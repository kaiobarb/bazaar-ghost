#!/usr/bin/env python3
"""
SFDE Processor - Main orchestrator for VOD processing pipeline
Stream → Filter → Detect → Extract
"""

import os
import sys
import re
import signal
import queue
import threading
import subprocess
import time
import json
import logging
import math
from datetime import datetime, timedelta
from typing import Optional, Dict, Any, Tuple, List
import yaml
import cv2
import numpy as np
from dotenv import load_dotenv

# skips connectivity check to the paddle OCR model hoster (models are pre-downloaded)
os.environ["PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK"] = "True"
# Load environment variables
load_dotenv(".env.local")

# Import worker modules
from frame_processor import FrameProcessor
from supabase_client import SupabaseClient
from json_logger import JSONFormatter
from telemetry import (
    init_telemetry,
    create_span,
    record_counter,
    record_histogram,
    record_gauge,
    extract_trace_context,
    set_span_attribute,
    add_span_event,
    shutdown_telemetry,
)

# Quality configuration mapping for test mode
QUALITY_CONFIGS = {
    "360p": {"resolution": (640, 360), "file_suffix": "360p.mp4"},
    "480p": {"resolution": (854, 480), "file_suffix": "480p.mp4"},
    "1080p": {"resolution": (1920, 1080), "file_suffix": "1080p.mp4"},
    "1080p60": {"resolution": (1920, 1080), "file_suffix": "1080p.mp4"},
}


