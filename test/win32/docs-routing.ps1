# T822 meta-check: the progressive-disclosure docs routing still resolves.
#
# Why: on 2026-08-15 the root CLAUDE.md was split into a small always-loaded
# core plus seven scenario partitions under docs\claude\, and ~18 files that
# cited a CLAUDE.md section by name were repointed at the partition that now
# owns it. Those pointers are the whole navigation model - a source comment
# saying `docs/claude/cli.md "Instance addressability"` is how the next reader
# finds the contract - and NOTHING checked them. Two survived the split
# pointing at CLAUDE.md sections that had moved out of it (a dangling
# `CLAUDE.md "Naming"` in test\win32\window-name-env.ps1 and a dangling
# `CLAUDE.md, "Agent contract & upgrade compatibility"` in
# docs\design\session-persistence.md), and the only thing that found them was a
# human reading the split's validation criteria by hand a day later.
#
# What is checked:
#
#   B  the root routing table's targets all exist on disk
#   C  every `docs/claude/<file>.md` path cited anywhere in the tracked tree
#      resolves to a real file
#   D  every `<doc> "<section>"` citation (doc = CLAUDE.md or a docs\claude
#      partition) names a heading that really is in that doc
#   E  no partition is orphaned - every docs\claude\*.md is routed to from the
#      root CLAUDE.md, so a file nobody can be told to read is a finding
#
# Deliberately NOT checked: prose mentions of CLAUDE.md with no section
# ("CLAUDE.md: the global cache must sit on the repo's drive"). Those name a
# rule rather than a location, they cannot be verified without guessing, and a
# check that guesses is a check that gets ignored.
#
# The parity history files are excluded from the scan (the log, the digests,
# the task/decision/detail/audit files): they are an append-only record of what
# was true on the day it was written, so a path that later moved must NOT
# retroactively turn them red.
#
# Static scan, no app, no CLI - safe on the off-desktop harness.
#
#   powershell -NoProfile -File test\win32\docs-routing.ps1
#
# isolation: none - this script never runs a ghoztty verb; it only reads files.
param([string]$Repo)

$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

$script:failures = 0
$script:passes = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name $detail"; $script:failures++ }
}

# A citation is `<doc>[,] "<section>"`, where <doc> is the root CLAUDE.md or one
# of its partitions. Both slash flavors, since scripts and zig comments write
# the Windows one.
#
# Two shapes the naive form got wrong, both measured against the real tree:
#
#  * A long citation WRAPS - over a comment block behind a `//!` / `///` / `#`
#    marker in source, or over bare prose in a markdown paragraph. The section
#    may therefore cross ONE newline, marker or not; a heading short enough to
#    cite never wraps twice, and bounding it at one keeps a stray quote from
#    swallowing the rest of a file.
#  * `"== S8.6: ... per docs/claude/cli.md"` in a PowerShell script ends a
#    STRING right after the path, and the naive pattern read that terminator as
#    the opening quote of a section running to the next quote three lines down.
#    A real citation always separates the path from the quote with a space or a
#    comma, so requiring that separator drops the whole false-positive class.
$DocRefPattern = '(?:docs[\\/]claude[\\/][A-Za-z0-9._-]+\.md)'
$CiteContinuation = '\r?\n[ \t]*(?://!|///|//|#|\*)?[ \t]*'
$CitePattern = "((?:$DocRefPattern)|CLAUDE\.md)(?:,[ \t]*|[ \t]+)""([^""\r\n]+(?:$CiteContinuation[^""\r\n]+)?)"""

function Read-Text([string]$Path) {
    # ReadAllText detects the UTF-8 the repo is written in; PS 5.1's
    # Get-Content would decode it as the ANSI codepage and mangle every dash.
    try { return [System.IO.File]::ReadAllText($Path) } catch { return '' }
}

