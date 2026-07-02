package main

// Tests for the real-OIDC client-auth path (WP-B1) against a FAKE LOCAL ISSUER:
// an httptest server that serves an OIDC discovery document + JWKS and mints
// its own RS256 ID tokens. No Google involved. Everything is stdlib — the
// tokens are hand-rolled JWTs signed with crypto/rsa.

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

const (
	testClientID = "test-client-id.apps.googleusercontent.com"
	testKeyID    = "test-key-1"
	allowedEmail = "owner@example.com"
	testSub      = "google-sub-1234567890"
)

// fakeIssuer is a minimal OIDC identity provider: discovery doc + JWKS +
// RS256 token minting.
type fakeIssuer struct {
	srv *httptest.Server
	key *rsa.PrivateKey
}

func newFakeIssuer(t *testing.T) *fakeIssuer {
	t.Helper()

	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate rsa key: %v", err)
	}
	f := &fakeIssuer{key: key}

	mux := http.NewServeMux()
	mux.HandleFunc("/.well-known/openid-configuration", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"issuer":                                f.srv.URL,
			"authorization_endpoint":                f.srv.URL + "/auth",
			"token_endpoint":                        f.srv.URL + "/token",
			"jwks_uri":                              f.srv.URL + "/jwks",
			"response_types_supported":              []string{"id_token"},
			"subject_types_supported":               []string{"public"},
			"id_token_signing_alg_values_supported": []string{"RS256"},
		})
	})
	mux.HandleFunc("/jwks", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"keys": []map[string]any{{
				"kty": "RSA",
				"alg": "RS256",
				"use": "sig",
				"kid": testKeyID,
				"n":   base64.RawURLEncoding.EncodeToString(key.N.Bytes()),
				"e":   base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes()),
			}},
		})
	})

	f.srv = httptest.NewServer(mux)
	t.Cleanup(f.srv.Close)
	return f
}

// validClaims returns a claim set that the authenticator must accept. Tests
// mutate individual claims to produce each rejection case.
func (f *fakeIssuer) validClaims() map[string]any {
	now := time.Now()
	return map[string]any{
		"iss":            f.srv.URL,
		"aud":            testClientID,
		"sub":            testSub,
		"email":          "Owner@Example.com", // mixed case: must come back lowercased
		"email_verified": true,
		"iat":            now.Add(-time.Minute).Unix(),
		"exp":            now.Add(time.Hour).Unix(),
	}
}

// mint produces an RS256-signed JWT over claims using key (defaults to the
// issuer's own key). Passing a different key simulates a forged signature.
func mint(t *testing.T, key *rsa.PrivateKey, claims map[string]any) string {
	t.Helper()

	seg := func(v any) string {
		b, err := json.Marshal(v)
		if err != nil {
			t.Fatalf("marshal jwt segment: %v", err)
		}
		return base64.RawURLEncoding.EncodeToString(b)
	}
	signingInput := seg(map[string]any{"alg": "RS256", "typ": "JWT", "kid": testKeyID}) + "." + seg(claims)
	sum := sha256.Sum256([]byte(signingInput))
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, sum[:])
	if err != nil {
		t.Fatalf("sign jwt: %v", err)
	}
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(sig)
}

// newOIDCAuthenticator builds an Authenticator against the fake issuer,
// mirroring main.go's lifecycle exactly: the init context is cancelled as soon
// as NewAuthenticator returns. Token verification (and thus the lazy JWKS
// fetch) happens AFTER that cancellation, proving verify-time key fetches do
// not depend on the init context.
func newOIDCAuthenticator(t *testing.T, f *fakeIssuer, mutate func(*Config)) *Authenticator {
	t.Helper()

	cfg := &Config{
		GoogleClientID: testClientID,
		IssuerURL:      f.srv.URL,
		AllowedEmails:  []string{allowedEmail},
	}
	if mutate != nil {
		mutate(cfg)
	}

	initCtx, cancelInit := context.WithTimeout(context.Background(), 10*time.Second)
	a, err := NewAuthenticator(initCtx, cfg, slog.New(slog.NewTextHandler(io.Discard, nil)))
	cancelInit()
	if err != nil {
		t.Fatalf("NewAuthenticator: %v", err)
	}
	return a
}

func requestWithBearer(token string) *http.Request {
	r := httptest.NewRequest(http.MethodGet, "/v1/client/devices", nil)
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	return r
}

