-- Provision the screenshot bucket on fresh environments; preserve existing bucket settings.
INSERT INTO storage.buckets (id, name, public)
VALUES ('detections', 'detections', true)
ON CONFLICT (id) DO NOTHING;
