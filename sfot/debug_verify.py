#!/usr/bin/env python3
"""
Verify what gets saved as debug frame vs what tesseract actually processes
"""

import yaml
import cv2
import base64
import sys

sys.path.insert(0, 'src')
from frame_processor import FrameProcessor

def test_debug_consistency():
    with open('config.yaml', 'r') as f:
        config = yaml.safe_load(f)
    
    processor = FrameProcessor(config)
    
    # Load test frame and encode to bytes
    frame = cv2.imread("../.ignore/375(1).jpg")
    success, encoded = cv2.imencode('.jpg', frame)
    frame_bytes = encoded.tobytes()
    
    # Process frame
    result = processor.process_frame(frame_bytes, 123, "test")
    
    if result and result['ocr_debug_frame']:
        # Decode the debug frame from base64
        debug_data = base64.b64decode(result['ocr_debug_frame'])
        
        # Save it to compare
        with open('debug_frame_from_result.jpg', 'wb') as f:
            f.write(debug_data)
        
        print("✓ Saved debug frame from result to: debug_frame_from_result.jpg")
        print(f"✓ OCR result: '{result['username']}'")
        
        # Also manually run the pipeline to compare
        frame = processor._decode_frame(frame_bytes)
        processed_frame, emblem_right_x, detected_rank = processor._detect_and_remove_emblem(frame)
        cropped_frame = processor._intelligent_crop(processed_frame, result['template_left_x'], emblem_right_x)
        final_processed = processor._advanced_preprocess_for_ocr(cropped_frame)
        
        cv2.imwrite('manual_final_processed.jpg', final_processed)
        print("✓ Saved manual final processed to: manual_final_processed.jpg")
        
        # Compare shapes
        debug_img = cv2.imdecode(cv2.imdecode(debug_data, cv2.IMREAD_UNCHANGED), cv2.IMREAD_UNCHANGED)
        if debug_img is not None:
            print(f"Debug frame shape: {debug_img.shape}")
        print(f"Manual processed shape: {final_processed.shape}")
        
    else:
        print("❌ No result or debug frame")

if __name__ == "__main__":
    test_debug_consistency()