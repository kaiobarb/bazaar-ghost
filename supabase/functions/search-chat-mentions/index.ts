import "jsr:@supabase/functions-js/edge-runtime.d.ts";

import { supabase, verifySecretKey } from "../_shared/supabase.ts";
import { twitchGraphQLCall } from "../_shared/twitch.ts";
import { log, recordCounter } from "../_shared/telemetry.ts";

// Keywords to search for (case-insensitive)
const KEYWORDS = ["bazaarghost", "bazaar ghost", "bazaarghost.stream"];

// Rate limiting between GQL requests (ms)
const DELAY_BETWEEN_VODS_MS = 500;
const DELAY_BETWEEN_CHUNKS_MS = 100;

// Safety limit for pagination per VOD
const MAX_PAGES_PER_VOD = 500;

interface ChatComment {
  id: string;
  username: string;
  displayName: string;
  message: string;
  offsetSeconds: number;
  createdAt: string;
}

interface ChatPageResult {
  comments: ChatComment[];
  hasNext: boolean;
}

interface ChatMention {
  channel: string;
  channelDisplay: string;
  vodId: string;
  vodTitle: string;
  vodDate: string;
  username: string;
  displayName: string;
  message: string;
  offsetSeconds: number;
  timestamp: string;
  vodUrl: string;
  keywordMatched: string;
}

interface VideoCommentsResponse {
  video: {
    id: string;
    comments: {
      edges: Array<{
        cursor: string;
        node: {
          id: string;
          commenter: {
            id: string;
            login: string;
            displayName: string;
          } | null;
          contentOffsetSeconds: number;
          createdAt: string;
          message: {
            fragments: Array<{ text: string }>;
          };
        };
      }>;
      pageInfo: {
        hasNextPage: boolean;
      };
    } | null;
  } | null;
}

const CHAT_REPLAY_QUERY = `
  query VideoCommentsByOffsetOrCursor($videoID: ID!, $contentOffsetSeconds: Int) {
    video(id: $videoID) {
      id
      comments(contentOffsetSeconds: $contentOffsetSeconds) {
        edges {
          cursor
          node {
            id
            commenter {
              id
              login
              displayName
            }
            contentOffsetSeconds
            createdAt
            message {
              fragments {
                text
              }
            }
          }
        }
        pageInfo {
          hasNextPage
        }
      }
    }
  }
`;

/**
 * Fetch a page of chat comments for a VOD at a given offset.
 */
async function fetchVodComments(
  vodId: string,
  contentOffset: number,
): Promise<ChatPageResult> {
  try {
    const result = await twitchGraphQLCall<VideoCommentsResponse>(
      CHAT_REPLAY_QUERY,
      { videoID: vodId, contentOffsetSeconds: contentOffset },
      "VideoCommentsByOffsetOrCursor",
    );

    const video = result.data?.video;
    if (!video?.comments) {
      return { comments: [], hasNext: false };
    }

    const edges = video.comments.edges ?? [];
    const comments: ChatComment[] = edges.map((edge) => {
      const node = edge.node;
      const messageText = node.message.fragments
        .map((f) => f.text)
        .join("");
      const commenter = node.commenter;

      return {
        id: node.id,
        username: commenter?.login ?? "[deleted]",
        displayName: commenter?.displayName ?? "[deleted]",
        message: messageText,
        offsetSeconds: node.contentOffsetSeconds ?? 0,
        createdAt: node.createdAt,
      };
    });

    const hasNext = video.comments.pageInfo?.hasNextPage ?? false;
    return { comments, hasNext };
  } catch (error: any) {
    console.error(`Error fetching comments for VOD ${vodId}: ${error.message}`);
    return { comments: [], hasNext: false };
  }
}

/**
 * Format seconds into H:MM:SS display and Twitch URL timestamp.
 */
function formatTimestamp(seconds: number): { display: string; url: string } {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const secs = seconds % 60;
  return {
    display: `${hours}:${String(minutes).padStart(2, "0")}:${
      String(secs).padStart(2, "0")
    }`,
    url: `${hours}h${minutes}m${secs}s`,
  };
}

/**
 * Sleep for a given number of milliseconds.
 */
function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Search all chat messages in a single VOD for keyword matches.
 * Uses offset-based pagination (cursor pagination requires integrity token).
 */
