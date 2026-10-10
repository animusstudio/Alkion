package api

import (
	"bufio"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"workout-tracker/server/internal/auth"
	"workout-tracker/server/internal/db"
	"workout-tracker/server/internal/migration"
)

// handoverArm is one TEST-ONLY injected fault, armed over stdin by the Hub's
// migrationacceptance orchestrator. No HTTP route can arm or trigger it.
type handoverArm struct {
	Kind   string `json:"kind"` // crash-after-commit, drop-peer
	Path   string `json:"path"`
	Method string `json:"method"`
	// Count > 1 keeps the arm for that many matching requests (a dropped
	// peer response is otherwise retried by the client transport).
	Count int `json:"count"`
}
type handoverFaults struct {
	mu   sync.Mutex
	arms []handoverArm
}

func (f *handoverFaults) take(r *http.Request, kind string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i, a := range f.arms {
		if a.Kind == kind && strings.Contains(r.URL.Path, a.Path) && (a.Method == "" || a.Method == r.Method) {
			if a.Count > 1 {
				f.arms[i].Count--
				return true
			}
			f.arms = append(f.arms[:i], f.arms[i+1:]...)
			return true
		}
	}
	return false
}

// discardResponse buffers a response that a simulated crash never sends. It
// unwraps to the real writer so the upload's read deadline still applies.
type discardResponse struct {
	http.ResponseWriter
	header http.Header
	status int
}

func (d *discardResponse) Header() http.Header         { return d.header }
func (d *discardResponse) Write(b []byte) (int, error) { return len(b), nil }
func (d *discardResponse) WriteHeader(status int)      { d.status = status }
func (d *discardResponse) Unwrap() http.ResponseWriter { return d.ResponseWriter }

