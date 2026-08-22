# Merge-back plan: taking upstream Ghostty into this fork

Written 2026-08-18 for **T879**, from the data in
[`windows-parity-divergence.md`](windows-parity-divergence.md) (T516). Every
number below is computed, not remembered; the commands that produce each one
are named so the plan can be re-derived when the inventory is regenerated.

## Which merge this is

Two different merges get called "merge back" and they are not the same job:

| | What it is | Where it is tracked |
|---|---|---|
| **Branch -> fork main** | `users/dzearing/windows-amd64` (1244 ahead) into `origin/main` (81 ahead of us) | the daily **main intake** in `go.md` step 0.6, one task per incoming commit |
| **Upstream -> fork** (this doc) | `ghostty-org/ghostty` `main` into this repo | nothing until now; 764 upstream commits are unmapped to any task |

They are independent: `origin/main` forked from upstream at the **same** commit
we did (`git merge-base origin/main ad6e72ddc` = `063ac3ecc`) and has never
merged upstream since. So the fork's `main` carries no upstream work we would
inherit for free, and this plan applies whichever branch does the merge first.

**This doc covers the second row only.** The first row already has a working
daily process and does not need a plan.

## The state of the divergence

- **Fork point:** `063ac3ecc` (2026-05-07)
- **Ours:** 1780 commits, 2104 files changed
- **Upstream:** `ad6e72ddc` (2026-08-15), 764 non-merge commits, 747 files changed
  - Every number below is measured against that pin, which is deliberate: an
    inventory that moves under S6 is not an inventory. `upstream/main` has since
    moved on (T957 fetched it at `e6605009b`), so S6's range grows a little each
    week until it is taken - re-run `scripts\divergence-inventory.ps1` before
    S6, not before S1.
- **Risk set (both sides touched):** 131 files
- **Changed only here:** 1973 files - no conflict possible
- **Changed only upstream:** 616 files - arrive clean

### What keeps these shas alive

Every sha this doc pins in backticks is anchored by a local lightweight tag,
`refs/tags/upstream-anchor/<sha>`, written by
`scripts\upstream-remote.ps1 ensure` (which `go-loop-exec.ps1 claim` runs every
turn) and asserted by `test\win32\upstream-remote.ps1` section A6b.

The anchor used to be `refs/remotes/upstream/main` alone, and that is not
durable. On 2026-08-22 a turn ran `git remote remove upstream` by hand; the
tracking ref went with it, re-adding the remote twelve minutes later did not
bring it back, and for the next hour and a half every sha below was reachable
from nothing and a `git gc` was entitled to drop it (T1099). A tag is a ref this
repo owns: no remote operation prunes it, it survives the remote being removed
outright, and because it is lightweight neither `git push` nor `push.followTags`
can leak it into `origin`.

**Re-cutting a stage means re-running `ensure`.** The sha list is read out of
this file, so a new pin is un-anchored until the script sees it - which is why
this doc is in the `upstream-remote` guard's coverage list and editing it makes
that harness due.

## The fact that decides the sequence: upstream is on Zig 0.16.0

Upstream commit **`e8525c0fd` "Update to Zig 0.16.0"** (authored 2026-05-07,
committed **2026-07-21**) raised `minimum_zig_version` to `0.16.0`. We are
pinned at **`0.15.2`** (`build.zig.zon:6`). That single commit:

- touches **357 files**, of which **71 are in the 131-file risk set** - more
  than half the entire merge risk lands in one upstream commit;
- splits upstream's range into **372 commits before** it and **392 after**;
- **deletes `src/os/env.zig`**, which we extended (+41 lines) and which **13
  files across our tree** call into (`internal_os.getenv` / `setenv` /
  `getEnvMap` / `appendEnv` / ...), two of them under `src/apprt/win32/`.

Nothing else in the range comes close in blast radius. Everything downstream of
the plan follows from putting that commit in its own stage rather than letting
it detonate inside a larger one.

A second consequence worth stating plainly: most of the Windows-looking churn
upstream (`src/os/windows.zig` +239/-105, `src/pty.zig` +46/-33) comes from
that same commit. It is **toolchain API churn, not upstream Windows work** -
`git log 063ac3ecc..ad6e72ddc -- src/os/windows.zig` returns exactly one
commit, and it is the Zig bump.

## How the 131 files were grouped

Two axes, both derived mechanically:

**Domain group (G1-G10).** Assigned by path with a first-match-wins rule, so
every file is in exactly one group. 131 assigned, **0 ungrouped**.

**Merge strategy (U / O / T),** from how much each side actually changed the
file since the fork point (`git diff -U0 <forkpoint> <side> -- <path>`,
counting changed lines):

