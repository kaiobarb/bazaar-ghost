-- Function to get all pending chunks for a VOD
-- Accepts either vod_id (bigint) or source_id (text)
-- Returns chunks that are not completed or currently processing

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
) AS $$
BEGIN
    -- Validate inputs - must provide either vod_id or source_id
    IF p_vod_id IS NULL AND p_source_id IS NULL THEN
        RAISE EXCEPTION 'Must provide either vod_id or source_id';
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
    INNER JOIN vods v ON c.vod_id = v.id
    WHERE
        -- Match by vod_id or source_id
        (p_vod_id IS NOT NULL AND c.vod_id = p_vod_id)
        OR
        (p_source_id IS NOT NULL AND v.source_id = p_source_id)

        -- Only return non-completed and non-processing chunks
        AND c.status NOT IN ('completed', 'processing')
    ORDER BY c.chunk_index ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Grant execute permission to authenticated users
GRANT EXECUTE ON FUNCTION get_pending_chunks_for_vod TO authenticated;
GRANT EXECUTE ON FUNCTION get_pending_chunks_for_vod TO service_role;