---
name: ghoztty
description: Use when opening terminal windows, creating split pane layouts, opening a rendered markdown/doc/README, a live HTML page, a code file, or a website in a viewer ("side") pane, showing a git diff in a pane (current branch vs main, `git status`, a single commit, or an arbitrary range), listing open windows/panes, renaming window titles, rearranging pane layouts, reading terminal output, sending keystrokes to panes, setting activity state, showing a sticky status banner above a pane, listing persistent terminal sessions, opening a shell on a remote machine, emitting `ghoztty://focus/<target>` links so a generated document can jump to a terminal window or pane, or managing Ghoztty windows via CLI. Ghoztty is a terminal emulator with IPC commands for programmatic window/pane management. Use this skill whenever you need to launch a terminal, create splits, open a file or website in a side/viewer pane (rendered markdown, a live HTML page, syntax-highlighted code, or a webpage), show changes for a branch, commit, or range, query window state, rename windows, rearrange layouts, read pane output, send input to panes, track activity state, post a persistent banner with status/links above a pane, or tear down layouts. When the user says "open X in a side pane", "show the readme/doc beside this", or "preview this markdown", use `+split --view=<path-or-url>`; when they say "show me changes in this branch", "what's on my branch vs main", "show me my git status", or "what changed in <sha>", use `+split --view=git-diff:<revspec>` or `--view=git-status:`.
---

# Ghoztty CLI Reference

Ghoztty is a fork of Ghostty that adds CLI-driven window management over a Unix domain socket. All IPC commands are **idempotent** — named targets that already exist are focused instead of recreated.

## Prerequisites

Before running any `ghoztty` commands, verify it's available:

```bash
command -v ghoztty
```

If not found, tell the user:

> **ghoztty not found.** Install it from https://github.com/dzearing/ghoztty/releases and make sure it's in your PATH.

Do NOT proceed if `ghoztty` is unavailable.

## Know where you are: `$GHOZTTY_PANE_ID`

Every pane bakes its own identity into its processes' environment. When you are
running **inside** a Ghoztty pane, you already know which pane you are — do not
call `+list` to figure it out.

| Variable | What it is |
|---|---|
| `$GHOZTTY_PANE_ID` | This pane's stable id (a UUID). Accepted directly by every `--target`/`--name`/`--pane` with no prior registration or `+list`. Stable for the pane's whole life, across app relaunch and session restore. |
| `$GHOZTTY_WINDOW_NAME` | The name of the window this pane is in, when it has one. |
| `$GHOZTTY_IPC_SOCKET` | The IPC socket of the app instance that owns this pane. The CLI reads it automatically — you never pass it, but it is why commands reach *this* app (e.g. a debug build) rather than whichever build is on `$PATH`. |

**So "open a side pane here" is one command:**

```bash
ghoztty +split --pane="$GHOZTTY_PANE_ID" --direction=right
```

Rules that follow from this:

- **Target your own pane explicitly.** A bare `+split` goes to the *most recently
  focused* window — if the user clicks another window between their request and
  your command, the split lands in the wrong place. `--pane="$GHOZTTY_PANE_ID"`
  is immune to focus changes.
- **Do not pass `--working-directory` for a plain split.** A new split inherits
  the parent pane's cwd. Passing your own cwd overrides it, and the two diverge
  as soon as the shell `cd`s somewhere.
- **Do not call `+list` first.** It is a wasted round trip when you only need
  your own pane, and it auto-registers every pane it walks. Use `+list` when you
  genuinely need to inspect *other* windows/panes.
- Prefer the pane id over pid/tty matching: pids and ttys are per-machine and are
  meaningless for remote panes. (`+list --tty=<tty>` remains a fallback for a
  process that has no baked env, e.g. one started before its pane existed.)

## Commands

### `ghoztty +new-window`

Create or focus a terminal window. **Auto-launches Ghoztty if no instance is running.**

```
ghoztty +new-window [flags]
```

| Flag | Description |
|------|-------------|
| `--target=<name>` | Register window with a name. If it already exists, focuses it instead. |
| `--working-directory=<path>` | Working directory for the terminal. Relative paths are resolved from CWD. `~` is expanded. If omitted, uses the CWD where `ghoztty` is invoked. |
| `--command=<cmd>` | Command to run in the terminal. Auto-wrapped in the user's login shell with profile loaded. |
| `--view=<path-or-url>` | Open a **viewer** pane instead of a terminal: a rendered markdown file, an `.html`/`.htm` file rendered as a **live page**, a syntax-highlighted text/code file, or a website (http/https URL). Relative paths resolve against `--working-directory` (else caller cwd). Mutually exclusive with `--command`/`-e`. |
| `--shell=<path>` | Shell to use for `--command`/`--split-command`, invoked with `-lic`. Falls back to config `command-shell`, then `$SHELL`, then `/bin/zsh`. |
| `--env=KEY=VALUE` | Environment variable for the spawned process. Repeatable. |
| `--no-activate` | Create the window without stealing focus from the current workspace. Useful for automation and background agent windows. |
| `--title=<title>` | Override the window/tab title. |
| `--split=right\|down\|left\|up` | Atomically create a split pane alongside the main pane. |
| `--color=<#hex\|random>` | Background color for the window. Hex (`#rrggbb` or `#rgb`) or `random` for a random dark tint. |
| `--split-color=<#hex\|random>` | Background color for the split pane (only with `--split`). |
| `--split-command=<cmd>` | Command for the split pane (only with `--split`). |
| `--split-percent=<1-99>` | Percentage of space for the new split pane (default 50, only with `--split`). |
| `-e <args...>` | Everything after `-e` becomes the command. No more flags are parsed. |

### `ghoztty +split`

Create a split pane in a running window.

```
ghoztty +split [flags]
```

