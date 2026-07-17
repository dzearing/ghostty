# Relay-Brokered OAuth (BFF) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the confidential Google `client_secret` off the macOS app onto the relay via a full BFF brokered token exchange, so Google id/refresh tokens never touch the client and the app holds only a short-lived, revocable relay session token.

**Architecture:** The app keeps PKCE + loopback and obtains the authorization `code` locally, then POSTs `{code, code_verifier, redirect_uri}` to a new relay `/oauth/exchange`. The relay (holding the secret) exchanges with Google, verifies the id_token (existing aud-allowlist + `ALLOWED_EMAILS`), stores the Google refresh token AES-256-GCM-encrypted at rest, and mints an opaque relay session token (same opaque + SHA-256-hashed pattern as device tokens). `/v1/client/*` flip from Google-ID-token auth to session-token auth; a `/oauth/renew` path re-mints using the stored refresh token.

**Tech Stack:** Go 1.26 relay (`modernc.org/sqlite`, goose migrations, `coreos/go-oidc/v3`), Swift macOS app (Foundation/CryptoKit/Network), Zig 0.15 build system, Xcode.

## Global Constraints

- Fork is **Ghoztty** (with Z) — no user-facing "Ghostty" strings.
- **Never touch `/Applications/Ghoztty.app`.** Test only the debug build (`zig-out/Ghoztty-Debug.app`; separate socket + bundle id).
- **No AI attribution** in commits or PRs (no `Co-Authored-By`, no "Generated with" footers).
- **No secret** may ship in the app binary or be committed to the repo / git history. The Google client **id** is public and managed as build config; the client **secret** and `SESSION_ENC_KEY` live only on the relay.
- Namespace is `com.dzearing.ghoztty.*` — never `com.mitchellh.*`.
- Toolchain: `export PATH=/opt/homebrew/opt/zig@0.15/bin:/opt/homebrew/opt/gettext/bin:$PATH; export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Build/verify gate before "done": `zig build -Doptimize=Debug`, the Swift test target, and `cd relay && go test ./...` all green.
- Relay env vars use `GHOSTTY_` prefix (S), not GHOZTTY.
- Session token TTL: **1h**. Session row idle max: **60 days**. Renew leeway on the client: **60s**.

---

## Phase 1 — Relay backend (Go)

All files under `relay/`. Run tests with `cd relay && go test ./...` (add `-run TestName` to target one).

### Task 1: AES-256-GCM secret encryption + `SESSION_ENC_KEY` config

**Files:**
- Create: `relay/crypto.go`
- Create: `relay/crypto_test.go`
- Modify: `relay/config.go` (add `SessionEncKey []byte` field + load `SESSION_ENC_KEY`)

**Interfaces:**
- Produces: `func encryptSecret(key, plaintext []byte) ([]byte, error)`, `func decryptSecret(key, ciphertext []byte) ([]byte, error)`, `func decodeSessionEncKey(s string) ([]byte, error)`; `Config.SessionEncKey []byte`.

- [ ] **Step 1: Write the failing test** — `relay/crypto_test.go`:

```go
package main

import (
	"bytes"
	"crypto/rand"
	"testing"
)

func testKey(t *testing.T) []byte {
	t.Helper()
	k := make([]byte, 32)
	if _, err := rand.Read(k); err != nil {
		t.Fatal(err)
	}
	return k
}

func TestEncryptDecryptRoundTrip(t *testing.T) {
	key := testKey(t)
	plain := []byte("1//0gRefreshTokenExampleValue")
	ct, err := encryptSecret(key, plain)
	if err != nil {
		t.Fatalf("encrypt: %v", err)
	}
	if bytes.Contains(ct, plain) {
		t.Fatal("ciphertext leaks plaintext")
	}
	got, err := decryptSecret(key, ct)
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	if !bytes.Equal(got, plain) {
		t.Fatalf("round trip mismatch: got %q want %q", got, plain)
	}
}

func TestEncryptNonceUnique(t *testing.T) {
	key := testKey(t)
	a, _ := encryptSecret(key, []byte("x"))
	b, _ := encryptSecret(key, []byte("x"))
	if bytes.Equal(a, b) {
		t.Fatal("same plaintext must not produce identical ciphertext (nonce reuse)")
	}
}

func TestDecryptWrongKeyFails(t *testing.T) {
	ct, _ := encryptSecret(testKey(t), []byte("secret"))
	if _, err := decryptSecret(testKey(t), ct); err == nil {
		t.Fatal("decrypt with wrong key must fail")
	}
}

func TestDecodeSessionEncKey(t *testing.T) {
	// 32 bytes base64-std encoded.
	good := "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=" // 32 'A'..-ish bytes
	k, err := decodeSessionEncKey(good)
	if err != nil || len(k) != 32 {
		t.Fatalf("decode good key: len=%d err=%v", len(k), err)
	}
	if _, err := decodeSessionEncKey("too-short"); err == nil {
		t.Fatal("short key must be rejected")
	}
	if _, err := decodeSessionEncKey(""); err == nil {
		t.Fatal("empty key must be rejected")
	}
}
```

- [ ] **Step 2: Run test to verify it fails** — `cd relay && go test -run 'TestEncrypt|TestDecrypt|TestDecodeSessionEncKey' ./...` → FAIL (undefined: encryptSecret …).

- [ ] **Step 3: Write minimal implementation** — `relay/crypto.go`:

```go
package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
)

// encryptSecret seals plaintext with AES-256-GCM under key (32 bytes). The
// 12-byte random nonce is prepended to the returned ciphertext. Used to protect
// the Google refresh token at rest (the one recoverable secret the relay
// stores); everything else is a one-way hash.
func encryptSecret(key, plaintext []byte) ([]byte, error) {
	gcm, err := newGCM(key)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, fmt.Errorf("nonce: %w", err)
	}
	return gcm.Seal(nonce, nonce, plaintext, nil), nil
}

// decryptSecret opens a ciphertext produced by encryptSecret.
func decryptSecret(key, ciphertext []byte) ([]byte, error) {
	gcm, err := newGCM(key)
	if err != nil {
		return nil, err
	}
	ns := gcm.NonceSize()
	if len(ciphertext) < ns {
		return nil, errors.New("ciphertext too short")
	}
	return gcm.Open(nil, ciphertext[:ns], ciphertext[ns:], nil)
}

