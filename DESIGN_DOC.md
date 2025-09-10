## Purpose

Bazaar Ghost indexes **Twitch VODs** (and optionally YouTube) for the game **The Bazaar**, detects **matchup screens**, extracts **usernames**, and exposes a **searchable website** where players can find themselves in past matches. The system favors **lean, cheap/free, open-source** components and trades a few minutes of freshness for **simplicity, robustness, and scalability**.

---

## Goals

- **Accurate, searchable index** of matchup timestamps linked to source VODs.
- **Semi-live tracking** of ongoing streams by processing **30-minute VOD chunks**.
- **Backfill** of historical VODs to seed initial results.
- **Low-cost, low-ops** operation with clear pathways to scale.
- **Strong lifecycle rules**: records only appear in search if a **valid external VOD link** exists; removed/expired VODs are **archived** and can be pruned.
- **Runtime parity**: the **SFOT** execution path runs from a **single container image** across **local**, **VM**, and **Cloud Run Jobs** with the **same entrypoint and pinned dependencies** to reduce snowflakes.

## Non-Goals

- Hosting full clips or heavy media storage (out of scope for now).
- Perfect real-time operation; **≤\~30–40 min** latency is acceptable.
- Complex multi-cloud orchestration; keep components minimal.

---

## High-Level Flow

1. **Cataloger** discovers streamers and eligible VODs for _The Bazaar_, auto-inserts new streamers, and (for **vetted** streamers) writes VOD/placeholder job records for **Bazaar-only** sections; enqueuing is triggered downstream (e.g., DB trigger/worker).
2. **Live Sentinel** subscribes to **Twitch EventSub** (stream online/offline). When online, it **enqueues** a 30-minute chunk every 30 minutes until offline.
3. **Chunk Workers** process enqueued VOD windows using **SFOT** (Streamlink → FFmpeg → OpenCV → Tesseract) — **executed via the same container image** everywhere — and write **progress + detections**.
4. **VOD Health** checks run on a schedule to **validate link availability**; unavailable links **hide** detections from search and **archive** them.
5. **Ops Console** shows jobs in progress, throughput, runtimes, failures, and match counters.

---

## Control Plane vs Data Plane

- **Control Plane (managed + cheap)**

  - **Supabase**: Postgres, auth, **Queues**, **Cron**, **Edge Functions**, Realtime.
  - Stores creators, VOD references, chunk jobs, progress snapshots, detections, and archival flags.
  - Hosts **Edge Functions** for Cataloger and Live Sentinel webhooks.

- **Data Plane (SFOT execution)**

  - **One container image** drives all execution targets (local/VM/Cloud Run Jobs).
  - Option A **VM worker** (Hetzner/DO/Oracle Free): single queue consumer with small parallelism; cheapest for steady loads.
  - Option B **Cloud Run Jobs**: one job per chunk; **scale-to-zero**; generous free tier; best for bursty workloads.
  - **Hybrid**: VM baseline + Cloud Run Jobs as overflow if queue depth spikes.

---

## Components

### 1) Cataloger

**Purpose:** Build and maintain the backlog of **eligible** Bazaar content with a **human-in-the-loop** gate before backfilling/processing.

**Key Principles**

- **Automatic streamer discovery:** Any channel streaming in _The Bazaar_ category is auto-inserted into the DB.
- **Human-in-the-loop backfill gate:** VODs are only inserted for channels with `vetted_for_backfill = true` (e.g., SFOT profile confirmed, HUD not blocked, ROI stable).
- **Bazaar-only scope:** Create VOD/placeholder job records **only** for VOD sections that contain Bazaar gameplay (prefer official chapter data when available).
- **Idempotent + append-only:** Upserts avoid duplicates; no artificial caps on backlog size.
- **Decoupled enqueue:** Cataloger writes records; actual **enqueue** is triggered downstream (e.g., DB trigger/worker). TBD.

**Responsibilities (Phase 1)**

