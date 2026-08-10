# Windows parity sweeps

The evidence trail for `scripts\parity-sweep.ps1` (T152). One section per
swept range, written at the time the range was evaluated.

**Why this file exists.** The sweeps before T152 (T88, T117) recorded a
*narrative* of what a merge contained — "this brought the viewer work". A
narrative cannot be checked for holes, and on 2026-07-29 a re-audit found 16
Mac commits that had been merged and never mapped to any Windows work item.
The sweep replaces the narrative with an enumeration, and this file is where
the enumeration lands so the next sweep can diff against it instead of
re-deriving it.

**How a commit stops being unmapped.** The sweep keys coverage on the commit
sha, so a commit is covered once *some* parity doc cites it. Three legitimate
dispositions, all of which count:

1. **Filed** — a new task exists for it.
2. **Covered by an existing task** — the behavior is already in the queue and
   the commit is simply part of that task's content. Cite it against that
   task; do not file a duplicate.
3. **No parity owed** — Mac-only (a Swift crash fix, a macOS test harness, a
   doc scrub). Say *why*, so a later reader does not have to re-derive the
   judgement.

Never resolve an unmapped commit by deleting it from the range.

---

## `cda6e5191..4a41394b2` — 2026-08-08 main intake (swept 2026-08-09)

Swept retroactively: this range was the 2026-08-08 intake, which filed
T598-T606 before the sweep existed. The sweep found **7 of its 54 commits
uncited** — none of them a missing feature, all of them content of a task
that was already filed. That is the exact leak shape T152 was filed for
(compare `538f4fd64` in T152's own table: *"behavior covered, commit was
uncited"*), and it is why citation is now a gate rather than a habit.

- Commits evaluated: 54
- Mapped at the time of the sweep: 47
- Unmapped, now dispositioned: 7

| Commit | Subject | Filed as |
|---|---|---|
| `06d50037a` | macos: harden banner state writes and escape untrusted banner fields | T598 (bundled-hook content) |
| `1b632b812` | macos: drop dead `last` key from banner wipe lists | T598 (bundled-hook content) |
| `4b07859e4` | docs: warn against "fixing" the load-bearing TERM_PROGRAM=ghostty spelling | T598 (bundled-hook content) |
| `15208971a` | docs: correct the agent-integration description to match the code | T598 (bundled-hook content) |
| `4ea557270` | docs: record the HookSpec generalization as a deferred refactor | T598 (bundled-hook content) |
| `4df779938` | macos: drop the AI-attribution line from the bundled process-feedback skill | T598 (bundled-skill content) |
| `bced2217c` | test(macos): give poll's default deadline real headroom (15s -> 60s) | No parity owed - a macOS-only XCTest deadline |

This is also the whole divergence: `git merge-base HEAD origin/main` is
`cda6e5191`, so with this range clean there is nothing on main that this
branch has not been told about.

**What the six T598 rows mean for the Windows work.** They are all changes to
the files main's agent integration *installs* (`ghoztty-banner.sh` and the
bundled `process-feedback` skill), which Windows does not install at all yet.
So they add no new Windows task, but they do change what T598 must ship when
it lands: the hardened banner script (mkdir-mutex around the state
read-modify-write, unique temp file, self-healing on a corrupt state file, and
markdown-escaping of prompt-derived and model-set fields so an untrusted value
cannot forge a clickable link in the trusted banner overlay), the
de-attributed skill template, and the `TERM_PROGRAM=ghostty` spelling that
reads like a typo and is load-bearing. Vendoring the pre-hardening copies
would ship known defects on day one.

---

## Known backlog: already-merged history (not yet swept)

Running the sweep over merged history — `680a07ed3..HEAD`, everything since
2026-06-01 — reports **210 commits, 126 of them cited nowhere**. That is the
tail the 2026-07-29 hand audit never reached (it only covered
`--since=2026-07-08`) plus everything the T88 and T117 merges brought in
before that.

Most of those 126 are expected to be no-parity-owed or covered-but-uncited,
the way T598's six turned out to be. Expected is not measured, which is the
entire argument for this file. Tracked as **T684**, to be worked in slices
with each commit dispositioned here.

The sweep also does not watch the shared `src/` core yet, so a change main
makes to code both platforms compile is currently ungated — that is how the
`src/cli/send_keys.zig` divergence behind T604 went unflagged. Tracked as
**T685**, which has to solve the "our own commits are not incoming commits"
problem before the paths can widen.
