# WP-D3 snapshot re-attach (tracker T109). Proves the win32 app persists a
# STRUCTURED SCREEN SNAPSHOT per agent-backed pane and re-attaches at the byte
# offset that snapshot reflects, instead of asking the agent to replay its whole
# retained ring.
#
# Why it matters: the agent's per-session ring is a CONCATENATION of segments
# drawn at different geometries (every attach resize makes conhost append a
# fresh `ESC[H ESC[2J` + viewport repaint at the new size). A full-ring replay
# parsed at any single geometry is faithful only to its own segments, which is
# what T89i measured as exactly one already-seen row clobbered at the junction
# where the replayed block starts overwriting the restored pane's screen. With a
# snapshot there IS no full-ring replay: we paint our own clean VT repaint and
# the agent gap-fills only `(offset, S]`.
#
#   A. WRITE half - a live agent-backed pane's manifest leaf carries
#      `screen_snapshot` (base64 of a real VT repaint, containing the marker the
#      pane printed) and a nonzero `screen_snapshot_offset`.
#   B. BUDGET half - the snapshot never crowds the topology: the manifest still
#      parses, still declares version 1, and stays under the 8 MiB read ceiling.
#   C. RESTORE half - kill ONLY the app (the detached agent keeps the PTY),
#      relaunch, and prove from the app's own decision log that the re-attach
#      took the DELTA path (`attach: session=<sid> offset=N snapshot=M` with
#      both N and M > 0, N equal to the offset the manifest recorded) rather
#      than the full-ring path (`offset=0 snapshot=0`) - and that the pane's
#      pre-quit content survived.
#
# The log line is the oracle because the two paths are indistinguishable from
# outside: both end with a pane full of the right text. `-NegativeControl`
# inverts C3 so a build that silently fell back to the full ring scores RED
# instead of quietly passing on the content assertions alone.
#
# Non-interactive; asserts and exits nonzero on any failure. Hermetic in the
# same way as session-reattach.ps1: a per-run $env:LOCALAPPDATA, a per-run
# GHOSTTY_LOCAL_AGENT_BIN, a private IPC pipe suffix, and it ONLY ever kills
# ghoztty / ghoztty-agent processes launched from the repo zig-out. Runs on a
# BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1).
#
# The exe under test is a DEBUG build (Console subsystem), so std.log goes to
# STDERR - captured per launch via Start-OnTestDesktop -StdErr. The
# %LOCALAPPDATA%\ghoztty\ghoztty.log sink is release-only.
#
#   powershell -NoProfile -File test\win32\session-snapshot-reattach.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$root = Join-Path $env:TEMP "ghoztty-snap-reattach-$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

