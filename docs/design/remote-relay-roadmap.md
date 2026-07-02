# Remote Relay — Vision & Execution Roadmap

> Companion to `remote-transport-relay.md` (transport design, PROVEN) and
> `remote-machines.md` (original SSH-host-centric spec). This doc captures the
> **account-centric product vision** and a **phased, subagent-sized work plan** so the
> effort survives context clears and parallel agents. Branch: `feature/remote-machines`.

---

## 0. Status snapshot (the baseline — read first on resume)

**Core tunneling is PROVEN end-to-end, Tailscale-free.** A real Ghoztty remote window
into a Windows box (`MaximusHome`) was opened entirely through an Azure-hosted relay
(`hostname` → `MaximusHome` confirmed over the wire).

Commits on `feature/remote-machines`:
- `6f2560bca` — relay service (Go, `relay/`)
- `628321b9a` — SSH-over-relay connectors + ssh `ProxyCommand`
- `a8a485f5b` — client relay transport (`relay_dial.zig`, C export, CLI, Swift)
- `292a07368` + `c6a…` — native Zig WS client; SINGLE-BINARY agent (`--relay`);
  Go sidecars deleted
- `f0482de02` — pill honors `--name` on the IPC/CLI path
- `3f6dc90bc` — pill shows AGENT-REPORTED hostname (`Hello.hostname`,
  `ghostty_remote_connection_hostname`); relay windows registered in the IPC
  `targetRegistry` (`+send-keys`/`+read` work on them); debug-app crash-loop fix
  (ad-hoc re-sign after the install `cp -R` — was SIGKILL "Code Signature Invalid")
- `9ca6b1773` — pill SUPPRESSED when the agent-reported hostname is the local
  machine (`Machine.isLocalHostname`, normalized compare; pending live GUI verify)
- `26338d255` — WP-C1: `PATCH`/`DELETE /v1/client/devices/{id}` — rename + delete
  w/ credential revocation + live-conn kick (NOT yet deployed to the Azure relay)

WP-A2 (bundle `relay-connect`) is SUPERSEDED by the single-binary/in-process
client (`292a07368`) — no helper binary exists to bundle.

Validated 2026-07-01: **one-liner Windows install** (relay serves `/dl/install.ps1`
+ `ghoztty-agent.exe` via Caddy `handle_path /dl/*` → `/var/www/ghoztty-dl`) proven
on a SECOND box, the corp Cloud PC `CPC-dzear-IER1M` (device `windows-remote`) —
pill shows the real hostname. Install: `$env:DEVICE_TOKEN='<tok>'; irm
https://<fqdn>/dl/install.ps1 | iex` (re-run w/o token = binary update; don't mix
with the SMB watcher on the same box). The pill-not-local user requirement is
IMPLEMENTED (`9ca6b1773`) but awaits live GUI verification (needs a debug-app
relaunch, blocked while the user has live remote windows).

