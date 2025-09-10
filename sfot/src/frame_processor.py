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
        self.crop_region = config['detection']['crop_region']
        
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
            
            # Extract usernames via OCR
            usernames = self._extract_usernames(frame)
            
            # Prepare result
            result = {
                'vod_id': vod_id,
                'timestamp': timestamp,
                'is_matchup': True,
                'confidence': confidence,
                'player1_username': usernames.get('player1'),
                'player2_username': usernames.get('player2'),
                'frame_base64': base64.b64encode(frame_data).decode('utf-8')
            }
            
            self.logger.debug(f"Detected matchup at {timestamp}s: {usernames}")
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
            
            # If we have a template, use template matching
            if self.template is not None:
                return self._template_matching(gray)
            
            # Otherwise use feature detection
            return self._feature_detection(gray)
            
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
    
    def _feature_detection(self, gray: np.ndarray) -> Tuple[bool, float]:
        """
        Use feature detection for matchup screen
        Looking for specific patterns that indicate a matchup screen
        """
        try:
            # Crop to region of interest if specified
            if self.crop_region:
                x, y, w, h = self.crop_region
                roi = gray[y:y+h, x:x+w]
            else:
                roi = gray
            
            # Look for "VS" text pattern
            # Apply edge detection
            edges = cv2.Canny(roi, 50, 150)
            
            # Count edge pixels (matchup screens have consistent UI elements)
            edge_ratio = np.count_nonzero(edges) / edges.size
            
            # Matchup screens typically have 5-15% edge pixels in the ROI
            is_matchup = 0.05 <= edge_ratio <= 0.15
            confidence = min(1.0, edge_ratio / 0.10) if is_matchup else edge_ratio
            
            return is_matchup, confidence
            
        except Exception as e:
            self.logger.error(f"Feature detection error: {e}")
            return False, 0.0
    
    def _extract_usernames(self, frame: np.ndarray) -> Dict[str, Optional[str]]:
        """
        Extract player usernames from matchup screen using OCR
        
        Returns:
            Dictionary with player1 and player2 usernames
        """
        usernames = {'player1': None, 'player2': None}
        
        try:
            # Define regions for username extraction
            # These coordinates should be calibrated for The Bazaar UI
            username_regions = {
                'player1': (100, 200, 300, 50),  # x, y, width, height
                'player2': (500, 200, 300, 50)
            }
            
            for player, (x, y, w, h) in username_regions.items():
                # Crop region
                username_roi = frame[y:y+h, x:x+w]
                
                # Preprocess for OCR
                processed = self._preprocess_for_ocr(username_roi)
                
                # Run OCR
                text = pytesseract.image_to_string(
                    processed,
                    lang=self.tesseract_lang,
                    config=self.tesseract_config
                ).strip()
                
                # Clean up text
                cleaned = self._clean_username(text)
                if cleaned:
                    usernames[player] = cleaned
                    
        except Exception as e:
            self.logger.error(f"Username extraction error: {e}")
        
        return usernames
    
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