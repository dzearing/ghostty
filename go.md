# go.md — on-box (Windows) session entry point

You are the on-box Windows session for the Windows parity effort.

1. Read `docs/design/windows-parity-tasks.md` top to bottom. It is the
   canonical state/task doc. Its "On-box session bootstrap" section lists
   your first actions: native debug build, core tests, and the T03
   fake-pipe-server round-trip — record evidence in the state table.
2. Then follow the doc's resume protocol autonomously: pick the first
   `todo` task whose deps are done (T04 as of 2026-07-12), implement,
   validate ON THIS BOX per the task's Validation section, update the
   state table + session log, commit and push at every task boundary.
   Keep going through as many tasks as possible; stop only where a task's
   validation genuinely needs the Mac seat or the user.
3. The repo CLAUDE.md is written from the Mac seat (app bundles, unix
   sockets, /Applications paths). Where it conflicts with the tracker doc,
   the tracker doc wins on Windows. The "never touch /Applications/
   Ghoztty.app" rule has an on-box analog: never touch an installed
   Ghoztty under Program Files or the user's extracted portable dir —
   always run the freshly built `zig-out\bin\ghoztty.exe`.
4. Sync discipline: `git pull` before starting, push at every task
   boundary — the Mac seat works Mac-side tasks on the same branch.
