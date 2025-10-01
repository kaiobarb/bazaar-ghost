-- Update all functions to only process chunks with 'pending' status
-- This prevents double-processing of chunks that have been queued for GitHub

-- 1. Update get_pending_chunks_for_vod to only return 'pending' chunks
DROP FUNCTION IF EXISTS get_pending_chunks_for_vod(BIGINT, TEXT);

CREATE OR REPLACE FUNCTION get_pending_chunks_for_vod(
    p_vod_id BIGINT DEFAULT NULL,
    p_source_id TEXT DEFAULT NULL
)
RETURNS TABLE (
    chunk_id UUID,
    vod_id BIGINT,
    source_id TEXT,
    chunk_index INT,
    start_seconds INT,
    end_seconds INT,
    status processing_status,
    attempt_count INT
)
LANGUAGE plpgsql
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

-- 2. Update process_pending_vods to only count 'pending' chunks
DROP FUNCTION IF EXISTS process_pending_vods(INTEGER);

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

-- 3. Update get_pending_vods_count to only count 'pending' chunks
DROP FUNCTION IF EXISTS get_pending_vods_count();

CREATE OR REPLACE FUNCTION get_pending_vods_count()
RETURNS TABLE (
    total_vods BIGINT,
    total_pending_chunks BIGINT,
    ready_vods BIGINT
)
LANGUAGE sql
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

-- Grant necessary permissions
GRANT EXECUTE ON FUNCTION get_pending_chunks_for_vod TO postgres;
GRANT EXECUTE ON FUNCTION get_pending_chunks_for_vod TO service_role;
GRANT EXECUTE ON FUNCTION process_pending_vods TO postgres;
GRANT EXECUTE ON FUNCTION process_pending_vods TO service_role;
GRANT EXECUTE ON FUNCTION get_pending_vods_count TO postgres;
GRANT EXECUTE ON FUNCTION get_pending_vods_count TO service_role;
GRANT EXECUTE ON FUNCTION get_pending_vods_count TO authenticated;

-- Update comments
COMMENT ON FUNCTION get_pending_chunks_for_vod IS 'Gets only pending chunks for a VOD (excluding queued, processing, completed, failed)';
COMMENT ON FUNCTION process_pending_vods IS 'Selects up to N VODs with pending chunks and triggers processing via edge function';
COMMENT ON FUNCTION get_pending_vods_count IS 'Returns statistics about available VODs with pending chunks only';