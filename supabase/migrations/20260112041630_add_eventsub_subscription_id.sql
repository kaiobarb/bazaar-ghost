-- Add eventsub_subscription_id to streamers table for tracking EventSub webhook subscriptions
ALTER TABLE streamers
ADD COLUMN eventsub_subscription_id text NULL;

COMMENT ON COLUMN streamers.eventsub_subscription_id IS 'Twitch EventSub subscription ID for stream.offline webhook.';
