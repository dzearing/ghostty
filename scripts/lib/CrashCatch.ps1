<#
.SYNOPSIS
    Catch a crashing Windows process under `cdb` and keep the evidence: a full
    minidump on disk plus symbolised stacks for EVERY thread (T450).

.DESCRIPTION
    Zig's segfault handler dies in a recursive panic on this box, so a crashing
    test binary prints two lines and no stack:

        Segmentation fault at address 0xffffffffffffffff
        aborting due to recursive panic

    The handler faults while walking the stack, which means the one artefact
    that would name the culprit is exactly the artefact the crash destroys.
    Every investigation into the T443 corruption therefore started blind, and
    worse: the handler only ever sees the VICTIM's thread. The thread that did
    the damage is not in the picture at all.

    A debugger sidesteps both problems. It takes the exception on FIRST chance,
    before any in-process handler runs, so the recursive panic never happens,
    and it can walk every thread in the process rather than the one that
    tripped over the damage.

    `cdb.exe` IS available on this box, contrary to what T443/T449/T450 all
    recorded: the Microsoft Store WinDbg package ships a console `cdbX64.exe`
    under %LOCALAPPDATA%\Microsoft\WindowsApps\Microsoft.WinDbg_8wekyb3d8bbwe.
    Nothing needs installing and nothing needs elevation. See Get-CdbPath.

.NOTES
    Dot-source it:  . "$PSScriptRoot\lib\CrashCatch.ps1"
    ASCII only, PowerShell 5.1 compatible.

    Two cdb details that cost an experiment each and are easy to re-break:

    1. Paths inside a QUOTED cdb command string are parsed by cdb, which treats
       backslash as an escape -- `.dump /ma D:\a\b.dmp` arrives as `D:ab.dmp`.
       Use FORWARD slashes inside those strings (Windows accepts them) rather
       than doubling backslashes.
    2. cdb's initial commands (-c / -cf) run at the FIRST break, which is the
       loader breakpoint. That is where the exception filters get registered
       (`sxe -c "<commands>" av`), and only then does `g` start the program.
       Passing -g skips the loader break, so the first break becomes the crash
       itself and the filters are registered too late to ever fire.
#>

# ------------------------------------------------------------- finding cdb

function Get-CdbPath {
    <#
    .SYNOPSIS
        Path to a console cdb.exe, or $null.
    .DESCRIPTION
        Ordered by what actually exists on this box first. The Store WinDbg
        package is the one that is present, and it needs no install step -- the
        "cdb is not installed" note in T443/T449/T450 was reading only for the
        Windows Kits copy, which is genuinely absent (that directory ships
        dbghelp.dll and friends but no debugger).
    .PARAMETER Override
        An explicit path to prefer. $env:GHOZTTY_CDB does the same thing.
    #>
    param([string]$Override)

    $candidates = @()
    if ($Override) { $candidates += $Override }
    if ($env:GHOZTTY_CDB) { $candidates += $env:GHOZTTY_CDB }
    $candidates += (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\Microsoft.WinDbg_8wekyb3d8bbwe\cdbX64.exe')
    $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Debuggers\x64\cdb.exe')
    $candidates += (Join-Path $env:ProgramFiles 'Windows Kits\10\Debuggers\x64\cdb.exe')

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path -LiteralPath $c).Path }
    }
    $onPath = Get-Command 'cdb.exe' -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    return $null
}

# --------------------------------------------------------- locating binaries

# The test binaries each zig lane produces. `none` and `win32` build the same
# name into different cache directories, so these are matched newest-first by
# write time rather than by path.
$script:LANE_TEST_EXES = @{
    'none'  = @('ghostty-test.exe')
    'win32' = @('ghostty-test.exe')
    'agent' = @('ghoztty-agent-test.exe', 'ghoztty-agent-core-test.exe')
}

function Get-NewestBuiltBinary {
    <#
    .SYNOPSIS
        The most recently built copy of a named exe under .zig-cache\o, or $null.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Repo = 'D:\git\ghoztty'
    )
    $root = Join-Path $Repo '.zig-cache\o'
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    $hit = Get-ChildItem -LiteralPath $root -Recurse -Filter $Name -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

