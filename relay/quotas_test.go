package main

// M4 quota tests: device quota at every creating path (manual POST + both
// self-enroll flows, with credential rotation exempt), concurrent-session
// quota at connect, per-account overrides vs defaults, legacy identities with
// no account row, and the 0004 migration round-trip.

import (
	"context"
	"database/sql"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/dzearing/ghoztty-relay/migrations"
	"github.com/pressly/goose/v3"
)

// newQuotaTestServer is newTestServer (bridge_integration_test.go) plus a
// Config mutator, so quota/rate-limit tests can opt into limits while every
// other test keeps the zero-value (unlimited/disabled) defaults.
func newQuotaTestServer(t *testing.T, mutate func(*Config)) (*httptest.Server, string, *Store) {
	t.Helper()

	cfg := &Config{
		ListenAddr:     "127.0.0.1:0",
		StateDir:       t.TempDir(),
		DevAuth:        true,
		DevClientToken: "dev-secret-token",
		DevEmail:       "dev@example.com",
	}
	if mutate != nil {
		mutate(cfg)
	}

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	auth, err := NewAuthenticator(context.Background(), cfg, logger)
	if err != nil {
		t.Fatalf("NewAuthenticator: %v", err)
	}
	store, err := LoadStore(cfg.DBPath(), cfg.DevicesPath(), logger)
	if err != nil {
		t.Fatalf("LoadStore: %v", err)
	}
	auth.SetGate(NewSigninGate(cfg, store, logger))
	dir := NewDirectory(logger)
	h := NewHandler(cfg, auth, store, dir, logger)

	mux := http.NewServeMux()
	h.Register(mux)
	ts := httptest.NewServer(mux)
	t.Cleanup(ts.Close)

	return ts, cfg.DevClientToken, store
}

// postDevice POSTs /v1/client/devices and returns (status, decoded body).
func postDevice(t *testing.T, ts *httptest.Server, token, name string) (int, map[string]any) {
	t.Helper()
	resp := doJSON(t, http.MethodPost, ts.URL+"/v1/client/devices", token, `{"name":"`+name+`"}`)
	defer resp.Body.Close()
	var body map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode device post (status %d): %v", resp.StatusCode, err)
	}
	return resp.StatusCode, body
}

// TestDeviceQuotaManualEnroll: the default device quota is enforced at POST
// /v1/client/devices with the documented 409 body. The dev identity has NO
// account row, proving quotas work for legacy identities via defaults alone.
func TestDeviceQuotaManualEnroll(t *testing.T) {
	ts, token, _ := newQuotaTestServer(t, func(cfg *Config) { cfg.QuotaMaxDevices = 2 })

	for _, name := range []string{"one", "two"} {
		if status, body := postDevice(t, ts, token, name); status != http.StatusCreated {
			t.Fatalf("create %q = %d %v, want 201", name, status, body)
		}
	}
	status, body := postDevice(t, ts, token, "three")
	if status != http.StatusConflict {
		t.Fatalf("over-quota create = %d %v, want 409", status, body)
	}
	if body["error"] != "device quota exceeded" || body["limit"] != float64(2) {
		t.Fatalf("over-quota body = %v, want {error: device quota exceeded, limit: 2}", body)
	}
}

// TestDeviceQuotaZeroUnlimited: 0 = unlimited (both the config default for
// zero-valued Configs and an explicit setting).
func TestDeviceQuotaZeroUnlimited(t *testing.T) {
	ts, token, _ := newQuotaTestServer(t, func(cfg *Config) { cfg.QuotaMaxDevices = 0 })
	for _, name := range []string{"a", "b", "c", "d", "e"} {
		if status, body := postDevice(t, ts, token, name); status != http.StatusCreated {
			t.Fatalf("create %q = %d %v, want 201 (0 must mean unlimited)", name, status, body)
		}
	}
}