Live test infra (DEV/bring-up only):
- **Relay:** Azure VM `ghoztty-relay`, FQDN `ghoztty-relay-dz17575.westus2.cloudapp.azure.com`,
  RG `ghoztty-relay-rg`, West US 2, personal MSDN sub. Caddy (Let's Encrypt) → Go relay
  on `127.0.0.1:8080` (systemd `ghoztty-relay`). **`DEV_AUTH=true`** (static token in
  `/etc/ghoztty-relay.env`; OIDC implemented but inactive). Teardown:
  `az group delete -n ghoztty-relay-rg --yes`.
- **Windows box (`MaximusHome`):** **SINGLE-BINARY** `ghoztty-agent.exe --relay=<base>`
  (dials the relay itself via the native Zig WS client — no connector, no listener,
  one systray), token from `%LOCALAPPDATA%\ghoztty\relay.env`. Managed by the
  single-binary `ghoztty-agent-watcher.ps1` on `\\homeassistant\share\ghoztty-windows`
  (re-run after a script change). Devices: `windows-home`, `windows-remote` (unused).
  The Go `relay-connect`/`relay-agent` sidecars are DELETED — Go is only the relay
  server now. Mac client dials the relay in-process (no subprocess).
- **Mac client:** `Ghoztty-Debug.app` (`zig build -Doptimize=Debug`) dials the relay
  in-process (native WS; no helper subprocess, no launchctl env). Dev CLIENT token via
  `GHOSTTY_RELAY_TOKEN` env or `--token=` (CLIENT token, NOT a device token — a wrong
  token 401s and pops a MODAL alert that blocks queued dials until dismissed). The
  build re-signs the installed bundle ad-hoc (crash-loop fix); rebuild the native
  test agent too (`zig build agent`) when protocol fields change.

Conventions: env vars use **`GHOSTTY_`** (S, ghostty-fork inheritance), NOT GHOZTTY.
Toolchain: `export PATH=/opt/homebrew/opt/zig@0.15/bin:/opt/homebrew/opt/gettext/bin:$PATH;
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. GUI driving: see the
`ghoztty-gui-driving-now-possible` memory (process name `ghoztty`; confirm frontmost==debug
pid before keystrokes; launch via `open`).

How to prove the relay right now:
```
# device list (dev CLIENT token lives in /etc/ghoztty-relay.env on the VM +
# scratchpad relay-devtoken.txt):
curl -H "Authorization: Bearer <dev tok>" https://<fqdn>/v1/client/devices
# real window (debug app running):
zig-out/Ghoztty-Debug.app/Contents/MacOS/ghoztty +new-remote-window \
  --relay=https://<fqdn> --device=<device-id> --token=<dev tok> --name=<label>
# Go relay e2e test: cd relay && go test ./...
```

---

## 1. Vision (the product, in the user's words)

**Account-centric remote resources, dead-simple to manage:**

- **Sign in on the client → access my resources.** One identity (Google, with 2FA)
  unlocks the list of machines I own.
- **Install the agent on a machine, sign in there → the machine adds itself** to my
  resources (idempotent — no-op if already registered). No manual token wrangling.
- **Super easy to manage:** add a host = install+sign-in; **remove an old host** = one
  action in the list.
- **Cmd-Shift-N → chooser populated with my machines → pick one → new window** (the
  flow we already test, but account-driven).
- **Restore remote windows** after quitting/reopening the app.
- **Connection status for all hosts** (online/offline/disconnected), likely surfaced in
  the **Activity Monitor**.

Mental model: like Tailscale's "my devices," but for Ghoztty agent processes — and
self-hosted (the relay), no banned third-party dependency.

---

## 2. Target architecture

### 2.1 Identity & account
- **Account = a verified OIDC identity** (Google `sub`/email). The relay's allowlist
  gates which identities may exist (just the owner for now; multi-user later).
- **Client auth:** browser OAuth (Google, 2FA) → ID token → Keychain; refreshed.
- **Agent auth / self-enroll:** OAuth **device-code flow** on install ("visit URL,
  enter code, sign in"). On success the relay **upserts** this machine as a resource
  owned by that identity and issues a long-lived, revocable device credential. This is
  the "sign in on the agent and it adds itself" behavior. Replaces today's manual
  `POST /v1/client/devices` token minting.

### 2.2 Resource directory (per account, on the relay)
- Each resource = `{id, name, owner, created, last_seen, online}`. CRUD:
  **create** (self-enroll), **read** (list w/ online status — built), **update**
  (rename), **delete** (remove host + revoke its credential). All strictly owner-scoped.

### 2.3 Client
- After sign-in, the **Cmd-Shift-N chooser binds to the account resource list** (not
  hardcoded `Machine.swift`, not `~/.ssh/config`). Pick → `relay_dial` → window.
- **Add machine:** guided ("install the agent on the new box and sign in"); it then
  appears automatically. **Remove:** calls relay delete.
- `relay-connect` **bundled into the .app** (resolved via `GHOSTTY_BIN_DIR`/bundle, no
  launchctl hack).

### 2.4 Resilience & status
- **Restore:** a local manifest of open remote sessions; on relaunch, re-`ATTACH` by
  session UUID through the relay (the **agent already persists sessions** across
  disconnect — `SessionStore`, detach≠terminate, §7.1 of the spec).
- **Status:** relay already tracks online/offline per resource; add a reconnect state
  machine (spec §5) and surface status in the **Activity Monitor** + the in-window
  status pill (spec §11.3).

### 2.5 Relay operations
- Productionize: move to the always-on **home NUC** (Cloudflare Tunnel for a public
  `wss://` with no open ports) or keep Azure; **disable `DEV_AUTH`**; audit logging,
  rate limits, credential rotation/revocation.

---

## 3. Delta vs the existing spec (cross-check)

The original `remote-machines.md` is **SSH-host-centric**: connections keyed by
`(host,user,port,jump)`, hydrated from `~/.ssh/config`, full CRUD CLI (§10
`+remote add/edit/list/remove`), Connection Manager sidebar (§11.2), status pill
(§11.3), activity/kill view (§11.5).

The relay vision **keeps the UI shells** (chooser/sheet §11.1, manager §11.2, status
pill §11.3, activity view §11.5, error states §11.7) and the **CLI CRUD surface**
(§10) but **swaps the data model**: a resource is an **account-owned, self-registering
agent** reached via the relay, not an ssh-config host reached by direct dial. Both can
coexist (ssh-config hosts and relay resources in one list), but the relay path is the
Tailscale-replacement and the default for the vision. `~/.ssh/config` import (§10
`import-ssh-config`) becomes optional/secondary.

The transport WPs in `remote-transport-relay.md` map in: **WP-T1/T2/T3 = DONE**;
**WP-T0** (revert local default to SSH) is now optional (relay is the path); **WP-T4**
(Swift sign-in + dynamic list) expands into WP-R1/R2/R3/R5 below.

---

## 4. Phased work packages (subagent-sized; each self-contained)

Each WP lists: **goal · depends · key files · acceptance test**. A subagent should be
able to take one WP with only this doc + the repo.

### Phase A — Seamless single-machine GUI (prove the everyday flow)
- **WP-A1 — Cmd-Shift-N → relay window (dev token).** *Goal:* the existing GUI chooser
  opens `maximushome` via the **relay** transport (not TCP). *Depends:* none (transport
  done). *Files:* `macos/.../Machine.swift` (add relay fields/transport kind + a
  maximushome-relay entry: base + device id; token from `GHOSTTY_RELAY_TOKEN` env),
  the Cmd-Shift-N chooser + `AppDelegate` menu dispatch → `openRemoteWindow(relay:device:token:)`.
  *Accept:* Cmd-Shift-N → choose maximushome → a window opens running cmd.exe on
  MaximusHome through the relay. (Token still the dev token — OIDC is Phase B.)
- **WP-A2 — Bundle `relay-connect` into the .app.** *Goal:* kill the launchctl hack.
  *Files:* `build.zig`/`GhosttyAgent.zig`-style step to copy `relay-connect` into the
  app bundle; `embedded.zig` resolves it from `GHOSTTY_BIN_DIR`/bundle when
  `GHOSTTY_RELAY_CONNECT` unset. *Accept:* fresh app open → relay window works with no
  env var set.

### Phase B — Identity (sign-in everywhere)
- **WP-B1 — Real Google OIDC on the relay.** *Goal:* register a Google OAuth client;
  relay verifies real ID tokens; set `GOOGLE_CLIENT_ID`/`ALLOWED_EMAILS`; **disable
  `DEV_AUTH`**. *Files:* relay config/deploy. *Accept:* a real Google token authenticates;
  dev token rejected. (Needs ~10 min of Google Cloud Console clicks — document them.)
  **Prep DONE:** OIDC path audited + verified against a fake local issuer
  (`relay/auth_oidc_test.go`; identity now `{email, sub}`; bounded JWKS fetches);
  click-by-click deploy runbook in `docs/design/relay-oidc-setup.md`. **Remaining:**
  register the OAuth client in the console + flip the VM env per the runbook
  (do it with the user present — the Mac dev-token flow 401s until WP-B2).
- **WP-B2 — Client sign-in (macOS).** *Goal:* in-app Google OAuth (browser) → token in
  Keychain + refresh; signed-in identity drives all relay calls. *Files:* new
  `macos/.../RemoteConnection/` sign-in; wire token into the relay calls (replaces
  `GHOSTTY_RELAY_TOKEN`). *Accept:* user signs in with Google+2FA; chooser loads their
  resources.
- **WP-B3 — Agent device-code sign-in / self-enroll.** *Goal:* agent install runs OAuth
  device-code; on sign-in the machine **upserts itself** as a resource + gets a
  revocable credential. *Files:* relay device-code endpoints; agent/connector enroll
  flow; installer UX. *Accept:* install on a fresh box, sign in, it appears in the list
  automatically (idempotent on repeat).

### Phase C — Resource management (CRUD + UI)
- **WP-C1 — Relay resource CRUD. ✅ DONE.** *Goal:* add **rename** + **delete**
  (revoke credential) to the owner-scoped directory (list/create exist). *Files:*
  relay `handlers.go`/`store.go`. *Accept:* list/rename/delete via API; delete
  revokes. *Shipped:* `PATCH /v1/client/devices/{id}` (rename) +
  `DELETE /v1/client/devices/{id}` (delete + token revocation + live control/data
  conns kicked); owner-scoped 404s; tests in `relay/devices_crud_test.go`.
- **WP-C2 — Resource management UI.** *Goal:* the chooser/manager lists account
  resources with online status; **add** (guided install+sign-in) and **remove** a host.
  Reuse spec §11.2 shape. *Files:* `macos/.../RemoteConnection/`. *Accept:* remove an
  old host from the list; it disappears + its credential is revoked.

### Phase D — Resilience
- **WP-D1 — Connection status surface.** *Goal:* online/offline/reconnecting per
  resource in the **Activity Monitor** + status pill; reconnect state machine (spec §5).
  *Accept:* kill a host's connector → UI shows offline/reconnecting; recovery shows
  online.
- **WP-D2 — Window restore over relay.** *Goal:* local manifest of open remote
  sessions; on relaunch re-`ATTACH` by UUID through the relay. *Accept:* open remote
  windows, quit, reopen → windows restored to live sessions.

### Phase E — Operations
- **WP-E1 — Relay productionization.** *Goal:* move relay to the home NUC (Cloudflare
  Tunnel) or finalize Azure; disable DEV_AUTH; audit log, rate limits, rotation.
  *Accept:* documented, reproducible prod deploy; DEV_AUTH off.

**Suggested order:** A1 (immediate) → A2 → B1 → B2 → {C1, B3} → C2 → {D1, D2} → E1.
Phase A can ship on the dev token; Phase B makes it real.

---

## 5. Resume & parallel-subagent protocol

- **On context-clear resume:** read §0 (baseline) + this §4, check `git log` for the
  latest `feat(relay)` commits, and continue from the first unchecked WP.
- **Parallel subagents:** WPs touching disjoint files can run concurrently. Safe
  parallel sets: {B1 relay} ∥ {A1/A2 Mac}; {C1 relay} ∥ {D2 Mac}. Serialize anything
  touching `relay/handlers.go` or `embedded.zig`. Give each subagent: this doc, the
  target WP, and "build with the zig@0.15 toolchain; report files + acceptance result."
- **Each WP must end green:** `cd relay && go test ./...` and/or
  `zig build -Doptimize=Debug` succeed; state the acceptance test result.
- Keep this doc's WP checkboxes + §0 snapshot updated as increments land (mirror the
  one-liners into the `ghoztty-remote-transport-relay` memory).
