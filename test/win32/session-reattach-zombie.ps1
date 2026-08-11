# T532 - a restored pane must be LIVE, never a photograph of one.
#
# WHY THIS SCRIPT EXISTS
#
# On 2026-08-06 a user hard-killed the app, relaunched, and got windows that
# painted perfectly and were dead: typing did nothing, no new output ever
# arrived, and the app logged success at every step. Two existing scripts
# already kill the app the same way and probe liveness afterwards
# (session-reattach.ps1 F8b, session-snapshot-reattach.ps1 C6d) and both restore
# live - so the freeze needed a variable neither of them had. This script owns
# the two that were run down, and the second one is the bug.
#
# WHAT IT DOES
#
#   A-C: the ALTERNATE SCREEN. The incident's panes were a TUI, and an
#   alt-screen session takes a genuinely different branch of the agent's ATTACH,
#
#       const skip_replay = want_snapshot and s.gridOnAltScreen();  server.zig
#
#   where the raw ring replay is SUPPRESSED and the grid snapshot stands alone.
#   Every other persistence fixture runs cmd.exe on the primary screen, so that
#   branch was unexecuted code on the one journey a user actually took. Here a
#   `-e` fixture enters the alternate screen and echoes every line it reads:
#
#     A. Prove it IS on the alt screen (the manifest snapshot carries `?1049h`,
#        which the formatter emits only for a differing mode) and that it is
#        interactive BEFORE the kill - the positive control, without which a
#        dead pane afterwards proves only that the fixture never worked.
#     B. Hard-kill ONLY the app (Stop-Process -Force, the shape the upgrade
#        script uses). The agent keeps the ConPTY.
#     C. Relaunch, confirm the delta attach in the app's own log, confirm the
#        pre-kill screen came back - and then TYPE. The fixture answers
#        `ALTECHO<token>`, which nothing but the live child can produce: ConPTY
#        echoes the typed token itself, so matching the bare token would score a
#        frozen pane as live. (This restores live at HEAD and did before the
#        fix too - the alt screen was eliminated as the cause, not confirmed.)
#
#   D: the STALE RESUME POINT - the actual root cause. The client arms its
#   section-7.3 discard watermark from the offset its own manifest recorded,
#   and used to never compare it against the agent's stream head. A session id outlives its
#   byte stream (an agent restart relaunches the session under the same id with
#   a fresh stream at 0), so a manifest written before that restart records an
#   offset in a stream that no longer exists. Arming it discards every byte the
#   agent will ever send - its grid snapshot included - forever, while the pane
#   still paints (the viewer replays its OWN persisted snapshot) and input still
#   reaches the child. That is the report word for word: "repaint correctly but
#   non interactive, not painting, but seemed to still be working."
#
#   Section D reproduces it exactly, by rewriting the recorded offset in the
#   on-disk manifest to a phantom 43394044 - the incident's own number - while
#   the app is dead, then relaunching. Before the fix the pane comes back
#   painted and frozen; after it, the client clamps its resume point to the
#   agent's head, says so in the log, and the pane is live.
#
# Non-interactive; exits nonzero on any failure. Hermetic exactly like its two
# neighbours: a per-run %LOCALAPPDATA%, a per-run GHOSTTY_LOCAL_AGENT_BIN, a
# private IPC pipe suffix, and it only ever kills ghoztty / ghoztty-agent
# processes launched from the repo zig-out. Runs on a BACKGROUND Win32 desktop.
#
#   powershell -NoProfile -File test\win32\session-reattach-zombie.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$root = Join-Path $env:TEMP "ghoztty-alt-reattach-$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')

function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

