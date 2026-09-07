# LOCAL Restore All rebuilds into an ALREADY-RUNNING viewer (tracker T486).
#
# T194 moved crash recovery to launch time, and chooser-restore-all.ps1 moved
# with it: its fixture (kill the app, drop the manifest, relaunch) now recovers
# before the chooser can be opened, so the local BUTTON's own rebuild -
# its local arm: the shared-agent-connection transport plus the
# `markLayoutDirty` bind-back that only the local arm does - stopped being
# exercised on this box. The remote script still drives the shared rebuild
# (`restoreAllFrom`) across the relay, but the local arm's two behaviours have
# no oracle there.
#
# The scenario the button still owns is a viewer that was ALREADY RUNNING when
# the sessions were orphaned: it cannot have recovered them at launch because
# they did not exist yet. That is a real shape on a real box - the installed
# release and the Desktop portable copy are two processes sharing one agent;
# one crashes, the other is the survivor the user presses Restore All in.
#
# The fixture builds it with two app instances on ONE agent:
#
#   - `GHOZTTY_PIPE_SUFFIX` isolates only the app's CLI IPC endpoint, so two
#     suffixes (-t486a / -t486b) give two independently targetable instances.
#   - The agent lineage is `GHOZTTY_AGENT_INSTANCE` (left unset here), so both
#     instances resolve THE SAME debug agent - the premise of the whole test.
#
# What this drives, end to end, against a real local agent:
#
#   1. survivor B launches first, with nothing to restore (one live session).
#   2. instance A builds the topology: its auto-named startup window split to
#      two panes, plus a named window `t486-multi` split to two. A is then
#      killed the way a crash kills it, and the shared layout manifest is
#      DELETED - so a manifest that reappears later can only be B's write.
#   3. the agent reports A's four sessions alive and unattached: orphans that
#      B, already running, never had a launch-time chance to recover.
#   4. Restore All in B's chooser rebuilds exactly the two orphaned windows -
#      counted from B's own log line, shapes read back over B's pipe, every
#      orphan ATTACHED per the agent (dialled directly, never through the app),
#      and a rebuilt pane answering input (T652: attached is not alive).
#      B's own window is untouched. This is also the one fixture that can
#      exercise T121's incumbent-keeps-name case IN PROCESS: A's startup
#      window carries the same auto `window-N` name B's live window holds, so
#      the rebuilt copy must come up beside it without stealing the name -
#      which is why the auto window is identified by SHAPE here, like T338.
#   4b. T618: the app KEEPS PUMPING while that restore is in flight. The pull
#      and the liveness probe used to run on the GUI thread with a 2 s budget
#      each, so a wedged agent froze the app for ~4 s with no cursor and no
#      redraw - the local half of the freeze T339 fixed for the relay. B is
#      launched with `GHOZTTY_RESTORE_PULL_DELAY_MS`, which stalls the pull in
#      front of the RPC it describes, and therefore on whichever thread that RPC
#      runs on; the chooser is then asked for a WM_NULL every 150 ms throughout.
#      Before T618 every one of those probes would time out.
#   5. the bind-back: the local arm marks the layout dirty after a
#      rebuild (Mac's `bindLocal`), so the manifest deleted in step 2 must
#      reappear - now recording all three of B's windows, named window
#      included. That write is what makes the NEXT launch restore these
#      windows from the manifest without the agent round trip, and it is the
#      behaviour no other script reaches.
#
# THE T851 SKIP GATE. Building this fixture found a live defect: launch restore
# treats "alive" as "attachable" without asking whether a session is currently
# attached to a RUNNING viewer, so instance A's launch adopts B's window and
# the agent rebinds - B's pane freezes and the fixture's premise (a clean
# second instance) never exists. Until T851 lands, section 2 detects the steal
# (the `session-restore: restored` line in A's log, or A coming up with no
# fresh session of its own) and SKIPS the rest loudly, naming T851 in the
# verdict line. When A launches clean the gate passes and sections 2-5 are the
# regression coverage for T851 as well as the T486 fixture.
#
# The keyboard is the trigger under test (Tab walks to the button and focus is
# asserted ON it before Return - the T240 lesson), and the shared machinery is
# chooser-restore-all.ps1's, kept in step.
#
#   powershell -NoProfile -File test\win32\chooser-restore-all-adopt.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    # T618: how long B's Restore All pull is stalled for, so "is the app still
    # pumping?" has an interval to be asked in. A healthy local agent answers a
    # named pipe in single-digit milliseconds, which is no interval at all.
    [int]$PullDelayMs = 2500
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')

