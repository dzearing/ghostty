# T448 acceptance: clicking a desktop notification focuses the PANE that
# raised it.
#
# WHAT THIS COVERS, AND WHAT IT DOES NOT. This script drives the ROUTING half
# of click-to-focus: given that the shell delivered a balloon click, does the
# right pane in the right window end up focused. It posts the tray callback
# (WM_APP_TRAY) into the app's message-only window directly, so it proves the
# handler and everything downstream of it - and, by T240's rule, it therefore
# proves NOTHING about DELIVERY: whether the shell actually sends
# NIN_BALLOONUSERCLICK for our balloon when a human clicks it. A test that
# synthesizes the trigger cannot validate the trigger.
#
# Delivery is the half that was broken, and it is settled elsewhere:
#
#   * By CODE. The balloon icon must ask for Windows 2000-or-later behavior
#     with NIM_SETVERSION or the NIN_* notifications are never sent at all.
#     That call was missing until T448 - see src/apprt/win32/tray_notify.zig,
#     which carries the MSDN quote ("NIM_SETVERSION must be called every time
#     a notification area icon is added") and the reason we register version 3
#     rather than 4.
#   * By MEASUREMENT, as far as it goes: case 6 below reads the app's own log
#     back and fails if the shell ever REFUSED the version registration. A
#     background desktop has no notification area at all, so that check reads
#     differently there - see the case for which half survives where, and for
#     the 2026-08-07 interactive measurement (both calls succeed against the
#     real shell).
#   * By HAND, once, on the interactive desktop, because a balloon renders
#     there and a real click cannot be faked off it:
#
#       zig build -Dapp-runtime=win32 -Doptimize=Debug
#       $env:GHOZTTY_PIPE_SUFFIX = '-t448manual'
#       .\zig-out\bin\ghoztty.exe
#       # in a pane, from powershell:
#       [console]::Write([char]27 + ']777;notify;Ghoztty;click me' + [char]7)
#       # click somewhere else to background that pane, then click the toast.
#       # PASS = the pane that printed the OSC is focused.
#
# T218 house rules apply: runs on a BACKGROUND Win32 desktop
# (test/win32/lib/TestDesktop.ps1) so it never takes the user's foreground,
# and only ever touches ghoztty processes from the repo zig-out.
#
# The message-only window is looked up pid-filtered (Find-TestMessageWindow):
# message-only windows are NOT isolated by the test desktop the way top-level
# windows are, so an unfiltered find could hand back the user's own running
# Ghoztty and every post below would drive their terminal.
#
# -NegativeControl inverts case 1's assertion and MUST fail.
#
#   powershell -NoProfile -File test\win32\notification-click-focus.ps1
param(
    [string]$Exe,
    [switch]$NegativeControl,
    [switch]$Interactive
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $Exe) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
if (-not (Test-Path $Exe)) { $Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }

# Isolate the IPC endpoint before any CLI call - inherited by the app through
# CreateProcessW and by every `& $Exe +...` below.
$env:GHOZTTY_PIPE_SUFFIX = "-notifclicktest$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-DebugGhoztty {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 500 | Out-Null
}

# --- the tray callback, exactly as the shell would send it -------------------
# WM_APP_TRAY is WM_APP+3 (App.zig); under NOTIFYICON_VERSION the wparam is the
# icon's uID and the low word of lparam is the event.
$WM_APP_TRAY = 0x8003
$NIN_BALLOONUSERCLICK = 0x0405
$NIN_BALLOONTIMEOUT = 0x0404
$UID_DESKTOP = 1

