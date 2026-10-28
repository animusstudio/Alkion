-- +goose Up
-- One planned exercise within a day template, with its target prescription.
-- is_template/created_by are DENORMALIZED from the parent day_templates row and
-- stamped server-side on write: PowerSync classic sync rules cannot JOIN, so the
-- per-user / templates buckets filter items directly on these columns. Target
-- columns are nullable (a custom day may omit them).
CREATE TABLE day_template_items (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    day_template_id     UUID NOT NULL REFERENCES day_templates(id) ON DELETE CASCADE,
    exercise_id         UUID NOT NULL REFERENCES exercises(id),
    position            INTEGER NOT NULL,
    target_warmup_sets  INTEGER,
    target_working_sets INTEGER,
    target_rep_low      INTEGER,
    target_rep_high     INTEGER,
    target_rir_low      INTEGER,
    target_rir_high     INTEGER,
    is_template         BOOLEAN NOT NULL DEFAULT FALSE,
    created_by          UUID REFERENCES users(id) ON DELETE CASCADE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX day_template_items_template_idx ON day_template_items (day_template_id, position);
CREATE INDEX day_template_items_created_by_idx ON day_template_items (created_by);

-- +goose Down
DROP TABLE day_template_items;
