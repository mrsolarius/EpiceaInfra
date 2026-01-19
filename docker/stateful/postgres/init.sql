-- PostgreSQL initialization script for Epicea Infrastructure
-- Enables performance monitoring extensions and creates necessary schemas
-- Using ghcr.io/immich-app/postgres image with VectorChord support

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Configure pg_stat_statements
ALTER SYSTEM SET pg_stat_statements.track = 'all';
ALTER SYSTEM SET pg_stat_statements.max = 10000;
ALTER SYSTEM SET pg_stat_statements.track_utility = on;
ALTER SYSTEM SET pg_stat_statements.track_planning = on;

-- Enable timing statistics for I/O operations (required for blk_read_time and blk_write_time)
ALTER SYSTEM SET track_io_timing = on;

-- Enable activity tracking
ALTER SYSTEM SET track_activities = on;
ALTER SYSTEM SET track_counts = on;
ALTER SYSTEM SET track_functions = 'all';

-- Configure autovacuum for better performance monitoring
ALTER SYSTEM SET log_autovacuum_min_duration = 0;

-- Improve query logging for debugging (adjust as needed for production)
ALTER SYSTEM SET log_min_duration_statement = 1000; -- Log queries taking more than 1 second
ALTER SYSTEM SET log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h ';
ALTER SYSTEM SET log_lock_waits = on;
ALTER SYSTEM SET log_temp_files = 0; -- Log all temp file usage (disk spillage)
ALTER SYSTEM SET log_checkpoints = on;
ALTER SYSTEM SET log_connections = on;
ALTER SYSTEM SET log_disconnections = on;
ALTER SYSTEM SET log_duration = off; -- Already covered by log_min_duration_statement

-- After this initialization, PostgreSQL will need to be restarted
-- for some settings to take effect (pg_stat_statements.track, etc.)
