-- Generate data-only SQL against the current schema. Empty tables produce no INSERT.
BEGIN READ ONLY;
SELECT '-- Catalog snapshot; processing is disabled. Storage objects are not copied.';
SELECT 'BEGIN; SET LOCAL session_replication_role = replica;';
SELECT 'TRUNCATE public.detections, public.chunks, public.vods, public.streamers, public.sfde_profiles CASCADE;';
WITH selected_streamers AS (
  SELECT s.* FROM public.streamers s
  ORDER BY s.num_bazaar_vods DESC NULLS LAST, s.id LIMIT 100
), selected_vods AS (
  SELECT v.* FROM selected_streamers s CROSS JOIN LATERAL (
    SELECT * FROM public.vods WHERE streamer_id=s.id ORDER BY published_at DESC NULLS LAST, id LIMIT 10
  ) v
), records AS (
  SELECT 1 AS ordering, 'sfde_profiles' AS table_name, to_jsonb(p) AS row_data
  FROM public.sfde_profiles p WHERE p.id=1 OR p.id IN (SELECT sfde_profile_id FROM selected_streamers)
  UNION ALL SELECT 2, 'streamers', to_jsonb(s) || '{"processing_enabled":false,"eventsub_subscription_id":null}' FROM selected_streamers s
  UNION ALL SELECT 3, 'vods', to_jsonb(v) || '{"ready_for_processing":false}' FROM selected_vods v
  UNION ALL SELECT 4, 'chunks', to_jsonb(c) || '{"status":"pending","queued_at":null,"started_at":null,"completed_at":null,"lease_expires_at":null}'
    FROM public.chunks c JOIN selected_vods v ON v.id=c.vod_id
  UNION ALL SELECT 5, 'detections', to_jsonb(d) FROM public.detections d JOIN selected_vods v ON v.id=d.vod_id
), columns AS (
  SELECT c.relname, string_agg(format('%I', a.attname), ', ' ORDER BY a.attnum) AS names
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_attribute a ON a.attrelid=c.oid
  WHERE n.nspname='public' AND a.attnum>0 AND NOT a.attisdropped AND a.attgenerated=''
  GROUP BY c.relname
)
SELECT format('INSERT INTO public.%I (%s) OVERRIDING SYSTEM VALUE SELECT %s FROM jsonb_populate_record(NULL::public.%I, %L::jsonb);',
  r.table_name, c.names, c.names, r.table_name, r.row_data::text)
FROM records r JOIN columns c ON c.relname=r.table_name ORDER BY r.ordering, r.row_data->>'id';
SELECT format('SELECT setval(%L, GREATEST(COALESCE((SELECT MAX(id) FROM public.%I), 1), 1), true);',
  pg_get_serial_sequence('public.' || name, 'id'), name)
FROM (VALUES ('vods'), ('sfde_profiles')) AS tables(name);
SELECT 'COMMIT;';
COMMIT;
