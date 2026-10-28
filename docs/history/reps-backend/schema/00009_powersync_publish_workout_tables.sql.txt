-- +goose Up
-- Add the workout tables to the "powersync" publication so their row changes
-- enter the logical-replication stream. Publication name is fixed as "powersync"
-- (00004). refresh_tokens stays EXCLUDED — token hashes must never replicate.
ALTER PUBLICATION powersync ADD TABLE sessions;
ALTER PUBLICATION powersync ADD TABLE sets;
ALTER PUBLICATION powersync ADD TABLE bodyweight_logs;

-- +goose Down
ALTER PUBLICATION powersync DROP TABLE bodyweight_logs;
ALTER PUBLICATION powersync DROP TABLE sets;
ALTER PUBLICATION powersync DROP TABLE sessions;
