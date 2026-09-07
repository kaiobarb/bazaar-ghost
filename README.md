# BazaarGhost

BazaarGhost finds opponents in Twitch VODs of [The Bazaar](https://www.thebazaar.gg/) and makes those appearances searchable at [bazaarghost.stream](https://bazaarghost.stream). This repository contains the cataloger, processing pipeline, database, and Discord bot integration.

## Processing contract

A detection means a sampled frame contained a rank emblem and an opponent name that passed OCR validation. It includes the source VOD, absolute second, rank, OCR confidence, screenshot, truncation flags, and optional in-game day. It is not a complete match history or a claim that OCR is always correct.

1. Twitch discovery catalogs new streamers with processing **enabled** and creates their EventSub subscriptions.
2. The cataloger identifies Bazaar chapter ranges. PostgreSQL plans missing work in chunks of at most 1,800 seconds, including short tails. An empty Bazaar range list creates no work.
3. EventSub or the scheduler asks `process-vod` to dispatch pending chunks to GitHub Actions. Only available, ready VODs belonging to enabled streamers qualify.
4. Each SFDE container atomically claims one chunk. Streamlink resolves the rendition; FFmpeg seeks the HLS playlist, crops, and samples at 0.5 FPS. OpenCV detects the nameplate and PaddleOCR reads the opponent.
5. The result worker uploads screenshots before inserting detections. A chunk completes only after all frames and the final result batch drain successfully. Search RPCs hide unavailable VODs.

## Layout

| Path | Responsibility |
|---|---|
| `sfde/src/sfde.py`, `video.py` | Chunk ownership, decoder/OCR/result workers, timestamp pairing |
| `sfde/src/frame_processor.py` | Nameplate crop, OCR acceptance, duplicate suppression, optional day OCR |
| `sfde/src/*_detector.py` | Resolution-specific OpenCV template matching |
| `sfde/src/supabase_client.py` | Chunk state, screenshot persistence, retry-safe detection inserts |
| `supabase/functions/_shared/` | Twitch API, authentication, cataloging, dispatch, telemetry |
| `supabase/functions/` | Discovery, cataloging, EventSub, availability checks, Discord, maintenance endpoints |
| `supabase/migrations/` | Versioned schema and processing RPCs |
| `supabase/tests/`, `sfde/tests/`, `scripts/tests/` | Database, CV/OCR, pipeline, and workflow regressions |
| `scripts/vod_workflow.py` | Validated workflow inputs, rendition selection, failure reporting |
| `.github/workflows/` | Tests, processing, deployment, Discord command registration |

## Local development

Install Docker, Supabase CLI, and Deno. Work against local Supabase first:

```bash
supabase start
supabase db reset
supabase test db
deno check supabase/functions/*/index.ts
deno test --allow-env supabase/functions/_shared/*_test.ts
python -m unittest discover -s scripts/tests
```

`db reset` resets the local database and applies migrations plus any configured seed. Create migrations with `supabase migration new <name>`; do not create migration files manually.

For the complete offline SFDE suite, including cached OCR models and a real FFmpeg/HLS seek test:

```bash
docker build --target test -t sfde:test sfde/
docker run --rm --network none sfde:test
```

Model downloads happen during the image build. Test execution needs no network or credentials. See [SFDE usage](sfde/README.md) for a real chunk run.

Use a root `.env.dev` file for local processing. Nothing implicitly loads `.env` or another credentials file:

```dotenv
SUPABASE_URL=http://127.0.0.1:54321
SUPABASE_SECRET_KEY=<local secret or service-role key>
TWITCH_CLIENT_ID=<development application ID>
TWITCH_CLIENT_SECRET=<development application secret>
```

Optional OTLP settings are `OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_EXPORTER_OTLP_HEADERS`. Disabled or failing telemetry must not determine a processing outcome.

Internal edge endpoints validate `apikey` or bearer secret credentials in application code. `SECRET_KEY` is also accepted for hosted functions where the `SUPABASE_` prefix is reserved. EventSub and Discord requests use their provider signatures. Existing deployment uses `--no-verify-jwt`; local gateway settings are unchanged, so use a locally accepted JWT when invoking a gateway configured to verify JWTs.

## Maintenance

- `seed-from-prod.sh` requires an explicit `PROD_DB_URL`. It reads a bounded catalog snapshot into `supabase/seed.sql`, uses current column names, and disables processing in the generated seed. Storage objects are not copied.
- `sync-prod-to-dev.sh` requires explicit source/destination connections and confirmation. It imports that catalog in one transaction, preserving migration-managed schemas, roles, and Vault. Apply the same migrations to dev first. This is a catalog refresh, not a full database clone.
- `clear-detections-bucket.ts` lists files by default. `--execute` deletes them. It paginates and stops on errors. Supply `SUPABASE_URL` and `SUPABASE_SECRET_KEY` explicitly.
- `setup_test_fixtures.py` copies validated local annotations and images into the committed fixture corpus.

Production connections are unnecessary for local tests. Put experiments and generated output in `.ignore/`.

## Deployment

`dev` and `main` target development and production respectively. Existing workflows deploy changed functions and migrations when pushed. The cleanup migration must be applied before starting workers that call `claim_sfde_chunk`. Validate locally, deploy/test dev, then have the maintainer merge to main and perform production verification.

This project is not currently accepting external contributions and has no license grant; all rights reserved.