// TestDeviceQuotaOverrides: a per-account override beats the default; an
// override of 0 means unlimited for that account; no override (NULL) uses the
// default.
func TestDeviceQuotaOverrides(t *testing.T) {
	t.Run("override raises default", func(t *testing.T) {
		ts, token, store := newQuotaTestServer(t, func(cfg *Config) { cfg.QuotaMaxDevices = 1 })
		acct, err := store.CreateAccount("dev", "dev@example.com", "")
		if err != nil {
			t.Fatalf("seed account: %v", err)
		}
		if err := store.SetQuotaOverrides(acct.ID, QuotaOverrides{MaxDevices: ptrInt(3)}); err != nil {
			t.Fatalf("set overrides: %v", err)
		}

		for _, name := range []string{"a", "b", "c"} {
			if status, body := postDevice(t, ts, token, name); status != http.StatusCreated {
				t.Fatalf("create %q = %d %v, want 201 (override=3)", name, status, body)
			}
		}
		if status, body := postDevice(t, ts, token, "d"); status != http.StatusConflict || body["limit"] != float64(3) {
			t.Fatalf("4th create = %d %v, want 409 limit 3", status, body)
		}
	})

	t.Run("override zero is unlimited", func(t *testing.T) {
		ts, token, store := newQuotaTestServer(t, func(cfg *Config) { cfg.QuotaMaxDevices = 1 })
		acct, err := store.CreateAccount("dev", "dev@example.com", "")
		if err != nil {
			t.Fatalf("seed account: %v", err)
		}
		if err := store.SetQuotaOverrides(acct.ID, QuotaOverrides{MaxDevices: ptrInt(0)}); err != nil {
			t.Fatalf("set overrides: %v", err)
		}
		for _, name := range []string{"a", "b", "c", "d"} {
			if status, body := postDevice(t, ts, token, name); status != http.StatusCreated {
				t.Fatalf("create %q = %d %v, want 201 (override 0 = unlimited)", name, status, body)
			}
		}
	})

	t.Run("null override uses default", func(t *testing.T) {
		ts, token, store := newQuotaTestServer(t, func(cfg *Config) { cfg.QuotaMaxDevices = 1 })
		// Account exists but carries NO overrides (both columns NULL).
		if _, err := store.CreateAccount("dev", "dev@example.com", ""); err != nil {
			t.Fatalf("seed account: %v", err)
		}
		if status, _ := postDevice(t, ts, token, "a"); status != http.StatusCreated {
			t.Fatalf("first create = %d, want 201", status)
		}
		if status, body := postDevice(t, ts, token, "b"); status != http.StatusConflict || body["limit"] != float64(1) {
			t.Fatalf("second create = %d %v, want 409 limit 1 (NULL = default)", status, body)
		}
	})
}

// TestQuotaOverridesEmailFallback: a legacy identity (no sub) resolves its
// account overrides via the email fallback, mirroring ownsClause precedence.
func TestQuotaOverridesEmailFallback(t *testing.T) {
	_, _, store := newQuotaTestServer(t, nil)
	acct, err := store.CreateAccount("sub-q", "quota@example.com", "")
	if err != nil {
		t.Fatalf("seed account: %v", err)
	}
	if err := store.SetQuotaOverrides(acct.ID, QuotaOverrides{MaxDevices: ptrInt(7), MaxSessions: ptrInt(2)}); err != nil {
		t.Fatalf("set overrides: %v", err)
	}

	// Sub-keyed lookup.
	o, err := store.GetQuotaOverrides(Identity{Email: "other@example.com", Sub: "sub-q"})
	if err != nil || o == nil || o.MaxDevices == nil || *o.MaxDevices != 7 {
		t.Fatalf("sub lookup = %+v (%v), want MaxDevices=7", o, err)
	}
	// Email fallback for a sub-less identity.
	o, err = store.GetQuotaOverrides(Identity{Email: "Quota@Example.com", Sub: ""})
	if err != nil || o == nil || o.MaxSessions == nil || *o.MaxSessions != 2 {
		t.Fatalf("email fallback = %+v (%v), want MaxSessions=2", o, err)
	}
	// A stranger resolves nothing.
	o, err = store.GetQuotaOverrides(Identity{Email: "nobody@example.com", Sub: "sub-none"})
	if err != nil || o != nil {
		t.Fatalf("stranger lookup = %+v (%v), want nil", o, err)
	}
}

// TestUpsertRotationNotCounted: at the device limit, re-enrolling an EXISTING
// (owner, name) rotates the credential without tripping the quota — the
// lost-token recovery path — while a new name is refused.
func TestUpsertRotationNotCounted(t *testing.T) {
	_, _, store := newQuotaTestServer(t, nil)

	first, tok1, err := store.UpsertDeviceLimited("dev@example.com", "dev", "box", 1)
	if err != nil {
		t.Fatalf("initial upsert: %v", err)
	}

	// Same name at the limit: rotation, allowed, same identity, new token.
	again, tok2, err := store.UpsertDeviceLimited("dev@example.com", "dev", "box", 1)
	if err != nil {
		t.Fatalf("rotation upsert refused: %v", err)
	}
	if again.ID != first.ID {
		t.Fatalf("rotation changed device identity: %s -> %s", first.ID, again.ID)
	}
	if tok1 == tok2 {
		t.Fatal("rotation did not issue a fresh token")
	}
	if store.AuthenticateToken(tok1) != nil {
		t.Fatal("old token still authenticates after rotation")
	}
	if store.AuthenticateToken(tok2) == nil {
		t.Fatal("new token does not authenticate")
	}

	// A NEW name at the limit is refused with the typed error.
	_, _, err = store.UpsertDeviceLimited("dev@example.com", "dev", "otherbox", 1)
	if !isQuotaExceeded(err) {
		t.Fatalf("new-name upsert err = %v, want QuotaExceededError", err)
	}
}

