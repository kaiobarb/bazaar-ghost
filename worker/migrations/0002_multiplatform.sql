-- Add independent platform identities without rewriting Twitch's public contracts.
-- The parent table is rebuilt with deferred FK validation; child records retain their IDs.
PRAGMA defer_foreign_keys=ON;
DROP VIEW detection_search;
DROP VIEW vod_embed_info;
DROP VIEW streamers_with_detections;
DROP VIEW vod_stats;
DROP VIEW streamer_detection_stats;
DROP TRIGGER chunks_status_changed;
CREATE TABLE platform_accounts (
 id TEXT PRIMARY KEY, source TEXT NOT NULL CHECK(source IN('youtube','bilibili')), source_id TEXT NOT NULL,
 display_name TEXT NOT NULL CHECK(length(display_name) BETWEEN 1 AND 200), streamer_id INTEGER REFERENCES streamers(id),
 sfde_profile_id INTEGER NOT NULL DEFAULT 1 REFERENCES sfde_profiles(id), processing_enabled INTEGER NOT NULL DEFAULT 0 CHECK(processing_enabled IN(0,1)),
 catalog_cursor INTEGER NOT NULL DEFAULT 1 CHECK(catalog_cursor>0), archive_cursor INTEGER NOT NULL DEFAULT 1 CHECK(archive_cursor>0),
 last_cataloged_at TEXT, created_at TEXT NOT NULL DEFAULT(strftime('%Y-%m-%dT%H:%M:%fZ','now')),
 UNIQUE(source,source_id), UNIQUE(id,source)
);
CREATE TABLE vods_next (
 id INTEGER PRIMARY KEY AUTOINCREMENT, streamer_id INTEGER REFERENCES streamers(id), source TEXT NOT NULL DEFAULT 'twitch' CHECK(source IN('twitch','youtube','bilibili')),
 source_id TEXT NOT NULL, title TEXT, duration_seconds INTEGER NOT NULL CHECK(duration_seconds>0), published_at TEXT,
 availability TEXT NOT NULL DEFAULT 'available' CHECK(availability IN('available','unavailable','unknown','checking','expired')),
 last_availability_check TEXT, unavailable_since TEXT, ready_for_processing INTEGER NOT NULL DEFAULT 0 CHECK(ready_for_processing IN(0,1)),
 bazaar_chapters TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(bazaar_chapters)),
 status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN('pending','processing','completed','failed','partial')),
 created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')), updated_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')), platform_account_id TEXT, sfde_profile_id INTEGER REFERENCES sfde_profiles(id), recorded_at TEXT,
 template_version TEXT NOT NULL DEFAULT 'auto' CHECK(template_version IN('auto','old','current')),
 content_kind TEXT NOT NULL DEFAULT 'archive' CHECK(content_kind IN('archive','upload')),
 notifications_enabled INTEGER NOT NULL DEFAULT 1 CHECK(notifications_enabled IN(0,1)),
 source_video_id TEXT, source_part_id TEXT, source_part_index INTEGER CHECK(source_part_index>0),
 FOREIGN KEY(platform_account_id,source) REFERENCES platform_accounts(id,source),
 CHECK((source='twitch' AND streamer_id IS NOT NULL) OR (source IN('youtube','bilibili') AND platform_account_id IS NOT NULL)),
 CHECK(source<>'bilibili' OR (source_video_id IS NOT NULL AND source_part_id IS NOT NULL AND source_part_index IS NOT NULL AND source_id=source_video_id||':'||source_part_id)),
 UNIQUE(source,source_id)
);
INSERT INTO vods_next(id,streamer_id,source,source_id,title,duration_seconds,published_at,availability,last_availability_check,unavailable_since,ready_for_processing,bazaar_chapters,status,created_at,updated_at) SELECT id,streamer_id,source,source_id,title,duration_seconds,published_at,availability,last_availability_check,unavailable_since,ready_for_processing,bazaar_chapters,status,created_at,updated_at FROM vods;
-- Keep the AUTOINCREMENT high watermark even when the highest historical VOD was deleted.
INSERT INTO sqlite_sequence(name,seq) SELECT 'vods_next',seq FROM sqlite_sequence WHERE name='vods' AND NOT EXISTS(SELECT 1 FROM sqlite_sequence WHERE name='vods_next');
UPDATE sqlite_sequence SET seq=max(seq,coalesce((SELECT seq FROM sqlite_sequence WHERE name='vods'),0)) WHERE name='vods_next';
DROP TABLE vods;
ALTER TABLE vods_next RENAME TO vods;
CREATE INDEX vods_streamer ON vods(streamer_id,published_at DESC);
CREATE INDEX vods_availability ON vods(source,availability,last_availability_check);
CREATE INDEX vods_account ON vods(platform_account_id,published_at DESC);
CREATE TRIGGER chunks_status_changed AFTER UPDATE OF status ON chunks BEGIN
 UPDATE vods SET status=CASE
 WHEN EXISTS(SELECT 1 FROM chunks WHERE vod_id=NEW.vod_id AND status IN('processing','queued')) THEN 'processing'
 WHEN NOT EXISTS(SELECT 1 FROM chunks WHERE vod_id=NEW.vod_id AND status NOT IN('completed','archived')) THEN 'completed'
 WHEN EXISTS(SELECT 1 FROM chunks WHERE vod_id=NEW.vod_id AND status='completed') THEN 'partial'
 WHEN EXISTS(SELECT 1 FROM chunks WHERE vod_id=NEW.vod_id AND status='failed') THEN 'failed'
 ELSE 'pending' END, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=NEW.vod_id;