function Get-FailingTestBinaryFromLog {
    <#
    .SYNOPSIS
        The exact test exe `zig build` was running when the lane failed.
    .DESCRIPTION
        Preferred over newest-by-write-time, which is a guess: the `none` and
        `win32` lanes build the SAME exe name into different cache directories,
        so if one of them hits a cache and does not relink, "newest" points at
        the other lane's binary and the capture re-runs the wrong program.

        zig prints the command under its failure line:

            error: while executing test '...', the following command exited ...
            ".\\.zig-cache\\o\\<hash>\\ghostty-test.exe" "--cache-dir=..." ...

        with backslashes doubled, hence the unescape.
    .OUTPUTS
        An absolute path, or $null when the log does not name one.
    #>
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [string]$Repo = 'D:\git\ghoztty'
    )
    if (-not (Test-Path -LiteralPath $LogPath)) { return $null }
    $hit = Select-String -Path $LogPath -Pattern '"([^"]*\.zig-cache[^"]*\.exe)"' -ErrorAction SilentlyContinue |
        Select-Object -Last 1
    if (-not $hit) { return $null }
    $raw = $hit.Matches[0].Groups[1].Value -replace '\\\\', '\'
    $raw = $raw -replace '^\.[\\/]', ''
    $full = if ([IO.Path]::IsPathRooted($raw)) { $raw } else { Join-Path $Repo $raw }
    if (Test-Path -LiteralPath $full) { return (Resolve-Path -LiteralPath $full).Path }
    return $null
}

function Get-LaneTestBinary {
    <#
    .SYNOPSIS
        The most recently built test exe(s) for a lane, newest first.
    .DESCRIPTION
        `zig build` leaves them under .zig-cache\o\<hash>\. Running one directly
        is far cheaper than re-running the lane (no build, no build runner) and
        is how T443's repro loop already works.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('none', 'win32', 'agent')][string]$Lane,
        [string]$Repo = 'D:\git\ghoztty'
    )
    $out = @()
    foreach ($n in $script:LANE_TEST_EXES[$Lane]) {
        $hit = Get-NewestBuiltBinary -Name $n -Repo $Repo
        if ($hit) { $out += $hit }
    }
    return @($out)
}

# ------------------------------------------------------------- the catch itself

# Exception filters worth breaking on. Deliberately only the ones that are
# always fatal: a debugger that stops on every benign first-chance C++ or COM
# exception would fire constantly inside the WebView2 tests and catch nothing.
$script:FATAL_FILTERS = @(
    'av', # access violation      0xC0000005 -- the T443 signature
    'sov', # stack overflow         0xC00000FD
    'ii', # illegal instruction    0xC000001D
    'dz', # integer divide by zero 0xC0000094
    'c0000374', # heap corruption
    'c0000409'      # stack buffer overrun / __fastfail
)

function New-CdbScript {
    <#
    .SYNOPSIS
        The cdb command script that registers the filters and runs the program.
    .DESCRIPTION
        Written as ONE line: cdb's -cf joins a multi-line script with spaces
        rather than newlines, which silently glues `g` onto the end of the
        previous command.
    .PARAMETER PrologCommands
        Extra commands to run at the loader break BEFORE the filters are
        registered -- e.g. the databreak entry breakpoint (DataBreak.ps1).
        Each element must be a complete, self-contained cdb command.
    #>
    param(
        [Parameter(Mandatory)][string]$DumpPath,
        [int]$MaxFrames = 60,
        [string[]]$PrologCommands = @()
    )
    # Forward slashes on purpose -- see the backslash note at the top.
    $dump = $DumpPath -replace '\\', '/'
    $onCrash = @(
        '.echo GHOZTTY-CRASH-BEGIN',
        '.lines -e',
        '.exr -1',
        '.ecxr',
        ".echo GHOZTTY-FAULTING-THREAD",
        "kv $MaxFrames",
        '.echo GHOZTTY-ALL-THREADS',
        "~*kv $MaxFrames",
        ".dump /ma $dump",
        '.echo GHOZTTY-CRASH-END',
        'q'
    ) -join ';'

    $cmds = @()
    foreach ($c in $PrologCommands) { $cmds += $c }
    foreach ($f in $script:FATAL_FILTERS) { $cmds += ('sxe -c "' + $onCrash + '" ' + $f) }
    $cmds += 'g'
    $cmds += 'q'
    return ($cmds -join '; ')
}

