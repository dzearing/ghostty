# Windows parity tasks — one file per task

**This directory is the canonical task store.** One task, one file:
`T<id>.md`. It replaces the single state table in
`../windows-parity-tasks.md`, which is now **frozen** (see Migration below).

## Why one file per task

Two agents work this repo at once — the `go.md` execution loop and an
interactive session. A single shared table means every new task is a write to
the same file and the same few lines, so concurrent work either conflicts or
silently clobbers. It has already cost us: two rows were filed for the same
bug under the id **T112**, and the id **T153** was minted twice on the same
day by two sessions that could not see each other.

One file per task makes both failures structurally impossible:

- **Adding a task** creates a new file. It cannot conflict with an edit to
  any other task.
- **Editing a task** touches only that task's file.
- **Duplicate ids** cannot happen silently — the file already exists, and
  `parity-tasks.ps1 new` allocates with an atomic `CreateNew` that *fails* if
  a racing agent took the number, then retries with the next one.

## File format

YAML frontmatter, then prose. Frontmatter is the machine-readable part; keep
it accurate, because `parity-tasks.ps1` reads it.

```markdown
---
id: T144
title: "New windows (ctrl+n) open in C:\\Windows\\System32"
phase: "K"
deps: ["T89h"]
status: "todo"
commits: []
seat: "win"
tags: ["fix"]
user-report: true
---

# T144 — New windows (ctrl+n) open in C:\Windows\System32

## Summary

What is wrong, the evidence, the fix, and how it will be validated.

## Details

Spec, design notes, on-box evidence. Grows as the task is worked.

## Validation criteria

- [ ] The observable checks that prove this is done. Tick each as it is
      verified, and say HOW it was verified (which script, which lane,
      which manual check) next to the tick.

## Progress log

- 2026-08-05 09:12: claimed; work starting.
- 2026-08-05 09:40: root cause found in X; writing the fix in Y. Filed T201.
```

| Field | Meaning |
|---|---|
| `id` | Must equal the filename stem. Enforced by `validate`. |
| `title` | One line, no markdown. Shown by `list` / `next`. |
| `phase` | Grouping letter, or `null`. |
| `deps` | Ids that must be `done`/`skipped` first. `[]` if none. |
| `status` | `todo` / `in-progress` / `done` / `blocked(<what>)` / `skipped(<why>)` |
| `commits` | Commit hashes that delivered it. |
| `seat` | Which box can do the work: `win` (default when absent) / `mac` / `any`. |
| `priority` | What the work is WORTH, and the queue's primary sort key: `P0` severe (crash, hang, data loss, a broken feature) / `P1` feature work and UX polish (the `new` default) / `P2` infra and nice-to-have / `P3` reviewed and deliberately behind everything else. Absent means *untriaged*, which sorts behind even `P3` — "nobody has looked" is a weaker claim than "somebody looked and parked it". A value outside the set fails `validate` (T345): it would otherwise read as untriaged and silently lose its ranking. |
| `order` | The sequence *within* one priority band. Fractional on purpose, so `set-order T500 -Order 2.5` injects between two neighbours without renumbering. Absent means unordered, which sorts LAST in the band — so `order:` cannot express "put this behind everything", and `P3` is the spelling for that. |
| `triage-reason` | One line saying why the task carries the priority it does. Written by `set-priority -Summary`, shown by `next`. |
| `tags` | Categories, from a closed set: `feature` / `fix` / `polish` / `perf` / `test` / `infra` / `docs` / `security`. Optional (pre-tag files have none); an unknown tag fails `validate`. The dashboard shows them on activity cards and in the task detail view, so a reader can tell user-facing work (`feature`/`fix`/`polish`) from internal work at a glance. |

## Progress log + stale in-progress resume (2026-08-05)

Two bluescreens killed loop turns mid-task and left tasks marked
`in-progress` with no agent on them, half-done work uncommitted, and no
record of where the turn had got to. Two rules close that hole:

- **Journal as you work.** `parity-tasks.ps1 note T144 -Text "..."` appends a
  timestamped line to the task's `## Progress log` (creating the section if
  needed; `-Session <id>` stamps which conversation wrote it). `next -Claim`
  writes the first entry automatically. Add one at each meaningful step —
  root cause found, fix built, validation run, surprise hit — so a dead turn
  leaves a trail, not a bare status.
