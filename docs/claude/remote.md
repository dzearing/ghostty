# Remote machines: dialing, the connection pill, relay sign-in

> Progressive-disclosure doc routed from `/CLAUDE.md`. Load this when working
> on or scripting remote windows (`+new-remote-window`), per-host defaults,
> the titlebar connection pill, or relay/Google account sign-in. Browsing and
> resuming a machine's sessions (the chooser, Restore All, the machine
> connection pool) live in `docs/claude/sessions.md`.

### `ghoztty +new-remote-window`

Open a terminal window whose shell runs on a remote machine via a `ghoztty-agent`
reached over TCP. Drives the same flow as the Cmd-Shift-N "New Remote Window" menu
action (dial the agent, build a remote surface, open the window), so the remote
path is scriptable/testable from the shell.

```
ghoztty +new-remote-window --host=<host> --port=<port> --relay=<base> --device=<id> --token=<tok> --working-directory=<path> --shell=<path> --command=<cmd>
```

- `--host`: Agent host (DNS name or literal IP). Required unless dialing via `--relay` + `--device`.
- `--port`: Agent TCP port. Required unless dialing via `--relay` + `--device`.
- `--relay` + `--device`: Dial the enrolled agent `--device=<id>` through the
  rendezvous relay at `--relay=<https-base>` instead of direct TCP (takes
  precedence over `--host`/`--port` when both are given). Auth bearer:
  explicit `--token=`, else the signed-in account (macOS Keychain; on Windows
  the DPAPI account store, see Relay account sign-in below), else the
  `GHOSTTY_RELAY_TOKEN` env var — with no source the command fails with "not
  signed in".
- `--working-directory`: Working directory ON THE REMOTE MACHINE for the new
  session. Overrides the machine's per-host default.
- `--shell`: Shell ON THE REMOTE MACHINE to run (e.g. `wsl.exe`,
  `powershell.exe`, `/bin/zsh`). Overrides the machine's per-host default.
- `--command`: Command to run in the remote session instead of an interactive
  shell. Runs through the resolved shell using its native convention (POSIX
  `-lic`, cmd `/c`, powershell/pwsh `-Command`, wsl `--`).

```bash
ghoztty +new-remote-window --host=127.0.0.1 --port=7777
ghoztty +new-remote-window --host=winbox --port=7777 --shell=wsl.exe --working-directory='C:\dev'
```

The remote session uses the remote machine's own default shell and working
directory (the local shell/pwd are NOT forwarded — they would not exist on a
different OS such as a Windows ConPTY agent) unless a **per-host default** or
an explicit flag says otherwise. Per-host defaults (default working directory
+ default shell per machine) are edited in the machine chooser (Cmd-Shift-N on
macOS / Ctrl+Shift+N on Windows → row `⋯` menu → "Host Settings…"), keyed by
relay device id or `host:port` — persisted in UserDefaults on macOS and in
`%LOCALAPPDATA%\ghoztty\host_defaults.json` on Windows (`-debug` suffixed for
debug builds; `GHOSTTY_HOST_DEFAULTS` overrides the path outright, which is how
the acceptance test avoids the real file). Both are LOCAL preferences, never
account resources: a sign-out or a 401 must not lose a user's shell choice.
Explicit `--working-directory`/`--shell` flags override them per window. New
tabs/splits on a remote window use the per-host default shell too — but NOT its
working directory, since their cwd inherits from the parent pane and a default
must not yank a split away from where its parent is.

### The connection status pill (GUI, both platforms)

A remote window's titlebar carries a small **connection pill**, because a
dropped link is otherwise invisible until you type into a pane and nothing
happens. Three states, driven by the per-window reconnect ladder:

| State | Shows | Clickable |
|---|---|---|
| connected | a **green dot**, no words | no |
| reconnecting | an **amber dot** + `Reconnecting… n/5` | no |
| disconnected | a **red** capsule: refresh glyph + **Reconnect** | yes — re-dials now |

