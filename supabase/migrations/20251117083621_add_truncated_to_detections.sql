-- Add truncated column to detections table to track when custom edge was used for username truncation
ALTER TABLE public.detections
ADD COLUMN truncated boolean DEFAULT false;

-- Add comment to explain the column
COMMENT ON COLUMN public.detections.truncated IS 'Whether the username was truncated using custom edge from sfot_profiles (due to camera/UI occlusion)';

-- Create index for filtering truncated detections (useful for analysis)
CREATE INDEX idx_detections_truncated ON public.detections(truncated) WHERE truncated = true;