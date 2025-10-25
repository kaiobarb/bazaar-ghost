#!/usr/bin/env python3
"""
Emblem detection and removal for improved OCR accuracy
Uses AKAZE feature matching for robust emblem detection
"""

import cv2
import numpy as np
from pathlib import Path
from typing import Tuple, Optional, Dict, Any, List
import logging

class EmblemDetector:
    """Detect and remove rank emblems using AKAZE feature matching or template matching"""

    RANKS = ['bronze', 'silver', 'gold', 'diamond', 'legend']

    def __init__(self, templates_dir: str = "/home/kaio/Dev/bazaar-ghost/sfot/templates", resolution: str = "480p", method: str = "akaze", feature_resolution: Optional[str] = None):
        """Initialize with emblem templates and detection method

        Args:
            templates_dir: Directory containing emblem templates
            resolution: Resolution to use for templates (360p, 480p, 720p, 1080p)
            method: Detection method - 'akaze' or 'template' (default: 'akaze')
            feature_resolution: Resolution to use for AKAZE feature extraction (e.g., '1080p' for better keypoints).
                               If None or method != 'akaze', uses resolution for everything.
        """
        self.templates_dir = Path(templates_dir)
        self.resolution = resolution
        self.method = method.lower()
        self.logger = logging.getLogger(__name__)

        # For AKAZE: optionally use higher resolution templates for feature extraction
        if self.method == 'akaze' and feature_resolution and feature_resolution != resolution:
            self.feature_resolution = feature_resolution
            self.logger.info(f"Using {feature_resolution} templates for AKAZE features, {resolution} for bbox dimensions")
        else:
            self.feature_resolution = resolution

        # Initialize AKAZE detector and matcher (only if using AKAZE method)
        if self.method == 'akaze':
            self.detector = cv2.AKAZE_create()
            self.matcher = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=False)
            self.logger.info(f"EmblemDetector initialized with AKAZE method")
        elif self.method == 'template':
            self.detector = None
            self.matcher = None
            self.logger.info(f"EmblemDetector initialized with template matching method")
        else:
            raise ValueError(f"Unknown detection method: {self.method}. Use 'akaze' or 'template'")

        # Storage for pre-computed template features
        self.template_keypoints = {}
        self.template_descriptors = {}
        self.template_shapes = {}  # Store template dimensions for bbox calculation (at resolution)
        self.feature_template_shapes = {}  # Store feature template dimensions (at feature_resolution)
        self.template_masks = {}  # Alpha masks for template matching
        self.templates = {}  # Keep for visualization/debugging

        # Load all rank templates and pre-compute features
        self._load_templates()

    def _load_templates(self):
        """Load all rank emblem templates and pre-compute AKAZE features"""
        for rank in self.RANKS:
            # Load template at processing resolution (for bbox dimensions and template matching)
            template_path = self.templates_dir / f"{rank}_{self.resolution}.png"

            # Fallback to old naming for 480p if new file doesn't exist
            if not template_path.exists() and self.resolution == "480p":
                template_path = self.templates_dir / f"_{rank}_480.png"

            if template_path.exists():
                # Load template WITH alpha channel for transparency support
                template_bgra = cv2.imread(str(template_path), cv2.IMREAD_UNCHANGED)
                if template_bgra is not None:
                    # Extract BGR channels and alpha mask
                    if len(template_bgra.shape) == 3 and template_bgra.shape[2] == 4:
                        template = template_bgra[:,:,:3]  # BGR channels only
                        alpha = template_bgra[:,:,3]
                        # Create binary mask: pixels with alpha > 0 are valid
                        self.template_masks[rank] = (alpha > 0).astype(np.uint8)
                    else:
                        template = template_bgra
                        self.template_masks[rank] = None

                    # Store template for later use (removal, visualization)
                    self.templates[rank] = template
                    self.template_shapes[rank] = template.shape[:2]  # (height, width)

                    # For AKAZE: load feature template if using different resolution
                    if self.method == 'akaze' and self.feature_resolution != self.resolution:
                        feature_template_path = self.templates_dir / f"{rank}_{self.feature_resolution}.png"

                        if feature_template_path.exists():
                            feature_template_bgra = cv2.imread(str(feature_template_path), cv2.IMREAD_UNCHANGED)
                            if feature_template_bgra is not None:
                                # Extract BGR channels only
                                if len(feature_template_bgra.shape) == 3 and feature_template_bgra.shape[2] == 4:
                                    feature_template = feature_template_bgra[:,:,:3]
                                else:
                                    feature_template = feature_template_bgra

                                # Store feature template dimensions
                                self.feature_template_shapes[rank] = feature_template.shape[:2]

                                # Compute AKAZE features from high-res template
                                kp, des = self.detector.detectAndCompute(feature_template, None)

                                if des is not None and len(des) > 0:
                                    self.template_keypoints[rank] = kp
                                    self.template_descriptors[rank] = des
                                    self.logger.info(f"Loaded {rank} emblem: {len(kp)} keypoints from {feature_template_path.name} (bbox dims from {template_path.name})")
                                else:
                                    self.logger.warning(f"No keypoints found in {rank} feature template at {self.feature_resolution}")
                            else:
                                self.logger.warning(f"Failed to load {rank} feature template at {self.feature_resolution}")
                        else:
                            self.logger.warning(f"Feature template not found: {feature_template_path}, falling back to {self.resolution}")
                            # Fallback: use processing resolution template for features
                            self.feature_template_shapes[rank] = template.shape[:2]
                            kp, des = self.detector.detectAndCompute(template, None)
                            if des is not None and len(des) > 0:
                                self.template_keypoints[rank] = kp
                                self.template_descriptors[rank] = des
                                self.logger.info(f"Loaded {rank} emblem: {len(kp)} keypoints from {template_path.name} (fallback)")
                            else:
                                self.logger.warning(f"No keypoints found in {rank} template")
                    elif self.method == 'akaze':
                        # AKAZE without multi-resolution: use same template for everything
                        self.feature_template_shapes[rank] = template.shape[:2]
                        kp, des = self.detector.detectAndCompute(template, None)

                        if des is not None and len(des) > 0:
                            self.template_keypoints[rank] = kp
                            self.template_descriptors[rank] = des
                            self.logger.info(f"Loaded {rank} emblem: {len(kp)} keypoints from {template_path.name}")
                        else:
                            self.logger.warning(f"No keypoints found in {rank} template")
                    else:
                        # Template matching mode - just log that we loaded it
                        mask_info = "with mask" if self.template_masks[rank] is not None else "without mask"
                        self.logger.info(f"Loaded {rank} emblem template {mask_info} from {template_path.name}")
                else:
                    self.logger.warning(f"Failed to load {rank} template")
            else:
                self.logger.warning(f"Template not found: {template_path}")
    
    def _detect_emblem_akaze(self, frame: np.ndarray, threshold: float) -> Tuple[Optional[str], Optional[Tuple[int, int, int, int]], float]:
        """
        Detect which emblem is present using AKAZE feature matching

        Args:
            frame: Input frame (color BGR)
            threshold: Matching confidence threshold (0-1)

        Returns:
            (rank_name, (x, y, w, h), confidence) or (None, None, 0.0) if no match
        """
        # Extract frame keypoints and descriptors
        frame_kp, frame_des = self.detector.detectAndCompute(frame, None)

        if frame_des is None or len(frame_des) == 0:
            self.logger.debug("No keypoints found in frame")
            return None, None, 0.0

        best_rank = None
        best_bbox = None
        best_confidence = 0.0

        # Try matching against each rank template
        for rank in self.RANKS:
            if rank not in self.template_descriptors:
                continue

            template_des = self.template_descriptors[rank]
            template_kp = self.template_keypoints[rank]

            # Match descriptors
            matches = self.matcher.knnMatch(template_des, frame_des, k=2)

            # Apply Lowe's ratio test
            good_matches = []
            for match_pair in matches:
                if len(match_pair) == 2:
                    m, n = match_pair
                    if m.distance < 0.75 * n.distance:  # Lowe's ratio
                        good_matches.append(m)

            if len(good_matches) == 0:
                continue

            # Calculate confidence score
            match_ratio = len(good_matches) / min(len(template_kp), len(frame_kp))
            avg_distance = np.mean([m.distance for m in good_matches])
            # Hamming distance normalization for AKAZE
            distance_score = max(0, 1.0 - avg_distance / 64.0)
            confidence = match_ratio * 0.5 + distance_score * 0.5

            # Try to find homography for validation and confidence boost
            # Use homography bbox geometry to filter false positives
            homography_valid = False
            if len(good_matches) >= 4:
                src_pts = np.float32([template_kp[m.queryIdx].pt for m in good_matches]).reshape(-1, 1, 2)
                dst_pts = np.float32([frame_kp[m.trainIdx].pt for m in good_matches]).reshape(-1, 1, 2)

                homography, inliers = cv2.findHomography(src_pts, dst_pts, cv2.RANSAC, 5.0)

                if homography is not None and inliers is not None:
                    # Update confidence with inlier ratio
                    inlier_ratio = np.sum(inliers) / len(good_matches)
                    confidence = confidence * 0.7 + inlier_ratio * 0.3

                    # Calculate homography bbox for validation (catches false positives)
                    # Use feature template dimensions for homography validation
                    feature_h, feature_w = self.feature_template_shapes[rank]
                    pts = np.float32([[0, 0], [0, feature_h-1], [feature_w-1, feature_h-1], [feature_w-1, 0]]).reshape(-1, 1, 2)
                    dst = cv2.perspectiveTransform(pts, homography)

                    # Get homography bounding rectangle
                    hom_x, hom_y, hom_w, hom_h = cv2.boundingRect(dst)

                    # Validate homography bbox geometry (filters false positives)
                    # Check: reasonable size (not too small/distorted)
                    area_ratio = (hom_w * hom_h) / (feature_w * feature_h)
                    aspect_ratio = hom_w / hom_h if hom_h > 0 else 0
                    template_aspect = feature_w / feature_h

                    # Accept if: area is 50-200% of template, aspect ratio similar
                    if (0.5 <= area_ratio <= 2.0 and
                        0.7 <= aspect_ratio / template_aspect <= 1.4):
                        homography_valid = True
                    else:
                        self.logger.debug(f"Rejecting {rank}: bad homography geometry (area_ratio={area_ratio:.2f}, aspect={aspect_ratio:.2f})")

            # Only return bbox if homography validation passed (or not enough matches for homography)
            if homography_valid or len(good_matches) < 4:
                # Calculate bbox using actual template dimensions at keypoint centroid
                # This is the bbox we actually use for processing
                dst_points = [frame_kp[m.trainIdx].pt for m in good_matches]
                if dst_points:
                    # Use median of matched keypoints for robust center estimate
                    xs = [p[0] for p in dst_points]
                    ys = [p[1] for p in dst_points]
                    center_x = np.median(xs)
                    center_y = np.median(ys)

                    # Place bbox using actual template dimensions (not feature template dimensions)
                    # This ensures bbox matches the processing resolution
                    actual_h, actual_w = self.template_shapes[rank]
                    x = int(center_x - actual_w / 2)
                    y = int(center_y - actual_h / 2)
                    bbox = (x, y, actual_w, actual_h)
                else:
                    bbox = None
            else:
                # Homography validation failed - reject this detection
                bbox = None

            # Check if this is the best match so far (only if bbox is valid)
            if bbox is not None and confidence > best_confidence and confidence >= threshold:
                best_confidence = confidence
                best_rank = rank
                best_bbox = bbox
                self.logger.debug(f"Match found: {rank} with {len(good_matches)} matches, conf={confidence:.3f}")
            elif bbox is None and confidence >= threshold:
                self.logger.debug(f"Rejecting {rank} match (conf={confidence:.3f}): bbox validation failed")

        if best_rank:
            self.logger.debug(f"Detected {best_rank} emblem with confidence {best_confidence:.3f}")
            return best_rank, best_bbox, best_confidence

        return None, None, 0.0

    def _detect_emblem_template(self, frame: np.ndarray, threshold: float = 0.85) -> Tuple[Optional[str], Optional[Tuple[int, int, int, int]], float]:
        """
        Detect which emblem is present using template matching with TM_SQDIFF_NORMED

        Args:
            frame: Input frame (color BGR)
            threshold: Matching confidence threshold (0-1)

        Returns:
            (rank_name, (x, y, w, h), confidence) or (None, None, 0.0) if no match
        """
        best_rank = None
        best_bbox = None
        best_confidence = 0.0

        # Try matching against each rank template
        for rank in self.RANKS:
            if rank not in self.templates:
                continue

            template = self.templates[rank]
            mask = self.template_masks.get(rank)

            # Check template fits in frame
            if template.shape[0] > frame.shape[0] or template.shape[1] > frame.shape[1]:
                self.logger.debug(f"Template {rank} too large for frame, skipping")
                continue

            # Perform template matching
            try:
                if mask is not None:
                    result = cv2.matchTemplate(frame, template, cv2.TM_SQDIFF_NORMED, mask=mask)
                else:
                    result = cv2.matchTemplate(frame, template, cv2.TM_SQDIFF_NORMED)

                min_val, max_val, min_loc, max_loc = cv2.minMaxLoc(result)
                confidence = 1.0 - min_val  # TM_SQDIFF_NORMED: lower is better

                if confidence > best_confidence and confidence >= threshold:
                    best_confidence = confidence
                    best_rank = rank
                    # Bbox at match location with template dimensions
                    h, w = template.shape[:2]
                    best_bbox = (min_loc[0], min_loc[1], w, h)
                    self.logger.debug(f"Template match found: {rank} at {min_loc}, conf={confidence:.3f}")

            except Exception as e:
                self.logger.error(f"Template matching error for {rank}: {e}")
                continue

        if best_rank:
            self.logger.debug(f"Detected {best_rank} emblem (template) with confidence {best_confidence:.3f}")
            return best_rank, best_bbox, best_confidence

        return None, None, 0.0

    def detect_emblem(self, frame: np.ndarray, threshold: float = 0.30) -> Tuple[Optional[str], Optional[Tuple[int, int, int, int]], float]:
        """
        Detect which emblem is present in the frame

        Uses AKAZE feature matching or template matching based on initialization method

        Args:
            frame: Input frame (color BGR)
            threshold: Matching confidence threshold (0-1), default 0.30 for AKAZE

        Returns:
            (rank_name, (x, y, w, h), confidence) or (None, None, 0.0) if no match
        """
        if self.method == 'template':
            return self._detect_emblem_template(frame)
        elif self.method == 'akaze':
            return self._detect_emblem_akaze(frame, threshold)
        else:
            raise ValueError(f"Unknown detection method: {self.method}")

    def remove_emblem(self, frame: np.ndarray,
                     threshold: float = 0.30,
                     fill_value: int = 0) -> Tuple[np.ndarray, Optional[str]]:
        """
        Detect and remove emblem from frame by masking it out

        Args:
            frame: Input frame
            threshold: Detection threshold
            fill_value: Value to fill masked area (0=black, 255=white)

        Returns:
            (processed_frame, detected_rank)
        """
        # Detect emblem
        rank, bbox, confidence = self.detect_emblem(frame, threshold)

        if bbox is None:
            return frame, None

        # Create output frame
        result = frame.copy()
        x, y, w, h = bbox

        # Use exact bounding box
        x1 = max(0, x)
        y1 = max(0, y)
        x2 = min(result.shape[1], x + w)
        y2 = min(result.shape[0], y + h)

        self.logger.debug(f"Removing {rank} emblem: bbox=({x},{y},{w},{h}), fill={fill_value}")

        # Fill the region
        if len(result.shape) == 3:
            # For color images, fill all channels
            result[y1:y2, x1:x2] = [fill_value, fill_value, fill_value]
        else:
            result[y1:y2, x1:x2] = fill_value

        return result, rank
    
    def create_debug_visualization(self, frame: np.ndarray,
                                  threshold: float = 0.2) -> np.ndarray:
        """
        Create a visualization showing detected emblem bounding box

        Args:
            frame: Input frame
            threshold: Detection threshold

        Returns:
            Visualization frame with bbox overlay
        """
        # Ensure color output
        if len(frame.shape) == 2:
            vis = cv2.cvtColor(frame, cv2.COLOR_GRAY2BGR)
        else:
            vis = frame.copy()
        
        # Detect emblem
        rank, bbox, confidence = self.detect_emblem(frame, threshold)
        
        if bbox:
            x, y, w, h = bbox

            # Draw detection rectangle (green) - exact template dimensions
            cv2.rectangle(vis, (x, y), (x + w, y + h), (0, 255, 0), 2)

            # Add text label
            label = f"{rank.upper()} ({confidence:.2f})"
            cv2.putText(vis, label, (x, y - 5),
                       cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1)
        
        return vis


