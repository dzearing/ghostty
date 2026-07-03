package main

// Tests for the OAuth device-code self-enroll endpoints (WP-B3, relay side).
// They extend the WP-B1 fake-issuer infrastructure: the fake issuer's
// discovery document advertises device-code endpoints, and fakeGoogleDeviceFlow
// implements them statefully (pending -> approved/denied/expired per grant),
// minting real RS256 ID tokens with the issuer's key. No Google involved.

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// fakeGrant is the state of one fake device-code grant.
type fakeGrant struct {
	userCode string
	status   string // "pending", "approved", "denied", "expired"
	idToken  string // returned when status == "approved"
}

// fakeGoogleDeviceFlow implements Google's device-code + token endpoints on
// top of a fakeIssuer. Each /device/code call mints a fresh grant; tests
// steer its outcome by user_code (which is all a real user ever sees too).
type fakeGoogleDeviceFlow struct {
	mu     sync.Mutex
	seq    int
	grants map[string]*fakeGrant // device_code -> grant

	expiresIn int // seconds, reported to the relay
	interval  int // seconds, reported to the relay

	// wantClientID is the client_id /device/code must be called with (like
	// real Google, an unknown client is refused). Defaults to testClientID;
	// dual-client tests point it at testDeviceClientID.
	wantClientID string

	// Last form each endpoint received, for asserting which OAuth client
	// (id/secret) the relay presented upstream.
	lastDeviceCodeForm url.Values
	lastTokenForm      url.Values
}

func newFakeGoogleDeviceFlow(f *fakeIssuer) *fakeGoogleDeviceFlow {
	g := &fakeGoogleDeviceFlow{
		grants:       make(map[string]*fakeGrant),
		expiresIn:    600,
		interval:     1, // keep tests fast; Google's real minimum is 5
		wantClientID: testClientID,
	}
	f.deviceCodeHandler = g.handleDeviceCode
	f.tokenHandler = g.handleToken
	return g
}

func (g *fakeGoogleDeviceFlow) handleDeviceCode(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	g.mu.Lock()
	g.lastDeviceCodeForm = r.PostForm
	wantClientID := g.wantClientID
	g.mu.Unlock()
	if r.PostFormValue("client_id") != wantClientID {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(map[string]any{"error": "invalid_client"})
		return
	}

	g.mu.Lock()
	g.seq++
	deviceCode := fmt.Sprintf("fake-google-device-code-%d", g.seq)
	userCode := fmt.Sprintf("WXYZ-%04d", g.seq)
	g.grants[deviceCode] = &fakeGrant{userCode: userCode, status: "pending"}
	g.mu.Unlock()

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"device_code":      deviceCode,
		"user_code":        userCode,
		"verification_url": "https://www.google.com/device",
		"expires_in":       g.expiresIn,
		"interval":         g.interval,
	})
}

func (g *fakeGoogleDeviceFlow) handleToken(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	g.mu.Lock()
	g.lastTokenForm = r.PostForm
	g.mu.Unlock()
	writeErr := func(status int, code string) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(map[string]any{"error": code})
	}

	if r.PostFormValue("grant_type") != grantTypeDeviceCode {
		writeErr(http.StatusBadRequest, "unsupported_grant_type")
		return
	}

	g.mu.Lock()
	grant := g.grants[r.PostFormValue("device_code")]
	g.mu.Unlock()
	if grant == nil {
		writeErr(http.StatusBadRequest, "invalid_grant")
		return
	}

	switch grant.status {
	case "pending":
		writeErr(http.StatusPreconditionRequired, "authorization_pending")
	case "denied":
		writeErr(http.StatusForbidden, "access_denied")
	case "expired":
		writeErr(http.StatusBadRequest, "expired_token")
	case "approved":
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"access_token": "fake-access-token",
			"id_token":     grant.idToken,
			"expires_in":   3599,
			"token_type":   "Bearer",
		})
	default:
		writeErr(http.StatusBadRequest, "invalid_grant")
	}
}

