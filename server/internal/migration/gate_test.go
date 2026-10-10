package migration

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"workout-tracker/server/db/migrations"
	"workout-tracker/server/internal/db"
)

func testAccount(t *testing.T) (*pgxpool.Pool, string, TransitionCommand) {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := db.Migrate(ctx, url); err != nil {
		t.Fatal(err)
	}
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	var user, instance string
	if err := pool.QueryRow(ctx, `INSERT INTO users(email,password_hash) VALUES (gen_random_uuid()::text||'@example.invalid','synthetic') RETURNING id::text`).Scan(&user); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = pool.Exec(context.Background(), `DELETE FROM users WHERE id=$1::uuid`, user) })
	if err := pool.QueryRow(ctx, `SELECT instance_id::text FROM legacy_server_instance WHERE singleton`).Scan(&instance); err != nil {
		t.Fatal(err)
	}
	var transition, operation string
	if err := pool.QueryRow(ctx, `SELECT gen_random_uuid()::text,gen_random_uuid()::text`).Scan(&transition, &operation); err != nil {
		t.Fatal(err)
	}
	command := TransitionCommand{Key: TransitionKey{Scope: ScopeBinding{OldInstanceID: instance, OldAccountID: user, HubInstanceID: "00000000-0000-4000-8000-000000000001", HubSpaceID: "00000000-0000-4000-8000-000000000002", HubSourceID: "00000000-0000-4000-8000-000000000003"}, TransitionID: transition, Epoch: 1}, OperationID: operation}
	command.RequestHash = FreezeRequestHash(command)
	return pool, user, command
}

func TestFreezeReceiptSnapshotAndIdentity(t *testing.T) {
	pool, user, command := testAccount(t)
	ctx := context.Background()
	store := NewStore(pool)
	receipt, err := store.Freeze(ctx, command)
	if err != nil {
		t.Fatal(err)
	}
	var snapshot []byte
	if err := pool.QueryRow(ctx, `SELECT snapshot FROM account_writer_freeze_receipts WHERE account_id=$1::uuid`, user).Scan(&snapshot); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(snapshot)
	if receipt.Digest != hex.EncodeToString(sum[:]) {
		t.Fatal("persisted snapshot does not reproduce receipt digest")
	}
	var evidence struct {
		Families []struct {
			Name string
			Rows []json.RawMessage
		}
	}
	if err := json.Unmarshal(snapshot, &evidence); err != nil {
		t.Fatal(err)
	}
	if len(evidence.Families) != 7 {
		t.Fatalf("families: %d", len(evidence.Families))
	}
	for _, change := range []func(*TransitionCommand){
		func(c *TransitionCommand) { c.OperationID = "00000000-0000-4000-8000-000000000099" },
		func(c *TransitionCommand) { c.Key.Scope.HubSpaceID = "00000000-0000-4000-8000-000000000099" },
		func(c *TransitionCommand) { c.Key.Scope.OldInstanceID = "00000000-0000-4000-8000-000000000099" },
		func(c *TransitionCommand) { c.Key.Epoch++ },
		func(c *TransitionCommand) { c.Key.TransitionID = "00000000-0000-4000-8000-000000000099" },
	} {
		changed := command
		change(&changed)
		changed.RequestHash = FreezeRequestHash(changed)
		if _, err := store.Freeze(ctx, changed); err == nil {
			t.Fatalf("changed freeze accepted: %+v", changed)
		}
	}
	changed := command
	changed.RequestHash = strings.Repeat("0", 64)
	if _, err := store.Freeze(ctx, changed); err == nil {
		t.Fatal("unvalidated request hash accepted")
	}
	// Retirement and canceled retries cannot reopen authority or destroy evidence.
	if _, err := pool.Exec(ctx, `UPDATE account_writer_authority SET state='RETIRED' WHERE account_id=$1::uuid`, user); err != nil {
		t.Fatal(err)
	}
	recoveredPool, err := pgxpool.NewWithConfig(ctx, pool.Config())
	if err != nil {
		t.Fatal(err)
	}
	defer recoveredPool.Close()
	again, err := NewStore(recoveredPool).Freeze(ctx, command)
	if err != nil || again != receipt {
		t.Fatalf("retry: %+v %v", again, err)
	}
	expired, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := store.Freeze(expired, command); err == nil {
		t.Fatal("canceled freeze succeeded")
	}
	var state string
	if err := pool.QueryRow(ctx, `SELECT state FROM account_writer_authority WHERE account_id=$1::uuid`, user).Scan(&state); err != nil || state != "RETIRED" {
		t.Fatalf("retirement reopened: %s %v", state, err)
	}
}

