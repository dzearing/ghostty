package main

// Tests for the browser (web-callback) enroll flow. They extend the fake
// Google with the authorization-code half: the test plays the browser (GET
// /enroll/<nonce> → 302 → callback) and fakeGoogleWebFlow plays Google's
// token endpoint (code → id_token exchange with the Web client id+secret),
// minting real RS256 ID tokens with the fake issuer's key.

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	// The third OAuth client ("Web application") used by the browser enroll
	// flow when GOOGLE_WEB_CLIENT_ID/_SECRET are configured.
	testWebClientID     = "test-web-client-id.apps.googleusercontent.com"
	testWebClientSecret = "test-web-client-secret"
)

// fakeGoogleWebFlow implements Google's token endpoint for the
// authorization-code grant on top of a fakeIssuer. Tests mint codes bound to
// an ID token (the fake equivalent of the owner completing the consent page)
// and the relay's callback redeems them.
type fakeGoogleWebFlow struct {
	mu    sync.Mutex
	seq   int
	codes map[string]string // auth code -> id_token (single-use)

	lastTokenForm url.Values // for asserting which client the relay presented
}

func newFakeGoogleWebFlow(f *fakeIssuer) *fakeGoogleWebFlow {
	g := &fakeGoogleWebFlow{codes: make(map[string]string)}
	f.tokenHandler = g.handleToken
	return g
}

// newCode mints an authorization code that redeems for idToken.
func (g *fakeGoogleWebFlow) newCode(idToken string) string {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.seq++
	code := "fake-google-auth-code-" + strings.Repeat("x", g.seq) // distinct per mint
	g.codes[code] = idToken
	return code
}

func (g *fakeGoogleWebFlow) handleToken(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	g.mu.Lock()
	g.lastTokenForm = r.PostForm
	g.mu.Unlock()
	writeErr := func(status int, code string) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(map[string]any{"error": code})
	}

	if r.PostFormValue("grant_type") != "authorization_code" {
		writeErr(http.StatusBadRequest, "unsupported_grant_type")
		return
	}
	// Like real Google: the web client must present id + secret + the exact
	// redirect_uri the code was issued against.
	if r.PostFormValue("client_id") != testWebClientID ||
		r.PostFormValue("client_secret") != testWebClientSecret {
		writeErr(http.StatusUnauthorized, "invalid_client")
		return
	}
	if r.PostFormValue("redirect_uri") == "" {
		writeErr(http.StatusBadRequest, "invalid_request")
		return
	}

	g.mu.Lock()
	idToken, ok := g.codes[r.PostFormValue("code")]
	delete(g.codes, r.PostFormValue("code")) // codes are single-use
	g.mu.Unlock()
	if !ok {
		writeErr(http.StatusBadRequest, "invalid_grant")
		return
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"access_token": "fake-access-token",
		"id_token":     idToken,
		"expires_in":   3599,
		"token_type":   "Bearer",
	})
}

// withWebClient configures the Web OAuth client on a test relay Config.
func withWebClient(cfg *Config) {
	cfg.GoogleWebClientID = testWebClientID
	cfg.GoogleWebClientSecret = testWebClientSecret
}

// webEnrollStart POSTs /v1/enroll/start with flow "web" and decodes the body.
func webEnrollStart(t *testing.T, ts *httptest.Server, name string) webStartResponse {
	t.Helper()

	resp, err := http.Post(ts.URL+"/v1/enroll/start", "application/json",
		strings.NewReader(`{"name":"`+name+`","flow":"web"}`))
	if err != nil {
		t.Fatalf("web enroll start: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("web enroll start status = %d (%s), want 200", resp.StatusCode, body)
	}
	var out webStartResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode web enroll start: %v", err)
	}
	return out
}

// noRedirectClient never follows redirects, so the 302 Location is assertable.
var noRedirectClient = &http.Client{
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
}

