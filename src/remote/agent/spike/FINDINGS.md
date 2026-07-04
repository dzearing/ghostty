# WP2 Windows-agent risk spike — findings

> Spike for the remote-machines feature (`docs/design/remote-machines.md` §13/§17).
> Goal: write the Windows-specific agent code for every risk §17 flags, prove it
> **builds** by cross-compiling from a Mac, and produce the exact procedure to
> **verify** it on a real Windows host (none of it can run on macOS).
>
> Files: `win32.zig` (the extern decls `std.os.windows` lacks), `main.zig` (each
> risk as a function, in the real API sequence), this doc.

## Verdict

| Risk (§17) | Status from the spike | Confidence |
|---|---|---|
| Windows binary stdio (blocker) | Use **raw `ReadFile`/`WriteFile` on the std handle** (no CRT text translation) **+ COBS framing on the ssh hop**. Builds. | High on approach; **must measure** all-256-byte fidelity through `ssh-shellhost` on real hw. |
| Daemon survival (out-of-band) | **Scheduled Task** (`schtasks /create /f` + `/run`), **not** `CREATE_BREAKAWAY_FROM_JOB`. Builds. | High (matches Win32-OpenSSH#1032); verify survives `sshd` teardown. |
| Job topology (containment) | Daemon-owned BREAKAWAY_OK job → child `CREATE_BREAKAWAY_FROM_JOB|CREATE_NEW_PROCESS_GROUP` → `AssignProcessToJobObject` into per-session job; nested-job fallback. Builds. | Medium; the reassign-vs-nested fallback needs a real run. |
| Named pipe security | Owner-only DACL (SDDL `D:P(A;;GA;;;OW)`) + `PIPE_REJECT_REMOTE_CLIENTS` + `FILE_FLAG_FIRST_PIPE_INSTANCE` + `WaitNamedPipeW`. Builds. | High; verify squatter rejection + peer-PID. |
| Ctrl-C escalation | `0x03`→ConPTY input, then `GenerateConsoleCtrlEvent(CTRL_C_EVENT,pgid)`, `TerminateJobObject` only for kill. Builds. | Medium; verify console-read vs ReadConsole cases. |
| `Command.zig`→`CommandCore` | **Small** (~2–4 h). Only 3 thin couplings; see §"Refactor". | High. |

**Bottom line:** every Windows path the design calls for **compiles and links** for
`x86_64-windows-gnu` and `aarch64-windows-gnu`. No API in the design is missing or
mis-specified. The remaining unknowns are all *runtime* behaviors that require a
Windows box (binary-stdio fidelity through `ssh-shellhost`, daemon survival, job
reassignment) — listed in §"On-Windows test procedure".

---

## 1. Binary / COBS stdio (§4.2)

- **Decision: bypass the CRT, frame on the hop.** The spike reads/writes the std
  handle with raw `ReadFile`/`WriteFile` (`setupBinaryStdio`/`relayStdinToPipe`).
  The kernel handle does **no** CR/LF translation, so `_setmode(_O_BINARY)` is
  unnecessary for *our* handle. (`_setmode` is still listed in the extern notes
  for completeness, but the spike does not need it — one fewer CRT dependency.)
- **Why COBS is still required:** the corruption risk is not our local handle — it
  is `ssh-shellhost.exe` on the *ssh hop*, which can still mangle bytes regardless
  of our mode (Win32-OpenSSH#1256). So frames crossing a Windows hop are COBS- (or
  base64-) wrapped and `0x00`-delimited. `relayStdinToPipe` calls
  `protocol.cobs.encode` to prove the WP1 codec compiles and links for a Windows
  target.
- **Default = COBS**, pinned at the `HELLO` handshake (WP1). The on-Windows test
  (§"procedure" step 2) sends all 256 byte values round-trip to decide whether
  *raw* is ever safe; the design says default to encoded, and nothing here changes
  that.

## 2. Out-of-band daemon via Scheduled Task (§4.1/§13)

- `startDaemonViaScheduledTask` builds `schtasks /create /f /sc ONLOGON /tn … /tr
  "<agent> daemon" /it /rl LIMITED` then `schtasks /run /tn …`, each via
  `CreateProcessW` with `CREATE_NO_WINDOW | DETACHED_PROCESS`.
- **Not breakaway:** confirmed the design's reasoning holds at the API level —
  `sshd` runs the command under `ssh-shellhost.exe` in a job without
  `JOB_OBJECT_LIMIT_BREAKAWAY_OK`, so `CREATE_BREAKAWAY_FROM_JOB` would fail
  ACCESS_DENIED. Task Scheduler launches the daemon in its *own* job, decoupled.
- **`/run` is async** → the bridge cannot assume the pipe exists. `connectToDaemonPipe`
  loops `CreateFileW` ↔ `WaitNamedPipeW(100ms)` up to ~5 s (well under the
  exit-code-13 budget, §10.2). `/rl LIMITED` keeps the daemon non-elevated (§15 M6).

## 3. Named-pipe security (§4.1/§15 M6)

- `ownerOnlyPipeSecurity` turns the **fixed** SDDL `D:P(A;;GA;;;OW)` into a
  `SECURITY_ATTRIBUTES` via `ConvertStringSecurityDescriptorToSecurityDescriptorW`
  (advapi32) and `LocalFree`s it. The SDDL is a constant — **no caller value is
  ever interpolated** into it (same injection-safety rule as OSC-9;9, §9.4).
- `createDaemonPipe` sets `FILE_FLAG_FIRST_PIPE_INSTANCE` (fail-closed on a
  name-squat → `PipeNameSquatted`) + `PIPE_REJECT_REMOTE_CLIENTS` (no off-box
  clients) + the owner-only DACL. Three independent guards; the `<sid>` in a real
  pipe name is obfuscation, not access control.
- `acceptAndIdentifyClient` derives the connecting **PID via
  `GetNamedPipeClientProcessId`** — the unforgeable peer-cred identity the daemon
  maps PID→session by job membership (§9.5). No env bearer token anywhere.

## 4. Job-Object containment topology (§9.1/§13.4)

- `createDaemonJob`: the daemon owns a job with
  `BREAKAWAY_OK | KILL_ON_JOB_CLOSE | ACTIVE_PROCESS` limits (the §7.1 caps live
  here). This is the **only** valid place for BREAKAWAY_OK — the daemon controls
  its own job, unlike sshd's.
- `spawnContainedSession`: `CreateProcessW` with `CREATE_BREAKAWAY_FROM_JOB |
  CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW`, then a fresh per-session
  `CreateJobObjectW` + `AssignProcessToJobObject`. If reassignment is refused it
  returns `JobAssignFailed` (the real agent then nests a job).
- `jobAccounting` (`QueryInformationJobObject` → `ActiveProcesses`) and
  `killSession` (`TerminateJobObject`) cover the monitor view (§9.3) and the
  race-safe subtree kill (§9.2) — reaps `setsid`-style escapees a pgid walk misses.

## 5. Ctrl-C escalation (§9.2)

- `interruptSession`: writes `0x03` to the ConPTY input handle (handles the direct
  console-read case), then `GenerateConsoleCtrlEvent(CTRL_C_EVENT, pgid)` (the
  child is in its own process group from `CREATE_NEW_PROCESS_GROUP`). **Interrupt
  is not a kill** — only an explicit `+remote kill` calls `TerminateJobObject`.

---

## extern inventory — what `std.os.windows` (0.15.2) lacks

Confirmed by grepping the bundled std. **Present** (reused directly):
`GetStdHandle`, `CreateNamedPipeW`, `CreateFileW`, `ReadFile`, `WriteFile`,
`CloseHandle`, `WaitForSingleObject`, `GetLastError`, `STD_INPUT_HANDLE`,
`STD_OUTPUT_HANDLE`, `CTRL_C_EVENT`, `SECURITY_ATTRIBUTES`, `STARTUPINFOW`,
`PROCESS_INFORMATION`, `HLOCAL`.

**Absent → declared in `win32.zig`** (matches the §17 list exactly):

| API | Lib | Why |
|---|---|---|
| `ConnectNamedPipe`, `DisconnectNamedPipe` | kernel32 | pipe server accept |
| `WaitNamedPipeW` | kernel32 | schtasks startup race (§4.1) |
| `GetNamedPipeClientProcessId` | kernel32 | peer-cred identity (§9.5) |
| `CreateJobObjectW`, `AssignProcessToJobObject`, `TerminateJobObject`, `SetInformationJobObject`, `QueryInformationJobObject` | kernel32 | containment + caps + kill (§9.1) |
| `GenerateConsoleCtrlEvent` | kernel32 | Ctrl-C (§9.2) |
| `CreateMutexW` | kernel32 | single-instance (§4.1) |
| `ConvertStringSecurityDescriptorToSecurityDescriptorW`, `LocalFree` | advapi32 | owner-only DACL (§15 M6) |
| `CreateProcessW` (DWORD-flags variant) | kernel32 | std's typed flags hide `CREATE_BREAKAWAY_FROM_JOB`/`CREATE_NEW_PROCESS_GROUP`; redeclared with a plain DWORD (the project already does this at `src/os/windows.zig:91`) |

Also declared: the Job-Object structs (`JOBOBJECT_BASIC_LIMIT_INFORMATION`,
`JOBOBJECT_EXTENDED_LIMIT_INFORMATION`, `IO_COUNTERS`,
`JOBOBJECT_BASIC_ACCOUNTING_INFORMATION`), `JOBOBJECTINFOCLASS`, and the
process-creation / pipe / job / error constants. `PSECURITY_DESCRIPTOR` is just a
`LPVOID` (also absent from std).

> Suggested home in the real tree: fold these into the existing
> `src/os/windows.zig` `exp` namespace (which already holds HPCON, the ConPTY
> externs, and `FILE_FLAG_FIRST_PIPE_INSTANCE`) so the agent and the GUI share one
> declaration site, rather than a separate `win32.zig`.

---

## Cross-compile proof (build-time)

Run from the repo root with a zig 0.15.2 toolchain. `protocol` is supplied as a
module (build.zig will wire the same module for the real agent):

```sh
# x86_64
zig build-exe -target x86_64-windows-gnu \
  -femit-bin=ghoztty-agent-spike.exe \
  --dep protocol \
  -Mroot=src/remote/agent/spike/main.zig \
  -Mprotocol=src/remote/protocol.zig

# aarch64
zig build-exe -target aarch64-windows-gnu \
  -femit-bin=ghoztty-agent-spike-arm.exe \
  --dep protocol \
  -Mroot=src/remote/agent/spike/main.zig \
  -Mprotocol=src/remote/protocol.zig
```

Observed (this Mac):

```
ghoztty-agent-spike.exe:     PE32+ executable (console) x86-64,  for MS Windows
ghoztty-agent-spike-arm.exe: PE32+ executable (console) Aarch64, for MS Windows
```

Both link cleanly against MinGW's kernel32 + advapi32 import libraries → all
extern prototypes are well-formed. (The default native macOS target of this
zig 0.15.2 cannot even link a hello-world because the host SDK is macOS 26; use
`-target x86_64-windows-gnu` as above, or `-target <arch>-macos.13.0.0` for the
host-side unit tests in WP1/WP3.)

---

## On-Windows test procedure (must run on real hardware)

Prereqs: a Windows host with OpenSSH Server (§13.2), key auth as a **non-admin**
user (§13.3). Build & copy the spike (or the real agent) with `scp`.

1. **Single-instance + pipe creation.** Run `ghoztty-agent-spike.exe daemon`.
   Then, from a second shell, run it again → expect the second to log
   *"another daemon already owns the singleton; exiting"* (named mutex).
2. **Binary-stdio fidelity (the blocker).** Over ssh, pipe all 256 byte values
   through `ghoztty-agent-spike.exe bridge` and diff the round-trip:
   `ssh winbox "ghoztty-agent-spike.exe bridge" < all256.bin > out.bin` and
   `cmp all256.bin out.bin`. **If raw differs, COBS must be the default** (it is).
3. **Squatter rejection.** As user A, create the pipe; as user B (different
   account), start the daemon → `createDaemonPipe` must return `PipeNameSquatted`
   (ACCESS_DENIED from `FIRST_PIPE_INSTANCE`).
4. **Peer-cred.** Connect a bridge; confirm the daemon logs the bridge's real PID
   (`GetNamedPipeClientProcessId`).
5. **Out-of-band daemon survival.** `spawn-daemon` mode registers + runs the
   Scheduled Task; start a session, then `kill` the ssh connection (sshd teardown)
   → the session keeps running; reconnect and confirm reattach (mirrors §13.6).
6. **Job topology.** Spawn a session; `QueryInformationJobObject` shows it in the
   per-session job; spawn a `Start-Process`-detached grandchild → still in the
   job; `TerminateJobObject` reaps the whole subtree. If `AssignProcessToJobObject`
   returns `JobAssignFailed`, exercise the nested-job fallback.
7. **Ctrl-C escalation.** Run a `pwsh` loop; `interrupt` → `0x03` + console ctrl
   event interrupts without killing; `+remote kill` → `TerminateJobObject` ends it.
8. **OSC 9;9 cwd.** (Real agent only) confirm the injected prompt emits
   `OSC 9;9;<$PWD>` from pwsh/cmd and a hostile cwd value stays inert (§9.4).

---

## `Command.zig` → `CommandCore` refactor assessment (§17)

`Command.zig` is 911 lines and looks heavy, but its coupling to the GUI graph is
**only three thin points** — the refactor is small (~2–4 h, matching §17):

1. **`global_state.rlimits.restore()`** (line 219, the single use of `global.zig`).
   In the child after fork, before exec. → Inject a `ResourceLimits` value into
   the spawn options (`opts.rlimits`); the agent passes its own. Removes the
   `@import("global.zig")` and its transitive state.

2. **`apprt.runtime.pre_exec` / `post_fork`** (lines 142–155). Two `@hasDecl`
   guards pick an apprt-specific `PreExecInfo`/`PostForkInfo`, else an empty
   struct. This `@import("apprt.zig")` is what drags the renderer/font/config
   graph. → Make these two info types **comptime-injectable** (a struct of types
   on the spawn options, defaulting to the empty structs). The headless agent
   passes the empty structs and never imports `apprt`.

3. **`configpkg.Config`** (lines 143, 152). Used *only* as the parameter type in
   the two inline `init(_: *const configpkg.Config)` signatures above, and the
   param is unused (`_`). It disappears with (2) — no separate work.

Net: extract the spawn core (pty fd wiring, `CreateProcessW`/`fork`+`exec`,
`ConPTY` attach, wait/reap) into `CommandCore` parameterized by
`{ rlimits, PreExecInfo, PostForkInfo }`. `Command.zig` becomes a thin GUI wrapper
that supplies the apprt/config/global values; the agent links `CommandCore`
without pulling the renderer. The Windows ConPTY path (`startWindows`, the
`PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` plumbing at `src/Command.zig:294`) is
already config/apprt-free and moves wholesale.

**Risk:** low. No fork/exec or ConPTY logic changes — it is a dependency-injection
extraction. The one subtlety is preserving the post-fork ordering of
`rlimits.restore()` relative to the pre_exec hook (keep the exact sequence).
