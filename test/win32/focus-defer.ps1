# T48 regression: deferred SetFocus (release GUI deadlock).
#
# The release GUI froze because SetFocus was called synchronously inside a
# WndProc (mouse-button / focus-forward handlers). SetFocus runs the IME/CTF
# activation cascade inline, which does a synchronous SendMessage that
# re-enters our WindowProc; on that nested, non-pumping stack the GUI thread
# could Condition.wait() forever (see docs/design/t48-deadlock-dump-analysis.md).
# The fix posts WM_APP_SETFOCUS and performs the real SetFocus at the top of
# the message loop instead.
#
# This test drives the EXACT fixed path: it posts real WM_LBUTTONDOWN/UP into
# each terminal surface HWND (-> surfaceWndProc mouse handler -> deferSetFocus)
# and asserts:
#   1. Deferred focus actually MOVES real GUI focus to the clicked pane
#      (read cross-thread via GetGUIThreadInfo().hwndFocus).
#   2. Under rapid click churn + heavy terminal output (the deadlock's
#      load shape), the GUI thread stays RESPONSIVE: SendMessageTimeout
#      (SMTO_ABORTIFHUNG) returns before timeout and +list still answers
#      (the IPC listener lives on the GUI thread, so a hung thread = no reply).
#
# T218: runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1), so
# it never takes the user's foreground - asserted at the end, not assumed. The
# private FocusDrv driver is gone; its three pieces are now harness API:
# Send-TestMouse (the click), Get-TestFocusedWindow (the GUITHREADINFO read),
# and Send-TestClickStorm / Test-TestWindowResponsive (added here - the storm
# has to be UNPACED to be the load shape this bug needs, which is exactly what
# Send-TestMouse's per-click settling deliberately is not).
#
# The app is launched onto the test desktop explicitly rather than letting
# `+new-window` auto-spawn it: auto-spawn puts the GUI on the USER's desktop,
# which is the whole thing this migration fixes (batch-1 lesson).
#
# T107: the tail of this script used to fail on the box (+list timing out,
# focus not moving) and the verdict was HARNESS, not product - both causes
# were removed by the T218 migration above (posted input needs no foreground,
# and CleanSlate + --session-persistence=false removed the split-vs-agent
# race that intermittently yielded 1 surface). What T107 leaves behind is the
# load-shape assertions below: the flood and the storm are now measured, so
# this script can no longer report an idle app's responsiveness as the T48
# regression holding.
#
# -NegativeControl inverts the deferred-focus assertion and MUST fail.
#
# Only ever touches ghoztty processes from the repo zig-out.
#   powershell -NoProfile -File test\win32\focus-defer.ps1
param(
    [string]$Exe,
    [switch]$NegativeControl,
    [switch]$Interactive
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $Exe) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
if (-not (Test-Path $Exe)) { $Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }

# Isolate the IPC endpoint unconditionally - inherited by the app through
# CreateProcessW, by every `& $Exe +...` below, and by the Start-Job child.
$env:GHOZTTY_PIPE_SUFFIX = '-focusdefertest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