- **A stale claim is resumed, never orphaned.** This queue runs ONE agent at
  a time, so any task still `in-progress` when `next -Claim` runs is a stale
  claim by definition. `next -Claim` hands that task back (output `RESUME:`
  instead of `NEXT:`) with instructions to reassess from its progress log and
  `git status` before either finishing it or noting why and resetting it to
  `todo`. Plain `next` stays read-only and just prints an `IN FLIGHT:` line.
  `validate` fails an in-progress task with no `## Progress log`.

## Validation criteria (2026-08-05)

Every task carries a `## Validation criteria` checklist — the observable
checks that prove it is done (`new` scaffolds it). The turn that lands the
task ticks each criterion **with how it was verified**. The dashboard's task
detail view shows the checklist, so "what validation was done" is answerable
without reading the diff.

## `user-report:` — a task a person asked for (T1315, 2026-09-04)

`user-report: true` says a USER told us about this: a report in the terminal, a
screenshot, "it did the thing again". It is optional and absent means no, so
every older file keeps meaning what it always did.

The flag is not a label — it changes what closing the task does. `set-status
<id> -Status done` on a flagged task runs `scripts\daily-publish.ps1 -Request`
itself, with the task id and title as the reason, so the fix ships that day
rather than waiting for the next daily release; the request is recorded in the
task's own progress log. `validate` then fails **UNSHIPPED USER REPORT** on a
closed user report whose log has no such receipt.

```powershell
scripts\parity-tasks.ps1 new -Title "…" -UserReport -Tags fix
scripts\parity-tasks.ps1 set-priority T123 -Priority P0 -UserReport   # triage recognises one
```

Why it is structural rather than a habit: T1294 made the same-day publish
possible and left the *asking* to whoever closed the task. On 2026-09-03 that
cost the user a second download of the same broken installer and a second
report of a bug we had already fixed. A closed user report is not done from
where they are standing until the fix has shipped. Acceptance: section F of
`test\win32\gate-negatives.ps1`.

## Seats (T344, 2026-08-02)

Some tasks can only be done on the other machine — a Swift fix that needs a
macOS regression build, a Mac-side verification of a shared-Zig change. The
tracker has named them in prose since T87 (*"Mac seat: …"*), but the tooling
did not know, so `next` kept handing this box **T30** — a task whose Validation
begins *"Mac regression build"*. `next` is a pure function of the files, so
that is not a one-turn annoyance: **every** turn gets the same answer.

`seat:` makes it data. The default is `win`, which is why the field is
optional and every pre-T344 file still means what it always did.

```powershell
scripts\parity-tasks.ps1 next                 # this box: win + any
scripts\parity-tasks.ps1 next -Seat mac       # the Mac seat's own queue
scripts\parity-tasks.ps1 list -Seat mac       # what is waiting over there
scripts\parity-tasks.ps1 new -Title "…" -Seat mac
```

Filtering is never silent: `next` prints every todo it passed over for the
other seat, with its seat, so the queue that is not yours stays visible. A
seat value outside the set fails `validate` — a typo would hide the task from
*both* seats, which is the stall this field exists to end.

Suffixed ids are real and load-bearing: `T89a` (a split of T89) and `T89f2`
(a split of a split). Any `T<digits>[letter][digits]` is valid.

## Using it

```powershell
scripts\parity-tasks.ps1 next                 # first todo whose deps are all done
scripts\parity-tasks.ps1 list -Status todo    # filter by status
scripts\parity-tasks.ps1 list -Phase K
scripts\parity-tasks.ps1 show T144
scripts\parity-tasks.ps1 set-status T144 -Status done -Commit abc1234
scripts\parity-tasks.ps1 new -Title "Short title" -Phase K -Deps T73,T94
scripts\parity-tasks.ps1 stale-scan -Top 40   # which todos may already be fixed
scripts\parity-tasks.ps1 validate             # ids, titles, statuses, dangling deps
```

**A todo is a claim about the code, made on the day it was filed, and nothing
re-checks it** (T404). T98 was handed out fourteen days after T41 had already
fixed its defect at the source, and the loop spent a whole turn discovering
that; the expensive version is a card a later fix only PARTLY repaired, where
the next agent implements over work it never read.

So the question is asked at PICK time. `next` prints the filing date and any
commits that have touched the files the task itself names since — with `CHECK
FIRST` when there are any — and `stale-scan` asks it of the whole queue, ranked
by a later commit having NAMED the task (a follow-up that fixed it in passing, a
split that absorbed it, a duplicate that closed it), then oldest first.

