package migration

import (
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
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

type statusReader struct{ receipt Receipt }

func (s *statusReader) Status(context.Context, TransitionKey) (Receipt, error) {
	return s.receipt, nil
}
func testKey() TransitionKey {
	return TransitionKey{Scope: ScopeBinding{HubInstanceID: "00000000-0000-4000-8000-000000000001", OldInstanceID: "00000000-0000-4000-8000-000000000002", OldAccountID: "00000000-0000-4000-8000-000000000003", HubSpaceID: "00000000-0000-4000-8000-000000000004", HubSourceID: "00000000-0000-4000-8000-000000000005"}, TransitionID: "00000000-0000-4000-8000-000000000006", Epoch: 1}
}
func testReceipt() Receipt {
	return Receipt{Key: testKey(), State: "READY", Digest: strings.Repeat("a", 64), ServerSnapshotDigest: strings.Repeat("c", 64), OperationID: "00000000-0000-4000-8000-000000000007", RequestHash: strings.Repeat("b", 64), DecisionSequence: 1}
}
func testCert(t *testing.T, ca *x509.Certificate, cakey *ecdsa.PrivateKey, server bool) (tls.Certificate, *x509.Certificate, *ecdsa.PrivateKey) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	serial, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	cert := &x509.Certificate{SerialNumber: serial, NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature}
	parent, signer := ca, cakey
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
func pin(cert tls.Certificate) string {
	sum := sha256.Sum256(cert.Certificate[0])
	return hex.EncodeToString(sum[:])
}
func testTLS(t *testing.T) (tls.Certificate, tls.Certificate, *x509.CertPool, *x509.CertPool) {
	_, sca, sk := testCert(t, nil, nil, true)
	_, cca, ck := testCert(t, nil, nil, false)
	server, _, _ := testCert(t, sca, sk, true)
	client, _, _ := testCert(t, cca, ck, false)
	sr := x509.NewCertPool()
	sr.AddCert(sca)
	cr := x509.NewCertPool()
	cr.AddCert(cca)
	return server, client, sr, cr
}
func TestPeerPinnedScope(t *testing.T) {
	server, client, sr, cr := testTLS(t)
	key := testKey()
	reader := &statusReader{testReceipt()}
	policy := Policy{Scope: key.Scope, PeerInstanceID: key.Scope.OldInstanceID, CertificateSHA256: pin(client)}
	h, err := NewHandler(policy, reader)
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewUnstartedServer(h)
	ts.TLS = &tls.Config{Certificates: []tls.Certificate{server}, ClientAuth: tls.RequireAndVerifyClientCert, ClientCAs: cr, MinVersion: tls.VersionTLS13}
	ts.StartTLS()
	defer ts.Close()
	cfg := ClientConfig{URL: ts.URL, Scope: key.Scope, PeerInstanceID: key.Scope.HubInstanceID, CertificateSHA256: pin(server), Roots: sr, Certificate: client}
	c, err := NewClient(cfg)
	if err != nil {
		t.Fatal(err)
	}
	got, err := c.Status(context.Background(), key)
	if err != nil || got != reader.receipt {
		t.Fatalf("trusted peer: %+v %v", got, err)
	}
	for _, change := range []func(*Receipt){func(r *Receipt) { r.Key.Scope.HubInstanceID = "00000000-0000-4000-8000-000000000099" }, func(r *Receipt) { r.Key.Scope.OldAccountID = "00000000-0000-4000-8000-000000000099" }, func(r *Receipt) { r.Key.Scope.HubSpaceID = "00000000-0000-4000-8000-000000000099" }, func(r *Receipt) { r.Key.Scope.HubSourceID = "00000000-0000-4000-8000-000000000099" }, func(r *Receipt) { r.Key.TransitionID = "00000000-0000-4000-8000-000000000099" }, func(r *Receipt) { r.Key.Epoch++ }, func(r *Receipt) { r.Digest = "client-claim" }, func(r *Receipt) { r.State = "UNKNOWN" }} {
		reader.receipt = testReceipt()
		change(&reader.receipt)
		if _, err := c.Status(context.Background(), key); err == nil {
			t.Fatal("foreign/invalid receipt accepted")
		}
	}
	reader.receipt = testReceipt()
	cfg.CertificateSHA256 = strings.Repeat("0", 64)
	wrong, _ := NewClient(cfg)
	if _, err := wrong.Status(context.Background(), key); err == nil {
		t.Fatal("unpinned identity accepted")
	}
	cfg.CertificateSHA256 = pin(server)
	_, _, unknownRoots, _ := testTLS(t)
	cfg.Roots = unknownRoots
	wrong, _ = NewClient(cfg)
	if _, err := wrong.Status(context.Background(), key); err == nil {
		t.Fatal("untrusted root accepted")
	}
	cfg.Roots = sr
	alien, _, _, _ := testTLS(t)
	cfg.Certificate = alien
	wrong, _ = NewClient(cfg)
	if _, err := wrong.Status(context.Background(), key); err == nil {
		t.Fatal("untrusted client accepted")
	}
	redirect := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, ts.URL+r.URL.RequestURI(), http.StatusTemporaryRedirect)
	}))
	redirect.TLS = ts.TLS.Clone()
	redirect.StartTLS()
	defer redirect.Close()
	cfg.URL = redirect.URL
	cfg.Certificate = client
	wrong, _ = NewClient(cfg)
	if _, err := wrong.Status(context.Background(), key); err == nil {
		t.Fatal("redirect accepted")
	}
	unconfigured, _ := NewHandler(policy, nil)
	rr := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/internal/reps-migrations/"+string(key.TransitionID)+"?epoch=1", nil)
	req.TLS = &tls.ConnectionState{PeerCertificates: []*x509.Certificate{client.Leaf}, VerifiedChains: [][]*x509.Certificate{{client.Leaf}}}
	unconfigured.ServeHTTP(rr, req)
	if rr.Code != 503 {
		t.Fatalf("unconfigured=%d", rr.Code)
	}
}

