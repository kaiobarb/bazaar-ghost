#!/bin/bash

source .env

SUPABASE_URL="https://gdpblyinfpkohpgiuspe.supabase.co"
SUPABASE_API_KEY="$SUPABASE_SERVICE_ROLE"

# Fetch all VODs from Supabase
echo "Fetching VOD IDs from Supabase..."
VODS=$(curl -s "$SUPABASE_URL/rest/v1/vods?select=vod_id" \
  -H "apikey: $SUPABASE_API_KEY" \
  -H "Authorization: Bearer $SUPABASE_API_KEY")

echo "$VODS" | jq -r '.[].vod_id' | while read -r VOD_ID; do
  echo "Fetching info for VOD ID: $VOD_ID"

  # Fetch VOD metadata from Twitch CLI
  TWITCH_DATA=$(twitch api get videos -q id=$VOD_ID)
  CREATED_AT=$(echo "$TWITCH_DATA" | jq -r '.data[0].created_at')

  if [[ "$CREATED_AT" == "null" || -z "$CREATED_AT" ]]; then
    echo "Failed to get created_at for VOD $VOD_ID"
    continue
  fi

  echo "📝 Updating VOD $VOD_ID with created_at: $CREATED_AT"

  # Update Supabase with the uploaded date
  curl -s -X PATCH "$SUPABASE_URL/rest/v1/vods?vod_id=eq.$VOD_ID" \
    -H "apikey: $SUPABASE_API_KEY" \
    -H "Authorization: Bearer $SUPABASE_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"date_uploaded\": \"$CREATED_AT\"}" > /dev/null
done

echo "Finished updating all VODs with upload dates."
