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
    """Detect and remove rank emblems from nameplate frames using AKAZE feature matching"""

    RANKS = ['bronze', 'silver', 'gold', 'diamond', 'legend']

    def __init__(self, templates_dir: str = "/home/kaio/Dev/bazaar-ghost/sfot/templates", resolution: str = "480p"):
        """Initialize with emblem templates and AKAZE detector

        Args:
            templates_dir: Directory containing emblem templates
            resolution: Resolution to use for templates (360p, 480p, 720p, 1080p)
        """
        self.templates_dir = Path(templates_dir)
        self.resolution = resolution
        self.logger = logging.getLogger(__name__)

        # Initialize AKAZE detector and matcher
        self.detector = cv2.AKAZE_create()
        self.matcher = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=False)

        # Storage for pre-computed template features
        self.template_keypoints = {}
        self.template_descriptors = {}
        self.template_shapes = {}  # Store template dimensions for bbox calculation
        self.templates = {}  # Keep for visualization/debugging

        # Load all rank templates and pre-compute descriptors
        self._load_templates()

    def _load_templates(self):
        """Load all rank emblem templates and pre-compute AKAZE features"""
        for rank in self.RANKS:
            # Try new naming scheme first (with resolution suffix)
            template_path = self.templates_dir / f"{rank}_{self.resolution}.png"

            # Fallback to old naming for 480p if new file doesn't exist
            if not template_path.exists() and self.resolution == "480p":
                template_path = self.templates_dir / f"_{rank}_480.png"

            if template_path.exists():
                # Load template WITH alpha channel for transparency support
                template_bgra = cv2.imread(str(template_path), cv2.IMREAD_UNCHANGED)
                if template_bgra is not None:
                    # Extract BGR channels (ignore alpha for AKAZE)
                    if len(template_bgra.shape) == 3 and template_bgra.shape[2] == 4:
                        template = template_bgra[:,:,:3]  # BGR channels only
                    else:
                        template = template_bgra

                    # Store template for later use (removal, visualization)
                    self.templates[rank] = template
                    self.template_shapes[rank] = template.shape[:2]  # (height, width)

                    # Pre-compute AKAZE keypoints and descriptors
                    kp, des = self.detector.detectAndCompute(template, None)

                    if des is not None and len(des) > 0:
                        self.template_keypoints[rank] = kp
                        self.template_descriptors[rank] = des
                        self.logger.info(f"Loaded {rank} emblem: {len(kp)} keypoints from {template_path.name}")
                    else:
                        self.logger.warning(f"No keypoints found in {rank} template")
                else:
                    self.logger.warning(f"Failed to load {rank} template")
            else:
                self.logger.warning(f"Template not found: {template_path}")
    
    def detect_emblem(self, frame: np.ndarray, threshold: float = 0.30) -> Tuple[Optional[str], Optional[Tuple[int, int, int, int]], float]:
        """
        Detect which emblem is present in the frame using AKAZE feature matching

        Args:
            frame: Input frame (color BGR)
            threshold: Matching confidence threshold (0-1), default 0.30 for AKAZE

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

            # Try to find homography for better bbox and confidence
            if len(good_matches) >= 4:
                src_pts = np.float32([template_kp[m.queryIdx].pt for m in good_matches]).reshape(-1, 1, 2)
                dst_pts = np.float32([frame_kp[m.trainIdx].pt for m in good_matches]).reshape(-1, 1, 2)

                homography, inliers = cv2.findHomography(src_pts, dst_pts, cv2.RANSAC, 5.0)

                if homography is not None and inliers is not None:
                    # Update confidence with inlier ratio
                    inlier_ratio = np.sum(inliers) / len(good_matches)
                    confidence = confidence * 0.7 + inlier_ratio * 0.3

                    # Calculate bounding box using homography
                    h, w = self.template_shapes[rank]
                    pts = np.float32([[0, 0], [0, h-1], [w-1, h-1], [w-1, 0]]).reshape(-1, 1, 2)
                    dst = cv2.perspectiveTransform(pts, homography)

                    # Get bounding rectangle
                    x, y, w, h = cv2.boundingRect(dst)
                    bbox = (x, y, w, h)
                else:
                    # No valid homography, estimate bbox from matches
                    dst_points = [frame_kp[m.trainIdx].pt for m in good_matches]
                    if dst_points:
                        xs = [p[0] for p in dst_points]
                        ys = [p[1] for p in dst_points]
                        x, y = int(min(xs)), int(min(ys))
                        w, h = self.template_shapes[rank]
                        bbox = (x, y, w, h)
                    else:
                        bbox = None
            else:
                # Not enough matches for homography, estimate bbox
                dst_points = [frame_kp[m.trainIdx].pt for m in good_matches]
                if dst_points:
                    xs = [p[0] for p in dst_points]
                    ys = [p[1] for p in dst_points]
                    x, y = int(min(xs)), int(min(ys))
                    w, h = self.template_shapes[rank]
                    bbox = (x, y, w, h)
                else:
                    bbox = None

            # Check if this is the best match so far
            if confidence > best_confidence and confidence >= threshold:
                best_confidence = confidence
                best_rank = rank
                best_bbox = bbox
                self.logger.debug(f"Match found: {rank} with {len(good_matches)} matches, conf={confidence:.3f}")

        if best_rank:
            self.logger.debug(f"Detected {best_rank} emblem with confidence {best_confidence:.3f}")
            return best_rank, best_bbox, best_confidence

        return None, None, 0.0
    
    def remove_emblem(self, frame: np.ndarray,
                     threshold: float = 0.30,
                     expand_pixels: int = 2,
                     fill_value: int = 0) -> Tuple[np.ndarray, Optional[str]]:
        """
        Detect and remove emblem from frame by masking it out
        
        Args:
            frame: Input frame
            threshold: Detection threshold
            expand_pixels: Expand mask by this many pixels to ensure complete removal
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
        
        # Expand the bounding box
        x1 = max(0, x - expand_pixels)
        y1 = max(0, y - expand_pixels)
        x2 = min(result.shape[1], x + w + expand_pixels)
        y2 = min(result.shape[0], y + h + expand_pixels)
        
        self.logger.debug(f"Removing {rank} emblem: bbox=({x},{y},{w},{h}), expanded=({x1},{y1},{x2},{y2}), fill={fill_value}")
        
        # Fill the region
        if len(result.shape) == 3:
            # For color images, fill all channels
            result[y1:y2, x1:x2] = [fill_value, fill_value, fill_value]
        else:
            result[y1:y2, x1:x2] = fill_value
        
        return result, rank
    
    def create_debug_visualization(self, frame: np.ndarray, 
                                  threshold: float = 0.2,
                                  expand_pixels: int = 2) -> np.ndarray:
        """
        Create a visualization showing detected emblem and mask area
        
        Args:
            frame: Input frame
            threshold: Detection threshold
            expand_pixels: Mask expansion
            
        Returns:
            Visualization frame with overlays
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
            
            # Draw detection rectangle (green)
            cv2.rectangle(vis, (x, y), (x + w, y + h), (0, 255, 0), 2)
            
            # Draw expanded mask area (red)
            x1 = max(0, x - expand_pixels)
            y1 = max(0, y - expand_pixels)
            x2 = min(vis.shape[1], x + w + expand_pixels)
            y2 = min(vis.shape[0], y + h + expand_pixels)
            cv2.rectangle(vis, (x1, y1), (x2, y2), (0, 0, 255), 1)
            
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
    vis = detector.create_debug_visualization(img, threshold=threshold, expand_pixels=5)
    cv2.imshow("Emblem Detection", vis)
    
    # Show removal result with more aggressive expansion
    removed, detected_rank = detector.remove_emblem(img, threshold=threshold, expand_pixels=5, fill_value=0)
    cv2.imshow("Emblem Removed", removed)
    
    # Also show the difference
    diff = cv2.absdiff(img, removed)
    cv2.imshow("Difference", diff)
    
    print("\nPress any key to exit...")
    cv2.waitKey(0)
    cv2.destroyAllWindows()


if __name__ == "__main__":
    test_emblem_detector()