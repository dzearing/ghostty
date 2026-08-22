# T1048 acceptance: in-place recovery pairs TABS by identity, not by position.
#
# THE DEFECT. `App.rebuildWindowInPlace` walked `for (0..tab_count) |ti|` and
# handed `captured.tabs[ti]` to live tab `ti`. That join is correct only while
# the window's tab list has not moved since `captureSessionLayout` ran - and the
# capture is immediately followed by `reconnectForRecovery`, which can block for
# SECONDS while it re-dials the agent. `LocalAgent.findOrSpawn` pumps IPC while
# it waits (T188), so a `ghoztty +close` issued in that window IS served: the tab
# list shifts under a capture nobody re-took, and every later tab is then rebuilt
# from its NEIGHBOUR's tree - its sessions re-ATTACHed into the wrong panes.
# `rebuildTabInPlace`'s correspondence check cannot catch it, because it compares
# node SHAPES and two single-pane tabs have the same shape. T343 removed exactly
# this class one level up (windows now pair on `layout_uuid`); T1048 gives tabs
# their own `uuid` and the same `pairTabs` join.
#
# HOW THE RACE IS DRIVEN, with no test hook and no debugger:
#
#   1. Three single-pane tabs, each with a DIFFERENT shell pid.
#   2. SUSPEND the agent. The app's transport FSM walks to `reconnecting` after
#      3 missed heartbeats, opens its settle watch, and - because the wedge is
#      held past the 5s window - commits to in-place recovery. It logs
#      "recovering local windows in place", captures the layout, and then blocks
#      in the re-dial against the frozen agent.
#   3. STILL SUSPENDED, close tab 0 over IPC. `Connection.closeChannel` is a
#      fire-and-forget control write, so this needs nothing from the frozen
#      agent, and the request RETURNING is proof it was served while the dial
#      was still in flight. That ordering is asserted, not assumed - without it
#      a pass would say nothing (C1/C2), and neither would a rebuild that came
#      from the ABORT path's re-entry with a fresh capture (D2).
#   4. RESUME, immediately, so the dial is still probing when the agent starts
#      answering. The rebuild then runs against a capture one tab out of date.
#
# THE ORACLE is the shell pid at each tab POSITION. Since T909 sessions are
# holder-backed, so a suspend/resume never costs a child and the surviving tabs
# keep their pids across the rebuild:
#
#   * fixed:  tabs [B, C] hold pids [P2, P3] - each tab kept its own session.
#   * broken: live tab 0 (B) pairs with captured tab 0 (A), whose session the
#             close just ENDED, so it re-opens with a brand-new pid; live tab 1
#             (C) pairs with captured tab 1 and comes back holding P2 - B's
#             session, in C's tab.
#
# Both halves of that are checked: the pids, and the surface set (a rebuild
# replaces every `GhozttyTerminal` child, which is what proves a rebuild ran at
# all rather than the recovery having quietly done nothing).
#
# -NegativeControl inverts the load-bearing claim (D4) so a run MUST fail,
# proving the oracle discriminates rather than passing for free.
#
# Hermetic: a per-run $env:LOCALAPPDATA + GHOSTTY_LOCAL_AGENT_BIN + private IPC
# suffix, and it only ever kills ghoztty / ghoztty-agent processes launched from
# this repo's zig-out. Runs on a BACKGROUND desktop (T217), so the chord that
# makes a tab is POSTED and never steals the user's foreground.
#
#   powershell -NoProfile -File test\win32\agent-recovery-tabs.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "  PASS $label" }
    else { $script:fail++; Write-Host "  FAIL $label" -ForegroundColor Red }
}
function Skip([string]$label) { $script:skipped++; Write-Host "  SKIP $label" }

function Kill-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $Exe -SettleMs 700)
}

