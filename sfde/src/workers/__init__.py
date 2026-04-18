"""SFDE pipeline workers.

Each worker is a `run(ctx: PipelineContext)` function intended to be the
target of a `threading.Thread`. All shared state flows through `ctx` so
workers can be unit-tested with a hand-built context and mock queues.
"""

from workers.context import PipelineContext
from workers import streamlink, ffmpeg, opencv, result

__all__ = ["PipelineContext", "streamlink", "ffmpeg", "opencv", "result"]
