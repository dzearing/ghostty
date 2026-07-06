package main

// M2 tests: the /v1/admin/ surface and its authorization. Coverage:
//   - 401 (no/garbage token) and 403 (verified non-admin) on EVERY route
//     (table-driven sweep — also proves each route is actually registered,
//     since an unregistered path would 404 instead).
//   - ADMIN_SUBS bootstrap works with NO account row, in the flag-OFF world,
//     for a sub that is NOT on ALLOWED_EMAILS (admins are a distinct surface).
//   - is_admin=1 account grants admin WITHOUT ADMIN_SUBS.
//   - Happy paths for every endpoint, and an admin_audit row per mutation.
//   - block -> that account's sign-in refused via the M1 gate (flag ON),
//     unblock -> allowed again.
//   - delete account -> account gone AND its devices' tokens revoked
//     (including a legacy email-fallback device), live connection kicked.
//   - invite create/list/revoke round-trip incl. generated-code shape.
//   - signin-attempts filters (outcome/email/since/limit) + input validation.
//   - migration 0003 round-trips Up -> Down -> Up.

import (
	"context"
	"database/sql"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"regexp"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/dzearing/ghoztty-relay/migrations"
	"github.com/pressly/goose/v3"
)

// newAdminTestServer wires the full relay with DEV_AUTH plus the given
// ADMIN_SUBS bootstrap list. The dev identity's sub is "dev", so passing
// "dev" makes the dev token an admin; passing nothing makes it a verified
// NON-admin (the 403 case).
func newAdminTestServer(t *testing.T, adminSubs ...string) (*httptest.Server, string, *Store) {
	t.Helper()

	cfg := &Config{
		ListenAddr:     "127.0.0.1:0",
		StateDir:       t.TempDir(),
		DevAuth:        true,
		DevClientToken: "dev-secret-token",
		DevEmail:       "dev@example.com",
		AdminSubs:      adminSubs,
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
	h := NewHandler(cfg, auth, store, NewDirectory(logger), logger)
	mux := http.NewServeMux()
	h.Register(mux)
	ts := httptest.NewServer(mux)
	t.Cleanup(ts.Close)
	return ts, cfg.DevClientToken, store
}

// newAdminOIDCServer wires the relay against the fake issuer (+ fake Google
// device flow, for the sign-in-gate integration tests), mirroring main.go's
// wiring. mutate adjusts the config before construction (flag state,
// ALLOWED_EMAILS, ADMIN_SUBS...).
func newAdminOIDCServer(t *testing.T, f *fakeIssuer, mutate func(*Config)) (*httptest.Server, *Store, *fakeGoogleDeviceFlow) {
	t.Helper()

	g := newFakeGoogleDeviceFlow(f)

	cfg := &Config{
		ListenAddr:         "127.0.0.1:0",
		StateDir:           t.TempDir(),
		GoogleClientID:     testClientID,
		GoogleClientSecret: "test-client-secret",
		IssuerURL:          f.srv.URL,
		RelayBaseURL:       "https://relay.test",
	}
	if mutate != nil {
		mutate(cfg)
	}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	initCtx, cancelInit := context.WithTimeout(context.Background(), 10*time.Second)
	auth, err := NewAuthenticator(initCtx, cfg, logger)
	cancelInit()
	if err != nil {
		t.Fatalf("NewAuthenticator: %v", err)
	}
	store, err := LoadStore(cfg.DBPath(), cfg.DevicesPath(), logger)
	if err != nil {
		t.Fatalf("LoadStore: %v", err)
	}
	auth.SetGate(NewSigninGate(cfg, store, logger))
	h := NewHandler(cfg, auth, store, NewDirectory(logger), logger)
	mux := http.NewServeMux()
	h.Register(mux)
	ts := httptest.NewServer(mux)
	t.Cleanup(ts.Close)
	return ts, store, g
}

// adminRoutes enumerates every admin endpoint (method, path, body) for the
// authorization sweep.
var adminRoutes = []struct {
	method, path, body string
}{
	{http.MethodGet, "/v1/admin/signin-attempts", ""},
	{http.MethodGet, "/v1/admin/accounts", ""},
	{http.MethodPost, "/v1/admin/accounts/some-id/block", `{"reason":"x"}`},
	{http.MethodPost, "/v1/admin/accounts/some-id/unblock", ""},
	{http.MethodDelete, "/v1/admin/accounts/some-id", ""},
	{http.MethodGet, "/v1/admin/accounts/some-id/usage", ""},
	{http.MethodPost, "/v1/admin/invites", `{}`},
	{http.MethodGet, "/v1/admin/invites", ""},
	{http.MethodDelete, "/v1/admin/invites/SOME-CODE", ""},
	{http.MethodGet, "/v1/admin/settings", ""},
	{http.MethodPut, "/v1/admin/settings", `{"signup_mode":"open"}`},
	{http.MethodGet, "/v1/admin/allowlist", ""},
	{http.MethodPost, "/v1/admin/allowlist", `{"email":"someone@example.com"}`},
	{http.MethodDelete, "/v1/admin/allowlist/someone@example.com", ""},
}

// TestAdminAuthSweep: on every admin route, a missing token and a garbage
// token are 401 (not verifiably anyone) while a VALID user token whose sub is
// not an admin is 403 — deliberately distinct statuses, and never a success.
func TestAdminAuthSweep(t *testing.T) {
	// No ADMIN_SUBS: the dev token verifies (sub "dev") but is NOT an admin.
	ts, devToken, _ := newAdminTestServer(t)

	for _, rt := range adminRoutes {
		t.Run(rt.method+" "+rt.path, func(t *testing.T) {
			// No token -> 401.
			req, _ := http.NewRequest(rt.method, ts.URL+rt.path, nil)
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatalf("no-token request: %v", err)
			}
			resp.Body.Close()
			if resp.StatusCode != http.StatusUnauthorized {
				t.Fatalf("no token status = %d, want 401", resp.StatusCode)
			}

			// Garbage token -> 401.
			resp2 := doJSON(t, rt.method, ts.URL+rt.path, "garbage-token", rt.body)
			resp2.Body.Close()
			if resp2.StatusCode != http.StatusUnauthorized {
				t.Fatalf("garbage token status = %d, want 401", resp2.StatusCode)
			}

			// Verified non-admin (the dev token authenticates users fine) -> 403.
			resp3 := doJSON(t, rt.method, ts.URL+rt.path, devToken, rt.body)
			resp3.Body.Close()
			if resp3.StatusCode != http.StatusForbidden {
				t.Fatalf("verified non-admin status = %d, want 403", resp3.StatusCode)
			}
		})
	}
}