# Suspend/resume a process. Same shape as agent-recovery.ps1's native block,
# minus what this script does not use - the window enumerator is deliberately
# NOT here (see `Get-TerminalSurfaces`).
if (-not ('GhozttyTabPairNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class GhozttyTabPairNative {
    [DllImport("ntdll.dll")] static extern int NtSuspendProcess(IntPtr h);
    [DllImport("ntdll.dll")] static extern int NtResumeProcess(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);

    const int PROCESS_SUSPEND_RESUME = 0x0800;

    public static int SetSuspended(int pid, bool suspended) {
        IntPtr h = OpenProcess(PROCESS_SUSPEND_RESUME, false, pid);
        if (h == IntPtr.Zero) return -1;
        int rc = suspended ? NtSuspendProcess(h) : NtResumeProcess(h);
        CloseHandle(h);
        return rc;
    }

}
'@
}
function Set-AgentSuspended($procId, [bool]$suspended) {
    return [GhozttyTabPairNative]::SetSuspended([int]$procId, $suspended)
}
# The app's pane surfaces, as a comparable set. `EnumWindows` is per-DESKTOP and
# this app runs on the background one, so a native enumerator would answer an
# empty set for every sample and make "the surfaces were replaced" a tautology -
# the TestDesktop walker is the one that can see them.
function Get-TerminalSurfaces($top) {
    $panes = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal')
    return , @($panes | ForEach-Object { [int64]$_.Hwnd } | Sort-Object)
}

# ---------------------------------------------------------------- CLI helpers
function Run-Cli($argsLine, $out, $timeoutSec = 15) {
    $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "/c `"`"$Exe`" $argsLine > `"$out`" 2>&1`""
    $null = $p.Handle   # before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1)
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    $p.WaitForExit()
    return $p.ExitCode
}