// setOutcome flips the grant identified by userCode into the given terminal
// status (with idToken for "approved") — the fake equivalent of the owner
// acting on Google's consent page.
func (g *fakeGoogleDeviceFlow) setOutcome(t *testing.T, userCode, status, idToken string) {
	t.Helper()
	g.mu.Lock()
	defer g.mu.Unlock()
	for _, grant := range g.grants {
		if grant.userCode == userCode {
			grant.status = status
			grant.idToken = idToken
			return
		}
	}
	t.Fatalf("no fake grant with user_code %q", userCode)
}

// newEnrollTestServer wires the full relay in production posture (OIDC on,
// DEV_AUTH off) against the fake issuer, with a fixed public base URL.
// Optional mutate funcs adjust the Config before wiring (e.g. dual-client).
func newEnrollTestServer(t *testing.T, f *fakeIssuer, mutate ...func(*Config)) (*httptest.Server, *Store) {
	t.Helper()

	cfg := &Config{
		ListenAddr:         "127.0.0.1:0",
		StateDir:           t.TempDir(),
		GoogleClientID:     testClientID,
		GoogleClientSecret: "test-client-secret",
		IssuerURL:          f.srv.URL,
		AllowedEmails:      []string{allowedEmail},
		RelayBaseURL:       "https://relay.test",
	}
	for _, m := range mutate {
		m(cfg)
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

	return ts, store
}

// enrollStart POSTs /v1/enroll/start and decodes the response.
func enrollStart(t *testing.T, ts *httptest.Server, name string) enrollStartResponse {
	t.Helper()

	resp, err := http.Post(ts.URL+"/v1/enroll/start", "application/json",
		strings.NewReader(`{"name":"`+name+`"}`))
	if err != nil {
		t.Fatalf("enroll start: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("enroll start status = %d (%s), want 200", resp.StatusCode, body)
	}
	var out enrollStartResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode enroll start: %v", err)
	}
	return out
}

// enrollPoll POSTs /v1/enroll/poll and returns (status, decoded body).
func enrollPoll(t *testing.T, ts *httptest.Server, handle string) (int, map[string]any) {
	t.Helper()

	resp, err := http.Post(ts.URL+"/v1/enroll/poll", "application/json",
		strings.NewReader(`{"device_code_handle":"`+handle+`"}`))
	if err != nil {
		t.Fatalf("enroll poll: %v", err)
	}
	defer resp.Body.Close()
	var body map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode enroll poll (status %d): %v", resp.StatusCode, err)
	}
	return resp.StatusCode, body
}

// enrollToCompletion runs a full enroll flow: start, approve as the
// allowlisted owner, poll once (the first poll is never rate-limited), and
// return the issued (deviceID, deviceToken).
func enrollToCompletion(t *testing.T, ts *httptest.Server, f *fakeIssuer, g *fakeGoogleDeviceFlow, name string) (string, string) {
	t.Helper()

	start := enrollStart(t, ts, name)
	g.setOutcome(t, start.UserCode, "approved", mint(t, f.key, f.validClaims()))

	status, body := enrollPoll(t, ts, start.DeviceCodeHandle)
	if status != http.StatusOK || body["status"] != "complete" {
		t.Fatalf("poll after approval = %d %v, want 200 complete", status, body)
	}
	id, _ := body["device_id"].(string)
	tok, _ := body["device_token"].(string)
	if id == "" || tok == "" {
		t.Fatalf("complete response missing device_id/device_token: %v", body)
	}
	return id, tok
}

// dialControl attempts the agent control WS upgrade with a device token and
// returns (conn, http status). conn is nil on failure.
func dialControl(t *testing.T, ts *httptest.Server, deviceToken string) (*websocket.Conn, int) {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	c, resp, err := websocket.Dial(ctx, wsURL(ts.URL, "/v1/agent/control"), &websocket.DialOptions{
		HTTPHeader: bearerHeader(deviceToken),
	})
	status := 0
	if resp != nil {
		status = resp.StatusCode
	}
	if err != nil {
		return nil, status
	}
	return c, status
}