class SFDEProcessor:
    """Main SFDE processor orchestrator"""

    def __init__(self, config: Dict[str, Any]):
        """Initialize SFDE processor with configuration"""
        self.chunk_id = config["chunk_id"]
        self.test_mode = config.get("test_mode", False)
        self.quality = config.get("quality", "480p")
        self.old_templates = config.get("old_templates", False)
        self.video_fps = config.get("video_fps", 30)  # Actual video FPS

        self.formatted_quality = (
            f"{self.quality}60" if self.video_fps == 60 else self.quality
        )

        # Load configuration
        self.config = self._load_config()

        # Parse SFDE profile from environment variable
        self.profile = self._parse_sfde_profile()

        # Initialize Supabase client first to fetch chunk details
        self.supabase = SupabaseClient(
            self.config, test_mode=self.test_mode, quality=self.quality
        )

        # Fetch chunk details from database
        chunk_details = self.supabase.get_chunk_details(self.chunk_id)
        if not chunk_details:
            raise ValueError(f"Could not fetch details for chunk {self.chunk_id}")

        # Set processing parameters from chunk details
        self.vod_id = chunk_details["vod_id"]
        self.start_time = chunk_details["start_seconds"]
        self.end_time = chunk_details["end_seconds"]
        self.streamer = chunk_details.get("streamer")
        self.initial_status = chunk_details.get("status")  # Store for later use

        # Set streamer on supabase client for metric attribution
        self.supabase.set_streamer(self.streamer)

        # Initialize components
        self.frame_queue = queue.Queue(maxsize=self.config["processing"]["queue_size"])
        self.pts_queue = queue.Queue()  # PTS timestamps from FFmpeg showinfo filter
        self.result_queue = queue.Queue()
        self.shutdown = threading.Event()

        # Process state
        self.streamlink_proc: Optional[subprocess.Popen] = None
        self.ffmpeg_proc: Optional[subprocess.Popen] = None
        self.frames_processed = 0
        self.matchups_found = 0
        self.result_batch = []  # Current batch being accumulated
        self.all_detections = []  # All detections for summary export

        # IGD subregion slices (computed by ffmpeg_worker, read by opencv_worker).
        # Initialize here so opencv_worker can safely read them before ffmpeg_worker sets them.
        self._nameplate_slice: Optional[List[int]] = None
        self._igd_slice: Optional[List[int]] = None

        # Initialize frame processor with quality information and template selection
        self.frame_processor = FrameProcessor(
            self.config,
            quality=self.quality,
            old_templates=self.old_templates,
            profile=self.profile,
            streamer=self.streamer,
        )

        # Setup logging
        self._setup_logging()

        # Initialize OpenTelemetry
        self._init_telemetry()

        # Register signal handlers
        signal.signal(signal.SIGTERM, self._handle_shutdown)
        signal.signal(signal.SIGINT, self._handle_shutdown)

    def percent_to_pixels(
        self, crop_percent: List[float], frame_width: int, frame_height: int
    ) -> List[int]:
        """Convert percentage-based crop to pixel coordinates with proper rounding

        Args:
            crop_percent: [x, y, width, height] as fractions (0.0-1.0)
            frame_width: Width of the frame in pixels
            frame_height: Height of the frame in pixels

        Returns:
            [width, height, x, y] in pixels for FFmpeg crop filter
        """
        x_percent, y_percent, w_percent, h_percent = crop_percent

        # Calculate pixel values with proper rounding
        x = math.floor(x_percent * frame_width)  # Round left down
        y = math.floor(y_percent * frame_height)  # Round top down
        w = math.ceil(w_percent * frame_width)  # Round width up
        h = math.ceil(h_percent * frame_height)  # Round height up

        # Ensure values don't exceed frame bounds
        x = min(x, frame_width - 1)
        y = min(y, frame_height - 1)
        w = min(w, frame_width - x)
        h = min(h, frame_height - y)

        # Return in FFmpeg format [width, height, x, y]
        return [w, h, x, y]

    def _load_config(self) -> Dict[str, Any]:
        """Load configuration from YAML file"""
        config_path = os.path.join(os.path.dirname(__file__), "..", "config.yaml")
        with open(config_path, "r") as f:
            config = yaml.safe_load(f)

        # Override with environment variables if present
        if os.getenv("SUPABASE_URL"):
            config["supabase"]["url"] = os.getenv("SUPABASE_URL")
        if os.getenv("SUPABASE_SECRET_KEY"):
            config["supabase"]["secret_key"] = os.getenv("SUPABASE_SECRET_KEY")

        return config

    def _parse_sfde_profile(self) -> Dict[str, Any]:
        """Parse SFDE profile from environment variable

        Returns:
            Dictionary containing profile data with crop_region, scale, etc.

        Raises:
            ValueError: If SFDE_PROFILE is missing or invalid JSON
        """
        sfde_profile_json = os.getenv("SFDE_PROFILE")

        if not sfde_profile_json:
            raise ValueError(
                "SFDE_PROFILE environment variable is required. "
                "This should be provided by the GitHub Actions workflow as a JSON string."
            )

        try:
            profile = json.loads(sfde_profile_json)
        except json.JSONDecodeError as e:
            raise ValueError(f"SFDE_PROFILE is not valid JSON: {e}")

        # Validate required fields
        if "crop_region" not in profile:
            raise ValueError("SFDE_PROFILE missing required field: crop_region")

        if (
            not isinstance(profile["crop_region"], list)
            or len(profile["crop_region"]) != 4
        ):
            raise ValueError(
                f"SFDE_PROFILE crop_region must be array of 4 numbers, got: {profile.get('crop_region')}"
            )

        # Parse igd_crop_region if present (optional)
        igd_crop = profile.get("igd_crop_region")
        if igd_crop is not None:
            if not isinstance(igd_crop, list) or len(igd_crop) != 4:
                raise ValueError(
                    f"SFDE_PROFILE igd_crop_region must be array of 4 numbers, got: {igd_crop}"
                )
            # Convert to floats (may come as strings from JSON/DB)
            profile["igd_crop_region"] = [float(v) for v in igd_crop]

        return profile

    def _compute_combined_crop(
        self, frame_width: int, frame_height: int
    ) -> Tuple[List[int], Optional[List[int]], Optional[List[int]]]:
        """Compute a combined FFmpeg crop that encompasses both nameplate and IGD regions.

        When igd_crop_region is present in the profile, computes a bounding box that
        covers both crop regions. Returns the combined crop for FFmpeg plus local offsets
        for slicing each subregion from the decoded frame.

        Args:
            frame_width: Width of the source frame in pixels.
            frame_height: Height of the source frame in pixels.

        Returns:
            Tuple of:
                - combined_crop: [w, h, x, y] in pixels for the FFmpeg crop filter
                - nameplate_slice: [x_offset, y_offset, w, h] local offsets within combined crop, or None if no IGD
                - igd_slice: [x_offset, y_offset, w, h] local offsets within combined crop, or None if no IGD
        """
        nameplate_pixels = self.percent_to_pixels(
            self.profile["crop_region"], frame_width, frame_height
        )
        np_w, np_h, np_x, np_y = nameplate_pixels

        igd_crop = self.profile.get("igd_crop_region")
        if not igd_crop:
            # No IGD — return nameplate crop only, no subregion slicing needed
            return nameplate_pixels, None, None

        igd_pixels = self.percent_to_pixels(igd_crop, frame_width, frame_height)
        igd_w, igd_h, igd_x, igd_y = igd_pixels

        # Compute bounding box that encompasses both regions
        bbox_x = min(np_x, igd_x)
        bbox_y = min(np_y, igd_y)
        bbox_right = max(np_x + np_w, igd_x + igd_w)
        bbox_bottom = max(np_y + np_h, igd_y + igd_h)
        bbox_w = bbox_right - bbox_x
        bbox_h = bbox_bottom - bbox_y

        # Clamp to frame bounds
        bbox_w = min(bbox_w, frame_width - bbox_x)
        bbox_h = min(bbox_h, frame_height - bbox_y)

        combined_crop = [bbox_w, bbox_h, bbox_x, bbox_y]

        # Compute local offsets within the combined crop
        nameplate_slice = [np_x - bbox_x, np_y - bbox_y, np_w, np_h]
        igd_slice = [igd_x - bbox_x, igd_y - bbox_y, igd_w, igd_h]

        return combined_crop, nameplate_slice, igd_slice

    def _setup_logging(self):
        """Setup structured JSON logging"""
        self.logger = logging.getLogger("sfde")
        self.logger.setLevel(getattr(logging, self.config["logging"]["level"]))

        # JSON formatter
        formatter = JSONFormatter()

        # Console handler (stdout for docker logs / GitHub Actions)
        console_handler = logging.StreamHandler(sys.stdout)
        console_handler.setFormatter(formatter)
        self.logger.addHandler(console_handler)

        # Add context to all logs for Grafana/Loki queryability
        # Note: environment comes from OpenTelemetry resource attributes, not here
        self.environment = os.getenv("ENVIRONMENT", "production")
        self.logger = logging.LoggerAdapter(
            self.logger,
            {
                "vod_id": self.vod_id,
                "chunk_id": self.chunk_id,
                "streamer": self.streamer,
                "quality": self.formatted_quality,
            },
        )

    def _init_telemetry(self):
        """Initialize OpenTelemetry for distributed tracing and metrics"""
        # Initialize telemetry (will be no-op if OTEL_EXPORTER_OTLP_ENDPOINT not set)
        telemetry_enabled = init_telemetry(
            service_name="sfde", environment=self.environment
        )

        if telemetry_enabled:
            self.logger.info("OpenTelemetry initialized successfully")
        else:
            self.logger.info(
                "OpenTelemetry disabled (OTEL_EXPORTER_OTLP_ENDPOINT not set)"
            )

        # Extract trace context if provided (propagated from GitHub Actions via process-vod edge function)
        trace_parent = os.getenv("TRACEPARENT")
        if trace_parent:
            self.trace_context = extract_trace_context({"traceparent": trace_parent})
            self.logger.info(
                f"Trace context extracted from TRACEPARENT: {trace_parent[:50]}..."
            )
        else:
            self.trace_context = None

        # Common span attributes for this chunk
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
        """Handle shutdown signals gracefully"""
        self.logger.info(f"Received signal {signum}, initiating shutdown")
        self.shutdown.set()

    def process_vod_chunk(self) -> Dict[str, Any]:
        """Main processing entry point"""
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

        # Track processing time for metrics
        processing_start_time = time.time()

        # Wrap entire processing in a root span
        with create_span("process_chunk", attributes=self.span_attributes) as root_span:
            try:
                # Always clean up existing detections and images when rerunning a chunk
                # This ensures clean slate whether chunk was completed, failed, or partially processed
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

                # Update chunk status to processing with quality info
                self.supabase.update_chunk(
                    self.chunk_id, "processing", quality=self.formatted_quality
                )

                # Pre-compute combined crop and subregion slices so both
                # ffmpeg_worker and opencv_worker have them before they start.
                quality_resolutions = {
                    "360p": (640, 360),
                    "480p": (854, 480),
                    "720p": (1280, 720),
                    "1080p": (1920, 1080),
                    "1080p60": (1920, 1080),
                }
                pre_fw, pre_fh = quality_resolutions.get(self.quality, (854, 480))
                combined_crop, nameplate_slice, igd_slice = self._compute_combined_crop(
                    pre_fw, pre_fh
                )
                self._combined_crop = combined_crop
                self._nameplate_slice = nameplate_slice
                self._igd_slice = igd_slice

                if igd_slice:
                    self.logger.info(
                        f"IGD detection enabled. Combined crop: {combined_crop}, "
                        f"nameplate slice: {nameplate_slice}, IGD slice: {igd_slice}"
                    )

                # Start worker threads
                threads = [
                    threading.Thread(target=self.streamlink_worker, name="streamlink"),
                    threading.Thread(target=self.ffmpeg_worker, name="ffmpeg"),
                    threading.Thread(target=self.opencv_worker, name="opencv"),
                    threading.Thread(target=self.result_worker, name="results"),
                ]

                for thread in threads:
                    thread.start()

                # Wait for completion or shutdown
                for thread in threads:
                    thread.join(timeout=self.config["processing"]["timeout"])

                # Final status update - check if we completed successfully
                # If shutdown was set but we processed frames successfully, it's completion
                if self.frames_processed > 0 and self.shutdown.is_set():
                    status = "completed"
                elif not self.shutdown.is_set():
                    status = "completed"
                else:
                    status = "interrupted"

                # Record telemetry metrics
                duration_ms = (time.time() - processing_start_time) * 1000

                # Structured JSON event for chunk completion
                # Log as JSON so Loki can parse with | json
                self.logger.info(
                    json.dumps(
                        {
                            "event": "chunk_finished",
                            "status": status,
                            "frames_processed": self.frames_processed,
                            "matchups_found": self.matchups_found,
                            "duration_ms": round(duration_ms, 2),
                            "fps": round(
                                self.frames_processed / (duration_ms / 1000), 2
                            )
                            if duration_ms > 0
                            else 0,
                        }
                    )
                )
                metric_attrs = {
                    "streamer": self.streamer or "unknown",
                    "quality": self.formatted_quality,
                }

                if status == "completed":
                    record_counter("chunks_completed", 1, metric_attrs)
                else:
                    record_counter("chunks_failed", 1, metric_attrs)

                record_histogram("processing_duration", duration_ms, metric_attrs)

                if duration_ms > 0:
                    fps = self.frames_processed / (duration_ms / 1000)
                    record_histogram("frame_processing_rate", fps, metric_attrs)

                # Set span attributes with final results
                if root_span:
                    root_span.set_attribute("frames.processed", self.frames_processed)
                    root_span.set_attribute("matchups.found", self.matchups_found)
                    root_span.set_attribute("duration.ms", duration_ms)
                    root_span.set_attribute("status", status)

                # Update chunk with final status
                if status == "completed":
                    self.supabase.update_chunk(
                        self.chunk_id,
                        "completed",
                        frames_processed=self.frames_processed,
                        detections_count=self.matchups_found,
                        quality=self.formatted_quality,
                    )
                else:
                    # Set back to pending if interrupted
                    self.supabase.update_chunk(
                        self.chunk_id,
                        "pending",
                        error=f"Processing interrupted after {self.frames_processed} frames",
                        frames_processed=self.frames_processed,
                        detections_count=self.matchups_found,
                        quality=self.formatted_quality,
                    )

                # Export detection summary for GitHub Actions workflow
                self.export_detection_summary()

                return {
                    "status": status,
                    "frames_processed": self.frames_processed,
                    "matchups_found": self.matchups_found,
                    "vod_id": self.vod_id,
                    "start_time": self.start_time,
                    "end_time": self.end_time,
                    "quality": self.quality,
                }

            except Exception as e:
                self.logger.error(f"Processing failed: {e}", exc_info=True)
                # Record failure metric
                record_counter(
                    "chunks_failed",
                    1,
                    {
                        "streamer": self.streamer or "unknown",
                        "quality": self.formatted_quality,
                        "error_type": type(e).__name__,
                    },
                )
                # Update chunk status to failed with error message
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

    def streamlink_worker(self):
        """Worker to run streamlink and pipe HLS stream to FFmpeg"""
        metric_attrs = {
            "streamer": self.streamer or "unknown",
            "quality": self.formatted_quality,
        }

        # Span for tracing - runs in parallel with ffmpeg/opencv workers
        with create_span("streamlink_stream", attributes=self.span_attributes) as span:
            try:
                # Skip streamlink in test mode - FFmpeg will read directly from file
                if self.test_mode:
                    self.logger.info("Test mode enabled, skipping streamlink")
                    return

                # Calculate duration
                duration = self.end_time - self.start_time

                # Build streamlink command with quality preference
                quality_stream = (
                    self.quality
                    if self.quality
                    in [
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
                    ]
                    else "480p"
                )
                cmd = [
                    "streamlink",
                    "--stream-segment-threads",
                    "1",  # Consistent delivery
                    "--hls-segment-stream-data",  # Immediate segment write
                    "--hls-start-offset",
                    f"{self.start_time // 3600}:{(self.start_time % 3600) // 60:02d}:{self.start_time % 60:02d}",
                    "--stream-segmented-duration",
                    str(duration),  # Use segmented duration
                    f"https://twitch.tv/videos/{self.vod_id}",
                    quality_stream + ",360p60,480p60,720p60,1080p60",
                    "-O",  # Output to stdout
                ]

                self.logger.info(f"Starting streamlink: {' '.join(cmd)}")

                # Start streamlink process
                self.streamlink_proc = subprocess.Popen(
                    cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=65536
                )

                # Monitor streamlink process (runs in parallel with ffmpeg consuming stdout)
                self.logger.info("Streamlink process started, piping to FFmpeg...")
                while not self.shutdown.is_set():
                    if self.streamlink_proc.poll() is not None:
                        # Process ended
                        stderr = self.streamlink_proc.stderr.read().decode(
                            "utf-8", errors="ignore"
                        )
                        if self.streamlink_proc.returncode != 0:
                            self.logger.error(
                                f"Streamlink failed with code {self.streamlink_proc.returncode}: {stderr}"
                            )
                            self.shutdown.set()  # Signal shutdown on streamlink failure
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
                            self.logger.info(f"Streamlink completed successfully.")
                        break
                    time.sleep(1)

            except Exception as e:
                self.logger.error(f"Streamlink worker failed: {e}")
                record_counter(
                    "errors",
                    1,
                    {
                        **metric_attrs,
                        "component": "streamlink",
                        "error_type": type(e).__name__,
                    },
                )
                self.shutdown.set()

    def ffmpeg_worker(self):
        """Worker to decode frames from streamlink stream (runs in parallel with opencv_worker)"""
        metric_attrs = {
            "streamer": self.streamer or "unknown",
            "quality": self.formatted_quality,
        }

        with create_span("ffmpeg_decode", attributes=self.span_attributes) as span:
            try:
                # In test mode, read directly from file
                if self.test_mode:
                    # Determine input file path
                    quality_config = QUALITY_CONFIGS.get(
                        self.quality, QUALITY_CONFIGS["480p"]
                    )
                    test_data_dir = self.config.get("test_mode", {}).get(
                        "data_directory", "test_data"
                    )
                    video_filename = quality_config["file_suffix"]

                    # Log which quality file we're using
                    self.logger.info(
                        f"Test mode enabled - using video file: {video_filename} for quality: {self.quality}"
                    )

                    # Check if running in Docker container (test_data mounted at /app/test_data)
                    docker_test_path = f"/app/{test_data_dir}"
                    if os.path.exists(docker_test_path):
                        # Running in Docker container
                        input_file = os.path.join(
                            docker_test_path, self.vod_id, video_filename
                        )
                        self.logger.info(
                            f"Running in Docker container - test data path: {docker_test_path}"
                        )
                    else:
                        # Running locally
                        input_file = os.path.join(
                            os.path.dirname(__file__),
                            "..",
                            "..",
                            test_data_dir,
                            self.vod_id,
                            video_filename,
                        )
                        self.logger.info(
                            f"Running locally - test data path: {test_data_dir}"
                        )

                    if not os.path.exists(input_file):
                        self.logger.error(f"Test file not found: {input_file}")
                        self.logger.error(
                            f"Expected video file '{video_filename}' in directory: {os.path.dirname(input_file)}"
                        )
                        self.shutdown.set()
                        return

                    self.logger.info(f"Test video file located: {input_file}")
                    self.logger.info(
                        f"Video resolution for processing: {quality_config['resolution'][0]}x{quality_config['resolution'][1]}"
                    )

                    # Get frame dimensions from quality config for crop calculation
                    frame_width, frame_height = quality_config["resolution"]
                else:
                    # Wait for streamlink to start
                    time.sleep(2)
                    if (
                        not self.streamlink_proc
                        or self.streamlink_proc.poll() is not None
                    ):
                        self.logger.error(
                            "Streamlink not running when FFmpeg tried to start"
                        )
                        return

                    self.logger.info("Streamlink confirmed running, starting FFmpeg...")
                    # Determine resolution based on quality for streamlink mode
                    quality_resolutions = {
                        "360p": (640, 360),
                        "480p": (854, 480),
                        "720p": (1280, 720),
                        "1080p": (1920, 1080),
                        "1080p60": (1920, 1080),
                    }
                    frame_width, frame_height = quality_resolutions.get(
                        self.quality, (854, 480)
                    )

                # Build video filter chain
                vf_filters = [f"fps={self.config['processing']['frame_rate']}"]

                # Use pre-computed combined crop (set in process_vod_chunk before threads start)
                w, h, x, y = self._combined_crop
                vf_filters.append(f"crop={w}:{h}:{x}:{y}")
                self.logger.info(
                    f"Applied crop: [x={x}, y={y}, w={w}, h={h}] for {frame_width}x{frame_height} video"
                )
                self.logger.info(f"Cropped frame dimensions will be: {w}x{h} pixels")

                # Add showinfo filter to extract PTS timestamps from stderr
                vf_filters.append("showinfo")

                vf_chain = ",".join(vf_filters)

                # Build FFmpeg command
                if self.test_mode:
                    # Read from file with seeking support
                    # Use loglevel 'info' so showinfo filter PTS output appears on stderr
                    ffmpeg_cmd = [
                        "ffmpeg",
                        "-ss",
                        str(self.start_time),  # Seek to start time
                        "-i",
                        input_file,  # Input from file
                        "-t",
                        str(self.end_time - self.start_time),  # Duration
                        "-vf",
                        vf_chain,
                        "-f",
                        "image2pipe",
                        "-vcodec",
                        "mjpeg",
                        "-loglevel",
                        "info",
                        "pipe:1",  # Output to stdout
                    ]
                else:
                    # Read from pipe (streamlink)
                    # Use loglevel 'info' so showinfo filter PTS output appears on stderr
                    ffmpeg_cmd = [
                        "ffmpeg",
                        "-i",
                        "pipe:0",  # Input from stdin
                        "-vf",
                        vf_chain,
                        "-f",
                        "image2pipe",
                        "-vcodec",
                        "mjpeg",
                        "-loglevel",
                        "info",
                        "pipe:1",  # Output to stdout
                    ]

                if self.config["ffmpeg"]["keyframes_only"] and not self.test_mode:
                    # Insert input options before -i (only for pipe input)
                    ffmpeg_cmd.insert(1, "-skip_frame")
                    ffmpeg_cmd.insert(2, "nokey")

                self.logger.info("Starting FFmpeg pipeline")

                # Start FFmpeg process
                if self.test_mode:
                    # No stdin needed when reading from file
                    self.ffmpeg_proc = subprocess.Popen(
                        ffmpeg_cmd,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        bufsize=65536,
                    )
                else:
                    # Connect to streamlink's stdout
                    self.ffmpeg_proc = subprocess.Popen(
                        ffmpeg_cmd,
                        stdin=self.streamlink_proc.stdout,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        bufsize=65536,
                    )

                # Check if FFmpeg started successfully
                time.sleep(0.5)  # Give FFmpeg a moment to start
                if self.ffmpeg_proc.poll() is not None:
                    stderr = self.ffmpeg_proc.stderr.read().decode(
                        "utf-8", errors="ignore"
                    )
                    self.logger.error(
                        f"FFmpeg failed to start. Exit code: {self.ffmpeg_proc.returncode}, stderr: {stderr}"
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
                else:
                    self.logger.info("FFmpeg process started successfully")

                # Start background thread to read FFmpeg stderr and parse
                # showinfo PTS timestamps. Each showinfo line corresponds 1:1
                # with a JPEG frame on stdout, so pts_queue stays in sync
                # with frame_queue.
                pts_re = re.compile(r"pts_time:([\d.]+)\s")

                def _read_ffmpeg_stderr():
                    try:
                        for raw_line in self.ffmpeg_proc.stderr:
                            line = raw_line.decode("utf-8", errors="ignore").rstrip()
                            m = pts_re.search(line)
                            if m:
                                self.pts_queue.put(float(m.group(1)))
                            elif line and "showinfo" not in line:
                                # Forward non-showinfo FFmpeg messages to logger
                                self.logger.debug(f"FFmpeg: {line}")
                    except Exception as e:
                        self.logger.warning(f"FFmpeg stderr reader error: {e}")

                stderr_thread = threading.Thread(
                    target=_read_ffmpeg_stderr, name="ffmpeg-stderr", daemon=True
                )
                stderr_thread.start()

                # Read frames from FFmpeg
                frame_buffer = b""
                frames_extracted = 0
                bytes_read = 0
                self.logger.info("Starting to read frames from FFmpeg...")

                while not self.shutdown.is_set():
                    chunk = self.ffmpeg_proc.stdout.read(4096)
                    if not chunk:
                        self.logger.info(
                            f"FFmpeg stream ended. Total bytes read: {bytes_read}, frames extracted: {frames_extracted}"
                        )
                        break

                    bytes_read += len(chunk)
                    frame_buffer += chunk

                    # Look for JPEG markers
                    while True:
                        start = frame_buffer.find(b"\xff\xd8")  # JPEG start
                        if start == -1:
                            break

                        end = frame_buffer.find(b"\xff\xd9", start)  # JPEG end
                        if end == -1:
                            break

                        # Extract complete frame
                        frame_data = frame_buffer[start : end + 2]
                        frame_buffer = frame_buffer[end + 2 :]
                        frames_extracted += 1
                        # Add to queue if not full
                        try:
                            self.frame_queue.put(frame_data, timeout=0.1)
                            record_gauge("queue_depth", 1, metric_attrs)
                        except queue.Full:
                            # Frame dropped — consume the matching PTS to
                            # keep pts_queue and frame_queue in sync
                            try:
                                self.pts_queue.get(timeout=1)
                            except queue.Empty:
                                pass
                            self.logger.warning("Frame queue full, dropping frame")
                            record_counter(
                                "frames_skipped",
                                1,
                                {**metric_attrs, "reason": "queue_full"},
                            )
                            record_counter("queue_overflow", 1, metric_attrs)

                # Wait for stderr thread to finish reading remaining output
                stderr_thread.join(timeout=5)

                self.logger.info(
                    f"FFmpeg worker finished. Final stats: {bytes_read} bytes read, {frames_extracted} frames extracted"
                )

                # Signal shutdown when FFmpeg finishes normally (not due to error)
                if not self.shutdown.is_set():
                    self.logger.info(
                        "FFmpeg completed successfully, signaling shutdown"
                    )
                    self.shutdown.set()

                # Set span attributes for frames extracted
                if span:
                    span.set_attribute("frames.extracted", frames_extracted)
                    span.set_attribute("bytes.read", bytes_read)

            except Exception as e:
                self.logger.error(f"FFmpeg worker failed: {e}")
                record_counter(
                    "errors",
                    1,
                    {
                        **metric_attrs,
                        "component": "ffmpeg",
                        "error_type": type(e).__name__,
                    },
                )
                self.shutdown.set()

    def _decode_jpeg(self, frame_data: bytes) -> Optional[np.ndarray]:
        """Decode JPEG bytes to a BGR numpy array.

        Args:
            frame_data: Raw JPEG bytes.

        Returns:
            BGR numpy array, or None if decoding fails.
        """
        arr = np.frombuffer(frame_data, dtype=np.uint8)
        frame = cv2.imdecode(arr, cv2.IMREAD_COLOR)
        return frame

    def _encode_jpeg(self, frame: np.ndarray) -> bytes:
        """Encode a BGR numpy array to JPEG bytes.

        Args:
            frame: BGR numpy array.

        Returns:
            Raw JPEG bytes.
        """
        _, buf = cv2.imencode(".jpg", frame)
        return buf.tobytes()

    def _slice_subregion(self, frame: np.ndarray, region: List[int]) -> np.ndarray:
        """Slice a subregion from a decoded frame.

        Args:
            frame: Decoded BGR numpy array of the combined crop.
            region: [x_offset, y_offset, width, height] within the combined crop.

        Returns:
            Numpy array view of the subregion.
        """
        x, y, w, h = region
        return frame[y : y + h, x : x + w]

    def opencv_worker(self):
        """Worker to process frames with OpenCV (runs in parallel, consumes from frame queue)"""
        self.logger.info("OpenCV worker starting...")
        metric_attrs = {
            "streamer": self.streamer or "unknown",
            "quality": self.formatted_quality,
        }

        # IGD state machine
        igd_enabled = self._igd_slice is not None
        igd_scan_active = False
        igd_frames_scanned = 0
        igd_max_scan_frames = 15  # ~30 seconds at 0.5 fps
        pending_detection = None  # Held detection awaiting IGD resolution

        if igd_enabled:
            self.logger.info(
                f"\033[36mIGD detection enabled, will scan up to {igd_max_scan_frames} frames after each username detection\033[0m"
            )

        try:
            while not self.shutdown.is_set():
                try:
                    # Get frame from queue
                    frame_data = self.frame_queue.get(timeout=1)
                    record_gauge("queue_depth", -1, metric_attrs)

                    # Get PTS-based timestamp from showinfo filter output.
                    # pts_time is seconds from stream start (0-based).
                    # Falls back to frame counting if PTS is unavailable.
                    try:
                        pts_time = self.pts_queue.get(timeout=5)
                        timestamp = self.start_time + int(pts_time)
                    except queue.Empty:
                        sampling_rate = self.config["processing"]["frame_rate"]
                        seconds_per_sampled_frame = (
                            1 / sampling_rate if sampling_rate > 0 else 0
                        )
                        timestamp = self.start_time + int(
                            self.frames_processed * seconds_per_sampled_frame
                        )
                        self.logger.warning(
                            f"PTS unavailable for frame {self.frames_processed}, using frame count fallback"
                        )

                    # If using combined crop, decode and slice subregions.
                    # Otherwise pass raw JPEG bytes directly (existing behavior).
                    if self._nameplate_slice is not None:
                        full_frame = self._decode_jpeg(frame_data)
                        if full_frame is None:
                            self.frames_processed += 1
                            continue
                        nameplate_frame = self._slice_subregion(
                            full_frame, self._nameplate_slice
                        )
                        nameplate_data = self._encode_jpeg(nameplate_frame)
                    else:
                        full_frame = None
                        nameplate_data = frame_data

                    result = self.frame_processor.process_frame(
                        nameplate_data, timestamp, self.vod_id, self.chunk_id
                    )

                    self.frames_processed += 1
                    record_counter("frames_processed", 1, metric_attrs)

                    # --- IGD scan on current frame (if active) ---
                    if igd_scan_active and full_frame is not None:
                        igd_crop = self._slice_subregion(full_frame, self._igd_slice)
                        igd_value = self.frame_processor.extract_igd(igd_crop)
                        igd_frames_scanned += 1

                        if igd_value is not None:
                            pending_detection["igd"] = igd_value
                            self.logger.info(
                                f"\033[32mIGD detected: day {igd_value} after {igd_frames_scanned} frames for {pending_detection.get('username')}\033[0m"
                            )
                            record_counter("igd_detected", 1, metric_attrs)
                            self._enqueue_detection(pending_detection, metric_attrs)
                            pending_detection = None
                            igd_scan_active = False
                        elif igd_frames_scanned >= igd_max_scan_frames:
                            self.logger.warning(
                                f"\033[33mIGD scan timed out after {igd_frames_scanned} frames for {pending_detection.get('username')}\033[0m"
                            )
                            record_counter("igd_timeout", 1, metric_attrs)
                            self._enqueue_detection(pending_detection, metric_attrs)
                            pending_detection = None
                            igd_scan_active = False

                    # --- Handle new matchup detection ---
                    if result and result.get("is_matchup"):
                        if igd_enabled:
                            # If a previous IGD scan is still active, flush it
                            if igd_scan_active and pending_detection is not None:
                                self.logger.warning(
                                    f"New matchup detected while IGD scan active, flushing pending detection for {pending_detection.get('username')}"
                                )
                                self._enqueue_detection(pending_detection, metric_attrs)

                            # Start IGD scan for the new detection
                            pending_detection = result
                            igd_scan_active = True
                            igd_frames_scanned = 0
                        else:
                            # No IGD — enqueue immediately (existing behavior)
                            self._enqueue_detection(result, metric_attrs)

                except queue.Empty:
                    continue
                except Exception as e:
                    self.logger.error(f"Frame processing error: {e}")

            # Shutdown: flush any pending detection
            if igd_scan_active and pending_detection is not None:
                self.logger.info(
                    f"Shutdown: flushing pending IGD detection for {pending_detection.get('username')}"
                )
                self._enqueue_detection(pending_detection, metric_attrs)

        except Exception as e:
            self.logger.error(f"OpenCV worker failed: {e}")
            self.shutdown.set()

    def _enqueue_detection(
        self, result: Dict[str, Any], metric_attrs: Dict[str, str]
    ) -> None:
        """Enqueue a matchup detection to the result queue and record metrics.

        Args:
            result: Detection result dict from process_frame().
            metric_attrs: Metric attributes for telemetry.
        """
        self.result_queue.put(result)
        self.matchups_found += 1

        # Structured JSON event for Loki queryability
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
        # Color: green if IGD found, yellow if missing
        if result.get("igd") is not None:
            self.logger.info(f"\033[32m{detection_json}\033[0m")
        else:
            self.logger.info(f"\033[33m{detection_json}\033[0m")

        # Record matchup detection
        record_counter("matchups_detected", 1, metric_attrs)

        # Record OCR confidence histogram
        if result.get("confidence"):
            record_histogram("ocr_confidence", result["confidence"], metric_attrs)

    def result_worker(self):
        """Worker to handle results and update Supabase in batches"""
        try:
            while not self.shutdown.is_set():
                try:
                    # Get result from queue
                    result = self.result_queue.get(timeout=1)
                    self.result_batch.append(result)

                    # Track all detections for summary export
                    self.all_detections.append(
                        {
                            "timestamp": result["timestamp"],
                            "username": result["username"],
                            "confidence": result.get("confidence", 0),
                            "rank": result.get("detected_rank"),
                            "frame_base64": result.get(
                                "frame_base64"
                            ),  # For workflow summary images
                        }
                    )

                    # Send batch when it reaches configured size
                    if len(self.result_batch) >= self.config["supabase"]["batch_size"]:
                        self.supabase.upload_batch(self.result_batch)
                        self.result_batch = []

                except queue.Empty:
                    # Continue waiting for more results
                    continue

        except Exception as e:
            self.logger.error(f"Result worker failed: {e}")
        finally:
            # Send remaining batch at shutdown
            if self.result_batch:
                self.logger.info(
                    f"Flushing final batch of {len(self.result_batch)} detections"
                )
                self.supabase.upload_batch(self.result_batch)
                self.result_batch = []

    def export_detection_summary(self, output_dir: str = "/app/output"):
        """Export detection summary for GitHub Actions workflow summary

        Args:
            output_dir: Directory to write the summary JSON file
        """
        try:
            self.logger.info(f"Exporting detection summary for chunk {self.chunk_id}")
            self.logger.info(f"Total detections tracked: {len(self.all_detections)}")

            # Prepare summary
            summary = {
                "chunk_id": self.chunk_id,
                "vod_id": self.vod_id,
                "streamer": self.streamer,
                "start_time": self.start_time,
                "end_time": self.end_time,
                "quality": self.formatted_quality,
                "frames_processed": self.frames_processed,
                "matchups_found": self.matchups_found,
                "detections": [],
            }

            # Add ALL detection details (images are in Supabase storage)
            for detection in self.all_detections:
                summary["detections"].append(
                    {
                        "timestamp": detection["timestamp"],
                        "username": detection["username"],
                        "confidence": detection["confidence"],
                        "rank": detection["rank"],
                    }
                )

            # Ensure output directory exists and is writable
            try:
                os.makedirs(output_dir, exist_ok=True)
                self.logger.info(f"Output directory ready: {output_dir}")
            except Exception as mkdir_err:
                self.logger.error(f"Failed to create output directory: {mkdir_err}")
                raise

            # Write to output directory with unique filename per chunk
            output_path = os.path.join(output_dir, f"detections_{self.chunk_id}.json")
            self.logger.info(f"Writing summary to: {output_path}")

            with open(output_path, "w") as f:
                json.dump(summary, f, indent=2)

            # Verify file was written
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
        """Clean up resources on shutdown"""
        self.logger.info("Starting cleanup")

        # Set shutdown flag
        self.shutdown.set()

        # Terminate subprocesses
        for proc_name, proc in [
            ("ffmpeg", self.ffmpeg_proc),
            ("streamlink", self.streamlink_proc),
        ]:
            if proc and proc.poll() is None:
                self.logger.info(f"Terminating {proc_name}")
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.logger.warning(f"Force killing {proc_name}")
                    proc.kill()

        # Clear queues
        while not self.frame_queue.empty():
            try:
                self.frame_queue.get_nowait()
            except queue.Empty:
                break

        # Flush and shutdown telemetry before exit
        self.logger.info("Flushing telemetry...")
        shutdown_telemetry()

        self.logger.info("Cleanup completed")


def main():
    """Main entry point"""
    # Parse command line arguments or environment variables
    config = {
        "chunk_id": os.getenv("CHUNK_ID", sys.argv[1] if len(sys.argv) > 1 else None),
        "test_mode": os.getenv("TEST_MODE", "false").lower() == "true",
        "quality": os.getenv(
            "QUALITY", "480p"
        ),  # Can be single or comma-separated list
        "old_templates": os.getenv("OLD_TEMPLATES", "false").lower() == "true",
        "video_fps": int(os.getenv("VIDEO_FPS", "30")),  # Actual video FPS (30 or 60)
    }

    if not config["chunk_id"]:
        print("Usage: sfde.py <chunk_id>")
        print("Or set CHUNK_ID environment variable")
        print(
            "Optional: TEST_MODE=true/false, QUALITY=480p (or 480p,360p,1080p60), OLD_TEMPLATES=true/false"
        )
        sys.exit(1)

    # Create and run processor
    try:
        processor = SFDEProcessor(config)
        result = processor.process_vod_chunk()
        # Exit with appropriate code
        sys.exit(0 if result["status"] == "completed" else 1)
    except Exception as e:
        print(f"Failed to process chunk: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