# The same call in ONE process launch, for the latency-bound step in section C.
# Arguments go straight to the exe as an array: `cmd /c` re-parses the line.
function Run-CliOne($argv, $out, $timeoutSec = 15) {
    $p = Start-Process -FilePath $Exe -WindowStyle Hidden -PassThru `
        -ArgumentList $argv -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    $null = $p.Handle   # before any wait, or ExitCode reads empty (lib\ExitCodeAudit.ps1)
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    $p.WaitForExit()
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

function Get-List($tag, $timeoutSec = 12) {
    $code = Run-Cli '+list --json' "$tmp\list-$tag.json" $timeoutSec
    if ($code -ne 0) { return $null }
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
# One row per TAB of the first window, in tab order: the tab's first leaf's pane
# id and shell pid. Tab POSITION is the whole point of this script, so nothing
# here sorts or dedupes.
function Get-TabRows($tag, $timeoutSec = 12) {
    $tree = Get-List $tag $timeoutSec
    $wins = Windows-Of $tree
    if ($wins.Count -lt 1) { return , @() }
    $acc = @()
    foreach ($t in @($wins[0].tabs)) {
        $leaves = @(Leaves-Of $t.splits)
        if ($leaves.Count -lt 1) { continue }
        $acc += [pscustomobject]@{ Id = "$($leaves[0].id)"; ShellPid = [int]$leaves[0].pid }
    }
    return , $acc
}
function Wait-TabCount($tag, $want, $timeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $rows = @()
    while ((Get-Date) -lt $deadline) {
        $rows = Get-TabRows $tag
        if ($rows.Count -eq $want) { return , $rows }
        Start-Sleep -Milliseconds 400
    }
    return , $rows
}

function Get-RunAgents {
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.CommandLine -like "*$tmp*" })
}

function Get-AppLogLength { if (Test-Path $appLog) { (Get-Item $appLog).Length } else { 0 } }
function Read-AppLog($fromLen) {
    if (-not (Test-Path $appLog)) { return '' }
    try {
        $fs = [System.IO.File]::Open($appLog, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -le $fromLen) { return '' }
            [void]$fs.Seek([int64]$fromLen, 'Begin')
            $buf = New-Object byte[] ([int]($fs.Length - $fromLen))
            [void]$fs.Read($buf, 0, $buf.Length)
            return [System.Text.Encoding]::UTF8.GetString($buf)
        } finally { $fs.Dispose() }
    } catch { return '' }
}
function Wait-AppLog($fromLen, $pattern, $timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Read-AppLog $fromLen) -match $pattern) { return $true }
        Start-Sleep -Milliseconds 150
    }
    return $false
}

# ================================================================== setup
if (-not (Test-Path $Exe)) { throw "ghoztty exe not found: $Exe" }
if (-not (Test-Path $AgentExe)) { throw "agent exe not found: $AgentExe" }

$root = Join-Path $env:TEMP "ghoztty-recovery-tabs-$PID"
$tmp = Join-Path $root 'run'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
$appLog = Join-Path $tmp 'app.err'

[void](Set-GhozttyTestIsolation -Tag 'recovtabs')
Assert-GhozttyPrivateEndpoint -Exe $Exe

Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$appPid = 0
$agentPid = 0

try {
    # ============================================================ A: baseline
    "== A: three single-pane tabs, each on its own shell"
    $app = Start-OnTestDesktop -Exe $Exe -StdErr $appLog `
        -Arguments @('--title=t1048-tabs', '--window-show-tab-bar=always')
    $appPid = $app.Pid
    $top = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'top window never appeared' -Label 'agent-recovery-tabs'
    }
    $rows = Wait-TabCount 'a0' 1 40
    Assert ($rows.Count -eq 1) 'A1 the GUI came up with one tab and answers +list'
    if ($rows.Count -ne 1) { throw 'setup: no first tab' }
    Assert-GhozttyIsolated -Exe $Exe

    # ctrl+t twice. The chord is POSTED to the focused pane child, which is what
    # keeps this off the interactive desktop; each new tab activates, so the
    # third lands after the second and the order is [A, B, C].
    for ($i = 0; $i -lt 2; $i++) {
        $panes = @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal')
        $focusTarget = if ($panes.Count -gt 0) { [IntPtr]$panes[0].Hwnd } else { [IntPtr]::Zero }
        if (-not (Focus-TestWindow -Window $top -Child $focusTarget)) {
            Write-TestAssertedNothing -Reason 'could not focus the GUI' -Label 'agent-recovery-tabs'
        }
        [void](Send-TestKeys -Window $top -Target $focusTarget -Modifiers ctrl -Key T)
        $rows = Wait-TabCount "a$($i + 1)" ($i + 2) 30
        if ($rows.Count -ne ($i + 2)) { break }
    }
    Assert ($rows.Count -eq 3) "A2 ctrl+t twice made three tabs (got $($rows.Count))"
    if ($rows.Count -ne 3) { throw 'setup: could not build three tabs' }

    $base = @($rows)
    $basePids = @($base | ForEach-Object { $_.ShellPid })
    "    [A] tab pids: $($basePids -join ',')"
    # Distinct pids are what makes the position oracle able to say anything at
    # all; a zero would mean a pane whose shell is not agent-backed yet.
    $distinct = @($basePids | Sort-Object -Unique)
    Assert ($distinct.Count -eq 3 -and -not ($basePids -contains 0)) `
        'A3 each tab has its own live shell pid (oracle control)'

    $agents = @(Get-RunAgents)
    Assert ($agents.Count -eq 1) "A4 exactly one agent belongs to this run (got $($agents.Count))"
    if ($agents.Count -lt 1) { throw 'setup: no agent for this run' }
    $agentPid = [int]$agents[0].ProcessId
    $surf0 = Get-TerminalSurfaces $top
    Assert ($surf0.Count -eq 3) "A5 three terminal surfaces before the wedge (got $($surf0.Count))"

    # ================================================== B: wedge into recovery
    "== B: a wedge held past the settle window commits the app to recovery"
    $logMark = Get-AppLogLength
    Assert ((Set-AgentSuspended $agentPid $true) -eq 0) 'B1 the agent was suspended'

    # The app's own verdict, never a clock: reaching `reconnecting` costs 3
    # missed heartbeats 3s apart, and the settle window is 5s on top.
    Assert (Wait-AppLog $logMark 'before deciding on in-place recovery' 60) `
        'B2 the app noticed the drop and opened its settle watch'
    # This line is emitted immediately BEFORE the capture; everything after it
    # until the re-dial returns is the window the defect lives in.
    $recovering = Wait-AppLog $logMark 'recovering local windows in place' 60
    Assert $recovering 'B3 the wedge outlasted the settle window and recovery started'

    # ============================================ C: close tab 0 inside the race
    "== C: close tab 0 while the re-dial is still blocked on the frozen agent"
    #
    # EVERYTHING HERE IS A LATENCY BUDGET, and it is why the close goes through
    # `Run-CliOne` rather than `Run-Cli`. `findOrSpawn` gives up on a frozen
    # agent in seconds - it spawns a replacement, which the frozen holder's
    # single-instance guard refuses, and the dial ABORTS about two seconds later
    # - so the close has to be QUEUED, PUMPED and answered inside that window.
    # A `cmd /c ghoztty ...` costs two process launches to do it in one.
    $closeRc = $null
    if ($recovering) {
        # Served by `gui_pump` from inside `findOrSpawn` (T188), which is what
        # makes this reach the app at all: the GUI thread is not in its message
        # loop. The close needs nothing back from the agent - `closeChannel`
        # writes CLOSE and tears the pane down locally - so a frozen agent
        # cannot stall it, and the request RETURNING is proof it was served
        # while the dial was still in flight.
        $closeRc = Run-CliOne @('+close', "--target=$($base[0].Id)") "$tmp\close.txt" 20
    }
    Assert ($closeRc -eq 0) "C1 the close was served while the agent was still frozen (rc=$closeRc)"
    # The whole point of the arm: the shift must land BEFORE the rebuild. If the
    # dial had already returned, the rebuild saw a list that had not moved and
    # every assertion below would pass for free.
    $rebuiltEarly = (Read-AppLog $logMark) -match 'in-place recovery: rebuilt'
    Assert (-not $rebuiltEarly) 'C2 no rebuild had run yet - the close is inside the race window'

    # Resume at once, and only now: the dial has to still be probing when the
    # agent starts answering, or its budget expires and the abort path re-enters
    # recovery later with a FRESH capture - which would agree with the live list
    # again and measure nothing. D2 checks that never happened.
    Assert ((Set-AgentSuspended $agentPid $false) -eq 0) 'C3 the agent was resumed'

    # ================================================= D: the survivors' sessions
    "== D: each surviving tab is rebuilt from its OWN captured tree"
    $rebuilt = Wait-AppLog $logMark 'in-place recovery: rebuilt' 120
    if (-not $rebuilt) {
        "    [D1] recovery lines since the wedge:"
        foreach ($ln in ((Read-AppLog $logMark) -split "`r?`n")) {
            if ($ln -match 'recovery|local agent|re-dial|retry') { "      $ln" }
        }
    }
    Assert $rebuilt 'D1 the re-dial completed and the rebuild ran'

    # THE ANTI-VACUITY GATE. An ABORTED re-dial arms a retry, and the retry
    # re-enters `recoverLocalAgentInPlace` from the top - fresh capture, taken
    # after the close, agreeing with the live tab list again. Every assertion
    # below would then pass on a build with the defect. The rebuild has to be
    # the FIRST attempt's, working from the capture the close went behind.
    $tail = Read-AppLog $logMark
    $reentered = ($tail -match 'in-place recovery ABORTED') -or ($tail -match 'in-place recovery: retry')
    Assert (-not $reentered) `
        'D2 the rebuild came from the ORIGINAL capture - the re-dial never aborted and re-entered'

    # A rebuild replaces every terminal surface, so a fresh set is positive proof
    # one ran - the same oracle agent-recovery.ps1 uses, and what keeps D4 from
    # being satisfied by a recovery that quietly did nothing.
    $surf1 = @()
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        $surf1 = Get-TerminalSurfaces $top
        $reused = @($surf1 | Where-Object { $surf0 -contains $_ })
        if ($surf1.Count -eq 2 -and $reused.Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    }
    $reused = @($surf1 | Where-Object { $surf0 -contains $_ })
    Assert ($surf1.Count -eq 2 -and $reused.Count -eq 0) `
        "D3 two freshly rebuilt terminal surfaces (count=$($surf1.Count) reused=$($reused.Count))"

    $after = Wait-TabCount 'd0' 2 60
    $afterPids = @($after | ForEach-Object { $_.ShellPid })
    "    [D] before=$($basePids -join ',') after=$($afterPids -join ',')"
    $want = @($basePids[1], $basePids[2])
    $kept = ($after.Count -eq 2) -and ("$($afterPids -join ',')" -eq "$($want -join ',')")
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: asserting the survivors did NOT keep their sessions - this run MUST fail'
        Assert (-not $kept) 'D4(neg) the survivors kept their own sessions (inverted)'
    } else {
        Assert $kept "D4 each survivor kept its own session (want $($want -join ',') got $($afterPids -join ','))"
    }

    Assert ($null -ne (Get-Process -Id $appPid -ErrorAction SilentlyContinue)) `
        'D5 the app pid never changed - this was recovery, not a relaunch'

    Complete-TestBody  # T1039: the run reached the end of its body
} finally {
    # A suspended agent left behind would outlive the script.
    if ($agentPid -gt 0) { [void](Set-AgentSuspended $agentPid $false) }
    Kill-RepoInstances
    if ($td) { Remove-TestDesktop $td }
    $env:LOCALAPPDATA = $savedLocalAppData
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

# ------------------------------------------------- foreground discipline
$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

# A green run stamps the covered files (T783). Red leaves the stamp alone; a
# -NegativeControl run proves the harness discriminates, not the flow, so it
# must not stamp either.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard agent-recovery-tabs -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'agent-recovery-tabs'
