-- +goose Up
ALTER TABLE exercises ADD COLUMN default_rest_seconds INTEGER;

-- +goose Down
ALTER TABLE exercises DROP COLUMN default_rest_seconds;
