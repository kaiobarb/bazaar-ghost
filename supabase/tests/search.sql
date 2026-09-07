BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions;
SELECT plan(5);

INSERT INTO sfde_profiles(id, profile_name, crop_region)
OVERRIDING SYSTEM VALUE VALUES (910001, 'search-test', ARRAY[0.5,0.5,0.4,0.2]);
INSERT INTO streamers(id, login, processing_enabled, sfde_profile_id)
VALUES (910001, 'search_test', true, 910001);
INSERT INTO vods(id, streamer_id, source_id, duration_seconds, bazaar_chapters, ready_for_processing, availability)
OVERRIDING SYSTEM VALUE VALUES
  (910001, 910001, 'search-first', 60, ARRAY[0,60], true, 'available'),
  (910002, 910001, 'search-second', 60, ARRAY[0,60], true, 'available'),
  (910003, 910001, 'search-expired', 60, ARRAY[0,60], true, 'available');
INSERT INTO detections(chunk_id, vod_id, username, confidence, rank, frame_time_seconds)
SELECT id, vod_id, 'SearchContractFixture', 0.99, 'gold', 10
FROM chunks WHERE vod_id IN (910001, 910002, 910003);
UPDATE vods SET availability = 'expired' WHERE id = 910003;

SET LOCAL ROLE anon;
SELECT is((SELECT count(*)::integer FROM fuzzy_search_detections(
  search_query => 'SearchContractFixture', streamer_id_filter => 910001
)), 2, 'anonymous username search works without the optional VOD filter');
SELECT is((SELECT count(*)::integer FROM fuzzy_search_detections(
  search_query => 'SearchContractFixture', vod_source_id_filter => 'search-first'
)), 1, 'VOD filter returns exactly the selected archive');
SELECT is((SELECT vod_source_id FROM fuzzy_search_detections(
  search_query => 'SearchContractFixture', vod_source_id_filter => 'search-first'
)), 'search-first', 'VOD filter excludes matching opponents in other archives');
SELECT is((SELECT count(*)::integer FROM fuzzy_search_detections(
  search_query => 'SearchContractFixture', vod_source_id_filter => 'search-expired'
)), 0, 'unavailable source VODs remain hidden');
SELECT is((SELECT total_count FROM fuzzy_search_detections(
  search_query => 'SearchContractFixture', streamer_id_filter => 910001, result_limit => 1
)), 2::bigint, 'pagination reports the complete filtered count');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
