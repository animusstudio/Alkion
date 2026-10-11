package migration

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Policy binds a leaf certificate identity to one peer instance and one scope.
// Roots are configured separately from user JWT / OIDC trust.
type Policy struct {
	Scope             ScopeBinding
	PeerInstanceID    string
	CertificateSHA256 string
}

func (p Policy) valid() bool {
	return ValidateKey(TransitionKey{Scope: p.Scope, TransitionID: p.Scope.OldAccountID, Epoch: 1}) == nil && ValidHash(p.CertificateSHA256) && (p.PeerInstanceID == p.Scope.HubInstanceID || p.PeerInstanceID == p.Scope.OldInstanceID)
}
func leafPin(c *x509.Certificate) string {
	sum := sha256.Sum256(c.Raw)
	return hex.EncodeToString(sum[:])
}

type ClientConfig struct {
	URL               string
	Scope             ScopeBinding
	PeerInstanceID    string
	CertificateSHA256 string
	Roots             *x509.CertPool
	Certificate       tls.Certificate
}
type Client struct {
	url    string
	policy Policy
	http   *http.Client
}

func NewClient(cfg ClientConfig) (*Client, error) {
	u, err := url.Parse(cfg.URL)
	p := Policy{cfg.Scope, cfg.PeerInstanceID, cfg.CertificateSHA256}
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") || !p.valid() || cfg.Roots == nil || len(cfg.Certificate.Certificate) == 0 {
		return nil, ErrInvalidPeer
	}
	tlsCfg := &tls.Config{RootCAs: cfg.Roots.Clone(), Certificates: []tls.Certificate{cfg.Certificate}, MinVersion: tls.VersionTLS13, VerifyConnection: func(cs tls.ConnectionState) error {
		if len(cs.VerifiedChains) == 0 || len(cs.PeerCertificates) == 0 || leafPin(cs.PeerCertificates[0]) != p.CertificateSHA256 {
			return ErrInvalidPeer
		}
		return nil
	}}
	return &Client{url: strings.TrimRight(cfg.URL, "/"), policy: p, http: &http.Client{Transport: &http.Transport{TLSClientConfig: tlsCfg}, Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("migration peer redirects denied") }}}, nil
}
func (c *Client) Status(ctx context.Context, k TransitionKey) (Receipt, error) {
	if ValidateKey(k) != nil || k.Scope != c.policy.Scope {
		return Receipt{}, ErrInvalidPeer
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.url+"/internal/reps-migrations/"+string(k.TransitionID)+"?epoch="+strconv.FormatUint(k.Epoch, 10), nil)
	if err != nil {
		return Receipt{}, err
	}
	res, err := c.http.Do(req)
	if err != nil {
		return Receipt{}, err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return Receipt{}, ErrInvalidPeer
	}
	payload, err := io.ReadAll(io.LimitReader(res.Body, 16*1024+1))
	if err != nil || len(payload) > 16*1024 {
		return Receipt{}, ErrInvalidPeer
	}
	r, err := DecodePeerReceipt(payload)
	if err != nil || r.Key != k {
		return Receipt{}, ErrInvalidPeer
	}
	return r, nil
}

type Handler struct {
	policy Policy
	reader PeerReader
}

func NewHandler(p Policy, reader PeerReader) (*Handler, error) {
	if !p.valid() {
		return nil, ErrInvalidPeer
	}
	return &Handler{p, reader}, nil
}
func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.TLS == nil || len(r.TLS.VerifiedChains) == 0 || len(r.TLS.PeerCertificates) == 0 || leafPin(r.TLS.PeerCertificates[0]) != h.policy.CertificateSHA256 {
		http.Error(w, "peer denied", http.StatusForbidden)
		return
	}
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		http.Error(w, "method denied", http.StatusMethodNotAllowed)
		return
	}
	prefix := "/internal/reps-migrations/"
	id := strings.TrimPrefix(r.URL.Path, prefix)
	q, err := url.ParseQuery(r.URL.RawQuery)
	epoch, parseErr := strconv.ParseUint(q.Get("epoch"), 10, 63)
	k := TransitionKey{Scope: h.policy.Scope, TransitionID: string(id), Epoch: epoch}
	if !strings.HasPrefix(r.URL.Path, prefix) || r.URL.RawPath != "" || err != nil || parseErr != nil || len(q) != 1 || len(q["epoch"]) != 1 || strconv.FormatUint(epoch, 10) != q.Get("epoch") || ValidateKey(k) != nil || r.ContentLength != 0 {
		http.Error(w, "invalid request", http.StatusBadRequest)
		return
	}
	if h.reader == nil {
		http.Error(w, "peer status unavailable", http.StatusServiceUnavailable)
		return
	}
	receipt, err := h.reader.Status(r.Context(), k)
	if err != nil || receipt.Key != k || ValidateReceipt(receipt) != nil {
		http.Error(w, "peer status unavailable", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(receipt)
}