// TestDeviceQuotaEnrollDeviceFlow: the quota is enforced on the device-code
// self-enroll path with a terse terminal poll outcome, and rotation via
// re-enrolling the same machine still works at the limit.
func TestDeviceQuotaEnrollDeviceFlow(t *testing.T) {
	f := newFakeIssuer(t)
	g := newFakeGoogleDeviceFlow(f)
	ts, _, _ := newEnrollTestServer(t, f, func(cfg *Config) { cfg.QuotaMaxDevices = 1 })

	// First machine fills the quota.
	enrollToCompletion(t, ts, f, g, "box1")

	// A second machine is refused, terminally, naming the limit.
	start := enrollStart(t, ts, "box2")
	g.setOutcome(t, start.UserCode, "approved", mint(t, f.key, f.validClaims()))
	status, body := enrollPoll(t, ts, start.DeviceCodeHandle)
	if status != http.StatusConflict || body["status"] != "error" ||
		body["error"] != "device quota exceeded" || body["limit"] != float64(1) {
		t.Fatalf("over-quota enroll poll = %d %v, want 409 device quota exceeded limit 1", status, body)
	}

	// Re-enrolling box1 (rotation) still succeeds at the limit.
	enrollToCompletion(t, ts, f, g, "box1")
}

// TestDeviceQuotaWebEnroll: the browser flow surfaces the quota as a clear
// error page and the agent's poll gets the terse terminal outcome.
func TestDeviceQuotaWebEnroll(t *testing.T) {
	f := newFakeIssuer(t)
	g := newFakeGoogleWebFlow(f)
	ts, store, _ := newEnrollTestServer(t, f, withWebClient, func(cfg *Config) { cfg.QuotaMaxDevices = 1 })

	// Fill the quota for the enrolling identity.
	if _, _, err := store.CreateDevice(allowedEmail, testSub, "existing"); err != nil {
		t.Fatalf("seed device: %v", err)
	}

	start := webEnrollStart(t, ts, "browser-box")
	state := authRedirect(t, ts, f, start.EnrollURL)
	claims := f.validClaims()
	claims["aud"] = testWebClientID
	code := g.newCode(mint(t, f.key, claims))

	status, _, page := browsePath(t, ts, callbackPath(code, state))
	if status != http.StatusConflict || !strings.Contains(page, "Device limit reached") {
		t.Fatalf("callback = %d, want 409 'Device limit reached'; page:\n%s", status, page)
	}

	pstatus, body := enrollPoll(t, ts, start.DeviceCodeHandle)
	if pstatus != http.StatusConflict || body["error"] != "device quota exceeded" {
		t.Fatalf("post-callback poll = %d %v, want 409 device quota exceeded", pstatus, body)
	}
}

