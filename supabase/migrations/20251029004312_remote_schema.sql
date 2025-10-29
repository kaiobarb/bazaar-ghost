create extension if not exists "pg_net" with schema "public" version '0.19.5';

drop trigger if exists "trigger_auto_chunks" on "public"."vods";

revoke delete on table "public"."cataloger_runs" from "anon";

revoke insert on table "public"."cataloger_runs" from "anon";

revoke references on table "public"."cataloger_runs" from "anon";

revoke select on table "public"."cataloger_runs" from "anon";

revoke trigger on table "public"."cataloger_runs" from "anon";

revoke truncate on table "public"."cataloger_runs" from "anon";

revoke update on table "public"."cataloger_runs" from "anon";

revoke delete on table "public"."cataloger_runs" from "authenticated";

revoke insert on table "public"."cataloger_runs" from "authenticated";

revoke references on table "public"."cataloger_runs" from "authenticated";

revoke select on table "public"."cataloger_runs" from "authenticated";

revoke trigger on table "public"."cataloger_runs" from "authenticated";

revoke truncate on table "public"."cataloger_runs" from "authenticated";

revoke update on table "public"."cataloger_runs" from "authenticated";

revoke delete on table "public"."cataloger_runs" from "service_role";

revoke insert on table "public"."cataloger_runs" from "service_role";

revoke references on table "public"."cataloger_runs" from "service_role";

revoke select on table "public"."cataloger_runs" from "service_role";

revoke trigger on table "public"."cataloger_runs" from "service_role";

revoke truncate on table "public"."cataloger_runs" from "service_role";

revoke update on table "public"."cataloger_runs" from "service_role";

revoke delete on table "public"."chunks" from "anon";

revoke insert on table "public"."chunks" from "anon";

revoke references on table "public"."chunks" from "anon";

revoke select on table "public"."chunks" from "anon";

revoke trigger on table "public"."chunks" from "anon";

revoke truncate on table "public"."chunks" from "anon";

revoke update on table "public"."chunks" from "anon";

revoke delete on table "public"."chunks" from "authenticated";

revoke insert on table "public"."chunks" from "authenticated";

revoke references on table "public"."chunks" from "authenticated";

revoke select on table "public"."chunks" from "authenticated";

revoke trigger on table "public"."chunks" from "authenticated";

revoke truncate on table "public"."chunks" from "authenticated";

revoke update on table "public"."chunks" from "authenticated";

revoke delete on table "public"."chunks" from "service_role";

revoke insert on table "public"."chunks" from "service_role";

revoke references on table "public"."chunks" from "service_role";

revoke select on table "public"."chunks" from "service_role";

revoke trigger on table "public"."chunks" from "service_role";

revoke truncate on table "public"."chunks" from "service_role";

revoke update on table "public"."chunks" from "service_role";

revoke delete on table "public"."detections" from "anon";

revoke insert on table "public"."detections" from "anon";

revoke references on table "public"."detections" from "anon";

revoke select on table "public"."detections" from "anon";

revoke trigger on table "public"."detections" from "anon";

revoke truncate on table "public"."detections" from "anon";

revoke update on table "public"."detections" from "anon";

revoke delete on table "public"."detections" from "authenticated";

revoke insert on table "public"."detections" from "authenticated";

revoke references on table "public"."detections" from "authenticated";

revoke select on table "public"."detections" from "authenticated";

revoke trigger on table "public"."detections" from "authenticated";

revoke truncate on table "public"."detections" from "authenticated";

revoke update on table "public"."detections" from "authenticated";

revoke delete on table "public"."detections" from "service_role";

revoke insert on table "public"."detections" from "service_role";

revoke references on table "public"."detections" from "service_role";

revoke select on table "public"."detections" from "service_role";

revoke trigger on table "public"."detections" from "service_role";

revoke truncate on table "public"."detections" from "service_role";

revoke update on table "public"."detections" from "service_role";

revoke delete on table "public"."processing_config" from "anon";

revoke insert on table "public"."processing_config" from "anon";

revoke references on table "public"."processing_config" from "anon";

revoke select on table "public"."processing_config" from "anon";

revoke trigger on table "public"."processing_config" from "anon";

revoke truncate on table "public"."processing_config" from "anon";

revoke update on table "public"."processing_config" from "anon";

revoke delete on table "public"."processing_config" from "authenticated";

revoke insert on table "public"."processing_config" from "authenticated";

revoke references on table "public"."processing_config" from "authenticated";

revoke select on table "public"."processing_config" from "authenticated";

revoke trigger on table "public"."processing_config" from "authenticated";

revoke truncate on table "public"."processing_config" from "authenticated";

revoke update on table "public"."processing_config" from "authenticated";

revoke delete on table "public"."processing_config" from "service_role";

revoke insert on table "public"."processing_config" from "service_role";

revoke references on table "public"."processing_config" from "service_role";

revoke select on table "public"."processing_config" from "service_role";

revoke trigger on table "public"."processing_config" from "service_role";

revoke truncate on table "public"."processing_config" from "service_role";

revoke update on table "public"."processing_config" from "service_role";

revoke delete on table "public"."sfot_profiles" from "anon";

revoke insert on table "public"."sfot_profiles" from "anon";

revoke references on table "public"."sfot_profiles" from "anon";

revoke select on table "public"."sfot_profiles" from "anon";

revoke trigger on table "public"."sfot_profiles" from "anon";

revoke truncate on table "public"."sfot_profiles" from "anon";

revoke update on table "public"."sfot_profiles" from "anon";

revoke delete on table "public"."sfot_profiles" from "authenticated";

