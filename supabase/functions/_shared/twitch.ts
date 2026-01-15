const TWITCH_CLIENT_ID = Deno.env.get("TWITCH_CLIENT_ID")!;
const TWITCH_CLIENT_SECRET = Deno.env.get("TWITCH_CLIENT_SECRET")!;

/**
 * Verify Twitch EventSub webhook signature using HMAC-SHA256.
 * See: https://dev.twitch.tv/docs/eventsub/handling-webhook-events/#verifying-the-event-message
 */
export async function verifyEventSubSignature(
  messageId: string,
  timestamp: string,
  body: string,
  signature: string,
  secret: string,
): Promise<boolean> {
  const message = messageId + timestamp + body;
  const encoder = new TextEncoder();

  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );

  const signatureBuffer = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(message),
  );

  const expectedSignature = "sha256=" +
    Array.from(new Uint8Array(signatureBuffer))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");

  // Timing-safe comparison to prevent timing attacks
  return timingSafeEqual(
    encoder.encode(expectedSignature),
    encoder.encode(signature),
  );
}

/**
 * Timing-safe string comparison to prevent timing attacks.
 */
function timingSafeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a[i] ^ b[i];
  }
  return result === 0;
}

interface TwitchToken {
  access_token: string;
  expires_at: number;
}

let twitchToken: TwitchToken | null = null;

export async function getTwitchToken(): Promise<string> {
  if (twitchToken && twitchToken.expires_at > Date.now()) {
    return twitchToken.access_token;
  }

  console.log("Generating new Twitch token...");
  const response = await fetch("https://id.twitch.tv/oauth2/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: TWITCH_CLIENT_ID,
      client_secret: TWITCH_CLIENT_SECRET,
      grant_type: "client_credentials",
    }),
  });

  if (!response.ok) {
    const errorText = await response.text();
    console.error("Failed to get Twitch token:", errorText);
    throw new Error(`Failed to get Twitch token: ${response.status}`);
  }

  const data = await response.json();
  console.log("Token generated successfully, expires in:", data.expires_in);

  twitchToken = {
    access_token: data.access_token,
    expires_at: Date.now() + data.expires_in * 1000 - 60000, // Refresh 1 min early
  };

  return twitchToken.access_token;
}

export async function twitchApiCall(
  endpoint: string,
  params?: Record<string, string>,
) {
  const token = await getTwitchToken();
  const url = new URL(`https://api.twitch.tv/helix/${endpoint}`);

  if (params) {
    Object.entries(params).forEach(([key, value]) => {
      url.searchParams.append(key, value);
    });
  }

  console.log(`Twitch API call to: ${url.toString()}`);

  const headers = {
    "Client-Id": TWITCH_CLIENT_ID,
    Authorization: `Bearer ${token}`,
    Accept: "application/json",
    "accept-language": "PURPOSELYBADVALUEBECAUSETWITCHAPIISGARBAGE",
    "User-Agent": "Bazaar-Ghost/1.0",
  };

  const response = await fetch(url.toString(), {
    method: "GET",
    headers: headers,
  });

  console.log(`Response status: ${response.status}`);
  if (!response.ok) {
    const errorText = await response.text();
    console.log(`Error response: ${errorText}`);
    throw new Error(
      `Twitch API error: ${response.status} ${response.statusText}`,
    );
  }

  const responseText = await response.text();

  let responseData;
  try {
    responseData = JSON.parse(responseText);
  } catch (e) {
    console.error("Failed to parse JSON response:", e);
    console.error("Raw response:", responseText);
    throw new Error("Invalid JSON response from Twitch API");
  }

  return responseData;
}

export async function getBazaarGameId(): Promise<string> {
  const { data } = await twitchApiCall("search/categories", {
    query: "The Bazaar",
    first: "10",
  });

  // Find exact match for "The Bazaar"
  const bazaarGame = data?.find(
    (game: any) => game.name.toLowerCase() === "the bazaar",
  );

  if (!bazaarGame) {
    console.log(
      "Available games found:",
      data?.map((g: any) => g.name),
    );
    throw new Error("The Bazaar game not found on Twitch");
  }

  console.log(`Found The Bazaar with ID: ${bazaarGame.id}`);
  return bazaarGame.id;
}

export async function checkVodAvailability(vodId: string): Promise<boolean> {
  try {
    const { data } = await twitchApiCall("videos", {
      id: vodId,
    });

    // If we get data back with the VOD, it's available
    return data && data.length > 0;
  } catch (error) {
    // If API call fails (404, etc.), VOD is not available
    console.log(`VOD ${vodId} is not available: ${error.message}`);
    return false;
  }
}

