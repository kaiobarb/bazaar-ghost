-- Create test schema for testing SFOT with different configurations
CREATE SCHEMA IF NOT EXISTS test;

-- Grant usage on test schema to necessary roles
GRANT USAGE ON SCHEMA test TO postgres, anon, authenticated, service_role;

-- Mirror public schema tables to test schema
-- This creates identical table structures without the data

-- Mirror cataloger_runs table
CREATE TABLE test.cataloger_runs (LIKE public.cataloger_runs INCLUDING ALL);

-- Mirror streamers table
CREATE TABLE test.streamers (LIKE public.streamers INCLUDING ALL);

-- Mirror vods table
CREATE TABLE test.vods (LIKE public.vods INCLUDING ALL);

-- Mirror chunks table
CREATE TABLE test.chunks (LIKE public.chunks INCLUDING ALL);

-- Mirror detections table
CREATE TABLE test.detections (LIKE public.detections INCLUDING ALL);

-- Mirror sfot_profiles table
CREATE TABLE test.sfot_profiles (LIKE public.sfot_profiles INCLUDING ALL);

-- Re-create foreign key constraints to reference test schema tables
ALTER TABLE test.vods
    ADD CONSTRAINT test_vods_streamer_id_fkey
    FOREIGN KEY (streamer_id) REFERENCES test.streamers(id);

ALTER TABLE test.chunks
    ADD CONSTRAINT test_chunks_vod_id_fkey
    FOREIGN KEY (vod_id) REFERENCES test.vods(id);

ALTER TABLE test.detections
    ADD CONSTRAINT test_detections_chunk_id_fkey
    FOREIGN KEY (chunk_id) REFERENCES test.chunks(id);

ALTER TABLE test.detections
    ADD CONSTRAINT test_detections_vod_id_fkey
    FOREIGN KEY (vod_id) REFERENCES test.vods(id);

ALTER TABLE test.cataloger_runs
    ADD CONSTRAINT test_cataloger_runs_run_type_check
    CHECK (run_type = ANY (ARRAY['refresh'::text, 'backfill'::text]));

-- Grant permissions on test schema tables
GRANT ALL ON ALL TABLES IN SCHEMA test TO postgres;
GRANT ALL ON ALL TABLES IN SCHEMA test TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA test TO anon, authenticated;

-- Grant permissions on sequences in test schema
GRANT ALL ON ALL SEQUENCES IN SCHEMA test TO postgres;
GRANT ALL ON ALL SEQUENCES IN SCHEMA test TO service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA test TO anon, authenticated;

-- Add comment to describe the test schema
COMMENT ON SCHEMA test IS 'Test schema for SFOT testing with different configurations and resolutions';