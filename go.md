# go.md — on-box (Windows) session entry point

You are the on-box Windows session for the Windows parity effort.

## THE TURN (user, 2026-07-28 — this is the whole job, every time)

> pick up a task, build it, test it, make sure it's right, assess if more
> tasks need to be done, update the task doc with status and new tasks, then
> `/reset-context` to start over

Concretely, in order, with no stops in between:

0. **Claim the loop** (T139) — one command, before anything else:

   ```
   powershell -NoProfile -File scripts\go-loop-exec.ps1 claim
   ```

   - Exit **0** (`PRIMARY …`): you are the execution window. Carry on.
   - Exit **3** (`STAND-DOWN …`): another session already holds the loop.
     This window has been unmarked and closed; **stop, do not pick a task.**
   - What it does: takes the lock (`scripts\go-loop-lock.ps1`), pins this
     window's title to `[go-loop] …` so the execution window is identifiable
     on sight and in `+list --json`, then resolves duplicates **without
     asking anyone** — it messages the other window's session to say it is a
     duplicate, closes it, and continues.
   - **Only `[go-loop]`-marked windows are ever touched.** A second Claude
     window that is filing tasks, auditing, or reviewing is unmarked, so it is
     never a rival and never gets closed. That is the normal case on this box.
   - The arbiter is the lock, not a negotiation: whoever holds it is primary,
     which is symmetric and cannot deadlock. Ownership is keyed on the
     **pane**, so a relaunched claude in the same pane is the same slot (the
     upgrade script does exactly that). A lock whose owner died — or whose
     heartbeat is older than 30 min — is taken over automatically, so a crash
     never wedges the loop.
   - `scripts\go-loop-exec.ps1 list` shows every window and which are marked.

1. **Pick up a task** — first Current-priorities item, else
   `powershell -NoProfile -File scripts\parity-tasks.ps1 next`. Never ask
   which one.
2. **Build it.**
3. **Test it** — the task's own Validation, plus the standing floor (both
   `zig build test` lanes, `zig build test-agent`, P1–P3).
4. **Make sure it's right** — validation must actually pass, on the box. A
   clean build is not evidence, and neither is a passing script you did not
   read the last line of.
5. **Assess whether more tasks are needed** — every bug, gap, or surprise the
   work turned up becomes a NEW task file, minted with
   `scripts\parity-tasks.ps1 new -Title "…"`. Loose threads are how work gets
   lost. Never hand-pick an id; `new` allocates atomically so a second agent
   filing at the same moment cannot collide with you.
6. **Update the tracker** — `scripts\parity-tasks.ps1 set-status <id> -Status
   done -Commit <sha>`, evidence into that task's own file, ONE log entry in
   `docs/design/windows-parity-log.md`. Run `scripts\parity-tasks.ps1
   validate` before committing. Commit and push. Refresh the lock while you are here
   (`scripts\go-loop-lock.ps1 heartbeat`) — a long task is the one case where
   a turn can outlive the watchdog's staleness window.
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

1. Pick exactly **one** task (`scripts\parity-tasks.ps1 next`).
2. Do it: implement → validate on the box → update the task file + session
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
task is too big: split it into sub-tasks (e.g. "T19a design" + "T19
implement" — `parity-tasks.ps1 new`, then set the parent to
`skipped(split → …)`), commit the split, and reset.

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

1. **Tasks live one-per-file** in `docs/design/windows-parity-tasks/`
   (`T<id>.md`, YAML frontmatter + Summary + Details). This replaced the
   single state table on 2026-07-29 so two agents can file and edit tasks
   without writing to the same file — see that directory's `README.md` for
   the format and the full command set.

   **Do not read the directory wholesale.** Use the script, then read only
   the one task file you are working:

   ```
   powershell -NoProfile -File scripts\parity-tasks.ps1 next
   powershell -NoProfile -File scripts\parity-tasks.ps1 show T144
   ```

   `docs/design/windows-parity-tasks.md` is still worth reading for its
   narrative sections — the resume protocol, **Current priorities** (which
   still outranks `next`), and the key code landmarks — but its **state
   table is frozen**: a historical snapshot, no longer ground truth. Never
   add a row to it. Likewise `windows-parity-details.md` is frozen; its
   per-task sections were copied into the task files, and the task file
   wins. The session log (`windows-parity-log.md`), the audit appendix
   (`windows-parity-audit.md`), and the spec (`windows-parity-spec.md`) are
   unchanged — open at most the one section you actually need, never all of
   them "for background".
2. Work **one** task, per the context rule above. At the boundary, record
   status and evidence in the task's own file, and append ONE short entry to
   `windows-parity-log.md` (no build output, no diffs). Run
   `scripts\parity-tasks.ps1 validate` before you commit.
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
- **BUILD THE STAGING RELEASE FIRST — the upgrade never builds** (2026-07-30,
  T208). `upgrade-ghoztty-windows.ps1` copies whatever is already sitting in
  `zig-out-release`, and `launch-upgrade.ps1` only checks that the directory
  *exists*. Skip the build and the delivery ships the PREVIOUS delivery's
  binary while `LAUNCH OK`, `exe swapped` and `UPGRADE OK` all report success.
  That happened delivering T202: the installed release still reported
  `+9968a62d9` afterwards. So, before the launch:

  ```powershell
  zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast `
      -Dtarget=x86_64-windows-gnu -Dstrip=false --prefix zig-out-release
  ```

  and after it, `ghoztty +version` must report `git rev-parse --short HEAD`.
  A delivery is not done until you have READ that commit back.

- **Launch that upgrade through `scripts/launch-upgrade.ps1`, never with a
  hand-rolled `Start-Process`** (2026-07-30, T200). Call it IN-PROCESS from
  the turn's last tool call so the prompt binds as one string:

  ```powershell
  & D:\git\ghoztty\scripts\launch-upgrade.ps1 `
      -Prompt '/reset-context <verify this delivery…> Then read go.md and go'
  ```

  It writes the prompt to a file (never argv), starts the upgrade detached,
  and then WAITS for the upgrade script's first log line before reporting
  success — so a launch that dies fails in *this* turn, while someone is
  still watching. Exit 0 = confirmed running; anything else = the installed
  release was NOT upgraded, so do not report the delivery as done.

  Why it exists: `Start-Process -ArgumentList @(…)` does not quote its
  elements, so a multi-word `-ResumePrompt` is re-tokenized into positional
  arguments. On 2026-07-30 that killed parameter binding *before* the
  script's first line — nothing logged, stderr thrown away with the hidden
  window — and the turn reported "upgrading now" over a delivery that never
  happened. The loop then sat dead for 45 minutes until the watchdog fired.