Connected is deliberately wordless: a chip that permanently reads "Connected"
is chrome that says nothing, so the pill only grows words when something is
wrong. That is also what keeps the three states apart without relying on hue
(WCAG 1.4.1) — they differ in whether there is text and in what it says.
Clicking **Reconnect** starts from ANY disconnected tier, terminal included,
resets the poisoned-session breaker (a click is fresh evidence) and dials
immediately instead of waiting out a backoff. It re-attaches when the session
survived, and **opens a fresh shell in every pane when it did not** — a rebooted
box, a restarted agent — rebuilding the window IN PLACE, so the split layout the
user arranged and every pane's `$GHOZTTY_PANE_ID` come through the swap
unchanged and only the contents are new (T611).

That second answer is licensed by the CLICK and by nothing else. The automatic
ladder still goes terminal on a session it can no longer find: replacing a grid
somebody arranged with a wall of empty prompts is a surprise unless they asked
for it, and the pill's button is how they ask. So "did the user ask" rides the
ATTEMPT — set when the ladder starts, carried out to the redial worker and back
with its reply — rather than being read off the window when the dial lands,
where a second drop arriving mid-dial would answer for a ladder it did not
start. The whole end-of-attempt rule is one pure function
(`remote_reconnect.decideAttempt`) precisely because the two halves of it were
each correct and separately tested for months while the driver called them with
a hardcoded "no". Acceptance: `test/win32/remote-reconnect-fresh.ps1` (layout,
pane ids, and both panes LIVE across the swap; the automatic arm as the
control), plus section 4 of `test/win32/remote-pill.ps1` (the pill goes green
again).

**A relay re-dial carries the bearer the window was opened with** (T1276).
Credentials resolve in the same order everywhere else does — the signed-in
account's relay session token first, because that tier renews, then
`GHOSTTY_RELAY_TOKEN` — and since T1276 the window's OWN dial token is the
fallback behind both (`Window.RemoteMachine.relay.token`, chosen by
`remote_reconnect.chooseRelayToken`). Without it every window opened by
`+new-remote-window --relay=… --token=…` was un-reconnectable: the store is
empty on that path, the ladder read the emptiness as SIGNED OUT, and the window
went terminal about three seconds after the far agent died without ever opening
a socket. Genuinely no credential anywhere is still terminal — retrying cannot
sign anyone in — and so is a relay that REJECTS the bearer (401/403, one attempt,
no ladder). "The device is offline" is not that: the relay answers a dead device
409/502, which is an ordinary unreachable-machine retry. Acceptance:
`test/win32/remote-reconnect-relay.ps1` (climb, recovery onto the same session,
and the 401 arm), plus section 6 of `test/win32/ipc-relay.ps1`, which now
asserts the window is still recoverable rather than merely no longer connected.

macOS renders this as Mac's machine pill plus a separate status capsule
(`MachinePillView.swift`); Windows merges the two into one capsule in the
caption band (T367) — the band already hosts the "…" button, so the affordance
costs no terminal rows, and the pill shares that button's vertical center. A
**quiet** win32 pill is not a button and stays part of the drag region, so it
never leaves a dead patch in the titlebar. Windows geometry, wording and
contrast floors: `src/apprt/win32/remote_pill.zig` (asserted at
1.0/1.25/1.5/2.0); acceptance: `test/win32/remote-pill.ps1`. The win32 pill
does not yet name the machine or open the Activity Monitor on click the way
Mac's does — filed as T610.

### Relay account sign-in (GUI only — there is no CLI verb)

Signing in to the Google account that authenticates relay connections is a
**GUI affordance on every platform**: the machine chooser's account row
(Cmd-Shift-N on macOS, Ctrl+Shift+N on Windows) shows the signed-in email with
a **Sign Out** button, or a **Sign in with Google…** button when signed out.
There is deliberately **no `+relay-login` / `+relay-logout` CLI command** —
Windows briefly had that pair and it was removed (T141), because a verb that
exists on one platform's CLI and not the other's is exactly the divergence this
project does not ship. If you are looking for a CLI way to sign in, there isn't
one by design; open the chooser.

