# Long-context soak harness (T53a/T53b): Claude-Code-like load against the
# release-staging build, fully IPC-driven (no keyboard injection, safe to
# run beside real work). Isolated on a run-unique '-soak<pid>' pipe suffix.
#
# Load mix (all --shell=cmd panes in one named window):
#   soak-stream : endless `type` of an 8MB file  -> sustained visible stream
#   soak-altscr : PS loop toggling ESC[?1049h/l  -> alt-screen churn (TUI-like)
#   soak-grow   : 150k numbered lines            -> big scrollback, then idle
#   (original)  : idle cmd prompt                -> input-latency probe target
#
# Sampled every 15s: WorkingSet, PrivateBytes, Handles, Threads, GDI/USER
# objects, Responding. Every 60s: input-latency probe (+send-keys marker ->
# poll +read until visible). End: big-scrollback +read latency, GHOZTTY_PERF
# telemetry slice from the app log, assertions, CSV + report under
# %TEMP%\ghoztty-soak\<stamp>\.
#
# Usage:
#   soak.ps1                      # 30-minute bounded soak, foreground
#   soak.ps1 -Minutes 5           # quick smoke
#   soak.ps1 -Minutes 240 -Detach # relaunch self detached (T53b long run)
#
# The sampling loop below prints NOTHING between its start and its verdict, by
# design - it samples counters every 15s and only speaks when something is
# wrong. So an unattended runner sees a silent 30-minute process, which is what
# the declaration on the next line is for: scripts\suite-run.ps1 reads it and
# gives this script its own cap instead of the 600s one that killed it and
# scored it `stall` on every sweep (T1125). 30 minutes of soak, plus the
# launch, the 8MB asset build, the end-of-run probes and teardown.
#
# suite-timeout-sec: 2400
param(
    [int]$Minutes = 30,
    [string]$ExePath = 'D:\git\ghoztty\zig-out-release\bin\ghoztty.exe',
    [switch]$Detach,
    [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'

if ($Detach) {
    Start-Process powershell -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath, '-Minutes', $Minutes, '-ExePath', $ExePath)
    Write-Host "soak launched detached ($Minutes min); report will land under $env:TEMP\ghoztty-soak\"
    exit 0
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $env:TEMP "ghoztty-soak\$stamp"
New-Item -ItemType Directory -Force $outDir | Out-Null
$report = Join-Path $outDir 'report.txt'
$csv = Join-Path $outDir 'samples.csv'
$logSlice = Join-Path $outDir 'log-slice.txt'
# $appLog is derived AFTER the sandbox below moves LOCALAPPDATA - see there.
$appLog = $null

function Rep($m) { $m | Tee-Object -FilePath $report -Append | Write-Host }
$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Rep "PASS  $label" }
    else { $script:fail++; Rep "FAIL  $label" }
}

# --- Renderer telemetry grading (T1147) ---------------------------------------
# The `perf` sampler reports once a SECOND PER PANE, and this window has four
# panes of which one is a deliberately idle latency-probe target. An idle
# unfocused pane legitimately redraws about once a second, so it emits `fps=1`
# for essentially every window of the run - and there are more of those windows
# than loaded ones. Every statistic taken over the pooled population therefore
# describes HOW MANY PANES HAPPENED TO BE IDLE rather than how the renderer
# coped: the original `median fps >= 20` read 1 and failed (T1147), and T1158's
# `p90 >= 30` only avoided that by picking a percentile above the idle mass,
# which is still an inference about the population rather than a measurement of
# the panes under load.
#
# Since T1147 each sample NAMES ITS PANE (`perf pane=<uuid> fps=...`), so the
# grading is done where the load actually is: group by pane, map the ids back to
# the names this script gave them, and grade the panes it deliberately loaded.
# The idle probe pane is reported - which is what turns "the fps=1 population is
# idle panes" from an inference into a measurement - and graded by nothing.
function Measure-PaneFps {
    param([System.Collections.IDictionary]$ByPane)
    $rows = @()
    foreach ($k in @($ByPane.Keys)) {
        $v = @($ByPane[$k] | Sort-Object)
        if ($v.Count -eq 0) { continue }
        $p90i = [Math]::Min([int]($v.Count * 0.90), $v.Count - 1)
        $rows += [pscustomobject]@{
            Pane      = $k
            Samples   = $v.Count
            Min       = $v[0]
            Median    = $v[[Math]::Min([int]($v.Count / 2), $v.Count - 1)]
            P90       = $v[$p90i]
            Max       = $v[-1]
            IdleShare = [Math]::Round(@($v | Where-Object { $_ -le 1 }).Count / $v.Count, 2)
        }
    }
    return @($rows | Sort-Object -Property Pane)
}

