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

0.5. **Daily digest** (user, 2026-08-05) — before picking a task, check
   `docs/design/windows-parity-digests/<today>.md` (local date). If it is
   **5am or later** and today's file does not exist, write it now; then carry
   on with the turn. Rules:

   - **One file per day, today only — never backfill.** If the loop was down
     for three days, the next turn writes today's digest and nobody writes the
     missing two: a digest is a morning read, not a ledger, and a backfilled
     reflection is fiction.
   - It renders in the dashboard's **Daily digest** view (markdown: headings,
     lists, bold, links). Frontmatter: just `date: "YYYY-MM-DD"`. The view
     renders its own day/date header, so the body starts at the categories.
   - **The body has two CATEGORIES, each an H2, rendered as tabs** (user,
     2026-08-06): `## Commentary` (this step writes it) and `## Task triage`
     (step 0.6 writes it). Subsections inside a category are H3s.
   - **Audience: the user, over coffee.** Plain language, no task-id soup —
     name a task id only when they might click it. `## Commentary` covers:
     - **Yesterday** — what actually landed (from the log and the tracker's
       activity), and what it means for the end goal, not a commit list.
     - **Today's focus** — what the queue says comes next and why that is the
       right next thing.
     - **Reflection** — a genuine step back: how the work has been going,
       common themes across recent tasks and decisions, what keeps recurring.
       Are tools missing? Skills missing? Is the UX clean? Which gaps still
       stand between here and **merging back into main**? Think out of the
       box; propose process changes, not just code changes.
     - **Decisions** — anything filed for the user's call, and any directives
       from recently resolved ones that should steer the day.
   - Write it from evidence (the log, `git log` since yesterday 5am, the
     dashboard payload, resolved decisions), not from memory of the session.

0.6. **Daily triage** (user, 2026-08-06; option A of the convergence
   decision) — runs whenever step 0.5 wrote a new digest, immediately after
   it. Purpose: the backlog CONVERGES only if intake is controlled and the
   completion number has a fixed denominator. Mechanics:

   - **Milestone cutline.** `milestone: "M1"` in a task's frontmatter marks
     it part of the current convergence target; the dashboard's number is
     M1-closed / M1-total, never done/all-time. **New tasks default OUT of
     M1** — promotion is a deliberate triage act, with the same bar as a P0/
     P1 call: user-facing, or blocking a user-facing task, or blocking the
     merge-back goal. Never remove a task from M1 to make the number move —
     scope-cuts are `skipped(reason)`, visible as closures, not silent
     demotions.
   - **Sweep new-since-yesterday tasks** (git: task files added since the
     last triage): confirm each has a sane `priority:` + `triage-reason:`,
     wire `deps:` both ways (a follow-up depends on its parent; a split's
     children carry the parent's deps), and make the M1 in/out call.
   - **Dependency hygiene, whole backlog**: deps naming a missing id, deps
     already satisfied (parent done/skipped), and cycles. `order:` is
     re-derived where it contradicts deps — a dependent never sorts before
     what it waits on. (Do not hand-renumber the world; fix contradictions.)
   - **Staleness sweep**: open todos untouched for 30+ days, or whose
     subject a later task/fix superseded, become PROPOSED closes — listed in
     the triage summary with a one-line reason each. A proposal the user has
     not vetoed by the NEXT day's triage is closed as `skipped(stale: …)`.
     Never close a P0/P1 by staleness alone.
   - **Write `## Task triage`** into today's digest: counts (filed
     yesterday, closed yesterday, net flow, M1 closed/total), what was
     promoted into M1 and why, dep repairs made, proposed closes awaiting
     veto, and yesterday's proposals now enacted. **Scannable, never dense**
     (user, 2026-08-06): lead with an H3 stat line (`### M1: X of Y
     closed`), then short bold-labeled bullets — one idea each, two
     sentences max. No wall-of-prose paragraphs; this is read on a
     dashboard at a glance.
   - Commit triage-only frontmatter churn as `chore(triage): …` — the
     modified-date column must not read a bulk re-triage as work on 200
     tasks.

