-- Explicit NULL must not turn the public appearance search into an unbounded query.
CREATE OR REPLACE FUNCTION public.search_video_detections(
  search_query text DEFAULT NULL, source_filter text DEFAULT NULL,
  account_filter uuid DEFAULT NULL, video_filter bigint DEFAULT NULL,
  result_limit integer DEFAULT 100, result_offset integer DEFAULT 0
) RETURNS SETOF public.video_detections LANGUAGE plpgsql SECURITY INVOKER
SET search_path = public, extensions AS $$
BEGIN
  IF result_limit IS NULL OR result_offset IS NULL OR result_limit < 1 OR result_limit > 500 OR result_offset < 0 THEN
    RAISE EXCEPTION 'Invalid pagination';
  END IF;
  RETURN QUERY SELECT d.* FROM video_detections d
  WHERE (search_query IS NULL OR search_query = '' OR d.username ILIKE '%' || search_query || '%')
    AND (source_filter IS NULL OR d.source = source_filter)
    AND (account_filter IS NULL OR d.platform_account_id = account_filter)
    AND (video_filter IS NULL OR d.vod_id = video_filter)
  ORDER BY d.indexed_at DESC, d.detection_id LIMIT result_limit OFFSET result_offset;
END;
$$;
