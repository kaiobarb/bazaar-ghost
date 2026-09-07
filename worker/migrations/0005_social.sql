-- Clips are durable video anchors. OCR rows may disappear or be replaced without
-- changing a clip ID or deleting its likes, bookmarks, comments, or reports.
CREATE TABLE clips (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  vod_id INTEGER NOT NULL REFERENCES vods(id) ON DELETE CASCADE,
  anchor_seconds INTEGER NOT NULL CHECK(anchor_seconds>=0),
  current_detection_id TEXT UNIQUE REFERENCES detections(id) ON DELETE SET NULL,
  status TEXT NOT NULL DEFAULT 'visible' CHECK(status IN('visible','hidden')),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  UNIQUE(vod_id,anchor_seconds)
);
CREATE INDEX clips_visible ON clips(status,id);
CREATE TRIGGER clip_anchor_immutable BEFORE UPDATE OF vod_id,anchor_seconds ON clips
WHEN NEW.vod_id!=OLD.vod_id OR NEW.anchor_seconds!=OLD.anchor_seconds
BEGIN SELECT RAISE(ABORT,'Clip anchors are immutable'); END;
CREATE TRIGGER clip_detection_insert_guard BEFORE INSERT ON clips
WHEN NEW.current_detection_id IS NOT NULL AND NOT EXISTS(
  SELECT 1 FROM detections WHERE id=NEW.current_detection_id AND vod_id=NEW.vod_id AND frame_time_seconds=NEW.anchor_seconds)
BEGIN SELECT RAISE(ABORT,'Clip detection must match exact anchor'); END;
CREATE TRIGGER clip_detection_update_guard BEFORE UPDATE OF current_detection_id ON clips
WHEN NEW.current_detection_id IS NOT NULL AND NOT EXISTS(
  SELECT 1 FROM detections WHERE id=NEW.current_detection_id AND vod_id=NEW.vod_id AND frame_time_seconds=NEW.anchor_seconds)
BEGIN SELECT RAISE(ABORT,'Clip detection must match exact anchor'); END;
INSERT INTO clips(vod_id,anchor_seconds,current_detection_id)
SELECT vod_id,frame_time_seconds,id FROM detections WHERE confidence>0.7 ORDER BY vod_id,frame_time_seconds;
CREATE TRIGGER detection_clip_insert AFTER INSERT ON detections WHEN NEW.confidence>0.7 BEGIN
  INSERT INTO clips(vod_id,anchor_seconds,current_detection_id) VALUES(NEW.vod_id,NEW.frame_time_seconds,NEW.id)
  ON CONFLICT(vod_id,anchor_seconds) DO UPDATE SET current_detection_id=excluded.current_detection_id;
END;
CREATE TRIGGER detection_clip_update AFTER UPDATE OF vod_id,frame_time_seconds,confidence ON detections BEGIN
  UPDATE clips SET current_detection_id=NULL WHERE current_detection_id=OLD.id;
  INSERT INTO clips(vod_id,anchor_seconds,current_detection_id)
  SELECT NEW.vod_id,NEW.frame_time_seconds,NEW.id WHERE NEW.confidence>0.7
  ON CONFLICT(vod_id,anchor_seconds) DO UPDATE SET current_detection_id=excluded.current_detection_id;
END;

CREATE TABLE clip_likes (
  clip_id INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  PRIMARY KEY(clip_id,user_id)
) WITHOUT ROWID;
CREATE INDEX clip_likes_user ON clip_likes(user_id,clip_id);
-- Favorite and heart are API aliases for this SAME private bookmark.
CREATE TABLE clip_favorites (
  user_id TEXT NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  clip_id INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  PRIMARY KEY(user_id,clip_id)
) WITHOUT ROWID;
CREATE INDEX clip_favorites_clip ON clip_favorites(clip_id);
CREATE TABLE clip_comments (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL UNIQUE,
  clip_id INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
  author_id TEXT NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  body TEXT,
  original_body_hash TEXT NOT NULL,
  version INTEGER NOT NULL DEFAULT 1 CHECK(version>0),
  status TEXT NOT NULL DEFAULT 'visible' CHECK(status IN('visible','hidden','deleted')),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  CHECK((status='deleted' AND body IS NULL) OR (status!='deleted' AND body IS NOT NULL AND length(body) BETWEEN 1 AND 2000))
);
CREATE INDEX clip_comments_public ON clip_comments(clip_id,status,sequence);
CREATE INDEX clip_comments_author ON clip_comments(author_id);
CREATE TABLE social_reports (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL UNIQUE,
  reporter_id TEXT NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  clip_id INTEGER REFERENCES clips(id) ON DELETE CASCADE,
  comment_id TEXT REFERENCES clip_comments(id) ON DELETE CASCADE,
  reason TEXT NOT NULL CHECK(length(reason) BETWEEN 1 AND 1000),
  status TEXT NOT NULL DEFAULT 'open' CHECK(status IN('open','resolved','dismissed')),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  CHECK((clip_id IS NULL)!=(comment_id IS NULL))
);
CREATE UNIQUE INDEX social_reports_clip_once ON social_reports(reporter_id,clip_id) WHERE clip_id IS NOT NULL;
CREATE UNIQUE INDEX social_reports_comment_once ON social_reports(reporter_id,comment_id) WHERE comment_id IS NOT NULL;
CREATE INDEX social_reports_queue ON social_reports(status,sequence);
CREATE INDEX social_reports_reporter ON social_reports(reporter_id);
CREATE INDEX social_reports_clip ON social_reports(clip_id);
CREATE INDEX social_reports_comment ON social_reports(comment_id);
CREATE TABLE social_moderation_audit (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  request_id TEXT NOT NULL UNIQUE,
  target_type TEXT NOT NULL CHECK(target_type IN('clip','comment','user','report')),
  target_id TEXT NOT NULL,
  action TEXT NOT NULL,
  reason TEXT NOT NULL,
  actor TEXT NOT NULL DEFAULT 'admin-key' CHECK(actor='admin-key'),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
-- At most three small counters per account; no IP addresses or session tokens.
CREATE TABLE social_rate_limits (
  user_id TEXT NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  category TEXT NOT NULL CHECK(category IN('reaction','comment','report')),
  window_start INTEGER NOT NULL,
  count INTEGER NOT NULL CONSTRAINT social_rate_count CHECK(count BETWEEN 1 AND CASE category WHEN 'reaction' THEN 120 WHEN 'comment' THEN 20 ELSE 5 END),
  PRIMARY KEY(user_id,category)
) WITHOUT ROWID;
