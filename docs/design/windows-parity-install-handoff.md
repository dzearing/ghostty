# T1179 handoff checkpoint - the clean-machine install proof

**Written 2026-08-30 by the go-loop, immediately before it stopped.**

This file exists because the next step kills every terminal on the box. The
go-loop, the controller chat and the task dashboard all run inside Ghoztty
panes, and you are about to close Ghoztty to install over it. Nothing can be
waiting for you when you come back, so everything you need is here rather than
in a pane's scrollback.

---

## What is being proved

> "I want to go to the website and be able to install the prod version of
> ghoztty on a new machine and it should just work."

The published site must offer **one** Windows installer, that installer must
produce a **working** Ghoztty with no second download and no script, and a
**later** build must then arrive through the app's own update rather than a
script. The cutover to `main` does not start until this passes, and the loop
may not self-certify it - you install, you confirm.

## The release you are installing

| | |
|---|---|
| Version | **1.35.0** |
| Release | https://github.com/dzearing/ghoztty/releases/tag/win-v1.35.0 |
| Installer | `Ghoztty-1.35.0-x64.msi` |
| Website | https://dzearing.github.io/ghoztty/ |

**Go to the website and click the Windows download** - that is the path being
tested. The direct release link above is only for checking what you got.

1.35.0 is the first published build that carries the whole install epic:
one installer (T1175), the installer launching Ghoztty when it finishes
(T1176), a startup failure raising a dialog instead of exiting silently
(T1177), and in-app update (T1178). Everything on the site before today
pointed at win-v1.34.0, published 2026-08-21, which predates all four.

## Before you install: clear the box

There are copies of Ghoztty all over this machine, and "no prior Ghoztty" has
to be true rather than assumed. From a Ghoztty pane (or any PowerShell), in
`D:\git\ghoztty`:

```
powershell -NoProfile -File scripts\ghoztty-cleanup.ps1 clean
```

It asks before each item and removes nothing on its own; an unanswered item is
kept. At the time this was written it found **26 artifacts - 25 removable, 1
protected**:

- **Installs (8)**: the installed release at
  `%LOCALAPPDATA%\Programs\Ghoztty`, two portable copies (Desktop and the
  `\\homeassistant\share` copy), and five `zig-out*` dev prefixes in the repo.
- **Registry**: the `Ghoztty Remote Agent 1.12.1` Apps & Features entry,
  four `GhozttyAgent*` autostart entries, two settings keys.
- **PATH**, **two Start Menu shortcuts**, **two scheduled tasks**, and the
  state directory `%LOCALAPPDATA%\ghoztty` (1271 files, 750 MB - relay
  sign-in, saved sessions, agent logs).
- **Protected, never offered**: the ghost `Ghoztty 26.7.502` registration
  `{A10466B5-...}`, whose uninstall would delete the live install's files.

Things worth thinking about before you answer yes to them:

- The **installed release is in use by the running Ghoztty** - it cannot be
  removed until you close every window, which you are about to do anyway.
- **`\\homeassistant\share\...`** and the **`zig-out*` dev prefixes** are not
  part of the product and removing them costs nothing but rebuild time.
- The **state directory** holds your relay sign-in and saved sessions.
  Removing it is the honest "new machine" answer; keeping it is a legitimate
  choice - say so with
  `scripts\ghoztty-cleanup.ps1 keep state-dir -Reason "..."` so the verdict
  records it as deliberate rather than counting it dirty.
- The **`GhozttyGoLoopWatchdog` scheduled task** is the loop's own supervisor.
  Removing it means the loop will not revive itself; you will start it by
  hand (below). Either answer is fine - just know which you gave.

Then:

```
powershell -NoProfile -File scripts\ghoztty-cleanup.ps1 verdict
```

Exit 0 means clean (everything gone, kept on purpose, or protected). Keep that
output - it is the evidence T1179 records.

## The install

1. **Close every Ghoztty window.** All of them, including the one running the
   loop and the one running the controller chat.
2. Download the Windows installer **from the website** and run it. Per-user,
   no admin password.
3. **Ghoztty should launch itself when the installer finishes** (T1176). Note
   whether it did.

## What to check when it comes up

- [ ] The website offered exactly **one** Windows installer.
- [ ] A window opened, with a working shell in it.
- [ ] It launched **by itself** when the installer finished.
- [ ] **No error dialog** and no silent failure on first run.
- [ ] `ghoztty +list` works from inside it - the CLI is on PATH.
- [ ] Sessions work: the session agent is alive, splits and tabs behave.
- [ ] `ghoztty --version` (or the About box) says **1.35.0**.

Anything that is not true is the finding - it is more valuable than a pass.

## Resuming the loop

From the new Ghoztty, in `D:\git\ghoztty`:

```
powershell -NoProfile -File scripts\go-loop-exec.ps1 resume
```

Then start Claude in a pane and give it:

```
read go.md and go
```

It will pick T1179 back up as a `RESUME:`, read this file, record what you
report, and then do the **second half**: publish 1.36.0 and take it through
the app's own update - no script, no file copying - which is the last
criterion on the task.

## Where things stand on disk

- Task: `docs/design/windows-parity-tasks/T1179.md` (in-progress, P0, M1)
- The loop is **stopped by request**, so the watchdog will not revive it into
  a machine mid-install. `resume` above is what clears that.
- The site mirror in this repo is already retargeted at 1.35.0; CI retargets
  the live gh-pages page in the same run that publishes the release.