| Flag | Description |
|------|-------------|
| `--direction=right\|down\|left\|up` | Split direction. Default: `right`. |
| `--target=<name>` | Window or pane to split in — a name from `--target`/`--name`, or any pane id (e.g. `$GHOZTTY_PANE_ID`, no registration needed). Default: most recently focused window. |
| `--pane=<name-or-id>` | Split adjacent to this specific pane instead of the focused one. Use `--pane="$GHOZTTY_PANE_ID"` to split off your own pane regardless of what the user has focused. |
| `--name=<name>` | Register the new pane with a name. If it already exists, focuses it instead. |
| `--command=<cmd>` | Command to run in the new pane. Auto-wrapped in the user's login shell with profile loaded. |
| `--view=<path-or-url>` | Open the new pane as a **viewer** (rendered markdown / live HTML page / highlighted code / website) instead of a terminal. Relative paths resolve against `--working-directory` (else caller cwd). Mutually exclusive with `--command`/`-e`. This is the way to "open a file/README/doc in a side pane". |
| `--shell=<path>` | Shell to use for `--command`, invoked with `-lic`. Falls back to config `command-shell`, then `$SHELL`, then `/bin/zsh`. |
| `--env=KEY=VALUE` | Environment variable for the spawned process. Repeatable. |
| `--color=<#hex\|random>` | Background color for the new pane. |
| `--working-directory=<path>` | Working directory for the new pane. |
| `-e <args...>` | Everything after `-e` becomes the command. |

### Viewer panes (`--view=<path-or-url>`)

Both `+new-window` and `+split` accept `--view` to open a **viewer pane** instead
of a terminal. This is the built-in way to honor "open the README in a side pane",
"show that doc beside this", or "preview this markdown" — **do not** shell out to
`less`/`cat`/`open` for that. The pane renders:

- **Markdown** files — fully rendered (GitHub styling, code highlighting, task
  lists), with **live reload** on save (scroll position preserved).
- **HTML** files (`.html`, `.htm`) — rendered as a **live page**, not as
  source: the file's own CSS, JS, images, and fonts load from its directory,
  and it **live-reloads on save** (scroll preserved). A static mock or
  prototype needs no server. Two limits: assets must live under the page's own
  directory (no `../shared/app.css`), and only the HTML file itself is
  watched — `+reload` picks up a changed sibling stylesheet or script.
- **Text / code** files — syntax-highlighted, read-only.
- **Websites** — any `http(s)://` URL (this is the only mode that uses the
  network; file rendering is fully offline via bundled assets).

It follows the system/app light-dark theme automatically. Viewer panes are
**view-only** (no editing) and are ordinary leaves in the split tree, so
`--name`, `--target`, `--split-percent`, `+close`, and `+rearrange` all work on
them. Idempotent: re-running with the same `--name` focuses the existing viewer
instead of opening another. (Minor gap: while a viewer pane is focused, some
`goto_split` keybindings may not fire — click a terminal pane to regain them.)

```bash
# Open a README in a rendered pane to the right of YOUR pane
ghoztty +split --pane="$GHOZTTY_PANE_ID" --direction=right --view=README.md

# A doc pane at 45% width, named so you can refocus/close it later
# (--working-directory here only resolves the relative --view path)
ghoztty +split --pane="$GHOZTTY_PANE_ID" --direction=right --split-percent=45 \
  --name=docs --working-directory=/path/to/project --view=docs/design/overview.md

# A standalone viewer window for a webpage
ghoztty +new-window --target=changelog --view=https://example.com/changelog

# Editor + live-rendered markdown preview, side by side (two steps)
ghoztty +new-window --target=notes --command="nvim NOTES.md"
ghoztty +split --target=notes --direction=right --name=preview --view=NOTES.md
```

### Git diff panes (`--view=git-diff:…` / `--view=git-status:`)

A viewer can also render a **git diff**: a changed-files tree with a filter on
the left, red/green syntax-highlighted hunks on the right, and
next/previous-change + unified ⇄ side-by-side controls in the nav bar. This is
how to answer "show me what's changed on this branch" or "show me my git
status" — **do not** dump `git diff` into the terminal for that.

It is the same `--view=` flag, so `--name`, `--pane`, `--split-percent`,
`+reload`, `+close`, and `+list` all work exactly as above.

| `--view=` | Shows | The user says |
|---|---|---|
| `git-status:` | Working tree: staged, unstaged, untracked, in three sections | "my git status", "what have I changed", "uncommitted changes" |
| `git-diff:main...HEAD` | `HEAD` against the **merge base** with `main` | "changes on this branch", "what's on my branch vs main" |
| `git-diff:` | This branch against the repo's mainline, auto-detected | "changes in this branch", no base named |
| `git-diff:<sha>` | That ONE commit's own changes | "what changed in `<sha>`", "show me commit `<sha>`" |
| `git-diff:<a>..<b>` | The literal comparison of two revisions | "diff `<a>` against `<b>`", "what's changed since `<tag>`" (`<tag>..HEAD`) |

Two things to get right:

- **Three dots for "this branch", two for "between these two."** `main...HEAD`
  goes against the merge base, which is what a person means by "what's on my
  branch" — it excludes whatever landed on `main` since they branched.
- **A bare revision means THAT COMMIT**, not "diff against it".
  `git-diff:abc123` answers "what changed in abc123"; a comparison is
  `git-diff:abc123..HEAD`.

**`--working-directory` is the exception to the rule above.** For a plain split
you skip it, but a `git-*:` spec is not a path — it is never path-resolved, and
`--working-directory` is what picks the **repository** the diff is taken in. A
split inherits your cwd, so you can omit it when you are already in the repo;
pass it whenever the diff is about a repo you are not sitting in. A directory in
no git working tree renders an explanatory card rather than an empty pane.

```bash
# "show me changes in the current branch against main" — beside your pane
ghoztty +split --pane="$GHOZTTY_PANE_ID" --direction=right --split-percent=60 \
  --name=diff --view=git-diff:main...HEAD

# "show me files in my git status", for a repo you are NOT cd'd into
ghoztty +split --pane="$GHOZTTY_PANE_ID" --direction=right --name=status \
  --working-directory=/path/to/project --view=git-status:

# one commit, and an arbitrary range
ghoztty +split --name=commit  --view=git-diff:a1b2c3d
ghoztty +split --name=release --view=git-diff:v1.2.0..v1.3.0

ghoztty +reload --target=diff        # re-run after new commits land
```

