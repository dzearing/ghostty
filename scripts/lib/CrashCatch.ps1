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

# The NTSTATUS table lives there, and T478 needs it to say what a nonzero exit
# code MEANS rather than printing a bare number. Dot-sourcing twice is harmless,
# and CrashDiag.ps1 dot-sources nothing itself, so there is no cycle to worry
# about.
. "$PSScriptRoot\CrashDiag.ps1"

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
    'agent' = @('ghoztty-agent-test.exe')
}

# What a lane's test binary is MADE OF, so a candidate can be checked rather
# than assumed (T855).
#
# Newest-mtime alone is not a lane: `none` and `win32` both build
# `ghostty-test.exe`, so whichever lane linked last wins the name for both, and
# `-Lane none` silently ran the win32 binary during the T504 triage. Nothing in
# the output said so, and every number that came out of it was about the other
# program.
#
# Zig embeds each test's fully-qualified name in the binary, and `-Dtest-filter`
# leaves the excluded ones OUT, so the test names answer both questions this
# resolution has to ask:
#
#   Core    - names every full build of that lane must carry. All missing-but-one
#             is a filtered (`-Dtest-filter`) build, which must never stand in
#             for the lane it was cut from.
#   Only    - names ONLY this lane compiles. The win32 apprt is not in the none
#             lane's module graph at all, so its GUI tests are the discriminator.
#             (Pure-logic win32 files like layout_blobs ARE in both lanes -- the
#             markers here are deliberately ones that touch HWNDs.)
#   NotThis - the other lane's `Only` markers, whose PRESENCE proves the
#             candidate is that other lane's binary.
#
# The agent lane's exe has a unique name and cannot be confused with a lane, so
# it carries Core alone -- there is still a filtered build to catch. It is also
# the lane's ONLY binary since T434; a name that is not in this table resolves
# with "no lane signature -- not checked", which is what -ExtraExeNames relies
# on for a fixture run.
$script:LANE_MARKERS = @{
    'none'  = @{
        'ghostty-test.exe' = @{
            Core    = @(
                'terminal.Screen.test.', 'terminal.PageList.test.', 'input.Binding.test.',
                'config.Config.test.', 'cli.args.test.', 'datastruct.blocking_queue.test.'
            )
            Only    = @()
            NotThis = @('apprt.win32.Window.test.', 'apprt.win32.Scrollbar.test.', 'apprt.win32.IpcRegistry.test.')
        }
    }
    'win32' = @{
        'ghostty-test.exe' = @{
            Core    = @(
                'terminal.Screen.test.', 'terminal.PageList.test.', 'input.Binding.test.',
                'config.Config.test.', 'cli.args.test.', 'datastruct.blocking_queue.test.'
            )
            Only    = @('apprt.win32.Window.test.', 'apprt.win32.Scrollbar.test.', 'apprt.win32.IpcRegistry.test.')
            NotThis = @()
        }
    }
    'agent' = @{
        'ghoztty-agent-test.exe' = @{
            Core    = @('remote.agent.server.test.', 'remote.protocol.test.', 'remote.pipe_stream.test.')
            Only    = @()
            NotThis = @()
        }
    }
}

# Verdicts are keyed on path+size+mtime, so re-resolving inside one run (the
# soak asks twice, the harness asks per lane) does not re-read 96 MB each time.
$script:LANE_MARKER_CACHE = @{}