| Code | Rule | Meaning | Count |
|---|---|---|---|
| **U** | our side <= 10 changed lines | **Upstream wins.** Take upstream's file whole, re-apply our few lines, verify by grep. | **52** |
| **O** | upstream side <= 10 changed lines, ours larger | **Ours wins.** Keep our file, hand-port upstream's small delta. | **12** |
| **T** | everything else | **True three-way.** Both sides did real work; read both diffs. | **67** |

The 52 U-files are the load-bearing discovery. Sampling them shows our whole
delta in that class is one of three mechanical overlays:

- **branding** - `com.mitchellh.ghostty` -> `com.dzearing.ghoztty`,
  `Bundle.main.bundleIdentifier!` -> `Bundle.loggerSubsystem`;
- **the apprt enum arm** - `.none => void` -> `.none, .win32 => void` and its
  siblings, added wherever the core switches on the app runtime;
- **a path or name string** carrying the fork's identity.

None of those is a semantic conflict. They are a *patch overlay* that can be
re-applied after taking upstream wholesale, which is why Stage 0 below turns
the overlay into a script instead of 52 manual resolutions. Measured against
the real fork delta once the script existed, 28 of the 52 are resolved by it
outright and the other 24 shrink to the non-identity work they also carry -
Stage 0 item 2 has the breakdown.

## Group summary

| Group | Domain | Files | T | U | O | Our lines | Up lines | Seat |
|---|---|---|---|---|---|---|---|---|
| G1 | Repo meta, community, packaging | 15 | 0 | 13 | 2 | 221 | 848 | win |
| G2 | Build system | 10 | 5 | 4 | 1 | 605 | 744 | win |
| G3 | macOS app | 35 | 16 | 16 | 3 | 4030 | 2293 | **mac** |
| G4 | libghostty C API + embedded runtime | 4 | 4 | 0 | 0 | 2720 | 262 | both |
| G5 | CLI surface | 20 | 13 | 1 | 6 | 1322 | 1748 | win |
| G6 | apprt + IPC | 8 | 4 | 4 | 0 | 714 | 2195 | win |
| G7 | Config + input | 4 | 4 | 0 | 0 | 989 | 1116 | win |
| G8 | Terminal core, renderer, datastruct | 17 | 10 | 7 | 0 | 1078 | 18810 | win |
| G9 | Process, PTY, OS, shell-integration | 17 | 10 | 7 | 0 | 1662 | 3086 | win |
| G10 | `src/Surface.zig` | 1 | 1 | 0 | 0 | 1087 | 1503 | win |

Per-group merge direction and gate:

- **G1** - upstream wins on everything except `.gitignore` and our `CLAUDE.md`.
  `.gitignore` is a **union merge** (both sides only added lines); `CLAUDE.md`
  is entirely ours and upstream's same-named file is a different document -
  keep ours, and if upstream's is wanted at all it lands as a separate path.
  The `.github/vouch-*` workflows are upstream's contributor process, not ours:
  take theirs unconditionally. **Gate:** the tree still builds; no runtime risk.
- **G2** - true three-way. Our `build.zig` carries `-Dapp-runtime=win32`, the
  agent build, and the `GlobalCacheOnDifferentDrive` guard (T243); upstream's
  `src/build/SharedDeps.zig` and `Config.zig` moved substantially. Ours wins on
  every win32/agent hunk, upstream wins on dependency and target plumbing.
  **Gate:** `floor-lane.ps1 -Lane all` - all four lanes, including the `lib`
  compile that is the only thing on this box that builds the shared core for a
  Windows target.
- **G3** - **the Mac seat's stage.** 16 of the 35 are U (branding), but the
  three-way half includes `BaseTerminalController.swift` (2031 of our lines vs
  389 of theirs) and the xcodeproj. Nothing here can be validated on this box.
  **Gate:** a Mac build plus the macOS test suite, run by the Mac seat.
- **G4** - all four are three-way and all four are ours-dominant
  (`src/apprt/embedded.zig` 2097 vs 144; `include/ghostty.h` 581 vs 40). Our
  additions are new C API surface; upstream's are mostly signature churn from
  the Zig bump. Ours wins on our symbols, upstream wins on theirs.
  **Gate:** the `lib` lane, because a C API edit made from this seat is
  otherwise discovered by the Mac seat at its next build (T323/T475).
- **G5** - our new verbs (`new_window.zig` +129, `version.zig` +155,
  `args.zig` +399) against upstream's rewrite of the ssh-cache pair
  (+543/+568). Disjoint subjects: take upstream's ssh-cache whole, keep our
  verb files, three-way only `src/cli/args.zig` and `src/cli/ghostty.zig`
  where both sides edited the dispatch table.
  **Gate:** `ipc-p1/p2/p3` plus `test\win32\cli-unknown-flag.ps1`.
