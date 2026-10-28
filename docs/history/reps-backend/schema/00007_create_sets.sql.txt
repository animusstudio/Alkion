-- +goose Up
-- A single working/warmup set within a session. weight_kg is NUMERIC for exact
-- decimal loads. rir = reps-in-reserve. is_warmup is client intent; is_top_set
-- and is_pr are computed server-side on write (never trusted from the client).
-- user_id is DENORMALIZED from the parent session and stamped server-side on
-- write: PowerSync classic sync rules cannot JOIN, so the per-user sync rule
-- filters sets directly on this column. updated_at supports the editable window.
CREATE TABLE sets (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id      UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    exercise_id     UUID NOT NULL REFERENCES exercises(id),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    set_number      INTEGER NOT NULL,
    weight_kg       NUMERIC(6, 2) NOT NULL,
    reps            INTEGER NOT NULL,
    rir             INTEGER,
    is_warmup       BOOLEAN NOT NULL DEFAULT FALSE,
    is_top_set      BOOLEAN NOT NULL DEFAULT FALSE,
    is_pr           BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX sets_session_idx ON sets (session_id, set_number);
CREATE INDEX sets_exercise_idx ON sets (exercise_id, created_at);
CREATE INDEX sets_user_id_idx ON sets (user_id);

-- +goose Down
DROP TABLE sets;
