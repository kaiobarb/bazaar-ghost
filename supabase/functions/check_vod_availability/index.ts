import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { supabase } from "../_shared/supabase.ts";
import { getTwitchToken } from "../_shared/twitch.ts";

const TWITCH_CLIENT_ID = Deno.env.get("TWITCH_CLIENT_ID")!;

async function checkVodBatch(vodIds: string[]): Promise<Record<string, boolean>> {
  const token = await getTwitchToken();
  const results: Record<string, boolean> = {};

  const url = new URL("https://api.twitch.tv/helix/videos");

  // Add each ID as a separate query parameter (not comma-separated!)
  for (const id of vodIds) {
    url.searchParams.append("id", id);
  }

  console.log(`Checking ${vodIds.length} VODs with URL: ${url.toString()}`);

  try {
    const response = await fetch(url.toString(), {
      method: "GET",
      headers: {
        "Client-Id": TWITCH_CLIENT_ID,
        Authorization: `Bearer ${token}`,
        Accept: "application/json",
      },
    });

    console.log(`Response status: ${response.status}`);

    // Initialize all VODs as unavailable
    for (const vodId of vodIds) {
      results[vodId] = false;
    }

    if (response.ok) {
      const data = await response.json();
      console.log(`API returned ${data.data?.length || 0} available VODs out of ${vodIds.length} requested`);

      // Mark returned VODs as available
      if (data.data) {
        for (const vod of data.data) {
          results[vod.id] = true;
          console.log(`✓ VOD ${vod.id} is available: "${vod.title}" by ${vod.user_name}`);
        }
      }

      // Log which VODs were NOT found
      const unavailable = vodIds.filter(id => !results[id]);
      if (unavailable.length > 0) {
        console.log(`✗ ${unavailable.length} VODs not found: ${unavailable.join(", ")}`);
      }
    } else {
      const errorText = await response.text();
      console.error(`API error response: ${errorText}`);
    }
  } catch (error) {
    console.error(`Error checking VOD batch:`, error);
    // All VODs remain marked as unavailable
  }

  return results;
}

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    console.log("=== Starting VOD availability check ===");

    // Get VODs that need availability check
    const { data: vodsToCheck, error: fetchError } = await supabase
      .from("vods")
      .select("id, source_id, title, streamer_id")
      .eq("source", "twitch")
      .eq("availability", "available")
      .or(
        `last_availability_check.is.null,last_availability_check.lt.${
          new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()
        }`
      )
      .limit(100)
      .order("last_availability_check", { ascending: true, nullsFirst: true });

    if (fetchError) {
      throw new Error(`Failed to fetch VODs: ${fetchError.message}`);
    }

    if (!vodsToCheck || vodsToCheck.length === 0) {
      console.log("No VODs need availability check");
      return new Response(
        JSON.stringify({
          message: "No VODs need availability check",
          checked: 0,
          markedUnavailable: 0,
          stillAvailable: 0
        }),
        {
          headers: { "Content-Type": "application/json" },
          status: 200
        }
      );
    }

    console.log(`Found ${vodsToCheck.length} VODs to check`);

    // Extract Twitch VOD IDs
    const twitchIds = vodsToCheck.map(v => v.source_id);

    // Check availability in batches of 100 (Twitch API limit)
    const results = await checkVodBatch(twitchIds);

    let markedUnavailable = 0;
    let stillAvailable = 0;

    // Update database based on results
    for (const vod of vodsToCheck) {
      const isAvailable = results[vod.source_id];

      if (!isAvailable) {
        // Mark as unavailable
        const { error: updateError } = await supabase
          .from("vods")
          .update({
            availability: "unavailable",
            unavailable_since: new Date().toISOString(),
            last_availability_check: new Date().toISOString(),
          })
          .eq("id", vod.id);

        if (updateError) {
          console.error(`Failed to update VOD ${vod.id}:`, updateError);
        } else {
          markedUnavailable++;
          console.log(`Marked VOD ${vod.source_id} (${vod.title}) as unavailable`);
        }
      } else {
        // Just update the last check timestamp
        const { error: updateError } = await supabase
          .from("vods")
          .update({
            last_availability_check: new Date().toISOString(),
          })
          .eq("id", vod.id);

        if (updateError) {
          console.error(`Failed to update VOD ${vod.id}:`, updateError);
        } else {
          stillAvailable++;
        }
      }
    }

    console.log(`=== Check complete ===`);
    console.log(`Checked: ${vodsToCheck.length}`);
    console.log(`Still available: ${stillAvailable}`);
    console.log(`Marked unavailable: ${markedUnavailable}`);

    return new Response(
      JSON.stringify({
        message: "VOD availability check complete",
        checked: vodsToCheck.length,
        markedUnavailable,
        stillAvailable,
        details: {
          vodsChecked: vodsToCheck.map(v => ({
            id: v.source_id,
            title: v.title,
            available: results[v.source_id]
          }))
        }
      }),
      {
        headers: { "Content-Type": "application/json" },
        status: 200,
      }
    );
  } catch (error: any) {
    console.error("VOD availability check error:", error);
    return new Response(
      JSON.stringify({ error: error.message }),
      {
        headers: { "Content-Type": "application/json" },
        status: 500,
      }
    );
  }
});

/* To invoke locally:

  1. Run `supabase start` (see: https://supabase.com/docs/reference/cli/supabase-start)
  2. Make sure your environment variables are set (TWITCH_CLIENT_ID, TWITCH_CLIENT_SECRET)
  3. Make an HTTP request:

  curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/check_vod_availability' \
    --header "Authorization: Bearer $SUPABASE_PUBLISHABLE_KEY" \
    --header 'Content-Type: application/json' \
    --header "apikey: $SUPABASE_PUBLISHABLE_KEY" \
    --data '{}'

*/