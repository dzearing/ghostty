# go.md — on-box (Windows) session entry point

You are the on-box Windows session for the Windows parity effort.

## THE TURN (user, 2026-07-28 — this is the whole job, every time)

> pick up a task, build it, test it, make sure it's right, assess if more
> tasks need to be done, update the task doc with status and new tasks, then
> `/reset-context` to start over

Concretely, in order, with no stops in between:

0. **Take the loop lock** (T139) — one command, before anything else:

   ```
   powershell -NoProfile -File scripts\go-loop-lock.ps1 acquire
   ```

   - Exit **0** (`ACQUIRED …`): you own the loop. Carry on.
   - Exit **3** (`BUSY owner_pane=… age=…m`): **another session is already
     running this loop.** Say so, name the owner, and STOP — do not pick a
     task. Two loops on one tracker clash (that is exactly what T138's
     upgrade-script fork did on 2026-07-28: both sessions built T131).
   - The same command each turn refreshes the heartbeat, and a lock whose
     owner died — or whose heartbeat is older than 30 min — is taken over
     automatically, so a crash never wedges the loop. Ownership is keyed on
     the **pane**, so a relaunched claude in the same pane is the same slot.

1. **Pick up a task** — first Current-priorities item, else first `todo` whose
   deps are `done`. Never ask which one.
2. **Build it.**
3. **Test it** — the task's own Validation, plus the standing floor (both
   `zig build test` lanes, `zig build test-agent`, P1–P3).
4. **Make sure it's right** — validation must actually pass, on the box. A
   clean build is not evidence, and neither is a passing script you did not
   read the last line of.
5. **Assess whether more tasks are needed** — every bug, gap, or surprise the
   work turned up becomes a NEW row. Loose threads are how work gets lost.
6. **Update the tracker** — row status + commit, details evidence, ONE log
   entry. Commit and push.
7. **`/reset-context read go.md and go`, and end the turn there.**

**Ending a turn any other way is a failure, not a pause.** The loop
perpetuates itself through step 7. A turn that stops after step 6 to report
success leaves the loop dead — that already cost six days (2026-07-21 →
2026-07-27) and killed it again on 2026-07-28. Finishing a task is not a
reason to stop; finishing IS the trigger to reset and take the next one.

Since T139 there IS a supervisor, but do not lean on it: the watchdog
(`scripts\go-loop-watchdog.ps1`, a per-user scheduled task) only notices the
step-0 heartbeat going stale, and only re-enters after up to ~45 min of dead
time. It is the safety net for a crash, not a substitute for step 7.

The one allowed exception: if the reset probe finds this session is not in a
Ghoztty pane, say so plainly and ask the user to run `/clear`.

## THE CONTEXT RULE (read this first, it overrides everything below)

**One task per context. Then reset. No exceptions.**

A previous session ignored this and ran to a 716k-token context by chaining
task after task. Long contexts get slow, expensive, and forgetful — and the
work is *already* durable in git + the tracker doc, so there is nothing to
"keep in your head" across tasks.

Concretely:

1. Pick exactly **one** task (the first `todo` whose deps are `done`).
2. Do it: implement → validate on the box → update the tracker row + session
   log → commit → push.
3. **STOP and reset context.** Do NOT keep working after invoking a reset —
   the clear only fires when your turn ends, so continuing silently cancels
   it (this is exactly how the 716k session happened).
   - `/reset-context` works on this box as of 2026-07-13 IF this session
     runs inside the installed release Ghoztty
     (`%LOCALAPPDATA%\Programs\Ghoztty\ghoztty.exe`, on the user PATH,
     IPC-capable, refreshed via T36). The skill's Step 1 branches on
     `/proc/self/winpid` → `ghoztty +list --pid=…` (fixed in the
     dzearing-claude-marketplace repo + the plugin cache).
   - If the session is NOT in a Ghoztty pane (e.g. Windows Terminal, or the
     old pre-IPC portable build), the probe returns nothing — then **ask
     the user to run `/clear`** and stop, as before.
4. The fresh session re-reads this file and the tracker, and picks up the
   next task with a clean context.

**Check your context usage at every task boundary.** If you are above ~150k,
reset even if you feel mid-flow. If a single task pushes you past ~250k, the
task is too big: split it into sub-tasks in the tracker (e.g. "T19a design"
+ "T19 implement"), commit the split, and reset.

