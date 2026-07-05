package main

// M1 account + invite-code store layer. These methods back the invite-code
// sign-in path (auth_gate.go). They live alongside the device methods in
// store.go and share the same *sql.DB (WAL mode, single writer). Everything
// that must not race — invite validate+consume in particular — is done inside
// one transaction with a conditional UPDATE so a concurrent consume of the
// last remaining use cannot double-spend.

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
)

// Account status values.
const (
	AccountActive  = "active"
	AccountBlocked = "blocked"
)

// Account is one signed-up user, keyed on the stable Google `sub`.
type Account struct {
	ID            string
	GoogleSub     string
	Email         string
	Status        string
	InvitedByCode string
	CreatedAt     time.Time
	BlockedAt     *time.Time
	BlockedReason string
}

// InviteOutcome is the typed result of validating/consuming an invite code. It
// maps 1:1 onto the signin_attempts.outcome enum so the caller can log the
// precise reason a code was refused.
type InviteOutcome int

const (
	InviteOK InviteOutcome = iota
	InviteBad              // code does not exist
	InviteRevoked          // revoked_at set
	InviteExpired          // past expires_at
	InviteExhausted        // uses >= max_uses
)

// signinOutcome returns the signin_attempts.outcome string for a failed
// invite validation. Only call for non-OK outcomes.
func (o InviteOutcome) signinOutcome() string {
	switch o {
	case InviteRevoked:
		return outcomeRevokedInvite
	case InviteExpired:
		return outcomeExpiredInvite
	case InviteExhausted:
		return outcomeExhaustedInvite
	default:
		return outcomeBadInvite
	}
}

// GetAccountBySub returns the account for a Google sub, or nil if none exists.
// A nil, nil return is the "no account yet" signal the sign-in gate uses to
// branch to the invite-code path.
func (s *Store) GetAccountBySub(sub string) (*Account, error) {
	if sub == "" {
		return nil, nil
	}
	return s.scanAccount(s.db.QueryRow(
		`SELECT id, google_sub, email, status, COALESCE(invited_by_code,''),
		        created_at, blocked_at, COALESCE(blocked_reason,'')
		 FROM accounts WHERE google_sub = ?`, sub,
	))
}

// GetAccountByEmail returns the account whose email matches (lowercased), or
// nil. Used only for the legacy-owner bind path: a pre-account owner signing
// in for the first time is matched by email, then their sub is stamped on.
func (s *Store) GetAccountByEmail(email string) (*Account, error) {
	email = strings.ToLower(email)
	if email == "" {
		return nil, nil
	}
	return s.scanAccount(s.db.QueryRow(
		`SELECT id, google_sub, email, status, COALESCE(invited_by_code,''),
		        created_at, blocked_at, COALESCE(blocked_reason,'')
		 FROM accounts WHERE email = ? LIMIT 1`, email,
	))
}

// scanAccount reads one account row; sql.ErrNoRows maps to (nil, nil).
func (s *Store) scanAccount(sc interface{ Scan(...any) error }) (*Account, error) {
	var a Account
	var created time.Time
	var blockedAt sql.NullTime
	if err := sc.Scan(&a.ID, &a.GoogleSub, &a.Email, &a.Status, &a.InvitedByCode,
		&created, &blockedAt, &a.BlockedReason); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	a.CreatedAt = created.UTC()
	if blockedAt.Valid {
		t := blockedAt.Time.UTC()
		a.BlockedAt = &t
	}
	return &a, nil
}

// CreateAccount inserts a new active account keyed on sub. invitedByCode may be
// empty (migrated/bootstrap owners have no code). Returns the created account.
// A UNIQUE-violation on google_sub surfaces as an error — callers should have
// checked GetAccountBySub first; this is the fail-closed backstop.
func (s *Store) CreateAccount(sub, email, invitedByCode string) (*Account, error) {
	if sub == "" {
		return nil, fmt.Errorf("create account: empty google_sub")
	}
	a := &Account{
		ID:            uuid.NewString(),
		GoogleSub:     sub,
		Email:         strings.ToLower(email),
		Status:        AccountActive,
		InvitedByCode: invitedByCode,
		CreatedAt:     time.Now().UTC(),
	}
	var code any
	if invitedByCode != "" {
		code = invitedByCode
	}
	if _, err := s.db.Exec(
		`INSERT INTO accounts (id, google_sub, email, status, invited_by_code, created_at)
		 VALUES (?, ?, ?, ?, ?, ?)`,
		a.ID, a.GoogleSub, a.Email, a.Status, code, a.CreatedAt,
	); err != nil {
		return nil, fmt.Errorf("persist account: %w", err)
	}
	return a, nil
}

// BindAccountSub attaches a google_sub to an existing account row (found by
// email) that has none yet, and refreshes its email. This is the legacy-owner
// path: an owner who predates accounts signs in for the first time, is matched
// by email, and gets their sub stamped so all future authz keys on sub. The
// UPDATE is guarded to only fill an empty sub, so a re-run cannot rebind.
func (s *Store) BindAccountSub(accountID, sub, email string) error {
	if sub == "" {
		return fmt.Errorf("bind account sub: empty sub")
	}
	_, err := s.db.Exec(
		`UPDATE accounts SET google_sub = ?, email = ? WHERE id = ? AND (google_sub = '' OR google_sub IS NULL)`,
		sub, strings.ToLower(email), accountID,
	)
	if err != nil {
		return fmt.Errorf("bind account sub: %w", err)
	}
	return nil
}

