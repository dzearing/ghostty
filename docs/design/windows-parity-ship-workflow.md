# The ship workflow: cutting over from one long branch to per-feature PRs

**Task:** T1058. **User directive, 2026-08-21:** *"when we feel like we're in a
stable state and feature complete, we would get this all merged back into main
and continue work from there or build individual worktrees for new features and
make prs."*

This doc is the whole transition in one place: what has to be true before the
cutover, how the cutover is done, and what a turn looks like afterwards. It is
referenced from `go.md`, which is the file every turn actually reads.

## Which merge this is

Two different merges get called "merge back". They are independent and this doc
covers only the first.

| | What it is | Where it is planned |
|---|---|---|
| **Branch → fork main** | `users/dzearing/windows-amd64` into `origin/main` (dzearing/ghoztty) | **this doc** |
| **Upstream → fork** | `ghostty-org/ghostty` `main` into this repo | `windows-parity-merge-back-plan.md` |

`origin/main` is not a dead trunk. The Mac seat has been merging feature
branches into it all along — `users/dzearing/pane-resize-fixed-edges`,
`users/dzearing/session-restore`, `users/dzearing/url-protocol` — with releases
cut off it up to v1.34.0. **So the post-cutover shape is not invented here; it
is the shape `main` already has.** What the Windows seat is doing is joining it.

## Today, and the two things wrong with it

Every turn commits straight onto `users/dzearing/windows-amd64`. As of
2026-08-21 that is 1397 commits ahead of `origin/main` and 93 behind.

1. **There is no review point.** Work is finished when a turn says it is
   finished. The only reader is the turn that wrote it, which is the weakest
   check the project has (T1060 exists for exactly this).
2. **Nothing ships independently.** A feature cannot reach `main` without
   bringing every other in-flight change with it, so the whole branch is either
   good or not good, and it has been "not yet" for months.

## Entry criteria — checked, not felt

"When we feel like we're in a stable state" is the part that has to become a
command, because the cutover happens once and a mood is not a gate:

```powershell
powershell -NoProfile -File scripts\ship-readiness.ps1
powershell -NoProfile -File scripts\ship-readiness.ps1 -RunLanes   # the real one
```

Exit 0 = READY, 1 = NOT READY (with every unmet criterion and its remedy named),
2 = the check could not run. `-Json` for the machine-readable form.

| Criterion | Satisfied when | Why it gates |
|---|---|---|
| `tree` | nothing uncommitted | a cutover carrying a dirty tree merges work nobody can name |
| `push` | HEAD == its upstream | a merge computed from unpushed commits is not the merge that happens |
| `behind` | `origin/main` fully contained in HEAD | main is live; unmerged main commits make this a three-way merge, not a cutover |
| `p0` | no open P0 (either seat) | a P0 is a crash, hang, data loss or a broken feature — "stable" cannot be true over one |
| `inprogress` | no other task in-progress | half-finished work in the trunk is what the PR boundary exists to prevent |
| `guards` | `guard-due.ps1 check` clean | a due harness means "green" is a memory, not a measurement |
| `macseat` | T87 done or explicitly sequenced | this box cannot build macOS; the Mac half is unowned until a human takes it |
| `lanes` | the four floor lanes green **this run** | measured only under `-RunLanes`; otherwise UNKNOWN, which counts as unmet |
| `accept` | P1–P3 green **this run** | same rule |
| `ghrepo` | `gh` resolves to `dzearing/ghoztty` | see the landmine below |

**UNKNOWN counts as unmet, deliberately.** A lane that was green yesterday says
nothing about today's tree, and the one failure mode this gate cannot afford is
reading "we did not look" as "ready".

### The `gh` landmine

This repo has two remotes — `origin` (dzearing/ghoztty) and `upstream`
(ghostty-org/ghostty) — and until T1058 no `gh repo set-default`. `gh` picks a
repository by walking the remotes, and a bare `gh pr list` here answered with
**upstream's** open pull requests. Under a PR workflow that means a bare
`gh pr create` would have offered this fork's Windows work as a pull request to
the public Ghostty project: outward-facing, and not retractable.

Two defences, both required, because the first one is local config that no
`git clone` and no `git pull` carries:

- `gh repo set-default dzearing/ghoztty` (done on this box; `ghrepo` re-checks it
  every readiness run).
- **Every repository-scoped `gh` call in this family passes `--repo` explicitly.**
  Section C of `test\win32\ship-workflow.ps1` scans for a bare one and fails.

## The cutover

Run only when `ship-readiness.ps1 -RunLanes` exits 0.

1. **Close the `behind` gap first.** Merge `origin/main` **into** the branch, on
   the branch, where the floor lanes can judge the result. Resolving 93 commits'
   worth of conflicts inside the merge *to* main would put the resolution
   straight onto the trunk with nothing to test it against.
