package main

// M2 admin surface: the /v1/admin/ REST API and its authorization middleware
// (plan §5 M2). The admin API is a DISTINCT, separately authorized surface
// (plan §2): a normal user token is never sufficient, and an admin token is
// never sufficient for user endpoints — the two authorization models do not
// mix.
//
// Admin authorization shape (works identically with INVITE_SIGNUP on or off):
//
//  1. VERIFY the caller exactly as strictly as the user surface does —
//     the same OIDC checks (signature/issuer/aud/exp/email_verified/sub) via
//     Authenticator.VerifyIdentity, or the constant-time DEV_AUTH token
//     compare. Any failure -> 401. OIDC verification is never weakened.
//  2. AUTHORIZE by admin-ness only: sub ∈ ADMIN_SUBS (env bootstrap) OR the
//     account row for the sub has is_admin=1 (managed in DB). A verified
//     non-admin -> 403 (deliberately distinct from 401 so a mis-provisioned
//     admin can tell "bad token" from "not an admin").
//
// The user-authorization gates (ALLOWED_EMAILS when the flag is off, the
// invite-code account model when it is on) are NOT consulted: an admin need
// not be a user, and being a user grants nothing here. This keeps the admin
// surface flag-independent — the OIDC identity is the constant, the admin
// allowlist is the decision — and fail-closed: no ADMIN_SUBS and no is_admin
// rows means every admin request 403s.
//
// Every mutation writes an admin_audit row AFTER it succeeds. The write is
// best-effort (logged on failure, never fails the response): refusing to
// report a mutation that already happened would mislead the admin, and the
// slog line preserves a secondary trail.

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// adminHandlerFunc is an admin route handler; ident is the verified admin.
type adminHandlerFunc func(w http.ResponseWriter, r *http.Request, admin Identity)

// adminOnly wraps every admin route with the verify-then-authorize middleware
// described in the header comment. 401 = not (verifiably) anyone; 403 =
// verified, but not an admin.
func (h *Handler) adminOnly(next adminHandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ident, status := h.authenticateAdmin(r.Context(), r)
		switch status {
		case http.StatusUnauthorized:
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		case http.StatusForbidden:
			http.Error(w, "forbidden: admin access required", http.StatusForbidden)
			return
		}
		next(w, r, ident)
	}
}

// authenticateAdmin verifies the caller's identity (full OIDC strictness, or
// the dev token under DEV_AUTH) and checks admin-ness. Returns the identity
// and 0 on success, or a zero Identity and the HTTP status to reject with.
func (h *Handler) authenticateAdmin(ctx context.Context, r *http.Request) (Identity, int) {
	token := bearerToken(r)
	if token == "" {
		return Identity{}, http.StatusUnauthorized
	}

	var ident Identity
	if h.cfg.DevAuth && h.cfg.DevClientToken != "" &&
		subtle.ConstantTimeCompare([]byte(token), []byte(h.cfg.DevClientToken)) == 1 {
		// Dev stand-in, mirroring AuthenticateClient's dev path: the static
		// token maps to sub "dev" — an admin only if ADMIN_SUBS (or an
		// is_admin account for "dev") says so.
		ident = Identity{Email: strings.ToLower(h.cfg.DevEmail), Sub: "dev"}
	} else {
		var err error
		ident, err = h.auth.VerifyIdentity(ctx, token)
		if err != nil {
			return Identity{}, http.StatusUnauthorized
		}
	}

	if !h.isAdmin(ident) {
		h.logger.Warn("admin access refused: verified caller is not an admin",
			"sub", ident.Sub, "email", ident.Email)
		return Identity{}, http.StatusForbidden
	}
	return ident, 0
}

// isAdmin is the admin-ness decision: env bootstrap allowlist first (no DB
// needed — the recovery path must work even if the DB is wedged), then the
// managed-in-DB flag. A store error fails closed.
func (h *Handler) isAdmin(ident Identity) bool {
	if h.adminSubs[ident.Sub] {
		return true
	}
	ok, err := h.store.AccountIsAdmin(ident.Sub)
	if err != nil {
		h.logger.Error("admin flag lookup failed", "sub", ident.Sub, "err", err)
		return false // fail closed
	}
	return ok
}

// audit writes the admin_audit row for a completed mutation (best-effort; see
// the file header for why a failure never fails the response). detail is
// marshalled to a small JSON blob.
func (h *Handler) audit(admin Identity, action, target string, detail map[string]any) {
	blob := ""
	if len(detail) > 0 {
		b, err := json.Marshal(detail)
		if err == nil {
			blob = string(b)
		}
	}
	if err := h.store.RecordAdminAudit(admin.Sub, admin.Email, action, target, blob); err != nil {
		h.logger.Error("admin audit write failed", "action", action, "target", target, "err", err)
	}
	h.logger.Info("admin mutation", "action", action, "target", target, "admin_sub", admin.Sub)
}

