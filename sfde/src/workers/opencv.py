"""OpenCV worker: consume JPEG frames, run detection, emit results.

Pulls from `ctx.frame_queue` / `ctx.pts_queue`, runs
`ctx.frame_processor.process_frame()`, optionally runs the IGD
(in-game-day) scan state machine, and pushes detections to
`ctx.result_queue`.
"""

import json
import queue
from typing import Any, Dict

from image_utils import decode_jpeg, encode_jpeg, slice_subregion
from telemetry import record_counter, record_gauge, record_histogram
from workers.context import PipelineContext

_IGD_MAX_SCAN_FRAMES = 15  # ~30 seconds at 0.5 fps


def enqueue_detection(
    ctx: PipelineContext, result: Dict[str, Any], metric_attrs: Dict[str, str]
) -> None:
    """Push a matchup detection to the result queue and record metrics."""
    ctx.result_queue.put(result)
    ctx.matchups_found += 1

    detection_json = json.dumps(
        {
            "event": "matchup_detected",
            "timestamp_seconds": result.get("timestamp"),
            "username": result.get("username"),
            "ocr_confidence": result.get("confidence"),
            "emblem_rank": result.get("detected_rank"),
            "truncated": result.get("truncated", False),
            "igd": result.get("igd"),
        }
    )
    if result.get("igd") is not None:
        ctx.logger.info(f"\033[32m{detection_json}\033[0m")
    else:
        ctx.logger.info(f"\033[33m{detection_json}\033[0m")

    record_counter("matchups_detected", 1, metric_attrs)
    if result.get("confidence"):
        record_histogram("ocr_confidence", result["confidence"], metric_attrs)


def run(ctx: PipelineContext) -> None:
    ctx.logger.info("OpenCV worker starting...")
    metric_attrs = ctx.metric_attrs

    igd_enabled = ctx.igd_slice is not None
    igd_scan_active = False
    igd_frames_scanned = 0
    pending_detection: Dict[str, Any] | None = None

    if igd_enabled:
        ctx.logger.info(
            f"\033[36mIGD detection enabled, will scan up to {_IGD_MAX_SCAN_FRAMES} frames after each username detection\033[0m"
        )

    try:
        while not ctx.shutdown.is_set():
            try:
                frame_data = ctx.frame_queue.get(timeout=1)
                record_gauge("queue_depth", -1, metric_attrs)

                try:
                    pts_time = ctx.pts_queue.get(timeout=5)
                    timestamp = ctx.start_time + int(pts_time)
                except queue.Empty:
                    sampling_rate = ctx.config["processing"]["frame_rate"]
                    seconds_per_sampled_frame = (
                        1 / sampling_rate if sampling_rate > 0 else 0
                    )
                    timestamp = ctx.start_time + int(
                        ctx.frames_processed * seconds_per_sampled_frame
                    )
                    ctx.logger.warning(
                        f"PTS unavailable for frame {ctx.frames_processed}, using frame count fallback"
                    )

                if ctx.nameplate_slice is not None:
                    full_frame = decode_jpeg(frame_data)
                    if full_frame is None:
                        ctx.frames_processed += 1
                        continue
                    nameplate_frame = slice_subregion(full_frame, ctx.nameplate_slice)
                    nameplate_data = encode_jpeg(nameplate_frame)
                else:
                    full_frame = None
                    nameplate_data = frame_data

                result = ctx.frame_processor.process_frame(
                    nameplate_data, timestamp, ctx.vod_id, ctx.chunk_id
                )

                ctx.frames_processed += 1
                record_counter("frames_processed", 1, metric_attrs)

                # --- IGD scan on current frame (if active) ---
                if igd_scan_active and full_frame is not None:
                    igd_crop = slice_subregion(full_frame, ctx.igd_slice)
                    igd_value = ctx.frame_processor.extract_igd(igd_crop)
                    igd_frames_scanned += 1

                    if igd_value is not None:
                        pending_detection["igd"] = igd_value
                        ctx.logger.info(
                            f"\033[32mIGD detected: day {igd_value} after {igd_frames_scanned} frames for {pending_detection.get('username')}\033[0m"
                        )
                        record_counter("igd_detected", 1, metric_attrs)
                        enqueue_detection(ctx, pending_detection, metric_attrs)
                        pending_detection = None
                        igd_scan_active = False
                    elif igd_frames_scanned >= _IGD_MAX_SCAN_FRAMES:
                        ctx.logger.warning(
                            f"\033[33mIGD scan timed out after {igd_frames_scanned} frames for {pending_detection.get('username')}\033[0m"
                        )
                        record_counter("igd_timeout", 1, metric_attrs)
                        enqueue_detection(ctx, pending_detection, metric_attrs)
                        pending_detection = None
                        igd_scan_active = False

                # --- Handle new matchup detection ---
                if result and result.get("is_matchup"):
                    if igd_enabled:
                        if igd_scan_active and pending_detection is not None:
                            ctx.logger.warning(
                                f"New matchup detected while IGD scan active, flushing pending detection for {pending_detection.get('username')}"
                            )
                            enqueue_detection(ctx, pending_detection, metric_attrs)

                        pending_detection = result
                        igd_scan_active = True
                        igd_frames_scanned = 0
                    else:
                        enqueue_detection(ctx, result, metric_attrs)

            except queue.Empty:
                continue
            except Exception as e:
                ctx.logger.error(f"Frame processing error: {e}")

        if igd_scan_active and pending_detection is not None:
            ctx.logger.info(
                f"Shutdown: flushing pending IGD detection for {pending_detection.get('username')}"
            )
            enqueue_detection(ctx, pending_detection, metric_attrs)

    except Exception as e:
        ctx.logger.error(f"OpenCV worker failed: {e}")
        ctx.shutdown.set()
