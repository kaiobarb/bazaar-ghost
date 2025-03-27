import os
import time
import numpy as np
import cv2
import requests
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
import re
import sys
import signal
from dotenv import load_dotenv

# Load environment variables
load_dotenv()

SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_SERVICE_ROLE = os.getenv("SUPABASE_SERVICE_ROLE")

# Inputs
VOD_ID = sys.argv[1]  # Pass VOD ID as an argument
print(VOD_ID)
FRAME_DIR = f"/mnt/tmpfs/{VOD_ID}/frames"
MATCHUP_DIR = f"/mnt/tmpfs/{VOD_ID}/matchups"

# Ensure matchup directory exists
os.makedirs(MATCHUP_DIR, exist_ok=True)
os.makedirs(FRAME_DIR, exist_ok=True)


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

THRESHOLD = 0.78  # Template matching confidence threshold
CROP_X, CROP_Y, CROP_W, CROP_H = 60, 10, 184, 31

# Regex to extract timestamps from filename
FILENAME_REGEX = re.compile(r"(\d+)_(\d+)_(\d+)\.png")

last_frame_time = 0
last_matchup_time = 0
last_update = time.time()


def update_metadata():
    global last_frame_time, last_matchup_time
    payload = {
        "last_frame_processed": last_frame_time,
        "last_matchup_frame": last_matchup_time
    }
    response = requests.patch(
        f"{SUPABASE_URL}/rest/v1/metadata?vod_id=eq.{VOD_ID}",
        headers={
            "apikey": SUPABASE_SERVICE_ROLE,
            "Authorization": f"Bearer {SUPABASE_SERVICE_ROLE}",
            "Content-Type": "application/json"
        },
        json=payload
    )
    if response.status_code == 204:
        print(f"✅ Metadata updated: {payload}")
    else:
        print(f"❌ Failed to update metadata: {response.text}")


def rank_match(frame):
    for rank, template in RANK_TEMPLATES.items():
        if template is None:
            continue
        res = cv2.matchTemplate(frame, template, cv2.TM_CCOEFF_NORMED)
        match_value = np.max(res)
        if match_value >= THRESHOLD:
            print(f"Rank matched: {rank.upper()} (Confidence: {match_value:.2f})")
            return rank
    return None


class FrameHandler(FileSystemEventHandler):
    def on_created(self, event):
        global last_frame_time, last_matchup_time, last_update

        if event.is_directory or not event.src_path.endswith(".png"):
            return

        frame_path = event.src_path
        frame_filename = os.path.basename(frame_path)

        match = FILENAME_REGEX.match(frame_filename)
        if not match:
            print(f"Skipping {frame_filename}, invalid format.")
            return

        _, vod_start_timestamp, frame_time = match.groups()
        vod_start_timestamp = int(vod_start_timestamp)
        frame_time = int(frame_time) * 5
        last_frame_time = frame_time

        frame = cv2.imread(frame_path, cv2.IMREAD_COLOR)
        if frame is None:
            print(f"Error: Could not load {frame_path}")
            return

        detected_rank = rank_match(frame)
        cropped_frame = frame[CROP_Y:CROP_Y + CROP_H, CROP_X:CROP_X + CROP_W]

        if detected_rank:
            gray_frame = cv2.cvtColor(cropped_frame, cv2.COLOR_BGR2GRAY)
            _, frame_bin = cv2.threshold(gray_frame, 105, 255, cv2.THRESH_BINARY)
            kernel = np.ones((3, 3), np.uint8)
            frame_dilate = cv2.dilate(frame_bin, kernel, iterations=2)
            contours, _ = cv2.findContours(frame_dilate, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

            if contours:
                x, y, w, h = max([cv2.boundingRect(cnt) for cnt in contours], key=lambda b: b[2] * b[3])
                frame_bin = cv2.bitwise_not(frame_bin)
                cropped_nameplate = frame_bin[y:y+h, x:x+w]
                matchup_filename = f"{MATCHUP_DIR}/{frame_time}_{detected_rank}.png"
                cv2.imwrite(matchup_filename, cropped_nameplate)
                last_matchup_time = frame_time
                print(f"Saved: {matchup_filename} from {frame_path}")

        try:
            os.remove(frame_path)
        except Exception as e:
            print(f"Could not delete {frame_path}: {e}")

        if time.time() - last_update >= 20:
            update_metadata()
            last_update = time.time()


if __name__ == "__main__":
    print(f"Watching for new frames in {FRAME_DIR}/")
    event_handler = FrameHandler()
    observer = Observer()
    observer.schedule(event_handler, FRAME_DIR, recursive=False)

    def handle_sigterm(signum, frame):
        print("Received SIGTERM, shutting down...")
        update_metadata()
        observer.stop()

    signal.signal(signal.SIGTERM, handle_sigterm)
    signal.signal(signal.SIGINT, handle_sigterm)

    observer.start()
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        update_metadata()
        observer.stop()
    observer.join()
