-- Track how many notifications have been sent for each subscription
ALTER TABLE public.notification_subscriptions
ADD COLUMN notification_count INTEGER NOT NULL DEFAULT 0;

-- Function to increment notification count for multiple subscriptions
CREATE OR REPLACE FUNCTION increment_notification_count(
  p_username TEXT,
  p_discord_user_ids TEXT[]
)
RETURNS VOID AS $$
BEGIN
  UPDATE notification_subscriptions
  SET notification_count = notification_count + 1
  WHERE username = p_username
    AND discord_user_id = ANY(p_discord_user_ids);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
