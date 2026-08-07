# One installer: folding the standalone agent into the Ghoztty install (T417)

**Status:** design accepted 2026-08-06; implementation split into T546–T550.
**Directive (user, 2026-08-03):** "you install ghoztty on any machine, you can
transfer sessions across machines. Then we can remove the standalone agent."

This note answers the questions T417 posed, names one decision per question
(not a menu), and records the migration story. The only call routed to the
user for possible override is the serving default (decision D22); everything
else follows from verified code facts listed below.

## What the investigation established (verified 2026-08-06)

1. **Two agent processes, two session stores — and only one is persisted.**
   The app-spawned local agent (`--listen-pipe` on Windows via
   `src/apprt/win32/LocalAgent.zig`, `--listen-unix` on macOS via
   `LocalAgentManager.swift`) runs with `--port-file`/`--sessions-file`, so
   its `SessionStore` persists sessions.json, layouts.json and ring
   snapshots. The relay agent (`runRelay` in `src/remote/agent/main.zig`)
   initializes its `SessionStore` with **no `meta_path` and no
   `layouts_path`** — its sessions and layout blobs are in-memory only and
   die with the process.
2. **Therefore the standalone installer was never the real gap.** Even with
   the agent MSI on a box, the sessions a user actually cares about — the
   terminals in their Ghoztty windows — live in the *local* agent's store,
   which the relay path cannot see. Browsing that machine from another device
   (T318–T320/T336) reaches the relay agent's separate, empty-unless-remotely-
   populated store. "Install Ghoztty → transfer sessions" fails today for a
   deeper reason than packaging: the serving process does not hold the
   sessions worth transferring.
3. **A transport mode is exclusive per process.** `Mode` in
   `src/remote/agent/main.zig` is a `union(enum)`; one invocation serves one
   transport. Coexistence today means two processes with distinct
   single-instance guards (`local[-debug]` for `--listen-pipe`, the legacy
   `relay` guard for `--relay` — T89d1; the macOS `--listen-unix` agent still
   takes the relay guard, a latent Mac collision flagged in the code).
4. **The HKCU Run key is already contested.** The app writes
   `HKCU\...\Run\GhozttyAgent` → `"...\ghoztty-agent.exe" --listen-pipe=...`
   (`LocalAgent.writeAutostart`, refreshed every run once persistence
   engages); the standalone MSI writes the **same value name** →
   `"...\Ghoztty Agent\ghoztty-agent.exe" --relay=<url>`
   (`relay/deploy/msi/ghoztty-agent.wxs`). On a box with both, whichever
   wrote last owns logon autostart — on a box that runs Ghoztty daily, the
   app wins and the relay agent silently stops autostarting.
5. **The Windows app install already ships the binary.** `ghoztty-agent.exe`
   is a required sibling of `ghoztty.exe` (T89h; `dist/windows-installer/
   build-msi.sh` hard-fails without it). The standalone MSI adds nothing the
   box does not already have except the `--relay` launch mode and the
   credential bootstrap.
6. **The credential is already shared state at a neutral path.**
   `relay.env` lives at `%LOCALAPPDATA%\ghoztty\relay.env` /
   `~/.config/ghoztty/relay.env` (`enroll.relayEnvPath`) — outside both
   install dirs, deliberately preserved by the MSI across
   install/upgrade/uninstall, and hot-reloaded by the running agent
   (`relay_creds.zig` watcher).
7. **macOS has no serving capability at all** — no Mac analog of the agent
   MSI exists and `LocalAgentManager` never passes `--relay`. The Mac half is
   new capability, not consolidation.

## Decision 1 — one process, both transports, one store

**The session-persistence agent grows an optional relay uplink in the same
process, serving the same `SessionStore` that backs the local pipe/unix
socket.** Not: one install managing two processes.

Why this and not two processes: fact 1 is decisive. With two processes there
are two stores, and the user's sentence requires the *local* store to be
reachable from other machines. Bridging two processes (a session-handoff or
proxy protocol between local and relay agents) would be strictly more
machinery than adding a second listener to the process that already owns the
sessions — and the relay uplink is already architected as a detachable
subsystem: `runRelay`'s control loop only dials out, reconnects with backoff,
and never owns session lifetime ("sessions survive control drops" is an
existing guarantee). Grafting that loop onto the listen-pipe/unix daemon
changes what the uplink *reaches*, not how sessions live.