// TestAdminBootstrapSubNoAccountRow: ADMIN_SUBS alone grants admin — no
// account row exists, INVITE_SIGNUP is OFF, and the admin's email is NOT on
// ALLOWED_EMAILS. The same token is refused on the USER surface (admins are a
// distinct authorization surface, not super-users of the client API).
func TestAdminBootstrapSubNoAccountRow(t *testing.T) {
	f := newFakeIssuer(t)
	ts, store, _ := newAdminOIDCServer(t, f, func(c *Config) {
		c.AllowedEmails = nil // admin deliberately not a user
		c.AdminSubs = []string{"admin-sub-boot"}
	})
	adminToken := mint(t, f.key, claimsFor(f, "admin-sub-boot", "admin@example.com"))

	// Sanity: truly no account row backs this admin.
	if a, _ := store.GetAccountBySub("admin-sub-boot"); a != nil {
		t.Fatalf("precondition: expected no account row, got %+v", a)
	}

	resp := doJSON(t, http.MethodGet, ts.URL+"/v1/admin/accounts", adminToken, "")
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("bootstrap admin status = %d, want 200", resp.StatusCode)
	}

	// The admin token grants nothing on the user surface (flag OFF ->
	// ALLOWED_EMAILS gates, and this email is not on it).
	resp2 := doJSON(t, http.MethodGet, ts.URL+"/v1/client/devices", adminToken, "")
	resp2.Body.Close()
	if resp2.StatusCode != http.StatusUnauthorized {
		t.Fatalf("admin token on user surface status = %d, want 401", resp2.StatusCode)
	}
}

// TestAdminVerifiedUserNotAdmin403OIDC: a real, ALLOWED_EMAILS-authorized user
// (flag OFF) is still 403 on the admin surface — a normal user token is never
// sufficient.
func TestAdminVerifiedUserNotAdmin403OIDC(t *testing.T) {
	f := newFakeIssuer(t)
	ts, _, _ := newAdminOIDCServer(t, f, func(c *Config) {
		c.AllowedEmails = []string{allowedEmail}
		c.AdminSubs = []string{"someone-else"}
	})
	userToken := mint(t, f.key, f.validClaims()) // allowlisted user, sub testSub

	// Works on the user surface...
	resp := doJSON(t, http.MethodGet, ts.URL+"/v1/client/devices", userToken, "")
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("user token on user surface status = %d, want 200", resp.StatusCode)
	}

	// ...but is 403 (not 401) on the admin surface.
	resp2 := doJSON(t, http.MethodGet, ts.URL+"/v1/admin/accounts", userToken, "")
	resp2.Body.Close()
	if resp2.StatusCode != http.StatusForbidden {
		t.Fatalf("user token on admin surface status = %d, want 403", resp2.StatusCode)
	}
}

