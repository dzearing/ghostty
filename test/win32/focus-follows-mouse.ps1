# T75 acceptance: `focus-follows-mouse` focuses the split under the pointer.
#
# Pre-fix, win32 handleMouseMove only forwarded cursor position; the config
# was accepted and ignored. Mac (SurfaceView mouseMoved) and GTK (surface
# "is_cursor_still" + grabFocus) focus the hovered split on real motion.
#
# Two GUI launches:
#   run 1 (--focus-follows-mouse=true): split down -> A (top), B (bottom,
#     focused). Glide the pointer from B into A: focus must move to A with no
#     click; glide back: focus returns to B.
#   run 2 (default off): same layout, same glide -> focus must NOT move;
#     then a click on A must still focus it (positive control that the glide
#     genuinely reached pane A, so the no-op wasn't a dead mouse).
# Focused HWND is read with GetGUIThreadInfo; the T48 deferred-SetFocus
# path lands focus asynchronously, so assertions poll.
#
# T218 (batch 3): runs on a BACKGROUND Win32 desktop
# (test/win32/lib/TestDesktop.ps1), so it never takes the user's foreground -
# asserted at the end, not assumed. The private FfmDrv driver is gone.
#
# WHY THE GLIDE STILL MEANS SOMETHING WHEN NOTHING PHYSICAL MOVES. T218 named
# this script as one to check first, because `SetCursorPos`/`GetCursorPos` are
# not a usable channel off the input desktop and the product gates on "real
# pointer motion". Read the gate (Surface.focusFollowsMouse) and it is
# satisfied honestly by posted input: the motion test is
#
#     ClientToScreen(hwnd, lparam point) != app.ffm_last_screen_pos
#
# i.e. it compares the coordinates carried by the MESSAGE, not anything read
# back from the cursor. So a posted WM_MOUSEMOVE with moving coordinates is the
# same evidence a hardware move is - and `Send-TestMouse` sets the desktop's
# cursor position alongside each post anyway, so the two stay coherent.
#
# What posting does NOT reproduce is hit-testing: a posted message goes to the
# hwnd it names. Glide-TestPointer therefore names the pane that CONTAINS each
# step point, which is what the OS would have picked. Naming the wrong one
# would be the test lying to itself - the app would then focus whatever it was
# told, and the assertion would pass on a broken product.
#
# -NegativeControl inverts run 1's hover assertion and MUST fail.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#   powershell -NoProfile -File test\win32\focus-follows-mouse.ps1
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

# Isolate the IPC endpoint unconditionally - inherited by the app through
# CreateProcessW and by every `& $exe +...` below.
$env:GHOZTTY_PIPE_SUFFIX = "-ffmtest$PID"
$errlog = Join-Path $env:TEMP 'ghoztty-ffm-stderr.log'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

function Center($pane) {
    @{ X = [int](($pane.Left + $pane.Right) / 2); Y = [int](($pane.Top + $pane.Bottom) / 2) }
}

function Get-Panes([IntPtr]$top) {
    @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object Visible)
}

# The pane whose rect contains a screen point, or IntPtr::Zero.
function Resolve-PaneAt($panes, [int]$x, [int]$y) {
    foreach ($p in $panes) {
        if ($x -ge $p.Left -and $x -lt $p.Right -and $y -ge $p.Top -and $y -lt $p.Bottom) {
            return [IntPtr]$p.Hwnd
        }
    }
    return [IntPtr]::Zero
}

# Move the pointer from (x0,y0) to (x1,y1) in $Steps posted WM_MOUSEMOVEs,
# each addressed to the pane that really sits under that step - see the header.
# A step that lands outside every pane (the divider gap) is skipped rather than
# posted to a neighbour: the OS would not have delivered it to one either.
function Glide-TestPointer([IntPtr]$top, $panes, [int]$x0, [int]$y0, [int]$x1, [int]$y1, [int]$Steps = 8) {
    for ($i = 1; $i -le $Steps; $i++) {
        $x = [int]($x0 + ($x1 - $x0) * $i / $Steps)
        $y = [int]($y0 + ($y1 - $y0) * $i / $Steps)
        $target = Resolve-PaneAt $panes $x $y
        if ($target -eq [IntPtr]::Zero) { continue }
        [void](Send-TestMouse -Window $top -Target $target -X $x -Y $y -Action move)
    }
}

