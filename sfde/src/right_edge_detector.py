#!/usr/bin/env python3
"""
Right edge detection for nameplate boundaries in matchup screens
Detects the right edge of nameplate frames to identify partial occlusions
"""

import cv2
import numpy as np
from pathlib import Path
from typing import Tuple, Optional
import logging


class RightEdgeDetector:
    """Detect right edge boundaries in nameplate frames"""

    def __init__(
        self,
        templates_dir: str = str(Path(__file__).resolve().parent.parent / 'templates'),
        resolution: str = "480p",
    ):
        """Initialize with right edge template for specified resolution

        Args:
            templates_dir: Directory containing right edge templates
            resolution: Resolution to use for template (360p, 480p, 720p, 1080p)
        """
        self.templates_dir = Path(templates_dir)
        self.resolution = resolution
        self.template = None
        self.mask = None  # Store alpha mask for template
        self.logger = logging.getLogger(__name__)

        # Load resolution-specific template
        self._load_template()
        if self.template is None:
            raise ValueError(f'Missing right edge template for {resolution}')

    def _load_template(self):
        """Load the right edge template for the specified resolution"""
        template_path = self.templates_dir / f"right_edge_{self.resolution}.png"

        if template_path.exists():
            # Load template WITH alpha channel for transparency support
            template_bgra = cv2.imread(str(template_path), cv2.IMREAD_UNCHANGED)
            if template_bgra is not None:
                # If template has alpha channel, extract BGR and create mask
                if len(template_bgra.shape) == 3 and template_bgra.shape[2] == 4:
                    # Has alpha channel - extract BGR and alpha mask
                    self.template = template_bgra[:, :, :3]  # BGR channels only
                    alpha = template_bgra[:, :, 3]  # Alpha channel
                    # Create binary mask: pixels with alpha > 0 are valid
                    self.mask = (alpha > 0).astype(np.uint8)
                    self.logger.info(
                        f"Loaded right edge template from {template_path.name} with mask"
                    )
                else:
                    # No alpha channel, use as-is with no mask
                    self.template = template_bgra
                    self.mask = None
                    self.logger.info(
                        f"Loaded right edge template from {template_path.name} without mask"
                    )

                h, w = self.template.shape[:2]
                self.logger.debug(f"Template dimensions: {w}x{h}")
            else:
                self.logger.error(f"Failed to load template from {template_path}")
        else:
            self.logger.warning(f"Right edge template not found: {template_path}")

    def detect_right_edge(
        self, frame: np.ndarray, threshold: float = 0.7
    ) -> Tuple[Optional[int], float]:
        """
        Detect the right edge boundary in the frame

        Args:
            frame: Input frame (color)
            threshold: Matching threshold (0-1)

        Returns:
            (right_edge_x, confidence) or (None, 0.0) if no match
            right_edge_x is the x-coordinate of the right edge of the template
        """
        if self.template is None:
            self.logger.warning("No template loaded for right edge detection")
            return None, 0.0

        # Ensure template fits in frame
        if (
            self.template.shape[0] > frame.shape[0]
            or self.template.shape[1] > frame.shape[1]
        ):
            self.logger.info("Template larger than frame, skipping detection")
            return None, 0.0

        try:
            # Only search the right half of the frame to avoid UI false positives
            frame_height, frame_width = frame.shape[:2]
            right_half_start = frame_width // 2
            right_half = frame[:, right_half_start:]
            if self.template.shape[1] > right_half.shape[1]:
                return None, 0.0
            
            # Use TM_CCORR_NORMED for better accuracy with new templates
            if self.mask is not None:
                result = cv2.matchTemplate(
                    right_half, self.template, cv2.TM_CCORR_NORMED, mask=self.mask
                )
            else:
                result = cv2.matchTemplate(right_half, self.template, cv2.TM_CCORR_NORMED)

            result[~np.isfinite(result)] = -np.inf
            min_val, max_val, min_loc, max_loc = cv2.minMaxLoc(result)
            if not np.isfinite(max_val):
                return None, 0.0
            confidence = max_val  # Already normalized for TM_CCORR_NORMED

            # Check if match exceeds threshold
            if confidence >= threshold:
                # Calculate right edge x-coordinate (adjust for right-half search)
                template_width = self.template.shape[1]
                # max_loc[0] is relative to right_half, so add the offset
                absolute_x = max_loc[0] + right_half_start
                right_edge_x = absolute_x + template_width

                self.logger.info(
                    f"Right edge detected at x={right_edge_x} "
                    f"(template at {absolute_x}), confidence={confidence:.3f}, "
                    f"frame width={frame.shape[1]}, edge ratio={right_edge_x/frame.shape[1]:.3f}"
                )
                
                return right_edge_x, confidence
            else:
                self.logger.info(
                    f"No right edge match (best confidence: {confidence:.3f}, threshold: {threshold:.2f})"
                )
                return None, confidence  # Return best confidence even when no match

        except Exception as e:
            self.logger.error(f'Right edge detection error: {e}')
            raise
