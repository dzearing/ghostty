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
	"errors"
	"log/slog"
)

// ErrInviteRequired is returned when a verified identity has no account and
// supplied no valid invite code. Distinct from ErrUnauthorized so enroll flows
// can surface a "you need an invite code" message rather than a bare 401.
var ErrInviteRequired = errors.New("invite code required")

// SigninGate authorizes verified identities under the invite-code model.
type SigninGate struct {
	cfg    *Config
	store  *Store
	logger *slog.Logger
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
// is the client IP for the audit row. Callers MUST have verified the identity
// (VerifyIdentity) before calling; this method makes no OIDC checks.
func (g *SigninGate) Authorize(ident Identity, inviteCode, ip string) error {
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
		g.record(ident, ip, outcomeAllowed, acct.ID)
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
	if err := g.store.RecordSigninAttempt(ident.Email, ident.Sub, ip, outcome, accountID); err != nil {
		g.logger.Warn("record signin attempt failed", "err", err)
	}
}