revoke insert on table "public"."sfot_profiles" from "authenticated";

revoke references on table "public"."sfot_profiles" from "authenticated";

revoke select on table "public"."sfot_profiles" from "authenticated";

revoke trigger on table "public"."sfot_profiles" from "authenticated";

revoke truncate on table "public"."sfot_profiles" from "authenticated";

revoke update on table "public"."sfot_profiles" from "authenticated";

revoke delete on table "public"."sfot_profiles" from "service_role";

revoke insert on table "public"."sfot_profiles" from "service_role";

revoke references on table "public"."sfot_profiles" from "service_role";

revoke select on table "public"."sfot_profiles" from "service_role";

revoke trigger on table "public"."sfot_profiles" from "service_role";

revoke truncate on table "public"."sfot_profiles" from "service_role";

revoke update on table "public"."sfot_profiles" from "service_role";

revoke delete on table "public"."streamers" from "anon";

revoke insert on table "public"."streamers" from "anon";

revoke references on table "public"."streamers" from "anon";

revoke select on table "public"."streamers" from "anon";

revoke trigger on table "public"."streamers" from "anon";

revoke truncate on table "public"."streamers" from "anon";

revoke update on table "public"."streamers" from "anon";

revoke delete on table "public"."streamers" from "authenticated";

revoke insert on table "public"."streamers" from "authenticated";

revoke references on table "public"."streamers" from "authenticated";

revoke select on table "public"."streamers" from "authenticated";

revoke trigger on table "public"."streamers" from "authenticated";

revoke truncate on table "public"."streamers" from "authenticated";

revoke update on table "public"."streamers" from "authenticated";

revoke delete on table "public"."streamers" from "service_role";

revoke insert on table "public"."streamers" from "service_role";

revoke references on table "public"."streamers" from "service_role";

revoke select on table "public"."streamers" from "service_role";

revoke trigger on table "public"."streamers" from "service_role";

revoke truncate on table "public"."streamers" from "service_role";

revoke update on table "public"."streamers" from "service_role";

revoke delete on table "public"."vods" from "anon";

revoke insert on table "public"."vods" from "anon";

revoke references on table "public"."vods" from "anon";

revoke select on table "public"."vods" from "anon";

revoke trigger on table "public"."vods" from "anon";

revoke truncate on table "public"."vods" from "anon";

revoke update on table "public"."vods" from "anon";

revoke delete on table "public"."vods" from "authenticated";

revoke insert on table "public"."vods" from "authenticated";

revoke references on table "public"."vods" from "authenticated";

revoke select on table "public"."vods" from "authenticated";

revoke trigger on table "public"."vods" from "authenticated";

revoke truncate on table "public"."vods" from "authenticated";

revoke update on table "public"."vods" from "authenticated";

revoke delete on table "public"."vods" from "service_role";

revoke insert on table "public"."vods" from "service_role";

revoke references on table "public"."vods" from "service_role";

revoke select on table "public"."vods" from "service_role";

revoke trigger on table "public"."vods" from "service_role";

revoke truncate on table "public"."vods" from "service_role";

revoke update on table "public"."vods" from "service_role";

drop view if exists "public"."cron_job_status";

set check_function_bodies = off;

create or replace view "public"."streamer_detection_stats" as  SELECT s.id AS streamer_id,
    s.login,
    s.display_name,
    count(d.*) AS total_detections,
    avg(d.confidence) AS avg_confidence,
    count(d.*) FILTER (WHERE (d.no_right_edge = true)) AS no_right_edge_detections,
    count(v.*) FILTER (WHERE (v.status = 'processing'::vod_status)) AS vods_processing,
    count(v.*) FILTER (WHERE (v.status = 'completed'::vod_status)) AS vods_completed,
    count(v.*) FILTER (WHERE (v.status = 'failed'::vod_status)) AS vods_failed,
    count(v.*) FILTER (WHERE (v.status = 'partial'::vod_status)) AS vods_partial,
    count(v.*) FILTER (WHERE (v.status = 'pending'::vod_status)) AS vods_pending,
    count(v.*) AS total_vods,
        CASE
            WHEN (count(v.*) > 0) THEN round(((count(d.*))::numeric / (NULLIF(count(v.*), 0))::numeric), 2)
            ELSE (0)::numeric
        END AS avg_detections_per_vod
   FROM ((streamers s
     LEFT JOIN vods v ON ((v.streamer_id = s.id)))
     LEFT JOIN detections d ON ((d.vod_id = v.id)))
  GROUP BY s.id, s.login, s.display_name;


CREATE OR REPLACE FUNCTION public.auto_create_chunks()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_duration integer;
BEGIN
  -- Only create chunks if both VOD and streamer are ready for processing
  IF NEW.ready_for_processing = TRUE THEN
    -- Check if streamer has processing enabled
    IF EXISTS (
      SELECT 1 FROM streamers s
      WHERE s.id = NEW.streamer_id
      AND s.processing_enabled = TRUE
    ) THEN
      -- Check minimum duration (10 minutes)
      IF NEW.duration_seconds >= 600 THEN
        -- Use the new Bazaar-aware chunking function
        PERFORM create_bazaar_aware_chunks(NEW.id);
      ELSE
        RAISE NOTICE 'VOD % is too short for chunking (% seconds)', NEW.id, NEW.duration_seconds;
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.auto_queue_next_vod()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_max_concurrent integer;
  v_auto_enabled boolean;
  v_current_active_count integer;
  v_next_vod_id bigint;
  v_chunks_queued integer := 0;
  v_response_id bigint;
  v_anon_key text;
  v_function_url text;
