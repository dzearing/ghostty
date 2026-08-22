# T1097 meta-check: "merge back" never appears bare in the live tree again.
#
# Why: the phrase names THREE unrelated operations in this repo and nothing in
# the wording tells them apart -
#
#   cutover        `users/dzearing/windows-amd64` -> `main` on dzearing/ghoztty.
#                  The goal. Gated by scripts\ship-readiness.ps1, executed by
#                  T1074.
#   upstream pull  ghostty-org/ghostty -> this fork. Allowed, on the user's call
#                  only, mac build first (D80). Planned in
#                  docs\design\windows-parity-upstream-pull-plan.md.
#   upstreaming    this fork -> ghostty-org/ghostty. NEVER happens; the
#                  `upstream` remote is fetch-only by construction (D80).
#
# On 2026-08-22 that collision cost a full round trip with the user twice and
# produced a wrong correction that had to be undone: a digest sentence reading
# "the merge back to upstream Ghostty actually began" was read as this fork
# preparing pull requests against the public Ghostty project, and a task (T1095)
# was filed on the misreading and had to be closed again. CLAUDE.md now bans the
# bare phrase. This script is what makes the ban hold - a rule in a doc that
# nothing checks is a rule that decays.
#
# THE RULE. `merge back` / `merge-back` / `merged back` / `merging back` is a
# finding unless it is REPORTED rather than USED. Two shapes count as reported:
#
#   a quoted mention  - `"merge back"` in a sentence about the phrase itself,
#                       which is exactly what CLAUDE.md, D80 and the two plan
#                       docs do when they explain the ban;
#   a quotation       - a double-quoted span or a markdown blockquote carrying
#                       somebody else's words. The user's own cutover directive
#                       is quoted verbatim in ship-readiness.ps1,
#                       ship-feature.ps1 and the ship-workflow doc, and editing
#                       a quote to fit a naming rule falsifies it.
#
# A quotation is bounded - under 800 characters and no blank line inside - so an
# unbalanced quote mark cannot silently exempt the rest of a file. Everything
# else has to say WHICH merge it means.
#
# WHAT IS HISTORY, and therefore never scanned: the dated digests, the session
# log, the audit / details / spec / divergence / feature-ideas files, every
# decision record (a decision preserves the question AS IT WAS ASKED, including
# the user's verbatim words - rewriting one would falsify the record), and any
# task file already `done` or `skipped(...)`. Inside a still-open task file the
# `## Progress log` is history too and is skipped, so a dated journal entry does
# not have to be edited to keep the tree green.
#
# Sections:
#
#   A  the scanner itself bites (synthetic fixtures, both directions)
#   B  the live tree is clean
#   C  the three senses are each named where a reader lands: the plan doc, the
#      ship-workflow doc and CLAUDE.md all carry the disambiguation
#   D  the renamed plan doc is the one on disk (T1132)
#
# Static scan, no app, no CLI - safe on the off-desktop harness.
#
#   powershell -NoProfile -File test\win32\merge-terminology.ps1
#   powershell -NoProfile -File test\win32\merge-terminology.ps1 -NegativeControl
#
# isolation: none - this script never runs a ghoztty verb; it only reads files.
param(
    [string]$Repo,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Stop'
if (-not $Repo) { $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

$script:failures = 0
$script:passes = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) { "  PASS $name"; $script:passes++ }
    else { "  FAIL $name $detail"; $script:failures++ }
}

# "merge back", "merge-back", "merged back", "merging back", "merges back" -
# and across a line break, because prose wraps. `[-\s]` covers the hyphen, the
# space and the newline in one.
$BarePattern = 'merg\w*[-\s]back'
# The same phrase wrapped in quotes: a MENTION, always allowed. Curly quotes are
# in the class because the markdown here is written with them in places.
$QuotedPattern = '["''“”‘’]\s*merg\w*[-\s]back\s*["''“”‘’]'
# A QUOTATION is reporting what someone else wrote, not writing it: the user's
# directives are quoted verbatim in several live docs and scripts, and editing
# one to fit a naming rule would falsify it. Any double-quoted span is exempt,
# bounded so a stray quote mark cannot swallow a whole file - a real quotation
# is one passage, never a page, and never crosses a blank line.
$QuotationPattern = '"[^"]*"'
$script:QuotationMaxChars = 800

