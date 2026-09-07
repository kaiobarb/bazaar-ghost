-- Keep legacy Twitch readers isolated while exposing YouTube through the new backend contract.
REVOKE ALL ON public.platform_accounts FROM anon, authenticated;
GRANT SELECT ON public.platform_accounts TO anon, authenticated;

CREATE OR REPLACE VIEW public.detection_search WITH (security_invoker = true) AS
SELECT d.id AS detection_id, d.username, d.frame_time_seconds, d.confidence, d.rank,
  d.storage_path, d.no_right_edge, d.truncated, d.igd, d.created_at AS detection_created_at,
  v.id AS vod_id, v.source_id AS vod_source_id, v.title AS vod_title,
  v.published_at AS vod_published_at, v.duration_seconds AS vod_duration_seconds,
  v.availability AS vod_availability,
  v.published_at + make_interval(secs => d.frame_time_seconds) AS actual_timestamp,
  s.id AS streamer_id, s.login AS streamer_login, s.display_name AS streamer_display_name,
  s.profile_image_url AS streamer_avatar,
  'https://www.twitch.tv/videos/' || v.source_id || '?t=' || d.frame_time_seconds || 's' AS vod_url
FROM public.detections d JOIN public.vods v ON v.id = d.vod_id
JOIN public.streamers s ON s.id = v.streamer_id
WHERE v.source = 'twitch' AND v.availability = 'available' AND d.confidence > 0.7;

CREATE OR REPLACE VIEW public.detection_search_debug WITH (security_invoker = true) AS
SELECT d.id AS detection_id, d.username, d.frame_time_seconds, d.confidence, d.rank,
  d.storage_path, d.no_right_edge, d.truncated, d.igd, d.created_at AS detection_created_at,
  v.id AS vod_id, v.source_id AS vod_source_id, v.title AS vod_title,
  v.published_at AS vod_published_at, v.duration_seconds AS vod_duration_seconds,
  v.availability AS vod_availability,
  v.published_at + make_interval(secs => d.frame_time_seconds) AS actual_timestamp,
  s.id AS streamer_id, s.login AS streamer_login, s.display_name AS streamer_display_name,
  s.profile_image_url AS streamer_avatar,
  'https://www.twitch.tv/videos/' || v.source_id || '?t=' || d.frame_time_seconds || 's' AS vod_url
FROM public.detections d JOIN public.vods v ON v.id = d.vod_id
JOIN public.streamers s ON s.id = v.streamer_id
WHERE v.source = 'twitch' AND v.availability = 'available' AND d.confidence > 0;

CREATE OR REPLACE VIEW public.vod_embed_info AS
SELECT v.id AS vod_id, v.source_id AS vod_source_id, v.title, v.published_at,
  v.duration_seconds, v.bazaar_chapters, v.availability,
  s.id AS streamer_id, s.login AS streamer_login,
  s.display_name AS streamer_display_name, s.profile_image_url AS streamer_avatar
FROM vods v JOIN streamers s ON v.streamer_id = s.id
WHERE v.source = 'twitch';

CREATE OR REPLACE VIEW public.vod_stats WITH (security_invoker = true) AS
SELECT v.id, s.display_name AS streamer, d.total_detections, d.avg_confidence,
  c.quality, v.source_id, v.source, v.title, v.duration_seconds, v.published_at,
  v.availability, v.last_availability_check, v.unavailable_since,
  v.ready_for_processing, v.created_at, v.updated_at, v.bazaar_chapters, v.status,
  c.chunks_count AS chunks
FROM vods v
LEFT JOIN streamers s ON s.id = v.streamer_id
LEFT JOIN LATERAL (
  SELECT COUNT(*) AS total_detections, AVG(confidence) AS avg_confidence
  FROM detections WHERE vod_id = v.id
) d ON true
LEFT JOIN LATERAL (
  SELECT COUNT(*) AS chunks_count,
    CASE WHEN v.status <> 'pending' AND array_length(array_agg(DISTINCT quality), 1) = 1
      THEN (array_agg(DISTINCT quality))[1] ELSE NULL::text END AS quality
  FROM chunks WHERE vod_id = v.id
) c ON true
WHERE v.source = 'twitch';

CREATE OR REPLACE FUNCTION public.force_process_vod(
  p_vod_id bigint DEFAULT NULL, p_source_id text DEFAULT NULL,
  p_target_chunk_seconds integer DEFAULT 1800, p_min_gap_seconds integer DEFAULT 1
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_vod vods%ROWTYPE; v_created integer;
BEGIN
  IF (p_vod_id IS NULL) = (p_source_id IS NULL) THEN RAISE EXCEPTION 'Provide exactly one VOD identifier'; END IF;
  SELECT * INTO STRICT v_vod FROM vods
  WHERE (id = p_vod_id OR (source = 'twitch' AND source_id = p_source_id)) FOR UPDATE;
  IF NOT EXISTS (SELECT 1 FROM vod_processing_context WHERE id = v_vod.id
    AND availability = 'available' AND ready_for_processing AND processing_enabled) THEN
    RAISE EXCEPTION 'VOD is not eligible for processing';
  END IF;
  IF EXISTS (SELECT 1 FROM chunks WHERE vod_id = v_vod.id AND status IN ('queued', 'processing')) THEN
    RAISE EXCEPTION 'Cannot reset a VOD with active workers';
  END IF;
  UPDATE chunks SET status = 'pending', last_error = NULL, completed_at = NULL, lease_expires_at = NULL
  WHERE vod_id = v_vod.id AND status <> 'archived';
  v_created := create_missing_chunks_for_vod(v_vod.id, p_target_chunk_seconds, p_min_gap_seconds);
  RETURN jsonb_build_object('success', true, 'vod_id', v_vod.id, 'created_chunks', v_created);
END;
$$;
