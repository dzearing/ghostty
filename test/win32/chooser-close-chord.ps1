# Machine-chooser CLOSE-CHORD acceptance (tracker T603).
#
# Upstream `11fe14bc3` fixed the Mac half: "Close" (Cmd-W) sends its action to
# the FIRST RESPONDER, nothing in the chooser panel's chain answered it, and
# AppKit carried the search on into the MAIN window - so a chord aimed at the
# dialog closed a pane behind it. This is the Windows seat's regression arm for
# the same promise, in the two halves a user would describe:
#
#   1. Ctrl+W with the chooser focused DISMISSES THE CHOOSER. (Before T603 it
#      did nothing at all here: `MachineChooser.handleKey` had no case for it,
#      so the key fell through to the filter EDIT, which ignores it.)
#   2. Every terminal window and pane behind the chooser is still there
#      afterwards. This is the half the Mac bug broke, and win32 has never been
#      able to reach it - the chord arrives as a WM_KEYDOWN at a chooser
#      control, the owner window is DISABLED while the dialog is up, and only a
#      Surface's own WndProc turns a key into a binding. Asserted anyway: the
#      failure mode is expensive (a pane full of work, closed by a chord aimed
#      somewhere else) and cheap to keep watched.
#
# POSITIVE CONTROL, mandatory and first: the same chord, delivered the same
# way, closes a pane when a TERMINAL is focused. Without it "the pane behind
# survived" is equally consistent with the keystroke never arriving - which is
# exactly how a confident, wrong negative gets recorded.
#
# THE CONTROL HAS A PRECONDITION OF ITS OWN (T1284). Ctrl+W over a terminal
# closes the pane only when that pane's shell is descendant-free; a busy shell
# gets `Surface.close`'s confirmation dialog instead (T41), which is MODAL. On
# 2026-09-02 this script scored three reds inside the suite and ALL PASS on the
# re-run alone, and the filed suspicion was that a posted chord cannot reach a
# background desktop. It can: the reproduction is a forced confirmation
# (`--confirm-close-surface=always`), which produces that suite log assertion
# for assertion - the pane count frozen at 2, the chooser still opening because
# a posted message ignores the modal's EnableWindow, and the owner window never
# re-enabling. So the control now WAITS for the shells to go idle, and reads
# the dialog back rather than inferring a missing keystroke from a pane that
# did not close. Harness defect, not a desktop capability gap.
#
# -NegativeControl inverts assertion (1) to expect the chooser to SURVIVE
# Ctrl+W, which is the pre-T603 behavior and MUST fail; it is how a run proves
# this script discriminates rather than riding a green desktop.
#
# -ForceConfirm reproduces the 2026-09-02 suite red on demand (see T1284): it
# runs the app with `confirm-close-surface = always`, so the positive control's
# Ctrl+W raises the modal instead of closing. It MUST fail, at the dialog
# assertion and the pane count, and it must fail THERE ONLY - that is the
# demonstration that the dialog is now named and dismissed rather than left
# standing to redden two more sections.
#
#   powershell -NoProfile -File test\win32\chooser-close-chord.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$ForceConfirm
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }

# Isolate the IPC endpoint (inherited through CreateProcessW): an instance
# answering the shared pipe would let another run's windows into this one.
$env:GHOZTTY_PIPE_SUFFIX = "-t603$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
# T1284: the idle oracle and the confirm-dialog reader. The positive control
# below closes a pane, and a close only happens outright when the pane's shell
# is descendant-free - otherwise it raises a MODAL confirmation, and that is
# what this script actually scored (three reds) inside the suite on 2026-09-02.
. (Join-Path $PSScriptRoot 'lib\PaneIdle.ps1')

$script:pass = 0
$script:fail = 0

function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

