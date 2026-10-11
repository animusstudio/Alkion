package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"workout-tracker/server/internal/auth"
	"workout-tracker/server/internal/db"
	"workout-tracker/server/internal/migration"
)

// Synthetic status reader for HTTP dispatch/JWT boundary tests only. Actual mTLS
// and two independent PostgreSQL handlers are proved in migration integration.
type syntheticOwnerRoutePeer struct{ receipt migration.Receipt }

func (p *syntheticOwnerRoutePeer) Status(context.Context, migration.TransitionKey) (migration.Receipt, error) {
	return p.receipt, nil
}
func TestPeerOwnerControlRoutes(t *testing.T) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	if err := db.Migrate(ctx, url); err != nil {
		t.Fatal(err)
	}
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	var account, instance, transition, operation string
	if err = pool.QueryRow(ctx, `INSERT INTO users(email,password_hash)VALUES(gen_random_uuid()::text||'@example.invalid','synthetic')RETURNING id::text`).Scan(&account); err != nil {
		t.Fatal(err)
	}
	if err = pool.QueryRow(ctx, `SELECT instance_id::text,gen_random_uuid()::text,gen_random_uuid()::text FROM legacy_server_instance`).Scan(&instance, &transition, &operation); err != nil {
		t.Fatal(err)
	}
	scope := migration.ScopeBinding{HubInstanceID: "00000000-0000-4000-8000-000000000001", OldInstanceID: instance, OldAccountID: account, HubSpaceID: "00000000-0000-4000-8000-000000000002", HubSourceID: "00000000-0000-4000-8000-000000000003"}
	c := migration.TransitionCommand{Key: migration.TransitionKey{Scope: scope, TransitionID: transition, Epoch: 1}, OperationID: operation}
	c.RequestHash = migration.FreezeRequestHash(c)
	key, err := rsaKeyForTest()
	if err != nil {
		t.Fatal(err)
	}
	signer := auth.NewSigner(key, "synthetic", "synthetic-old")
	verifier := auth.NewVerifier(&key.PublicKey, "synthetic-old")
	token, err := signer.Sign(account, "old-api", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	other, _ := signer.Sign("00000000-0000-4000-8000-000000000099", "old-api", time.Minute)
	store := migration.NewStore(pool)
	peer := &syntheticOwnerRoutePeer{}
	control := NewMigrationControl(migration.NewService(store, peer, scope))
	router := NewRouter(Deps{Verifier: verifier, APIAudience: "old-api", Migration: control})
	body, _ := json.Marshal(map[string]any{"command": c, "owner_consent": true})
	path := "/migration/transitions/" + transition + "/freeze"
	run := func(path, token string, body []byte) int {
		req := httptest.NewRequest("POST", path, bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)
		return w.Code
	}
	if got := run(path, "", body); got != 401 {
		t.Fatalf("no auth=%d", got)
	}
	if got := run(path, other, body); got != 403 {
		t.Fatalf("wrong owner=%d", got)
	}
	noConsent, _ := json.Marshal(map[string]any{"command": c, "owner_consent": false})
	if got := run(path, token, noConsent); got != 403 {
		t.Fatalf("no consent=%d", got)
	}
	for _, state := range []string{"READY", "RETIRED"} {
		claim, _ := json.Marshal(map[string]any{"command": c, "owner_consent": true, "peer_receipt": map[string]string{"state": state}})
		if got := run(path, token, claim); got != 400 {
			t.Fatalf("client %s claim=%d", state, got)
		}
	}
	badCase := bytes.Replace(body, []byte(`"command":`), []byte(`"COMMAND":`), 1)
	if got := run(path, token, badCase); got != 400 {
		t.Fatalf("case-aliased command=%d", got)
	}
	commandJSON, _ := json.Marshal(c)
	duplicate := append([]byte(`{"command":`), commandJSON...)
	duplicate = append(duplicate, []byte(`,"owner_consent":false,"owner_consent":true}`)...)
	if got := run(path, token, duplicate); got != 400 {
		t.Fatalf("duplicate consent=%d", got)
	}
	if got := run(path+"?claim=READY", token, body); got != 400 {
		t.Fatalf("query=%d", got)
	}
	if got := run(path, token, body); got != http.StatusOK {
		t.Fatalf("freeze=%d", got)
	}
	if got := run(path, token, body); got != http.StatusOK {
		t.Fatalf("retry=%d", got)
	}
	frozen, err := store.Status(ctx, c.Key)
	if err != nil {
		t.Fatal(err)
	}
	peer.receipt = migration.Receipt{Key: c.Key, State: "READY", Digest: strings.Repeat("e", 64), ServerSnapshotDigest: frozen.ServerSnapshotDigest, OperationID: c.OperationID, RequestHash: strings.Repeat("a", 64), DecisionSequence: 2}
	decision := c
	decision.Digest = peer.receipt.Digest
	if err = pool.QueryRow(ctx, `SELECT gen_random_uuid()::text`).Scan(&decision.OperationID); err != nil {
		t.Fatal(err)
	}
	decision.RequestHash = migration.DecisionRequestHash("surrender", decision)
	surrenderBody, _ := json.Marshal(map[string]any{"command": decision, "owner_consent": true})
	surrenderPath := "/migration/transitions/" + transition + "/surrender"
	if got := run(surrenderPath, token, surrenderBody); got != 200 {
		t.Fatalf("JWT owner surrender=%d", got)
	}
	if got := run(surrenderPath, token, surrenderBody); got != 200 {
		t.Fatalf("JWT owner decision retry=%d", got)
	}
	peer.receipt.State = "ABORTED"
	if err = pool.QueryRow(ctx, `SELECT gen_random_uuid()::text`).Scan(&decision.OperationID); err != nil {
		t.Fatal(err)
	}
	decision.RequestHash = migration.DecisionRequestHash("unfreeze", decision)
	unfreezeBody, _ := json.Marshal(map[string]any{"command": decision, "owner_consent": true})
	if got := run("/migration/transitions/"+transition+"/unfreeze", token, unfreezeBody); got != 503 {
		t.Fatalf("JWT delayed unfreeze=%d", got)
	}
	var count int
	if err = pool.QueryRow(ctx, `SELECT count(*) FROM account_migration_owner_consents WHERE account_id=$1::uuid AND verified_subject=$1::uuid AND action='freeze'`, account).Scan(&count); err != nil || count != 1 {
		t.Fatalf("consent=%d %v", count, err)
	}
}
