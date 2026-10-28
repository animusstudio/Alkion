-- +goose Up
-- Every account owns a committed writer-gate row before its first write.
-- LockAccountWriter used to create the row lazily inside the first upload's
-- transaction. Until that upload committed, Freeze and any later upload
-- waited on the uncommitted unique-index insert instead of queueing on the
-- row lock, so a later upload could commit after Freeze was requested
-- (H4T10-3). With the row committed at account creation, upload and Freeze
-- always claim the same existing row FOR UPDATE: a later upload queues
-- behind Freeze, observes FROZEN and changes no rows. LockAccountWriter's
-- insert stays as a no-op fallback.
INSERT INTO account_writer_authority (account_id, instance_id)
  SELECT u.id, i.instance_id FROM users u CROSS JOIN legacy_server_instance i WHERE i.singleton
  ON CONFLICT (account_id) DO NOTHING;

-- +goose StatementBegin
CREATE FUNCTION create_account_writer_gate() RETURNS trigger LANGUAGE plpgsql
SET search_path FROM CURRENT AS $$
BEGIN
 INSERT INTO account_writer_authority (account_id, instance_id)
  SELECT NEW.id, instance_id FROM legacy_server_instance WHERE singleton
  ON CONFLICT (account_id) DO NOTHING;
 RETURN NEW;
END;
$$;
-- +goose StatementEnd
CREATE TRIGGER account_writer_gate_on_user AFTER INSERT ON users
 FOR EACH ROW EXECUTE FUNCTION create_account_writer_gate();

-- +goose Down
-- Writer authority is forward-only: removing the pre-created gate rows would
-- reopen the first-upload freeze race.
-- +goose StatementBegin
DO $$ BEGIN RAISE EXCEPTION 'account writer gate rows cannot be rolled back'; END $$;
-- +goose StatementEnd
