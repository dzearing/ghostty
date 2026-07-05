# Multi-Tenant Launch — Conductor State (resume-from-cold)

This is the **single source of truth for the orchestration loop**. It exists so a
FRESH context (after `/clear`) can resume with zero prior memory. The detailed
plan is `docs/design/multi-tenant-launch-plan.md`; this file tracks *where we are*
and *what to do next*.

Last updated: 2026-07-05 (M1 merged; M2 + M4 + M5a are now unblocked; production
cutover of M1 auth is PENDING — human checkpoint).

## ON RESUME ("go") — do this, in order
1. Read this file, then `docs/design/multi-tenant-launch-plan.md`.
2. Establish ground truth from git, not memory:
   - `git -C /Users/dzearing/git/ghoztty log --oneline -8` (what's merged to main)
   - `git -C /Users/dzearing/git/ghoztty branch -a | grep mt/` (milestone branches)
   - `git -C /Users/dzearing/git/ghoztty worktree list` (in-flight worktrees)
3. Find the first milestone in the table below that is NOT `merged`. That's the
   active one. Reconcile its row with git:
   - If its branch exists with commits but isn't merged → it's awaiting review;
     review the diff, run its acceptance checks, merge if green (else fix).
   - If no branch → launch it (Agent tool, `isolation: worktree`, spec from the
     plan's milestone section). Milestone agents run in their OWN context.
4. After merging a milestone: update the table below, `git add`+commit+push this
   file, THEN reset context (see "Context-reset protocol").
5. Respect the human checkpoints — STOP and ask before those steps.

## Locked decisions (see plan §2)
SQLite (WAL) + Litestream · React (Vite) SPA + Recharts · Prometheus · single Azure VM · admin via Google OIDC allowlist. Authz key migrates email→`google_sub` in M1.

## Milestone status
| M | Name | Branch | State | Depends on |
|---|------|--------|-------|-----------|
| M0 | SQLite foundation | `mt/m0-sqlite` | **merged** → main `8a328e120` (re-verified: build/vet/race-tests/static-build). NOT yet deployed to prod. | — |
| M1 | Invite-code sign-up (retire ALLOWED_EMAILS, authz→sub) | `mt/m1-invite-signup` | **merged** → main `40066364e` (re-verified: build/vet/race-tests/static-build). Staged behind `INVITE_SIGNUP` (default OFF) — **live cutover NOT done** (human checkpoint; see M1 handoff below). | M0 ✓ |
| M2 | Admin API + admin auth | `mt/m2-admin-api` | pending | M1 |
| M3 | Admin portal UI (React) | `mt/m3-admin-portal` | pending | M2 |
| M4 | Quotas + rate limits | `mt/m4-quotas` | pending | M1 (parallel w/ M2/M3) |
| M5a | Prometheus /metrics backbone | `mt/m5a-metrics` | pending | M0 (parallel) |
| M5b | Portal availability + usage charts | `mt/m5b-portal-charts` | pending | M3, M5a |
| M6 | Launch hardening / ops | `mt/m6-ops` | pending | M3, M4, M5 |

State values: `pending` → `in worktree` → `awaiting review` → `merged`.

## Human checkpoints (STOP and ask)
- **M1 production auth cutover** — flipping live sign-in from `ALLOWED_EMAILS` to
  invite codes. Stage behind a flag; get explicit OK before the live switch.
- **Litestream backup target** — needs an Azure Blob storage account + container
  + creds (wired in M6 or when provided).
- **Prometheus standup** (M5a) — a service on the VM + scrape config.
- Any production deploy of the relay (restart drops live relay links briefly).

## Deploy facts (for milestones that ship)
- Relay VM: `azureuser@ghoztty-relay-dz17575.westus2.cloudapp.azure.com`, systemd
  unit `ghoztty-relay`, env at `/etc/ghoztty-relay.env`, `STATE_DIR=/var/lib/ghoztty-relay`.
- Build+deploy relay: `cd relay && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /tmp/relay . && scp … && sudo install … && sudo systemctl restart ghoztty-relay`.
- Agent republish (unrelated to this work): `relay/deploy/publish-agent.sh --if-changed`.

## Context-reset protocol (why this file exists)
The conductor context bloats across milestones; reset it at each merge boundary.
- **Constraint (verified 2026-07-05):** the pane running the conductor is NOT in
  ghoztty's IPC registry (`GHOZTTY_PANE_NAME` = surface id, but `+read`/`+send-keys`
  return "not found in registry"). A pre-existing pane can't be a send-keys target,
  so the conductor CANNOT `/clear` itself directly.
- **Working reset options:**
  1. Manual: at a merge boundary the conductor writes state here and stops; the
     human types `/clear` then `go`. Reliable; doubles as a per-milestone review beat.
  2. Automated: run the conductor inside a REGISTERED pane
     (`ghoztty +new-window --target=conductor --command="claude"`), and at each
     boundary fire a detached `sleep 2; ghoztty +send-keys --target=conductor "/clear" Enter; sleep 1; ghoztty +send-keys --target=conductor "go" Enter`
     before ending the turn. A registered target CAN be driven; the background
     send fires after the turn ends. (Not yet set up.)

## M1 handoff facts (from the merged work — M2/M4 must honor these)
- **`INVITE_SIGNUP` env flag (bool, default OFF).** OFF = pre-M1 behavior
  byte-for-byte (`ALLOWED_EMAILS` gates, no attempt logging). ON = invite-code
  account model governs sign-in. Flipping it live is the pending human checkpoint.
- Migration `0002_accounts.sql`: `accounts` (google_sub UNIQUE, status
  active|blocked), `invite_codes` (code pk, max_uses NULL=unlimited, uses,
  expires_at/revoked_at), `signin_attempts` (append-only audit, indexed on ts).
- **`devices.account_id` deferred to M2** (documented in the migration header).
  Ownership is keyed on `devices.owner_sub` with a lowercased-email fallback for
  legacy empty-sub rows (`ownsClause` in store.go, `Device.OwnedBy`). M2 adds the
  physical FK once live devices have bound subs.
- Authz surface: `Authenticator.VerifyIdentity` (verification only) vs
  `VerifyIDToken` (verification + ALLOWED_EMAILS, the flag-OFF path);
  `SigninGate.Authorize` (auth_gate.go) is the flag-ON decision and needs the
  Store. Wired via `auth.SetGate(...)` in main.go — test servers must mirror this.
- Invite code enters at `POST /v1/enroll/start` JSON body field `invite_code`
  (both device + web flows), parked on the pending enrollment, consumed at the
  success path. Returning/legacy owners never need one (headless flow unchanged).
- Legacy owner migration is **lazy**: first verified sign-in with flag ON matches
  a legacy device by email, creates the account (no code), and backfills the sub
  onto their devices (`BindLegacyDevicesToSub`). Reads SQLite, never devices.json.
- Store seams for M2 admin API: `CreateInviteCode`, `RevokeInviteCode`,
  `GetAccountBySub/ByEmail`, `RecordSigninAttempt`, `CountSigninAttempts`.
- DSN gained `_txlock=immediate` (BEGIN IMMEDIATE) so read-then-write txs wait on
  busy_timeout instead of failing with SQLITE_BUSY_SNAPSHOT under concurrency.

### M1 production cutover runbook (the pending human checkpoint)
1. Deploy the new binary (brings SQLite from M0 + flag-OFF M1; restart drops live
   relay links briefly — itself a checkpoint). Live auth unchanged.
2. Seed ≥1 invite code (`Store.CreateInviteCode`; M2 admin API will wrap this).
3. Set `INVITE_SIGNUP=true` in `/etc/ghoztty-relay.env`, restart. Keep
   `ALLOWED_EMAILS` populated for one release as the instant rollback
   (`INVITE_SIGNUP=false` + restart reverts fully; no data migration).
4. Verify dzearing@gmail.com signs in with NO code → an `accounts` row appears
   with the real Google sub, status=active; devices get sub-stamped.
5. Watch `signin_attempts` outcome distribution for anomalies.

## M0 handoff facts (from the merged work — M1 must honor these)
- `devices` table exists (SQLite, WAL, `STATE_DIR/ghoztty-relay.db`); migrations
  are goose, dialect `sqlite3`, embedded in `relay/migrations/`, auto-applied on
  startup. M1 adds `0002+` for `accounts`/`invite_codes`/`signin_attempts` and may
  FK `devices.account_id`.
- Ownership is still keyed on `owner_email` (lowercased on write); `owner_sub` is
  stored but not yet an authz key — M1 migrates authz to `google_sub`.
- `ALLOWED_EMAILS` is untouched and still enforced — M1 retires it.
- The JSON importer only runs on an empty table. Existing rows now live in SQLite,
  so M1's "migrate the existing owner into an account" logic must read from the
  `devices` table, NOT `devices.json`.
- **Prod not yet on SQLite** — the live relay still runs the pre-M0 binary. Deploy
  M0's storage swap either standalone (approval: it's a restart) or bundled with
  the M1 cutover. Either way the live `devices.json` imports on first SQLite boot.

## M1 launch spec (for the fresh context)
Launch a worktree agent (Agent tool, `isolation: worktree`) with the plan's §M1
scope: accounts + invite_codes + signin_attempts tables; new-account sign-in
requires a valid/unexpired/unexhausted invite code; blocked-account rejection;
record every sign-in attempt; **migrate the existing owner into an active account
with no code**; **switch every ownership check from owner_email to google_sub**
(email fallback for legacy rows); retire the `ALLOWED_EMAILS` gate (keep as an
emergency bootstrap behind a flag for one release). Acceptance: fresh Google
account can sign up only with a valid code; blocked account refused; existing
owner keeps working; cross-account isolation tests still green; all prior tests
green. STOP before the production cutover (human checkpoint).
