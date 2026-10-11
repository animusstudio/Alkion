package migration

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"math"

	"github.com/jackc/pgx/v5"
)

type ownerConsent struct {
	account  string
	explicit bool
}
type consentKey struct{}

// OwnerConsentContext is called only after the old server verifies its own JWT.
// Portable captures, Hub grants and uploaded peer receipts cannot establish it.
func OwnerConsentContext(ctx context.Context, verifiedAccount string, explicit bool) context.Context {
	return context.WithValue(ctx, consentKey{}, ownerConsent{verifiedAccount, explicit})
}

type Service struct {
	store *Store
	peer  PeerReader
	scope ScopeBinding
}

func NewService(store *Store, peer PeerReader, scope ScopeBinding) *Service {
	return &Service{store, peer, scope}
}
func (s *Service) authorize(ctx context.Context, c TransitionCommand) (string, error) {
	owner, ok := ctx.Value(consentKey{}).(ownerConsent)
	if !ok || !owner.explicit || owner.account != c.Key.Scope.OldAccountID || c.Key.Scope != s.scope || ValidateKey(c.Key) != nil || s.store == nil {
		return "", ErrConflict
	}
	return owner.account, nil
}
func (s *Service) Freeze(ctx context.Context, c TransitionCommand) (Receipt, error) {
	owner, err := s.authorize(ctx, c)
	if err != nil {
		return Receipt{}, err
	}
	return s.store.freeze(ctx, c, owner)
}
func (s *Service) Surrender(ctx context.Context, c TransitionCommand) (Receipt, error) {
	return s.decide(ctx, "surrender", c)
}
func (s *Service) Unfreeze(ctx context.Context, c TransitionCommand) (Receipt, error) {
	return s.decide(ctx, "unfreeze", c)
}
func (s *Service) decide(ctx context.Context, action string, c TransitionCommand) (Receipt, error) {
	owner, err := s.authorize(ctx, c)
	if err != nil {
		return Receipt{}, err
	}
	if !ValidUUID(c.OperationID) || !ValidHash(c.Digest) || c.RequestHash != DecisionRequestHash(action, c) {
		return Receipt{}, ErrConflict
	}
	// A retry reads immutable local evidence without depending on peer uptime.
	if receipt, found, err := s.store.decision(ctx, action, c); err != nil || found {
		return receipt, err
	}
	if s.peer == nil {
		return Receipt{}, ErrConflict
	}
	// The remote fetch precedes any local lock. Recheck all local eligibility below.
	peer, err := s.peer.Status(ctx, c.Key)
	if err != nil {
		return Receipt{}, err
	}
	expected := "READY"
	if action == "unfreeze" {
		expected = "ABORTED"
	}
	if ValidateReceipt(peer) != nil || peer.Key != c.Key || peer.Digest != c.Digest || peer.State != expected {
		return Receipt{}, ErrConflict
	}
	tx, err := s.store.pool.Begin(ctx)
	if err != nil {
		return Receipt{}, err
	}
	defer tx.Rollback(ctx)
	gate, err := LockAccountWriter(ctx, tx, owner)
	if err != nil {
		return Receipt{}, err
	}
	if receipt, found, err := readDecision(ctx, tx, action, c); err != nil || found {
		if err != nil {
			return Receipt{}, err
		}
		if err = tx.Commit(ctx); err != nil {
			return Receipt{}, err
		}
		return receipt, nil
	}
	if gate.State != Frozen || gate.TransitionID != c.Key.TransitionID || gate.Epoch != c.Key.Epoch || gate.OldInstanceID != c.Key.Scope.OldInstanceID {
		return Receipt{}, ErrConflict
	}
	var frozenBytes, snapshot []byte
	if err = tx.QueryRow(ctx, `SELECT receipt,snapshot FROM account_writer_freeze_receipts WHERE account_id=$1::uuid AND transition_id=$2::uuid`, owner, c.Key.TransitionID).Scan(&frozenBytes, &snapshot); err != nil {
		return Receipt{}, err
	}
	var frozen Receipt
	if json.Unmarshal(frozenBytes, &frozen) != nil || frozen.Key != c.Key {
		return Receipt{}, ErrConflict
	}
	snapshotSum := sha256.Sum256(snapshot)
	snapshotDigest := hex.EncodeToString(snapshotSum[:])
	if frozen.Digest != snapshotDigest || peer.ServerSnapshotDigest != snapshotDigest {
		return Receipt{}, ErrConflict
	}
	var sequence uint64
	if err = tx.QueryRow(ctx, `SELECT decision_sequence FROM account_writer_authority WHERE account_id=$1::uuid`, owner).Scan(&sequence); err != nil {
		return Receipt{}, err
	}
	if sequence >= math.MaxInt64 || c.Key.Epoch >= math.MaxInt64 {
		return Receipt{}, ErrConflict
	}
	receipt := Receipt{Key: c.Key, State: Retired, Digest: c.Digest, ServerSnapshotDigest: snapshotDigest, OperationID: c.OperationID, RequestHash: c.RequestHash, DecisionSequence: sequence + 1}
	if action == "unfreeze" {
		receipt.State = OldActive
		receipt.Key.Epoch++
	}
	if err = recordConsent(ctx, tx, owner, action, c); err != nil {
		return Receipt{}, err
	}
	rb, _ := json.Marshal(receipt)
	pb, _ := json.Marshal(peer)
	if _, err = tx.Exec(ctx, `INSERT INTO account_migration_peer_decisions(account_id,instance_id,transition_id,operation_id,action,request_hash,receipt,peer_receipt) VALUES($1::uuid,$2::uuid,$3::uuid,$4::uuid,$5,$6,$7::jsonb,$8::jsonb)`, owner, c.Key.Scope.OldInstanceID, c.Key.TransitionID, c.OperationID, action, c.RequestHash, rb, pb); err != nil {
		return Receipt{}, err
	}
	if action == "surrender" {
		_, err = tx.Exec(ctx, `UPDATE account_writer_authority SET state='RETIRED',decision_sequence=$2,updated_at=now() WHERE account_id=$1::uuid`, owner, receipt.DecisionSequence)
	} else {
		_, err = tx.Exec(ctx, `UPDATE account_writer_authority SET state='OLD_ACTIVE',epoch=$2,transition_id=NULL,hub_instance_id=NULL,hub_space_id=NULL,hub_source_id=NULL,decision_sequence=$3,updated_at=now() WHERE account_id=$1::uuid`, owner, receipt.Key.Epoch, receipt.DecisionSequence)
	}
	if err != nil {
		return Receipt{}, err
	}
	if err = tx.Commit(ctx); err != nil {
		return Receipt{}, err
	}
	return receipt, nil
}

