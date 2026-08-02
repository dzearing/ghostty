# Machine-chooser RESTORE ALL against a REMOTE machine (tracker T336).
#
# T335 rebuilds THIS machine's whole window/tab/split topology from the blobs its
# own agent holds. This is the same rebuild pointed at another machine over the
# relay - the half that closes T146 - and it is a separate task because of one
# structural difference with no Mac analog: Mac hands every rebuilt window ONE
# connection (SessionLayoutRestore.swift:659-675), while win32 windows each OWN
# their transport (`Window.deinit` tears it down). Sharing one dial here would
# mean the first window the user closes takes the others' agent with it, so the
# rule is one dial per window - and this script is where that is visible rather
# than asserted in a comment.
#
# THE FIXTURE, and why it is not T319's. A cross-machine Restore All needs a
# machine whose agent holds LAYOUT BLOBS, and the only thing that pushes a blob
# is an APP pushing to ITS OWN local agent (T334). A bare
# `ghoztty-agent --listen` - T319's "other machine" - has no app, so it holds no
# layouts, and a correct implementation against it returns zero. The only
# machine on this box that an app has lived on is this one, and its agent listens
# on a NAMED PIPE. So:
#
#   app A (persistence on)  ->  local agent  ->  layouts.json          [fixture]
#   kill app A, delete port.json                                       [orphan]
#   lib\PipeBridge.ps1      ->  that pipe, exposed on a TCP port
#   lib\FakeRelay.ps1       ->  ws://.../connect bridged to that port
#   app B (persistence OFF) ->  sees it ONLY as relay device dev-remote
#
# Deleting `port.json` is what makes the discrimination real: app B and the CLI
# both find the local agent through that file, so with it gone the Local row can
# only resolve to `failed` - and every session app B can see, it saw through the
# relay. The PipeBridge does not need the file (it knows the pipe name), so the
# agent itself is untouched and keeps its children alive.
#
# WHAT IS ASSERTED
#   A  the fixture: the agent holds a 3-pane window's layout blob (file evidence)
#   B  with port.json gone the Local row fails, and offers no Restore All - so
#      nothing that follows can be the local path in disguise
#   C  the device row loads the machine's sessions and Restore All is SHOWN.
#      This is the T336 regression: the pre-T336 rule was `row == .local`, so
#      this assertion fails against the old build with the button HIDDEN
#   D  an EXPIRED bearer (401 injected after the roster loaded) leaves the
#      chooser open with a sign-in message and builds NO window - the failure
#      mode that must not half-build a topology
#   E  the rebuild: one window, its recorded 3-pane split shape, over the relay
#   F  per-window transport ownership: the restore spends >= 2 dials (the pull's
#      own, plus one per window), counted in the relay's request log
#   G  independent oracle - the agent, asked directly over its pipe, reports all
#      three original sessions ATTACHED
#   H  pressing it again rebuilds nothing: the machine-scoped double-attach
#      guard holds across the relay too
#
# The keyboard is the trigger under test, not a shortcut around it: Tab walks to
# the button and the script asserts FOCUS LANDED ON IT before pressing Return
# (the T240 lesson - "nothing happened" is equally consistent with the keys never
# arriving).
#
# T248: every repo ghoztty/ghoztty-agent is killed at setup and the agent state
# is dropped, so the fixture is built fresh rather than measuring the last run.
# T267: the script sets its own window size instead of inheriting whatever the
# last GUI script left in window_placement-debug.
#
#   powershell -NoProfile -File test\win32\chooser-restore-all-remote.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [int]$BridgePort = 47951,
    [int]$RelayPort = 47952
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }

# Isolate the IPC endpoint (inherited through CreateProcessW).
$env:GHOZTTY_PIPE_SUFFIX = '-t336'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\FakeRelay.ps1')
. (Join-Path $PSScriptRoot 'lib\PipeBridge.ps1')

$script:pass = 0
$script:fail = 0

function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

