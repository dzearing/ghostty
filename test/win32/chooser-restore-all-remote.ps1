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
#   F2 those per-window dials are opened TOGETHER (T616). The relay answers every
#      connect 1.5 s late, so a serial restore can only open window k's dial once
#      window k-1's was answered - its CONNECT lines land a whole delay apart.
#      The relay's own log is the witness, so this is not a wall-clock guess
#   F3 and the wait the user actually sits through therefore does not grow with
#      the window count: the whole restore costs about two round trips, not 1 + N
#   I  the app keeps PUMPING while those dials are outstanding (T339). The relay
#      is told to answer every connect 1.5 s late, so the restore is in flight
#      for seconds, and the chooser is asked for a WM_NULL every 150 ms
#      throughout. Before T339 all N+1 upgrades ran on the GUI thread and every
#      one of those probes would time out
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
    [int]$RelayPort = 47952,
    # How late the relay answers each `/connect` while section 6's slow-connect
    # file is armed. 1.5 s per dial x (1 pull + N windows) is several seconds of
    # in-flight time, which is the window the responsiveness probe measures in.
    [int]$SlowMs = 1500
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }

# Isolate the IPC endpoint (inherited through CreateProcessW).
$env:GHOZTTY_PIPE_SUFFIX = "-t336$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
# T652: the "attached is not alive" oracle. Read its header before adding an
# assertion about a rebuilt pane.
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')
. (Join-Path $PSScriptRoot 'lib\FakeRelay.ps1')
. (Join-Path $PSScriptRoot 'lib\PipeBridge.ps1')

$script:pass = 0
$script:fail = 0
$script:bodyComplete = $false

function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

function Stop-RepoProcesses([string[]]$Names) {
    # T351: the ghoztty halves go through the one shared, path-exact kill
    # (lib\CleanSlate.ps1) - every private copy answered "does the agent go too"
    # alone. Anything else in $Names is this script's own litter, so it stays local.
    if ($Names -contains 'ghoztty') {
        [void](Stop-RepoGhoztty -Exe $Exe -AppOnly:(-not ($Names -contains 'ghoztty-agent')) -SettleMs 0)
    }
    foreach ($name in ($Names | Where-Object { $_ -notin @('ghoztty', 'ghoztty-agent') })) {
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
        # `title` is the window's DISPLAY name - the `+rename` pin when one is
        # set, else the active tab's title. T1296: the cross-machine rebuild was
        # asserted to keep `target` and its topology and nothing ever looked at
        # the name the user actually reads off the title bar.
        $out += [pscustomobject]@{ Name = $w.target; Panes = $panes; Title = $w.title }
    }
    return @($out)
}

# Every leaf pane id under $node, in tree order (T413). `+list` auto-registers
# what it discovers and every --target/--name accepts a pane id directly, so
# these are usable as `+read` targets with no extra naming step.
# The pane id hangs off the leaf's `terminal` object, NOT off the leaf itself
# (`{type:leaf, terminal:{id,...}}`) - reading `$node.id` yields empty strings,
# and `+read --name=` then answers nothing for every pane, which reads exactly
# like a restore that lost the content.
function Get-LeafIds($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') {
        if ($null -ne $node.terminal) { return @($node.terminal.id) }
        if ($null -ne $node.viewer) { return @($node.viewer.id) }
        return @()
    }
    if ($node.type -eq 'split') { return @(Get-LeafIds $node.left) + @(Get-LeafIds $node.right) }
    return @()
}

