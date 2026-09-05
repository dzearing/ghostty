# T545 acceptance: `+sessions` must name what a PLAIN SHELL session is running.
#
# The gap: the roster's command column comes from `argv`, which is only set for
# a pane opened with an explicit `--command`. Every ordinary pane - the user
# typed their command at the prompt - has `argv == null`, so `+sessions`
# answered nothing at all about what the session was doing. The agent has known
# the answer since T429 (`Session.fg_cmd`, sampled off the shell's most recent
# direct child); it simply never reached the roster.
#
# Scored by OUTCOME - what does the CLI a user runs actually print - not by
# reading the agent's sessions.json:
#
#   A: a live plain-shell session running a long command reports it. The row
#      in `+sessions --json` carries `fg_cmd`, and the human-readable table
#      prints `running=<that command>`. This is also the harness's positive
#      control: it proves the agent is sampling at all on this box, which is
#      what makes B's absence mean something.
#   B: the same session, back at its prompt, reports NOTHING - `fg_cmd` is null
#      and no `running=` appears. Scored only after A passed, because "no
#      command reported" is the answer a build that never sampled would give
#      too, and the two are indistinguishable without A in front of it.
#   C: `argv` and `fg_cmd` stay SEPARATE facts. The row that carries a running
#      command must not have had it written into `argv` - that field is what
#      RELAUNCH re-executes, and overwriting it would make a resumed pane
#      re-run `ping` in place of the shell.
#
# The sampler runs on the store's slow tick (every ~10s), so every assertion
# here polls rather than reading once.
#
# Hermetic: a per-run LOCALAPPDATA, GHOSTTY_LOCAL_AGENT_BIN and IPC pipe
# suffix, run on a BACKGROUND Win32 desktop, and it only ever kills ghoztty /
# ghoztty-agent processes launched from the repo zig-out.
#
#   powershell -NoProfile -File test\win32\sessions-running-cmd.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    # How many pings the pane runs. Long enough that the ~10s sampler is
    # guaranteed several looks at it while it is up.
    [int]$PingCount = 45,
    [switch]$NegativeControl,
    [switch]$Interactive
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$root = Join-Path $env:TEMP "ghoztty-running-cmd-$PID"

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
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 700)
}

function Run-CliArgs($argv, $out, $timeoutSec = 15) {
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

# The agent's roster as rows.
#
# NOT `@(... | ConvertFrom-Json)`: PowerShell 5.1's ConvertFrom-Json hands a
# JSON array down the pipeline as ONE object, so that idiom reports 1 row for a
# whole roster and every count assertion built on it is a false pass.
function Get-Roster($tag) {
    Run-CliArgs @('+sessions', '--json') "$tmp\sessions-$tag.json" 25 | Out-Null
    $raw = Out-Text "$tmp\sessions-$tag.json"
    if ([string]::IsNullOrWhiteSpace($raw)) { return , @() }
    try { $obj = $raw | ConvertFrom-Json } catch { return , @() }
    if ($null -eq $obj) { return , @() }
    if ($obj -is [System.Array]) { return , $obj }
    return , @($obj)
}

# The human-readable table - the other half of the surface, and the one a person
# actually reads.
function Get-RosterText($tag) {
    Run-CliArgs @('+sessions') "$tmp\sessions-text-$tag.txt" 25 | Out-Null
    return (Out-Text "$tmp\sessions-text-$tag.txt")
}

function Live-Rows($rows) { return , @($rows | Where-Object { $_.alive }) }

# Poll the roster until a LIVE row reports a foreground command matching
# `$pattern`. Returns that row, or $null on timeout.
function Wait-RunningCmd($tag, $pattern, $timeoutSec = 75) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $i = 0
    while ((Get-Date) -lt $deadline) {
        foreach ($r in (Live-Rows (Get-Roster "$tag-$i"))) {
            if ($null -ne $r.fg_cmd -and $r.fg_cmd -match $pattern) { return $r }
        }
        $i++
        Start-Sleep -Seconds 3
    }
    return $null
}

# Poll until every live row is back to reporting nothing. Returns $true when the
# roster has gone quiet within the window.
function Wait-NoRunningCmd($tag, $timeoutSec = 90) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $i = 0
    while ((Get-Date) -lt $deadline) {
        $live = Live-Rows (Get-Roster "$tag-$i")
        if ($live.Count -gt 0) {
            $busy = @($live | Where-Object { $null -ne $_.fg_cmd })
            if ($busy.Count -eq 0) { return $true }
        }
        $i++
        Start-Sleep -Seconds 3
    }
    return $false
}

function Start-App($title, $extraArgs = @()) {
    $script:AppLog = Join-Path $tmp "applog-$title.err.txt"
    # persistence: on (default) - the agent under test only owns sessions when
    # persistence is on, and a session it does not own has no roster row.
    $app = Start-OnTestDesktop -Exe $Exe -Arguments $extraArgs -StdErr $script:AppLog
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 40000
    if ($top -eq [IntPtr]::Zero) { return 0 }
    return [int]$app.Pid
}

