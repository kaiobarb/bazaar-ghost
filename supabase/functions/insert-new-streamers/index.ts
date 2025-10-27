// Setup type definitions for built-in Supabase Runtime APIs
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { supabase } from "../_shared/supabase.ts";
import { getBazaarGameId, twitchApiCall } from "../_shared/twitch.ts";

interface InsertNewStreamersResult {
  newStreamersDiscovered: number;
  streamersChecked: number;
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

      // Insert new streamer into database
      const { error: insertError } = await supabase.from("streamers").insert({
        id: parseInt(user.id),
        login: user.login,
        display_name: user.display_name,
        profile_image_url: user.profile_image_url,
        // has_vods: hasVods,
        processing_enabled: false,
      });

      if (insertError) {
        console.error(
          `Error inserting streamer ${user.login}:`,
          insertError,
        );
      } else {
        newStreamersDiscovered++;
        console.log(
          `✓ Inserted new streamer: ${user.login}`,
        );
      }

      // Rate limiting: wait 100ms between streamer checks
      await new Promise((resolve) => setTimeout(resolve, 100));
    }

    console.log(`
Summary:
  Streamers checked: ${streamersChecked}
  New streamers discovered: ${newStreamersDiscovered}
    `);
  } catch (error: any) {
    console.error("Error in insertNewStreamers:", error);
    throw error;
  }

  return {
    newStreamersDiscovered,
    streamersChecked,
  };
}

serve(async (req) => {
  try {
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
