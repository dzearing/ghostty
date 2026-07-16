# Session-persistence E2E harness

Automated end-to-end tests for the hybrid local-agent session persistence
(design doc §5). They drive the **debug** build entirely through the debug CLI,
kill the app, relaunch, and assert mechanically that every pane's process
**survived and re-attached** (was not restarted).

> Debug bundle / debug socket / debug agent only. These scripts never touch
> `/Applications/Ghoztty.app`. Build first: `zig build -Doptimize=Debug`.

## `session-persistence.py` — kill -9 survival (task T07)

```
scripts/e2e/session-persistence.py [--cycles=3] [--keep] [--verbose]
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

_Planned._ Same flow, but between kill and relaunch the app bundle is replaced
with a freshly-built copy (new mtime) to simulate a Sparkle swap, exercised for
both the `SIGKILL` and graceful-quit paths.
