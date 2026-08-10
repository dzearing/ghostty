# T188 acceptance: the app must ANSWER IPC while it is still restoring, not
# only after.
#
# THE DEFECT. An IPC request is never served by the listener thread that
# accepted it - `IpcServer.listen` posts WM_APP_IPC to the message-only window
# and blocks on the request's `done` event until the GUI thread runs the
# handler. `App.run` called `restoreSessionLayout()` straight through before the
# message loop and pumped nothing while it did, so for the whole restore a
# client connected and then waited: measured 451 ms for a healthy 5-pane
# restore and 10 755 ms against an agent SUSPENDED across the relaunch. To a
# caller - the upgrade script that reported this, or any agent tooling - that is
# indistinguishable from "no running Ghoztty instance".
#
# THE ORACLE, and why it is a real one. `+list --json` answers with the windows
# that exist RIGHT NOW, so a startup that answers early answers with FEWER
# windows than it ends up with. Each arm therefore records two numbers from one
# polling loop:
#
#   t_answer  - elapsed to the first `+list --json` that parses at all
#   t_window  - elapsed to the first one that reports >= 1 window
#
# Before the fix those two collapse onto each other: nothing answers until the
# restore is done, by which point the windows are there. After it they separate,
# and the gap IS the interval that used to be a blackout. Arm C is the
# load-bearing one because the suspended agent makes that interval seconds wide;
# arm B's healthy restore is a few hundred milliseconds by nature, so it is
# scored on a ceiling rather than on a gap it cannot reliably show.
#
# Timing is measured from the moment the app process is started, with the poll
# loop issuing `+list` back-to-back and no sleep between attempts, so the
# resolution is one CLI startup (~150 ms) - far finer than the seconds these
# arms discriminate.
#
# Runs on a BACKGROUND Win32 desktop so it never takes the user's foreground;
# hermetic via a per-run LOCALAPPDATA + GHOSTTY_LOCAL_AGENT_BIN + a private IPC
# pipe suffix, and it only ever kills ghoztty / ghoztty-agent processes launched
# from the repo zig-out.
#
#   powershell -NoProfile -File test\win32\ipc-startup-latency.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    # Invert arm C's central assertion. A run with this flag MUST fail - it is
    # how we prove the arm can fail at all, rather than passing because the
    # measurement never happened.
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
$root = Join-Path $env:TEMP "ghoztty-startup-latency-$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')

function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

# NtSuspendProcess: the only way from PowerShell to freeze the agent WITHOUT
# killing it, which is the whole point of arm C - a killed agent is dialed and
# refused fast, a suspended one holds the single-instance guard and makes every
# dial burn its full handshake timeout.
if (-not ('GhozttyProcSuspend' -as [type])) {
    Add-Type -Namespace '' -Name 'GhozttyProcSuspend' -MemberDefinition @'
[DllImport("ntdll.dll", SetLastError = true)]
public static extern int NtSuspendProcess(IntPtr hProcess);
[DllImport("ntdll.dll", SetLastError = true)]
public static extern int NtResumeProcess(IntPtr hProcess);
'@
}
function Suspend-Pid($procId) {
    try {
        $p = [System.Diagnostics.Process]::GetProcessById($procId)
        return ([GhozttyProcSuspend]::NtSuspendProcess($p.Handle) -eq 0)
    } catch { return $false }
}
function Resume-Pid($procId) {
    try {
        $p = [System.Diagnostics.Process]::GetProcessById($procId)
        return ([GhozttyProcSuspend]::NtResumeProcess($p.Handle) -eq 0)
    } catch { return $false }
}

function Stop-TestProcs {
    foreach ($n in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$n'" |
            Where-Object { $_.CommandLine -like '*zig-out*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 700
}
function Stop-AppOnly {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 900
}
function Get-RunAgentPid($t) {
    $a = @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.CommandLine -like "*$t*" })
    if ($a.Count -eq 0) { return 0 }
    return [int]$a[0].ProcessId
}
function Wait-AgentPid($t, $timeoutSec = 25) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $p = Get-RunAgentPid $t
        if ($p -ne 0) { return $p }
        Start-Sleep -Milliseconds 400
    }
    return (Get-RunAgentPid $t)
}