# Poll $paneIds for $mark, whitespace-insensitively - the pane is a third of a
# 100-column window, so a marker sitting near the right edge comes back wrapped
# across two rows and a naive match misses content that is plainly there.
function Wait-PaneText($paneIds, $mark, $timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $needle = ($mark -replace '\s', '')
    while ((Get-Date) -lt $deadline) {
        foreach ($id in @($paneIds)) {
            $text = (& $Exe +read --name=$id --lines=200 2>$null | Out-String)
            if ((($text -replace '\s', '')) -match [regex]::Escape($needle)) { return $true }
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# The pane ids of the window whose ipc name is $name, in the app the CLI reaches.
function Get-WindowPaneIds($name) {
    $tree = Get-ListTree
    if ($null -eq $tree) { return @() }
    foreach ($w in @($tree.windows)) {
        if ($w.target -ne $name) { continue }
        $ids = @()
        foreach ($t in @($w.tabs)) { $ids += @(Get-LeafIds $t.splits) }
        return @($ids)
    }
    return @()
}

function Layouts-Store {
    $path = Join-Path $agentDir 'layouts.json'
    if (-not (Test-Path $path)) { return @() }
    try { $doc = (Get-Content $path -Raw) | ConvertFrom-Json } catch { return @() }
    if ($null -eq $doc -or $null -eq $doc.layouts) { return @() }
    return @($doc.layouts)
}

# The store record for the window whose IPC name is $name, found by reading the
# BLOB rather than the record key. T338 (landed 72 minutes after T336, and this
# script was not re-run) re-keyed every blob on the window's stable UUID, so
# `key -eq 't336-multi'` has matched nothing since - and PowerShell answered
# `@($null.session_ids).Count` = 1, which is why "no record at all" read as a
# window with one session id. The ipc_name inside the blob is what actually
# names the window, and it survives both keying schemes.
function Find-BlobFor($name) {
    foreach ($rec in Layouts-Store) {
        if ($rec.key -eq $name) { return $rec }   # pre-T338 keying
        $blob = $null
        try { $blob = $rec.blob | ConvertFrom-Json } catch { continue }
        if ($null -ne $blob -and $blob.ipc_name -eq $name) { return $rec }
    }
    return $null
}

# Poll until the named window's blob claims $n session ids. A record can exist
# before its panes have published their ids (the OPEN reply is async and
# syncSessionLayout re-arms a retry), so waiting for EXISTENCE would race a
# correct implementation (the T334 lesson).
function Wait-BlobIds($name, $n, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $rec = $null
    while ((Get-Date) -lt $deadline) {
        $rec = Find-BlobFor $name
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

# The Restore All button, asked for by its control ID (lib\ChooserControls.ps1,
# T294) and including hidden windows - the hidden state is a result this test
# needs to be able to read, and the caption this used to key on is one of the
# things the chooser is free to change. Returned as an HWND, which is what every
# call site here passes on to Send-TestKeys / Test-TestWindowVisible.
function Get-RestoreAllButton($chooser) {
    return ConvertTo-TestHwnd (Get-ChooserRestoreAllButton -Chooser $chooser)
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

# T616: when the relay saw each `/connect` for $device, from $fromIndex on. The
# log is stamped HH:mm:ss.fff, which is all the resolution a 1.5 s deferral
# needs. Returns the times in arrival order - the first is the layout pull's own
# dial, the rest are the windows'.
function Get-RelayConnectTimes($log, $device, $fromIndex) {
    if (-not (Test-Path $log)) { return @() }
    $lines = @(Get-Content $log)
    $out = @()
    for ($i = $fromIndex; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^(\d{2}:\d{2}:\d{2}\.\d{3}) CONNECT device=$device") {
            $out += [datetime]::ParseExact($Matches[1], 'HH:mm:ss.fff', $null)
        }
    }
    return $out
}

function Count-RelayConnects($log, $device) {
    if (-not (Test-Path $log)) { return 0 }
    return @(Select-String -Path $log -Pattern "CONNECT device=$device" -ErrorAction SilentlyContinue).Count
}

# Tab from the filter onto Restore All. Returns $true only when focus actually
# LANDED on the button. The walk is `Focus-ChooserControl` in
# lib\ChooserControls.ps1 (T342) - the private copy this replaced sampled focus
# once at a fixed 300ms and treated a transient 0 as fatal.
function Focus-RestoreAll($chooser, $filter, $btn) {
    return Focus-ChooserControl -Chooser $chooser -From $filter -To $btn
}

$TOKEN = 'faketoken-t336'
$DEV = 'dev-remote'
# T413: echoed into a fixture pane before the machine is taken away, and looked
# for again after the cross-machine rebuild. Space-free on purpose - send-keys
# concatenates adjacent text, and a marker with spaces in it cannot be matched
# back reliably once the pane has wrapped it (the T109 script's lesson).
$T413MARK = "T413RINGREPLAY$($PID)Z"
# T1296: the window's user-set NAME (a `+rename` title pin). The user reported a
# cross-machine restore bringing a window back anonymous, and every assertion
# here was about `target` and topology - neither of which is what they read off
# the title bar. Space-free so a `-like` prefix match cannot be confused by the
# activity suffix or the debug marker the title also carries.
$T1296NAME = "T1296Pinned$($PID)"
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
    # T413: a line of the machine's OWN output, so section 6 can ask whether the
    # rebuilt pane came back with its content and not merely with its shape. The
    # read-back HERE is the positive control: without it, a miss after the
    # rebuild is equally consistent with the marker never having been typed.
    Start-Sleep -Seconds 2
    & $Exe +send-keys --target=t336-multi "echo $T413MARK" Enter 2>$null | Out-Null
    $fixturePanes = @(Get-WindowPaneIds 't336-multi')
    Assert (Wait-PaneText $fixturePanes $T413MARK) `
        "the fixture pane really printed the marker before the machine went away ($($fixturePanes.Count) pane(s))"
    $alive = @(Wait-AliveCount 4)
    Assert ($alive.Count -ge 4) "the machine has four live sessions ($($alive.Count))"

    # T1296: give the window the NAME the user would give it, before the machine
    # is taken away. `+rename` pins the display title (`Window.setTitleOverride`,
    # the same path as the rename dialog) and marks the layout dirty, so the pin
    # rides the very next blob push.
    & $Exe +rename --target=t336-multi --title=$T1296NAME 2>$null | Out-Null
    Start-Sleep -Seconds 1
    $namedBefore = @(Get-WindowShapes | Where-Object { $_.Name -eq 't336-multi' }) | Select-Object -First 1
    Assert ($null -ne $namedBefore -and $namedBefore.Title -like "$T1296NAME*") `
        "the fixture window really carries its user-set name before the machine goes away ($(if ($namedBefore) { $namedBefore.Title } else { '<no window>' }))"

    $blob = Wait-BlobIds 't336-multi' 3
    Assert ($null -ne $blob -and @($blob.session_ids).Count -eq 3) `
        "A the agent holds the window's layout with its three session ids ($(@($blob.session_ids).Count))"
    # The other half of the fixture control: if the name never reached the blob
    # this is a CAPTURE bug, and no assertion about the rebuild could tell the
    # two apart.
    $blobName = $null
    if ($null -ne $blob) { try { $blobName = ($blob.blob | ConvertFrom-Json).title_override } catch {} }
    Assert ($blobName -eq $T1296NAME) `
        "A2 the stored blob carries the window's user-set name ($(if ($blobName) { $blobName } else { '<absent>' }))"
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
    # Armed only for section 6 (T339): while it exists every connect is answered
    # $SlowMs late, which is what makes "the app is still pumping" a measurable
    # claim rather than a race with a loopback dial that takes 3 ms.
    $slowConnect = Join-Path $tmp 'slowconnect'
    Remove-Item $slowConnect -ErrorAction SilentlyContinue
    $script:relay = Start-FakeRelay -Port $RelayPort -AgentPort $BridgePort `
        -DevicesJson $devicesJson -LogPath $relaylog -TripUnauthorizedFile $tripAuth `
        -SlowConnectFile $slowConnect -SlowConnectMs $SlowMs
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
    # T339: make the link slow, so the N+1 dials take seconds. Before T339 they
    # ran on the GUI thread and this is the interval in which the app answered
    # nothing at all.
    New-Item -ItemType File -Path $slowConnect -Force | Out-Null
    $deferBefore = Count-LogLines $relaylog 'DEFER '
    $btn = Get-RestoreAllButton $chooser
    Assert (Focus-RestoreAll $chooser $filter $btn) 'Tab reaches the button again (the positive control)'
    # T616: where the relay's log stood before this press, and when the press
    # happened - F2 and F3 measure the dialing phase from these two marks.
    $relayLinesBefore = if (Test-Path $relaylog) { @(Get-Content $relaylog).Count } else { 0 }
    $pressAt = Get-Date
    Send-TestKeys -Window $chooser -Target $btn -Key Return | Out-Null

    # I: the app keeps pumping while the restore is in flight. Each probe is a
    # WM_NULL SendMessageTimeout at the chooser - its wndproc runs on the GUI
    # thread, so an answer IS the message loop turning over. Probing stops at
    # the first sign the dialing phase is over (the rebuild itself legitimately
    # occupies the GUI thread, and measuring that would be measuring the wrong
    # thing).
    $probes = 0
    $blocked = 0
    $probeDeadline = (Get-Date).AddMilliseconds([Math]::Max(2000, $SlowMs * 2))
    while ((Get-Date) -lt $probeDeadline) {
        if (-not (Test-TestWindowExists -Window $chooser)) { break }
        if (Count-LogLines $errlogB 'restore all: rebuilt \d+ window') { break }
        $probes++
        if (-not (Test-TestWindowResponsive -Window $chooser -TimeoutMs 1000)) { $blocked++ }
        Start-Sleep -Milliseconds 150
    }
    $deferAfter = Count-LogLines $relaylog 'DEFER '
    Assert (($deferAfter - $deferBefore) -ge 1) `
        "the link really was slow for this press ($($deferAfter - $deferBefore) deferred connect(s) at ${SlowMs}ms)"
    Assert ($probes -ge 3) "the restore stayed in flight long enough to measure ($probes probes)"
    Assert ($blocked -eq 0) `
        "I the app kept pumping while the restore dialed ($blocked of $probes probes went unanswered)"

    $rebuilt = Wait-LogLine $errlogB 'restore all: rebuilt (\d+) window' 30000
    # T616: measured before the link is made fast again. Disarming the slow file
    # here rather than above the wait is the whole point - a restore that is
    # still dialing when the delay disappears would be timed against a link that
    # stopped being slow halfway through.
    $restoreMs = ((Get-Date) - $pressAt).TotalMilliseconds
    Remove-Item $slowConnect -ErrorAction SilentlyContinue
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
    # T1296: the reported loss. A restored set of windows the user cannot tell
    # apart is the symptom; `target` surviving is not a substitute, because it is
    # not what the title bar shows.
    Assert ($null -ne $restored -and $restored.Title -like "$T1296NAME*") `
        "E2 the rebuilt window came back with its user-set name ($(if ($restored) { $restored.Title } else { '<no window>' }))"

    # F: per-window transport ownership. The pull dials once for itself and each
    # rebuilt window dials its own, so the restore spends 1 + N connects. Fewer
    # would mean windows are sharing a connection - which `Window.deinit` then
    # frees out from under the others the first time one is closed.
    $connectsAfter = Count-RelayConnects $relaylog $DEV
    Assert (($connectsAfter - $connectsBefore) -ge ($rebuiltN + 1)) `
        "F the restore spent its own dial plus one per window ($($connectsAfter - $connectsBefore) connects for $rebuiltN windows)"

    # F2 (T616): and it opened them TOGETHER. Every connect is answered $SlowMs
    # late, so a serial dialer cannot start window k until window k-1 has been
    # answered and its CONNECT lines are a whole delay apart; a fan-out opens
    # them within milliseconds. The relay's log is the witness - our own clock
    # never enters into it - and F above still pins the COUNT, so concurrency
    # cannot be bought by sharing a connection.
    $windowConnects = @(@(Get-RelayConnectTimes $relaylog $DEV $relayLinesBefore) | Select-Object -Skip 1)
    $spanMs = 0
    if ($windowConnects.Count -ge 2) {
        $spanMs = ($windowConnects[$windowConnects.Count - 1] - $windowConnects[0]).TotalMilliseconds
    }
    Assert ($windowConnects.Count -ge 2) `
        "F2 the relay logged a dial per window for this press ($($windowConnects.Count) after the pull's own)"
    Assert ($windowConnects.Count -ge 2 -and $spanMs -lt ($SlowMs / 2)) `
        "F2 and they were opened together, not one after the other ($([int]$spanMs) ms apart; serial dialing puts them >= ${SlowMs}ms apart)"

    # F3: what the user actually waits. Serial dialing alone costs (1 + N) x the
    # link delay before the first window can appear; a fan-out costs about two
    # round trips whatever N is, so the wait stops growing with the number of
    # windows being brought back.
    Assert ($restoreMs -lt ((1 + $rebuiltN) * $SlowMs)) `
        "F3 the wait did not grow with the window count ($([int]$restoreMs) ms for $rebuiltN windows; serial dialing alone would spend $((1 + $rebuiltN) * $SlowMs) ms)"

    # G: the independent oracle. port.json comes back only so the CLI can find
    # the agent; the reading itself never goes through the app.
    Copy-Item $portSaved $portFile -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    $attached = @(Get-Sessions | Where-Object { $multiIds -contains $_.id -and $_.attached }).Count
    Assert ($attached -eq 3) `
        "G the agent reports all three original sessions ATTACHED ($attached of 3)"

    # --- J: WHICH re-attach a blob-sourced pane takes, and what it costs ----
    # T413 resolved this deliberately: layout blobs carry no WP-D3 snapshot, so
    # every pane rebuilt from one attaches at offset 0 and takes the agent's ring
    # replay. Asserting the log line pins the decision (a future change that put
    # snapshots back into the topology mirror - and re-uploaded every window on
    # every layout mutation - would flip these numbers and fail here), and the
    # marker read-back is the other half: the replay path must still deliver the
    # pane's CONTENT, which is what T106's capture-geometry reflow plus the
    # agent's own grid snapshot are there to guarantee.
    $deltaAttaches = 0
    $replayAttaches = 0
    foreach ($sid in $multiIds) {
        $line = Wait-LogLine $errlogB "attach: session=$sid offset=(\d+) snapshot=(\d+)" 5000
        if ($null -eq $line) { continue }
        if ($line -match 'offset=(\d+) snapshot=(\d+)') {
            if ([int64]$Matches[1] -gt 0 -or [int64]$Matches[2] -gt 0) { $deltaAttaches++ }
            else { $replayAttaches++ }
        }
    }
    Assert ($replayAttaches -eq 3) `
        "J every blob-sourced pane attached at offset=0 snapshot=0, the documented replay path ($replayAttaches of 3)"
    Assert ($deltaAttaches -eq 0) `
        "and none claimed a WP-D3 delta the blob cannot carry ($deltaAttaches)"

    $paneIds = @(Get-WindowPaneIds 't336-multi')
    Assert (Wait-PaneText $paneIds $T413MARK) `
        "J the replay still brought the machine's own output back ('$T413MARK' readable in $($paneIds.Count) rebuilt pane(s))"

    # K (T652): ATTACHED IS NOT ALIVE - and the replay assertion directly above
    # is the sharpest case of it, because a replayed marker is BY DEFINITION a
    # recording. G's `attached` is the agent's bookkeeping and E/F count windows
    # and dials; a pane rebuilt as a frozen picture satisfies all of them. Typing
    # is the only question a recording cannot answer, and here it crosses the
    # whole cross-machine path: local keystroke -> relay -> agent -> child, and
    # the child's answer all the way back onto this screen.
    Assert (Test-PaneLive -Exe $Exe -Target 't336-multi' -Tmp $tmp -Tag 'CRR') `
        'K a rebuilt REMOTE pane is LIVE: input crosses the relay and output comes back'

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
    # The last statement of the body, so an unwind cannot reach it: the stamp
    # below is only written for a run that got all the way here. (This script
    # scores itself rather than through lib\TestScore.ps1, so it keeps its own
    # flag instead of `Complete-TestBody`.)
    $script:bodyComplete = $true
} finally {
    Stop-PipeBridge $script:bridge
    if ($null -ne $script:relay) { Stop-FakeRelay $script:relay }
    Copy-Item $portSaved $portFile -Force -ErrorAction SilentlyContinue
    Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
    Remove-TestDesktop
}

# --- stamp (T616) ----------------------------------------------------------
# A clean, complete run records the files the restore-all-remote guard covers,
# so scripts\guard-due.ps1 stops asking until one of them changes again.
if ($script:fail -eq 0 -and $script:bodyComplete) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard restore-all-remote -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red }
exit ([int]($script:fail -gt 0))
