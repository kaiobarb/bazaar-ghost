-- Durable account polling, discovery, archive readiness, and signed YouTube notifications.
CREATE TABLE public.platform_ingestion_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source text NOT NULL CHECK (source IN ('youtube', 'bilibili')),
  kind text NOT NULL CHECK (kind IN ('account', 'video', 'discovery')),
  source_id text NOT NULL,
  account_id uuid,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'waiting', 'processing', 'completed', 'skipped')),
  next_attempt_at timestamptz NOT NULL DEFAULT NOW(),
  last_attempt_at timestamptz,
  completed_at timestamptz,
  attempts integer NOT NULL DEFAULT 0,
  last_error text,
  state jsonb NOT NULL DEFAULT '{}'::jsonb,
  lease_token uuid,
  lease_expires_at timestamptz,
  rerun_requested boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (source, kind, source_id),
  FOREIGN KEY (account_id, source) REFERENCES public.platform_accounts(id, source) ON DELETE CASCADE,
  CHECK (kind <> 'account' OR account_id IS NOT NULL)
);
CREATE INDEX platform_ingestion_due_idx ON public.platform_ingestion_jobs(next_attempt_at)
  WHERE status IN ('pending', 'waiting', 'processing');
ALTER TABLE public.platform_ingestion_jobs ENABLE ROW LEVEL SECURITY;
CREATE POLICY service_role_full_access ON public.platform_ingestion_jobs
  FOR ALL TO service_role USING (true) WITH CHECK (true);
REVOKE ALL ON public.platform_ingestion_jobs FROM anon, authenticated;
GRANT ALL ON public.platform_ingestion_jobs TO service_role;

CREATE TABLE public.youtube_websub_subscriptions (
  account_id uuid PRIMARY KEY REFERENCES public.platform_accounts(id) ON DELETE CASCADE,
  callback_token text NOT NULL DEFAULT encode(extensions.gen_random_bytes(32), 'hex'),
  secret text NOT NULL DEFAULT encode(extensions.gen_random_bytes(32), 'hex'),
  requested_at timestamptz,
  confirmed_at timestamptz,
  lease_expires_at timestamptz,
  last_error text,
  CHECK (length(callback_token) = 64 AND length(secret) = 64)
);
ALTER TABLE public.youtube_websub_subscriptions ENABLE ROW LEVEL SECURITY;
CREATE POLICY service_role_full_access ON public.youtube_websub_subscriptions
  FOR ALL TO service_role USING (true) WITH CHECK (true);
REVOKE ALL ON public.youtube_websub_subscriptions FROM anon, authenticated;
GRANT ALL ON public.youtube_websub_subscriptions TO service_role;

CREATE TABLE public.youtube_websub_deliveries (
  account_id uuid NOT NULL REFERENCES public.platform_accounts(id) ON DELETE CASCADE,
  body_sha256 text NOT NULL CHECK (body_sha256 ~ '^[a-f0-9]{64}$'),
  received_at timestamptz NOT NULL DEFAULT NOW(),
  PRIMARY KEY (account_id, body_sha256)
);
ALTER TABLE public.youtube_websub_deliveries ENABLE ROW LEVEL SECURITY;
CREATE POLICY service_role_full_access ON public.youtube_websub_deliveries
  FOR ALL TO service_role USING (true) WITH CHECK (true);
REVOKE ALL ON public.youtube_websub_deliveries FROM anon, authenticated;
GRANT ALL ON public.youtube_websub_deliveries TO service_role;