func TestPeerWireFixture(t *testing.T) {
	schema, err := os.ReadFile("testdata/reps-migration-peer.schema.json")
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(schema)
	const schemaPin = "989e41423c9c4947790ba213481b905cac6b1ff94671826cf88127e5059e447e"
	if hex.EncodeToString(sum[:]) != schemaPin {
		t.Fatal("peer schema changed without explicit pin update")
	}
	var fixture struct {
		SchemaSHA256 string            `json:"schema_sha256"`
		Action       string            `json:"action"`
		Command      TransitionCommand `json:"command"`
		Receipt      Receipt           `json:"receipt"`
	}
	b, err := os.ReadFile("testdata/wire-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	if json.Unmarshal(b, &fixture) != nil || fixture.SchemaSHA256 != schemaPin || fixture.Command.RequestHash != DecisionRequestHash(fixture.Action, fixture.Command) || ValidateReceipt(fixture.Receipt) != nil {
		t.Fatal("canonical shared fixture mismatch")
	}
}

func TestPeerStrictStatusRoute(t *testing.T) {
	_, client, _, _ := testTLS(t)
	key := testKey()
	h, err := NewHandler(Policy{Scope: key.Scope, PeerInstanceID: key.Scope.OldInstanceID, CertificateSHA256: pin(client)}, &statusReader{testReceipt()})
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"/internal/reps-migrations/" + string(key.TransitionID) + "?epoch=1&epoch=1", "/internal/reps-migrations/" + string(key.TransitionID) + "?epoch=01", "/internal/reps-migrations/" + string(key.TransitionID) + "?epoch=1&digest=claim", "/internal/reps-migrations/" + strings.ToUpper(string(key.TransitionID)) + "A?epoch=1", "/internal/reps-migrations/" + string(key.TransitionID) + "/?epoch=1"} {
		req := httptest.NewRequest("GET", path, nil)
		req.TLS = &tls.ConnectionState{PeerCertificates: []*x509.Certificate{client.Leaf}, VerifiedChains: [][]*x509.Certificate{{client.Leaf}}}
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, req)
		if rr.Code == 200 {
			t.Fatalf("noncanonical request accepted: %s", path)
		}
	}
	req := httptest.NewRequest("GET", "/internal/reps-migrations/"+string(key.TransitionID)+"?epoch=1", strings.NewReader(`{"state":"READY"}`))
	req.TLS = &tls.ConnectionState{PeerCertificates: []*x509.Certificate{client.Leaf}, VerifiedChains: [][]*x509.Certificate{{client.Leaf}}}
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != 400 {
		t.Fatalf("uploaded peer receipt=%d", rr.Code)
	}
}
func TestPeerRuntimeConfigurationClosed(t *testing.T) {
	cfg, err := LoadRuntimeConfig("")
	if err != nil || cfg != nil {
		t.Fatalf("unset configuration: %+v %v", cfg, err)
	}
	if _, err := NewClient(ClientConfig{URL: "http://127.0.0.1"}); err == nil {
		t.Fatal("insecure configuration accepted")
	}
	if _, err := StartRuntime(context.Background(), RuntimeConfig{}, nil); err == nil {
		t.Fatal("unconfigured listener accepted")
	}
}

func TestPeerWireRequiresSnapshotComponent(t *testing.T) {
	for _, state := range []string{"FROZEN", "PREPARED", "READY", "ABORTED", "RETIRED", "OLD_ACTIVE", "ACTIVE", "SUSPENDED"} {
		r := testReceipt()
		r.State = state
		r.ServerSnapshotDigest = ""
		if ValidateReceipt(r) == nil {
			t.Fatalf("missing authenticated snapshot component accepted for %s", state)
		}
	}
}

func TestPeerStrictJSON(t *testing.T) {
	server, client, sr, cr := testTLS(t)
	receipt := testReceipt()
	wire, _ := json.Marshal(receipt)
	for _, bad := range [][]byte{bytes.Replace(wire, []byte(`"state":`), []byte(`"STATE":`), 1), bytes.Replace(wire, []byte(`"state":"READY"`), []byte(`"state":"ABORTED","state":"READY"`), 1)} {
		ts := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(bad)
		}))
		ts.TLS = &tls.Config{Certificates: []tls.Certificate{server}, ClientAuth: tls.RequireAndVerifyClientCert, ClientCAs: cr, MinVersion: tls.VersionTLS13}
		ts.StartTLS()
		peer, err := NewClient(ClientConfig{URL: ts.URL, Scope: receipt.Key.Scope, PeerInstanceID: receipt.Key.Scope.HubInstanceID, CertificateSHA256: pin(server), Roots: sr, Certificate: client})
		if err != nil {
			t.Fatal(err)
		}
		_, err = peer.Status(context.Background(), receipt.Key)
		ts.Close()
		if err == nil {
			t.Fatal("duplicate/case-aliased peer JSON accepted")
		}
	}
}
