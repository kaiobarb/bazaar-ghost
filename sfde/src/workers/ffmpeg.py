"""FFmpeg worker: decode frames from streamlink (or test file) into JPEGs.

Reads the combined crop from `ctx.combined_crop`, emits JPEG bytes to
`ctx.frame_queue`, and emits PTS timestamps (seconds from stream start)
to `ctx.pts_queue` via FFmpeg's showinfo filter on stderr.
"""

import os
import queue
import re
import subprocess
import threading
import time

from sfde_config import QUALITY_CONFIGS, QUALITY_RESOLUTIONS
from telemetry import create_span, record_counter, record_gauge
from workers.context import PipelineContext

_PTS_RE = re.compile(r"pts_time:([\d.]+)\s")


def _resolve_test_input(ctx: PipelineContext) -> tuple[str, tuple[int, int]] | None:
    """Locate the test-mode video file for this chunk's quality."""
    quality_config = QUALITY_CONFIGS.get(ctx.quality, QUALITY_CONFIGS["480p"])
    test_data_dir = ctx.config.get("test_mode", {}).get("data_directory", "test_data")
    video_filename = quality_config["file_suffix"]

    ctx.logger.info(
        f"Test mode enabled - using video file: {video_filename} for quality: {ctx.quality}"
    )

    docker_test_path = f"/app/{test_data_dir}"
    if os.path.exists(docker_test_path):
        input_file = os.path.join(docker_test_path, ctx.vod_id, video_filename)
        ctx.logger.info(
            f"Running in Docker container - test data path: {docker_test_path}"
        )
    else:
        input_file = os.path.join(
            os.path.dirname(__file__),
            "..",
            "..",
            "..",
            test_data_dir,
            ctx.vod_id,
            video_filename,
        )
        ctx.logger.info(f"Running locally - test data path: {test_data_dir}")

    if not os.path.exists(input_file):
        ctx.logger.error(f"Test file not found: {input_file}")
        ctx.logger.error(
            f"Expected video file '{video_filename}' in directory: {os.path.dirname(input_file)}"
        )
        return None

    ctx.logger.info(f"Test video file located: {input_file}")
    ctx.logger.info(
        f"Video resolution for processing: {quality_config['resolution'][0]}x{quality_config['resolution'][1]}"
    )
    return input_file, quality_config["resolution"]


def _build_ffmpeg_cmd(
    ctx: PipelineContext, input_file: str | None, vf_chain: str
) -> list[str]:
    if ctx.test_mode:
        cmd = [
            "ffmpeg",
            "-ss",
            str(ctx.start_time),
            "-i",
            input_file,
            "-t",
            str(ctx.end_time - ctx.start_time),
            "-vf",
            vf_chain,
            "-f",
            "image2pipe",
            "-vcodec",
            "mjpeg",
            "-loglevel",
            "info",
            "pipe:1",
        ]
    else:
        cmd = [
            "ffmpeg",
            "-i",
            "pipe:0",
            "-vf",
            vf_chain,
            "-f",
            "image2pipe",
            "-vcodec",
            "mjpeg",
            "-loglevel",
            "info",
            "pipe:1",
        ]

    if ctx.config["ffmpeg"]["keyframes_only"] and not ctx.test_mode:
        cmd.insert(1, "-skip_frame")
        cmd.insert(2, "nokey")

    return cmd


