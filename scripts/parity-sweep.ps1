<#
.SYNOPSIS
  Enumerate the Mac-side commits in a range and report which ones nothing in
  the Windows parity docs has ever referenced.

.DESCRIPTION
  The parity sweeps before this one (T88, T117) were NARRATIVE summaries of
  what a merge contained. A summary cannot be checked for completeness; an
  enumeration can. On 2026-07-29 a re-audit of three weeks of history turned up
  16 Mac commits with zero references in any Windows doc - features that had
  been merged into this branch and were never mapped to a work item, which is
  how a Mac feature silently never arrives on Windows.

  So this is the gate: for a commit range, list every non-merge commit touching
  the Mac-side paths, then report which of them are UNMAPPED - no reference
  anywhere under docs/design/windows-parity*. Unmapped commits exit 1, so the
  daily main intake (go.md step 0.6) cannot record a clean sweep over a hole.

  Coverage is keyed on the COMMIT SHA, because that is the one identifier a
  Mac commit and a Windows task can share. A commit counts as mapped when any
  task file, log entry, digest, decision, or the intake watermark mentions its
  sha in any abbreviation of 7 characters or longer. That is the same test the
  2026-07-29 hand audit used; this makes it repeatable, and reports WHICH file
  did the mentioning, so "filed as" is evidence rather than memory.

  Deliberately NOT a heuristic about subjects or file paths: a commit is either
  written down somewhere or it is not, and only the second kind is a leak.

  WHAT COUNTS AS MAC-SIDE (T685). The original watch list was macos/ and
  src/viewer/, which is what the 2026-07-29 audit happened to measure. But a
  parity obligation arrives just as often through the SHARED core: T604 exists
  because main rewrote src/cli/send_keys.zig underneath this branch's
  bracketed-paste work, and nothing flagged it. So the default is now the whole
  of macos/ plus the whole of src/, minus the two frontends that owe Windows
  nothing - src/apprt/win32/ (ours) and src/apprt/gtk/ (Linux). Subtracting
  from src/ rather than listing an allowlist of subtrees is deliberate: a gate
  that misses a directory main adds next month is this exact defect again.

  WHICH SIDE IS ENUMERATED. Widening the paths puts this branch's own work in
  scope too - 187 of our commits touch shared src/ since the merge-base - so a
  range that spans this branch would drown the finding in our own history and
  the gate would be ignored within a day. Only the INCOMING side is therefore
  enumerated: a commit in the range that is not reachable from -IncomingRef
  (origin/main, else main) is branch-local, dropped, and counted separately in
  the report. For the daily intake range (<watermark>..origin/main) that is a
  no-op; for "-Range <merge-base>..HEAD" it is the difference between a usable
  report and 187 lines of noise.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).

.EXAMPLE
  # The default: everything on origin/main since the last recorded intake.
  scripts\parity-sweep.ps1

.EXAMPLE
  # A specific merge range, as a gate before closing the merge task.
  scripts\parity-sweep.ps1 -Range cda6e5191..4a41394b2

.EXAMPLE
  # The block to paste into the intake note / merge task as evidence.
  scripts\parity-sweep.ps1 -Range cda6e5191..4a41394b2 -Format markdown
#>
[CmdletBinding()]
param(
    # A git rev-range ("a..b"). Wins over -Since. With neither, the range is
    # "<lastEvaluated from the intake watermark>..origin/main", i.e. exactly
    # the commits the daily intake still owes tasks for.
    [string]$Range,

    # Shorthand for "-Range <sha>..origin/main".
    [string]$Since,

    # The paths a parity-relevant commit touches. macos/ is the Swift frontend;
    # src/ is the shared core (CLI surface, termio, the agent, the viewer page
    # assets), every part of which can hand Windows an obligation. The two
    # exclusions are the frontends that cannot: src/apprt/win32/ is ours, and
    # src/apprt/gtk/ is Linux's. See the T685 note in the header.
    [string[]]$Paths = @(
        'macos/',
        'src/',
        ':(exclude)src/apprt/win32/',
        ':(exclude)src/apprt/gtk/'
    ),

    # The ref that defines the INCOMING side. A commit in the range that is not
    # reachable from here is this branch's own work, and is excluded from the
    # enumeration rather than reported as an unmapped Mac change. Defaults to
    # origin/main, else main; empty in a clone that has neither, which disables
    # the exclusion (and says so in the report).
    [string]$IncomingRef,

    # Where the parity docs live. Overridable so the acceptance test can point
    # the reference index at a fixture instead of the real tracker.
    [string]$DocsPath,

    [ValidateSet('text', 'markdown', 'json')]
    [string]$Format = 'text',

    # Also list the mapped commits (with the file that maps each). Off by
    # default: the finding is the unmapped set, and a 70-row "all fine" table
    # buries it.
    [switch]$ShowMapped,

    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

if (-not $DocsPath) {
    $DocsPath = Join-Path $RepoRoot 'docs\design'
}

$IntakePath = Join-Path $RepoRoot 'docs\design\windows-parity-main-intake.json'

# ---------------------------------------------------------------------------
# Range resolution
# ---------------------------------------------------------------------------

# PS 5.1 wraps a native command's stderr lines in NativeCommandError records,
# which under $ErrorActionPreference = 'Stop' THROW - so a merely chatty git
# ("warning: refname 'main' is ambiguous") would fail the gate with a message
# about the wrong thing entirely. Drop to Continue across the call and judge
# the command by its exit code, which is the only thing that means "failed".
function Invoke-Git {
    param([string[]]$GitArgs)

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git -C $RepoRoot @GitArgs 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prev
    }

    if ($code -ne 0) {
        throw ("git " + ($GitArgs -join ' ') + " failed (exit $code): " + (@($out) -join "`n"))
    }
    # Keep only real output lines: an ErrorRecord here is a stderr line from a
    # command that nonetheless succeeded, and it is not a commit.
    return @($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
}

# Same reasoning for the existence probes, which are allowed to fail.
function Test-Rev {
    param([string]$Rev)

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git -C $RepoRoot rev-parse --verify --quiet "$Rev^{commit}" > $null 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prev
    }
    return ($code -eq 0)
}

