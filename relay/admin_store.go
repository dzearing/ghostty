package main

// M2 admin store layer. These methods back the /v1/admin/ REST surface
// (admin.go): sign-in attempt listing with filters, account list/search with
// device counts, block/unblock/delete, invite listing, the managed-in-DB
// admin flag, and the admin_audit trail. They share the same *sql.DB as the
// device and account methods (WAL mode, single writer); anything that must
// not race — delete-account-with-devices in particular — runs in one
// transaction.

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// --- Admin flag --------------------------------------------------------------

// AccountIsAdmin reports whether the account for a Google sub carries the
// managed-in-DB admin flag. No row (or empty sub) is simply "not an admin" —
// bootstrap admins live on ADMIN_SUBS and need no account row.
func (s *Store) AccountIsAdmin(sub string) (bool, error) {
	if sub == "" {
		return false, nil
	}
	var isAdmin int
	err := s.db.QueryRow(`SELECT is_admin FROM accounts WHERE google_sub = ?`, sub).Scan(&isAdmin)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("admin flag lookup: %w", err)
	}
	return isAdmin != 0, nil
}

// SetAccountAdmin flips the managed-in-DB admin flag on an account. No M2
// endpoint mutates this yet (the flag exists so admins can later be managed
// without env changes); it is the seam tests and future milestones use.
// Returns whether an account row was updated.
func (s *Store) SetAccountAdmin(id string, isAdmin bool) (bool, error) {
	v := 0
	if isAdmin {
		v = 1
	}
	res, err := s.db.Exec(`UPDATE accounts SET is_admin = ? WHERE id = ?`, v, id)
	if err != nil {
		return false, fmt.Errorf("set admin flag: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("set admin flag: %w", err)
	}
	return n > 0, nil
}

// --- Accounts ----------------------------------------------------------------

// GetAccountByID returns the account with the given id, or nil if none exists.
func (s *Store) GetAccountByID(id string) (*Account, error) {
	if id == "" {
		return nil, nil
	}
	return s.scanAccount(s.db.QueryRow(
		`SELECT `+accountCols+` FROM accounts WHERE id = ?`, id,
	))
}

// AccountSummary is one row of the admin account list: the account plus its
// live device count under the ownership predicate.
type AccountSummary struct {
	Account
	DeviceCount int
}

// escapeLike makes a raw substring safe inside a LIKE '%...%' pattern with
// ESCAPE '\': the wildcards % and _ (and the escape char itself) are literal.
func escapeLike(s string) string {
	return strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(s)
}

// ListAccounts returns accounts for the admin list, newest first. q, when
// non-empty, is a case-insensitive substring match on email; status, when
// non-empty, filters on exact status. The per-account device count uses the
// same sub-with-email-fallback ownership predicate as the client API
// (store.go ownsClause), so what the admin sees as "this account's devices"
// is exactly what delete-account would remove.
func (s *Store) ListAccounts(q, status string) ([]AccountSummary, error) {
	query := `SELECT ` + accountCols + `,
	       (SELECT COUNT(*) FROM devices d
	         WHERE (d.owner_sub != '' AND d.owner_sub = accounts.google_sub)
	            OR (d.owner_sub = '' AND d.owner_email = accounts.email))
	 FROM accounts`
	var where []string
	var args []any
	if q != "" {
		where = append(where, `email LIKE ? ESCAPE '\'`)
		args = append(args, "%"+escapeLike(strings.ToLower(q))+"%")
	}
	if status != "" {
		where = append(where, `status = ?`)
		args = append(args, status)
	}
	if len(where) > 0 {
		query += " WHERE " + strings.Join(where, " AND ")
	}
	query += ` ORDER BY created_at DESC, id DESC`

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("list accounts: %w", err)
	}
	defer rows.Close()

	var out []AccountSummary
	for rows.Next() {
		var a Account
		var created time.Time
		var blockedAt sql.NullTime
		var isAdmin, devCount int
		if err := rows.Scan(&a.ID, &a.GoogleSub, &a.Email, &a.Status, &a.InvitedByCode,
			&created, &blockedAt, &a.BlockedReason, &isAdmin, &devCount); err != nil {
			return nil, fmt.Errorf("scan account: %w", err)
		}
		a.CreatedAt = created.UTC()
		if blockedAt.Valid {
			t := blockedAt.Time.UTC()
			a.BlockedAt = &t
		}
		a.IsAdmin = isAdmin != 0
		out = append(out, AccountSummary{Account: a, DeviceCount: devCount})
	}
	return out, rows.Err()
}

