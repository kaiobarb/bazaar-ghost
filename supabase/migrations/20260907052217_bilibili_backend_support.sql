-- Add Bilibili published-video parts without inventing a combined submission timeline.
ALTER TABLE public.platform_accounts DROP CONSTRAINT platform_accounts_source_check;
ALTER TABLE public.platform_accounts ADD CONSTRAINT platform_accounts_source_check
  CHECK (source IN ('twitch', 'youtube', 'bilibili'));
ALTER TABLE public.vods
  ADD COLUMN source_video_id text,
  ADD COLUMN source_part_id text,
  ADD COLUMN source_part_index integer,
  ADD CONSTRAINT bilibili_part_identity CHECK (source <> 'bilibili' OR (
    source_video_id IS NOT NULL AND source_video_id ~ '^BV[A-Za-z0-9]{10}$'
    AND source_part_id IS NOT NULL AND source_part_id ~ '^[1-9][0-9]*$'
    AND source_part_index IS NOT NULL AND source_part_index > 0
    AND source_id = source_video_id || ':' || source_part_id
    AND platform_account_id IS NOT NULL
  ));
CREATE INDEX vods_source_video_idx ON public.vods(source, source_video_id);

CREATE OR REPLACE VIEW public.video_detections WITH (security_invoker = true) AS
SELECT d.id AS detection_id, d.username, d.confidence, d.rank, d.frame_time_seconds,
  d.storage_path, d.truncated, d.igd, d.created_at AS indexed_at,
  v.id AS vod_id, v.source, v.source_id, v.title, v.published_at, v.recorded_at,
  v.platform_account_id, v.streamer_id, COALESCE(a.display_name, s.display_name, s.login) AS creator_name,
  CASE v.source
    WHEN 'youtube' THEN 'https://www.youtube.com/watch?v=' || v.source_id || '&t=' || d.frame_time_seconds || 's'
    WHEN 'twitch' THEN 'https://www.twitch.tv/videos/' || v.source_id || '?t=' || d.frame_time_seconds || 's'
    WHEN 'bilibili' THEN 'https://www.bilibili.com/video/' || v.source_video_id
      || '/?p=' || v.source_part_index || '&t=' || d.frame_time_seconds END AS video_url,
  CASE WHEN v.source = 'twitch' THEN COALESCE(v.recorded_at, v.published_at)
       ELSE v.recorded_at END + make_interval(secs => d.frame_time_seconds) AS recorded_timestamp,
  COALESCE(v.source_video_id, v.source_id) AS source_video_id,
  v.source_part_id, v.source_part_index,
  CASE v.source
    WHEN 'youtube' THEN 'https://www.youtube.com/embed/' || v.source_id || '?start=' || d.frame_time_seconds
    WHEN 'bilibili' THEN 'https://player.bilibili.com/player.html?bvid=' || v.source_video_id
      || '&cid=' || v.source_part_id || '&t=' || d.frame_time_seconds || '&autoplay=0&danmaku=0'
    END AS embed_url
FROM public.detections d JOIN public.vods v ON v.id = d.vod_id
LEFT JOIN public.platform_accounts a ON a.id = v.platform_account_id
LEFT JOIN public.streamers s ON s.id = v.streamer_id
WHERE v.availability = 'available' AND d.confidence > 0.7;
