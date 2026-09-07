<#
.SYNOPSIS
    Keep the zig build caches from filling the repo drive (T1054).

.DESCRIPTION
    Zig never evicts its build cache and this project builds all day, so the
    cache grows ~40 GB a day forever. On 2026-08-21 D: reached exactly 0 bytes
    free with 31,359 entries and 1,235 GB in `.zig-cache\o`, and every floor
    lane then died in five seconds with a bare `error: Unexpected` -- which
    reads as broken code, not as a full disk. A turn can burn its whole context
    on that.

    Actions:

      check   Report the cheap health question and exit 0. Never deletes.
      sweep   Report, and CLEAR the caches when they are over a limit. This is
              what `go-loop-exec.ps1 claim` runs once a turn.
      clear   Clear now, whatever the numbers say.

    `check` and `sweep` also ask whether the fetched packages in the global
    cache look WHOLE, not merely numerous (T1436). On 2026-09-07 the claim
    printed "build cache ok: 1025.8 GB free, 1474 entries" and every build on
    the box was already dead: one package had been half-extracted, and this
    report counted it as an entry like any other. Scanning for that costs ~90ms
    over 1,500 packages and is described in scripts\lib\CacheHeal.ps1.

    Clearing is WHOLE, never by age: pruning `o\` alone leaves Zig's manifests
    in `h\` claiming outputs that no longer exist, and the next build fails
    with `failed to spawn build runner ... FileNotFound`. See
    scripts\lib\BuildCache.ps1 for the full argument and the measurements.

    Exit codes: 0 ok (including "over, and cleared"), 2 error. Being over a
    limit is never a nonzero exit -- this runs inside the claim, and a claim
    that can fail over housekeeping wedges the loop, which is the disease and
    not the cure.

.EXAMPLE
    powershell -NoProfile -File scripts\build-cache.ps1 check
    powershell -NoProfile -File scripts\build-cache.ps1 sweep
    powershell -NoProfile -File scripts\build-cache.ps1 clear -Force
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('check', 'sweep', 'clear')]
    [string]$Action = 'check',

    [string]$Repo,
    # Cache directories to consider. Default: the repo's `.zig-cache` plus the
    # zig GLOBAL cache, which is a second multi-GB pile on the same drive.
    [string[]]$CacheDir,
    # Clear when free space on a cache's drive is at or below this. 100 GB is
    # about two and a half days of headroom at the measured ~40 GB/day, which
    # is enough for a weekend of unattended loop turns.
    [double]$MinFreeGB = 100,
    # Backstop for a drive so large that free space never trips: 12,000 entries
    # is ~470 GB at the measured average. A cache this size on a roomy drive is
    # still worth dropping, because every zig operation walks it.
    [int]$MaxEntries = 12000,
    [double]$WarnFreeGB = 0,
    # `clear` refuses without this, so a stray invocation cannot cost somebody
    # a cold rebuild. `sweep` does not need it: being over the limit IS the
    # authorization.
    [switch]$Force,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }
. (Join-Path $PSScriptRoot 'lib\BuildCache.ps1')
# Get-TornPackage: the integrity half of the cache question (T1436).
. (Join-Path $PSScriptRoot 'lib\CacheHeal.ps1')

if (-not $CacheDir -or $CacheDir.Count -eq 0) {
    $CacheDir = @(
        (Join-Path $Repo '.zig-cache'),
        (Resolve-ZigGlobalCacheDir -RepoPath $Repo)
    )
}
# A repo whose global cache resolves onto the repo cache (or a caller passing
# the same path twice) must not be cleared twice and counted twice.
$CacheDir = @($CacheDir | Where-Object { $_ } | Select-Object -Unique)

$state = Get-BuildCacheState -CacheDirs $CacheDir -MinFreeGB $MinFreeGB `
    -MaxEntries $MaxEntries -WarnFreeGB $WarnFreeGB
$tempState = Get-SystemTempState -RepoPath $Repo

