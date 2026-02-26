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
        templates_dir: str = "/home/kaio/Dev/bazaar-ghost/sfot/templates",
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
        self.logger = logging.getLogger("sfot.right_edge_detector")

        # Load resolution-specific template
        self._load_template()

    def _load_template(self):
        """Load right edge templates for the specified resolution"""
        self.templates = {}  # name -> {template, mask}

        # Load original template (with alpha/mask)
        orig_path = self.templates_dir / f"right_edge_{self.resolution}.png"
        if orig_path.exists():
            bgra = cv2.imread(str(orig_path), cv2.IMREAD_UNCHANGED)
            if bgra is not None and len(bgra.shape) == 3 and bgra.shape[2] == 4:
                tmpl = bgra[:, :, :3]
                alpha = bgra[:, :, 3]
                mask = (alpha > 0).astype(np.uint8)
                self.templates["orig"] = {"template": tmpl, "mask": mask}
                # Also store without mask variant
                self.templates["orig_nomask"] = {"template": tmpl, "mask": None}
                self.logger.info(
                    f"Loaded orig template {orig_path.name} ({tmpl.shape[1]}x{tmpl.shape[0]})"
                )

        # Load new template (no alpha)
        new_path = self.templates_dir / f"right_edge_{self.resolution}_new.png"
        if new_path.exists():
            tmpl = cv2.imread(str(new_path), cv2.IMREAD_COLOR)
            if tmpl is not None:
                self.templates["new"] = {"template": tmpl, "mask": None}
                self.logger.info(
                    f"Loaded new template {new_path.name} ({tmpl.shape[1]}x{tmpl.shape[0]})"
                )

        # Set self.template for backward compat (use first available)
        if self.templates:
            first = next(iter(self.templates.values()))
            self.template = first["template"]
            self.mask = first["mask"]
        else:
            self.logger.warning(f"No right edge templates found for {self.resolution}")

    def _binarize(self, image: np.ndarray) -> np.ndarray:
        """Convert image to binary using Otsu's thresholding

        Args:
            image: BGR or grayscale image

        Returns:
            Binary (single-channel) image
        """
        if len(image.shape) == 3:
            gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
        else:
            gray = image
        _, binary = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
        return binary

    def _run_bench_pass(
        self,
        frame: np.ndarray,
        templates: dict,
        methods: list,
        mask_methods: set,
        pass_label: str,
    ) -> list:
        """Run all method/template combos for a single benchmark pass

        Args:
            frame: The frame to match against (BGR or binary)
            templates: Dict of name -> {template, mask} to test
            methods: List of (method_name, method_flag, use_min) tuples
            mask_methods: Set of method flags that support mask parameter
            pass_label: Label prefix for log lines (e.g. 'color' or 'binary')

        Returns:
            List of formatted result strings
        """
        results = []

        for tmpl_name, tmpl_data in templates.items():
            template = tmpl_data["template"]
            mask = tmpl_data["mask"]

            # Skip if template doesn't fit
            if template.shape[0] > frame.shape[0] or template.shape[1] > frame.shape[1]:
                results.append(
                    f"  [{pass_label}] {tmpl_name}: SKIP (template larger than frame)"
                )
                continue

            for method_name, method_flag, use_min in methods:
                try:
                    # Only pass mask for methods that support it, and only if mask exists
                    use_mask = mask is not None and method_flag in mask_methods
                    if use_mask:
                        result = cv2.matchTemplate(
                            frame, template, method_flag, mask=mask
                        )
                    else:
                        result = cv2.matchTemplate(frame, template, method_flag)

                    min_val, max_val, min_loc, max_loc = cv2.minMaxLoc(result)

                    if use_min:
                        best_val = min_val
                        best_loc = min_loc
                    else:
                        best_val = max_val
                        best_loc = max_loc

                    template_width = template.shape[1]
                    right_edge_x = best_loc[0] + template_width
                    mask_str = "+mask" if use_mask else ""

                    results.append(
                        f"  [{pass_label}] {tmpl_name}/{method_name}{mask_str}: "
                        f"val={best_val:.4f} x={right_edge_x} (at {best_loc[0]},{best_loc[1]})"
                    )
                except Exception as e:
                    results.append(
                        f"  [{pass_label}] {tmpl_name}/{method_name}: ERROR {e}"
                    )

        return results

    def detect_right_edge(
        self, frame: np.ndarray, threshold: float = 0.7
    ) -> Tuple[Optional[int], float]:
        """
        Try all template matching methods across all loaded templates and log results.
        Runs two passes: color (original) and binary (Otsu thresholded).
        Returns (None, 0.0) — this is a benchmarking mode, not production detection.
        """
        if not self.templates:
            self.logger.warning("No templates loaded for right edge detection")
            return None, 0.0

        methods = [
            ("SQDIFF", cv2.TM_SQDIFF, True),  # (name, flag, use_min)
            ("SQDIFF_NORMED", cv2.TM_SQDIFF_NORMED, True),
            ("CCORR", cv2.TM_CCORR, False),
            ("CCORR_NORMED", cv2.TM_CCORR_NORMED, False),
            ("CCOEFF", cv2.TM_CCOEFF, False),
            ("CCOEFF_NORMED", cv2.TM_CCOEFF_NORMED, False),
        ]

        # Methods that support mask parameter
        mask_methods = {cv2.TM_SQDIFF, cv2.TM_CCORR_NORMED, cv2.TM_CCOEFF_NORMED}

        results = []

        # Pass 1: Color (original BGR templates against BGR frame)
        results.extend(
            self._run_bench_pass(frame, self.templates, methods, mask_methods, "color")
        )

        # Pass 2: Binary (Otsu thresholded frame and templates)
        binary_frame = self._binarize(frame)
        binary_templates = {}
        for tmpl_name, tmpl_data in self.templates.items():
            binary_tmpl = self._binarize(tmpl_data["template"])
            # Binarize mask too if present (threshold at 0 since mask is already 0/1)
            binary_mask = tmpl_data["mask"]
            binary_templates[tmpl_name] = {"template": binary_tmpl, "mask": binary_mask}

        results.extend(
            self._run_bench_pass(
                binary_frame, binary_templates, methods, mask_methods, "binary"
            )
        )

        self.logger.info("RIGHT_EDGE_BENCH:\n" + "\n".join(results))
        return None, 0.0

    def create_debug_visualization(
        self, frame: np.ndarray, threshold: float = 0.7
    ) -> np.ndarray:
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
                result = cv2.matchTemplate(
                    frame, self.template, cv2.TM_SQDIFF, mask=self.mask
                )
            else:
                result = cv2.matchTemplate(frame, self.template, cv2.TM_SQDIFF)
            _, _, min_loc, _ = cv2.minMaxLoc(result)

            cv2.rectangle(
                vis,
                (template_x, min_loc[1]),
                (right_edge_x, min_loc[1] + template_h),
                (0, 255, 0),
                2,
            )

            # Add text label
            label = f"Right Edge ({confidence:.2f})"
            cv2.putText(
                vis,
                label,
                (template_x, min_loc[1] - 5),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.5,
                (0, 255, 0),
                1,
            )

        return vis


def test_right_edge_detector():
    """Test right edge detection on a sample image"""
    import sys

    # Configure logging to see debug output
    logging.basicConfig(level=logging.DEBUG, format="%(levelname)s - %(message)s")

    # Get image path from command line or use default
    img_path = (
        sys.argv[1]
        if len(sys.argv) > 1
        else "/home/kaio/Dev/bazaar-ghost/.ignore/375(1).jpg"
    )
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