function Stop-RepoProcesses([string[]]$Names) {
    foreach ($name in $Names) {
        Get-CimInstance Win32_Process -Filter "Name='$name.exe'" | ForEach-Object {
            if ($_.ExecutablePath -and $_.ExecutablePath.StartsWith((Join-Path $repo 'zig-out'), 'OrdinalIgnoreCase')) {
                try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}
            }
        }
    }
    Start-Sleep -Milliseconds 700
}

$agentDir = Join-Path $env:LOCALAPPDATA 'ghoztty\local-agent-debug'
$portFile = Join-Path $agentDir 'port.json'
$portSaved = Join-Path $env:TEMP "ghoztty-t336-port-$PID.json"

function Reset-AgentState {
    foreach ($f in @('sessions.json', 'port.json', 'layouts.json')) {
        Remove-Item (Join-Path $agentDir $f) -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path $agentDir 'rings') -Recurse -Force -ErrorAction SilentlyContinue
}

function Remove-LayoutManifest {
    Remove-Item (Join-Path $env:LOCALAPPDATA 'ghoztty\session-layout-debug.json') -ErrorAction SilentlyContinue
}

# `ghoztty +verb > file` writes zero bytes from PowerShell (T245) - capture
# through a pipe instead.
function Get-Sessions {
    $out = (& $Exe +sessions --json 2>$null | Out-String)
    if (-not $out -or $out.Trim().Length -eq 0) { return @() }
    try { $j = $out | ConvertFrom-Json } catch { return @() }
    if ($null -eq $j) { return @() }
    return @($j)
}

function Wait-AliveCount($target, $timeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $rows = @()
    while ((Get-Date) -lt $deadline) {
        $rows = @(Get-Sessions | Where-Object { $_.alive })
        if ($rows.Count -ge $target) { return $rows }
        Start-Sleep -Milliseconds 500
    }
    return $rows
}

function Get-ListTree {
    $out = (& $Exe +list --json 2>$null | Out-String)
    if (-not $out -or $out.Trim().Length -eq 0) { return $null }
    try { $j = $out | ConvertFrom-Json } catch { return $null }
    if ($null -ne $j -and $null -ne $j.data) { return $j.data }
    return $j
}

function Count-Leaves($node) {
    if ($null -eq $node) { return 0 }
    if ($node.type -eq 'leaf') { return 1 }
    if ($node.type -eq 'split') { return (Count-Leaves $node.left) + (Count-Leaves $node.right) }
    return 0
}

# Every window in +list --json as {name, panes}. PS 5.1 unrolls one-element
# arrays, so every walk over these wraps in @(...) (the T334 lesson).
function Get-WindowShapes {
    $tree = Get-ListTree
    if ($null -eq $tree) { return @() }
    $out = @()
    foreach ($w in @($tree.windows)) {
        $panes = 0
        foreach ($t in @($w.tabs)) { $panes += (Count-Leaves $t.splits) }
        # `target` is the registered ipc name in +list --json (`name` is the
        # PANE-level field); reading the wrong one silently matches nothing.
        $out += [pscustomobject]@{ Name = $w.target; Panes = $panes }
    }
    return @($out)
}

function Layouts-Store {
    $path = Join-Path $agentDir 'layouts.json'
    if (-not (Test-Path $path)) { return @() }
    try { $doc = (Get-Content $path -Raw) | ConvertFrom-Json } catch { return @() }
    if ($null -eq $doc -or $null -eq $doc.layouts) { return @() }
    return @($doc.layouts)
}

# Poll until the named window's blob claims $n session ids. A record can exist
# before its panes have published their ids (the OPEN reply is async and
# syncSessionLayout re-arms a retry), so waiting for EXISTENCE would race a
# correct implementation (the T334 lesson).
function Wait-BlobIds($key, $n, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $rec = $null
    while ((Get-Date) -lt $deadline) {
        $rec = @(Layouts-Store | Where-Object { $_.key -eq $key }) | Select-Object -First 1
        if ($null -ne $rec -and @($rec.session_ids).Count -ge $n) { return $rec }
        Start-Sleep -Milliseconds 500
    }
    return $rec
}