func newGCM(key []byte) (cipher.AEAD, error) {
	if len(key) != 32 {
		return nil, fmt.Errorf("session enc key must be 32 bytes, got %d", len(key))
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// decodeSessionEncKey parses SESSION_ENC_KEY: base64-std (padded or raw) of
// exactly 32 bytes. Empty/short is an error (fail-closed).
func decodeSessionEncKey(s string) ([]byte, error) {
	if s == "" {
		return nil, errors.New("SESSION_ENC_KEY is empty")
	}
	for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding} {
		if k, err := enc.DecodeString(s); err == nil && len(k) == 32 {
			return k, nil
		}
	}
	return nil, errors.New("SESSION_ENC_KEY must be base64 of exactly 32 bytes")
}
```

- [ ] **Step 4: Add config field + load.** In `relay/config.go`, add to the `Config` struct (near `DevEmail`):

```go
	// SessionEncKey is the AES-256 key (32 bytes) protecting Google refresh
	// tokens at rest for the brokered-OAuth session store (oauth.go). Sourced
	// from SESSION_ENC_KEY (base64 of 32 bytes). Empty disables the brokered
	// flow (fail-closed): /oauth/exchange + /oauth/renew answer 503.
	SessionEncKey []byte
```

In `LoadConfig`, after the `ALLOWED_EMAILS` loop, add:

```go
	if k, err := decodeSessionEncKey(os.Getenv("SESSION_ENC_KEY")); err == nil {
		cfg.SessionEncKey = k
	}
```

- [ ] **Step 5: Run tests** — `cd relay && go test -run 'TestEncrypt|TestDecrypt|TestDecodeSessionEncKey' ./...` → PASS.

- [ ] **Step 6: Commit**

```bash
git add relay/crypto.go relay/crypto_test.go relay/config.go
git commit -m "feat(relay): AES-256-GCM secret encryption + SESSION_ENC_KEY config"
```

---

### Task 2: `sessions` table + session store methods

**Files:**
- Create: `relay/migrations/0007_sessions.sql`
- Create: `relay/sessions.go`
- Create: `relay/sessions_test.go`

**Interfaces:**
- Consumes: `newDeviceToken()` (store.go), `Identity` (auth.go), `Store.db`.
- Produces on `*Store`:
  - `CreateSession(sub, email string, refreshEnc []byte, ttl time.Duration) (rawToken string, expiresAt time.Time, err error)`
  - `AuthenticateSession(rawToken string) (Identity, bool)` — valid (not expired, not revoked); bumps `last_used_at`.
  - `SessionForRenew(rawToken string) (*sessionRow, bool)` — not revoked, within idle max, ignoring the 1h expiry; returns `refreshEnc`.
  - `RotateSession(oldRawToken, newRawToken string, refreshEnc []byte, expiresAt time.Time) error`
  - `RevokeSession(rawToken string) error`
  - type `sessionRow struct { Sub, Email string; RefreshEnc []byte }`
- Constant: `sessionIdleMax = 60 * 24 * time.Hour`.

- [ ] **Step 1: Write the migration** — `relay/migrations/0007_sessions.sql`:

```sql
-- +goose Up
-- Brokered-OAuth relay sessions (BFF). One row per active client session.
-- The raw session token is never stored; only hex(SHA-256(raw token)), exactly
-- like device tokens. The Google refresh token is stored AES-256-GCM encrypted
-- (crypto.go) — the one recoverable secret the relay holds.
CREATE TABLE sessions (
    token_hash        TEXT PRIMARY KEY,      -- hex(SHA-256(raw session token))
    google_sub        TEXT NOT NULL,
    email             TEXT NOT NULL,
    refresh_enc       BLOB NOT NULL,         -- encrypted Google refresh token
    created_at        TIMESTAMP NOT NULL,
    expires_at        TIMESTAMP NOT NULL,    -- session-token validity (1h)
    last_used_at      TIMESTAMP NOT NULL,
    revoked_at        TIMESTAMP              -- NULL = active
);

CREATE INDEX idx_sessions_sub ON sessions (google_sub);

-- +goose Down
DROP TABLE sessions;
```

- [ ] **Step 2: Write the failing test** — `relay/sessions_test.go`:

```go
package main

import (
	"testing"
	"time"
)

func newSessionTestStore(t *testing.T) *Store {
	t.Helper()
	s, err := LoadStore(t.TempDir()+"/db.sqlite", "", testLogger())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestCreateAndAuthenticateSession(t *testing.T) {
	s := newSessionTestStore(t)
	raw, exp, err := s.CreateSession("sub-1", "user@example.com", []byte("enc"), time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if raw == "" || time.Until(exp) <= 0 {
		t.Fatalf("bad session: raw=%q exp=%v", raw, exp)
	}
	ident, ok := s.AuthenticateSession(raw)
	if !ok || ident.Sub != "sub-1" || ident.Email != "user@example.com" {
		t.Fatalf("authenticate: ok=%v ident=%+v", ok, ident)
	}
	if _, ok := s.AuthenticateSession("bogus"); ok {
		t.Fatal("bogus token must not authenticate")
	}
}

func TestAuthenticateSessionExpired(t *testing.T) {
	s := newSessionTestStore(t)
	raw, _, _ := s.CreateSession("sub", "u@e.com", []byte("enc"), -time.Minute) // already expired
	if _, ok := s.AuthenticateSession(raw); ok {
		t.Fatal("expired session must not authenticate")
	}
	// but it is still renewable
	if _, ok := s.SessionForRenew(raw); !ok {
		t.Fatal("expired-but-fresh session must be renewable")
	}
}

func TestRotateAndRevokeSession(t *testing.T) {
	s := newSessionTestStore(t)
	raw, _, _ := s.CreateSession("sub", "u@e.com", []byte("enc1"), time.Hour)
	newRaw, _, _ := s.CreateSession("tmp", "t@e.com", []byte("x"), time.Hour) // just to get a fresh raw token value
	_ = s.RevokeSession(newRaw)
	if err := s.RotateSession(raw, newRaw, []byte("enc2"), time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, ok := s.AuthenticateSession(raw); ok {
		t.Fatal("old token must be invalid after rotation")
	}
	ident, ok := s.AuthenticateSession(newRaw)
	if !ok || ident.Sub != "sub" {
		t.Fatalf("rotated token must carry original identity: ok=%v ident=%+v", ok, ident)
	}
	row, ok := s.SessionForRenew(newRaw)
	if !ok || string(row.RefreshEnc) != "enc2" {
		t.Fatalf("rotation must update refresh_enc: ok=%v row=%+v", ok, row)
	}
	if err := s.RevokeSession(newRaw); err != nil {
		t.Fatal(err)
	}
	if _, ok := s.AuthenticateSession(newRaw); ok {
		t.Fatal("revoked session must not authenticate")
	}
	if _, ok := s.SessionForRenew(newRaw); ok {
		t.Fatal("revoked session must not be renewable")
	}
}
```

> Note: `testLogger()` already exists in the relay test package (used by other `_test.go` files). If not found where you look, grep `func testLogger` in `relay/*_test.go` and reuse it.

- [ ] **Step 3: Run test to verify it fails** — `cd relay && go test -run TestCreateAndAuthenticateSession ./...` → FAIL (undefined: CreateSession).

- [ ] **Step 4: Write the implementation** — `relay/sessions.go`:

```go
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
```

> `RevokeSession` deletes the row (destroying the refresh token) rather than setting `revoked_at`; the `revoked_at` column is retained for tests/observability and future soft-revoke needs, and `AuthenticateSession`/`SessionForRenew` still honor it.

- [ ] **Step 5: Run tests** — `cd relay && go test -run 'TestCreateAndAuthenticateSession|TestAuthenticateSessionExpired|TestRotateAndRevokeSession' ./...` → PASS.

- [ ] **Step 6: Commit**

```bash
git add relay/migrations/0007_sessions.sql relay/sessions.go relay/sessions_test.go
git commit -m "feat(relay): sessions table + opaque session-token store (BFF)"
```

---

### Task 3: Google code-exchange + refresh helpers (capture refresh token)

**Files:**
- Create: `relay/oauth.go`
- Create: `relay/oauth_test.go`

**Interfaces:**
- Consumes: `Authenticator.tokenURL`, `Authenticator.httpClient` (auth.go, same package), `Config`.
- Produces: type `googleTokens struct { IDToken, RefreshToken, AccessToken string; ExpiresIn int }`; method `func (h *Handler) googleExchangeCode(ctx context.Context, code, codeVerifier, redirectURI string) (*googleTokens, string, error)` and `func (h *Handler) googleRefresh(ctx context.Context, refreshToken string) (*googleTokens, string, error)` — return `(tokens, oauthErr, err)` mirroring `postTokenForm`.

- [ ] **Step 1: Write the failing test** — `relay/oauth_test.go` (uses the existing fake-issuer harness; see `auth_oidc_test.go` `fakeIssuer` + `mint`):

```go
package main

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
)

// oauthExchangeFixture wires a fake Google token endpoint returning a code
// exchange with a refresh token, and a Handler pointed at it.
func TestGoogleExchangeCodeCapturesRefresh(t *testing.T) {
	f := newFakeIssuer(t)
	defer f.close()
	f.tokenHandler = func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		if r.Form.Get("grant_type") != "authorization_code" {
			w.WriteHeader(400)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": "unsupported_grant_type"})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"id_token":      f.mint(t, validClaims(f)),
			"refresh_token": "1//refresh-abc",
			"access_token":  "ya29.access",
			"expires_in":    3599,
		})
	}
	h := newOAuthTestHandler(t, f)

	tokens, oauthErr, err := h.googleExchangeCode(context.Background(), "the-code", "the-verifier", "http://127.0.0.1:49152")
	if err != nil || oauthErr != "" {
		t.Fatalf("exchange: oauthErr=%q err=%v", oauthErr, err)
	}
	if tokens.RefreshToken != "1//refresh-abc" || tokens.IDToken == "" {
		t.Fatalf("missing tokens: %+v", tokens)
	}
}
```

> `newFakeIssuer`, `f.tokenHandler`, `f.mint`, `validClaims`, and `f.close` are the existing fake-issuer harness members in `auth_oidc_test.go`. If the field/func names differ slightly, read `auth_oidc_test.go` and adapt. `newOAuthTestHandler(t, f)` is a small helper you add next to this test that builds a `Config{GoogleClientID:"desktop", GoogleClientSecret:"sekret", IssuerURL:f.srv.URL, AllowedEmails:[]string{"user@example.com"}, SessionEncKey: testKey(t)}` → `NewAuthenticator` → `LoadStore(t.TempDir())` → `NewHandler`. Model it on `newEnrollTestServer` in `enroll_test.go`.

- [ ] **Step 2: Run test to verify it fails** — `cd relay && go test -run TestGoogleExchangeCodeCapturesRefresh ./...` → FAIL (undefined: googleExchangeCode / newOAuthTestHandler).

- [ ] **Step 3: Write the implementation** — `relay/oauth.go` (start with the low-level helpers; the HTTP handlers come in Tasks 4–6):

```go
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
)

// sessionTTL is how long a minted relay session token is valid before the app
// must renew it. Short by design; renew re-checks the allowlist.
const sessionTTL = time.Hour

// googleTokens is the subset of Google's token-endpoint response the brokered
// flow needs. Unlike enroll.go's postTokenForm (id_token only), this captures
// the refresh token.
type googleTokens struct {
	IDToken      string `json:"id_token"`
	RefreshToken string `json:"refresh_token"`
	AccessToken  string `json:"access_token"`
	ExpiresIn    int    `json:"expires_in"`
}

// googleExchangeCode redeems an authorization code (+ PKCE verifier) at Google's
// token endpoint using the DESKTOP client id + secret, capturing the refresh
// token. Returns (tokens, oauthErr, err): oauthErr is a protocol-level OAuth
// error code; err is transport/5xx/malformed.
func (h *Handler) googleExchangeCode(ctx context.Context, code, codeVerifier, redirectURI string) (*googleTokens, string, error) {
	form := url.Values{
		"grant_type":    {"authorization_code"},
		"client_id":     {h.cfg.GoogleClientID},
		"client_secret": {h.cfg.GoogleClientSecret},
		"code":          {code},
		"code_verifier": {codeVerifier},
		"redirect_uri":  {redirectURI},
	}
	return h.postGoogleToken(ctx, form)
}

// googleRefresh redeems a stored refresh token for fresh tokens using the
// DESKTOP client id + secret.
func (h *Handler) googleRefresh(ctx context.Context, refreshToken string) (*googleTokens, string, error) {
	form := url.Values{
		"grant_type":    {"refresh_token"},
		"client_id":     {h.cfg.GoogleClientID},
		"client_secret": {h.cfg.GoogleClientSecret},
		"refresh_token": {refreshToken},
	}
	return h.postGoogleToken(ctx, form)
}

func (h *Handler) postGoogleToken(ctx context.Context, form url.Values) (*googleTokens, string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, h.auth.tokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, "", fmt.Errorf("build token request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := h.auth.httpClient.Do(req)
	if err != nil {
		return nil, "", fmt.Errorf("token request: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, "", fmt.Errorf("read token response: %w", err)
	}
	if resp.StatusCode >= 500 {
		return nil, "", fmt.Errorf("token endpoint status %d", resp.StatusCode)
	}
	var out struct {
		googleTokens
		Error string `json:"error"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, "", fmt.Errorf("parse token response (status %d): %w", resp.StatusCode, err)
	}
	if out.Error != "" {
		return nil, out.Error, nil
	}
	if resp.StatusCode == http.StatusOK && out.IDToken != "" {
		return &out.googleTokens, "", nil
	}
	return nil, "", fmt.Errorf("token endpoint returned neither id_token nor error (status %d)", resp.StatusCode)
}
```

> Add `"time"` to the import block (used by `sessionTTL`).

- [ ] **Step 4: Add the `newOAuthTestHandler` helper** in `relay/oauth_test.go` (or a shared `_test.go`), modeled on `newEnrollTestServer`. Verify it compiles.

- [ ] **Step 5: Run tests** — `cd relay && go test -run TestGoogleExchangeCodeCapturesRefresh ./...` → PASS.

- [ ] **Step 6: Commit**

```bash
git add relay/oauth.go relay/oauth_test.go
git commit -m "feat(relay): Google code-exchange + refresh helpers capturing refresh token"
```

---

### Task 4: `POST /oauth/exchange` handler

**Files:**
- Modify: `relay/oauth.go` (add handler + `mintSession` helper + `oauthUnavailable` guard + `sessionResponse` type)
- Modify: `relay/handlers.go` (register route in `Register`, ~line 78)
- Modify: `relay/oauth_test.go` (add exchange + allowlist tests)

**Interfaces:**
- Produces: `func (h *Handler) handleOAuthExchange(w http.ResponseWriter, r *http.Request)`; `sessionResponse struct { SessionToken string `json:"session_token"`; Expiry int64 `json:"expiry"`; Email string `json:"email"`; Picture string `json:"picture,omitempty"` }`; helper `func (h *Handler) mintSession(ctx, googleTokens) (*sessionResponse, error)`; `func isLoopbackRedirect(u string) bool`.

- [ ] **Step 1: Write the failing tests** — append to `relay/oauth_test.go`:

```go
func doExchange(t *testing.T, srv *httptest.Server, body map[string]string) (*http.Response, map[string]any) {
	t.Helper()
	b, _ := json.Marshal(body)
	resp, err := http.Post(srv.URL+"/oauth/exchange", "application/json", bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	resp.Body.Close()
	return resp, out
}

func TestOAuthExchangeMintsSession(t *testing.T) {
	f := newFakeIssuer(t)
	defer f.close()
	f.tokenHandler = okTokenHandler(t, f) // returns id_token(validClaims)+refresh_token
	srv, _ := newOAuthTestServer(t, f, []string{"user@example.com"})
	defer srv.Close()

	resp, out := doExchange(t, srv, map[string]string{
		"code": "c", "code_verifier": "v", "redirect_uri": "http://127.0.0.1:49152",
	})
	if resp.StatusCode != 200 {
		t.Fatalf("status=%d body=%v", resp.StatusCode, out)
	}
	if out["session_token"] == "" || out["session_token"] == nil {
		t.Fatalf("no session_token: %v", out)
	}
	if out["email"] != "user@example.com" {
		t.Fatalf("email=%v", out["email"])
	}
}

func TestOAuthExchangeAllowlistRejected(t *testing.T) {
	f := newFakeIssuer(t)
	defer f.close()
	f.tokenHandler = okTokenHandler(t, f)
	srv, _ := newOAuthTestServer(t, f, []string{"someone-else@example.com"}) // caller not allowed
	defer srv.Close()

	resp, _ := doExchange(t, srv, map[string]string{
		"code": "c", "code_verifier": "v", "redirect_uri": "http://127.0.0.1:49152",
	})
	if resp.StatusCode != http.StatusForbidden && resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401/403 for non-allowlisted, got %d", resp.StatusCode)
	}
}

func TestOAuthExchangeRejectsNonLoopbackRedirect(t *testing.T) {
	f := newFakeIssuer(t)
	defer f.close()
	f.tokenHandler = okTokenHandler(t, f)
	srv, _ := newOAuthTestServer(t, f, []string{"user@example.com"})
	defer srv.Close()

	resp, _ := doExchange(t, srv, map[string]string{
		"code": "c", "code_verifier": "v", "redirect_uri": "https://evil.example.com/cb",
	})
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400 for non-loopback redirect, got %d", resp.StatusCode)
	}
}
```

> Add `newOAuthTestServer(t, f, allowedEmails)` (builds the Config as in Task 3 + `httptest.NewServer(mux)` after `h.Register(mux)`; returns `(srv, h)`), and `okTokenHandler(t, f)` (returns the id_token+refresh_token JSON) as helpers in the test file. `validClaims(f)` should carry `email: "user@example.com"`, `email_verified: true`, `aud: "desktop"`.

- [ ] **Step 2: Run tests to verify they fail** — `cd relay && go test -run TestOAuthExchange ./...` → FAIL (route 404 / undefined helpers).

- [ ] **Step 3: Implement the handler** — append to `relay/oauth.go`:

```go
// oauthUnavailable reports whether the brokered flow can't run (missing secret
// key or Google client not configured). Fail-closed → 503.
func (h *Handler) oauthUnavailable() bool {
	return len(h.cfg.SessionEncKey) != 32 || h.cfg.GoogleClientID == "" ||
		h.cfg.GoogleClientSecret == "" || h.auth.tokenURL == ""
}

// isLoopbackRedirect accepts only loopback redirect URIs (the app's PKCE
// loopback receiver), so the relay is not a generic code-exchange oracle.
func isLoopbackRedirect(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "http" {
		return false
	}
	host := u.Hostname()
	return host == "127.0.0.1" || host == "::1" || host == "localhost"
}

type sessionResponse struct {
	SessionToken string `json:"session_token"`
	Expiry       int64  `json:"expiry"` // unix seconds
	Email        string `json:"email"`
	Picture      string `json:"picture,omitempty"`
}

// handleOAuthExchange: POST /oauth/exchange (JSON, UNAUTHENTICATED — the
// authorization code + PKCE verifier ARE the credential). Body:
// {code, code_verifier, redirect_uri}. Exchanges the code with Google (desktop
// client secret, server-side), verifies + allowlists the id_token, stores the
// refresh token encrypted, and mints a relay session token.
func (h *Handler) handleOAuthExchange(w http.ResponseWriter, r *http.Request) {
	if h.oauthUnavailable() {
		http.Error(w, "brokered oauth not configured", http.StatusServiceUnavailable)
		return
	}
	var body struct {
		Code        string `json:"code"`
		CodeVerif   string `json:"code_verifier"`
		RedirectURI string `json:"redirect_uri"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192)).Decode(&body); err != nil ||
		body.Code == "" || body.CodeVerif == "" || body.RedirectURI == "" {
		http.Error(w, "invalid body: expected {code, code_verifier, redirect_uri}", http.StatusBadRequest)
		return
	}
	if !isLoopbackRedirect(body.RedirectURI) {
		http.Error(w, "redirect_uri must be loopback", http.StatusBadRequest)
		return
	}

	tokens, oauthErr, err := h.googleExchangeCode(r.Context(), body.Code, body.CodeVerif, body.RedirectURI)
	if err != nil {
		h.logger.Warn("oauth exchange upstream error", "err", err)
		http.Error(w, "upstream token exchange failed", http.StatusBadGateway)
		return
	}
	if oauthErr != "" {
		h.logger.Warn("oauth exchange rejected by google", "oauth_error", oauthErr)
		http.Error(w, "token exchange rejected: "+oauthErr, http.StatusBadRequest)
		return
	}
	if tokens.RefreshToken == "" {
		http.Error(w, "google did not return a refresh token", http.StatusBadGateway)
		return
	}

	out, err := h.mintSession(r.Context(), tokens)
	if err != nil {
		// mintSession maps verification/allowlist failure to ErrUnauthorized.
		if errors.Is(err, ErrUnauthorized) {
			http.Error(w, "not authorized", http.StatusForbidden)
			return
		}
		h.logger.Error("mint session failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// mintSession verifies + allowlists the id_token, extracts display claims,
// encrypts the refresh token, and persists a new session row.
func (h *Handler) mintSession(ctx context.Context, tokens *googleTokens) (*sessionResponse, error) {
	ident, err := h.auth.VerifyIDToken(ctx, tokens.IDToken) // signature/aud/exp + ALLOWED_EMAILS
	if err != nil {
		return nil, err
	}
	picture := parsePictureClaim(tokens.IDToken)
	enc, err := encryptSecret(h.cfg.SessionEncKey, []byte(tokens.RefreshToken))
	if err != nil {
		return nil, err
	}
	raw, exp, err := h.store.CreateSession(ident.Sub, ident.Email, enc, sessionTTL)
	if err != nil {
		return nil, err
	}
	return &sessionResponse{
		SessionToken: raw,
		Expiry:       exp.Unix(),
		Email:        ident.Email,
		Picture:      picture,
	}, nil
}

// parsePictureClaim best-effort reads the `picture` claim from a JWT payload
// (display only; the id_token was already verified by VerifyIDToken). Returns
// "" when absent or unparseable.
func parsePictureClaim(idToken string) string {
	parts := strings.Split(idToken, ".")
	if len(parts) != 3 {
		return ""
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return ""
	}
	var claims struct {
		Picture string `json:"picture"`
	}
	_ = json.Unmarshal(payload, &claims)
	return claims.Picture
}
```

> Add `"encoding/base64"` and `"errors"` to `oauth.go` imports.

- [ ] **Step 4: Register the route** — in `relay/handlers.go` `Register`, after the enroll routes (~line 78) add:

```go
	// Brokered-OAuth (BFF): the app hands the relay a PKCE authorization code;
	// the relay holds the client secret + Google tokens and mints session tokens.
	mux.HandleFunc("POST /oauth/exchange", h.handleOAuthExchange)
```

- [ ] **Step 5: Run tests** — `cd relay && go test -run TestOAuthExchange ./...` → PASS.

- [ ] **Step 6: Commit**

```bash
git add relay/oauth.go relay/oauth_test.go relay/handlers.go
git commit -m "feat(relay): POST /oauth/exchange — brokered code exchange + session minting"
```

---

### Task 5: `POST /oauth/renew` handler

**Files:**
- Modify: `relay/oauth.go` (add `handleOAuthRenew`)
- Modify: `relay/handlers.go` (register route)
- Modify: `relay/oauth_test.go` (renew tests)

**Interfaces:**
- Consumes: `bearerToken(r)` (auth.go), `Store.SessionForRenew`, `Store.RotateSession`, `googleRefresh`, `encryptSecret/decryptSecret`, `VerifyIDToken`.
- Produces: `func (h *Handler) handleOAuthRenew(w http.ResponseWriter, r *http.Request)`.

- [ ] **Step 1: Write the failing test** — append to `relay/oauth_test.go`:

```go
func TestOAuthRenewRotatesToken(t *testing.T) {
	f := newFakeIssuer(t)
	defer f.close()
	f.tokenHandler = okTokenHandler(t, f) // handles both authorization_code and refresh_token grants
	srv, _ := newOAuthTestServer(t, f, []string{"user@example.com"})
	defer srv.Close()

	_, ex := doExchange(t, srv, map[string]string{
		"code": "c", "code_verifier": "v", "redirect_uri": "http://127.0.0.1:49152",
	})
	old := ex["session_token"].(string)

	req, _ := http.NewRequest("POST", srv.URL+"/oauth/renew", nil)
	req.Header.Set("Authorization", "Bearer "+old)
	resp, err := http.DefaultClient.Do(req)
	if err != nil || resp.StatusCode != 200 {
		t.Fatalf("renew status=%v err=%v", resp.StatusCode, err)
	}
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	resp.Body.Close()
	neu, _ := out["session_token"].(string)
	if neu == "" || neu == old {
		t.Fatalf("renew must rotate the token: old=%q new=%q", old, neu)
	}
}
```

> Make `okTokenHandler` respond to both `grant_type=authorization_code` and `grant_type=refresh_token` (both return an id_token; the refresh grant may omit `refresh_token`).

- [ ] **Step 2: Run test to verify it fails** — `cd relay && go test -run TestOAuthRenewRotatesToken ./...` → FAIL (404).

- [ ] **Step 3: Implement** — append to `relay/oauth.go`:

```go
// handleOAuthRenew: POST /oauth/renew (Bearer session token). Uses the stored
// Google refresh token to mint a fresh id_token, RE-CHECKS the allowlist, and
// rotates the session token. Accepts a just-expired token (SessionForRenew
// ignores the 1h expiry within the idle cap); rejects revoked/absent/idle-max.
func (h *Handler) handleOAuthRenew(w http.ResponseWriter, r *http.Request) {
	if h.oauthUnavailable() {
		http.Error(w, "brokered oauth not configured", http.StatusServiceUnavailable)
		return
	}
	raw := bearerToken(r)
	row, ok := h.store.SessionForRenew(raw)
	if !ok {
		http.Error(w, "session not renewable", http.StatusUnauthorized)
		return
	}
	refreshPlain, err := decryptSecret(h.cfg.SessionEncKey, row.RefreshEnc)
	if err != nil {
		h.logger.Error("decrypt refresh token failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	tokens, oauthErr, err := h.googleRefresh(r.Context(), string(refreshPlain))
	if err != nil {
		http.Error(w, "upstream refresh failed", http.StatusBadGateway)
		return
	}
	if oauthErr != "" {
		// invalid_grant etc. → the Google grant is dead (revoked). Kill the row.
		_ = h.store.RevokeSession(raw)
		http.Error(w, "refresh rejected: "+oauthErr, http.StatusUnauthorized)
		return
	}
	ident, err := h.auth.VerifyIDToken(r.Context(), tokens.IDToken) // re-run allowlist
	if err != nil {
		_ = h.store.RevokeSession(raw)
		http.Error(w, "not authorized", http.StatusForbidden)
		return
	}

	// Google rotates refresh tokens sometimes; keep the newest.
	newRefresh := row.RefreshEnc
	if tokens.RefreshToken != "" {
		if enc, encErr := encryptSecret(h.cfg.SessionEncKey, []byte(tokens.RefreshToken)); encErr == nil {
			newRefresh = enc
		}
	}
	newRaw, newHashHex, err := newDeviceToken()
	_ = newHashHex
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	exp := time.Now().Add(sessionTTL)
	if err := h.store.RotateSession(raw, newRaw, newRefresh, exp); err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, &sessionResponse{
		SessionToken: newRaw,
		Expiry:       exp.Unix(),
		Email:        ident.Email,
		Picture:      parsePictureClaim(tokens.IDToken),
	})
}
```

- [ ] **Step 4: Register the route** — in `relay/handlers.go` `Register`, after the `/oauth/exchange` line:

```go
	mux.HandleFunc("POST /oauth/renew", h.handleOAuthRenew)
```

- [ ] **Step 5: Run tests** — `cd relay && go test -run 'TestOAuthRenew|TestOAuthExchange' ./...` → PASS.

- [ ] **Step 6: Commit**

```bash
git add relay/oauth.go relay/handlers.go relay/oauth_test.go
git commit -m "feat(relay): POST /oauth/renew — refresh-backed session rotation + allowlist recheck"
```

---

### Task 6: `POST /oauth/signout` handler

**Files:**
- Modify: `relay/oauth.go` (add `handleOAuthSignout`)
- Modify: `relay/handlers.go` (register route)
- Modify: `relay/oauth_test.go` (signout test)

- [ ] **Step 1: Write the failing test** — append to `relay/oauth_test.go`:

```go
func TestOAuthSignoutRevokes(t *testing.T) {
	f := newFakeIssuer(t)
	defer f.close()
	f.tokenHandler = okTokenHandler(t, f)
	srv, _ := newOAuthTestServer(t, f, []string{"user@example.com"})
	defer srv.Close()

	_, ex := doExchange(t, srv, map[string]string{
		"code": "c", "code_verifier": "v", "redirect_uri": "http://127.0.0.1:49152",
	})
	tok := ex["session_token"].(string)

	req, _ := http.NewRequest("POST", srv.URL+"/oauth/signout", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, _ := http.DefaultClient.Do(req)
	if resp.StatusCode != 204 && resp.StatusCode != 200 {
		t.Fatalf("signout status=%d", resp.StatusCode)
	}
	resp.Body.Close()

	// The token must no longer work on a client endpoint.
	lr, _ := http.NewRequest("GET", srv.URL+"/v1/client/devices", nil)
	lr.Header.Set("Authorization", "Bearer "+tok)
	lresp, _ := http.DefaultClient.Do(lr)
	if lresp.StatusCode == 200 {
		t.Fatal("revoked session token still authenticates client calls")
	}
	lresp.Body.Close()
}
```

> This test also depends on Task 7 (client auth via session tokens). If you run it before Task 7, the final assertion won't hold; either implement Task 7 first or `t.Skip` the client-call assertion until then. Prefer implementing Task 7 next and running both.

- [ ] **Step 2: Implement** — append to `relay/oauth.go`:

```go
// handleOAuthSignout: POST /oauth/signout (Bearer session token). Revokes the
// session and destroys the stored Google refresh token. Idempotent.
func (h *Handler) handleOAuthSignout(w http.ResponseWriter, r *http.Request) {
	if raw := bearerToken(r); raw != "" {
		_ = h.store.RevokeSession(raw)
	}
	w.WriteHeader(http.StatusNoContent)
}
```

- [ ] **Step 3: Register the route** — in `relay/handlers.go` `Register`:

```go
	mux.HandleFunc("POST /oauth/signout", h.handleOAuthSignout)
```

- [ ] **Step 4: Commit** (tests run together with Task 7)

```bash
git add relay/oauth.go relay/handlers.go relay/oauth_test.go
git commit -m "feat(relay): POST /oauth/signout — revoke session + destroy refresh token"
```

---

### Task 7: Switch `/v1/client/*` auth to session tokens

**Files:**
- Modify: `relay/auth.go` (add `store` field + `SetStore`; rewrite `authenticateClient` session branch; remove Google-ID-token client path)
- Modify: `relay/handlers.go` (`NewHandler` calls `auth.SetStore(store)`)
- Modify: existing relay tests that authenticated client calls with a raw Google id token (convert to a minted session token or assert `VerifyIDToken` directly)
- Modify: `relay/oauth_test.go` (accept-session / reject-google tests)

**Interfaces:**
- Consumes: `Store.AuthenticateSession` (Task 2).
- Produces: `func (a *Authenticator) SetStore(s *Store)`; `authenticateClient` returns identity from a valid session token.

- [ ] **Step 1: Write the failing tests** — append to `relay/oauth_test.go`:

```go
func TestClientCallAcceptsSessionToken(t *testing.T) {
	f := newFakeIssuer(t)
	defer f.close()
	f.tokenHandler = okTokenHandler(t, f)
	srv, _ := newOAuthTestServer(t, f, []string{"user@example.com"})
	defer srv.Close()

	_, ex := doExchange(t, srv, map[string]string{
		"code": "c", "code_verifier": "v", "redirect_uri": "http://127.0.0.1:49152",
	})
	tok := ex["session_token"].(string)

	req, _ := http.NewRequest("GET", srv.URL+"/v1/client/devices", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, _ := http.DefaultClient.Do(req)
	if resp.StatusCode != 200 {
		t.Fatalf("session token must authenticate client calls, got %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestClientCallRejectsRawGoogleIDToken(t *testing.T) {
	f := newFakeIssuer(t)
	defer f.close()
	srv, _ := newOAuthTestServer(t, f, []string{"user@example.com"})
	defer srv.Close()

	idToken := f.mint(t, validClaims(f)) // a valid Google id token
	req, _ := http.NewRequest("GET", srv.URL+"/v1/client/devices", nil)
	req.Header.Set("Authorization", "Bearer "+idToken)
	resp, _ := http.DefaultClient.Do(req)
	if resp.StatusCode == 200 {
		t.Fatal("a raw Google id token must no longer authenticate client calls")
	}
	resp.Body.Close()
}
```

- [ ] **Step 2: Run to verify** — `cd relay && go test -run 'TestClientCall' ./...` → the reject test may already pass-by-accident only once code changes; run after implementing.

- [ ] **Step 3: Implement the auth switch** — in `relay/auth.go`:

  1. Add a field to `Authenticator` (near `gate`):

```go
	// store backs session-token client auth (brokered OAuth). Late-bound by
	// NewHandler (SetStore), mirroring SetGate/SetRateLimits.
	store *Store
```

  2. Add the setter (near `SetGate`):

```go
// SetStore binds the session store for client session-token auth. Called once
// at startup after the Store exists.
func (a *Authenticator) SetStore(s *Store) { a.store = s }
```

  3. Replace the body of `authenticateClient` **after** the DEV_AUTH block (the two `gate`-based branches) with a session-token lookup:

```go
	// Brokered OAuth: the client bearer is a relay-minted session token, not a
	// raw Google ID token. Google verification happens only at /oauth/exchange
	// and /oauth/renew (which stamp the allowlist onto the session); a valid,
	// unexpired, unrevoked session is sufficient here.
	if a.store != nil {
		if ident, ok := a.store.AuthenticateSession(token); ok {
			return ident, nil
		}
	}
	return Identity{}, ErrUnauthorized
```

  Delete the now-unused `gate`-based client branches (`if a.gate == nil ... verifyIDTokenIP` and the "Flag ON" block) from `authenticateClient` ONLY. Keep `VerifyIdentity`, `VerifyIDToken`, `verifyIDTokenIP`, `emailAllowed` — they are still used by `/oauth/exchange`, `/oauth/renew`, enroll, and admin.

- [ ] **Step 4: Bind the store** — in `relay/handlers.go` `NewHandler`, right after `auth.SetRateLimits(h.rl)`:

```go
	auth.SetStore(store)
```

- [ ] **Step 5: Fix existing-test fallout.** Run `cd relay && go test ./...` and fix any test that authenticated a `/v1/client/*` call with a raw Google id token (it will now 401). Convert each to mint a session via `/oauth/exchange` first, or use the DEV_AUTH path (`DevAuth:true, DevClientToken:"..."`) which is unchanged. Tests of `VerifyIDToken`/`VerifyIdentity` themselves are unaffected. Iterate until green.

- [ ] **Step 6: Run the whole relay suite** — `cd relay && go test ./...` → PASS.

- [ ] **Step 7: Commit**

```bash
git add relay/auth.go relay/handlers.go relay/*_test.go
git commit -m "feat(relay): authenticate /v1/client/* with relay session tokens (drop raw Google id-token path)"
```

---

## Phase 2 — macOS app (Swift)

Build check: `zig build -Doptimize=Debug`. The Swift unit tests run in the hosted test target; the pure OAuth pieces additionally run under the standalone swiftc harness (see the WP-B2 notes / existing harness).

### Task 8: Repoint `GoogleOAuth.swift` from Google's token endpoint to the relay

**Files:**
- Modify: `macos/Sources/Features/Remote/GoogleOAuth.swift`
- Modify: `macos/Tests/Remote/GoogleOAuthTests.swift`

**Interfaces:**
- Produces: `GoogleOAuth.Endpoints { authorization: URL; exchange: URL; renew: URL; signout: URL }`; `GoogleOAuth.RelaySessionClient` with `SessionResponse` and `exchange`/`renew`/`signOut`.
- Removes: `TokenClient`, `TokenResponse`, `IDTokenClaims` (relay returns display fields), `CachedIDToken`, `parseIDTokenClaims`, expiry math. Keeps: `PKCE`, `authorizationURL`, `LoopbackCodeReceiver`.

- [ ] **Step 1: Update `Endpoints`** in `GoogleOAuth.swift`:

```swift
    /// The OAuth/relay endpoints in use. `authorization` is Google's (the
    /// browser leg); the token exchange/renew/signout are the RELAY's — the app
    /// never talks to Google's token endpoint (BFF). Injectable for tests only.
    struct Endpoints: Sendable {
        var authorization: URL
        var exchange: URL
        var renew: URL
        var signout: URL

        static let googleAuthorization =
            URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!

        /// Production endpoints for a given relay base (e.g. the Azure relay).
        static func relay(base: URL) -> Endpoints {
            Endpoints(
                authorization: googleAuthorization,
                exchange: base.appendingPathComponent("oauth/exchange"),
                renew: base.appendingPathComponent("oauth/renew"),
                signout: base.appendingPathComponent("oauth/signout"))
        }
    }
```

- [ ] **Step 2: Replace `TokenClient` with `RelaySessionClient`.** Delete `TokenResponse`, `IDTokenClaims`, `ClaimsError`, `parseIDTokenClaims`, `CachedIDToken`, and `TokenClient`. Add:

```swift
    // MARK: - Relay session client

    /// The app's client for the relay's brokered-OAuth endpoints. It exchanges
    /// the PKCE authorization code for a relay session token, renews it, and
    /// signs out. Google tokens never touch the client.
    struct RelaySessionClient {
        let endpoints: Endpoints
        var urlSession: URLSession = .shared

        /// The relay's session response: an opaque session token, its expiry
        /// (unix seconds), and display fields.
        struct SessionResponse: Decodable, Equatable {
            let sessionToken: String
            let expiry: Double
            let email: String
            let picture: String?

            enum CodingKeys: String, CodingKey {
                case sessionToken = "session_token"
                case expiry
                case email
                case picture
            }

            var expiresAt: Date { Date(timeIntervalSince1970: expiry) }
        }

        enum SessionError: LocalizedError {
            case http(Int, String)
            case badResponse
            var errorDescription: String? {
                switch self {
                case .http(let code, let detail):
                    return detail.isEmpty
                        ? "The relay returned HTTP \(code) during sign-in."
                        : "The relay returned HTTP \(code) during sign-in: \(detail)"
                case .badResponse:
                    return "The relay returned a sign-in response that couldn't be parsed."
                }
            }
        }

        /// POST /oauth/exchange — trade the PKCE code for a relay session token.
        func exchange(code: String, redirectURI: String, codeVerifier: String) async throws -> SessionResponse {
            var req = URLRequest(url: endpoints.exchange)
            req.httpMethod = "POST"
            req.timeoutInterval = 20
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "code": code,
                "code_verifier": codeVerifier,
                "redirect_uri": redirectURI,
            ])
            return try await send(req)
        }

        /// POST /oauth/renew — rotate the session token using the relay-held
        /// refresh token. The current (possibly just-expired) token is the bearer.
        func renew(sessionToken: String) async throws -> SessionResponse {
            var req = URLRequest(url: endpoints.renew)
            req.httpMethod = "POST"
            req.timeoutInterval = 20
            req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
            return try await send(req)
        }

        /// POST /oauth/signout — best-effort revoke (ignore failures).
        func signOut(sessionToken: String) async {
            var req = URLRequest(url: endpoints.signout)
            req.httpMethod = "POST"
            req.timeoutInterval = 10
            req.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
            _ = try? await urlSession.data(for: req)
        }

        private func send(_ req: URLRequest) async throws -> SessionResponse {
            let (data, resp) = try await urlSession.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw SessionError.badResponse }
            guard (200..<300).contains(http.statusCode) else {
                let detail = String(data: data, encoding: .utf8) ?? ""
                throw SessionError.http(http.statusCode, detail.prefix(200).description)
            }
            guard let out = try? JSONDecoder().decode(SessionResponse.self, from: data) else {
                throw SessionError.badResponse
            }
            return out
        }
    }
```

Keep `TokenClient.formEncode`/`formEscape`? They are no longer used — delete them with `TokenClient`. (If any test referenced `formEncode`, delete that test.)

- [ ] **Step 3: Update tests** in `GoogleOAuthTests.swift`: keep `GoogleOAuthPKCETests` and `authorizationURLCarriesPKCEAndScopes`. Delete `GoogleOAuthTokenParsingTests` cases that decode `TokenResponse`/`IDTokenClaims`/`CachedIDToken`/`formEncode` and all of `GoogleOAuthExpiryTests`. Add a decode test for `RelaySessionClient.SessionResponse`:

```swift
struct RelaySessionResponseTests {
    @Test func decodesRelaySessionResponse() throws {
        let json = #"{"session_token":"sess_abc","expiry":1900000000,"email":"dzearing@gmail.com","picture":"https://x/p.png"}"#
        let r = try JSONDecoder().decode(
            GoogleOAuth.RelaySessionClient.SessionResponse.self, from: Data(json.utf8))
        #expect(r.sessionToken == "sess_abc")
        #expect(r.email == "dzearing@gmail.com")
        #expect(r.picture == "https://x/p.png")
        #expect(r.expiresAt == Date(timeIntervalSince1970: 1_900_000_000))
    }
}
```

- [ ] **Step 4: Build** — `zig build -Doptimize=Debug` → compiles (RelayAccount still references removed symbols; expect errors here that Task 9 fixes — so build fully only after Task 9). Instead, at this step just confirm `GoogleOAuth.swift` itself is internally consistent by grepping for leftover `TokenClient`/`TokenResponse` usages: `rg -n "TokenClient|TokenResponse|IDTokenClaims|CachedIDToken|parseIDTokenClaims" macos/Sources`.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Features/Remote/GoogleOAuth.swift macos/Tests/Remote/GoogleOAuthTests.swift
git commit -m "feat(macos): repoint OAuth token exchange from Google to the relay (BFF client)"
```

---

### Task 9: `RelayAccount.swift` — session-token storage, remove runtime credential lookups

**Files:**
- Modify: `macos/Sources/Features/Remote/RelayAccount.swift`

**Interfaces:**
- Produces: `RelayAccount.signIn()` (unchanged signature), `currentToken() async throws -> String`, `resolveToken() async -> String?` (session-only), `hasCredentials`, `isSignedIn`, `isConfigured`, `email`, `pictureURL`; `RelayAccountKeychain.Stored { sessionToken, expiry, email, picture? }`.
- Removes: `ClientConfig`, `clientConfig()`, `clientIDDefaultsKey`, `clientSecretDefaultsKey`, `devToken`, all env/UserDefaults credential reads.

- [ ] **Step 1: Change Keychain `Stored`** to the session shape:

```swift
    struct Stored: Codable, Equatable {
        var sessionToken: String
        /// Session-token expiry (unix seconds), from the relay.
        var expiry: Double
        var email: String
        var picture: String?
    }
```

- [ ] **Step 2: Client id from the bundle.** Replace `clientConfig()`/`ClientConfig`/`clientIDDefaultsKey`/`clientSecretDefaultsKey`/`isConfigured` with:

```swift
    /// The Google OAuth client id — a build-time constant baked into the app
    /// bundle (Info.plist `GhosttyGoogleClientID`, injected via the
    /// `-Dgoogle-client-id` build option). Injectable for tests. The client id
    /// is public (it appears in the browser authorize URL); the confidential
    /// client secret lives ONLY on the relay.
    let clientID: String

    nonisolated static func bundledClientID() -> String {
        (Bundle.main.infoDictionary?["GhosttyGoogleClientID"] as? String) ?? ""
    }

    /// Sign-in is possible whenever a client id is baked in — always true in a
    /// shipped build. (No runtime credential lookup remains.)
    nonisolated static var isConfigured: Bool { !bundledClientID().isEmpty }
```

- [ ] **Step 3: Rework `init`** to take/relay the client id + relay endpoints and load the stored session:

```swift
    init(
        clientID: String = RelayAccount.bundledClientID(),
        endpoints: GoogleOAuth.Endpoints = .relay(base: RelayAccount.defaultRelayBase),
        keychain: RelayAccountKeychain =
            RelayAccountKeychain(service: "com.dzearing.ghoztty.relay-account"),
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.clientID = clientID
        self.endpoints = endpoints
        self.keychain = keychain
        self.openURL = openURL
        initialLoadTask = Task { [weak self] in
            guard let self else { return }
            let stored = await Self.loadStoredOffMain(self.keychain)
            self.cachedSession = stored
            self.email = stored?.email
            self.pictureURL = stored?.picture.flatMap(URL.init(string:))
        }
    }

    /// The relay base URL (mirrors RelayDirectoryClient.defaultBase).
    nonisolated static var defaultRelayBase: URL {
        URL(string: RelayDirectoryClient.defaultBase)!
    }
```

Add an in-memory cache field replacing `cachedIDToken`:

```swift
    /// In-memory copy of the stored session (token + expiry), so the hot path
    /// avoids a Keychain read. Renewed via /oauth/renew near expiry.
    private var cachedSession: RelayAccountKeychain.Stored?
```

- [ ] **Step 4: Rewrite `signIn()`** to exchange the code at the relay:

```swift
    func signIn() async throws {
        guard !clientID.isEmpty else { throw AccountError.notConfigured }

        let verifier = GoogleOAuth.PKCE.generateVerifier()
        let state = GoogleOAuth.PKCE.randomURLSafeToken(byteCount: 16)
        let receiver = try GoogleOAuth.LoopbackCodeReceiver(expectedState: state)
        let port = try await receiver.start()
        let redirectURI = "http://127.0.0.1:\(port)"

        let url = GoogleOAuth.authorizationURL(
            endpoints: endpoints,
            clientID: clientID,
            redirectURI: redirectURI,
            state: state,
            codeChallenge: GoogleOAuth.PKCE.challenge(for: verifier))
        guard openURL(url) else {
            receiver.cancel()
            throw AccountError.browserFailed
        }

        let code: String
        do {
            code = try await receiver.waitForCode()
        } catch {
            receiver.cancel()
            throw error
        }

        let client = GoogleOAuth.RelaySessionClient(endpoints: endpoints)
        let session = try await client.exchange(
            code: code, redirectURI: redirectURI, codeVerifier: verifier)

        let stored = RelayAccountKeychain.Stored(
            sessionToken: session.sessionToken, expiry: session.expiry,
            email: session.email, picture: session.picture)
        try keychain.save(stored)
        cachedSession = stored
        refreshTask?.cancel(); refreshTask = nil
        self.email = session.email
        self.pictureURL = session.picture.flatMap(URL.init(string:))
        if self === Self.shared {
            (NSApp.delegate as? AppDelegate)?.relayAccountDidSignIn()
        }
    }
```

> `GoogleOAuth.authorizationURL` takes `endpoints.authorization` internally — confirm it references `endpoints.authorization` (it does). No signature change needed.

- [ ] **Step 5: Rewrite `currentToken()`** (was `currentIDToken`) to renew via the relay:

```swift
    /// The current relay session token: the cached one while it has >60s of
    /// life, else a freshly renewed one (via /oauth/renew, which uses the
    /// relay-held Google refresh token). Throws when signed out or renew fails.
    func currentToken() async throws -> String {
        let leeway: TimeInterval = 60
        if let s = cachedSession, s.expiry - Date().timeIntervalSince1970 > leeway {
            return s.sessionToken
        }
        if let task = refreshTask {
            return try await task.value.sessionToken
        }
        guard let stored = cachedSession ?? (await Self.loadStoredOffMain(keychain)) else {
            throw AccountError.signedOut
        }
        let client = GoogleOAuth.RelaySessionClient(endpoints: endpoints)
        let task = Task { try await client.renew(sessionToken: stored.sessionToken) }
        refreshTask = task
        defer { refreshTask = nil }
        let session = try await task.value
        let newStored = RelayAccountKeychain.Stored(
            sessionToken: session.sessionToken, expiry: session.expiry,
            email: session.email, picture: session.picture)
        try? keychain.save(newStored)
        cachedSession = newStored
        if pictureURL?.absoluteString != session.picture {
            pictureURL = session.picture.flatMap(URL.init(string:))
        }
        return session.sessionToken
    }
```

Change `refreshTask` type from `Task<GoogleOAuth.TokenResponse, Error>?` to `Task<GoogleOAuth.RelaySessionClient.SessionResponse, Error>?`.

- [ ] **Step 6: Rewrite `signOut()`** to revoke server-side (best-effort) before clearing:

```swift
    func signOut() {
        if let token = cachedSession?.sessionToken {
            let client = GoogleOAuth.RelaySessionClient(endpoints: endpoints)
            Task { await client.signOut(sessionToken: token) }
        }
        keychain.delete()
        cachedSession = nil
        refreshTask?.cancel(); refreshTask = nil
        email = nil
        pictureURL = nil
        if self === Self.shared {
            MachineRegistry.shared.clearRelayMachines()
            (NSApp.delegate as? AppDelegate)?.relayAccountDidSignOut()
        }
    }
```

- [ ] **Step 7: Rewrite the token-resolution seam** — replace the `devToken` + `resolveToken` extension:

```swift
extension RelayAccount {
    /// THE token-resolution seam for every relay call: the signed-in account's
    /// relay session token (renewing as needed), or nil when signed out.
    static func resolveToken() async -> String? {
        try? await shared.currentToken()
    }

    /// Synchronous capability check: is there a stored session? Used where an
    /// async resolve would be premature (e.g. "should the chooser open").
    static var hasCredentials: Bool { shared.isSignedIn }
}
```

- [ ] **Step 8: Purge remaining old references** — remove `AccountError.badTokenResponse` uses tied to Google claims if now unused (keep the case if still referenced), and delete the now-dead `currentIDToken` name. Grep: `rg -n "currentIDToken|devToken|clientConfig|GHOSTTY_RELAY_TOKEN|GHOSTTY_GOOGLE|GhosttyGoogleClient|badTokenResponse" macos/Sources/Features/Remote/RelayAccount.swift`.

- [ ] **Step 9: Build** — `zig build -Doptimize=Debug`. Fix consumer breakages surfaced here in Task 10 (they call `resolveToken`/`hasCredentials`/`isConfigured` — signatures preserved, so most compile; the failures will be in comment/string references and `MachineChooserView`/`Machine.swift` uses of `isConfigured`, all still valid).

- [ ] **Step 10: Commit**

```bash
git add macos/Sources/Features/Remote/RelayAccount.swift
git commit -m "feat(macos): store relay session token in Keychain; remove runtime credential + devToken lookups"
```

---

### Task 10: Update consumers, error strings, and the ⌘⇧N chooser guard

**Files:**
- Modify: `macos/Sources/App/macOS/AppDelegate.swift` (⌘⇧N guard ~line 1052-1066; error string ~1178)
- Modify: `macos/Sources/Features/Remote/RelayDirectoryClient.swift` (error strings mentioning `GHOSTTY_RELAY_TOKEN`)
- Modify: `macos/Sources/Features/Remote/MachineChooserView.swift`, `RemoteActivityMonitor.swift`, `IPCServer.swift`, `Machine.swift`, `BaseTerminalController.swift`, `TerminalController.swift` — comment/string cleanups only; verify calls still compile.

- [ ] **Step 1: Simplify the ⌘⇧N guard.** In `AppDelegate.newRemoteWindow(_:)`, replace the 3-condition guard + bail-to-local (lines ~1055-1066) with an always-open chooser:

```swift
    @IBAction func newRemoteWindow(_ sender: Any?) {
        let registry = MachineRegistry.shared

        // Sign-in is always possible (the Google client id is baked into the
        // build), so ⌘⇧N ALWAYS presents the chooser — "Local" + any machines +
        // the sign-in/out footer. Never silently open a local window (that made
        // the app look broken when signed out with zero machines).
        MachineChooser.present(registry: registry) { [weak self] selected in
            // ... unchanged body ...
        }
    }
```

Leave the closure body unchanged.

- [ ] **Step 2: Update user-facing / dev strings.** In `AppDelegate.swift` ~line 1178, change:

```swift
            return "not signed in: sign in to open relay windows"
```

In `RelayDirectoryClient.swift`, update `DirectoryError` messages:

```swift
            case .noAccount:
                return "No relay account is available. Sign in with Google."
            case .unauthorized:
                return "The relay rejected the session token (401). Sign in again."
```

And the doc comment atop `RelayDirectoryClient` and the `current()` doc: drop the `GHOSTTY_RELAY_TOKEN` mention (the bearer is now the relay session token from `resolveToken()`).

- [ ] **Step 3: Grep for stragglers** and fix any remaining `GHOSTTY_RELAY_TOKEN` / devToken references in Swift sources:

```bash
rg -n "GHOSTTY_RELAY_TOKEN|devToken|GHOSTTY_GOOGLE|GhosttyGoogleClientID\"|clientConfig" macos/Sources
```

(The `GhosttyGoogleClientID` Info.plist key read in `RelayAccount.bundledClientID()` is expected and correct — leave it.)

- [ ] **Step 4: Build** — `zig build -Doptimize=Debug` → SUCCESS.

- [ ] **Step 5: Run Swift tests** — build/run the hosted test target (or the swiftc OAuth harness). Confirm the OAuth/PKCE/session tests pass. Command (hosted target):

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild test -project macos/Ghostty.xcodeproj -scheme Ghostty \
  -only-testing:GhosttyTests/RelaySessionResponseTests \
  -only-testing:GhosttyTests/GoogleOAuthPKCETests 2>&1 | tail -20
```

> If the scheme/target names differ, list them with `xcodebuild -list -project macos/Ghostty.xcodeproj` and adjust. The pure pieces also run under the existing swiftc harness — use whichever the repo's WP-B2 notes document.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources
git commit -m "feat(macos): ⌘⇧N always opens the chooser; drop GHOSTTY_RELAY_TOKEN references"
```

---

## Phase 3 — Build / release wiring

### Task 11: `build.zig` client-id option + dev local-file fallback

**Files:**
- Modify: `build.zig` (add option; resolve dev file)
- Modify: `.gitignore` (ignore the dev file)
- (Config plumbing to xcodebuild is Task 12.)

- [ ] **Step 1: Add the option + resolution** near the other `b.option(...)` calls in `build.zig`:

```zig
    // Google OAuth client id (public; used to build the browser authorize URL).
    // Injected into the macOS app's Info.plist as GhosttyGoogleClientID. For
    // releases, CI passes -Dgoogle-client-id=<secret>. For dev builds, if the
    // option is empty we read a git-ignored local file so a developer's build
    // "just works" without exporting anything.
    const google_client_id: []const u8 = b.option(
        []const u8,
        "google-client-id",
        "Google OAuth client id baked into the macOS app (Info.plist)",
    ) orelse readDevGoogleClientID(b);
```

Add the helper (near the bottom of `build.zig`, or in the build-pkg config that `GhosttyXcodebuild` reads — see Task 12 for where the value must land):

```zig
fn readDevGoogleClientID(b: *std.Build) []const u8 {
    const path = "macos/google-client-id.txt";
    const data = std.fs.cwd().readFileAlloc(b.allocator, path, 4096) catch return "";
    return std.mem.trim(u8, data, " \t\r\n");
}
```

Thread `google_client_id` into the build config struct that `GhosttyXcodebuild.init` consumes (the same `config` value that already carries `version`). Read `src/build/Config.zig` (or wherever `config.version` is defined) and add a `google_client_id: []const u8` field, set from this option.

- [ ] **Step 2: Ignore the dev file** — append to `.gitignore`:

```
# Local Google OAuth client id for dev builds (never commit; injected via
# -Dgoogle-client-id in CI). The id is public but managed as build config.
macos/google-client-id.txt
```

- [ ] **Step 3: Verify** — `zig build -Doptimize=Debug -Dgoogle-client-id=test.apps.googleusercontent.com` builds; `zig build -Doptimize=Debug` (no option, no file) builds with an empty id.

- [ ] **Step 4: Commit**

```bash
git add build.zig .gitignore src/build/Config.zig
git commit -m "build: -Dgoogle-client-id option + git-ignored dev local-file fallback"
```

---

### Task 12: Pass the client id through xcodebuild into Info.plist

**Files:**
- Modify: `src/build/GhosttyXcodebuild.zig` (pass `GHOSTTY_GOOGLE_CLIENT_ID=<id>` build setting on both the build and run xcodebuild invocations)
- Modify: `macos/Ghostty-Info.plist` (add the key with a build-setting reference)

- [ ] **Step 1: Add the plist key** — in `macos/Ghostty-Info.plist`, after the `GhosttyCommit` entry:

```xml
	<key>GhosttyGoogleClientID</key>
	<string>$(GHOSTTY_GOOGLE_CLIENT_ID)</string>
```

- [ ] **Step 2: Pass the build setting** — in `src/build/GhosttyXcodebuild.zig`, alongside the `MARKETING_VERSION=...` `addArgs` (build step, ~line 87), add:

```zig
        step.addArgs(&.{
            b.fmt("GHOSTTY_GOOGLE_CLIENT_ID={s}", .{config.google_client_id}),
        });
```

Do the same on the second xcodebuild invocation (the run/native step, ~line 116) so `zig build run` also bakes it in. `config.google_client_id` is the field added in Task 11.

- [ ] **Step 3: Verify substitution.** Build the debug app with a marker id and confirm it lands in the built Info.plist:

```bash
export PATH=/opt/homebrew/opt/zig@0.15/bin:/opt/homebrew/opt/gettext/bin:$PATH
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
zig build -Doptimize=Debug -Dgoogle-client-id=marker.apps.googleusercontent.com
/usr/libexec/PlistBuddy -c 'Print :GhosttyGoogleClientID' \
  zig-out/Ghoztty-Debug.app/Contents/Info.plist
# Expected: marker.apps.googleusercontent.com
```

> If `$(...)` substitution does not populate the key (some `GENERATE_INFOPLIST_FILE` setups only substitute known keys), fall back to a post-build PlistBuddy `Set :GhosttyGoogleClientID` step in `GhosttyXcodebuild.zig` mirroring how the release workflow sets `GhosttyCommit`. Verify with the same PlistBuddy read.

- [ ] **Step 4: Commit**

```bash
git add src/build/GhosttyXcodebuild.zig macos/Ghostty-Info.plist
git commit -m "build(macos): inject GhosttyGoogleClientID into Info.plist at build time"
```

---

### Task 13: Wire the release workflows to inject the client id from a secret

**Files:**
- Modify: `.github/workflows/release-tip.yml`
- Modify: `.github/workflows/release-tag.yml`

- [ ] **Step 1: Find the macOS build step** in each workflow (the `zig build` / `xcodebuild` invocation that produces `macos/build/Release/Ghostty.app`, near the existing `PlistBuddy -c "Set :GhosttyCommit ..."` lines).

- [ ] **Step 2: Inject the id.** If the build goes through `zig build`, add `-Dgoogle-client-id=${{ secrets.GOOGLE_CLIENT_ID }}` to that invocation. If it invokes `xcodebuild` directly, either pass `GHOSTTY_GOOGLE_CLIENT_ID=${{ secrets.GOOGLE_CLIENT_ID }}` as a build setting, or add a PlistBuddy step next to the `GhosttyCommit` one:

```yaml
          /usr/libexec/PlistBuddy -c "Set :GhosttyGoogleClientID ${{ secrets.GOOGLE_CLIENT_ID }}" "macos/build/Release/Ghostty.app/Contents/Info.plist"
```

Match the mechanism to how each workflow actually builds (read the surrounding steps first).

- [ ] **Step 3: Note for the maintainer.** Add the GitHub Actions repo secret `GOOGLE_CLIENT_ID` (the Desktop client id). This is a manual step performed in the GitHub UI — document it in the roadmap (Task 14). The workflow change is inert until the secret exists (empty → same as a dev build with no id, which fails closed on sign-in only, not at build).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release-tip.yml .github/workflows/release-tag.yml
git commit -m "ci: inject Google client id into release builds from GOOGLE_CLIENT_ID secret"
```

---

## Phase 4 — Docs, verification, cutover

### Task 14: Update the roadmap doc

**Files:**
- Modify: `docs/design/remote-relay-roadmap.md`

- [ ] **Step 1** Add a dated section documenting the brokered BFF model: secret server-side only; `/oauth/exchange` + `/oauth/renew` + `/oauth/signout`; the `sessions` table + AES-GCM refresh-token encryption (`SESSION_ENC_KEY`); `/v1/client/*` now session-token authed; the build-time client id (`-Dgoogle-client-id` → Info.plist `GhosttyGoogleClientID`); and that the `GHOSTTY_GOOGLE_CLIENT_ID/_SECRET` env, `GhosttyGoogleClient*` UserDefaults, and `GHOSTTY_RELAY_TOKEN` devToken paths are REMOVED. Note the new relay env (`SESSION_ENC_KEY`) and the GitHub secret `GOOGLE_CLIENT_ID`.

- [ ] **Step 2: Commit**

```bash
git add docs/design/remote-relay-roadmap.md
git commit -m "docs: roadmap reflects brokered BFF OAuth (session tokens, build-time client id)"
```

---

### Task 15: Local end-to-end verification (debug app + local relay)

No code changes — a verification gate. Requires the user to provide the **Desktop client id + secret** and to generate a `SESSION_ENC_KEY`.

- [ ] **Step 1: Generate a session key** — `openssl rand -base64 32` (this is the local `SESSION_ENC_KEY`).
- [ ] **Step 2: Run the relay locally**:

```bash
cd relay
GOOGLE_CLIENT_ID='<desktop-id>' GOOGLE_CLIENT_SECRET='<desktop-secret>' \
ALLOWED_EMAILS='dzearing@gmail.com' DEV_AUTH=false \
SESSION_ENC_KEY='<from step 1>' STATE_DIR="$(mktemp -d)" LISTEN_ADDR=127.0.0.1:8080 \
go run .
```

- [ ] **Step 3: Build the debug app with the real client id + point it at the local relay**:

```bash
export PATH=/opt/homebrew/opt/zig@0.15/bin:/opt/homebrew/opt/gettext/bin:$PATH
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
zig build -Doptimize=Debug -Dgoogle-client-id='<desktop-id>'
GHOSTTY_RELAY_BASE=http://127.0.0.1:8080 open zig-out/Ghoztty-Debug.app
```

- [ ] **Step 4: Drive the flow** (GUI): ⌘⇧N → chooser opens (never a silent local window) → Sign In with Google → complete browser 2FA → footer shows `dzearing@gmail.com`. Confirm on the relay logs a session was minted. Verify the chooser lists devices (a `/v1/client/devices` call authed by the session token). Leave it >1h or force a renew (restart app) and confirm it renews without re-opening the browser. Sign Out → confirm the relay revokes.
- [ ] **Step 5:** Confirm no Google refresh/id token is in the app Keychain — only the session token:

```bash
# The Keychain item is service com.dzearing.ghoztty.relay-account; inspect via
# Keychain Access or `security find-generic-password -s com.dzearing.ghoztty.relay-account -w`
# and confirm the JSON has `sessionToken`, not a Google refresh token.
```

- [ ] **Step 6:** Full green gate: `zig build -Doptimize=Debug` && `cd relay && go test ./...` && Swift tests.

---

### Task 16: Production cutover (Azure relay + fresh app build)

No repo changes — an operational gate, done with the user present. Brief relay disruption is acceptable (sole user).

- [ ] **Step 1:** On the Azure VM, add to `/etc/ghoztty-relay.env`: `SESSION_ENC_KEY=<prod key>` (generate a NEW one for prod), and confirm `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `ALLOWED_EMAILS`, `DEV_AUTH=false`.
- [ ] **Step 2:** Deploy the new relay binary (the goose migration `0007_sessions.sql` runs automatically on start). Restart `systemctl restart ghoztty-relay`. Check `/healthz` and logs.
- [ ] **Step 3:** Add the GitHub Actions secret `GOOGLE_CLIENT_ID` (Desktop id) so release builds bake it in.
- [ ] **Step 4:** Build the app with the real client id (or cut a release), re-sign-in, verify the live browser flow end-to-end against the prod relay (⌘⇧N → sign in → list devices → open a remote window → renew). Existing agents/devices are unaffected (device tokens are separate).
- [ ] **Step 5:** Final: confirm a raw Google id token no longer authenticates `/v1/client/*` on prod (spot check with `curl`), and that sign-out revokes.

---

## Self-Review

**Spec coverage:**
- Relay `/oauth/exchange` + renew + signout → Tasks 4, 5, 6. ✅
- Google code→token exchange server-side w/ confidential secret → Task 3 (`googleExchangeCode`). ✅
- id_token aud + `ALLOWED_EMAILS` verification reuse → Task 4 (`mintSession` → `VerifyIDToken`). ✅
- Refresh + id tokens server-side only; refresh encrypted at rest → Tasks 1, 2, 4. ✅
- Short-lived session token, opaque + SQLite, rotated on renew → Task 2, 5. ✅
- `/v1/client/*` switch to session tokens → Task 7. ✅
- App: repoint TokenClient, delete client_secret → Task 8. ✅
- App: session token in Keychain; update resolveToken/hasCredentials/isSignedIn + consumers → Tasks 9, 10. ✅
- Remove env + UserDefaults credential paths; devToken removed → Task 9. ✅
- Build-time client id via build.zig option + dev file + CI secret → Tasks 11, 12, 13. ✅
- ⌘⇧N never silently opens local → Task 10. ✅
- Docs → Task 14. ✅
- Tests (relay + Swift) → in every code task; suites gated in Tasks 7, 10, 15. ✅
- Rollout local e2e + prod cutover → Tasks 15, 16. ✅

**Placeholder scan:** No "TBD"/"add error handling"-style gaps; code is concrete. The two conditional fallbacks (Info.plist `$(...)` substitution in Task 12; release-build mechanism in Task 13) are explicit branches with verification commands, not vague placeholders.

**Type consistency:** `sessionResponse{session_token, expiry, email, picture}` (Go) ↔ `RelaySessionClient.SessionResponse{sessionToken, expiry, email, picture}` (Swift) with matching JSON keys. `Stored{sessionToken, expiry, email, picture}` (Swift Keychain) matches. `CreateSession/AuthenticateSession/SessionForRenew/RotateSession/RevokeSession` names are used consistently across Tasks 2, 4, 5, 6, 7. `sessionRow.RefreshEnc` used in Tasks 2 and 5. `googleTokens.RefreshToken/IDToken` used in Tasks 3, 4, 5. `config.google_client_id` (Zig) threaded Tasks 11→12.
