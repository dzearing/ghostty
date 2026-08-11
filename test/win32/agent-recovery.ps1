# T145 acceptance: IN-PLACE local-agent crash recovery.
#
# The defect: when the local ghoztty-agent dies while the GUI stays up, every
# persistent pane is frozen — its PTY went with the agent and the app's shared
# connection is dead. Before T145 the panes stayed dead until the user quit and
# relaunched, which is the exact failure session persistence exists to prevent.
#
# Measured by OUTCOME, never by log scraping:
#
#   A: baseline — a 2-pane window, both panes agent-backed and RESPONSIVE
#      (a marker typed in and read back), with the app pid and shell pids
#      recorded.
#   B: kill ONLY the agent. The app process must still be the SAME pid and must
#      still answer IPC — that is what makes this "in place" rather than a
#      relaunch. This section also proves the trap is ARMED: with the agent
#      gone, the panes are genuinely broken before recovery is asserted.
#   C: recovery — within the settle window + re-dial, the window is back to 2
#      panes and BOTH ARE RESPONSIVE AGAIN (a fresh marker round-trips). The
#      shell pids are NEW (the children died with the agent; the respawned
#      agent RELAUNCHes them), which is what separates a real rebuild from a
#      pane that merely still exists.
#   D: the e65cfa4d5 lesson — recovery must not KILL the sessions it recovers.
#      The alive-session count is 2 after recovery AND still 2 after the
#      departing surfaces have had time to finish tearing down (their DETACH
#      must never have been a CLOSE).
#   E: topology is preserved, not flattened: still one window, one tab, a split
#      of exactly two leaves, and the pane's registered IPC name still resolves.
#   G: T195 - the other half of the policy, and the one that keeps recovery from
#      being destructive: a link BLIP must be a no-op. The agent is SUSPENDED
#      until the app says it has started its settle watch, then RESUMED well
#      inside the 5s window, and nothing may move - same terminal surfaces, same
#      children, same sessions, same responsive pane.
#   H: the negative control for G - the identical blip HELD past the window, which
#      must rebuild. One variable between the two sections: how long the link
#      stayed down.
#
# The oracle for "did a rebuild run" is the set of GhozttyTerminal child windows,
# not the child pids. Recovery keeps the window HWND and replaces the SURFACES
# inside it, so a fresh set is positive proof a rebuild ran and an unchanged set
# is positive proof none did. Sections E7 and H6 take that same measurement where
# a rebuild IS expected, which is what makes G's "nothing changed" a claim rather
# than a tautology.
#
# Fully hermetic: a per-run $env:LOCALAPPDATA and GHOSTTY_LOCAL_AGENT_BIN, and
# it ONLY ever kills ghoztty / ghoztty-agent processes launched from the repo
# zig-out with THIS run's state dir — never the user's real release instance.
#
#   powershell -NoProfile -File test\win32\agent-recovery.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$root = Join-Path $env:TEMP "ghoztty-agent-recovery-$PID"

function Assert($name, $cond) {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name"; $script:failures++ }
}

