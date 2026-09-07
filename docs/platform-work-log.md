# Cloudflare platform integration and validation

## Objective and boundaries

Integrate the multiplatform backend from thread `01a07a18-dac2-7571-993b-3c00d035afd7` into the Cloudflare migration, deploy and validate a dedicated environment, then implement backend user authentication and clip likes, comments, and favorites. OCR and all workflow execution remain in GitHub Actions. Existing production and the separate frontend repository must remain untouched.

Work branch: `codex/cloudflare-validation`, starting at migration commit `6a6d0ae`. Reviewed source platform commits: `c7c3863` and `ec4b870` on `dev`. The first integrated platform commit is `2923d2a`.

## Execution plan

- [x] Review source multiplatform changes, record defects and port contracts.
- [x] Integrate platform identity, catalog/discovery/archive ingestion, media resolution, verified appearances, webhook handling, and search into Workers/D1/GitHub workflows. Initial integration committed as `2923d2a`; review fixes continue locally.
- [ ] Validate the integrated pipeline locally with platform-specific tests and real OCR processing.
- [x] Provision separate Cloudflare resources and GitHub environment, with branch-bound deployment and processing workflows.
- [ ] Deploy only the validation environment and run hosted API, queue, database, storage, and GitHub processing checks; correct and redeploy failures.
- [ ] Design and implement user authentication, sessions, account lifecycle, and clip identity.
- [ ] Implement likes, comments, favorites, ownership, moderation, and abuse controls, with public/private API contracts.
- [ ] Adversarially review implementation and tests; address findings and validate hosted functionality.
- [ ] Publish operational documentation, API examples, deployment/test evidence, and a requirement-by-requirement completion audit.

## Verification requirements

Completion requires authoritative evidence for every plan item, including actual isolated hosted deployment and GitHub jobs. Local mocks do not prove provider permissions or live media access. Authentication must verify identity through a real supported flow; test identities must never become a deployed authentication bypass. Likes and favorites must be idempotent and distinct; comments must enforce author/moderator authorization. No browser client receives admin or processor credentials.

Production safeguards: no pushes to `main`/`dev`, no production/development resource mutations, no changes to existing provider callbacks, no real notification delivery from validation, and no broad repository rule changes when branch/environment-scoped controls suffice. New resources must have distinct names and identifiers. Keep test evidence free of credentials and personal data.

## Activity

### 2026-09-07 — initial inspection

- Confirmed clean migration worktree at `6a6d0ae`; main checkout is `dev` at `ec4b870`.
- Created dedicated local validation branch without changing the original checkout.
- Started independent source review, environment isolation review, and auth design/adversarial review agents.
- At initial inspection the Cloudflare migration had local/development/production templates only; the isolated environment was subsequently provisioned and deployed as recorded below.

## Decisions and evidence

The activity entries below distinguish the committed/deployed baseline, local follow-up work, and unfinished requirements. Test and deployment success alone do not establish end-to-end provider processing.

### 2026-09-07 — integration and isolation

- Ported independent YouTube/Bilibili creator identities, stable BV/CID parts, source-aware processing/profile/template context, separate public platform search, and reviewed appearance groups into D1/Workers.
- Kept public Twitch views scoped to Twitch, and fenced Twitch availability/chat jobs so they cannot misclassify other platforms.
- Ported catalog/discovery/archive runners and Streamlink/yt-dlp media adapters to the explicit catalog/processor HTTP APIs; OCR stays in GitHub Docker jobs.
- Replaced PostgreSQL locks with transactional D1 assertions. Independent tests reproduced concurrent timeline edits, account disables, and expired jobs; planning now checks the current timeline and active lease within its write transaction.
- Added namespace-aware signed YouTube WebSub handling, atomic receipt/job persistence, per-account lifetime replay digests, and optional hub renewal in the Worker.
- Found and fixed an additive schema watermark issue: the VOD table rebuild must preserve deleted-ID AUTOINCREMENT history as well as current rows.
- Provisioned only new validation resources: Worker name `bazaarghost-validation`; D1 `4159adb1-b0af-4a3e-9a0c-755dfe5d822c`; R2 `bazaarghost-validation-detections` and `bazaarghost-validation-logs`; Queues `bazaarghost-validation-jobs` and `bazaarghost-validation-dlq`.
- Created GitHub environment `validation`, restricted to `codex/cloudflare-validation`; configured its independent processor/catalog credentials and backend URL. Existing dev/production environments, callbacks, and resources were not changed.
- Validation endpoint: `https://bazaarghost-validation.kaio-8df.workers.dev`. The initial deployment is recorded below.
- A dedicated branch pipeline tests and optionally deploys the exact commit. A durable validation-scoped Cloudflare API token for unattended GitHub deployment is not yet configured; the authenticated local Wrangler CLI can deploy the validation environment meanwhile.

Review evidence: `.ignore/multiplatform-review.md`, `.ignore/environment-review.md`, `.ignore/platform-upgrade-review/evidence.json`, `.ignore/auth-design.md`. Resource evidence: `.ignore/platform-validation/provisioning.json`. Local evidence is distinct from the hosted observations below.

### 2026-09-07 — first isolated deployment and runner checks