// TestAdminIsAdminFlagWithoutEnv: an account with is_admin=1 grants admin
// with ADMIN_SUBS empty — the managed-in-DB path stands alone.
func TestAdminIsAdminFlagWithoutEnv(t *testing.T) {
	ts, devToken, store := newAdminTestServer(t) // no ADMIN_SUBS

	// Before the flag: verified but 403.
	resp := doJSON(t, http.MethodGet, ts.URL+"/v1/admin/invites", devToken, "")
	resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("pre-flag status = %d, want 403", resp.StatusCode)
	}

	a, err := store.CreateAccount("dev", "dev@example.com", "")
	if err != nil {
		t.Fatalf("seed account: %v", err)
	}
	if ok, err := store.SetAccountAdmin(a.ID, true); err != nil || !ok {
		t.Fatalf("set admin flag: ok=%v err=%v", ok, err)
	}

	resp2 := doJSON(t, http.MethodGet, ts.URL+"/v1/admin/invites", devToken, "")
	resp2.Body.Close()
	if resp2.StatusCode != http.StatusOK {
		t.Fatalf("post-flag status = %d, want 200", resp2.StatusCode)
	}
}

// decodeJSONBody decodes a response body into a generic map and closes it.
func decodeJSONBody(t *testing.T, resp *http.Response) map[string]any {
	t.Helper()
	defer resp.Body.Close()
	var out map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode body (status %d): %v", resp.StatusCode, err)
	}
	return out
}

// seedAttempt inserts a signin_attempts row with an EXPLICIT timestamp (the
// store method always stamps now(), which is useless for `since` tests).
func seedAttempt(t *testing.T, s *Store, ts time.Time, email, sub, outcome, accountID string) {
	t.Helper()
	var acct any
	if accountID != "" {
		acct = accountID
	}
	if _, err := s.db.Exec(
		`INSERT INTO signin_attempts (ts, email, google_sub, ip, outcome, account_id)
		 VALUES (?, ?, ?, ?, ?, ?)`,
		ts.UTC(), email, sub, "10.0.0.1", outcome, acct,
	); err != nil {
		t.Fatalf("seed attempt: %v", err)
	}
}

// TestAdminSigninAttemptsFilters covers the feed: newest-first ordering and
// each query filter (outcome, email, since, limit), plus 400s on bad input.
func TestAdminSigninAttemptsFilters(t *testing.T) {
	ts, adminToken, store := newAdminTestServer(t, "dev")

	base := time.Date(2026, 7, 1, 12, 0, 0, 0, time.UTC)
	seedAttempt(t, store, base, "a@example.com", "sub-a", outcomeAllowed, "acct-a")
	seedAttempt(t, store, base.Add(1*time.Hour), "b@example.com", "sub-b", outcomeBlocked, "acct-b")
	seedAttempt(t, store, base.Add(2*time.Hour), "a@example.com", "sub-a", outcomeNoAccount, "")
	seedAttempt(t, store, base.Add(3*time.Hour), "c@example.com", "sub-c", outcomeAllowed, "acct-c")

	get := func(query string) []SigninAttempt {
		t.Helper()
		resp := doJSON(t, http.MethodGet, ts.URL+"/v1/admin/signin-attempts"+query, adminToken, "")
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("GET %s status = %d, want 200", query, resp.StatusCode)
		}
		var out struct {
			Attempts []SigninAttempt `json:"attempts"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
			t.Fatalf("decode attempts: %v", err)
		}
		return out.Attempts
	}

	// Unfiltered: all four, newest first.
	all := get("")
	if len(all) != 4 {
		t.Fatalf("unfiltered = %d rows, want 4", len(all))
	}
	for i := 1; i < len(all); i++ {
		if all[i].TS.After(all[i-1].TS) {
			t.Fatalf("not newest-first: %v after %v", all[i].TS, all[i-1].TS)
		}
	}
	if all[0].Email != "c@example.com" || all[0].Outcome != outcomeAllowed || all[0].IP != "10.0.0.1" {
		t.Fatalf("newest row = %+v, want c@example.com allowed", all[0])
	}

	// outcome filter.
	if got := get("?outcome=" + outcomeAllowed); len(got) != 2 {
		t.Fatalf("outcome=allowed = %d rows, want 2", len(got))
	}
	// email filter (exact).
	if got := get("?email=a@example.com"); len(got) != 2 {
		t.Fatalf("email=a@ = %d rows, want 2", len(got))
	}
	// since filter (inclusive).
	since := base.Add(2 * time.Hour).Format(time.RFC3339)
	if got := get("?since=" + since); len(got) != 2 {
		t.Fatalf("since=+2h = %d rows, want 2", len(got))
	}
	// limit.
	if got := get("?limit=3"); len(got) != 3 {
		t.Fatalf("limit=3 = %d rows, want 3", len(got))
	}
	// Combined.
	if got := get("?outcome=" + outcomeAllowed + "&email=a@example.com"); len(got) != 1 || got[0].AccountID != "acct-a" {
		t.Fatalf("combined filter = %+v, want the single acct-a row", got)
	}

	// Bad input -> 400.
	for _, q := range []string{"?since=yesterday", "?limit=0", "?limit=nope"} {
		resp := doJSON(t, http.MethodGet, ts.URL+"/v1/admin/signin-attempts"+q, adminToken, "")
		resp.Body.Close()
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("GET %s status = %d, want 400", q, resp.StatusCode)
		}
	}
}

// TestAdminAccountsListSearch covers GET /v1/admin/accounts: device counts
// under the sub+email-fallback predicate, substring search, status filter.
func TestAdminAccountsListSearch(t *testing.T) {
	ts, adminToken, store := newAdminTestServer(t, "dev")

	a1, _ := store.CreateAccount("sub-alice", "alice@example.com", "CODE1")
	a2, _ := store.CreateAccount("sub-bob", "bob@other.net", "")
	// alice: one sub-owned device + one legacy email-fallback device.
	if _, _, err := store.CreateDevice("alice@example.com", "sub-alice", "alice-box"); err != nil {
		t.Fatalf("seed device: %v", err)
	}
	if _, _, err := store.CreateDevice("alice@example.com", "", "alice-legacy"); err != nil {
		t.Fatalf("seed legacy device: %v", err)
	}
	if _, err := store.BlockAccount(a2.ID, "spam"); err != nil {
		t.Fatalf("block bob: %v", err)
	}

	get := func(query string) []accountView {
		t.Helper()
		resp := doJSON(t, http.MethodGet, ts.URL+"/v1/admin/accounts"+query, adminToken, "")
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("GET %s status = %d, want 200", query, resp.StatusCode)
		}
		var out struct {
			Accounts []accountView `json:"accounts"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
			t.Fatalf("decode accounts: %v", err)
		}
		return out.Accounts
	}

	all := get("")
	if len(all) != 2 {
		t.Fatalf("list = %d accounts, want 2", len(all))
	}
	byID := map[string]accountView{}
	for _, a := range all {
		byID[a.ID] = a
	}
	if v := byID[a1.ID]; v.DeviceCount != 2 || v.Email != "alice@example.com" || v.InvitedByCode != "CODE1" {
		t.Fatalf("alice view = %+v, want device_count=2 (sub-owned + legacy)", v)
	}
	if v := byID[a2.ID]; v.DeviceCount != 0 || v.Status != AccountBlocked || v.BlockedReason != "spam" {
		t.Fatalf("bob view = %+v, want blocked with 0 devices", v)
	}

	// Substring search on email.
	if got := get("?q=alice"); len(got) != 1 || got[0].ID != a1.ID {
		t.Fatalf("q=alice = %+v, want just alice", got)
	}
	// LIKE wildcards in q are literal, not wildcards.
	if got := get("?q=%25"); len(got) != 0 {
		t.Fatalf("q=%%25 matched %d accounts, want 0 (wildcard must be escaped)", len(got))
	}
	// Status filter.
	if got := get("?status=blocked"); len(got) != 1 || got[0].ID != a2.ID {
		t.Fatalf("status=blocked = %+v, want just bob", got)
	}
	// Invalid status -> 400.
	resp := doJSON(t, http.MethodGet, ts.URL+"/v1/admin/accounts?status=weird", adminToken, "")
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status=weird status = %d, want 400", resp.StatusCode)
	}
}