// TestOIDCValidTokenAccepted: a properly signed, addressed, fresh token for an
// allowlisted account authenticates and yields the lowercased email + sub.
func TestOIDCValidTokenAccepted(t *testing.T) {
	f := newFakeIssuer(t)
	a := newOIDCAuthenticator(t, f, nil)

	token := mint(t, f.key, f.validClaims())
	ident, err := a.AuthenticateClient(context.Background(), requestWithBearer(token))
	if err != nil {
		t.Fatalf("AuthenticateClient: %v", err)
	}
	if ident.Email != allowedEmail {
		t.Errorf("email = %q, want %q (lowercased)", ident.Email, allowedEmail)
	}
	if ident.Sub != testSub {
		t.Errorf("sub = %q, want %q", ident.Sub, testSub)
	}
}

// TestOIDCRejections: every deviation from a valid token fails closed.
func TestOIDCRejections(t *testing.T) {
	f := newFakeIssuer(t)
	a := newOIDCAuthenticator(t, f, nil)

	cases := []struct {
		name   string
		mutate func(claims map[string]any)
	}{
		{"wrong audience", func(c map[string]any) { c["aud"] = "someone-elses-client-id" }},
		{"wrong issuer", func(c map[string]any) { c["iss"] = "https://attacker.example.com" }},
		{"expired", func(c map[string]any) {
			c["iat"] = time.Now().Add(-2 * time.Hour).Unix()
			c["exp"] = time.Now().Add(-time.Hour).Unix()
		}},
		{"email not on allowlist", func(c map[string]any) { c["email"] = "stranger@example.com" }},
		{"email not verified", func(c map[string]any) { c["email_verified"] = false }},
		{"email missing", func(c map[string]any) { delete(c, "email") }},
		{"sub missing", func(c map[string]any) { delete(c, "sub") }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			claims := f.validClaims()
			tc.mutate(claims)
			token := mint(t, f.key, claims)
			if _, err := a.AuthenticateClient(context.Background(), requestWithBearer(token)); err == nil {
				t.Fatalf("token with %s was accepted; want rejection", tc.name)
			}
		})
	}

	t.Run("garbage token", func(t *testing.T) {
		if _, err := a.AuthenticateClient(context.Background(), requestWithBearer("not-a-jwt")); err == nil {
			t.Fatal("garbage token accepted")
		}
	})
	t.Run("no token", func(t *testing.T) {
		if _, err := a.AuthenticateClient(context.Background(), requestWithBearer("")); err == nil {
			t.Fatal("missing token accepted")
		}
	})
}

// TestOIDCForgedSignatureRejected: valid claims signed by a key that is NOT in
// the issuer's JWKS must be rejected.
func TestOIDCForgedSignatureRejected(t *testing.T) {
	f := newFakeIssuer(t)
	a := newOIDCAuthenticator(t, f, nil)

	attackerKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate attacker key: %v", err)
	}
	token := mint(t, attackerKey, f.validClaims())
	if _, err := a.AuthenticateClient(context.Background(), requestWithBearer(token)); err == nil {
		t.Fatal("forged-signature token accepted")
	}
}

// TestDevAuthCoexistsWithOIDC: with DEV_AUTH=true and OIDC configured, the
// static dev token still authenticates (mapping to DEV_EMAIL / sub "dev"),
// real OIDC tokens also work, and a wrong static token is still rejected.
func TestDevAuthCoexistsWithOIDC(t *testing.T) {
	f := newFakeIssuer(t)
	a := newOIDCAuthenticator(t, f, func(cfg *Config) {
		cfg.DevAuth = true
		cfg.DevClientToken = "dev-secret-token"
		cfg.DevEmail = "Dev@Example.com"
	})

	ident, err := a.AuthenticateClient(context.Background(), requestWithBearer("dev-secret-token"))
	if err != nil {
		t.Fatalf("dev token rejected with DEV_AUTH=true: %v", err)
	}
	if ident.Email != "dev@example.com" || ident.Sub != "dev" {
		t.Errorf("dev identity = %+v, want dev@example.com / dev", ident)
	}

	// Real OIDC token works alongside dev auth.
	real := mint(t, f.key, f.validClaims())
	if ident, err := a.AuthenticateClient(context.Background(), requestWithBearer(real)); err != nil || ident.Email != allowedEmail {
		t.Errorf("real token alongside dev auth: ident=%+v err=%v", ident, err)
	}

	// A wrong static token falls through to OIDC and fails there.
	if _, err := a.AuthenticateClient(context.Background(), requestWithBearer("wrong-dev-token")); err == nil {
		t.Fatal("wrong static token accepted")
	}
}

