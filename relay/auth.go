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

	// envAllowed is the ALLOWED_EMAILS env allowlist (lowercased). Since the
	// DB-backed allowlist (allowlist.go, migration 0006) it is the BOOTSTRAP/
	// RECOVERY half of the effective allowlist: always honored, never written
	// to the DB — same pattern as ADMIN_SUBS. Day-to-day entries live in the
	// allowed_emails table, managed from the portal. See emailAllowed.
	envAllowed map[string]bool

	// gate is the invite-code authorization layer, consulted only when
	// Config.InviteSignup is ON. It is wired after the Store exists (SetGate),
	// so it is nil during construction; the OFF path never touches it. It needs
	// the Store, which the Authenticator is built before, hence the late bind.
	gate *SigninGate

	// limits is the M4 rate-limiter set (ratelimit.go); only the failed
	// sign-in limiter is consulted here. Late-bound by NewHandler
	// (SetRateLimits, mirroring SetGate); nil-safe when never bound.
	limits *RateLimiters

	// allowedAuds is the `aud` allowlist for ID tokens: GOOGLE_CLIENT_ID (the
	// Desktop client the Mac app signs in with) plus GOOGLE_DEVICE_CLIENT_ID
	// (the TV/limited-input client the device-code enroll flow uses) plus
	// GOOGLE_WEB_CLIENT_ID (the Web client the browser enroll callback uses),
	// each when set.
	// go-oidc's verifier only checks a single ClientID, so the verifier is
	// built with SkipClientIDCheck and VerifyIDToken enforces membership in
	// this list explicitly — one verifier, one signature check, and a
	// fail-closed aud gate that rejects when the list is empty or no audience
	// matches. (The two-verifier alternative would double signature/JWKS work
	// and make "which verifier's error do we trust?" ambiguous.)
	allowedAuds []string

	// OAuth flow endpoints, taken from the issuer's OIDC discovery document
	// (Google publishes device_authorization_endpoint =
	// https://oauth2.googleapis.com/device/code, authorization_endpoint =
	// https://accounts.google.com/o/oauth2/v2/auth). Deriving them from
	// discovery means tests redirect them through the same test-only IssuerURL
	// override as everything else — no separate endpoint knobs. Empty if the
	// issuer does not advertise the flow.
	deviceAuthURL string
	authURL       string
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
		cfg:        cfg,
		logger:     logger,
		envAllowed: make(map[string]bool, len(cfg.AllowedEmails)),
	}
	for _, e := range cfg.AllowedEmails {
		a.envAllowed[strings.ToLower(e)] = true
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
		// SkipClientIDCheck because we accept up to TWO audiences (see the
		// allowedAuds field doc); the explicit aud gate lives in VerifyIDToken
		// and fails closed.
		a.verifier = provider.Verifier(&oidc.Config{SkipClientIDCheck: true})
		a.allowedAuds = []string{cfg.GoogleClientID}
		for _, aud := range []string{cfg.GoogleDeviceClientID, cfg.GoogleWebClientID} {
			if aud != "" && !audAllowed(a.allowedAuds, []string{aud}) {
				a.allowedAuds = append(a.allowedAuds, aud)
			}
		}
		a.httpClient = httpClient

		// Pull the OAuth endpoints out of the discovery document for the
		// self-enroll flows (device-code + web callback). Absence is not an
		// error: enrollment simply reports itself unavailable.
		var disc struct {
			DeviceAuthorizationEndpoint string `json:"device_authorization_endpoint"`
			AuthorizationEndpoint       string `json:"authorization_endpoint"`
			TokenEndpoint               string `json:"token_endpoint"`
		}
		if err := provider.Claims(&disc); err == nil {
			a.deviceAuthURL = disc.DeviceAuthorizationEndpoint
			a.authURL = disc.AuthorizationEndpoint
			a.tokenURL = disc.TokenEndpoint
		}
		logger.Info("OIDC client auth enabled", "issuer", issuer,
			"device_flow", a.deviceAuthURL != "" && a.tokenURL != "",
			"web_enroll", cfg.GoogleWebClientID != "" && a.authURL != "" && a.tokenURL != "")
	} else {
		logger.Warn("GOOGLE_CLIENT_ID unset — OIDC client auth disabled")
	}

	return a, nil
}