// TestAdminBlockUnblock covers the block/unblock pair: state transitions,
// idempotency (original blocked_at preserved on re-block), 404 on unknown
// ids, and one audit row per mutation.
func TestAdminBlockUnblock(t *testing.T) {
	ts, adminToken, store := newAdminTestServer(t, "dev")
	a, _ := store.CreateAccount("sub-x", "x@example.com", "")

	// Block with a reason.
	resp := doJSON(t, http.MethodPost, ts.URL+"/v1/admin/accounts/"+a.ID+"/block", adminToken, `{"reason":"abuse"}`)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("block status = %d, want 200", resp.StatusCode)
	}
	body := decodeJSONBody(t, resp)
	acct := body["account"].(map[string]any)
	if acct["status"] != AccountBlocked || acct["blocked_reason"] != "abuse" || acct["blocked_at"] == nil {
		t.Fatalf("block response account = %+v", acct)
	}
	got, _ := store.GetAccountByID(a.ID)
	if got.Status != AccountBlocked || got.BlockedAt == nil || got.BlockedReason != "abuse" {
		t.Fatalf("persisted account after block = %+v", got)
	}
	firstBlockedAt := *got.BlockedAt

	// Idempotent re-block: 200, original blocked_at preserved, reason refreshed.
	resp2 := doJSON(t, http.MethodPost, ts.URL+"/v1/admin/accounts/"+a.ID+"/block", adminToken, `{"reason":"worse"}`)
	resp2.Body.Close()
	if resp2.StatusCode != http.StatusOK {
		t.Fatalf("re-block status = %d, want 200", resp2.StatusCode)
	}
	got2, _ := store.GetAccountByID(a.ID)
	if !got2.BlockedAt.Equal(firstBlockedAt) || got2.BlockedReason != "worse" {
		t.Fatalf("re-block: blocked_at=%v (want %v) reason=%q (want worse)", got2.BlockedAt, firstBlockedAt, got2.BlockedReason)
	}

	// Unblock: active again, blocked state wiped.
	resp3 := doJSON(t, http.MethodPost, ts.URL+"/v1/admin/accounts/"+a.ID+"/unblock", adminToken, "")
	resp3.Body.Close()
	if resp3.StatusCode != http.StatusOK {
		t.Fatalf("unblock status = %d, want 200", resp3.StatusCode)
	}
	got3, _ := store.GetAccountByID(a.ID)
	if got3.Status != AccountActive || got3.BlockedAt != nil || got3.BlockedReason != "" {
		t.Fatalf("account after unblock = %+v", got3)
	}
	// Idempotent unblock.
	resp4 := doJSON(t, http.MethodPost, ts.URL+"/v1/admin/accounts/"+a.ID+"/unblock", adminToken, "")
	resp4.Body.Close()
	if resp4.StatusCode != http.StatusOK {
		t.Fatalf("re-unblock status = %d, want 200", resp4.StatusCode)
	}

	// Unknown account -> 404.
	for _, p := range []string{"/block", "/unblock"} {
		resp := doJSON(t, http.MethodPost, ts.URL+"/v1/admin/accounts/nope"+p, adminToken, `{}`)
		resp.Body.Close()
		if resp.StatusCode != http.StatusNotFound {
			t.Fatalf("%s unknown account status = %d, want 404", p, resp.StatusCode)
		}
	}

	// Audit: 2 blocks + 2 unblocks.
	if n, _ := store.CountAdminAudit("account.block"); n != 2 {
		t.Fatalf("account.block audit rows = %d, want 2", n)
	}
	if n, _ := store.CountAdminAudit("account.unblock"); n != 2 {
		t.Fatalf("account.unblock audit rows = %d, want 2", n)
	}
}

