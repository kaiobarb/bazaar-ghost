-- Add truncated field to detection_search view and related functions

-- Drop functions first (cannot change return type with CREATE OR REPLACE)
DROP FUNCTION IF EXISTS "public"."fuzzy_search_detections";
DROP FUNCTION IF EXISTS "public"."fuzzy_search_detections_debug";
DROP FUNCTION IF EXISTS "public"."fuzzy_search_detections_test";
DROP FUNCTION IF EXISTS "public"."get_top_streamers_with_recent_detections";

-- Drop views (need to recreate to add column in middle)
DROP VIEW IF EXISTS "public"."detection_search_debug";
DROP VIEW IF EXISTS "public"."detection_search";

-- 1. Recreate detection_search view with truncated
CREATE VIEW "public"."detection_search" WITH ("security_invoker"='on') AS
SELECT "d"."id" AS "detection_id",
    "d"."username",
    "d"."frame_time_seconds",
    "d"."confidence",
    "d"."rank",
    "d"."storage_path",
    "d"."no_right_edge",
    "d"."truncated",
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

-- 2. Update detection_search_debug view to include truncated
CREATE OR REPLACE VIEW "public"."detection_search_debug" WITH ("security_invoker"='on') AS
SELECT "d"."id" AS "detection_id",
    "d"."username",
    "d"."frame_time_seconds",
    "d"."confidence",
    "d"."rank",
    "d"."storage_path",
    "d"."no_right_edge",
    "d"."truncated",
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

-- 3. Update fuzzy_search_detections function to return truncated and total_count, with offset support
CREATE OR REPLACE FUNCTION "public"."fuzzy_search_detections"(
    "search_query" "text" DEFAULT NULL::"text",
    "streamer_id_filter" bigint DEFAULT NULL::bigint,
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

-- 4. Update fuzzy_search_detections_debug function to return truncated
CREATE OR REPLACE FUNCTION "public"."fuzzy_search_detections_debug"(
    "search_query" "text" DEFAULT NULL::"text",
    "streamer_id_filter" bigint DEFAULT NULL::bigint,
    "date_range_filter" "text" DEFAULT 'all'::"text",
    "similarity_threshold" double precision DEFAULT 0.2,
    "result_limit" integer DEFAULT 100
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
    "truncated" boolean
)
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
        END AS similarity_score,
        ds.truncated
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

-- 5. Update fuzzy_search_detections_test function to return truncated
CREATE OR REPLACE FUNCTION "public"."fuzzy_search_detections_test"(
    "search_query" "text" DEFAULT NULL::"text",
    "streamer_id_filter" bigint DEFAULT NULL::bigint,
    "date_range_filter" "text" DEFAULT 'all'::"text",
    "similarity_threshold" double precision DEFAULT 0.2,
    "result_limit" integer DEFAULT 100
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
    LIMIT result_limit;
END;
$$;

-- 6. Update get_top_streamers_with_recent_detections function to return truncated
CREATE OR REPLACE FUNCTION "public"."get_top_streamers_with_recent_detections"(
    "top_count" integer DEFAULT 10,
    "detections_per_streamer" integer DEFAULT 3
) RETURNS TABLE(
    "streamer_id" bigint,
    "streamer_login" "text",
    "streamer_display_name" "text",
    "streamer_avatar" "text",
    "total_detections" bigint,
    "total_vods" bigint,
    "detection_id" "uuid",
    "username" "text",
    "frame_time_seconds" integer,
    "confidence" double precision,
    "rank" "text",
    "vod_id" bigint,
    "vod_source_id" "text",
    "vod_url" "text",
    "actual_timestamp" timestamp with time zone,
    "detection_row_num" bigint,
    "truncated" boolean
)
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
      ds.truncated,
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
    rd.row_num AS detection_row_num,
    rd.truncated
  FROM recent_detections rd
  WHERE rd.row_num <= detections_per_streamer
  ORDER BY rd.detection_count DESC, rd.streamer_id, rd.row_num;
END;
$$;
