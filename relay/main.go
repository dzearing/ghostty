// Command ghoztty-relay is a secure rendezvous relay for the Ghoztty
// remote-machines feature. Both the local Ghoztty client and the remote
// ghoztty-agent dial OUTBOUND over wss://:443 (TLS terminated by Caddy in
// front; this process speaks plain HTTP/WebSocket on loopback). The relay
// authenticates both ends, tracks online agents, and splices the two streams
// into a single opaque byte pipe. It never inspects the payload (SSH rides
// inside, end-to-end).
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	cfg := LoadConfig()

	if cfg.DevAuth {
		logger.Warn("DEV_AUTH enabled — not for production")
	}

	// Brokered-OAuth (BFF) readiness: the /oauth/exchange + /oauth/renew flow
	// needs SESSION_ENC_KEY (to encrypt Google refresh tokens at rest). Without
	// it those endpoints answer 503, so the macOS app can't sign in — surface
	// that loudly at startup instead of failing silently at first sign-in.
	if cfg.GoogleClientID != "" && len(cfg.SessionEncKey) != 32 {
		logger.Warn("SESSION_ENC_KEY unset or invalid — brokered OAuth (/oauth/exchange) disabled; the macOS app cannot sign in")
	} else if len(cfg.SessionEncKey) == 32 {
		logger.Info("brokered OAuth enabled (/oauth/exchange, /oauth/renew, /oauth/signout)")
	}

	// OIDC discovery happens here; give it a bounded window at startup.
	initCtx, cancelInit := context.WithTimeout(context.Background(), 30*time.Second)
	auth, err := NewAuthenticator(initCtx, cfg, logger)
	cancelInit()
	if err != nil {
		logger.Error("failed to init authenticator", "err", err)
		os.Exit(1)
	}

	store, err := LoadStore(cfg.DBPath(), cfg.DevicesPath(), logger)
	if err != nil {
		logger.Error("failed to load device store", "err", err)
		os.Exit(1)
	}
	defer store.Close()

	// Wire the account-model authorization gate. The runtime signup mode
	// (settings.go: DB settings.signup_mode, seeded from SIGNUP_MODE /
	// INVITE_SIGNUP) decides per-request whether it governs — `allowlist`
	// keeps the legacy ALLOWED_EMAILS path. The gate needs the Store, hence
	// this late bind after LoadStore. The log below is a startup SNAPSHOT
	// only; the mode is changeable live via PUT /v1/admin/settings.
	gate := NewSigninGate(cfg, store, logger)
	auth.SetGate(gate)
	mode, modeSource := gate.SignupModeWithSource()
	logger.Info("signup mode resolved", "mode", mode, "source", modeSource)
	if mode != SignupAllowlist {
		logger.Warn("account model governs sign-in (ALLOWED_EMAILS bypassed)", "mode", mode)
	}

	// Admin surface (M2): bootstrap admins come from ADMIN_SUBS; with none
	// configured, only accounts.is_admin rows grant access (fail closed —
	// neither means every /v1/admin/ request 403s).
	logger.Info("admin bootstrap allowlist", "subs", len(cfg.AdminSubs))

	dir := NewDirectory(logger)
	h := NewHandler(cfg, auth, store, dir, logger)

	mux := http.NewServeMux()
	h.Register(mux)

	// Prometheus /metrics on its own (loopback by default) listener — never on
	// the public mux. Bind failure is fatal: it is a config error (metrics.go).
	metricsSrv, err := StartMetricsServer(cfg, dir, store, logger)
	if err != nil {
		logger.Error("failed to start metrics listener", "err", err)
		os.Exit(1)
	}

	srv := &http.Server{
		Addr: cfg.ListenAddr,
		// InstrumentHTTP wraps the mux for request/error-rate counters
		// (metrics.go); it preserves Hijacker for the WebSocket routes.
		Handler: InstrumentHTTP(mux),
		// No global write/read timeouts: WebSocket bridges are long-lived.
		// Per-operation timeouts (heartbeat, session setup) bound the risky paths.
		ReadHeaderTimeout: 10 * time.Second,
	}

	// Graceful shutdown on SIGINT/SIGTERM.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		logger.Info("relay listening", "addr", cfg.ListenAddr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("server error", "err", err)
			stop()
		}
	}()

	<-ctx.Done()
	logger.Info("shutting down")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("graceful shutdown failed", "err", err)
	}
	if metricsSrv != nil {
		_ = metricsSrv.Shutdown(shutdownCtx)
	}
}