// ValidateAndConsumeInvite atomically validates an invite code and, if valid,
// increments its use count — both inside one transaction so the last remaining
// use cannot be double-spent under concurrency. The increment is a conditional
// UPDATE (max_uses IS NULL OR uses < max_uses) whose RowsAffected==0 means a
// racing consumer took the final slot first, which is reported as Exhausted.
//
// Returns InviteOK on success; otherwise a typed outcome the caller logs.
func (s *Store) ValidateAndConsumeInvite(code string) (InviteOutcome, error) {
	code = strings.TrimSpace(code)
	if code == "" {
		return InviteBad, nil
	}

	tx, err := s.db.Begin()
	if err != nil {
		return InviteBad, err
	}
	defer tx.Rollback()

	var maxUses sql.NullInt64
	var uses int64
	var expiresAt, revokedAt sql.NullTime
	err = tx.QueryRow(
		`SELECT max_uses, uses, expires_at, revoked_at FROM invite_codes WHERE code = ?`, code,
	).Scan(&maxUses, &uses, &expiresAt, &revokedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return InviteBad, nil
	}
	if err != nil {
		return InviteBad, fmt.Errorf("lookup invite: %w", err)
	}

	if revokedAt.Valid {
		return InviteRevoked, nil
	}
	if expiresAt.Valid && time.Now().UTC().After(expiresAt.Time.UTC()) {
		return InviteExpired, nil
	}
	if maxUses.Valid && uses >= maxUses.Int64 {
		return InviteExhausted, nil
	}

	// Conditional increment: only succeeds if a slot is still free. This is the
	// race guard — two concurrent consumers of the final use serialize on the
	// row and exactly one gets RowsAffected==1.
	res, err := tx.Exec(
		`UPDATE invite_codes SET uses = uses + 1
		 WHERE code = ? AND revoked_at IS NULL
		   AND (max_uses IS NULL OR uses < max_uses)`,
		code,
	)
	if err != nil {
		return InviteBad, fmt.Errorf("consume invite: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return InviteBad, fmt.Errorf("consume invite: %w", err)
	}
	if n == 0 {
		// Lost the race for the last slot (or it was revoked between the read
		// and the update). Treat as exhausted — no free use remained for us.
		return InviteExhausted, nil
	}
	if err := tx.Commit(); err != nil {
		return InviteBad, fmt.Errorf("consume invite: %w", err)
	}
	return InviteOK, nil
}

// CreateInviteCode inserts an invite code. maxUses nil = unlimited; expiresAt
// nil = never expires. This is the test/bootstrap seam; the M2 admin API will
// wrap it with authorization + audit. Returns an error if the code already
// exists (PRIMARY KEY violation).
func (s *Store) CreateInviteCode(code string, maxUses *int, expiresAt *time.Time, note string) error {
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
	if _, err := s.db.Exec(
		`INSERT INTO invite_codes (code, max_uses, uses, expires_at, note, created_at)
		 VALUES (?, ?, 0, ?, ?, ?)`,
		code, mu, exp, note, time.Now().UTC(),
	); err != nil {
		return fmt.Errorf("persist invite code: %w", err)
	}
	return nil
}

// RevokeInviteCode marks a code revoked (test/bootstrap seam; M2 admin wraps
// it). Idempotent-ish: revoking an unknown code is a no-op.
func (s *Store) RevokeInviteCode(code string) error {
	_, err := s.db.Exec(
		`UPDATE invite_codes SET revoked_at = ? WHERE code = ? AND revoked_at IS NULL`,
		time.Now().UTC(), strings.TrimSpace(code),
	)
	return err
}

// InviteUses returns the current use count of a code (test helper).
func (s *Store) InviteUses(code string) (int, error) {
	var n int
	err := s.db.QueryRow(`SELECT uses FROM invite_codes WHERE code = ?`, strings.TrimSpace(code)).Scan(&n)
	return n, err
}

// signin_attempts.outcome enum values.
const (
	outcomeAllowed         = "allowed"
	outcomeBlocked         = "blocked"
	outcomeNoAccount       = "no_account"
	outcomeBadInvite       = "bad_invite"
	outcomeExpiredInvite   = "expired_invite"
	outcomeRevokedInvite   = "revoked_invite"
	outcomeExhaustedInvite = "exhausted_invite"
	outcomeNotVerified     = "not_verified"
)

// RecordSigninAttempt appends one audit row. It is best-effort: the caller
// treats a logging failure as non-fatal (it must NOT block a legitimate
// sign-in), but the error is returned so the caller can log it. accountID may
// be empty (no account resolved).
func (s *Store) RecordSigninAttempt(email, sub, ip, outcome, accountID string) error {
	var acct any
	if accountID != "" {
		acct = accountID
	}
	_, err := s.db.Exec(
		`INSERT INTO signin_attempts (ts, email, google_sub, ip, outcome, account_id)
		 VALUES (?, ?, ?, ?, ?, ?)`,
		time.Now().UTC(), strings.ToLower(email), sub, ip, outcome, acct,
	)
	if err != nil {
		return fmt.Errorf("record signin attempt: %w", err)
	}
	return nil
}

// CountSigninAttempts returns how many attempt rows match an outcome (test
// helper). Pass "" to count all.
func (s *Store) CountSigninAttempts(outcome string) (int, error) {
	var n int
	var err error
	if outcome == "" {
		err = s.db.QueryRow(`SELECT COUNT(*) FROM signin_attempts`).Scan(&n)
	} else {
		err = s.db.QueryRow(`SELECT COUNT(*) FROM signin_attempts WHERE outcome = ?`, outcome).Scan(&n)
	}
	return n, err
}
