-- Add vod_source_id_filter parameter to fuzzy_search_detections
-- Allows filtering ghost search results to a specific VOD (by Twitch source_id)

-- Must drop first because we're changing the parameter list
DROP FUNCTION IF EXISTS "public"."fuzzy_search_detections";

CREATE OR REPLACE FUNCTION "public"."fuzzy_search_detections"(
    "search_query" "text" DEFAULT NULL::"text",
    "streamer_id_filter" bigint DEFAULT NULL::bigint,
    "vod_source_id_filter" "text" DEFAULT NULL::"text",
    "date_range_filter" "text" DEFAULT 'all'::"text",
    "similarity_threshold" double precision DEFAULT 0.2,
    "result_limit" integer DEFAULT 100,
    "result_offset" integer DEFAULT 0
) RETURNS TABLE(
    "detection_id" "uuid",
    "username" "text",
    "streamer_id" bigint,
    "streamer_login" "text",
    "streamer_display_name" "text",
    "streamer_avatar" "text",
    "frame_time_seconds" integer,
    "confidence" double precision,
    "rank" "text",
    "vod_id" bigint,
    "vod_source_id" "text",
    "vod_url" "text",
    "actual_timestamp" timestamp with time zone,
    "similarity_score" real,
    "total_count" bigint,
    "truncated" boolean
)
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
            ds.truncated,
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
            -- VOD filter (by Twitch source_id)
            AND (
                vod_source_id_filter IS NULL
                OR ds.vod_source_id = vod_source_id_filter
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
            fr.*,
            COUNT(*) OVER() as total_count
        FROM filtered_results fr
    )
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
        counted_results.total_count::bigint,
        counted_results.truncated
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
