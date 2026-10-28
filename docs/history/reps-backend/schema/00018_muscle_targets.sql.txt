-- +goose Up
-- Per-user weekly set target per muscle group (Today / Progress volume bars).
-- One row per (user, muscle). Synced per-user via the by_user bucket.
CREATE TABLE muscle_targets (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    muscle      TEXT NOT NULL,
    target_sets INTEGER NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, muscle)
);

CREATE INDEX muscle_targets_user_idx ON muscle_targets (user_id);

ALTER PUBLICATION powersync ADD TABLE muscle_targets;
GRANT SELECT ON muscle_targets TO powersync_role;

-- +goose Down
ALTER PUBLICATION powersync DROP TABLE muscle_targets;
DROP TABLE muscle_targets;
