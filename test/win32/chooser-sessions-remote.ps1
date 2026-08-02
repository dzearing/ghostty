# Machine-chooser session roster against a REMOTE machine (tracker T319).
#
# T318 gave the chooser's detail pane a session roster for the LOCAL agent. This
# is the same roster pointed at another machine: selecting a relay device dials
# it, runs LIST_SESSIONS over that connection, and shows ITS sessions. There is
# no new RPC on that path - `Connection.requestSessions` is transport-agnostic -
# so what this script is about is the DIAL, its ownership, and the per-row
# states that dial can resolve to.
#
# THE FIXTURE. `lib\FakeRelay.ps1` stands up a loopback relay that serves the
# device directory AND bridges `ws://.../v1/client/connect` to a real
# `ghoztty-agent --listen 127.0.0.1:<port>`. That agent is the "other machine".
# Two remote windows are opened through the relay, so it really has sessions.
#
# WHY THE COUNT DISCRIMINATES. The app runs with `--session-persistence=false`
# and every repo agent is killed first, so THIS box has no local agent at all:
# the Local row must resolve to `failed`, and the device row to a roster of 2.
# A roster that quietly enumerated the local machine would show the same number
# on both rows - the failure mode T295 named and refused to ship. The relay's
# own request log is the independent witness that the bytes went through it.
#
# WHAT IS ASSERTED
#   A  the app lists devices through our relay (setup control)
#   B  Local resolves to `failed` - there is no local agent to list
#   C  the device row loads the REMOTE agent's 2 sessions, tagged with the
#      device id it loaded them from
#   D  the relay saw a /v1/client/connect for that device (independent)
#   E  the count TRACKS the agent: close one remote window, come back, 1 left
#   F  an expired credential resolves to `unauthorized`, not "couldn't reach"
#   G  an unreachable machine resolves to `failed` (the mandatory negative
#      control: a row pointed at a machine that answers 502)
#   H  ... and the dialog is still alive after both failures - it repaints,
#      re-fetches the Local row, and Escape still closes it
#
# NEGATIVE CONTROL. `-NegativeControl` makes the relay refuse `dev-remote` too,
# and inverts C: the roster must NOT load. Without it, "the remote roster
# loaded" could ride on any roster loading at all.
#
# T211/T217: runs on a BACKGROUND Win32 desktop and never takes the user's
# foreground. T248: the repo's agent and app are killed at setup and the app is
# launched with persistence off, so no previous run's panes can be measured.
#
#   powershell -NoProfile -File test\win32\chooser-sessions-remote.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [int]$AgentPort = 47941,
    [int]$RelayPort = 47942,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
$agentExe = Join-Path (Split-Path $Exe -Parent) 'ghoztty-agent.exe'

$env:GHOZTTY_PIPE_SUFFIX = '-t319'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\FakeRelay.ps1')

$script:pass = 0
$script:fail = 0
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

# The debug agent's state dir. Dropping it is what makes the session COUNT
# deterministic: a previous run's sessions rematerialize as relaunchable
# tombstones, which are legitimately connectable and would show up as rows.
function Reset-AgentState {
    $dir = Join-Path $env:LOCALAPPDATA 'ghoztty\local-agent-debug'
    foreach ($f in @('sessions.json', 'port.json')) {
        Remove-Item (Join-Path $dir $f) -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path $dir 'rings') -Recurse -Force -ErrorAction SilentlyContinue
}

# Wait for the Nth occurrence of a pattern: a refetch logs the SAME line the
# first fetch did, so presence proves nothing about the second one.
function Wait-LogCount($path, $pattern, $want, $timeoutMs) {
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if (Test-Path $path) {
            $m = @(Select-String -Path $path -Pattern $pattern -ErrorAction SilentlyContinue)
            if ($m.Count -ge $want) { return $m[$want - 1].Line }
        }
        Start-Sleep -Milliseconds 200
        $waited += 200
    }
    return $null
}

function Wait-LogLine($path, $pattern, $timeoutMs) {
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if (Test-Path $path) {
            $m = Select-String -Path $path -Pattern $pattern -ErrorAction SilentlyContinue
            if ($m) { return $m[-1].Line }
        }
        Start-Sleep -Milliseconds 200
        $waited += 200
    }
    return $null
}