Both platforms use the same **relay-brokered (BFF) OAuth**: PKCE + a loopback
redirect obtain the authorization code locally, the code goes to the relay's
`/oauth/exchange` (the relay holds the client secret and talks to Google
server-side), and the returned opaque **relay session token** + expiry + email
+ relay base are stored — macOS in the Keychain, Windows **DPAPI-encrypted** at
`%LOCALAPPDATA%\ghoztty\account.dat` (owner-only DACL). No Google token or
client secret ever touches the machine. The flow runs on a background thread so
the window never blocks while the browser is open; the app renews the session
at the stored relay via `/oauth/renew` as it nears expiry (renewal rotates the
token and the rotation is persisted). Sign-out best-effort revokes at the relay
(`/oauth/signout`, which also destroys the relay-held Google refresh token)
before deleting the local store.

#### Signing out revokes THIS machine (T1421)

An account's **user session** and a machine's **device enrollment** are two
independent relay credentials, and `/oauth/signout` revokes only the session —
deliberately, because an account may own headless hosts that no app is signed in
on. That independence was also a hole: signing out in the app running ON an
enrolled machine left the machine listed, online and bridgeable from every other
client on the account, with live sessions still visible through "See Activity".
Sign-out looked like "this machine is no longer mine" and wasn't.

The rule on both platforms: **app sign-out is a hard revocation of the machine
the app runs on, when — and only when — that enrollment belongs to the account
signing out.** On Windows `relay_signin.signOut` reads the local
`relay.env`, asks `GET /v1/agent/whoami` whose machine it is, and on a match
`POST`s `/v1/agent/deenroll` with the machine's OWN credential; the device row is
deleted, every live connection is severed, and the local credential file goes
with it. The decision itself is pure and lives in **`src/remote/relay_revoke.zig`**
(`decide` → `.none` / `.revoke` / `.foreign` / `.unknown`), so every branch is
unit-tested in the `none` lane.

Two consequences worth stating rather than rediscovering:

- **`.unknown` is never guessed.** A credential exists and the relay could not
  say whose it is → the sign-out ABORTS and the account stays **signed in**,
  because reporting "signed out" while the machine is still reachable is the bug
  itself. The chooser says so and offers **Sign Out Anyway**
  (`SignOutMode.force`), which does not re-run the revocation — the Mac's
  `f3b1e5fb5` removed exactly that second pass, since it only makes the user wait
  out the same timeouts twice.
- **Identity is what the relay says, never the hostname.** Hostnames collide and
  the failure mode is deleting somebody's other machine. A machine enrolled to
  another account is `.foreign` and left completely alone; the chooser's existing
  "Remove from Account" is the same hard revocation for a machine you can see but
  are not running on.

`relay.env`'s `RELAY_BASE` legitimately carries a `ws://` / `wss://` spelling
(`relay_creds.baseMatches` strips all four schemes for that reason), so
`relay_revoke.normalizeBase` rewrites it before any HTTP call, and a `RELAY_BASE`
that is missing or unparseable falls back to the account's own relay rather than
destroying the one credential that could revoke the machine.

#### A forced sign-out finishes itself later (T1424)

"Sign Out Anyway" used to be the end of the story: the user was told, honestly,
that the machine stayed connected to the account — and nothing ever tried again.
The machine remained listed, reachable and streamable from every other computer
on the account until they remembered to go to one of those computers and remove
it by hand, which nobody does. A security decision they had already made was
left depending on a chore.

So `SignOutMode.force` now **arms a pending revocation** instead of abandoning
one: `pending-revoke.json`, written beside `relay.env` (same directory, so
`GHOSTTY_RELAY_ENV` carries both), holding the device token, the normalized
relay base, the account that signed out, and when it was armed. It is atomic and
owner-only ACL'd, exactly like the credential it sits next to.
`src/remote/relay_revoke_pending.zig` owns it.

