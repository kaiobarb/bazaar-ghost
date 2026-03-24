"""Aggregate accuracy regression tests.

These tests enforce minimum accuracy thresholds across the full validated
dataset. They're the primary CI gate — if any threshold drops, the build fails.

All detection results are pre-computed in the session-scoped
all_detection_results fixture — tests just query cached results.
"""

import pytest


class TestEmblemAccuracyRegression:
    def test_overall_emblem_accuracy(
        self, emblem_visible_frames, all_detection_results
    ):
        correct = 0
        total = 0

        for frame in emblem_visible_frames:
            r = all_detection_results.get(frame.key)
            if r is None:
                continue
            total += 1
            if r.emblem_rank == frame.expected_rank:
                correct += 1

        accuracy = correct / total if total > 0 else 0
        assert accuracy >= 0.98, f"Emblem accuracy regression: {accuracy:.1%} < 98%"


class TestOCRAccuracyRegression:
    def test_overall_ocr_accuracy(self, emblem_visible_frames, all_detection_results):
        correct = 0
        total = 0

        for frame in emblem_visible_frames:
            r = all_detection_results.get(frame.key)
            if r is None:
                continue
            total += 1
            if r.ocr_username == frame.expected_username:
                correct += 1

        accuracy = correct / total if total > 0 else 0
        assert accuracy >= 0.80, f"OCR accuracy regression: {accuracy:.1%} < 80%"

    def test_clean_ocr_accuracy(self, clean_frames, all_detection_results):
        correct = 0
        total = 0

        for frame in clean_frames:
            if not frame.emblem_visible:
                continue
            r = all_detection_results.get(frame.key)
            if r is None:
                continue
            total += 1
            if r.ocr_username == frame.expected_username:
                correct += 1

        accuracy = correct / total if total > 0 else 0
        assert accuracy >= 0.90, f"Clean OCR accuracy regression: {accuracy:.1%} < 90%"


class TestRightEdgeDetectionRegression:
    def test_right_edge_detection_rate(
        self, right_edge_visible_frames, all_detection_results
    ):
        default_frames = [f for f in right_edge_visible_frames if f.custom_edge is None]
        if not default_frames:
            pytest.skip("No default-profile right-edge-visible frames")

        detected = 0
        total = 0

        for frame in default_frames:
            r = all_detection_results.get(frame.key)
            if r is None:
                continue
            total += 1
            if r.right_edge_x is not None:
                detected += 1

        rate = detected / total if total > 0 else 0
        assert rate >= 0.80, f"Right edge detection regression: {rate:.1%} < 80%"


class TestDatasetIntegrity:
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
        import random

        sample = random.sample(all_validated_frames, min(20, len(all_validated_frames)))
        for frame in sample:
            img = frame.image
            assert img is not None, f"Could not load {frame.image_path}"
            assert len(img.shape) == 3, f"Not a color image: {frame.image_path}"
            assert img.shape[2] == 3, f"Not BGR: {frame.image_path}"