- Resolve `game_id` for _The Bazaar_.
- **Discovery**

  - Periodically enumerate creators currently/previously streaming _The Bazaar_ and **upsert** streamer records with metadata (ids, login, display_name, profile_img, etc.).
  - For **vetted** streamers, list their recent VODs and determine **Bazaar segments** using available metadata (e.g., chapters/markers). Where exact chapters are available, generate **per-segment** placeholders; otherwise mark VODs as `bazaar_presence = unknown` without creating processing placeholders.

- **Backlog accounting**

  - Maintain uncapped counts of **eligible Bazaar VODs** per streamer (for prioritization and ops visibility).
  - Persist minimal, query-friendly fields (vod_id, created_at, duration, known Bazaar segments, last_checked_at, availability state).

**Responsibilities (Phase 2)**

- **Daily** refresh to:

  - Detect **new Bazaar VODs/segments** for vetted streamers and add placeholders.
  - Recheck **availability** of previously discovered VODs and update state.

**Discovery Strategy (tactics)**

- **Baseline:** Hourly cron-based Helix queries to discover new streamers and VODs; idempotent upserts.
- **Efficiency (optional):** For already-known creators, consider **EventSub `channel.update`** to detect category switches to/from _The Bazaar_, reducing reliance on polling. (Still require periodic discovery for brand-new creators.)

**Outputs**

- **Streamers**: upserted with flags (`vetted_for_backfill`, optional `sfot_profile_id`).
- **VOD placeholders**: Only for vetted streamers **and** confirmed Bazaar segments (chapter-backed). Non-chaptered candidates are recorded for visibility but **not** enqueued.
- **Metrics**: `eligible_bazaar_vod_count` per streamer; timestamps of last discovery/refresh.

**Runtime/Hosting**

- **Supabase Edge Function** + **Cron**. Idempotent, paginated Helix access; respects rate limits; retries on transient errors.

**Notes / Open Questions**

- Best signal for Bazaar **segments**: public chapter/marker availability varies; fallback policy when chapters are missing.
- Exact mechanism for **enqueue** (DB trigger vs. queue consumer) left **TBD**.

### 2) Live Sentinel

**Purpose:** Turn live streams into **semi-live VOD chunks**.

**Responsibilities**

- **EventSub** webhooks: `stream.online` and `stream.offline`.
- On **online**:

  - Resolve **current live-VOD** ID.
  - Enqueue first **\[t, t+30m)** window (with 2–5 min safety margin).
  - Set a **recurring enqueue** every 30 min while live.

- On **offline**:

  - Stop recurrence; enqueue a **final catch-up** window if needed.

**Runtime/Hosting**

- **Supabase Edge Function** with verified webhooks (HMAC), idempotent handling, retries.

---

### 3) Chunk Workers (SFOT)

**Purpose:** Process a 30-minute VOD window and emit results.

**Requirements**

- **Container parity:** one image across local, VM, and Cloud Run Jobs; same interface; configuration via environment or mounted config file.
- **Single-language orchestration:** prefer **Python-based** packages and wrappers so the controller/orchestrator script(s) stay in one language.
- **Deterministic & idempotent:** work unit identity is `(vod_id, start, end)`; safe to retry without duplicate emissions.
- **Resource guardrails:** bounded CPU/memory use, network rate limiting, and max concurrency to control cost.
- **Clear failure semantics:** well-defined exit statuses; transient errors retried with backoff; permanent failures surfaced to the control plane.
- **Telemetry:** structured logs (JSON), progress snapshots, and detection outputs recorded to the control plane (Supabase).

**Responsibilities**

- Retrieve the target **VOD time window** and sample frames at a **configured cadence** sufficient for HUD legibility.
- Apply a **visual gate** to detect matchup screens; on positives, run **OCR** to extract usernames with constrained character sets.
- Emit **detections** (usernames + precise timestamps, and optional evidence frame references) and **progress** updates.
- Respect **overlap/safety margins** between adjacent windows and avoid duplicate results.
- Operate within platform **rate limits** and policies for API/CDN access.

**Configuration (examples)**

