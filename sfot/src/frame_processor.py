"""
Frame processor module - Handles OpenCV detection and Tesseract OCR
"""

import cv2
import numpy as np
import pytesseract
from typing import Optional, Dict, Any, Tuple
import logging
import base64
from PIL import Image
import io
from emblem_detector import EmblemDetector
from right_edge_detector import RightEdgeDetector
class FrameProcessor:
    """Process frames for matchup detection and OCR"""
    
    def __init__(self, config: Dict[str, Any], quality: str = "480p", test_mode: bool = False, old_templates: bool = False, method: str = 'template', profile: Optional[Dict[str, Any]] = None):
        """Initialize frame processor with configuration

        Args:
            config: Configuration dictionary
            quality: Video quality being processed (360p, 480p, 720p, 1080p)
            test_mode: Whether running in test mode
            old_templates: Whether to use underscore-prefixed templates for older VODs
            profile: SFOT profile containing custom_edge and opaque_edge settings
        """
        self.config = config
        self.quality = quality
        self.test_mode = test_mode
        self.old_templates = old_templates
        self.logger = logging.getLogger('sfot.frame_processor')
        self.method = method

        # Store profile settings for custom edge detection
        self.profile = profile or {}
        self.custom_edge_percent = self.profile.get('custom_edge')  # e.g., 0.80 = 80%
        self.opaque_edge = self.profile.get('opaque_edge', False)  # Default False for backward compatibility

        # Log custom edge settings if present
        if self.custom_edge_percent is not None:
            self.logger.info(f"Custom edge configured: {self.custom_edge_percent*100:.1f}% of crop width, opaque={self.opaque_edge}")

        # Load detection parameters
        self.threshold = config['detection']['threshold']

        # Load matchup template if specified
        self.matchup_template = None
        if 'template_path' in config['detection']:
            try:
                self.matchup_template = cv2.imread(config['detection']['template_path'], 0)
                self.logger.info(f"Loaded matchup template: {config['detection']['template_path']}")
            except Exception as e:
                self.logger.warning(f"Could not load matchup template: {e}")

        # Map quality to resolution for templates
        resolution_map = {
            '360p': '360p',
            '480p': '480p',
            '720p': '720p',
            '1080p': '1080p',
            '1080p60': '1080p'  # Use 1080p templates for 1080p60 too
        }
        template_resolution = resolution_map.get(quality, '480p')

        # Initialize emblem detector
        self.emblem_detector = None
        if config.get('emblem_detection', {}).get('enabled', False):
            try:
                emblem_config = config['emblem_detection']
                templates_dir = emblem_config.get('templates_dir', 'templates/')

                # Get feature resolution for AKAZE (optional)
                feature_resolution = emblem_config.get('akaze_feature_resolution') if method == 'akaze' else None

                # Initialize detector with method and optional feature resolution
                # Use TM_CCOEFF_NORMED for better discrimination against gameplay UI
                template_method = emblem_config.get('template_method', 'TM_CCOEFF_NORMED')
                self.emblem_detector = EmblemDetector(
                    templates_dir,
                    resolution=template_resolution,
                    method=method,
                    feature_resolution=feature_resolution,
                    old_templates=self.old_templates,
                    template_method=template_method
                )

                # Set threshold based on method
                if method == 'akaze':
                    self.emblem_threshold = emblem_config.get('akaze_threshold', 0.30)
                elif method == 'template':
                    self.emblem_threshold = emblem_config.get('template_threshold', 0.80)
                else:
                    self.emblem_threshold = 0.30  # fallback

                self.logger.info(f"Initialized emblem detector with {template_resolution} templates using {method} method (threshold={self.emblem_threshold})")

                # Log template dimensions for debugging
                if hasattr(self.emblem_detector, 'templates'):
                    for rank, template in self.emblem_detector.templates.items():
                        if template is not None:
                            h, w = template.shape[:2]
                            self.logger.info(f"Template '{rank}' dimensions: {w}x{h} pixels ({template_resolution})")

            except Exception as e:
                self.logger.warning(f"Could not initialize emblem detector: {e}")

        # Initialize right edge detector
        self.right_edge_detector = None
        self.right_edge_crop_margin = 0.0
        if config.get('right_edge_detection', {}).get('enabled', True):
            try:
                templates_dir = config.get('right_edge_detection', {}).get('templates_dir',
                                          config.get('emblem_detection', {}).get('templates_dir', 'templates/'))
                self.right_edge_detector = RightEdgeDetector(templates_dir, resolution=template_resolution)
                self.right_edge_threshold = config.get('right_edge_detection', {}).get('threshold', 0.7)
                # Crop margin: crop this % more to avoid edge artifacts (e.g., 10% = crop at x=90 if edge at x=100)
                self.right_edge_crop_margin = config.get('right_edge_detection', {}).get('crop_margin_percent', 10) / 100.0
                self.logger.info(f"Initialized right edge detector with {template_resolution} template (crop margin: {self.right_edge_crop_margin*100:.0f}%)")
            except Exception as e:
                self.logger.warning(f"Could not initialize right edge detector: {e}")
        
        # OCR preprocessing parameters
        self.ocr_preprocessing = config.get('ocr_preprocessing', {})
        
        # Tesseract configuration - enhanced with tuned parameters
        base_config = config['tesseract']['config']
        psm = config['tesseract'].get('psm', 7)
        oem = config['tesseract'].get('oem', 1)
        dpi = config['tesseract'].get('dpi', 480)
        self.tesseract_config = f"--oem {oem} --psm {psm} -c tessedit_user_defined_dpi={dpi} {base_config}"
        self.tesseract_lang = config['tesseract']['lang']
        
        # Cache for performance
        self.last_matchup_time = 0
        self.min_matchup_interval = 10  # Minimum seconds between matchups
    
    def process_frame(self, frame_data: bytes, timestamp: int, vod_id: str, chunk_id: str) -> Optional[Dict[str, Any]]:
        """
        Process a single frame for matchup detection

        Args:
            frame_data: JPEG frame data
            timestamp: Timestamp in seconds
            vod_id: VOD identifier
            chunk_id: Chunk uuid

        Returns:
            Detection result or None
        """
        try:
            # Decode frame
            frame = self._decode_frame(frame_data)
            if frame is None:
                return None

            # PHASE 1: Emblem detection first (5 template scans)
            detected_rank, emblem_bbox, emblem_confidence = self._detect_emblem_first(frame)

            if detected_rank is None:
                # No emblem found, no matchup
                return None

            # Reject if bbox is None (detection without valid bounding box)
            if emblem_bbox is None:
                self.logger.info(f"Rejecting detection at {timestamp}s: emblem detected but bbox is None")
                return None

            # Validate emblem bounding box position and size
            if emblem_bbox and self.method != 'template':
                x, y, w, h = emblem_bbox
                frame_h, frame_w = frame.shape[:2]

                # Check 0: Bounding box dimensions must be positive
                if w <= 0 or h <= 0:
                    self.logger.info(f"Rejecting detection at {timestamp}s: invalid bbox dimensions (w={w}, h={h})")
                    return None

                # Calculate centroid (allow bbox to extend slightly off-frame)
                centroid_x = x + w / 2
                centroid_y = y + h / 2

                # Check 1: Centroid must be within frame boundaries
                if centroid_x < 0 or centroid_x >= frame_w or centroid_y < 0 or centroid_y >= frame_h:
                    self.logger.info(f"Rejecting detection at {timestamp}s: centroid outside frame (centroid={centroid_x:.1f},{centroid_y:.1f}, frame={frame_w}x{frame_h})")
                    return None

                # Check 2: Centroid must be vertically centered (within middle 60% of frame height)
                # This allows for slight vertical offset but rejects wildly misplaced detections
                min_y = frame_h * 0.20  # Top 20% margin
                max_y = frame_h * 0.80  # Bottom 20% margin
                if centroid_y < min_y or centroid_y > max_y:
                    self.logger.info(f"Rejecting detection at {timestamp}s: centroid not vertically centered (y={centroid_y:.1f}, valid range={min_y:.1f}-{max_y:.1f})")
                    return None

                # Check 3: Emblem height must be reasonable (at least 80% of frame height)
                # Reduced from 90% to allow for some variation in template size
                min_height = frame_h * 0.80
                if h < min_height:
                    self.logger.info(f"Rejecting detection at {timestamp}s: emblem too short (h={h:.1f}, min={min_height:.1f})")
                    return None

            # Check minimum interval
            if timestamp - self.last_matchup_time < self.min_matchup_interval:
                return None

            self.last_matchup_time = timestamp

            # Calculate emblem right boundary for cropping (needed for multi-crop OCR)
            emblem_right_x = None
            if emblem_bbox:
                x, y, w, h = emblem_bbox
                emblem_right_x = min(frame.shape[1], x + w)  # Use exact bbox width

            # Right edge detection with custom edge support
            right_edge_x = None
            no_right_edge = False
            truncated = False  # Track if custom edge was used

            if self.opaque_edge and self.custom_edge_percent is not None:
                # Case 1: opaque_edge=true - always use custom_edge, skip detection entirely
                # Calculate custom edge position based on frame width
                right_edge_x = int(frame.shape[1] * self.custom_edge_percent)
                truncated = True
                self.logger.info(f"Using custom edge (opaque mode) at {right_edge_x}px ({self.custom_edge_percent*100:.1f}% of frame width)")

            elif self.right_edge_detector:
                # Case 2: opaque_edge=false or null - try regular detection first
                right_edge_x, right_conf = self.right_edge_detector.detect_right_edge(frame, self.right_edge_threshold)

                if right_edge_x is None:
                    # No right edge detected
                    no_right_edge = True

                    # Case 3: Fall back to multi-crop OCR if custom_edge configured
                    if self.custom_edge_percent is not None:
                        # Try multi-crop OCR to find optimal crop position
                        self.logger.info(f"No right edge detected, trying multi-crop OCR (custom_edge={self.custom_edge_percent*100:.1f}% as max bound)")

                        optimal_crop_x = self._multi_crop_ocr(frame, emblem_right_x, timestamp)

                        if optimal_crop_x is not None:
                            right_edge_x = optimal_crop_x
                            truncated = True
                            self.logger.info(f"Multi-crop OCR found optimal crop at {right_edge_x}px")
                        else:
                            # Multi-crop failed, fall back to custom_edge directly
                            right_edge_x = int(frame.shape[1] * self.custom_edge_percent)
                            truncated = True
                            self.logger.info(f"Multi-crop failed, using custom edge fallback at {right_edge_x}px ({self.custom_edge_percent*100:.1f}% of frame width)")
                    else:
                        # Case 4: No custom_edge configured, log occlusion warning
                        self.logger.info(f"No right edge detected at {timestamp}s (best conf: {right_conf:.3f}, threshold: {self.right_edge_threshold:.2f}) - possible streamer cam occlusion")
                else:
                    self.logger.debug(f"Right edge detected at {timestamp}s, x={right_edge_x} (conf: {right_conf:.3f})")

            # Remove emblem from frame for better OCR
            processed_frame = frame.copy()

            # Validate right edge position - reject if right edge is to the left of emblem
            if right_edge_x is not None and emblem_right_x is not None:
                if right_edge_x < emblem_right_x:
                    self.logger.info(f"Rejecting detection at {timestamp}s: right edge ({right_edge_x}) is left of emblem right ({emblem_right_x})")
                    return None

            # cropping based on emblem and right edge
            cropped_frame = self._intelligent_crop(processed_frame, emblem_right_x, right_edge_x, truncated)
            
            # Advanced OCR preprocessing
            processed = self._advanced_preprocess_for_ocr(cropped_frame)

            # Extract username via OCR using preprocessed frame (returns username, confidence, and ocr_data)
            username, ocr_confidence, ocr_data = self._extract_usernames(processed)

            # Encode the original frame (already cropped by FFmpeg)
            success, encoded = cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
            frame_jpeg = encoded.tobytes() if success else None

            # Encode the preprocessed frame for debug
            success_debug, encoded_debug = cv2.imencode('.jpg', processed, [cv2.IMWRITE_JPEG_QUALITY, 90])
            debug_jpeg = encoded_debug.tobytes() if success_debug else None

            # Create OCR debug outputs if in test mode
            ocr_viz_jpeg = None
            ocr_log_text = None
            if self.test_mode and ocr_data is not None:
                # Generate OCR visualization with bounding boxes
                ocr_viz_jpeg = self._create_ocr_visualization(processed, ocr_data)

                # Generate OCR log
                ocr_log_text = self._generate_ocr_log(ocr_data, timestamp, username, ocr_confidence)

            # Create bounding box visualization if in test mode and emblem detector is available
            boxes_jpeg = None
            if self.test_mode and self.emblem_detector:
                try:
                    # Create visualization with emblem bounding box on original frame
                    boxes_vis = self.emblem_detector.create_debug_visualization(
                        frame,
                        threshold=self.emblem_threshold
                    )

                    # Add right edge visualization if detected
                    if self.right_edge_detector and right_edge_x is not None:
                        # Calculate actual crop position with margin
                        margin_pixels = int(right_edge_x * self.right_edge_crop_margin)
                        crop_position = right_edge_x - margin_pixels

                        # Draw vertical line at actual crop position (cyan)
                        cv2.line(boxes_vis, (crop_position, 0), (crop_position, boxes_vis.shape[0]),
                                (255, 255, 0), 2)  # Cyan color - shows where crop will happen

                        # Draw right edge bounding box if we can find the match location
                        if self.right_edge_detector.template is not None:
                            # Re-run detection to get match location (cached by template matching)
                            template = self.right_edge_detector.template
                            mask = self.right_edge_detector.mask

                            if mask is not None:
                                result = cv2.matchTemplate(frame, template, cv2.TM_SQDIFF, mask=mask)
                            else:
                                result = cv2.matchTemplate(frame, template, cv2.TM_SQDIFF)
                            _, _, min_loc, _ = cv2.minMaxLoc(result)

                            template_h, template_w = template.shape[:2]
                            template_x = right_edge_x - template_w

                            # Draw bounding box around detected template (cyan)
                            cv2.rectangle(boxes_vis,
                                        (template_x, min_loc[1]),
                                        (right_edge_x, min_loc[1] + template_h),
                                        (255, 255, 0), 2)  # Cyan color

                            # Add text label showing detected position and crop position
                            label = f"Right Edge: {right_edge_x} -> crop at {crop_position}"
                            cv2.putText(boxes_vis, label, (template_x, min_loc[1] - 5),
                                       cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 0), 1)

                    success_boxes, encoded_boxes = cv2.imencode('.jpg', boxes_vis, [cv2.IMWRITE_JPEG_QUALITY, 90])
                    boxes_jpeg = encoded_boxes.tobytes() if success_boxes else None
                    self.logger.debug(f"Created bounding box visualization for timestamp {timestamp}")
                except Exception as e:
                    self.logger.warning(f"Failed to create bounding box visualization: {e}")

            # Prepare result
            result = {
                'vod_id': vod_id,
                'timestamp': timestamp,
                'is_matchup': True,
                'confidence': ocr_confidence,  # OCR confidence (0-1), not emblem confidence
                'username': username,
                'detected_rank': detected_rank,
                'chunk_id': chunk_id,
                'emblem_right_x': emblem_right_x,
                'right_edge_x': right_edge_x,
                'no_right_edge': no_right_edge,
                'truncated': truncated,  # Track if custom edge was used for truncation
                'frame_base64': base64.b64encode(frame_jpeg).decode('utf-8') if frame_jpeg else None,
                'ocr_debug_frame': base64.b64encode(debug_jpeg).decode('utf-8') if debug_jpeg else None
            }

            # Add bounding box frame if created (test mode only)
            if boxes_jpeg:
                result['emblem_boxes_frame'] = base64.b64encode(boxes_jpeg).decode('utf-8')

            # Add OCR debug data if created (test mode only)
            if ocr_viz_jpeg:
                result['ocr_viz_frame'] = base64.b64encode(ocr_viz_jpeg).decode('utf-8')
            if ocr_log_text:
                result['ocr_log_text'] = ocr_log_text

            self.logger.debug(f"Detected matchup at {timestamp}s: {username}")
            return result
            
        except Exception as e:
            self.logger.error(f"Frame processing error: {e}")
            return None
    
    def _decode_frame(self, frame_data: bytes) -> Optional[np.ndarray]:
        """Decode JPEG frame data to numpy array"""
        try:
            # Convert bytes to numpy array
            nparr = np.frombuffer(frame_data, np.uint8)
            frame = cv2.imdecode(nparr, cv2.IMREAD_COLOR)
            return frame
        except Exception as e:
            self.logger.error(f"Failed to decode frame: {e}")
            return None
    
    def _detect_emblem_first(self, frame: np.ndarray) -> Tuple[Optional[str], Optional[Tuple[int, int, int, int]], float]:
        """
        Detect matchup by looking for rank emblems first (5 template scans)

        Args:
            frame: Input frame

        Returns:
            (detected_rank, emblem_bbox, confidence) or (None, None, 0.0) if no emblem found
        """
        if self.emblem_detector is None:
            # Fallback to old template matching if emblem detector not available
            self.logger.warning("Emblem detector not initialized, cannot detect matchups")
            return None, None, 0.0

        try:
            # Try to detect any of the 5 rank emblems
            rank, bbox, confidence = self.emblem_detector.detect_emblem(
                frame,
                threshold=self.emblem_threshold
            )

            if rank is not None:
                self.logger.info(f"Matchup detected via {rank} emblem at {bbox}, confidence={confidence:.3f}")
                return rank, bbox, confidence

            return None, None, 0.0

        except Exception as e:
            self.logger.error(f"Emblem-first detection error: {e}")
            return None, None, 0.0

    def _detect_matchup(self, frame: np.ndarray) -> Tuple[bool, float, Optional[int]]:
        """
        [DEPRECATED] Old detection method using matchup_template.png
        Kept for backward compatibility but not used in new pipeline

        Returns:
            (is_matchup, confidence_score, template_left_x)
        """
        try:
            # Convert to grayscale
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)

            if self.matchup_template is not None:
                return self._template_matching(gray)

        except Exception as e:
            self.logger.error(f"Matchup detection error: {e}")
            return False, 0.0, None
    
    def _template_matching(self, gray: np.ndarray) -> Tuple[bool, float, Optional[int]]:
        """Use template matching for detection and return coordinates"""
        try:
            # Apply template matching
            result = cv2.matchTemplate(gray, self.matchup_template, cv2.TM_CCOEFF_NORMED)
            min_val, max_val, min_loc, max_loc = cv2.minMaxLoc(result)
            
            # Check if match exceeds threshold
            is_match = max_val >= self.threshold
            
            # Return left x coordinate of matched template
            template_left_x = max_loc[0] if is_match else None
            
            if is_match:
                self.logger.debug(f"Template match found at x={template_left_x}, confidence={max_val:.3f}")
            
            return is_match, max_val, template_left_x
            
        except Exception as e:
            self.logger.error(f"Template matching error: {e}")
            return False, 0.0, None
    
    def _detect_and_remove_emblem(self, frame: np.ndarray) -> Tuple[np.ndarray, Optional[int], Optional[str]]:
        """
        Detect emblem and remove it, returning the right boundary x coordinate

        Args:
            frame: Input frame

        Returns:
            (processed_frame, emblem_right_x, detected_rank)
        """
        try:
            # Remove emblem with white fill (255)
            processed_frame, detected_rank = self.emblem_detector.remove_emblem(
                frame,
                threshold=self.emblem_threshold,
                fill_value=255  # White fill
            )

            # Get emblem coordinates for right boundary calculation
            emblem_right_x = None
            if detected_rank:
                # Re-detect to get coordinates (emblem_detector.remove_emblem doesn't return coordinates)
                rank, bbox, confidence = self.emblem_detector.detect_emblem(frame, self.emblem_threshold)
                if bbox:
                    x, y, w, h = bbox
                    # Calculate right boundary using exact bbox
                    emblem_right_x = min(frame.shape[1], x + w)
                    self.logger.debug(f"Detected {rank} emblem, right boundary at x={emblem_right_x}")

            return processed_frame, emblem_right_x, detected_rank

        except Exception as e:
            self.logger.error(f"Emblem detection/removal error: {e}")
            return frame, None, None
    
    def _intelligent_crop(self, frame: np.ndarray, emblem_right_x: Optional[int], right_edge_x: Optional[int], truncated: bool = False) -> np.ndarray:
        """
        Crop frame intelligently based on emblem and right edge coordinates

        Args:
            frame: Input frame
            emblem_right_x: Right boundary from emblem detection (after expansion)
            right_edge_x: Right boundary from right edge detection
            truncated: Whether custom_edge fallback was used

        Returns:
            Cropped frame
        """
        try:
            h, w = frame.shape[:2]

            # Crop top and bottom proportionally (24% of height works well across resolutions)
            # For 480p (54px): ~13px, for 1080p (121px): ~29px
            crop_ratio = 0.24
            top_crop = int(h * crop_ratio)
            bottom_crop = int(h * crop_ratio)
            y1 = max(0, top_crop)
            y2 = min(h, h - bottom_crop)

            # Determine horizontal cropping
            if emblem_right_x is not None and right_edge_x is not None:
                # Both boundaries detected - ideal case
                # Username is between emblem and right edge
                left_bound = emblem_right_x

                # Apply crop margin to right edge to avoid edge artifacts
                # E.g., if right_edge_x=100 and margin=10%, crop at 90
                margin_pixels = int(right_edge_x * self.right_edge_crop_margin)

                # When custom_edge is configured, trust tight crops without enforcing minimum width
                # This applies whether we used custom_edge fallback or actual detection succeeded
                if self.custom_edge_percent is not None:
                    right_bound = right_edge_x - margin_pixels
                else:
                    right_bound = max(emblem_right_x + 20, right_edge_x - margin_pixels)  # Ensure at least 20px width

                # Validate coordinates are reasonable
                # For streamers with custom_edge configured, skip minimum width validation
                min_width = 0 if self.custom_edge_percent is not None else 20
                if left_bound >= 0 and right_bound <= w and right_bound > left_bound + min_width:
                    x1 = max(0, left_bound)
                    x2 = min(w, right_bound)
                    crop_source = "custom_edge" if truncated else "detected"
                    self.logger.debug(f"Ideal crop with both boundaries ({crop_source}): x={x1}-{x2}, y={y1}-{y2} (right_edge={right_edge_x}, margin={margin_pixels}px)")
                else:
                    self.logger.warning(f"Invalid boundaries: emblem_right={emblem_right_x}, right_edge={right_edge_x}, adjusted_right={right_bound}, truncated={truncated}")
                    x1 = 0
                    x2 = w
            elif emblem_right_x is not None and right_edge_x is None:
                # Only emblem detected - partial occlusion case
                # Estimate username area: typically ~200-250px wide at 480p
                # Scale based on frame width
                estimated_width = int(w * 0.25)  # ~25% of frame width for username area
                x1 = max(0, emblem_right_x)
                x2 = min(w, emblem_right_x + estimated_width)
                self.logger.debug(f"Partial occlusion crop (no right edge): x={x1}-{x2}, y={y1}-{y2}")
            elif emblem_right_x is None and right_edge_x is not None:
                # No emblem detected but have right edge (from detection or custom_edge fallback)
                # Crop from start of frame to right_edge with margin
                margin_pixels = int(right_edge_x * self.right_edge_crop_margin)
                x1 = 0
                # When custom_edge is configured, don't enforce minimum width
                if self.custom_edge_percent is not None:
                    x2 = right_edge_x - margin_pixels
                else:
                    x2 = max(20, right_edge_x - margin_pixels)
                crop_source = "custom_edge" if truncated else "detected"
                self.logger.debug(f"No emblem crop with right edge ({crop_source}): x={x1}-{x2}, y={y1}-{y2}")
            else:
                # Fallback: use right portion of frame
                x1 = 0
                x2 = max(w - 20, w // 2)
                self.logger.debug(f"Fallback crop: x={x1}-{x2}, y={y1}-{y2}")

            # Final validation: ensure minimum crop size
            min_width = 50
            min_height = 20

            if y2 - y1 < min_height or x2 - x1 < min_width:
                self.logger.warning(f"Crop too small ({x2-x1}x{y2-y1}), returning original frame")
                return frame

            cropped = frame[y1:y2, x1:x2]
            return cropped

        except Exception as e:
            self.logger.error(f"Intelligent crop v2 error: {e}")
            return frame

    def _multi_crop_ocr(self, frame: np.ndarray, emblem_right_x: Optional[int], timestamp: int, num_samples: int = 15) -> Optional[int]:
        """
        Multi-crop OCR approach: Try multiple crop positions and find the best one

        Args:
            frame: Input frame
            emblem_right_x: Left boundary (where emblem ends)
            timestamp: Frame timestamp for logging
            num_samples: Number of crop positions to test

        Returns:
            Optimal crop position (right edge x), or None if all attempts failed
        """
        try:
            if emblem_right_x is None or self.custom_edge_percent is None:
                return None

            h, w = frame.shape[:2]
            custom_edge_x = int(w * self.custom_edge_percent)

            # Vertical crop parameters (same as _intelligent_crop)
            crop_ratio = 0.24
            top_crop = int(h * crop_ratio)
            bottom_crop = int(h * crop_ratio)
            y1 = max(0, top_crop)
            y2 = min(h, h - bottom_crop)

            # Generate sample positions (quadratic spacing for more samples near custom_edge)
            positions = []
            for i in range(num_samples):
                t = (i / (num_samples - 1)) ** 1.5  # Quadratic spacing
                x = int(custom_edge_x + t * (w - custom_edge_x))
                positions.append(x)

            self.logger.debug(f"Multi-crop testing {num_samples} positions from {custom_edge_x} to {w}")

            results = []

            for right_x in positions:
                # Horizontal crop
                x1 = emblem_right_x
                x2 = min(w, right_x)

                if x2 <= x1:
                    continue

                # Crop frame
                cropped = frame[y1:y2, x1:x2]

                # Preprocess for OCR
                preprocessed = self._advanced_preprocess_for_ocr(cropped)

                # Run OCR
                username, conf, ocr_data = self._extract_usernames(preprocessed)

                if username:
                    results.append({
                        'right_x': right_x,
                        'width': x2 - x1,
                        'text': username,
                        'confidence': conf
                    })

            if not results:
                self.logger.debug(f"Multi-crop: No valid OCR results")
                return None

            # Selection strategy: Among high-confidence results (>= 0.85), pick highest confidence
            # If tied, prefer longest text (most complete username)
            high_conf_threshold = 0.85
            high_conf_results = [r for r in results if r['confidence'] >= high_conf_threshold]

            if not high_conf_results:
                # No high-confidence results, use highest confidence overall
                best = max(results, key=lambda x: x['confidence'])
                self.logger.debug(f"Multi-crop: No high-confidence results, using best overall (conf={best['confidence']:.3f})")
            else:
                # Find maximum confidence among high-confidence results
                max_conf = max(r['confidence'] for r in high_conf_results)

                # Get all with max confidence
                max_conf_results = [r for r in high_conf_results if r['confidence'] == max_conf]

                # If multiple tied, prefer longest text
                best = max(max_conf_results, key=lambda x: len(x['text']))

                self.logger.debug(f"Multi-crop: Selected from {len(high_conf_results)} high-conf results (max_conf={max_conf:.3f})")

            self.logger.info(f"Multi-crop result: '{best['text']}' at crop={best['right_x']}px (conf={best['confidence']:.3f}, width={best['width']}px)")

            return best['right_x']

        except Exception as e:
            self.logger.error(f"Multi-crop OCR error: {e}")
            return None

    def _advanced_preprocess_for_ocr(self, frame: np.ndarray) -> np.ndarray:
        """Advanced OCR preprocessing based on tuned parameters"""
        try:
            if frame is None or frame.size == 0:
                self.logger.error("Empty frame provided to preprocessing")
                return frame
                
            # Convert to grayscale if needed
            if len(frame.shape) == 3:
                gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            else:
                gray = frame.copy()
            
            # Scale factor from preset (3.0x)
            scale_factor = self.ocr_preprocessing.get('scale_factor', 3.0)
            scale_factor = max(1.0, min(10.0, scale_factor))  # Clamp to reasonable range
            if scale_factor > 1.0:
                gray = cv2.resize(gray, None, fx=scale_factor, fy=scale_factor, 
                                 interpolation=cv2.INTER_CUBIC)
            
            # Gaussian blur for noise reduction (2px from preset)
            gaussian_blur = self.ocr_preprocessing.get('gaussian_blur', 2)
            gaussian_blur = max(0, min(15, gaussian_blur))  # Clamp to reasonable range
            if gaussian_blur > 0:
                # Ensure odd kernel size
                kernel_size = gaussian_blur if gaussian_blur % 2 == 1 else gaussian_blur + 1
                kernel_size = max(3, kernel_size)  # Minimum kernel size
                gray = cv2.GaussianBlur(gray, (kernel_size, kernel_size), 0)
            
            # CLAHE contrast enhancement
            if self.ocr_preprocessing.get('clahe_enabled', True):
                clahe_clip = self.ocr_preprocessing.get('clahe_clip', 1.4)
                clahe_grid = self.ocr_preprocessing.get('clahe_grid', 11)
                clahe_clip = max(1.0, min(10.0, clahe_clip))  # Reasonable range
                clahe_grid = max(2, min(20, clahe_grid))  # Reasonable range
                clahe = cv2.createCLAHE(clipLimit=clahe_clip, tileGridSize=(clahe_grid, clahe_grid))
                gray = clahe.apply(gray)
            
            # Binary thresholding
            binary_threshold = self.ocr_preprocessing.get('binary_threshold', 154)
            binary_threshold = max(0, min(255, binary_threshold))  # Valid range
            _, binary = cv2.threshold(gray, binary_threshold, 255, cv2.THRESH_BINARY)
            
            # Invert if specified (from preset)
            if self.ocr_preprocessing.get('invert', True):
                binary = 255 - binary
            
            # Final check for valid output
            if binary is None or binary.size == 0:
                self.logger.error("Preprocessing produced empty result")
                return frame
                
            return binary
            
        except Exception as e:
            self.logger.error(f"Advanced OCR preprocessing error: {e}")
            # Fallback to basic preprocessing
            return self._preprocess_for_ocr(frame)
    
    def _extract_usernames(self, frame: np.ndarray) -> Tuple[Optional[str], float, Optional[dict]]:
        """
        Extract username from preprocessed nameplate frame using OCR

        Args:
            frame: Already preprocessed frame (grayscale, scaled, binary, denoised)

        Returns:
            Tuple of (username, confidence, ocr_data) where confidence is 0-1 scale
            ocr_data is the full Tesseract output dict for debugging
        """
        try:
            # Run OCR with detailed output to get confidence scores
            data = pytesseract.image_to_data(
                frame,
                lang=self.tesseract_lang,
                config=self.tesseract_config,
                output_type=pytesseract.Output.DICT
            )

            # Extract text and confidence from OCR results
            # Filter out entries with no confidence (-1) and empty strings
            valid_words = []
            confidences = []

            for i, conf in enumerate(data['conf']):
                text = data['text'][i].strip()
                if conf != -1 and text:  # -1 means no confidence available
                    valid_words.append(text)
                    confidences.append(float(conf))

            if not valid_words:
                return None, 0.0, data

            # Join words into full text
            text = ' '.join(valid_words)

            # Calculate average confidence (normalized to 0-1 range)
            avg_confidence = np.mean(confidences) / 100.0 if confidences else 0.0

            # Log low confidence OCR results for debugging
            if avg_confidence < 0.5:
                self.logger.warning(f"Low OCR confidence: text='{text}', confidences={confidences}, avg={avg_confidence:.3f}")

            # Clean up text
            cleaned = self._clean_username(text)

            return cleaned, avg_confidence, data

        except Exception as e:
            self.logger.error(f"Username extraction error: {e}")

        return None, 0.0, None

    def _create_ocr_visualization(self, preprocessed_frame: np.ndarray, ocr_data: dict) -> Optional[bytes]:
        """
        Create visualization showing Tesseract bounding boxes on preprocessed frame

        Args:
            preprocessed_frame: The preprocessed binary image that was fed to Tesseract
            ocr_data: Full Tesseract output dict from image_to_data()

        Returns:
            JPEG bytes of visualization, or None on error
        """
        try:
            # Convert grayscale to color for visualization
            if len(preprocessed_frame.shape) == 2:
                vis = cv2.cvtColor(preprocessed_frame, cv2.COLOR_GRAY2BGR)
            else:
                vis = preprocessed_frame.copy()

            # Draw bounding boxes for each detected text element
            n_boxes = len(ocr_data['text'])
            for i in range(n_boxes):
                text = ocr_data['text'][i].strip()
                conf = ocr_data['conf'][i]

                # Skip empty text or invalid confidence
                if not text or conf == -1:
                    continue

                # Get bounding box coordinates
                x = ocr_data['left'][i]
                y = ocr_data['top'][i]
                w = ocr_data['width'][i]
                h = ocr_data['height'][i]

                # Color-code by confidence: green (>70%), yellow (30-70%), red (<30%)
                if conf > 70:
                    color = (0, 255, 0)  # Green
                elif conf > 30:
                    color = (0, 255, 255)  # Yellow (BGR)
                else:
                    color = (0, 0, 255)  # Red

                # Draw bounding box
                cv2.rectangle(vis, (x, y), (x + w, y + h), color, 2)

                # Add text label with confidence
                label = f"{text} ({conf:.0f}%)"
                cv2.putText(vis, label, (x, y - 5),
                           cv2.FONT_HERSHEY_SIMPLEX, 0.5, color, 1)

            # Encode as JPEG
            success, encoded = cv2.imencode('.jpg', vis, [cv2.IMWRITE_JPEG_QUALITY, 90])
            if success:
                return encoded.tobytes()
            return None

        except Exception as e:
            self.logger.error(f"OCR visualization error: {e}")
            return None

    def _generate_ocr_log(self, ocr_data: dict, timestamp: int, username: Optional[str], confidence: float) -> str:
        """
        Generate human-readable OCR debug log

        Args:
            ocr_data: Full Tesseract output dict
            timestamp: Frame timestamp
            username: Detected/cleaned username
            confidence: Average OCR confidence (0-1)

        Returns:
            Plain text log as string
        """
        try:
            lines = []
            lines.append("=" * 60)
            lines.append("OCR Debug Log")
            lines.append("=" * 60)
            lines.append(f"Timestamp: {timestamp}s")
            lines.append(f"Detected Username: {username if username else '(none)'}")
            lines.append(f"Average Confidence: {confidence:.3f}")
            lines.append("")

            # Extract detected words
            lines.append("Detected Text Elements:")
            lines.append("-" * 60)
            lines.append(f"{'Text':<20} {'Conf':<8} {'BBox (x,y,w,h)':<30}")
            lines.append("-" * 60)

            n_boxes = len(ocr_data['text'])
            for i in range(n_boxes):
                text = ocr_data['text'][i].strip()
                conf = ocr_data['conf'][i]

                # Skip empty text or invalid confidence
                if not text or conf == -1:
                    continue

                x = ocr_data['left'][i]
                y = ocr_data['top'][i]
                w = ocr_data['width'][i]
                h = ocr_data['height'][i]

                lines.append(f"{text:<20} {conf:<8.1f} ({x},{y},{w},{h})")

            lines.append("")
            lines.append("Tesseract Configuration:")
            lines.append("-" * 60)
            lines.append(f"Config: {self.tesseract_config}")
            lines.append(f"Language: {self.tesseract_lang}")
            lines.append("")

            return "\n".join(lines)

        except Exception as e:
            self.logger.error(f"OCR log generation error: {e}")
            return f"Error generating OCR log: {e}"

    def _preprocess_for_ocr(self, roi: np.ndarray) -> np.ndarray:
        """Preprocess image region for better OCR accuracy"""
        try:
            # Convert to grayscale if needed
            if len(roi.shape) == 3:
                gray = cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY)
            else:
                gray = roi
            
            # Resize for better OCR (Tesseract works better with larger text)
            scaled = cv2.resize(gray, None, fx=2, fy=2, interpolation=cv2.INTER_CUBIC)
            
            # Apply thresholding to get binary image
            _, binary = cv2.threshold(scaled, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
            
            # Denoise
            denoised = cv2.medianBlur(binary, 3)
            
            return denoised
            
        except Exception as e:
            self.logger.error(f"OCR preprocessing error: {e}")
            return roi
    
    def _clean_username(self, text: str) -> Optional[str]:
        """Clean and validate extracted username"""
        if not text:
            return None

        # Remove non-alphanumeric characters except underscore, dash, and dot
        # These are allowed in usernames and whitelisted in Tesseract config
        import re
        cleaned = re.sub(r'[^a-zA-Z0-9_\-.]', '', text)

        return cleaned

        return None
    
