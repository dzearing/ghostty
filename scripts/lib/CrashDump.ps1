<#
.SYNOPSIS
    Read the crash dump Windows Error Reporting already wrote, instead of
    re-running the crash to make a new one (T460).

.DESCRIPTION
    T450 gave a crashed lane a stack by re-running the test binary under cdb.
    That only works when the crash REPRODUCES, and the crash it exists for
    lands on about half of runs -- so the first occurrence, the one that
    actually happened, yields nothing, and every intermittent crash is
    diagnosed by trying to provoke it again (D6, user: "we want it to be easy
    to diagnose crashes so that we can capture and fix them faster").

    Measured on this box, 2026-08-12: nothing needed inventing. WER's
    LocalDumps is already enabled machine-wide, and a Debug zig binary that
    dies of an access violation ALREADY leaves a minidump in
    %LOCALAPPDATA%\CrashDumps at the moment it dies -- unattended, on the first
    crash, at zero cost to a run that does not crash. Post-mortemed with
    `cdb -z` it yields exactly what the re-run yields:

        * every thread's stack, not just the faulting one
        * the original fault site (avthread!boom) sitting BELOW zig's
          handleSegfaultWindows frames, so the handler's own abort does not
          destroy it
        * source lines, from the pdb beside the built exe

    in about a second. So the always-on first-chance capture this task asks
    for already existed and nothing READ it. This library is the reader.

    Two measured facts worth keeping, because both are easy to assume wrong:

    1. LocalDumps is HKLM-only. An HKCU\...\Windows Error Reporting\LocalDumps
       key with a DumpFolder is ignored outright -- the dump still went to the
       HKLM default folder. So a per-exe DumpType=2 (full memory) entry needs
       elevation, which makes it an OPTIONAL upgrade rather than a
       precondition: the default mini dump already carries every thread's
       stack, which is what a stack question needs.
    2. The exception recorded in the dump is the ABORT (0x80000003 break),
       not the access violation, because zig's segfault handler runs first and
       then aborts. That is a presentation problem, not a loss: the AV frames
       are still on the same thread's stack under the handler. Write-CrashStack
       says so rather than letting a reader conclude the process died of a
       breakpoint.

.NOTES
    Dot-source it:  . "$PSScriptRoot\lib\CrashDump.ps1"
    Depends on lib\CrashCatch.ps1 for Get-CdbPath / Read-CrashCatchLog /
    Remove-OldCrashCapture, which it dot-sources if they are not loaded yet.
    ASCII only, PowerShell 5.1 compatible.
#>

if (-not (Get-Command Read-CrashCatchLog -ErrorAction SilentlyContinue)) {
    . "$PSScriptRoot\CrashCatch.ps1"
}

# --------------------------------------------------------- is capture armed?

# HKLM, and only HKLM -- see the measured note at the top.
$script:WER_LOCALDUMPS_KEY = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps'

function Get-WerDumpTypeName {
    param([int]$Type)
    switch ($Type) {
        0 { return 'custom' }
        1 { return 'mini' }
        2 { return 'full' }
    }
    return "unknown($Type)"
}

function Get-WerLocalDumpConfig {
    <#
    .SYNOPSIS
        Whether Windows writes a dump when one of our binaries dies, and where.
    .DESCRIPTION
        The presence of the LocalDumps key IS the switch: an empty key means
        enabled with the documented defaults (%LOCALAPPDATA%\CrashDumps, mini,
        keep 10). A per-exe subkey overrides value by value, not wholesale, so
        an exe entry that only sets DumpType still inherits the global folder.
    .PARAMETER ExeName
        Report the settings that would apply to this exe (e.g. ghostty-test.exe).
    .OUTPUTS
        Armed, Scope (none|global|per-exe), DumpFolder, DumpType, DumpTypeName,
        DumpCount, Key.
    #>
    param([string]$ExeName)

    $res = [pscustomobject]@{
        Armed        = $false
        Scope        = 'none'
        DumpFolder   = ''
        DumpType     = 0
        DumpTypeName = ''
        DumpCount    = 0
        Key          = $script:WER_LOCALDUMPS_KEY
    }
    # The seam that reproduces a box with no first-crash capture from this same
    # tree, so the fallback (re-run under cdb) stays measurable and the claim
    # "the lane did not re-run" is falsifiable rather than merely observed.
    # Unset everywhere except that test.
    if ($env:GHOZTTY_CRASH_NO_WER -and $env:GHOZTTY_CRASH_NO_WER -ne '0') { return $res }

    $global = Get-ItemProperty -Path $script:WER_LOCALDUMPS_KEY -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $script:WER_LOCALDUMPS_KEY)) { return $res }

    $res.Armed = $true
    $res.Scope = 'global'
    # Documented defaults for a key that exists but says nothing.
    $folder = '%LOCALAPPDATA%\CrashDumps'
    $type = 1
    $count = 10
    if ($global) {
        if ($null -ne $global.DumpFolder) { $folder = [string]$global.DumpFolder }
        if ($null -ne $global.DumpType) { $type = [int]$global.DumpType }
        if ($null -ne $global.DumpCount) { $count = [int]$global.DumpCount }
    }
    if ($ExeName) {
        $exeKey = Join-Path $script:WER_LOCALDUMPS_KEY $ExeName
        if (Test-Path -LiteralPath $exeKey) {
            $res.Scope = 'per-exe'
            $res.Key = $exeKey
            $per = Get-ItemProperty -Path $exeKey -ErrorAction SilentlyContinue
            if ($per) {
                if ($null -ne $per.DumpFolder) { $folder = [string]$per.DumpFolder }
                if ($null -ne $per.DumpType) { $type = [int]$per.DumpType }
                if ($null -ne $per.DumpCount) { $count = [int]$per.DumpCount }
            }
        }
    }
    # DumpFolder is REG_EXPAND_SZ; Get-ItemProperty hands back the raw string.
    $res.DumpFolder = [Environment]::ExpandEnvironmentVariables($folder)
    $res.DumpType = $type
    $res.DumpTypeName = Get-WerDumpTypeName -Type $type
    $res.DumpCount = $count
    return $res
}

