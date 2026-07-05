package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/coder/websocket"
)

// sessionSetupTimeout bounds how long a client waits for the agent to dial back
// its data connection before giving up.
const sessionSetupTimeout = 15 * time.Second

// heartbeatInterval / heartbeatTimeout govern control-connection liveness.
const (
	heartbeatInterval = 15 * time.Second
	heartbeatTimeout  = 10 * time.Second
)

// Handler wires the HTTP/WS endpoints to the auth, store, and directory.
type Handler struct {
	cfg    *Config
	auth   *Authenticator
	store  *Store
	dir    *Directory
	enroll *EnrollManager
	quotas *Quotas       // M4 per-account limits (quotas.go)
	rl     *RateLimiters // M4 abuse-control rate limits (ratelimit.go)
	logger *slog.Logger
}

// NewHandler constructs a Handler.
func NewHandler(cfg *Config, auth *Authenticator, store *Store, dir *Directory, logger *slog.Logger) *Handler {
	h := &Handler{
		cfg:    cfg,
		auth:   auth,
		store:  store,
		dir:    dir,
		enroll: NewEnrollManager(cfg, auth, store, logger),
		quotas: NewQuotas(cfg, store, dir, logger),
		rl:     NewRateLimiters(cfg),
		logger: logger,
	}
	// M4: bind the failed-sign-in limiter into the Authenticator (late bind,
	// mirroring SetGate) so production and every test wiring get it through
	// this one path with no main.go changes.
	auth.SetRateLimits(h.rl)
	return h
}

// Register attaches all routes to mux. Method+path patterns require Go 1.22+.
func (h *Handler) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/agent/control", h.handleAgentControl)
	mux.HandleFunc("GET /v1/agent/data", h.handleAgentData)
	mux.HandleFunc("GET /v1/agent/whoami", h.handleAgentWhoami)
	mux.HandleFunc("POST /v1/agent/deenroll", h.handleAgentDeenroll)
	mux.HandleFunc("GET /v1/client/devices", h.handleListDevices)
	mux.HandleFunc("POST /v1/client/devices", h.handleEnrollDevice)
	mux.HandleFunc("PATCH /v1/client/devices/{id}", h.handleRenameDevice)
	mux.HandleFunc("DELETE /v1/client/devices/{id}", h.handleDeleteDevice)
	mux.HandleFunc("GET /v1/client/connect", h.handleClientConnect)
	mux.HandleFunc("POST /v1/enroll/start", h.handleEnrollStart)
	mux.HandleFunc("POST /v1/enroll/poll", h.handleEnrollPoll)
	// Browser-facing web-enroll leg. The literal "callback" segment wins over
	// the {nonce} wildcard per ServeMux precedence, so both can coexist.
	mux.HandleFunc("GET /enroll/callback", h.handleEnrollCallback)
	mux.HandleFunc("GET /enroll/{nonce}", h.handleEnrollWeb)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})
}

// acceptOptions are shared WS accept options. Origin checking is disabled
// because both peers are non-browser programmatic clients (the Ghoztty app and
// the agent daemon) authenticated via bearer tokens, not browser same-origin.
var acceptOptions = &websocket.AcceptOptions{InsecureSkipVerify: true}

// --- Agent endpoints -------------------------------------------------------

// hostnameHeader is the optional agent-supplied header on control connects
// carrying the machine's OS-reported hostname. Kept distinct from the
// user-facing display name: rename changes the name, never the hostname.
const hostnameHeader = "X-Ghoztty-Hostname"

// maxHostnameLen bounds the agent-reported hostname (matches the enroll name
// bound; RFC 1035 caps hostnames at 255 anyway).
const maxHostnameLen = 128

