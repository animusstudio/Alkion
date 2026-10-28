-- +goose Up
-- A reusable workout day (e.g. "Upper A"). Shared seeded days have
-- is_template=TRUE, created_by=NULL; user-created custom days have
-- is_template=FALSE, created_by=<user>. slug is set only for seeded days
-- (idempotent seeding); custom days leave it NULL (multiple NULLs allowed).
CREATE TABLE day_templates (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slug         TEXT UNIQUE,
    name         TEXT NOT NULL,
    notes        TEXT,
    position     INTEGER NOT NULL DEFAULT 0,
    is_template  BOOLEAN NOT NULL DEFAULT FALSE,
    created_by   UUID REFERENCES users(id) ON DELETE CASCADE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX day_templates_created_by_idx ON day_templates (created_by);

-- +goose Down
DROP TABLE day_templates;
