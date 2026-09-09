-- The smoke script saves each generated frame's reviewed crop before claiming.
-- Dedicated per-video profiles leave the ordinary local catalog untouched.
INSERT OR IGNORE INTO sfde_profiles(id,profile_name,crop_region,opaque_edge)
VALUES (10,'local_ocr_smoke_10','[0,0,1,1]',0),
(11,'local_ocr_smoke_11','[0,0,1,1]',0),
(12,'local_ocr_smoke_12','[0,0,1,1]',0);
INSERT OR IGNORE INTO vods(id,streamer_id,source_id,title,duration_seconds,published_at,bazaar_chapters,ready_for_processing,sfde_profile_id)
VALUES (10,1,'1000000010','OCR smoke 1',12,'2026-09-01T12:00:00Z','[0,12]',1,10),
(11,1,'1000000011','OCR smoke 2',12,'2026-09-01T12:00:00Z','[0,12]',1,11),
(12,1,'1000000012','OCR smoke 3',12,'2026-09-01T12:00:00Z','[0,12]',1,12);
-- Upgrade these exact older fixtures only after their active work has stopped.
UPDATE vods SET sfde_profile_id=id
WHERE id IN(10,11,12) AND source='twitch' AND streamer_id=1
 AND source_id=CAST(1000000000+id AS TEXT) AND title='OCR smoke '||(id-9)
 AND duration_seconds=12 AND sfde_profile_id IS NULL
 AND NOT EXISTS(SELECT 1 FROM chunks WHERE vod_id=vods.id AND status IN('queued','processing'));
