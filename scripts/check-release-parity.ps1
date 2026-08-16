# Does the newest macOS release have its Windows half? (T579)
#
# Until merge-back a full release is TWO tag pushes: vX.Y.Z on main for macOS
# and win-vX.Y.Z on the Windows branch (T577 explains why one tag cannot do
# both). Skipping the second push produces no error anywhere: every download
# link keeps answering 200, it just hands people an old build -- that is how
# the Windows channel sat three weeks stale (T38), and how v1.32.0/v1.33.0
# shipped macOS-only for six days before this check existed.
#
# So this asserts VERSION DRIFT, not link liveness: the newest vX.Y.Z release
# and the newest win-vX.Y.Z release must carry the same version. It runs in
# two places off one implementation: on this box (the acceptance harness
# test\win32\release-parity.ps1 drives it against fixtures and, under
# -RequireNetwork, against the live repo), and in CI as fork-ci.yml's
# release-parity job on every push to the Windows branch -- the parity loop
# pushes many times a day, so a forgotten win-v tag is loud within hours
# instead of silent for weeks. It deliberately lives NOWHERE near release.yml,
# so it structurally cannot fail or delay the macOS release.
#
# Exit codes: 0 = in step (or nothing to compare), 1 = gap, 2 = could not
# answer (fetch/parse failure -- never conflate "could not look" with "looked
# and it was fine").
#
#   powershell -NoProfile -File scripts\check-release-parity.ps1
#   pwsh -NoProfile -File scripts/check-release-parity.ps1        # CI
#   ... -ReleasesJson fixture.json                                # tests
param(
    [string]$Repo = 'dzearing/ghoztty',
    # Path to a JSON array of release objects ({tag_name, draft, prerelease}),
    # the same shape the GitHub API returns. Fixtures for the harness; omitted
    # = ask the live API via gh.
    [string]$ReleasesJson
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Load the release list.
# ---------------------------------------------------------------------------
$releases = $null
if ($ReleasesJson) {
    if (-not (Test-Path -LiteralPath $ReleasesJson)) {
        Write-Output "ERROR: releases fixture not found: $ReleasesJson"
        exit 2
    }
    try {
        # Assignment, not @(pipeline): under PS 5.1 ConvertFrom-Json emits a
        # JSON array as ONE pipeline item, and @() around that wraps it a
        # second time -- the loop below would then see a single inner array
        # whose member-enumerated .draft is truthy, and skip every release.
        $releases = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $ReleasesJson -Raw)
    } catch {
        Write-Output "ERROR: could not parse $($ReleasesJson): $($_.Exception.Message)"
        exit 2
    }
} else {
    # --paginate + --jq '.[]' emits one JSON object per line (NDJSON), which
    # sidesteps gh's concatenated-arrays pagination output that a plain
    # ConvertFrom-Json cannot parse. per_page=100 keeps it to one page for a
    # long time; --paginate keeps it correct after that.
    $lines = & gh api "repos/$Repo/releases?per_page=100" --paginate `
        --jq '.[] | {tag_name, draft, prerelease}' 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Output "ERROR: gh api failed for repos/$Repo/releases:"
        $lines | ForEach-Object { Write-Output "  $_" }
        exit 2
    }
    try {
        $releases = @($lines | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    } catch {
        Write-Output "ERROR: could not parse gh api output: $($_.Exception.Message)"
        exit 2
    }
}

# ---------------------------------------------------------------------------
# Newest published X.Y.Z per family. Drafts and prereleases are not releases a
# user can be behind on; tags that are not exactly (win-)vX.Y.Z (tip, rc
# builds) are other channels and never part of the pair.
# ---------------------------------------------------------------------------
$macBest = $null   # [version]
$winBest = $null
$macVersions = @()
foreach ($r in $releases) {
    if ($r.draft -or $r.prerelease) { continue }
    if ($r.tag_name -match '^v(\d+\.\d+\.\d+)$') {
        $v = [version]$Matches[1]
        $macVersions += $v
        if ($null -eq $macBest -or $v -gt $macBest) { $macBest = $v }
    } elseif ($r.tag_name -match '^win-v(\d+\.\d+\.\d+)$') {
        $v = [version]$Matches[1]
        if ($null -eq $winBest -or $v -gt $winBest) { $winBest = $v }
    }
}

if ($null -eq $macBest) {
    Write-Output "NOTHING TO COMPARE: no published vX.Y.Z releases in $Repo"
    exit 0
}

if ($null -ne $winBest -and $winBest -ge $macBest) {
    if ($winBest -eq $macBest) {
        Write-Output "IN STEP: v$macBest has its matching win-v$winBest release"
    } else {
        Write-Output "IN STEP: newest Windows release win-v$winBest is ahead of newest macOS release v$macBest"
    }
    exit 0
}

# Gap. Name both ends, and say how far behind in releases (not versions):
# "3 releases behind" is what a person acts on.
$behind = @($macVersions | Sort-Object -Unique | Where-Object { $null -eq $winBest -or $_ -gt $winBest }).Count
$winDesc = 'none'
if ($null -ne $winBest) { $winDesc = "win-v$winBest" }
Write-Output "GAP: newest macOS release v$macBest has no matching win-v$macBest release"
Write-Output "  newest Windows release: $winDesc ($behind release(s) behind)"
Write-Output "  fix: push tag win-v$macBest on the Windows branch (see docs in .github/workflows/release-windows.yml)"
exit 1