type querier interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}

func readDecision(ctx context.Context, q querier, action string, c TransitionCommand) (Receipt, bool, error) {
	var rb, pb []byte
	var recordedAction string
	err := q.QueryRow(ctx, `SELECT action,receipt,peer_receipt FROM account_migration_peer_decisions WHERE account_id=$1::uuid AND transition_id=$2::uuid`, c.Key.Scope.OldAccountID, c.Key.TransitionID).Scan(&recordedAction, &rb, &pb)
	if err == pgx.ErrNoRows {
		return Receipt{}, false, nil
	}
	if err != nil {
		return Receipt{}, false, err
	}
	var r, p Receipt
	if json.Unmarshal(rb, &r) != nil || json.Unmarshal(pb, &p) != nil || ValidateReceipt(r) != nil || ValidateReceipt(p) != nil {
		return Receipt{}, true, ErrConflict
	}
	expectedKey := c.Key
	if action == "unfreeze" {
		expectedKey.Epoch++
	}
	expectedState, expectedPeer := Retired, "READY"
	if action == "unfreeze" {
		expectedState, expectedPeer = OldActive, "ABORTED"
	}
	if r.State != expectedState || p.State != expectedPeer || r.ServerSnapshotDigest != p.ServerSnapshotDigest || recordedAction != action || r.Key != expectedKey || p.Key != c.Key || r.Digest != c.Digest || r.OperationID != c.OperationID || r.RequestHash != c.RequestHash {
		return Receipt{}, true, ErrConflict
	}
	return r, true, nil
}
func (s *Store) decision(ctx context.Context, action string, c TransitionCommand) (Receipt, bool, error) {
	return readDecision(ctx, s.pool, action, c)
}
func recordConsent(ctx context.Context, tx pgx.Tx, owner, action string, c TransitionCommand) error {
	if owner != c.Key.Scope.OldAccountID {
		return ErrConflict
	}
	var storedAction, hash, account, transition string
	_, err := tx.Exec(ctx, `INSERT INTO account_migration_owner_consents(account_id,instance_id,transition_id,operation_id,action,request_hash,consent_version,verified_subject) VALUES($1::uuid,$2::uuid,$3::uuid,$4::uuid,$5,$6,'independent-old-owner-v1',$1::uuid) ON CONFLICT(operation_id) DO NOTHING`, owner, c.Key.Scope.OldInstanceID, c.Key.TransitionID, c.OperationID, action, c.RequestHash)
	if err != nil {
		return err
	}
	err = tx.QueryRow(ctx, `SELECT action,request_hash,account_id::text,transition_id::text FROM account_migration_owner_consents WHERE operation_id=$1::uuid`, c.OperationID).Scan(&storedAction, &hash, &account, &transition)
	if err != nil {
		return err
	}
	if storedAction != action || hash != c.RequestHash || account != owner || transition != c.Key.TransitionID {
		return ErrConflict
	}
	return nil
}

