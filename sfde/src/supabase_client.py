"""
Supabase client module - Handles all Supabase interactions
"""

import os
import base64
import time
import logging
from typing import List, Dict, Any, Optional
from supabase import create_client, Client
from supabase.client import ClientOptions
from datetime import datetime, timezone
from uuid import NAMESPACE_URL, uuid5
from telemetry import create_span, record_histogram, record_counter


class SupabaseClient:
    """Handle Supabase operations for SFDE processor"""

    def __init__(
        self,
        config: Dict[str, Any],
        test_mode: bool = False,
        quality: str = "480p",
        streamer: Optional[str] = None,
    ) -> None:
        """Initialize Supabase client with optional test mode and quality"""
        self.config = config
        self.logger = logging.getLogger("sfde.supabase")
        self.test_mode = test_mode
        self.quality = quality
        self.schema = "public"
        self.streamer = (
            streamer  # Set later via set_streamer() after chunk details are fetched
        )

        # Get credentials from environment
        url = os.getenv("SUPABASE_URL", config.get("supabase", {}).get("url"))
        key = os.getenv(
            "SUPABASE_SECRET_KEY", config.get("supabase", {}).get("secret_key")
        )

        if not url or not key:
            raise ValueError("SUPABASE_URL and SUPABASE_SECRET_KEY must be set")

        # TEST_MODE selects a local video, not an undeclared database schema.
        options = ClientOptions(postgrest_client_timeout=config['supabase'].get('connection_timeout', 30))
        self.client: Client = create_client(url, key, options)
        self.storage_bucket = config["supabase"]["storage_bucket"]

        # Batch processing settings
        self.retry_attempts = config['supabase']['retry_attempts']
        if not isinstance(self.retry_attempts, int) or not 1 <= self.retry_attempts <= 5:
            raise ValueError('retry_attempts must be between 1 and 5')

        self.logger.info(f"Supabase client initialized (schema: {self.schema})")

    def set_streamer(self, streamer: Optional[str]) -> None:
        """Set the streamer name for metric attribution"""
        self.streamer = streamer

    def get_chunk_details(self, chunk_id: str) -> Optional[Dict[str, Any]]:
        """Get chunk details with VOD and streamer information"""
        try:
            # Fetch chunk with joined VOD and streamer data
            response = (
                self.client.table("chunks")
                .select("*, vods(id, source, source_id, streamer_id, streamers(login), platform_accounts(display_name))")
                .eq("id", chunk_id)
                .single()
                .execute()
            )

            if response and response.data:
                chunk_data = response.data
                self.logger.info(f"Retrieved chunk details for {chunk_id}")

                # Flatten the response structure for easier access
                result = {
                    "id": chunk_data["id"],
                    "start_seconds": chunk_data["start_seconds"],
                    "end_seconds": chunk_data["end_seconds"],
                    "status": chunk_data.get("status"),
                    "vod_pk": chunk_data['vods']['id'],
                    "source": chunk_data['vods']['source'],
                    "vod_id": chunk_data["vods"]["source_id"]
                    if chunk_data.get("vods")
                    else None,
                    "streamer": chunk_data["vods"]["streamers"]["login"]
                    if chunk_data.get("vods") and chunk_data["vods"].get("streamers")
                    else None,
                }
                account = chunk_data['vods'].get('platform_accounts')
                if account:
                    result['streamer'] = account['display_name']
                return result
            else:
                self.logger.error(f"No chunk found with ID {chunk_id}")
                return None

        except Exception as e:
            self.logger.error(f"Failed to get chunk details: {e}")
            return None

    def update_chunk(self, chunk_id: str, status: str, **kwargs: Any) -> Any:
        """Update chunk status"""
        try:
            data = {"status": status, "updated_at": datetime.now(timezone.utc).isoformat()}

            # Add optional fields
            if "error" in kwargs:
                data["last_error"] = kwargs["error"]
            if "frames_processed" in kwargs:
                data["frames_processed"] = kwargs["frames_processed"]
            if "detections_count" in kwargs:
                data["detections_count"] = kwargs["detections_count"]
            if "processing_duration_ms" in kwargs:
                data["processing_duration_ms"] = kwargs["processing_duration_ms"]
            if "quality" in kwargs:
                data["quality"] = kwargs["quality"]
            if status in ("completed", "failed", "pending"):
                data["lease_expires_at"] = None
            if status == "completed":
                data["completed_at"] = datetime.now(timezone.utc).isoformat()
            elif status == "processing":
                data["started_at"] = datetime.now(timezone.utc).isoformat()
                data["last_error"] = None
                data["completed_at"] = None
            # Update chunk
            response = (
                self.client.table("chunks").update(data).eq("id", chunk_id).execute()
            )

            self.logger.info(f"Updated chunk {chunk_id} to {status}")
            return response

        except Exception as e:
            self.logger.error(f"Failed to update chunk: {e}")
            raise

    def _image_path(self, vod_id: str, timestamp: int, image_type: str = 'detection') -> str:
        prefix = f'test/{self.quality}/{vod_id}' if self.test_mode else str(vod_id)
        if image_type == 'detection':
            return f'{prefix}/{timestamp}.jpg'
        if self.test_mode:
            label = {'ocr_debug': 'preprocessed', 'emblem_boxes': 'boxes'}[image_type]
            return f'{prefix}/ocr_debug/{label}_{timestamp}.jpg'
        return f'{prefix}/{image_type}_{timestamp}.jpg'

    def upload_batch(self, matchups: List[Dict[str, Any]]) -> bool:
        """Save screenshots before publishing detections; retries reuse stable IDs."""
        started = time.monotonic()
        attrs = {'streamer': self.streamer or 'unknown', 'quality': self.quality}
        with create_span('supabase_upload', attributes={'batch.size': len(matchups)}):
            for attempt in range(self.retry_attempts):
                try:
                    records = []
                    vod_ids = {}
                    for matchup in matchups:
                        if not matchup.get('username'):
                            continue
                        source_id = str(matchup['vod_id'])
                        source = matchup.get('source', 'twitch')
                        identity = (source, source_id)
                        if matchup.get('vod_pk') is not None:
                            vod_ids[identity] = matchup['vod_pk']
                        if identity not in vod_ids:
                            response = (self.client.table('vods').select('id')
                                        .eq('source', source).eq('source_id', source_id).single().execute())
                            vod_ids[identity] = response.data['id']
                        timestamp = matchup['timestamp']
                        storage_id = source_id if source == 'twitch' else f'{source}/{source_id}'
                        image_path = None
                        for field, kind in [('frame_base64', 'detection'), ('ocr_debug_frame', 'ocr_debug'),
                                            ('emblem_boxes_frame', 'emblem_boxes')]:
                            if matchup.get(field):
                                self._upload_image(storage_id, timestamp, matchup[field], kind)
                                if kind == 'detection':
                                    image_path = f'/{self.storage_bucket}/{self._image_path(storage_id, timestamp)}'
                        records.append({
                            'id': str(uuid5(NAMESPACE_URL, f"bazaarghost:{matchup['chunk_id']}:{timestamp}")),
                            'vod_id': vod_ids[identity], 'chunk_id': matchup['chunk_id'],
                            'frame_time_seconds': timestamp, 'username': matchup['username'],
                            'confidence': matchup.get('confidence', 0), 'rank': matchup.get('detected_rank'),
                            'storage_path': image_path, 'no_right_edge': matchup.get('no_right_edge', False),
                            'truncated': matchup.get('truncated', False), 'igd': matchup.get('igd'),
                        })
                    if records:
                        (self.client.table('detections').upsert(records, on_conflict='id', ignore_duplicates=True).execute())
                        record_counter('detections_uploaded', len(records), attrs)
                    record_histogram('upload_duration', (time.monotonic() - started) * 1000, attrs)
                    return True
                except Exception as error:
                    self.logger.error('Batch upload attempt %s failed: %s', attempt + 1, error)
                    if attempt + 1 == self.retry_attempts:
                        record_counter('errors', 1, {**attrs, 'component': 'supabase', 'error_type': type(error).__name__})
                        raise
                    time.sleep(2 ** attempt)
        return False  # Constructor validation guarantees at least one attempt.

    def _upload_image(self, vod_id: str, timestamp: int, base64_data: str,
                      image_type: str = 'detection') -> None:
        try:
            self.client.storage.from_(self.storage_bucket).upload(
                path=self._image_path(vod_id, timestamp, image_type),
                file=base64.b64decode(base64_data, validate=True),
                file_options={'content-type': 'image/jpeg', 'upsert': 'true'},
            )
        except Exception:
            if image_type == 'detection':
                raise
            self.logger.warning('Optional debug image upload failed', exc_info=True)

    def delete_chunk_detections(self, chunk_id: str) -> int:
        """Clear this claimed chunk in pages, including known debug image paths."""
        count = 0
        while True:
            response = (self.client.table('detections').select('id,storage_path')
                        .eq('chunk_id', chunk_id).order('id').limit(500).execute())
            detections = response.data
            if not detections:
                return count
            paths = []
            for detection in detections:
                if not detection.get('storage_path'):
                    continue
                path = detection['storage_path'].lstrip('/').removeprefix(f'{self.storage_bucket}/')
                paths.append(path)
                prefix, filename = path.rsplit('/', 1)
                if prefix.startswith('test/'):
                    paths.extend([f'{prefix}/ocr_debug/preprocessed_{filename}', f'{prefix}/ocr_debug/boxes_{filename}'])
                else:
                    paths.extend([f'{prefix}/ocr_debug_{filename}', f'{prefix}/emblem_boxes_{filename}'])
            for offset in range(0, len(paths), 100):
                self.client.storage.from_(self.storage_bucket).remove(paths[offset:offset + 100])
            (self.client.table('detections').delete().in_('id', [row['id'] for row in detections]).execute())
            count += len(detections)

    def claim_chunk(self, chunk_id: str) -> bool:
        """Atomically acquire a pending/queued chunk before deleting prior results."""
        response = self.client.rpc('claim_sfde_chunk', {'p_chunk_id': chunk_id}).execute()
        return response.data is True
