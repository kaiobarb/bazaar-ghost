-- Preserve the source-video identity contract for single-part platforms.
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
 LEFT JOIN streamers s ON s.id=v.streamer_id WHERE v.availability='available' AND d.confidence>0.7;
