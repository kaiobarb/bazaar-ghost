"""Tests for sfde_config geometry functions.

parse_sfde_profile and load_config touch env/filesystem so are
integration-level; compute_combined_crop is pure and tested here.
"""


from sfde_config import compute_combined_crop


class TestComputeCombinedCrop:
    BASE_PROFILE = {"crop_region": [0.1, 0.6, 0.8, 0.15]}

    def test_no_igd_returns_nameplate_only(self):
        crop, nameplate_slice, igd_slice = compute_combined_crop(
            self.BASE_PROFILE, 854, 480
        )
        assert nameplate_slice is None
        assert igd_slice is None
        # crop should equal percent_to_pixels result for crop_region
        from image_utils import percent_to_pixels
        expected = percent_to_pixels([0.1, 0.6, 0.8, 0.15], 854, 480)
        assert crop == expected

    def test_with_igd_returns_slices(self):
        profile = {
            **self.BASE_PROFILE,
            "igd_crop_region": [0.05, 0.75, 0.2, 0.1],
        }
        crop, nameplate_slice, igd_slice = compute_combined_crop(profile, 854, 480)
        assert nameplate_slice is not None
        assert igd_slice is not None
        assert len(crop) == 4
        assert len(nameplate_slice) == 4
        assert len(igd_slice) == 4

    def test_combined_crop_encompasses_both_regions(self):
        """Combined bbox must contain both nameplate and IGD pixels."""
        profile = {
            "crop_region": [0.1, 0.1, 0.3, 0.2],
            "igd_crop_region": [0.5, 0.5, 0.3, 0.2],
        }
        crop, nameplate_slice, igd_slice = compute_combined_crop(profile, 854, 480)
        bbox_w, bbox_h, bbox_x, bbox_y = crop

        from image_utils import percent_to_pixels
        np_w, np_h, np_x, np_y = percent_to_pixels([0.1, 0.1, 0.3, 0.2], 854, 480)
        igd_w, igd_h, igd_x, igd_y = percent_to_pixels([0.5, 0.5, 0.3, 0.2], 854, 480)

        assert bbox_x <= np_x
        assert bbox_y <= np_y
        assert bbox_x + bbox_w >= np_x + np_w
        assert bbox_y + bbox_h >= np_y + np_h
        assert bbox_x <= igd_x
        assert bbox_y <= igd_y
        assert bbox_x + bbox_w >= igd_x + igd_w
        assert bbox_y + bbox_h >= igd_y + igd_h

    def test_slices_are_local_offsets(self):
        """Slice offsets must be relative to combined crop, not frame."""
        profile = {
            "crop_region": [0.1, 0.6, 0.4, 0.1],
            "igd_crop_region": [0.1, 0.75, 0.4, 0.1],
        }
        crop, nameplate_slice, igd_slice = compute_combined_crop(profile, 854, 480)
        bbox_w, bbox_h, bbox_x, bbox_y = crop
        np_x, np_y, np_w, np_h = nameplate_slice
        ig_x, ig_y, ig_w, ig_h = igd_slice

        # Slices must fit within the combined crop
        assert np_x + np_w <= bbox_w
        assert np_y + np_h <= bbox_h
        assert ig_x + ig_w <= bbox_w
        assert ig_y + ig_h <= bbox_h

    def test_clamps_to_frame_bounds(self):
        profile = {"crop_region": [0.9, 0.9, 0.5, 0.5]}  # would overflow
        crop, _, _ = compute_combined_crop(profile, 854, 480)
        w, h, x, y = crop
        assert x + w <= 854
        assert y + h <= 480
