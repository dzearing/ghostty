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
#   C. +new-window --target=blob-second -> a SECOND record, keyed by the ipc
#      name; the first is untouched.
#   D. +close --target=blob-second -> that record is DELETED and the survivor
#      is the first window. This is the close path, with no close hook: the
#      sync's reconcile pass is what removes it.
#   E. hard-kill the GUI (the quit / crash / upgrade class) -> the blobs SURVIVE
#      in the agent. That is the whole point of the store: the machine stays
#      restorable while no viewer is running.
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

$ErrorActionPreference = 'Continue'
$script:failures = 0
$root = Join-Path $env:TEMP "ghoztty-layout-blobs-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

function Stop-TestProcs {
    foreach ($n in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$n'" |
            Where-Object { $_.CommandLine -like '*zig-out*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 700
}

# Kill ONLY the zig-out GUI, leaving the agent running - the app-exit class.
function Stop-GuiOnly {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 900
}

# Run a zig-out ghoztty +command with a hard timeout; stdout+stderr -> $out.
function Run-Cli($argsLine, $out, $timeoutSec = 15) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$out`" 2>&1`""
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

# --- the store under test ----------------------------------------------------

function Layouts-Path($tmp) { Join-Path $tmp 'ghoztty\local-agent-debug\layouts.json' }

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

# T267: control the window's own size rather than inheriting whatever the last
# GUI script left in window_placement-debug. Nothing here measures pixels, but a
# window restored offscreen by a stale placement cannot be driven either.
Start-Process -FilePath $Exe -WindowStyle Minimized -ArgumentList @(
    '--title=t334-layout-blobs', '--window-width=100', '--window-height=30') | Out-Null

# ============================================================================
"== A: one startup window mirrors as one record with its session id"
# ============================================================================
$rowsA = Wait-AliveCount $tmp 'a' 1 25
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
"== C: a second window is a second record, keyed by its ipc name"
# ============================================================================
Run-Cli '+new-window --target=blob-second' "$tmp\newwin.txt" 20 | Out-Null
Wait-AliveCount $tmp 'c' 3 20 | Out-Null
$recsC = Wait-Records $tmp 2 25
Assert "C1 the agent holds two layout records" (@($recsC).Count -eq 2)
$recC2 = @($recsC | Where-Object { $_.key -eq 'blob-second' }) | Select-Object -First 1
Assert "C2 the new record is keyed by the ipc name" ($null -ne $recC2)
Assert "C3 the new record's blob carries that ipc name" (
    $null -ne $recC2 -and $null -ne $recC2.win -and $recC2.win.ipc_name -eq 'blob-second')
$recC1 = @($recsC | Where-Object { $_.key -eq $keyA }) | Select-Object -First 1
Assert "C4 the first window's record is still there, still two-leaf" (
    $null -ne $recC1 -and @(Nodes $recC1).Count -eq 3)

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
"== cleanup"
Stop-TestProcs
$env:LOCALAPPDATA = $savedLocalAppData
if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue

if ($script:failures -eq 0) { "ALL PASS"; exit 0 }
else { "$($script:failures) FAILURE(S)"; exit 1 }
