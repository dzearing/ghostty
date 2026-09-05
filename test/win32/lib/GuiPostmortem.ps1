<#
.SYNOPSIS
    T527 - say WHY a process an acceptance run launched is gone.

.DESCRIPTION
    Twice on 2026-08-06 the Debug GUI vanished in the middle of an acceptance
    run: no panic, no `error:`, the stderr log simply stopped after a normal
    line. Twenty-six later asserts then failed for the wrong reason, and the
    only thing anybody could say afterwards was "the app died". Nothing in the
    harness had read the ONE number that separates the two possible stories -
    the process exit code. An unhandled exception leaves an NTSTATUS there
    (0xC0000005 and friends) and a matching `Application Error` record in the
    Windows Application log; a `ExitProcess`/`abort` from the app or one of its
    dependencies leaves an ordinary small integer and no record at all. Those
    are different bugs with different fixes, and the harness threw the
    distinction away every time.

    This library is the missing read. Give it a pid (and, where the caller has
    it, the process object it launched and the stderr log it pointed the child
    at) and it answers with a verdict a human can act on:

        GUI POSTMORTEM ghoztty.exe pid 43112
          verdict : CRASHED - 0xC0000005 STATUS_ACCESS_VIOLATION
          ...

    It never launches anything and never kills anything - it only reads - so it
    is safe to call from a `finally`, from a SETUP FAIL branch, and from the
    teardown path that runs after a script has already given up.

.NOTES
    Dot-source it:  . "$PSScriptRoot\lib\GuiPostmortem.ps1"
    `lib\TestDesktop.ps1` already does, and records a launch for every process
    it starts, so a GUI script gets the automatic teardown report for free.
    ASCII only, PowerShell 5.1 compatible.
#>

. (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'scripts\lib\CrashDiag.ps1')

# Full NTSTATUS -> name, for the codes a Windows GUI process actually dies
# from. CrashDiag's table is keyed by LOW BYTE because that is all `zig build`
# leaves of a child's exit code; here the whole 32 bits survive, so the answer
# can be exact instead of a candidate list.
#
# Keyed by the printed hex STRING, not by a numeric literal. PowerShell 5.1
# parses `0xC0000005` as an Int32 and therefore as a NEGATIVE number, so a table
# written the obvious way answers nothing for the very codes it exists to name -
# which is exactly how the first run of this file reported an access violation
# as `unnamed NTSTATUS`.
$script:GUIPM_STATUS_NAME = @{
    '0x80000003' = 'STATUS_BREAKPOINT (a debugger break, or a Zig panic that reached __debugbreak)'
    '0xC0000005' = 'STATUS_ACCESS_VIOLATION'
    '0xC000001D' = 'STATUS_ILLEGAL_INSTRUCTION'
    '0xC0000025' = 'STATUS_NONCONTINUABLE_EXCEPTION'
    '0xC0000026' = 'STATUS_INVALID_DISPOSITION'
    '0xC000008C' = 'STATUS_ARRAY_BOUNDS_EXCEEDED'
    '0xC0000094' = 'STATUS_INTEGER_DIVIDE_BY_ZERO'
    '0xC0000096' = 'STATUS_PRIVILEGED_INSTRUCTION'
    '0xC00000FD' = 'STATUS_STACK_OVERFLOW'
    '0xC0000135' = 'STATUS_DLL_NOT_FOUND'
    '0xC0000142' = 'STATUS_DLL_INIT_FAILED'
    '0xC0000374' = 'STATUS_HEAP_CORRUPTION'
    '0xC0000409' = 'STATUS_STACK_BUFFER_OVERRUN (__fastfail)'
    '0xC000041D' = 'STATUS_FATAL_USER_CALLBACK_EXCEPTION (an exception escaped a window procedure)'
    '0xC0000602' = 'STATUS_FAIL_FAST_EXCEPTION'
    '0x40010004' = 'DBG_TERMINATE_PROCESS (something asked Windows to kill it)'
}

# 2^31 as an Int64. Written out rather than as `0x80000000`, for the reason in
# the comment above: that literal is Int32::MinValue here, and comparing an
# exit code against it makes every clean exit look like a crash.
$script:GUIPM_HIGH_BIT = 2147483648L