# T248: the app+agent kill and the debug session-layout manifest come from
# lib\CleanSlate.ps1 now — a pane from a previous run survives an app-only
# kill twice over and gets FOCUSED under the same target name. The flood-shell
# sweep stays here: it is this script's own litter, not shared hygiene.
function Stop-DebugGhoztty {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 0 | Out-Null
    # Kill any orphaned flood shell from the click-storm phase.
    Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" |
        Where-Object { $_.CommandLine -like '*FD-LOAD*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
}

# How far the FD-LOAD flood has counted, read out of the pane itself (-1 when
# no FD-LOAD line is in the tail at all). T107: this is what turns "under heavy
# terminal output" from a comment into an assertion - see the load-shape block
# below for why a green run without it proves nothing.
function Get-FloodCounter {
    $tail = (& $Exe +read --name=fdb --lines=400 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    $m = [regex]::Matches($tail, 'FD-LOAD-(\d+)')
    if ($m.Count -eq 0) { return -1 }
    return [int]$m[$m.Count - 1].Groups[1].Value
}

# Click a pane, then wait for the GUI thread's real keyboard focus to land on
# it (the deferred SetFocus makes this asynchronous, so it is polled).
function Test-ClickFocuses([IntPtr]$surface, [int]$timeoutMs) {
    $r = Get-TestWindowRect -Window $surface
    [void](Send-TestMouse -Window $script:top -Target $surface -X ($r.Left + 10) -Y ($r.Top + 10) -Action click)
    for ($t = 0; $t -lt $timeoutMs; $t += 50) {
        Start-Sleep -Milliseconds 50
        if ([IntPtr](Get-TestFocusedWindow -Window $script:top) -eq $surface) { return $true }
    }
    return $false
}

Stop-DebugGhoztty
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$app = $null

try {

Write-Host '== build a 3-pane window on the test desktop'
# --session-persistence=false: a restored layout manifest would decide the
# pane count this test asserts on (batch-2 lesson).
$app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false')
$script:appPid = $app.Pid
Start-Sleep -Seconds 3
if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
& $Exe +split --name=fdb --direction=down 2>&1 | Out-Null
Start-Sleep -Seconds 1
& $Exe +split --name=fdc --direction=right 2>&1 | Out-Null
Start-Sleep -Seconds 2

$script:top = Wait-TestWindow -ProcessId $script:appPid -Class 'GhozttyWindow'
Assert ($script:top -ne [IntPtr]::Zero) 'found GhozttyWindow top HWND'
Assert (-not (Test-TestDesktopLeak -ProcessId $script:appPid)) 'window is NOT enumerable on the interactive desktop'
$surfaces = @(Get-TestChildWindows -Window $script:top -Class 'GhozttyTerminal' |
    ForEach-Object { [IntPtr]$_.Hwnd })
Assert ($surfaces.Count -ge 3) "found >=3 terminal surface HWNDs (got $($surfaces.Count))"

Write-Host '== deferred focus moves real GUI focus to each clicked pane'
# Click each pane in turn; the deferred SetFocus (posted from the mouse
# WndProc, run at loop top) must land real keyboard focus on that HWND.
$allMoved = $true
foreach ($s in $surfaces) {
    if (-not (Test-ClickFocuses $s 1500)) { $allMoved = $false }
}
if ($NegativeControl) {
    Write-Host 'NEGATIVE CONTROL: asserting a click does NOT move focus - this run MUST fail'
    Assert (-not $allMoved) 'NEGATIVE CONTROL: click does not focus the clicked pane'
} else {
    Assert $allMoved 'click -> deferred SetFocus focuses each pane'
}
# And it is not a one-shot: bounce focus back to the first pane.
Assert (Test-ClickFocuses $surfaces[0] 1500) 'focus bounces back to first pane'

Write-Host '== responsive baseline (before load)'
Assert (Test-TestWindowResponsive -Window $script:top -TimeoutMs 3000) 'GUI thread pumps WM_NULL (idle)'

Write-Host '== rapid click churn under heavy terminal output'
# Flood one pane with output (the deadlock's load shape), then storm the
# mouse WndProc SetFocus path across all panes. Pre-fix, a re-entrant
# IME/CTF SetFocus on this stack could wedge the GUI thread here.
#
# T107: every assertion below this line is about behaviour UNDER LOAD, so the
# load itself is asserted, not assumed. Without that, a flood that never
# started (a +send-keys failure, a renamed pane, a shell that does not speak
# `for /L`) and a storm that posted nothing both leave this whole section
# green - the responsiveness of an idle app, reported as the deadlock
# regression holding.
& $Exe +send-keys --target=fdb "for /L %i in (1,1,150000) do @echo FD-LOAD-%i" Enter 2>&1 | Out-Null
Assert ($LASTEXITCODE -eq 0) "+send-keys delivered the flood command (exit $LASTEXITCODE)"
Start-Sleep -Milliseconds 500
$floodStart = Get-FloodCounter
Assert ($floodStart -gt 0) "flood is producing output before the storm (counter $floodStart)"

# Park focus off the storm's last target so "focus is on the last target"
# afterwards cannot be true by accident.
[void](Test-ClickFocuses $surfaces[0] 1500)
$rounds = 500                                     # 500 * 3 panes = 1500 focus changes
$expectedPosts = 2 * $rounds * $surfaces.Count    # a down + an up per click
$posted = Send-TestClickStorm -Targets $surfaces -Rounds $rounds
Assert ($posted -eq $expectedPosts) "click storm posted all $expectedPosts messages (got $posted)"

# ... and the app ACTED on them: the storm ends every round on the last
# target, so real GUI focus must arrive there. Posting is not processing.
$stormActed = $false
for ($t = 0; $t -lt 5000; $t += 100) {
    Start-Sleep -Milliseconds 100
    if ([IntPtr](Get-TestFocusedWindow -Window $script:top) -eq $surfaces[-1]) { $stormActed = $true; break }
}
Assert $stormActed 'storm clicks were processed (focus moved to the storm target)'

Write-Host '== still responsive after the storm'
$resp = $false
for ($i = 0; $i -lt 5; $i++) {
    if (Test-TestWindowResponsive -Window $script:top -TimeoutMs 3000) { $resp = $true; break }
    Start-Sleep -Milliseconds 200
}
Assert $resp 'GUI thread still pumps WM_NULL after click storm'

# The IPC listener runs ON the GUI thread; a reply within timeout proves the
# thread is pumping messages (a hang would leave +list stuck / pipe-busy).
$ipcOk = $false
$job = Start-Job { param($e) & $e +list } -ArgumentList $Exe
if (Wait-Job $job -Timeout 8) { Receive-Job $job | Out-Null; if ($job.State -eq 'Completed') { $ipcOk = $true } }
Remove-Job $job -Force -ErrorAction SilentlyContinue
Assert $ipcOk '+list answers within 8s (GUI-thread IPC listener alive)'

# Focus still controllable after the storm (thread not wedged mid-dispatch).
Assert (Test-ClickFocuses $surfaces[0] 2000) 'focus still moves after storm'

# The flood outlives the assertions it is the load for - measured ~2.5k
# lines/s on this box, so 150k lines runs about a minute while the block above
# takes a few seconds. Asserting that closes the window in which the counter
# could have been read from a flood that had already finished.
$floodEnd = Get-FloodCounter
Assert ($floodEnd -gt $floodStart) "flood was still producing across the assertions ($floodStart -> $floodEnd)"
Assert ($floodEnd -gt 0 -and $floodEnd -lt 150000) "flood had not run out before the assertions ended (counter $floodEnd)"

} finally {
    Write-Host '== teardown'
    # Read the launched pids BEFORE cleanup: Remove-TestDesktop empties the
    # live pid list as it kills (batch-3 lesson).
    $script:launched = @(Get-TestLaunchedPids)
    # Direct kill (not IPC +close): the flood keeps the GUI-thread IPC listener
    # busy, so an IPC teardown would just wait on it. Stop-DebugGhoztty also
    # reaps the orphaned FD-LOAD flood shell.
    Remove-TestDesktop
    Stop-DebugGhoztty
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($script:launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($($script:pass) assertions)"; exit 0 }
else { Write-Host "$($script:fail) FAILURE(S) ($($script:pass) passed)" -ForegroundColor Red; exit 1 }