function Test-FileHasStrings {
    <#
    .SYNOPSIS
        Which of these ASCII needles appear anywhere in the file.
    .DESCRIPTION
        Streamed in chunks with an overlap of one needle length, so a marker
        that straddles a chunk boundary is still found, and a 96 MB test binary
        never lands in memory whole. Proving a needle ABSENT requires reading to
        the end, which is the cost of the check being trustworthy.
    .OUTPUTS
        A hashtable: needle -> [bool].
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Needles
    )
    $found = @{}
    foreach ($n in $Needles) { $found[$n] = $false }
    if (-not $Needles -or $Needles.Count -eq 0) { return $found }
    if (-not (Test-Path -LiteralPath $Path)) { return $found }

    $maxNeedle = ($Needles | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    # Opened FileShare.ReadWrite: a lane may be relinking the very file being
    # probed, and a sharing violation here would read as "no marker".
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $size = 4MB
        $buf = New-Object byte[] $size
        $carry = ''
        while (($read = $fs.Read($buf, 0, $size)) -gt 0) {
            $s = $carry + [Text.Encoding]::ASCII.GetString($buf, 0, $read)
            foreach ($n in $Needles) {
                if (-not $found[$n] -and $s.Contains($n)) { $found[$n] = $true }
            }
            $keep = [Math]::Min($maxNeedle, $s.Length)
            $carry = $s.Substring($s.Length - $keep)
        }
    }
    finally { $fs.Dispose() }
    return $found
}

function Get-BinaryLaneVerdict {
    <#
    .SYNOPSIS
        Is this exe the FULL test binary of that lane -- and if not, what is it?
    .OUTPUTS
        Ok, Reason, Path, CacheDir, Name, Lane, Missing (core markers absent),
        Foreign (other-lane markers present), Absent (own markers absent),
        Checked ($false when nothing is known about that exe name).
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('none', 'win32', 'agent')][string]$Lane
    )
    $name = Split-Path -Leaf $Path
    $res = [pscustomobject]@{
        Path     = $Path
        CacheDir = (Split-Path -Parent $Path)
        Name     = $name
        Lane     = $Lane
        Ok       = $false
        Checked  = $false
        # Set when the candidate is positively identified as a DIFFERENT lane's
        # build, as opposed to merely not verifiable -- the difference between
        # "this answer would be about the wrong program" and "I cannot tell".
        OtherLane = $false
        Reason   = ''
        Missing  = @()
        Foreign  = @()
        Absent   = @()
    }
    $spec = $null
    if ($script:LANE_MARKERS.ContainsKey($Lane)) { $spec = $script:LANE_MARKERS[$Lane][$name] }
    if (-not $spec) {
        # Nothing known about this name: say so rather than pretending to check.
        $res.Ok = $true
        $res.Reason = "no lane signature for $name -- not checked"
        return $res
    }

    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $item) {
        $res.Reason = 'the file is gone'
        return $res
    }
    $key = '{0}|{1}|{2}|{3}' -f $Path, $item.Length, $item.LastWriteTimeUtc.Ticks, $Lane
    if ($script:LANE_MARKER_CACHE.ContainsKey($key)) { return $script:LANE_MARKER_CACHE[$key] }

    $needles = @($spec.Core) + @($spec.Only) + @($spec.NotThis)
    $hit = Test-FileHasStrings -Path $Path -Needles $needles
    $res.Checked = $true
    $res.Missing = @($spec.Core | Where-Object { -not $hit[$_] })
    $res.Absent = @($spec.Only | Where-Object { -not $hit[$_] })
    $res.Foreign = @($spec.NotThis | Where-Object { $hit[$_] })

    if ($res.Foreign.Count -gt 0) {
        $res.OtherLane = $true
        $res.Reason = "another lane's binary -- it carries $($res.Foreign[0])"
    }
    elseif ($res.Absent.Count -gt 0 -and $res.Absent.Count -eq @($spec.Only).Count) {
        # Every one of this lane's exclusive tests is missing: that is the OTHER
        # lane's build wearing the same file name, not a filtered one.
        $res.OtherLane = $true
        $res.Reason = "another lane's binary -- none of this lane's own tests are in it (no $($res.Absent[0]))"
    }
    elseif ($res.Missing.Count -gt 0 -or $res.Absent.Count -gt 0) {
        $gone = @($res.Missing) + @($res.Absent)
        $res.Reason = ("a partial build -- {0} expected test name(s) missing, e.g. {1} (a -Dtest-filter build is not the lane)" -f `
                $gone.Count, $gone[0])
    }
    else {
        $res.Ok = $true
        $res.Reason = ("verified: {0} core test(s) present{1}{2}" -f `
                @($spec.Core).Count,
            $(if (@($spec.Only).Count) { ", {0} {1}-only test(s) present" -f @($spec.Only).Count, $Lane } else { '' }),
            $(if (@($spec.NotThis).Count) { ", {0} other-lane test(s) absent" -f @($spec.NotThis).Count } else { '' }))
    }
    $script:LANE_MARKER_CACHE[$key] = $res
    return $res
}

