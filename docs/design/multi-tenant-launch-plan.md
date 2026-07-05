# Ghoztty Relay — Multi-Tenant Launch Plan

Turning the single-tenant private-beta relay into a public, closed-signup
product: invite codes, an admin portal, a real database, quotas, and
availability monitoring.

**Status:** planning. Nothing here is built yet. Each milestone below is scoped
to be executed in its OWN git worktree/context, reviewed, and merged before the
next dependent one starts (see §7 Execution model).

---

## 0. Where we are today (baseline)

- **Relay:** single Go service, one Azure VM, TLS terminated by Caddy in front,
  process on loopback `127.0.0.1:8080`.
- **Auth:** Google OIDC. A verified sign-in is accepted only if its email is in
  the `ALLOWED_EMAILS` env allowlist (`auth.go:209`) — currently a single
  address. Empty list = nobody. This is a **private-beta gate**, not tenancy.
- **Storage:** flat file `devices.json` under `STATE_DIR`, loaded into an
  in-memory `map[string]*Device` behind a `sync.RWMutex`, **rewritten whole** on
  every mutation (`store.go:319`). No accounts table — an "account" is implicit,
  just the `owner_email`/`owner_sub` on each device row.
- **Isolation:** already per-account and sound — device rows are owner-stamped,
  `ListByOwner` filters, connect/rename/delete are owner-scoped. Two accounts are
  correctly walled off *today*. The security model is multi-tenant-ready; the
  deployment is not.
- **Live state:** online agents + pending sessions live only in-memory in
  `Directory` (never persisted).
- **No** quotas, rate limits, abuse controls, metrics store, or admin surface.

## 1. Target state

- **Closed sign-up via invite codes.** First sign-in requires a valid, unexpired,
  not-exhausted code → creates an account (keyed on the stable Google `sub`).
- **Admin portal** (web) to: watch sign-in attempts; list/search sign-ups; block
  or delete accounts; create/revoke invite codes (optional expiry + max uses);
  view per-account usage/quota; view availability + usage charts.
- **Real database** (Postgres) with migrations, replacing the flat file.
- **Quotas + rate limits** per account and per IP; enforced and surfaced.
- **Metrics + availability monitoring** feeding the portal's charts.

## 2. Tech decisions (LOCKED — confirmed 2026-07-05)

| Concern | Decision | Notes |
|---|---|---|
| Database | **SQLite** (WAL mode) on the VM, continuously backed up by **Litestream** to Azure Blob | Pure-Go driver so the relay stays a static single binary (no cgo). Nearly free, single-node. Litestream backup target (storage account + container) is the one small infra bit, deferrable to when it's wired. |
| DB driver | **`modernc.org/sqlite`** (pure Go, CGO-free) + **`goose`** migrations + **`sqlc`** (sqlite dialect) | Keeps `CGO_ENABLED=0` static builds; type-safe queries; versioned schema. |
| Admin portal | **React (Vite) SPA** + **Recharts**, served as static assets by Caddy, talking to an admin REST API on the relay | Interactive dashboards/charts. |
| Metrics backbone | **Prometheus** (relay exposes `/metrics`) on the same VM; portal queries its HTTP API. Grafana optional for deep ops. | |
| Hosting | **Single Azure VM** for now — SQLite + Prometheus alongside the relay. Revisit HA when usage warrants. | Accepted single point of failure for beta. |
| Admin identity | Google OIDC restricted to an **admin allowlist** (bootstrap sub via env, then managed in DB) | Reuse existing auth; no separate cred system. |

Everything stays behind Caddy TLS. The admin API is a distinct, separately
authorized surface (admin-only), never reachable with a normal user token.

## 3. Data model (target schema sketch)

