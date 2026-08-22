# Machine-chooser OPEN-CHORD acceptance (tracker T746).
#
# User report 2026-08-11: "Ctrl+Shift+N does nothing - the machine chooser
# never appears." The chord is the Windows analog of Cmd-Shift-N and, per the
# T22c decision-3 note in `Surface.handleKeyEvent`, is intercepted LOCALLY
# there rather than through a core binding action (there is no
# `new_remote_window` action to bind). That single interception point is the
# defect: it is reached only while a TERMINAL pane owns the keyboard focus.
#
# A window's focus is routinely somewhere else:
#
#   * a VIEWER pane (a rendered doc, a dashboard, a web page) - its keyboard
#     lives inside WebView2's Chromium children and comes back to us through
#     `viewer_accel.forwards`, which has no arm for a chord that is not a
#     binding action. So the chord fell through to the cross-platform
#     `ctrl+shift+n -> new_window` default and opened a PLAIN LOCAL WINDOW,
#     which is worse than nothing: the user asked for the chooser and got a
#     different window, in a build whose whole point is that the chord means
#     "new remote window" here.
#
#   * the TOP-LEVEL window itself, which happens whenever a child control the
#     app created takes and then drops focus. `Window.wndProc` has no
#     WM_KEYDOWN arm at all, so the chord is dropped on the floor - the
#     literal "nothing happens" the report describes.
#
# Three sections, in the order that makes a red one readable:
#
#   1. POSITIVE CONTROL, mandatory and first - a focused terminal pane opens
#      the chooser. Without it every "the chooser did not open" below is
#      equally consistent with the keystroke never being delivered, which is
#      exactly how a confident wrong negative gets recorded.
#   2. A focused VIEWER pane opens the chooser - and does NOT open a second
#      terminal window instead. Both halves are asserted: "the chooser is
#      absent" and "a plain window appeared" are different defects and the
#      second one is invisible if you only count choosers.
#   3. A focused top-level window (no child focus) opens the chooser.
#
# -NegativeControl inverts sections 2 and 3 to expect the PRE-FIX behavior
# (no chooser), which must FAIL - it is how a run proves this script
# discriminates rather than riding a green desktop.
#
#   powershell -NoProfile -File test\win32\chooser-open-chord.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl
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
$env:GHOZTTY_PIPE_SUFFIX = "-t746$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

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

# PS 5.1 unrolls a one-element array on return, so `.Count` on the result is
# $null when the app has a single window — and `$null -eq $null` made both
# "no plain window was opened instead" assertions pass vacuously in this
# script's first run. Every caller re-wraps with @(...).
function Get-TopWindows($procId) {
    return @(Get-TestWindows -ProcessId $procId -Class 'GhozttyWindow')
}

function Get-Chooser($procId) {
    return Wait-TestWindow -ProcessId $procId -Class 'GhozttyMachineChooser' -TimeoutMs 4000
}

function Close-Chooser($top, $procId) {
    $c = Get-TestWindows -ProcessId $procId -Class 'GhozttyMachineChooser'
    foreach ($h in @($c)) {
        [void](Send-TestKeys -Window ([IntPtr][int64]$h.Hwnd) -Target ([IntPtr][int64]$h.Hwnd) -Key Escape)
    }
    Start-Sleep -Milliseconds 800
}

# persistence: --session-persistence=false - this run is about a key chord, and
# a restore of the previous script's panes would seed the window with panes
# this one never opened (T158).
function Launch-Gui($errlog) {
    $args = @('--window-width=110', '--window-height=32', '--session-persistence=false')
    $app = Start-OnTestDesktop -Exe $Exe -Arguments $args -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { return $null }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { return $null }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { return $null }
    return @{ App = $app; Pid = $app.Pid; Top = $top; Surface = $surface }
}

Write-Host 'T746 machine chooser open chord'
Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
New-TestDesktop | Out-Null

$errlog = Join-Path $env:TEMP "ghoztty-t746-stderr-$PID.log"
Remove-Item $errlog -ErrorAction SilentlyContinue

