#!/usr/bin/env python3
"""Copy validated frames from test_data/ into sfde/tests/fixtures/ for unit testing.

Flattens the category/vod_id/ hierarchy into a single frames/ directory
using {vod_id}_{filename} naming convention.
"""

import json
import shutil
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ANNOTATIONS_PATH = REPO_ROOT / "test_data" / "annotations(10).json"
SOURCE_DIR = REPO_ROOT / "test_data"
DEST_DIR = REPO_ROOT / "sfde" / "tests" / "fixtures"


def main():
    with open(ANNOTATIONS_PATH) as f:
        annotations = json.load(f)

    frames_dir = DEST_DIR / "frames"
    frames_dir.mkdir(parents=True, exist_ok=True)

    copied = 0
    missing = 0
    for key, ann in annotations.items():
        if not ann.get("validated"):
            continue

        src = SOURCE_DIR / ann["category"] / str(ann["vod_id"]) / ann["filename"]
        dest_filename = f"{ann['vod_id']}_{ann['filename']}"
        dest = frames_dir / dest_filename

        if src.exists():
            shutil.copy2(src, dest)
            copied += 1
        else:
            print(f"  missing: {src}")
            missing += 1

    # Copy annotations.json (canonical name, no parens)
    dest_annotations = DEST_DIR / "annotations.json"
    shutil.copy2(ANNOTATIONS_PATH, dest_annotations)

    print(f"Copied {copied} frames to {frames_dir}")
    if missing:
        print(f"Warning: {missing} frames not found in test_data/")
    print(f"Copied annotations.json to {dest_annotations}")


if __name__ == "__main__":
    main()