# Kill only what this repo built. The installed release (and its agent, which
# owns the user's real terminal) is never touched.
function Stop-RepoProcesses([string[]]$Names) {
    # T351: the ghoztty halves go through the one shared, path-exact kill
    # (lib\CleanSlate.ps1) - every private copy answered "does the agent go too"
    # alone. Anything else in $Names is this script's own litter, so it stays local.
    if ($Names -contains 'ghoztty') {
        [void](Stop-RepoGhoztty -Exe $Exe -AppOnly:(-not ($Names -contains 'ghoztty-agent')) -SettleMs 0)
    }
    foreach ($name in ($Names | Where-Object { $_ -notin @('ghoztty', 'ghoztty-agent') })) {
        Get-CimInstance Win32_Process -Filter "Name='$name.exe'" | ForEach-Object {
            if ($_.ExecutablePath -and $_.ExecutablePath.StartsWith((Join-Path $repo 'zig-out'), 'OrdinalIgnoreCase')) {
                try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}
            }
        }
    }
    Start-Sleep -Milliseconds 600
}

# `ghoztty +verb > file` writes zero bytes from PowerShell (T245) - capture
# through a pipe instead.
# `+list --json` reports each tab's split TREE, so the pane count is its leaf
# count - which is the number this script compares before and after a chord.
function Count-Leaves($node) {
    if ($null -eq $node) { return 0 }
    if ($node.type -eq 'leaf') { return 1 }
    return (Count-Leaves $node.left) + (Count-Leaves $node.right)
}

function Get-PaneCount {
    $out = (& $Exe +list --json 2>$null | Out-String)
    if (-not $out -or $out.Trim().Length -eq 0) { return -1 }
    try { $j = $out | ConvertFrom-Json } catch { return -1 }
    if ($null -eq $j) { return -1 }
    $n = 0
    foreach ($w in @($j.data.windows)) {
        foreach ($t in @($w.tabs)) { $n += (Count-Leaves $t.splits) }
    }
    return $n
}

# persistence: --session-persistence=false - this run is about a key chord, and
# a restore of the previous script's panes would seed the window with panes
# this one never opened (T158).
function Launch-Gui($errlog) {
    $args = @('--window-width=100', '--window-height=30', '--session-persistence=false')
    # -ForceConfirm: the T1284 reproduction. `confirm-close-surface = always` is
    # the one branch `Surface.shellIsIdle` refuses to answer "idle" for whatever
    # the process table says, so it stands in for a busy shell deterministically.
    # The run MUST go red, and it must go red at the two NEW assertions - the
    # dialog reader and, once the modal is dismissed, the pane that did not
    # close - rather than dragging sections 2 and 3 down with it.
    if ($ForceConfirm) { $args += '--confirm-close-surface=always' }
    $app = Start-OnTestDesktop -Exe $Exe -Arguments $args -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { return $null }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { return $null }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { return $null }
    return @{ App = $app; Pid = $app.Pid; Top = $top; Surface = $surface }
}

function Open-Chooser($g) {
    if (-not (Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl, shift -Key N)) { return [IntPtr]::Zero }
    return Wait-TestWindow -ProcessId $g.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 5000
}

Write-Host 'T603 machine chooser close chord'
Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
New-TestDesktop | Out-Null

$errlog = Join-Path $env:TEMP "ghoztty-t603-stderr-$PID.log"
Remove-Item $errlog -ErrorAction SilentlyContinue

