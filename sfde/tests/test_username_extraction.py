"""Tests for username OCR extraction accuracy.

All detection results are pre-computed in the session-scoped
all_detection_results fixture — tests just query cached results.
"""

import pytest


class TestUsernameExtractionClean:
    def test_clean_frame_accuracy(self, clean_frames, all_detection_results, metrics):
        if not clean_frames:
            pytest.skip("No clean frames")

        correct = 0
        wrong = []

        for frame in clean_frames:
            r = all_detection_results.get(frame.key)
            if r is None:
                continue
            if r.ocr_username == frame.expected_username:
                correct += 1
            else:
                wrong.append(
                    f"{frame.key}: expected='{frame.expected_username}' "
                    f"got='{r.ocr_username}' conf={r.ocr_confidence:.3f}"
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
    @pytest.mark.parametrize("quality", ["480p", "720p", "720p60", "1080p60"])
    def test_quality_accuracy(
        self, quality, all_validated_frames, all_detection_results, metrics
    ):
        quality_frames = [
            f for f in all_validated_frames if f.quality == quality and f.emblem_visible
        ]
        if not quality_frames:
            pytest.skip(f"No validated frames for quality={quality}")

        correct = 0
        wrong = []
        for frame in quality_frames:
            r = all_detection_results.get(frame.key)
            if r is None:
                continue
            if r.ocr_username == frame.expected_username:
                correct += 1
            else:
                wrong.append(
                    f"{frame.key}: expected='{frame.expected_username}' "
                    f"got='{r.ocr_username}' conf={r.ocr_confidence:.3f}"
                )

        total = len(quality_frames)
        accuracy = correct / total if total > 0 else 0
        metrics(f"[DETAIL] OCR @{quality}: {correct}/{total} ({accuracy:.1%})")
        for w in wrong:
            metrics(w)


class TestUsernameExtractionCorrected:
    def test_corrected_usernames(
        self, all_validated_frames, all_detection_results, metrics
    ):
        corrected = [
            f for f in all_validated_frames if f.username_corrected and f.emblem_visible
        ]
        if not corrected:
            pytest.skip("No corrected-username frames")

        matches = 0
        wrong = []

        for frame in corrected:
            r = all_detection_results.get(frame.key)
            if r is None:
                continue
            if r.ocr_username == frame.expected_username:
                matches += 1
            else:
                wrong.append(
                    f"{frame.key}: expected='{frame.expected_username}' "
                    f"got='{r.ocr_username}' conf={r.ocr_confidence:.3f}"
                )

        total = len(corrected)
        rate = matches / total if total > 0 else 0
        metrics(f"Corrected username OCR match rate: {matches}/{total} ({rate:.1%})")
        for w in wrong:
            metrics(w)
