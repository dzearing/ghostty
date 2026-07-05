package main

// OAuth self-enrollment (relay side): browser (web-callback) flow with the
// device-code flow as the headless fallback.
//
// An agent on a fresh machine enrolls itself without any pre-existing
// credential: it POSTs /v1/enroll/start with its machine name, shows (and
// tries to open) the returned prompt to its owner, and polls /v1/enroll/poll
// until the owner completes the Google sign-in. On success the relay verifies
// the resulting ID token EXACTLY like interactive client auth (same verifier,
// same ALLOWED_EMAILS), upserts the machine as a device owned by that
// identity, and hands back a device token once.
//
// Two start modes ({"flow":"web"} vs default "device"):
//
//   - WEB (Tailscale-style, machines with a browser): the relay mints a
//     pending enrollment plus a human-friendly single-use URL
//     GET /enroll/<nonce>. Opening it 302s to Google's auth endpoint with the
//     Web client; Google redirects back to GET /enroll/callback?code&state,
//     where the relay exchanges the code (server-side, with the Web client
//     secret), verifies the ID token, upserts the device, and renders a tiny
//     success page. The agent's poll then returns "complete" exactly as in
//     the device flow — the agent side needs no poll changes. `state` is a
//     fresh 256-bit random value minted at redirect time and mapped in
//     memory to the pending enrollment (no signing needed), so a forged or
//     replayed callback cannot bind to someone else's enrollment.
//   - DEVICE (RFC 8628, headless fallback): "visit <url>, enter <code>",
//     unchanged.
//
// Security posture — the enrolling machine is UNAUTHENTICATED, so:
//
//   - Google's device_code never leaves the relay. The caller gets an opaque
//     relay-minted handle instead. The device_code is a bearer credential to
//     Google's token endpoint (anyone holding it + the public client id/secret
//     of a TV/desktop client could poll Google directly and mint ID tokens for
//     whoever approves the user_code); keeping it server-side means the handle
//     is worthless outside this relay, the relay alone controls the poll rate
//     Google sees, and the owner's ID token never transits the agent box.
//   - Polls are rate-limited per handle to the interval Google prescribed;
//     early polls are answered from memory without touching Google.
//   - Pending enrollments are capped and expire on Google's expires_in, so an
//     unauthenticated caller cannot grow state or launder unlimited requests
//     to Google through the relay.
//   - The success payload (device token) is returned exactly once, then the
//     handle is forgotten. A lost response is recovered by re-enrolling, which
//     is idempotent (same owner+name -> same device, fresh token).

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

const (
	// grantTypeDeviceCode is the RFC 8628 device-code grant type.
	grantTypeDeviceCode = "urn:ietf:params:oauth:grant-type:device_code"

	// maxPendingEnrollments bounds in-memory state creatable by
	// unauthenticated callers (and the Google traffic they can induce).
	maxPendingEnrollments = 32

	// maxEnrollNameLen bounds the requested machine name.
	maxEnrollNameLen = 128

	// defaultPollInterval is used if Google omits `interval` (it documents 5s
	// as the minimum).
	defaultPollInterval = 5 * time.Second

	// slowDownBump is how much the poll interval grows on a slow_down error,
	// per RFC 8628 §3.5.
	slowDownBump = 5 * time.Second

	// webEnrollExpiry bounds how long a web enrollment (nonce + state +
	// pending handle) stays alive. There is no Google-prescribed expires_in
	// for this flow; 15 minutes is plenty to click through a sign-in.
	webEnrollExpiry = 15 * time.Minute

	// webPollInterval is the poll cadence advertised for web enrollments.
	// Web polls are answered entirely from relay memory (Google is only
	// contacted once, in the callback), so this can be snappy.
	webPollInterval = 2 * time.Second
)

// Enrollment flows.
const (
	flowDevice = "device"
	flowWeb    = "web"
)

