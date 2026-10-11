package migration

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func certPEM(c tls.Certificate) []byte {
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: c.Certificate[0]})
}
func keyPEM(t *testing.T, c tls.Certificate) []byte {
	t.Helper()
	b, err := x509.MarshalECPrivateKey(c.PrivateKey.(*ecdsa.PrivateKey))
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: b})
}
func caPEM(c *x509.Certificate) []byte {
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: c.Raw})
}

// Real PostgreSQL on both sides and each repository's actual HTTP handler.
// The Hub fixture is explicitly synthetic READY/ABORTED and proves transport
// decisions only; it cannot certify migration eligibility or activation.
func TestPeerTwoPostgresActualHandlers(t *testing.T) {
	hubCheckout := os.Getenv("PDH_PEER_TEST_HUB_CHECKOUT")
	hubDSN := os.Getenv("HUB_TEST_DATABASE_URL")
	if hubCheckout == "" || hubDSN == "" {
		t.Skip("set PDH_PEER_TEST_HUB_CHECKOUT and HUB_TEST_DATABASE_URL for two-repository integration")
	}
	pool, user, freeze := testAccount(t)
	store := NewStore(pool)
	ctx := OwnerConsentContext(context.Background(), user, true)
	f, err := NewService(store, nil, freeze.Key.Scope).Freeze(ctx, freeze)
	if err != nil {
		t.Fatal(err)
	}
	hubPool, err := pgxpool.New(ctx, hubDSN)
	if err != nil {
		t.Fatal(err)
	}
	defer hubPool.Close()
	schema := "synthetic_peer_" + strings.ReplaceAll(freeze.Key.TransitionID, "-", "")
	if _, err = hubPool.Exec(ctx, "CREATE SCHEMA "+schema); err != nil {
		t.Fatal(err)
	}
	defer hubPool.Exec(context.Background(), "DROP SCHEMA "+schema+" CASCADE")
	if _, err = hubPool.Exec(ctx, "CREATE TABLE "+schema+".status(transition_id uuid PRIMARY KEY,receipt jsonb NOT NULL)"); err != nil {
		t.Fatal(err)
	}
	synthetic := Receipt{Key: freeze.Key, State: "READY", Digest: strings.Repeat("f", 64), ServerSnapshotDigest: f.Digest, OperationID: freeze.OperationID, RequestHash: strings.Repeat("c", 64), DecisionSequence: 1}
	b, _ := json.Marshal(synthetic)
	if _, err = hubPool.Exec(ctx, "INSERT INTO "+schema+".status VALUES($1::uuid,$2::jsonb)", freeze.Key.TransitionID, b); err != nil {
		t.Fatal(err)
	}
	// Independent server and client roots, generated solely in process memory.
	_, hca, hcak := testCert(t, nil, nil, true)
	hubServer, _, _ := testCert(t, hca, hcak, true)
	_, occa, occak := testCert(t, nil, nil, false)
	oldClient, _, _ := testCert(t, occa, occak, false)
	_, oca, ocak := testCert(t, nil, nil, true)
	oldServer, _, _ := testCert(t, oca, ocak, true)
	_, hcca, hccak := testCert(t, nil, nil, false)
	hubClient, _, _ := testCert(t, hcca, hccak, false)
	roots := x509.NewCertPool()
	roots.AddCert(hcca)
	oldHandler, err := NewHandler(Policy{Scope: freeze.Key.Scope, PeerInstanceID: freeze.Key.Scope.HubInstanceID, CertificateSHA256: pin(hubClient)}, store)
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewUnstartedServer(oldHandler)
	ts.TLS = &tls.Config{Certificates: []tls.Certificate{oldServer}, ClientCAs: roots, ClientAuth: tls.RequireAndVerifyClientCert, MinVersion: tls.VersionTLS13}
	ts.StartTLS()
	defer ts.Close()
	procCtx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	binary := filepath.Join(t.TempDir(), "synthetic-hub-peer.test")
	build := exec.CommandContext(procCtx, "go", "test", "-c", "./apps/api/internal/migrationpeer", "-o", binary)
	build.Dir = hubCheckout
	build.Env = append(os.Environ(), "GOCACHE=/tmp/pdh-lineage-go-cache")
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build synthetic Hub fixture: %s %v", output, err)
	}
	cmd := exec.CommandContext(procCtx, binary, "-test.run=^TestSyntheticHubPeerProcess$", "-test.v")
	cmd.Dir = hubCheckout
	cmd.Env = append(os.Environ(), "PDH_SYNTHETIC_PEER_PROCESS=1", "GOCACHE=/tmp/pdh-lineage-go-cache")
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
		if err := cmd.Wait(); err != nil {
			t.Errorf("synthetic Hub fixture process: %v", err)
		}
	}()
	cfg := struct {
		Scope                                  ScopeBinding
		Certificate, PrivateKey, ClientCA      []byte
		ClientPin, Table, RepsURL, RepsPin     string
		ServerCA, ClientCertificate, ClientKey []byte
	}{freeze.Key.Scope, certPEM(hubServer), keyPEM(t, hubServer), caPEM(occa), pin(oldClient), schema + ".status", ts.URL, pin(oldServer), caPEM(oca), certPEM(hubClient), keyPEM(t, hubClient)}
	if err = json.NewEncoder(in).Encode(cfg); err != nil {
		t.Fatal(err)
	}
	scan := bufio.NewScanner(out)
	var hubURL string
	for scan.Scan() {
		line := scan.Text()
		t.Log(line)
		if strings.HasPrefix(line, "PEER_URL=") {
			hubURL = strings.TrimPrefix(line, "PEER_URL=")
			break
		}
	}
	if hubURL == "" {
		t.Fatal("synthetic Hub fixture failed to start")
	}
	hubRoots := x509.NewCertPool()
	hubRoots.AddCert(hca)
	peer, err := NewClient(ClientConfig{URL: hubURL, Scope: freeze.Key.Scope, PeerInstanceID: freeze.Key.Scope.HubInstanceID, CertificateSHA256: pin(hubServer), Roots: hubRoots, Certificate: oldClient})
	if err != nil {
		t.Fatal(err)
	}
	ready, err := peer.Status(ctx, freeze.Key)
	if err != nil || ready != synthetic {
		t.Fatalf("old → synthetic Hub READY: %+v %v", ready, err)
	}
	// Hub's actual client independently reads Reps's actual PostgreSQL status handler.
	check := func(expected string) {
		t.Helper()
		if err = json.NewEncoder(in).Encode(struct {
			Key      TransitionKey
			Expected string
		}{freeze.Key, expected}); err != nil {
			t.Fatal(err)
		}
		for scan.Scan() {
			line := scan.Text()
			if strings.HasPrefix(line, "PEER_CHECK=") {
				if line != "PEER_CHECK="+expected {
					t.Fatalf("Hub → old: %s", line)
				}
				return
			}
		}
		t.Fatal("Hub peer check missing")
	}
	check(Frozen)
	// A valid-looking client digest never substitutes for an authenticated digest.
	svc := NewService(store, peer, freeze.Key.Scope)
	wrong := decisionCommand(freeze, strings.Repeat("0", 64), "surrender")
	if _, err = svc.Surrender(ctx, wrong); err == nil {
		t.Fatal("client READY digest accepted")
	}
	surrendered, err := svc.Surrender(ctx, decisionCommand(freeze, synthetic.Digest, "surrender"))
	if err != nil || surrendered.State != Retired {
		t.Fatalf("surrender: %+v %v", surrendered, err)
	}
	check(Retired)
	synthetic.State = "ABORTED"
	synthetic.DecisionSequence++
	b, _ = json.Marshal(synthetic)
	if _, err = hubPool.Exec(ctx, "UPDATE "+schema+".status SET receipt=$2::jsonb WHERE transition_id=$1::uuid", freeze.Key.TransitionID, b); err != nil {
		t.Fatal(err)
	}
	aborted, err := peer.Status(ctx, freeze.Key)
	if err != nil || aborted.State != "ABORTED" {
		t.Fatalf("old → synthetic Hub ABORTED: %v", err)
	}
	if _, err = svc.Unfreeze(ctx, decisionCommand(freeze, synthetic.Digest, "unfreeze")); err == nil {
		t.Fatal("delayed authenticated abort reopened RETIRED")
	}
	check(Retired)
	// Ordinary restore/SQL gate reset is rejected by the forward migration guard.
	if _, err = pool.Exec(ctx, `UPDATE account_writer_authority SET state='OLD_ACTIVE',transition_id=NULL,hub_instance_id=NULL,hub_space_id=NULL,hub_source_id=NULL WHERE account_id=$1::uuid`, user); err == nil {
		t.Fatal("ordinary gate reset reopened RETIRED")
	}
	fmt.Fprint(in, "\n")
}