export async function batchCheckVodAvailability(
  vodIds: string[],
): Promise<Record<string, boolean>> {
  const results: Record<string, boolean> = {};

  // Twitch API can handle up to 100 video IDs in a single call
  const batchSize = 100;

  for (let i = 0; i < vodIds.length; i += batchSize) {
    const batch = vodIds.slice(i, i + batchSize);

    try {
      // Build URL with multiple id parameters (not comma-separated)
      const token = await getTwitchToken();
      const url = new URL("https://api.twitch.tv/helix/videos");

      // Add each ID as a separate query parameter
      for (const id of batch) {
        url.searchParams.append("id", id);
      }

      console.log(`Checking ${batch.length} VODs with URL: ${url.toString()}`);

      const response = await fetch(url.toString(), {
        method: "GET",
        headers: {
          "Client-Id": TWITCH_CLIENT_ID,
          Authorization: `Bearer ${token}`,
          Accept: "application/json",
        },
      });

      // Mark all requested VODs as unavailable by default
      for (const vodId of batch) {
        results[vodId] = false;
      }

      if (response.ok) {
        const responseData = await response.json();
        console.log(
          `API returned ${
            responseData.data?.length || 0
          } available VODs out of ${batch.length} requested`,
        );

        // Mark returned VODs as available
        if (responseData.data) {
          for (const vod of responseData.data) {
            results[vod.id] = true;
            console.log(`✓ VOD ${vod.id} is available`);
          }
        }

        // Log which VODs were NOT found
        const unavailable = batch.filter((id) => !results[id]);
        if (unavailable.length > 0) {
          console.log(
            `✗ ${unavailable.length} VODs not found: ${unavailable.join(", ")}`,
          );
        }
      } else {
        const errorText = await response.text();
        console.error(`API error response: ${errorText}`);
        // All VODs remain marked as unavailable
      }

      console.log(`Checked availability for ${batch.length} VODs`);

      // Rate limiting: wait 1 second between batches
      if (i + batchSize < vodIds.length) {
        await new Promise((resolve) => setTimeout(resolve, 1000));
      }
    } catch (error) {
      console.error(`Error checking VOD availability for batch:`, error);
      // Mark all VODs in this batch as unavailable
      for (const vodId of batch) {
        results[vodId] = false;
      }
    }
  }

  return results;
}

export async function getStreamerIdByLogin(
  login: string,
): Promise<string | null> {
  try {
    const { data } = await twitchApiCall("users", { login });

    if (data && data.length > 0) {
      return data[0].id;
    }

    console.log(`No streamer found with login: ${login}`);
    return null;
  } catch (error) {
    console.error(`Error fetching streamer ID for ${login}:`, error);
    return null;
  }
}

export async function getVodsFromStreamer(
  streamerId: string,
  params?: {
    first?: string;
    after?: string;
    before?: string;
    type?: string;
    period?: string;
  },
) {
  const queryParams: Record<string, string> = {
    user_id: streamerId,
    first: params?.first || "100",
  };

  if (params?.after) queryParams.after = params.after;
  if (params?.before) queryParams.before = params.before;
  if (params?.type) queryParams.type = params.type;
  if (params?.period) queryParams.period = params.period;

  return twitchApiCall("videos", queryParams);
}

export async function isStreamerLive(userId: string): Promise<boolean> {
  try {
    const { data } = await twitchApiCall("streams", { user_id: userId });

    // If data array has entries, streamer is live
    // Empty array means offline
    const isLive = data && data.length > 0;

    if (isLive) {
      console.log(`Streamer ${userId} is currently live: ${data[0].title}`);
    } else {
      console.log(`Streamer ${userId} is offline`);
    }

    return isLive;
  } catch (error) {
    console.error(`Error checking live status for ${userId}:`, error);
    // On error, assume not live to avoid skipping VODs
    return false;
  }
}

// GraphQL API constants and functions
const TWITCH_GQL_URL = "https://gql.twitch.tv/gql";
const TWITCH_GQL_CLIENT_ID = "kimne78kx3ncx6brgo4mv6wki5h1ko"; // Public Twitch web client ID

interface GraphQLResponse<T = any> {
  data?: T;
  errors?: Array<{ message: string; locations?: any[]; extensions?: any }>;
}

/**
 * Make a GraphQL API call to Twitch's unofficial GQL endpoint
 * Used for fetching data not available in Helix API (e.g., VOD chapters)
 */
