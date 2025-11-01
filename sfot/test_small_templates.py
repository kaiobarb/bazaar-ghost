#!/usr/bin/env python3
"""
Test script for underscore-prefixed (small) templates on older VODs
"""

import cv2
import numpy as np
import sys
import os
from pathlib import Path
import argparse
import json

# Add src to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'src'))

from emblem_detector import EmblemDetector

def extract_frame(video_path: str, timestamp: int):
    """Extract a single frame from video at given timestamp"""
    cap = cv2.VideoCapture(video_path)
    cap.set(cv2.CAP_PROP_POS_MSEC, timestamp * 1000)
    ret, frame = cap.read()
    cap.release()
    return frame if ret else None

def apply_crop(frame, crop_percent):
    """Apply percentage-based crop to frame"""
    h, w = frame.shape[:2]
    x_pct, y_pct, w_pct, h_pct = crop_percent

    x = int(x_pct * w)
    y = int(y_pct * h)
    crop_w = int(w_pct * w)
    crop_h = int(h_pct * h)

    return frame[y:y+crop_h, x:x+crop_w]

def compare_templates(frame, timestamp, method='template', show_visual=True):
    """Compare detection results between normal and small templates"""

    # Initialize detectors
    normal_detector = EmblemDetector(
        templates_dir="/home/kaio/Dev/bazaar-ghost/sfot/templates",
        resolution="480p",
        method=method,
        old_templates=False
    )

    small_detector = EmblemDetector(
        templates_dir="/home/kaio/Dev/bazaar-ghost/sfot/templates",
        resolution="480p",
        method=method,
        old_templates=True
    )

    # Set thresholds based on method
    threshold = 0.85 if method == 'template' else 0.30

    # Detect with both template sets
    print(f"\n[Timestamp {timestamp}s]")
    print("-" * 50)

    # Normal templates
    normal_rank, normal_bbox, normal_conf = normal_detector.detect_emblem(frame, threshold=threshold)
    if normal_rank:
        print(f"Normal templates: {normal_rank} (conf: {normal_conf:.3f})")
        if normal_bbox:
            print(f"  Bbox: {normal_bbox}")
    else:
        print(f"Normal templates: No detection")

    # Small templates
    small_rank, small_bbox, small_conf = small_detector.detect_emblem(frame, threshold=threshold)
    if small_rank:
        print(f"Small templates:  {small_rank} (conf: {small_conf:.3f})")
        if small_bbox:
            print(f"  Bbox: {small_bbox}")
    else:
        print(f"Small templates:  No detection")

    # Visualize if requested
    if show_visual:
        vis_frame = frame.copy()

        # Draw normal detection in green
        if normal_rank and normal_bbox:
            x, y, w, h = normal_bbox
            cv2.rectangle(vis_frame, (x, y), (x+w, y+h), (0, 255, 0), 2)
            cv2.putText(vis_frame, f"Normal: {normal_rank} ({normal_conf:.2f})",
                       (x, y-10), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1)

        # Draw small detection in blue
        if small_rank and small_bbox:
            x, y, w, h = small_bbox
            # Offset slightly if overlapping with normal
            offset = 0 if not normal_bbox else 30
            cv2.rectangle(vis_frame, (x, y), (x+w, y+h), (255, 0, 0), 2)
            cv2.putText(vis_frame, f"Small: {small_rank} ({small_conf:.2f})",
                       (x, y+h+20+offset), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 0, 0), 1)

        # Show frame
        cv2.imshow("Template Comparison", vis_frame)

        # Show detected regions side by side if both detected
        if normal_bbox and small_bbox:
            nx, ny, nw, nh = normal_bbox
            sx, sy, sw, sh = small_bbox

            normal_region = frame[ny:ny+nh, nx:nx+nw]
            small_region = frame[sy:sy+sh, sx:sx+sw]

            # Resize to same height for comparison
            target_h = 100
            if normal_region.size > 0 and small_region.size > 0:
                normal_resized = cv2.resize(normal_region,
                                          (int(nw * target_h / nh), target_h))
                small_resized = cv2.resize(small_region,
                                         (int(sw * target_h / sh), target_h))

                # Create comparison image
                comparison = np.hstack([normal_resized,
                                       np.ones((target_h, 20, 3), dtype=np.uint8) * 128,
                                       small_resized])
                cv2.imshow("Detected Regions (Normal | Small)", comparison)

        # Show templates for reference
        if show_visual and (normal_rank or small_rank):
            template_comparison = []

            # Get the detected rank (prefer small if it detected something)
            rank_to_show = small_rank if small_rank else normal_rank

            # Normal template
            normal_template = normal_detector.templates.get(rank_to_show)
            if normal_template is not None:
                template_comparison.append(cv2.resize(normal_template, (100, 100)))

            # Small template
            small_template = small_detector.templates.get(rank_to_show)
            if small_template is not None:
                template_comparison.append(cv2.resize(small_template, (100, 100)))

            if len(template_comparison) == 2:
                template_vis = np.hstack([template_comparison[0],
                                         np.ones((100, 20, 3), dtype=np.uint8) * 128,
                                         template_comparison[1]])
                cv2.imshow(f"Templates for {rank_to_show} (Normal | Small)", template_vis)

    return {
        'timestamp': timestamp,
        'normal': {'rank': normal_rank, 'confidence': normal_conf, 'bbox': normal_bbox},
        'small': {'rank': small_rank, 'confidence': small_conf, 'bbox': small_bbox}
    }

