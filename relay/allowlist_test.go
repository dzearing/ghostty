package main

// Tests for the DB-backed sign-in allowlist (allowlist.go + migration 0006 +
// admin_allowlist.go). Coverage:
//   - Store CRUD: lowercasing, list order, typed duplicate, remove semantics.
//   - The gate's short-TTL cache: a direct DB write is NOT seen inside the
//     TTL; BustAllowlistCache makes it visible immediately (the property the
//     admin add/remove handlers rely on).
//   - Fake-issuer integration: the env ∪ DB union gates sign-in in allowlist
//     mode — a DB-added email is allowed WITHOUT a restart, removal rejects
//     on the next request, and the env-listed owner is allowed even with an
//     empty table. Plus the addendum behaviors: an allowed allowlist-path
//     sign-in ensures an ACCOUNT ROW exists (fresh create + legacy-owner bind
//     with the sub stamped onto legacy devices, no duplicates on repeat), and
//     a BLOCKED account is refused in allowlist mode (unblock restores).
//   - Admin API validation: 400 invalid email/oversize note, 409 duplicate /
//     env-listed add / env-entry delete, audit rows for every mutation and
//     none for refusals, and the GET union shape with source labels.
//   - Migration 0006 round-trips Up -> DownTo(5) -> Up (pinned, never
//     relative — merge-composition note in the progress doc).
// The 401/403 auth sweep for the three routes lives in admin_test.go
// (adminRoutes), alongside every other admin endpoint.

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/dzearing/ghoztty-relay/migrations"
	"github.com/pressly/goose/v3"
)

func TestAllowlistStoreCRUD(t *testing.T) {
	s := newStore(t)

	// Empty table lists empty.
	if rows, err := s.ListAllowedEmails(); err != nil || len(rows) != 0 {
		t.Fatalf("initial list = %v, %v; want empty, nil", rows, err)
	}

	// Add lowercases + trims.
	if err := s.AddAllowedEmail("  Friend@Example.COM ", "college friend"); err != nil {
		t.Fatalf("AddAllowedEmail: %v", err)
	}
	got, err := s.GetAllowedEmail("friend@example.com")
	if err != nil || got == nil {
		t.Fatalf("GetAllowedEmail = %v, %v; want row", got, err)
	}
	if got.Email != "friend@example.com" || got.Note != "college friend" || got.CreatedAt.IsZero() {
		t.Fatalf("row = %+v, want lowercased email + note + created_at", got)
	}

	// Duplicate (any casing) -> the typed conflict.
	if err := s.AddAllowedEmail("FRIEND@example.com", ""); !errors.Is(err, ErrAllowlistDuplicate) {
		t.Fatalf("duplicate add err = %v, want ErrAllowlistDuplicate", err)
	}
	// Empty email refused.
	if err := s.AddAllowedEmail("   ", ""); err == nil {
		t.Fatalf("AddAllowedEmail(blank) should error")
	}

	// List is alphabetical.
	if err := s.AddAllowedEmail("aaa@example.com", ""); err != nil {
		t.Fatalf("AddAllowedEmail: %v", err)
	}
	rows, err := s.ListAllowedEmails()
	if err != nil || len(rows) != 2 {
		t.Fatalf("list = %v, %v; want 2 rows", rows, err)
	}
	if rows[0].Email != "aaa@example.com" || rows[1].Email != "friend@example.com" {
		t.Fatalf("list order = [%s, %s], want alphabetical", rows[0].Email, rows[1].Email)
	}

	// Remove: true once, false after (end state already holds).
	if removed, err := s.RemoveAllowedEmail("Friend@Example.com"); err != nil || !removed {
		t.Fatalf("remove = %v, %v; want true, nil", removed, err)
	}
	if removed, err := s.RemoveAllowedEmail("friend@example.com"); err != nil || removed {
		t.Fatalf("repeat remove = %v, %v; want false, nil", removed, err)
	}
	if got, _ := s.GetAllowedEmail("friend@example.com"); got != nil {
		t.Fatalf("row still present after remove: %+v", got)
	}
}

