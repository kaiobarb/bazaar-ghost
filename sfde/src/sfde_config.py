"""Config / profile loading and crop geometry for SFDE.

Everything here is pure (env + file reads only) so it can be unit-tested
without constructing an SFDEProcessor.
"""

import json
import os
from typing import Any, Dict, List, Optional, Tuple

import yaml

from image_utils import percent_to_pixels

# Quality → (width, height). Used for test-mode file selection and crop math.
QUALITY_RESOLUTIONS: Dict[str, Tuple[int, int]] = {
    "360p": (640, 360),
    "480p": (854, 480),
    "720p": (1280, 720),
    "1080p": (1920, 1080),
    "1080p60": (1920, 1080),
}

# Test-mode video file mapping
QUALITY_CONFIGS: Dict[str, Dict[str, Any]] = {
    "360p": {"resolution": (640, 360), "file_suffix": "360p.mp4"},
    "480p": {"resolution": (854, 480), "file_suffix": "480p.mp4"},
    "1080p": {"resolution": (1920, 1080), "file_suffix": "1080p.mp4"},
    "1080p60": {"resolution": (1920, 1080), "file_suffix": "1080p.mp4"},
}


def load_config() -> Dict[str, Any]:
    """Load config.yaml and apply SUPABASE_* env overrides."""
    config_path = os.path.join(os.path.dirname(__file__), "..", "config.yaml")
    with open(config_path, "r") as f:
        config = yaml.safe_load(f)

    if os.getenv("SUPABASE_URL"):
        config["supabase"]["url"] = os.getenv("SUPABASE_URL")
    if os.getenv("SUPABASE_SECRET_KEY"):
        config["supabase"]["secret_key"] = os.getenv("SUPABASE_SECRET_KEY")

    return config


def parse_sfde_profile() -> Dict[str, Any]:
    """Parse and validate the SFDE_PROFILE env var (JSON)."""
    sfde_profile_json = os.getenv("SFDE_PROFILE")

    if not sfde_profile_json:
        raise ValueError(
            "SFDE_PROFILE environment variable is required. "
            "This should be provided by the GitHub Actions workflow as a JSON string."
        )

    try:
        profile = json.loads(sfde_profile_json)
    except json.JSONDecodeError as e:
        raise ValueError(f"SFDE_PROFILE is not valid JSON: {e}")

    if "crop_region" not in profile:
        raise ValueError("SFDE_PROFILE missing required field: crop_region")

    if not isinstance(profile["crop_region"], list) or len(profile["crop_region"]) != 4:
        raise ValueError(
            f"SFDE_PROFILE crop_region must be array of 4 numbers, got: {profile.get('crop_region')}"
        )

    igd_crop = profile.get("igd_crop_region")
    if igd_crop is not None:
        if not isinstance(igd_crop, list) or len(igd_crop) != 4:
            raise ValueError(
                f"SFDE_PROFILE igd_crop_region must be array of 4 numbers, got: {igd_crop}"
            )
        profile["igd_crop_region"] = [float(v) for v in igd_crop]

    return profile


def compute_combined_crop(
    profile: Dict[str, Any], frame_width: int, frame_height: int
) -> Tuple[List[int], Optional[List[int]], Optional[List[int]]]:
    """Compute a combined FFmpeg crop covering both nameplate and IGD regions.

    Returns:
        (combined_crop [w,h,x,y], nameplate_slice [x,y,w,h] or None,
         igd_slice [x,y,w,h] or None)
    """
    nameplate_pixels = percent_to_pixels(
        profile["crop_region"], frame_width, frame_height
    )
    np_w, np_h, np_x, np_y = nameplate_pixels

    igd_crop = profile.get("igd_crop_region")
    if not igd_crop:
        return nameplate_pixels, None, None

    igd_pixels = percent_to_pixels(igd_crop, frame_width, frame_height)
    igd_w, igd_h, igd_x, igd_y = igd_pixels

    bbox_x = min(np_x, igd_x)
    bbox_y = min(np_y, igd_y)
    bbox_right = max(np_x + np_w, igd_x + igd_w)
    bbox_bottom = max(np_y + np_h, igd_y + igd_h)
    bbox_w = bbox_right - bbox_x
    bbox_h = bbox_bottom - bbox_y

    bbox_w = min(bbox_w, frame_width - bbox_x)
    bbox_h = min(bbox_h, frame_height - bbox_y)

    combined_crop = [bbox_w, bbox_h, bbox_x, bbox_y]
    nameplate_slice = [np_x - bbox_x, np_y - bbox_y, np_w, np_h]
    igd_slice = [igd_x - bbox_x, igd_y - bbox_y, igd_w, igd_h]

    return combined_crop, nameplate_slice, igd_slice
