# Agent-owned layout blobs (tracker T334) - the plumbing under cross-machine
# "Restore All" (section 5.4 / T18). Proves that the win32 app MIRRORS its live
# window topology into the local agent's `layouts.json` and keeps that mirror
# CONVERGENT: one record per restorable window, each carrying the session ids
# its panes are attached to, records updated as the topology changes, and
# records DELETED when their window goes away.
#
# Why it matters: the agent's blob store is what another viewer reads to rebuild
# a machine's windows. Before T334 win32 pushed nothing, so a Windows machine
# was invisible to Restore All - including from itself.
#
#   A. one startup window -> one record, one session id, a single-leaf blob.
#   B. +split -> the SAME record now has 3 nodes (a split over two leaves) and
#      TWO session ids. (Upsert, not a second record.)
#   C. +new-window --target=blob-second -> a SECOND record under its own stable
#      key; the first is untouched.
#   D. +close --target=blob-second -> that record is DELETED and the survivor
#      is the first window. This is the close path, with no close hook: the
#      sync's reconcile pass is what removes it.
#   E. hard-kill the GUI (the quit / crash / upgrade class) -> the blobs SURVIVE
#      in the agent. That is the whole point of the store: the machine stays
#      restorable while no viewer is running.
#   F. (T338/T194) relaunch with the local manifest GONE - the crash case - and
#      the dead run's record must still be there, intact, under its own key.
#      Since T194 that relaunch RECOVERS the window from that record rather than
#      opening a blank one beside it, so the key it comes back under is the same
#      uuid; a window opened afterwards still takes a fresh key of its own.
#
# Non-interactive and headless-safe: no foreground grabs, no synthetic input, so
# it does not need the T211 background-desktop harness. Fully hermetic: a
# per-run $env:LOCALAPPDATA + per-run GHOSTTY_LOCAL_AGENT_BIN, and it ONLY ever
# kills ghoztty / ghoztty-agent processes launched from the repo zig-out (T248 -
# never the user's real release instance, which uses a different IPC socket and
# agent lineage).
#
#   powershell -NoProfile -File test\win32\layout-blobs.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

# T1240: the GUI launches ON THE TEST DESKTOP, not on the user's. A window
# arrives on the desktop of whoever started the process, so both launches here
# used to put one across whatever the user was reading. The CLI calls stay on
# `Run-Cli`: none of the verbs they use can create a process.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$ErrorActionPreference = 'Continue'
$script:failures = 0
$root = Join-Path $env:TEMP "ghoztty-layout-blobs-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

function Stop-TestProcs {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 700)
}

# Kill ONLY the zig-out GUI, leaving the agent running - the app-exit class.
function Stop-GuiOnly {
    # T351: the shared, path-exact kill (lib\CleanSlate.ps1). -AppOnly is the
    # point of this helper - the agent (and its PTYs) stay up - and exact-exe is
    # what the private copy's '*zig-out*' filter got wrong: that also matched a
    # detached instance running from zig-out-release (T53b).
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 900)
}

# Run a zig-out ghoztty +command with a hard timeout; stdout+stderr -> $out.
function Run-Cli($argsLine, $out, $timeoutSec = 15) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$out`" 2>&1`""
    $null = $p.Handle   # before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1)
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

# --- the store under test ----------------------------------------------------

function Layouts-Path($tmp) { Join-Path $tmp 'ghoztty\local-agent-debug\layouts.json' }

# The blob key shape since T338: a window's stable uuid (8-4-4-4-12 hex), the
# same textual form as a pane id. NOT the manifest `id` (`window-N` / `win-N`),
# which restarts per app process and is what made a relaunch overwrite the
# previous run's topology.
function Is-Uuid($s) {
    return ($s -is [string]) -and
        ($s -match '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$')
}

# Parsed layouts.json, or $null. Each element gains a decoded `.win` (the blob
# parsed as a session-layout window) so assertions read the topology directly.
function Get-Layouts($tmp) {
    $path = Layouts-Path $tmp
    if (-not (Test-Path $path)) { return $null }
    $doc = $null
    try { $doc = (Get-Content $path -Raw) | ConvertFrom-Json } catch { return $null }
    if ($null -eq $doc -or $null -eq $doc.layouts) { return $null }
    $out = @()
    foreach ($rec in @($doc.layouts)) {
        $win = $null
        try { $win = $rec.blob | ConvertFrom-Json } catch {}
        $out += [pscustomobject]@{
            key         = $rec.key
            session_ids = @($rec.session_ids)
            win         = $win
        }
    }
    return @($out)
}

