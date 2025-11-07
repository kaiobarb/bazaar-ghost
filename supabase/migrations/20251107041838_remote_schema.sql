drop extension if exists "pg_net";

create extension if not exists "pg_net" with schema "public";

create extension if not exists "pg_trgm" with schema "public";

drop trigger if exists "trigger_vod_status_change" on "public"."vods";

drop trigger if exists "trigger_auto_create_chunks" on "public"."vods";

drop function if exists "public"."create_chunks_for_segment"(p_vod_id bigint, p_start_seconds integer, p_end_seconds integer, p_chunk_duration_seconds integer);

drop function if exists "public"."cron_process_pending_vods"();

drop function if exists "public"."manual_process_pending_vods"(max_vods integer);

alter table "public"."processing_config" enable row level security;

CREATE INDEX idx_detection_search_username_trgm ON public.detections USING gin (username public.gin_trgm_ops);

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.create_missing_chunks_for_vod(p_vod_id bigint, p_target_chunk_seconds integer DEFAULT 3600, p_min_gap_seconds integer DEFAULT 300)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_vod_duration     integer;
  v_bazaar_chapters  integer[];
  v_created          integer := 0;
  v_chunk_idx_start  integer;
  v_seg_start        integer;
  v_seg_end          integer;
  v_seg_dur          integer;
  v_gap_mr           int4multirange;
  v_existing_mr      int4multirange;
  v_seg_mr           int4multirange;
  r_gap              int4range;
  g_start            integer;
  g_end              integer;
  g_dur              integer;
  num_chunks         integer;
  chunk_dur          integer;
  i                  integer;
  cur_start          integer;
  cur_end            integer;
begin
  -- Load VOD
  select duration_seconds, bazaar_chapters
  into v_vod_duration, v_bazaar_chapters
  from vods
  where id = p_vod_id;

  if v_vod_duration is null then
    raise notice 'VOD % not found', p_vod_id;
    return 0;
  end if;

  -- Nothing to do if VOD shorter than 5 minutes total
  if v_vod_duration < p_min_gap_seconds then
    raise notice 'VOD % is too short (%s s), skipping', p_vod_id, v_vod_duration;
    return 0;
  end if;

  -- If no Bazaar chapters, treat whole VOD as one segment
  if v_bazaar_chapters is null
     or array_length(v_bazaar_chapters, 1) is null
     or array_length(v_bazaar_chapters, 1) = 0 then
    v_bazaar_chapters := array[0, v_vod_duration];
  end if;

  -- Determine starting chunk_index (append-only)
  select coalesce(max(chunk_index), -1) + 1
  into v_chunk_idx_start
  from chunks
  where vod_id = p_vod_id;

  -- Iterate pairs [start, end] from chapters/segments
  for i in 1..array_length(v_bazaar_chapters,1) by 2 loop
    v_seg_start := v_bazaar_chapters[i];
    v_seg_end   := v_bazaar_chapters[i+1];

    if v_seg_end is null then
      continue;
    end if;

    -- Clamp to VOD duration for safety
    v_seg_start := greatest(0, least(v_seg_start, v_vod_duration));
    v_seg_end   := greatest(0, least(v_seg_end,   v_vod_duration));
    if v_seg_end <= v_seg_start then
      continue;
    end if;

    v_seg_dur := v_seg_end - v_seg_start;
    -- Skip segment if < 5 minutes
    if v_seg_dur < p_min_gap_seconds then
      continue;
    end if;

    -- Build multirange for this segment
    v_seg_mr := int4multirange(int4range(v_seg_start, v_seg_end));

    -- Existing chunks overlapping this segment (as multirange)
    select coalesce(range_agg(int4range(c.start_seconds, c.end_seconds))::int4multirange, '{}')
    into v_existing_mr
    from chunks c
    where c.vod_id = p_vod_id
      and int4range(c.start_seconds, c.end_seconds) && int4range(v_seg_start, v_seg_end);

    -- Uncovered gaps = segment minus existing
    v_gap_mr := v_seg_mr - coalesce(v_existing_mr, '{}');

    -- For each uncovered gap in this segment, create chunks per rules
    for r_gap in
      select unnest(v_gap_mr)
    loop
      g_start := lower(r_gap);
      g_end   := upper(r_gap);
      g_dur   := g_end - g_start;

      -- Ignore tiny gaps (< 5 min)
      if g_dur < p_min_gap_seconds then
        continue;
      end if;

      -- ≤ 1 hour → single chunk
      if g_dur <= p_target_chunk_seconds then
        begin
          insert into chunks (vod_id, start_seconds, end_seconds, chunk_index)
          values (p_vod_id, g_start, g_end, v_chunk_idx_start + v_created);
          v_created := v_created + 1;
        exception when unique_violation or exclusion_violation then
          -- Another worker might have created it; skip
          continue;
        end;
        continue;
      end if;

      -- > 1 hour → the FEWEST chunks with each ≥ 1 hour
      -- Strategy: num_chunks = floor(g_dur / 1h), each chunk ≈ ceil(g_dur / num_chunks)
      num_chunks := floor(g_dur::numeric / p_target_chunk_seconds);
      if num_chunks < 1 then
        num_chunks := 1;
      end if;
      -- Distribute so each is ≥ ~1h (or one longer chunk when 1h < g_dur < 2h)
      chunk_dur := ceil(g_dur::numeric / num_chunks);

      cur_start := g_start;
      for i in 1..num_chunks loop
        if i = num_chunks then
          cur_end := g_end;  -- last chunk absorbs remainder
        else
          cur_end := least(cur_start + chunk_dur, g_end);
          -- Guard against pathological short last chunk; fold into fewer
          if (g_end - cur_end) > 0 and (g_end - cur_end) < p_target_chunk_seconds then
            -- Merge remainder now: make this the final chunk
            cur_end := g_end;
            -- Adjust num_chunks to break the loop after insert
            num_chunks := i;
          end if;
        end if;

        -- Insert, tolerating races
        begin
          insert into chunks (vod_id, start_seconds, end_seconds, chunk_index)
          values (p_vod_id, cur_start, cur_end, v_chunk_idx_start + v_created);
          v_created := v_created + 1;
        exception when unique_violation or exclusion_violation then
          -- Skip on overlap/dup (exclusion constraint or concurrent insert)
          null;
        end;

        exit when cur_end >= g_end;
        cur_start := cur_end;
      end loop;
    end loop; -- gaps
  end loop; -- segments

  return v_created;
end;
$function$
;

