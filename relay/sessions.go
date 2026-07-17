package main

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"time"
)

// sessionIdleMax bounds how long a session row survives without use before it
// stops being renewable (the user must re-run the browser sign-in). The session
// TOKEN is short-lived (1h, expires_at); the ROW persists across renews until
// sign-out, refresh failure, or this idle cap.
const sessionIdleMax = 60 * 24 * time.Hour

// sessionRow is the renewable state of a session: the owner identity and the
// encrypted Google refresh token.
type sessionRow struct {
	Sub        string
	Email      string
	RefreshEnc []byte
}

func hashToken(raw string) string {
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
}

// CreateSession mints a new opaque session token and persists the row. Returns
// the raw token (shown to the caller once) and the expiry.
func (s *Store) CreateSession(sub, email string, refreshEnc []byte, ttl time.Duration) (string, time.Time, error) {
	raw, hash, err := newDeviceToken() // opaque 32-byte random + hex(SHA-256)
	if err != nil {
		return "", time.Time{}, err
	}
	now := time.Now().UTC()
	exp := now.Add(ttl)
	if _, err := s.db.Exec(
		`INSERT INTO sessions (token_hash, google_sub, email, refresh_enc, created_at, expires_at, last_used_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?)`,
		hash, sub, email, refreshEnc, now, exp, now,
	); err != nil {
		return "", time.Time{}, err
	}
	return raw, exp, nil
}

// AuthenticateSession validates a session token for a client API call: exists,
// not revoked, not expired. On success it bumps last_used_at and returns the
// identity. This is the per-request hot path — no Google call.
func (s *Store) AuthenticateSession(raw string) (Identity, bool) {
	if raw == "" {
		return Identity{}, false
	}
	hash := hashToken(raw)
	var sub, email string
	var expiresAt time.Time
	var revoked sql.NullTime
	err := s.db.QueryRow(
		`SELECT google_sub, email, expires_at, revoked_at FROM sessions WHERE token_hash = ?`, hash,
	).Scan(&sub, &email, &expiresAt, &revoked)
	if err != nil {
		if !errors.Is(err, sql.ErrNoRows) {
			s.logger.Error("authenticate session failed", "err", err)
		}
		return Identity{}, false
	}
	if revoked.Valid || time.Now().After(expiresAt) {
		return Identity{}, false
	}
	_, _ = s.db.Exec(`UPDATE sessions SET last_used_at = ? WHERE token_hash = ?`, time.Now().UTC(), hash)
	return Identity{Email: email, Sub: sub}, true
}

// SessionForRenew looks up a session for the renew path: not revoked and used
// within sessionIdleMax, IGNORING the short expires_at (a just-expired token is
// still renewable). Returns the encrypted refresh token for the caller to
// decrypt and redeem at Google.
func (s *Store) SessionForRenew(raw string) (*sessionRow, bool) {
	if raw == "" {
		return nil, false
	}
	hash := hashToken(raw)
	var row sessionRow
	var lastUsed time.Time
	var revoked sql.NullTime
	err := s.db.QueryRow(
		`SELECT google_sub, email, refresh_enc, last_used_at, revoked_at FROM sessions WHERE token_hash = ?`, hash,
	).Scan(&row.Sub, &row.Email, &row.RefreshEnc, &lastUsed, &revoked)
	if err != nil {
		return nil, false
	}
	if revoked.Valid || time.Since(lastUsed) > sessionIdleMax {
		return nil, false
	}
	return &row, true
}

// RotateSession replaces a session's token (new hash), refresh token, and
// expiry in place — preserving the row identity. Called on renew (token
// rotation is a security best practice).
func (s *Store) RotateSession(oldRaw, newRaw string, refreshEnc []byte, expiresAt time.Time) error {
	res, err := s.db.Exec(
		`UPDATE sessions SET token_hash = ?, refresh_enc = ?, expires_at = ?, last_used_at = ?
		 WHERE token_hash = ?`,
		hashToken(newRaw), refreshEnc, expiresAt.UTC(), time.Now().UTC(), hashToken(oldRaw),
	)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return errors.New("session not found for rotation")
	}
	return nil
}

// RevokeSession deletes a session row (sign-out): the token stops working AND
// the encrypted Google refresh token is destroyed.
func (s *Store) RevokeSession(raw string) error {
	_, err := s.db.Exec(`DELETE FROM sessions WHERE token_hash = ?`, hashToken(raw))
	return err
}