function Stop-TestProcs {
    foreach ($n in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$n'" |
            Where-Object { $_.CommandLine -like '*zig-out*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 700
}

# Kill ONLY the app. The agent keeps its ConPTYs - that is the whole scenario.
function Stop-AppOnly {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 900
}

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
function Wait-AliveCount($tmp, $tag, $target, $timeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $rows = @()
    while ((Get-Date) -lt $deadline) {
        $rows = Get-Sessions $tmp $tag
        if (@(Alive-Ids $rows).Count -eq $target) { return $rows }
        Start-Sleep -Milliseconds 500
    }
    return $rows
}

function Manifest-Path($tmp) { return (Join-Path $tmp 'ghoztty\session-layout-debug.json') }
function Read-Manifest($tmp) {
    $p = Manifest-Path $tmp
    if (-not (Test-Path $p)) { return $null }
    try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch { return $null }
}
function Wait-Manifest($tmp, $pred, $timeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $m = $null
    while ((Get-Date) -lt $deadline) {
        $m = Read-Manifest $tmp
        if ($null -ne $m) { try { if (& $pred $m) { return $m } } catch {} }
        Start-Sleep -Milliseconds 400
    }
    return $m
}
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
function First-Snapshot-Leaf($m) {
    if ($null -eq $m) { return $null }
    foreach ($leaf in @(All-Leaves $m)) {
        if ($leaf.screen_snapshot -and $leaf.screen_snapshot_offset) { return $leaf }
    }
    return $null
}
function Decode-Snapshot($b64) {
    try { return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) }
    catch { return $null }
}
# Strip CSI/OSC/2-byte-ESC and all whitespace: a per-cell VT repaint shoots SGR
# runs through the text and wraps it at the pane width.
function Snapshot-Text($decoded) {
    if ($null -eq $decoded) { return '' }
    $t = [regex]::Replace($decoded, "`e\][^`a`e]*(`a|`e\\)", '')
    $t = [regex]::Replace($t, "`e\[[0-9;:?]*[ -/]*[@-~]", '')
    $t = [regex]::Replace($t, "`e[@-Z\\-_]", '')
    return ($t -replace '\s', '')
}

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
function Wait-FirstPaneId($tmp, $timeoutSec = 30) {
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

# Poll `+read` until $pattern shows up in the pane's visible screen (an
# alt-screen pane reads back the visible frame - T193). Returns $true on a hit.
function Wait-PaneText($tmp, $pane, $pattern, $tag, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        Run-Cli "+read --name=$pane --lines=200" "$tmp\read-$tag.txt" 10 | Out-Null
        if (((Out-Text "$tmp\read-$tag.txt") -replace '\s', '') -match $pattern) { return $true }
        Start-Sleep -Milliseconds 600
    }
    return $false
}

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
function Wait-LogMatch($path, $pattern, $timeoutSec = 40) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $m = [regex]::Match((Read-AppLog $path), $pattern)
        if ($m.Success) { return $m }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

Assert-GhozttyIsolatedBuild -Exe $Exe

Stop-TestProcs
New-Item -ItemType Directory -Force $root | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = '-altreattach'

# ---- the fixture that lives on the alternate screen -------------------------
#
# It enables ENABLE_VIRTUAL_TERMINAL_PROCESSING explicitly rather than trusting
# the ConPTY default: without it the `?1049h` would be printed as text instead
# of switching buffers, and the whole experiment would silently re-test the
# primary screen again while every assertion still passed.
$fixture = Join-Path $root 'altpane.ps1'
$fixtureText = @'
$ErrorActionPreference = 'Continue'
Add-Type -Namespace T532 -Name Con -MemberDefinition @"
[DllImport("kernel32.dll", SetLastError=true)]
public static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool GetConsoleMode(IntPtr h, out uint m);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool SetConsoleMode(IntPtr h, uint m);
"@
$h = [T532.Con]::GetStdHandle(-11)
$mode = 0
if ([T532.Con]::GetConsoleMode($h, [ref]$mode)) {
    [void][T532.Con]::SetConsoleMode($h, $mode -bor 4)
}
$esc = [string][char]27
[Console]::Out.Write($esc + '[?1049h' + $esc + '[2J' + $esc + '[H')
[Console]::Out.Write("ALTPANEREADY`r`n")
[Console]::Out.Flush()
while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    $line = $line.Trim()
    if ($line -eq 'ALTQUIT') { break }
    if ($line.Length -gt 0) {
        [Console]::Out.Write("ALTECHO<" + $line + ">`r`n")
        [Console]::Out.Flush()
    }
}
[Console]::Out.Write($esc + '[?1049l')
'@
Set-Content -LiteralPath $fixture -Value $fixtureText -Encoding ASCII

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {

Assert "agent binary exists in zig-out" (Test-Path $AgentExe)
Assert "ghoztty exe exists in zig-out" (Test-Path $Exe)

$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$logA = Join-Path $root 'app-a.err'
$logB = Join-Path $root 'app-b.err'
$logC = Join-Path $root 'app-c.err'
$paneD = $null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe

# ============================================================================
Say "== A: an alt-screen pane is agent-backed, on the alt screen, and interactive"
# ============================================================================
# persistence: on (default) - the relaunch below has to RESTORE what this launch left.
$app = Start-OnTestDesktop -Exe $Exe -StdErr $logA -Arguments @(
    '--title=t532-alt', '-e', 'powershell', '-NoProfile', '-File', $fixture)
$rowsA = Wait-AliveCount $tmp 'a' 1 40
Assert "A1 the -e pane is agent-backed (one live session)" (@(Alive-Ids $rowsA).Count -eq 1)
$sid = if (@(Alive-Ids $rowsA).Count -ge 1) { @(Alive-Ids $rowsA)[0] } else { $null }

$pane = Wait-FirstPaneId $tmp 30
Assert "A2 the pane is addressable" ($null -ne $pane)

Assert "A3 the fixture reached the alternate screen and printed its marker" (
    $null -ne $pane -and (Wait-PaneText $tmp $pane 'ALTPANEREADY' 'ready' 45))

# The positive control. Without it, a dead pane in C proves only that the
# fixture never worked - which is a bug in this script, not in the product.
$preToken = "ALTPRE$($PID)X"
Run-Cli "+send-keys --target=$pane $preToken Enter" "$tmp\send-pre.txt" 12 | Out-Null
Assert "A4 the pane is LIVE before the kill (fixture echoes what was typed)" (
    $null -ne $pane -and (Wait-PaneText $tmp $pane "ALTECHO<$preToken>" 'pre' 30))

# Provoke the debounced manifest capture (a title pin is the cheapest layout
# mutation), and wait for the capture that POST-DATES the echo above.
Run-Cli "+rename --target=$pane --title=t532-alt" "$tmp\ren.txt" 12 | Out-Null
$want = $preToken
$mA = Wait-Manifest $tmp {
    param($m)
    $l = First-Snapshot-Leaf $m
    $null -ne $l -and (Snapshot-Text (Decode-Snapshot $l.screen_snapshot)) -match $want
} 35
$leafA = First-Snapshot-Leaf $mA
Assert "A5 a manifest leaf carries a screen snapshot holding the pane's screen" (
    $null -ne $leafA)

$decodedA = if ($null -ne $leafA) { Decode-Snapshot $leafA.screen_snapshot } else { $null }
# THE variable under test. `?1049h` is emitted by the snapshot formatter only
# for a DIFFERING mode, so its presence is the proof that this session drives
# the agent's `skip_replay` branch - the one no other fixture reaches.
Assert "A6 the pane really is on the ALTERNATE screen (snapshot carries ?1049h)" (
    $null -ne $decodedA -and $decodedA.Contains('?1049h'))

$offsetA = if ($null -ne $leafA) { [uint64]$leafA.screen_snapshot_offset } else { 0 }
Assert "A7 the recorded offset is nonzero (a 0 offset would mean full-ring)" ($offsetA -gt 0)

# ============================================================================
Say "== B: hard-kill the app; the agent keeps the alt-screen ConPTY"
# ============================================================================
Stop-AppOnly
$agentIds = @(Alive-Ids (Wait-AliveCount $tmp 'b' 1 20))
Assert "B1 the agent kept the alt-screen session alive after the app died" (
    $agentIds.Count -eq 1 -and $null -ne $sid -and $agentIds[0] -eq $sid)

$mFinal = Read-Manifest $tmp
$leafFinal = First-Snapshot-Leaf $mFinal
Assert "B2 the final on-disk manifest still carries the alt-screen snapshot" (
    $null -ne $leafFinal -and
    (Decode-Snapshot $leafFinal.screen_snapshot).Contains('?1049h'))
$offsetFinal = if ($null -ne $leafFinal) { [uint64]$leafFinal.screen_snapshot_offset } else { 0 }

# ============================================================================
Say "== C: relaunch - the restored alt-screen pane must be LIVE, not a picture"
# ============================================================================
# persistence: on (default) - session persistence IS this script's subject.
$relaunched = Start-OnTestDesktop -Exe $Exe -StdErr $logB
$hit = Wait-LogMatch $logB "attach: session=$sid offset=(\d+) snapshot=(\d+)" 45
Assert "C1 the restored pane logged its ATTACH" ($null -ne $hit)
$logOffset = if ($null -ne $hit) { [uint64]$hit.Groups[1].Value } else { 0 }
$logSnapLen = if ($null -ne $hit) { [uint64]$hit.Groups[2].Value } else { 0 }
Assert "C2 attach took the delta path (offset > 0 with a snapshot)" (
    $logOffset -gt 0 -and $logSnapLen -gt 0)
Assert "C3 the attach offset is the one the manifest recorded" (
    $offsetFinal -gt 0 -and $logOffset -eq $offsetFinal)

$paneC = Wait-FirstPaneId $tmp 35
Assert "C4 the restored pane is addressable" ($null -ne $paneC)
Assert "C5 the pre-kill alt screen came back (the echo from A4 is on it)" (
    $null -ne $paneC -and (Wait-PaneText $tmp $paneC "ALTECHO<$preToken>" 'post' 35))

# C6 is the point of the whole script. Everything above is satisfied by a
# photograph: C5 in particular proves the restored pane shows the right pixels,
# which is exactly what the user saw on 2026-08-06 before discovering it was
# dead. Type into it and require the CHILD's answer back.
$liveToken = "ALTLIVE$($PID)X"
Run-Cli "+send-keys --target=$paneC $liveToken Enter" "$tmp\send-live.txt" 12 | Out-Null
Assert "C6 the restored ALT-SCREEN pane is LIVE: input reaches the child, output returns" (
    $null -ne $paneC -and (Wait-PaneText $tmp $paneC "ALTECHO<$liveToken>" 'live' 40))

Assert "C7 the relaunched app has no window on the interactive desktop" (
    -not (Test-TestDesktopLeak -ProcessId $relaunched.Pid))

# ============================================================================
Say "== D: a STALE resume point (the root cause) must not freeze the pane"
# ============================================================================
# Reproduce the incident's mechanism directly. A session id outlives its byte
# stream, so a manifest can record an offset in a stream that no longer exists;
# the incident's was 43394044. Write that number into the manifest while the app
# is dead and relaunch: the ATTACH then claims to have applied 43 MB of a stream
# the agent has produced a few KB of.
Stop-AppOnly
$phantom = 43394044
$mStale = Read-Manifest $tmp
Assert "D1 there is a manifest to age" ($null -ne $mStale)
$aged = 0
foreach ($w in @($mStale.windows)) {
    foreach ($t in @($w.tabs)) {
        foreach ($n in @($t.nodes)) {
            if ($null -ne $n.leaf -and $n.leaf.screen_snapshot_offset) {
                $n.leaf.screen_snapshot_offset = $phantom
                $aged++
            }
        }
    }
}
Assert "D2 at least one leaf's recorded offset was aged into a dead stream" ($aged -ge 1)
# Two write details, both load-bearing, and both first observed as a manifest
# the app rejected with `session-restore: manifest load failed
# err=error.SyntaxError` - after which it recovered the window from the AGENT
# instead and every liveness assertion below passed against a pane the repro
# never touched:
#   - `-Depth` (the default of 2 flattens the nested tree into type names), and
#   - a BOM-less UTF-8 write. PS 5.1's `Set-Content -Encoding UTF8` writes a
#     BOM, and the app's JSON parser reads it as a syntax error.
$json = $mStale | ConvertTo-Json -Depth 40 -Compress
[System.IO.File]::WriteAllText(
    (Manifest-Path $tmp), $json, (New-Object System.Text.UTF8Encoding $false))

# persistence: on (default) - session persistence IS this script's subject.
$relaunched2 = Start-OnTestDesktop -Exe $Exe -StdErr $logC
$hit2 = Wait-LogMatch $logC "attach: session=$sid offset=$phantom " 45
Assert "D3 the app attached with the phantom offset (the repro took)" ($null -ne $hit2)
# The other half of "the repro took". A manifest the app REJECTS is silently
# routed around - it recovers the window from the agent instead, on a fresh
# offset-0 attach - and every liveness assertion below then passes against a
# pane the repro never touched. That is not a hypothetical: it is what the
# first run of this section did.
$mangled = [regex]::Match((Read-AppLog $logC), 'manifest load failed')
Assert "D4 the aged manifest was CONSUMED, not rejected as malformed" (-not $mangled.Success)
$reproTook = ($null -ne $hit2) -and (-not $mangled.Success)

# The fix's own voice: a client that clamps must say it clamped, or the next
# person debugging this has the same nothing-in-the-log the incident had.
Assert "D5 the app reports the stale resume point instead of swallowing it" (
    $reproTook -and $null -ne (Wait-LogMatch $logC "ahead of the agent's stream head" 30))

$paneD = Wait-FirstPaneId $tmp 35
Assert "D6 the pane restored from a stale manifest is addressable" ($null -ne $paneD)
$staleToken = "ALTSTALE$($PID)X"
Run-Cli "+send-keys --target=$paneD $staleToken Enter" "$tmp\send-stale.txt" 12 | Out-Null
Assert "D7 the pane restored from a STALE offset is LIVE, not a frozen picture" (
    $reproTook -and $null -ne $paneD -and
    (Wait-PaneText $tmp $paneD "ALTECHO<$staleToken>" 'stale' 45))

if ($script:failures -gt 0) {
    Say "== DIAG: sid=$sid pane=$pane paneC=$paneC paneD=$paneD offsetA=$offsetA offsetFinal=$offsetFinal"
    foreach ($pair in @(@('B', $logB), @('C', $logC))) {
        Say "== DIAG: attach log lines ($($pair[0])) =="
        foreach ($line in ((Read-AppLog $pair[1]) -split "`n")) {
            if ($line -match 'attach:|session-restore:|stream head') { Say $line.Trim() }
        }
    }
    Say "== DIAG: last read =="
    foreach ($f in @('read-stale.txt', 'read-live.txt', 'read-post.txt', 'read-pre.txt', 'read-ready.txt')) {
        if (Test-Path "$tmp\$f") { Say "-- $f --"; Say (Out-Text "$tmp\$f") ; break }
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
    $launched = @(Get-TestLaunchedPids)
    Assert "E1 the foreground watcher actually sampled (negative control)" ($fgSeen.Count -gt 0)
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert "E2 no test-desktop app ever became foreground on the interactive desktop" ($leaked.Count -eq 0)
}

Say ""
if ($script:failures -eq 0) { Say "ALL PASS ($script:passes assertions)"; exit 0 }
else { Say "$($script:failures) FAILURE(S) / $script:passes passed"; exit 1 }
