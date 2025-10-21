-- Add no_right_edge column to track partial occlusion cases
-- When true, indicates the right edge of the nameplate was not detected,
-- possibly due to streamer cam overlay

-- Add to public schema
ALTER TABLE public.detections
ADD COLUMN IF NOT EXISTS no_right_edge BOOLEAN DEFAULT false;

-- Add to test schema
ALTER TABLE test.detections
ADD COLUMN IF NOT EXISTS no_right_edge BOOLEAN DEFAULT false;

-- Add comment to document the column
COMMENT ON COLUMN public.detections.no_right_edge IS 'Indicates if right edge detection failed, suggesting possible streamer cam occlusion';
COMMENT ON COLUMN test.detections.no_right_edge IS 'Indicates if right edge detection failed, suggesting possible streamer cam occlusion';

-- Create index for filtering/analysis
CREATE INDEX IF NOT EXISTS idx_detections_no_right_edge ON public.detections(no_right_edge) WHERE no_right_edge = true;
CREATE INDEX IF NOT EXISTS idx_test_detections_no_right_edge ON test.detections(no_right_edge) WHERE no_right_edge = true;