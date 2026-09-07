INSERT OR IGNORE INTO sfde_profiles(id,profile_name,crop_region,igd_crop_region) VALUES(1,'default','[0,0,1,1]','[0,0,0.1,0.1]');
INSERT OR IGNORE INTO streamers(id,login,display_name,has_vods) VALUES(1,'local_fixture','Local Fixture',1);
INSERT OR IGNORE INTO vods(id,streamer_id,source_id,title,duration_seconds,published_at,bazaar_chapters,ready_for_processing) VALUES(1,1,'1000000001','Local pipeline fixture',3661,'2026-09-01T12:00:00Z','[0,3661]',1);
