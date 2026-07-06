package main

// Integration tests for the runtime signup mode (settings.go), end-to-end
// through the device-code enroll flow against the fake issuer — the same
// harness as invite_signup_test.go — plus the /v1/admin/settings surface:
//
//   - open:   a fresh verified identity gets an account with NO invite code
//   - invite: SIGNUP_MODE=invite behaves exactly like the M1 flag
//             (invite_signup_test.go covers the INVITE_SIGNUP=true seed)
//   - closed: fresh identities are refused (outcome signup_closed) even with
//             a valid code in hand; existing accounts keep working
//   - blocked accounts are refused in EVERY mode
//   - PUT /v1/admin/settings flips live behavior with no restart (the
//     in-process cache bust), returns the new state, and writes an audit row
//
// The admin auth sweep for the settings routes lives in admin_test.go
// (adminRoutes) alongside every other admin endpoint.

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// newSignupModeServer wires the full relay against the fake issuer with the
// given signup-mode seed (as if SIGNUP_MODE were set), mirroring main.go's
// wiring. ALLOWED_EMAILS stays empty: the account model must do the work.
func newSignupModeServer(t *testing.T, f *fakeIssuer, mode string, mutate func(*Config)) (*httptest.Server, *Store, *fakeGoogleDeviceFlow) {
	t.Helper()
	return newAdminOIDCServer(t, f, func(c *Config) {
		c.SignupMode = mode
		if mutate != nil {
			mutate(c)
		}
	})
}

// TestSignupModeOpenCreatesAccount: in open mode a brand-new verified
// identity (no account, not a legacy owner, NO invite code) is allowed and
// gets an active account with no invited_by_code, audited as allowed.
func TestSignupModeOpenCreatesAccount(t *testing.T) {
	f := newFakeIssuer(t)
	ts, store, g := newSignupModeServer(t, f, "open", nil)

	start := enrollStartCode(t, ts, "openbox", "") // no code!
	status, body := approveAndPoll(t, ts, f, g, start, claimsFor(f, "sub-open", "open@example.com"))

	if status != http.StatusOK || body["status"] != "complete" {
		t.Fatalf("open-mode enroll = %d %v, want 200 complete", status, body)
	}
	a, _ := store.GetAccountBySub("sub-open")
	if a == nil || a.Status != AccountActive || a.InvitedByCode != "" {
		t.Fatalf("open-mode account not created correctly: %+v", a)
	}
	if n, _ := store.CountSigninAttempts(outcomeAllowed); n != 1 {
		t.Fatalf("allowed attempts = %d, want 1", n)
	}
}

// TestSignupModeInviteViaEnvRequiresCode: SIGNUP_MODE=invite behaves exactly
// like the M1 invite model — a fresh identity with no code is refused
// (no_account) and a valid code lets them in.
func TestSignupModeInviteViaEnvRequiresCode(t *testing.T) {
	f := newFakeIssuer(t)
	ts, store, g := newSignupModeServer(t, f, "invite", nil)

	start := enrollStartCode(t, ts, "box", "")
	status, body := approveAndPoll(t, ts, f, g, start, claimsFor(f, "sub-inv", "inv@example.com"))
	if status != http.StatusForbidden || body["status"] != "rejected" {
		t.Fatalf("no-code enroll = %d %v, want 403 rejected", status, body)
	}
	if n, _ := store.CountSigninAttempts(outcomeNoAccount); n != 1 {
		t.Fatalf("no_account attempts = %d, want 1", n)
	}

	if err := store.CreateInviteCode("LETMEIN", ptrInt(1), nil, ""); err != nil {
		t.Fatalf("create code: %v", err)
	}
	start2 := enrollStartCode(t, ts, "box", "LETMEIN")
	status2, body2 := approveAndPoll(t, ts, f, g, start2, claimsFor(f, "sub-inv", "inv@example.com"))
	if status2 != http.StatusOK || body2["status"] != "complete" {
		t.Fatalf("coded enroll = %d %v, want 200 complete", status2, body2)
	}
	if a, _ := store.GetAccountBySub("sub-inv"); a == nil || a.InvitedByCode != "LETMEIN" {
		t.Fatalf("invite account not created correctly: %+v", a)
	}
}

// TestSignupModeClosed: fresh identities are refused with outcome
// signup_closed — even holding a VALID invite code, which must not be
// consumed — while an existing account keeps signing in.
func TestSignupModeClosed(t *testing.T) {
	f := newFakeIssuer(t)
	ts, store, g := newSignupModeServer(t, f, "closed", nil)

	// A valid code exists, but closed means closed: refused, code untouched.
	if err := store.CreateInviteCode("GOLDEN", ptrInt(1), nil, ""); err != nil {
		t.Fatalf("create code: %v", err)
	}
	start := enrollStartCode(t, ts, "box", "GOLDEN")
	status, body := approveAndPoll(t, ts, f, g, start, claimsFor(f, "sub-cls", "cls@example.com"))
	if status != http.StatusForbidden || body["status"] != "rejected" {
		t.Fatalf("closed-mode fresh enroll = %d %v, want 403 rejected", status, body)
	}
	if a, _ := store.GetAccountBySub("sub-cls"); a != nil {
		t.Fatalf("no account should exist in closed mode, got %+v", a)
	}
	if n, _ := store.CountSigninAttempts(outcomeSignupClosed); n != 1 {
		t.Fatalf("signup_closed attempts = %d, want 1", n)
	}
	if n, _ := store.InviteUses("GOLDEN"); n != 0 {
		t.Fatalf("code uses = %d, want 0 (closed mode must not consume)", n)
	}

	// An existing account still signs in (closed gates NEW signups only).
	if _, err := store.CreateAccount("sub-old", "old@example.com", ""); err != nil {
		t.Fatalf("seed account: %v", err)
	}
	start2 := enrollStartCode(t, ts, "oldbox", "")
	status2, body2 := approveAndPoll(t, ts, f, g, start2, claimsFor(f, "sub-old", "old@example.com"))
	if status2 != http.StatusOK || body2["status"] != "complete" {
		t.Fatalf("closed-mode existing-account enroll = %d %v, want 200 complete", status2, body2)
	}
}

