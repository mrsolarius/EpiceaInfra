-- PostgreSQL initialization script for Immich
-- Using ghcr.io/immich-app/postgres image with VectorChord support

-- Enable required extensions for Immich
CREATE EXTENSION IF NOT EXISTS cube;
CREATE EXTENSION IF NOT EXISTS earthdistance;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS vectors;

-- Ensure schema public is owned by the user (needed for migrations)
-- The user is passed via POSTGRES_USER environment variable
ALTER SCHEMA public OWNER TO CURRENT_USER;
