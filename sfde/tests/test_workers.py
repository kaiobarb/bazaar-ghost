"""Orchestration tests for SFDE pipeline workers.

Each worker is tested in isolation via a hand-built PipelineContext with
mock collaborators. No Supabase, no subprocess, no Docker required beyond
the container's installed deps (cv2, numpy).

Pattern for terminating workers:
  - Pre-fill frame_queue / result_queue with N items.
  - Make the mock's Nth call set ctx.shutdown so the worker exits cleanly.
"""

from __future__ import annotations

import queue
import threading
from typing import Any, Dict
from unittest.mock import MagicMock

import numpy as np

from image_utils import encode_jpeg
from workers.context import PipelineContext

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_MINIMAL_CONFIG = {
    "processing": {"frame_rate": 0.5, "queue_size": 10, "timeout": 30},
    "supabase": {"batch_size": 3},
    "logging": {"level": "WARNING"},
    "ffmpeg": {"keyframes_only": False},
    "test_mode": {"data_directory": "test_data"},
}


def _make_jpeg(w: int = 32, h: int = 32) -> bytes:
    """Return minimal valid JPEG bytes."""
    frame = np.zeros((h, w, 3), dtype=np.uint8)
    return encode_jpeg(frame)


def make_ctx(**overrides) -> PipelineContext:
    """Build a PipelineContext with mock collaborators.

    Pass keyword args to override any field (e.g. igd_slice=[...]).
    """
    defaults: Dict[str, Any] = dict(
        chunk_id="test-chunk-uuid",
        vod_id="test-vod-id",
        streamer="test_streamer",
        quality="480p",
        formatted_quality="480p",
        start_time=100,
        end_time=200,
        test_mode=True,
        config=_MINIMAL_CONFIG,
        profile={"crop_region": [0.1, 0.6, 0.8, 0.15]},
        span_attributes={},
        logger=MagicMock(),
        combined_crop=[683, 72, 85, 288],
        nameplate_slice=None,
        igd_slice=None,
        frame_queue=queue.Queue(maxsize=20),
        pts_queue=queue.Queue(),
        result_queue=queue.Queue(),
        shutdown=threading.Event(),
        frame_processor=MagicMock(),
        supabase=MagicMock(),
    )
    defaults.update(overrides)
    return PipelineContext(**defaults)


# ---------------------------------------------------------------------------
# Result worker
# ---------------------------------------------------------------------------

class TestResultWorker:
    def test_batches_and_uploads(self):
        """Accumulates batch_size detections then calls upload_batch."""
        from workers import result

        ctx = make_ctx()
        batch_size = ctx.config["supabase"]["batch_size"]  # 3

        detections = [
            {"timestamp": 100 + i, "username": f"user{i}", "confidence": 0.9,
             "detected_rank": "gold", "frame_base64": None}
            for i in range(batch_size)
        ]
        for d in detections:
            ctx.result_queue.put(d)

        # After draining queue: set shutdown so worker exits
        def upload_side_effect(batch):
            ctx.shutdown.set()

        ctx.supabase.upload_batch.side_effect = upload_side_effect

        result.run(ctx)

        ctx.supabase.upload_batch.assert_called_once()
        uploaded = ctx.supabase.upload_batch.call_args[0][0]
        assert len(uploaded) == batch_size

    def test_flushes_partial_batch_on_shutdown(self):
        """Remaining detections (< batch_size) are flushed in finally block."""
        from workers import result

        ctx = make_ctx()
        # Put fewer items than batch_size so no mid-run upload triggers
        ctx.result_queue.put(
            {"timestamp": 100, "username": "u1", "confidence": 0.8,
             "detected_rank": None, "frame_base64": None}
        )
        ctx.shutdown.set()  # exit immediately after draining

        result.run(ctx)

        # Should flush the one item in finally
        ctx.supabase.upload_batch.assert_called_once()
        assert len(ctx.supabase.upload_batch.call_args[0][0]) == 1

    def test_all_detections_tracked(self):
        """Each result is appended to ctx.all_detections for summary export."""
        from workers import result

        ctx = make_ctx()
        ctx.result_queue.put(
            {"timestamp": 105, "username": "player1", "confidence": 0.95,
             "detected_rank": "diamond", "frame_base64": None}
        )
        ctx.shutdown.set()

        result.run(ctx)

        assert len(ctx.all_detections) == 1
        assert ctx.all_detections[0]["username"] == "player1"

    def test_empty_queue_exits_on_shutdown(self):
        """Worker exits cleanly when shutdown is set and queue is empty."""
        from workers import result

        ctx = make_ctx()
        ctx.shutdown.set()

        result.run(ctx)  # should not block or raise

        ctx.supabase.upload_batch.assert_not_called()


# ---------------------------------------------------------------------------
# OpenCV worker (no IGD)
# ---------------------------------------------------------------------------