// TestSessionQuotaConnect: the concurrent-session quota refuses a second
// connect with a clean 409 + JSON body while one session is live, and admits
// again once the first session ends.
func TestSessionQuotaConnect(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	ts, clientToken, _ := newQuotaTestServer(t, func(cfg *Config) { cfg.QuotaMaxSessions = 1 })
	deviceID, deviceToken := enrollDevice(t, ts, clientToken, "testbox")

	// Agent online.
	control, _, err := websocket.Dial(ctx, wsURL(ts.URL, "/v1/agent/control"), &websocket.DialOptions{
		HTTPHeader: bearerHeader(deviceToken),
	})
	if err != nil {
		t.Fatalf("agent control dial: %v", err)
	}
	defer control.Close(websocket.StatusNormalClosure, "")

	// Session 1: full bridge (client connect + agent data dial-back).
	client, _, err := websocket.Dial(ctx, wsURL(ts.URL, "/v1/client/connect?device="+deviceID), &websocket.DialOptions{
		HTTPHeader: bearerHeader(clientToken),
	})
	if err != nil {
		t.Fatalf("client connect dial: %v", err)
	}
	_, raw, err := control.Read(ctx)
	if err != nil {
		t.Fatalf("read open command: %v", err)
	}
	var cmd struct {
		Session string `json:"session"`
	}
	if err := json.Unmarshal(raw, &cmd); err != nil {
		t.Fatalf("unmarshal open command: %v", err)
	}
	data, _, err := websocket.Dial(ctx, wsURL(ts.URL, "/v1/agent/data?session="+cmd.Session), &websocket.DialOptions{
		HTTPHeader: bearerHeader(deviceToken),
	})
	if err != nil {
		t.Fatalf("agent data dial: %v", err)
	}
	defer data.CloseNow()

	// Session 2 is refused pre-upgrade: plain GET sees the 409 JSON body.
	resp := doJSON(t, http.MethodGet, ts.URL+"/v1/client/connect?device="+deviceID, clientToken, "")
	var body map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode session-quota body (status %d): %v", resp.StatusCode, err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusConflict ||
		body["error"] != "session quota exceeded" || body["limit"] != float64(1) {
		t.Fatalf("second connect = %d %v, want 409 session quota exceeded limit 1", resp.StatusCode, body)
	}
	// A real WS dial is refused with the same status.
	if _, wsResp, err := websocket.Dial(ctx, wsURL(ts.URL, "/v1/client/connect?device="+deviceID), &websocket.DialOptions{
		HTTPHeader: bearerHeader(clientToken),
	}); err == nil {
		t.Fatal("second WS connect succeeded, want quota refusal")
	} else if wsResp == nil || wsResp.StatusCode != http.StatusConflict {
		got := 0
		if wsResp != nil {
			got = wsResp.StatusCode
		}
		t.Fatalf("second WS connect status = %d, want 409", got)
	}

	// End session 1; the slot frees when the handler returns (RemovePending).
	client.Close(websocket.StatusNormalClosure, "")
	deadline := time.Now().Add(5 * time.Second)
	for {
		c2, _, err := websocket.Dial(ctx, wsURL(ts.URL, "/v1/client/connect?device="+deviceID), &websocket.DialOptions{
			HTTPHeader: bearerHeader(clientToken),
		})
		if err == nil {
			c2.Close(websocket.StatusNormalClosure, "")
			break // slot freed — quota released with the session
		}
		if time.Now().After(deadline) {
			t.Fatal("connect still refused 5s after first session ended")
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// TestQuotaUsage: the M2 admin seam reports consumption vs effective limits.
func TestQuotaUsage(t *testing.T) {
	ts, token, store := newQuotaTestServer(t, func(cfg *Config) {
		cfg.QuotaMaxDevices = 5
		cfg.QuotaMaxSessions = 3
	})
	for _, name := range []string{"a", "b"} {
		if status, _ := postDevice(t, ts, token, name); status != http.StatusCreated {
			t.Fatalf("create %q failed", name)
		}
	}

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	q := NewQuotas(&Config{QuotaMaxDevices: 5, QuotaMaxSessions: 3}, store, NewDirectory(logger), logger)
	u, err := q.UsageFor(Identity{Email: "dev@example.com", Sub: "dev"})
	if err != nil {
		t.Fatalf("UsageFor: %v", err)
	}
	want := QuotaUsage{Devices: 2, MaxDevices: 5, Sessions: 0, MaxSessions: 3}
	if u != want {
		t.Fatalf("usage = %+v, want %+v", u, want)
	}
}

// TestQuotaMigrationRoundTrip: 0004 applies, rolls back, and re-applies
// cleanly (0003 is absent in this tree by design; goose tolerates the gap).
func TestQuotaMigrationRoundTrip(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "roundtrip.db")
	db, err := sql.Open("sqlite", "file:"+dbPath)
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	defer db.Close()

	goose.SetBaseFS(migrations.FS)
	goose.SetLogger(goose.NopLogger())
	if err := goose.SetDialect("sqlite3"); err != nil {
		t.Fatalf("set dialect: %v", err)
	}

	quotaCols := func() int {
		var n int
		if err := db.QueryRow(
			`SELECT COUNT(*) FROM pragma_table_info('accounts')
			 WHERE name IN ('max_devices', 'max_sessions')`,
		).Scan(&n); err != nil {
			t.Fatalf("inspect accounts columns: %v", err)
		}
		return n
	}

	if err := goose.Up(db, "."); err != nil {
		t.Fatalf("up: %v", err)
	}
	if n := quotaCols(); n != 2 {
		t.Fatalf("after up: %d quota columns, want 2", n)
	}
	// Pinned target (never relative Down): later migrations exist (0005), and
	// a relative Down would revert THAT instead of 0004 (merge-composition
	// note in docs/design/multi-tenant-launch-progress.md).
	if err := goose.DownTo(db, ".", 3); err != nil { // rolls back 0005 + 0004, keeps 0003
		t.Fatalf("down: %v", err)
	}
	if n := quotaCols(); n != 0 {
		t.Fatalf("after down: %d quota columns, want 0", n)
	}
	if err := goose.Up(db, "."); err != nil {
		t.Fatalf("re-up: %v", err)
	}
	if n := quotaCols(); n != 2 {
		t.Fatalf("after re-up: %d quota columns, want 2", n)
	}
	// And the re-created columns are writable.
	if _, err := db.Exec(
		`INSERT INTO accounts (id, google_sub, email, status, created_at, max_devices, max_sessions)
		 VALUES ('id1', 'sub1', 'a@b.c', 'active', ?, 4, 2)`, time.Now().UTC(),
	); err != nil {
		t.Fatalf("insert with quota columns after round-trip: %v", err)
	}
}