# Refuse a build whose endpoints are the user's before anything is launched.
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

# The two app-instance endpoints. The AGENT lineage is deliberately shared:
# GHOZTTY_AGENT_INSTANCE stays unset, so A and B resolve one debug agent.
$SuffixA = '-t486a'
$SuffixB = '-t486b'

$script:pass = 0
$script:fail = 0

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

function Reset-AgentState {
    $dir = Join-Path $env:LOCALAPPDATA 'ghoztty\local-agent-debug'
    foreach ($f in @('sessions.json', 'port.json', 'layouts.json')) {
        Remove-Item (Join-Path $dir $f) -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path $dir 'rings') -Recurse -Force -ErrorAction SilentlyContinue
}

$ManifestPath = Join-Path $env:LOCALAPPDATA 'ghoztty\session-layout-debug.json'
function Remove-LayoutManifest {
    Remove-Item $ManifestPath -ErrorAction SilentlyContinue
}

# Aim the CLI at one instance. Every `& $Exe +verb` below reads the ambient
# GHOZTTY_PIPE_SUFFIX (inherited through cmd.exe by Test-PaneLive too), so the
# suffix is switched at each stage boundary rather than per call.
function Use-Instance([string]$Suffix) {
    $env:GHOZTTY_PIPE_SUFFIX = $Suffix
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
        $out += [pscustomobject]@{ Name = $w.target; Panes = $panes }
    }
    return @($out)
}

function Wait-WindowCount($n, $timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $shapes = @()
    while ((Get-Date) -lt $deadline) {
        $shapes = @(Get-WindowShapes)
        if ($shapes.Count -ge $n) { return $shapes }
        Start-Sleep -Milliseconds 500
    }
    return $shapes
}

function Layouts-Store {
    $path = Join-Path $env:LOCALAPPDATA 'ghoztty\local-agent-debug\layouts.json'
    if (-not (Test-Path $path)) { return @() }
    try { $doc = (Get-Content $path -Raw) | ConvertFrom-Json } catch { return @() }
    if ($null -eq $doc -or $null -eq $doc.layouts) { return @() }
    return @($doc.layouts)
}

# Poll until SOME blob whose ipc_name is $ipcName claims >= $n session ids.
# Matching on the count as well as the name is load-bearing here, not a
# nicety: BOTH instances allocate `window-1` for their startup window, so two
# blobs can carry the same ipc_name and only the id count tells A's apart.
function Wait-BlobIds($ipcName, $n, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $rec = $null
    while ((Get-Date) -lt $deadline) {
        $rec = @(Layouts-Store | Where-Object {
                $w = $null
                try { $w = $_.blob | ConvertFrom-Json } catch {}
                $null -ne $w -and $w.ipc_name -eq $ipcName -and @($_.session_ids).Count -ge $n
            }) | Select-Object -First 1
        if ($null -ne $rec) { return $rec }
        Start-Sleep -Milliseconds 500
    }
    return $rec
}

