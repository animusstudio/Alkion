-- +goose Up
-- focus = labeled training emphasis (e.g. "Push"); scheduled_weekday = 0..6
-- (Mon..Sun) for the week strip / day chip. Both nullable (custom days may omit).
ALTER TABLE day_templates
    ADD COLUMN focus            TEXT,
    ADD COLUMN scheduled_weekday SMALLINT;

-- +goose Down
ALTER TABLE day_templates
    DROP COLUMN focus,
    DROP COLUMN scheduled_weekday;