BEGIN
  -- Get configuration settings
  SELECT value::integer INTO v_max_concurrent
  FROM public.processing_config
  WHERE key = 'max_concurrent_chunks';

  SELECT value::boolean INTO v_auto_enabled
  FROM public.processing_config
  WHERE key = 'auto_queue_enabled';

  -- Exit if auto-queuing is disabled
  IF NOT v_auto_enabled THEN
    RAISE NOTICE 'Auto-queuing is disabled';
    RETURN;
  END IF;

  -- Count currently active chunks (queued or processing)
  SELECT COUNT(*)
  INTO v_current_active_count
  FROM public.chunks
  WHERE status IN ('queued', 'processing');

  RAISE NOTICE 'Current active chunks: %, max allowed: %', v_current_active_count, v_max_concurrent;

  -- Check if we have capacity for more chunks
  IF v_current_active_count >= v_max_concurrent THEN
    RAISE NOTICE 'At capacity (% active chunks), not queuing new VOD', v_current_active_count;
    RETURN;
  END IF;

  -- Find the next pending VOD (oldest by published_at)
  SELECT v.id
  INTO v_next_vod_id
  FROM public.vods v
  INNER JOIN public.streamers s ON s.id = v.streamer_id
  WHERE v.status = 'pending'
    AND v.ready_for_processing = true
    AND s.processing_enabled = true
    AND v.availability = 'available'
    AND EXISTS (SELECT 1 FROM public.chunks WHERE vod_id = v.id AND status = 'pending')
  ORDER BY v.published_at ASC
  LIMIT 1;

  IF v_next_vod_id IS NULL THEN
    RAISE NOTICE 'No pending VODs found to queue';
    RETURN;
  END IF;

  RAISE NOTICE 'Queuing all chunks for VOD %', v_next_vod_id;

  -- Queue all pending chunks from this VOD
  UPDATE public.chunks
  SET
    status = 'queued',
    queued_at = now(),
    updated_at = now()
  WHERE vod_id = v_next_vod_id
    AND status = 'pending';

  GET DIAGNOSTICS v_chunks_queued = ROW_COUNT;

  RAISE NOTICE 'Queued % chunks from VOD %', v_chunks_queued, v_next_vod_id;

  -- Trigger GitHub processing for this VOD
  IF v_chunks_queued > 0 THEN
    -- Get configuration for edge function call
    v_anon_key := COALESCE(
      current_setting('app.settings.anon_key', true),
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0'
    );

    v_function_url := COALESCE(
      current_setting('app.settings.edge_function_url', true) || '/trigger-github-processing',
      'http://localhost:54321/functions/v1/trigger-github-processing'
    );

    -- Call trigger-github-processing edge function
    BEGIN
      SELECT net.http_post(
        url := v_function_url,
        headers := jsonb_build_object(
          'Authorization', 'Bearer ' || v_anon_key,
          'Content-Type', 'application/json'
        ),
        body := jsonb_build_object(
          'vod_id', v_next_vod_id,
          'chunks_to_process', v_chunks_queued
        ),
        timeout_milliseconds := 10000
      ) INTO v_response_id;

      RAISE NOTICE 'Called trigger-github-processing for VOD %, response_id: %',
        v_next_vod_id, v_response_id;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Failed to call trigger-github-processing: %', SQLERRM;
    END;
  END IF;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.cleanup_streamer_chunks_on_disable()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.processing_enabled = FALSE THEN
    DELETE FROM chunks 
    WHERE vod_id IN (SELECT id FROM vods WHERE streamer_id = NEW.id)
    AND status IN ('pending', 'processing');
  END IF;
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.cleanup_vod_chunks_on_disable()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.ready_for_processing = FALSE THEN
    DELETE FROM chunks 
    WHERE vod_id = NEW.id
    AND status IN ('pending', 'processing');
  END IF;
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.create_bazaar_aware_chunks(p_vod_id bigint, p_min_chunk_duration integer DEFAULT 3600)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_vod_duration integer;
  v_bazaar_chapters integer[];
  v_chunk_count integer := 0;
  v_chunk_index integer := 0;
  v_segment_start integer;
  v_segment_end integer;
  v_current_start integer;
  v_current_end integer;
  v_segment_duration integer;
  v_num_chunks integer;
  v_chunk_duration integer;
  i integer;
