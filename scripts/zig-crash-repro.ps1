# zig-crash-repro.ps1 - is the compiler crash ours, the toolchain's, or the box's? (T449)
#
# Two arms, run back to back on the same box under the same conditions:
#
#   A. ghoztty  - replay the exact `zig test` compile command the test-agent
#                 lane runs, standalone (no build runner, no --listen).
#   B. control  - a comparably heavy compile with NO ghoztty source in it at
#                 all (zig's own standard library test build).
#
# The arms are what make the result mean something. A crashes and B is clean
# => the fault is data-dependent on our source, so it is a compiler bug our
# code triggers, not the machine. Both crash => nothing to do with our source.
# Neither crashes => the failure needs load or concurrency this harness is not
# reproducing, and that itself is a finding.
#
# Every iteration is correlated against the Windows Application Error log, so
# an exit code is never reported without the exception that produced it.

[CmdletBinding()]
param(
    [int]$Runs = 5,
    [ValidateSet('both', 'ghoztty', 'control')]
    [string]$Arm = 'both',
    [string]$CommandLog = '',
    [string]$OutDir = "$env:TEMP\zig-crash-repro"
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo
$env:ZIG_GLOBAL_CACHE_DIR = 'D:\zig-global-cache'

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# `zig` on PATH here is a WinGet SHIM, so its own directory has no lib/ next to
# it. Ask the compiler where it actually lives instead of deriving it from the
# shim's path, which silently produced a control arm that failed in 0s.
# `zig env` emits ZON, not JSON, so ConvertFrom-Json chokes on the leading `.{`.
$zigEnv = (& zig env) -join "`n"
function Get-ZonString([string]$zon, [string]$key) {
    if ($zon -match "\.$key\s*=\s*`"([^`"]+)`"") { return $Matches[1] -replace '\\\\', '\' }
    throw "could not read .$key from 'zig env'"
}
$zig = Get-ZonString $zigEnv 'zig_exe'
$zigLib = Get-ZonString $zigEnv 'lib_dir'

function Get-ZigCrashesSince([datetime]$t) {
    Get-WinEvent -FilterHashtable @{LogName = 'Application'; Id = 1000; StartTime = $t } -ErrorAction SilentlyContinue |
        ForEach-Object {
            $p = $_.Properties
            [pscustomobject]@{ Time = $_.TimeCreated; App = $p[0].Value; Code = $p[6].Value; Mod = $p[3].Value; Off = $p[7].Value }
        }
}

# The lane's compile command is enormous and machine-generated; capture it from
# a failing lane log rather than trying to keep a copy in sync by hand.
function Get-GhozttyCompileCommand([string]$log) {
    if (-not $log -or -not (Test-Path $log)) { return $null }
    $line = Select-String -Path $log -Pattern '^"[^"]*zig\.exe" test ' | Select-Object -First 1
    if (-not $line) { return $null }
    # zig prints the command with backslashes doubled; undo that, and drop
    # --listen=- so the compiler runs standalone instead of waiting on a
    # build-runner protocol that is not there.
    $cmd = $line.Line -replace '\\\\', '\'
    $cmd = $cmd -replace '\s--listen=-\s*$', ''
    # Split off the leading "...zig.exe" so the rest can be handed to
    # CreateProcess as a raw argument string.
    if ($cmd -match '^"([^"]+)"\s+(.*)$') {
        return [pscustomobject]@{ Exe = $Matches[1]; Args = $Matches[2] }
    }
    return $null
}

$results = @()

# The lane's compile command is ~10 KB, well past cmd.exe's 8191-character
# limit, so `cmd /c "<cmd> > log"` dies with "The command line is too long"
# before zig is ever launched. CreateProcess allows 32767, so go straight to
# it and hand the arguments over as one raw string - no shell, no re-tokenizing.
function Invoke-Raw([string]$exe, [string]$argString, [string]$outFile) {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $exe
    $psi.Arguments = $argString
    $psi.WorkingDirectory = (Get-Location).Path
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    # Read both pipes concurrently: draining one and then the other deadlocks
    # as soon as the second fills its buffer, and zig is chatty on both.
    $o = $p.StandardOutput.ReadToEndAsync()
    $e = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    Set-Content -Path $outFile -Value ($o.Result + $e.Result) -Encoding UTF8
    return $p.ExitCode
}

function Invoke-Arm([string]$name, [string]$exe, [string]$argString, [int]$n) {
    Write-Host ""
    Write-Host "=== arm '$name' x$n ==="
    for ($i = 1; $i -le $n; $i++) {
        $t0 = Get-Date
        $out = Join-Path $OutDir "$name-$i.log"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $code = Invoke-Raw $exe $argString $out
        $sw.Stop()
        Start-Sleep -Seconds 2   # WER writes the event slightly after the exit
        $crashes = @(Get-ZigCrashesSince $t0)
        $desc = if ($crashes.Count) {
            ($crashes | ForEach-Object { "$($_.App)/$('0x{0:x}' -f [int64]"0x$($_.Code)") @ $($_.Mod)+$($_.Off)" }) -join '; '
        }
        else { '(no Application Error record)' }
        $verdict = if ($code -eq 0) { 'ok' } else { 'FAIL' }
        Write-Host ("  run {0}  {1,-4} exit={2,-4} {3,4}s  {4}" -f $i, $verdict, $code, [int]$sw.Elapsed.TotalSeconds, $desc)
        $script:results += [pscustomobject]@{ Arm = $name; Run = $i; Exit = $code; Seconds = [int]$sw.Elapsed.TotalSeconds; Crash = $desc }
    }
}

if ($Arm -in 'both', 'ghoztty') {
    $cmd = Get-GhozttyCompileCommand $CommandLog
    if (-not $cmd) {
        Write-Host "arm 'ghoztty' SKIPPED: no zig compile command found in -CommandLog '$CommandLog'"
        Write-Host "  (run 'zig build test-agent' until it fails, redirect to a file, pass it here)"
    }
    else {
        Invoke-Arm 'ghoztty' $cmd.Exe $cmd.Args $Runs
    }
}

if ($Arm -in 'both', 'control') {
    $std = Join-Path $zigLib 'std\std.zig'
    # -fno-emit-bin: we are stress-testing the compiler front/middle end, not
    # producing anything. Same compiler, same threads, none of our source.
    $ctrl = "test `"$std`" -fno-emit-bin --global-cache-dir `"$env:ZIG_GLOBAL_CACHE_DIR`" --cache-dir `"$OutDir\ctrl-cache`""
    Invoke-Arm 'control' $zig $ctrl $Runs
}

Write-Host ""
Write-Host "=== summary ==="
foreach ($g in $results | Group-Object Arm) {
    $bad = @($g.Group | Where-Object { $_.Exit -ne 0 })
    Write-Host ("{0,-9} {1}/{2} failed   exits: {3}" -f $g.Name, $bad.Count, $g.Count, (($g.Group.Exit | Sort-Object -Unique) -join ','))
}
$results | Export-Csv -NoTypeInformation -Path (Join-Path $OutDir 'results.csv')
Write-Host "logs + results.csv in $OutDir"