- Committed and pushed `2923d2a` to `codex/cloudflare-validation`, then deployed that commit to the validation Worker. Public `/health` returned HTTP 200 with `environment=validation` and `build_commit=2923d2a…`.
- [Validation CI run 34145737889](https://github.com/liftaris/bazaar-ghost/actions/runs/34145737889) passed **98 SFDE/OCR tests, 78 Worker tests, and 61 script tests** on `2923d2a`. Its deployment job completed but skipped actual deployment steps because the dedicated Cloudflare CI token is not configured. The first Worker deployment instead used the authenticated local Wrangler CLI; unattended GitHub deployment remains pending that token.
- [YouTube catalog run 34146038610](https://github.com/liftaris/bazaar-ghost/actions/runs/34146038610) and [run 34146040402](https://github.com/liftaris/bazaar-ghost/actions/runs/34146040402) failed at the Python HTTP health preflight with HTTP 403 / Cloudflare 1010. Those runs did not reach provider cataloging or OCR. A browser-accessible health endpoint does not yet prove runner access.
- No hosted VOD has completed the catalog → GitHub OCR → D1/R2 path in this migration environment. Validation remains configured with outbound integrations disabled and no Cron schedules.
- Local follow-up changes are not part of deployed `2923d2a`: populated multiplatform snapshot export/import, additional scheduling/atomicity/search fixes, and the additive platform-contract migration. The snapshot tooling has passed local tests and a synthetic populated D1 import; it has not exported or imported hosted data.
- Review also identified a clean early FFmpeg end-of-file path which could mark an incompletely sampled chunk completed. Its correction remains in progress. Hosted acceptance must check expected sampled-frame coverage (for example, 450 frames for a 900-second range at 0.5 FPS), terminal states, persisted detections, and retrievable screenshots together.
- User authentication, sessions, likes, comments, and favorites are not implemented yet. An auth design has been reviewed and the Better Auth dependency has been added locally; this is preparatory work, not a working login or social API.

### 2026-09-07 — independent Worker contract review

- Reproduced and fixed three integration regressions with real local D1: ordinary YouTube appearances lost their populated `source_video_id`; a source disappearing between grouped-search reads could return an inconsistent group or throw; enabling a previously disabled historical catalog left its unplanned recordings invisible to the ingestion dispatcher. The source identity correction is additive migration `0003_platform_contracts.sql`; deployed migration `0002` remains unchanged.
- Account creation/enablement and durable account-poll scheduling now commit in one fenced transaction. Failure-injection tests lose the database response after commit and verify an enabled account still has its polling job. Automatic rediscovery continues to preserve operator disables.
- Both schedulers share bounded, due-work selection. Future-scheduled chunks do not crowd out ready recordings; default non-Twitch priority remains below Twitch and explicit chunk priorities take precedence. Reservation rechecks current enablement, availability, readiness, and schedule before publishing any GitHub work.
- Group selection and appearance aggregation use one SQL snapshot while preserving public response names and fields.
- Validation: `npm run typecheck`, `git diff --check`, and the complete local Workers/D1 suite passed: **86 tests across 7 files**, including **8 independent contract regression tests**. These are local runtime checks; hosted completion evidence is recorded separately by the deployment work.
- Additional review work identified that successful nonempty decoding did not prove coverage of the requested chunk. A separate media regression/fix is in progress; successful status alone must not be treated as end-to-end coverage evidence.

### 2026-09-07 — runner access and second platform revision

- Reproduced Cloudflare 1010 with urllib's generic default User-Agent. Added a truthful BazaarGhost application User-Agent to the no-redirect backend clients; the actual Python `/health` preflight now succeeds against validation before credentials are sent. Deployment health and dev storage clients share the corrected transport.
- Added reviewed-range input to the Bilibili workflow. This permits source-relative bounded smoke runs instead of cataloging an entire submission by accident.
- Reviewed Worker fixes pass 86 tests: one-snapshot appearance groups, source-video identity fallback, atomic account/poll scheduling, old unplanned catalog eligibility, due-time/priority selection, and disable-before-reservation checks.
- Updated populated snapshot support through platform migration 0003; auth/session migration remains explicitly excluded. The current script suite passes 76 tests and the targeted Docker persistence suite passes 5 tests.
- A real FFmpeg reproduction confirmed clean early EOF could incorrectly complete a partially decoded chunk. Coverage validation and regression tests are in progress; no hosted completion will be accepted from status alone.

### 2026-09-07 — decoded range coverage

- Reproduced a false completion with actual FFmpeg: a six-second MP4 requested as `[0,30)` returned exit code 0, emitted samples at 0/2/4 seconds, and the old runner marked the thirty-second chunk completed with only three frames.
- The decoder now verifies its first sample starts at the requested offset, successive sampled PTS values are continuous at the configured rate, and every sampling tick in the requested half-open range is present. Success also requires all decoded samples to pass through frame processing. Clean early EOF, a shifted start, missing samples, and duplicate timestamps fail the chunk instead of writing completed.
- Moved FFmpeg's duration limit to input reading because an output duration rounds to the encoder's coarse sampled time base. The documented `fps` filter `eof_action=pass` preserves a legitimate final partial sampling interval, allowing the expected count to be `ceil(duration * frame_rate)` rather than accepting a missing last tick. Sampling remains discrete; this verifies the sampled timeline, not exhaustive visual recall or the authenticity of upstream frames.
- Successful structured logs, returned results, and exported detection summaries include requested bounds, first/last sample timestamps, interval, expected minimum samples, and decoded sample count. Hosted audits can compare these with processed frames and persisted detections.
- Validation: **113 offline OCR tests passed in 69.71 seconds**, including **34 pipeline/media tests**. Real local MP4/HLS cases cover clean early EOF, a six-second source requested as seven seconds, nonzero and between-segment seeks, complete odd-length recordings, a one-second final range, and several sampling rates. `py_compile` and `git diff --check` also passed. Runtime source and test mounts included the current parent-owned backend/media client changes; the earlier cached Docker image alone does not contain this final source. Local evidence: `.ignore/cloudflare-platform-coverage-tests.log`.

FFmpeg reference: https://ffmpeg.org/ffmpeg-filters.html#fps and https://ffmpeg.org/ffmpeg.html (input duration option).
