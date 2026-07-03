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
	// is necessary but NOT sufficient: the email must also appear here.
	AllowedEmails []string

	// StateDir holds persisted relay state (currently devices.json).
	StateDir string

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
		GoogleClientID:           os.Getenv("GOOGLE_CLIENT_ID"),
		GoogleClientSecret:       os.Getenv("GOOGLE_CLIENT_SECRET"),
		GoogleDeviceClientID:     os.Getenv("GOOGLE_DEVICE_CLIENT_ID"),
		GoogleDeviceClientSecret: os.Getenv("GOOGLE_DEVICE_CLIENT_SECRET"),
		RelayBaseURL:             strings.TrimRight(os.Getenv("RELAY_BASE_URL"), "/"),
		StateDir:                 getenv("STATE_DIR", "./state"),
		DevAuth:                  strings.EqualFold(os.Getenv("DEV_AUTH"), "true"),
		DevClientToken:           os.Getenv("DEV_CLIENT_TOKEN"),
		DevEmail:                 os.Getenv("DEV_EMAIL"),
	}

	for _, e := range strings.Split(os.Getenv("ALLOWED_EMAILS"), ",") {
		e = strings.ToLower(strings.TrimSpace(e))
		if e != "" {
			cfg.AllowedEmails = append(cfg.AllowedEmails, e)
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

// DevicesPath returns the path to the persisted device directory.
func (c *Config) DevicesPath() string {
	return filepath.Join(c.StateDir, "devices.json")
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
