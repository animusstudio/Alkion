// Package main is the workout-tracker HTTP server entrypoint.
package main

import (
	"context"
	"flag"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"workout-tracker/server/internal/api"
	"workout-tracker/server/internal/auth"
	"workout-tracker/server/internal/config"
	"workout-tracker/server/internal/db"
	"workout-tracker/server/internal/migration"
)

func main() {
	healthFlag := flag.Bool("healthcheck", false, "probe /healthz on the local HTTP_ADDR and exit 0 (healthy) or 1")
	flag.Parse()
	if *healthFlag {
		addr := os.Getenv("HTTP_ADDR")
		if addr == "" {
			addr = ":8080"
		}
		// Normalize "0.0.0.0:8080" / "host:8080" to ":8080" for the localhost probe.
		if _, port, err := net.SplitHostPort(addr); err == nil {
			addr = ":" + port
		}
		if err := healthcheck("http://localhost" + addr); err != nil {
			os.Exit(1)
		}
		os.Exit(0)
	}

	cfg, err := config.Load()
	if err != nil {
		slog.Error("config load failed", "err", err)
		os.Exit(1)
	}

	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: cfg.SlogLevel()}))
	slog.SetDefault(logger)

	priv, err := auth.LoadPrivateKeyPEM(cfg.JWTPrivateKeyPath)
	if err != nil {
		logger.Error("load signing key failed", "err", err)
		os.Exit(1)
	}
	kid := auth.ThumbprintKID(&priv.PublicKey)
	signer := auth.NewSigner(priv, kid, cfg.JWTIssuer)
	verifier := auth.NewVerifier(&priv.PublicKey, cfg.JWTIssuer)

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	pool, err := db.NewPool(ctx, cfg.DatabaseURL)
	if err != nil {
		logger.Error("db connect failed", "err", err)
		os.Exit(1)
	}
	defer pool.Close()

	// Apply embedded migrations on startup so a fresh deploy / DR-restored CT
	// self-provisions its schema (and the powersync publication + role).
	if err := db.Migrate(ctx, cfg.DatabaseURL); err != nil {
		logger.Error("migrations failed", "err", err)
		os.Exit(1)
	}
	logger.Info("migrations applied")

	var migrationControl *api.MigrationControl
	peerConfig, err := migration.LoadRuntimeConfig(os.Getenv("REPS_MIGRATION_PEER_CONFIG"))
	if err != nil {
		logger.Error("migration configuration failed")
		os.Exit(1)
	}
	if peerConfig != nil {
		store := migration.NewStore(pool)
		// Pin the configured old instance to the durable database identity at startup.
		var instance string
		if err := pool.QueryRow(ctx, `SELECT instance_id::text FROM legacy_server_instance WHERE singleton`).Scan(&instance); err != nil || instance != peerConfig.Scope.OldInstanceID {
			logger.Error("migration instance binding failed")
			os.Exit(1)
		}
		if peerConfig.IncomingPeerInstanceID != peerConfig.Scope.HubInstanceID || peerConfig.OutgoingPeerInstanceID != peerConfig.Scope.HubInstanceID {
			logger.Error("migration peer instance binding failed")
			os.Exit(1)
		}
		runtime, err := migration.StartRuntime(ctx, *peerConfig, store)
		if err != nil {
			logger.Error("migration peer startup failed")
			os.Exit(1)
		}
		defer runtime.Close()
		go func() {
			if err := <-runtime.Errors; err != nil && err != http.ErrServerClosed {
				logger.Error("migration peer listener failed")
				cancel()
			}
		}()
		migrationControl = api.NewMigrationControl(migration.NewService(store, runtime.Client, peerConfig.Scope))
	}
	uploadHandler := api.NewUploadHandler(pool)

	authHandler := api.NewAuthHandler(api.AuthConfig{
		Users:             auth.NewUserStore(pool),
		Refresh:           auth.NewRefreshStore(pool, cfg.RefreshTokenTTL),
		Signer:            signer,
		APIAudience:       cfg.APIAudience,
		PowerSyncAudience: cfg.PowerSyncAudience,
		PowerSyncURL:      cfg.PowerSyncURL,
		AccessTTL:         cfg.AccessTokenTTL,
		PowerSyncTTL:      cfg.PowerSyncTokenTTL,
	})

	srv := &http.Server{
		Addr: cfg.HTTPAddr,
		Handler: api.NewRouter(api.Deps{
			Pinger:      pool,
			JWKS:        auth.JWKSHandler(&priv.PublicKey, kid),
			Auth:        authHandler,
			Verifier:    verifier,
			APIAudience: cfg.APIAudience,
			Upload:      uploadHandler,
			Migration:   migrationControl,
		}),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       api.UploadTimeout,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	go func() {
		logger.Info("server starting", "addr", cfg.HTTPAddr, "kid", kid)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Error("server failed", "err", err)
			os.Exit(1)
		}
	}()

	<-ctx.Done()
	logger.Info("shutdown signal received")

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer shutdownCancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("graceful shutdown failed", "err", err)
	}
	logger.Info("server stopped")
}