// TestEnrollHappyPath: start -> pending -> owner approves -> poll returns the
// device credential once; the device exists, is owned by the verified
// identity, and its token authenticates the agent control WS.
func TestEnrollHappyPath(t *testing.T) {
	f := newFakeIssuer(t)
	g := newFakeGoogleDeviceFlow(f)
	ts, store := newEnrollTestServer(t, f)

	start := enrollStart(t, ts, "fresh-box")
	if start.VerificationURL != "https://www.google.com/device" {
		t.Errorf("verification_url = %q", start.VerificationURL)
	}
	if start.UserCode == "" || start.DeviceCodeHandle == "" {
		t.Fatalf("start response missing user_code/handle: %+v", start)
	}
	// The handle must be the relay's own opaque token, not Google's
	// device_code (which must never leave the relay).
	if strings.Contains(start.DeviceCodeHandle, "fake-google-device-code") {
		t.Fatalf("device_code_handle leaks Google's device_code: %q", start.DeviceCodeHandle)
	}
	if start.Interval != g.interval || start.ExpiresIn != g.expiresIn {
		t.Errorf("interval/expires_in = %d/%d, want %d/%d",
			start.Interval, start.ExpiresIn, g.interval, g.expiresIn)
	}

	// Owner has not approved yet: pending.
	status, body := enrollPoll(t, ts, start.DeviceCodeHandle)
	if status != http.StatusOK || body["status"] != "pending" {
		t.Fatalf("pre-approval poll = %d %v, want 200 pending", status, body)
	}

	// Owner signs in on Google (fake): grant approved for the allowlisted
	// identity.
	g.setOutcome(t, start.UserCode, "approved", mint(t, f.key, f.validClaims()))

	// Respect the poll interval, then collect the credential.
	time.Sleep(time.Duration(start.Interval)*time.Second + 100*time.Millisecond)
	status, body = enrollPoll(t, ts, start.DeviceCodeHandle)
	if status != http.StatusOK || body["status"] != "complete" {
		t.Fatalf("post-approval poll = %d %v, want 200 complete", status, body)
	}
	deviceID, _ := body["device_id"].(string)
	deviceToken, _ := body["device_token"].(string)
	if deviceID == "" || deviceToken == "" {
		t.Fatalf("complete response missing device_id/device_token: %v", body)
	}
	if body["relay_base"] != "https://relay.test" {
		t.Errorf("relay_base = %v, want https://relay.test", body["relay_base"])
	}

	// The device exists and is owned by the VERIFIED identity (lowercased
	// email + Google sub), named as requested.
	dev := store.Get(deviceID)
	if dev == nil {
		t.Fatal("enrolled device not in store")
	}
	if dev.OwnerEmail != allowedEmail || dev.OwnerSub != testSub || dev.Name != "fresh-box" {
		t.Errorf("device = %+v, want owner %s sub %s name fresh-box", dev, allowedEmail, testSub)
	}

	// The issued token authenticates the agent control WS upgrade.
	c, _ := dialControl(t, ts, deviceToken)
	if c == nil {
		t.Fatal("enrolled device token rejected on /v1/agent/control")
	}
	c.CloseNow()

	// The credential was returned exactly once: the handle is gone.
	status, body = enrollPoll(t, ts, start.DeviceCodeHandle)
	if status != http.StatusNotFound {
		t.Fatalf("poll after completion = %d %v, want 404", status, body)
	}
}