CREATE FUNCTION public.enqueue_platform_ingestion(
  p_source text, p_kind text, p_source_id text, p_account_id uuid DEFAULT NULL,
  p_wake boolean DEFAULT false
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid;
BEGIN
  IF p_source IS NULL OR p_source NOT IN ('youtube', 'bilibili') OR p_source_id IS NULL OR
     p_kind IS NULL OR p_kind NOT IN ('account', 'video', 'discovery') OR
     (p_kind = 'discovery' AND p_source_id <> 'bazaar') OR
     (p_kind = 'video' AND NOT CASE WHEN p_source = 'youtube' THEN p_source_id ~ '^[A-Za-z0-9_-]{11}$'
                                  ELSE p_source_id ~ '^BV[A-Za-z0-9]{10}$' END) OR
     (p_kind = 'account' AND (p_account_id IS NULL OR NOT EXISTS (
       SELECT 1 FROM platform_accounts WHERE id = p_account_id AND source = p_source AND source_id = p_source_id
     ))) THEN
    RAISE EXCEPTION 'Invalid ingestion identity';
  END IF;
  INSERT INTO platform_ingestion_jobs(source, kind, source_id, account_id)
  VALUES (p_source, p_kind, p_source_id, p_account_id)
  ON CONFLICT (source, kind, source_id) DO UPDATE SET
    account_id = COALESCE(platform_ingestion_jobs.account_id, EXCLUDED.account_id),
    -- Routine polls do not continuously recatalog terminal videos. Revisit metadata/added parts daily.
    status = CASE WHEN platform_ingestion_jobs.status <> 'processing' AND
       (p_wake OR (platform_ingestion_jobs.status IN ('completed', 'skipped') AND
         platform_ingestion_jobs.completed_at < NOW() - INTERVAL '1 day')) THEN 'pending'
       ELSE platform_ingestion_jobs.status END,
    next_attempt_at = CASE WHEN p_wake OR (platform_ingestion_jobs.status IN ('completed', 'skipped') AND
         platform_ingestion_jobs.completed_at < NOW() - INTERVAL '1 day') THEN NOW()
       ELSE platform_ingestion_jobs.next_attempt_at END,
    rerun_requested = platform_ingestion_jobs.rerun_requested OR
      (p_wake AND platform_ingestion_jobs.status = 'processing')
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE FUNCTION public.claim_platform_ingestion(p_include_discovery boolean DEFAULT true)
RETURNS SETOF public.platform_ingestion_jobs LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  WITH candidate AS (
    SELECT j.id FROM platform_ingestion_jobs j
    LEFT JOIN platform_accounts a ON a.id = j.account_id
    WHERE ((j.status IN ('pending', 'waiting') AND j.next_attempt_at <= NOW()) OR
           (j.status = 'processing' AND j.lease_expires_at < NOW()))
      AND (j.account_id IS NULL OR a.processing_enabled)
      AND (p_include_discovery OR j.kind <> 'discovery')
    ORDER BY j.next_attempt_at, j.created_at
    LIMIT 1 FOR UPDATE OF j SKIP LOCKED
  )
  UPDATE platform_ingestion_jobs j SET status = 'processing', lease_token = gen_random_uuid(),
    lease_expires_at = NOW() + INTERVAL '20 minutes', last_attempt_at = NOW(), attempts = attempts + 1
  FROM candidate c WHERE j.id = c.id RETURNING j.*;
$$;

CREATE FUNCTION public.finish_platform_ingestion(
  p_id uuid, p_token uuid, p_status text, p_delay_seconds integer DEFAULT 900,
  p_error text DEFAULT NULL, p_state jsonb DEFAULT '{}'::jsonb
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_status IS NULL OR p_status NOT IN ('waiting', 'completed', 'skipped') OR
     p_delay_seconds IS NULL OR p_delay_seconds < 30 OR p_delay_seconds > 604800 OR
     p_state IS NULL OR jsonb_typeof(p_state) <> 'object' THEN
    RAISE EXCEPTION 'Invalid ingestion completion';
  END IF;
  UPDATE platform_ingestion_jobs SET
    status = CASE WHEN rerun_requested THEN 'pending' ELSE p_status END,
    next_attempt_at = CASE WHEN rerun_requested THEN NOW() ELSE NOW() + make_interval(secs => p_delay_seconds) END,
    completed_at = CASE WHEN p_status IN ('completed', 'skipped') THEN NOW() ELSE NULL END,
    last_error = left(p_error, 1000), state = p_state,
    attempts = CASE WHEN p_error IS NULL THEN 0 ELSE attempts END,
    lease_token = NULL, lease_expires_at = NULL, rerun_requested = false
  WHERE id = p_id AND lease_token = p_token AND status = 'processing' AND lease_expires_at > NOW();
  RETURN FOUND;
END;
$$;

CREATE FUNCTION public.receive_youtube_notification(p_account_id uuid, p_digest text, p_video_ids text[])
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_video_id text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM platform_accounts WHERE id = p_account_id AND source = 'youtube' AND processing_enabled) THEN
    RETURN false;
  END IF;
  IF p_video_ids IS NULL OR cardinality(p_video_ids) > 100 THEN RAISE EXCEPTION 'Invalid notification'; END IF;
  INSERT INTO youtube_websub_deliveries(account_id, body_sha256) VALUES (p_account_id, p_digest)
    ON CONFLICT DO NOTHING;
  IF NOT FOUND THEN RETURN false; END IF;
  FOREACH v_video_id IN ARRAY p_video_ids LOOP
    PERFORM enqueue_platform_ingestion('youtube', 'video', v_video_id, p_account_id, true);
  END LOOP;
  RETURN true;
END;
$$;

CREATE FUNCTION public.schedule_platform_account() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.source IN ('youtube', 'bilibili') AND NEW.processing_enabled THEN
    PERFORM enqueue_platform_ingestion(NEW.source, 'account', NEW.source_id, NEW.id, true);
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER schedule_platform_account AFTER INSERT OR UPDATE OF processing_enabled ON public.platform_accounts
  FOR EACH ROW EXECUTE FUNCTION public.schedule_platform_account();

REVOKE ALL ON FUNCTION public.enqueue_platform_ingestion(text,text,text,uuid,boolean),
  public.claim_platform_ingestion(boolean), public.finish_platform_ingestion(uuid,uuid,text,integer,text,jsonb),
  public.receive_youtube_notification(uuid,text,text[]), public.schedule_platform_account() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.enqueue_platform_ingestion(text,text,text,uuid,boolean),
  public.claim_platform_ingestion(boolean), public.finish_platform_ingestion(uuid,uuid,text,integer,text,jsonb),
  public.receive_youtube_notification(uuid,text,text[]) TO service_role;

SELECT public.enqueue_platform_ingestion(source, 'account', source_id, id)
FROM public.platform_accounts WHERE source IN ('youtube', 'bilibili') AND processing_enabled;
SELECT public.enqueue_platform_ingestion('youtube', 'discovery', 'bazaar');
SELECT public.enqueue_platform_ingestion('bilibili', 'discovery', 'bazaar');

CREATE FUNCTION public.get_platform_ingestion_dispatches(p_limit integer DEFAULT 3)
RETURNS TABLE(vod_id bigint) LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT c.vod_id FROM chunks c JOIN vod_processing_context v ON v.id = c.vod_id
  WHERE c.status = 'pending' AND c.scheduled_for <= NOW()
    AND v.source IN ('youtube', 'bilibili') AND v.processing_enabled
    AND v.availability = 'available' AND v.ready_for_processing
  GROUP BY c.vod_id ORDER BY MAX(c.priority) DESC, MIN(c.scheduled_for), c.vod_id
  LIMIT GREATEST(0, LEAST(COALESCE(p_limit, 0), 3));
$$;
REVOKE ALL ON FUNCTION public.get_platform_ingestion_dispatches(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_platform_ingestion_dispatches(integer) TO service_role;
