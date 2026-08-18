# Non-destructive agent upgrade (T705 design)

Status: **accepted design** (D59 resolved 2026-08-14: build the non-destructive
handoff; design pass first). This document is the design pass. Implementation is
split into the tasks listed at the end.

## The problem

The local `ghoztty-agent` owns every persistent session's PTY. Today a running
agent can only adopt a newer build through two exits, and both are lossy
(T662):

- `refresh_now` — silent restart, allowed only at ZERO live sessions. A box
  with an always-open pane never reaches it.
- `confirm_first` — the mandatory dialog, which costs every live session, and
  is deliberately deferred during the unattended morning refresh (T525).

The agent contract (CLAUDE.md / `docs/claude/sessions.md`) already names the
preferred mechanism it does not have: *"Prefer a lazy, non-destructive agent
upgrade. Carry sessions across … so no work is lost."* This design is that
mechanism.

## What a live session actually is

Per session the agent holds, on Windows:

| Piece | Durable today? | Carriable across a process boundary? |
|---|---|---|
| Session metadata (id, title, cwd, command) | yes — `sessions.json` | yes (disk) |
| Output ring (scrollback) | yes — ring snapshots on disk | yes (disk) |
| Shell process (+ tree) | no | **yes** — a process handle can be duplicated/inherited; on Windows `WaitForSingleObject`/`GetExitCodeProcess` work on a non-child handle |
| ConPTY I/O pipes (`in_pipe`, `out_pipe`) | no | **yes** — plain handles, duplicable/inheritable |
| ConPTY control channel (`HPCON`) | no | **NO** (documented APIs) — see below |
| Kill-on-close Job Object over the shell | no | yes — the job HANDLE is duplicable; but see below |
| Reader thread / in-memory state | no | n/a — rebuilt from the handles + disk state |

### The HPCON is the wall

`CreatePseudoConsole` returns an opaque `HPCON` (`src/pty.zig` stores it as
`pseudo_console`). Inside it — undocumented, implemented by kernelbase — live
the *signal pipe* (how `ResizePseudoConsole` talks to conhost) and the *ConDrv
reference handle* (what keeps conhost alive). Consequences:

- There is no documented way to duplicate, reopen, or hand an `HPCON` to
  another process. `DuplicateHandle` does not apply (it is not a handle), and
  the internal handles cannot be reached without peeking the struct layout.
- When the owning process exits, the kernel closes those internal handles,
  conhost tears down, and conhost **terminates the attached shell**. So the
  shell's survival is welded to the agent process even before our own
  kill-on-close job (`pty_child.zig`) terminates it a second time.
- Undocumented escape hatches exist — reading the `HPCON` layout, spawning
  `conhost.exe --headless --signal … --server …` by hand so we own every
  handle, or writing the resize packet (`PTY_SIGNAL_RESIZE_WINDOW`) straight
  into a duplicated signal pipe. Other ecosystems ship these. They would carry
  the I/O and leave resize/teardown riding reverse-engineered internals —
  exactly the "carries some of it silently" outcome T705 forbids. Rejected.

POSIX contrast, for the Mac half: the PTY master **fd is fully transferable**
over `SCM_RIGHTS`, with no equivalent of the HPCON problem. What POSIX cannot
transfer is child-reaping — the new agent is not the parent, so `waitpid` is
lost and exit is observed via `kqueue`/`EVFILT_PROC NOTE_EXIT` instead (and the
exit *code* is degraded). The two platforms fail in different places, which is
the tell that transferring live state at upgrade time is the wrong shape.

## Chosen design: ownership inversion (per-session PTY holders)

Instead of carrying the PTY across the upgrade, stop the agent from owning it.
Each persistent session's ConPTY + shell moves into a tiny **holder process** —
the same `ghoztty-agent.exe` binary in a dedicated mode (`--pty-host`) — and
the agent becomes a coordinator that talks to holders over per-session pipes.
At upgrade time **nothing is carried, because nothing moves**: the old agent
exits, holders keep every shell alive, the new agent re-adopts them.

```
app ⇄ agent (named pipe, unchanged)
         ⇄ holder #1 (per-session control pipe) — owns ConPTY + shell + job
         ⇄ holder #2 …
```

### The holder

- Creates the ConPTY (`CreatePseudoConsole`, documented, never transferred),
  spawns the shell on it, and owns its own kill-on-close Job Object over the
  shell subtree — so a dead holder still leaks no processes. The holder is
  **not** assigned to the agent's job (the escape pattern already exists:
  `spawnEscapingJob`; breakaway is refused from the pane-shell chain, not from
  the agent spawning a supervisor).
