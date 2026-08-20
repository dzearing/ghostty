# T297 acceptance: the Activity Monitor's DIALED (owned-connection) path.
#
# WHY THIS EXISTS. The panel reaches a remote machine two ways, and until this
# script only one of them was proven to WORK on the box:
#
#   reuse (BORROWED)  `activity-monitor-remote.ps1` drives a panel opened from a
#                     remote window's palette, which hands it the window's own
#                     connection. Covered end to end, ownership rule included.
#   dial (OWNED)      the chooser's Activity button. `chooser-menu.ps1` proves
#                     only that the button ATTEMPTS a dial and FAILS HONESTLY
#                     against a fake directory that is not an agent endpoint.
#                     Nothing exercised dial -> sample -> free.
#
# The dial is the riskier half, because it is the only path that OWNS what it
# opens: `close` frees a transport, `shutdown()`-before-join has to unblock a
# parked RPC, and a dial landing AFTER its panel closed has to be torn down by
# `ActivityMonitor.onDialed` instead of adopted under whatever is there now.
# Each of those is a leak or a use-after-free when it is wrong, and all of them
# were argued from code reading plus a unit test of `panelMatches`.
#
# THE FIXTURE. `lib\FakeRelay.ps1` is the piece `chooser-menu.ps1` could not
# have: a loopback relay that answers `/v1/client/devices` AND upgrades
# `/v1/client/connect?device=` to a WebSocket bridged to a real
# `ghoztty-agent --listen 127.0.0.1:<port>`. `relay_dial` takes an `http://`
# base as plaintext `ws://` for exactly this, so no TLS is involved. The device
# in the directory therefore IS a reachable machine, which is what turns
# chooser-menu's honest failure into a success case.
#
# WHAT IS ASSERTED
#   A  the Activity button DIALS (never borrows), the dial crosses the relay,
#      it connects, and the panel then samples the AGENT rather than this
#      process
#   B  closing that panel FREES the connection: the relay sees the client go
#      away and the app is left holding no socket to the machine
#   C  a panel closed WHILE its dial is in flight neither crashes nor leaks -
#      the late dial lands on the app's message window, is torn down instead of
#      adopted, and the relay sees that bridge close too
#
# THE ORACLE FOR A. A loopback agent enumerates the same box, so "the table
# populated" proves nothing: a panel that silently sampled THIS process would
# paint an identical-looking table under the machine's name. The distinguishing
# field is the snapshot's ROOT PID - the agent's own pid for a remote sample,
# the app's for a local one - logged by `ActivityMonitor.rebuild` as `root=`.
# `-NegativeControl` inverts it (asserting the panel sampled LOCALLY); that run
# MUST fail.
#
# THE ORACLE FOR B AND C is the app's ESTABLISHED sockets, counted from outside
# the process by `Get-NetTCPConnection`: a panel that only THOUGHT it freed its
# transport still holds one. That is deliberately not the app's account of
# itself, because "we freed it" is what a leak also says.
#
# The relay's log is the second oracle, and it answers only for C. A freed
# WsClient sends a plain TCP FIN and no WS close frame — deliberate, and the
# T81 panic is why (`ws_client.closeImpl`) — and `FakeRelay`'s pump only ever
# reads a bridge when `NetworkStream.DataAvailable` is true, which is
# `Socket.Available != 0` and therefore FALSE at a bare EOF. So the relay
# NOTICES a dial it had already pushed bytes through (C: the late bridge is
# torn down within a frame of coming up) and does NOT notice an idle one going
# away (B), exactly as its own header says it leaks idle pairs. Asserting a
# `BRIDGE down` for B would be asserting a property of the fake.
#
# T211/T217: runs on a BACKGROUND Win32 desktop and asserts at the end that it
# never took the user's foreground. T248/T158: the repo's agent and app are
# killed at setup and the app is launched with --session-persistence=false, so
# a restored manifest cannot hand this run a previous run's panes.
#
#   powershell -NoProfile -File test\win32\activity-monitor-dialed.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [int]$AgentPort = 47971,
    [int]$RelayPort = 47972,
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
$agentExe = Join-Path (Split-Path $Exe -Parent) 'ghoztty-agent.exe'

