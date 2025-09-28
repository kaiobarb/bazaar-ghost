-- Create function to update chunk status with appropriate field updates
CREATE OR REPLACE FUNCTION update_chunk_status(
    p_chunk_id UUID,
    p_status TEXT,
    p_error_message TEXT DEFAULT NULL
)
RETURNS JSON AS $$
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
$$ LANGUAGE plpgsql SECURITY DEFINER;