END;
CREATE VIEW detection_search AS SELECT
 d.id AS detection_id,d.username,d.frame_time_seconds,d.confidence,d.rank,d.storage_path,d.no_right_edge,d.truncated,d.igd,d.created_at AS detection_created_at,
 v.id AS vod_id,v.source_id AS vod_source_id,v.title AS vod_title,v.published_at AS vod_published_at,v.duration_seconds AS vod_duration_seconds,v.availability AS vod_availability,
 strftime('%Y-%m-%dT%H:%M:%fZ',v.published_at,'+'||d.frame_time_seconds||' seconds') AS actual_timestamp,
 s.id AS streamer_id,s.login AS streamer_login,s.display_name AS streamer_display_name,s.profile_image_url AS streamer_avatar,
 'https://www.twitch.tv/videos/'||v.source_id||'?t='||d.frame_time_seconds||'s' AS vod_url,d.username_lower
 FROM detections d JOIN vods v ON v.id=d.vod_id JOIN streamers s ON s.id=v.streamer_id WHERE v.source='twitch' AND v.availability='available' AND d.confidence>0.7;
CREATE VIEW vod_embed_info AS SELECT v.id AS vod_id,v.source_id AS vod_source_id,v.title,v.published_at,v.duration_seconds,v.bazaar_chapters,v.availability,
 s.id AS streamer_id,s.login AS streamer_login,s.display_name AS streamer_display_name,s.profile_image_url AS streamer_avatar FROM vods v JOIN streamers s ON s.id=v.streamer_id WHERE v.source='twitch';
CREATE VIEW streamers_with_detections AS SELECT s.id AS streamer_id,s.login AS streamer_login,s.display_name AS streamer_display_name,s.profile_image_url AS streamer_avatar,s.processing_enabled,
 count(d.detection_id) AS detection_count,count(DISTINCT d.vod_id) AS vod_count,max(d.actual_timestamp) AS latest_detection_timestamp
 FROM streamers s JOIN detection_search d ON d.streamer_id=s.id GROUP BY s.id;
CREATE VIEW vod_stats AS SELECT v.*,s.display_name AS streamer,
 (SELECT count(*) FROM detections d WHERE d.vod_id=v.id) AS total_detections,
 (SELECT avg(confidence) FROM detections d WHERE d.vod_id=v.id) AS avg_confidence,
 (SELECT count(*) FROM chunks c WHERE c.vod_id=v.id) AS chunks,
 (SELECT CASE WHEN count(DISTINCT quality)=1 AND v.status!='pending' THEN max(quality) END FROM chunks c WHERE c.vod_id=v.id) AS quality
 FROM vods v JOIN streamers s ON s.id=v.streamer_id WHERE v.source='twitch';
