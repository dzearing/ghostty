package main

// M1 integration tests for the invite-code sign-in gate (INVITE_SIGNUP=ON),
// driven end-to-end through the device-code enroll flow against the fake
// issuer. They prove the §4 cutover behavior: a fresh account needs a valid
// code; blocked accounts are refused; existing and legacy owners keep working
// without a code; every attempt is audited with the right outcome.
//
// The flag-OFF path is unchanged and already covered by the existing enroll
// tests (which wire no gate), so these focus on the ON path.

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// newInviteSignupServer wires the full relay with INVITE_SIGNUP=ON and the
// gate bound, against the fake issuer + fake Google device flow. ALLOWED_EMAILS
// is deliberately EMPTY so the tests prove the account model (not the
// allowlist) is doing the authorizing. Returns the server, store, and the fake
// device flow to steer approvals.
func newInviteSignupServer(t *testing.T, f *fakeIssuer) (*httptest.Server, *Store, *fakeGoogleDeviceFlow) {
	t.Helper()

	g := newFakeGoogleDeviceFlow(f)

	cfg := &Config{
		ListenAddr:         "127.0.0.1:0",
		StateDir:           t.TempDir(),
		GoogleClientID:     testClientID,
		GoogleClientSecret: "test-client-secret",
		IssuerURL:          f.srv.URL,
		AllowedEmails:      nil, // empty on purpose: the account model gates now
		RelayBaseURL:       "https://relay.test",
		InviteSignup:       true,
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

// claimsFor returns a valid claim set for a specific (sub, email), so tests can
// enroll distinct identities.
func claimsFor(f *fakeIssuer, sub, email string) map[string]any {
	c := f.validClaims()
	c["sub"] = sub
	c["email"] = email
	return c
}

// enrollStartCode POSTs /v1/enroll/start with an optional invite_code and
// decodes the response.
func enrollStartCode(t *testing.T, ts *httptest.Server, name, code string) enrollStartResponse {
	t.Helper()
	body := `{"name":"` + name + `"}`
	if code != "" {
		body = `{"name":"` + name + `","invite_code":"` + code + `"}`
	}
	resp := doJSON(t, http.MethodPost, ts.URL+"/v1/enroll/start", "", body)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("enroll start status = %d, want 200", resp.StatusCode)
	}
	var out enrollStartResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode enroll start: %v", err)
	}
	return out
}

// approveAndPoll approves the grant for start.UserCode with the given claims,
// then polls once and returns (status, body).
func approveAndPoll(t *testing.T, ts *httptest.Server, f *fakeIssuer, g *fakeGoogleDeviceFlow, start enrollStartResponse, claims map[string]any) (int, map[string]any) {
	t.Helper()
	g.setOutcome(t, start.UserCode, "approved", mint(t, f.key, claims))
	return enrollPoll(t, ts, start.DeviceCodeHandle)
}

// TestInviteSignupFreshNoCodeRejected: a brand-new identity (no account, not a
// legacy owner) with NO invite code is rejected, and the attempt is logged as
// no_account.
func TestInviteSignupFreshNoCodeRejected(t *testing.T) {
	f := newFakeIssuer(t)
	ts, store, g := newInviteSignupServer(t, f)

	start := enrollStartCode(t, ts, "newbox", "")
	status, body := approveAndPoll(t, ts, f, g, start, claimsFor(f, "sub-new", "new@example.com"))

	if status != http.StatusForbidden || body["status"] != "rejected" {
		t.Fatalf("no-code enroll = %d %v, want 403 rejected", status, body)
	}
	if a, _ := store.GetAccountBySub("sub-new"); a != nil {
		t.Fatalf("no account should have been created, got %+v", a)
	}
	if n, _ := store.CountSigninAttempts(outcomeNoAccount); n != 1 {
		t.Fatalf("no_account attempts = %d, want 1", n)
	}
}

// TestInviteSignupFreshWithCodeAccepted: a valid code lets a fresh identity in,
// creates an active account stamped with invited_by_code, increments the code's
// uses, and logs an allowed attempt.
func TestInviteSignupFreshWithCodeAccepted(t *testing.T) {
	f := newFakeIssuer(t)
	ts, store, g := newInviteSignupServer(t, f)
	if err := store.CreateInviteCode("GOLDEN", ptrInt(1), nil, "beta"); err != nil {
		t.Fatalf("create code: %v", err)
	}

	start := enrollStartCode(t, ts, "newbox", "GOLDEN")
	status, body := approveAndPoll(t, ts, f, g, start, claimsFor(f, "sub-new", "new@example.com"))

	if status != http.StatusOK || body["status"] != "complete" {
		t.Fatalf("coded enroll = %d %v, want 200 complete", status, body)
	}
	a, _ := store.GetAccountBySub("sub-new")
	if a == nil || a.Status != AccountActive || a.InvitedByCode != "GOLDEN" {
		t.Fatalf("account not created correctly: %+v", a)
	}
	if n, _ := store.InviteUses("GOLDEN"); n != 1 {
		t.Fatalf("code uses = %d, want 1", n)
	}
	if n, _ := store.CountSigninAttempts(outcomeAllowed); n != 1 {
		t.Fatalf("allowed attempts = %d, want 1", n)
	}
}

