#!/bin/bash

source .env  # Load environment variables

# Ensure tmpfs directory exists
mkdir -p "$TMPFS_DIR"

# Check if required tools are installed
if ! command -v parallel &> /dev/null; then
    echo "Error: GNU parallel is not installed. Please install it before running this script."
    exit 1
fi

if [ ! -f "$VOD_FILE" ]; then
    echo "VOD list file not found. Run fetch_vods.sh first."
    exit 1
fi

# Function to process a single VOD
process_vod() {
    VOD_ID="$1"
    VOD_TIMESTAMP="$2"
    source .env

    # Prevent other parallel instances from processing the same VOD
    if grep -q "^$VOD_ID " "$VOD_FILE" | grep -q "# IN-PROGRESS"; then
        echo "Skipping VOD: $VOD_ID (Already in progress)"
        return
    fi

    echo "Processing VOD: $VOD_ID ($VOD_TIMESTAMP)"
    
    # Mark VOD as in-progress in vod_list.txt
    sed -i "s/^$VOD_ID .*$/& # IN-PROGRESS/" "$VOD_FILE"

    mkdir -p "$TMPFS_DIR/$VOD_ID/frames"
    mkdir -p "$TMPFS_DIR/$VOD_ID/matchups"

    source ./venv/bin/activate 
    # Run frame extraction and OCR in parallel
    ( python -u process_frames.py "$VOD_ID" 2>&1 | tee logs/process_frames_$VOD_ID.log ) &
    FRAMES_PID=$!

    (python -u process_matchups_ocr.py "$VOD_ID" 2>&1 | tee logs/process_matchups_$VOD_ID.log) &
    MATCHUPS_PID=$!

    echo "Started process_frames.py (PID: $FRAMES_PID)"
    echo "Started process_matchups_ocr.py (PID: $MATCHUPS_PID)"

    # Run VOD capture
    ./vod_capture.sh "https://www.twitch.tv/videos/$VOD_ID" "$VOD_ID" "$VOD_TIMESTAMP" > logs/vod_capture_$VOD_ID.log

    # Once vod_capture.sh exits, terminate the processing scripts
    echo "Terminating process_frames.py and process_matchups_ocr.py..."
    kill -TERM -$FRAMES_PID -$MATCHUPS_PID 2>/dev/null
    # wait $FRAMES_PID $MATCHUPS_PID 2>/dev/null

    echo "Finished processing VOD: $VOD_ID"

    # Remove the processed VOD entry from vod_list.txt
    sed -i "/^$VOD_ID /d" "$VOD_FILE"
    echo "Cleaned up VOD entry: $VOD_ID"
}

export -f process_vod

# Debug: Check if parallel receives correct input
echo "Running Parallel..."
cat "$VOD_FILE" | grep -v "# IN-PROGRESS" | parallel --jobs "$MAX_PARALLEL_JOBS" --colsep ' ' process_vod {1} {2}