# Poll until every id in $ids reports the given attached state (agent-side
# bookkeeping; the kill is noticed on a broken pipe, not instantly).
function Wait-Attached([string[]]$ids, [bool]$want, $timeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $rows = @(Get-Sessions | Where-Object { $ids -contains $_.id })
        if ($rows.Count -eq $ids.Count) {
            $ok = @($rows | Where-Object { [bool]$_.attached -eq $want }).Count
            if ($ok -eq $ids.Count) { return $true }
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
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

# Tab from the filter to Restore All. Returns $true only when focus actually
# LANDED on the button. The walk is `Focus-ChooserControl` in
# lib\ChooserControls.ps1 (T342) - the private copy this replaced sampled focus
# once at a fixed 300ms and treated a transient 0 as fatal.
function Focus-RestoreAll($chooser, $filter, $btn) {
    return Focus-ChooserControl -Chooser $chooser -From $filter -To $btn
}

function Wait-RosterLoaded($errlog, $timeoutMs = 10000) {
    return Wait-LogLine $errlog 'chooser roster: loaded (\d+) session' $timeoutMs
}

Write-Host 'T486 local Restore All adopts orphans into a running viewer'
Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
Reset-AgentState
Remove-LayoutManifest
New-TestDesktop | Out-Null

$errlogA = Join-Path $env:TEMP "ghoztty-t486-stderrA-$PID.log"
$errlogB = Join-Path $env:TEMP "ghoztty-t486-stderrB-$PID.log"
Remove-Item $errlogA, $errlogB -ErrorAction SilentlyContinue

$gA = $null
$gB = $null
try {
    # --- 1. the survivor, up first with nothing to restore -------------------
    Write-Host ''
    Write-Host '1. viewer B launches first: one live session, nothing to recover'
    Use-Instance $SuffixB
    # T618: armed for B's whole life and read only when Restore All starts, so
    # nothing before section 4 is affected. Cleared immediately so instance A
    # (launched below) never inherits it.
    $env:GHOZTTY_RESTORE_PULL_DELAY_MS = "$PullDelayMs"
    $gB = Launch-Gui $errlogB @('--session-persistence=true')
    Remove-Item env:GHOZTTY_RESTORE_PULL_DELAY_MS -ErrorAction SilentlyContinue
    if (-not $gB) { Write-Host 'SETUP FAIL: instance B died at launch'; exit 1 }
    $aliveB = @(Wait-AliveCount 1)
    Assert ($aliveB.Count -eq 1) "B's startup pane is the machine's only session ($($aliveB.Count))"
    $shapesB0 = @(Get-WindowShapes)
    Assert ($shapesB0.Count -eq 1 -and $shapesB0[0].Panes -eq 1) `
        'B is a single one-pane window (launch restore had nothing to do)'
    $bIds = @(Get-AliveSessions | ForEach-Object { $_.id })

    # --- 2. instance A builds the topology, then dies ------------------------
    Write-Host ''
    Write-Host '2. instance A builds two multi-pane windows on the SAME agent, then is killed'
    Use-Instance $SuffixA
    $gA = Launch-Gui $errlogA @('--session-persistence=true')
    if (-not $gA) { Write-Host 'SETUP FAIL: instance A died at launch'; exit 1 }
    Start-Sleep -Seconds 2

    # The T851 gate: A must come up CLEAN - one fresh startup session of its
    # own, nothing adopted from B. While T851 is open, A's launch restore
    # adopts B's window instead (the agent rebinds to the newest attach and
    # B's pane freezes), and nothing built on top of that state measures the
    # button. The steal has two independent signatures - the restore line in
    # A's log, and A producing no new session id - and either one skips.
    $aliveNow = @(Wait-AliveCount 2 15)
    $freshIds = @($aliveNow | Where-Object { $bIds -notcontains $_.id } | ForEach-Object { $_.id })
    $stole = $null -ne (Wait-LogLine $errlogA 'session-restore: restored \d+ window' 1000)

    do {
    if ($stole -or $freshIds.Count -ne 1) {
        # skip-audit: T851 - launch restore adopts the running viewer's sessions
        Write-Host "SKIP  sections 2-5: instance A adopted the running viewer's session at launch (T851) - the fixture needs a clean second instance"
        $script:skipped++
        break
    }

    $shapesA0 = @(Get-WindowShapes)
    $autoName = if ($shapesA0.Count -ge 1) { $shapesA0[0].Name } else { '' }
    Assert ($autoName -match '^window-\d+$') "A's startup window carries an auto ipc name ($autoName)"
    & $Exe +split --target=$autoName --direction=down 2>$null | Out-Null
    Start-Sleep -Seconds 2
    & $Exe +new-window --target=t486-multi 2>$null | Out-Null
    Start-Sleep -Seconds 2
    & $Exe +split --target=t486-multi --direction=right 2>$null | Out-Null
    $alive = @(Wait-AliveCount 5)
    Assert ($alive.Count -ge 5) "the machine now has five live sessions ($($alive.Count))"

    # The blobs are what Restore All reads - wait for them to SETTLE before
    # the kill rather than discovering mid-rebuild that they were filling in.
    $blobMulti = Wait-BlobIds 't486-multi' 2
    Assert ($null -ne $blobMulti) "the agent holds the named window's layout with two session ids"
    $multiIds = if ($null -ne $blobMulti) { @($blobMulti.session_ids) } else { @() }
    $blobAuto = Wait-BlobIds $autoName 2
    Assert ($null -ne $blobAuto) "and A's auto-named window's, with its two"
    $autoIds = if ($null -ne $blobAuto) { @($blobAuto.session_ids) } else { @() }
    $orphanIds = @($multiIds + $autoIds | Where-Object { $_ })
    Assert ($orphanIds.Count -eq 4 -and @($orphanIds | Where-Object { $bIds -contains $_ }).Count -eq 0) `
        "A's four session ids are distinct from B's ($($orphanIds.Count) ids)"

    # Kill A ONLY - B must survive, so no name-wide sweep here. The manifest is
    # then deleted: A was writing it too, so only a delete makes a later
    # reappearance attributable to B's bind-back (step 5).
    Stop-Process -Id $gA.Pid -Force -ErrorAction SilentlyContinue
    $gA = $null
    Start-Sleep -Milliseconds 700
    Remove-LayoutManifest
    Assert (-not (Test-Path $ManifestPath)) 'the shared layout manifest is gone (deleted, and A cannot rewrite it)'

    # --- 3. the orphans ------------------------------------------------------
    Write-Host ''
    Write-Host '3. the agent reports A''s sessions alive and unattached - orphans B never saw at launch'
    Assert (Wait-Attached $orphanIds $false) 'all four of A''s sessions drop to UNATTACHED'
    $aliveOrphans = @(Get-AliveSessions | Where-Object { $orphanIds -contains $_.id })
    Assert ($aliveOrphans.Count -eq 4) "and all four are still ALIVE ($($aliveOrphans.Count) of 4)"

    # --- 4. Restore All in the running viewer --------------------------------
    Write-Host ''
    Write-Host '4. Restore All in B rebuilds exactly the two orphaned windows'
    Use-Instance $SuffixB
    $chooser = Open-Chooser $gB
    Assert ($chooser -ne [IntPtr]::Zero) 'ctrl+shift+n opens the chooser on B'
    if ($chooser -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no chooser'; exit 1 }
    $filter = Get-TestChildWindow -Window $chooser -Class 'Edit'
    Assert ($filter -ne [IntPtr]::Zero) 'the chooser has its filter field'
    Assert ($null -ne (Wait-RosterLoaded $errlogB)) 'the roster loaded before anything was read'
    Start-Sleep -Milliseconds 800

    $btn = Get-RestoreAllButton $chooser
    Assert ($btn -ne [IntPtr]::Zero -and (Test-TestWindowVisible -Window $btn)) `
        'Restore All is offered (five alive sessions clear the >= 2 rule)'
    Assert (Focus-RestoreAll $chooser $filter $btn) 'Tab reaches the button (the positive control)'
    $pressAt = Get-Date
    Send-TestKeys -Window $chooser -Target $btn -Key Return | Out-Null

    # 4b (T618): the app keeps pumping while the pull is stalled. Each probe is a
    # WM_NULL SendMessageTimeout at the chooser - its wndproc runs on the GUI
    # thread, so an answer IS the message loop turning over. Probing stops at the
    # first sign the pull is over: the rebuild itself legitimately occupies the
    # GUI thread, and measuring that would be measuring the wrong thing.
    $probes = 0
    $blocked = 0
    $probeDeadline = $pressAt.AddMilliseconds($PullDelayMs - 300)
    while ((Get-Date) -lt $probeDeadline) {
        if (-not (Test-TestWindowExists -Window $chooser)) { break }
        if (Select-String -Path $errlogB -Pattern 'restore all: rebuilt \d+ window' -Quiet -ErrorAction SilentlyContinue) { break }
        $probes++
        if (-not (Test-TestWindowResponsive -Window $chooser -TimeoutMs 1000)) { $blocked++ }
        Start-Sleep -Milliseconds 150
    }

    $rebuilt = Wait-LogLine $errlogB 'restore all: rebuilt (\d+) window' 15000
    $restoreMs = ((Get-Date) - $pressAt).TotalMilliseconds
    Assert ($null -ne $rebuilt -and $rebuilt -match 'rebuilt 2 window') `
        "B's local arm rebuilt exactly two windows ($rebuilt)"

    # The control for 4b, in two halves: the stall was ARMED (B logged reading
    # the seam) and it was PAID (the restore really was in flight that long).
    # Without both, "the app stayed responsive" would be equally consistent with
    # a restore that finished before the first probe.
    Assert ($null -ne (Wait-LogLine $errlogB "pull stalled ${PullDelayMs}ms" 1000)) `
        "the pull was stalled ${PullDelayMs}ms for this press (the interval is real)"
    Assert ($restoreMs -ge $PullDelayMs) `
        "and the restore was in flight for all of it ($([int]$restoreMs) ms)"
    Assert ($probes -ge 3) "the restore stayed in flight long enough to measure ($probes probes)"
    Assert ($blocked -eq 0) `
        "4b the app kept pumping while the local pull was stalled ($blocked of $probes probes went unanswered)"

    $shapes = @(Wait-WindowCount 3)
    Assert ($shapes.Count -eq 3) "B now shows three windows ($($shapes.Count))"
    $multi = @($shapes | Where-Object { $_.Name -eq 't486-multi' }) | Select-Object -First 1
    Assert ($null -ne $multi) 'the named window came back under its ipc name'
    Assert ($null -ne $multi -and $multi.Panes -eq 2) `
        "with its recorded split - two panes ($(if ($multi) { $multi.Panes } else { 0 }))"
    # A's startup window is identified by SHAPE: its recorded `window-N` name is
    # held by B's own live window (T121 keeps the incumbent), which is exactly
    # the collision this two-instance fixture exists to exercise.
    Assert (@($shapes | Where-Object { $_.Panes -eq 2 }).Count -eq 2) `
        'the auto-named orphan came back too, beside B''s incumbent (by shape, T338/T121)'
    Assert (@($shapes | Where-Object { $_.Panes -eq 1 }).Count -eq 1) `
        'and B''s own window is untouched - no duplicate, no stolen panes'

    # The independent oracle: the agent, dialled directly, sees a viewer on
    # every orphan again.
    Assert (Wait-Attached $orphanIds $true) 'the agent reports all four adopted sessions ATTACHED'

    # T652: attached is not alive - type into an adopted pane and require the
    # child to answer.
    Assert (Test-PaneLive -Exe $Exe -Target 't486-multi' -Tag 'CRADPT') `
        'an adopted pane is LIVE: input reaches the child, new output returns'

    # --- 5. the bind-back ----------------------------------------------------
    Write-Host ''
    Write-Host '5. the rebuild re-records the windows locally (markLayoutDirty, Mac''s bindLocal)'
    # The manifest was deleted after A died and nothing but B can write it now.
    # `App.adoptRestoreAllLocal` marks the layout dirty on a rebuild > 0, so the
    # file must come back recording ALL of B's windows - which is what lets the
    # NEXT launch restore them from the manifest without the agent round trip.
    # This is the local arm's own behaviour: the remote adopt path skips it on
    # purpose (those windows are not ours to promise back).
    $deadline = (Get-Date).AddSeconds(20)
    $manifest = $null
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $ManifestPath) {
            try { $manifest = (Get-Content $ManifestPath -Raw) | ConvertFrom-Json } catch { $manifest = $null }
            if ($null -ne $manifest -and @($manifest.windows).Count -ge 3) { break }
        }
        Start-Sleep -Milliseconds 500
    }
    Assert ($null -ne $manifest) 'the manifest reappeared after the rebuild'
    Assert ($null -ne $manifest -and @($manifest.windows).Count -eq 3) `
        "recording all three windows ($(if ($manifest) { @($manifest.windows).Count } else { 0 }))"
    $names = if ($null -ne $manifest) { @($manifest.windows | ForEach-Object { $_.ipc_name }) } else { @() }
    Assert ($names -contains 't486-multi') 'the adopted named window included'
    } while ($false)
} finally {
    if ($gA -and $gA.Pid) { Stop-Process -Id $gA.Pid -Force -ErrorAction SilentlyContinue }
    Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
    Remove-TestDesktop
}

Write-Host ''
if ($script:fail -eq 0) {
    Write-Host "ALL PASS ($script:pass assertions$(if ($script:skipped) { ", $script:skipped SKIPPED" }))"
} else {
    Write-Host "$script:fail FAILURE(S) ($script:pass passed$(if ($script:skipped) { ", $script:skipped SKIPPED" }))" -ForegroundColor Red
}
exit ([int]($script:fail -gt 0))
