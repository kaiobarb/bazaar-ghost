# Automatic platform ingestion on Cloudflare

The Worker stores durable discovery, creator-poll, and video-readiness jobs in D1. A bounded GitHub Actions runner claims those jobs, reads platform metadata through yt-dlp/public endpoints, and sends validated catalog changes back to the Worker. Finite playable recordings then enter the existing GitHub OCR workflow. Nothing records a live stream.

This ports the ingestion follow-up from `ec4b870`. The separate [multiplatform backend guide](multiplatform-backend.md) describes source identities, profiles, manual backfills, processing, and appearance grouping.

## Triggers and coverage

| Platform | Discover/enroll creators | Find new playable recordings |
|---|---|---|
| Twitch | Existing Bazaar streamer discovery | Existing EventSub offline event plus VOD reconciliation |
| YouTube | Immutable channel enrollment and bounded recent game-video search | Signed WebSub hints, uploads/streams polling, durable live/post-live readiness retries |
| Bilibili | Immutable uploader UID enrollment and bounded recent `大巴扎` search | Published submission polling/discovery followed by stable CID enumeration |

A stream ending and a recording becoming playable are distinct events. WebSub is an acceleration path for YouTube feed changes; polling and readiness jobs remain necessary. Bilibili integration detects published uploads/replays, not a guaranteed room-ended event. A stream with no accessible published replay never becomes ingestible through this path.

Discovery is best effort. Title/tag gates miss videos that omit the game and may admit discussions or mixed footage. Full metadata verifies the actual owner before account enrollment; a similar creator display name never links identities across platforms. Existing operator disables win over automatic rediscovery.

## Enrollment and bounded runs

Supply `BAZAARGHOST_API_URL`, `BAZAARGHOST_CATALOG_KEY`, and `ENVIRONMENT=local|validation` for the intended local or isolated hosted backend. The commands verify `/health` and never source ambient `.env` files. Hosted GitHub jobs require the branch paired with their selected environment.

```bash
python scripts/platform_ingestion.py enroll --source youtube --identity '@Kripparrian'
python scripts/platform_ingestion.py enroll --source bilibili --identity 2663423

# Catalog already-enrolled accounts/candidates without broad discovery or OCR dispatch.
python scripts/platform_ingestion.py run --no-discovery --limit 10 --seconds 300

# Include discovery and dispatch up to three due videos in the selected environment.
python scripts/platform_ingestion.py run --limit 30 --seconds 1200 --dispatch
```

Enrollment accepts `--profile-id` and an optional verified `--streamer-id` link. YouTube upload-only/archive-only creators are supported: an explicit absent-tab response is an empty tab, while network/access failures remain errors.

Discovery-enabled runs ensure both platform discovery jobs exist before claiming work, without resetting an existing job's due time. `--no-discovery` creates no discovery jobs and excludes existing broad discovery jobs during that run. It does not erase candidates nominated earlier. First enrollment scans a recent page; it does not automatically request a creator's lifetime upload history. Manual historical backfills remain explicit, separately bounded operations.

## Durable state and retries

`platform_ingestion_jobs` stores discovery, account scans, and video-readiness work. The unique key is `(source, kind, source_id)`. Claims are atomic, expire after twenty minutes, and issue a unique lease token. Expired jobs can be reclaimed; stale runners cannot finish or mutate catalog state under the replacement's lease.

Every automatic mutation carries its job identity/token: account discovery, candidate enqueueing, account attachment, video upsert, subscription renewal, and completion. The backend validates ownership in the same D1 transaction as the change. Manual catalog operations use the catalog credential without pretending to hold a job lease. The catalog credential exposes explicit operations rather than unrestricted database writes.

Discovery normally nominates up to 20 recent candidates per platform every six hours. Account scans become due every fifteen minutes. YouTube tracks uploads and streams separately. Each tab stores its previous first ID, an in-progress scan head, and the next playlist position. Catch-up continues in bounded pages until it reaches that previous head or the end; candidate persistence precedes cursor advancement. Inspected playlist slots, including unavailable entries, determine positional progress. Transient failures retain the last committed cursor.

Readiness jobs persist outside the latest channel page. Scheduled/live/post-live YouTube states wait fifteen minutes before retry. Transport/extractor failures retain retryable jobs with a visible error/backoff; they do not establish deletion. Account-feed failures back off up to four hours, and repeated video/discovery exceptions up to roughly five hours. Healthy polling resets the error-attempt counter.

Provider failures carry a finite diagnostic category into the durable job error and the runner's `error_categories` JSON array. Examples include `auth_required`, `http_403`, `http_412`, `http_429`, `provider_feed_rejected`, and `transport_timeout`. Raw extractor stderr, response bodies, playback URLs, and arbitrary exception messages are excluded. These categories describe the observed failure; they do not authorize bypassing provider restrictions or establish that a recording was deleted.

Bilibili jobs process up to 20 parts per lease and continue by seen CID, rather than mutable part number. Recent rediscovery can reopen a completed submission after a day to detect appended parts. Old submissions absent from all current feeds require explicit recataloging to discover revisions; this is not a complete historical watcher.

A notification arriving during active work sets `rerun_requested`. The finishing transaction schedules another pass rather than discarding that notification. GitHub runner crashes leave reclaimable leases; a failed individual job is recorded while the runner continues other healthy work. A run containing errors exits unsuccessfully so the workflow makes partial outages visible.

## YouTube WebSub lifecycle

The public Worker callback is `/functions/v1/youtube-webhook`. The Worker owns per-account callback capabilities, HMAC secrets, subscription requests, confirmations, and granted lease expiry in `youtube_websub_subscriptions`. Python requests `/api/catalog/subscriptions/renew`; it never receives those secrets or calls the hub with them.