$env:GHOZTTY_PIPE_SUFFIX = '-t297'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\FakeRelay.ps1')
. (Join-Path $PSScriptRoot 'lib\ChooserControls.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

function Stop-RepoProcesses {
    foreach ($name in @('ghoztty', 'ghoztty-agent')) {
        Get-CimInstance Win32_Process -Filter "Name='$name.exe'" | ForEach-Object {
            if ($_.ExecutablePath -and $_.ExecutablePath.StartsWith((Join-Path $repo 'zig-out'), 'OrdinalIgnoreCase')) {
                try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}
            }
        }
    }
    Start-Sleep -Milliseconds 500
}

function Reset-AgentState {
    $dir = Join-Path $env:LOCALAPPDATA 'ghoztty\local-agent-debug'
    foreach ($f in @('sessions.json', 'port.json')) {
        Remove-Item (Join-Path $dir $f) -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path $dir 'rings') -Recurse -Force -ErrorAction SilentlyContinue
}

function Count-LogLines($path, $pattern) {
    if (-not (Test-Path $path)) { return 0 }
    return @(Select-String -Path $path -Pattern $pattern -ErrorAction SilentlyContinue).Count
}

function Wait-LogCount($path, $pattern, $want, $timeoutMs) {
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if ((Count-LogLines $path $pattern) -ge $want) { return $true }
        Start-Sleep -Milliseconds 200
        $waited += 200
    }
    return $false
}

function Count-RelayLines($path, $pattern) {
    return @(Get-FakeRelayLog $path | Select-String $pattern).Count
}

function Wait-RelayLines($path, $pattern, $want, $timeoutMs) {
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if ((Count-RelayLines $path $pattern) -ge $want) { return $true }
        Start-Sleep -Milliseconds 250
        $waited += 250
    }
    return $false
}

# The panel's most recent rebuild line. `Root` is the snapshot's own root pid -
# the field that tells a remote sample from a local one from outside.
function Get-PanelState($path) {
    if (-not (Test-Path $path)) { return $null }
    $pat = 'activity monitor: source=(\S+) total=(\d+) shown=(\d+) needle="([^"]*)" show_all=(\w+) sort=\w+/\w+ selected=\d+ root=(-?\d+)'
    $m = @(Select-String -Path $path -Pattern $pat) | Select-Object -Last 1
    if (-not $m) { return $null }
    $g = $m.Matches[0].Groups
    return [pscustomobject]@{
        Source = $g[1].Value
        Total  = [int]$g[2].Value
        Shown  = [int]$g[3].Value
        Root   = [int64]$g[6].Value
    }
}

function Wait-PanelState($path, [string]$SourceLike, [int]$TimeoutMs = 20000) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $s = Get-PanelState $path
        if ($null -ne $s -and $s.Source -like $SourceLike -and $s.Total -gt 0) { return $s }
        Start-Sleep -Milliseconds 300
    }
    return Get-PanelState $path
}