// TestEnrollIdempotentReEnroll: re-running enrollment for the same owner +
// name yields the SAME device id with a ROTATED credential — the old token is
// revoked, the new one works. (One credential per device: the store keeps a
// single token hash, and re-enroll doubles as lost-token recovery, which only
// works if the fresh token wins.)
func TestEnrollIdempotentReEnroll(t *testing.T) {
	f := newFakeIssuer(t)
	g := newFakeGoogleDeviceFlow(f)
	ts, store := newEnrollTestServer(t, f)

	id1, tok1 := enrollToCompletion(t, ts, f, g, "same-box")
	id2, tok2 := enrollToCompletion(t, ts, f, g, "same-box")

	if id1 != id2 {
		t.Fatalf("re-enroll minted a new device: %s then %s", id1, id2)
	}
	if tok1 == tok2 {
		t.Fatal("re-enroll returned the same raw token")
	}
	if n := len(store.ListByOwner(allowedEmail)); n != 1 {
		t.Fatalf("owner has %d devices after re-enroll, want 1", n)
	}

	// Old credential revoked, new one live.
	if c, status := dialControl(t, ts, tok1); c != nil {
		c.CloseNow()
		t.Fatal("old token still authenticates after re-enroll")
	} else if status != http.StatusUnauthorized {
		t.Fatalf("old-token control dial status = %d, want 401", status)
	}
	c, _ := dialControl(t, ts, tok2)
	if c == nil {
		t.Fatal("new token rejected after re-enroll")
	}
	c.CloseNow()

	// A different name for the same owner is a distinct device.
	id3, _ := enrollToCompletion(t, ts, f, g, "other-box")
	if id3 == id1 {
		t.Fatal("different name reused the same device id")
	}
	if n := len(store.ListByOwner(allowedEmail)); n != 2 {
		t.Fatalf("owner has %d devices, want 2", n)
	}
}

// TestEnrollDeniedTerminal: the owner clicking "deny" on Google is terminal —
// 403 denied, and the handle is forgotten.
func TestEnrollDeniedTerminal(t *testing.T) {
	f := newFakeIssuer(t)
	g := newFakeGoogleDeviceFlow(f)
	ts, store := newEnrollTestServer(t, f)

	start := enrollStart(t, ts, "denied-box")
	g.setOutcome(t, start.UserCode, "denied", "")

	status, body := enrollPoll(t, ts, start.DeviceCodeHandle)
	if status != http.StatusForbidden || body["status"] != "denied" {
		t.Fatalf("denied poll = %d %v, want 403 denied", status, body)
	}
	if status, _ := enrollPoll(t, ts, start.DeviceCodeHandle); status != http.StatusNotFound {
		t.Fatalf("poll after denial = %d, want 404 (terminal)", status)
	}
	if n := len(store.ListByOwner(allowedEmail)); n != 0 {
		t.Fatalf("denied enrollment created %d devices", n)
	}
}

// TestEnrollExpiredTerminal: Google reporting the code expired is terminal —
// 410 expired, handle forgotten.
func TestEnrollExpiredTerminal(t *testing.T) {
	f := newFakeIssuer(t)
	g := newFakeGoogleDeviceFlow(f)
	ts, _ := newEnrollTestServer(t, f)

	start := enrollStart(t, ts, "slow-box")
	g.setOutcome(t, start.UserCode, "expired", "")

	status, body := enrollPoll(t, ts, start.DeviceCodeHandle)
	if status != http.StatusGone || body["status"] != "expired" {
		t.Fatalf("expired poll = %d %v, want 410 expired", status, body)
	}
	if status, _ := enrollPoll(t, ts, start.DeviceCodeHandle); status != http.StatusNotFound {
		t.Fatalf("poll after expiry = %d, want 404 (terminal)", status)
	}
}

// TestEnrollNonAllowlistedRejected: a REAL, verified Google sign-in by an
// identity not on ALLOWED_EMAILS is terminally rejected and enrolls nothing —
// the allowlist gates enrollment exactly like client auth.
func TestEnrollNonAllowlistedRejected(t *testing.T) {
	f := newFakeIssuer(t)
	g := newFakeGoogleDeviceFlow(f)
	ts, store := newEnrollTestServer(t, f)

	start := enrollStart(t, ts, "intruder-box")
	claims := f.validClaims()
	claims["email"] = "stranger@example.com"
	g.setOutcome(t, start.UserCode, "approved", mint(t, f.key, claims))

	status, body := enrollPoll(t, ts, start.DeviceCodeHandle)
	if status != http.StatusForbidden || body["status"] != "rejected" {
		t.Fatalf("non-allowlisted poll = %d %v, want 403 rejected", status, body)
	}
	if _, ok := body["device_token"]; ok {
		t.Fatal("rejected enrollment leaked a device token")
	}
	if status, _ := enrollPoll(t, ts, start.DeviceCodeHandle); status != http.StatusNotFound {
		t.Fatalf("poll after rejection = %d, want 404 (terminal)", status)
	}
	if n := len(store.ListByOwner("stranger@example.com")) + len(store.ListByOwner(allowedEmail)); n != 0 {
		t.Fatalf("rejected enrollment created %d devices", n)
	}
}

