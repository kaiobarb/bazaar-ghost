import os
import time
import requests
import pytesseract
import cv2
import glob
from dotenv import load_dotenv

# Load environment variables
load_dotenv()

SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_STORAGE_BUCKET = os.getenv("SUPABASE_STORAGE_BUCKET")
SUPABASE_SERVICE_ROLE = os.getenv("SUPABASE_SERVICE_ROLE")

# Valid rank labels
VALID_RANKS = {"bronze", "silver", "gold", "diamond", "legend"}

def process_matchup_file(matchup_path):
    """Process a single matchup image file"""
    matchup_filename = os.path.basename(matchup_path)
    vod_id = matchup_path.split("/")[-3]  # Extract VOD_ID from folder structure

    print(f"Processing existing matchup image: {matchup_filename} (VOD: {vod_id})")

    try:
        parts = matchup_filename.replace(".png", "").split("_")
        frame_time = int(parts[0])
        rank = parts[1] if len(parts) > 1 else None
    except ValueError:
        print(f"Invalid filename format: {matchup_filename}, skipping...")
        return

    if rank not in VALID_RANKS:
        print(f"Invalid rank in filename: {rank}, skipping...")
        return

    twitch_vod_link = f"https://www.twitch.tv/videos/{vod_id}?t={frame_time}s"

    # Run Tesseract OCR (PSM 8 for single word recognition)
    img = cv2.imread(matchup_path, cv2.IMREAD_GRAYSCALE)
    if img is None:
        print(f"Could not load image: {matchup_filename}, skipping...")
        return

    tesseract_config = "--psm 8 --oem 3"
    ocr_result = pytesseract.image_to_data(img, config=tesseract_config, output_type=pytesseract.Output.DICT)

    # Extract best guess (highest confidence text)
    extracted_text = ""
    confidence_score = 0.0

    if len(ocr_result["text"]) > 0:
        best_idx = max(range(len(ocr_result["conf"])), key=lambda i: ocr_result["conf"][i])
        extracted_text = ocr_result["text"][best_idx].strip()
        confidence_score = float(ocr_result["conf"][best_idx])

    print(f"OCR Extracted: '{extracted_text}' (Confidence: {confidence_score:.2f})")

    # Upload to Supabase Storage
    storage_path = f"{SUPABASE_STORAGE_BUCKET}/{vod_id}/{frame_time}.png"
    with open(matchup_path, "rb") as f:
        file_data = f.read()

    response = requests.put(
        f"{SUPABASE_URL}/storage/v1/object/{storage_path}",
        headers={
            "apikey": SUPABASE_SERVICE_ROLE,
            "Authorization": f"Bearer {SUPABASE_SERVICE_ROLE}",
            "Content-Type": "image/png"
        },
        data=file_data
    )

    if response.status_code == 200:
        image_url = f"{SUPABASE_URL}/storage/v1/object/public/{storage_path}"
        print(f"Uploaded to Supabase: {image_url}")
    else:
        print(f"Upload failed: {response.text}")
        return

    # Insert record into matchups table
    response = requests.post(
        f"{SUPABASE_URL}/rest/v1/matchups",
        headers={
            "apikey": f"{SUPABASE_SERVICE_ROLE}",
            "Authorization": f"Bearer {SUPABASE_SERVICE_ROLE}",
            "Content-Type": "application/json",
            "Prefer": "resolution=merge"
        },
        json={
            "vod_id": vod_id,
            "username": extracted_text,
            "confidence": confidence_score,
            "image_url": image_url,
            "frame_time": frame_time,
            "vod_link": twitch_vod_link,
            "rank": rank
        }
    )

    if response.status_code == 201:
        print(f"Matchup {matchup_filename} processed and stored in Supabase.")
    else:
        print(f"Failed to insert matchup into Supabase: {response.text}")

    # Delete matchup file after processing
    try:
        os.remove(matchup_path)
    except Exception as e:
        print(f"Could not delete {matchup_filename}: {e}")

# Process existing matchups
print(f"Scanning existing matchups in /mnt/tmpfs/*/matchups/")
existing_files = glob.glob("/mnt/tmpfs/*/matchups/*.png")

if not existing_files:
    print("No existing matchups found.")
else:
    for file in existing_files:
        process_matchup_file(file)

print("✅ Finished processing all existing matchups.")
