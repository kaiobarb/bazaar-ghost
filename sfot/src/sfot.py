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
from datetime import datetime, timedelta
from typing import Optional, Dict, Any, Tuple
import psutil
import yaml
import numpy as np
from dotenv import load_dotenv

# Load environment variables
load_dotenv()

# Import worker modules
from frame_processor import FrameProcessor
from supabase_client import SupabaseClient
from json_logger import JSONFormatter

class SFOTProcessor:
    """Main SFOT processor orchestrator"""
    
    def __init__(self, config: Dict[str, Any]):
        """Initialize SFOT processor with configuration"""
        self.vod_id = config['vod_id']
        self.start_time = config['start_time']
        self.end_time = config['end_time']
        
        # Load configuration
        self.config = self._load_config()
        
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
        
        # Initialize workers
        self.frame_processor = FrameProcessor(self.config)
        self.supabase = SupabaseClient(self.config)
        
        # Setup logging
        self._setup_logging()
        
        # Register signal handlers
        signal.signal(signal.SIGTERM, self._handle_shutdown)
        signal.signal(signal.SIGINT, self._handle_shutdown)
        
    def _load_config(self) -> Dict[str, Any]:
        """Load configuration from YAML file"""
        config_path = os.path.join(os.path.dirname(__file__), '..', 'config.yaml')
        with open(config_path, 'r') as f:
            config = yaml.safe_load(f)
        
        # Override with environment variables if present
        if os.getenv('SUPABASE_URL'):
            config['supabase']['url'] = os.getenv('SUPABASE_URL')
        if os.getenv('SUPABASE_SERVICE_ROLE_KEY'):
            config['supabase']['service_role_key'] = os.getenv('SUPABASE_SERVICE_ROLE_KEY')
            
        return config
    
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
        
        # Add VOD context to all logs
        self.logger = logging.LoggerAdapter(self.logger, {
            'vod_id': self.vod_id,
        })
    
    def _handle_shutdown(self, signum, frame):
        """Handle shutdown signals gracefully"""
        self.logger.info(f"Received signal {signum}, initiating graceful shutdown")
        self.shutdown.set()
    
    def process_vod_chunk(self) -> Dict[str, Any]:
        """Main processing entry point"""
        self.logger.info(f"Starting VOD processing: {self.vod_id} [{self.start_time}-{self.end_time}]")
        
        try:
            # Start worker threads
            threads = [
                threading.Thread(target=self.streamlink_worker, name="streamlink"),
                threading.Thread(target=self.ffmpeg_worker, name="ffmpeg"),
                threading.Thread(target=self.opencv_worker, name="opencv"),
                threading.Thread(target=self.result_worker, name="results"),
                threading.Thread(target=self.monitor_worker, name="monitor")
            ]
            
            for thread in threads:
                thread.start()
            
            # Wait for completion or shutdown
            for thread in threads:
                thread.join(timeout=self.config['processing']['timeout'])
            
            # Final status update
            status = 'completed' if not self.shutdown.is_set() else 'interrupted'
            self.logger.info(f"Processing {status}: {self.frames_processed} frames, {self.matchups_found} matchups")
            
            return {
                'status': status,
                'frames_processed': self.frames_processed,
                'matchups_found': self.matchups_found,
                'vod_id': self.vod_id,
                'start_time': self.start_time,
                'end_time': self.end_time
            }
            
        except Exception as e:
            self.logger.error(f"Processing failed: {e}", exc_info=True)
            raise
        finally:
            self.cleanup()
    
    def streamlink_worker(self):
        """Worker to run streamlink and pipe output to FFmpeg"""
        try:
            # Calculate duration
            duration = self.end_time - self.start_time
            
            # Build streamlink command
            cmd = [
                'streamlink',
                '--default-stream', self.config['streamlink']['default_stream'],
                f'https://twitch.tv/videos/{self.vod_id}',
                '--hls-start-offset', str(timedelta(seconds=self.start_time)),
                '--hls-duration', str(duration),
                '--retry-streams', str(self.config['streamlink']['retry_delay']),
                '--retry-max', str(self.config['streamlink']['retry_attempts']),
                '--quiet',
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
            while not self.shutdown.is_set():
                if self.streamlink_proc.poll() is not None:
                    # Process ended
                    stderr = self.streamlink_proc.stderr.read().decode('utf-8', errors='ignore')
                    if self.streamlink_proc.returncode != 0:
                        self.logger.error(f"Streamlink failed: {stderr}")
                    break
                time.sleep(1)
                
        except Exception as e:
            self.logger.error(f"Streamlink worker failed: {e}")
            self.shutdown.set()
    
    def ffmpeg_worker(self):
        """Worker to process streamlink output through FFmpeg"""
        try:
            # Wait for streamlink to start
            time.sleep(2)
            
            if not self.streamlink_proc or self.streamlink_proc.poll() is not None:
                self.logger.error("Streamlink not running")
                return
            
            # Build FFmpeg command for keyframe extraction
            ffmpeg_cmd = [
                'ffmpeg',
                '-i', 'pipe:0',  # Input from stdin
                '-vf', f'fps={self.config["processing"]["frame_rate"]}',
                '-f', 'image2pipe',
                '-vcodec', 'mjpeg',
                '-loglevel', self.config['ffmpeg']['loglevel'],
                'pipe:1'  # Output to stdout
            ]
            
            if self.config['ffmpeg']['keyframes_only']:
                ffmpeg_cmd.insert(3, '-skip_frame')
                ffmpeg_cmd.insert(4, 'nokey')
            
            self.logger.info("Starting FFmpeg pipeline")
            
            # Start FFmpeg process
            self.ffmpeg_proc = subprocess.Popen(
                ffmpeg_cmd,
                stdin=self.streamlink_proc.stdout,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                bufsize=65536
            )
            
            # Read frames from FFmpeg
            frame_buffer = b''
            while not self.shutdown.is_set():
                chunk = self.ffmpeg_proc.stdout.read(4096)
                if not chunk:
                    break
                    
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
                    
                    # Add to queue if not full
                    try:
                        self.frame_queue.put(frame_data, timeout=0.1)
                    except queue.Full:
                        self.logger.warning("Frame queue full, dropping frame")
                        
        except Exception as e:
            self.logger.error(f"FFmpeg worker failed: {e}")
            self.shutdown.set()
    
    def opencv_worker(self):
        """Worker to process frames with OpenCV"""
        try:
            while not self.shutdown.is_set():
                try:
                    # Get frame from queue
                    frame_data = self.frame_queue.get(timeout=1)
                    
                    # Process frame
                    timestamp = self.start_time + (self.frames_processed * 5)  # Based on frame rate
                    result = self.frame_processor.process_frame(
                        frame_data, 
                        timestamp,
                        self.vod_id
                    )
                    
                    self.frames_processed += 1
                    
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
        """Worker to handle results and update Supabase"""
        batch = []
        last_batch_time = time.time()
        
        try:
            while not self.shutdown.is_set():
                try:
                    # Get result from queue
                    result = self.result_queue.get(timeout=1)
                    batch.append(result)
                    
                    # Check if batch should be sent
                    current_time = time.time()
                    should_send = (
                        len(batch) >= self.config['supabase']['batch_size'] or
                        current_time - last_batch_time >= self.config['processing']['batch_update_interval']
                    )
                    
                    if should_send and batch:
                        self.supabase.upload_batch(batch)
                        batch = []
                        last_batch_time = current_time
                        
                except queue.Empty:
                    # Check if time to send partial batch
                    current_time = time.time()
                    if batch and current_time - last_batch_time >= self.config['processing']['batch_update_interval']:
                        self.supabase.upload_batch(batch)
                        batch = []
                        last_batch_time = current_time
                        
        except Exception as e:
            self.logger.error(f"Result worker failed: {e}")
        finally:
            # Send remaining batch
            if batch:
                self.supabase.upload_batch(batch)
    
    def monitor_worker(self):
        """Worker to monitor health and update status"""
        try:
            while not self.shutdown.is_set():
                # Collect metrics
                metrics = self.get_health_metrics()
                
                # Log health status
                self.logger.info("Health check", extra={'metrics': metrics})
                
                # Check resource limits
                if metrics['memory_usage_mb'] > self.config['resources']['max_memory_mb']:
                    self.logger.warning(f"Memory limit exceeded: {metrics['memory_usage_mb']}MB")
                    
                time.sleep(10)
                
        except Exception as e:
            self.logger.error(f"Monitor worker failed: {e}")
    
    def get_health_metrics(self) -> Dict[str, Any]:
        """Get current health metrics"""
        process = psutil.Process()
        return {
            'status': 'healthy' if not self.shutdown.is_set() else 'shutting_down',
            'frames_processed': self.frames_processed,
            'matchups_found': self.matchups_found,
            'queue_size': self.frame_queue.qsize(),
            'memory_usage_mb': process.memory_info().rss / 1024 / 1024,
            'cpu_percent': process.cpu_percent(interval=1),
            'threads': threading.active_count()
        }
    
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


def main():
    """Main entry point"""
    # Parse command line arguments or environment variables
    config = {
        'vod_id': os.getenv('VOD_ID', sys.argv[1] if len(sys.argv) > 1 else None),
        'start_time': int(os.getenv('START_TIME', sys.argv[2] if len(sys.argv) > 2 else 0)),
        'end_time': int(os.getenv('END_TIME', sys.argv[3] if len(sys.argv) > 3 else 1800)),
    }
    
    if not config['vod_id']:
        print("Usage: sfot.py <vod_id> [start_time] [end_time]")
        print("Or set VOD_ID, START_TIME, END_TIME environment variables")
        sys.exit(1)
    
    # Create and run processor
    processor = SFOTProcessor(config)
    result = processor.process_vod_chunk()
    
    # Exit with appropriate code
    sys.exit(0 if result['status'] == 'completed' else 1)


if __name__ == '__main__':
    main()