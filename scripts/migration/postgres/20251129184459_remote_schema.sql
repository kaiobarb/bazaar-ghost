


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', 'public', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "btree_gist" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pg_trgm" WITH SCHEMA "public";






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
    "truncated" boolean DEFAULT false,
    CONSTRAINT "detections_rank_check" CHECK (("rank" = ANY (ARRAY['bronze'::"text", 'silver'::"text", 'gold'::"text", 'diamond'::"text", 'legend'::"text"])))
);


ALTER TABLE "public"."detections" OWNER TO "postgres";


COMMENT ON COLUMN "public"."detections"."no_right_edge" IS 'Indicates if right edge detection failed, suggesting possible streamer cam occlusion';



COMMENT ON COLUMN "public"."detections"."truncated" IS 'Whether the username was truncated using custom edge from sfot_profiles (due to camera/UI occlusion)';



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
    "has_vods" boolean DEFAULT false,
    "sfot_profile_id" bigint DEFAULT 1
);


ALTER TABLE "public"."streamers" OWNER TO "postgres";


COMMENT ON COLUMN "public"."streamers"."oldest_vod" IS 'Timestamp of the oldest VOD from this streamer (any game, not just Bazaar)';



COMMENT ON COLUMN "public"."streamers"."num_vods" IS 'Total count of all VODs from this streamer';



COMMENT ON COLUMN "public"."streamers"."num_bazaar_vods" IS 'Count of VODs with Bazaar gameplay';



COMMENT ON COLUMN "public"."streamers"."has_vods" IS 'True if streamer has more than 1 VOD stored (indicating they keep their VODs)';



COMMENT ON COLUMN "public"."streamers"."sfot_profile_id" IS 'SFOT processing profile to use for
  this streamer (defaults to profile ID 1 - default)';



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
    "id" bigint NOT NULL,
    "profile_name" "text" NOT NULL,
    "crop_region" numeric[] NOT NULL,
    "scale" numeric DEFAULT 1.0,
    "custom_edge" numeric,
    "opaque_edge" boolean DEFAULT true,
    "from_date" timestamp with time zone,
    "to_date" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "crop_region_length" CHECK (("array_length"("crop_region", 1) = 4))
);


ALTER TABLE "public"."sfot_profiles" OWNER TO "postgres";


COMMENT ON TABLE "public"."sfot_profiles" IS 'SFOT processing profiles';



COMMENT ON COLUMN "public"."sfot_profiles"."profile_name" IS 'Unique name for the profile';



COMMENT ON COLUMN "public"."sfot_profiles"."crop_region" IS 'Array of 4 decimals [x, y, width,
  height] as percentages';



ALTER TABLE "public"."sfot_profiles" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."sfot_profiles_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


CREATE OR REPLACE FUNCTION "public"."auto_create_chunks"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$DECLARE
  should_run boolean := false;
BEGIN
  -- Decide when to (re)chunk
  IF TG_OP = 'INSERT' THEN
    should_run := true;
  ELSE
    IF (
         (NEW.ready_for_processing IS TRUE
           AND NEW.ready_for_processing IS DISTINCT FROM OLD.ready_for_processing)
         OR (NEW.duration_seconds IS DISTINCT FROM OLD.duration_seconds)
         OR (NEW.bazaar_chapters IS DISTINCT FROM OLD.bazaar_chapters)
       )
    THEN
      should_run := true;
    END IF;
  END IF;

  IF should_run THEN
    -- Only process if streamer allows it
    IF EXISTS (
      SELECT 1 FROM streamers s
      WHERE s.id = NEW.streamer_id
        AND s.processing_enabled = TRUE
    ) THEN
      -- Minimum length (10 min)
      IF NEW.duration_seconds >= 600 THEN
        PERFORM create_missing_chunks_for_vod(NEW.id);
      ELSE
        RAISE NOTICE 'VOD % too short for chunking (% s)', NEW.id, NEW.duration_seconds;
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;$$;


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
    AS $$BEGIN
  IF NEW.processing_enabled = TRUE AND OLD.processing_enabled = FALSE THEN
    -- Create chunks for all ready VODs for this streamer
    PERFORM create_missing_chunks_for_vod(v.id)
    FROM vods v
    WHERE v.streamer_id = NEW.id 
    AND v.ready_for_processing = TRUE;
  END IF;
  RETURN NEW;
END;$$;


ALTER FUNCTION "public"."create_chunks_for_enabled_streamer"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_missing_chunks_for_vod"("p_vod_id" bigint, "p_target_chunk_seconds" integer DEFAULT 3600, "p_min_gap_seconds" integer DEFAULT 300) RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_vod_duration     integer;
  v_bazaar_chapters  integer[];
  v_created          integer := 0;
  v_chunk_idx_start  integer;
  v_seg_start        integer;
  v_seg_end          integer;
  v_seg_dur          integer;
  v_gap_mr           int4multirange;
  v_existing_mr      int4multirange;
  v_seg_mr           int4multirange;
  r_gap              int4range;
  g_start            integer;
  g_end              integer;
  g_dur              integer;
  num_chunks         integer;
  chunk_dur          integer;
  i                  integer;
  cur_start          integer;
  cur_end            integer;
begin
  -- Load VOD
  select duration_seconds, bazaar_chapters
  into v_vod_duration, v_bazaar_chapters
  from vods
  where id = p_vod_id;

  if v_vod_duration is null then
    raise notice 'VOD % not found', p_vod_id;
    return 0;
  end if;

  -- Nothing to do if VOD shorter than 5 minutes total
  if v_vod_duration < p_min_gap_seconds then
    raise notice 'VOD % is too short (%s s), skipping', p_vod_id, v_vod_duration;
    return 0;
  end if;

  -- If no Bazaar chapters, treat whole VOD as one segment
  if v_bazaar_chapters is null
     or array_length(v_bazaar_chapters, 1) is null
     or array_length(v_bazaar_chapters, 1) = 0 then
    v_bazaar_chapters := array[0, v_vod_duration];
  end if;

  -- Determine starting chunk_index (append-only)
  select coalesce(max(chunk_index), -1) + 1
  into v_chunk_idx_start
  from chunks
  where vod_id = p_vod_id;

  -- Iterate pairs [start, end] from chapters/segments
  for i in 1..array_length(v_bazaar_chapters,1) by 2 loop
    v_seg_start := v_bazaar_chapters[i];
    v_seg_end   := v_bazaar_chapters[i+1];

    if v_seg_end is null then
      continue;
    end if;

    -- Clamp to VOD duration for safety
    v_seg_start := greatest(0, least(v_seg_start, v_vod_duration));
    v_seg_end   := greatest(0, least(v_seg_end,   v_vod_duration));
    if v_seg_end <= v_seg_start then
      continue;
    end if;

    v_seg_dur := v_seg_end - v_seg_start;
    -- Skip segment if < 5 minutes
    if v_seg_dur < p_min_gap_seconds then
      continue;
    end if;

    -- Build multirange for this segment
    v_seg_mr := int4multirange(int4range(v_seg_start, v_seg_end));

    -- Existing chunks overlapping this segment (as multirange)
    select coalesce(range_agg(int4range(c.start_seconds, c.end_seconds))::int4multirange, '{}')
    into v_existing_mr
    from chunks c
    where c.vod_id = p_vod_id
      and int4range(c.start_seconds, c.end_seconds) && int4range(v_seg_start, v_seg_end);

    -- Uncovered gaps = segment minus existing
    v_gap_mr := v_seg_mr - coalesce(v_existing_mr, '{}');

    -- For each uncovered gap in this segment, create chunks per rules
    for r_gap in
      select unnest(v_gap_mr)
    loop
      g_start := lower(r_gap);
      g_end   := upper(r_gap);
      g_dur   := g_end - g_start;

      -- Ignore tiny gaps (< 5 min)
      if g_dur < p_min_gap_seconds then
        continue;
      end if;

      -- ≤ 1 hour → single chunk
      if g_dur <= p_target_chunk_seconds then
        begin
          insert into chunks (vod_id, start_seconds, end_seconds, chunk_index)
          values (p_vod_id, g_start, g_end, v_chunk_idx_start + v_created);
          v_created := v_created + 1;
        exception when unique_violation or exclusion_violation then
          -- Another worker might have created it; skip
          continue;
        end;
        continue;
      end if;

      -- > 1 hour → the FEWEST chunks with each ≥ 1 hour
      -- Strategy: num_chunks = floor(g_dur / 1h), each chunk ≈ ceil(g_dur / num_chunks)
      num_chunks := floor(g_dur::numeric / p_target_chunk_seconds);
      if num_chunks < 1 then
        num_chunks := 1;
      end if;
      -- Distribute so each is ≥ ~1h (or one longer chunk when 1h < g_dur < 2h)
      chunk_dur := ceil(g_dur::numeric / num_chunks);

      cur_start := g_start;
      for i in 1..num_chunks loop
        if i = num_chunks then
          cur_end := g_end;  -- last chunk absorbs remainder
        else
          cur_end := least(cur_start + chunk_dur, g_end);
          -- Guard against pathological short last chunk; fold into fewer
          if (g_end - cur_end) > 0 and (g_end - cur_end) < p_target_chunk_seconds then
            -- Merge remainder now: make this the final chunk
            cur_end := g_end;
            -- Adjust num_chunks to break the loop after insert
            num_chunks := i;
          end if;
        end if;

        -- Insert, tolerating races
        begin
          insert into chunks (vod_id, start_seconds, end_seconds, chunk_index)
          values (p_vod_id, cur_start, cur_end, v_chunk_idx_start + v_created);
          v_created := v_created + 1;
        exception when unique_violation or exclusion_violation then
          -- Skip on overlap/dup (exclusion constraint or concurrent insert)
          null;
        end;

        exit when cur_end >= g_end;
        cur_start := cur_end;
      end loop;
    end loop; -- gaps
  end loop; -- segments

  return v_created;
