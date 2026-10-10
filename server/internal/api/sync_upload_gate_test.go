package api

import (
	"context"
	"fmt"
	"io"
	"os"
	"strings"
	"sync"
	"time"

	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"workout-tracker/server/internal/db"
	"workout-tracker/server/internal/migration"

	"github.com/jackc/pgx/v5/pgxpool"
)

// A gate failure must never touch the queue payload or acknowledge its work.
type unreadQueueBody struct{ reads atomic.Int32 }

func (b *unreadQueueBody) Read(p []byte) (int, error) {
	b.reads.Add(1)
	return 0, fmt.Errorf("queue body must remain unread")
}
func (*unreadQueueBody) Close() error { return nil }

func TestUploadGateStorageUnavailable(t *testing.T) {
	pool := uploadTestPool(t)
	user := seedUploadUser(t, pool)
	cfg := pool.Config()
	cfg.ConnConfig.RuntimeParams["search_path"] = "pg_catalog"
	unavailable, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer unavailable.Close()
	body := &unreadQueueBody{}
	req := httptest.NewRequest(http.MethodPost, "/sync/upload", body)
	req = req.WithContext(context.WithValue(req.Context(), userIDKey, user))
	rec := httptest.NewRecorder()
	NewUploadHandler(unavailable).Upload(rec, req)
	if rec.Code != http.StatusServiceUnavailable {
		t.Errorf("gate unavailable: got %d, want 503; %s", rec.Code, rec.Body.String())
	}
	if got := body.reads.Load(); got != 0 {
		t.Errorf("read unavailable queue %d times", got)
	}
}

