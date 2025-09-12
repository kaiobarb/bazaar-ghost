#!/usr/bin/env python3
"""
Emblem detection and removal for improved OCR accuracy
Detects rank emblems in nameplate frames and masks them out
"""

import cv2
import numpy as np
from pathlib import Path
from typing import Tuple, Optional, Dict, Any
import logging

class EmblemDetector:
    """Detect and remove rank emblems from nameplate frames"""
    
    RANKS = ['bronze', 'silver', 'gold', 'diamond', 'legend']
    
    def __init__(self, templates_dir: str = "/home/kaio/Dev/bazaar-ghost/sfot/templates"):
        """Initialize with emblem templates"""
        self.templates_dir = Path(templates_dir)
        self.templates = {}
        self.logger = logging.getLogger(__name__)
        
        # Load all rank templates
        self._load_templates()
    
    def _load_templates(self):
        """Load all rank emblem templates"""
        for rank in self.RANKS:
            template_path = self.templates_dir / f"{rank}_480.png"
            if template_path.exists():
                template = cv2.imread(str(template_path))
                if template is not None:
                    # Keep templates in color for color matching
                    self.templates[rank] = template
                    self.logger.info(f"Loaded {rank} emblem template (color)")
                else:
                    self.logger.warning(f"Failed to load {rank} template")
            else:
                self.logger.warning(f"Template not found: {template_path}")
    
    def detect_emblem(self, frame: np.ndarray, threshold: float = 0.7) -> Tuple[Optional[str], Optional[Tuple[int, int, int, int]], float]:
        """
        Detect which emblem is present in the frame
        
        Args:
            frame: Input frame (can be color or grayscale)
            threshold: Matching threshold (0-1)
            
        Returns:
            (rank_name, (x, y, w, h), confidence) or (None, None, 0.0) if no match
        """
        # if len(frame.shape) == 3:
        #     gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        # else:
        #     gray = frame
        
        best_match = None
        best_confidence = 0
        best_location = None
        best_rank = None
        
        # Try each template
        for rank, template in self.templates.items():
            # Ensure template fits in frame
            if template.shape[0] > frame.shape[0] or template.shape[1] > frame.shape[1]:
                continue
            
            # Perform template matching
            result = cv2.matchTemplate(frame, template, cv2.TM_CCOEFF_NORMED)
            min_val, max_val, min_loc, max_loc = cv2.minMaxLoc(result)
            
            # Check if this is the best match so far
            if max_val > best_confidence and max_val >= threshold:
                best_confidence = max_val
                best_location = max_loc
                best_rank = rank
                # Get template dimensions - note: shape is (height, width, channels) for color
                h, w = template.shape[:2]
                best_match = (best_location[0], best_location[1], w, h)
                self.logger.debug(f"Match found: {rank} at ({max_loc[0]}, {max_loc[1]}), size=({w}x{h}), conf={max_val:.3f}")
        
        if best_match:
            self.logger.debug(f"Detected {best_rank} emblem with confidence {best_confidence:.3f}")
            return best_rank, best_match, best_confidence
        
        return None, None, 0.0
    
    def remove_emblem(self, frame: np.ndarray, 
                     threshold: float = 0.7,
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