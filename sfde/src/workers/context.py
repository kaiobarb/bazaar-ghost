"""Shared state passed to every pipeline worker."""

import logging
import queue
import subprocess
import threading
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

from frame_processor import FrameProcessor
from supabase_client import SupabaseClient


@dataclass
class PipelineContext:
    """All state shared between SFDE worker threads.

    Immutable-ish config lives at the top; mutable cross-thread state
    (process handles, counters, batches) lives at the bottom with defaults.
    Build one of these with mocks to unit-test a worker in isolation.
    """

    # --- Chunk identity / config (set once) ---
    chunk_id: str
    vod_id: str
    streamer: Optional[str]
    quality: str
    formatted_quality: str
    start_time: int
    end_time: int
    test_mode: bool
    config: Dict[str, Any]
    profile: Dict[str, Any]
    span_attributes: Dict[str, Any]
    logger: logging.LoggerAdapter

    # --- Crop geometry (set once before threads start) ---
    combined_crop: List[int]
    nameplate_slice: Optional[List[int]]
    igd_slice: Optional[List[int]]

    # --- Queues / sync ---
    frame_queue: queue.Queue
    pts_queue: queue.Queue
    result_queue: queue.Queue
    shutdown: threading.Event

    # --- Injected collaborators ---
    frame_processor: FrameProcessor
    supabase: SupabaseClient

    # --- Mutable cross-worker state ---
    streamlink_proc: Optional[subprocess.Popen] = None
    ffmpeg_proc: Optional[subprocess.Popen] = None
    frames_processed: int = 0
    matchups_found: int = 0
    result_batch: List[Dict[str, Any]] = field(default_factory=list)
    all_detections: List[Dict[str, Any]] = field(default_factory=list)

    @property
    def metric_attrs(self) -> Dict[str, str]:
        return {
            "streamer": self.streamer or "unknown",
            "quality": self.formatted_quality,
        }