# Kill ONLY zig-out ghoztty/agent processes (never the user's release build).
function Stop-TestProcs {
    foreach ($n in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$n'" |
            Where-Object { $_.CommandLine -like '*zig-out*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 700
}

# The agent processes belonging to THIS run (their command line names this
# run's state dir). Never the user's, never another test's.
function Get-RunAgents($tmp) {
    # Unary comma: PowerShell unwraps a 1-element array on return, and every
    # caller here does arithmetic on .Count.
    return , @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.CommandLine -like "*$tmp*" })
}
function Show-Agents($tmp, $tag) {
    "    [$tag] agents for this run:"
    foreach ($a in (Get-RunAgents $tmp)) { "      pid=$($a.ProcessId) $($a.CommandLine)" }
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

# Same, but the arguments are passed as a real ARRAY straight to the exe.
# `cmd /c` re-parses the whole line and eats the inner quotes, so an argument
# containing a space (`+send-keys ... "echo MARKER"`) arrives split in two —
# which is how the first run of this script reported a healthy pane as
# unresponsive. Nothing that carries a space may go through Run-Cli.
function Run-CliArgs($argv, $out, $timeoutSec = 15) {
    # persistence: on (default) - the agent under test only owns sessions when persistence is on.
    $p = Start-Process -FilePath $Exe -WindowStyle Hidden -PassThru `
        -ArgumentList $argv -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    # The TIMED WaitForExit returns before the Process object has published
    # ExitCode; the argument-less overload is what makes it readable. Without
    # this every call reads back $null and a healthy pane looks unresponsive.
    # Touching .Handle caches the process handle; without it PowerShell cannot
    # read ExitCode once the process has exited (it comes back empty, which
    # every caller reads as failure).
    $null = $p.Handle
    $p.WaitForExit()
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }

function Get-List($tmp, $tag, $timeoutSec = 12) {
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
# Every terminal leaf across every window/tab, in tree order.
function All-Leaves($tree) {
    $acc = @()
    foreach ($w in Windows-Of $tree) {
        foreach ($t in @($w.tabs)) { $acc += Leaves-Of $t.splits }
    }
    return , $acc
}
function Leaf-Count($tree) { return (All-Leaves $tree).Count }
# Terminal-only / viewer-only views of that list. A viewer leaf reports
# `"type": "viewer"` and none of the shell fields (no pid, no tty, no pwd).
#
# The `$all = ...` step is load-bearing: `All-Leaves` returns its list wrapped
# in a unary-comma array, and piping that function call DIRECTLY into
# Where-Object unrolls only the wrapper — so `$_` is the whole leaf array and
# `$_.type` member-enumerates into an array that is always truthy. Both filters
# then "matched", and every assertion below them passed vacuously. Assigning
# first unrolls the wrapper to the real list, which is what enumerates.
function Terminal-Leaves($tree) {
    $all = All-Leaves $tree
    return , @($all | Where-Object { $_.type -ne 'viewer' })
}
function Viewer-Leaves($tree) {
    $all = All-Leaves $tree
    return , @($all | Where-Object { $_.type -eq 'viewer' })
}

function Get-Sessions($tmp, $tag) {
    $code = Run-Cli '+sessions --json' "$tmp\sess-$tag.json" 12
    if ($code -ne 0) { return @() }
    try { $rows = Out-Text "$tmp\sess-$tag.json" | ConvertFrom-Json } catch { return @() }
    if ($null -eq $rows) { return @() }
    return @($rows)
}
function Alive-Rows($rows) { return @($rows | Where-Object { $_.alive -eq $true }) }
function Alive-Pids($rows) {
    return , @(Alive-Rows $rows | ForEach-Object { [int]$_.pid } | Sort-Object)
}
function Wait-AliveCount($tmp, $tag, $target, $timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $rows = @()
    while ((Get-Date) -lt $deadline) {
        $rows = Get-Sessions $tmp $tag
        if ((Alive-Rows $rows).Count -eq $target) { return , $rows }
        Start-Sleep -Milliseconds 500
    }
    return , $rows
}

# THE liveness oracle for a pane: type a unique marker and read it back. A pane
# whose PTY is gone still EXISTS in +list — only a round-trip proves it works.
function Test-PaneResponsive($tmp, $target, $tag, $timeoutSec = 20) {
    $marker = "T145x$($tag)x$(Get-Random -Maximum 999999)"
    # The command is assembled from SPACE-FREE positional arguments plus the
    # `Space` key name. `+send-keys` concatenates its positionals, so this types
    # exactly `echo <marker>` — and nothing in the chain (PowerShell, the exe's
    # argv, cmd) ever sees a quoted argument to re-quote. A quoted `"echo M"`
    # reaches cmd WITH its quotes and dies as "not recognized as an internal or
    # external command", which is how the first run of this script scored a
    # working pane as broken.
    Run-CliArgs @('+send-keys', "--target=$target", 'echo', 'Space', $marker, 'Enter') `
        "$tmp\keys-$tag.txt" 12 | Out-Null
    # Deliberately NOT gated on send-keys' exit code: the marker coming back is
    # the oracle, and a stricter gate only adds a way for the harness to score
    # a working pane as broken.
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        # A wide line budget, because the wrap above means one MARKER costs one
        # line per character. At --lines=25 the marker fell off the top of the
        # window and the oracle reported a working pane as dead.
        $rc = Run-Cli "+read --name=$target --lines=300" "$tmp\read-$tag.txt" 12
        if ($rc -eq 0) {
            # The window is minimized, so a split pane can be a couple of
            # columns wide and the terminal WRAPS the echoed marker across
            # lines — it is really there, one character per row. Collapsing all
            # whitespace is what makes the oracle measure "did the shell run
            # it?" instead of "how wide is the pane?" (the marker is
            # deliberately space-free so this cannot create a false positive).
            $txt = (Out-Text "$tmp\read-$tag.txt") -replace "`0", '' -replace '\s', ''
            if ($txt -match [regex]::Escape($marker)) { return $true }
        }
        Start-Sleep -Milliseconds 600
    }
    return $false
}