- Time window length (defaults to **30m**), **overlap** seconds, **sampling cadence**.
- Rendition preference and **ROI/threshold profiles** per HUD version.
- OCR parameters (e.g., page segmentation, allowed charset), **retry/backoff**, and **timeouts**.
- Concurrency limits and optional feature flags (e.g., enable evidence frame storage).

**Runtime/Hosting (high-level)**

- Invoked by a queue consumer or serverless job runner using the **same container** and entry contract; no environment-specific code paths.

> Implementation details (specific CLI flags, image names, build steps) are intentionally kept in code/docs; this section remains **tech-agnostic** while enforcing behavior and contracts.

### 4) Backfill Runner (local)

**Purpose:** Seed initial data quickly using the **same container** to keep code paths identical.

**Responsibilities**

- Download full VODs (low-res) **or** fetch segment ranges; process as regular **chunks** via the `sfot run` container.

**Runtime**

- Local bash/python orchestrator invoking `docker run` with Supabase credentials and job args; write progress/results to Supabase.

---

### 5) Ops Console

**Purpose:** Awareness and debugging; starts read-only.

**Implementation (start simple)**

- **Metabase** against Supabase with a few saved queries:

  - Chunks in progress (with %), completions/day, p50/p95 runtimes.
  - Matches per streamer/day; failure counts by reason.

- Later: **Appsmith** or a tiny **Next.js + Supabase Realtime** app for **control buttons** (rerun chunk, retry failed, kick off backfill for a Twitch URL).

---

## VOD Availability & Data Lifecycle (critical requirement)

**Assumption:** A result is **useful only if** it links to **accessible external video** (VOD or clip). If the source becomes unavailable, hide from search; optionally keep an **archive** record.

### States

- **available**: VOD/clip URL is reachable and playable (per Helix status/URL and/or HEAD/GET check).
- **unknown**: not yet checked or transient error; conservative handling (optionally show with disclaimer or hide until confirmed).
- **unavailable**: 404/410/permission, or Helix no longer returns the video → **exclude from search**.

### Health Checks

- **On write**: when chunk finishes, verify the VOD reference exists (Helix Get Videos / platform API).
- **Scheduled sweeps**:

  - **Daily**: check a rolling window of recent VODs.
  - **Weekly**: sample older VODs.

- **On search** (optional): lazy-check stale entries (>N days since last check) in the background.

### Behavior When Unavailable

- Mark related detections as **unlinked**; **hide from search** immediately.
- Move records to an **archive** area/state (still queryable by admins).
- Optional local export (CSV/NDJSON) for a belt-and-suspenders backup.

### Pruning Policy (cost guardrail)

- Maintain a soft cap aligned with **Supabase free tier** thresholds.
- When crossing thresholds:

  1. Export **archive** records locally (batch download).
  2. **Purge** archived detections older than K days or least-valuable by score.

- Keep stats on prune volume and remaining counts.

---

## Prioritization

- **Creators:** prioritize by **eligible Bazaar VOD count** (uncapped). Tie-breaker: most recent eligible VOD timestamp.
- **VODs/Segments:** within a creator, process **confirmed Bazaar chapters/segments** first; otherwise newest-first among confirmed items. _(No viewer-based scoring.)_

---

## Reliability Patterns

- **Idempotent chunk identity**: `(vod_id, start, end)`; duplicates are safe no-ops.
- **Leases + heartbeats** on claimed work; expire and reassign on worker failure.
- **Backpressure**: token bucket for HLS segment fetches; per-worker concurrency = `min(vCPU-1, configured_max)`.
- **Retries**: exponential backoff on transient network/CDN/API errors; cap attempts; flag hard failures.
- **Safety margins**: don’t schedule the most recent 2–5 minutes of an in-progress live VOD; add **8–10s overlap** between adjacent chunks.

---

## Cost Model (guidance)

- **Compute**:

  - VM @ €3.79–\$8/mo (steady trickle) **or** Cloud Run Jobs (bursty; free tier often covers you).

- **Storage**: none for clips (out of scope); DB rows only. If you choose to persist tiny PNG proofs later, store sparingly and purge aggressively.
- **Egress**: minimal (primarily control-plane + metadata).

