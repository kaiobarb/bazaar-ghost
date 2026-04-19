"""Shared fixtures for SFDE unit tests.

Loads validated annotations and frame images, initializes detectors
with session scope so PaddleOCR and template loading only happen once.

Detection results (emblem, right edge, OCR) are cached in a single
session-scoped pass so each frame is processed exactly once.
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

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

from helpers import RESOLUTION_MAP, get_emblem_detector_key, get_processor_key


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


@dataclass
class DetectionResult:
    """Cached detection results for a single frame (computed once per session)."""

    # Emblem detection
    emblem_rank: Optional[str]
    emblem_bbox: Optional[Tuple[int, int, int, int]]
    emblem_conf: float

    # Right edge detection
    right_edge_x: Optional[int]
    right_edge_conf: float

    # OCR extraction (after emblem crop)
    ocr_username: Optional[str]
    ocr_confidence: float


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
# Detector fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(scope="session")
def emblem_detectors(config) -> Dict[str, "EmblemDetector"]:
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


@pytest.fixture(scope="session")
def frame_processors(config) -> Dict[str, "FrameProcessor"]:
    """One FrameProcessor per (quality, old_templates) combo.

    These are expensive to create (PaddleOCR init), so session-scoped.
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


# ---------------------------------------------------------------------------
# Cached detection results — single pass over all frames
# ---------------------------------------------------------------------------


@pytest.fixture(scope="session")
def all_detection_results(
    all_validated_frames,
    emblem_detectors,
    right_edge_detectors,
    frame_processors,
    emblem_threshold,
    right_edge_threshold,
) -> Dict[str, DetectionResult]:
    """Run emblem detection, right edge detection, and OCR on every frame
    exactly once. Returns a dict keyed by frame.key.

    This is the most expensive fixture (~3 min) but eliminates all
    redundant inference across test files.
    """
    results = {}

    for frame in all_validated_frames:
        # Emblem detection
        det_key = get_emblem_detector_key(frame)
        detector = emblem_detectors.get(det_key)
        if detector is not None:
            e_rank, e_bbox, e_conf = detector.detect_emblem(
                frame.image, threshold=emblem_threshold
            )
        else:
            e_rank, e_bbox, e_conf = None, None, 0.0

        # Right edge detection
        re_detector = right_edge_detectors.get(frame.template_resolution)
        if re_detector is not None:
            re_x, re_conf = re_detector.detect_right_edge(
                frame.image, threshold=right_edge_threshold
            )
        else:
            re_x, re_conf = None, 0.0

        # OCR extraction (requires emblem bbox for cropping)
        proc_key = get_processor_key(frame)
        processor = frame_processors.get(proc_key)
        if processor is not None:
            cropped = processor._crop(frame.image, e_bbox)
            ocr_user, ocr_conf, _ = processor._extract_usernames(cropped)
        else:
            ocr_user, ocr_conf = None, 0.0

        results[frame.key] = DetectionResult(
            emblem_rank=e_rank,
            emblem_bbox=e_bbox,
            emblem_conf=e_conf,
            right_edge_x=re_x,
            right_edge_conf=re_conf,
            ocr_username=ocr_user,
            ocr_confidence=ocr_conf,
        )

    return results
