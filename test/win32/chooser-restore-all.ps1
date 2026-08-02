# Machine-chooser RESTORE ALL acceptance (tracker T335).
#
# T334 made this machine's window topology visible to the agent (one layout blob
# per window). This is the task that spends it: the chooser offers "Restore All"
# for a machine with two or more LIVE sessions, and pressing it rebuilds that
# machine's whole window/tab/split topology here - sourced from the AGENT's copy
# of the layout, not from this box's session-layout.json. That source is the
# whole point: it works when the local manifest is gone, which is exactly when a
# user wants their windows back and exactly when launch-time restore can do
# nothing (Mac: SessionLayoutRestore.swift:586-588).
#
# What this drives, end to end, against a REAL local agent:
#
#   1. the >= 2 ALIVE rule, from both sides. A one-session machine must NOT
#      offer the button, and the control that says so is the SAME probe finding
#      the button HIDDEN rather than absent - a lookup that cannot see hidden
#      windows would report "no button" for a bug and for correct behavior
#      alike. Then panes are added and the same probe finds it shown.
#   2. the rebuild. The fixture orphans a 3-pane window the way a crash does
#      (kill the APP, keep the agent, drop the manifest), and Restore All brings
#      it back: one window, the recorded split topology, every pane ATTACHed to
#      its original session - cross-checked against `ghoztty +sessions --json`,
#      which dials the agent directly and never goes through the app.
#   3. the double-attach guard. Pressing it again must rebuild NOTHING: the
#      agent rebinds a session to the newest attach, so a second rebuild would
#      steal the panes out of the window it just made.
#
# The keyboard is the trigger under test, not a shortcut around it: Tab walks to
# the button and the script asserts FOCUS LANDED ON IT before pressing Return.
# Without that check "nothing happened" is equally consistent with the keys never
# arriving (the T240 lesson).
#
# The fixture builds TWO multi-pane windows and both must come back: one named
# with `+new-window --target=`, and one the user never named, which carries only
# the auto ipc name (`window-N`) the app allocates. That second window is the
# T338 case: its key used to be that per-run name, so the relaunched app's own
# blank startup window claimed it and overwrote the topology inside the layout
# debounce - before anyone could press anything. Keys are per-window uuids now,
# so the correct answer is two rebuilt windows, not one.
#
# T248: the repo's agent AND its app are killed at setup and the agent's state is
# dropped, so the fixture is built fresh instead of measuring the previous run's
# sessions.
# T267: the script sets its own window size rather than inheriting whatever the
# last GUI script left in window_placement-debug.
#
#   powershell -NoProfile -File test\win32\chooser-restore-all.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }

# Isolate the IPC endpoint (inherited through CreateProcessW).
$env:GHOZTTY_PIPE_SUFFIX = '-t335'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

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

function Reset-AgentState {
    $dir = Join-Path $env:LOCALAPPDATA 'ghoztty\local-agent-debug'
    foreach ($f in @('sessions.json', 'port.json', 'layouts.json')) {
        Remove-Item (Join-Path $dir $f) -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path $dir 'rings') -Recurse -Force -ErrorAction SilentlyContinue
}

# Dropping the layout manifest is what makes the orphan fixture: with it the
# relaunched app re-attaches the very windows this test needs to be missing, and
# the rebuild would have nothing left to prove.
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

function Get-AliveSessions { return @(Get-Sessions | Where-Object { $_.alive }) }

