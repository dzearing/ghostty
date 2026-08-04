<#
.SYNOPSIS
    Decode the exit codes a crashed Windows child reports through `zig build`,
    and correlate them with the Windows Application crash log (T444).

.DESCRIPTION
    `zig build` on Windows can end a step with

        error: the following command exited with error code 5:

    and print no diagnostic at all. Two investigations read that as a compile
    error that was somehow not printed. It is not: the step's child process
    CRASHED, and 5 is what is left of the crash code.

    `std.process.Child` truncates the Windows exit code to a byte
    (`lib/std/process/Child.zig:462`, `@as(u8, @truncate(exit_code))`), so an
    NTSTATUS comes out the other side as its LOW BYTE:

        0xC0000005 ACCESS_VIOLATION   -> 5
        0x80000003 BREAKPOINT         -> 3      (a Zig panic / segfault handler)
        0xC00000FD STACK_OVERFLOW     -> 253
        0xC0000409 STACK_BUFFER_OVERRUN -> 9

    That mapping is lossy, so a low byte on its own is a SUSPICION, never a
    verdict -- a program really can call exit(5). The Windows Application log is
    what turns it into evidence: a crashed process leaves an `Application Error`
    (id 1000) record naming the exe, the exception code, the faulting module and
    the fault offset. This library reads both and prints them together.

.NOTES
    Dot-source it:  . "$PSScriptRoot\lib\CrashDiag.ps1"
    ASCII only, PowerShell 5.1 compatible.
#>

# Exit-code low byte -> the NTSTATUS values that could have produced it. Only
# statuses a build/test lane can plausibly die from are listed; an unknown low
# byte yields nothing and the caller stays quiet rather than guessing.
$script:NT_STATUS_BY_LOW_BYTE = @{
    0x03 = @(@{ Status = 0x80000003; Name = 'STATUS_BREAKPOINT (Zig panic / segfault handler abort)' })
    0x05 = @(@{ Status = 0xC0000005; Name = 'STATUS_ACCESS_VIOLATION' })
    0x09 = @(@{ Status = 0xC0000409; Name = 'STATUS_STACK_BUFFER_OVERRUN (__fastfail)' })
    0x0D = @(@{ Status = 0xC000000D; Name = 'STATUS_INVALID_PARAMETER' })
    0x1D = @(@{ Status = 0xC000001D; Name = 'STATUS_ILLEGAL_INSTRUCTION' })
    0x25 = @(@{ Status = 0xC0000025; Name = 'STATUS_NONCONTINUABLE_EXCEPTION' })
    0x26 = @(@{ Status = 0xC0000026; Name = 'STATUS_INVALID_DISPOSITION' })
    0x35 = @(@{ Status = 0xC0000135; Name = 'STATUS_DLL_NOT_FOUND' })
    0x42 = @(@{ Status = 0xC0000142; Name = 'STATUS_DLL_INIT_FAILED' })
    0x74 = @(@{ Status = 0xC0000374; Name = 'STATUS_HEAP_CORRUPTION' })
    0x8C = @(@{ Status = 0xC000008C; Name = 'STATUS_ARRAY_BOUNDS_EXCEEDED' })
    0x94 = @(@{ Status = 0xC0000094; Name = 'STATUS_INTEGER_DIVIDE_BY_ZERO' })
    0x96 = @(@{ Status = 0xC0000096; Name = 'STATUS_PRIVILEGED_INSTRUCTION' })
    0xFD = @(@{ Status = 0xC00000FD; Name = 'STATUS_STACK_OVERFLOW' })
}

function Get-NtStatusCandidate {
    <#
    .SYNOPSIS
        NTSTATUS values whose low byte matches a truncated exit code.
    .OUTPUTS
        Zero or more objects with Status (uint32), Hex, and Name. Empty means
        "no known crash produces this code" -- report the code as-is.
    #>
    param([Parameter(Mandatory)][int]$Code)

    # Callers may hand us either the truncated byte zig printed, or a raw
    # Windows code (which PowerShell surfaces as a negative Int32). Fold both to
    # the low byte, which is the only part zig kept.
    $low = $Code -band 0xFF
    $hits = $script:NT_STATUS_BY_LOW_BYTE[$low]
    if (-not $hits) { return @() }
    return @($hits | ForEach-Object {
            [pscustomobject]@{
                Status = $_.Status
                Hex    = ('0x{0:X8}' -f $_.Status)
                Name   = $_.Name
            }
        })
}

