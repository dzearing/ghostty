package main

// DB-backed sign-in allowlist (migration 0006): the `allowlist` signup mode's
// email gate becomes admin-manageable LIVE from the portal instead of a
// hardcoded env value. The EFFECTIVE allowlist is the UNION of:
//
//   - allowed_emails rows (source "db") — added/removed via /v1/admin/allowlist
//     (admin_allowlist.go), effective on the next request via an in-process
//     cache bust; and
//   - the ALLOWED_EMAILS env var (source "env") — demoted to a bootstrap/
//     recovery allowance, same pattern as ADMIN_SUBS and the signup_mode env
//     seed: always honored, never imported into the table, shown in the portal
//     distinctly labeled and immutable.
//
// The DB side is consulted through a short-TTL cache on the SigninGate
// (mirroring the signup-mode cache in settings.go): auth runs on every API
// request, so an uncached membership test would turn each request into an
// extra SQLite read. Fail-safe, never fail-open: a DB read error logs and
// falls back to the env set only — a wedged DB can neither admit strangers
// nor lock out the env-listed owner.
//
// The allowlist only GATES sign-in when the signup mode is `allowlist`
// (settings.go); the CRUD works in any mode so an admin can stage the list
// before switching modes.
//
// Account records in allowlist mode: an ALLOWED sign-in also ensures an
// account row exists for the identity (legacy-owner bind or create — the same
// logic as the account-model path), so the portal's Accounts page shows the
// owner and their device count in EVERY mode. And a BLOCKED account is
// refused even when its email is on the allowlist: the admin's explicit block
// outranks the env list (see AuthorizeAllowlisted).

import (
	"database/sql"
	"errors"
	"fmt"
	"net/mail"
	"strings"
	"time"
)

// ErrAllowlistDuplicate is the typed conflict for adding an email that is
// already an allowed_emails row. Callers map it to HTTP 409.
var ErrAllowlistDuplicate = errors.New("email already on the allowlist")

// allowlistTTL bounds how long the DB allowlist set is served from cache —
// same rationale and value as signupModeTTL (settings.go): effectively live
// (an admin change lands within seconds on other processes, instantly
// in-process via the mutation-path cache bust) at a cost of at most one
// SQLite read per interval.
const allowlistTTL = 5 * time.Second

// AllowedEmail is one allowed_emails row.
type AllowedEmail struct {
	Email     string
	Note      string
	CreatedAt time.Time
}

// --- Store layer ---------------------------------------------------------------

// ListAllowedEmails returns every allowed_emails row, alphabetically.
func (s *Store) ListAllowedEmails() ([]AllowedEmail, error) {
	rows, err := s.db.Query(
		`SELECT email, note, created_at FROM allowed_emails ORDER BY email ASC`,
	)
	if err != nil {
		return nil, fmt.Errorf("list allowed emails: %w", err)
	}
	defer rows.Close()

	var out []AllowedEmail
	for rows.Next() {
		var e AllowedEmail
		var created time.Time
		if err := rows.Scan(&e.Email, &e.Note, &created); err != nil {
			return nil, fmt.Errorf("scan allowed email: %w", err)
		}
		e.CreatedAt = created.UTC()
		out = append(out, e)
	}
	return out, rows.Err()
}

// GetAllowedEmail returns one row (email lowercased/trimmed by the caller or
// here — both are safe), or nil when the email has no row.
func (s *Store) GetAllowedEmail(email string) (*AllowedEmail, error) {
	email = strings.ToLower(strings.TrimSpace(email))
	var e AllowedEmail
	var created time.Time
	err := s.db.QueryRow(
		`SELECT email, note, created_at FROM allowed_emails WHERE email = ?`, email,
	).Scan(&e.Email, &e.Note, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("get allowed email: %w", err)
	}
	e.CreatedAt = created.UTC()
	return &e, nil
}

// AddAllowedEmail inserts one allowlist row. The email is lowercased and
// trimmed (membership checks compare lowercased). A duplicate returns the
// typed ErrAllowlistDuplicate so the admin API can answer 409.
func (s *Store) AddAllowedEmail(email, note string) error {
	email = strings.ToLower(strings.TrimSpace(email))
	if email == "" {
		return fmt.Errorf("add allowed email: empty email")
	}
	if _, err := s.db.Exec(
		`INSERT INTO allowed_emails (email, note, created_at) VALUES (?, ?, ?)`,
		email, note, time.Now().UTC(),
	); err != nil {
		if isUniqueViolation(err) {
			return ErrAllowlistDuplicate
		}
		return fmt.Errorf("add allowed email: %w", err)
	}
	return nil
}

