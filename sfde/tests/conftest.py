"""Shared fixtures for SFDE unit tests.

Loads validated annotations and frame images, initializes detectors
with session scope so PaddleOCR and template loading only happen once.
"""

import json
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

import cv2
import numpy as np
import pytest
import yaml

# Add sfde/src to import path
SFDE_SRC = Path(__file__).resolve().parent.parent / "src"
sys.path.insert(0, str(SFDE_SRC))

FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"
TEMPLATES_DIR = Path(__file__).resolve().parent.parent / "templates"
CONFIG_PATH = Path(__file__).resolve().parent.parent / "config.yaml"

from helpers import RESOLUTION_MAP


@dataclass
class ValidatedFrame:
    """A single validated detection frame with ground truth annotations."""

    key: str
    image_path: Path
    expected_username: str
    expected_rank: str
    original_confidence: float
    right_edge_visible: bool
    emblem_visible: bool
    category: str
    quality: str
    vod_id: int
    frame_time_seconds: int
    username_corrected: bool
    custom_edge: Optional[float]
    profile_name: str
    old_templates: bool
    _image: Optional[np.ndarray] = field(default=None, repr=False)

    @property
    def image(self) -> np.ndarray:
        if self._image is None:
            self._image = cv2.imread(str(self.image_path))
            if self._image is None:
                raise FileNotFoundError(f"Could not load image: {self.image_path}")
        return self._image

    @property
    def template_resolution(self) -> str:
        return RESOLUTION_MAP.get(self.quality, "480p")


# ---------------------------------------------------------------------------
# Session fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(scope="session")
def config() -> Dict[str, Any]:
    with open(CONFIG_PATH) as f:
        return yaml.safe_load(f)


@pytest.fixture(scope="session")
def annotations() -> Dict[str, Any]:
    path = FIXTURES_DIR / "annotations.json"
    with open(path) as f:
        return json.load(f)


@pytest.fixture(scope="session")
def all_validated_frames(annotations) -> List[ValidatedFrame]:
    frames = []
    for key, ann in annotations.items():
        if not ann.get("validated"):
            continue

        vod_id = ann["vod_id"]
        filename = ann["filename"]
        frame_filename = f"{vod_id}_{filename}"
        image_path = FIXTURES_DIR / "frames" / frame_filename

        if not image_path.exists():
            continue

        custom_edge = ann.get("custom_edge")
        if custom_edge is not None:
            custom_edge = float(custom_edge)

        frames.append(
            ValidatedFrame(
                key=key,
                image_path=image_path,
                expected_username=ann["username"],
                expected_rank=ann["original_rank"],
                original_confidence=ann["original_confidence"],
                right_edge_visible=ann["right_edge_visible"],
                emblem_visible=ann["emblem_visible"],
                category=ann["category"],
                quality=ann["quality"],
                vod_id=vod_id,
                frame_time_seconds=ann["frame_time_seconds"],
                username_corrected=ann.get("username_corrected", False),
                custom_edge=custom_edge,
                profile_name=ann.get("profile_name", "default"),
                old_templates=(ann["category"] == "old_templates"),
            )
        )
    return frames


# ---------------------------------------------------------------------------
# Filtered frame lists
# ---------------------------------------------------------------------------


@pytest.fixture(scope="session")
def clean_frames(all_validated_frames) -> List[ValidatedFrame]:
    return [f for f in all_validated_frames if f.category == "clean"]


@pytest.fixture(scope="session")
def bad_frames(all_validated_frames) -> List[ValidatedFrame]:
    return [f for f in all_validated_frames if f.category == "bad"]


@pytest.fixture(scope="session")
def covered_edge_frames(all_validated_frames) -> List[ValidatedFrame]:
    return [f for f in all_validated_frames if f.category == "covered_edge"]


@pytest.fixture(scope="session")
def old_template_frames(all_validated_frames) -> List[ValidatedFrame]:
    return [f for f in all_validated_frames if f.category == "old_templates"]


@pytest.fixture(scope="session")
def emblem_visible_frames(all_validated_frames) -> List[ValidatedFrame]:
    return [f for f in all_validated_frames if f.emblem_visible]


@pytest.fixture(scope="session")
def no_emblem_frames(all_validated_frames) -> List[ValidatedFrame]:
    return [f for f in all_validated_frames if not f.emblem_visible]


@pytest.fixture(scope="session")
def right_edge_visible_frames(all_validated_frames) -> List[ValidatedFrame]:
    return [f for f in all_validated_frames if f.right_edge_visible]


@pytest.fixture(scope="session")
def no_right_edge_frames(all_validated_frames) -> List[ValidatedFrame]:
    return [f for f in all_validated_frames if not f.right_edge_visible]


# ---------------------------------------------------------------------------
# Detector fixtures (keyed by template resolution + old_templates flag)
# ---------------------------------------------------------------------------


@pytest.fixture(scope="session")
def emblem_detectors(config) -> Dict[str, "EmblemDetector"]:
    """One EmblemDetector per (resolution, old_templates) combo found in test data."""
    from emblem_detector import EmblemDetector

    detectors = {}
    emblem_cfg = config.get("emblem_detection", {})
    method = emblem_cfg.get("template_method", "TM_CCOEFF_NORMED")

    for res in ("480p", "720p", "1080p"):
        for old in (False, True):
            key = f"{res}_old" if old else res
            detectors[key] = EmblemDetector(
                templates_dir=str(TEMPLATES_DIR),
                resolution=res,
                old_templates=old,
                template_method=method,
            )
    return detectors


@pytest.fixture(scope="session")
def right_edge_detectors() -> Dict[str, "RightEdgeDetector"]:
    """One RightEdgeDetector per resolution."""
    from right_edge_detector import RightEdgeDetector

    detectors = {}
    for res in ("480p", "720p", "1080p"):
        detectors[res] = RightEdgeDetector(
            templates_dir=str(TEMPLATES_DIR),
            resolution=res,
        )
    return detectors


@pytest.fixture(scope="session")
def emblem_threshold(config) -> float:
    return config.get("emblem_detection", {}).get("template_threshold", 0.5)


@pytest.fixture(scope="session")
def right_edge_threshold(config) -> float:
    return config.get("right_edge_detection", {}).get("threshold", 0.88)


# ---------------------------------------------------------------------------
# FrameProcessor fixtures (heavy — one per resolution, session scoped)
# ---------------------------------------------------------------------------


@pytest.fixture(scope="session")
def frame_processors(config) -> Dict[str, "FrameProcessor"]:
    """One FrameProcessor per (quality, old_templates) combo.

    These are expensive to create (PaddleOCR init), so session-scoped.
    Keys match the pattern: '480p', '720p', '1080p', '480p_old'.
    """
    from frame_processor import FrameProcessor

    processors = {}
    qualities = [
        ("480p", False),
        ("720p", False),
        ("720p60", False),
        ("1080p60", False),
        ("480p", True),
    ]

    for quality, old_templates in qualities:
        key = f"{quality}_old" if old_templates else quality
        processors[key] = FrameProcessor(
            config=config,
            quality=quality,
            old_templates=old_templates,
            profile=None,
            streamer="test",
        )

    return processors
