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
		ListenAddr:     getenv("LISTEN_ADDR", "127.0.0.1:8080"),
		GoogleClientID: os.Getenv("GOOGLE_CLIENT_ID"),
		StateDir:       getenv("STATE_DIR", "./state"),
		DevAuth:        strings.EqualFold(os.Getenv("DEV_AUTH"), "true"),
		DevClientToken: os.Getenv("DEV_CLIENT_TOKEN"),
		DevEmail:       os.Getenv("DEV_EMAIL"),
	}

	for _, e := range strings.Split(os.Getenv("ALLOWED_EMAILS"), ",") {
		e = strings.ToLower(strings.TrimSpace(e))
		if e != "" {
			cfg.AllowedEmails = append(cfg.AllowedEmails, e)
		}
	}

	return cfg
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
