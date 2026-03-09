-- View: vod_embed_info
-- One row per VOD with all data the embed panel needs:
-- VOD metadata (title, duration, chapters) + streamer info (name, avatar, login)

CREATE OR REPLACE VIEW "public"."vod_embed_info" AS
SELECT
    v.id              AS vod_id,
    v.source_id       AS vod_source_id,
    v.title,
    v.published_at,
    v.duration_seconds,
    v.bazaar_chapters,
    v.availability,
    s.id              AS streamer_id,
    s.login           AS streamer_login,
    s.display_name    AS streamer_display_name,
    s.profile_image_url AS streamer_avatar
FROM vods v
JOIN streamers s ON v.streamer_id = s.id;
