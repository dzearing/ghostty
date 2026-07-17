package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// withSessionKey installs a 32-byte session encryption key on the test Config
// so the brokered-OAuth flow is enabled.
func withSessionKey(t *testing.T) func(*Config) {
	return func(c *Config) { c.SessionEncKey = testKey(t) }
}

// okTokenHandler serves a fake Google token endpoint that returns a valid
// id_token for both the authorization_code and refresh_token grants; the code
// grant additionally returns a refresh token.
func okTokenHandler(t *testing.T, f *fakeIssuer) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		resp := map[string]any{
			"id_token":     mint(t, f.key, f.validClaims()),
			"access_token": "ya29.access",
			"expires_in":   3599,
		}
		if r.Form.Get("grant_type") == "authorization_code" {
			resp["refresh_token"] = "1//refresh-abc"
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	}
}

// newBrokerServer wires the full relay (OIDC on, DEV_AUTH off) against the fake
// issuer with the brokered-OAuth flow enabled. allowed overrides ALLOWED_EMAILS
// when non-nil.
func newBrokerServer(t *testing.T, f *fakeIssuer, allowed []string) (*httptest.Server, *Handler) {
	ts, _, h := newEnrollTestServer(t, f, func(c *Config) {
		c.SessionEncKey = testKey(t)
		if allowed != nil {
			c.AllowedEmails = allowed
		}
	})
	return ts, h
}

// setGoogleTokenClaims points the fake issuer's token endpoint at a specific
// claim set, so a brokered /oauth/exchange mints a session for that identity.
func setGoogleTokenClaims(t *testing.T, f *fakeIssuer, claims map[string]any) {
	f.tokenHandler = func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		resp := map[string]any{"id_token": mint(t, f.key, claims), "expires_in": 3599}
		if r.Form.Get("grant_type") == "authorization_code" {
			resp["refresh_token"] = "1//refresh"
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	}
}

// sessionToken mints a relay session token for the given Google claims via the
// full brokered /oauth/exchange flow. Returns "" when the sign-in was rejected
// (e.g. not allowlisted / blocked).
func sessionToken(t *testing.T, ts *httptest.Server, f *fakeIssuer, claims map[string]any) string {
	setGoogleTokenClaims(t, f, claims)
	_, out := doExchange(t, ts, map[string]string{
		"code": "c", "code_verifier": "v", "redirect_uri": "http://127.0.0.1:49152",
	})
	tok, _ := out["session_token"].(string)
	return tok
}

func doExchange(t *testing.T, ts *httptest.Server, body map[string]string) (*http.Response, map[string]any) {
	t.Helper()
	b, _ := json.Marshal(body)
	resp, err := http.Post(ts.URL+"/oauth/exchange", "application/json", bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	resp.Body.Close()
	return resp, out
}

// --- Task 3: low-level exchange helper --------------------------------------

func TestGoogleExchangeCodeCapturesRefresh(t *testing.T) {
	f := newFakeIssuer(t)
	f.tokenHandler = okTokenHandler(t, f)
	_, _, h := newEnrollTestServer(t, f, withSessionKey(t))

	tokens, oauthErr, err := h.googleExchangeCode(context.Background(), "the-code", "the-verifier", "http://127.0.0.1:49152")
	if err != nil || oauthErr != "" {
		t.Fatalf("exchange: oauthErr=%q err=%v", oauthErr, err)
	}
	if tokens.RefreshToken != "1//refresh-abc" || tokens.IDToken == "" {
		t.Fatalf("missing tokens: %+v", tokens)
	}
}

// --- Task 4: /oauth/exchange ------------------------------------------------

func TestOAuthExchangeMintsSession(t *testing.T) {
	f := newFakeIssuer(t)
	f.tokenHandler = okTokenHandler(t, f)
	ts, _ := newBrokerServer(t, f, []string{allowedEmail})

	resp, out := doExchange(t, ts, map[string]string{
		"code": "c", "code_verifier": "v", "redirect_uri": "http://127.0.0.1:49152",
	})
	if resp.StatusCode != 200 {
		t.Fatalf("status=%d body=%v", resp.StatusCode, out)
	}
	if tok, _ := out["session_token"].(string); tok == "" {
		t.Fatalf("no session_token: %v", out)
	}
	if out["email"] != allowedEmail {
		t.Fatalf("email=%v want %v", out["email"], allowedEmail)
	}
}

func TestOAuthExchangeAllowlistRejected(t *testing.T) {
	f := newFakeIssuer(t)
	f.tokenHandler = okTokenHandler(t, f)
	ts, _ := newBrokerServer(t, f, []string{"someone-else@example.com"})

	resp, _ := doExchange(t, ts, map[string]string{
		"code": "c", "code_verifier": "v", "redirect_uri": "http://127.0.0.1:49152",
	})
	if resp.StatusCode != http.StatusForbidden && resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401/403 for non-allowlisted, got %d", resp.StatusCode)
	}
}

