-- Discord username notification subscriptions
-- Allows Discord users to subscribe to notifications when their Bazaar username is detected

CREATE TABLE public.notification_subscriptions (
    discord_user_id TEXT NOT NULL,
    username TEXT NOT NULL,
    username_lower TEXT GENERATED ALWAYS AS (lower(username)) STORED,
    enabled BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now(),

    PRIMARY KEY (discord_user_id, username_lower)
);

ALTER TABLE public.notification_subscriptions OWNER TO postgres;

COMMENT ON TABLE public.notification_subscriptions IS 'Discord user subscriptions for username detection notifications';
COMMENT ON COLUMN public.notification_subscriptions.discord_user_id IS 'Discord snowflake ID';
COMMENT ON COLUMN public.notification_subscriptions.username IS 'The Bazaar username to monitor';
COMMENT ON COLUMN public.notification_subscriptions.username_lower IS 'Lowercase username for case-insensitive matching';
COMMENT ON COLUMN public.notification_subscriptions.enabled IS 'Whether notifications are enabled for this subscription';

-- Index for lookups by username alone (PK is discord_user_id, username_lower)
CREATE INDEX idx_notification_subscriptions_username_lower
    ON public.notification_subscriptions(username_lower);

-- Trigram index for fuzzy matching (handles OCR errors like l/j, 0/O)
CREATE INDEX idx_notification_subscriptions_username_trgm
    ON public.notification_subscriptions
    USING gin (username_lower public.gin_trgm_ops);

-- RLS (only service_role has access - used by edge functions and triggers)
ALTER TABLE public.notification_subscriptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role full access" ON public.notification_subscriptions
    FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);
