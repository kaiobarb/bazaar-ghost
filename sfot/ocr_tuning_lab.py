#!/usr/bin/env python3
"""
Interactive OCR tuning lab for Bazaar Ghost nameplate detection
Provides real-time parameter adjustment via OpenCV trackbars
"""

import json
import cv2
import numpy as np
import pytesseract
import os
import sys
from pathlib import Path
from emblem_detector import EmblemDetector

# Default image path - can be overridden via command line
DEFAULT_IMG = ".ignore/375(1).jpg"

def nothing(_): 
    """Trackbar callback"""
    pass

def clamp_odd(x): 
    """Ensure value is odd (required for some OpenCV operations)"""
    return x if x % 2 == 1 else max(3, x-1)

class OCRTuningLab:
    def __init__(self, img_path):
        self.img_path = img_path
        self.raw = cv2.imread(img_path)
        if self.raw is None:
            raise FileNotFoundError(f"Image not found: {img_path}")
        
        # Store original for reference
        self.original = self.raw.copy()
        
        # Crop selection variables
        self.crop_roi = None  # (x, y, w, h) tuple
        self.selecting = False
        self.selection_start = None
        self.selection_end = None
        
        # Tesseract whitelist for Twitch usernames
        self.whitelist = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"
        
        # Initialize emblem detector
        self.emblem_detector = EmblemDetector()
        self.detected_rank = None
        
        # Initialize windows
        self.setup_ui()
        
        # Load preset if exists
        self.load_preset()
    
    def setup_ui(self):
        """Setup OpenCV windows and trackbars"""
        # Main window for processed image
        cv2.namedWindow("OCR Tuning Lab", cv2.WINDOW_NORMAL)
        cv2.resizeWindow("OCR Tuning Lab", 1200, 400)
        
        # Crop selector window
        cv2.namedWindow("Crop Selector", cv2.WINDOW_NORMAL)
        cv2.setMouseCallback("Crop Selector", self.mouse_callback)
        
        # Control panel window
        cv2.namedWindow("Controls", cv2.WINDOW_NORMAL)
        cv2.resizeWindow("Controls", 400, 700)
        
        # Emblem removal trackbars
        cv2.createTrackbar("Remove Emblem", "Controls", 1, 1, nothing)
        cv2.createTrackbar("Emblem Thresh x100", "Controls", 70, 100, nothing)  # 0.0-1.0
        cv2.createTrackbar("Emblem Expand", "Controls", 2, 10, nothing)
        cv2.createTrackbar("Show Emblem Debug", "Controls", 0, 1, nothing)
        
        # Frame cropping trackbars
        cv2.createTrackbar("Crop Top", "Controls", 5, 20, nothing)
        cv2.createTrackbar("Crop Bottom", "Controls", 5, 20, nothing)
        cv2.createTrackbar("Crop Left", "Controls", 0, 20, nothing)
        cv2.createTrackbar("Crop Right", "Controls", 0, 20, nothing)
        
        # Preprocessing trackbars
        cv2.createTrackbar("Scale Factor x10", "Controls", 20, 50, nothing)  # 1.0-5.0
        cv2.createTrackbar("Grayscale", "Controls", 1, 1, nothing)
        
        # Noise reduction
        cv2.createTrackbar("Gaussian Blur", "Controls", 0, 15, nothing)
        cv2.createTrackbar("Median Blur", "Controls", 0, 15, nothing)
        cv2.createTrackbar("Bilateral d", "Controls", 0, 15, nothing)
        cv2.createTrackbar("Bilateral Color", "Controls", 75, 200, nothing)
        cv2.createTrackbar("Bilateral Space", "Controls", 75, 200, nothing)
        
        # Contrast enhancement
        cv2.createTrackbar("CLAHE Enable", "Controls", 1, 1, nothing)
        cv2.createTrackbar("CLAHE Clip x10", "Controls", 20, 100, nothing)  # 1.0-10.0
        cv2.createTrackbar("CLAHE Grid", "Controls", 8, 20, nothing)
        
        # Thresholding options
        cv2.createTrackbar("Thresh Type", "Controls", 2, 4, nothing)  # 0:Binary, 1:Otsu, 2:Adaptive Mean, 3:Adaptive Gaussian, 4:None
        cv2.createTrackbar("Binary Thresh", "Controls", 127, 255, nothing)
        cv2.createTrackbar("Adaptive Block", "Controls", 11, 51, nothing)  # odd only
        cv2.createTrackbar("Adaptive C", "Controls", 2, 20, nothing)
        
        # Morphological operations
        cv2.createTrackbar("Morph Op", "Controls", 0, 4, nothing)  # 0:None, 1:Erode, 2:Dilate, 3:Open, 4:Close
        cv2.createTrackbar("Morph Kernel", "Controls", 1, 7, nothing)
        cv2.createTrackbar("Morph Iter", "Controls", 1, 5, nothing)
        
        # Post-processing
        cv2.createTrackbar("Invert", "Controls", 0, 1, nothing)
        cv2.createTrackbar("Border Pad", "Controls", 10, 30, nothing)
        cv2.createTrackbar("Sharpen", "Controls", 0, 1, nothing)
        
        # OCR settings
        cv2.createTrackbar("PSM Mode", "Controls", 7, 13, nothing)
        cv2.createTrackbar("OEM Mode", "Controls", 1, 3, nothing)
        cv2.createTrackbar("DPI", "Controls", 300, 600, nothing)
    
    def preprocess(self, img):
        """Apply preprocessing based on trackbar values"""
        result = img.copy()
        
        # Step 1: Emblem removal (before anything else)
        if cv2.getTrackbarPos("Remove Emblem", "Controls") == 1:
            threshold = cv2.getTrackbarPos("Emblem Thresh x100", "Controls") / 100.0
            expand = cv2.getTrackbarPos("Emblem Expand", "Controls")
            
            # Determine fill value based on invert setting
            fill_value = 255 if cv2.getTrackbarPos("Invert", "Controls") == 0 else 1
            
            result, self.detected_rank = self.emblem_detector.remove_emblem(
                result, threshold=threshold, expand_pixels=expand, fill_value=fill_value
            )
            
            # Show debug visualization if enabled
            if cv2.getTrackbarPos("Show Emblem Debug", "Controls") == 1:
                debug_vis = self.emblem_detector.create_debug_visualization(
                    img, threshold=threshold, expand_pixels=expand
                )
                cv2.imshow("Emblem Detection Debug", debug_vis)
            else:
                # Close debug window if it exists
                cv2.destroyWindow("Emblem Detection Debug")
        else:
            self.detected_rank = None
            cv2.destroyWindow("Emblem Detection Debug")
        
        # Step 2: Frame cropping
        crop_top = cv2.getTrackbarPos("Crop Top", "Controls")
        crop_bottom = cv2.getTrackbarPos("Crop Bottom", "Controls")
        crop_left = cv2.getTrackbarPos("Crop Left", "Controls")
        crop_right = cv2.getTrackbarPos("Crop Right", "Controls")
        
        if crop_top > 0 or crop_bottom > 0 or crop_left > 0 or crop_right > 0:
            h, w = result.shape[:2]
            y1 = crop_top
            y2 = h - crop_bottom
            x1 = crop_left
            x2 = w - crop_right
            
            # Ensure valid crop
            if y2 > y1 and x2 > x1:
                result = result[y1:y2, x1:x2]
        
        # Step 3: Continue with existing preprocessing
        # Convert to grayscale if needed
        if cv2.getTrackbarPos("Grayscale", "Controls") == 1:
            if len(result.shape) == 3:
                result = cv2.cvtColor(result, cv2.COLOR_BGR2GRAY)
        
        # Scale up
        scale = cv2.getTrackbarPos("Scale Factor x10", "Controls") / 10.0
        if scale > 1.0:
            result = cv2.resize(result, None, fx=scale, fy=scale, 
                               interpolation=cv2.INTER_CUBIC)
        
        # Noise reduction - Gaussian blur
        gauss_k = cv2.getTrackbarPos("Gaussian Blur", "Controls")
        if gauss_k > 0:
            gauss_k = clamp_odd(gauss_k)
            result = cv2.GaussianBlur(result, (gauss_k, gauss_k), 0)
        
        # Median blur
        median_k = cv2.getTrackbarPos("Median Blur", "Controls")
        if median_k > 0:
            median_k = clamp_odd(median_k)
            result = cv2.medianBlur(result, median_k)
        
        # Bilateral filter
        bil_d = cv2.getTrackbarPos("Bilateral d", "Controls")
        if bil_d > 0:
            bil_color = cv2.getTrackbarPos("Bilateral Color", "Controls")
            bil_space = cv2.getTrackbarPos("Bilateral Space", "Controls")
            result = cv2.bilateralFilter(result, bil_d, bil_color, bil_space)
        
        # Ensure grayscale for following operations
        if len(result.shape) == 3:
            result = cv2.cvtColor(result, cv2.COLOR_BGR2GRAY)
        
        # CLAHE (Contrast Limited Adaptive Histogram Equalization)
        if cv2.getTrackbarPos("CLAHE Enable", "Controls") == 1:
            clip = cv2.getTrackbarPos("CLAHE Clip x10", "Controls") / 10.0
            grid = cv2.getTrackbarPos("CLAHE Grid", "Controls")
            clahe = cv2.createCLAHE(clipLimit=clip, tileGridSize=(grid, grid))
            result = clahe.apply(result)
        
        # Sharpen
        if cv2.getTrackbarPos("Sharpen", "Controls") == 1:
            kernel = np.array([[-1,-1,-1],
                              [-1, 9,-1],
                              [-1,-1,-1]])
            result = cv2.filter2D(result, -1, kernel)
        
        # Thresholding
        thresh_type = cv2.getTrackbarPos("Thresh Type", "Controls")
        if thresh_type == 0:  # Simple binary
            thresh_val = cv2.getTrackbarPos("Binary Thresh", "Controls")
            _, result = cv2.threshold(result, thresh_val, 255, cv2.THRESH_BINARY)
        elif thresh_type == 1:  # Otsu
            _, result = cv2.threshold(result, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
        elif thresh_type == 2:  # Adaptive Mean
            block = clamp_odd(cv2.getTrackbarPos("Adaptive Block", "Controls"))
            C = cv2.getTrackbarPos("Adaptive C", "Controls")
            result = cv2.adaptiveThreshold(result, 255, cv2.ADAPTIVE_THRESH_MEAN_C,
                                         cv2.THRESH_BINARY, block, C)
        elif thresh_type == 3:  # Adaptive Gaussian
            block = clamp_odd(cv2.getTrackbarPos("Adaptive Block", "Controls"))
            C = cv2.getTrackbarPos("Adaptive C", "Controls")
            result = cv2.adaptiveThreshold(result, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                                         cv2.THRESH_BINARY, block, C)
        # thresh_type == 4 means no thresholding
        
        # Morphological operations
        morph_op = cv2.getTrackbarPos("Morph Op", "Controls")
        if morph_op > 0:
            kernel_size = clamp_odd(cv2.getTrackbarPos("Morph Kernel", "Controls"))
            iterations = cv2.getTrackbarPos("Morph Iter", "Controls")
            kernel = np.ones((kernel_size, kernel_size), np.uint8)
            
            if morph_op == 1:  # Erode
                result = cv2.erode(result, kernel, iterations=iterations)
            elif morph_op == 2:  # Dilate
                result = cv2.dilate(result, kernel, iterations=iterations)
            elif morph_op == 3:  # Opening
                result = cv2.morphologyEx(result, cv2.MORPH_OPEN, kernel, iterations=iterations)
            elif morph_op == 4:  # Closing
                result = cv2.morphologyEx(result, cv2.MORPH_CLOSE, kernel, iterations=iterations)
        
        # Invert if needed
        if cv2.getTrackbarPos("Invert", "Controls") == 1:
            result = 255 - result
        
        # Add border padding
        pad = cv2.getTrackbarPos("Border Pad", "Controls")
        if pad > 0:
            result = cv2.copyMakeBorder(result, pad, pad, pad, pad, 
                                       cv2.BORDER_CONSTANT, value=255)
        
        return result
    
    def run_ocr(self, img):
        """Run Tesseract OCR with current settings"""
        psm = cv2.getTrackbarPos("PSM Mode", "Controls")
        oem = cv2.getTrackbarPos("OEM Mode", "Controls")
        dpi = cv2.getTrackbarPos("DPI", "Controls")
        
        config = f'--oem {oem} --psm {psm} -l eng ' \
                f'-c user_defined_dpi={dpi} ' \
                f'-c tessedit_char_whitelist="{self.whitelist}" ' \
                f'-c load_system_dawg=0 -c load_freq_dawg=0'
        
        try:
            # Get detailed data
            data = pytesseract.image_to_data(img, config=config, 
                                            output_type=pytesseract.Output.DICT)
            
            # Extract words with confidence
            words = []
            confs = []
            for i, word in enumerate(data['text']):
                conf = int(data['conf'][i])
                if word.strip() and conf > 0:
                    words.append(word)
                    confs.append(conf)
            
            text = " ".join(words).strip()
            mean_conf = (sum(confs) / len(confs)) if confs else 0
            
            # Also get simple string output
            simple_text = pytesseract.image_to_string(img, config=config).strip()
            
            return text, mean_conf, simple_text
        except Exception as e:
            return f"Error: {e}", 0, ""
    
    def draw_info(self, img, text, conf, simple_text):
        """Draw OCR results and info on image"""
        # Convert to color for overlay
        if len(img.shape) == 2:
            vis = cv2.cvtColor(img, cv2.COLOR_GRAY2BGR)
        else:
            vis = img.copy()
        
        # Create info overlay
        h, w = vis.shape[:2]
        info_height = 50
        overlay = np.zeros((info_height, w, 3), dtype=np.uint8)
        overlay[:] = (40, 40, 40)
        
        # Add text info (removed PSM line, will be in window title)
        y_offset = 20
        cv2.putText(overlay, f"Data: '{text}'", 
                   (10, y_offset), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1)
        
        y_offset += 25
        cv2.putText(overlay, f"Simple: '{simple_text}'", 
                   (10, y_offset), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 200, 255), 1)
        
        # Stack overlay on top
        result = np.vstack([overlay, vis])
        
        return result
    
    def update_window_title(self, conf):
        """Update the main window title with current settings"""
        psm = cv2.getTrackbarPos("PSM Mode", "Controls")
        thresh_names = ["Binary", "Otsu", "Adapt Mean", "Adapt Gauss", "None"]
        thresh_type = cv2.getTrackbarPos("Thresh Type", "Controls")
        
        rank_str = f" | Rank: {self.detected_rank.upper()}" if self.detected_rank else ""
        title = f"OCR Tuning Lab - PSM: {psm} | Thresh: {thresh_names[thresh_type]} | Conf: {conf:.1f}%{rank_str}"
        cv2.setWindowTitle("OCR Tuning Lab", title)
    
    def save_preset(self):
        """Save current settings to JSON"""
        preset = {
            "emblem_removal": {
                "enabled": cv2.getTrackbarPos("Remove Emblem", "Controls"),
                "threshold": cv2.getTrackbarPos("Emblem Thresh x100", "Controls") / 100.0,
                "expand": cv2.getTrackbarPos("Emblem Expand", "Controls"),
            },
            "frame_crop": {
                "top": cv2.getTrackbarPos("Crop Top", "Controls"),
                "bottom": cv2.getTrackbarPos("Crop Bottom", "Controls"),
                "left": cv2.getTrackbarPos("Crop Left", "Controls"),
                "right": cv2.getTrackbarPos("Crop Right", "Controls"),
            },
            "scale_factor": cv2.getTrackbarPos("Scale Factor x10", "Controls") / 10.0,
            "grayscale": cv2.getTrackbarPos("Grayscale", "Controls"),
            "gaussian_blur": cv2.getTrackbarPos("Gaussian Blur", "Controls"),
            "median_blur": cv2.getTrackbarPos("Median Blur", "Controls"),
            "bilateral": {
                "d": cv2.getTrackbarPos("Bilateral d", "Controls"),
                "sigmaColor": cv2.getTrackbarPos("Bilateral Color", "Controls"),
                "sigmaSpace": cv2.getTrackbarPos("Bilateral Space", "Controls"),
            },
            "clahe": {
                "enabled": cv2.getTrackbarPos("CLAHE Enable", "Controls"),
                "clip": cv2.getTrackbarPos("CLAHE Clip x10", "Controls") / 10.0,
                "grid": cv2.getTrackbarPos("CLAHE Grid", "Controls"),
            },
            "threshold": {
                "type": cv2.getTrackbarPos("Thresh Type", "Controls"),
                "binary_value": cv2.getTrackbarPos("Binary Thresh", "Controls"),
                "adaptive_block": cv2.getTrackbarPos("Adaptive Block", "Controls"),
                "adaptive_C": cv2.getTrackbarPos("Adaptive C", "Controls"),
            },
            "morphology": {
                "operation": cv2.getTrackbarPos("Morph Op", "Controls"),
                "kernel_size": cv2.getTrackbarPos("Morph Kernel", "Controls"),
                "iterations": cv2.getTrackbarPos("Morph Iter", "Controls"),
            },
            "invert": cv2.getTrackbarPos("Invert", "Controls"),
            "border_pad": cv2.getTrackbarPos("Border Pad", "Controls"),
            "sharpen": cv2.getTrackbarPos("Sharpen", "Controls"),
            "ocr": {
                "psm": cv2.getTrackbarPos("PSM Mode", "Controls"),
                "oem": cv2.getTrackbarPos("OEM Mode", "Controls"),
                "dpi": cv2.getTrackbarPos("DPI", "Controls"),
            }
        }
        
        with open("ocr_preset.json", "w") as f:
            json.dump(preset, f, indent=2)
        print("\n✓ Saved preset to ocr_preset.json")
        return preset
    
    def load_preset(self):
        """Load preset from JSON if exists"""
        if not os.path.exists("ocr_preset.json"):
            return
        
        try:
            with open("ocr_preset.json", "r") as f:
                preset = json.load(f)
            
            # Apply preset values
            if "emblem_removal" in preset:
                cv2.setTrackbarPos("Remove Emblem", "Controls", preset["emblem_removal"]["enabled"])
                cv2.setTrackbarPos("Emblem Thresh x100", "Controls", int(preset["emblem_removal"]["threshold"] * 100))
                cv2.setTrackbarPos("Emblem Expand", "Controls", preset["emblem_removal"]["expand"])
            
            if "frame_crop" in preset:
                cv2.setTrackbarPos("Crop Top", "Controls", preset["frame_crop"]["top"])
                cv2.setTrackbarPos("Crop Bottom", "Controls", preset["frame_crop"]["bottom"])
                cv2.setTrackbarPos("Crop Left", "Controls", preset["frame_crop"]["left"])
                cv2.setTrackbarPos("Crop Right", "Controls", preset["frame_crop"]["right"])
            
            if "scale_factor" in preset:
                cv2.setTrackbarPos("Scale Factor x10", "Controls", int(preset["scale_factor"] * 10))
            if "grayscale" in preset:
                cv2.setTrackbarPos("Grayscale", "Controls", preset["grayscale"])
            if "gaussian_blur" in preset:
                cv2.setTrackbarPos("Gaussian Blur", "Controls", preset["gaussian_blur"])
            if "median_blur" in preset:
                cv2.setTrackbarPos("Median Blur", "Controls", preset["median_blur"])
            
            if "bilateral" in preset:
                cv2.setTrackbarPos("Bilateral d", "Controls", preset["bilateral"]["d"])
                cv2.setTrackbarPos("Bilateral Color", "Controls", preset["bilateral"]["sigmaColor"])
                cv2.setTrackbarPos("Bilateral Space", "Controls", preset["bilateral"]["sigmaSpace"])
            
            if "clahe" in preset:
                cv2.setTrackbarPos("CLAHE Enable", "Controls", preset["clahe"]["enabled"])
                cv2.setTrackbarPos("CLAHE Clip x10", "Controls", int(preset["clahe"]["clip"] * 10))
                cv2.setTrackbarPos("CLAHE Grid", "Controls", preset["clahe"]["grid"])
            
            if "threshold" in preset:
                cv2.setTrackbarPos("Thresh Type", "Controls", preset["threshold"]["type"])
                cv2.setTrackbarPos("Binary Thresh", "Controls", preset["threshold"]["binary_value"])
                cv2.setTrackbarPos("Adaptive Block", "Controls", preset["threshold"]["adaptive_block"])
                cv2.setTrackbarPos("Adaptive C", "Controls", preset["threshold"]["adaptive_C"])
            
            if "morphology" in preset:
                cv2.setTrackbarPos("Morph Op", "Controls", preset["morphology"]["operation"])
                cv2.setTrackbarPos("Morph Kernel", "Controls", preset["morphology"]["kernel_size"])
                cv2.setTrackbarPos("Morph Iter", "Controls", preset["morphology"]["iterations"])
            
            if "invert" in preset:
                cv2.setTrackbarPos("Invert", "Controls", preset["invert"])
            if "border_pad" in preset:
                cv2.setTrackbarPos("Border Pad", "Controls", preset["border_pad"])
            if "sharpen" in preset:
                cv2.setTrackbarPos("Sharpen", "Controls", preset["sharpen"])
            
            if "ocr" in preset:
                cv2.setTrackbarPos("PSM Mode", "Controls", preset["ocr"]["psm"])
                cv2.setTrackbarPos("OEM Mode", "Controls", preset["ocr"]["oem"])
                cv2.setTrackbarPos("DPI", "Controls", preset["ocr"]["dpi"])
            
            print("✓ Loaded preset from ocr_preset.json")
        except Exception as e:
            print(f"Could not load preset: {e}")
    
    def mouse_callback(self, event, x, y, flags, param):
        """Handle mouse events for crop selection"""
        if event == cv2.EVENT_LBUTTONDOWN:
            self.selecting = True
            self.selection_start = (x, y)
            self.selection_end = (x, y)
        
        elif event == cv2.EVENT_MOUSEMOVE:
            if self.selecting:
                self.selection_end = (x, y)
        
        elif event == cv2.EVENT_LBUTTONUP:
            if self.selecting:
                self.selecting = False
                # Calculate crop ROI
                x1 = min(self.selection_start[0], self.selection_end[0])
                y1 = min(self.selection_start[1], self.selection_end[1])
                x2 = max(self.selection_start[0], self.selection_end[0])
                y2 = max(self.selection_start[1], self.selection_end[1])
                
                # Ensure valid selection
                if x2 - x1 > 5 and y2 - y1 > 5:
                    self.crop_roi = (x1, y1, x2 - x1, y2 - y1)
                    print(f"✓ Crop selected: x={x1}, y={y1}, w={x2-x1}, h={y2-y1}")
    
    def draw_crop_selector(self):
        """Draw crop selector window with current selection"""
        display = self.original.copy()
        
        # Draw existing crop ROI
        if self.crop_roi:
            x, y, w, h = self.crop_roi
            cv2.rectangle(display, (x, y), (x + w, y + h), (0, 255, 0), 2)
            cv2.putText(display, "Active Crop", (x, y - 5), 
                       cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1)
        
        # Draw current selection in progress
        if self.selecting and self.selection_start and self.selection_end:
            cv2.rectangle(display, self.selection_start, self.selection_end, 
                         (255, 255, 0), 1)
        
        # Add instructions
        h, w = display.shape[:2]
        instructions = [
            "Click and drag to select crop region",
            "Press C to clear crop",
            "ESC to close selector"
        ]
        y_offset = 25
        for instruction in instructions:
            cv2.putText(display, instruction, (10, y_offset), 
                       cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1)
            # Add black background for text
            (text_w, text_h), _ = cv2.getTextSize(instruction, 
                                                  cv2.FONT_HERSHEY_SIMPLEX, 0.5, 1)
            cv2.rectangle(display, (8, y_offset - text_h - 2), 
                         (12 + text_w, y_offset + 2), (0, 0, 0), -1)
            cv2.putText(display, instruction, (10, y_offset), 
                       cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1)
            y_offset += 25
        
        cv2.imshow("Crop Selector", display)
    
    def get_working_image(self):
        """Get the image to process (either cropped or full)"""
        if self.crop_roi:
            x, y, w, h = self.crop_roi
            return self.original[y:y+h, x:x+w].copy()
        return self.original.copy()
    
    def run(self):
        """Main processing loop"""
        print("\n=== OCR Tuning Lab ===")
        print(f"Image: {self.img_path}")
        print("\nControls:")
        print("  ESC   - Exit")
        print("  S     - Save preset")
        print("  R     - Reset to original")
        print("  O     - Show original/processed toggle")
        print("  C     - Open crop selector / Clear crop")
        print("  SPACE - Pause/Resume auto-update")
        print("\n")
        
        show_original = False
        auto_update = True
        show_crop_selector = True  # Show on startup
        
        while True:
            # Update crop selector window if visible
            if show_crop_selector:
                self.draw_crop_selector()
            
            if auto_update or cv2.waitKey(1) == ord(' '):
                # Get the working image (cropped or full)
                working_img = self.get_working_image()
                
                if show_original:
                    # Show original (or cropped original)
                    display = working_img.copy()
                    label = "ORIGINAL" if not self.crop_roi else "ORIGINAL (CROPPED)"
                    cv2.putText(display, label, (10, 30), 
                              cv2.FONT_HERSHEY_SIMPLEX, 1, (0, 0, 255), 2)
                else:
                    # Process and show result
                    processed = self.preprocess(working_img)
                    text, conf, simple = self.run_ocr(processed)
                    display = self.draw_info(processed, text, conf, simple)
                    
                    # Update window title with current settings
                    self.update_window_title(conf)
                    
                    # Add crop indicator
                    if self.crop_roi:
                        cv2.putText(display, "[CROPPED]", (display.shape[1] - 100, 20), 
                                  cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1)
                
                cv2.imshow("OCR Tuning Lab", display)
            
            key = cv2.waitKey(30) & 0xFF
            
            if key == 27:  # ESC
                # Close crop selector if open, otherwise exit
                if show_crop_selector:
                    show_crop_selector = False
                    cv2.destroyWindow("Crop Selector")
                else:
                    break
            elif key == ord('s'):  # Save
                self.save_preset()
            elif key == ord('r'):  # Reset
                self.setup_ui()
                print("✓ Reset to defaults")
            elif key == ord('o'):  # Toggle original
                show_original = not show_original
            elif key == ord('c') or key == ord('C'):  # Crop selector
                if show_crop_selector:
                    # Clear crop and close selector
                    self.crop_roi = None
                    show_crop_selector = False
                    cv2.destroyWindow("Crop Selector")
                    print("✓ Crop cleared")
                else:
                    # Open crop selector
                    show_crop_selector = True
                    cv2.namedWindow("Crop Selector", cv2.WINDOW_NORMAL)
                    cv2.setMouseCallback("Crop Selector", self.mouse_callback)
                    print("✓ Crop selector opened")
            elif key == ord(' '):  # Toggle auto-update
                auto_update = not auto_update
                status = "enabled" if auto_update else "disabled"
                print(f"Auto-update {status}")
        
        cv2.destroyAllWindows()


def main():
    # Get image path from command line or use default
    img_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_IMG
    
    # Make path relative to project root if needed
    if not os.path.isabs(img_path):
        project_root = Path(__file__).parent.parent
        img_path = str(project_root / img_path)
    
    try:
        lab = OCRTuningLab(img_path)
        lab.run()
    except FileNotFoundError as e:
        print(f"Error: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"Unexpected error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()