create or replace view "public"."detection_search" as  SELECT d.id AS detection_id,
    d.username,
    d.frame_time_seconds,
    d.confidence,
    d.rank,
    d.storage_path,
    d.no_right_edge,
    d.created_at AS detection_created_at,
    v.id AS vod_id,
    v.source_id AS vod_source_id,
    v.title AS vod_title,
    v.published_at AS vod_published_at,
    v.duration_seconds AS vod_duration_seconds,
    v.availability AS vod_availability,
    (v.published_at + ((d.frame_time_seconds || ' seconds'::text))::interval) AS actual_timestamp,
    s.id AS streamer_id,
    s.login AS streamer_login,
    s.display_name AS streamer_display_name,
    s.profile_image_url AS streamer_avatar,
        CASE
            WHEN (v.source_id IS NOT NULL) THEN (((('https://www.twitch.tv/videos/'::text || v.source_id) || '?t='::text) || d.frame_time_seconds) || 's'::text)
            ELSE NULL::text
        END AS vod_url
   FROM ((public.detections d
     JOIN public.vods v ON ((d.vod_id = v.id)))
     JOIN public.streamers s ON ((v.streamer_id = s.id)))
  WHERE ((v.availability = 'available'::public.vod_availability) AND (d.confidence > (0.7)::double precision));


create or replace view "public"."detections_with_streamer_vod" as  SELECT d.username,
    d.confidence,
    d.rank,
    d.frame_time_seconds,
    d.storage_path,
    d.created_at,
    d.no_right_edge,
    v.source_id AS vod_source_id,
    s.login AS streamer_login,
    d.chunk_id
   FROM ((public.detections d
     LEFT JOIN public.vods v ON ((v.id = d.vod_id)))
     LEFT JOIN public.streamers s ON ((s.id = v.streamer_id)));


create or replace view "public"."detections_with_streamer_vods" as  SELECT d.id,
    d.chunk_id,
    d.vod_id,
    d.username,
    d.confidence,
    d.rank,
    d.frame_time_seconds,
    d.storage_path,
    d.created_at,
    d.no_right_edge,
    v.streamer_id,
    s.login AS streamer_login,
    v.title AS vod_title,
    v.published_at
   FROM ((public.detections d
     LEFT JOIN public.vods v ON ((d.vod_id = v.id)))
     LEFT JOIN public.streamers s ON ((v.streamer_id = s.id)));


CREATE OR REPLACE FUNCTION public.fuzzy_search_detections(search_query text DEFAULT NULL::text, streamer_id_filter bigint DEFAULT NULL::bigint, date_range_filter text DEFAULT 'all'::text, similarity_threshold double precision DEFAULT 0.2, result_limit integer DEFAULT 100)
 RETURNS TABLE(detection_id uuid, username text, streamer_id bigint, streamer_login text, streamer_display_name text, streamer_avatar text, frame_time_seconds integer, confidence double precision, rank text, vod_id bigint, vod_source_id text, vod_url text, actual_timestamp timestamp with time zone, similarity_score real)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    -- Set the similarity threshold for this query
    EXECUTE format('SET LOCAL pg_trgm.similarity_threshold = %s', similarity_threshold);

    RETURN QUERY
    SELECT
        ds.detection_id,
        ds.username,
        ds.streamer_id,
        ds.streamer_login,
        ds.streamer_display_name,
        ds.streamer_avatar,
        ds.frame_time_seconds,
        ds.confidence,
        ds.rank,
        ds.vod_id,
        ds.vod_source_id,
        ds.vod_url,
        ds.actual_timestamp,
        CASE
            WHEN search_query IS NOT NULL AND search_query != ''
            THEN similarity(ds.username, search_query)
            ELSE 1.0
        END AS similarity_score
    FROM detection_search ds
    WHERE
        -- Username fuzzy search or no filter
        (
            search_query IS NULL
            OR search_query = ''
            OR ds.username % search_query  -- Uses trigram similarity operator
        )
        -- Streamer filter
        AND (
            streamer_id_filter IS NULL
            OR ds.streamer_id = streamer_id_filter
        )
        -- Date range filter
        AND (
            date_range_filter = 'all'
            OR (date_range_filter = 'week' AND ds.actual_timestamp >= NOW() - INTERVAL '7 days')
            OR (date_range_filter = 'month' AND ds.actual_timestamp >= NOW() - INTERVAL '30 days')
            OR (date_range_filter = 'year' AND ds.actual_timestamp >= NOW() - INTERVAL '365 days')
        )
    ORDER BY
        -- If searching, order by similarity score first, then by timestamp
        CASE
            WHEN search_query IS NOT NULL AND search_query != ''
            THEN similarity(ds.username, search_query)
            ELSE 0
        END DESC,
        ds.actual_timestamp DESC
    LIMIT result_limit;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.get_global_stats()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    stats json;
