-- Preserve raw detections while allowing reviewed cross-platform copies to share a matchup.
CREATE TABLE public.matchup_groups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  evidence text NOT NULL CHECK (length(evidence) BETWEEN 10 AND 4000),
  created_at timestamptz NOT NULL DEFAULT NOW()
);
CREATE TABLE public.matchup_appearances (
  detection_id uuid PRIMARY KEY REFERENCES public.detections(id) ON DELETE CASCADE,
  matchup_id uuid NOT NULL REFERENCES public.matchup_groups(id),
  linked_at timestamptz NOT NULL DEFAULT NOW()
);
CREATE INDEX matchup_appearances_group_idx ON public.matchup_appearances(matchup_id);
ALTER TABLE public.matchup_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.matchup_appearances ENABLE ROW LEVEL SECURITY;
CREATE POLICY service_role_full_access ON public.matchup_groups
  FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY service_role_full_access ON public.matchup_appearances
  FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY public_read ON public.matchup_appearances
  FOR SELECT TO anon, authenticated USING (true);
REVOKE ALL ON public.matchup_groups, public.matchup_appearances FROM anon, authenticated;
GRANT SELECT ON public.matchup_appearances TO anon, authenticated;
GRANT ALL ON public.matchup_groups, public.matchup_appearances TO service_role;

CREATE FUNCTION public.link_matchup_appearances(p_detection_ids uuid[], p_evidence text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_ids uuid[]; v_group uuid; v_groups integer;
BEGIN
  SELECT array_agg(DISTINCT id ORDER BY id) INTO v_ids FROM unnest(p_detection_ids) id;
  IF COALESCE(cardinality(v_ids), 0) < 2 OR cardinality(v_ids) > 50
    OR p_evidence IS NULL OR length(trim(p_evidence)) NOT BETWEEN 10 AND 4000 THEN
    RAISE EXCEPTION 'Provide 2-50 detection IDs and a substantive verification note';
  END IF;
  -- These infrequent operator decisions serialize; raw processing is unaffected.
  PERFORM pg_advisory_xact_lock(78103420);
  IF (SELECT COUNT(*) FROM detections WHERE id = ANY(v_ids)) <> cardinality(v_ids) THEN
    RAISE EXCEPTION 'Every appearance must reference an existing detection';
  END IF;
  IF (SELECT COUNT(DISTINCT vod_id) FROM detections WHERE id = ANY(v_ids)) < 2 THEN
    RAISE EXCEPTION 'Verified copies must come from at least two source videos';
  END IF;
  SELECT COUNT(DISTINCT matchup_id) INTO v_groups FROM matchup_appearances WHERE detection_id = ANY(v_ids);
  IF v_groups > 1 THEN RAISE EXCEPTION 'Conflicting groups require explicit unlinking before relinking'; END IF;
  SELECT matchup_id INTO v_group FROM matchup_appearances WHERE detection_id = ANY(v_ids) LIMIT 1;
  IF v_group IS NULL THEN
    INSERT INTO matchup_groups(evidence) VALUES (trim(p_evidence)) RETURNING id INTO v_group;
  END IF;
  INSERT INTO matchup_appearances(detection_id, matchup_id)
    SELECT id, v_group FROM unnest(v_ids) id ON CONFLICT (detection_id) DO NOTHING;
  RETURN v_group;
END;
$$;
REVOKE ALL ON FUNCTION public.link_matchup_appearances(uuid[],text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.link_matchup_appearances(uuid[],text) TO service_role;

CREATE FUNCTION public.unlink_matchup_appearance(p_detection_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(78103420);
  DELETE FROM matchup_appearances WHERE detection_id = p_detection_id;
  RETURN FOUND;
END;
$$;
REVOKE ALL ON FUNCTION public.unlink_matchup_appearance(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.unlink_matchup_appearance(uuid) TO service_role;

-- Group before pagination. An unavailable Twitch copy never hides a surviving YouTube/Bilibili copy.
CREATE FUNCTION public.search_matchup_appearances(
  search_query text DEFAULT NULL, source_filter text DEFAULT NULL,
  result_limit integer DEFAULT 100, result_offset integer DEFAULT 0
) RETURNS TABLE(matchup_id uuid, username text, appearances jsonb, total_count bigint)
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
BEGIN
  IF result_limit IS NULL OR result_offset IS NULL OR result_limit NOT BETWEEN 1 AND 500 OR result_offset < 0 THEN
    RAISE EXCEPTION 'Invalid pagination';
  END IF;
  RETURN QUERY WITH visible AS (
    SELECT COALESCE(a.matchup_id, d.detection_id) AS group_id, d.*
    FROM video_detections d LEFT JOIN matchup_appearances a ON a.detection_id = d.detection_id
  ), matched AS (
    SELECT DISTINCT group_id FROM visible
    WHERE (search_query IS NULL OR search_query = '' OR visible.username ILIKE '%' || search_query || '%')
      AND (source_filter IS NULL OR source = source_filter)
  ), grouped AS (
    SELECT v.group_id,
      (array_agg(v.username ORDER BY v.confidence DESC, v.detection_id))[1] AS best_username,
      jsonb_agg(to_jsonb(v) - 'group_id' ORDER BY v.confidence DESC, v.detection_id) AS copies,
      MAX(v.indexed_at) AS indexed_at
    FROM visible v JOIN matched m ON m.group_id = v.group_id GROUP BY v.group_id
  ) SELECT g.group_id, g.best_username, g.copies, COUNT(*) OVER ()
    FROM grouped g ORDER BY g.indexed_at DESC, g.group_id LIMIT result_limit OFFSET result_offset;
END;
$$;
REVOKE ALL ON FUNCTION public.search_matchup_appearances(text,text,integer,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.search_matchup_appearances(text,text,integer,integer) TO anon, authenticated, service_role;
