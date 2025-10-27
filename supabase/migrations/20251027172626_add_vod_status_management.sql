

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE SCHEMA IF NOT EXISTS "test";


ALTER SCHEMA "test" OWNER TO "postgres";


COMMENT ON SCHEMA "test" IS 'Test schema exposed via REST API - remember to add to API settings';



CREATE EXTENSION IF NOT EXISTS "btree_gist" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."chunk_source" AS ENUM (
    'vod',
    'live'
);


ALTER TYPE "public"."chunk_source" OWNER TO "postgres";


CREATE TYPE "public"."processing_status" AS ENUM (
    'pending',
    'queued',
    'processing',
    'completed',
    'failed',
    'archived'
);


ALTER TYPE "public"."processing_status" OWNER TO "postgres";


CREATE TYPE "public"."vod_availability" AS ENUM (
    'available',
    'checking',
    'unavailable',
    'expired'
);


ALTER TYPE "public"."vod_availability" OWNER TO "postgres";


CREATE TYPE "public"."vod_status" AS ENUM (
    'pending',
    'processing',
    'completed',
    'failed',
    'partial'
);


ALTER TYPE "public"."vod_status" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."auto_create_chunks"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
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
$$;


ALTER FUNCTION "public"."auto_create_chunks"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."auto_queue_next_vod"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
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
$$;


ALTER FUNCTION "public"."auto_queue_next_vod"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."auto_queue_next_vod"() IS 'Queues all chunks from the next pending VOD if under concurrency limit';



CREATE OR REPLACE FUNCTION "public"."cleanup_streamer_chunks_on_disable"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF NEW.processing_enabled = FALSE THEN
    DELETE FROM chunks 
    WHERE vod_id IN (SELECT id FROM vods WHERE streamer_id = NEW.id)
    AND status IN ('pending', 'processing');
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."cleanup_streamer_chunks_on_disable"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cleanup_vod_chunks_on_disable"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF NEW.ready_for_processing = FALSE THEN
    DELETE FROM chunks 
    WHERE vod_id = NEW.id
    AND status IN ('pending', 'processing');
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."cleanup_vod_chunks_on_disable"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_bazaar_aware_chunks"("p_vod_id" bigint, "p_min_chunk_duration" integer DEFAULT 3600) RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
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
$$;


