-- +goose Up
-- A bodyweight entry on a date. weight_kg is NUMERIC for exact decimal weights.
CREATE TABLE bodyweight_logs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    date            DATE NOT NULL,
    weight_kg       NUMERIC(5, 2) NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX bodyweight_logs_user_date_idx ON bodyweight_logs (user_id, date DESC);

-- +goose Down
DROP TABLE bodyweight_logs;
