<#
.SYNOPSIS
  Mechanical divergence inventory against upstream ghostty (T516).

.DESCRIPTION
  Merge-back planning needs a list, not a guess: which files did THIS fork
  change since the fork point, which did upstream change in the same span,
  and - the actual merge risk - which did both sides touch. This script
  computes all three sets mechanically and writes a committed report so the
  dashboard and digests can cite it.

  Mechanics: fetch the upstream ref (or resolve a local ref with -NoFetch,
  which is how the acceptance test runs against a synthetic repo), find the
  fork point with `git merge-base`, diff each side against it with
  `--name-status -M`, and tally per-file commit counts with one
  `git log --name-only` pass per side.

  The three lists are emitted in full: the changed-both risk set as a table
  with per-side status and commit counts, the two single-side lists as
  directory rollups with the complete file list in a collapsed block.

  Exit codes: 0 = report written; 2 = no merge base / bad ref; 1 = git error.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

.EXAMPLE
  powershell -NoProfile -File scripts\divergence-inventory.ps1
  # fetches ghostty-org/ghostty main, writes docs\design\windows-parity-divergence.md

.EXAMPLE
  powershell -NoProfile -File scripts\divergence-inventory.ps1 -NoFetch -UpstreamRef mylocal -RepoRoot C:\tmp\repo -OutFile C:\tmp\report.md