```
accounts
  id              uuid pk
  google_sub      text unique not null      -- stable identity; authz key
  email           text not null             -- current email (display/contact)
  status          text not null             -- active | blocked
  invited_by_code text                      -- the code consumed at signup
  created_at      timestamptz
  blocked_at      timestamptz null
  blocked_reason  text null

devices                                     -- existing Device, now FK'd
  id              uuid pk
  account_id      uuid fk -> accounts.id
  name, hostname, token_hash, created_at    -- as today

invite_codes
  code            text pk                    -- human-typable
  created_by      uuid fk -> accounts.id (admin)
  max_uses        int null                   -- null = unlimited
  uses            int not null default 0
  expires_at      timestamptz null           -- null = never
  revoked_at      timestamptz null
  note            text
  created_at      timestamptz

signin_attempts
  id              bigserial pk
  ts              timestamptz
  email, google_sub text
  ip              inet
  outcome         text     -- allowed | blocked | no_account | bad_invite | expired_invite | not_verified
  account_id      uuid null

usage_events                                 -- for per-account usage + charts
  id              bigserial pk
  account_id      uuid
  device_id       uuid
  kind            text      -- session_open | session_close
  bytes           bigint null
  duration_ms     bigint null
  ts              timestamptz

admin_audit
  id, ts, admin_account_id, action, target, detail   -- every admin mutation
```

Metrics (Prometheus) are separate from these operational tables; the portal
joins DB (accounts/usage) with Prometheus (availability/throughput).

## 4. The auth-model cutover (important, affects live users)

Switching from `ALLOWED_EMAILS` to invite-code accounts changes the live
sign-in path. Cutover rules (implemented in M1):

1. **Migrate the existing owner:** create an `active` account for the current
   `owner_email`/`owner_sub` (from `devices.json`) with no code required, and
   re-point its devices. So today's user never gets locked out.
2. **New sign-in:** verified Google identity with NO account → require an invite
   code in the request → validate (exists, not revoked, not expired, uses <
   max_uses) → create account, increment `uses`, record attempt.
3. **Returning sign-in:** account must exist AND `status = active`. Blocked →
   reject; every attempt recorded either way.
4. **Authz key becomes `google_sub`** (not the mutable email) everywhere
   ownership is checked — folds in the P3 hardening from the prior audit.
5. `ALLOWED_EMAILS` is retired (or kept only as an emergency admin bootstrap).

## 5. Milestones

Each is a standalone unit of work with its own worktree/branch, acceptance
tests, and (where relevant) a deploy step. **Bold = human checkpoint** required.

### M0 — Database foundation (no user-visible change)
- Add SQLite (`modernc.org/sqlite`, WAL) + `goose` migrations + `sqlc`. DB path
  under `STATE_DIR` (`ghoztty-relay.db`). No managed-DB provisioning — it's a
  file; Litestream backup is wired in M6 (or when a blob target is provided).
- Reimplement `Store` against SQLite behind the *existing* interface so current
  handlers are untouched; keep `Directory` in-memory.
- One-time importer: `devices.json` → `devices`/`accounts` on first boot
  (idempotent; leaves the JSON as a backup).
- `ALLOWED_EMAILS` still works (parallel) — zero behavior change yet.
- **Accept:** relay runs on SQLite, all existing Go tests green, existing devices
  intact, dev flow (enroll/connect) unchanged, static `CGO_ENABLED=0` build still
  works. Branch: `mt/m0-sqlite`. **No human checkpoint** (no infra to provision).

### M1 — Accounts + invite-code sign-up (retire the allowlist)
- Accounts + invite_codes + signin_attempts tables + the §4 cutover logic.
- New enroll/sign-in path: invite required for new accounts; blocked-account
  rejection; attempt logging; **authz keyed on `google_sub`**.
- Migrate the existing owner (no code). Remove `ALLOWED_EMAILS` gate.
- **Accept:** a fresh Google account can sign up only with a valid code; a
  blocked account is refused; existing owner keeps working; cross-account
  isolation tests still green. **Human checkpoint: production cutover** (this
  changes the live auth path). Branch: `mt/m1-invite-signup`.

### M2 — Admin API + admin auth
- Admin allowlist (bootstrap sub via env → managed in DB). Admin-only middleware.
- REST endpoints: list/filter sign-in attempts; list/search accounts; block /
  unblock / delete account; invite-code CRUD (create w/ optional expiry +
  max_uses, list, revoke); per-account usage summary. Every mutation → `admin_audit`.
