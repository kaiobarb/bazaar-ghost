-- Generated seed data from latest Bazaar VODs
-- Generated at: 2025-10-12T07:07:30.066Z

-- Clear existing data
TRUNCATE TABLE public.detections CASCADE;
TRUNCATE TABLE public.chunks CASCADE;
TRUNCATE TABLE public.vods CASCADE;
TRUNCATE TABLE public.streamers CASCADE;

-- Streamers
INSERT INTO public.streamers (id, login, display_name, profile_image_url, processing_enabled, has_vods, oldest_vod, num_vods, num_bazaar_vods, created_at, updated_at) VALUES
(1364977185, 'melodystarsky', 'MelodyStarSky', 'https://static-cdn.jtvnw.net/jtv_user_pictures/2ffeae73-f7d4-4532-b92f-680c22093890-profile_image-300x300.jpeg', true, true, NULL, 0, 0, '2025-10-12T07:07:30.066Z', '2025-10-12T07:07:30.066Z'),
(63559337, 'ragelf', 'Ragelf', 'https://static-cdn.jtvnw.net/jtv_user_pictures/ragelf-profile_image-3b48e9bc5b24d8d0-300x300.jpeg', true, true, NULL, 0, 0, '2025-10-12T07:07:30.066Z', '2025-10-12T07:07:30.066Z'),
(19198298, 'mikevalentine', 'mikevalentine', 'https://static-cdn.jtvnw.net/jtv_user_pictures/d4555d6089c1817f-profile_image-300x300.png', true, true, NULL, 0, 0, '2025-10-12T07:07:30.066Z', '2025-10-12T07:07:30.066Z'),
(52486901, 'patman737', 'Patman737', 'https://static-cdn.jtvnw.net/jtv_user_pictures/a9933275-2ac0-4a2b-92fa-6985ad6a2fc8-profile_image-300x300.png', true, true, NULL, 0, 0, '2025-10-12T07:07:30.066Z', '2025-10-12T07:07:30.066Z'),
(51479482, 'patchdoll', 'Patchdoll', 'https://static-cdn.jtvnw.net/jtv_user_pictures/edfa57b0-1628-4685-9e25-2e16f3fc9b7c-profile_image-300x300.png', true, true, NULL, 0, 0, '2025-10-12T07:07:30.066Z', '2025-10-12T07:07:30.066Z'),
(1251663536, '2sixten', '2Sixten', 'https://static-cdn.jtvnw.net/jtv_user_pictures/ab28d4e2-c5ec-4eb4-9dbc-021d5d9f1731-profile_image-300x300.png', true, true, NULL, 0, 0, '2025-10-12T07:07:30.066Z', '2025-10-12T07:07:30.066Z'),
(1030629434, 'destinydecktarot', 'destinydecktarot', 'https://static-cdn.jtvnw.net/jtv_user_pictures/2cdbe4ac-819a-40b5-92e5-f0be2d5071db-profile_image-300x300.jpeg', true, true, NULL, 0, 0, '2025-10-12T07:07:30.066Z', '2025-10-12T07:07:30.066Z');

