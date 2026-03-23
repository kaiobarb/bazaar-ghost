"""Tests for username OCR extraction accuracy.

Tests the full pipeline: frame -> emblem crop -> OCR -> clean_username,
using FrameProcessor on validated detection frames.

The frames in fixtures/ are already-cropped nameplate regions (as stored in
Supabase), so we test _extract_usernames and _crop + _extract_usernames paths.
"""

import pytest

from helpers import get_processor_key, get_emblem_detector_key


class TestUsernameExtractionClean:
    """OCR accuracy on clean (high-confidence, default profile) frames."""

    def test_clean_frame_accuracy(
        self,
        clean_frames,
        frame_processors,
        emblem_detectors,
        emblem_threshold,
        metrics,
    ):
        """Clean frames should have high OCR accuracy."""
        if not clean_frames:
            pytest.skip("No clean frames")

        correct = 0
        wrong = []

        for frame in clean_frames:
            proc_key = get_processor_key(frame)
            processor = frame_processors.get(proc_key)
            if processor is None:
                continue

            det_key = get_emblem_detector_key(frame)
            detector = emblem_detectors.get(det_key)
            if detector is None:
                continue

            rank, bbox, conf = detector.detect_emblem(
                frame.image, threshold=emblem_threshold
            )
            cropped = processor._crop(frame.image, bbox)
            username, ocr_conf, _ = processor._extract_usernames(cropped)

            if username == frame.expected_username:
                correct += 1
            else:
                wrong.append(
                    f"{frame.key}: expected='{frame.expected_username}' got='{username}' "
                    f"conf={ocr_conf:.3f}"
                )

        total = len(clean_frames)
        accuracy = correct / total if total > 0 else 0

        metrics(f"[SUMMARY] Clean OCR: {correct}/{total} ({accuracy:.1%})")
        for w in wrong:
            metrics(w)

        assert accuracy >= 0.90, (
            f"Clean frame OCR accuracy {accuracy:.1%} below 90% threshold. "
            f"See {len(wrong)} failures above."
        )


class TestUsernameExtractionByQuality:
    """Per-quality OCR accuracy breakdown."""

    @pytest.mark.parametrize("quality", ["480p", "720p", "720p60", "1080p60"])
    def test_quality_accuracy(
        self,
        quality,
        all_validated_frames,
        frame_processors,
        emblem_detectors,
        emblem_threshold,
        metrics,
    ):
        quality_frames = [
            f for f in all_validated_frames if f.quality == quality and f.emblem_visible
        ]
        if not quality_frames:
            pytest.skip(f"No validated frames for quality={quality}")

        proc_key = quality if not quality_frames[0].old_templates else f"{quality}_old"
        processor = frame_processors.get(proc_key)
        if processor is None:
            pytest.skip(f"No processor for {proc_key}")

        correct = 0
        wrong = []
        for frame in quality_frames:
            det_key = get_emblem_detector_key(frame)
            detector = emblem_detectors.get(det_key)
            if detector is None:
                continue

            rank, bbox, _ = detector.detect_emblem(
                frame.image, threshold=emblem_threshold
            )
            cropped = processor._crop(frame.image, bbox)
            username, ocr_conf, _ = processor._extract_usernames(cropped)

            if username == frame.expected_username:
                correct += 1
            else:
                wrong.append(
                    f"{frame.key}: expected='{frame.expected_username}' got='{username}' "
                    f"conf={ocr_conf:.3f}"
                )

        total = len(quality_frames)
        accuracy = correct / total if total > 0 else 0
        metrics(f"[DETAIL] OCR @{quality}: {correct}/{total} ({accuracy:.1%})")
        for w in wrong:
            metrics(w)


class TestUsernameExtractionCorrected:
    """Frames where the username was manually corrected during annotation."""

    def test_corrected_usernames(
        self,
        all_validated_frames,
        frame_processors,
        emblem_detectors,
        emblem_threshold,
        metrics,
    ):
        """Corrected frames are known-hard cases. Track OCR accuracy on them."""
        corrected = [
            f for f in all_validated_frames if f.username_corrected and f.emblem_visible
        ]
        if not corrected:
            pytest.skip("No corrected-username frames")

        matches_corrected = 0
        wrong = []

        for frame in corrected:
            proc_key = get_processor_key(frame)
            processor = frame_processors.get(proc_key)
            if processor is None:
                continue

            det_key = get_emblem_detector_key(frame)
            detector = emblem_detectors.get(det_key)
            if detector is None:
                continue

            rank, bbox, _ = detector.detect_emblem(
                frame.image, threshold=emblem_threshold
            )
            cropped = processor._crop(frame.image, bbox)
            username, conf, _ = processor._extract_usernames(cropped)

            if username == frame.expected_username:
                matches_corrected += 1
            else:
                wrong.append(
                    f"{frame.key}: expected='{frame.expected_username}' got='{username}' "
                    f"conf={conf:.3f}"
                )

        total = len(corrected)
        rate = matches_corrected / total if total > 0 else 0
        metrics(
            f"Corrected username OCR match rate: {matches_corrected}/{total} ({rate:.1%})"
        )
        for w in wrong:
            metrics(w)
