package main

// Unit tests for the runtime settings layer (settings.go + migration 0005):
// GetSetting/SetSetting round-trips, the signup-mode resolution precedence
// (DB > SIGNUP_MODE > INVITE_SIGNUP > allowlist default, invalid values fail
// safe to allowlist), the short-TTL cache (a direct DB write is NOT seen
// inside the TTL; the in-process SetSignupMode bust IS seen immediately), and
// the 0005 migration round-trip (pinned DownTo — never relative, per the
// merge-composition note in docs/design/multi-tenant-launch-progress.md).
// HTTP-level behavior (open/closed/invite/blocked, admin endpoints) lives in
// signup_mode_test.go.

import (
	"database/sql"
	"io"
	"log/slog"
	"path/filepath"
	"testing"

	"github.com/dzearing/ghoztty-relay/migrations"
	"github.com/pressly/goose/v3"
)

// newGate builds a SigninGate over a fresh store with the given config —
// each call gets a cold mode cache.
func newGate(t *testing.T, cfg *Config, store *Store) *SigninGate {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	return NewSigninGate(cfg, store, logger)
}

func TestSettingsGetSet(t *testing.T) {
	s := newStore(t)

	// Missing key -> "" with no error.
	if v, err := s.GetSetting("nope"); err != nil || v != "" {
		t.Fatalf("GetSetting(missing) = %q, %v; want \"\", nil", v, err)
	}

	// Insert, read back.
	if err := s.SetSetting("signup_mode", "open"); err != nil {
		t.Fatalf("SetSetting: %v", err)
	}
	if v, err := s.GetSetting("signup_mode"); err != nil || v != "open" {
		t.Fatalf("GetSetting = %q, %v; want open, nil", v, err)
	}

	// Upsert overwrites in place.
	if err := s.SetSetting("signup_mode", "closed"); err != nil {
		t.Fatalf("SetSetting(update): %v", err)
	}
	if v, _ := s.GetSetting("signup_mode"); v != "closed" {
		t.Fatalf("GetSetting after update = %q, want closed", v)
	}
	var n int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM settings`).Scan(&n); err != nil || n != 1 {
		t.Fatalf("settings rows = %d (err %v), want exactly 1 (upsert, not insert)", n, err)
	}

	// Empty key is refused.
	if err := s.SetSetting("", "x"); err == nil {
		t.Fatalf("SetSetting(empty key) should error")
	}
}

// TestSignupModeResolutionPrecedence: DB row > SIGNUP_MODE env > INVITE_SIGNUP
// env > allowlist default; invalid values (DB or env) fail safe to allowlist.
func TestSignupModeResolutionPrecedence(t *testing.T) {
	cases := []struct {
		name       string
		cfg        Config
		dbValue    string // "" = no settings row
		wantMode   SignupMode
		wantSource string
	}{
		{"default is allowlist", Config{}, "", SignupAllowlist, settingSourceEnv},
		{"INVITE_SIGNUP=true seeds invite", Config{InviteSignup: true}, "", SignupInvite, settingSourceEnv},
		{"SIGNUP_MODE beats INVITE_SIGNUP", Config{SignupMode: "open", InviteSignup: true}, "", SignupOpen, settingSourceEnv},
		{"SIGNUP_MODE=closed", Config{SignupMode: "closed"}, "", SignupClosed, settingSourceEnv},
		{"invalid SIGNUP_MODE fails safe", Config{SignupMode: "wide-open", InviteSignup: true}, "", SignupAllowlist, settingSourceEnv},
		{"db beats every env seed", Config{SignupMode: "open", InviteSignup: true}, "closed", SignupClosed, settingSourceDB},
		{"db allowlist wins over env invite", Config{InviteSignup: true}, "allowlist", SignupAllowlist, settingSourceDB},
		{"invalid db value fails safe", Config{SignupMode: "open"}, "bogus", SignupAllowlist, settingSourceDB},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			store := newStore(t)
			if tc.dbValue != "" {
				if err := store.SetSetting(settingSignupMode, tc.dbValue); err != nil {
					t.Fatalf("seed setting: %v", err)
				}
			}
			g := newGate(t, &tc.cfg, store)
			mode, source := g.SignupModeWithSource()
			if mode != tc.wantMode || source != tc.wantSource {
				t.Fatalf("mode = %s/%s, want %s/%s", mode, source, tc.wantMode, tc.wantSource)
			}
			// Enabled() is derived: everything but allowlist enables the gate.
			if got, want := g.Enabled(), tc.wantMode != SignupAllowlist; got != want {
				t.Fatalf("Enabled() = %v, want %v", got, want)
			}
		})
	}
}

// TestSignupModeCacheAndBust: the resolved mode is served from cache inside
// the TTL (a DIRECT DB write is deliberately not seen yet), while the
// in-process SetSignupMode bust makes a change visible immediately — the
// property the admin PUT path relies on.
func TestSignupModeCacheAndBust(t *testing.T) {
	store := newStore(t)
	g := newGate(t, &Config{InviteSignup: true}, store)

	// Prime the cache: env-seeded invite.
	if m := g.SignupMode(); m != SignupInvite {
		t.Fatalf("initial mode = %s, want invite", m)
	}

	// A direct DB write (another process, or a test poking the store) is NOT
	// seen within the TTL — that's the cache working.
	if err := store.SetSetting(settingSignupMode, "open"); err != nil {
		t.Fatalf("SetSetting: %v", err)
	}
	if m := g.SignupMode(); m != SignupInvite {
		t.Fatalf("mode after direct db write = %s, want still-cached invite", m)
	}

	// SetSignupMode (the admin path) busts the cache: visible immediately.
	if err := g.SetSignupMode(SignupClosed); err != nil {
		t.Fatalf("SetSignupMode: %v", err)
	}
	mode, source := g.SignupModeWithSource()
	if mode != SignupClosed || source != settingSourceDB {
		t.Fatalf("mode after bust = %s/%s, want closed/db", mode, source)
	}
	// And it persisted.
	if v, _ := store.GetSetting(settingSignupMode); v != "closed" {
		t.Fatalf("persisted mode = %q, want closed", v)
	}

	// A fresh gate (cold cache — e.g. a restarted process) sees the DB value.
	g2 := newGate(t, &Config{InviteSignup: true}, store)
	if m := g2.SignupMode(); m != SignupClosed {
		t.Fatalf("fresh gate mode = %s, want closed", m)
	}

	// Invalid modes are refused before touching the store.
	if err := g.SetSignupMode("hackerman"); err == nil {
		t.Fatalf("SetSignupMode(invalid) should error")
	}
}

// TestMigration0005RoundTrip proves 0005 goes Up -> Down -> Up cleanly.
// DownTo(4) is PINNED (never a relative Down — merge-composition note in the
// progress doc: a relative Down would revert whatever happens to be latest).
func TestMigration0005RoundTrip(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "roundtrip.db")
	db, err := sql.Open("sqlite", "file:"+dbPath+"?_pragma=journal_mode(WAL)&_pragma=foreign_keys(ON)")
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	defer db.Close()

	goose.SetBaseFS(migrations.FS)
	goose.SetLogger(goose.NopLogger())
	if err := goose.SetDialect("sqlite3"); err != nil {
		t.Fatalf("set dialect: %v", err)
	}

	hasSettings := func() bool {
		var n int
		if err := db.QueryRow(
			`SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'settings'`,
		).Scan(&n); err != nil {
			t.Fatalf("sqlite_master: %v", err)
		}
		return n > 0
	}

	if err := goose.Up(db, "."); err != nil {
		t.Fatalf("goose up: %v", err)
	}
	if !hasSettings() {
		t.Fatalf("after up: settings table missing")
	}

	if err := goose.DownTo(db, ".", 4); err != nil {
		t.Fatalf("goose down to 0004: %v", err)
	}
	if hasSettings() {
		t.Fatalf("after down: settings table still present")
	}

	if err := goose.Up(db, "."); err != nil {
		t.Fatalf("goose re-up: %v", err)
	}
	if !hasSettings() {
		t.Fatalf("after re-up: settings table missing")
	}
	// The re-created table is writable.
	if _, err := db.Exec(
		`INSERT INTO settings (key, value, updated_at) VALUES ('signup_mode', 'open', CURRENT_TIMESTAMP)`,
	); err != nil {
		t.Fatalf("insert after round-trip: %v", err)
	}
}
