"""Tests for right edge detection in nameplate frames.

All detection results are pre-computed in the session-scoped
all_detection_results fixture — tests just query cached results.
"""

import pytest

from helpers import RESOLUTION_MAP


class TestRightEdgeVisible:
    def test_detection_rate(
        self, right_edge_visible_frames, all_detection_results, metrics
    ):
        default_frames = [f for f in right_edge_visible_frames if f.custom_edge is None]
        if not default_frames:
            pytest.skip("No default-profile frames with visible right edge")

        detected = 0
        missed = []
        for frame in default_frames:
            r = all_detection_results.get(frame.key)
            if r is None:
                continue
            if r.right_edge_x is not None:
                detected += 1
            else:
                missed.append(
                    f"MISSED: {frame.key} quality={frame.quality} conf={r.right_edge_conf:.3f}"
                )

        rate = detected / len(default_frames) if default_frames else 0
        metrics(
            f"[SUMMARY] Right edge detection: {detected}/{len(default_frames)} ({rate:.1%})"
        )
        for m in missed:
            metrics(m)

        assert rate >= 0.80, f"Right edge detection rate {rate:.1%} below 80% threshold"

    def test_edge_position_is_reasonable(
        self, right_edge_visible_frames, all_detection_results
    ):
        default_frames = [f for f in right_edge_visible_frames if f.custom_edge is None]

        for frame in default_frames:
            r = all_detection_results.get(frame.key)
            if r is None or r.right_edge_x is None:
                continue

            img_w = frame.image.shape[1]
            ratio = r.right_edge_x / img_w

            assert ratio >= 0.4, (
                f"Right edge too far left: x={r.right_edge_x}, w={img_w}, "
                f"ratio={ratio:.2f} for {frame.key}"
            )
            assert r.right_edge_x <= img_w, (
                f"Right edge past frame boundary: x={r.right_edge_x}, w={img_w} "
                f"for {frame.key}"
            )


class TestRightEdgeByResolution:
    @pytest.mark.parametrize("resolution", ["480p", "720p", "1080p"])
    def test_resolution_detection_rate(
        self, resolution, right_edge_visible_frames, all_detection_results, metrics
    ):
        res_frames = [
            f
            for f in right_edge_visible_frames
            if RESOLUTION_MAP.get(f.quality, "480p") == resolution
            and f.custom_edge is None
        ]
        if not res_frames:
            pytest.skip(f"No default-profile right-edge-visible frames at {resolution}")

        detected = 0
        missed = []
        for frame in res_frames:
            r = all_detection_results.get(frame.key)
            if r is None:
                continue
            if r.right_edge_x is not None:
                detected += 1
            else:
                missed.append(
                    f"MISSED @{resolution}: {frame.key} conf={r.right_edge_conf:.3f}"
                )

        rate = detected / len(res_frames) if res_frames else 0
        metrics(
            f"[DETAIL] Right edge @{resolution}: {detected}/{len(res_frames)} ({rate:.1%})"
        )
        for m in missed:
            metrics(m)

        assert rate >= 0.75, (
            f"Right edge detection at {resolution}: {rate:.1%} below 75% threshold"
        )


class TestRightEdgeObscured:
    def test_obscured_frames_info(
        self, no_right_edge_frames, all_detection_results, metrics
    ):
        if not no_right_edge_frames:
            pytest.skip("No frames annotated as right-edge-obscured")

        default_frames = [f for f in no_right_edge_frames if f.custom_edge is None]
        if not default_frames:
            pytest.skip("No default-profile frames with obscured right edge")

        detected = 0
        false_positives = []
        for frame in default_frames:
            r = all_detection_results.get(frame.key)
            if r is None:
                continue
            if r.right_edge_x is not None:
                detected += 1
                false_positives.append(
                    f"FALSE POS: {frame.key} x={r.right_edge_x} conf={r.right_edge_conf:.3f}"
                )

        rate = detected / len(default_frames) if default_frames else 0
        metrics(
            f"Right edge false positives (obscured): {detected}/{len(default_frames)} ({rate:.1%})"
        )
        for fp in false_positives:
            metrics(fp)
