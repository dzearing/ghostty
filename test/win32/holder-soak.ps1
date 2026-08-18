# T909 acceptance: holders are the DEFAULT, so their cost is now everyone's cost.
#
# Flipping `GHOZTTY_AGENT_PTY_HOLDER` on by default (T909) turns "one extra
# process per session" from something an opt-in user chose into something every
# box pays. The promise being measured here is the one a user would notice if it
# broke: with a realistic number of persistent panes open, the machine is not
# visibly worse off, the app still answers instantly, every pane still works,
# and NOTHING is left running when it all shuts down.
#
# Sections:
#   A. Scale: N named agent-backed panes come up, and EVERY live session is
#      holder-backed (a fallback to the in-process child would quietly halve the
#      process count and pass a naive count check).
#   B. Cost: each holder's working set is small (a holder owns a ConPTY, a ring
#      and a pipe - it must not be a second terminal), the whole holder fleet is
#      reported as one number, and `+list` still answers well inside the T62
#      bound with every session up. Sampled panes are LIVE, not pictures.
#   C. Teardown at scale: stop the app and the agent, and no holder is left
#      behind. A per-session leak is invisible at one session and is a pile of
#      orphaned shells at N.
#
# Hermetic: a per-run $env:LOCALAPPDATA, a private IPC pipe suffix, and
# GHOSTTY_LOCAL_AGENT_BIN pinned to the agent under test. Only processes whose
# ExecutablePath is the exe/agent under test are ever stopped - never the user's
# installed release, which owns their live sessions.
#
#   powershell -NoProfile -File test\win32\holder-soak.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    # Enough panes that a per-session cost shows up as a number, few enough that
    # the run stays inside a task turn.
    [int]$Panes = 6,
    # A holder is a ConPTY + a bounded ring + one pipe. The bound is generous on
    # purpose: it is here to catch a holder that grew a terminal, a renderer or
    # an unbounded buffer, not to police a few hundred KB.
    [int]$MaxHolderMB = 60,
    # Same bound P1 and session-persistence hold `+list` to (T62).
    [int]$MaxListMs = 2000
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')

$script:passes = 0
$script:failures = 0

function Assert([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

if (-not (Test-Path $Exe)) {
    Write-TestAssertedNothing -Label 'HOLDER-SOAK' -Reason "exe not found: $Exe (build with: zig build -Dapp-runtime=win32 -Doptimize=Debug)"
}
if (-not (Test-Path $AgentExe)) {
    Write-TestAssertedNothing -Label 'HOLDER-SOAK' -Reason "agent not found: $AgentExe (build with: zig build agent -Doptimize=Debug)"
}

# --- process helpers: ONLY ever the binaries under test ----------------------

function Get-TestApps {
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -eq $Exe })
}
function Get-TestAgentProcs {
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.ExecutablePath -eq $AgentExe })
}
# The session manager itself: an agent process that is NOT one of the per-session
# holders (holders are the same binary in `--pty-host` mode).
function Get-TestAgents {
    return , @((Get-TestAgentProcs) | Where-Object { $_.CommandLine -notmatch '--pty-host' })
}
function Get-TestHolders {
    return , @((Get-TestAgentProcs) | Where-Object { $_.CommandLine -match '--pty-host' })
}
function Stop-Everything {
    foreach ($p in (Get-TestApps)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    foreach ($p in (Get-TestAgentProcs)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 900
}

# --- CLI plumbing ------------------------------------------------------------

# ghoztty.exe is GUI-subsystem, so a pipe reads empty; redirect through cmd and
# bound the wait, or a wedged server hangs the script instead of failing it.
function Run-Cli([string]$argsLine, [string]$out, [int]$timeoutSec = 20) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$out`" 2>&1`""
    $null = $p.Handle   # before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1)
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $p.ExitCode
}
function Out-Text([string]$f) { if (Test-Path $f) { return (Get-Content $f -Raw) } return '' }

function Get-Sessions([string]$tmp, [string]$tag) {
    $code = Run-Cli '+sessions --json' "$tmp\sess-$tag.json" 20
    if ($code -ne 0) { return @() }
    $rows = $null
    try { $rows = (Out-Text "$tmp\sess-$tag.json") | ConvertFrom-Json } catch { return @() }
    if ($null -eq $rows) { return @() }
    return , @($rows)
}
function Alive-Rows($rows) { return , @($rows | Where-Object { $_.alive -eq $true }) }

# Every terminal leaf across every window of `+list --json`. Pane TARGETS come
# from here rather than from a `--name` given at creation: `--name` registers a
# pane on `+split` only - on `+new-window` it is silently dropped (T968) - while
# `+list` auto-registers every pane it discovers, so the id it reports back is
# usable as a target immediately.
function Leaves-Of($node) {
    if ($null -eq $node) { return @() }
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    if ($node.type -eq 'split') { return @(Leaves-Of $node.left) + @(Leaves-Of $node.right) }
    return @()
}
function Get-PaneNames {
    $raw = Get-GhozttyListRaw -Exe $Exe
    $doc = $null
    try { $doc = $raw | ConvertFrom-Json } catch { return , @() }
    if ($null -eq $doc -or -not $doc.success) { return , @() }
    $out = @()
    foreach ($w in @($doc.data.windows)) {
        foreach ($t in @($w.tabs)) {
            foreach ($lf in (Leaves-Of $t.splits)) {
                if ($lf.type -eq 'terminal' -and $lf.name) { $out += [string]$lf.name }
            }
        }
    }
    return , @($out)
}
function Wait-AliveCount([string]$tmp, [string]$tag, [int]$target, [int]$timeoutSec = 90) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $rows = @()
    while ((Get-Date) -lt $deadline) {
        $rows = Get-Sessions $tmp $tag
        if ((Alive-Rows $rows).Count -ge $target) { return , $rows }
        Start-Sleep -Milliseconds 700
    }
    return , $rows
}
function Wait-HolderCount([int]$target, [int]$timeoutSec = 60) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Get-TestHolders).Count -ge $target) { break }
        Start-Sleep -Milliseconds 700
    }
    return , (Get-TestHolders)
}