**The pane's location IS the spec.** `+list --json` reports it as the pane's
`url`, so you can tell whether a diff pane is already open on the right revspec
before opening another; `+reload`/Cmd+R re-runs it; the address bar shows and
accepts it. Since `--name` is idempotent, re-splitting with the same name just
focuses the existing pane — to retarget it at a different revspec, `+close` it
and re-split.

A `git-status:` pane **re-checks the working tree every 2s**, so it needs no
`+reload` after an edit or a `git add`. A commit or range pane is a fixed pair
of trees and is not polled.

### Auto-preview conventions (build → show it beside the work)

When you produce something previewable, **show it in a viewer pane automatically**
— don't wait to be asked, and don't paste raw output into the terminal. Use a
**1/3 ⁄ 2/3 layout**: work panes stacked vertically in the left third, the
preview filling the right two-thirds. The `--split-percent=66` gives the new
right pane 2/3 of the width, leaving 1/3 for your work column.

**Trigger 1 — you author or edit a Markdown design doc / README / spec.**
Open it in a right-hand 2/3 viewer. Markdown viewers **live-reload on save**, so
you set this up once and every edit re-renders automatically (no `+reload`).

```bash
# From your working pane: doc preview fills the right 2/3
ghoztty +split --direction=right --split-percent=66 --name=preview --view=docs/design/spec.md
# ...keep editing docs/design/spec.md — the preview re-renders on each save.
```

**Trigger 2 — you scaffold or edit a static mock HTML app / prototype.**
Point the preview straight at the **file**. An `.html`/`.htm` file opened with
`--view` renders as a **live page** — its own CSS, JS, and images load from the
file's directory — and it **live-reloads on save**, exactly like markdown. No
server, no `+reload`.

```bash
# Preview the mock in the right 2/3 — that's the whole setup
ghoztty +split --direction=right --split-percent=66 --name=preview \
  --view=/path/to/app/index.html
# ...keep editing index.html — the page re-renders on each save.
```

Two things to know:

- Only the **viewed file** is watched. Editing a sibling `style.css` or
  `app.js` does not trigger a reload on its own — `ghoztty +reload
  --target=preview` picks those up (it bypasses the cache).
- The page may read assets **inside its own directory** only. A prototype that
  reaches up out of its folder (`../shared/app.css`) won't resolve — either
  keep assets under the page, or serve the project (Trigger 3).

**Trigger 3 — the app needs a dev server** (a framework app: Vite, Next,
webpack, `npm run dev`). A build step or a router means there is no static file
to point at, so **host it** and view the URL. Run the dev server in a work pane
in the left third, then point the preview at its URL. URL viewers do **not**
auto-reload unless the dev server itself pushes HMR, so `+reload` the preview
after edits.

```bash
# 1. Run the dev server from a work pane stacked below your session (left third)
ghoztty +split --direction=down --name=server \
  --working-directory=/path/to/app --command="npm run dev"

# 2. Preview the running app in the right 2/3
ghoztty +split --direction=right --split-percent=66 --name=preview \
  --view=http://localhost:3000

# 3. After each edit, refresh the preview (URL viewers don't live-reload)
ghoztty +reload --target=preview
```

**Locking the exact 1/3-stacked ⁄ 2/3-preview layout.** When you have several
work panes and want them tiled deterministically in the left third with the
preview pinned to the right 2/3, name every pane and `+rearrange`:

```bash
ghoztty +rearrange --target=<window> --layout='{
  "direction": "horizontal",
  "ratio": 33,
  "left": {
    "direction": "vertical",
    "ratio": 50,
    "left": {"pane": "session"},
    "right": {"pane": "server"}
  },
  "right": {"pane": "preview"}
}'
```

### `ghoztty +reload`

Reload a named **viewer pane** in place — no close/reopen. Website viewers re-fetch the page from origin (bypassing caches); file viewers re-render the file preserving scroll position. Local file viewers already live-reload on save, so this mainly matters for `--view=<url>` panes (e.g. refresh a dev-server preview after a rebuild) — and for an `.html` pane whose sibling CSS/JS changed, which the save-watcher does not see.

```
ghoztty +reload --target=<name>
```

| Flag | Description |
|------|-------------|
| `--target=<name>` | Named window or pane (or a pane id). Required. For a window target, the reload applies to its focused pane. |

- Targeting a terminal pane fails with `... is a terminal pane, nothing to reload` (exit 1) — mirroring how terminal-only commands reject viewer panes.

```bash
# Refresh a local dev-server preview after rebuilding
ghoztty +split --target=dev --name=preview --view=http://localhost:3000
# ... rebuild ...
ghoztty +reload --target=preview
```

### `ghoztty +list`

List all open windows, tabs, and panes. Human-readable tree view by default, `--json` for machine-readable output. Requires a running Ghoztty instance.

```
ghoztty +list [flags]
```

| Flag | Description |
|------|-------------|
| `--json` | Output machine-readable JSON instead of the default tree view. |

**Human-readable output:**

```
Window: "Editor" [target: editor] (focused)
  Tab 1: "Editor" (selected)
    ├─ ~/projects  /Users/david/projects  pid:12345  /dev/ttys003  [name: main-editor]
    ├─ ~/logs  /Users/david/logs  pid:12346  /dev/ttys004  [name: logs]
    └─ ~/src  /Users/david/src  pid:12347  /dev/ttys005  [name: terminal] *
Window: "~/docs"
  Tab 1: "~/docs" (selected)
    ~/docs  /Users/david/docs  pid:12348  /dev/ttys006 *
```