# Grade one pane per key of $Floors (name -> the fps floor that pane must
# reach). A loaded pane that produced no telemetry at all FAILS (it was told to
# render and never did); one with too few samples to say anything is reported
# and not graded, so a short -Minutes smoke cannot manufacture a verdict out of
# six windows.
#
# The floor is PER PANE because the three load generators do not ask the same
# thing of the renderer, and one floor for all of them is a flake waiting to
# happen. Measured 2026-08-31 over a 5-minute run: `soak-stream` (an endless
# `type` of an 8MB file) sits at the 60 cap, min 59; `soak-altscr` sits at
# median 27 / p90 30 / max 32, because its script SLEEPS 150ms twice per
# iteration - it is paced by its own load, not by the renderer, and grading it
# at 30 puts the bar exactly on its ceiling. Each floor is set where a real
# renderer regression shows up and this run's own margin does not.
function Test-LoadedPaneFps {
    param(
        [object[]]$Rows,
        [System.Collections.IDictionary]$Floors,
        [int]$MinSamples = 60
    )
    $out = @()
    foreach ($name in @($Floors.Keys | Sort-Object)) {
        $floor = [int]$Floors[$name]
        $r = @($Rows | Where-Object { $_.Pane -eq $name })[0]
        if (-not $r) {
            $out += [pscustomobject]@{ Pane = $name; Floor = $floor; Graded = $true; Pass = $false; Why = 'no telemetry from this pane' }
        } elseif ($r.Samples -lt $MinSamples) {
            $out += [pscustomobject]@{ Pane = $name; Floor = $floor; Graded = $false; Pass = $true; Why = "only $($r.Samples) samples (< $MinSamples)" }
        } else {
            $out += [pscustomobject]@{ Pane = $name; Floor = $floor; Graded = $true; Pass = ($r.P90 -ge $floor); Why = "p90 $($r.P90) fps over $($r.Samples) samples" }
        }
    }
    return @($out)
}

# What each load generator is expected to sustain. Used by the run and by
# -SelfTest, so the negative control grades against the same numbers the real
# verdict does.
$script:PaneFpsFloors = @{
    'soak-stream' = 30
    'soak-altscr' = 15
    'soak-grow'   = 30
}

# Negative control for the grader (T1147): `soak.ps1 -SelfTest` proves the
# assertion can score red, in seconds, without a 30-minute run. A gate nobody
# has watched fail is indistinguishable from a gate that cannot fail.
if ($SelfTest) {
    $idle = @(1) * 400
    $fast = @(60) * 300 + @(1) * 100      # stream/grow, with idle stretches
    $paced = @(27) * 280 + @(30) * 20 + @(1) * 100   # altscr, as measured
    $slow = @(8) * 300 + @(1) * 100       # loaded, renderer cannot keep up
    $floors = $script:PaneFpsFloors

    $healthy = Measure-PaneFps @{ 'soak-stream' = $fast; 'soak-altscr' = $paced; 'soak-grow' = $fast; 'probe' = $idle }
    $hv = Test-LoadedPaneFps -Rows $healthy -Floors $floors
    Assert (@($hv | Where-Object { -not $_.Pass }).Count -eq 0) 'selftest: healthy build passes with 400 idle-pane fps=1 samples present'
    Assert ((@($healthy | Where-Object { $_.Pane -eq 'probe' })[0]).IdleShare -eq 1) 'selftest: the idle probe pane is reported as 100% fps<=1'

    $regressed = Measure-PaneFps @{ 'soak-stream' = $fast; 'soak-altscr' = $slow; 'soak-grow' = $fast; 'probe' = $idle }
    $rv = Test-LoadedPaneFps -Rows $regressed -Floors $floors
    Assert (@($rv | Where-Object { -not $_.Pass }).Count -eq 1) 'selftest: a loaded pane dropping to 8 fps turns the verdict RED'
    Assert ((@($rv | Where-Object { $_.Pane -eq 'soak-altscr' })[0]).Pass -eq $false) 'selftest: the red verdict names the pane that dropped'

    $streamDrop = Measure-PaneFps @{ 'soak-stream' = (@(25) * 300 + @(1) * 100); 'soak-altscr' = $paced; 'soak-grow' = $fast; 'probe' = $idle }
    $sv = Test-LoadedPaneFps -Rows $streamDrop -Floors $floors
    Assert ((@($sv | Where-Object { $_.Pane -eq 'soak-stream' })[0]).Pass -eq $false) 'selftest: the 60fps stream pane falling to 25 is RED even though 25 clears altscr floor'

    $missing = Measure-PaneFps @{ 'soak-stream' = $fast; 'soak-grow' = $fast; 'probe' = $idle }
    $mv = Test-LoadedPaneFps -Rows $missing -Floors $floors
    Assert ((@($mv | Where-Object { $_.Pane -eq 'soak-altscr' })[0]).Pass -eq $false) 'selftest: a loaded pane that rendered nothing at all is a failure'

    $short = Test-LoadedPaneFps -Rows (Measure-PaneFps @{ 'soak-stream' = @(60) * 10; 'soak-altscr' = @(60) * 10; 'soak-grow' = @(60) * 10 }) -Floors $floors
    Assert (@($short | Where-Object { $_.Graded }).Count -eq 0) 'selftest: too few samples is reported, not graded'

    Rep ""
    Rep "=== selftest: $($script:pass) passed, $($script:fail) failed"
    if ($script:fail -gt 0) { Rep "$($script:fail) FAILURE(S)"; exit 1 }
    Rep 'ALL PASS'
    exit 0
}

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class SoakDrv {
    [DllImport("user32.dll")] public static extern uint GetGuiResources(IntPtr hProcess, uint uiFlags);
}
'@