CREATE VIEW streamer_detection_stats AS SELECT s.id AS streamer_id,s.login,s.display_name,count(d.id) AS total_detections,avg(d.confidence) AS avg_confidence,
 count(d.id) FILTER(WHERE d.no_right_edge=1) AS no_right_edge_detections,
 count(DISTINCT v.id) FILTER(WHERE v.status='processing') AS vods_processing,count(DISTINCT v.id) FILTER(WHERE v.status='completed') AS vods_completed,
 count(DISTINCT v.id) FILTER(WHERE v.status='failed') AS vods_failed,count(DISTINCT v.id) FILTER(WHERE v.status='partial') AS vods_partial,
 count(DISTINCT v.id) FILTER(WHERE v.status='pending') AS vods_pending,count(DISTINCT v.id) AS total_vods,
 coalesce(round(1.0*count(d.id)/nullif(count(DISTINCT v.id),0),2),0) AS avg_detections_per_vod
 FROM streamers s LEFT JOIN vods v ON v.streamer_id=s.id AND v.source='twitch' LEFT JOIN detections d ON d.vod_id=v.id GROUP BY s.id;

CREATE VIEW vod_processing_context AS SELECT v.*,
 CASE WHEN v.platform_account_id IS NOT NULL THEN a.processing_enabled ELSE s.processing_enabled END AS processing_enabled,
 coalesce(v.sfde_profile_id,a.sfde_profile_id,s.sfde_profile_id,1) AS effective_profile_id,
 coalesce(a.display_name,s.display_name,s.login) AS creator_name,
 CASE WHEN v.template_version='old' THEN 1 WHEN v.template_version='current' THEN 0
 ELSE coalesce((CASE WHEN v.source='twitch' THEN v.published_at ELSE v.recorded_at END)<'2025-08-12T00:00:00.000Z',0) END AS old_templates
 FROM vods v LEFT JOIN platform_accounts a ON a.id=v.platform_account_id LEFT JOIN streamers s ON s.id=v.streamer_id;
CREATE VIEW video_detections AS SELECT d.id AS detection_id,d.username,d.confidence,d.rank,d.frame_time_seconds,
 d.storage_path,d.no_right_edge,d.truncated,d.igd,d.created_at AS indexed_at,
 v.id AS vod_id,v.source,v.source_id,v.source_video_id,v.source_part_id,v.source_part_index,v.title,v.published_at,v.recorded_at,
 v.platform_account_id,v.streamer_id,coalesce(a.display_name,s.display_name,s.login) AS creator_name,
 CASE v.source
 WHEN 'twitch' THEN 'https://www.twitch.tv/videos/'||v.source_id||'?t='||d.frame_time_seconds||'s'
 WHEN 'youtube' THEN 'https://www.youtube.com/watch?v='||v.source_id||'&t='||d.frame_time_seconds||'s'
 WHEN 'bilibili' THEN 'https://www.bilibili.com/video/'||v.source_video_id||'/?p='||v.source_part_index||'&t='||d.frame_time_seconds END AS video_url,
 CASE v.source
 WHEN 'youtube' THEN 'https://www.youtube.com/embed/'||v.source_id||'?start='||d.frame_time_seconds
 WHEN 'bilibili' THEN 'https://player.bilibili.com/player.html?bvid='||v.source_video_id||'&cid='||v.source_part_id||'&t='||d.frame_time_seconds END AS embed_url,
 strftime('%Y-%m-%dT%H:%M:%fZ',CASE WHEN v.source='twitch' THEN coalesce(v.recorded_at,v.published_at) ELSE v.recorded_at END,'+'||d.frame_time_seconds||' seconds') AS recorded_timestamp
 FROM detections d JOIN vods v ON v.id=d.vod_id LEFT JOIN platform_accounts a ON a.id=v.platform_account_id
 LEFT JOIN streamers s ON s.id=v.streamer_id WHERE v.availability='available' AND d.confidence>0.7;
