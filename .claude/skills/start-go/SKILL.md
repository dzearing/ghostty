---
name: start-go
description: Use when the user asks to start, restart, or supervise the go-loop ("start go", "/start-go", "get the loop running", "is the loop alive"). Brings up the parity tracker in a side pane of THIS controller chat, ensures the go.md loop is running in a SEPARATE window, and then monitors it every 2 hours - dissecting and fixing the cause whenever it stops.
---

# Start and supervise the go-loop

Three halves, always all three, in order. This session is the **controller**: it
does not run the loop, it watches it. The loop runs in its own window.

## 1. The tracker, in a side pane of this chat

```powershell
powershell -NoProfile -File scripts\task-dashboard.ps1 -Install
```

`-Install` registers the `GhozttyTaskDashboard` keep-alive task (every 5m) and
starts the server; then the pane. Both halves are idempotent - an already
listening server is reused, and an existing `tasks` pane is focused rather than
opened twice. Run it **from this pane** so `$GHOZTTY_PANE_ID` splits the
dashboard off the controller chat rather than off whatever window was last
focused.

The keep-alive is not optional. The server is a child of the Ghoztty that
spawned it, so it sits inside the app's kill-on-close job and dies with every
app restart - which is what "the tracker died" was on 2026-08-11. The scheduled
task is created by the Task Scheduler service, outside that job, so it comes
back on its own.

## 2. The loop, in a window of its own

```powershell
powershell -NoProfile -File scripts\go-loop-health.ps1
```

- exit **0** (`HEALTHY`) - a loop is already running. Do not start another.
- exit **1** (`DEGRADED`) - running, but read the `-` notes and fix what they
  name before moving on.
- exit **2** (`DOWN`) - no live owner. Start one:

  ```powershell
  powershell -NoProfile -File scripts\go-loop-watchdog.ps1 -Once -Force
  ```

  That is the supervisor's own re-entry path (opens a Ghoztty window, launches
  claude in it, types the go.md prompt) rather than a second way of doing the
  same thing. Confirm with `go-loop-health.ps1` afterwards; `windows=1` and
  `state=held` is the shape you want.

**Never claim the loop from this session.** If `go-loop-lock.ps1 status` reports
`mine=True` here, the controller has taken the loop's slot - release it
(`go-loop-lock.ps1 release`) and let the loop window own it. A controller
holding the lock is invisible to every check and is exactly how one window ends
up believing it is primary while another actually is.

## 3. Monitor every 2 hours

Set up the recurring check with the `loop` skill:

```
/loop 2h powershell -NoProfile -File scripts\go-loop-health.ps1 -Postmortem
```

Each tick prints ONE timestamped line carrying **uptime** - how long the loop
has run unbroken - plus turn, the claimed task, open-decision count, marked
window count, watchdog and dashboard state. Uptime is the signal that matters:
`alive` alone cannot tell a loop that has run all night from one revived forty
seconds ago, and the difference is the whole question.

### When a tick is not HEALTHY, dissect before restarting

Restarting first destroys the evidence - the lock file holds only the current
state, so a revival overwrites the death. Work down this list, then fix the
cause, then restart:

1. **Read the ledger.** `temp\go-loop-history.jsonl` is append-only: one row per
   acquire / heartbeat / release, each with `at`, `turn`, `reason` and
   `uptime_m`. A `reason` of `dead-owner`, `stale-heartbeat` or `rebooted` with
   `turn` back at 1 means the loop was killed and revived, not that it stopped
   by itself. `rebooted` specifically means the machine booted after the run
   started - the pane id survived a Ghoztty session restore, but the run did
   not, and the uptime clock restarts because it genuinely should. Cross-check
   the boot against `Get-WinEvent -LogName System -Id 1074,41`: a planned
   Windows Update restart is expected and only the *recovery* is in scope,
   while a Kernel-Power 41 with no 1074 beside it is a hard crash worth chasing.
2. **Was it a hanging decision?** `decisions_open` in the health line. A loop
   that filed a decision and stopped has broken go.md step 5b, which says file
   it and *keep going*. Fix the loop's behavior (and the wording in go.md if it
   invited the stop), never just answer the decision and move on.
3. **Was it a Ghoztty restart?** `-Postmortem` prints the `ghoztty.exe` and
   `ghoztty-agent.exe` start times. If they are newer than the loop's
   `acquired`, the app went down and took claude with it. That is the 2026-08-11
   shape: the app restarted at 08:19:34, the loop owner died with it, the
   watchdog opened a second window at 08:21, and the tracker died at the same
   instant. Check for a crash record (`Get-WinEvent` on `Application`, filtered
   to `ghoztty`) - a crash is a Ghoztty bug and gets a parity task; a clean
   restart (upgrade, morning refresh, the user relaunching) is expected and
   only the *recovery* is in scope.
4. **Was it the turn protocol?** If the last transcript activity is long before
   the death, the turn ended without step 7 (`/reset-context read go.md and
   go`). That is a go.md failure, not a crash - the loop does not restart
   itself, so a turn that stops to report success kills it silently. Fix by
   making the step harder to miss, not by restarting once.
5. **Duplicate loops?** `windows=` above 1, or a held lock whose pane is not the
   marked window. Two sessions on one tracker clash. Close the impostor with
   `go-loop-exec.ps1 list` to identify it.

Apply the fix in the same turn, commit it, and say plainly what died, why, and
what now prevents it. A restart without a cause is a restart you will do again
in two hours.
