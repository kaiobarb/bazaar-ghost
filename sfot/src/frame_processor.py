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

class FrameProcessor:
    """Process frames for matchup detection and OCR"""
    
    def __init__(self, config: Dict[str, Any]):
        """Initialize frame processor with configuration"""
        self.config = config
        self.logger = logging.getLogger('sfot.frame_processor')
        
        # Load detection parameters
        self.threshold = config['detection']['threshold']
        
        # Load template if specified
        self.template = None
        if 'template_path' in config['detection']:
            try:
                self.template = cv2.imread(config['detection']['template_path'], 0)
                self.logger.info(f"Loaded template: {config['detection']['template_path']}")
            except Exception as e:
                self.logger.warning(f"Could not load template: {e}")
        
        # Tesseract configuration
        self.tesseract_config = config['tesseract']['config']
        self.tesseract_lang = config['tesseract']['lang']
        
        # Cache for performance
        self.last_matchup_time = 0
        self.min_matchup_interval = 10  # Minimum seconds between matchups
    
    def process_frame(self, frame_data: bytes, timestamp: int, vod_id: str) -> Optional[Dict[str, Any]]:
        """
        Process a single frame for matchup detection
        
        Args:
            frame_data: JPEG frame data
            timestamp: Timestamp in seconds
            vod_id: VOD identifier
            
        Returns:
            Detection result or None
        """
        try:
            # Decode frame
            frame = self._decode_frame(frame_data)
            if frame is None:
                return None
            
            # Check for matchup
            is_matchup, confidence = self._detect_matchup(frame)
            
            if not is_matchup:
                return None
            
            # Check minimum interval
            if timestamp - self.last_matchup_time < self.min_matchup_interval:
                return None
            
            self.last_matchup_time = timestamp
            
            # Preprocess frame for OCR
            processed = self._preprocess_for_ocr(frame)
            
            # Extract username via OCR using preprocessed frame
            username = self._extract_usernames(processed)
            
            # Encode the original frame (already cropped by FFmpeg)
            success, encoded = cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
            frame_jpeg = encoded.tobytes() if success else None
            
            # Encode the preprocessed frame for debug
            success_debug, encoded_debug = cv2.imencode('.jpg', processed, [cv2.IMWRITE_JPEG_QUALITY, 90])
            debug_jpeg = encoded_debug.tobytes() if success_debug else None
            
            # Prepare result
            result = {
                'vod_id': vod_id,
                'timestamp': timestamp,
                'is_matchup': True,
                'confidence': confidence,
                'username': username,
                'frame_base64': base64.b64encode(frame_jpeg).decode('utf-8') if frame_jpeg else None,
                'ocr_debug_frame': base64.b64encode(debug_jpeg).decode('utf-8') if debug_jpeg else None
            }
            
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
    
    def _detect_matchup(self, frame: np.ndarray) -> Tuple[bool, float]:
        """
        Detect if frame contains a matchup screen
        
        Returns:
            (is_matchup, confidence_score)
        """
        try:
            # Convert to grayscale
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            
            if self.template is not None:
                return self._template_matching(gray)
            
        except Exception as e:
            self.logger.error(f"Matchup detection error: {e}")
            return False, 0.0
    
    def _template_matching(self, gray: np.ndarray) -> Tuple[bool, float]:
        """Use template matching for detection"""
        try:
            # Apply template matching
            result = cv2.matchTemplate(gray, self.template, cv2.TM_CCOEFF_NORMED)
            min_val, max_val, min_loc, max_loc = cv2.minMaxLoc(result)
            
            # Check if match exceeds threshold
            is_match = max_val >= self.threshold
            return is_match, max_val
            
        except Exception as e:
            self.logger.error(f"Template matching error: {e}")
            return False, 0.0
    
    
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
    
