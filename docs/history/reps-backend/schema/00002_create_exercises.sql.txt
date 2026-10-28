-- +goose Up
CREATE TABLE exercises (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT NOT NULL,
    slug            TEXT NOT NULL UNIQUE,
    muscle_group    TEXT NOT NULL,
    is_template     BOOLEAN NOT NULL DEFAULT FALSE,
    created_by      UUID REFERENCES users(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX exercises_muscle_group_idx ON exercises (muscle_group);
CREATE INDEX exercises_created_by_idx ON exercises (created_by);

-- +goose Down
DROP TABLE exercises;