// BlockAccount sets an account's status to blocked with a reason. Idempotent:
// re-blocking keeps the ORIGINAL blocked_at (COALESCE) and refreshes the
// reason. The block takes effect at the next sign-in decision (the M1 gate
// refuses blocked accounts when INVITE_SIGNUP is ON); already-issued device
// tokens keep working until the account is deleted — blocking stops the
// human, deleting revokes the machines. Returns the updated account, or nil
// when no such account exists.
func (s *Store) BlockAccount(id, reason string) (*Account, error) {
	res, err := s.db.Exec(
		`UPDATE accounts SET status = ?, blocked_at = COALESCE(blocked_at, ?), blocked_reason = ?
		 WHERE id = ?`,
		AccountBlocked, time.Now().UTC(), reason, id,
	)
	if err != nil {
		return nil, fmt.Errorf("block account: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return nil, fmt.Errorf("block account: %w", err)
	}
	if n == 0 {
		return nil, nil
	}
	return s.GetAccountByID(id)
}

// UnblockAccount clears an account's blocked state (status back to active,
// blocked_at/blocked_reason wiped). Idempotent: unblocking an active account
// is a no-op that still returns it. Returns nil when no such account exists.
func (s *Store) UnblockAccount(id string) (*Account, error) {
	res, err := s.db.Exec(
		`UPDATE accounts SET status = ?, blocked_at = NULL, blocked_reason = NULL WHERE id = ?`,
		AccountActive, id,
	)
	if err != nil {
		return nil, fmt.Errorf("unblock account: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return nil, fmt.Errorf("unblock account: %w", err)
	}
	if n == 0 {
		return nil, nil
	}
	return s.GetAccountByID(id)
}

// DeleteAccount removes an account AND every device it owns, in one
// transaction. Device ownership uses the same sub-with-email-fallback
// predicate as the client API (ownsClause), so legacy email-only devices the
// account owns are deleted too. Deleting the devices deletes their token
// hashes — the agents' credentials are revoked at that instant (the caller
// must additionally sever any live connections via Directory.KickDevice).
// Sign-in attempt and audit rows are retained (append-only history).
// Returns whether an account was deleted and the IDs of the removed devices.
func (s *Store) DeleteAccount(id string) (bool, []string, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return false, nil, err
	}
	defer tx.Rollback()

	acct, err := s.scanAccount(tx.QueryRow(
		`SELECT ` + accountCols + ` FROM accounts WHERE id = ?`, id,
	))
	if err != nil {
		return false, nil, fmt.Errorf("lookup account: %w", err)
	}
	if acct == nil {
		return false, nil, nil
	}

	sub, email := ownsArgs(Identity{Sub: acct.GoogleSub, Email: acct.Email})
	rows, err := tx.Query(`SELECT id FROM devices WHERE `+ownsClause, sub, email)
	if err != nil {
		return false, nil, fmt.Errorf("list owned devices: %w", err)
	}
	var deviceIDs []string
	for rows.Next() {
		var did string
		if err := rows.Scan(&did); err != nil {
			rows.Close()
			return false, nil, fmt.Errorf("scan owned device: %w", err)
		}
		deviceIDs = append(deviceIDs, did)
	}
	if err := rows.Close(); err != nil {
		return false, nil, fmt.Errorf("list owned devices: %w", err)
	}

	if _, err := tx.Exec(`DELETE FROM devices WHERE `+ownsClause, sub, email); err != nil {
		return false, nil, fmt.Errorf("delete owned devices: %w", err)
	}
	if _, err := tx.Exec(`DELETE FROM accounts WHERE id = ?`, id); err != nil {
		return false, nil, fmt.Errorf("delete account: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return false, nil, fmt.Errorf("delete account: %w", err)
	}
	return true, deviceIDs, nil
}

// --- Sign-in attempts ---------------------------------------------------------

// SigninAttempt is one signin_attempts row, as served to the admin feed.
type SigninAttempt struct {
	ID        int64     `json:"id"`
	TS        time.Time `json:"ts"`
	Email     string    `json:"email"`
	GoogleSub string    `json:"google_sub"`
	IP        string    `json:"ip"`
	Outcome   string    `json:"outcome"`
	AccountID string    `json:"account_id,omitempty"`
}

// SigninAttemptFilter narrows ListSigninAttempts. Zero values mean "no
// filter"; Limit <= 0 is replaced by the caller-facing default.
type SigninAttemptFilter struct {
	Outcome string
	Email   string    // exact match, lowercased
	Since   time.Time // ts >= Since when non-zero
	Limit   int
}

// ListSigninAttempts returns attempt rows newest-first under the filter. The
// WHERE clause is composed from the set filters; ORDER BY ts DESC rides the
// idx_signin_attempts_ts index (id DESC breaks same-timestamp ties so the
// order is total).
func (s *Store) ListSigninAttempts(f SigninAttemptFilter) ([]SigninAttempt, error) {
	query := `SELECT id, ts, email, google_sub, ip, outcome, COALESCE(account_id,'')
	 FROM signin_attempts`
	var where []string
	var args []any
	if f.Outcome != "" {
		where = append(where, `outcome = ?`)
		args = append(args, f.Outcome)
	}
	if f.Email != "" {
		where = append(where, `email = ?`)
		args = append(args, strings.ToLower(f.Email))
	}
	if !f.Since.IsZero() {
		where = append(where, `ts >= ?`)
		args = append(args, f.Since.UTC())
	}
	if len(where) > 0 {
		query += " WHERE " + strings.Join(where, " AND ")
	}
	query += ` ORDER BY ts DESC, id DESC LIMIT ?`
	args = append(args, f.Limit)

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("list signin attempts: %w", err)
	}
	defer rows.Close()

	var out []SigninAttempt
	for rows.Next() {
		var a SigninAttempt
		var ts time.Time
		if err := rows.Scan(&a.ID, &ts, &a.Email, &a.GoogleSub, &a.IP, &a.Outcome, &a.AccountID); err != nil {
			return nil, fmt.Errorf("scan signin attempt: %w", err)
		}
		a.TS = ts.UTC()
		out = append(out, a)
	}
	return out, rows.Err()
}

// SigninOutcomeCountsForAccount aggregates an account's sign-in attempts by
// outcome for the usage summary. It matches rows that resolved to the account
// (account_id) OR carry the account's sub (google_sub) — the latter catches
// pre-account attempts (e.g. no_account refusals before signup) that have no
// account_id.
func (s *Store) SigninOutcomeCountsForAccount(accountID, sub string) (map[string]int, error) {
	rows, err := s.db.Query(
		`SELECT outcome, COUNT(*) FROM signin_attempts
		 WHERE account_id = ? OR (google_sub != '' AND google_sub = ?)
		 GROUP BY outcome`,
		accountID, sub,
	)
	if err != nil {
		return nil, fmt.Errorf("signin outcome counts: %w", err)
	}
	defer rows.Close()

	out := make(map[string]int)
	for rows.Next() {
		var outcome string
		var n int
		if err := rows.Scan(&outcome, &n); err != nil {
			return nil, fmt.Errorf("scan outcome count: %w", err)
		}
		out[outcome] = n
	}
	return out, rows.Err()
}

// --- Invite codes --------------------------------------------------------------

// InviteCode is one invite_codes row, as served to the admin list.
type InviteCode struct {
	Code      string     `json:"code"`
	CreatedBy string     `json:"created_by,omitempty"` // admin sub (matches admin_audit.admin_sub); empty for test/bootstrap-seeded codes
	MaxUses   *int64     `json:"max_uses"`             // null = unlimited
	Uses      int64      `json:"uses"`
	ExpiresAt *time.Time `json:"expires_at"` // null = never expires
	RevokedAt *time.Time `json:"revoked_at"` // null = not revoked
	Note      string     `json:"note"`
	CreatedAt time.Time  `json:"created_at"`
}

// CreateInviteCodeBy is the admin-API insert: CreateInviteCode plus the
// created_by stamp. createdBy holds the acting admin's stable sub — NOT an
// account id, for the same reason admin_audit keys on the sub (a bootstrap
// admin may have no account row; see 0003_admin.sql). Returns an error if the
// code already exists (PRIMARY KEY violation).
func (s *Store) CreateInviteCodeBy(code string, maxUses *int, expiresAt *time.Time, note, createdBy string) error {
	code = strings.TrimSpace(code)
	if code == "" {
		return fmt.Errorf("create invite: empty code")
	}
	var mu any
	if maxUses != nil {
		mu = *maxUses
	}
	var exp any
	if expiresAt != nil {
		exp = expiresAt.UTC()
	}
	var by any
	if createdBy != "" {
		by = createdBy
	}
	if _, err := s.db.Exec(
		`INSERT INTO invite_codes (code, created_by, max_uses, uses, expires_at, note, created_at)
		 VALUES (?, ?, ?, 0, ?, ?, ?)`,
		code, by, mu, exp, note, time.Now().UTC(),
	); err != nil {
		return fmt.Errorf("persist invite code: %w", err)
	}
	return nil
}

// GetInviteCode returns one invite code row, or nil if the code is unknown.
func (s *Store) GetInviteCode(code string) (*InviteCode, error) {
	row := s.db.QueryRow(
		`SELECT code, COALESCE(created_by,''), max_uses, uses, expires_at, revoked_at, note, created_at
		 FROM invite_codes WHERE code = ?`, strings.TrimSpace(code),
	)
	ic, err := scanInviteCode(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return ic, err
}

// ListInviteCodes returns all invite codes, newest first.
func (s *Store) ListInviteCodes() ([]InviteCode, error) {
	rows, err := s.db.Query(
		`SELECT code, COALESCE(created_by,''), max_uses, uses, expires_at, revoked_at, note, created_at
		 FROM invite_codes ORDER BY created_at DESC, code ASC`,
	)
	if err != nil {
		return nil, fmt.Errorf("list invite codes: %w", err)
	}
	defer rows.Close()

	var out []InviteCode
	for rows.Next() {
		ic, err := scanInviteCode(rows)
		if err != nil {
			return nil, fmt.Errorf("scan invite code: %w", err)
		}
		out = append(out, *ic)
	}
	return out, rows.Err()
}

// scanInviteCode reads one invite_codes row.
func scanInviteCode(sc interface{ Scan(...any) error }) (*InviteCode, error) {
	var ic InviteCode
	var maxUses sql.NullInt64
	var expiresAt, revokedAt sql.NullTime
	var created time.Time
	if err := sc.Scan(&ic.Code, &ic.CreatedBy, &maxUses, &ic.Uses, &expiresAt, &revokedAt, &ic.Note, &created); err != nil {
		return nil, err
	}
	if maxUses.Valid {
		v := maxUses.Int64
		ic.MaxUses = &v
	}
	if expiresAt.Valid {
		t := expiresAt.Time.UTC()
		ic.ExpiresAt = &t
	}
	if revokedAt.Valid {
		t := revokedAt.Time.UTC()
		ic.RevokedAt = &t
	}
	ic.CreatedAt = created.UTC()
	return &ic, nil
}

// --- Admin audit ---------------------------------------------------------------

// RecordAdminAudit appends one admin_audit row. adminSub keys the acting
// admin (see 0003_admin.sql for why the sub, not an account id); adminEmail
// rides along for readability. action/target/detail describe the mutation.
func (s *Store) RecordAdminAudit(adminSub, adminEmail, action, target, detail string) error {
	_, err := s.db.Exec(
		`INSERT INTO admin_audit (ts, admin_sub, admin_email, action, target, detail)
		 VALUES (?, ?, ?, ?, ?, ?)`,
		time.Now().UTC(), adminSub, strings.ToLower(adminEmail), action, target, detail,
	)
	if err != nil {
		return fmt.Errorf("record admin audit: %w", err)
	}
	return nil
}

// CountAdminAudit returns how many audit rows match an action (test helper,
// mirroring CountSigninAttempts). Pass "" to count all.
func (s *Store) CountAdminAudit(action string) (int, error) {
	var n int
	var err error
	if action == "" {
		err = s.db.QueryRow(`SELECT COUNT(*) FROM admin_audit`).Scan(&n)
	} else {
		err = s.db.QueryRow(`SELECT COUNT(*) FROM admin_audit WHERE action = ?`, action).Scan(&n)
	}
	return n, err
}