- **The retry authenticates as the DEVICE.** By then the user is signed out and
  there is no session to speak with; `POST /v1/agent/deenroll` takes the
  machine's own bearer. That is why the local credential is KEPT on the forced
  path — deleting it would destroy the only thing that could ever revoke the
  machine.
- **It runs at every launch and on a backoff while the app runs**
  (`retryAsync`, called from `App.startup` and again the moment a record is
  armed): 0s, 5s, 15s, 60s, 5min, then every 15min. There is no local event for
  "the relay became reachable" — an adapter coming up is not the same question —
  so the capped backoff is what bounds "still enrolled" to minutes instead of
  until the next relaunch.
- **Only an answer clears it.** `nextAfter`: 204/200 → cleared, revoked. 401 →
  cleared, and **nothing else concluded** — a POST that landed with a lost
  response is indistinguishable from this, and reading it as proof of a
  completed revocation is how the Mac seat's first cut also cleared the
  machine's suspension record, so the user signed back in to find the machine
  simply gone (`f3b1e5fb5`, and the reason T1425 must not touch that branch).
  Anything else — no answer, a 5xx, a 404 from a relay with no such route —
  stays ARMED. Giving up after N tries means a closed lid strands the machine
  forever.
- **Signing back in cancels it — but never on the email alone.** Re-adopting
  this machine has to win, or the retry would revoke the machine the user just
  signed back in on. What settles it is a fresh probe of the credential
  (`relay_suspend.pendingAction`), not the fact that the same address signed in:
  a revocation whose response was lost is indistinguishable from one that
  failed, so an email-only cancel can leave a dead token in `relay.env`, the
  machine off the account, and nothing left to notice. Confirmed alive cancels,
  confirmed dead drops the file and re-enrolls, an unanswerable relay stays
  ARMED.

Acceptance is section 9 of `test\win32\relay-account.ps1`, which arms the
record against a port that is DEAD at sign-out time and brought up afterwards —
the only version of the test that can tell an armed retry from a lucky first
attempt. It covers all three: completed with no relaunch, completed at the next
launch, and cancelled by signing back in.

#### The AGENT completes it, and takes the machine offline first (T1427)

The app is not what keeps this machine on the account. `ghoztty-agent` is: it
holds the same `relay.env` credential and keeps a control WebSocket up, which is
what makes the machine listed, reachable and streamable from every other
computer — and it runs when no Ghoztty window is open at all. So the retry above,
which only the app drove, left the disowned machine online until somebody
happened to launch Ghoztty here. For the sign-out that means "I am done with this
box", that is never.

`src/remote/agent/revoke_watch.zig` is the agent's half. It polls for the record
on the same 5s cadence the credential watcher uses, and it does two things in
this order:

1. **Park the uplink** (`LinkControl.disconnect`). No network needed, so the
   window during which a disowned machine is reachable ends at the next tick
   rather than at the next successful de-enroll. Local sessions are untouched —
   a control drop only ever DETACHes them.
2. **Then hand the completion to `relay_revoke_pending.retryAsync`.** The rules
   stay in one place; nothing about a 401 is re-decided here.

Parking gives up the one signal the agent had that the app lacks — a live link
knows when the relay comes back. That is deliberate: the link being up IS the
hole, and the capped backoff already bounds "still enrolled" to minutes.

- **`verdict` is the pure rule** (armed, held, the credential relay.env now
  holds). Armed → hold. Not armed and never held → not this module's business.
  Not armed but held: the credential's presence is what separates a completed
  revocation (gone — keep holding, a redial against a dead token helps nobody)
  from a sign-back-in or a re-enroll (present — release). The two release cases
  collapse on purpose: both leave the machine legitimately on an account, and
  comparing tokens would buy no decision.
- **One veto, checked first.** `SharingUplink.reconcile` already writes the
  desired link state every tick from `sharing.json`; a second writer would have
  produced a machine online half the time. The revocation check is now the first
  thing that reconciler does and it returns on a hold, and the watcher parks but
  never resumes there (`owns_resume = false`). In `--relay` mode nothing else
  writes that state, so there the watcher owns both edges.
