-- +goose Up
-- PowerSync logical-replication prerequisites. The publication name MUST be
-- exactly "powersync" (not configurable). Scoped to the tables PowerSync syncs
-- (currently only exercises); never publish refresh_tokens (token hashes must
-- not enter the WAL/replication stream). Add `users` here only when a sync rule
-- references it: ALTER PUBLICATION powersync ADD TABLE users;
CREATE PUBLICATION powersync FOR TABLE exercises;

-- Least-privilege role PowerSync connects as. Created NOLOGIN with no password
-- here (no secret in git); a one-time out-of-band step grants LOGIN + PASSWORD
-- from PS_REPLICATION_PASSWORD. REPLICATION is required for logical replication;
-- BYPASSRLS so row-level security never hides rows from the initial snapshot.
CREATE ROLE powersync_role WITH NOLOGIN REPLICATION BYPASSRLS;
GRANT CONNECT ON DATABASE workout_tracker TO powersync_role;
GRANT USAGE ON SCHEMA public TO powersync_role;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO powersync_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO powersync_role;

-- +goose Down
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE SELECT ON TABLES FROM powersync_role;
REVOKE SELECT ON ALL TABLES IN SCHEMA public FROM powersync_role;
REVOKE USAGE ON SCHEMA public FROM powersync_role;
REVOKE CONNECT ON DATABASE workout_tracker FROM powersync_role;
DROP ROLE IF EXISTS powersync_role;
DROP PUBLICATION IF EXISTS powersync;
