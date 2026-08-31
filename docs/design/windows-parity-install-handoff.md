# T1179 handoff checkpoint - the clean-machine install proof

**Rewritten 2026-08-31 by the go-loop for the SECOND walk, immediately before
it stopped. The first walk (1.35.0, 2026-08-31 07:08) is summarised at the
bottom.**

This file exists because the next step kills every terminal on the box. The
go-loop, the controller chat and the task dashboard all run inside Ghoztty
panes, and the installer is about to close Ghoztty. Nothing can be waiting for
you when you come back, so everything you need is here rather than in a pane's
scrollback.

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
| Version | **1.36.0** |
| Release | https://github.com/dzearing/ghoztty/releases/tag/win-v1.36.0 |
| Installer | `Ghoztty-1.36.0-x64.msi` |
| Website | https://dzearing.github.io/ghoztty/ |

**Go to the website and click the Windows download** - that is the path being
tested. The direct release link above is only for checking what you got.

1.36.0 is the first published build that carries the fixes your last install
turned up:

- **T1204/T1207** - installing over a running Ghoztty. The installer now asks
  the app to close, replaces the files and opens it again, and it does that
  *without* killing the session agent or the per-session PTY holders, so your
  open shells survive the upgrade. Last time this path died with a silent
  "configuring" dialog and then demanded a reboot it did not need.
- **T1205** - About and `--version` now agree with each other, with Apps &
  Features and with the website.
- **T1217** - a build delivered into the installed-release folder keeps a
  truthful version number and can still find updates.

## Install it OVER the running Ghoztty - do not close it first

This is the opposite of last time's instruction, and it is deliberate: the
install-over-running path is the thing that broke, so the walk has to exercise
it. Leave your windows open, including the loop's and the controller's, and
double-click the MSI.

What should happen:

1. The installer notices Ghoztty is running and closes it politely (you may
   see a "the following applications should be closed" step - let it).
2. It installs. **No reboot prompt.** No dialog that flashes and vanishes.
3. **Ghoztty opens again by itself** when the installer finishes (T1176).
4. Your restored sessions are still there - the agent was not killed.

## What to check when it comes up

- [ ] The website offered exactly **one** Windows installer.
- [ ] The installer closed the running Ghoztty on its own rather than failing.
- [ ] **No error dialog**, no vanishing window, and **no reboot demand**.
- [ ] It **launched by itself** when the installer finished. *(This is the one
      criterion nobody has ever observed - the first walk had a reboot in
      between. Please watch for it specifically.)*
- [ ] A window opened with a working shell in it.
- [ ] The **About box** says **1.36.0** - and so does `ghoztty --version`.
- [ ] `ghoztty +list` works from inside it - the CLI is on PATH.
- [ ] Sessions survived: `ghoztty +sessions` shows the agent alive, and your
      previously open shells came back.

Anything that is not true is the finding - it is more valuable than a pass.

## Then: resume the loop

From the new Ghoztty, in `D:\git\ghoztty`:

```
powershell -NoProfile -File scripts\go-loop-exec.ps1 resume
```

Then start Claude in a pane and give it:

```
read go.md and go
```

It picks T1179 back up as a `RESUME:`, reads this file, records what you
report, and then does the **last** step: publish **1.37.0** and leave it for
the app's own updater to find. You will get an update notification in the
running terminal; taking it - with no script and no file copying - is the
final criterion on the gate.

## If you would rather clean the box first

Optional, and not required for this walk. `scripts\ghoztty-cleanup.ps1
inventory` currently finds **23 unaccounted artifacts**: the installed release
itself, two portable copies (Desktop and `\\homeassistant\share`), five
`zig-out*` dev prefixes in the repo, the `Ghoztty Remote Agent 1.12.1` Apps &
Features entry, four `GhozttyAgent*` autostart entries, two settings keys, the
user PATH entry, the Start Menu shortcut, the `GhozttyGoLoopWatchdog` and
`GhozttyTaskDashboard` scheduled tasks, and the 744 MB state directory at
`%LOCALAPPDATA%\ghoztty` (relay sign-in, saved sessions, agent logs).

```
powershell -NoProfile -File scripts\ghoztty-cleanup.ps1 clean
powershell -NoProfile -File scripts\ghoztty-cleanup.ps1 verdict
```

`clean` asks before each item and removes nothing on its own. Two of them are
worth a thought: the **state directory** holds your relay sign-in and saved
sessions (keeping it is legitimate - say so with `ghoztty-cleanup.ps1 keep
state-dir -Reason "..."` so the verdict records it as deliberate), and the
**`GhozttyGoLoopWatchdog`** task is the loop's own supervisor, so removing it
means the loop will not revive itself.

Note that cleaning removes the running install, which means closing every
window - and that would skip the install-over-running path this walk is here
to test. If you want both, do this walk first.

## Where things stand on disk

- Task: `docs/design/windows-parity-tasks/T1179.md` (blocked on you, P0, M1)
- The loop is **stopped by request**, so the watchdog will not revive it into
  a machine mid-install. `resume` above is what clears that.
- The morning refresh will not overwrite what you install while the loop is
  stopped. When it does run again it now delivers a build that reports the
  right version and can still find updates (T1217); whether it should keep
  running at all is **D85**, waiting on your answer in the dashboard.

---

## The first walk, for reference (1.35.0, 2026-08-31 07:08)

**Passed:** the site offered exactly one Windows installer; the install
completed; About and `--version` both reported `1.35.0+890207079`; `ghoztty`
resolved on PATH; `+list` worked; `+sessions` showed the agent alive with an
attached pinned session; the Start Menu shortcut targeted the installed exe.

**Failed:** "no silent failure" - installing over the running Ghoztty said
"configuring" and vanished (Error 1500 / status 1602 from a collided msiexec),
then demanded a reboot it did not need. Fixed by T1204/T1207, which is what
this walk re-tests.

**Never observed:** whether the installer launched Ghoztty itself - the reboot
happened in between.