// TestEnrollUsesDeviceClientWhenConfigured: with GOOGLE_DEVICE_CLIENT_ID/_SECRET
// set, the relay presents THAT client (id + secret) to Google's device-code and
// token endpoints — Google only allows the device-code grant for TV/limited-
// input clients — and the resulting ID token (aud = device client) passes the
// enroll-poll verification.
func TestEnrollUsesDeviceClientWhenConfigured(t *testing.T) {
	f := newFakeIssuer(t)
	g := newFakeGoogleDeviceFlow(f)
	g.wantClientID = testDeviceClientID // fake Google refuses any other client
	ts, store := newEnrollTestServer(t, f, func(cfg *Config) {
		cfg.GoogleDeviceClientID = testDeviceClientID
		cfg.GoogleDeviceClientSecret = testDeviceClientSecret
	})

	start := enrollStart(t, ts, "tv-client-box")

	g.mu.Lock()
	dcForm := g.lastDeviceCodeForm
	g.mu.Unlock()
	if got := dcForm.Get("client_id"); got != testDeviceClientID {
		t.Errorf("device-code client_id = %q, want %q", got, testDeviceClientID)
	}

	// Real-world shape: the ID token minted via the device client carries the
	// DEVICE client's ID as aud.
	claims := f.validClaims()
	claims["aud"] = testDeviceClientID
	g.setOutcome(t, start.UserCode, "approved", mint(t, f.key, claims))

	status, body := enrollPoll(t, ts, start.DeviceCodeHandle)
	if status != http.StatusOK || body["status"] != "complete" {
		t.Fatalf("poll = %d %v, want 200 complete (device-client aud must verify)", status, body)
	}

	g.mu.Lock()
	tokForm := g.lastTokenForm
	g.mu.Unlock()
	if got := tokForm.Get("client_id"); got != testDeviceClientID {
		t.Errorf("token client_id = %q, want %q", got, testDeviceClientID)
	}
	if got := tokForm.Get("client_secret"); got != testDeviceClientSecret {
		t.Errorf("token client_secret = %q, want %q", got, testDeviceClientSecret)
	}

	if id, _ := body["device_id"].(string); id == "" || store.Get(id) == nil {
		t.Fatalf("enrolled device missing from store: %v", body)
	}
}

// TestEnrollFallsBackToPrimaryClient: without GOOGLE_DEVICE_CLIENT_ID, the
// enroll flow keeps today's behavior — GOOGLE_CLIENT_ID/GOOGLE_CLIENT_SECRET
// go upstream.
func TestEnrollFallsBackToPrimaryClient(t *testing.T) {
	f := newFakeIssuer(t)
	g := newFakeGoogleDeviceFlow(f)
	ts, _ := newEnrollTestServer(t, f)

	enrollToCompletion(t, ts, f, g, "fallback-box")

	g.mu.Lock()
	dcForm, tokForm := g.lastDeviceCodeForm, g.lastTokenForm
	g.mu.Unlock()
	if got := dcForm.Get("client_id"); got != testClientID {
		t.Errorf("device-code client_id = %q, want %q", got, testClientID)
	}
	if got := tokForm.Get("client_id"); got != testClientID {
		t.Errorf("token client_id = %q, want %q", got, testClientID)
	}
	if got := tokForm.Get("client_secret"); got != "test-client-secret" {
		t.Errorf("token client_secret = %q, want %q", got, "test-client-secret")
	}
}

