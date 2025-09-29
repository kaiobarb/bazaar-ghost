"""
Supabase client module - Handles all Supabase interactions
"""

import os
import time
import logging
from typing import List, Dict, Any, Optional
from supabase import create_client, Client
import requests
from datetime import datetime, timedelta

class SupabaseClient:
    """Handle Supabase operations for SFOT processor"""
    
    def __init__(self, config: Dict[str, Any]):
        """Initialize Supabase client"""
        self.config = config
        self.logger = logging.getLogger('sfot.supabase')
        
        # Get credentials from environment
        url = os.getenv('SUPABASE_URL', config.get('supabase', {}).get('url'))
        key = os.getenv('SUPABASE_SECRET_KEY', config.get('supabase', {}).get('secret_key'))

        if not url or not key:
            raise ValueError("SUPABASE_URL and SUPABASE_SECRET_KEY must be set")
        
        # Initialize client
        self.client: Client = create_client(url, key)
        self.storage_bucket = config['supabase']['storage_bucket']
        
        # Batch processing settings
        self.batch_size = config['supabase']['batch_size']
        self.retry_attempts = config['supabase']['retry_attempts']
        
        self.logger.info("Supabase client initialized")
    
    def update_chunk(self, chunk_id: str, status: str, **kwargs):
        """Update chunk status"""
        try:
            data = {
                'status': status,
                'updated_at': datetime.utcnow().isoformat()
            }
            
            # Add optional fields
            if 'error' in kwargs:
                data['last_error'] = kwargs['error']
            if 'frames_processed' in kwargs:
                data['frames_processed'] = kwargs['frames_processed']
            if 'detections_count' in kwargs:
                data['detections_count'] = kwargs['detections_count']
            if status == 'completed':
                data['completed_at'] = datetime.utcnow().isoformat()
            elif status == 'processing':
                data['started_at'] = datetime.utcnow().isoformat()
            
            # Update chunk
            response = self.client.table('chunks').update(data).eq('id', chunk_id).execute()
            
            self.logger.info(f"Updated chunk {chunk_id} to {status}")
            return response
            
        except Exception as e:
            self.logger.error(f"Failed to update chunk: {e}")
            return None
    
    def update_chunk_progress(self, chunk_id: str, frames_processed: int, detections_count: int):
        """Update chunk progress metrics"""
        try:
            data = {
                'frames_processed': frames_processed,
                'detections_count': detections_count,
                'updated_at': datetime.utcnow().isoformat()
            }
            
            response = self.client.table('chunks').update(data).eq('id', chunk_id).execute()
            return response
            
        except Exception as e:
            self.logger.error(f"Failed to update chunk progress: {e}")
            return None
    
    def upload_batch(self, matchups: List[Dict[str, Any]]):
        """Upload batch of detection results"""
        for attempt in range(self.retry_attempts):
            try:
                # Prepare batch data
                batch_data = []
                image_uploads = []
                
                # Cache for VOD ID lookups
                vod_id_cache = {}
                
                for matchup in matchups:
                    # Look up the actual database vod_id from source_id if not cached
                    source_id = str(matchup['vod_id'])
                    if source_id not in vod_id_cache:
                        try:
                            vod_response = self.client.table('vods').select('id').eq('source_id', source_id).single().execute()
                            vod_id_cache[source_id] = vod_response.data['id']
                        except Exception as e:
                            self.logger.error(f"Failed to find VOD with source_id {source_id}: {e}")
                            continue
                    
                    actual_vod_id = vod_id_cache[source_id]
                    
                    # Create detection record if username was extracted
                    if matchup.get('username'):
                        record = {
                            'vod_id': actual_vod_id,  # Use the database ID
                            'frame_time_seconds': matchup['timestamp'],
                            'username': matchup['username'],
                            'confidence': matchup.get('confidence', 0),
                            # chunk_id would be set if we had it
                            # 'chunk_id': matchup.get('chunk_id'),
                        }
                        batch_data.append(record)
                    
                    # Queue image upload if present
                    if 'frame_base64' in matchup:
                        image_uploads.append({
                            'vod_id': matchup['vod_id'],
                            'timestamp': matchup['timestamp'],
                            'data': matchup['frame_base64'],
                            'type': 'detection'
                        })
                    
                    # Queue OCR debug frame upload if present
                    if 'ocr_debug_frame' in matchup:
                        image_uploads.append({
                            'vod_id': matchup['vod_id'],
                            'timestamp': matchup['timestamp'],
                            'data': matchup['ocr_debug_frame'],
                            'type': 'ocr_debug'
                        })
                
                # Insert detection records
                if batch_data:
                    response = self.client.table('detections').insert(batch_data).execute()
                    self.logger.info(f"Uploaded {len(batch_data)} detections")
                
                # Upload images to storage
                for img in image_uploads:
                    self._upload_image(img['vod_id'], img['timestamp'], img['data'], img.get('type', 'detection'))
                
                return True
                
            except Exception as e:
                self.logger.error(f"Batch upload attempt {attempt + 1} failed: {e}")
                if attempt < self.retry_attempts - 1:
                    time.sleep(2 ** attempt)  # Exponential backoff
                else:
                    raise
    
    def _upload_image(self, vod_id: str, timestamp: int, base64_data: str, image_type: str = 'detection'):
        """Upload matchup screenshot to storage"""
        try:
            # Generate filename based on type
            if image_type == 'detection':
                filename = f"{vod_id}/{timestamp}.jpg"
            else:
                # For OCR debug frames
                filename = f"{vod_id}/{image_type}/{timestamp}.jpg"
            
            # Decode base64
            import base64
            image_data = base64.b64decode(base64_data)
            
            # Upload to storage
            response = self.client.storage.from_(self.storage_bucket).upload(
                path=filename,
                file=image_data,
                file_options={"content-type": "image/jpeg"}
            )
            
            self.logger.debug(f"Uploaded image: {filename}")
            return response
            
        except Exception as e:
            self.logger.error(f"Image upload failed: {e}")
            return None
    
    def get_pending_chunks(self, limit: int = 10) -> List[Dict[str, Any]]:
        """Get pending chunks for processing"""
        try:
            response = self.client.table('chunks')\
                .select('*')\
                .eq('status', 'pending')\
                .order('priority', desc=True)\
                .order('scheduled_for')\
                .limit(limit)\
                .execute()
            
            return response.data if response else []
            
        except Exception as e:
            self.logger.error(f"Failed to get pending chunks: {e}")
            return []
    
    def claim_chunk(self, chunk_id: str, worker_id: str) -> bool:
        """Claim a chunk for processing"""
        try:
            # Atomic update to claim chunk
            response = self.client.table('chunks')\
                .update({
                    'status': 'processing',
                    'worker_id': worker_id,
                    'started_at': datetime.utcnow().isoformat(),
                    'lease_expires_at': (datetime.utcnow() + timedelta(minutes=30)).isoformat()
                })\
                .eq('id', chunk_id)\
                .eq('status', 'pending')\
                .execute()
            
            # Check if update was successful
            if response.data and len(response.data) > 0:
                self.logger.info(f"Claimed chunk {chunk_id}")
                return True
            return False
            
        except Exception as e:
            self.logger.error(f"Failed to claim chunk: {e}")
            return False