Verification requires the exact enrolled channel topic and a pending request before echoing a bounded plain-text challenge. Deliveries require a valid raw-body SHA-1/SHA-256 HMAC, an enabled account, an active confirmed lease, bounded XML without DTD/entities, and matching channel/video identities. Receipt deduplication and candidate enqueueing commit together before acknowledgement.

The requested lease is ten days; renewal begins within twelve hours of expiry. The hub determines the actual granted lease. Unconfirmed requests wait an hour before another attempt. Hub denial/request failure is recorded and leaves polling active. Disabling an account stops renewal and delivery acceptance; explicit upstream unsubscribe is not implemented, so its outstanding hub subscription expires naturally.

Delivery digest tombstones are retained for the account lifetime. WebSub deliveries contain no signed timestamp, so deleting those digests would let an old signed body wake processing again. Stable source IDs and guarded timelines additionally keep cataloging idempotent. A real public hub subscription/renewal and live-to-archive event still need hosted evidence beyond signed local fixtures.

## Dedicated migration workflow

`ingest-platforms.yml` accepts `workflow_dispatch` and `workflow_call`, requires `refs/heads/codex/cloudflare-validation`, uses GitHub environment `validation`, and serializes its runs. Both triggers expose the same controls:

| Input | Default | Behavior |
|---|---|---|
| `source` | `none` | Optional enrollment platform: `none`, `youtube`, or `bilibili` |
| `identity` | empty | Optional creator identity to enroll before draining jobs |
| `discovery` | `false` | Include broad discovery jobs when true |
| `dispatch` | `true` | Dispatch OCR for up to three due videos after draining jobs when true |
| `limit` | `30` | Maximum ingestion jobs to claim; integer from 1 through 100 |
| `seconds` | `1200` | Budget for starting ingestion jobs; integer from 30 through 1200 |

Discovery defaults off so initial platform tests can start with selected creators/recordings. The default drain remains thirty jobs/twenty minutes with OCR dispatch enabled. The CLI rejects out-of-range or noninteger budgets. It starts no new job after the budget expires, though an already-running bounded metadata operation may finish later. OCR dispatch, when enabled, happens after this drain and is separate from its time/job budget.

For a short run of existing account/candidate jobs without broad discovery or OCR dispatch:

```bash
gh workflow run ingest-platforms.yml --ref codex/cloudflare-validation \
  -f source=none -f discovery=false -f dispatch=false -f limit=3 -f seconds=90
```

This run still claims durable jobs and writes catalog/retry state; `dispatch=false` is not a dry run. Inputs enter task-specific environment variables and a quoted shell argument array, so numeric validation remains in the CLI and a false dispatch input does not fall back to true.

The workflow has no automatic default-branch schedule. GitHub scheduled workflows are activated from the default branch; merely checking out a feature branch would not make a separate schedule exist. The validation pipeline can call ingestion after deployment, or the isolated control plane can explicitly dispatch it once platform behavior is verified. Initial validation must not require changes to the running production/default-branch workflow.

Environment preflight verifies HTTPS origin, unauthenticated `/health`, and GitHub branch pairing before sending catalog/processor keys. The Worker separately checks the requested environment before dispatching OCR. Validation resource names, credentials, queues, and callbacks are separate from dev and production. Weekly deletion of the existing dev bucket does not apply to validation.

The OCR dispatcher selects at most three due platform videos per ingestion run and retains the global active-chunk cap. Video count alone is not a source-hours budget: a long archive can create many pending chunks. Broad automatic enrollment should follow measured queue age, error rates, and processing cost, with an explicit capacity policy.

## Evidence to retain

For each hosted recording, retain its source identity, complete reviewed range, profile/template era, workflow run and commit, completed chunk/VOD state, frame count, detections, and retrievable screenshot checks. Validate source-relative timestamps, especially nonzero starts and Bilibili part timelines. Compare against prior known detections without presenting sample agreement as exhaustive recall.

The original source branch observed both successful and blocked Bilibili uploader feeds from the local machine. That proves feasibility for specific feeds from that network, not sustained GitHub-runner reliability.

On 2026-09-07, [bounded hosted ingestion run 34152338750](https://github.com/liftaris/bazaar-ghost/actions/runs/34152338750) completed a YouTube account poll and queued forty video-readiness candidates, while both enrolled Bilibili uploader feeds failed. All three leases finished and the failed account jobs retained their retry state; the workflow correctly reported failure for the partial outage and dispatched no OCR. Independent bounded local probes reproduced HTTP 412 for UID 2561817 and Bilibili JSON code −352 for UID 2663423 with yt-dlp 2026.08.19. JSON −352/−401 are provider rejection codes, not HTTP statuses or evidence of expired user credentials. The feed URLs match the maintained extractor. Successful individual-video playback does not establish uploader-feed availability.

Automatic Bilibili uploader polling is therefore access-limited in the current environment. Reviewed BV/CID cataloging and processing of accessible individual recordings remain usable. YouTube individual-video extraction has separately requested human sign-in from GitHub-hosted runners; the successful full-recording validation used disposable self-hosted GitHub Actions runners. Diagnostic improvements preserve these limitations explicitly. Evidence: `.ignore/feed-evidence/README.md` and `.ignore/platform-validation/ingestion-34152338750/`.

Operational state includes due-job age, attempts, last error, per-tab progress, subscription confirmation, and lease expiry. Useful alerts include overdue work, repeated feed failures, unconfirmed/expired subscriptions, and no candidate growth despite active creators. A Grafana dashboard package for these new fields has not been added.