// Status serves immutable decisions. OLD_ACTIVE recovery proof additionally
// requires the current gate to remain at that exact advanced epoch/sequence.
// Cached owner controls still return immutable historical results.
func (s *Store) Status(ctx context.Context, k TransitionKey) (Receipt, error) {
	if ValidateKey(k) != nil {
		return Receipt{}, ErrConflict
	}
	var rb, snapshot []byte
	err := s.pool.QueryRow(ctx, `SELECT receipt FROM account_migration_peer_decisions WHERE account_id=$1::uuid AND transition_id=$2::uuid`, k.Scope.OldAccountID, k.TransitionID).Scan(&rb)
	frozen := err == pgx.ErrNoRows
	if frozen {
		err = s.pool.QueryRow(ctx, `SELECT receipt,snapshot FROM account_writer_freeze_receipts WHERE account_id=$1::uuid AND transition_id=$2::uuid`, k.Scope.OldAccountID, k.TransitionID).Scan(&rb, &snapshot)
	}
	if err != nil {
		return Receipt{}, err
	}
	var r Receipt
	if json.Unmarshal(rb, &r) != nil {
		return Receipt{}, ErrConflict
	}
	if frozen {
		sum := sha256.Sum256(snapshot)
		r.ServerSnapshotDigest = hex.EncodeToString(sum[:])
		if r.Digest != r.ServerSnapshotDigest {
			return Receipt{}, ErrConflict
		}
	}
	if ValidateReceipt(r) != nil || r.Key != k {
		return Receipt{}, ErrConflict
	}
	if r.State == OldActive {
		var current bool
		err = s.pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM account_writer_authority WHERE account_id=$1::uuid AND instance_id=$2::uuid AND state='OLD_ACTIVE' AND epoch=$3 AND decision_sequence=$4 AND transition_id IS NULL AND hub_instance_id IS NULL AND hub_space_id IS NULL AND hub_source_id IS NULL)`, k.Scope.OldAccountID, k.Scope.OldInstanceID, k.Epoch, r.DecisionSequence).Scan(&current)
		if err != nil {
			return Receipt{}, err
		}
		if !current {
			return Receipt{}, ErrConflict
		}
	}
	return r, nil
}