BEGIN
  -- Get VOD details
  SELECT duration_seconds, bazaar_chapters
  INTO v_vod_duration, v_bazaar_chapters
  FROM vods
  WHERE id = p_vod_id;

  -- Skip if VOD is too short (less than 10 minutes)
  IF v_vod_duration < 600 THEN
    RAISE NOTICE 'VOD % is too short (% seconds), skipping chunking', p_vod_id, v_vod_duration;
    RETURN 0;
  END IF;

  -- If no Bazaar chapters (entire VOD is Bazaar), treat whole VOD as one segment
  IF v_bazaar_chapters IS NULL OR array_length(v_bazaar_chapters, 1) IS NULL OR array_length(v_bazaar_chapters, 1) = 0 THEN
    v_bazaar_chapters := ARRAY[0, v_vod_duration];
  END IF;

  -- Process each Bazaar segment (check array length again for safety)
  IF array_length(v_bazaar_chapters, 1) IS NOT NULL AND array_length(v_bazaar_chapters, 1) > 0 THEN
    FOR i IN 1..array_length(v_bazaar_chapters, 1) BY 2 LOOP
      v_segment_start := v_bazaar_chapters[i];
      v_segment_end := v_bazaar_chapters[i + 1];

      -- Skip if segment end is null (shouldn't happen, but safety check)
      IF v_segment_end IS NULL THEN
        CONTINUE;
      END IF;

      v_segment_duration := v_segment_end - v_segment_start;

      -- Skip very short segments (less than 10 minutes)
      IF v_segment_duration < 600 THEN
        RAISE NOTICE 'Skipping short Bazaar segment (% seconds) in VOD %', v_segment_duration, p_vod_id;
        CONTINUE;
      END IF;

      -- If segment is less than minimum chunk duration, make it one chunk
      IF v_segment_duration <= p_min_chunk_duration THEN
        INSERT INTO chunks (vod_id, start_seconds, end_seconds, chunk_index)
        VALUES (p_vod_id, v_segment_start, v_segment_end, v_chunk_index)
        ON CONFLICT (vod_id, chunk_index) DO NOTHING;

        v_chunk_count := v_chunk_count + 1;
        v_chunk_index := v_chunk_index + 1;

        RAISE NOTICE 'Created single chunk for segment: % - % (% seconds)',
          v_segment_start, v_segment_end, v_segment_duration;
      ELSE
        -- Calculate optimal chunk count to avoid small remainders
        v_num_chunks := CEIL(v_segment_duration::float / p_min_chunk_duration);

        -- If the last chunk would be less than 1 hour, merge it with previous
        -- Example: 1h30m -> 1 chunk of 1h30m, not 1h + 30m
        IF v_segment_duration % p_min_chunk_duration > 0 AND
           v_segment_duration % p_min_chunk_duration < p_min_chunk_duration AND
           v_num_chunks > 1 THEN
          v_num_chunks := v_num_chunks - 1;
        END IF;

        -- Calculate actual chunk duration for this segment
        v_chunk_duration := CEIL(v_segment_duration::float / v_num_chunks);

        -- Create chunks for this segment
        v_current_start := v_segment_start;
        FOR j IN 1..v_num_chunks LOOP
          v_current_end := LEAST(v_current_start + v_chunk_duration, v_segment_end);

          -- Last chunk gets any remainder
          IF j = v_num_chunks THEN
            v_current_end := v_segment_end;
          END IF;

          INSERT INTO chunks (vod_id, start_seconds, end_seconds, chunk_index)
          VALUES (p_vod_id, v_current_start, v_current_end, v_chunk_index)
          ON CONFLICT (vod_id, chunk_index) DO NOTHING;

          RAISE NOTICE 'Created chunk %: % - % (% seconds)',
            v_chunk_index, v_current_start, v_current_end, (v_current_end - v_current_start);

          v_chunk_count := v_chunk_count + 1;
          v_chunk_index := v_chunk_index + 1;
          v_current_start := v_current_end;
        END LOOP;
      END IF;
    END LOOP;
  END IF;  -- End of array length check

  RAISE NOTICE 'Created % chunks for VOD %', v_chunk_count, p_vod_id;
  RETURN v_chunk_count;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.create_chunks_for_enabled_streamer()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.processing_enabled = TRUE AND OLD.processing_enabled = FALSE THEN
    -- Create chunks for all ready VODs for this streamer
    PERFORM create_chunks_for_segment(v.id, 0, v.duration_seconds)
    FROM vods v
    WHERE v.streamer_id = NEW.id 
    AND v.ready_for_processing = TRUE;
  END IF;
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.create_chunks_for_segment(p_vod_id bigint, p_start_seconds integer, p_end_seconds integer, p_chunk_duration_seconds integer DEFAULT 1800)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_chunk_count INT := 0;
  v_current_start INT := p_start_seconds;
  v_current_end INT;
  v_chunk_index INT := 0;
BEGIN
  WHILE v_current_start < p_end_seconds LOOP
    v_current_end := LEAST(v_current_start + p_chunk_duration_seconds, p_end_seconds);
    
    INSERT INTO chunks (vod_id, start_seconds, end_seconds, chunk_index)
    VALUES (p_vod_id, v_current_start, v_current_end, v_chunk_index)
    ON CONFLICT (vod_id, chunk_index) DO NOTHING;
    
    v_chunk_count := v_chunk_count + 1;
    v_current_start := v_current_end;
    v_chunk_index := v_chunk_index + 1;
  END LOOP;
  
  RETURN v_chunk_count;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.cron_insert_new_streamers()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_response_id bigint;
  v_status_code integer;
  v_anon_key text;
  v_url text;
BEGIN
  -- Get the anon key from environment or use the local dev key
  -- In production, this should be set as a secret
  v_anon_key := COALESCE(
    current_setting('app.settings.anon_key', true),
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0'
  );

  -- Construct the URL (local or production based on environment)
  v_url := COALESCE(
    current_setting('app.settings.edge_function_url', true) || '/insert-new-streamers',
    'http://localhost:54321/functions/v1/insert-new-streamers'
  );

  -- Call the edge function using pg_net
  SELECT net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || v_anon_key,
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000
  ) INTO v_response_id;

  -- Wait for response (optional - remove for async)
  SELECT status_code
  INTO v_status_code
  FROM net._http_response
  WHERE id = v_response_id;

  IF v_status_code IS NOT NULL AND v_status_code != 200 THEN
    RAISE WARNING 'insert-new-streamers returned status code: %', v_status_code;
  END IF;

  RAISE NOTICE 'Called insert-new-streamers edge function, response_id: %', v_response_id;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.cron_process_pending_vods()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_processed_count INTEGER;
