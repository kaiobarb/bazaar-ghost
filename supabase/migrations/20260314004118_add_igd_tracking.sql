-- Add in-game day (IGD) tracking to detections and IGD crop region to SFDE profiles.
-- IGD is the day number (1-20) during which a ghost battle occurs.
-- The IGD crop region defines where in the full frame the day number appears.

-- Add igd column to detections
ALTER TABLE detections ADD COLUMN igd smallint;

-- Add igd_crop_region to sfde_profiles (same format as crop_region: [x%, y%, w%, h%])
ALTER TABLE sfde_profiles ADD COLUMN igd_crop_region numeric[];

-- Add length constraint matching crop_region's pattern
ALTER TABLE sfde_profiles ADD CONSTRAINT igd_crop_region_length
  CHECK (igd_crop_region IS NULL OR array_length(igd_crop_region, 1) = 4);

-- Update detection_search view to include igd
DROP VIEW IF EXISTS detection_search;
CREATE VIEW detection_search WITH (security_invoker = on) AS
SELECT
    d.id AS detection_id,
    d.username,
    d.frame_time_seconds,
    d.confidence,
    d.rank,
    d.storage_path,
    d.no_right_edge,
    d.truncated,
    d.igd,
    d.created_at AS detection_created_at,
    v.id AS vod_id,
    v.source_id AS vod_source_id,
    v.title AS vod_title,
    v.published_at AS vod_published_at,
    v.duration_seconds AS vod_duration_seconds,
    v.availability AS vod_availability,
    (v.published_at + (d.frame_time_seconds || ' seconds')::interval) AS actual_timestamp,
    s.id AS streamer_id,
    s.login AS streamer_login,
    s.display_name AS streamer_display_name,
    s.profile_image_url AS streamer_avatar,
    CASE
        WHEN v.source_id IS NOT NULL THEN
            'https://www.twitch.tv/videos/' || v.source_id || '?t=' || d.frame_time_seconds || 's'
        ELSE NULL
    END AS vod_url
FROM detections d
JOIN vods v ON d.vod_id = v.id
JOIN streamers s ON v.streamer_id = s.id
WHERE v.availability = 'available' AND d.confidence > 0.7;

-- Update detection_search_debug view to include igd
DROP VIEW IF EXISTS detection_search_debug;
CREATE OR REPLACE VIEW detection_search_debug WITH (security_invoker = on) AS
SELECT
    d.id AS detection_id,
    d.username,
    d.frame_time_seconds,
    d.confidence,
    d.rank,
    d.storage_path,
    d.no_right_edge,
    d.truncated,
    d.igd,
    d.created_at AS detection_created_at,
    v.id AS vod_id,
    v.source_id AS vod_source_id,
    v.title AS vod_title,
    v.published_at AS vod_published_at,
    v.duration_seconds AS vod_duration_seconds,
    v.availability AS vod_availability,
    (v.published_at + (d.frame_time_seconds || ' seconds')::interval) AS actual_timestamp,
    s.id AS streamer_id,
    s.login AS streamer_login,
    s.display_name AS streamer_display_name,
    s.profile_image_url AS streamer_avatar,
    CASE
        WHEN v.source_id IS NOT NULL THEN
            'https://www.twitch.tv/videos/' || v.source_id || '?t=' || d.frame_time_seconds || 's'
        ELSE NULL
    END AS vod_url
FROM detections d
JOIN vods v ON d.vod_id = v.id
JOIN streamers s ON v.streamer_id = s.id
WHERE v.availability = 'available' AND d.confidence > 0.0;
