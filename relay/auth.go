package main

import (
	"context"
	"crypto/subtle"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"

	"github.com/coreos/go-oidc/v3/oidc"
)

// googleIssuer is the canonical Google OIDC issuer. The verifier checks the ID
// token's signature against this issuer's published JWKS.
const googleIssuer = "https://accounts.google.com"

// ErrUnauthorized is returned for any authentication/authorization failure.
// Callers translate it into an HTTP 401 / WS 1008 and never bridge.
var ErrUnauthorized = errors.New("unauthorized")

// Authenticator verifies client (human, OIDC) and agent (device-token) auth.
// It is fail-closed: any error, missing token, or unmet condition rejects.
type Authenticator struct {
	cfg      *Config
	logger   *slog.Logger
	verifier *oidc.IDTokenVerifier // nil if GOOGLE_CLIENT_ID is unset
	allowed  map[string]bool       // lowercased allowlist
}

// NewAuthenticator builds the authenticator. When GOOGLE_CLIENT_ID is set it
// fetches Google's OIDC discovery document (and thus JWKS) up front. When it is
// unset, real OIDC client auth is unavailable and only DEV_AUTH (if enabled)
// can authenticate clients.
func NewAuthenticator(ctx context.Context, cfg *Config, logger *slog.Logger) (*Authenticator, error) {
	a := &Authenticator{
		cfg:     cfg,
		logger:  logger,
		allowed: make(map[string]bool, len(cfg.AllowedEmails)),
	}
	for _, e := range cfg.AllowedEmails {
		a.allowed[strings.ToLower(e)] = true
	}

	if cfg.GoogleClientID != "" {
		provider, err := oidc.NewProvider(ctx, googleIssuer)
		if err != nil {
			return nil, fmt.Errorf("init google oidc provider: %w", err)
		}
		a.verifier = provider.Verifier(&oidc.Config{ClientID: cfg.GoogleClientID})
		logger.Info("OIDC client auth enabled", "issuer", googleIssuer)
	} else {
		logger.Warn("GOOGLE_CLIENT_ID unset — OIDC client auth disabled")
	}

	return a, nil
}

// AuthenticateClient verifies a human client request and returns the caller's
// verified, authorized email. Order of checks:
//  1. (dev only) static DEV_CLIENT_TOKEN match -> DEV_EMAIL.
//  2. Full Google ID-token verification: signature/issuer/aud/exp.
//  3. email_verified == true.
//  4. email present in the allowlist.
//
// Presence of a token is never sufficient.
func (a *Authenticator) AuthenticateClient(ctx context.Context, r *http.Request) (string, error) {
	token := bearerToken(r)
	if token == "" {
		return "", ErrUnauthorized
	}

	// Dev stand-in: constant-time compare against the static dev token. This is
	// an explicit, opt-in credential and maps directly to DEV_EMAIL.
	if a.cfg.DevAuth && a.cfg.DevClientToken != "" {
		if subtle.ConstantTimeCompare([]byte(token), []byte(a.cfg.DevClientToken)) == 1 {
			return strings.ToLower(a.cfg.DevEmail), nil
		}
		// Not the dev token — fall through to real OIDC if configured.
	}

	if a.verifier == nil {
		return "", ErrUnauthorized
	}

	// Verify checks signature against Google's JWKS, the issuer, the audience
	// (== GOOGLE_CLIENT_ID), and expiry.
	idToken, err := a.verifier.Verify(ctx, token)
	if err != nil {
		a.logger.Warn("client id-token verification failed", "err", err)
		return "", ErrUnauthorized
	}

	var claims struct {
		Email         string `json:"email"`
		EmailVerified bool   `json:"email_verified"`
	}
	if err := idToken.Claims(&claims); err != nil {
		return "", ErrUnauthorized
	}
	if !claims.EmailVerified || claims.Email == "" {
		a.logger.Warn("client email not verified")
		return "", ErrUnauthorized
	}

	email := strings.ToLower(claims.Email)
	if !a.allowed[email] {
		// Authorization gate: a valid Google login by anyone not on the
		// allowlist is rejected.
		a.logger.Warn("client email not on allowlist", "email", email)
		return "", ErrUnauthorized
	}

	return email, nil
}

// AuthenticateDevice verifies an agent request via its device token and returns
// the matching Device. Constant-time comparison happens inside the store.
func (a *Authenticator) AuthenticateDevice(r *http.Request, store *Store) (*Device, error) {
	token := bearerToken(r)
	if token == "" {
		return nil, ErrUnauthorized
	}
	dev := store.AuthenticateToken(token)
	if dev == nil {
		return nil, ErrUnauthorized
	}
	return dev, nil
}

// bearerToken extracts a bearer token from the Authorization header, or "".
func bearerToken(r *http.Request) string {
	h := r.Header.Get("Authorization")
	const prefix = "Bearer "
	if len(h) > len(prefix) && strings.EqualFold(h[:len(prefix)], prefix) {
		return strings.TrimSpace(h[len(prefix):])
	}
	return ""
}
