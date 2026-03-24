"""Tests for rank emblem detection via template matching.

Tests that EmblemDetector correctly identifies rank emblems (bronze, silver,
gold, diamond, legend) from validated detection frames.

All detection results are pre-computed in the session-scoped
all_detection_results fixture — tests just query cached results.
"""

import pytest

from helpers import RESOLUTION_MAP


class TestEmblemDetectionOnVisibleFrames:
    """Frames annotated with emblem_visible=True should detect the correct rank."""

    def test_detects_correct_rank(
        self, emblem_visible_frames, all_detection_results, metrics
    ):
        correct = 0
        errors = []

        for frame in emblem_visible_frames:
            r = all_detection_results.get(frame.key)
            if r is None:
                continue

            if r.emblem_rank is None:
                errors.append(
                    f"NOT DETECTED: {frame.key} expected={frame.expected_rank}"
                )
            elif r.emblem_rank != frame.expected_rank:
                errors.append(
                    f"WRONG RANK: {frame.key} expected={frame.expected_rank} "
                    f"got={r.emblem_rank} conf={r.emblem_conf:.3f}"
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

    def test_emblem_bbox_is_valid(self, emblem_visible_frames, all_detection_results):
        for frame in emblem_visible_frames:
            r = all_detection_results.get(frame.key)
            if r is None or r.emblem_bbox is None:
                continue

            x, y, w, h = r.emblem_bbox
            img_h, img_w = frame.image.shape[:2]

            assert x >= 0 and y >= 0, (
                f"Bbox origin negative: {r.emblem_bbox} for {frame.key}"
            )
            assert x + w <= img_w, (
                f"Bbox exceeds width: {r.emblem_bbox} for {frame.key}"
            )
            assert y + h <= img_h, (
                f"Bbox exceeds height: {r.emblem_bbox} for {frame.key}"
            )
            assert x < img_w * 0.6, (
                f"Emblem too far right: x={x}, frame_w={img_w} for {frame.key}"
            )


class TestEmblemDetectionByRank:
    @pytest.mark.parametrize("rank", ["bronze", "silver", "gold", "diamond", "legend"])
    def test_rank_accuracy(
        self, rank, emblem_visible_frames, all_detection_results, metrics
    ):
        rank_frames = [f for f in emblem_visible_frames if f.expected_rank == rank]
        if not rank_frames:
            pytest.skip(f"No validated frames for rank={rank}")

        correct = 0
        errors = []
        for frame in rank_frames:
            r = all_detection_results.get(frame.key)
            if r is None:
                continue
            if r.emblem_rank == rank:
                correct += 1
            elif r.emblem_rank is None:
                errors.append(f"NOT DETECTED: {frame.key}")
            else:
                errors.append(
                    f"WRONG: {frame.key} got={r.emblem_rank} conf={r.emblem_conf:.3f}"
                )

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
    @pytest.mark.parametrize("resolution", ["480p", "720p", "1080p"])
    def test_resolution_accuracy(
        self, resolution, emblem_visible_frames, all_detection_results, metrics
    ):
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
            r = all_detection_results.get(frame.key)
            if r is None:
                continue
            if r.emblem_rank == frame.expected_rank:
                correct += 1
            elif r.emblem_rank is None:
                errors.append(
                    f"NOT DETECTED @{resolution}: {frame.key} expected={frame.expected_rank}"
                )
            else:
                errors.append(
                    f"WRONG @{resolution}: {frame.key} expected={frame.expected_rank} "
                    f"got={r.emblem_rank} conf={r.emblem_conf:.3f}"
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
    def test_no_emblem_frames_low_detection(
        self, no_emblem_frames, all_detection_results, metrics
    ):
        if not no_emblem_frames:
            pytest.skip("No frames annotated as no-emblem")

        detected = 0
        false_positives = []
        for frame in no_emblem_frames:
            r = all_detection_results.get(frame.key)
            if r is None:
                continue
            if r.emblem_rank is not None:
                detected += 1
                false_positives.append(
                    f"FALSE POS: {frame.key} detected={r.emblem_rank} conf={r.emblem_conf:.3f}"
                )

        rate = detected / len(no_emblem_frames)
        metrics(
            f"No-emblem false positives: {detected}/{len(no_emblem_frames)} ({rate:.1%})"
        )
        for fp in false_positives:
            metrics(fp)
