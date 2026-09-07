CREATE TABLE sfde_profiles (
 id INTEGER PRIMARY KEY, profile_name TEXT NOT NULL UNIQUE, crop_region TEXT NOT NULL CHECK(json_array_length(crop_region)=4),
 scale REAL NOT NULL DEFAULT 1, custom_edge REAL, opaque_edge INTEGER NOT NULL DEFAULT 1 CHECK(opaque_edge IN(0,1)),
 igd_crop_region TEXT CHECK(igd_crop_region IS NULL OR json_array_length(igd_crop_region)=4), from_date TEXT, to_date TEXT,
 created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')), updated_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE TABLE streamers (
 id INTEGER PRIMARY KEY, login TEXT NOT NULL UNIQUE COLLATE NOCASE, display_name TEXT, profile_image_url TEXT,
 processing_enabled INTEGER NOT NULL DEFAULT 1 CHECK(processing_enabled IN(0,1)), sfde_profile_id INTEGER NOT NULL DEFAULT 1 REFERENCES sfde_profiles(id),
 oldest_vod TEXT, num_vods INTEGER DEFAULT 0, num_bazaar_vods INTEGER DEFAULT 0, has_vods INTEGER DEFAULT 0,
 eventsub_subscription_id TEXT, created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')), updated_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE TABLE vods (
 id INTEGER PRIMARY KEY AUTOINCREMENT, streamer_id INTEGER NOT NULL REFERENCES streamers(id), source TEXT NOT NULL DEFAULT 'twitch' CHECK(source='twitch'),
 source_id TEXT NOT NULL, title TEXT, duration_seconds INTEGER NOT NULL CHECK(duration_seconds>0), published_at TEXT,
 availability TEXT NOT NULL DEFAULT 'available' CHECK(availability IN('available','unavailable','unknown','checking','expired')),
 last_availability_check TEXT, unavailable_since TEXT, ready_for_processing INTEGER NOT NULL DEFAULT 0 CHECK(ready_for_processing IN(0,1)),
 bazaar_chapters TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(bazaar_chapters)),
 status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN('pending','processing','completed','failed','partial')),
 created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')), updated_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')), UNIQUE(source,source_id)
);
CREATE INDEX vods_streamer ON vods(streamer_id,published_at DESC);
CREATE INDEX vods_availability ON vods(availability,last_availability_check);
CREATE TABLE chunks (
 id TEXT PRIMARY KEY, vod_id INTEGER NOT NULL REFERENCES vods(id), start_seconds INTEGER NOT NULL CHECK(start_seconds>=0),
 end_seconds INTEGER NOT NULL CHECK(end_seconds>start_seconds), chunk_index INTEGER NOT NULL,
 status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN('pending','queued','processing','completed','failed','archived')), source TEXT DEFAULT 'vod',
 queued_at TEXT, started_at TEXT, completed_at TEXT, attempt_count INTEGER NOT NULL DEFAULT 0, last_error TEXT,
 frames_processed INTEGER NOT NULL DEFAULT 0 CHECK(frames_processed>=0), detections_count INTEGER NOT NULL DEFAULT 0 CHECK(detections_count>=0), processing_duration_ms INTEGER,
 priority INTEGER DEFAULT 0, scheduled_for TEXT, lease_expires_at TEXT, claim_token TEXT, quality TEXT,
 created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')), updated_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
 UNIQUE(vod_id,start_seconds,end_seconds), UNIQUE(vod_id,chunk_index)
);
CREATE INDEX chunks_status ON chunks(status,lease_expires_at);
-- D1 batch is transactional. Reject concurrent plans that would overlap existing work.
CREATE TRIGGER chunks_no_overlap BEFORE INSERT ON chunks WHEN EXISTS(
 SELECT 1 FROM chunks WHERE vod_id=NEW.vod_id AND start_seconds<NEW.end_seconds AND end_seconds>NEW.start_seconds
) BEGIN SELECT RAISE(ABORT,'overlapping chunk'); END;
CREATE TRIGGER chunks_status_changed AFTER UPDATE OF status ON chunks BEGIN
 UPDATE vods SET status=CASE
 WHEN EXISTS(SELECT 1 FROM chunks WHERE vod_id=NEW.vod_id AND status IN('processing','queued')) THEN 'processing'
 WHEN NOT EXISTS(SELECT 1 FROM chunks WHERE vod_id=NEW.vod_id AND status NOT IN('completed','archived')) THEN 'completed'
 WHEN EXISTS(SELECT 1 FROM chunks WHERE vod_id=NEW.vod_id AND status='completed') THEN 'partial'
 WHEN EXISTS(SELECT 1 FROM chunks WHERE vod_id=NEW.vod_id AND status='failed') THEN 'failed'
 ELSE 'pending' END, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=NEW.vod_id;
