package main

// quotas.go — M4 per-account resource quotas (plan §5 M4).
//
// Two persistent limits, enforced at every path that grows the resource:
//
//   - MAX DEVICES per account: enforced inside the device-creating store
//     transactions (CreateDeviceLimited for the manual client POST,
//     UpsertDeviceLimited for both self-enroll flows). An upsert that matches
//     an EXISTING device is credential ROTATION, not growth — it is never
//     quota-checked, so re-running the installer (the lost-token recovery
//     path) keeps working at the limit.
//   - MAX CONCURRENT SESSIONS per account: enforced against the live
//     Directory at client connect. A "session" is one admitted client connect
//     (a pendingSession) from its creation until the client handler returns —
//     i.e. it covers both the setup window and the active bridge, because
//     handleClientConnect only removes the entry (deferred RemovePending)
//     when bridging ends or times out.
//
// Limit resolution: env defaults (QUOTA_MAX_DEVICES / QUOTA_MAX_SESSIONS,
// 0 = unlimited) overridable per account via nullable columns on `accounts`
// (migration 0004; NULL = default, 0 = unlimited for that account). Quota
// keying follows the ownership rule everywhere else (store.go ownsClause):
// the caller's sub, with a lowercased-email fallback for legacy identities.
// An identity with NO account row (legacy owners, dev auth, INVITE_SIGNUP
// off) simply gets the defaults — enforcement is about resource abuse, not
// signup policy, so it works identically in both flag states.
//
// Fail-open stance: an errored OVERRIDE lookup logs and falls back to the
// defaults — a DB hiccup must not lock a legitimate user out; denial happens
// only on a positively-observed over-limit. The device COUNT, by contrast,
// runs inside the same write transaction as the insert; an error there is a
// write failure and surfaces as one (500), exactly as an insert error always
// has.
//
// Quota exceeded -> HTTP 409 Conflict with {"error":"<res> quota exceeded",
// "limit":N}. 409 over 403 deliberately: the caller is fully authorized, the
// request merely conflicts with current resource state, and the SAME request
// succeeds after freeing a resource — matching the existing "device offline"
// 409 on connect.

import (
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"
)

// QuotaExceededError is the typed over-limit refusal, carrying which resource
// and the effective limit for the client error body.
type QuotaExceededError struct {
	Resource string // "device" | "session"
	Limit    int
}

func (e *QuotaExceededError) Error() string { return e.Resource + " quota exceeded" }

// errWebQuota marks a web-enroll callback that failed on the device quota, so
// the browser page can say "device limit reached" rather than a generic error.
var errWebQuota = errors.New("device quota exceeded")

// Limits are the effective (post-override) limits for one caller. 0 means
// unlimited.
type Limits struct {
	MaxDevices  int
	MaxSessions int
}

// QuotaOverrides are one account's per-account limit overrides. A nil field
// means "use the configured default"; 0 means unlimited for this account.
type QuotaOverrides struct {
	MaxDevices  *int
	MaxSessions *int
}

// QuotaUsage is current consumption vs effective limits for one caller — the
// read model the M2 admin surface renders. Max* of 0 = unlimited.
type QuotaUsage struct {
	Devices     int
	MaxDevices  int
	Sessions    int
	MaxSessions int
}

// quotaKey is the per-identity key used for session counting and per-identity
// rate limiting: the stable sub when present, else the lowercased email
// (legacy identities) — the same precedence as ownsClause. Prefixed so a sub
// can never collide with an email string.
func quotaKey(ident Identity) string {
	if ident.Sub != "" {
		return "sub:" + ident.Sub
	}
	return "email:" + strings.ToLower(ident.Email)
}

// Quotas resolves effective limits and usage for callers. Handler owns one;
// the M2 admin API wraps LimitsFor/UsageFor plus the Store override seams.
type Quotas struct {
	cfg    *Config
	store  *Store
	dir    *Directory
	logger *slog.Logger
}