// TestAdminBlockRefusesSignin is the M1-gate integration: with INVITE_SIGNUP
// ON, an admin block makes that account's next sign-in (device-code enroll)
// refuse with outcome=blocked; unblock lets it through again.
func TestAdminBlockRefusesSignin(t *testing.T) {
	f := newFakeIssuer(t)
	ts, store, g := newAdminOIDCServer(t, f, func(c *Config) {
		c.InviteSignup = true
		c.AdminSubs = []string{"admin-sub-1"}
	})
	adminToken := mint(t, f.key, claimsFor(f, "admin-sub-1", "admin@example.com"))

	victim, err := store.CreateAccount("sub-victim", "victim@example.com", "")
	if err != nil {
		t.Fatalf("seed account: %v", err)
	}

	// Baseline: the account signs in fine (returning-owner path, no code).
	start := enrollStartCode(t, ts, "victim-box", "")
	status, body := approveAndPoll(t, ts, f, g, start, claimsFor(f, "sub-victim", "victim@example.com"))
	if status != http.StatusOK || body["status"] != "complete" {
		t.Fatalf("baseline enroll = %d %v, want 200 complete", status, body)
	}

	// Admin blocks the account over HTTP.
	resp := doJSON(t, http.MethodPost, ts.URL+"/v1/admin/accounts/"+victim.ID+"/block", adminToken, `{"reason":"abuse"}`)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("block status = %d, want 200", resp.StatusCode)
	}

	// The next sign-in is refused, audited as blocked.
	start2 := enrollStartCode(t, ts, "victim-box-2", "")
	status2, body2 := approveAndPoll(t, ts, f, g, start2, claimsFor(f, "sub-victim", "victim@example.com"))
	if status2 != http.StatusForbidden || body2["status"] != "rejected" {
		t.Fatalf("blocked enroll = %d %v, want 403 rejected", status2, body2)
	}
	if n, _ := store.CountSigninAttempts(outcomeBlocked); n != 1 {
		t.Fatalf("blocked attempts = %d, want 1", n)
	}

	// Unblock -> allowed again.
	resp2 := doJSON(t, http.MethodPost, ts.URL+"/v1/admin/accounts/"+victim.ID+"/unblock", adminToken, "")
	resp2.Body.Close()
	if resp2.StatusCode != http.StatusOK {
		t.Fatalf("unblock status = %d, want 200", resp2.StatusCode)
	}
	start3 := enrollStartCode(t, ts, "victim-box-3", "")
	status3, body3 := approveAndPoll(t, ts, f, g, start3, claimsFor(f, "sub-victim", "victim@example.com"))
	if status3 != http.StatusOK || body3["status"] != "complete" {
		t.Fatalf("post-unblock enroll = %d %v, want 200 complete", status3, body3)
	}
}