# Asked of every cache dir that has a `p\`, which in practice is the global
# one. Never fatal and never nonzero, like everything else this script reports:
# a torn package is a thing to NAME before a lane trips over it, and the repair
# is a delete the caller decides on.
$torn = @()
foreach ($dir in $CacheDir) { $torn += @(Get-TornPackage -GlobalCacheDir $dir) }

$cleared = @()
$didClear = $false

if ($Action -eq 'clear') {
    if (-not $Force) {
        Write-Host "build cache: refusing to clear without -Force (this costs a cold rebuild)"
        exit 0
    }
    $didClear = $true
} elseif ($Action -eq 'sweep' -and $state.Over) {
    $didClear = $true
}

if ($didClear) {
    foreach ($dir in $CacheDir) {
        $r = Clear-BuildCache -CacheDir $dir
        $cleared += $r
    }
}

if ($Json) {
    ([ordered]@{
        action  = $Action
        over    = [bool]$state.Over
        reason  = $state.Reason
        warn    = [bool]$state.Warn
        freeGB  = $state.FreeGB
        entries = $state.Entries
        caches  = @($state.Caches)
        tornPackages = @($torn)
        systemTemp = ([ordered]@{
            path       = $tempState.Path
            drive      = $tempState.Drive
            freeGB     = $tempState.FreeGB
            buildTemp  = $tempState.BuildTemp
            redirected = [bool]$tempState.Redirected
            low        = [bool]$tempState.Low
        })
        cleared = @($cleared)
    } | ConvertTo-Json -Depth 5)
    exit 0
}

if ($didClear) {
    $freed = 0
    $failed = @()
    foreach ($c in $cleared) {
        $freed += $c.FreedGB
        if ($c.Error -and $c.Error -ne 'absent') { $failed += $c }
    }
    $why = if ($Action -eq 'clear') { 'on request' } else { "over limit ($($state.Reason))" }
    Write-Host ("BUILD CACHE CLEARED $why - {0} GB reclaimed, was {1} entries with {2} GB free" -f `
        [math]::Round($freed, 1), $state.Entries, $state.FreeGB)
    foreach ($f in $failed) {
        # Loud, because a partial clear is the dangling-manifest state: `h\`
        # can now name outputs under a half-removed `o\`.
        Write-Host "  PARTIAL: $($f.Path) not fully removed - $($f.Error)"
    }
} else {
    Write-Host $state.Summary
}

# T1436: "big" and "healthy" are different questions and only the first one was
# ever asked here. A torn package is silent until a build needs the file that
# went missing, and then it takes every lane down at once with a message that
# names no task and no change.
if (-not $didClear -and $torn.Count -gt 0) {
    Write-Host "  BUILD CACHE TORN: $($torn.Count) fetched package(s) look half-extracted"
    foreach ($t in ($torn | Select-Object -First 5)) {
        Write-Host "    $($t.Reason): $($t.Entry) - $($t.Detail)"
    }
    Write-Host "    delete the named director(y/ies); the next build re-fetches them"
}

# T1431. The cache numbers above are about the REPO drive; zig's C/C++ compile
# steps scratch in %TEMP%, which is a different drive on this box and was
# measured by nothing. A claim that prints "1078 GB free" while C: holds 0.1 GB
# is worse than silence: it is a reassurance that the next bare
# `error: Unexpected` will be read as broken code. So the drive %TEMP% is
# actually on gets a line of its own, and it says whether a build would even be
# affected -- once the build shells scratch on the repo drive, a full C: is a
# heads-up rather than an outage.
if ($tempState.Low -or -not $tempState.Redirected) {
    Write-Host "  $($tempState.Summary)"
}

if ($Action -ne 'clear') {
    $scratch = @(Get-StaleScratchDir -Repo $Repo -CacheDirs $CacheDir)
    if ($scratch.Count -gt 0) {
        $names = ($scratch | Select-Object -First 6 | ForEach-Object { $_.Name }) -join ', '
        $more = if ($scratch.Count -gt 6) { ", +$($scratch.Count - 6) more" } else { '' }
        Write-Host "  stale scratch dirs: $($scratch.Count) ($names$more) - left alone; delete by hand when done with them"
    }
}

exit 0
