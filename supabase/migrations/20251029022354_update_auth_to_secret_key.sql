-- Store the secret key in vault (replace with your actual secret key for testing)
-- NOTE: In production, this should be done via the Supabase dashboard, not in a migration
INSERT INTO vault.secrets (name, secret)
VALUES ('secret_key', 'your_secret_key_here')
ON CONFLICT (name) DO UPDATE
SET secret = EXCLUDED.secret,
    updated_at = now();

-- Create wrapper functions for Edge Functions that use the new secret key

-- Wrapper for insert-new-streamers
CREATE OR REPLACE FUNCTION public.cron_insert_new_streamers_v2()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_response_id bigint;
  v_secret_key text;
  v_url text;
BEGIN
  -- Get the secret key from Vault
  SELECT decrypted_secret INTO v_secret_key
  FROM vault.decrypted_secrets
  WHERE name = 'secret_key';

  IF v_secret_key IS NULL THEN
    RAISE EXCEPTION 'No secret_key found in Vault';
  END IF;

  -- Construct the URL (use localhost for local testing)
  v_url := COALESCE(
    current_setting('app.settings.edge_function_url', true) || '/insert-new-streamers',
    'http://localhost:54321/functions/v1/insert-new-streamers'
  );

  -- Call the edge function with apikey header
  SELECT net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'apikey', v_secret_key,
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000
  ) INTO v_response_id;

  RAISE NOTICE 'Called insert-new-streamers edge function, response_id: %', v_response_id;
END;
$$;

-- Wrapper for check-vod-availability
CREATE OR REPLACE FUNCTION public.cron_check_vod_availability()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_response_id bigint;
  v_secret_key text;
  v_url text;
BEGIN
  -- Get the secret key from Vault
  SELECT decrypted_secret INTO v_secret_key
  FROM vault.decrypted_secrets
  WHERE name = 'secret_key';

  IF v_secret_key IS NULL THEN
    RAISE EXCEPTION 'No secret_key found in Vault';
  END IF;

  v_url := COALESCE(
    current_setting('app.settings.edge_function_url', true) || '/check_vod_availability',
    'http://localhost:54321/functions/v1/check_vod_availability'
  );

  SELECT net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'apikey', v_secret_key,
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  ) INTO v_response_id;

  RAISE NOTICE 'Called check_vod_availability edge function, response_id: %', v_response_id;
END;
$$;

-- Update the existing cron_update_streamer_vods to use secret_key if available
CREATE OR REPLACE FUNCTION public.cron_update_streamer_vods()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_streamer RECORD;
  v_response_id bigint;
  v_status_code integer;
  v_auth_key text;
  v_url text;
  v_updated_count integer := 0;
BEGIN
  -- Get the authentication key (prefer secret_key, fallback to service_role_key)
  SELECT decrypted_secret INTO v_auth_key
  FROM vault.decrypted_secrets
  WHERE name = 'secret_key'
  LIMIT 1;

  IF v_auth_key IS NULL THEN
    SELECT decrypted_secret INTO v_auth_key
    FROM vault.decrypted_secrets
    WHERE name = 'service_role_key'
    LIMIT 1;
  END IF;

  IF v_auth_key IS NULL THEN
    v_auth_key := current_setting('app.settings.anon_key', true);
  END IF;

  -- Base URL for edge functions (local for testing)
  v_url := COALESCE(
    current_setting('app.settings.edge_function_url', true) || '/update-vods',
    'http://localhost:54321/functions/v1/update-vods'
  );

  -- Find streamers that need updating (same logic as before)
  FOR v_streamer IN
    SELECT id, login, updated_at
    FROM streamers
    WHERE processing_enabled = true
      AND (
        has_vods = true
        OR (created_at = updated_at)
        OR has_vods IS NULL
      )
      AND updated_at <= NOW() - INTERVAL '24 hours'
    ORDER BY updated_at ASC
    LIMIT 10
  LOOP
    BEGIN
      -- Call update-vods with apikey header
      SELECT net.http_post(
        url := v_url,
        headers := jsonb_build_object(
          'apikey', v_auth_key,
          'Content-Type', 'application/json'
        ),
        body := jsonb_build_object('streamer_id', v_streamer.id),
        timeout_milliseconds := 60000
      ) INTO v_response_id;

      v_updated_count := v_updated_count + 1;

      RAISE NOTICE 'Called update-vods for streamer % (%)', v_streamer.login, v_streamer.id;

      -- Small delay between calls to avoid rate limiting
      PERFORM pg_sleep(1);

    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Failed to update VODs for streamer % (%): %',
        v_streamer.login, v_streamer.id, SQLERRM;
    END;
  END LOOP;

  RAISE NOTICE 'Updated VODs for % streamers', v_updated_count;
