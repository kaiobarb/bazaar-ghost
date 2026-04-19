# Architectural Review — bazaar-ghost

An honest assessment of high-level design decisions and patterns in this codebase.
Written April 2026 after a review session with Claude.

---

## Areas for improvement

### 1. No separation between infrastructure and domain logic

The biggest structural issue. `process-vod/index.ts` handles HTTP parsing, Twitch signature verification, database queries, business rules (old templates cutoff), GitHub API calls, and chunk status transitions — all in one place. The three layers that should be distinct:

- **Transport** — parse the request, validate auth, serialize the response
- **Domain** — "given this VOD, what chunks need processing and with what config?"
- **Infrastructure** — GitHub API, Supabase queries, Twitch API

When these are interleaved, a 2am failure is hard to diagnose: is it the auth, the business logic, or the DB query? Splitting `process-vod` was a start (#5 on the improvement list), but the pattern should propagate.

---

### 2. State is communicated through status strings, not recorded transitions

Chunks move through `pending → queued → processing → completed/failed`. The problems:

- Nothing enforces valid transitions — any code can set any status at any time
- No record of *when* a transition happened or *why* it failed
- Chunks can get stuck in `processing` forever with no way to distinguish "container died" from "job is slow"

**Better pattern:** An append-only `chunk_events` table (`chunk_id, from_status, to_status, timestamp, metadata`). Current status is always derivable; you never lose history; "why is this chunk stuck?" becomes a query instead of a mystery.

---

### 3. GitHub Actions as compute — intentional, with known trade-offs

Using GitHub Actions as the VOD processing job runner was a deliberate cost decision — it's free and has been reliable enough for this use case. The trade-offs to be aware of:

- **No concurrency control** — multiple workflow dispatches run in parallel with no coordination
- **No automatic retry** — if a container dies mid-chunk, the chunk sits in `processing` with no requeue
- **No job visibility** — knowing whether a job is running requires polling the GitHub API
- **Silent failures** — dispatch errors in `processStreamOffline` are caught and swallowed; chunks stay `queued` with no alert or retry

These aren't reasons to replace GH Actions — they're reasons to build management around it: a stuck-chunk detector (cron that requeues `processing` chunks older than N minutes), explicit error alerting on dispatch failure, and concurrency limiting on the workflow side.

---

### 4. Config lives in five separate places

Detection behavior is controlled by:

1. `config.yaml` — frame rate, OCR threshold, batch size
2. `sfde_profiles` table — crop regions, edge settings per streamer
3. `OLD_TEMPLATES_CUTOFF` — hardcoded constant in `_shared/github.ts`
4. `old_templates` flag — env var + workflow input
5. Template PNG files — implicitly define which resolutions are supported

These five systems must agree, and there's no single place to answer "what were the exact settings for this chunk?" A resolved config object — computed once at dispatch time and stored with the chunk — would make debugging detection quality problems dramatically faster.

---

### 5. Error handling is fire-and-forget at the boundaries

In `processStreamOffline`, the entire GitHub dispatch sequence is wrapped in a `try/catch` that logs and swallows the error. If dispatch fails, chunks stay `queued` forever — no retry, no alert, no requeue. In `sfde.py`, worker exceptions correctly set the chunk to `failed`, but there's no automatic retry or backoff.

The architecture has no opinion on "what happens when things go wrong" beyond logging. This is fine for a solo project, but any reliability improvement starts here.

---

### 6. The test pyramid was inverted

Before the April 2026 refactor session, the test suite had good CV unit tests (emblem detection, OCR accuracy) — expensive tests that require real images and loaded models — but almost no cheap tests (pure functions, state transitions, HTTP routing). 

Expensive model tests catch accuracy regressions. Cheap unit tests catch logic bugs in seconds. The cheap ones should always exist first. The refactor added `test_image_utils.py`, `test_sfde_config.py`, `test_workers.py`, and `test_imports.py` to start correcting this.

---

### 7. Magic strings for status and rank values

`"pending"`, `"queued"`, `"processing"`, `"completed"`, `"failed"` appear as raw strings throughout TypeScript and Python. Same with `"bronze"`, `"silver"`, `"gold"`, `"diamond"`, `"legend"`. 

In TypeScript these should be `const enum` or union types. In Python, `enum.Enum`. When a new status is added, the type checker should flag every site that needs updating — currently `grep` is the only option.

---

## What's genuinely good

- **Observability** — OpenTelemetry tracing end-to-end, structured JSON logging, Grafana Cloud integration. Better than most solo projects by a wide margin.
- **Migration discipline** — 11 tracked Supabase migrations, no ad-hoc schema changes in prod.
- **SFDE profile system** — per-streamer detection config stored in DB rather than code. This is the right architectural instinct; it just hasn't been applied consistently to the rest of config.
- **Worker decomposition (post-refactor)** — `PipelineContext` + `run(ctx)` workers give each thread a testable seam. The IGD state machine, JPEG boundary parsing, and queue-sync invariant are now exercisable without Docker.

---

## Highest-leverage single fix

**Make chunk state transitions explicit and recorded** (item 2 above). One migration adding a `chunk_events` table + one helper function that writes a row on every status change. Cost: ~2 hours. Benefit: "why is this chunk stuck?" goes from a mystery to a 30-second query. Every other reliability improvement builds on this foundation.
