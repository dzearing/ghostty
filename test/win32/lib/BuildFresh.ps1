# BuildFresh.ps1 - T1028. Refuse, BEFORE anything is launched or typed, to
# GRADE a zig-out exe that is older than the sources it is being asked to
# measure.
#
# Dot-sourced by lib\BuildMode.ps1, and called from
# `Assert-GhozttyIsolatedBuild`, so every acceptance script that already gates
# on build MODE now gates on build FRESHNESS too, with no per-script edit.
#
# WHY THIS EXISTS
#
# Every `test\win32\*.ps1` that launches the app defaults `-Exe` to
# `<repo>\zig-out\bin\ghoztty.exe`. Eleven of them run `zig build` first; the
# rest - including the P1-P3 floor - drive whatever copy happens to be on disk.
# Nothing checked that the copy came from the code under test.
#
# The false RED is merely annoying and self-correcting: on 2026-08-20 T316's
# first `relay-account.ps1` run reported 3 FAILURE(S) against an exe built four
# hours earlier, the code was right, and a rebuild made it green.
#
# The false GREEN is the defect. A change that a STALE exe still passes exits 0,
# and since T783 exiting 0 STAMPS the guard - so `scripts\guard-due.ps1`
# afterwards answers "this harness has been run against the code as it stands"
# about an exe that was never built from it. That is the single question the
# stamp exists to answer, and it can be made to lie without anybody acting in
# bad faith.
#
# WHY MTIME, AND NOT THE BAKED COMMIT
#
# `upgrade-staleness` compares a DELIVERED exe's baked commit against
# `git rev-parse HEAD`, which is exactly right for a delivery: what ships must
# be a commit. It is the wrong question here, in both directions:
#
#   * blind to uncommitted work - the state a turn is in for the whole of
#     steps 2-4, which is precisely when acceptance scripts run;
#   * red on a commit that changed nothing - the loop builds, tests, and THEN
#     commits, so at step 6 the exe's baked commit is the parent of HEAD while
#     its bytes are exactly what HEAD's sources produce. A hard refusal there
#     would fire on every turn, and a gate that cries wolf daily gets an
#     `-Allow` bolted onto every caller within a week.
#
# Newest relevant source mtime vs the exe's mtime answers the question actually
# being asked - "was this exe built from the tree as it now stands?" - and it
# answers it for uncommitted edits, for a `git pull` that brings in another
# seat's work (checkout stamps mtimes to now), and for a branch switch.
#
# WHAT COUNTS AS A SOURCE
#
# `build.zig`, `build.zig.zon`, and everything under `src\` EXCEPT `*.md` (a
# docs-only edit builds the same bytes) and `src\apprt\gtk\` (Linux's frontend,
# which this exe cannot contain). 1258 files, ~17ms, cached per process.
#
# THE ONE FALSE POSITIVE, AND ITS EXIT
#
# An edit to a `src\` file that is NOT in this exe's module graph - a Mac-only
# `src\apprt\embedded.zig` change arriving through a main intake, say - raises
# the high-water mark, and the remedial `zig build` then relinks nothing, so the
# exe's mtime does not move and the refusal would not clear. That would be a
# wedge, so the refusal names a second remedy that always terminates:
# `GHOZTTY_TEST_REBUILD_STALE=1` builds and, on success, writes a WITNESS beside
# the exe recording the high-water mark that build covered. A successful build
# IS the proof - relink or no relink - and the witness is what carries that
# proof to the next process. It is tied to the exe's mtime, so the moment the
# exe is rebuilt for real the witness stops applying.
#
# WHAT CATCHES WHAT (with BuildMode.ps1's table)
#
#   Assert-GhozttyIsolatedBuild - these bytes derive the USER'S endpoints.
#   Assert-GhozttyFreshBuild    - these bytes are not the code under test.
#
# Both speak before the first `+new-window`, and both are about the exe rather
# than about anything running, so both work on a cold box.

Set-StrictMode -Off

if (-not (Get-Variable -Name GhozttyFreshCache -Scope Script -ErrorAction SilentlyContinue)) {
    Set-Variable -Name GhozttyFreshCache -Scope Script -Value @{}
}

# Directories under src\ whose contents cannot be in a win32 ghoztty.exe.
$script:GhozttyFreshExcludedDirs = @('\src\apprt\gtk\')

# T1431: `Invoke-GhozttyDebugBuild` scratches on the repo's drive rather than in
# %TEMP%. The rule lives in one place (scripts\lib\BuildCache.ps1) beside the
# global-cache rule it mirrors, so this file asks for it instead of keeping a
# second copy that would be free to disagree.
. (Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) 'scripts\lib\BuildCache.ps1')