// RemoveAllowedEmail deletes one allowlist row and reports whether a row was
// actually removed (false = no such row; the desired end state already held).
func (s *Store) RemoveAllowedEmail(email string) (bool, error) {
	email = strings.ToLower(strings.TrimSpace(email))
	res, err := s.db.Exec(`DELETE FROM allowed_emails WHERE email = ?`, email)
	if err != nil {
		return false, fmt.Errorf("remove allowed email: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("remove allowed email: %w", err)
	}
	return n > 0, nil
}

// --- Cached membership (on the SigninGate, which owns cfg + store) ---------------

// AllowlistedInDB reports whether email (lowercased by the caller) has an
// allowed_emails row, via the short-TTL cache. Nil-gate safe: a gate-less
// Authenticator (some unit tests) gets false — env-only, exactly the pre-DB
// behavior.
func (g *SigninGate) AllowlistedInDB(email string) bool {
	if g == nil || g.store == nil {
		return false
	}
	return g.dbAllowlist()[email]
}

// dbAllowlist returns the cached DB allowlist set, re-reading on expiry. A
// read failure logs and yields the empty set (env-only fallback — fail-safe,
// not fail-open); the empty result is cached for the TTL so a wedged DB is
// not hammered on every request.
func (g *SigninGate) dbAllowlist() map[string]bool {
	now := time.Now()
	g.alMu.Lock()
	if g.alSet != nil && now.Before(g.alExp) {
		set := g.alSet
		g.alMu.Unlock()
		return set
	}
	g.alMu.Unlock()

	rows, err := g.store.ListAllowedEmails()
	set := make(map[string]bool, len(rows))
	if err != nil {
		g.logger.Error("allowlist lookup failed — falling back to env-only", "err", err)
	} else {
		for _, r := range rows {
			set[strings.ToLower(r.Email)] = true
		}
	}

	g.alMu.Lock()
	g.alSet, g.alExp = set, now.Add(allowlistTTL)
	g.alMu.Unlock()
	return set
}

// BustAllowlistCache forces the next membership check to re-read the DB. The
// admin add/remove handlers call it so a mutation governs the very next
// request in-process (other processes converge within allowlistTTL). Nil-safe.
func (g *SigninGate) BustAllowlistCache() {
	if g == nil {
		return
	}
	g.alMu.Lock()
	g.alSet, g.alExp = nil, time.Time{}
	g.alMu.Unlock()
}

// --- Allowlist-path account model -------------------------------------------------

// AuthorizeAllowlisted applies the account layer to an identity whose
// allowlist membership check already PASSED (env ∪ DB). Two jobs:
//
//  1. A BLOCKED account is refused (outcome `blocked`) even though the email
//     is allowlisted — the admin's explicit block outranks the env list, so
//     the portal's block button is meaningful in every mode. Unblock restores
//     access. Fail-safe for the env-listed owner: an account LOOKUP failure
//     logs and allows (membership already passed; a wedged DB must never lock
//     the operator out) — blocked enforcement resumes when the DB recovers.
//  2. An allowed sign-in ENSURES an account row exists (legacy-owner bind or
//     create, reusing the gate's account-model logic) so the owner's account
//     and device count appear on the portal Accounts page without ever
//     leaving allowlist mode. Best-effort like RecordLegacy: an ensure
//     failure logs and never blocks the sign-in.
//
// Writes the (throttled) allowlist_allowed audit row on success. Nil-gate
// safe: gate-less unit tests allow with no records.
func (g *SigninGate) AuthorizeAllowlisted(ident Identity, ip, tokenFP string) error {
	if g == nil || g.store == nil {
		return nil
	}
	acct, err := g.store.GetAccountBySub(ident.Sub)
	if err != nil {
		g.logger.Error("allowlist-path account lookup failed — allowing (membership already passed)", "err", err)
		g.RecordLegacy(ident, ip, true, tokenFP)
		return nil
	}
	if acct != nil && acct.Status == AccountBlocked {
		g.record(ident, ip, outcomeBlocked, acct.ID)
		g.logger.Warn("allowlist sign-in refused: account blocked", "sub", ident.Sub, "email", ident.Email)
		return ErrUnauthorized
	}
	if acct == nil {
		g.ensureAllowlistAccount(ident)
	}
	g.RecordLegacy(ident, ip, true, tokenFP)
	return nil
}

// ensureAllowlistAccount makes an account record exist for an allowlisted
// identity: legacy-owner bind first (matches a pre-account device by email
// and stamps the sub onto it — identical to the account-model path), else a
// plain create with no invite code. Best-effort: failures log, never block.
func (g *SigninGate) ensureAllowlistAccount(ident Identity) {
	if ident.Sub == "" {
		return
	}
	if legacy, err := g.legacyOwnerAccount(ident); err != nil {
		g.logger.Warn("allowlist account ensure (legacy bind) failed", "err", err)
		return
	} else if legacy != nil {
		g.logger.Info("legacy owner bound to account (allowlist mode)", "sub", ident.Sub, "email", ident.Email)
		return
	}
	if _, err := g.store.CreateAccount(ident.Sub, ident.Email, ""); err != nil {
		g.logger.Warn("allowlist account ensure (create) failed", "err", err)
		return
	}
	g.logger.Info("account created (allowlist mode)", "sub", ident.Sub, "email", ident.Email)
}

// --- Validation --------------------------------------------------------------------

// maxAllowlistNoteLen bounds the admin-supplied note (mirrors invite notes).
const maxAllowlistNoteLen = 512

// validAllowlistEmail is the admin-input sanity check for POSTed emails: a
// bare RFC 5322 address (no display name), bounded length. Deliberately
// lenient beyond that — ALLOWED_EMAILS never validated at all, and the check
// exists to catch fat-fingered garbage, not to out-guess mail systems.
func validAllowlistEmail(email string) bool {
	if email == "" || len(email) > 254 {
		return false
	}
	addr, err := mail.ParseAddress(email)
	return err == nil && addr.Address == email
}