// TestAllowlistCacheAndBust: membership is served from the gate's short-TTL
// cache (a direct DB write is deliberately not seen yet); BustAllowlistCache
// makes it visible immediately — what the admin mutation handlers rely on.
func TestAllowlistCacheAndBust(t *testing.T) {
	store := newStore(t)
	g := newGate(t, &Config{}, store)

	// Prime the cache with the empty set.
	if g.AllowlistedInDB("late@example.com") {
		t.Fatalf("empty table should not allow")
	}

	// A direct DB write is NOT seen within the TTL — that's the cache working.
	if err := store.AddAllowedEmail("late@example.com", ""); err != nil {
		t.Fatalf("AddAllowedEmail: %v", err)
	}
	if g.AllowlistedInDB("late@example.com") {
		t.Fatalf("direct db write visible inside the TTL — cache not working")
	}

	// The bust makes it visible immediately.
	g.BustAllowlistCache()
	if !g.AllowlistedInDB("late@example.com") {
		t.Fatalf("bust did not make the new row visible")
	}

	// Same for removal.
	if _, err := store.RemoveAllowedEmail("late@example.com"); err != nil {
		t.Fatalf("RemoveAllowedEmail: %v", err)
	}
	if !g.AllowlistedInDB("late@example.com") {
		t.Fatalf("removal visible inside the TTL — cache not working")
	}
	g.BustAllowlistCache()
	if g.AllowlistedInDB("late@example.com") {
		t.Fatalf("bust did not make the removal visible")
	}

	// Nil-gate safety: env-only behavior for gate-less unit tests.
	var nilGate *SigninGate
	if nilGate.AllowlistedInDB("late@example.com") {
		t.Fatalf("nil gate must report false")
	}
	nilGate.BustAllowlistCache() // must not panic
}

// clientDevicesStatus signs in on the user surface (GET /v1/client/devices —
// the AuthenticateClient path) with a freshly minted ID token for (sub,
// email) and returns the HTTP status. A fresh token per call keeps the
// allowed-row audit throttle out of the way.
func clientDevicesStatus(t *testing.T, ts *httptest.Server, f *fakeIssuer, sub, email string) int {
	t.Helper()
	// Sign in via the brokered /oauth/exchange (it runs the allowlist/account
	// gate + mints a session), then exercise the client surface with the
	// session token. A rejected sign-in yields no token → the client call 401s,
	// preserving the original allowed→200 / rejected→401 contract.
	token := sessionToken(t, ts, f, claimsFor(f, sub, email))
	resp := doJSON(t, http.MethodGet, ts.URL+"/v1/client/devices", token, "")
	resp.Body.Close()
	return resp.StatusCode
}