func TestFreezeReceiptCannotBeRewrittenOrDeleted(t *testing.T) {
	pool, user, command := testAccount(t)
	ctx := context.Background()
	if _, err := NewStore(pool).Freeze(ctx, command); err != nil {
		t.Fatal(err)
	}
	for _, sql := range []string{`UPDATE account_writer_freeze_receipts SET request_hash=repeat('0',64) WHERE account_id=$1::uuid`, `DELETE FROM account_writer_freeze_receipts WHERE account_id=$1::uuid`, `DELETE FROM account_writer_authority WHERE account_id=$1::uuid`, `DELETE FROM users WHERE id=$1::uuid`} {
		if _, err := pool.Exec(ctx, sql, user); err == nil {
			t.Errorf("immutable authority evidence removed: %s", sql)
		}
	}
}

func TestFreezeFailureRollsBackGate(t *testing.T) {
	pool, user, command := testAccount(t)
	ctx := context.Background()
	// A failure after snapshot/UPDATE must undo the state change too.
	schema := "freeze_failure_" + strings.ReplaceAll(user, "-", "")
	if _, err := pool.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatal(err)
	}
	defer func() { _, _ = pool.Exec(ctx, "DROP SCHEMA "+schema+" CASCADE") }()
	if _, err := pool.Exec(ctx, "CREATE TABLE "+schema+".account_writer_freeze_receipts (LIKE public.account_writer_freeze_receipts INCLUDING ALL, CHECK (false))"); err != nil {
		t.Fatal(err)
	}
	cfg := pool.Config()
	cfg.ConnConfig.RuntimeParams["search_path"] = schema + ",public"
	isolated, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer isolated.Close()
	gate := func() string {
		var row string
		if err := pool.QueryRow(ctx, `SELECT row(a.*)::text FROM account_writer_authority a WHERE account_id=$1::uuid`, user).Scan(&row); err != nil {
			t.Fatal(err)
		}
		return row
	}
	before := gate()
	if _, err := NewStore(isolated).Freeze(ctx, command); err == nil {
		t.Fatal("receipt failure accepted")
	}
	if after := gate(); after != before {
		t.Fatalf("failed freeze changed its gate: %s -> %s", before, after)
	}
	if _, err := NewStore(pool).Freeze(ctx, command); err != nil {
		t.Fatalf("freeze retry after rollback: %v", err)
	}
}

