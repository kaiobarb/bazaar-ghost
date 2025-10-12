// Follow this setup guide to integrate the Deno language server with your editor:
// https://deno.land/manual/getting_started/setup_your_environment
// This enables autocomplete, go to definition, etc.

// Setup type definitions for built-in Supabase Runtime APIs
import "jsr:@supabase/functions-js/edge-runtime.d.ts"

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import {
  twitchApiCall,
  getBazaarGameId,
} from "../_shared/twitch.ts";

interface GenerateSeedResult {
  streamers: number;
  vods: number;
  sql: string;
}

function escapeString(str: string | null): string {
  if (str === null) return "NULL";
  // Escape single quotes by doubling them
  return `'${str.replace(/'/g, "''")}'`;
}

function formatTimestamp(date: string | null): string {
  if (!date) return "NULL";
  return `'${date}'`;
}

async function generateSeedData(): Promise<GenerateSeedResult> {
  const streamersMap = new Map<string, any>();
  const vodsArray: any[] = [];

  try {
    // Get The Bazaar game ID first
    const bazaarGameId = await getBazaarGameId();

    console.log("Fetching recent 10 Bazaar VODs...");

    // Fetch 10 VODs to seed db with
    const params: Record<string, string> = {
      game_id: bazaarGameId,
      first: "10",
      type: "archive"
    };

    const { data: vods } = await twitchApiCall("videos", params);

    console.log(`Got ${vods?.length || 0} VODs`);

    if (!vods || vods.length === 0) {
      throw new Error("No VODs found");
    }

    // Process VODs and collect unique streamer IDs
    for (const vod of vods) {
      // Parse duration (format: "1h2m3s")
      const durationMatch = vod.duration.match(
        /(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?/
      );
      const hours = parseInt(durationMatch?.[1] || "0");
      const minutes = parseInt(durationMatch?.[2] || "0");
      const seconds = parseInt(durationMatch?.[3] || "0");
      const durationSeconds = hours * 3600 + minutes * 60 + seconds;

      // Store VOD data
      vodsArray.push({
        streamer_id: parseInt(vod.user_id),
        source: "twitch",
        source_id: vod.id,
        title: vod.title,
        duration_seconds: durationSeconds,
        published_at: vod.published_at,
        availability: "available",
        ready_for_processing: true,
      });

      // Collect unique streamer IDs
      if (!streamersMap.has(vod.user_id)) {
        streamersMap.set(vod.user_id, {
          id: parseInt(vod.user_id),
          login: vod.user_login,
          display_name: vod.user_name,
        });
      }
    }

    // Get full streamer details
    console.log("Fetching streamer details...");
    const streamerIds = Array.from(streamersMap.keys());

    // Fetch all user details in one call
    const userParams: Record<string, string> = {};
    streamerIds.forEach(id => {
      userParams.id = id;
    });

    // Twitch API allows multiple id params
    const url = new URL("https://api.twitch.tv/helix/users");
    for (const id of streamerIds) {
      url.searchParams.append("id", id);
    }

    const { data: users } = await twitchApiCall("users?" + url.searchParams.toString().replace("https://api.twitch.tv/helix/users?", ""), {});

    if (users) {
      for (const user of users) {
        const streamerData = streamersMap.get(user.id);
        if (streamerData) {
          streamerData.login = user.login;
          streamerData.display_name = user.display_name;
          streamerData.profile_image_url = user.profile_image_url;
        }
      }
    }

    // Generate SQL statements
    let sql = `-- Generated seed data from latest Bazaar VODs
-- Generated at: ${new Date().toISOString()}

-- Clear existing data
TRUNCATE TABLE public.detections CASCADE;
TRUNCATE TABLE public.chunks CASCADE;
TRUNCATE TABLE public.vods CASCADE;
TRUNCATE TABLE public.streamers CASCADE;

`;

    // Generate streamers INSERT
    sql += "-- Streamers\n";
    sql += "INSERT INTO public.streamers (id, login, display_name, profile_image_url, processing_enabled, first_seen_at, last_seen_streaming_bazaar, total_vods, processed_vods, total_detections, created_at, updated_at) VALUES\n";

    const streamerValues: string[] = [];
    const now = new Date().toISOString();

    for (const [_, streamer] of streamersMap) {
      streamerValues.push(
        `(${streamer.id}, ${escapeString(streamer.login)}, ${escapeString(streamer.display_name)}, ${escapeString(streamer.profile_image_url)}, true, '${now}', '${now}', 0, 0, 0, '${now}', '${now}')`
      );
    }

    sql += streamerValues.join(",\n") + ";\n\n";

    // Generate VODs INSERT
    sql += "-- VODs\n";
    sql += "INSERT INTO public.vods (streamer_id, source, source_id, title, duration_seconds, published_at, availability, last_availability_check, ready_for_processing, created_at, updated_at) VALUES\n";

    const vodValues: string[] = [];

    for (const vod of vodsArray) {
      vodValues.push(
        `(${vod.streamer_id}, ${escapeString(vod.source)}, ${escapeString(vod.source_id)}, ${escapeString(vod.title)}, ${vod.duration_seconds}, ${formatTimestamp(vod.published_at)}, '${vod.availability}', '${now}', ${vod.ready_for_processing}, '${now}', '${now}')`
      );
    }

    sql += vodValues.join(",\n") + ";\n\n";

    // Add sequence updates
    sql += `-- Update sequences
SELECT setval('public.vods_id_seq', (SELECT MAX(id) FROM public.vods), true);
`;

    console.log(`Generated seed data with ${streamersMap.size} streamers and ${vodsArray.length} VODs`);

    return {
      streamers: streamersMap.size,
      vods: vodsArray.length,
      sql: sql,
    };
  } catch (error: any) {
    console.error("Generate seed data error:", error);
    throw error;
  }
}

serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    const result = await generateSeedData();

    // Return the SQL as plain text for easy copying
    const format = new URL(req.url).searchParams.get("format");

    if (format === "json") {
      return new Response(JSON.stringify(result), {
        headers: { "Content-Type": "application/json" },
        status: 200,
      });
    } else {
      // Default to returning just the SQL
      return new Response(result.sql, {
        headers: { "Content-Type": "text/plain" },
        status: 200,
      });
    }
  } catch (error) {
    console.error("Generate seed data function error:", error);
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { "Content-Type": "application/json" },
      status: 500,
    });
  }
});

/* To invoke locally and save to seed.sql:

  1. Run `supabase start`
  2. Generate seed data:

  # Get SQL directly:
  curl -s --location --request POST 'http://127.0.0.1:54321/functions/v1/generate-seed-data' \
    --header 'Authorization: Bearer YOUR_ANON_KEY' \
    --header 'Content-Type: application/json' \
    --data '{}' > supabase/seed.sql

  # Or get JSON response:
  curl --location --request POST 'http://127.0.0.1:54321/functions/v1/generate-seed-data?format=json' \
    --header 'Authorization: Bearer YOUR_ANON_KEY' \
    --header 'Content-Type: application/json' \
    --data '{}'

*/