try {
    $g = Launch-Gui $errlog
    if (-not $g) { Write-Host 'SETUP FAIL: GUI did not come up'; exit 1 }

    # --- 1. positive control: the chord acts when a terminal is focused ------
    Write-Host ''
    Write-Host '1. positive control: Ctrl+W with a terminal focused closes the pane'
    & $Exe +split --direction=right 2>$null | Out-Null
    Start-Sleep -Seconds 2
    $before = Get-PaneCount
    Assert ($before -eq 2) "the window holds two panes to start (found $before)"

    $pane = Get-TestChildWindow -Window $g.Top -Class 'GhozttyTerminal'
    Assert ($pane -ne [IntPtr]::Zero) 'a terminal pane is there to aim the chord at'

    # WAIT FOR THE SHELLS TO SETTLE FIRST (T1284). A close asks
    # `Surface.shellIsIdleNow`, and a shell that still has descendants - which
    # is what a freshly split pane looks like for as long as its shell takes to
    # start, and that is a function of box load - raises the confirmation
    # dialog instead of closing. So the state this control depends on is now
    # waited for and asserted rather than assumed after a flat 2-second sleep.
    $idle = Wait-PanesIdle -Exe $Exe -TimeoutMs 20000
    Assert $idle.Idle "both panes' shells are idle before the chord ($($idle.Text))"

    [void](Send-TestKeys -Window $g.Top -Target $pane -Modifiers ctrl -Key W)
    Start-Sleep -Seconds 2

    # And READ THE DIALOG BACK, because a confirmation is the one other thing
    # Ctrl+W can do here, and it is indistinguishable from a chord that never
    # arrived if nobody looks. It is also modal: left standing it disables the
    # owner window for the rest of the run, which is how one wrong assertion
    # became three on 2026-09-02. Named, then dismissed.
    $confirm = Get-CloseConfirmDialog -ProcessId $g.Pid
    Assert ($confirm -eq [IntPtr]::Zero) 'the close went through without a confirmation dialog (the shell was idle)'
    if ($confirm -ne [IntPtr]::Zero) { [void](Clear-CloseConfirmDialog -ProcessId $g.Pid) }

    $afterPane = Get-PaneCount
    Assert ($afterPane -eq ($before - 1)) "Ctrl+W closed one pane ($before -> $afterPane)"
    Assert (Test-TestWindowExists -Window $g.Top) 'and the window itself survived (one pane was left)'

    # --- 2. the chord over the chooser --------------------------------------
    Write-Host ''
    Write-Host '2. Ctrl+W with the chooser focused dismisses the CHOOSER'
    $panesBefore = Get-PaneCount
    # Re-resolve the surface: section 1 closed a pane, and the HWND captured at
    # launch may be the one it destroyed.
    $g.Surface = Get-TestChildWindow -Window $g.Top -Class 'GhozttyTerminal'
    Assert ($g.Surface -ne [IntPtr]::Zero) 'a live terminal pane is there to open the chooser from'
    $chooser = Open-Chooser $g
    Assert ($chooser -ne [IntPtr]::Zero) 'the chooser opened'
    if ($chooser -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no chooser to drive'; exit 1 }
    Start-Sleep -Milliseconds 500

    # Focus sits in the filter EDIT when the chooser opens - the state a real
    # user is in when they change their mind and reach for Ctrl+W.
    $filter = ConvertTo-TestHwnd (Get-ChooserFilterField -Chooser $chooser)
    Assert ($filter -ne [IntPtr]::Zero) 'the chooser has its filter field'
    Assert (-not (Test-TestWindowEnabled -Window $g.Top)) 'the owner window is disabled while the chooser is up'

    [void](Send-TestKeys -Window $chooser -Target $filter -Modifiers ctrl -Key W)
    Start-Sleep -Seconds 1

    $gone = -not (Test-TestWindowExists -Window $chooser)
    if ($NegativeControl) {
        Assert (-not $gone) 'NEGATIVE CONTROL: the chooser SURVIVED Ctrl+W (pre-T603 behavior)'
    } else {
        Assert $gone 'Ctrl+W dismissed the chooser'
    }

    # Section 3 measures a SETTLED state - the chooser gone, the owner live
    # again - so a run where it survived (the negative control, or a red one)
    # dismisses it the way that has always worked before measuring. Otherwise
    # inverting assertion (1) drags an unrelated assertion red with it, and a
    # negative control that fails twice no longer says which claim it tested.
    if (Test-TestWindowExists -Window $chooser) {
        [void](Send-TestKeys -Window $chooser -Target $filter -Key Escape)
        Start-Sleep -Milliseconds 800
    }

    # --- 3. and nothing behind it was closed --------------------------------
    Write-Host ''
    Write-Host '3. the window behind the chooser is untouched'
    $panesAfter = Get-PaneCount
    Assert (Test-TestWindowExists -Window $g.Top) 'the terminal window behind the chooser is still open'
    Assert ($panesAfter -eq $panesBefore) "no pane behind the chooser was closed ($panesBefore -> $panesAfter)"
    Assert (Test-TestWindowEnabled -Window $g.Top) 'the owner window is enabled again once the chooser is gone'
    Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) 'the app survived the chord'

    Assert (-not (Test-TestDesktopLeak -ProcessId $g.Pid)) 'the run never took the interactive desktop'
} finally {
    Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
    Remove-TestDesktop
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red }
exit ([int]($script:fail -gt 0))