function Read-Text([string]$Path) {
    # ReadAllText decodes the UTF-8 the repo is written in; PS 5.1's
    # Get-Content would read it as the ANSI codepage and mangle every dash.
    try { return [System.IO.File]::ReadAllText($Path) } catch { return '' }
}

# Everything the rule does NOT apply to, stripped before the scan so the caller
# only ever sees real findings.
function Remove-Exempt([string]$Text, [bool]$IsTask) {
    # A still-open task file's `## Progress log` is dated history like the
    # session log: entries are appended, never rewritten.
    if ($IsTask) {
        $idx = $Text.IndexOf("`n## Progress log")
        if ($idx -ge 0) { $Text = $Text.Substring(0, $idx) }
    }
    # A markdown blockquote is somebody else's words by construction.
    $Text = [regex]::Replace($Text, '(?m)^[ \t]*>.*$', ' ')
    # Then quotations, longest form first so the short mention pattern only has
    # to catch the single-quoted case the quotation rule deliberately leaves
    # alone (an apostrophe is not a quote mark, and treating it as one would
    # blank half of any sentence containing "don't").
    $Text = [regex]::Replace($Text, $QuotationPattern, {
        param($m)
        if ($m.Value.Length -gt $script:QuotationMaxChars) { return $m.Value }
        if ($m.Value -match '\r?\n[ \t]*\r?\n') { return $m.Value }
        return ' '
    })
    return [regex]::Replace($Text, $QuotedPattern, ' ', 'IgnoreCase')
}

function Get-BareUses([string]$Text, [bool]$IsTask) {
    $stripped = Remove-Exempt $Text $IsTask
    $out = @()
    foreach ($m in [regex]::Matches($stripped, $BarePattern, 'IgnoreCase')) {
        # Report the phrase with a little context so a finding is actionable
        # without opening the file.
        $from = [Math]::Max(0, $m.Index - 40)
        $len = [Math]::Min($stripped.Length - $from, $m.Length + 80)
        $ctx = ($stripped.Substring($from, $len) -replace '\s+', ' ').Trim()
        $out += $ctx
    }
    return $out
}

# A task file is history once it is closed. Read the frontmatter status rather
# than guessing from the id.
function Test-TaskClosed([string]$Text) {
    $m = [regex]::Match($Text, '(?m)^status:\s*"?([^"\r\n]+)"?\s*$')
    if (-not $m.Success) { return $false }
    $status = $m.Groups[1].Value.Trim()
    return ($status -eq 'done' -or $status -like 'skipped*')
}

# ---------------------------------------------------------------------------
"== A: the scanner bites, in both directions"
# ---------------------------------------------------------------------------
$hits = @(Get-BareUses 'this lands at merge-back with no Mac change' $false)
Assert 'A1 a bare hyphenated use is a finding' ($hits.Count -eq 1) "(got $($hits.Count))"

$hits = @(Get-BareUses 'we will merge back into main next month' $false)
Assert 'A2 a bare spaced use is a finding' ($hits.Count -eq 1) "(got $($hits.Count))"

$hits = @(Get-BareUses 'the work was merged back last week' $false)
Assert 'A3 an inflected use ("merged back") is a finding' ($hits.Count -eq 1) `
    "(got $($hits.Count))"

$hits = @(Get-BareUses "the docs call this `"merge back`" and mean three things" $false)
Assert 'A4 a double-quoted mention is allowed' ($hits.Count -eq 0) "(got $($hits.Count))"

$hits = @(Get-BareUses "Disambiguate 'merge-back': one phrase, three merges" $false)
Assert 'A5 a single-quoted mention is allowed' ($hits.Count -eq 0) "(got $($hits.Count))"

$hits = @(Get-BareUses "prose wraps, so the merge`nback phrase can straddle a line" $false)
Assert 'A6 a use split across a line break is still a finding' ($hits.Count -eq 1) `
    "(got $($hits.Count))"

# The user's own directives are quoted verbatim in live docs and scripts. They
# are the record of what was asked and must not be edited to fit a naming rule.
$hits = @(Get-BareUses 'User directive: "we would get this all merged back into main and make prs."' $false)
Assert 'A6b a verbatim quotation is allowed' ($hits.Count -eq 0) "(got $($hits.Count))"

$hits = @(Get-BareUses "> We will NEVER merge back to ghostty.`nand we mean it" $false)
Assert 'A6c a markdown blockquote is allowed' ($hits.Count -eq 0) "(got $($hits.Count))"

