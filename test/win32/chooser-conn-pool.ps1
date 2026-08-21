# One warm connection per remote machine, not one per roster fetch (T461).
#
# WHAT CHANGED. The chooser's detail pane used to dial the relay, run
# LIST_SESSIONS, and FREE the connection on every single roster fetch of a remote
# machine - so N refetches of one machine cost N WebSocket upgrades and N relay
# authentications, and there was nowhere to hang anything that has to keep
# listening. `App.machine_pool` now owns ONE connection per endpoint, the chooser
# holds a lease on the machine it is showing, and every fetch BORROWS that
# connection.
#
# THE ORACLE IS THE RELAY'S REQUEST LOG, not the app's own account of itself.
# `lib\FakeRelay.ps1` logs a line per `/v1/client/connect`, so the number of
# dials is counted on the far side of the wire by something that has no idea what
# the pool is. The app log supplies the other half of the pair - how many roster
# LOADS those dials served - because "one dial" is only good news if the fetches
# really happened. A run where the refetches silently did not fire would pass a
# dial count of 1 and prove nothing; C asserts both numbers.
#
# THE REFETCH DRIVER. Pressing Down while the LAST row is selected re-runs
# `refreshDetail` on the SAME machine (`clampSelection` clamps to the row it is
# already on), which is a `refresh_in_place` roster fetch. So the directory here
# lists exactly ONE device: the rows are [This PC, dev-remote], and every Down
# after the first is another fetch of dev-remote with no selection change.
#
# WHAT IS ASSERTED
#   A  setup control: the app lists our device, and one remote window is open
#      through the relay so the machine really has a session to list
#   B  selecting the device row loads its roster over a pooled connection
#   C  five more fetches of that machine cost ZERO further dials (and really
#      were five more fetches)
#   D  closing the chooser releases the last lease and drops the connection -
#      a browse must not leave a socket open to every machine clicked through
#   E  the control that makes C mean something: a SECOND chooser dials again,
#      and its roster loads. If the pool had simply stopped dialing, C would
#      still pass and E could not.
#   F  arrowing AWAY from the machine and back also re-dials (same policy as D,
#      measured while one chooser stays open)
#
# T211/T217: runs on a BACKGROUND Win32 desktop and never takes the user's
# foreground. T248: the repo's agent and app are killed at setup and the app is
# launched with persistence off.
#
#   powershell -NoProfile -File test\win32\chooser-conn-pool.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [int]$AgentPort = 47951,
    [int]$RelayPort = 47952
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
$agentExe = Join-Path (Split-Path $Exe -Parent) 'ghoztty-agent.exe'

$env:GHOZTTY_PIPE_SUFFIX = '-t461'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\FakeRelay.ps1')
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

function Count-RelayConnects($path, $device) {
    return @(Get-FakeRelayLog $path | Select-String "CONNECT device=$device").Count
}

# Wait until the relay's connect count STOPS moving, so a delta is measured
# against a settled number rather than against a dial still in flight.
function Wait-RelaySettled($path, $device, $quietMs = 1200) {
    $last = -1
    for ($i = 0; $i -lt 20; $i++) {
        $now = Count-RelayConnects $path $device
        if ($now -eq $last) { return $now }
        $last = $now
        Start-Sleep -Milliseconds $quietMs
    }
    return $last
}

$TOKEN = 'faketoken-t461'
$DEV = 'dev-remote'
# ONE device on purpose: it makes dev-remote the LAST row, which is what turns a
# repeated Down into a repeated fetch of the same machine (see the header).
$devicesJson = '{"devices":[' +
'{"id":"' + $DEV + '","name":"E2E-Remote","hostname":"remote.local","online":true}]}'

$errlog = Join-Path $env:TEMP "ghoztty-t461-stderr-$PID.log"
$relaylog = Join-Path $env:TEMP "ghoztty-t461-relay-$PID.log"
$agentlog = Join-Path $env:TEMP "ghoztty-t461-agent-$PID.log"
$tmp = Join-Path $env:TEMP "ghoztty-t461-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
Remove-Item $errlog, $relaylog -ErrorAction SilentlyContinue

Write-Host 'T461 machine connection pool - one dial per machine, not per fetch'
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
Stop-RepoProcesses
Reset-AgentState
New-TestDesktop | Out-Null

