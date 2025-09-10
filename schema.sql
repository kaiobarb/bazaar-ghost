-- Bazaar Ghost Database Schema v2
-- Building on first iteration, adding control plane features

-- ============================================
-- ENUMS
-- ============================================

CREATE TYPE processing_status AS ENUM (
  'pending',
  'queued',
  'processing',
  'completed',
  'failed',
  'archived'
);

CREATE TYPE vod_availability AS ENUM (
  'available',
  'checking',
  'unavailable',
  'expired'
);

CREATE TYPE chunk_source AS ENUM (
  'vod',
  'live'
);

-- Enable required extension for exclusion constraints
CREATE EXTENSION IF NOT EXISTS btree_gist;


-- ============================================
-- CORE TABLES
-- ============================================

-- Streamers table with vetting controls
CREATE TABLE streamers (
  id BIGINT PRIMARY KEY,
  login TEXT UNIQUE NOT NULL,
  display_name TEXT,
  profile_image_url TEXT,
  
  -- Processing controls
  processing_enabled BOOLEAN DEFAULT FALSE,
  
  -- Discovery metadata
  first_seen_at TIMESTAMPTZ DEFAULT NOW(),
  last_seen_streaming_bazaar TIMESTAMPTZ,
  
  -- Stats
  total_vods INT DEFAULT 0,
  processed_vods INT DEFAULT 0,
  total_detections INT DEFAULT 0,
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- VODs table
CREATE TABLE vods (
  id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  streamer_id BIGINT REFERENCES streamers(id) ON DELETE CASCADE,
  
  -- Source tracking
  source TEXT NOT NULL DEFAULT 'twitch',
  source_id TEXT NOT NULL,
  
  -- Metadata
  title TEXT,
  duration_seconds INT,
  published_at TIMESTAMPTZ,
  
  -- Availability tracking
  availability vod_availability DEFAULT 'available',
  last_availability_check TIMESTAMPTZ,
  unavailable_since TIMESTAMPTZ,
  
  -- Processing controls
  ready_for_processing BOOLEAN DEFAULT FALSE,
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  
  UNIQUE(source, source_id)
);

CREATE INDEX idx_vods_streamer ON vods(streamer_id);
CREATE INDEX idx_vods_availability ON vods(availability);

-- Processing chunks (30-minute segments)
CREATE TABLE chunks (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  vod_id BIGINT REFERENCES vods(id) ON DELETE CASCADE,
  
  -- Chunk boundaries
  start_seconds INT NOT NULL,
  end_seconds INT NOT NULL,
  chunk_index INT NOT NULL, -- 0-based index within VOD
  
  -- Processing state
  status processing_status DEFAULT 'pending',
  source chunk_source DEFAULT 'vod',
  
  -- Queue management
  queued_at TIMESTAMPTZ,
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  
  -- Worker tracking
  worker_id TEXT,
  attempt_count INT DEFAULT 0,
  last_error TEXT,
  
  -- Results
  frames_processed INT DEFAULT 0,
  detections_count INT DEFAULT 0,
  processing_duration_ms INT,
  
  -- Queue management
  priority INT DEFAULT 0,
  scheduled_for TIMESTAMPTZ DEFAULT NOW(),
  lease_expires_at TIMESTAMPTZ,
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  
  UNIQUE(vod_id, chunk_index),
  
  -- Prevent overlapping time ranges for same VOD
  EXCLUDE USING gist (
    vod_id WITH =,
    int4range(start_seconds, end_seconds) WITH &&
  )
);

CREATE INDEX idx_chunks_status ON chunks(status);
CREATE INDEX idx_chunks_vod ON chunks(vod_id);
CREATE INDEX idx_chunks_ready ON chunks(scheduled_for, priority DESC) 
  WHERE status = 'pending' AND (lease_expires_at IS NULL OR lease_expires_at < NOW());

-- Detections (evolved from matchups)
CREATE TABLE detections (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  chunk_id UUID REFERENCES chunks(id) ON DELETE CASCADE,
  vod_id BIGINT REFERENCES vods(id) ON DELETE CASCADE,
  
  -- Detection data
  username TEXT NOT NULL,
  confidence FLOAT,
  rank TEXT CHECK (rank IN ('bronze', 'silver', 'gold', 'diamond', 'legend')),
  
  -- Timestamp within VOD
  frame_time_seconds INT NOT NULL,
  
  -- OCR/processing metadata
  ocr_text TEXT,
  storage_path TEXT, -- Path to image in Supabase Storage
  processing_metadata JSONB
  
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_detections_username ON detections(LOWER(username));
CREATE INDEX idx_detections_vod ON detections(vod_id);

-- ============================================
-- CONTROL PLANE TABLES
-- ============================================

-- Cataloger state tracking
CREATE TABLE cataloger_runs (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  run_type TEXT CHECK (run_type IN ('discovery', 'refresh', 'backfill')),
  
  started_at TIMESTAMPTZ DEFAULT NOW(),
  completed_at TIMESTAMPTZ,
  
  -- Discovery stats
  streamers_discovered INT DEFAULT 0,
  streamers_updated INT DEFAULT 0,
  vods_discovered INT DEFAULT 0,
  chunks_created INT DEFAULT 0,
  
  -- Error tracking
  errors JSONB DEFAULT '[]',
  status TEXT DEFAULT 'running',
  
  metadata JSONB DEFAULT '{}'
);

-- SFOT container profiles
CREATE TABLE sfot_profiles (
  profile_name TEXT PRIMARY KEY,
  
  -- Container configuration
  container_image TEXT NOT NULL,
  container_tag TEXT NOT NULL,
  
  -- Processing parameters
  frame_interval_seconds INT DEFAULT 5,
  confidence_threshold FLOAT DEFAULT 0.7,
  
  -- Resource limits
  memory_mb INT DEFAULT 2048,
  cpu_millicores INT DEFAULT 1000,
  timeout_seconds INT DEFAULT 1800,
  
  -- Feature flags
  enable_gpu BOOLEAN DEFAULT FALSE,
  enable_debug_output BOOLEAN DEFAULT FALSE,
  
  metadata JSONB DEFAULT '{}',
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

-- Function to create chunks for a VOD segment
CREATE OR REPLACE FUNCTION create_chunks_for_segment(
  p_vod_id BIGINT,
  p_start_seconds INT,
  p_end_seconds INT,
  p_chunk_duration_seconds INT DEFAULT 1800
) RETURNS INT AS $$
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
$$ LANGUAGE plpgsql;

-- Function to auto-create chunks when VOD is ready for processing
CREATE OR REPLACE FUNCTION auto_create_chunks() RETURNS TRIGGER AS $$
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
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_auto_chunks
  AFTER INSERT OR UPDATE OF ready_for_processing ON vods
  FOR EACH ROW
  EXECUTE FUNCTION auto_create_chunks();

-- Function to create chunks for newly enabled streamers
CREATE OR REPLACE FUNCTION create_chunks_for_enabled_streamer() RETURNS TRIGGER AS $$
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
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_streamer_enabled
  AFTER UPDATE OF processing_enabled ON streamers
  FOR EACH ROW
  EXECUTE FUNCTION create_chunks_for_enabled_streamer();

-- Function to clean up chunks when processing is disabled
CREATE OR REPLACE FUNCTION cleanup_chunks_on_disable() RETURNS TRIGGER AS $$
BEGIN
  -- When VOD processing is disabled
  IF TG_TABLE_NAME = 'vods' AND NEW.ready_for_processing = FALSE THEN
    DELETE FROM chunks 
    WHERE vod_id = NEW.id
    AND status IN ('pending', 'processing');
    
  -- When streamer processing is disabled  
  ELSIF TG_TABLE_NAME = 'streamers' AND NEW.processing_enabled = FALSE THEN
    DELETE FROM chunks 
    WHERE vod_id IN (SELECT id FROM vods WHERE streamer_id = NEW.id)
    AND status IN ('pending', 'processing');
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_vod_processing_disabled
  AFTER UPDATE OF ready_for_processing ON vods
  FOR EACH ROW
  EXECUTE FUNCTION cleanup_chunks_on_disable();

CREATE TRIGGER trigger_streamer_processing_disabled
  AFTER UPDATE OF processing_enabled ON streamers
  FOR EACH ROW
  EXECUTE FUNCTION cleanup_chunks_on_disable();

-- View for visible detections (replaces is_visible column and trigger)
CREATE VIEW visible_detections AS
SELECT d.*
FROM detections d
JOIN vods v ON d.vod_id = v.id
WHERE v.availability = 'available';

-- ============================================
-- ROW LEVEL SECURITY
-- ============================================

ALTER TABLE detections ENABLE ROW LEVEL SECURITY;
ALTER TABLE vods ENABLE ROW LEVEL SECURITY;

-- Public read access to detections only through available VODs
CREATE POLICY "Public can view detections from available VODs" ON detections
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM vods 
      WHERE vods.id = detections.vod_id 
      AND vods.availability = 'available'
    )
  );

-- Public read access to available VODs
CREATE POLICY "Public can view available VODs" ON vods
  FOR SELECT
  USING (availability = 'available');