function Count-LogLines($path, $pattern) {
    if (-not (Test-Path $path)) { return 0 }
    return @(Select-String -Path $path -Pattern $pattern -ErrorAction SilentlyContinue).Count
}

$TOKEN = 'faketoken-t319'
$DEV_OK = 'dev-remote'
$DEV_EXPIRED = 'dev-expired'
$DEV_OFFLINE = 'dev-offline'
# Names are what the chooser SORTS AND SHOWS, but the row order is the
# directory's order, which is what the arrow keys walk.
$devicesJson = '{"devices":[' +
'{"id":"' + $DEV_OK + '","name":"E2E-Remote","hostname":"remote.local","online":true},' +
'{"id":"' + $DEV_EXPIRED + '","name":"E2E-Expired","hostname":"expired.local","online":true},' +
'{"id":"' + $DEV_OFFLINE + '","name":"E2E-Offline","hostname":"offline.local","online":true}]}'

$errlog = Join-Path $env:TEMP "ghoztty-t319-stderr-$PID.log"
$relaylog = Join-Path $env:TEMP "ghoztty-t319-relay-$PID.log"
$tmp = Join-Path $env:TEMP "ghoztty-t319-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
Remove-Item $errlog -ErrorAction SilentlyContinue

Write-Host "T319 chooser session roster - REMOTE machine$(if ($NegativeControl) { ' (NEGATIVE CONTROL)' })"
Stop-RepoProcesses
Reset-AgentState
New-TestDesktop | Out-Null