try {
    $g = Launch-Gui $errlog
    if (-not $g) {
        Write-TestAssertedNothing -Label 'T746 CHOOSER OPEN CHORD' -Reason 'the GUI did not come up'
    }

    # --- 1. positive control: a focused TERMINAL opens the chooser ----------
    Write-Host ''
    Write-Host '1. POSITIVE CONTROL: Ctrl+Shift+N with a terminal focused'
    Assert (Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl, shift -Key N) `
        'the chord was injected at the terminal pane'
    $chooser = Get-Chooser $g.Pid
    Assert ($chooser -ne [IntPtr]::Zero) 'CONTROL: a focused terminal opens the chooser'
    Close-Chooser $g.Top $g.Pid
    Assert ((Get-TestWindows -ProcessId $g.Pid -Class 'GhozttyMachineChooser').Count -eq 0) `
        'CONTROL: and Escape dismissed it again'

    # --- 2. a focused VIEWER pane ------------------------------------------
    Write-Host ''
    Write-Host '2. Ctrl+Shift+N with a VIEWER pane focused'
    & $Exe +split --direction=right --name=t746doc --view=about:blank 2>$null | Out-Null
    Start-Sleep -Seconds 3

    $chromeHwnd = [IntPtr]::Zero
    $viewHost = [IntPtr]::Zero
    for ($t = 0; $t -lt 50 -and $chromeHwnd -eq [IntPtr]::Zero; $t++) {
        foreach ($h in @(Get-TestChildWindows -Window $g.Top -Class 'GhozttyViewer')) {
            if (-not $h.Visible) { continue }
            $widget = @(Get-TestChildWindows -Window ([IntPtr][int64]$h.Hwnd) -Class '*' |
                Where-Object { $_.Class -eq 'Chrome_WidgetWin_1' })
            if ($widget.Count -ge 1) {
                $chromeHwnd = [IntPtr][int64]$widget[0].Hwnd
                $viewHost = [IntPtr][int64]$h.Hwnd
            }
        }
        if ($chromeHwnd -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 200 }
    }
    Assert ($chromeHwnd -ne [IntPtr]::Zero) 'the viewer pane and its Chromium input child are up'

    if ($chromeHwnd -ne [IntPtr]::Zero) {
        Focus-TestWindow -Window $g.Top -Child $viewHost | Out-Null
        Start-Sleep -Milliseconds 400

        $topsBefore = @(Get-TopWindows $g.Pid).Count
        Assert (Send-TestViewerChord -Window $g.Top -Target $chromeHwnd -Modifiers ctrl, shift -Key N) `
            'the chord was injected at the viewer pane'
        Start-Sleep -Milliseconds 1500
        $chooser2 = Get-Chooser $g.Pid
        $topsAfter = @(Get-TopWindows $g.Pid).Count

        if ($NegativeControl) {
            Assert ($chooser2 -eq [IntPtr]::Zero) `
                'NEGATIVE CONTROL: a focused viewer does NOT open the chooser (pre-T746; must FAIL)'
        } else {
            Assert ($chooser2 -ne [IntPtr]::Zero) 'a focused viewer pane opens the chooser'
        }
        Assert ($topsAfter -eq $topsBefore) `
            "and no plain terminal window was opened instead ($topsBefore -> $topsAfter)"
        Close-Chooser $g.Top $g.Pid
    }

    # --- 3. a focused TOP-LEVEL window (no child focus) --------------------
    Write-Host ''
    Write-Host '3. Ctrl+Shift+N with the top-level window focused (no child)'
    Focus-TestWindow -Window $g.Top | Out-Null
    Start-Sleep -Milliseconds 400
    $topsBefore3 = @(Get-TopWindows $g.Pid).Count
    Assert (Send-TestKeys -Window $g.Top -Modifiers ctrl, shift -Key N) `
        'the chord was injected at the top-level window'
    Start-Sleep -Milliseconds 1200
    $chooser3 = Get-Chooser $g.Pid
    $topsAfter3 = @(Get-TopWindows $g.Pid).Count

    if ($NegativeControl) {
        Assert ($chooser3 -eq [IntPtr]::Zero) `
            'NEGATIVE CONTROL: the top-level window does NOT open the chooser (pre-T746; must FAIL)'
    } else {
        Assert ($chooser3 -ne [IntPtr]::Zero) 'the top-level window opens the chooser'
    }
    Assert ($topsAfter3 -eq $topsBefore3) `
        "and no plain terminal window was opened instead ($topsBefore3 -> $topsAfter3)"
    Close-Chooser $g.Top $g.Pid
    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
    Remove-TestDesktop
}

Write-Host ''
Write-TestVerdict -Label 'T746 CHOOSER OPEN CHORD' -Pass $script:pass -Fail $script:fail
