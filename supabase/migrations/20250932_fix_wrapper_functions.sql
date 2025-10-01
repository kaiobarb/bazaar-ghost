-- Fix wrapper functions to match the corrected process_pending_vods return type
-- Drop existing wrapper functions
DROP FUNCTION IF EXISTS manual_process_pending_vods(INT);
DROP FUNCTION IF EXISTS cron_process_pending_vods();

-- Recreate manual trigger function with correct return type
CREATE OR REPLACE FUNCTION manual_process_pending_vods(max_vods INT DEFAULT 10)
RETURNS TABLE (
    vod_id UUID,  -- Changed from BIGINT to UUID
    source_id TEXT,
    pending_chunks BIGINT,  -- Changed from INT to BIGINT
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

-- Update comments
COMMENT ON FUNCTION manual_process_pending_vods IS 'Manual trigger for testing VOD processing scheduling';
COMMENT ON FUNCTION cron_process_pending_vods IS 'Wrapper function for pg_cron to process pending VODs';