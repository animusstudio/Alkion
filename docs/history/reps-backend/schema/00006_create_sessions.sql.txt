-- +goose Up
-- A training session: one workout on one date. split_label names the rotation
-- slot (e.g. "Upper A"); notes is freeform. UUID PK → default REPLICA IDENTITY
-- is enough for PowerSync to replicate UPDATE/DELETE.
CREATE TABLE sessions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    date            DATE NOT NULL,
    split_label     TEXT,
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX sessions_user_date_idx ON sessions (user_id, date DESC);

-- +goose Down
DROP TABLE sessions;