- **Both processes may retry the same record, safely.** One gets 204 and the
  other 401, which `nextAfter` already maps to "stop, conclude nothing else";
  the record delete and the credential delete are both idempotent. No
  cross-process lock, and "exactly once" still holds where it must — the relay
  deletes the device once.

Acceptance is section 5 of `test\win32\agent-sharing-uplink.ps1`: the dial
stream stops within a tick of `pending-revoke.json` appearing, the
`POST /v1/agent/deenroll` arrives at the loopback relay **from the agent with no
app running**, the record survives a relay that answers nothing, and clearing it
brings the uplink back. T1430 covers the one branch it does not reach — the
`--relay` daemon's release edge.

#### Sign-out SUSPENDS the machine; signing back in restores it (T1425)

Revoking the machine is the half a security review asks for. The half the user
meets is that their own computer vanished from the machine list on every other
device they own — and signing back in did not bring it back. The only way home
was re-running browser enrollment by hand, which is not a thing most people know
exists, so sign-out was a one-way door.

So a sign-out **suspends** rather than discards. `suspended-enrollment.json`
lands beside `relay.env` (same directory rule as the pending record) holding the
relay, the machine's relay-side display name and the account that owned it, and
`src/remote/relay_suspend.zig` owns it. Signing back in with the same account
re-enrolls this machine — `POST /v1/client/devices` with the SESSION token, so
no second trip through a browser — and writes the fresh credential back to
`relay.env`, which a running `ghoztty-agent` adopts within one watcher tick and
reconnects with. Nothing is restarted.

- **It holds no secret**, which is why it is not ACL-hardened the way
  `pending-revoke.json` is: the credential it describes is dead, and the retry
  that still needs a live one keeps it in `relay.env` where it already was.
- **The record is written BEFORE the de-enroll POST.** The relay is about to
  delete the only copy of this machine's name, and a lost response would leave
  it unlearnable (the retry sees a bare 401). Writing it first costs nothing on
  a revocation that fails: the restore drops a record whose machine turns out to
  be enrolled already. A sign-out forced through against a relay that never
  answered records the suspension with NO name, and the restore falls back to
  this machine's hostname — the name a fresh enrollment would have given it.
- **Four refusals**, each a `restoreAction` branch: a different account never
  inherits the machine; restore is refused across relays (a session on relay A
  cannot mint a device on relay B — revocation makes the opposite trade because
  failing safe there means revoking *more*); a credential that arrived meanwhile
  (a manual `--enroll` while signed out) is never overwritten; and a pending
  revocation is settled on a probe, per the bullet above.
- **Retried at every launch while signed in**, not only at sign-in
  (`launchAsync` — the ONE entry point, so a pending retry can never race a
  restore for the same credential). A re-enroll can fail transiently — a 5xx,
  the account at its device limit (`409` → `error.QuotaExceeded`), a moment
  offline — and a machine that never comes back is not something a user would
  think to fix by signing out and in again.

Acceptance is section 10 of `test\win32\relay-account.ps1`: sign out and back
in on the fake relay and watch the machine return under its old name with a
fresh credential; a restore against a DEAD port that stays armed and completes
at the next launch once the port answers; and another account's suspension
dropped unread with no enroll attempted.

Still open, split out of the Mac change: **T1426** (the chooser saying a machine
is still connected to an account it was signed out of).

The Google OAuth client id is baked into the build via `-Dgoogle-client-id`
(public — it appears in the browser URL), overridable with
`GHOSTTY_GOOGLE_CLIENT_ID`; a dev build with neither reads a git-ignored
`google-client-id.txt` at the repo root (or the older `macos/` path). The relay
comes from `GHOSTTY_RELAY_BASE`, else the built-in default. Shared
implementation: `src/remote/relay_signin.zig`; win32 UI in
`src/apprt/win32/RelayAccountRow.zig`.

