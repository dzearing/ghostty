# T1390 acceptance: closing a REMOTE window offers Disconnect, and Disconnect
# leaves the remote process running.
#
# What was wrong: closing a window whose terminals run on another machine always
# terminated the remote child. There was no way to step away from a long build
# on a remote box and come back to it - shutting the window was the same as
# ending the work. The mechanism to do better already existed on both sides of
# the wire (freeing a surface DETACHes its agent session and only CLOSEs it when
# the app marked it CLOSE-on-free); it simply was not reachable from the UI.
#
# The oracle throughout is the OS process table, never anything the app says: a
# loopback `ghoztty-agent --listen` stands in for the other machine, so the
# "remote" child is a real local process this script can watch live or die.
#
#   Section A - Disconnect. The confirmation offers three buttons, Disconnect is
#     the DEFAULT, and after clicking it the window is gone and the remote shell
#     is STILL RUNNING. This is the feature.
#   Section B - Close. The same dialog, the other affirmative: the window is
#     gone and the remote shell is gone with it. Without B, a Disconnect that
#     did nothing at all would look identical to a Disconnect that worked.
#   Section C - Cancel. The window survives and the shell survives, so the third
#     button did not cost the dialog its dismissive answer.
#   Section D - `ghoztty +close`. The programmatic path must raise NO dialog and
#     must return - a modal there would wedge every later `ghoztty +...` command
#     - and it must still END the session, which is what `+close` documents.
#   Section E - `confirm-close-surface = false`. A user who turned confirmations
#     off asked for no prompts, and this feature does not get to reintroduce
#     one: the remote window closes with no dialog at all.
#   Section F - a LOCAL window and a LOCAL pane. The dialog each shows has NO
#     Disconnect button.
#     This is the scope demonstration: a local shell is a child of this app and
#     there is no session to leave behind, and a local session-persistence pane
#     is excluded on purpose because "closing a pane ends its session" is that
#     feature's documented contract.
#
# Sections A/B/C run their shells IDLE on purpose. A remote window is confirmed
# even when nothing is running under it - ending a process on another machine is
# not the recoverable thing an idle local shell is - so an idle shell is the
# state in which the widened gate is the ONLY reason a dialog can appear.
#
#   powershell -NoProfile -File test\win32\remote-disconnect.ps1
#   powershell -NoProfile -File test\win32\remote-disconnect.ps1 -NegativeControl
#
# -NegativeControl inverts section A's central claim (that the shell survives a
# Disconnect), so a run that cannot tell the two answers apart scores red.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [int]$Port = 47913,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:pass = 0
$script:fail = 0

function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
[void](Set-GhozttyTestIsolation -Tag 'remdisc')

$td = New-TestDesktop

# BS_DEFPUSHBUTTON: the Enter default, which for this dialog must be Disconnect.
$BS_DEFPUSHBUTTON = 0x1
$WM_CLOSE = 0x0010

function Stop-Everything {
    [void](Reset-GhozttyTestState -Exe $Exe -SettleMs 800)
}

# Every live descendant pid of $Root, from the OS process table.
function Get-DescendantPids([int]$Root) {
    $all = Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name
    $byParent = @{}
    foreach ($p in $all) {
        $key = [int]$p.ParentProcessId
        if (-not $byParent.ContainsKey($key)) { $byParent[$key] = @() }
        $byParent[$key] += $p
    }
    $out = @()
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($Root)
    $seen = @{}
    while ($queue.Count -gt 0) {
        $cur = [int]$queue.Dequeue()
        if ($seen.ContainsKey($cur)) { continue }
        $seen[$cur] = $true
        foreach ($child in $byParent[$cur]) {
            $out += $child
            $queue.Enqueue([int]$child.ProcessId)
        }
    }
    # Plain `return`: `return ,$out` would wrap an EMPTY array in a one-element
    # array, so `@(...)` counts 1 where there are none (PS 5.1).
    return $out
}

# The per-session PTY HOLDER processes (`ghoztty-agent.exe --pty-host`, T905):
# the holder deliberately escapes the agent's job and, on one escape tier, its
# parent link too - so the shell is not always an agent descendant. Found by
# command line for that reason.
function Get-PtyHolderPids {
    $out = @()
    $zigOut = Join-Path $repo 'zig-out'
    foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" -ErrorAction SilentlyContinue)) {
        if (-not $p.ExecutablePath) { continue }
        if (-not $p.ExecutablePath.StartsWith($zigOut, 'OrdinalIgnoreCase')) { continue }
        if ($p.CommandLine -and $p.CommandLine -match '--pty-host') { $out += [int]$p.ProcessId }
    }
    return $out
}

