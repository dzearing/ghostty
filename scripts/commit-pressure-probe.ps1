# commit-pressure-probe.ps1 - run a command while watching system commit (T449)
#
# Why: on this box the Windows commit LIMIT is RAM + a 4 GB page file, and a
# `zig build` fans out several parallel LLVM compiles that each want gigabytes.
# When commit is exhausted, VirtualAlloc starts failing, and C++ code that does
# not check every allocation dereferences null - which is exactly the shape of
# the `zig.exe` access violations this task is chasing (one of them faulted at
# address 0x10, the classic `nullptr->field`).
#
# So: sample commit every second for the life of a command, report the peak
# against the limit, and correlate with anything the Application Error log
# recorded. That turns "the compiler crashed again" into a number.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Command,
    [int]$Runs = 1,
    [int]$IntervalMs = 1000
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo
$env:ZIG_GLOBAL_CACHE_DIR = 'D:\zig-global-cache'

$limit = (Get-Counter '\Memory\Commit Limit').CounterSamples[0].CookedValue
Write-Host ("commit limit: {0:N1} GB   physical: {1:N1} GB" -f ($limit / 1GB), `
    ((Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize / 1MB))

for ($run = 1; $run -le $Runs; $run++) {
    $t0 = Get-Date
    # The sampler streams to a file rather than returning a value: it is killed
    # rather than allowed to finish, and a job that is stopped never emits its
    # pipeline output - so an in-memory peak would always come back empty.
    $samplesFile = Join-Path $env:TEMP "commit-samples-$run.txt"
    Remove-Item $samplesFile -ErrorAction SilentlyContinue
    $sampler = Start-Job -ScriptBlock {
        param($ms, $file)
        while ($true) {
            $c = (Get-Counter '\Memory\Committed Bytes' -ErrorAction SilentlyContinue).CounterSamples[0].CookedValue
            if ($c) { Add-Content -Path $file -Value ([string][int64]$c) }
            Start-Sleep -Milliseconds $ms
        }
    } -ArgumentList $IntervalMs, $samplesFile

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $log = Join-Path $env:TEMP "commit-probe-$run.log"
    cmd.exe /c "$Command > `"$log`" 2>&1"
    $code = $LASTEXITCODE
    $sw.Stop()

    # The job holds its peak in a loop with no exit condition; stopping it is
    # how we end the sample window, so read the value it already emitted.
    Stop-Job $sampler -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $sampler -Force -ErrorAction SilentlyContinue | Out-Null
    $vals = @(Get-Content $samplesFile -ErrorAction SilentlyContinue | ForEach-Object { [int64]$_ })
    $peak = if ($vals.Count) { ($vals | Measure-Object -Maximum).Maximum } else { 0 }
    $nSamples = $vals.Count

    Start-Sleep -Seconds 2
    $crashes = @(Get-WinEvent -FilterHashtable @{LogName = 'Application'; Id = 1000; StartTime = $t0 } -ErrorAction SilentlyContinue |
        ForEach-Object { $p = $_.Properties; "$($p[0].Value)/$($p[6].Value)@$($p[3].Value)+$($p[7].Value)" })

    Write-Host ("run {0}  exit={1,-4} {2,4}s  n={3}  peakCommit={4:N1} GB ({5:N0}% of limit)  crashes: {6}" -f `
            $run, $code, [int]$sw.Elapsed.TotalSeconds, $nSamples, ($peak / 1GB), (100 * $peak / $limit), `
        $(if ($crashes.Count) { $crashes -join '; ' } else { 'none' }))
}