// NewQuotas builds the resolver.
func NewQuotas(cfg *Config, store *Store, dir *Directory, logger *slog.Logger) *Quotas {
	return &Quotas{cfg: cfg, store: store, dir: dir, logger: logger}
}

// LimitsFor returns the caller's effective limits (fail-open on lookup error).
func (q *Quotas) LimitsFor(ident Identity) Limits {
	return limitsFor(q.cfg, q.store, q.logger, ident)
}

// UsageFor returns current consumption vs effective limits (M2 admin seam).
func (q *Quotas) UsageFor(ident Identity) (QuotaUsage, error) {
	lim := q.LimitsFor(ident)
	devices, err := q.store.CountDevicesForOwner(ident)
	if err != nil {
		return QuotaUsage{}, err
	}
	return QuotaUsage{
		Devices:     devices,
		MaxDevices:  lim.MaxDevices,
		Sessions:    q.dir.SessionCountForOwner(quotaKey(ident)),
		MaxSessions: lim.MaxSessions,
	}, nil
}

// limitsFor is the standalone resolver (EnrollManager calls it directly with
// its own deps — it has no Directory and needs none for limits). Defaults come
// from config; a per-account override (when an account row exists) wins.
// Fail-open: an errored override read logs and returns the defaults.
func limitsFor(cfg *Config, store *Store, logger *slog.Logger, ident Identity) Limits {
	lim := Limits{MaxDevices: cfg.QuotaMaxDevices, MaxSessions: cfg.QuotaMaxSessions}
	o, err := store.GetQuotaOverrides(ident)
	if err != nil {
		logger.Error("quota override lookup failed; using defaults", "err", err)
		return lim
	}
	if o != nil {
		if o.MaxDevices != nil {
			lim.MaxDevices = *o.MaxDevices
		}
		if o.MaxSessions != nil {
			lim.MaxSessions = *o.MaxSessions
		}
	}
	return lim
}

// --- Store: overrides + quota-aware device writes ----------------------------

// GetQuotaOverrides returns the caller's account overrides, or nil when the
// caller has no account row (legacy identity / flag OFF) — the caller then
// uses the configured defaults. Resolution mirrors ownsClause precedence:
// sub-keyed account first, email fallback second.
func (s *Store) GetQuotaOverrides(ident Identity) (*QuotaOverrides, error) {
	sub, email := ownsArgs(ident)
	if sub != "" {
		o, err := scanQuotaOverrides(s.db.QueryRow(
			`SELECT max_devices, max_sessions FROM accounts WHERE google_sub = ?`, sub,
		))
		if err != nil || o != nil {
			return o, err
		}
	}
	if email == "" {
		return nil, nil
	}
	return scanQuotaOverrides(s.db.QueryRow(
		`SELECT max_devices, max_sessions FROM accounts WHERE email = ? LIMIT 1`, email,
	))
}

// scanQuotaOverrides reads one overrides row; sql.ErrNoRows maps to (nil, nil).
func scanQuotaOverrides(sc interface{ Scan(...any) error }) (*QuotaOverrides, error) {
	var md, ms sql.NullInt64
	if err := sc.Scan(&md, &ms); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	var o QuotaOverrides
	if md.Valid {
		v := int(md.Int64)
		o.MaxDevices = &v
	}
	if ms.Valid {
		v := int(ms.Int64)
		o.MaxSessions = &v
	}
	return &o, nil
}