// TestSignupModeBlockedRejectedEveryMode: a blocked account is refused in
// open, invite, AND closed modes — blocking outranks every signup policy.
func TestSignupModeBlockedRejectedEveryMode(t *testing.T) {
	for _, mode := range []string{"open", "invite", "closed"} {
		t.Run(mode, func(t *testing.T) {
			f := newFakeIssuer(t)
			ts, store, g := newSignupModeServer(t, f, mode, nil)

			a, err := store.CreateAccount("sub-blk", "blk@example.com", "")
			if err != nil {
				t.Fatalf("seed account: %v", err)
			}
			if _, err := store.BlockAccount(a.ID, "abuse"); err != nil {
				t.Fatalf("block account: %v", err)
			}

			start := enrollStartCode(t, ts, "box", "")
			status, body := approveAndPoll(t, ts, f, g, start, claimsFor(f, "sub-blk", "blk@example.com"))
			if status != http.StatusForbidden || body["status"] != "rejected" {
				t.Fatalf("[%s] blocked enroll = %d %v, want 403 rejected", mode, status, body)
			}
			if n, _ := store.CountSigninAttempts(outcomeBlocked); n != 1 {
				t.Fatalf("[%s] blocked attempts = %d, want 1", mode, n)
			}
		})
	}
}

// TestAdminSettingsLiveFlip: THE product ask — the mode is changed at runtime
// from the admin API and sign-in behavior flips on the very next request,
// no restart. Also covers the GET shape (mode + source), PUT validation, and
// the settings.update audit row.
func TestAdminSettingsLiveFlip(t *testing.T) {
	f := newFakeIssuer(t)
	// Seeded like today's planned prod: INVITE_SIGNUP=true, no SIGNUP_MODE.
	ts, store, g := newAdminOIDCServer(t, f, func(c *Config) {
		c.InviteSignup = true
		c.AdminSubs = []string{"admin-sub-live"}
	})
	adminToken := mint(t, f.key, claimsFor(f, "admin-sub-live", "admin@example.com"))

	// GET: the env seed governs (invite / env-default).
	resp := doJSON(t, http.MethodGet, ts.URL+"/v1/admin/settings", adminToken, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET settings status = %d, want 200", resp.StatusCode)
	}
	got := decodeJSONBody(t, resp)
	if got["signup_mode"] != "invite" || got["source"] != "env-default" {
		t.Fatalf("GET settings = %v, want invite/env-default", got)
	}

	// Before the flip: a fresh identity with no code is refused (invite mode).
	start := enrollStartCode(t, ts, "box", "")
	status, _ := approveAndPoll(t, ts, f, g, start, claimsFor(f, "sub-flip", "flip@example.com"))
	if status != http.StatusForbidden {
		t.Fatalf("pre-flip enroll status = %d, want 403", status)
	}

	// PUT garbage -> 400, nothing changes.
	respBad := doJSON(t, http.MethodPut, ts.URL+"/v1/admin/settings", adminToken, `{"signup_mode":"everyone"}`)
	respBad.Body.Close()
	if respBad.StatusCode != http.StatusBadRequest {
		t.Fatalf("PUT invalid mode status = %d, want 400", respBad.StatusCode)
	}

	// PUT open -> the DB row now governs.
	resp2 := doJSON(t, http.MethodPut, ts.URL+"/v1/admin/settings", adminToken, `{"signup_mode":"open"}`)
	if resp2.StatusCode != http.StatusOK {
		t.Fatalf("PUT settings status = %d, want 200", resp2.StatusCode)
	}
	got2 := decodeJSONBody(t, resp2)
	if got2["signup_mode"] != "open" || got2["source"] != "db" {
		t.Fatalf("PUT settings = %v, want open/db", got2)
	}

	// Immediately after (same process, no restart): the same fresh identity
	// is let in and gets an account — the cache bust made the flip live.
	start2 := enrollStartCode(t, ts, "box", "")
	status2, body2 := approveAndPoll(t, ts, f, g, start2, claimsFor(f, "sub-flip", "flip@example.com"))
	if status2 != http.StatusOK || body2["status"] != "complete" {
		t.Fatalf("post-flip enroll = %d %v, want 200 complete", status2, body2)
	}
	if a, _ := store.GetAccountBySub("sub-flip"); a == nil || a.InvitedByCode != "" {
		t.Fatalf("post-flip account not created correctly: %+v", a)
	}

	// GET reflects the DB-governed state.
	resp3 := doJSON(t, http.MethodGet, ts.URL+"/v1/admin/settings", adminToken, "")
	got3 := decodeJSONBody(t, resp3)
	if got3["signup_mode"] != "open" || got3["source"] != "db" {
		t.Fatalf("GET after PUT = %v, want open/db", got3)
	}

	// Exactly one audit row, carrying old -> new.
	if n, err := store.CountAdminAudit("settings.update"); err != nil || n != 1 {
		t.Fatalf("settings.update audit rows = %d (err %v), want 1", n, err)
	}
	var detail string
	if err := store.db.QueryRow(
		`SELECT detail FROM admin_audit WHERE action = 'settings.update'`,
	).Scan(&detail); err != nil {
		t.Fatalf("read audit detail: %v", err)
	}
	if detail != `{"new":"open","old":"invite"}` {
		t.Fatalf("audit detail = %s, want old invite -> new open", detail)
	}
}