# An unbalanced quote mark must not blank the rest of the file. Both guards -
# the length cap and the blank line - are load-bearing.
$long = '"' + ('x' * 900) + ' merge back ' + ('y' * 100) + '"'
$hits = @(Get-BareUses $long $false)
Assert 'A6d an over-long quoted span is NOT treated as a quotation' ($hits.Count -eq 1) `
    "(got $($hits.Count))"

$hits = @(Get-BareUses "a stray `" mark here`n`nand a paragraph later we merge back anyway `"" $false)
Assert 'A6e a span crossing a blank line is NOT treated as a quotation' ($hits.Count -eq 1) `
    "(got $($hits.Count))"

$taskText = @"
---
id: T999
status: "todo"
---

# T999 - a still-open task

The summary is live prose and is scanned.

## Progress log

- 2026-08-22 07:47: merged back cleanly, no conflicts.
"@
$hits = @(Get-BareUses $taskText $true)
Assert 'A7 an open task file exempts its Progress log' ($hits.Count -eq 0) "(got $($hits.Count))"
Assert 'A8 a done task reads as closed' (Test-TaskClosed 'status: "done"')
Assert 'A9 a skipped task reads as closed' (Test-TaskClosed 'status: "skipped(superseded by T1)"')
Assert 'A10 a todo task does not read as closed' (-not (Test-TaskClosed 'status: "todo"'))
Assert 'A11 an in-progress task does not read as closed' `
    (-not (Test-TaskClosed 'status: "in-progress"'))
# `blocked(...)` is an OPEN state - the task is parked, not closed - and its
# prose is still what a future turn will act on.
Assert 'A12 a blocked task does not read as closed' `
    (-not (Test-TaskClosed 'status: "blocked(waiting on the user)"'))

# ---------------------------------------------------------------------------
"== B: the live tree carries no bare use"
# ---------------------------------------------------------------------------
Push-Location $Repo
try { $tracked = @(& git ls-files) } finally { Pop-Location }
Assert 'B1 git listed the tracked tree' ($tracked.Count -gt 100) "(got $($tracked.Count))"

# The append-only parity record, and the decision files that preserve a question
# as it was asked. See the header for why each one is history.
$HistoryPattern = '^docs/design/windows-parity-(log|audit|details|spec|divergence|feature-ideas)|^docs/design/windows-parity-(digests|decisions)/'
$TaskPattern = '^docs/design/windows-parity-tasks/T[0-9]+\.md$'
$TextExt = @('.md', '.ps1', '.zig', '.swift', '.sh', '.yml', '.yaml', '.txt', '.json')

# THIS file is section A's fixture bank - it holds deliberately bare uses so the
# assertions above can prove the scanner reports one. Scanned like any other
# tracked file they are guaranteed failures and the harness could never go
# green. Its own text is exercised by section A instead.
$SelfRel = 'test/win32/merge-terminology.ps1'

$scanned = 0
$findings = @()
foreach ($rel in $tracked) {
    if ($rel -eq $SelfRel) { continue }
    if ($rel -match $HistoryPattern) { continue }
    if (-not ($TextExt -contains ([System.IO.Path]::GetExtension($rel)))) { continue }
    $full = Join-Path $Repo ($rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $full)) { continue }
    $text = Read-Text $full
    if ($text.Length -eq 0) { continue }
    if ($text -notmatch $BarePattern) { continue }

    $isTask = $rel -match $TaskPattern
    if ($isTask -and (Test-TaskClosed $text)) { continue }
    $scanned++
    foreach ($ctx in (Get-BareUses $text $isTask)) {
        $findings += "$rel :: ...$ctx..."
    }
}

Assert 'B2 the scan reached files that mention the phrase' ($scanned -ge 1) "(scanned $scanned)"
foreach ($f in $findings) { "  BARE USE $f" }
Assert 'B3 no live file uses the bare phrase' ($findings.Count -eq 0) `
    "($($findings.Count) finding(s))"

# ---------------------------------------------------------------------------
"== C: each sense is named where a reader lands"
# ---------------------------------------------------------------------------
$claude = Read-Text (Join-Path $Repo 'CLAUDE.md')
Assert 'C1 CLAUDE.md states the phrase means three things' `
    ($claude -match 'three different things here') "(the standing rule went missing)"
Assert 'C2 CLAUDE.md names all three senses' `
    ($claude -match '(?s)\*\*cutover\*\*.*\*\*upstream pull\*\*.*\*\*Upstreaming\*\*')

