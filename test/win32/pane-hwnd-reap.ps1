# T681 acceptance: a closed split pane's child HWND is destroyed, not leaked.
#
# WHAT THE DEFECT WAS. Every terminal pane is a WS_CHILD `GhozttyTerminal`
# window that WGL renders into. `Surface.deinit` deliberately never called
# `DestroyWindow` on it - the first win32 commit recorded a segfault inside
# OPENGL32.dll's window-destruction hook when it did - and left the reap to the
# parent window's own teardown. So `+close` on a pane hid the window and walked
# away from it: measured while building T126's acceptance script, ten seconds
# after the close the dead pane was still enumerable under the top window,
# hidden, at its last size. One USER object per closed pane, held for the life
# of the app, against a per-process quota of 10k - on a box whose sessions run
# for days.
#
# THE FIX, and what that means for the oracle. The handle is now POSTED to the
# app's message-only window and destroyed from the top of the message loop
# (`App.reapSurfaceHwnd` -> `performSurfaceReap`), so the destroy no longer
# shares a stack with the WGL teardown. Deferral is what makes arm C matter:
# closing a WINDOW deinits every pane and then destroys the parent, and Win32
# frees the children with it, so those posted reaps arrive at handles that are
# already gone and may have been recycled. `surface_reap.reapable` is the
# two-factor gate that keeps them safe (class + a cleared GWLP_USERDATA), and
# arm C is what proves the app survives that path rather than destroying
# somebody else's window.
#
# Arms:
#   A. control - three panes, three GhozttyTerminal children.
#   B. after closing two, exactly one child remains (and no HIDDEN leftovers),
#      the app has not crashed, and the surviving pane is LIVE - a reap that
#      took the wrong window would show up here.
#   C. close the whole window, then open a fresh one: the app is still running
#      and the new pane is LIVE.
#
# -NegativeControl inverts arm B's count assertion and MUST fail.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#   powershell -NoProfile -File test\win32\pane-hwnd-reap.ps1
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

$env:GHOZTTY_PIPE_SUFFIX = '-panereap'
$errlog = Join-Path $env:TEMP 'ghoztty-pane-reap-stderr.log'
$tmp = Join-Path $env:TEMP "ghoztty-t681-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

# Every GhozttyTerminal child of the top window, hidden ones included - a
# leaked pane window is hidden by `Surface.unref` before it is abandoned, so
# counting only the visible ones would have passed against the defect.
function Get-PaneWindows([int64]$top) {
    return @(Get-TestChildWindows -Window ([IntPtr]$top) -Class 'GhozttyTerminal')
}

# Poll until the child count settles at $want (the reap is posted, so it lands
# a message-loop turn after `+close` returns), then report what we actually saw.
#
# Both PowerShell 5.1 array traps are live in these six lines, in opposite
# directions, and each one produced a red arm over a build that was correct:
#   * a bare `return $seen` UNROLLS a one-element array, and a lone
#     PSCustomObject's `.Count` is $null - not 1 - so the poll burns its whole
#     timeout and the caller reads "saw ";
#   * `return , $seen` stops that, but then wrapping the CALL in @() re-wraps
#     the array inside another one and every count reads 1.
# So: comma on the way out, no @() on the way in.
function Wait-PaneCount([int64]$top, [int]$want, [int]$timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $seen = @()
    do {
        $seen = @(Get-PaneWindows $top)
        if ($seen.Count -eq $want) { return , $seen }
        Start-Sleep -Milliseconds 400
    } while ((Get-Date) -lt $deadline)
    return , $seen
}

$td = New-TestDesktop -Interactive:$Interactive
Kill-RepoInstances

try {
    # persistence: off - this script closes panes and windows and then counts
    # what is left; a restore of the previous run's layout would seed panes
    # nobody in here created.
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @(
        '--config-default-files=false', '--session-persistence=false')
    $appPid = $app.Pid
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI is NOT enumerable on the interactive desktop'

    $top = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow' -TimeoutMs 20000
    Assert ($top -ne [IntPtr]::Zero) 'top-level window appeared'
    if ($top -eq [IntPtr]::Zero) { throw 'no window' }
    [void](Set-TestWindowPos -Window ([IntPtr]$top) -X 40 -Y 40 -Width 1200 -Height 820)

    # ---- A. control -------------------------------------------------------
    # One split at a time, each waited for: the second names the pane the first
    # created, and a `+split` fired before the window has its first pane is a
    # race that shows up as a missing pane three assertions later.
    $base = Wait-PaneCount ([int64]$top) 1
    Assert ($base.Count -eq 1) "A0 the window starts with one pane (saw $($base.Count))"
    & $exe +split --target=window-1 --name=t681b --direction=right 2>&1 | Out-Null
    [void](Wait-PaneCount ([int64]$top) 2)
    & $exe +split --target=t681b --name=t681c --direction=down 2>&1 | Out-Null
    $panes = Wait-PaneCount ([int64]$top) 3
    Assert ($panes.Count -eq 3) "A1 three panes are three child windows (saw $($panes.Count))"
    if ($panes.Count -ne 3) { throw 'splits did not land' }

    # ---- B. the reap ------------------------------------------------------
    & $exe +close --target=t681c 2>&1 | Out-Null
    & $exe +close --target=t681b 2>&1 | Out-Null
    $left = Wait-PaneCount ([int64]$top) 1
    $countOk = ($left.Count -eq 1)
    if ($NegativeControl) { $countOk = -not $countOk }
    Assert $countOk "B1 the two closed panes' child windows are gone (saw $($left.Count), want 1)"
    Assert (@($left | Where-Object { -not $_.Visible }).Count -eq 0) `
        'B2 nothing hidden is left behind under the window'

    $alive = Get-Process -Id $appPid -ErrorAction SilentlyContinue
    Assert ($null -ne $alive) 'B3 the app survived the destroys (no OPENGL32 teardown crash)'

    Assert (Test-PaneLive -Exe $exe -Target 'window-1' -Tmp $tmp -Tag 'B') `
        'B4 the surviving pane is LIVE: input reaches the child, output returns'

    # ---- C. the whole-window close, where the reaps land after the free ---
    & $exe +close --target=window-1 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    $alive = Get-Process -Id $appPid -ErrorAction SilentlyContinue
    Assert ($null -ne $alive) 'C1 the app survived closing a whole window of panes'

    & $exe +new-window --target=t681w2 2>&1 | Out-Null
    $top2 = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow' -TimeoutMs 20000
    Assert ($top2 -ne [IntPtr]::Zero) 'C2 a fresh window opens afterwards'
    Assert (Test-PaneLive -Exe $exe -Target 't681w2' -Tmp $tmp -Tag 'C') `
        'C3 the fresh pane is LIVE - no reap took its window'

    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI never became visible on the interactive desktop'
}
finally {
    Kill-RepoInstances
    Remove-TestDesktop
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" -ForegroundColor Green }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red }
exit $(if ($script:fail -eq 0) { 0 } else { 1 })
