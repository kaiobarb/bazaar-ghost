-- Bazaar Ghost Seed Data
-- This file seeds the local database with test data

-- Insert default SFOT profile
INSERT INTO sfot_profiles (profile_name, container_image, container_tag) VALUES
('default', 'ghcr.io/your-username/bazaar-ghost-sfot', 'latest'),
('gpu-optimized', 'ghcr.io/your-username/bazaar-ghost-sfot', 'gpu'),
('debug', 'ghcr.io/your-username/bazaar-ghost-sfot', 'debug');

-- Insert sample streamers (not processing enabled by default)
INSERT INTO streamers (id, login, display_name, profile_image_url, first_seen_at) VALUES
(12345, 'testkripp', 'Test Kripparian', 'https://example.com/avatar1.jpg', NOW() - INTERVAL '7 days'),
(67890, 'teststreamer', 'Test Streamer', 'https://example.com/avatar2.jpg', NOW() - INTERVAL '3 days'),
(11111, 'testuser3', 'Another Test User', 'https://example.com/avatar3.jpg', NOW() - INTERVAL '1 day');

-- Insert sample VODs (not ready for processing by default)
INSERT INTO vods (streamer_id, source, source_id, title, duration_seconds, published_at) VALUES
(12345, 'twitch', '1234567890', 'Epic Bazaar Stream - Climbing to Legend', 7200, NOW() - INTERVAL '2 days'),
(12345, 'twitch', '1234567891', 'More Bazaar Gameplay', 5400, NOW() - INTERVAL '1 day'),
(67890, 'twitch', '2345678901', 'Learning The Bazaar Basics', 3600, NOW() - INTERVAL '6 hours');

-- Enable processing for one test streamer and mark one VOD as ready
UPDATE streamers SET processing_enabled = true WHERE id = 12345;
UPDATE vods SET ready_for_processing = true WHERE source_id = '1234567890';

-- The trigger will automatically create chunks for the ready VOD
-- from the enabled streamer (vod with source_id '1234567890')