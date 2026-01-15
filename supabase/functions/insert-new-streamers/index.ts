// Setup type definitions for built-in Supabase Runtime APIs
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { supabase, verifySecretKey } from "../_shared/supabase.ts";
import {
  createEventSubSubscription,
  getBazaarGameId,
  twitchApiCall,
} from "../_shared/twitch.ts";
import { log, recordCounter } from "../_shared/telemetry.ts";

interface InsertNewStreamersResult {
  newStreamersDiscovered: number;
  streamersChecked: number;
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
 * Discovers new Bazaar streamers from recent VODs using Helix API
 */
async function insertNewStreamers(): Promise<InsertNewStreamersResult> {
  let newStreamersDiscovered = 0;
  let streamersChecked = 0;

  try {
    // Get The Bazaar game ID
    const bazaarGameId = await getBazaarGameId();
    console.log(`The Bazaar game ID: ${bazaarGameId}`);

    // Fetch 500 most recent Bazaar VODs (5 pages of 100)
    console.log("Fetching recent Bazaar VODs from Helix API...");

    let cursor: string | undefined;
    let pageCount = 0;
    const maxPages = 5; // 500 VODs total
    const streamersMap = new Map<string, any>(); // Track unique streamers by ID

    // Paginate through VODs
    do {
      const params: Record<string, string> = {
        game_id: bazaarGameId,
        first: "100",
        type: "archive",
        sort: "time",
      };

      if (cursor) {
        params.after = cursor;
      }

      console.log(`Fetching VODs page ${pageCount + 1}...`);
      const { data: vods, pagination } = await twitchApiCall("videos", params);

      console.log(`Got ${vods?.length || 0} VODs on page ${pageCount + 1}`);

      // Collect streamer IDs from VODs
      if (vods) {
        for (const vod of vods) {
          if (!streamersMap.has(vod.user_id)) {
            streamersMap.set(vod.user_id, {
              id: vod.user_id,
              login: vod.user_login,
              display_name: vod.user_name,
            });
          }
        }
      }

      cursor = pagination?.cursor;
      pageCount++;
    } while (cursor && pageCount < maxPages);

    console.log(
      `Found ${streamersMap.size} unique streamers from ${
        pageCount * 100
      } VODs`,
    );

    // Process each unique streamer
    for (const [streamerId, streamerData] of streamersMap) {
      streamersChecked++;

      // Check if streamer already exists in database
      const { data: existingStreamer } = await supabase
        .from("streamers")
        .select("id")
        .eq("id", parseInt(streamerId))
        .single();

      if (existingStreamer) {
        console.log(`Streamer ${streamerData.login} already exists, skipping`);
        continue;
      }

      console.log(`New streamer found: ${streamerData.login} (${streamerId})`);

      // Fetch full user profile from Helix
      const { data: users } = await twitchApiCall("users", {
        id: streamerId,
      });

      if (!users || users.length === 0) {
        console.log(`Could not fetch user details for ${streamerId}`);
        continue;
      }

      const user = users[0];

      // Insert new streamer into database with processing enabled
      const { error: insertError } = await supabase.from("streamers").insert({
        id: parseInt(user.id),
        login: user.login,
        display_name: user.display_name,
        profile_image_url: user.profile_image_url,
        processing_enabled: true,
      });

      if (insertError) {
        console.error(
          `Error inserting streamer ${user.login}:`,
          insertError,
        );
        log("error", "Failed to insert new streamer", {
          streamer_id: user.id,
          login: user.login,
          error: insertError.message,
        });
      } else {
        newStreamersDiscovered++;
        console.log(
          `✓ Inserted new streamer: ${user.login}`,
        );

        // Record telemetry for new streamer
        recordCounter("streamers.inserted", 1, {
          login: user.login,
        });
        log("info", "Inserted new streamer", {
          streamer_id: user.id,
          login: user.login,
          display_name: user.display_name,
        });

        // Create EventSub subscription for the new processing-enabled streamer
        await ensureEventSubSubscription(parseInt(user.id), user.login);
      }

      // Rate limiting: wait 100ms between streamer checks
      await new Promise((resolve) => setTimeout(resolve, 100));
    }

    console.log(`
Summary:
  Streamers checked: ${streamersChecked}
  New streamers discovered: ${newStreamersDiscovered}
    `);

    // Record summary telemetry
    log("info", "insert-new-streamers completed", {
      streamers_checked: streamersChecked,
      new_streamers_discovered: newStreamersDiscovered,
    });
  } catch (error: any) {
    console.error("Error in insertNewStreamers:", error);
    log("error", "insert-new-streamers failed", {
      error: error.message,
    });
    throw error;
  }

  return {
    newStreamersDiscovered,
    streamersChecked,
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
        }
      );
    }

    if (req.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    const result = await insertNewStreamers();

    return new Response(JSON.stringify(result), {
      headers: { "Content-Type": "application/json" },
      status: 200,
    });
  } catch (error: any) {
    console.error("Insert new streamers function error:", error);
    return new Response(
      JSON.stringify({ error: error.message }),
      {
        headers: { "Content-Type": "application/json" },
        status: 500,
      },
    );
  }
});

/* To invoke locally:

  1. Run `supabase start` (see: https://supabase.com/docs/reference/cli/supabase-start)
  2. Make an HTTP request:

  curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/insert-new-streamers' \
    --header 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0' \
    --header 'Content-Type: application/json' \
    --data '{}'

*/