**Which id a BINARY carries is readable, and the delivery reads it** (T795).
`ghoztty +version` prints, under `Build Config`, either
`relay sign-in : configured (<id>)` or
`relay sign-in : not configured (no google client id baked in)` — the bake, not
what `resolveClientId` would resolve, so the line answers "what do these bytes
carry" rather than "what would this shell do". `scripts\deliver-windows-build.ps1`
announces the staged build's state once up front (a build that cannot sign in is
a loud `WARNING`, never a failure — the id is build configuration a box may
legitimately not have) and then compares every delivered `ghoztty.exe`/`.com`
against staging. A binary from before T795 prints no such line, which reads as
*unreported* and asserts nothing.

Two ways a build ends up unable to sign in, both closed by T795:

- **Published artifacts.** `release.yml`'s macOS job has passed
  `-Dgoogle-client-id` from the `GOOGLE_CLIENT_ID` repository secret since T93;
  `release-windows.yml` passed nothing, and a CI runner has no
  `google-client-id.txt` to fall back on — so every published MSI and portable
  ZIP shipped with sign-in unavailable while the DMG built from the same tag
  worked. Both workflows now bake the same secret, threaded through
  `dist/windows-installer/build-release-artifacts.sh`. That script passes the
  flag **only when the variable is non-empty**, which is load-bearing: an
  explicit `-Dgoogle-client-id=""` satisfies the build option and short-circuits
  the fallback to the repo-root file.
- **On-box builds.** Drop the id (`docs/design/relay-oidc-setup.md` step 10
  stashed it in a password manager) into `google-client-id.txt` at the repo
  root — D72's answer — and every local and delivered build picks it up with no
  flag to remember. Until it exists, this box's builds keep saying sign-in is
  unavailable, by design rather than by dead button.

**A build with no client id says so instead of offering the button** (T747). No
id resolves ⇒ `signIn` can only ever answer `NoClientId`, so the account row
draws no control at all — the sentence *"Google sign-in isn't set up in this
build"* takes the whole band, and the chooser's footer hint carries the remedy
(the two ways to supply an id, plus `docs/design/relay-oidc-setup.md`). Mac has
always branched this way (`RelayAccount.isConfigured` →
`MachineChooserView.accountRow`); win32 drew the enabled button unconditionally,
so on the shipped build — which bakes no id — every press failed instantly with
no browser and no visible reason, and the whole relay path read as broken. The
state is `chooser_layout.AccountState.unconfigured`, and it only ever replaces
the SIGNED-OUT case: a stored account is still offered Sign Out (which needs no
client id) and an in-flight sign-in still describes itself. What hid this for so
long is that the test always supplied one: every GUI section of
`test/win32/relay-account.ps1` sets `GHOSTTY_GOOGLE_CLIENT_ID`, so the state
every real user meets was never once exercised. Its section 8 now launches
without one, and ends with the configured relaunch as its control.

Launching "without one" takes a knob, because on a configured seat the id is
BAKED in and no environment variable can unbake it (Windows cannot even hold a
present-but-empty variable). `GHOZTTY_RELAY_NO_CLIENT_ID=1`
(`relay_signin.env_force_unconfigured`) makes `resolveClientId` find nothing —
env id and bake alike — so the unconfigured experience is measurable on every
seat. Tests and automation only, same shape as `GHOZTTY_ENROLL_NO_OPEN`. Before
T918 the section instead SKIPPED itself when `macos/google-client-id.txt`
existed, which read only the legacy path while `Config.zig` prefers the
repo-root spelling the Windows seat is told to use: a documented setup produced
six phantom FAILs, and a seat that fixed the path would have lost the coverage
to a skip instead — on exactly the seats that have sign-in configured, which is
the population that hid T747 in the first place.

Once signed in, `+new-remote-window --relay/--device` with **no** `--token`
uses the account's session token (token-resolution order: explicit `--token`
→ signed-in account → `GHOSTTY_RELAY_TOKEN`). A pre-brokered store
(refresh-token shape) is treated as signed out — sign in once more to migrate.