// TestAllowlistUnionGatesSignin is the product ask end-to-end: in allowlist
// mode the EFFECTIVE list is env ∪ DB — an admin adds an email from the API
// and it signs in on the very next request (no restart), removal rejects on
// the next request, and the env-listed owner keeps working even with an
// empty table. Mutations are audited; the GET union carries source labels.
func TestAllowlistUnionGatesSignin(t *testing.T) {
	f := newFakeIssuer(t)
	// Default mode (no SIGNUP_MODE, no INVITE_SIGNUP) = allowlist.
	ts, store, _ := newAdminOIDCServer(t, f, func(c *Config) {
		c.AllowedEmails = []string{allowedEmail}
		c.AdminSubs = []string{"admin-sub-al"}
	})
	adminToken := mint(t, f.key, claimsFor(f, "admin-sub-al", "admin@example.com"))

	// The env-listed owner signs in with an EMPTY allowed_emails table.
	if got := clientDevicesStatus(t, ts, f, testSub, allowedEmail); got != http.StatusOK {
		t.Fatalf("env email with empty table status = %d, want 200", got)
	}
	// A stranger is rejected and audited.
	if got := clientDevicesStatus(t, ts, f, "sub-stranger", "stranger@example.com"); got != http.StatusUnauthorized {
		t.Fatalf("stranger status = %d, want 401", got)
	}
	if n, _ := store.CountSigninAttempts(outcomeAllowlistRejected); n != 1 {
		t.Fatalf("allowlist_rejected attempts = %d, want 1", n)
	}

	// Admin adds an email -> 201 with the db-sourced entry.
	resp := doJSON(t, http.MethodPost, ts.URL+"/v1/admin/allowlist", adminToken,
		`{"email":"Newbie@Example.com","note":"beta friend"}`)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("add status = %d, want 201", resp.StatusCode)
	}
	created := decodeJSONBody(t, resp)["email"].(map[string]any)
	if created["email"] != "newbie@example.com" || created["source"] != "db" ||
		created["note"] != "beta friend" || created["created_at"] == nil {
		t.Fatalf("created entry = %+v", created)
	}

	// The added email is allowed on the VERY NEXT request — same process, no
	// restart (the handler's cache bust).
	if got := clientDevicesStatus(t, ts, f, "sub-newbie", "newbie@example.com"); got != http.StatusOK {
		t.Fatalf("db-added email status = %d, want 200", got)
	}
	// ...and the allowed sign-in ensured an account record (addendum: accounts
	// exist as records in every mode).
	acct, err := store.GetAccountBySub("sub-newbie")
	if err != nil || acct == nil || acct.Status != AccountActive || acct.InvitedByCode != "" {
		t.Fatalf("allowlist-mode account = %+v (err %v), want active account with no code", acct, err)
	}

	// GET: the union with source labels — env entry first, then the db row.
	respList := doJSON(t, http.MethodGet, ts.URL+"/v1/admin/allowlist", adminToken, "")
	if respList.StatusCode != http.StatusOK {
		t.Fatalf("list status = %d, want 200", respList.StatusCode)
	}
	var listOut struct {
		Emails []struct {
			Email     string `json:"email"`
			Source    string `json:"source"`
			Note      string `json:"note"`
			CreatedAt string `json:"created_at"`
		} `json:"emails"`
	}
	func() {
		defer respList.Body.Close()
		if err := json.NewDecoder(respList.Body).Decode(&listOut); err != nil {
			t.Fatalf("decode list: %v", err)
		}
	}()
	if len(listOut.Emails) != 2 {
		t.Fatalf("list = %d entries, want 2 (env + db)", len(listOut.Emails))
	}
	if e := listOut.Emails[0]; e.Email != allowedEmail || e.Source != "env" || e.Note != "" || e.CreatedAt != "" {
		t.Fatalf("env entry = %+v, want bare env-sourced %s", e, allowedEmail)
	}
	if e := listOut.Emails[1]; e.Email != "newbie@example.com" || e.Source != "db" || e.Note != "beta friend" || e.CreatedAt == "" {
		t.Fatalf("db entry = %+v", e)
	}

	// Remove -> rejected on the next request (cache busted in-process).
	respDel := doJSON(t, http.MethodDelete, ts.URL+"/v1/admin/allowlist/newbie@example.com", adminToken, "")
	if respDel.StatusCode != http.StatusOK {
		t.Fatalf("remove status = %d, want 200", respDel.StatusCode)
	}
	if body := decodeJSONBody(t, respDel); body["removed"] != true {
		t.Fatalf("remove body = %v, want removed=true", body)
	}
	if got := clientDevicesStatus(t, ts, f, "sub-newbie", "newbie@example.com"); got != http.StatusUnauthorized {
		t.Fatalf("removed email status = %d, want 401", got)
	}

	// The env-listed owner is STILL allowed — the table is empty again.
	if got := clientDevicesStatus(t, ts, f, testSub, allowedEmail); got != http.StatusOK {
		t.Fatalf("env email after removal status = %d, want 200", got)
	}

	// One audit row per mutation.
	if n, _ := store.CountAdminAudit("allowlist.add"); n != 1 {
		t.Fatalf("allowlist.add audit rows = %d, want 1", n)
	}
	if n, _ := store.CountAdminAudit("allowlist.remove"); n != 1 {
		t.Fatalf("allowlist.remove audit rows = %d, want 1", n)
	}
}

