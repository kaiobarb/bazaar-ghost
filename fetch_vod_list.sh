#!/bin/bash

# Twitch API Credentials
CLIENT_ID="wz0xxp3mlfs3tb7u3n6riswhreha1c"
ACCESS_TOKEN="bkmebxq2wlrjwcxqr9fcpmb1xd6npy"
TARGET_VOD_ID="2397931096"
VOD_FILE="master_vod_list.txt"
STREAMER_ID="29795919"

# Fetch VODs (sorted from latest to oldest)
VODS_JSON=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
                -H "Client-Id: $CLIENT_ID" \
                "https://api.twitch.tv/helix/videos?user_id=$STREAMER_ID&type=archive")

# Extract VOD IDs and timestamps (as Unix timestamps), and save to file
echo "$VODS_JSON" | jq -r '.data[] | select(.id >= "'$TARGET_VOD_ID'") | "\(.id) \(.created_at)"' > "$VOD_FILE"

echo "Stored VOD list in $VOD_FILE"
