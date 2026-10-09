-- +goose Up
CREATE TABLE account_migration_owner_consents (
 account_id uuid NOT NULL,
 instance_id uuid NOT NULL,
 transition_id uuid NOT NULL,
 operation_id uuid PRIMARY KEY,
 action text NOT NULL CHECK (action IN ('freeze','surrender','unfreeze')),
 request_hash text NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
 consent_version text NOT NULL CHECK (consent_version='independent-old-owner-v1'),
 verified_subject uuid NOT NULL CHECK (verified_subject=account_id),
 recorded_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY(instance_id,account_id) REFERENCES account_writer_authority(instance_id,account_id)
);
CREATE TABLE account_migration_peer_decisions (
 account_id uuid NOT NULL,
 instance_id uuid NOT NULL,
 transition_id uuid NOT NULL UNIQUE,
 operation_id uuid NOT NULL UNIQUE REFERENCES account_migration_owner_consents(operation_id),
 action text NOT NULL CHECK (action IN ('surrender','unfreeze')),
 request_hash text NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
 receipt jsonb NOT NULL,
 peer_receipt jsonb NOT NULL,
 decided_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(account_id,transition_id),
 FOREIGN KEY(instance_id,account_id) REFERENCES account_writer_authority(instance_id,account_id)
);
CREATE TRIGGER account_migration_owner_consent_immutable BEFORE UPDATE OR DELETE ON account_migration_owner_consents
 FOR EACH ROW EXECUTE FUNCTION protect_account_writer_freeze_receipt();
CREATE TRIGGER account_migration_peer_decision_immutable BEFORE UPDATE OR DELETE ON account_migration_peer_decisions
 FOR EACH ROW EXECUTE FUNCTION protect_account_writer_freeze_receipt();
REVOKE ALL ON account_migration_owner_consents,account_migration_peer_decisions FROM powersync_role;
-- +goose StatementBegin
CREATE FUNCTION enforce_monotonic_account_writer() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.account_id<>OLD.account_id OR NEW.instance_id<>OLD.instance_id OR NEW.epoch<OLD.epoch OR NEW.decision_sequence<OLD.decision_sequence THEN
  RAISE EXCEPTION 'account writer identity and epoch are monotonic';
 END IF;
 IF OLD.state='RETIRED' AND (NEW.state<>OLD.state OR NEW.epoch<>OLD.epoch OR NEW.transition_id IS DISTINCT FROM OLD.transition_id OR NEW.hub_instance_id IS DISTINCT FROM OLD.hub_instance_id OR NEW.hub_space_id IS DISTINCT FROM OLD.hub_space_id OR NEW.hub_source_id IS DISTINCT FROM OLD.hub_source_id) THEN
  RAISE EXCEPTION 'retired account cannot reopen';
 END IF;
 IF OLD.state='FROZEN' AND NEW.state='OLD_ACTIVE' AND NOT EXISTS (
  SELECT 1 FROM account_migration_peer_decisions WHERE account_id=OLD.account_id AND transition_id=OLD.transition_id AND action='unfreeze'
  AND (receipt->'key'->>'epoch')::bigint=NEW.epoch AND NEW.epoch>OLD.epoch
 ) THEN RAISE EXCEPTION 'authenticated abort decision required'; END IF;
 IF OLD.state='OLD_ACTIVE' AND NEW.state='FROZEN' AND EXISTS (
  SELECT 1 FROM account_writer_freeze_receipts WHERE transition_id=NEW.transition_id
 ) THEN RAISE EXCEPTION 'transition cannot be reused'; END IF;
 RETURN NEW;
END;
$$;
-- +goose StatementEnd
CREATE TRIGGER account_writer_monotonic BEFORE UPDATE ON account_writer_authority
 FOR EACH ROW EXECUTE FUNCTION enforce_monotonic_account_writer();
-- +goose Down
-- +goose StatementBegin
DO $$ BEGIN RAISE EXCEPTION 'peer migration decisions cannot be rolled back'; END $$;
-- +goose StatementEnd