// TestAllowlistAdminValidation covers the refusal paths: invalid email and
// oversize note (400), duplicate add / env-listed add / env-entry delete
// (409, the latter with the env-managed explanation), unknown delete
// (200 removed=false) — and no audit rows for any refusal.
func TestAllowlistAdminValidation(t *testing.T) {
	f := newFakeIssuer(t)
	ts, store, _ := newAdminOIDCServer(t, f, func(c *Config) {
		c.AllowedEmails = []string{allowedEmail}
		c.AdminSubs = []string{"admin-sub-val"}
	})
	adminToken := mint(t, f.key, claimsFor(f, "admin-sub-val", "admin@example.com"))

	// Invalid emails -> 400.
	for _, body := range []string{
		`{"email":"not-an-email"}`,
		`{"email":""}`,
		`{"email":"a b@example.com"}`,
		`{"email":"Jane Doe <jane@example.com>"}`,
		`not json`,
	} {
		resp := doJSON(t, http.MethodPost, ts.URL+"/v1/admin/allowlist", adminToken, body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("POST %s status = %d, want 400", body, resp.StatusCode)
		}
	}
	// Oversize note -> 400.
	resp := doJSON(t, http.MethodPost, ts.URL+"/v1/admin/allowlist", adminToken,
		`{"email":"ok@example.com","note":"`+strings.Repeat("x", maxAllowlistNoteLen+1)+`"}`)
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("oversize note status = %d, want 400", resp.StatusCode)
	}

	// Duplicate DB row -> 409.
	if err := store.AddAllowedEmail("dupe@example.com", ""); err != nil {
		t.Fatalf("seed row: %v", err)
	}
	resp2 := doJSON(t, http.MethodPost, ts.URL+"/v1/admin/allowlist", adminToken, `{"email":"DUPE@example.com"}`)
	resp2.Body.Close()
	if resp2.StatusCode != http.StatusConflict {
		t.Fatalf("duplicate add status = %d, want 409", resp2.StatusCode)
	}

	// Env-listed add -> 409 (the env half is not portal-managed).
	resp3 := doJSON(t, http.MethodPost, ts.URL+"/v1/admin/allowlist", adminToken,
		`{"email":"`+allowedEmail+`"}`)
	resp3.Body.Close()
	if resp3.StatusCode != http.StatusConflict {
		t.Fatalf("env-listed add status = %d, want 409", resp3.StatusCode)
	}

	// Env-entry delete -> 409 with the env-managed explanation.
	resp4 := doJSON(t, http.MethodDelete, ts.URL+"/v1/admin/allowlist/"+allowedEmail, adminToken, "")
	if resp4.StatusCode != http.StatusConflict {
		t.Fatalf("env delete status = %d, want 409", resp4.StatusCode)
	}
	buf := make([]byte, 512)
	n, _ := resp4.Body.Read(buf)
	resp4.Body.Close()
	if !strings.Contains(string(buf[:n]), "ALLOWED_EMAILS") {
		t.Fatalf("env delete body = %q, want the env-managed explanation", string(buf[:n]))
	}

	// Unknown delete -> 200 removed=false (idempotent end state).
	resp5 := doJSON(t, http.MethodDelete, ts.URL+"/v1/admin/allowlist/ghost@example.com", adminToken, "")
	if resp5.StatusCode != http.StatusOK {
		t.Fatalf("unknown delete status = %d, want 200", resp5.StatusCode)
	}
	if body := decodeJSONBody(t, resp5); body["removed"] != false {
		t.Fatalf("unknown delete body = %v, want removed=false", body)
	}

	// No refusal produced an audit row.
	if n, _ := store.CountAdminAudit("allowlist.add"); n != 0 {
		t.Fatalf("allowlist.add audit rows = %d, want 0", n)
	}
	if n, _ := store.CountAdminAudit("allowlist.remove"); n != 0 {
		t.Fatalf("allowlist.remove audit rows = %d, want 0", n)
	}
}

// TestAllowlistModeLegacyOwnerBind (addendum): an allowlist-mode sign-in by a
// pre-account owner (a legacy device carrying only their email) binds them to
// an account — sub stamped onto the legacy device so the portal's device
// count is right — and repeat sign-ins never duplicate the account.
func TestAllowlistModeLegacyOwnerBind(t *testing.T) {
	f := newFakeIssuer(t)
	ts, store, _ := newAdminOIDCServer(t, f, func(c *Config) {
		c.AllowedEmails = []string{allowedEmail}
	})

	// The pre-account world: one device owned by email only.
	if _, _, err := store.CreateDevice(allowedEmail, "", "legacy-box"); err != nil {
		t.Fatalf("seed legacy device: %v", err)
	}

	// First allowlist-mode sign-in binds the legacy owner.
	if got := clientDevicesStatus(t, ts, f, testSub, allowedEmail); got != http.StatusOK {
		t.Fatalf("legacy owner sign-in status = %d, want 200", got)
	}
	acct, err := store.GetAccountBySub(testSub)
	if err != nil || acct == nil || acct.Email != allowedEmail || acct.InvitedByCode != "" {
		t.Fatalf("bound account = %+v (err %v)", acct, err)
	}
	if store.HasLegacyDeviceForEmail(allowedEmail) {
		t.Fatalf("legacy device not sub-stamped after bind")
	}

	// The portal's account list shows the owner WITH their machine count —
	// the product ask ("I want to see how many machines I have hooked up").
	summaries, err := store.ListAccounts("", "")
	if err != nil || len(summaries) != 1 {
		t.Fatalf("ListAccounts = %v (err %v), want the one bound account", summaries, err)
	}
	if summaries[0].GoogleSub != testSub || summaries[0].DeviceCount != 1 {
		t.Fatalf("account summary = sub %s count %d, want %s/1",
			summaries[0].GoogleSub, summaries[0].DeviceCount, testSub)
	}

	// Repeat sign-ins are idempotent: still exactly one account row.
	if got := clientDevicesStatus(t, ts, f, testSub, allowedEmail); got != http.StatusOK {
		t.Fatalf("repeat sign-in status = %d, want 200", got)
	}
	var n int
	if err := store.db.QueryRow(`SELECT COUNT(*) FROM accounts`).Scan(&n); err != nil || n != 1 {
		t.Fatalf("accounts rows = %d (err %v), want exactly 1", n, err)
	}
}