function Resolve-Range {
    if ($Range) { return $Range }

    $head = 'origin/main'
    if (-not (Test-Rev $head)) {
        # No fetched origin/main on this box - fall back to plain main so the
        # script is still usable in a bare clone.
        $head = 'main'
        if (-not (Test-Rev $head)) {
            throw "neither origin/main nor main resolves; pass -Range explicitly"
        }
    }

    if ($Since) { return "$Since..$head" }

    if (-not (Test-Path -LiteralPath $IntakePath)) {
        throw "no -Range/-Since and no intake watermark at $IntakePath; pass -Range explicitly"
    }
    $intake = Get-Content -LiteralPath $IntakePath -Raw | ConvertFrom-Json
    if (-not $intake.lastEvaluated) {
        throw "intake watermark has no lastEvaluated; pass -Range explicitly"
    }
    return ("{0}..{1}" -f $intake.lastEvaluated, $head)
}

function Resolve-IncomingRef {
    if ($IncomingRef) {
        if (-not (Test-Rev $IncomingRef)) {
            throw "-IncomingRef '$IncomingRef' does not resolve to a commit"
        }
        return $IncomingRef
    }
    foreach ($candidate in @('origin/main', 'main')) {
        if (Test-Rev $candidate) { return $candidate }
    }
    # A clone with neither: enumerate the range as given rather than refuse.
    return ''
}

# ---------------------------------------------------------------------------
# The reference index: every commit-sha-shaped token in the parity docs, and
# the file each came from.
# ---------------------------------------------------------------------------

# A sha reference is 7-40 hex characters that is not part of a longer
# identifier and not a "#rrggbb" color. Keyed on the first 7 characters so a
# lookup is one hashtable hit; the full token is re-checked as a prefix of the
# candidate sha, which is what keeps a coincidental 7-hex word from mapping a
# commit it has nothing to do with.
$ShaToken = [regex]'(?<![#0-9A-Za-z])([0-9a-f]{7,40})(?![0-9A-Za-z])'

function Build-ReferenceIndex {
    param([string]$Root)

    $index = @{}
    if (-not (Test-Path -LiteralPath $Root)) { return $index }

    $files = Get-ChildItem -LiteralPath $Root -Recurse -File |
        Where-Object { $_.FullName -like '*windows-parity*' -and ($_.Extension -eq '.md' -or $_.Extension -eq '.json') }

    foreach ($f in $files) {
        $text = Get-Content -LiteralPath $f.FullName -Raw
        if (-not $text) { continue }
        foreach ($m in $ShaToken.Matches($text)) {
            $tok = $m.Groups[1].Value
            $key = $tok.Substring(0, 7)
            if (-not $index.ContainsKey($key)) { $index[$key] = New-Object System.Collections.ArrayList }
            [void]$index[$key].Add([pscustomobject]@{ Token = $tok; File = $f })
        }
    }
    return $index
}

# The label a mapped commit is "filed as": the task id when the reference lives
# in a task file, otherwise the doc's own name. This is why the sweep can print
# a Filed-as column without anyone maintaining one.
function Get-SourceLabel {
    param([System.IO.FileInfo]$File)

    if ($File.Directory.Name -eq 'windows-parity-tasks' -and $File.BaseName -match '^T\d+[a-z]*$') {
        return $File.BaseName
    }
    if ($File.Directory.Name -eq 'windows-parity-decisions' -and $File.BaseName -match '^D\d+$') {
        return $File.BaseName
    }
    return $File.Name
}

function Find-Mapping {
    param([hashtable]$Index, [string]$Sha)

    $key = $Sha.Substring(0, 7)
    if (-not $Index.ContainsKey($key)) { return $null }

    $labels = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($entry in $Index[$key]) {
        # The indexed token must really be an abbreviation OF this sha, not
        # merely share its first seven characters.
        if ($Sha.StartsWith($entry.Token)) {
            $label = Get-SourceLabel $entry.File
            if (-not $labels.Contains($label)) { $labels.Add($label, $true) }
        }
    }
    if ($labels.Count -eq 0) { return $null }
    return @($labels.Keys)
}

