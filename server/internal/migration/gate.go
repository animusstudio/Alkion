package migration

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
)

// LockAccountWriter initializes under the unique account key BEFORE locking.
// Never synthesize an active gate after a missing table/instance or SQL failure.
func LockAccountWriter(ctx context.Context, tx pgx.Tx, accountID string) (Gate, error) {
	var gate Gate
	if _, err := tx.Exec(ctx, `INSERT INTO account_writer_authority (account_id,instance_id)
  SELECT $1::uuid,instance_id FROM legacy_server_instance WHERE singleton
  ON CONFLICT (account_id) DO NOTHING`, accountID); err != nil {
		return gate, fmt.Errorf("initialize account writer: %w", err)
	}
	err := tx.QueryRow(ctx, `SELECT a.account_id::text,a.instance_id::text,a.state,a.epoch,COALESCE(a.transition_id::text,'')
  FROM account_writer_authority a JOIN legacy_server_instance i ON i.instance_id=a.instance_id AND i.singleton
  WHERE a.account_id=$1::uuid FOR UPDATE OF a`, accountID).Scan(&gate.OldAccountID, &gate.OldInstanceID, &gate.State, &gate.Epoch, &gate.TransitionID)
	if err != nil {
		return Gate{}, fmt.Errorf("lock account writer: %w", err)
	}
	return gate, nil
}

// Store has no network-facing entry point. Its caller must establish trusted
// control/consent before using Freeze; implementing that protocol is separate.
type Store struct{ pool *pgxpool.Pool }

func NewStore(pool *pgxpool.Pool) *Store { return &Store{pool: pool} }