-- VODs
INSERT INTO public.vods (streamer_id, source, source_id, title, duration_seconds, published_at, availability, last_availability_check, ready_for_processing, created_at, updated_at) VALUES
(1364977185, 'twitch', '2589729606', 'Стрим The Bazaar. Базарим на разные темы 2', 1463, '2025-10-12T06:43:07Z', 'available', '2025-10-12T07:07:30.066Z', true, '2025-10-12T07:07:30.066Z', '2025-10-12T07:07:30.066Z'),
(1364977185, 'twitch', '2589729033', 'Стрим The Bazaar. Базарим на разные темы 2', 25, '2025-10-12T06:41:31Z', 'available', '2025-10-12T07:07:30.066Z', true, '2025-10-12T07:07:30.066Z', '2025-10-12T07:07:30.066Z'),
(63559337, 'twitch', '2589716680', 'shitty bazaar', 53, '2025-10-12T06:10:31Z', 'available', '2025-10-12T07:07:30.066Z', true, '2025-10-12T07:07:30.066Z', '2025-10-12T07:07:30.066Z'),
(19198298, 'twitch', '2589713231', 'Потыкаем пятиметровой палкой', 3921, '2025-10-12T06:02:09Z', 'available', '2025-10-12T07:07:30.066Z', true, '2025-10-12T07:07:30.066Z', '2025-10-12T07:07:30.066Z'),
(52486901, 'twitch', '2589694255', '💥 Climbing the Bazaar Ranks! Intense Matches & Big Brain Plays 💎', 6433, '2025-10-12T05:20:17Z', 'available', '2025-10-12T07:07:30.066Z', true, '2025-10-12T07:07:30.066Z', '2025-10-12T07:07:30.066Z'),
(52486901, 'twitch', '2589685110', '💥 Climbing the Bazaar Ranks! Intense Matches & Big Brain Plays 💎', 175, '2025-10-12T05:02:12Z', 'available', '2025-10-12T07:07:30.066Z', true, '2025-10-12T07:07:30.066Z', '2025-10-12T07:07:30.066Z'),
(52486901, 'twitch', '2589673313', '💥 Climbing the Bazaar Ranks! Intense Matches & Big Brain Plays 💎', 860, '2025-10-12T04:39:14Z', 'available', '2025-10-12T07:07:30.066Z', true, '2025-10-12T07:07:30.066Z', '2025-10-12T07:07:30.066Z'),
(51479482, 'twitch', '2589669964', 'new patch late night gameing', 9290, '2025-10-12T04:32:40Z', 'available', '2025-10-12T07:07:30.066Z', true, '2025-10-12T07:07:30.066Z', '2025-10-12T07:07:30.066Z'),
(1251663536, 'twitch', '2589664440', '[Top 2 Peak] Winstreaking on Vanessa !Guide', 9886, '2025-10-12T04:22:44Z', 'available', '2025-10-12T07:07:30.066Z', true, '2025-10-12T07:07:30.066Z', '2025-10-12T07:07:30.066Z'),
(1030629434, 'twitch', '2589656829', 'Wind Down With Me!', 5230, '2025-10-12T04:09:30Z', 'available', '2025-10-12T07:07:30.066Z', true, '2025-10-12T07:07:30.066Z', '2025-10-12T07:07:30.066Z');

-- Update sequences
SELECT setval('public.vods_id_seq', (SELECT MAX(id) FROM public.vods), true);

-- Note: Chunks are automatically created by the trigger_auto_create_chunks trigger
-- when VODs are inserted with ready_for_processing=true and streamer has processing_enabled=true

-- Seed test schema (if it exists)
DO $$
DECLARE
  test_vod_id bigint;
  test_chunk_id uuid;
BEGIN
  -- Only seed if test schema exists
  IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'test') THEN
    -- Clear test data first
    TRUNCATE TABLE test.detections CASCADE;
    TRUNCATE TABLE test.chunks CASCADE;
    TRUNCATE TABLE test.vods CASCADE;
    TRUNCATE TABLE test.streamers CASCADE;

    -- Insert Kripp as test streamer
    INSERT INTO test.streamers (
      id, login, display_name, profile_image_url, processing_enabled,
      has_vods, oldest_vod, num_vods, num_bazaar_vods,
      created_at, updated_at
    ) VALUES (
      29795919,
      'nl_kripp',
      'nl_Kripp',
      'https://static-cdn.jtvnw.net/jtv_user_pictures/401068e0-820a-4d9f-9e7c-1e5563398458-profile_image-300x300.png',
      true,
      true, NULL, 0, 0,
      '2025-09-23 07:09:54.440199+00',
      '2025-09-23 07:09:54.440199+00'
    );

    -- Insert test VOD (duration: 1h47m = 6420 seconds)
    INSERT INTO test.vods (
      streamer_id, source, source_id, title, duration_seconds,
      published_at, availability, last_availability_check,
      ready_for_processing, created_at, updated_at
    ) VALUES (
      29795919,  -- Kripp's ID
      'twitch',
      '2549030240',
      'Test VOD - The Bazaar Multiple Qualities',
      6420,  -- 1h47m
      '2025-10-12 00:00:00+00',
      'available',
      NOW(),
      true,
      NOW(),
      NOW()
    );

    -- Get the VOD ID we just inserted
    SELECT id INTO test_vod_id FROM test.vods WHERE source_id = '2549030240' LIMIT 1;

    -- Create a single chunk for testing (first hour / 3200 seconds)
    INSERT INTO test.chunks (
      id, vod_id, start_seconds, end_seconds, chunk_index,
      status, source, frames_processed, detections_count,
      priority, scheduled_for, created_at, updated_at
    ) VALUES (
      gen_random_uuid(),
      test_vod_id,
      0,
      3200,  -- First one hour chunk
      0,
      'pending',
      'vod',
      0,
      0,
      0,
      NOW(),
      NOW(),
      NOW()
    );

    -- Update sequences for test schema
    PERFORM setval('test.vods_id_seq', (SELECT MAX(id) FROM test.vods), true);

    RAISE NOTICE 'Test schema seeded: Kripp streamer, VOD 2549030240, and chunk created';
  END IF;
END $$;
