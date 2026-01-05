#!/usr/bin/env python3
"""
Emblem detection and removal for improved OCR accuracy
Uses template matching for emblem detection
"""

import cv2
import numpy as np
from pathlib import Path
from typing import Tuple, Optional
import logging

class EmblemDetector:
    """Detect and remove rank emblems using template matching"""

    RANKS = ['bronze', 'silver', 'gold', 'diamond', 'legend']

    def __init__(self, templates_dir: str = "templates", resolution: str = "480p",
                 old_templates: bool = False, template_method: str = 'TM_CCOEFF_NORMED'):
        """Initialize with emblem templates

        Args:
            templates_dir: Directory containing emblem templates
            resolution: Resolution to use for templates (360p, 480p, 720p, 1080p)
            old_templates: Use underscore-prefixed templates for older VODs
            template_method: OpenCV template matching method
        """
        self.templates_dir = Path(templates_dir)
        self.resolution = resolution
        self.old_templates = old_templates
        self.template_method = template_method
        self.logger = logging.getLogger(__name__)

        # Configure template matching method
        if template_method == 'TM_CCOEFF_NORMED':
            self.cv_method = cv2.TM_CCOEFF_NORMED
            self.lower_better = False
        elif template_method == 'TM_SQDIFF_NORMED':
            self.cv_method = cv2.TM_SQDIFF_NORMED
            self.lower_better = True
        else:  # TM_CCORR_NORMED
            self.cv_method = cv2.TM_CCORR_NORMED
            self.lower_better = False

        if self.old_templates:
            self.logger.info(f"Using small templates (underscore-prefixed) for {resolution}")

        # Storage for templates
        self.templates = {}
        self.template_masks = {}

        self._load_templates()

    def _load_templates(self):
        """Load all rank emblem templates"""
        for rank in self.RANKS:
            if self.old_templates:
                template_path = self.templates_dir / f"_{rank}_{self.resolution}.png"
            else:
                template_path = self.templates_dir / f"{rank}_{self.resolution}.png"

            if template_path.exists():
                template_bgra = cv2.imread(str(template_path), cv2.IMREAD_UNCHANGED)
                if template_bgra is not None:
                    # Extract BGR channels and alpha mask
                    if len(template_bgra.shape) == 3 and template_bgra.shape[2] == 4:
                        template = template_bgra[:,:,:3]
                        alpha = template_bgra[:,:,3]
                        self.template_masks[rank] = (alpha > 0).astype(np.uint8)
                    else:
                        template = template_bgra
                        self.template_masks[rank] = None

                    self.templates[rank] = template
                    mask_info = "with mask" if self.template_masks[rank] is not None else "without mask"
                    self.logger.info(f"Loaded {rank} emblem template {mask_info} from {template_path.name}")
                else:
                    self.logger.warning(f"Failed to load {rank} template")
            else:
                self.logger.warning(f"Template not found: {template_path}")

    def detect_emblem(self, frame: np.ndarray, threshold: float = 0.5) -> Tuple[Optional[str], Optional[Tuple[int, int, int, int]], float]:
        """
        Detect which emblem is present using template matching

        Args:
            frame: Input frame (color BGR)
            threshold: Matching confidence threshold (0-1)

        Returns:
            (rank_name, (x, y, w, h), confidence) or (None, None, 0.0) if no match
        """
        best_rank = None
        best_bbox = None
        best_score = -999 if not self.lower_better else 999
        best_confidence = 0.0

        for rank in self.RANKS:
            if rank not in self.templates:
                continue

            template = self.templates[rank]
            mask = self.template_masks.get(rank)

            if template.shape[0] > frame.shape[0] or template.shape[1] > frame.shape[1]:
                continue

            try:
                if mask is not None:
                    result = cv2.matchTemplate(frame, template, self.cv_method, mask=mask)
                else:
                    result = cv2.matchTemplate(frame, template, self.cv_method)

                min_val, max_val, min_loc, max_loc = cv2.minMaxLoc(result)

                if self.lower_better:
                    score = min_val
                    loc = min_loc
                    confidence = 1.0 - min_val
                else:
                    score = max_val
                    loc = max_loc
                    confidence = max_val

                is_better = (not self.lower_better and score > best_score) or \
                           (self.lower_better and score < best_score)

                if is_better and confidence >= threshold:
                    best_score = score
                    best_confidence = confidence
                    best_rank = rank
                    h, w = template.shape[:2]
                    best_bbox = (loc[0], loc[1], w, h)

            except Exception as e:
                self.logger.error(f"Template matching error for {rank}: {e}")
                continue

        return best_rank, best_bbox, best_confidence

    def remove_emblem(self, frame: np.ndarray, threshold: float = 0.5, fill_value: int = 0) -> Tuple[np.ndarray, Optional[str]]:
        """
        Detect and remove emblem from frame by masking it out

        Args:
            frame: Input frame
            threshold: Detection threshold
            fill_value: Value to fill masked area (0=black, 255=white)

        Returns:
            (processed_frame, detected_rank)
        """
        rank, bbox, confidence = self.detect_emblem(frame, threshold)

        if bbox is None:
            return frame, None

        result = frame.copy()
        x, y, w, h = bbox

        x1 = max(0, x)
        y1 = max(0, y)
        x2 = min(result.shape[1], x + w)
        y2 = min(result.shape[0], y + h)

        if len(result.shape) == 3:
            result[y1:y2, x1:x2] = [fill_value, fill_value, fill_value]
        else:
            result[y1:y2, x1:x2] = fill_value

        return result, rank

    def create_debug_visualization(self, frame: np.ndarray, threshold: float = 0.5) -> np.ndarray:
        """
        Create a visualization showing detected emblem bounding box

        Args:
            frame: Input frame
            threshold: Detection threshold

        Returns:
            Visualization frame with bbox overlay
        """
        if len(frame.shape) == 2:
            vis = cv2.cvtColor(frame, cv2.COLOR_GRAY2BGR)
        else:
            vis = frame.copy()

        rank, bbox, confidence = self.detect_emblem(frame, threshold)

        if bbox:
            x, y, w, h = bbox
            cv2.rectangle(vis, (x, y), (x + w, y + h), (0, 255, 0), 2)
            label = f"{rank.upper()} ({confidence:.2f})"
            cv2.putText(vis, label, (x, y - 5), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1)

        return vis