// browsePath GETs a relay path as a browser would (no redirect following) and
// returns (status, Location header, body).
func browsePath(t *testing.T, ts *httptest.Server, path string) (int, string, string) {
	t.Helper()
	resp, err := noRedirectClient.Get(ts.URL + path)
	if err != nil {
		t.Fatalf("GET %s: %v", path, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, resp.Header.Get("Location"), string(body)
}

// enrollPathOf extracts the relay-relative /enroll/<nonce> path from the
// advertised enroll_url (which is built on the configured public base).
func enrollPathOf(t *testing.T, enrollURL string) string {
	t.Helper()
	path, ok := strings.CutPrefix(enrollURL, "https://relay.test")
	if !ok || !strings.HasPrefix(path, "/enroll/") {
		t.Fatalf("enroll_url = %q, want https://relay.test/enroll/<nonce>", enrollURL)
	}
	return path
}

// authRedirect drives the browser entry leg: GET /enroll/<nonce>, assert the
// 302 to the fake Google auth endpoint, and return the bound state.
func authRedirect(t *testing.T, ts *httptest.Server, f *fakeIssuer, enrollURL string) string {
	t.Helper()

	status, loc, _ := browsePath(t, ts, enrollPathOf(t, enrollURL))
	if status != http.StatusFound {
		t.Fatalf("GET enroll link status = %d, want 302", status)
	}
	u, err := url.Parse(loc)
	if err != nil {
		t.Fatalf("parse redirect location %q: %v", loc, err)
	}
	if got := strings.TrimSuffix(loc, "?"+u.RawQuery); got != f.srv.URL+"/auth" {
		t.Errorf("redirect target = %q, want %s/auth", got, f.srv.URL)
	}
	q := u.Query()
	if got := q.Get("client_id"); got != testWebClientID {
		t.Errorf("auth client_id = %q, want %q", got, testWebClientID)
	}
	if got := q.Get("redirect_uri"); got != "https://relay.test/enroll/callback" {
		t.Errorf("auth redirect_uri = %q, want https://relay.test/enroll/callback", got)
	}
	if got := q.Get("response_type"); got != "code" {
		t.Errorf("auth response_type = %q, want code", got)
	}
	if got := q.Get("scope"); got != "openid email" {
		t.Errorf("auth scope = %q, want %q", got, "openid email")
	}
	if got := q.Get("prompt"); got != "select_account" {
		t.Errorf("auth prompt = %q, want select_account", got)
	}
	state := q.Get("state")
	if state == "" {
		t.Fatal("auth redirect carries no state")
	}
	return state
}

// callbackPath builds the relay callback path Google would redirect to.
func callbackPath(code, state string) string {
	q := url.Values{"code": {code}, "state": {state}}
	return "/enroll/callback?" + q.Encode()
}

// TestEnrollWebHappyPath: web start → browser opens the enroll link → 302 to
// Google with the Web client and a bound state → callback with a valid code
// approves the enrollment and renders the success page → the agent's poll
// returns the device credential once, and the token authenticates.
func TestEnrollWebHappyPath(t *testing.T) {
	f := newFakeIssuer(t)
	g := newFakeGoogleWebFlow(f)
	ts, store, _ := newEnrollTestServer(t, f, withWebClient)

	start := webEnrollStart(t, ts, "browser-box")
	if start.DeviceCodeHandle == "" {
		t.Fatalf("start response missing handle: %+v", start)
	}
	if start.Interval <= 0 || start.ExpiresIn <= 0 {
		t.Errorf("interval/expires_in = %d/%d, want > 0", start.Interval, start.ExpiresIn)
	}
	// The browser nonce and the poll handle must be distinct secrets: the
	// enroll URL is shown to humans (and shoulder-surfable); the handle is
	// what the credential comes back on.
	if strings.Contains(start.EnrollURL, start.DeviceCodeHandle) {
		t.Fatalf("enroll_url embeds the poll handle: %q", start.EnrollURL)
	}

	// Pending until the browser leg finishes.
	if status, body := enrollPoll(t, ts, start.DeviceCodeHandle); status != http.StatusOK || body["status"] != "pending" {
		t.Fatalf("pre-callback poll = %d %v, want 200 pending", status, body)
	}

	state := authRedirect(t, ts, f, start.EnrollURL)

	// The owner completes the Google sign-in: Google redirects back with a
	// code. Real-world shape: the ID token carries the WEB client's aud.
	claims := f.validClaims()
	claims["aud"] = testWebClientID
	code := g.newCode(mint(t, f.key, claims))

	status, _, page := browsePath(t, ts, callbackPath(code, state))
	if status != http.StatusOK {
		t.Fatalf("callback status = %d, want 200; page:\n%s", status, page)
	}
	if !strings.Contains(page, "browser-box") || !strings.Contains(page, "added to your account") {
		t.Errorf("success page missing machine name/confirmation:\n%s", page)
	}

	// The relay presented the WEB client (id + secret) at the token endpoint.
	g.mu.Lock()
	tokForm := g.lastTokenForm
	g.mu.Unlock()
	if got := tokForm.Get("client_id"); got != testWebClientID {
		t.Errorf("token client_id = %q, want %q", got, testWebClientID)
	}
	if got := tokForm.Get("redirect_uri"); got != "https://relay.test/enroll/callback" {
		t.Errorf("token redirect_uri = %q, want the registered callback", got)
	}

	// The agent's unchanged poll now yields the credential.
	pstatus, body := enrollPoll(t, ts, start.DeviceCodeHandle)
	if pstatus != http.StatusOK || body["status"] != "complete" {
		t.Fatalf("post-callback poll = %d %v, want 200 complete", pstatus, body)
	}
	deviceID, _ := body["device_id"].(string)
	deviceToken, _ := body["device_token"].(string)
	if deviceID == "" || deviceToken == "" {
		t.Fatalf("complete response missing device_id/device_token: %v", body)
	}
	if body["relay_base"] != "https://relay.test" {
		t.Errorf("relay_base = %v, want https://relay.test", body["relay_base"])
	}

	dev := store.Get(deviceID)
	if dev == nil {
		t.Fatal("web-enrolled device not in store")
	}
	if dev.OwnerEmail != allowedEmail || dev.OwnerSub != testSub || dev.Name != "browser-box" {
		t.Errorf("device = %+v, want owner %s sub %s name browser-box", dev, allowedEmail, testSub)
	}

	c, _ := dialControl(t, ts, deviceToken)
	if c == nil {
		t.Fatal("web-enrolled device token rejected on /v1/agent/control")
	}
	c.CloseNow()

	// Credential delivered exactly once.
	if status, _ := enrollPoll(t, ts, start.DeviceCodeHandle); status != http.StatusNotFound {
		t.Fatalf("poll after completion = %d, want 404", status)
	}
}

// TestEnrollWebStateMismatch: a callback with a state the relay never issued
// is rejected with an error page, binds to nothing, and does not consume the
// real enrollment — the genuine callback still completes afterwards.
func TestEnrollWebStateMismatch(t *testing.T) {
	f := newFakeIssuer(t)
	g := newFakeGoogleWebFlow(f)
	ts, store, _ := newEnrollTestServer(t, f, withWebClient)

	start := webEnrollStart(t, ts, "state-box")
	state := authRedirect(t, ts, f, start.EnrollURL)

	claims := f.validClaims()
	claims["aud"] = testWebClientID
	code := g.newCode(mint(t, f.key, claims))

	status, _, page := browsePath(t, ts, callbackPath(code, "forged-state"))
	if status != http.StatusBadRequest {
		t.Fatalf("forged-state callback status = %d, want 400; page:\n%s", status, page)
	}
	if n := len(store.ListByOwner(allowedEmail)); n != 0 {
		t.Fatalf("forged-state callback created %d devices", n)
	}

	// The real state is untouched; the flow still completes.
	if status, _, _ := browsePath(t, ts, callbackPath(code, state)); status != http.StatusOK {
		t.Fatalf("genuine callback after forged attempt = %d, want 200", status)
	}
	if pstatus, body := enrollPoll(t, ts, start.DeviceCodeHandle); pstatus != http.StatusOK || body["status"] != "complete" {
		t.Fatalf("poll = %d %v, want 200 complete", pstatus, body)
	}
}

// TestEnrollWebNonceSingleUse: the enroll link works once; a replay gets an
// error page, not a second Google redirect.
func TestEnrollWebNonceSingleUse(t *testing.T) {
	f := newFakeIssuer(t)
	newFakeGoogleWebFlow(f)
	ts, _, _ := newEnrollTestServer(t, f, withWebClient)

	start := webEnrollStart(t, ts, "replay-box")
	_ = authRedirect(t, ts, f, start.EnrollURL)

	status, loc, page := browsePath(t, ts, enrollPathOf(t, start.EnrollURL))
	if status != http.StatusNotFound || loc != "" {
		t.Fatalf("replayed enroll link = %d (loc %q), want 404 with no redirect", status, loc)
	}
	if !strings.Contains(page, "already been used or has expired") {
		t.Errorf("replay page lacks explanation:\n%s", page)
	}
}

// TestEnrollWebExpiredNonce: an expired web enrollment's link renders the
// error page and its handle stops polling.
func TestEnrollWebExpiredNonce(t *testing.T) {
	f := newFakeIssuer(t)
	newFakeGoogleWebFlow(f)
	ts, _, h := newEnrollTestServer(t, f, withWebClient)

	start := webEnrollStart(t, ts, "slow-browser-box")

	// Force the enrollment past its deadline.
	h.enroll.mu.Lock()
	h.enroll.pending[start.DeviceCodeHandle].expiresAt = time.Now().Add(-time.Minute)
	h.enroll.mu.Unlock()

	status, _, _ := browsePath(t, ts, enrollPathOf(t, start.EnrollURL))
	if status != http.StatusNotFound {
		t.Fatalf("expired enroll link status = %d, want 404", status)
	}
	if status, _ := enrollPoll(t, ts, start.DeviceCodeHandle); status != http.StatusNotFound {
		t.Fatalf("poll of expired web enrollment = %d, want 404", status)
	}
}

// TestEnrollWebNonAllowlistedRejected: a REAL, verified Google sign-in by an
// identity not on ALLOWED_EMAILS gets the terse rejection page, enrolls
// nothing, and the agent's poll reports the terminal rejection.
func TestEnrollWebNonAllowlistedRejected(t *testing.T) {
	f := newFakeIssuer(t)
	g := newFakeGoogleWebFlow(f)
	ts, store, _ := newEnrollTestServer(t, f, withWebClient)

	start := webEnrollStart(t, ts, "intruder-browser-box")
	state := authRedirect(t, ts, f, start.EnrollURL)

	claims := f.validClaims()
	claims["aud"] = testWebClientID
	claims["email"] = "stranger@example.com"
	code := g.newCode(mint(t, f.key, claims))

	status, _, page := browsePath(t, ts, callbackPath(code, state))
	if status != http.StatusForbidden {
		t.Fatalf("non-allowlisted callback status = %d, want 403", status)
	}
	if !strings.Contains(page, "not allowed") {
		t.Errorf("rejection page lacks explanation:\n%s", page)
	}
	if n := len(store.ListByOwner("stranger@example.com")) + len(store.ListByOwner(allowedEmail)); n != 0 {
		t.Fatalf("rejected web enrollment created %d devices", n)
	}

	pstatus, body := enrollPoll(t, ts, start.DeviceCodeHandle)
	if pstatus != http.StatusForbidden || body["status"] != "rejected" {
		t.Fatalf("poll after rejection = %d %v, want 403 rejected", pstatus, body)
	}
	if status, _ := enrollPoll(t, ts, start.DeviceCodeHandle); status != http.StatusNotFound {
		t.Fatalf("second poll after rejection = %d, want 404 (terminal)", status)
	}
}

// TestEnrollWebUserCancelled: the owner clicking "cancel" on Google's page
// (error=access_denied redirect) marks the enrollment denied for the agent.
func TestEnrollWebUserCancelled(t *testing.T) {
	f := newFakeIssuer(t)
	newFakeGoogleWebFlow(f)
	ts, store, _ := newEnrollTestServer(t, f, withWebClient)

	start := webEnrollStart(t, ts, "cancelled-box")
	state := authRedirect(t, ts, f, start.EnrollURL)

	q := url.Values{"error": {"access_denied"}, "state": {state}}
	status, _, page := browsePath(t, ts, "/enroll/callback?"+q.Encode())
	if status != http.StatusForbidden || !strings.Contains(page, "cancelled") {
		t.Fatalf("cancel callback = %d, want 403 cancelled page:\n%s", status, page)
	}

	pstatus, body := enrollPoll(t, ts, start.DeviceCodeHandle)
	if pstatus != http.StatusForbidden || body["status"] != "denied" {
		t.Fatalf("poll after cancel = %d %v, want 403 denied", pstatus, body)
	}
	if n := len(store.ListByOwner(allowedEmail)); n != 0 {
		t.Fatalf("cancelled enrollment created %d devices", n)
	}
}

// TestEnrollWebBadCodeTerminal: a code Google refuses (invalid_grant) is
// terminal — error page, and the poll reports the failure.
func TestEnrollWebBadCodeTerminal(t *testing.T) {
	f := newFakeIssuer(t)
	newFakeGoogleWebFlow(f)
	ts, store, _ := newEnrollTestServer(t, f, withWebClient)

	start := webEnrollStart(t, ts, "bad-code-box")
	state := authRedirect(t, ts, f, start.EnrollURL)

	status, _, _ := browsePath(t, ts, callbackPath("no-such-code", state))
	if status != http.StatusBadGateway {
		t.Fatalf("bad-code callback status = %d, want 502", status)
	}
	pstatus, body := enrollPoll(t, ts, start.DeviceCodeHandle)
	if pstatus != http.StatusBadRequest || body["status"] != "error" {
		t.Fatalf("poll after bad code = %d %v, want 400 error", pstatus, body)
	}
	if n := len(store.ListByOwner(allowedEmail)); n != 0 {
		t.Fatalf("bad-code enrollment created %d devices", n)
	}
}

// TestEnrollWebUnavailableWithoutWebClient: without GOOGLE_WEB_CLIENT_ID the
// web flow answers 503 (the agent's cue to fall back to device-code) and the
// browser endpoints render the unavailable page — while the device-code flow
// keeps working end to end.
func TestEnrollWebUnavailableWithoutWebClient(t *testing.T) {
	f := newFakeIssuer(t)
	g := newFakeGoogleDeviceFlow(f) // token endpoint speaks device-code only
	ts, store, _ := newEnrollTestServer(t, f)

	resp, err := http.Post(ts.URL+"/v1/enroll/start", "application/json",
		strings.NewReader(`{"name":"box","flow":"web"}`))
	if err != nil {
		t.Fatalf("web start: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("web start without web client status = %d, want 503", resp.StatusCode)
	}

	if status, _, _ := browsePath(t, ts, "/enroll/some-nonce"); status != http.StatusServiceUnavailable {
		t.Fatalf("enroll link without web client status = %d, want 503", status)
	}

	// Device-code flow is untouched.
	id, tok := enrollToCompletion(t, ts, f, g, "fallback-still-works")
	if id == "" || tok == "" || store.Get(id) == nil {
		t.Fatal("device-code flow broken with web client unset")
	}
}

// TestEnrollWebUnknownFlowRejected: an unrecognized flow value is a 400, not
// a silent device-code start.
func TestEnrollWebUnknownFlowRejected(t *testing.T) {
	f := newFakeIssuer(t)
	newFakeGoogleWebFlow(f)
	ts, _, _ := newEnrollTestServer(t, f, withWebClient)

	resp, err := http.Post(ts.URL+"/v1/enroll/start", "application/json",
		strings.NewReader(`{"name":"box","flow":"carrier-pigeon"}`))
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("unknown flow status = %d, want 400", resp.StatusCode)
	}
}
