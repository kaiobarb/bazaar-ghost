"""Smoke test: verify the refactored modules import cleanly.

This catches broken imports in sfde.py / workers/* without needing
a live Supabase connection or a real chunk.
"""



def test_image_utils_imports():
    import image_utils

    assert callable(image_utils.percent_to_pixels)
    assert callable(image_utils.decode_jpeg)
    assert callable(image_utils.encode_jpeg)
    assert callable(image_utils.slice_subregion)


def test_sfde_config_imports():
    import sfde_config

    assert callable(sfde_config.load_config)
    assert callable(sfde_config.parse_sfde_profile)
    assert callable(sfde_config.compute_combined_crop)
    assert isinstance(sfde_config.QUALITY_RESOLUTIONS, dict)


def test_workers_package_imports():
    from workers import PipelineContext, ffmpeg, opencv, result, streamlink

    assert callable(ffmpeg.run)
    assert callable(opencv.run)
    assert callable(result.run)
    assert callable(streamlink.run)
    assert PipelineContext is not None


def test_workers_context_fields():
    """PipelineContext dataclass has expected fields."""
    import dataclasses

    from workers.context import PipelineContext

    fields = {f.name for f in dataclasses.fields(PipelineContext)}
    for expected in (
        "chunk_id",
        "frame_queue",
        "pts_queue",
        "result_queue",
        "shutdown",
        "nameplate_slice",
        "igd_slice",
        "combined_crop",
    ):
        assert expected in fields, f"PipelineContext missing field: {expected}"
