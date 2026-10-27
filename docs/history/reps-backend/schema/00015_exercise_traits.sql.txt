-- +goose Up
-- Exercise identity traits + default prescription (design "data model" section).
-- compound drives rest duration + warm-up suggestion; plate_step_kg drives the
-- weight stepper increment; base_weight_kg seeds the first session; default_*
-- pre-fill a new day-template slot (resolveSlot fallback). All nullable except
-- the two with sensible defaults so existing rows stay valid.
ALTER TABLE exercises
    ADD COLUMN equip               TEXT,
    ADD COLUMN compound            BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN base_weight_kg      NUMERIC(6,2),
    ADD COLUMN plate_step_kg       NUMERIC(5,2) NOT NULL DEFAULT 2.5,
    ADD COLUMN default_rep_low     INTEGER,
    ADD COLUMN default_rep_high    INTEGER,
    ADD COLUMN default_warmup_sets INTEGER,
    ADD COLUMN default_working_sets INTEGER,
    ADD COLUMN default_rir_low     INTEGER,
    ADD COLUMN default_rir_high    INTEGER;

-- +goose Down
ALTER TABLE exercises
    DROP COLUMN equip,
    DROP COLUMN compound,
    DROP COLUMN base_weight_kg,
    DROP COLUMN plate_step_kg,
    DROP COLUMN default_rep_low,
    DROP COLUMN default_rep_high,
    DROP COLUMN default_warmup_sets,
    DROP COLUMN default_working_sets,
    DROP COLUMN default_rir_low,
    DROP COLUMN default_rir_high;
