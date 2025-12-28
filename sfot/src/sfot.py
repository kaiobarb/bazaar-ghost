#!/usr/bin/env python3
"""
SFOT Processor - Main orchestrator for VOD processing pipeline
Streamlink → FFmpeg → OpenCV → Tesseract
"""

import os
import sys
import signal
import queue
import threading
import subprocess
import time
import json
import logging
import math
import io
from datetime import datetime, timedelta
from typing import Optional, Dict, Any, Tuple, List
import yaml
import numpy as np
from dotenv import load_dotenv

# Load environment variables
load_dotenv()

# Import worker modules
from frame_processor import FrameProcessor
from supabase_client import SupabaseClient
from json_logger import JSONFormatter

# Quality configuration mapping for test mode
QUALITY_CONFIGS = {
    '360p': {'resolution': (640, 360), 'file_suffix': '360p.mp4'},
    '480p': {'resolution': (854, 480), 'file_suffix': '480p.mp4'},
    '1080p': {'resolution': (1920, 1080), 'file_suffix': '1080p.mp4'},
    '1080p60': {'resolution': (1920, 1080), 'file_suffix': '1080p.mp4'}
}

class SFOTProcessor:
    """Main SFOT processor orchestrator"""

    def __init__(self, config: Dict[str, Any]):
        """Initialize SFOT processor with configuration"""
        self.chunk_id = config['chunk_id']
        self.test_mode = config.get('test_mode', False)
        self.quality = config.get('quality', '480p')
        self.old_templates = config.get('old_templates', False)
        self.method = config.get('method', 'template')
        self.video_fps = config.get('video_fps', 30)  # Actual video FPS

        # Format quality string with FPS suffix for database storage
        # Streamlink/Twitch returns quality as "480p", "720p", "1080p" for 30fps, but appends "60"
        # if it is a 60fps stream.
        # Append "60" suffix when video is 60fps to match streamlink's naming (e.g., "1080p60")
        self.formatted_quality = f"{self.quality}60" if self.video_fps == 60 else self.quality

        # Load configuration
        self.config = self._load_config()

        # Parse SFOT profile from environment variable
        self.profile = self._parse_sfot_profile()

        # Initialize Supabase client first to fetch chunk details
        self.supabase = SupabaseClient(self.config, test_mode=self.test_mode, quality=self.quality)

        # Fetch chunk details from database
        chunk_details = self.supabase.get_chunk_details(self.chunk_id)
        if not chunk_details:
            raise ValueError(f"Could not fetch details for chunk {self.chunk_id}")

        # Set processing parameters from chunk details
        self.vod_id = chunk_details['vod_id']
        self.start_time = chunk_details['start_seconds']
        self.end_time = chunk_details['end_seconds']
        self.streamer = chunk_details.get('streamer')
        self.initial_status = chunk_details.get('status')  # Store for later use

        # Initialize components
        self.frame_queue = queue.Queue(maxsize=self.config['processing']['queue_size'])
        self.result_queue = queue.Queue()
        self.shutdown = threading.Event()

        # Process state
        self.streamlink_proc: Optional[subprocess.Popen] = None
        self.ffmpeg_proc: Optional[subprocess.Popen] = None
        self.frames_processed = 0
        self.matchups_found = 0
        self.last_update_time = time.time()
        self.frames_at_last_update = 0
        self.result_batch = []  # Current batch being accumulated
        self.all_detections = []  # All detections for summary export

        # Initialize frame processor with quality information, test mode, and template selection
        self.frame_processor = FrameProcessor(self.config, quality=self.quality, test_mode=self.test_mode, old_templates=self.old_templates, method=self.method, profile=self.profile)

        # Setup logging
        self._setup_logging()

        # Register signal handlers
        signal.signal(signal.SIGTERM, self._handle_shutdown)
        signal.signal(signal.SIGINT, self._handle_shutdown)

    def percent_to_pixels(self, crop_percent: List[float], frame_width: int, frame_height: int) -> List[int]:
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
        x = math.floor(x_percent * frame_width)      # Round left down
        y = math.floor(y_percent * frame_height)     # Round top down
        w = math.ceil(w_percent * frame_width)       # Round width up
        h = math.ceil(h_percent * frame_height)      # Round height up

        # Ensure values don't exceed frame bounds
        x = min(x, frame_width - 1)
        y = min(y, frame_height - 1)
        w = min(w, frame_width - x)
        h = min(h, frame_height - y)

        # Return in FFmpeg format [width, height, x, y]
        return [w, h, x, y]

    def _load_config(self) -> Dict[str, Any]:
        """Load configuration from YAML file"""
        config_path = os.path.join(os.path.dirname(__file__), '..', 'config.yaml')
        with open(config_path, 'r') as f:
            config = yaml.safe_load(f)

        # Override with environment variables if present
        if os.getenv('SUPABASE_URL'):
            config['supabase']['url'] = os.getenv('SUPABASE_URL')
        if os.getenv('SUPABASE_SECRET_KEY'):
            config['supabase']['secret_key'] = os.getenv('SUPABASE_SECRET_KEY')

        return config

    def _parse_sfot_profile(self) -> Dict[str, Any]:
        """Parse SFOT profile from environment variable

        Returns:
            Dictionary containing profile data with crop_region, scale, etc.

        Raises:
            ValueError: If SFOT_PROFILE is missing or invalid JSON
        """
        sfot_profile_json = os.getenv('SFOT_PROFILE')

        if not sfot_profile_json:
            raise ValueError(
                "SFOT_PROFILE environment variable is required. "
                "This should be provided by the GitHub Actions workflow as a JSON string."
            )

        try:
            profile = json.loads(sfot_profile_json)
        except json.JSONDecodeError as e:
            raise ValueError(f"SFOT_PROFILE is not valid JSON: {e}")

        # Validate required fields
        if 'crop_region' not in profile:
            raise ValueError("SFOT_PROFILE missing required field: crop_region")

        if not isinstance(profile['crop_region'], list) or len(profile['crop_region']) != 4:
            raise ValueError(
                f"SFOT_PROFILE crop_region must be array of 4 numbers, got: {profile.get('crop_region')}"
            )

        return profile
    
    def _setup_logging(self):
        """Setup structured JSON logging"""
        self.logger = logging.getLogger('sfot')
        self.logger.setLevel(getattr(logging, self.config['logging']['level']))

        # JSON formatter
        formatter = JSONFormatter()

        # Console handler
        console_handler = logging.StreamHandler(sys.stdout)
        console_handler.setFormatter(formatter)
        self.logger.addHandler(console_handler)

        # String buffer handler to capture logs for upload
        self.log_buffer = io.StringIO()
        buffer_handler = logging.StreamHandler(self.log_buffer)
        buffer_handler.setFormatter(formatter)
        self.logger.addHandler(buffer_handler)

        # Add VOD context to all logs
        self.logger = logging.LoggerAdapter(self.logger, {
            'vod_id': self.vod_id,
        })
    
    def _handle_shutdown(self, signum, frame):
        """Handle shutdown signals gracefully"""
        self.logger.info(f"Received signal {signum}, initiating shutdown")
        self.shutdown.set()
    
    def process_vod_chunk(self) -> Dict[str, Any]:
        """Main processing entry point"""
        self.logger.info(f"Starting VOD processing: {self.vod_id} [{self.start_time}-{self.end_time}]")
        self.logger.info(f"Using SFOT profile: {self.profile.get('profile_name', 'unknown')}")
        self.logger.info(f"Crop region: {self.profile['crop_region']}")
        if self.old_templates:
            self.logger.info("Using small templates (underscore-prefixed) for older VOD processing")

        try:
            # Always clean up existing detections and images when rerunning a chunk
            # This ensures clean slate whether chunk was completed, failed, or partially processed
            self.logger.info(f"Cleaning up any existing detections for chunk {self.chunk_id} (status: {self.initial_status})...")
            deleted_count = self.supabase.delete_chunk_detections(self.chunk_id)
            if deleted_count > 0:
                self.logger.info(f"Deleted {deleted_count} existing detections and their images for clean reprocessing")
            else:
                self.logger.info(f"No existing detections found for chunk {self.chunk_id}")

            # Update chunk status to processing with quality info
            self.supabase.update_chunk(
                self.chunk_id,
                'processing',
                quality=self.formatted_quality
            )

            # Start worker threads
            threads = [
                threading.Thread(target=self.streamlink_worker, name="streamlink"),
                threading.Thread(target=self.ffmpeg_worker, name="ffmpeg"),
                threading.Thread(target=self.opencv_worker, name="opencv"),
                threading.Thread(target=self.result_worker, name="results"),
                threading.Thread(target=self.progress_monitor_worker, name="progress_monitor")
            ]

            for thread in threads:
                thread.start()

            # Wait for completion or shutdown
            for thread in threads:
                thread.join(timeout=self.config['processing']['timeout'])

            # Final status update - check if we completed successfully
            # If shutdown was set but we processed frames successfully, it's completion
            if self.frames_processed > 0 and self.shutdown.is_set():
                status = 'completed'
            elif not self.shutdown.is_set():
                status = 'completed'
            else:
                status = 'interrupted'
            self.logger.info(f"Processing {status}: {self.frames_processed} frames, {self.matchups_found} matchups")

            # Update chunk with final status
            if status == 'completed':
                self.supabase.update_chunk(
                    self.chunk_id,
                    'completed',
                    frames_processed=self.frames_processed,
                    detections_count=self.matchups_found,
                    quality=self.formatted_quality
                )
            else:
                # Set back to pending if interrupted
                self.supabase.update_chunk(
                    self.chunk_id,
                    'pending',
                    error=f"Processing interrupted after {self.frames_processed} frames",
                    frames_processed=self.frames_processed,
                    detections_count=self.matchups_found,
                    quality=self.formatted_quality
                )

            # Export detection summary for GitHub Actions workflow
            self.export_detection_summary()

            return {
                'status': status,
                'frames_processed': self.frames_processed,
                'matchups_found': self.matchups_found,
                'vod_id': self.vod_id,
                'start_time': self.start_time,
                'end_time': self.end_time,
                'quality': self.quality
            }

        except Exception as e:
            self.logger.error(f"Processing failed: {e}", exc_info=True)
            # Update chunk status to failed with error message
            try:
                self.supabase.update_chunk(
                    self.chunk_id,
                    'failed',
                    error=f"Processing failed: {str(e)}",
                    quality=self.formatted_quality
                )
            except Exception as update_error:
                self.logger.error(f"Failed to update chunk status on error: {update_error}")
            raise
        finally:
            self.cleanup()
    
    def streamlink_worker(self):
        """Worker to run streamlink and pipe output to FFmpeg"""
        try:
            # Skip streamlink in test mode - FFmpeg will read directly from file
            if self.test_mode:
                self.logger.info("Test mode enabled, skipping streamlink")
                return

            # Calculate duration
            duration = self.end_time - self.start_time

            # Build streamlink command with quality preference
            quality_stream = self.quality if self.quality in ['360p', '360p60', '480p', '480p60', '720p', '720p60', '1080p', '1080p60', 'worst', 'best'] else '480p'
            cmd = [
                'streamlink',
                '--stream-segment-threads', '1',  # Consistent delivery
                '--hls-segment-stream-data',      # Immediate segment write
                '--hls-start-offset', str(timedelta(seconds=self.start_time)),
                '--stream-segmented-duration', str(duration),  # Use segmented duration
                f'https://twitch.tv/videos/{self.vod_id}',
                quality_stream + ',360p60,480p60,720p60,1080p60',
                '-O'  # Output to stdout
            ]
            
            self.logger.info(f"Starting streamlink: {' '.join(cmd)}")
            
            # Start streamlink process
            self.streamlink_proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                bufsize=65536
            )
            
            # Monitor streamlink process
            self.logger.info("Streamlink process started, monitoring...")
            while not self.shutdown.is_set():
                if self.streamlink_proc.poll() is not None:
                    # Process ended
                    stderr = self.streamlink_proc.stderr.read().decode('utf-8', errors='ignore')
                    if self.streamlink_proc.returncode != 0:
                        self.logger.error(f"Streamlink failed with code {self.streamlink_proc.returncode}: {stderr}")
                        self.shutdown.set()  # Signal shutdown on streamlink failure
                    else:
                        self.logger.info(f"Streamlink completed successfully.")
                    break
                time.sleep(1)
                
        except Exception as e:
            self.logger.error(f"Streamlink worker failed: {e}")
            self.shutdown.set()
    
    def ffmpeg_worker(self):
        """Worker to process streamlink output through FFmpeg"""
        try:
            # In test mode, read directly from file
            if self.test_mode:
                # Determine input file path
                quality_config = QUALITY_CONFIGS.get(self.quality, QUALITY_CONFIGS['480p'])
                test_data_dir = self.config.get('test_mode', {}).get('data_directory', 'test_data')
                video_filename = quality_config['file_suffix']

                # Log which quality file we're using
                self.logger.info(f"Test mode enabled - using video file: {video_filename} for quality: {self.quality}")

                # Check if running in Docker container (test_data mounted at /app/test_data)
                docker_test_path = f'/app/{test_data_dir}'
                if os.path.exists(docker_test_path):
                    # Running in Docker container
                    input_file = os.path.join(docker_test_path, self.vod_id, video_filename)
                    self.logger.info(f"Running in Docker container - test data path: {docker_test_path}")
                else:
                    # Running locally
                    input_file = os.path.join(os.path.dirname(__file__), '..', '..', test_data_dir,
                                             self.vod_id, video_filename)
                    self.logger.info(f"Running locally - test data path: {test_data_dir}")

                if not os.path.exists(input_file):
                    self.logger.error(f"Test file not found: {input_file}")
                    self.logger.error(f"Expected video file '{video_filename}' in directory: {os.path.dirname(input_file)}")
                    self.shutdown.set()
                    return

                self.logger.info(f"Test video file located: {input_file}")
                self.logger.info(f"Video resolution for processing: {quality_config['resolution'][0]}x{quality_config['resolution'][1]}")

                # Get frame dimensions from quality config for crop calculation
                frame_width, frame_height = quality_config['resolution']
            else:
                # Wait for streamlink to start
                time.sleep(2)
                if not self.streamlink_proc or self.streamlink_proc.poll() is not None:
                    self.logger.error("Streamlink not running when FFmpeg tried to start")
                    return

                self.logger.info("Streamlink confirmed running, starting FFmpeg...")
                # Determine resolution based on quality for streamlink mode
                quality_resolutions = {
                    '360p': (640, 360),
                    '480p': (854, 480),
                    '720p': (1280, 720),
                    '1080p': (1920, 1080)
                }
                frame_width, frame_height = quality_resolutions.get(self.quality, (854, 480))

            # Build video filter chain
            vf_filters = [f'fps={self.config["processing"]["frame_rate"]}']

            # Use crop region from SFOT profile
            crop_pixels = self.percent_to_pixels(
                self.profile['crop_region'],
                frame_width,
                frame_height
            )
            w, h, x, y = crop_pixels
            vf_filters.append(f'crop={w}:{h}:{x}:{y}')
            self.logger.info(f"Applied profile crop: [x={x}, y={y}, w={w}, h={h}] for {frame_width}x{frame_height} video")
            self.logger.info(f"Cropped frame dimensions will be: {w}x{h} pixels")

            vf_chain = ','.join(vf_filters)

            # Build FFmpeg command
            if self.test_mode:
                # Read from file with seeking support
                ffmpeg_cmd = [
                    'ffmpeg',
                    '-ss', str(self.start_time),  # Seek to start time
                    '-i', input_file,  # Input from file
                    '-t', str(self.end_time - self.start_time),  # Duration
                    '-vf', vf_chain,
                    '-f', 'image2pipe',
                    '-vcodec', 'mjpeg',
                    '-loglevel', self.config['ffmpeg']['loglevel'],
                    'pipe:1'  # Output to stdout
                ]
            else:
                # Read from pipe (streamlink)
                ffmpeg_cmd = [
                    'ffmpeg',
                    '-i', 'pipe:0',  # Input from stdin
                    '-vf', vf_chain,
                    '-f', 'image2pipe',
                    '-vcodec', 'mjpeg',
                    '-loglevel', self.config['ffmpeg']['loglevel'],
                    'pipe:1'  # Output to stdout
                ]

            if self.config['ffmpeg']['keyframes_only'] and not self.test_mode:
                # Insert input options before -i (only for pipe input)
                ffmpeg_cmd.insert(1, '-skip_frame')
                ffmpeg_cmd.insert(2, 'nokey')
            
            self.logger.info("Starting FFmpeg pipeline")

            # Start FFmpeg process
            if self.test_mode:
                # No stdin needed when reading from file
                self.ffmpeg_proc = subprocess.Popen(
                    ffmpeg_cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    bufsize=65536
                )
            else:
                # Connect to streamlink's stdout
                self.ffmpeg_proc = subprocess.Popen(
                    ffmpeg_cmd,
                    stdin=self.streamlink_proc.stdout,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    bufsize=65536
                )

            # Check if FFmpeg started successfully
            time.sleep(0.5)  # Give FFmpeg a moment to start
            if self.ffmpeg_proc.poll() is not None:
                stderr = self.ffmpeg_proc.stderr.read().decode('utf-8', errors='ignore')
                self.logger.error(f"FFmpeg failed to start. Exit code: {self.ffmpeg_proc.returncode}, stderr: {stderr}")
                return
            else:
                self.logger.info("FFmpeg process started successfully")
            
            # Read frames from FFmpeg
            frame_buffer = b''
            frames_extracted = 0
            bytes_read = 0
            self.logger.info("Starting to read frames from FFmpeg...")

            while not self.shutdown.is_set():
                chunk = self.ffmpeg_proc.stdout.read(4096)
                if not chunk:
                    # Check FFmpeg stderr for any error messages
                    stderr_data = b''
                    try:
                        stderr_data = self.ffmpeg_proc.stderr.read()
                        stderr_text = stderr_data.decode('utf-8', errors='ignore') if stderr_data else "No stderr output"
                    except:
                        stderr_text = "Could not read stderr"

                    self.logger.info(f"FFmpeg stream ended. Total bytes read: {bytes_read}, frames extracted: {frames_extracted}")
                    break

                bytes_read += len(chunk)
                frame_buffer += chunk

                # Look for JPEG markers
                while True:
                    start = frame_buffer.find(b'\xff\xd8')  # JPEG start
                    if start == -1:
                        break

                    end = frame_buffer.find(b'\xff\xd9', start)  # JPEG end
                    if end == -1:
                        break

                    # Extract complete frame
                    frame_data = frame_buffer[start:end+2]
                    frame_buffer = frame_buffer[end+2:]
                    frames_extracted += 1
                    # Add to queue if not full
                    try:
                        self.frame_queue.put(frame_data, timeout=0.1)
                    except queue.Full:
                        self.logger.warning("Frame queue full, dropping frame")

            self.logger.info(f"FFmpeg worker finished. Final stats: {bytes_read} bytes read, {frames_extracted} frames extracted")

            # Signal shutdown when FFmpeg finishes normally (not due to error)
            if not self.shutdown.is_set():
                self.logger.info("FFmpeg completed successfully, signaling shutdown")
                self.shutdown.set()
                        
        except Exception as e:
            self.logger.error(f"FFmpeg worker failed: {e}")
            self.shutdown.set()
    
    def opencv_worker(self):
        """Worker to process frames with OpenCV"""
        self.logger.info("OpenCV worker starting...")
        try:
            while not self.shutdown.is_set():
                try:
                    # Get frame from queue
                    frame_data = self.frame_queue.get(timeout=1)

                    # Calculate timestamp based on frame rate
                    sampling_rate = self.config["processing"]["frame_rate"]
                    seconds_per_sampled_frame = 1 / sampling_rate if sampling_rate > 0 else 0
                    timestamp = self.start_time + int(self.frames_processed * seconds_per_sampled_frame)
                    result = self.frame_processor.process_frame(
                        frame_data, 
                        timestamp,
                        self.vod_id,
                        self.chunk_id
                    )
                    
                    self.frames_processed += 1

                    # Log every frame processed
                    # self.logger.debug(f"Processed frame {self.frames_processed} at {timestamp}s")

                    # If matchup detected, add to result queue
                    if result and result.get('is_matchup'):
                        self.result_queue.put(result)
                        self.matchups_found += 1
                        self.logger.info(f"Matchup detected at {timestamp}s")
                        
                except queue.Empty:
                    continue
                except Exception as e:
                    self.logger.error(f"Frame processing error: {e}")
                    
        except Exception as e:
            self.logger.error(f"OpenCV worker failed: {e}")
            self.shutdown.set()
    
    def result_worker(self):
        """Worker to handle results and update Supabase in batches"""
        try:
            while not self.shutdown.is_set():
                try:
                    # Get result from queue
                    result = self.result_queue.get(timeout=1)
                    self.result_batch.append(result)

                    # Track all detections for summary export
                    self.all_detections.append({
                        'timestamp': result['timestamp'],
                        'username': result['username'],
                        'confidence': result.get('confidence', 0),
                        'rank': result.get('detected_rank'),
                        'frame_base64': result.get('frame_base64')  # For workflow summary images
                    })

                    # Send batch when it reaches configured size
                    if len(self.result_batch) >= self.config['supabase']['batch_size']:
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
                self.logger.info(f"Flushing final batch of {len(self.result_batch)} detections")
                self.supabase.upload_batch(self.result_batch)
                self.result_batch = []

    def progress_monitor_worker(self):
        """Worker to log progress updates every 10 seconds"""
        self.logger.info("Progress monitor starting...")
        update_interval = 10.0  # seconds

        try:
            while not self.shutdown.is_set():
                # Wait for the update interval or until shutdown
                if self.shutdown.wait(update_interval):
                    break

                # Calculate progress metrics
                current_time = time.time()
                time_elapsed = current_time - self.last_update_time
                frames_since_update = self.frames_processed - self.frames_at_last_update

                # Calculate processing rate
                if time_elapsed > 0:
                    fps = frames_since_update / time_elapsed
                else:
                    fps = 0.0

                # Log progress update
                self.logger.info(
                    f"Progress: Processed {self.frames_processed} frames, "
                    f"{self.matchups_found} matchups detected, "
                    f"{frames_since_update} frames since last update ({fps:.1f} fps)"
                )

                # Update tracking variables
                self.last_update_time = current_time
                self.frames_at_last_update = self.frames_processed

        except Exception as e:
            self.logger.error(f"Progress monitor failed: {e}")

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
                'chunk_id': self.chunk_id,
                'vod_id': self.vod_id,
                'streamer': self.streamer,
                'start_time': self.start_time,
                'end_time': self.end_time,
                'quality': self.formatted_quality,
                'frames_processed': self.frames_processed,
                'matchups_found': self.matchups_found,
                'detections': []
            }

            # Add detection details (limit to 10 samples for summary, without base64 images)
            for detection in self.all_detections[:10]:
                summary['detections'].append({
                    'timestamp': detection['timestamp'],
                    'username': detection['username'],
                    'confidence': detection['confidence'],
                    'rank': detection['rank']
                })

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

            with open(output_path, 'w') as f:
                json.dump(summary, f, indent=2)

            # Verify file was written
            if os.path.exists(output_path):
                file_size = os.path.getsize(output_path)
                self.logger.info(f"Successfully exported detection summary ({file_size} bytes)")
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
        for proc_name, proc in [('ffmpeg', self.ffmpeg_proc), ('streamlink', self.streamlink_proc)]:
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

        self.logger.info("Cleanup completed")

        # Upload logs to storage
        try:
            self.upload_logs()
        except Exception as e:
            print(f"Failed to upload logs: {e}", file=sys.stderr)

    def upload_logs(self):
        """Upload captured logs to Supabase storage"""
        try:
            # Flush any remaining logs - access the underlying logger from the adapter
            underlying_logger = self.logger.logger if hasattr(self.logger, 'logger') else self.logger
            for handler in underlying_logger.handlers:
                handler.flush()

            # Get log contents from buffer
            log_contents = self.log_buffer.getvalue()
            if not log_contents:
                self.logger.warning("No logs to upload")
                return

            # Generate filename with timestamp
            timestamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
            if self.test_mode:
                filename = f"test/{self.quality}/{self.chunk_id}_{timestamp}.jsonl"
            else:
                filename = f"production/{self.chunk_id}_{timestamp}.jsonl"

            # Upload to Supabase
            self.logger.info(f"Uploading logs to storage: {filename}")
            success = self.supabase.upload_logs(filename, log_contents)
            if success:
                self.logger.info(f"Logs successfully uploaded to: {filename}")
            else:
                self.logger.error("Failed to upload logs to storage")

        except Exception as e:
            self.logger.error(f"Failed to upload logs: {e}")


def main():
    """Main entry point"""
    # Parse command line arguments or environment variables
    config = {
        'chunk_id': os.getenv('CHUNK_ID', sys.argv[1] if len(sys.argv) > 1 else None),
        'test_mode': os.getenv('TEST_MODE', 'false').lower() == 'true',
        'quality': os.getenv('QUALITY', '480p'),  # Can be single or comma-separated list
        'old_templates': os.getenv('OLD_TEMPLATES', 'false').lower() == 'true',
        'video_fps': int(os.getenv('VIDEO_FPS', '30')),  # Actual video FPS (30 or 60)
    }

    if not config['chunk_id']:
        print("Usage: sfot.py <chunk_id>")
        print("Or set CHUNK_ID environment variable")
        print("Optional: TEST_MODE=true/false, QUALITY=480p (or 480p,360p,1080p60), OLD_TEMPLATES=true/false")
        sys.exit(1)

    # Create and run processor
    try:
        processor = SFOTProcessor(config)
        result = processor.process_vod_chunk()
        # Exit with appropriate code
        sys.exit(0 if result['status'] == 'completed' else 1)
    except Exception as e:
        print(f"Failed to process chunk: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