$root = Join-Path $env:TEMP "ghoztty-holder-soak-$PID"
$tmp = Join-Path $root 'run'
$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedHolderFlag = $env:GHOZTTY_AGENT_PTY_HOLDER

try {
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
    # THE SUBJECT: nothing is set. Holder-backed spawning is the default since
    # T909, and an arm that set the flag would keep passing on the day the
    # default silently regressed. Only an inherited opt-out is cleared.
    Remove-Item env:GHOZTTY_AGENT_PTY_HOLDER -ErrorAction SilentlyContinue

    [void](Set-GhozttyTestIsolation -Tag 'soak909')
    Assert-GhozttyPrivateEndpoint -Exe $Exe
    Stop-Everything

    # ========================================================================
    Say "== A: $Panes persistent panes, every one of them holder-backed"
    # ========================================================================
    # persistence: on (default) - an agent-backed pane is the whole subject.
    $app = Start-Process -FilePath $Exe -WindowStyle Minimized -PassThru `
        -ArgumentList @('--title=soak909', '--window-width=90', '--window-height=24')
    $ready = $false
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if ($app.HasExited) { break }
        if ((Get-GhozttyListRaw -Exe $Exe) -match '"') { $ready = $true; break }
        Start-Sleep -Milliseconds 500
    }
    Assert 'A1 premise: the app is up and answering IPC' $ready
    if (-not $ready) { Write-TestVerdict -Label 'HOLDER-SOAK' -Pass $script:passes -Fail $script:failures }
    Assert-GhozttyIsolated -Exe $Exe

    # Separate WINDOWS rather than splits of one: N splits of a single window run
    # into minimum-pane-size geometry long before N is interesting, and the
    # subject here is the per-SESSION cost, which is the same either way.
    $made = 0
    for ($i = 1; $i -le $Panes; $i++) {
        if ((Run-Cli "+new-window --target=soak$i" "$tmp\new-$i.txt" 30) -eq 0) { $made++ }
    }
    Assert "A2 all $Panes windows were created" ($made -eq $Panes)

    # The app's own first pane is a session too, so the floor is $Panes + 1.
    $want = $Panes + 1
    $rows = Wait-AliveCount $tmp 'a' $want 120
    $alive = Alive-Rows $rows
    Say "    [A] alive sessions: $($alive.Count) (wanted $want)"
    Assert "A3 $want sessions are alive on the agent" ($alive.Count -ge $want)

    $holders = Wait-HolderCount $alive.Count 60
    Say "    [A] holder processes: $($holders.Count)"
    # EQUAL, not "at least": a holder-spawn failure falls back to the in-process
    # child with only a log line, so a session count that outruns the holder
    # count is exactly what that silent fallback looks like from out here.
    Assert 'A4 every live session has its own holder (no silent fallback to the in-process child)' (
        $holders.Count -eq $alive.Count -and $holders.Count -ge $want)

    # ========================================================================
    Say "== B: the cost of that, measured"
    # ========================================================================
    $sizes = @($holders | ForEach-Object { [math]::Round($_.WorkingSetSize / 1MB, 1) })
    $maxMB = if ($sizes.Count -gt 0) { ($sizes | Measure-Object -Maximum).Maximum } else { 0 }
    $totalMB = if ($sizes.Count -gt 0) { [math]::Round((($sizes | Measure-Object -Sum).Sum), 1) } else { 0 }
    $agentProcs = Get-TestAgents
    $agentMB = if ($agentProcs.Count -gt 0) {
        [math]::Round((($agentProcs | ForEach-Object { $_.WorkingSetSize } | Measure-Object -Sum).Sum / 1MB), 1)
    } else { 0 }
    Say "    [B] holder working sets (MB): $($sizes -join ', ')"
    Say "    [B] holder fleet total: $totalMB MB for $($holders.Count) sessions; session manager: $agentMB MB"
    Assert "B1 the biggest holder is under ${MaxHolderMB}MB (max=${maxMB}MB)" (
        $holders.Count -gt 0 -and $maxMB -le $MaxHolderMB)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $listCode = Run-Cli '+list --json' "$tmp\list-b.txt" 20
    $sw.Stop()
    $listMs = [int]$sw.ElapsedMilliseconds
    Say "    [B] +list with $($alive.Count) sessions up: ${listMs}ms"
    Assert "B2 +list still answers in ${listMs}ms < ${MaxListMs}ms with every session up" (
        $listCode -eq 0 -and $listMs -lt $MaxListMs)

    # Sampled rather than exhaustive: three panes across the fleet cost three
    # round-trips instead of N, and a fleet-wide breakage cannot hide in the gap
    # (the first, the middle and the last were spawned at different points in
    # the ramp).
    # NOT `$panes`: the script parameter `[int]$Panes` is the same variable by
    # PowerShell's case-insensitive rules, and assigning an array to it throws
    # an ArgumentTransformationMetadataException from the type constraint.
    $paneIds = Get-PaneNames
    Assert "B3 premise: +list reports all $want panes as targetable" ($paneIds.Count -ge $want)
    $sample = @()
    if ($paneIds.Count -gt 0) {
        $sample = @($paneIds[0], $paneIds[[math]::Floor($paneIds.Count / 2)], $paneIds[$paneIds.Count - 1]) |
            Select-Object -Unique
    }
    $liveCount = 0
    foreach ($n in $sample) {
        if (Test-PaneLive -Exe $Exe -Target $n -Tmp $tmp -Tag 'B' -TimeoutSec 40) { $liveCount++ }
    }
    Assert "B4 sampled panes are LIVE, not pictures ($liveCount/$($sample.Count))" (
        $sample.Count -eq 3 -and $liveCount -eq $sample.Count)

    # ========================================================================
    Say "== C: teardown at scale - a per-session leak is a pile of orphans"
    # ========================================================================
    Stop-Everything
    Start-Sleep -Seconds 2
    $left = Get-TestHolders
    if ($left.Count -gt 0) { Say "    [C] left behind: $(($left | ForEach-Object { $_.ProcessId }) -join ', ')" }
    Assert 'C1 no holder survives a full app + agent teardown' ($left.Count -eq 0)
} catch {
    # A terminating error must never read as a clean run: without this the
    # script jumps straight to `finally`, stamps the guard and prints ALL PASS
    # over sections that never executed (seen once while this file was being
    # written, which is why it is here).
    Write-Host "  FAIL harness error: $_" -ForegroundColor Red
    $script:failures++
} finally {
    Stop-Everything
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    if ($null -ne $savedHolderFlag) { $env:GHOZTTY_AGENT_PTY_HOLDER = $savedHolderFlag }
    else { Remove-Item env:GHOZTTY_AGENT_PTY_HOLDER -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- stamp (T783) -----------------------------------------------------------
if ($script:failures -eq 0) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard holder-soak -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Label 'HOLDER-SOAK' -Pass $script:passes -Fail $script:failures
