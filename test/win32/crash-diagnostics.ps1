<#
.SYNOPSIS
    T444 - a crashed child must be reported as a crash, not as a bare exit code.

.DESCRIPTION
    `zig build` can end a step with nothing but

        error: the following command exited with error code 5:

    Two investigations read that as a compile failure whose diagnostic went
    missing. It is neither: the child CRASHED, and 5 is the low byte of
    0xC0000005 STATUS_ACCESS_VIOLATION, because `std.process.Child` truncates
    the Windows exit code to a byte (lib/std/process/Child.zig:462).

    This script proves the decode and the crash-log correlation that
    `scripts/lib/CrashDiag.ps1` adds, end to end, against a REAL access
    violation -- not a mocked one.

.OUTPUTS
    One `ALL PASS` / `N FAILURE(S)` line last, per the house convention.
#>
[CmdletBinding()]
param(
    [string]$Repo = 'D:\git\ghoztty'
)

# T675: suppress the app's startup job self-escape - this harness tracks the
# pids it launches, and a pane-launched app would otherwise hand its work to
# a respawned twin mid-test.
$env:GHOZTTY_NO_STARTUP_ESCAPE = '1'

$ErrorActionPreference = 'Continue'
. "$Repo\scripts\lib\CrashDiag.ps1"

$failures = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host "PASS $Name" }
    else { Write-Host "FAIL $Name $Detail"; $script:failures++ }
}

# ------------------------------------------------------- 1. the decode itself

$av = @(Get-NtStatusCandidate -Code 5)
Check 'decode 5 -> access violation' ($av.Count -eq 1 -and $av[0].Hex -eq '0xC0000005') "got $($av | ForEach-Object { $_.Hex })"

$bp = @(Get-NtStatusCandidate -Code 3)
Check 'decode 3 -> breakpoint' ($bp.Count -eq 1 -and $bp[0].Hex -eq '0x80000003') "got $($bp | ForEach-Object { $_.Hex })"

$so = @(Get-NtStatusCandidate -Code 253)
Check 'decode 253 -> stack overflow' ($so.Count -eq 1 -and $so[0].Hex -eq '0xC00000FD') "got $($so | ForEach-Object { $_.Hex })"

# A raw negative Int32 (what PowerShell reports for a crash) folds to the same
# byte zig would have printed, so callers can pass either.
$raw = @(Get-NtStatusCandidate -Code -1073741819)
Check 'decode raw 0xC0000005 -> access violation' ($raw.Count -eq 1 -and $raw[0].Hex -eq '0xC0000005')

# Codes no crash produces must stay silent rather than guess.
Check 'exit 1 is not decoded as a crash' ((@(Get-NtStatusCandidate -Code 1)).Count -eq 0)
Check 'exit 7 is not decoded as a crash' ((@(Get-NtStatusCandidate -Code 7)).Count -eq 0)

# ---------------------------------------------------- 2. reading zig's phrasing

$logDir = Join-Path $env:TEMP ("crashdiag-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$fakeLog = Join-Path $logDir 'zig.log'
@(
    'error: the following command exited with error code 5:',
    "error: while executing test 'terminal.PageList.test.whatever', the following command exited with code 3 (expected exited with code 0):",
    'some unrelated line'
) | Set-Content -Path $fakeLog -Encoding ASCII

$codes = @(Get-TruncatedExitCodeFromLog -LogPath $fakeLog)
Check 'both zig exit-code phrasings are read' (($codes -contains 5) -and ($codes -contains 3)) "got [$($codes -join ',')]"
Check 'the expected-code-0 clause is not read as a failure' (-not ($codes -contains 0)) "got [$($codes -join ',')]"

# --------------------------------------------- 3. a REAL access violation, live

$crashDir = Join-Path (Split-Path -Qualifier $Repo) ('\crashdiag-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $crashDir -Force | Out-Null
$src = Join-Path $crashDir 'av.zig'
@(
    'pub fn main() void {',
    '    const p: *volatile u8 = @ptrFromInt(0x10);',
    '    p.* = 1;',
    '}'
) | Set-Content -Path $src -Encoding ASCII

if (-not $env:ZIG_GLOBAL_CACHE_DIR) {
    # CLAUDE.md: the global cache must sit on the repo's drive.
    $env:ZIG_GLOBAL_CACHE_DIR = (Join-Path (Split-Path -Qualifier $Repo) '\zig-global-cache')
}
Push-Location $crashDir
# ReleaseFast on purpose: that is how the shipped zig.exe is built, so it has no
# segfault handler and dies exactly the way the compiler did in T444's evidence.
$buildOut = & zig build-exe av.zig -OReleaseFast 2>&1
Pop-Location
$exe = Join-Path $crashDir 'av.exe'
Check 'crasher built' (Test-Path $exe) "$buildOut"

if (Test-Path $exe) {
    $since = (Get-Date).AddSeconds(-2)
    $p = Start-Process -FilePath $exe -PassThru -Wait -WindowStyle Hidden
    # Cache the handle before the child exits or ExitCode reads empty.
    $null = $p.Handle
    $code = $p.ExitCode
    Check 'a real AV exits with 0xC0000005' ($code -eq -1073741819) "got $code"
    Check 'that code truncates to the 5 zig prints' ((($code -band 0xFF)) -eq 5) "got $($code -band 0xFF)"

    # WER writes the record a beat later, so poll rather than read once.
    $found = $null
    $deadline = (Get-Date).AddSeconds(30)
    while (-not $found -and (Get-Date) -lt $deadline) {
        $found = @(Get-ProcessCrashEvent -Since $since -NameLike 'av.exe') | Select-Object -First 1
        if (-not $found) { Start-Sleep -Seconds 2 }
    }
    Check 'the crash is found in the Application log' ($null -ne $found)
    if ($found) {
        Check 'the log names the exception' ($found.ExceptionCode -eq '0xc0000005') "got $($found.ExceptionCode)"
        Check 'the exception is named in words' ($found.ExceptionName -match 'ACCESS_VIOLATION') "got '$($found.ExceptionName)'"
    }

    # The whole diagnostic, as a lane would print it: a log saying "error code 5"
    # plus the real crash in the same window.
    $captured = New-Object System.Collections.ArrayList
    $wrote = Write-CrashDiagnostic -Since $since -LogPath $fakeLog -WaitSeconds 20 -Writer { param($s) $null = $captured.Add($s) }
    $text = ($captured -join "`n")
    Check 'the diagnostic printed something' ([bool]$wrote)
    Check 'the diagnostic decodes the exit code' ($text -match 'exit code 5 is the low byte of 0xC0000005')
    Check 'the diagnostic names the crashed process' ($text -match 'CRASH .*av\.exe')
    Check 'the diagnostic explains the truncation' ($text -match 'truncates the Windows exit code')
}

# ----------------------------------------- 4. it must not invent a crash either

$quietSince = Get-Date
$quietLog = Join-Path $logDir 'quiet.log'
'error: the following command exited with error code 5:' | Set-Content -Path $quietLog -Encoding ASCII
$captured2 = New-Object System.Collections.ArrayList
$null = Write-CrashDiagnostic -Since $quietSince -LogPath $quietLog -WaitSeconds 4 -Writer { param($s) $null = $captured2.Add($s) }
$text2 = ($captured2 -join "`n")
Check 'with no crash record the diagnostic says so' ($text2 -match 'no Application Error record') "got '$text2'"

# A lane that failed on an ordinary error stays quiet: no decode, no noise.
$plainLog = Join-Path $logDir 'plain.log'
'error: expected type u8, found u16' | Set-Content -Path $plainLog -Encoding ASCII
$captured3 = New-Object System.Collections.ArrayList
$wrote3 = Write-CrashDiagnostic -Since (Get-Date) -LogPath $plainLog -WaitSeconds 0 -Writer { param($s) $null = $captured3.Add($s) }
Check 'an ordinary compile error prints no crash diagnostic' (-not $wrote3) "got '$($captured3 -join '|')'"

# ------------------------------------------- 5. the wrapper still runs with it

$laneOut = & powershell -NoProfile -File (Join-Path $Repo 'scripts\floor-lane.ps1') -SelfTest 2>&1
$laneText = ($laneOut | Out-String)
Check 'floor-lane self-test still passes with the diagnostic wired in' ($laneText -match 'ALL PASS') `
    "tail: $(($laneOut | Select-Object -Last 3) -join ' / ')"

# --------------------------------------------------------------------- cleanup

Remove-Item $logDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $crashDir -Recurse -Force -ErrorAction SilentlyContinue

if ($failures -eq 0) { Write-Host 'ALL PASS' } else { Write-Host "$failures FAILURE(S)" }
exit $(if ($failures -eq 0) { 0 } else { 1 })