def run(ctx: PipelineContext) -> None:
    metric_attrs = ctx.metric_attrs

    with create_span("ffmpeg_decode", attributes=ctx.span_attributes) as span:
        try:
            input_file: str | None = None
            if ctx.test_mode:
                resolved = _resolve_test_input(ctx)
                if resolved is None:
                    ctx.shutdown.set()
                    return
                input_file, (frame_width, frame_height) = resolved
            else:
                time.sleep(2)
                if not ctx.streamlink_proc or ctx.streamlink_proc.poll() is not None:
                    ctx.logger.error(
                        "Streamlink not running when FFmpeg tried to start"
                    )
                    return
                ctx.logger.info("Streamlink confirmed running, starting FFmpeg...")
                frame_width, frame_height = QUALITY_RESOLUTIONS.get(
                    ctx.quality, (854, 480)
                )

            vf_filters = [f"fps={ctx.config['processing']['frame_rate']}"]
            w, h, x, y = ctx.combined_crop
            vf_filters.append(f"crop={w}:{h}:{x}:{y}")
            ctx.logger.info(
                f"Applied crop: [x={x}, y={y}, w={w}, h={h}] for {frame_width}x{frame_height} video"
            )
            ctx.logger.info(f"Cropped frame dimensions will be: {w}x{h} pixels")
            vf_filters.append("showinfo")
            vf_chain = ",".join(vf_filters)

            ffmpeg_cmd = _build_ffmpeg_cmd(ctx, input_file, vf_chain)
            ctx.logger.info("Starting FFmpeg pipeline")

            if ctx.test_mode:
                ctx.ffmpeg_proc = subprocess.Popen(
                    ffmpeg_cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    bufsize=65536,
                )
            else:
                ctx.ffmpeg_proc = subprocess.Popen(
                    ffmpeg_cmd,
                    stdin=ctx.streamlink_proc.stdout,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    bufsize=65536,
                )

            time.sleep(0.5)
            if ctx.ffmpeg_proc.poll() is not None:
                stderr = ctx.ffmpeg_proc.stderr.read().decode("utf-8", errors="ignore")
                ctx.logger.error(
                    f"FFmpeg failed to start. Exit code: {ctx.ffmpeg_proc.returncode}, stderr: {stderr}"
                )
                record_counter(
                    "errors",
                    1,
                    {
                        **metric_attrs,
                        "component": "ffmpeg",
                        "error_type": "start_failed",
                    },
                )
                return
            ctx.logger.info("FFmpeg process started successfully")

            def _read_ffmpeg_stderr():
                try:
                    for raw_line in ctx.ffmpeg_proc.stderr:
                        line = raw_line.decode("utf-8", errors="ignore").rstrip()
                        m = _PTS_RE.search(line)
                        if m:
                            ctx.pts_queue.put(float(m.group(1)))
                        elif line and "showinfo" not in line:
                            ctx.logger.debug(f"FFmpeg: {line}")
                except Exception as e:
                    ctx.logger.warning(f"FFmpeg stderr reader error: {e}")

            stderr_thread = threading.Thread(
                target=_read_ffmpeg_stderr, name="ffmpeg-stderr", daemon=True
            )
            stderr_thread.start()

            frame_buffer = b""
            frames_extracted = 0
            bytes_read = 0
            ctx.logger.info("Starting to read frames from FFmpeg...")

            while not ctx.shutdown.is_set():
                chunk = ctx.ffmpeg_proc.stdout.read(4096)
                if not chunk:
                    ctx.logger.info(
                        f"FFmpeg stream ended. Total bytes read: {bytes_read}, frames extracted: {frames_extracted}"
                    )
                    break

                bytes_read += len(chunk)
                frame_buffer += chunk

                while True:
                    start = frame_buffer.find(b"\xff\xd8")
                    if start == -1:
                        break
                    end = frame_buffer.find(b"\xff\xd9", start)
                    if end == -1:
                        break

                    frame_data = frame_buffer[start : end + 2]
                    frame_buffer = frame_buffer[end + 2 :]
                    frames_extracted += 1
                    try:
                        ctx.frame_queue.put(frame_data, timeout=0.1)
                        record_gauge("queue_depth", 1, metric_attrs)
                    except queue.Full:
                        try:
                            ctx.pts_queue.get(timeout=1)
                        except queue.Empty:
                            pass
                        ctx.logger.warning("Frame queue full, dropping frame")
                        record_counter(
                            "frames_skipped",
                            1,
                            {**metric_attrs, "reason": "queue_full"},
                        )
                        record_counter("queue_overflow", 1, metric_attrs)

            stderr_thread.join(timeout=5)

            ctx.logger.info(
                f"FFmpeg worker finished. Final stats: {bytes_read} bytes read, {frames_extracted} frames extracted"
            )

            if not ctx.shutdown.is_set():
                ctx.logger.info("FFmpeg completed successfully, signaling shutdown")
                ctx.shutdown.set()

            if span:
                span.set_attribute("frames.extracted", frames_extracted)
                span.set_attribute("bytes.read", bytes_read)

        except Exception as e:
            ctx.logger.error(f"FFmpeg worker failed: {e}")
            record_counter(
                "errors",
                1,
                {
                    **metric_attrs,
                    "component": "ffmpeg",
                    "error_type": type(e).__name__,
                },
            )
            ctx.shutdown.set()
