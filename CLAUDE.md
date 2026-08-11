# Ghoztty

A fork of [Ghostty](https://github.com/ghostty-org/ghostty) that adds CLI-driven window management for AI agents and automation.

Ghoztty ships on **macOS and Windows**, and the two are kept symmetric. Read
the next section before you add anything.

## Platform symmetry is a standing rule

**Every new feature must land in BOTH the macOS and the Windows build.** (User
directive, 2026-07-13.) A feature that exists on one platform and not the other
is an unfinished feature, not a platform-specific one — the divergence is the
defect, the same way an off-scale spacing value is a defect in the win32 design
system even when it looks fine in isolation.

What that means in practice:

- **Translate the feature, not the implementation.** Where a concept has no
  native counterpart, build the Windows-native equivalent rather than skipping
  it or emulating the Mac mechanism: AF_UNIX socket → owner-only-DACL **named
  pipe**, LaunchAgent → **HKCU Run** entry, Keychain → **DPAPI** store,
  `+list --tty` → `+list --pid`, `-lic` shell invocation → per-flavor
  (`pwsh -NoExit -Command`, `cmd /K`, `wsl --`). Every one of those pairs is
  documented in the sections below; follow the pattern instead of inventing a
  new one.
- **The CLI surface is identical on both platforms.** A verb, flag, or default
  that exists on one CLI and not the other is the divergence this project
  explicitly does not ship — Windows briefly had `+relay-login`/`+relay-logout`
  with no Mac analog and they were **removed** (T141), not kept. If a capability
  needs a GUI affordance on one platform, give it that affordance on both.
- **Land both, or file the other half.** If you genuinely cannot implement the
  second platform in the same change (no box to validate on, a dependency that
  is not ready), the change is not done until a task exists for the other
  seat — on Windows that is
  `powershell -NoProfile -File scripts\parity-tasks.ps1 new -Title "…"`, with
  `seat: mac` for work that only the Mac seat can validate. Never leave the
  gap undocumented.
- **Both seats work the same branch**, so pull before starting and push at
  every task boundary.

Windows parity work is tracked in `docs/design/windows-parity-tasks/` (one file
per task) with `docs/design/windows-parity-tasks.md` as the narrative index; the
Windows session protocol lives in `go.md`.

## CLI Window Management

IPC commands communicate with a running Ghoztty instance over a local IPC
endpoint (a Unix domain socket on macOS, a named pipe on Windows — see
Architecture). All commands are idempotent — named targets that already exist
are focused instead of recreated. Since T135, that focus is no longer silent
about what it dropped: `+new-window` against an existing target replies
`outcome: "focused"` (vs `"created"`) and, when create-only flags
(`--command`, an explicit `--working-directory`, `--view`, …) were passed, a
`note` naming them — which the CLI prints to stderr while keeping exit 0. The
CLI's auto-inserted cwd is marked `--cwd-implicit` on the wire so a bare
re-focus stays quiet. (win32 server done; Mac server half is T523 — the
shared CLI already prints any note it receives.) The verbs, flags, and semantics below are the
same on both platforms.

### `ghoztty +new-window`

Create or focus a terminal window. Auto-launches Ghoztty if no instance is running.

```
ghoztty +new-window --target=<name> --working-directory=<path> --command=<cmd> --view=<path-or-url-or-diff> --shell=<path> --title=<title> --split=right|down|left|up --split-command=<cmd> --no-activate -e <args...>
```

- `--shell`: Shell to use for `--command`/`--split-command`, invoked with `-lic` so profile is loaded. Falls back to config `command-shell`, then `$SHELL`, then `/bin/zsh`.
  On Windows the fallback is `command-shell` then `cmd.exe`, and the invocation is per-flavor (the shell stays alive after the command): `pwsh`/`powershell` → `-NoExit -Command`, `cmd` → `/K`, `wsl` → `-e /bin/sh -lic "<cmd>; exec \"$SHELL\" -li"` in the default distro, `nu` → `-e`, anything else (e.g. git-bash) → `-lic "<cmd>; exec shell -li"`.
  **The keep-alive is argv-shaped here, and that is why the agent-backed path needs its own wiring** (T468). With `session-persistence` on — the default — every local pane's shell is spawned by `ghoztty-agent`, which synthesizes its own `<shell> /c <cmd>` and exits the moment the command returns. POSIX hides this because its keep-alive lives INSIDE the command string (`<cmd>; exec <shell> -li`), which rides `OPEN.command` untouched; `cmd /K` and `-NoExit -Command` cannot. So a local-agent pane sends the wrapped invocation as `OPEN.argv` (the agent's exec-verbatim seam) while `OPEN.command` still carries the raw command as the session's label. Only for the LOCAL agent — a cross-machine agent is a different machine and applies its own convention. `-e` is never wrapped, on either path: it means "exec exactly this". Acceptance: `test/win32/ipc-command-keepalive.ps1`.
  **`wsl` is the row that takes an ARGV rather than a command string, which is why it looks different** (T656). `wsl -- <cmd>` hands the rest of the *Windows* command line to the distro's default shell **as written**, so the quoting Windows applies to a spaced argument survived into the distro and bash looked for a program literally named `"echo hi"` — `command not found` naming the whole line, on both paths, with the pane dying with it. `-e` execs an argv instead, so the command reaches the inner shell as one properly-unquoted argument. `/bin/sh` because it is the one interpreter every distro is guaranteed to have (dash on Ubuntu, and dash accepts `-lic`); `exec "$SHELL" -li` because the pane must be left in the user's REAL login shell, exactly as the posix row leaves it — `$SHELL` comes from the distro's passwd entry, with `/bin/sh` as the fallback. Acceptance: arm I of `test/win32/ipc-command-keepalive.ps1`.
- `--view`: Open a window whose single pane is a **viewer** (see Viewer Panes below) instead of a terminal — a file, a website, or a **git diff** (`git-status:` / `git-diff:<revspec>`, see Git diff panes). Mutually exclusive with `--command`/`-e`.
- `--title`: Set the **window title**. A window title pins the titlebar — it wins over any tab or pane title and survives pane focus changes and shell OSC title updates — until cleared. The titlebar falls back to window title → active tab's title → active pane's title. Interactive equivalents: Cmd+Shift+R ("Change Window Title", also sets/clears it), plus separate "Change Tab Title" and "Change Pane Title" commands in the menu and command palette. `ghoztty +rename --target=<name> --title=<title>` changes it later (`--title=""` clears the pin).

### `ghoztty +split`

Create a split pane in a running window.

```
ghoztty +split --direction=right|down|left|up --target=<name> --name=<name> --command=<cmd> --view=<path-or-url-or-diff> --shell=<path> --working-directory=<path> -e <args...>
```

- `--direction`: Split direction. Default: `right`.
- `--target`: Named window to split in (default: most recently focused).
- `--name`: Register the new pane with a name for later targeting.
- `--view`: Open a **viewer** pane (see Viewer Panes below) instead of a terminal — a file, a website, or a **git diff** (`git-status:` / `git-diff:<revspec>`, see Git diff panes). Mutually exclusive with `--command`/`-e`. Works with `--pane` targeting, including splitting off an existing viewer pane.

On Windows, `ghoztty +list --pid=<pid>` prints just the name of the pane
whose shell is an ancestor of the given process id — the tty-less way for a
process inside a pane to discover its own pane (e.g. `ghoztty +list
--pid=$(cat /proc/$$/winpid)` from git-bash — `$$`, not `self`: the pid must
still be alive when the server walks ancestry, and `/proc/self` read via
`cat` names the already-exited `cat` — or `--pid=$PID` from PowerShell).

### `ghoztty +close`

Close a named pane or window. Closing a nonexistent target succeeds silently.
For a session-persistence pane this ENDS the agent session (the process is
killed once the close's undo window expires) — same as closing the pane in the
GUI. Only an app quit keeps sessions alive for re-attach.

```
ghoztty +close --target=<name>
```

### `ghoztty +rearrange`

Replace a window's active tab's whole split layout with one given as JSON —
every leaf names an already-existing pane, so this MOVES panes rather than
creating them.

```
ghoztty +rearrange --target=<name> --layout='{"direction":"horizontal","ratio":30,"left":{"pane":"a"},"right":{"pane":"b"}}'
```

**A pane the new layout omits is CLOSED, session and all** (T128, win32; the
Mac half is T683). Dropping a pane out of the layout destroys it, so it ends
its agent session exactly as `+close` on that pane would — it used to DETACH
instead, leaving the child running under the agent forever, pinned against the
idle reaper with no pane anywhere that could reach it. A pane the new layout
still names is only being moved and is never touched: the marking runs through
`agent_recovery.closesDepartingLeaf` → `sessionSpared`, so a session the new
tree still references is never ended (main's `e65cfa4d5` invariant, which is
what keeps recovery-style tree swaps safe). Acceptance:
`test/win32/rearrange-session-drop.ps1`.

### `ghoztty +read`

Read the last N lines of terminal output from a named pane and print to stdout.

```
ghoztty +read --name=<pane> --lines=<N>
```

- `--name`: Named pane to read from (required).
- `--lines`: Number of lines from the end of scrollback (default: 50).

**An empty pane is an answer, not an error** (T181, win32; the Mac half is
T481). A terminal pane that has printed nothing yet exits 0 with empty output,
the way `tail` of an empty file does — that is the state of *every* pane for
the first fraction of a second of its life (the window is registered, and
`+list --json` already reports its pane id and its child's pid, before the
shell has painted a prompt) and the permanent state of a pane running something
silent. It used to answer `failed to read terminal content from '<pane>'`,
which a caller could not tell apart from a missing or wedged pane — so a caller
that read once recorded "the pane produced no output" as a verdict. Every
remaining failure names a distinct state: `not found in registry`, `is no
longer alive`, `is a viewer pane, not a terminal`, `is not readable: its
terminal never finished starting up`, and `failed to read terminal content`
(now only a genuine internal failure). `+send-keys` splits the same two
liveness states apart. The "last N lines" rule itself lives in
`src/apprt/ipc/read_tail.zig` so both platforms describe it identically.

**A pane on the alternate screen reads back the visible screen** (T193,
win32; the Mac half rides with T481). A TUI pane — htop, a pager, a
full-screen installer — answers `+read` with what a user looking at the pane
sees, because the dump reads the *active* screen; the alternate screen has no
scrollback by design, so the visible frame is the whole truthful answer. When
the program leaves the alt screen (`ESC[?1049l`), the primary screen's
scrollback is readable again. Regression arm: G in
`test/win32/ipc-read-race.ps1`.

### `ghoztty +list`

List open windows, tabs, and panes (human-readable tree, or `--json`). Listing auto-registers every pane it discovers, so returned names are immediately usable as targets.

```
ghoztty +list [--json] [--tty=<tty>]
```

- `--tty`: Print only the registered name of the pane whose terminal matches the given tty (`ttys014` or `/dev/ttys014`; raw padded `ps -o tty=` output is accepted), then exit. Exits 1 if no match. Lets a process find its own pane: `ghoztty +list --tty="$(ps -o tty= -p $PPID)"`.

`--json` windows carry a **`chrome`** object reporting where the tab strip's
clickable regions ARE (T231) — `{"dpi": 120, "tab_strip": {"band", "tabs",
"new_tab", "menu"}}`, every rect in the window's CLIENT coordinates, physical
pixels, right/bottom exclusive. They are not a fresh layout pass: they are the
rects the window's own hit tests read, so what is reported and what a click
reaches cannot drift. **`null` means there is nothing there to hit** — the
`menu` on a window whose caption hosts the menu (T260), a tab the strip could
not fit, every region of a strip that has not painted yet — and `tab_strip:
null` means the window shows no strip at all, which is a different answer from
the whole `chrome` key being absent (a server that cannot say). `band` is where
strip content may sit: inside both insets, the buttons' own vertical band, and
on a merged caption row its right edge is the seam rather than the window edge.

This exists because the alternative is a second implementation of
`tab_strip_layout` in whatever language the caller is written in, and that
cannot be type-checked against the first: the win32 acceptance harness kept one
and it rotted twice — a fixed "46px left of the right edge" that landed inside
the menu button at 125% DPI, then a modelled tab width that stopped matching
when T235 sized tabs to their titles. Both produced failing assertions against
a completely healthy product. Consumers ask
`Get-TestStripRegions` (`test/win32/lib/ChromeGeometry.ps1`); a pixel scan is
now only for asserting that something is PAINTED, never for finding a click
target. (win32 server since T231; the Mac server half is T735.)

`--json` terminal panes carry a `session_id` field when the pane is bound to a
session-persistence agent session — the join key against `+sessions --json`,
so a script can answer "which pane is this session open in" (and vice versa)
without app logs. Absent for plain non-persistent panes and viewers. (win32
server since T332; the Mac server half is T553.)

### `ghoztty +sessions`

List the persistent terminal sessions owned by the local `ghoztty-agent` (the daemon that keeps session-persistence PTYs alive across app restarts). Unlike the other IPC commands, this dials the agent **directly** over its 0600 unix socket (`~/.config/ghoztty/local-agent[-debug]/agent.sock`) — NOT the app's IPC socket — so it works even when the Ghoztty app is not running (as long as the agent is). Requires `session-persistence = on`. On Windows the agent's local transport is instead an owner-only-DACL **named pipe** (`\\.\pipe\ghoztty-agent[-debug]-<user>`); the endpoint is discovered from the agent's `pipe` field in `%LOCALAPPDATA%\ghoztty\local-agent[-debug]\port.json`, and the same-uid guarantee comes from the pipe DACL rather than a peercred check.

```
ghoztty +sessions [--json] [--agent]
```

Each row reports the session id, liveness (`alive`; `dead(relaunchable)` for a tombstone that RELAUNCH can still revive — e.g. after a reboot or agent restart; or `dead(<code>)` for a genuinely exited session), whether a viewer is currently `attached`, the activity state (`idle`/`busy`/`needs_input`), the child pid, `pinned` when the session is protected from the agent's idle-TTL reaper (persistent local panes are pinned so they survive the viewer quitting indefinitely; cross-machine sessions are not), the working directory (when known), and the command. `--json` emits one object per session for scripts and agents.

```bash
ghoztty +sessions
ghoztty +sessions --json
```

**`--agent` answers which BUILD is running** (T662), instead of listing
sessions. The agent outlives the app on purpose, so it is routinely a different
build than everything around it — and until this existed that comparison
happened only in an app log line, on a box where the app had already been
restarted past the interesting moment:

```
running:  20260719-574fe0805  (pid 24228)
bundled:  20260730-e69d41755
status:   stale - 11 days behind, 4 live sessions
next:     Ghoztty restarts it onto the bundled build when no sessions are open, or when you confirm the restart it offers.
```

`status` is a machine token — `current`, `stale`, `newer`, `unknown` (the
bundled binary could not be read), `not_running` — and `--json` emits it with
`running`, `bundled`, `days_behind`, `live_sessions`, `sessions` and
`agent_pid`. **No agent running is an answer, not an error**: it exits 0 with
`not_running`, because the next persistent session simply starts the bundled
build. `days_behind` is calendar days between the two `YYYYMMDD` stamps, and is
absent rather than 0 or negative whenever there is no honest number to give (a
`dev` stamp, a pre-versioned agent, a same-day rebuild, a newer running agent).
Staleness itself is defined in exactly one place for both readers —
`src/remote/agent_build.zig`, shared by this CLI and the win32 upgrade policy
(`agent_upgrade.zig`) — so the number a user reads and the decision the app acts
on cannot disagree. Acceptance: `test/win32/sessions-agent-build.ps1`.

**How a long-lived box adopts a newer agent** (the state this command exists to
make visible): the running agent is restarted onto the bundled build when the
app's check finds it stale AND there are zero live sessions, or when the user
accepts the mandatory confirmation. Both can go unreached indefinitely on a box
whose panes never all close — the morning app-only refresh (T525) deliberately
never swaps `ghoztty-agent.exe` and defers that confirmation, and the check
re-runs only at launch and when the last persistent window closes. So today the
documented path is an **attended full delivery** (`scripts/launch-upgrade.ps1`
without `-AppOnly`, which does prompt), and `+sessions --agent` is how you know
whether one is due. The non-destructive alternative CLAUDE.md's agent contract
calls the preferred path — drain, snapshot, re-exec, re-attach, no dialog and no
lost sessions — is filed as **T705**.

### `ghoztty +send-keys`

Send text input to a named pane's terminal PTY.

```
ghoztty +send-keys --target=<name> [flags] <text|key>...
```

> **To submit, end the text with `\n`** — `ghoztty +send-keys --target=t "prompt\n"`.
> (`--enter`, or a separate `Enter` argument, do the same thing. Use one, not
> two — they stack, and two of them submit twice.)

- `--target`: Named pane or window to send input to. Required.
- `--enter`: Press Enter after the text. Same as a trailing `\n` or a trailing `Enter` argument. On its own, with no text, it just presses Enter.
- `--when-idle`: Poll the target pane's recent output every 500ms until it looks idle before sending: no `esc to interrupt` in the tail (older Claude Code's busy marker) AND the tail unchanged across ~1s (busy TUIs animate spinners/timers every second; an idle prompt is static — this catches Claude Code ≥ 2.1.207, which dropped the marker). Sends anyway after `--idle-timeout=<seconds>` (default 30) or if the pane can't be read.
- `--keys-file=<path>`: Send the file's bytes **verbatim** — no key notation, no
  `\n` escape processing. It keeps its position among the positional arguments,
  so `--keys-file=p.txt Enter` sends the file and then a carriage return. **Use
  this for any text the caller did not author by hand** (a prompt, a path,
  anything with quotes or backslashes): PowerShell 5.1 does not escape an
  embedded `"` when it builds a native command line, so such text arrives as a
  positional argument with its quotes stripped, re-tokenized and concatenated
  without separators, or broken outright. Length is not the hazard — the
  transport is byte-exact at 10,000 characters (T210). **The trailing-newline
  rule below does not apply to it**: the CLI sends a file exactly as it is on
  disk, trailing newline included, because "verbatim" is the flag's whole reason
  to exist and a generated prompt file routinely ends in a newline nobody meant
  as "submit". Submit one with a following `Enter` (or `--enter`). Like any
  text run it follows the paste convention below, so the file's own trailing
  newline reaches a bracketed-paste program (every TUI) as a literal newline
  and does not submit.