function Launch-Gui($errlog, [string[]]$extra) {
    $args = @('--window-width=100', '--window-height=30') + $extra
    $app = Start-OnTestDesktop -Exe $Exe -Arguments $args -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { return $null }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { return $null }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { return $null }
    return @{ App = $app; Pid = $app.Pid; Top = $top; Surface = $surface }
}

function Open-Chooser($g) {
    foreach ($try in 1..3) {
        if (Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl, shift -Key N) {
            $c = Wait-TestWindow -ProcessId $g.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000
            if ($c -ne [IntPtr]::Zero) { return $c }
        }
    }
    return [IntPtr]::Zero
}

# The Restore All button, found by CAPTION and including hidden windows - the
# hidden state is a result this test needs to be able to read.
function Get-RestoreAllButton($chooser) {
    return Find-TestWindowEx -Parent $chooser -Class 'Button' -Title 'Restore All'
}

function Wait-LogLine($path, $pattern, $timeoutMs) {
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if (Test-Path $path) {
            $m = Select-String -Path $path -Pattern $pattern -ErrorAction SilentlyContinue
            if ($m) { return $m[-1].Line }
        }
        Start-Sleep -Milliseconds 250
        $waited += 250
    }
    return $null
}

function Count-LogLines($path, $pattern) {
    if (-not (Test-Path $path)) { return 0 }
    return @(Select-String -Path $path -Pattern $pattern -ErrorAction SilentlyContinue).Count
}

function Count-RelayConnects($log, $device) {
    if (-not (Test-Path $log)) { return 0 }
    return @(Select-String -Path $log -Pattern "CONNECT device=$device" -ErrorAction SilentlyContinue).Count
}

# Tab from the filter onto Restore All. Each Tab is re-aimed at whatever now
# holds focus, and that is not a nicety: `Send-TestKeys` SetFocus()es its
# -Target before posting, so six Tabs all aimed at the filter walk the SAME
# first step six times and focus never leaves the list.
function Focus-RestoreAll($chooser, $filter, $btn) {
    $cur = $filter
    for ($i = 0; $i -lt 6; $i++) {
        Send-TestKeys -Window $chooser -Target $cur -Key Tab | Out-Null
        Start-Sleep -Milliseconds 300
        $f = Get-TestFocusedWindow -Window $chooser
        if ([int64]$f -eq 0) { return $false }
        $cur = [IntPtr]$f
        if ([int64]$f -eq [int64]$btn) { return $true }
    }
    return $false
}

$TOKEN = 'faketoken-t336'
$DEV = 'dev-remote'
$devicesJson = '{"devices":[{"id":"' + $DEV + '","name":"E2E-Remote","hostname":"remote.local","online":true}]}'

$errlogA = Join-Path $env:TEMP "ghoztty-t336-stderrA-$PID.log"
$errlogB = Join-Path $env:TEMP "ghoztty-t336-stderrB-$PID.log"
$relaylog = Join-Path $env:TEMP "ghoztty-t336-relay-$PID.log"
$bridgelog = Join-Path $env:TEMP "ghoztty-t336-bridge-$PID.log"
$tmp = Join-Path $env:TEMP "ghoztty-t336-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
Remove-Item $errlogA, $errlogB -ErrorAction SilentlyContinue

Write-Host 'T336 chooser Restore All - REMOTE machine over the relay'
Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
Reset-AgentState
Remove-LayoutManifest
New-TestDesktop | Out-Null