# Poll until the store holds exactly $n records (or timeout). Returns the last
# reading either way, so a failed assertion still shows what was there.
function Wait-Records($tmp, $n, $timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $recs = @()
    while ((Get-Date) -lt $deadline) {
        $recs = Get-Layouts $tmp
        if ($null -ne $recs -and @($recs).Count -eq $n) { return @($recs) }
        Start-Sleep -Milliseconds 400
    }
    return @($recs)
}

# Poll until the record keyed $key has $n session ids.
function Wait-RecordIds($tmp, $key, $n, $timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $rec = $null
    while ((Get-Date) -lt $deadline) {
        $recs = Get-Layouts $tmp
        $rec = @($recs | Where-Object { $_.key -eq $key }) | Select-Object -First 1
        if ($null -ne $rec -and @($rec.session_ids).Count -eq $n) { return $rec }
        Start-Sleep -Milliseconds 400
    }
    return $rec
}

# The flat node array of a decoded blob's first tab.
#
# ALWAYS call this as `@(Nodes $rec)`: PowerShell 5.1 unrolls a function's
# array return, so a ONE-node tree (the single-leaf window in section A) comes
# back as a bare PSCustomObject whose `.Count` is $null and whose `[0]` is not
# an element. A three-node tree happens to survive - which is exactly how this
# trap passes the interesting case and fails the simple one.
function Nodes($rec) {
    if ($null -eq $rec -or $null -eq $rec.win -or $null -eq $rec.win.tabs) { return @() }
    return @(@($rec.win.tabs)[0].nodes)
}

# --- the live topology, for cross-checking ----------------------------------

function Get-Sessions($tmp, $tag) {
    $code = Run-Cli '+sessions --json' "$tmp\sess-$tag.json" 12
    if ($code -ne 0) { return @() }
    $rows = $null
    try { $rows = Out-Text "$tmp\sess-$tag.json" | ConvertFrom-Json } catch {}
    if ($null -eq $rows) { return @() }
    return @($rows)
}
function Alive-Ids($rows) { return @($rows | Where-Object { $_.alive -eq $true } | ForEach-Object { $_.id }) }

function Wait-AliveCount($tmp, $tag, $target, $timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $rows = @()
    while ((Get-Date) -lt $deadline) {
        $rows = Get-Sessions $tmp $tag
        if (@(Alive-Ids $rows).Count -eq $target) { return $rows }
        Start-Sleep -Milliseconds 500
    }
    return $rows
}

$td = New-TestDesktop

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN

Assert "agent binary exists in zig-out" (Test-Path $AgentExe)
Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)

$tmp = Join-Path $root 'run'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe

# T441: a private IPC endpoint. The LOCALAPPDATA redirect above does not cover
# it — the endpoint a CLI dials comes from the pane's baked
# `$GHOZTTY_IPC_SOCKET` unless a suffix outranks it, so without this the +split
# and +close calls below act on the user's installed release.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'blobs')
Assert-GhozttyPrivateEndpoint -Exe $Exe

# T267: control the window's own size rather than inheriting whatever the last
# GUI script left in window_placement-debug. Nothing here measures pixels, but a
# window restored offscreen by a stale placement cannot be driven either.
# persistence: on (default) - the agent under test only owns sessions when persistence is on.
[void](Start-OnTestDesktop -Exe $Exe -Arguments @(
    '--title=t334-layout-blobs', '--window-width=100', '--window-height=30'))

# ============================================================================
"== A: one startup window mirrors as one record with its session id"
# ============================================================================
$rowsA = Wait-AliveCount $tmp 'a' 1 25
Assert-GhozttyIsolated -Exe $Exe
$aliveA = @(Alive-Ids $rowsA)
Assert "A1 startup pane is agent-backed (one live session)" ($aliveA.Count -eq 1)

# Wait for the record to SETTLE, not merely to exist. The first push can land
# before an agent-backed pane has published its session id (the OPEN reply is
# async; `syncSessionLayout` re-arms a bounded retry until every leaf resolves),
# so a record with no ids yet is an expected intermediate state, not a defect.
$recsA = Wait-Records $tmp 1 25
Assert "A2 the agent holds exactly one layout record" (@($recsA).Count -eq 1)
$keyA0 = (@($recsA) | Select-Object -First 1).key
$recA = Wait-RecordIds $tmp $keyA0 1 25
if ($null -eq $recA -or @($recA.session_ids).Count -ne 1) {
    "  NOTE record did not settle; raw store follows"
    Get-Content (Layouts-Path $tmp) -Raw
}
Assert "A3 the blob decoded as a window with one tab" (
    $null -ne $recA -and $null -ne $recA.win -and @($recA.win.tabs).Count -eq 1)
