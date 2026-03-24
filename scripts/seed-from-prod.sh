#!/bin/bash

# Pull a meaningful subset of production data into supabase/seed.sql
# Usage: PROD_DB_PASSWORD=xxx ./scripts/seed-from-prod.sh

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ -z "${PROD_DB_PASSWORD:-}" ]; then
    echo -e "${RED}Error: PROD_DB_PASSWORD environment variable is not set${NC}"
    echo "Usage: PROD_DB_PASSWORD=xxx $0"
    exit 1
fi

PROD_DB_URL="postgresql://postgres.dzklnkhayqmwldnjxywr:${PROD_DB_PASSWORD}@aws-1-us-east-2.pooler.supabase.com:6543/postgres"
SEED_FILE="supabase/seed.sql"

echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}     Seed from Production (top streamers + recent data)${NC}"
echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
echo

echo -e "${BLUE}Querying production for top 10 streamers by detection count...${NC}"

# Single SQL query that generates the entire seed file via CTEs + format()
# %L handles NULL correctly (outputs unquoted NULL) and quotes strings safely
GENERATED_SQL=$(psql "$PROD_DB_URL" --no-align --tuples-only --quiet -c "
WITH top_streamers AS (
    SELECT v.streamer_id, COUNT(d.id) AS det_count
    FROM detections d
    JOIN vods v ON d.vod_id = v.id
    GROUP BY v.streamer_id
    ORDER BY det_count DESC
    LIMIT 100
),
selected_vods AS (
    SELECT v.id AS vod_id, v.streamer_id
    FROM vods v
    JOIN top_streamers ts ON v.streamer_id = ts.streamer_id
    WHERE v.id IN (
        SELECT v2.id
        FROM vods v2
        WHERE v2.streamer_id = v.streamer_id
        ORDER BY v2.published_at DESC NULLS LAST
        LIMIT 10
    )
),
referenced_profiles AS (
    SELECT DISTINCT s.sfot_profile_id
    FROM streamers s
    JOIN top_streamers ts ON s.id = ts.streamer_id
),
-- Generate INSERT rows using format() + %L for safe quoting (handles NULLs, special chars)
profile_rows AS (
    SELECT format(
        '(%s, %L, %L, %s, %L, %s, %L, %L, %L, %L)',
        p.id,
        p.profile_name,
        p.crop_region::text,
        p.scale,
        p.custom_edge,
        p.opaque_edge::text,
        p.from_date,
        p.to_date,
        p.created_at,
        p.updated_at
    ) AS row_text,
    p.id AS sort_key
    FROM sfot_profiles p
    JOIN referenced_profiles rp ON p.id = rp.sfot_profile_id
),
streamer_rows AS (
    SELECT format(
        '(%s, %L, %L, %L, %s, %s, %L, %s, %s, %s, %L, %L)',
        s.id,
        s.login,
        s.display_name,
        s.profile_image_url,
        s.processing_enabled::text,
        s.has_vods::text,
        s.oldest_vod,
        s.num_vods,
        s.num_bazaar_vods,
        s.sfot_profile_id,
        s.created_at,
        s.updated_at
    ) AS row_text,
    s.id AS sort_key
    FROM streamers s
    JOIN top_streamers ts ON s.id = ts.streamer_id
),
vod_rows AS (
    SELECT format(
        '(%s, %s, %L, %L, %L, %L, %L, %L, %L, %s, %L, %L, %L, %L)',
        v.id,
        v.streamer_id,
        v.source,
        v.source_id,
        v.title,
        v.duration_seconds,
        v.published_at,
        v.availability::text,
        v.last_availability_check,
        'false',
        v.bazaar_chapters::text,
        v.status::text,
        v.created_at,
        v.updated_at
    ) AS row_text,
    v.id AS sort_key
    FROM vods v
    JOIN selected_vods sv ON v.id = sv.vod_id
),
chunk_rows AS (
    SELECT format(
        '(%L, %s, %s, %s, %s, %L, %L, %L, %L, %L, %L, %s, %s, %s, %s, %L, %L)',
        c.id,
        c.vod_id,
        c.start_seconds,
        c.end_seconds,
        c.chunk_index,
        c.status::text,
        c.source::text,
        c.quality,
        c.queued_at,
        c.started_at,
        c.completed_at,
        c.attempt_count,
        c.frames_processed,
        c.detections_count,
        c.priority,
        c.created_at,
        c.updated_at
    ) AS row_text,
    c.vod_id AS sort_key1,
    c.chunk_index AS sort_key2
    FROM chunks c
    JOIN selected_vods sv ON c.vod_id = sv.vod_id
),
detection_rows AS (
    SELECT format(
        '(%L, %L, %s, %L, %L, %L, %s, %L, %s, %s, %L)',
        d.id,
        d.chunk_id,
        d.vod_id,
        d.username,
        d.confidence,
        d.rank,
        d.frame_time_seconds,
        d.storage_path,
        d.no_right_edge::text,
        d.truncated::text,
        d.created_at
    ) AS row_text,
    d.vod_id AS sort_key1,
    d.frame_time_seconds AS sort_key2
    FROM detections d
    JOIN selected_vods sv ON d.vod_id = sv.vod_id
),
counts AS (
    SELECT
        (SELECT count(*) FROM top_streamers) AS streamer_count,
        (SELECT count(*) FROM selected_vods) AS vod_count,
        (SELECT count(*) FROM chunk_rows) AS chunk_count,
        (SELECT count(*) FROM detection_rows) AS detection_count
)
SELECT
    '-- ============================================================' || E'\n' ||
    '-- Seed data from production (top streamers by detection count)' || E'\n' ||
    '-- Generated at: ' || now()::text || E'\n' ||
    '-- Streamers: ' || c.streamer_count || ', VODs: ' || c.vod_count ||
    ', Chunks: ' || c.chunk_count || ', Detections: ' || c.detection_count || E'\n' ||
    '-- ============================================================' || E'\n' ||
    E'\n' ||
    '-- Clear existing data' || E'\n' ||
    'TRUNCATE TABLE public.detections CASCADE;' || E'\n' ||
    'TRUNCATE TABLE public.chunks CASCADE;' || E'\n' ||
    'TRUNCATE TABLE public.vods CASCADE;' || E'\n' ||
    'TRUNCATE TABLE public.streamers CASCADE;' || E'\n' ||
    'TRUNCATE TABLE public.sfot_profiles CASCADE;' || E'\n' ||
    E'\n' ||
    '-- Disable triggers during seed to prevent chunk auto-creation and status recalc' || E'\n' ||
    'SET session_replication_role = replica;' || E'\n' ||
    E'\n' ||
    '-- SFOT Profiles' || E'\n' ||
    'INSERT INTO public.sfot_profiles (id, profile_name, crop_region, scale, custom_edge, opaque_edge, from_date, to_date, created_at, updated_at) OVERRIDING SYSTEM VALUE VALUES' || E'\n' ||
    (SELECT string_agg(row_text, E',\n' ORDER BY sort_key) FROM profile_rows) || ';' || E'\n' ||
    E'\n' ||
    '-- Streamers (processing_enabled preserved from prod)' || E'\n' ||
    'INSERT INTO public.streamers (id, login, display_name, profile_image_url, processing_enabled, has_vods, oldest_vod, num_vods, num_bazaar_vods, sfot_profile_id, created_at, updated_at) VALUES' || E'\n' ||
    (SELECT string_agg(row_text, E',\n' ORDER BY sort_key) FROM streamer_rows) || ';' || E'\n' ||
    E'\n' ||
    '-- VODs (ready_for_processing=false to prevent chunk auto-creation trigger)' || E'\n' ||
    'INSERT INTO public.vods (id, streamer_id, source, source_id, title, duration_seconds, published_at, availability, last_availability_check, ready_for_processing, bazaar_chapters, status, created_at, updated_at) OVERRIDING SYSTEM VALUE VALUES' || E'\n' ||
    (SELECT string_agg(row_text, E',\n' ORDER BY sort_key) FROM vod_rows) || ';' || E'\n' ||
    E'\n' ||
    '-- Chunks (inserted explicitly with prod statuses)' || E'\n' ||
    'INSERT INTO public.chunks (id, vod_id, start_seconds, end_seconds, chunk_index, status, source, quality, queued_at, started_at, completed_at, attempt_count, frames_processed, detections_count, priority, created_at, updated_at) VALUES' || E'\n' ||
    (SELECT string_agg(row_text, E',\n' ORDER BY sort_key1, sort_key2) FROM chunk_rows) || ';' || E'\n' ||
    E'\n' ||
    '-- Detections' || E'\n' ||
    'INSERT INTO public.detections (id, chunk_id, vod_id, username, confidence, rank, frame_time_seconds, storage_path, no_right_edge, truncated, created_at) VALUES' || E'\n' ||
    (SELECT string_agg(row_text, E',\n' ORDER BY sort_key1, sort_key2) FROM detection_rows) || ';' || E'\n' ||
    E'\n' ||
    '-- Re-enable triggers' || E'\n' ||
    'SET session_replication_role = DEFAULT;' || E'\n' ||
    E'\n' ||
    '-- Reset sequences' || E'\n' ||
    'SELECT setval(''public.vods_id_seq'', (SELECT COALESCE(MAX(id), 1) FROM public.vods), true);' || E'\n' ||
    'SELECT setval(''public.sfot_profiles_id_seq'', (SELECT COALESCE(MAX(id), 1) FROM public.sfot_profiles), true);'
FROM counts c;
")

# Read the existing test schema seed block from current seed.sql
TEST_BLOCK=$(sed -n '/^-- Seed test schema/,$ p' "$SEED_FILE")

# Write the generated SQL + test block
{
    echo "$GENERATED_SQL"
    echo ""
    echo "$TEST_BLOCK"
} > "$SEED_FILE"

echo -e "${GREEN}Wrote ${SEED_FILE}${NC}"
echo

# Print summary from the header comment
echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
grep '^-- Streamers:' "$SEED_FILE" | sed 's/^-- /  /'
echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
echo
echo -e "${BLUE}Next steps:${NC}"
echo "  supabase db reset    # Apply migrations + new seed"
echo -e "${GREEN}Done!${NC}"
