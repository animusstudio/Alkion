package api

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"workout-tracker/server/internal/auth"
	"workout-tracker/server/internal/db"
	"workout-tracker/server/internal/migration"
)

func abortCertificate(t *testing.T, ca *x509.Certificate, signer *ecdsa.PrivateKey, server bool) (tls.Certificate, *x509.Certificate, *ecdsa.PrivateKey) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	serial, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	cert := &x509.Certificate{SerialNumber: serial, NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature}
	parent := ca
	if ca == nil {
		cert.IsCA = true
		cert.BasicConstraintsValid = true
		cert.KeyUsage |= x509.KeyUsageCertSign
		parent = cert
		signer = key
	} else if server {
		cert.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}
		cert.IPAddresses = []net.IP{net.ParseIP("127.0.0.1")}
	} else {
		cert.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}
	}
	der, err := x509.CreateCertificate(rand.Reader, cert, parent, &key.PublicKey, signer)
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key, Leaf: parsed}, parsed, key
}
func abortPin(c tls.Certificate) string {
	h := sha256.Sum256(c.Certificate[0])
	return hex.EncodeToString(h[:])
}
func abortCertPEM(c tls.Certificate) []byte {
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: c.Certificate[0]})
}
func abortCAPEM(c *x509.Certificate) []byte {
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: c.Raw})
}
func abortKeyPEM(t *testing.T, c tls.Certificate) []byte {
	t.Helper()
	b, err := x509.MarshalECPrivateKey(c.PrivateKey.(*ecdsa.PrivateKey))
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: b})
}