BEGIN
    -- Process up to 10 VODs
    SELECT COUNT(*)
    INTO v_processed_count
    FROM process_pending_vods(10);

    -- Log to vod_processing_log table if it exists
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public'
        AND table_name = 'vod_processing_log'
    ) THEN
        INSERT INTO vod_processing_log (
            job_name,
            vods_processed,
            metadata
        ) VALUES (
            'cron_process_pending_vods',
            v_processed_count,
            jsonb_build_object(
                'vods_scheduled', v_processed_count,
                'triggered_by', 'pg_cron'
            )
        );
    END IF;

    -- Log to console for monitoring
    RAISE NOTICE 'Cron job processed % VODs', v_processed_count;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.cron_update_streamer_vods()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$DECLARE
  v_streamer RECORD;
  v_response_id bigint;
  v_status_code integer;
  v_anon_key text;
  v_url text;
  v_updated_count integer := 0;
BEGIN
  -- Get the anon key from environment
v_anon_key := COALESCE( (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'service_role_key' LIMIT 1), current_setting('app.settings.service_role_key', true), current_setting('app.settings.anon_key', true) );

  -- Base URL for edge functions
  v_url := 'https://dzklnkhayqmwldnjxywr.supabase.co/functions/v1/update-vods';

  -- Find streamers that:
  -- 1. Have processing enabled
  -- 2. Either have has_vods = true, OR their created_at = updated_at (never updated since creation)
  -- 3. Haven't been updated in the last 24 hours
  FOR v_streamer IN
    SELECT id, login, updated_at
    FROM streamers
    WHERE processing_enabled = true
      AND (
        has_vods = true
        OR (created_at = updated_at)
        OR has_vods IS NULL
      )
      AND updated_at <= NOW() - INTERVAL '24 hours'
    ORDER BY updated_at ASC
    LIMIT 10  -- Process max 10 streamers per run to avoid timeout
  LOOP
    BEGIN
      -- Call update-vods for this streamer
      SELECT net.http_post(
        url := v_url,
        headers := jsonb_build_object(
          'Authorization', 'Bearer ' || v_anon_key,
          'Content-Type', 'application/json'
        ),
        body := jsonb_build_object('streamer_id', v_streamer.id),
        timeout_milliseconds := 60000  -- 60 seconds per streamer
      ) INTO v_response_id;

      v_updated_count := v_updated_count + 1;

      RAISE NOTICE 'Called update-vods for streamer % (%)', v_streamer.login, v_streamer.id;

      -- Small delay between calls to avoid rate limiting
      PERFORM pg_sleep(1);

    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Failed to update VODs for streamer % (%): %',
        v_streamer.login, v_streamer.id, SQLERRM;
    END;
  END LOOP;

  RAISE NOTICE 'Updated VODs for % streamers', v_updated_count;
END;$function$
;

CREATE OR REPLACE FUNCTION public.get_pending_chunks_for_vod(p_vod_id bigint DEFAULT NULL::bigint, p_source_id text DEFAULT NULL::text)
 RETURNS TABLE(chunk_id uuid, vod_id bigint, source_id text, chunk_index integer, start_seconds integer, end_seconds integer, status processing_status, attempt_count integer)
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- Validate input parameters
    IF p_vod_id IS NULL AND p_source_id IS NULL THEN
        RAISE EXCEPTION 'Must provide either p_vod_id or p_source_id';
    END IF;

    RETURN QUERY
    SELECT
        c.id as chunk_id,
        c.vod_id,
        v.source_id,
        c.chunk_index,
        c.start_seconds,
        c.end_seconds,
        c.status,
        c.attempt_count
    FROM chunks c
    JOIN vods v ON v.id = c.vod_id
    WHERE
        -- Match by either vod_id or source_id
        (p_vod_id IS NOT NULL AND c.vod_id = p_vod_id
         OR
         p_source_id IS NOT NULL AND v.source_id = p_source_id)
        -- Only get chunks that are pending (not queued, processing, completed, or failed)
        AND c.status = 'pending'
        -- VOD must be available
        AND v.availability = 'available'
        -- VOD must be ready for processing
        AND v.ready_for_processing = TRUE
        -- Streamer must be enabled for processing
        AND EXISTS (
            SELECT 1 FROM streamers s
            WHERE s.id = v.streamer_id
            AND s.processing_enabled = TRUE
        )
    ORDER BY
        c.chunk_index ASC;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.get_pending_vods_count()
 RETURNS TABLE(total_vods bigint, total_pending_chunks bigint, ready_vods bigint)
 LANGUAGE sql
AS $function$
    WITH vod_stats AS (
        SELECT
            v.id,
            COUNT(c.id) AS pending_chunks
        FROM vods v
        INNER JOIN chunks c ON c.vod_id = v.id
        WHERE
            -- VOD is ready for processing
            v.ready_for_processing = TRUE
            -- VOD must be available on Twitch
            AND v.availability = 'available'
            -- Has chunks that are pending (not queued, processing, completed, or failed)
            AND c.status = 'pending'
            -- Streamer is enabled for processing
            AND EXISTS (
                SELECT 1 FROM streamers s
                WHERE s.id = v.streamer_id
                AND s.processing_enabled = TRUE
            )
        GROUP BY v.id
    )
    SELECT
        COUNT(*)::BIGINT AS total_vods,
        SUM(pending_chunks)::BIGINT AS total_pending_chunks,
        COUNT(*)::BIGINT AS ready_vods
    FROM vod_stats;
$function$
;

CREATE OR REPLACE FUNCTION public.manual_process_pending_vods(max_vods integer DEFAULT 10)
 RETURNS TABLE(vod_id bigint, source_id text, pending_chunks bigint, request_id bigint)
 LANGUAGE sql
 SECURITY DEFINER
AS $function$
    SELECT * FROM process_pending_vods(max_vods);
