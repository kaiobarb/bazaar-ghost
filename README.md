# Bazaar Ghost

Bazaar Ghost indexes Twitch VODs for [The Bazaar](https://www.thebazaar.gg/), detects matchup screens via computer vision, extracts opponent usernames, and makes them searchable at [bazaarghost.stream](https://bazaarghost.stream).

## How It Works

When a streamer goes offline on Twitch, Bazaar Ghost automatically:

1. **Discovers streamers** playing The Bazaar via Twitch chapter metadata
2. **Splits VODs** into 30-minute chunks for parallel processing
3. **Runs SFDE** (Stream Filter Detect Extract) on each chunk to detect matchup screens and extract opponent usernames
4. **Stores results** in a searchable database with frame screenshots

Users can then search for their username on [bazaarghost.stream](https://bazaarghost.stream) to find VODs where they appeared as an opponent.

## Architecture

```
                    Twitch EventSub
                         |
                         v
              +---------------------+
              |   Supabase Edge     |
              |     Functions       |
              | (streamer discovery |
              |  VOD cataloging,    |
              |  webhook handling)  |
              +---------------------+
                         |
                         v
              +---------------------+
              |   GitHub Actions    |
              |  (orchestration &   |
              |   parallel chunks)  |
              +---------------------+
                         |
                         v
              +---------------------+
              |   SFDE Container    |
              |  Streamlink->FFmpeg |
              |  ->OpenCV->PaddleOCR|
              +---------------------+
                         |
                         v
              +---------------------+
              |  Supabase Postgres  |
              |  + Storage          |
              +---------------------+
                         |
                         v
              +---------------------+
              |  bazaarghost.stream |
              |     (frontend)      |
              +---------------------+
```

**Control Plane** -- Supabase Edge Functions (Deno/TypeScript) in `supabase/functions/` handle streamer discovery, VOD cataloging, Twitch EventSub webhooks, Discord bot commands, and GitHub Actions orchestration.

**Data Plane** -- The SFDE Python container in `sfde/` processes individual 30-minute VOD chunks: downloads the stream segment via Streamlink, extracts frames with FFmpeg, detects matchup screens with OpenCV template matching, and reads usernames with PaddleOCR.

**Database** -- Supabase PostgreSQL stores streamers, VODs, chunks, detections, and user notification subscriptions. Migrations live in `supabase/migrations/`.

**Observability** -- OpenTelemetry traces, metrics, and logs ship to Grafana Cloud from both Edge Functions and the SFDE container.

## Project Structure

```
supabase/
  functions/
    _shared/                    # Shared: Supabase client, Twitch API, CORS, telemetry
    insert-new-streamers/       # Discovers streamers from recent Bazaar VODs
    update-vods/                # Fetches VODs with chapter data for a streamer
    process-vod/                # Handles EventSub webhooks, triggers GitHub Actions
    trigger-github-processing/  # Dispatches GitHub Actions workflows
    check_vod_availability/     # Checks if a Twitch VOD is still accessible
    get_vods_from_streamer/     # Returns VODs for a given streamer
    schedule-vod-processing/    # Schedules VOD processing runs
    search-chat-mentions/       # Searches Twitch chat mentions
    ghost-bot/                  # Discord bot (/search, /notify, /list, /setchannel, /help)
    generate-seed/              # Generates seed SQL
    generate-seed-data/         # Generates seed data
  migrations/                   # PostgreSQL migrations
  config.toml                   # Supabase project config
sfde/
  src/
    sfde.py                     # Main orchestrator (4 parallel threads)
    frame_processor.py          # PaddleOCR + emblem detection + right edge detection
    emblem_detector.py          # Template-matching rank emblem detection
    right_edge_detector.py      # Right edge detection for nameplate boundaries
    supabase_client.py          # DB/storage client for chunk lifecycle
    telemetry.py                # OpenTelemetry instrumentation
    json_logger.py              # JSON structured logging
  templates/                    # ~38 template images (rank emblems + right edges)
  config.yaml                   # Processing parameters
  Dockerfile                    # SFDE container definition
  docker-compose.yml            # Local Docker Compose config
  build.sh                      # Build + tag for GHCR
  requirements.txt              # Python dependencies
scripts/
  seed-from-prod.sh             # Generate seed.sql from production data
  sync-prod-to-dev.sh           # Full prod-to-dev database sync
  clear-detections-bucket.ts    # Clear Supabase storage bucket (Deno)
.github/workflows/
  process-vod.yml               # Main: fetches chunks, runs SFDE matrix over them
  process-chunk.yml             # Single chunk processing
  deploy-functions.yml          # Auto-deploy Edge Functions on push to main/dev
  deploy-migrations.yml         # Auto-deploy migrations on push to main/dev
  sync-discord-commands.yml     # Sync Discord bot slash commands
```

## Prerequisites

- [Supabase CLI](https://supabase.com/docs/guides/cli/getting-started) (v2+)
- [Docker](https://docs.docker.com/get-docker/) (for running SFDE locally)
- [Deno](https://deno.land/) (for Edge Function development -- installed automatically by Supabase CLI)
- A Twitch developer application ([dev.twitch.tv](https://dev.twitch.tv/console/apps)) for API access

## Local Development

### 1. Clone and start Supabase

```bash
git clone https://github.com/kaiobarb/bazaar-ghost.git
cd bazaar-ghost

# Start local Supabase (Postgres, Auth, Storage, Edge Functions)
supabase start
```

The `supabase start` output will print your local API URL and keys. The local database is seeded automatically from `supabase/seed.sql` if present.

### 2. Environment variables

Create a `.env.dev` file in the project root:

```bash
# Supabase (from `supabase start` output)
SUPABASE_URL=http://localhost:54321
SUPABASE_SECRET_KEY=<service_role key from supabase start>

# Twitch API (required for streamer discovery and VOD fetching)
TWITCH_CLIENT_ID=<your-twitch-client-id>
TWITCH_CLIENT_SECRET=<your-twitch-client-secret>

# Optional: Grafana Cloud (for OpenTelemetry)
OTEL_EXPORTER_OTLP_ENDPOINT=<your-otlp-endpoint>
OTEL_EXPORTER_OTLP_HEADERS=<your-otlp-auth-header>
```

### 3. Reset the database (apply migrations + seed)

```bash
supabase db reset
```

### 4. Invoke Edge Functions locally

```bash
curl -i --location --request POST 'http://localhost:54321/functions/v1/<function-name>' \
  --header "Authorization: Bearer <SUPABASE_SECRET_KEY>" \
  --header 'Content-Type: application/json' \
  --data '{"key": "value"}'
```

### 5. Run SFDE locally

See `sfde/README.md` for full details. The quick version:

```bash
# Build the SFDE container
docker build -t sfde:dev sfde/

# Run a chunk (requires a valid chunk_id in the database)
docker run --rm --network host \
  --env-file .env.dev \
  -e CHUNK_ID=<chunk-uuid> \
  -e QUALITY=480p \
  sfde:dev
```

SFDE takes a `CHUNK_ID` (a UUID referencing a row in the `chunks` table) and processes that 30-minute segment. It connects to Supabase for chunk metadata, uploads detection frames to Storage, and writes results back to the database.

## Database

The database schema is managed via migrations in `supabase/migrations/`. Core tables:

| Table | Description |
|---|---|
| `streamers` | Twitch streamers being tracked |
| `vods` | Individual VODs with chapter metadata and availability status |
| `chunks` | 30-minute processing units within a VOD |
| `detections` | Matchup screen detections with extracted usernames and timestamps |
| `sfde_profiles` | Per-streamer crop regions and processing parameters |
| `notification_subscriptions` | Discord notification subscriptions |
| `server_channels` | Discord server/channel configuration |

Create new migrations with the Supabase CLI:

```bash
supabase migration new <migration_name>
# Edit the generated file in supabase/migrations/
supabase db reset  # Test locally
```

## Environments

| Environment | Branch | Supabase Project | Deploys |
|---|---|---|---|
| Development | `dev` | Dev (free tier) | Auto on push |
| Production | `main` | Prod (Pro tier) | Auto on push |

Pushing to `dev` or `main` triggers GitHub Actions to auto-deploy Edge Functions and apply migrations to the corresponding Supabase project.

## Contributing

Contributions are not yet being accepted while the project is being set up for external development. Stay tuned.

## License

Not yet licensed. All rights reserved.
