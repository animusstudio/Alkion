package migration

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"testing"
)

type testPeer struct {
	mu      sync.Mutex
	receipt Receipt
	fail    bool
	before  func()
}

func (p *testPeer) Status(ctx context.Context, k TransitionKey) (Receipt, error) {
	p.mu.Lock()
	r, fail, f := p.receipt, p.fail, p.before
	p.mu.Unlock()
	if f != nil {
		f()
	}
	if fail {
		return Receipt{}, ErrConflict
	}
	return r, nil
}
func decisionCommand(f TransitionCommand, digest, action string) TransitionCommand {
	f.Digest = digest
	sum := sha256.Sum256([]byte(f.OperationID + action))
	f.OperationID = fmt.Sprintf("%08x-%04x-%04x-%04x-%012x", sum[:4], sum[4:6], sum[6:8], sum[8:10], sum[10:16])
	f.RequestHash = DecisionRequestHash(action, f)
	return f
}
func TestOldSurrenderAbortRace(t *testing.T) {
	for _, winner := range []string{"surrender", "unfreeze"} {
		t.Run(winner, func(t *testing.T) {
			pool, user, freeze := testAccount(t)
			ctx := OwnerConsentContext(context.Background(), user, true)
			store := NewStore(pool)
			f, err := store.Freeze(ctx, freeze)
			if err != nil {
				t.Fatal(err)
			}
			peer := &testPeer{receipt: Receipt{Key: freeze.Key, State: "READY", Digest: f.Digest, ServerSnapshotDigest: f.Digest, OperationID: "00000000-0000-4000-8000-000000000080", RequestHash: strings.Repeat("a", 64), DecisionSequence: 2}}
			svc := NewService(store, peer, freeze.Key.Scope)
			surrender := decisionCommand(freeze, f.Digest, "surrender")
			abort := decisionCommand(freeze, f.Digest, "unfreeze")
			var got Receipt
			if winner == "surrender" {
				got, err = svc.Surrender(ctx, surrender)
			} else {
				peer.receipt.State = "ABORTED"
				got, err = svc.Unfreeze(ctx, abort)
			}
			if err != nil {
				t.Fatal(err)
			}
			peer.fail = true // Exact durable retry does not depend on peer availability.
			var again Receipt
			if winner == "surrender" {
				again, err = svc.Surrender(ctx, surrender)
			} else {
				again, err = svc.Unfreeze(ctx, abort)
			}
			if err != nil || again != got {
				t.Fatalf("retry differs: %+v %v", again, err)
			}
			changed := surrender
			if winner == "unfreeze" {
				changed = abort
			}
			changed.OperationID = "00000000-0000-4000-8000-000000000099"
			changed.RequestHash = DecisionRequestHash(winner, changed)
			if winner == "surrender" {
				_, err = svc.Surrender(ctx, changed)
			} else {
				_, err = svc.Unfreeze(ctx, changed)
			}
			if err == nil {
				t.Fatal("changed operation accepted")
			}
			peer.fail = false
			peer.receipt.State = "ABORTED"
			if winner == "surrender" {
				if _, err = svc.Unfreeze(ctx, abort); err == nil {
					t.Fatal("retired reopened")
				}
			} else {
				peer.receipt.State = "READY"
				if _, err = svc.Surrender(ctx, surrender); err == nil {
					t.Fatal("abort tombstone reused")
				}
				freeze.Key.Epoch = got.Key.Epoch + 1
				freeze.OperationID = "00000000-0000-4000-8000-000000000092"
				freeze.RequestHash = FreezeRequestHash(freeze)
				if _, err = store.Freeze(ctx, freeze); err == nil {
					t.Fatal("aborted transition reused")
				}
			}
			recovered := NewService(NewStore(pool), peer, freeze.Key.Scope)
			if winner == "surrender" {
				peer.fail = true
				if _, err = recovered.Unfreeze(ctx, abort); err == nil {
					t.Fatal("crash/timeout reopen")
				}
			}
		})
	}
}
func TestPeerDecisionRevalidatesAfterFetch(t *testing.T) {
	pool, user, freeze := testAccount(t)
	store := NewStore(pool)
	f, err := store.Freeze(context.Background(), freeze)
	if err != nil {
		t.Fatal(err)
	}
	ctx := OwnerConsentContext(context.Background(), user, true)
	peer := &testPeer{receipt: Receipt{Key: freeze.Key, State: "READY", Digest: f.Digest, ServerSnapshotDigest: f.Digest, OperationID: "00000000-0000-4000-8000-000000000080", RequestHash: strings.Repeat("a", 64), DecisionSequence: 2}}
	svc := NewService(store, peer, freeze.Key.Scope)
	surrender := decisionCommand(freeze, f.Digest, "surrender")
	abort := decisionCommand(freeze, f.Digest, "unfreeze")
	peer.before = func() {
		other := &testPeer{receipt: peer.receipt}
		other.receipt.State = "ABORTED"
		if _, err := NewService(store, other, freeze.Key.Scope).Unfreeze(ctx, abort); err != nil {
			t.Fatal(err)
		}
	}
	if _, err = svc.Surrender(ctx, surrender); err == nil {
		t.Fatal("state changed during fetch accepted")
	}
}
func TestPeerOwnerConsentAndDigest(t *testing.T) {
	pool, user, freeze := testAccount(t)
	store := NewStore(pool)
	f, err := store.Freeze(context.Background(), freeze)
	if err != nil {
		t.Fatal(err)
	}
	peer := &testPeer{receipt: Receipt{Key: freeze.Key, State: "READY", Digest: f.Digest, ServerSnapshotDigest: f.Digest, OperationID: "00000000-0000-4000-8000-000000000080", RequestHash: strings.Repeat("a", 64), DecisionSequence: 2}}
	svc := NewService(store, peer, freeze.Key.Scope)
	c := decisionCommand(freeze, f.Digest, "surrender")
	for _, ctx := range []context.Context{context.Background(), OwnerConsentContext(context.Background(), user, false), OwnerConsentContext(context.Background(), "00000000-0000-4000-8000-000000000099", true)} {
		if _, err := svc.Surrender(ctx, c); err == nil {
			t.Fatal("missing independent old owner consent accepted")
		}
	}
	ctx := OwnerConsentContext(context.Background(), user, true)
	peer.receipt.Digest = strings.Repeat("0", 64)
	if _, err = svc.Surrender(ctx, c); err == nil {
		t.Fatal("wrong digest accepted")
	}
	peer.receipt.Digest = f.Digest
	c.RequestHash = strings.Repeat("0", 64)
	if _, err = svc.Surrender(ctx, c); err == nil {
		t.Fatal("client hash accepted")
	}
}

