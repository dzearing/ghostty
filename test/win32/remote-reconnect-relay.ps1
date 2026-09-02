# T1276 acceptance: the reconnect ladder on the RELAY path - the path a user's
# second machine actually uses.
#
# WHAT WENT WRONG. T366 built the ladder: a cross-machine window whose agent
# dies re-dials on a 1/2/4/8/15s schedule, comes back on its own when the
# machine does, and only ever reports a TERMINAL verdict for something retrying
# cannot fix. On the relay path none of that ran. About three seconds after the
# far agent died, `+list --json` reported
# `{"state":"disconnected","self_healable":false}` - the terminal verdict - and
# the relay never saw a second dial. The cause was not the network and not the
# 401 rule everyone suspected: `RemoteReconnect.startAttempt` resolved the relay
# bearer from the account/env store ONLY, and a window opened by
# `+new-remote-window --token=...` records no credential there, so the first
# attempt died at "needs a relay credential (signed out)" before a socket was
# opened. `Window.RemoteMachine.relay` now carries the bearer the window was
# dialed with, and `remote_reconnect.chooseRelayToken` prefers the renewable
# store token with that one as the fallback.
#
# The arms, in the order they are scored:
#
#   A  CONTROL. A relay window comes up through a loopback fake relay onto a
#      real `ghoztty-agent --listen`, and `+list --json` says `connected`.
#      Scored first and deliberately: every arm below reads that same field, and
#      a build that could not open a relay window at all would leave a window
#      that is "not connected" too.
#   B  LADDER. The relay goes away under the window - the machine is fine, the
#      path to it is not, which is the case the ladder exists for. The window
#      must CLIMB (`reconnecting`, rising attempt) and must really DIAL: the app
#      log has to name more than one failed re-dial. The dial count is the
#      load-bearing half, because the state field alone cannot tell a ladder
#      that is dialing from one that merely says it is - and "says it is, then
#      goes terminal without dialing" is precisely the defect.
#   C  RECOVERY. The relay comes back inside the fast ladder's ~30s budget, with
#      the far agent (and its session) untouched. The window must return to
#      `connected` ON ITS OWN, with no click, and hold the SAME session id - a
#      window rebuilt with a fresh shell is byte-identical to a recovered one
#      for anything that only reads the state.
#   D  A REJECTED BEARER IS STILL TERMINAL. The relay is told to answer 401 and
#      the link is dropped again. One attempt, then
#      `disconnected`/`self_healable:false`, and exactly ONE re-dial - and that
#      one logged as `WebSocketUnauthorized`: retrying cannot sign anyone in,
#      and the fix for the offline case must not have weakened that.
#
# Why the drop is a RELAY outage rather than the agent being killed: an agent
# that is killed and restarted comes back owning nothing, and the automatic
# ladder answers a vanished session by going terminal ON PURPOSE (T611 - a grid
# the user arranged is not replaced with empty shells unless they asked). That
# path is `remote-reconnect-fresh.ps1`'s. Here the session must survive, so the
# thing that goes away is the path to it.
#
# TEETH-CHECK: re-run with `-TeethCheck`, which never brings the relay back -
# arm C ("it comes back on its own") must go red, which is what says C is
# measuring a recovery rather than a window that never left `connected`.
# Measured 2026-09-02: C red, and D red behind it, because a window that never
# recovered has nothing left to drop - a cascade, not three findings.
#
# The credential defect's OWN negative control cannot be built harness-side: it
# lives in what the window recorded at open time. It is the pre-fix binary, and
# it was measured rather than reasoned about - at cdf47065c this same walk gave
# `{"state":"disconnected","self_healable":false}` three seconds after the agent
# died, with ONE line in the relay's request log (the original dial) and
# `remote reconnect: 'relwin' needs a relay credential (signed out)` in the app
# log. Arm B's dial count and its signed-out check are both aimed at exactly
# that reading.
#
#   powershell -NoProfile -File test\win32\remote-reconnect-relay.ps1
param(
    [string]$ExePath,
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [int]$RelayPort = 47961,
    [int]$AgentPort = 47962,
    [switch]$TeethCheck
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $Exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-relrecon$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\FakeRelay.ps1')
. (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
Register-RepoBuildTeardown -Exe $Exe | Out-Null

$script:pass = 0
$script:fail = 0
function Check([bool]$cond, [string]$msg) {
    if ($cond) { $script:pass++; Write-Host "  PASS  $msg" }
    else { $script:fail++; Write-Host "  FAIL  $msg" }
}

$tmp = Join-Path $env:TEMP "ghoztty-t1276-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$errlog = Join-Path $tmp 'app.err'
$relaylog = Join-Path $tmp 'relay.log'
$authTrip = Join-Path $tmp 'unauth'
$DEV = 'dev-t1276'
$TOKEN = "faketok-t1276-$PID"
$devicesJson = '{"devices":[{"id":"' + $DEV + '","name":"E2E-Reconnect","hostname":"remote.local","online":true}]}'

# The window's `connection` object from `+list --json`, or $null.
function Get-Conn([string]$target) {
    $raw = (& $Exe +list --json 2>$null | ForEach-Object { $_.ToString() }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $j = $null
    try { $j = $raw | ConvertFrom-Json } catch { return $null }
    if (-not $j.data.windows) { return $null }
    $w = $j.data.windows | Where-Object { $_.target -eq $target } | Select-Object -First 1
    if (-not $w) { return $null }
    return $w.connection
}

# The session id of the window's first pane, or $null.
function Get-SessionId([string]$target) {
    $raw = (& $Exe +list --json 2>$null | ForEach-Object { $_.ToString() }) -join "`n"
    $j = $null
    try { $j = $raw | ConvertFrom-Json } catch { return $null }
    $w = $j.data.windows | Where-Object { $_.target -eq $target } | Select-Object -First 1
    if (-not $w) { return $null }
    return $w.tabs[0].splits.terminal.session_id
}

# Poll the connection object until $test says yes. Returns the last one seen,
# so a failing arm can print what it actually got rather than "not it".
function Wait-Conn([string]$target, [scriptblock]$test, [int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $last = $null
    while ((Get-Date) -lt $deadline) {
        $last = Get-Conn $target
        if ($null -ne $last -and (& $test $last)) { return $last }
        Start-Sleep -Milliseconds 700
    }
    return $last
}

function Show-Conn($c) {
    if ($null -eq $c) { return '(no connection object)' }
    return ($c | ConvertTo-Json -Compress)
}

# Failed re-dials the ladder has logged. The app names every one
# (`remote reconnect: relay dial device=... failed err=...`), so this counts
# attempts that really opened a socket even while the relay is down and its own
# request log cannot see them.
function Count-Dials() {
    return @(Select-String -Path $errlog -Pattern 'remote reconnect: relay dial device=' -ErrorAction SilentlyContinue).Count
}

function Start-FarAgent() {
    $saved = $env:GHOZTTY_AGENT_INSTANCE
    $env:GHOZTTY_AGENT_INSTANCE = "t1276relrecon$PID"
    $p = Start-Process -FilePath $AgentExe -PassThru -WindowStyle Hidden `
        -ArgumentList '--listen', "127.0.0.1:$AgentPort", '--headless' `
        -RedirectStandardOutput (Join-Path $tmp "agent-$([guid]::NewGuid().ToString('N').Substring(0,6)).out") `
        -RedirectStandardError (Join-Path $tmp "agent-$([guid]::NewGuid().ToString('N').Substring(0,6)).err")
    $null = $p.Handle   # before any HasExited read (lib\ExitCodeAudit.ps1)
    if ($null -eq $saved) { Remove-Item env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue }
    else { $env:GHOZTTY_AGENT_INSTANCE = $saved }
    return $p
}

Write-Host 'T1276 remote reconnect - the RELAY path'
$script:agent = $null
$script:relay = $null
$script:app = $null
try {
    # --- A: the fixture, and the control ------------------------------------
    Write-Host ''
    Write-Host 'A. a relay window over a loopback relay onto a real agent'
    $script:agent = Start-FarAgent
    Start-Sleep -Seconds 3
    if ($script:agent.HasExited) {
        Write-Host "  the far agent exited $($script:agent.ExitCode) at startup; nothing below could be measured"
        $script:fail++
        throw 'fixture agent died'
    }
    $script:relay = Start-FakeRelay -Port $RelayPort -AgentPort $AgentPort `
        -DevicesJson $devicesJson -LogPath $relaylog -TripUnauthorizedFile $authTrip
    Start-Sleep -Seconds 1
    Check ((Test-Path $relaylog) -and (Select-String -Path $relaylog -Pattern 'LISTEN' -Quiet)) `
        "the fake relay fronts that agent as device $DEV"

    New-TestDesktop | Out-Null
    # No account store and no GHOSTTY_RELAY_TOKEN: the window's ONLY credential
    # is the one it is dialed with, which is the state the defect lived in.
    $env:GHOSTTY_ACCOUNT_STORE = (Join-Path $tmp 'account.dat')
    Remove-Item env:GHOSTTY_RELAY_TOKEN -ErrorAction SilentlyContinue
    $script:app = Start-OnTestDesktop -Exe $Exe -Arguments @('--window-width=100', '--window-height=30') -StdErr $errlog
    Start-Sleep -Seconds 4
    Remove-Item env:GHOSTTY_ACCOUNT_STORE -ErrorAction SilentlyContinue

    $openArgs = @("--relay=http://127.0.0.1:$RelayPort", "--device=$DEV", "--token=$TOKEN", '--name=relwin')
    $open = Invoke-OnTestDesktop -Exe $Exe -Arguments (@('+new-remote-window') + $openArgs) -TimeoutSec 45
    Check ($open.ExitCode -eq 0 -and -not $open.TimedOut) "+new-remote-window opened the window (exit $($open.ExitCode))"
    Start-Sleep -Seconds 2
    $conn = Wait-Conn 'relwin' { param($c) $c.state -eq 'connected' } 15
    Check ($conn.state -eq 'connected') "A the window is connected: $(Show-Conn $conn)"
    $sid0 = Get-SessionId 'relwin'
    Check (-not [string]::IsNullOrWhiteSpace($sid0)) "A its pane holds a remote session ($sid0)"
    if ($conn.state -ne 'connected') {
        Write-Host '  the fixture window never connected; B/C/D would measure nothing'
        throw 'fixture window not connected'
    }

    # --- B: the ladder climbs ----------------------------------------------
    Write-Host ''
    Write-Host 'B. the path to the machine goes away: the ladder must climb, and dial'
    $before = Count-Dials
    Stop-FakeRelay $script:relay      # the live bridge dies with its listener
    $script:relay = $null
    $conn = Wait-Conn 'relwin' { param($c) $c.state -eq 'reconnecting' -and $c.attempt -ge 3 } 25
    Check ($conn.state -eq 'reconnecting' -and $conn.attempt -ge 2) `
        "B the window climbs the ladder: $(Show-Conn $conn)"
    $dials = (Count-Dials) - $before
    Check ($dials -ge 2) "B and it really re-DIALS ($dials attempts since the drop)"
    $signedOut = @(Select-String -Path $errlog -Pattern 'needs a relay credential' -ErrorAction SilentlyContinue).Count
    Check ($signedOut -eq 0) 'B without ever reading its own bearer as signed out'

    # --- C: it comes back on its own ---------------------------------------
    Write-Host ''
    Write-Host 'C. the path comes back inside the ladder: so does the window'
    if (-not $TeethCheck) {
        $script:relay = Start-FakeRelay -Port $RelayPort -AgentPort $AgentPort `
            -DevicesJson $devicesJson -LogPath $relaylog -TripUnauthorizedFile $authTrip
        Start-Sleep -Seconds 1
    }
    $conn = Wait-Conn 'relwin' { param($c) $c.state -eq 'connected' } 60
    Check ($conn.state -eq 'connected') "C the window reconnected with no click: $(Show-Conn $conn)"
    $sid1 = Get-SessionId 'relwin'
    Check ($null -ne $sid1 -and $sid1 -eq $sid0) "C and re-ATTACHed the SAME session (was $sid0, now $sid1)"

    # --- D: a rejected bearer is still terminal, in one attempt -------------
    Write-Host ''
    Write-Host 'D. the relay rejects the bearer: terminal, in one attempt'
    New-Item -ItemType File -Force $authTrip | Out-Null
    $before = Count-Dials
    Stop-FakeRelay $script:relay
    $script:relay = Start-FakeRelay -Port $RelayPort -AgentPort $AgentPort `
        -DevicesJson $devicesJson -LogPath $relaylog -TripUnauthorizedFile $authTrip
    $conn = Wait-Conn 'relwin' { param($c) $c.state -eq 'disconnected' } 30
    Check ($conn.state -eq 'disconnected' -and $conn.self_healable -eq $false) `
        "D the window goes terminal: $(Show-Conn $conn)"
    Start-Sleep -Seconds 6   # a ladder still running would dial again inside this
    $dials = (Count-Dials) - $before
    Check ($dials -eq 1) "D after exactly one rejected dial ($dials since the drop)"
    $unauth = @(Select-String -Path $errlog -Pattern 'relay dial .*WebSocketUnauthorized' -ErrorAction SilentlyContinue).Count
    Check ($unauth -ge 1) 'D and the verdict came from a 401, not from a missing credential'
} catch {
    Write-Host "  harness error: $($_.Exception.Message)"
    if ($script:fail -eq 0) { $script:fail++ }
} finally {
    & $Exe +close --target=relwin 2>$null | Out-Null
    if ($script:app -and $script:app.Pid) {
        Stop-Process -Id $script:app.Pid -Force -ErrorAction SilentlyContinue
    }
    Stop-FakeRelay $script:relay
    if ($script:agent) { Stop-Process -Id $script:agent.Id -Force -ErrorAction SilentlyContinue }
    Remove-TestDesktop | Out-Null
}

Write-Host ''
Write-Host "  logs: $tmp"
# A green run stamps the covered files (T783) so guard-due can answer "has this
# harness been run against the code as it now stands?". Red leaves the stamp
# alone - red stays due - and a teeth-check is red by construction.
if ($script:fail -eq 0 -and -not $TeethCheck) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard remote-reconnect-relay -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}
if ($script:fail -eq 0) { "ALL PASS ($script:pass checks)"; exit 0 }
"$script:fail FAILURE(S) ($script:pass passed)"
exit 1
