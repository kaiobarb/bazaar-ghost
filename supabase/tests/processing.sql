BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions;
SELECT plan(23);
INSERT INTO sfde_profiles(id, profile_name, crop_region)
OVERRIDING SYSTEM VALUE VALUES (900001, 'cleanup-test', ARRAY[0.5,0.5,0.4,0.2]);
INSERT INTO streamers(id, login, processing_enabled, sfde_profile_id)
VALUES (900001, 'cleanup_test', true, 900001);
INSERT INTO vods(id, streamer_id, source_id, duration_seconds, bazaar_chapters, ready_for_processing)
OVERRIDING SYSTEM VALUE VALUES (900001, 900001, '900001', 3701, ARRAY[0,3701], true);

SELECT is((SELECT count(*)::integer FROM chunks WHERE vod_id=900001), 3, '3701 seconds produce three bounded chunks');
SELECT is((SELECT max(end_seconds-start_seconds) FROM chunks WHERE vod_id=900001), 1800, 'chunk duration never exceeds target');
SELECT is((SELECT sum(end_seconds-start_seconds)::integer FROM chunks WHERE vod_id=900001), 3701, 'short tail is preserved');
SELECT is(create_missing_chunks_for_vod(900001), 0, 'replanning is idempotent');
SELECT ok(claim_sfde_chunk((SELECT id FROM chunks WHERE vod_id=900001 AND chunk_index=0)), 'first worker claims chunk');
SELECT ok(NOT claim_sfde_chunk((SELECT id FROM chunks WHERE vod_id=900001 AND chunk_index=0)), 'second worker cannot claim same chunk');
SELECT is((SELECT attempt_count FROM chunks WHERE vod_id=900001 AND chunk_index=0), 1, 'attempt count increments on claim');
UPDATE chunks SET status='completed' WHERE vod_id=900001 AND chunk_index=0;
UPDATE chunks SET status='failed' WHERE vod_id=900001 AND chunk_index=1;
SELECT is((SELECT status::text FROM chunks WHERE vod_id=900001 AND chunk_index=0), 'completed', 'failed sibling preserves completed work');
SELECT is((SELECT status::text FROM vods WHERE id=900001), 'partial', 'VOD aggregate reflects partial processing');
SELECT ok(NOT has_function_privilege('anon', 'public.claim_sfde_chunk(uuid)', 'EXECUTE'), 'anonymous users cannot claim');
SELECT ok(NOT has_function_privilege('anon', 'public.force_process_vod(bigint,text,integer,integer)', 'EXECUTE'), 'anonymous users cannot trigger processing');
SELECT ok(NOT has_table_privilege('anon', 'public.sfde_profiles', 'UPDATE'), 'anonymous users cannot alter processing profiles');
SELECT ok(has_table_privilege('anon', 'public.detections', 'SELECT'), 'public detection reads remain available');
INSERT INTO vods(id, streamer_id, source_id, duration_seconds, bazaar_chapters, ready_for_processing)
OVERRIDING SYSTEM VALUE VALUES (900002, 900001, '900002', 1000, ARRAY[0,20,500,510], true);
SELECT is((SELECT sum(end_seconds-start_seconds)::integer FROM chunks WHERE vod_id=900002), 30, 'short Bazaar chapters are covered without other games');
UPDATE chunks SET lease_expires_at=NOW()-INTERVAL '1 minute', status='processing' WHERE vod_id=900001 AND chunk_index=2;
SELECT is(recover_expired_chunks(), 1, 'expired worker is recovered');
SELECT ok(claim_sfde_chunk((SELECT id FROM chunks WHERE vod_id=900001 AND chunk_index=2)), 'expired chunk can be retried');
SELECT is(recover_expired_chunks(), 0, 'live lease is preserved');
SELECT throws_ok('SELECT force_process_vod(900001)', 'P0001', 'Cannot reset a VOD with active workers', 'force cannot steal running work');
UPDATE streamers SET processing_enabled=false WHERE id=900001;
SELECT is((SELECT count(*)::integer FROM chunks WHERE vod_id=900001), 3, 'disable preserves chunk identities');
SELECT ok(NOT claim_sfde_chunk((SELECT id FROM chunks WHERE vod_id=900002 LIMIT 1)), 'disabled streamer cannot start work');
UPDATE streamers SET processing_enabled=true WHERE id=900001;
DELETE FROM chunks WHERE vod_id=900002;
SELECT is((SELECT sum(proposed_duration)::integer FROM simulate_chunk_plan_for_vod(900002)), 30, 'preview covers exactly the missing Bazaar ranges');
SELECT is(create_missing_chunks_for_vod(900002), 2, 'insertion matches preview');
INSERT INTO vods(id, streamer_id, source_id, duration_seconds, bazaar_chapters, ready_for_processing)
OVERRIDING SYSTEM VALUE VALUES (900004, 900001, '900004', 1000, ARRAY[]::integer[], true);
SELECT is((SELECT count(*)::integer FROM chunks WHERE vod_id=900004), 0, 'no Bazaar chapters means no work');
SELECT * FROM finish();
ROLLBACK;