1. **Pick up a task — ONE command, which also claims it:**

   ```
   powershell -NoProfile -File scripts\parity-tasks.ps1 next -Claim
   ```

   Never ask which one. `-Claim` marks the task it hands you `in-progress` in
   the same breath, and that mark is the ONLY thing that says what is being
   worked right now: the loop lock records the pane, the turn and a heartbeat
   but NOT the task. This used to be two commands — `next`, then a separate
   `set-status` — and a turn that ran the first and forgot the second left a
   watching human with a dashboard that could see the loop was alive and still
   could not name what it was doing (user, 2026-08-04: *"why is the loop status
   not getting updated"*). Picking and claiming are one act; they are now one
   command, which is the only version that cannot be half-done.

   **If it answers `RESUME:` instead of `NEXT:`, that IS your task** (user,
   2026-08-05). One agent runs this queue at a time, so a task still
   in-progress when a turn starts is a stale claim — the turn that made it
   died (crash, reboot, reset) or forgot to close out. Two bluescreens on
   2026-08-05 left T496/T497 exactly there: in-progress with no agent, half
   the fix uncommitted in the tree, and nothing telling the next turn. On a
   RESUME, **reassess before you build**: read the task's `## Progress log`,
   run `git status`/`git diff` on the files its Where section names, and
   decide from evidence whether to keep-and-finish the uncommitted work or
   reset it and restart clean. If the task should NOT be resumed (superseded,
   wrong approach), record why with `note` and set it back to `todo` — never
   just take fresh work over the top of a stale claim.

   **Journal as you work.** `next -Claim` writes the first `## Progress log`
   entry for you; add one at each meaningful step:

   ```
   powershell -NoProfile -File scripts\parity-tasks.ps1 note T144 -Text "root cause: X; fix going into Y" -Session <your-session-id>
   ```

   At minimum: after the root cause / design is settled, after the build,
   after validation, and whenever something surprising changes the plan
   (include ids of any tasks you filed). This is not ceremony — the progress
   log is what the RESUME path reads when a turn dies mid-task, and
   `validate` fails an in-progress task that has none. Pass `-Session` with
   your session id when you know it, so a stale task names the conversation
   that was working it.

   **Tag it when you file it.** `new -Tags fix,polish` (closed set: `feature`
   / `fix` / `polish` / `perf` / `test` / `infra` / `docs` / `security`) —
   tags are how the dashboard tells user-facing work from internal work at a
   glance. When you claim an untagged task, add tags to its frontmatter as
   part of making it readable.

   `next` picks by **`order:`** (the queue, lowest first), then `priority:`,
   then id — so the head of the queue is one task, not a band of forty.
   Anything in **Current priorities** below still outranks it; that list is
   pinned by hand and `order:` is kept in step with it.

   `next` answers for **this box's seat** (T344): tasks marked `seat: mac` — a
   Swift fix, a macOS regression run — are the Mac seat's and are listed as
   skipped rather than handed to you. Do not take one; if you find a task you
   cannot validate here, mark it `seat: mac` and re-run `next`.

   Step 6 moves it to `done`; if you abandon it instead, set it back to `todo`
   rather than leaving it in progress. A task left in-progress whose file then
   goes untouched shows as **stale** on the dashboard and gets offered up for
   reset, which is the cleanup path for exactly this mistake.

   **Then make it readable.** Add these two sections to the task file if they
   are not already there — they are what a human watching the dashboard sees
   while you work:

   ```markdown
   ## In plain terms

   Two or three sentences, no jargon: what is wrong or missing right now,
   what will be different when this lands, and who notices. Name the symptom
   a user would describe, not the mechanism.

   ## Goals

   - [ ] the first concrete outcome
   - [ ] the second
   - [x] tick them off as they land
   ```

   A task title is a defect sentence written for whoever will fix it — "the
   session-interrupted notice never survives the ConPTY repaint" is precise
   and tells a watching human nothing. `## In plain terms` is the version
   they can read: no ConPTY, no repaint, no task ids. Write it for someone
   who has never opened this repo. Tick the goals as you go, so the card
   shows progress rather than a frozen list.

   **And give it validation criteria.** Every task carries a `## Validation
   criteria` checklist (`new` scaffolds it; add one to older files when you
   claim them): the observable checks that prove the task is done. Step 4
   ticks them — each tick names HOW it was verified (which script, which
   lane, which manual check). The dashboard's task detail view renders this
   checklist, so "what was validated" is answerable without the diff.
2. **Build it.**
3. **Test it** — the task's own Validation, plus the standing floor (both
   `zig build test` lanes, `zig build test-agent`, P1–P3). Run the three zig
   lanes through `scripts\floor-lane.ps1 -Lane all` (T430) rather than bare: a
   bare lane can wedge with no output and no timeout, and a wedge you cannot
   tell from a slow run is worse than a red test. The wrapper watches CPU as
   well as the clock, so it always ends with `PASS`, `FAIL` or `STALL` plus a
   diagnostic. **Run the lanes and the acceptance scripts sequentially, never
   overlapped** (T401): an acceptance script deliberately kills agents and
   takes the per-user pipe, and box load from a concurrent lane starved test
   waits badly enough to wedge the lane for 11+ minutes before T346/T258
   bounded them — today the same overlap costs a red flake that reads as
   "test-agent is flaky again". A background lane plus a foreground script is
   the exact shape that burned the T96 turn.
4. **Make sure it's right** — validation must actually pass, on the box. A
   clean build is not evidence, and neither is a passing script you did not
   read the last line of.
