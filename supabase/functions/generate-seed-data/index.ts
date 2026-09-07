import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { supabase, verifySecretKey } from "../_shared/supabase.ts";

function literal(value: unknown): string {
  if (value == null) return "NULL";
  if (typeof value === "boolean" || typeof value === "number") {
    return String(value);
  }
  if (Array.isArray(value)) {
    return `ARRAY[${value.map(literal).join(",")}]::numeric[]`;
  }
  return `'${String(value).replaceAll("'", "''")}'`;
}

/** Export a small catalog using the current schema, with automatic processing disabled. */
Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }
  if (!verifySecretKey(req)) {
    return new Response("Unauthorized", { status: 401 });
  }
  try {
    const { data: vods, error } = await supabase.from("vods")
      .select(
        "source, source_id, streamer_id, title, duration_seconds, published_at, bazaar_chapters",
      )
      .order("published_at", { ascending: false }).limit(10);
    if (error) throw new Error(error.message);
    const ids = [...new Set((vods || []).map((vod) => vod.streamer_id))];
    const { data: streamers, error: streamerError } = await supabase.from(
      "streamers",
    )
      .select("id, login, display_name, profile_image_url, sfde_profile_id").in(
        "id",
        ids,
      );
    if (streamerError) throw new Error(streamerError.message);
    const profileIds = [
      ...new Set((streamers || []).map((streamer) => streamer.sfde_profile_id)),
    ];
    const { data: profiles, error: profileError } = await supabase.from(
      "sfde_profiles",
    )
      .select(
        "id, profile_name, crop_region, scale, custom_edge, opaque_edge, igd_crop_region",
      ).in("id", profileIds);
    if (profileError) throw new Error(profileError.message);
    const sql = ["-- Local catalog seed; processing stays disabled.", "BEGIN;"];
    for (const profile of profiles || []) {
      sql.push(
        `INSERT INTO public.sfde_profiles (${
          Object.keys(profile).join(",")
        }) OVERRIDING SYSTEM VALUE VALUES (${
          Object.values(profile).map(literal).join(",")
        }) ON CONFLICT (id) DO NOTHING;`,
      );
    }
    for (const streamer of streamers || []) {
      sql.push(
        `INSERT INTO public.streamers (${
          Object.keys(streamer).join(",")
        },processing_enabled) VALUES (${
          Object.values(streamer).map(literal).join(",")
        },false) ON CONFLICT (id) DO NOTHING;`,
      );
    }
    for (const vod of vods || []) {
      const chapters = `ARRAY[${
        (vod.bazaar_chapters || []).join(",")
      }]::integer[]`;
      const { bazaar_chapters: _, ...fields } = vod;
      sql.push(
        `INSERT INTO public.vods (${
          Object.keys(fields).join(",")
        },bazaar_chapters,ready_for_processing) VALUES (${
          Object.values(fields).map(literal).join(",")
        },${chapters},false) ON CONFLICT (source,source_id) DO NOTHING;`,
      );
    }
    sql.push(
      "SELECT setval('public.sfde_profiles_id_seq', COALESCE((SELECT MAX(id) FROM public.sfde_profiles), 1), EXISTS(SELECT 1 FROM public.sfde_profiles));",
      "COMMIT;",
    );
    const result = {
      streamers: streamers?.length || 0,
      vods: vods?.length || 0,
      sql: sql.join("\n"),
    };
    return new URL(req.url).searchParams.get("format") === "json"
      ? Response.json(result)
      : new Response(result.sql, {
        headers: { "Content-Type": "text/plain; charset=utf-8" },
      });
  } catch (error: any) {
    return Response.json({ error: error.message }, { status: 500 });
  }
});