func TestUploadGateBeforeDecode(t *testing.T) {
	pool := uploadTestPool(t)
	if err := db.Migrate(context.Background(), os.Getenv("TEST_DATABASE_URL")); err != nil {
		t.Fatal(err)
	}
	user := seedUploadUser(t, pool)
	h := NewUploadHandler(pool)
	cmd := freezeCommand(t, pool, user)
	receipt, err := migration.NewStore(pool).Freeze(context.Background(), cmd)
	if err != nil {
		t.Fatal(err)
	}
	if receipt.State != "FROZEN" || receipt.Key.Epoch != 1 {
		t.Fatalf("freeze receipt: %+v", receipt)
	}
	for _, state := range []string{"FROZEN", "RETIRED"} {
		if _, err := pool.Exec(context.Background(), `UPDATE account_writer_authority SET state=$2 WHERE account_id=$1::uuid`, user, state); err != nil {
			t.Fatal(err)
		}
		for _, payload := range []string{"not json", `{"batch":[]}`, `{"batch":[{"table":"invalid","op":"PUT"}]}`, allFamilies(t, pool)} {
			t.Run(state+"/"+fmt.Sprint(len(payload)), func(t *testing.T) {
				body := &countedQueueBody{Reader: strings.NewReader(payload)}
				req := httptest.NewRequest(http.MethodPost, "/sync/upload", body)
				req = req.WithContext(context.WithValue(req.Context(), userIDKey, user))
				rec := httptest.NewRecorder()
				h.Upload(rec, req)
				if rec.Code != 503 || body.reads != 0 {
					t.Fatalf("status=%d reads=%d body=%s", rec.Code, body.reads, rec.Body.String())
				}
			})
		}
	}
	for _, table := range []string{"sessions", "sets", "bodyweight_logs", "muscle_targets", "exercises", "day_templates", "day_template_items"} {
		owner := "user_id"
		if table == "exercises" || strings.HasPrefix(table, "day_template") {
			owner = "created_by"
		}
		var n int
		if err := pool.QueryRow(context.Background(), "SELECT count(*) FROM "+table+" WHERE "+owner+"=$1::uuid", user).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n != 0 {
			t.Fatalf("%s changed: %d", table, n)
		}
	}
	signer, verifier := newAuthPair(t)
	token, err := signer.Sign(user, "workout-tracker-api", -time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	router := NewRouter(Deps{Auth: &AuthHandler{}, Verifier: verifier, APIAudience: "workout-tracker-api", Upload: h})
	body := &unreadQueueBody{}
	req := httptest.NewRequest(http.MethodPost, "/sync/upload", body)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	if rec.Code != 401 || body.reads.Load() != 0 {
		t.Fatalf("expired auth status=%d reads=%d", rec.Code, body.reads.Load())
	}
}

type countedQueueBody struct {
	*strings.Reader
	reads int
}

func (b *countedQueueBody) Read(p []byte) (int, error) { b.reads++; return b.Reader.Read(p) }
func (*countedQueueBody) Close() error                 { return nil }

func freezeCommand(t *testing.T, pool *pgxpool.Pool, user string) migration.TransitionCommand {
	t.Helper()
	var instance string
	if err := pool.QueryRow(context.Background(), `SELECT instance_id::text FROM legacy_server_instance WHERE singleton`).Scan(&instance); err != nil {
		t.Fatal(err)
	}
	cmd := migration.TransitionCommand{Key: migration.TransitionKey{Scope: migration.ScopeBinding{OldInstanceID: instance, OldAccountID: user, HubInstanceID: "00000000-0000-4000-8000-000000000001", HubSpaceID: "00000000-0000-4000-8000-000000000002", HubSourceID: "00000000-0000-4000-8000-000000000003"}, TransitionID: "00000000-0000-4000-8000-000000000004", Epoch: 1}, OperationID: "00000000-0000-4000-8000-000000000005"}
	if err := pool.QueryRow(context.Background(), `SELECT gen_random_uuid()::text,gen_random_uuid()::text`).Scan(&cmd.Key.TransitionID, &cmd.OperationID); err != nil {
		t.Fatal(err)
	}
	cmd.RequestHash = migration.FreezeRequestHash(cmd)
	return cmd
}

func allFamilies(t *testing.T, pool *pgxpool.Pool) string {
	t.Helper()
	var exercise string
	if err := pool.QueryRow(context.Background(), `SELECT id::text FROM exercises WHERE is_template LIMIT 1`).Scan(&exercise); err != nil {
		t.Fatal(err)
	}
	payload := fmt.Sprintf(`{"batch":[
 {"op":"PUT","table":"exercises","id":"00000000-0000-4000-8000-000000000011","data":{"name":"Synthetic","slug":"synthetic-fence","muscle_group":"chest"}},
 {"op":"PUT","table":"day_templates","id":"00000000-0000-4000-8000-000000000012","data":{"name":"Synthetic","position":1}},
 {"op":"PUT","table":"day_template_items","id":"00000000-0000-4000-8000-000000000013","data":{"day_template_id":"00000000-0000-4000-8000-000000000012","exercise_id":"%s","position":1}},
 {"op":"PUT","table":"sessions","id":"00000000-0000-4000-8000-000000000014","data":{"date":"2026-10-09"}},
 {"op":"PUT","table":"sets","id":"00000000-0000-4000-8000-000000000015","data":{"session_id":"00000000-0000-4000-8000-000000000014","exercise_id":"%s","set_number":1,"weight_kg":"10.00","reps":5}},
 {"op":"PUT","table":"bodyweight_logs","id":"00000000-0000-4000-8000-000000000016","data":{"date":"2026-10-09","weight_kg":"80.00"}},
 {"op":"PUT","table":"muscle_targets","id":"00000000-0000-4000-8000-000000000017","data":{"muscle":"chest","target_sets":10}}
 ]}`, exercise, exercise)
	ids := make([]string, 7)
	for i := range ids {
		if err := pool.QueryRow(context.Background(), `SELECT gen_random_uuid()::text`).Scan(&ids[i]); err != nil {
			t.Fatal(err)
		}
		payload = strings.ReplaceAll(payload, fmt.Sprintf("00000000-0000-4000-8000-0000000000%02d", 11+i), ids[i])
	}
	payload = strings.ReplaceAll(payload, "synthetic-fence", "synthetic-fence-"+ids[0])
	t.Cleanup(func() {
		for _, pair := range []struct{ table, id string }{{"day_template_items", ids[2]}, {"day_templates", ids[1]}, {"sessions", ids[3]}, {"exercises", ids[0]}, {"bodyweight_logs", ids[5]}, {"muscle_targets", ids[6]}} {
			_, _ = pool.Exec(context.Background(), "DELETE FROM "+pair.table+" WHERE id=$1::uuid", pair.id)
		}
	})
	return payload
}

func TestUploadFreezeWaitsForCommit(t *testing.T) {
	pool := uploadTestPool(t)
	if err := db.Migrate(context.Background(), os.Getenv("TEST_DATABASE_URL")); err != nil {
		t.Fatal(err)
	}
	user := seedUploadUser(t, pool)
	h := NewUploadHandler(pool)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	// Establish the unique account row before exercising lock ordering.
	if rec := postUpload(t, h, user, `{"batch":[]}`); rec.Code != 200 {
		t.Fatalf("initialize: %d", rec.Code)
	}
	reader, writer := io.Pipe()
	started := make(chan struct{})
	req := httptest.NewRequest(http.MethodPost, "/sync/upload", &signaledBody{ReadCloser: reader, started: started})
	req = req.WithContext(context.WithValue(ctx, userIDKey, user))
	first := httptest.NewRecorder()
	firstDone := make(chan struct{})
	go func() { h.Upload(first, req); close(firstDone) }()
	select {
	case <-started:
	case <-ctx.Done():
		t.Fatal("first upload never read")
	}
	cmd := freezeCommand(t, pool, user)
	type freezeResult struct {
		r migration.Receipt
		e error
	}
	frozen := make(chan freezeResult, 1)
	go func() { r, e := migration.NewStore(pool).Freeze(ctx, cmd); frozen <- freezeResult{r, e} }()
	// Observe the real database lock waits: freeze first, then the later
	// upload's FOR UPDATE queued behind it, both blocked by the first upload's
	// transaction. Releasing the first upload before the later one is queued
	// would let it lock the row in the instant between the first commit and
	// freeze re-locking it (PostgreSQL row-lock waiters are not a strict
	// queue for a newcomer that finds the row unlocked).
	waitForAccountLockWaiters := func(want int, failure string) {
		t.Helper()
		for {
			var waiting int
			err := pool.QueryRow(ctx, `SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE '%account_writer_authority%' AND cardinality(pg_blocking_pids(pid))>0 AND pid<>pg_backend_pid()`).Scan(&waiting)
			if err != nil {
				t.Fatal(err)
			}
			if waiting >= want {
				return
			}
			select {
			case <-time.After(time.Millisecond * 5):
			case <-ctx.Done():
				t.Fatal(failure)
			}
		}
	}
	waitForAccountLockWaiters(1, "freeze did not wait for account lock")
	second := httptest.NewRecorder()
	body := &unreadQueueBody{}
	secondReq := httptest.NewRequest(http.MethodPost, "/sync/upload", body)
	secondReq = secondReq.WithContext(context.WithValue(ctx, userIDKey, user))
	secondDone := make(chan struct{})
	go func() { h.Upload(second, secondReq); close(secondDone) }()
	waitForAccountLockWaiters(2, "later upload did not queue its account lock behind freeze")
	_, err := io.WriteString(writer, allFamilies(t, pool))
	if err != nil {
		t.Fatal(err)
	}
	_ = writer.Close()
	select {
	case <-firstDone:
	case <-ctx.Done():
		t.Fatal("first upload timed out")
	}
	if first.Code != 200 || !strings.Contains(first.Body.String(), `"applied":7`) {
		t.Fatalf("first: %d %s", first.Code, first.Body.String())
	}
	var fr freezeResult
	select {
	case fr = <-frozen:
	case <-ctx.Done():
		t.Fatal("freeze timed out")
	}
	if fr.e != nil {
		t.Fatal(fr.e)
	}
	select {
	case <-secondDone:
	case <-ctx.Done():
		t.Fatal("second upload timed out")
	}
	if second.Code != 503 || body.reads.Load() != 0 {
		t.Fatalf("later upload: %d reads=%d", second.Code, body.reads.Load())
	}
	var snapshot []byte
	if err := pool.QueryRow(ctx, `SELECT snapshot FROM account_writer_freeze_receipts WHERE account_id=$1::uuid`, user).Scan(&snapshot); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"sessions", "sets", "bodyweight_logs", "muscle_targets", "exercises", "day_templates", "day_template_items"} {
		if !strings.Contains(string(snapshot), `"`+name+`"`) {
			t.Fatalf("snapshot missing %s", name)
		}
	}
	if !strings.Contains(string(snapshot), `"date":"2026-10-09"`) || !strings.Contains(string(snapshot), `"is_top_set":true`) || !strings.Contains(string(snapshot), `"is_pr":true`) {
		t.Fatalf("baseline did not contain committed recomputation: %s", snapshot)
	}
	repeat, err := migration.NewStore(pool).Freeze(ctx, cmd)
	if err != nil || repeat != fr.r {
		t.Fatalf("exact retry changed receipt: %+v %+v %v", fr.r, repeat, err)
	}
	// Every unrelated account still uses the old wire protocol (no installation headers).
	other := seedUploadUser(t, pool)
	if rec := postUpload(t, h, other, `not json`); rec.Code != 200 {
		t.Fatalf("unrelated malformed upload: %d", rec.Code)
	}
}

