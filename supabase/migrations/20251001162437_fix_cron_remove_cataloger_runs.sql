-- Fix cron_process_pending_vods to remove cataloger_runs references
DROP FUNCTION IF EXISTS cron_process_pending_vods();

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
GRANT EXECUTE ON FUNCTION cron_process_pending_vods TO postgres;
GRANT EXECUTE ON FUNCTION cron_process_pending_vods TO service_role;

-- Update comment
COMMENT ON FUNCTION cron_process_pending_vods IS 'Wrapper function for pg_cron to process pending VODs';