function Run-CliArgs($argv, $out, $timeoutSec = 15) {
    # persistence: n/a - a CLI invocation, which opens no window.
    $p = Start-Process -FilePath $Exe -WindowStyle Hidden -PassThru `
        -ArgumentList $argv -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    # Cache the handle BEFORE the process can exit - reading .ExitCode after an
    # uncached exit returns empty and scores a working CLI as a failure.
    $null = $p.Handle
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    $p.WaitForExit()
    return $p.ExitCode
}
function Out-Text($f) { if (Test-Path $f) { Get-Content $f -Raw } else { '' } }
function Get-List($tag, $timeoutSec = 20) {
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
function Wait-Leaves($tag, $target, $timeoutSec = 45) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $tree = Get-List $tag
        if ((All-Leaves $tree).Count -ge $target) { return $tree }
        Start-Sleep -Milliseconds 400
    }
    return (Get-List "$tag-last")
}

<#
Start the app and, from the same instant, hammer `+list --json` until it both
answers and reports a window. Returns the two elapsed times in ms (or -1 for a
number that never happened) plus the pane count the settled list reported.

The stopwatch starts BEFORE the launch, so both numbers include process startup
- which is what a caller experiences and what the pre-fix measurements in T188
counted too.
#>
function Measure-Startup($tag, $extraArgs = @(), $windowTimeoutSec = 60) {
    $script:AppLog = Join-Path $tmp "applog-$tag.err.txt"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # persistence: on (default) - the interval being measured IS the restore, so a launch with nothing to restore would measure nothing.
    $app = Start-OnTestDesktop -Exe $Exe -Arguments $extraArgs -StdErr $script:AppLog
    $tAnswer = -1
    $tWindow = -1
    $panes = 0
    $deadline = (Get-Date).AddSeconds($windowTimeoutSec)
    $i = 0
    while ((Get-Date) -lt $deadline) {
        $i++
        $tree = Get-List "$tag-$i"
        if ($null -ne $tree) {
            if ($tAnswer -lt 0) { $tAnswer = [int]$sw.ElapsedMilliseconds }
            # A window that lists no pane yet is still mid-construction, and the
            # question this measures is when the startup's windows EXIST — so
            # settle on the first list that reports a real pane.
            $wins = @(Windows-Of $tree)
            $leaves = (All-Leaves $tree).Count
            if ($wins.Count -ge 1 -and $leaves -ge 1) {
                $tWindow = [int]$sw.ElapsedMilliseconds
                $panes = $leaves
                break
            }
        }
    }
    $sw.Stop()
    return [pscustomobject]@{
        Pid = [int]$app.Pid; Answer = $tAnswer; Window = $tWindow; Panes = $panes
    }
}

# A new state dir needs a new AGENT: the debug agent's single-instance guard is
# keyed on the pipe name, which carries no state-dir component, so an agent left
# over from the previous arm keeps answering and the app never spawns one
# against the fresh dir. (Measured: arm B then restored nothing and scored its
# own setup a FAIL.) Killing the app alone is a DIFFERENT operation and stays
# that way — arms B and C depend on the agent surviving their relaunch.
function Reset-State($arm) {
    Stop-TestProcs
    $script:tmp = Join-Path $root "run-$arm"
    New-Item -ItemType Directory -Force (Join-Path $script:tmp 'ghoztty\local-agent-debug') | Out-Null
    $env:LOCALAPPDATA = $script:tmp
}

Stop-TestProcs
$tmp = Join-Path $root 'run'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$saved = @{ lad = $env:LOCALAPPDATA; bin = $env:GHOSTTY_LOCAL_AGENT_BIN; pipe = $env:GHOZTTY_PIPE_SUFFIX }
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $AgentExe
# Isolate the IPC endpoint AND check the build mode (T350/T441): every `+list`
# below is an oracle, and a release build under a private suffix would still
# dial the agent holding the user's live sessions.
Set-GhozttyTestIsolation -Tag 'startlat'
Assert-GhozttyPrivateEndpoint -Exe $Exe

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$suspended = 0

try {

Assert 'setup: ghoztty exe exists in zig-out' (Test-Path $Exe)
Assert 'setup: agent exe exists in zig-out' (Test-Path $AgentExe)

# ============================================================================
Say '== A: cold start, no manifest - the floor everything else is read against'
# ============================================================================
Reset-State 'a'
$a = Measure-Startup 'cold'
Say "   cold start: first answer $($a.Answer)ms, first window $($a.Window)ms"
Assert 'A1 a cold start answers +list at all' ($a.Answer -ge 0)
Assert 'A2 a cold start opens its window' ($a.Window -ge 0)
Assert 'A3 the cold-start answer is prompt (< 6s)' ($a.Answer -ge 0 -and $a.Answer -lt 6000)
Stop-AppOnly

# ============================================================================
Say '== B: healthy 5-pane restore - IPC answers, and the layout still comes back'
# ============================================================================
Reset-State 'b'
$b0 = Measure-Startup 'bbuild'
Assert 'B1 setup: the build instance came up' ($b0.Window -ge 0)
Run-CliArgs @('+new-window', '--target=sl') "$tmp\nw.txt" 25 | Out-Null
foreach ($n in @('p2', 'p3', 'p4')) {
    Run-CliArgs @('+split', '--target=sl', "--name=$n", '--direction=right') "$tmp\sp-$n.txt" 25 | Out-Null
}
$built = Wait-Leaves 'bbuilt' 4 45
$builtPanes = (All-Leaves $built).Count
Assert "B2 setup: built a multi-pane layout (got $builtPanes)" ($builtPanes -ge 4)
$agentB = Wait-AgentPid $tmp 25
Assert 'B3 setup: an agent owns this run''s sessions' ($agentB -ne 0)

# App only - the agent (and every PTY) stays alive, so the relaunch RE-ATTACHES.
Stop-AppOnly
$b = Measure-Startup 'brestore'
# The measurement stops at the FIRST list reporting a pane, which mid-restore is
# a partial answer — so the "did the layout come back" question is asked
# separately, after it settles. (A partial first answer is the healthy-restore
# echo of arm C's gap: it means the app described itself while still building.)
$settled = Wait-Leaves 'bsettled' $builtPanes 45
$settledPanes = (All-Leaves $settled).Count
Say "   healthy restore: first answer $($b.Answer)ms ($($b.Panes) pane(s) then), first window $($b.Window)ms, $settledPanes settled"
Assert 'B4 the restoring app answers +list' ($b.Answer -ge 0)
Assert "B5 the restore actually restored the panes (got $settledPanes)" ($settledPanes -ge $builtPanes)
Assert 'B6 the answer arrives inside 3s' ($b.Answer -ge 0 -and $b.Answer -lt 3000)
Assert 'B7 the answer is not LATER than the windows it describes' ($b.Answer -le $b.Window)

# ============================================================================
Say '== C: agent SUSPENDED across the relaunch - the case that used to block 10.7s'
# ============================================================================
# Reuse arm B's state dir: its manifest and its (now frozen) agent are exactly
# the fixture this arm needs.
$suspended = $agentB
Assert 'C1 setup: the agent was suspended, not killed' (Suspend-Pid $suspended)
Stop-AppOnly
$c = Measure-Startup 'csusp'
Say "   suspended agent: first answer $($c.Answer)ms, first window $($c.Window)ms"
Assert 'C2 the app answers +list despite the wedged agent' ($c.Answer -ge 0)
Assert 'C3 that answer is prompt (< 3s)' ($c.Answer -ge 0 -and $c.Answer -lt 3000)
# The pre-condition that stops C3 from passing vacuously: startup really WAS
# slow this time. Without the suspend it settles in well under a second.
Assert 'C4 setup held: startup really was slowed by the wedged agent (>= 2.5s)' ($c.Window -ge 2500)
$gap = if ($c.Window -ge 0 -and $c.Answer -ge 0) { $c.Window - $c.Answer } else { -1 }
Say "   gap answered-before-settled: $($gap)ms"
if ($NegativeControl) {
    Say 'NEGATIVE CONTROL: asserting IPC was NOT answered early - this run MUST fail'
    Assert 'C5 IPC answered well before startup finished (inverted)' ($gap -lt 1000)
} else {
    Assert 'C5 IPC answered well before startup finished (>= 1s earlier)' ($gap -ge 1000)
}

Resume-Pid $suspended | Out-Null
$suspended = 0

} finally {
    if ($suspended -ne 0) { Resume-Pid $suspended | Out-Null }
    Stop-TestProcs
    Stop-TestForegroundWatch
    Remove-TestDesktop $td
    $env:LOCALAPPDATA = $saved.lad
    $env:GHOSTTY_LOCAL_AGENT_BIN = $saved.bin
    $env:GHOZTTY_PIPE_SUFFIX = $saved.pipe
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

Say ''
if ($script:failures -eq 0) { Say "ALL PASS ($script:passes)" }
else { Write-Host "$script:failures FAILURE(S) ($script:passes passed)" -ForegroundColor Red }
exit ([int]($script:failures -gt 0))