// handleAgentControl: GET /v1/agent/control (WebSocket).
// Authenticates the device token, registers the device online, then holds the
// connection open with a ping/pong heartbeat. Disconnect -> device offline.
// If the agent sent an X-Ghoztty-Hostname header, the device's hostname is
// upserted (older agents omit it — tolerated).
func (h *Handler) handleAgentControl(w http.ResponseWriter, r *http.Request) {
	dev, err := h.auth.AuthenticateDevice(r, h.store)
	if err != nil {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	// Record the agent-reported hostname before upgrading. Best-effort: a
	// persist failure must not cost the device its connectivity.
	if hn := strings.TrimSpace(r.Header.Get(hostnameHeader)); hn != "" && len(hn) <= maxHostnameLen {
		if err := h.store.SetHostname(dev.ID, hn); err != nil {
			h.logger.Warn("hostname upsert failed", "device", dev.ID, "err", err)
		}
	}

	c, err := websocket.Accept(w, r, acceptOptions)
	if err != nil {
		return // Accept already wrote the response
	}

	ac := h.dir.RegisterAgent(dev.ID, c)
	defer h.dir.UnregisterAgent(ac)
	defer c.CloseNow()

	// CloseRead spawns a background reader that processes control frames
	// (ping/pong/close) and cancels readCtx on disconnect. The agent is not
	// expected to send data messages on the control channel; if it does, the
	// connection is closed with a policy violation.
	readCtx := c.CloseRead(r.Context())

	ticker := time.NewTicker(heartbeatInterval)
	defer ticker.Stop()
	for {
		select {
		case <-readCtx.Done():
			return // peer disconnected
		case <-ticker.C:
			pingCtx, cancel := context.WithTimeout(readCtx, heartbeatTimeout)
			err := c.Ping(pingCtx)
			cancel()
			if err != nil {
				h.logger.Info("control heartbeat failed; closing", "device", dev.ID)
				return
			}
		}
	}
}

// handleAgentData: GET /v1/agent/data?session=<uuid> (WebSocket).
// The agent dials this in response to an "open" command. We authenticate the
// device, match it to the pending session (and verify the session belongs to
// this device), then block until the client handler finishes bridging.
func (h *Handler) handleAgentData(w http.ResponseWriter, r *http.Request) {
	dev, err := h.auth.AuthenticateDevice(r, h.store)
	if err != nil {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	sessionID := r.URL.Query().Get("session")
	if sessionID == "" {
		http.Error(w, "missing session", http.StatusBadRequest)
		return
	}

	c, err := websocket.Accept(w, r, acceptOptions)
	if err != nil {
		return
	}
	// Always close this data conn when the handler returns. On the normal path
	// bridge() also closes it (harmless double-close); this covers the race where
	// the agent dials back in the window between the client's timeout drain and
	// RemovePending, where bridge() never runs.
	defer c.CloseNow()

	ps, ok := h.dir.ClaimData(sessionID, dev.ID, c)
	if !ok {
		// Unknown session, wrong device, or duplicate dial: refuse, no bridge.
		c.Close(websocket.StatusPolicyViolation, "no matching session")
		return
	}

	h.logger.Info("agent data conn claimed", "device", dev.ID, "session", sessionID)

	// Hand-off complete: the client handler now owns the bridge. Block here
	// until it signals completion so this HTTP handler (and its hijacked socket)
	// stays alive for the lifetime of the bridge.
	<-ps.done
}

// handleAgentWhoami: GET /v1/agent/whoami (JSON).
// Device-authenticated. Returns the account the device token is bound to, so
// the agent's tray can show "Signed in as <email>". The agent only persists the
// opaque token locally (never the email), so it asks the relay who it is.
func (h *Handler) handleAgentWhoami(w http.ResponseWriter, r *http.Request) {
	dev, err := h.auth.AuthenticateDevice(r, h.store)
	if err != nil {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"email":     dev.OwnerEmail,
		"device_id": dev.ID,
		"name":      dev.Name,
		"hostname":  dev.Hostname,
	})
}

// handleAgentDeenroll: POST /v1/agent/deenroll (no body).
// Device-authenticated SELF de-enroll: the agent revokes its own registration.
// Deletes the device the token belongs to (revoking the token hash) and severs
// any live connection. This is the relay side of the tray's "Sign out". The
// agent clears its local relay.env after this succeeds. Idempotent from the
// caller's view: a token that no longer maps to a device just 401s.
func (h *Handler) handleAgentDeenroll(w http.ResponseWriter, r *http.Request) {
	dev, err := h.auth.AuthenticateDevice(r, h.store)
	if err != nil {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	// Reuse the owner-scoped delete (the device's own owner always matches).
	deleted, err := h.store.DeleteDevice(dev.ID, dev.OwnerEmail)
	if err != nil {
		h.logger.Error("self de-enroll failed", "device", dev.ID, "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	if deleted {
		// Credential revoked (hash gone) — now sever anything still live.
		h.dir.KickDevice(dev.ID)
		h.logger.Info("device self de-enrolled", "device", dev.ID, "owner", dev.OwnerEmail)
	}
	w.WriteHeader(http.StatusNoContent)
}

// --- Client endpoints ------------------------------------------------------

// deviceView is the client-facing JSON shape of one device, shared by the
// list and rename endpoints. Hostname is the OS-reported machine hostname
// (distinct from the display Name; omitted when unknown).
type deviceView struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Hostname  string    `json:"hostname,omitempty"`
	Online    bool      `json:"online"`
	CreatedAt time.Time `json:"created_at"`
}

// viewOf renders a device with its live online status.
func (h *Handler) viewOf(d *Device) deviceView {
	return deviceView{
		ID:        d.ID,
		Name:      d.Name,
		Hostname:  d.Hostname,
		Online:    h.dir.IsOnline(d.ID),
		CreatedAt: d.CreatedAt,
	}
}

// handleListDevices: GET /v1/client/devices (JSON).
// Returns the authenticated caller's devices with live online status.
func (h *Handler) handleListDevices(w http.ResponseWriter, r *http.Request) {
	ident, err := h.auth.AuthenticateClient(r.Context(), r)
	if err != nil {
		h.writeAuthErr(w, err) // 401, or 429 when rate limited (ratelimit.go)
		return
	}
	// Ownership is keyed on the caller's stable google_sub, with a legacy
	// email fallback for devices enrolled before sub existed (store.go).
	devices := h.store.ListByOwnerIdent(ident)
	out := make([]deviceView, 0, len(devices))
	for _, d := range devices {
		out = append(out, h.viewOf(d))
	}

	writeJSON(w, http.StatusOK, map[string]any{"devices": out})
}

// handleEnrollDevice: POST /v1/client/devices (JSON).
// Enrolls a new device owned by the caller and returns the raw device token
// ONCE. The relay only ever stores the token's hash.
func (h *Handler) handleEnrollDevice(w http.ResponseWriter, r *http.Request) {
	ident, err := h.auth.AuthenticateClient(r.Context(), r)
	if err != nil {
		h.writeAuthErr(w, err) // 401, or 429 when rate limited (ratelimit.go)
		return
	}
	email := ident.Email

	var body struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body); err != nil || body.Name == "" {
		http.Error(w, "invalid body: expected {\"name\":\"...\"}", http.StatusBadRequest)
		return
	}

	// M4: quota-aware create — the caller's device quota is enforced inside
	// the create transaction (quotas.go).
	dev, rawToken, err := h.createDeviceQuota(ident, body.Name)
	if err != nil {
		if h.writeQuotaExceeded(w, err) { // 409 + {"error","limit"}
			return
		}
		h.logger.Error("enroll failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	h.logger.Info("device enrolled", "device", dev.ID, "owner", email, "name", dev.Name)

	// The raw token is returned exactly once and is never recoverable.
	writeJSON(w, http.StatusCreated, map[string]any{
		"id":    dev.ID,
		"name":  dev.Name,
		"token": rawToken,
	})
}

// handleRenameDevice: PATCH /v1/client/devices/{id} (JSON).
// Renames a device owned by the caller. The ownership check happens inside the
// store under its lock, so it cannot race with a concurrent delete.
func (h *Handler) handleRenameDevice(w http.ResponseWriter, r *http.Request) {
	ident, err := h.auth.AuthenticateClient(r.Context(), r)
	if err != nil {
		h.writeAuthErr(w, err) // 401, or 429 when rate limited (ratelimit.go)
		return
	}
	email := ident.Email

	id := r.PathValue("id")

	var body struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body); err != nil || body.Name == "" {
		http.Error(w, "invalid body: expected {\"name\":\"...\"}", http.StatusBadRequest)
		return
	}

	dev, err := h.store.RenameDeviceByOwner(id, ident, body.Name)
	if err != nil {
		h.logger.Error("rename failed", "device", id, "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	if dev == nil {
		// Do not distinguish "not found" from "not yours": both are 404 so
		// device IDs of other owners are not enumerable.
		http.Error(w, "device not found", http.StatusNotFound)
		return
	}

	h.logger.Info("device renamed", "device", dev.ID, "owner", email, "name", dev.Name)

	writeJSON(w, http.StatusOK, h.viewOf(dev))
}

// handleDeleteDevice: DELETE /v1/client/devices/{id}.
// Removes a device owned by the caller AND revokes its credential: the token
// hash is deleted from the store (so the token can never authenticate again)
// and any live connections the device holds through the relay — control and
// bridged data — are closed immediately.
func (h *Handler) handleDeleteDevice(w http.ResponseWriter, r *http.Request) {
	ident, err := h.auth.AuthenticateClient(r.Context(), r)
	if err != nil {
		h.writeAuthErr(w, err) // 401, or 429 when rate limited (ratelimit.go)
		return
	}
	email := ident.Email

	id := r.PathValue("id")

	deleted, err := h.store.DeleteDeviceByOwner(id, ident)
	if err != nil {
		h.logger.Error("delete failed", "device", id, "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	if !deleted {
		// Same non-enumerable 404 as everywhere else.
		http.Error(w, "device not found", http.StatusNotFound)
		return
	}

	// Credential is revoked (hash gone) — now sever anything still live.
	h.dir.KickDevice(id)

	h.logger.Info("device deleted", "device", id, "owner", email)
	w.WriteHeader(http.StatusNoContent)
}

// handleClientConnect: GET /v1/client/connect?device=<id> (WebSocket).
// Verifies ownership + online status, allocates a session, asks the agent to
// dial back, waits for the data conn, then bridges the two streams.
func (h *Handler) handleClientConnect(w http.ResponseWriter, r *http.Request) {
	ident, err := h.auth.AuthenticateClient(r.Context(), r)
	if err != nil {
		h.writeAuthErr(w, err) // 401, or 429 when rate limited (ratelimit.go)
		return
	}
	email := ident.Email

	// M4: per-identity connect rate limit (429 + Retry-After).
	if h.limitConnect(w, ident) {
		return
	}

	deviceID := r.URL.Query().Get("device")
	if deviceID == "" {
		http.Error(w, "missing device", http.StatusBadRequest)
		return
	}

	dev := h.store.Get(deviceID)
	if dev == nil || !dev.OwnedBy(ident) {
		// Do not distinguish "not found" from "not yours": both are 404 to the
		// caller so device IDs of other owners are not enumerable. Ownership is
		// sub-keyed with a legacy email fallback (store.go OwnedBy).
		http.Error(w, "device not found", http.StatusNotFound)
		return
	}
	if !h.dir.IsOnline(deviceID) {
		http.Error(w, "device offline", http.StatusConflict)
		return
	}

	// M4: concurrent-session quota, checked pre-upgrade for a clean HTTP 409
	// body; newOwnedSession re-enforces it atomically after the upgrade.
	if h.writeSessionQuotaExceeded(w, ident) {
		return
	}

	// All authz checks passed; upgrade to WebSocket.
	c, err := websocket.Accept(w, r, acceptOptions)
	if err != nil {
		return
	}
	defer c.CloseNow()

	ps, ok := h.newOwnedSession(c, deviceID, ident)
	if !ok {
		return
	}
	// Always release the agent data handler (which blocks on ps.done) and drop
	// the pending entry, no matter which path we exit through.
	defer h.dir.RemovePending(ps.id)
	defer close(ps.done)

	if err := h.dir.SendOpen(deviceID, ps.id); err != nil {
		c.Close(websocket.StatusGoingAway, "device offline")
		return
	}

	h.logger.Info("client connecting", "device", deviceID, "session", ps.id, "owner", email)

	select {
	case agentConn := <-ps.dataCh:
		// Both ends present: bridge them. This blocks until either side ends.
		// ps.done is closed by the deferred close above when we return, which
		// releases the waiting agent data handler.
		bridge(c, agentConn)
		h.logger.Info("bridge ended", "session", ps.id)
	case <-time.After(sessionSetupTimeout):
		c.Close(websocket.StatusPolicyViolation, "agent did not connect in time")
		h.logger.Warn("session setup timed out", "device", deviceID, "session", ps.id)
		// Drain a late-arriving data conn so it is not leaked.
		select {
		case late := <-ps.dataCh:
			late.Close(websocket.StatusGoingAway, "session timed out")
		default:
		}
	}
}

// --- Self-enroll endpoints (WP-B3) -----------------------------------------

// handleEnrollStart: POST /v1/enroll/start (JSON, UNAUTHENTICATED).
// Body {"name":"<machine name>", "flow":"device"|"web", "invite_code":"..."}
// (flow defaults to "device" for back-compat; invite_code is optional).
//
//   - device: starts a Google device-code sign-in and returns
//     {verification_url, user_code, device_code_handle, interval, expires_in}.
//     The handle is an opaque relay-side stand-in for Google's device_code,
//     which never leaves the relay (see enroll.go for why).
//   - web: returns {enroll_url, device_code_handle, interval, expires_in};
//     the owner opens enroll_url in a browser and the agent polls the same
//     /v1/enroll/poll. 503 when no Web OAuth client is configured — the
//     agent falls back to the device flow.
//
// invite_code (when INVITE_SIGNUP is ON) is parked on the enrollment and
// consumed at the success path to create a brand-new account. A returning
// owner never needs it (existing-account/legacy-owner paths authorize without
// a code), so the headless device flow keeps working unchanged for them.
func (h *Handler) handleEnrollStart(w http.ResponseWriter, r *http.Request) {
	// M4: per-IP rate limit — this endpoint is unauthenticated and mints
	// upstream traffic + relay state, making it the most abusable one.
	if h.limitEnrollStart(w, r) {
		return
	}

	var body struct {
		Name       string `json:"name"`
		Flow       string `json:"flow"`
		InviteCode string `json:"invite_code"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body); err != nil {
		http.Error(w, "invalid body: expected {\"name\":\"...\"}", http.StatusBadRequest)
		return
	}
	name := strings.TrimSpace(body.Name)
	if name == "" || len(name) > maxEnrollNameLen {
		http.Error(w, "invalid body: expected {\"name\":\"...\"}", http.StatusBadRequest)
		return
	}
	inviteCode := strings.TrimSpace(body.InviteCode)

	switch body.Flow {
	case "", flowDevice:
		resp, err := h.enroll.Start(r.Context(), name, inviteCode)
		switch {
		case errors.Is(err, errEnrollUnavailable):
			http.Error(w, "enrollment unavailable: relay has no OIDC device flow configured", http.StatusServiceUnavailable)
			return
		case errors.Is(err, errEnrollBusy):
			http.Error(w, "too many pending enrollments, retry later", http.StatusTooManyRequests)
			return
		case err != nil:
			h.logger.Warn("enroll start failed", "err", err)
			http.Error(w, "upstream error", http.StatusBadGateway)
			return
		}
		writeJSON(w, http.StatusOK, resp)
	case flowWeb:
		resp, err := h.enroll.StartWeb(name, inviteCode, h.relayBase(r))
		switch {
		case errors.Is(err, errEnrollUnavailable):
			http.Error(w, "web enrollment unavailable: relay has no web OAuth client configured", http.StatusServiceUnavailable)
			return
		case errors.Is(err, errEnrollBusy):
			http.Error(w, "too many pending enrollments, retry later", http.StatusTooManyRequests)
			return
		case err != nil:
			h.logger.Warn("web enroll start failed", "err", err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		writeJSON(w, http.StatusOK, resp)
	default:
		http.Error(w, "invalid flow: expected \"device\" or \"web\"", http.StatusBadRequest)
	}
}

// handleEnrollWeb: GET /enroll/{nonce} (BROWSER, UNAUTHENTICATED).
// The human-friendly single-use entry point printed/opened by the agent:
// consumes the nonce and 302s to Google's auth endpoint with the Web client
// and a fresh state bound to the pending enrollment.
func (h *Handler) handleEnrollWeb(w http.ResponseWriter, r *http.Request) {
	loc, err := h.enroll.AuthRedirectURL(r.PathValue("nonce"), h.relayBase(r))
	switch {
	case errors.Is(err, errEnrollUnavailable):
		writeEnrollPage(w, http.StatusServiceUnavailable, false, "Enrollment unavailable",
			"This relay has no browser sign-in configured.")
		return
	case errors.Is(err, errWebNonceUnknown):
		writeEnrollPage(w, http.StatusNotFound, false, "Link invalid or expired",
			"This enrollment link has already been used or has expired. "+
				"Run the enrollment on the machine again to get a fresh link.")
		return
	case err != nil:
		h.logger.Warn("web enroll redirect failed", "err", err)
		writeEnrollPage(w, http.StatusInternalServerError, false, "Something went wrong",
			"Run the enrollment on the machine again.")
		return
	}
	http.Redirect(w, r, loc, http.StatusFound)
}

// handleEnrollCallback: GET /enroll/callback?code&state (BROWSER,
// UNAUTHENTICATED — this is the Web client's registered redirect URI).
// Binds state back to the pending enrollment, exchanges the code, verifies
// the identity, upserts the device, and tells the human what happened. The
// agent's poll picks up the outcome.
func (h *Handler) handleEnrollCallback(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	state := q.Get("state")

	// The owner clicked "cancel" on Google's page: Google sends error=... back.
	if gerr := q.Get("error"); gerr != "" && state != "" {
		if err := h.enroll.DenyByState(state); err == nil {
			writeEnrollPage(w, http.StatusForbidden, false, "Sign-in cancelled",
				"The machine was NOT added to your account. You can close this tab.")
			return
		}
		writeEnrollPage(w, http.StatusBadRequest, false, "Link invalid or expired",
			"Run the enrollment on the machine again to get a fresh link.")
		return
	}

	code := q.Get("code")
	if code == "" || state == "" {
		writeEnrollPage(w, http.StatusBadRequest, false, "Malformed callback",
			"Missing code or state. Run the enrollment on the machine again.")
		return
	}

	name, err := h.enroll.Callback(r.Context(), code, state, clientIP(r))
	switch {
	case errors.Is(err, errWebStateUnknown):
		writeEnrollPage(w, http.StatusBadRequest, false, "Link invalid or expired",
			"This sign-in doesn't match a pending enrollment (already completed, "+
				"or it expired). Run the enrollment on the machine again.")
	case errors.Is(err, errWebRejected):
		writeEnrollPage(w, http.StatusForbidden, false, "Account not allowed",
			"The Google sign-in worked, but that account is not allowed on this relay. "+
				"The machine was NOT added.")
	case errors.Is(err, errWebExchange):
		writeEnrollPage(w, http.StatusBadGateway, false, "Sign-in could not be completed",
			"The code exchange with Google failed. Run the enrollment on the machine again.")
	case errors.Is(err, errWebQuota):
		// M4: device quota — same 409 the API paths use for quota refusals.
		writeEnrollPage(w, http.StatusConflict, false, "Device limit reached",
			"Your account already has its maximum number of machines. "+
				"Remove one, then run the enrollment again.")
	case err != nil:
		writeEnrollPage(w, http.StatusInternalServerError, false, "Something went wrong",
			"Run the enrollment on the machine again.")
	default:
		writeEnrollPage(w, http.StatusOK, true, name+" added to your account",
			"You can close this tab — the machine finishes enrolling on its own "+
				"within a few seconds.")
	}
}

// handleEnrollPoll: POST /v1/enroll/poll (JSON, UNAUTHENTICATED, rate-limited
// per handle). Body {"device_code_handle":"..."}. Pending -> 200
// {"status":"pending"}; early poll -> 429 {"status":"slow_down"}; approval by
// an allowlisted identity -> 200 {"status":"complete", device_id,
// device_token, relay_base} exactly once; denied/expired/rejected are
// terminal.
func (h *Handler) handleEnrollPoll(w http.ResponseWriter, r *http.Request) {
	// M4: per-IP backstop behind the per-handle interval throttle below —
	// that throttle is per enrollment, so handle-rotating callers need this.
	if h.limitEnrollPoll(w, r) {
		return
	}

	var body struct {
		Handle string `json:"device_code_handle"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body); err != nil || body.Handle == "" {
		http.Error(w, "invalid body: expected {\"device_code_handle\":\"...\"}", http.StatusBadRequest)
		return
	}

	out := h.enroll.Poll(r.Context(), body.Handle, h.relayBase(r), clientIP(r))
	writeJSON(w, out.status, out.body)
}

// relayBase is the public base URL handed to freshly enrolled agents:
// RELAY_BASE_URL when configured, else derived from the request Host (correct
// behind Caddy, which preserves Host and always terminates https).
func (h *Handler) relayBase(r *http.Request) string {
	if h.cfg.RelayBaseURL != "" {
		return h.cfg.RelayBaseURL
	}
	return "https://" + r.Host
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// writeEnrollPage renders the tiny self-contained HTML page the web-enroll
// browser leg ends on (success or terse failure). No external assets.
func writeEnrollPage(w http.ResponseWriter, status int, ok bool, title, detail string) {
	mark, color := "✕", "#c0392b"
	if ok {
		mark, color = "✓", "#27ae60"
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	_, _ = fmt.Fprintf(w, `<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Ghoztty enrollment</title>
<style>
body{font:16px/1.5 -apple-system,system-ui,sans-serif;display:flex;min-height:100vh;margin:0;
     align-items:center;justify-content:center;background:#f6f7f8;color:#1c1e21}
main{max-width:26rem;padding:2rem;text-align:center}
.mark{font-size:3rem;color:%s}
h1{font-size:1.25rem;margin:.5rem 0}
p{color:#555;margin:0}
</style></head><body><main>
<div class="mark">%s</div>
<h1>%s</h1>
<p>%s</p>
</main></body></html>
`, color, mark, html.EscapeString(title), html.EscapeString(detail))
}
