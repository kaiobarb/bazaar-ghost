-- Grant permissions on test schema to API roles
-- This is required for the REST API to access the test schema

-- Grant usage on the test schema
GRANT USAGE ON SCHEMA test TO anon, authenticated, service_role;

-- Grant all privileges on all tables in test schema
GRANT ALL ON ALL TABLES IN SCHEMA test TO anon, authenticated, service_role;

-- Grant all privileges on all sequences in test schema
GRANT ALL ON ALL SEQUENCES IN SCHEMA test TO anon, authenticated, service_role;

-- Grant all privileges on all functions in test schema
GRANT ALL ON ALL FUNCTIONS IN SCHEMA test TO anon, authenticated, service_role;

-- Set default privileges for future tables/sequences/functions
ALTER DEFAULT PRIVILEGES IN SCHEMA test GRANT ALL ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA test GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA test GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;

-- Also need to expose the schema in the API settings
-- This would need to be done in the Supabase dashboard or via the management API
-- Dashboard: Settings -> API -> Additional schemas -> Add "test"
COMMENT ON SCHEMA test IS 'Test schema exposed via REST API - remember to add to API settings';