-- +goose Up
-- Wall-clock workout length, written by the client at Finish (elapsed/60).
ALTER TABLE sessions ADD COLUMN duration_min INTEGER;

-- +goose Down
ALTER TABLE sessions DROP COLUMN duration_min;
