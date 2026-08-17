# Session-persistence E2E harness

Automated end-to-end tests for the hybrid local-agent session persistence
(design doc §5). They drive the **debug** build entirely through the debug CLI,
kill the app, relaunch, and assert mechanically that every pane's process
**survived and re-attached** (was not restarted).

> Debug bundle / debug socket / debug agent only. These scripts never touch
> `/Applications/Ghoztty.app`. Build first: `zig build -Doptimize=Debug`.

## `session-persistence.py` — kill -9 survival (task T07)

```
scripts/e2e/session-persistence.py [--cycles=3] [--upgrade | --agent-restart | --agent-only] [--quit=kill|graceful] [--keep] [--verbose]
```

What it does:

1. **Full reset** — kills any debug app + local agent, clears the layout
   manifest and agent port file for a known-clean start.
2. **Builds the headline scenario** — 2 windows, 5 panes, nested split topology
   with distinct ratios:
   - Window A: `P0 | (P1 / P2)` — root ratio 0.30, sub ratio 0.70
   - Window B: `P3 | P4` — ratio 0.40

   Each pane runs a unique never-exiting marker:
   `echo PANE=<n> PID=$$; i=0; while true; do echo tick-<n>-$((i++)); sleep 1; done`
3. **N kill/relaunch cycles** (default 3) — `SIGKILL`s the app and relaunches
   the *same* binary with 0s gap (T06b made fast relaunch safe), polling until
   every pane re-attaches.
4. **Asserts each cycle** (exits nonzero + prints an actionable diff on any miss):
   - every pane's PID unchanged **and** still alive (re-attached, not restarted)
   - tick counter strictly increases across the gap; exactly one `PANE=` line in
     scrollback (a second one ⇒ the shell restarted)
   - split topology deep-equal — directions + ratios within ±0.01
   - window count and per-window marker set preserved
   - pre-gap scrollback line replayed after restore
   - kill→interactive gap < 10s
   - the local agent PID is unchanged (agent owned the PTYs across the swap)

Panes are identified across restore by their `PANE=<n>` marker, not by IPC name,
so unnamed panes that get fresh auto-registered names on restore are handled.

By default the harness cleans up (closes windows, resets state) on exit; pass
`--keep` to leave the restored fixture running for inspection.

### Notes / gotchas encoded here

- The Ghoztty CLI requires `--flag=value` syntax; `--flag value` silently drops
  the value (e.g. leaves a window unnamed).
- `+split --name=` registers the pane asynchronously on agent-backed windows, so
  the harness polls `+list` for a name before using it as a target.