def test_emblem_detector():
    """Test emblem detection on a sample image"""
    import sys
    
    # Configure logging to see debug output
    logging.basicConfig(
        level=logging.NOTSET,
        format='%(levelname)s - %(message)s'
    )
    
    # Get image path from command line or use default
    img_path = sys.argv[1] if len(sys.argv) > 1 else "/home/kaio/Dev/bazaar-ghost/.ignore/375(1).jpg"
    
    # Initialize detector
    detector = EmblemDetector()
    
    # Load test image
    img = cv2.imread(img_path)
    if img is None:
        print(f"Could not load image: {img_path}")
        return
    
    # Test detection with lower threshold for testing
    threshold = 0.4  # Lower threshold since we're getting 0.442
    rank, bbox, conf = detector.detect_emblem(img, threshold=threshold)
    print(f"Detection result: {rank} (confidence: {conf:.3f})")
    
    if bbox:
        print(f"Location: x={bbox[0]}, y={bbox[1]}, w={bbox[2]}, h={bbox[3]}")
    
    # Show visualization
    vis = detector.create_debug_visualization(img, threshold=threshold)
    cv2.imshow("Emblem Detection", vis)
    
    # Show removal result
    removed, detected_rank = detector.remove_emblem(img, threshold=threshold, fill_value=0)
    cv2.imshow("Emblem Removed", removed)
    
    # Also show the difference
    diff = cv2.absdiff(img, removed)
    cv2.imshow("Difference", diff)
    
    print("\nPress any key to exit...")
    cv2.waitKey(0)
    cv2.destroyAllWindows()


if __name__ == "__main__":
    test_emblem_detector()