func TestOldSurrenderAbortConcurrent(t *testing.T) {
	pool, user, freeze := testAccount(t)
	ctx := OwnerConsentContext(context.Background(), user, true)
	store := NewStore(pool)
	f, err := store.Freeze(ctx, freeze)
	if err != nil {
		t.Fatal(err)
	}
	ready := Receipt{Key: freeze.Key, State: "READY", Digest: f.Digest, ServerSnapshotDigest: f.Digest, OperationID: freeze.OperationID, RequestHash: strings.Repeat("d", 64), DecisionSequence: 2}
	abort := ready
	abort.State = "ABORTED"
	arrived := make(chan struct{}, 2)
	release := make(chan struct{})
	before := func() { arrived <- struct{}{}; <-release }
	readyPeer := &testPeer{receipt: ready, before: before}
	abortPeer := &testPeer{receipt: abort, before: before}
	results := make(chan error, 2)
	go func() {
		_, err := NewService(store, readyPeer, freeze.Key.Scope).Surrender(ctx, decisionCommand(freeze, f.Digest, "surrender"))
		results <- err
	}()
	go func() {
		_, err := NewService(store, abortPeer, freeze.Key.Scope).Unfreeze(ctx, decisionCommand(freeze, f.Digest, "unfreeze"))
		results <- err
	}()
	<-arrived
	<-arrived
	close(release)
	success := 0
	for i := 0; i < 2; i++ {
		if <-results == nil {
			success++
		}
	}
	if success != 1 {
		t.Fatalf("competing decisions success=%d", success)
	}
	var state string
	var epoch uint64
	if err = pool.QueryRow(ctx, `SELECT state,epoch FROM account_writer_authority WHERE account_id=$1::uuid`, user).Scan(&state, &epoch); err != nil {
		t.Fatal(err)
	}
	if state != Retired && !(state == OldActive && epoch == freeze.Key.Epoch+1) {
		t.Fatalf("invalid terminal state: %s/%d", state, epoch)
	}
}

func TestPeerAuthenticatedSnapshotBinding(t *testing.T) {
	pool, user, freeze := testAccount(t)
	store := NewStore(pool)
	f, err := store.Freeze(context.Background(), freeze)
	if err != nil {
		t.Fatal(err)
	}
	ctx := OwnerConsentContext(context.Background(), user, true)
	aggregate := strings.Repeat("e", 64)
	peer := &testPeer{receipt: Receipt{Key: freeze.Key, State: "READY", Digest: aggregate, ServerSnapshotDigest: strings.Repeat("0", 64), OperationID: freeze.OperationID, RequestHash: strings.Repeat("a", 64), DecisionSequence: 2}}
	svc := NewService(store, peer, freeze.Key.Scope)
	c := decisionCommand(freeze, aggregate, "surrender")
	if _, err = svc.Surrender(ctx, c); err == nil {
		t.Fatal("authenticated READY associated with foreign frozen snapshot accepted")
	}
	peer.receipt.ServerSnapshotDigest = ""
	if _, err = svc.Surrender(ctx, c); err == nil {
		t.Fatal("missing authenticated snapshot accepted")
	}
	peer.receipt.ServerSnapshotDigest = f.Digest
	receipt, err := svc.Surrender(ctx, c)
	if err != nil || receipt.Digest != aggregate || receipt.ServerSnapshotDigest != f.Digest {
		t.Fatalf("separate authenticated aggregate/snapshot: %+v %v", receipt, err)
	}
}

