-- Make chunk ownership exclusive, bound new chunks to 30 minutes, and restrict control-plane writes.

CREATE OR REPLACE FUNCTION public.claim_sfde_chunk(p_chunk_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  UPDATE chunks c
  SET status = 'processing', started_at = NOW(), completed_at = NULL,
      last_error = NULL, attempt_count = COALESCE(attempt_count, 0) + 1,
      lease_expires_at = NOW() + INTERVAL '35 minutes'
  FROM vods v JOIN streamers s ON s.id = v.streamer_id
  WHERE c.id = p_chunk_id AND c.vod_id = v.id
    AND c.status IN ('pending', 'queued')
    AND v.availability = 'available' AND v.ready_for_processing
    AND s.processing_enabled;
  RETURN FOUND;
END;
$$;
REVOKE ALL ON FUNCTION public.claim_sfde_chunk(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_sfde_chunk(uuid) TO service_role;

-- VOD state is derived from chunks. A failed runner must not rewrite successful siblings.
DROP TRIGGER IF EXISTS vods_mark_chunks_failed_trigger ON public.vods;
DROP FUNCTION IF EXISTS public.vods_mark_chunks_failed_on_vod_failure();

CREATE OR REPLACE FUNCTION public.simulate_chunk_plan_for_vod(
  p_vod_id bigint, p_target_chunk_seconds integer DEFAULT 1800,
  p_min_gap_seconds integer DEFAULT 1
) RETURNS TABLE(segment_start integer, segment_end integer, gap_start integer, gap_end integer,
  proposed_chunk_start integer, proposed_chunk_end integer, proposed_duration integer)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_vod vods%ROWTYPE;
  v_existing int4multirange;
  v_segments int4multirange := '{}';
  v_gap int4range;
  v_segment int4range;
  v_start integer;
  v_end integer;
  v_i integer;
BEGIN
  IF p_target_chunk_seconds <= 0 OR p_min_gap_seconds <= 0 THEN
    RAISE EXCEPTION 'Chunk and minimum gap durations must be positive';
  END IF;
  SELECT * INTO v_vod FROM vods WHERE id = p_vod_id;
  IF NOT FOUND OR NOT v_vod.ready_for_processing OR v_vod.availability <> 'available'
    OR NOT EXISTS (SELECT 1 FROM streamers WHERE id = v_vod.streamer_id AND processing_enabled)
    OR COALESCE(v_vod.duration_seconds, 0) <= 0 THEN
    RETURN;
  END IF;
  -- No chapter evidence means no work. The cataloger handles genuine no-chapter Bazaar VODs.
  IF COALESCE(cardinality(v_vod.bazaar_chapters), 0) = 0 THEN
    RETURN;
  END IF;
  IF cardinality(v_vod.bazaar_chapters) % 2 <> 0 THEN
    RAISE EXCEPTION 'Bazaar chapters must contain start/end pairs';
  END IF;
  FOR v_i IN 1..cardinality(v_vod.bazaar_chapters) BY 2 LOOP
    v_start := GREATEST(0, v_vod.bazaar_chapters[v_i]);
    v_end := LEAST(v_vod.duration_seconds, v_vod.bazaar_chapters[v_i + 1]);
    IF v_end > v_start THEN
      v_segments := v_segments + int4multirange(int4range(v_start, v_end, '[)'));
    END IF;
  END LOOP;
  SELECT COALESCE(range_agg(int4range(start_seconds, end_seconds, '[)')), '{}')
  INTO v_existing FROM chunks WHERE vod_id = p_vod_id;
  FOR v_segment IN SELECT unnest(v_segments) LOOP
    FOR v_gap IN SELECT unnest(int4multirange(v_segment) - v_existing) LOOP
      v_start := lower(v_gap);
      IF upper(v_gap) - v_start < p_min_gap_seconds THEN CONTINUE; END IF;
      WHILE v_start < upper(v_gap) LOOP
        v_end := LEAST(v_start + p_target_chunk_seconds, upper(v_gap));
        segment_start := lower(v_segment); segment_end := upper(v_segment);
        gap_start := lower(v_gap); gap_end := upper(v_gap);
        proposed_chunk_start := v_start; proposed_chunk_end := v_end;
        proposed_duration := v_end - v_start;
        RETURN NEXT;
        v_start := v_end;
      END LOOP;
    END LOOP;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_missing_chunks_for_vod(
  p_vod_id bigint, p_target_chunk_seconds integer DEFAULT 1800,
  p_min_gap_seconds integer DEFAULT 1
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_index integer; v_created integer := 0; v_plan record;
BEGIN
  -- Serialize planners; preview and insertion use exactly the same range calculation.
  PERFORM 1 FROM vods WHERE id = p_vod_id FOR UPDATE;
  SELECT COALESCE(MAX(chunk_index), -1) + 1 INTO v_index FROM chunks WHERE vod_id = p_vod_id;
  FOR v_plan IN SELECT * FROM simulate_chunk_plan_for_vod(p_vod_id, p_target_chunk_seconds, p_min_gap_seconds) LOOP
    INSERT INTO chunks(vod_id, start_seconds, end_seconds, chunk_index)
    VALUES(p_vod_id, v_plan.proposed_chunk_start, v_plan.proposed_chunk_end, v_index);
    v_index := v_index + 1;
    v_created := v_created + 1;
  END LOOP;
  RETURN v_created;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_bazaar_aware_chunks(
  p_vod_id bigint, p_min_chunk_duration integer DEFAULT 1800
) RETURNS integer
LANGUAGE sql SET search_path = public
AS $$ SELECT create_missing_chunks_for_vod(p_vod_id, p_min_chunk_duration, 1); $$;

CREATE OR REPLACE FUNCTION public.auto_create_chunks()
RETURNS trigger LANGUAGE plpgsql SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM create_missing_chunks_for_vod(NEW.id);
  ELSIF NEW.ready_for_processing IS DISTINCT FROM OLD.ready_for_processing
    OR NEW.duration_seconds IS DISTINCT FROM OLD.duration_seconds
    OR NEW.bazaar_chapters IS DISTINCT FROM OLD.bazaar_chapters THEN
    PERFORM create_missing_chunks_for_vod(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

-- Existing read contracts remain available; processing mutations belong to the service.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON
  public.streamers, public.vods, public.chunks, public.detections,
  public.sfde_profiles, public.cataloger_runs, public.processing_config
FROM anon, authenticated;

DO $$
DECLARE v_table text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY['streamers', 'vods', 'chunks', 'detections',
      'sfde_profiles', 'cataloger_runs', 'processing_config'] LOOP
    EXECUTE format('CREATE POLICY service_role_full_access ON public.%I FOR ALL TO service_role USING (true) WITH CHECK (true)', v_table);
  END LOOP;
END;
$$;

-- SECURITY DEFINER processing RPCs must not provide a bypass around table permissions.
DO $$
DECLARE v_function regprocedure;
BEGIN
  FOR v_function IN
    SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN (
      'auto_queue_next_vod', 'create_bazaar_aware_chunks', 'create_missing_chunks_for_vod',
      'cron_insert_new_streamers', 'cron_update_streamer_vods', 'force_process_vod',
      'process_pending_vods', 'update_chunk_status', 'increment_notification_count'
    )
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', v_function);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', v_function);
  END LOOP;
END;
$$;

-- Recover abandoned runners without allowing a second worker to steal a live lease.
CREATE OR REPLACE FUNCTION public.recover_expired_chunks()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_count integer;
BEGIN
  UPDATE chunks SET status = 'pending', queued_at = NULL, lease_expires_at = NULL,
    last_error = 'Previous processing lease expired'
  WHERE (status = 'processing' AND COALESCE(lease_expires_at, started_at + INTERVAL '45 minutes') < NOW())
     OR (status = 'queued' AND queued_at < NOW() - INTERVAL '45 minutes');
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;
REVOKE ALL ON FUNCTION public.recover_expired_chunks() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.recover_expired_chunks() TO service_role;

CREATE OR REPLACE FUNCTION public.process_pending_vods(max_vods integer DEFAULT 5)
RETURNS TABLE(vod_id bigint, source_id text, pending_chunks bigint, request_id bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_url text;
  v_key text;
  v_limit integer;
  v_active integer;
  v_vod record;
  v_request bigint;
BEGIN
  IF max_vods < 1 OR max_vods > 100 THEN RAISE EXCEPTION 'max_vods must be between 1 and 100'; END IF;
  PERFORM recover_expired_chunks();
  SELECT decrypted_secret INTO v_url FROM vault.decrypted_secrets WHERE name = 'supabase_url' LIMIT 1;
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'secret_key' LIMIT 1;
  IF v_url IS NULL OR v_key IS NULL THEN
    RAISE EXCEPTION 'Configure supabase_url and secret_key in Vault';
  END IF;
  SELECT COALESCE((SELECT value::integer FROM processing_config WHERE key = 'max_concurrent_chunks'), 10) INTO v_limit;
  SELECT COUNT(*) INTO v_active FROM chunks WHERE status IN ('queued', 'processing');
  IF v_active >= v_limit THEN RETURN; END IF;
  FOR v_vod IN
    SELECT v.id, v.source_id, COUNT(*) AS pending_chunks
    FROM vods v JOIN chunks c ON c.vod_id = v.id JOIN streamers s ON s.id = v.streamer_id
    WHERE v.ready_for_processing AND v.availability = 'available' AND s.processing_enabled
      AND c.status = 'pending' AND c.scheduled_for <= NOW()
    GROUP BY v.id, v.source_id, v.published_at
    ORDER BY MIN(c.attempt_count), v.published_at DESC LIMIT max_vods
  LOOP
    SELECT net.http_post(
      url := v_url || '/functions/v1/process-vod',
      headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', v_key),
      body := jsonb_build_object('vod_id', v_vod.id), timeout_milliseconds := 30000
    ) INTO v_request;
    RETURN QUERY SELECT v_vod.id, v_vod.source_id, v_vod.pending_chunks, v_request;
    v_active := v_active + v_vod.pending_chunks;
    EXIT WHEN v_active >= v_limit;
  END LOOP;
END;
$$;

-- Keep the legacy entry point, but use the real authenticated orchestrator.
CREATE OR REPLACE FUNCTION public.auto_queue_next_vod()
RETURNS void LANGUAGE plpgsql SET search_path = public
AS $$
BEGIN
  IF COALESCE((SELECT value::boolean FROM processing_config WHERE key = 'auto_queue_enabled'), false) THEN
    PERFORM process_pending_vods(1);
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.force_process_vod(
  p_vod_id bigint DEFAULT NULL, p_source_id text DEFAULT NULL,
  p_target_chunk_seconds integer DEFAULT 1800, p_min_gap_seconds integer DEFAULT 1
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_vod vods%ROWTYPE; v_created integer;
BEGIN
  IF (p_vod_id IS NULL) = (p_source_id IS NULL) THEN RAISE EXCEPTION 'Provide exactly one VOD identifier'; END IF;
  SELECT * INTO STRICT v_vod FROM vods
  WHERE (id = p_vod_id OR (source = 'twitch' AND source_id = p_source_id)) FOR UPDATE;
  IF v_vod.availability <> 'available' OR NOT v_vod.ready_for_processing
    OR NOT EXISTS (SELECT 1 FROM streamers WHERE id=v_vod.streamer_id AND processing_enabled) THEN
    RAISE EXCEPTION 'VOD is not eligible for processing';
  END IF;
  IF EXISTS (SELECT 1 FROM chunks WHERE vod_id=v_vod.id AND status IN ('queued', 'processing')) THEN
    RAISE EXCEPTION 'Cannot reset a VOD with active workers';
  END IF;
  -- Retain detections until their replacement worker starts, and preserve chunk identities.
  UPDATE chunks SET status='pending', last_error=NULL, completed_at=NULL, lease_expires_at=NULL
  WHERE vod_id=v_vod.id AND status <> 'archived';
  v_created := create_missing_chunks_for_vod(v_vod.id, p_target_chunk_seconds, p_min_gap_seconds);
  RETURN jsonb_build_object('success', true, 'vod_id', v_vod.id, 'created_chunks', v_created);
END;
$$;
COMMENT ON FUNCTION public.force_process_vod(bigint,text,integer,integer)
IS 'Reset inactive eligible chunks for reprocessing, preserving identities and existing detections until claimed.';

-- Disabling processing prevents new claims; it must not delete a running worker's chunk.
DROP TRIGGER IF EXISTS trigger_streamer_processing_disabled ON public.streamers;
DROP TRIGGER IF EXISTS trigger_vod_processing_disabled ON public.vods;
DROP FUNCTION IF EXISTS public.cleanup_streamer_chunks_on_disable();
DROP FUNCTION IF EXISTS public.cleanup_vod_chunks_on_disable();

CREATE OR REPLACE FUNCTION public.get_pending_chunks_for_vod(
  p_vod_id bigint DEFAULT NULL, p_source_id text DEFAULT NULL
) RETURNS TABLE(chunk_id uuid, vod_id bigint, source_id text, chunk_index integer,
  start_seconds integer, end_seconds integer, status public.processing_status, attempt_count integer)
LANGUAGE plpgsql SET search_path = public
AS $$
BEGIN
  IF (p_vod_id IS NULL) = (p_source_id IS NULL) THEN RAISE EXCEPTION 'Provide exactly one VOD identifier'; END IF;
  RETURN QUERY SELECT c.id, c.vod_id, v.source_id, c.chunk_index, c.start_seconds, c.end_seconds, c.status, c.attempt_count
  FROM chunks c JOIN vods v ON v.id=c.vod_id JOIN streamers s ON s.id=v.streamer_id
  WHERE (v.id=p_vod_id OR (v.source='twitch' AND v.source_id=p_source_id))
    AND c.status='pending' AND c.scheduled_for <= NOW()
    AND v.availability='available' AND v.ready_for_processing AND s.processing_enabled
  ORDER BY c.chunk_index;
END;
$$;

CREATE OR REPLACE FUNCTION public.increment_notification_count(p_username text, p_discord_user_ids text[])
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  UPDATE notification_subscriptions SET notification_count=notification_count+1
  WHERE username_lower=lower(p_username) AND discord_user_id=ANY(p_discord_user_ids);
$$;

-- Pin application SECURITY DEFINER functions, including read RPCs; leave extension functions alone.
DO $$
DECLARE v_function regprocedure;
BEGIN
  FOR v_function IN
    SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.prosecdef
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid=p.oid AND d.classid='pg_proc'::regclass AND d.deptype='e')
  LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path = public, extensions', v_function);
  END LOOP;
END;
$$;
