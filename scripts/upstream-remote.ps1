<#
.SYNOPSIS
  Keep a permanent `upstream` remote (ghostty-org/ghostty) wired up and fetched,
  so every sha the upstream pull plan cites stays resolvable.

.DESCRIPTION
  T957, Stage 0 of docs\design\windows-parity-upstream-pull-plan.md.

  The plan pins six staged merge points plus the fork point by sha. Before this
  script those objects were in the store for one reason only: `divergence-
  inventory.ps1` had fetched them once, by sha, into no ref. Nothing kept them
  alive - a `git gc` was free to drop every one of them, and the day it did, the
  merge plan would still READ fine while none of its shas resolved. A dangling
  plan is worse than no plan: it looks like preparation.

  A remote fixes that (upstream/main is a ref, and all seven shas are its
  ancestors), but a remote is LOCAL CONFIG. It cannot arrive by `git pull`, the
  Mac seat's clone has never had one, and a fresh clone starts without it - the
  same shape as `core.hooksPath` in git-commit-guard.ps1 (T948). So the durable
  form is not "somebody ran `git remote add` once" but a checked-in script that
  re-asserts it, wired into `go-loop-exec.ps1 claim` - the one command every
  turn runs first.

  ensure   Add the remote if missing, correct its URL if it drifted, fetch when
           the refs are absent or the last fetch is older than -MaxAgeHours, and
           ANCHOR every plan sha with a local tag. Then print the same verdict
           `check` would - UPSTREAM OK or UPSTREAM PROBLEM. NEVER fatal: an
           offline box, a DNS failure or a proxy must not wedge the loop, so a
           failed fetch is a WARNING and exit 0, and so is a PROBLEM verdict. The
           remote itself still gets added, because that part needs no network.
  check    Report without touching the network or writing a ref, and exit 1 if
           anything is wrong: remote present, URL canonical, upstream/main
           resolvable, and every sha cited in the upstream pull plan resolvable AND
           anchored by a local tag. This is the assertion the plan depends on.
  list     Print what is known, always exit 0.

  Fetch recency is stamped in .git\ghoztty-upstream-fetch.json rather than read
  off FETCH_HEAD, which any `git fetch origin` also touches.

  T1099 changed what "kept alive" means here, twice over.

  A remote-tracking ref is NOT a durable anchor. On 2026-08-22 a turn ran
  `git remote remove upstream` by hand; that deletes refs/remotes/upstream/*, and
  re-adding the remote twelve minutes later did not bring the ref back. For the
  next hour and a half every plan sha was reachable from nothing and a `git gc`
  was entitled to drop it. The same hole opens on a refspec change, on a fresh
  clone, and on the Mac seat, which has never fetched this remote at all. So the
  anchor is now a LOCAL TAG per plan sha (`refs/tags/upstream-anchor/<sha>`):
  a ref this repo owns, that no remote operation can prune, and that survives the
  remote being removed outright. Lightweight on purpose - `git push` never
  carries a lightweight tag, and `push.followTags` only ever carries annotated
  ones, so anchoring cannot leak these into origin.

  And the verdict `ensure` prints is now `check`'s verdict, not a weaker one. It
  used to say UPSTREAM OK on `upstream/main` resolving ALONE, never asking the
  plan-sha question - so the one line the loop prints every turn could not go red
  for the exact thing the script exists to protect. It printed
  `UPSTREAM OK (upstream/main a88ad03e6, fetched 16h ago)` on the very turn whose
  acceptance run scored 5 failures against this repo.

  Acceptance: test\win32\upstream-remote.ps1.

.EXAMPLE
  powershell -NoProfile -File scripts\upstream-remote.ps1 ensure
  powershell -NoProfile -File scripts\upstream-remote.ps1 check
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('ensure', 'check', 'list')]
    [string]$Action = 'ensure',

    [string]$Repo,
    [string]$Url = 'https://github.com/ghostty-org/ghostty.git',
    [string]$Remote = 'upstream',
    [int]$MaxAgeHours = 24,
    [switch]$Force,
    [switch]$NoFetch,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = Split-Path -Parent $PSScriptRoot }

# The plan doc is the source of the sha list on purpose: a hard-coded list here
# would go stale the moment a stage is re-cut, and then `check` would be green
# about shas nobody is merging.
$PlanRelative = 'docs\design\windows-parity-upstream-pull-plan.md'

# The durable anchor namespace (T1099). One lightweight tag per plan sha, under
# a prefix nothing else uses, so `git tag -l "$AnchorPrefix*"` is exactly the set
# this script owns and a human reading `git tag` can tell what they are for.
$AnchorPrefix = 'upstream-anchor/'

# ---------------------------------------------------------------------------
# git plumbing. Every call captures per-record (T883): `2>&1 | Out-String` on a
# native command yields a formatted ErrorRecord block whose text tracks the
# host's buffer width, and an assertion over that is an assertion about the
# console it ran in.
# ---------------------------------------------------------------------------
function Invoke-Git {
    param([string[]]$GitArgs)
    # Function-scoped, so a git that writes to stderr (a missing remote, an
    # unknown sha - both NORMAL answers here) reports through its exit code
    # instead of a NativeCommandError landing on the host.
    $ErrorActionPreference = 'SilentlyContinue'
    $out = @(& git -C $Repo @GitArgs 2>$null)
    return [pscustomobject]@{
        Code   = $LASTEXITCODE
        Lines  = $out
        Text   = ($out -join "`n").Trim()
    }
}

function Get-RemoteUrl {
    $r = Invoke-Git @('remote', 'get-url', $Remote)
    if ($r.Code -ne 0) { return $null }
    return $r.Text
}

# Two spellings of the same remote must not read as drift: git accepts the
# .git suffix optional, and `git remote add` records exactly what it was given.
function Test-SameUrl {
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return $false }
    $na = $A.Trim().TrimEnd('/') -replace '\.git$', ''
    $nb = $B.Trim().TrimEnd('/') -replace '\.git$', ''
    return [string]::Equals($na, $nb, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-StampPath {
    $r = Invoke-Git @('rev-parse', '--git-dir')
    if ($r.Code -ne 0 -or -not $r.Text) { return $null }
    $gitDir = $r.Text
    if (-not [System.IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $Repo $gitDir }
    return (Join-Path $gitDir 'ghoztty-upstream-fetch.json')
}

function Get-LastFetch {
    $p = Get-StampPath
    if (-not $p) { return $null }
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        $j = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        if ($j.lastFetch) { return [datetime]::Parse($j.lastFetch) }
    } catch { }
    return $null
}

function Set-LastFetch {
    param([datetime]$When)
    $p = Get-StampPath
    if (-not $p) { return }
    try {
        $obj = [pscustomobject]@{ lastFetch = $When.ToString('o'); remote = $Remote; url = $Url }
        ($obj | ConvertTo-Json) | Set-Content -LiteralPath $p -Encoding UTF8
    } catch { }
}

function Format-Ago {
    param([datetime]$When)
    $span = (Get-Date) - $When
    if ($span.TotalMinutes -lt 1) { return 'just now' }
    if ($span.TotalHours -lt 1) { return ("{0}m ago" -f [int]$span.TotalMinutes) }
    if ($span.TotalDays -lt 1) { return ("{0}h ago" -f [int]$span.TotalHours) }
    return ("{0}d ago" -f [int]$span.TotalDays)
}

# Every 9+ hex token inside backticks in the plan. Extracting from the doc is
# what makes this check track the plan instead of a copy of it.
function Get-PlanShas {
    $path = Join-Path $Repo $PlanRelative
    # No leading-comma return: every call site wraps in @(), and `return ,@()`
    # makes an EMPTY result count as one there (PS 5.1).
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $text = Get-Content -LiteralPath $path -Raw
    $found = @{}
    foreach ($m in [regex]::Matches($text, '`([0-9a-f]{9,40})`')) {
        $found[$m.Groups[1].Value] = $true
    }
    return @($found.Keys | Sort-Object)
}

function Get-AnchorName {
    param([string]$Sha)
    return "$AnchorPrefix$Sha"
}

# True only when the tag exists AND points at the commit it names. A tag left
# behind by a re-cut plan would otherwise read as an anchor for whatever sha it
# happens to be spelled with.
function Test-Anchored {
    param([string]$Sha)
    $tag = Get-AnchorName $Sha
    $t = Invoke-Git @('rev-parse', '--verify', '--quiet', "refs/tags/$tag^{commit}")
    if ($t.Code -ne 0 -or -not $t.Text) { return $false }
    $c = Invoke-Git @('rev-parse', '--verify', '--quiet', "$Sha^{commit}")
    if ($c.Code -ne 0 -or -not $c.Text) { return $false }
    return [string]::Equals($t.Text, $c.Text, [System.StringComparison]::OrdinalIgnoreCase)
}

# Writes the anchor. Returns $true when it created one, $false when there was
# nothing to do or the write failed - a repo on a read-only volume must not wedge
# the loop, which is the same argument as the never-fatal fetch below.
function Add-Anchor {
    param([string]$Sha)
    if (Test-Anchored $Sha) { return $false }
    $tag = Get-AnchorName $Sha
    # -f so a tag pointing at the wrong object is repaired rather than skipped.
    $r = Invoke-Git @('tag', '-f', $tag, "$Sha^{commit}")
    return ($r.Code -eq 0)
}

function Get-AnchorTags {
    $r = Invoke-Git @('tag', '-l', "$AnchorPrefix*")
    if ($r.Code -ne 0) { return @() }
    return @($r.Lines | Where-Object { $_ })
}

function Test-ShaState {
    param([string]$Sha)
    $t = Invoke-Git @('cat-file', '-t', $Sha)
    if ($t.Code -ne 0 -or $t.Text -ne 'commit') {
        return [pscustomobject]@{ Sha = $Sha; Resolves = $false; Ancestor = $false; Anchored = $false }
    }
    $a = Invoke-Git @('merge-base', '--is-ancestor', $Sha, "$Remote/main")
    return [pscustomobject]@{
        Sha      = $Sha
        Resolves = $true
        Ancestor = ($a.Code -eq 0)
        Anchored = (Test-Anchored $Sha)
    }
}

# One place builds the verdict, so `ensure` and `check` cannot drift into
# answering different questions - which is the defect T1099 fixed. Ancestry of
# upstream/main is REPORTED but is not a problem on its own: it is a property of
# the remote being fetched, while the anchor is what actually keeps the object
# alive.
function Get-Problems {
    param($State, $Rows, $Shas)
    $problems = @()
    if (-not $State.Url) { $problems += "remote '$Remote' is not configured" }
    elseif (-not $State.UrlOk) { $problems += "remote '$Remote' points at '$($State.Url)', expected '$Url'" }
    if (-not $State.Head) { $problems += "$Remote/main does not resolve (never fetched?)" }
    foreach ($r in @($Rows)) {
        if (-not $r.Resolves) { $problems += "merge-plan sha $($r.Sha) does not resolve" }
        elseif (-not $r.Anchored) { $problems += "merge-plan sha $($r.Sha) is not anchored by a tag (gc bait)" }
    }
    if (@($Shas).Count -eq 0) { $problems += "the upstream pull plan cites no shas (is $PlanRelative missing?)" }
    return @($problems)
}

function Get-State {
    # NOT $url: PowerShell variable names are case-INSENSITIVE, so a local
    # `$url` here IS the script's `-Url` parameter, and the comparison below
    # would be the configured URL against itself - which reads as "always
    # correct" and silently disables the drift repair. Cost: one red B3.
    $currentUrl = Get-RemoteUrl
    $head = Invoke-Git @('rev-parse', '--short=9', "$Remote/main")
    return [pscustomobject]@{
        Remote    = $Remote
        Url       = $currentUrl
        UrlOk     = (Test-SameUrl $currentUrl $Url)
        Head      = $(if ($head.Code -eq 0) { $head.Text } else { $null })
        LastFetch = Get-LastFetch
    }
}

# ---------------------------------------------------------------------------

switch ($Action) {

    'ensure' {
        $state = Get-State
        $notes = @()

        if (-not $state.Url) {
            $add = Invoke-Git @('remote', 'add', $Remote, $Url)
            if ($add.Code -ne 0) {
                "WARNING upstream remote could not be added: $($add.Text)"
                exit 0
            }
            $notes += "added"
        } elseif (-not $state.UrlOk) {
            # A drifted URL is worse than a missing one - it resolves, so
            # nothing complains, and the shas it fetches are somebody else's.
            $set = Invoke-Git @('remote', 'set-url', $Remote, $Url)
            if ($set.Code -ne 0) {
                "WARNING upstream remote URL is '$($state.Url)', expected '$Url' (set-url failed)"
            } else {
                $notes += "url corrected from '$($state.Url)'"
            }
        }

        $state = Get-State
        $needFetch = $false
        $why = ''
        if ($Force) { $needFetch = $true; $why = 'forced' }
        elseif (-not $state.Head) { $needFetch = $true; $why = 'no upstream/main ref' }
        elseif (-not $state.LastFetch) { $needFetch = $true; $why = 'never stamped' }
        elseif (((Get-Date) - $state.LastFetch).TotalHours -ge $MaxAgeHours) {
            $needFetch = $true
            $why = "last fetch $(Format-Ago $state.LastFetch)"
        }

        if ($needFetch -and $NoFetch) {
            $notes += "fetch skipped (-NoFetch; $why)"
            $needFetch = $false
        }

        if ($needFetch) {
            $f = Invoke-Git @('fetch', '--prune', $Remote)
            if ($f.Code -ne 0) {
                # Offline is a normal state for this box, and a loop that
                # cannot claim because GitHub is unreachable is a worse
                # failure than a stale upstream ref.
                "WARNING upstream fetch failed ($why); working with what is in the store"
                $state = Get-State
                if ($state.Head) { "  upstream remote present ($Remote/main $($state.Head))" }
                exit 0
            }
            Set-LastFetch (Get-Date)
            $notes += "fetched ($why)"
            $state = Get-State
        }

        # Anchor before judging (T1099). Every plan sha that resolves gets a
        # local tag, so the objects stop depending on a remote-tracking ref that
        # a `git remote remove` deletes out from under them.
        $shas = @(Get-PlanShas)
        $anchored = 0
        foreach ($s in $shas) { if (Add-Anchor $s) { $anchored++ } }
        if ($anchored -gt 0) { $notes += "anchored $anchored sha(s)" }

        $rows = @()
        foreach ($s in $shas) { $rows += (Test-ShaState $s) }
        $problems = @(Get-Problems -State $state -Rows $rows -Shas $shas)

        $suffix = ''
        if ($notes.Count -gt 0) { $suffix = ' - ' + ($notes -join ', ') }
        if ($problems.Count -eq 0) {
            $when = ''
            if ($state.LastFetch) { $when = ", fetched $(Format-Ago $state.LastFetch)" }
            "UPSTREAM OK ($Remote/main $($state.Head)$when)$suffix"
            "  merge-plan shas: $(@($rows | Where-Object { $_.Anchored }).Count)/$($shas.Count) anchored by tag"
        } else {
            # Reported, never fatal: a loop that cannot claim because GitHub is
            # unreachable is a worse failure than an unanchored sha. The teeth
            # are test\win32\upstream-remote.ps1 via guard-due, not this exit code.
            "UPSTREAM PROBLEM$suffix"
            foreach ($p in $problems) { "  $p" }
            "  remedy: powershell -NoProfile -File scripts\upstream-remote.ps1 ensure -Force"
        }
        exit 0
    }

    'check' {
        $state = Get-State
        $shas = @(Get-PlanShas)
        # Evaluated whether or not upstream/main resolves: the whole point of the
        # tag anchor is that a sha stays alive with the remote gone, so a missing
        # ref must no longer hide the sha question behind it.
        $rows = @()
        foreach ($s in $shas) { $rows += (Test-ShaState $s) }
        $problems = @(Get-Problems -State $state -Rows $rows -Shas $shas)

        if ($Json) {
            [pscustomobject]@{
                remote    = $Remote
                url       = $state.Url
                urlOk     = $state.UrlOk
                head      = $state.Head
                lastFetch = $(if ($state.LastFetch) { $state.LastFetch.ToString('o') } else { $null })
                planShas  = @($rows | ForEach-Object { [pscustomobject]@{ sha = $_.Sha; resolves = $_.Resolves; ancestor = $_.Ancestor; anchored = $_.Anchored } })
                problems  = @($problems)
            } | ConvertTo-Json -Depth 5
        } else {
            if ($problems.Count -eq 0) {
                $when = ''
                if ($state.LastFetch) { $when = ", fetched $(Format-Ago $state.LastFetch)" }
                "UPSTREAM OK ($Remote/main $($state.Head)$when)"
                "  merge-plan shas: $(@($rows | Where-Object { $_.Anchored }).Count)/$($shas.Count) anchored by tag, $(@($rows | Where-Object { $_.Ancestor }).Count)/$($shas.Count) reachable from $Remote/main"
            } else {
                "UPSTREAM PROBLEM"
                foreach ($p in $problems) { "  $p" }
                "  remedy: powershell -NoProfile -File scripts\upstream-remote.ps1 ensure -Force"
            }
        }
        if ($problems.Count -eq 0) { exit 0 } else { exit 1 }
    }

    'list' {
        $state = Get-State
        "remote:     $Remote"
        "url:        $($state.Url)"
        "head:       $($state.Head)"
        "lastFetch:  $(if ($state.LastFetch) { $state.LastFetch.ToString('o') } else { '(none)' })"
        $planShas = @(Get-PlanShas)
        "plan shas:  $($planShas -join ' ')"
        $anchors = @(Get-AnchorTags)
        "anchors:    $(@($planShas | Where-Object { Test-Anchored $_ }).Count)/$($planShas.Count) (tags under $AnchorPrefix)"
        # A tag left behind by a re-cut plan is worth SEEING - it is not a
        # problem (it keeps an object alive and costs nothing) but it is the
        # only trace that the plan used to name something else.
        $stale = @($anchors | Where-Object { $planShas -notcontains ($_ -replace [regex]::Escape($AnchorPrefix), '') })
        if ($stale.Count -gt 0) { "stale:      $($stale -join ' ') (anchors for shas the plan no longer cites)" }
        exit 0
    }
}
