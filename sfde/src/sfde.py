#!/usr/bin/env python3
"""
SFDE Processor - Main orchestrator for VOD processing pipeline
Stream → Filter → Detect → Extract

All shared state lives on a PipelineContext (workers/context.py).
Worker thread bodies live in workers/{streamlink,ffmpeg,opencv,result}.py.
"""

import json
import logging
import os
import queue
import signal
import subprocess
import sys
import threading
import time
from typing import Any, Dict

from dotenv import load_dotenv

# skips connectivity check to the paddle OCR model hoster (models are pre-downloaded)
os.environ["PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK"] = "True"
load_dotenv(".env.local")

from frame_processor import FrameProcessor
from json_logger import JSONFormatter
from sfde_config import (
    QUALITY_RESOLUTIONS,
    compute_combined_crop,
    load_config,
    parse_sfde_profile,
)
from supabase_client import SupabaseClient
from telemetry import (
    create_span,
    extract_trace_context,
    init_telemetry,
    record_counter,
    record_histogram,
    shutdown_telemetry,
)
from workers import PipelineContext, ffmpeg, opencv, result, streamlink


class SFDEProcessor:
    """Builds a PipelineContext and runs the four worker threads."""

    def __init__(self, config: Dict[str, Any]):
        self.chunk_id = config["chunk_id"]
        self.test_mode = config.get("test_mode", False)
        self.quality = config.get("quality", "480p")
        self.old_templates = config.get("old_templates", False)
        self.video_fps = config.get("video_fps", 30)

        self.formatted_quality = (
            f"{self.quality}60" if self.video_fps == 60 else self.quality
        )

        self.config = load_config()
        self.profile = parse_sfde_profile()

        self.supabase = SupabaseClient(
            self.config, test_mode=self.test_mode, quality=self.quality
        )

        chunk_details = self.supabase.get_chunk_details(self.chunk_id)
        if not chunk_details:
            raise ValueError(f"Could not fetch details for chunk {self.chunk_id}")

        self.vod_id = chunk_details["vod_id"]
        self.start_time = chunk_details["start_seconds"]
        self.end_time = chunk_details["end_seconds"]
        self.streamer = chunk_details.get("streamer")
        self.initial_status = chunk_details.get("status")

        self.supabase.set_streamer(self.streamer)

        self._setup_logging()
        self._init_telemetry()

        # Pre-compute combined crop and subregion slices (pure fn of profile+quality)
        fw, fh = QUALITY_RESOLUTIONS.get(self.quality, (854, 480))
        combined_crop, nameplate_slice, igd_slice = compute_combined_crop(
            self.profile, fw, fh
        )

        frame_processor = FrameProcessor(
            self.config,
            quality=self.quality,
            old_templates=self.old_templates,
            profile=self.profile,
            streamer=self.streamer,
        )

        self.ctx = PipelineContext(
            chunk_id=self.chunk_id,
            vod_id=self.vod_id,
            streamer=self.streamer,
            quality=self.quality,
            formatted_quality=self.formatted_quality,
            start_time=self.start_time,
            end_time=self.end_time,
            test_mode=self.test_mode,
            config=self.config,
            profile=self.profile,
            span_attributes=self.span_attributes,
            logger=self.logger,
            combined_crop=combined_crop,
            nameplate_slice=nameplate_slice,
            igd_slice=igd_slice,
            frame_queue=queue.Queue(maxsize=self.config["processing"]["queue_size"]),
            pts_queue=queue.Queue(),
            result_queue=queue.Queue(),
            shutdown=threading.Event(),
            frame_processor=frame_processor,
            supabase=self.supabase,
        )

        signal.signal(signal.SIGTERM, self._handle_shutdown)
        signal.signal(signal.SIGINT, self._handle_shutdown)

    def _setup_logging(self):
        base = logging.getLogger("sfde")
        base.setLevel(getattr(logging, self.config["logging"]["level"]))

        formatter = JSONFormatter()
        console_handler = logging.StreamHandler(sys.stdout)
        console_handler.setFormatter(formatter)
        base.addHandler(console_handler)

        self.environment = os.getenv("ENVIRONMENT", "production")
        self.logger = logging.LoggerAdapter(
            base,
            {
                "vod_id": self.vod_id,
                "chunk_id": self.chunk_id,
                "streamer": self.streamer,
                "quality": self.formatted_quality,
            },
        )

    def _init_telemetry(self):
        telemetry_enabled = init_telemetry(
            service_name="sfde", environment=self.environment
        )

        if telemetry_enabled:
            self.logger.info("OpenTelemetry initialized successfully")
        else:
            self.logger.info(
                "OpenTelemetry disabled (OTEL_EXPORTER_OTLP_ENDPOINT not set)"
            )

        trace_parent = os.getenv("TRACEPARENT")
        if trace_parent:
            self.trace_context = extract_trace_context({"traceparent": trace_parent})
            self.logger.info(
                f"Trace context extracted from TRACEPARENT: {trace_parent[:50]}..."
            )
        else:
            self.trace_context = None

        self.span_attributes = {
            "vod.id": self.vod_id,
            "chunk.id": self.chunk_id,
            "streamer": self.streamer,
            "quality": self.formatted_quality,
            "profile.name": self.profile.get("profile_name", "default"),
            "start_seconds": self.start_time,
            "end_seconds": self.end_time,
        }

    def _handle_shutdown(self, signum, frame):
        self.logger.info(f"Received signal {signum}, initiating shutdown")
        self.ctx.shutdown.set()

    def process_vod_chunk(self) -> Dict[str, Any]:
        ctx = self.ctx
        self.logger.info(
            f"Starting VOD processing: {self.vod_id} [{self.start_time}-{self.end_time}]"
        )
        self.logger.info(
            f"Using SFDE profile: {self.profile.get('profile_name', 'unknown')}"
        )
        self.logger.info(f"Crop region: {self.profile['crop_region']}")
        if self.old_templates:
            self.logger.info(
                "Using small templates (underscore-prefixed) for older VOD processing"
            )
        if ctx.igd_slice:
            self.logger.info(
                f"IGD detection enabled. Combined crop: {ctx.combined_crop}, "
                f"nameplate slice: {ctx.nameplate_slice}, IGD slice: {ctx.igd_slice}"
            )

        processing_start_time = time.time()

        with create_span("process_chunk", attributes=self.span_attributes) as root_span:
            try:
                self.logger.info(
                    f"Cleaning up any existing detections for chunk {self.chunk_id} (status: {self.initial_status})..."
                )
                deleted_count = self.supabase.delete_chunk_detections(self.chunk_id)
                if deleted_count > 0:
                    self.logger.info(
                        f"Deleted {deleted_count} existing detections and their images for clean reprocessing"
                    )
                else:
                    self.logger.info(
                        f"No existing detections found for chunk {self.chunk_id}"
                    )

                self.supabase.update_chunk(
                    self.chunk_id, "processing", quality=self.formatted_quality
                )

                threads = [
                    threading.Thread(
                        target=streamlink.run, args=(ctx,), name="streamlink"
                    ),
                    threading.Thread(target=ffmpeg.run, args=(ctx,), name="ffmpeg"),
                    threading.Thread(target=opencv.run, args=(ctx,), name="opencv"),
                    threading.Thread(target=result.run, args=(ctx,), name="results"),
                ]

                for thread in threads:
                    thread.start()

                for thread in threads:
                    thread.join(timeout=self.config["processing"]["timeout"])

                if ctx.frames_processed > 0 and ctx.shutdown.is_set():
                    status = "completed"
                elif not ctx.shutdown.is_set():
                    status = "completed"
                else:
                    status = "interrupted"

                duration_ms = (time.time() - processing_start_time) * 1000

                self.logger.info(
                    json.dumps(
                        {
                            "event": "chunk_finished",
                            "status": status,
                            "frames_processed": ctx.frames_processed,
                            "matchups_found": ctx.matchups_found,
                            "duration_ms": round(duration_ms, 2),
                            "fps": round(
                                ctx.frames_processed / (duration_ms / 1000), 2
                            )
                            if duration_ms > 0
                            else 0,
                        }
                    )
                )
                metric_attrs = ctx.metric_attrs

                if status == "completed":
                    record_counter("chunks_completed", 1, metric_attrs)
                else:
                    record_counter("chunks_failed", 1, metric_attrs)

                record_histogram("processing_duration", duration_ms, metric_attrs)

                if duration_ms > 0:
                    fps = ctx.frames_processed / (duration_ms / 1000)
                    record_histogram("frame_processing_rate", fps, metric_attrs)

                if root_span:
                    root_span.set_attribute("frames.processed", ctx.frames_processed)
                    root_span.set_attribute("matchups.found", ctx.matchups_found)
                    root_span.set_attribute("duration.ms", duration_ms)
                    root_span.set_attribute("status", status)

                if status == "completed":
                    self.supabase.update_chunk(
                        self.chunk_id,
                        "completed",
                        frames_processed=ctx.frames_processed,
                        detections_count=ctx.matchups_found,
                        quality=self.formatted_quality,
                    )
                else:
                    self.supabase.update_chunk(
                        self.chunk_id,
                        "pending",
                        error=f"Processing interrupted after {ctx.frames_processed} frames",
                        frames_processed=ctx.frames_processed,
                        detections_count=ctx.matchups_found,
                        quality=self.formatted_quality,
                    )

                self.export_detection_summary()

                return {
                    "status": status,
                    "frames_processed": ctx.frames_processed,
                    "matchups_found": ctx.matchups_found,
                    "vod_id": self.vod_id,
                    "start_time": self.start_time,
                    "end_time": self.end_time,
                    "quality": self.quality,
                }

            except Exception as e:
                self.logger.error(f"Processing failed: {e}", exc_info=True)
                record_counter(
                    "chunks_failed",
                    1,
                    {
                        "streamer": self.streamer or "unknown",
                        "quality": self.formatted_quality,
                        "error_type": type(e).__name__,
                    },
                )
                try:
                    self.supabase.update_chunk(
                        self.chunk_id,
                        "failed",
                        error=f"Processing failed: {str(e)}",
                        quality=self.formatted_quality,
                    )
                except Exception as update_error:
                    self.logger.error(
                        f"Failed to update chunk status on error: {update_error}"
                    )
                raise
            finally:
                self.cleanup()

    def export_detection_summary(self, output_dir: str = "/app/output"):
        ctx = self.ctx
        try:
            self.logger.info(f"Exporting detection summary for chunk {self.chunk_id}")
            self.logger.info(f"Total detections tracked: {len(ctx.all_detections)}")

            summary = {
                "chunk_id": self.chunk_id,
                "vod_id": self.vod_id,
                "streamer": self.streamer,
                "start_time": self.start_time,
                "end_time": self.end_time,
                "quality": self.formatted_quality,
                "frames_processed": ctx.frames_processed,
                "matchups_found": ctx.matchups_found,
                "detections": [],
            }

            for detection in ctx.all_detections:
                summary["detections"].append(
                    {
                        "timestamp": detection["timestamp"],
                        "username": detection["username"],
                        "confidence": detection["confidence"],
                        "rank": detection["rank"],
                    }
                )

            try:
                os.makedirs(output_dir, exist_ok=True)
                self.logger.info(f"Output directory ready: {output_dir}")
            except Exception as mkdir_err:
                self.logger.error(f"Failed to create output directory: {mkdir_err}")
                raise

            output_path = os.path.join(output_dir, f"detections_{self.chunk_id}.json")
            self.logger.info(f"Writing summary to: {output_path}")

            with open(output_path, "w") as f:
                json.dump(summary, f, indent=2)

            if os.path.exists(output_path):
                file_size = os.path.getsize(output_path)
                self.logger.info(
                    f"Successfully exported detection summary ({file_size} bytes)"
                )
            else:
                self.logger.error(f"File was not created: {output_path}")

        except Exception as e:
            self.logger.error(f"Failed to export detection summary: {e}", exc_info=True)

    def cleanup(self):
        ctx = self.ctx
        self.logger.info("Starting cleanup")

        ctx.shutdown.set()

        for proc_name, proc in [
            ("ffmpeg", ctx.ffmpeg_proc),
            ("streamlink", ctx.streamlink_proc),
        ]:
            if proc and proc.poll() is None:
                self.logger.info(f"Terminating {proc_name}")
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.logger.warning(f"Force killing {proc_name}")
                    proc.kill()

        while not ctx.frame_queue.empty():
            try:
                ctx.frame_queue.get_nowait()
            except queue.Empty:
                break

        self.logger.info("Flushing telemetry...")
        shutdown_telemetry()

        self.logger.info("Cleanup completed")


def main():
    config = {
        "chunk_id": os.getenv("CHUNK_ID", sys.argv[1] if len(sys.argv) > 1 else None),
        "test_mode": os.getenv("TEST_MODE", "false").lower() == "true",
        "quality": os.getenv("QUALITY", "480p"),
        "old_templates": os.getenv("OLD_TEMPLATES", "false").lower() == "true",
        "video_fps": int(os.getenv("VIDEO_FPS", "30")),
    }

    if not config["chunk_id"]:
        print("Usage: sfde.py <chunk_id>")
        print("Or set CHUNK_ID environment variable")
        print(
            "Optional: TEST_MODE=true/false, QUALITY=480p (or 480p,360p,1080p60), OLD_TEMPLATES=true/false"
        )
        sys.exit(1)

    try:
        processor = SFDEProcessor(config)
        result_dict = processor.process_vod_chunk()
        sys.exit(0 if result_dict["status"] == "completed" else 1)
    except Exception as e:
        print(f"Failed to process chunk: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
