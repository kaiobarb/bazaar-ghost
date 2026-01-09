import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  getBazaarGameId,
  getStreamerVodsWithChapters,
  VideoChapter,
  VODWithChapters,
} from "./twitch.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SECRET_KEY = Deno.env.get("SECRET_KEY");

// Debug logging to see what environment variables we have
console.log("SUPABASE_URL:", SUPABASE_URL);
console.log(
  "SUPABASE_SERVICE_ROLE_KEY:",
  SUPABASE_SERVICE_ROLE_KEY
    ? `${SUPABASE_SERVICE_ROLE_KEY.substring(0, 20)}...`
    : "NOT SET",
);
console.log(
  "SECRET_KEY:",
  SECRET_KEY ? `${SECRET_KEY.substring(0, 20)}...` : "NOT SET",
);

export const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

/**
 * Verifies that the request contains a valid secret key in the apikey header
 * Returns true if valid, false otherwise
 * Skips verification for local development and Supabase UI test invocations
 */
export function verifySecretKey(req: Request): boolean {
  // Skip verification on local (kong:8000 is the internal Docker URL for local dev)
  const isLocal = SUPABASE_URL.includes("localhost") ||
    SUPABASE_URL.includes("127.0.0.1") ||
    SUPABASE_URL.includes("kong:8000");

  console.log(SUPABASE_URL);
  if (isLocal) {
    console.log("Skipped secret verification (local environment)");
    return true;
  }

  const apiKey = req.headers.get("apikey");

  if (!apiKey) {
    console.log("No apikey header provided");
    return false;
  }

  if (!SECRET_KEY) {
    console.error("SECRET_KEY environment variable not set");
    return false;
  }

  const isValid = apiKey === SECRET_KEY;

  if (!isValid) {
    console.log("Invalid apikey provided");
  }

  return isValid;
}

/**
 * Extract Bazaar chapter time ranges from VOD chapters.
 * Returns array in format: [start1_sec, end1_sec, start2_sec, end2_sec, ...]
 */
export function extractBazaarChapters(
  chapters: VideoChapter[],
  videoLengthSeconds: number,
  bazaarGameId: string,
): number[] {
  const bazaarSegments: number[] = [];

  // Sort chapters by position
  const sortedChapters = [...chapters].sort(
    (a, b) => a.positionMilliseconds - b.positionMilliseconds,
  );

  for (let i = 0; i < sortedChapters.length; i++) {
    const chapter = sortedChapters[i];

    // Check if this chapter is for The Bazaar
    const isBazaar = chapter.game?.id === bazaarGameId ||
      chapter.game?.name?.toLowerCase().includes("bazaar");

    if (isBazaar) {
      // Chapter start time in seconds
      const startSeconds = Math.floor(chapter.positionMilliseconds / 1000);

      // Chapter end time: either next chapter start or video end
      let endSeconds: number;
      if (i + 1 < sortedChapters.length) {
        endSeconds = Math.floor(
          sortedChapters[i + 1].positionMilliseconds / 1000,
        );
      } else {
        endSeconds = videoLengthSeconds;
      }

      // Add to segments array
      bazaarSegments.push(startSeconds, endSeconds);

      console.log(
        `  Found Bazaar segment: ${startSeconds}s - ${endSeconds}s (${
          endSeconds - startSeconds
        }s duration)`,
      );
    }
  }

  return bazaarSegments;
}

export interface FetchAndUpsertResult {
  /** Number of VODs with Bazaar gameplay that were upserted */
  vodsUpserted: number;
  /** Total Bazaar segment count across all upserted VODs */
  bazaarSegments: number;
  /** Source IDs of upserted VODs */
  upsertedVodIds: string[];
  /** Total VODs fetched from Twitch (before filtering for Bazaar) */
  totalVodsFetched: number;
  /** Oldest VOD timestamp (for streamer stats) */
  oldestVod: string | null;
}

/**
 * Fetch VODs with chapter data, extract Bazaar chapters, and upsert to database.
 *
 * @param streamerId - Internal streamer ID from database
 * @param streamerLogin - Twitch login name
 * @param numVods - Optional limit on number of VODs to fetch. If not provided, fetches all.
 * @param skipLiveVod - If true, skip the most recent VOD
 */
export async function fetchAndUpsertVods(
  streamerId: number,
  streamerLogin: string,
  numVods?: number,
  skipLiveVod: boolean = false,
): Promise<FetchAndUpsertResult> {
  const bazaarGameId = await getBazaarGameId();
  const vods = await getStreamerVodsWithChapters(streamerLogin, numVods);

  let vodsUpserted = 0;
  let bazaarSegments = 0;
  const upsertedVodIds: string[] = [];

  // Optionally skip first VOD if streamer is live
  const vodsToProcess = skipLiveVod && vods.length > 0 ? vods.slice(1) : vods;
  const totalVodsFetched = vodsToProcess.length;

  // Calculate oldest VOD timestamp
  let oldestVod: string | null = null;
  if (vodsToProcess.length > 0) {
    oldestVod = vodsToProcess.reduce((oldest, vod) => {
      return !oldest || vod.publishedAt < oldest ? vod.publishedAt : oldest;
    }, null as string | null);
  }

  for (const vod of vodsToProcess) {
    console.log(`Processing VOD ${vod.id}: ${vod.title}`);

    // Extract Bazaar chapter time ranges
    let chapters = extractBazaarChapters(
      vod.chapters,
      vod.lengthSeconds,
      bazaarGameId,
    );

    // Fallback: If no chapters found but VOD's main game is The Bazaar,
    // treat the entire VOD as a Bazaar segment
    if (chapters.length === 0) {
      const isBazaarGame = vod.game?.id === bazaarGameId ||
        vod.game?.name?.toLowerCase().includes("bazaar");

      if (isBazaarGame) {
        console.log(
          `  No chapters, but VOD game is The Bazaar - treating entire VOD as Bazaar segment`,
        );
        chapters = [0, vod.lengthSeconds];
      } else {
        console.log(`  No Bazaar gameplay found in VOD ${vod.id}, skipping`);
        continue;
      }
    }

    console.log(`  VOD ${vod.id} has ${chapters.length / 2} Bazaar segment(s)`);

    // Upsert VOD to database
    const { error } = await supabase.from("vods").upsert(
      {
        streamer_id: streamerId,
        source: "twitch",
        source_id: vod.id,
        title: vod.title,
        duration_seconds: vod.lengthSeconds,
        published_at: vod.publishedAt,
        bazaar_chapters: chapters,
        availability: "available",
        last_availability_check: new Date().toISOString(),
        ready_for_processing: true,
        updated_at: new Date().toISOString(),
      },
      {
        onConflict: "source,source_id",
        ignoreDuplicates: false,
      },
    );

    if (error) {
      console.error(`Error upserting VOD ${vod.id}:`, error);
    } else {
      vodsUpserted++;
      bazaarSegments += chapters.length / 2;
      upsertedVodIds.push(vod.id);
      console.log(`✓ Upserted VOD ${vod.id} with Bazaar chapters`);
    }
  }

  return {
    vodsUpserted,
    bazaarSegments,
    upsertedVodIds,
    totalVodsFetched,
    oldestVod,
  };
}