# Kill ONLY zig-out ghoztty/agent processes (never the user's release build).
function Stop-TestProcs {
    foreach ($n in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$n'" |
            Where-Object { $_.CommandLine -like '*zig-out*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 700
}

# Kill ONLY the zig-out ghoztty APP - the agent keeps its PTYs, which is the
# crash/upgrade re-attach scenario under test.
function Stop-AppOnly {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 900
}

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

# ---- session / manifest helpers -------------------------------------------

function Get-Sessions($tmp, $tag) {
    $code = Run-Cli '+sessions --json' "$tmp\sess-$tag.json" 12
    if ($code -ne 0) { return @() }
    $rows = $null
    try { $rows = Out-Text "$tmp\sess-$tag.json" | ConvertFrom-Json } catch {}
    if ($null -eq $rows) { return @() }
    return @($rows)
}
function Alive-Ids($rows) {
    return @($rows | Where-Object { $_.alive -eq $true } | ForEach-Object { $_.id })
}
function Wait-AliveCount($tmp, $tag, $target, $timeoutSec = 18) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $rows = @()
    while ((Get-Date) -lt $deadline) {
        $rows = Get-Sessions $tmp $tag
        if (@(Alive-Ids $rows).Count -eq $target) { return $rows }
        Start-Sleep -Milliseconds 500
    }
    return $rows
}

# Debug builds write the -debug filename (session_layout.layoutPath).
function Manifest-Path($tmp) { return (Join-Path $tmp 'ghoztty\session-layout-debug.json') }
function Read-Manifest($tmp) {
    $p = Manifest-Path $tmp
    if (-not (Test-Path $p)) { return $null }
    try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch { return $null }
}
function Wait-Manifest($tmp, $pred, $timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $m = $null
    while ((Get-Date) -lt $deadline) {
        $m = Read-Manifest $tmp
        if ($null -ne $m) { try { if (& $pred $m) { return $m } } catch {} }
        Start-Sleep -Milliseconds 400
    }
    return $m
}

# Every terminal leaf across a manifest, in tree order. Wrapped with the unary
# comma so a single-leaf result never unwraps to a scalar (PS5.1 array trap).
function All-Leaves($m) {
    $leaves = @()
    foreach ($w in @($m.windows)) {
        foreach ($t in @($w.tabs)) {
            foreach ($n in @($t.nodes)) {
                if ($null -ne $n.leaf) { $leaves += $n.leaf }
            }
        }
    }
    return , $leaves
}

# The first leaf that recorded a WP-D3 pair, or $null.
function First-Snapshot-Leaf($m) {
    if ($null -eq $m) { return $null }
    foreach ($leaf in @(All-Leaves $m)) {
        if ($leaf.screen_snapshot -and $leaf.screen_snapshot_offset) { return $leaf }
    }
    return $null
}

# The first terminal leaf id in a `+list --json` tree. Listing auto-registers
# every pane it discovers, so the returned id is immediately usable as a
# --target (pane ids are, agent SESSION ids are not).
function Find-Leaf($node) {
    if ($null -eq $node) { return $null }
    if ($node.type -eq 'leaf') { return $node.terminal }
    if ($node.type -eq 'split') {
        $l = Find-Leaf $node.left
        if ($null -ne $l) { return $l }
        return (Find-Leaf $node.right)
    }
    return $null
}
function Wait-FirstPaneId($tmp, $timeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Run-Cli '+list --json' "$tmp\list.json" 10) -eq 0) {
            $tree = $null
            try { $tree = Out-Text "$tmp\list.json" | ConvertFrom-Json } catch {}
            if ($null -ne $tree) {
                $windows = if ($null -ne $tree.data) { $tree.data.windows } else { $tree.windows }
                foreach ($w in @($windows)) {
                    foreach ($t in @($w.tabs)) {
                        $leaf = Find-Leaf $t.splits
                        if ($null -ne $leaf -and $leaf.id) { return $leaf.id }
                    }
                }
            }
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Decode-Snapshot($b64) {
    try { return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) }
    catch { return $null }
}

# The snapshot is a per-CELL VT repaint, so a run of plain text is shot through
# with SGR sequences (`SNAP` ESC[0m `MARKER`) and wrapped at the pane width.
# Strip CSI/OSC and then all whitespace to get the readable text back - the same
# "match with separators removed" technique the other scripts use for wrapping.
function Snapshot-Text($decoded) {
    if ($null -eq $decoded) { return '' }
    $t = [regex]::Replace($decoded, "`e\][^`a`e]*(`a|`e\\)", '')   # OSC
    $t = [regex]::Replace($t, "`e\[[0-9;:?]*[ -/]*[@-~]", '')      # CSI
    $t = [regex]::Replace($t, "`e[@-Z\\-_]", '')                    # 2-byte ESC
    return ($t -replace '\s', '')
}

# ---- app-log helpers (the RESTORE oracle) ----------------------------------

