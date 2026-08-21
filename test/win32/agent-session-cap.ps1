# T278 acceptance: dead tombstones must never cost a user a working pane.
#
# The defect, measured on box 2026-08-01: the local agent's 256-session cap
# counted DEAD sessions. Every restored pane materializes its recorded session
# as a dead-but-relaunchable tombstone, and a tombstone is `pinned` (that is
# what keeps a persistent local pane alive while its viewer is away), which is
# exactly what exempted it from the idle-TTL reaper. The set only ever grew.
# Once it reached 256 every OPEN was refused - and the refusal was silent, so
# each new pane came up with NO child process: `+read` said "failed to read
# terminal content", `+send-keys` went nowhere, and `+list` reported the pane
# as running with pid 0. Indistinguishable from a hung shell.
#
# Scored by OUTCOME - can the user type into a fresh pane and see the result -
# not by log scraping:
#
#   A: 256 dead tombstones in the agent's sessions.json, an agent started on
#      top of them, and a brand-new window. The pane must have a real child
#      (pid != 0) and must echo a unique marker back.
#   B: the tombstones did not silently take the agent's roster with them:
#      `+sessions --json` answers, and the live pane is in it.
#   C: negative control for the whole harness - the same run with an EMPTY
#      sessions.json must also pass. Without it, A proves nothing about the cap
#      (a build that refused every OPEN outright would fail both, and a build
#      that ignored sessions.json entirely would pass both for the wrong
#      reason) - so C is scored FIRST and its failure is called out as a setup
#      failure rather than a product one.
#
# Hermetic: a per-run LOCALAPPDATA, GHOSTTY_LOCAL_AGENT_BIN and IPC pipe
# suffix, run on a BACKGROUND Win32 desktop, and it only ever kills ghoztty /
# ghoztty-agent processes launched from the repo zig-out.
#
#   powershell -NoProfile -File test\win32\agent-session-cap.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    # How many dead tombstones to seed. 256 is `session.max_sessions`; the
    # point is to be AT the cap with nothing alive.
    [int]$Tombstones = 256,
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$root = Join-Path $env:TEMP "ghoztty-session-cap-$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
# T1033: this script launches the app itself (Start-Process, not the test
# desktop's helper), so it asks the pre-flight question the helper asks: are
# these bytes ours to drive, or the ones the user's installed Ghoztty owns?
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

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

function Run-CliArgs($argv, $out, $timeoutSec = 15) {
    # persistence: on (default) - the agent under test only owns sessions when persistence is on.
    $p = Start-Process -FilePath $Exe -WindowStyle Hidden -PassThru `
        -ArgumentList $argv -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    # Cache the handle BEFORE the process can exit: reading `.Handle` afterwards
    # yields an EMPTY ExitCode and every `-eq 0` gate scores a working CLI FAIL.
    $null = $p.Handle
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    $p.WaitForExit()
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

function Get-List($tag, $timeoutSec = 12) {
    Run-CliArgs @('+list', '--json') "$tmp\list-$tag.json" $timeoutSec | Out-Null
    try { return (Out-Text "$tmp\list-$tag.json" | ConvertFrom-Json) } catch { return $null }
}
function Windows-Of($tree) {
    if ($null -eq $tree) { return , @() }
    if ($null -ne $tree.data) { return , @($tree.data.windows) }
    return , @($tree.windows)
}
function Leaves-Of($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') { return @(Leaves-Of $node.left) + @(Leaves-Of $node.right) }
    return @()
}
function All-Leaves($tree) {
    $acc = @()
    foreach ($w in Windows-Of $tree) { foreach ($t in @($w.tabs)) { $acc += Leaves-Of $t.splits } }
    return , $acc
}
function Wait-Leaves($tag, $target, $timeoutSec = 60) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $tree = Get-List $tag
        if ((All-Leaves $tree).Count -ge $target) { return $tree }
        Start-Sleep -Milliseconds 600
    }
    return (Get-List "$tag-last")
}
function Read-Pane($id, $tag, $lines = 200) {
    Run-CliArgs @('+read', "--name=$id", "--lines=$lines") "$tmp\read-$tag.txt" 12 | Out-Null
    return ((Out-Text "$tmp\read-$tag.txt") -replace "`0", '')
}

