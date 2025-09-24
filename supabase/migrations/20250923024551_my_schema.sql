drop policy "cataloger_runs_all_access" on "public"."cataloger_runs";

drop policy "chunks_all_access" on "public"."chunks";

drop policy "sfot_profiles_all_access" on "public"."sfot_profiles";

drop policy "streamers_all_access" on "public"."streamers";

drop index if exists "public"."idx_detections_chunk_id";

alter table "public"."cataloger_runs" disable row level security;

alter table "public"."chunks" disable row level security;

alter table "public"."sfot_profiles" disable row level security;

alter table "public"."streamers" disable row level security;


