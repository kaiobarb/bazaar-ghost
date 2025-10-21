"""Custom logger for SFOT that sends logs to local Supabase Logflare instance"""
import requests
import json
from datetime import datetime
from typing import Any, Dict, Optional

class SupabaseLogger:
    def __init__(self, source_name: str = "sfot_logs", api_key: Optional[str] = None):
        """Initialize logger for local Supabase Logflare instance

        Args:
            source_name: Name for the log source in Logflare
            api_key: API key for Logflare (optional for local dev)
        """
        self.logflare_url = "http://localhost:54327"
        self.source_name = source_name
        self.api_key = api_key or "your-local-api-key"

    def log(self, level: str, message: str, metadata: Dict[str, Any] = None):
        """Send log to local Logflare instance

        Args:
            level: Log level (info, warn, error, debug)
            message: Log message
            metadata: Additional metadata to include
        """
        try:
            payload = {
                "message": message,
                "metadata": {
                    "level": level,
                    "service": "sfot",
                    "timestamp": datetime.utcnow().isoformat(),
                    **(metadata or {})
                }
            }

            response = requests.post(
                f"{self.logflare_url}/api/logs",
                params={"source_name": self.source_name},
                headers={
                    "Content-Type": "application/json",
                    "X-API-KEY": self.api_key
                },
                json=payload
            )

            if response.status_code not in [200, 201, 202]:
                print(f"Failed to send log: {response.status_code} - {response.text}")

        except Exception as e:
            print(f"Error sending log to Logflare: {e}")

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


# Usage example
if __name__ == "__main__":
    logger = SupabaseLogger()

    # Log VOD processing events
    logger.info("Starting VOD processing",
                vod_id="123456",
                streamer="kripp",
                duration_seconds=1800)

    logger.info("Matchup detected",
                timestamp=1234.56,
                player1="Kripp",
                player2="Opponent",
                confidence=0.95)

    logger.error("Frame processing failed",
                 frame_number=12345,
                 error="OCR timeout")