function Test-PidAlive([int]$ProcessId) {
    if ($ProcessId -le 0) { return $false }
    return $null -ne (Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue)
}

# The shell the listening agent spawned for the remote session. `$Known` is the
# set of shell pids earlier sections already claimed, so a section that opens a
# second remote window does not re-find the first one's shell.
function Find-RemoteShellPid([int]$AgentPid, [int[]]$Known) {
    for ($t = 0; $t -lt 40; $t++) {
        foreach ($root in (@($AgentPid) + @(Get-PtyHolderPids))) {
            foreach ($p in (Get-DescendantPids $root)) {
                if ($p.Name -match '^(conhost|openconsole)\.exe$') { continue }
                # A holder reached through the agent is a waypoint, not the
                # shell; its own descendants are enumerated by this same walk.
                if ($p.Name -eq 'ghoztty-agent.exe') { continue }
                if ($Known -contains [int]$p.ProcessId) { continue }
                return [int]$p.ProcessId
            }
        }
        Start-Sleep -Milliseconds 250
    }
    return 0
}

# The confirm dialog, waited for in either direction. Mirrors
# close-confirm-idle.ps1's helper of the same name.
function Wait-Dialog([int]$GuiPid, [bool]$Appear, [int]$TimeoutMs = 6000) {
    if ($Appear) { return Wait-TestWindow -ProcessId $GuiPid -Class 'GhozttyConfirmDialog' -TimeoutMs $TimeoutMs }
    $waited = 0
    while ($waited -lt $TimeoutMs) {
        if ((Get-TestWindow -ProcessId $GuiPid -Class 'GhozttyConfirmDialog') -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
        Start-Sleep -Milliseconds 200
        $waited += 200
    }
    return (Get-TestWindow -ProcessId $GuiPid -Class 'GhozttyConfirmDialog')
}

function Get-DialogButtons([IntPtr]$Dialog) {
    return @(Get-TestControls -Window $Dialog -Class 'Button' | Where-Object { $_.Text -and $_.Text -ne '' })
}

function Get-DialogButton([IntPtr]$Dialog, [string]$Caption) {
    foreach ($b in (Get-DialogButtons $Dialog)) {
        if ($b.Text -eq $Caption) { return $b }
    }
    return $null
}

function Wait-WindowGone([IntPtr]$Window, [int]$TimeoutMs = 8000) {
    $waited = 0
    while ($waited -lt $TimeoutMs) {
        if (-not (Test-TestWindowExists -Window $Window)) { return $true }
        Start-Sleep -Milliseconds 200
        $waited += 200
    }
    return (-not (Test-TestWindowExists -Window $Window))
}

# The new top-level window that appeared for $ProcessId since $Before.
function Wait-NewTopWindow([int]$ProcessId, $Before, [int]$TimeoutMs = 15000) {
    $waited = 0
    while ($waited -lt $TimeoutMs) {
        foreach ($w in (Get-TestWindows -ProcessId $ProcessId)) {
            if ($Before -notcontains $w.Hwnd) { return [IntPtr]$w.Hwnd }
        }
        Start-Sleep -Milliseconds 250
        $waited += 250
    }
    return [IntPtr]::Zero
}

function Start-Gui([string[]]$ExtraArgs) {
    $app = Start-OnTestDesktop -Exe $Exe -Arguments $ExtraArgs
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { return $null }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { return $null }
    Set-TestWindowSize -Window $top -Width 1100 -Height 700 | Out-Null
    Start-Sleep -Milliseconds 400
    return @{ App = $app; Pid = $app.Pid; Top = $top }
}

# Open a remote window against the loopback agent and return
# { Hwnd, Shell } - the window and the shell process it is really driving.
function Open-RemoteWindow([int]$GuiPid, [string]$Name, [int]$AgentPid, [int[]]$KnownShells) {
    $before = @(Get-TestWindows -ProcessId $GuiPid | ForEach-Object { $_.Hwnd })
    [void](Invoke-OnTestDesktop -Exe $Exe -Arguments @('+new-remote-window', '--host=127.0.0.1', "--port=$Port", "--name=$Name"))
    $hwnd = Wait-NewTopWindow $GuiPid $before
    if ($hwnd -eq [IntPtr]::Zero) { return $null }
    $shell = Find-RemoteShellPid $AgentPid $KnownShells
    return @{ Hwnd = $hwnd; Shell = $shell }
}

# ---------------------------------------------------------------------------

$agent = $null
$g = $null
$shells = @()

try {
    Stop-Everything

    if (-not (Test-Path $AgentExe)) {
        Write-Host "SETUP FAIL: no agent at $AgentExe"
        $script:fail++
        exit 1
    }

    Write-Host ""
    Write-Host "== setup: a loopback agent stands in for the other machine =="
    $env:GHOSTTY_AGENT_LOCK = Join-Path $env:TEMP 'ghoztty-t1390-agent.lock'
    $agent = Start-Process -FilePath $AgentExe `
        -ArgumentList '--listen', "127.0.0.1:$Port", '--headless' `
        -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2
    Assert (-not $agent.HasExited) 'the listening agent is up'
    if ($agent.HasExited) { exit 1 }

    # Persistence OFF for the app's own base window: the only ghoztty-agent on
    # the box is then our listener, so the shell oracle cannot pick up a
    # local-agent session by mistake - and section F's local window is a plain
    # child-of-the-app shell, which is the case it is there to cover.
    $g = Start-Gui @('--session-persistence=false')
    if (-not $g) { Write-Host 'SETUP FAIL: GUI did not come up'; $script:fail++; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $g.Pid)) 'the app is NOT on the interactive desktop'
    Assert-GhozttyIsolated -Exe $Exe

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "== A: Disconnect leaves the remote process running =="

    $rem = Open-RemoteWindow $g.Pid 'remdiscA' $agent.Id $shells
    Assert ($null -ne $rem -and $rem.Hwnd -ne [IntPtr]::Zero) 'A: +new-remote-window opened a window'
    if ($null -eq $rem -or $rem.Hwnd -eq [IntPtr]::Zero) { exit 1 }
    Assert ($rem.Shell -gt 0) "A: the agent spawned a shell for the remote session (pid $($rem.Shell))"
    if ($rem.Shell -le 0) { exit 1 }
    $shells += $rem.Shell

    # An IDLE remote shell: the state in which the widened gate is the ONLY
    # reason a dialog can appear at all.
    $idle = @(Get-DescendantPids $rem.Shell)
    Assert ($idle.Count -eq 0) "A: the remote shell is idle before the close ($($idle.Count) descendants)"

    # The title-bar X / Alt+F4 path, exactly: WM_CLOSE to the window.
    [void](Send-TestWindowClose -Window $rem.Hwnd)
    $dlg = Wait-Dialog $g.Pid $true
    Assert ($dlg -ne [IntPtr]::Zero) 'A: closing an IDLE remote window still confirms'
    if ($dlg -eq [IntPtr]::Zero) { exit 1 }

    $buttons = Get-DialogButtons $dlg
    Assert ($buttons.Count -eq 3) "A: the confirmation offers three buttons (got $($buttons.Count): $(($buttons | ForEach-Object { $_.Text }) -join ', '))"
    $disconnect = Get-DialogButton $dlg 'Disconnect'
    $close = Get-DialogButton $dlg 'Close'
    $cancel = Get-DialogButton $dlg 'Cancel'
    Assert ($null -ne $disconnect) 'A: there is a Disconnect button'
    Assert ($null -ne $close) 'A: there is a Close button'
    Assert ($null -ne $cancel) 'A: there is a Cancel button'
    if ($null -eq $disconnect -or $null -eq $close -or $null -eq $cancel) { exit 1 }

    # The row reads [Disconnect] [Close] [Cancel]: the dismissive answer last,
    # which is where this dialog has always put it on Windows.
    Assert ($disconnect.Right -le $close.Left) 'A: Disconnect sits left of Close'
    Assert ($close.Right -le $cancel.Left) 'A: Close sits left of Cancel'

    # Disconnect is the Enter default - the answer that ends nothing.
    $dstyle = Get-TestWindowStyle -Window ([IntPtr]$disconnect.Hwnd)
    $cstyle = Get-TestWindowStyle -Window ([IntPtr]$close.Hwnd)
    Assert (($dstyle -band $BS_DEFPUSHBUTTON) -ne 0) 'A: Disconnect is the default button'
    Assert (($cstyle -band $BS_DEFPUSHBUTTON) -eq 0) 'A: Close is not the default button'

    # The message names the machine and both outcomes, so the choice is
    # readable without knowing what the buttons mean.
    $msg = ''
    foreach ($s in (Get-TestControls -Window $dlg -Class 'Static')) { if ($s.Text) { $msg += $s.Text } }
    Assert ($msg -match '127\.0\.0\.1') 'A: the message names the machine the session runs on'
    Assert ($msg -match 'resume') 'A: the message says the session can be resumed later'

    [void](Send-TestControlClick -Control ([IntPtr]$disconnect.Hwnd))
    Assert (Wait-WindowGone $rem.Hwnd) 'A: the remote window closes on Disconnect'

    # THE claim. Give the DETACH/CLOSE decision time to reach the agent and be
    # acted on, then ask the process table.
    Start-Sleep -Seconds 3
    $alive = Test-PidAlive $rem.Shell
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: asserting the shell DIED on Disconnect - this run MUST fail'
        Assert (-not $alive) 'A: the remote shell keeps running after Disconnect (inverted)'
    } else {
        Assert $alive 'A: the remote shell KEEPS RUNNING after Disconnect'
    }

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "== B: Close still ends the remote process =="

    $remB = Open-RemoteWindow $g.Pid 'remdiscB' $agent.Id $shells
    Assert ($null -ne $remB -and $remB.Hwnd -ne [IntPtr]::Zero) 'B: remote window opened'
    if ($null -eq $remB -or $remB.Hwnd -eq [IntPtr]::Zero) { exit 1 }
    Assert ($remB.Shell -gt 0) "B: the agent spawned a second shell (pid $($remB.Shell))"
    if ($remB.Shell -le 0) { exit 1 }
    $shells += $remB.Shell

    [void](Send-TestWindowClose -Window $remB.Hwnd)
    $dlg = Wait-Dialog $g.Pid $true
    Assert ($dlg -ne [IntPtr]::Zero) 'B: the confirmation appears'
    if ($dlg -eq [IntPtr]::Zero) { exit 1 }
    $close = Get-DialogButton $dlg 'Close'
    Assert ($null -ne $close) 'B: there is a Close button'
    if ($null -eq $close) { exit 1 }

    [void](Send-TestControlClick -Control ([IntPtr]$close.Hwnd))
    Assert (Wait-WindowGone $remB.Hwnd) 'B: the remote window closes on Close'
    Start-Sleep -Seconds 3
    Assert (-not (Test-PidAlive $remB.Shell)) 'B: the remote shell is GONE after Close'

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "== C: Cancel keeps the window and the session =="

    $remC = Open-RemoteWindow $g.Pid 'remdiscC' $agent.Id $shells
    Assert ($null -ne $remC -and $remC.Hwnd -ne [IntPtr]::Zero) 'C: remote window opened'
    if ($null -eq $remC -or $remC.Hwnd -eq [IntPtr]::Zero) { exit 1 }
    $shells += $remC.Shell

    [void](Send-TestWindowClose -Window $remC.Hwnd)
    $dlg = Wait-Dialog $g.Pid $true
    Assert ($dlg -ne [IntPtr]::Zero) 'C: the confirmation appears'
    if ($dlg -ne [IntPtr]::Zero) {
        $cancel = Get-DialogButton $dlg 'Cancel'
        Assert ($null -ne $cancel) 'C: there is a Cancel button'
        if ($null -ne $cancel) {
            [void](Send-TestControlClick -Control ([IntPtr]$cancel.Hwnd))
            Assert ((Wait-Dialog $g.Pid $false 4000) -eq [IntPtr]::Zero) 'C: the dialog goes away'
            Assert (Test-TestWindowExists -Window $remC.Hwnd) 'C: the remote window survives Cancel'
            Assert (Test-PidAlive $remC.Shell) 'C: the remote shell survives Cancel'
        }
    }

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "== D: +close raises no dialog, returns, and ends the session =="

    # Same window section C left open - the programmatic path on a window that a
    # user close would have prompted for.
    $r = Invoke-OnTestDesktop -Exe $Exe -Arguments @('+close', '--target=remdiscC')
    Assert ($r.ExitCode -eq 0) "D: +close returns 0 (got $($r.ExitCode))"
    Assert (-not $r.TimedOut) 'D: +close returns rather than blocking on a modal'
    Assert ((Wait-Dialog $g.Pid $false 2000) -eq [IntPtr]::Zero) 'D: +close raised NO dialog'
    Assert (Wait-WindowGone $remC.Hwnd) 'D: +close closed the remote window'
    Start-Sleep -Seconds 3
    Assert (-not (Test-PidAlive $remC.Shell)) 'D: +close ENDED the remote session'

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "== E: confirm-close-surface = false closes with no prompt =="

    if ($g) { Stop-Process -Id $g.Pid -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 800 }
    $g = Start-Gui @('--session-persistence=false', '--confirm-close-surface=false')
    if (-not $g) { Write-Host 'SETUP FAIL: E GUI did not come up'; $script:fail++; exit 1 }

    $remE = Open-RemoteWindow $g.Pid 'remdiscE' $agent.Id $shells
    Assert ($null -ne $remE -and $remE.Hwnd -ne [IntPtr]::Zero) 'E: remote window opened'
    if ($null -eq $remE -or $remE.Hwnd -eq [IntPtr]::Zero) { exit 1 }
    $shells += $remE.Shell

    [void](Send-TestWindowClose -Window $remE.Hwnd)
    Assert ((Wait-Dialog $g.Pid $false 2500) -eq [IntPtr]::Zero) 'E: no dialog for a user who turned confirmations off'
    Assert (Wait-WindowGone $remE.Hwnd) 'E: the remote window closes straight away'

    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "== F: a LOCAL window is offered no Disconnect =="

    # `confirm-close-surface = always` is what forces the dialog here. The
    # obvious control - a BUSY local shell, which T41 says must confirm - is
    # unusable while T1398 is open: that path currently raises no dialog at all,
    # so it would report "no Disconnect button" over "no dialog" and prove
    # nothing about the offer. `always` is the other branch `Surface.shellIsIdle`
    # refuses to answer idle for, it is unconditional, and it gives this section
    # exactly what it needs: a local confirmation to look inside.
    if ($g) { Stop-Process -Id $g.Pid -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 800 }
    $g = Start-Gui @('--session-persistence=false', '--confirm-close-surface=always')
    if (-not $g) { Write-Host 'SETUP FAIL: F GUI did not come up'; $script:fail++; exit 1 }
    $surface = Get-TestChildWindow -Window $g.Top -Class 'GhozttyTerminal'
    Assert ($surface -ne [IntPtr]::Zero) 'F: the local window has a terminal surface'
    if ($surface -eq [IntPtr]::Zero) { exit 1 }

    # The window path (`Window.confirmCloseIfNeeded`), which is where sections
    # A-C got their three-button dialog.
    [void](Send-TestWindowClose -Window $g.Top)
    $dlg = Wait-Dialog $g.Pid $true
    Assert ($dlg -ne [IntPtr]::Zero) 'F: a LOCAL window still confirms (positive control)'
    if ($dlg -ne [IntPtr]::Zero) {
        $buttons = Get-DialogButtons $dlg
        Assert ($buttons.Count -eq 2) "F: the local confirmation has two buttons (got $($buttons.Count): $(($buttons | ForEach-Object { $_.Text }) -join ', '))"
        Assert ($null -eq (Get-DialogButton $dlg 'Disconnect')) 'F: a local WINDOW is offered NO Disconnect'
        Send-TestControlKey -Control $dlg -Key Escape | Out-Null
        Assert ((Wait-Dialog $g.Pid $false 4000) -eq [IntPtr]::Zero) 'F: Escape dismisses the local confirm'
        Assert (Test-TestWindowVisible -Window $g.Top) 'F: the local window survives the cancelled close'
    }

    # And the PANE path (`Surface.close`), which grew its own offer arm and so
    # needs its own scope check.
    Send-TestKeys -Window $g.Top -Target $surface -Modifiers ctrl -Key W | Out-Null
    $dlg = Wait-Dialog $g.Pid $true
    Assert ($dlg -ne [IntPtr]::Zero) 'F(pane): a LOCAL pane still confirms (positive control)'
    if ($dlg -ne [IntPtr]::Zero) {
        $buttons = Get-DialogButtons $dlg
        Assert ($buttons.Count -eq 2) "F(pane): the local confirmation has two buttons (got $($buttons.Count))"
        Assert ($null -eq (Get-DialogButton $dlg 'Disconnect')) 'F(pane): a local PANE is offered NO Disconnect'
        Send-TestControlKey -Control $dlg -Key Escape | Out-Null
        [void](Wait-Dialog $g.Pid $false 4000)
    }
} finally {
    Write-Host ""
    Write-Host "== cleanup =="
    if ($g) { Stop-Process -Id $g.Pid -Force -ErrorAction SilentlyContinue }
    if ($agent) { Stop-Process -Id $agent.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
    Stop-Everything
    Remove-TestDesktop | Out-Null
}

# A green run stamps the covered files (T783) so guard-due can answer "has this
# harness been run against the code as it now stands?". Red leaves the stamp
# alone - red stays due - and so does a -NegativeControl run, whose whole point
# is to score red.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard remote-disconnect -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ""
if ($script:fail -eq 0) { "ALL PASS ($script:pass assertions)"; exit 0 }
else { "$script:fail FAILURE(S) ($script:pass passed)"; exit 1 }