type signaledBody struct {
	io.ReadCloser
	started chan struct{}
	once    sync.Once
}

func (b *signaledBody) Read(p []byte) (int, error) {
	b.once.Do(func() { close(b.started) })
	return b.ReadCloser.Read(p)
}

func TestUploadGateOversizeDoesNotAcknowledge(t *testing.T) {
	pool := uploadTestPool(t)
	user := seedUploadUser(t, pool)
	// Even a valid first JSON document cannot hide an unbounded trailing body.
	rec := postUpload(t, NewUploadHandler(pool), user, `{"batch":[]}`+strings.Repeat(" ", int(MaxUploadBytes)))
	if rec.Code != 503 {
		t.Fatalf("oversized queue acknowledged: %d %s", rec.Code, rec.Body.String())
	}
	var gates int
	if err := pool.QueryRow(context.Background(), `SELECT count(*) FROM account_writer_authority WHERE account_id=$1::uuid`, user).Scan(&gates); err != nil {
		t.Fatal(err)
	}
	if gates != 0 {
		t.Fatalf("failed upload committed gate initialization: %d", gates)
	}
}

func TestUploadGateCanceledBodyRollsBack(t *testing.T) {
	pool := uploadTestPool(t)
	user := seedUploadUser(t, pool)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	reader, writer := io.Pipe()
	defer writer.Close()
	started := make(chan struct{})
	body := &signaledBody{ReadCloser: reader, started: started}
	req := httptest.NewRequest(http.MethodPost, "/sync/upload", body)
	req = req.WithContext(context.WithValue(ctx, userIDKey, user))
	rec := httptest.NewRecorder()
	done := make(chan struct{})
	go func() { NewUploadHandler(pool).Upload(rec, req); close(done) }()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("read never started")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("cancellation did not bound body read")
	}
	if rec.Code != 503 {
		t.Fatalf("canceled queue acknowledged: %d", rec.Code)
	}
	var gates int
	if err := pool.QueryRow(context.Background(), `SELECT count(*) FROM account_writer_authority WHERE account_id=$1::uuid`, user).Scan(&gates); err != nil {
		t.Fatal(err)
	}
	if gates != 0 {
		t.Fatal("canceled upload committed")
	}
}