function Get-GhozttyRepoRootForFresh {
    <#
    .SYNOPSIS
    The repo root, derived from this file's location (test\win32\lib\).
    #>
    param([string]$Repo)
    if ($Repo) { return $Repo.TrimEnd('\') }
    return (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent).TrimEnd('\')
}

function Get-GhozttySourceHighWater {
    <#
    .SYNOPSIS
    The newest mtime among the files that feed a win32 ghoztty.exe.

    .DESCRIPTION
    Returns a PSCustomObject with Time (UTC), Path (the file holding it) and
    Count, or $null when the tree cannot be read. Enumerated with
    [System.IO.Directory]::EnumerateFiles rather than Get-ChildItem: 1258 files
    in ~17ms, which is cheap enough to sit in front of every acceptance script.
    Cached per repo per process - the tree does not change under a running
    script, and three libraries may ask.
    #>
    param([string]$Repo)

    $root = Get-GhozttyRepoRootForFresh -Repo $Repo
    $key = "high:$root"
    if ($script:GhozttyFreshCache.ContainsKey($key)) { return $script:GhozttyFreshCache[$key] }

    $result = $null
    $srcDir = Join-Path $root 'src'
    if (Test-Path -LiteralPath $srcDir) {
        $newestTime = [datetime]::MinValue
        $newestPath = $null
        $count = 0
        foreach ($f in [System.IO.Directory]::EnumerateFiles($srcDir, '*', 'AllDirectories')) {
            if ($f.EndsWith('.md', [StringComparison]::OrdinalIgnoreCase)) { continue }
            $skip = $false
            foreach ($ex in $script:GhozttyFreshExcludedDirs) {
                if ($f.IndexOf($ex, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $skip = $true; break }
            }
            if ($skip) { continue }
            $count++
            $t = [System.IO.File]::GetLastWriteTimeUtc($f)
            if ($t -gt $newestTime) { $newestTime = $t; $newestPath = $f }
        }
        foreach ($name in @('build.zig', 'build.zig.zon')) {
            $p = Join-Path $root $name
            if (Test-Path -LiteralPath $p) {
                $count++
                $t = [System.IO.File]::GetLastWriteTimeUtc($p)
                if ($t -gt $newestTime) { $newestTime = $t; $newestPath = $p }
            }
        }
        if ($newestPath) {
            $result = [pscustomobject]@{ Time = $newestTime; Path = $newestPath; Count = $count }
        }
    }

    $script:GhozttyFreshCache[$key] = $result
    return $result
}

function Get-GhozttyFreshWitnessPath {
    <#
    .SYNOPSIS
    Where the "a build covered this high-water mark" note lives for $Exe.
    #>
    param([Parameter(Mandatory = $true)][string]$Exe)
    return (Join-Path (Split-Path $Exe -Parent) '.build-fresh-witness.json')
}

function Test-GhozttyExeIsRepoBuild {
    <#
    .SYNOPSIS
    Is $Exe the repo's own zig-out build - the only exe this gate speaks about?

    .DESCRIPTION
    An installed release, a portable copy, `zig-out-release`, and the `.cmd`
    stubs an acceptance script writes into $TEMP are all out of scope: none of
    them is claimed to be built from this tree, so "older than src\" says
    nothing about them. Scoping on the path is what keeps this gate from
    inventing a rule for exes it knows nothing about.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string]$Repo
    )
    if (-not $Exe) { return $false }
    $root = Get-GhozttyRepoRootForFresh -Repo $Repo
    $full = $Exe
    try { $full = [System.IO.Path]::GetFullPath($Exe) } catch { $full = $Exe }
    $zigOut = (Join-Path $root 'zig-out') + '\'
    return $full.StartsWith($zigOut, [StringComparison]::OrdinalIgnoreCase)
}

function Get-GhozttyExeBuildTime {
    <#
    .SYNOPSIS
    When $Exe's bytes were last proved to cover the tree, as a UTC time.

    .DESCRIPTION
    The exe's own mtime, unless a witness written by the -Rebuild path applies:
    a build that relinked nothing still proves the exe covers the sources, and
    the witness is how that proof survives the process that made it. The witness
    only applies while the exe's mtime is the one it was written against, so a
    real rebuild retires it automatically.
    #>
    param([Parameter(Mandatory = $true)][string]$Exe)

    if (-not (Test-Path -LiteralPath $Exe)) { return $null }
    $exeTime = [System.IO.File]::GetLastWriteTimeUtc($Exe)

    $witnessPath = Get-GhozttyFreshWitnessPath -Exe $Exe
    if (Test-Path -LiteralPath $witnessPath) {
        try {
            $w = Get-Content -LiteralPath $witnessPath -Raw | ConvertFrom-Json
            $wExe = [datetime]::Parse($w.exeWriteTimeUtc).ToUniversalTime()
            $wBuilt = [datetime]::Parse($w.builtAtUtc).ToUniversalTime()
            # Sub-second write times survive a round trip through JSON only if
            # both sides use the same format; compare on whole seconds.
            if ([math]::Abs(($wExe - $exeTime).TotalSeconds) -lt 1 -and $wBuilt -gt $exeTime) {
                return $wBuilt
            }
        } catch {
            # A corrupt witness is no witness. Fall through to the exe's mtime.
        }
    }
    return $exeTime
}

function Write-GhozttyFreshWitness {
    <#
    .SYNOPSIS
    Record that a successful build covered the tree as it stands right now.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][datetime]$BuiltAtUtc
    )
    $witness = [pscustomobject]@{
        exe             = $Exe
        exeWriteTimeUtc = ([System.IO.File]::GetLastWriteTimeUtc($Exe)).ToString('o')
        builtAtUtc      = $BuiltAtUtc.ToString('o')
        note            = 'T1028: a zig build that relinked nothing still proves this exe covers the sources.'
    }
    $path = Get-GhozttyFreshWitnessPath -Exe $Exe
    $witness | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding ascii
}

