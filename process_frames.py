import os
import time
import numpy as np
import cv2
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
import re
import sys
import signal 

# Inputs
VOD_ID = sys.argv[1]  # Pass VOD ID as an argument
print(VOD_ID)
FRAME_DIR = f"/mnt/tmpfs/{VOD_ID}/frames"
MATCHUP_DIR = f"/mnt/tmpfs/{VOD_ID}/matchups"

# Ensure matchup directory exists
os.makedirs(MATCHUP_DIR, exist_ok=True)

RANK_TEMPLATES = {
    "legend": cv2.imread("templates/legend_480.png", cv2.IMREAD_COLOR),
    "diamond": cv2.imread("templates/diamond_480.png", cv2.IMREAD_COLOR),
    "gold": cv2.imread("templates/gold_480.png", cv2.IMREAD_COLOR),
    "silver": cv2.imread("templates/silver_480.png", cv2.IMREAD_COLOR),
    "bronze": cv2.imread("templates/bronze_480.png", cv2.IMREAD_COLOR),
}

# Ensure all templates loaded correctly
for rank, template in RANK_TEMPLATES.items():
    if template is None:
        raise FileNotFoundError(f"Template for {rank} not found.")

# TEMPLATE_W, TEMPLATE_H = template.shape[1], template.shape[0]
THRESHOLD = 0.78  # Template matching confidence threshold

CROP_X, CROP_Y, CROP_W, CROP_H = 60, 10, 184, 31

# Regex to extract timestamps from filename
FILENAME_REGEX = re.compile(r"(\d+)_(\d+)_(\d+)\.png")

def rank_match(frame):
    """
    Determines the rank of the opponent based on template matching.
    Checks in order: Legend → Diamond → Gold → Silver → Bronze.
    Returns the detected rank or None if no match is found.
    """
    for rank, template in RANK_TEMPLATES.items():
        if template is None:
            continue  # Skip if template failed to load

        res = cv2.matchTemplate(frame, template, cv2.TM_CCOEFF_NORMED)
        match_value = np.max(res)

        if match_value >= THRESHOLD:
            print(f"Rank matched: {rank.upper()} (Confidence: {match_value:.2f})")
            return rank  # Return the first matched rank
    return None

class FrameHandler(FileSystemEventHandler):
    """Watches for new frames and processes them."""

    def on_created(self, event):
        if event.is_directory or not event.src_path.endswith(".png"):
            return

        frame_path = event.src_path
        frame_filename = os.path.basename(frame_path)

        # Extract timestamps from filename
        match = FILENAME_REGEX.match(frame_filename)
        if not match:
            print(f"Skipping {frame_filename}, invalid format.")
            return

        _, vod_start_timestamp, frame_time = match.groups()
        vod_start_timestamp = int(vod_start_timestamp)
        frame_time = int(frame_time) * 5

        # Load frame
        frame = cv2.imread(frame_path, cv2.IMREAD_COLOR_BGR)
        if frame is None:
            print(f"Error: Could not load {frame_path}")
            return

        # detect rank
        detected_rank = rank_match(frame)
        
        # limiting area where contouring can happen
        cropped_frame = frame[CROP_Y:CROP_Y + CROP_H, CROP_X:CROP_X + CROP_W]

        # if match_value >= THRESHOLD:
        if detected_rank:
            # print(f"Match Found at {frame_time}s (Confidence: {match_value:.2f})")

            gray_frame = cv2.cvtColor(cropped_frame, cv2.COLOR_BGR2GRAY)

            # Thresholding for better contour detection
            _, frame_bin = cv2.threshold(gray_frame, 105, 255, cv2.THRESH_BINARY)
            kernel = np.ones((3, 3), np.uint8)
            frame_dilate = cv2.dilate(frame_bin, kernel, iterations=2)

            # Find contours (text region isolation)
            contours, _ = cv2.findContours(frame_dilate, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

            if contours:
                # Find the largest contour (assumed to be the nameplate)
                x, y, w, h = max([cv2.boundingRect(cnt) for cnt in contours], key=lambda b: b[2] * b[3])
                frame_bin = cv2.bitwise_not(frame_bin)
                cropped_nameplate = frame_bin[y:y+h, x:x+w]

                # Save cropped nameplate
                matchup_filename = f"{MATCHUP_DIR}/{frame_time}_{detected_rank}.png"
                cv2.imwrite(matchup_filename, cropped_nameplate)
                print(f"Saved: {matchup_filename} from {frame_path}")

        try:
            os.remove(frame_path)
        except Exception as e:
            print(f"Could not delete {frame_path}: {e}")

if __name__ == "__main__":
    print(f"Watching for new frames in {FRAME_DIR}/")
    event_handler = FrameHandler()
    observer = Observer()
    observer.schedule(event_handler, FRAME_DIR, recursive=False)

    def handle_sigterm(signum, frame):
        print("Received SIGTERM, shutting down...")
        observer.stop()

    signal.signal(signal.SIGTERM, handle_sigterm)

    observer.start()

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()