if (-not (Test-Path $ExePath)) { Rep "ABORT: exe not found: $ExePath"; exit 1 }
$exe = $ExePath
# T1158 bystander baseline. Read the USER'S session roster while the env is
# still theirs - $exe is a release build, so with no GHOZTTY_AGENT_INSTANCE set
# it dials exactly the agent that owns the user's live panes. This is the
# measurement the fix is judged by, and it is taken by the harness itself so
# every future run re-proves it instead of trusting the env vars below.
$userSessionsBefore = @(
    (& $exe +sessions 2>&1 | ForEach-Object { $_.ToString() }) |
        Where-Object { $_ -match '^[0-9a-f]{32}' } |
        ForEach-Object { ($_ -split '\s+')[0] }
)

# T1158: ALL THREE isolating knobs, not just the app pipe. This harness's
# subject is a RELEASE build, so its endpoints are the user's by default, and
# for weeks it held only `GHOZTTY_PIPE_SUFFIX` - the state BuildMode.ps1's own
# header calls "the dangerous state, not a partial win". The app pipe was
# private while every pane it opened became a session in the agent that owns the
# user's live terminal, PINNED. A pinned live session is immortal on purpose
# (it is what lets a pane outlive its window), so nothing reaped them: two runs
# left six shells behind, and the 5am refresh restarted the user's terminal into
# the pile. `-ReleaseSandbox` adds GHOZTTY_AGENT_INSTANCE and a private
# LOCALAPPDATA, and `Assert-GhozttyIsolatedBuild` below now verifies all three
# rather than taking `-AllowReleaseBuild` on trust.
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 'soak' -ReleaseSandbox -SandboxRoot (Join-Path $outDir 'sandbox'))
$env:GHOZTTY_PERF = '1'
# Now that LOCALAPPDATA is the sandbox, this is the log THIS run's app writes.
# It used to be the user's own `ghoztty.log`, so the GHOZTTY_PERF slice below
# was reading the user's live terminal's telemetry interleaved with the soak's.
$appLog = Join-Path $env:LOCALAPPDATA 'ghoztty\ghoztty.log'
$exeItem = Get-Item $exe
Rep "=== ghoztty soak $stamp"
Rep "exe: $exe ($(($exeItem).LastWriteTime), $(($exeItem).Length) bytes)"
Rep "duration: $Minutes min; pipe suffix: $env:GHOZTTY_PIPE_SUFFIX"
Rep "agent lineage: $env:GHOZTTY_AGENT_INSTANCE; state root: $env:LOCALAPPDATA"