$ship = Read-Text (Join-Path $Repo 'docs\design\windows-parity-ship-workflow.md')
Assert 'C3 the ship-workflow doc opens with the three-way table' `
    ($ship -match '(?s)## Which merge this is.*\| \*\*Cutover\*\*.*\| \*\*Upstream pull\*\*.*\| \*\*Upstreaming\*\*')
Assert 'C4 ...and says which one it governs' `
    ($ship -match 'covers the \*\*cutover\*\*')

$plan = Read-Text (Join-Path $Repo 'docs\design\windows-parity-upstream-pull-plan.md')
Assert 'C5 the upstream pull plan opens with the same three-way table' `
    ($plan -match '(?s)## Which merge this is.*\| \*\*Cutover\*\*.*\| \*\*Upstream pull\*\*.*\| \*\*Upstreaming\*\*')
Assert 'C6 ...and says which one it governs' `
    ($plan -match 'covers the middle row only')

$readiness = Read-Text (Join-Path $Repo 'scripts\ship-readiness.ps1')
Assert 'C7 ship-readiness.ps1 says which merge it gates' `
    ($readiness -match '(?s)WHICH MERGE THIS IS.*cutover.*upstream pull.*upstreaming')

# ---------------------------------------------------------------------------
"== D: the plan doc is filed under a name that says which merge it is (T1132)"
# ---------------------------------------------------------------------------
Assert 'D1 the upstream pull plan exists under its disambiguated name' `
    (Test-Path -LiteralPath (Join-Path $Repo 'docs\design\windows-parity-upstream-pull-plan.md'))
Assert 'D2 the old ambiguous filename is gone' `
    (-not (Test-Path -LiteralPath (Join-Path $Repo 'docs\design\windows-parity-merge-back-plan.md')))

# Every place that has to open the plan by path must agree on the new one. A
# stale path here is not cosmetic: upstream-remote.ps1 reads the sha list out of
# this file, and a path that misses makes the anchor check silently vacuous.
$byPath = @(
    'scripts\upstream-remote.ps1',
    'scripts\guard-due.ps1',
    'test\win32\upstream-remote.ps1'
)
$stale = @()
foreach ($rel in $byPath) {
    $t = Read-Text (Join-Path $Repo $rel)
    if ($t -match 'windows-parity-merge-back-plan\.md') { $stale += $rel }
}
foreach ($s in $stale) { "  STALE PLAN PATH $s" }
Assert 'D3 nothing still opens the plan by its old filename' ($stale.Count -eq 0) `
    "($($stale.Count) stale)"

# ---------------------------------------------------------------------------
# Negative control: the scan must be able to go RED against a REAL file, not
# only against section A's string fixtures. Plant one bare use in a tracked live
# doc, scan it, and assert - INVERTED - that nothing was reported. A working
# scanner fails that assertion, so a healthy repo scores exactly 1 FAILURE here;
# a scanner whose pattern quietly stopped matching would pass it and be caught.
# The probe file is restored either way, including on a crash.
# ---------------------------------------------------------------------------
if ($NegativeControl) {
    ""
    "NEGATIVE CONTROL: asserting a planted bare use is NOT reported - a working scan MUST fail this"
    $probe = Join-Path $Repo 'docs\design\windows-parity-ship-workflow.md'
    $original = [System.IO.File]::ReadAllText($probe)
    $hits = @()
    try {
        [System.IO.File]::WriteAllText($probe, $original + "`nWe will merge back next month.`n")
        $hits = @(Get-BareUses (Read-Text $probe) $false)
    } finally {
        [System.IO.File]::WriteAllText($probe, $original)
    }
    Assert 'N1 a planted bare use goes unreported (inverted)' ($hits.Count -eq 0) `
        "(reported $($hits.Count), which is the healthy answer)"
    Assert 'N2 the probe file is restored byte for byte' `
        ([System.IO.File]::ReadAllText($probe) -eq $original)
}

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1 can
# answer "has this scan been run against the tree as it now stands?".
if ($script:failures -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard merge-terminology -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

""
if ($script:failures -eq 0) { "ALL PASS ($script:passes)"; exit 0 }
else { "$script:failures FAILURE(S) ($script:passes passed)"; exit 1 }
