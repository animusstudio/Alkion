package migration

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"time"
)

// RuntimeConfig is an explicit operator-supplied control-plane configuration.
// Empty env configuration registers neither a peer listener nor owner controls.
type RuntimeConfig struct {
	ListenAddress             string       `json:"listen_address"`
	Scope                     ScopeBinding `json:"scope"`
	IncomingPeerInstanceID    string       `json:"incoming_peer_instance_id"`
	IncomingCertificateSHA256 string       `json:"incoming_certificate_sha256"`
	IncomingClientCAFile      string       `json:"incoming_client_ca_file"`
	ServerCertificateFile     string       `json:"server_certificate_file"`
	ServerKeyFile             string       `json:"server_key_file"`
	OutgoingURL               string       `json:"outgoing_url"`
	OutgoingPeerInstanceID    string       `json:"outgoing_peer_instance_id"`
	OutgoingCertificateSHA256 string       `json:"outgoing_certificate_sha256"`
	OutgoingServerCAFile      string       `json:"outgoing_server_ca_file"`
	ClientCertificateFile     string       `json:"client_certificate_file"`
	ClientKeyFile             string       `json:"client_key_file"`
}

func LoadRuntimeConfig(path string) (*RuntimeConfig, error) {
	if path == "" {
		return nil, nil
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	dec := json.NewDecoder(io.LimitReader(f, 64*1024+1))
	dec.DisallowUnknownFields()
	var cfg RuntimeConfig
	if dec.Decode(&cfg) != nil || dec.Decode(new(any)) != io.EOF {
		return nil, errors.New("invalid migration peer configuration")
	}
	return &cfg, nil
}

type Runtime struct {
	Client *Client
	server *http.Server
	Errors <-chan error
}

func (r *Runtime) Close() error { return r.server.Close() }
func readRoots(path string) (*x509.CertPool, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(b) {
		return nil, errors.New("invalid migration peer trust roots")
	}
	return pool, nil
}

// StartRuntime binds the dedicated mTLS listener before returning. Reader must be
// a real scope-bound authority reader. A nil Hub reader always answers 503.
func StartRuntime(ctx context.Context, cfg RuntimeConfig, reader PeerReader) (*Runtime, error) {
	incoming := Policy{cfg.Scope, cfg.IncomingPeerInstanceID, cfg.IncomingCertificateSHA256}
	if !incoming.valid() || cfg.IncomingPeerInstanceID != cfg.OutgoingPeerInstanceID || cfg.ListenAddress == "" {
		return nil, ErrInvalidPeer
	}
	incomingRoots, err := readRoots(cfg.IncomingClientCAFile)
	if err != nil {
		return nil, err
	}
	outgoingRoots, err := readRoots(cfg.OutgoingServerCAFile)
	if err != nil {
		return nil, err
	}
	serverCert, err := tls.LoadX509KeyPair(cfg.ServerCertificateFile, cfg.ServerKeyFile)
	if err != nil {
		return nil, err
	}
	clientCert, err := tls.LoadX509KeyPair(cfg.ClientCertificateFile, cfg.ClientKeyFile)
	if err != nil {
		return nil, err
	}
	client, err := NewClient(ClientConfig{URL: cfg.OutgoingURL, Scope: cfg.Scope, PeerInstanceID: cfg.OutgoingPeerInstanceID, CertificateSHA256: cfg.OutgoingCertificateSHA256, Roots: outgoingRoots, Certificate: clientCert})
	if err != nil {
		return nil, err
	}
	handler, err := NewHandler(incoming, reader)
	if err != nil {
		return nil, err
	}
	listener, err := net.Listen("tcp", cfg.ListenAddress)
	if err != nil {
		return nil, err
	}
	server := NewServer(handler, serverCert, incomingRoots)
	done := make(chan error, 1)
	go func() { done <- server.Serve(tls.NewListener(listener, server.TLSConfig)) }()
	go func() { <-ctx.Done(); _ = server.Close() }()
	return &Runtime{Client: client, server: server, Errors: done}, nil
}

// NewServer is the peer listener's server: production timeouts and size
// limits, TLS 1.3 and a required verified client chain (the handler then
// pins the client leaf). Serve it on tls.NewListener(l, server.TLSConfig).
func NewServer(handler http.Handler, certificate tls.Certificate, clientRoots *x509.CertPool) *http.Server {
	return &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16 * 1024, TLSConfig: &tls.Config{Certificates: []tls.Certificate{certificate}, ClientCAs: clientRoots, ClientAuth: tls.RequireAndVerifyClientCert, MinVersion: tls.VersionTLS13}}
}