$script:agent = $null
$script:relay = $null
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
    Write-Host "  OK   remote agent pid=$($script:agent.Id) on 127.0.0.1:$AgentPort"

    $script:relay = Start-FakeRelay -Port $RelayPort -AgentPort $AgentPort `
        -DevicesJson $devicesJson -LogPath $relaylog
    if (-not (Select-String -Path $relaylog -Pattern 'LISTEN' -Quiet)) {
        Write-TestAssertedNothing -Reason 'the fake relay never listened'
    }
    Write-Host "  OK   fake relay on 127.0.0.1:$RelayPort"

    # --- The app, signed in via the env token, on the test desktop ---------
    $env:GHOSTTY_RELAY_BASE = "http://127.0.0.1:$RelayPort"
    $env:GHOSTTY_RELAY_TOKEN = $TOKEN
    $env:GHOSTTY_ACCOUNT_STORE = (Join-Path $tmp 'account.dat')
    $app = Start-OnTestDesktop -Exe $Exe `
        -Arguments @('--window-width=100', '--window-height=30', '--session-persistence=false') `
        -StdErr $errlog
    foreach ($k in 'GHOSTTY_RELAY_BASE', 'GHOSTTY_RELAY_TOKEN', 'GHOSTTY_ACCOUNT_STORE') {
        Remove-Item "env:$k" -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) {
        Write-TestAssertedNothing -Reason 'the GUI died at launch'
    }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'no top window' }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { Write-TestAssertedNothing -Reason 'no pane' }

    # One remote window through the relay, so the machine has a session to list.
    cmd /c "`"$Exe`" +new-remote-window --relay=http://127.0.0.1:$RelayPort --device=$DEV --token=$TOKEN > `"$tmp\open.txt`" 2>&1"
    Start-Sleep -Seconds 3
    Assert ((Count-RelayConnects $relaylog $DEV) -ge 1) `
        'A a remote window opened through our relay (setup control)'

    # --- Open the chooser and select the machine ---------------------------
    Write-Host ''
    Write-Host '1. the device row loads its roster over a pooled connection'
    $chooser = [IntPtr]::Zero
    foreach ($try in 1..3) {
        if (Send-TestKeys -Window $top -Target $surface -Modifiers ctrl, shift -Key N) {
            $chooser = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000
        }
        if ($chooser -ne [IntPtr]::Zero) { break }
    }
    Assert ($chooser -ne [IntPtr]::Zero) 'ctrl+shift+n opens the chooser'
    if ($chooser -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'the chooser never opened; nothing about the pool was measured'
    }
    # The row the rest of this run drives is OURS: the chooser fetched the
    # directory from our relay when it opened.
    Assert ((Get-FakeRelayLog $relaylog | Select-String '/v1/client/devices').Count -ge 1) `
        'A the chooser listed the device directory from our relay'

    $before = Wait-RelaySettled $relaylog $DEV
    Send-TestControlKey -Control $chooser -Key Down | Out-Null
    $loaded = Wait-LogCount $errlog "chooser roster: loaded \d+ session.*device=$DEV" 1 15000
    Assert $loaded 'B selecting the device row loads the remote roster'
    Assert ((Count-LogLines $errlog "machine pool: warm connection ready relay:.*\|$DEV") -eq 1) `
        'B the pool dialed it exactly once'

    # --- C: the whole point ------------------------------------------------
    Write-Host ''
    Write-Host '2. five more fetches of the same machine cost no further dials'
    $afterFirst = Wait-RelaySettled $relaylog $DEV
    Assert (($afterFirst - $before) -eq 1) `
        "B the roster's own dial is ONE connect (before=$before after=$afterFirst)"

    $loadsBefore = Count-LogLines $errlog "chooser roster: loaded \d+ session.*device=$DEV"
    foreach ($i in 1..5) {
        # Down at the LAST row clamps to itself: same machine, fresh fetch.
        Send-TestControlKey -Control $chooser -Key Down | Out-Null
        Start-Sleep -Milliseconds 700
    }
    $wantLoads = $loadsBefore + 5
    $gotLoads = Wait-LogCount $errlog "chooser roster: loaded \d+ session.*device=$DEV" $wantLoads 20000
    $loadsAfter = Count-LogLines $errlog "chooser roster: loaded \d+ session.*device=$DEV"
    # The control for C: the refetches really happened. Without this, "one dial"
    # would also be the verdict for a chooser that fetched nothing at all.
    Assert $gotLoads "C the five refetches really ran ($loadsBefore -> $loadsAfter loads)"
    $afterRefetch = Wait-RelaySettled $relaylog $DEV
    Assert (($afterRefetch - $afterFirst) -eq 0) `
        "C and they dialed the relay ZERO more times (still $afterRefetch connects)"
    Assert ((Count-LogLines $errlog "machine pool: warm connection ready relay:.*\|$DEV") -eq 1) `
        'C the pool still reports exactly one warm connection for it'

    # --- F: leaving the machine gives the socket back ----------------------
    Write-Host ''
    Write-Host '3. arrowing away and back re-dials (a browse holds one machine, not all of them)'
    Send-TestControlKey -Control $chooser -Key Up | Out-Null
    Start-Sleep -Milliseconds 800
    Assert ((Count-LogLines $errlog 'machine pool: last lease released') -ge 1) `
        'F moving off the machine released its lease'
    Send-TestControlKey -Control $chooser -Key Down | Out-Null
    $backLoads = Wait-LogCount $errlog "chooser roster: loaded \d+ session.*device=$DEV" ($loadsAfter + 1) 15000
    $afterBack = Wait-RelaySettled $relaylog $DEV
    Assert ($backLoads -and ($afterBack - $afterRefetch) -eq 1) `
        "F coming back dials once more and loads again (delta $($afterBack - $afterRefetch))"

    # --- D: the chooser closing takes the connection with it ---------------
    Write-Host ''
    Write-Host '4. closing the chooser drops the connection'
    $releasesBefore = Count-LogLines $errlog 'machine pool: last lease released'
    Send-TestControlKey -Control $chooser -Key Escape | Out-Null
    Start-Sleep -Milliseconds 800
    Assert (-not (Test-TestWindowExists -Window $chooser)) 'D Escape closed the chooser'
    Assert ((Count-LogLines $errlog 'machine pool: last lease released') -ge ($releasesBefore + 1)) `
        'D closing it released the last lease and dropped the connection'

    # --- E: the control that makes C a result rather than a silence --------
    Write-Host ''
    Write-Host '5. a second chooser dials again - the pool did not just stop dialing'
    $chooser2 = [IntPtr]::Zero
    foreach ($try in 1..3) {
        if (Send-TestKeys -Window $top -Target $surface -Modifiers ctrl, shift -Key N) {
            $chooser2 = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000
        }
        if ($chooser2 -ne [IntPtr]::Zero) { break }
    }
    Assert ($chooser2 -ne [IntPtr]::Zero) 'E the chooser opens a second time'
    if ($chooser2 -ne [IntPtr]::Zero) {
        $loads2Before = Count-LogLines $errlog "chooser roster: loaded \d+ session.*device=$DEV"
        Send-TestControlKey -Control $chooser2 -Key Down | Out-Null
        $reload = Wait-LogCount $errlog "chooser roster: loaded \d+ session.*device=$DEV" ($loads2Before + 1) 15000
        $afterSecond = Wait-RelaySettled $relaylog $DEV
        Assert $reload 'E the second chooser loads the roster again'
        Assert (($afterSecond - $afterBack) -eq 1) `
            "E and it really re-dialed (delta $($afterSecond - $afterBack))"
        Assert (Test-TestWindowResponsive -Window $chooser2) 'E the chooser''s message loop is not wedged'
        Send-TestControlKey -Control $chooser2 -Key Escape | Out-Null
        Start-Sleep -Milliseconds 500
    }

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'the app survived the whole run'
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'the run never took the user''s foreground'
    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    Stop-FakeRelay $script:relay
    if ($null -ne $script:agent) {
        Stop-Process -Id $script:agent.Id -Force -ErrorAction SilentlyContinue
    }
    Stop-RepoProcesses
    Remove-TestDesktop
    Remove-Item 'env:GHOSTTY_AGENT_LOCK' -ErrorAction SilentlyContinue
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped
