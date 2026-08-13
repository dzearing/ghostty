<#
.SYNOPSIS
    Run a program (or a lane's test binary) under cdb and keep the crash: a
    full minidump plus every thread's symbolised stack. T450.

.DESCRIPTION
    Zig's own segfault handler dies in a recursive panic on this box, so a
    crashing test binary leaves nothing but

        Segmentation fault at address 0xffffffffffffffff
        aborting due to recursive panic

    and every investigation into the T443 corruption has started from that.
    Running under a debugger takes the exception on FIRST chance -- before any
    in-process handler -- and walks EVERY thread, which is the point: the
    thread that scribbled over memory is not the thread that trips over it.

    No install and no elevation: the Microsoft Store WinDbg package already on
    this box ships a console cdbX64.exe.

.PARAMETER Lane
    Catch the newest test binary a zig lane built, instead of naming an exe.
    `agent` covers both agent test binaries and tries them in turn.

.PARAMETER Attempts
    Re-run until a crash is caught, up to this many times. The T443 crash lands
    on roughly half of runs, so one clean attempt proves nothing.

.PARAMETER Last
    Do not run anything: read the dump Windows already wrote for this lane's
    test binary the last time it died (T460). That is the crash that actually
    happened, it takes about a second, and it is the ONLY path that works for a
    crash which does not reproduce. -Since bounds how far back to look.

.PARAMETER FromDump
    Same, for a dump named explicitly.

.PARAMETER Status
    Report whether Windows is keeping a dump when a process dies at all, and
    how to arm it if not.

.OUTPUTS
    A `-- crash stack --` block, and the dump/transcript paths.
    Exit 0 = ran clean (no crash caught), 1 = a crash was caught and captured,
    2 = could not run (no cdb, no such exe, nothing built for the lane, no dump
    to read).

.EXAMPLE
    powershell -NoProfile -File scripts\crash-catch.ps1 -Lane agent -Last
.EXAMPLE
    powershell -NoProfile -File scripts\crash-catch.ps1 -Lane agent -Attempts 6
.EXAMPLE
    powershell -NoProfile -File scripts\crash-catch.ps1 -Exe .\zig-out\bin\ghoztty.exe -Arguments '+list'
#>
[CmdletBinding()]
param(
    [ValidateSet('none', 'win32', 'agent')][string]$Lane,
    [string]$Exe,
    [string[]]$Arguments = @(),
    [int]$Attempts = 1,
    [int]$TimeoutSeconds = 1200,
    [string]$OutDir,
    [string]$Cdb,
    [switch]$Last,
    [string]$FromDump,
    [switch]$Status,
    [int]$SinceHours = 24,
    [string]$Repo = 'D:\git\ghoztty'
)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\lib\CrashCatch.ps1"
. "$PSScriptRoot\lib\CrashDump.ps1"

if ($Status) {
    $armed = Write-WerArmedStatus -ExeNames @('ghostty-test.exe')
    exit $(if ($armed) { 0 } else { 2 })
}

$cdbPath = Get-CdbPath -Override $Cdb
if (-not $cdbPath) {
    Write-Host 'crash-catch: no cdb.exe found.'
    Write-Host '  Looked for the Store WinDbg console debugger at'
    Write-Host ('  ' + (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\Microsoft.WinDbg_8wekyb3d8bbwe\cdbX64.exe'))
    Write-Host '  and the Windows Kits copy under "Windows Kits\10\Debuggers\x64".'
    Write-Host '  Install WinDbg from the Store, or set $env:GHOZTTY_CDB to a cdb.exe.'
    exit 2
}
Write-Host "crash-catch: cdb = $cdbPath"

# ------------------------------------------- read a crash that already happened

if ($Last -or $FromDump) {
    $dumpPath = $FromDump
    $sym = $null
    if (-not $dumpPath) {
        if (-not $Lane) {
            Write-Host 'crash-catch: -Last needs -Lane <none|win32|agent> (whose binary died?).'
            exit 2
        }
        $bins = @(Get-LaneTestBinary -Lane $Lane -Repo $Repo)
        if ($bins.Count -eq 0) {
            Write-Host "crash-catch: nothing built for lane '$Lane' -- run the lane once first."
            exit 2
        }
        $names = @($bins | ForEach-Object { Split-Path -Leaf $_ })
        $found = Find-WerCrashDump -ExeNames $names -Since (Get-Date).AddHours(-$SinceHours) -WaitSeconds 1
        if (-not $found) {
            Write-Host ("crash-catch: no dump for " + ($names -join ', ') + " in the last $SinceHours h.")
            $null = Write-WerArmedStatus -ExeNames $names
            exit 2
        }
        $dumpPath = $found.FullName
        $match = @($bins | Where-Object { (Split-Path -Leaf $_) -eq (($found.Name -replace '\.\d+\.dmp$', '')) })
        if ($match.Count -gt 0) { $sym = Split-Path -Parent $match[0] }
    }
    if (-not (Test-Path -LiteralPath $dumpPath)) {
        Write-Host "crash-catch: no such dump: $dumpPath"
        exit 2
    }
    if (-not $sym -and $Lane) {
        $bins = @(Get-LaneTestBinary -Lane $Lane -Repo $Repo)
        if ($bins.Count -gt 0) { $sym = Split-Path -Parent $bins[0] }
    }
    Write-Host "crash-catch: reading $dumpPath (no re-run)"
    $r = Invoke-CrashDumpAnalysis -DumpPath $dumpPath -SymbolPath $sym -OutDir $OutDir -Cdb $Cdb -Repo $Repo
    if (Write-CrashDumpStack -Result $r) { exit 1 }
    exit 2
}

# ------------------------------------------------------------- what to run

$targets = @()
if ($Exe) { $targets = @($Exe) }
elseif ($Lane) {
    $targets = @(Get-LaneTestBinary -Lane $Lane -Repo $Repo)
    if ($targets.Count -eq 0) {
        Write-Host "crash-catch: nothing built for lane '$Lane' under $Repo\.zig-cache\o -- run the lane once first."
        exit 2
    }
    Write-Host ("crash-catch: lane $Lane -> " + (($targets | ForEach-Object { Split-Path -Leaf $_ }) -join ', '))
}
else {
    Write-Host 'crash-catch: pass -Lane <none|win32|agent> or -Exe <path>.'
    exit 2
}

# ------------------------------------------------------------------- run it

$caught = $null
foreach ($t in $targets) {
    if (-not (Test-Path -LiteralPath $t)) {
        Write-Host "crash-catch: no such exe: $t"
        exit 2
    }
    $r = Invoke-CrashCatch -Exe $t -Arguments $Arguments -OutDir $OutDir `
        -Attempts $Attempts -TimeoutSeconds $TimeoutSeconds -Cdb $Cdb -Repo $Repo
    if ($r -and $r.Crashed) { $caught = $r; break }
    # NOT $last: PowerShell variable names are case-insensitive, so that would
    # be the -Last switch parameter, and assigning a result object to it throws
    # a transformation error mid-run (caught by crash-stacks.ps1).
    $lastResult = $r
}

if ($caught) {
    $null = Write-CrashStack -Result $caught
    exit 1
}

$null = Write-CrashStack -Result $lastResult
exit 0
