package main

// Runtime service settings (migration 0005): a key/value table an admin
// mutates LIVE from the portal — no env edit, no restart. The first consumer
// is the sign-up policy, settings.signup_mode, which replaces the binary
// INVITE_SIGNUP env flag with four runtime-switchable modes:
//
//   open      — anyone with a verified Google account gets an account on
//               first sign-in (no invite code)
//   invite    — new accounts require a valid invite code (the M1 behavior)
//   closed    — no new sign-ups; existing accounts keep working (refusals
//               audited as outcome `signup_closed`)
//   allowlist — the legacy ALLOWED_EMAILS env gate (pre-M1 behavior)
//
// Resolution order (resolveSignupMode): the DB row wins; when absent the mode
// is seeded from the environment — SIGNUP_MODE if set, else INVITE_SIGNUP=true
// maps to `invite` (back-compat), else `allowlist` — so an existing deployment
// keeps its exact current behavior until an admin changes the mode. Unknown
// values fail safe to `allowlist` (the most restrictive pre-existing behavior)
// with an error log, never to an open door.
//
// The resolved mode is cached for a short TTL so per-request auth does not
// hammer SQLite; SetSignupMode (the admin PUT path) busts the cache
// in-process so a change is effective on the very next request.

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// SignupMode is the sign-up policy (settings.signup_mode).
type SignupMode string

const (
	SignupOpen      SignupMode = "open"
	SignupInvite    SignupMode = "invite"
	SignupClosed    SignupMode = "closed"
	SignupAllowlist SignupMode = "allowlist"
)

// settingSignupMode is the settings key holding the sign-up policy.
const settingSignupMode = "signup_mode"

// signupModeTTL bounds how long a resolved mode is served from cache. Auth
// runs on EVERY API request (device-list polls included), so an uncached
// resolver would turn each request into an extra SQLite read; 5s keeps the
// mode effectively live (an admin flip lands within seconds on other
// processes, instantly in-process via the SetSignupMode cache bust) while
// costing at most one read per interval.
const signupModeTTL = 5 * time.Second

// parseSignupMode validates a raw mode string. Fail-closed by construction:
// callers map !ok to SignupAllowlist.
func parseSignupMode(s string) (SignupMode, bool) {
	switch SignupMode(s) {
	case SignupOpen, SignupInvite, SignupClosed, SignupAllowlist:
		return SignupMode(s), true
	}
	return "", false
}

// --- Store layer ---------------------------------------------------------------

// GetSetting returns the value for key, or "" (no error) when the key is
// absent — absence is the normal "not configured, use the default" state.
func (s *Store) GetSetting(key string) (string, error) {
	var v string
	err := s.db.QueryRow(`SELECT value FROM settings WHERE key = ?`, key).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("get setting %q: %w", key, err)
	}
	return v, nil
}

// SetSetting upserts one settings row. The single INSERT..ON CONFLICT
// statement is atomic (one implicit transaction), so a concurrent reader can
// never observe a half-written row.
func (s *Store) SetSetting(key, value string) error {
	if key == "" {
		return fmt.Errorf("set setting: empty key")
	}
	if _, err := s.db.Exec(
		`INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?)
		 ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
		key, value, time.Now().UTC(),
	); err != nil {
		return fmt.Errorf("set setting %q: %w", key, err)
	}
	return nil
}

// --- Mode resolution (on the SigninGate, which owns cfg + store) ----------------

// Setting sources, as reported by GET /v1/admin/settings.
const (
	settingSourceDB  = "db"          // a settings row governs
	settingSourceEnv = "env-default" // no row yet; seeded from the environment
)

// SignupMode returns the effective sign-up policy (cached; see signupModeTTL).
func (g *SigninGate) SignupMode() SignupMode {
	m, _ := g.SignupModeWithSource()
	return m
}

// SignupModeWithSource returns the effective mode plus where it came from
// ("db" when a settings row governs, "env-default" when seeded from the
// environment). Serves from the short-TTL cache; on expiry it re-resolves.
func (g *SigninGate) SignupModeWithSource() (SignupMode, string) {
	now := time.Now()
	g.modeMu.Lock()
	if g.modeVal != "" && now.Before(g.modeExp) {
		m, src := g.modeVal, g.modeSource
		g.modeMu.Unlock()
		return m, src
	}
	g.modeMu.Unlock()

	m, src := g.resolveSignupMode()

	g.modeMu.Lock()
	g.modeVal, g.modeSource, g.modeExp = m, src, now.Add(signupModeTTL)
	g.modeMu.Unlock()
	return m, src
}

// SetSignupMode persists the mode (settings.signup_mode) and busts the
// in-process cache, so the change governs the very next request with no
// restart. Callers validate the mode first (parseSignupMode).
func (g *SigninGate) SetSignupMode(m SignupMode) error {
	if _, ok := parseSignupMode(string(m)); !ok {
		return fmt.Errorf("set signup mode: invalid mode %q", m)
	}
	if err := g.store.SetSetting(settingSignupMode, string(m)); err != nil {
		return err
	}
	g.modeMu.Lock()
	g.modeVal, g.modeSource, g.modeExp = "", "", time.Time{} // force re-resolve from DB
	g.modeMu.Unlock()
	return nil
}

// resolveSignupMode is the uncached resolution: DB row > SIGNUP_MODE env >
// INVITE_SIGNUP env (true -> invite) > allowlist. Any invalid value — and a
// DB read failure — fails safe to allowlist (the most restrictive
// pre-existing behavior) with an error log.
func (g *SigninGate) resolveSignupMode() (SignupMode, string) {
	v, err := g.store.GetSetting(settingSignupMode)
	if err != nil {
		g.logger.Error("signup mode lookup failed — failing safe to allowlist", "err", err)
		return SignupAllowlist, settingSourceEnv
	}
	if v != "" {
		if m, ok := parseSignupMode(v); ok {
			return m, settingSourceDB
		}
		g.logger.Error("invalid settings.signup_mode — failing safe to allowlist", "value", v)
		return SignupAllowlist, settingSourceDB
	}

	// No DB row yet: seed from the environment so existing deployments keep
	// their exact behavior until the mode is changed from the portal.
	if g.cfg.SignupMode != "" {
		if m, ok := parseSignupMode(g.cfg.SignupMode); ok {
			return m, settingSourceEnv
		}
		g.logger.Error("invalid SIGNUP_MODE env — failing safe to allowlist", "value", g.cfg.SignupMode)
		return SignupAllowlist, settingSourceEnv
	}
	if g.cfg.InviteSignup {
		return SignupInvite, settingSourceEnv
	}
	return SignupAllowlist, settingSourceEnv
}