// deleteAccountGateRow removes the gate row that migration 00025's trigger
// committed with the account, recreating an account that predates the eager
// row (for example one committed while 00025 ran, before 00026 re-backfilled
// it). Only a fresh account with no receipts or decisions can lose its row.
func deleteAccountGateRow(t *testing.T, pool *pgxpool.Pool, user string) {
	t.Helper()
	ctx := context.Background()
	if _, err := pool.Exec(ctx, `DELETE FROM account_writer_authority WHERE account_id=$1::uuid`, user); err != nil {
		t.Fatalf("delete gate row: %v", err)
	}
	var n int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM account_writer_authority WHERE account_id=$1::uuid`, user).Scan(&n); err != nil || n != 0 {
		t.Fatalf("gate row still present before the lazy path: rows=%d err=%v", n, err)
	}
}

// TestLockAccountWriterUniqueInitialization exercises LockAccountWriter's lazy
// fallback: with no committed gate row, concurrent first lockers must create
// exactly one OLD_ACTIVE epoch-0 row and all succeed.
func TestLockAccountWriterUniqueInitialization(t *testing.T) {
	pool, user, _ := testAccount(t)
	deleteAccountGateRow(t, pool, user)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var wg sync.WaitGroup
	results := make(chan error, 8)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			tx, err := pool.Begin(ctx)
			if err != nil {
				results <- err
				return
			}
			defer tx.Rollback(context.Background())
			gate, err := LockAccountWriter(ctx, tx, user)
			if err == nil && (gate.State != OldActive || gate.Epoch != 0) {
				t.Error("initial state differs")
			}
			if err == nil {
				err = tx.Commit(ctx)
			}
			results <- err
		}()
	}
	wg.Wait()
	close(results)
	for err := range results {
		if err != nil {
			t.Fatal(err)
		}
	}
	var n int
	var state string
	var epoch, sequence int64
	if err := pool.QueryRow(ctx, `SELECT count(*),min(state),min(epoch),min(decision_sequence) FROM account_writer_authority WHERE account_id=$1::uuid`, user).Scan(&n, &state, &epoch, &sequence); err != nil || n != 1 {
		t.Fatalf("initial account rows=%d err=%v", n, err)
	}
	if state != OldActive || epoch != 0 || sequence != 0 {
		t.Fatalf("lazily created gate %s/%d/%d", state, epoch, sequence)
	}
}

// TestRebackfillRestoresMissingGateRows (migration 00026): an account left
// without a gate row by 00025's backfill-before-trigger window gets its
// OLD_ACTIVE epoch-0 row from the re-backfill, and the re-backfill changes
// no existing row.
func TestRebackfillRestoresMissingGateRows(t *testing.T) {
	pool, user, command := testAccount(t)
	_, other, _ := testAccount(t)
	ctx := context.Background()
	if _, err := NewStore(pool).Freeze(ctx, command); err != nil {
		t.Fatalf("freeze an existing gate: %v", err)
	}
	gateOf := func(account string) string {
		var row string
		if err := pool.QueryRow(ctx, `SELECT a::text FROM account_writer_authority a WHERE account_id=$1::uuid`, account).Scan(&row); err != nil {
			t.Fatalf("gate of %s: %v", account, err)
		}
		return row
	}
	frozenBefore := gateOf(user)
	deleteAccountGateRow(t, pool, other)
	raw, err := migrations.FS.ReadFile("00026_rebackfill_account_writer_gate_rows.sql")
	if err != nil {
		t.Fatalf("read 00026: %v", err)
	}
	up, _, ok := strings.Cut(string(raw), "-- +goose Down")
	if !ok || !strings.Contains(up, "-- +goose Up") {
		t.Fatal("00026 lacks goose Up/Down sections")
	}
	for i := 0; i < 2; i++ {
		if _, err := pool.Exec(ctx, up); err != nil {
			t.Fatalf("re-backfill run %d: %v", i+1, err)
		}
	}
	var state, instance string
	var epoch, sequence int64
	if err := pool.QueryRow(ctx, `SELECT a.state,a.epoch,a.decision_sequence,a.instance_id::text FROM account_writer_authority a JOIN legacy_server_instance i ON i.instance_id=a.instance_id AND i.singleton WHERE a.account_id=$1::uuid`, other).Scan(&state, &epoch, &sequence, &instance); err != nil {
		t.Fatalf("re-backfill left the account without a gate row: %v", err)
	}
	if state != OldActive || epoch != 0 || sequence != 0 {
		t.Fatalf("re-backfilled gate %s/%d/%d", state, epoch, sequence)
	}
	if after := gateOf(user); after != frozenBefore {
		t.Fatalf("re-backfill changed an existing gate: %s -> %s", frozenBefore, after)
	}
}

// TestAccountCreationCommitsWriterGate (H4T10-3, migration 00025): the gate
// row is committed together with the account, before any write, so upload
// and Freeze always queue on the same existing row.
func TestAccountCreationCommitsWriterGate(t *testing.T) {
	pool, user, _ := testAccount(t)
	var state, instance string
	var epoch, sequence int64
	if err := pool.QueryRow(context.Background(), `SELECT a.state,a.epoch,a.decision_sequence,a.instance_id::text FROM account_writer_authority a JOIN legacy_server_instance i ON i.instance_id=a.instance_id AND i.singleton WHERE a.account_id=$1::uuid`, user).Scan(&state, &epoch, &sequence, &instance); err != nil {
		t.Fatalf("no committed gate row for a new account: %v", err)
	}
	if state != OldActive || epoch != 0 || sequence != 0 {
		t.Fatalf("new account gate %s/%d/%d", state, epoch, sequence)
	}
	var orphans int
	if err := pool.QueryRow(context.Background(), `SELECT count(*) FROM users u WHERE NOT EXISTS(SELECT 1 FROM account_writer_authority a WHERE a.account_id=u.id)`).Scan(&orphans); err != nil || orphans != 0 {
		t.Fatalf("accounts without a gate row: %d %v", orphans, err)
	}
}

func TestFreezeRejectsZeroIdentity(t *testing.T) {
	pool, _, command := testAccount(t)
	command.Key.Scope.HubInstanceID = "00000000-0000-0000-0000-000000000000"
	command.RequestHash = FreezeRequestHash(command)
	if _, err := NewStore(pool).Freeze(context.Background(), command); err == nil {
		t.Error("zero instance identity admitted")
	}
}

func TestSnapshotDigestIndependentOfSessionTimezone(t *testing.T) {
	pool, user, _ := testAccount(t)
	ctx := context.Background()
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	gate, err := LockAccountWriter(ctx, tx, user)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO bodyweight_logs (user_id,date,weight_kg,created_at) VALUES ($1::uuid,'2026-10-09',80,'2026-10-09T10:00:00Z')`, user); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `SET LOCAL TIME ZONE 'Europe/Rome'`); err != nil {
		t.Fatal(err)
	}
	first, err := snapshotAccount(ctx, tx, gate)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `SET LOCAL TIME ZONE 'UTC'`); err != nil {
		t.Fatal(err)
	}
	second, err := snapshotAccount(ctx, tx, gate)
	if err != nil {
		t.Fatal(err)
	}
	if string(first) != string(second) {
		t.Fatal("snapshot digest encoding depends on session timezone")
	}
}