# The last block Write-GuiPostmortem printed, so a caller - the harness's own
# acceptance script above all - can assert on what a teardown reported without
# having to capture Write-Host output from its own process.
$script:GUIPM_LAST = @()

<#
Turn a raw Win32 exit code into { IsCrash, Hex, Name }.

A process that ends through an unhandled exception exits with the exception
code, and every one of those has the high bit set - so the test is structural
rather than a lookup, and a status this table has never seen is still reported
as a crash (named `unnamed NTSTATUS`) instead of being read as a tidy exit.
#>
function ConvertTo-GuiExitVerdict {
    param([Parameter(Mandatory = $true)][int]$ExitCode)

    $u = ([int64]$ExitCode) -band 0xFFFFFFFFL
    $hex = '0x{0:X8}' -f $u
    if ($u -lt $script:GUIPM_HIGH_BIT) {
        return [pscustomobject]@{ IsCrash = $false; Hex = $hex; Name = '' }
    }
    $name = $script:GUIPM_STATUS_NAME[$hex]
    if (-not $name) { $name = 'unnamed NTSTATUS' }
    return [pscustomobject]@{ IsCrash = $true; Hex = $hex; Name = $name }
}

<#
Read the tail of a child's stderr log, and say whether it stops mid-line.

The T527 evidence was exactly this shape: the last line in the file was a
complete, ordinary `info(win32_ipc)` line and then nothing. That is worth
distinguishing from a file that ends halfway through a write, which says the
process died while the line was being flushed.
#>
function Get-GuiStdErrTail {
    param([string]$Path, [int]$Lines = 12)

    $out = [pscustomobject]@{ Found = $false; Tail = ''; EndsMidLine = $false; Bytes = 0 }
    if (-not $Path) { return $out }
    if (-not (Test-Path -LiteralPath $Path)) { return $out }
    $raw = ''
    try { $raw = [System.IO.File]::ReadAllText($Path) } catch { return $out }
    $out.Found = $true
    $out.Bytes = $raw.Length
    if ($raw.Length -gt 0) { $out.EndsMidLine = -not ($raw.EndsWith("`n")) }
    $all = @($raw -split "`r?`n" | Where-Object { $_ -ne '' })
    if ($all.Count -gt $Lines) { $all = $all[($all.Count - $Lines)..($all.Count - 1)] }
    $out.Tail = ($all -join "`n")
    return $out
}

<#
Any crash dump Windows kept for this process, if the box happens to have WER
LocalDumps armed. Absence is normal and is reported as such rather than as a
failure - arming LocalDumps writes under HKLM and needs elevation, which this
loop does not have.
#>
function Get-GuiCrashDump {
    param([Parameter(Mandatory = $true)][string]$Name, [datetime]$Since = [datetime]::MinValue)

    $dir = Join-Path $env:LOCALAPPDATA 'CrashDumps'
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    $hits = @(Get-ChildItem -LiteralPath $dir -Filter "$stem*.dmp" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $Since } |
        Sort-Object LastWriteTime -Descending)
    if ($hits.Count -eq 0) { return $null }
    return $hits[0].FullName
}

<#
The whole diagnosis for one process.

`-Process` is the System.Diagnostics.Process the caller launched. It is what
makes the exit code readable AT ALL after the process is gone: Windows keeps
the code only while some handle to the process is open, and the harness caches
one at launch for exactly this reason. Without it the answer degrades to
"gone, exit code unknown" rather than lying.

