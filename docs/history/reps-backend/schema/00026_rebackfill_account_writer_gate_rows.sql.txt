-- +goose Up
-- Re-run 00025's gate-row backfill now that its AFTER INSERT trigger exists.
-- 00025 backfills before it creates create_account_writer_gate, so an account
-- committed between that backfill's snapshot and the trigger's creation got
-- neither the backfilled row nor the eager trigger row, and stayed on
-- LockAccountWriter's lazy insert (the first-upload freeze race H4T10-3
-- closes). CREATE TRIGGER waits for every in-flight insert into users, so
-- once 00025 has committed every such account is committed too, and every
-- later account gets its row from the trigger. This statement, which runs
-- after 00025 has committed, therefore leaves no account without a committed
-- gate row. It is idempotent: existing rows are never changed.
INSERT INTO account_writer_authority (account_id, instance_id)
  SELECT u.id, i.instance_id FROM users u CROSS JOIN legacy_server_instance i WHERE i.singleton
  ON CONFLICT (account_id) DO NOTHING;

-- +goose Down
-- Writer authority is forward-only, like 00023-00025: removing gate rows
-- would reopen the first-upload freeze race.
-- +goose StatementBegin
DO $$ BEGIN RAISE EXCEPTION 'account writer gate rows cannot be rolled back'; END $$;
-- +goose StatementEnd
