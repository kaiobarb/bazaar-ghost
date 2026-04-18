"""Pure image/geometry helpers shared by the SFDE pipeline."""

import math
from typing import List, Optional

import cv2
import numpy as np


def percent_to_pixels(
    crop_percent: List[float], frame_width: int, frame_height: int
) -> List[int]:
    """Convert percentage-based crop to FFmpeg-style pixel coords.

    Args:
        crop_percent: [x, y, width, height] as fractions (0.0-1.0)
        frame_width: Width of the frame in pixels
        frame_height: Height of the frame in pixels

    Returns:
        [width, height, x, y] in pixels for FFmpeg crop filter
    """
    x_percent, y_percent, w_percent, h_percent = crop_percent

    x = math.floor(x_percent * frame_width)
    y = math.floor(y_percent * frame_height)
    w = math.ceil(w_percent * frame_width)
    h = math.ceil(h_percent * frame_height)

    x = min(x, frame_width - 1)
    y = min(y, frame_height - 1)
    w = min(w, frame_width - x)
    h = min(h, frame_height - y)

    return [w, h, x, y]


def decode_jpeg(frame_data: bytes) -> Optional[np.ndarray]:
    """Decode JPEG bytes to a BGR numpy array, or None on failure."""
    arr = np.frombuffer(frame_data, dtype=np.uint8)
    return cv2.imdecode(arr, cv2.IMREAD_COLOR)


def encode_jpeg(frame: np.ndarray) -> bytes:
    """Encode a BGR numpy array to JPEG bytes."""
    _, buf = cv2.imencode(".jpg", frame)
    return buf.tobytes()


def slice_subregion(frame: np.ndarray, region: List[int]) -> np.ndarray:
    """Slice [x_offset, y_offset, w, h] from a decoded frame."""
    x, y, w, h = region
    return frame[y : y + h, x : x + w]
