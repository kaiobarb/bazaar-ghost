# Bazaar Ghost

System for indexing The Bazaar VODs from Twitch - detects matchups and extracts usernames via OCR.

## Setup

### Prerequisites

- Python 3.11+
- Supabase CLI
- Docker (optional)
- Streamlink, FFmpeg, Tesseract installed locally

### Start Supabase

```bash
supabase start
```

### Environment Variables

Create `.env` in project root:

```bash
# Required
SUPABASE_URL=http://localhost:54321
SUPABASE_SERVICE_ROLE_KEY=<from supabase start output>

# Optional
TWITCH_CLIENT_ID=<your-client-id>
TWITCH_CLIENT_SECRET=<your-client-secret>
```

## Running SFOT Processor

### Install dependencies

```bash
cd sfot
pip install -r requirements.txt
```

### Run processor

```bash
python src/sfot.py <vod_id> [start_time] [end_time]

# Example: Process first hour of VOD 123456789
python src/sfot.py 123456789 0 3200
```

### Run with Docker

```bash
cd sfot
docker-compose up
```

## Configuration

Edit `sfot/config.yaml`:

```yaml
processing:
  frame_rate: 0.2 # Frames per second to extract
  queue_size: 10
  timeout: 3200
  batch_update_interval: 20

detection:
  threshold: 0.78 # Template matching threshold
  crop_region: [271, 54, 503, 352] # w, h, x, y for nameplate
  template_path: "templates/matchup_template.png"

streamlink:
  default_stream: "480p"
  retry_attempts: 3

tesseract:
  lang: "eng"
  config: "--psm 8 --oem 3"
```

## Storage

Detection images stored in Supabase Storage:

- Full color nameplate: `{vod_id}/{timestamp}.jpg`
- OCR debug frame: `{vod_id}/ocr_debug/{timestamp}.jpg`
