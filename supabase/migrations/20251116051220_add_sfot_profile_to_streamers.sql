-- Add sfot_profile column to streamers table
-- This references the sfot_profiles table to specify which processing profile to use

ALTER TABLE public.streamers
ADD COLUMN sfot_profile_id bigint DEFAULT 1 REFERENCES public.sfot_profiles(id);

-- Add index for faster profile lookups
CREATE INDEX idx_streamers_sfot_profile ON public.streamers(sfot_profile_id);

-- Add comment
COMMENT ON COLUMN public.streamers.sfot_profile_id IS 'SFOT processing profile to use for this streamer (defaults to profile ID 1 - default)';

-- Set ChronosOutOfTime (streamer ID 89389140) to use ChronosOutOfTime profile
UPDATE public.streamers
SET sfot_profile_id = (SELECT id FROM public.sfot_profiles WHERE profile_name = 'ChronosOutOfTime')
WHERE id = 89389140;
