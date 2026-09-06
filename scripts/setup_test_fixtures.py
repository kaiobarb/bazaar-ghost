#!/usr/bin/env python3
"""Copy validated frames from test_data/ into sfde/tests/fixtures/ for unit testing.

Flattens the category/vod_id/ hierarchy into a single frames/ directory
using {vod_id}_{filename} naming convention.
"""

import argparse
import json
import shutil
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ANNOTATIONS_PATH = REPO_ROOT / "test_data" / "annotations.json"
SOURCE_DIR = REPO_ROOT / "test_data"
DEST_DIR = REPO_ROOT / "sfde" / "tests" / "fixtures"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--annotations', type=Path, default=ANNOTATIONS_PATH)
    args = parser.parse_args()
    with open(args.annotations) as f:
        annotations = json.load(f)

    missing_paths = [SOURCE_DIR / ann['category'] / str(ann['vod_id']) / ann['filename']
                     for ann in annotations.values() if ann.get('validated')
                     and not (SOURCE_DIR / ann['category'] / str(ann['vod_id']) / ann['filename']).is_file()]
    if missing_paths:
        raise FileNotFoundError(f'{len(missing_paths)} validated frames are missing; first: {missing_paths[0]}')
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
    shutil.copy2(args.annotations, dest_annotations)

    print(f"Copied {copied} frames to {frames_dir}")
    if missing:
        print(f"Warning: {missing} frames not found in test_data/")
    print(f"Copied annotations.json to {dest_annotations}")


if __name__ == "__main__":
    main()
