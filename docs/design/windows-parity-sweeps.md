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

## `680a07ed3..HEAD` — already-merged history (swept 2026-08-10, T684)

The tail the 2026-07-29 hand audit never reached (it only covered
`--since=2026-07-08`), plus everything the T88 and T117 merges brought in
before that — i.e. every Mac-side commit on this branch since 2026-06-01.

- Commits evaluated: 210
- Mapped before this sweep: 84
- Unmapped, dispositioned below: 126
- Genuine gaps found and filed: **7** (T709–T715)

**Three dispositions do the bulk of the work here, and each is a claim about
evidence, not a shrug:**

1. **Port baseline.** The range is *already-merged* history, and the Windows
   port of each of these features was written afterwards, in July/August,
   against Mac code that already contained the commit. So the commit is part
   of what the port copied, not a delta the port missed. Cited against the
   port's own task, which is where a reader should go to ask whether the port
   is faithful.
2. **Shared code, already compiled in.** The substance is in `src/` (core,
   `src/remote/`, `src/cli/`), which the Windows build compiles from the same
   tree. Nothing is owed unless a *Mac-frontend* behavior rides on top, and
   where one does it is called out.
3. **Mac-only.** A Swift object-lifetime or AutoLayout fix, an XCTest change,
   or a CI/identity/doc scrub. Named individually below with the reason, so a
   later reader does not have to re-derive the judgement.

### Remote windows, the machine chooser, and the relay — port baseline

WP4 (June) and WP-A1/B2/C2/D1/D2 (July) built the Mac's remote-window stack:
Cmd-Shift-N chooser, the machine pill, TCP and relay transports, Google
sign-in, the reconnect ladder, and remote-window restore. The Windows port of
all of it is T21a/T21b (relay dial + sign-in), T22b/T22c (device directory +
chooser dialog), T93 (brokered OAuth), T68 (new window/tab/split inherits the
remote host), T367 (the caption-band connection pill), and T318–T321/T336
(session roster, cross-machine browse, resume, Restore All).

`333b9565a`, `e91c6e7b7`, `5236bb863`, `75c4b301d`, `f3e5ec070`, `29ee2c71e`,
`5945f7e13`, `d550aa8dd`, `86ada5f9e`, `74ea0674f`, `9186f1f00`, `a8a485f5b`,
`f0482de02`, `dbfcd7c08`, `a12c26765`, `3f6dc90bc`, `8076e707b`, `9716098bb`,
`361aa960e`, `9ce38cdaa`, `68d7baa8a`, `9ca6b1773`, `ef84967d6`, `b2b90939c`,
`d7c570175`, `4a55acef1`, `81792453a`, `f1d38a028`, `d2d47f5b0`, `4c5ae0e1a`,
`ff9760acb`, `881d09a91`, `555ca6607`, `cbc3d5bfe`, `a00550f84`, `f2dbaeb2c`