- Single-pane tabs show the terminal inline (no tree characters)
- Multi-pane tabs use `├─`/`└─` tree connectors
- `*` marks the focused terminal in each tab
- `[target: X]` and `[name: X]` shown when set
- Empty state prints `No windows open.`

**JSON output structure (`--json`):**

```json
{
  "success": true,
  "data": {
    "windows": [
      {
        "id": "tab-group-8f436dd60",
        "title": "Editor",
        "target": "editor",
        "focused": true,
        "tabs": [
          {
            "id": "tab-8f5985200",
            "title": "Editor",
            "index": 1,
            "selected": true,
            "splits": {
              "type": "leaf",
              "terminal": {
                "id": "485DECDE-...",
                "title": "~/projects",
                "working_directory": "/Users/david/projects",
                "pid": 12345,
                "tty": "/dev/ttys003",
                "name": "main-editor",
                "focused": true,
                "exit_code": null
              }
            }
          }
        ]
      }
    ]
  }
}
```

**Key JSON fields:**
- **`target`** (on windows): User-provided name from `+new-window --target=X`, or auto-generated (`window-1`, `window-2`, etc.)
- **`name`** (on terminals): User-provided from `+split --name=X`, or auto-generated UUID
- **`splits`**: Recursive tree — `"type":"leaf"` contains a `terminal` object, `"type":"split"` contains `direction` (`horizontal`/`vertical`), `ratio`, `left`, `right`
- **`focused`**: On windows = frontmost window. On terminals = focused pane in its tab.
- **`exit_code`**: `null` if the process is still running, or the exit code (e.g. `0`, `1`) if it has exited. Human-readable output shows `running` or `exited(N)`.

**Side effect:** `+list` auto-registers all discovered windows and panes in the target registry, so names from the output can immediately be used with `+close --target=<name>` or `+split --target=<name>`.

**Don't use `+list` to find yourself.** If you are running inside a pane, `$GHOZTTY_PANE_ID` already names it (see [Know where you are](#know-where-you-are-ghoztty_pane_id)). Reach for `+list` when you need to inspect *other* windows/panes.

### `ghoztty +rename`

Change the display title of a named window. The target registry name is **not** affected.

```
ghoztty +rename --target=<name> --title=<new-title>
```

| Flag | Description |
|------|-------------|
| `--target=<name>` | The named window or pane whose title to change. Required. |
| `--title=<new-title>` | The new display title for the window/tab title bar. Required. |

Returns an error if the target doesn't exist in the registry.

### `ghoztty +rearrange`

Rebuild the split tree of a window to match a declarative JSON layout. **Preserves terminal state** — running processes, scrollback, and focus are kept intact. Panes are reparented in the tree, not destroyed and recreated.

```
ghoztty +rearrange [flags]
```

| Flag | Description |
|------|-------------|
| `--target=<name>` | Window to rearrange. Default: most recently focused window. |
| `--layout=<json>` | JSON layout descriptor (required). See format below. |

**Layout JSON format:**

The layout is a tree with two node types:

- **Leaf**: `{"pane": "<name>"}` — references an existing named pane
- **Split**: `{"direction": "horizontal|vertical", "ratio": <0-100>, "left": <node>, "right": <node>}`

| Field | Description |
|-------|-------------|
| `direction` | `"horizontal"` (left\|right) or `"vertical"` (top\|bottom) |
| `ratio` | Percentage given to the left/top child. Default: 50. Clamped to 10–90. |
| `left`, `right` | Child nodes (each is a leaf or another split) |

**Behavior:**
- All pane names in the layout must exist in the target window's registry.
- A layout may name **viewer panes** (`--view=`) alongside terminals; a viewer keeps its rendered page and scroll position.
- Panes **not** mentioned in the layout are removed from the tree.
- Focus is preserved if the focused pane is in the new layout; otherwise moves to the first leaf.
- Supports undo (Cmd+Z restores the previous layout).

**Example — editor at 40%, three workers stacked vertically:**

```bash
ghoztty +rearrange --target=ide --layout='{
  "direction": "horizontal",
  "ratio": 40,
  "left": {"pane": "editor"},
  "right": {
    "direction": "vertical",
    "ratio": 33,
    "left": {"pane": "worker1"},
    "right": {
      "direction": "vertical",
      "ratio": 50,
      "left": {"pane": "worker2"},
      "right": {"pane": "worker3"}
    }
  }
}'
```

**Example — swap two panes:**

```bash
# Before: editor left, terminal right
# After: terminal left, editor right
ghoztty +rearrange --target=ide --layout='{
  "direction": "horizontal",
  "ratio": 50,
  "left": {"pane": "terminal"},
  "right": {"pane": "editor"}
}'
```

**Example — query then rearrange:**

```bash
# Get current state, then rebuild layout
state=$(ghoztty +list --json)
# Parse pane names from $state, construct new layout, then:
ghoztty +rearrange --target=mywin --layout='...'
```

### `ghoztty +close`

Close a named pane or window. **Closing a nonexistent target succeeds silently** (idempotent).

```
ghoztty +close --target=<name>
```

**This ends the pane's session — it does not hide it.** Session persistence is on by default, so a terminal pane's shell runs under the `ghoztty-agent` and normally survives an app quit, crash, or upgrade. `+close` is not that: it kills the process once the close's undo window expires, exactly like closing the pane in the GUI. Only an app quit preserves a session for re-attach. Viewer panes have no session, and `+close` never prompts for them.

### `ghoztty +read`

Read the last N lines of terminal output from a named pane and print to stdout. Useful for inspecting command output, logs, or checking if a process has finished.

```
ghoztty +read --name=<pane> [--lines=<N>]
```

| Flag | Description |
|------|-------------|
| `--name=<pane>` | Named pane to read from. Required. |
| `--lines=<N>` | Number of lines from the end of scrollback (default: 50). |

### `ghoztty +send-keys`

Send text and key sequences to a named pane's terminal PTY. Enables scripted interaction with running processes.

```
ghoztty +send-keys --target=<name> [flags] <text|key>...
```