function Run-Case([string]$label, [string[]]$extraArgs, [bool]$expectFollow, [bool]$control) {
    Kill-RepoInstances
    if ($control) { Remove-Item $errlog -ErrorAction SilentlyContinue }

    # --session-persistence=false: each launch would otherwise write a layout
    # manifest that the next one restores (T131).
    $launchArgs = @('--session-persistence=false') + $extraArgs
    $sp = @{ Exe = $exe; Arguments = $launchArgs }
    if ($control) { $sp.StdErr = $errlog }
    $app = Start-OnTestDesktop @sp
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host "SETUP FAIL ($label): GUI died at launch"; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL ($label): top window not found"; exit 1 }

    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) `
        "$label window is NOT enumerable on the interactive desktop"

    & $exe +split --direction=down | Out-Null
    Start-Sleep -Milliseconds 800

    $panes = Get-Panes $top
    Assert ($panes.Count -eq 2) "$label setup: 2 visible panes"
    if ($panes.Count -ne 2) { Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue; exit 1 }
    $A = $panes | Sort-Object Top | Select-Object -First 1     # top pane
    $B = $panes | Sort-Object Top | Select-Object -Last 1      # bottom pane (focused after split)
    $ca = Center $A
    $cb = Center $B

    if ($control) {
        # Positive control: ctrl+k reaches binding dispatch (debug log only).
        [void](Send-TestKeys -Window $top -Target ([IntPtr]$B.Hwnd) -Modifiers ctrl -Key K)
        Start-Sleep -Milliseconds 400
        if (Test-Path $errlog) {
            if (-not (Select-String -Path $errlog -Pattern 'clear_screen' -Quiet)) {
                Write-Host 'ABORT: positive control failed (clear_screen never dispatched) - injection broken, not a T75 verdict'
                Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue; exit 1
            }
            Write-Host 'OK    positive control: injection reaches bindings (clear_screen dispatched)'
        } else {
            Write-Host 'OK    positive control degraded: no debug log (release build), chord delivery only'
        }
    }

    # Share the app's input queue and put keyboard focus on B (which the split
    # already focused). focusFollowsMouse also requires the parent to be the
    # thread's ACTIVE window, which is the other half of what this does.
    if (-not (Focus-TestWindow -Window $top -Child ([IntPtr]$B.Hwnd))) {
        Write-Host "SETUP FAIL ($label): could not focus the GUI"
        Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue; exit 1
    }
    Assert (Wait-TestFocus -Window $top -Expected $B.Hwnd) "$label setup: focus starts on pane B"

    # Park on B first. The gate records the first move it sees without acting
    # (no motion proven yet), so the glide that follows starts from a known
    # position instead of spending its first step on the record-only case.
    [void](Send-TestMouse -Window $top -Target ([IntPtr]$B.Hwnd) -X $cb.X -Y $cb.Y -Action move)

    # Glide from B's center into A's center. No clicks.
    Glide-TestPointer $top $panes $cb.X $cb.Y $ca.X $ca.Y
    Start-Sleep -Milliseconds 300

    if ($expectFollow) {
        Assert (Wait-TestFocus -Window $top -Expected $A.Hwnd) "$label hover moved focus to pane A (no click)"
        # And back again.
        Glide-TestPointer $top $panes $ca.X $ca.Y $cb.X $cb.Y
        Assert (Wait-TestFocus -Window $top -Expected $B.Hwnd) "$label hover moved focus back to pane B"
    } else {
        Start-Sleep -Milliseconds 700
        Assert ((Get-TestFocusedWindow -Window $top) -eq $B.Hwnd) "$label hover did NOT move focus (config off)"
        # Positive control: a click at the same spot must focus A, proving the
        # glide genuinely reached pane A.
        [void](Send-TestMouse -Window $top -Target ([IntPtr]$A.Hwnd) -X $ca.X -Y $ca.Y -Action click)
        Assert (Wait-TestFocus -Window $top -Expected $A.Hwnd) "$label click control: click on A focuses A"
    }

    Assert (-not ($app.Process -and $app.Process.HasExited)) "$label no crash"
    Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue
}

Kill-RepoInstances

# Watch the user's desktop for the whole run: nothing we launch may ever take
# foreground there. That is the complaint the test desktop exists to fix.
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()

try {
    # -NegativeControl flips run 1 to assert the hover does NOT follow, so a
    # passing run would mean the focus oracle reads the same answer either way.
    $follow = -not $NegativeControl
    if ($NegativeControl) { Write-Host 'NEGATIVE CONTROL: run 1 asserts hover does NOT move focus - this run MUST fail' }
    Run-Case 'on ' @('--focus-follows-mouse=true') $follow $true
    $launched += $script:GhozttyTestDesktopPids
    Run-Case 'off' @() $false $false
    $launched += $script:GhozttyTestDesktopPids
} finally {
    Remove-TestDesktop
    Kill-RepoInstances
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