The reconnect-storm worry from T417 ("does relay churn drag local PTYs
down?") resolves the same way: the control link is one background thread plus
per-session data dials; a relay outage costs reconnect attempts on that
thread and nothing else. The local pipe accept loop, the PTY children and the
rings are untouched — exactly as they already are during a control drop in
today's relay agent.

Consequences folded into T546:

- The consolidated daemon keeps the **local** single-instance guard. The
  legacy relay guard retires with the standalone agent (and the latent Mac
  guard collision from fact 3 dies with it).
- Uplink state is **persisted agent-side** (a small sharing config in the
  agent state dir), not a Run-key flag: the Run key command stays exactly
  today's `--listen-pipe/--listen-unix` composition, and the agent decides at
  startup — and on a hot toggle, via the same watch pattern relay.env already
  uses — whether to raise the uplink. This keeps the app's
  `agentCommandLine` single-source rule intact and means enabling sharing
  never needs a Run-key rewrite.
- **No self-update and no tray in this mode.** The agent binary is owned by
  the app install (T89h) and updated by app delivery; the relay-hosted
  self-updater would fight it. The tray (including tray-account sign-in) was
  the standalone agent's only UI; the product's account UI is the machine
  chooser (T141), which both platforms already have. Headless is also the
  only symmetric shape — the Mac agent never had a tray.
- Sessions created over the relay land in the same persisted store, so they
  gain sessions.json/ring persistence for free — an upgrade over today's
  in-memory relay store.

## Decision 2 — enrollment and serving live in the machine chooser

The account row (macOS `Cmd-Shift-N`, Windows `Ctrl+Shift+N`; win32
`RelayAccountRow.zig`) gains a **"Share this machine" toggle** next to
sign-in. Toggling on: run device enrollment if `relay.env` is absent (the
existing `enroll.zig` browser OAuth, driven off the UI thread the way sign-in
already is), persist sharing state, poke the agent to raise the uplink.
Toggling off: lower the uplink, keep the credential. **No new CLI verb** —
T141 removed `+relay-login`/`+relay-logout` precisely because account
affordances are GUI-on-both-platforms, and "share this machine" is the same
kind of thing. Windows UI is T547, macOS is T548.

## Decision 3 — serving is opt-in (D22 filed for override)

Sharing is **off until the user flips the toggle**, per machine. Rationale:
consolidation makes the uplink expose the user's *real local terminals*, not
a separate remote-only store — sign-in today means "connect out", and a
sign-in that silently starts serving shells is a security regression on any
box the user signs into merely to reach other machines. The cost — the
user's sentence becomes "install, sign in, flip one switch" — is mitigated
in-place: after sign-in the account row shows the unshared state exactly
where the user is already looking. D22 records both options with the
recommendation; if the user picks default-on, T547/T548 change one default
and the note's rationale flips, nothing structural moves.

## Decision 4 — migration: adopt, then uninstall (T549)

On a box with the standalone install (detected by its ARP/product
registration or `%LOCALAPPDATA%\Programs\Ghoztty Agent\`):

1. **Preserve `relay.env`** — nothing to do; it lives outside both install
   dirs (fact 6) and the consolidated agent reads the same path. No
   re-enroll, ever.
2. **Mark sharing enabled** — the box was serving; adoption must not turn
   that off. This is the one case where the toggle starts on.
3. **Stop the standalone agent at zero live sessions.** Its store is
   in-memory (fact 1): stopping it mid-session kills real remote shells. The
   idle-swap policy already exists in the agent's self-updater ("swap only
   when the store has zero live sessions") and adoption reuses it.
4. **Uninstall the product** (per-user msiexec, matched by UpgradeCode
   `7143BA66-FD7B-4D45-8555-E946D2141912`, never by name) and let the
   app-owned Run key be the only `GhozttyAgent` value — which also ends the
   fact-4 collision.

## Decision 5 — what retires, what must keep answering (T550)

Deleted once T547+T549 ship: `relay/deploy/msi/` (wxs + its build script),
`relay/deploy/install.ps1`, `relay/deploy/publish-agent.sh`,
`scripts/deploy-windows-agent.sh`, and the self-update + tray-account code
paths that exist only for the standalone install. Docs pointing at them
(`relay/README.md`, `remote-relay-roadmap.md`,
`remote-machines-CONTINUATION-3.md`, `.claude/commands/release.md`) get
updated in the same change.

The hosted `https://<relay>/dl/install.ps1` URL **keeps working**: the
hosted copy becomes a stub that prints where to get Ghoztty (the app install
now carries the agent). A pasted one-liner from an old doc must inform, not
404.

## Split tasks

| Task | Seat | What |
|---|---|---|
| T546 | any | One process serves local transport + relay uplink over one store |
| T547 | win | "Share this machine" toggle + enrollment in the Windows chooser |
| T548 | mac | Same toggle + app-managed serving on macOS (new capability) |
| T549 | win | Adopt + retire an existing standalone install (idle-stop, uninstall, Run-key ownership) |
| T550 | win | Retire the MSI publishing pipeline; keep `/dl/install.ps1` answering |

Dependencies: T547/T548/T549 → T546; T550 → T547+T549. The Mac half (T548)
does not block Windows retirement (the standalone installer is
Windows-only), but T417's parent goal is not done until both seats serve.