// SetGate binds the invite-code authorization gate. Called once at startup
// after the Store exists. When nil (or Config.InviteSignup off) the legacy
// ALLOWED_EMAILS path is used and live auth is unchanged.
func (a *Authenticator) SetGate(g *SigninGate) { a.gate = g }

// AuthenticateClient verifies a human client request and returns the caller's
// verified, authorized identity (email + Google sub). Order of checks:
//  1. (dev only) static DEV_CLIENT_TOKEN match -> DEV_EMAIL.
//  2. Full Google ID-token verification: signature/issuer/aud/exp.
//  3. email_verified == true, email and sub present.
//  4. Authorization: ALLOWED_EMAILS (flag OFF) or the invite-code account
//     model (flag ON — active account required; the client API carries no
//     invite code, so a brand-new account without a code is rejected here and
//     must instead sign up through the enroll flow).
//
// Presence of a token is never sufficient.
//
// M4 abuse control: failed sign-ins are rate limited per client IP. The
// budget is CHECKED before any verification work (a brute-forcer gets 429s
// without costing a JWKS/signature check) and CHARGED only on failure, so
// successful authenticated traffic never consumes it (see ratelimit.go).
func (a *Authenticator) AuthenticateClient(ctx context.Context, r *http.Request) (Identity, error) {
	if err := a.limits.checkSigninBudget(clientIP(r)); err != nil {
		return Identity{}, err
	}
	ident, err := a.authenticateClient(ctx, r)
	if err != nil {
		a.limits.chargeSigninFailure(clientIP(r))
	}
	return ident, err
}

// authenticateClient is the unthrottled body of AuthenticateClient.
func (a *Authenticator) authenticateClient(ctx context.Context, r *http.Request) (Identity, error) {
	token := bearerToken(r)
	if token == "" {
		return Identity{}, ErrUnauthorized
	}

	// Dev stand-in: constant-time compare against the static dev token. This is
	// an explicit, opt-in credential and maps directly to DEV_EMAIL.
	if a.cfg.DevAuth && a.cfg.DevClientToken != "" {
		if subtle.ConstantTimeCompare([]byte(token), []byte(a.cfg.DevClientToken)) == 1 {
			ident := Identity{Email: strings.ToLower(a.cfg.DevEmail), Sub: "dev"}
			if a.gate != nil && a.gate.Enabled() {
				// Dev auth still flows through the invite-code gate when ON, so
				// the account model governs uniformly. No invite code on a
				// client API request; an existing account (or legacy owner) is
				// what allows it.
				if err := a.gate.Authorize(ident, "", clientIP(r), tokenFingerprint(token)); err != nil {
					return Identity{}, err
				}
			}
			return ident, nil
		}
		// Not the dev token — fall through to real OIDC if configured.
	}

	// Flag OFF: exact legacy accept/reject behavior (verify + ALLOWED_EMAILS);
	// the client IP rides along for the (logging-only) attempt audit.
	if a.gate == nil || !a.gate.Enabled() {
		return a.verifyIDTokenIP(ctx, token, clientIP(r))
	}

	// Flag ON: verify identity (unchanged OIDC strictness), then authorize via
	// the account model. The client API supplies no invite code.
	ident, err := a.VerifyIdentity(ctx, token)
	if err != nil {
		return Identity{}, err
	}
	if err := a.gate.Authorize(ident, "", clientIP(r), tokenFingerprint(token)); err != nil {
		return Identity{}, err
	}
	return ident, nil
}

// clientIP extracts a best-effort client IP for the audit log. Behind Caddy the
// X-Forwarded-For head is the real client; fall back to RemoteAddr's host.
func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		if i := strings.IndexByte(xff, ','); i >= 0 {
			return strings.TrimSpace(xff[:i])
		}
		return strings.TrimSpace(xff)
	}
	host := r.RemoteAddr
	if i := strings.LastIndexByte(host, ':'); i >= 0 {
		host = host[:i]
	}
	return host
}