// TestEnrollUnknownAudRejected: even with both clients configured, an ID token
// addressed to some OTHER client id is terminally rejected at the enroll poll.
func TestEnrollUnknownAudRejected(t *testing.T) {
	f := newFakeIssuer(t)
	g := newFakeGoogleDeviceFlow(f)
	g.wantClientID = testDeviceClientID
	ts, store := newEnrollTestServer(t, f, func(cfg *Config) {
		cfg.GoogleDeviceClientID = testDeviceClientID
		cfg.GoogleDeviceClientSecret = testDeviceClientSecret
	})

	start := enrollStart(t, ts, "wrong-aud-box")
	claims := f.validClaims()
	claims["aud"] = "someone-elses-client-id"
	g.setOutcome(t, start.UserCode, "approved", mint(t, f.key, claims))

	status, body := enrollPoll(t, ts, start.DeviceCodeHandle)
	if status != http.StatusForbidden || body["status"] != "rejected" {
		t.Fatalf("unknown-aud poll = %d %v, want 403 rejected", status, body)
	}
	if n := len(store.ListByOwner(allowedEmail)); n != 0 {
		t.Fatalf("unknown-aud enrollment created %d devices", n)
	}
}

// TestEnrollPollRateLimited: polls faster than the advertised interval are
// answered 429 slow_down from relay memory (Google sees at most one poll per
// interval).
func TestEnrollPollRateLimited(t *testing.T) {
	f := newFakeIssuer(t)
	g := newFakeGoogleDeviceFlow(f)
	ts, _ := newEnrollTestServer(t, f)

	start := enrollStart(t, ts, "eager-box")

	// First poll is allowed immediately.
	if status, body := enrollPoll(t, ts, start.DeviceCodeHandle); status != http.StatusOK || body["status"] != "pending" {
		t.Fatalf("first poll = %d %v, want 200 pending", status, body)
	}
	// Second poll inside the interval is rate-limited without reaching the
	// fake Google.
	g.mu.Lock()
	seqBefore := g.seq
	g.mu.Unlock()
	status, body := enrollPoll(t, ts, start.DeviceCodeHandle)
	if status != http.StatusTooManyRequests || body["status"] != "slow_down" {
		t.Fatalf("rapid second poll = %d %v, want 429 slow_down", status, body)
	}
	g.mu.Lock()
	seqAfter := g.seq
	g.mu.Unlock()
	if seqBefore != seqAfter {
		t.Fatal("rate-limited poll reached the upstream device-code endpoint")
	}

	// After the interval elapses, polling works again.
	time.Sleep(time.Duration(start.Interval)*time.Second + 100*time.Millisecond)
	if status, body := enrollPoll(t, ts, start.DeviceCodeHandle); status != http.StatusOK || body["status"] != "pending" {
		t.Fatalf("post-interval poll = %d %v, want 200 pending", status, body)
	}
}

// TestEnrollBadRequests: malformed inputs and unknown handles.
func TestEnrollBadRequests(t *testing.T) {
	f := newFakeIssuer(t)
	newFakeGoogleDeviceFlow(f)
	ts, _ := newEnrollTestServer(t, f)

	// Missing/empty name.
	for _, body := range []string{``, `{}`, `{"name":""}`, `{"name":"   "}`} {
		resp, err := http.Post(ts.URL+"/v1/enroll/start", "application/json", strings.NewReader(body))
		if err != nil {
			t.Fatalf("start: %v", err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusBadRequest {
			t.Errorf("start with body %q status = %d, want 400", body, resp.StatusCode)
		}
	}

	// Missing handle.
	resp, err := http.Post(ts.URL+"/v1/enroll/poll", "application/json", strings.NewReader(`{}`))
	if err != nil {
		t.Fatalf("poll: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("poll without handle status = %d, want 400", resp.StatusCode)
	}

	// Unknown handle.
	if status, _ := enrollPoll(t, ts, "no-such-handle"); status != http.StatusNotFound {
		t.Errorf("unknown handle poll status = %d, want 404", status)
	}
}

// TestEnrollUnavailableWithoutOIDC: with no OIDC configured (dev-auth-only
// relay), enrollment reports itself unavailable rather than half-working.
func TestEnrollUnavailableWithoutOIDC(t *testing.T) {
	ts, _, _ := newTestServer(t) // DEV_AUTH posture, no GOOGLE_CLIENT_ID

	resp, err := http.Post(ts.URL+"/v1/enroll/start", "application/json",
		strings.NewReader(`{"name":"box"}`))
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("start without OIDC status = %d, want 503", resp.StatusCode)
	}
}
