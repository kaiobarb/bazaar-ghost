#!/bin/bash
source .env

# Inputs
STREAM_URL="$1"        # Twitch VOD URL
VOD_ID="$2"            # VOD ID
VOD_ISO_TIMESTAMP="$3" # VOD Start Time (ISO 8601)

# Convert ISO 8601 to Unix timestamp
VOD_TIMESTAMP=$(date -d "$VOD_ISO_TIMESTAMP" +%s)

# Set up tmpfs directories
VOD_DIR="$TMPFS_DIR/$VOD_ID"
FRAME_DIR="$VOD_DIR/frames"
MATCHUP_DIR="$VOD_DIR/matchups"
mkdir -p "$FRAME_DIR" "$MATCHUP_DIR"

echo "$VOD_DIR"

# Update metadata (start)
curl -s -X PATCH "$SUPABASE_URL/rest/v1/metadata?vod_id=eq.$VOD_ID" \
  -H "apikey: $SUPABASE_SERVICE_ROLE" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE" \
  -H "Content-Type: application/json" \
  -d '{
    "started_at": "'$(date -u +"%Y-%m-%dT%H:%M:%SZ")'",
    "status": "partial"
  }'

echo "Capturing frames from $STREAM_URL (VOD ID: $VOD_ID, Start: $VOD_TIMESTAMP)"

# Streamlink → FFmpeg → Save frames to tmpfs
VF="crop=271:54:503:352,fps=0.2"
  streamlink --default-stream 480p "$STREAM_URL" -O | \
    ffmpeg -skip_frame nokey -i pipe:0 -vf $VF -frame_pts true -r 0.2 -f image2 "$FRAME_DIR/${VOD_ID}_${VOD_TIMESTAMP}_%06d.png"

echo "Finished processing VOD: $VOD_ID"
