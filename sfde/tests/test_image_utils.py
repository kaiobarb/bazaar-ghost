"""Tests for image_utils pure functions.

These run with zero external dependencies (cv2/numpy are in the container).
"""

import numpy as np

from image_utils import decode_jpeg, encode_jpeg, percent_to_pixels, slice_subregion


class TestPercentToPixels:
    def test_basic(self):
        # 50% x, 25% y, 30% w, 10% h on an 854x480 frame
        result = percent_to_pixels([0.5, 0.25, 0.3, 0.1], 854, 480)
        w, h, x, y = result
        assert x == 427  # floor(0.5 * 854)
        assert y == 120  # floor(0.25 * 480)
        assert w == 257  # ceil(0.3 * 854)
        assert h == 48   # ceil(0.1 * 480)

    def test_clamps_to_frame_bounds(self):
        # Region that would extend past the right/bottom edge
        result = percent_to_pixels([0.9, 0.9, 0.5, 0.5], 854, 480)
        w, h, x, y = result
        assert x + w <= 854
        assert y + h <= 480

    def test_full_frame(self):
        result = percent_to_pixels([0.0, 0.0, 1.0, 1.0], 854, 480)
        w, h, x, y = result
        assert x == 0
        assert y == 0
        assert w == 854
        assert h == 480

    def test_returns_four_ints(self):
        result = percent_to_pixels([0.1, 0.2, 0.3, 0.4], 1920, 1080)
        assert len(result) == 4
        assert all(isinstance(v, int) for v in result)


class TestJpegRoundtrip:
    def _make_frame(self, w=64, h=64):
        return np.random.randint(0, 255, (h, w, 3), dtype=np.uint8)

    def test_encode_decode_roundtrip(self):
        frame = self._make_frame()
        encoded = encode_jpeg(frame)
        decoded = decode_jpeg(encoded)
        assert decoded is not None
        assert decoded.shape == frame.shape

    def test_encode_returns_bytes(self):
        frame = self._make_frame()
        result = encode_jpeg(frame)
        assert isinstance(result, bytes)
        # JPEG magic bytes
        assert result[:2] == b"\xff\xd8"
        assert result[-2:] == b"\xff\xd9"

    def test_decode_bad_bytes_returns_none(self):
        result = decode_jpeg(b"not a jpeg")
        assert result is None

    def test_decode_empty_returns_none(self):
        result = decode_jpeg(b"")
        assert result is None


class TestSliceSubregion:
    def test_slice_top_left(self):
        frame = np.zeros((100, 200, 3), dtype=np.uint8)
        frame[0:20, 0:40] = 255  # mark top-left
        region = [0, 0, 40, 20]  # x, y, w, h
        sliced = slice_subregion(frame, region)
        assert sliced.shape == (20, 40, 3)
        assert sliced.mean() == 255

    def test_slice_preserves_content(self):
        frame = np.zeros((100, 200, 3), dtype=np.uint8)
        frame[10:30, 50:100] = 128
        region = [50, 10, 50, 20]
        sliced = slice_subregion(frame, region)
        assert sliced.shape == (20, 50, 3)
        assert sliced.mean() == 128

    def test_slice_returns_view(self):
        frame = np.zeros((100, 200, 3), dtype=np.uint8)
        region = [0, 0, 50, 50]
        sliced = slice_subregion(frame, region)
        # numpy slices are views — modifying slice modifies original
        sliced[:] = 99
        assert frame[0, 0, 0] == 99