function Read-CrashCatchLog {
    <#
    .SYNOPSIS
        Turn a cdb transcript into the facts a caller needs.
    #>
    param([Parameter(Mandatory)][string]$LogPath)

    $res = [pscustomobject]@{
        Crashed       = $false
        ExceptionCode = ''
        ExceptionName = ''
        FaultSite     = ''
        ThreadCount   = 0
        SourceLines   = 0
        FaultingStack = @()
        AllStacks     = @()
    }
    if (-not (Test-Path -LiteralPath $LogPath)) { return $res }
    $lines = @(Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue)
    # ANCHORED, and only ever on a line that is nothing but the marker.
    #
    # cdb echoes its initial command back at the prompt before running it, and
    # that command CONTAINS every marker as `.echo GHOZTTY-CRASH-BEGIN`. A
    # substring match therefore reports a crash on every clean run -- which is
    # exactly the false positive this catcher exists to avoid producing.
    # A real marker line is the word alone, optionally behind cdb's `N:MMM>`
    # prompt.
    function Test-Marker {
        param([string]$Line, [string]$Marker)
        return ($Line -match ('^\s*(?:\d+:\d+>\s*)?' + [regex]::Escape($Marker) + '\s*$'))
    }
    $begin = -1; $faulting = -1; $all = -1; $end = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($begin -lt 0 -and (Test-Marker $lines[$i] 'GHOZTTY-CRASH-BEGIN')) { $begin = $i }
        elseif ($faulting -lt 0 -and (Test-Marker $lines[$i] 'GHOZTTY-FAULTING-THREAD')) { $faulting = $i }
        elseif ($all -lt 0 -and (Test-Marker $lines[$i] 'GHOZTTY-ALL-THREADS')) { $all = $i }
        elseif ($end -lt 0 -and (Test-Marker $lines[$i] 'GHOZTTY-CRASH-END')) { $end = $i }
    }
    if ($begin -lt 0) { return $res }
    $res.Crashed = $true
    if ($end -lt 0) { $end = $lines.Count - 1 }

    $body = $lines[$begin..$end]
    $text = $body -join "`n"
    if ($text -match 'ExceptionCode:\s*([0-9a-fA-F]{8})') { $res.ExceptionCode = '0x' + $Matches[1].ToLower() }
    if (-not $res.ExceptionCode -and $text -match 'code ([0-9a-fA-F]{8}) \(') { $res.ExceptionCode = '0x' + $Matches[1].ToLower() }
    if ($text -match 'ExceptionAddress:\s*\S+\s*\(([^)]+)\)') { $res.FaultSite = $Matches[1] }
    if ($text -match '\(([^)]*Access violation[^)]*)\)') { $res.ExceptionName = $Matches[1] }
    # `.exr -1` names the code in parentheses beside it ("80000003 (Break
    # instruction exception)"). Reading that is what keeps a post-mortem block
    # from printing a bare hex number with no words next to it.
    if (-not $res.ExceptionName -and $text -match 'ExceptionCode:\s*[0-9a-fA-F]{8}\s*\(([^)]+)\)') {
        $res.ExceptionName = $Matches[1].Trim()
    }
    if (-not $res.ExceptionName -and $text -match '- code [0-9a-fA-F]+ \(') {
        if ($text -match '\): ([A-Za-z ]+) - code') { $res.ExceptionName = $Matches[1].Trim() }
    }

    if ($faulting -ge 0) {
        $stop = if ($all -gt $faulting) { $all - 1 } else { $end }
        $res.FaultingStack = @($lines[($faulting + 1)..$stop])
    }
    if ($all -ge 0) {
        $res.AllStacks = @($lines[($all + 1)..$end])
        # "  N  Id: pid.tid Suspend: ..." heads each thread ~*kv prints.
        $res.ThreadCount = @($res.AllStacks | Where-Object { $_ -match '^\s*[.#]?\s*\d+\s+Id:\s' }).Count
    }
    # A source-line count is the difference between a usable stack and a list of
    # offsets -- it is what T450's second goal actually asks for.
    $res.SourceLines = @($res.AllStacks | Where-Object { $_ -match '\[[A-Za-z]:\\.+ @ \d+\]' }).Count
    return $res
}