// SetQuotaOverrides writes an account's limit overrides (M2 admin seam). A
// nil field clears the override back to the configured default (NULL). Errors
// when no such account exists.
func (s *Store) SetQuotaOverrides(accountID string, o QuotaOverrides) error {
	var md, ms any
	if o.MaxDevices != nil {
		md = *o.MaxDevices
	}
	if o.MaxSessions != nil {
		ms = *o.MaxSessions
	}
	res, err := s.db.Exec(
		`UPDATE accounts SET max_devices = ?, max_sessions = ? WHERE id = ?`,
		md, ms, accountID,
	)
	if err != nil {
		return fmt.Errorf("persist quota overrides: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("persist quota overrides: %w", err)
	}
	if n == 0 {
		return fmt.Errorf("set quota overrides: no account %s", accountID)
	}
	return nil
}

// CountDevicesForOwner counts the caller's devices under the standard
// ownership rule (sub-keyed, legacy email fallback).
func (s *Store) CountDevicesForOwner(ident Identity) (int, error) {
	sub, email := ownsArgs(ident)
	var n int
	err := s.db.QueryRow(
		`SELECT COUNT(*) FROM devices WHERE `+ownsClause, sub, email,
	).Scan(&n)
	return n, err
}

// countDevicesTx is CountDevicesForOwner inside a transaction, for the
// check-then-insert quota enforcement.
func countDevicesTx(tx *sql.Tx, ownerSub, ownerEmail string) (int, error) {
	sub, email := ownsArgs(Identity{Email: ownerEmail, Sub: ownerSub})
	var n int
	err := tx.QueryRow(
		`SELECT COUNT(*) FROM devices WHERE `+ownsClause, sub, email,
	).Scan(&n)
	return n, err
}

// CreateDeviceLimited is CreateDevice with the device quota enforced in the
// same transaction as the insert (no check-then-act window against a
// concurrent create). maxDevices 0 = unlimited (plain CreateDevice).
func (s *Store) CreateDeviceLimited(ownerEmail, ownerSub, name string, maxDevices int) (*Device, string, error) {
	if maxDevices <= 0 {
		return s.CreateDevice(ownerEmail, ownerSub, name)
	}

	rawToken, hash, err := newDeviceToken()
	if err != nil {
		return nil, "", err
	}
	dev := &Device{
		ID:         uuid.NewString(),
		Name:       name,
		OwnerEmail: strings.ToLower(ownerEmail),
		OwnerSub:   ownerSub,
		TokenHash:  hash,
		CreatedAt:  time.Now().UTC(),
	}

	tx, err := s.db.Begin()
	if err != nil {
		return nil, "", err
	}
	defer tx.Rollback()

	n, err := countDevicesTx(tx, ownerSub, dev.OwnerEmail)
	if err != nil {
		return nil, "", fmt.Errorf("count devices for quota: %w", err)
	}
	if n >= maxDevices {
		return nil, "", &QuotaExceededError{Resource: "device", Limit: maxDevices}
	}

	if _, err := tx.Exec(
		`INSERT INTO devices (`+deviceCols+`) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		dev.ID, dev.Name, dev.Hostname, dev.OwnerEmail, dev.OwnerSub, dev.TokenHash, dev.CreatedAt,
	); err != nil {
		return nil, "", fmt.Errorf("persist device: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, "", fmt.Errorf("persist device: %w", err)
	}
	return dev, rawToken, nil
}

// UpsertDeviceLimited is the quota-aware self-enroll primitive; UpsertDevice
// (store.go) delegates here with maxDevices 0 and keeps its full contract
// documentation. The quota check applies ONLY on the create branch — matching
// an existing (owner, name) row is credential rotation, which changes the
// device population by nothing and must keep working at the limit (it is the
// lost-token recovery path). Check and insert share the transaction, so two
// concurrent enrolls cannot both squeeze under the cap.
func (s *Store) UpsertDeviceLimited(ownerEmail, ownerSub, name string, maxDevices int) (*Device, string, error) {
	rawToken, hash, err := newDeviceToken()
	if err != nil {
		return nil, "", err
	}
	ownerEmail = strings.ToLower(ownerEmail)

	tx, err := s.db.Begin()
	if err != nil {
		return nil, "", err
	}
	defer tx.Rollback()

	// Oldest (owner, name) row wins deterministically; ties broken by id.
	existing, err := scanDevice(tx.QueryRow(
		`SELECT `+deviceCols+` FROM devices
		 WHERE owner_email = ? AND name = ?
		 ORDER BY created_at ASC, id ASC
		 LIMIT 1`,
		ownerEmail, name,
	))
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, "", fmt.Errorf("lookup upsert target: %w", err)
	}

	if existing != nil {
		// Rotation: same device identity, fresh credential. Never quota-checked.
		existing.TokenHash = hash
		if ownerSub != "" {
			existing.OwnerSub = ownerSub
		}
		if _, err := tx.Exec(
			`UPDATE devices SET token_hash = ?, owner_sub = ? WHERE id = ?`,
			existing.TokenHash, existing.OwnerSub, existing.ID,
		); err != nil {
			return nil, "", fmt.Errorf("persist upsert: %w", err)
		}
		if err := tx.Commit(); err != nil {
			return nil, "", fmt.Errorf("persist upsert: %w", err)
		}
		return existing, rawToken, nil
	}

	// Create branch: this grows the device population, so the quota applies.
	if maxDevices > 0 {
		n, err := countDevicesTx(tx, ownerSub, ownerEmail)
		if err != nil {
			return nil, "", fmt.Errorf("count devices for quota: %w", err)
		}
		if n >= maxDevices {
			return nil, "", &QuotaExceededError{Resource: "device", Limit: maxDevices}
		}
	}

	dev := &Device{
		ID:   uuid.NewString(),
		Name: name,
		// Device-code enrollment names the device after the machine's
		// hostname, so at creation the two coincide. They diverge when the
		// owner renames the device (rename never touches Hostname) and the
		// hostname is thereafter refreshed by the agent's control connects.
		Hostname:   name,
		OwnerEmail: ownerEmail,
		OwnerSub:   ownerSub,
		TokenHash:  hash,
		CreatedAt:  time.Now().UTC(),
	}
	if _, err := tx.Exec(
		`INSERT INTO devices (`+deviceCols+`) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		dev.ID, dev.Name, dev.Hostname, dev.OwnerEmail, dev.OwnerSub, dev.TokenHash, dev.CreatedAt,
	); err != nil {
		return nil, "", fmt.Errorf("persist device: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, "", fmt.Errorf("persist device: %w", err)
	}
	cp := *dev
	return &cp, rawToken, nil
}

// --- Directory: owner-scoped session admission -------------------------------

// SessionCountForOwner counts live sessions (pending + bridged) for an owner
// key. Linear over the sessions map, which is bounded by maxPendingSessions.
func (d *Directory) SessionCountForOwner(ownerKey string) int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.sessionCountLocked(ownerKey)
}

// sessionCountLocked counts ownerKey's sessions. Caller holds d.mu.
func (d *Directory) sessionCountLocked(ownerKey string) int {
	n := 0
	for _, ps := range d.sessions {
		if ps.ownerKey == ownerKey {
			n++
		}
	}
	return n
}

// CreatePendingOwned registers a new pending session attributed to ownerKey,
// enforcing the per-owner session quota atomically under the directory lock
// (the pre-upgrade check in handleClientConnect is advisory; this is the
// authoritative one). maxSessions 0 = unlimited; empty ownerKey is never
// quota-checked (back-compat CreatePending path).
func (d *Directory) CreatePendingOwned(deviceID, ownerKey string, maxSessions int) (*pendingSession, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if len(d.sessions) >= maxPendingSessions {
		return nil, ErrTooManyPending
	}
	if maxSessions > 0 && ownerKey != "" && d.sessionCountLocked(ownerKey) >= maxSessions {
		return nil, &QuotaExceededError{Resource: "session", Limit: maxSessions}
	}
	ps := &pendingSession{
		id:       uuid.NewString(),
		deviceID: deviceID,
		ownerKey: ownerKey,
		dataCh:   make(chan *websocket.Conn, 1),
		done:     make(chan struct{}),
	}
	d.sessions[ps.id] = ps
	return ps, nil
}

// --- Handler integration ------------------------------------------------------

// writeQuotaExceeded translates a quota refusal into the documented 409 JSON
// body. Returns false (nothing written) for any other error.
func (h *Handler) writeQuotaExceeded(w http.ResponseWriter, err error) bool {
	var qe *QuotaExceededError
	if !errors.As(err, &qe) {
		return false
	}
	h.logger.Warn("quota exceeded", "resource", qe.Resource, "limit", qe.Limit)
	writeJSON(w, http.StatusConflict, map[string]any{
		"error": qe.Error(),
		"limit": qe.Limit,
	})
	return true
}

// createDeviceQuota is the quota-aware device create behind POST
// /v1/client/devices: resolves the caller's effective limit and enforces it
// inside the create transaction.
func (h *Handler) createDeviceQuota(ident Identity, name string) (*Device, string, error) {
	lim := h.quotas.LimitsFor(ident)
	return h.store.CreateDeviceLimited(ident.Email, ident.Sub, name, lim.MaxDevices)
}

// writeSessionQuotaExceeded is the advisory PRE-upgrade session-quota check:
// it exists so an over-quota caller gets a clean HTTP 409 + JSON body instead
// of a mid-upgrade WebSocket close. Racy by nature (two connects can both
// pass); CreatePendingOwned re-enforces atomically after the upgrade.
func (h *Handler) writeSessionQuotaExceeded(w http.ResponseWriter, ident Identity) bool {
	lim := h.quotas.LimitsFor(ident)
	if lim.MaxSessions <= 0 {
		return false
	}
	if h.dir.SessionCountForOwner(quotaKey(ident)) < lim.MaxSessions {
		return false
	}
	h.logger.Warn("session quota exceeded", "limit", lim.MaxSessions)
	writeJSON(w, http.StatusConflict, map[string]any{
		"error": "session quota exceeded",
		"limit": lim.MaxSessions,
	})
	return true
}

// newOwnedSession creates the owner-attributed pending session after the
// WebSocket upgrade, closing the conn with the right reason on refusal
// (quota race vs relay-wide pending cap). Returns (nil, false) when refused.
func (h *Handler) newOwnedSession(c *websocket.Conn, deviceID string, ident Identity) (*pendingSession, bool) {
	lim := h.quotas.LimitsFor(ident)
	ps, err := h.dir.CreatePendingOwned(deviceID, quotaKey(ident), lim.MaxSessions)
	if err != nil {
		var qe *QuotaExceededError
		if errors.As(err, &qe) {
			c.Close(websocket.StatusTryAgainLater, "session quota exceeded")
		} else {
			c.Close(websocket.StatusTryAgainLater, "relay busy")
		}
		return nil, false
	}
	return ps, true
}

// --- Enroll integration -------------------------------------------------------

// upsertEnrolled is the quota-aware device upsert behind both self-enroll
// success paths (device-code poll + web callback).
func (m *EnrollManager) upsertEnrolled(ident Identity, name string) (*Device, string, error) {
	lim := limitsFor(m.cfg, m.store, m.logger, ident)
	return m.store.UpsertDeviceLimited(ident.Email, ident.Sub, name, lim.MaxDevices)
}

// enrollUpsertFailed maps an upsert failure onto the poll protocol: a quota
// refusal is a terse, terminal 409 naming the limit (existing terminal-error
// style); anything else stays the historical 500.
func (m *EnrollManager) enrollUpsertFailed(name string, err error) pollOutcome {
	var qe *QuotaExceededError
	if errors.As(err, &qe) {
		m.logger.Warn("enrollment refused: device quota exceeded", "name", name, "limit", qe.Limit)
		return pollOutcome{http.StatusConflict, map[string]any{
			"status": "error",
			"error":  qe.Error(),
			"limit":  qe.Limit,
		}}
	}
	m.logger.Error("enroll upsert failed", "err", err)
	return pollOutcome{http.StatusInternalServerError, map[string]any{
		"status": "error",
		"error":  "internal error",
	}}
}

// isQuotaExceeded reports whether err is a quota refusal.
func isQuotaExceeded(err error) bool {
	var qe *QuotaExceededError
	return errors.As(err, &qe)
}

// getenvInt parses an integer env var, returning def when unset or
// malformed — a typo in a limit must not silently disable it.
func getenvInt(key string, def int) int {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return def
	}
	return n
}
