package main

import (
	"context"
	"crypto/subtle"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
)

// googleIssuer is the canonical Google OIDC issuer. The verifier checks the ID
// token's signature against this issuer's published JWKS.
const googleIssuer = "https://accounts.google.com"

// oidcHTTPTimeout bounds every HTTP request the OIDC machinery makes: the
// discovery fetch at startup AND the lazy JWKS fetch/refresh at verify time.
// go-oidc's shared remote keyset lives on context.Background() (it outlives the
// init context deliberately), so this per-request client timeout is the only
// thing preventing a hung Google fetch from stalling auth forever.
const oidcHTTPTimeout = 15 * time.Second

// ErrUnauthorized is returned for any authentication/authorization failure.
// Callers translate it into an HTTP 401 / WS 1008 and never bridge.
var ErrUnauthorized = errors.New("unauthorized")

// Identity is a verified, authorized caller identity.
type Identity struct {
	// Email is the verified email, lowercased, present on the allowlist.
	Email string
	// Sub is the issuer's stable subject identifier for the account (Google
	// `sub`). Unlike email it can never change or be re-assigned, so it is the
	// right long-term account key (roadmap §2.1). "dev" under DEV_AUTH.
	Sub string
}

// Authenticator verifies client (human, OIDC) and agent (device-token) auth.
// It is fail-closed: any error, missing token, or unmet condition rejects.
type Authenticator struct {
	cfg      *Config
	logger   *slog.Logger
	verifier *oidc.IDTokenVerifier // nil if GOOGLE_CLIENT_ID is unset
	allowed  map[string]bool       // lowercased allowlist

	// Device-code flow endpoints, taken from the issuer's OIDC discovery
	// document (Google publishes device_authorization_endpoint =
	// https://oauth2.googleapis.com/device/code). Deriving them from discovery
	// means tests redirect them through the same test-only IssuerURL override
	// as everything else — no separate endpoint knobs. Empty if the issuer
	// does not advertise a device flow.
	deviceAuthURL string
	tokenURL      string
	// httpClient is the bounded-timeout client shared with the OIDC provider;
	// device-code HTTP calls reuse it so every outbound request is bounded.
	httpClient *http.Client
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
		issuer := googleIssuer
		if cfg.IssuerURL != "" {
			issuer = cfg.IssuerURL // tests only; production always uses Google
		}
		// The http.Client travels with the provider into its shared JWKS keyset
		// (which go-oidc pins to context.Background()), so its Timeout bounds
		// key fetches for the whole process lifetime — not just discovery.
		httpClient := &http.Client{Timeout: oidcHTTPTimeout}
		provider, err := oidc.NewProvider(oidc.ClientContext(ctx, httpClient), issuer)
		if err != nil {
			return nil, fmt.Errorf("init google oidc provider: %w", err)
		}
		a.verifier = provider.Verifier(&oidc.Config{ClientID: cfg.GoogleClientID})
		a.httpClient = httpClient

		// Pull the device-code endpoints out of the discovery document for the
		// self-enroll flow (WP-B3). Absence is not an error: enrollment simply
		// reports itself unavailable.
		var disc struct {
			DeviceAuthorizationEndpoint string `json:"device_authorization_endpoint"`
			TokenEndpoint               string `json:"token_endpoint"`
		}
		if err := provider.Claims(&disc); err == nil {
			a.deviceAuthURL = disc.DeviceAuthorizationEndpoint
			a.tokenURL = disc.TokenEndpoint
		}
		logger.Info("OIDC client auth enabled", "issuer", issuer,
			"device_flow", a.deviceAuthURL != "" && a.tokenURL != "")
	} else {
		logger.Warn("GOOGLE_CLIENT_ID unset — OIDC client auth disabled")
	}

	return a, nil
}

// AuthenticateClient verifies a human client request and returns the caller's
// verified, authorized identity (email + Google sub). Order of checks:
//  1. (dev only) static DEV_CLIENT_TOKEN match -> DEV_EMAIL.
//  2. Full Google ID-token verification: signature/issuer/aud/exp.
//  3. email_verified == true, email and sub present.
//  4. email present in the allowlist.
//
// Presence of a token is never sufficient.
func (a *Authenticator) AuthenticateClient(ctx context.Context, r *http.Request) (Identity, error) {
	token := bearerToken(r)
	if token == "" {
		return Identity{}, ErrUnauthorized
	}

	// Dev stand-in: constant-time compare against the static dev token. This is
	// an explicit, opt-in credential and maps directly to DEV_EMAIL.
	if a.cfg.DevAuth && a.cfg.DevClientToken != "" {
		if subtle.ConstantTimeCompare([]byte(token), []byte(a.cfg.DevClientToken)) == 1 {
			return Identity{Email: strings.ToLower(a.cfg.DevEmail), Sub: "dev"}, nil
		}
		// Not the dev token — fall through to real OIDC if configured.
	}

	return a.VerifyIDToken(ctx, token)
}

// VerifyIDToken runs the full OIDC verification + allowlist authorization on a
// raw ID token and returns the verified identity. It is the single shared
// gate for both interactive client auth (AuthenticateClient) and device-code
// self-enrollment (the /v1/enroll/poll success path): signature against the
// issuer's JWKS, issuer, audience (== GOOGLE_CLIENT_ID), expiry, `sub`
// present, `email_verified`, and membership in ALLOWED_EMAILS.
func (a *Authenticator) VerifyIDToken(ctx context.Context, token string) (Identity, error) {
	if token == "" || a.verifier == nil {
		return Identity{}, ErrUnauthorized
	}

	// Verify checks signature against Google's JWKS, the issuer, the audience
	// (== GOOGLE_CLIENT_ID), and expiry.
	idToken, err := a.verifier.Verify(ctx, token)
	if err != nil {
		a.logger.Warn("client id-token verification failed", "err", err)
		return Identity{}, ErrUnauthorized
	}
	if idToken.Subject == "" {
		// `sub` is REQUIRED by the OIDC core spec; a token without one is
		// malformed. Fail closed.
		a.logger.Warn("client id-token missing sub")
		return Identity{}, ErrUnauthorized
	}

	var claims struct {
		Email         string `json:"email"`
		EmailVerified bool   `json:"email_verified"`
	}
	if err := idToken.Claims(&claims); err != nil {
		return Identity{}, ErrUnauthorized
	}
	if !claims.EmailVerified || claims.Email == "" {
		a.logger.Warn("client email not verified")
		return Identity{}, ErrUnauthorized
	}

	email := strings.ToLower(claims.Email)
	if !a.allowed[email] {
		// Authorization gate: a valid Google login by anyone not on the
		// allowlist is rejected.
		a.logger.Warn("client email not on allowlist", "email", email)
		return Identity{}, ErrUnauthorized
	}

	return Identity{Email: email, Sub: idToken.Subject}, nil
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