func TestOldSurrenderDecisionImmutability(t *testing.T) {
	pool, user, c := testAccount(t)
	ctx := OwnerConsentContext(context.Background(), user, true)
	store := NewStore(pool)
	f, err := NewService(store, nil, c.Key.Scope).Freeze(ctx, c)
	if err != nil {
		t.Fatal(err)
	}
	peer := &testPeer{receipt: Receipt{Key: c.Key, State: "READY", Digest: strings.Repeat("e", 64), ServerSnapshotDigest: f.Digest, OperationID: c.OperationID, RequestHash: strings.Repeat("a", 64), DecisionSequence: 2}}
	svc := NewService(store, peer, c.Key.Scope)
	command := decisionCommand(c, peer.receipt.Digest, "surrender")
	receipt, err := svc.Surrender(ctx, command)
	if err != nil {
		t.Fatal(err)
	}
	for _, query := range []string{`UPDATE account_migration_peer_decisions SET request_hash=repeat('0',64) WHERE account_id=$1::uuid`, `DELETE FROM account_migration_peer_decisions WHERE account_id=$1::uuid`, `UPDATE account_migration_owner_consents SET request_hash=repeat('0',64) WHERE account_id=$1::uuid`, `DELETE FROM account_migration_owner_consents WHERE account_id=$1::uuid`, `UPDATE account_writer_authority SET epoch=0 WHERE account_id=$1::uuid`} {
		if _, err = pool.Exec(ctx, query, user); err == nil {
			t.Fatalf("immutable decision altered: %s", query)
		}
	}
	if _, err = pool.Exec(ctx, `UPDATE account_writer_authority SET updated_at=now()+interval '100 years' WHERE account_id=$1::uuid`, user); err != nil {
		t.Fatal(err)
	}
	restored := NewService(NewStore(pool), peer, c.Key.Scope)
	again, err := restored.Surrender(ctx, command)
	if err != nil || again != receipt {
		t.Fatalf("clock advance/store restart: %+v %v", again, err)
	}
	expired, cancel := context.WithCancel(ctx)
	cancel()
	if _, err = restored.Unfreeze(expired, decisionCommand(c, peer.receipt.Digest, "unfreeze")); err == nil {
		t.Fatal("timeout reopened retired account")
	}
}

func TestPeerHistoricalFreezeSnapshotWithoutRewrite(t *testing.T) {
	pool, _, c := testAccount(t)
	ctx := context.Background()
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	gate, err := LockAccountWriter(ctx, tx, c.Key.Scope.OldAccountID)
	if err != nil {
		t.Fatal(err)
	}
	snapshot, err := snapshotAccount(ctx, tx, gate)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(snapshot)
	digest := hex.EncodeToString(sum[:])
	historical := Receipt{Key: c.Key, State: Frozen, Digest: digest, OperationID: c.OperationID, RequestHash: c.RequestHash, DecisionSequence: 1}
	raw, _ := json.Marshal(historical)
	var object map[string]json.RawMessage
	if err = json.Unmarshal(raw, &object); err != nil {
		t.Fatal(err)
	}
	delete(object, "server_snapshot_digest")
	raw, _ = json.Marshal(object)
	if _, err = tx.Exec(ctx, `UPDATE account_writer_authority SET state='FROZEN',epoch=$2,transition_id=$3::uuid,hub_instance_id=$4::uuid,hub_space_id=$5::uuid,hub_source_id=$6::uuid,decision_sequence=1 WHERE account_id=$1::uuid`, gate.OldAccountID, c.Key.Epoch, c.Key.TransitionID, c.Key.Scope.HubInstanceID, c.Key.Scope.HubSpaceID, c.Key.Scope.HubSourceID); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `INSERT INTO account_writer_freeze_receipts(account_id,instance_id,transition_id,epoch,operation_id,request_hash,receipt,snapshot)VALUES($1::uuid,$2::uuid,$3::uuid,$4,$5::uuid,$6,$7::jsonb,$8)`, gate.OldAccountID, gate.OldInstanceID, c.Key.TransitionID, c.Key.Epoch, c.OperationID, c.RequestHash, raw, snapshot); err != nil {
		t.Fatal(err)
	}
	if err = tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	store := NewStore(pool)
	status, err := store.Status(ctx, c.Key)
	if err != nil || status.ServerSnapshotDigest != digest {
		t.Fatalf("historical status component: %+v %v", status, err)
	}
	retry, err := store.Freeze(ctx, c)
	if err != nil || retry != status {
		t.Fatalf("historical retry: %+v %v", retry, err)
	}
	var rewritten bool
	if err = pool.QueryRow(ctx, `SELECT receipt ? 'server_snapshot_digest' FROM account_writer_freeze_receipts WHERE account_id=$1::uuid`, gate.OldAccountID).Scan(&rewritten); err != nil || rewritten {
		t.Fatalf("immutable historical receipt rewritten=%t %v", rewritten, err)
	}
}
