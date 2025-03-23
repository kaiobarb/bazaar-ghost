#!/bin/bash

source .env

TARGET_VOD_ID="2289278802" # First VOD of Kripp playing closed beta
VOD_FILE="master_vod_list.txt"
STREAMER_ID="29795919" # nl_kripp
SUPABASE_URL="https://gdpblyinfpkohpgiuspe.supabase.co"
SUPABASE_API_KEY="$SUPABASE_SERVICE_ROLE"

# Pagination variables
CURSOR=""
FOUND_TARGET=false
PAGE_COUNT=0

echo "Fetching VODs for streamer ID: $STREAMER_ID"

# Function to fetch VODs and update Supabase
fetch_vods() {
    local url="https://api.twitch.tv/helix/videos?user_id=$STREAMER_ID&type=archive&first=100"
    if [[ -n "$CURSOR" ]]; then
        url+="&after=$CURSOR"
    fi

    VODS_JSON=$(curl -s -H "Authorization: Bearer $TWITCH_ACCESS_TOKEN" \
                      -H "Client-Id: $TWITCH_CLIENT_ID" \
                      "$url")

    CURSOR=$(echo "$VODS_JSON" | jq -r '.pagination.cursor')
    
    # Use process substitution to avoid a subshell so that FOUND_TARGET is updated properly
    while read -r vod; do
        VOD_ID=$(echo "$vod" | jq -r '.id')
        CREATED_AT=$(echo "$vod" | jq -r '.created_at')
        DURATION=$(echo "$vod" | jq -r '.duration')

        # Convert Twitch duration (e.g., "2h30m") to seconds
        # Remove any trailing '+' sign before evaluating the expression
        DURATION_SEC=$(echo "$DURATION" | awk '
            {
                gsub(/h/, "*3600+");
                gsub(/m/, "*60+");
                gsub(/s/, "");
                expr = $0;
                sub(/\+$/, "", expr);
                print expr
            }' | bc)

        # Stop fetching if we found the target VOD
        if [[ "$VOD_ID" -eq "$TARGET_VOD_ID" ]]; then
            FOUND_TARGET=true
        fi

        # Insert or update VOD in Supabase
        echo "Processing VOD: $VOD_ID ($CREATED_AT, Duration: $DURATION_SEC sec)"
        curl -X POST "$SUPABASE_URL/rest/v1/vods" \
            -H "apikey: $SUPABASE_API_KEY" \
            -H "Authorization: Bearer $SUPABASE_API_KEY" \
            -H "Content-Type: application/json" \
            -H "Prefer: resolution=merge" \
            -d '{
                "vod_id": '"$VOD_ID"',
                "streamer_id": '"$STREAMER_ID"',
                "duration": '"$DURATION_SEC"'
            }'

        # Append to local file
        echo "$VOD_ID $CREATED_AT" >> "$VOD_FILE"
    done < <(echo "$VODS_JSON" | jq -c '.data[]')

    # Stop fetching if we found the target VOD
    if [[ "$FOUND_TARGET" == true ]]; then
        echo "✅ Found target VOD ($TARGET_VOD_ID). Stopping fetch."
        return 1
    fi

    return 0
}

# Loop until target VOD is found or no more pages
while true; do
    PAGE_COUNT=$((PAGE_COUNT + 1))
    echo "Fetching page $PAGE_COUNT..."
    
    fetch_vods
    [[ $? -ne 0 ]] && break

    if [[ -z "$CURSOR" || "$CURSOR" == "null" ]]; then
        echo "No more pages available."
        break
    fi
done

echo "VOD fetching complete. Entries stored in $VOD_FILE and Supabase."