func TestOAuthExchangeRejectsNonLoopbackRedirect(t *testing.T) {
	f := newFakeIssuer(t)
	f.tokenHandler = okTokenHandler(t, f)
	ts, _ := newBrokerServer(t, f, []string{allowedEmail})

	resp, _ := doExchange(t, ts, map[string]string{
		"code": "c", "code_verifier": "v", "redirect_uri": "https://evil.example.com/cb",
	})
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400 for non-loopback redirect, got %d", resp.StatusCode)
	}
}

// --- Task 5: /oauth/renew ---------------------------------------------------

func TestOAuthRenewRotatesToken(t *testing.T) {
	f := newFakeIssuer(t)
	f.tokenHandler = okTokenHandler(t, f)
	ts, _ := newBrokerServer(t, f, []string{allowedEmail})

	_, ex := doExchange(t, ts, map[string]string{
		"code": "c", "code_verifier": "v", "redirect_uri": "http://127.0.0.1:49152",
	})
	old := ex["session_token"].(string)

	req, _ := http.NewRequest("POST", ts.URL+"/oauth/renew", nil)
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

// --- Task 6: /oauth/signout -------------------------------------------------

func TestOAuthSignoutRevokes(t *testing.T) {
	f := newFakeIssuer(t)
	f.tokenHandler = okTokenHandler(t, f)
	ts, _ := newBrokerServer(t, f, []string{allowedEmail})

	_, ex := doExchange(t, ts, map[string]string{
		"code": "c", "code_verifier": "v", "redirect_uri": "http://127.0.0.1:49152",
	})
	tok := ex["session_token"].(string)

	req, _ := http.NewRequest("POST", ts.URL+"/oauth/signout", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, _ := http.DefaultClient.Do(req)
	if resp.StatusCode != 204 && resp.StatusCode != 200 {
		t.Fatalf("signout status=%d", resp.StatusCode)
	}
	resp.Body.Close()

	lr, _ := http.NewRequest("GET", ts.URL+"/v1/client/devices", nil)
	lr.Header.Set("Authorization", "Bearer "+tok)
	lresp, err := http.DefaultClient.Do(lr)
	if err != nil {
		t.Fatal(err)
	}
	defer lresp.Body.Close()
	if lresp.StatusCode == 200 {
		t.Fatal("revoked session token still authenticates client calls")
	}
}

// --- Task 7: client auth via session tokens ---------------------------------

func TestClientCallAcceptsSessionToken(t *testing.T) {
	f := newFakeIssuer(t)
	f.tokenHandler = okTokenHandler(t, f)
	ts, _ := newBrokerServer(t, f, []string{allowedEmail})

	_, ex := doExchange(t, ts, map[string]string{
		"code": "c", "code_verifier": "v", "redirect_uri": "http://127.0.0.1:49152",
	})
	tok := ex["session_token"].(string)

	req, _ := http.NewRequest("GET", ts.URL+"/v1/client/devices", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("session token must authenticate client calls, got %d", resp.StatusCode)
	}
}

func TestClientCallRejectsRawGoogleIDToken(t *testing.T) {
	f := newFakeIssuer(t)
	ts, _ := newBrokerServer(t, f, []string{allowedEmail})

	idToken := mint(t, f.key, f.validClaims()) // a valid Google id token
	req, _ := http.NewRequest("GET", ts.URL+"/v1/client/devices", nil)
	req.Header.Set("Authorization", "Bearer "+idToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == 200 {
		t.Fatal("a raw Google id token must no longer authenticate client calls")
	}
}