Assert "A4 the blob's tree is a single leaf" (
    @(Nodes $recA).Count -eq 1 -and $null -ne @(Nodes $recA)[0].leaf)
Assert "A5 the record claims exactly the live session id" (
    $null -ne $recA -and @($recA.session_ids).Count -eq 1 -and
    $recA.session_ids[0] -eq $aliveA[0])
Assert "A6 the leaf carries that same session id" (
    $null -ne $recA -and @(Nodes $recA)[0].leaf.session_id -eq $aliveA[0])
$keyA = if ($null -ne $recA) { $recA.key } else { '' }
Assert "A7 the record is keyed by the window's stable uuid (T338)" (Is-Uuid $keyA)
Assert "A8 that key is the uuid the blob itself records (T338)" (
    $null -ne $recA -and $null -ne $recA.win -and $recA.win.uuid -eq $keyA)

# ============================================================================
"== B: a split UPSERTS the same record (two leaves, two session ids)"
# ============================================================================
Run-Cli '+split --direction=right --name=t334sib' "$tmp\split.txt" 15 | Out-Null
$rowsB = Wait-AliveCount $tmp 'b' 2 20
Assert "B1 the split opened a second agent-backed session" (@(Alive-Ids $rowsB).Count -eq 2)

$recB = Wait-RecordIds $tmp $keyA 2 25
$recsB = Get-Layouts $tmp
Assert "B2 still exactly one record - an upsert, not a second window" (@($recsB).Count -eq 1)
Assert "B3 the record now claims both session ids" (
    $null -ne $recB -and @($recB.session_ids).Count -eq 2)
$nodesB = @(Nodes $recB)
Assert "B4 the blob's tree is a split over two leaves" (
    $nodesB.Count -eq 3 -and $null -ne $nodesB[0].split -and
    $null -ne $nodesB[1].leaf -and $null -ne $nodesB[2].leaf)
Assert "B5 every live session id appears in the record" (
    $null -ne $recB -and
    (@(@(Alive-Ids $rowsB) | Where-Object { $recB.session_ids -contains $_ }).Count -eq 2))

# ============================================================================
"== C: a second window is a second record under its own stable key"
# ============================================================================
Run-Cli '+new-window --target=blob-second' "$tmp\newwin.txt" 20 | Out-Null
Wait-AliveCount $tmp 'c' 3 20 | Out-Null
$recsC = Wait-Records $tmp 2 25
Assert "C1 the agent holds two layout records" (@($recsC).Count -eq 2)
# The record is IDENTIFIED by its blob (the ipc name it carries), not by its
# key: since T338 the key is the window's stable uuid, and keying on anything
# derived per app run is the defect that task fixes.
$recC2 = @($recsC | Where-Object {
        $null -ne $_.win -and $_.win.ipc_name -eq 'blob-second' }) | Select-Object -First 1
Assert "C2 the new window has its own record, found by the ipc name in its blob" (
    $null -ne $recC2)
Assert "C3 that record is keyed by a uuid, NOT by the ipc name (T338)" (
    $null -ne $recC2 -and $recC2.key -ne 'blob-second' -and (Is-Uuid $recC2.key))
Assert "C4 the key is exactly the uuid recorded in the blob (T338)" (
    $null -ne $recC2 -and $recC2.key -eq $recC2.win.uuid)
$recC1 = @($recsC | Where-Object { $_.key -eq $keyA }) | Select-Object -First 1
Assert "C5 the first window's record is still there, still two-leaf" (
    $null -ne $recC1 -and @(Nodes $recC1).Count -eq 3)
Assert "C6 the two windows hold different keys" (
    $null -ne $recC1 -and $null -ne $recC2 -and $recC1.key -ne $recC2.key)

# ============================================================================
"== D: closing that window DELETES its record (the reconcile pass)"
# ============================================================================
Run-Cli '+close --target=blob-second' "$tmp\close.txt" 15 | Out-Null
$recsD = Wait-Records $tmp 1 25
Assert "D1 the agent is back to one layout record" (@($recsD).Count -eq 1)
Assert "D2 the survivor is the first window, not the closed one" (
    (@($recsD) | Select-Object -First 1).key -eq $keyA)