function Write-WerArmedStatus {
    <#
    .SYNOPSIS
        One or three lines saying whether the first crash will be captured.
    #>
    param(
        [string[]]$ExeNames = @('ghostty-test.exe'),
        [scriptblock]$Writer = { param($s) Write-Host $s }
    )
    $cfg = Get-WerLocalDumpConfig -ExeName $ExeNames[0]
    if (-not $cfg.Armed) {
        & $Writer 'first-crash capture: NOT ARMED -- Windows is not keeping a dump when a process dies.'
        & $Writer '  Arm it once, from an elevated shell (machine-wide; HKCU is ignored):'
        & $Writer ('  reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps" /f')
        & $Writer '  Until then a crash can only be diagnosed by reproducing it under cdb.'
        return $false
    }
    & $Writer ("first-crash capture: armed ({0}, {1} dumps, keep {2}) -> {3}" -f `
            $cfg.Scope, $cfg.DumpTypeName, $cfg.DumpCount, $cfg.DumpFolder)
    if ($cfg.DumpType -ne 2) {
        & $Writer ('  mini dumps carry every thread stack, which is what a stack question needs. For full memory, elevated:')
        & $Writer ('  reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\{0}" /v DumpType /t REG_DWORD /d 2 /f' -f $ExeNames[0])
    }
    return $true
}

# ------------------------------------------------------------ finding a dump

function Find-WerCrashDump {
    <#
    .SYNOPSIS
        The newest dump WER wrote for one of these exes since a moment in time.
    .DESCRIPTION
        The -Since guard is the whole safety of this: a dump from last week
        parses perfectly and would be reported as the stack of the crash that
        just happened. A wrong stack is worse than no stack -- it sends the
        next investigation somewhere the bug has never been. So a dump older
        than the run that is asking is never returned.

        WER writes the file after the process is gone and takes a beat over it,
        so this polls for up to -WaitSeconds and only accepts a dump whose size
        has stopped changing.
    .OUTPUTS
        A FileInfo, or $null.
    #>
    param(
        [Parameter(Mandatory)][string[]]$ExeNames,
        [Parameter(Mandatory)][datetime]$Since,
        [int]$WaitSeconds = 20,
        [string]$Folder
    )
    if (-not $Folder) {
        $cfg = Get-WerLocalDumpConfig -ExeName $ExeNames[0]
        if (-not $cfg.Armed) { return $null }
        $Folder = $cfg.DumpFolder
    }
    if (-not $Folder -or -not (Test-Path -LiteralPath $Folder)) { return $null }

    # WER names them "<exe>.<pid>.dmp".
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ($true) {
        $hit = $null
        foreach ($name in $ExeNames) {
            $cand = Get-ChildItem -LiteralPath $Folder -File -Filter ($name + '.*.dmp') -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -ge $Since } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($cand -and (-not $hit -or $cand.LastWriteTime -gt $hit.LastWriteTime)) { $hit = $cand }
        }
        if ($hit) {
            # Still being written? Its length is still moving.
            $len1 = $hit.Length
            Start-Sleep -Milliseconds 400
            $again = Get-Item -LiteralPath $hit.FullName -ErrorAction SilentlyContinue
            if ($again -and $again.Length -eq $len1 -and $len1 -gt 0) { return $again }
        }
        if ((Get-Date) -ge $deadline) { return $null }
        Start-Sleep -Milliseconds 500
    }
}

# ------------------------------------------------------------- reading a dump

function Test-MinidumpHasException {
    <#
    .SYNOPSIS
        Does this dump record an exception -- i.e. is it a crash at all?
    .DESCRIPTION
        Asked of the FILE, not of the debugger, because the debugger cannot
        answer it. cdb opened a dump taken of a healthy, running process (what
        the T48 freeze watchdog writes) and reported
        `ExceptionCode: 80000003 (Break instruction exception)` off the current
        context -- indistinguishable, in its output, from the real breakpoint a
        zig binary aborts on. Reading that as a crash would manufacture a stack
        for a bug that never happened, which is the one failure this whole path
        must not have.

        A minidump says it plainly: an ExceptionStream (type 6) in the stream
        directory. MINIDUMP_HEADER is signature 'MDMP', version, stream count,
        directory RVA; each directory entry is {type, size, rva}.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $fs = $null
    $br = $null
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        $br = New-Object IO.BinaryReader($fs)
        if ($fs.Length -lt 32) { return $false }
        $sig = $br.ReadUInt32()
        if ($sig -ne 0x504D444D) { return $false }   # 'MDMP'
        $null = $br.ReadUInt32()                     # version
        $count = $br.ReadUInt32()
        $dirRva = $br.ReadUInt32()
        if ($count -eq 0 -or $count -gt 4096) { return $false }
        if (($dirRva + 12 * $count) -gt $fs.Length) { return $false }
        $fs.Position = $dirRva
        for ($i = 0; $i -lt $count; $i++) {
            $type = $br.ReadUInt32()
            $size = $br.ReadUInt32()
            $null = $br.ReadUInt32()                 # rva
            if ($type -eq 6 -and $size -gt 0) { return $true }   # ExceptionStream
        }
        return $false
    }
    catch { return $false }
    finally {
        if ($br) { $br.Close() }
        if ($fs) { $fs.Dispose() }
    }
}

function Get-MinidumpMainModulePath {
    <#
    .SYNOPSIS
        The full path of the EXE this dump was taken of, as recorded in it.
    .DESCRIPTION
        WER names its files `<exe>.<pid>.dmp`, and both zig test lanes build a
        `ghostty-test.exe`, so the file name cannot say which program died
        (T855). The dump itself can: MINIDUMP_MODULE_LIST (stream type 4) lists
        every loaded module, and the FIRST entry is the executable, recorded with
        the .zig-cache\o\<hash>\ directory it was built into.

        That directory is what tells a none-lane crash from a win32-lane one --
        and it is also the right place to look for the pdb, which is how a stack
        gets source lines that belong to the build that actually crashed rather
        than to whatever was linked last.

        Layout: MINIDUMP_HEADER {sig,ver,count,dirRva}; directory entries
        {type,size,rva} of 12 bytes; the module list is {count:u32, modules...}
        with each MINIDUMP_MODULE 108 bytes and ModuleNameRva at offset 20; a
        MINIDUMP_STRING is {byteLength:u32, UTF-16 chars}.
    .OUTPUTS
        A string path, or $null when the dump does not carry one.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $fs = $null
    $br = $null
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        $br = New-Object IO.BinaryReader($fs)
        if ($fs.Length -lt 32) { return $null }
        if ($br.ReadUInt32() -ne 0x504D444D) { return $null }   # 'MDMP'
        $null = $br.ReadUInt32()                                # version
        $count = $br.ReadUInt32()
        $dirRva = $br.ReadUInt32()
        if ($count -eq 0 -or $count -gt 4096) { return $null }
        if (($dirRva + 12 * $count) -gt $fs.Length) { return $null }

        $modRva = 0
        $fs.Position = $dirRva
        for ($i = 0; $i -lt $count; $i++) {
            $type = $br.ReadUInt32()
            $size = $br.ReadUInt32()
            $rva = $br.ReadUInt32()
            if ($type -eq 4 -and $size -gt 4) { $modRva = $rva; break }   # ModuleListStream
        }
        if ($modRva -eq 0 -or ($modRva + 4) -gt $fs.Length) { return $null }

        $fs.Position = $modRva
        $nModules = $br.ReadUInt32()
        if ($nModules -eq 0) { return $null }
        # First module = the executable. Its name RVA sits 20 bytes in
        # (BaseOfImage u64, SizeOfImage u32, CheckSum u32, TimeDateStamp u32).
        $fs.Position = $modRva + 4 + 20
        $nameRva = $br.ReadUInt32()
        if (($nameRva + 4) -gt $fs.Length) { return $null }
        $fs.Position = $nameRva
        $bytes = $br.ReadUInt32()
        if ($bytes -eq 0 -or $bytes -gt 4096 -or ($nameRva + 4 + $bytes) -gt $fs.Length) { return $null }
        $raw = $br.ReadBytes([int]$bytes)
        return ([Text.Encoding]::Unicode.GetString($raw)).TrimEnd([char]0)
    }
    catch { return $null }
    finally {
        if ($br) { $br.Close() }
        if ($fs) { $fs.Dispose() }
    }
}

function New-CrashDumpScript {
    <#
    .SYNOPSIS
        The cdb command line for a post-mortem, emitting the SAME markers a
        live catch does so one parser reads both.
    #>
    param([int]$MaxFrames = 60)
    return (@(
            '.lines -e',
            '.echo GHOZTTY-CRASH-BEGIN',
            '.exr -1',
            '.ecxr',
            '.echo GHOZTTY-FAULTING-THREAD',
            "kv $MaxFrames",
            '.echo GHOZTTY-ALL-THREADS',
            "~*kv $MaxFrames",
            '.echo GHOZTTY-CRASH-END',
            'q'
        ) -join '; ')
}

function Test-HandlerAbortStack {
    <#
    .SYNOPSIS
        Did zig's own segfault handler abort the process here?
    .DESCRIPTION
        Then the recorded exception is the handler's breakpoint, not the fault
        that started it, and the real fault frames are further down the same
        thread. Saying so is the difference between a reader chasing a
        breakpoint and a reader reading the stack.
    #>
    param([string[]]$Stacks, [string]$ExceptionCode)
    if (-not $Stacks) { return $false }
    $text = ($Stacks -join "`n")
    if ($text -notmatch 'handleSegfault|posix!?abort|!abort\+') { return $false }
    return ($ExceptionCode -eq '0x80000003' -or $text -match 'handleSegfault')
}

function Invoke-CrashDumpAnalysis {
    <#
    .SYNOPSIS
        Turn a dump Windows already wrote into the same result a live catch
        returns -- without re-running anything.
    .PARAMETER SymbolPath
        Directory holding the pdb for the crashed binary (in this repo, the
        .zig-cache\o\<hash>\ the exe was built into). Without it the frames are
        module+offset rather than source lines.
    .PARAMETER Keep
        A copy of the dump is kept in -OutDir under the same name shape the
        live catcher uses, so it survives WER's own DumpCount rotation and is
        bounded by the same retention.
    .OUTPUTS
        Crashed, Source ('wer'), ExceptionCode, ExceptionName, FaultSite,
        HandlerAbort, ThreadCount, SourceLines, LastTest, DumpPath, LogPath,
        FaultingStack, AllStacks, DumpWritten, Seconds.
    #>
    param(
        [Parameter(Mandatory)][string]$DumpPath,
        [string]$SymbolPath,
        [int]$MaxFrames = 60,
        [string]$OutDir,
        [int]$Keep = 3,
        [int]$TimeoutSeconds = 300,
        [string]$Cdb,
        [string]$Repo = 'D:\git\ghoztty',
        [string]$LaneLog,
        [scriptblock]$Writer = { param($s) Write-Host $s }
    )

    if (-not (Test-Path -LiteralPath $DumpPath)) { throw "no such dump: $DumpPath" }
    $dumpFull = (Resolve-Path -LiteralPath $DumpPath).Path
    $cdbPath = Get-CdbPath -Override $Cdb
    if (-not $cdbPath) { throw 'no cdb.exe found -- see Get-CdbPath for where it is looked for' }
    if (-not (Test-MinidumpHasException -Path $dumpFull)) {
        # Not a crash dump. Answer before spending cdb on it, and keep nothing:
        # a transcript of a healthy process filed under "crash" is worse than
        # no answer, and this is the shape the freeze watchdog writes.
        return [pscustomobject]@{
            Crashed       = $false
            Source        = 'wer'
            Attempt       = 0
            Attempts      = 0
            ExceptionCode = ''
            ExceptionName = ''
            FaultSite     = ''
            HandlerAbort  = $false
            ThreadCount   = 0
            SourceLines   = 0
            LastTest      = ''
            DumpPath      = $dumpFull
            OriginalDump  = $dumpFull
            LogPath       = ''
            FaultingStack = @()
            AllStacks     = @()
            DumpWritten   = $false
            ExitCode      = 0
            Seconds       = 0
        }
    }

    if (-not $OutDir) { $OutDir = Join-Path $Repo '.dumps' }
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    $OutDir = (Resolve-Path -LiteralPath $OutDir).Path

    # "<exe>.<pid>.dmp" -> "<exe>"; the trailing -0 marks a capture that cost no
    # re-run (a live catch numbers its attempts from 1), and keeps the name in
    # the shape Remove-OldCrashCapture is scoped to.
    $leaf = Split-Path -Leaf $dumpFull
    $base = ($leaf -replace '\.exe\.\d+\.dmp$', '') -replace '\.dmp$', ''
    $stamp = (Get-Item -LiteralPath $dumpFull).LastWriteTime.ToString('yyyyMMdd-HHmmss')
    $tag = "$base-$stamp-0"
    $log = Join-Path $OutDir "$tag.log"
    $kept = Join-Path $OutDir "$tag.dmp"

    $prevSym = $env:_NT_SYMBOL_PATH
    if ($SymbolPath) { $env:_NT_SYMBOL_PATH = $SymbolPath }

    $script = New-CrashDumpScript -MaxFrames $MaxFrames
    # Quote by hand: -ArgumentList does not quote its elements (the T200 lesson).
    $argList = @('-lines', '-z', ('"' + $dumpFull + '"'), '-c', ('"' + $script + '"'))

    $t0 = Get-Date
    $errLog = Join-Path $OutDir "$tag.err.log"
    $p = Start-Process -FilePath $cdbPath -ArgumentList ($argList -join ' ') `
        -RedirectStandardOutput $log -RedirectStandardError $errLog -NoNewWindow -PassThru
    # Cache the handle before the child exits or ExitCode reads empty (T197).
    $null = $p.Handle
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        & $Writer "crash-dump: TIMEOUT after ${TimeoutSeconds}s -- killing"
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
        $p.WaitForExit(10000) | Out-Null
    }
    $seconds = [int]((Get-Date) - $t0).TotalSeconds
    $env:_NT_SYMBOL_PATH = $prevSym
    Remove-Item -LiteralPath $errLog -Force -ErrorAction SilentlyContinue

    $parsed = Read-CrashCatchLog -LogPath $log
    # The markers alone are not evidence here, and neither is cdb's exception
    # code: a post-mortem emits both for ANY dump cdb can open, including the
    # T48 freeze watchdog's dumps of a live process, where the "exception" is
    # the current context's break. The dump's own ExceptionStream is the fact,
    # and it was already checked above.
    $isCrash = $parsed.Crashed

    $dumpWritten = $false
    if ($isCrash) {
        try {
            Copy-Item -LiteralPath $dumpFull -Destination $kept -Force -ErrorAction Stop
            $dumpWritten = $true
        }
        catch { $dumpWritten = $false }
        Remove-OldCrashCapture -OutDir $OutDir -Keep $Keep
    }
    else {
        # Nothing to keep from a dump that did not parse as a crash: the
        # transcript is only cdb complaining, and keeping it buries real ones.
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        Crashed       = $isCrash
        Source        = 'wer'
        Attempt       = 0
        Attempts      = 0
        ExceptionCode = $parsed.ExceptionCode
        ExceptionName = $parsed.ExceptionName
        FaultSite     = $parsed.FaultSite
        HandlerAbort  = (Test-HandlerAbortStack -Stacks $parsed.AllStacks -ExceptionCode $parsed.ExceptionCode)
        ThreadCount   = $parsed.ThreadCount
        SourceLines   = $parsed.SourceLines
        LastTest      = (Get-LastProgressLine -Path $LaneLog)
        DumpPath      = $(if ($dumpWritten) { $kept } else { $dumpFull })
        OriginalDump  = $dumpFull
        LogPath       = $(if ($isCrash) { $log } else { '' })
        FaultingStack = $parsed.FaultingStack
        AllStacks     = $parsed.AllStacks
        DumpWritten   = $dumpWritten
        ExitCode      = $p.ExitCode
        Seconds       = $seconds
    }
}

function Write-CrashDumpStack {
    <#
    .SYNOPSIS
        The `-- crash stack --` block for a dump Windows already had.
    .DESCRIPTION
        Same shape as Write-CrashStack, plus the two things only this path can
        say: that the evidence is from the crash that actually happened (no
        re-run, no reproduction), and that the recorded exception is zig's
        handler aborting rather than the fault itself when that is the case.
    #>
    param(
        [Parameter(Mandatory)]$Result,
        [int]$MaxFrames = 14,
        [scriptblock]$Writer = { param($s) Write-Host $s }
    )
    if (-not $Result) { return $false }
    if (-not $Result.Crashed) {
        & $Writer '-- crash stack --'
        & $Writer '  the dump did not parse as a crash, so nothing is claimed from it'
        return $false
    }
    & $Writer '-- crash stack --'
    & $Writer ("  {0} {1} at {2}" -f $Result.ExceptionCode, $Result.ExceptionName, $Result.FaultSite)
    & $Writer ("  from the dump Windows wrote at the moment of the crash -- no re-run, no reproduction ({0}s to read; {1} thread(s), {2} frame(s) with source lines)" -f `
            $Result.Seconds, $Result.ThreadCount, $Result.SourceLines)
    if ($Result.HandlerAbort) {
        & $Writer "  NOTE: that exception is zig's segfault handler aborting. The fault that started it is further down this stack."
    }
    if ($Result.LastTest) { & $Writer ('  running at the time: ' + $Result.LastTest) }
    $frames = @($Result.FaultingStack | Where-Object { $_ -match '\S' } | Select-Object -First $MaxFrames)
    foreach ($f in $frames) { & $Writer ('  | ' + $f.TrimEnd()) }
    if ($Result.DumpPath) { & $Writer ('  dump (all threads): ' + $Result.DumpPath) }
    if ($Result.LogPath) { & $Writer ("  transcript (every thread's stack): " + $Result.LogPath) }
    return $true
}