// TestHandoverRepsProcess is the old-backend half of the Hub's two-backend
// handover acceptance harness (apps/api/internal/migrationacceptance). It
// serves the production router (JWT, /sync/upload, owner migration
// controls) over HTTP and the production mTLS peer handler and client, on
// the disposable TEST_DATABASE_URL. The only TEST-ONLY seams are the stdin
// frames: synthetic accounts/tokens and injected faults (a crash after the
// handler commits, before any response byte; a dropped peer response).
func TestHandoverRepsProcess(t *testing.T) {
	if os.Getenv("PDH_HANDOVER_REPS_PROCESS") != "1" {
		t.Skip("two-backend handover fixture subprocess only")
	}
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Fatal("TEST_DATABASE_URL required")
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
	scan := bufio.NewScanner(os.Stdin)
	scan.Buffer(make([]byte, 4096), 8<<20)
	read := func(v any) {
		t.Helper()
		if !scan.Scan() || json.Unmarshal(scan.Bytes(), v) != nil {
			t.Fatal("invalid handover frame")
		}
	}
	var boot struct {
		Account string `json:"account"`
		RSAKey  []byte `json:"rsa_key"`
	}
	read(&boot)
	block, _ := pem.Decode(boot.RSAKey)
	if block == nil {
		t.Fatal("synthetic signing key")
	}
	rsaKey, err := x509.ParsePKCS1PrivateKey(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	newAccount := func() (string, error) {
		var id string
		err := pool.QueryRow(ctx, `INSERT INTO users(email,password_hash) VALUES('handover-'||gen_random_uuid()::text||'@example.invalid','synthetic') RETURNING id::text`).Scan(&id)
		return id, err
	}
	if boot.Account == "" {
		if boot.Account, err = newAccount(); err != nil {
			t.Fatal(err)
		}
	}
	var instance string
	if err = pool.QueryRow(ctx, `SELECT instance_id::text FROM legacy_server_instance WHERE singleton`).Scan(&instance); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(map[string]string{"account": boot.Account, "instance": instance})
	fmt.Println("HANDOVER_ACCOUNT=" + string(raw))

	var cfg struct {
		Scope             migration.ScopeBinding `json:"scope"`
		PublicAddr        string                 `json:"public_addr"`
		PeerAddr          string                 `json:"peer_addr"`
		PeerCertificate   []byte                 `json:"peer_certificate"`
		PeerKey           []byte                 `json:"peer_key"`
		PeerClientCA      []byte                 `json:"peer_client_ca"`
		HubClientPin      string                 `json:"hub_client_pin"`
		ClientCertificate []byte                 `json:"client_certificate"`
		ClientKey         []byte                 `json:"client_key"`
		HubServerCA       []byte                 `json:"hub_server_ca"`
		HubPin            string                 `json:"hub_pin"`
		HubPeerURL        string                 `json:"hub_peer_url"`
	}
	read(&cfg)
	cert, err := tls.X509KeyPair(cfg.PeerCertificate, cfg.PeerKey)
	if err != nil {
		t.Fatal(err)
	}
	clientCert, err := tls.X509KeyPair(cfg.ClientCertificate, cfg.ClientKey)
	if err != nil {
		t.Fatal(err)
	}
	clientRoots, serverRoots := x509.NewCertPool(), x509.NewCertPool()
	if !clientRoots.AppendCertsFromPEM(cfg.PeerClientCA) || !serverRoots.AppendCertsFromPEM(cfg.HubServerCA) {
		t.Fatal("synthetic roots")
	}
	store := migration.NewStore(pool)
	peerHandler, err := migration.NewHandler(migration.Policy{Scope: cfg.Scope, PeerInstanceID: cfg.Scope.HubInstanceID, CertificateSHA256: cfg.HubClientPin}, store)
	if err != nil {
		t.Fatal(err)
	}
	hubPeer, err := migration.NewClient(migration.ClientConfig{URL: cfg.HubPeerURL, Scope: cfg.Scope, PeerInstanceID: cfg.Scope.HubInstanceID, CertificateSHA256: cfg.HubPin, Roots: serverRoots, Certificate: clientCert})
	if err != nil {
		t.Fatal(err)
	}
	signer := auth.NewSigner(rsaKey, "synthetic-handover", "synthetic-old-handover")
	verifier := auth.NewVerifier(&rsaKey.PublicKey, "synthetic-old-handover")
	router := NewRouter(Deps{Pinger: pool, Auth: NewAuthHandler(AuthConfig{}), Verifier: verifier, APIAudience: "old-api", Upload: NewUploadHandler(pool), Migration: NewMigrationControl(migration.NewService(store, hubPeer, cfg.Scope))})
	faults := &handoverFaults{}
	public := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if faults.take(r, "crash-after-commit") {
			d := &discardResponse{ResponseWriter: w, header: http.Header{}, status: 200}
			router.ServeHTTP(d, r)
			fmt.Printf("HANDOVER_CRASH=after-commit:%d\n", d.status)
			os.Exit(86)
		}
		router.ServeHTTP(w, r)
	})
	peer := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if faults.take(r, "drop-peer") {
			if hj, ok := w.(http.Hijacker); ok {
				if conn, _, err := hj.Hijack(); err == nil {
					_ = conn.Close()
					fmt.Println("HANDOVER_DROPPED=peer")
					return
				}
			}
		}
		peerHandler.ServeHTTP(w, r)
	})
	peerListener, err := net.Listen("tcp", cfg.PeerAddr)
	if err != nil {
		t.Fatal(err)
	}
	peerServer := &http.Server{Handler: peer, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		_ = peerServer.Serve(tls.NewListener(peerListener, &tls.Config{Certificates: []tls.Certificate{cert}, ClientCAs: clientRoots, ClientAuth: tls.RequireAndVerifyClientCert, MinVersion: tls.VersionTLS13}))
	}()
	defer peerServer.Close()
	publicListener, err := net.Listen("tcp", cfg.PublicAddr)
	if err != nil {
		t.Fatal(err)
	}
	// The production server's whole-request read timeout bounds held bodies.
	publicServer := &http.Server{Handler: public, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second, WriteTimeout: 30 * time.Second}
	go func() { _ = publicServer.Serve(publicListener) }()
	defer publicServer.Close()
	fmt.Println("HANDOVER_READY=reps")

	reply := func(v any, err error) {
		out := map[string]any{"ok": err == nil, "value": v}
		if err != nil {
			out["error"] = err.Error()
		}
		raw, _ := json.Marshal(out)
		fmt.Println("HANDOVER_REPLY=" + string(raw))
	}
	for scan.Scan() {
		var frame struct {
			Action  string      `json:"action"`
			Account string      `json:"account"`
			Arm     handoverArm `json:"arm"`
		}
		if json.Unmarshal(scan.Bytes(), &frame) != nil {
			t.Fatal("invalid handover frame")
		}
		switch frame.Action {
		case "token":
			token, err := signer.Sign(frame.Account, "old-api", time.Hour)
			reply(token, err)
		case "account":
			id, err := newAccount()
			reply(id, err)
		case "arm":
			faults.mu.Lock()
			faults.arms = append(faults.arms, frame.Arm)
			faults.mu.Unlock()
			reply(frame.Arm.Kind, nil)
		case "disarm":
			faults.mu.Lock()
			faults.arms = nil
			faults.mu.Unlock()
			reply("disarmed", nil)
		case "quit":
			reply("quit", nil)
			return
		default:
			reply(nil, errors.New("unknown handover frame"))
		}
	}
}