async function searchVodChat(
  vod: any,
): Promise<{ matches: ChatMention[]; totalComments: number }> {
  const vodId = vod.source_id;
  const streamer = vod.streamers ?? {};
  const channel = streamer.login ?? "unknown";
  const channelDisplay = streamer.display_name ?? channel;

  const matches: ChatMention[] = [];
  const seenIds = new Set<string>();
  let totalUniqueComments = 0;

  let offset = 0;
  let maxOffsetSeen = 0;
  let pages = 0;

  while (pages < MAX_PAGES_PER_VOD) {
    const { comments, hasNext } = await fetchVodComments(vodId, offset);

    if (comments.length === 0) break;

    pages++;
    let newThisPage = 0;

    for (const comment of comments) {
      if (seenIds.has(comment.id)) continue;

      seenIds.add(comment.id);
      newThisPage++;
      totalUniqueComments++;

      if (comment.offsetSeconds > maxOffsetSeen) {
        maxOffsetSeen = comment.offsetSeconds;
      }

      const textLower = comment.message.toLowerCase();

      for (const keyword of KEYWORDS) {
        if (textLower.includes(keyword.toLowerCase())) {
          const ts = formatTimestamp(comment.offsetSeconds);

          matches.push({
            channel,
            channelDisplay,
            vodId,
            vodTitle: vod.title ?? "",
            vodDate: vod.published_at ?? "",
            username: comment.username,
            displayName: comment.displayName,
            message: comment.message,
            offsetSeconds: comment.offsetSeconds,
            timestamp: ts.display,
            vodUrl: `https://www.twitch.tv/videos/${vodId}?t=${ts.url}`,
            keywordMatched: keyword,
          });
          break; // Don't duplicate if multiple keywords match
        }
      }
    }

    if (newThisPage === 0 || !hasNext) break;

    offset = maxOffsetSeen + 1;
    await sleep(DELAY_BETWEEN_CHUNKS_MS);
  }

  return { matches, totalComments: totalUniqueComments };
}

/**
 * Fetch VODs from streamers with has_vods=true published in the last 24 hours.
 */
async function getRecentVods(): Promise<any[]> {
  const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();

  const allVods: any[] = [];
  const pageSize = 1000;
  let offset = 0;

  while (true) {
    const { data, error } = await supabase
      .from("vods")
      .select(
        "id, source_id, title, duration_seconds, published_at, streamer_id, " +
          "streamers!inner(id, login, display_name, has_vods)",
      )
      .gte("published_at", since)
      .eq("streamers.has_vods", true)
      .order("published_at", { ascending: false })
      .range(offset, offset + pageSize - 1);

    if (error) {
      throw new Error(`Failed to fetch VODs: ${error.message}`);
    }

    if (!data || data.length === 0) break;

    allVods.push(...data);

    if (data.length < pageSize) break;

    offset += pageSize;
  }

  return allVods;
}

/**
 * Main handler: search recent VOD chats for bazaarghost mentions.
 * Results are logged to Grafana (Loki via structured logs, Prometheus via counters).
 */
async function searchChatMentions(): Promise<{
  vodsSearched: number;
  vodsWithChat: number;
  totalComments: number;
  totalMatches: number;
  matches: ChatMention[];
}> {
  log("info", "Starting chat mention search", {
    keywords: KEYWORDS,
    lookbackHours: 24,
  });

  const vods = await getRecentVods();

  log("info", "Fetched VODs for chat search", {
    vodCount: vods.length,
  });

  let vodsSearched = 0;
  let vodsWithChat = 0;
  let totalComments = 0;
  const allMatches: ChatMention[] = [];

  for (const vod of vods) {
    const streamer = vod.streamers ?? {};
    const channel = streamer.login ?? "unknown";
    const vodId = vod.source_id;

    const { matches, totalComments: commentCount } = await searchVodChat(vod);
    vodsSearched++;

    if (commentCount > 0) {
      vodsWithChat++;
      totalComments += commentCount;
    }

    if (matches.length > 0) {
      allMatches.push(...matches);

      // Log each match individually so they appear as separate Loki entries
      for (const match of matches) {
        log("info", "Chat mention found", {
          service: "search-chat-mentions",
          channel: match.channel,
          channelDisplay: match.channelDisplay,
          vodId: match.vodId,
          vodTitle: match.vodTitle,
          vodDate: match.vodDate,
          username: match.username,
          displayName: match.displayName,
          message: match.message,
          offsetSeconds: match.offsetSeconds,
          timestamp: match.timestamp,
          vodUrl: match.vodUrl,
          keywordMatched: match.keywordMatched,
        });
      }

      await recordCounter(
        "chat_mentions.found",
        matches.length,
        { channel },
      );
    }

    await sleep(DELAY_BETWEEN_VODS_MS);
  }

  // Summary metrics
  await recordCounter("chat_mentions.vods_searched", vodsSearched);
  await recordCounter("chat_mentions.comments_searched", totalComments);
  await recordCounter("chat_mentions.total_found", allMatches.length);

  log("info", "Chat mention search complete", {
    service: "search-chat-mentions",
    vodsSearched,
    vodsWithChat,
    totalComments,
    totalMatches: allMatches.length,
  });

  return {
    vodsSearched,
    vodsWithChat,
    totalComments,
    totalMatches: allMatches.length,
    matches: allMatches,
  };
}

Deno.serve(async (req) => {
  try {
    if (!verifySecretKey(req)) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { headers: { "Content-Type": "application/json" }, status: 401 },
      );
    }

    if (req.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    const result = await searchChatMentions();

    return new Response(JSON.stringify(result), {
      headers: { "Content-Type": "application/json" },
      status: 200,
    });
  } catch (error: any) {
    console.error("search-chat-mentions error:", error);
    log("error", "Chat mention search failed", {
      service: "search-chat-mentions",
      error: error.message,
    });

    return new Response(
      JSON.stringify({ error: error.message }),
      { headers: { "Content-Type": "application/json" }, status: 500 },
    );
  }
});