func TestUploadGateMissingInstanceDoesNotAssumeActive(t *testing.T) {
	pool := uploadTestPool(t)
	user := seedUploadUser(t, pool)
	// Isolate missing-instance evidence without modifying the real test instance.
	schema := "missing_instance_" + randomHex(t)
	if _, err := pool.Exec(context.Background(), "CREATE SCHEMA "+schema); err != nil {
		t.Fatal(err)
	}
	defer func() { _, _ = pool.Exec(context.Background(), "DROP SCHEMA "+schema+" CASCADE") }()
	if _, err := pool.Exec(context.Background(), "CREATE TABLE "+schema+".legacy_server_instance (LIKE public.legacy_server_instance INCLUDING ALL)"); err != nil {
		t.Fatal(err)
	}
	cfg := pool.Config()
	cfg.ConnConfig.RuntimeParams["search_path"] = schema + ",public"
	isolated, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer isolated.Close()
	// An existing account gate also must not survive lost instance identity.
	if rec := postUpload(t, NewUploadHandler(pool), user, `{"batch":[]}`); rec.Code != 200 {
		t.Fatal(rec.Code)
	}
	body := &unreadQueueBody{}
	req := httptest.NewRequest(http.MethodPost, "/sync/upload", body)
	req = req.WithContext(context.WithValue(req.Context(), userIDKey, user))
	rec := httptest.NewRecorder()
	NewUploadHandler(isolated).Upload(rec, req)
	if rec.Code != 503 || body.reads.Load() != 0 {
		t.Fatalf("missing instance: status=%d reads=%d", rec.Code, body.reads.Load())
	}
}

