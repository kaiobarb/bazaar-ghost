"""Tests for right edge detection in nameplate frames.

Tests that RightEdgeDetector correctly identifies (or correctly fails to
identify) the right boundary of the nameplate frame.
"""

import pytest

from helpers import get_emblem_detector_key


class TestRightEdgeVisible:
    """Frames annotated with right_edge_visible=True should detect an edge."""

    def test_detection_rate(
        self,
        right_edge_visible_frames,
        right_edge_detectors,
        right_edge_threshold,
        metrics,
    ):
        """Right edge should be detected on frames where it's visible."""
        default_frames = [f for f in right_edge_visible_frames if f.custom_edge is None]
        if not default_frames:
            pytest.skip("No default-profile frames with visible right edge")

        detected = 0
        missed = []
        for frame in default_frames:
            detector = right_edge_detectors.get(frame.template_resolution)
            if detector is None:
                continue

            x, conf = detector.detect_right_edge(
                frame.image, threshold=right_edge_threshold
            )
            if x is not None:
                detected += 1
            else:
                missed.append(
                    f"MISSED: {frame.key} quality={frame.quality} conf={conf:.3f}"
                )

        rate = detected / len(default_frames) if default_frames else 0
        metrics(
            f"[SUMMARY] Right edge detection: {detected}/{len(default_frames)} ({rate:.1%})"
        )
        for m in missed:
            metrics(m)

        assert rate >= 0.80, f"Right edge detection rate {rate:.1%} below 80% threshold"

    def test_edge_position_is_reasonable(
        self, right_edge_visible_frames, right_edge_detectors, right_edge_threshold
    ):
        """Detected right edge should be in the right portion of the frame."""
        default_frames = [f for f in right_edge_visible_frames if f.custom_edge is None]

        for frame in default_frames:
            detector = right_edge_detectors.get(frame.template_resolution)
            if detector is None:
                continue

            x, conf = detector.detect_right_edge(
                frame.image, threshold=right_edge_threshold
            )
            if x is None:
                continue

            img_w = frame.image.shape[1]
            ratio = x / img_w

            assert ratio >= 0.4, (
                f"Right edge too far left: x={x}, w={img_w}, ratio={ratio:.2f} "
                f"for {frame.key}"
            )
            assert x <= img_w, (
                f"Right edge past frame boundary: x={x}, w={img_w} for {frame.key}"
            )


class TestRightEdgeByResolution:
    """Per-resolution detection rate breakdown."""

    @pytest.mark.parametrize("resolution", ["480p", "720p", "1080p"])
    def test_resolution_detection_rate(
        self,
        resolution,
        right_edge_visible_frames,
        right_edge_detectors,
        right_edge_threshold,
        metrics,
    ):
        from helpers import RESOLUTION_MAP

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
            detector = right_edge_detectors.get(resolution)
            if detector is None:
                continue

            x, conf = detector.detect_right_edge(
                frame.image, threshold=right_edge_threshold
            )
            if x is not None:
                detected += 1
            else:
                missed.append(f"MISSED @{resolution}: {frame.key} conf={conf:.3f}")

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
    """Frames annotated with right_edge_visible=False."""

    def test_obscured_frames_info(
        self, no_right_edge_frames, right_edge_detectors, right_edge_threshold, metrics
    ):
        """Track detection behavior on frames with obscured right edge."""
        if not no_right_edge_frames:
            pytest.skip("No frames annotated as right-edge-obscured")

        default_frames = [f for f in no_right_edge_frames if f.custom_edge is None]
        if not default_frames:
            pytest.skip("No default-profile frames with obscured right edge")

        detected = 0
        false_positives = []
        for frame in default_frames:
            detector = right_edge_detectors.get(frame.template_resolution)
            if detector is None:
                continue

            x, conf = detector.detect_right_edge(
                frame.image, threshold=right_edge_threshold
            )
            if x is not None:
                detected += 1
                false_positives.append(f"FALSE POS: {frame.key} x={x} conf={conf:.3f}")

        rate = detected / len(default_frames) if default_frames else 0
        metrics(
            f"Right edge false positives (obscured): {detected}/{len(default_frames)} ({rate:.1%})"
        )
        for fp in false_positives:
            metrics(fp)
