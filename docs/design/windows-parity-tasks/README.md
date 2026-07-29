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
---

# T144 — New windows (ctrl+n) open in C:\Windows\System32

## Summary

What is wrong, the evidence, the fix, and how it will be validated.

## Details

Spec, design notes, on-box evidence. Grows as the task is worked.
```

| Field | Meaning |
|---|---|
| `id` | Must equal the filename stem. Enforced by `validate`. |
| `title` | One line, no markdown. Shown by `list` / `next`. |
| `phase` | Grouping letter, or `null`. |
| `deps` | Ids that must be `done`/`skipped` first. `[]` if none. |
| `status` | `todo` / `in-progress` / `done` / `blocked(<what>)` / `skipped(<why>)` |
| `commits` | Commit hashes that delivered it. |

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
scripts\parity-tasks.ps1 validate             # ids, titles, statuses, dangling deps
```

`validate` is the gate: run it before committing a task change. It prints
`ALL PASS (<n> tasks)` or the specific problems, and exits non-zero on
failure.

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

- `../windows-parity-tasks.md` — the narrative sections (resume protocol,
  **Current priorities**, key code landmarks) are still live and still worth
  reading; its **state table** is a historical snapshot. Do not add rows to
  it. `Current priorities` remains the ordering authority over `next`.
- `../windows-parity-details.md` — its per-task sections were copied into the
  task files. Do not edit it; edit the task file.
- `../windows-parity-log.md` — unchanged, still the dated session log.

Copies drift, so the copy is the one to trust: **the task file wins.**
