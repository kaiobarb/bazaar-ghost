"""Shared helper functions for SFDE tests."""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from conftest import ValidatedFrame

# Quality -> template resolution mapping (mirrors frame_processor.py)
RESOLUTION_MAP = {
    "360p": "360p",
    "480p": "480p",
    "720p": "720p",
    "720p60": "720p",
    "1080p": "1080p",
    "1080p60": "1080p",
}


def get_processor_key(frame: ValidatedFrame) -> str:
    """Return the frame_processors dict key for a given frame."""
    if frame.old_templates:
        return f"{frame.quality}_old"
    return frame.quality


def get_emblem_detector_key(frame: ValidatedFrame) -> str:
    """Return the emblem_detectors dict key for a given frame."""
    res = RESOLUTION_MAP.get(frame.quality, "480p")
    if frame.old_templates:
        return f"{res}_old"
    return res