function Remove-OldCrashCapture {
    <#
    .SYNOPSIS
        Keep only the newest N captures in a directory.
    .DESCRIPTION
        A `/ma` dump of a test binary runs 120-450 MB. Three red floor runs put
        953 MB in .dumps\ during this task's own validation, and the directory is
        gitignored so nothing else would ever notice it growing. Keep 3: enough
        to compare crashes against each other, bounded near a gigabyte.

        Scoped by NAME SHAPE to what this library writes
        (`<exe>-<yyyyMMdd>-<HHmmss>-<attempt>.<ext>`), so it cannot delete the
        T48 freeze watchdog's `ghoztty-<pid>-hang-<stamp>.dmp` files sharing the
        same directory.
    #>
    param(
        [Parameter(Mandatory)][string]$OutDir,
        [int]$Keep = 3
    )
    if (-not (Test-Path -LiteralPath $OutDir)) { return }
    $pattern = '-\d{8}-\d{6}-\d+$'
    $groups = Get-ChildItem -LiteralPath $OutDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '-\d{8}-\d{6}-\d+(\.err)?\.(dmp|log|cdb)$' } |
        Group-Object { ($_.Name -replace '(\.err)?\.(dmp|log|cdb)$', '') } |
        Where-Object { $_.Name -match $pattern }
    if ($groups.Count -le $Keep) { return }
    $stale = $groups |
        Sort-Object { ($_.Group | Measure-Object LastWriteTime -Maximum).Maximum } -Descending |
        Select-Object -Skip $Keep
    foreach ($g in $stale) {
        foreach ($f in $g.Group) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    }
}

function Get-LastProgressLine {
    <#
    .SYNOPSIS
        The last thing Zig's test runner said before it died, cleaned up.
    .DESCRIPTION
        That line names the test that was running -- `2066/3833
        terminal.search.screen.test.simple search with history...` -- which is
        the landmark every T443 datum is keyed to. It arrives on stderr wrapped
        in progress escape sequences and carriage returns, so it needs undoing
        before it is readable.
    #>
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return '' }
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if (-not $raw) { return '' }
    $clean = $raw -replace "\x1b\[[0-9;?]*[a-zA-Z]", '' -replace "\x1b[()][A-Za-z0-9]", ''
    $parts = $clean -split "[`r`n]" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '\S' }
    if (-not $parts) { return '' }
    # Prefer a real progress line; fall back to whatever was said last.
    $progress = @($parts | Where-Object { $_ -match '^\d+/\d+\s' })
    if ($progress.Count -gt 0) { return $progress[-1] }
    return $parts[-1]
}