- **Accept:** full admin REST surface, authorized (non-admin → 403), tested.
  Branch: `mt/m2-admin-api`.

### M3 — Admin portal UI
- React (Vite) SPA (or templ+HTMX) consuming M2. Screens: dashboard, sign-in
  attempts, accounts (block/delete), invite codes (create/expire/revoke),
  per-account usage. Served behind Caddy at an admin host/path, admin-OIDC gated.
- **Accept:** you can manage codes, watch attempts, and block/delete accounts
  from a browser. Branch: `mt/m3-admin-portal`.

### M4 — Quotas, rate limits, abuse controls (parallelizable after M1)
- Per-account: max devices, max concurrent sessions. Per-IP + per-account rate
  limits on sign-in/enroll/connect. Configurable defaults, per-account overrides.
- Surface quota usage via the admin API/portal.
- **Accept:** limits enforced (with clear client errors) + visible in the portal;
  load test confirms rate limiting. Branch: `mt/m4-quotas`.

### M5 — Metrics, availability monitoring + charts
- **M5a (after M0):** relay exposes Prometheus `/metrics` (online agents, active
  sessions, bridge throughput, error rates, sign-in outcomes, DB health);
  **stand up Prometheus (human: infra) + scrape config.** Uptime/blackbox probe.
- **M5b (after M3):** portal availability + usage charts (query Prometheus HTTP
  API + `usage_events`). Optional Grafana for deep ops.
- **Accept:** portal shows uptime, live counts, and usage-over-time charts.
  Branches: `mt/m5a-metrics`, `mt/m5b-portal-charts`.

### M6 — Launch hardening / ops
- DB backups + PITR verified; secrets management; portal + migration deploy
  pipeline; account deletion + data export (privacy); ToS/privacy copy; runbooks;
  HA/failover decision. **Human checkpoints throughout.** Branch: `mt/m6-ops`.

## 6. Dependency graph

```
M0 ─► M1 ─► M2 ─► M3 ─► M5b ─► M6
        │                ▲
        ├─► M4 ──────────┤
        └─► M5a ─────────┘   (M5a needs only M0)
```

Critical path is sequential (M0→M1→M2→M3→M5b→M6); **M4** and **M5a** run in
parallel worktrees once their parent is merged.

## 7. Execution model (worktree per milestone, automated)

- One git worktree + branch per milestone (names above). A milestone is
  implemented, tested, and self-reviewed **inside its worktree** so contexts stay
  isolated and the main tree is never half-migrated.
- Sequence dependent milestones: a milestone starts only after its parent is
  merged to `main` (its schema/interfaces are the parent's contract). M4/M5a fan
  out in parallel.
- Each milestone ends with: green tests, a short changelog, and — for M0/M1/M3/M5
  — a **human checkpoint** before the production step (DB provisioning, auth
  cutover, portal deploy) because those touch live users, cost, or infra.
- Automation drives the *implementation + tests* autonomously per worktree;
  provisioning real infra (Postgres, Prometheus) and production cutovers stay
  gated on explicit approval.

## 8. Decisions — LOCKED (2026-07-05)

1. **Database:** SQLite (WAL) + Litestream backup, on the VM.
2. **Admin portal:** React (Vite) SPA + Recharts.
3. **Metrics:** Prometheus (+ optional Grafana), same VM.
4. **Hosting:** single Azure VM for now; revisit HA later.

## 9. Risks / notes

- **Auth cutover (M1) is the riskiest step** — it changes the live sign-in path.
  Migrate the existing owner first; stage behind a flag; keep `ALLOWED_EMAILS` as
  a rollback for one release.
- Flat-file→Postgres import must be idempotent and verified against a backup of
  `devices.json`.
- Cost: managed Postgres + Prometheus add real monthly spend — size for beta,
  scale later.
- The device/session data plane (agent ↔ relay bridge) is unchanged by all of
  this; the work is auth, storage, and the admin/ops surface.