# --- Load-generator assets ----------------------------------------------------
$assetDir = Join-Path $env:TEMP 'ghoztty-soak'
$streamFile = Join-Path $assetDir 'stream.txt'
if (-not (Test-Path $streamFile) -or (Get-Item $streamFile).Length -lt 8000000) {
    $line = ('soak-stream-payload ' + ('x' * 60))
    $block = [System.Text.StringBuilder]::new()
    1..1000 | ForEach-Object { [void]$block.AppendLine("$line $_") }
    $sw = [System.IO.StreamWriter]::new($streamFile, $false)
    1..100 | ForEach-Object { $sw.Write($block.ToString()) }
    $sw.Close()
}
$altscrScript = Join-Path $assetDir 'altscr.ps1'
@'
$e = [char]27
while ($true) {
    [console]::Write("$e[?1049h")
    1..100 | ForEach-Object { [console]::WriteLine("altscr churn line $_ " + ('y' * 40)) }
    Start-Sleep -Milliseconds 150
    [console]::Write("$e[?1049l")
    1..20 | ForEach-Object { [console]::WriteLine("primary interlude $_") }
    Start-Sleep -Milliseconds 150
}
'@ | Set-Content -Encoding ascii $altscrScript

# --- Fresh isolated instance + layout -----------------------------------------
# T248: the sibling agent and the debug session-layout manifest are part of
# "fresh" — a soak that inherits the previous run's persisted pane is soaking
# a pane nobody just created, with hours of its own scrollback already in it.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
# T1241: the auto-launch below goes to the background test desktop.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
# T350: -AllowReleaseBuild, said out loud. This harness's SUBJECT is the release
# build (its whole point is grading what ships), so it is the one caller that
# legitimately runs an exe whose endpoints are not the -debug ones. The run-unique
# suffix above keeps its app endpoint off the user's; its kills are path-exact
# to zig-out-release either way.
Reset-GhozttyTestState -Exe $exe -SettleMs 500 -AllowReleaseBuild | Out-Null