function Invoke-CrashCatch {
    <#
    .SYNOPSIS
        Run a program under cdb; on a fatal exception write a full dump and
        every thread's stack, then return what was found.
    .PARAMETER Attempts
        Run the program up to this many times, stopping at the first crash. The
        T443 crash is intermittent (roughly half of runs), so a single attempt
        is not evidence of anything when it comes back clean.
    .OUTPUTS
        One object per call: Crashed, Attempt, Attempts, ExceptionCode,
        ExceptionName, FaultSite, ThreadCount, SourceLines, LastTest, DumpPath,
        LogPath, ErrLogPath, FaultingStack, AllStacks, ExitCode, Seconds.
    #>
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @(),
        [string]$OutDir,
        [int]$Attempts = 1,
        [int]$TimeoutSeconds = 1200,
        [int]$Keep = 3,
        [string]$Cdb,
        [string]$Repo = 'D:\git\ghoztty',
        [scriptblock]$Writer = { param($s) Write-Host $s }
    )

    if (-not (Test-Path -LiteralPath $Exe)) { throw "no such exe: $Exe" }
    $exePath = (Resolve-Path -LiteralPath $Exe).Path
    $cdbPath = Get-CdbPath -Override $Cdb
    if (-not $cdbPath) { throw 'no cdb.exe found -- see Get-CdbPath for where it is looked for' }

    if (-not $OutDir) { $OutDir = Join-Path $Repo '.dumps' }
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    $OutDir = (Resolve-Path -LiteralPath $OutDir).Path

    $base = [IO.Path]::GetFileNameWithoutExtension($exePath)
    $result = $null

    for ($a = 1; $a -le $Attempts; $a++) {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $tag = "$base-$stamp-$a"
        $dump = Join-Path $OutDir "$tag.dmp"
        $log = Join-Path $OutDir "$tag.log"
        # Zig's test runner reports progress on stderr, so this is the file that
        # says WHICH test was running when it died -- the landmark every T443
        # datum is keyed to. cdb's own output (the stacks) goes to stdout.
        $errLog = Join-Path $OutDir "$tag.err.log"
        $scriptFile = Join-Path $OutDir "$tag.cdb"
        New-CdbScript -DumpPath $dump | Set-Content -LiteralPath $scriptFile -Encoding ASCII

        # The pdb sits beside the exe in .zig-cache\o\<hash>\; pointing the
        # symbol path at that directory is what turns offsets into source lines.
        $prevSym = $env:_NT_SYMBOL_PATH
        $env:_NT_SYMBOL_PATH = (Split-Path -Parent $exePath)

        # Quote every path element by hand: Start-Process -ArgumentList does not
        # quote its elements (the T200 lesson), so a path with a space would be
        # re-tokenized into separate arguments.
        $argList = @('-lines', '-cf', ('"' + $scriptFile + '"'), ('"' + $exePath + '"'))
        foreach ($x in $Arguments) { $argList += ('"' + $x + '"') }

        & $Writer ("crash-catch: attempt $a/$Attempts -- $cdbPath -> $base")
        $t0 = Get-Date
        $p = Start-Process -FilePath $cdbPath -ArgumentList ($argList -join ' ') `
            -RedirectStandardOutput $log -RedirectStandardError $errLog -NoNewWindow -PassThru
        # Cache the handle before the child exits or ExitCode reads empty
        # (the PS 5.1 Start-Process trap).
        $null = $p.Handle
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            & $Writer "crash-catch: TIMEOUT after ${TimeoutSeconds}s -- killing"
            try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
            $p.WaitForExit(10000) | Out-Null
        }
        $seconds = [int]((Get-Date) - $t0).TotalSeconds
        $env:_NT_SYMBOL_PATH = $prevSym

        $parsed = Read-CrashCatchLog -LogPath $log
        $result = [pscustomobject]@{
            Crashed       = $parsed.Crashed
            Attempt       = $a
            Attempts      = $Attempts
            ExceptionCode = $parsed.ExceptionCode
            ExceptionName = $parsed.ExceptionName
            FaultSite     = $parsed.FaultSite
            ThreadCount   = $parsed.ThreadCount
            SourceLines   = $parsed.SourceLines
            LastTest      = Get-LastProgressLine -Path $errLog
            DumpPath      = $(if (Test-Path -LiteralPath $dump) { $dump } else { '' })
            LogPath       = $log
            ErrLogPath    = $errLog
            FaultingStack = $parsed.FaultingStack
            AllStacks     = $parsed.AllStacks
            ExitCode      = $p.ExitCode
            Seconds       = $seconds
        }
        Remove-Item -LiteralPath $scriptFile -Force -ErrorAction SilentlyContinue
        if ($parsed.Crashed) {
            Remove-OldCrashCapture -OutDir $OutDir -Keep $Keep
            break
        }
        # Nothing to keep from a clean attempt: no dump was written and the
        # transcript is only the program's own output. Keeping them would bury
        # the one run that matters under N that did not.
        Remove-Item -LiteralPath $log, $errLog -Force -ErrorAction SilentlyContinue
        & $Writer "crash-catch: attempt $a ran clean in ${seconds}s"
    }
    return $result
}

function Write-CrashStack {
    <#
    .SYNOPSIS
        Print the compact `-- crash stack --` block for a caught crash.
    .DESCRIPTION
        The faulting thread's frames go to the console; the ALL-thread stacks
        and the dump stay on disk, because the whole point of this task is that
        the thread that did the damage is usually not the one that faulted, and
        that reading takes a human or a follow-up query rather than 40 lines of
        console spam.
    #>
    param(
        [Parameter(Mandatory)]$Result,
        [int]$MaxFrames = 14,
        [scriptblock]$Writer = { param($s) Write-Host $s }
    )
    if (-not $Result) { return $false }
    if (-not $Result.Crashed) {
        & $Writer "-- crash stack --"
        & $Writer ("  no crash in {0} attempt(s) -- the program ran to completion (exit {1})" -f $Result.Attempts, $Result.ExitCode)
        return $false
    }
    & $Writer "-- crash stack --"
    & $Writer ("  {0} {1} at {2}" -f $Result.ExceptionCode, $Result.ExceptionName, $Result.FaultSite)
    & $Writer ("  caught on attempt {0}/{1} in {2}s; {3} thread(s) captured, {4} frame(s) with source lines" -f `
            $Result.Attempt, $Result.Attempts, $Result.Seconds, $Result.ThreadCount, $Result.SourceLines)
    if ($Result.LastTest) { & $Writer ("  running at the time: " + $Result.LastTest) }
    $frames = @($Result.FaultingStack | Where-Object { $_ -match '\S' } | Select-Object -First $MaxFrames)
    foreach ($f in $frames) { & $Writer ("  | " + $f.TrimEnd()) }
    if ($Result.DumpPath) { & $Writer ("  dump (all threads, full memory): " + $Result.DumpPath) }
    & $Writer ("  transcript (every thread's stack): " + $Result.LogPath)
    return $true
}
