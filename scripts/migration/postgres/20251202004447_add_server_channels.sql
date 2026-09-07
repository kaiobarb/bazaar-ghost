-- Server channels table: stores which channel each server uses for notifications
CREATE TABLE public.server_channels (
    guild_id TEXT PRIMARY KEY,
    channel_id TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE public.server_channels ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role full access" ON public.server_channels
    FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- Add notify_type and guild_id to notification_subscriptions
ALTER TABLE public.notification_subscriptions
ADD COLUMN notify_type TEXT NOT NULL DEFAULT 'both'
CHECK (notify_type IN ('dm', 'server', 'both'));

ALTER TABLE public.notification_subscriptions
ADD COLUMN guild_id TEXT;