# ---------------------------------------------------------------------------
# Sweep
# ---------------------------------------------------------------------------

$resolvedRange = Resolve-Range
$resolvedIncoming = Resolve-IncomingRef

$logArgs = @('log', '--no-merges', '--format=%H%x09%s', $resolvedRange, '--')
$logArgs += $Paths
$lines = @(Invoke-Git $logArgs)

# The branch-local set: in the range, touching the watched paths, but NOT
# reachable from the incoming ref. These are this branch's own commits, which
# are not Mac changes owed a Windows task and must never be reported as such.
$local = @{}
if ($resolvedIncoming) {
    $localArgs = @('rev-list', '--no-merges', $resolvedRange, '--not', $resolvedIncoming, '--')
    $localArgs += $Paths
    foreach ($s in @(Invoke-Git $localArgs)) {
        $s = ([string]$s).Trim()
        if ($s) { $local[$s] = $true }
    }
}

$index = Build-ReferenceIndex -Root $DocsPath

$mapped = New-Object System.Collections.ArrayList
$unmapped = New-Object System.Collections.ArrayList
$excluded = 0

foreach ($line in $lines) {
    $line = [string]$line
    if (-not $line.Trim()) { continue }
    $parts = $line.Split("`t", 2)
    $sha = $parts[0]
    $subject = if ($parts.Length -gt 1) { $parts[1] } else { '' }

    if ($local.ContainsKey($sha)) { $excluded++; continue }

    $labels = Find-Mapping -Index $index -Sha $sha
    $row = [pscustomobject]@{
        commit   = $sha.Substring(0, 9)
        sha      = $sha
        subject  = $subject
        filed_as = if ($labels) { @($labels) } else { @() }
    }
    if ($labels) { [void]$mapped.Add($row) } else { [void]$unmapped.Add($row) }
}

$total = $mapped.Count + $unmapped.Count

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

switch ($Format) {
    'json' {
        [pscustomobject]@{
            range           = $resolvedRange
            paths           = $Paths
            incoming_ref    = $resolvedIncoming
            excluded_local  = $excluded
            total           = $total
            mapped          = @($mapped)
            unmapped        = @($unmapped)
        } | ConvertTo-Json -Depth 5
    }

    'markdown' {
        '## Parity coverage'
        ''
        ("Range: ``{0}`` (paths: {1})" -f $resolvedRange, (($Paths | ForEach-Object { '`' + $_ + '`' }) -join ', '))
        ''
        ("- Commits evaluated: {0}" -f $total)
        ("- Mapped to Windows work items: {0}" -f $mapped.Count)
        if ($excluded -gt 0) {
            ("- Excluded as branch-local (not reachable from ``{0}``): {1}" -f $resolvedIncoming, $excluded)
        }
        if ($unmapped.Count -gt 0) {
            ("- **Unmapped: {0}** - file a task for each before closing this merge." -f $unmapped.Count)
            ''
            '| Commit | Subject | Filed as |'
            '|---|---|---|'
            foreach ($r in $unmapped) {
                ("| ``{0}`` | {1} |  |" -f $r.commit, ($r.subject -replace '\|', '\|'))
            }
        }
        else {
            '- Unmapped: 0'
        }
        if ($ShowMapped -and $mapped.Count -gt 0) {
            ''
            '<details><summary>Mapped commits</summary>'
            ''
            '| Commit | Subject | Filed as |'
            '|---|---|---|'
            foreach ($r in $mapped) {
                ("| ``{0}`` | {1} | {2} |" -f $r.commit, ($r.subject -replace '\|', '\|'), ($r.filed_as -join ', '))
            }
            ''
            '</details>'
        }
    }

    default {
        ("PARITY SWEEP {0}" -f $resolvedRange)
        ("  paths:   {0}" -f ($Paths -join ' '))
        ("  docs:    {0}" -f $DocsPath)
        if ($resolvedIncoming) {
            ("  incoming: {0}   branch-local excluded: {1}" -f $resolvedIncoming, $excluded)
        }
        else {
            "  incoming: (unresolved - branch-local exclusion disabled)"
        }
        ("  commits: {0}   mapped: {1}   unmapped: {2}" -f $total, $mapped.Count, $unmapped.Count)
        if ($ShowMapped -and $mapped.Count -gt 0) {
            ''
            'MAPPED:'
            foreach ($r in $mapped) {
                ("  {0}  {1}  [{2}]" -f $r.commit, $r.subject, ($r.filed_as -join ', '))
            }
        }
        if ($unmapped.Count -gt 0) {
            ''
            'UNMAPPED (file a task for each before recording this range as swept):'
            foreach ($r in $unmapped) {
                ("  {0}  {1}" -f $r.commit, $r.subject)
            }
        }
        ''
        if ($unmapped.Count -gt 0) {
            ("{0} UNMAPPED COMMIT(S)" -f $unmapped.Count)
        }
        else {
            "SWEEP CLEAN ($total commit(s) evaluated)"
        }
    }
}

if ($unmapped.Count -gt 0) { exit 1 }
exit 0
