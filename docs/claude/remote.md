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

Once signed in, `+new-remote-window --relay/--device` with **no** `--token`
uses the account's session token (token-resolution order: explicit `--token`
→ signed-in account → `GHOSTTY_RELAY_TOKEN`). A pre-brokered store
(refresh-token shape) is treated as signed out — sign in once more to migrate.