export async function twitchGraphQLCall<T = any>(
  query: string,
  variables?: Record<string, any>,
  operationName?: string,
): Promise<GraphQLResponse<T>> {
  const body: any = { query };

  if (variables) {
    body.variables = variables;
  }

  if (operationName) {
    body.operationName = operationName;
  }

  console.log(`Twitch GraphQL call: ${operationName || "query"}`);

  const response = await fetch(TWITCH_GQL_URL, {
    method: "POST",
    headers: {
      "Client-ID": TWITCH_GQL_CLIENT_ID,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    const errorText = await response.text();
    console.error(`GraphQL HTTP error: ${response.status} - ${errorText}`);
    throw new Error(`GraphQL HTTP error: ${response.status}`);
  }

  const result = await response.json();

  // Handle partial errors - Twitch often returns data with field-level errors
  if (result.errors && result.errors.length > 0) {
    console.warn(
      "GraphQL errors (may have partial data):",
      JSON.stringify(result.errors, null, 2),
    );

    if (!result.data) {
      throw new Error(
        `GraphQL error with no data: ${result.errors[0].message}`,
      );
    }

    console.log("Proceeding with partial data despite errors");
  }

  return result;
}

export interface VideoChapter {
  positionMilliseconds: number;
  type: string;
  description: string;
  game?: {
    id: string;
    name: string;
    displayName: string;
  };
}

export interface VODWithChapters {
  id: string;
  title: string;
  lengthSeconds: number;
  publishedAt: string;
  game?: {
    id: string;
    name: string;
  };
  chapters: VideoChapter[];
}

/**
 * Fetch VODs for a streamer with chapter data using GraphQL.
 * @param streamerLogin - Twitch login name
 * @param numVods - Optional limit on number of VODs to fetch. If not provided, fetches all (up to 5000).
 */
export async function getStreamerVodsWithChapters(
  streamerLogin: string,
  numVods?: number,
): Promise<VODWithChapters[]> {
  const query = `
    query GetUserVideos($login: String!, $first: Int!, $after: Cursor) {
      user(login: $login) {
        id
        displayName
        login
        videos(first: $first, type: ARCHIVE, after: $after) {
          edges {
            node {
              id
              title
              lengthSeconds
              publishedAt
              game {
                id
                name
                displayName
              }
              moments(first: 25, momentRequestType: VIDEO_CHAPTER_MARKERS) {
                edges {
                  node {
                    positionMilliseconds
                    type
                    description
                    details {
                      ... on GameChangeMomentDetails {
                        game {
                          id
                          name
                          displayName
                        }
                      }
                    }
                  }
                }
              }
            }
            cursor
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
      }
    }
  `;

  const allVods: VODWithChapters[] = [];
  let cursor: string | undefined;
  let pageCount = 0;

  // If numVods specified, fetch exactly that many (max 100 per request)
  // Otherwise, fetch all with pagination (up to 50 pages = 5000 VODs)
  const perPage = numVods ? Math.min(numVods, 100) : 100;
  const maxPages = numVods ? 1 : 50;

  do {
    const variables: { login: string; first: number; after?: string } = {
      login: streamerLogin,
      first: perPage,
    };

    if (cursor) {
      variables.after = cursor;
    }

    console.log(
      `Fetching VODs for ${streamerLogin} (page ${pageCount + 1})...`,
    );

    const response = await twitchGraphQLCall(query, variables, "GetUserVideos");

    if (!response.data?.user) {
      console.log(`User ${streamerLogin} not found or has no videos`);
      break;
    }

    const videos = response.data.user.videos.edges || [];
    console.log(`Got ${videos.length} VODs on page ${pageCount + 1}`);

    for (const edge of videos) {
      const video = edge.node;

      // Parse chapter data
      const chapters: VideoChapter[] = [];
      if (video.moments?.edges) {
        for (const momentEdge of video.moments.edges) {
          const moment = momentEdge.node;

          // Extract game info from details
          const game = moment.details?.game;

          chapters.push({
            positionMilliseconds: moment.positionMilliseconds,
            type: moment.type,
            description: moment.description,
            game: game
              ? {
                id: game.id,
                name: game.name,
                displayName: game.displayName,
              }
              : undefined,
          });
        }
      }

      allVods.push({
        id: video.id,
        title: video.title,
        lengthSeconds: video.lengthSeconds,
        publishedAt: video.publishedAt,
        game: video.game
          ? {
            id: video.game.id,
            name: video.game.name,
          }
          : undefined,
        chapters,
      });
    }

    const pageInfo = response.data.user.videos.pageInfo;
    cursor = pageInfo.hasNextPage ? pageInfo.endCursor : undefined;
    pageCount++;
  } while (cursor && pageCount < maxPages);

  console.log(`Total VODs fetched for ${streamerLogin}: ${allVods.length}`);
  return allVods;
}

// ============================================================================
// EventSub Subscription Management
// ============================================================================

export interface EventSubSubscription {
  id: string;
  status: string;
  type: string;
  condition: {
    broadcaster_user_id: string;
  };
  transport: {
    method: string;
    callback?: string;
  };
  created_at: string;
}

export interface CreateSubscriptionResult {
  success: boolean;
  subscription_id: string | null;
  already_exists: boolean;
  error?: string;
}

/**
 * Create a stream.offline EventSub subscription for a broadcaster.
 * Returns success if subscription is created or already exists.
 */
export async function createEventSubSubscription(
  broadcasterUserId: string,
): Promise<CreateSubscriptionResult> {
  const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
  const TWITCH_EVENTSUB_SECRET = Deno.env.get("TWITCH_EVENTSUB_SECRET");

  if (!SUPABASE_URL) {
    console.error("SUPABASE_URL not configured");
    return {
      success: false,
      subscription_id: null,
      already_exists: false,
      error: "SUPABASE_URL not configured",
    };
  }

  if (!TWITCH_EVENTSUB_SECRET) {
    console.error("TWITCH_EVENTSUB_SECRET not configured");
    return {
      success: false,
      subscription_id: null,
      already_exists: false,
      error: "TWITCH_EVENTSUB_SECRET not configured",
    };
  }

  const token = await getTwitchToken();
  const callbackUrl = `${SUPABASE_URL}/functions/v1/process-vod`;

  const payload = {
    type: "stream.offline",
    version: "1",
    condition: {
      broadcaster_user_id: broadcasterUserId,
    },
    transport: {
      method: "webhook",
      callback: callbackUrl,
      secret: TWITCH_EVENTSUB_SECRET,
    },
  };

  console.log(
    `Creating EventSub subscription for broadcaster ${broadcasterUserId}`,
  );
  console.log(`Callback URL: ${callbackUrl}`);

  try {
    const response = await fetch(
      "https://api.twitch.tv/helix/eventsub/subscriptions",
      {
        method: "POST",
        headers: {
          "Client-Id": TWITCH_CLIENT_ID,
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(payload),
      },
    );

    if (response.status === 202) {
      // Success - subscription created
      const data = await response.json();
      const subscriptionId = data.data?.[0]?.id;
      console.log(`EventSub subscription created: ${subscriptionId}`);
      return {
        success: true,
        subscription_id: subscriptionId,
        already_exists: false,
      };
    }

    if (response.status === 409) {
      // Subscription already exists - this is still success
      console.log(
        `EventSub subscription already exists for ${broadcasterUserId}`,
      );

      // Try to get the existing subscription ID
      const existing = await hasEventSubSubscription(broadcasterUserId);
      return {
        success: true,
        subscription_id: existing.subscription_id,
        already_exists: true,
      };
    }

    // Other error
    const errorText = await response.text();
    console.error(`EventSub creation failed: ${response.status} ${errorText}`);
    return {
      success: false,
      subscription_id: null,
      already_exists: false,
      error: `${response.status}: ${errorText}`,
    };
  } catch (error: any) {
    console.error(`EventSub creation error:`, error);
    return {
      success: false,
      subscription_id: null,
      already_exists: false,
      error: error.message,
    };
  }
}

/**
 * List all EventSub subscriptions for the app.
 * Can filter by type and/or user_id (broadcaster).
 */
export async function listEventSubSubscriptions(
  filters?: {
    type?: string;
    user_id?: string;
  },
): Promise<EventSubSubscription[]> {
  const token = await getTwitchToken();
  const allSubscriptions: EventSubSubscription[] = [];
  let cursor: string | undefined;

  do {
    const url = new URL("https://api.twitch.tv/helix/eventsub/subscriptions");

    if (filters?.type) {
      url.searchParams.set("type", filters.type);
    }
    if (filters?.user_id) {
      url.searchParams.set("user_id", filters.user_id);
    }
    if (cursor) {
      url.searchParams.set("after", cursor);
    }

    const response = await fetch(url.toString(), {
      method: "GET",
      headers: {
        "Client-Id": TWITCH_CLIENT_ID,
        Authorization: `Bearer ${token}`,
      },
    });

    if (!response.ok) {
      const errorText = await response.text();
      console.error(
        `Failed to list EventSub subscriptions: ${response.status} ${errorText}`,
      );
      break;
    }

    const data = await response.json();

    if (data.data) {
      allSubscriptions.push(...data.data);
    }

    cursor = data.pagination?.cursor;
  } while (cursor);

  return allSubscriptions;
}

/**
 * Check if a stream.offline subscription exists for a broadcaster.
 */
export async function hasEventSubSubscription(
  broadcasterUserId: string,
): Promise<{ exists: boolean; subscription_id: string | null }> {
  const subscriptions = await listEventSubSubscriptions({
    type: "stream.offline",
    user_id: broadcasterUserId,
  });

  const matching = subscriptions.find(
    (sub) =>
      sub.condition.broadcaster_user_id === broadcasterUserId &&
      sub.type === "stream.offline",
  );

  return {
    exists: !!matching,
    subscription_id: matching?.id || null,
  };
}
