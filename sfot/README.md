# SFOT Processor

Streamlined SFOT (Streamlink → FFmpeg → OpenCV → Tesseract) pipeline for processing Twitch VODs.

## Architecture

Single Python orchestrator managing the complete pipeline:

- **Streamlink**: Fetches VOD segments
- **FFmpeg**: Extracts keyframes
- **OpenCV**: Detects matchup screens
- **Tesseract**: Extracts usernames via OCR

## Quick Start

### Local Development

```bash
# Install dependencies
pip install -r requirements.txt

# Run processor
python src/sfot.py <vod_id> <start_time> <end_time>

# Or use environment variables
export VOD_ID=123456789
export START_TIME=0
export END_TIME=1800
python src/sfot.py
```

### Docker

```bash
# Build container
./build.sh

# Run with docker-compose
docker-compose run --rm sfot

# Or run directly
docker run --rm \
  -e SUPABASE_URL="your-url" \
  -e SUPABASE_SERVICE_ROLE_KEY="your-key" \
  -e VOD_ID="123456789" \
  -e START_TIME="0" \
  -e END_TIME="1800" \
  ghcr.io/bazaar-ghost/sfot:latest
```

## Configuration

Edit `config.yaml` to adjust:

- Frame processing rate
- Detection thresholds
- Resource limits
- Batch sizes

## Environment Variables

- `SUPABASE_URL`: Supabase project URL
- `SUPABASE_SERVICE_ROLE_KEY`: Service role key for Supabase
- `VOD_ID`: Twitch VOD ID to process
- `START_TIME`: Start time in seconds
- `END_TIME`: End time in seconds

## Monitoring

The processor outputs structured JSON logs with:

- Processing metrics
- Health status
- Error tracking
- Performance data

## Performance

- Processes ~360 frames per 30-minute chunk (1 frame/5s)
- Memory usage: ~300-400MB
- CPU usage: ~30-50%
- Network: Minimal (batch updates every 20s)
