drop extension if exists "pg_net";

revoke delete on table "public"."cataloger_runs" from "anon";

revoke insert on table "public"."cataloger_runs" from "anon";

revoke references on table "public"."cataloger_runs" from "anon";

revoke select on table "public"."cataloger_runs" from "anon";

revoke trigger on table "public"."cataloger_runs" from "anon";

revoke truncate on table "public"."cataloger_runs" from "anon";

revoke update on table "public"."cataloger_runs" from "anon";

revoke delete on table "public"."cataloger_runs" from "authenticated";

revoke insert on table "public"."cataloger_runs" from "authenticated";

revoke references on table "public"."cataloger_runs" from "authenticated";

revoke select on table "public"."cataloger_runs" from "authenticated";

revoke trigger on table "public"."cataloger_runs" from "authenticated";

revoke truncate on table "public"."cataloger_runs" from "authenticated";

revoke update on table "public"."cataloger_runs" from "authenticated";

revoke delete on table "public"."cataloger_runs" from "service_role";

revoke insert on table "public"."cataloger_runs" from "service_role";

revoke references on table "public"."cataloger_runs" from "service_role";

revoke select on table "public"."cataloger_runs" from "service_role";

revoke trigger on table "public"."cataloger_runs" from "service_role";

revoke truncate on table "public"."cataloger_runs" from "service_role";

revoke update on table "public"."cataloger_runs" from "service_role";

revoke delete on table "public"."chunks" from "anon";

revoke insert on table "public"."chunks" from "anon";

revoke references on table "public"."chunks" from "anon";

revoke select on table "public"."chunks" from "anon";

revoke trigger on table "public"."chunks" from "anon";

revoke truncate on table "public"."chunks" from "anon";

revoke update on table "public"."chunks" from "anon";

revoke delete on table "public"."chunks" from "authenticated";

revoke insert on table "public"."chunks" from "authenticated";

revoke references on table "public"."chunks" from "authenticated";

revoke select on table "public"."chunks" from "authenticated";

revoke trigger on table "public"."chunks" from "authenticated";

revoke truncate on table "public"."chunks" from "authenticated";

revoke update on table "public"."chunks" from "authenticated";

revoke delete on table "public"."chunks" from "service_role";

revoke insert on table "public"."chunks" from "service_role";

revoke references on table "public"."chunks" from "service_role";

revoke select on table "public"."chunks" from "service_role";

revoke trigger on table "public"."chunks" from "service_role";

revoke truncate on table "public"."chunks" from "service_role";

revoke update on table "public"."chunks" from "service_role";

revoke delete on table "public"."detections" from "anon";

revoke insert on table "public"."detections" from "anon";

revoke references on table "public"."detections" from "anon";

revoke select on table "public"."detections" from "anon";

revoke trigger on table "public"."detections" from "anon";

revoke truncate on table "public"."detections" from "anon";

revoke update on table "public"."detections" from "anon";

revoke delete on table "public"."detections" from "authenticated";

revoke insert on table "public"."detections" from "authenticated";

revoke references on table "public"."detections" from "authenticated";

revoke select on table "public"."detections" from "authenticated";

revoke trigger on table "public"."detections" from "authenticated";

revoke truncate on table "public"."detections" from "authenticated";

revoke update on table "public"."detections" from "authenticated";

revoke delete on table "public"."detections" from "service_role";

revoke insert on table "public"."detections" from "service_role";

revoke references on table "public"."detections" from "service_role";

revoke select on table "public"."detections" from "service_role";

revoke trigger on table "public"."detections" from "service_role";

revoke truncate on table "public"."detections" from "service_role";

revoke update on table "public"."detections" from "service_role";

revoke delete on table "public"."sfot_profiles" from "anon";

revoke insert on table "public"."sfot_profiles" from "anon";

revoke references on table "public"."sfot_profiles" from "anon";

revoke select on table "public"."sfot_profiles" from "anon";

revoke trigger on table "public"."sfot_profiles" from "anon";

revoke truncate on table "public"."sfot_profiles" from "anon";

revoke update on table "public"."sfot_profiles" from "anon";

revoke delete on table "public"."sfot_profiles" from "authenticated";

revoke insert on table "public"."sfot_profiles" from "authenticated";

revoke references on table "public"."sfot_profiles" from "authenticated";

revoke select on table "public"."sfot_profiles" from "authenticated";

revoke trigger on table "public"."sfot_profiles" from "authenticated";

revoke truncate on table "public"."sfot_profiles" from "authenticated";

revoke update on table "public"."sfot_profiles" from "authenticated";

revoke delete on table "public"."sfot_profiles" from "service_role";

revoke insert on table "public"."sfot_profiles" from "service_role";

revoke references on table "public"."sfot_profiles" from "service_role";

revoke select on table "public"."sfot_profiles" from "service_role";

revoke trigger on table "public"."sfot_profiles" from "service_role";

revoke truncate on table "public"."sfot_profiles" from "service_role";

revoke update on table "public"."sfot_profiles" from "service_role";

revoke delete on table "public"."streamers" from "anon";

revoke insert on table "public"."streamers" from "anon";

revoke references on table "public"."streamers" from "anon";

revoke select on table "public"."streamers" from "anon";

