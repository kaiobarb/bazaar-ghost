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
# Use async logger for non-blocking performance
try:
    from async_logger import FireAndForgetLogger as SupabaseLogger
except ImportError:
    from custom_logger import SupabaseLogger

class FrameProcessor:
    """Process frames for matchup detection and OCR"""
    
    def __init__(self, config: Dict[str, Any], quality: str = "480p", test_mode: bool = False):
        """Initialize frame processor with configuration

        Args:
            config: Configuration dictionary
            quality: Video quality being processed (360p, 480p, 720p, 1080p)
            test_mode: Whether running in test mode
        """
        self.config = config
        self.quality = quality
        self.test_mode = test_mode
        self.logger = logging.getLogger('sfot.frame_processor')

        # Initialize Supabase logger for centralized logging
        self.supabase_logger = SupabaseLogger(source_name="sfot_logs")

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
                templates_dir = config['emblem_detection'].get('templates_dir', 'templates/')
                self.emblem_detector = EmblemDetector(templates_dir, resolution=template_resolution)
                self.emblem_threshold = config['emblem_detection'].get('threshold', 0.25)
                self.emblem_expand = config['emblem_detection'].get('expand_pixels', 10)
                self.logger.info(f"Initialized emblem detector with {template_resolution} templates")
            except Exception as e:
                self.logger.warning(f"Could not initialize emblem detector: {e}")

        # Initialize right edge detector
        self.right_edge_detector = None
        if config.get('right_edge_detection', {}).get('enabled', True):
            try:
                templates_dir = config.get('right_edge_detection', {}).get('templates_dir',
                                          config.get('emblem_detection', {}).get('templates_dir', 'templates/'))
                self.right_edge_detector = RightEdgeDetector(templates_dir, resolution=template_resolution)
                self.right_edge_threshold = config.get('right_edge_detection', {}).get('threshold', 0.7)
                self.logger.info(f"Initialized right edge detector with {template_resolution} template")
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

            # Validate emblem bounding box position and size
            if emblem_bbox:
                x, y, w, h = emblem_bbox
                frame_h, frame_w = frame.shape[:2]

                # Check 1: Emblem top must be within 5% of frame height from top
                max_top_offset = frame_h * 0.05
                if y > max_top_offset:
                    self.logger.info(f"Rejecting detection at {timestamp}s: emblem too far from top (y={y:.1f}, max={max_top_offset:.1f})")
                    return None

                # Check 2: Emblem height must be at least 90% of frame height
                min_height = frame_h * 0.90
                if h < min_height:
                    self.logger.info(f"Rejecting detection at {timestamp}s: emblem too short (h={h:.1f}, min={min_height:.1f})")
                    return None

            # Check minimum interval
            if timestamp - self.last_matchup_time < self.min_matchup_interval:
                return None

            self.last_matchup_time = timestamp

            # PHASE 2: Right edge detection (only if emblem was found)
            right_edge_x = None
            no_right_edge = False

            if self.right_edge_detector:
                right_edge_x, right_conf = self.right_edge_detector.detect_right_edge(frame, self.right_edge_threshold)
                if right_edge_x is None:
                    no_right_edge = True
                    self.logger.info(f"No right edge detected at {timestamp}s (best conf: {right_conf:.3f}, threshold: {self.right_edge_threshold:.2f}) - possible streamer cam occlusion")
                else:
                    self.logger.debug(f"Right edge detected at {timestamp}s, x={right_edge_x} (conf: {right_conf:.3f})")

            # Remove emblem from frame for better OCR
            processed_frame = frame.copy()
            if self.emblem_detector and emblem_bbox:
                processed_frame, _ = self.emblem_detector.remove_emblem(
                    frame,
                    threshold=self.emblem_threshold,
                    expand_pixels=0,  # Use exact bounding box without expansion
                    fill_value=255
                )

            # Calculate emblem right boundary for cropping
            emblem_right_x = None
            if emblem_bbox:
                x, y, w, h = emblem_bbox
                emblem_right_x = min(frame.shape[1], x + w)  # Use exact bbox width

            # PHASE 3: Intelligent cropping based on emblem and right edge
            cropped_frame = self._intelligent_crop_v2(processed_frame, emblem_right_x, right_edge_x)
            
            # Advanced OCR preprocessing
            processed = self._advanced_preprocess_for_ocr(cropped_frame)
            
            # Extract username via OCR using preprocessed frame
            username = self._extract_usernames(processed)
            
            # Encode the original frame (already cropped by FFmpeg)
            success, encoded = cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
            frame_jpeg = encoded.tobytes() if success else None
            
            # Encode the preprocessed frame for debug
            success_debug, encoded_debug = cv2.imencode('.jpg', processed, [cv2.IMWRITE_JPEG_QUALITY, 90])
            debug_jpeg = encoded_debug.tobytes() if success_debug else None

            # Create bounding box visualization if in test mode and emblem detector is available
            boxes_jpeg = None
            if self.test_mode and self.emblem_detector:
                try:
                    # Create visualization with bounding boxes on original frame
                    boxes_vis = self.emblem_detector.create_debug_visualization(
                        frame,
                        threshold=self.emblem_threshold,
                        expand_pixels=self.emblem_expand
                    )
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
                'confidence': emblem_confidence,
                'username': username,
                'detected_rank': detected_rank,
                'chunk_id': chunk_id,
                'emblem_right_x': emblem_right_x,
                'right_edge_x': right_edge_x,
                'no_right_edge': no_right_edge,
                'frame_base64': base64.b64encode(frame_jpeg).decode('utf-8') if frame_jpeg else None,
                'ocr_debug_frame': base64.b64encode(debug_jpeg).decode('utf-8') if debug_jpeg else None
            }

            # Add bounding box frame if created (test mode only)
            if boxes_jpeg:
                result['emblem_boxes_frame'] = base64.b64encode(boxes_jpeg).decode('utf-8')
            
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
                # Log to Supabase
                self.supabase_logger.info("Matchup detected",
                                          rank=rank,
                                          confidence=confidence,
                                          quality=self.quality)
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
                expand_pixels=self.emblem_expand, 
                fill_value=255  # White fill
            )
            
            # Get emblem coordinates for right boundary calculation
            emblem_right_x = None
            if detected_rank:
                # Re-detect to get coordinates (emblem_detector.remove_emblem doesn't return coordinates)
                rank, bbox, confidence = self.emblem_detector.detect_emblem(frame, self.emblem_threshold)
                if bbox:
                    x, y, w, h = bbox
                    # Calculate right boundary after expansion
                    emblem_right_x = min(frame.shape[1], x + w + self.emblem_expand)
                    self.logger.debug(f"Detected {rank} emblem, right boundary at x={emblem_right_x}")
            
            return processed_frame, emblem_right_x, detected_rank
            
        except Exception as e:
            self.logger.error(f"Emblem detection/removal error: {e}")
            return frame, None, None
    
    def _intelligent_crop_v2(self, frame: np.ndarray, emblem_right_x: Optional[int], right_edge_x: Optional[int]) -> np.ndarray:
        """
        Crop frame intelligently based on emblem and right edge coordinates

        Args:
            frame: Input frame
            emblem_right_x: Right boundary from emblem detection (after expansion)
            right_edge_x: Right boundary from right edge detection

        Returns:
            Cropped frame
        """
        try:
            h, w = frame.shape[:2]

            # Crop top and bottom proportionally (22% of height works well across resolutions)
            # For 480p (54px): ~12px, for 1080p (121px): ~27px
            crop_ratio = 0.22
            top_crop = int(h * crop_ratio)
            bottom_crop = int(h * crop_ratio)
            y1 = max(0, top_crop)
            y2 = min(h, h - bottom_crop)

            # Determine horizontal cropping
            if emblem_right_x is not None and right_edge_x is not None:
                # Both boundaries detected - ideal case
                # Username is between emblem and right edge
                left_bound = emblem_right_x
                right_bound = right_edge_x

                # Validate coordinates are reasonable
                if left_bound >= 0 and right_bound <= w and right_bound > left_bound + 20:
                    x1 = max(0, left_bound)
                    x2 = min(w, right_bound)
                    self.logger.debug(f"Ideal crop with both boundaries: x={x1}-{x2}, y={y1}-{y2}")
                else:
                    self.logger.warning(f"Invalid boundaries: emblem_right={emblem_right_x}, right_edge={right_edge_x}")
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

    def _intelligent_crop(self, frame: np.ndarray, template_left_x: Optional[int], emblem_right_x: Optional[int]) -> np.ndarray:
        """
        Crop frame intelligently based on template and emblem coordinates
        
        Args:
            frame: Input frame
            template_left_x: Left boundary from template matching
            emblem_right_x: Right boundary from emblem detection (after expansion)
            
        Returns:
            Cropped frame
        """
        try:
            h, w = frame.shape[:2]
            
            # Crop top and bottom by 12px as per preset
            top_crop = 12
            bottom_crop = 12
            y1 = max(0, top_crop)
            y2 = min(h, h - bottom_crop)
            
            # Determine horizontal cropping
            if template_left_x is not None and emblem_right_x is not None:
                # Handle coordinate order (emblem might be left of template match)
                left_bound = min(template_left_x, emblem_right_x) 
                right_bound = max(template_left_x, emblem_right_x)
                
                # Validate coordinates are reasonable
                if left_bound >= 0 and right_bound <= w and right_bound > left_bound + 20:  # Min 20px width
                    x1 = max(0, left_bound)
                    x2 = min(w, right_bound)
                    self.logger.debug(f"Intelligent crop using coordinates: x={x1}-{x2}, y={y1}-{y2}")
                else:
                    self.logger.warning(f"Coordinates too close: template_left={template_left_x}, emblem_right={emblem_right_x}, falling back")
                    x1 = 0
                    x2 = max(w - 20, w // 2)
            else:
                # Fallback: use full width but apply right crop from preset (20px)
                x1 = 0
                x2 = max(w - 20, w // 2)  # Ensure we don't crop too much
                self.logger.debug(f"Fallback crop (missing coordinates): x={x1}-{x2}, y={y1}-{y2}")
            
            # Final validation: ensure minimum crop size
            min_width = 50  # Minimum width for meaningful OCR
            min_height = 20  # Minimum height for meaningful OCR
            
            if y2 - y1 < min_height or x2 - x1 < min_width:
                self.logger.warning(f"Crop too small ({x2-x1}x{y2-y1}), returning original frame")
                return frame
                
            cropped = frame[y1:y2, x1:x2]
            return cropped
            
        except Exception as e:
            self.logger.error(f"Intelligent crop error: {e}")
            return frame
    
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
    
    def _extract_usernames(self, frame: np.ndarray) -> Optional[str]:
        """
        Extract username from preprocessed nameplate frame using OCR
        
        Args:
            frame: Already preprocessed frame (grayscale, scaled, binary, denoised)
        
        Returns:
            Extracted username or None
        """
        try:
            # Run OCR on preprocessed frame
            text = pytesseract.image_to_string(
                frame,
                lang=self.tesseract_lang,
                config=self.tesseract_config
            ).strip()
            
            # Clean up text
            cleaned = self._clean_username(text)
            return cleaned
                    
        except Exception as e:
            self.logger.error(f"Username extraction error: {e}")
        
        return None
    
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
        
        # Remove non-alphanumeric characters except underscore
        import re
        cleaned = re.sub(r'[^a-zA-Z0-9_]', '', text)
        
        # Validate length (Twitch usernames are 4-25 characters)
        if 4 <= len(cleaned) <= 25:
            return cleaned
        
        return None
    