# Auto-launch flow: +new-window spawns the GUI (detached) when no soak
# instance answers, and names the window.
#
# T1241: the CLI runs on the BACKGROUND test desktop, and the app it auto-spawns
# inherits that desktop - so a soak no longer parks four load-generating panes
# across whatever the user is reading. -AllowReleaseBuild for the same reason
# Reset-GhozttyTestState above takes it: the release build IS this harness's
# subject.
$td = New-TestDesktop
[void](Invoke-OnTestDesktop -Exe $exe -Arguments @('+new-window', '--target=soak', '--shell=cmd') `
    -AllowReleaseBuild -TimeoutSec 60)
Start-Sleep -Seconds 3
$gui = @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
    Where-Object { $_.ExecutablePath -eq $exe } |
    Where-Object { $_.ProcessId -ne $PID })
# The window is on the test desktop, so .NET's MainWindowHandle - which
# enumerates the CALLER's desktop - reads 0 for every one of these processes.
# Ask the desktop that actually has the window.
$gui = @($gui | Where-Object {
    (Get-TestWindow -ProcessId $_.ProcessId -Class 'GhozttyWindow') -ne [IntPtr]::Zero })
# An ABORT after the GUI exists used to `exit 1` straight past the teardown at
# the bottom of this script, leaving the three load generators pinning the box
# and the sandbox agent running. On 2026-08-31 that turned one aborted setup
# into a machine that was still at full tilt five minutes later, which is
# exactly the state that makes the NEXT attempt abort too. Every abort from
# here down goes through this instead.
function Abort-Soak([string]$why) {
    Rep "ABORT: $why"
    & $exe +close --target=soak 2>$null | Out-Null
    Start-Sleep -Seconds 1
    try { [void](Stop-RepoGhoztty -Exe $exe -SettleMs 1500) } catch { Rep "  (teardown: $_)" }
    try { Remove-TestDesktop | Out-Null } catch { }
    exit 1
}

if ($gui.Count -ne 1) { Rep "ABORT: expected 1 soak GUI process, got $($gui.Count)"; exit 1 }
$proc = Get-Process -Id $gui[0].ProcessId
Rep "gui pid: $($proc.Id)"

& $exe +split --target=soak --name=soak-stream --direction=right --shell=cmd `
    "--command=for /l %i in (1,1,2000000) do @type $streamFile" | Out-Null
Start-Sleep -Milliseconds 800
& $exe +split --target=soak --name=soak-altscr --direction=down --shell=cmd `
    "--command=powershell -nop -ExecutionPolicy Bypass -File `"$altscrScript`"" | Out-Null
Start-Sleep -Milliseconds 800
& $exe +split --target=soak-stream --name=soak-grow --direction=down --shell=cmd `
    "--command=for /l %i in (1,1,150000) do @echo SOAKGROW %i abcdefghijklmnopqrstuvwxyz0123456789" | Out-Null
Start-Sleep -Seconds 2

# The window's original (unnamed) pane is the latency-probe target: it is
# the leaf whose name we did not choose.
#
# This `+list` runs two seconds after three load generators were turned on, so
# it asks the app its busiest question at its busiest moment. The default 30s
# IPC budget is not enough there: on 2026-08-31 it timed out and the run
# ABORTED at minute one, throwing away a 30-minute soak before a single sample
# was taken. This is SETUP, not a measurement - the `+list` that is actually
# graded is the one at the end of the run, which keeps the default budget - so
# it gets a wider one rather than a verdict.
#
# And the OUTPUT is captured through cmd redirection, then sanitised before it
# is parsed. When the app does not answer immediately the client prints
# "Waiting for Ghoztty to answer '+list' ..." on its way to SUCCEEDING - a
# progress message, not a failure - and it cost this run twice on 2026-08-31.
# Once as JSON: `& $exe +list --json | ConvertFrom-Json` fed that line to the
# parser, the parse threw, and the run aborted with "soak window not in +list"
# while the window was right there. And once as an exception: rewriting it as
# `& $exe ... 2>&1` turned the same message into a NativeCommandError, which
# `$ErrorActionPreference = 'Stop'` at the top of this file makes TERMINATING -
# the script died with no ABORT line at all. `Get-GhozttyListRaw` (Isolation.ps1)
# redirects inside cmd, so neither hazard exists; everything from the first `{`
# is the JSON.
$prevIpcTimeout = $env:GHOZTTY_IPC_TIMEOUT_MS
$env:GHOZTTY_IPC_TIMEOUT_MS = '120000'
try {
    $listRaw = Get-GhozttyListRaw -Exe $exe
} finally { $env:GHOZTTY_IPC_TIMEOUT_MS = $prevIpcTimeout }
$brace = $listRaw.IndexOf('{')
if ($brace -lt 0) { Abort-Soak "+list --json produced no JSON: $listRaw" }
$listJson = $listRaw.Substring($brace) | ConvertFrom-Json
$leaves = @()
function Walk($node) {
    if ($null -ne $node.terminal) { $script:leaves += $node.terminal }
    if ($null -ne $node.left) { Walk $node.left; Walk $node.right }
}
$win = $listJson.data.windows | Where-Object { $_.target -eq 'soak' }
if (-not $win) { Abort-Soak 'soak window not in +list' }
$win.tabs | ForEach-Object { Walk $_.splits }
$named = @('soak-stream', 'soak-altscr', 'soak-grow')
$probe = @($leaves | Where-Object { $named -notcontains $_.name })
if ($probe.Count -ne 1) { Abort-Soak "expected 1 probe pane, got $($probe.Count) of $($leaves.Count) leaves" }
$probePane = $probe[0].name
# T1147: the `perf pane=<uuid>` telemetry names panes by their pane id; this is
# how the ids become the names this script gave them, so the report and the
# assertions read in the harness's own vocabulary.
$paneNames = @{}
foreach ($l in $leaves) { if ($l.id) { $paneNames[[string]$l.id] = [string]$l.name } }
$loadedPanes = $named
Assert ($leaves.Count -eq 4) "layout: 4 leaves in soak window (probe pane: $probePane)"

# Baseline +read latency on the (still small) grow pane, for the end-of-run
# big-scrollback comparison.
$sw = [System.Diagnostics.Stopwatch]::StartNew()
& $exe +read --name=soak-grow --lines=50 | Out-Null
$sw.Stop()
$readBaselineMs = $sw.ElapsedMilliseconds
Rep "baseline +read latency (grow pane mid-blast): ${readBaselineMs}ms"
if ($readBaselineMs -gt 2000) {
    Rep "WARN  +read stalled ${readBaselineMs}ms against a tiny-write storm - known issue (T62 renderer-mutex starvation), not asserted here"
}

$logStart = if (Test-Path $appLog) { (Get-Item $appLog).Length } else { 0 }

# --- Sampling loop -------------------------------------------------------------
'elapsed_s,ws_mb,private_mb,handles,threads,gdi,user,responding,latency_ms' |
    Set-Content -Encoding ascii $csv
$deadline = (Get-Date).AddMinutes($Minutes)
$t0 = Get-Date
$notRespondingSamples = 0
$latencies = @()
$samples = @()
$lastLatencyProbe = (Get-Date).AddSeconds(-60)
$probeN = 0
$procAlive = $true

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 15
    $proc.Refresh()
    if ($proc.HasExited) { $procAlive = $false; Rep 'FATAL: gui process exited mid-soak'; break }

    $elapsed = [int]((Get-Date) - $t0).TotalSeconds
    $wsMb = [math]::Round($proc.WorkingSet64 / 1MB, 1)
    $privMb = [math]::Round($proc.PrivateMemorySize64 / 1MB, 1)
    $gdi = [SoakDrv]::GetGuiResources($proc.Handle, 0)
    $usr = [SoakDrv]::GetGuiResources($proc.Handle, 1)
    $resp = $proc.Responding
    if (-not $resp) { $notRespondingSamples++ }

    $latMs = ''
    if (((Get-Date) - $lastLatencyProbe).TotalSeconds -ge 60) {
        $lastLatencyProbe = Get-Date
        $probeN++
        $marker = "LATPROBE_$probeN"
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        & $exe +send-keys --target=$probePane "echo $marker" Enter | Out-Null
        $found = $false
        while (-not $found -and $sw.ElapsedMilliseconds -lt 5000) {
            Start-Sleep -Milliseconds 100
            $tail = & $exe +read --name=$probePane --lines=5 | Out-String
            # Marker must appear twice: the echoed command AND its output
            # (the send itself proves echo; the second copy proves execution).
            if (([regex]::Matches($tail, $marker)).Count -ge 2) { $found = $true }
        }
        $sw.Stop()
        if ($found) { $latMs = $sw.ElapsedMilliseconds; $latencies += [int]$latMs }
        else { $latMs = -1; Rep "WARN  latency probe $probeN never became visible (5s)" }
    }

    $row = "$elapsed,$wsMb,$privMb,$($proc.HandleCount),$($proc.Threads.Count),$gdi,$usr,$resp,$latMs"
    Add-Content -Encoding ascii $csv $row
    $samples += [pscustomobject]@{
        Elapsed = $elapsed; WsMb = $wsMb; PrivMb = $privMb
        Handles = $proc.HandleCount; Gdi = $gdi; Usr = $usr
    }
}

# --- End-of-run probes ---------------------------------------------------------
if ($procAlive) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $growTail = & $exe +read --name=soak-grow --lines=50 | Out-String
    $sw.Stop()
    $readBigMs = $sw.ElapsedMilliseconds
    $growDone = $growTail -match 'SOAKGROW 150000'
    Rep "big-scrollback +read latency: ${readBigMs}ms (baseline ${readBaselineMs}ms; grow finished: $growDone)"

    $listOk = $true
    & $exe +list | Out-Null
    if ($LASTEXITCODE -ne 0) { $listOk = $false }
}

# Telemetry slice from the app log (only the soak exe runs with
# GHOZTTY_PERF set, so 'perf ' lines in the increment are ours).
$fpsVals = @()
$gapVals = @()
$fpsByPane = @{}
$anonSamples = 0
$slowMutex = 0
if ((Test-Path $appLog) -and (Get-Item $appLog).Length -gt $logStart) {
    $fs = [System.IO.FileStream]::new($appLog, 'Open', 'Read', 'ReadWrite')
    try {
        $fs.Seek($logStart, 'Begin') | Out-Null
        $sr = [System.IO.StreamReader]::new($fs)
        $sliceWriter = [System.IO.StreamWriter]::new($logSlice, $false)
        while ($null -ne ($line = $sr.ReadLine())) {
            if ($line -match 'perf |slow') { $sliceWriter.WriteLine($line) }
            # `pane=` is optional so this harness still reads an exe built
            # before T1147 - it falls back to the pooled assertion below and
            # says so, instead of silently grading nothing.
            if ($line -match 'perf (?:pane=(\S+) )?fps=(\d+) max_gap_ms=(\d+)') {
                $fps = [int]$Matches[2]
                $fpsVals += $fps
                $gapVals += [int]$Matches[3]
                $pane = $Matches[1]
                if ($pane) {
                    $key = if ($paneNames.ContainsKey($pane)) { $paneNames[$pane] } else { $pane }
                    if (-not $fpsByPane.ContainsKey($key)) { $fpsByPane[$key] = @() }
                    $fpsByPane[$key] += $fps
                } else { $anonSamples++ }
            }
            if ($line -match 'slow.*mutex|mutex.*slow') { $slowMutex++ }
        }
        $sliceWriter.Close()
    } finally { $fs.Close() }
}

# --- Assertions ---------------------------------------------------------------
Assert $procAlive 'gui process alive for the whole soak'
if ($procAlive) {
    Assert ($notRespondingSamples -eq 0) "responsive at every sample (not-responding samples: $notRespondingSamples)"
    Assert $listOk 'IPC still answers +list at the end'
    Assert ($readBigMs -lt 1000) "+read on 150k-line scrollback < 1s (${readBigMs}ms)"

    if ($fpsVals.Count -gt 10) {
        $sortedFps = $fpsVals | Sort-Object
        $medianFps = $sortedFps[[int]($sortedFps.Count / 2)]
        $maxGap = ($gapVals | Measure-Object -Maximum).Maximum
        # max_gap is informational only: an IDLE unfocused pane legitimately
        # reports gaps equal to the time between its redraws (e.g. ~60s
        # between latency probes), so a global stall assertion false-fails.
        # Stall detection comes from Responding, the per-pane fps grading
        # below, and the latency probes instead.
        $p90Fps = $sortedFps[[int]($sortedFps.Count * 0.90)]
        Rep "renderer telemetry: $($fpsVals.Count) samples across $($fpsByPane.Count) panes, pooled median fps $medianFps, pooled p90 $p90Fps, worst frame gap ${maxGap}ms, slow-mutex warns $slowMutex"

        # Per-pane breakdown FIRST, because it is the evidence the pooled
        # numbers above cannot be read without: it shows, from the telemetry
        # rather than by inference, that the fps=1 mass belongs to the idle
        # probe pane.
        $paneRows = Measure-PaneFps $fpsByPane
        foreach ($r in $paneRows) {
            $tag = if ($loadedPanes -contains $r.Pane) { 'LOADED' } elseif ($r.Pane -eq $probePane) { 'idle probe' } else { 'other' }
            Rep ("  pane {0,-14} {1,-11} samples {2,5}  min {3,3}  median {4,3}  p90 {5,3}  max {6,3}  fps<=1 share {7}" -f `
                $r.Pane, $tag, $r.Samples, $r.Min, $r.Median, $r.P90, $r.Max, $r.IdleShare)
        }

        if ($fpsByPane.Count -gt 0) {
            # `soak-grow` finishes its 150k lines and then goes idle, at which
            # point its own samples become idle samples like the probe's. Grade
            # it only while it is still loading at the end of the run; the same
            # cannot happen to stream/altscr, which are endless loops by
            # construction.
            $grade = @{}
            foreach ($k in $script:PaneFpsFloors.Keys) { $grade[$k] = $script:PaneFpsFloors[$k] }
            if ($growDone) {
                $grade.Remove('soak-grow')
                Rep '  (soak-grow finished its 150k lines and went idle - not graded)'
            }

            $verdicts = Test-LoadedPaneFps -Rows $paneRows -Floors $grade
            foreach ($v in $verdicts) {
                if ($v.Graded) { Assert $v.Pass "loaded pane $($v.Pane) sustains >= $($v.Floor) fps ($($v.Why))" }
                else { Rep "  WARN  $($v.Pane) not graded: $($v.Why)" }
            }
            if ($anonSamples -gt 0) {
                Rep "  WARN  $anonSamples perf samples carried no pane= (pre-T1147 exe?) and were pooled only"
            }
        } else {
            # Pre-T1147 exe: no sample says which pane it came from, so the
            # best available claim is the pooled one T1158 left behind.
            Rep 'WARN  no perf sample carried pane= - grading the pooled population (pre-T1147 exe)'
            Assert ($p90Fps -ge 30) "the rendering windows sustain >= 30 fps (pooled p90 $p90Fps)"
        }
    } else {
        Rep "WARN  too few perf log windows ($($fpsVals.Count)) - telemetry assertions skipped"
    }

    if ($latencies.Count -ge 2) {
        $latSorted = $latencies | Sort-Object
        $latMed = $latSorted[[int]($latSorted.Count / 2)]
        Rep "input-latency probes: $($latencies.Count) ok, median ${latMed}ms, worst $($latSorted[-1])ms"
        Assert ($latMed -lt 2000) "median echo round-trip < 2s under load (${latMed}ms)"
    }

    # Leak heuristics: compare medians of the first and last quarters so
    # early scrollback fill does not count as a leak.
    if ($samples.Count -ge 8) {
        $q = [int]($samples.Count / 4)
        $firstQ = $samples[0..($q - 1)]
        $lastQ = $samples[($samples.Count - $q)..($samples.Count - 1)]
        function MedianOf($arr, $prop) {
            $v = @($arr | ForEach-Object { $_.$prop } | Sort-Object)
            return $v[[int]($v.Count / 2)]
        }
        $privDelta = (MedianOf $lastQ 'PrivMb') - (MedianOf $firstQ 'PrivMb')
        $handleDelta = (MedianOf $lastQ 'Handles') - (MedianOf $firstQ 'Handles')
        $gdiDelta = (MedianOf $lastQ 'Gdi') - (MedianOf $firstQ 'Gdi')
        $usrDelta = (MedianOf $lastQ 'Usr') - (MedianOf $firstQ 'Usr')
        Rep "growth q1->q4 (median): private ${privDelta}MB, handles $handleDelta, GDI $gdiDelta, USER $usrDelta"
        Assert ($privDelta -lt 300) "private-bytes growth after fill < 300MB (${privDelta}MB)"
        Assert ($handleDelta -lt 500) "handle growth after fill < 500 ($handleDelta)"
        Assert ($gdiDelta -lt 200) "GDI-object growth after fill < 200 ($gdiDelta)"
        Assert ($usrDelta -lt 200) "USER-object growth after fill < 200 ($usrDelta)"
    }
}