function Get-ProcessCrashEvent {
    <#
    .SYNOPSIS
        `Application Error` (id 1000) records in a time window, parsed.
    .DESCRIPTION
        This is the half that makes a low-byte guess into evidence: it names the
        process that actually died, with the real exception code.
    #>
    param(
        [Parameter(Mandatory)][datetime]$Since,
        [datetime]$Until = [datetime]::MaxValue,
        [string]$NameLike
    )

    $filter = @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = $Since }
    # -ErrorAction SilentlyContinue is load-bearing: Get-WinEvent THROWS on an
    # empty match ("No events were found"), and an empty match is the normal,
    # healthy case.
    $events = @(Get-WinEvent -FilterHashtable $filter -ErrorAction SilentlyContinue)

    $out = @()
    foreach ($e in $events) {
        if ($e.TimeCreated -gt $Until) { continue }
        $m = $e.Message
        $app = if ($m -match 'Faulting application name:\s*([^,]+)') { $Matches[1].Trim() } else { '?' }
        if ($NameLike -and ($app -notlike $NameLike)) { continue }
        $exc = if ($m -match 'Exception code:\s*(0x[0-9a-fA-F]+)') { $Matches[1] } else { '?' }
        $mod = if ($m -match 'Faulting module name:\s*([^,]+)') { $Matches[1].Trim() } else { '?' }
        $off = if ($m -match 'Fault offset:\s*(0x[0-9a-fA-F]+)') { $Matches[1] } else { '?' }
        $fpid = if ($m -match 'Faulting process id:\s*(0x[0-9a-fA-F]+)') { $Matches[1] } else { '?' }

        $excName = ''
        $excVal = 0
        if ($exc -ne '?' -and [int]::TryParse($exc.Substring(2), [System.Globalization.NumberStyles]::HexNumber, $null, [ref]$excVal)) {
            $cand = @(Get-NtStatusCandidate -Code $excVal)
            if ($cand.Count -gt 0) { $excName = $cand[0].Name }
        }

        $out += [pscustomobject]@{
            Time          = $e.TimeCreated
            App           = $app
            ExceptionCode = $exc
            ExceptionName = $excName
            Module        = $mod
            FaultOffset   = $off
            ProcessId     = $fpid
        }
    }
    return @($out | Sort-Object Time)
}

function Get-TruncatedExitCodeFromLog {
    <#
    .SYNOPSIS
        Every exit code `zig build` reported in a log, deduped.
    .DESCRIPTION
        Matches both shapes zig emits:
          "the following command exited with error code 5:"   (a step's child)
          "the following command exited with code 3 (expected exited with code 0)"
                                                              (a test runner)
    #>
    param([Parameter(Mandatory)][string]$LogPath)

    if (-not (Test-Path $LogPath)) { return @() }
    $codes = @{}
    Select-String -Path $LogPath -Pattern 'exited with (?:error )?code (\d+)' -ErrorAction SilentlyContinue |
        ForEach-Object {
            foreach ($m in $_.Matches) {
                $c = [int]$m.Groups[1].Value
                # "(expected exited with code 0)" is the EXPECTATION, not a result.
                if ($c -ne 0) { $codes[$c] = $true }
            }
        }
    return @($codes.Keys | Sort-Object)
}

function Write-CrashDiagnostic {
    <#
    .SYNOPSIS
        Print why a lane's exit code is what it is: decode it, and name any
        process that crashed in the same window.
    .PARAMETER WaitSeconds
        Windows Error Reporting writes the Application Error record a beat after
        the process dies, so a diagnostic that reads the log immediately can miss
        its own crash. Poll for up to this long -- but only when the exit code
        actually looks like a crash, so a plain red lane is not slowed down.
    #>
    param(
        [Parameter(Mandatory)][datetime]$Since,
        [string]$LogPath,
        [int]$WaitSeconds = 20,
        [scriptblock]$Writer = { param($s) Write-Host $s }
    )

    $codes = @()
    if ($LogPath) { $codes = @(Get-TruncatedExitCodeFromLog -LogPath $LogPath) }

    $suspect = $false
    $lines = @()
    foreach ($c in $codes) {
        $cand = @(Get-NtStatusCandidate -Code $c)
        if ($cand.Count -eq 0) { continue }
        $suspect = $true
        foreach ($k in $cand) {
            $lines += ("  exit code {0} is the low byte of {1} {2}" -f $c, $k.Hex, $k.Name)
        }
    }
    if ($suspect) {
        $lines += '  (std.process.Child truncates the Windows exit code to a byte, so a'
        $lines += '   crashed child arrives as NTSTATUS & 0xFF -- see scripts/lib/CrashDiag.ps1)'
    }

    # Only wait on WER when something already looks like a crash.
    $deadline = (Get-Date).AddSeconds($(if ($suspect) { $WaitSeconds } else { 0 }))
    $crashes = @(Get-ProcessCrashEvent -Since $Since)
    while ($crashes.Count -eq 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $crashes = @(Get-ProcessCrashEvent -Since $Since)
    }

    if ($lines.Count -eq 0 -and $crashes.Count -eq 0) { return $false }

    & $Writer "-- crash diagnostics --"
    foreach ($l in $lines) { & $Writer $l }
    if ($crashes.Count -gt 0) {
        foreach ($c in $crashes) {
            & $Writer ("  CRASH {0:HH:mm:ss} {1} pid={2} {3} {4} in {5}+{6}" -f `
                    $c.Time, $c.App, $c.ProcessId, $c.ExceptionCode, $c.ExceptionName, $c.Module, $c.FaultOffset)
        }
    }
    elseif ($suspect) {
        # Say so out loud rather than letting the decode read as a confirmation.
        & $Writer "  (no Application Error record in this window -- the code may be a genuine exit())"
    }
    return $true
}