function Send-BalloonEvent([int]$Uid, [int]$Event) {
    return (Send-TestRawMessage -Window $script:msgWnd -Message ([uint32]$WM_APP_TRAY) `
        -WParam ([IntPtr]$Uid) -LParam ([IntPtr]$Event))
}

# Raise a desktop notification FROM a named pane, via OSC 777 printed by the
# pane's own shell - the real path a program in a pane uses, not an IPC verb.
# Bodies must differ between raises: the core suppresses identical
# notifications for 5s and rate-limits all of them to one per second.
function Invoke-Notification([string]$Pane, [string]$Body) {
    $cmd = "powershell -NoProfile -Command `"[console]::Write([char]27+']777;notify;Ghoztty;$Body'+[char]7)`""
    & $Exe +send-keys --target=$Pane $cmd Enter 2>&1 | Out-Null
    $ok = ($LASTEXITCODE -eq 0)
    Start-Sleep -Seconds 3   # shell start + the OSC actually reaching the app
    return $ok
}

# Focus is asynchronous (the T48 deferred SetFocus), so every focus claim polls.
function Wait-Focus([int64]$Expected, [int]$TimeoutMs = 4000) {
    for ($t = 0; $t -lt $TimeoutMs; $t += 100) {
        if ([int64](Get-TestFocusedWindow -Window $script:winA) -eq $Expected) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

# The pane focused right now, as an int64 (0 when the read fails).
function Get-FocusedPane { return [int64](Get-TestFocusedWindow -Window $script:winA) }

# The pane a fresh split leaves focused - which is how each pane's HWND is
# learned here. Geometry would work too, but "the split I just made is focused"
# is exact and needs no assumption about which side is which.
function Wait-NewFocus([int64]$NotThis, [int]$TimeoutMs = 6000) {
    for ($t = 0; $t -lt $TimeoutMs; $t += 100) {
        $f = Get-FocusedPane
        if ($f -ne 0 -and $f -ne $NotThis) { return $f }
        Start-Sleep -Milliseconds 100
    }
    return 0
}

Stop-DebugGhoztty
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$app = $null

try {

Write-Host '== setup: two windows, a named pane in each'
# --session-persistence=false: a restored layout would decide the pane count
# and focus this test asserts on.
$script:appLog = Join-Path $env:TEMP "ghoztty-notif-click-$PID.log"
$app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -StdErr $script:appLog
$script:appPid = $app.Pid
Start-Sleep -Seconds 3
if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }

$script:winA = Wait-TestWindow -ProcessId $script:appPid -Class 'GhozttyWindow'
Assert ($script:winA -ne [IntPtr]::Zero) 'found the first GhozttyWindow'
Assert (-not (Test-TestDesktopLeak -ProcessId $script:appPid)) 'window is NOT enumerable on the interactive desktop'

$paneA1 = Get-FocusedPane
Assert ($paneA1 -ne 0) 'the launch window has a focused pane'

& $Exe +split --name=nf-a2 --direction=down 2>&1 | Out-Null
$paneA2 = Wait-NewFocus $paneA1
Assert ($paneA2 -ne 0) 'split nf-a2 created and focused (window A, pane 2)'

& $Exe +new-window --target=nf-b 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $Exe +split --target=nf-b --name=nf-b2 --direction=down 2>&1 | Out-Null
$paneB2 = Wait-NewFocus $paneA2
Assert ($paneB2 -ne 0) 'split nf-b2 created and focused (window B, pane 2)'

$tops = @(Get-TestWindows -ProcessId $script:appPid -Class 'GhozttyWindow')
Assert ($tops.Count -eq 2) "two top-level windows exist (got $($tops.Count))"
$script:winB = [IntPtr]($tops | Where-Object { $_.Hwnd -ne [int64]$script:winA } | Select-Object -First 1 -ExpandProperty Hwnd)
Assert ($script:winB -ne [IntPtr]::Zero) 'identified window B'

$script:msgWnd = Find-TestMessageWindow -ProcessId $script:appPid
Assert ($script:msgWnd -ne [IntPtr]::Zero) "found OUR app's GhozttyMsg message-only window (pid $($script:appPid))"
if ($script:msgWnd -eq [IntPtr]::Zero) { throw 'no message window: refusing to post the tray callback anywhere else' }

Write-Host '== 1: a background pane raises a notification; the click focuses THAT pane'
Assert (Invoke-Notification 'nf-a2' 'case-one') '+send-keys delivered the OSC 777 notify (case 1)'
[void](Focus-TestWindow -Window $script:winA -Child ([IntPtr]$paneA1))
Assert ((Get-FocusedPane) -eq $paneA1) 'focus parked off the notifying pane'
Assert (Send-BalloonEvent $UID_DESKTOP $NIN_BALLOONUSERCLICK) 'posted the balloon click'
$focused = Wait-Focus $paneA2
if ($NegativeControl) {
    Write-Host 'NEGATIVE CONTROL: asserting the click does NOT focus the raiser - this run MUST fail'
    Assert (-not $focused) 'NEGATIVE CONTROL: click does not focus the notifying pane'
} else {
    Assert $focused 'the click focused the pane that raised the notification'
}

Write-Host '== 2: with two windows, the click presents the raiser''s WINDOW too'
Assert (Invoke-Notification 'nf-b2' 'case-two') '+send-keys delivered the OSC 777 notify (case 2)'
[void](Focus-TestWindow -Window $script:winA -Child ([IntPtr]$paneA1))
Assert ((Get-FocusedPane) -eq $paneA1) 'focus parked in the OTHER window'
Assert (Send-BalloonEvent $UID_DESKTOP $NIN_BALLOONUSERCLICK) 'posted the balloon click'
Assert (Wait-Focus $paneB2) 'the click focused the pane in the non-active window'
# Activation, not foreground: a background desktop has no foreground window,
# so "this window was presented" is read off the GUI thread's active window.
Assert ([int64](Get-TestActiveWindow -Window $script:winA) -eq [int64]$script:winB) `
    'the raiser''s window became the active window'

Write-Host '== 3: only a CLICK acts - a balloon that merely timed out must not steal focus'
Assert (Invoke-Notification 'nf-a2' 'case-three') '+send-keys delivered the OSC 777 notify (case 3)'
[void](Focus-TestWindow -Window $script:winB -Child ([IntPtr]$paneB2))
Assert ((Get-FocusedPane) -eq $paneB2) 'focus parked off the notifying pane'
Assert (Send-BalloonEvent $UID_DESKTOP $NIN_BALLOONTIMEOUT) 'posted a balloon TIMEOUT'
Start-Sleep -Milliseconds 1500
Assert ((Get-FocusedPane) -eq $paneB2) 'a timed-out balloon did not move focus'
# Control: the same post channel, same notification, with the click event -
# without this, "nothing moved" would also be the reading of a dead channel.
Assert (Send-BalloonEvent $UID_DESKTOP $NIN_BALLOONUSERCLICK) 'posted the balloon click'
Assert (Wait-Focus $paneA2) 'CONTROL: the click on the same notification does move focus'

Write-Host '== 4: two notifications from different panes - the LAST raiser wins'
Assert (Invoke-Notification 'nf-a2' 'case-four-first') '+send-keys delivered the first OSC 777 notify'
Assert (Invoke-Notification 'nf-b2' 'case-four-second') '+send-keys delivered the second OSC 777 notify'
[void](Focus-TestWindow -Window $script:winA -Child ([IntPtr]$paneA1))
Assert ((Get-FocusedPane) -eq $paneA1) 'focus parked off both notifying panes'
Assert (Send-BalloonEvent $UID_DESKTOP $NIN_BALLOONUSERCLICK) 'posted the balloon click'
Assert (Wait-Focus $paneB2) 'the click focused the LAST pane to raise a notification'

Write-Host '== 5: the notifying pane is closed before the click - no crash'
Assert (Invoke-Notification 'nf-a2' 'case-five') '+send-keys delivered the OSC 777 notify (case 5)'
& $Exe +close --target=nf-a2 2>&1 | Out-Null
Start-Sleep -Seconds 3
Assert (Send-BalloonEvent $UID_DESKTOP $NIN_BALLOONUSERCLICK) 'posted the balloon click for a closed pane'
Start-Sleep -Seconds 2
& $Exe +list 2>&1 | Out-Null
Assert ($LASTEXITCODE -eq 0) '+list still answers (the GUI thread survived the click)'
Assert (Test-TestWindowExists -Window $script:winA) 'window A is still alive'
Assert (Test-TestWindowExists -Window $script:winB) 'window B is still alive'

Write-Host '== 6: the version registration is not silently failing'
# The one piece of DELIVERY this script can honestly measure, and it has to be
# read differently per desktop, because a BACKGROUND desktop has no shell:
# there is no notification area to add an icon to, so NIM_ADD fails and
# NIM_SETVERSION - which addresses an icon by (hWnd, uID) - necessarily fails
# with it. That is the harness, not the product.
#
# What is still assertable off the interactive desktop is the SHAPE of the
# failure. "NIM_SETVERSION failed while NIM_ADD succeeded" is the genuine
# defect (a version the shell refuses, e.g. asking for 4 with a struct sized
# for 2) and would go red here; "both failed" is the shell-less desktop. The
# cases above prove the balloons were raised at all, so a log with no
# NIM_SETVERSION line whatsoever would mean the notification path never ran.
#
# Measured on the interactive desktop 2026-08-07 (T448): a debug build under a
# private pipe suffix raised an OSC 777 notification and logged NO warning at
# all - NIM_ADD and NIM_SETVERSION both succeed against the real shell, so the
# box accepts NOTIFYICON_VERSION. `-Interactive` asserts exactly that.
$logText = if (Test-Path $script:appLog) { Get-Content $script:appLog -Raw } else { '' }
Assert ($logText.Length -gt 0) 'CONTROL: the app log was captured at all'
if ($Interactive -or $env:GHOZTTY_TEST_INTERACTIVE -eq '1') {
    Assert ($logText -notmatch 'NIM_SETVERSION failed') 'the shell accepted NIM_SETVERSION for every balloon'
} else {
    $bad = [regex]::Matches($logText, 'NIM_SETVERSION failed[^\r\n]*NIM_ADD succeeded')
    Assert ($bad.Count -eq 0) 'no balloon had its version REFUSED while its icon was accepted'
    Assert ($logText -match 'NIM_SETVERSION') `
        'CONTROL: the balloon path ran (this desktop has no shell, so it must have logged)'
}

} finally {
    Write-Host '== teardown'
    $script:launched = @(Get-TestLaunchedPids)
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