Both are prompts, never verdicts: of the first four cards checked this way, one
was already fixed by a main intake, one was partly fixed, and two were entirely
real. Only exact FILE paths count — a card naming `test\win32\` names an area,
and ranked by raw hit count every such card sat on top with 300+ "touches",
which measures how busy the repo is and says nothing about the task.

`validate` is the gate: run it before committing a task change. It prints
`ALL PASS (<n> tasks)` or the specific problems, and exits non-zero on
failure.

**A status change writes its own receipt** (T564). `set-status` appends the
transition to the task's `## Progress log` — `status: blocked(waiting for a
recurrence) -> todo (by dashboard: is unblocked and back in the queue)` — so a
reader can always tell what moved a task and who moved it. Two consequences
worth knowing:

- The **old status is preserved verbatim**, reason and all. Statuses carry a
  parenthetical (`blocked(...)`, `skipped(split -> T394)`) and the dashboard's
  buttons write a bare `todo` over it; the log entry is the only place that text
  survives. Before this, un-parking a task destroyed the reason it was parked.
- `-SourceNote "<who>"` names the hand on it; `-NoNote` suppresses the entry and
  exists **only** for a bulk normalisation pass that would otherwise stamp a note
  into every file. A status flip with no receipt is the defect T564 fixed — do
  not reach for it to keep a diff small.

A no-op (setting the status it already has) writes nothing, so re-running a
command is not an event.

**Un-blocking needs evidence** (T892). Moving a task OUT of `blocked(...)` is
the one transition that asserts something nobody checked — the park recorded a
condition, and a bare `set-status <id> -Status todo` claims it is now met while
saying nothing about it. `set-status` therefore refuses that transition without
`-SourceNote`, and prints the task's `unblock:` text so the caller sees the
condition they are claiming is satisfied:

```powershell
# refused (exit 2), and prints T443's unblock condition back at you
scripts\parity-tasks.ps1 set-status T443 -Status todo

# accepted, and the receipt says what was checked
scripts\parity-tasks.ps1 set-status T443 -Status todo `
    -SourceNote "fresh access violation in the 03:02 win32 lane; dump appended to the watch log"
```

Every other transition is untouched — a claim, a close, a re-park
(`blocked(a)` → `blocked(b)`) all stay as cheap as they were. `-NoNote` is
still the bulk hatch, and prints that it took it. This exists because T443's
armed watch was reopened twice with nothing behind it (D27, then 2026-08-16),
and each time the next turn spent its whole context re-verifying the same watch
and re-parking it.

**Always mint ids with `new`.** Hand-picking a number reintroduces exactly
the race this layout removes.

## Reading discipline (this still matters)

The context rule in `go.md` is unchanged, and this layout makes it cheaper to
obey: read **only** the task file you are working plus `go.md`. Do not read
the directory wholesale — that is what `list` and `next` are for. A single
task file is a few KB; the old table was 35 KB and had to be read in full to
find one row.

## Migration (2026-07-29)

Generated from the state table in `../windows-parity-tasks.md` plus the
matching `## T<id>` sections of `../windows-parity-details.md`. 185 files;
`validate` passes.

Nothing was dropped, including three things the first pass would have lost:

- **`T112`** had two table rows for the same defect. Both are in `T112.md` —
  the later one as the Summary, the earlier under "Earlier filing".
- **`T53`** had a details section but no table row (an umbrella split into
  T53a/T53b). Preserved as `T53.md`.
- **`T89d1` / `T89f1` / `T89f2`** were initially missed by an id pattern that
  did not allow a digit after the letter suffix. Caught by `validate`
  reporting them as dangling deps.

**The old docs are frozen, not deleted:**

- `../windows-parity-tasks.md` — the resume protocol and the key code
  landmarks are still live and still worth reading; its **state table** is a
  historical snapshot. Do not add rows to it. **Current priorities** was
  frozen on 2026-08-21 (T345) once every task it named had closed: `next` is
  the ordering authority, and the way to change what comes next is to
  re-triage the task (`set-priority`), not to hand-maintain a list.
- `../windows-parity-details.md` — its per-task sections were copied into the
  task files. Do not edit it; edit the task file.
- `../windows-parity-log.md` — unchanged, still the dated session log.

Copies drift, so the copy is the one to trust: **the task file wins.**
