// Follow this setup guide to integrate the Deno language server with your editor:
// https://deno.land/manual/getting_started/setup_your_environment
// This enables autocomplete, go to definition, etc.

// Setup type definitions for built-in Supabase Runtime APIs
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { supabase } from "../_shared/supabase.ts";
import { twitchApiCall, getBazaarGameId, getTwitchToken } from "../_shared/twitch.ts";

interface GetVodsFromStreamerResult {
  vodsDiscovered: number;
  vodsInserted: number;
  vodsWouldBeInserted?: number;
  vodsAlreadyExist?: number;
  streamerLogin: string;
  streamerId: number;
  dryRun: boolean;
}

async function getVodsFromStreamer(streamerId: string, dryRun: boolean = false): Promise<GetVodsFromStreamerResult> {
  let vodsDiscovered = 0;
  let vodsInserted = 0;
  let vodsWouldBeInserted = 0;
  let vodsAlreadyExist = 0;
  let streamerLogin = "";

  try {
    // First, get the streamer info if we don't have it
    const { data: users } = await twitchApiCall("users", {
      id: streamerId,
    });

    if (!users || users.length === 0) {
      throw new Error(`Streamer with ID ${streamerId} not found`);
    }

    const user = users[0];
    streamerLogin = user.login;
    console.log(`Fetching VODs for streamer: ${user.login} (${streamerId})`);

    if (dryRun) {
      console.log(`[DRY RUN] Would upsert streamer: ${user.login} (${user.id})`);
    } else {
      // Upsert the streamer data
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

      if (streamerError) {
        console.error(`Error upserting streamer:`, streamerError);
      }
    }

    // Fetch ALL VODs for this specific streamer
    // Since this function is for known Bazaar streamers, we'll get all their VODs
    let cursor: string | undefined;
    let pageCount = 0;
    const maxPages = 1; // Allow more pages since we're targeting a specific streamer
    let allVods: any[] = [];

    do {
      const params: Record<string, string> = {
        user_id: streamerId,
        first: "10",
        type: "archive", // Get only vods, not highlights or uploads
      };

      // Add cursor for pagination
      if (cursor) {
        params.after = cursor;
      }

      console.log(`Fetching VODs page ${pageCount + 1} for ${user.login}...`);
      const { data: vods, pagination } = await twitchApiCall("videos", params);

      console.log(`Got ${vods?.length || 0} VODs on page ${pageCount + 1}`);

      // Add VODs to our collection
      if (vods && vods.length > 0) {
        allVods = allVods.concat(vods);
      }

      cursor = pagination?.cursor;
      pageCount++;

      // If we got no VODs on this page, stop pagination
      if (!vods || vods.length === 0) {
        break;
      }
    } while (cursor && pageCount < maxPages);

    console.log(`Found ${allVods.length} total VODs for ${user.login}`);
    vodsDiscovered = allVods.length;

    // TEST: Check if we can get game_id from VOD details
    if (dryRun && allVods.length > 0) {
      console.log("[DRY RUN TEST] Testing game_id filtering with first 10 VODs...");

      // Get The Bazaar game ID
      const bazaarGameId = await getBazaarGameId();
      console.log(`[DRY RUN TEST] Bazaar game ID: ${bazaarGameId}`);

      // Take first 10 VODs as a sample
      // const sampleVods = allVods.slice(0, 10);
      const vodIds = allVods.map(v => v.id);

      // Fetch detailed info for these VODs
      const token = await getTwitchToken();
      const url = new URL("https://api.twitch.tv/helix/videos");

      // Add each ID as a separate query parameter
      for (const id of vodIds) {
        url.searchParams.append("id", id);
      }

      const response = await fetch(url.toString(), {
        method: "GET",
        headers: {
          "Client-Id": Deno.env.get("TWITCH_CLIENT_ID")!,
          Authorization: `Bearer ${token}`,
          Accept: "application/json",
        },
      });

      if (response.ok) {
        const detailedData = await response.json();
        console.log(`[DRY RUN TEST] Got details for ${detailedData.data?.length || 0} VODs`);
        console.log(detailedData.data)

        // Check which VODs have game_id
        let bazaarVodCount = 0;
        for (const vod of detailedData.data || []) {
          console.log(`[DRY RUN TEST] VOD ${vod.id}: game_id=${vod.game_id}, title="${vod.title}"`);
          if (vod.game_id === bazaarGameId) {
            bazaarVodCount++;
            console.log(`  ^ This is a Bazaar VOD!`);
          }
        }

        console.log(`[DRY RUN TEST] Found ${bazaarVodCount} Bazaar VODs out of ${vodIds.length} sampled`);
      } else {
        console.error(`[DRY RUN TEST] Failed to fetch VOD details: ${response.status}`);
      }
    }

    // Process all VODs
    // for (const vod of allVods) {
    //   // Parse duration (format: "1h2m3s")
    //   const durationMatch = vod.duration.match(
    //     /(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?/
    //   );
    //   const hours = parseInt(durationMatch?.[1] || "0");
    //   const minutes = parseInt(durationMatch?.[2] || "0");
    //   const seconds = parseInt(durationMatch?.[3] || "0");
    //   const durationSeconds = hours * 3600 + minutes * 60 + seconds;

    //   // Skip VODs shorter than 10 minutes (600 seconds)
    //   if (durationSeconds < 600) {
    //     console.log(
    //       `Skipping short VOD ${vod.id}: ${vod.duration} (${durationSeconds}s)`
    //     );
    //     continue;
    //   }

    //   // Check if this VOD already exists
    //   const { data: existingVod } = await supabase
    //     .from("vods")
    //     .select("id")
    //     .eq("source", "twitch")
    //     .eq("source_id", vod.id)
    //     .single();

    //   if (existingVod) {
    //     vodsAlreadyExist++;
    //     if (dryRun) {
    //       console.log(`[DRY RUN] VOD ${vod.id} already exists, would update: ${vod.title}`);
    //     } else {
    //       console.log(`VOD ${vod.id} already exists, updating...`);
    //       // Update existing VOD
    //       const { error: updateError } = await supabase
    //         .from("vods")
    //         .update({
    //           title: vod.title,
    //           duration_seconds: durationSeconds,
    //           availability: "available",
    //           last_availability_check: new Date().toISOString(),
    //         })
    //         .eq("id", existingVod.id);

    //       if (updateError) {
    //         console.error(`Error updating VOD ${vod.id}:`, updateError);
    //       }
    //     }
    //   } else {
    //     // New VOD would be inserted
    //     if (dryRun) {
    //       vodsWouldBeInserted++;
    //       console.log(`[DRY RUN] Would insert VOD ${vod.id}: ${vod.title}`);
    //     } else {
    //       // Insert new VOD
    //       const { error: vodError } = await supabase.from("vods").insert({
    //         streamer_id: parseInt(streamerId),
    //         source: "twitch",
    //         source_id: vod.id,
    //         title: vod.title,
    //         duration_seconds: durationSeconds,
    //         published_at: vod.published_at,
    //         availability: "available",
    //         last_availability_check: new Date().toISOString(),
    //         ready_for_processing: false, // Require manual approval
    //       });

    //       if (!vodError) {
    //         vodsInserted++;
    //         console.log(`Inserted VOD ${vod.id}: ${vod.title}`);
    //       } else {
    //         console.error(`Error inserting VOD ${vod.id}:`, vodError);
    //       }
    //     }
    //   }
    // }

    if (dryRun) {
      console.log(
        `[DRY RUN] Completed: ${vodsDiscovered} VODs discovered, ${vodsWouldBeInserted} would be inserted, ${vodsAlreadyExist} already exist for ${user.login}`
      );
    } else {
      console.log(
        `Completed: ${vodsDiscovered} VODs discovered, ${vodsInserted} new VODs inserted for ${user.login}`
      );
    }

  } catch (error: any) {
    console.error("Get VODs from streamer error:", error);
    throw error;
  }

  const result: GetVodsFromStreamerResult = {
    vodsDiscovered,
    vodsInserted,
    streamerLogin,
    streamerId: parseInt(streamerId),
    dryRun,
  };

  if (dryRun) {
    result.vodsWouldBeInserted = vodsWouldBeInserted;
    result.vodsAlreadyExist = vodsAlreadyExist;
  }

  return result;
}

serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    const { streamerId, dryRun = false } = await req.json();

    if (!streamerId) {
      return new Response(
        JSON.stringify({ error: "streamerId is required" }),
        {
          headers: { "Content-Type": "application/json" },
          status: 400,
        }
      );
    }

    const result = await getVodsFromStreamer(streamerId, dryRun);

    return new Response(JSON.stringify(result), {
      headers: { "Content-Type": "application/json" },
      status: 200,
    });
  } catch (error) {
    console.error("Get VODs from streamer function error:", error);
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { "Content-Type": "application/json" },
      status: 500,
    });
  }
});

/* To invoke locally:

  1. Run `supabase start` (see: https://supabase.com/docs/reference/cli/supabase-start)
  2. Make an HTTP request:

  # Regular run (will insert VODs):
  curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/get_vods_from_streamer' \
    --header 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0' \
    --header 'Content-Type: application/json' \
    --data '{"streamerId":"29795919"}'

  # Dry run (shows what would be added without inserting):
  curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/get_vods_from_streamer' \
    --header 'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0' \
    --header 'Content-Type: application/json' \
    --data '{"streamerId":"29795919", "dryRun": true}'

  Note: 29795919 is the Twitch ID for nl_kripp
  This function fetches ALL VODs from the streamer, not just Bazaar ones.
  Use this for known Bazaar streamers who are already vetted.
*/