// This fixture executes the actual Hub PREPARED barrier, blocked Ready baseline
// association, Abort, old JWT Unfreeze, and Hub authenticated recovery control.
// No READY producer or peer-status table substitutes for either authority store.
func TestActualTwoPostgresAbortCompletion(t *testing.T) {
	checkout, dsn := os.Getenv("PDH_PEER_TEST_HUB_CHECKOUT"), os.Getenv("TEST_DATABASE_URL")
	if checkout == "" || dsn == "" || os.Getenv("HUB_TEST_DATABASE_URL") == "" {
		t.Skip("two-repository disposable PostgreSQL fixture requires explicit checkout and DSNs")
	}
	ctx := context.Background()
	if err := db.Migrate(ctx, dsn); err != nil {
		t.Fatal(err)
	}
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	var account, instance string
	if err = pool.QueryRow(ctx, `INSERT INTO users(email,password_hash)VALUES(gen_random_uuid()::text||'@example.invalid','synthetic')RETURNING id::text`).Scan(&account); err != nil {
		t.Fatal(err)
	}
	// The current monotonic authority guard intentionally retains decisions.
	if err = pool.QueryRow(ctx, `SELECT instance_id::text FROM legacy_server_instance WHERE singleton`).Scan(&instance); err != nil {
		t.Fatal(err)
	}
	procCtx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	binary := filepath.Join(t.TempDir(), "actual-abort-hub.test")
	build := exec.CommandContext(procCtx, "go", "test", "-race", "-c", "./apps/api/internal/postgres", "-o", binary)
	build.Dir = checkout
	build.Env = append(os.Environ(), "GOCACHE=/tmp/pdh-lineage-go-cache")
	if output, e := build.CombinedOutput(); e != nil {
		t.Fatalf("build actual Hub fixture %s %v", output, e)
	}
	cmd := exec.CommandContext(procCtx, binary, "-test.run=^TestActualAbortHubPeerProcess$", "-test.v")
	cmd.Dir = filepath.Join(checkout, "apps/api/internal/postgres")
	cmd.Env = append(os.Environ(), "PDH_ACTUAL_ABORT_PROCESS=1", "GOCACHE=/tmp/pdh-lineage-go-cache")
	cmd.Stderr = os.Stderr
	in, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err = cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		in.Close()
		if e := cmd.Wait(); e != nil {
			t.Errorf("actual Hub fixture process %v", e)
		}
	}()
	encoder := json.NewEncoder(in)
	scanner := bufio.NewScanner(out)
	scanner.Buffer(make([]byte, 4096), 2<<20)
	frame := func(prefix string) string {
		t.Helper()
		for scanner.Scan() {
			line := scanner.Text()
			if strings.HasPrefix(line, prefix) {
				return strings.TrimPrefix(line, prefix)
			}
			t.Log(line)
		}
		t.Fatal("missing actual Hub fixture frame " + prefix)
		return ""
	}
	if err = encoder.Encode(struct{ OldInstanceID, OldAccountID string }{instance, account}); err != nil {
		t.Fatal(err)
	}
	var key migration.TransitionKey
	if err = json.Unmarshal([]byte(frame("AUTHORITY_KEY=")), &key); err != nil {
		t.Fatal(err)
	}
	_, hca, hcak := abortCertificate(t, nil, nil, true)
	hubServer, _, _ := abortCertificate(t, hca, hcak, true)
	_, occa, occak := abortCertificate(t, nil, nil, false)
	oldClient, _, _ := abortCertificate(t, occa, occak, false)
	_, oca, ocak := abortCertificate(t, nil, nil, true)
	oldServer, _, _ := abortCertificate(t, oca, ocak, true)
	_, hcca, hccak := abortCertificate(t, nil, nil, false)
	hubClient, _, _ := abortCertificate(t, hcca, hccak, false)
	roots := x509.NewCertPool()
	roots.AddCert(hcca)
	store := migration.NewStore(pool)
	handler, err := migration.NewHandler(migration.Policy{Scope: key.Scope, PeerInstanceID: key.Scope.HubInstanceID, CertificateSHA256: abortPin(hubClient)}, store)
	if err != nil {
		t.Fatal(err)
	}
	oldTLS := httptest.NewUnstartedServer(handler)
	oldTLS.TLS = &tls.Config{Certificates: []tls.Certificate{oldServer}, ClientCAs: roots, ClientAuth: tls.RequireAndVerifyClientCert, MinVersion: tls.VersionTLS13}
	oldTLS.StartTLS()
	defer oldTLS.Close()
	cfg := struct {
		Certificate, PrivateKey, ClientCA, ServerCA, ClientCertificate, ClientKey []byte
		ClientPin, RepsURL, RepsPin                                               string
	}{abortCertPEM(hubServer), abortKeyPEM(t, hubServer), abortCAPEM(occa), abortCAPEM(oca), abortCertPEM(hubClient), abortKeyPEM(t, hubClient), abortPin(oldClient), oldTLS.URL, abortPin(oldServer)}
	if err = encoder.Encode(cfg); err != nil {
		t.Fatal(err)
	}
	hubURL := frame("AUTHORITY_URL=")
	hubRoots := x509.NewCertPool()
	hubRoots.AddCert(hca)
	peer, err := migration.NewClient(migration.ClientConfig{URL: hubURL, Scope: key.Scope, PeerInstanceID: key.Scope.HubInstanceID, CertificateSHA256: abortPin(hubServer), Roots: hubRoots, Certificate: oldClient})
	if err != nil {
		t.Fatal(err)
	}
	hubControl := func(action string, status int) json.RawMessage {
		t.Helper()
		if e := encoder.Encode(struct{ Action string }{action}); e != nil {
			t.Fatal(e)
		}
		var r struct {
			Status int             `json:"status"`
			Body   json.RawMessage `json:"body"`
		}
		if e := json.Unmarshal([]byte(frame("AUTHORITY_REPLY=")), &r); e != nil {
			t.Fatal(e)
		}
		if r.Status != status {
			t.Fatalf("Hub %s %d want %d %s", action, r.Status, status, r.Body)
		}
		t.Logf("actual Hub %s status=%d", action, r.Status)
		return r.Body
	}
	rsaKey, err := rsaKeyForTest()
	if err != nil {
		t.Fatal(err)
	}
	signer := auth.NewSigner(rsaKey, "synthetic", "synthetic-old-abort")
	verifier := auth.NewVerifier(&rsaKey.PublicKey, "synthetic-old-abort")
	token, err := signer.Sign(account, "old-api", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	service := migration.NewService(store, peer, key.Scope)
	router := NewRouter(Deps{Verifier: verifier, APIAudience: "old-api", Migration: NewMigrationControl(service)})
	oldControl := func(action string, c migration.TransitionCommand, status int) migration.Receipt {
		t.Helper()
		raw, _ := json.Marshal(map[string]any{"command": c, "owner_consent": true})
		req := httptest.NewRequest("POST", "/migration/transitions/"+c.Key.TransitionID+"/"+action, bytes.NewReader(raw))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)
		if w.Code != status {
			t.Fatalf("old %s %d want %d %s", action, w.Code, status, w.Body.String())
		}
		var r migration.Receipt
		if status == 200 && json.Unmarshal(w.Body.Bytes(), &r) != nil {
			t.Fatal("invalid old receipt")
		}
		t.Logf("actual old JWT %s status=%d", action, w.Code)
		return r
	}
	hubControl("prepare", 200)
	if _, err = peer.Status(ctx, key); err == nil {
		t.Fatal("prebaseline Hub proof available")
	}
	freeze := migration.TransitionCommand{Key: key}
	if err = pool.QueryRow(ctx, `SELECT gen_random_uuid()::text`).Scan(&freeze.OperationID); err != nil {
		t.Fatal(err)
	}
	freeze.RequestHash = migration.FreezeRequestHash(freeze)
	frozen := oldControl("freeze", freeze, 200)
	hubControl("ready", 409)
	baseline, err := peer.Status(ctx, key)
	if err != nil || baseline.State != "PREPARED" || baseline.ServerSnapshotDigest != frozen.Digest {
		t.Fatalf("durable actual baseline %+v %v", baseline, err)
	}
	hubControl("abort", 200)
	hubControl("abort-completion", 503) // Old is still FROZEN; advanced proof unavailable.
	aborted, err := peer.Status(ctx, key)
	if err != nil || aborted.State != "ABORTED" {
		t.Fatal(aborted, err)
	}
	unfreeze := freeze
	unfreeze.Digest = aborted.Digest
	if err = pool.QueryRow(ctx, `SELECT gen_random_uuid()::text`).Scan(&unfreeze.OperationID); err != nil {
		t.Fatal(err)
	}
	unfreeze.RequestHash = migration.DecisionRequestHash("unfreeze", unfreeze)
	recovered := oldControl("unfreeze", unfreeze, 200)
	if recovered.State != "OLD_ACTIVE" || recovered.Key.Epoch != key.Epoch+1 {
		t.Fatal(recovered)
	}
	completion := hubControl("abort-completion", 200)
	var proof struct {
		OldActiveEpoch uint64 `json:"old_active_epoch"`
	}
	if json.Unmarshal(completion, &proof) != nil || proof.OldActiveEpoch != recovered.Key.Epoch {
		t.Fatal("completion epoch differs")
	}
	hubControl("recovery-writes", 200)
	freshBody := hubControl("fresh-prepare", 200)
	var fresh struct {
		Key migration.TransitionKey `json:"key"`
	}
	if json.Unmarshal(freshBody, &fresh) != nil || fresh.Key.Epoch != 3 {
		t.Fatal("fresh transition not higher epoch")
	}
	later := freeze
	later.Key = fresh.Key
	if err = pool.QueryRow(ctx, `SELECT gen_random_uuid()::text`).Scan(&later.OperationID); err != nil {
		t.Fatal(err)
	}
	later.RequestHash = migration.FreezeRequestHash(later)
	oldControl("freeze", later, 200)
	if _, err = store.Status(ctx, recovered.Key); err == nil {
		t.Fatal("later FROZEN serves historical recovery proof")
	}
	oldControl("freeze", freeze, 200)
	oldControl("unfreeze", unfreeze, 200) // History, without gate reset.
	surrender := unfreeze
	if err = pool.QueryRow(ctx, `SELECT gen_random_uuid()::text`).Scan(&surrender.OperationID); err != nil {
		t.Fatal(err)
	}
	surrender.RequestHash = migration.DecisionRequestHash("surrender", surrender)
	oldControl("surrender", surrender, 503)
	state, epoch := "", uint64(0)
	if err = pool.QueryRow(ctx, `SELECT state,epoch FROM account_writer_authority WHERE account_id=$1::uuid`, account).Scan(&state, &epoch); err != nil || state != "FROZEN" || epoch != 3 {
		t.Fatalf("delayed controls changed current gate %s/%d %v", state, epoch, err)
	}
	t.Log("real two-PG prepare -> Freeze -> blocked Ready -> Abort -> JWT Unfreeze -> independently authenticated completion -> writes -> fresh epoch confirmed")
}