5. **Assess whether more tasks are needed** — every bug, gap, or surprise the
   work turned up becomes a NEW task file, minted with
   `scripts\parity-tasks.ps1 new -Title "…"`. Loose threads are how work gets
   lost. Never hand-pick an id; `new` allocates atomically so a second agent
   filing at the same moment cannot collide with you.
5b. **File any judgement call as a decision.** You never stop to ask (THE
   CONTEXT RULE), and that stays true — but a call the user might want to
   overturn gets a receipt, so it reaches them without blocking you:

   ```
   powershell -NoProfile -File scripts\parity-decisions.ps1 new ^
       -Title "<the question, phrased as a question>" -Task T123 ^
       -Assumed "<what you did meanwhile, so work continued>" ^
       -Options "Do X (Recommended)::Pros: a | b::Cons: c::Mitigation: d;;Do Y::Pros: e::Cons: f | g" ^
       -Why "<what forced the choice, in two or three sentences>"
   ```

   It surfaces at the top of the dashboard's Activity feed
   (`scripts\task-dashboard.ps1`). When the user picks an option, the answer
   is folded into the linked task automatically — so the reply lands where
   whoever picks that task up will see it.

   **What belongs here:** a fork you resolved by assumption and could not
   verify (which of two designs, how far to widen a fix, whether a surprise
   is in scope). **What does not:** anything you can settle by reading the
   code or running something — investigate instead; a decision is not a way
   to outsource work. Anything the tracker already answers. And never file
   one and then wait: keep going, exactly as before.

   Write it for someone who has not seen the code. `-Why` states what forced
   the choice. Each option carries **Pros:** and **Cons:** lists (`|` between
   items) — a list without both is not a choice, it is a quiz — and where a
   con can be reduced, a **Mitigation:** naming the extra work that reduces
   it ("adds complexity" → a thorough design pass to make sure the shape is
   the one that scales; "touches shared core" → cross-platform tests on both
   lanes first). If the mitigation is real work, file it with
   `parity-tasks.ps1 new` so picking that option does not silently drop its
   safety net. The dashboard renders these as bulleted Pros/Cons columns, so
   keep each item one crisp clause, not a paragraph.

   Exactly ONE option's label ends in **"(Recommended)"**, and that option is
   **listed first**: the pick that best balances robustness, performance,
   user experience, scale over time, and stability, with the fewest
   sacrifices. **Implementation effort and time are NEVER part of that
   balance** (user directive, 2026-08-05): we have time to get things right,
   and what a choice costs in engineering hours is not what it costs the
   customer. "Cheapest" and "fastest" are not pros; "no named experiment left
   that could produce information" is a valid con, because that is about
   evidence, not effort. (`parity-decisions.ps1` sorts the recommended option
   to the front and warns if the flag count is not exactly one.)
6. **Update the tracker** — `scripts\parity-tasks.ps1 set-status <id> -Status
   done -Commit <sha>`, evidence into that task's own file, ONE log entry in
   `docs/design/windows-parity-log.md`. Run `scripts\parity-tasks.ps1
   validate` before committing. Commit and push.

   **Your commit message is the activity feed.** The dashboard builds each
   feed item from the commit that finished the work: the subject becomes the
   headline, the first paragraph of the body becomes "what changed", and the
   tasks completed and filed in that commit hang off it. Write the subject as
   a plain statement of what now behaves differently, and open the body with a
   paragraph a reader can understand without the diff. That is already the
   house style — this is just what depends on it.

   Refresh the lock while you are here
   (`scripts\go-loop-lock.ps1 heartbeat`). Since T253 this is a checkpoint,
   not the loop's only pulse: the lock also follows the session transcript's
   mtime, which Claude Code advances on every message and tool result, so a
   long turn no longer reads as stale just because nobody ran a command. The
   manual refresh still matters as the fallback for a session whose transcript
   could not be resolved (`acquire` says which: `pulse=transcript` vs
   `pulse=heartbeat-only`).
7. **`/reset-context read go.md and go`, and end the turn there.**

**Ending a turn any other way is a failure, not a pause.** The loop
perpetuates itself through step 7. A turn that stops after step 6 to report
success leaves the loop dead — that already cost six days (2026-07-21 →
2026-07-27) and killed it again on 2026-07-28. Finishing a task is not a
reason to stop; finishing IS the trigger to reset and take the next one.

Since T139 there IS a supervisor, but do not lean on it: the watchdog
(`scripts\go-loop-watchdog.ps1`) only notices the step-0 heartbeat going stale,
and only re-enters after up to ~45 min of dead time. It is the safety net for a
crash, not a substitute for step 7.

