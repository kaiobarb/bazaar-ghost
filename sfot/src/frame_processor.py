"""
Frame processor module - Handles OpenCV detection and easyOCR
"""

import cv2
import numpy as np
import easyocr
from typing import Optional, Dict, Any, Tuple
import logging
import base64
from PIL import Image
import io
from emblem_detector import EmblemDetector
from right_edge_detector import RightEdgeDetector
from telemetry import create_span, record_histogram
class FrameProcessor:
    """Process frames for matchup detection and OCR"""
    
    def __init__(self, config: Dict[str, Any], quality: str = "480p", old_templates: bool = False, method: str = 'template', profile: Optional[Dict[str, Any]] = None):
        """Initialize frame processor with configuration

        Args:
            config: Configuration dictionary
            quality: Video quality being processed (360p, 480p, 720p, 1080p)
            old_templates: Whether to use underscore-prefixed templates for older VODs
            profile: SFOT profile containing custom_edge and opaque_edge settings
        """
        self.config = config
        self.quality = quality
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

        # Initialize easyOCR reader
        easyocr_config = config.get('easyocr', {})
        model_storage = easyocr_config.get('model_storage_directory', './models')

        try:
            self.reader = easyocr.Reader(
                ['en'],
                gpu=False,
                model_storage_directory=model_storage,
                download_enabled=False,
                verbose=False
            )
            # Set allowlist for valid username characters
            self.reader.allowlist = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-'
            self.logger.info(f"Initialized easyOCR reader (CPU mode) with character allowlist")
        except Exception as e:
            self.logger.error(f"Failed to initialize easyOCR reader: {e}")
            raise

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

            # Emblem detection first (5 template scans)
            detected_rank, emblem_bbox, emblem_confidence = self._detect_emblem(frame)

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
                # Case 2: Try right edge detection
                right_edge_x, right_conf = self.right_edge_detector.detect_right_edge(
                    frame, self.right_edge_threshold
                )

                if right_edge_x is None:
                    # No right edge detected
                    no_right_edge = True

                    # Case 3: Fall back to custom_edge if configured
                    if self.custom_edge_percent is not None:
                        right_edge_x = int(frame.shape[1] * self.custom_edge_percent)
                        truncated = True
                        self.logger.info(
                            f"No right edge detected, using custom_edge at {right_edge_x}px"
                        )
                    else:
                        # No custom_edge configured
                        self.logger.info(
                            f"No right edge detected (conf: {right_conf:.3f}) - "
                            f"possible streamer cam occlusion"
                        )
                else:
                    self.logger.debug(f"Right edge detected at {timestamp}s, x={right_edge_x} (conf: {right_conf:.3f})")
                    # Record right edge confidence metric
                    record_histogram("right_edge_confidence", right_conf, {})

            # Remove emblem from frame for better OCR
            processed_frame = frame.copy()

            # Simple top/bottom cropping and emblem removal
            cropped_frame = self._crop(processed_frame, emblem_bbox)

            # Preprocess frame for OCR
            preprocessed_frame = self._preprocess_for_easyocr(cropped_frame)

            # Extract username via OCR using preprocessed frame (returns username, confidence, and ocr_data)
            username, ocr_confidence, ocr_data = self._extract_usernames(preprocessed_frame)

            # Encode the original frame (already cropped by FFmpeg)
            success, encoded = cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
            frame_jpeg = encoded.tobytes() if success else None

            # Create OCR debug visualization (always on matchup frames)
            debug_jpeg = None
            if ocr_data is not None:
                # Generate OCR visualization with bounding boxes on preprocessed frame
                debug_jpeg = self._create_ocr_visualization(preprocessed_frame, ocr_data)

            # Create emblem bounding box visualization if emblem detector is available
            boxes_jpeg = None
            if self.emblem_detector:
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
                'confidence': ocr_confidence,
                'username': username,
                'detected_rank': detected_rank,
                'chunk_id': chunk_id,
                'emblem_right_x': emblem_right_x,
                'right_edge_x': right_edge_x,
                'no_right_edge': no_right_edge,
                'truncated': truncated,
                'frame_base64': base64.b64encode(frame_jpeg).decode('utf-8') if frame_jpeg else None,
                'ocr_debug_frame': base64.b64encode(debug_jpeg).decode('utf-8') if debug_jpeg else None
            }

            # Add bounding box frame if created
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
    
    def _detect_emblem(self, frame: np.ndarray) -> Tuple[Optional[str], Optional[Tuple[int, int, int, int]], float]:
        """
        Detect matchup by looking for rank emblems first (5 template scans)

        Args:
            frame: Input frame

        Returns:
            (detected_rank, emblem_bbox, confidence) or (None, None, 0.0) if no emblem found
        """
        if self.emblem_detector is None:
            self.logger.warning("Emblem detector not initialized, cannot detect matchups")
            return None, None, 0.0

        with create_span("emblem_detection") as span:
            try:
                # Try to detect any of the 5 rank emblems
                rank, bbox, confidence = self.emblem_detector.detect_emblem(
                    frame,
                    threshold=self.emblem_threshold
                )

                if rank is not None:
                    self.logger.info(f"Matchup detected via {rank} emblem at {bbox}, confidence={confidence:.3f}")
                    if span:
                        span.set_attribute("emblem.rank", rank)
                        span.set_attribute("emblem.confidence", confidence)
                        span.set_attribute("emblem.detected", True)
                    # Record emblem confidence histogram
                    record_histogram("emblem_confidence", confidence, {"rank": rank})
                    return rank, bbox, confidence

                if span:
                    span.set_attribute("emblem.detected", False)
                return None, None, 0.0

            except Exception as e:
                self.logger.error(f"Emblem detection error: {e}")
                return None, None, 0.0
    
    def _crop(self, frame: np.ndarray, emblem_bbox: Optional[Tuple[int, int, int, int]] = None) -> np.ndarray:
        """
        Crop frame to remove top/bottom borders and optionally the emblem

        Args:
            frame: Input frame
            emblem_bbox: Optional emblem bounding box (x, y, w, h) to crop out

        Returns:
            Cropped frame (top/bottom removed, emblem removed if bbox provided)
        """
        try:
            h, w = frame.shape[:2]

            # Vertical crop: remove top/bottom 24%
            crop_ratio = 0.24
            top_crop = int(h * crop_ratio)
            bottom_crop = int(h * crop_ratio)

            y1 = max(0, top_crop)
            y2 = min(h, h - bottom_crop)

            # Horizontal crop: remove emblem from left side if bbox provided
            x1 = 0
            if emblem_bbox is not None:
                emblem_x, emblem_y, emblem_w, emblem_h = emblem_bbox
                # Crop from the right edge of the emblem
                x1 = max(0, emblem_x + emblem_w)

            cropped = frame[y1:y2, x1:]

            # Validate minimum dimensions
            if cropped.shape[0] < 20 or cropped.shape[1] < 50:
                self.logger.warning(
                    f"Crop too small: {cropped.shape}, using original"
                )
                return frame

            return cropped

        except Exception as e:
            self.logger.error(f"Simple crop error: {e}")
            return frame


    def _preprocess_for_easyocr(self, frame: np.ndarray) -> np.ndarray:
        """
        Preprocessing for easyOCR using scaling, CLAHE, blur, binary threshold, and inversion

        Args:
            frame: Input frame (BGR or grayscale)

        Returns:
            Preprocessed frame
        """
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
            self.logger.error(f"OCR preprocessing error: {e}")
            return frame
    
    def _extract_usernames(self, frame: np.ndarray) -> Tuple[Optional[str], float, Optional[dict]]:
        """
        Extract username from preprocessed nameplate frame using easyOCR

        Args:
            frame: Preprocessed frame (grayscale, optionally upscaled)

        Returns:
            Tuple of (username, confidence, ocr_data) where confidence is 0-1 scale
            ocr_data contains detection details for debugging
        """
        with create_span("ocr_extraction") as span:
            try:
                # Run easyOCR detection
                results = self.reader.readtext(frame)

                # results format: List[Tuple[bbox, text, confidence]]
                # bbox: [[x1,y1], [x2,y2], [x3,y3], [x4,y4]]
                # text: detected string
                # confidence: 0-1 float

                if not results:
                    if span:
                        span.set_attribute("ocr.text", "")
                        span.set_attribute("ocr.confidence", 0.0)
                        span.set_attribute("ocr.detection_count", 0)
                    return None, 0.0, {"detections": []}

                # Strategy: Take detection with highest confidence
                # (easyOCR typically returns one result per text region)
                best_detection = max(results, key=lambda x: x[2])
                bbox, text, confidence = best_detection

                # Clean up text
                cleaned = self._clean_username(text)

                # Build debug data structure
                ocr_data = {
                    "detections": [
                        {
                            "bbox": bbox,
                            "text": text,
                            "confidence": conf
                        }
                        for bbox, text, conf in results
                    ]
                }

                # Log low confidence
                if confidence < 0.5:
                    self.logger.warning(
                        f"Low OCR confidence: text='{text}', "
                        f"confidence={confidence:.3f}"
                    )

                # Set span attributes
                if span:
                    span.set_attribute("ocr.text", cleaned or "")
                    span.set_attribute("ocr.confidence", confidence)
                    span.set_attribute("ocr.detection_count", len(results))
                    span.set_attribute("ocr.raw_text", text)

                return cleaned, confidence, ocr_data

            except Exception as e:
                self.logger.error(f"Username extraction error: {e}")
                if span:
                    span.set_attribute("ocr.error", str(e))
                return None, 0.0, None

    def _create_ocr_visualization(self, preprocessed_frame: np.ndarray, ocr_data: dict) -> Optional[bytes]:
        """
        Create visualization showing easyOCR bounding boxes

        Args:
            preprocessed_frame: The preprocessed image fed to easyOCR
            ocr_data: easyOCR output dict with detection list

        Returns:
            JPEG bytes of visualization, or None on error
        """
        try:
            # Convert grayscale to color
            if len(preprocessed_frame.shape) == 2:
                vis = cv2.cvtColor(preprocessed_frame, cv2.COLOR_GRAY2BGR)
            else:
                vis = preprocessed_frame.copy()

            # Draw bounding boxes for each detection
            for detection in ocr_data.get('detections', []):
                bbox = detection['bbox']  # [[x1,y1], [x2,y2], [x3,y3], [x4,y4]]
                text = detection['text']
                conf = detection['confidence']

                # Convert bbox to numpy array
                points = np.array(bbox, dtype=np.int32)

                # Color based on confidence
                if conf > 0.7:
                    color = (0, 255, 0)  # Green
                elif conf > 0.3:
                    color = (0, 255, 255)  # Yellow
                else:
                    color = (0, 0, 255)  # Red

                # Draw polygon
                cv2.polylines(vis, [points], True, color, 2)

                # Draw text label
                label = f"{text} ({conf:.2f})"
                cv2.putText(
                    vis, label, tuple(points[0]),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, color, 1
                )

            # Encode to JPEG
            success, encoded = cv2.imencode('.jpg', vis, [cv2.IMWRITE_JPEG_QUALITY, 90])
            return encoded.tobytes() if success else None

        except Exception as e:
            self.logger.error(f"OCR visualization error: {e}")
            return None

    def _generate_ocr_log(self, ocr_data: dict, timestamp: int, username: Optional[str], confidence: float) -> str:
        """
        Generate human-readable OCR debug log for easyOCR

        Args:
            ocr_data: easyOCR output dict with detection list
            timestamp: Frame timestamp
            username: Detected/cleaned username
            confidence: OCR confidence (0-1)

        Returns:
            Plain text log as string
        """
        try:
            lines = []
            lines.append("=" * 60)
            lines.append("OCR Debug Log (easyOCR)")
            lines.append("=" * 60)
            lines.append(f"Timestamp: {timestamp}s")
            lines.append(f"Detected Username: {username if username else '(none)'}")
            lines.append(f"Confidence: {confidence:.3f}")
            lines.append("")

            # Extract detections
            lines.append("Detected Text Elements:")
            lines.append("-" * 60)
            lines.append(f"{'Text':<30} {'Confidence':<12}")
            lines.append("-" * 60)

            for detection in ocr_data.get('detections', []):
                text = detection['text']
                conf = detection['confidence']
                lines.append(f"{text:<30} {conf:.3f}")

            lines.append("")
            lines.append(f"Total detections: {len(ocr_data.get('detections', []))}")
            lines.append("")

            return "\n".join(lines)

        except Exception as e:
            self.logger.error(f"OCR log generation error: {e}")
            return f"Error generating OCR log: {e}"
    
    def _clean_username(self, text: str) -> Optional[str]:
        """Clean and validate extracted username"""
        if not text:
            return None

        # Remove non-alphanumeric characters except underscore, dash, and dot
        import re
        cleaned = re.sub(r'[^a-zA-Z0-9_\-.]', '', text)

        return cleaned if cleaned else None
    