# THE liveness oracle for a pane: type a unique marker and read it back TWICE -
# once as the echoed input line, once as the command's output. One occurrence is
# just keystrokes landing in a dead pane's line editor.
function Test-PaneResponsive($id, $tag, $timeoutSec = 40) {
    $marker = "T278x$($tag)x$(Get-Random -Maximum 999999)"
    Run-CliArgs @('+send-keys', "--target=$id", 'echo', 'Space', $marker, 'Enter') `
        "$tmp\keys-$tag.txt" 12 | Out-Null
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $txt = (Read-Pane $id "resp-$tag") -replace '\s', ''
        $hits = ([regex]::Matches($txt, [regex]::Escape($marker))).Count
        if ($hits -ge 2) { return $true }
        Start-Sleep -Milliseconds 700
    }
    return $false
}

function Start-App($title, $extraArgs = @()) {
    $script:AppLog = Join-Path $tmp "applog-$title.err.txt"
    # persistence: on (default) - the agent under test only owns sessions when persistence is on.
    $app = Start-OnTestDesktop -Exe $Exe -Arguments $extraArgs -StdErr $script:AppLog
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 40000
    if ($top -eq [IntPtr]::Zero) { return 0 }
    return [int]$app.Pid
}

# A virgin state dir per arm: LOCALAPPDATA carries both the session-layout
# manifest and the agent's sessions.json, so sharing one across arms means arm
# N+1 restores arm N's windows before its own setup runs.
function Reset-State($arm) {
    $script:tmp = Join-Path $root "run-$arm"
    $script:agentDir = Join-Path $script:tmp 'ghoztty\local-agent-debug'
    New-Item -ItemType Directory -Force $script:agentDir | Out-Null
    $env:LOCALAPPDATA = $script:tmp
}

# Seed `n` DEAD tombstones: recorded sessions with no process behind them, in
# exactly the shape a restored persistent pane leaves behind (pinned, a cwd, a
# fresh unclaimed_restarts allowance so nothing ages them out on this load).
function Seed-Tombstones($n) {
    $recs = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $n; $i++) {
        # A stable, unique 128-bit hex id per record. Never zero (the control
        # channel), which the agent skips as malformed.
        $id = ('{0:x8}' -f ($i + 1)) + 'deadbeefcafef00d0000000000000000'.Substring(0, 24)
        $recs.Add('{"id":"' + $id + '","cwd":"C:\\\\Users","pinned":true,"created_ms":1785863794903,"unclaimed_restarts":0}')
    }
    $json = '{"version":1,"sessions":[' + ($recs -join ',') + ']}'
    [System.IO.File]::WriteAllText((Join-Path $script:agentDir 'sessions.json'), $json)
    return $n
}

# The agent's own roster. Returns @{ total; alive } or $null.
#
# NOT `@(... | ConvertFrom-Json).Count`: PowerShell 5.1's ConvertFrom-Json hands
# a JSON array down the pipeline as ONE object, so that idiom reports 1 for a
# 257-element roster and every count assertion built on it is a false pass.
function Get-AgentRoster($tag) {
    Run-CliArgs @('+sessions', '--json') "$tmp\sessions-$tag.json" 25 | Out-Null
    $raw = Out-Text "$tmp\sessions-$tag.json"
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { $obj = $raw | ConvertFrom-Json } catch { return $null }
    if ($null -eq $obj) { return $null }
    $rows = if ($obj -is [System.Array]) { $obj } else { @($obj) }
    return @{ total = $rows.Count; alive = @($rows | Where-Object { $_.alive }).Count }
}

# One arm: seed `$seed` tombstones, bring the GUI up, and demand a working pane.
function Invoke-Arm($arm, $seed, $prefix) {
    Reset-State $arm
    if ($seed -gt 0) {
        $wrote = Seed-Tombstones $seed
        Assert "$prefix seeded $wrote dead tombstones" `
            ((Test-Path (Join-Path $script:agentDir 'sessions.json')) -and $wrote -eq $seed)
    }

    $appPid = Start-App $arm
    Assert "$prefix the GUI came up" ($appPid -ne 0)
    if ($appPid -eq 0) { return }

    $tree = Wait-Leaves "$arm-0" 1 60
    $leaves = All-Leaves $tree
    Assert "$prefix a pane exists" ($leaves.Count -ge 1)
    if ($leaves.Count -lt 1) { return }

    # The wedge's fingerprint: a pane that reports `running` with pid 0 because
    # its OPEN was refused and nothing said so.
    $leaf = $leaves[0]
    Assert "$prefix the pane has a real child (pid != 0), not a refused OPEN" `
        ($null -ne $leaf.pid -and [int]$leaf.pid -ne 0)

    if ($NegativeControl -and $seed -gt 0) {
        Say 'NEGATIVE CONTROL: asserting the seeded arm CANNOT type - this run MUST fail'
        Assert "$prefix the pane is dead (inverted)" (-not (Test-PaneResponsive $leaf.id $arm))
    } else {
        Assert "$prefix the pane takes input and echoes it back" `
            (Test-PaneResponsive $leaf.id $arm)
    }

    if ($seed -gt 0) {
        # The agent must still answer under the load, and the roster must show a
        # session with a process behind it. The tombstones themselves STAY - they
        # are the reboot floor, and a user can still Resume them; the fix is that
        # they no longer deny anyone a live one.
        $r = Get-AgentRoster $arm
        Assert "$prefix +sessions still answers" ($null -ne $r)
        if ($null -ne $r) {
            Assert "$prefix the roster still carries the $seed tombstones (got $($r.total))" `
                ($r.total -ge $seed)
            Assert "$prefix the roster has a LIVE session (got $($r.alive) alive)" `
                ($r.alive -ge 1)
        }
    }

    Stop-TestProcs
}

