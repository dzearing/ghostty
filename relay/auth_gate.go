package main

// SigninGate is the M1 authorization layer for the invite-code account model
// (plan §4.1–§4.3). It sits BETWEEN OIDC identity verification (auth.go, which
// still checks signature/issuer/aud/exp/email_verified and never weakens) and
// the act of granting access. It exists because that decision needs the Store
// and (for new accounts) the invite code from the request — neither of which
// auth.go's verifier has.
//
// It is only consulted when Config.InviteSignup is TRUE. When FALSE, callers
// keep using Authenticator.VerifyIDToken (ALLOWED_EMAILS) unchanged, so the
// live sign-in path is byte-for-byte identical to pre-M1.
//
// Decision, given a VERIFIED identity (email_verified, sub present):
//   - active account for this google_sub            -> allow
//   - blocked account                               -> reject (blocked)
//   - no account, valid+consumable invite code       -> create active account, allow
//   - no account, missing/invalid code               -> reject (no_account/bad_invite/…)
//
// A legacy owner (a device owner who predates accounts, matched by email with
// no sub yet) is allowed WITHOUT a code and lazily gets an account bound to
// their sub on this first verified sign-in (plan §4.1 option (a)).
//
// Every consulted attempt is recorded in signin_attempts (best-effort — a
// logging failure never blocks a legitimate sign-in). Recording only happens
// on the invite path (flag ON); the OFF path is untouched.

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"log/slog"
	"strings"
	"sync"
	"time"
)

// ErrInviteRequired is returned when a verified identity has no account and
// supplied no valid invite code. Distinct from ErrUnauthorized so enroll flows
// can surface a "you need an invite code" message rather than a bare 401.
var ErrInviteRequired = errors.New("invite code required")

// allowedLogInterval bounds repeat "allowed" audit rows for the SAME
// credential: the client authenticates on EVERY API request (device list
// polls included), so unthrottled logging floods signin_attempts with the
// same caller within hours. The throttle is credential-keyed, not just
// time-keyed: a FRESH token (a real login minting a new ID token) records
// immediately — "I signed in, show me" — while re-presentations of the same
// token are suppressed within the interval. Silent hourly token refresh thus
// costs at most one row per refresh. Failures/blocks are always recorded
// (each one is signal). In-memory: resets on restart (an extra row per
// identity per restart — harmless).
const allowedLogInterval = time.Hour

// allowedMark is the throttle state per identity: which credential was last
// logged, and when.
type allowedMark struct {
	fp string // token fingerprint
	t  time.Time
}

// SigninGate authorizes verified identities under the invite-code model.
type SigninGate struct {
	cfg    *Config
	store  *Store
	logger *slog.Logger

	// mu guards lastAllowed, the per-identity throttle state for "allowed"
	// audit rows (see allowedLogInterval).
	mu          sync.Mutex
	lastAllowed map[string]allowedMark
}

// throttleKey identifies a caller for the allowed-row throttle: the stable
// sub when present, else the lowercased email (legacy identities).
func throttleKey(ident Identity) string {
	if ident.Sub != "" {
		return ident.Sub
	}
	return strings.ToLower(ident.Email)
}

// tokenFingerprint is a compact, non-reversible identifier for a presented
// credential, used ONLY as the throttle key (never stored, never compared for
// auth). A fresh login mints a fresh token -> fresh fingerprint -> immediate
// audit row.
func tokenFingerprint(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:8])
}

// shouldRecordAllowed reports whether an "allowed" row is due for this
// identity + credential: YES for a credential not seen before (fresh login),
// YES when the interval elapsed, NO for the same credential re-presented
// within the interval (API polling). Marks it recorded when returning true.
func (g *SigninGate) shouldRecordAllowed(key, fp string) bool {
	now := time.Now()
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.lastAllowed == nil {
		g.lastAllowed = make(map[string]allowedMark)
	}
	if last, ok := g.lastAllowed[key]; ok &&
		last.fp == fp && now.Sub(last.t) < allowedLogInterval {
		return false
	}
	// Opportunistic sweep so the map cannot grow without bound.
	if len(g.lastAllowed) > 8192 {
		for k, m := range g.lastAllowed {
			if now.Sub(m.t) >= allowedLogInterval {
				delete(g.lastAllowed, k)
			}
		}
	}
	g.lastAllowed[key] = allowedMark{fp: fp, t: now}
	return true
}

// RecordLegacy writes the audit row for an ALLOWLIST-path decision
// (INVITE_SIGNUP off): outcome allowlist_allowed / allowlist_rejected. It is
// logging only — the accept/reject decision was already made by the caller
// and is unchanged. Allowed rows are throttled like the gate's own; verified-
// but-rejected rows are always recorded. Nil-safe: a gate-less Authenticator
// (some tests) simply doesn't log.
func (g *SigninGate) RecordLegacy(ident Identity, ip string, allowed bool, tokenFP string) {
	if g == nil || g.store == nil {
		return
	}
	if allowed {
		if !g.shouldRecordAllowed(throttleKey(ident), tokenFP) {
			// Metrics still count every decision; only the DB row is throttled.
			mSigninAttempts.WithLabelValues(outcomeAllowlistAllowed).Inc()
			return
		}
		g.record(ident, ip, outcomeAllowlistAllowed, "")
		return
	}
	g.record(ident, ip, outcomeAllowlistRejected, "")
}

// recordAllowedThrottled is the throttled variant of record() for the gate's
// own (INVITE_SIGNUP on) "allowed" decisions — same rationale as
// allowedLogInterval: authenticated API traffic must not flood the feed, but
// a fresh credential (real login) records immediately.
func (g *SigninGate) recordAllowedThrottled(ident Identity, ip, accountID, tokenFP string) {
	if !g.shouldRecordAllowed(throttleKey(ident), tokenFP) {
		mSigninAttempts.WithLabelValues(outcomeAllowed).Inc()
		return
	}
	g.record(ident, ip, outcomeAllowed, accountID)
}