// TestDevTokenRejectedWhenDevAuthOff: the production posture. The same static
// token that dev mode accepts must be rejected once DEV_AUTH is off.
func TestDevTokenRejectedWhenDevAuthOff(t *testing.T) {
	f := newFakeIssuer(t)
	a := newOIDCAuthenticator(t, f, func(cfg *Config) {
		cfg.DevAuth = false
		cfg.DevClientToken = "dev-secret-token" // still set; must be ignored
		cfg.DevEmail = "dev@example.com"
	})

	if _, err := a.AuthenticateClient(context.Background(), requestWithBearer("dev-secret-token")); err == nil {
		t.Fatal("dev token accepted with DEV_AUTH=false")
	}
}

// TestOIDCDisabledWithoutClientID: with no GOOGLE_CLIENT_ID and no dev auth,
// every client token is rejected (fail closed, no verifier).
func TestOIDCDisabledWithoutClientID(t *testing.T) {
	cfg := &Config{AllowedEmails: []string{allowedEmail}}
	a, err := NewAuthenticator(context.Background(), cfg, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatalf("NewAuthenticator: %v", err)
	}
	if _, err := a.AuthenticateClient(context.Background(), requestWithBearer("anything")); err == nil {
		t.Fatal("token accepted with OIDC unconfigured and DEV_AUTH off")
	}
}

// TestOIDCEndToEndHTTP wires the FULL relay (handlers + store + directory) in
// production posture — OIDC on, DEV_AUTH off — and exercises the real HTTP
// endpoints: a minted ID token can enroll and list devices; a bad bearer gets
// 401.
func TestOIDCEndToEndHTTP(t *testing.T) {
	f := newFakeIssuer(t)

	cfg := &Config{
		ListenAddr:     "127.0.0.1:0",
		StateDir:       t.TempDir(),
		GoogleClientID: testClientID,
		IssuerURL:      f.srv.URL,
		AllowedEmails:  []string{allowedEmail},
	}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	initCtx, cancelInit := context.WithTimeout(context.Background(), 10*time.Second)
	auth, err := NewAuthenticator(initCtx, cfg, logger)
	cancelInit()
	if err != nil {
		t.Fatalf("NewAuthenticator: %v", err)
	}
	store, err := LoadStore(cfg.DevicesPath(), logger)
	if err != nil {
		t.Fatalf("LoadStore: %v", err)
	}
	h := NewHandler(cfg, auth, store, NewDirectory(logger), logger)
	mux := http.NewServeMux()
	h.Register(mux)
	ts := httptest.NewServer(mux)
	t.Cleanup(ts.Close)

	token := mint(t, f.key, f.validClaims())

	// Enroll with the real ID token.
	deviceID, deviceToken := enrollDevice(t, ts, token, "oidcbox")
	if deviceID == "" || deviceToken == "" {
		t.Fatal("enroll with OIDC token failed")
	}

	// List devices with the real ID token; the enrolled device is visible.
	req, _ := http.NewRequest(http.MethodGet, ts.URL+"/v1/client/devices", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("list status = %d, want 200", resp.StatusCode)
	}
	var out struct {
		Devices []struct {
			ID string `json:"id"`
		} `json:"devices"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode list: %v", err)
	}
	if len(out.Devices) != 1 || out.Devices[0].ID != deviceID {
		t.Fatalf("list = %+v, want the enrolled device %s", out.Devices, deviceID)
	}

	// The dev token has no power in production posture.
	req2, _ := http.NewRequest(http.MethodGet, ts.URL+"/v1/client/devices", nil)
	req2.Header.Set("Authorization", "Bearer dev-secret-token")
	resp2, err := http.DefaultClient.Do(req2)
	if err != nil {
		t.Fatalf("list with dev token: %v", err)
	}
	resp2.Body.Close()
	if resp2.StatusCode != http.StatusUnauthorized {
		t.Fatalf("dev-token status = %d, want 401", resp2.StatusCode)
	}
}