$script:relay = $null
$script:bridge = $null
try {
    # --- 1. the fixture: a 3-pane window whose layout the agent holds -------
    Write-Host ''
    Write-Host '1. the machine: an app, its agent, and a 3-pane named window'
    $g = Launch-Gui $errlogA @('--session-persistence=true')
    if (-not $g) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }

    & $Exe +new-window --target=t336-multi 2>$null | Out-Null
    Start-Sleep -Seconds 2
    & $Exe +split --target=t336-multi --direction=right 2>$null | Out-Null
    Start-Sleep -Seconds 2
    & $Exe +split --target=t336-multi --direction=down 2>$null | Out-Null
    $alive = @(Wait-AliveCount 4)
    Assert ($alive.Count -ge 4) "the machine has four live sessions ($($alive.Count))"

    $blob = Wait-BlobIds 't336-multi' 3
    Assert ($null -ne $blob -and @($blob.session_ids).Count -eq 3) `
        "A the agent holds the window's layout with its three session ids ($(@($blob.session_ids).Count))"
    $multiIds = if ($null -ne $blob) { @($blob.session_ids) } else { @() }

    # --- 2. take the machine away, and hand it back only over the relay ----
    Write-Host ''
    Write-Host '2. the app is gone and port.json with it: the agent is only reachable through the relay'
    Stop-RepoProcesses @('ghoztty')
    Remove-LayoutManifest
    Copy-Item $portFile $portSaved -Force -ErrorAction SilentlyContinue
    Remove-Item $portFile -ErrorAction SilentlyContinue
    Assert (-not (Test-Path $portFile)) 'the local agent is no longer discoverable locally'

    $pipeName = Get-LocalAgentPipeName
    $script:bridge = Start-PipeBridge -Port $BridgePort -PipeName $pipeName -LogPath $bridgelog
    Assert ((Test-Path $bridgelog) -and (Select-String -Path $bridgelog -Pattern 'LISTEN' -Quiet)) `
        "the pipe bridge fronts $pipeName on 127.0.0.1:$BridgePort"

    $tripAuth = Join-Path $tmp 'trip401'
    Remove-Item $tripAuth -ErrorAction SilentlyContinue
    $script:relay = Start-FakeRelay -Port $RelayPort -AgentPort $BridgePort `
        -DevicesJson $devicesJson -LogPath $relaylog -TripUnauthorizedFile $tripAuth
    Assert ((Test-Path $relaylog) -and (Select-String -Path $relaylog -Pattern 'LISTEN' -Quiet)) `
        "the fake relay serves that machine as device $DEV"

    # --- 3. the app under test: persistence OFF, so it never spawns an agent -
    Write-Host ''
    Write-Host '3. a fresh app that has no local agent at all'
    $env:GHOSTTY_RELAY_BASE = "http://127.0.0.1:$RelayPort"
    $env:GHOSTTY_RELAY_TOKEN = $TOKEN
    $env:GHOSTTY_ACCOUNT_STORE = (Join-Path $tmp 'account.dat')
    $g = Launch-Gui $errlogB @('--session-persistence=false')
    foreach ($k in 'GHOSTTY_RELAY_BASE', 'GHOSTTY_RELAY_TOKEN', 'GHOSTTY_ACCOUNT_STORE') {
        Remove-Item "env:$k" -ErrorAction SilentlyContinue
    }
    if (-not $g) { Write-Host 'SETUP FAIL: GUI died on relaunch'; exit 1 }
    $shapesBefore = @(Get-WindowShapes)
    Assert ($shapesBefore.Count -eq 1) `
        "it restored nothing on its own ($($shapesBefore.Count) window)"

    $chooser = Open-Chooser $g
    Assert ($chooser -ne [IntPtr]::Zero) 'ctrl+shift+n opens the chooser'
    if ($chooser -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no chooser'; exit 1 }
    $filter = Get-TestChildWindow -Window $chooser -Class 'Edit'
    Assert ($filter -ne [IntPtr]::Zero) 'the chooser has its filter field'

    # B: with no local agent the Local row must FAIL. Everything after this is
    # therefore something the app learned through the relay.
    $localLine = Wait-LogLine $errlogB 'chooser roster: (loaded|fetch failed) .*target=local' 10000
    Assert ($null -ne $localLine -and $localLine -match 'fetch failed .*target=local') `
        "B the Local row has nothing to list ($localLine)"
    $btn = Get-RestoreAllButton $chooser
    Assert ($btn -ne [IntPtr]::Zero) 'the Restore All control exists on the chooser'
    Assert (-not (Test-TestWindowVisible -Window $btn)) `
        'and it is HIDDEN on a machine with no live sessions'

    # --- 4. the device row: the roster, and the button T336 unlocks ---------
    Write-Host ''
    Write-Host '4. the remote machine lists its sessions and offers Restore All'
    Send-TestControlKey -Control $chooser -Key Down | Out-Null
    Start-Sleep -Milliseconds 500
    $remoteLine = Wait-LogLine $errlogB "chooser roster: loaded (\d+) session.*device=$DEV" 15000
    $remoteCount = -1
    if ($remoteLine -match 'loaded (\d+) session') { $remoteCount = [int]$Matches[1] }
    Assert ($remoteCount -ge 4) "the device row loaded the machine's sessions ($remoteCount)"
    Assert ((Count-RelayConnects $relaylog $DEV) -ge 1) `
        'the roster really went through the relay (independent witness)'
    Start-Sleep -Milliseconds 800
    $btn = Get-RestoreAllButton $chooser
    Assert ($btn -ne [IntPtr]::Zero -and (Test-TestWindowVisible -Window $btn)) `
        'C the same probe now finds Restore All SHOWN on a REMOTE row'

    # --- 5. an expired bearer must not half-build a topology ----------------
    Write-Host ''
    Write-Host '5. the credential expires between the roster and the click'
    New-Item -ItemType File -Path $tripAuth -Force | Out-Null
    Assert (Focus-RestoreAll $chooser $filter $btn) 'Tab walks focus onto the Restore All button'
    # Aimed at the BUTTON: Send-TestKeys focuses its target first, so a Return
    # aimed at the filter would press the default action instead.
    Send-TestKeys -Window $chooser -Target $btn -Key Return | Out-Null
    $denied = Wait-LogLine $errlogB 'restore all: (relay dial failed|failed err=error.Unauthorized)' 10000
    Assert ($null -ne $denied) "D a 401 is reported, not swallowed ($denied)"
    Start-Sleep -Seconds 2
    Assert (Test-TestWindowExists -Window $chooser) `
        'the chooser stayed OPEN to say so rather than dismissing onto nothing'
    Assert ((Count-LogLines $errlogB 'restore all: rebuilt \d+ window') -eq 0) `
        'and NO window was built on a dial that never succeeded'
    Remove-Item $tripAuth -ErrorAction SilentlyContinue

    # --- 6. the rebuild -----------------------------------------------------
    Write-Host ''
    Write-Host '6. Restore All rebuilds the remote machine''s topology here'
    $connectsBefore = Count-RelayConnects $relaylog $DEV
    $btn = Get-RestoreAllButton $chooser
    Assert (Focus-RestoreAll $chooser $filter $btn) 'Tab reaches the button again (the positive control)'
    Send-TestKeys -Window $chooser -Target $btn -Key Return | Out-Null

    $rebuilt = Wait-LogLine $errlogB 'restore all: rebuilt (\d+) window' 20000
    Assert ($null -ne $rebuilt) "E Return on the button rebuilds a window ($rebuilt)"
    $rebuiltN = 0
    if ($rebuilt -match 'rebuilt (\d+) window') { $rebuiltN = [int]$Matches[1] }
    Start-Sleep -Seconds 4
    Assert (-not (Test-TestWindowExists -Window $chooser)) 'the chooser dismissed itself onto the rebuild'

    # ALL of that machine's windows, not just the interesting one: app A left a
    # startup window behind as well as `t336-multi`, and "Restore All" means
    # both. (T335's local script sees only one because the relaunched app there
    # runs with persistence ON and overwrites the startup window's blob key -
    # T338. This app has persistence OFF and pushes nothing, so the machine's
    # own two windows are exactly what the agent still holds.)
    $shapesAfter = @(Get-WindowShapes)
    Assert ($rebuiltN -ge 2) "the machine's whole topology came back, not one window of it ($rebuiltN)"
    Assert ($shapesAfter.Count -eq ($shapesBefore.Count + $rebuiltN)) `
        "every rebuilt window is on screen ($($shapesBefore.Count) -> $($shapesAfter.Count), rebuilt $rebuiltN)"
    $restored = @($shapesAfter | Where-Object { $_.Name -eq 't336-multi' }) | Select-Object -First 1
    Assert ($null -ne $restored) 'the rebuilt window kept its ipc name'
    Assert ($null -ne $restored -and $restored.Panes -eq 3) `
        "and its recorded split topology - three panes ($(if ($restored) { $restored.Panes } else { 0 }))"

    # F: per-window transport ownership. The pull dials once for itself and each
    # rebuilt window dials its own, so the restore spends 1 + N connects. Fewer
    # would mean windows are sharing a connection - which `Window.deinit` then
    # frees out from under the others the first time one is closed.
    $connectsAfter = Count-RelayConnects $relaylog $DEV
    Assert (($connectsAfter - $connectsBefore) -ge ($rebuiltN + 1)) `
        "F the restore spent its own dial plus one per window ($($connectsAfter - $connectsBefore) connects for $rebuiltN windows)"

    # G: the independent oracle. port.json comes back only so the CLI can find
    # the agent; the reading itself never goes through the app.
    Copy-Item $portSaved $portFile -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    $attached = @(Get-Sessions | Where-Object { $multiIds -contains $_.id -and $_.attached }).Count
    Assert ($attached -eq 3) `
        "G the agent reports all three original sessions ATTACHED ($attached of 3)"

    # --- 7. the double-attach guard, across the relay -----------------------
    Write-Host ''
    Write-Host '7. pressing it again rebuilds nothing (those panes are already here)'
    $rebuiltBefore = Count-LogLines $errlogB 'restore all: rebuilt \d+ window'
    $chooser = Open-Chooser $g
    Assert ($chooser -ne [IntPtr]::Zero) 'the chooser reopens after the rebuild'
    if ($chooser -ne [IntPtr]::Zero) {
        $filter = Get-TestChildWindow -Window $chooser -Class 'Edit'
        Send-TestControlKey -Control $chooser -Key Down | Out-Null
        Start-Sleep -Milliseconds 500
        Wait-LogLine $errlogB "chooser roster: loaded (\d+) session.*device=$DEV" 15000 | Out-Null
        Start-Sleep -Milliseconds 800
        $btn = Get-RestoreAllButton $chooser
        Assert (Focus-RestoreAll $chooser $filter $btn) 'Tab reaches the button on the device row'
        Send-TestKeys -Window $chooser -Target $btn -Key Return | Out-Null
        $skipped = Wait-LogLine $errlogB "restore all: 't336-multi' is already open here" 12000
        Assert ($null -ne $skipped) 'H the window already on screen is skipped, not attached twice'
        Start-Sleep -Seconds 2
        Assert ((Count-LogLines $errlogB 'restore all: rebuilt \d+ window') -eq $rebuiltBefore) `
            'nothing was rebuilt'
        $shapesFinal = @(Get-WindowShapes)
        Assert ($shapesFinal.Count -eq $shapesAfter.Count) `
            "the window count did not change ($($shapesFinal.Count))"
    }
} finally {
    Stop-PipeBridge $script:bridge
    if ($null -ne $script:relay) { Stop-FakeRelay $script:relay }
    Copy-Item $portSaved $portFile -Force -ErrorAction SilentlyContinue
    Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
    Remove-TestDesktop
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red }
exit ([int]($script:fail -gt 0))
