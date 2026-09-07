-- Rename sfot_profiles to sfde_profiles and update all references

-- Rename the table
ALTER TABLE public.sfot_profiles RENAME TO sfde_profiles;

-- Rename the sequence
ALTER SEQUENCE public.sfot_profiles_id_seq RENAME TO sfde_profiles_id_seq;

-- Rename the column on streamers
ALTER TABLE public.streamers RENAME COLUMN sfot_profile_id TO sfde_profile_id;

-- Rename constraints
ALTER TABLE public.sfde_profiles RENAME CONSTRAINT sfot_profiles_pkey TO sfde_profiles_pkey;
ALTER TABLE public.sfde_profiles RENAME CONSTRAINT sfot_profiles_profile_name_key TO sfde_profiles_profile_name_key;
ALTER TABLE public.streamers RENAME CONSTRAINT streamers_sfot_profile_id_fkey TO streamers_sfde_profile_id_fkey;

-- Rename indexes
ALTER INDEX public.idx_sfot_profiles_dates RENAME TO idx_sfde_profiles_dates;
ALTER INDEX public.idx_sfot_profiles_profile_name RENAME TO idx_sfde_profiles_profile_name;
ALTER INDEX public.idx_streamers_sfot_profile RENAME TO idx_streamers_sfde_profile;

-- Update table and column comments
COMMENT ON TABLE public.sfde_profiles IS 'SFDE processing profiles';
COMMENT ON COLUMN public.streamers.sfde_profile_id IS 'SFDE processing profile to use for this streamer';
COMMENT ON COLUMN public.detections.truncated IS 'Whether the username was truncated using custom edge from sfde_profiles (due to camera/UI occlusion)';

-- Drop old RLS policies and recreate with new names
-- (RLS policies cannot be renamed, must drop and recreate)
DROP POLICY IF EXISTS "Allow authenticated delete" ON public.sfde_profiles;
DROP POLICY IF EXISTS "Allow authenticated insert" ON public.sfde_profiles;
DROP POLICY IF EXISTS "Allow authenticated update" ON public.sfde_profiles;
DROP POLICY IF EXISTS "Allow public read access" ON public.sfde_profiles;
DROP POLICY IF EXISTS "Public users can insert sfot_profiles" ON public.sfde_profiles;
DROP POLICY IF EXISTS "Public users can update sfot_profiles" ON public.sfde_profiles;

CREATE POLICY "Allow authenticated delete" ON public.sfde_profiles FOR DELETE TO authenticated USING (true);
CREATE POLICY "Allow authenticated insert" ON public.sfde_profiles FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "Allow authenticated update" ON public.sfde_profiles FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "Allow public read access" ON public.sfde_profiles FOR SELECT USING (true);
CREATE POLICY "Public users can insert sfde_profiles" ON public.sfde_profiles FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY "Public users can update sfde_profiles" ON public.sfde_profiles FOR UPDATE USING (true) WITH CHECK (true);