DROP TRIGGER detection_outbox;
CREATE TRIGGER detection_outbox AFTER INSERT ON detections WHEN NEW.confidence>0.7 AND EXISTS(
 SELECT 1 FROM vods WHERE id=NEW.vod_id AND source='twitch' AND notifications_enabled=1
) BEGIN INSERT INTO notification_outbox(detection_id) VALUES(NEW.id); END;
CREATE TABLE matchup_groups(id TEXT PRIMARY KEY,evidence TEXT NOT NULL CHECK(length(trim(evidence)) BETWEEN 10 AND 4000),created_at TEXT NOT NULL DEFAULT(strftime('%Y-%m-%dT%H:%M:%fZ','now')));
CREATE TABLE matchup_appearances(detection_id TEXT PRIMARY KEY REFERENCES detections(id) ON DELETE CASCADE,matchup_id TEXT NOT NULL REFERENCES matchup_groups(id),linked_at TEXT NOT NULL DEFAULT(strftime('%Y-%m-%dT%H:%M:%fZ','now')));
CREATE INDEX appearances_group ON matchup_appearances(matchup_id);
CREATE TABLE platform_ingestion_jobs (
 id TEXT PRIMARY KEY,source TEXT NOT NULL CHECK(source IN('youtube','bilibili')),kind TEXT NOT NULL CHECK(kind IN('account','video','discovery')),source_id TEXT NOT NULL,
 account_id TEXT,status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN('pending','waiting','processing','completed','skipped')),
 next_attempt_at TEXT NOT NULL DEFAULT(strftime('%Y-%m-%dT%H:%M:%fZ','now')),last_attempt_at TEXT,completed_at TEXT,attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts>=0),last_error TEXT,
 state TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(state) AND json_type(state)='object'),lease_token TEXT,lease_expires_at TEXT,
 rerun_requested INTEGER NOT NULL DEFAULT 0 CHECK(rerun_requested IN(0,1)),created_at TEXT NOT NULL DEFAULT(strftime('%Y-%m-%dT%H:%M:%fZ','now')),
 UNIQUE(source,kind,source_id),FOREIGN KEY(account_id,source) REFERENCES platform_accounts(id,source) ON DELETE CASCADE,CHECK(kind<>'account' OR account_id IS NOT NULL)
);
CREATE INDEX ingestion_due ON platform_ingestion_jobs(next_attempt_at,status);
CREATE TABLE youtube_websub_subscriptions(account_id TEXT PRIMARY KEY REFERENCES platform_accounts(id) ON DELETE CASCADE,
 callback_token TEXT NOT NULL CHECK(length(callback_token)=64),secret TEXT NOT NULL CHECK(length(secret)=64),requested_at TEXT,confirmed_at TEXT,lease_expires_at TEXT,last_error TEXT);
CREATE TABLE youtube_websub_deliveries(account_id TEXT NOT NULL REFERENCES platform_accounts(id) ON DELETE CASCADE,body_sha256 TEXT NOT NULL CHECK(length(body_sha256)=64),received_at TEXT NOT NULL DEFAULT(strftime('%Y-%m-%dT%H:%M:%fZ','now')),PRIMARY KEY(account_id,body_sha256));
CREATE INDEX websub_delivery_age ON youtube_websub_deliveries(received_at);
PRAGMA defer_foreign_keys=OFF;
-- Transaction-local assertions are inserted and removed in the same D1 batch.
CREATE TABLE mutation_checks(id TEXT PRIMARY KEY,ok INTEGER NOT NULL CONSTRAINT valid_mutation CHECK(ok=1));
CREATE TABLE matchup_review_events(id TEXT PRIMARY KEY,matchup_id TEXT NOT NULL REFERENCES matchup_groups(id),action TEXT NOT NULL CHECK(action IN('link','unlink')),detection_ids TEXT NOT NULL CHECK(json_valid(detection_ids)),evidence TEXT NOT NULL,created_at TEXT NOT NULL DEFAULT(strftime('%Y-%m-%dT%H:%M:%fZ','now')));
