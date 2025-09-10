import { supabase } from "../lib/supabase.ts";
import { twitchApiCall } from "../lib/twitch.ts";

export async function discoverStreamers(gameId: string) {
  const runId = crypto.randomUUID();

  // Start cataloger run
  await supabase.from("cataloger_runs").insert({
    id: runId,
    run_type: "discovery",
    started_at: new Date().toISOString(),
  });

  let streamersDiscovered = 0;
  let streamersUpdated = 0;
  let cursor: string | undefined;

  try {
    // Get current live streams for The Bazaar
    do {
      const params: Record<string, string> = {
        game_id: gameId,
        first: "100",
      };
      if (cursor) params.after = cursor;

      const { data, pagination } = await twitchApiCall("streams", params);

      for (const stream of data) {
        // Get full user details
        const { data: users } = await twitchApiCall("users", {
          id: stream.user_id,
        });
        const user = users[0];

        // Upsert streamer
        const { error } = await supabase.from("streamers").upsert(
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

        if (error) {
          console.error(`Error upserting streamer ${user.login}:`, error);
        } else {
          streamersDiscovered++;
        }
      }

      cursor = pagination?.cursor;
    } while (cursor);

    // Update cataloger run
    await supabase
      .from("cataloger_runs")
      .update({
        completed_at: new Date().toISOString(),
        streamers_discovered: streamersDiscovered,
        streamers_updated: streamersUpdated,
        status: "completed",
      })
      .eq("id", runId);
  } catch (error) {
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

  return { streamersDiscovered, streamersUpdated };
}