def test_multiple_frames(video_path, timestamps, method='template', crop_percent=None):
    """Test multiple timestamps and summarize results"""

    results = []

    for ts in timestamps:
        frame = extract_frame(video_path, ts)
        if frame is not None:
            if crop_percent:
                frame = apply_crop(frame, crop_percent)

            result = compare_templates(frame, ts, method, show_visual=False)
            results.append(result)

            # Quick visual check
            cv2.imshow("Current Frame", frame)
            key = cv2.waitKey(100)
            if key == ord('q'):
                break

    # Summarize results
    print("\n" + "="*60)
    print("SUMMARY OF DETECTIONS")
    print("="*60)

    normal_detections = 0
    small_detections = 0
    both_detections = 0
    mismatches = 0

    for r in results:
        normal_detected = r['normal']['rank'] is not None
        small_detected = r['small']['rank'] is not None

        if normal_detected:
            normal_detections += 1
        if small_detected:
            small_detections += 1
        if normal_detected and small_detected:
            both_detections += 1
            if r['normal']['rank'] != r['small']['rank']:
                mismatches += 1

        # Print details if there's a difference
        if normal_detected != small_detected or (normal_detected and r['normal']['rank'] != r['small']['rank']):
            print(f"\n{r['timestamp']:4d}s: DIFFERENCE DETECTED")
            print(f"  Normal: {r['normal']['rank'] or 'None'} " +
                  (f"({r['normal']['confidence']:.3f})" if r['normal']['rank'] else ""))
            print(f"  Small:  {r['small']['rank'] or 'None'} " +
                  (f"({r['small']['confidence']:.3f})" if r['small']['rank'] else ""))

    print(f"\nStatistics:")
    print(f"  Normal templates detected: {normal_detections}/{len(results)}")
    print(f"  Small templates detected:  {small_detections}/{len(results)}")
    print(f"  Both detected same frame:  {both_detections}/{len(results)}")
    print(f"  Rank mismatches:          {mismatches}/{both_detections if both_detections > 0 else 1}")

    # Performance comparison
    if small_detections > normal_detections:
        print(f"\n✓ Small templates performed better (+{small_detections - normal_detections} detections)")
    elif normal_detections > small_detections:
        print(f"\n✗ Normal templates performed better (+{normal_detections - small_detections} detections)")
    else:
        print(f"\n= Both template sets performed equally ({small_detections} detections)")

    return results

def main():
    parser = argparse.ArgumentParser(description='Test small templates on older VOD')
    parser.add_argument('--vod', default='2538527387', help='VOD ID')
    parser.add_argument('--timestamp', type=int, help='Single timestamp to test')
    parser.add_argument('--method', choices=['template', 'akaze'], default='template',
                       help='Detection method')
    parser.add_argument('--batch', action='store_true',
                       help='Test batch of timestamps')
    parser.add_argument('--visual', action='store_true',
                       help='Show visual comparison for single timestamp')

    args = parser.parse_args()

    # Video path
    video_path = f"/home/kaio/Dev/bazaar-ghost/test_data/{args.vod}/480p.mp4"

    if not os.path.exists(video_path):
        print(f"Error: Video not found at {video_path}")
        return

    print(f"Testing templates on VOD {args.vod}")
    print(f"Method: {args.method.upper()}")
    print(f"Video: {video_path}")
    print("="*60)

    # Crop region from config
    crop_percent = [0.005859375, 0.5208333333333334, 0.2802734375, 0.20833333333333334]

    if args.batch:
        # Test multiple timestamps
        # These are timestamps where we expect to find matchup screens
        test_timestamps = [
            500, 750, 1000, 1250, 1500, 1750, 1969,  # EdsonCarteiro at 1969
            2000, 2250, 2500, 2750, 3000, 3250, 3500,
            3750, 4000, 4250, 4500, 4750, 5000,
            5500, 6000, 6500, 7000, 7500, 8000,
            8500, 9000, 9500, 10000, 10500, 11000, 11500
        ]

        # Filter to timestamps within first 3h20m (12000s) where Bazaar gameplay occurs
        test_timestamps = [ts for ts in test_timestamps if ts < 12000]

        print(f"Testing {len(test_timestamps)} timestamps...")
        results = test_multiple_frames(video_path, test_timestamps, args.method, crop_percent)

    else:
        # Test single timestamp
        timestamp = args.timestamp if args.timestamp else 1969  # Default to problematic EdsonCarteiro

        print(f"Extracting frame at {timestamp}s...")
        frame = extract_frame(video_path, timestamp)

        if frame is None:
            print("Error: Could not extract frame")
            return

        # Apply crop
        cropped = apply_crop(frame, crop_percent)
        print(f"Frame size after crop: {cropped.shape[1]}x{cropped.shape[0]}")

        # Compare templates
        result = compare_templates(cropped, timestamp, args.method, show_visual=args.visual or True)

        print("\nPress 'q' to quit, 's' to save comparison images...")
        key = cv2.waitKey(0)

        if key == ord('s'):
            # Save frames for analysis
            cv2.imwrite(f"frame_{timestamp}.png", cropped)
            print(f"Saved frame_{timestamp}.png")

            # Save detected regions if available
            if result['normal']['bbox']:
                x, y, w, h = result['normal']['bbox']
                region = cropped[y:y+h, x:x+w]
                cv2.imwrite(f"normal_detection_{timestamp}.png", region)
                print(f"Saved normal_detection_{timestamp}.png")

            if result['small']['bbox']:
                x, y, w, h = result['small']['bbox']
                region = cropped[y:y+h, x:x+w]
                cv2.imwrite(f"small_detection_{timestamp}.png", region)
                print(f"Saved small_detection_{timestamp}.png")

    cv2.destroyAllWindows()

if __name__ == '__main__':
    main()