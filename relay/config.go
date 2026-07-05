package main

import (
	"os"
	"path/filepath"
	"strings"
)

// Config holds all runtime configuration for the relay. Everything is sourced
// from environment variables so the service is trivial to run under systemd /
// containers with no config file to manage.
type Config struct {
	// ListenAddr is the plain-HTTP listen address. TLS is terminated by Caddy
	// in front, so we deliberately default to loopback only.
	ListenAddr string

	// MetricsAddr is the SEPARATE Prometheus /metrics listen address (default
	// loopback 127.0.0.1:9091 — never on the Caddy-proxied public mux, so
	// metrics are unreachable from the internet by construction). Set
	// METRICS_ADDR=off to disable the listener. See metrics.go.
	MetricsAddr string

	// GoogleClientID is the OAuth 2.0 / OIDC client ID that Google-issued ID
	// tokens must be addressed to (the `aud` claim). Required for real OIDC.
	GoogleClientID string

	// GoogleClientSecret is the OAuth client secret, used ONLY for the
	// device-code token polling in the self-enroll flow (Google's token
	// endpoint requires it for TV/limited-input and desktop client types).
	// Per Google, secrets of these client types are not treated as
	// confidential; it grants nothing by itself. Optional — when unset the
	// poll request simply omits it.
	GoogleClientSecret string

	// GoogleDeviceClientID / GoogleDeviceClientSecret identify a SECOND OAuth
	// client, of type "TVs and Limited Input devices", used only for the
	// device-code self-enroll flow. Google restricts the device-code grant to
	// that client type, while the Mac app signs in with a Desktop client
	// (authorization-code + PKCE) — hence two clients. When set, enroll uses
	// this pair for the device-code start/poll calls and ID tokens carrying
	// this client ID as `aud` are accepted alongside GoogleClientID. When
	// unset, enroll falls back to GoogleClientID/GoogleClientSecret.
	GoogleDeviceClientID     string
	GoogleDeviceClientSecret string

	// GoogleWebClientID / GoogleWebClientSecret identify a THIRD OAuth client,
	// of type "Web application", used for the browser-based enroll flow: the
	// agent's --enroll opens a relay-hosted URL that 302s to Google's auth
	// endpoint and lands back on GET /enroll/callback, where the relay
	// exchanges the code with this client. The client MUST have
	// `https://<relay>/enroll/callback` registered as an authorized redirect
	// URI. Optional: when unset, web enrollment answers 503 and the agent
	// falls back to the device-code flow. ID tokens carrying this client ID
	// as `aud` are accepted alongside the desktop/device clients.
	GoogleWebClientID     string
	GoogleWebClientSecret string

	// RelayBaseURL is this relay's public https base URL (e.g.
	// "https://relay.example.com"), returned to freshly enrolled agents so
	// they know where to dial back. When unset it is derived per-request from
	// the Host header ("https://" + Host), which is correct behind Caddy.
	RelayBaseURL string

	// IssuerURL overrides the OIDC issuer for TESTS ONLY (a local fake issuer
	// serving its own discovery doc + JWKS). It is deliberately NOT read from
	// the environment: production always verifies against the real Google
	// issuer, and an env knob here would be an auth-bypass footgun.
	IssuerURL string

	// AllowedEmails is the authorization allowlist. A verified Google identity
	// is necessary but NOT sufficient: the email must also appear here. This is
	// the sign-in gate when InviteSignup is OFF (the default).
	AllowedEmails []string

	// InviteSignup switches the sign-in authorization model (plan §4). When
	// FALSE (the default) the AllowedEmails allowlist gates sign-in exactly as
	// before — merging/deploying M1 must NOT change live auth. When TRUE the
	// invite-code account model governs: an active account for the caller's
	// google_sub is allowed; a blocked account is refused; no account requires a
	// valid invite code that is then consumed to create the account. Sourced
	// from INVITE_SIGNUP; flipping it live is the human cutover checkpoint.
	InviteSignup bool

	// AdminSubs is the bootstrap admin allowlist: comma-separated Google `sub`
	// values (NOT emails — the sub is the stable authz key, plan §2/§4.4) whose
	// verified holders may call the /v1/admin/ surface. It is the
	// bootstrap/recovery path; day-to-day admin-ness is managed in the DB via
	// accounts.is_admin (admin = sub ∈ AdminSubs OR is_admin=1). Empty means no
	// bootstrap admins — with no is_admin accounts either, every admin endpoint
	// 403s (fail closed). Under DEV_AUTH the dev identity's sub is "dev", so
	// including "dev" here makes the dev token an admin (tests only). Sourced
	// from ADMIN_SUBS.
	AdminSubs []string

	// StateDir holds persisted relay state: the SQLite database
	// (ghoztty-relay.db) and, on legacy installs, the old devices.json.
	StateDir string

	// --- M4 quotas + rate limits (quotas.go / ratelimit.go) ---

	// QuotaMaxDevices / QuotaMaxSessions are the DEFAULT per-account limits on
	// enrolled devices and concurrent relay sessions. 0 = unlimited. Accounts
	// may carry per-account overrides (accounts.max_devices / max_sessions,
	// migration 0004; NULL = use these defaults, 0 = unlimited for that
	// account). Sourced from QUOTA_MAX_DEVICES / QUOTA_MAX_SESSIONS
	// (defaults 10 / 8). Zero-valued Configs built directly (tests) therefore
	// get unlimited unless they opt in.
	QuotaMaxDevices  int
	QuotaMaxSessions int

	// In-memory abuse-control rate limits, requests per minute; 0 disables a
	// limiter. Buckets reset on restart (accepted for the single-VM beta).
	// See ratelimit.go for where each one bites.
	RateSigninPerMin     int // failed sign-ins per IP (RATELIMIT_SIGNIN_PER_MIN, default 10)
	RateEnrollPerMin     int // enroll starts per IP (RATELIMIT_ENROLL_PER_MIN, default 6)
	RateEnrollPollPerMin int // enroll polls per IP, backstop (RATELIMIT_ENROLL_POLL_PER_MIN, default 120)
	RateConnectPerMin    int // client connects per identity (RATELIMIT_CONNECT_PER_MIN, default 60)

	// --- Dev/test auth (MUST be off in production) ---

	// DevAuth, when true, accepts a static bearer token (DevClientToken) as a
	// stand-in for a full OIDC client sign-in. Intended only for local testing
	// of the bridge before Google OAuth is wired up.
	DevAuth bool

	// DevClientToken is the static bearer accepted when DevAuth is true.
	DevClientToken string

	// DevEmail is the identity that a successful dev-auth maps to.
	DevEmail string
}

