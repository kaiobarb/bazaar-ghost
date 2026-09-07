import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {
  fetchAndUpsertVods,
  supabase,
  verifySecretKey,
} from "../_shared/supabase.ts";
import { getStreamerById, isStreamerLive } from "../_shared/twitch.ts";
import { corsHeaders } from "../_shared/cors.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }
  if (!verifySecretKey(req)) {
    return new Response("Unauthorized", { status: 401 });
  }
  try {
    const { streamerId, dryRun = false } = await req.json();
    if (!/^\d+$/.test(String(streamerId)) || typeof dryRun !== "boolean") {
      return Response.json({
        error: "streamerId must be numeric and dryRun must be boolean",
      }, { status: 400 });
    }
    const user = await getStreamerById(String(streamerId));
    if (!user) {
      return Response.json({ error: "Streamer not found" }, { status: 404 });
    }
    if (!dryRun) {
      const { error } = await supabase.from("streamers").upsert({
        id: Number(user.id),
        login: user.login,
        display_name: user.display_name,
        profile_image_url: user.profile_image_url,
      }, { onConflict: "id" });
      if (error) throw new Error(error.message);
    }
    const result = await fetchAndUpsertVods(
      Number(user.id),
      user.login,
      undefined,
      await isStreamerLive(user.id),
      dryRun,
    );
    return Response.json({
      streamerId: Number(user.id),
      streamerLogin: user.login,
      dryRun,
      vodsDiscovered: result.totalVodsFetched,
      vodsInserted: dryRun ? 0 : result.vodsUpserted,
      vodsWouldBeInserted: dryRun ? result.vodsUpserted : undefined,
    }, { headers: corsHeaders });
  } catch (error: any) {
    return Response.json({ error: error.message }, {
      status: error instanceof SyntaxError ? 400 : 500,
      headers: corsHeaders,
    });
  }
});