#>
[CmdletBinding()]
param(
    [string]$UpstreamUrl = 'https://github.com/ghostty-org/ghostty.git',
    [string]$UpstreamRef = 'main',
    [switch]$NoFetch,
    [string]$OurRef = 'HEAD',
    [string]$RepoRoot,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if (-not $OutFile) { $OutFile = Join-Path $RepoRoot 'docs\design\windows-parity-divergence.md' }

function Invoke-Git {
    param([Parameter(Mandatory)][string[]]$GitArgs)
    $out = & git -C $RepoRoot -c core.quotepath=false @GitArgs
    if ($LASTEXITCODE -ne 0) {
        throw ("git {0} failed (exit {1})" -f ($GitArgs -join ' '), $LASTEXITCODE)
    }
    if ($null -eq $out) { return @() }
    return @($out)
}

function Resolve-Commit {
    param([string]$Ref)
    # ^{commit} so a tag or branch name resolves to the commit it points at.
    $r = @(& git -C $RepoRoot rev-parse --verify --quiet ($Ref + '^{commit}'))
    if ($LASTEXITCODE -ne 0 -or $r.Count -eq 0) { return $null }
    return $r[0]
}

# name-status -M: rename detection on, so a moved file is one R entry under its
# NEW name rather than a phantom delete + add pair. The map value is the
# one-letter status (M/A/D/R/C...); for R/C lines the path is the last field.
function Get-ChangedFiles {
    param([string]$FromSha, [string]$ToSha)
    $map = @{}
    foreach ($line in (Invoke-Git @('diff', '--name-status', '-M', $FromSha, $ToSha))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t"
        if ($parts.Count -lt 2) { continue }
        $map[$parts[$parts.Count - 1]] = $parts[0].Substring(0, 1)
    }
    return $map
}

# One log pass over the whole side: every path line is one commit touching that
# path. `--format=` keeps commit headers out of the stream (blank separators
# are skipped; no real path is whitespace-only).
function Get-CommitCounts {
    param([string]$FromSha, [string]$ToSha)
    $counts = @{}
    $range = '{0}..{1}' -f $FromSha, $ToSha
    foreach ($line in (Invoke-Git @('log', '--format=', '--name-only', $range))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($counts.ContainsKey($line)) { $counts[$line]++ } else { $counts[$line] = 1 }
    }
    return $counts
}

# Depth-2 directory rollup ("src/apprt/", "docs/design/", "(root)") so a
# 2000-file list has a readable summary above the full listing.
function Get-DirRollup {
    param([string[]]$Paths)
    $roll = @{}
    foreach ($p in $Paths) {
        $seg = $p -split '/'
        $key = if ($seg.Count -ge 3) { ($seg[0..1] -join '/') + '/' }
               elseif ($seg.Count -eq 2) { $seg[0] + '/' }
               else { '(root)' }
        if ($roll.ContainsKey($key)) { $roll[$key]++ } else { $roll[$key] = 1 }
    }
    return $roll
}

# --- resolve the three commits ---------------------------------------------

$ourSha = Resolve-Commit $OurRef
if (-not $ourSha) { Write-Host ("ERROR: cannot resolve our ref '{0}'" -f $OurRef); exit 2 }

if ($NoFetch) {
    $upSha = Resolve-Commit $UpstreamRef
    if (-not $upSha) { Write-Host ("ERROR: cannot resolve upstream ref '{0}' (-NoFetch)" -f $UpstreamRef); exit 2 }
    $upstreamLabel = $UpstreamRef
}
else {
    Invoke-Git @('fetch', '--quiet', $UpstreamUrl, $UpstreamRef) | Out-Null
    # @(...) at every call site: a 1-line git answer unrolls to a bare string
    # on return, and [0] on a string is its first CHARACTER (PS 5.1).
    $upSha = @(Invoke-Git @('rev-parse', 'FETCH_HEAD'))[0]
    $upstreamLabel = '{0} {1}' -f $UpstreamUrl, $UpstreamRef
}

$mbOut = @(& git -C $RepoRoot merge-base $ourSha $upSha)
if ($LASTEXITCODE -ne 0 -or $mbOut.Count -eq 0) {
    Write-Host ("ERROR: no merge base between {0} and {1} (unrelated histories?)" -f $ourSha, $upSha)
    exit 2
}
$mb = $mbOut[0]

$mbDate = @(Invoke-Git @('log', '-1', '--format=%ad', '--date=short', $mb))[0]
$mbSubject = @(Invoke-Git @('log', '-1', '--format=%s', $mb))[0]
$ourCommits = [int]@(Invoke-Git @('rev-list', '--count', ('{0}..{1}' -f $mb, $ourSha)))[0]
$upCommits = [int]@(Invoke-Git @('rev-list', '--count', ('{0}..{1}' -f $mb, $upSha)))[0]

# --- compute the three sets -------------------------------------------------

$oursMap = Get-ChangedFiles $mb $ourSha
$upMap = Get-ChangedFiles $mb $upSha

$both = @($oursMap.Keys | Where-Object { $upMap.ContainsKey($_) } | Sort-Object)
$onlyOurs = @($oursMap.Keys | Where-Object { -not $upMap.ContainsKey($_) } | Sort-Object)
$onlyUp = @($upMap.Keys | Where-Object { -not $oursMap.ContainsKey($_) } | Sort-Object)

$ourCounts = Get-CommitCounts $mb $ourSha
$upCounts = Get-CommitCounts $mb $upSha

# --- write the report -------------------------------------------------------

$ourShort = $ourSha.Substring(0, 9)
$upShort = $upSha.Substring(0, 9)
$mbShort = $mb.Substring(0, 9)
$today = Get-Date -Format 'yyyy-MM-dd'

$L = New-Object System.Collections.Generic.List[string]
$L.Add('# Divergence inventory vs upstream Ghostty')
$L.Add('')
$L.Add(('Generated {0} by `scripts/divergence-inventory.ps1` (T516). Regenerate with:' -f $today))
$L.Add('')
$L.Add('```')
$L.Add('powershell -NoProfile -File scripts\divergence-inventory.ps1')
$L.Add('```')
$L.Add('')
$L.Add(('- **Fork point:** `{0}` ({1}) - {2}' -f $mbShort, $mbDate, $mbSubject))
$L.Add(('- **Ours:** `{0}` ({1}) - {2} commits, {3} files changed since the fork point' -f $ourShort, $OurRef, $ourCommits, ($oursMap.Count)))
$L.Add(('- **Upstream:** `{0}` ({1}) - {2} commits, {3} files changed' -f $upShort, $upstreamLabel, $upCommits, ($upMap.Count)))
$L.Add(('- **Changed on both sides (merge risk set): {0} files** - listed in full below' -f $both.Count))
$L.Add(('- **Changed only here:** {0} files (no upstream conflict possible)' -f $onlyOurs.Count))
$L.Add(('- **Changed only upstream:** {0} files (arrive clean on a merge)' -f $onlyUp.Count))
$L.Add('')
$L.Add('Status letters: M modified, A added, D deleted, R renamed, C copied.')
$L.Add('A file we deleted that upstream kept editing (D vs M) is still merge')
$L.Add('risk - the risk set is any path BOTH sides touched, whatever the touch.')
$L.Add('Commit counts are non-merge commits whose diff touches the path')
$L.Add('(equivalent to `git log --full-history --no-merges -- <path>` over the')
$L.Add('same range), so a merge that carried a change in is not double-counted.')
$L.Add('')
$L.Add(('## Changed on both sides ({0} files) - the merge risk set' -f $both.Count))
$L.Add('')
$L.Add('| File | Ours | Our commits | Upstream | Upstream commits |')
$L.Add('|---|---|---|---|---|')
foreach ($p in $both) {
    $oc = if ($ourCounts.ContainsKey($p)) { $ourCounts[$p] } else { 0 }
    $uc = if ($upCounts.ContainsKey($p)) { $upCounts[$p] } else { 0 }
    $L.Add(('| `{0}` | {1} | {2} | {3} | {4} |' -f $p, $oursMap[$p], $oc, $upMap[$p], $uc))
}

foreach ($side in @(
        @{ Title = 'Changed only here'; Paths = $onlyOurs; Counts = $ourCounts },
        @{ Title = 'Changed only upstream'; Paths = $onlyUp; Counts = $upCounts })) {
    $L.Add('')
    $L.Add(('## {0} ({1} files)' -f $side.Title, $side.Paths.Count))
    $L.Add('')
    $L.Add('| Directory | Files |')
    $L.Add('|---|---|')
    $roll = Get-DirRollup $side.Paths
    foreach ($k in ($roll.Keys | Sort-Object)) {
        $L.Add(('| `{0}` | {1} |' -f $k, $roll[$k]))
    }
    $L.Add('')
    $L.Add('<details><summary>Full list</summary>')
    $L.Add('')
    $L.Add('```')
    foreach ($p in $side.Paths) {
        $c = if ($side.Counts.ContainsKey($p)) { $side.Counts[$p] } else { 0 }
        $L.Add(('{0}  ({1} commits)' -f $p, $c))
    }
    $L.Add('```')
    $L.Add('')
    $L.Add('</details>')
}
$L.Add('')

$outDir = Split-Path -Parent $OutFile
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}
[System.IO.File]::WriteAllLines($OutFile, $L, (New-Object System.Text.UTF8Encoding($false)))

# --- stdout summary ---------------------------------------------------------

Write-Host ('DIVERGENCE fork point {0} ({1})' -f $mbShort, $mbDate)
Write-Host ('  ours     {0} ({1}): {2} commits, {3} files' -f $ourShort, $OurRef, $ourCommits, $oursMap.Count)
Write-Host ('  upstream {0} ({1}): {2} commits, {3} files' -f $upShort, $upstreamLabel, $upCommits, $upMap.Count)
Write-Host ('  changed both (risk set): {0}' -f $both.Count)
Write-Host ('  changed only here: {0}' -f $onlyOurs.Count)
Write-Host ('  changed only upstream: {0}' -f $onlyUp.Count)
Write-Host ('  report: {0}' -f $OutFile)
exit 0