Stop-TestProcs
$tmp = Join-Path $root 'run'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$saved = @{ lad = $env:LOCALAPPDATA; bin = $env:GHOSTTY_LOCAL_AGENT_BIN; pipe = $env:GHOZTTY_PIPE_SUFFIX }
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
# Isolate the IPC endpoint: every `+list` / `+send-keys` / `+sessions` below is
# an oracle, and a user instance answering the shared pipe would answer them
# about somebody else's windows and somebody else's sessions.
$env:GHOZTTY_PIPE_SUFFIX = "-runcmd$PID"

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {

Assert "setup: ghoztty exe exists in zig-out" (Test-Path $Exe)
Assert "setup: agent exe exists in zig-out" (Test-Path $AgentExe)

$appPid = Start-App 'run'
Assert "setup: the GUI came up" ($appPid -ne 0)
if ($appPid -eq 0) { throw 'no GUI' }

$tree = Wait-Leaves 'boot' 1 60
$leaves = All-Leaves $tree
Assert "setup: a pane exists" ($leaves.Count -ge 1)
if ($leaves.Count -lt 1) { throw 'no pane' }
$paneId = $leaves[0].id

# The pane was opened by the app with no explicit `--command`, which is the
# whole point: this is the shape whose roster row said nothing.
$boot = Live-Rows (Get-Roster 'boot')
Assert "setup: the agent owns a live session for the pane" ($boot.Count -ge 1)
Assert "setup: that session has no recorded argv (a plain shell)" `
    ($boot.Count -ge 1 -and $null -eq $boot[0].argv)

# ============================================================================
Say "== A: a plain-shell session running a command says so"
# ============================================================================
Run-CliArgs @('+send-keys', "--target=$paneId", 'ping', 'Space', '-n', 'Space',
    "$PingCount", 'Space', '127.0.0.1', 'Enter') "$tmp\keys-ping.txt" 12 | Out-Null

$running = Wait-RunningCmd 'busy' 'ping'
if ($NegativeControl) {
    Say 'NEGATIVE CONTROL: asserting the roster NEVER names the running command - this run MUST fail'
    Assert "A the roster stays silent while ping runs (inverted)" ($null -eq $running)
} else {
    Assert "A --json reports the running command (fg_cmd)" ($null -ne $running)
}
if ($null -ne $running) { Say "    fg_cmd = $($running.fg_cmd)" }

$text = Get-RosterText 'busy'
Assert "A the human-readable table prints running=<cmd>" ($text -match 'running=\S*ping')

# ============================================================================
Say "== C: argv and fg_cmd stay separate facts"
# ============================================================================
# `argv` is what RELAUNCH re-executes. If the sampled command had been folded
# into it, `session-relaunch = rerun` would bring the pane back running ping
# instead of a shell - which is why these are two fields and not one.
Assert "C the sampled command did not overwrite argv" `
    ($null -ne $running -and $null -eq $running.argv)
Assert "C the table still distinguishes cmd= from running=" `
    (($text -match 'running=') -and ($text -notmatch 'cmd=\S*ping'))

# ============================================================================
Say "== B: back at the prompt, the roster reports nothing"
# ============================================================================
# Scored last and only meaningful because A passed: an empty answer is what a
# build that never sampled would give too. Waiting for ping to finish on its own
# keeps this off any ^C-delivery question - a separate mechanism with its own
# failure modes (T84).
Say "    waiting for ping to finish and the sampler to clear the record..."
Assert "B an idle prompt reports no running command" (Wait-NoRunningCmd 'idle')

$idleText = Get-RosterText 'idle'
Assert "B the idle table prints no running= column" ($idleText -notmatch 'running=')

} catch {
    Write-Host "  FAIL harness: $_" -ForegroundColor Red
    $script:failures++
} finally {
    Stop-TestProcs
    Stop-TestForegroundWatch
    if ($td) { Remove-TestDesktop $td }
    $env:LOCALAPPDATA = $saved.lad
    $env:GHOSTTY_LOCAL_AGENT_BIN = $saved.bin
    $env:GHOZTTY_PIPE_SUFFIX = $saved.pipe
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

# A clean green run stamps the covered files (T783); a red run - the negative
# control included - leaves the stamp alone on purpose, because red must stay
# due.
if ($script:failures -eq 0 -and -not $NegativeControl) {
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard sessions-running-cmd -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
if ($script:failures -eq 0) { Write-Host "ALL PASS ($script:passes checks)" -ForegroundColor Green; exit 0 }
Write-Host "$script:failures FAILURE(S) ($script:passes passed)" -ForegroundColor Red
exit 1