function Invoke-GhozttyDebugBuild {
    <#
    .SYNOPSIS
    Build zig-out the way CLAUDE.md says. Returns $true when zig exits 0.

    .DESCRIPTION
    ZIG_GLOBAL_CACHE_DIR must sit on the repo's drive or zig 0.15.2 asserts
    instead of explaining itself (T243), so it is derived rather than assumed.
    TMP/TEMP go to the repo's drive for the same reason (T1431): zig's C/C++
    compile steps scratch there, %TEMP% is on C: on this box, and a full C:
    makes every build die with a bare `error: Unexpected` that names no disk.
    #>
    param([string]$Repo)

    $root = Get-GhozttyRepoRootForFresh -Repo $Repo
    if (-not $env:ZIG_GLOBAL_CACHE_DIR) {
        $env:ZIG_GLOBAL_CACHE_DIR = (Join-Path (Split-Path -Qualifier $root) '\zig-global-cache')
    }
    Write-Host "  BuildFresh: rebuilding $root (zig build -Dapp-runtime=win32 -Doptimize=Debug)..."
    $ok = $false
    $prevTemp = Push-BuildTempEnv -RepoPath $root
    Push-Location $root
    try {
        # Stringify each record before Out-String: `2>&1` puts ErrorRecords on
        # the pipeline and the formatter is host-dependent (lib\StderrCaptureAudit).
        $out = (& zig build -Dapp-runtime=win32 -Doptimize=Debug 2>&1 |
            ForEach-Object { $_.ToString() } | Out-String)
        $ok = ($LASTEXITCODE -eq 0)
        if (-not $ok) {
            Write-Host "  BuildFresh: the rebuild FAILED (zig exit $LASTEXITCODE)."
            foreach ($line in ($out -split "`r?`n" | Where-Object { $_ -match 'error' } | Select-Object -Last 10)) {
                Write-Host "    $line"
            }
        }
    } catch {
        Write-Host "  BuildFresh: the rebuild could not run: $($_.Exception.Message)"
        $ok = $false
    } finally {
        Pop-Location
        Pop-BuildTempEnv -Previous $prevTemp
    }
    return $ok
}

function Test-GhozttyFreshBuild {
    <#
    .SYNOPSIS
    Pure-ish predicate: is $Exe at least as new as the sources it would measure?

    .DESCRIPTION
    Returns a PSCustomObject: Fresh (bool), InScope (bool), ExeTime, HighWater,
    HighWaterPath, DriftSeconds. Out-of-scope exes report Fresh = $true, because
    this gate has nothing to say about them.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string]$Repo
    )

    $shape = [pscustomobject]@{
        Fresh         = $true
        InScope       = $false
        ExeTime       = $null
        HighWater     = $null
        HighWaterPath = $null
        DriftSeconds  = 0
    }

    if (-not (Test-GhozttyExeIsRepoBuild -Exe $Exe -Repo $Repo)) { return $shape }
    $shape.InScope = $true

    $high = Get-GhozttySourceHighWater -Repo $Repo
    if (-not $high) { return $shape }
    $shape.HighWater = $high.Time
    $shape.HighWaterPath = $high.Path

    $exeTime = Get-GhozttyExeBuildTime -Exe $Exe
    if (-not $exeTime) { return $shape }   # a missing exe is BuildMode's refusal to make
    $shape.ExeTime = $exeTime

    if ($high.Time -gt $exeTime) {
        $shape.Fresh = $false
        $shape.DriftSeconds = [int]($high.Time - $exeTime).TotalSeconds
    }
    return $shape
}