// registerAdmin attaches the /v1/admin/ routes, each behind adminOnly.
func (h *Handler) registerAdmin(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/admin/signin-attempts", h.adminOnly(h.handleAdminSigninAttempts))
	mux.HandleFunc("GET /v1/admin/accounts", h.adminOnly(h.handleAdminListAccounts))
	mux.HandleFunc("POST /v1/admin/accounts/{id}/block", h.adminOnly(h.handleAdminBlockAccount))
	mux.HandleFunc("POST /v1/admin/accounts/{id}/unblock", h.adminOnly(h.handleAdminUnblockAccount))
	mux.HandleFunc("DELETE /v1/admin/accounts/{id}", h.adminOnly(h.handleAdminDeleteAccount))
	mux.HandleFunc("GET /v1/admin/accounts/{id}/usage", h.adminOnly(h.handleAdminAccountUsage))
	mux.HandleFunc("POST /v1/admin/invites", h.adminOnly(h.handleAdminCreateInvite))
	mux.HandleFunc("GET /v1/admin/invites", h.adminOnly(h.handleAdminListInvites))
	mux.HandleFunc("DELETE /v1/admin/invites/{code}", h.adminOnly(h.handleAdminRevokeInvite))
	mux.HandleFunc("GET /v1/admin/settings", h.adminOnly(h.handleAdminGetSettings))
	mux.HandleFunc("PUT /v1/admin/settings", h.adminOnly(h.handleAdminPutSettings))
	mux.HandleFunc("GET /v1/admin/allowlist", h.adminOnly(h.handleAdminListAllowlist))
	mux.HandleFunc("POST /v1/admin/allowlist", h.adminOnly(h.handleAdminAddAllowlist))
	mux.HandleFunc("DELETE /v1/admin/allowlist/{email}", h.adminOnly(h.handleAdminRemoveAllowlist))
}

// --- Views -------------------------------------------------------------------

// accountView is the admin-facing JSON shape of one account.
type accountView struct {
	ID            string     `json:"id"`
	GoogleSub     string     `json:"google_sub"`
	Email         string     `json:"email"`
	Status        string     `json:"status"`
	InvitedByCode string     `json:"invited_by_code,omitempty"`
	CreatedAt     time.Time  `json:"created_at"`
	BlockedAt     *time.Time `json:"blocked_at,omitempty"`
	BlockedReason string     `json:"blocked_reason,omitempty"`
	IsAdmin       bool       `json:"is_admin"`
	DeviceCount   int        `json:"device_count"`
}

// accountViewOf renders an account (deviceCount supplied by the caller — the
// list query computes it in SQL; single-account paths count via the store).
func accountViewOf(a *Account, deviceCount int) accountView {
	return accountView{
		ID:            a.ID,
		GoogleSub:     a.GoogleSub,
		Email:         a.Email,
		Status:        a.Status,
		InvitedByCode: a.InvitedByCode,
		CreatedAt:     a.CreatedAt,
		BlockedAt:     a.BlockedAt,
		BlockedReason: a.BlockedReason,
		IsAdmin:       a.IsAdmin,
		DeviceCount:   deviceCount,
	}
}

// --- Sign-in attempts ----------------------------------------------------------

// signinAttemptsDefaultLimit / MaxLimit bound the admin attempts feed.
const (
	signinAttemptsDefaultLimit = 100
	signinAttemptsMaxLimit     = 1000
)

// handleAdminSigninAttempts: GET /v1/admin/signin-attempts (JSON).
// Newest-first attempt feed. Query params: outcome (exact), email (exact,
// lowercased), since (RFC3339, inclusive), limit (default 100, cap 1000).
func (h *Handler) handleAdminSigninAttempts(w http.ResponseWriter, r *http.Request, _ Identity) {
	q := r.URL.Query()
	f := SigninAttemptFilter{
		Outcome: q.Get("outcome"),
		Email:   q.Get("email"),
		Limit:   signinAttemptsDefaultLimit,
	}
	if v := q.Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			http.Error(w, "invalid limit: expected a positive integer", http.StatusBadRequest)
			return
		}
		f.Limit = min(n, signinAttemptsMaxLimit)
	}
	if v := q.Get("since"); v != "" {
		t, err := time.Parse(time.RFC3339, v)
		if err != nil {
			http.Error(w, "invalid since: expected RFC3339 timestamp", http.StatusBadRequest)
			return
		}
		f.Since = t
	}

	attempts, err := h.store.ListSigninAttempts(f)
	if err != nil {
		h.logger.Error("admin list signin attempts failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	if attempts == nil {
		attempts = []SigninAttempt{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"attempts": attempts})
}