---

## Security & Compliance

- Store secrets in platform secret managers / envs (Twitch tokens, DB, webhooks).
- Verify **EventSub HMAC**; rotate secrets on schedule.
- Principle of least privilege on DB service keys.
- Rate limits and respectful polling against Twitch APIs/CDNs.

---

## Observability

- **Progress snapshots** per chunk (time-based % is OK).
- **Worker health** (load, RSS, active chunks).
- Error taxonomy (network, decode, OCR, API 4xx/5xx).
- Minimal alerts (e.g., no progress > N min, rising failure rate).

---

## Deployment Topologies

### VM-First

- One small VM runs the queue consumer that **invokes the container**; simplest + cheapest steady-state.
- Supabase Edge Functions handle Cataloger + Live Sentinel.
- Optionally add Cloud Run Jobs as **overflow** when backlog spikes (same image).

### Serverless-First

- Cloud Run Jobs execute **one chunk per run**; scale to zero, free tier friendly.
- Same Supabase control plane.
- No VM to babysit; best for irregular/bursty loads.

---

## Configuration & Secrets (examples)

- Twitch app credentials, EventSub secret.
- Target game (“The Bazaar”) resolved to `game_id`.
- Discovery windows (hours/days), max creators per run, pagination caps.
- Chunk window size (30m), overlap (8–10s), live safety margin (2–5m).
- **Containerized SFOT knobs** (via env or config file): rendition preference, ROI version, OCR parameters, OpenCV thresholds, GOP burst policy, concurrency.
- Container registry URL/credentials (for private images) if not public.

**Example env keys** (subset)

```
SUPABASE_URL=
SUPABASE_SERVICE_ROLE_KEY=
TWITCH_CLIENT_ID=
TWITCH_CLIENT_SECRET=
SFOT_RENDITION=480p
SFOT_IKEY_ONLY=true
SFOT_GPU=false
```

---

## Failure Modes & Policies

- **Stream/VOD unavailable** mid-processing → mark chunk failed (retry with backoff); if persistent, park VOD.
- **Long GOP** (I-frame gaps): temporary ref-frame decode burst; log once per chunk.
- **High false positives**: raise OpenCV threshold and require **temporal stability** (≥2 consecutive hits).
- **API 401/403**: refresh token; alert if repeated.
- **Container failures**: non-zero exit codes reported to control plane; job auto-retry policy in queue/Cloud Run.

---

## Rollout Plan

1. Build **SFOT container**, push to registry (GHCR). Pin `X.Y.Z` and set `latest`.
2. **Cataloger** Edge Function + Cron (hourly live snapshot, daily backlog refresh).
3. **Live Sentinel** EventSub webhooks (online/offline → enqueue).
4. **Chunk Worker** orchestrators (local/VM/Cloud Run) all call the same image/entrypoint.
5. **VOD Health** sweeper + search-filtering behavior.
6. **Ops Console** (Metabase) with 3–4 initial charts.
7. **Pruning** script for archived records (local export + delete).

---

## Open Questions

- Exact **latency SLO** for semi-live results (e.g., 25–40 min acceptable?).
- Minimum **rendition** that preserves HUD readability across creators (360p vs 480p vs 720p30).
- How aggressively to **prune archives** (age-based vs score-based), and what local backup format to standardize on (CSV vs NDJSON).
- Do live vods on twitch keep the same id once the livestream goes offline?
- Is a **GPU variant** worthwhile for OCR (Tesseract mostly CPU-bound; potential future ML OCR)?

---

### Summary

This design keeps Bazaar Ghost **lean and robust**: simple **Edge Functions** orchestrate, a **queue** feeds either a **cheap VM** or **scale-to-zero jobs**, and **a single containerized SFOT** guarantees **runtime parity** across environments. The **VOD-availability policy** ensures only **linkable** matches remain searchable while expired items move to **archive** and are **prunable** to protect cost. It’s pragmatic today and extensible when you want richer controls and visuals later.
