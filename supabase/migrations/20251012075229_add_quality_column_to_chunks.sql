-- Add quality column to chunks table to track processing resolution
ALTER TABLE public.chunks
ADD COLUMN quality text;

-- Add comment for documentation
COMMENT ON COLUMN public.chunks.quality IS 'Video quality/resolution used for processing this chunk (e.g., 360p, 720p, 1080p)';