Two of those carry a live Windows follow-up rather than a gap of their own:
`cbc3d5bfe`/`a00550f84` (a device rename reaches every open window's pill)
land on **T610**, since the win32 pill does not name the machine at all yet;
`23d3938e8` (live per-machine CPU/mem in the picker) is **T619**, already
filed and open.

`23d3938e8`

### Activity Monitor — port baseline (T226 → T284/T285/T286/T295/T296/T298)

The Mac built the panel over three days at the end of June — charts, machine
carousel, process filter, multi-select kill, sparklines. The win32 port
(T226 and its four splits) was written against that finished panel.

`9e8ff621b`, `04c03f9e6`, `ea6b4ef70`, `afda9fcf8`, `f24d7f472`,
`ac4b8c401`, `b359f5a12`, `e69bb02a6`, `c6a72a8ee`, `438b853bb`, `f55488c13`

### Hero mode — port baseline (T19a/T58/T59a/T59b, divider T250)

`fe5335968` reflowed terminal content and smoothed the divider drag in Mac's
hero mode. The win32 hero mode was designed (T58) and ported (T59a/T59b)
afterwards, on a snapshot pipeline rather than live panes, and its divider was
brought onto the design system in T250.

`fe5335968`

### Session persistence — port baseline (T89a → T89b–T89i)

Mac's T03–T19 series (LocalAgentManager, the session-layout manifest,
launch-time restore, the per-user LaunchAgent, `sessions.json`, on-by-default)
is the design the Windows port translates: named pipe for the UDS, HKCU Run
for the LaunchAgent, `%LOCALAPPDATA%\ghoztty\local-agent[-debug]\` for the
state directory.

`09f277f47`, `3730b5f26`, `3e3f355a0`, `6c6e32b64`, `0490b16fc`, `a0dce4b48`,
`cda38f18f`, `2654015c7`, `03a781207`, `062d797f7`, `5ed3c26a9`

### Viewer panes — port baseline (T90a → T90b–T90h)

Mac's T01–T15 viewer series in one day on 2026-07-17, plus its follow-ups.
The Windows port is T90a's design and the T90b–T90h splits, whose own
follow-ups (T380, T383, T390, T394–T397, T399, T400) are where the individual
behaviors below are tracked on this side.

`6a10f3a53`, `df7a46903`, `ccf71bf4d`, `b612d6540`, `ebd25654c`, `2ba2744ba`,
`ad7d547c2`, `27a6fa42e`, `f88e9a5fd`, `2b9018a9a`, `52100e1cc`, `fda06f156`,
`81fc07da2`, `0a22f6a1c`, `dd9811582`

`dd9811582` (File→Open / dock drop for markdown) is the one with no Windows
equivalent filed. It is not a gap in the pane itself: the win32 build has no
file-association or drop-target story at all, which is a larger question than
this sweep, and `+new-window --view=` already covers the scriptable path.

### Pane banner markdown — port baseline (T35, T131, T149, T165, T377)

Headings, tables, lists, checkboxes, separators, autolinking and the wrapping
rules all shipped on Mac between 2026-07-17 and 2026-07-30 and are documented
as present on Windows in CLAUDE.md, each with its own win32 task and geometry
assertions.

`47e15036f`, `6eeebcc15`, `701d700bf`, `bc016b257`, `4dd56db35`, `6da6dad9f`,
`c77c98f54`, `c35dabe73`, `c7c9da939`

### Chooser and Activity Monitor build-out (August) — mixed

This is the youngest slice and the one that produced most of the real gaps,
which is what you would expect: the Windows ports were written before it.

| Commit | Disposition |
|---|---|
| `7d9ef0dff` | Per-session CPU meter fed by the agent's pushed stream — **T462** (win32 never subscribes to `session_cpu`) |
| `f0d5e3308` | Stop the session-CPU stream when the picker closes — content of **T462** |
| `9c79a6374`, `8133f7bfe` | CPU-value layout polish in the row — content of **T462** |
| `9e06ca67a` | Live session roster while the dialog is open — **T710** (filed) |
| `bf318f55b` | Push the roster instead of polling it; show window renames — **T710** (filed) |
| `74fade009` | Right-aligned "See Activity", now including This Mac — **T177** (the win32 detail action row, done) |
| `2a5da6a27`, `d706f2d28` | Never offer to resume a session we have no pane for; hide just-closed panes — **T520** (open) |
| `f0a4ad6d0` | Stop `sessions.json` growing forever with dead Resume rows — shared `src/remote/`, already compiled into the Windows agent |
| `78a21daa8` | Modeless New Window picker — **T712** (filed) |
| `ab79f37c4`, `2964c8859` | Per-core %CPU and which pane owns each process — **T709** (filed) |
| `9018aee04` | What's New reshaped into a real release-notes window — **T624** (open: no bundled release notes on Windows) |
| `38d02efe9` | Link the version at the fork's release — **T714** (filed) |
| `3de92c55d` | New-surface link clicks go to the default browser — already shipped on win32 as **T163** (popup adoption + Ctrl to keep) |
| `2742c2013`, `c90f110be` | macOS XCTest timing fixes — no parity owed |

### Filed as new Windows tasks

The seven genuine gaps this sweep found. Each names the Mac commit in its own
Summary, which is what maps the commit from here on.

| Task | Gap | From |
|---|---|---|
| **T709** | Activity Monitor has no per-core %CPU and no owning-pane column | `ab79f37c4`, `2964c8859` |
| **T710** | The chooser polls the roster instead of being pushed it, and never shows a window rename | `bf318f55b`, `9e06ca67a` |
| **T711** | The chooser opens with an empty, unseeded device list and never refreshes while open | `66012e2ee`, `b0028112a`, `55dd70978`, `27e639ae6` |
| **T712** | The chooser is modal and freezes the terminal behind it | `78a21daa8` |
| **T713** | Relay sign-out leaves account remote windows running and new dials allowed | `ed8482d25` |
| **T714** | The About box has no links — no fork release for the version, no Help | `6ea66423f`, `38d02efe9` |
| **T715** | No assistive-tech attribute for a remote window's link state | `97530c9ac` |

### Mac-only — no parity owed

| Commit | Why nothing is owed |
|---|---|
| `716ade71a` | Swift object-lifetime fix: use-after-free tearing down a remote pane's `SurfaceView`. win32 owns its surfaces explicitly; no analog. |
| `f7459ffee`, `fe592d126`, `042f9c6f7` | AppKit AutoLayout thrash around the machine pill (intrinsic content size feedback loop, and its revert). The win32 pill is laid out by hand in `remote_pill.zig`. |
| `b421cfac3` | "Never swap a failed surface over a healthy grid" — a SwiftUI view-swap ordering bug. win32 rebuilds the pane's transport in place. |
| `c1b42e16f` | Stop the reconnect ladder on a poisoned session — the win32 ladder already carries the poisoned-session breaker (T367, documented in CLAUDE.md). |
| `38ff0c0e3`, `03ca52586` | Frozen-agent thaw. The fix is in `src/remote/` and the agent, which Windows compiles and runs; the Mac half is Swift plumbing. |
| `bff7c6c40` | GUI-thread/IO-thread join deadlock — the fix is in `src/Surface.zig`, `src/termio/` and `src/datastruct/`, i.e. already in the Windows build. |
| `c1570b5eb`, `372a8c606` | IPC single-instance with sentinel-file recovery. Windows has no sentinel file *by design*: binding the named pipe **is** the single-instance lock (`IpcServer.zig`), so there is no stale-socket state to recover from. |
| `3a2df53e1`, `912299319` | Bundle-identity renames (`com.mitchellh.*` → `com.dzearing.ghoztty`) across Info.plist, xcodeproj, flatpak, po/, CI. The Windows endpoints already derive from the `ghoztty` name. |
| `ed34fbab7` | Automatic CLI setup + Claude Code integration on first launch — win32 has its own `ClaudeIntegration.zig` doing the same job the Windows way. |
| `d7fbe2cd6` | `+split --target=<window>` no-op when a viewer pane is focused. A SwiftUI focus-resolution bug: win32 splits the tab's active pane *node* (`Window.newSplitAt`), which is pane-kind agnostic, and T395 exercises that path from a viewer. |
| `97530c9ac` | *(the AX attribute half is filed as T715; the macOS test half is Mac-only)* |
| `366f557b4` | Chooser polish — hide own machine, dedupe header, footer divider, profile-photo avatar. The win32 chooser is owner-drawn with its own layout (T172, T175–T177); T602 tracks the remaining identity-band difference. |
| `bc96dad4d` | XCTest: wait for conditions instead of fixed durations. |
| `6ea66423f` | *(the Help/About link half is filed as T714)* |

### What this sweep does not cover

The sweep still watches only `macos/` and `src/viewer/`, so a change main
makes to the shared `src/` core is ungated — that is how the
`src/cli/send_keys.zig` divergence behind T604 went unflagged. Tracked as
**T685**, which has to solve the "our own commits are not incoming commits"
problem before the paths can widen.