- Positional arguments are text or key names, written to the PTY in order.
  Adjacent arguments of the same kind merge into one **run**, and the run
  boundaries survive to the PTY write: a text run is framed as a **bracketed
  paste** (`ESC[200~` … `ESC[201~`, one write) when the program in the pane has
  mode 2004 enabled, and key runs are written bare, outside the frame. That is
  what makes `+send-keys --target=t "a long prompt" Enter` submit — an unframed
  trailing `\r` reads to a TUI as a newline *inside* pasted text, and the
  message sits in the composer unsent. Framing is a property of the bytes, not
  of their timing, so no sleep in the path substitutes for it.
- Key notation: `C-c` (Ctrl-C), `C-d` (Ctrl-D), `C-z` (Ctrl-Z), etc.
- Named keys: `Enter`, `Tab`, `Escape`, `Space`, `Backspace`
- Escape sequences in text: `\n`, `\t`, `\r`, `\\`, `\e`

```bash
ghoztty +send-keys --target=term "hello\tworld\n"   # types, then submits
ghoztty +send-keys --target=term "ls -la" Enter
ghoztty +send-keys --target=term --enter "ls -la"
ghoztty +send-keys --target=term C-c
```

**A trailing newline is a keypress; an interior one is content.** The trailing run of `\n`/`\r` is peeled off a text argument and delivered as that many Enter presses, so `"a\nb\n"` pastes two lines and then submits. **What is counted is line endings, not bytes** (T658): a trailing `\r\n` is ONE line ending written the Windows way and presses Enter once, while repeated endings still count separately (`"a\n\n"` and `"a\r\n\r\n"` both press twice, and a bare `"a\r\r"` still presses twice). Counting bytes there submitted a CRLF-terminated argument twice — the caller's message, then an empty line after it, which a chat-style TUI reads as a second, blank turn — and Windows is where CRLF text comes from. This is a deliberate divergence from upstream main's byte-counting peel (`a7f7476e1`), which T604 ported verbatim; round 17 of `test/win32/send-keys-bracketed.ps1` is the on-wire oracle. This runs after escape processing, so `\n` written as the two-character escape and a real newline byte behave identically. The accepted cost: there is no way to paste text ending in a literal newline without submitting — a trailing newline in a paste means "commit" essentially always, and a program that has not enabled bracketed paste sees `\r` mapped back to `\n` by the tty's `ICRNL` anyway. (`--keys-file=` is exempt; see above.)

**A newline inside a text run follows the paste convention, on both platforms** (T661). A program that has enabled bracketed paste receives it as a literal `\n` — it is a line break in the pasted content, which is what makes `"a\nb\n"` type two lines into a composer and then submit. A program that has NOT receives `\n` mapped to `\r`, which is what xterm has always done for an unbracketed paste (`src/input/paste.zig`) and what makes the same send run two commands in a shell. macOS reaches the second half for free, because a POSIX pty accepts LF as a line terminator; Windows has to do the mapping, because conhost's VT input translation **swallows a bare LF** — without it `+send-keys "echo A\necho B\n"` reaches `cmd.exe` as `echo Aecho B`. The win32 rule is `IpcHandlers.prepareSendKeysRun`; rounds 11, 12 and 15 of `test/win32/send-keys-bracketed.ps1` measure both halves on the wire.

That rule needs to know the CLI already spelled `Enter` as CR, and a flat `--keys=` payload cannot say so by itself, so **every `+send-keys` request carries `--keys-resolved=1`**. A request without it came from a CLI old enough that a bare `\n` meant Enter and is normalized unconditionally, exactly as before — a server ignores the argument it does not know, and macOS, which never normalized at all, ignores it forever. Round 16 is that control.

**Any unknown `--flag` is a hard error** (exit 1), naming the submit spellings. `--press-enter` used to become a text positional and get typed into the pane at exit 0, which is how agents got this wrong without noticing. Single-dash arguments (`-la`, `-p`) are ordinary text. To send literal text starting with `--`, put it after a bare `--`, which stops flag parsing but not key notation:

```bash
ghoztty +send-keys --target=term -- "--not-a-flag" Enter
```

**Text and keys stay distinguishable.** Argument boundaries survive all the way to the write. When a call mixes text with keys, adjacent arguments of the same kind merge into a run, and each **text** run is written to the pane as a **bracketed paste** (`ESC[200~` … `ESC[201~`) while each **key** run is written bare, outside the frame.

This is what makes `+send-keys --target=t "some message" Enter` actually submit. Flattened into one burst of bytes ending in `\r`, a TUI's paste detection reads that `\r` as a newline inside pasted text — correctly, since that is exactly how a real multi-line paste looks — and the message sits unsent in the composer. Framing states which bytes were pasted, so the `\r` after the closing fencepost is unambiguously a keypress. It is a property of the bytes, not of their timing, so there is no delay anywhere in the path.

Two consequences worth knowing:

- A text run is framed **in a single PTY write**. Splitting the frame across writes lets the opening fencepost land in its own `read()` on the far side, and a receiver that sees a lone `ESC[200~` does not reliably associate it with the content after it (measured against Claude Code, which then falls back to its length heuristic and swallows the `\r` again).
- Framing only happens when the program running in the pane has **enabled bracketed paste** (DEC mode 2004) — which every modern TUI and interactive shell does. A pane running something that has not (`cat`, a shell script's `read`) gets the bytes verbatim, so nothing can inject literal `[200~` junk into a program that would not understand it. Text containing `ESC[201~` is also sent unframed, rather than emitting a frame that would close early.

Single-kind calls — `"text"` on its own, `Enter` on its own, `C-c` on its own — have no boundary to disambiguate and are sent byte-for-byte as they always were.

**Delivery integrity is measured, not assumed** (T664). A pane read cannot tell a byte that never arrived from a byte the grid lost, which is how one sighting of a text run missing its FIRST character — a `--keys-file` run landing a beat after a bare Enter — stayed an anecdote. Rounds 13–14 of `test/win32/send-keys-bracketed.ps1` pin that shape on the wire, byte for byte, including a payload long enough to cross the 64-byte pooled write buffer in `termio.Exec.queueWrite` (the only seam that splits one run across two PTY writes). `test/win32/send-keys-soak.ps1` repeats it a few hundred times with randomised gaps, judged by a receipt file the in-pane shell writes rather than by the screen; it is **on-demand, not part of P1–P3**. 315 measured sends found no loss, so nothing in our write path is known to truncate a run — the unexplained leg, if it recurs, is conhost's VT input translation and cygwin's console reader.

**A boundary the CLI cannot see is a boundary it cannot encode.** Framing spans one call, so a caller that must split the text and the Enter into two calls — the self-upgrade does, because it verifies the prompt arrived before submitting it — gets a flat text run and a naked CR no matter what the CLI does. Such a caller submits with `" " Enter` rather than a bare `Enter`: the throwaway space makes the *submitting* call a mixed send, so a closing fencepost lands immediately before the CR. A trailing space means nothing to the receiver, which is what makes it safe — a submit that instead withheld the prompt's own last character would submit a truncated prompt if that character were dropped. Shared helper: `Get-LoopSubmitArgs` in `scripts/loop-session.ps1` (T438); byte-level oracle: rounds 6–8 of `test/win32/send-keys-bracketed.ps1`.

### `ghoztty +set-state`

Set the activity state of a named window or pane. The state is aggregated across all panes in a window (priority: `needs_input` > `busy` > `idle`) and shown as a title suffix and custom `AXWindowActivityState` accessibility attribute.

`idle`/`busy`/`needs_input` are the **machine tokens** — the vocabulary of this flag, of the OSC 7777 payload, and of `AXWindowActivityState`. They are a public API (hooks call the CLI, external tools like ztabby read the attribute) and do not change for readability. The **title suffix** shows a human label instead, and the two differ for one state: `needs_input` renders as `(question)`. Consumers must read the accessibility attribute rather than parsing the title. (The win32 title still interpolates the raw token — T465.)

```
ghoztty +set-state --target=<name> --state=<idle|busy|needs_input>
```

- `--target`: Named window or pane. Required.
- `--state`: Activity state. Required. One of `idle`, `busy`, `needs_input`.

```bash
ghoztty +set-state --target=dev --state=busy
ghoztty +set-state --target=dev --state=needs_input
ghoztty +set-state --target=dev --state=idle
```

Processes can also set state via OSC escape sequence: `\033]7777;<state>\007`

### `ghoztty +set-banner`

Set or clear the sticky banner of a named pane or window. The banner is a native overlay rendered above the terminal content of a pane — it persists (survives scrolling, screen clears, and content updates) until changed or cleared. Setting a banner on a window target applies it to that window's focused pane (banners are per-pane).

```
ghoztty +set-banner --target=<name> [--clear] [text...]
```

- `--target`: Named pane or window. Required.
- `--clear`: Remove the banner (empty text does the same).
- All other arguments are treated as the banner text (multiple are joined with spaces).

Banner text supports a small markdown subset: `**bold**`, `*italic*` or `_italic_`, `__underline__`, `` `code` ``, and `[text](url)` clickable links (URL must include a scheme, e.g. `https://`). Note `__underline__` intentionally differs from CommonMark (where `__` is bold). `\` escapes the next character. Unterminated delimiters render literally. A literal `\n` in CLI banner text becomes a line break — banners can span multiple lines (display is capped at 10 lines).

**Autolinking.** Bare URLs and bare file paths become clickable without `[text](url)` syntax. A URL must carry a scheme — only `http://` and `https://` linkify, never a bare `www.example.com` or `config.io`, so prose is never falsely linked. A file path must start with `/`, `~/`, `./`, or `../`; the sigil is the whole signal (there is no filesystem check), which is why a bare relative `macos/Sources/Foo.swift` stays plain text. `~/` expands to the home directory and `./`/`../` resolve against **the pane's current working directory** at render time — a dot-relative path in a pane with no known cwd stays plain text rather than resolving against a guess. Trailing sentence punctuation stays outside the link (`See https://x.com.` links `https://x.com`), while brackets balanced *inside* the link are kept (`…/Foo_(bar)`). Autolinking never fires inside a `` `code` `` span, after a `\` escape, or inside an explicit `[label](url)` — the explicit link always owns its whole label.

**Link clicks.** A plain click hands the link *out* of Ghoztty; the modifiers bring it back in. Cmd (**Ctrl on Windows**) opens a **viewer side pane** for either kind of link, and Cmd-Shift (**Ctrl-Shift**) gives the link a surface of its own.

| | plain click | Cmd / Ctrl | Cmd-Shift / Ctrl-Shift |
|---|---|---|---|
| **URL** | default browser | side pane | new Ghoztty window |
| **file path** | reveal in Finder / File Explorer | side pane | open with default app |

A URL goes to the real browser by default because Ghoztty's `WKWebView` (WebView2 on Windows) keeps its own cookie store with no relationship to Safari/Chrome/Edge — anything behind a login renders logged-out in a viewer pane, and OAuth sign-in never completes. A file path is only *revealed*, never opened, so a click can't launch whatever app claims the extension. The right-click menu offers all of them (its first item is by contract the left-click default) plus Copy Link / Copy Path.

**Link hover affordance.** A banner link's underline is **dotted at rest and solid while the pointer is over it** (plus the pointing-hand cursor), so a link reads as a link before you click and tells you which one a click would take. Hovering lights the WHOLE link, not the fragment under the pointer — a link split by wrapping or by nested styling goes solid together. The underline is drawn by hand rather than by the font's own underline attribute, because there is exactly one of those and it is solid: a link would otherwise either always look hovered or never look like a link. Shared with the same click/menu model on both platforms (win32: `banner_link.zig` + `banner_layout.linkUnderline`, T165).

**Lists.** Consecutive lines that begin with a list marker render as a list block with table-like row spacing and a **shared marker gutter**, so every item's content left-aligns regardless of marker kind (bullets, numbers, and checkboxes in one run all line up). Supported markers:

- `- ` or `* ` → an unordered **bullet** (`•`).
- `1.`, `2.`, … (digits, a period, then a space) → an **ordered** item, rendered with the source number. A decimal like `1.5` (no space after the dot) stays plain text.
- `[x]`/`[X]` (checked) and `[ ]` (single space, unchecked) → a read-only **task-list checkbox**, drawn as a **native box** (rounded 2px corners; checked shows a green check on a faint green wash), not a plaintext glyph. A `- `/`* ` directly before a checkbox is the checkbox's marker, not a separate bullet (`- [x] done`). Checkboxes are display-only (no interactivity), and `[x](url)` is still a link (the `x` is link text). Checkboxes in **table cells** render the same native box. A checkbox that appears mid-paragraph in a wrapping (non-list) text line falls back to the `☑`/`☐` glyph.

**Separators.** A line of 3+ of the same `-`, `*`, or `_` (spaces allowed — `---`, `***`, `___`, `- - -`) is a **thematic break**, rendered as a full-width horizontal divider between the blocks above and below it (e.g. to separate a title, a table, and a trailing note). A `- `/`* ` bullet or `**bold**` on its own line is unaffected (they carry non-marker content or mixed characters). Each rule counts as one line toward the 10-line display cap.

Banners also support standard markdown pipe tables, rendered as an aligned grid with a bold header row: a `| a | b |` header line immediately followed by a `|---|---|` separator with the same column count, then `| 1 | 2 |` body rows. Separator cells may carry `:` alignment markers (`:---` left, `:---:` center, `---:` right). Cells support the full inline subset; `\|` puts a literal pipe inside a cell. Ragged body rows are padded/truncated to the header width. The separator row doesn't render; every other table row counts toward the 10-line display cap (a row still counts once no matter how many lines its cells wrap to). **Long cell text word-wraps** onto multiple lines and the row grows to fit, rather than truncating to one line — matching a normal markdown renderer. Column widths derive from the pane's current width, so the banner reflows live as the pane is resized and never blocks the pane from shrinking (even a long unbroken token breaks mid-string). A cell is capped at **3 wrapped lines** — a cell that would wrap further (e.g. a long unbroken string in a very narrow pane) is tail-truncated with an ellipsis on its last visible line, so one nasty cell can't blow up the banner height. A cell that contains an *inline* task-list checkbox stays a single line (its native box can't reflow around wrapping text).