function Wait-AliveCount($target, $timeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $rows = @()
    while ((Get-Date) -lt $deadline) {
        $rows = @(Get-AliveSessions)
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
    $path = Join-Path $env:LOCALAPPDATA 'ghoztty\local-agent-debug\layouts.json'
    if (-not (Test-Path $path)) { return @() }
    try { $doc = (Get-Content $path -Raw) | ConvertFrom-Json } catch { return @() }
    if ($null -eq $doc -or $null -eq $doc.layouts) { return @() }
    return @($doc.layouts)
}

# Poll until the blob of the window named $ipcName claims $n session ids. A
# record can exist before its panes have published their ids (the OPEN reply is
# async and syncSessionLayout re-arms a retry), so waiting for EXISTENCE would
# race a correct implementation (the T334 lesson).
#
# The lookup goes through the BLOB's `ipc_name`, not the record key: since T338
# the key is the window's stable uuid, which is exactly the point - no key in
# this store is derived from anything the app re-allocates per run.
function Wait-BlobIds($ipcName, $n, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $rec = $null
    while ((Get-Date) -lt $deadline) {
        $rec = @(Layouts-Store | Where-Object {
                $w = $null
                try { $w = $_.blob | ConvertFrom-Json } catch {}
                $null -ne $w -and $w.ipc_name -eq $ipcName
            }) | Select-Object -First 1
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
    if (-not (Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl, shift -Key N)) { return [IntPtr]::Zero }
    return Wait-TestWindow -ProcessId $g.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 5000
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

function Send-ChooserKey($chooser, $filter, $key) {
    return Send-TestKeys -Window $chooser -Target $filter -Key $key
}

# Tab from the filter to Restore All: filter -> list -> New Window -> Restore
# All (Activity and the `…` are hidden on the Local row and are stepped over).
# Returns $true when focus actually landed on the button, which the caller
# asserts BEFORE pressing anything.
#
# Each Tab is re-aimed at whatever now holds focus, and that is not a nicety:
# `Send-TestKeys` SetFocus()es its -Target before posting (TestDesktop's
# SendChord attaches to the GUI thread to do it), so five Tabs all aimed at the
# filter walk the SAME first step five times and focus never leaves the list.
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

function Wait-RosterLoaded($errlog, $timeoutMs = 10000) {
    return Wait-LogLine $errlog 'chooser roster: loaded (\d+) session' $timeoutMs
}

Write-Host 'T335 chooser Restore All'
Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
Reset-AgentState
Remove-LayoutManifest
New-TestDesktop | Out-Null

$errlog1 = Join-Path $env:TEMP "ghoztty-t335-stderr1-$PID.log"
$errlog2 = Join-Path $env:TEMP "ghoztty-t335-stderr2-$PID.log"
Remove-Item $errlog1, $errlog2 -ErrorAction SilentlyContinue

try {
    # --- 1. the rule's negative side ---------------------------------------
    Write-Host ''
    Write-Host '1. one live session: the button exists and is HIDDEN'
    $g = Launch-Gui $errlog1 @('--session-persistence=true')
    if (-not $g) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $alive1 = @(Wait-AliveCount 1)
    Assert ($alive1.Count -eq 1) "the startup pane is the machine's only session ($($alive1.Count))"

    $chooser = Open-Chooser $g
    Assert ($chooser -ne [IntPtr]::Zero) 'ctrl+shift+n opens the chooser'
    if ($chooser -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no chooser'; exit 1 }
    $filter = Get-TestChildWindow -Window $chooser -Class 'Edit'
    Assert ($filter -ne [IntPtr]::Zero) 'the chooser has its filter field'
    Assert ($null -ne (Wait-RosterLoaded $errlog1)) 'the roster loaded before anything was read'
    Start-Sleep -Milliseconds 600

    $btn = Get-RestoreAllButton $chooser
    # The control EXISTING is what makes the next assertion meaningful: a probe
    # that cannot see hidden windows says "absent" for a defect and for correct
    # behavior alike.
    Assert ($btn -ne [IntPtr]::Zero) 'the Restore All control exists on the chooser'
    Assert (-not (Test-TestWindowVisible -Window $btn)) 'and it is HIDDEN with one live session'

    Send-ChooserKey $chooser $filter 'Escape' | Out-Null
    Start-Sleep -Milliseconds 600

    # --- 2. the rule's positive side ---------------------------------------
    Write-Host ''
    Write-Host '2. two multi-pane windows - one named, one only auto-named'
    # The startup window is the T338 fixture: the user never named it, so its
    # only ipc name is the auto `window-N` the app allocates from a per-process
    # counter - the very name the relaunched app hands its own blank window.
    $shapes0 = @(Get-WindowShapes)
    $autoName = if ($shapes0.Count -ge 1) { $shapes0[0].Name } else { '' }
    Assert ($autoName -match '^window-\d+$') "the startup window carries an auto ipc name ($autoName)"
    & $Exe +split --target=$autoName --direction=down 2>$null | Out-Null
    Start-Sleep -Seconds 2

    & $Exe +new-window --target=t335-multi 2>$null | Out-Null
    Start-Sleep -Seconds 2
    & $Exe +split --target=t335-multi --direction=right 2>$null | Out-Null
    Start-Sleep -Seconds 2
    & $Exe +split --target=t335-multi --direction=down 2>$null | Out-Null
    $alive2 = @(Wait-AliveCount 5)
    Assert ($alive2.Count -ge 5) "the machine now has five live sessions ($($alive2.Count))"

    # The blobs are the thing Restore All reads, so wait for them to SETTLE here
    # rather than discovering mid-rebuild that they were still filling in.
    $blob = Wait-BlobIds 't335-multi' 3
    Assert ($null -ne $blob -and @($blob.session_ids).Count -eq 3) `
        "the agent holds the named window's layout with its three session ids ($(@($blob.session_ids).Count))"
    $multiIds = if ($null -ne $blob) { @($blob.session_ids) } else { @() }

    $blobAuto = Wait-BlobIds $autoName 2
    Assert ($null -ne $blobAuto -and @($blobAuto.session_ids).Count -eq 2) `
        "and the auto-named window's, with its two ($(@($blobAuto.session_ids).Count))"
    $autoIds = if ($null -ne $blobAuto) { @($blobAuto.session_ids) } else { @() }
    Assert ($null -ne $blobAuto -and $blobAuto.key -ne $autoName) `
        'the auto-named window is keyed by something other than its per-run name (T338)'

    $chooser = Open-Chooser $g
    Assert ($chooser -ne [IntPtr]::Zero) 'the chooser reopens'
    $filter = Get-TestChildWindow -Window $chooser -Class 'Edit'
    Assert ($null -ne (Wait-RosterLoaded $errlog1)) 'the roster loaded again'
    Start-Sleep -Milliseconds 800
    $btn = Get-RestoreAllButton $chooser
    Assert ($btn -ne [IntPtr]::Zero -and (Test-TestWindowVisible -Window $btn)) `
        'the same probe now finds Restore All SHOWN'
    Send-ChooserKey $chooser $filter 'Escape' | Out-Null
    Start-Sleep -Milliseconds 600

    # --- 3. the rebuild -----------------------------------------------------
    Write-Host ''
    Write-Host '3. after a crash with no manifest, Restore All rebuilds the window'
    # Kill the APP only: the agent keeps the children alive - the whole point of
    # session persistence - and with the manifest gone the relaunch cannot
    # re-attach them, so the topology exists ONLY in the agent's blob.
    Stop-RepoProcesses @('ghoztty')
    Remove-LayoutManifest
    $orphans = @(Get-AliveSessions)
    Assert ($orphans.Count -ge 5) "the sessions outlived the app ($($orphans.Count) alive)"

    $g = Launch-Gui $errlog2 @('--session-persistence=true')
    if (-not $g) { Write-Host 'SETUP FAIL: GUI died on relaunch'; exit 1 }
    Start-Sleep -Seconds 3
    $shapesBefore = @(Get-WindowShapes)
    Assert ($shapesBefore.Count -eq 1) `
        "the relaunched app restored nothing on its own ($($shapesBefore.Count) window)"

    $attachedBefore = @(Get-Sessions | Where-Object { $multiIds -contains $_.id -and $_.attached }).Count
    Assert ($attachedBefore -eq 0) 'none of the orphaned panes has a viewer yet'

    $chooser = Open-Chooser $g
    Assert ($chooser -ne [IntPtr]::Zero) 'the chooser opens on the relaunched app'
    if ($chooser -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no chooser'; exit 1 }
    $filter = Get-TestChildWindow -Window $chooser -Class 'Edit'
    Assert ($null -ne (Wait-RosterLoaded $errlog2)) 'the roster loaded'
    Start-Sleep -Milliseconds 800
    $btn = Get-RestoreAllButton $chooser
    Assert ($btn -ne [IntPtr]::Zero -and (Test-TestWindowVisible -Window $btn)) `
        'Restore All is offered for the local machine'

    Assert (Focus-RestoreAll $chooser $filter $btn) 'Tab walks focus onto the Restore All button'
    # Aimed at the BUTTON: Send-TestKeys focuses its target first, so a Return
    # aimed at the filter would press the default action instead.
    Send-TestKeys -Window $chooser -Target $btn -Key Return | Out-Null

    $rebuilt = Wait-LogLine $errlog2 'restore all: rebuilt (\d+) window' 10000
    Assert ($null -ne $rebuilt) 'Return on the button rebuilds at least one window'
    Start-Sleep -Seconds 3
    Assert (-not (Test-TestWindowExists -Window $chooser)) 'the chooser dismissed itself onto the rebuild'

    $shapesAfter = @(Get-WindowShapes)
    Assert ($shapesAfter.Count -eq ($shapesBefore.Count + 2)) `
        "both windows came back ($($shapesBefore.Count) -> $($shapesAfter.Count))"
    $restored = @($shapesAfter | Where-Object { $_.Name -eq 't335-multi' }) | Select-Object -First 1
    Assert ($null -ne $restored) 'the rebuilt window kept its ipc name'
    Assert ($null -ne $restored -and $restored.Panes -eq 3) `
        "and its recorded split topology - three panes ($(if ($restored) { $restored.Panes } else { 0 }))"
    # The auto-named window is identified by SHAPE, not by name: its recorded
    # `window-N` collides with the one the relaunched app already handed its own
    # blank window, and which registration survives that is T121's question, not
    # this one's. The blank window is single-pane; a 2-pane window can only be
    # the rebuilt one.
    $restoredAuto = @($shapesAfter | Where-Object { $_.Panes -eq 2 }) | Select-Object -First 1
    Assert ($null -ne $restoredAuto) `
        'the window the user never named came back too, with its two panes (T338)'

    # The independent oracle: the agent, dialled directly, now reports a viewer
    # on every one of those sessions. Nothing about this reading goes through
    # the app, and none of them was attached a moment ago.
    Start-Sleep -Seconds 1
    $attachedAfter = @(Get-Sessions | Where-Object { $multiIds -contains $_.id -and $_.attached }).Count
    Assert ($attachedAfter -eq 3) `
        "the agent reports all three original sessions ATTACHED ($attachedAfter of 3)"
    $attachedAuto = @(Get-Sessions | Where-Object { $autoIds -contains $_.id -and $_.attached }).Count
    Assert ($attachedAuto -eq 2) `
        "and both of the auto-named window's sessions ATTACHED ($attachedAuto of 2)"

    # --- 4. the double-attach guard ----------------------------------------
    Write-Host ''
    Write-Host '4. pressing it again rebuilds nothing (the panes are already here)'
    $rebuiltBefore = Count-LogLines $errlog2 'restore all: rebuilt \d+ window'
    $chooser = Open-Chooser $g
    Assert ($chooser -ne [IntPtr]::Zero) 'the chooser reopens after the rebuild'
    $filter = Get-TestChildWindow -Window $chooser -Class 'Edit'
    Assert ($null -ne (Wait-RosterLoaded $errlog2)) 'the roster loaded'
    Start-Sleep -Milliseconds 800
    $btn = Get-RestoreAllButton $chooser
    Assert (Focus-RestoreAll $chooser $filter $btn) 'Tab reaches the button again (the positive control)'
    Send-TestKeys -Window $chooser -Target $btn -Key Return | Out-Null
    $skipped = Wait-LogLine $errlog2 "restore all: 't335-multi' is already open here" 8000
    Assert ($null -ne $skipped) 'the window already on screen is skipped, not attached twice'
    Start-Sleep -Seconds 2
    Assert ((Count-LogLines $errlog2 'restore all: rebuilt \d+ window') -eq $rebuiltBefore) `
        'nothing was rebuilt'
    Assert (Test-TestWindowExists -Window $chooser) `
        'and the chooser stayed OPEN to say so rather than dismissing onto nothing'
    $shapesFinal = @(Get-WindowShapes)
    Assert ($shapesFinal.Count -eq $shapesAfter.Count) `
        "the window count did not change ($($shapesFinal.Count))"
} finally {
    Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
    Remove-TestDesktop
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red }
exit ([int]($script:fail -gt 0))