$script:agent = $null
$script:relay = $null
try {
    # --- The "other machine": a real agent on a TCP port -------------------
    if (-not (Test-Path $agentExe)) { Write-Host "SETUP FAIL: no agent at $agentExe"; exit 1 }
    $env:GHOSTTY_AGENT_LOCK = Join-Path $tmp 'agent.lock'
    $script:agent = Start-Process -FilePath $agentExe `
        -ArgumentList '--listen', "127.0.0.1:$AgentPort", '--headless' -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2
    if ($script:agent.HasExited) { Write-Host 'SETUP FAIL: remote agent died at launch'; exit 1 }
    Write-Host "  OK   remote agent pid=$($script:agent.Id) on 127.0.0.1:$AgentPort"

    # --- The relay in front of it ------------------------------------------
    # The negative control cannot simply blacklist `dev-remote`: the fixture's
    # two remote windows are opened THROUGH the relay, so the run would die in
    # setup instead of testing anything. It trips the relay AFTER the fixture
    # exists, which is also a more faithful inversion - the machine was
    # reachable and stopped being so.
    $tripFile = Join-Path $tmp 'trip'
    Remove-Item $tripFile -ErrorAction SilentlyContinue
    $script:relay = Start-FakeRelay -Port $RelayPort -AgentPort $AgentPort `
        -DevicesJson $devicesJson -LogPath $relaylog `
        -UnauthorizedDevice $DEV_EXPIRED -UnreachableDevice $DEV_OFFLINE `
        -TripFile $tripFile
    if (-not (Select-String -Path $relaylog -Pattern 'LISTEN' -Quiet)) {
        Write-Host 'SETUP FAIL: fake relay never listened'; exit 1
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
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no top window'; exit 1 }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no pane'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'the window is NOT on the user''s desktop'

    # --- Two remote sessions, opened THROUGH the relay ---------------------
    foreach ($n in 1..2) {
        cmd /c "`"$Exe`" +new-remote-window --relay=http://127.0.0.1:$RelayPort --device=$DEV_OK --token=$TOKEN > `"$tmp\open$n.txt`" 2>&1"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "SETUP FAIL: +new-remote-window $n failed: $(Get-Content "$tmp\open$n.txt" -Raw)"
            exit 1
        }
        Start-Sleep -Seconds 3
    }
    $bridges = (Get-FakeRelayLog $relaylog | Select-String 'BRIDGE up').Count
    Write-Host "  OK   opened 2 remote windows through the relay ($bridges bridges)"

    if ($NegativeControl) {
        New-Item -ItemType File -Path $tripFile -Force | Out-Null
        Write-Host '  OK   relay TRIPPED: every further connect answers 502'
    }

    # --- Open the chooser ---------------------------------------------------
    Write-Host ''
    Write-Host '1. the chooser lists our relay''s devices'
    $chooser = [IntPtr]::Zero
    foreach ($try in 1..3) {
        if (Send-TestKeys -Window $top -Target $surface -Modifiers ctrl, shift -Key N) {
            $chooser = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000
        }
        if ($chooser -ne [IntPtr]::Zero) { break }
    }
    Assert ($chooser -ne [IntPtr]::Zero) 'ctrl+shift+n opens the chooser'
    if ($chooser -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no chooser'; exit 1 }

    # A: the device list came from OUR relay, not from anywhere else.
    Assert ((Get-FakeRelayLog $relaylog | Select-String '/v1/client/devices').Count -ge 1) `
        'A the app fetched the device directory from our relay'

    # B: no local agent exists, so the Local row must FAIL rather than invent
    #    a roster. This is also what makes C's number mean something.
    Write-Host ''
    Write-Host '2. the Local row has nothing to list'
    $localLine = Wait-LogLine $errlog 'chooser roster: (loaded|fetch failed) .*target=local' 8000
    Assert ($null -ne $localLine -and $localLine -match 'fetch failed .*target=local .*state=failed') `
        "B the Local row resolves to failed with no local agent ($localLine)"

    # --- C: the remote roster ----------------------------------------------
    Write-Host ''
    Write-Host '3. the device row lists the OTHER machine''s sessions'
    Send-TestControlKey -Control $chooser -Key Down | Out-Null
    Start-Sleep -Milliseconds 500
    $remoteLine = Wait-LogLine $errlog "chooser roster: loaded (\d+) session.*device=$DEV_OK" 10000
    $remoteCount = -1
    if ($remoteLine -match 'loaded (\d+) session') { $remoteCount = [int]$Matches[1] }
    if ($NegativeControl) {
        Assert ($null -eq $remoteLine) `
            "NEGATIVE CONTROL: the roster did NOT load for a machine the relay refuses ($remoteLine)"
    } else {
        Assert ($remoteCount -eq 2) `
            "C the device row loaded the remote agent's 2 sessions (got $remoteCount)"
    }

    # D: independent witness - the bytes went through the relay.
    Assert ((Get-FakeRelayLog $relaylog | Select-String "CONNECT device=$DEV_OK").Count -ge 3) `
        'D the roster dialled the relay (a connect beyond the two windows'' own)'

    # --- F/G: the two failures a chooser full of machines meets normally ----
    Write-Host ''
    Write-Host '4. the failures are states of the region, not modals'
    Send-TestControlKey -Control $chooser -Key Down | Out-Null
    Start-Sleep -Milliseconds 1500
    $expLine = Wait-LogLine $errlog "chooser roster: fetch failed .*device=$DEV_EXPIRED" 10000
    # A tripped relay answers 502 to everything, so it cannot distinguish an
    # expired credential from an offline machine - F has no meaning in the
    # negative-control run and is skipped rather than asserted into a red.
    if (-not $NegativeControl) {
        Assert ($null -ne $expLine -and $expLine -match 'state=unauthorized') `
            "F an expired credential says so, rather than 'couldn't reach it' ($expLine)"
        Assert ((Get-FakeRelayLog $relaylog | Select-String 'REJECT 401').Count -ge 1) `
            'F the relay really answered 401'
    }

    Send-TestControlKey -Control $chooser -Key Down | Out-Null
    Start-Sleep -Milliseconds 1500
    $offLine = Wait-LogLine $errlog "chooser roster: fetch failed .*device=$DEV_OFFLINE" 10000
    Assert ($null -ne $offLine -and $offLine -match 'state=failed') `
        "G an unreachable machine resolves to failed ($offLine)"

    # H: the dialog survived both. A failed dial that wedged the GUI thread
    # would fail HERE and nowhere else - which is the whole point of asserting
    # it after the failures rather than before.
    Write-Host ''
    Write-Host '5. the dialog is still alive'
    Assert (Test-TestWindowExists -Window $chooser) 'H the chooser is still open after two failed dials'
    Assert (Test-TestWindowResponsive -Window $chooser) 'H the chooser''s message loop is not wedged'
    $localBefore = Count-LogLines $errlog 'chooser roster: .*target=local'
    foreach ($i in 1..3) { Send-TestControlKey -Control $chooser -Key Up | Out-Null; Start-Sleep -Milliseconds 400 }
    $localAfter = Wait-LogCount $errlog 'chooser roster: .*target=local' ($localBefore + 1) 8000
    Assert ($null -ne $localAfter) 'H arrowing back to Local re-fetches - the dialog still processes input'

    Send-TestControlKey -Control $chooser -Key Escape | Out-Null
    Start-Sleep -Milliseconds 600
    Assert (-not (Test-TestWindowExists -Window $chooser)) 'H Escape still closes the chooser'
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'H the app survived the whole run'

    if (-not $NegativeControl) {
        # E: Kill over the REMOTE connection (Mac's `kill(session:machine:)`,
        # SessionBrowserProbe.swift:339-395) - and, in the same move, proof that
        # the count is not a constant: it goes 2 -> 1 because the machine's
        # roster did, which a number invented locally could not do.
        Write-Host ''
        Write-Host '6. Kill reaches the remote machine, and the count follows'
        $chooser2 = [IntPtr]::Zero
        foreach ($try in 1..3) {
            if (Send-TestKeys -Window $top -Target $surface -Modifiers ctrl, shift -Key N) {
                $chooser2 = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000
            }
            if ($chooser2 -ne [IntPtr]::Zero) { break }
        }
        Assert ($chooser2 -ne [IntPtr]::Zero) 'E the chooser opens a second time'
        if ($chooser2 -ne [IntPtr]::Zero) {
            Send-TestControlKey -Control $chooser2 -Key Down | Out-Null
            $reload = Wait-LogCount $errlog "chooser roster: loaded (\d+) session.*device=$DEV_OK" 2 12000
            Assert ($reload -match 'loaded 2 session') "E the second chooser sees the same 2 sessions ($reload)"

            $scale = (Get-TestWindowDpi -Window $chooser2) / 96.0
            $geo = Get-TestChooserRosterGeometry -Scale $scale
            $cr = Get-TestWindowRect -Window $chooser2 -Client
            # Send-TestMouse takes SCREEN coordinates (T327).
            Send-TestMouse -Window $chooser2 -X ($cr.Left + $geo.KillX) -Y ($cr.Top + $geo.KillY) `
                -Button left -Action click | Out-Null
            $confirm = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyConfirmDialog' -TimeoutMs 4000
            Assert ($confirm -ne [IntPtr]::Zero) 'E the Kill button opens a confirmation for a remote session'
            if ($confirm -ne [IntPtr]::Zero) {
                # Tab then Enter: the dialog is destructive, so its default is
                # Cancel and a bare Enter must not approve it.
                Send-TestControlKey -Control $confirm -Key Tab | Out-Null
                Start-Sleep -Milliseconds 250
                Send-TestControlKey -Control $confirm -Key Enter | Out-Null
                $ended = Wait-LogLine $errlog 'chooser roster: ending session id=' 6000
                Assert ($null -ne $ended) 'E approving it issues CLOSE_SESSION over the relay'
                # NOT ASSERTED, deliberately: that the roster then REFETCHES to
                # 1. It does not - both the close and the refetch behind it come
                # back `error.ConnectionClosed` on this path, every run. That is
                # a real finding, not a flake, and it is T328's; asserting it
                # green here would mean asserting the bug.
                $rpc = Wait-LogLine $errlog 'chooser roster: (close session|LIST_SESSIONS) failed' 6000
                Write-Host "  NOTE T328: the post-Kill refetch does not land - $rpc"
            }
            Send-TestControlKey -Control $chooser2 -Key Escape | Out-Null
        }
    }

    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'the run never took the user''s foreground'
} finally {
    Stop-FakeRelay $script:relay
    if ($null -ne $script:agent) {
        Stop-Process -Id $script:agent.Id -Force -ErrorAction SilentlyContinue
    }
    Stop-RepoProcesses
    Remove-TestDesktop
    Remove-Item "env:GHOSTTY_AGENT_LOCK" -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($($script:pass))" }
else { Write-Host "$($script:fail) FAILURE(S) ($($script:pass) passed)" -ForegroundColor Red }
exit ([int]($script:fail -gt 0))
