"""Streamlink worker: pipe a Twitch VOD segment to stdout for FFmpeg."""

import subprocess
import time

from telemetry import create_span, record_counter
from workers.context import PipelineContext

_VALID_QUALITIES = {
    "360p",
    "360p60",
    "480p",
    "480p60",
    "720p",
    "720p60",
    "1080p",
    "1080p60",
    "worst",
    "best",
}


def run(ctx: PipelineContext) -> None:
    metric_attrs = ctx.metric_attrs

    with create_span("streamlink_stream", attributes=ctx.span_attributes):
        try:
            if ctx.test_mode:
                ctx.logger.info("Test mode enabled, skipping streamlink")
                return

            duration = ctx.end_time - ctx.start_time
            quality_stream = ctx.quality if ctx.quality in _VALID_QUALITIES else "480p"

            cmd = [
                "streamlink",
                "--stream-segment-threads",
                "1",
                "--hls-segment-stream-data",
                "--hls-start-offset",
                f"{ctx.start_time // 3600}:{(ctx.start_time % 3600) // 60:02d}:{ctx.start_time % 60:02d}",
                "--stream-segmented-duration",
                str(duration),
                f"https://twitch.tv/videos/{ctx.vod_id}",
                quality_stream + ",360p60,480p60,720p60,1080p60",
                "-O",
            ]

            ctx.logger.info(f"Starting streamlink: {' '.join(cmd)}")

            ctx.streamlink_proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=65536
            )

            ctx.logger.info("Streamlink process started, piping to FFmpeg...")
            while not ctx.shutdown.is_set():
                if ctx.streamlink_proc.poll() is not None:
                    stderr = ctx.streamlink_proc.stderr.read().decode(
                        "utf-8", errors="ignore"
                    )
                    if ctx.streamlink_proc.returncode != 0:
                        ctx.logger.error(
                            f"Streamlink failed with code {ctx.streamlink_proc.returncode}: {stderr}"
                        )
                        ctx.shutdown.set()
                        record_counter(
                            "errors",
                            1,
                            {
                                **metric_attrs,
                                "component": "streamlink",
                                "error_type": "exit_code",
                            },
                        )
                    else:
                        ctx.logger.info("Streamlink completed successfully.")
                    break
                time.sleep(1)

        except Exception as e:
            ctx.logger.error(f"Streamlink worker failed: {e}")
            record_counter(
                "errors",
                1,
                {
                    **metric_attrs,
                    "component": "streamlink",
                    "error_type": type(e).__name__,
                },
            )
            ctx.shutdown.set()