func TestUploadGateCommitFailurePreservesQueue(t *testing.T) {
	pool := uploadTestPool(t)
	user := seedUploadUser(t, pool)
	ctx := context.Background()
	schema := "commit_failure_" + randomHex(t)
	if _, err := pool.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatal(err)
	}
	defer func() { _, _ = pool.Exec(ctx, "DROP SCHEMA "+schema+" CASCADE") }()
	statements := []string{
		"CREATE TABLE " + schema + ".bodyweight_logs (LIKE public.bodyweight_logs INCLUDING ALL)",
		"CREATE FUNCTION " + schema + ".fail_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic deferred failure'; END $$",
		"CREATE CONSTRAINT TRIGGER fail_commit AFTER INSERT ON " + schema + ".bodyweight_logs DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION " + schema + ".fail_commit()",
	}
	for _, sql := range statements {
		if _, err := pool.Exec(ctx, sql); err != nil {
			t.Fatal(err)
		}
	}
	cfg := pool.Config()
	cfg.ConnConfig.RuntimeParams["search_path"] = schema + ",public"
	isolated, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer isolated.Close()
	rec := postUpload(t, NewUploadHandler(isolated), user, `{"batch":[{"op":"PUT","table":"bodyweight_logs","id":"00000000-0000-4000-8000-000000000001","data":{"date":"2026-10-09","weight_kg":"80.00"}}]}`)
	if rec.Code != 503 || strings.Contains(rec.Body.String(), "applied") {
		t.Fatalf("commit failure acknowledged: %d %s", rec.Code, rec.Body.String())
	}
	var rows int
	if err := isolated.QueryRow(ctx, `SELECT count(*) FROM bodyweight_logs`).Scan(&rows); err != nil {
		t.Fatal(err)
	}
	if rows != 0 {
		t.Fatal("failed commit left row changes")
	}
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM account_writer_authority WHERE account_id=$1::uuid`, user).Scan(&rows); err != nil {
		t.Fatal(err)
	}
	if rows != 0 {
		t.Fatal("failed commit left gate initialization")
	}
}

func TestUploadGateSlowHTTPBodyReleasesLock(t *testing.T) {
	pool := uploadTestPool(t)
	user := seedUploadUser(t, pool)
	started := make(chan struct{})
	h := NewUploadHandler(pool)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r = r.WithContext(context.WithValue(r.Context(), userIDKey, user))
		r.Body = &signaledBody{ReadCloser: r.Body, started: started}
		h.Upload(w, r)
	}))
	defer srv.Close()
	reader, writer := io.Pipe()
	defer writer.Close()
	request, err := http.NewRequest(http.MethodPost, srv.URL+"/sync/upload", reader)
	if err != nil {
		t.Fatal(err)
	}
	type result struct {
		response *http.Response
		err      error
	}
	done := make(chan result, 1)
	client := srv.Client()
	client.Timeout = UploadTimeout + 3*time.Second
	go func() { response, err := client.Do(request); done <- result{response, err} }()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("slow body never reached handler")
	}
	select {
	case result := <-done:
		if result.err != nil {
			t.Fatal(result.err)
		}
		defer result.response.Body.Close()
		if result.response.StatusCode != 503 {
			t.Fatalf("slow body acknowledged: %d", result.response.StatusCode)
		}
	case <-time.After(UploadTimeout + 2*time.Second):
		t.Fatal("slow HTTP body held account lock indefinitely")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(context.Background())
	if _, err := migration.LockAccountWriter(ctx, tx, user); err != nil {
		t.Fatalf("slow body's account lock still held: %v", err)
	}
}
