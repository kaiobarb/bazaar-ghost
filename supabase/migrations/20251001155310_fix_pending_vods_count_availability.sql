-- Fix get_pending_vods_count to exclude unavailable VODs
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
            -- Has chunks that are not completed, processing, or failed
            AND c.status NOT IN ('completed', 'processing', 'failed')
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
GRANT EXECUTE ON FUNCTION get_pending_vods_count TO postgres;
GRANT EXECUTE ON FUNCTION get_pending_vods_count TO service_role;
GRANT EXECUTE ON FUNCTION get_pending_vods_count TO authenticated;

-- Update comment
COMMENT ON FUNCTION get_pending_vods_count IS 'Returns statistics about available VODs with pending/queued chunks (excluding failed and unavailable VODs)';