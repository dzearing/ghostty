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
- `5c6fade6c` — WP-B1 prep: OIDC path verified (fake-issuer tests, `{email,sub}`
  identity, bounded JWKS fetches) + runbook `docs/design/relay-oidc-setup.md`
- `361aa960e` — WP-C2: chooser lists account devices from the relay w/ online dot
  + remove/rename (`RelayDirectoryClient.swift`; GUI render verify pending)
- WP-B3 (relay half) — OAuth device-code SELF-ENROLL: unauthenticated
  `POST /v1/enroll/start` (Google device-code via discovery; opaque handle,
  Google's device_code never leaves the relay) + `POST /v1/enroll/poll`
  (per-handle rate limit; ID token verified like client auth; idempotent
  upsert: same owner+name → same device id, token ROTATED) → returns
  `{device_id, device_token, relay_base}` once; `relay/enroll.go` +
  `enroll_test.go` vs fake Google endpoints.
- WP-B3 (agent half) — `ghoztty-agent --enroll --relay=<base>`: prints
  "visit <url>, enter code XXXX-XXXX", polls (slow_down +5s; denied/expired/
  rejected terminal), persists `RELAY_BASE`+`DEVICE_TOKEN` to relay.env
  (`%LOCALAPPDATA%\ghoztty\relay.env` / `~/.config/ghoztty/relay.env`;
  `GHOSTTY_RELAY_ENV` overrides — tests use it). `--relay` mode now falls back
  to relay.env when `GHOSTTY_DEVICE_TOKEN` is unset (env wins), so enroll→run
  is seamless. New: `src/remote/http_client.zig` (native TLS or plaintext-http
  JSON POST; http:// is for loopback test relays), `src/remote/agent/enroll.zig`.
  PROVEN e2e by `relay/agent_enroll_e2e_test.go` (real Zig binary vs fake-issuer
  relay; gated on `GHOZTTY_AGENT_BIN`). Installer updated: hosted install.ps1
  source now in-repo at `relay/deploy/install.ps1` — no DEVICE_TOKEN → runs
  `--enroll` interactively. DEPLOYED 2026-07-02: the new install.ps1 AND the
  enroll-capable `ghoztty-agent.exe` are uploaded to `/var/www/ghoztty-dl/`
  (the SMB-share copy for MaximusHome's watcher was deliberately NOT swapped —
  hot-swap restarts the agent and kills live sessions). STILL TODO: register
  the real Google OAuth client (WP-B1; until then the deployed relay is
  DEV_AUTH-only and enroll answers 503; the flip now also needs
  `GOOGLE_CLIENT_SECRET` in /etc/ghoztty-relay.env).
- WP-D2 — remote windows RESTORE on relaunch: local `RemoteSessionManifest`
  (UserDefaults) + re-`ATTACH` by session UUID through the relay at launch; clean
  close removes the entry, quit keeps it; restore failures are silent (no modal);
  protocol flow proven by the extended `wp4-e2e` harness (GUI quit/reopen verify
  pending)
- WP-D1 — connection status surface + reconnect: §5.1 `LinkState` exposed over C
  (`ghostty_remote_connection_state`/`_set_state_callback`); per-window reconnect
  machine in `BaseTerminalController` (backoff dial → `GET_CWD` probe →
  re-`ATTACH` swap; exhausted/gone ⇒ `disconnected`, window kept); pill dot
  green/yellow/red + status suffix (local suppression lifted while degraded);
  proven by `wp4-e2e` Phase 3 (GUI pill flow verify pending)
- WP-B2 — client Google sign-in (macOS): browser authorization-code + PKCE w/
  loopback redirect (`GoogleOAuth.swift`), refresh token in Keychain, in-memory
  ID token w/ 60s-leeway refresh (`RelayAccount.swift`); ONE token seam
  `RelayAccount.resolveToken()` (account ID token → `GHOSTTY_RELAY_TOKEN`
  fallback) now feeds the directory client, chooser dial, WP-D2 restore, WP-D1
  reconnect, and IPC `+new-remote-window` (when no `--token`); chooser footer
  sign-in/sign-out row; client id from `GHOSTTY_GOOGLE_CLIENT_ID` /
  `defaults GhosttyGoogleClientID` (none baked in — Google client still
  unregistered, see `relay-oidc-setup.md`); verified headlessly (swiftc
  harness: PKCE vector, loopback, fake token endpoint, Keychain e2e) — real
  Google client + live browser flow pending WP-B1 console registration

- `ef84967d6` — loopback endpoints (127.x/::1/localhost) count as the local
  machine for pill suppression (a TCP dial to 127.0.0.1 showed a "127.0.0.1" pill)

WP-A2 (bundle `relay-connect`) is SUPERSEDED by the single-binary/in-process
client (`292a07368`) — no helper binary exists to bundle.

**2026-07-03 mid-day — live dogfooding sprint (tip `a00550f84`; relay + `/dl`
exe + install.ps1 all redeployed):**
- `f2dbaeb2c` — Activity Monitor chart button dials RELAY machines via
  `AppDelegate.dialRelay` (was TCP-only → silent no-op for account machines).
- `ed8482d25` — SIGN-OUT CONTRACT (user-defined): sign-out closes all
  account-backed windows (`isSigningOut` preserves their manifest entries),
  every dial path (chooser/IPC/restore/reconnect/Cmd-N-inheritance) refuses
  BEFORE dialing when signed out (one de-duped "Sign in…" alert; CLI gets error
  text), sign-in replays the manifest (defers past the modal; double-restore
  guard `partitionForRestore`).
- `d538167e6` — TAILSCALE-STYLE BROWSER ENROLLMENT: `flow:"web"` on
  enroll/start → relay-hosted `/enroll/<nonce>` → Google → `/enroll/callback`
  (server-side exchange w/ new `GOOGLE_WEB_CLIENT_ID/_SECRET`; success page);
  agent opens the default browser; device-code is now the headless fallback.
  DEPLOYED but `web_enroll=false` until the user registers the Web client
  (redirect URI `https://<fqdn>/enroll/callback`) and provides id+secret.
- `ae77fbc1d` — agent tray Disconnect/Reconnect (`link_control.zig`: atomic
  desired-state + ResetEvent + close-unblocks-read; tooltip/status line;
  relay-mode only). Windows tray UI itself still needs on-box verification.
- `881d09a91` — chooser primary button: "New" (was "Open"); "Restore (N)" when
  the selected machine has manifest-restorable windows — restores ONLY that
  machine's entries (`restoreRemoteWindows(matching:)`).
- `71db69417` — agent SINGLE-INSTANCE guard (user hit 2 tray agents: installer
  autostart + SMB watcher both supervising): named mutex `Local\GhozttyAgentDaemon`
  (win) / flock `~/.config/ghoztty/agent.lock` (posix); daemon modes only
  (`--stdio`/`--enroll` exempt); conflict = log + exit 183. Follow-up noted:
  daemon doesn't re-read relay.env after re-enroll.
- `37cca720a` — remote sessions advertise `TERM=xterm-256color` (was
  xterm-ghostty — no terminfo on remote boxes; git/less printed "terminal is
  not fully functional" on Windows) + agent sets `COLORTERM=truecolor`.
- `a00550f84` — RENAME PROPAGATES: display name now wins over agent hostname in
  the pill AND `AXGhosttyMachine` (ztabby consumes it); rename posts
  `.ghosttyMachineDidRename` → open windows update pill/AX live; manifest
  entries renamed too; `isLocalMachine` checks name AND hostname so suppression
  survives renames.
STILL OPEN: user to register the `ghoztty-web` OAuth client + paste id/secret
(flips web enroll on); on-box Windows verification of tray items +
single-instance (installer re-run picks up the new exe); GUI verify of the
sign-out/restore cycle, New/Restore button, rename propagation, D1 pill
walkthrough.

**2026-07-03 morning — user-driven chooser polish + the SLEEP BUG (tip `a4e8e57c1`,
relay + `/dl` exe redeployed):**
- `9ce38cdaa`/`68d7baa8a` — signed-out chooser shows NO account machines (bug the
  user hit), seeded maximushome entry deleted, chooser stays reachable signed-out.
- `366f557b4` — own-machine row hidden, "New Window" header dedupe, footer
  divider, real Sign In/Out buttons, profile-photo avatar (`profile` scope —
  needs one re-sign-in to take).
- `ff9760acb` — device `hostname` field (seeded at enroll; upserted from the new
  `X-Ghoztty-Hostname` control header) + "(hostname)" subtext under renamed
  machines, Online/Offline text removed, shape-coded colorblind-safe status
  (filled vs hollow circle), fixed-width icon column alignment.
- `a4e8e57c1` — **agent keepalive**: real bug — Mac slept, relay heartbeat closed
  the control WS, the agent sat on the dead TCP link forever ("connected", never
  re-online until process restart). Now: ping every 20s, stale at 50s w/o inbound
  (wall-clock, so wake detects within ~70s), teardown via the proven
  close-unblocks-read contract, then the normal 3s redial. Proven by a
  silent-server integration test + hostname backfill observed LIVE on first
  connect. Real sleep/wake confirmation still pending (will happen organically).
- User exercised delete+revoke from the UI and (accidentally) removed
  windows-home/MaximusHome — re-enroll via the tokenless installer one-liner
  (hosted exe has enroll+keepalive now). `windows-remote` still runs the OLD
  binary (no hostname/keepalive until an installer re-run on that box).
- GOTCHA: each debug rebuild re-signs ad-hoc → Keychain permission prompt
  ("Always Allow") or full re-sign-in; and ALWAYS check app-process start time
  vs binary mtime after a relaunch — a raced quit dialog left a stale instance
  running and caused "I still see the same bugs".

**🎉 GOOGLE AUTH LIVE IN PRODUCTION POSTURE (2026-07-02 evening).** Two real
OAuth clients registered in project `ghoztty-relay` (Desktop `ghoztty-client` +
TV/limited-input `ghoztty-agent`; ids/secrets in the user's password manager;
Desktop pair also in `launchctl setenv GHOSTTY_GOOGLE_CLIENT_ID/_SECRET` for the
debug app). Relay `fcfeb0f07` (dual-aud allowlist) deployed with both pairs +
`ALLOWED_EMAILS=dzearing@gmail.com`, and **`DEV_AUTH=false`** — dev/garbage/no
tokens all 401. VALIDATED LIVE, all on the real Google + production relay:
(1) `ghoztty-agent --enroll` → user entered code at google.com/device → device
`6955eedc` "Davids-Personal-Macbook-Pro.local" created, credentials in
`~/.config/ghoztty/relay.env` (0600), agent started from relay.env alone →
ONLINE, and it appears in the chooser automatically; (2) in-app **Sign in with
Google** (chooser footer shows `dzearing@gmail.com · Sign Out`); (3) chooser
device-list fetch post-flip (only possible via ID token); (4) `+new-remote-window`
with NO `--token` → cmd.exe window on MaximusHome via `RelayAccount.resolveToken()`.
All 5 live agents stayed online through the flip (device tokens are separate).
NOTE for future sessions: the scratchpad dev client token is DEAD — client-API
curl checks need a fresh ID token (runbook §3) or the signed-in app. Rollback:
`/etc/ghoztty-relay.env.bak` on the VM (§5 of the runbook).

**Validated live 2026-07-02 (GUI, debug app):** pill hidden for local-machine
targets on BOTH paths (relay dial to a local `--relay` agent; TCP dial to
127.0.0.1) and shown for MaximusHome; WP-C2 chooser fetches the account list w/
online dots and the ellipsis menu's **Remove from Account** flow deleted
`e2e-smoketest` end-to-end (confirm alert → relay DELETE → gone from API+list);
WP-D2 restore proven TWICE (clean quit → relaunch → both remote windows
re-ATTACH; keystrokes reach the restored MaximusHome session). The updated relay
(CRUD + enroll + OIDC hardening) is DEPLOYED to the Azure VM (rename verified
live; agents auto-reconnected after restart; DEV_AUTH still on). WP-D1 pill
yellow/red flow still needs its GUI walkthrough (headless Phase-3 proof done).
GOTCHAS learned: `+new-remote-window` to an OFFLINE device blocks ~2min then
pops the modal error alert (queued dials hang behind it — dismiss via AX
`click button "OK" of window 1`); quitting with open windows shows a
"Close Ghoztty" confirm dialog (same AX click); scratchpad
`device-token.txt` was a STALE device token — a wrong-device token makes the
agent's control WS connect-then-drop in a 3s loop (dup-control kick); fresh
tokens: `mac-local` device `bdd8c0fa-…` token in THIS session's scratchpad
`mac-local-device.json`.

Validated 2026-07-01: **one-liner Windows install** (relay serves `/dl/install.ps1`
+ `ghoztty-agent.exe` via Caddy `handle_path /dl/*` → `/var/www/ghoztty-dl`) proven
on a SECOND box, the corp Cloud PC `CPC-dzear-IER1M` (device `windows-remote`) —
pill shows the real hostname. Install: `$env:DEVICE_TOKEN='<tok>'; irm
https://<fqdn>/dl/install.ps1 | iex` (re-run w/o token = binary update; don't mix
with the SMB watcher on the same box). The pill-not-local user requirement is
DONE and LIVE-VERIFIED (`9ca6b1773` + `ef84967d6`, see the 2026-07-02 block).

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
- **WP-B2 — Client sign-in (macOS). ✅ BUILT (needs the real Google client id).**
  *Goal:* in-app Google OAuth (browser) → token in Keychain + refresh; signed-in
  identity drives all relay calls. *Accept:* user signs in with Google+2FA; chooser
  loads their resources. *Shipped:* `GoogleOAuth.swift` (PKCE + loopback-redirect
  receiver + token client; endpoints injectable for tests only, relay `IssuerURL`
  pattern) + `RelayAccount.swift` (Keychain refresh token, cached ID token w/ 60s
  leeway, `signIn`/`signOut`/`email`); the single seam `RelayAccount.resolveToken()`
  feeds `RelayDirectoryClient.current()`, the Cmd-Shift-N dial, WP-D2 restore,
  WP-D1 reconnect, and IPC dials without `--token`; chooser footer shows
  sign-in/signed-in state. Client id/secret via `GHOSTTY_GOOGLE_CLIENT_ID`/`_SECRET`
  env or `GhosttyGoogleClientID`/`GhosttyGoogleClientSecret` defaults; when unset
  the footer points at `relay-oidc-setup.md`. Verified headlessly (swiftc harness
  incl. fake token endpoint + Keychain e2e; unit tests in
  `macos/Tests/Remote/GoogleOAuthTests.swift`). **Remaining:** register the Google
  client (WP-B1 runbook §1), then a live browser sign-in pass.
- **WP-B3 — Agent device-code sign-in / self-enroll.** *Goal:* agent install runs OAuth
  device-code; on sign-in the machine **upserts itself** as a resource + gets a
  revocable credential. *Files:* relay device-code endpoints; agent/connector enroll
  flow; installer UX. *Accept:* install on a fresh box, sign in, it appears in the list
  automatically (idempotent on repeat). **Relay half DONE:** `/v1/enroll/start` +
  `/v1/enroll/poll` in `relay/enroll.go` (opaque handle, poll rate limit, idempotent
  upsert w/ token rotation, same verifier + `ALLOWED_EMAILS` gate; endpoints from
  OIDC discovery so the fake issuer covers them; new env: `GOOGLE_CLIENT_SECRET`,
  optional `RELAY_BASE_URL`); tests in `relay/enroll_test.go`. **Agent half DONE:**
  `ghoztty-agent --enroll --relay=<base>` (`src/remote/agent/enroll.zig` +
  `src/remote/http_client.zig`) prints the code prompt, polls with slow_down
  backoff, persists relay.env; `--relay` falls back to relay.env for the token;
  installer source `relay/deploy/install.ps1` enrolls interactively when no
  DEVICE_TOKEN; e2e-proven vs the fake-issuer relay by
  `relay/agent_enroll_e2e_test.go`. **Remaining:** upload the new install.ps1 to
  the VM + do WP-B1 (real Google client) so the deployed relay's enroll
  endpoints stop answering 503; note: if a separate "TV/Limited Input" Google
  client is used, relay `aud` must accept both client IDs (currently single
  `GOOGLE_CLIENT_ID` for both flows).

### Phase C — Resource management (CRUD + UI)
- **WP-C1 — Relay resource CRUD. ✅ DONE.** *Goal:* add **rename** + **delete**
  (revoke credential) to the owner-scoped directory (list/create exist). *Files:*
  relay `handlers.go`/`store.go`. *Accept:* list/rename/delete via API; delete
  revokes. *Shipped:* `PATCH /v1/client/devices/{id}` (rename) +
  `DELETE /v1/client/devices/{id}` (delete + token revocation + live control/data
  conns kicked); owner-scoped 404s; tests in `relay/devices_crud_test.go`.
- **WP-C2 — Resource management UI. ✅ BUILT (GUI verify pending).** *Goal:* the
  chooser/manager lists account resources with online status; **add** (guided
  install+sign-in) and **remove** a host. Reuse spec §11.2 shape. *Files:*
  `macos/.../RemoteConnection/`. *Accept:* remove an old host from the list; it
  disappears + its credential is revoked. *Shipped:* `RelayDirectoryClient.swift`
  (list/rename/delete; base `GHOSTTY_RELAY_BASE` else Azure dev, token
  `GHOSTTY_RELAY_TOKEN` — OIDC swaps `fromEnvironment()` only); chooser refreshes
  from the relay on open, relay rows get online/offline dot + remove/rename via
  ellipsis+context menu (NSAlert flows; chooser is an AppKit modal). HTTP layer
  verified against a local relay; chooser RENDERING + Azure e2e still needs the
  deferred debug-app relaunch. "Add" guided flow deferred to Phase B (device-code).

### Phase D — Resilience
- **WP-D1 — Connection status surface. ✅ BUILT (GUI verify pending).** *Goal:*
  online/offline/reconnecting per resource in the **Activity Monitor** + status
  pill; reconnect state machine (spec §5). *Accept:* kill a host's connector →
  UI shows offline/reconnecting; recovery shows online. *Shipped:* the Zig §5.1
  `LinkState` FSM (already reaching `reconnecting` on reader-EOF/missed
  heartbeats) is now exposed over the C ABI
  (`ghostty_remote_connection_state` + `_set_state_callback`, teardown-safe via
  `Connection.clearStateHandler`); `RemoteConnection` (Swift) mirrors it and
  posts `.ghosttyRemoteConnectionLinkDidChange`; `BaseTerminalController` runs
  the per-WINDOW reconnect machine (`RemoteWindowConnectionState`:
  `connected → reconnecting(1..5, backoff 1/2/4/8/15s ≈ 30s) → connected |
  disconnected`) — each attempt re-dials (relay or TCP), `GET_CWD`-probes the
  session, and on success swaps in a fresh root surface re-`ATTACH`ed by UUID
  (the WP-D2 mechanism, same single-root-pane scope); session-gone/evicted or
  exhausted retries ⇒ `disconnected`, window KEPT. Pill dot is now
  green/yellow/red with a "— reconnecting… (N)"/"— disconnected" suffix;
  local-machine pill suppression stays, EXCEPT a degraded window always shows
  the pill (a frozen window must say why). Chooser online/offline dots =
  WP-C2; Activity Monitor cards already show live/connecting/unreachable dots
  (unchanged). Proven headlessly by `wp4-e2e` Phase 3 (agent kill →
  CONNECTED→RECONNECTING observed via the same handler seam; retry-dial to a
  fresh agent handshakes; gone-session probe fails cleanly). GUI pill
  yellow→green/red flow still needs the deferred debug-app relaunch verify.
- **WP-D2 — Window restore over relay. ✅ BUILT (GUI quit/reopen verify pending).**
  *Goal:* local manifest of open remote sessions; on relaunch re-`ATTACH` by UUID
  through the relay. *Accept:* open remote windows, quit, reopen → windows restored
  to live sessions. *Shipped:* no protocol/agent changes needed — `ATTACH`-by-UUID,
  `termio/Remote.zig` attach, and the C `session_id` plumbing already existed
  end-to-end. New `RemoteSessionManifest.swift` (JSON `[Entry]` under the
  `RemoteSessionManifest` `UserDefaults.ghostty` key; debug/release separate by
  bundle id) records `{relayBase, deviceID, sessionID, name}` per open relay
  window; the session UUID is captured by polling
  `ghostty_surface_remote_session_id` after open. Clean close (user close / child
  exit) removes the entry; quit keeps it (`AppDelegate.isQuitting` guards
  `windowWillClose`). `AppDelegate.restoreRemoteWindows()` (launch) re-dials each
  entry on a background queue (token from `GHOSTTY_RELAY_TOKEN`, NO modal alerts),
  liveness-probes the session via `GET_CWD` (gone → entry dropped silently; relay
  unreachable → entry kept for next launch), then reopens the window with
  `remoteSessionId` set ⇒ re-`ATTACH`. Protocol flow proven headlessly by the
  extended `wp4-e2e` harness (OPEN → drop conn w/o CLOSE → re-dial → probe good +
  bogus UUID → ATTACH alive → live round-trip vs the real agent). Restore covers
  relay windows opened via dial/restore paths; single root pane per window (split
  layout restore = spec §7.2, later); inherited (Cmd-N-from-remote) windows not
  yet tracked.

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
