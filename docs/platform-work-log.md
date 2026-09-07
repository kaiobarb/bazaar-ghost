# Cloudflare platform integration and validation

## Objective and boundaries

Integrate the multiplatform backend from thread `01a07a18-dac2-7571-993b-3c00d035afd7` into the Cloudflare migration, deploy and validate a dedicated environment, then implement backend user authentication and clip likes, comments, and favorites. OCR and all workflow execution remain in GitHub Actions. Existing production and the separate frontend repository must remain untouched.

Work branch: `codex/cloudflare-validation`, starting at migration commit `6a6d0ae`. Source platform commits found locally: `c7c3863` and `ec4b870` on `dev`. Source review must verify the thread and intended behavior before integration.

## Execution plan

- [x] Review source multiplatform changes, record defects and port contracts.
- [ ] Integrate platform identity, catalog/discovery/archive ingestion, media resolution, verified appearances, webhook handling, and search into Workers/D1/GitHub workflows.
- [ ] Validate the integrated pipeline locally with platform-specific tests and real OCR processing.
- [ ] Provision separate Cloudflare resources and GitHub environment, with branch-bound deployment and processing workflows.
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
- Cloudflare migration currently has local/development/production templates only; hosted deployment remains to be performed for the new isolated environment.

## Decisions and evidence

Pending review and implementation. Record commands/results, commit IDs, workflow run IDs, deployment version IDs, outstanding provider restrictions, and resolved review findings here as work progresses. Do not store secrets in this file.

### 2026-09-07 — integration and isolation

- Ported independent YouTube/Bilibili creator identities, stable BV/CID parts, source-aware processing/profile/template context, separate public platform search, and reviewed appearance groups into D1/Workers.
- Kept public Twitch views scoped to Twitch, and fenced Twitch availability/chat jobs so they cannot misclassify other platforms.
- Ported catalog/discovery/archive runners and Streamlink/yt-dlp media adapters to the explicit catalog/processor HTTP APIs; OCR stays in GitHub Docker jobs.
- Replaced PostgreSQL locks with transactional D1 assertions. Independent tests reproduced concurrent timeline edits, account disables, and expired jobs; planning now checks the current timeline and active lease within its write transaction.
- Added namespace-aware signed YouTube WebSub handling, atomic receipt/job persistence, per-account lifetime replay digests, and optional hub renewal in the Worker.
- Found and fixed an additive schema watermark issue: the VOD table rebuild must preserve deleted-ID AUTOINCREMENT history as well as current rows.
- Provisioned only new validation resources: Worker name `bazaarghost-validation`; D1 `4159adb1-b0af-4a3e-9a0c-755dfe5d822c`; R2 `bazaarghost-validation-detections` and `bazaarghost-validation-logs`; Queues `bazaarghost-validation-jobs` and `bazaarghost-validation-dlq`.
- Created GitHub environment `validation`, restricted to `codex/cloudflare-validation`; configured its independent processor/catalog credentials and backend URL. Existing dev/production environments, callbacks, and resources were not changed.
- Intended endpoint: `https://bazaarghost-validation.kaio-8df.workers.dev`. Code deployment is still pending final integration checks at this entry.
- A dedicated branch pipeline tests and optionally deploys the exact commit. A durable validation-scoped Cloudflare API token for unattended GitHub deployment is not yet configured; the authenticated local Wrangler CLI can deploy the validation environment meanwhile.

Review evidence: `.ignore/multiplatform-review.md`, `.ignore/environment-review.md`, `.ignore/platform-upgrade-review/evidence.json`, `.ignore/auth-design.md`. Resource evidence: `.ignore/platform-validation/provisioning.json`. These are local artifacts, not hosted completion claims.
