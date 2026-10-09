-- +goose Up
-- Durable instance identity is generated once, never from a client request.
CREATE TABLE legacy_server_instance (
 singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
 instance_id uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
 created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO legacy_server_instance (singleton) VALUES (true);

CREATE TABLE account_writer_authority (
 account_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
 instance_id uuid NOT NULL REFERENCES legacy_server_instance(instance_id),
 state text NOT NULL DEFAULT 'OLD_ACTIVE' CHECK (state IN ('OLD_ACTIVE','FROZEN','RETIRED')),
 epoch bigint NOT NULL DEFAULT 0 CHECK (epoch >= 0),
 transition_id uuid,
 hub_instance_id uuid,
 hub_space_id uuid,
 hub_source_id uuid,
 decision_sequence bigint NOT NULL DEFAULT 0 CHECK (decision_sequence >= 0),
 updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE (instance_id, account_id),
 CHECK ((state = 'OLD_ACTIVE' AND transition_id IS NULL AND hub_instance_id IS NULL AND hub_space_id IS NULL AND hub_source_id IS NULL)
     OR (state <> 'OLD_ACTIVE' AND transition_id IS NOT NULL AND hub_instance_id IS NOT NULL AND hub_space_id IS NOT NULL AND hub_source_id IS NOT NULL))
);

-- Immutable decisions survive later gate transitions. Never publish controls or
-- snapshots to PowerSync (the old replication role has no access to these).
CREATE TABLE account_writer_freeze_receipts (
 account_id uuid NOT NULL,
 instance_id uuid NOT NULL,
 transition_id uuid NOT NULL UNIQUE,
 epoch bigint NOT NULL CHECK (epoch > 0),
 operation_id uuid NOT NULL UNIQUE,
 request_hash text NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
 receipt jsonb NOT NULL,
 snapshot bytea NOT NULL,
 decided_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY (account_id, transition_id),
 FOREIGN KEY (instance_id,account_id) REFERENCES account_writer_authority(instance_id,account_id) ON DELETE RESTRICT
);
REVOKE ALL ON legacy_server_instance, account_writer_authority, account_writer_freeze_receipts FROM powersync_role;

-- +goose StatementBegin
CREATE FUNCTION protect_account_writer_freeze_receipt() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 RAISE EXCEPTION 'account freeze receipts are immutable';
END;
$$;
-- +goose StatementEnd
CREATE TRIGGER account_writer_freeze_receipt_immutable BEFORE UPDATE OR DELETE ON account_writer_freeze_receipts
 FOR EACH ROW EXECUTE FUNCTION protect_account_writer_freeze_receipt();

-- +goose Down
-- Writer authority is forward-only: rolling this fence away can reopen retired
-- accounts. Restore/rollback needs a separately reviewed closed-writer procedure.
-- +goose StatementBegin
DO $$ BEGIN RAISE EXCEPTION 'account writer authority cannot be rolled back'; END $$;
-- +goose StatementEnd
