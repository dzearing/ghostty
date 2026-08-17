# Session persistence & the ghoztty-agent

> Progressive-disclosure doc routed from `/CLAUDE.md`. Load this when working
> on session persistence, `ghoztty-agent`, restore/re-attach/relaunch paths,
> the machine chooser (browse/resume/Restore All, session CPU meters, the
> machine connection pool), or ANY change to the app<->agent wire protocol —
> the agent contract at the end of this file is mandatory reading for that.

## Session Persistence

Terminal processes can be made independent of the GUI app so they survive app
crashes, quits, and binary upgrades (and relaunch across reboots / agent
crashes). It is **on by default** (disable with `session-persistence = off`).

- `session-persistence = off|on` (macOS + Windows, default `on`). When `on`, new local
  windows/tabs/splits run their shell under the local `ghoztty-agent` (found or
  spawned on demand) instead of directly under the app process, so the child
  processes outlive the app. On next launch the app re-attaches: layout, split
  ratios, titles, working dirs, and gap-filled scrollback come back with the
  **same PIDs** (no restart) as long as the agent stayed alive.
- `session-relaunch = notify|auto|prompt` (default `notify`). Only matters across
  an **agent** restart (reboot / agent upgrade), where the child is gone but its
  metadata was materialized from disk as a relaunchable tombstone.
  **A recorded command is never re-executed by default** — it was recorded in a
  world that no longer exists, and nobody asked for it twice.
  - `notify` (default) — the pane comes up on a **fresh shell** in the session's
    recorded working directory (a missing directory falls back to `$HOME` /
    `%USERPROFILE%` rather than failing the pane), with a notice above it
    naming the command that WAS running so it can be copied and re-issued
    deliberately. The notice is written **twice on purpose**: as selectable
    terminal text, and as a sticky **pane banner** — a ConPTY shell's startup
    repaint (cmd.exe's `ESC[H ESC[2J`) erases the former, and the banner is the
    copy that survives it. The dead tombstone is retired (fire-and-forget
    `CLOSE_SESSION`) so it does not accumulate in `sessions.json`.
  - `auto` — respawns the recorded command in-place with a
    `--- session restarted ---` divider.
  - `prompt` — leaves the pane in its exited state for the user to decide.

  E2E: `test/win32/session-relaunch-notify.ps1`.

**An agent that dies while the app stays up is recovered IN PLACE** (T145), and
**a recovery that cannot reach an agent keeps trying** (T723). A dropped shared
link is judged before it is acted on — only a link still down after
`agent_recovery.settle_ms` (5s) counts, because the transport returns to
`connected` on the next authentic packet and the Mac shipped this without a
settle window and had recovery destroy the sessions it had just re-attached
(`e65cfa4d5`). A confirmed drop re-dials (spawning a fresh agent if needed) and
rebuilds each local window's split topology onto the new connection: same window,
same layout, same pane ids, no app relaunch.

The re-dial can fail, and a WEDGED agent — alive, so its single-instance guard
blocks a replacement, but never completing a handshake — is how. That abort used
to be terminal, and silently: the settle watch opens on a link DOWN EDGE, and
`Connection` fires its observer only when the state actually CHANGES, so a link
already in `reconnecting` never produced a second edge (the only transition left
is to `dead`, which needs a server-sent DETACHED frame a wedged or killed agent
never sends). Nothing re-armed anything and the panes stayed frozen until the
user quit — the exact failure in-place recovery exists to remove. An abort now
arms a **bounded, backed-off retry** (`agent_recovery.retry_delays_ms`, ~90s over
six attempts), which stands down the moment the old link heals on its own — the
abort left the panes riding it, since recovery retires a connection only when the
re-dial SUCCEEDS, so a heal is the whole cure and rebuilding over it would replace
working panes. When the schedule is spent the app says so in the pane itself, as a
banner naming the state and the remedy; a pane already carrying a banner keeps it
(T422's rule — the user's banner holds live state and this notice is not entitled
to that slot). Acceptance: sections I and J of `test/win32/agent-recovery.ps1`
(the wedge held past the re-dial, ended by a kill and by a resume). The Mac half
is T763.

**A refused pane says why, immediately** (T469). When the agent will not open a
session — it is at its live-session cap, it is out of memory, or the shell/
command could not be spawned at all — it answers `OPEN_FAILED` (0x06,
`{reason, detail}`) instead of dropping the request, and the pane paints a
plain-words message naming the cause and what to do about it. Before this there
was no frame for "I will not open this": the app's parked OPEN waited out its
full 10 s `rpc_open_timeout_ns` and then blamed `error.Timeout` and "exhausting
a system resource" — a sentence true of no failure a user can act on. Because
by-type OPEN RPCs serialize on one mutex, a window of N panes paid that 10 s N
times, in turn, for panes that were never coming.

- `reason` is a **stable machine token** (`session_cap`, `spawn_failed`,
  `out_of_memory`, `malformed_request`), never prose, and the app owns the
  sentence — the agent outlives the app talking to it, so an agent that shipped
  wording would pin the text to whichever build happens to be resident. An
  unknown token from a newer agent renders a generic sentence rather than being
  echoed raw or dropped. Mapping: `src/termio/open_failed_notice.zig` (pure,
  asserted in the none lane); the paint is `termio.Thread`'s existing failure
  path, which a backend can now pre-empt via `Backend.bringUpNotice()`.
- Capability-gated on `open_failed`, because a new opcode is a **fatal framing
  error** to a peer that does not know it. Both skew directions degrade to
  exactly the pre-T469 behavior (silence, then the client's own timeout, then
  the generic message) — never a garble, never a wedge.
- Two agent test seams make the refusal reproducible from one tree, which is
  why this path shipped silent for as long as it did:
  `GHOSTTY_AGENT_MAX_SESSIONS=<1..256>` (also `--max-sessions`) lowers the live
  cap so two panes reach a genuine `error.TooManySessions`, and
  `GHOSTTY_AGENT_SUPPRESS_CAPS=<comma list>` makes this binary advertise an
  older agent's HELLO so the fallback can be watched happening. The app spawns
  the agent with an inherited environment block, so both reach the agent an
  acceptance script never launches itself. Empty/default in every real agent.
- Acceptance: `test/win32/agent-open-refused.ps1` (control / fast refusal /
  skew).

**And a pane that cannot RE-JOIN its session says why too** (T657) — the resume
half, which is the one a user meets after a reboot, an app upgrade, or picking a
session out of the chooser. It used to arrive at the pane as a bare
`error.RemoteAttachFailed` and paint the same "exhausting a system resource"
text. It is two mechanisms, split by what each can carry, and the split is the
design:

- **The reason for `not_found` / `dead` / `attached_elsewhere` is derived on the
  CLIENT** from the `AttachStatus` the agent already sends. Those are complete
  answers that arrive in milliseconds and have on every agent that ever shipped,
  so the sentence needs **no capability and no wire change** and works against an
  agent of any age. Mapping: `src/termio/attach_failed_notice.zig` (pure,
  asserted in the none lane), out through the same `Backend.bringUpNotice()`
  seam. Deliberately NOT re-stated on the wire: two spellings of one fact across
  a compatibility boundary is what the agent contract exists to prevent, and it
  would strand every caller that reads `AttachOutcome.status` (the chooser,
  Restore All) behind a new error.
- **`ATTACH_FAILED` (0x07, `{reason, detail}`) covers only what `ATTACHED`
  cannot express** — today a payload the agent could not parse, which was the
  one genuinely silent ATTACH path and did cost the client the full 10 s.
  Capability-gated on `attach_failed` for the same fatal-framing reason as 0x06,
  degrading in both skew directions to exactly the pre-T657 silence-then-timeout.
  Client entry point: `Connection.attachChannelRefusable` → `error.AttachRefused`
  with a `protocol.RefusalCopy` (the verb-neutral rename of `OpenFailedCopy`,
  now that both refusals share it).
- **Reachability needed a seam**, for the reason T469's two did. The win32
  launch restore probes the agent's roster first and gives a leaf whose session
  is not listed a null id, so it OPENs fresh rather than ATTACHing (T89g) —
  which leaves this failure to the case where the probe DID NOT LAND (a slow or
  wedged agent past `restore_probe_timeout_ns`). `GHOZTTY_RESTORE_PROBE_UNKNOWN=1`
  forces that liveness tri-state to UNKNOWN and changes nothing else, so the
  branch is reproducible instead of racy. Unset in every real launch.
- Acceptance: `test/win32/agent-attach-refused.ps1` (live-restore control /
  fast named refusal / the same message against a suppressed capability).

**A launch command and a restore both happen.** `ghoztty -e <cmd…>` (or a
`command`/`initial-command` in the config) asked for something on THIS launch;
the windows restore rebuilds are what the user left behind. Neither silently
swallows the other: the requested window is opened **first**, then restore
rebuilds the rest, and the requested window is raised back to the foreground
afterwards. Opening it first is not cosmetic — core `Surface.init` hands
`initial-command` to whichever surface is `app.first`, and a restored pane would
otherwise consume it and have nowhere to run it (it ATTACHes to a session that
already exists), which is how the command used to vanish with no window, no
error and no log line (T406). Acceptance: section D of
`test/win32/gui-launch-command.ps1`.

Session lifecycle: a process DIES when the user closes its pane/tab/window (or
`+close`s it — the CLOSE lands when the close's undo window expires), when the
shell itself exits, or when the agent dies (children then relaunch as
tombstones per `session-relaunch`). It SURVIVES app quit/crash/upgrade (quit
never prompts for persistent windows — their sessions re-attach on relaunch).
E2E: `scripts/e2e/session-persistence.py` (incl. `--winsize` for re-attach
PTY-geometry integrity).

**A restored screen is PARKED into scrollback before anything repaints over
it** (T666). A re-attaching pane paints the app's own persisted VT repaint of
the screen it had when it was last saved (WP-D3, `Remote.restore_snapshot`) —
and that paint lands on the VISIBLE rows, where the very next thing on the wire
is a full-viewport repaint that homes to row 1: the agent's `grid_snapshot`
(which opens `ESC[H ESC[2J`) and, behind it, ConPTY's own post-attach fresh
paint. Every row of restored history was overwritten in place, so a pane came
back holding one screen and nothing above it — which is why the SECOND restore
in a row looked like total scrollback loss while the first looked fine (with
little history, everything still fitted in the viewport). The pane now scrolls
the restored screen off the top at the agent's snapshot head — the exact offset
where the replay that CONTINUES that screen ends and the repaint of the current
one begins — so the repaint gets a blank viewport and the history sits above it.
The rule is `src/termio/restore_park.zig` (pure, asserted in the none lane) and
it is gated on `Connection.peerRepaintsOnAttach`: a peer that promises no
repaint never has its viewport blanked. This is the same invariant T106 named —
on Windows content survives an attach only if it is in scrollback before the
repaint lands — and T106's replay-geometry reflow now covers the snapshot attach
path too, because the gap-fill there is the same geometry-bound ConPTY bytes and
keeping it means replaying it correctly rather than letting the repaint erase
the shredded result. One screenful may legitimately appear twice (the restored
tail and the repaint of it), which is the duplication section D of
`test/win32/session-persistence.ps1` has always allowed. Acceptance: the B\*.7
arms of that script (a marker planted before the FIRST kill must still be
readable after the third).

The agent owns the PTYs, keeps a per-session output ring (2 MB default;
snapshotted to disk for reboot scrollback), persists session metadata to
`sessions.json`, and is packaged as a per-user LaunchAgent so it comes back
after a crash/reboot. The app dials it over a 0600 AF_UNIX socket
(`~/.config/ghoztty/local-agent[-debug]/agent.sock`) with a same-uid peercred
check. Use `+sessions` (`docs/claude/cli.md`) to enumerate live sessions directly from the
agent, even when the app is not running. On Windows the same design holds
with native swaps: the agent (`ghoztty-agent.exe`, shipped as a required
sibling of `ghoztty.exe`) owns ConPTYs, is dialed over the owner-only-DACL
named pipe (see `+sessions` in `docs/claude/cli.md`), keeps its state under
`%LOCALAPPDATA%\ghoztty\local-agent[-debug]\`, and the reboot-comeback analog
of the LaunchAgent is an HKCU Run entry (`GhozttyAgent`) the GUI
writes/refreshes when persistence engages. Design + measured E2E results:
`docs/design/session-persistence.md`; E2E harness: `scripts/e2e/session-persistence.py`.

### Browsing and resuming sessions from the chooser

The machine chooser (Cmd-Shift-N on macOS, Ctrl+Shift+N on Windows) is where a
machine's live sessions are browsed and taken over. Select a machine and its
**session roster** appears in the detail pane — one card per connectable
session, with its title, working directory, activity state and a Kill control.
From there:

- **Resume one** — Right steps the keyboard cursor into the roster, Up/Down walk
  it, and Return opens a window here whose pane **ATTACHes** to that session
  (the process keeps running on its own machine; only the viewer is local). A
  session already open in one of your panes is focused instead of attached
  twice. Dead-but-relaunchable rows are listed — their recorded command is worth
  seeing — but cannot be resumed; reviving one is a RELAUNCH, a different verb.
- **Restore All** — rebuilds the machine's *whole* window/tab/split topology
  here, every pane attached to its still-running session. The button appears
  only when the selected machine has **two or more live sessions**: with one
  there is no topology to rebuild and Resume already covers it. The layout comes
  from the blobs the **agent** holds, not from the local `session-layout.json`,
  which is what makes it work after a crash that lost the manifest — precisely
  when launch-time restore can do nothing. Pointed at a **remote** machine it
  dials that machine for the layouts and gives **every rebuilt window its own
  connection** (a Windows detail with no Mac analog: a win32 window owns its
  transport and frees it on close, so one shared dial would die with the first
  window closed). A frame authored on the far machine's monitors is re-clamped
  onto a visible local one; a window whose sessions are already open here is
  skipped rather than attached twice.

Both work **cross-machine on macOS and Windows** — browse a relay machine's
roster, resume one session or rebuild the whole topology locally. Cross-machine
Resume shipped on macOS 2026-07-16; on Windows, browse/Resume-one landed with
T318–T320 and cross-machine Restore All with T336 (2026-08-02).

**Every session row carries a live CPU meter**, on both platforms — a bar that
saturates at ONE core plus the number, per-core over the session's whole process
tree (top(1)'s convention, so four busy threads read ~400%). It is what tells the
build chewing a core from the five shells sitting at a prompt. Three rules,
Mac's, and each is load-bearing:

- **The agent decides the cadence.** The client asks (2s) and the agent floors,
  stretches under its own load and caps (`Server.throttledIntervalMs`, 0.5–10s),
  reporting what it actually used in EVERY frame. The UI reads that number rather
  than assuming its own, which is what keeps a throttled stream distinguishable
  from a stalled one. A fixed client-side poll would hit a box hardest exactly
  when it can least afford it.
- **0% is shown, not hidden.** Hiding idle rows makes "idle" and "the meter is
  broken" look identical, and it removes the baseline that makes a busy row
  obvious — 400% only reads as alarming next to neighbours at 0. A missing meter
  means exactly one thing: no reading for that session.
- **The column is reserved for the MACHINE, never per row**, so every title
  starts at the same x and the meters stack into a scannable strip. An agent that
  never advertised `capability.session_cpu` reserves nothing and draws nothing —
  the gate is not politeness, since an unknown opcode is a FATAL framing error to
  an older agent, so subscribing blind would kill a working connection.

Windows subscribes on the same warm connection everything else about that machine
rides (below): the local agent's, or the pool's for a remote one, torn down when
the selection moves and before the lease is released (T462 —
`SessionCpuProbe.zig`, with the column geometry, the fill, the tone and the
number pure in `chooser_cpu.zig`, asserted at 1.0/1.25/1.5/2.0). Acceptance:
`test/win32/chooser-session-cpu.ps1`, whose control makes the same agent advertise
like an older one (`GHOSTTY_AGENT_SUPPRESS_CAPS=session_cpu`) and requires the
meter to vanish rather than freeze, wedge, or invent a number.

**Selecting a machine dials it ONCE, and everything about that machine rides the
same connection** (T461 — the win32 half of Mac's
`MachineConnectionPool.swift`). Every roster refetch of a remote row used to dial
the relay, run `LIST_SESSIONS` and free the connection again — so a WebSocket
upgrade and a relay authentication per fetch, and nowhere to hang anything that
has to keep LISTENING (a per-session CPU meter needs a connection that outlives
one RPC, which a dial-read-free probe cannot host by construction). The local
agent has had a warm connection since session persistence shipped; this is the
remote half of it, `App.machine_pool`.

- **Keyed by ENDPOINT** (`relay:<base>|<device>` or `tcp:<host>:<port>`), never by
  chooser row: two rows that name the same device describe one agent and share
  one socket. The token is not part of the key — a rotated relay session token is
  the same machine — but it IS refreshed on every acquire, so a re-dial never
  uses a stale bearer.
- **Refcounted by leases, never by guesswork.** Dialed on the first borrow, freed
  on the last release. A lease follows the chooser's SELECTION, so a browse does
  not leave a socket open to every machine the user clicked through — arrowing
  away drops it and arrowing back dials again — and closing the chooser can never
  leave a connection behind, because the lease also holds the chooser as its
  callback context (a lease that outlived its dialog is a call into freed memory
  the next time anything about that machine changes: measured, and it killed the
  app).
- **A blocking RPC outlives the pool's own reference.** `LIST_SESSIONS` and
  `CLOSE_SESSION` run on worker threads where the last lease can drop mid-call, so
  `borrow` hands out an atomically refcounted entry and whoever drops the last
  reference frees the transport. That is Mac's ARC retain in win32 dress, and it
  is what makes the win32 invalidation path safe with no synchronous delivery:
  a link-state callback arrives on the connection's own reader thread and can only
  POST to the GUI thread, and a borrow the notification has not reached yet is
  holding the transport up by construction.
- **A dial that lands after its machine moved on belongs to nobody.** Released,
  invalidated or re-dialed while a dial blocks ⇒ the result is freed instead of
  installed, decided by a pool-wide monotonic generation (never per-slot, so a
  slot reused for the same endpoint cannot match a stale dial by accident).
- **Only a DEAD link invalidates.** The transport FSM enters `reconnecting` after
  a few missed heartbeats and snaps back on the next authentic packet, so a down
  edge is not a death — the same reasoning as `agent_recovery.settle_ms`, minus
  its settle window, because nothing here rebuilds windows: it just re-dials
  (bounded by a 5s cooldown, so a refetch storm cannot become a dial storm).
- The **local** agent is deliberately not pooled here: `LocalAgent` already owns
  exactly this for the app's lifetime, and pooling it too would mean two
  connections to one agent.

Rules — the key, the lease refcount, the cooldown, the generation check — are
pure in `src/apprt/win32/machine_pool.zig` and asserted in the `none` lane;
the resources are `MachineConnectionPool.zig`. Acceptance:
`test/win32/chooser-conn-pool.ps1`, whose oracle is the fake relay's own request
log (five refetches, zero further connects) paired with the app's load count —
"one dial" is only good news if the fetches really happened — and whose control is
a second chooser that must dial again.

**Restore All across LINEAGES** (a Mac machine restored on Windows) works as of
T337, and it works by translation rather than by agreement. The layout blob the
agent stores is opaque to it, so its schema is a contract between two viewers —
and the two never shared one: macOS writes a camelCase
`SessionLayoutManifest.Entry`, one blob per TAB, with a nested `tree`; win32
writes a snake_case `session_layout.Window`, one blob per WINDOW, with a flat
indexed `nodes` array. There is no lineage tag to switch on and there cannot be
one retroactively — the blobs already in a live agent were written before any tag
could exist. So the READER identifies a blob by shape (`tree` vs `tabs`) and
converts the other lineage's into its own (win32:
`src/apprt/win32/mac_layout_blob.zig`; the Mac half is T622), skipping — never
failing on — anything it still cannot read. Two things deliberately do not
survive the trip: the WP-D3 screen snapshot (another viewer's stale screen must
never be painted into a restored pane) and the window ORIGIN (Cocoa measures y
up from the bottom-left and the blob records no source-screen height, so it is
passed through and re-anchored if it lands off-screen — T623). Full contract:
`docs/design/session-persistence.md` §5.4.2. Acceptance:
`test/win32/layout-blob-cross-lineage.ps1`.

### Agent contract & upgrade compatibility

The `ghoztty-agent` outlives the app on purpose (per-user LaunchAgent; survives
quit/crash/upgrade). The direct consequence: **a running agent is frequently a
DIFFERENT build than the app talking to it** — an app upgrade replaces the app
binary while the old agent process keeps running with every PTY attached. The
app↔agent wire contract is therefore a **compatibility boundary.** Forward
compatibility across it is the **default and strongly preferred** path; a
breaking change is allowed but only as a *conscious* decision routed through the
mandatory agent-update process (below), never as an accident. What is never
acceptable is an *unhandled* skew — garbled output, a wedged socket, or a crash.
Treat this boundary with the same care as an on-disk format or a public API.

Rules for any change to the agent↔app protocol (messages, fields, framing, the
ring/snapshot/gap-fill replay, HELLO handshake):

- **Old agent + new app MUST keep working, and new agent + old app MUST keep
  working.** Neither side may assume the peer is its own build. A skew must
  degrade to reduced function, never to garbled output, a wedged socket, or a
  crash. (The 1.14.0 re-attach corruption — new app replaying an old agent's
  scrollback into smeared, non-interactive panes — is exactly the failure this
  rule exists to prevent.)
- **Evolve additively.** New messages and new fields only. Never change the
  meaning, type, or framing of an existing message or field, and never remove
  one that an older peer still sends or expects. Readers ignore unknown fields
  and tolerate absent ones (fall back, don't fail). A field that goes missing
  because the peer is older must degrade gracefully — the way agent-side
  pid/tty already reports null to an app that doesn't understand it.
- **Detect capability at runtime — never at compile time.** Attach begins with
  a **HELLO handshake** that exchanges a protocol/capability version so each
  side negotiates behavior from what the peer *actually* advertises, not from
  what this build happens to ship. Gate every new behavior on the negotiated
  capability, and document each protocol version and what it added in the agent
  protocol source so the compatibility matrix is checkable at runtime and in
  review.
- **Breaking changes are allowed — deliberately, never accidentally.** Forward
  compatibility is the default because it's the cheapest path (no disruption),
  but a break is a legitimate tool when additive evolution would be worse. What
  makes a break acceptable is that it is *conscious* and *backed by the
  mandatory agent-update process* — not that it's forbidden. When you break the
  contract: bump the protocol version, and on an incompatible skew the app must
  NOT replay across it. Instead the mandatory-update mechanism takes over:
  - **Prefer a lazy, non-destructive agent upgrade.** Carry sessions across by
    upgrading the agent when it is safe — on idle, or as each session naturally
    closes — draining/snapshotting and resuming so no work is lost, then proceed
    with the app upgrade transparently. This is what makes most breaks painless.
  - **When a session cannot be carried across**, show a **mandatory, explicit
    confirmation before resetting**: *"Upgrading will reset all windows.
    Continue?"* Never silently reset live sessions, and never silently replay
    across a version the handshake flagged as incompatible.

  The mandatory-update process is the safety net that makes breaking changes
  survivable; the HELLO handshake is what lets us detect when we need it. Build
  and keep both robust, and a breaking change becomes a conscious, bounded cost
  rather than a corrupted-session incident.

### The per-session PTY holder (Windows, T904+)

The non-destructive agent upgrade (T705, design:
`docs/design/agent-nondestructive-handoff.md`) inverts PTY ownership on
Windows: each persistent session's ConPTY + shell + kill-on-close job lives in
a tiny **holder process** (`ghoztty-agent.exe --pty-host`, one per session),
and the agent talks to it over an owner-only-DACL named pipe
(`\\.\pipe\ghoztty-pty-host[-debug]-<user>-<session-id>`). An agent restart
then carries nothing, because nothing moves — holders keep every shell alive
and the next agent re-adopts them.

The holder⇄owner protocol (`src/remote/agent/pty_host_proto.zig`: versioned
HELLO, DATA both ways, RESIZE/SIGNAL/EXIT, offset-acknowledged bounded replay)
is a **second compatibility boundary with the same rules as the app⇄agent
contract above** — a holder outlives the agent that spawned it BY DESIGN, so a
reconnecting owner is routinely a different build. Evolve it additively
(decoders ignore unknown frame types and trailing payload bytes), bump its
`proto_version` only for a conscious break, and keep the holder's surface
frozen-tiny so it almost never needs upgrading itself. Increment status lives
in T705's split (T904 holder+protocol, T905 spawn path, T906 adoption, T907
choreography). Acceptance: `test\win32\pty-host.ps1`.

**Since T905 the agent can actually spawn one**, behind
`GHOZTTY_AGENT_PTY_HOLDER=1` (read from the agent's own environment at start, so
one agent's sessions are all spawned the same way). Three things about that path
are contract, not detail:

- **A holder is spawned from a JSON spawn spec**, not from flags: the agent
  writes `%TEMP%\ghoztty-ptyhost-<id>.json` holding the whole `protocol.Open`
  verbatim (`src/remote/agent/pty_host_spec.zig`) and the holder reads **and
  deletes** it before spawning the shell. That is what keeps an explicit `argv`
  shell-integration rewrite, the forwarded `OPEN.env` allowlist and `TERM`
  byte-identical to the in-process child — a command line would have to quote
  them and an inherited environment would leak one session's vars into the next.
  Add a field additively (`format_version` bumps only for a real break; a holder
  refuses a version it cannot read rather than spawning a wrong shell).
- **`sessions.json` gains `holder_pipe` / `holder_pid` / `holder_stamp`**,
  strictly additive. They are the only durable handle on a survivor, so they
  must round-trip through `materialize` as well as `persistMeta` — a persist
  that dropped them would erase the pointer to a live shell.
- **A holder-spawn failure falls back to the in-process child** with a warning
  naming what was lost. Losing the survive-an-agent-death property is a bad
  day; a dead pane because a holder would not start is a worse one.

Acceptance for that half is `test\win32\pty-holder.ps1`, which kills a real
agent and asserts the shell and holder live on — with a flag-OFF negative
control asserting the shell still dies with the agent, so the measurement is of
the change rather than of the box.

Design + status: `docs/design/session-persistence.md`.

