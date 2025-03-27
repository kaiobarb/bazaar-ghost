#!/bin/bash

source .env

# TARGET_VOD_ID="2289278802" # First VOD of Kripp playing closed beta
VOD_FILE="master_vod_list.txt"
# STREAMER_ID="29795919" # nl_kripp
# STREAMER_ID="156576581" # rahresh
STREAMER_ID="1251663536" # 2sixten
SUPABASE_URL="https://gdpblyinfpkohpgiuspe.supabase.co"
SUPABASE_API_KEY="$SUPABASE_SERVICE_ROLE"

# Pagination variables
CURSOR=""
PAGE_COUNT=0

echo "Fetching VODs for streamer ID: $STREAMER_ID using Twitch CLI..."

fetch_vods() {
    local api_command="twitch api get videos -q user_id=$STREAMER_ID -q type=archive -q first=100"
    if [[ -n "$CURSOR" ]]; then
        api_command+=" -q after=$CURSOR"
    fi

    VODS_JSON=$(eval "$api_command")

    CURSOR=$(echo "$VODS_JSON" | jq -r '.pagination.cursor')

    while read -r vod; do
        VOD_ID=$(echo "$vod" | jq -r '.id')
        CREATED_AT=$(echo "$vod" | jq -r '.created_at')
        DURATION=$(echo "$vod" | jq -r '.duration')

        # Convert Twitch duration (e.g., "2h30m") to seconds
        DURATION_SEC=$(echo "$DURATION" | awk '
            {
                gsub(/h/, "*3600+");
                gsub(/m/, "*60+");
                gsub(/s/, "");
                expr = $0;
                sub(/\+$/, "", expr);
                print expr
            }' | bc)

        echo "Processing VOD: $VOD_ID ($CREATED_AT, Duration: $DURATION_SEC sec)"

        # Insert or update into Supabase
        curl -s -X POST "$SUPABASE_URL/rest/v1/vods" \
            -H "apikey: $SUPABASE_API_KEY" \
            -H "Authorization: Bearer $SUPABASE_API_KEY" \
            -H "Content-Type: application/json" \
            -H "Prefer: resolution=merge" \
            -d '{
                "vod_id": '"$VOD_ID"',
                "streamer_id": '"$STREAMER_ID"',
                "duration": '"$DURATION_SEC"',
                "date_uploaded": "'"$CREATED_AT"'"
            }'

        # Save locally
        echo "$VOD_ID $CREATED_AT" >> "$VOD_FILE"

    done < <(echo "$VODS_JSON" | jq -c '.data[]')

    [[ "$CURSOR" == "null" || -z "$CURSOR" ]] && return 1 || return 0
}

# Main fetch loop
while true; do
    PAGE_COUNT=$((PAGE_COUNT + 1))
    echo "Fetching page $PAGE_COUNT..."
    fetch_vods || break
done

echo "VOD fetching complete. Entries stored in $VOD_FILE and Supabase."