// --- Accounts -------------------------------------------------------------------

// handleAdminListAccounts: GET /v1/admin/accounts (JSON).
// Query params: q (case-insensitive substring on email), status (exact:
// active|blocked). Each row carries its device count.
func (h *Handler) handleAdminListAccounts(w http.ResponseWriter, r *http.Request, _ Identity) {
	status := r.URL.Query().Get("status")
	if status != "" && status != AccountActive && status != AccountBlocked {
		http.Error(w, "invalid status: expected active or blocked", http.StatusBadRequest)
		return
	}

	accounts, err := h.store.ListAccounts(r.URL.Query().Get("q"), status)
	if err != nil {
		h.logger.Error("admin list accounts failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	out := make([]accountView, 0, len(accounts))
	for i := range accounts {
		out = append(out, accountViewOf(&accounts[i].Account, accounts[i].DeviceCount))
	}
	writeJSON(w, http.StatusOK, map[string]any{"accounts": out})
}

// handleAdminBlockAccount: POST /v1/admin/accounts/{id}/block (JSON).
// Body {"reason":"..."} (reason optional but recommended). Sets
// status=blocked + blocked_at + blocked_reason; idempotent (re-block keeps
// the original blocked_at, refreshes the reason). The block bites at the next
// sign-in decision (M1 gate, flag ON); existing device tokens keep working —
// delete the account to revoke machines. An admin MAY block their own
// account: blocking only gates USER sign-in, admin-ness is a separate surface
// (ADMIN_SUBS / is_admin), so a self-blocked admin retains admin access and
// can undo it — there is no lock-yourself-out hazard, hence no special case.
func (h *Handler) handleAdminBlockAccount(w http.ResponseWriter, r *http.Request, admin Identity) {
	id := r.PathValue("id")

	var body struct {
		Reason string `json:"reason"`
	}
	// An empty body is tolerated (reason defaults to ""); malformed JSON is not.
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body); err != nil && !errors.Is(err, io.EOF) {
		http.Error(w, "invalid body: expected {\"reason\":\"...\"}", http.StatusBadRequest)
		return
	}

	acct, err := h.store.BlockAccount(id, body.Reason)
	if err != nil {
		h.logger.Error("admin block failed", "account", id, "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	if acct == nil {
		http.Error(w, "account not found", http.StatusNotFound)
		return
	}

	h.audit(admin, "account.block", id, map[string]any{"reason": body.Reason, "email": acct.Email})
	writeJSON(w, http.StatusOK, map[string]any{"account": accountViewOf(acct, h.deviceCountFor(acct))})
}

// handleAdminUnblockAccount: POST /v1/admin/accounts/{id}/unblock (no body).
// Clears the blocked state. Idempotent: unblocking an active account is a
// no-op 200.
func (h *Handler) handleAdminUnblockAccount(w http.ResponseWriter, r *http.Request, admin Identity) {
	id := r.PathValue("id")

	acct, err := h.store.UnblockAccount(id)
	if err != nil {
		h.logger.Error("admin unblock failed", "account", id, "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	if acct == nil {
		http.Error(w, "account not found", http.StatusNotFound)
		return
	}

	h.audit(admin, "account.unblock", id, map[string]any{"email": acct.Email})
	writeJSON(w, http.StatusOK, map[string]any{"account": accountViewOf(acct, h.deviceCountFor(acct))})
}

// handleAdminDeleteAccount: DELETE /v1/admin/accounts/{id} (JSON).
// Deletes the account AND every device it owns (sub-keyed with the legacy
// email fallback — same predicate the client API uses), which revokes the
// devices' token hashes; live connections are then severed. Returns whether
// anything was deleted (deleting a nonexistent account is a 200
// {"deleted":false} — the desired end state already holds).
func (h *Handler) handleAdminDeleteAccount(w http.ResponseWriter, r *http.Request, admin Identity) {
	id := r.PathValue("id")

	deleted, deviceIDs, err := h.store.DeleteAccount(id)
	if err != nil {
		h.logger.Error("admin delete account failed", "account", id, "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	if deleted {
		// Credentials are revoked (hashes gone) — now sever anything still live.
		for _, did := range deviceIDs {
			h.dir.KickDevice(did)
		}
		h.audit(admin, "account.delete", id, map[string]any{"devices_deleted": len(deviceIDs)})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"deleted":         deleted,
		"devices_deleted": len(deviceIDs),
	})
}

// handleAdminAccountUsage: GET /v1/admin/accounts/{id}/usage (JSON).
// Per-account usage summary from what exists TODAY: the account row, its
// devices (with live online status) and their count, and sign-in attempt
// counts by outcome. Richer usage (sessions/bytes/duration via a
// usage_events table) lands with M4/M5 — deliberately NOT created here.
func (h *Handler) handleAdminAccountUsage(w http.ResponseWriter, r *http.Request, _ Identity) {
	id := r.PathValue("id")

	acct, err := h.store.GetAccountByID(id)
	if err != nil {
		h.logger.Error("admin usage lookup failed", "account", id, "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	if acct == nil {
		http.Error(w, "account not found", http.StatusNotFound)
		return
	}

	devices := h.store.ListByOwnerIdent(Identity{Email: acct.Email, Sub: acct.GoogleSub})
	devViews := make([]deviceView, 0, len(devices))
	for _, d := range devices {
		devViews = append(devViews, h.viewOf(d))
	}

	counts, err := h.store.SigninOutcomeCountsForAccount(acct.ID, acct.GoogleSub)
	if err != nil {
		h.logger.Error("admin usage counts failed", "account", id, "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"account":         accountViewOf(acct, len(devViews)),
		"devices":         devViews,
		"device_count":    len(devViews),
		"signin_attempts": counts,
	})
}

// deviceCountFor counts an account's devices under the shared ownership
// predicate, for single-account responses (the list computes it in SQL).
func (h *Handler) deviceCountFor(a *Account) int {
	return len(h.store.ListByOwnerIdent(Identity{Email: a.Email, Sub: a.GoogleSub}))
}

// --- Invite codes ----------------------------------------------------------------

// inviteCodeAlphabet is the generated-code alphabet: unambiguous characters
// only (no 0/O, 1/I/l, and no L to avoid l-vs-1 confusion when lowercased).
const inviteCodeAlphabet = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"

// generateInviteCode returns a human-typable random code, XXXX-XXXX: 8
// characters from a 31-char unambiguous alphabet (~39.6 bits — plenty for a
// code that is also rate-limited by the enroll flow and consumable at most
// max_uses times), grouped by a dash for readability.
func generateInviteCode() (string, error) {
	b := make([]byte, 8)
	for i := range b {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(inviteCodeAlphabet))))
		if err != nil {
			return "", fmt.Errorf("generate invite code: %w", err)
		}
		b[i] = inviteCodeAlphabet[n.Int64()]
	}
	return string(b[:4]) + "-" + string(b[4:]), nil
}

// maxInviteCodeLen / maxInviteNoteLen bound admin-supplied invite fields.
const (
	maxInviteCodeLen = 64
	maxInviteNoteLen = 512
)

// handleAdminCreateInvite: POST /v1/admin/invites (JSON).
// Body {"code":"..."(optional), "max_uses":N|null, "expires_at":RFC3339|null,
// "note":"..."}. An omitted/empty code gets a generated XXXX-XXXX one
// (retried on the astronomically unlikely collision); a supplied code that
// already exists is a 409. created_by is stamped with the acting admin's sub.
func (h *Handler) handleAdminCreateInvite(w http.ResponseWriter, r *http.Request, admin Identity) {
	var body struct {
		Code      string     `json:"code"`
		MaxUses   *int       `json:"max_uses"`
		ExpiresAt *time.Time `json:"expires_at"`
		Note      string     `json:"note"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body); err != nil {
		http.Error(w, "invalid body: expected {\"code\":..., \"max_uses\":..., \"expires_at\":..., \"note\":...}", http.StatusBadRequest)
		return
	}
	code := strings.TrimSpace(body.Code)
	if len(code) > maxInviteCodeLen || len(body.Note) > maxInviteNoteLen {
		http.Error(w, "code or note too long", http.StatusBadRequest)
		return
	}
	if body.MaxUses != nil && *body.MaxUses <= 0 {
		http.Error(w, "invalid max_uses: expected a positive integer or null", http.StatusBadRequest)
		return
	}

	supplied := code != ""
	for attempt := 0; ; attempt++ {
		if !supplied {
			var err error
			code, err = generateInviteCode()
			if err != nil {
				h.logger.Error("invite code generation failed", "err", err)
				http.Error(w, "internal error", http.StatusInternalServerError)
				return
			}
		}
		err := h.store.CreateInviteCodeBy(code, body.MaxUses, body.ExpiresAt, body.Note, admin.Sub)
		if err == nil {
			break
		}
		// PRIMARY KEY collision: fatal for a supplied code (it exists), retried
		// for a generated one. Any other error is a 500.
		if isUniqueViolation(err) {
			if supplied {
				http.Error(w, "invite code already exists", http.StatusConflict)
				return
			}
			if attempt < 4 {
				continue // regenerate; ~2^40 space makes >1 retry vanishingly rare
			}
		}
		h.logger.Error("admin create invite failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	ic, err := h.store.GetInviteCode(code)
	if err != nil || ic == nil {
		h.logger.Error("admin create invite readback failed", "code", code, "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	h.audit(admin, "invite.create", code, map[string]any{
		"max_uses":   body.MaxUses,
		"expires_at": body.ExpiresAt,
		"note":       body.Note,
		"generated":  !supplied,
	})
	writeJSON(w, http.StatusCreated, map[string]any{"invite": ic})
}

// isUniqueViolation reports whether err is a SQLite UNIQUE/PRIMARY KEY
// constraint failure. modernc.org/sqlite exposes no typed error for this, so
// the documented error text is matched (the same approach its own tests use).
func isUniqueViolation(err error) bool {
	return err != nil && strings.Contains(err.Error(), "UNIQUE constraint failed")
}

// handleAdminListInvites: GET /v1/admin/invites (JSON).
// All codes, newest first, with uses/max_uses/expiry/revoked state.
func (h *Handler) handleAdminListInvites(w http.ResponseWriter, r *http.Request, _ Identity) {
	invites, err := h.store.ListInviteCodes()
	if err != nil {
		h.logger.Error("admin list invites failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	if invites == nil {
		invites = []InviteCode{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"invites": invites})
}

// --- Service settings --------------------------------------------------------------

// settingsView renders the settings payload for both GET and PUT responses.
func settingsView(mode SignupMode, source string) map[string]any {
	return map[string]any{"signup_mode": string(mode), "source": source}
}

// handleAdminGetSettings: GET /v1/admin/settings (JSON).
// Returns the EFFECTIVE runtime settings: the resolved signup mode plus its
// source ("db" when a settings row governs, "env-default" when still seeded
// from SIGNUP_MODE / INVITE_SIGNUP — see settings.go).
func (h *Handler) handleAdminGetSettings(w http.ResponseWriter, r *http.Request, _ Identity) {
	gate := h.auth.gate
	if gate == nil {
		// Only reachable in a mis-wired test server: production always SetGates.
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	mode, source := gate.SignupModeWithSource()
	writeJSON(w, http.StatusOK, settingsView(mode, source))
}

// handleAdminPutSettings: PUT /v1/admin/settings (JSON).
// Body {"signup_mode":"open|invite|closed|allowlist"}. Validates, persists
// (settings.signup_mode), busts the in-process cache — the change governs the
// very next sign-in decision, no restart — writes a settings.update audit row
// (old -> new), and returns the new effective state.
func (h *Handler) handleAdminPutSettings(w http.ResponseWriter, r *http.Request, admin Identity) {
	gate := h.auth.gate
	if gate == nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	var body struct {
		SignupMode string `json:"signup_mode"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body); err != nil {
		http.Error(w, "invalid body: expected {\"signup_mode\":\"open|invite|closed|allowlist\"}", http.StatusBadRequest)
		return
	}
	mode, ok := parseSignupMode(strings.ToLower(strings.TrimSpace(body.SignupMode)))
	if !ok {
		http.Error(w, "invalid signup_mode: expected open, invite, closed, or allowlist", http.StatusBadRequest)
		return
	}

	oldMode, _ := gate.SignupModeWithSource()
	if err := gate.SetSignupMode(mode); err != nil {
		h.logger.Error("admin set signup mode failed", "mode", mode, "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	h.audit(admin, "settings.update", settingSignupMode, map[string]any{
		"old": string(oldMode),
		"new": string(mode),
	})
	writeJSON(w, http.StatusOK, settingsView(mode, settingSourceDB))
}

// handleAdminRevokeInvite: DELETE /v1/admin/invites/{code}.
// Revokes the code (RevokeInviteCode: sets revoked_at, no-op when already
// revoked or unknown — idempotent 204 either way; the desired end state,
// "this code cannot be consumed", holds regardless).
func (h *Handler) handleAdminRevokeInvite(w http.ResponseWriter, r *http.Request, admin Identity) {
	code := r.PathValue("code")

	if err := h.store.RevokeInviteCode(code); err != nil {
		h.logger.Error("admin revoke invite failed", "code", code, "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	h.audit(admin, "invite.revoke", code, nil)
	w.WriteHeader(http.StatusNoContent)
}