// Errors mapped to HTTP statuses / error pages by the handlers.
var (
	errEnrollUnavailable = errors.New("enrollment unavailable")
	errEnrollBusy        = errors.New("too many pending enrollments")

	// Web-flow browser-facing failures (rendered as terse HTML pages).
	errWebNonceUnknown = errors.New("unknown or expired enrollment link")
	errWebStateUnknown = errors.New("unknown or expired sign-in state")
	errWebExchange     = errors.New("code exchange with the issuer failed")
	errWebRejected     = errors.New("identity not allowed")
	errWebInternal     = errors.New("internal error")
)

// enrollment is one in-flight enrollment (device-code or web), keyed by its
// opaque poll handle.
type enrollment struct {
	name string // requested machine name
	flow string // flowDevice or flowWeb

	// inviteCode is the signup code supplied at Start (device flow) or on the
	// browser entry (web flow). It is consumed by the SigninGate at the success
	// path when INVITE_SIGNUP is ON to create a brand-new account. Empty for an
	// existing/returning owner (who never needs a code) and ignored entirely
	// when the flag is OFF.
	inviteCode string

	// Device flow only.
	deviceCode string // Google device_code — NEVER sent to the caller

	// Web flow only. nonce/state/redirectURI drive the browser leg; the
	// web* outcome fields are filled by the callback and delivered by the
	// next poll.
	webNonce       string         // single-use /enroll/<nonce> entry; "" once consumed
	webState       string         // OAuth `state` (random, in-memory map); "" until redirect / after use
	webRedirectURI string         // exact redirect_uri sent to the auth endpoint (must match at exchange)
	webDone        bool           // the callback reached a terminal outcome
	webStatus      int            // poll HTTP status once webDone
	webBody        map[string]any // poll body once webDone (relay_base added at poll time)

	interval   time.Duration // minimum poll spacing
	expiresAt  time.Time     // enrollment deadline
	nextPollAt time.Time     // earliest time the next upstream poll may run
	inFlight   bool          // an upstream poll is executing right now
}

// EnrollManager owns the pending-enrollment table and the Google device-code
// conversation. All upstream endpoints come from the authenticator's OIDC
// discovery, so tests redirect them via the same fake issuer as client auth.
type EnrollManager struct {
	cfg    *Config
	auth   *Authenticator
	store  *Store
	logger *slog.Logger

	mu      sync.Mutex
	pending map[string]*enrollment
	nonces  map[string]string // web entry nonce -> poll handle
	states  map[string]string // OAuth state -> poll handle
}

// NewEnrollManager wires the enrollment flow.
func NewEnrollManager(cfg *Config, auth *Authenticator, store *Store, logger *slog.Logger) *EnrollManager {
	return &EnrollManager{
		cfg:     cfg,
		auth:    auth,
		store:   store,
		logger:  logger,
		pending: make(map[string]*enrollment),
		nonces:  make(map[string]string),
		states:  make(map[string]string),
	}
}

// authorizeEnroll verifies an enrollment ID token and authorizes it under the
// active model. Flag OFF: exactly the legacy path (VerifyIDToken = verify +
// ALLOWED_EMAILS). Flag ON: verify identity (unchanged OIDC strictness), then
// the invite-code gate decides — an existing/returning owner needs no code, a
// brand-new account consumes inviteCode. Returns the authorized identity or an
// error (ErrUnauthorized / ErrInviteRequired). ip feeds the attempt audit.
func (m *EnrollManager) authorizeEnroll(ctx context.Context, idToken, inviteCode, ip string) (Identity, error) {
	gate := m.auth.gate
	if gate == nil || !gate.Enabled() {
		return m.auth.VerifyIDToken(ctx, idToken)
	}
	ident, err := m.auth.VerifyIdentity(ctx, idToken)
	if err != nil {
		return Identity{}, err
	}
	if err := gate.Authorize(ident, inviteCode, ip); err != nil {
		return Identity{}, err
	}
	return ident, nil
}

// available reports whether the issuer advertises a device flow and OIDC
// client auth is configured (the success path needs the verifier).
func (m *EnrollManager) available() bool {
	return m.auth.verifier != nil && m.auth.deviceAuthURL != "" && m.auth.tokenURL != ""
}

