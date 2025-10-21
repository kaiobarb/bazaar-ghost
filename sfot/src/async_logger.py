"""Async logger for SFOT that sends logs to local Supabase Logflare instance without blocking"""
import asyncio
import aiohttp
import json
from datetime import datetime
from typing import Any, Dict, Optional
from concurrent.futures import ThreadPoolExecutor
import threading
import queue

class AsyncSupabaseLogger:
    def __init__(self, source_name: str = "sfot_logs", api_key: Optional[str] = None):
        """Initialize async logger for local Supabase Logflare instance

        Args:
            source_name: Name for the log source in Logflare
            api_key: API key for Logflare (optional for local dev)
        """
        self.logflare_url = "http://localhost:54327"
        self.source_name = source_name
        self.api_key = api_key or "your-local-api-key"

        # Queue for log messages
        self.log_queue = queue.Queue()
        self.running = True

        # Start background thread for sending logs
        self.worker_thread = threading.Thread(target=self._worker, daemon=True)
        self.worker_thread.start()

    def _worker(self):
        """Background worker that sends logs from the queue"""
        import requests

        while self.running:
            try:
                # Get log from queue (blocks for up to 1 second)
                log_data = self.log_queue.get(timeout=1)

                # Send to Logflare
                requests.post(
                    f"{self.logflare_url}/api/logs",
                    params={"source_name": self.source_name},
                    headers={
                        "Content-Type": "application/json",
                        "X-API-KEY": self.api_key
                    },
                    json=log_data,
                    timeout=5
                )

            except queue.Empty:
                continue  # No logs to send
            except Exception as e:
                print(f"Failed to send log: {e}")

    def log(self, level: str, message: str, metadata: Dict[str, Any] = None):
        """Queue log for async sending

        Args:
            level: Log level (info, warn, error, debug)
            message: Log message
            metadata: Additional metadata to include
        """
        payload = {
            "message": message,
            "metadata": {
                "level": level,
                "service": "sfot",
                "timestamp": datetime.utcnow().isoformat(),
                **(metadata or {})
            }
        }

        # Add to queue (non-blocking)
        try:
            self.log_queue.put_nowait(payload)
        except queue.Full:
            print(f"Log queue full, dropping: {message}")

    def info(self, message: str, **metadata):
        """Log info level message"""
        self.log("info", message, metadata)

    def error(self, message: str, **metadata):
        """Log error level message"""
        self.log("error", message, metadata)

    def warning(self, message: str, **metadata):
        """Log warning level message"""
        self.log("warning", message, metadata)

    def debug(self, message: str, **metadata):
        """Log debug level message"""
        self.log("debug", message, metadata)

    def shutdown(self):
        """Shutdown the logger and flush remaining logs"""
        self.running = False
        self.worker_thread.join(timeout=5)


# Alternative: Fire-and-forget approach (even simpler)
class FireAndForgetLogger:
    def __init__(self, source_name: str = "sfot_logs", api_key: Optional[str] = None):
        self.logflare_url = "http://localhost:54327"
        self.source_name = source_name
        self.api_key = api_key or "your-local-api-key"
        self.executor = ThreadPoolExecutor(max_workers=2)

    def _send_log(self, payload):
        """Send log in background thread"""
        import requests
        try:
            requests.post(
                f"{self.logflare_url}/api/logs",
                params={"source_name": self.source_name},
                headers={
                    "Content-Type": "application/json",
                    "X-API-KEY": self.api_key
                },
                json=payload,
                timeout=5
            )
        except:
            pass  # Silently fail - this is fire-and-forget

    def log(self, level: str, message: str, metadata: Dict[str, Any] = None):
        """Send log in background without blocking"""
        payload = {
            "message": message,
            "metadata": {
                "level": level,
                "service": "sfot",
                "timestamp": datetime.utcnow().isoformat(),
                **(metadata or {})
            }
        }

        # Submit to thread pool (non-blocking)
        self.executor.submit(self._send_log, payload)

    def info(self, message: str, **metadata):
        self.log("info", message, metadata)

    def error(self, message: str, **metadata):
        self.log("error", message, metadata)

    def warning(self, message: str, **metadata):
        self.log("warning", message, metadata)

    def debug(self, message: str, **metadata):
        self.log("debug", message, metadata)