-- PostgreSQL initialization script for Immich
-- Using ghcr.io/immich-app/postgres image with VectorChord support

-- Enable required extensions for Immich
CREATE EXTENSION IF NOT EXISTS cube;
CREATE EXTENSION IF NOT EXISTS earthdistance;

-- Note: VectorChord extension is automatically managed by Immich
-- No need to create it manually