// VerifyIdentity runs the OIDC IDENTITY VERIFICATION on a raw ID token and
// returns the verified identity WITHOUT applying any authorization decision:
// signature against the issuer's JWKS, issuer, audience (∈ {GOOGLE_CLIENT_ID,
// GOOGLE_DEVICE_CLIENT_ID, GOOGLE_WEB_CLIENT_ID}), expiry, `sub` present, and
// `email_verified`. These checks are exactly as strict as they have always
// been; the ONLY thing factored out is the ALLOWED_EMAILS membership test,
// which is an authorization decision (see VerifyIDToken and the SigninGate).
// Fail-closed: any verification failure returns ErrUnauthorized.
func (a *Authenticator) VerifyIdentity(ctx context.Context, token string) (Identity, error) {
	if token == "" || a.verifier == nil {
		return Identity{}, ErrUnauthorized
	}

	// Verify checks signature against Google's JWKS, the issuer, and expiry.
	// The audience check is ours (SkipClientIDCheck): see allowedAuds.
	idToken, err := a.verifier.Verify(ctx, token)
	if err != nil {
		a.logger.Warn("client id-token verification failed", "err", err)
		return Identity{}, ErrUnauthorized
	}
	if !audAllowed(a.allowedAuds, idToken.Audience) {
		a.logger.Warn("client id-token audience not allowed", "aud", idToken.Audience)
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

	return Identity{Email: strings.ToLower(claims.Email), Sub: idToken.Subject}, nil
}

// VerifyIDToken runs the full OIDC verification + allowlist authorization on
// a raw ID token and returns the verified, authorized identity. It is the
// `allowlist` signup-mode gate for interactive client auth
// (AuthenticateClient), device-code self-enrollment (the /v1/enroll/poll
// success path), and web enrollment (the /enroll/callback code exchange):
// VerifyIdentity plus the effective-allowlist membership test (env ∪ DB, see
// emailAllowed) plus the allowlist-path account layer (blocked refusal +
// account ensure, see SigninGate.AuthorizeAllowlisted). In every other signup
// mode the callers use VerifyIdentity + the SigninGate instead (enroll.go).
func (a *Authenticator) VerifyIDToken(ctx context.Context, token string) (Identity, error) {
	return a.verifyIDTokenIP(ctx, token, "")
}

// emailAllowed is the EFFECTIVE allowlist membership test: the ALLOWED_EMAILS
// env set (bootstrap/recovery — always honored, so a wedged DB or a portal
// mishap can never lock out the operator) UNION the allowed_emails table
// (portal-managed, behind the gate's short-TTL cache). email must already be
// lowercased (VerifyIdentity lowercases). Nil-gate safe: env-only, which is
// exactly the pre-0006 behavior for gate-less unit tests.
func (a *Authenticator) emailAllowed(email string) bool {
	if a.envAllowed[email] {
		return true
	}
	return a.gate.AllowlistedInDB(email)
}

// verifyIDTokenIP is VerifyIDToken with the client IP plumbed through for the
// signin_attempts audit row. The membership test is env ∪ DB (emailAllowed);
// a member is then run through the allowlist-path account layer
// (AuthorizeAllowlisted): a blocked account is refused even when allowlisted,
// and an allowed sign-in ensures an account row exists so the portal shows
// the owner in every mode. SigninGate.RecordLegacy owns both the Prometheus
// counter and the (throttled-for-allowed) DB row; a nil gate (gate-less unit
// tests) records nothing and allows any member.
func (a *Authenticator) verifyIDTokenIP(ctx context.Context, token, ip string) (Identity, error) {
	ident, err := a.VerifyIdentity(ctx, token)
	if err != nil {
		return Identity{}, err
	}
	if !a.emailAllowed(ident.Email) {
		// Authorization gate: a valid Google login by anyone not on the
		// allowlist is rejected.
		a.gate.RecordLegacy(ident, ip, false, "")
		a.logger.Warn("client email not on allowlist", "email", ident.Email)
		return Identity{}, ErrUnauthorized
	}
	if err := a.gate.AuthorizeAllowlisted(ident, ip, tokenFingerprint(token)); err != nil {
		return Identity{}, err
	}
	return ident, nil
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

// audAllowed reports whether any of the token's audiences appears on the
// allowlist — the same membership rule go-oidc applies for its single
// ClientID. Fail-closed: an empty allowlist or empty audience list rejects.
func audAllowed(allowed, audiences []string) bool {
	for _, aud := range audiences {
		for _, ok := range allowed {
			if aud != "" && aud == ok {
				return true
			}
		}
	}
	return false
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
