<#
.SYNOPSIS
    Size/free-space accounting for the zig build caches, and the whole-cache
    clear that keeps the repo drive from filling up (T1054).

.DESCRIPTION
    Zig never evicts: every distinct build hash keeps its full output under
    `.zig-cache\o\<hash>\`, and a debug `ghoztty.exe` is 48 MB with a 100 MB
    `.pdb` beside it. Four floor lanes several times a day plus acceptance and
    staging builds is ~40 GB a day, and on 2026-08-21 that reached exactly 0
    bytes free on D: -- 31,359 entries, 1,235 GB. What that looks like from
    inside a turn is worse than an out-of-disk message: every lane dies in five
    seconds with a bare `error: Unexpected` from zig, which reads as red code.

    Two rules come out of that morning, and they are why this file is shaped
    the way it is.

    **Clear WHOLE, never by age.** The first remedy tried was an age prune of
    `.zig-cache\o` (28,369 entries, 1,082 GB) and it broke the very next lane:
    Zig's manifests under `.zig-cache\h\` still recorded those outputs as hits,
    so the build runner failed with `failed to spawn build runner
    .zig-cache\o\<hash>\build.exe: FileNotFound`. The user's call on seeing it
    was "clear it completely and start fresh if this is just build artifacts",
    and that is the policy: a cache that is entirely regenerable does not need
    a subtle eviction policy, and the subtle policy is what produced the
    dangling manifests. `Clear-BuildCache` therefore removes the cache
    directory whole -- `o\`, `h\`, `c\`, `tmp\`, all of it.

    **Ask the cheap question first.** The trigger is FREE SPACE, which is an
    O(1) call to the drive; a claim on a healthy box must not walk 30,000
    directories to learn that nothing is wrong. `Get-BuildCacheState` therefore
    never sums file sizes. Its second, still-cheap signal is the ENTRY COUNT of
    `.zig-cache\o` -- one non-recursive directory enumeration, no stat per file
    -- used as a size proxy at the measured ~40 MB per entry. That proxy is
    approximate on purpose: it only has to be right about "this cache is now
    enormous", and it is bounded by the free-space trigger on any drive where
    being wrong would matter.

.NOTES
    Functions only; no side effects at load. Dot-source from a CLI
    (scripts\build-cache.ps1) or a harness.
#>

# Measured on 2026-08-21: 31,359 entries in `.zig-cache\o` totalled 1,235 GB.
# Used to turn the cheap entry count into a size estimate, and documented as an
# average rather than a rule -- entries range from a few KB of generated zig to
# a 48 MB exe plus a 100 MB pdb.
$script:BUILDCACHE_MB_PER_ENTRY = 40

function Get-DriveFreeGB {
    <#
        Free gigabytes on the volume a path lives on, or $null when the path
        names no reachable volume. O(1): a DriveInfo query, never a walk.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $root = [System.IO.Path]::GetPathRoot($full)
        if (-not $root) { return $null }
        $di = New-Object System.IO.DriveInfo($root)
        if (-not $di.IsReady) { return $null }
        return [math]::Round($di.AvailableFreeSpace / 1GB, 1)
    } catch { return $null }
}

function Resolve-ZigGlobalCacheDir {
    <#
        Where zig's GLOBAL cache lives for a build out of $RepoPath. One copy
        of the rule, because two would be free to disagree: floor-lane.ps1
        delegates here rather than keeping its own.

        CLAUDE.md/T243: the global cache MUST sit on the repo's drive, or zig
        0.15.2's build runner panics in convertPathArg before any test runs.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [string]$Explicit
    )
    if ($Explicit) { return $Explicit }
    if ($env:ZIG_GLOBAL_CACHE_DIR) { return $env:ZIG_GLOBAL_CACHE_DIR }
    $drive = (Split-Path -Qualifier $RepoPath)
    return (Join-Path $drive '\zig-global-cache')
}

function Resolve-BuildTempDir {
    <#
        Where a BUILD should scratch. Same shape and the same reason as
        `Resolve-ZigGlobalCacheDir` above: one copy of the rule, on the repo's
        own drive.

        T1431. Zig's C/C++ compile steps (glslang, oniguruma, translate-c,
        helpgen) write their intermediates into %TEMP%, which on this box lives
        on C: while everything else the build touches lives on D:. On
        2026-09-07 C: had 0.1 GB free and every `zig build` died with a bare
        `error: Unexpected` naming no file, no line and no disk -- the T1054
        failure again, but on a drive nothing was measuring, so the cache
        sweeper reported 1 TB free while the build could not write a byte.
        Pointing TMP/TEMP at the repo drive made the same build succeed with no
        other change.

        `GHOZTTY_BUILD_TEMP` overrides, which is what lets the acceptance
        harness drive a fixture directory instead of the real one.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [string]$Explicit
    )
    if ($Explicit) { return $Explicit }
    if ($env:GHOZTTY_BUILD_TEMP) { return $env:GHOZTTY_BUILD_TEMP }
    $drive = (Split-Path -Qualifier $RepoPath)
    return (Join-Path $drive '\zig-build-temp')
}

function Push-BuildTempEnv {
    <#
        Create the build scratch directory, point this process's TMP/TEMP at it,
        and return the values that were there before so `Pop-BuildTempEnv` can
        put them back.

        Deliberately environment-based rather than a flag on the zig command
        line: the compile steps that fill %TEMP% are several layers below the
        caller (zig -> clang -> a linker temp), and an environment a child
        inherits is the only place all of them can be reached from.

        Scoped rather than permanent because these callers keep using %TEMP% for
        their OWN files - a build log, a version probe - and a helper that moved
        those too would relocate paths its caller had already printed. A caller
        that must not move its own %TEMP% at all (`floor-lane.ps1`, whose lane
        logs an acceptance harness finds by path) asks `Resolve-BuildTempDir`
        instead and sets the two variables on the build shell it spawns.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [string]$Explicit
    )
    $dir = Resolve-BuildTempDir -RepoPath $RepoPath -Explicit $Explicit
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $prev = @{ TMP = $env:TMP; TEMP = $env:TEMP; Dir = $dir }
    $env:TMP = $dir
    $env:TEMP = $dir
    return $prev
}

function Pop-BuildTempEnv {
    <#
        Restore what `Push-BuildTempEnv` replaced. Tolerates $null so a caller
        can put this in a `finally` without asking whether the push happened.
    #>
    param($Previous)
    if (-not $Previous) { return }
    $env:TMP = $Previous.TMP
    $env:TEMP = $Previous.TEMP
}

function Get-SystemTempState {
    <#
        How much room the drive %TEMP% is on has left, and whether a build
        would be redirected off it.

        Reported rather than acted on: %TEMP% belongs to the user's session, so
        the remedy for a full C: is the redirect above plus a human deleting
        something -- never this script clearing a directory Windows and every
        other program on the box share. What it exists to stop is the SILENT
        version, where a claim prints 1 TB free about D: and the very next lane
        dies on C: with a message about neither.

        Returns Path, Drive, FreeGB, BuildTemp, Redirected, Low, Summary.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        # At or below this, the summary says so out loud. 10 GB is the same
        # floor `floor-lane.ps1` refuses a lane below, so the two numbers cannot
        # tell different stories about the same box.
        [double]$LowFreeGB = 10,
        [string]$TempPath,
        [string]$BuildTemp
    )
    if (-not $TempPath) { $TempPath = $env:TEMP }
    $buildTempDir = Resolve-BuildTempDir -RepoPath $RepoPath -Explicit $BuildTemp

    $drive = ''
    $free = $null
    if ($TempPath) {
        try { $drive = Split-Path -Qualifier ([System.IO.Path]::GetFullPath($TempPath)) } catch { $drive = '' }
        $free = Get-DriveFreeGB -Path $TempPath
    }
    $buildDrive = ''
    try { $buildDrive = Split-Path -Qualifier ([System.IO.Path]::GetFullPath($buildTempDir)) } catch { $buildDrive = '' }

    $redirected = ($drive -ne '') -and ($buildDrive -ne '') -and ($drive -ne $buildDrive)
    $low = ($null -ne $free) -and ($free -le $LowFreeGB)

    $freeText = if ($null -eq $free) { 'unknown' } else { "$free GB" }
    $summary =
        if ($low -and $redirected) {
            "system temp low: $drive has $freeText free - builds scratch in $buildTempDir instead, so this does not stop a build"
        } elseif ($low) {
            "system temp low: $drive has $freeText free and builds scratch there - a zig build will fail with a bare 'error: Unexpected'"
        } else {
            "system temp ok: $drive $freeText free, builds scratch in $buildTempDir"
        }

    return @{
        Path       = $TempPath
        Drive      = $drive
        FreeGB     = $free
        BuildTemp  = $buildTempDir
        Redirected = $redirected
        Low        = $low
        Summary    = $summary
    }
}

function Get-BuildCacheEntryCount {
    <#
        Number of output entries in a zig cache, counted with ONE non-recursive
        directory enumeration of `o\`. Never stats a file, never recurses.
        Returns 0 for a cache that does not exist or has no `o\` yet.
    #>
    param([Parameter(Mandatory = $true)][string]$CacheDir)
    $o = Join-Path $CacheDir 'o'
    if (-not (Test-Path -LiteralPath $o)) { return 0 }
    try {
        $n = 0
        foreach ($d in [System.IO.Directory]::EnumerateDirectories($o)) { $n++ }
        return $n
    } catch { return 0 }
}

function Get-BuildCacheState {
    <#
        The cheap health question, asked of one or more cache directories:
        how much room is left on their drives, how many entries do they hold,
        and does that put any of them over a limit?

        Returns a hashtable with:
          Caches     - one record per cache dir (Path, Exists, Entries, EstGB, FreeGB)
          FreeGB     - the SMALLEST free space across the drives involved
          Entries    - the LARGEST entry count across the caches
          Over       - $true when a limit is exceeded
          Reason     - 'free-space' | 'entries' | '' , which limit tripped
          Warn       - $true when free space is inside the warning band but not over
          Summary    - one line, safe to print from a claim
    #>
    param(
        [Parameter(Mandatory = $true)][string[]]$CacheDirs,
        [double]$MinFreeGB = 100,
        [int]$MaxEntries = 12000,
        # Free space at or below this prints a heads-up without clearing.
        # Defaults to twice the trigger, so the warning arrives a full cycle
        # of ~40 GB/day before the clear does.
        [double]$WarnFreeGB = 0
    )
    if ($WarnFreeGB -le 0) { $WarnFreeGB = $MinFreeGB * 2 }

    $records = @()
    $minFree = $null
    # NOT $maxEntries: PowerShell variable names are case-insensitive, so that
    # spelling silently overwrites the $MaxEntries parameter and every cache
    # reads as exactly at its own ceiling.
    $peakEntries = 0
    foreach ($dir in @($CacheDirs | Where-Object { $_ })) {
        $free = Get-DriveFreeGB -Path $dir
        $entries = Get-BuildCacheEntryCount -CacheDir $dir
        $records += [pscustomobject]@{
            Path    = $dir
            Exists  = (Test-Path -LiteralPath $dir)
            Entries = $entries
            EstGB   = [math]::Round(($entries * $script:BUILDCACHE_MB_PER_ENTRY) / 1024.0, 1)
            FreeGB  = $free
        }
        if ($null -ne $free -and ($null -eq $minFree -or $free -lt $minFree)) { $minFree = $free }
        if ($entries -gt $peakEntries) { $peakEntries = $entries }
    }

    $over = $false
    $reason = ''
    if ($null -ne $minFree -and $minFree -le $MinFreeGB) { $over = $true; $reason = 'free-space' }
    elseif ($peakEntries -ge $MaxEntries) { $over = $true; $reason = 'entries' }

    $warn = (-not $over) -and ($null -ne $minFree) -and ($minFree -le $WarnFreeGB)

    $freeText = if ($null -eq $minFree) { 'unknown' } else { "$minFree GB" }
    $summary =
        if ($over -and $reason -eq 'free-space') {
            "build cache over limit: $freeText free (floor $MinFreeGB GB), $peakEntries entries"
        } elseif ($over) {
            "build cache over limit: $peakEntries entries (ceiling $MaxEntries), $freeText free"
        } elseif ($warn) {
            "build cache getting large: $freeText free, $peakEntries entries - clears below $MinFreeGB GB"
        } else {
            "build cache ok: $freeText free, $peakEntries entries"
        }

    return @{
        Caches  = $records
        FreeGB  = $minFree
        Entries = $peakEntries
        Over    = $over
        Reason  = $reason
        Warn    = $warn
        Summary = $summary
    }
}

function Clear-BuildCache {
    <#
        Remove a zig cache directory WHOLE and report what it freed. Whole,
        not by age: pruning `o\` alone leaves Zig's manifests in `h\` pointing
        at outputs that no longer exist, and the next build fails with
        `failed to spawn build runner ... FileNotFound` -- a failure that reads
        like a broken repo and costs a turn to diagnose.

        Returns a record: Path, Removed ($true when the directory is gone),
        FreedGB (measured from the drive, before minus after), Error.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$CacheDir,
        [switch]$WhatIf
    )
    $before = Get-DriveFreeGB -Path $CacheDir
    if (-not (Test-Path -LiteralPath $CacheDir)) {
        return [pscustomobject]@{ Path = $CacheDir; Removed = $false; FreedGB = 0; Error = 'absent' }
    }
    if ($WhatIf) {
        return [pscustomobject]@{ Path = $CacheDir; Removed = $false; FreedGB = 0; Error = 'what-if' }
    }
    $err = ''
    try {
        Remove-Item -LiteralPath $CacheDir -Recurse -Force -ErrorAction Stop
    } catch {
        $err = $_.Exception.Message
    }
    # A locked file (a lane still running, a virus scanner holding a handle)
    # leaves part of the tree behind. That is reported, not retried: a partial
    # clear is exactly the dangling-manifest state above, so the caller must be
    # able to see it happened.
    $gone = -not (Test-Path -LiteralPath $CacheDir)
    $after = Get-DriveFreeGB -Path $CacheDir
    $freed = if ($null -ne $before -and $null -ne $after) { [math]::Round($after - $before, 1) } else { 0 }
    if ($freed -lt 0) { $freed = 0 }
    return [pscustomobject]@{ Path = $CacheDir; Removed = $gone; FreedGB = $freed; Error = $err }
}

function Get-StaleScratchDir {
    <#
        Leftovers from finished tasks that are NOT caches: `zig-out-*` staging
        copies, `.dumps`, and the per-task scratch directories under the cache
        (`t508-*`). ~3 GB when this was written.

        Reported only. Nothing here deletes them: they sit outside a cache, so
        "entirely regenerable" is an assumption rather than a fact, and the
        standing rule is to ask before deleting anything outside a cache.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        # Every cache being managed, not just the global one: the per-task
        # scratch directories this project leaves behind (`t508-*`) sit under
        # the REPO cache, so a sweeper that only looked at the global cache
        # would report none of them.
        [string[]]$CacheDirs = @()
    )
    $found = @()
    foreach ($d in @(Get-ChildItem -LiteralPath $Repo -Directory -Force -ErrorAction SilentlyContinue)) {
        $keep = ($d.Name -eq 'zig-out') -or ($d.Name -eq '.zig-cache')
        if ($keep) { continue }
        if ($d.Name -like 'zig-out-*' -or $d.Name -eq '.dumps') {
            $found += [pscustomobject]@{ Path = $d.FullName; Name = $d.Name; Kind = 'repo' }
        }
    }
    foreach ($cache in @($CacheDirs | Where-Object { $_ })) {
        if (-not (Test-Path -LiteralPath $cache)) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $cache -Directory -Force -ErrorAction SilentlyContinue)) {
            # Zig's own subdirectories are o/h/c/tmp/z; anything else under a
            # cache directory was put there by one of our scripts.
            if ($d.Name -in @('o', 'h', 'c', 'tmp', 'z')) { continue }
            $found += [pscustomobject]@{ Path = $d.FullName; Name = $d.Name; Kind = 'cache-scratch' }
        }
    }
    return $found
}