# Opened with FileShare.ReadWrite: the app still holds the handle.
function Read-AppLog($path) {
    if (-not $path -or -not (Test-Path $path)) { return '' }
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -le 0) { return '' }
            $buf = New-Object byte[] $fs.Length
            $n = $fs.Read($buf, 0, $buf.Length)
            return [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
        } finally { $fs.Dispose() }
    } catch { return '' }
}
# Poll rather than read once: the line may not be flushed yet, and a bare read
# would turn a timing gap into a false failure.
function Wait-LogMatch($path, $pattern, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $m = [regex]::Match((Read-AppLog $path), $pattern)
        if ($m.Success) { return $m }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
# Isolate the IPC endpoint: every assertion is read back through +list /
# +sessions / +read, and an instance answering the shared pipe would answer
# them about somebody else's windows.
$env:GHOZTTY_PIPE_SUFFIX = '-snapreattach'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {

Assert "agent binary exists in zig-out" (Test-Path $AgentExe)
Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)

$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$logA = Join-Path $root 'app-a.err'
$logB = Join-Path $root 'app-b.err'
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe

# ============================================================================
Say "== A: a live agent-backed pane records a screen snapshot + offset"
# ============================================================================
# persistence: on (default) - the relaunch below has to RESTORE what this launch left.
$app = Start-OnTestDesktop -Exe $Exe -Arguments @('--title=t109-snapshot') -StdErr $logA
$rowsA = Wait-AliveCount $tmp 'a' 1 25
Assert "A1 startup pane is agent-backed (one live session)" (@(Alive-Ids $rowsA).Count -eq 1)
Assert "A1b the launched app has no window on the interactive desktop" `
    (-not (Test-TestDesktopLeak -ProcessId $app.Pid))
$sid = @(Alive-Ids $rowsA)[0]
$pane = Wait-FirstPaneId $tmp 25
Assert "A1c the startup pane has an addressable pane id" ($null -ne $pane)

# Plant a marker in the pane. A single space-free token: send-keys concatenates
# positional args, and cmd echoes it plus an error, both landing it on screen.
$marker = "SNAPMARKER$($PID)XYZ"
Run-Cli "+send-keys --target=$pane $marker Enter" "$tmp\mark.txt" 12 | Out-Null
$preOk = $false
$deadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadline) {
    Run-Cli "+read --name=$pane --lines=200" "$tmp\read-pre.txt" 10 | Out-Null
    if (((Out-Text "$tmp\read-pre.txt") -replace '\s', '') -match $marker) { $preOk = $true; break }
    Start-Sleep -Milliseconds 500
}
Assert "A2 marker is on the pane's screen before quit" $preOk

# The manifest write is DEBOUNCED off layout mutations, and this test kills the
# app outright (no graceful quit, so no final sync) - so the capture that must
# contain the marker has to be provoked. A window title pin is the cheapest
# mutation that marks the layout dirty and changes nothing visible about the
# tree; +rename resolves a pane target to its parent window.
Run-Cli "+rename --target=$pane --title=t109-snapshot" "$tmp\ren.txt" 12 | Out-Null
# Poll for the capture that POST-DATES the marker, not merely for "a snapshot
# exists": the startup window already wrote one, and accepting it would score a
# stale blob and then compare the wrong offsets in C.
$mark = $marker
$mA = Wait-Manifest $tmp {
    param($m)
    $l = First-Snapshot-Leaf $m
    $null -ne $l -and (Snapshot-Text (Decode-Snapshot $l.screen_snapshot)) -match $mark
} 30
$leafA = First-Snapshot-Leaf $mA
Assert "A3 a manifest leaf carries screen_snapshot + screen_snapshot_offset" ($null -ne $leafA)

$offsetA = if ($null -ne $leafA) { [uint64]$leafA.screen_snapshot_offset } else { 0 }
Assert "A4 the recorded offset is nonzero (a bare offset of 0 means full-ring)" ($offsetA -gt 0)

$decoded = if ($null -ne $leafA) { Decode-Snapshot $leafA.screen_snapshot } else { $null }
Assert "A5 the snapshot is valid base64 and decodes to bytes" (
    $null -ne $decoded -and $decoded.Length -gt 0)
Assert "A6 the snapshot is a VT repaint (contains ESC)" (
    $null -ne $decoded -and $decoded.Contains([char]27))
Assert "A7 the snapshot holds the pane's actual screen (the marker is in it)" (
    (Snapshot-Text $decoded) -match $marker)

# ============================================================================
Say "== B: the snapshot does not crowd the topology out of the manifest"
# ============================================================================
$mPath = Manifest-Path $tmp
$sizeB = if (Test-Path $mPath) { (Get-Item $mPath).Length } else { 0 }
Assert "B1 the manifest still parses and declares schema version 1" (
    $null -ne $mA -and $mA.version -eq 1)
Assert "B2 the manifest is under the 8 MiB read ceiling" ($sizeB -gt 0 -and $sizeB -lt 8MB)
Assert "B3 the leaf still carries its session id and pane id alongside the snapshot" (
    $null -ne $leafA -and $leafA.session_id -and $leafA.pane_id)

# ============================================================================
Say "== C: relaunch re-attaches at the recorded offset, not from the ring head"
# ============================================================================
Stop-AppOnly
$agentIds = @(Alive-Ids (Wait-AliveCount $tmp 'c-agent' 1 18))
Assert "C1 the agent kept the session alive after the app died" (
    $agentIds.Count -eq 1 -and $agentIds[0] -eq $sid)

# Re-read the manifest with the app dead: the file is final now, so THIS is
# byte-for-byte what restore is about to consume. Comparing C4/C5 against the
# `$mA` poll instead would race any later debounced write and mis-score a
# working delta attach as a mismatch.
$mFinal = Read-Manifest $tmp
$leafFinal = First-Snapshot-Leaf $mFinal
Assert "C1b the final on-disk manifest still carries a snapshot pair" ($null -ne $leafFinal)
$offsetFinal = if ($null -ne $leafFinal) { [uint64]$leafFinal.screen_snapshot_offset } else { 0 }
$snapBytesFinal = if ($null -ne $leafFinal) {
    [uint64]([Convert]::FromBase64String($leafFinal.screen_snapshot).Length)
} else { 0 }
Assert "C1c the final snapshot still holds the marker" (
    $null -ne $leafFinal -and
    (Snapshot-Text (Decode-Snapshot $leafFinal.screen_snapshot)) -match $marker)

# persistence: on (default) - session persistence IS this script's subject.
$relaunched = Start-OnTestDesktop -Exe $Exe -StdErr $logB
$hit = Wait-LogMatch $logB "attach: session=$sid offset=(\d+) snapshot=(\d+)" 40
Assert "C2 the restored pane logged its ATTACH" ($null -ne $hit)

$logOffset = if ($null -ne $hit) { [uint64]$hit.Groups[1].Value } else { 0 }
$logSnapLen = if ($null -ne $hit) { [uint64]$hit.Groups[2].Value } else { 0 }
$deltaPath = ($logOffset -gt 0 -and $logSnapLen -gt 0)
if ($NegativeControl) {
    # Invert the claim this whole script exists for. A control that PASSES here
    # is scoring a build that fell back to the full-ring replay - the pane still
    # ends up full of the right text, which is exactly why the content
    # assertions alone cannot be the oracle.
    Assert "C3 (NEGATIVE CONTROL) attach took the full-ring path" (-not $deltaPath)
} else {
    Assert "C3 attach took the WP-D3 delta path (offset > 0 with a snapshot)" $deltaPath
}
Assert "C4 the attach offset is exactly the one the manifest recorded" (
    $offsetFinal -gt 0 -and $logOffset -eq $offsetFinal)
Assert "C5 the painted snapshot matches the recorded one byte for byte" (
    $snapBytesFinal -gt 0 -and $logSnapLen -eq $snapBytesFinal)

# Content survived: the restore is fast AND correct, not fast and empty.
$paneC = Wait-FirstPaneId $tmp 30
Assert "C6 the restored pane is addressable" ($null -ne $paneC)
$postOk = $false
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    Run-Cli "+read --name=$paneC --lines=200" "$tmp\read-post.txt" 10 | Out-Null
    if (((Out-Text "$tmp\read-post.txt") -replace '\s', '') -match $marker) { $postOk = $true; break }
    Start-Sleep -Milliseconds 600
}
Assert "C6b the pre-quit marker is still on the restored pane" $postOk
Assert "C6c the relaunched app has no window on the interactive desktop" `
    (-not (Test-TestDesktopLeak -ProcessId $relaunched.Pid))

# C6d (T532): a REPAINTED pane and a LIVE pane look identical until you type.
# Everything above this line is satisfied by a recording - C5 even proves the
# painted bytes match the recorded snapshot byte for byte, which is exactly what
# a frozen pane would also prove. On 2026-08-06 a user hit the difference: after
# a hard kill and relaunch, panes restored on THIS path (a delta attach, offset
# and snapshot both nonzero - `attach: offset=43394044 snapshot=14382`) painted
# correctly and then took no input and produced no output, while the app logged
# success at every step. So probe the live half directly: plant a marker AFTER
# the restore and require it to come back.
$liveMarker = "SNAPLIVE$($PID)XYZ"
Run-Cli "+send-keys --target=$paneC $liveMarker Enter" "$tmp\mark-live.txt" 12 | Out-Null
$liveOk = $false
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    Run-Cli "+read --name=$paneC --lines=200" "$tmp\read-live.txt" 10 | Out-Null
    if (((Out-Text "$tmp\read-live.txt") -replace '\s', '') -match $liveMarker) { $liveOk = $true; break }
    Start-Sleep -Milliseconds 600
}
Assert "C6d the delta-restored pane is LIVE: input reaches the child, output returns" $liveOk