- The fresh-launch fallback "initial window" is closed after Window A exists (so
  closing it can't quit the app), leaving exactly the 2 test windows in the
  manifest.

## `session-persistence.py --upgrade` — simulated binary upgrade (task T08)

```
scripts/e2e/session-persistence.py --upgrade [--quit=kill|graceful] [--cycles=3]
```

Same scenario and assertions as above, but between terminating the app and
relaunching it, the **installed bundle is physically replaced on disk** — every
file unlinked and rewritten with fresh inodes at the same installed path — exactly
the on-disk swap an updater (Sparkle) performs. The app then relaunches from the
replaced bundle and must re-attach every pane intact, with the **agent process
untouched** (same PID before and after the swap). Each cycle asserts the main
executable's inode actually changed (proof the bundle was replaced).

Both termination modes are covered:

- `--quit=kill` (default) — `SIGKILL`, i.e. crash-then-upgrade.
- `--quit=graceful` — AppleScript `quit` (scoped by bundle id, never by process
  name — the release app shares the name), routing through
  `applicationShouldTerminate` (`isQuitting` ⇒ manifest preserved).

The `<10s` SLA is measured as the **recovery** gap (old process gone →
all panes interactive), reported separately from how long termination itself
takes (`term=…s`), since recovery speed — not quit speed — is the crash/upgrade
criterion.

**Why the swapped bundle is byte-identical (not a recompiled binary):** the debug
build is *ad-hoc* signed (no team), so its keychain authorization for
`com.dzearing.ghoztty.relay-account` is bound to the app's exact code hash
(cdhash). A genuinely-recompiled or re-signed bundle has a different cdhash and
would trigger a keychain re-auth **prompt on every launch**. Real Developer-ID
upgrades keep a stable designated requirement and don't prompt; we can't
replicate that ad-hoc. Holding the bytes constant is immaterial to what the test
proves — the restore path never reads app-bundle bytes; it reads the layout
manifest + the surviving agent. The test still exercises the full
FS-swap → relaunch → re-attach path an upgrade takes. The harness verifies the
reserve copy's cdhash matches the installed one before starting.

### Known caveat: slow graceful quit with many agent-backed panes (task T08a)

With several session-persistence (agent-backed) panes open, a **graceful** quit
can hang ~45s in AppKit's `-[NSApplication _terminateFromSender:…saveWindows:]`
window-teardown before the process exits (plain exec-backed windows quit in
<1s). The `isQuitting` manifest-preservation path runs *before* the hang, so
persistence is unaffected, and recovery after relaunch is still <4s — but the
harness waits out the hang (up to 45s) then `SIGKILL`s as a last resort. This is
a pre-existing app-teardown issue tracked as T08a, not a persistence regression.

## `session-persistence.py --agent-restart` — reboot-equivalent (task T12d)

```
scripts/e2e/session-persistence.py --agent-restart [--cycles=3]
```

The **reboot floor** (design ACs 3 & 4). A reboot — or an agent crash — is the
one scenario no design can keep processes alive across: when the agent dies, its
children die (POSIX PTY semantics) and its in-RAM output ring is gone. The honest
contract is *session state restores + processes **relaunch***, not survival. This
variant proves it end to end:

1. **Setup** — same 2-window / 5-pane fixture. The app installs a per-user
   **LaunchAgent** (`com.dzearing.ghoztty.debug.agent`, `RunAtLoad`+`KeepAlive`)
   so launchd — not the app — owns the agent.
2. **Reboot** — `SIGKILL` **both** the app and the agent (a reboot takes down
   everything). launchd's `KeepAlive` restarts the agent; the fresh agent loads
   `sessions.json` and materializes every session as a *relaunchable tombstone*
   before it accepts connections.
3. **Recover** — relaunch the app. It rebuilds the layout from the manifest,
   re-attaches each leaf by session id, and (session-relaunch = `rerun`) fires
   `RELAUNCH` per pane: the agent respawns the child from recorded argv/cwd.

Each cycle asserts the **opposite** of the survival tests: the agent PID
**changed** (launchd brought a new one, in ≤ 5 s — measured 0–2 s), every pane's
child PID is **new** (relaunched, not re-attached), the pane shows the
`--- session restarted ---` banner, the marker command re-ran, and the split
topology is still rebuilt exactly from the manifest.

**launchd respawn throttle.** launchd rate-limits `KeepAlive` respawns to once
per `ThrottleInterval` (default 10 s) since the job's last spawn. A real agent
crash happens long after startup, so before each kill the harness settles the
live agent past that floor (tracking its spawn wall-clock — this box's
`ps -o etimes=` is not a valid keyword) to measure the true single-crash latency
rather than a throttle artifact of rapid cycling.

**Cleanliness.** The debug LaunchAgent is a distinct label from the release job,
and `full_reset` boots it out (+ removes the plist) at start and teardown, so a
KeepAlive job never lingers on the machine after a run. Because launchd owns the
agent, `--agent-restart` (and any run after it) relies on that bootout — a bare
`SIGKILL` of a `KeepAlive` agent would be undone by launchd instantly.

## `session-persistence.py --agent-only` — in-place recovery (task T12e)

```
scripts/e2e/session-persistence.py --agent-only [--cycles=3]
```

In-place **AC4**: the agent crashes while the GUI app **stays up**. This is the
same reboot floor as `--agent-restart` (children + ring RAM are lost, sessions
*relaunch*), but the app is **never** relaunched — recovery happens live.

1. **Setup** — same 2-window / 5-pane fixture + LaunchAgent as `--agent-restart`.
2. **Crash** — `SIGKILL` **only** the agent; the app keeps running. launchd's
   `KeepAlive` restarts the agent, which materializes each session as a
   relaunchable tombstone before accepting connections.
3. **Recover in place** — the live app's shared local-agent connection observes
   the dropped transport (the local UDS link never self-heals — the Zig FSM only
   computes backoff), re-dials the restarted agent **once** for all windows, and
   rebuilds each open window's full split tree in place → re-`ATTACH` finds the
   tombstone → auto-`RELAUNCH` with the `--- session restarted ---` banner.

Each cycle asserts the reboot-cycle checks (agent PID changed ≤ 5 s, fresh child
PIDs, restart banner, exact topology from the manifest) **plus the defining
in-place invariant: the app process is unchanged** (it did not relaunch). The
local machine pill stays hidden throughout — recovery looks like the panes just
restarted in place. Measured recovery ~2.5–3.7 s. Same launchd-throttle settling
and LaunchAgent cleanliness as `--agent-restart` above.

The per-window remote reconnect ladder (WP-D1) is intentionally **not** used for
local windows: it re-dials the loopback machine over TCP (the local transport is
a UDS) and would collapse the window to a single root pane. Local recovery is
centralized in `LocalAgentManager` → `AppDelegate.recoverSessionLayoutInPlace`.
