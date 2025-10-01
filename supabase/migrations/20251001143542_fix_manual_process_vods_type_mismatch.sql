-- Fix type mismatch in manual_process_pending_vods
DROP FUNCTION IF EXISTS manual_process_pending_vods(INT);

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

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION manual_process_pending_vods TO postgres;
GRANT EXECUTE ON FUNCTION manual_process_pending_vods TO service_role;

-- Update comment
COMMENT ON FUNCTION manual_process_pending_vods IS 'Manual trigger for testing VOD processing scheduling';