// TestAllowlistModeBlockedRefused (addendum): the admin's explicit block
// outranks the allowlist — a blocked account is refused in allowlist mode
// even though its email is env-listed (outcome `blocked`), and unblock
// restores access.
func TestAllowlistModeBlockedRefused(t *testing.T) {
	f := newFakeIssuer(t)
	ts, store, _ := newAdminOIDCServer(t, f, func(c *Config) {
		c.AllowedEmails = []string{allowedEmail}
	})

	// First sign-in creates the account record.
	if got := clientDevicesStatus(t, ts, f, testSub, allowedEmail); got != http.StatusOK {
		t.Fatalf("baseline sign-in status = %d, want 200", got)
	}
	acct, _ := store.GetAccountBySub(testSub)
	if acct == nil {
		t.Fatalf("no account record after allowlist-mode sign-in")
	}

	// Block -> refused despite the env listing, audited as blocked.
	if _, err := store.BlockAccount(acct.ID, "abuse"); err != nil {
		t.Fatalf("block: %v", err)
	}
	if got := clientDevicesStatus(t, ts, f, testSub, allowedEmail); got != http.StatusUnauthorized {
		t.Fatalf("blocked env-listed sign-in status = %d, want 401", got)
	}
	if n, _ := store.CountSigninAttempts(outcomeBlocked); n != 1 {
		t.Fatalf("blocked attempts = %d, want 1", n)
	}

	// Unblock -> allowed again.
	if _, err := store.UnblockAccount(acct.ID); err != nil {
		t.Fatalf("unblock: %v", err)
	}
	if got := clientDevicesStatus(t, ts, f, testSub, allowedEmail); got != http.StatusOK {
		t.Fatalf("post-unblock sign-in status = %d, want 200", got)
	}
}

// TestMigration0006RoundTrip proves 0006 goes Up -> Down -> Up cleanly.
// DownTo(5) is PINNED (never a relative Down — merge-composition note in the
// progress doc: a relative Down would revert whatever happens to be latest).
func TestMigration0006RoundTrip(t *testing.T) {
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

	hasAllowlist := func() bool {
		var n int
		if err := db.QueryRow(
			`SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'allowed_emails'`,
		).Scan(&n); err != nil {
			t.Fatalf("sqlite_master: %v", err)
		}
		return n > 0
	}

	if err := goose.Up(db, "."); err != nil {
		t.Fatalf("goose up: %v", err)
	}
	if !hasAllowlist() {
		t.Fatalf("after up: allowed_emails table missing")
	}

	if err := goose.DownTo(db, ".", 5); err != nil {
		t.Fatalf("goose down to 0005: %v", err)
	}
	if hasAllowlist() {
		t.Fatalf("after down: allowed_emails table still present")
	}

	if err := goose.Up(db, "."); err != nil {
		t.Fatalf("goose re-up: %v", err)
	}
	if !hasAllowlist() {
		t.Fatalf("after re-up: allowed_emails table missing")
	}
	// The re-created table is writable and keeps its default note.
	if _, err := db.Exec(
		`INSERT INTO allowed_emails (email, created_at) VALUES ('x@example.com', ?)`,
		time.Now().UTC(),
	); err != nil {
		t.Fatalf("insert after round-trip: %v", err)
	}
	var note string
	if err := db.QueryRow(`SELECT note FROM allowed_emails WHERE email = 'x@example.com'`).Scan(&note); err != nil || note != "" {
		t.Fatalf("default note = %q (err %v), want empty string", note, err)
	}
}