// Freeze serializes with every admitted upload and commits its snapshot and
// immutable receipt with the gate change. All errors roll back the whole change.
func (s *Store) Freeze(ctx context.Context, command TransitionCommand) (Receipt, error) {
	if err := validateFreeze(command); err != nil {
		return Receipt{}, err
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Receipt{}, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	gate, err := LockAccountWriter(ctx, tx, command.Key.Scope.OldAccountID)
	if err != nil {
		return Receipt{}, err
	}
	if gate.OldInstanceID != command.Key.Scope.OldInstanceID {
		return Receipt{}, ErrConflict
	}
	// Exact retry returns the recorded decision even after later state changes.
	var receiptBytes []byte
	err = tx.QueryRow(ctx, `SELECT receipt FROM account_writer_freeze_receipts WHERE account_id=$1::uuid AND transition_id=$2::uuid`, gate.OldAccountID, command.Key.TransitionID).Scan(&receiptBytes)
	if err == nil {
		var receipt Receipt
		if err := json.Unmarshal(receiptBytes, &receipt); err != nil {
			return Receipt{}, err
		}
		if receipt.Key != command.Key || receipt.OperationID != command.OperationID || receipt.RequestHash != command.RequestHash {
			return Receipt{}, ErrConflict
		}
		if err := tx.Commit(ctx); err != nil {
			return Receipt{}, err
		}
		return receipt, nil
	}
	if err != pgx.ErrNoRows {
		return Receipt{}, err
	}
	if gate.State != OldActive || command.Key.Epoch != gate.Epoch+1 {
		return Receipt{}, ErrConflict
	}
	snapshot, err := snapshotAccount(ctx, tx, gate)
	if err != nil {
		return Receipt{}, err
	}
	sum := sha256.Sum256(snapshot)
	var sequence uint64
	err = tx.QueryRow(ctx, `UPDATE account_writer_authority SET state='FROZEN',epoch=$2,transition_id=$3::uuid,
  hub_instance_id=$4::uuid,hub_space_id=$5::uuid,hub_source_id=$6::uuid,
  decision_sequence=decision_sequence+1,updated_at=now() WHERE account_id=$1::uuid RETURNING decision_sequence`,
		gate.OldAccountID, command.Key.Epoch, command.Key.TransitionID, command.Key.Scope.HubInstanceID, command.Key.Scope.HubSpaceID, command.Key.Scope.HubSourceID).Scan(&sequence)
	if err != nil {
		return Receipt{}, err
	}
	receipt := Receipt{Key: command.Key, State: Frozen, Digest: hex.EncodeToString(sum[:]), OperationID: command.OperationID, RequestHash: command.RequestHash, DecisionSequence: sequence}
	receiptBytes, err = json.Marshal(receipt)
	if err != nil {
		return Receipt{}, err
	}
	_, err = tx.Exec(ctx, `INSERT INTO account_writer_freeze_receipts (account_id,instance_id,transition_id,epoch,operation_id,request_hash,receipt,snapshot)
  VALUES ($1::uuid,$2::uuid,$3::uuid,$4,$5::uuid,$6,$7::jsonb,$8)`,
		gate.OldAccountID, gate.OldInstanceID, command.Key.TransitionID, command.Key.Epoch, command.OperationID, command.RequestHash, receiptBytes, snapshot)
	if err != nil {
		return Receipt{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Receipt{}, err
	}
	return receipt, nil
}

func validateFreeze(command TransitionCommand) error {
	scope := command.Key.Scope
	for _, id := range []string{scope.OldAccountID, scope.OldInstanceID, scope.HubInstanceID, scope.HubSpaceID, scope.HubSourceID, command.Key.TransitionID, command.OperationID} {
		var parsed pgtype.UUID
		if err := parsed.Scan(id); err != nil || !parsed.Valid || parsed.Bytes == ([16]byte{}) {
			return fmt.Errorf("invalid freeze identity")
		}
		// Require canonical lower-case UUID wire identity, no spelling aliases.
		value, _ := parsed.Value()
		if value != id {
			return fmt.Errorf("noncanonical freeze identity")
		}
	}
	if command.Key.Epoch == 0 || command.Key.Epoch > math.MaxInt64 || command.Digest != "" || command.RequestHash != FreezeRequestHash(command) {
		return fmt.Errorf("invalid freeze command")
	}
	return nil
}

// Snapshot v1 includes all seven families in fixed order with rows ordered by
// UUID, retaining computed columns and the shared templates visible to accounts.
// It is evidence only: deployed maintenance/template writers must be quiesced
// before this local transaction can establish global migration readiness.
func snapshotAccount(ctx context.Context, tx pgx.Tx, gate Gate) ([]byte, error) {
	// PostgreSQL timestamp JSON depends on session timezone. Pin it for the
	// versioned snapshot encoding so independent readers reproduce the digest.
	if _, err := tx.Exec(ctx, `SET LOCAL TIME ZONE 'UTC'`); err != nil {
		return nil, err
	}
	type family struct {
		Name string          `json:"name"`
		Rows json.RawMessage `json:"rows"`
	}
	snapshot := struct {
		Version       string   `json:"version"`
		OldInstanceID string   `json:"old_instance_id"`
		OldAccountID  string   `json:"old_account_id"`
		Families      []family `json:"families"`
	}{Version: "reps-account-snapshot-v1", OldInstanceID: gate.OldInstanceID, OldAccountID: gate.OldAccountID}
	for _, source := range []struct{ table, where string }{
		{"bodyweight_logs", "user_id=$1::uuid"},
		{"day_template_items", "created_by=$1::uuid OR is_template"},
		{"day_templates", "created_by=$1::uuid OR is_template"},
		{"exercises", "created_by=$1::uuid OR is_template"},
		{"muscle_targets", "user_id=$1::uuid"},
		{"sessions", "user_id=$1::uuid"},
		{"sets", "user_id=$1::uuid"},
	} {
		var rows []byte
		if err := tx.QueryRow(ctx, "SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) FROM "+source.table+" r WHERE "+source.where, gate.OldAccountID).Scan(&rows); err != nil {
			return nil, err
		}
		snapshot.Families = append(snapshot.Families, family{Name: source.table, Rows: rows})
	}
	return json.Marshal(snapshot)
}