# ============================================================================
"== E: the blobs survive the app exit (quit / crash / upgrade class)"
# ============================================================================
$idsE = @(Alive-Ids (Get-Sessions $tmp 'e0'))
Stop-GuiOnly
$recsE = Get-Layouts $tmp
Assert "E1 the record is still in the store with no viewer running" (@($recsE).Count -eq 1)
$recE = @($recsE) | Select-Object -First 1
Assert "E2 it still names the sessions the agent is keeping alive" (
    $null -ne $recE -and @($recE.session_ids).Count -eq 2 -and
    (@(@($idsE) | Where-Object { $recE.session_ids -contains $_ }).Count -eq 2))

# ============================================================================
"== F: (T338/T194) a relaunch with no local manifest RECOVERS the dead run's window"
# ============================================================================
# The exact case Restore All is for: the app died without writing (or with a
# lost) session-layout manifest, so the only surviving copy of the topology is
# the agent's. Before T338 the blob key was the manifest's per-run window id, so
# the relaunched app's blank startup window UPSERTED the dead run's key inside
# the 250ms layout debounce and the record was gone before anyone could press
# anything.
#
# WHAT F EXPECTS CHANGED WITH T194, and the change is the point: launch-time
# restore now always consults the agent, so the relaunch REBUILDS the dead run's
# window instead of opening a blank one beside it. There is therefore no rival
# window and no third session - one record, still keyed by the same uuid the
# dead run used, which is T338's claim restated on the path that now depends on
# it. session-crash-recover.ps1 is the oracle for the recovery itself; this
# section stays the oracle for the KEY. F6-F8 keep the "a later window takes a
# fresh key" half under test with a window opened after the recovery.
Remove-Item (Join-Path $tmp 'ghoztty\session-layout-debug.json') -Force -ErrorAction SilentlyContinue
Assert "F1 the local manifest really is gone before the relaunch" (
    -not (Test-Path (Join-Path $tmp 'ghoztty\session-layout-debug.json')))

# persistence: on (default) - the agent under test only owns sessions when persistence is on.
[void](Start-OnTestDesktop -Exe $Exe -Arguments @(
    '--title=t338-relaunch', '--window-width=100', '--window-height=30'))

$recsF = Wait-Records $tmp 1 30
Assert "F2 the store holds ONE record - the recovered window, no blank one beside it" (
    @($recsF).Count -eq 1)
$recF1 = @($recsF | Where-Object { $_.key -eq $keyA }) | Select-Object -First 1
Assert "F3 it is still the dead run's key: the recovery ADOPTED the uuid (T338)" (
    $null -ne $recF1)
Assert "F4 it still describes the two-leaf window it always did" (
    $null -ne $recF1 -and @(Nodes $recF1).Count -eq 3)
Assert "F5 it still claims the sessions the agent kept alive - a re-ATTACH" (
    $null -ne $recF1 -and @($recF1.session_ids).Count -eq 2 -and
    (@(@($idsE) | Where-Object { $recF1.session_ids -contains $_ }).Count -eq 2))
$idsF = @(Alive-Ids (Get-Sessions $tmp 'f'))
Assert "F5b no extra session was opened by the recovery" (
    $idsF.Count -eq 2 -and (@(@($idsE) | Where-Object { $idsF -contains $_ }).Count -eq 2))

# The T338 key claim, on a window that really is new: it must take a fresh uuid
# rather than colliding with the recovered run's.
Run-Cli '+new-window --target=blob-after' "$tmp\afterwin.txt" 20 | Out-Null
$recsF2 = Wait-Records $tmp 2 30
Assert "F6 opening a window after the recovery adds a SECOND record" (
    @($recsF2).Count -eq 2)
$recF2 = @($recsF2 | Where-Object { $_.key -ne $keyA }) | Select-Object -First 1
Assert "F7 the new window took a fresh uuid key of its own" (
    $null -ne $recF2 -and (Is-Uuid $recF2.key) -and $recF2.key -ne $keyA)
Assert "F8 the new record claims a session the recovered one does not" (
    $null -ne $recF2 -and @($recF2.session_ids).Count -eq 1 -and
    -not ($idsE -contains $recF2.session_ids[0]))

# ============================================================================
"== cleanup"
Stop-TestProcs
$env:LOCALAPPDATA = $savedLocalAppData
if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
Remove-TestDesktop | Out-Null

if ($script:failures -eq 0) { "ALL PASS"; exit 0 }
else { "$($script:failures) FAILURE(S)"; exit 1 }