// LoadConfig reads configuration from the environment, applying defaults.
func LoadConfig() *Config {
	cfg := &Config{
		ListenAddr:               getenv("LISTEN_ADDR", "127.0.0.1:8080"),
		MetricsAddr:              getenv("METRICS_ADDR", "127.0.0.1:9091"),
		GoogleClientID:           os.Getenv("GOOGLE_CLIENT_ID"),
		GoogleClientSecret:       os.Getenv("GOOGLE_CLIENT_SECRET"),
		GoogleDeviceClientID:     os.Getenv("GOOGLE_DEVICE_CLIENT_ID"),
		GoogleDeviceClientSecret: os.Getenv("GOOGLE_DEVICE_CLIENT_SECRET"),
		GoogleWebClientID:        os.Getenv("GOOGLE_WEB_CLIENT_ID"),
		GoogleWebClientSecret:    os.Getenv("GOOGLE_WEB_CLIENT_SECRET"),
		RelayBaseURL:             strings.TrimRight(os.Getenv("RELAY_BASE_URL"), "/"),
		StateDir:                 getenv("STATE_DIR", "./state"),
		InviteSignup:             strings.EqualFold(os.Getenv("INVITE_SIGNUP"), "true"),
		DevAuth:                  strings.EqualFold(os.Getenv("DEV_AUTH"), "true"),
		DevClientToken:           os.Getenv("DEV_CLIENT_TOKEN"),
		DevEmail:                 os.Getenv("DEV_EMAIL"),
	}

	// M4 quotas + rate limits (getenvInt lives in quotas.go).
	cfg.QuotaMaxDevices = getenvInt("QUOTA_MAX_DEVICES", 10)
	cfg.QuotaMaxSessions = getenvInt("QUOTA_MAX_SESSIONS", 8)
	cfg.RateSigninPerMin = getenvInt("RATELIMIT_SIGNIN_PER_MIN", 10)
	cfg.RateEnrollPerMin = getenvInt("RATELIMIT_ENROLL_PER_MIN", 6)
	cfg.RateEnrollPollPerMin = getenvInt("RATELIMIT_ENROLL_POLL_PER_MIN", 120)
	cfg.RateConnectPerMin = getenvInt("RATELIMIT_CONNECT_PER_MIN", 60)

	for _, e := range strings.Split(os.Getenv("ALLOWED_EMAILS"), ",") {
		e = strings.ToLower(strings.TrimSpace(e))
		if e != "" {
			cfg.AllowedEmails = append(cfg.AllowedEmails, e)
		}
	}

	// Subs are opaque case-sensitive identifiers — trimmed, never lowercased.
	for _, s := range strings.Split(os.Getenv("ADMIN_SUBS"), ",") {
		s = strings.TrimSpace(s)
		if s != "" {
			cfg.AdminSubs = append(cfg.AdminSubs, s)
		}
	}

	return cfg
}

// EnrollClientID returns the OAuth client ID to use for the device-code
// enroll flow: the dedicated TV/limited-input client when configured,
// otherwise the primary client (back-compat single-client setup).
func (c *Config) EnrollClientID() string {
	if c.GoogleDeviceClientID != "" {
		return c.GoogleDeviceClientID
	}
	return c.GoogleClientID
}

// EnrollClientSecret returns the client secret paired with EnrollClientID.
// The secret always travels with its own client: mixing the device client's
// ID with the desktop client's secret would be rejected by Google.
func (c *Config) EnrollClientSecret() string {
	if c.GoogleDeviceClientID != "" {
		return c.GoogleDeviceClientSecret
	}
	return c.GoogleClientSecret
}

// DBPath returns the path to the SQLite database file under StateDir.
func (c *Config) DBPath() string {
	return filepath.Join(c.StateDir, "ghoztty-relay.db")
}

// DevicesPath returns the path to the legacy flat-file device directory. It is
// no longer written; it is read once by LoadStore's one-time importer and then
// left in place as a backup.
func (c *Config) DevicesPath() string {
	return filepath.Join(c.StateDir, "devices.json")
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