end;
$$;


ALTER FUNCTION "public"."create_missing_chunks_for_vod"("p_vod_id" bigint, "p_target_chunk_seconds" integer, "p_min_gap_seconds" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cron_insert_new_streamers"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$DECLARE
  v_response_id bigint;
  v_status_code integer;
  v_secret_key text;
  v_supabase_url text;
  v_url text;
BEGIN
  -- Get the secret key from vault
  SELECT decrypted_secret INTO v_secret_key
  FROM vault.decrypted_secrets
  WHERE name = 'secret_key'
  LIMIT 1;

  IF v_secret_key IS NULL THEN
    RAISE EXCEPTION 'No secret key found in vault';
  END IF;

  -- Get Supabase URL from vault
  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'supabase_url'
  LIMIT 1;

  IF v_supabase_url IS NULL THEN
    RAISE EXCEPTION 'No supabase_url found in vault';
  END IF;

  -- Construct full URL for edge function
  v_url := v_supabase_url || '/functions/v1/insert-new-streamers';

  -- Call the edge function using pg_net with apikey header
  SELECT net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'apikey', v_secret_key,
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
END;$$;


ALTER FUNCTION "public"."cron_insert_new_streamers"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."cron_insert_new_streamers"() IS 'Calls insert-new-streamers edge function daily at 00:00 UTC via cron';



CREATE OR REPLACE FUNCTION "public"."cron_update_streamer_vods"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$DECLARE
  v_streamer RECORD;
  v_response_id bigint;
  v_status_code integer;
  v_secret_key text;
  v_supabase_url text;
  v_url text;
  v_updated_count integer := 0;
  v_interval_text text;
  v_interval interval;
BEGIN
  -- Load the interval config
  SELECT value INTO v_interval_text
  FROM processing_config
  WHERE key = 'update_vods_interval';

  IF v_interval_text IS NULL THEN
    RAISE NOTICE 'No update_vods_interval found, defaulting to 6 hours';
    v_interval := interval '6 hours';
  ELSE
    BEGIN
      v_interval := v_interval_text::interval;
    EXCEPTION WHEN others THEN
      RAISE WARNING 'Invalid interval value %, defaulting to 6 hours', v_interval_text;
      v_interval := interval '6 hours';
    END;
  END IF;

  -- Get secrets from vault
  SELECT decrypted_secret INTO v_secret_key
  FROM vault.decrypted_secrets
  WHERE name = 'secret_key'
  LIMIT 1;

  IF v_secret_key IS NULL THEN
    RAISE EXCEPTION 'No secret key found in vault';
  END IF;

  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'supabase_url'
  LIMIT 1;

  IF v_supabase_url IS NULL THEN
    RAISE EXCEPTION 'No supabase_url found in vault';
  END IF;

  v_url := v_supabase_url || '/functions/v1/update-vods';

  -- Find streamers to process
  FOR v_streamer IN
    SELECT id, login, updated_at
    FROM streamers
    WHERE processing_enabled = true
      AND (
        has_vods = true
        OR (created_at = updated_at)
        OR has_vods IS NULL
      )
      AND updated_at <= NOW() - v_interval
    ORDER BY updated_at ASC
    LIMIT 10
  LOOP
    BEGIN
      SELECT net.http_post(
        url := v_url,
        headers := jsonb_build_object(
          'apikey', v_secret_key,
          'Content-Type', 'application/json'
        ),
        body := jsonb_build_object('streamer_id', v_streamer.id),
        timeout_milliseconds := 60000
      ) INTO v_response_id;

      v_updated_count := v_updated_count + 1;
      RAISE NOTICE 'Called update-vods for streamer % (%)', v_streamer.login, v_streamer.id;
      PERFORM pg_sleep(1);

    EXCEPTION WHEN others THEN
      RAISE WARNING 'Failed to update VODs for streamer % (%): %',
        v_streamer.login, v_streamer.id, SQLERRM;
    END;
  END LOOP;

  RAISE NOTICE 'Updated VODs for % streamers (interval %)', v_updated_count, v_interval_text;
END;$$;


ALTER FUNCTION "public"."cron_update_streamer_vods"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."cron_update_streamer_vods"() IS 'Updates VODs for streamers that have not been updated in 24+ hours, runs hourly';



CREATE OR REPLACE FUNCTION "public"."force_process_vod"("p_vod_id" bigint DEFAULT NULL::bigint, "p_source_id" "text" DEFAULT NULL::"text", "p_target_chunk_seconds" integer DEFAULT 3600, "p_min_gap_seconds" integer DEFAULT 300) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$DECLARE
    v_vod_id bigint;
    v_availability vod_availability;
    v_deleted_chunks integer;
    v_deleted_detections integer;
    v_created_chunks integer;
BEGIN
    -- Validate: must provide one identifier
    IF p_vod_id IS NULL AND p_source_id IS NULL THEN
        RAISE EXCEPTION 'Must provide either p_vod_id or p_source_id';
    END IF;

    -- Resolve VOD ID from source_id if needed
    IF p_vod_id IS NULL THEN
        SELECT id INTO v_vod_id
        FROM vods
        WHERE source_id = p_source_id;

        IF v_vod_id IS NULL THEN
            RAISE EXCEPTION 'VOD not found with source_id: %', p_source_id;
        END IF;
    ELSE
        v_vod_id := p_vod_id;
    END IF;

    -- Check VOD availability (only process if available)
    SELECT availability INTO v_availability
    FROM vods
    WHERE id = v_vod_id;

    IF v_availability IS NULL THEN
        RAISE EXCEPTION 'VOD not found with id: %', v_vod_id;
    END IF;

    IF v_availability != 'available' THEN
        RAISE EXCEPTION 'VOD % is not available (status: %)', v_vod_id, v_availability;
    END IF;

    -- Count detections before deletion (for reporting)
    SELECT COUNT(*) INTO v_deleted_detections
    FROM detections
    WHERE vod_id = v_vod_id;

    -- Hard delete existing chunks (detections will cascade delete)
    DELETE FROM chunks
    WHERE vod_id = v_vod_id;

    GET DIAGNOSTICS v_deleted_chunks = ROW_COUNT;

    RAISE NOTICE 'Deleted % chunks and % detections for VOD %',
        v_deleted_chunks, v_deleted_detections, v_vod_id;

    -- Re-create chunks using existing intelligent chunker
    -- NOTE: Ignores ready_for_processing flag (force mode)
    v_created_chunks := create_missing_chunks_for_vod(
        v_vod_id,
        p_target_chunk_seconds,
        p_min_gap_seconds
    );

    RAISE NOTICE 'Created % new chunks for VOD %', v_created_chunks, v_vod_id;

    -- Return summary
    RETURN jsonb_build_object(
        'success', true,
        'vod_id', v_vod_id,
        'deleted_chunks', v_deleted_chunks,
        'deleted_detections', v_deleted_detections,
        'created_chunks', v_created_chunks,
        'message', format('Force-processed VOD %s: deleted %s chunks/%s detections, created %s new chunks',
            v_vod_id, v_deleted_chunks, v_deleted_detections, v_created_chunks)
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', SQLERRM,
        'vod_id', v_vod_id
    );
END;$$;


ALTER FUNCTION "public"."force_process_vod"("p_vod_id" bigint, "p_source_id" "text", "p_target_chunk_seconds" integer, "p_min_gap_seconds" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."force_process_vod"("p_vod_id" bigint, "p_source_id" "text", "p_target_chunk_seconds" integer, "p_min_gap_seconds" integer) IS 'Force reprocess a VOD by deleting all existing chunks and recreating them. Ignores ready_for_processing flag.';



CREATE OR REPLACE FUNCTION "public"."fuzzy_search_detections"("search_query" "text" DEFAULT NULL::"text", "streamer_id_filter" bigint DEFAULT NULL::bigint, "date_range_filter" "text" DEFAULT 'all'::"text", "similarity_threshold" double precision DEFAULT 0.2, "result_limit" integer DEFAULT 100) RETURNS TABLE("detection_id" "uuid", "username" "text", "streamer_id" bigint, "streamer_login" "text", "streamer_display_name" "text", "streamer_avatar" "text", "frame_time_seconds" integer, "confidence" double precision, "rank" "text", "vod_id" bigint, "vod_source_id" "text", "vod_url" "text", "actual_timestamp" timestamp with time zone, "similarity_score" real)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    -- Set the similarity threshold for this query
    EXECUTE format('SET LOCAL pg_trgm.similarity_threshold = %s', similarity_threshold);

    RETURN QUERY
    SELECT
        ds.detection_id,
        ds.username,
        ds.streamer_id,
        ds.streamer_login,
        ds.streamer_display_name,
        ds.streamer_avatar,
        ds.frame_time_seconds,
        ds.confidence,
        ds.rank,
        ds.vod_id,
        ds.vod_source_id,
        ds.vod_url,
        ds.actual_timestamp,
        CASE
            WHEN search_query IS NOT NULL AND search_query != ''
            THEN similarity(ds.username, search_query)
            ELSE 1.0
        END AS similarity_score
    FROM detection_search ds
    WHERE
        -- Username fuzzy search or no filter
        (
            search_query IS NULL
            OR search_query = ''
            OR ds.username % search_query  -- Uses trigram similarity operator
        )
        -- Streamer filter
        AND (
            streamer_id_filter IS NULL
            OR ds.streamer_id = streamer_id_filter
        )
        -- Date range filter
        AND (
            date_range_filter = 'all'
            OR (date_range_filter = 'week' AND ds.actual_timestamp >= NOW() - INTERVAL '7 days')
            OR (date_range_filter = 'month' AND ds.actual_timestamp >= NOW() - INTERVAL '30 days')
            OR (date_range_filter = 'year' AND ds.actual_timestamp >= NOW() - INTERVAL '365 days')
        )
    ORDER BY
        -- If searching, order by similarity score first, then by timestamp
        CASE
            WHEN search_query IS NOT NULL AND search_query != ''
            THEN similarity(ds.username, search_query)
            ELSE 0
        END DESC,
        ds.actual_timestamp DESC
    LIMIT result_limit;
END;
$$;


ALTER FUNCTION "public"."fuzzy_search_detections"("search_query" "text", "streamer_id_filter" bigint, "date_range_filter" "text", "similarity_threshold" double precision, "result_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fuzzy_search_detections_debug"("search_query" "text" DEFAULT NULL::"text", "streamer_id_filter" bigint DEFAULT NULL::bigint, "date_range_filter" "text" DEFAULT 'all'::"text", "similarity_threshold" double precision DEFAULT 0.2, "result_limit" integer DEFAULT 100) RETURNS TABLE("detection_id" "uuid", "username" "text", "streamer_id" bigint, "streamer_login" "text", "streamer_display_name" "text", "streamer_avatar" "text", "frame_time_seconds" integer, "confidence" double precision, "rank" "text", "vod_id" bigint, "vod_source_id" "text", "vod_url" "text", "actual_timestamp" timestamp with time zone, "similarity_score" real)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    -- Set the similarity threshold for this query
    EXECUTE format('SET LOCAL pg_trgm.similarity_threshold = %s', similarity_threshold);

    RETURN QUERY
    SELECT
        ds.detection_id,
        ds.username,
        ds.streamer_id,
        ds.streamer_login,
        ds.streamer_display_name,
        ds.streamer_avatar,
        ds.frame_time_seconds,
        ds.confidence,
        ds.rank,
        ds.vod_id,
        ds.vod_source_id,
        ds.vod_url,
        ds.actual_timestamp,
        CASE
            WHEN search_query IS NOT NULL AND search_query != ''
            THEN similarity(ds.username, search_query)
            ELSE 1.0
        END AS similarity_score
    FROM detection_search_debug ds
    WHERE
        -- Username fuzzy search or no filter
        (
            search_query IS NULL
            OR search_query = ''
            OR ds.username % search_query  -- Uses trigram similarity operator
        )
        -- Streamer filter
        AND (
            streamer_id_filter IS NULL
            OR ds.streamer_id = streamer_id_filter
        )
        -- Date range filter
        AND (
            date_range_filter = 'all'
            OR (date_range_filter = 'week' AND ds.actual_timestamp >= NOW() - INTERVAL '7 days')
            OR (date_range_filter = 'month' AND ds.actual_timestamp >= NOW() - INTERVAL '30 days')
            OR (date_range_filter = 'year' AND ds.actual_timestamp >= NOW() - INTERVAL '365 days')
        )
    ORDER BY
        -- If searching, order by similarity score first, then by timestamp
        CASE
            WHEN search_query IS NOT NULL AND search_query != ''
            THEN similarity(ds.username, search_query)
            ELSE 0
        END DESC,
        ds.actual_timestamp DESC
    LIMIT result_limit;
END;
$$;


ALTER FUNCTION "public"."fuzzy_search_detections_debug"("search_query" "text", "streamer_id_filter" bigint, "date_range_filter" "text", "similarity_threshold" double precision, "result_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fuzzy_search_detections_test"("search_query" "text" DEFAULT NULL::"text", "streamer_id_filter" bigint DEFAULT NULL::bigint, "date_range_filter" "text" DEFAULT 'all'::"text", "similarity_threshold" double precision DEFAULT 0.2, "result_limit" integer DEFAULT 100, "result_offset" integer DEFAULT 0) RETURNS TABLE("detection_id" "uuid", "username" "text", "streamer_id" bigint, "streamer_login" "text", "streamer_display_name" "text", "streamer_avatar" "text", "frame_time_seconds" integer, "confidence" double precision, "rank" "text", "vod_id" bigint, "vod_source_id" "text", "vod_url" "text", "actual_timestamp" timestamp with time zone, "similarity_score" real, "total_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    -- Set the similarity threshold for this query
    EXECUTE format('SET LOCAL pg_trgm.similarity_threshold = %s', similarity_threshold);

    RETURN QUERY
    WITH filtered_results AS (
        SELECT
            ds.detection_id,
            ds.username,
            ds.streamer_id,
            ds.streamer_login,
            ds.streamer_display_name,
            ds.streamer_avatar,
            ds.frame_time_seconds,
            ds.confidence,
            ds.rank,
            ds.vod_id,
            ds.vod_source_id,
            ds.vod_url,
            ds.actual_timestamp,
            CASE
                WHEN search_query IS NOT NULL AND search_query != ''
                THEN similarity(ds.username, search_query)
                ELSE 1.0
            END AS similarity_score
        FROM detection_search ds
        WHERE
            -- Username fuzzy search or no filter
            (
                search_query IS NULL
                OR search_query = ''
                OR ds.username % search_query  -- Uses trigram similarity operator
            )
            -- Streamer filter
            AND (
                streamer_id_filter IS NULL
                OR ds.streamer_id = streamer_id_filter
            )
            -- Date range filter
            AND (
                date_range_filter = 'all'
                OR (date_range_filter = 'day' AND ds.actual_timestamp >= NOW() - INTERVAL '1 day')
                OR (date_range_filter = 'week' AND ds.actual_timestamp >= NOW() - INTERVAL '7 days')
                OR (date_range_filter = 'month' AND ds.actual_timestamp >= NOW() - INTERVAL '30 days')
                OR (date_range_filter = 'year' AND ds.actual_timestamp >= NOW() - INTERVAL '365 days')
            )
    ),
    counted_results AS (
        SELECT
            *,
            COUNT(*) OVER() as total_count
        FROM filtered_results
    )
    -- FIX: Fully qualify all column names to avoid ambiguity
    SELECT
        counted_results.detection_id,
        counted_results.username,
        counted_results.streamer_id,
        counted_results.streamer_login,
        counted_results.streamer_display_name,
        counted_results.streamer_avatar,
        counted_results.frame_time_seconds,
        counted_results.confidence,
        counted_results.rank,
        counted_results.vod_id,
        counted_results.vod_source_id,
        counted_results.vod_url,
        counted_results.actual_timestamp,
        counted_results.similarity_score,
        counted_results.total_count::bigint
    FROM counted_results
    ORDER BY
        -- If searching, order by similarity score first, then by timestamp
        CASE
            WHEN search_query IS NOT NULL AND search_query != ''
            THEN counted_results.similarity_score
            ELSE 0
        END DESC,
        counted_results.actual_timestamp DESC
    LIMIT result_limit
    OFFSET result_offset;
END;
$$;


ALTER FUNCTION "public"."fuzzy_search_detections_test"("search_query" "text", "streamer_id_filter" bigint, "date_range_filter" "text", "similarity_threshold" double precision, "result_limit" integer, "result_offset" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_global_stats"() RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    stats json;
BEGIN
    SELECT json_build_object(
        'streamers', COUNT(DISTINCT streamer_id),
        'vods', COUNT(DISTINCT vod_id),
        'matchups', COUNT(*)
    ) INTO stats
    FROM detection_search;

    RETURN stats;
END;
$$;


ALTER FUNCTION "public"."get_global_stats"() OWNER TO "postgres";


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



CREATE OR REPLACE FUNCTION "public"."get_top_streamers_with_recent_detections"("top_count" integer DEFAULT 10, "detections_per_streamer" integer DEFAULT 5) RETURNS TABLE("streamer_id" bigint, "streamer_login" "text", "streamer_display_name" "text", "streamer_avatar" "text", "total_detections" bigint, "total_vods" bigint, "detection_id" "uuid", "username" "text", "frame_time_seconds" integer, "confidence" double precision, "rank" "text", "vod_id" bigint, "vod_source_id" "text", "vod_url" "text", "actual_timestamp" timestamp with time zone, "detection_row_num" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  RETURN QUERY
  WITH top_streamers AS (
    SELECT
      ds.streamer_id,
      ds.streamer_login,
      ds.streamer_display_name,
      ds.streamer_avatar,
      COUNT(*) AS detection_count,
      COUNT(DISTINCT ds.vod_id) AS vod_count
    FROM public.detection_search ds
    GROUP BY ds.streamer_id, ds.streamer_login, ds.streamer_display_name, ds.streamer_avatar
    ORDER BY detection_count DESC
    LIMIT top_count
  ),
  recent_detections AS (
    SELECT
      ts.streamer_id,
      ts.streamer_login,
      ts.streamer_display_name,
      ts.streamer_avatar,
      ts.detection_count,
      ts.vod_count,
      ds.detection_id,
      ds.username,
      ds.frame_time_seconds,
      ds.confidence,
      ds.rank,
      ds.vod_id,
      ds.vod_source_id,
      ds.vod_url,
      ds.actual_timestamp,
      ROW_NUMBER() OVER (PARTITION BY ts.streamer_id ORDER BY ds.actual_timestamp DESC) AS row_num
    FROM top_streamers ts
    JOIN public.detection_search ds ON ds.streamer_id = ts.streamer_id
  )
  SELECT
    rd.streamer_id,
    rd.streamer_login,
    rd.streamer_display_name,
    rd.streamer_avatar,
    rd.detection_count::bigint AS total_detections,
    rd.vod_count::bigint       AS total_vods,
    rd.detection_id,
    rd.username,
    rd.frame_time_seconds,
    rd.confidence,
    rd.rank,
    rd.vod_id,
    rd.vod_source_id,
    rd.vod_url,
    rd.actual_timestamp,
    rd.row_num AS detection_row_num
  FROM recent_detections rd
  WHERE rd.row_num <= detections_per_streamer
  ORDER BY rd.detection_count DESC, rd.streamer_id, rd.row_num;
END;
$$;


ALTER FUNCTION "public"."get_top_streamers_with_recent_detections"("top_count" integer, "detections_per_streamer" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
  BEGIN
      NEW.updated_at = now();
      RETURN NEW;
  END;
  $$;


ALTER FUNCTION "public"."handle_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."process_pending_vods"("max_vods" integer DEFAULT 5) RETURNS TABLE("vod_id" bigint, "source_id" "text", "pending_chunks" bigint, "request_id" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$DECLARE
    v_supabase_url TEXT;
    v_secret_key TEXT;
    v_max_concurrent INTEGER;
    v_current_active_count INTEGER;
    v_vod RECORD;
    v_request_id BIGINT;
    v_processed_count INTEGER := 0;
BEGIN
    -- Get credentials from Vault
    SELECT decrypted_secret INTO v_supabase_url
    FROM vault.decrypted_secrets
    WHERE name = 'supabase_url';

    SELECT decrypted_secret INTO v_secret_key
    FROM vault.decrypted_secrets
    WHERE name = 'secret_key';

    -- Check if credentials are available
    IF v_supabase_url IS NULL OR v_secret_key IS NULL THEN
        RAISE EXCEPTION 'Missing Supabase credentials in Vault. Please configure supabase_url and secret_key.';
    END IF;

    -- Get max concurrent chunks configuration
    SELECT value::integer INTO v_max_concurrent
    FROM processing_config
    WHERE key = 'max_concurrent_chunks';

    -- Default to 10 if not configured
    IF v_max_concurrent IS NULL THEN
        v_max_concurrent := 10;
    END IF;

    -- Count currently active chunks (queued or processing)
    SELECT COUNT(*)
    INTO v_current_active_count
    FROM chunks
    WHERE status IN ('queued', 'processing');

    RAISE NOTICE 'Current active chunks: %, max allowed: %', v_current_active_count, v_max_concurrent;

    -- Check if we have capacity for more chunks
    IF v_current_active_count >= v_max_concurrent THEN
        RAISE NOTICE 'At capacity (% active chunks), not processing new VODs', v_current_active_count;
        RETURN;
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
        -- Call process-vod edge function with apikey header
        SELECT net.http_post(
            url := v_supabase_url || '/functions/v1/process-vod',
            headers := jsonb_build_object(
                'Content-Type', 'application/json',
                'apikey', v_secret_key
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

    -- If no VODs were processed, log it
    IF v_processed_count = 0 THEN
        RAISE NOTICE 'No VODs with pending chunks found for processing';
    END IF;

    RETURN;
END;$$;


ALTER FUNCTION "public"."process_pending_vods"("max_vods" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."process_pending_vods"("max_vods" integer) IS 'Selects up to N VODs with pending chunks and triggers processing via edge function';



CREATE OR REPLACE FUNCTION "public"."simulate_chunk_plan_for_vod"("p_vod_id" bigint, "p_target_chunk_seconds" integer DEFAULT 3600, "p_min_gap_seconds" integer DEFAULT 300) RETURNS TABLE("segment_start" integer, "segment_end" integer, "gap_start" integer, "gap_end" integer, "proposed_chunk_start" integer, "proposed_chunk_end" integer, "proposed_duration" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_vod_duration     integer;
  v_bazaar_chapters  integer[];
  v_seg_start        integer;
  v_seg_end          integer;
  v_seg_dur          integer;
  v_gap_mr           int4multirange;
  v_existing_mr      int4multirange;
  v_seg_mr           int4multirange;
  r_gap              int4range;
  g_start            integer;
  g_end              integer;
  g_dur              integer;
  num_chunks         integer;
  chunk_dur          integer;
  i                  integer;
  cur_start          integer;
  cur_end            integer;
begin
  select duration_seconds, bazaar_chapters
  into v_vod_duration, v_bazaar_chapters
  from vods where id = p_vod_id;

  if v_vod_duration is null then
    return;
  end if;

  if v_bazaar_chapters is null
     or array_length(v_bazaar_chapters,1) is null
     or array_length(v_bazaar_chapters,1)=0 then
    v_bazaar_chapters := array[0, v_vod_duration];
  end if;

  for i in 1..array_length(v_bazaar_chapters,1) by 2 loop
    v_seg_start := v_bazaar_chapters[i];
    v_seg_end   := v_bazaar_chapters[i+1];
    if v_seg_end is null then continue; end if;
    v_seg_start := greatest(0, least(v_seg_start, v_vod_duration));
    v_seg_end   := greatest(0, least(v_seg_end,   v_vod_duration));
    if v_seg_end <= v_seg_start then continue; end if;
    v_seg_dur := v_seg_end - v_seg_start;
    if v_seg_dur < p_min_gap_seconds then continue; end if;

    v_seg_mr := int4multirange(int4range(v_seg_start, v_seg_end));

    select coalesce(range_agg(int4range(c.start_seconds, c.end_seconds))::int4multirange, '{}')
    into v_existing_mr
    from chunks c
    where c.vod_id = p_vod_id
      and int4range(c.start_seconds, c.end_seconds) && int4range(v_seg_start, v_seg_end);

    v_gap_mr := v_seg_mr - coalesce(v_existing_mr, '{}');

    for r_gap in select unnest(v_gap_mr) loop
      g_start := lower(r_gap);
      g_end   := upper(r_gap);
      g_dur   := g_end - g_start;
      if g_dur < p_min_gap_seconds then continue; end if;

      if g_dur <= p_target_chunk_seconds then
        proposed_chunk_start := g_start;
        proposed_chunk_end   := g_end;
        proposed_duration    := g_dur;
        segment_start := v_seg_start;
        segment_end   := v_seg_end;
        gap_start     := g_start;
        gap_end       := g_end;
        return next;
        continue;
      end if;

      num_chunks := floor(g_dur::numeric / p_target_chunk_seconds);
      if num_chunks < 1 then num_chunks := 1; end if;
      chunk_dur := ceil(g_dur::numeric / num_chunks);
      cur_start := g_start;

      for i in 1..num_chunks loop
        if i = num_chunks then
          cur_end := g_end;
        else
          cur_end := least(cur_start + chunk_dur, g_end);
          if (g_end - cur_end) > 0 and (g_end - cur_end) < p_target_chunk_seconds then
            cur_end := g_end;
            num_chunks := i;
          end if;
        end if;
        proposed_chunk_start := cur_start;
        proposed_chunk_end   := cur_end;
        proposed_duration    := cur_end - cur_start;
        segment_start := v_seg_start;
        segment_end   := v_seg_end;
        gap_start     := g_start;
        gap_end       := g_end;
        return next;
        exit when cur_end >= g_end;
        cur_start := cur_end;
      end loop;
    end loop;
  end loop;
end;
$$;


ALTER FUNCTION "public"."simulate_chunk_plan_for_vod"("p_vod_id" bigint, "p_target_chunk_seconds" integer, "p_min_gap_seconds" integer) OWNER TO "postgres";


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



CREATE OR REPLACE FUNCTION "public"."vods_mark_chunks_failed_on_vod_failure"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- Only run on status change from 'processing' to 'failed'
  IF (TG_OP = 'UPDATE')
     AND (OLD.status = 'processing'::vod_status)
     AND (NEW.status = 'failed'::vod_status) THEN

    -- Update associated chunks to failed if not already failed
    UPDATE public.chunks
    SET status = 'failed'::processing_status,
        updated_at = NOW()
    WHERE vod_id = NEW.id
      AND status IS DISTINCT FROM 'failed'::processing_status;

  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."vods_mark_chunks_failed_on_vod_failure"() OWNER TO "postgres";

CREATE OR REPLACE VIEW "public"."detection_search" WITH ("security_invoker"='on') AS
 SELECT "d"."id" AS "detection_id",
    "d"."username",
    "d"."frame_time_seconds",
    "d"."confidence",
    "d"."rank",
    "d"."storage_path",
    "d"."no_right_edge",
    "d"."created_at" AS "detection_created_at",
    "v"."id" AS "vod_id",
    "v"."source_id" AS "vod_source_id",
    "v"."title" AS "vod_title",
    "v"."published_at" AS "vod_published_at",
    "v"."duration_seconds" AS "vod_duration_seconds",
    "v"."availability" AS "vod_availability",
    ("v"."published_at" + (("d"."frame_time_seconds" || ' seconds'::"text"))::interval) AS "actual_timestamp",
    "s"."id" AS "streamer_id",
    "s"."login" AS "streamer_login",
    "s"."display_name" AS "streamer_display_name",
    "s"."profile_image_url" AS "streamer_avatar",
        CASE
            WHEN ("v"."source_id" IS NOT NULL) THEN (((('https://www.twitch.tv/videos/'::"text" || "v"."source_id") || '?t='::"text") || "d"."frame_time_seconds") || 's'::"text")
            ELSE NULL::"text"
        END AS "vod_url"
   FROM (("public"."detections" "d"
     JOIN "public"."vods" "v" ON (("d"."vod_id" = "v"."id")))
     JOIN "public"."streamers" "s" ON (("v"."streamer_id" = "s"."id")))
  WHERE (("v"."availability" = 'available'::"public"."vod_availability") AND ("d"."confidence" > (0.7)::double precision));


ALTER VIEW "public"."detection_search" OWNER TO "postgres";


COMMENT ON VIEW "public"."detection_search" IS 'copy of detection_search, but can be altered without affecting prod';



CREATE OR REPLACE VIEW "public"."detection_search_debug" WITH ("security_invoker"='on') AS
 SELECT "d"."id" AS "detection_id",
    "d"."username",
    "d"."frame_time_seconds",
    "d"."confidence",
    "d"."rank",
    "d"."storage_path",
    "d"."no_right_edge",
    "d"."created_at" AS "detection_created_at",
    "v"."id" AS "vod_id",
    "v"."source_id" AS "vod_source_id",
    "v"."title" AS "vod_title",
    "v"."published_at" AS "vod_published_at",
    "v"."duration_seconds" AS "vod_duration_seconds",
    "v"."availability" AS "vod_availability",
    ("v"."published_at" + (("d"."frame_time_seconds" || ' seconds'::"text"))::interval) AS "actual_timestamp",
    "s"."id" AS "streamer_id",
    "s"."login" AS "streamer_login",
    "s"."display_name" AS "streamer_display_name",
    "s"."profile_image_url" AS "streamer_avatar",
        CASE
            WHEN ("v"."source_id" IS NOT NULL) THEN (((('https://www.twitch.tv/videos/'::"text" || "v"."source_id") || '?t='::"text") || "d"."frame_time_seconds") || 's'::"text")
            ELSE NULL::"text"
        END AS "vod_url"
   FROM (("public"."detections" "d"
     JOIN "public"."vods" "v" ON (("d"."vod_id" = "v"."id")))
     JOIN "public"."streamers" "s" ON (("v"."streamer_id" = "s"."id")))
  WHERE (("v"."availability" = 'available'::"public"."vod_availability") AND ("d"."confidence" > (0.0)::double precision));


ALTER VIEW "public"."detection_search_debug" OWNER TO "postgres";




CREATE OR REPLACE VIEW "public"."streamer_detection_stats" WITH ("security_invoker"='on') AS
 SELECT "s"."id" AS "streamer_id",
    "s"."login",
    "s"."display_name",
    "count"("d"."id") AS "total_detections",
    "avg"("d"."confidence") AS "avg_confidence",
    "count"("d"."id") FILTER (WHERE ("d"."no_right_edge" = true)) AS "no_right_edge_detections",
    "count"(DISTINCT "v"."id") FILTER (WHERE ("v"."status" = 'processing'::"public"."vod_status")) AS "vods_processing",
    "count"(DISTINCT "v"."id") FILTER (WHERE ("v"."status" = 'completed'::"public"."vod_status")) AS "vods_completed",
    "count"(DISTINCT "v"."id") FILTER (WHERE ("v"."status" = 'failed'::"public"."vod_status")) AS "vods_failed",
    "count"(DISTINCT "v"."id") FILTER (WHERE ("v"."status" = 'partial'::"public"."vod_status")) AS "vods_partial",
    "count"(DISTINCT "v"."id") FILTER (WHERE ("v"."status" = 'pending'::"public"."vod_status")) AS "vods_pending",
    "count"(DISTINCT "v"."id") AS "total_vods",
        CASE
            WHEN ("count"(DISTINCT "v"."id") > 0) THEN "round"((("count"("d"."id"))::numeric / (NULLIF("count"(DISTINCT "v"."id"), 0))::numeric), 2)
            ELSE (0)::numeric
        END AS "avg_detections_per_vod"
   FROM (("public"."streamers" "s"
     LEFT JOIN "public"."vods" "v" ON (("v"."streamer_id" = "s"."id")))
     LEFT JOIN "public"."detections" "d" ON (("d"."vod_id" = "v"."id")))
  GROUP BY "s"."id", "s"."login", "s"."display_name";


ALTER VIEW "public"."streamer_detection_stats" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."streamers_with_detections" WITH ("security_invoker"='on') AS
 SELECT "s"."id" AS "streamer_id",
    "s"."login" AS "streamer_login",
    "s"."display_name" AS "streamer_display_name",
    "s"."profile_image_url" AS "streamer_avatar",
    "s"."processing_enabled",
    "count"(DISTINCT "d"."id") AS "detection_count",
    "count"(DISTINCT "v"."id") AS "vod_count",
    "max"(("v"."published_at" + (("d"."frame_time_seconds" || ' seconds'::"text"))::interval)) AS "latest_detection_timestamp"
   FROM (("public"."streamers" "s"
     JOIN "public"."vods" "v" ON (("v"."streamer_id" = "s"."id")))
     JOIN "public"."detections" "d" ON (("d"."vod_id" = "v"."id")))
  WHERE (("v"."availability" = 'available'::"public"."vod_availability") AND ("d"."confidence" > (0.7)::double precision))
  GROUP BY "s"."id", "s"."login", "s"."display_name", "s"."profile_image_url", "s"."processing_enabled"
  ORDER BY ("count"(DISTINCT "d"."id")) DESC;


ALTER VIEW "public"."streamers_with_detections" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vod_stats" WITH ("security_invoker"='on') AS
 SELECT "v"."id",
    "s"."streamer",
    "d_total"."total_detections",
    "d"."avg_confidence",
    "q"."quality",
    "v"."source_id",
    "v"."source",
    "v"."title",
    "v"."duration_seconds",
    "v"."published_at",
    "v"."availability",
    "v"."last_availability_check",
    "v"."unavailable_since",
    "v"."ready_for_processing",
    "v"."created_at",
    "v"."updated_at",
    "v"."bazaar_chapters",
    "v"."status",
    "c"."chunks_count" AS "chunks"
   FROM ((((("public"."vods" "v"
     LEFT JOIN LATERAL ( SELECT "count"(*) AS "chunks_count"
           FROM "public"."chunks" "ch"
          WHERE ("ch"."vod_id" = "v"."id")) "c" ON (true))
     LEFT JOIN LATERAL ( SELECT "avg"("de"."confidence") AS "avg_confidence"
           FROM "public"."detections" "de"
          WHERE (("de"."vod_id" = "v"."id") AND ("de"."confidence" IS NOT NULL))) "d" ON (true))
     LEFT JOIN LATERAL ( SELECT "count"(*) AS "total_detections"
           FROM "public"."detections" "de2"
          WHERE ("de2"."vod_id" = "v"."id")) "d_total" ON (true))
     LEFT JOIN LATERAL ( SELECT "st"."display_name" AS "streamer"
           FROM "public"."streamers" "st"
          WHERE ("st"."id" = "v"."streamer_id")
         LIMIT 1) "s" ON (true))
     LEFT JOIN LATERAL ( SELECT
                CASE
                    WHEN ("v"."status" <> 'pending'::"public"."vod_status") THEN
                    CASE
                        WHEN ("array_length"("array_agg"(DISTINCT "ch"."quality"), 1) = 1) THEN ("array_agg"(DISTINCT "ch"."quality"))[1]
                        ELSE NULL::"text"
                    END
                    ELSE NULL::"text"
                END AS "quality"
           FROM "public"."chunks" "ch"
          WHERE ("ch"."vod_id" = "v"."id")) "q" ON (true));


ALTER VIEW "public"."vod_stats" OWNER TO "postgres";


ALTER TABLE "public"."vods" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."vods_id_seq"
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
    ADD CONSTRAINT "sfot_profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sfot_profiles"
    ADD CONSTRAINT "sfot_profiles_profile_name_key" UNIQUE ("profile_name");



ALTER TABLE ONLY "public"."streamers"
    ADD CONSTRAINT "streamers_login_key" UNIQUE ("login");



ALTER TABLE ONLY "public"."streamers"
    ADD CONSTRAINT "streamers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."vods"
    ADD CONSTRAINT "vods_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."vods"
    ADD CONSTRAINT "vods_source_source_id_key" UNIQUE ("source", "source_id");



CREATE INDEX "idx_chunks_ready" ON "public"."chunks" USING "btree" ("scheduled_for", "priority" DESC) WHERE ("status" = 'pending'::"public"."processing_status");



CREATE INDEX "idx_chunks_status" ON "public"."chunks" USING "btree" ("status");



CREATE INDEX "idx_chunks_vod" ON "public"."chunks" USING "btree" ("vod_id");



CREATE INDEX "idx_chunks_vod_status" ON "public"."chunks" USING "btree" ("vod_id", "status");



CREATE INDEX "idx_detection_search_username_trgm" ON "public"."detections" USING "gin" ("username" "public"."gin_trgm_ops");



CREATE INDEX "idx_detections_chunk_id" ON "public"."detections" USING "btree" ("chunk_id");



CREATE INDEX "idx_detections_no_right_edge" ON "public"."detections" USING "btree" ("no_right_edge") WHERE ("no_right_edge" = true);



CREATE INDEX "idx_detections_truncated" ON "public"."detections" USING "btree" ("truncated") WHERE ("truncated" = true);



CREATE INDEX "idx_detections_username" ON "public"."detections" USING "btree" ("lower"("username"));



CREATE INDEX "idx_detections_vod" ON "public"."detections" USING "btree" ("vod_id");



CREATE INDEX "idx_sfot_profiles_dates" ON "public"."sfot_profiles" USING "btree" ("from_date", "to_date");



CREATE INDEX "idx_sfot_profiles_profile_name" ON "public"."sfot_profiles" USING "btree" ("profile_name");



CREATE INDEX "idx_streamers_sfot_profile" ON "public"."streamers" USING "btree" ("sfot_profile_id");



CREATE INDEX "idx_vods_availability" ON "public"."vods" USING "btree" ("availability");



CREATE INDEX "idx_vods_status" ON "public"."vods" USING "btree" ("status");



CREATE INDEX "idx_vods_status_published_at" ON "public"."vods" USING "btree" ("status", "published_at") WHERE ("status" = 'pending'::"public"."vod_status");



CREATE INDEX "idx_vods_streamer" ON "public"."vods" USING "btree" ("streamer_id");



CREATE OR REPLACE TRIGGER "set_updated_at" BEFORE UPDATE ON "public"."sfot_profiles" FOR EACH ROW EXECUTE FUNCTION "public"."handle_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_auto_create_chunks" AFTER INSERT OR UPDATE OF "ready_for_processing", "duration_seconds", "bazaar_chapters" ON "public"."vods" FOR EACH ROW EXECUTE FUNCTION "public"."auto_create_chunks"();



CREATE OR REPLACE TRIGGER "trigger_chunk_status_update_vod" AFTER INSERT OR DELETE OR UPDATE OF "status" ON "public"."chunks" FOR EACH ROW EXECUTE FUNCTION "public"."update_vod_status"();



CREATE OR REPLACE TRIGGER "trigger_streamer_enabled" AFTER UPDATE OF "processing_enabled" ON "public"."streamers" FOR EACH ROW EXECUTE FUNCTION "public"."create_chunks_for_enabled_streamer"();



CREATE OR REPLACE TRIGGER "trigger_streamer_processing_disabled" AFTER UPDATE OF "processing_enabled" ON "public"."streamers" FOR EACH ROW EXECUTE FUNCTION "public"."cleanup_streamer_chunks_on_disable"();



CREATE OR REPLACE TRIGGER "trigger_vod_processing_disabled" AFTER UPDATE OF "ready_for_processing" ON "public"."vods" FOR EACH ROW EXECUTE FUNCTION "public"."cleanup_vod_chunks_on_disable"();



CREATE OR REPLACE TRIGGER "vods_mark_chunks_failed_trigger" AFTER UPDATE OF "status" ON "public"."vods" FOR EACH ROW WHEN (("old"."status" IS DISTINCT FROM "new"."status")) EXECUTE FUNCTION "public"."vods_mark_chunks_failed_on_vod_failure"();



ALTER TABLE ONLY "public"."chunks"
    ADD CONSTRAINT "chunks_vod_id_fkey" FOREIGN KEY ("vod_id") REFERENCES "public"."vods"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."detections"
    ADD CONSTRAINT "detections_chunk_id_fkey" FOREIGN KEY ("chunk_id") REFERENCES "public"."chunks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."detections"
    ADD CONSTRAINT "detections_vod_id_fkey" FOREIGN KEY ("vod_id") REFERENCES "public"."vods"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."streamers"
    ADD CONSTRAINT "streamers_sfot_profile_id_fkey" FOREIGN KEY ("sfot_profile_id") REFERENCES "public"."sfot_profiles"("id");



ALTER TABLE ONLY "public"."vods"
    ADD CONSTRAINT "vods_streamer_id_fkey" FOREIGN KEY ("streamer_id") REFERENCES "public"."streamers"("id") ON DELETE CASCADE;



CREATE POLICY "Allow authenticated delete" ON "public"."sfot_profiles" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "Allow authenticated insert" ON "public"."sfot_profiles" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Allow authenticated update" ON "public"."sfot_profiles" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Allow public read access" ON "public"."sfot_profiles" FOR SELECT USING (true);



CREATE POLICY "Public can view available VODs" ON "public"."vods" FOR SELECT USING (("availability" = 'available'::"public"."vod_availability"));



CREATE POLICY "Public can view detections from available VODs" ON "public"."detections" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."vods"
  WHERE (("vods"."id" = "detections"."vod_id") AND ("vods"."availability" = 'available'::"public"."vod_availability")))));



CREATE POLICY "Public users can insert sfot_profiles" ON "public"."sfot_profiles" FOR INSERT TO "anon" WITH CHECK (true);



CREATE POLICY "Public users can update sfot_profiles" ON "public"."sfot_profiles" FOR UPDATE USING (true) WITH CHECK (true);



ALTER TABLE "public"."cataloger_runs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "cataloger_runs_all_access" ON "public"."cataloger_runs" USING (true) WITH CHECK (true);



ALTER TABLE "public"."chunks" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "chunks_all_access" ON "public"."chunks" USING (true) WITH CHECK (true);



ALTER TABLE "public"."detections" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."processing_config" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "processing_config_block_client_delete" ON "public"."processing_config" FOR DELETE TO "authenticated" USING (false);



CREATE POLICY "processing_config_block_client_insert" ON "public"."processing_config" FOR INSERT TO "authenticated" WITH CHECK (false);



CREATE POLICY "processing_config_block_client_select" ON "public"."processing_config" FOR SELECT TO "authenticated" USING (false);



CREATE POLICY "processing_config_block_client_update" ON "public"."processing_config" FOR UPDATE TO "authenticated" USING (false) WITH CHECK (false);



ALTER TABLE "public"."sfot_profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."streamers" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "streamers_all_access" ON "public"."streamers" USING (true) WITH CHECK (true);



ALTER TABLE "public"."vods" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";





GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";






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



GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "service_role";




















































































































































































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



GRANT ALL ON FUNCTION "public"."create_missing_chunks_for_vod"("p_vod_id" bigint, "p_target_chunk_seconds" integer, "p_min_gap_seconds" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."create_missing_chunks_for_vod"("p_vod_id" bigint, "p_target_chunk_seconds" integer, "p_min_gap_seconds" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_missing_chunks_for_vod"("p_vod_id" bigint, "p_target_chunk_seconds" integer, "p_min_gap_seconds" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."cron_insert_new_streamers"() TO "anon";
GRANT ALL ON FUNCTION "public"."cron_insert_new_streamers"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."cron_insert_new_streamers"() TO "service_role";



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



GRANT ALL ON FUNCTION "public"."force_process_vod"("p_vod_id" bigint, "p_source_id" "text", "p_target_chunk_seconds" integer, "p_min_gap_seconds" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."force_process_vod"("p_vod_id" bigint, "p_source_id" "text", "p_target_chunk_seconds" integer, "p_min_gap_seconds" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."force_process_vod"("p_vod_id" bigint, "p_source_id" "text", "p_target_chunk_seconds" integer, "p_min_gap_seconds" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."fuzzy_search_detections"("search_query" "text", "streamer_id_filter" bigint, "date_range_filter" "text", "similarity_threshold" double precision, "result_limit" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."fuzzy_search_detections"("search_query" "text", "streamer_id_filter" bigint, "date_range_filter" "text", "similarity_threshold" double precision, "result_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fuzzy_search_detections"("search_query" "text", "streamer_id_filter" bigint, "date_range_filter" "text", "similarity_threshold" double precision, "result_limit" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."fuzzy_search_detections_debug"("search_query" "text", "streamer_id_filter" bigint, "date_range_filter" "text", "similarity_threshold" double precision, "result_limit" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."fuzzy_search_detections_debug"("search_query" "text", "streamer_id_filter" bigint, "date_range_filter" "text", "similarity_threshold" double precision, "result_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fuzzy_search_detections_debug"("search_query" "text", "streamer_id_filter" bigint, "date_range_filter" "text", "similarity_threshold" double precision, "result_limit" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."fuzzy_search_detections_test"("search_query" "text", "streamer_id_filter" bigint, "date_range_filter" "text", "similarity_threshold" double precision, "result_limit" integer, "result_offset" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."fuzzy_search_detections_test"("search_query" "text", "streamer_id_filter" bigint, "date_range_filter" "text", "similarity_threshold" double precision, "result_limit" integer, "result_offset" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fuzzy_search_detections_test"("search_query" "text", "streamer_id_filter" bigint, "date_range_filter" "text", "similarity_threshold" double precision, "result_limit" integer, "result_offset" integer) TO "service_role";



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



GRANT ALL ON FUNCTION "public"."get_global_stats"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_global_stats"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_global_stats"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_pending_chunks_for_vod"("p_vod_id" bigint, "p_source_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_pending_chunks_for_vod"("p_vod_id" bigint, "p_source_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_pending_chunks_for_vod"("p_vod_id" bigint, "p_source_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_pending_vods_count"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_pending_vods_count"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_pending_vods_count"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_top_streamers_with_recent_detections"("top_count" integer, "detections_per_streamer" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_top_streamers_with_recent_detections"("top_count" integer, "detections_per_streamer" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_top_streamers_with_recent_detections"("top_count" integer, "detections_per_streamer" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_updated_at"() TO "service_role";



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



GRANT ALL ON FUNCTION "public"."oid_dist"("oid", "oid") TO "postgres";
GRANT ALL ON FUNCTION "public"."oid_dist"("oid", "oid") TO "anon";
GRANT ALL ON FUNCTION "public"."oid_dist"("oid", "oid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."oid_dist"("oid", "oid") TO "service_role";



GRANT ALL ON FUNCTION "public"."process_pending_vods"("max_vods" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."process_pending_vods"("max_vods" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_pending_vods"("max_vods" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "postgres";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "anon";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "service_role";



GRANT ALL ON FUNCTION "public"."show_limit"() TO "postgres";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "anon";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "service_role";



GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "postgres";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "anon";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."simulate_chunk_plan_for_vod"("p_vod_id" bigint, "p_target_chunk_seconds" integer, "p_min_gap_seconds" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."simulate_chunk_plan_for_vod"("p_vod_id" bigint, "p_target_chunk_seconds" integer, "p_min_gap_seconds" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."simulate_chunk_plan_for_vod"("p_vod_id" bigint, "p_target_chunk_seconds" integer, "p_min_gap_seconds" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "service_role";



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



GRANT ALL ON FUNCTION "public"."vods_mark_chunks_failed_on_vod_failure"() TO "anon";
GRANT ALL ON FUNCTION "public"."vods_mark_chunks_failed_on_vod_failure"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."vods_mark_chunks_failed_on_vod_failure"() TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "service_role";
























GRANT ALL ON TABLE "public"."cataloger_runs" TO "anon";
GRANT ALL ON TABLE "public"."cataloger_runs" TO "authenticated";
GRANT ALL ON TABLE "public"."cataloger_runs" TO "service_role";



GRANT ALL ON TABLE "public"."chunks" TO "anon";
GRANT ALL ON TABLE "public"."chunks" TO "authenticated";
GRANT ALL ON TABLE "public"."chunks" TO "service_role";



GRANT ALL ON TABLE "public"."detections" TO "anon";
GRANT ALL ON TABLE "public"."detections" TO "authenticated";
GRANT ALL ON TABLE "public"."detections" TO "service_role";



GRANT ALL ON TABLE "public"."streamers" TO "anon";
GRANT ALL ON TABLE "public"."streamers" TO "authenticated";
GRANT ALL ON TABLE "public"."streamers" TO "service_role";



GRANT ALL ON TABLE "public"."vods" TO "anon";
GRANT ALL ON TABLE "public"."vods" TO "authenticated";
GRANT ALL ON TABLE "public"."vods" TO "service_role";



GRANT ALL ON TABLE "public"."detection_search" TO "anon";
GRANT ALL ON TABLE "public"."detection_search" TO "authenticated";
GRANT ALL ON TABLE "public"."detection_search" TO "service_role";



GRANT ALL ON TABLE "public"."detection_search_debug" TO "anon";
GRANT ALL ON TABLE "public"."detection_search_debug" TO "authenticated";
GRANT ALL ON TABLE "public"."detection_search_debug" TO "service_role";



GRANT ALL ON TABLE "public"."processing_config" TO "anon";
GRANT ALL ON TABLE "public"."processing_config" TO "authenticated";
GRANT ALL ON TABLE "public"."processing_config" TO "service_role";



GRANT ALL ON TABLE "public"."sfot_profiles" TO "anon";
GRANT ALL ON TABLE "public"."sfot_profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."sfot_profiles" TO "service_role";



GRANT ALL ON SEQUENCE "public"."sfot_profiles_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."sfot_profiles_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."sfot_profiles_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."streamer_detection_stats" TO "anon";
GRANT ALL ON TABLE "public"."streamer_detection_stats" TO "authenticated";
GRANT ALL ON TABLE "public"."streamer_detection_stats" TO "service_role";



GRANT ALL ON TABLE "public"."streamers_with_detections" TO "anon";
GRANT ALL ON TABLE "public"."streamers_with_detections" TO "authenticated";
GRANT ALL ON TABLE "public"."streamers_with_detections" TO "service_role";



GRANT ALL ON TABLE "public"."vod_stats" TO "anon";
GRANT ALL ON TABLE "public"."vod_stats" TO "authenticated";
GRANT ALL ON TABLE "public"."vod_stats" TO "service_role";



GRANT ALL ON SEQUENCE "public"."vods_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."vods_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."vods_id_seq" TO "service_role";









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































drop extension if exists "pg_net";

create extension if not exists "pg_net" with schema "public";