**Keep tool output small.** Prefer `zig build ... 2>&1 | Select-String error`
over dumping full build logs; prefer `| Select-Object -Last 1` on acceptance
scripts (they print a single ALL PASS / N FAILURE(S) line by design). Read
only the parts of files you need.

**NEVER pipe a build into `Select-Object -First N`.** `-First` STOPS the
pipeline once it has N items, which tears down the still-running native
command: `zig build` dies mid-run and reports **exit -1 with no failure
text**. This is a FALSE failure and it has already been mis-filed twice as a
"transient exit=-1" flake (T89h, then T89i). `-Last N` is safe (it must drain
the whole stream). When you want the first few matches, redirect first and
filter the file: `zig build test -Dapp-runtime=win32 *> $log; "exit:
$LASTEXITCODE"; Select-String -Path $log -Pattern 'error:' | Select-Object
-First 10`. Rule of thumb: a lane that "fails" with warnings but no `error:`
line did not fail — re-run it unfiltered before believing it.

## What to do

1. Read `docs/design/windows-parity-tasks.md`. It is the canonical
   state/task doc; the state table is ground truth. **Read only that file.**
   The per-task details (`windows-parity-details.md`), the session log
   (`windows-parity-log.md`), the audit appendix
   (`windows-parity-audit.md`), and the spec (`windows-parity-spec.md`) are
   split out on purpose — open at most the one section you actually need for
   your task (for details, Grep `^## T<id> ` and Read that slice), never
   all of them "for background".
2. Follow its resume protocol for **one** task, per the context rule above.
   At the boundary, append ONE short entry to `windows-parity-log.md` (no
   build output, no diffs).
3. The repo CLAUDE.md is written from the Mac seat (app bundles, unix
   sockets, /Applications paths). Where it conflicts with the tracker doc,
   the tracker doc wins on Windows. The "never touch /Applications/
   Ghoztty.app" rule has an on-box analog: never touch an installed
   Ghoztty under Program Files or the user's extracted portable dir —
   always run the freshly built `zig-out\bin\ghoztty.exe`.
4. Sync discipline: `git pull` before starting, push at the task boundary —
   the Mac seat works Mac-side tasks on the same branch.

## Standing quality bar (from the user, 2026-07-12; expanded 2026-07-15)

- Full parity with every Mac feature that translates; build Windows-native
  equivalents where the concept doesn't (e.g. shell flavors, `+list --pid`
  instead of `--tty`).
- **No mega files.** Split modules as they grow (see `src/apprt/win32/`
  IpcServer/IpcHandlers/IpcRegistry and `src/apprt/ipc/args.zig`).
- **Everything gets tests.** Pure logic → unit tests in the none-runtime
  lane; behavior → an on-box validation script. Both test lanes
  (`-Dapp-runtime=none` and `-Dapp-runtime=win32`) must be green, `zig build
  test-agent` must be green (agent floor, T89b), and the P1–P3 acceptance
  scripts in `test/win32/` must stay ALL PASS.
- **Reliable and fast under long-context use** (2026-07-15): no crashes,
  no slowdowns, tuned for hours-long Claude Code sessions (T53 tracks the
  soak/tuning pass). Windows UI affordances should look Windows-native,
  not like bare controls (T50 is the pattern-setter).
- **Fully autonomous** (2026-07-15): the user steps away — never stop to
  ask clarifying questions mid-process; audit your own trail; use
  adversarial investigation for hard problems and recommended approaches
  where they exist. After a task: verify, mark the doc, audit the task
  list for gaps, commit/push, `/reset-context read go.md and go`, repeat.
- **Deliver to every install location** when a fix matters to the user:
  installed release (`%LOCALAPPDATA%\Programs\Ghoztty`), Desktop portable
  (`D:\Users\David\Desktop\Ghoztty-portable-x64`), and the share copy
  (`\\homeassistant\share\ghoztty-windows`). A fix that only lives in
  zig-out does not exist as far as the user can tell (the T49 lesson).
- **Never override `-ResumeCommand` on `scripts/upgrade-ghoztty-windows.ps1`**
  (2026-07-18): the default (`claude --dangerously-skip-permissions
  --continue "read go.md and go"`) is what re-enters this loop after the
  kill/swap. A plain `claude` override relaunched a blank session and
  stalled the loop for ~1.5 days (2026-07-17 02:32 → user return). The
  script now substitutes the default for any --continue-less override
  unless `-AllowPlainResume` is passed. Also finish the turn (commit,
  tracker updated) BEFORE launching the script — it kills Claude after
  `-DelaySeconds`.
