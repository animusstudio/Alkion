-- +goose Up
-- Optionally record which day template a session was started from. Nullable:
-- ad-hoc sessions leave it NULL. ON DELETE SET NULL so deleting a template does
-- not delete the historical sessions that used it.
ALTER TABLE sessions ADD COLUMN day_template_id UUID REFERENCES day_templates(id) ON DELETE SET NULL;

-- +goose Down
ALTER TABLE sessions DROP COLUMN day_template_id;
