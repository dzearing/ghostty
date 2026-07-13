# go.md — on-box (Windows) session entry point

You are the on-box Windows session for the Windows parity effort.

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
3. **STOP and reset context.** Run `/reset-context read go.md and go`, reply
   with one short line, and end the turn. Do NOT keep working after invoking
   it — the clear only fires when your turn ends, so continuing silently
   cancels the reset (this is exactly how the 716k session happened).
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

## What to do

1. Read `docs/design/windows-parity-tasks.md` top to bottom. It is the
   canonical state/task doc; the state table is ground truth.
2. Follow its resume protocol for **one** task, per the context rule above.
3. The repo CLAUDE.md is written from the Mac seat (app bundles, unix
   sockets, /Applications paths). Where it conflicts with the tracker doc,
   the tracker doc wins on Windows. The "never touch /Applications/
   Ghoztty.app" rule has an on-box analog: never touch an installed
   Ghoztty under Program Files or the user's extracted portable dir —
   always run the freshly built `zig-out\bin\ghoztty.exe`.
4. Sync discipline: `git pull` before starting, push at the task boundary —
   the Mac seat works Mac-side tasks on the same branch.

## Standing quality bar (from the user, 2026-07-12)

- Full parity with every Mac feature that translates; build Windows-native
  equivalents where the concept doesn't (e.g. shell flavors, `+list --pid`
  instead of `--tty`).
- **No mega files.** Split modules as they grow (see `src/apprt/win32/`
  IpcServer/IpcHandlers/IpcRegistry and `src/apprt/ipc/args.zig`).
- **Everything gets tests.** Pure logic → unit tests in the none-runtime
  lane; behavior → an on-box validation script. Both test lanes
  (`-Dapp-runtime=none` and `-Dapp-runtime=win32`) must be green, and the
  P1–P3 acceptance scripts in `test/win32/` must stay ALL PASS.