// webAvailable reports whether the browser (web-callback) enroll flow is
// configured: OIDC verifier + auth/token endpoints + a Web OAuth client.
func (m *EnrollManager) webAvailable() bool {
	return m.auth.verifier != nil && m.auth.authURL != "" && m.auth.tokenURL != "" &&
		m.cfg.GoogleWebClientID != "" && m.cfg.GoogleWebClientSecret != ""
}

// enrollStartResponse is the JSON body of POST /v1/enroll/start.
type enrollStartResponse struct {
	VerificationURL  string `json:"verification_url"`
	UserCode         string `json:"user_code"`
	DeviceCodeHandle string `json:"device_code_handle"`
	Interval         int    `json:"interval"`   // seconds between polls
	ExpiresIn        int    `json:"expires_in"` // seconds until the code dies
}

// Start begins an enrollment: asks Google for a device/user code pair and
// files it under a fresh opaque handle. inviteCode (may be empty) is parked on
// the enrollment for the invite-code gate to consume on the success path when
// INVITE_SIGNUP is ON.
func (m *EnrollManager) Start(ctx context.Context, name, inviteCode string) (*enrollStartResponse, error) {
	if !m.available() {
		return nil, errEnrollUnavailable
	}

	// Reserve a slot before spending an upstream request.
	now := time.Now()
	m.mu.Lock()
	m.purgeExpiredLocked(now)
	if len(m.pending) >= maxPendingEnrollments {
		m.mu.Unlock()
		return nil, errEnrollBusy
	}
	m.mu.Unlock()

	form := url.Values{
		"client_id": {m.cfg.EnrollClientID()},
		"scope":     {"openid email"},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, m.auth.deviceAuthURL,
		strings.NewReader(form.Encode()))
	if err != nil {
		return nil, fmt.Errorf("build device-code request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := m.auth.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("device-code request: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if err != nil {
		return nil, fmt.Errorf("read device-code response: %w", err)
	}

	var out struct {
		DeviceCode      string `json:"device_code"`
		UserCode        string `json:"user_code"`
		VerificationURL string `json:"verification_url"` // Google's field name
		VerificationURI string `json:"verification_uri"` // RFC 8628 field name
		ExpiresIn       int    `json:"expires_in"`
		Interval        int    `json:"interval"`
		Error           string `json:"error"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("parse device-code response (status %d): %w", resp.StatusCode, err)
	}
	verificationURL := out.VerificationURL
	if verificationURL == "" {
		verificationURL = out.VerificationURI
	}
	if resp.StatusCode != http.StatusOK || out.DeviceCode == "" || out.UserCode == "" ||
		verificationURL == "" || out.ExpiresIn <= 0 {
		return nil, fmt.Errorf("device-code endpoint refused (status %d, error %q)", resp.StatusCode, out.Error)
	}

	interval := time.Duration(out.Interval) * time.Second
	if interval <= 0 {
		interval = defaultPollInterval
	}

	handle, err := newEnrollHandle()
	if err != nil {
		return nil, err
	}

	now = time.Now()
	m.mu.Lock()
	// Re-check the cap under lock: slots may have filled while we were talking
	// to Google. Better to drop this response than to grow unbounded.
	if len(m.pending) >= maxPendingEnrollments {
		m.mu.Unlock()
		return nil, errEnrollBusy
	}
	m.pending[handle] = &enrollment{
		name:       name,
		flow:       flowDevice,
		inviteCode: inviteCode,
		deviceCode: out.DeviceCode,
		interval:   interval,
		expiresAt:  now.Add(time.Duration(out.ExpiresIn) * time.Second),
		nextPollAt: now, // the first poll may run immediately
	}
	m.mu.Unlock()

	// The user_code is a live (short-lived) enrollment credential shown to the
	// human — deliberately NOT logged.
	m.logger.Info("enrollment started", "name", name)

	return &enrollStartResponse{
		VerificationURL:  verificationURL,
		UserCode:         out.UserCode,
		DeviceCodeHandle: handle,
		Interval:         int(interval / time.Second),
		ExpiresIn:        out.ExpiresIn,
	}, nil
}

// webStartResponse is the JSON body of POST /v1/enroll/start for
// {"flow":"web"}.
type webStartResponse struct {
	EnrollURL        string `json:"enroll_url"`
	DeviceCodeHandle string `json:"device_code_handle"`
	Interval         int    `json:"interval"`   // seconds between polls
	ExpiresIn        int    `json:"expires_in"` // seconds until the link dies
}

// StartWeb begins a browser enrollment: files a pending enrollment under a
// fresh opaque poll handle plus a distinct single-use browser nonce, and
// returns the relay-hosted URL the owner should open. No upstream request is
// made — Google is first contacted when the browser hits the callback.
func (m *EnrollManager) StartWeb(name, inviteCode, relayBase string) (*webStartResponse, error) {
	if !m.webAvailable() {
		return nil, errEnrollUnavailable
	}

	handle, err := newEnrollHandle()
	if err != nil {
		return nil, err
	}
	nonce, err := newEnrollHandle()
	if err != nil {
		return nil, err
	}

	now := time.Now()
	m.mu.Lock()
	m.purgeExpiredLocked(now)
	if len(m.pending) >= maxPendingEnrollments {
		m.mu.Unlock()
		return nil, errEnrollBusy
	}
	m.pending[handle] = &enrollment{
		name:       name,
		flow:       flowWeb,
		inviteCode: inviteCode,
		webNonce:   nonce,
		interval:   webPollInterval,
		expiresAt:  now.Add(webEnrollExpiry),
		nextPollAt: now,
	}
	m.nonces[nonce] = handle
	m.mu.Unlock()

	m.logger.Info("web enrollment started", "name", name)

	return &webStartResponse{
		EnrollURL:        relayBase + "/enroll/" + nonce,
		DeviceCodeHandle: handle,
		Interval:         int(webPollInterval / time.Second),
		ExpiresIn:        int(webEnrollExpiry / time.Second),
	}, nil
}

// AuthRedirectURL consumes a web enrollment's single-use browser nonce and
// returns the Google authorization URL to 302 the browser to. The freshly
// minted `state` is stored on the pending enrollment (and indexed) so the
// callback can bind the returning browser to exactly this enrollment.
func (m *EnrollManager) AuthRedirectURL(nonce, relayBase string) (string, error) {
	if !m.webAvailable() {
		return "", errEnrollUnavailable
	}
	state, err := newEnrollHandle()
	if err != nil {
		return "", err
	}
	redirectURI := relayBase + "/enroll/callback"

	m.mu.Lock()
	m.purgeExpiredLocked(time.Now())
	handle, ok := m.nonces[nonce]
	if !ok {
		m.mu.Unlock()
		return "", errWebNonceUnknown
	}
	e := m.pending[handle]
	delete(m.nonces, nonce) // single-use: a replayed link gets an error page
	e.webNonce = ""
	e.webState = state
	e.webRedirectURI = redirectURI
	m.states[state] = handle
	m.mu.Unlock()

	q := url.Values{
		"client_id":     {m.cfg.GoogleWebClientID},
		"redirect_uri":  {redirectURI},
		"response_type": {"code"},
		"scope":         {"openid email"},
		"state":         {state},
		"prompt":        {"select_account"},
	}
	return m.auth.authURL + "?" + q.Encode(), nil
}

// Callback completes a web enrollment: binds `state` back to its pending
// enrollment, exchanges the authorization code with the Web client
// (server-side — the client secret and the ID token never leave the relay),
// verifies the identity through the shared VerifyIDToken gate, and upserts
// the device. The outcome is parked on the enrollment for the agent's next
// poll to deliver; the returned machine name feeds the success page.
func (m *EnrollManager) Callback(ctx context.Context, code, state, ip string) (string, error) {
	m.mu.Lock()
	m.purgeExpiredLocked(time.Now())
	handle, ok := m.states[state]
	if !ok {
		m.mu.Unlock()
		return "", errWebStateUnknown
	}
	e := m.pending[handle]
	delete(m.states, state) // single-use: a replayed callback gets an error page
	e.webState = ""
	name, redirectURI, inviteCode := e.name, e.webRedirectURI, e.inviteCode
	m.mu.Unlock()

	idToken, oauthErr, err := m.exchangeAuthCode(ctx, code, redirectURI)
	switch {
	case err != nil:
		m.finishWeb(handle, http.StatusBadGateway, map[string]any{
			"status": "error", "error": "upstream error",
		})
		m.logger.Warn("web enroll code exchange failed", "name", name, "err", err)
		return "", errWebExchange
	case oauthErr != "":
		m.finishWeb(handle, http.StatusBadRequest, map[string]any{
			"status": "error", "error": oauthErr,
		})
		m.logger.Warn("web enroll code refused", "name", name, "oauth_error", oauthErr)
		return "", errWebExchange
	}

	ident, verr := m.authorizeEnroll(ctx, idToken, inviteCode, ip)
	if verr != nil {
		// A real Google login that fails verification/authorization (allowlist
		// when flag OFF, or blocked-account / missing-or-bad invite when ON) is
		// terminal for this enrollment.
		m.finishWeb(handle, http.StatusForbidden, map[string]any{"status": "rejected"})
		m.logger.Warn("web enrollment identity rejected", "name", name, "err", verr)
		return "", errWebRejected
	}

	// M4: quota-aware upsert (device quota; rotation of an existing device is
	// never counted — quotas.go).
	dev, rawToken, uerr := m.upsertEnrolled(ident, name)
	if uerr != nil {
		out := m.enrollUpsertFailed(name, uerr)
		m.finishWeb(handle, out.status, out.body)
		if isQuotaExceeded(uerr) {
			return "", errWebQuota
		}
		return "", errWebInternal
	}

	m.finishWeb(handle, http.StatusOK, map[string]any{
		"status":       "complete",
		"device_id":    dev.ID,
		"device_token": rawToken, // delivered to the agent exactly once, by poll
	})
	m.logger.Info("device web-enrolled", "device", dev.ID, "owner", ident.Email, "name", dev.Name)
	return name, nil
}

// DenyByState marks a web enrollment denied (the owner cancelled on Google's
// consent page — Google redirects back with error=access_denied&state=...).
// Unknown/expired state is answered with the same error as Callback.
func (m *EnrollManager) DenyByState(state string) error {
	m.mu.Lock()
	m.purgeExpiredLocked(time.Now())
	handle, ok := m.states[state]
	if !ok {
		m.mu.Unlock()
		return errWebStateUnknown
	}
	e := m.pending[handle]
	delete(m.states, state)
	e.webState = ""
	name := e.name
	m.mu.Unlock()

	m.finishWeb(handle, http.StatusForbidden, map[string]any{"status": "denied"})
	m.logger.Info("web enrollment denied by user", "name", name)
	return nil
}

// finishWeb parks a terminal outcome on a web enrollment (if it still
// exists) for the agent's next poll to deliver. Takes m.mu itself.
func (m *EnrollManager) finishWeb(handle string, status int, body map[string]any) {
	m.mu.Lock()
	defer m.mu.Unlock()
	e := m.pending[handle]
	if e == nil || e.flow != flowWeb {
		return // expired/purged while we talked to Google; the token is lost, re-enroll recovers
	}
	e.webDone = true
	e.webStatus = status
	e.webBody = body
}

// exchangeAuthCode redeems a web-flow authorization code at the token
// endpoint using the Web client id + secret. Same result contract as
// exchangeDeviceCode.
func (m *EnrollManager) exchangeAuthCode(ctx context.Context, code, redirectURI string) (idToken, oauthErr string, err error) {
	return m.postTokenForm(ctx, url.Values{
		"client_id":     {m.cfg.GoogleWebClientID},
		"client_secret": {m.cfg.GoogleWebClientSecret},
		"code":          {code},
		"grant_type":    {"authorization_code"},
		"redirect_uri":  {redirectURI},
	})
}

// pollOutcome is what a poll returns to the HTTP layer: a status code and a
// ready-to-encode JSON body.
type pollOutcome struct {
	status int
	body   map[string]any
}

// Poll advances one enrollment. relayBase is echoed to the agent on success
// so it knows where to dial back. ip feeds the sign-in attempt audit on the
// success path when INVITE_SIGNUP is ON.
func (m *EnrollManager) Poll(ctx context.Context, handle, relayBase, ip string) pollOutcome {
	now := time.Now()
	m.mu.Lock()
	m.purgeExpiredLocked(now)
	e := m.pending[handle]
	if e == nil {
		// Unknown, already-consumed, terminal, or expired-and-purged. Handles
		// are 256-bit random, so this is not an enumeration oracle.
		m.mu.Unlock()
		return pollOutcome{http.StatusNotFound, map[string]any{
			"status": "unknown",
			"error":  "unknown or completed device_code_handle",
		}}
	}
	if now.After(e.expiresAt) {
		m.removeLocked(handle, e)
		m.mu.Unlock()
		return pollOutcome{http.StatusGone, map[string]any{"status": "expired"}}
	}
	if e.flow == flowWeb {
		// Web enrollments never poll upstream: the browser callback resolves
		// them, this poll just delivers the parked outcome (exactly once).
		if !e.webDone {
			iv := int(e.interval / time.Second)
			m.mu.Unlock()
			return pollOutcome{http.StatusOK, map[string]any{"status": "pending", "interval": iv}}
		}
		status, body := e.webStatus, e.webBody
		m.removeLocked(handle, e)
		m.mu.Unlock()
		if body["status"] == "complete" {
			body["relay_base"] = relayBase
		}
		return pollOutcome{status, body}
	}
	if e.inFlight || now.Before(e.nextPollAt) {
		// Rate limit: answered from memory, Google is not contacted.
		iv := int(e.interval / time.Second)
		m.mu.Unlock()
		return pollOutcome{http.StatusTooManyRequests, map[string]any{
			"status":   "slow_down",
			"interval": iv,
		}}
	}
	e.inFlight = true
	e.nextPollAt = now.Add(e.interval)
	deviceCode, name, inviteCode := e.deviceCode, e.name, e.inviteCode
	m.mu.Unlock()

	// Talk to Google outside the lock.
	idToken, oauthErr, err := m.exchangeDeviceCode(ctx, deviceCode)

	m.mu.Lock()
	e.inFlight = false
	switch {
	case err != nil:
		// Transient upstream trouble: keep the enrollment alive; the agent
		// retries on the normal interval.
		m.mu.Unlock()
		m.logger.Warn("enroll token poll failed", "err", err)
		return pollOutcome{http.StatusBadGateway, map[string]any{
			"status": "error",
			"error":  "upstream error, retry",
		}}
	case oauthErr == "authorization_pending":
		iv := int(e.interval / time.Second)
		m.mu.Unlock()
		return pollOutcome{http.StatusOK, map[string]any{"status": "pending", "interval": iv}}
	case oauthErr == "slow_down":
		e.interval += slowDownBump
		e.nextPollAt = time.Now().Add(e.interval)
		iv := int(e.interval / time.Second)
		m.mu.Unlock()
		return pollOutcome{http.StatusOK, map[string]any{"status": "pending", "interval": iv}}
	case oauthErr == "access_denied":
		delete(m.pending, handle)
		m.mu.Unlock()
		m.logger.Info("enrollment denied by user", "name", name)
		return pollOutcome{http.StatusForbidden, map[string]any{"status": "denied"}}
	case oauthErr == "expired_token":
		delete(m.pending, handle)
		m.mu.Unlock()
		return pollOutcome{http.StatusGone, map[string]any{"status": "expired"}}
	case oauthErr != "":
		// Unknown OAuth error: the grant is not going to recover. Terminal.
		delete(m.pending, handle)
		m.mu.Unlock()
		m.logger.Warn("enrollment failed at token endpoint", "name", name, "oauth_error", oauthErr)
		return pollOutcome{http.StatusBadRequest, map[string]any{"status": "error", "error": oauthErr}}
	}
	m.mu.Unlock()

	// The owner approved. Verify the ID token EXACTLY like client auth
	// (signature/issuer/aud/exp + email_verified) and authorize it: ALLOWED_EMAILS
	// when INVITE_SIGNUP is OFF, or the invite-code account model when ON (a
	// returning owner needs no code; a brand-new account consumes inviteCode).
	ident, verr := m.authorizeEnroll(ctx, idToken, inviteCode, ip)
	if verr != nil {
		// A real Google login that fails verification/authorization is terminal:
		// retrying the same grant cannot change the identity or the invite.
		m.mu.Lock()
		delete(m.pending, handle)
		m.mu.Unlock()
		m.logger.Warn("enrollment identity rejected", "name", name, "err", verr)
		return pollOutcome{http.StatusForbidden, map[string]any{"status": "rejected"}}
	}

	// M4: quota-aware upsert (device quota; rotation of an existing device is
	// never counted — quotas.go).
	dev, rawToken, uerr := m.upsertEnrolled(ident, name)

	// The grant is single-use at Google either way; drop the handle now.
	m.mu.Lock()
	delete(m.pending, handle)
	m.mu.Unlock()

	if uerr != nil {
		return m.enrollUpsertFailed(name, uerr)
	}

	m.logger.Info("device self-enrolled", "device", dev.ID, "owner", ident.Email, "name", dev.Name)

	return pollOutcome{http.StatusOK, map[string]any{
		"status":       "complete",
		"device_id":    dev.ID,
		"device_token": rawToken, // returned exactly once
		"relay_base":   relayBase,
	}}
}

// exchangeDeviceCode polls Google's token endpoint once for the device_code.
// Returns the ID token on success, the OAuth error code (e.g.
// "authorization_pending") on a protocol-level answer, or err on
// transport/5xx/malformed trouble.
func (m *EnrollManager) exchangeDeviceCode(ctx context.Context, deviceCode string) (idToken, oauthErr string, err error) {
	form := url.Values{
		"client_id":   {m.cfg.EnrollClientID()},
		"device_code": {deviceCode},
		"grant_type":  {grantTypeDeviceCode},
	}
	if s := m.cfg.EnrollClientSecret(); s != "" {
		form.Set("client_secret", s)
	}
	return m.postTokenForm(ctx, form)
}

// postTokenForm POSTs a form to the issuer's token endpoint and decodes the
// answer. Returns the ID token on success, the OAuth error code (e.g.
// "authorization_pending", "invalid_grant") on a protocol-level answer, or
// err on transport/5xx/malformed trouble.
func (m *EnrollManager) postTokenForm(ctx context.Context, form url.Values) (idToken, oauthErr string, err error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, m.auth.tokenURL,
		strings.NewReader(form.Encode()))
	if err != nil {
		return "", "", fmt.Errorf("build token request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := m.auth.httpClient.Do(req)
	if err != nil {
		return "", "", fmt.Errorf("token request: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", "", fmt.Errorf("read token response: %w", err)
	}
	if resp.StatusCode >= 500 {
		return "", "", fmt.Errorf("token endpoint status %d", resp.StatusCode)
	}

	var out struct {
		IDToken string `json:"id_token"`
		Error   string `json:"error"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return "", "", fmt.Errorf("parse token response (status %d): %w", resp.StatusCode, err)
	}
	switch {
	case out.Error != "":
		return "", out.Error, nil
	case resp.StatusCode == http.StatusOK && out.IDToken != "":
		return out.IDToken, "", nil
	default:
		return "", "", fmt.Errorf("token endpoint returned neither id_token nor error (status %d)", resp.StatusCode)
	}
}

// purgeExpiredLocked drops expired enrollments. Caller holds m.mu.
func (m *EnrollManager) purgeExpiredLocked(now time.Time) {
	for h, e := range m.pending {
		if now.After(e.expiresAt) && !e.inFlight {
			m.removeLocked(h, e)
		}
	}
}

// removeLocked forgets an enrollment and its web-flow index entries. Caller
// holds m.mu.
func (m *EnrollManager) removeLocked(handle string, e *enrollment) {
	if e.webNonce != "" {
		delete(m.nonces, e.webNonce)
	}
	if e.webState != "" {
		delete(m.states, e.webState)
	}
	delete(m.pending, handle)
}

// newEnrollHandle mints a 32-byte random opaque handle.
func newEnrollHandle() (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("generate enroll handle: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}