END;
$$;

-- Update process_pending_vods to use secret_key when calling process-vod edge function
CREATE OR REPLACE FUNCTION public.process_pending_vods(max_vods integer DEFAULT 5)
RETURNS TABLE(vod_id bigint, source_id text, pending_chunks bigint, request_id bigint)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_supabase_url TEXT;
    v_auth_key TEXT;
    v_vod RECORD;
    v_request_id BIGINT;
    v_processed_count INTEGER := 0;
BEGIN
    -- Get credentials from Vault
    SELECT decrypted_secret INTO v_supabase_url
    FROM vault.decrypted_secrets
    WHERE name = 'supabase_url';

    -- Try secret_key first, then service_role_key
    SELECT decrypted_secret INTO v_auth_key
    FROM vault.decrypted_secrets
    WHERE name = 'secret_key';

    IF v_auth_key IS NULL THEN
        SELECT decrypted_secret INTO v_auth_key
        FROM vault.decrypted_secrets
        WHERE name = 'service_role_key';
    END IF;

    -- Use local URL for testing if supabase_url not set
    IF v_supabase_url IS NULL THEN
        v_supabase_url := 'http://localhost:54321';
    END IF;

    IF v_auth_key IS NULL THEN
        RAISE EXCEPTION 'Missing authentication key in Vault. Please configure secret_key or service_role_key.';
    END IF;

    -- Find VODs with pending chunks (same logic as before)
    FOR v_vod IN
        SELECT
            v.id AS vod_id,
            v.source_id,
            COUNT(c.id) AS pending_chunks,
            MIN(c.attempt_count) AS min_attempt_count,
            v.published_at
        FROM vods v
        INNER JOIN chunks c ON c.vod_id = v.id
        WHERE
            v.ready_for_processing = TRUE
            AND v.availability = 'available'
            AND c.status = 'pending'
            AND EXISTS (
                SELECT 1 FROM streamers s
                WHERE s.id = v.streamer_id
                AND s.processing_enabled = TRUE
            )
        GROUP BY v.id, v.source_id, v.published_at
        ORDER BY
            MIN(c.attempt_count) ASC,
            v.published_at DESC
        LIMIT max_vods
    LOOP
        -- Call process-vod edge function with apikey header
        SELECT net.http_post(
            url := v_supabase_url || '/functions/v1/process-vod',
            headers := jsonb_build_object(
                'Content-Type', 'application/json',
                'apikey', v_auth_key
            ),
            body := jsonb_build_object(
                'vod_id', v_vod.vod_id,
                'source_id', v_vod.source_id
            ),
            timeout_milliseconds := 10000
        ) INTO v_request_id;

        RAISE NOTICE 'Scheduled processing for VOD % (source: %) with % pending chunks. Request ID: %',
            v_vod.vod_id, v_vod.source_id, v_vod.pending_chunks, v_request_id;

        RETURN QUERY
        SELECT
            v_vod.vod_id,
            v_vod.source_id,
            v_vod.pending_chunks,
            v_request_id;

        v_processed_count := v_processed_count + 1;
    END LOOP;

    IF v_processed_count = 0 THEN
        RAISE NOTICE 'No VODs with pending chunks found for processing';
    END IF;

    RETURN;
END;
$$;

-- Note: For local testing with pg_cron, you would need to install and configure pg_cron
-- The actual cron jobs should be updated via Supabase UI for production
--
-- Example commands to run after applying this migration (for reference):
-- SELECT cron.schedule('insert-new-streamers', '0 0 * * *', 'SELECT public.cron_insert_new_streamers_v2()');
-- SELECT cron.schedule('check-vod-availability', '0 */12 * * *', 'SELECT public.cron_check_vod_availability()');