ALTER FUNCTION "public"."create_bazaar_aware_chunks"("p_vod_id" bigint, "p_min_chunk_duration" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_chunks_for_enabled_streamer"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
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
$$;


ALTER FUNCTION "public"."create_chunks_for_enabled_streamer"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_chunks_for_segment"("p_vod_id" bigint, "p_start_seconds" integer, "p_end_seconds" integer, "p_chunk_duration_seconds" integer DEFAULT 1800) RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
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
$$;


ALTER FUNCTION "public"."create_chunks_for_segment"("p_vod_id" bigint, "p_start_seconds" integer, "p_end_seconds" integer, "p_chunk_duration_seconds" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cron_insert_new_streamers"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
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
$$;


ALTER FUNCTION "public"."cron_insert_new_streamers"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."cron_insert_new_streamers"() IS 'Calls insert-new-streamers edge function daily at 00:00 UTC via cron';



CREATE OR REPLACE FUNCTION "public"."cron_process_pending_vods"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
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
$$;


ALTER FUNCTION "public"."cron_process_pending_vods"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."cron_process_pending_vods"() IS 'Wrapper function for pg_cron to process pending VODs';



CREATE OR REPLACE FUNCTION "public"."cron_update_streamer_vods"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_streamer RECORD;
  v_response_id bigint;
  v_status_code integer;
  v_anon_key text;
  v_url text;
  v_updated_count integer := 0;
BEGIN
  -- Get the anon key from environment or use the local dev key
  v_anon_key := COALESCE(
    current_setting('app.settings.anon_key', true),
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0'
  );

  -- Base URL for edge functions
  v_url := COALESCE(
    current_setting('app.settings.edge_function_url', true) || '/update-vods',
    'http://localhost:54321/functions/v1/update-vods'
  );

  -- Find streamers that:
  -- 1. Have processing enabled
  -- 2. Have has_vods = true (or NULL for backward compatibility)
  -- 3. Haven't been updated in the last 24 hours
  FOR v_streamer IN
    SELECT id, login, updated_at
    FROM streamers
    WHERE processing_enabled = true
      AND (has_vods = true OR has_vods IS NULL)
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
END;
$$;


ALTER FUNCTION "public"."cron_update_streamer_vods"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."cron_update_streamer_vods"() IS 'Updates VODs for streamers that have not been updated in 24+ hours, runs hourly';



CREATE OR REPLACE FUNCTION "public"."get_pending_chunks_for_vod"("p_vod_id" bigint DEFAULT NULL::bigint, "p_source_id" "text" DEFAULT NULL::"text") RETURNS TABLE("chunk_id" "uuid", "vod_id" bigint, "source_id" "text", "chunk_index" integer, "start_seconds" integer, "end_seconds" integer, "status" "public"."processing_status", "attempt_count" integer)
    LANGUAGE "plpgsql"
    AS $$
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
$$;


ALTER FUNCTION "public"."get_pending_chunks_for_vod"("p_vod_id" bigint, "p_source_id" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_pending_chunks_for_vod"("p_vod_id" bigint, "p_source_id" "text") IS 'Gets only pending chunks for a VOD (excluding queued, processing, completed, failed)';



CREATE OR REPLACE FUNCTION "public"."get_pending_vods_count"() RETURNS TABLE("total_vods" bigint, "total_pending_chunks" bigint, "ready_vods" bigint)
    LANGUAGE "sql"
    AS $$
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
$$;


ALTER FUNCTION "public"."get_pending_vods_count"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_pending_vods_count"() IS 'Returns statistics about available VODs with pending chunks only';



CREATE OR REPLACE FUNCTION "public"."manual_process_pending_vods"("max_vods" integer DEFAULT 10) RETURNS TABLE("vod_id" bigint, "source_id" "text", "pending_chunks" bigint, "request_id" bigint)
    LANGUAGE "sql" SECURITY DEFINER
    AS $$
    SELECT * FROM process_pending_vods(max_vods);
$$;


ALTER FUNCTION "public"."manual_process_pending_vods"("max_vods" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."manual_process_pending_vods"("max_vods" integer) IS 'Manual trigger for testing VOD processing scheduling';



CREATE OR REPLACE FUNCTION "public"."process_pending_vods"("max_vods" integer DEFAULT 5) RETURNS TABLE("vod_id" bigint, "source_id" "text", "pending_chunks" bigint, "request_id" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
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

    -- Find VODs with pending chunks (only 'pending' status, not 'queued' or others)
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
            -- Has chunks that are pending (not queued, processing, completed, or failed)
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
        -- Make async HTTP call to process-vod edge function
        SELECT net.http_post(
            url := v_supabase_url || '/functions/v1/process-vod',
            headers := jsonb_build_object(
                'Content-Type', 'application/json',
                'Authorization', 'Bearer ' || v_service_role_key,
                'apikey', v_service_role_key
            ),
            body := jsonb_build_object(
                'vod_id', v_vod.vod_id::TEXT,
                'source_id', v_vod.source_id
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
$$;


ALTER FUNCTION "public"."process_pending_vods"("max_vods" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."process_pending_vods"("max_vods" integer) IS 'Selects up to N VODs with pending chunks and triggers processing via edge function';



CREATE OR REPLACE FUNCTION "public"."trigger_vod_status_change"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
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
$$;


ALTER FUNCTION "public"."trigger_vod_status_change"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."trigger_vod_status_change"() IS 'Handles VOD status changes and triggers auto-queuing of next VOD';



CREATE OR REPLACE FUNCTION "public"."update_chunk_status"("p_chunk_id" "uuid", "p_status" "text", "p_error_message" "text" DEFAULT NULL::"text") RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
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
$$;


ALTER FUNCTION "public"."update_chunk_status"("p_chunk_id" "uuid", "p_status" "text", "p_error_message" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_vod_status"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
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
$$;


ALTER FUNCTION "public"."update_vod_status"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."update_vod_status"() IS 'Updates VOD status based on the status of all its chunks';


SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."cataloger_runs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "run_type" "text",
    "started_at" timestamp with time zone DEFAULT "now"(),
    "completed_at" timestamp with time zone,
    "streamers_discovered" integer DEFAULT 0,
    "streamers_updated" integer DEFAULT 0,
    "vods_discovered" integer DEFAULT 0,
    "chunks_created" integer DEFAULT 0,
    "errors" "jsonb" DEFAULT '[]'::"jsonb",
    "status" "text" DEFAULT 'running'::"text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    CONSTRAINT "cataloger_runs_run_type_check" CHECK (("run_type" = ANY (ARRAY['discovery'::"text", 'refresh'::"text", 'backfill'::"text"])))
);


ALTER TABLE "public"."cataloger_runs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."chunks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "vod_id" bigint,
    "start_seconds" integer NOT NULL,
    "end_seconds" integer NOT NULL,
    "chunk_index" integer NOT NULL,
    "status" "public"."processing_status" DEFAULT 'pending'::"public"."processing_status",
    "source" "public"."chunk_source" DEFAULT 'vod'::"public"."chunk_source",
    "queued_at" timestamp with time zone,
    "started_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "attempt_count" integer DEFAULT 0,
    "last_error" "text",
    "frames_processed" integer DEFAULT 0,
    "detections_count" integer DEFAULT 0,
    "processing_duration_ms" integer,
    "priority" integer DEFAULT 0,
    "scheduled_for" timestamp with time zone DEFAULT "now"(),
    "lease_expires_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "quality" "text"
);


ALTER TABLE "public"."chunks" OWNER TO "postgres";


COMMENT ON COLUMN "public"."chunks"."quality" IS 'Video quality/resolution used for processing this chunk (e.g., 360p, 720p, 1080p)';



CREATE OR REPLACE VIEW "public"."cron_job_status" AS
 SELECT "jobname",
    "schedule",
    "active",
    "jobid"
   FROM "cron"."job"
  WHERE ("jobname" = ANY (ARRAY['insert-new-streamers-daily'::"text", 'update-streamer-vods-hourly'::"text"]))
  ORDER BY "jobname";


ALTER VIEW "public"."cron_job_status" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."detections" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "chunk_id" "uuid",
    "vod_id" bigint,
    "username" "text" NOT NULL,
    "confidence" double precision,
    "rank" "text",
    "frame_time_seconds" integer NOT NULL,
    "storage_path" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "no_right_edge" boolean DEFAULT false,
    CONSTRAINT "detections_rank_check" CHECK (("rank" = ANY (ARRAY['bronze'::"text", 'silver'::"text", 'gold'::"text", 'diamond'::"text", 'legend'::"text"])))
);


ALTER TABLE "public"."detections" OWNER TO "postgres";


COMMENT ON COLUMN "public"."detections"."no_right_edge" IS 'Indicates if right edge detection failed, suggesting possible streamer cam occlusion';



CREATE TABLE IF NOT EXISTS "public"."processing_config" (
    "key" "text" NOT NULL,
    "value" "text" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."processing_config" OWNER TO "postgres";


COMMENT ON TABLE "public"."processing_config" IS 'Configuration settings for VOD processing system';



CREATE TABLE IF NOT EXISTS "public"."sfot_profiles" (
    "profile_name" "text" NOT NULL,
    "container_image" "text" NOT NULL,
    "container_tag" "text" NOT NULL,
    "frame_interval_seconds" integer DEFAULT 5,
    "confidence_threshold" double precision DEFAULT 0.7,
    "memory_mb" integer DEFAULT 2048,
    "cpu_millicores" integer DEFAULT 1000,
    "timeout_seconds" integer DEFAULT 1800,
    "enable_gpu" boolean DEFAULT false,
    "enable_debug_output" boolean DEFAULT false,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."sfot_profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."streamers" (
    "id" bigint NOT NULL,
    "login" "text" NOT NULL,
    "display_name" "text",
    "profile_image_url" "text",
    "processing_enabled" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "oldest_vod" timestamp with time zone,
    "num_vods" integer DEFAULT 0,
    "num_bazaar_vods" integer DEFAULT 0,
    "has_vods" boolean DEFAULT false
);


ALTER TABLE "public"."streamers" OWNER TO "postgres";


COMMENT ON COLUMN "public"."streamers"."oldest_vod" IS 'Timestamp of the oldest VOD from this streamer (any game, not just Bazaar)';



COMMENT ON COLUMN "public"."streamers"."num_vods" IS 'Total count of all VODs from this streamer';



COMMENT ON COLUMN "public"."streamers"."num_bazaar_vods" IS 'Count of VODs with Bazaar gameplay';



COMMENT ON COLUMN "public"."streamers"."has_vods" IS 'True if streamer has more than 1 VOD stored (indicating they keep their VODs)';



CREATE TABLE IF NOT EXISTS "public"."vods" (
    "id" bigint NOT NULL,
    "streamer_id" bigint,
    "source" "text" DEFAULT 'twitch'::"text" NOT NULL,
    "source_id" "text" NOT NULL,
    "title" "text",
    "duration_seconds" integer,
    "published_at" timestamp with time zone,
    "availability" "public"."vod_availability" DEFAULT 'available'::"public"."vod_availability",
    "last_availability_check" timestamp with time zone,
    "unavailable_since" timestamp with time zone,
    "ready_for_processing" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "bazaar_chapters" integer[] DEFAULT ARRAY[]::integer[],
    "status" "public"."vod_status" DEFAULT 'pending'::"public"."vod_status"
);


ALTER TABLE "public"."vods" OWNER TO "postgres";


COMMENT ON COLUMN "public"."vods"."bazaar_chapters" IS 'Time ranges (in seconds) where The Bazaar was played. Format: [start1, end1, start2, end2, ...] where even indices are start times and odd indices are end times';



COMMENT ON COLUMN "public"."vods"."status" IS 'Current processing status of the VOD based on its chunks';



ALTER TABLE "public"."vods" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."vods_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "test"."cataloger_runs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "run_type" "text",
    "started_at" timestamp with time zone DEFAULT "now"(),
    "completed_at" timestamp with time zone,
    "streamers_discovered" integer DEFAULT 0,
    "streamers_updated" integer DEFAULT 0,
    "vods_discovered" integer DEFAULT 0,
    "chunks_created" integer DEFAULT 0,
    "errors" "jsonb" DEFAULT '[]'::"jsonb",
    "status" "text" DEFAULT 'running'::"text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    CONSTRAINT "cataloger_runs_run_type_check" CHECK (("run_type" = ANY (ARRAY['discovery'::"text", 'refresh'::"text", 'backfill'::"text"]))),
    CONSTRAINT "test_cataloger_runs_run_type_check" CHECK (("run_type" = ANY (ARRAY['refresh'::"text", 'backfill'::"text"])))
);


ALTER TABLE "test"."cataloger_runs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "test"."chunks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "vod_id" bigint,
    "start_seconds" integer NOT NULL,
    "end_seconds" integer NOT NULL,
    "chunk_index" integer NOT NULL,
    "status" "public"."processing_status" DEFAULT 'pending'::"public"."processing_status",
    "source" "public"."chunk_source" DEFAULT 'vod'::"public"."chunk_source",
    "queued_at" timestamp with time zone,
    "started_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "attempt_count" integer DEFAULT 0,
    "last_error" "text",
    "frames_processed" integer DEFAULT 0,
    "detections_count" integer DEFAULT 0,
    "processing_duration_ms" integer,
    "priority" integer DEFAULT 0,
    "scheduled_for" timestamp with time zone DEFAULT "now"(),
    "lease_expires_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "quality" "text"
);


ALTER TABLE "test"."chunks" OWNER TO "postgres";


COMMENT ON COLUMN "test"."chunks"."quality" IS 'Video quality/resolution used for processing this chunk (e.g., 360p, 720p, 1080p)';



CREATE TABLE IF NOT EXISTS "test"."detections" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "chunk_id" "uuid",
    "vod_id" bigint,
    "username" "text" NOT NULL,
    "confidence" double precision,
    "rank" "text",
    "frame_time_seconds" integer NOT NULL,
    "storage_path" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "no_right_edge" boolean DEFAULT false,
    CONSTRAINT "detections_rank_check" CHECK (("rank" = ANY (ARRAY['bronze'::"text", 'silver'::"text", 'gold'::"text", 'diamond'::"text", 'legend'::"text"])))
);


ALTER TABLE "test"."detections" OWNER TO "postgres";


COMMENT ON COLUMN "test"."detections"."no_right_edge" IS 'Indicates if right edge detection failed, suggesting possible streamer cam occlusion';



CREATE TABLE IF NOT EXISTS "test"."processing_config" (
    "key" "text" NOT NULL,
    "value" "text" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "test"."processing_config" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "test"."sfot_profiles" (
    "profile_name" "text" NOT NULL,
    "container_image" "text" NOT NULL,
    "container_tag" "text" NOT NULL,
    "frame_interval_seconds" integer DEFAULT 5,
    "confidence_threshold" double precision DEFAULT 0.7,
    "memory_mb" integer DEFAULT 2048,
    "cpu_millicores" integer DEFAULT 1000,
    "timeout_seconds" integer DEFAULT 1800,
    "enable_gpu" boolean DEFAULT false,
    "enable_debug_output" boolean DEFAULT false,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "test"."sfot_profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "test"."streamers" (
    "id" bigint NOT NULL,
    "login" "text" NOT NULL,
    "display_name" "text",
    "profile_image_url" "text",
    "processing_enabled" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "oldest_vod" timestamp with time zone,
    "num_vods" integer DEFAULT 0,
    "num_bazaar_vods" integer DEFAULT 0,
    "has_vods" boolean DEFAULT false
);


ALTER TABLE "test"."streamers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "test"."vods" (
    "id" bigint NOT NULL,
    "streamer_id" bigint,
    "source" "text" DEFAULT 'twitch'::"text" NOT NULL,
    "source_id" "text" NOT NULL,
    "title" "text",
    "duration_seconds" integer,
    "published_at" timestamp with time zone,
    "availability" "public"."vod_availability" DEFAULT 'available'::"public"."vod_availability",
    "last_availability_check" timestamp with time zone,
    "unavailable_since" timestamp with time zone,
    "ready_for_processing" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "bazaar_chapters" integer[] DEFAULT ARRAY[]::integer[],
    "status" "public"."vod_status" DEFAULT 'pending'::"public"."vod_status"
);


ALTER TABLE "test"."vods" OWNER TO "postgres";


ALTER TABLE "test"."vods" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "test"."vods_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE ONLY "public"."cataloger_runs"
    ADD CONSTRAINT "cataloger_runs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."chunks"
    ADD CONSTRAINT "chunks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."chunks"
    ADD CONSTRAINT "chunks_vod_id_chunk_index_key" UNIQUE ("vod_id", "chunk_index");



ALTER TABLE ONLY "public"."chunks"
    ADD CONSTRAINT "chunks_vod_id_int4range_excl" EXCLUDE USING "gist" ("vod_id" WITH =, "int4range"("start_seconds", "end_seconds") WITH &&);



ALTER TABLE ONLY "public"."detections"
    ADD CONSTRAINT "detections_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."processing_config"
    ADD CONSTRAINT "processing_config_pkey" PRIMARY KEY ("key");



ALTER TABLE ONLY "public"."sfot_profiles"
    ADD CONSTRAINT "sfot_profiles_pkey" PRIMARY KEY ("profile_name");



ALTER TABLE ONLY "public"."streamers"
    ADD CONSTRAINT "streamers_login_key" UNIQUE ("login");



ALTER TABLE ONLY "public"."streamers"
    ADD CONSTRAINT "streamers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."vods"
    ADD CONSTRAINT "vods_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."vods"
    ADD CONSTRAINT "vods_source_source_id_key" UNIQUE ("source", "source_id");



ALTER TABLE ONLY "test"."cataloger_runs"
    ADD CONSTRAINT "cataloger_runs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "test"."chunks"
    ADD CONSTRAINT "chunks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "test"."chunks"
    ADD CONSTRAINT "chunks_vod_id_chunk_index_key" UNIQUE ("vod_id", "chunk_index");



ALTER TABLE ONLY "test"."chunks"
    ADD CONSTRAINT "chunks_vod_id_int4range_excl" EXCLUDE USING "gist" ("vod_id" WITH =, "int4range"("start_seconds", "end_seconds") WITH &&);



ALTER TABLE ONLY "test"."detections"
    ADD CONSTRAINT "detections_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "test"."processing_config"
    ADD CONSTRAINT "processing_config_pkey" PRIMARY KEY ("key");



ALTER TABLE ONLY "test"."sfot_profiles"
    ADD CONSTRAINT "sfot_profiles_pkey" PRIMARY KEY ("profile_name");



ALTER TABLE ONLY "test"."streamers"
    ADD CONSTRAINT "streamers_login_key" UNIQUE ("login");



ALTER TABLE ONLY "test"."streamers"
    ADD CONSTRAINT "streamers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "test"."vods"
    ADD CONSTRAINT "vods_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "test"."vods"
    ADD CONSTRAINT "vods_source_source_id_key" UNIQUE ("source", "source_id");



CREATE INDEX "idx_chunks_ready" ON "public"."chunks" USING "btree" ("scheduled_for", "priority" DESC) WHERE ("status" = 'pending'::"public"."processing_status");



CREATE INDEX "idx_chunks_status" ON "public"."chunks" USING "btree" ("status");



CREATE INDEX "idx_chunks_vod" ON "public"."chunks" USING "btree" ("vod_id");



CREATE INDEX "idx_chunks_vod_status" ON "public"."chunks" USING "btree" ("vod_id", "status");



CREATE INDEX "idx_detections_chunk_id" ON "public"."detections" USING "btree" ("chunk_id");



CREATE INDEX "idx_detections_no_right_edge" ON "public"."detections" USING "btree" ("no_right_edge") WHERE ("no_right_edge" = true);



CREATE INDEX "idx_detections_username" ON "public"."detections" USING "btree" ("lower"("username"));



CREATE INDEX "idx_detections_vod" ON "public"."detections" USING "btree" ("vod_id");



CREATE INDEX "idx_vods_availability" ON "public"."vods" USING "btree" ("availability");



CREATE INDEX "idx_vods_status" ON "public"."vods" USING "btree" ("status");



CREATE INDEX "idx_vods_status_published_at" ON "public"."vods" USING "btree" ("status", "published_at") WHERE ("status" = 'pending'::"public"."vod_status");



CREATE INDEX "idx_vods_streamer" ON "public"."vods" USING "btree" ("streamer_id");



CREATE INDEX "chunks_scheduled_for_priority_idx" ON "test"."chunks" USING "btree" ("scheduled_for", "priority" DESC) WHERE ("status" = 'pending'::"public"."processing_status");



CREATE INDEX "chunks_status_idx" ON "test"."chunks" USING "btree" ("status");



CREATE INDEX "chunks_vod_id_idx" ON "test"."chunks" USING "btree" ("vod_id");



CREATE INDEX "detections_chunk_id_idx" ON "test"."detections" USING "btree" ("chunk_id");



CREATE INDEX "detections_lower_idx" ON "test"."detections" USING "btree" ("lower"("username"));



CREATE INDEX "detections_vod_id_idx" ON "test"."detections" USING "btree" ("vod_id");



CREATE INDEX "idx_test_detections_no_right_edge" ON "test"."detections" USING "btree" ("no_right_edge") WHERE ("no_right_edge" = true);



CREATE INDEX "vods_availability_idx" ON "test"."vods" USING "btree" ("availability");



CREATE INDEX "vods_streamer_id_idx" ON "test"."vods" USING "btree" ("streamer_id");



CREATE OR REPLACE TRIGGER "trigger_auto_chunks" AFTER INSERT OR UPDATE OF "ready_for_processing" ON "public"."vods" FOR EACH ROW EXECUTE FUNCTION "public"."auto_create_chunks"();



CREATE OR REPLACE TRIGGER "trigger_auto_create_chunks" AFTER INSERT OR UPDATE OF "ready_for_processing" ON "public"."vods" FOR EACH ROW EXECUTE FUNCTION "public"."auto_create_chunks"();



CREATE OR REPLACE TRIGGER "trigger_chunk_status_update_vod" AFTER INSERT OR DELETE OR UPDATE OF "status" ON "public"."chunks" FOR EACH ROW EXECUTE FUNCTION "public"."update_vod_status"();



CREATE OR REPLACE TRIGGER "trigger_streamer_enabled" AFTER UPDATE OF "processing_enabled" ON "public"."streamers" FOR EACH ROW EXECUTE FUNCTION "public"."create_chunks_for_enabled_streamer"();



CREATE OR REPLACE TRIGGER "trigger_streamer_processing_disabled" AFTER UPDATE OF "processing_enabled" ON "public"."streamers" FOR EACH ROW EXECUTE FUNCTION "public"."cleanup_streamer_chunks_on_disable"();



CREATE OR REPLACE TRIGGER "trigger_vod_processing_disabled" AFTER UPDATE OF "ready_for_processing" ON "public"."vods" FOR EACH ROW EXECUTE FUNCTION "public"."cleanup_vod_chunks_on_disable"();



CREATE OR REPLACE TRIGGER "trigger_vod_status_change" AFTER UPDATE OF "status" ON "public"."vods" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_vod_status_change"();



CREATE OR REPLACE TRIGGER "trigger_chunk_status_update_vod" AFTER INSERT OR DELETE OR UPDATE OF "status" ON "test"."chunks" FOR EACH ROW EXECUTE FUNCTION "public"."update_vod_status"();



CREATE OR REPLACE TRIGGER "trigger_vod_status_change" AFTER UPDATE OF "status" ON "test"."vods" FOR EACH ROW EXECUTE FUNCTION "public"."trigger_vod_status_change"();



ALTER TABLE ONLY "public"."chunks"
    ADD CONSTRAINT "chunks_vod_id_fkey" FOREIGN KEY ("vod_id") REFERENCES "public"."vods"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."detections"
    ADD CONSTRAINT "detections_chunk_id_fkey" FOREIGN KEY ("chunk_id") REFERENCES "public"."chunks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."detections"
    ADD CONSTRAINT "detections_vod_id_fkey" FOREIGN KEY ("vod_id") REFERENCES "public"."vods"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."vods"
    ADD CONSTRAINT "vods_streamer_id_fkey" FOREIGN KEY ("streamer_id") REFERENCES "public"."streamers"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "test"."chunks"
    ADD CONSTRAINT "test_chunks_vod_id_fkey" FOREIGN KEY ("vod_id") REFERENCES "test"."vods"("id");



ALTER TABLE ONLY "test"."detections"
    ADD CONSTRAINT "test_detections_chunk_id_fkey" FOREIGN KEY ("chunk_id") REFERENCES "test"."chunks"("id");



ALTER TABLE ONLY "test"."detections"
    ADD CONSTRAINT "test_detections_vod_id_fkey" FOREIGN KEY ("vod_id") REFERENCES "test"."vods"("id");



ALTER TABLE ONLY "test"."vods"
    ADD CONSTRAINT "test_vods_streamer_id_fkey" FOREIGN KEY ("streamer_id") REFERENCES "test"."streamers"("id");



CREATE POLICY "Public can view available VODs" ON "public"."vods" FOR SELECT USING (("availability" = 'available'::"public"."vod_availability"));



CREATE POLICY "Public can view detections from available VODs" ON "public"."detections" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."vods"
  WHERE (("vods"."id" = "detections"."vod_id") AND ("vods"."availability" = 'available'::"public"."vod_availability")))));



ALTER TABLE "public"."cataloger_runs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "cataloger_runs_all_access" ON "public"."cataloger_runs" USING (true) WITH CHECK (true);



ALTER TABLE "public"."chunks" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "chunks_all_access" ON "public"."chunks" USING (true) WITH CHECK (true);



ALTER TABLE "public"."detections" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sfot_profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sfot_profiles_all_access" ON "public"."sfot_profiles" USING (true) WITH CHECK (true);



ALTER TABLE "public"."streamers" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "streamers_all_access" ON "public"."streamers" USING (true) WITH CHECK (true);



ALTER TABLE "public"."vods" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;






GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT USAGE ON SCHEMA "test" TO "anon";
GRANT USAGE ON SCHEMA "test" TO "authenticated";
GRANT USAGE ON SCHEMA "test" TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey16_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey16_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey16_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey16_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey16_out"("public"."gbtreekey16") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey16_out"("public"."gbtreekey16") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey16_out"("public"."gbtreekey16") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey16_out"("public"."gbtreekey16") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey2_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey2_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey2_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey2_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey2_out"("public"."gbtreekey2") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey2_out"("public"."gbtreekey2") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey2_out"("public"."gbtreekey2") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey2_out"("public"."gbtreekey2") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey32_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey32_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey32_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey32_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey32_out"("public"."gbtreekey32") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey32_out"("public"."gbtreekey32") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey32_out"("public"."gbtreekey32") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey32_out"("public"."gbtreekey32") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey4_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey4_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey4_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey4_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey4_out"("public"."gbtreekey4") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey4_out"("public"."gbtreekey4") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey4_out"("public"."gbtreekey4") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey4_out"("public"."gbtreekey4") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey8_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey8_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey8_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey8_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey8_out"("public"."gbtreekey8") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey8_out"("public"."gbtreekey8") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey8_out"("public"."gbtreekey8") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey8_out"("public"."gbtreekey8") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey_var_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey_var_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey_var_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey_var_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbtreekey_var_out"("public"."gbtreekey_var") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbtreekey_var_out"("public"."gbtreekey_var") TO "anon";
GRANT ALL ON FUNCTION "public"."gbtreekey_var_out"("public"."gbtreekey_var") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbtreekey_var_out"("public"."gbtreekey_var") TO "service_role";




















































































































































































GRANT ALL ON FUNCTION "public"."auto_create_chunks"() TO "anon";
GRANT ALL ON FUNCTION "public"."auto_create_chunks"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."auto_create_chunks"() TO "service_role";



GRANT ALL ON FUNCTION "public"."auto_queue_next_vod"() TO "anon";
GRANT ALL ON FUNCTION "public"."auto_queue_next_vod"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."auto_queue_next_vod"() TO "service_role";



GRANT ALL ON FUNCTION "public"."cash_dist"("money", "money") TO "postgres";
GRANT ALL ON FUNCTION "public"."cash_dist"("money", "money") TO "anon";
GRANT ALL ON FUNCTION "public"."cash_dist"("money", "money") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cash_dist"("money", "money") TO "service_role";



GRANT ALL ON FUNCTION "public"."cleanup_streamer_chunks_on_disable"() TO "anon";
GRANT ALL ON FUNCTION "public"."cleanup_streamer_chunks_on_disable"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."cleanup_streamer_chunks_on_disable"() TO "service_role";



GRANT ALL ON FUNCTION "public"."cleanup_vod_chunks_on_disable"() TO "anon";
GRANT ALL ON FUNCTION "public"."cleanup_vod_chunks_on_disable"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."cleanup_vod_chunks_on_disable"() TO "service_role";



GRANT ALL ON FUNCTION "public"."create_bazaar_aware_chunks"("p_vod_id" bigint, "p_min_chunk_duration" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."create_bazaar_aware_chunks"("p_vod_id" bigint, "p_min_chunk_duration" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_bazaar_aware_chunks"("p_vod_id" bigint, "p_min_chunk_duration" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."create_chunks_for_enabled_streamer"() TO "anon";
GRANT ALL ON FUNCTION "public"."create_chunks_for_enabled_streamer"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_chunks_for_enabled_streamer"() TO "service_role";



GRANT ALL ON FUNCTION "public"."create_chunks_for_segment"("p_vod_id" bigint, "p_start_seconds" integer, "p_end_seconds" integer, "p_chunk_duration_seconds" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."create_chunks_for_segment"("p_vod_id" bigint, "p_start_seconds" integer, "p_end_seconds" integer, "p_chunk_duration_seconds" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_chunks_for_segment"("p_vod_id" bigint, "p_start_seconds" integer, "p_end_seconds" integer, "p_chunk_duration_seconds" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."cron_insert_new_streamers"() TO "anon";
GRANT ALL ON FUNCTION "public"."cron_insert_new_streamers"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."cron_insert_new_streamers"() TO "service_role";



GRANT ALL ON FUNCTION "public"."cron_process_pending_vods"() TO "anon";
GRANT ALL ON FUNCTION "public"."cron_process_pending_vods"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."cron_process_pending_vods"() TO "service_role";



GRANT ALL ON FUNCTION "public"."cron_update_streamer_vods"() TO "anon";
GRANT ALL ON FUNCTION "public"."cron_update_streamer_vods"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."cron_update_streamer_vods"() TO "service_role";



GRANT ALL ON FUNCTION "public"."date_dist"("date", "date") TO "postgres";
GRANT ALL ON FUNCTION "public"."date_dist"("date", "date") TO "anon";
GRANT ALL ON FUNCTION "public"."date_dist"("date", "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."date_dist"("date", "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."float4_dist"(real, real) TO "postgres";
GRANT ALL ON FUNCTION "public"."float4_dist"(real, real) TO "anon";
GRANT ALL ON FUNCTION "public"."float4_dist"(real, real) TO "authenticated";
GRANT ALL ON FUNCTION "public"."float4_dist"(real, real) TO "service_role";



GRANT ALL ON FUNCTION "public"."float8_dist"(double precision, double precision) TO "postgres";
GRANT ALL ON FUNCTION "public"."float8_dist"(double precision, double precision) TO "anon";
GRANT ALL ON FUNCTION "public"."float8_dist"(double precision, double precision) TO "authenticated";
GRANT ALL ON FUNCTION "public"."float8_dist"(double precision, double precision) TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bit_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bit_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bit_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bit_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bit_consistent"("internal", bit, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bit_consistent"("internal", bit, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bit_consistent"("internal", bit, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bit_consistent"("internal", bit, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bit_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bit_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bit_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bit_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bit_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bit_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bit_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bit_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bit_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bit_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bit_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bit_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bit_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bit_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bit_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bit_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_consistent"("internal", boolean, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_consistent"("internal", boolean, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_consistent"("internal", boolean, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_consistent"("internal", boolean, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_same"("public"."gbtreekey2", "public"."gbtreekey2", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_same"("public"."gbtreekey2", "public"."gbtreekey2", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_same"("public"."gbtreekey2", "public"."gbtreekey2", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_same"("public"."gbtreekey2", "public"."gbtreekey2", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bool_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bool_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bool_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bool_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bpchar_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bpchar_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bpchar_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bpchar_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bpchar_consistent"("internal", character, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bpchar_consistent"("internal", character, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bpchar_consistent"("internal", character, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bpchar_consistent"("internal", character, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bytea_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bytea_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bytea_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bytea_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bytea_consistent"("internal", "bytea", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bytea_consistent"("internal", "bytea", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bytea_consistent"("internal", "bytea", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bytea_consistent"("internal", "bytea", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bytea_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bytea_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bytea_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bytea_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bytea_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bytea_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bytea_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bytea_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bytea_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bytea_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bytea_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bytea_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_bytea_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_bytea_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_bytea_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_bytea_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_consistent"("internal", "money", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_consistent"("internal", "money", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_consistent"("internal", "money", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_consistent"("internal", "money", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_distance"("internal", "money", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_distance"("internal", "money", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_distance"("internal", "money", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_distance"("internal", "money", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_cash_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_cash_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_cash_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_cash_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_consistent"("internal", "date", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_consistent"("internal", "date", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_consistent"("internal", "date", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_consistent"("internal", "date", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_distance"("internal", "date", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_distance"("internal", "date", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_distance"("internal", "date", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_distance"("internal", "date", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_date_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_date_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_date_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_date_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_decompress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_decompress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_decompress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_decompress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_consistent"("internal", "anyenum", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_consistent"("internal", "anyenum", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_consistent"("internal", "anyenum", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_consistent"("internal", "anyenum", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_enum_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_enum_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_enum_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_enum_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_consistent"("internal", real, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_consistent"("internal", real, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_consistent"("internal", real, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_consistent"("internal", real, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_distance"("internal", real, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_distance"("internal", real, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_distance"("internal", real, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_distance"("internal", real, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float4_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float4_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float4_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float4_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_consistent"("internal", double precision, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_consistent"("internal", double precision, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_consistent"("internal", double precision, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_consistent"("internal", double precision, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_distance"("internal", double precision, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_distance"("internal", double precision, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_distance"("internal", double precision, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_distance"("internal", double precision, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_float8_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_float8_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_float8_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_float8_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_inet_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_inet_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_inet_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_inet_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_inet_consistent"("internal", "inet", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_inet_consistent"("internal", "inet", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_inet_consistent"("internal", "inet", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_inet_consistent"("internal", "inet", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_inet_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_inet_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_inet_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_inet_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_inet_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_inet_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_inet_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_inet_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_inet_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_inet_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_inet_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_inet_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_inet_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_inet_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_inet_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_inet_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_consistent"("internal", smallint, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_consistent"("internal", smallint, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_consistent"("internal", smallint, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_consistent"("internal", smallint, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_distance"("internal", smallint, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_distance"("internal", smallint, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_distance"("internal", smallint, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_distance"("internal", smallint, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_same"("public"."gbtreekey4", "public"."gbtreekey4", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_same"("public"."gbtreekey4", "public"."gbtreekey4", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_same"("public"."gbtreekey4", "public"."gbtreekey4", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_same"("public"."gbtreekey4", "public"."gbtreekey4", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int2_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int2_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int2_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int2_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_consistent"("internal", integer, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_consistent"("internal", integer, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_consistent"("internal", integer, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_consistent"("internal", integer, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_distance"("internal", integer, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_distance"("internal", integer, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_distance"("internal", integer, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_distance"("internal", integer, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int4_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int4_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int4_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int4_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_consistent"("internal", bigint, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_consistent"("internal", bigint, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_consistent"("internal", bigint, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_consistent"("internal", bigint, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_distance"("internal", bigint, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_distance"("internal", bigint, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_distance"("internal", bigint, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_distance"("internal", bigint, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_int8_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_int8_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_int8_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_int8_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_consistent"("internal", interval, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_consistent"("internal", interval, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_consistent"("internal", interval, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_consistent"("internal", interval, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_decompress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_decompress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_decompress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_decompress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_distance"("internal", interval, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_distance"("internal", interval, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_distance"("internal", interval, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_distance"("internal", interval, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_intv_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_intv_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_intv_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_intv_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_consistent"("internal", "macaddr8", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_consistent"("internal", "macaddr8", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_consistent"("internal", "macaddr8", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_consistent"("internal", "macaddr8", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad8_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad8_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad8_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad8_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_consistent"("internal", "macaddr", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_consistent"("internal", "macaddr", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_consistent"("internal", "macaddr", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_consistent"("internal", "macaddr", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_macad_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_macad_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_macad_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_macad_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_numeric_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_numeric_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_numeric_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_numeric_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_numeric_consistent"("internal", numeric, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_numeric_consistent"("internal", numeric, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_numeric_consistent"("internal", numeric, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_numeric_consistent"("internal", numeric, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_numeric_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_numeric_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_numeric_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_numeric_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_numeric_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_numeric_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_numeric_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_numeric_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_numeric_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_numeric_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_numeric_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_numeric_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_numeric_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_numeric_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_numeric_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_numeric_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_consistent"("internal", "oid", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_consistent"("internal", "oid", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_consistent"("internal", "oid", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_consistent"("internal", "oid", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_distance"("internal", "oid", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_distance"("internal", "oid", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_distance"("internal", "oid", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_distance"("internal", "oid", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_same"("public"."gbtreekey8", "public"."gbtreekey8", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_oid_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_oid_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_oid_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_oid_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_text_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_text_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_text_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_text_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_text_consistent"("internal", "text", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_text_consistent"("internal", "text", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_text_consistent"("internal", "text", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_text_consistent"("internal", "text", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_text_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_text_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_text_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_text_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_text_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_text_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_text_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_text_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_text_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_text_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_text_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_text_same"("public"."gbtreekey_var", "public"."gbtreekey_var", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_text_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_text_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_text_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_text_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_consistent"("internal", time without time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_consistent"("internal", time without time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_consistent"("internal", time without time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_consistent"("internal", time without time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_distance"("internal", time without time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_distance"("internal", time without time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_distance"("internal", time without time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_distance"("internal", time without time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_time_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_time_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_time_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_time_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_timetz_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_timetz_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_timetz_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_timetz_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_timetz_consistent"("internal", time with time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_timetz_consistent"("internal", time with time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_timetz_consistent"("internal", time with time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_timetz_consistent"("internal", time with time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_consistent"("internal", timestamp without time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_consistent"("internal", timestamp without time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_consistent"("internal", timestamp without time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_consistent"("internal", timestamp without time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_distance"("internal", timestamp without time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_distance"("internal", timestamp without time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_distance"("internal", timestamp without time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_distance"("internal", timestamp without time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_same"("public"."gbtreekey16", "public"."gbtreekey16", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_ts_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_ts_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_ts_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_ts_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_tstz_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_tstz_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_tstz_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_tstz_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_tstz_consistent"("internal", timestamp with time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_tstz_consistent"("internal", timestamp with time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_tstz_consistent"("internal", timestamp with time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_tstz_consistent"("internal", timestamp with time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_tstz_distance"("internal", timestamp with time zone, smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_tstz_distance"("internal", timestamp with time zone, smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_tstz_distance"("internal", timestamp with time zone, smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_tstz_distance"("internal", timestamp with time zone, smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_consistent"("internal", "uuid", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_consistent"("internal", "uuid", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_consistent"("internal", "uuid", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_consistent"("internal", "uuid", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_same"("public"."gbtreekey32", "public"."gbtreekey32", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_uuid_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_uuid_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_uuid_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_uuid_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_var_decompress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_var_decompress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_var_decompress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_var_decompress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gbt_var_fetch"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gbt_var_fetch"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gbt_var_fetch"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gbt_var_fetch"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_pending_chunks_for_vod"("p_vod_id" bigint, "p_source_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_pending_chunks_for_vod"("p_vod_id" bigint, "p_source_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_pending_chunks_for_vod"("p_vod_id" bigint, "p_source_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_pending_vods_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_pending_vods_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_pending_vods_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."int2_dist"(smallint, smallint) TO "postgres";
GRANT ALL ON FUNCTION "public"."int2_dist"(smallint, smallint) TO "anon";
GRANT ALL ON FUNCTION "public"."int2_dist"(smallint, smallint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."int2_dist"(smallint, smallint) TO "service_role";



GRANT ALL ON FUNCTION "public"."int4_dist"(integer, integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."int4_dist"(integer, integer) TO "anon";
GRANT ALL ON FUNCTION "public"."int4_dist"(integer, integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."int4_dist"(integer, integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."int8_dist"(bigint, bigint) TO "postgres";
GRANT ALL ON FUNCTION "public"."int8_dist"(bigint, bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."int8_dist"(bigint, bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."int8_dist"(bigint, bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."interval_dist"(interval, interval) TO "postgres";
GRANT ALL ON FUNCTION "public"."interval_dist"(interval, interval) TO "anon";
GRANT ALL ON FUNCTION "public"."interval_dist"(interval, interval) TO "authenticated";
GRANT ALL ON FUNCTION "public"."interval_dist"(interval, interval) TO "service_role";



GRANT ALL ON FUNCTION "public"."manual_process_pending_vods"("max_vods" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."manual_process_pending_vods"("max_vods" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."manual_process_pending_vods"("max_vods" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."oid_dist"("oid", "oid") TO "postgres";
GRANT ALL ON FUNCTION "public"."oid_dist"("oid", "oid") TO "anon";
GRANT ALL ON FUNCTION "public"."oid_dist"("oid", "oid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."oid_dist"("oid", "oid") TO "service_role";



GRANT ALL ON FUNCTION "public"."process_pending_vods"("max_vods" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."process_pending_vods"("max_vods" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_pending_vods"("max_vods" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."time_dist"(time without time zone, time without time zone) TO "postgres";
GRANT ALL ON FUNCTION "public"."time_dist"(time without time zone, time without time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."time_dist"(time without time zone, time without time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."time_dist"(time without time zone, time without time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."trigger_vod_status_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."trigger_vod_status_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trigger_vod_status_change"() TO "service_role";



GRANT ALL ON FUNCTION "public"."ts_dist"(timestamp without time zone, timestamp without time zone) TO "postgres";
GRANT ALL ON FUNCTION "public"."ts_dist"(timestamp without time zone, timestamp without time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."ts_dist"(timestamp without time zone, timestamp without time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."ts_dist"(timestamp without time zone, timestamp without time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."tstz_dist"(timestamp with time zone, timestamp with time zone) TO "postgres";
GRANT ALL ON FUNCTION "public"."tstz_dist"(timestamp with time zone, timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."tstz_dist"(timestamp with time zone, timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."tstz_dist"(timestamp with time zone, timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."update_chunk_status"("p_chunk_id" "uuid", "p_status" "text", "p_error_message" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."update_chunk_status"("p_chunk_id" "uuid", "p_status" "text", "p_error_message" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_chunk_status"("p_chunk_id" "uuid", "p_status" "text", "p_error_message" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_vod_status"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_vod_status"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_vod_status"() TO "service_role";












SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;



SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;









GRANT ALL ON TABLE "public"."cataloger_runs" TO "anon";
GRANT ALL ON TABLE "public"."cataloger_runs" TO "authenticated";
GRANT ALL ON TABLE "public"."cataloger_runs" TO "service_role";



GRANT ALL ON TABLE "public"."chunks" TO "anon";
GRANT ALL ON TABLE "public"."chunks" TO "authenticated";
GRANT ALL ON TABLE "public"."chunks" TO "service_role";



GRANT ALL ON TABLE "public"."cron_job_status" TO "anon";
GRANT ALL ON TABLE "public"."cron_job_status" TO "authenticated";
GRANT ALL ON TABLE "public"."cron_job_status" TO "service_role";



GRANT ALL ON TABLE "public"."detections" TO "anon";
GRANT ALL ON TABLE "public"."detections" TO "authenticated";
GRANT ALL ON TABLE "public"."detections" TO "service_role";



GRANT ALL ON TABLE "public"."processing_config" TO "anon";
GRANT ALL ON TABLE "public"."processing_config" TO "authenticated";
GRANT ALL ON TABLE "public"."processing_config" TO "service_role";



GRANT ALL ON TABLE "public"."sfot_profiles" TO "anon";
GRANT ALL ON TABLE "public"."sfot_profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."sfot_profiles" TO "service_role";



GRANT ALL ON TABLE "public"."streamers" TO "anon";
GRANT ALL ON TABLE "public"."streamers" TO "authenticated";
GRANT ALL ON TABLE "public"."streamers" TO "service_role";



GRANT ALL ON TABLE "public"."vods" TO "anon";
GRANT ALL ON TABLE "public"."vods" TO "authenticated";
GRANT ALL ON TABLE "public"."vods" TO "service_role";



GRANT ALL ON SEQUENCE "public"."vods_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."vods_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."vods_id_seq" TO "service_role";



GRANT ALL ON TABLE "test"."cataloger_runs" TO "service_role";
GRANT ALL ON TABLE "test"."cataloger_runs" TO "anon";
GRANT ALL ON TABLE "test"."cataloger_runs" TO "authenticated";



GRANT ALL ON TABLE "test"."chunks" TO "service_role";
GRANT ALL ON TABLE "test"."chunks" TO "anon";
GRANT ALL ON TABLE "test"."chunks" TO "authenticated";



GRANT ALL ON TABLE "test"."detections" TO "service_role";
GRANT ALL ON TABLE "test"."detections" TO "anon";
GRANT ALL ON TABLE "test"."detections" TO "authenticated";



GRANT ALL ON TABLE "test"."processing_config" TO "anon";
GRANT ALL ON TABLE "test"."processing_config" TO "authenticated";
GRANT ALL ON TABLE "test"."processing_config" TO "service_role";



GRANT ALL ON TABLE "test"."sfot_profiles" TO "service_role";
GRANT ALL ON TABLE "test"."sfot_profiles" TO "anon";
GRANT ALL ON TABLE "test"."sfot_profiles" TO "authenticated";



GRANT ALL ON TABLE "test"."streamers" TO "service_role";
GRANT ALL ON TABLE "test"."streamers" TO "anon";
GRANT ALL ON TABLE "test"."streamers" TO "authenticated";



GRANT ALL ON TABLE "test"."vods" TO "service_role";
GRANT ALL ON TABLE "test"."vods" TO "anon";
GRANT ALL ON TABLE "test"."vods" TO "authenticated";



GRANT ALL ON SEQUENCE "test"."vods_id_seq" TO "service_role";
GRANT ALL ON SEQUENCE "test"."vods_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "test"."vods_id_seq" TO "authenticated";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "test" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "test" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "test" GRANT ALL ON SEQUENCES TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "test" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "test" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "test" GRANT ALL ON FUNCTIONS TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "test" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "test" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "test" GRANT ALL ON TABLES TO "service_role";



























RESET ALL;

--
-- Dumped schema changes for auth and storage
--