function Get-DocPaths([string]$Text) {
    $out = @()
    foreach ($m in [regex]::Matches($Text, $DocRefPattern)) {
        $out += ($m.Value -replace '/', '\')
    }
    return $out
}

function Get-Citations([string]$Text) {
    $out = @()
    foreach ($m in [regex]::Matches($Text, $CitePattern)) {
        # Fold a wrapped citation back into one line: drop the comment marker
        # the continuation line starts with, then collapse the whitespace.
        $section = [regex]::Replace($m.Groups[2].Value, $CiteContinuation, ' ')
        $section = ($section -replace '\s+', ' ').Trim()
        if ($section.Length -lt 2 -or $section.Length -gt 80) { continue }
        $out += [pscustomobject]@{
            Doc     = ($m.Groups[1].Value -replace '/', '\')
            Section = $section
        }
    }
    return $out
}

function Get-Headings([string]$Path) {
    $text = Read-Text $Path
    $out = @()
    foreach ($m in [regex]::Matches($text, '(?m)^#{1,6}[ \t]+(.+?)[ \t]*$')) {
        $out += $m.Groups[1].Value.Trim()
    }
    return $out
}

# A citation resolves when a heading matches it outright, or begins with it -
# "Naming" is allowed to point at "### Naming (auto names)" - so a heading that
# grows a parenthetical does not break every pointer at it.
function Test-SectionPresent($headings, [string]$section) {
    foreach ($h in $headings) {
        if ($h -eq $section) { return $true }
        if ($h -like "$section*") { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
"== A: the scan itself still bites (synthetic fixtures)"
# ---------------------------------------------------------------------------
$fixDir = Join-Path $env:TEMP "ghoztty-docsroute-$PID"
New-Item -ItemType Directory -Force $fixDir | Out-Null
try {
    $paths = @(Get-DocPaths 'see docs/claude/nope.md and docs\claude\cli.md for more')
    Assert 'A1 both slash flavors of a partition path are found' ($paths.Count -eq 2) `
        "(got $($paths.Count))"
    Assert 'A2 paths are normalized to backslashes' `
        ($paths -contains 'docs\claude\nope.md' -and $paths -contains 'docs\claude\cli.md')

    $cites = @(Get-Citations 'the contract (CLAUDE.md "CLI at a glance") and docs/claude/cli.md, "Naming"')
    Assert 'A3 quoted citations are extracted for both doc forms' ($cites.Count -eq 2) `
        "(got $($cites.Count))"
    Assert 'A4 a citation keeps its doc and section' `
        ($cites[0].Doc -eq 'CLAUDE.md' -and $cites[0].Section -eq 'CLI at a glance' -and `
         $cites[1].Doc -eq 'docs\claude\cli.md' -and $cites[1].Section -eq 'Naming')

    Assert 'A5 an unquoted prose mention is not treated as a citation' `
        (@(Get-Citations 'CLAUDE.md: the global cache must sit on the repo drive').Count -eq 0)

    $wrapped = @'
//! The wire shape is a compatibility boundary (docs/claude/sessions.md, "Agent contract &
//! upgrade compatibility"), so an envelope is additive.
'@
    $wrappedCites = @(Get-Citations $wrapped)
    Assert 'A9 a citation wrapped across a comment block is folded back into one' `
        ($wrappedCites.Count -eq 1 -and `
         $wrappedCites[0].Section -eq 'Agent contract & upgrade compatibility') `
        "(got '$(if ($wrappedCites.Count) { $wrappedCites[0].Section })')"

    $terminator = @'
"== S8.6: +rename / +rearrange / +list per docs/claude/cli.md"
& $Exe +rename --target=ide 2>&1 | Out-Null
Assert "S8.6 renamed"
'@
    Assert 'A10 a path that ends a string is not read as an open citation' `
        (@(Get-Citations $terminator).Count -eq 0)

    $prose = @'
This is part of the mandatory agent-update UX (CLAUDE.md, "Agent contract &
upgrade compatibility"), which the dialog implements.
'@
    $proseCites = @(Get-Citations $prose)
    Assert 'A11 a citation wrapped over bare markdown prose is folded too' `
        ($proseCites.Count -eq 1 -and `
         $proseCites[0].Section -eq 'Agent contract & upgrade compatibility') `
        "(got '$(if ($proseCites.Count) { $proseCites[0].Section })')"

    $fixDoc = Join-Path $fixDir 'fix.md'
    Set-Content -LiteralPath $fixDoc -Encoding ASCII -Value @(
        '# Top',
        'body',
        '### Naming (auto names)',
        'more'
    )
    $fixHeads = Get-Headings $fixDoc
    Assert 'A6 headings are read at every level' `
        ($fixHeads -contains 'Top' -and $fixHeads -contains 'Naming (auto names)')
    Assert 'A7 a section that grew a parenthetical still resolves' `
        (Test-SectionPresent $fixHeads 'Naming')
    Assert 'A8 a section that is not there is reported missing' `
        (-not (Test-SectionPresent $fixHeads 'Instance addressability'))
} finally {
    Remove-Item -Recurse -Force $fixDir -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
"== B: the root routing table points at files that exist"
# ---------------------------------------------------------------------------
$rootPath = Join-Path $Repo 'CLAUDE.md'
$rootText = Read-Text $rootPath
Assert 'B1 the root CLAUDE.md is readable' ($rootText.Length -gt 0)

$routed = @(Get-DocPaths $rootText | Sort-Object -Unique)
Assert 'B2 the routing table names a plausible number of partitions' ($routed.Count -ge 5) `
    "(got $($routed.Count))"

$missingRouted = @()
foreach ($rel in $routed) {
    if (-not (Test-Path (Join-Path $Repo $rel))) { $missingRouted += $rel }
}
foreach ($m in $missingRouted) { "  MISSING routed target $m" }
Assert 'B3 every routed partition exists on disk' ($missingRouted.Count -eq 0) `
    "($($missingRouted.Count) missing)"

# ---------------------------------------------------------------------------
"== C/D: every citation in the tracked tree resolves"
# ---------------------------------------------------------------------------
Push-Location $Repo
try { $tracked = @(& git ls-files) } finally { Pop-Location }
Assert 'C1 git listed the tracked tree' ($tracked.Count -gt 100) "(got $($tracked.Count))"

# The append-only parity record is history, not navigation (see the header).
$HistoryPattern = '^docs/design/windows-parity-(log|audit|details|spec|digests/|tasks/|tasks\.md|decisions/)'
$TextExt = @('.md', '.ps1', '.zig', '.swift', '.sh', '.yml', '.yaml', '.txt', '.json')

$scanned = 0
$badPaths = @()
$badCites = @()
$headingCache = @{}

foreach ($rel in $tracked) {
    if ($rel -match $HistoryPattern) { continue }
    if ($TextExt -notcontains ([System.IO.Path]::GetExtension($rel))) { continue }
    $full = Join-Path $Repo ($rel -replace '/', '\')
    if (-not (Test-Path $full)) { continue }
    $text = Read-Text $full
    if ($text.Length -eq 0) { continue }
    if ($text -notmatch 'CLAUDE\.md|docs[\\/]claude[\\/]') { continue }
    $scanned++

    # @() on both: a helper that found nothing returns an unrolled $null, and
    # only the array wrapper guarantees zero iterations rather than one pass
    # with a null item.
    foreach ($p in @(Get-DocPaths $text)) {
        if (-not (Test-Path (Join-Path $Repo $p))) { $badPaths += "$rel -> $p" }
    }

    foreach ($c in @(Get-Citations $text)) {
        $docRel = $c.Doc
        if ($docRel -eq 'CLAUDE.md') { $docRel = 'CLAUDE.md' }
        $docFull = Join-Path $Repo $docRel
        if (-not (Test-Path $docFull)) { $badCites += "$rel -> $docRel (no such doc)"; continue }
        if (-not $headingCache.ContainsKey($docRel)) {
            $headingCache[$docRel] = @(Get-Headings $docFull)
        }
        if (-not (Test-SectionPresent $headingCache[$docRel] $c.Section)) {
            $badCites += "$rel -> $docRel `"$($c.Section)`" (no such section)"
        }
    }
}

Assert 'C2 the scan reached the files that reference the docs' ($scanned -ge 10) `
    "(scanned $scanned)"
foreach ($b in $badPaths) { "  DANGLING PATH $b" }
Assert 'C3 every docs\claude path cited in the tree exists' ($badPaths.Count -eq 0) `
    "($($badPaths.Count) dangling)"
foreach ($b in $badCites) { "  DANGLING CITATION $b" }
Assert 'D1 every quoted section citation names a real heading' ($badCites.Count -eq 0) `
    "($($badCites.Count) dangling)"

# ---------------------------------------------------------------------------
"== E: no partition is unreachable from the root"
# ---------------------------------------------------------------------------
$partitions = @(Get-ChildItem (Join-Path $Repo 'docs\claude\*.md') -File |
    ForEach-Object { "docs\claude\$($_.Name)" })
Assert 'E1 the partitions directory is populated' ($partitions.Count -ge 5) `
    "(got $($partitions.Count))"

$orphans = @()
foreach ($p in $partitions) {
    if ($routed -notcontains $p) { $orphans += $p }
}
foreach ($o in $orphans) { "  ORPHAN $o (exists but the root routes nobody to it)" }
Assert 'E2 every partition is routed to from the root CLAUDE.md' ($orphans.Count -eq 0) `
    "($($orphans.Count) orphan(s))"

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1 can
# answer "has this scan been run against the docs as they now stand?".
if ($script:failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard docs-routing -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
if ($script:failures -eq 0) { "ALL PASS ($script:passes)"; exit 0 }
else { "$script:failures FAILURE(S) ($script:passes passed)"; exit 1 }
