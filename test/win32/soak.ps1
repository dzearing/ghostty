# Long-context soak harness (T53a/T53b): Claude-Code-like load against the
# release-staging build, fully IPC-driven (no keyboard injection, safe to
# run beside real work). Isolated on the '-soak' pipe suffix.
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
param(
    [int]$Minutes = 30,
    [string]$ExePath = 'D:\git\ghoztty\zig-out-release\bin\ghoztty.exe',
    [switch]$Detach
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
$appLog = Join-Path $env:LOCALAPPDATA 'ghoztty\ghoztty.log'

function Rep($m) { $m | Tee-Object -FilePath $report -Append | Write-Host }
$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Rep "PASS  $label" }
    else { $script:fail++; Rep "FAIL  $label" }
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
$env:GHOZTTY_PIPE_SUFFIX = '-soak'
$env:GHOZTTY_PERF = '1'
$exeItem = Get-Item $exe
Rep "=== ghoztty soak $stamp"
Rep "exe: $exe ($(($exeItem).LastWriteTime), $(($exeItem).Length) bytes)"
Rep "duration: $Minutes min; pipe suffix: -soak"

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
# T350: -AllowReleaseBuild, said out loud. This harness's SUBJECT is the release
# build (its whole point is grading what ships), so it is the one caller that
# legitimately runs an exe whose endpoints are not the -debug ones. The '-soak'
# suffix above keeps its app endpoint off the user's; its kills are path-exact
# to zig-out-release either way.
Reset-GhozttyTestState -Exe $exe -SettleMs 500 -AllowReleaseBuild | Out-Null

# Auto-launch flow: +new-window spawns the GUI (detached) when no -soak
# instance answers, and names the window.
& $exe +new-window --target=soak --shell=cmd | Out-Null
Start-Sleep -Seconds 3
$gui = @(Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
    Where-Object { $_.ExecutablePath -eq $exe } |
    Where-Object { $_.ProcessId -ne $PID })
$gui = @($gui | Where-Object {
    $p = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
    $p -and $p.MainWindowHandle -ne 0 })
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
$listJson = & $exe +list --json | ConvertFrom-Json
$leaves = @()
function Walk($node) {
    if ($null -ne $node.terminal) { $script:leaves += $node.terminal }
    if ($null -ne $node.left) { Walk $node.left; Walk $node.right }
}
$win = $listJson.data.windows | Where-Object { $_.target -eq 'soak' }
if (-not $win) { Rep 'ABORT: soak window not in +list'; exit 1 }
$win.tabs | ForEach-Object { Walk $_.splits }
$named = @('soak-stream', 'soak-altscr', 'soak-grow')
$probe = @($leaves | Where-Object { $named -notcontains $_.name })
if ($probe.Count -ne 1) { Rep "ABORT: expected 1 probe pane, got $($probe.Count) of $($leaves.Count) leaves"; exit 1 }
$probePane = $probe[0].name
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
$slowMutex = 0
if ((Test-Path $appLog) -and (Get-Item $appLog).Length -gt $logStart) {
    $fs = [System.IO.FileStream]::new($appLog, 'Open', 'Read', 'ReadWrite')
    try {
        $fs.Seek($logStart, 'Begin') | Out-Null
        $sr = [System.IO.StreamReader]::new($fs)
        $sliceWriter = [System.IO.StreamWriter]::new($logSlice, $false)
        while ($null -ne ($line = $sr.ReadLine())) {
            if ($line -match 'perf |slow') { $sliceWriter.WriteLine($line) }
            if ($line -match 'perf fps=(\d+) max_gap_ms=(\d+)') {
                $fpsVals += [int]$Matches[1]
                $gapVals += [int]$Matches[2]
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
        # Stall detection comes from Responding, fps-under-load, and the
        # latency probes instead.
        Rep "renderer telemetry: $($fpsVals.Count) windows, median fps $medianFps, worst frame gap ${maxGap}ms (idle panes inflate this), slow-mutex warns $slowMutex"
        Assert ($medianFps -ge 20) "median fps under load >= 20 (got $medianFps)"
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

Rep ''
if ($script:fail -eq 0) { Rep "ALL PASS ($script:pass assertions) - report: $report" }
else { Rep "$script:fail FAILURE(S) / $script:pass passed - report: $report"; exit 1 }