> **To submit, end the text with `\n`** — `ghoztty +send-keys --target=t "prompt\n"`.
> (`--enter`, or a separate `Enter` argument, do the same thing. Use one, not
> two — they stack, and two of them submit twice.)

| Flag / Arg | Description |
|------------|-------------|
| `--target=<name>` | Named pane or window to send input to. Required. |
| `--enter` | Press Enter after the text, submitting it. Same as a trailing `\n` or a trailing `Enter` argument. On its own, with no text, it just presses Enter. |
| `--when-idle` | Poll the target's recent output every 500ms until it no longer shows `esc to interrupt` (Claude Code's busy marker) before sending. Sends anyway once the timeout elapses, or if the pane can't be read. |
| `--idle-timeout=<seconds>` | How long `--when-idle` waits before sending regardless. Default 30. |
| `--` | Stop flag parsing. Everything after it is a positional, so this is how you send literal text starting with `--`. Key notation still applies. |
| Positional args | Text strings and key names, written to the PTY in order. |

**Key notation:**
- Control keys: `C-c` (Ctrl-C), `C-d` (Ctrl-D), `C-z` (Ctrl-Z), etc.
- Named keys: `Enter`, `Tab`, `Escape`, `Space`, `Backspace`
- Escape sequences in text: `\n`, `\t`, `\r`, `\\`, `\e`

```bash
ghoztty +send-keys --target=term "hello\tworld\n"   # types, then submits
ghoztty +send-keys --target=term "ls -la" Enter
ghoztty +send-keys --target=agent --when-idle --enter "next task"
ghoztty +send-keys --target=term C-c
ghoztty +send-keys --target=term -- "--not-a-flag" Enter
```

**A trailing newline is a keypress; an interior one is content.** The trailing
run of `\n`/`\r` is peeled off the text and sent as that many Enter presses, so
`"a\nb\n"` pastes two lines and then submits. The peel happens after escape
processing, so `\n` written as the two-character escape and a real newline byte
behave the same. The accepted cost: text ending in a literal newline can't be
pasted without submitting.

**Any unknown `--flag` is a hard error** (exit 1) naming the submit spellings —
`--press-enter` used to be typed into the pane at exit 0, silently. Single-dash
arguments (`-la`, `-p`) stay ordinary text.

**Why the boundary matters.** Argument boundaries survive to the write:
adjacent args of the same kind merge into a run, each **text** run is sent as a
bracketed paste, and each **key** run is sent bare outside the frame. That is
what makes a message actually submit. Flattened into one burst ending in `\r`,
a TUI reads that `\r` as a newline *inside* pasted text — correctly, since that
is what a real multi-line paste looks like — and the message sits unsent in the
composer. Framing only applies when the program has enabled bracketed paste
(every modern TUI and interactive shell does), so a plain `cat` or a script's
`read` still gets the bytes verbatim.

### `ghoztty +set-state`

Set the activity state of a named window or pane. State is aggregated across all panes in a window (priority: `needs_input` > `busy` > `idle`) and shown as a title suffix and custom `AXWindowActivityState` accessibility attribute. Transition to `needs_input` triggers `requestUserAttention`.

```
ghoztty +set-state --target=<name> --state=<idle|busy|needs_input>
```

| Flag | Description |
|------|-------------|
| `--target=<name>` | Named window or pane. Required. |
| `--state=<state>` | Activity state: `idle`, `busy`, or `needs_input`. Required. |

Processes can also set state via OSC escape sequence: `\033]7777;<state>\007`

```bash
ghoztty +set-state --target=dev --state=busy
ghoztty +set-state --target=dev --state=needs_input
ghoztty +set-state --target=dev --state=idle
```

**Don't set the state of your own pane.** Ghoztty's installed hooks already own
it, under the same `needs_input` > `busy` > `idle` ordering — including keeping
the pane `busy` while background subagents outlive the main loop. A manual call
either duplicates what the hooks just did or fights them. Use `+set-state` for
*other* panes: a build, a dev server, a long-running job you launched.

The hooks track each live subagent with a marker file under
`/tmp/ghoztty-<runtime>-agents-<session_id>/`, so the pane stays `busy` until
the last one finishes rather than going `idle` the moment the main loop goes
quiet. Markers are recovered two ways when a kill skips `SubagentStop`: the
owning agent's pid is baked into each filename (so a dead session's markers are
dropped exactly and instantly), and an agent that emits no tool call for longer
than `GHOZTTY_AGENT_STALE_MIN` minutes (default `30`) is presumed dead. That
window must exceed the longest single *tool call*, not the longest agent — a
40-minute build emits nothing between its start and its end.

This is wired for **Claude Code**. Copilot CLI gets the banner hooks but not yet
the full state machine (see the note in `CopilotHookSpec`), so a Copilot pane
still reports `idle` at the end of a turn even with background work in flight.

### `ghoztty +set-banner`

Set or clear a **sticky banner** rendered above a pane's terminal content. The banner is a native overlay — it persists across scrolling, screen clears, and content updates until you change or clear it. Ideal for pinning status, progress, or links (e.g. a PR link) above the pane you're working in.

```
ghoztty +set-banner --target=<name> [--clear] [text...]
```

| Flag / Arg | Description |
|------------|-------------|
| `--target=<name>` | Named pane or window. Required. For a window target, the banner is applied to its focused pane (banners are per-pane). |
| `--clear` | Remove the banner. Empty text does the same. |
| Positional args | Banner text (multiple args are joined with spaces). |

**Formatting** (markdown subset):

| Syntax | Result |
|--------|--------|
| `# text` … `###### text` | **heading** — larger than body text, on its own line. A banner's title line needs one; without a leading `#` it renders at body size and the banner reads as a wall of same-sized text. Requires the space after the `#`. |
| `**text**` | bold |
| `*text*` or `_text_` | italic |
| `__text__` | underline (differs from CommonMark, where `__` is bold) |
| `` `text` `` | monospace code |
| `[label](https://url)` | clickable link — the URL must include a scheme |
| `\*`, `\[`, `\\`, `\|`, … | backslash escapes the next character |
| `\n` | line break — banners can span multiple lines (display capped at 10) |

