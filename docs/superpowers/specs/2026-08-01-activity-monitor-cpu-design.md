# Activity Monitor: CPU correctness, pane attribution, per-session CPU

Date: 2026-08-01

Three related changes to the Activity Monitor panel and the machine chooser:

1. Fix the `% CPU` column, which reads `0.0` for every process.
2. Show which window/pane owns each Ghoztty-spawned process.
3. Add a per-session CPU meter to the chooser's session list.

---

## 1. CPU correctness

### Root cause: three bugs, multiplying

Measured on this machine (`hw.ncpu == 18`, `mach_timebase numer=125 denom=3`
⇒ 41.67 ns/tick, a 24 MHz Apple Silicon timebase) against a process pinned to
exactly one core (`yes > /dev/null`):

| Interpretation of `pti_total_user + pti_total_system` | Computed %CPU |
| --- | --- |
| raw value is **nanoseconds** (what the code assumes) | **2.39** |
| raw value is **mach ticks**, converted via timebase | **99.63** |

`top` reports ~100 for the same process. So:

| # | Bug | Factor | Site |
| --- | --- | --- | --- |
| 1a | `pti_total_*` treated as ns; they are **mach absolute time units** | **24×** | `src/remote/agent/proc.zig` `sampleMacos` |
| 1b | `normalized()` divides per-core % by `ncpu` | **18×** | `RemoteActivityMonitorView.swift:1089` |
| 1c | One shared `ProcSampler`, two pollers clobbering its baselines | flicker → 0 | `src/apprt/embedded.zig` `LocalSamplers` |

Combined 1a × 1b = **432×**: a fully-pinned core renders as `0.1`, which
formats to `0.1`/`0.0`. That is the whole screenshot.

### 1a — convert mach ticks to nanoseconds

In `sampleMacos`, convert the cumulative busy reading through
`mach_timebase_info` before handing it to `cpuForPid`.

The unit convention stays **"`busy` is nanoseconds"**, which is what the shared
`cpuForPid`/`perCorePct` helpers already document and what the other two OS
paths already produce (Windows converts 100 ns FILETIME ticks → ns; Linux
converts jiffies → ns). macOS was the one path not converting. So this change
makes all three coherent rather than introducing a macOS special case, and
`perCorePct` itself is untouched.

On Intel Macs the timebase is 1:1, so the conversion is an identity there. The
fix is correct on both architectures; it is not Apple-Silicon-conditional.

The timebase is queried once and cached (it is constant for the life of the
machine).

### 1b — report per-core %CPU

Delete `normalized()` from the process table and render `cpuPctPerCore`
directly, matching `top` and macOS Activity Monitor, where a busy multithreaded
process legitimately shows 150 / 400. The column header is already `% CPU`.

No normalized alternative and no toggle. The honest default is the one the
header already promises; a second labeled mode is speculative.

**The header host gauge is deliberately unchanged.** `metrics.zig`'s `cpuPct`
derives host CPU from `HOST_CPU_LOAD_INFO` busy/total ticks, clamped 0..100 —
a genuine percentage of the whole machine, and a different quantity from
`proc.perCorePct`. It is correct as-is and stays that way.

### 1c — stop the two pollers fighting

`ghostty_local_proc_list` uses one process-wide persistent `ProcSampler`, and
two timers call it: the machine-card summary at 5.0s
(`RemoteActivityMonitorView.swift:258`) and the table refresh at 1.5s (line
378). Each call swaps in fresh prev-sample baselines, so when the two ticks
land close together the table computes a delta over a near-zero wall window.

`sampleLocalCard()` reads only `list.host` — it never looks at the process
rows, yet pays for a full 500-process enumeration every 5 seconds and destroys
the table's baselines as a side effect.

Fix: add a host-only entry point (`ghostty_local_host_metrics`) that samples
the host sampler and does not touch the proc sampler; point the card at it.
This fixes correctness and removes the wasted enumeration in one move, and is
simpler than keying sampler instances by caller.

---

## 2. Window/pane attribution

### The key: controlling tty, seeded then propagated by ppid

Neither tty nor ppid alone is sufficient. Traced against a live pane:

```
38560 ttys004 zsh          ← the agent's child: the pane's shell
  38577 ttys004 2.1.220    ← claude  (accounting name is its version string)
    38730 ttys004 node     ← burns CPU, keeps the tty          ✅ tty works
    57724 ??      bash     ← Bash tool call, setsid'd, no tty  ❌ tty fails
      57826 ??    jq                                            ❌
```

- Processes that keep the controlling terminal (the `node` workers that
  actually burn CPU) are caught by a tty match.
- Claude Code's Bash-tool subprocesses drop their controlling terminal but
  remain ppid-descendants.

So: **seed** attribution from the tty match, then **propagate** to unattributed
rows by walking up the ppid chain to the first attributed ancestor.

`foregroundPID` (what `+list` reports per pane) is the *claude* pid, not the
pane's shell, so it is the wrong anchor on its own. The tty seed finds the
whole pane subtree without the app needing to know the shell pid.

### Wire change

Add `tty` to `protocol.Proc` and to the `ghostty_proc_s` C struct. On macOS the
value comes from `proc_bsdinfo.e_tdev`, a field the sampler **already reads** —
zero additional syscalls.

