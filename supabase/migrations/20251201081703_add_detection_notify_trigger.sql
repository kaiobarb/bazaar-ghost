-- Trigger to notify Discord users when their username is detected
-- Calls ghost-bot edge function with action: "notify"

CREATE OR REPLACE FUNCTION notify_on_detection()
RETURNS TRIGGER AS $$
DECLARE
  v_secret_key text;
  v_supabase_url text;
BEGIN
  -- Get secrets from vault
  SELECT decrypted_secret INTO v_secret_key
  FROM vault.decrypted_secrets
  WHERE name = 'secret_key'
  LIMIT 1;

  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'supabase_url'
  LIMIT 1;

  IF v_secret_key IS NULL OR v_supabase_url IS NULL THEN
    RAISE WARNING 'Missing vault secrets for notification';
    RETURN NEW;
  END IF;

  PERFORM net.http_post(
    url := v_supabase_url || '/functions/v1/ghost-bot',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', v_secret_key
    ),
    body := jsonb_build_object(
      'action', 'notify',
      'username', NEW.username,
      'vod_id', NEW.vod_id,
      'frame_time_seconds', NEW.frame_time_seconds
    )
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER detection_notify_trigger
  AFTER INSERT ON detections
  FOR EACH ROW
  EXECUTE FUNCTION notify_on_detection();