Styles nest (`**bold with a [link](https://…)**`). Unterminated delimiters render literally.

**Tables** (standard markdown pipe syntax): a `| a | b |` header line immediately followed by a `|---|---|` separator with the same column count, then `| 1 | 2 |` body rows, render as an aligned grid with a bold header. Separator cells accept `:` alignment markers (`:---` left, `:---:` center, `---:` right). Cells support the full inline subset; `\|` puts a literal pipe inside a cell. Ragged rows are padded/truncated to the header width. The separator row doesn't render, but every other table row counts toward the 10-line cap.

```bash
ghoztty +set-banner --target=dev "**PR #123** — _3 files_, +120/−45 — [view](https://github.com/org/repo/pull/123)"
# A titled banner: the title is a heading line, so it stands out from the body.
ghoztty +set-banner --target=dev "# Deploy blocked\nstaging smoke tests are red — [run 4821](https://ci.example.com/4821)"
ghoztty +set-banner --target=dev "## Build status\n| Job | State |\n|:---|---:|\n| lint | ok |\n| tests | **3 failed** |"
ghoztty +set-banner --target=dev --clear
```

Multi-line banners are **collapsible** in the UI: a chevron button (top-right) or a click anywhere on the banner background toggles between the full banner (default) and a collapsed single-line preview with a bottom fade. This is a display-only, per-pane UI state — it doesn't change the stored banner text, and there's no CLI flag for it.

Processes inside the pane can also set the banner without IPC via OSC escape sequence: `\033]7778;<text>\007` (empty text clears; note the OSC parser drops raw newlines, so OSC banners are single-line — use the CLI for tables/multi-line). Interactive users can press Cmd+R ("Set Pane Banner…", also in the command palette) for a multi-line editor (Return = newline, Cmd+Return = save).

### `ghoztty +sessions`

List the persistent terminal sessions owned by the local `ghoztty-agent` — the daemon that keeps PTYs alive across app restarts.

```
ghoztty +sessions [--json]
```

Unlike every other IPC command, this dials the **agent directly** rather than the app's socket, so it works even when the Ghoztty app is not running (as long as the agent is). Requires `session-persistence = on`, which is the default.

Each row reports the session id, liveness (`alive`, or `dead(<code>)` for a tombstoned session), whether a viewer is `attached`, the activity state, the child pid, whether it is `pinned` against the agent's idle reaper, the working directory, and the command.

`--json` emits a **bare array** of rows — not the `{"success":…,"data":…}` envelope the window commands use — with every field present including nulls: `id`, `alive`, `exit_code`, `attached`, `activity`, `pid`, `cwd`, `argv`, `title`, `created_at`, `last_activity`, `pinned`.

```bash
ghoztty +sessions
ghoztty +sessions --json | jq -r '.[] | select(.alive) | "\(.id)\t\(.activity)\t\(.argv)"'
```

### `ghoztty +new-remote-window`

Open a terminal window whose shell runs on a **remote machine**, via a `ghoztty-agent` reached over TCP. Same flow as the Cmd-Shift-N "New Remote Window" menu action.

```
ghoztty +new-remote-window --host=<host> --port=<port> [flags]
```

| Flag | Description |
|------|-------------|
| `--host=<host>` | Agent host, DNS name or literal IP. Required. |
| `--port=<port>` | Agent TCP port. Required. |
| `--working-directory=<path>` | Working directory **on the remote machine**. Overrides that machine's per-host default. |
| `--shell=<path>` | Shell **on the remote machine** (e.g. `wsl.exe`, `powershell.exe`, `/bin/zsh`). Overrides the per-host default. |
| `--command=<cmd>` | Command to run instead of an interactive shell, through the resolved shell's native convention (POSIX `-lic`, cmd `/c`, powershell `-Command`, wsl `--`). |

```bash
ghoztty +new-remote-window --host=127.0.0.1 --port=7777
ghoztty +new-remote-window --host=winbox --port=7777 --shell=wsl.exe --working-directory='C:\dev'
```

Your local shell and cwd are **not** forwarded — they wouldn't exist on a different OS such as a Windows ConPTY agent. The remote machine's own defaults apply unless a per-host default (machine chooser → row `⋯` → "Host Settings…") or an explicit flag says otherwise. A remote pane's IPC still belongs to the **local** app, so `+split`, `+close`, and `+set-banner` target it like any other pane.

## Focus links: the `ghoztty://` URL scheme

A **link** can bring a Ghoztty window or pane to the front. This is the piece
that makes a generated document useful: a worktree dashboard, a status report,
a build summary can each carry a "jump to that terminal" link that works from a
browser, from a rendered doc in a viewer pane, or from a pane banner.

```
ghoztty://focus/<target>
```

That is the **only** form and `focus` is the **only** verb. `<target>` is
percent-decoded and handed to the same resolver `--target` uses, so it accepts
everything a `--target` accepts:

| `<target>` | Example |
|---|---|
| a registered window name | `ghoztty://focus/dev` |
| an auto-assigned window name | `ghoztty://focus/window-3` |
| a registered pane name | `ghoztty://focus/logs` |
| a pane id (`$GHOZTTY_PANE_ID`, case-insensitive) | `ghoztty://focus/8b1f1a2c-3d4e-4f50-9a6b-7c8d9e0f1a2b` |

Percent-encode anything awkward: `ghoztty://focus/my%20window`. Everything
after the verb is ONE target, so a name containing `/` survives either way
(`focus/feat%2Flogin` and `focus/feat/login` both mean `feat/login`).

**Nothing else is possible through a link — by design.** There is no
`ghoztty://new-window`, no `ghoztty://send-keys`, no way to run a command. Any
web page the user visits can fire a URL scheme with no prompt and no
same-origin check, so anything that could spawn a shell or type into a pane
would be remote code execution behind an `<a href>`. Raising a window that
already exists is the one verb whose worst case is a nuisance. If you find
yourself wanting a second verb, use the CLI — it is reachable only by code
already running as the user — and do not propose widening the scheme.