# --- Teardown ------------------------------------------------------------------
& $exe +close --target=soak 2>$null | Out-Null
Start-Sleep -Seconds 2
if ($procAlive) {
    $proc.Refresh()
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
}

# T1158: the sandbox has an agent of its OWN now, and a `--pty-host` holder per
# pane that deliberately outlives it (T904/T906 - that is what makes a session
# survive an agent restart, so it is neither a child of the agent nor in its
# job). Closing the window reaches none of them, which is the T1127 shape
# exactly. Stop-RepoGhoztty is path-exact and refuses anything not under the
# repo, so this can only ever reach zig-out-release's own processes - never the
# installed agent holding the user's panes.
[void](Stop-RepoGhoztty -Exe $exe -SettleMs 1500)
Remove-TestDesktop | Out-Null

# --- T1158: the bystander check ------------------------------------------------
# The point of the whole sandbox, asserted rather than assumed. Read the user's
# roster back with the env restored to theirs; a session this run opened must
# not be in it. Before the sandbox every soak added its panes here as PINNED
# sessions, which are immortal by design (that is what lets a pane outlive its
# window), so nothing reaped them and the 5am refresh restarted the user's
# terminal into the accumulated pile.
$env:GHOZTTY_AGENT_INSTANCE = $null
Remove-Item Env:GHOZTTY_AGENT_INSTANCE -ErrorAction SilentlyContinue
$env:LOCALAPPDATA = [Environment]::GetFolderPath('LocalApplicationData')
$userSessionsAfter = @(
    (& $exe +sessions 2>&1 | ForEach-Object { $_.ToString() }) |
        Where-Object { $_ -match '^[0-9a-f]{32}' } |
        ForEach-Object { ($_ -split '\s+')[0] }
)
$strays = @($userSessionsAfter | Where-Object { $userSessionsBefore -notcontains $_ })
Rep "bystander: user agent held $($userSessionsBefore.Count) session(s) before, $($userSessionsAfter.Count) after"
Assert ($strays.Count -eq 0) "no session leaked into the user's agent (strays: $($strays -join ' '))"

Rep ''
if ($script:fail -eq 0) { Rep "ALL PASS ($script:pass assertions) - report: $report" }
else { Rep "$script:fail FAILURE(S) / $script:pass passed - report: $report"; exit 1 }
