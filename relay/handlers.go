package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
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
	logger *slog.Logger
}

// NewHandler constructs a Handler.
func NewHandler(cfg *Config, auth *Authenticator, store *Store, dir *Directory, logger *slog.Logger) *Handler {
	return &Handler{cfg: cfg, auth: auth, store: store, dir: dir, logger: logger}
}

// Register attaches all routes to mux. Method+path patterns require Go 1.22+.
func (h *Handler) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/agent/control", h.handleAgentControl)
	mux.HandleFunc("GET /v1/agent/data", h.handleAgentData)
	mux.HandleFunc("GET /v1/client/devices", h.handleListDevices)
	mux.HandleFunc("POST /v1/client/devices", h.handleEnrollDevice)
	mux.HandleFunc("PATCH /v1/client/devices/{id}", h.handleRenameDevice)
	mux.HandleFunc("DELETE /v1/client/devices/{id}", h.handleDeleteDevice)
	mux.HandleFunc("GET /v1/client/connect", h.handleClientConnect)
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

// handleAgentControl: GET /v1/agent/control (WebSocket).
// Authenticates the device token, registers the device online, then holds the
// connection open with a ping/pong heartbeat. Disconnect -> device offline.
func (h *Handler) handleAgentControl(w http.ResponseWriter, r *http.Request) {
	dev, err := h.auth.AuthenticateDevice(r, h.store)
	if err != nil {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
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

// --- Client endpoints ------------------------------------------------------

// handleListDevices: GET /v1/client/devices (JSON).
// Returns the authenticated caller's devices with live online status.
func (h *Handler) handleListDevices(w http.ResponseWriter, r *http.Request) {
	email, err := h.auth.AuthenticateClient(r.Context(), r)
	if err != nil {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	type deviceView struct {
		ID        string    `json:"id"`
		Name      string    `json:"name"`
		Online    bool      `json:"online"`
		CreatedAt time.Time `json:"created_at"`
	}

	devices := h.store.ListByOwner(email)
	out := make([]deviceView, 0, len(devices))
	for _, d := range devices {
		out = append(out, deviceView{
			ID:        d.ID,
			Name:      d.Name,
			Online:    h.dir.IsOnline(d.ID),
			CreatedAt: d.CreatedAt,
		})
	}

	writeJSON(w, http.StatusOK, map[string]any{"devices": out})
}

// handleEnrollDevice: POST /v1/client/devices (JSON).
// Enrolls a new device owned by the caller and returns the raw device token
// ONCE. The relay only ever stores the token's hash.
func (h *Handler) handleEnrollDevice(w http.ResponseWriter, r *http.Request) {
	email, err := h.auth.AuthenticateClient(r.Context(), r)
	if err != nil {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	var body struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body); err != nil || body.Name == "" {
		http.Error(w, "invalid body: expected {\"name\":\"...\"}", http.StatusBadRequest)
		return
	}

	dev, rawToken, err := h.store.CreateDevice(email, body.Name)
	if err != nil {
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
	email, err := h.auth.AuthenticateClient(r.Context(), r)
	if err != nil {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	id := r.PathValue("id")

	var body struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body); err != nil || body.Name == "" {
		http.Error(w, "invalid body: expected {\"name\":\"...\"}", http.StatusBadRequest)
		return
	}

	dev, err := h.store.RenameDevice(id, email, body.Name)
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

	writeJSON(w, http.StatusOK, map[string]any{
		"id":         dev.ID,
		"name":       dev.Name,
		"online":     h.dir.IsOnline(dev.ID),
		"created_at": dev.CreatedAt,
	})
}

// handleDeleteDevice: DELETE /v1/client/devices/{id}.
// Removes a device owned by the caller AND revokes its credential: the token
// hash is deleted from the store (so the token can never authenticate again)
// and any live connections the device holds through the relay — control and
// bridged data — are closed immediately.
func (h *Handler) handleDeleteDevice(w http.ResponseWriter, r *http.Request) {
	email, err := h.auth.AuthenticateClient(r.Context(), r)
	if err != nil {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	id := r.PathValue("id")

	deleted, err := h.store.DeleteDevice(id, email)
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
	email, err := h.auth.AuthenticateClient(r.Context(), r)
	if err != nil {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	deviceID := r.URL.Query().Get("device")
	if deviceID == "" {
		http.Error(w, "missing device", http.StatusBadRequest)
		return
	}

	dev := h.store.Get(deviceID)
	if dev == nil || dev.OwnerEmail != email {
		// Do not distinguish "not found" from "not yours": both are 404 to the
		// caller so device IDs of other owners are not enumerable.
		http.Error(w, "device not found", http.StatusNotFound)
		return
	}
	if !h.dir.IsOnline(deviceID) {
		http.Error(w, "device offline", http.StatusConflict)
		return
	}

	// All authz checks passed; upgrade to WebSocket.
	c, err := websocket.Accept(w, r, acceptOptions)
	if err != nil {
		return
	}
	defer c.CloseNow()

	ps, err := h.dir.CreatePending(deviceID)
	if err != nil {
		c.Close(websocket.StatusTryAgainLater, "relay busy")
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

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