- **G6** - the four GTK files are U (2-8 lines each, all branding or the
  `.win32` arm) despite upstream's large rewrite: take theirs. The two that
  matter are `src/apprt/action.zig` (117 vs 104 - both sides added actions,
  read both) and `src/apprt/ipc.zig` (517 vs 104 - ours is the whole IPC
  client, upstream's is small; ours wins with their delta ported).
  **Gate:** `ipc-p1/p2/p3`.
- **G7** - `src/config/Config.zig` is the second-hottest file in the repo (740
  vs 619). Both sides added config keys; the merge is mostly additive but the
  ordering and the docs comments will conflict textually on nearly every hunk.
  **Gate:** `zig build test` on both runtimes plus a `+show-config` diff before
  and after.
- **G8** - **the cheapest large win.** 18810 upstream lines against 1078 of
  ours, and 7 of the 17 are U. `PageList.zig` (+8789 upstream, 63 ours),
  `stream.zig` (+1579 / 22), `terminal/c/terminal.zig` (+3977 / 2) and
  `stream_terminal.zig` (+1914 / 8) are upstream-wins outright. The real
  three-way is confined to `page.zig`, `datastruct/split_tree.zig` and
  `renderer/State.zig`, where our splits and viewer work live.
  **Gate:** `zig build test` (`none` lane carries the terminal unit tests).
- **G9** - where the Windows work actually collides. `src/termio/Exec.zig`
  (309 / 745) and `src/Command.zig` (479 / 307) hold our ConPTY and job-object
  changes against upstream's process rework; `src/os/env.zig` is the deletion
  described above. The five shell-integration scripts are all U (branding).
  **Gate:** `zig build test-agent` plus `ipc-p1/p2/p3`; a ConPTY regression
  shows up nowhere else.
- **G10** - `src/Surface.zig` alone: 1087 of our lines against upstream
  +472/-1031. It is its own stage because it is the one file where a bad
  resolution silently changes behavior in every pane.
  **Gate:** both test lanes plus a manual pass through the P1-P3 scripts.

The full per-file assignment is in [Appendix A](#appendix-a-the-131-file-risk-set).

## Merge shape: staged by upstream range, not by path

A merge takes whole commits, so "merge G8 first" is not a thing git can do. The
plan therefore stages by **upstream commit range**, and the group tables above
say what each range will hit. Boundaries were chosen so the Zig bump sits
alone, and otherwise fall on month ends.

| Stage | Upstream range | Commits | Files | Risk-set files hit | T | U | O | Heaviest groups |
|---|---|---|---|---|---|---|---|---|
| S1 | `063ac3ecc..c4c9e945a` (fork point -> 2026-05-31) | 127 | 115 | 40 | 19 | 20 | 1 | G3(9) G1(9) G6(5) |
| S2 | `c4c9e945a..c6b0c0dcb` (2026-06) | 80 | 105 | 32 | 14 | 17 | 1 | G3(14) G1(5) G6(4) |
| S3 | `c6b0c0dcb..74d0c72fd` (2026-07-01 -> last pre-Zig-0.16) | 164 | 132 | 26 | 13 | 13 | 0 | G8(10) G1(6) G9(4) |
| **S4** | `74d0c72fd..e8525c0fd` (**the Zig 0.16.0 bump, 1 commit**) | 1 | 357 | **71** | 45 | 18 | 8 | G5(20) G8(13) G9(12) |
| S5 | `e8525c0fd..ec5b36961` (post-Zig -> 2026-07-31) | 121 | 228 | 40 | 24 | 15 | 1 | G8(7) G1(7) G9(6) |
| S6 | `ec5b36961..ad6e72ddc` (2026-08 -> upstream head) | 271 | 322 | 78 | 52 | 24 | 2 | G3(26) G8(12) G5(9) |

Regenerate with the boundary shas above and
`git diff --name-only <from> <to>` intersected against the risk set.

Read that table as: S1-S3 are ordinary merges of ordinary size. **S4 is the
project.** S5-S6 are ordinary again but only once S4 has landed.

### Stage 0 - preparation (no merge)

The first mergeable stage is S1, but S1 should not be attempted until three
things exist, because each of them is needed by every later stage:

1. **A permanent `upstream` remote.** ✅ **Done (T957.)** `ad6e72ddc` used to be
   in the object store for one reason only - `divergence-inventory.ps1` had
   fetched it, into no ref - so a `git gc` was free to drop every sha this doc
   pins while the doc went on reading correctly. `upstream` now points at
   `https://github.com/ghostty-org/ghostty.git`, and all seven shas cited here
   (the six stage points plus the fork point) are ancestors of `upstream/main`,
   so the ref keeps them alive.

   A remote is LOCAL config, though - it cannot arrive by `git pull`, and the
   Mac seat's clone has never had one - so the durable form is
   `scripts\upstream-remote.ps1`, re-asserted every turn from
   `go-loop-exec.ps1 claim` (the same argument as `core.hooksPath`, T948). It
   adds the remote, corrects a drifted URL, and fetches at most once a day;
   a fetch failure is a warning, never fatal, because an offline box must not
   wedge the loop. `check` is the gate: it exits 1 unless every sha cited in
   THIS FILE resolves and is reachable from `upstream/main`, so a re-cut stage
   is covered the day it is written here.
2. **The branding overlay as a script.** ✅ **Done (T956.)**
   `scripts\fork-identity.ps1` re-applies the fork identity across a tree
   (`apply`), reports anywhere an upstream form survives (`check`, exit 1), and
   prints its own rule table (`rules`) so this doc and the code cannot drift.
   A U-file merge is now "take theirs, run `apply`, run `check`".

   **What it actually resolves, measured rather than claimed.** The 52 U-files
   were checked out at the fork point, overlaid, and compared against HEAD:
   **28 of the 52 come back byte-identical**, and across all 52 the overlay
   removes **104 of the 210 changed lines**. The remaining 24 files are not
   identity at all and no rule should invent them:

   - **6 CI workflows** - the `github.repository == 'ghostty-org/ghostty'`
     guards are applied SELECTIVELY (28 guards over 47 jobs in `test.yml`
     alone), so a rule that added them everywhere would be wrong rather than
     merely coarse.
   - **8 macOS files** - the `Ghostty.SurfaceView` -> `PaneView` type rename
     and real feature deltas (the window title override in the restorable
     state, release notes on the update sheet).
   - **10 files carrying genuine work in a small diff** - a raised comptime
     branch quota, the `win32_input` mode, two OSC parsers, the IPC fields on
     `Global`, `SetConsoleCP` on `src/os/windows.zig` - plus `build.zig.zon`,
     whose `.version` is ours by policy and would go stale as a constant.

   So the honest form of the earlier claim is: the overlay makes **28 of the
   131 resolutions free and shrinks 24 more to their real content**, at every
   stage, rather than once.

   The rules are narrow and each one is derived from a measured fork delta;
   a blanket `ghostty` -> `ghoztty` rename would be wrong and is never done.
   `xterm-ghostty` is the TERM value, `GHOSTTY_*` is a published contract with
   shells, `ghostty-org/ghostty` is upstream's repository, `src/apprt/gtk` and
   `macos/Sources/Ghostty` are directory and module names, and `po/*.po`
   headers are gettext metadata. `test\win32\fork-identity.ps1` section E is a
   fixture of exactly those strings, asserted to come back byte-identical -
   because a blanket rename would pass every other assertion in the harness.

   The apprt arm is structural, not textual: `.none => void,` appears 29 times
   at the fork point and only 11 of them are app-runtime switches, so the
   script finds the brace-balanced `switch (... app_runtime)` block first and
   widens only "not applicable" arms in blocks that do not already cover
   `.win32`. A switch that maps members to modules (`src/apprt.zig`) or that
   has its own `.win32` arm (`src/build/SharedDeps.zig`) is reported, never
   rewritten.
3. **`.gitattributes` merge drivers** ✅ **Done (T957.)** `.gitignore` is under
   git's built-in `merge=union`, measured on the real divergence: ours grew 28
   lines and upstream's grew 4 in the same two regions, which conflicts without
   the driver and merges clean with it, losing no entry from either side. Two
   shared append-only ledgers joined it for a different reason - both seats
   append to `windows-parity-log.md` and `windows-parity-feature-ideas.md` on
   the same branch, so their conflict is a `git pull --rebase` away on any turn,
   not a merge stage away.

   The list stays short on purpose: union NEVER conflicts, so it is only
   correct where taking both sides always is. A `.zig`, `.zon` or `.json` under
   a union driver would merge into something that does not parse - worse than
   the conflict it avoided - which is why `test\win32\upstream-remote.ps1`
   section D asserts that no structured-syntax file is ever listed, and asks
   `git check-attr` (not a re-implementation of its pattern matching) whether
   each declared path really resolves to `union`.

Stage 0 is pure infrastructure and lands on this branch with no upstream code,
so it is safe to do at any time - including before the decision to merge is
final. **All three items are now done** (T957, T956), so S1 is unblocked on
preparation grounds; what it still waits on is the go/no-go in D80.

### Stage sequence and the gate after each

Every stage lands on a scratch branch, is gated, and only then fast-forwards:

```
powershell -NoProfile -File scripts\fork-identity.ps1 check
powershell -NoProfile -File scripts\floor-lane.ps1 -Lane all
powershell -NoProfile -File test\win32\ipc-p1.ps1   # then ipc-p2.ps1, ipc-p3.ps1
powershell -NoProfile -File scripts\guard-due.ps1 check
```

`fork-identity check` runs FIRST because it is the cheapest and because a merge
stage is exactly when upstream identity re-enters the tree: every U-file
resolved as "take theirs" arrives carrying it. Run `apply` on the conflicted
paths, then `check` until it exits 0.

`guard-due check` is the part that is easy to skip and should not be: a merge
changes code under many acceptance harnesses at once, and after a merge stage
its report is the only thing that says which harnesses now owe a run.

| Stage | Do this | Extra gate beyond the floor |
|---|---|---|
| **0** | remote, overlay script, merge drivers | overlay verifier finds zero upstream identity strings |
| **S1** | merge `c4c9e945a` | none - mostly G1/G3 |
| **S2** | merge `c6b0c0dcb` | none |
| **S3** | merge `74d0c72fd` | `zig build test` both lanes (G8 is heaviest here) |
| **S4** | **upgrade the toolchain to Zig 0.16.0, then merge `e8525c0fd`** | full floor + P1-P3 + `test-agent`; a full delivery to the portable locations before the user's next morning refresh |
| **S5** | merge `ec5b36961` | `zig build test-agent` (G9 heavy) |
| **S6** | merge `ad6e72ddc` | full floor + P1-P3; Mac seat validates G3 |

**S4 is not one task.** It is at minimum: the toolchain bump on our side, the
`src/os/env.zig` replacement (13 call sites, 2 of them win32), the
`src/apprt/win32/` port to 0.16 APIs (2000+ files of ours never seen by
upstream's bump), and the agent. It should be split into sub-tasks the moment
it is picked up, per the context rule.

## The 616 upstream-only files

They cannot conflict, which is exactly why they are the easiest thing to get
wrong: they arrive silently and change behavior anyway.

- **390 are under `src/`**, and **101 of those are files upstream ADDED**.
  New modules that our build does not reference are inert; new modules that
  upstream's own edits now reference are load-bearing, and they arrive in the
  same stage as those edits.
- The other 226 upstream-only `src/` files are modifications to files we never
  touched - the largest single source of behavior change in the whole merge,
  and none of it shows up in any conflict.
- The remaining 226 files outside `src/` (`pkg/` 51, `macos/` 49, `example/`
  43, `po/` 33, `include/` 21, `.github/` 9, `nix/` 5) are dependency pins,
  translations, and examples. `pkg/` matters (it is the vendored dependency
  set and moves with the Zig bump); `example/` and `po/` do not.

**The rule:** the floor gate after each stage is what covers them. A stage is
not done because it merged cleanly - it is done because `floor-lane -Lane all`
and P1-P3 are green *after* the 616's share of that stage arrived. That is the
whole reason the stages are gated individually rather than merging once and
testing at the end.

## Open parity tasks superseded by upstream

**None found.** The structural reason is stronger than the search:

- `git ls-tree -d --name-only ad6e72ddc src/apprt/` returns **only
  `src/apprt/gtk`**. Upstream has no `src/apprt/win32` and no `src/apprt/ipc`
  - both are ours alone. No upstream change can supersede a task about the
  win32 frontend, the IPC server, the viewer panes, the tab strip, or the
  chooser, which is what the great majority of the open backlog is.
- A keyword sweep of the 353 open `todo` tasks for shared-core subjects
  (ssh, OSC, terminfo, shell-integration, selection, PageList, scrollback,
  font, unicode, clipboard, paste, keybind, config) returned 15 tasks, and
  every one of the 11 `seat: win` ones is win32-frontend, viewer, or agent
  work (T575 F10 keybind, T595 diff.css fonts, T621 and T911 agent scrollback,
  T750 viewer MIME table, T765 config reload repaint, T790 win32 filter-box
  folding, T864 unrecognized shell, T893 external config reload, T936 composer
  chips, T947 clipboard contention). The other four (T340, T558, T700, T821)
  are `seat: mac` and belong to the G3 stage anyway.

The inverse is where the risk actually is, and it is not "superseded" but
"invalidated": **T-tasks that touch G9 or G4 will need rework after S4**,
because the Zig 0.16 API churn lands underneath them. That is an argument for
sequencing S4 before more work accumulates in those groups, not for holding
tasks.

## Follow-up tasks filed from this plan

| Task | What it is | Stage |
|---|---|---|
| **T956** | Fork-identity overlay script + verifier - mechanizes 52 of the 131 resolutions | Stage 0 |
| **T957** | Permanent `upstream` remote, and `.gitattributes` union-merge drivers | Stage 0 |
| **T958** | Move the fork to Zig 0.16.0 - **must be split when picked up** | S4 |
| **T959** | `src/os/env.zig` has no upstream home after 0.16; 13 callers | S4 |
| **T960** | Re-run the divergence inventory monthly so this plan stays honest | ongoing |

T956 and T957 land no upstream code and are safe before the decision below is
answered. T958/T959 are gated on it.

## What this plan does not decide

Whether to merge at all, and when. The staging above makes the cost legible -
S1-S3 and S5-S6 are five ordinary merges; S4 is a toolchain migration of the
entire fork - but the call about spending that on a fork whose value is a
Windows frontend upstream does not have belongs to the user. Filed as **D80**
(`docs/design/windows-parity-decisions/D80.md`), which is the go/no-go this
plan waits on.

## Appendix A: the 131-file risk set

`Ours/Up` is the git status letter on each side (M modified, A added,
D deleted). `Our lines` / `Up lines` are changed lines since the fork point.
Strategy is U (upstream wins) / O (ours wins) / T (three-way), per the rule
above.

<!-- BEGIN GENERATED: per-group risk-set tables -->

### G1 - Repo meta, community, packaging (15 files)

| File | Ours/Up | Our lines | Up lines | Strategy |
|---|---|---|---|---|
| `.gitignore` | MM | 30 | 5 | O |
| `CLAUDE.md` | AA | 134 | 1 | O |
| `.github/workflows/test.yml` | MM | 8 | 611 | U |
| `nix/tests.nix` | MM | 10 | 109 | U |
| `po/README_TRANSLATORS.md` | MM | 6 | 44 | U |
| `po/README_CONTRIBUTORS.md` | MM | 4 | 24 | U |
| `HACKING.md` | MM | 4 | 16 | U |
| `.github/workflows/vouch-check-issue.yml` | MM | 2 | 7 | U |
| `.github/workflows/vouch-manage-by-discussion.yml` | MM | 2 | 6 | U |
| `.github/workflows/vouch-manage-by-issue.yml` | MM | 2 | 6 | U |
| `.github/workflows/vouch-sync-codeowners.yml` | MM | 4 | 6 | U |
| `snap/snapcraft.yaml` | MM | 4 | 5 | U |
| `.github/workflows/vouch-check-pr.yml` | MM | 7 | 4 | U |
| `.github/DISCUSSION_TEMPLATE/issue-triage.yml` | MM | 2 | 2 | U |
| `CODEOWNERS` | MM | 2 | 2 | U |

### G2 - Build system (10 files)

| File | Ours/Up | Our lines | Up lines | Strategy |
|---|---|---|---|---|
| `src/build/GhosttyXcodebuild.zig` | MM | 100 | 10 | O |
| `src/build/SharedDeps.zig` | MM | 35 | 293 | T |
| `src/build/Config.zig` | MM | 101 | 244 | T |
| `build.zig` | MM | 232 | 62 | T |
| `src/build/GhosttyResources.zig` | MM | 66 | 30 | T |
| `src/build/GhosttyExe.zig` | MM | 58 | 17 | T |
| `build.zig.zon` | MM | 2 | 55 | U |
| `src/build/GhosttyI18n.zig` | MM | 2 | 21 | U |
| `src/helpgen.zig` | MM | 5 | 8 | U |
| `src/build/webgen/main_commands.zig` | MM | 4 | 4 | U |

### G3 - macOS app, `seat: mac` (35 files)

| File | Ours/Up | Our lines | Up lines | Strategy |
|---|---|---|---|---|
| `macos/Sources/Features/About/AboutView.swift` | MM | 47 | 4 | O |
| `macos/Sources/Ghostty/Ghostty.Action.swift` | MM | 37 | 3 | O |
| `macos/Sources/Features/Terminal/TerminalRestorable.swift` | MM | 18 | 2 | O |
| `macos/Sources/Features/Terminal/BaseTerminalController.swift` | MM | 2031 | 389 | T |
| `macos/Ghostty.xcodeproj/project.pbxproj` | MM | 184 | 337 | T |
| `macos/Sources/Ghostty/Ghostty.App.swift` | MM | 212 | 256 | T |
| `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` | MM | 399 | 240 | T |
| `macos/Sources/Ghostty/Surface View/SurfaceView.swift` | MM | 225 | 130 | T |
| `macos/Sources/Features/Command Palette/CommandPalette.swift` | MM | 99 | 119 | T |
| `macos/Sources/Features/Update/UpdateViewModel.swift` | MM | 19 | 78 | T |
| `macos/Sources/Features/Terminal/TerminalController.swift` | MM | 275 | 63 | T |
| `macos/Sources/Ghostty/GhosttyPackage.swift` | MM | 81 | 62 | T |
| `macos/Sources/Ghostty/Surface View/OSSurfaceView.swift` | MM | 14 | 62 | T |
| `macos/Sources/Ghostty/Ghostty.Config.swift` | MM | 18 | 56 | T |
| `macos/Sources/Features/Command Palette/TerminalCommandPalette.swift` | MM | 114 | 52 | T |
| `macos/Sources/Features/Update/UpdatePopoverView.swift` | MM | 46 | 46 | T |
| `macos/Sources/Helpers/Extensions/OSColor+Extension.swift` | MM | 43 | 33 | T |
| `macos/Sources/Features/Update/UpdateSimulator.swift` | MM | 20 | 19 | T |
| `macos/Sources/Ghostty/Ghostty.Surface.swift` | MM | 86 | 11 | T |
| `macos/Sources/Features/Global Keybinds/GlobalEventTap.swift` | MM | 2 | 69 | U |
| `macos/Sources/Features/App Intents/Entities/TerminalEntity.swift` | MM | 2 | 67 | U |
| `macos/Sources/App/iOS/iOSApp.swift` | MD | 2 | 50 | U |
| `macos/Sources/Features/QuickTerminal/QuickTerminalController.swift` | MM | 9 | 20 | U |
| `macos/Sources/Helpers/Extensions/NSPasteboard+Extension.swift` | MM | 2 | 18 | U |
| `macos/Sources/Features/App Intents/QuickTerminalIntent.swift` | MM | 2 | 14 | U |
| `macos/Sources/Features/Terminal/TerminalRestorableState+InteralState.swift` | MM | 9 | 14 | U |
| `macos/Sources/Features/Terminal/Window Styles/TitlebarTabsTahoeTerminalWindow.swift` | MM | 2 | 14 | U |
| `macos/Sources/Ghostty/Surface View/SurfaceView+Transferable.swift` | MM | 2 | 11 | U |
| `macos/Sources/Features/QuickTerminal/QuickTerminalRestorableState.swift` | MM | 6 | 10 | U |
| `macos/Sources/Features/Update/UpdateDelegate.swift` | MM | 4 | 10 | U |
| `macos/Sources/Features/Update/UpdateDriver.swift` | MM | 6 | 10 | U |
| `macos/Sources/Features/Secure Input/SecureInput.swift` | MM | 2 | 8 | U |
| `macos/Sources/Features/App Intents/NewTerminalIntent.swift` | MM | 8 | 6 | U |
| `macos/Sources/Features/AppleScript/ScriptTerminal.swift` | MM | 2 | 6 | U |
| `macos/Sources/Features/Terminal/Window Styles/TitlebarTabsVenturaTerminalWindow.swift` | MM | 2 | 4 | U |

### G4 - libghostty C API + embedded runtime (4 files)

| File | Ours/Up | Our lines | Up lines | Strategy |
|---|---|---|---|---|
| `src/apprt/embedded.zig` | MM | 2097 | 144 | T |
| `src/main_c.zig` | MM | 27 | 52 | T |
| `include/ghostty.h` | MM | 581 | 40 | T |
| `src/config/CApi.zig` | MM | 15 | 26 | T |

### G5 - CLI surface (20 files)

| File | Ours/Up | Our lines | Up lines | Strategy |
|---|---|---|---|---|
| `src/cli/explain_config.zig` | MM | 16 | 9 | O |
| `src/cli/boo.zig` | MM | 11 | 8 | O |
| `src/cli/list_actions.zig` | MM | 11 | 7 | O |
| `src/cli/show_face.zig` | MM | 21 | 7 | O |
| `src/cli/help.zig` | MM | 45 | 5 | O |
| `src/cli/show_config.zig` | MM | 18 | 5 | O |
| `src/cli/ssh-cache/DiskCache.zig` | MM | 72 | 568 | T |
| `src/cli/ssh_cache.zig` | MM | 23 | 543 | T |
| `src/cli/edit_config.zig` | MM | 18 | 132 | T |
| `src/main_ghostty.zig` | MM | 200 | 95 | T |
| `src/cli/list_themes.zig` | MM | 13 | 86 | T |
| `src/cli/args.zig` | MM | 401 | 79 | T |
| `src/cli/new_window.zig` | MM | 142 | 68 | T |
| `src/cli/ghostty.zig` | MM | 125 | 42 | T |
| `src/cli/crash_report.zig` | MM | 11 | 25 | T |
| `src/cli/list_colors.zig` | MM | 13 | 19 | T |
| `src/cli/list_keybinds.zig` | MM | 11 | 18 | T |
| `src/cli/version.zig` | MM | 156 | 12 | T |
| `src/cli/validate_config.zig` | MM | 11 | 11 | T |
| `src/cli/list_fonts.zig` | MM | 4 | 9 | U |

### G6 - apprt + IPC (8 files)

| File | Ours/Up | Our lines | Up lines | Strategy |
|---|---|---|---|---|
| `src/apprt/gtk/class/application.zig` | MM | 37 | 771 | T |
| `src/apprt/gtk/class/split_tree.zig` | MM | 29 | 388 | T |
| `src/apprt/action.zig` | MM | 117 | 104 | T |
| `src/apprt/ipc.zig` | MM | 517 | 104 | T |
| `src/apprt/gtk/class/surface.zig` | MM | 2 | 537 | U |
| `src/apprt/gtk/class/window.zig` | MM | 2 | 276 | U |
| `src/apprt/gtk/winproto/x11.zig` | MM | 2 | 13 | U |
| `src/apprt/gtk/Surface.zig` | MM | 8 | 2 | U |

### G7 - Config + input (4 files)

| File | Ours/Up | Our lines | Up lines | Strategy |
|---|---|---|---|---|
| `src/config/Config.zig` | MM | 740 | 619 | T |
| `src/input/command.zig` | MM | 55 | 387 | T |
| `src/input/Binding.zig` | MM | 35 | 94 | T |
| `src/config/url.zig` | MM | 159 | 16 | T |

### G8 - Terminal core, renderer, datastruct (17 files)

| File | Ours/Up | Our lines | Up lines | Strategy |
|---|---|---|---|---|
| `src/terminal/PageList.zig` | MM | 63 | 8789 | T |
| `src/terminal/stream.zig` | MM | 22 | 1579 | T |
| `src/terminal/page.zig` | MM | 286 | 620 | T |
| `src/renderer/generic.zig` | MM | 84 | 257 | T |
| `src/datastruct/split_tree.zig` | MM | 286 | 192 | T |
| `src/renderer/Thread.zig` | MM | 38 | 167 | T |
| `src/renderer/cell.zig` | MM | 12 | 156 | T |
| `src/terminal/osc.zig` | MM | 41 | 128 | T |
| `src/datastruct/blocking_queue.zig` | MM | 66 | 83 | T |
| `src/renderer/State.zig` | MM | 161 | 76 | T |
| `src/terminal/c/terminal.zig` | MM | 2 | 3977 | U |
| `src/terminal/stream_terminal.zig` | MM | 8 | 1914 | U |
| `src/font/face.zig` | MM | 2 | 596 | U |
| `src/terminal/modes.zig` | MM | 1 | 183 | U |
| `src/inspector/widgets/termio.zig` | MM | 2 | 89 | U |
| `src/terminal/mouse.zig` | MM | 2 | 3 | U |
| `src/terminal/osc/parsers.zig` | MM | 2 | 1 | U |

### G9 - Process, PTY, OS, shell-integration (17 files)

| File | Ours/Up | Our lines | Up lines | Strategy |
|---|---|---|---|---|
| `src/termio/Exec.zig` | MM | 309 | 745 | T |
| `src/Command.zig` | MM | 479 | 307 | T |
| `src/termio/stream_handler.zig` | MM | 101 | 230 | T |
| `src/os/env.zig` | MD | 42 | 178 | T |
| `src/termio/Termio.zig` | MM | 217 | 145 | T |
| `src/termio/shell_integration.zig` | MM | 250 | 106 | T |
| `src/pty.zig` | MM | 23 | 79 | T |
| `src/os/main.zig` | MM | 16 | 19 | T |
| `src/termio/Thread.zig` | MM | 153 | 16 | T |
| `src/termio/mailbox.zig` | MM | 31 | 15 | T |
| `src/global.zig` | MM | 7 | 513 | U |
| `src/os/windows.zig` | MM | 8 | 344 | U |
| `src/shell-integration/elvish/lib/ghostty-integration.elv` | MM | 4 | 82 | U |
| `src/shell-integration/nushell/vendor/autoload/ghostty.nu` | MM | 2 | 82 | U |
| `src/shell-integration/fish/vendor_conf.d/ghostty-shell-integration.fish` | MM | 8 | 81 | U |
| `src/shell-integration/zsh/ghostty-integration` | MM | 6 | 73 | U |
| `src/shell-integration/bash/ghostty.bash` | MM | 6 | 71 | U |

### G10 - `src/Surface.zig` (1 file)

| File | Ours/Up | Our lines | Up lines | Strategy |
|---|---|---|---|---|
| `src/Surface.zig` | MM | 1087 | 1503 | T |