// TestAdminDeleteAccountRevokesDevices: DELETE removes the account AND its
// devices — both the sub-owned one and a legacy email-fallback one — revoking
// their tokens (401 on agent endpoints afterwards) and severing the live
// control connection. A repeat delete reports deleted=false.
func TestAdminDeleteAccountRevokesDevices(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	ts, adminToken, store := newAdminTestServer(t, "dev")

	a, err := store.CreateAccount("sub-x", "x@example.com", "")
	if err != nil {
		t.Fatalf("seed account: %v", err)
	}
	_, tok1, err := store.CreateDevice("x@example.com", "sub-x", "box-sub")
	if err != nil {
		t.Fatalf("seed sub device: %v", err)
	}
	// Legacy device: email-only ownership (empty sub) — must be deleted too.
	_, tok2, err := store.CreateDevice("x@example.com", "", "box-legacy")
	if err != nil {
		t.Fatalf("seed legacy device: %v", err)
	}

	// Bring the sub-owned device online to prove the kick.
	control, _, err := websocket.Dial(ctx, wsURL(ts.URL, "/v1/agent/control"), &websocket.DialOptions{
		HTTPHeader: bearerHeader(tok1),
	})
	if err != nil {
		t.Fatalf("agent control dial: %v", err)
	}
	defer control.CloseNow()

	resp := doJSON(t, http.MethodDelete, ts.URL+"/v1/admin/accounts/"+a.ID, adminToken, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("delete status = %d, want 200", resp.StatusCode)
	}
	body := decodeJSONBody(t, resp)
	if body["deleted"] != true || body["devices_deleted"] != float64(2) {
		t.Fatalf("delete response = %v, want deleted=true devices_deleted=2", body)
	}

	// Account row is gone.
	if got, _ := store.GetAccountByID(a.ID); got != nil {
		t.Fatalf("account still exists after delete: %+v", got)
	}

	// The live control connection was severed.
	readCtx, readCancel := context.WithTimeout(ctx, 5*time.Second)
	defer readCancel()
	if _, _, err := control.Read(readCtx); err == nil {
		t.Fatalf("expected control read to fail after account delete (kicked)")
	}

	// Both device tokens are revoked: 401 on the agent surface.
	for name, tok := range map[string]string{"sub-owned": tok1, "legacy": tok2} {
		_, dialResp, err := websocket.Dial(ctx, wsURL(ts.URL, "/v1/agent/control"), &websocket.DialOptions{
			HTTPHeader: bearerHeader(tok),
		})
		if err == nil {
			t.Fatalf("%s: expected dial with revoked token to fail", name)
		}
		if dialResp == nil || dialResp.StatusCode != http.StatusUnauthorized {
			got := 0
			if dialResp != nil {
				got = dialResp.StatusCode
			}
			t.Fatalf("%s revoked-token status = %d, want 401", name, got)
		}
	}

	// Audit row written.
	if n, _ := store.CountAdminAudit("account.delete"); n != 1 {
		t.Fatalf("account.delete audit rows = %d, want 1", n)
	}

	// Repeat delete: the end state already holds — 200 deleted=false, no
	// second audit row.
	resp2 := doJSON(t, http.MethodDelete, ts.URL+"/v1/admin/accounts/"+a.ID, adminToken, "")
	body2 := decodeJSONBody(t, resp2)
	if resp2.StatusCode != http.StatusOK || body2["deleted"] != false {
		t.Fatalf("repeat delete = %d %v, want 200 deleted=false", resp2.StatusCode, body2)
	}
	if n, _ := store.CountAdminAudit("account.delete"); n != 1 {
		t.Fatalf("audit rows after no-op delete = %d, want still 1", n)
	}
}

// generatedCodeRE is the required shape of a generated invite code:
// XXXX-XXXX from the unambiguous alphabet (no 0/O/1/I/L).
var generatedCodeRE = regexp.MustCompile(`^[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{4}-[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{4}$`)

// TestGenerateInviteCodeShape: the generator only ever emits the documented
// human-typable shape.
func TestGenerateInviteCodeShape(t *testing.T) {
	for i := 0; i < 200; i++ {
		code, err := generateInviteCode()
		if err != nil {
			t.Fatalf("generate: %v", err)
		}
		if !generatedCodeRE.MatchString(code) {
			t.Fatalf("generated code %q does not match %v", code, generatedCodeRE)
		}
	}
}

