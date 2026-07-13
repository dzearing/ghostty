package main

// M1 store-level tests: invite-code validate/consume (incl. the concurrency
// race), account CRUD, the legacy email->sub bind, sign-in attempt logging,
// and cross-account device isolation keyed on google_sub with the legacy
// email fallback. No HTTP/OIDC here — the sign-in gate integration lives in
// invite_signup_test.go.

import (
	"io"
	"log/slog"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// newStore opens a fresh SQLite-backed store in a temp dir (no legacy JSON).
func newStore(t *testing.T) *Store {
	t.Helper()
	dir := t.TempDir()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	s, err := LoadStore(filepath.Join(dir, "ghoztty-relay.db"), filepath.Join(dir, "devices.json"), logger)
	if err != nil {
		t.Fatalf("LoadStore: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func ptrInt(n int) *int { return &n }

// TestInviteValidateConsume covers the happy path and each refusal outcome,
// asserting both the typed outcome and the use-count side effect.
func TestInviteValidateConsume(t *testing.T) {
	s := newStore(t)

	// Unlimited code: consumes forever, uses increments each time.
	if err := s.CreateInviteCode("UNLIMITED", nil, nil, "n"); err != nil {
		t.Fatalf("create unlimited: %v", err)
	}
	for i := 1; i <= 3; i++ {
		if o, err := s.ValidateAndConsumeInvite("UNLIMITED"); err != nil || o != InviteOK {
			t.Fatalf("unlimited consume #%d = %v,%v want OK", i, o, err)
		}
	}
	if n, _ := s.InviteUses("UNLIMITED"); n != 3 {
		t.Fatalf("unlimited uses = %d, want 3", n)
	}

	// Capped code: OK until exhausted, then InviteExhausted.
	if err := s.CreateInviteCode("CAP2", ptrInt(2), nil, ""); err != nil {
		t.Fatalf("create cap2: %v", err)
	}
	if o, _ := s.ValidateAndConsumeInvite("CAP2"); o != InviteOK {
		t.Fatalf("cap2 use1 = %v, want OK", o)
	}
	if o, _ := s.ValidateAndConsumeInvite("CAP2"); o != InviteOK {
		t.Fatalf("cap2 use2 = %v, want OK", o)
	}
	if o, _ := s.ValidateAndConsumeInvite("CAP2"); o != InviteExhausted {
		t.Fatalf("cap2 use3 = %v, want Exhausted", o)
	}
	if n, _ := s.InviteUses("CAP2"); n != 2 {
		t.Fatalf("cap2 uses = %d, want 2 (exhausted consume must not increment)", n)
	}

	// Unknown code -> InviteBad.
	if o, _ := s.ValidateAndConsumeInvite("NOPE"); o != InviteBad {
		t.Fatalf("unknown = %v, want Bad", o)
	}

	// Expired code -> InviteExpired, no increment.
	past := time.Now().Add(-time.Hour)
	if err := s.CreateInviteCode("EXPIRED", nil, &past, ""); err != nil {
		t.Fatalf("create expired: %v", err)
	}
	if o, _ := s.ValidateAndConsumeInvite("EXPIRED"); o != InviteExpired {
		t.Fatalf("expired = %v, want Expired", o)
	}
	if n, _ := s.InviteUses("EXPIRED"); n != 0 {
		t.Fatalf("expired uses = %d, want 0", n)
	}

	// Revoked code -> InviteRevoked, no increment.
	if err := s.CreateInviteCode("REVOKED", nil, nil, ""); err != nil {
		t.Fatalf("create revoked: %v", err)
	}
	if err := s.RevokeInviteCode("REVOKED"); err != nil {
		t.Fatalf("revoke: %v", err)
	}
	if o, _ := s.ValidateAndConsumeInvite("REVOKED"); o != InviteRevoked {
		t.Fatalf("revoked = %v, want Revoked", o)
	}
	if n, _ := s.InviteUses("REVOKED"); n != 0 {
		t.Fatalf("revoked uses = %d, want 0", n)
	}
}

// TestInviteConsumeRaceSafe hammers a capped code from many goroutines and
// asserts EXACTLY max_uses consumers succeed — proving the check+increment is
// race-safe (run under -race for the full guarantee).
func TestInviteConsumeRaceSafe(t *testing.T) {
	s := newStore(t)
	const cap = 5
	const goroutines = 50
	if err := s.CreateInviteCode("RACE", ptrInt(cap), nil, ""); err != nil {
		t.Fatalf("create: %v", err)
	}

	var wg sync.WaitGroup
	var mu sync.Mutex
	oks := 0
	for i := 0; i < goroutines; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			o, err := s.ValidateAndConsumeInvite("RACE")
			if err != nil {
				t.Errorf("consume err: %v", err)
				return
			}
			if o == InviteOK {
				mu.Lock()
				oks++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()

	if oks != cap {
		t.Fatalf("race: %d successful consumes, want exactly %d", oks, cap)
	}
	if n, _ := s.InviteUses("RACE"); n != cap {
		t.Fatalf("race: uses = %d, want %d", n, cap)
	}
}

// TestAccountCRUD covers create/lookup-by-sub, the no-account signal, blocked
// status readback, and the duplicate-sub guard.
func TestAccountCRUD(t *testing.T) {
	s := newStore(t)

	if a, err := s.GetAccountBySub("ghost"); err != nil || a != nil {
		t.Fatalf("lookup of unknown sub = %v,%v want nil,nil", a, err)
	}

	a, err := s.CreateAccount("sub-1", "User@Example.com", "CODE1")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if a.Status != AccountActive || a.Email != "user@example.com" || a.InvitedByCode != "CODE1" {
		t.Fatalf("account fields wrong: %+v", a)
	}

	got, err := s.GetAccountBySub("sub-1")
	if err != nil || got == nil || got.ID != a.ID {
		t.Fatalf("lookup by sub = %v,%v want the created account", got, err)
	}

	// Duplicate sub is refused (UNIQUE).
	if _, err := s.CreateAccount("sub-1", "other@example.com", ""); err == nil {
		t.Fatalf("duplicate google_sub should fail")
	}
}

// TestRecordSigninAttempt proves attempts persist with their outcome and are
// countable (the admin feed's data source).
func TestRecordSigninAttempt(t *testing.T) {
	s := newStore(t)
	for _, o := range []string{outcomeAllowed, outcomeAllowed, outcomeBlocked, outcomeNoAccount} {
		if err := s.RecordSigninAttempt("a@b.com", "sub", "1.2.3.4", o, ""); err != nil {
			t.Fatalf("record %s: %v", o, err)
		}
	}
	if n, _ := s.CountSigninAttempts(""); n != 4 {
		t.Fatalf("total attempts = %d, want 4", n)
	}
	if n, _ := s.CountSigninAttempts(outcomeAllowed); n != 2 {
		t.Fatalf("allowed attempts = %d, want 2", n)
	}
}

// TestOwnershipIsolationBySub proves two accounts never see each other's
// devices — including the legacy (empty-sub) row reached by the email
// fallback. This is the load-bearing authz property of the M1 sub cutover.
func TestOwnershipIsolationBySub(t *testing.T) {
	s := newStore(t)

	alice := Identity{Email: "alice@example.com", Sub: "sub-alice"}
	bob := Identity{Email: "bob@example.com", Sub: "sub-bob"}

	// Alice owns a sub-stamped device.
	da, _, err := s.CreateDevice(alice.Email, alice.Sub, "alice-box")
	if err != nil {
		t.Fatalf("create alice dev: %v", err)
	}
	// Bob owns a sub-stamped device.
	db, _, err := s.CreateDevice(bob.Email, bob.Sub, "bob-box")
	if err != nil {
		t.Fatalf("create bob dev: %v", err)
	}
	// Alice ALSO owns a LEGACY device (empty sub) — reachable only by the
	// email fallback.
	dl, _, err := s.CreateDevice(alice.Email, "", "alice-legacy")
	if err != nil {
		t.Fatalf("create alice legacy dev: %v", err)
	}

	// Alice sees her two devices (sub-stamped + legacy), never Bob's.
	aliceDevs := s.ListByOwnerIdent(alice)
	if len(aliceDevs) != 2 {
		t.Fatalf("alice sees %d devices, want 2: %+v", len(aliceDevs), aliceDevs)
	}
	for _, d := range aliceDevs {
		if d.ID == db.ID {
			t.Fatalf("alice can see bob's device %s", db.ID)
		}
	}

	// Bob sees exactly his one device, never Alice's (sub or legacy).
	bobDevs := s.ListByOwnerIdent(bob)
	if len(bobDevs) != 1 || bobDevs[0].ID != db.ID {
		t.Fatalf("bob sees %+v, want only %s", bobDevs, db.ID)
	}

	// Bob cannot rename or delete Alice's sub-stamped device.
	if d, _ := s.RenameDeviceByOwner(da.ID, bob, "stolen"); d != nil {
		t.Fatalf("bob renamed alice's sub-device")
	}
	if ok, _ := s.DeleteDeviceByOwner(da.ID, bob); ok {
		t.Fatalf("bob deleted alice's sub-device")
	}
	// Bob cannot touch Alice's LEGACY device either (email fallback must not
	// leak across accounts — bob's email differs).
	if d, _ := s.RenameDeviceByOwner(dl.ID, bob, "stolen"); d != nil {
		t.Fatalf("bob renamed alice's legacy device")
	}
	if ok, _ := s.DeleteDeviceByOwner(dl.ID, bob); ok {
		t.Fatalf("bob deleted alice's legacy device")
	}

	// The OwnedBy predicate agrees.
	if !da.OwnedBy(alice) || da.OwnedBy(bob) {
		t.Fatalf("OwnedBy(sub) wrong for alice's sub device")
	}
	if !dl.OwnedBy(alice) || dl.OwnedBy(bob) {
		t.Fatalf("OwnedBy(email fallback) wrong for alice's legacy device")
	}

	// Alice CAN rename her own legacy device via the email fallback.
	if d, _ := s.RenameDeviceByOwner(dl.ID, alice, "renamed-legacy"); d == nil || d.Name != "renamed-legacy" {
		t.Fatalf("alice could not rename her own legacy device")
	}
}

// TestBindLegacyDevicesToSub proves the legacy-owner migration primitive:
// stamping a sub onto empty-sub rows flips their ownership to sub-keyed while
// leaving other owners untouched.
func TestBindLegacyDevicesToSub(t *testing.T) {
	s := newStore(t)

	// Two legacy devices for the same email, one for a different email.
	_, _, _ = s.CreateDevice("legacy@example.com", "", "box1")
	_, _, _ = s.CreateDevice("legacy@example.com", "", "box2")
	_, _, _ = s.CreateDevice("other@example.com", "", "otherbox")

	if !s.HasLegacyDeviceForEmail("legacy@example.com") {
		t.Fatalf("expected legacy devices for legacy@example.com")
	}

	if err := s.BindLegacyDevicesToSub("legacy@example.com", "sub-legacy"); err != nil {
		t.Fatalf("bind: %v", err)
	}

	// After binding, they are sub-owned and no longer "legacy".
	if s.HasLegacyDeviceForEmail("legacy@example.com") {
		t.Fatalf("legacy devices should be sub-stamped now")
	}
	owner := Identity{Email: "legacy@example.com", Sub: "sub-legacy"}
	if devs := s.ListByOwnerIdent(owner); len(devs) != 2 {
		t.Fatalf("sub owner sees %d devices, want 2", len(devs))
	}
	// The other email's legacy device is untouched.
	if !s.HasLegacyDeviceForEmail("other@example.com") {
		t.Fatalf("bind must not touch other owners' legacy devices")
	}
}

// TestSigninAttemptThrottle covers the credential-keyed allowed-row throttle
// (same token re-presented within the interval -> one DB row; a FRESH token
// records immediately; failures always recorded) and the allowlist-path
// RecordLegacy audit rows, including nil-gate safety.
func TestSigninAttemptThrottle(t *testing.T) {
	s := newStore(t)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	g := NewSigninGate(&Config{InviteSignup: true}, s, logger)
	ident := Identity{Email: "user@example.com", Sub: "sub-1"}
	fpA := tokenFingerprint("token-A")

	// Same credential re-presented (API polling) -> exactly one row.
	g.recordAllowedThrottled(ident, "1.2.3.4", "acct-1", fpA)
	g.recordAllowedThrottled(ident, "1.2.3.4", "acct-1", fpA)
	g.recordAllowedThrottled(ident, "1.2.3.4", "acct-1", fpA)
	if n, _ := s.CountSigninAttempts(outcomeAllowed); n != 1 {
		t.Fatalf("allowed rows = %d, want 1 (same-token throttled)", n)
	}

	// A FRESH credential (real login) records immediately, no interval wait.
	g.recordAllowedThrottled(ident, "1.2.3.4", "acct-1", tokenFingerprint("token-B"))
	if n, _ := s.CountSigninAttempts(outcomeAllowed); n != 2 {
		t.Fatalf("allowed rows = %d, want 2 (fresh token records immediately)", n)
	}

	// A different identity gets its own row.
	g.recordAllowedThrottled(Identity{Email: "other@example.com", Sub: "sub-2"}, "1.2.3.4", "acct-2", fpA)
	if n, _ := s.CountSigninAttempts(outcomeAllowed); n != 3 {
		t.Fatalf("allowed rows = %d, want 3 (per identity)", n)
	}

	// Failures are never throttled.
	g.record(ident, "1.2.3.4", outcomeBlocked, "acct-1")
	g.record(ident, "1.2.3.4", outcomeBlocked, "acct-1")
	if n, _ := s.CountSigninAttempts(outcomeBlocked); n != 2 {
		t.Fatalf("blocked rows = %d, want 2 (unthrottled)", n)
	}

	// Allowlist path: shares the same per-identity throttle state — the same
	// credential last marked above is suppressed, a fresh one records.
	g.RecordLegacy(ident, "1.2.3.4", true, tokenFingerprint("token-B"))
	if n, _ := s.CountSigninAttempts(outcomeAllowlistAllowed); n != 0 {
		t.Fatalf("allowlist_allowed rows = %d, want 0 (same token suppressed)", n)
	}
	fresh := Identity{Email: "legacy@example.com"} // no sub -> email key
	fpL := tokenFingerprint("legacy-token")
	g.RecordLegacy(fresh, "5.6.7.8", true, fpL)
	g.RecordLegacy(fresh, "5.6.7.8", true, fpL)
	if n, _ := s.CountSigninAttempts(outcomeAllowlistAllowed); n != 1 {
		t.Fatalf("allowlist_allowed rows = %d, want 1", n)
	}
	g.RecordLegacy(fresh, "5.6.7.8", false, "")
	g.RecordLegacy(fresh, "5.6.7.8", false, "")
	if n, _ := s.CountSigninAttempts(outcomeAllowlistRejected); n != 2 {
		t.Fatalf("allowlist_rejected rows = %d, want 2 (unthrottled)", n)
	}

	// Nil gate: never panics, never records (gate-less unit-test Authenticators).
	var nilGate *SigninGate
	nilGate.RecordLegacy(ident, "1.2.3.4", true, fpA)
	nilGate.RecordLegacy(ident, "1.2.3.4", false, "")
}

// TestSigninAttemptThrottleExpiry proves the clock expires even for the SAME
// credential: back-date the mark and a new row is due on re-presentation.
func TestSigninAttemptThrottleExpiry(t *testing.T) {
	s := newStore(t)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	g := NewSigninGate(&Config{InviteSignup: true}, s, logger)
	ident := Identity{Email: "user@example.com", Sub: "sub-1"}
	fp := tokenFingerprint("token-A")

	g.recordAllowedThrottled(ident, "", "a", fp)
	g.mu.Lock()
	g.lastAllowed[throttleKey(ident)] = allowedMark{fp: fp, t: time.Now().Add(-allowedLogInterval - time.Minute)}
	g.mu.Unlock()
	g.recordAllowedThrottled(ident, "", "a", fp)
	if n, _ := s.CountSigninAttempts(outcomeAllowed); n != 2 {
		t.Fatalf("allowed rows = %d, want 2 after interval expiry", n)
	}
}