**Everything wraps, by one rule.** Paragraphs, headings and list rows wrap exactly the way table cells do (T377) — greedy word wrap against the pane's current content width, a long unbroken token broken mid-string, and the same **3-line cap** with a tail ellipsis on the last visible line. A wrapped list row's continuation lines start at the shared marker gutter, not back under the marker, and a task-list row wraps like any other (its checkbox is the row's *marker*, drawn in the gutter, so nothing has to reflow around it). The wrapped height is what the renderer reports upward, so the band, the pane inset and the terminal below all follow it. The 10-line display cap still counts a wrapped block **once**, the way a wrapped table row counts once.

**The collapse chevron owns the card's right strip.** Content — every block, not just the first line — stops a clear 4 DIP short of the chevron's box, so no paragraph, heading, list row, table cell or rule ever paints under it. The reservation is pure geometry (`banner_layout.contentWidth`, asserted at 1.0/1.25/1.5/2.0) and applies only when the banner is collapsible, i.e. when a chevron is actually drawn.

**Collapsing animates the card and only the card.** The card eases between its expanded and collapsed heights over 180ms (`banner_layout.COLLAPSE_MS`, Mac's `easeInOut(0.18)`), while the band the window layout reserves — and therefore the terminal grid below it — moves to the settled height in ONE step per click. Both platforms arrive there from opposite directions: Mac drives its inset off a hidden, animation-free copy of the banner content so the Metal surface never chases intermediate frames; win32 simply never lets the animation into `stripHeight()`, and lets the still-tall card overhang the terminal for the length of a collapse. A second click mid-flight reverses from the height the card is actually at, and users who turned off Windows' "animation effects" (`SPI_GETCLIENTAREAANIMATION`, read in one place: `App.clientAreaAnimationsEnabled`) get the instant toggle. What win32 does NOT do yet is Mac's parallel cross-fade of the body — it clips the content to the animating card with the existing bottom fade instead, filed as T677. Acceptance: section 6f2 of `test/win32/pane-banner.ps1` (T149).

```bash
ghoztty +set-banner --target=dev "**Build status**\n| Job | State |\n|---|---:|\n| lint | ok |\n| tests | **3 failed** |"
```

```bash
ghoztty +set-banner --target=dev "**PR #123** — _3 files_, +120/−45 — [view](https://github.com/org/repo/pull/123)"
ghoztty +set-banner --target=dev --clear
```

Processes can also set the banner from inside the pane via OSC escape sequence: `\033]7778;<text>\007` (empty text clears). The interactive equivalent is Cmd+R ("Set Pane Banner…", also in the command palette), which opens a multi-line editor for the focused pane's banner (Return inserts a newline, Cmd+Return saves, Escape cancels). Cmd+R only reaches this while a **terminal** pane is focused — a focused viewer pane takes Cmd+R for reload (see Viewer Panes). On Windows the editor chord is Ctrl+Shift+B and Ctrl+Enter saves (plain Ctrl+R belongs to the shell).

Banners are persisted per pane in the session-layout manifest (keyed to the stable pane id), so a session-persistence restore brings them back with their text intact — across app quit/relaunch/upgrade re-attach and across an agent-restart relaunch alike. **The banner slot belongs to the pane** (T422): the session-interrupted notice an agent-restart prints is always folded into the pane's scrollback, but only claims the banner slot when the pane has no banner of its own — a restored banner is never overwritten by it. `+list --json` reports each terminal pane's current banner in a `banner` field (absent when no banner is set), which is also the CLI way to read a banner back.

### `ghoztty +reload`

Reload a named **viewer pane** (see Viewer Panes below) in place — no
close/reopen. Website viewers re-fetch the page from origin (bypassing
caches); file viewers re-render the file preserving scroll position (they
already live-reload on their own, so this mainly matters for URL viewers);
**diff viewers re-run their git command**, picking up commits, staging, and
edits, and keeping the open file and its scroll position.

```
ghoztty +reload --target=<name>
```

- `--target`: Named window or pane (or a pane id). Required. For a window
  target the reload applies to its focused pane.
- Targeting a terminal pane fails with `... is a terminal pane, nothing to
  reload` (exit 1), mirroring how terminal-only commands reject viewer panes.
- Interactive equivalent: **Cmd+R** while a viewer pane is focused (see
  Viewer Panes → Keyboard).

```bash
ghoztty +split --target=dev --name=preview --view=http://localhost:3000
ghoztty +reload --target=preview
```

### `ghoztty +new-remote-window`

Open a terminal window whose shell runs on a remote machine via a `ghoztty-agent`
reached over TCP. Drives the same flow as the Cmd-Shift-N "New Remote Window" menu
action (dial the agent, build a remote surface, open the window), so the remote
path is scriptable/testable from the shell.

```
ghoztty +new-remote-window --host=<host> --port=<port> --relay=<base> --device=<id> --token=<tok> --working-directory=<path> --shell=<path> --command=<cmd>
```

- `--host`: Agent host (DNS name or literal IP). Required unless dialing via `--relay` + `--device`.
- `--port`: Agent TCP port. Required unless dialing via `--relay` + `--device`.
- `--relay` + `--device`: Dial the enrolled agent `--device=<id>` through the
  rendezvous relay at `--relay=<https-base>` instead of direct TCP (takes
  precedence over `--host`/`--port` when both are given). Auth bearer:
  explicit `--token=`, else the signed-in account (macOS Keychain; on Windows
  the DPAPI account store, see Relay account sign-in below), else the
  `GHOSTTY_RELAY_TOKEN` env var — with no source the command fails with "not
  signed in".
- `--working-directory`: Working directory ON THE REMOTE MACHINE for the new
  session. Overrides the machine's per-host default.
- `--shell`: Shell ON THE REMOTE MACHINE to run (e.g. `wsl.exe`,
  `powershell.exe`, `/bin/zsh`). Overrides the machine's per-host default.
- `--command`: Command to run in the remote session instead of an interactive
  shell. Runs through the resolved shell using its native convention (POSIX
  `-lic`, cmd `/c`, powershell/pwsh `-Command`, wsl `--`).

```bash
ghoztty +new-remote-window --host=127.0.0.1 --port=7777
ghoztty +new-remote-window --host=winbox --port=7777 --shell=wsl.exe --working-directory='C:\dev'
```

The remote session uses the remote machine's own default shell and working
directory (the local shell/pwd are NOT forwarded — they would not exist on a
different OS such as a Windows ConPTY agent) unless a **per-host default** or
an explicit flag says otherwise. Per-host defaults (default working directory
+ default shell per machine) are edited in the machine chooser (Cmd-Shift-N on
macOS / Ctrl+Shift+N on Windows → row `⋯` menu → "Host Settings…"), keyed by
relay device id or `host:port` — persisted in UserDefaults on macOS and in
`%LOCALAPPDATA%\ghoztty\host_defaults.json` on Windows (`-debug` suffixed for
debug builds; `GHOSTTY_HOST_DEFAULTS` overrides the path outright, which is how
the acceptance test avoids the real file). Both are LOCAL preferences, never
account resources: a sign-out or a 401 must not lose a user's shell choice.
Explicit `--working-directory`/`--shell` flags override them per window. New
tabs/splits on a remote window use the per-host default shell too — but NOT its
working directory, since their cwd inherits from the parent pane and a default
must not yank a split away from where its parent is.

### The connection status pill (GUI, both platforms)

A remote window's titlebar carries a small **connection pill**, because a
dropped link is otherwise invisible until you type into a pane and nothing
happens. Three states, driven by the per-window reconnect ladder:

| State | Shows | Clickable |
|---|---|---|
| connected | a **green dot**, no words | no |
| reconnecting | an **amber dot** + `Reconnecting… n/5` | no |
| disconnected | a **red** capsule: refresh glyph + **Reconnect** | yes — re-dials now |

Connected is deliberately wordless: a chip that permanently reads "Connected"
is chrome that says nothing, so the pill only grows words when something is
wrong. That is also what keeps the three states apart without relying on hue
(WCAG 1.4.1) — they differ in whether there is text and in what it says.
Clicking **Reconnect** starts from ANY disconnected tier, terminal included,
resets the poisoned-session breaker (a click is fresh evidence) and dials
immediately instead of waiting out a backoff. It re-attaches when the session
survived — **but on Windows a session that did NOT survive still ends the
window rather than opening a fresh shell on the machine** (T611), so a click
after the remote box rebooted currently dials, finds nothing to re-attach, and
leaves the pill red.

macOS renders this as Mac's machine pill plus a separate status capsule
(`MachinePillView.swift`); Windows merges the two into one capsule in the
caption band (T367) — the band already hosts the "…" button, so the affordance
costs no terminal rows, and the pill shares that button's vertical center. A
**quiet** win32 pill is not a button and stays part of the drag region, so it
never leaves a dead patch in the titlebar. Windows geometry, wording and
contrast floors: `src/apprt/win32/remote_pill.zig` (asserted at
1.0/1.25/1.5/2.0); acceptance: `test/win32/remote-pill.ps1`. The win32 pill
does not yet name the machine or open the Activity Monitor on click the way
Mac's does — filed as T610.

### Relay account sign-in (GUI only — there is no CLI verb)

Signing in to the Google account that authenticates relay connections is a
**GUI affordance on every platform**: the machine chooser's account row
(Cmd-Shift-N on macOS, Ctrl+Shift+N on Windows) shows the signed-in email with
a **Sign Out** button, or a **Sign in with Google…** button when signed out.
There is deliberately **no `+relay-login` / `+relay-logout` CLI command** —
Windows briefly had that pair and it was removed (T141), because a verb that
exists on one platform's CLI and not the other's is exactly the divergence this
project does not ship. If you are looking for a CLI way to sign in, there isn't
one by design; open the chooser.

Both platforms use the same **relay-brokered (BFF) OAuth**: PKCE + a loopback
redirect obtain the authorization code locally, the code goes to the relay's
`/oauth/exchange` (the relay holds the client secret and talks to Google
server-side), and the returned opaque **relay session token** + expiry + email
+ relay base are stored — macOS in the Keychain, Windows **DPAPI-encrypted** at
`%LOCALAPPDATA%\ghoztty\account.dat` (owner-only DACL). No Google token or
client secret ever touches the machine. The flow runs on a background thread so
the window never blocks while the browser is open; the app renews the session
at the stored relay via `/oauth/renew` as it nears expiry (renewal rotates the
token and the rotation is persisted). Sign-out best-effort revokes at the relay
(`/oauth/signout`, which also destroys the relay-held Google refresh token)
before deleting the local store.

The Google OAuth client id is baked into the build via `-Dgoogle-client-id`
(public — it appears in the browser URL), overridable with
`GHOSTTY_GOOGLE_CLIENT_ID`; the relay comes from `GHOSTTY_RELAY_BASE`, else the
built-in default. Shared implementation: `src/remote/relay_signin.zig`; win32
UI in `src/apprt/win32/RelayAccountRow.zig`.

Once signed in, `+new-remote-window --relay/--device` with **no** `--token`
uses the account's session token (token-resolution order: explicit `--token`
→ signed-in account → `GHOSTTY_RELAY_TOKEN`). A pre-brokered store
(refresh-token shape) is treated as signed out — sign in once more to migrate.

### Naming

- `+new-window --target=<name>` registers a **window**
- `+split --name=<name>` registers a **pane**
- `+split --target`, `+close --target`, and `+send-keys --target` reference either kind

A window opened without an explicit `--target=` (Cmd-N, or a bare
`+new-window`) still gets an **auto name** — `window-1`, `window-2`, … — which
is exported to its panes as `$GHOZTTY_WINDOW_NAME` and shown as `target` in
`+list`. That name is targetable immediately: `resolveTarget` falls back to
scanning live windows by name, so no `+list` is needed first. (It used to be
registry-only, so every `--target=window-N` failed with `not found in
registry` until something walked the tree — invisibly, for the many callers
that discard stderr.)

### Pane identity

Every pane has a **stable, ghoztty-owned pane id** (a UUID):

- Exported to the pane's processes as `$GHOZTTY_PANE_ID` (baked at spawn).
- Shown as the leaf `id` in `+list --json`.
- Accepted directly by every `--target`/`--name` (case-insensitive), with no
  prior registration or `+list` needed: `ghoztty +set-banner
  --target=$GHOZTTY_PANE_ID …` works from inside any local pane.
- Stable for the pane's whole life: persisted in the session-layout manifest and
  restored on app relaunch (session-persistence panes keep the same id AND the
  same baked env), preserved across remote reconnect swaps, and re-applied to
  the respawned shell when the agent relaunches a session after its own restart
  (the RELAUNCH carries the pane's env/TERM/argv).

Prefer the pane id over pid/tty matching for self-identification: pids and ttys
belong to the machine the process runs on and are meaningless for remote panes.
(`+list --tty=<tty>` still works for local panes as a fallback.)

### Instance addressability

An IPC command run inside a pane targets **the app instance that owns that
pane**, not whichever build the `ghoztty` binary on `$PATH` happens to be. Every
pane's env is baked with `$GHOZTTY_IPC_SOCKET` — the absolute path of its own
app's IPC socket — and the CLI prefers it over the compile-time
`ghostty[-debug]-<uid>.sock` derivation. So `ghoztty +split` run from a
debug-build pane splits the **debug** window even though `ghoztty` on `$PATH` is
the release binary (before this, it silently drove the release app).

- Baked on every pane path: plain local spawn, session-persistence agent panes
  (the agent replays the pane env on RELAUNCH), and remote panes — a remote
  pane's IPC still belongs to the *local* app.
- Absent or empty ⇒ today's derivation, so a CLI run from a plain non-Ghoztty
  shell is unchanged, as is a pane baked by an older app or agent.
- Override it (`GHOZTTY_IPC_SOCKET=<path> ghoztty +list`) to aim a single
  command at a specific instance.
- One resolution site each side: `apprt.ipc.socketPath()` (`src/apprt/ipc.zig`)
  for the CLI, `IPCSocket.path` (Swift) for the server.
- **Windows uses the same var for a pipe name** (T118): the value is
  `\\.\pipe\ghoztty[-debug]-<user>`, not a socket path, and the name was kept
  identical rather than adding a sibling — the var is baked into long-lived
  panes that outlive the app, and neither side ever parses the value. The CLI
  resolves it in `ipc_client.clientEndpointPath()`
  (`src/os/ipc_client.zig`), which `apprt.ipc.socketPath()` delegates to there.
- **An explicit `GHOZTTY_PIPE_SUFFIX` outranks the baked value** on Windows.
  The suffix is how a harness aims at the instance it just launched, and a
  script inherits the environment of the pane it was started from — without
  this rule every `test\win32\*.ps1` run from one of the user's panes would
  drive the user's terminal. Precedence: suffix → baked → derivation.
- **Only clients read it.** The IPC *server* binds `ipc_client.endpointPath()`,
  the pure derivation, and the win32 App drops any inherited
  `$GHOZTTY_IPC_SOCKET` from its own environment at startup — otherwise a dev
  build launched from a pane of the installed release would try to bind (or
  forward its startup `new-window` to) that release instance's endpoint.
  Acceptance: `test/win32/ipc-instance-addressability.ps1`.

### Example: three-pane layout

```bash
ghoztty +new-window --target=ide --command="nvim ."
ghoztty +split --target=ide --name=term --direction=down --command=zsh
ghoztty +split --target=ide --name=logs --direction=right --command="tail -f app.log"
# read output from a pane
ghoztty +read --name=logs --lines=5
# teardown
ghoztty +close --target=logs
ghoztty +close --target=term
ghoztty +close --target=ide
```

## The `ghoztty://` URL scheme

A **link** can raise a Ghoztty window or pane. This is the piece that makes a
generated document (a worktree dashboard, a status report) able to say "jump to
that terminal" — from a browser, from a doc rendered in a viewer pane, or from
a pane banner.

```
ghoztty://focus/<target>
```

One verb, one shape. `<target>` is percent-decoded and passed to the same
target resolver `--target` uses, so there is one naming system, not two: a
registered window name, an auto `window-N`, a registered pane name, or a pane
id (`$GHOZTTY_PANE_ID`, case-insensitive). Everything after the verb is ONE
target, so a name containing `/` survives encoded (`focus/feat%2Flogin`) or not
(`focus/feat/login`). The path form is canonical over `ghoztty://<target>`
(nowhere to put a verb) and over `ghoztty://focus?target=…` (a second escaping
context for no gain). Parsing is strict: unknown verb, empty target, and bare
`ghoztty://<name>` all yield nothing rather than a lenient guess. **There is no
`+focus` CLI verb on either platform** — the scheme is a link surface, and a
verb that existed on one CLI and not the other is the divergence this project
does not ship.

**Focus is the only capability, and that is the design, not a first
increment.** A registered URL scheme is reachable by any web page the user
visits — no prompt, no gesture beyond a click, no same-origin check, no way to
know who asked. Everything the IPC endpoint exposes is safe there only because
a 0600 unix socket (an owner-only-DACL named pipe on Windows) is reachable only
by code already running as the user; none of that holds for a link. A scheme
that could spawn a shell (`--command`), type into a pane (`+send-keys`), or open
a viewer would be remote code execution behind an `<a href>`. Raising an
already-existing window is the one verb whose worst case is a nuisance. The
parser reads a verb rather than hardcoding one shape so a future verb *could* be
added — but wanting a second verb to make something work is a signal to stop and
ask, not to add one.

Consequences, all deliberate and the same on both platforms:

- **The debug build registers `ghoztty-debug://`**, the release builds
  `ghoztty://` — the same split as the IPC endpoint (and, on macOS, the bundle
  id). Otherwise the shell picks between them and the user's links start landing
  in a debug build. macOS declares it in `CFBundleURLTypes` (the
  `GHOSTTY_URL_SCHEME` build setting); Windows has no `Info.plist`, so the app
  writes its own per-user handler at launch —
  `HKCU\Software\Classes\<scheme>` with the `URL Protocol` marker and
  `shell\open\command` = `"<this exe>" "%1"`, off the GUI thread, idempotent and
  rewritten every launch so an upgrade or a move re-points it. `HKCU`, never
  `HKLM`: Ghoztty installs per user and a machine-wide association would need
  elevation. `GHOZTTY_URL_SCHEME=0`/`off` skips registration.
- **Both spellings parse in both builds.** Links clicked *inside* Ghoztty are
  short-circuited in process and never reach the shell, so a document that
  hardcodes `ghoztty://` still focuses the right pane when a debug build is
  rendering it.
- **A link that resolves to nothing says so** (`url_scheme.Failure`): a warning
  naming the target for `target_not_found`, or naming the URL plus the one
  supported form for `unsupported_link`. A click that appears to do nothing is
  indistinguishable from a broken app, and both failures are ordinary (the
  window was closed; the document predates this build). What failure never does
  is *act*: no window is created and no "closest" window is focused as a
  consolation. Presentation is **coalesced** so a burst — any page can fire a
  scheme — is one dialog, not one per link: macOS behind an
  `isPresentingFailure` flag (`application(_:open:)` takes a whole array),
  Windows behind a named mutex as well, because there every click is its own
  short-lived process and a flag cannot see the burst. A URL that isn't ours at
  all is ignored silently; nobody clicked a Ghoztty link. The wording lives on
  `Failure` rather than in the presenter so it is testable.
- **App not running:** the honest answer is the same as any other miss —
  nothing is open by that name — because a focus link must never create a
  window as a side effect. macOS cannot decline the launch LaunchServices does,
  so the app comes up with its normal `initial-window` behavior (that belongs to
  *launching Ghoztty*, exactly as `open -a` does, not to the focus verb) and the
  link reports not-found. On Windows the activation process reports it and
  exits without starting a terminal at all.
- **Viewer panes** intercept `ghoztty://` ahead of the live-page passthrough
  (the engine cannot load the scheme, so an allowed navigation is a dead click,
  and handing it to the shell would route it to whichever BUILD registered the
  scheme). A `target="_blank"` focus link resolves to a *command* destination
  instead of falling through "non-web scheme ⇒ open a Ghoztty window", which is
  how it used to create a viewer window pointed at the command string.
- **Rendered markdown** needs `viewer.js` to widen DOMPurify's
  `ALLOWED_URI_REGEXP` by exactly these two schemes. markdown-it keeps a
  `ghoztty://` href, and the sanitizer then stripped it — the link rendered as
  dead text. Keep the regex in sync when the vendored DOMPurify is bumped.
- **Banner links** ignore the Cmd / Ctrl modifier scheme: the link names a
  window, not content, so there is nothing to open in a side pane or a new
  window. The right-click menu is **Focus in Ghoztty** + **Copy Link**.

The grammar and the failure wording are ONE definition per platform —
`src/apprt/ipc/url_scheme.zig` on Windows, `GhozttyURLScheme.swift` on macOS —
so the launcher, the viewer and the banner cannot disagree about what a link
means. Windows entry points: `main_ghostty.zig` (an activation is answered
before the single-instance bind, or it would forward a `new-window` and open a
terminal), `ViewerPane` for viewer link clicks and popups, `BannerOverlay` for
banner clicks; all funnel into `apprt/win32/url_scheme.zig` →
`IpcHandlers.focusTarget` (the external path through the internal `focus` IPC
action). Acceptance: `test/win32/url-scheme.ps1`.

## Viewer Panes

A pane (or a whole window) can render **content** instead of a terminal: a
markdown file, a plain text/code file, a website, or a **git diff**. Viewers
live in the normal split tree — they resize, focus, zoom, close, and persist
like any pane. View-only, no editing.

```bash
ghoztty +new-window --view=README.md                 # viewer window
ghoztty +split --target=dev --name=doc --view=docs/design.md
ghoztty +split --pane=doc --direction=down --view=https://example.com
ghoztty +split --target=dev --name=diff --view=git-status:   # a git diff
ghoztty +close --target=doc
```

- **Markdown** (`.md`, `.markdown`, `.mdown`, `.mkd`, `.mdwn`): GitHub-style
  rendering via bundled markdown-it + highlight.js (offline, zero network) —
  headings, GFM tables, nested/task lists, fenced code with syntax
  highlighting, blockquotes, images (relative paths resolve against the
  file's directory), links. Light/dark follows the window appearance. Body
  text is set in the **system font** and code in the system monospace, so a
  viewer reads as native content rather than a web page. One stack serves both
  platforms: `system-ui` leads it (San Francisco on macOS, Segoe UI on
  Windows), with the `-apple-system`/SF spellings and the `"Segoe UI"` /
  `Consolas` entries behind it as insurance for an engine that does not answer
  `system-ui`. A stack that names only the macOS families falls through to the
  GENERIC family on Windows — Arial, Courier New — next to chrome that is Segoe
  UI, which is what T386 fixed in `selection.js` and `viewer.css`. The same
  hole is still open in `diff.css` and rides the win32 diff pane (T595).
- **Table of contents** (markdown only, and only with two or more headings) —
  one of the two contents of the pane's shared **side panel** (the other is a
  diff's file tree; see Git diff panes). Everything in this bullet is the
  *panel*, and therefore true of both: only the rows differ.
  A native card listing the document's headings, nested by level, with the
  section you are reading highlighted as you scroll. The card reads as a
  macOS sidebar: the selected row is a rounded pill in the system's own
  selection colors — accent-filled with white text while the window is key,
  the neutral unemphasized gray otherwise — and hover is a separate faint
  wash. **Clicking a row pins the selection to it**: the smooth scroll on the
  way there fires a scroll event per frame, and the highlight must not walk
  off the row you asked for. Your next scroll gesture hands the selection
  back to the scroll spy. A pinned "CONTENTS" header sits on Liquid Glass
  (`glassBackdrop()`, macOS 26; an `NSVisualEffectView` before that) with the
  rows scrolling *under* it, and the scroller's track stops below it —
  both from one `safeAreaInset`, not a ZStack.
  In a **wide pane** the card sits in a left gutter and the document column
  reflows beside it; **drag the card's right edge** to resize it (the gutter
  and the document's text column follow in the same layout pass). The width
  is a preference in defaults, shared by every viewer pane.
  In a **narrow pane** (< 720pt) the gutter would crowd the text, so the card
  becomes an overlay: the navigation bar stays pinned open and gains a
  contents button as its first item, which slides the card in and out. The
  switch follows the *pane* width live, so dragging a split divider reflows
  it. The card is the same glass card as the pane banner overlay (shared
  `GlassCardBackground`), opaque so document text never shows through it.
  Panel open/closed state is ephemeral — it does not survive a session
  restore, since restoring an overlay would hide the content it covers.
- **Margins are one number.** `GlassCard.outerMargin` (12pt) is the gap every
  glass card leaves around itself, on all four sides, and the document leaves
  the same 12px on all four of its own — so a TOC card and a banner in the
  pane next door line up at their corners, and the text starts exactly one
  margin right of the card. Per-component fudges are what break that; there
  are none. Enforced by `documentAlignsToTheCard` in `ViewerTOCTests`.
- **Text/code files** (anything else): syntax-highlighted by extension.
- **Websites** (`http://`/`https://`): the pane navigates there directly.
- **Git diffs** (`git-status:` / `git-diff:<revspec>`): see Git diff panes.
- **Links** in file viewers: http(s) opens the default browser; a relative
  `.md` link opens another viewer split; other local files open in their
  default app.
- **Links that open a new surface** in a website viewer — `target="_blank"` or
  `window.open()` — go to the **system default browser**, not a new Ghoztty
  window, for the same cookie-store reason banner URLs do. Same-pane
  navigation is untouched: a website viewer follows ordinary links in place.
  **Cmd-click** (**Ctrl** on Windows) keeps the popup in Ghoztty as its own
  viewer window (honoring the size the opener asked for), and so does a popup
  the browser can't be handed — a bare `window.open()` with no URL, or a
  non-web scheme. The tradeoff: a popup that lands in the browser can't
  `window.close()` itself back to the Ghoztty page that opened it, so an OAuth
  flow finishes in the browser. That flow wasn't authenticating in Ghoztty
  anyway.

  **A kept popup is ADOPTED, never re-opened** (T163). The window's one pane
  hands its own web view to the runtime — Mac returns a `WKWebView` built from
  WebKit's `configuration` out of `createWebViewWith`; win32 parks the request
  on a WebView2 deferral and answers it with `put_NewWindow` once its pane's
  controller exists — and the runtime navigates that view itself. Opening a
  pane at the same URL instead is the mistake the whole path exists to avoid:
  it is a *different* window as far as the opening script is concerned, so
  `window.opener`, a write through the handle `window.open()` returned, and
  `window.close()` are all dead. `window.close()` closes the popup's pane and
  nothing else (Mac `webViewDidClose`, win32 `add_WindowCloseRequested` →
  posted, never handled inline, because closing a pane tears down the very
  controller whose callback you are in). The one thing win32 cannot copy is
  where the modifier comes from: WebView2 puts no modifier state on the popup
  args, so Ctrl is read with `GetAsyncKeyState` — `GetKeyState` there answers
  for the browser-process message being dispatched, not for the click.
  Acceptance: `test/win32/viewer-popup.ps1`, plus the live ABI test in the
  win32 unit lane (`ViewerPane.zig`, "T163: a popup is adopted as a pane,
  sized, and can close itself").
- **Live reload**: file viewers watch the file (including atomic saves) and
  re-render preserving scroll position.
- **Navigation chrome**: hovering the thin strip at a pane's top slides in a
  bar with back / forward / reload / **home** and an **editable address
  field** — in every mode, files included. Typing an `http(s)` address (or a
  bare `example.com`, completed omnibox-style) navigates the pane to the web;
  typing an absolute or `~` path points it back at a file. Back and forward
  reflect real history (disabled when there is none) and work across the
  file↔web boundary — going Back from a website re-renders the file. **Home**
  returns to the location the pane was originally opened with, which is
  remembered separately from where the user has navigated to (and both
  survive a session restore). Clicking into the address field selects the
  whole address; clicking again inside it just moves the caret.
- **Keyboard** (pane-scoped: live only while keyboard focus is inside a
  viewer pane — its page, its nav bar, or its feedback composer — in any
  viewer mode):
  - **Cmd+R** reloads the pane in place, exactly like `+reload` (web
    re-fetches from origin, files re-render with scroll preserved).
  - **Cmd+D** slides the nav bar in if hidden and puts the caret in the
    address field with the whole address selected — the keyboard version of
    clicking into it.
  - The standard editing chords (Cmd+C/V/X/A) reach whichever field inside the
    pane holds focus — the address bar, or a diff panel's filter — which they
    otherwise would not, because Cmd+C/V are terminal keybindings.
  - Both **override their global binding only while the viewer holds focus**
    (Cmd+R = "Set Pane Banner…", Cmd+D = split right). Focus a terminal pane
    and they do their global thing again; Cmd+Shift+R ("Change Window Title")
    and Cmd+Shift+D (split down) are never affected.
  - **On Windows** (T161) the pane-scoped chords are **Ctrl+R** (reload),
    **Ctrl+D / Ctrl+L / Alt+D** (address bar — the latter two are
    Windows-native aliases), and **Ctrl+Plus/Minus/0** (page zoom, same ×1.1
    step and [0.5, 3.0] clamp as the Mac Cmd+/−/0), under the identical
    override-only-while-focused rule: a focused terminal keeps ctrl+r for
    the shell, ctrl+d for split-right, and ctrl+plus/minus/0 for font size.
    Zoom is content-scoped (not live in the address field), matching Mac.
- `--view=about:blank` opens a **blank browser pane**. The command palette's
  "Viewer: Open Browser Pane" does the same interactively and puts the caret
  straight in the address field — the equivalent of `+split --view=<url>` for
  when the URL is not known up front.
- Because any viewer can browse, `+list --json`'s `"url"` (and the session
  manifest) report where a pane currently IS, not where it was opened.
- Relative `--view` paths resolve against `--working-directory` if given,
  else the caller's cwd. A `git-*:` spec is NOT a path — its text is a revspec,
  so it is never path-resolved; the same `--working-directory` decides which
  *repository* it applies to.
- `+list` marks viewer panes with a `view:` prefix (JSON: `"type": "viewer"`
  plus `"url"`); they auto-register names like terminal panes.
- `+read`/`+send-keys`/`+set-state`/`+set-banner` against a viewer fail with
  `... is a viewer pane, not a terminal` (exit 1). `+close` works normally
  and never prompts for viewers.
- Session persistence: viewer panes restore by re-opening their file/URL, and
  a diff pane by RE-RUNNING its spec against the origin directory the manifest
  persisted — so a restored `git-status:` pane shows today's working tree, not
  a snapshot of the one it was closed on. (Terminals in the same window
  re-attach as usual.) A missing file restores as an in-page error card.
- File → Open (or dragging onto the dock icon, or `open -a Ghoztty file.md`)
  opens `.md`-family files as a viewer window.

### Git diff panes

`--view=git-status:` / `--view=git-diff:<revspec>` opens a pane that renders a
git diff: a native file tree on the left, traditional red/green
syntax-highlighted hunks on the right, and next/previous-change +
unified⇄side-by-side controls in the nav bar.

**macOS only so far.** The CLI half is shared — `cli/view_arg.zig` knows both
schemes and passes them through path resolution untouched, mirroring
`ViewerDiffSpec.parse` — and so are the page assets (`src/viewer/diff.js`,
`diff.css`), but the win32 viewer has no diff mode yet, so the command is
accepted here and draws nothing usable. That is the divergence this project
does not ship, and it is filed rather than left undocumented: **T463** (render
the diff) and **T464** (the file-tree side panel).

```bash
# changes in this branch against main (three-dot: the merge base, which is
# what "changes in this branch" means to a person)
ghoztty +split --target=dev --name=diff --view=git-diff:main...HEAD

# the working tree — staged, unstaged, and untracked, kept apart
ghoztty +new-window --target=review --working-directory=~/git/repo --view=git-status:

# one commit's own changes, and an arbitrary range
ghoztty +split --view=git-diff:a1b2c3d
ghoztty +split --view=git-diff:v1.2.0..v1.3.0

# this branch against main/master/origin HEAD, whichever the repo has
ghoztty +split --view=git-diff:

ghoztty +reload --target=diff        # re-run the diff
```

**The location IS the diff spec**, which is what buys every existing viewer
affordance for free — the address bar shows and accepts it, `+list --json`
reports it as the pane's `url`, `+reload`/Cmd+R re-runs it, back/forward cross
into and out of it, and the session manifest restores the pane by re-running
it. Four forms:

| `--view=` | Means |
|---|---|
| `git-status:` | Working tree: staged, unstaged, and untracked |
| `git-diff:<a>...<b>` | Three-dot range — `<b>` against the merge base |
| `git-diff:<a>..<b>` | Two-dot range, handed to git verbatim |
| `git-diff:<sha>` | That ONE commit's changes (`git show`, first-parent for merges) |
| `git-diff:` | This branch against `origin/HEAD`, else `main`/`master` |

A bare revision means *that commit*, not "diff against it" — `git-diff:abc123`
answers "what changed in abc123". Use `a..b` when you mean a comparison.

- **Which repository**: the one containing `--working-directory` (else the
  caller's cwd, which `+split`/`+new-window` insert for you), resolved with
  `git rev-parse --show-toplevel`. A directory in no repo renders an
  explanatory card, not a blank pane.
- **The file tree is the table-of-contents card**, not a lookalike: same glass
  card, same pinned header, same row metrics and macOS selection pill, same
  gutter⇄overlay switch at 720pt, same drag-to-resize handle and shared width
  preference (`ViewerSidePanel` owns all of it). What it adds is a **filter
  field pinned under the header** — terms are ANDed against the whole path, a
  non-empty filter flattens the tree to a hit list, Return opens the top hit,
  Escape clears it — plus folder/file hierarchy with git's own status letter
  (A/M/D/R…) and each file's `+N −M`. Chains of single-child directories
  collapse into one row (`macos/Sources/Features/Viewer`), and clicking a
  folder folds it.
- **Working-tree sections**: staged, unstaged, and untracked are three lists,
  in that order, because which changes are staged is the thing `git status`
  exists to tell you. A file modified both staged and unstaged appears in both
  (they are different diffs), and clicking each shows that side.
- **Scale**: the file list is eager (one `--numstat`/`--name-status` pass —
  cheap for thousands of files) and each file's PATCH is fetched only when its
  row is clicked. Rows are appended to the page in chunks across frames, with
  a 20 000-row cap and a "Show the rest" button past it. Binary files and
  unreadable ones render a stub, never a hang. All git work runs off the main
  thread.
- **Rendering** is hand-rolled over parsed unified hunks (no new vendored
  dependency, zero added bundle weight) on the already-bundled highlight.js.
  Each hunk is highlighted as two contiguous texts — the old side and the new
  side — rather than line by line, so a block comment or template literal is
  not restarted on every row, and the result is split back into lines with the
  open tags carried across the break. Paired removed/added lines get an
  **intra-line word highlight** so a one-character change reads as one
  character. Deliberately NOT Monaco: this pane is read-only, and a
  multi-megabyte editor would blow up an offline bundle to lose on scroll
  performance.
- **Unified vs side-by-side**: unified is one column with sticky line-number
  gutters and horizontal scroll (code keeps its shape); side-by-side is a
  four-column CSS grid, so a pair stays aligned even when a long line wraps.
  The choice is a preference in defaults, shared by every diff pane.
- **Next/previous change** steps *change blocks* (a `@@` hunk can hold
  several), and rolls over into the adjacent FILE when the open one runs out —
  entering it at its first or last change so walking a diff reads continuously.
  It steps from a remembered index, not from the scroll position, so a fast
  double-press advances twice instead of re-picking the change the smooth
  scroll has not reached yet; your own next scroll hands it back.
- **Live**: a `git-status:` pane re-checks the working tree every 2s and
  updates only when the file list actually moved, so an edit or a `git add` in
  another pane shows up without a reload and without a flicker. A commit or a
  range is a fixed pair of trees and is not polled.
- The nav bar **stays pinned open** in a diff pane (it carries the change and
  layout controls, and shows the revspec).

### Worktree feedback capture

When a viewer pane's content can be attributed to a **git worktree**, its
navigation bar gains a **feedback button** (labeled with the worktree's
basename, full path on hover) that opens a composer toolbar below the nav bar.
On send it writes a report — plus any pasted screenshots — into
`<worktree>/temp/feedback/new/` for an external watcher to drain (Ghoztty produces
the queue; consuming it is separate and not built here).

- **Provenance (strategy D — port lookup first, pane-origin fallback).** The
  worktree is derived live from the pane's *current* location, re-resolved on
  every navigation (a pane can move between a file, `localhost:3000`, and a
  remote site, each a different worktree or none):
  1. **File viewers** → the viewed file's own directory.
  2. **`http://localhost:PORT` / `127.0.0.1` / `0.0.0.0` viewers** → the port's
     listening pid's cwd, via `lsof` (`-iTCP:<port> -sTCP:LISTEN -t`, then
     `-p <pid> -d cwd -Fn`) run off the main thread. lsof, not
     `proc_pidinfo`, because there is no port→pid syscall.
  3. **Fallback** (remote site, blank pane, or a port with no listener) → the
     pane's **origin directory**: `--working-directory` at `+split --view=` /
     `+new-window --view=` time, else the caller's cwd. `+split` now seeds the
     caller's cwd as `--working-directory` for `--view=` splits (terminal
     splits are unchanged so cwd inheritance still works). The origin is
     persisted in the session manifest (`viewerOriginDirectory`).

  Whatever directory results is resolved to a repo root via `git -C <dir>
  rev-parse --show-toplevel` (**any** working tree counts — a linked worktree
  or the main checkout). No repo ⇒ no feedback button. Resolutions are cached
  per (location, origin) for 15s so navigation never stutters and a dev server
  started later still makes the button appear.
  **Windows has all three legs and the button** (T633, T638): the strategy, the
  classification and the 15s cache are `src/apprt/win32/viewer_worktree.zig`
  (pure, asserted in the none lane), and the `git rev-parse` runs on a worker
  thread that posts `WM_APP_VIEWER_WORKTREE` back at the pane —
  `ViewerWorktreeProbe.zig` — because the viewer's message loop is the one the
  terminal next door draws on. Leg 2's translation of `lsof` is
  `GetExtendedTcpTable(TCP_TABLE_OWNER_PID_LISTENER)` for the listening pid
  (`src/os/listening_pid.zig`, both address families) and the PEB walk
  `src/os/process_cwd.zig` already does for that pid's working directory —
  Windows exposes no documented API for another process's cwd, and the
  alternative on offer, guessing from its command line, is exactly the
  confidently-wrong answer the report format avoids everywhere else. Both are
  syscalls against an untrusted process, so they ride the SAME worker as git:
  `viewer_worktree.plan` settles legs 1 and 3 on the message loop (string work)
  and hands a `.port` plan to the worker. Every failure — no listener, another
  user's process, a pid that exits mid-lookup — degrades to leg 3, never to a
  wrong repo. Acceptance: `test/win32/viewer-worktree.ps1` (legs 1 and 3) and
  `test/win32/viewer-worktree-port.ps1` (leg 2).

  The button is **icon-only**, in the same 24pt square as the other chrome
  controls; the destination is on its tooltip and in the composer footer.
- **Composer.** A **pill** that grows with its content (one line up to ~6),
  with two **circular buttons inside its trailing edge**: `+` takes an
  interactive screen snapshot (`screencapture -i -o` to a temp file — never
  `-c`, which would clobber the user's clipboard), and `↑` sends. `Enter`
  inserts a newline, `Cmd-Enter` sends, `Escape` closes.
  **Windows has the composer's chrome** (T634): the same pill and the same two
  circular actions, opened and closed by the same button, with `Ctrl+Enter` for
  Mac's `Cmd-Enter`. It is a native owner-painted child window under the nav
  bar — the page is inset by its band and gets the space back as the pill
  shrinks — and the nav bar stays pinned open while it is up, since the button
  that closes it lives there. The pill is a **capsule**, a named exception to
  the win32 radius scale (design system §3.1), with the radius pinned to the
  collapsed height so a six-line pill does not become an oval. Geometry:
  `src/apprt/win32/viewer_feedback_layout.zig` (asserted at 1.0/1.25/1.5/2.0);
  chrome: `ViewerFeedbackBar.zig`; acceptance: `test/win32/viewer-feedback.ps1`.
  **The composer's TEXT and its open flag live on the pane, not on the toolbar
  window**, which is what makes contents survive a close/reopen on both
  platforms. The win32 editing surface is a **RichEdit** (`Msftedit.dll`,
  class `RichEdit50W`) filling the pill's text rect — D43's answer, landed in
  **T635** — so caret, selection, word wrap, undo, clipboard and IME
  composition come from the OS rather than from a hand-rolled model. The
  control is the storage while the composer is open and every change mirrors
  back into the pane from `EN_CHANGE`; the pane is still what outlives the
  window. Three win32 details worth knowing: RichEdit sends **no** notifications
  until `EM_SETEVENTMASK`/`ENM_CHANGE` asks for them; it does **not**
  answer `EM_SETCUEBANNER`, so the empty composer's placeholder is painted by
  a subclass over the control's own `WM_PAINT`; and the mirror reads the
  control with `EM_GETTEXTEX`/`GT_DEFAULT` rather than `WM_GETTEXT`, because
  the latter expands each paragraph mark to CR+LF and every quote offset the
  composer computes has to index the control and the pane's buffer the same
  way.
  **The composer's two indexings are BYTES and CODE UNITS, and it converts
  between them** (T648). Every pure module here works in byte offsets into the
  pane's UTF-8 buffer — which is right, since that buffer is what the report is
  written from — and every edit message (`EM_EXSETSEL`, `EM_EXGETSEL`,
  `EM_POSFROMCHAR`) works in UTF-16 code units. Those agree **only for ASCII**:
  `é` is 2 bytes and 1 unit, an emoji is 4 bytes and 2 units. Handed straight
  across, a quote or an image chip landed short by the accumulated difference —
  silent corruption of what the user wrote, invisible to anyone typing plain
  English. So a `CHARRANGE` is never filled from a byte offset directly: it
  goes through `ViewerFeedbackBar.charIndex`, and a number out of the control
  goes through `.byteOffset`, both over the pure `utf16_offset.zig`. The
  conversion has exactly ONE home — the address bar and the banner editor only
  ever `EM_SETSEL(0, -1)`, so they compute no offset to get wrong. Line endings
  need no conversion (see `GT_DEFAULT` above); the encoding does. Acceptance:
  `test/win32/viewer-feedback-utf16.ps1`, whose every arm compares the WHOLE
  composer text — its first draft used a `[Image` substring needle and passed
  against a deliberately broken build that had left `[Imag` behind.
  **Send files the report on Windows too** (T636): `↑`/Ctrl+Enter writes the
  same folder into the same queue, off the UI thread on a worker
  (`ViewerFeedbackSend.zig`) because two `git rev-parse` spawns and a source
  file read have no business on the message loop the terminal next door draws
  on. The format, the `sourceLine` resolver and the staging+rename publish are
  pure and asserted in the none lane
  (`src/apprt/win32/viewer_feedback_report.zig`). Two Windows-shaped details:
  the folder stem is `yyyymmddTHHMMSSZ-<6 hex>` because NTFS reserves `:`, so
  a naive port of Mac's ISO-8601 stem cannot be a directory name here at all;
  and the **selection** is TRACKED as it changes by the injected blob
  (`viewer_bridge.selection_tracker_js`, debounced and capped) rather than
  asked for at send time, so the send stays synchronous and a page that never
  answers costs a missing field instead of a stranded composer (D48). The
  revision is resolved on the SEND rather than cached with the worktree (D47),
  so a pane left open across a branch switch still names what the user saw.
  What Windows does not have yet: the long-lived DRAFT staging folder and its
  footer link (**T645**); the quoted block landed in
  **T641** (below), the image half of the composer in **T637**, its
  thumbnail carousel in **T646** and the screenshot capture in **T647**.

  **The `+` button takes a screenshot on Windows too** (T647), and it is
  D44's answer rather than a translation: the two obvious Windows equivalents
  (`ms-screenclip:`, `SnippingTool /clip`) publish their result through the
  CLIPBOARD, which is the one thing Mac's `screencapture -i -o` comment
  forbids. So Ghoztty draws its own region selector. The desktop is
  photographed ONCE before the overlay exists (`screen_capture.zig`:
  `BitBlt` + `CAPTUREBLT` of the whole virtual screen into a top-down 32bpp
  DIB, so layered chrome is in the shot and the origin may be negative); a
  darkened copy of that photograph is what the full-desktop opaque popup
  paints (`RegionSelector.zig`), with the original showing bright inside the
  drag rectangle; mouse-up crops the original. Nothing on the path opens the
  clipboard. **Ctrl+Shift+S** is Mac's ⇧⌘S while the composer has focus.
  Escape, a right-click, losing activation, and a click with no drag all
  cancel — a zero-area drag is a cancel, never a zero-pixel picture. Rect math
  and the hint card's geometry are pure (`region_select.zig`, asserted at
  1.0/1.25/1.5/2.0); every input is read out of a message's `lparam` rather
  than from `GetCursorPos`, which is what lets the acceptance script POST a
  drag on a desktop where `SendInput` is dead. Acceptance:
  `test/win32/viewer-feedback-capture.ps1`.

  **The region can be selected from the keyboard alone** (T671) — a chord that
  starts a capture nobody can finish without a mouse promises a keyboard path
  that is not there. **Arrows** move a caret (starting in the middle of the
  monitor you are on), **Ctrl+arrow** steps 32 px so crossing a 4K screen is not
  a marathon, **Enter** pins the first corner and **Enter** again captures,
  **Shift+arrow** is the shortcut that does both in one press, and **Escape**
  still cancels. Keyboard and mouse drive the SAME `anchor`/`cursor` pair
  (`region.moveCaret` / `dropAnchor`, pure), so they interleave freely, and a
  plain arrow never collapses a selection the way a text caret would — losing a
  rectangle you spent thirty presses framing has no undo anywhere in the
  gesture. Modifiers are tracked from the `WM_KEYDOWN`/`WM_KEYUP` of `VK_SHIFT`
  and `VK_CONTROL` rather than read with `GetKeyState`, for the same reason
  coordinates come from `lparam`: a posted message carries no key state, so a
  `GetKeyState` Shift would be unreachable from the harness and therefore
  untested. `begin` seeds the pair once, because Ctrl+Shift+S is itself a chord
  still held when the overlay appears. The live caret position and selection
  size are **announced, not just drawn**: they go into the hint card AND into
  the window's text, which is the name assistive tech reads — and, not by
  accident, the only oracle a background-desktop script has for painted text.
  Pasting a screenshot inserts an **`[Image #N]` chip** — one atomic
  `NSTextAttachment` (a single `U+FFFC` character), so it selects, copies, and
  deletes (one Backspace) as a unit. A **thumbnail carousel** below the input
  mirrors the chips; clicking a chip scrolls to its thumbnail and vice versa.
  **Chip numbers are stable, not positional** — deleting `[Image #2]` leaves
  the sequence 1, 3 in both the text and the carousel (never renumbered), so a
  number always points at the same image. Composer contents survive
  toggling the toolbar closed/open and a detach/undo (they live on the pane,
  not the toolbar).

  **Windows pastes pictures too** (T637), by the same two rules and with the
  same consequences. A chip there is literally the characters `[Image #3]` —
  RichEdit has no attachment run to hang an image off, the same hole quoting
  works around — so the NUMBER is the identity and the report's `images` array
  is derived by scanning the composer text for chips, exactly as `quotes` is
  derived by scanning it for passages. Delete a chip and its picture leaves the
  report; nothing has to be told about the deletion. Atomicity is restored by
  hand: Backspace or Delete against a chip selects the whole run first, because
  eating the `]` alone would leave text that still LOOKS attached and no longer
  parses (`src/apprt/win32/viewer_feedback_images.zig`, pure and asserted in
  the none lane).
  The paste path has Mac's `readablePasteboardTypes` trap in win32 dress: a
  RichEdit asks the clipboard for text and nothing else, so an image-only
  clipboard would paste as silence. The composer therefore asks first
  (`clipboard_image.zig`), preferring the registered **`"PNG"`** format — which
  browsers publish and which is copied **byte for byte**, never re-encoded —
  then `CF_DIBV5`/`CF_DIB`/`CF_BITMAP`, which are normalised through one
  `StretchDIBits` into a 32-bit top-down DIB section (GDI already knows every
  palette, mask and row order; `dib_packed.zig` supplies the one thing it will
  not, where the pixels start inside the packed block) and encoded by
  `png_encode.zig`. That encoder is **pure** — `std.compress.flate` produces
  the zlib stream `IDAT` is defined as, so there is no new vendored dependency
  and no COM on the paste path, and it asserts against a decoder written in its
  own test rather than against itself. Alpha is dropped on the normalised path
  (a clipboard DIB's fourth byte is routinely all zeroes, and honouring that
  turns a good screenshot into a blank one). Acceptance:
  `test/win32/viewer-feedback-images.ps1`.

  **And Windows has the carousel** (T646): a row of square tiles under the pill,
  one per live chip, with the two-way sync. It follows the same
  derive-from-storage rule as everything else in the composer — the strip holds
  no list of its own, it is `Store.carousel(text)`, the set the report's
  `images` array comes from — so a deleted chip's thumbnail disappears with no
  second bookkeeping path to get wrong. Three win32-shaped details: the row and
  its gap **cost nothing when there are no images**, so a composer nobody
  pasted into is exactly as tall as it was before (geometry in
  `viewer_feedback_layout.zig`, asserted at 1.0/1.25/1.5/2.0 with the scroll
  clamp and the hit test); a tile is **letterboxed, never stretched or
  cropped**, because a cropped thumbnail of a screenshot is a thumbnail of its
  middle; and tiles are decoded once through `gdiplus_decode.decodeBytes` and
  **cached by (chip number, tile size)**, which is why filing a report has to
  tell the bar its store was reset — the number sequence restarts at 1 and the
  cache would otherwise paint the picture that was just sent. The sync is a
  click on a tile → `EM_EXSETSEL` over its whole chip, and a caret inside a chip
  → that tile ringed and scrolled into view (the caret side rides `EN_CHANGE`
  plus the RichEdit subclass's post-dispatch hook, since RichEdit only notifies
  what it is asked to). Acceptance:
  `test/win32/viewer-feedback-carousel.ps1`.

  **⇧⌘S** adds a screenshot from the keyboard while the composer has focus
  (free: the app's shift+cmd letters are t/z/w/d/f/g/v/n/r/[/], and macOS's own
  capture shortcuts are ⇧⌘3/4/5).

  The text view **must** override `readablePasteboardTypes` to include image
  types. AppKit validates the Edit▸Paste menu item against that list, so
  without it Cmd-V is *disabled* for an image-only clipboard and the paste
  override never runs — a silent no-op. `importsGraphics = true` does **not**
  add those types; only the override does.
- **Quoting.** Selecting text in a viewer pops a small **Quote / Copy**
  toolbar (standard `format_quote` / `content_copy` glyphs) above the
  selection. It lives in `src/viewer/selection.js` and is injected as a
  **`WKUserScript` into every page** — it cannot ship inside `viewer.js`,
  which is a `<script src>` in `viewer.html` and therefore only ever runs on
  the bundled template, which is why quoting used to work on markdown and do
  nothing on a website. Because it runs inside pages we do not control, its UI
  lives in a **shadow root** so page CSS cannot restyle or hide it. *Copy* puts it on the clipboard; *Quote* opens
  the composer (if closed) and inserts the passage at the caret as its own
  block — indented, with a tinted panel and an accent bar down the left, drawn
  in `drawBackground(in:)` (a background-color attribute paints only tight line
  boxes, with no bar and no rounding). The run carries a `feedbackQuoteID`
  attribute, so deleting it drops its metadata from the report — the same
  derive-from-storage rule the image carousel uses. The body renders it as a
  real markdown blockquote. Typing never inherits quote styling: AppKit
  carries `typingAttributes` over from text around the caret *including text
  just deleted*, so select-all + delete + type used to leave the user trapped
  writing inside the quote (and resurrected its metadata). The delegate
  refuses quote attributes at the source.

  **Windows has the same two-button toolbar and the same quoted block** (T641).
  Quote used to be hidden here (`window.__ghozttyHideQuote`, set by the
  injected blob) because there was nowhere to put the text; T635 built the
  composer and that flag is gone, so the shared `selection.js` now ships both
  buttons on both platforms. What differs is only how identity survives an
  edit: RichEdit has **no per-run user field** to hang a `feedbackQuoteID` on,
  so a quote is recovered from the TEXT — a registry entry is live when its
  passage still occupies a **complete run of lines** at or after the previous
  quote's end (`src/apprt/win32/viewer_feedback_doc.zig`, pure and asserted in
  the none lane). Same consequence as Mac's: delete the block and its metadata
  leaves the report, quote the same passage twice and you get two quotes; plus
  one Mac does not have — *editing* a quote's characters drops its context,
  which is the honest answer once the text is no longer the passage the
  context describes. The block is drawn with a wash (`CFM_BACKCOLOR`), a
  paragraph indent (`PFM_STARTINDENT`) and a **hand-painted accent bar**,
  because RichEdit's background colour paints tight line boxes with no bar —
  the same limitation that makes Mac draw its own. The typing trap has a win32
  spelling too: RichEdit carries character formatting forward from the
  character before the caret, so the composer resets typing attributes to
  plain **before** each `WM_CHAR`/paste/Enter that lands outside a quote.

  Each quote carries **referential context** so an agent can find what was
  being discussed (text alone is ambiguous — the same sentence can appear
  twice): the containing section's `headingId`/`headingText`, the containing
  block's `blockSelector` and full `blockText`, `offsetInBlock`,
  `documentOffset`, and — for file viewers — a 1-based **`sourceLine`**,
  resolved natively at send time by searching the file for the passage
  (mapping rendered DOM back to markdown source is unreliable; searching is
  not). It reports nil rather than a confidently wrong line.
- **Report output.** One **self-contained folder per submission**, so a report
  can be moved or handed to an agent as a unit:

  ```
  <worktree>/temp/feedback/new/<timestamp>-<suffix>/
      report.json
      images/image-1.png
  ```

  The whole folder is built under `temp/feedback/.staging/` and moved into place
  with a single **atomic `rename`** (same filesystem), so a watcher sees either
  nothing or a complete report with every image already present. Promoting one
  to an `in-progress/` queue is likewise a single `mv` — image paths in the
  report are folder-relative, so they survive the move. On Windows the rename is
  `std.fs`'s `MoveFileExW` **without** `MOVEFILE_COPY_ALLOWED`, so a staging
  area that somehow ended up on another volume fails loudly rather than
  degrading into the non-atomic copy this design exists to avoid.
  The queue lives under **`temp/`** because that name is already gitignored
  here (`.gitignore`) and conventionally elsewhere; a top-level `.feedback/`
  was not, so every filed report showed up as untracked in `git status`.
  **Format is JSON** (not markdown-frontmatter: a multi-line prose body with a
  `---` or `key:` line breaks naive frontmatter splitting; JSON has one parse
  path). `body` is markdown with each chip rendered as a
  `![Image #N](images/image-N.png)` reference relative to the folder.
  Alongside it, deliberately generous context so a downstream agent needn't ask
  follow-ups: `source` (`location`, `kind`, `filePath`, **`relativePath`** —
  repo-relative, `pageTitle`, **`selection`** — the text the user had selected,
  i.e. what they were pointing at, `paneID`, `viewport`), `worktree` (`path`,
  `name`, **`branch`**, **`commit`** — the exact revision they saw), `app`,
  `quotes` (see above), and `images` (with pixel dimensions and byte size). On success the composer
  clears and the toolbar shows a "Filed …" confirmation before closing.
  Absent optionals are **dropped, not written as `null`** (Swift's
  `JSONEncoder` omits a nil property, and the win32 writer matches it), so a
  report written on either platform has the same key set for the same content.
  The JSON keys are the contract and are spelled exactly as Mac emits them —
  `paneID` with a capital D and `headingId` with a small one, which disagree
  with each other and stay that way, because the watcher reading them is shared.

## Session Persistence

Terminal processes can be made independent of the GUI app so they survive app
crashes, quits, and binary upgrades (and relaunch across reboots / agent
crashes). It is **on by default** (disable with `session-persistence = off`).

- `session-persistence = off|on` (macOS + Windows, default `on`). When `on`, new local
  windows/tabs/splits run their shell under the local `ghoztty-agent` (found or
  spawned on demand) instead of directly under the app process, so the child
  processes outlive the app. On next launch the app re-attaches: layout, split
  ratios, titles, working dirs, and gap-filled scrollback come back with the
  **same PIDs** (no restart) as long as the agent stayed alive.
- `session-relaunch = notify|auto|prompt` (default `notify`). Only matters across
  an **agent** restart (reboot / agent upgrade), where the child is gone but its
  metadata was materialized from disk as a relaunchable tombstone.
  **A recorded command is never re-executed by default** — it was recorded in a
  world that no longer exists, and nobody asked for it twice.
  - `notify` (default) — the pane comes up on a **fresh shell** in the session's
    recorded working directory (a missing directory falls back to `$HOME` /
    `%USERPROFILE%` rather than failing the pane), with a notice above it
    naming the command that WAS running so it can be copied and re-issued
    deliberately. The notice is written **twice on purpose**: as selectable
    terminal text, and as a sticky **pane banner** — a ConPTY shell's startup
    repaint (cmd.exe's `ESC[H ESC[2J`) erases the former, and the banner is the
    copy that survives it. The dead tombstone is retired (fire-and-forget
    `CLOSE_SESSION`) so it does not accumulate in `sessions.json`.
  - `auto` — respawns the recorded command in-place with a
    `--- session restarted ---` divider.
  - `prompt` — leaves the pane in its exited state for the user to decide.

  E2E: `test/win32/session-relaunch-notify.ps1`.

**A refused pane says why, immediately** (T469). When the agent will not open a
session — it is at its live-session cap, it is out of memory, or the shell/
command could not be spawned at all — it answers `OPEN_FAILED` (0x06,
`{reason, detail}`) instead of dropping the request, and the pane paints a
plain-words message naming the cause and what to do about it. Before this there
was no frame for "I will not open this": the app's parked OPEN waited out its
full 10 s `rpc_open_timeout_ns` and then blamed `error.Timeout` and "exhausting
a system resource" — a sentence true of no failure a user can act on. Because
by-type OPEN RPCs serialize on one mutex, a window of N panes paid that 10 s N
times, in turn, for panes that were never coming.

- `reason` is a **stable machine token** (`session_cap`, `spawn_failed`,
  `out_of_memory`, `malformed_request`), never prose, and the app owns the
  sentence — the agent outlives the app talking to it, so an agent that shipped
  wording would pin the text to whichever build happens to be resident. An
  unknown token from a newer agent renders a generic sentence rather than being
  echoed raw or dropped. Mapping: `src/termio/open_failed_notice.zig` (pure,
  asserted in the none lane); the paint is `termio.Thread`'s existing failure
  path, which a backend can now pre-empt via `Backend.bringUpNotice()`.
- Capability-gated on `open_failed`, because a new opcode is a **fatal framing
  error** to a peer that does not know it. Both skew directions degrade to
  exactly the pre-T469 behavior (silence, then the client's own timeout, then
  the generic message) — never a garble, never a wedge.
- Two agent test seams make the refusal reproducible from one tree, which is
  why this path shipped silent for as long as it did:
  `GHOSTTY_AGENT_MAX_SESSIONS=<1..256>` (also `--max-sessions`) lowers the live
  cap so two panes reach a genuine `error.TooManySessions`, and
  `GHOSTTY_AGENT_SUPPRESS_CAPS=<comma list>` makes this binary advertise an
  older agent's HELLO so the fallback can be watched happening. The app spawns
  the agent with an inherited environment block, so both reach the agent an
  acceptance script never launches itself. Empty/default in every real agent.
- Acceptance: `test/win32/agent-open-refused.ps1` (control / fast refusal /
  skew).

**And a pane that cannot RE-JOIN its session says why too** (T657) — the resume
half, which is the one a user meets after a reboot, an app upgrade, or picking a
session out of the chooser. It used to arrive at the pane as a bare
`error.RemoteAttachFailed` and paint the same "exhausting a system resource"
text. It is two mechanisms, split by what each can carry, and the split is the
design:

- **The reason for `not_found` / `dead` / `attached_elsewhere` is derived on the
  CLIENT** from the `AttachStatus` the agent already sends. Those are complete
  answers that arrive in milliseconds and have on every agent that ever shipped,
  so the sentence needs **no capability and no wire change** and works against an
  agent of any age. Mapping: `src/termio/attach_failed_notice.zig` (pure,
  asserted in the none lane), out through the same `Backend.bringUpNotice()`
  seam. Deliberately NOT re-stated on the wire: two spellings of one fact across
  a compatibility boundary is what the agent contract exists to prevent, and it
  would strand every caller that reads `AttachOutcome.status` (the chooser,
  Restore All) behind a new error.
- **`ATTACH_FAILED` (0x07, `{reason, detail}`) covers only what `ATTACHED`
  cannot express** — today a payload the agent could not parse, which was the
  one genuinely silent ATTACH path and did cost the client the full 10 s.
  Capability-gated on `attach_failed` for the same fatal-framing reason as 0x06,
  degrading in both skew directions to exactly the pre-T657 silence-then-timeout.
  Client entry point: `Connection.attachChannelRefusable` → `error.AttachRefused`
  with a `protocol.RefusalCopy` (the verb-neutral rename of `OpenFailedCopy`,
  now that both refusals share it).
- **Reachability needed a seam**, for the reason T469's two did. The win32
  launch restore probes the agent's roster first and gives a leaf whose session
  is not listed a null id, so it OPENs fresh rather than ATTACHing (T89g) —
  which leaves this failure to the case where the probe DID NOT LAND (a slow or
  wedged agent past `restore_probe_timeout_ns`). `GHOZTTY_RESTORE_PROBE_UNKNOWN=1`
  forces that liveness tri-state to UNKNOWN and changes nothing else, so the
  branch is reproducible instead of racy. Unset in every real launch.
- Acceptance: `test/win32/agent-attach-refused.ps1` (live-restore control /
  fast named refusal / the same message against a suppressed capability).

**A launch command and a restore both happen.** `ghoztty -e <cmd…>` (or a
`command`/`initial-command` in the config) asked for something on THIS launch;
the windows restore rebuilds are what the user left behind. Neither silently
swallows the other: the requested window is opened **first**, then restore
rebuilds the rest, and the requested window is raised back to the foreground
afterwards. Opening it first is not cosmetic — core `Surface.init` hands
`initial-command` to whichever surface is `app.first`, and a restored pane would
otherwise consume it and have nowhere to run it (it ATTACHes to a session that
already exists), which is how the command used to vanish with no window, no
error and no log line (T406). Acceptance: section D of
`test/win32/gui-launch-command.ps1`.

Session lifecycle: a process DIES when the user closes its pane/tab/window (or
`+close`s it — the CLOSE lands when the close's undo window expires), when the
shell itself exits, or when the agent dies (children then relaunch as
tombstones per `session-relaunch`). It SURVIVES app quit/crash/upgrade (quit
never prompts for persistent windows — their sessions re-attach on relaunch).
E2E: `scripts/e2e/session-persistence.py` (incl. `--winsize` for re-attach
PTY-geometry integrity).

The agent owns the PTYs, keeps a per-session output ring (2 MB default;
snapshotted to disk for reboot scrollback), persists session metadata to
`sessions.json`, and is packaged as a per-user LaunchAgent so it comes back
after a crash/reboot. The app dials it over a 0600 AF_UNIX socket
(`~/.config/ghoztty/local-agent[-debug]/agent.sock`) with a same-uid peercred
check. Use `+sessions` (above) to enumerate live sessions directly from the
agent, even when the app is not running. On Windows the same design holds
with native swaps: the agent (`ghoztty-agent.exe`, shipped as a required
sibling of `ghoztty.exe`) owns ConPTYs, is dialed over the owner-only-DACL
named pipe (see `+sessions`), keeps its state under
`%LOCALAPPDATA%\ghoztty\local-agent[-debug]\`, and the reboot-comeback analog
of the LaunchAgent is an HKCU Run entry (`GhozttyAgent`) the GUI
writes/refreshes when persistence engages. Design + measured E2E results:
`docs/design/session-persistence.md`; E2E harness: `scripts/e2e/session-persistence.py`.

### Browsing and resuming sessions from the chooser

The machine chooser (Cmd-Shift-N on macOS, Ctrl+Shift+N on Windows) is where a
machine's live sessions are browsed and taken over. Select a machine and its
**session roster** appears in the detail pane — one card per connectable
session, with its title, working directory, activity state and a Kill control.
From there:

- **Resume one** — Right steps the keyboard cursor into the roster, Up/Down walk
  it, and Return opens a window here whose pane **ATTACHes** to that session
  (the process keeps running on its own machine; only the viewer is local). A
  session already open in one of your panes is focused instead of attached
  twice. Dead-but-relaunchable rows are listed — their recorded command is worth
  seeing — but cannot be resumed; reviving one is a RELAUNCH, a different verb.
- **Restore All** — rebuilds the machine's *whole* window/tab/split topology
  here, every pane attached to its still-running session. The button appears
  only when the selected machine has **two or more live sessions**: with one
  there is no topology to rebuild and Resume already covers it. The layout comes
  from the blobs the **agent** holds, not from the local `session-layout.json`,
  which is what makes it work after a crash that lost the manifest — precisely
  when launch-time restore can do nothing. Pointed at a **remote** machine it
  dials that machine for the layouts and gives **every rebuilt window its own
  connection** (a Windows detail with no Mac analog: a win32 window owns its
  transport and frees it on close, so one shared dial would die with the first
  window closed). A frame authored on the far machine's monitors is re-clamped
  onto a visible local one; a window whose sessions are already open here is
  skipped rather than attached twice.

Both work **cross-machine on macOS and Windows** — browse a relay machine's
roster, resume one session or rebuild the whole topology locally. Cross-machine
Resume shipped on macOS 2026-07-16; on Windows, browse/Resume-one landed with
T318–T320 and cross-machine Restore All with T336 (2026-08-02).

**Restore All across LINEAGES** (a Mac machine restored on Windows) works as of
T337, and it works by translation rather than by agreement. The layout blob the
agent stores is opaque to it, so its schema is a contract between two viewers —
and the two never shared one: macOS writes a camelCase
`SessionLayoutManifest.Entry`, one blob per TAB, with a nested `tree`; win32
writes a snake_case `session_layout.Window`, one blob per WINDOW, with a flat
indexed `nodes` array. There is no lineage tag to switch on and there cannot be
one retroactively — the blobs already in a live agent were written before any tag
could exist. So the READER identifies a blob by shape (`tree` vs `tabs`) and
converts the other lineage's into its own (win32:
`src/apprt/win32/mac_layout_blob.zig`; the Mac half is T622), skipping — never
failing on — anything it still cannot read. Two things deliberately do not
survive the trip: the WP-D3 screen snapshot (another viewer's stale screen must
never be painted into a restored pane) and the window ORIGIN (Cocoa measures y
up from the bottom-left and the blob records no source-screen height, so it is
passed through and re-anchored if it lands off-screen — T623). Full contract:
`docs/design/session-persistence.md` §5.4.2. Acceptance:
`test/win32/layout-blob-cross-lineage.ps1`.

### Agent contract & upgrade compatibility

The `ghoztty-agent` outlives the app on purpose (per-user LaunchAgent; survives
quit/crash/upgrade). The direct consequence: **a running agent is frequently a
DIFFERENT build than the app talking to it** — an app upgrade replaces the app
binary while the old agent process keeps running with every PTY attached. The
app↔agent wire contract is therefore a **compatibility boundary.** Forward
compatibility across it is the **default and strongly preferred** path; a
breaking change is allowed but only as a *conscious* decision routed through the
mandatory agent-update process (below), never as an accident. What is never
acceptable is an *unhandled* skew — garbled output, a wedged socket, or a crash.
Treat this boundary with the same care as an on-disk format or a public API.

Rules for any change to the agent↔app protocol (messages, fields, framing, the
ring/snapshot/gap-fill replay, HELLO handshake):

- **Old agent + new app MUST keep working, and new agent + old app MUST keep
  working.** Neither side may assume the peer is its own build. A skew must
  degrade to reduced function, never to garbled output, a wedged socket, or a
  crash. (The 1.14.0 re-attach corruption — new app replaying an old agent's
  scrollback into smeared, non-interactive panes — is exactly the failure this
  rule exists to prevent.)
- **Evolve additively.** New messages and new fields only. Never change the
  meaning, type, or framing of an existing message or field, and never remove
  one that an older peer still sends or expects. Readers ignore unknown fields
  and tolerate absent ones (fall back, don't fail). A field that goes missing
  because the peer is older must degrade gracefully — the way agent-side
  pid/tty already reports null to an app that doesn't understand it.
- **Detect capability at runtime — never at compile time.** Attach begins with
  a **HELLO handshake** that exchanges a protocol/capability version so each
  side negotiates behavior from what the peer *actually* advertises, not from
  what this build happens to ship. Gate every new behavior on the negotiated
  capability, and document each protocol version and what it added in the agent
  protocol source so the compatibility matrix is checkable at runtime and in
  review.
- **Breaking changes are allowed — deliberately, never accidentally.** Forward
  compatibility is the default because it's the cheapest path (no disruption),
  but a break is a legitimate tool when additive evolution would be worse. What
  makes a break acceptable is that it is *conscious* and *backed by the
  mandatory agent-update process* — not that it's forbidden. When you break the
  contract: bump the protocol version, and on an incompatible skew the app must
  NOT replay across it. Instead the mandatory-update mechanism takes over:
  - **Prefer a lazy, non-destructive agent upgrade.** Carry sessions across by
    upgrading the agent when it is safe — on idle, or as each session naturally
    closes — draining/snapshotting and resuming so no work is lost, then proceed
    with the app upgrade transparently. This is what makes most breaks painless.
  - **When a session cannot be carried across**, show a **mandatory, explicit
    confirmation before resetting**: *"Upgrading will reset all windows.
    Continue?"* Never silently reset live sessions, and never silently replay
    across a version the handshake flagged as incompatible.

  The mandatory-update process is the safety net that makes breaking changes
  survivable; the HELLO handshake is what lets us detect when we need it. Build
  and keep both robust, and a breaking change becomes a conscious, bounded cost
  rather than a corrupted-session incident.

Design + status: `docs/design/session-persistence.md`.

## Build, run & debug

Both platforms build from the same `zig build`; what differs is the app runtime
(`-Dapp-runtime`, which defaults to `none` on macOS and `win32` on Windows) and
what comes out the other end. **The installed app is the user's primary
terminal on both platforms — never test against it.**

### macOS

```bash
zig build -Doptimize=Debug      # -> zig-out/Ghoztty-Debug.app (xcodebuild)
open -na zig-out/Ghoztty-Debug.app
```

- **NEVER modify, replace, copy over, or touch `/Applications/Ghoztty.app` in
  any way.** Always test with the debug build at `zig-out/Ghoztty-Debug.app`.
  The debug build uses a separate socket (`ghostty-debug-<uid>.sock`) and a
  separate bundle identifier, so it runs alongside the release app.
- IPC endpoint: `$TMPDIR/ghostty[-debug]-<uid>.sock`.
- Logs: `sudo log stream --level debug --predicate
  'subsystem=="com.dzearing.ghoztty"'`.
- Swift frontend sources live in `macos/`; `zig build` drives `xcodebuild` for
  them (`src/build/GhosttyXcodebuild.zig`).

### Windows

```powershell
$env:ZIG_GLOBAL_CACHE_DIR = 'D:\zig-global-cache'   # MUST be on the repo's drive
zig build -Dapp-runtime=win32 -Doptimize=Debug      # -> zig-out\bin\ghoztty.exe
.\zig-out\bin\ghoztty.exe
```

- **`ZIG_GLOBAL_CACHE_DIR` must sit on the same drive as the repo.** Across
  drives, `std.fs.path.relative` returns an absolute path and zig 0.15.2's build
  runner panics in `convertPathArg` (`assert(!isAbsolute(child_cwd_rel))` in std
  `Run.zig`) — it aborts the run before any test executes, which reads like a
  test failure and is not one.

  **`build.zig` now refuses that shell before the panic can happen** (T243): the
  first thing `build()` does is compare the build root's drive letter against the
  resolved global cache's, and a mismatch is `error:
  GlobalCacheOnDifferentDrive` with the `$env:`/`set` line to paste. A doc note
  was not enough — this trap was paid at least four separate times (T242,
  T257/T262, T225), and one of those turns re-ran the identical command on the
  assumption of a transient, because a panic with no `error:` line naming this
  repo is exactly the shape of a flake. It never *sets* the variable for you: a
  build script that silently relocates a user's cache is its own surprise.
  Decision logic is pure (`src/build/drive_check.zig`, asserted by `zig build
  test` via the `src/build/build_test.zig` aggregator — the main test binary
  roots at `src/main.zig` and reaches no build logic at all); "cannot tell" is
  always answered as "no mismatch", so a POSIX seat, a UNC checkout, or a
  same-drive CI box is untouched.
- **`-Doptimize=Debug` is not optional**, and the reason is not speed — it is
  **endpoint isolation** (T350). The IPC pipe, the local agent's pipe and the
  state directory are all derived from the build mode: `is_debug` (Debug or
  ReleaseSafe) gets the `-debug` names, anything else gets *the same names the
  user's installed Ghoztty is already using*. So a `zig build
  -Dapp-runtime=win32` without the flag leaves a release build in `zig-out`, and
  from that moment `+new-window` opens windows in the user's terminal, the
  path-filtered kills match nothing, and the acceptance suite reports passes
  about a binary nobody here built. A private `GHOZTTY_PIPE_SUFFIX` does not fix
  it: the agent pipe has no env override. `test\win32\lib\BuildMode.ps1` now
  refuses such a run before anything is launched (acceptance:
  `test\win32\build-mode-guard.ps1`); `GHOZTTY_TEST_ALLOW_RELEASE=1` is the
  opt-in for a script whose subject really is the release build.
- **Never run or overwrite an installed Ghoztty** — not the installed release
  under `%LOCALAPPDATA%\Programs\Ghoztty`, not an extracted portable copy. This
  is the on-box analog of the `/Applications/Ghoztty.app` rule. Always run the
  freshly built `zig-out\bin\ghoztty.exe`.
- **A debug build announces itself** (T43): its whole caption/tab band is
  tinted warning amber and its title carries `" [DEBUG]"`, so a dev instance is
  never mistaken for the user's installed release. Gated on `Debug`/
  `ReleaseSafe` (the Mac banner's own gate). `GHOZTTY_DEBUG_MARKER=0` turns the
  tint off — the GUI acceptance harness sets it, because those scripts measure
  debug chrome as the proxy for what ships (see
  `docs/design/win32-design-system.md` §2.5).
- **Debug builds link the Console subsystem**, so `std.log` output goes to
  stderr in the shell you launched from, like every other platform. Release
  builds use the GUI subsystem (no console) and append `info` and above to
  `%LOCALAPPDATA%\ghoztty\ghoztty.log`; add `-Dwindows-console=true` to give a
  release build a console when you need to debug one live.
- IPC endpoint: the named pipe `\\.\pipe\ghoztty[-debug]-<USERNAME>` — the
  `-debug` suffix is what lets a debug build run alongside the installed
  release. `GHOZTTY_PIPE_SUFFIX` overrides the suffix; `GHOZTTY_IPC_SOCKET`
  (baked into every pane) overrides the whole endpoint, see Instance
  addressability.
- **A leftover agent no longer fails the build** (T192). The agent outlives the
  app on purpose, so a `ghoztty-agent.exe` left running from `zig-out\bin` by an
  earlier test run holds its own image file open — and Windows will not let
  anything replace a running image, so the install step used to die with
  `unable to update file … AccessDenied` **after `ghoztty.exe` had already
  installed**. That shape is the expensive part: exit 1 over a binary that
  really did change, which reads as "my change did not build" and turns a real
  test result into a suspected stale-binary artifact.

  A build-time host tool (`src/build/install_unlock_main.zig`, wired by
  `InstallUnlock.zig`) now runs ahead of every Windows install step and moves a
  locked destination aside as `<name>.old-<n>`, so the install's own atomic
  rename lands on an empty path; the leftover is deleted by a later build once
  the process holding it exits. Renaming, not killing: a build that terminated
  processes would take a concurrently-running acceptance suite's agent, and its
  live sessions, with it. The move must go through `MoveFileExW` — Zig's
  `std.fs.Dir.rename` opens the source with `GENERIC_WRITE | DELETE`, which a
  running image's share mode denies, so it fails on exactly the file this
  exists for. A still-running process keeps the `ExecutablePath` it was created
  with, so the path-filtered kills below still find it after the move.

  `GHOZTTY_INSTALL_UNLOCK=0` turns the guard off and reproduces the original
  failure from the same tree; acceptance:
  `test\win32\build-locked-artifact.ps1`.

  To stop a repo agent by hand, match on `ExecutablePath`, never on name — the
  installed release runs its own agent from `%LOCALAPPDATA%\Programs\Ghoztty`
  and owns the user's live sessions:

  ```powershell
  Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
      Where-Object { $_.ExecutablePath -eq 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe' } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
  ```
- **`ghoztty.com` is the CLI entry point from PowerShell/cmd** (T245).
  PowerShell keys its wait-and-redirect decision on the PE subsystem field, so
  `ghoztty +verb > file` against the GUI-subsystem `ghoztty.exe` writes 0 bytes
  silently (`$LASTEXITCODE` stays empty). The build therefore installs
  `ghoztty.com` — the SAME binary with the optional-header Subsystem WORD
  flipped to console (`src/build/patch_subsystem_main.zig`) — as a required
  sibling; PATHEXT resolves `.COM` before `.EXE`, so bare `ghoztty` from
  PowerShell or cmd gets working redirection, pipes, and exit codes (the
  devenv.com pattern). A GUI launch through the twin respawns `ghoztty.exe`
  detached (`runComShimGuiRespawn`), so a shell never blocks on the terminal it
  launched. Do NOT reintroduce a small relay shim: Defender's ML quarantined
  that shape on sight (`src/cli/com_shim.zig` has the story). Scripts calling
  `ghoztty.exe` by explicit path still need pipe capture, or should call the
  `.com`. Acceptance: `test/win32/cli-shim-redirect.ps1`.
- The session-persistence agent builds alongside the app as
  `zig-out\bin\ghoztty-agent.exe` (a required sibling of `ghoztty.exe`); its
  state lives under `%LOCALAPPDATA%\ghoztty\local-agent[-debug]\` and it is
  dialed over `\\.\pipe\ghoztty-agent[-debug]-<USERNAME>`. A stale agent from an
  earlier build keeps running by design — see Agent contract & upgrade
  compatibility.
- Release/delivery build (what ships, and what the delivery scripts stage):

  ```powershell
  zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast `
      -Dtarget=x86_64-windows-gnu -Dstrip=false --prefix zig-out-release
  ```

  `-Dstrip=false` is load-bearing: a stripped release build produces
  undebuggable crash dumps. Delivery to the user's install locations goes
  through `scripts/launch-upgrade.ps1` (never a hand-rolled `Start-Process`);
  `go.md` has the full protocol and the staleness gates.

### Test lanes and acceptance scripts

The floor for any change — all of these green, on the platform you changed:

```powershell
zig build test -Dapp-runtime=none      # pure logic, no app runtime
zig build test -Dapp-runtime=win32     # win32 apprt units (Windows)
zig build test-agent                   # ghoztty-agent, incl. real-pty tests
```

`zig build test` with no `-Dapp-runtime` is the `none` lane on macOS and the
`win32` lane on Windows, so **name the lane explicitly** rather than assuming
the bare command covers both.

On Windows, run them through the watchdog rather than bare (T430):

```powershell
powershell -NoProfile -File scripts\floor-lane.ps1 -Lane all
```

It sets `ZIG_GLOBAL_CACHE_DIR` on the repo's drive inside the launched command,
logs unbuffered through `cmd.exe`, and — the reason it exists — **tells a slow
lane from a wedged one**: a lane that is computing burns CPU, a lane that is
blocked does not, so zero CPU delta across the process tree with no new output
is reported as `STALL` with a diagnostic (process tree, per-thread wait reasons,
WebView2 hosts, log tail) instead of hanging forever with nothing to read. Exit
0 pass / 1 fail / 2 wedged / 3 wall-clock cap; `-Lane <one>`, `-Repeat N`,
`-Filter <test-filter>`, `-SelfTest` to prove the detector itself.

**A red lane never ends on a bare exit code** (T444). `std.process.Child`
truncates a Windows exit code to a byte, so a *crashed* child reaches `zig build`
as `NTSTATUS & 0xFF` — `0xC0000005` (access violation) arrives as
`error code 5`, `0x80000003` (Zig's segfault handler aborting) as `code 3` —
which reads as a compile step failing for no reason at all.
`scripts/lib/CrashDiag.ps1` decodes it back and correlates it with the Windows
`Application Error` log, so a FAIL ends with a `-- crash diagnostics --` block
naming the process, exception, module and fault offset. The decode alone is only
a suspicion (a program really can `exit(5)`), so with no crash record behind it
the block says so rather than asserting. Acceptance:
`test\win32\crash-diagnostics.ps1`.

**And a red lane captures a real stack** (T450). Zig's segfault handler dies in
a recursive panic here, and even when it works it only ever walks the thread
that faulted — never the one that did the damage. So a crash in one of our test
binaries makes `floor-lane.ps1` re-run that binary under **cdb**, which takes
the exception on first chance and writes a full minidump plus `~*kv` for every
thread into `.dumps\`; the console gets a `-- crash stack --` block with source
lines and the name of the test that was running. It gets **one** attempt by
default, so a red lane costs ~10 extra minutes at worst; `-NoCatch` skips it and
`-CatchAttempts 2` buys better odds on a specific intermittent crash. Run it by
hand against an intermittent crash with

```powershell
powershell -NoProfile -File scripts\crash-catch.ps1 -Lane agent -Attempts 6
```

which runs the lane's built test binary directly (~20–110 s a go, no build).
`cdb` needs no install and no elevation on this box — the Store WinDbg package
ships a console `cdbX64.exe` under `%LOCALAPPDATA%\Microsoft\WindowsApps\`.
Library: `scripts/lib/CrashCatch.ps1`, which documents the three cdb traps
(backslashes eaten inside quoted commands, filters must be armed at the loader
break, cdb echoes its own command back). Acceptance:
`test\win32\crash-stacks.ps1`.

**A harness must never fabricate a failure, and one shape of that is now
checked** (T197). `Start-Process -PassThru` hands back a process object whose
`ExitCode` reads back **empty** unless something touched `$p.Handle` while the
child was still alive — so `if ($code -ne 0) { fail }` scores a *working* CLI as
broken. A fabricated failure costs more than a missed one: it sends the next
session hunting a defect that is not there, which it did twice (T145, then a
whole T147 turn spent on six red assertions against a build whose complete
`+list` output was sitting in the redirect file).

The trigger is now measured rather than remembered: it fires **only when
`Start-Process` is given `-RedirectStandardOutput` / `-RedirectStandardError`**
(0 of 8 reads survive, whether the handle is cached late or never; 8 of 8 with
it cached first, and 8 of 8 without any redirect). That is why it read as
flakiness — most helpers here redirect *inside* `cmd /c … > file`, which is
unaffected, and the two spellings sit line-for-line next to each other. So the
rule is mechanical and applies to every site:

```powershell
$p = Start-Process ... -PassThru
$null = $p.Handle          # FIRST, before any wait
if (-not $p.WaitForExit($ms)) { ... }
$p.WaitForExit()
return $p.ExitCode
```

Better still, **gate on the OUTPUT when the output is the answer** — parse the
JSON, look for the marker — rather than on a shell-plumbing detail. Exemptions
are `-Wait` (Start-Process holds the handle itself) and an explicit
`# exitcode-audit: <reason>` marker, the same state-your-intent convention the
`# persistence:` markers use. The analyzer is
`test\win32\lib\ExitCodeAudit.ps1`; acceptance (and the sweep that must stay at
zero across `test\win32\` **and** `scripts\`):
`test\win32\harness-exitcode-audit.ps1`.

**A section the suite SKIPPED is named in the line anybody reads** (T219).
Skipping is legitimate — pwsh is not installed, there is no network, a release
build compiled the debug oracle out. A skip the RESULT cannot see is not: it is
an un-run assertion wearing a green hat, and an assertion inside one can rot for
months. `ipc-version.ps1` asserted the About box was a `#32770` MessageBox long
after it became a native `GhozttyConfirmDialog`, and every run still printed
`ALL PASS` because the foreground grab kept losing and the whole palette section
took its SKIP branch (T217 found it by making the chord land). Since the loop
reads exactly ONE line (`| Select-Object -Last 1`), a `(2 section(s) SKIPPED)`
line printed *above* the verdict is invisible to the only reader there is — five
scripts printed one there. So the count goes in the verdict itself:

```powershell
Write-Host 'SKIP  pwsh: not installed on this box'; $script:skipped++
...
"ALL PASS$(if ($script:skipped) { " ($script:skipped SKIPPED)" })"
"ALL PASS (12 assertions$(if ($script:skipped) { ", $script:skipped SKIPPED" }))"
```

Consumers match `ALL PASS` as a substring, so the suffix breaks nothing.
Exemptions are narrow and stated: a site that prints and immediately `exit`s is
its own last line, and a `# skip-audit: <reason>` marker is the same
state-your-intent convention `# persistence:` and `# exitcode-audit:` use.
Analyzer: `test\win32\lib\SkipAudit.ps1`, which reports `unreported` (skips
exist, the verdict is silent) and `uncounted` (a site the counter misses — a
number that under-reports is worse than no number, because it reads as
audited). Acceptance: `test\win32\skip-visibility.ps1`, whose `$SkipAuditPending`
list of not-yet-converted scripts can only SHRINK — an entry that no longer
violates fails the run just as an unlisted violator does.

**And a script that PRINTS failure EXITS failure** (T221). The verdict line is
for the human; the exit code is for everything else, and they used to be able to
disagree. `chooser-menu.ps1` and `host-settings.ps1` ended with a bare `if …
{ "ALL PASS" } else { "$fail FAILURE(S)" }` and no `exit` in sight, so a run with
red assertions fell off the end with `$LASTEXITCODE` at 0 — correct on screen, a
pass to any suite driver, `; if ($?)` chain or CI that scored it. (`config-errors.ps1`
had the identical bug, fixed in T217; all three are fixed, so what T221 delivered
is what keeps them fixed.) The rule runs **both** directions: the failure path
must terminate the script nonzero, AND the pass path must not fall into the
failure verdict on its way out — dropping the `exit 0` from the suite's
early-return shape makes a *green* run announce `FAILURE(S)` and exit 1.

Analyzer: `test\win32\lib\VerdictExitAudit.ps1`, reporting `fallthrough` (the
defect), `exits-zero`, `pass-falls-through` (the other direction) and
`no-verdict`. It reads the **AST**, unlike its two sibling audits, and that is
load-bearing rather than stylistic: in most of this suite the exit shares the
verdict's line (`else { "$fail FAILURE(S)"; exit 1 }`), so a line-oriented reader
must decide what "near" means — the first draft of one reported 128 of 160
scripts. Branch membership is a structural question, so ask the parser. What it
deliberately does not claim is a **computed** exit code (`exit ([int]($failures
-gt 0))`, which two scripts legitimately use); section C of the acceptance script
measures real codes on the wire instead, both shapes and both directions, with
the unfixed shape as a negative control. Exemption: the same stated-intent
`# verdict-audit: <reason>` marker, carried today only by `ipc-fake-server.ps1`,
a helper process with nothing to score. Acceptance:
`test\win32\verdict-exit-audit.ps1`, whose `-TeethCheck` plants a real violator
inside the swept directory and requires the sweep to find it.

**A test sandbox can have an agent of its own** (T167). The local agent's
single-instance guard is per-user and per-LINEAGE, and the lineage is a
compile-time fact (`local-debug` for every debug build), so a debug agent
already running refuses a sandbox's agent with exit 183 — and the app then falls
back to plain exec panes *silently*, leaving a suite that reports on session
persistence while exercising the non-persistent path. That is why so many
scripts open by killing every `local-agent-debug` process, which takes the
loop's own panes with it and means two suites can never run at once.
`GHOZTTY_AGENT_INSTANCE=<suffix>` names a distinct lineage instead, and it moves
**every** derivation that spells the lineage out — the guard mutex, the lock and
heartbeat files, the app's state dir (`local-agent-debug-<suffix>`), its agent
pipe (`\\.\pipe\ghoztty-agent-debug-<suffix>-<user>`), the HKCU Run value name,
and the dir `+sessions` reads — because a *half*-isolated sandbox is the bug,
not the fix. Sanitized to a whitelist and capped at 24 characters, with an
over-long value rejected rather than truncated (truncation would silently merge
two sandboxes into one lineage). Unset — every production run — reproduces each
legacy name byte for byte. Rules: `src/remote/agent_lineage.zig`; acceptance:
`test/win32/agent-instance-lineage.ps1` (which carries a `-TeethCheck` self-test
for its own end-to-end arm). Converting the existing suites onto it is T691; the
Swift half is T692.

**Tests must never touch live user state.** The WebView2 live-runtime tests run
under `webview2.TestProfile`, which points `LOCALAPPDATA` at a private per-run
root so they cannot contend with — or corrupt — the `EBWebView[-debug]` profile
a real Ghoztty is using. And a test server thread blocked in `accept()` is woken
with a **real connection** before its listener is closed: on Windows
`closesocket` does not signal a blocking call pending in another thread, so
close-then-`join()` is an indefinite hang (`TestPage`/`ReloadPage` in
`ViewerPane.zig`, `keepalive.zig`, `link_control.zig`, `self_update.zig`).

On Windows, behavior that unit tests cannot reach is covered by non-interactive
PowerShell acceptance scripts in `test/win32/` (80+ of them). The standing
regression floor is P1–P3, which must stay ALL PASS:

```powershell
powershell -NoProfile -File test\win32\ipc-p1.ps1   # +new-window, +list, +close
powershell -NoProfile -File test\win32\ipc-p2.ps1   # +split, +rename, +send-keys
powershell -NoProfile -File test\win32\ipc-p3.ps1   # +read, +set-state, OSC 7777, +rearrange
```

Each prints a single `ALL PASS` / `N FAILURE(S)` line at the end, so
`| Select-Object -Last 1` is enough to read the result. They default to
`-Exe D:\git\ghoztty\zig-out\bin\ghoztty.exe` and only ever touch ghoztty
processes running from that exact path, so they cannot disturb the user's
installed release.

**Everything gets tests**: pure logic → unit tests in the `none` lane;
behavior → an on-box acceptance script. Win32 chrome geometry belongs in the
pure geometry modules and must be asserted at 1.0, 1.25, 1.5 and 2.0 scaling
(see the design-system section below).

**Every launch in an acceptance script declares its session persistence**
(T158). Persistence is ON by default, so a GUI launched without
`--session-persistence=false` restores whatever panes the last launch left —
and each section writes the manifest the next one restores, so a script
poisons itself on a clean box (T131, then T155, where two scripts failed
`default setup: 2 visible panes` against a build whose geometry was verified
correct by hand). But a third of the suite WANTS it on — the `session-*`,
`agent-*` and restore families — so the rule is not "always pass the flag", it
is **state which you want**: pass the flag, pass something built from it, have
every caller of your helper pass it, or write a `# persistence: <reason>`
marker for a site where none of those fit (a CLI verb, a throwaway-
`LOCALAPPDATA` launch, a forward-and-exit second instance). The value must be
one `parseBool` accepts (`1/t/T/true/on/yes`, `0/f/F/false/off/no`) — anything
else is logged, dropped, and leaves a launch that looks explicit and restores
anyway. Enumerator: `test/win32/lib/PersistenceSweep.ps1`; acceptance (and the
live control that the flag really stops a restore):
`test/win32/persistence-flag.ps1`.

**A restore test must prove the pane is LIVE, not painted** (T532, T652). A
pane that came back as a frozen picture is byte-identical to a working one for
every assertion that reads the screen or `+list --json` — a replayed marker is
by definition a recording, a restored banner is a picture of a banner, and the
agent's `alive`/`attached` rows describe a child that may be wired to nothing.
On 2026-08-06 a user hit exactly that, with the whole acceptance suite green
over it. So every script that restores or re-attaches a pane types into it and
requires an answer: `Test-PaneLive` in `test\win32\lib\PaneLiveness.ps1` (an
`echo <token>`, matched **twice** — once as the echoed input line, once as the
command's output, because one hit is only bytes going in). Re-running a script
with `GHOZTTY_TEST_LIVENESS_BREAK=1` makes every liveness arm in it go red and
nothing else move, which is how each arm was teeth-checked. A viewer pane has
no shell; its equivalent claim is that the PAGE still responds — see the
page-server oracle in `test\win32\viewer-restore.ps1`.

## Windows UI: the design system is mandatory

**Before changing any pixel of the win32 chrome — tab strip, banner, dialogs,
chooser, menus, split dividers — read `docs/design/win32-design-system.md`.**
It is the rulebook, not a style suggestion, and a control that invents its own
spacing, sizing, radius, hover treatment or glyph geometry is a defect even
when it looks fine in isolation. The defect is the inconsistency.

The short version, all of which is enforceable and most of which is already
asserted in the pure geometry modules:

- **One 4 DIP spacing scale** (2/4/8/12/16/24). No value off the scale.
- **Nothing touches anything.** >= 4 DIP between any two painted elements and
  between an element and its container's edge. Deliberate merges (the selected
  tab chiclet into the pane) are named in the doc; there are no others.
- **Gaps are measured between PAINTED edges, never hit boxes.** A hit box may
  be larger than its paint, but it is invisible and never contributes a gap.
- **Size the container to the control**, not the reverse — centering a 26 DIP
  square in a 29 DIP band yields a jammed control, not a padded one.
- **One icon-button size** (28 DIP painted square, >= 32 DIP hit box), one
  fill treatment, one set of states (rest/hover/pressed/active/disabled/
  focused). State is never color alone; focus is always visible.
- **Contrast floors:** 4.5:1 text, **3:1 for chrome glyphs and meaningful
  boundaries** (WCAG 1.4.11), re-checked on the hovered fill too.
- **Radius scale** 4 (buttons) / 6 (tab chiclet top) / 8 (cards), and three
  elevation levels with shadows only where the level allows one.
- **Glyphs are filled shapes, never `LineTo` pen strokes** — `LineTo` drops the
  endpoint and wide pens bias one side, which is how a "+" ends up with one arm
  shorter than the other. Symmetry is asserted, not intended. Mark widths are
  tuned **optically** per glyph (a hamburger reads narrower than a plus at the
  same extent).
- **Dividers are 2 DIP** with a real hover color change (lighten in dark,
  darken in light) — not a cursor change alone.
- **Vertical space belongs to the terminal.** Chrome that controls nothing does
  not appear (no tab strip at one tab); always-reachable controls belong in the
  caption bar, which the window already pays for.
- **Horizontal chrome sizes to content, capped by PROPORTION** (a tab may take
  up to 50% of the run), never by a fixed DIP number that truncates a title
  while the strip sits half empty.

Put numbers in the pure geometry modules (`tab_strip_layout.zig`,
`icon_button.zig`, `split_geometry.zig`, `banner_layout.zig`) and assert them at
1.0, 1.25, 1.5 and 2.0 — most of these defects are invisible at 1.0 and obvious
at 1.25.

## Architecture

- **Zig core** (`src/`): terminal emulation, input handling, CLI commands, IPC client — shared by both platforms
- **Swift macOS app** (`macos/`): SwiftUI frontend, IPC server, split tree layout
- **Zig win32 app** (`src/apprt/win32/`): native Win32 frontend, IPC server (`IpcServer`/`IpcHandlers`/`IpcRegistry`), split tree layout, tab strip and chrome. Selected by `-Dapp-runtime=win32`, which is the default on Windows
- **`ghoztty-agent`** (`src/remote/agent/`): the session-persistence / remote-machines daemon, built by `zig build agent` and tested by `zig build test-agent`. One codebase, PTYs on macOS and ConPTYs on Windows
- Split panes use a binary tree (`SplitTree`) with a ratio (0.0–1.0) per split node, on both frontends
- IPC uses the same JSON messages on both platforms over a different local transport: a Unix domain socket at `$TMPDIR/ghostty[-debug]-<uid>.sock` on macOS, the named pipe `\\.\pipe\ghoztty[-debug]-<USERNAME>` on Windows. Both are overridden per pane by `$GHOZTTY_IPC_SOCKET` (see Instance addressability). The client side resolves in exactly one place on both platforms — `apprt.ipc.socketPath()` (`src/apprt/ipc.zig`), which delegates the pipe name to `ipc_client.endpointPath()` (`src/os/ipc_client.zig`) on Windows — so the derivation cannot drift