// TestAdminInviteLifecycle: create (explicit + generated) -> list -> revoke
// round-trip, incl. duplicate-code 409, validation 400s, consumability of a
// created code, and audit rows for every mutation.
func TestAdminInviteLifecycle(t *testing.T) {
	ts, adminToken, store := newAdminTestServer(t, "dev")

	// Explicit code with max_uses + expiry + note.
	exp := time.Now().Add(24 * time.Hour).UTC().Truncate(time.Second)
	resp := doJSON(t, http.MethodPost, ts.URL+"/v1/admin/invites", adminToken,
		`{"code":"BETA-2026","max_uses":5,"expires_at":"`+exp.Format(time.RFC3339)+`","note":"beta wave 1"}`)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create explicit status = %d, want 201", resp.StatusCode)
	}
	created := decodeJSONBody(t, resp)["invite"].(map[string]any)
	if created["code"] != "BETA-2026" || created["max_uses"] != float64(5) || created["note"] != "beta wave 1" {
		t.Fatalf("created invite = %+v", created)
	}
	// created_by carries the acting admin's sub.
	if created["created_by"] != "dev" {
		t.Fatalf("created_by = %v, want dev", created["created_by"])
	}

	// The created code is actually consumable by the sign-up machinery.
	if outcome, err := store.ValidateAndConsumeInvite("BETA-2026"); err != nil || outcome != InviteOK {
		t.Fatalf("consume created code: outcome=%v err=%v", outcome, err)
	}

	// Generated code: empty body -> XXXX-XXXX shape.
	resp2 := doJSON(t, http.MethodPost, ts.URL+"/v1/admin/invites", adminToken, `{"note":"generated"}`)
	if resp2.StatusCode != http.StatusCreated {
		t.Fatalf("create generated status = %d, want 201", resp2.StatusCode)
	}
	genCode := decodeJSONBody(t, resp2)["invite"].(map[string]any)["code"].(string)
	if !generatedCodeRE.MatchString(genCode) {
		t.Fatalf("generated code %q does not match %v", genCode, generatedCodeRE)
	}

	// Duplicate explicit code -> 409.
	resp3 := doJSON(t, http.MethodPost, ts.URL+"/v1/admin/invites", adminToken, `{"code":"BETA-2026"}`)
	resp3.Body.Close()
	if resp3.StatusCode != http.StatusConflict {
		t.Fatalf("duplicate create status = %d, want 409", resp3.StatusCode)
	}

	// Bad max_uses -> 400.
	resp4 := doJSON(t, http.MethodPost, ts.URL+"/v1/admin/invites", adminToken, `{"max_uses":0}`)
	resp4.Body.Close()
	if resp4.StatusCode != http.StatusBadRequest {
		t.Fatalf("max_uses=0 status = %d, want 400", resp4.StatusCode)
	}

	// List: both codes with their state (uses=1 on the consumed one).
	resp5 := doJSON(t, http.MethodGet, ts.URL+"/v1/admin/invites", adminToken, "")
	if resp5.StatusCode != http.StatusOK {
		t.Fatalf("list status = %d, want 200", resp5.StatusCode)
	}
	var listOut struct {
		Invites []InviteCode `json:"invites"`
	}
	func() {
		defer resp5.Body.Close()
		if err := json.NewDecoder(resp5.Body).Decode(&listOut); err != nil {
			t.Fatalf("decode invites: %v", err)
		}
	}()
	if len(listOut.Invites) != 2 {
		t.Fatalf("list = %d invites, want 2", len(listOut.Invites))
	}
	byCode := map[string]InviteCode{}
	for _, ic := range listOut.Invites {
		byCode[ic.Code] = ic
	}
	beta := byCode["BETA-2026"]
	if beta.Uses != 1 || beta.MaxUses == nil || *beta.MaxUses != 5 || beta.ExpiresAt == nil || beta.RevokedAt != nil {
		t.Fatalf("listed BETA-2026 = %+v", beta)
	}
	if gen := byCode[genCode]; gen.MaxUses != nil || gen.ExpiresAt != nil || gen.Note != "generated" {
		t.Fatalf("listed generated = %+v", gen)
	}

	// Revoke -> 204; the code is dead for sign-up; revoked_at visible in list.
	resp6 := doJSON(t, http.MethodDelete, ts.URL+"/v1/admin/invites/BETA-2026", adminToken, "")
	resp6.Body.Close()
	if resp6.StatusCode != http.StatusNoContent {
		t.Fatalf("revoke status = %d, want 204", resp6.StatusCode)
	}
	if outcome, _ := store.ValidateAndConsumeInvite("BETA-2026"); outcome != InviteRevoked {
		t.Fatalf("consume after revoke = %v, want InviteRevoked", outcome)
	}
	ic, _ := store.GetInviteCode("BETA-2026")
	if ic == nil || ic.RevokedAt == nil {
		t.Fatalf("revoked_at not set: %+v", ic)
	}
	// Idempotent repeat revoke.
	resp7 := doJSON(t, http.MethodDelete, ts.URL+"/v1/admin/invites/BETA-2026", adminToken, "")
	resp7.Body.Close()
	if resp7.StatusCode != http.StatusNoContent {
		t.Fatalf("repeat revoke status = %d, want 204", resp7.StatusCode)
	}

	// Audit: 2 creates (explicit + generated) + 2 revokes.
	if n, _ := store.CountAdminAudit("invite.create"); n != 2 {
		t.Fatalf("invite.create audit rows = %d, want 2", n)
	}
	if n, _ := store.CountAdminAudit("invite.revoke"); n != 2 {
		t.Fatalf("invite.revoke audit rows = %d, want 2", n)
	}
}