**A link that can't be followed says so.** If the target isn't open — it was
closed, it was never named, or Ghoztty was only just launched by this very
click — Ghoztty shows a warning naming the target ("Can't focus "dev""), and a
`ghoztty://` link it doesn't understand gets a warning naming the URL. What it
never does is act on a failure: no window is created and no "closest" window is
focused as a consolation. A burst of links produces one dialog, not one each.

So a stale link in a generated document is visible rather than mysterious —
but it is still a bad link. Regenerate dashboards rather than letting them rot,
and prefer targets that will still exist (below).

### Emitting links from a generated document

Write ordinary anchors:

```html
<a href="ghoztty://focus/ghoztty-url-protocol">ghoztty-url-protocol</a>
<a href="ghoztty://focus/8b1f1a2c-3d4e-4f50-9a6b-7c8d9e0f1a2b">that pane</a>
```

**Pick the target so the link survives.** This is the part that decides whether
a dashboard still works tomorrow:

| Situation | Target to write | Why |
|---|---|---|
| You are *creating* the window (e.g. one per worktree) | the `--target=` name you gave it | You chose it, so you can regenerate the same link without asking the app anything. |
| The window already exists and you are just describing it | the pane `id` from `+list --json` | Stable for the pane's whole life, including across app relaunch and session restore. |
| Linking to the pane you are running in | `$GHOZTTY_PANE_ID` | Already in your environment — no `+list` round trip. |

Prefer a **name you control** over an auto-assigned `window-N`: the auto names
are handed out per app run, so `window-3` can point at a different window after
a relaunch. Name the window when you open it and the link is stable by
construction:

```bash
# one window per worktree, named after it — the link is then predictable
for wt in ~/git/*/; do
  name="$(basename "$wt")"
  ghoztty +new-window --target="$name" --working-directory="$wt"
  echo "<li><a href=\"ghoztty://focus/$name\">$name</a></li>" >> dashboard.html
done
```

To build a dashboard from what is *already* open, walk `+list --json`. `splits`
is a recursive tree, so use `..` to pick out the `terminal` objects:

```bash
ghoztty +list --json | jq -r '
  .data.windows[] | .tabs[] | [.. | .terminal? | select(.)] | .[] |
  "<li><a href=\"ghoztty://focus/\(.id)\">\(.title)</a></li>"'
```

Markdown works too, in a viewer pane or anywhere else that renders links:

```markdown
| Worktree | Terminal |
|---|---|
| `ghoztty` | [open](ghoztty://focus/ghoztty) |
```

And in a banner (`[label](url)` needs the scheme, which this has):

```bash
ghoztty +set-banner --target=dev "Tests failing in [the build pane](ghoztty://focus/build)"
```

Clicking a `ghoztty://` link **inside** Ghoztty — a viewer pane, a pane banner
— is handled in process rather than routed back through macOS, so it always
means "this app". A banner link ignores the usual Cmd / Cmd-Shift modifiers
(there is no content to put in a pane or a window) and its right-click menu
offers just **Focus in Ghoztty** and **Copy Link**.

> **Debug builds use `ghoztty-debug://`.** The two builds register different
> schemes so LaunchServices never has to choose between them. Both builds
> *accept* both spellings for links clicked inside Ghoztty, so a document that
> hardcodes `ghoztty://` still works when a debug build renders it — but a link
> clicked in a **browser** reaches only the build that registered that exact
> scheme. Write `ghoztty://` unless you are specifically driving a debug build.

## Naming System

- `+new-window --target=<name>` registers a **window**
- `+split --name=<name>` registers a **pane**
- `+split --target` and `+close --target` can reference **either** kind
- Names are unique across all windows and panes

## Background Colors

- `--color=#1a1a2e` sets a specific hex background color on a window or pane.
- `--color=random` generates a random dark-tinted background (charcoal with subtle hue).
- When splitting a pane (ctrl-d or `+split`), the child pane automatically inherits a slightly lighter version of the parent's background for visual depth.
- Right-click a pane → "Background Color..." opens a live color picker.

## Key Behaviors

1. **Idempotency**: Re-running a command with the same `--target` or `--name` focuses the existing window/pane instead of creating a duplicate. This makes commands safe to retry.
2. **Auto-launch**: `+new-window` launches Ghoztty.app if no instance is running. `+split` and `+close` require a running instance.
3. **Atomic splits**: Use `+new-window --split=<dir>` to create a window with a split in one command, avoiding timing issues from sequential `+new-window` then `+split`.
4. **Shell initialization**: `--command` auto-wraps in the user's login shell with profile loaded, so aliases, PATH, nvm, etc. work out of the box. Use `--shell` to override which shell is used.

## Patterns

### Open a named window with a command

```bash
ghoztty +new-window --target=myapp --working-directory=/path/to/project --command="nvim ."
```

### Two-pane layout (editor + shell)

```bash
ghoztty +new-window \
  --target=dev \
  --working-directory=/path/to/project \
  --command="nvim ." \
  --split=down \
  --split-command="exec zsh -l"
```

### Three-pane layout (built sequentially)

```bash
ghoztty +new-window --target=ide --command="nvim ."
ghoztty +split --target=ide --name=term --direction=down --command=zsh
ghoztty +split --target=ide --name=logs --direction=right --command="tail -f app.log"
```

### Launch Claude Code in a named window

```bash
wt_path="$(cd /path/to/project && pwd)"
ghoztty +new-window \
  --target=task-name \
  --working-directory="${wt_path}" \
  --title="project: task-name" \
  --command="cl \"your prompt here\""
```

### Rename a window's title

```bash
ghoztty +rename --target=dev --title="Project: my-feature"
```

### Discover what's running, then target it

