-- +goose Up
-- recomputePR/recomputeTopSet filter sets by (user_id, exercise_id) on every
-- set write; the existing single-column indexes don't cover that pair.
CREATE INDEX IF NOT EXISTS sets_user_exercise_idx ON sets (user_id, exercise_id);

-- +goose Down
DROP INDEX IF EXISTS sets_user_exercise_idx;
