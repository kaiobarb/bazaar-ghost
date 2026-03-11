# SFOT Processor

SFOT (Streamlink -> FFmpeg -> OpenCV -> OCR) is the computer vision pipeline that processes Twitch VOD chunks to detect matchup screens and extract opponent usernames.

## Architecture

The `SFOTProcessor` class in `src/sfot.py` orchestrates 4 parallel threads connected by queues:

1. **Streamlink** -- Downloads a VOD segment via HLS, pipes the stream to stdout
2. **FFmpeg** -- Reads the piped stream, applies a crop region from the SFOT profile, extracts JPEG frames at 0.5 FPS (1 frame every 2 seconds)
3. **OpenCV** -- Detects rank emblems via template matching, finds nameplate right edges, then runs PaddleOCR to extract the opponent username
4. **Results** -- Batches detections, uploads frame screenshots to Supabase Storage, and inserts detection records into the database

### Detection pipeline detail

Each frame goes through three stages in `src/frame_processor.py`:

1. **Emblem detection** (`src/emblem_detector.py`) -- Template matches against rank badge images (bronze, silver, gold, diamond, legend) at the configured resolution. A match indicates a matchup screen is present.
2. **Right edge detection** (`src/right_edge_detector.py`) -- Locates the right boundary of the opponent's nameplate to crop the OCR region precisely, handling camera overlays that partially occlude the nameplate.
3. **PaddleOCR** -- Runs text recognition on the cropped nameplate region to extract the opponent's username.

### Template images

The `templates/` directory contains ~38 template images:

- **Rank emblems** at multiple resolutions (360p, 480p, 720p, 1080p, fullres) for each rank
- **Old templates** (prefixed with `_`) for VODs published before Aug 12, 2025, when The Bazaar used smaller UI elements
- **Right edge templates** at each resolution for nameplate boundary detection

## Running locally

SFOT runs as a Docker container. It takes a **chunk ID** (a UUID referencing a row in the `chunks` table) and processes that 30-minute VOD segment.

### Prerequisites

- Docker
- A running Supabase instance (local or remote) with seeded data
- A `.env.dev` file in the project root (see root README)

### Build and run

```bash
# From the project root
docker build -t sfot:dev sfot/

# Process a specific chunk
docker run --rm --network host \
  --env-file .env.dev \
  -e CHUNK_ID=<chunk-uuid> \
  -e QUALITY=480p \
  sfot:dev
```

### Build with the helper script

```bash
cd sfot
./build.sh          # Build + tag for GHCR
./build.sh --push   # Build + push to GHCR
```

### Run without Docker

```bash
cd sfot
pip install -r requirements.txt

# Set environment variables (or use .env.local which is auto-loaded)
export SUPABASE_URL=http://localhost:54321
export SUPABASE_SECRET_KEY=<your-key>
export CHUNK_ID=<chunk-uuid>

python src/sfot.py
# Or: python src/sfot.py <chunk-uuid>
```

## Environment Variables

| Variable                      | Required | Default      | Description                                                  |
| ----------------------------- | -------- | ------------ | ------------------------------------------------------------ |
| `CHUNK_ID`                    | Yes      | --           | UUID of the chunk to process (can also be passed as CLI arg) |
| `SUPABASE_URL`                | Yes      | --           | Supabase API URL                                             |
| `SUPABASE_SECRET_KEY`         | Yes      | --           | Supabase secret key                                          |
| `QUALITY`                     | No       | `480p`       | Stream quality to download (480p, 720p, 1080p, etc.)         |
| `OLD_TEMPLATES`               | No       | `false`      | Use old (smaller) template images for pre-Aug-2025 VODs      |
| `VIDEO_FPS`                   | No       | `30`         | Source video FPS (30 or 60)                                  |
| `SFOT_PROFILE`                | No       | --           | JSON string with crop region, scale, and edge settings       |
| `TEST_MODE`                   | No       | `false`      | Use local test files instead of downloading from Twitch      |
| `ENVIRONMENT`                 | No       | `production` | Environment name (for telemetry tagging)                     |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | No       | --           | OpenTelemetry collector endpoint                             |
| `OTEL_EXPORTER_OTLP_HEADERS`  | No       | --           | OpenTelemetry auth headers                                   |

## SFOT Profiles

Each streamer can have a custom SFOT profile that defines:

- **Crop region** -- Where the opponent nameplate appears on screen (varies by streamer overlay)
- **Scale** -- Scaling factor for the crop region
- **Edge settings** -- Custom right-edge detection parameters for streamers with camera overlays that partially cover the nameplate

The default profile (id=1) works for most streamers. Custom profiles are stored in the `sfot_profiles` table and passed to the container as the `SFOT_PROFILE` environment variable (a JSON string).

## Configuration

Processing parameters are in `config.yaml`:

| Section                | Key Parameters                                               |
| ---------------------- | ------------------------------------------------------------ |
| `processing`           | `frame_rate: 0.5` (1 frame/2s), `timeout: 1800` (30 min max) |
| `detection`            | `threshold: 0.78` (template matching confidence)             |
| `emblem_detection`     | `template_threshold: 0.5`, method: `TM_CCOEFF_NORMED`        |
| `right_edge_detection` | `threshold: 0.7`, `crop_margin_percent: 5`                   |
| `streamlink`           | Default `480p`, fallback to `360p`/`worst`                   |
| `resources`            | `max_memory_mb: 512`, `max_cpu_percent: 50`                  |

## Monitoring

SFOT emits:

- **Structured JSON logs** via `src/json_logger.py` with processing metrics, health status, and error tracking
- **OpenTelemetry traces and metrics** via `src/telemetry.py` when `OTEL_EXPORTER_OTLP_ENDPOINT` is configured
