#!/bin/bash

source .env

VOD_FILE="master_vod_list.txt"
SUPABASE_URL="https://gdpblyinfpkohpgiuspe.supabase.co"
SUPABASE_API_KEY="$SUPABASE_SERVICE_ROLE"

echo "Fetching VODs with progress < 90 from Supabase..."

# Clear the file
> "$VOD_FILE"

# Fetch from Supabase
RESPONSE=$(curl -s -X GET "$SUPABASE_URL/rest/v1/vods?select=vod_id,date_uploaded,metadata(progress)&metadata.progress=lt.90" \
  -H "apikey: $SUPABASE_API_KEY" \
  -H "Authorization: Bearer $SUPABASE_API_KEY" \
  -H "Accept: application/json")

# Check if the response is valid
if [[ -z "$RESPONSE" || "$RESPONSE" == "[]" ]]; then
  echo "No VODs found with progress < 90."
  exit 0
fi

# Write to file
echo "$RESPONSE" | jq -c '.[]' | while read -r vod; do
  VOD_ID=$(echo "$vod" | jq -r '.vod_id')
  CREATED_AT=$(echo "$vod" | jq -r '.date_uploaded')

  echo "$VOD_ID $CREATED_AT" >> "$VOD_FILE"
  echo "Queued VOD: $VOD_ID ($CREATED_AT)"
done

echo "VOD fetch complete. Entries saved to $VOD_FILE."
