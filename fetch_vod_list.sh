#!/bin/bash

source .env

TARGET_VOD_ID="2397931096"
VOD_FILE="master_vod_list.txt"
STREAMER_ID="29795919"

# Fetch VODs (sorted from latest to oldest)
VODS_JSON=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
                -H "Client-Id: $CLIENT_ID" \
                "https://api.twitch.tv/helix/videos?user_id=$STREAMER_ID&type=archive")

# Extract VOD IDs and timestamps (as Unix timestamps), and save to file
echo "$VODS_JSON" | jq -r '.data[] | select(.id >= "'$TARGET_VOD_ID'") | "\(.id) \(.created_at)"' > "$VOD_FILE"
# echo "$VODS_JSON" | jq -r '.data[]'
# echo "Stored VOD list in $VOD_FILE"
