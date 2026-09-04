# Machine-chooser SESSION RESUME against a REMOTE machine (tracker T331).
#
# T320 shipped both halves of resume and only the LOCAL one is measured on box:
# `chooser-resume.ps1` builds its fixture out of the local agent's own orphaned
# sessions, because that is the machine a script can create sessions on. The
# remote half - `MachineChooser.resumeRow`'s `.remote` branch,
# `App.resumeRelaySession`, and `openDialedWindow`'s ATTACH shape - was code
# that compiles, is reachable from the UI, and had never once run here.
#
# THE FIXTURE, and why it is `chooser-restore-all-remote.ps1`'s rather than
# T319's. A remote resume needs a machine holding LIVE, UNATTACHED sessions
# whose content this script can recognise afterwards. A bare
# `ghoztty-agent --listen` (T319's "other machine") can hold sessions, but the
# only way to put a marker in one is to open a window on it - and closing that
# window ENDS the session, while leaving it open makes the row `open_locally`,
# which the chooser answers by FOCUSING the pane instead of attaching (T330).
# So the machine is this box's own agent, taken away and handed back only over
# the relay:
#
#   app A (persistence on)  ->  local agent  ->  three live sessions   [fixture]
#   kill app A                                                          [orphan]
#   delete port.json           the local agent is undiscoverable locally
#   lib\PipeBridge.ps1      ->  that pipe, exposed on a TCP port
#   lib\FakeRelay.ps1       ->  ws://.../connect bridged to that port
#   app B (persistence OFF) ->  sees it ONLY as relay device dev-remote
#
# Deleting `port.json` is what makes every reading discriminate: app B and the
# CLI both find the local agent through that file, so with it gone the Local row
# can only resolve to `failed` and everything app B knows about that machine, it
# learned through the relay.
#
# WHAT IS ASSERTED
#   A  setup: the machine's sessions are alive and UNATTACHED once app A is
#      gone, and the Local row of a fresh app has nothing to list
#   B  the device row loads that machine's roster over the relay, and Right
#      steps the keyboard cursor into it
#   C  Return on the cursored row resumes THAT session: the app names the id and
#      the device, the dial crosses the relay (counted on the far side), the
#      pane really ATTACHes, and the chooser dismisses onto the new window
#   D  the ATTACH shape (the T331 risk): a resumed window does NOT take the
#      machine's per-host default cwd, because an attach does not spawn and a
#      cwd sent with it would describe a spawn that is not happening. The
#      POSITIVE CONTROL is a NEW remote window through the same relay, which
#      MUST land in that stored directory - otherwise "the default did not
#      apply" is equally consistent with a store nothing reads
#   E  the resumed pane is LIVE, not painted (T652): typing crosses the relay to
#      the machine's own child and its answer comes back
#   F  the independent oracle - the agent, asked directly over its pipe once
#      port.json is back, reports that session ATTACHED where it was not before
#   G  a tripped relay leaves the chooser OPEN with its hint set and builds NO
#      window - never a half-open one - and then the SAME keys on the SAME row
#      resume it once the relay answers again (the mandatory positive control:
#      "nothing happened" is otherwise equally consistent with the keys never
#      arriving, the T240 lesson)
#
# T211/T217: runs on a BACKGROUND Win32 desktop and asserts it never took the
# user's foreground. T248: every repo ghoztty/ghoztty-agent is killed at setup
# and the agent state is dropped, so the fixture is built fresh rather than
# measuring the previous run. T267: the script sets its own window size.
#
#   powershell -NoProfile -File test\win32\chooser-resume-remote.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [int]$BridgePort = 47961,
    [int]$RelayPort = 47962
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }

# Isolate the IPC endpoint (inherited through CreateProcessW).
$env:GHOZTTY_PIPE_SUFFIX = "-t331$PID"

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\ChooserCursor.ps1')  # Step-ChooserCursor / Walk-ChooserCursorToId
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')
. (Join-Path $PSScriptRoot 'lib\FakeRelay.ps1')
. (Join-Path $PSScriptRoot 'lib\PipeBridge.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0

function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

# Kill only what this repo built. The installed release (and ITS agent, which
# owns the user's real terminal) is never touched.
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
$portSaved = Join-Path $env:TEMP "ghoztty-t331-port-$PID.json"
# Debug builds keep the per-host defaults store beside the release one under a
# `-debug` name, so seeding it here cannot touch the user's own settings. It is
# still saved and put back: this box's debug store is the loop's, not ours.
$storeFile = Join-Path $env:LOCALAPPDATA 'ghoztty\host_defaults-debug.json'
$storeSaved = Join-Path $env:TEMP "ghoztty-t331-hostdefaults-$PID.json"

function Reset-AgentState {
    foreach ($f in @('sessions.json', 'port.json', 'layouts.json')) {
        Remove-Item (Join-Path $agentDir $f) -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path $agentDir 'rings') -Recurse -Force -ErrorAction SilentlyContinue
}

function Remove-LayoutManifest {
    Remove-Item (Join-Path $env:LOCALAPPDATA 'ghoztty\session-layout-debug.json') -ErrorAction SilentlyContinue
}

# Write the store by hand rather than through ConvertTo-Json + Set-Content: PS
# 5.1's -Encoding utf8 emits a BOM, which the parser rejects - the store would
# read as EMPTY and section D would pass for the wrong reason (host-settings.ps1
# paid for this lesson). Backslashes are doubled for JSON.
function Set-HostDefault($key, $wd) {
    $j = '{"hosts":[{"key":"' + ($key -replace '\\', '\\') + '"' +
    ',"working_directory":"' + ($wd -replace '\\', '\\') + '"}]}'
    [IO.File]::WriteAllText($storeFile, $j, (New-Object Text.UTF8Encoding $false))
}

# `ghoztty +verb > file` writes zero bytes from PowerShell (T245) - capture
# through a pipe instead.
function Get-Sessions {
    $out = (& $Exe +sessions --json 2>$null | Out-String)
    if (-not $out -or $out.Trim().Length -eq 0) { return @() }
    try { $j = $out | ConvertFrom-Json } catch { return @() }
    if ($null -eq $j) { return @() }
    # PS5.1 unrolls a one-element array on return, so wrap before counting.
    return @($j)
}

function Get-SessionIds {
    return @(Get-Sessions | Where-Object { $_.alive } | ForEach-Object { $_.id })
}

# Wait for a NEW live session id to appear, and hand it back. Diffing the
# agent's own roster is what ties a window this script opened to the session id
# the chooser will later show for it, with no layout-blob timing in between.
function Wait-NewSessionId($before, $timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $new = @(Get-SessionIds | Where-Object { $before -notcontains $_ })
        if ($new.Count -ge 1) { return $new[0] }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Get-ListTree {
    $out = (& $Exe +list --json 2>$null | Out-String)
    if (-not $out -or $out.Trim().Length -eq 0) { return $null }
    try { $j = $out | ConvertFrom-Json } catch { return $null }
    if ($null -ne $j -and $null -ne $j.data) { return $j.data }
    return $j
}

# Every leaf pane id under $node, in tree order. The pane id hangs off the
# leaf's `terminal` object (`{type:leaf, terminal:{id,...}}`), NOT off the leaf
# itself - reading `$node.id` yields empty strings and every `+read --name=`
# then answers nothing, which reads exactly like a resume that lost the content.
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

function Get-AllPaneIds {
    $tree = Get-ListTree
    if ($null -eq $tree) { return @() }
    $ids = @()
    foreach ($w in @($tree.windows)) {
        foreach ($t in @($w.tabs)) { $ids += @(Get-LeafIds $t.splits) }
    }
    return @($ids)
}

# The DISPLAY title of the window holding $paneId - what the user reads off the
# title bar and out of Alt-Tab (T1296). Empty when no window holds that pane.
function Get-WindowTitleForPane($paneId) {
    $tree = Get-ListTree
    if ($null -eq $tree) { return '' }
    foreach ($w in @($tree.windows)) {
        foreach ($t in @($w.tabs)) {
            if (@(Get-LeafIds $t.splits) -contains $paneId) { return [string]$w.title }
        }
    }
    return ''
}

# The pane ids of the window whose ipc name is $name.
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

function Get-WindowCount {
    $tree = Get-ListTree
    if ($null -eq $tree) { return -1 }
    return @($tree.windows).Count
}

# `cmd /c` rather than a PowerShell redirect: bytes on disk written by cmd, so
# the read is the same text in any host (T526/T883).
function Read-Pane($id, $file) {
    cmd /c "`"$Exe`" +read --name=$id --lines=120 > `"$tmp\$file`" 2>&1" | Out-Null
    if (-not (Test-Path "$tmp\$file")) { return '' }
    $text = Get-Content "$tmp\$file" -Raw
    if ($null -eq $text) { return '' }
    return $text
}

function Wait-PaneText($ids, $needle, $tag, $timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $want = ($needle -replace '\s', '')
    while ((Get-Date) -lt $deadline) {
        foreach ($id in @($ids)) {
            $text = Read-Pane $id "read-$tag.txt"
            if ((($text -replace '\s', '')) -match [regex]::Escape($want)) { return $true }
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
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

function Count-RelayLines($path, $pattern) {
    if (-not (Test-Path $path)) { return 0 }
    return @(Get-FakeRelayLog $path | Select-String $pattern).Count
}

function Launch-Gui($errlog, [string[]]$extra) {
    $arguments = @('--window-width=110', '--window-height=32') + $extra
    $app = Start-OnTestDesktop -Exe $Exe -Arguments $arguments -StdErr $errlog
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
            $c = Wait-TestWindow -ProcessId $g.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 5000
            if ($c -ne [IntPtr]::Zero) { return $c }
        }
    }
    return [IntPtr]::Zero
}

# Keys go to the filter EDIT, which is where focus sits when the chooser opens -
# the state a real user is in when they press Right.
function Send-ChooserKey($chooser, $filter, $key) {
    return Send-TestKeys -Window $chooser -Target $filter -Key $key
}

# --- Cursor-log navigation (T602/T620, shared in lib\ChooserCursor.ps1) ------
# This file used to hold its own paste of the walk, with a 4000ms step timeout
# against chooser-resume.ps1's 3000 - two copies that had already drifted, and a
# third script (orphan-notify.ps1) that never got one and paid for it (T1107).
# There is one copy now; these keep the positional shape the call sites use.
function Step-Cursor($chooser, $filter, $log, $key) {
    return Step-ChooserCursor -Chooser $chooser -Filter $filter -Log $log -Key $key
}

function Walk-CursorToId($chooser, $filter, $log, [string[]]$TargetIds, [int]$MaxRows) {
    return Walk-ChooserCursorToId -Chooser $chooser -Filter $filter -Log $log `
        -TargetIds $TargetIds -MaxRows $MaxRows
}

$TOKEN = 'faketoken-t331'
$DEV = 'dev-remote'
# Space-free on purpose: +send-keys concatenates adjacent TEXT positionals, and
# a marker with spaces cannot be matched back once a pane has wrapped it.
$MARK = "T331ATTACH$($PID)Z"
# T1296: the user's own name for the fixture window. A resume used to build a
# window with no name at all, so a user who resumed three sessions on another
# machine got three windows they could not tell apart. Space-free so a `-like`
# prefix match is not confused by the activity suffix or the debug marker the
# window title also carries.
$T1296NAME = "T1296Resumed$($PID)"
$devicesJson = '{"devices":[{"id":"' + $DEV + '","name":"E2E-Remote","hostname":"remote.local","online":true}]}'

$errlogA = Join-Path $env:TEMP "ghoztty-t331-stderrA-$PID.log"
$errlogB = Join-Path $env:TEMP "ghoztty-t331-stderrB-$PID.log"
$relaylog = Join-Path $env:TEMP "ghoztty-t331-relay-$PID.log"
$bridgelog = Join-Path $env:TEMP "ghoztty-t331-bridge-$PID.log"
$tmp = Join-Path $env:TEMP "ghoztty-t331-$PID"
$storeDir = Join-Path $tmp 't331-store'
New-Item -ItemType Directory -Force $tmp | Out-Null
New-Item -ItemType Directory -Force $storeDir | Out-Null
Remove-Item $errlogA, $errlogB, $relaylog -ErrorAction SilentlyContinue

Write-Host 'T331 chooser session resume - REMOTE machine over the relay'
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null
Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
Reset-AgentState
Remove-LayoutManifest
Copy-Item $storeFile $storeSaved -Force -ErrorAction SilentlyContinue
Remove-Item $storeFile -ErrorAction SilentlyContinue
Start-TestForegroundWatch
New-TestDesktop | Out-Null

$script:relay = $null
$script:bridge = $null
try {
    # --- 1. the machine: three live sessions, one of them marked ------------
    Write-Host ''
    Write-Host '1. the machine: an app, its agent, and three live sessions'
    $g = Launch-Gui $errlogA @('--session-persistence=true')
    if (-not $g) { Write-TestAssertedNothing -Reason 'the fixture GUI died at launch' -Label 'CHOOSER RESUME REMOTE' }

    $ids0 = @(Get-SessionIds)
    & $Exe +new-window --target=t331-w2 2>$null | Out-Null
    $markedId = Wait-NewSessionId $ids0
    $ids1 = @(Get-SessionIds)
    & $Exe +new-window --target=t331-w3 2>$null | Out-Null
    $spareId = Wait-NewSessionId $ids1
    if ($null -eq $markedId -or $null -eq $spareId) {
        Write-TestAssertedNothing -Reason 'the fixture windows produced no new agent sessions' -Label 'CHOOSER RESUME REMOTE'
    }
    Write-Host "  OK   fixture sessions: marked=$markedId spare=$spareId"

    # A line of the MACHINE'S own output, so section D can ask whether the
    # resumed pane came back with that session's content rather than a fresh
    # shell. The read-back here is the positive control for the marker itself:
    # without it, a miss after the resume is equally consistent with the marker
    # never having been typed.
    & $Exe +send-keys --target=t331-w2 "echo $MARK" Enter 2>$null | Out-Null
    $markedPanes = @(Get-WindowPaneIds 't331-w2')
    Assert (Wait-PaneText $markedPanes $MARK 'fixture') `
        "the marked pane really printed '$MARK' before the machine went away"

    # T1296: the NAME the user gave this window. `+rename` pins the display
    # title (the same path as the rename dialog), and the pin rides the layout
    # blob the machine's agent keeps - which is the only place app B can learn
    # it from, since section 2 deletes this box's own manifest.
    & $Exe +rename --target=t331-w2 --title=$T1296NAME 2>$null | Out-Null
    Start-Sleep -Seconds 2
    $namedBefore = if ($markedPanes.Count -ge 1) { Get-WindowTitleForPane $markedPanes[0] } else { '' }
    Assert ($namedBefore -like "$T1296NAME*") `
        "the fixture window really carries its user-set name before the machine goes away ($namedBefore)"

    # --- 2. take the machine away, hand it back only over the relay ---------
    Write-Host ''
    Write-Host '2. app A is gone and port.json with it: the agent is reachable only through the relay'
    Stop-RepoProcesses @('ghoztty')
    Remove-LayoutManifest
    $orphans = @(Get-Sessions | Where-Object { $_.alive })
    $unattached = @($orphans | Where-Object { -not $_.attached })
    Assert ($unattached.Count -ge 3) `
        "A the sessions outlived the app, unattached ($($unattached.Count) of $($orphans.Count) alive)"
    $wasAttached = @($orphans | Where-Object { $_.id -eq $markedId -and $_.attached }).Count
    Assert ($wasAttached -eq 0) 'A and the row this run will resume has no viewer yet'

    Copy-Item $portFile $portSaved -Force -ErrorAction SilentlyContinue
    Remove-Item $portFile -ErrorAction SilentlyContinue
    Assert (-not (Test-Path $portFile)) 'A the local agent is no longer discoverable locally'

    $pipeName = Get-LocalAgentPipeName
    $script:bridge = Start-PipeBridge -Port $BridgePort -PipeName $pipeName -LogPath $bridgelog
    Assert ((Test-Path $bridgelog) -and (Select-String -Path $bridgelog -Pattern 'LISTEN' -Quiet)) `
        "the pipe bridge fronts $pipeName on 127.0.0.1:$BridgePort"

    $tripFile = Join-Path $tmp 'trip'
    Remove-Item $tripFile -ErrorAction SilentlyContinue
    $script:relay = Start-FakeRelay -Port $RelayPort -AgentPort $BridgePort `
        -DevicesJson $devicesJson -LogPath $relaylog -TripFile $tripFile
    Assert ((Test-Path $relaylog) -and (Select-String -Path $relaylog -Pattern 'LISTEN' -Quiet)) `
        "the fake relay serves that machine as device $DEV"

    # --- 3. app B: no local agent, one relay device, a per-host default -----
    Write-Host ''
    Write-Host '3. a fresh app with no local agent, and a stored default for that machine'
    # The store is seeded BEFORE app B starts, so both the resume (which must
    # ignore it) and the new-window control (which must honour it) meet the same
    # store. The key for a relay machine is the DEVICE ID (T174).
    Set-HostDefault $DEV $storeDir
    $env:GHOSTTY_RELAY_BASE = "http://127.0.0.1:$RelayPort"
    $env:GHOSTTY_RELAY_TOKEN = $TOKEN
    $env:GHOSTTY_ACCOUNT_STORE = (Join-Path $tmp 'account.dat')
    $g = Launch-Gui $errlogB @('--session-persistence=false')
    foreach ($k in 'GHOSTTY_RELAY_BASE', 'GHOSTTY_RELAY_TOKEN', 'GHOSTTY_ACCOUNT_STORE') {
        Remove-Item "env:$k" -ErrorAction SilentlyContinue
    }
    if (-not $g) { Write-TestAssertedNothing -Reason 'app B died at launch' -Label 'CHOOSER RESUME REMOTE' }
    Assert (-not (Test-TestDesktopLeak -ProcessId $g.Pid)) 'the window is NOT on the user''s desktop'

    $chooser = Open-Chooser $g
    Assert ($chooser -ne [IntPtr]::Zero) 'ctrl+shift+n opens the chooser'
    if ($chooser -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'the chooser never opened; nothing about the resume was measured' -Label 'CHOOSER RESUME REMOTE'
    }
    $filter = ConvertTo-TestHwnd (Get-ChooserFilterField -Chooser $chooser)
    Assert ($filter -ne [IntPtr]::Zero) 'the chooser has its filter field'

    Assert ((Count-RelayLines $relaylog '/v1/client/devices') -ge 1) `
        'the device directory came from OUR relay'
    $localLine = Wait-LogLine $errlogB 'chooser roster: (loaded|fetch failed) .*target=local' 12000
    Assert ($null -ne $localLine -and $localLine -match 'fetch failed .*target=local') `
        "A the Local row has nothing to list ($localLine)"

    # --- 4. the device row's roster, and the keyboard cursor in it ----------
    Write-Host ''
    Write-Host '4. the device row lists the machine''s sessions and the cursor steps into them'
    Send-TestControlKey -Control $chooser -Key Down | Out-Null
    Start-Sleep -Milliseconds 500
    $remoteLine = Wait-LogLine $errlogB "chooser roster: loaded (\d+) session.*device=$DEV" 20000
    $remoteCount = -1
    if ($remoteLine -match 'loaded (\d+) session') { $remoteCount = [int]$Matches[1] }
    Assert ($remoteCount -ge 3) "B the device row loaded the remote machine's sessions ($remoteCount)"
    if ($remoteCount -lt 3) {
        Write-TestAssertedNothing -Reason 'the remote roster never loaded; there was no row to resume' -Label 'CHOOSER RESUME REMOTE'
    }

    $walked = Walk-CursorToId $chooser $filter $errlogB @($markedId) ($remoteCount + 2)
    Assert ($null -ne $walked) "B Right steps the cursor into the roster and Down walks it to the marked row ($walked)"
    if ($null -eq $walked) {
        Write-TestAssertedNothing -Reason 'the cursor never reached the marked row' -Label 'CHOOSER RESUME REMOTE'
    }
    Start-Sleep -Milliseconds 400

    # --- 5. the resume -----------------------------------------------------
    Write-Host ''
    Write-Host '5. Return resumes THAT session, over the relay'
    $connectsBefore = Count-RelayLines $relaylog "CONNECT device=$DEV"
    $windowsBefore = Get-WindowCount
    $panesBefore = @(Get-AllPaneIds)
    Send-ChooserKey $chooser $filter 'Return' | Out-Null
    $attachLine = Wait-LogLine $errlogB "resume session: attaching remote session id=([0-9a-fA-F]+) device=$DEV" 15000
    Assert ($null -ne $attachLine) "C Return on the cursored row resumes it remotely ($attachLine)"
    $resumedId = ''
    if ($attachLine -and $attachLine -match 'id=([0-9a-fA-F]+)') { $resumedId = $Matches[1] }
    Assert ($resumedId -eq $walked) `
        "C the resumed session is the row the cursor was on ($resumedId vs $walked)"

    $connectsAfter = Count-RelayLines $relaylog "CONNECT device=$DEV"
    Assert (($connectsAfter - $connectsBefore) -ge 1) `
        "C the resume dialled the machine through the relay ($($connectsAfter - $connectsBefore) connect(s), counted on the far side)"

    # The pane's OWN account of what it did, one layer below the App's: an
    # ATTACH to that session id rather than an OPEN of a fresh one.
    $paneAttach = Wait-LogLine $errlogB "attach: session=$markedId offset=(\d+) snapshot=(\d+)" 20000
    Assert ($null -ne $paneAttach) "C the pane really ATTACHed to that session ($paneAttach)"

    Start-Sleep -Seconds 3
    Assert (-not (Test-TestWindowExists -Window $chooser)) 'C the chooser dismissed itself onto the resumed window'
    $windowsAfter = Get-WindowCount
    Assert ($windowsAfter -eq ($windowsBefore + 1)) `
        "C exactly one window was opened for it ($windowsBefore -> $windowsAfter)"

    # --- 6. the ATTACH shape: no per-host defaults on a resume --------------
    Write-Host ''
    Write-Host '6. a resumed window does not take the machine''s default working directory'
    $resumedPanes = @(@(Get-AllPaneIds) | Where-Object { $panesBefore -notcontains $_ })
    Assert ($resumedPanes.Count -ge 1) "the resumed pane is addressable ($($resumedPanes.Count) new pane(s))"

    # C2 (T1296): the reported loss. This box's own manifest was deleted in
    # section 2, so the only place the name can have come from is the FAR
    # machine's layout blobs, pulled with the roster over the relay.
    $resumedTitle = if ($resumedPanes.Count -ge 1) { Get-WindowTitleForPane $resumedPanes[0] } else { '' }
    Assert ($resumedTitle -like "$T1296NAME*") `
        "C2 the resumed window came back with the name the user gave it ($resumedTitle)"
    $resumedText = ''
    if ($resumedPanes.Count -ge 1) {
        Assert (Wait-PaneText $resumedPanes $MARK 'resumed') `
            "D the resumed pane came back with the MACHINE'S own output ('$MARK')"
        $resumedText = Read-Pane $resumedPanes[0] 'resumed-final.txt'
    }
    Assert (-not ($resumedText -like '*t331-store*')) `
        'D and NOT in the stored per-host working directory - an attach does not spawn'

    # POSITIVE CONTROL for D: the same store, the same machine, an OPEN. If this
    # window does not land in the stored directory then "the default did not
    # apply" above is equally consistent with a store nothing ever reads.
    cmd /c "`"$Exe`" +new-remote-window --relay=http://127.0.0.1:$RelayPort --device=$DEV --name=t331-open > `"$tmp\openwin.txt`" 2>&1" | Out-Null
    Start-Sleep -Seconds 4
    $openPanes = @(Get-WindowPaneIds 't331-open')
    Assert ($openPanes.Count -ge 1) "the control window opened on the same machine ($($openPanes.Count) pane(s))"
    Assert (Wait-PaneText $openPanes 't331-store' 'control') `
        'D positive control: a NEW remote window DOES start in that stored directory'

    # --- 7. the resumed pane is live, not painted (T652) --------------------
    Write-Host ''
    Write-Host '7. the resumed pane is LIVE, not a picture of one'
    if ($resumedPanes.Count -ge 1) {
        Assert (Test-PaneLive -Exe $Exe -Target $resumedPanes[0] -Tmp $tmp -Tag 'CRR') `
            'E input crosses the relay to the machine''s own child and its answer comes back'
    }

    # --- 8. the independent oracle -----------------------------------------
    Write-Host ''
    Write-Host '8. the agent, asked directly, reports that session attached'
    # port.json comes back only so the CLI can find the agent; the reading
    # itself never goes through the app.
    Copy-Item $portSaved $portFile -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    $row = @(Get-Sessions | Where-Object { $_.id -eq $resumedId })
    Assert ($row.Count -eq 1 -and $row[0].attached) `
        "F the agent reports the resumed session ATTACHED (rows=$($row.Count))"

    # --- 9. a machine that stops answering ---------------------------------
    Write-Host ''
    Write-Host '9. the relay goes down between the roster and the keystroke'
    $chooser = Open-Chooser $g
    Assert ($chooser -ne [IntPtr]::Zero) 'the chooser reopens'
    if ($chooser -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'the chooser never reopened; the failure path was not measured' -Label 'CHOOSER RESUME REMOTE'
    }
    $filter = ConvertTo-TestHwnd (Get-ChooserFilterField -Chooser $chooser)
    Send-TestControlKey -Control $chooser -Key Down | Out-Null
    Start-Sleep -Milliseconds 500
    $reload = Wait-LogLine $errlogB "chooser roster: loaded (\d+) session.*device=$DEV" 20000
    $reloadCount = -1
    if ($reload -match 'loaded (\d+) session') { $reloadCount = [int]$Matches[1] }
    Assert ($reloadCount -ge 3) "the roster reloaded for the second visit ($reloadCount)"
    $walked2 = Walk-CursorToId $chooser $filter $errlogB @($spareId) ($reloadCount + 2)
    Assert ($null -ne $walked2) "the cursor walks to a second, still-unresumed row ($walked2)"
    if ($null -eq $walked2) {
        Write-TestAssertedNothing -Reason 'the cursor never reached the spare row' -Label 'CHOOSER RESUME REMOTE'
    }
    Start-Sleep -Milliseconds 400

    # The trip lands AFTER the roster loaded and the cursor is parked: a machine
    # that was reachable a moment ago and is not now, which is the reachable
    # shape of this failure rather than a device that never listed at all.
    New-Item -ItemType File -Path $tripFile -Force | Out-Null
    $attachesBefore = Count-LogLines $errlogB 'resume session: attaching remote session'
    $windowsBeforeFail = Get-WindowCount
    Send-ChooserKey $chooser $filter 'Return' | Out-Null
    $failed = Wait-LogLine $errlogB 'machine chooser: resume relay session failed err=error.DialFailed' 20000
    Assert ($null -ne $failed) "G the failed dial is reported, not swallowed ($failed)"
    Start-Sleep -Seconds 2
    Assert (Test-TestWindowExists -Window $chooser) `
        'G the chooser stayed OPEN to say so rather than dismissing onto nothing'
    $hint = Get-ChooserHintText -Chooser $chooser
    Assert ($hint -match "ouldn't reach that machine") "G and its hint says so ($hint)"
    Assert ((Count-LogLines $errlogB 'resume session: attaching remote session') -eq $attachesBefore) `
        'G nothing was attached on a dial that never succeeded'
    Assert ((Get-WindowCount) -eq $windowsBeforeFail) `
        "G and no half-open window was left behind ($windowsBeforeFail)"

    # --- 10. the positive control ------------------------------------------
    Write-Host ''
    Write-Host '10. positive control: the same keys, the same row, once the machine answers again'
    Remove-Item $tripFile -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Send-ChooserKey $chooser $filter 'Return' | Out-Null
    $second = Wait-LogLine $errlogB "resume session: attaching remote session id=$spareId device=$DEV" 20000
    Assert ($null -ne $second) "G the same keystroke resumes the row once the relay answers ($second)"
    Start-Sleep -Seconds 3
    Assert (-not (Test-TestWindowExists -Window $chooser)) 'G and the chooser dismissed onto it'
    Assert ((Get-WindowCount) -eq ($windowsBeforeFail + 1)) `
        "G exactly one window this time ($windowsBeforeFail -> $(Get-WindowCount))"

    Assert (-not (Test-TestDesktopLeak -ProcessId $g.Pid)) 'the run never took the user''s foreground'
    Complete-TestBody
} catch {
    # A run that THREW measured nothing after the throw, and the sections that
    # already passed must not carry it (T329/T1039).
    $script:fail++
    Write-Host "  FAIL the run threw before it finished: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "       at line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
} finally {
    Stop-PipeBridge $script:bridge
    Stop-FakeRelay $script:relay
    Copy-Item $portSaved $portFile -Force -ErrorAction SilentlyContinue
    if (Test-Path $storeSaved) { Copy-Item $storeSaved $storeFile -Force -ErrorAction SilentlyContinue }
    else { Remove-Item $storeFile -ErrorAction SilentlyContinue }
    Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
    Remove-TestDesktop
    Stop-TestForegroundWatch | Out-Null
    Remove-Item 'env:GHOZTTY_PIPE_SUFFIX' -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "  app A stderr: $errlogA"
Write-Host "  app B stderr: $errlogB"
Write-Host "  relay log:    $relaylog"

# --- stamp (T783/T816) ------------------------------------------------------
# Only a CLEAN green run records the covered files: a red run must stay due, and
# so must one that skipped a section, since a stamp over unmeasured code is the
# green hat the T219 audit refuses.
if ($script:fail -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard chooser-resume-remote -Repo $repo 2>&1 |
        ForEach-Object { Write-Host "  $($_.ToString())" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped `
    -Label 'CHOOSER RESUME REMOTE'
