// Setup type definitions for built-in Supabase Runtime APIs
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { supabase, verifySecretKey } from "../_shared/supabase.ts";
import {
  getBazaarGameId,
  getStreamerIdByLogin,
  getStreamerVodsWithChapters,
  getVodsFromStreamer,
} from "../_shared/twitch.ts";

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
 * Extract Bazaar chapter time ranges from VOD chapters
 * Returns array in format: [start1_sec, end1_sec, start2_sec, end2_sec, ...]
 */
function extractBazaarChapters(
  chapters: any[],
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

/**
 * Update VODs for a specific streamer using GraphQL API
 * Fetches VODs with chapter data and stores only those with Bazaar gameplay
 */
async function updateVods(streamerId: number): Promise<UpdateVodsResult> {
  let totalVodsFetched = 0;
  let vodsWithBazaar = 0;
  let vodsInserted = 0;
  let totalBazaarSegments = 0;

  try {
    // Get streamer info from database
    const { data: streamer, error: streamerError } = await supabase
      .from("streamers")
      .select("id, login, display_name")
      .eq("id", streamerId)
      .single();

    if (streamerError || !streamer) {
      throw new Error(`Streamer with ID ${streamerId} not found in database`);
    }

    console.log(
      `Fetching VODs for streamer: ${streamer.login} (${streamerId})`,
    );

    // Get The Bazaar game ID
    const bazaarGameId = await getBazaarGameId();
    console.log(`The Bazaar game ID: ${bazaarGameId}`);

    // Quick check: Get streamer's Twitch ID and check if they have more than 1 VOD
    // This avoids expensive GraphQL chapter fetching for streamers who don't save VODs
    console.log("Checking VOD count before fetching chapter data...");
    const twitchUserId = await getStreamerIdByLogin(streamer.login);

    if (!twitchUserId) {
      throw new Error(`Could not find Twitch user ID for ${streamer.login}`);
    }

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

    // Fetch all VODs with chapter data via GraphQL
    const vodsWithChapters = await getStreamerVodsWithChapters(
      streamer.login,
    );

    totalVodsFetched = vodsWithChapters.length;
    console.log(`Fetched ${totalVodsFetched} total VODs for ${streamer.login}`);

    // Process each VOD
    for (const vod of vodsWithChapters) {
      console.log(`Processing VOD ${vod.id}: ${vod.title}`);

      // Extract Bazaar chapter time ranges
      let bazaarChapters = extractBazaarChapters(
        vod.chapters,
        vod.lengthSeconds,
        bazaarGameId,
      );

      // Fallback: If no chapters found but VOD's main game is The Bazaar,
      // treat the entire VOD as a Bazaar segment
      if (bazaarChapters.length === 0) {
        const isBazaarGame = vod.game?.id === bazaarGameId ||
          vod.game?.name?.toLowerCase().includes("bazaar");

        if (isBazaarGame) {
          console.log(
            `  No chapters, but VOD game is The Bazaar - treating entire VOD as Bazaar segment`,
          );
          bazaarChapters = [0, vod.lengthSeconds];
        } else {
          console.log(`  No Bazaar gameplay found in VOD ${vod.id}, skipping`);
          continue;
        }
      }

      vodsWithBazaar++;
      totalBazaarSegments += bazaarChapters.length / 2; // Each segment = 2 numbers

      console.log(
        `  VOD ${vod.id} has ${bazaarChapters.length / 2} Bazaar segment(s)`,
      );

      // Upsert VOD to database
      const { error: vodError } = await supabase.from("vods").upsert(
        {
          streamer_id: streamerId,
          source: "twitch",
          source_id: vod.id,
          title: vod.title,
          duration_seconds: vod.lengthSeconds,
          published_at: vod.publishedAt,
          bazaar_chapters: bazaarChapters,
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

      if (vodError) {
        console.error(`Error upserting VOD ${vod.id}:`, vodError);
      } else {
        vodsInserted++;
        console.log(`✓ Upserted VOD ${vod.id} with Bazaar chapters`);
      }
    }

    // Calculate oldest VOD timestamp from all VODs
    let oldestVod: string | null = null;
    if (vodsWithChapters.length > 0) {
      oldestVod = vodsWithChapters.reduce((oldest, vod) => {
        return !oldest || vod.publishedAt < oldest ? vod.publishedAt : oldest;
      }, null as string | null);
    }

    // Update streamer statistics
    await supabase
      .from("streamers")
      .update({
        has_vods: true,
        num_vods: totalVodsFetched,
        num_bazaar_vods: vodsWithBazaar,
        oldest_vod: oldestVod,
        updated_at: new Date().toISOString(),
      })
      .eq("id", streamerId);

    console.log(`
Summary for ${streamer.login}:
  Total VODs fetched: ${totalVodsFetched}
  VODs with Bazaar gameplay: ${vodsWithBazaar}
  VODs inserted/updated: ${vodsInserted}
  Total Bazaar segments: ${totalBazaarSegments}
  Oldest VOD: ${oldestVod || "N/A"}
    `);

    return {
      streamerLogin: streamer.login,
      totalVodsFetched,
      vodsWithBazaar,
      vodsInserted,
      totalBazaarSegments,
    };
  } catch (error: any) {
    console.error("Update VODs error:", error);
    throw error;
  }
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