# ESTABLISHED sockets this app holds to the RELAY, counted from outside the app.
# The relay is what the app dials; the agent port is the relay's business.
function Get-RelayConnCount([int]$appPid, [int]$port) {
    try {
        return @(Get-NetTCPConnection -State Established -RemotePort $port `
                -OwningProcess $appPid -ErrorAction SilentlyContinue).Count
    } catch { return -1 }
}

function Wait-RelayConnCount([int]$appPid, [int]$port, [int]$want, [int]$timeoutMs) {
    $waited = 0
    $now = -1
    while ($waited -lt $timeoutMs) {
        $now = Get-RelayConnCount $appPid $port
        if ($now -eq $want) { return $now }
        Start-Sleep -Milliseconds 400
        $waited += 400
    }
    return $now
}

# Open the chooser, arrow onto the (single) relay device row, and hand back the
# chooser hwnd. The device row is the LAST row: [This PC, <device>].
function Open-ChooserOnDevice([IntPtr]$top, [IntPtr]$surface, [int]$appPid) {
    $chooser = [IntPtr]::Zero
    foreach ($try in 1..3) {
        if (Send-TestKeys -Window $top -Target $surface -Modifiers ctrl, shift -Key N) {
            $chooser = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyMachineChooser' -TimeoutMs 5000
        }
        if ($chooser -ne [IntPtr]::Zero) { break }
    }
    if ($chooser -eq [IntPtr]::Zero) { return $chooser }
    Start-Sleep -Milliseconds 400
    [void](Send-TestControlKey -Control $chooser -Key Down)
    Start-Sleep -Milliseconds 500
    return $chooser
}

$TOKEN = 'faketoken-t297'
$DEV = 'dev-dialed'
$DEVNAME = 'E2E-Dial'   # no spaces: the panel's `source=` log field is \S+
$devicesJson = '{"devices":[' +
'{"id":"' + $DEV + '","name":"' + $DEVNAME + '","hostname":"dial.local","online":true}]}'

$errlog = Join-Path $env:TEMP "ghoztty-t297-stderr-$PID.log"
$relaylog = Join-Path $env:TEMP "ghoztty-t297-relay-$PID.log"
$agentlog = Join-Path $env:TEMP "ghoztty-t297-agent-$PID.log"
$tmp = Join-Path $env:TEMP "ghoztty-t297-$PID"
$slowFile = Join-Path $tmp 'slow-connect'
New-Item -ItemType Directory -Force $tmp | Out-Null
Remove-Item $errlog, $relaylog -ErrorAction SilentlyContinue

Write-Host 'T297 Activity Monitor - the DIALED (owned-connection) path'
if ($NegativeControl) {
    Write-Host '  (negative control: asserting the panel sampled LOCALLY - this run MUST fail)'
}
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
Stop-RepoProcesses
Reset-AgentState
Start-TestForegroundWatch
New-TestDesktop -Interactive:$Interactive | Out-Null

$script:agent = $null
$script:relay = $null
$script:app = $null
try {
    # --- The "other machine": a real agent on a TCP port -------------------
    if (-not (Test-Path $agentExe)) {
        Write-TestAssertedNothing -Reason "no agent binary at $agentExe"
    }
    $env:GHOSTTY_AGENT_LOCK = Join-Path $tmp 'agent.lock'
    $script:agent = Start-Process -FilePath $agentExe `
        -ArgumentList '--listen', "127.0.0.1:$AgentPort", '--headless' -PassThru -WindowStyle Hidden `
        -RedirectStandardError $agentlog
    $null = $script:agent.Handle
    Start-Sleep -Seconds 2
    if ($script:agent.HasExited) {
        Write-TestAssertedNothing -Reason 'the remote agent died at launch'
    }
    $agentPid = $script:agent.Id
    Write-Host "  OK   remote agent pid=$agentPid on 127.0.0.1:$AgentPort"

    $script:relay = Start-FakeRelay -Port $RelayPort -AgentPort $AgentPort `
        -DevicesJson $devicesJson -LogPath $relaylog -SlowConnectFile $slowFile -SlowConnectMs 6000
    if (-not (Select-String -Path $relaylog -Pattern 'LISTEN' -Quiet)) {
        Write-TestAssertedNothing -Reason 'the fake relay never listened'
    }
    Write-Host "  OK   fake relay on 127.0.0.1:$RelayPort -> agent 127.0.0.1:$AgentPort"

    # --- The app, signed in via the env token, on the test desktop ---------
    $env:GHOSTTY_RELAY_BASE = "http://127.0.0.1:$RelayPort"
    $env:GHOSTTY_RELAY_TOKEN = $TOKEN
    $env:GHOSTTY_ACCOUNT_STORE = (Join-Path $tmp 'account.dat')
    $script:app = Start-OnTestDesktop -Exe $Exe `
        -Arguments @('--window-width=110', '--window-height=32', '--session-persistence=false') `
        -StdErr $errlog
    foreach ($k in 'GHOSTTY_RELAY_BASE', 'GHOSTTY_RELAY_TOKEN', 'GHOSTTY_ACCOUNT_STORE') {
        Remove-Item "env:$k" -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
    if ($script:app.Process -and $script:app.Process.HasExited) {
        Write-TestAssertedNothing -Reason 'the GUI died at launch'
    }
    $appPid = $script:app.Pid
    $top = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'no top window' }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'no pane' }

    # The number every "gave it back" assertion is measured against: what this
    # app holds to the relay before anything has dialed anything.
    $idleConns = Get-RelayConnCount $appPid $RelayPort
    Write-Host "  OK   app pid=$appPid, sockets to the relay before any dial: $idleConns"

    # =====================================================================
    Write-Host ''
    Write-Host '1. the Activity button dials the machine and samples IT'
    # =====================================================================
    $chooser = Open-ChooserOnDevice $top $surface $appPid
    Assert ($chooser -ne [IntPtr]::Zero) 'A ctrl+shift+n opens the chooser'
    if ($chooser -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'the chooser never opened; nothing about the dial was measured'
    }
    Assert ((Count-RelayLines $relaylog '/v1/client/devices') -ge 1) `
        'A the chooser listed the device directory from our relay'

    $ab = Get-ChooserActivityButton -Chooser $chooser
    Assert ($null -ne $ab -and $ab.Visible) 'A Activity is offered on the relay device row'
    if (-not ($ab -and $ab.Visible)) {
        Write-TestAssertedNothing -Reason 'no Activity button on the device row; the dial was never reachable'
    }

    $connectsBefore = Count-RelayLines $relaylog "CONNECT device=$DEV"
    [void](Invoke-ChooserClick -Chooser $chooser -Control $ab)
    $panel = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyActivityMonitor' -TimeoutMs 10000
    Assert ($panel -ne [IntPtr]::Zero) 'A Activity opens an Activity Monitor panel'
    if ($panel -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'no panel opened; the dialed path was never entered'
    }
    $ptitle = Get-TestWindowText -Window $panel
    Assert ($ptitle -like "*$DEVNAME*") "A the panel is titled for the selected machine (got '$ptitle')"

    Assert (Wait-LogCount $errlog "activity monitor: dialing source=$DEVNAME" 1 8000) `
        'A the panel DIALS its own connection'
    Assert ((Count-LogLines $errlog "activity monitor: reusing caller's connection") -eq 0) `
        'A and it borrowed nobody else''s (this is the OWNED path)'
    Assert (Wait-RelayLines $relaylog "CONNECT device=$DEV" ($connectsBefore + 1) 10000) `
        'A the dial really crossed the relay (counted on the far side)'
    Assert (Wait-LogCount $errlog "activity monitor: connected source=$DEVNAME" 1 15000) `
        'A the dial CONNECTED'
    Assert (Wait-RelayLines $relaylog "BRIDGE up device=$DEV" 1 8000) `
        'A the relay bridged that dial to the agent'

    $state = Wait-PanelState $errlog $DEVNAME
    if ($null -ne $state) {
        Write-Host "      state: source=$($state.Source) total=$($state.Total) shown=$($state.Shown) root=$($state.Root)"
    }
    Assert ($null -ne $state -and $state.Total -gt 0) 'A the panel populated a process table'
    $wantRoot = if ($NegativeControl) { $appPid } else { $agentPid }
    $rootLabel = if ($NegativeControl) { "this app ($appPid)" } else { "the AGENT ($agentPid)" }
    Assert ($null -ne $state -and $state.Root -eq $wantRoot) `
        "A the rows came from $rootLabel (root=$(if ($state) { $state.Root } else { 'none' }))"

    $liveConns = Get-RelayConnCount $appPid $RelayPort
    Write-Host "      sockets app -> 127.0.0.1:${RelayPort} while sampling: $liveConns"
    Assert ($liveConns -ge 1) 'A the panel is holding a connection open to the machine'

    # =====================================================================
    Write-Host ''
    Write-Host '2. closing the panel frees the connection it owns'
    # =====================================================================
    [void](Send-TestWindowClose -Window $panel)
    Assert (Wait-LogCount $errlog "activity monitor: closed source=$DEVNAME" 1 10000) `
        'B the panel closed'
    # The freed-transport oracle: counted from outside the app, so a panel that
    # only believes it let go still fails here.
    $afterClose = Wait-RelayConnCount $appPid $RelayPort $idleConns 12000
    Assert ($afterClose -eq $idleConns) `
        "B it FREED the connection it owned - no socket left to the machine (idle=$idleConns after=$afterClose)"
    Assert (-not ($script:app.Process -and $script:app.Process.HasExited)) 'B the app survived the close'

    # =====================================================================
    Write-Host ''
    Write-Host '3. a dial that lands after its panel closed is torn down, not adopted'
    # =====================================================================
    # The relay now answers every connect 6 s late, which is the "accepts and
    # stalls" the in-flight case needs. Deferred, never slept on, so live
    # bridges keep pumping.
    Set-Content -Path $slowFile -Value 'slow' -Encoding ASCII
    $lateBefore = Count-LogLines $errlog 'activity monitor: dial landed after its panel closed'
    $dialsBefore = Count-LogLines $errlog "activity monitor: dialing source=$DEVNAME"
    $upBefore = Count-RelayLines $relaylog "BRIDGE up device=$DEV"
    $downBeforeC = Count-RelayLines $relaylog "BRIDGE down device=$DEV"

    $chooser2 = Open-ChooserOnDevice $top $surface $appPid
    Assert ($chooser2 -ne [IntPtr]::Zero) 'C the chooser opens a second time'
    if ($chooser2 -eq [IntPtr]::Zero) {
        Write-Host '  SKIP C: the chooser did not re-open, so no in-flight dial could be staged'
        $script:skipped++
    } else {
        $ab2 = Get-ChooserActivityButton -Chooser $chooser2
        if (-not ($ab2 -and $ab2.Visible)) {
            Write-Host '  SKIP C: no Activity button after re-open, so no in-flight dial could be staged'
            $script:skipped++
        } else {
            [void](Invoke-ChooserClick -Chooser $chooser2 -Control $ab2)
            $panel2 = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyActivityMonitor' -TimeoutMs 10000
            Assert ($panel2 -ne [IntPtr]::Zero) 'C a second panel opens'
            $dialing = Wait-LogCount $errlog "activity monitor: dialing source=$DEVNAME" ($dialsBefore + 1) 8000
            Assert $dialing 'C and it starts a dial the slow relay has not answered yet'
            # Close it while that dial is still parked in the relay's defer list.
            Assert ((Count-LogLines $errlog "activity monitor: connected source=$DEVNAME") -eq 1) `
                'C the dial really is still in flight when we close (not connected yet)'
            if ($panel2 -ne [IntPtr]::Zero) { [void](Send-TestWindowClose -Window $panel2) }
            Assert (Wait-LogCount $errlog "activity monitor: closed source=$DEVNAME" 2 10000) `
                'C the panel closes while its dial is outstanding'

            Assert (Wait-LogCount $errlog 'activity monitor: dial landed after its panel closed' ($lateBefore + 1) 20000) `
                'C the late dial lands on the app and reports the panel is gone'
            Assert ((Count-LogLines $errlog "activity monitor: connected source=$DEVNAME") -eq 1) `
                'C it was NOT adopted by anything (no second connect)'
            # The relay CAN answer for this one: bytes went through that bridge
            # before it was dropped, so its pump reads the EOF (see the header).
            $lateUp = Wait-RelayLines $relaylog "BRIDGE up device=$DEV" ($upBefore + 1) 25000
            $lateDown = Wait-RelayLines $relaylog "BRIDGE down device=$DEV" ($downBeforeC + 1) 25000
            Assert ($lateUp -and $lateDown) `
                "C the relay bridged the late dial and then saw it torn down (up=$(Count-RelayLines $relaylog "BRIDGE up device=$DEV") down=$(Count-RelayLines $relaylog "BRIDGE down device=$DEV"))"
            $afterLate = Wait-RelayConnCount $appPid $RelayPort $idleConns 15000
            Assert ($afterLate -eq $idleConns) `
                "C the app is back to holding no socket to the machine (idle=$idleConns after=$afterLate)"
            Assert (-not ($script:app.Process -and $script:app.Process.HasExited)) `
                'C the app survived the late dial'
            Assert (Test-TestWindowResponsive -Window $top) 'C the app''s message loop is not wedged'
        }
    }
    Remove-Item $slowFile -ErrorAction SilentlyContinue

    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'the run never took the user''s foreground'
} finally {
    Stop-FakeRelay $script:relay
    if ($null -ne $script:agent) {
        Stop-Process -Id $script:agent.Id -Force -ErrorAction SilentlyContinue
    }
    Stop-RepoProcesses
    Remove-TestDesktop
    Stop-TestForegroundWatch | Out-Null
    Remove-Item 'env:GHOSTTY_AGENT_LOCK' -ErrorAction SilentlyContinue
    Remove-Item 'env:GHOZTTY_PIPE_SUFFIX' -ErrorAction SilentlyContinue
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "  app stderr: $errlog"
Write-Host "  relay log:  $relaylog"

# --- stamp (T783) ----------------------------------------------------------
# Only a CLEAN green run records the covered files: a red run must stay due, and
# so must one that skipped a section, since a stamp over unmeasured code is the
# green hat the T219 audit refuses.
if ($script:fail -eq 0 -and $script:skipped -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard activity-monitor-dialed -Repo $repo 2>&1 |
        ForEach-Object { Write-Host "  $($_.ToString())" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped `
    -Label 'ACTIVITY MONITOR DIALED ACCEPTANCE'