// TestInviteSignupBadCodeOutcomes: exhausted, expired, and revoked codes are
// each rejected with their specific audited outcome, and no account is made.
func TestInviteSignupBadCodeOutcomes(t *testing.T) {
	cases := []struct {
		name    string
		setup   func(s *Store) string // returns the code to use
		outcome string
	}{
		{"exhausted", func(s *Store) string {
			_ = s.CreateInviteCode("EX", ptrInt(1), nil, "")
			_, _ = s.ValidateAndConsumeInvite("EX") // burn the only use
			return "EX"
		}, outcomeExhaustedInvite},
		{"expired", func(s *Store) string {
			past := time.Now().Add(-time.Hour)
			_ = s.CreateInviteCode("EXP", nil, &past, "")
			return "EXP"
		}, outcomeExpiredInvite},
		{"revoked", func(s *Store) string {
			_ = s.CreateInviteCode("REV", nil, nil, "")
			_ = s.RevokeInviteCode("REV")
			return "REV"
		}, outcomeRevokedInvite},
		{"unknown", func(s *Store) string { return "NOSUCH" }, outcomeBadInvite},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newFakeIssuer(t)
			ts, store, g := newInviteSignupServer(t, f)
			code := tc.setup(store)

			start := enrollStartCode(t, ts, "box", code)
			status, body := approveAndPoll(t, ts, f, g, start, claimsFor(f, "sub-x", "x@example.com"))

			if status != http.StatusForbidden || body["status"] != "rejected" {
				t.Fatalf("%s enroll = %d %v, want 403 rejected", tc.name, status, body)
			}
			if a, _ := store.GetAccountBySub("sub-x"); a != nil {
				t.Fatalf("%s: no account should exist, got %+v", tc.name, a)
			}
			if n, _ := store.CountSigninAttempts(tc.outcome); n != 1 {
				t.Fatalf("%s: %s attempts = %d, want 1", tc.name, tc.outcome, n)
			}
		})
	}
}

// TestInviteSignupBlockedAccountRefused: an existing but blocked account is
// refused (even with a valid code lying around) and the attempt is audited
// blocked.
func TestInviteSignupBlockedAccountRefused(t *testing.T) {
	f := newFakeIssuer(t)
	ts, store, g := newInviteSignupServer(t, f)

	// Seed a blocked account for this sub.
	a, err := store.CreateAccount("sub-blk", "blocked@example.com", "")
	if err != nil {
		t.Fatalf("seed account: %v", err)
	}
	if _, err := store.db.Exec(
		`UPDATE accounts SET status = ?, blocked_at = ?, blocked_reason = ? WHERE id = ?`,
		AccountBlocked, time.Now().UTC(), "abuse", a.ID,
	); err != nil {
		t.Fatalf("block account: %v", err)
	}

	start := enrollStartCode(t, ts, "box", "")
	status, body := approveAndPoll(t, ts, f, g, start, claimsFor(f, "sub-blk", "blocked@example.com"))

	if status != http.StatusForbidden || body["status"] != "rejected" {
		t.Fatalf("blocked enroll = %d %v, want 403 rejected", status, body)
	}
	if n, _ := store.CountSigninAttempts(outcomeBlocked); n != 1 {
		t.Fatalf("blocked attempts = %d, want 1", n)
	}
}

// TestInviteSignupExistingOwnerNoCode: an identity with an existing active
// account keeps enrolling with NO invite code (the returning-owner path), and
// the attempt is audited allowed.
func TestInviteSignupExistingOwnerNoCode(t *testing.T) {
	f := newFakeIssuer(t)
	ts, store, g := newInviteSignupServer(t, f)

	if _, err := store.CreateAccount("sub-ret", "returning@example.com", "OLDCODE"); err != nil {
		t.Fatalf("seed account: %v", err)
	}

	start := enrollStartCode(t, ts, "box", "") // no code
	status, body := approveAndPoll(t, ts, f, g, start, claimsFor(f, "sub-ret", "returning@example.com"))

	if status != http.StatusOK || body["status"] != "complete" {
		t.Fatalf("returning-owner enroll = %d %v, want 200 complete", status, body)
	}
	if n, _ := store.CountSigninAttempts(outcomeAllowed); n != 1 {
		t.Fatalf("allowed attempts = %d, want 1", n)
	}
}

// TestInviteSignupLegacyOwnerMigrated: THE invariant — an owner who predates
// accounts (a device with empty owner_sub matching their email) signs in with
// the flag ON, NO invite code, is allowed, gets an account lazily bound to
// their sub, and their legacy device becomes sub-owned. Proves dzearing@ won't
// be locked out at cutover.
func TestInviteSignupLegacyOwnerMigrated(t *testing.T) {
	f := newFakeIssuer(t)
	ts, store, g := newInviteSignupServer(t, f)

	// Simulate a pre-accounts device: owned by email only, no sub.
	if _, _, err := store.CreateDevice("dzearing@example.com", "", "legacy-mac"); err != nil {
		t.Fatalf("seed legacy device: %v", err)
	}

	start := enrollStartCode(t, ts, "another-box", "") // no code!
	status, body := approveAndPoll(t, ts, f, g, start, claimsFor(f, "sub-dz", "dzearing@example.com"))

	if status != http.StatusOK || body["status"] != "complete" {
		t.Fatalf("legacy-owner enroll = %d %v, want 200 complete (must not lock out)", status, body)
	}
	// An account now exists for the bound sub.
	a, _ := store.GetAccountBySub("sub-dz")
	if a == nil || a.Status != AccountActive {
		t.Fatalf("legacy owner account not created/active: %+v", a)
	}
	// Their legacy device is now sub-owned (backfilled).
	if store.HasLegacyDeviceForEmail("dzearing@example.com") {
		t.Fatalf("legacy device should have been stamped with the sub")
	}
	owner := Identity{Email: "dzearing@example.com", Sub: "sub-dz"}
	if devs := store.ListByOwnerIdent(owner); len(devs) != 2 {
		// legacy-mac (backfilled) + another-box (just enrolled)
		t.Fatalf("legacy owner sees %d devices, want 2", len(devs))
	}
	if n, _ := store.CountSigninAttempts(outcomeAllowed); n != 1 {
		t.Fatalf("allowed attempts = %d, want 1", n)
	}
}
