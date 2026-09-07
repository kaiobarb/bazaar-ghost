-- Moderation belongs to the durable video anchor, not an OCR publication UUID.
-- Raw detections and processing statistics remain available to operational workflows.
DROP VIEW detection_search;
CREATE VIEW detection_search AS SELECT
 d.id AS detection_id,d.username,d.frame_time_seconds,d.confidence,d.rank,d.storage_path,d.no_right_edge,d.truncated,d.igd,d.created_at AS detection_created_at,
 v.id AS vod_id,v.source_id AS vod_source_id,v.title AS vod_title,v.published_at AS vod_published_at,v.duration_seconds AS vod_duration_seconds,v.availability AS vod_availability,
 strftime('%Y-%m-%dT%H:%M:%fZ',v.published_at,'+'||d.frame_time_seconds||' seconds') AS actual_timestamp,
 s.id AS streamer_id,s.login AS streamer_login,s.display_name AS streamer_display_name,s.profile_image_url AS streamer_avatar,
 'https://www.twitch.tv/videos/'||v.source_id||'?t='||d.frame_time_seconds||'s' AS vod_url,d.username_lower
 FROM detections d JOIN vods v ON v.id=d.vod_id JOIN streamers s ON s.id=v.streamer_id
 WHERE v.source='twitch' AND v.availability='available' AND d.confidence>0.7
 AND NOT EXISTS(SELECT 1 FROM clips c WHERE c.vod_id=d.vod_id AND c.anchor_seconds=d.frame_time_seconds AND c.status='hidden');

DROP VIEW video_detections;
CREATE VIEW video_detections AS SELECT d.id AS detection_id,d.username,d.confidence,d.rank,d.frame_time_seconds,
 d.storage_path,d.no_right_edge,d.truncated,d.igd,d.created_at AS indexed_at,
 v.id AS vod_id,v.source,v.source_id,coalesce(v.source_video_id,v.source_id) AS source_video_id,v.source_part_id,v.source_part_index,v.title,v.published_at,v.recorded_at,
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
 LEFT JOIN streamers s ON s.id=v.streamer_id WHERE v.availability='available' AND d.confidence>0.7
 AND NOT EXISTS(SELECT 1 FROM clips c WHERE c.vod_id=d.vod_id AND c.anchor_seconds=d.frame_time_seconds AND c.status='hidden');

-- A tiny primary-D1 revision invalidates edge caches without storing private data or
-- relying on eventually-consistent invalidation. Existing cached versions expire normally.
CREATE TABLE public_cache_state(id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL CHECK(revision>=0));
INSERT INTO public_cache_state(id,revision) VALUES(1,0);
CREATE TRIGGER clip_visibility_revision AFTER UPDATE OF status ON clips WHEN NEW.status!=OLD.status BEGIN
  UPDATE public_cache_state SET revision=revision+1 WHERE id=1;
END;
CREATE TRIGGER clip_hidden_insert_revision AFTER INSERT ON clips WHEN NEW.status='hidden' BEGIN
  UPDATE public_cache_state SET revision=revision+1 WHERE id=1;
END;
CREATE TRIGGER clip_hidden_delete_revision AFTER DELETE ON clips WHEN OLD.status='hidden' BEGIN
  UPDATE public_cache_state SET revision=revision+1 WHERE id=1;
END;
CREATE INDEX detections_storage_path ON detections(storage_path);