END;
CREATE TABLE search_names (name TEXT PRIMARY KEY, gram_count INTEGER NOT NULL);
CREATE TABLE search_grams (gram TEXT NOT NULL, name TEXT NOT NULL REFERENCES search_names(name) ON DELETE CASCADE, PRIMARY KEY(gram,name)) WITHOUT ROWID;
CREATE INDEX grams_name ON search_grams(name);
CREATE TABLE detections (
 id TEXT PRIMARY KEY, chunk_id TEXT NOT NULL REFERENCES chunks(id), vod_id INTEGER NOT NULL REFERENCES vods(id), username TEXT NOT NULL,
 username_lower TEXT NOT NULL REFERENCES search_names(name), confidence REAL CHECK(confidence BETWEEN 0 AND 1),
 rank TEXT CHECK(rank IN('bronze','silver','gold','diamond','legend')), frame_time_seconds INTEGER NOT NULL,
 storage_path TEXT, no_right_edge INTEGER DEFAULT 0 CHECK(no_right_edge IN(0,1)), truncated INTEGER DEFAULT 0 CHECK(truncated IN(0,1)),
 igd INTEGER CHECK(igd BETWEEN 1 AND 20), created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
 UNIQUE(chunk_id,frame_time_seconds)
);
CREATE INDEX detections_name ON detections(username_lower, vod_id);
CREATE INDEX detections_vod ON detections(vod_id,frame_time_seconds);
CREATE INDEX detections_chunk ON detections(chunk_id);
CREATE TRIGGER detection_chunk_matches BEFORE INSERT ON detections WHEN NOT EXISTS(
 SELECT 1 FROM chunks WHERE id=NEW.chunk_id AND vod_id=NEW.vod_id AND NEW.frame_time_seconds>=start_seconds AND NEW.frame_time_seconds<end_seconds
) BEGIN SELECT RAISE(ABORT,'detection outside chunk'); END;
CREATE TABLE notification_subscriptions (
 id INTEGER PRIMARY KEY AUTOINCREMENT, discord_user_id TEXT NOT NULL, username TEXT NOT NULL, username_lower TEXT NOT NULL,
 enabled INTEGER NOT NULL DEFAULT 1, notify_type TEXT NOT NULL DEFAULT 'both' CHECK(notify_type IN('dm','server','both')), guild_id TEXT,
 notification_count INTEGER NOT NULL DEFAULT 0, created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')), UNIQUE(discord_user_id,username_lower)
);
CREATE INDEX subscriptions_username ON notification_subscriptions(username_lower,enabled);
CREATE TABLE server_channels (guild_id TEXT PRIMARY KEY, channel_id TEXT NOT NULL, created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')));
-- Outbox survives a crash between committing a detection and publishing to Queues.
CREATE TABLE notification_outbox (detection_id TEXT PRIMARY KEY REFERENCES detections(id) ON DELETE CASCADE, sent_at TEXT);
CREATE TRIGGER detection_outbox AFTER INSERT ON detections WHEN NEW.confidence>0.7 BEGIN
 INSERT INTO notification_outbox(detection_id) VALUES(NEW.id);
END;
CREATE TABLE notification_deliveries (detection_id TEXT NOT NULL REFERENCES detections(id) ON DELETE CASCADE, destination TEXT NOT NULL, sent_at TEXT, PRIMARY KEY(detection_id,destination));
CREATE TABLE webhook_events (id TEXT PRIMARY KEY, created_at TEXT NOT NULL);
CREATE TABLE chat_mentions (id TEXT PRIMARY KEY, vod_id INTEGER NOT NULL REFERENCES vods(id), username TEXT, message TEXT, offset_seconds INTEGER, created_at TEXT);
CREATE TABLE processing_config (key TEXT PRIMARY KEY,value TEXT NOT NULL,description TEXT,created_at TEXT,updated_at TEXT);
CREATE TABLE cataloger_runs (id TEXT PRIMARY KEY,run_type TEXT,started_at TEXT,completed_at TEXT,streamers_discovered INTEGER DEFAULT 0,streamers_updated INTEGER DEFAULT 0,vods_discovered INTEGER DEFAULT 0,chunks_created INTEGER DEFAULT 0,errors TEXT DEFAULT '[]',status TEXT DEFAULT 'running',metadata TEXT DEFAULT '{}');
CREATE VIEW detection_search AS SELECT
 d.id AS detection_id,d.username,d.frame_time_seconds,d.confidence,d.rank,d.storage_path,d.no_right_edge,d.truncated,d.igd,d.created_at AS detection_created_at,
 v.id AS vod_id,v.source_id AS vod_source_id,v.title AS vod_title,v.published_at AS vod_published_at,v.duration_seconds AS vod_duration_seconds,v.availability AS vod_availability,
 strftime('%Y-%m-%dT%H:%M:%fZ',v.published_at,'+'||d.frame_time_seconds||' seconds') AS actual_timestamp,
 s.id AS streamer_id,s.login AS streamer_login,s.display_name AS streamer_display_name,s.profile_image_url AS streamer_avatar,
 'https://www.twitch.tv/videos/'||v.source_id||'?t='||d.frame_time_seconds||'s' AS vod_url,d.username_lower
 FROM detections d JOIN vods v ON v.id=d.vod_id JOIN streamers s ON s.id=v.streamer_id WHERE v.availability='available' AND d.confidence>0.7;
CREATE VIEW vod_embed_info AS SELECT v.id AS vod_id,v.source_id AS vod_source_id,v.title,v.published_at,v.duration_seconds,v.bazaar_chapters,v.availability,
 s.id AS streamer_id,s.login AS streamer_login,s.display_name AS streamer_display_name,s.profile_image_url AS streamer_avatar FROM vods v JOIN streamers s ON s.id=v.streamer_id;
CREATE VIEW streamers_with_detections AS SELECT s.id AS streamer_id,s.login AS streamer_login,s.display_name AS streamer_display_name,s.profile_image_url AS streamer_avatar,s.processing_enabled,
 count(d.detection_id) AS detection_count,count(DISTINCT d.vod_id) AS vod_count,max(d.actual_timestamp) AS latest_detection_timestamp
 FROM streamers s JOIN detection_search d ON d.streamer_id=s.id GROUP BY s.id;
CREATE VIEW vod_stats AS SELECT v.*,s.display_name AS streamer,
 (SELECT count(*) FROM detections d WHERE d.vod_id=v.id) AS total_detections,
 (SELECT avg(confidence) FROM detections d WHERE d.vod_id=v.id) AS avg_confidence,
 (SELECT count(*) FROM chunks c WHERE c.vod_id=v.id) AS chunks,
 (SELECT CASE WHEN count(DISTINCT quality)=1 AND v.status!='pending' THEN max(quality) END FROM chunks c WHERE c.vod_id=v.id) AS quality
 FROM vods v JOIN streamers s ON s.id=v.streamer_id;
CREATE VIEW streamer_detection_stats AS SELECT s.id AS streamer_id,s.login,s.display_name,count(d.id) AS total_detections,avg(d.confidence) AS avg_confidence,
 count(d.id) FILTER(WHERE d.no_right_edge=1) AS no_right_edge_detections,
 count(DISTINCT v.id) FILTER(WHERE v.status='processing') AS vods_processing,count(DISTINCT v.id) FILTER(WHERE v.status='completed') AS vods_completed,
 count(DISTINCT v.id) FILTER(WHERE v.status='failed') AS vods_failed,count(DISTINCT v.id) FILTER(WHERE v.status='partial') AS vods_partial,
 count(DISTINCT v.id) FILTER(WHERE v.status='pending') AS vods_pending,count(DISTINCT v.id) AS total_vods,
 coalesce(round(1.0*count(d.id)/nullif(count(DISTINCT v.id),0),2),0) AS avg_detections_per_vod
 FROM streamers s LEFT JOIN vods v ON v.streamer_id=s.id LEFT JOIN detections d ON d.vod_id=v.id GROUP BY s.id;
