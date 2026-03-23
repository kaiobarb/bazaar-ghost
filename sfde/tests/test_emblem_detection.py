"""Tests for rank emblem detection via template matching.

Tests that EmblemDetector correctly identifies rank emblems (bronze, silver,
gold, diamond, legend) from validated detection frames.
"""

import pytest

from helpers import get_emblem_detector_key


class TestEmblemDetectionOnVisibleFrames:
    """Frames annotated with emblem_visible=True should detect the correct rank."""

    def test_detects_correct_rank(
        self, emblem_visible_frames, emblem_detectors, emblem_threshold, metrics
    ):
        """Each visible-emblem frame should match its annotated rank."""
        correct = 0
        errors = []

        for frame in emblem_visible_frames:
            det_key = get_emblem_detector_key(frame)
            detector = emblem_detectors.get(det_key)
            if detector is None:
                continue

            rank, bbox, conf = detector.detect_emblem(
                frame.image, threshold=emblem_threshold
            )

            if rank is None:
                errors.append(
                    f"NOT DETECTED: {frame.key} expected={frame.expected_rank}"
                )
            elif rank != frame.expected_rank:
                errors.append(
                    f"WRONG RANK: {frame.key} expected={frame.expected_rank} got={rank} conf={conf:.3f}"
                )
            else:
                correct += 1

        total = len(emblem_visible_frames)
        accuracy = correct / total if total > 0 else 0

        metrics(f"[SUMMARY] Emblem detection: {correct}/{total} ({accuracy:.1%})")
        for err in errors:
            metrics(err)

        assert accuracy >= 0.98, (
            f"Emblem detection accuracy {accuracy:.1%} below 98% threshold. "
            f"{len(errors)} failures."
        )

    def test_emblem_bbox_is_valid(
        self, emblem_visible_frames, emblem_detectors, emblem_threshold
    ):
        """Detected emblems should have a reasonable bounding box."""
        for frame in emblem_visible_frames:
            det_key = get_emblem_detector_key(frame)
            detector = emblem_detectors.get(det_key)
            if detector is None:
                continue

            rank, bbox, conf = detector.detect_emblem(
                frame.image, threshold=emblem_threshold
            )
            if bbox is None:
                continue

            x, y, w, h = bbox
            img_h, img_w = frame.image.shape[:2]

            assert x >= 0 and y >= 0, f"Bbox origin negative: {bbox} for {frame.key}"
            assert x + w <= img_w, f"Bbox exceeds width: {bbox} for {frame.key}"
            assert y + h <= img_h, f"Bbox exceeds height: {bbox} for {frame.key}"
            assert x < img_w * 0.6, (
                f"Emblem too far right: x={x}, frame_w={img_w} for {frame.key}"
            )


class TestEmblemDetectionByRank:
    """Per-rank accuracy breakdown."""

    @pytest.mark.parametrize("rank", ["bronze", "silver", "gold", "diamond", "legend"])
    def test_rank_accuracy(
        self, rank, emblem_visible_frames, emblem_detectors, emblem_threshold, metrics
    ):
        rank_frames = [f for f in emblem_visible_frames if f.expected_rank == rank]
        if not rank_frames:
            pytest.skip(f"No validated frames for rank={rank}")

        correct = 0
        errors = []
        for frame in rank_frames:
            det_key = get_emblem_detector_key(frame)
            detector = emblem_detectors.get(det_key)
            if detector is None:
                continue

            detected_rank, _, conf = detector.detect_emblem(
                frame.image, threshold=emblem_threshold
            )
            if detected_rank == rank:
                correct += 1
            elif detected_rank is None:
                errors.append(f"NOT DETECTED: {frame.key}")
            else:
                errors.append(f"WRONG: {frame.key} got={detected_rank} conf={conf:.3f}")

        accuracy = correct / len(rank_frames)
        metrics(
            f"[DETAIL] Emblem {rank}: {correct}/{len(rank_frames)} ({accuracy:.1%})"
        )
        for err in errors:
            metrics(err)

        assert accuracy >= 0.95, (
            f"{rank} emblem accuracy {accuracy:.1%} below 95% threshold"
        )


class TestEmblemDetectionByResolution:
    """Per-resolution accuracy breakdown."""

    @pytest.mark.parametrize("resolution", ["480p", "720p", "1080p"])
    def test_resolution_accuracy(
        self,
        resolution,
        emblem_visible_frames,
        emblem_detectors,
        emblem_threshold,
        metrics,
    ):
        from helpers import RESOLUTION_MAP

        res_frames = [
            f
            for f in emblem_visible_frames
            if RESOLUTION_MAP.get(f.quality, "480p") == resolution
        ]
        if not res_frames:
            pytest.skip(f"No validated frames for resolution={resolution}")

        correct = 0
        errors = []
        for frame in res_frames:
            det_key = get_emblem_detector_key(frame)
            detector = emblem_detectors.get(det_key)
            if detector is None:
                continue

            detected_rank, _, conf = detector.detect_emblem(
                frame.image, threshold=emblem_threshold
            )
            if detected_rank == frame.expected_rank:
                correct += 1
            elif detected_rank is None:
                errors.append(
                    f"NOT DETECTED @{resolution}: {frame.key} expected={frame.expected_rank}"
                )
            else:
                errors.append(
                    f"WRONG @{resolution}: {frame.key} expected={frame.expected_rank} got={detected_rank} conf={conf:.3f}"
                )

        accuracy = correct / len(res_frames)
        metrics(
            f"[DETAIL] Emblem @{resolution}: {correct}/{len(res_frames)} ({accuracy:.1%})"
        )
        for err in errors:
            metrics(err)

        assert accuracy >= 0.95, (
            f"{resolution} emblem accuracy {accuracy:.1%} below 95% threshold"
        )


class TestNoEmblemFrames:
    """Frames annotated with emblem_visible=False should ideally not detect."""

    def test_no_emblem_frames_low_detection(
        self, no_emblem_frames, emblem_detectors, emblem_threshold, metrics
    ):
        if not no_emblem_frames:
            pytest.skip("No frames annotated as no-emblem")

        detected = 0
        false_positives = []
        for frame in no_emblem_frames:
            det_key = get_emblem_detector_key(frame)
            detector = emblem_detectors.get(det_key)
            if detector is None:
                continue

            rank, _, conf = detector.detect_emblem(
                frame.image, threshold=emblem_threshold
            )
            if rank is not None:
                detected += 1
                false_positives.append(
                    f"FALSE POS: {frame.key} detected={rank} conf={conf:.3f}"
                )

        rate = detected / len(no_emblem_frames)
        metrics(
            f"No-emblem false positives: {detected}/{len(no_emblem_frames)} ({rate:.1%})"
        )
        for fp in false_positives:
            metrics(fp)