$function$
;

CREATE OR REPLACE FUNCTION public.process_pending_vods(max_vods integer DEFAULT 5)
 RETURNS TABLE(vod_id bigint, source_id text, pending_chunks bigint, request_id bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_supabase_url TEXT;
    v_service_role_key TEXT;
    v_vod RECORD;
    v_request_id BIGINT;
    v_processed_count INTEGER := 0;
BEGIN
    -- Get credentials from Vault
    SELECT decrypted_secret INTO v_supabase_url
    FROM vault.decrypted_secrets
    WHERE name = 'supabase_url';

    SELECT decrypted_secret INTO v_service_role_key
    FROM vault.decrypted_secrets
    WHERE name = 'service_role_key';

    -- Check if credentials are available
    IF v_supabase_url IS NULL OR v_service_role_key IS NULL THEN
        RAISE EXCEPTION 'Missing Supabase credentials in Vault. Please configure supabase_url and service_role_key.';
    END IF;

    -- Find VODs with pending chunks
    FOR v_vod IN
        SELECT
            v.id AS vod_id,
            v.source_id,
            COUNT(c.id) AS pending_chunks,
            MIN(c.attempt_count) AS min_attempt_count,
            v.published_at
        FROM vods v
        INNER JOIN chunks c ON c.vod_id = v.id
        WHERE
            -- VOD is ready for processing
            v.ready_for_processing = TRUE
            -- VOD is available
            AND v.availability = 'available'
            -- Has chunks that are pending
            AND c.status = 'pending'
            -- Streamer is enabled for processing
            AND EXISTS (
                SELECT 1 FROM streamers s
                WHERE s.id = v.streamer_id
                AND s.processing_enabled = TRUE
            )
        GROUP BY v.id, v.source_id, v.published_at
        -- Prioritize VODs with fewer processing attempts
        ORDER BY
            MIN(c.attempt_count) ASC,
            v.published_at DESC
        LIMIT max_vods
    LOOP
        -- Call process-vod edge function directly
        -- It will handle updating chunks to queued and triggering GitHub
        SELECT net.http_post(
            url := v_supabase_url || '/functions/v1/process-vod',
            headers := jsonb_build_object(
                'Content-Type', 'application/json',
                'Authorization', 'Bearer ' || v_service_role_key
            ),
            body := jsonb_build_object(
                'vod_id', v_vod.vod_id,  -- Internal VOD ID
                'source_id', v_vod.source_id  -- Also send source_id for redundancy
            ),
            timeout_milliseconds := 10000  -- 10 second timeout
        ) INTO v_request_id;

        -- Log the processing attempt
        RAISE NOTICE 'Scheduled processing for VOD % (source: %) with % pending chunks. Request ID: %',
            v_vod.vod_id, v_vod.source_id, v_vod.pending_chunks, v_request_id;

        -- Return the result
        RETURN QUERY
        SELECT
            v_vod.vod_id,
            v_vod.source_id,
            v_vod.pending_chunks,
            v_request_id;

        v_processed_count := v_processed_count + 1;
    END LOOP;

    -- Log to vod_processing_log table if it exists
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public'
        AND table_name = 'vod_processing_log'
    ) THEN
        INSERT INTO vod_processing_log (
            job_name,
            vods_processed,
            metadata
        ) VALUES (
            'process_pending_vods',
            v_processed_count,
            jsonb_build_object(
                'max_vods_requested', max_vods,
                'vods_found', v_processed_count
            )
        );
    END IF;

    -- If no VODs were processed, log it
    IF v_processed_count = 0 THEN
        RAISE NOTICE 'No VODs with pending chunks found for processing';
    END IF;

    RETURN;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.trigger_vod_status_change()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  -- Only trigger when VOD goes from 'processing' to another state
  IF OLD.status = 'processing' AND NEW.status != 'processing' THEN
    RAISE NOTICE 'VOD % finished processing (status: %), checking for next VOD to queue',
      NEW.id, NEW.status;

    -- Schedule the auto-queue check asynchronously
    -- Using pg_notify to avoid blocking the transaction
    PERFORM pg_notify('vod_completed', NEW.id::text);

    -- For immediate processing in same transaction (optional)
    PERFORM public.auto_queue_next_vod();
  END IF;

  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.update_chunk_status(p_chunk_id uuid, p_status text, p_error_message text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    result_count INTEGER;
    chunk_record RECORD;
BEGIN
    -- Validate status input
    IF p_status NOT IN ('pending', 'processing', 'completed', 'failed') THEN
        RAISE EXCEPTION 'Invalid status: %. Must be one of: pending, processing, completed, failed', p_status;
    END IF;

    -- Update chunk based on status
    UPDATE chunks SET
        status = p_status::processing_status,
        updated_at = now(),
        -- Status-specific updates
        started_at = CASE
            WHEN p_status = 'processing' THEN now()
            WHEN p_status = 'pending' THEN NULL
            ELSE started_at
        END,
        completed_at = CASE
            WHEN p_status IN ('completed', 'failed') THEN now()
            ELSE NULL
        END,
        attempt_count = CASE
            WHEN p_status IN ('pending', 'failed') THEN attempt_count + 1
            ELSE attempt_count
        END,
        last_error = CASE
            WHEN p_status IN ('pending', 'failed') AND p_error_message IS NOT NULL THEN p_error_message
            WHEN p_status IN ('processing', 'completed') THEN NULL
            ELSE last_error
        END
    WHERE id = p_chunk_id;

    GET DIAGNOSTICS result_count = ROW_COUNT;

    IF result_count = 0 THEN
        RAISE EXCEPTION 'Chunk with ID % not found', p_chunk_id;
    END IF;

    -- Get updated record for return
    SELECT * INTO chunk_record FROM chunks WHERE id = p_chunk_id;

    RETURN json_build_object(
        'success', true,
        'chunk_id', p_chunk_id,
        'status', chunk_record.status,
        'attempt_count', chunk_record.attempt_count,
        'started_at', chunk_record.started_at,
        'completed_at', chunk_record.completed_at
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN json_build_object(
            'success', false,
            'error', SQLERRM,
            'chunk_id', p_chunk_id
        );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.update_vod_status()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_vod_id bigint;
  v_chunk_count integer;
  v_pending_count integer;
  v_queued_count integer;
  v_processing_count integer;
  v_completed_count integer;
  v_failed_count integer;
  v_new_status public.vod_status;
  v_old_status public.vod_status;
BEGIN
  -- Determine which VOD to update based on trigger event
  IF TG_OP = 'DELETE' THEN
    v_vod_id := OLD.vod_id;
  ELSE
    v_vod_id := NEW.vod_id;
  END IF;

  -- Skip if no VOD ID
  IF v_vod_id IS NULL THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  -- Get current VOD status
  SELECT status INTO v_old_status FROM public.vods WHERE id = v_vod_id;

  -- Count chunks by status
  SELECT
    COUNT(*),
    COUNT(*) FILTER (WHERE status = 'pending'),
    COUNT(*) FILTER (WHERE status = 'queued'),
    COUNT(*) FILTER (WHERE status = 'processing'),
    COUNT(*) FILTER (WHERE status = 'completed'),
    COUNT(*) FILTER (WHERE status = 'failed')
  INTO
    v_chunk_count,
    v_pending_count,
    v_queued_count,
    v_processing_count,
    v_completed_count,
    v_failed_count
  FROM public.chunks
  WHERE vod_id = v_vod_id;

  -- Determine new VOD status
  IF v_chunk_count = 0 OR v_chunk_count = v_pending_count THEN
    v_new_status := 'pending';
  ELSIF v_queued_count > 0 OR v_processing_count > 0 THEN
    v_new_status := 'processing';
  ELSIF v_chunk_count = v_completed_count THEN
    v_new_status := 'completed';
  ELSIF v_chunk_count = v_failed_count THEN
    v_new_status := 'failed';
  ELSE
    v_new_status := 'partial';
  END IF;

  -- Update VOD status if changed
  IF v_old_status IS DISTINCT FROM v_new_status THEN
    UPDATE public.vods
    SET
      status = v_new_status,
      updated_at = now()
    WHERE id = v_vod_id;

    RAISE NOTICE 'VOD % status changed from % to %', v_vod_id, v_old_status, v_new_status;
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$function$
;


revoke delete on table "test"."cataloger_runs" from "anon";

revoke insert on table "test"."cataloger_runs" from "anon";

revoke references on table "test"."cataloger_runs" from "anon";

revoke select on table "test"."cataloger_runs" from "anon";

revoke trigger on table "test"."cataloger_runs" from "anon";

revoke truncate on table "test"."cataloger_runs" from "anon";

revoke update on table "test"."cataloger_runs" from "anon";

revoke delete on table "test"."cataloger_runs" from "authenticated";

revoke insert on table "test"."cataloger_runs" from "authenticated";

revoke references on table "test"."cataloger_runs" from "authenticated";

revoke select on table "test"."cataloger_runs" from "authenticated";

revoke trigger on table "test"."cataloger_runs" from "authenticated";

revoke truncate on table "test"."cataloger_runs" from "authenticated";

revoke update on table "test"."cataloger_runs" from "authenticated";

revoke delete on table "test"."cataloger_runs" from "service_role";

revoke insert on table "test"."cataloger_runs" from "service_role";

revoke references on table "test"."cataloger_runs" from "service_role";

revoke select on table "test"."cataloger_runs" from "service_role";

revoke trigger on table "test"."cataloger_runs" from "service_role";

revoke truncate on table "test"."cataloger_runs" from "service_role";

revoke update on table "test"."cataloger_runs" from "service_role";

revoke delete on table "test"."chunks" from "anon";

revoke insert on table "test"."chunks" from "anon";

revoke references on table "test"."chunks" from "anon";

revoke select on table "test"."chunks" from "anon";

revoke trigger on table "test"."chunks" from "anon";

revoke truncate on table "test"."chunks" from "anon";

revoke update on table "test"."chunks" from "anon";

revoke delete on table "test"."chunks" from "authenticated";

revoke insert on table "test"."chunks" from "authenticated";

revoke references on table "test"."chunks" from "authenticated";

revoke select on table "test"."chunks" from "authenticated";

revoke trigger on table "test"."chunks" from "authenticated";

revoke truncate on table "test"."chunks" from "authenticated";

revoke update on table "test"."chunks" from "authenticated";

revoke delete on table "test"."chunks" from "service_role";

revoke insert on table "test"."chunks" from "service_role";

revoke references on table "test"."chunks" from "service_role";

revoke select on table "test"."chunks" from "service_role";

revoke trigger on table "test"."chunks" from "service_role";

revoke truncate on table "test"."chunks" from "service_role";

revoke update on table "test"."chunks" from "service_role";

revoke delete on table "test"."detections" from "anon";

revoke insert on table "test"."detections" from "anon";

revoke references on table "test"."detections" from "anon";

revoke select on table "test"."detections" from "anon";

revoke trigger on table "test"."detections" from "anon";

revoke truncate on table "test"."detections" from "anon";

revoke update on table "test"."detections" from "anon";

revoke delete on table "test"."detections" from "authenticated";

revoke insert on table "test"."detections" from "authenticated";

revoke references on table "test"."detections" from "authenticated";

revoke select on table "test"."detections" from "authenticated";

revoke trigger on table "test"."detections" from "authenticated";

revoke truncate on table "test"."detections" from "authenticated";

revoke update on table "test"."detections" from "authenticated";

revoke delete on table "test"."detections" from "service_role";

revoke insert on table "test"."detections" from "service_role";

revoke references on table "test"."detections" from "service_role";

revoke select on table "test"."detections" from "service_role";

revoke trigger on table "test"."detections" from "service_role";

revoke truncate on table "test"."detections" from "service_role";

revoke update on table "test"."detections" from "service_role";

revoke delete on table "test"."processing_config" from "anon";

revoke insert on table "test"."processing_config" from "anon";

revoke references on table "test"."processing_config" from "anon";

revoke select on table "test"."processing_config" from "anon";

revoke trigger on table "test"."processing_config" from "anon";

revoke truncate on table "test"."processing_config" from "anon";

revoke update on table "test"."processing_config" from "anon";

revoke delete on table "test"."processing_config" from "authenticated";

revoke insert on table "test"."processing_config" from "authenticated";

revoke references on table "test"."processing_config" from "authenticated";

revoke select on table "test"."processing_config" from "authenticated";

revoke trigger on table "test"."processing_config" from "authenticated";

revoke truncate on table "test"."processing_config" from "authenticated";

revoke update on table "test"."processing_config" from "authenticated";

revoke delete on table "test"."processing_config" from "service_role";

revoke insert on table "test"."processing_config" from "service_role";

revoke references on table "test"."processing_config" from "service_role";

revoke select on table "test"."processing_config" from "service_role";

revoke trigger on table "test"."processing_config" from "service_role";

revoke truncate on table "test"."processing_config" from "service_role";

revoke update on table "test"."processing_config" from "service_role";

revoke delete on table "test"."sfot_profiles" from "anon";

revoke insert on table "test"."sfot_profiles" from "anon";

revoke references on table "test"."sfot_profiles" from "anon";

revoke select on table "test"."sfot_profiles" from "anon";

revoke trigger on table "test"."sfot_profiles" from "anon";

revoke truncate on table "test"."sfot_profiles" from "anon";

revoke update on table "test"."sfot_profiles" from "anon";

revoke delete on table "test"."sfot_profiles" from "authenticated";

revoke insert on table "test"."sfot_profiles" from "authenticated";

revoke references on table "test"."sfot_profiles" from "authenticated";

revoke select on table "test"."sfot_profiles" from "authenticated";

revoke trigger on table "test"."sfot_profiles" from "authenticated";

revoke truncate on table "test"."sfot_profiles" from "authenticated";

revoke update on table "test"."sfot_profiles" from "authenticated";

revoke delete on table "test"."sfot_profiles" from "service_role";

revoke insert on table "test"."sfot_profiles" from "service_role";

revoke references on table "test"."sfot_profiles" from "service_role";

revoke select on table "test"."sfot_profiles" from "service_role";

revoke trigger on table "test"."sfot_profiles" from "service_role";

revoke truncate on table "test"."sfot_profiles" from "service_role";

revoke update on table "test"."sfot_profiles" from "service_role";

revoke delete on table "test"."streamers" from "anon";

revoke insert on table "test"."streamers" from "anon";

revoke references on table "test"."streamers" from "anon";

revoke select on table "test"."streamers" from "anon";

revoke trigger on table "test"."streamers" from "anon";

revoke truncate on table "test"."streamers" from "anon";

revoke update on table "test"."streamers" from "anon";

revoke delete on table "test"."streamers" from "authenticated";

revoke insert on table "test"."streamers" from "authenticated";

revoke references on table "test"."streamers" from "authenticated";

revoke select on table "test"."streamers" from "authenticated";

revoke trigger on table "test"."streamers" from "authenticated";

revoke truncate on table "test"."streamers" from "authenticated";

revoke update on table "test"."streamers" from "authenticated";

revoke delete on table "test"."streamers" from "service_role";

revoke insert on table "test"."streamers" from "service_role";

revoke references on table "test"."streamers" from "service_role";

revoke select on table "test"."streamers" from "service_role";

revoke trigger on table "test"."streamers" from "service_role";

revoke truncate on table "test"."streamers" from "service_role";

revoke update on table "test"."streamers" from "service_role";

revoke delete on table "test"."vods" from "anon";

revoke insert on table "test"."vods" from "anon";

revoke references on table "test"."vods" from "anon";

revoke select on table "test"."vods" from "anon";

revoke trigger on table "test"."vods" from "anon";

revoke truncate on table "test"."vods" from "anon";

revoke update on table "test"."vods" from "anon";

revoke delete on table "test"."vods" from "authenticated";

revoke insert on table "test"."vods" from "authenticated";

revoke references on table "test"."vods" from "authenticated";

revoke select on table "test"."vods" from "authenticated";

revoke trigger on table "test"."vods" from "authenticated";

revoke truncate on table "test"."vods" from "authenticated";

revoke update on table "test"."vods" from "authenticated";

revoke delete on table "test"."vods" from "service_role";

revoke insert on table "test"."vods" from "service_role";

revoke references on table "test"."vods" from "service_role";

revoke select on table "test"."vods" from "service_role";

revoke trigger on table "test"."vods" from "service_role";

revoke truncate on table "test"."vods" from "service_role";

revoke update on table "test"."vods" from "service_role";