Stop-TestProcs
$tmp = Join-Path $root 'run'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$saved = @{ lad = $env:LOCALAPPDATA; bin = $env:GHOSTTY_LOCAL_AGENT_BIN; pipe = $env:GHOZTTY_PIPE_SUFFIX }
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
# Isolate the IPC endpoint: every `+list` / `+read` / `+send-keys` below is an
# oracle, and a user instance answering the shared pipe would answer them about
# somebody else's windows.
$env:GHOZTTY_PIPE_SUFFIX = '-sesscap'

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {

Assert "setup: ghoztty exe exists in zig-out" (Test-Path $Exe)
Assert "setup: agent exe exists in zig-out" (Test-Path $AgentExe)

# ============================================================================
Say "== C: control - a clean agent opens a working pane"
# ============================================================================
# Scored first, and deliberately: if this fails, arm A proves nothing about the
# cap, so read a C failure as "the harness or the build is broken", not "the
# tombstone fix regressed".
Invoke-Arm 'clean' 0 'C'

# ============================================================================
Say "== A: $Tombstones dead tombstones must not cost the user a pane"
# ============================================================================
Invoke-Arm 'seeded' $Tombstones 'A'

} finally {
    Stop-TestProcs
    Stop-TestForegroundWatch
    if ($td) { Remove-TestDesktop $td }
    $env:LOCALAPPDATA = $saved.lad
    $env:GHOSTTY_LOCAL_AGENT_BIN = $saved.bin
    $env:GHOZTTY_PIPE_SUFFIX = $saved.pipe
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:failures -eq 0) { Write-Host "ALL PASS ($script:passes checks)" -ForegroundColor Green; exit 0 }
Write-Host "$script:failures FAILURE(S) ($script:passes passed)" -ForegroundColor Red
exit 1