revoke trigger on table "public"."streamers" from "anon";

revoke truncate on table "public"."streamers" from "anon";

revoke update on table "public"."streamers" from "anon";

revoke delete on table "public"."streamers" from "authenticated";

revoke insert on table "public"."streamers" from "authenticated";

revoke references on table "public"."streamers" from "authenticated";

revoke select on table "public"."streamers" from "authenticated";

revoke trigger on table "public"."streamers" from "authenticated";

revoke truncate on table "public"."streamers" from "authenticated";

revoke update on table "public"."streamers" from "authenticated";

revoke delete on table "public"."streamers" from "service_role";

revoke insert on table "public"."streamers" from "service_role";

revoke references on table "public"."streamers" from "service_role";

revoke select on table "public"."streamers" from "service_role";

revoke trigger on table "public"."streamers" from "service_role";

revoke truncate on table "public"."streamers" from "service_role";

revoke update on table "public"."streamers" from "service_role";

revoke delete on table "public"."vods" from "anon";

revoke insert on table "public"."vods" from "anon";

revoke references on table "public"."vods" from "anon";

revoke select on table "public"."vods" from "anon";

revoke trigger on table "public"."vods" from "anon";

revoke truncate on table "public"."vods" from "anon";

revoke update on table "public"."vods" from "anon";

revoke delete on table "public"."vods" from "authenticated";

revoke insert on table "public"."vods" from "authenticated";

revoke references on table "public"."vods" from "authenticated";

revoke select on table "public"."vods" from "authenticated";

revoke trigger on table "public"."vods" from "authenticated";

revoke truncate on table "public"."vods" from "authenticated";

revoke update on table "public"."vods" from "authenticated";

revoke delete on table "public"."vods" from "service_role";

revoke insert on table "public"."vods" from "service_role";

revoke references on table "public"."vods" from "service_role";

revoke select on table "public"."vods" from "service_role";

revoke trigger on table "public"."vods" from "service_role";

revoke truncate on table "public"."vods" from "service_role";

revoke update on table "public"."vods" from "service_role";

alter table "public"."cataloger_runs" enable row level security;

alter table "public"."chunks" enable row level security;

alter table "public"."sfot_profiles" enable row level security;

alter table "public"."streamers" enable row level security;

CREATE INDEX idx_detections_chunk_id ON public.detections USING btree (chunk_id);

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.auto_create_chunks()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  -- Only create chunks if both VOD and streamer are ready for processing
  IF NEW.ready_for_processing = TRUE THEN
    IF EXISTS (
      SELECT 1 FROM streamers s 
      WHERE s.id = NEW.streamer_id 
      AND s.processing_enabled = TRUE
    ) THEN
      PERFORM create_chunks_for_segment(NEW.id, 0, NEW.duration_seconds);
    END IF;
  END IF;
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.cleanup_streamer_chunks_on_disable()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.processing_enabled = FALSE THEN
    DELETE FROM chunks 
    WHERE vod_id IN (SELECT id FROM vods WHERE streamer_id = NEW.id)
    AND status IN ('pending', 'processing');
  END IF;
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.cleanup_vod_chunks_on_disable()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.ready_for_processing = FALSE THEN
    DELETE FROM chunks 
    WHERE vod_id = NEW.id
    AND status IN ('pending', 'processing');
  END IF;
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.create_chunks_for_enabled_streamer()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.processing_enabled = TRUE AND OLD.processing_enabled = FALSE THEN
    -- Create chunks for all ready VODs for this streamer
    PERFORM create_chunks_for_segment(v.id, 0, v.duration_seconds)
    FROM vods v
    WHERE v.streamer_id = NEW.id 
    AND v.ready_for_processing = TRUE;
  END IF;
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.create_chunks_for_segment(p_vod_id bigint, p_start_seconds integer, p_end_seconds integer, p_chunk_duration_seconds integer DEFAULT 1800)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_chunk_count INT := 0;
  v_current_start INT := p_start_seconds;
  v_current_end INT;
  v_chunk_index INT := 0;
BEGIN
  WHILE v_current_start < p_end_seconds LOOP
    v_current_end := LEAST(v_current_start + p_chunk_duration_seconds, p_end_seconds);
    
    INSERT INTO chunks (vod_id, start_seconds, end_seconds, chunk_index)
    VALUES (p_vod_id, v_current_start, v_current_end, v_chunk_index)
    ON CONFLICT (vod_id, chunk_index) DO NOTHING;
    
    v_chunk_count := v_chunk_count + 1;
    v_current_start := v_current_end;
    v_chunk_index := v_chunk_index + 1;
  END LOOP;
  
  RETURN v_chunk_count;
END;
$function$
;


  create policy "cataloger_runs_all_access"
  on "public"."cataloger_runs"
  as permissive
  for all
  to public
using (true)
with check (true);



  create policy "chunks_all_access"
  on "public"."chunks"
  as permissive
  for all
  to public
using (true)
with check (true);



  create policy "sfot_profiles_all_access"
  on "public"."sfot_profiles"
  as permissive
  for all
  to public
using (true)
with check (true);



  create policy "streamers_all_access"
  on "public"."streamers"
  as permissive
  for all
  to public
using (true)
with check (true);