class TestOpencvWorker:
    def _fill_queues(self, ctx: PipelineContext, n: int):
        jpeg = _make_jpeg()
        for i in range(n):
            ctx.frame_queue.put(jpeg)
            ctx.pts_queue.put(float(i * 2))  # 2s apart

    def test_non_matchup_frames_not_enqueued(self):
        """Frames where process_frame returns None don't reach result_queue."""
        from workers import opencv

        ctx = make_ctx()
        n = 3
        self._fill_queues(ctx, n)

        call_count = [0]
        def process_frame(*a, **kw):
            call_count[0] += 1
            if call_count[0] >= n:
                ctx.shutdown.set()
            return None  # no matchup

        ctx.frame_processor.process_frame.side_effect = process_frame

        opencv.run(ctx)

        assert ctx.result_queue.empty()
        assert ctx.frames_processed == n
        assert ctx.matchups_found == 0

    def test_matchup_detection_enqueued(self):
        """A frame with is_matchup=True lands in result_queue."""
        from workers import opencv

        ctx = make_ctx()
        self._fill_queues(ctx, 2)

        detection = {
            "is_matchup": True, "username": "opponent1",
            "confidence": 0.91, "detected_rank": "gold",
            "timestamp": 102, "truncated": False,
        }
        call_count = [0]
        def process_frame(*a, **kw):
            call_count[0] += 1
            if call_count[0] >= 2:
                ctx.shutdown.set()
            return detection if call_count[0] == 1 else None

        ctx.frame_processor.process_frame.side_effect = process_frame

        opencv.run(ctx)

        assert ctx.matchups_found == 1
        assert not ctx.result_queue.empty()
        result = ctx.result_queue.get_nowait()
        assert result["username"] == "opponent1"

    def test_frames_processed_counter(self):
        """ctx.frames_processed increments for every frame consumed."""
        from workers import opencv

        ctx = make_ctx()
        n = 5
        self._fill_queues(ctx, n)

        call_count = [0]
        def process_frame(*a, **kw):
            call_count[0] += 1
            if call_count[0] >= n:
                ctx.shutdown.set()
            return None

        ctx.frame_processor.process_frame.side_effect = process_frame

        opencv.run(ctx)

        assert ctx.frames_processed == n


# ---------------------------------------------------------------------------
# OpenCV worker — IGD state machine
# ---------------------------------------------------------------------------

class TestOpencvIGD:
    def _fill_queues(self, ctx, n):
        jpeg = _make_jpeg()
        for i in range(n):
            ctx.frame_queue.put(jpeg)
            ctx.pts_queue.put(float(i))

    def test_igd_found_before_timeout(self):
        """Detection is enqueued with igd value when extract_igd succeeds."""
        from workers import opencv

        ctx = make_ctx(
            nameplate_slice=[0, 0, 32, 16],
            igd_slice=[0, 16, 32, 16],
            combined_crop=[32, 32, 0, 0],
        )
        # Frame 1: matchup detected → starts IGD scan
        # Frame 2: IGD found → flushes detection
        # Frame 3: shutdown
        n = 3
        self._fill_queues(ctx, n)

        detection = {
            "is_matchup": True, "username": "foe",
            "confidence": 0.88, "detected_rank": "legend",
            "timestamp": 100, "truncated": False,
        }
        pf_calls = [0]
        def process_frame(*a, **kw):
            pf_calls[0] += 1
            if pf_calls[0] >= n:
                ctx.shutdown.set()
            return detection if pf_calls[0] == 1 else None

        igd_calls = [0]
        def extract_igd(*a, **kw):
            igd_calls[0] += 1
            return 42 if igd_calls[0] == 1 else None  # found on first scan

        ctx.frame_processor.process_frame.side_effect = process_frame
        ctx.frame_processor.extract_igd.side_effect = extract_igd

        opencv.run(ctx)

        assert ctx.matchups_found == 1
        result = ctx.result_queue.get_nowait()
        assert result.get("igd") == 42

    def test_igd_timeout_flushes_without_value(self):
        """After 15 scan frames with no IGD, detection is flushed without igd."""
        from workers import opencv
        from workers.opencv import _IGD_MAX_SCAN_FRAMES

        total = 1 + _IGD_MAX_SCAN_FRAMES + 1  # matchup + scan window + shutdown frame
        ctx = make_ctx(
            nameplate_slice=[0, 0, 32, 16],
            igd_slice=[0, 16, 32, 16],
            combined_crop=[32, 32, 0, 0],
        )
        self._fill_queues(ctx, total)

        detection = {
            "is_matchup": True, "username": "foe2",
            "confidence": 0.85, "detected_rank": "bronze",
            "timestamp": 100, "truncated": False,
        }
        pf_calls = [0]
        def process_frame(*a, **kw):
            pf_calls[0] += 1
            if pf_calls[0] >= total:
                ctx.shutdown.set()
            return detection if pf_calls[0] == 1 else None

        ctx.frame_processor.process_frame.side_effect = process_frame
        ctx.frame_processor.extract_igd.return_value = None  # never finds IGD

        opencv.run(ctx)

        assert ctx.matchups_found == 1
        result = ctx.result_queue.get_nowait()
        assert result.get("igd") is None  # flushed without value

    def test_new_matchup_flushes_pending_igd(self):
        """A second matchup while IGD scan is active flushes the first."""
        from workers import opencv

        ctx = make_ctx(
            nameplate_slice=[0, 0, 32, 16],
            igd_slice=[0, 16, 32, 16],
            combined_crop=[32, 32, 0, 0],
        )
        # Frame 1: matchup A; Frame 2: matchup B (flushes A); Frame 3: shutdown
        n = 3
        self._fill_queues(ctx, n)

        detection_a = {"is_matchup": True, "username": "a", "confidence": 0.9,
                       "detected_rank": "gold", "timestamp": 100, "truncated": False}
        detection_b = {"is_matchup": True, "username": "b", "confidence": 0.85,
                       "detected_rank": "silver", "timestamp": 101, "truncated": False}

        pf_calls = [0]
        def process_frame(*a, **kw):
            pf_calls[0] += 1
            if pf_calls[0] >= n:
                ctx.shutdown.set()
            if pf_calls[0] == 1:
                return detection_a
            if pf_calls[0] == 2:
                return detection_b
            return None

        ctx.frame_processor.process_frame.side_effect = process_frame
        ctx.frame_processor.extract_igd.return_value = None

        opencv.run(ctx)

        # Both A (flushed by B) and B (flushed at shutdown) should be enqueued
        assert ctx.matchups_found == 2