This is a new optional field on an existing message, so it is purely additive:
the decoder already sets `ignore_unknown_fields = true`, so old-agent →
new-app decodes as absent (column blank) and new-agent → old-app ignores it.
No capability bump — this is the agent contract's preferred default path.

### Resolution

Attribution runs in Swift as a pure function over the snapshot:

1. Build `tty → pane` from the live pane list.
2. Seed: each row whose tty matches a pane is attributed to it.
3. Propagate: for each unattributed row, walk up `ppid` to the first attributed
   ancestor and inherit it. Memoized; guarded against cycles and missing
   parents.

Keyed **per machine** (`controller.remoteConnection?.machine`, nil ⇒ local), so
a remote pane resolves against its own machine's tty namespace and never
collides with a local `ttys004`.

The displayed label reuses the existing fallback chain in
`BrowsedSession.label` (live pane title → agent title → persisted title → cwd
basename → command → pid) rather than writing a second one.

In "Show all" mode, unattributed rows show blank.

### Consequence: the spawned filter is anchored to the wrong root

`ghostty_local_proc_list` reports `agent_pid = getpid()` of the **app**, but
with `session-persistence = on` (the default) every pane shell is a child of
**`ghoztty-agent`**, not of the app — the app process has no children at all.
So the local "show only Ghoztty-spawned" filter cannot see any pane process.

With attribution available, the filter's definition becomes "attributed to a
pane, or is the app/agent itself", which is both correct and more meaningful
than a single-root BFS.

This is scope beyond the literal ask, included because the attribution column
is pointless if the filter it lives in shows one row. The breakage will be
confirmed live in the debug panel before the fix is claimed.

---

## 3. Per-session CPU meter

### A pushed stream, not a poll

New message triple modeled on the existing `metrics_sub` pump:

| Type | Direction | Payload |
| --- | --- | --- |
| `session_cpu_sub` | C→A | `{interval_ms}` — a **hint**, not a mandate |
| `session_cpu` | A→C | `{interval_ms, sessions: [{id, cpu_pct}]}` |
| `session_cpu_unsub` | C→A | `{}` |

**The agent owns the cadence.** The client's `interval_ms` is a floor; the
agent stretches it under its own load (×2 above 60% host CPU, ×4 above 85%,
capped at 10s) and reports the interval it actually chose in every frame, so
the client can render staleness honestly rather than assuming its request was
honored. The backoff is bounded, so the stream can never starve.

The agent does the subtree roll-up itself — it authoritatively knows
session → child pid, since it owns the PTYs — so each frame carries a handful
of `{id, cpu_pct}` rows instead of the whole process table. The roll-up uses
the same seed-then-propagate walk as §2, rooted at each session's child pid.

The pump owns its **own** `ProcSampler`, exactly as `metricsPumpLoop` owns its
own `metrics.Sampler`. That is the established pattern here and it structurally
avoids the §1c baseline-clobbering bug rather than re-introducing it.

### Capability gating

Unlike §2's field, these are genuinely new message types, so they are gated on
a new negotiated `session_cpu` capability (the intersection of both HELLOs).
When it is not negotiated the chooser shows **no meter** — degraded function,
never a wrong number and never a fallback poll that the agent did not consent
to. This satisfies the agent-contract rule for old-agent/new-app skew.

### Lifecycle

Subscribe when the chooser page appears, unsubscribe when it disappears. The
chooser is transient UI and must not hold a stream open behind itself.

Local sessions need no special case: the chooser already dials the local agent,
so the same subscription serves both `.local` and `.remote` rows.

---

## Testing

**Zig** — extend the existing `perCorePct` / `ProcSampler` tests rather than
starting fresh:

- mach-tick → ns conversion, including the Intel 1:1 identity case.
- A busy-spin integration test: a thread spinning for a known window must read
  a plausible per-core percentage, not ~1/24th of one.
- The seed-then-propagate roll-up helper: tty seed, setsid'd orphan reached by
  ppid, cycle guard, missing parent.

**Swift** — attribution as a pure function over a synthetic snapshot: tty seed,
setsid'd orphan, ppid cycle, unattributed row, per-machine namespacing.

**Ground truth (required — unit tests are not sufficient here).** The bug is in
what the number *means*, not in the arithmetic. Validate the running debug
panel against `top` and macOS Activity Monitor with a real pinned core:
a single-core-pinned process must read ~100, not ~0.1 and not ~5.6.

**Never touch `/Applications/Ghoztty.app`.** Build and test with
`zig build -Doptimize=Debug` and `zig-out/Ghoztty-Debug.app`.

---

## Rejected alternatives

- **Agent stamps each `Proc` with its owning session id** (instead of `tty`).
  More accurate in principle, but the local Activity Monitor's in-process path
  (`ghostty_local_proc_list`) bypasses the agent entirely and would need the
  session table plumbed into it. `tty` is raw data rather than a derived
  opinion, works identically on both paths, and the ppid propagation recovers
  the same accuracy.
- **ppid-walk alone, anchored at the pane's shell pid.** The app exposes
  `foregroundPID`, not the shell pid, so there is no anchor to walk to.
- **Keying `ProcSampler` instances by caller** to fix §1c. Works, but the card
  does not need the process table at all; a host-only call is both simpler and
  cheaper.
- **Client-polled session CPU.** Rejected in favour of the pushed stream so the
  agent can throttle itself under load.
- **A normalized/per-core toggle on the `% CPU` column.** Speculative; the
  header already promises `% CPU`.