# --- T195: suspend/resume a process, and enumerate the app's pane surfaces ---
#
# SUSPENDING is how a link BLIP is induced with no new test hook and no
# debugger: a frozen agent answers no heartbeats, so the app's transport FSM
# walks to `reconnecting` exactly as it does for a real drop
# (`remote/connection.zig` §5.1, 3 missed heartbeats at 3s), and a resume puts it
# back on the very next authentic packet.
#
# ENUMERATING is the outcome oracle. In-place recovery keeps the window HWND and
# replaces the surfaces inside it (`rebuildTabLeavesInPlace` ->
# `replaceTabLeaf`), so the tab's `GhozttyTerminal` child windows are a fresh set
# after a rebuild and the same set after a no-op.
#
# Child PIDS deliberately are NOT the oracle here, and that is a correction to
# the plan T195 was filed with. Pids answer the KILL (the children died with the
# agent, so the respawned one relaunches them - section C), but they cannot
# answer a SUSPEND: a frozen agent never loses a child, so a rebuild after a blip
# would re-ATTACH the very same pids and read as "nothing happened". The surface
# set separates the two cases under either stimulus.
if (-not ('GhozttyRecoveryNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class GhozttyRecoveryNative {
    [DllImport("ntdll.dll")] static extern int NtSuspendProcess(IntPtr h);
    [DllImport("ntdll.dll")] static extern int NtResumeProcess(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);

    delegate bool EnumProc(IntPtr hwnd, IntPtr lparam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lparam);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr lparam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder buf, int max);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr hwnd, out int pid);

    const int PROCESS_SUSPEND_RESUME = 0x0800;

    static string ClassOf(IntPtr h) {
        StringBuilder sb = new StringBuilder(256);
        int n = GetClassName(h, sb, sb.Capacity);
        return n > 0 ? sb.ToString() : "";
    }

    // 0 on success. -1 means the process could not be opened at all (gone, or
    // no PROCESS_SUSPEND_RESUME right), which is a different failure from a
    // suspend that was refused.
    public static int SetSuspended(int pid, bool suspended) {
        IntPtr h = OpenProcess(PROCESS_SUSPEND_RESUME, false, pid);
        if (h == IntPtr.Zero) return -1;
        int rc = suspended ? NtSuspendProcess(h) : NtResumeProcess(h);
        CloseHandle(h);
        return rc;
    }

    // Every window of class `cls` owned by `pid` - top-levels and all their
    // descendants - sorted, so two samples compare as sets.
    public static long[] WindowsOfClass(int pid, string cls) {
        List<long> acc = new List<long>();
        EnumWindows(delegate(IntPtr top, IntPtr lp) {
            int owner;
            GetWindowThreadProcessId(top, out owner);
            if (owner == pid) {
                if (ClassOf(top) == cls) acc.Add(top.ToInt64());
                EnumChildWindows(top, delegate(IntPtr child, IntPtr lp2) {
                    if (ClassOf(child) == cls) acc.Add(child.ToInt64());
                    return true;
                }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);
        acc.Sort();
        return acc.ToArray();
    }
}
'@
}

function Set-AgentSuspended($procId, [bool]$suspended) {
    return [GhozttyRecoveryNative]::SetSuspended([int]$procId, $suspended)
}
# Unary comma: every caller does arithmetic on .Count, and PowerShell unwraps a
# one-element array return into a scalar whose .Count is $null.
function Get-TerminalSurfaces($procId) {
    return , @([GhozttyRecoveryNative]::WindowsOfClass([int]$procId, 'GhozttyTerminal'))
}

# The settled surface set after a rebuild. The departing surfaces are destroyed
# ASYNCHRONOUSLY (the same teardown window section D waits out), so a sample
# taken the instant the rebuild finishes legitimately shows FOUR terminal
# surfaces - the two fresh ones and the two on their way out. Asserting on the
# first sample read that as "recovery reused a surface", the exact opposite of
# what had happened, and did so on 2 runs in 5. Waiting for the set to settle is
# what makes the instrument measure the rebuild instead of the teardown's clock.
function Wait-SurfacesReplaced($procId, $before, $want, $timeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $now = Get-TerminalSurfaces $procId
    while ((Get-Date) -lt $deadline) {
        $now = Get-TerminalSurfaces $procId
        $reused = @($now | Where-Object { $before -contains $_ })
        if ($now.Count -eq $want -and $reused.Count -eq 0) { return , $now }
        Start-Sleep -Milliseconds 500
    }
    return , $now
}

# The app's stderr. A Debug build links the CONSOLE subsystem, so std.log lands
# there line by line (each line is flushed), which is what makes "has the settle
# watch started yet?" answerable without a fixed sleep. It is a TIMING signal,
# never an oracle - every assertion below is an outcome.
function Get-AppLogText {
    if (-not $appLog) { return '' }
    if (-not (Test-Path $appLog)) { return '' }
    $t = $null
    try { $t = Get-Content $appLog -Raw -ErrorAction Stop } catch { return '' }
    if ($null -eq $t) { return '' }
    return $t
}
function Get-AppLogLength { return (Get-AppLogText).Length }
function Read-AppLog($from) {
    $t = Get-AppLogText
    if ($from -ge $t.Length) { return '' }
    return $t.Substring($from)
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

# T441: a private IPC endpoint, and it is NOT covered by the LOCALAPPDATA
# redirect above. The endpoint a CLI dials comes from the pane's baked
# `$GHOZTTY_IPC_SOCKET` unless a suffix outranks it, so without this every
# Run-Cli below would answer from the user's installed release.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'agentrec')
Assert-GhozttyPrivateEndpoint -Exe $Exe

# ============================================================================
"== A: baseline - a 2-pane agent-backed window, both panes responsive"
# ============================================================================
# persistence: on (default) - the agent under test only owns sessions when persistence is on.
# stderr goes to a file so section G can tell WHEN the app entered its settle
# watch (a Debug build logs to stderr; see Get-AppLogText). Redirecting to a
# FILE, never a pipe: nothing here drains a pipe, and a full one would block the
# app's logger.
$appLog = Join-Path $tmp 'app.err'
Start-Process -FilePath $Exe -WindowStyle Minimized -ArgumentList @('--title=t145-recovery') `
    -RedirectStandardOutput (Join-Path $tmp 'app.out') -RedirectStandardError $appLog | Out-Null

$appProc = $null
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    $tree = Get-List $tmp 'a0' 10
    if ((Leaf-Count $tree) -ge 1) {
        $appProc = @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
            Where-Object { $_.CommandLine -like '*t145-recovery*' })[0]
        break
    }
    Start-Sleep -Milliseconds 500
}
Assert "A1 the GUI came up and answers +list" ($null -ne $appProc)
if ($null -eq $appProc) {
    "AGENT-RECOVERY: $script:failures FAILURE(S)"
    $env:LOCALAPPDATA = $savedLocalAppData
    exit 1
}
$appPid = [int]$appProc.ProcessId
Assert-GhozttyIsolated -Exe $Exe

# Name the first pane, then split it so the topology under test is a real tree.
$firstLeaf = (All-Leaves (Get-List $tmp 'a1' 10))[0]
Run-Cli "+split --pane=$($firstLeaf.id) --name=t145b --direction=right" "$tmp\split.txt" 15 | Out-Null

$treeA = $null
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline) {
    $treeA = Get-List $tmp 'a2' 10
    if ((Leaf-Count $treeA) -eq 2) { break }
    Start-Sleep -Milliseconds 500
}
Assert "A2 the window has exactly 2 panes" ((Leaf-Count $treeA) -eq 2)

# T399: put a VIEWER pane in the same tab. It rides no agent session, so the
# agent going down cannot have invalidated it — section F measures that recovery
# leaves it strictly alone.
$viewFile = Join-Path $tmp 'view.md'
Set-Content -Path $viewFile -Value "# t399`n`nviewer pane content." -Encoding utf8
Run-CliArgs @('+split', "--pane=$($firstLeaf.id)", '--direction=down',
    '--name=t399v', "--view=$viewFile") "$tmp\viewsplit.txt" 20 | Out-Null

$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline) {
    $treeA = Get-List $tmp 'a2v' 10
    if ((Viewer-Leaves $treeA).Count -eq 1) { break }
    Start-Sleep -Milliseconds 500
}
$viewerA = @(Viewer-Leaves $treeA)[0]
Assert "A2b a viewer pane joined the tab" ($null -ne $viewerA)
Assert "A2c the tab now holds 2 terminals and 1 viewer" (
    (Terminal-Leaves $treeA).Count -eq 2 -and (Viewer-Leaves $treeA).Count -eq 1)

$paneA = (Terminal-Leaves $treeA)[0]
$rowsA = Wait-AliveCount $tmp 'a' 2 25
Assert "A3 both panes are agent-backed (2 live sessions)" ((Alive-Rows $rowsA).Count -eq 2)
$pidsA = Alive-Pids $rowsA
Assert "A4 both live sessions report a real child pid" (@($pidsA | Where-Object { $_ -gt 0 }).Count -eq 2)

Assert "A5 the named pane is responsive before the crash" (Test-PaneResponsive $tmp 't145b' 'a' 25)

# The pane surfaces as they are BEFORE anything drops. Section E7 compares
# against this across the kill (they must all be new); section G compares its own
# baseline across a blip (they must all be the same).
$surfA = Get-TerminalSurfaces $appPid
if ($surfA.Count -ne 2) { "    [A6] terminal surfaces: $($surfA -join ',')" }
Assert "A6 the two terminal panes have two terminal surfaces" ($surfA.Count -eq 2)

# ============================================================================
"== B: kill ONLY the agent - the app survives with the SAME pid"
# ============================================================================
$agents = Get-RunAgents $tmp
if ($agents.Count -ne 1) { Show-Agents $tmp 'B' }
Assert "B1 exactly one agent belongs to this run" ($agents.Count -eq 1)
$agentPid = if ($agents.Count -ge 1) { [int]$agents[0].ProcessId } else { 0 }
foreach ($a in $agents) { Stop-Process -Id $a.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 800

Assert "B2 the agent process is gone" (
    $null -eq (Get-Process -Id $agentPid -ErrorAction SilentlyContinue))

$stillHere = Get-Process -Id $appPid -ErrorAction SilentlyContinue
Assert "B3 the APP is still alive with the same pid (in place, not a relaunch)" ($null -ne $stillHere)

# The trap must be ARMED: with the agent dead the panes are genuinely broken.
# If this passes, the section-C assertions would be vacuous.
Assert "B4 the panes are BROKEN before recovery (trap armed)" (
    -not (Test-PaneResponsive $tmp 't145b' 'b' 4))

# ============================================================================
"== C: recovery - the panes come back, on NEW children, with no relaunch"
# ============================================================================
# Settle window (5s) + re-dial/spawn (<=2s) + agent restore + RELAUNCH.
$rowsC = Wait-AliveCount $tmp 'c' 2 45
Assert "C1 two sessions are alive again on the respawned agent" (
    (Alive-Rows $rowsC).Count -eq 2)

$newAgents = Get-RunAgents $tmp
Assert "C2 a fresh agent is running for this run" ($newAgents.Count -ge 1)
Assert "C3 it is NOT the process that was killed" (
    @($newAgents | Where-Object { [int]$_.ProcessId -eq $agentPid }).Count -eq 0)

$stillHere = Get-Process -Id $appPid -ErrorAction SilentlyContinue
Assert "C4 the app pid never changed across recovery" ($null -ne $stillHere)

$pidsC = Alive-Pids $rowsC
$newPids = @($pidsC | Where-Object { $pidsA -notcontains $_ })
if ($newPids.Count -ne 2) { "    [C5] before=$($pidsA -join ',') after=$($pidsC -join ',')" }
Assert "C5 the shells are NEW children (the old ones died with the agent)" (
    $newPids.Count -eq 2)

Assert "C6 the named pane is RESPONSIVE again - the actual defect" (
    Test-PaneResponsive $tmp 't145b' 'c' 30)

# ============================================================================
"== D: recovery must not kill the sessions it recovers (e65cfa4d5)"
# ============================================================================
# The departing surfaces tear down asynchronously. If any of them had been
# marked close-intent, its CLOSE would land AFTER the new panes attached and
# terminate a session a live pane is using. Waiting here is the point.
Start-Sleep -Seconds 6
$rowsD = Get-Sessions $tmp 'd'
Assert "D1 still exactly 2 live sessions after the old surfaces finished" (
    (Alive-Rows $rowsD).Count -eq 2)
Assert "D2 the pane still works after the teardown window" (
    Test-PaneResponsive $tmp 't145b' 'd' 20)

# ============================================================================
"== E: the topology was rebuilt, not flattened"
# ============================================================================
$treeE = Get-List $tmp 'e' 12
Assert "E1 still exactly one window" ((Windows-Of $treeE).Count -eq 1)
Assert "E2 still exactly 2 terminals in a split" ((Terminal-Leaves $treeE).Count -eq 2)
$tabsE = @((Windows-Of $treeE)[0].tabs)
Assert "E3 still exactly one tab" ($tabsE.Count -eq 1)
Assert "E4 the tab's root is a split, not a lone leaf" ($tabsE[0].splits.type -eq 'split')
# The IPC name survived: it is re-registered onto the rebuilt pane, so a target
# that worked before the crash still resolves after it.
$rcE = Run-Cli "+read --name=t145b --lines=1" "$tmp\read-e.txt" 12
Assert "E5 the pane's IPC name still resolves after the rebuild" ($rcE -eq 0)
# The stable pane id (T113) is PRESERVED across the rebuild, exactly as it is
# across a launch restore: the id is baked into the shell as $GHOZTTY_PANE_ID,
# so a recovery that minted a fresh one would leave every pane unable to name
# itself. (The first version of this script asserted the opposite — that a
# rebuilt pane is a "new" surface — which would have passed only on a build
# that broke the guarantee.)
$paneE = (Terminal-Leaves $treeE)[0]
Assert "E6 the rebuilt pane kept its stable pane id" ($paneE.id -eq $paneA.id)

# The CONTROL for section G, taken with G's own instrument. A rebuild keeps the
# window HWND and replaces the surfaces inside it, so nothing here may be one of
# the surfaces from A - and that is what makes "the surfaces are unchanged" a
# measurement of no-rebuild rather than of a blunt instrument.
$surfE = Wait-SurfacesReplaced $appPid $surfA 2
$reusedE = @($surfE | Where-Object { $surfA -contains $_ })
if ($reusedE.Count -ne 0) { "    [E7] before=$($surfA -join ',') after=$($surfE -join ',')" }
Assert "E7 recovery REPLACED every terminal surface (the control for G)" (
    $surfE.Count -eq 2 -and $reusedE.Count -eq 0)

# ============================================================================
"== F: T399 - the viewer pane was never touched by the recovery"
# ============================================================================
# A viewer holds no agent session, so a dropped agent link cannot have
# invalidated it. Recovery used to replace the tab's WHOLE tree, which destroyed
# the WebView2 host and re-opened the page — losing scroll position and in-page
# state for an event that had nothing to do with the pane.
#
# The pane id is the cheap observable, and it is a real one BECAUSE a re-created
# viewer draws a fresh random id (`ViewerPane.create`). Sections C and E already
# established that recovery genuinely ran and rebuilt the terminals on new
# children, so an untouched viewer here is a spared pane, not a skipped test.
$viewerE = @(Viewer-Leaves $treeE)
Assert "F1 the viewer pane is still in the tab" ($viewerE.Count -eq 1)
Assert "F2 it kept its stable pane id - it was never re-created" (
    $viewerE.Count -eq 1 -and $viewerE[0].id -eq $viewerA.id)
Assert "F3 it still shows the file it was opened with" (
    $viewerE.Count -eq 1 -and $viewerE[0].url -like '*view.md')
# And it is a live viewer, not a husk: `+reload` is viewer-only (it rejects a
# terminal pane outright), so a clean exit means the pane is still a working
# viewer answering to the name it was registered under before the crash.
$rcF = Run-Cli "+reload --target=t399v" "$tmp\reload-f.txt" 12
Assert "F4 the viewer still answers +reload by its registered name" ($rcF -eq 0)

# ============================================================================
"== G: T195 - a link BLIP inside the settle window must change nothing"
# ============================================================================
# The destructive half of recovery is what sections B-E measure. THIS is the half
# that keeps it from being destructive: `agent_recovery.settle_ms` (5s) exists
# because Mac shipped in-place recovery without it and the 2026-07-21 incident
# (`e65cfa4d5`) had it fire on a link that healed 27ms later, destroying the
# sessions it had just re-attached. The policy is unit-tested in
# `agent_recovery.zig`; what is measured here is the WIRING - that a heal inside
# the window really does reach `link_recovered` and really does leave the panes
# alone.
$settleMs = 5000    # agent_recovery.settle_ms

$agentsG = Get-RunAgents $tmp
if ($agentsG.Count -ne 1) { Show-Agents $tmp 'G' }
Assert "G1 exactly one agent belongs to this run before the blip" ($agentsG.Count -eq 1)
$agentPidG = if ($agentsG.Count -ge 1) { [int]$agentsG[0].ProcessId } else { 0 }

$rowsG0 = Wait-AliveCount $tmp 'g0' 2 25
$pidsG0 = Alive-Pids $rowsG0
$surfG0 = Get-TerminalSurfaces $appPid
Assert "G2 two live sessions and two terminal surfaces before the blip" (
    (Alive-Rows $rowsG0).Count -eq 2 -and $surfG0.Count -eq 2)

# Everything after this point is judged against log text written from here on,
# so a line from the section-C recovery cannot be mistaken for a fresh one.
$logMark = Get-AppLogLength
Assert "G3 the agent was suspended" (
    $agentPidG -gt 0 -and (Set-AgentSuspended $agentPidG $true) -eq 0)

# Wait for the app's OBSERVABLE state, never a fixed sleep: reaching
# `reconnecting` takes 3 missed heartbeats 3s apart, and a fixed wait would race
# the very window under test. The log line is the timing signal - it is emitted
# as the settle window opens, so the resume below is timed from the window's own
# start rather than from the suspend.
$watchSeen = $false
$deadline = (Get-Date).AddSeconds(45)
while ((Get-Date) -lt $deadline) {
    if ((Read-AppLog $logMark) -match 'before deciding on in-place recovery') {
        $watchSeen = $true
        break
    }
    Start-Sleep -Milliseconds 100
}
$watchAt = Get-Date
# Resume unconditionally, including on the timeout path: a suspended agent left
# behind would poison every section after this one and outlive the script.
$resumeRc = Set-AgentSuspended $agentPidG $false
$blipMs = [int]((Get-Date) - $watchAt).TotalMilliseconds

Assert "G4 the app noticed the drop and opened its settle watch" $watchSeen
Assert "G5 the agent was resumed" ($resumeRc -eq 0)
if ($blipMs -ge 2000) { "    [G6] resume landed +${blipMs}ms into a ${settleMs}ms window" }
# The heal itself costs one PING/PONG round-trip after the resume, so the resume
# must land with room to spare inside the window rather than merely inside it.
Assert "G6 the resume landed early in the ${settleMs}ms settle window" ($blipMs -lt 2000)

# Past the window plus several poll ticks (`agent_recovery.poll_ms` = 250): if a
# verdict were going to trigger recovery, it has by now.
Start-Sleep -Seconds 8

$tailG = Read-AppLog $logMark
Assert "G7 the link healed on its own - the app says no recovery was needed" (
    $tailG -match 'link recovered on its own')
Assert "G8 no in-place recovery was triggered by the blip" (
    $tailG -notmatch 'recovering local windows in place')

# The outcome, and the one that would still be true if every log line were
# missing: recovery replaces surfaces (E7), so surfaces that are still the same
# objects were never rebuilt.
$surfG1 = Get-TerminalSurfaces $appPid
$sameG = ($surfG1.Count -eq $surfG0.Count) -and
    (@($surfG1 | Where-Object { $surfG0 -notcontains $_ }).Count -eq 0)
if (-not $sameG) { "    [G9] before=$($surfG0 -join ',') after=$($surfG1 -join ',')" }
Assert "G9 every terminal SURFACE survived the blip - nothing was rebuilt" $sameG

$rowsG1 = Wait-AliveCount $tmp 'g1' 2 25
$pidsG1 = Alive-Pids $rowsG1
Assert "G10 still exactly 2 live sessions after the blip" ((Alive-Rows $rowsG1).Count -eq 2)
if ("$($pidsG1 -join ',')" -ne "$($pidsG0 -join ',')") {
    "    [G11] before=$($pidsG0 -join ',') after=$($pidsG1 -join ',')"
}
Assert "G11 the shells are the SAME children" (
    "$($pidsG1 -join ',')" -eq "$($pidsG0 -join ',')")
Assert "G12 the app pid never changed across the blip" (
    $null -ne (Get-Process -Id $appPid -ErrorAction SilentlyContinue))

# And the pane is a working pane, not a picture of one: a blip that left the
# panes intact but wedged would satisfy every assertion above it.
Assert "G13 the pane is still responsive after the blip" (
    Test-PaneResponsive $tmp 't145b' 'g' 30)

$treeG = Get-List $tmp 'g' 12
$viewerG = @(Viewer-Leaves $treeG)
Assert "G14 the viewer pane is untouched by the blip" (
    $viewerG.Count -eq 1 -and $viewerG[0].id -eq $viewerA.id)
Assert "G15 the topology is unchanged: 2 terminals in one window" (
    (Windows-Of $treeG).Count -eq 1 -and (Terminal-Leaves $treeG).Count -eq 2)

# ============================================================================
"== H: the negative control - the SAME blip, held past the window, DOES rebuild"
# ============================================================================
# Section G is only a claim if the same stimulus can produce the other answer.
# So: suspend again, and this time hold it until the app has said it is
# recovering, then resume. Everything is identical to G except the duration,
# which is the one variable the settle window is a function of.
#
# The resume is triggered by the app's own decision rather than by a clock, for
# the same reason G's is: recovery re-dials, and an agent still frozen when that
# dial runs would make this measure a WEDGED agent instead of a late heal.
#
# And note what H does NOT get to assert: the children are the same pids here as
# in G. A suspended agent never loses a child, so a rebuild re-ATTACHes the very
# sessions it had - which is exactly why the surface set, and not the pid set, is
# the oracle for both sections.
$logMarkH = Get-AppLogLength
$surfH0 = Get-TerminalSurfaces $appPid
$pidsH0 = Alive-Pids (Get-Sessions $tmp 'h0')
Assert "H1 two terminal surfaces before the second blip" ($surfH0.Count -eq 2)
Assert "H2 the agent was suspended again" (
    (Set-AgentSuspended $agentPidG $true) -eq 0)

$recoverSeen = $false
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    if ((Read-AppLog $logMarkH) -match 'recovering local windows in place') {
        $recoverSeen = $true
        break
    }
    Start-Sleep -Milliseconds 100
}
$resumeRcH = Set-AgentSuspended $agentPidG $false
Assert "H3 the agent was resumed" ($resumeRcH -eq 0)
Assert "H4 a drop held past the window DID trigger in-place recovery" $recoverSeen

# Recovery re-dials, re-attaches and rebuilds; give it the same room section C
# gives it.
$rowsH = Wait-AliveCount $tmp 'h' 2 45
Assert "H5 two sessions are alive after the rebuild" ((Alive-Rows $rowsH).Count -eq 2)

$surfH1 = Wait-SurfacesReplaced $appPid $surfH0 2
$reusedH = @($surfH1 | Where-Object { $surfH0 -contains $_ })
if ($reusedH.Count -ne 0) { "    [H6] before=$($surfH0 -join ',') after=$($surfH1 -join ',')" }
Assert "H6 every terminal surface was REPLACED - G's instrument reads both ways" (
    $surfH1.Count -eq 2 -and $reusedH.Count -eq 0)

# The documented negative result, asserted so it cannot quietly stop being true:
# pids are blind to this rebuild.
$pidsH1 = Alive-Pids $rowsH
Assert "H7 the children are UNCHANGED across a real rebuild (pids cannot judge this)" (
    "$($pidsH1 -join ',')" -eq "$($pidsH0 -join ',')")

Assert "H8 the pane is responsive again after the rebuild" (
    Test-PaneResponsive $tmp 't145b' 'h' 30)
$treeH = Get-List $tmp 'h' 12
Assert "H9 the topology survived: one window, 2 terminals, the viewer intact" (
    (Windows-Of $treeH).Count -eq 1 -and (Terminal-Leaves $treeH).Count -eq 2 -and
    @(Viewer-Leaves $treeH).Count -eq 1)

# ============================================================================
Stop-TestProcs
$env:LOCALAPPDATA = $savedLocalAppData
if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue

if ($script:failures -eq 0) { "AGENT-RECOVERY: ALL PASS ($script:passes)"; exit 0 }
"AGENT-RECOVERY: $script:failures FAILURE(S) / $script:passes passed"
exit 1
