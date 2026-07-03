package main

// OAuth device-code self-enrollment (WP-B3, relay side).
//
// An agent on a fresh machine enrolls itself without any pre-existing
// credential: it POSTs /v1/enroll/start with its machine name, shows the
// returned "visit <url>, enter <code>" prompt to its owner, and polls
// /v1/enroll/poll until the owner completes the Google sign-in. On success
// the relay verifies the resulting ID token EXACTLY like interactive client
// auth (same verifier, same ALLOWED_EMAILS), upserts the machine as a device
// owned by that identity, and hands back a device token once.
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
)

// Errors mapped to HTTP statuses by the handlers.
var (
	errEnrollUnavailable = errors.New("device-code enrollment unavailable")
	errEnrollBusy        = errors.New("too many pending enrollments")
)

// enrollment is one in-flight device-code enrollment, keyed by its opaque
// handle.
type enrollment struct {
	name       string        // requested machine name
	deviceCode string        // Google device_code — NEVER sent to the caller
	interval   time.Duration // minimum poll spacing (Google's `interval`)
	expiresAt  time.Time     // Google's expires_in deadline
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
}

// NewEnrollManager wires the enrollment flow.
func NewEnrollManager(cfg *Config, auth *Authenticator, store *Store, logger *slog.Logger) *EnrollManager {
	return &EnrollManager{
		cfg:     cfg,
		auth:    auth,
		store:   store,
		logger:  logger,
		pending: make(map[string]*enrollment),
	}
}

// available reports whether the issuer advertises a device flow and OIDC
// client auth is configured (the success path needs the verifier).
func (m *EnrollManager) available() bool {
	return m.auth.verifier != nil && m.auth.deviceAuthURL != "" && m.auth.tokenURL != ""
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
// files it under a fresh opaque handle.
func (m *EnrollManager) Start(ctx context.Context, name string) (*enrollStartResponse, error) {
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
		"client_id": {m.cfg.GoogleClientID},
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
		deviceCode: out.DeviceCode,
		interval:   interval,
		expiresAt:  now.Add(time.Duration(out.ExpiresIn) * time.Second),
		nextPollAt: now, // the first poll may run immediately
	}
	m.mu.Unlock()

	m.logger.Info("enrollment started", "name", name, "user_code", out.UserCode)

	return &enrollStartResponse{
		VerificationURL:  verificationURL,
		UserCode:         out.UserCode,
		DeviceCodeHandle: handle,
		Interval:         int(interval / time.Second),
		ExpiresIn:        out.ExpiresIn,
	}, nil
}

// pollOutcome is what a poll returns to the HTTP layer: a status code and a
// ready-to-encode JSON body.
type pollOutcome struct {
	status int
	body   map[string]any
}

// Poll advances one enrollment. relayBase is echoed to the agent on success
// so it knows where to dial back.
func (m *EnrollManager) Poll(ctx context.Context, handle, relayBase string) pollOutcome {
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
		delete(m.pending, handle)
		m.mu.Unlock()
		return pollOutcome{http.StatusGone, map[string]any{"status": "expired"}}
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
	deviceCode, name := e.deviceCode, e.name
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

	// The owner approved. Verify the ID token EXACTLY like client auth:
	// signature/issuer/aud/exp + email_verified + ALLOWED_EMAILS.
	ident, verr := m.auth.VerifyIDToken(ctx, idToken)
	if verr != nil {
		// A real Google login that fails our verification/allowlist is
		// terminal: retrying the same grant cannot change the identity.
		m.mu.Lock()
		delete(m.pending, handle)
		m.mu.Unlock()
		m.logger.Warn("enrollment identity rejected", "name", name)
		return pollOutcome{http.StatusForbidden, map[string]any{"status": "rejected"}}
	}

	dev, rawToken, uerr := m.store.UpsertDevice(ident.Email, ident.Sub, name)

	// The grant is single-use at Google either way; drop the handle now.
	m.mu.Lock()
	delete(m.pending, handle)
	m.mu.Unlock()

	if uerr != nil {
		m.logger.Error("enroll upsert failed", "err", uerr)
		return pollOutcome{http.StatusInternalServerError, map[string]any{
			"status": "error",
			"error":  "internal error",
		}}
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
		"client_id":   {m.cfg.GoogleClientID},
		"device_code": {deviceCode},
		"grant_type":  {grantTypeDeviceCode},
	}
	if m.cfg.GoogleClientSecret != "" {
		form.Set("client_secret", m.cfg.GoogleClientSecret)
	}

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
			delete(m.pending, h)
		}
	}
}

// newEnrollHandle mints a 32-byte random opaque handle.
func newEnrollHandle() (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("generate enroll handle: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}