2. **Re-run the floor lanes and P1–P3** after that merge. It is a real merge;
   green before it is not evidence about after it.
3. **The Mac seat runs T87** — the macOS regression build — against the merged
   branch. The Windows seat cannot do this and must not assume it.
4. **Merge branch → `main`** as a merge commit (never a squash: 1397 commits of
   history and the tracker's `commits:` fields both reference these shas).
5. **Verify on the trunk**: floor lanes and P1–P3 green from `main`, and a
   `+list` smoke on both platforms.
6. **Retire the old path** — `go.md` step 6 stops committing to the long branch
   and starts the per-feature flow below. Until this step happens, the old path
   is still the path.

## After the cutover: one feature, one worktree, one PR

`scripts\ship-feature.ps1` is the lifecycle. Each command has its checks built
in, so the workflow does not depend on a turn reading this section carefully.

```powershell
# start: a worktree at D:\git\ghoztty-wt\<slug> on users/dzearing/<slug>, forked
# from a freshly fetched origin/main
powershell -NoProfile -File scripts\ship-feature.ps1 new -Slug banner-fade

# what is in flight, and where each one stands (branch, commits, dirty, unpushed, PR)
powershell -NoProfile -File scripts\ship-feature.ps1 list

# push and open the PR against the FORK, explicitly
powershell -NoProfile -File scripts\ship-feature.ps1 pr -Slug banner-fade `
    -Title "the banner fades out when it collapses" -Body "..."

# after it merges: remove the worktree and delete the branch
powershell -NoProfile -File scripts\ship-feature.ps1 done -Slug banner-fade
```

**What each command refuses, and why:**

- `new` — a slug that already exists (silently landing in someone else's
  worktree is how two features end up in one branch) and a slug that is not
  kebab-case (it becomes both a directory name and a git ref). It fetches first,
  so the fork point is today's main.
- `pr` — a dirty tree (a PR must describe committed work) and a branch with no
  commits of its own (a PR over nothing is a notification people learn to
  ignore). Re-running it on a branch that already has an open PR pushes and says
  so rather than opening a second one.
- `done` — a dirty tree, unpushed commits, or a PR that is still open. `-Force`
  is the abandon path and prints that it was used.

**Why a worktree rather than `git checkout`.** This box runs a long-lived
Ghoztty out of `zig-out`, a dashboard server, an agent, and a go-loop whose lock
is keyed on a pane in this directory. A branch switch swaps the source out from
under all of it. A worktree gives the feature its own directory and leaves the
loop's tree alone — and an unfinished feature is then a directory somebody can
see rather than a stash somebody must remember.

**Relationship to the `/wt` skill.** `/wt` is the *interactive* path: it opens a
Ghoztty window, installs dependencies and starts a Claude session for a human.
`ship-feature.ps1` is the loop's non-interactive path and launches nothing. Both
can be used on the same worktree.

## The post-cutover turn

The turn shape in `go.md` changes in exactly three places:

- **Step 1 (pick a task)** gains a branch decision. `ship-feature.ps1 list`
  first: a worktree whose PR is open and not merged is **inherited work** and
  outranks a fresh task, the same way a `RESUME:` outranks a `NEXT:`. Otherwise
  `new -Slug <slug-from-the-task>`, and the turn works in that worktree.
- **Step 6 (update the tracker)** commits in the worktree, through the same
  `git-commit-guard.ps1` (the guard takes a repo-wide lock, and worktrees share
  the index-adjacent state that made the guard necessary), then `ship-feature.ps1
  pr`. The tracker update — task status, the log entry — is part of the feature's
  PR, not a separate commit on the trunk.
- **Merging** is its own act, gated by the adversarial review (T1060) and
  reported in the digest (T1059). A turn does not merge its own PR without that
  review having run.

Everything else — the claim, the digest, the guards, `/reset-context` — is
unchanged.

## Open dependencies

| | What is needed | Owner |
|---|---|---|
| T87 | macOS regression build, then the merge validated on Mac | **Mac seat** — cannot be done here |
| T1059 | the digest names every open PR and its CI health | Windows seat, after this |
| T1060 | the adversarial review gate before any merge | Windows seat, after this |
| `behind` | 93 commits of `origin/main` merged into the branch | Windows seat |

## Acceptance

`test\win32\ship-workflow.ps1` — the readiness gate's honesty (A), the whole
lifecycle in a throwaway repo pair including every refusal (B), the `gh`
landmine scan (C), and the doc/go.md wiring (D). Registered in
`scripts\guard-due.ps1` as `ship-workflow`, so editing either script marks the
harness due.