- Serves one owner at a time over an owner-only-DACL named pipe
  (`…\pty-host-<session-id>`), speaking a version-tagged protocol: `HELLO`
  (holder build stamp + protocol version), `DATA` both ways, `RESIZE`,
  `SIGNAL`, `EXIT` (code), plus **offset-acknowledged replay**: the holder
  keeps a bounded replay buffer (ring-sized) of un-acked output so an
  agent restart gap-fills instead of dropping bytes — the same shape as the
  existing app⇄agent gap-fill.
- Has a deliberately **frozen, tiny surface** — byte pump, resize, signal,
  exit — so it almost never needs upgrading itself. When it does, that is the
  contract's lazy path: holders upgrade per-session as each session naturally
  closes; a stale-but-compatible holder keeps serving (versioned HELLO, same
  additive-evolution rules as the app⇄agent contract).

### What this buys beyond upgrades

Today the kill-on-close job makes **any** agent death — crash included — kill
every shell. With holders, sessions survive agent crashes: the existing
in-place recovery (T145/T723) re-dials, the replacement agent adopts the
holders, and the panes re-attach to living shells. The upgrade path and the
crash path become the same, already-shipped "agent came back" path.

### Upgrade choreography ("never neither")

1. A newer build sits on disk (attended delivery, or `self_update` staging).
2. The old agent spawns the new binary. The new agent starts, adopts holders,
   binds nothing publicly yet, and reports **READY** back over a private pipe.
3. Only on READY does the old agent close its listener and exit; the new agent
   takes the single-instance guard and the public pipe (the `--force-replace`
   takeover machinery already exists in `single_instance.zig`).
4. Any failure before READY: the new process exits, the old agent keeps its
   listener and its sessions. The ORIGINAL agent survives every failure mode;
   "neither agent" is unreachable because the old one gives nothing up until
   the new one has proven adoption.
5. The app sees a link drop and runs the existing recovery/re-attach. No app
   change required.

### Compatibility

- `sessions.json` gains **additive** per-session fields (holder pipe name,
  holder pid, holder stamp). An older agent reading a newer file ignores them
  (existing reader rule); a newer agent reading an older file sees legacy
  sessions.
- **Legacy sessions** (ConPTY owned directly by the running agent) cannot be
  carried — the HPCON wall — and are never pretended otherwise. A
  mixed-generation agent **drains lazily**: the handoff waits until every live
  session is holder-backed, `+sessions --agent` names how many legacy sessions
  are still holding it back, and the only way to force it remains the existing
  explicit confirmation. On this box one attended delivery after holders ship
  converts everything.
- App↔agent wire protocol: unchanged except a new advertised capability so
  `+sessions --agent` can report handoff-readiness. All additive.

### Policy

`agent_upgrade.zig` gains a third arm: `handoff_now` — stale build AND every
live session holder-backed AND the running agent advertises the capability.
It asks nobody and loses nothing, so like `refresh_now` it is never deferred;
`confirm_first` remains only for legacy sessions and true breaking skews.

## Rejected alternatives

- **Live handle transfer at upgrade time** (inherit/duplicate pipes + process
  + job handles into the new agent): founders on the HPCON — resize and
  teardown would ride undocumented internals, and the transfer moment itself
  is a new failure surface on every upgrade. The holder design uses only
  documented APIs and has no critical moment.
- **Tombstone relaunch as the mechanism** (kill + respawn from recorded
  state): already exists for reboots; it loses the running process, which is
  the loss this task exists to end. Stays as the consent-gated fallback.
- **Keeping the old process alive as a dumb PTY proxy**: the old build's code
  keeps running indefinitely, which is the staleness problem restated.

## Implementation increments

Filed as parity tasks (T705 is split into these; ids in T705's log):

1. Holder process mode + control-pipe protocol + replay buffer (unit-tested in
   the `test-agent` lane; ConPTY smoke on the box).
2. New persistent sessions spawn holder-backed (flag-gated while new; DEFAULT
   since T909, with `GHOZTTY_AGENT_PTY_HOLDER=0` as the escape hatch), holder
   escapes the agent's job, `sessions.json` carries the additive fields;
   acceptance: kill the agent, the shell survives.
3. A starting agent adopts live holders — discovery, re-attach, gap-fill;
   acceptance: pane typed into before and after an agent kill (`Test-PaneLive`).
4. Upgrade choreography + rollback + `handoff_now` policy + mixed-generation
   drain reporting; carries T705's end-to-end validation criteria.
5. Mac seat: the POSIX half (holder mode or `SCM_RIGHTS` handoff — the Mac
   seat picks; the constraint table above is the input to that call).
