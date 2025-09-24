-- Enable RLS on streamers table with permissive policies
ALTER TABLE streamers ENABLE ROW LEVEL SECURITY;

-- Allow all operations on streamers (maintains current development workflow)
CREATE POLICY "streamers_all_access" ON streamers
FOR ALL USING (true) WITH CHECK (true);

-- Enable RLS on chunks table with permissive policies
ALTER TABLE chunks ENABLE ROW LEVEL SECURITY;

-- Allow all operations on chunks (maintains current development workflow)
CREATE POLICY "chunks_all_access" ON chunks
FOR ALL USING (true) WITH CHECK (true);

-- Enable RLS on cataloger_runs table with permissive policies
ALTER TABLE cataloger_runs ENABLE ROW LEVEL SECURITY;

-- Allow all operations on cataloger_runs (maintains current development workflow)
CREATE POLICY "cataloger_runs_all_access" ON cataloger_runs
FOR ALL USING (true) WITH CHECK (true);

-- Enable RLS on sfot_profiles table with permissive policies
ALTER TABLE sfot_profiles ENABLE ROW LEVEL SECURITY;

-- Allow all operations on sfot_profiles (maintains current development workflow)
CREATE POLICY "sfot_profiles_all_access" ON sfot_profiles
FOR ALL USING (true) WITH CHECK (true);

-- Add missing index on detections.chunk_id foreign key for better performance
CREATE INDEX idx_detections_chunk_id ON detections(chunk_id);