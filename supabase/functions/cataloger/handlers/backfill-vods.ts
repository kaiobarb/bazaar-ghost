import { supabase } from "../lib/supabase.ts";
import { twitchApiCall, getBazaarGameId } from "../lib/twitch.ts";

export async function backfillBazaarVODs() {
  const runId = crypto.randomUUID();

  // Start cataloger run
  await supabase.from("cataloger_runs").insert({
    id: runId,
    run_type: "backfill",
    started_at: new Date().toISOString(),
  });

  let vodsDiscovered = 0;
  let streamersDiscovered = 0;
  const streamersSet = new Set<string>(); // Track unique streamers

  try {
    // Get The Bazaar game ID first
    const bazaarGameId = await getBazaarGameId();

    let cursor: string | undefined;
    let pageCount = 0;
    const maxPages = 10; // Limit pagination to avoid excessive API calls

    // Fetch VODs directly using game_id parameter with pagination
    do {
      const params: Record<string, string> = {
        game_id: bazaarGameId,
        first: "100", // Max allowed per request
        type: "archive", // Get only past broadcasts
      };

      // Add cursor for pagination
      if (cursor) {
        params.after = cursor;
      }

      console.log(`Fetching VODs for The Bazaar (page ${pageCount + 1})...`);
      const { data: vods, pagination } = await twitchApiCall("videos", params);

      console.log(`Got ${vods?.length || 0} VODs on page ${pageCount + 1}`);

      // Process VODs
      for (const vod of vods || []) {
        // Track unique streamers
        if (!streamersSet.has(vod.user_id)) {
          streamersSet.add(vod.user_id);

          // Upsert the streamer
          const { error: streamerError } = await supabase.from("streamers").upsert(
            {
              id: parseInt(vod.user_id),
              login: vod.user_login,
              display_name: vod.user_name,
              last_seen_streaming_bazaar: new Date().toISOString(),
            },
            {
              onConflict: "id",
              ignoreDuplicates: false,
            }
          );

          if (!streamerError) {
            streamersDiscovered++;
          }
        }

        // Parse duration (format: "1h2m3s")
        const durationMatch = vod.duration.match(
          /(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?/
        );
        const hours = parseInt(durationMatch?.[1] || "0");
        const minutes = parseInt(durationMatch?.[2] || "0");
        const seconds = parseInt(durationMatch?.[3] || "0");
        const durationSeconds = hours * 3600 + minutes * 60 + seconds;

        // Upsert VOD
        const { error: vodError } = await supabase.from("vods").upsert(
          {
            streamer_id: parseInt(vod.user_id),
            source: "twitch",
            source_id: vod.id,
            title: vod.title,
            duration_seconds: durationSeconds,
            published_at: vod.published_at,
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

      cursor = pagination?.cursor;
      pageCount++;
    } while (cursor && pageCount < maxPages);

    console.log(
      `Backfill complete: discovered ${vodsDiscovered} VODs from ${streamersDiscovered} unique streamers`
    );

    // Update cataloger run
    await supabase
      .from("cataloger_runs")
      .update({
        completed_at: new Date().toISOString(),
        vods_discovered: vodsDiscovered,
        streamers_discovered: streamersDiscovered,
        status: "completed",
      })
      .eq("id", runId);
  } catch (error: any) {
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

  return { vodsDiscovered, streamersDiscovered };
}