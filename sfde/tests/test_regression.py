"""Aggregate accuracy regression tests.

These tests enforce minimum accuracy thresholds across the full validated
dataset. They're the primary CI gate — if any threshold drops, the build fails.

Thresholds are derived from config.yaml values and expected baseline performance.
"""

import pytest

from helpers import get_processor_key, get_emblem_detector_key


class TestEmblemAccuracyRegression:
    """Emblem detection must stay above threshold across all validated frames."""

    def test_overall_emblem_accuracy(
        self, emblem_visible_frames, emblem_detectors, emblem_threshold, metrics
    ):
        correct = 0
        total = 0

        for frame in emblem_visible_frames:
            det_key = get_emblem_detector_key(frame)
            detector = emblem_detectors.get(det_key)
            if detector is None:
                continue

            total += 1
            rank, _, _ = detector.detect_emblem(frame.image, threshold=emblem_threshold)
            if rank == frame.expected_rank:
                correct += 1

        accuracy = correct / total if total > 0 else 0
        metrics(
            f"[SUMMARY] Emblem accuracy (regression): {correct}/{total} ({accuracy:.1%})"
        )
        assert accuracy >= 0.98, f"Emblem accuracy regression: {accuracy:.1%} < 98%"


class TestOCRAccuracyRegression:
    """OCR username extraction must stay above threshold."""

    def test_overall_ocr_accuracy(
        self,
        emblem_visible_frames,
        frame_processors,
        emblem_detectors,
        emblem_threshold,
        metrics,
    ):
        """All emblem-visible frames: OCR should match ground truth username."""
        correct = 0
        total = 0

        for frame in emblem_visible_frames:
            proc_key = get_processor_key(frame)
            processor = frame_processors.get(proc_key)
            if processor is None:
                continue

            det_key = get_emblem_detector_key(frame)
            detector = emblem_detectors.get(det_key)
            if detector is None:
                continue

            total += 1
            rank, bbox, _ = detector.detect_emblem(
                frame.image, threshold=emblem_threshold
            )
            cropped = processor._crop(frame.image, bbox)
            username, _, _ = processor._extract_usernames(cropped)

            if username == frame.expected_username:
                correct += 1

        accuracy = correct / total if total > 0 else 0
        metrics(
            f"[SUMMARY] OCR accuracy (regression): {correct}/{total} ({accuracy:.1%})"
        )
        assert accuracy >= 0.80, f"OCR accuracy regression: {accuracy:.1%} < 80%"

    def test_clean_ocr_accuracy(
        self,
        clean_frames,
        frame_processors,
        emblem_detectors,
        emblem_threshold,
        metrics,
    ):
        """Clean frames only: higher accuracy expected."""
        correct = 0
        total = 0

        for frame in clean_frames:
            if not frame.emblem_visible:
                continue

            proc_key = get_processor_key(frame)
            processor = frame_processors.get(proc_key)
            if processor is None:
                continue

            det_key = get_emblem_detector_key(frame)
            detector = emblem_detectors.get(det_key)
            if detector is None:
                continue

            total += 1
            rank, bbox, _ = detector.detect_emblem(
                frame.image, threshold=emblem_threshold
            )
            cropped = processor._crop(frame.image, bbox)
            username, _, _ = processor._extract_usernames(cropped)

            if username == frame.expected_username:
                correct += 1

        accuracy = correct / total if total > 0 else 0
        metrics(
            f"[SUMMARY] Clean OCR accuracy (regression): {correct}/{total} ({accuracy:.1%})"
        )
        assert accuracy >= 0.90, f"Clean OCR accuracy regression: {accuracy:.1%} < 90%"


class TestRightEdgeDetectionRegression:
    """Right edge detection rate on visible-edge frames."""

    def test_right_edge_detection_rate(
        self,
        right_edge_visible_frames,
        right_edge_detectors,
        right_edge_threshold,
        metrics,
    ):
        default_frames = [f for f in right_edge_visible_frames if f.custom_edge is None]
        if not default_frames:
            pytest.skip("No default-profile right-edge-visible frames")

        detected = 0
        total = 0

        for frame in default_frames:
            detector = right_edge_detectors.get(frame.template_resolution)
            if detector is None:
                continue

            total += 1
            x, _ = detector.detect_right_edge(
                frame.image, threshold=right_edge_threshold
            )
            if x is not None:
                detected += 1

        rate = detected / total if total > 0 else 0
        metrics(
            f"[SUMMARY] Right edge detection (regression): {detected}/{total} ({rate:.1%})"
        )
        assert rate >= 0.80, f"Right edge detection regression: {rate:.1%} < 80%"


class TestDatasetIntegrity:
    """Ensure the test dataset itself is valid."""

    def test_minimum_frame_count(self, all_validated_frames, metrics):
        count = len(all_validated_frames)
        metrics(f"Dataset size: {count} validated frames")
        assert count >= 500, (
            f"Test dataset too small: {count} frames. Expected at least 500."
        )

    def test_all_categories_represented(self, all_validated_frames):
        categories = set(f.category for f in all_validated_frames)
        expected = {"clean", "bad", "covered_edge", "old_templates"}
        assert categories == expected, f"Missing categories: {expected - categories}"

    def test_all_ranks_represented(self, all_validated_frames):
        ranks = set(f.expected_rank for f in all_validated_frames)
        expected = {"bronze", "silver", "gold", "diamond", "legend"}
        assert ranks == expected, f"Missing ranks: {expected - ranks}"

    def test_multiple_qualities_represented(self, all_validated_frames):
        qualities = set(f.quality for f in all_validated_frames)
        assert len(qualities) >= 3, (
            f"Too few qualities: {qualities}. Expected at least 3."
        )

    def test_frames_loadable(self, all_validated_frames):
        """Spot-check that frames can actually be loaded."""
        import random

        sample = random.sample(all_validated_frames, min(20, len(all_validated_frames)))
        for frame in sample:
            img = frame.image
            assert img is not None, f"Could not load {frame.image_path}"
            assert len(img.shape) == 3, f"Not a color image: {frame.image_path}"
            assert img.shape[2] == 3, f"Not BGR: {frame.image_path}"
