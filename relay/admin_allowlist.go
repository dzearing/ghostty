package main

// Admin REST surface for the DB-backed sign-in allowlist (allowlist.go):
//
//   GET    /v1/admin/allowlist         -> {"emails":[{email,source,note?,created_at?}]}
//   POST   /v1/admin/allowlist         -> 201 {"email":{...}}  (400 invalid, 409 duplicate)
//   DELETE /v1/admin/allowlist/{email} -> {"removed":bool}     (409 env-managed)
//
// Every route sits behind adminOnly (admin.go) and every mutation writes an
// admin_audit row. GET reports the EFFECTIVE list: allowed_emails rows
// (source "db", editable) plus ALLOWED_EMAILS env entries (source "env",
// immutable from here — the bootstrap/recovery half; removing one means
// editing the server environment). An email present in BOTH (possible only
// if the env changed after the row was added — env entries are never
// imported) is shown once as its DB row, since that is the half the portal
// can act on; deleting it leaves the env allowance standing.
//
// Mutations bust the gate's allowlist cache, so an add/remove governs the
// very next sign-in decision in-process — no restart, mirroring the
// signup-mode PUT. The list only GATES sign-in in `allowlist` mode, but the
// CRUD works in any mode so the list can be staged before a mode switch.

import (
	"encoding/json"
	"errors"
	"net/http"
	"sort"
	"strings"
	"time"
)

// Allowlist entry sources, as reported by GET /v1/admin/allowlist.
const (
	allowlistSourceDB  = "db"  // allowed_emails row: portal-managed
	allowlistSourceEnv = "env" // ALLOWED_EMAILS entry: bootstrap/recovery, immutable here
)

// allowlistEntryView is the admin-facing JSON shape of one effective-allowlist
// entry. Note/CreatedAt are DB-row-only (env entries carry neither).
type allowlistEntryView struct {
	Email     string     `json:"email"`
	Source    string     `json:"source"`
	Note      string     `json:"note,omitempty"`
	CreatedAt *time.Time `json:"created_at,omitempty"`
}

// envAllowlist returns the lowercased ALLOWED_EMAILS entries as a set. Built
// from cfg per call (the env list is tiny and fixed for the process life).
func (h *Handler) envAllowlist() map[string]bool {
	set := make(map[string]bool, len(h.cfg.AllowedEmails))
	for _, e := range h.cfg.AllowedEmails {
		if e = strings.ToLower(strings.TrimSpace(e)); e != "" {
			set[e] = true
		}
	}
	return set
}

// handleAdminListAllowlist: GET /v1/admin/allowlist (JSON).
// Env entries (minus any shadowed by a DB row) first, then DB rows, each
// alphabetical — a stable order the portal can render as-is.
func (h *Handler) handleAdminListAllowlist(w http.ResponseWriter, r *http.Request, _ Identity) {
	rows, err := h.store.ListAllowedEmails()
	if err != nil {
		h.logger.Error("admin list allowlist failed", "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	inDB := make(map[string]bool, len(rows))
	for _, row := range rows {
		inDB[row.Email] = true
	}
	var envEmails []string
	for e := range h.envAllowlist() {
		if !inDB[e] {
			envEmails = append(envEmails, e)
		}
	}
	sort.Strings(envEmails)

	out := make([]allowlistEntryView, 0, len(envEmails)+len(rows))
	for _, e := range envEmails {
		out = append(out, allowlistEntryView{Email: e, Source: allowlistSourceEnv})
	}
	for _, row := range rows { // ListAllowedEmails is already alphabetical
		created := row.CreatedAt
		out = append(out, allowlistEntryView{
			Email:     row.Email,
			Source:    allowlistSourceDB,
			Note:      row.Note,
			CreatedAt: &created,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"emails": out})
}

// handleAdminAddAllowlist: POST /v1/admin/allowlist (JSON).
// Body {"email":"...", "note":"..."(optional)}. 400 on an invalid email or
// oversize note; 409 when the email is already allowed — as a DB row OR via
// the env (the env half is not portal-managed, so "add" would be a lie).
func (h *Handler) handleAdminAddAllowlist(w http.ResponseWriter, r *http.Request, admin Identity) {
	var body struct {
		Email string `json:"email"`
		Note  string `json:"note"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body); err != nil {
		http.Error(w, "invalid body: expected {\"email\":\"...\", \"note\":\"...\"}", http.StatusBadRequest)
		return
	}
	email := strings.ToLower(strings.TrimSpace(body.Email))
	if !validAllowlistEmail(email) {
		http.Error(w, "invalid email", http.StatusBadRequest)
		return
	}
	if len(body.Note) > maxAllowlistNoteLen {
		http.Error(w, "note too long", http.StatusBadRequest)
		return
	}
	if h.envAllowlist()[email] {
		http.Error(w, "email is already allowed via the ALLOWED_EMAILS environment variable", http.StatusConflict)
		return
	}

	if err := h.store.AddAllowedEmail(email, body.Note); err != nil {
		if errors.Is(err, ErrAllowlistDuplicate) {
			http.Error(w, "email already on the allowlist", http.StatusConflict)
			return
		}
		h.logger.Error("admin add allowlist email failed", "email", email, "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	h.auth.gate.BustAllowlistCache() // effective on the very next request

	entry, err := h.store.GetAllowedEmail(email)
	if err != nil || entry == nil {
		h.logger.Error("admin add allowlist readback failed", "email", email, "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	h.audit(admin, "allowlist.add", email, map[string]any{"note": body.Note})
	created := entry.CreatedAt
	writeJSON(w, http.StatusCreated, map[string]any{"email": allowlistEntryView{
		Email:     entry.Email,
		Source:    allowlistSourceDB,
		Note:      entry.Note,
		CreatedAt: &created,
	}})
}

// handleAdminRemoveAllowlist: DELETE /v1/admin/allowlist/{email} (JSON).
// Removes the DB row -> {"removed":true}. No DB row but env-listed -> 409
// with a body explaining the entry is env-managed (edit the server
// environment; it exists as the recovery path). Unknown email ->
// {"removed":false} (the desired end state already holds).
func (h *Handler) handleAdminRemoveAllowlist(w http.ResponseWriter, r *http.Request, admin Identity) {
	email := strings.ToLower(strings.TrimSpace(r.PathValue("email")))
	if email == "" {
		http.Error(w, "invalid email", http.StatusBadRequest)
		return
	}

	removed, err := h.store.RemoveAllowedEmail(email)
	if err != nil {
		h.logger.Error("admin remove allowlist email failed", "email", email, "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	if removed {
		h.auth.gate.BustAllowlistCache()
		h.audit(admin, "allowlist.remove", email, nil)
		writeJSON(w, http.StatusOK, map[string]any{"removed": true})
		return
	}
	if h.envAllowlist()[email] {
		http.Error(w,
			"email is managed by the ALLOWED_EMAILS environment variable and cannot be removed from the portal; "+
				"remove it from the server environment (it is the bootstrap/recovery allowance)",
			http.StatusConflict)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"removed": false})
}