// NewSigninGate builds the gate.
func NewSigninGate(cfg *Config, store *Store, logger *slog.Logger) *SigninGate {
	return &SigninGate{cfg: cfg, store: store, logger: logger}
}

// Enabled reports whether the invite-code model governs sign-in (flag ON).
func (g *SigninGate) Enabled() bool {
	return g.cfg.InviteSignup
}

// Authorize applies the invite-code account model to an already-VERIFIED
// identity and returns nil to allow or an error to reject. inviteCode is the
// code supplied in the request (may be empty — only new accounts need one). ip
// is the client IP for the audit row; tokenFP is the presented credential's
// fingerprint for the allowed-row throttle (see shouldRecordAllowed). Callers
// MUST have verified the identity (VerifyIdentity) before calling; this
// method makes no OIDC checks.
func (g *SigninGate) Authorize(ident Identity, inviteCode, ip, tokenFP string) error {
	// Existing account by stable sub.
	acct, err := g.store.GetAccountBySub(ident.Sub)
	if err != nil {
		g.logger.Error("account lookup failed", "err", err)
		return ErrUnauthorized // fail closed
	}
	if acct != nil {
		if acct.Status == AccountBlocked {
			g.record(ident, ip, outcomeBlocked, acct.ID)
			g.logger.Warn("sign-in refused: account blocked", "sub", ident.Sub, "email", ident.Email)
			return ErrUnauthorized
		}
		g.recordAllowedThrottled(ident, ip, acct.ID, tokenFP)
		return nil
	}

	// No account by sub. Before requiring an invite, honor the legacy-owner
	// migration: an owner who predates accounts (a device with only an email)
	// is matched by email and lazily gets an account bound to their sub — no
	// code, never locked out (plan §4.1).
	if legacy, err := g.legacyOwnerAccount(ident); err != nil {
		g.logger.Error("legacy-owner bind failed", "err", err)
		return ErrUnauthorized
	} else if legacy != nil {
		g.record(ident, ip, outcomeAllowed, legacy.ID)
		g.logger.Info("legacy owner bound to account", "sub", ident.Sub, "email", ident.Email)
		return nil
	}

	// Genuinely new: require and consume an invite code.
	if inviteCode == "" {
		g.record(ident, ip, outcomeNoAccount, "")
		return ErrInviteRequired
	}
	outcome, err := g.store.ValidateAndConsumeInvite(inviteCode)
	if err != nil {
		g.logger.Error("invite validation failed", "err", err)
		return ErrUnauthorized
	}
	if outcome != InviteOK {
		g.record(ident, ip, outcome.signinOutcome(), "")
		g.logger.Warn("sign-in refused: invalid invite", "outcome", outcome.signinOutcome(), "email", ident.Email)
		return ErrInviteRequired
	}

	// Code consumed — create the account.
	acct, err = g.store.CreateAccount(ident.Sub, ident.Email, inviteCode)
	if err != nil {
		g.logger.Error("account creation failed", "err", err)
		return ErrUnauthorized
	}
	g.record(ident, ip, outcomeAllowed, acct.ID)
	g.logger.Info("account created via invite", "sub", ident.Sub, "email", ident.Email)
	return nil
}

// legacyOwnerAccount finds a pre-account owner by email, binds this sign-in's
// sub to it, and returns the account. It matches ONLY when the caller owns at
// least one legacy device (owner_sub empty) under this email — so a brand-new
// stranger who merely shares no account cannot slip in without a code. Returns
// (nil, nil) when there is no legacy owner to migrate.
func (g *SigninGate) legacyOwnerAccount(ident Identity) (*Account, error) {
	// Is there an existing account row for this email that has no sub yet?
	// (e.g. a placeholder, or a prior partial bind.) Bind and return it.
	if acct, err := g.store.GetAccountByEmail(ident.Email); err != nil {
		return nil, err
	} else if acct != nil && acct.GoogleSub == "" {
		if err := g.store.BindAccountSub(acct.ID, ident.Sub, ident.Email); err != nil {
			return nil, err
		}
		acct.GoogleSub = ident.Sub
		return acct, nil
	}

	// Otherwise: does the caller own a legacy device (owner_sub empty) under
	// this email? That is the real "existing owner from before accounts"
	// signal. If so, create their account now (no code) and stamp the sub onto
	// their legacy devices so future authz is sub-keyed.
	if !g.store.HasLegacyDeviceForEmail(ident.Email) {
		return nil, nil
	}
	acct, err := g.store.CreateAccount(ident.Sub, ident.Email, "")
	if err != nil {
		return nil, err
	}
	if err := g.store.BindLegacyDevicesToSub(ident.Email, ident.Sub); err != nil {
		// Non-fatal: the account exists and future sign-ins still authorize;
		// the devices just keep matching by the email fallback until stamped.
		g.logger.Warn("legacy device sub backfill failed", "err", err)
	}
	return acct, nil
}

// record writes a best-effort signin_attempts row; a failure is logged, never
// propagated (it must not block a legitimate sign-in).
func (g *SigninGate) record(ident Identity, ip, outcome, accountID string) {
	mSigninAttempts.WithLabelValues(outcome).Inc() // metrics.go
	if err := g.store.RecordSigninAttempt(ident.Email, ident.Sub, ip, outcome, accountID); err != nil {
		g.logger.Warn("record signin attempt failed", "err", err)
	}
}