The supervisor has its own supervision (T440): it stamps a heartbeat on every
tick, the dashboard shows a "Supervisor is down" line when that stops, and a
per-user scheduled task re-launches it every 10 minutes (a no-op while it is
alive — the single-instance mutex sees to that). Before T440 it was an HKCU Run
entry alone, which fires at logon and never again; it died at 09:14 one morning
and nothing noticed for thirteen hours. Ask it directly with:

```
powershell -NoProfile -File scripts\go-loop-watchdog.ps1 -Status
```

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
   **The live status dashboard** answers "where is this project" without
   reading any task file. It renders in a Ghoztty viewer pane and refreshes
   itself as task and decision files change:

   ```
   powershell -NoProfile -File scripts\task-dashboard.ps1
   ```

   Three views behind a side nav: **Activity** (open decisions that need the
   user, then a timeline of what landed), **Data** (the charts), **Tasks**
   (lookup and filtering, newest first). Decisions are filed by step 5b below
   and live in `docs/design/windows-parity-decisions/`.

   That starts a small localhost server (detached, survives the session) and
   splits a viewer pane **off the pane you ran it from** — it defaults
   `--target` to `$GHOZTTY_PANE_ID`, because a bare `+split` targets the most
   recently focused window and lands somewhere else. Both halves are
   idempotent: re-running reuses the server and focuses the existing pane.
   `-Stop` kills the server, `-NoPane` skips the split, `-Port` moves it off
   7788. It is served over http and NOT written to a `.html` file on purpose:
   a viewer renders `.md` and treats every other extension as code, so a local
   `.html` would display its own source. After a reboot, run it again.
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

   **Build it with `-Doptimize=Debug`, and not for speed** (T350): the app's
   IPC pipe, the local agent's pipe and the state directory are all derived
   from the build mode, and a non-debug `zig-out` derives *the user's* — so the
   whole acceptance suite silently drives the terminal they are sitting in and
   passes. That is **endpoint isolation**, it is what the flag buys, and a
   private `GHOZTTY_PIPE_SUFFIX` does not substitute for it (the agent pipe has
   no env override). Acceptance scripts now refuse such a build before they
   launch anything (`test\win32\lib\BuildMode.ps1`); if you hit that refusal,
   rebuild rather than reach for the `GHOZTTY_TEST_ALLOW_RELEASE=1` opt-in,
   which exists for the handful of scripts whose subject IS the release build.
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
- **The launcher now BUILDS the staging release and refuses to ship anything
  else** (2026-07-31, T208). `upgrade-ghoztty-windows.ps1` still never builds —
  it copies whatever sits in `zig-out-release` — so `launch-upgrade.ps1` does it
  first, with the exact incantation that used to be a remembered precondition:

  ```powershell
  zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast `
      -Dtarget=x86_64-windows-gnu -Dstrip=false --prefix zig-out-release
  ```

  It then reads the staged exe's `+version` and compares the baked commit
  against `git rev-parse --short HEAD`. A mismatch is **STALE STAGING**: the
  launcher exits 3 and nothing is delivered. The upgrade script re-checks the
  same number before the kill (a stale prefix skips the swap entirely and the
  installed release is left untouched) and reads the *installed* exe back after
  the swap, so `UPGRADE OK` means the right bits are on disk rather than "a file
  copy returned success". Then it mirrors to the Desktop portable and the
  `\\homeassistant\share` copy, best-effort.

  Why all that: skipping the build shipped the PREVIOUS delivery's binary while
  `LAUNCH OK`, `exe swapped` and `UPGRADE OK` all reported success. That happened
  delivering T202 — the installed release still reported `+9968a62d9`
  afterwards. **A delivery is still not done until you have READ that commit
  back** from `ghoztty +version`; the gates make a lie loud, not unnecessary.

  Escape hatches, both loud in the log: `-SkipBuild` (I already built it — the
  freshness check still runs) and `-AllowStaleStaging` (ship a commit that is
  not HEAD, e.g. a deliberate rollback). Acceptance:
  `test\win32\upgrade-staleness.ps1`.

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

  **Give that tool call a long timeout** (T208): it now builds first, and a cold
  ReleaseFast build runs several minutes. A call that gets pushed to the
  background takes the "fails while someone is watching" guarantee with it. The
  cheap shape is to run the build in its own earlier tool call — the launcher's
  rebuild is then a no-op of a few seconds, and the build path still gets
  exercised, which `-SkipBuild` would skip.

  Why it exists: `Start-Process -ArgumentList @(…)` does not quote its
  elements, so a multi-word `-ResumePrompt` is re-tokenized into positional
  arguments. On 2026-07-30 that killed parameter binding *before* the
  script's first line — nothing logged, stderr thrown away with the hidden
  window — and the turn reported "upgrading now" over a delivery that never
  happened. The loop then sat dead for 45 minutes until the watchdog fired.
