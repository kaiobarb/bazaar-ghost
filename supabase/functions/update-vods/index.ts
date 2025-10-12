// Follow this setup guide to integrate the Deno language server with your editor:
// https://deno.land/manual/getting_started/setup_your_environment
// This enables autocomplete, go to definition, etc.

// Setup type definitions for built-in Supabase Runtime APIs
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { supabase } from "../_shared/supabase.ts";
import {
  twitchApiCall,
  getBazaarGameId,
  batchCheckVodAvailability,
} from "../_shared/twitch.ts";

interface UpdateVodsResult {
  vodsDiscovered: number;
  vodsUpdated: number;
  streamersDiscovered: number;
  availabilityChecks: number;
  vodsMarkedUnavailable: number;
}

async function updateVods(): Promise<UpdateVodsResult> {
  const runId = crypto.randomUUID();

  // Start cataloger run
  await supabase.from("cataloger_runs").insert({
    id: runId,
    run_type: "refresh",
    started_at: new Date().toISOString(),
  });

  let vodsDiscovered = 0;
  let vodsUpdated = 0;
  let streamersDiscovered = 0;
  let availabilityChecks = 0;
  let vodsMarkedUnavailable = 0;

  const streamersSet = new Set<string>(); // Track unique streamers

  try {
    // Get The Bazaar game ID first
    const bazaarGameId = await getBazaarGameId();

    console.log("Fetching recent Bazaar VODs...");

    let cursor: string | undefined;
    let pageCount = 0;
    const maxPages = 5; // Limit to 5 pages (500 VODs) for daily updates
    let allVods: any[] = [];

    // Fetch VODs with pagination
    do {
      const params: Record<string, string> = {
        game_id: bazaarGameId,
        first: "100",
        type: "archive", // Get only vods
        sort: "time"
      };

      // Add cursor for pagination
      if (cursor) {
        params.after = cursor;
      }

      console.log(`Fetching VODs for The Bazaar (page ${pageCount + 1})...`);
      const { data: vods, pagination } = await twitchApiCall("videos", params);

      console.log(`Got ${vods?.length || 0} VODs on page ${pageCount + 1}`);

      // Add VODs to our collection
      if (vods) {
        allVods = allVods.concat(vods);
      }

      cursor = pagination?.cursor;
      pageCount++;
    } while (cursor && pageCount < maxPages);

    console.log(`Got ${allVods.length} total recent VODs`);

    // Process all VODs
    for (const vod of allVods) {
      // Parse duration (format: "1h2m3s")
      const durationMatch = vod.duration.match(
        /(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?/
      );
      const hours = parseInt(durationMatch?.[1] || "0");
      const minutes = parseInt(durationMatch?.[2] || "0");
      const seconds = parseInt(durationMatch?.[3] || "0");
      const durationSeconds = hours * 3600 + minutes * 60 + seconds;

      // Skip VODs shorter than 10 minutes (600 seconds)
      if (durationSeconds < 600) {
        console.log(
          `Skipping short VOD ${vod.id}: ${vod.duration} (${durationSeconds}s)`
        );
        continue;
      }

      // Handle streamers - check if we need to get user details
      if (!streamersSet.has(vod.user_id)) {
        streamersSet.add(vod.user_id);

        // Check if streamer exists
        const { data: existingStreamer } = await supabase
          .from("streamers")
          .select("id")
          .eq("id", parseInt(vod.user_id))
          .single();

        if (!existingStreamer) {
          // Get full user details including profile image
          const { data: users } = await twitchApiCall("users", {
            id: vod.user_id,
          });

          if (users && users.length > 0) {
            const user = users[0];

            // Upsert the streamer with full profile data
            const { error: streamerError } = await supabase
              .from("streamers")
              .upsert(
                {
                  id: parseInt(user.id),
                  login: user.login,
                  display_name: user.display_name,
                  profile_image_url: user.profile_image_url,
                  last_seen_streaming_bazaar: new Date().toISOString(),
                },
                {
                  onConflict: "id",
                  ignoreDuplicates: false,
                }
              );

            if (!streamerError) {
              streamersDiscovered++;
              console.log(`Created new streamer: ${user.login}`);
            }
          }
        } else {
          // Update last seen timestamp for existing streamer
          await supabase
            .from("streamers")
            .update({
              last_seen_streaming_bazaar: new Date().toISOString(),
            })
            .eq("id", parseInt(vod.user_id));
        }
      }

      // Upsert VOD - this handles both new and existing records
      const { error: vodError } = await supabase.from("vods").upsert(
        {
          streamer_id: parseInt(vod.user_id),
          source: "twitch",
          source_id: vod.id,
          title: vod.title,
          duration_seconds: durationSeconds,
          published_at: vod.published_at,
          availability: "available", // Fresh from API, so it's available
          last_availability_check: new Date().toISOString(),
          ready_for_processing: false, // Require manual approval
        },
        {
          onConflict: "source,source_id",
          ignoreDuplicates: false,
        }
      );

      if (!vodError) {
        vodsDiscovered++;
      } else {
        console.error(`Error upserting VOD ${vod.id}:`, vodError);
      }
    }

    // Now check availability of existing VODs that haven't been checked recently
    console.log("Checking availability of existing VODs...");

    const { data: existingVods } = await supabase
      .from("vods")
      .select("source_id, id")
      .eq("source", "twitch")
      .eq("availability", "available")
      .or(
        "last_availability_check.is.null,last_availability_check.lt." +
          new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()
      ) // Older than 24 hours
      .limit(1000); // Limit to avoid overwhelming the API

    if (existingVods && existingVods.length > 0) {
      const vodIds = existingVods.map((vod) => vod.source_id);
      console.log(
        `Checking availability for ${vodIds.length} existing VODs...`
      );

      const availabilityResults = await batchCheckVodAvailability(vodIds);
      availabilityChecks = vodIds.length;

      // Update VOD availability status
      for (const vod of existingVods) {
        const isAvailable = availabilityResults[vod.source_id];

        if (!isAvailable) {
          // Mark as unavailable
          await supabase
            .from("vods")
            .update({
              availability: "unavailable",
              unavailable_since: new Date().toISOString(),
              last_availability_check: new Date().toISOString(),
            })
            .eq("id", vod.id);

          vodsMarkedUnavailable++;
          console.log(`Marked VOD ${vod.source_id} as unavailable`);
        } else {
          // Update last check timestamp
          await supabase
            .from("vods")
            .update({
              last_availability_check: new Date().toISOString(),
            })
            .eq("id", vod.id);
        }
      }
    }

    console.log(
      `Update complete: ${vodsDiscovered} VODs discovered, ${streamersDiscovered} streamers created, ${availabilityChecks} availability checks, ${vodsMarkedUnavailable} VODs marked unavailable`
    );

    // Update cataloger run with success
    await supabase
      .from("cataloger_runs")
      .update({
        completed_at: new Date().toISOString(),
        vods_discovered: vodsDiscovered,
        streamers_discovered: streamersDiscovered,
        status: "completed",
        metadata: {
          vodsUpdated,
          availabilityChecks,
          vodsMarkedUnavailable,
        },
      })
      .eq("id", runId);
  } catch (error: any) {
    console.error("Update VODs error:", error);

    // Log error to cataloger run
    await supabase
      .from("cataloger_runs")
      .update({
        completed_at: new Date().toISOString(),
        status: "failed",
        errors: [
          { message: error.message, timestamp: new Date().toISOString() },
        ],
      })
      .eq("id", runId);

    throw error;
  }

  return {
    vodsDiscovered,
    vodsUpdated,
    streamersDiscovered,
    availabilityChecks,
    vodsMarkedUnavailable,
  };
}

serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    const result = await updateVods();

    return new Response(JSON.stringify(result), {
      headers: { "Content-Type": "application/json" },
      status: 200,
    });
  } catch (error) {
    console.error("Update VODs function error:", error);
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { "Content-Type": "application/json" },
      status: 500,
    });
  }
});

/* To invoke locally:

  1. Run `supabase start` (see: https://supabase.com/docs/reference/cli/supabase-start)
  2. Make an HTTP request:

  curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/update-vods' \
    --header 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0' \
    --header 'Content-Type: application/json' \
    --data '{}'

*/
