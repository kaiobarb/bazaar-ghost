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

    def __init__(self, templates_dir: str = "/home/kaio/Dev/bazaar-ghost/sfot/templates", resolution: str = "480p"):
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
                    self.template = template_bgra[:,:,:3]  # BGR channels only
                    alpha = template_bgra[:,:,3]           # Alpha channel
                    # Create binary mask: pixels with alpha > 0 are valid
                    self.mask = (alpha > 0).astype(np.uint8)
                    self.logger.info(f"Loaded right edge template from {template_path.name} with mask")
                else:
                    # No alpha channel, use as-is with no mask
                    self.template = template_bgra
                    self.mask = None
                    self.logger.info(f"Loaded right edge template from {template_path.name} without mask")

                h, w = self.template.shape[:2]
                self.logger.debug(f"Template dimensions: {w}x{h}")
            else:
                self.logger.error(f"Failed to load template from {template_path}")
        else:
            self.logger.warning(f"Right edge template not found: {template_path}")

    def detect_right_edge(self, frame: np.ndarray, threshold: float = 0.7) -> Tuple[Optional[int], float]:
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
        if self.template.shape[0] > frame.shape[0] or self.template.shape[1] > frame.shape[1]:
            self.logger.debug("Template larger than frame, skipping detection")
            return None, 0.0

        try:
            # Perform template matching with mask if available
            if self.mask is not None:
                # Use TM_SQDIFF with mask - lower scores are better (non-normalized)
                result = cv2.matchTemplate(frame, self.template, cv2.TM_SQDIFF, mask=self.mask)
            else:
                # No mask, use regular matching
                result = cv2.matchTemplate(frame, self.template, cv2.TM_SQDIFF)

            min_val, max_val, min_loc, max_loc = cv2.minMaxLoc(result)

            # For SQDIFF (non-normalized), lower scores are better matches
            # Normalize to 0-1 range: perfect match = 0, worst = very high value
            # Use a scaling factor based on template size
            template_pixels = self.template.shape[0] * self.template.shape[1] * self.template.shape[2]
            max_possible_diff = template_pixels * 255 * 255  # Max squared difference per pixel
            normalized_score = min_val / max_possible_diff
            confidence = 1.0 - min(normalized_score, 1.0)  # Clamp to [0, 1]

            # Check if match exceeds threshold
            if confidence >= threshold:
                # Calculate right edge x-coordinate
                template_width = self.template.shape[1]
                right_edge_x = min_loc[0] + template_width  # Use min_loc for SQDIFF

                self.logger.debug(
                    f"Right edge detected at x={right_edge_x} "
                    f"(template at {min_loc[0]}), confidence={confidence:.3f}"
                )
                return right_edge_x, confidence
            else:
                self.logger.debug(f"No right edge match (best confidence: {confidence:.3f}, threshold: {threshold:.2f})")
                return None, confidence  # Return best confidence even when no match

        except Exception as e:
            self.logger.error(f"Right edge detection error: {e}")
            return None, 0.0

    def create_debug_visualization(self, frame: np.ndarray, threshold: float = 0.7) -> np.ndarray:
        """
        Create a visualization showing detected right edge

        Args:
            frame: Input frame
            threshold: Detection threshold

        Returns:
            Visualization frame with overlay
        """
        # Ensure color output
        if len(frame.shape) == 2:
            vis = cv2.cvtColor(frame, cv2.COLOR_GRAY2BGR)
        else:
            vis = frame.copy()

        # Detect right edge
        right_edge_x, confidence = self.detect_right_edge(frame, threshold)

        if right_edge_x is not None and self.template is not None:
            # # Draw vertical line at right edge
            # cv2.line(vis, (right_edge_x, 0), (right_edge_x, vis.shape[0]), (0, 255, 255), 2)

            # Draw template bounding box
            template_h, template_w = self.template.shape[:2]
            template_x = right_edge_x - template_w

            # Find the y position (from the match location)
            if self.mask is not None:
                result = cv2.matchTemplate(frame, self.template, cv2.TM_SQDIFF, mask=self.mask)
            else:
                result = cv2.matchTemplate(frame, self.template, cv2.TM_SQDIFF)
            _, _, min_loc, _ = cv2.minMaxLoc(result)

            cv2.rectangle(vis,
                         (template_x, min_loc[1]),
                         (right_edge_x, min_loc[1] + template_h),
                         (0, 255, 0), 2)

            # Add text label
            label = f"Right Edge ({confidence:.2f})"
            cv2.putText(vis, label, (template_x, min_loc[1] - 5),
                       cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1)

        return vis


def test_right_edge_detector():
    """Test right edge detection on a sample image"""
    import sys

    # Configure logging to see debug output
    logging.basicConfig(
        level=logging.DEBUG,
        format='%(levelname)s - %(message)s'
    )

    # Get image path from command line or use default
    img_path = sys.argv[1] if len(sys.argv) > 1 else "/home/kaio/Dev/bazaar-ghost/.ignore/375(1).jpg"
    resolution = sys.argv[2] if len(sys.argv) > 2 else "480p"

    # Initialize detector
    detector = RightEdgeDetector(resolution=resolution)

    # Load test image
    img = cv2.imread(img_path)
    if img is None:
        print(f"Could not load image: {img_path}")
        return

    # Test detection
    threshold = 0.7
    right_edge_x, conf = detector.detect_right_edge(img, threshold=threshold)
    print(f"Detection result: right_edge_x={right_edge_x} (confidence: {conf:.3f})")

    # Show visualization
    vis = detector.create_debug_visualization(img, threshold=threshold)
    cv2.imshow("Right Edge Detection", vis)

    print("\nPress any key to exit...")
    cv2.waitKey(0)
    cv2.destroyAllWindows()


if __name__ == "__main__":
    test_right_edge_detector()