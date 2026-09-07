# Application snapshots for Cloudflare

These tools migrate the backend application data through `0003_platform_contracts.sql`. They do not export Supabase Auth users, browser sessions, or the new auth layer. A snapshot containing unknown tables or columns stops conversion for review.

Pause source cataloging, ingestion, scheduled processing and notification delivery; drain active jobs before a final export. PostgREST pagination cannot provide a cross-table transactional snapshot. The exporter makes only read requests and refuses redirects, so project credentials cannot be forwarded to a different origin.

With `SUPABASE_URL` and `SUPABASE_SECRET_KEY` already supplied in the environment:

```sh
python scripts/migration/export_supabase.py .ignore/source-snapshot
python scripts/migration/convert.py .ignore/source-snapshot .ignore/d1-import
```

Both commands require new output directories. Output directories have mode `0700`; JSONL, SQL, manifests and the intermediate SQLite database have mode `0600`. The source WebSub table contains callback capabilities and signing secrets. Keep raw snapshots private even after conversion.

The snapshot manifest records every supported table as present with a row count or absent because the older source schema has no such table. A permission error, generic HTTP404, interrupted export, missing file, or row-count mismatch is an error. `sfot_profiles` and `sfot_profile_id` from the original schema are recognized. Original flat count manifests explicitly identify older snapshots; missing optional tables from those snapshots are reported in the conversion manifest. An unmanifested snapshot must contain the complete supported table set, including empty files.

Conversion applies all supported migrations in order to a private SQLite database and then loads profiles, streamer/platform identities, videos, chunks, detections, verified appearances, historical delivery state, ingestion jobs and WebSub state in dependency order. It validates foreign keys, constraints and chunk overlap before emitting SQL. Source timestamps normalize to UTC with millisecond precision; this preserves actual instants when D1 compares timestamp strings. Video IDs, recorded dates, Bilibili BV/CID identities and part order, processing settings, cursors, job state, and screenshot keys remain represented.

Any processing/queued chunk, processing ingestion job, or retained ingestion lease prevents conversion, even if the lease has already expired. Drain or explicitly resolve those jobs in the source before taking a new snapshot; the converter does not decide whether unfinished work succeeded.

Imported notification outbox rows are marked sent, and historical Twitch detections receive sent outbox records. Importing history does not create a notification backlog. Delivery receipts and WebSub body-digest tombstones are retained.

WebSub callback tokens and signing secrets are **rotated during conversion**. The generated database and SQL contain new random capabilities; original capabilities are not copied into the target. All imported subscription request, confirmation, and expiry fields are cleared. A subscription must be renewed for the target environment before any notification can be accepted. This is recorded in the manifest and in each subscription's status text. Keep `OUTBOUND_ENABLED=false` and scheduled/catalog jobs paused until you have reviewed the target hostname, provider configuration, and processing settings. Renew subscriptions only after that review; the converter never calls the hub.

Apply the supported D1 schema migrations to a fresh target before importing. The first import statement refuses a nonempty application database before changing any triggers. Import the numbered `import-0001.sql` parts in order; each part ends at a complete SQL statement and normally stays below 4 MB. A single larger statement remains whole. The complete `import.sql` is also available. Resume a partially imported database only with an explicit checkpoint review; rerunning the whole import is deliberately refused.

For the dedicated validation environment, inspect the actual bound database and pass deployment preflight before any remote import:

```sh
python scripts/deployment_check.py validation --ref refs/heads/codex/cloudflare-validation
```

Verify output table counts against `manifest.json`, run `PRAGMA foreign_key_check`, inspect source-specific video/search results and stored screenshot objects, and confirm there are no pending historical notification records. Database import does not copy R2/storage objects. No source export or hosted import is performed automatically by tests or deployment.

The converter deliberately stops at schema version 3 until an explicit user/auth migration contract exists. The current tests exercise populated Twitch/YouTube/Bilibili snapshots, cross-platform appearances, paused ingestion state, capability rotation, private file permissions, deleted-ID sequence preservation in the additive D1 migration, and rejection paths.
