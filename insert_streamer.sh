#!/bin/bash

source .env

USERNAME="$1"

if [ -z "$USERNAME" ]; then
  echo "Usage: $0 <twitch_username>"
  exit 1
fi

# Fetch user data from Twitch
RESPONSE=$(twitch api get users -q login="$USERNAME")

# Parse the data
USER_ID=$(echo "$RESPONSE" | jq -r '.data[0].id')
DISPLAY_NAME=$(echo "$RESPONSE" | jq -r '.data[0].display_name')
PROFILE_IMAGE_URL=$(echo "$RESPONSE" | jq -r '.data[0].profile_image_url')

if [ -z "$USER_ID" ] || [ "$USER_ID" == "null" ]; then
  echo "Streamer not found or Twitch API failed."
  exit 1
fi

echo "Inserting $DISPLAY_NAME into Supabase..."

# Insert into Supabase
curl -s -X POST "$SUPABASE_URL/rest/v1/streamers" \
  -H "apikey: $SUPABASE_SERVICE_ROLE" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE" \
  -H "Content-Type: application/json" \
  -H "Prefer: resolution=merge" \
  -d '{
    "id": '"$USER_ID"',
    "name": "'"$USERNAME"'",
    "display_name": "'"$DISPLAY_NAME"'",
    "profile_image_url": "'"$PROFILE_IMAGE_URL"'"
  }'
echo
echo "Inserted new streamer $DISPLAY_NAME ID: $USER_ID"