function Assert-GhozttyFreshBuild {
    <#
    .SYNOPSIS
    Throw unless $Exe was built from the tree as it now stands.

    .DESCRIPTION
    Call this before the app under test is launched;
    `Assert-GhozttyIsolatedBuild` already does, so an acceptance script gets it
    for free. Silent on the ordinary green path - the whole point is that a
    fresh run reads exactly as it did before.

    -Rebuild (or GHOZTTY_TEST_REBUILD_STALE=1) builds instead of refusing, and
    records a witness so a build that relinked nothing still clears the drift.
    -Allow (or GHOZTTY_TEST_ALLOW_STALE=1) is the loud hatch for a box that
    cannot build; it prints what it let through, because a run made under it
    has to be explainable afterwards rather than silently excused.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string]$Repo,
        [switch]$Allow,
        [switch]$Rebuild
    )

    $state = Test-GhozttyFreshBuild -Exe $Exe -Repo $Repo
    if ($state.Fresh) { return }

    $drift = [TimeSpan]::FromSeconds($state.DriftSeconds)
    $driftText = if ($drift.TotalHours -ge 1) { "{0:N1} hours" -f $drift.TotalHours }
                 elseif ($drift.TotalMinutes -ge 1) { "{0:N0} minutes" -f $drift.TotalMinutes }
                 else { "{0:N0} seconds" -f $drift.TotalSeconds }

    if ($Allow -or $env:GHOZTTY_TEST_ALLOW_STALE -eq '1') {
        Write-Host "  BuildFresh: STALE EXE ALLOWED - $Exe is $driftText older than $($state.HighWaterPath)."
        Write-Host "  BuildFresh: whatever this run reports is about the OLD bytes, not the code as it stands."
        return
    }

    if ($Rebuild -or $env:GHOZTTY_TEST_REBUILD_STALE -eq '1') {
        $startedUtc = [datetime]::UtcNow
        if (Invoke-GhozttyDebugBuild -Repo $Repo) {
            # The build read the sources as they are now, so it covers this
            # high-water mark whether or not the linker had anything to do.
            Write-GhozttyFreshWitness -Exe $Exe -BuiltAtUtc ([datetime]::UtcNow)
            $script:GhozttyFreshCache.Clear()
            $after = Test-GhozttyFreshBuild -Exe $Exe -Repo $Repo
            if ($after.Fresh) {
                Write-Host "  BuildFresh: rebuilt, and the exe now covers the tree."
                return
            }
            throw "Assert-GhozttyFreshBuild: rebuilt $Exe but it still reads as stale (sources changed mid-build?). Re-run."
        }
        throw @"
Assert-GhozttyFreshBuild: REFUSING TO RUN. The exe under test
    $Exe
is $driftText older than the sources it would measure, and the rebuild this run
was asked to do FAILED (see the zig errors above). Nothing was launched.
"@
    }

    $exeLocal = ([datetime]$state.ExeTime).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
    $srcLocal = ([datetime]$state.HighWater).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
    throw @"
Assert-GhozttyFreshBuild: REFUSING TO RUN. The exe under test
    $Exe
was built at $exeLocal, which is $driftText BEFORE the newest source it would
be measuring:
    $($state.HighWaterPath)   ($srcLocal)

So this run would grade code that is not the code under test. A red would be a
phantom you cannot fix by editing anything, and - the reason this gate exists -
a GREEN would exit 0 and STAMP the harness guard (T783), recording that this
harness has been run against the code as it now stands when it never saw it.

Build it and re-run:
    zig build -Dapp-runtime=win32 -Doptimize=Debug

If that build reports nothing to do - the edit was not in this exe's module
graph - re-run this script once with the rebuild opt-in, which records that a
build covered these sources:
    `$env:GHOZTTY_TEST_REBUILD_STALE = '1'

If this box genuinely cannot build and you accept a result about the old bytes,
say so explicitly: `$env:GHOZTTY_TEST_ALLOW_STALE = '1'.
"@
}