// TestAdminAccountUsage covers the usage summary: devices with count,
// sign-in outcome counts (incl. pre-account attempts matched by sub), and a
// 404 for an unknown account. Richer usage is M4/M5 (usage_events).
func TestAdminAccountUsage(t *testing.T) {
	ts, adminToken, store := newAdminTestServer(t, "dev")

	a, _ := store.CreateAccount("sub-u", "u@example.com", "")
	if _, _, err := store.CreateDevice("u@example.com", "sub-u", "u-box"); err != nil {
		t.Fatalf("seed device: %v", err)
	}
	base := time.Date(2026, 7, 2, 8, 0, 0, 0, time.UTC)
	// Pre-account refusal (no account_id, matched by sub) + two allowed.
	seedAttempt(t, store, base, "u@example.com", "sub-u", outcomeNoAccount, "")
	seedAttempt(t, store, base.Add(time.Hour), "u@example.com", "sub-u", outcomeAllowed, a.ID)
	seedAttempt(t, store, base.Add(2*time.Hour), "u@example.com", "sub-u", outcomeAllowed, a.ID)
	// Noise for someone else — must not leak into the summary.
	seedAttempt(t, store, base, "other@example.com", "sub-other", outcomeAllowed, "acct-other")

	resp := doJSON(t, http.MethodGet, ts.URL+"/v1/admin/accounts/"+a.ID+"/usage", adminToken, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("usage status = %d, want 200", resp.StatusCode)
	}
	body := decodeJSONBody(t, resp)

	if body["device_count"] != float64(1) {
		t.Fatalf("device_count = %v, want 1", body["device_count"])
	}
	devs := body["devices"].([]any)
	if len(devs) != 1 || devs[0].(map[string]any)["name"] != "u-box" {
		t.Fatalf("devices = %+v", devs)
	}
	counts := body["signin_attempts"].(map[string]any)
	if counts[outcomeAllowed] != float64(2) || counts[outcomeNoAccount] != float64(1) {
		t.Fatalf("signin_attempts = %+v, want allowed=2 no_account=1", counts)
	}
	acct := body["account"].(map[string]any)
	if acct["id"] != a.ID || acct["google_sub"] != "sub-u" {
		t.Fatalf("account = %+v", acct)
	}

	// Unknown account -> 404.
	resp2 := doJSON(t, http.MethodGet, ts.URL+"/v1/admin/accounts/nope/usage", adminToken, "")
	resp2.Body.Close()
	if resp2.StatusCode != http.StatusNotFound {
		t.Fatalf("unknown usage status = %d, want 404", resp2.StatusCode)
	}
}

// TestMigration0003RoundTrip proves 0003 goes Up -> Down -> Up cleanly (the
// Down path exercises SQLite DROP COLUMN through modernc.org/sqlite).
func TestMigration0003RoundTrip(t *testing.T) {
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

	hasIsAdmin := func() bool {
		var n int
		if err := db.QueryRow(
			`SELECT COUNT(*) FROM pragma_table_info('accounts') WHERE name = 'is_admin'`,
		).Scan(&n); err != nil {
			t.Fatalf("pragma_table_info: %v", err)
		}
		return n > 0
	}
	hasAuditTable := func() bool {
		var n int
		if err := db.QueryRow(
			`SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'admin_audit'`,
		).Scan(&n); err != nil {
			t.Fatalf("sqlite_master: %v", err)
		}
		return n > 0
	}

	// Up: everything applied.
	if err := goose.Up(db, "."); err != nil {
		t.Fatalf("goose up: %v", err)
	}
	if !hasIsAdmin() || !hasAuditTable() {
		t.Fatalf("after up: is_admin=%v admin_audit=%v, want both", hasIsAdmin(), hasAuditTable())
	}
	// Data survives the flag column across the round trip below.
	if _, err := db.Exec(
		`INSERT INTO accounts (id, google_sub, email, status, created_at) VALUES ('a1','s1','e@x.com','active',?)`,
		time.Now().UTC(),
	); err != nil {
		t.Fatalf("seed account: %v", err)
	}

	// Down to 0002: 0003 reverted (and any later migrations — M4 added 0004,
	// so a single relative Down would only revert THAT), 0002 intact.
	if err := goose.DownTo(db, ".", 2); err != nil {
		t.Fatalf("goose down to 0002: %v", err)
	}
	if hasIsAdmin() || hasAuditTable() {
		t.Fatalf("after down: is_admin=%v admin_audit=%v, want neither", hasIsAdmin(), hasAuditTable())
	}
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM accounts`).Scan(&n); err != nil || n != 1 {
		t.Fatalf("accounts after down = %d (err %v), want 1 (DROP COLUMN must keep rows)", n, err)
	}

	// Up again: clean re-apply.
	if err := goose.Up(db, "."); err != nil {
		t.Fatalf("goose re-up: %v", err)
	}
	if !hasIsAdmin() || !hasAuditTable() {
		t.Fatalf("after re-up: is_admin=%v admin_audit=%v, want both", hasIsAdmin(), hasAuditTable())
	}
	var isAdmin int
	if err := db.QueryRow(`SELECT is_admin FROM accounts WHERE id = 'a1'`).Scan(&isAdmin); err != nil || isAdmin != 0 {
		t.Fatalf("re-added is_admin default = %d (err %v), want 0", isAdmin, err)
	}
}