`-WaitSeconds` gives the Application log time to catch up - WER writes its
record a beat after the process disappears - and is only paid when the exit
code says a crash is plausible, so the healthy path costs nothing.
#>
function Get-GuiPostmortem {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [string]$Name = '',
        $Process = $null,
        [string]$StdErr = '',
        [datetime]$Since = [datetime]::MinValue,
        [int]$WaitSeconds = 20
    )

    $alive = $false
    try { $alive = $null -ne (Get-Process -Id $ProcessId -ErrorAction Stop) } catch { $alive = $false }

    $exit = $null
    if (-not $alive -and $Process) {
        try { if ($Process.HasExited) { $exit = [int]$Process.ExitCode } } catch { $exit = $null }
    }

    $verdictLine = ''
    $crashed = $false
    $hex = ''
    $status = ''
    if ($alive) {
        $verdictLine = 'still running'
    } elseif ($null -eq $exit) {
        $verdictLine = 'gone, and no handle was held so Windows no longer has its exit code'
    } else {
        $v = ConvertTo-GuiExitVerdict -ExitCode $exit
        $hex = $v.Hex
        $status = $v.Name
        $crashed = $v.IsCrash
        if ($crashed) {
            $verdictLine = "CRASHED - $hex $status"
        } elseif ($exit -eq 0) {
            $verdictLine = 'exited cleanly (0)'
        } else {
            $verdictLine = "exited with $exit ($hex) - an ordinary exit code, so this was a deliberate ExitProcess/abort somewhere, NOT an unhandled exception"
        }
    }

    $evt = $null
    $dump = $null
    if ($crashed) {
        $since = $Since
        if ($since -eq [datetime]::MinValue) { $since = (Get-Date).AddMinutes(-30) }
        $like = ''
        if ($Name) { $like = $Name }
        $deadline = (Get-Date).AddSeconds($WaitSeconds)
        while ($null -eq $evt) {
            $found = @(Get-ProcessCrashEvent -Since $since -NameLike $like)
            if ($found.Count -gt 0) {
                $mine = @($found | Where-Object { $_.ProcessId -eq ('0x{0:x}' -f $ProcessId) })
                if ($mine.Count -gt 0) { $evt = $mine[-1] } else { $evt = $found[-1] }
                break
            }
            if ((Get-Date) -ge $deadline) { break }
            Start-Sleep -Seconds 2
        }
        if ($Name) { $dump = Get-GuiCrashDump -Name $Name -Since $since }
    }

    $tail = Get-GuiStdErrTail -Path $StdErr

    return [pscustomobject]@{
        ProcessId     = $ProcessId
        Name          = $Name
        Alive         = $alive
        ExitCode      = $exit
        ExitCodeHex   = $hex
        Status        = $status
        Crashed       = $crashed
        Verdict       = $verdictLine
        CrashEvent    = $evt
        DumpPath      = $dump
        StdErrFound   = $tail.Found
        StdErrTail    = $tail.Tail
        StdErrMidLine = $tail.EndsMidLine
    }
}

<#
Print one diagnosis as a block, and remember it.

Everything here goes through Write-Host on purpose: this is called from
teardown and from SETUP FAIL branches, where a script's own pipeline output is
its verdict line and must not be polluted.
#>
function Write-GuiPostmortem {
    param([Parameter(Mandatory = $true)]$Report, [string]$Indent = '  ')

    $lines = @()
    $who = $Report.Name
    if (-not $who) { $who = 'process' }
    $lines += "GUI POSTMORTEM $who pid $($Report.ProcessId)"
    $lines += "  verdict : $($Report.Verdict)"
    if ($Report.CrashEvent) {
        $e = $Report.CrashEvent
        $lines += "  WER     : $($e.App) $($e.ExceptionCode) $($e.ExceptionName) in $($e.Module) +$($e.FaultOffset) at $($e.Time)"
    } elseif ($Report.Crashed) {
        $lines += '  WER     : no Application Error record found for it (the log may lag, or WER is disabled here)'
    }
    if ($Report.DumpPath) {
        $lines += "  dump    : $($Report.DumpPath)"
    } elseif ($Report.Crashed) {
        $lines += '  dump    : none (WER LocalDumps is not armed on this box - see docs/claude/build.md)'
    }
    if ($Report.StdErrFound) {
        $note = if ($Report.StdErrMidLine) { ' (the file stops MID-LINE, so it died while writing)' } else { ' (the file ends on a complete line, so it died between writes)' }
        $lines += "  stderr  :$note"
        foreach ($l in ($Report.StdErrTail -split "`n")) { if ($l) { $lines += "    | $l" } }
    }

    $script:GUIPM_LAST = $lines
    foreach ($l in $lines) { Write-Host ($Indent + $l) }
    return
}

# The lines Write-GuiPostmortem printed last. Empty when nothing has been
# reported, which is what a healthy run looks like.
function Get-LastGuiPostmortem {
    return @($script:GUIPM_LAST)
}

function Clear-LastGuiPostmortem {
    $script:GUIPM_LAST = @()
}
