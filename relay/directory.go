package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"
)

// maxPendingSessions bounds the number of in-flight session setups to limit
// memory/abuse. New connect requests are rejected past this.
const maxPendingSessions = 256

// controlWriteTimeout bounds how long a control-frame write may block.
const controlWriteTimeout = 10 * time.Second

var (
	// ErrDeviceOffline is returned when no live control connection exists.
	ErrDeviceOffline = errors.New("device offline")
	// ErrTooManyPending is returned when the pending-session bound is hit.
	ErrTooManyPending = errors.New("too many pending sessions")
)

// controlMsg is a JSON command the relay sends to an agent over its control WS.
type controlMsg struct {
	Type    string `json:"type"`
	Session string `json:"session,omitempty"`
}

// agentConn is a single registered, online agent and its control connection.
type agentConn struct {
	deviceID string
	conn     *websocket.Conn
	sendMu   sync.Mutex // serializes writes; a WS permits only one writer
}

// send marshals and writes a control command. Writes are serialized so
// concurrent open commands cannot interleave on the wire.
func (ac *agentConn) send(m controlMsg) error {
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	ac.sendMu.Lock()
	defer ac.sendMu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), controlWriteTimeout)
	defer cancel()
	return ac.conn.Write(ctx, websocket.MessageText, b)
}

// pendingSession tracks a client connect waiting for the agent to dial back.
type pendingSession struct {
	id       string
	deviceID string
	dataCh   chan *websocket.Conn // agent's data conn is delivered here (buffered 1)
	done     chan struct{}        // closed by the client handler when bridging ends
	// agentData is the claimed data conn (set under Directory.mu by ClaimData).
	// Kept so KickDevice can tear down a live bridge when the device is deleted.
	agentData *websocket.Conn
}

// Directory is the concurrency-safe in-memory registry of online agents and
// pending sessions. It holds no persistent state — it reflects live sockets.
type Directory struct {
	mu       sync.Mutex
	agents   map[string]*agentConn      // deviceID -> control connection
	sessions map[string]*pendingSession // sessionID -> pending session
	logger   *slog.Logger
}

// NewDirectory creates an empty directory.
func NewDirectory(logger *slog.Logger) *Directory {
	return &Directory{
		agents:   make(map[string]*agentConn),
		sessions: make(map[string]*pendingSession),
		logger:   logger,
	}
}

// RegisterAgent marks a device online with the given control conn. If the
// device already had a control connection, the old one is closed (the newest
// registration wins — a reconnecting agent supersedes a stale socket).
func (d *Directory) RegisterAgent(deviceID string, conn *websocket.Conn) *agentConn {
	d.mu.Lock()
	defer d.mu.Unlock()
	if old := d.agents[deviceID]; old != nil {
		old.conn.Close(websocket.StatusPolicyViolation, "replaced by new control connection")
	}
	ac := &agentConn{deviceID: deviceID, conn: conn}
	d.agents[deviceID] = ac
	d.logger.Info("agent online", "device", deviceID)
	return ac
}

// UnregisterAgent removes ac from the directory only if it is still the current
// registration for its device (so a superseded conn does not evict the new one).
func (d *Directory) UnregisterAgent(ac *agentConn) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.agents[ac.deviceID] == ac {
		delete(d.agents, ac.deviceID)
		d.logger.Info("agent offline", "device", ac.deviceID)
	}
}

// IsOnline reports whether the device currently has a control connection.
func (d *Directory) IsOnline(deviceID string) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.agents[deviceID] != nil
}

// CreatePending registers a new pending session for deviceID and returns it.
func (d *Directory) CreatePending(deviceID string) (*pendingSession, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if len(d.sessions) >= maxPendingSessions {
		return nil, ErrTooManyPending
	}
	ps := &pendingSession{
		id:       uuid.NewString(),
		deviceID: deviceID,
		dataCh:   make(chan *websocket.Conn, 1),
		done:     make(chan struct{}),
	}
	d.sessions[ps.id] = ps
	return ps, nil
}

// RemovePending deletes a pending session (called by the client handler when it
// finishes or times out).
func (d *Directory) RemovePending(id string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	delete(d.sessions, id)
}

// SendOpen tells the device's agent to dial back a data connection for session.
func (d *Directory) SendOpen(deviceID, sessionID string) error {
	d.mu.Lock()
	ac := d.agents[deviceID]
	d.mu.Unlock()
	if ac == nil {
		return ErrDeviceOffline
	}
	return ac.send(controlMsg{Type: "open", Session: sessionID})
}

// ClaimData matches an incoming agent data conn to a pending session and hands
// the conn to the waiting client handler. It verifies the session belongs to
// the authenticated device (so one device cannot hijack another's session).
// Returns the pending session and true on success; on any mismatch it returns
// false and the caller must close the conn.
func (d *Directory) ClaimData(sessionID, deviceID string, conn *websocket.Conn) (*pendingSession, bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	ps := d.sessions[sessionID]
	if ps == nil || ps.deviceID != deviceID {
		return nil, false
	}
	// dataCh is buffered(1); a non-blocking send succeeds unless a conn was
	// already delivered (duplicate dial) in which case we reject.
	select {
	case ps.dataCh <- conn:
		ps.agentData = conn
		return ps, true
	default:
		return nil, false
	}
}

// KickDevice forcibly disconnects a device: its control connection (if any) is
// closed and dropped from the registry, and any live or still-queued data
// connections for its sessions are closed (which ends their bridges and tears
// down the client side too). Called when a device is deleted so a revoked
// machine loses access immediately, not just on its next dial.
func (d *Directory) KickDevice(deviceID string) {
	d.mu.Lock()
	ac := d.agents[deviceID]
	delete(d.agents, deviceID)

	var conns []*websocket.Conn
	for _, ps := range d.sessions {
		if ps.deviceID != deviceID {
			continue
		}
		if ps.agentData != nil {
			conns = append(conns, ps.agentData)
		} else {
			// Delivered but not yet consumed by the client handler.
			select {
			case c := <-ps.dataCh:
				conns = append(conns, c)
			default:
			}
		}
	}
	d.mu.Unlock()

	if ac != nil {
		conns = append(conns, ac.conn)
		d.logger.Info("agent kicked (device deleted)", "device", deviceID)
	}

	// Close asynchronously: Close writes the close frame immediately but then
	// blocks for the peer's ack (up to its internal timeout). A device delete
	// must not stall on an unresponsive agent, so the handshake wait happens
	// off the request path. Close falls back to closing the socket on timeout.
	for _, c := range conns {
		go c.Close(websocket.StatusPolicyViolation, "device revoked")
	}
}