BEGIN
    SELECT json_build_object(
        'streamers', COUNT(DISTINCT streamer_id),
        'vods', COUNT(DISTINCT vod_id),
        'matchups', COUNT(*)
    ) INTO stats
    FROM detection_search;

    RETURN stats;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.get_top_streamers_with_recent_detections(top_count integer DEFAULT 10, detections_per_streamer integer DEFAULT 5)
 RETURNS TABLE(streamer_id bigint, streamer_login text, streamer_display_name text, streamer_avatar text, total_detections bigint, total_vods bigint, detection_id uuid, username text, frame_time_seconds integer, confidence double precision, rank text, vod_id bigint, vod_source_id text, vod_url text, actual_timestamp timestamp with time zone, detection_row_num bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  RETURN QUERY
  WITH top_streamers AS (
    SELECT
      ds.streamer_id,
      ds.streamer_login,
      ds.streamer_display_name,
      ds.streamer_avatar,
      COUNT(*) AS detection_count,
      COUNT(DISTINCT ds.vod_id) AS vod_count
    FROM public.detection_search ds
    GROUP BY ds.streamer_id, ds.streamer_login, ds.streamer_display_name, ds.streamer_avatar
    ORDER BY detection_count DESC
    LIMIT top_count
  ),
  recent_detections AS (
    SELECT
      ts.streamer_id,
      ts.streamer_login,
      ts.streamer_display_name,
      ts.streamer_avatar,
      ts.detection_count,
      ts.vod_count,
      ds.detection_id,
      ds.username,
      ds.frame_time_seconds,
      ds.confidence,
      ds.rank,
      ds.vod_id,
      ds.vod_source_id,
      ds.vod_url,
      ds.actual_timestamp,
      ROW_NUMBER() OVER (PARTITION BY ts.streamer_id ORDER BY ds.actual_timestamp DESC) AS row_num
    FROM top_streamers ts
    JOIN public.detection_search ds ON ds.streamer_id = ts.streamer_id
  )
  SELECT
    rd.streamer_id,
    rd.streamer_login,
    rd.streamer_display_name,
    rd.streamer_avatar,
    rd.detection_count::bigint AS total_detections,
    rd.vod_count::bigint       AS total_vods,
    rd.detection_id,
    rd.username,
    rd.frame_time_seconds,
    rd.confidence,
    rd.rank,
    rd.vod_id,
    rd.vod_source_id,
    rd.vod_url,
    rd.actual_timestamp,
    rd.row_num AS detection_row_num
  FROM recent_detections rd
  WHERE rd.row_num <= detections_per_streamer
  ORDER BY rd.detection_count DESC, rd.streamer_id, rd.row_num;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.search_detections_fuzzy(search_query text, p_streamer_id bigint DEFAULT NULL::bigint, p_date_from timestamp without time zone DEFAULT NULL::timestamp without time zone, p_date_to timestamp without time zone DEFAULT NULL::timestamp without time zone)
 RETURNS TABLE(detection_id uuid, username text, rank_score real, frame_time_seconds double precision, confidence double precision, rank text, vod_id bigint, vod_source_id text, vod_url text, streamer_id bigint, streamer_login text, streamer_display_name text, streamer_avatar text, actual_timestamp timestamp without time zone)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    SELECT
        ds.detection_id,
        ds.username,
        ts_rank(ds.fts, plainto_tsquery('simple', search_query)) as rank_score,
        ds.frame_time_seconds,
        ds.confidence,
        ds.rank,
        ds.vod_id,
        ds.vod_source_id,
        ds.vod_url,
        ds.streamer_id,
        ds.streamer_login,
        ds.streamer_display_name,
        ds.streamer_avatar,
        ds.actual_timestamp
    FROM detection_search ds
    WHERE
        ds.fts @@ plainto_tsquery('simple', search_query)
        AND (p_streamer_id IS NULL OR ds.streamer_id = p_streamer_id)
        AND (p_date_from IS NULL OR ds.actual_timestamp >= p_date_from)
        AND (p_date_to IS NULL OR ds.actual_timestamp <= p_date_to)
    ORDER BY
        ts_rank(ds.fts, plainto_tsquery('simple', search_query)) DESC,
        ds.actual_timestamp DESC
    LIMIT 100;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.simulate_chunk_plan_for_vod(p_vod_id bigint, p_target_chunk_seconds integer DEFAULT 3600, p_min_gap_seconds integer DEFAULT 300)
 RETURNS TABLE(segment_start integer, segment_end integer, gap_start integer, gap_end integer, proposed_chunk_start integer, proposed_chunk_end integer, proposed_duration integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_vod_duration     integer;
  v_bazaar_chapters  integer[];
  v_seg_start        integer;
  v_seg_end          integer;
  v_seg_dur          integer;
  v_gap_mr           int4multirange;
  v_existing_mr      int4multirange;
  v_seg_mr           int4multirange;
  r_gap              int4range;
  g_start            integer;
  g_end              integer;
  g_dur              integer;
  num_chunks         integer;
  chunk_dur          integer;
  i                  integer;
  cur_start          integer;
  cur_end            integer;
begin
  select duration_seconds, bazaar_chapters
  into v_vod_duration, v_bazaar_chapters
  from vods where id = p_vod_id;

  if v_vod_duration is null then
    return;
  end if;

  if v_bazaar_chapters is null
     or array_length(v_bazaar_chapters,1) is null
     or array_length(v_bazaar_chapters,1)=0 then
    v_bazaar_chapters := array[0, v_vod_duration];
  end if;

  for i in 1..array_length(v_bazaar_chapters,1) by 2 loop
    v_seg_start := v_bazaar_chapters[i];
    v_seg_end   := v_bazaar_chapters[i+1];
    if v_seg_end is null then continue; end if;
    v_seg_start := greatest(0, least(v_seg_start, v_vod_duration));
    v_seg_end   := greatest(0, least(v_seg_end,   v_vod_duration));
    if v_seg_end <= v_seg_start then continue; end if;
    v_seg_dur := v_seg_end - v_seg_start;
    if v_seg_dur < p_min_gap_seconds then continue; end if;

    v_seg_mr := int4multirange(int4range(v_seg_start, v_seg_end));

    select coalesce(range_agg(int4range(c.start_seconds, c.end_seconds))::int4multirange, '{}')
    into v_existing_mr
    from chunks c
    where c.vod_id = p_vod_id
      and int4range(c.start_seconds, c.end_seconds) && int4range(v_seg_start, v_seg_end);

    v_gap_mr := v_seg_mr - coalesce(v_existing_mr, '{}');

    for r_gap in select unnest(v_gap_mr) loop
      g_start := lower(r_gap);
      g_end   := upper(r_gap);
      g_dur   := g_end - g_start;
      if g_dur < p_min_gap_seconds then continue; end if;

      if g_dur <= p_target_chunk_seconds then
        proposed_chunk_start := g_start;
        proposed_chunk_end   := g_end;
        proposed_duration    := g_dur;
        segment_start := v_seg_start;
        segment_end   := v_seg_end;
        gap_start     := g_start;
        gap_end       := g_end;
        return next;
        continue;
      end if;

      num_chunks := floor(g_dur::numeric / p_target_chunk_seconds);
      if num_chunks < 1 then num_chunks := 1; end if;
      chunk_dur := ceil(g_dur::numeric / num_chunks);
      cur_start := g_start;

      for i in 1..num_chunks loop
        if i = num_chunks then
          cur_end := g_end;
        else
          cur_end := least(cur_start + chunk_dur, g_end);
          if (g_end - cur_end) > 0 and (g_end - cur_end) < p_target_chunk_seconds then
            cur_end := g_end;
            num_chunks := i;
          end if;
        end if;
        proposed_chunk_start := cur_start;
        proposed_chunk_end   := cur_end;
        proposed_duration    := cur_end - cur_start;
        segment_start := v_seg_start;
        segment_end   := v_seg_end;
        gap_start     := g_start;
        gap_end       := g_end;
        return next;
        exit when cur_end >= g_end;
        cur_start := cur_end;
      end loop;
    end loop;
  end loop;
end;
$function$
;

create or replace view "public"."streamer_detections" as  WITH ranked AS (
         SELECT s.login,
            d.username,
            row_number() OVER (PARTITION BY s.id ORDER BY d.confidence DESC, d.username) AS rn
           FROM ((public.streamers s
             JOIN public.vods v ON ((v.streamer_id = s.id)))
             JOIN public.detections d ON ((d.vod_id = v.id)))
          WHERE (s.login = ANY ('{nl_kripp,layzyn,behemyth23,dorsel,trynet123,rahresh,whisperzz_live,zenaton,hopeless_bb,jota3n,merimides,gnashin,mikevalentine,tr1kster,mobooshka_ua,true_adant,profumatotk,goranthaman,hunting_mage,leodriango,battleliquor,drevsaurus,nomastersnorulers,theobr0mine,offs2010,ericmcgann,mr_demonolog,2sixten,assertivestreaming,esaygraphics,kwev,heymaddle,dice_the_vice,classyato,ckatv,keletakis,sg4e,fr3akuency,kratzeflow,the_joker_92,doughboy808hi,bryukvaplay,chronosoutoftime,askaandthewolf,simplylohiow,volf81}'::text[]))
        )
 SELECT pivot.rn,
    max(
        CASE
            WHEN ((ranked.login = 'nl_kripp'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS nl_kripp,
    max(
        CASE
            WHEN ((ranked.login = 'layzyn'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS layzyn,
    max(
        CASE
            WHEN ((ranked.login = 'behemyth23'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS behemyth23,
    max(
        CASE
            WHEN ((ranked.login = 'dorsel'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS dorsel,
    max(
        CASE
            WHEN ((ranked.login = 'trynet123'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS trynet123,
    max(
        CASE
            WHEN ((ranked.login = 'rahresh'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS rahresh,
    max(
        CASE
            WHEN ((ranked.login = 'whisperzz_live'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS whisperzz_live,
    max(
        CASE
            WHEN ((ranked.login = 'zenaton'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS zenaton,
    max(
        CASE
            WHEN ((ranked.login = 'hopeless_bb'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS hopeless_bb,
    max(
        CASE
            WHEN ((ranked.login = 'jota3n'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS jota3n,
    max(
        CASE
            WHEN ((ranked.login = 'merimides'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS merimides,
    max(
        CASE
            WHEN ((ranked.login = 'gnashin'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS gnashin,
    max(
        CASE
            WHEN ((ranked.login = 'mikevalentine'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS mikevalentine,
    max(
        CASE
            WHEN ((ranked.login = 'tr1kster'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS tr1kster,
    max(
        CASE
            WHEN ((ranked.login = 'mobooshka_ua'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS mobooshka_ua,
    max(
        CASE
            WHEN ((ranked.login = 'true_adant'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS true_adant,
    max(
        CASE
            WHEN ((ranked.login = 'profumatotk'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS profumatotk,
    max(
        CASE
            WHEN ((ranked.login = 'goranthaman'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS goranthaman,
    max(
        CASE
            WHEN ((ranked.login = 'hunting_mage'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS hunting_mage,
    max(
        CASE
            WHEN ((ranked.login = 'leodriango'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS leodriango,
    max(
        CASE
            WHEN ((ranked.login = 'battleliquor'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS battleliquor,
    max(
        CASE
            WHEN ((ranked.login = 'drevsaurus'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS drevsaurus,
    max(
        CASE
            WHEN ((ranked.login = 'nomastersnorulers'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS nomastersnorulers,
    max(
        CASE
            WHEN ((ranked.login = 'theobr0mine'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS theobr0mine,
    max(
        CASE
            WHEN ((ranked.login = 'offs2010'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS offs2010,
    max(
        CASE
            WHEN ((ranked.login = 'ericmcgann'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS ericmcgann,
    max(
        CASE
            WHEN ((ranked.login = 'mr_demonolog'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS mr_demonolog,
    max(
        CASE
            WHEN ((ranked.login = '2sixten'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS "2sixten",
    max(
        CASE
            WHEN ((ranked.login = 'assertivestreaming'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS assertivestreaming,
    max(
        CASE
            WHEN ((ranked.login = 'esaygraphics'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS esaygraphics,
    max(
        CASE
            WHEN ((ranked.login = 'kwev'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS kwev,
    max(
        CASE
            WHEN ((ranked.login = 'heymaddle'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS heymaddle,
    max(
        CASE
            WHEN ((ranked.login = 'dice_the_vice'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS dice_the_vice,
    max(
        CASE
            WHEN ((ranked.login = 'classyato'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS classyato,
    max(
        CASE
            WHEN ((ranked.login = 'ckatv'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS ckatv,
    max(
        CASE
            WHEN ((ranked.login = 'keletakis'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS keletakis,
    max(
        CASE
            WHEN ((ranked.login = 'sg4e'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS sg4e,
    max(
        CASE
            WHEN ((ranked.login = 'fr3akuency'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS fr3akuency,
    max(
        CASE
            WHEN ((ranked.login = 'kratzeflow'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS kratzeflow,
    max(
        CASE
            WHEN ((ranked.login = 'the_joker_92'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS the_joker_92,
    max(
        CASE
            WHEN ((ranked.login = 'doughboy808hi'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS doughboy808hi,
    max(
        CASE
            WHEN ((ranked.login = 'bryukvaplay'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS bryukvaplay,
    max(
        CASE
            WHEN ((ranked.login = 'chronosoutoftime'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS chronosoutoftime,
    max(
        CASE
            WHEN ((ranked.login = 'askaandthewolf'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS askaandthewolf,
    max(
        CASE
            WHEN ((ranked.login = 'simplylohiow'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS simplylohiow,
    max(
        CASE
            WHEN ((ranked.login = 'volf81'::text) AND (ranked.rn = pivot.rn)) THEN ranked.username
            ELSE NULL::text
        END) AS volf81
   FROM (generate_series(1, 4315) pivot(rn)
     LEFT JOIN ranked ON ((ranked.rn = pivot.rn)))
  GROUP BY pivot.rn
  ORDER BY pivot.rn;


create or replace view "public"."vod_stats" as  SELECT v.id,
    v.source,
    v.source_id,
    v.title,
    v.duration_seconds,
    v.published_at,
    v.availability,
    v.last_availability_check,
    v.unavailable_since,
    v.ready_for_processing,
    v.created_at,
    v.updated_at,
    v.bazaar_chapters,
    v.status,
    d.avg_confidence,
    c.chunks_count AS chunks,
    s.streamer,
    q.quality
   FROM ((((public.vods v
     LEFT JOIN LATERAL ( SELECT count(*) AS chunks_count
           FROM public.chunks ch
          WHERE (ch.vod_id = v.id)) c ON (true))
     LEFT JOIN LATERAL ( SELECT avg(de.confidence) AS avg_confidence
           FROM public.detections de
          WHERE ((de.vod_id = v.id) AND (de.confidence IS NOT NULL))) d ON (true))
     LEFT JOIN LATERAL ( SELECT st.display_name AS streamer
           FROM public.streamers st
          WHERE (st.id = v.streamer_id)
         LIMIT 1) s ON (true))
     LEFT JOIN LATERAL ( SELECT
                CASE
                    WHEN (v.status <> 'pending'::public.vod_status) THEN
                    CASE
                        WHEN (array_length(array_agg(DISTINCT ch.quality), 1) = 1) THEN (array_agg(DISTINCT ch.quality))[1]
                        ELSE NULL::text
                    END
                    ELSE NULL::text
                END AS quality
           FROM public.chunks ch
          WHERE (ch.vod_id = v.id)) q ON (true));


CREATE OR REPLACE FUNCTION public.vods_mark_chunks_failed_on_vod_failure()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  -- Only run on status change from 'processing' to 'failed'
  IF (TG_OP = 'UPDATE')
     AND (OLD.status = 'processing'::vod_status)
     AND (NEW.status = 'failed'::vod_status) THEN

    -- Update associated chunks to failed if not already failed
    UPDATE public.chunks
    SET status = 'failed'::processing_status,
        updated_at = NOW()
    WHERE vod_id = NEW.id
      AND status IS DISTINCT FROM 'failed'::processing_status;

  END IF;

  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.auto_create_chunks()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$DECLARE
  should_run boolean := false;
BEGIN
  -- Decide when to (re)chunk
  IF TG_OP = 'INSERT' THEN
    should_run := true;
  ELSE
    IF (
         (NEW.ready_for_processing IS TRUE
           AND NEW.ready_for_processing IS DISTINCT FROM OLD.ready_for_processing)
         OR (NEW.duration_seconds IS DISTINCT FROM OLD.duration_seconds)
         OR (NEW.bazaar_chapters IS DISTINCT FROM OLD.bazaar_chapters)
       )
    THEN
      should_run := true;
    END IF;
  END IF;

  IF should_run THEN
    -- Only process if streamer allows it
    IF EXISTS (
      SELECT 1 FROM streamers s
      WHERE s.id = NEW.streamer_id
        AND s.processing_enabled = TRUE
    ) THEN
      -- Minimum length (10 min)
      IF NEW.duration_seconds >= 600 THEN
        PERFORM create_missing_chunks_for_vod(NEW.id);
      ELSE
        RAISE NOTICE 'VOD % too short for chunking (% s)', NEW.id, NEW.duration_seconds;
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;$function$
;

CREATE OR REPLACE FUNCTION public.create_chunks_for_enabled_streamer()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$BEGIN
  IF NEW.processing_enabled = TRUE AND OLD.processing_enabled = FALSE THEN
    -- Create chunks for all ready VODs for this streamer
    PERFORM create_missing_chunks_for_vod(v.id)
    FROM vods v
    WHERE v.streamer_id = NEW.id 
    AND v.ready_for_processing = TRUE;
  END IF;
  RETURN NEW;
END;$function$
;

CREATE OR REPLACE FUNCTION public.cron_insert_new_streamers()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$DECLARE
  v_response_id bigint;
  v_status_code integer;
  v_secret_key text;
  v_supabase_url text;
  v_url text;
BEGIN
  -- Get the secret key from vault
  SELECT decrypted_secret INTO v_secret_key
  FROM vault.decrypted_secrets
  WHERE name = 'secret_key'
  LIMIT 1;

  IF v_secret_key IS NULL THEN
    RAISE EXCEPTION 'No secret key found in vault';
  END IF;

  -- Get Supabase URL from vault
  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'supabase_url'
  LIMIT 1;

  IF v_supabase_url IS NULL THEN
    RAISE EXCEPTION 'No supabase_url found in vault';
  END IF;

  -- Construct full URL for edge function
  v_url := v_supabase_url || '/functions/v1/insert-new-streamers';

  -- Call the edge function using pg_net with apikey header
  SELECT net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'apikey', v_secret_key,
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000
  ) INTO v_response_id;

  -- Wait for response (optional - remove for async)
  SELECT status_code
  INTO v_status_code
  FROM net._http_response
  WHERE id = v_response_id;

  IF v_status_code IS NOT NULL AND v_status_code != 200 THEN
    RAISE WARNING 'insert-new-streamers returned status code: %', v_status_code;
  END IF;

  RAISE NOTICE 'Called insert-new-streamers edge function, response_id: %', v_response_id;
END;$function$
;

CREATE OR REPLACE FUNCTION public.cron_update_streamer_vods()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$DECLARE
  v_streamer RECORD;
  v_response_id bigint;
  v_status_code integer;
  v_secret_key text;
  v_supabase_url text;
  v_url text;
  v_updated_count integer := 0;
  v_interval_text text;
  v_interval interval;
BEGIN
  -- Load the interval config
  SELECT value INTO v_interval_text
  FROM processing_config
  WHERE key = 'update_vods_interval';

  IF v_interval_text IS NULL THEN
    RAISE NOTICE 'No update_vods_interval found, defaulting to 6 hours';
    v_interval := interval '6 hours';
  ELSE
    BEGIN
      v_interval := v_interval_text::interval;
    EXCEPTION WHEN others THEN
      RAISE WARNING 'Invalid interval value %, defaulting to 6 hours', v_interval_text;
      v_interval := interval '6 hours';
    END;
  END IF;

  -- Get secrets from vault
  SELECT decrypted_secret INTO v_secret_key
  FROM vault.decrypted_secrets
  WHERE name = 'secret_key'
  LIMIT 1;

  IF v_secret_key IS NULL THEN
    RAISE EXCEPTION 'No secret key found in vault';
  END IF;

  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'supabase_url'
  LIMIT 1;

  IF v_supabase_url IS NULL THEN
    RAISE EXCEPTION 'No supabase_url found in vault';
  END IF;

  v_url := v_supabase_url || '/functions/v1/update-vods';

  -- Find streamers to process
  FOR v_streamer IN
    SELECT id, login, updated_at
    FROM streamers
    WHERE processing_enabled = true
      AND (
        has_vods = true
        OR (created_at = updated_at)
        OR has_vods IS NULL
      )
      AND updated_at <= NOW() - v_interval
    ORDER BY updated_at ASC
    LIMIT 10
  LOOP
    BEGIN
      SELECT net.http_post(
        url := v_url,
        headers := jsonb_build_object(
          'apikey', v_secret_key,
          'Content-Type', 'application/json'
        ),
        body := jsonb_build_object('streamer_id', v_streamer.id),
        timeout_milliseconds := 60000
      ) INTO v_response_id;

      v_updated_count := v_updated_count + 1;
      RAISE NOTICE 'Called update-vods for streamer % (%)', v_streamer.login, v_streamer.id;
      PERFORM pg_sleep(1);

    EXCEPTION WHEN others THEN
      RAISE WARNING 'Failed to update VODs for streamer % (%): %',
        v_streamer.login, v_streamer.id, SQLERRM;
    END;
  END LOOP;

  RAISE NOTICE 'Updated VODs for % streamers (interval %)', v_updated_count, v_interval_text;
END;$function$
;

CREATE OR REPLACE FUNCTION public.process_pending_vods(max_vods integer DEFAULT 5)
 RETURNS TABLE(vod_id bigint, source_id text, pending_chunks bigint, request_id bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$DECLARE
    v_supabase_url TEXT;
    v_secret_key TEXT;
    v_max_concurrent INTEGER;
    v_current_active_count INTEGER;
    v_vod RECORD;
    v_request_id BIGINT;
    v_processed_count INTEGER := 0;
BEGIN
    -- Get credentials from Vault
    SELECT decrypted_secret INTO v_supabase_url
    FROM vault.decrypted_secrets
    WHERE name = 'supabase_url';

    SELECT decrypted_secret INTO v_secret_key
    FROM vault.decrypted_secrets
    WHERE name = 'secret_key';

    -- Check if credentials are available
    IF v_supabase_url IS NULL OR v_secret_key IS NULL THEN
        RAISE EXCEPTION 'Missing Supabase credentials in Vault. Please configure supabase_url and secret_key.';
    END IF;

    -- Get max concurrent chunks configuration
    SELECT value::integer INTO v_max_concurrent
    FROM processing_config
    WHERE key = 'max_concurrent_chunks';

    -- Default to 10 if not configured
    IF v_max_concurrent IS NULL THEN
        v_max_concurrent := 10;
    END IF;

    -- Count currently active chunks (queued or processing)
    SELECT COUNT(*)
    INTO v_current_active_count
    FROM chunks
    WHERE status IN ('queued', 'processing');

    RAISE NOTICE 'Current active chunks: %, max allowed: %', v_current_active_count, v_max_concurrent;

    -- Check if we have capacity for more chunks
    IF v_current_active_count >= v_max_concurrent THEN
        RAISE NOTICE 'At capacity (% active chunks), not processing new VODs', v_current_active_count;
        RETURN;
    END IF;

    -- Find VODs with pending chunks
    FOR v_vod IN
        SELECT
            v.id AS vod_id,
            v.source_id,
            COUNT(c.id) AS pending_chunks,
            MIN(c.attempt_count) AS min_attempt_count,
            v.published_at
        FROM vods v
        INNER JOIN chunks c ON c.vod_id = v.id
        WHERE
            -- VOD is ready for processing
            v.ready_for_processing = TRUE
            -- VOD is available
            AND v.availability = 'available'
            -- Has chunks that are pending
            AND c.status = 'pending'
            -- Streamer is enabled for processing
            AND EXISTS (
                SELECT 1 FROM streamers s
                WHERE s.id = v.streamer_id
                AND s.processing_enabled = TRUE
            )
        GROUP BY v.id, v.source_id, v.published_at
        -- Prioritize VODs with fewer processing attempts
        ORDER BY
            MIN(c.attempt_count) ASC,
            v.published_at DESC
        LIMIT max_vods
    LOOP
        -- Call process-vod edge function with apikey header
        SELECT net.http_post(
            url := v_supabase_url || '/functions/v1/process-vod',
            headers := jsonb_build_object(
                'Content-Type', 'application/json',
                'apikey', v_secret_key
            ),
            body := jsonb_build_object(
                'vod_id', v_vod.vod_id,  -- Internal VOD ID
                'source_id', v_vod.source_id  -- Also send source_id for redundancy
            ),
            timeout_milliseconds := 10000  -- 10 second timeout
        ) INTO v_request_id;

        -- Log the processing attempt
        RAISE NOTICE 'Scheduled processing for VOD % (source: %) with % pending chunks. Request ID: %',
            v_vod.vod_id, v_vod.source_id, v_vod.pending_chunks, v_request_id;

        -- Return the result
        RETURN QUERY
        SELECT
            v_vod.vod_id,
            v_vod.source_id,
            v_vod.pending_chunks,
            v_request_id;

        v_processed_count := v_processed_count + 1;
    END LOOP;

    -- If no VODs were processed, log it
    IF v_processed_count = 0 THEN
        RAISE NOTICE 'No VODs with pending chunks found for processing';
    END IF;

    RETURN;
END;$function$
;

create or replace view "public"."streamer_detection_stats" as  SELECT s.id AS streamer_id,
    s.login,
    s.display_name,
    count(d.id) AS total_detections,
    avg(d.confidence) AS avg_confidence,
    count(d.id) FILTER (WHERE (d.no_right_edge = true)) AS no_right_edge_detections,
    count(DISTINCT v.id) FILTER (WHERE (v.status = 'processing'::public.vod_status)) AS vods_processing,
    count(DISTINCT v.id) FILTER (WHERE (v.status = 'completed'::public.vod_status)) AS vods_completed,
    count(DISTINCT v.id) FILTER (WHERE (v.status = 'failed'::public.vod_status)) AS vods_failed,
    count(DISTINCT v.id) FILTER (WHERE (v.status = 'partial'::public.vod_status)) AS vods_partial,
    count(DISTINCT v.id) FILTER (WHERE (v.status = 'pending'::public.vod_status)) AS vods_pending,
    count(DISTINCT v.id) AS total_vods,
        CASE
            WHEN (count(DISTINCT v.id) > 0) THEN round(((count(d.id))::numeric / (NULLIF(count(DISTINCT v.id), 0))::numeric), 2)
            ELSE (0)::numeric
        END AS avg_detections_per_vod
   FROM ((public.streamers s
     LEFT JOIN public.vods v ON ((v.streamer_id = s.id)))
     LEFT JOIN public.detections d ON ((d.vod_id = v.id)))
  GROUP BY s.id, s.login, s.display_name;


grant delete on table "public"."cataloger_runs" to "anon";

grant insert on table "public"."cataloger_runs" to "anon";

grant references on table "public"."cataloger_runs" to "anon";

grant select on table "public"."cataloger_runs" to "anon";

grant trigger on table "public"."cataloger_runs" to "anon";

grant truncate on table "public"."cataloger_runs" to "anon";

grant update on table "public"."cataloger_runs" to "anon";

grant delete on table "public"."cataloger_runs" to "authenticated";

grant insert on table "public"."cataloger_runs" to "authenticated";

grant references on table "public"."cataloger_runs" to "authenticated";

grant select on table "public"."cataloger_runs" to "authenticated";

grant trigger on table "public"."cataloger_runs" to "authenticated";

grant truncate on table "public"."cataloger_runs" to "authenticated";

grant update on table "public"."cataloger_runs" to "authenticated";

grant delete on table "public"."cataloger_runs" to "service_role";

grant insert on table "public"."cataloger_runs" to "service_role";

grant references on table "public"."cataloger_runs" to "service_role";

grant select on table "public"."cataloger_runs" to "service_role";

grant trigger on table "public"."cataloger_runs" to "service_role";

grant truncate on table "public"."cataloger_runs" to "service_role";

grant update on table "public"."cataloger_runs" to "service_role";

grant delete on table "public"."chunks" to "anon";

grant insert on table "public"."chunks" to "anon";

grant references on table "public"."chunks" to "anon";

grant select on table "public"."chunks" to "anon";

grant trigger on table "public"."chunks" to "anon";

grant truncate on table "public"."chunks" to "anon";

grant update on table "public"."chunks" to "anon";

grant delete on table "public"."chunks" to "authenticated";

grant insert on table "public"."chunks" to "authenticated";

grant references on table "public"."chunks" to "authenticated";

grant select on table "public"."chunks" to "authenticated";

grant trigger on table "public"."chunks" to "authenticated";

grant truncate on table "public"."chunks" to "authenticated";

grant update on table "public"."chunks" to "authenticated";

grant delete on table "public"."chunks" to "service_role";

grant insert on table "public"."chunks" to "service_role";

grant references on table "public"."chunks" to "service_role";

grant select on table "public"."chunks" to "service_role";

grant trigger on table "public"."chunks" to "service_role";

grant truncate on table "public"."chunks" to "service_role";

grant update on table "public"."chunks" to "service_role";

grant delete on table "public"."detections" to "anon";

grant insert on table "public"."detections" to "anon";

grant references on table "public"."detections" to "anon";

grant select on table "public"."detections" to "anon";

grant trigger on table "public"."detections" to "anon";

grant truncate on table "public"."detections" to "anon";

grant update on table "public"."detections" to "anon";

grant delete on table "public"."detections" to "authenticated";

grant insert on table "public"."detections" to "authenticated";

grant references on table "public"."detections" to "authenticated";

grant select on table "public"."detections" to "authenticated";

grant trigger on table "public"."detections" to "authenticated";

grant truncate on table "public"."detections" to "authenticated";

grant update on table "public"."detections" to "authenticated";

grant delete on table "public"."detections" to "service_role";

grant insert on table "public"."detections" to "service_role";

grant references on table "public"."detections" to "service_role";

grant select on table "public"."detections" to "service_role";

grant trigger on table "public"."detections" to "service_role";

grant truncate on table "public"."detections" to "service_role";

grant update on table "public"."detections" to "service_role";

grant delete on table "public"."processing_config" to "anon";

grant insert on table "public"."processing_config" to "anon";

grant references on table "public"."processing_config" to "anon";

grant select on table "public"."processing_config" to "anon";

grant trigger on table "public"."processing_config" to "anon";

grant truncate on table "public"."processing_config" to "anon";

grant update on table "public"."processing_config" to "anon";

grant delete on table "public"."processing_config" to "authenticated";

grant insert on table "public"."processing_config" to "authenticated";

grant references on table "public"."processing_config" to "authenticated";

grant select on table "public"."processing_config" to "authenticated";

grant trigger on table "public"."processing_config" to "authenticated";

grant truncate on table "public"."processing_config" to "authenticated";

grant update on table "public"."processing_config" to "authenticated";

grant delete on table "public"."processing_config" to "service_role";

grant insert on table "public"."processing_config" to "service_role";

grant references on table "public"."processing_config" to "service_role";

grant select on table "public"."processing_config" to "service_role";

grant trigger on table "public"."processing_config" to "service_role";

grant truncate on table "public"."processing_config" to "service_role";

grant update on table "public"."processing_config" to "service_role";

grant delete on table "public"."sfot_profiles" to "anon";

grant insert on table "public"."sfot_profiles" to "anon";

grant references on table "public"."sfot_profiles" to "anon";

grant select on table "public"."sfot_profiles" to "anon";

grant trigger on table "public"."sfot_profiles" to "anon";

grant truncate on table "public"."sfot_profiles" to "anon";

grant update on table "public"."sfot_profiles" to "anon";

grant delete on table "public"."sfot_profiles" to "authenticated";

grant insert on table "public"."sfot_profiles" to "authenticated";

grant references on table "public"."sfot_profiles" to "authenticated";

grant select on table "public"."sfot_profiles" to "authenticated";

grant trigger on table "public"."sfot_profiles" to "authenticated";

grant truncate on table "public"."sfot_profiles" to "authenticated";

grant update on table "public"."sfot_profiles" to "authenticated";

grant delete on table "public"."sfot_profiles" to "service_role";

grant insert on table "public"."sfot_profiles" to "service_role";

grant references on table "public"."sfot_profiles" to "service_role";

grant select on table "public"."sfot_profiles" to "service_role";

grant trigger on table "public"."sfot_profiles" to "service_role";

grant truncate on table "public"."sfot_profiles" to "service_role";

grant update on table "public"."sfot_profiles" to "service_role";

grant delete on table "public"."streamers" to "anon";

grant insert on table "public"."streamers" to "anon";

grant references on table "public"."streamers" to "anon";

grant select on table "public"."streamers" to "anon";

grant trigger on table "public"."streamers" to "anon";

grant truncate on table "public"."streamers" to "anon";

grant update on table "public"."streamers" to "anon";

grant delete on table "public"."streamers" to "authenticated";

grant insert on table "public"."streamers" to "authenticated";

grant references on table "public"."streamers" to "authenticated";

grant select on table "public"."streamers" to "authenticated";

grant trigger on table "public"."streamers" to "authenticated";

grant truncate on table "public"."streamers" to "authenticated";

grant update on table "public"."streamers" to "authenticated";

grant delete on table "public"."streamers" to "service_role";

grant insert on table "public"."streamers" to "service_role";

grant references on table "public"."streamers" to "service_role";

grant select on table "public"."streamers" to "service_role";

grant trigger on table "public"."streamers" to "service_role";

grant truncate on table "public"."streamers" to "service_role";

grant update on table "public"."streamers" to "service_role";

grant delete on table "public"."vods" to "anon";

grant insert on table "public"."vods" to "anon";

grant references on table "public"."vods" to "anon";

grant select on table "public"."vods" to "anon";

grant trigger on table "public"."vods" to "anon";

grant truncate on table "public"."vods" to "anon";

grant update on table "public"."vods" to "anon";

grant delete on table "public"."vods" to "authenticated";

grant insert on table "public"."vods" to "authenticated";

grant references on table "public"."vods" to "authenticated";

grant select on table "public"."vods" to "authenticated";

grant trigger on table "public"."vods" to "authenticated";

grant truncate on table "public"."vods" to "authenticated";

grant update on table "public"."vods" to "authenticated";

grant delete on table "public"."vods" to "service_role";

grant insert on table "public"."vods" to "service_role";

grant references on table "public"."vods" to "service_role";

grant select on table "public"."vods" to "service_role";

grant trigger on table "public"."vods" to "service_role";

grant truncate on table "public"."vods" to "service_role";

grant update on table "public"."vods" to "service_role";

grant delete on table "test"."cataloger_runs" to "anon";

grant insert on table "test"."cataloger_runs" to "anon";

grant references on table "test"."cataloger_runs" to "anon";

grant select on table "test"."cataloger_runs" to "anon";

grant trigger on table "test"."cataloger_runs" to "anon";

grant truncate on table "test"."cataloger_runs" to "anon";

grant update on table "test"."cataloger_runs" to "anon";

grant delete on table "test"."cataloger_runs" to "authenticated";

grant insert on table "test"."cataloger_runs" to "authenticated";

grant references on table "test"."cataloger_runs" to "authenticated";

grant select on table "test"."cataloger_runs" to "authenticated";

grant trigger on table "test"."cataloger_runs" to "authenticated";

grant truncate on table "test"."cataloger_runs" to "authenticated";

grant update on table "test"."cataloger_runs" to "authenticated";

grant delete on table "test"."cataloger_runs" to "service_role";

grant insert on table "test"."cataloger_runs" to "service_role";

grant references on table "test"."cataloger_runs" to "service_role";

grant select on table "test"."cataloger_runs" to "service_role";

grant trigger on table "test"."cataloger_runs" to "service_role";

grant truncate on table "test"."cataloger_runs" to "service_role";

grant update on table "test"."cataloger_runs" to "service_role";

grant delete on table "test"."chunks" to "anon";

grant insert on table "test"."chunks" to "anon";

grant references on table "test"."chunks" to "anon";

grant select on table "test"."chunks" to "anon";

grant trigger on table "test"."chunks" to "anon";

grant truncate on table "test"."chunks" to "anon";

grant update on table "test"."chunks" to "anon";

grant delete on table "test"."chunks" to "authenticated";

grant insert on table "test"."chunks" to "authenticated";

grant references on table "test"."chunks" to "authenticated";

grant select on table "test"."chunks" to "authenticated";

grant trigger on table "test"."chunks" to "authenticated";

grant truncate on table "test"."chunks" to "authenticated";

grant update on table "test"."chunks" to "authenticated";

grant delete on table "test"."chunks" to "service_role";

grant insert on table "test"."chunks" to "service_role";

grant references on table "test"."chunks" to "service_role";

grant select on table "test"."chunks" to "service_role";

grant trigger on table "test"."chunks" to "service_role";

grant truncate on table "test"."chunks" to "service_role";

grant update on table "test"."chunks" to "service_role";

grant delete on table "test"."detections" to "anon";

grant insert on table "test"."detections" to "anon";

grant references on table "test"."detections" to "anon";

grant select on table "test"."detections" to "anon";

grant trigger on table "test"."detections" to "anon";

grant truncate on table "test"."detections" to "anon";

grant update on table "test"."detections" to "anon";

grant delete on table "test"."detections" to "authenticated";

grant insert on table "test"."detections" to "authenticated";

grant references on table "test"."detections" to "authenticated";

grant select on table "test"."detections" to "authenticated";

grant trigger on table "test"."detections" to "authenticated";

grant truncate on table "test"."detections" to "authenticated";

grant update on table "test"."detections" to "authenticated";

grant delete on table "test"."detections" to "service_role";

grant insert on table "test"."detections" to "service_role";

grant references on table "test"."detections" to "service_role";

grant select on table "test"."detections" to "service_role";

grant trigger on table "test"."detections" to "service_role";

grant truncate on table "test"."detections" to "service_role";

grant update on table "test"."detections" to "service_role";

grant delete on table "test"."processing_config" to "anon";

grant insert on table "test"."processing_config" to "anon";

grant references on table "test"."processing_config" to "anon";

grant select on table "test"."processing_config" to "anon";

grant trigger on table "test"."processing_config" to "anon";

grant truncate on table "test"."processing_config" to "anon";

grant update on table "test"."processing_config" to "anon";

grant delete on table "test"."processing_config" to "authenticated";

grant insert on table "test"."processing_config" to "authenticated";

grant references on table "test"."processing_config" to "authenticated";

grant select on table "test"."processing_config" to "authenticated";

grant trigger on table "test"."processing_config" to "authenticated";

grant truncate on table "test"."processing_config" to "authenticated";

grant update on table "test"."processing_config" to "authenticated";

grant delete on table "test"."processing_config" to "service_role";

grant insert on table "test"."processing_config" to "service_role";

grant references on table "test"."processing_config" to "service_role";

grant select on table "test"."processing_config" to "service_role";

grant trigger on table "test"."processing_config" to "service_role";

grant truncate on table "test"."processing_config" to "service_role";

grant update on table "test"."processing_config" to "service_role";

grant delete on table "test"."sfot_profiles" to "anon";

grant insert on table "test"."sfot_profiles" to "anon";

grant references on table "test"."sfot_profiles" to "anon";

grant select on table "test"."sfot_profiles" to "anon";

grant trigger on table "test"."sfot_profiles" to "anon";

grant truncate on table "test"."sfot_profiles" to "anon";

grant update on table "test"."sfot_profiles" to "anon";

grant delete on table "test"."sfot_profiles" to "authenticated";

grant insert on table "test"."sfot_profiles" to "authenticated";

grant references on table "test"."sfot_profiles" to "authenticated";

grant select on table "test"."sfot_profiles" to "authenticated";

grant trigger on table "test"."sfot_profiles" to "authenticated";

grant truncate on table "test"."sfot_profiles" to "authenticated";

grant update on table "test"."sfot_profiles" to "authenticated";

grant delete on table "test"."sfot_profiles" to "service_role";

grant insert on table "test"."sfot_profiles" to "service_role";

grant references on table "test"."sfot_profiles" to "service_role";

grant select on table "test"."sfot_profiles" to "service_role";

grant trigger on table "test"."sfot_profiles" to "service_role";

grant truncate on table "test"."sfot_profiles" to "service_role";

grant update on table "test"."sfot_profiles" to "service_role";

grant delete on table "test"."streamers" to "anon";

grant insert on table "test"."streamers" to "anon";

grant references on table "test"."streamers" to "anon";

grant select on table "test"."streamers" to "anon";

grant trigger on table "test"."streamers" to "anon";

grant truncate on table "test"."streamers" to "anon";

grant update on table "test"."streamers" to "anon";

grant delete on table "test"."streamers" to "authenticated";

grant insert on table "test"."streamers" to "authenticated";

grant references on table "test"."streamers" to "authenticated";

grant select on table "test"."streamers" to "authenticated";

grant trigger on table "test"."streamers" to "authenticated";

grant truncate on table "test"."streamers" to "authenticated";

grant update on table "test"."streamers" to "authenticated";

grant delete on table "test"."streamers" to "service_role";

grant insert on table "test"."streamers" to "service_role";

grant references on table "test"."streamers" to "service_role";

grant select on table "test"."streamers" to "service_role";

grant trigger on table "test"."streamers" to "service_role";

grant truncate on table "test"."streamers" to "service_role";

grant update on table "test"."streamers" to "service_role";

grant delete on table "test"."vods" to "anon";

grant insert on table "test"."vods" to "anon";

grant references on table "test"."vods" to "anon";

grant select on table "test"."vods" to "anon";

grant trigger on table "test"."vods" to "anon";

grant truncate on table "test"."vods" to "anon";

grant update on table "test"."vods" to "anon";

grant delete on table "test"."vods" to "authenticated";

grant insert on table "test"."vods" to "authenticated";

grant references on table "test"."vods" to "authenticated";

grant select on table "test"."vods" to "authenticated";

grant trigger on table "test"."vods" to "authenticated";

grant truncate on table "test"."vods" to "authenticated";

grant update on table "test"."vods" to "authenticated";

grant delete on table "test"."vods" to "service_role";

grant insert on table "test"."vods" to "service_role";

grant references on table "test"."vods" to "service_role";

grant select on table "test"."vods" to "service_role";

grant trigger on table "test"."vods" to "service_role";

grant truncate on table "test"."vods" to "service_role";

grant update on table "test"."vods" to "service_role";


  create policy "processing_config_block_client_delete"
  on "public"."processing_config"
  as permissive
  for delete
  to authenticated
using (false);



  create policy "processing_config_block_client_insert"
  on "public"."processing_config"
  as permissive
  for insert
  to authenticated
with check (false);



  create policy "processing_config_block_client_select"
  on "public"."processing_config"
  as permissive
  for select
  to authenticated
using (false);



  create policy "processing_config_block_client_update"
  on "public"."processing_config"
  as permissive
  for update
  to authenticated
using (false)
with check (false);


CREATE TRIGGER vods_mark_chunks_failed_trigger AFTER UPDATE OF status ON public.vods FOR EACH ROW WHEN ((old.status IS DISTINCT FROM new.status)) EXECUTE FUNCTION public.vods_mark_chunks_failed_on_vod_failure();

CREATE TRIGGER trigger_auto_create_chunks AFTER INSERT OR UPDATE OF ready_for_processing, duration_seconds, bazaar_chapters ON public.vods FOR EACH ROW EXECUTE FUNCTION public.auto_create_chunks();


