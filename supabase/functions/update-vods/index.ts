// Setup type definitions for built-in Supabase Runtime APIs
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import {
  fetchAndUpsertVods,
  supabase,
  verifySecretKey,
} from "../_shared/supabase.ts";
import {
  createEventSubSubscription,
  getStreamerIdByLogin,
  getVodsFromStreamer,
  isStreamerLive,
} from "../_shared/twitch.ts";
import { log, recordCounter } from "../_shared/telemetry.ts";

interface UpdateVodsRequest {
  streamer_id: number;
}

interface UpdateVodsResult {
  streamerLogin: string;
  totalVodsFetched: number;
  vodsWithBazaar: number;
  vodsInserted: number;
  totalBazaarSegments: number;
}

/**
 * Ensure EventSub subscription exists for a processing-enabled streamer.
 * Creates subscription if not already present.
 */
async function ensureEventSubSubscription(
  streamerId: number,
  streamerLogin: string,
): Promise<void> {
  log("info", "Ensuring EventSub subscription exists", {
    streamer_id: streamerId,
    login: streamerLogin,
  });

  const result = await createEventSubSubscription(streamerId.toString());

  if (result.success) {
    // Update database with subscription ID
    const { error } = await supabase
      .from("streamers")
      .update({ eventsub_subscription_id: result.subscription_id })
      .eq("id", streamerId);

    if (error) {
      log("error", "Failed to update streamer with subscription ID", {
        streamer_id: streamerId,
        error: error.message,
      });
    } else {
      recordCounter("eventsub.subscription.created", 1, {
        streamer: streamerLogin,
        already_existed: result.already_exists.toString(),
      });
      log("info", "EventSub subscription ensured", {
        streamer_id: streamerId,
        subscription_id: result.subscription_id,
        already_existed: result.already_exists,
      });
    }
  } else {
    recordCounter("eventsub.subscription.failed", 1, {
      streamer: streamerLogin,
    });
    log("error", "Failed to create EventSub subscription", {
      streamer_id: streamerId,
      error: result.error,
    });
  }
}

/**
 * Update VODs for a specific streamer using GraphQL API
 * Fetches VODs with chapter data and stores only those with Bazaar gameplay
 */
async function updateVods(streamerId: number): Promise<UpdateVodsResult> {
  // Get streamer info from database
  const { data: streamer, error: streamerError } = await supabase
    .from("streamers")
    .select("id, login, display_name, processing_enabled, eventsub_subscription_id")
    .eq("id", streamerId)
    .single();

  if (streamerError || !streamer) {
    throw new Error(`Streamer with ID ${streamerId} not found in database`);
  }

  // Ensure EventSub subscription exists for processing-enabled streamers
  if (streamer.processing_enabled && !streamer.eventsub_subscription_id) {
    await ensureEventSubSubscription(streamer.id, streamer.login);
  }

  console.log(
    `Fetching VODs for streamer: ${streamer.login} (${streamerId})`,
  );

  // Quick check: Get streamer's Twitch ID and check if they have more than 1 VOD
  // This avoids expensive GraphQL chapter fetching for streamers who don't save VODs
  console.log("Checking VOD count before fetching chapter data...");
  const twitchUserId = await getStreamerIdByLogin(streamer.login);

  if (!twitchUserId) {
    throw new Error(`Could not find Twitch user ID for ${streamer.login}`);
  }

  // Check if streamer is currently live
  const isLive = await isStreamerLive(twitchUserId);
  console.log(
    `Streamer ${streamer.login} live status: ${isLive ? "LIVE" : "offline"}`,
  );

  // Fetch only first 2 VODs to check count (lightweight Helix API call)
  const quickCheck = await getVodsFromStreamer(twitchUserId, { first: "2" });
  const vodCount = quickCheck.data?.length || 0;
  console.log(`Streamer has ${vodCount} VOD(s)`);

  // If streamer has 1 or fewer VODs, skip chapter processing
  if (vodCount <= 1) {
    console.log(
      `Streamer has ${vodCount} VOD(s), skipping chapter fetch and marking has_vods=false`,
    );

    await supabase
      .from("streamers")
      .update({
        has_vods: false,
        num_vods: vodCount,
        num_bazaar_vods: 0,
        oldest_vod: null,
        updated_at: new Date().toISOString(),
      })
      .eq("id", streamerId);

    return {
      streamerLogin: streamer.login,
      totalVodsFetched: vodCount,
      vodsWithBazaar: 0,
      vodsInserted: 0,
      totalBazaarSegments: 0,
    };
  }

  console.log(`Streamer has multiple VODs, proceeding with chapter fetch...`);

  // Use shared function to fetch and upsert VODs
  // skipLiveVod=true if streamer is currently live
  const result = await fetchAndUpsertVods(
    streamerId,
    streamer.login,
    undefined, // Fetch all VODs
    isLive, // Skip live VOD if streaming
  );

  const {
    vodsUpserted,
    bazaarSegments,
    totalVodsFetched,
    oldestVod,
  } = result;

  // Update streamer statistics
  await supabase
    .from("streamers")
    .update({
      has_vods: true,
      num_vods: totalVodsFetched,
      num_bazaar_vods: vodsUpserted,
      oldest_vod: oldestVod,
      updated_at: new Date().toISOString(),
    })
    .eq("id", streamerId);

  console.log(`
Summary for ${streamer.login}:
  Total VODs fetched: ${totalVodsFetched}
  VODs with Bazaar gameplay: ${vodsUpserted}
  VODs inserted/updated: ${vodsUpserted}
  Total Bazaar segments: ${bazaarSegments}
  Oldest VOD: ${oldestVod || "N/A"}
  `);

  return {
    streamerLogin: streamer.login,
    totalVodsFetched,
    vodsWithBazaar: vodsUpserted,
    vodsInserted: vodsUpserted,
    totalBazaarSegments: bazaarSegments,
  };
}

serve(async (req) => {
  try {
    // Verify secret key authentication
    if (!verifySecretKey(req)) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        {
          headers: { "Content-Type": "application/json" },
          status: 401,
        },
      );
    }

    if (req.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    // Parse request body
    const body = await req.json() as UpdateVodsRequest;

    if (!body.streamer_id || typeof body.streamer_id !== "number") {
      return new Response(
        JSON.stringify({
          error: "Missing or invalid required parameter: streamer_id (number)",
        }),
        {
          headers: { "Content-Type": "application/json" },
          status: 400,
        },
      );
    }

    const result = await updateVods(body.streamer_id);

    return new Response(JSON.stringify(result), {
      headers: { "Content-Type": "application/json" },
      status: 200,
    });
  } catch (error: any) {
    console.error("Update VODs function error:", error);
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { "Content-Type": "application/json" },
      status: 500,
    });
  }
});

/* To invoke locally:

  1. Run `supabase start` (see: https://supabase.com/docs/reference/cli/supabase-start)
  2. Make an HTTP request with a streamer_id:

  curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/update-vods' \
    --header 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0' \
    --header 'Content-Type: application/json' \
    --data '{"streamer_id": 29795919}'

  Note: Replace 29795919 with the actual streamer ID from your database

*/