function Resolve-LaneTestBinary {
    <#
    .SYNOPSIS
        The lane's own test binary, CHECKED -- with the rejects and the reasons.
    .DESCRIPTION
        Candidates are still gathered newest-first (a lane that relinked is the
        one being asked about), but "newest" no longer decides: each candidate is
        read for the lane's test-name markers and the first one that IS this
        lane's full build wins. When none is, the answer is a loud failure
        naming what was found instead -- never the other lane's program.
    .PARAMETER MaxCandidates
        How deep to look per exe name. Reading a candidate costs about half a
        second; the cache holds every build of the day, and a lane that is not in
        the newest handful has not been built recently enough to be the subject.
    .PARAMETER ExtraExeNames
        Additional exe names to resolve alongside the lane's own. Every real lane
        builds ONE binary since T434, so the multi-binary paths downstream (a log
        per binary, per-exe attribution in the soak summary) would have no way to
        be exercised -- this is how a fixture declares its second name without
        the table claiming the build produces it.
    .OUTPUTS
        One object per exe name the lane builds: Name, Path, CacheDir, Ok,
        Reason, Verdict, Rejected (path+reason pairs), Candidates.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('none', 'win32', 'agent')][string]$Lane,
        [string]$Repo = 'D:\git\ghoztty',
        [int]$MaxCandidates = 8,
        [string[]]$ExtraExeNames = @()
    )
    $root = Join-Path $Repo '.zig-cache\o'
    $out = @()
    $names = @($script:LANE_TEST_EXES[$Lane])
    foreach ($n in @($ExtraExeNames)) { if ($n -and $names -notcontains $n) { $names += $n } }
    foreach ($name in $names) {
        $entry = [pscustomobject]@{
            Name       = $name
            Path       = $null
            CacheDir   = $null
            Ok         = $false
            Reason     = "nothing named $name is built under $root"
            Verdict    = $null
            Rejected   = @()
            Candidates = 0
        }
        $cands = @()
        if (Test-Path -LiteralPath $root) {
            $cands = @(Get-ChildItem -LiteralPath $root -Recurse -Filter $name -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First $MaxCandidates)
        }
        $entry.Candidates = $cands.Count
        foreach ($c in $cands) {
            $v = Get-BinaryLaneVerdict -Path $c.FullName -Lane $Lane
            if ($v.Ok) {
                $entry.Path = $c.FullName
                $entry.CacheDir = Split-Path -Parent $c.FullName
                $entry.Ok = $true
                $entry.Reason = $v.Reason
                $entry.Verdict = $v
                break
            }
            $entry.Rejected += , [pscustomobject]@{ Path = $c.FullName; Reason = $v.Reason }
        }
        if (-not $entry.Ok -and $entry.Rejected.Count -gt 0) {
            $entry.Reason = ("no $name under $root is the $Lane lane's full build ({0} candidate(s) read; newest is {1})" -f `
                    $entry.Rejected.Count, $entry.Rejected[0].Reason)
        }
        $out += , $entry
    }
    return @($out)
}

function Write-LaneResolution {
    <#
    .SYNOPSIS
        Say which binary was picked, out of where, and what it passed.
    .DESCRIPTION
        The cache directory is printed on purpose: it is the only thing that
        tells two same-named lane binaries apart, and T855 exists because it was
        never shown.
    #>
    param(
        [Parameter(Mandatory)]$Resolution,
        [string]$Prefix = 'lane',
        [scriptblock]$Writer = { param($s) Write-Host $s }
    )
    foreach ($e in @($Resolution)) {
        if ($e.Ok) {
            & $Writer ("{0} {1} -> {2}" -f $Prefix, $e.Name, $e.Path)
            & $Writer ("{0}   {1}" -f $Prefix, $e.Reason)
        }
        else {
            & $Writer ("{0} {1} -> REFUSED: {2}" -f $Prefix, $e.Name, $e.Reason)
        }
        foreach ($r in @($e.Rejected)) {
            & $Writer ("{0}   skipped {1} -- {2}" -f $Prefix, $r.Path, $r.Reason)
        }
    }
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
        The lane's test exe(s), verified to BE that lane's full build.
    .DESCRIPTION
        `zig build` leaves them under .zig-cache\o\<hash>\. Running one directly
        is far cheaper than re-running the lane (no build, no build runner) and
        is how T443's repro loop already works.

        A path comes back only when Resolve-LaneTestBinary has confirmed the
        lane (T855). An unconfirmed candidate is dropped rather than returned,
        so a caller that only checks `.Count` still cannot end up running the
        other lane's program; callers that want to SAY why should ask
        Resolve-LaneTestBinary directly and print with Write-LaneResolution.
    .PARAMETER AllowUnverified
        Fall back to newest-by-write-time when nothing verifies. For a caller
        that has no lane claim to falsify -- and it still says so.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('none', 'win32', 'agent')][string]$Lane,
        [string]$Repo = 'D:\git\ghoztty',
        [switch]$AllowUnverified
    )
    $out = @()
    foreach ($e in @(Resolve-LaneTestBinary -Lane $Lane -Repo $Repo)) {
        if ($e.Ok) { $out += $e.Path }
        elseif ($AllowUnverified) {
            $hit = Get-NewestBuiltBinary -Name $e.Name -Repo $Repo
            if ($hit) { $out += $hit }
        }
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
    'bpe', # break instruction     0x80000003 -- a ZIG PANIC (T478)
    'c0000374', # heap corruption
    'c0000409'      # stack buffer overrun / __fastfail
)

# `bpe` deserves its own note, because leaving it out is what made this catcher
# lie for a month (T478). A Zig panic ends in `int3`, and cdb OWNS int3: with no
# filter registered for it the debugger consumes the break as its own, the
# script's `g` has already returned, and the next command in the script (`q`)
# quits -- so the transcript holds no crash block and the run reads as clean.
# The T477 test binary died on 10 runs out of 10 and `crash-catch` reported
# "ran clean in 17s" for every one of them.
#
# The cost of arming it is that a program which raises a breakpoint on purpose
# and handles it would now be stopped. Nothing this repo runs does that, and a
# first-chance int3 in a process nobody is debugging is fatal by construction
# (Zig panic, `@breakpoint()`, a CRT assert, `__debugbreak`) -- being told about
# it is the whole point. Planted breakpoints are unaffected: cdb matches an int3
# against its own `bp`/`ba` list first, so DataBreak.ps1's `bp0` command files
# still run (measured, and pinned by test\win32\crash-stacks.ps1).

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
    # Not `q` on its own (T478). `g` returns for two very different reasons --
    # the program exited, or something broke that no filter above claimed -- and
    # the old script could not tell them apart, so both were reported as a clean
    # run. `.lastevent` names which, and on an exit it carries the debuggee's
    # REAL exit code ("Exit process 0:1a3c, code 1a", in hex). cdb's own exit
    # code cannot stand in for it: `q` terminates a still-live debuggee and
    # returns 0, which is exactly the number that made a panicking binary look
    # healthy.
    $cmds += '.echo GHOZTTY-EXIT-BEGIN'
    $cmds += '.lastevent'
    $cmds += '.echo GHOZTTY-EXIT-END'
    $cmds += 'q'
    return ($cmds -join '; ')
}

function Format-DebuggeeExitCode {
    <#
    .SYNOPSIS
        A debuggee exit code as `0xXXXXXXXX`, plus its NTSTATUS name when it is
        one.
    .DESCRIPTION
        The code here is the FULL 32-bit value cdb reported, not the low byte
        `std.process.Child` truncates it to, so the decode can be exact: a
        status is named only when the whole value matches. That is what keeps an
        ordinary `exit(5)` from being announced as an access violation -- the
        risk CrashDiag's low-byte table carries by design, because through `zig
        build` the top bits are already gone.
    #>
    param([Parameter(Mandatory)][AllowNull()][object]$Code)

    if ($null -eq $Code) { return 'unknown' }
    # PowerShell 5.1 parses `0x80000003` -- in this call and in CrashDiag's
    # table -- as a NEGATIVE Int32, and `0xFFFFFFFF` as Int32 -1, so masking
    # with the literal is a no-op that leaves the sign in place. 4294967295 as a
    # written-out Int64 is the mask that actually widens both sides.
    $mask = 4294967295L
    $v = ([int64]$Code) -band $mask
    $hex = '0x{0:X8}' -f $v
    $decoded = @(Get-NtStatusCandidate -Code ([int]($v -band 0xFF)) |
            Where-Object { ((([int64]$_.Status) -band $mask) -eq $v) })
    if ($decoded.Count -gt 0) { return "$hex -> $($decoded[0].Name)" }
    return $hex
}

function Read-CrashCatchLog {
    <#
    .SYNOPSIS
        Turn a cdb transcript into the facts a caller needs.
    #>
    param([Parameter(Mandatory)][string]$LogPath)

    $res = [pscustomobject]@{
        Crashed          = $false
        ExceptionCode    = ''
        ExceptionName    = ''
        FaultSite        = ''
        ThreadCount      = 0
        SourceLines      = 0
        FaultingStack    = @()
        AllStacks        = @()
        # T478. "Ran clean" is a POSITIVE observation from here on: it requires
        # having seen the debuggee exit with code 0. Anything else -- a nonzero
        # exit, a break nothing claimed, a transcript that stops mid-run because
        # cdb was killed on timeout -- is Uncaught, and is reported as such.
        ExitObserved     = $false
        DebuggeeExitCode = $null
        LastEvent        = ''
        Uncaught         = $false
        UncaughtDetail   = ''
    }
    if (-not (Test-Path -LiteralPath $LogPath)) {
        $res.Uncaught = $true
        $res.UncaughtDetail = 'no transcript was written'
        return $res
    }
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
        # End-anchored only (T886): the markers are cdb `.echo` output, but a
        # debuggee whose LAST stdout write has no trailing newline glues its
        # text onto the front of the echo line ("...linkid=2286319GHOZTTY-
        # EXIT-BEGIN"), and a start-anchored match then reports a clean exit-0
        # run as UNCAUGHT. Anything may precede the marker; nothing but
        # whitespace may follow it — which is what keeps the "Reading initial
        # command '...; q'" line (markers mid-string, text after) a non-match.
        return ($Line -match ([regex]::Escape($Marker) + '\s*$'))
    }
    $begin = -1; $faulting = -1; $all = -1; $end = -1
    $exitBegin = -1; $exitEnd = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($begin -lt 0 -and (Test-Marker $lines[$i] 'GHOZTTY-CRASH-BEGIN')) { $begin = $i }
        elseif ($faulting -lt 0 -and (Test-Marker $lines[$i] 'GHOZTTY-FAULTING-THREAD')) { $faulting = $i }
        elseif ($all -lt 0 -and (Test-Marker $lines[$i] 'GHOZTTY-ALL-THREADS')) { $all = $i }
        elseif ($end -lt 0 -and (Test-Marker $lines[$i] 'GHOZTTY-CRASH-END')) { $end = $i }
        elseif ($exitBegin -lt 0 -and (Test-Marker $lines[$i] 'GHOZTTY-EXIT-BEGIN')) { $exitBegin = $i }
        elseif ($exitEnd -lt 0 -and (Test-Marker $lines[$i] 'GHOZTTY-EXIT-END')) { $exitEnd = $i }
    }

    # How the run ENDED, read before the crash block so it is available on the
    # path that used to return "no crash" unconditionally (T478).
    if ($exitBegin -ge 0) {
        $stopAt = if ($exitEnd -gt $exitBegin) { $exitEnd - 1 } else { $lines.Count - 1 }
        if ($stopAt -ge ($exitBegin + 1)) {
            $exitText = ($lines[($exitBegin + 1)..$stopAt]) -join "`n"
            if ($exitText -match 'Last event:\s*(.+)') { $res.LastEvent = $Matches[1].Trim() }
            # "Exit process 0:1a3c, code 1a" -- both numbers are HEX, which is
            # cdb's default radix and the difference between exit 26 and exit 1a.
            if ($exitText -match 'Exit process\s+\S+,\s*code\s+([0-9a-fA-F]+)') {
                $res.ExitObserved = $true
                $res.DebuggeeExitCode = [Convert]::ToInt64($Matches[1], 16)
            }
        }
    }

    if ($begin -lt 0) {
        # No exception was captured. That is only good news if the program was
        # SEEN to exit 0; every other shape is a death this catcher could not
        # explain, and saying so is the whole point of the task.
        if ($res.ExitObserved -and $res.DebuggeeExitCode -eq 0) { return $res }
        $res.Uncaught = $true
        $res.UncaughtDetail = if ($res.ExitObserved) {
            "exit " + (Format-DebuggeeExitCode -Code $res.DebuggeeExitCode)
        }
        elseif ($res.LastEvent) { "the debuggee never exited -- last event: $($res.LastEvent)" }
        else { 'the debugger reported neither an exception nor a process exit' }
        return $res
    }
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
            Crashed          = $parsed.Crashed
            Attempt          = $a
            Attempts         = $Attempts
            ExceptionCode    = $parsed.ExceptionCode
            ExceptionName    = $parsed.ExceptionName
            FaultSite        = $parsed.FaultSite
            ThreadCount      = $parsed.ThreadCount
            SourceLines      = $parsed.SourceLines
            LastTest         = Get-LastProgressLine -Path $errLog
            DumpPath         = $(if (Test-Path -LiteralPath $dump) { $dump } else { '' })
            LogPath          = $log
            ErrLogPath       = $errLog
            FaultingStack    = $parsed.FaultingStack
            AllStacks        = $parsed.AllStacks
            # cdb's exit code, which is NOT the debuggee's when the debuggee was
            # still alive at a break: `q` kills it and cdb returns 0 (T478).
            ExitCode         = $p.ExitCode
            ExitObserved     = $parsed.ExitObserved
            DebuggeeExitCode = $parsed.DebuggeeExitCode
            LastEvent        = $parsed.LastEvent
            Uncaught         = $parsed.Uncaught
            UncaughtDetail   = $parsed.UncaughtDetail
            Seconds          = $seconds
        }
        Remove-Item -LiteralPath $scriptFile -Force -ErrorAction SilentlyContinue
        if ($parsed.Crashed) {
            Remove-OldCrashCapture -OutDir $OutDir -Keep $Keep
            break
        }
        if ($parsed.Uncaught) {
            # The program died and the debugger could not say why. That is
            # evidence, not noise: the transcript stays, and re-running would
            # only paper over it, so the attempt loop stops here exactly as a
            # caught crash stops it.
            Remove-OldCrashCapture -OutDir $OutDir -Keep $Keep
            & $Writer ("crash-catch: attempt $a UNCAUGHT in ${seconds}s -- " + $parsed.UncaughtDetail)
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
        if ($Result.Uncaught) {
            # T478: the sentence that used to be printed here regardless --
            # "the program ran to completion" -- was the bug. It is now only
            # ever said about a run that was WATCHED exiting 0.
            & $Writer ("  UNCAUGHT ({0}) after {1} attempt(s) -- no exception was captured, so nothing here explains it" -f `
                    $Result.UncaughtDetail, $Result.Attempt)
            if ($Result.LastTest) { & $Writer ("  running at the time: " + $Result.LastTest) }
            if ($Result.LogPath -and (Test-Path -LiteralPath $Result.LogPath)) {
                & $Writer ("  transcript: " + $Result.LogPath)
            }
            return $false
        }
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