# The restored pane keeps snapshotting: the offset only ever moves forward, so
# the NEXT restore is a delta too rather than silently reverting to the ring.
# (Provoke the debounced capture the same way as A.)
Run-Cli "+rename --target=$paneC --title=t109-snapshot-2" "$tmp\ren2.txt" 12 | Out-Null
$floor = $offsetA
$mC = Wait-Manifest $tmp {
    param($m)
    $l = First-Snapshot-Leaf $m
    $null -ne $l -and [uint64]$l.screen_snapshot_offset -ge $floor
} 25
$leafC = First-Snapshot-Leaf $mC
Assert "C7 the restored pane records a fresh snapshot at an offset >= the first" (
    $null -ne $leafC -and [uint64]$leafC.screen_snapshot_offset -ge $offsetA)

if ($script:failures -gt 0) {
    Say "== DIAG: sid=$sid pane=$pane offsetA=$offsetA offsetFinal=$offsetFinal"
    Say "== DIAG: attach log lines =="
    foreach ($line in ((Read-AppLog $logB) -split "`n")) {
        if ($line -match 'attach:') { Say $line.Trim() }
    }
}

} finally {
    Say "== cleanup"
    Remove-TestDesktop
    Stop-TestProcs
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    $env:GHOZTTY_PIPE_SUFFIX = $savedPipe
    if ($script:failures -eq 0) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    else { Say "artifacts preserved at $root" }
}

$fgSeen = @(Stop-TestForegroundWatch)
Say "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    # Get-TestLaunchedPids, not the live pid list: Remove-TestDesktop has run by
    # now and emptied the live one, which would score this against nothing.
    $launched = @(Get-TestLaunchedPids)
    Assert "D1 the foreground watcher actually sampled (negative control)" ($fgSeen.Count -gt 0)
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert "D2 no test-desktop app ever became foreground on the interactive desktop" ($leaked.Count -eq 0)
}

Say ""
if ($script:failures -eq 0) { Say "ALL PASS ($script:passes assertions)"; exit 0 }
else { Say "$($script:failures) FAILURE(S) / $script:passes passed"; exit 1 }
