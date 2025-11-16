-- Drop the existing sfot_profiles table if it exists
DROP TABLE IF EXISTS public.sfot_profiles CASCADE;

-- Create the sfot_profiles table
CREATE TABLE public.sfot_profiles (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    profile_name text NOT NULL UNIQUE,
    crop_region numeric[] NOT NULL,
    scale numeric DEFAULT 1.0,
    custom_edge numeric DEFAULT NULL,
    opaque_edge boolean DEFAULT true,
    from_date timestamp with time zone DEFAULT NULL,
    to_date timestamp with time zone DEFAULT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),

    -- Constraint to ensure crop_region has exactly 4 elements
    CONSTRAINT crop_region_length CHECK (array_length(crop_region, 1) = 4)
);

-- Create an index on profile_name for faster lookups
CREATE INDEX idx_sfot_profiles_profile_name ON public.sfot_profiles(profile_name);

-- Create an index on date ranges for temporal queries
CREATE INDEX idx_sfot_profiles_dates ON public.sfot_profiles(from_date, to_date);

-- Enable Row Level Security
ALTER TABLE public.sfot_profiles ENABLE ROW LEVEL SECURITY;

-- Create RLS policies
-- Allow public read access (for SFOT processing)
CREATE POLICY "Allow public read access" ON public.sfot_profiles
    FOR SELECT
    USING (true);

-- Allow authenticated users to insert profiles
CREATE POLICY "Allow authenticated insert" ON public.sfot_profiles
    FOR INSERT
    TO authenticated
    WITH CHECK (true);

-- Allow authenticated users to update profiles
CREATE POLICY "Allow authenticated update" ON public.sfot_profiles
    FOR UPDATE
    TO authenticated
    USING (true)
    WITH CHECK (true);

-- Allow authenticated users to delete profiles
CREATE POLICY "Allow authenticated delete" ON public.sfot_profiles
    FOR DELETE
    TO authenticated
    USING (true);

-- Create trigger function to update updated_at timestamp
CREATE OR REPLACE FUNCTION public.handle_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger for updated_at
CREATE TRIGGER set_updated_at
    BEFORE UPDATE ON public.sfot_profiles
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_updated_at();

-- Add comment to table
COMMENT ON TABLE public.sfot_profiles IS 'SFOT processing profiles';

-- Add comments to columns
COMMENT ON COLUMN public.sfot_profiles.profile_name IS 'Unique name for the profile (e.g., "720p60-2024-11", "1080p60-2025-01")';
COMMENT ON COLUMN public.sfot_profiles.crop_region IS 'Array of 4 decimals [x, y, width, height] as percentages (e.g., {0.5726, 0.7333, 0.3500, 0.1125})';
COMMENT ON COLUMN public.sfot_profiles.scale IS 'Scale factor for template images (default 1.0)';
COMMENT ON COLUMN public.sfot_profiles.custom_edge IS 'Custom edge value as percentage of crop_region width (optional)';
COMMENT ON COLUMN public.sfot_profiles.opaque_edge IS 'Whether to use opaque edge processing (default true)';
COMMENT ON COLUMN public.sfot_profiles.from_date IS 'Start date of vods that this profile should apply to';
COMMENT ON COLUMN public.sfot_profiles.to_date IS 'End date of vods that this profile should apply to';