```bash
# Get JSON state
state=$(ghoztty +list --json)
# Parse with jq to find a specific pane, then close it
target=$(echo "$state" | jq -r '.data.windows[0].target')
ghoztty +close --target="$target"
```

### Rearrange: prioritize one pane, tile the rest

```bash
# Create 4 panes
ghoztty +new-window --target=work --command=zsh
ghoztty +split --target=work --name=main --direction=right --command=zsh
ghoztty +split --target=work --name=aux1 --direction=down --pane=main --command=zsh
ghoztty +split --target=work --name=aux2 --direction=right --pane=aux1 --command=zsh

# Rearrange: main gets 70% left, aux panes tile 2x1 on right
ghoztty +rearrange --target=work --layout='{
  "direction": "horizontal",
  "ratio": 70,
  "left": {"pane": "main"},
  "right": {
    "direction": "vertical",
    "ratio": 50,
    "left": {"pane": "aux1"},
    "right": {"pane": "aux2"}
  }
}'
```

### Read output from a pane

```bash
# Check what a running process has printed
ghoztty +read --name=term --lines=10

# Capture output for processing
output=$(ghoztty +read --name=build --lines=100)
echo "$output" | grep "error"
```

### Send commands to a running pane

**To submit, end the text with `\n`.** (`--enter`, or a separate `Enter`
argument, do the same thing — use one, not two.)

```bash
# Run a command in an existing pane — the trailing \n is what submits it
ghoztty +send-keys --target=term "hello\tworld\n"
ghoztty +send-keys --target=term "npm test\n"

# The other two spellings of the same thing
ghoztty +send-keys --target=term "npm test" Enter
ghoztty +send-keys --target=term --enter "npm test"

# Interrupt a running process
ghoztty +send-keys --target=term C-c

# Send EOF to close a shell
ghoztty +send-keys --target=term C-d

# Send literal text that starts with `--`
ghoztty +send-keys --target=term -- "--not-a-flag" Enter
```

### Track activity state

```bash
# Mark a pane as busy while working
ghoztty +set-state --target=dev --state=busy
# Signal that user input is needed
ghoztty +set-state --target=dev --state=needs_input
# Mark idle when done
ghoztty +set-state --target=dev --state=idle
```

### Pin a live status banner above your working pane

Post a PR link plus live stats above the pane you're working in, and keep it updated as work progresses. The banner is sticky — it stays put while the terminal scrolls underneath.

```bash
# When the PR is opened
ghoztty +set-banner --target=dev "**PR #123** — _draft_ — [view](https://github.com/org/repo/pull/123)"

# Update as work progresses (idempotent — just set it again)
ghoztty +set-banner --target=dev "**PR #123** — _3 files_, +120/−45 — CI __running__ — [view](https://github.com/org/repo/pull/123)"
ghoztty +set-banner --target=dev "**PR #123** — CI **green** — ready for review — [view](https://github.com/org/repo/pull/123)"

# Clear when done
ghoztty +set-banner --target=dev --clear
```

### Review your own changes beside the work

Open the branch diff next to the pane you're working in, then re-run it as commits land. A `git-status:` pane is the better choice while you're still editing — it re-checks the working tree every 2s on its own.

```bash
# What's on this branch, against main
ghoztty +split --pane="$GHOZTTY_PANE_ID" --direction=right --split-percent=60 \
  --name=diff --view=git-diff:main...HEAD

# ... commit some work ...
ghoztty +reload --target=diff

# Or watch the working tree live instead — no reload needed
ghoztty +split --pane="$GHOZTTY_PANE_ID" --direction=right --name=status \
  --view=git-status:
```

### Pass environment variables

```bash
ghoztty +new-window \
  --target=api \
  --env=API_KEY=sk-123 \
  --env=DEBUG=true \
  --command="node server.js"
```

### Clean teardown (reverse order)

```bash
ghoztty +close --target=logs
ghoztty +close --target=term
ghoztty +close --target=ide
```

Closing a nonexistent target is a no-op, so teardown scripts are safe even if some panes were already closed.

## Common Mistakes to Avoid

- **Don't use `+split` before `+new-window`** — there must be a running instance and a target window.
- **Don't manually wrap with `zsh -lic`** — `--command` auto-wraps in the user's login shell. Use `--shell` only if you need a different shell.
- **Don't use sequential `+new-window` then `+split`** for the initial layout — use `--split` and `--split-command` on `+new-window` for atomicity.
- **Don't assume `--working-directory` propagates to `--split-command`** — the split pane must `cd` explicitly if it needs the same directory.
- **Don't `less`/`cat`/`open` a file to show it in a pane** — that dumps raw text (unrendered markdown) or opens an external app. Use `+split --view=<path>` for a rendered, live-reloading viewer pane.
- **Don't leave a design doc or mock HTML app preview-less** — when you author Markdown or scaffold an HTML prototype, auto-open it in a right-hand 2/3 viewer (see *Auto-preview conventions*). Markdown and static `.html` files both render live and live-reload on save, so `--view` the file directly. Only a framework app that needs a dev server gets the serve-then-`--view`-the-URL treatment (and a `+reload` after edits).
- **Don't dump `git diff` into the terminal to show changes** — use `+split --view=git-diff:…` for a navigable diff with a file tree. Reach for the raw command only when you need the text yourself.
- **Don't read `git-diff:<sha>` as "compare against `<sha>`"** — a bare revision shows that commit's own changes. A comparison is `git-diff:<sha>..HEAD`.
- **Don't `+read`, `+send-keys`, `+set-state`, or `+set-banner` a viewer pane** — all four exit 1. The pane is for the user to look at; if you need a diff as text, run `git diff` yourself.
- **Don't `+close` a pane you only meant to hide** — it ends that pane's persistent session and the process does not come back.
- **Don't send `+send-keys` text with no way to submit it** — a bare `"message"` sits in a TUI composer unsent. End it with `\n` (`"message\n"`), or pass `--enter`, or a separate `Enter` argument. Pick one: they stack, and two of them submit twice.
