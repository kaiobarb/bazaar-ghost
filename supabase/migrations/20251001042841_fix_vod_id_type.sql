-- Fix vod_id type to match the actual vods table (BIGINT not UUID)
DROP FUNCTION IF EXISTS process_pending_vods(INTEGER);
DROP FUNCTION IF EXISTS manual_process_pending_vods(INT);
DROP FUNCTION IF EXISTS cron_process_pending_vods();

-- Recreate function with correct vod_id type (BIGINT)
CREATE OR REPLACE FUNCTION process_pending_vods(max_vods INTEGER DEFAULT 5)
RETURNS TABLE(
    vod_id BIGINT,
    source_id TEXT,
    pending_chunks BIGINT,
    request_id BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
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
            -- Has chunks that are not completed or currently processing
            AND c.status NOT IN ('completed', 'processing')
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

        -- Return the result (no cast needed, vod_id is already BIGINT)
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

-- Recreate manual trigger function with correct return type
CREATE OR REPLACE FUNCTION manual_process_pending_vods(max_vods INT DEFAULT 10)
RETURNS TABLE (
    vod_id BIGINT,
    source_id TEXT,
    pending_chunks BIGINT,
    request_id BIGINT
)
LANGUAGE sql
SECURITY DEFINER
AS $$
    SELECT * FROM process_pending_vods(max_vods);
$$;

-- Recreate cron wrapper function
CREATE OR REPLACE FUNCTION cron_process_pending_vods()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
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

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION process_pending_vods TO postgres;
GRANT EXECUTE ON FUNCTION process_pending_vods TO service_role;
GRANT EXECUTE ON FUNCTION manual_process_pending_vods TO postgres;
GRANT EXECUTE ON FUNCTION manual_process_pending_vods TO service_role;
GRANT EXECUTE ON FUNCTION cron_process_pending_vods TO postgres;
GRANT EXECUTE ON FUNCTION cron_process_pending_vods TO service_role;

-- Update comments
COMMENT ON FUNCTION process_pending_vods IS 'Selects up to N VODs with pending chunks and triggers processing via edge function';
COMMENT ON FUNCTION manual_process_pending_vods IS 'Manual trigger for testing VOD processing scheduling';
COMMENT ON FUNCTION cron_process_pending_vods IS 'Wrapper function for pg_cron to process pending VODs';