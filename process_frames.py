import os
import time
import numpy as np
import cv2
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
import re
import sys

# Inputs
VOD_ID = sys.argv[1]  # Pass VOD ID as an argument
print(VOD_ID)
FRAME_DIR = f"/mnt/tmpfs/{VOD_ID}/frames"
MATCHUP_DIR = f"/mnt/tmpfs/{VOD_ID}/matchups"

# Ensure matchup directory exists
os.makedirs(MATCHUP_DIR, exist_ok=True)

# Load template for matching
TEMPLATE_PATH = "./border_480.png"
template = cv2.imread(TEMPLATE_PATH, cv2.IMREAD_GRAYSCALE)
if template is None:
    raise FileNotFoundError(f"Template image not found: {TEMPLATE_PATH}")

TEMPLATE_W, TEMPLATE_H = template.shape[1], template.shape[0]
THRESHOLD = 0.6  # Template matching confidence threshold

# Regex to extract timestamps from filename
FILENAME_REGEX = re.compile(r"(\d+)_(\d+)_(\d+)\.png")

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
        frame = cv2.imread(frame_path, cv2.IMREAD_GRAYSCALE)
        if frame is None:
            print(f"Error: Could not load {frame_path}")
            return

        # Apply Template Matching
        res = cv2.matchTemplate(frame, template, cv2.TM_CCOEFF_NORMED)
        match_value = np.max(res)

        if match_value >= THRESHOLD:
            print(f"Match Found at {frame_time}s (Confidence: {match_value:.2f})")

            # Thresholding for better contour detection
            _, frame_bin = cv2.threshold(frame, 200, 255, cv2.THRESH_BINARY)
            kernel = np.ones((5, 5), np.uint8)
            frame_dilate = cv2.dilate(frame_bin, kernel, iterations=2)

            # Find contours (text region isolation)
            contours, _ = cv2.findContours(frame_dilate, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

            if contours:
                # Find the largest contour (assumed to be the nameplate)
                x, y, w, h = max([cv2.boundingRect(cnt) for cnt in contours], key=lambda b: b[2] * b[3])
                frame_bin = cv2.bitwise_not(frame_bin)
                cropped_nameplate = frame_bin[y:y+h, x:x+w]

                # Save cropped nameplate
                matchup_filename = f"{MATCHUP_DIR}/{frame_time}.png"
                cv2.imwrite(matchup_filename, cropped_nameplate)
                print(f"Saved: {matchup_filename}")

        # Delete frame after processing
        try:
            os.remove(frame_path)
        except Exception as e:
            print(f"Could not delete {frame_path}: {e}")

if __name__ == "__main__":
    print(f"Watching for new frames in {FRAME_DIR}/")
    event_handler = FrameHandler()
    observer = Observer()
    observer.schedule(event_handler, FRAME_DIR, recursive=False)
    observer.start()

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()
