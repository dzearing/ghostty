# SkipAudit (T219) - a SKIP that a script's SUMMARY LINE does not mention is an
# un-run assertion wearing a green hat.
#
# The shape this exists for, measured (T217, 2026-07-31): `ipc-version.ps1`
# asserted the About box is a `#32770` MessageBox. It has been a native
# `GhozttyConfirmDialog` since the T50 chrome pass, so the assertion had been
# WRONG for months - and every run still printed `ALL PASS`, because the
# foreground grab kept losing the race on a busy box and the whole palette
# section took its `SKIP palette test: <reason>` branch instead. Migrating the
# script onto the test desktop made the chord land every time, and the stale
# assertion surfaced on the first run.
#
# A skip is legitimate - pwsh is not installed, there is no network, a release
# build compiled the debug oracle out. What is not legitimate is a skip the
# result cannot see. The loop reads ONE line (`| Select-Object -Last 1`, go.md),
# so a `(2 section(s) SKIPPED)` line printed ABOVE `ALL PASS` is invisible to
# the only reader there is.
#
# THE RULE, therefore, and it is about the last line rather than about skipping:
#
#     A script that can print a SKIP must name the count in the same line that
#     announces the verdict:
#
#         ALL PASS                  ->  ALL PASS (2 SKIPPED)
#         ALL PASS (37 assertions)  ->  ALL PASS (37 assertions, 2 SKIPPED)
#
# Two findings enforce it:
#
#   * `unreported` - the script emits SKIP somewhere and NO line that emits its
#     verdict references a skip count. This is the whole defect.
#   * `uncounted` - a skip site that records nothing, so the count the summary
#     prints is short. A counter that misses sites is worse than no counter: it
#     reads as an audited number.
#
# Exemptions, both narrow:
#   * a site that EXITS within two logical lines - it printed the last line
#     itself, so there is no later summary for it to be missing from
#     (`SKIP ALL: harness could not post keys`; `exit 0`).
#   * a `# skip-audit: <reason>` marker on, or in the three lines above, the
#     site - the same state-your-intent convention the `# persistence:` and
#     `# exitcode-audit:` markers use.
#
# What this does NOT see, stated so a clean sweep is not read as more than it
# is: whether a skip branch is taken OFTEN. That is the other half of T219 and
# no static reader can answer it - a branch that fires on every run and one that
# has never fired look identical in the text. What the rule buys is that when it
# does fire, the one line anybody reads says so.

# Deliberately sets no StrictMode: this file is dot-sourced INTO suite scripts,
# and a mode set here would silently change how every one of them evaluates.

# THE CANONICAL SHAPE. Two lines, no dependency on this file at runtime - a
# rule that needed 25 scripts to dot-source a library would be a rule with a
# migration attached. `$script:skipped++` on an undefined variable is 1 in
# PowerShell 5.1, so there is nothing to initialise:
#
#     Write-Host 'SKIP  pwsh: not installed on this box'; $script:skipped++
#     ...
#     "ALL PASS$(if ($script:skipped) { " ($script:skipped SKIPPED)" })"
#     "ALL PASS (12 assertions$(if ($script:skipped) { ", $script:skipped SKIPPED" }))"
#
# A script that already keeps a counter (`$script:skip`, `$script:skipped`)
# keeps it; only the summary line has to start naming it.

# ---------------------------------------------------------------------------
# The analyzer.
# ---------------------------------------------------------------------------

# Collapse backtick continuations so a wrapped call reads as one logical line,
# carrying the FIRST physical line number so a finding points somewhere a human
# can open. (Same helper shape as ExitCodeAudit; duplicated rather than shared
# so neither lib depends on the other being dot-sourced first.)
function ConvertTo-SkipLogicalLines([string[]]$Lines) {
    $out = New-Object System.Collections.ArrayList
    $buf = ''
    $start = 0
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $t = ($Lines[$i] -replace '\s+$', '')
        if ($buf -eq '') { $start = $i + 1 }
        if ($t -match '`$') {
            $buf += ($t -replace '`$', '') + ' '
            continue
        }
        $buf += $t
        [void]$out.Add([pscustomobject]@{ Text = $buf; Line = $start })
        $buf = ''
    }
    if ($buf -ne '') { [void]$out.Add([pscustomobject]@{ Text = $buf; Line = $start }) }
    return $out
}

# Every single- and double-quoted literal on a line, contents only.
function Get-SkipStringLiterals([string]$Text) {
    $out = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($Text, "'([^']*)'|`"([^`"]*)`"")) {
        $v = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
        [void]$out.Add($v)
    }
    return $out
}

# A literal that both says SKIP and interpolates a skip COUNT is a report of
# skips, not a skip. That one test separates every reporting line in the suite
# ("($($script:skip) section(s) SKIPPED)", "$($script:skipped) SKIPPED",
# "ALL PASS ($($script:skipped) skipped)") from the sites themselves.
function Test-SkipReportLiteral([string]$Literal) {
    return ($Literal -match '\$[^\s]*skip')
}

# A skip site announces itself at the START of its message - `SKIP ALL: ...`,
# `  SKIP F: ...`, `SKIP T233 (rest): ...`. The match is CASE-SENSITIVE and
# anchored on purpose: `skipped(split -> T2)` is tracker fixture data,
# `"the walk SKIPPED a pane"` is prose about a negative control, and
# `"assertions skipped"` is a WARN. None of them is this script skipping, and a
# loose match reported all three (measured while writing this).
# Does this verdict-emitting line say a skip happened? A skip counter
# interpolated into it, the shared suffix, or the word said outright
# ("ALL PASS (37 assertions, pwsh skipped)"). What matters is that the one line
# anybody reads says so.
function Test-SkipVerdictReports([string]$Line) {
    return ($Line -match 'skip')
}

function Test-SkipEmitLiteral([string]$Literal) {
    if ($Literal -cnotmatch '^\s*SKIP') { return $false }
    return (-not (Test-SkipReportLiteral $Literal))
}

# The analyzer. Returns one object per VIOLATION; an empty result is a clean
# file. `-Text` may be passed instead of `-Path` so the self-test can drive it
# from fixtures without writing them to disk.
function Get-SkipAuditFindings {
    param(
        [string]$Path,
        [string[]]$Text
    )
    $lines = if ($null -ne $Text) { $Text } else { @(Get-Content -LiteralPath $Path) }
    $logical = @(ConvertTo-SkipLogicalLines $lines)
    $findings = New-Object System.Collections.ArrayList

    $sites = New-Object System.Collections.ArrayList
    $verdictLines = New-Object System.Collections.ArrayList
    $verdictReports = $false

    for ($i = 0; $i -lt $logical.Count; $i++) {
        $line = $logical[$i].Text
        if ($line -match '^\s*#') { continue }
        $literals = @(Get-SkipStringLiterals $line)
        if ($literals.Count -eq 0) { continue }

        # An assertion is already counted in the pass tally, and a comparison
        # against ANOTHER script's output is not this script's verdict:
        # go-loop-guard and crash-stacks both assert `-match 'ALL PASS'` on a
        # tool they invoke, which is not their own summary line.
        $isAssert = ($line -match '^\s*(Assert|AssertEq|Check)\b')
        $isOperand = ($line -match "-(c|i)?(match|like|eq|ne|contains|notmatch|notlike)\s*['`"][^'`"]*ALL PASS")

        # The verdict line(s): whatever announces this script's own ALL PASS.
        if (-not ($isAssert -or $isOperand)) {
            foreach ($lit in $literals) {
                if ($lit -match 'ALL PASS') {
                    [void]$verdictLines.Add($i)
                    if (Test-SkipVerdictReports $line) { $verdictReports = $true }
                    break
                }
            }
            # T271: a script on the shared scorer has no ALL PASS literal - the
            # scorer prints it - so the CALL is the verdict line, and `-Skipped`
            # is what makes it report the count.
            if ($line -match '\bWrite-Test(Verdict|AssertedNothing)\b') {
                [void]$verdictLines.Add($i)
                if ($line -match '-Skipped\b') { $verdictReports = $true }
            }
        }

        # A blanket "line contains a comparison operator" filter would drop real
        # sites - `if ($null -eq $hot) { Write-Host 'SKIP ...' }` is the suite's
        # commonest skip shape. Only reject the literal when it is the OPERAND
        # of one, i.e. the script is matching somebody else's SKIP text.
        # (The operator list is spelled out rather than `-\w+`, which matches the
        # `-Host` in `Write-Host "SKIP ..."` and silently emptied the sweep.)
        if ($isAssert) { continue }
        if ($line -match "-(c|i)?(match|like|eq|ne|contains|notmatch|notlike|split|replace)\s*['`"]\s*SKIP") { continue }

        foreach ($lit in $literals) {
            if (-not (Test-SkipEmitLiteral $lit)) { continue }
            [void]$sites.Add([pscustomobject]@{ Index = $i; Line = $logical[$i].Line; Literal = $lit })
            break
        }
    }

    if ($sites.Count -eq 0) { return $findings }

    # uncounted: a site that records nothing anywhere near itself.
    $liveSites = 0
    foreach ($s in $sites) {
        $i = $s.Index
        # Explicit marker, on the site or within the three lines above it.
        $marked = $false
        for ($m = [Math]::Max(0, $i - 3); $m -le $i; $m++) {
            if ($logical[$m].Text -match '#\s*skip-audit:') { $marked = $true; break }
        }
        if ($marked) { continue }

        $counted = $false
        $exits = $false
        $verdictBeforeExit = $false
        $from = [Math]::Max(0, $i - 2)
        $to = [Math]::Min($logical.Count - 1, $i + 2)
        for ($j = $from; $j -le $to; $j++) {
            $t = $logical[$j].Text
            if ($t -match '^\s*#') { continue }
            if ($t -match '\$[A-Za-z_:]*skip[A-Za-z]*\s*(\+\+|\+=)') { $counted = $true }
            # T271: the shared scorer reports the count for the script, so
            # `-Skipped <n>` on a `Write-TestVerdict`/`Write-TestAssertedNothing`
            # call IS this site being counted - and that call is also the verdict
            # (it prints the last line and exits), so it ends the search the way
            # an `ALL PASS` literal does.
            if ($t -match '\bWrite-Test(Verdict|AssertedNothing)\b') {
                $verdictBeforeExit = $true
                if ($t -match '-Skipped\b') { $counted = $true }
            }
            if ($j -ge $i -and -not $exits) {
                if ($t -match 'ALL PASS') {
                    $verdictBeforeExit = $true
                    if (Test-SkipVerdictReports $t) { $counted = $true }
                }
                if ($t -match '\bexit\b') { $exits = $true }
            }
        }
        # A site that exits right after printing is its own last line, so there
        # is no later summary for it to be missing from (`SKIP ALL: harness
        # could not post keys`, `exit 0`). But a site that prints SKIP, then
        # `ALL PASS`, then exits is the defect itself - agent-user-env did
        # exactly that, and its last line said ALL PASS with a section un-run.
        if ($exits -and -not $verdictBeforeExit) { continue }
        if ($counted) { $liveSites++; continue }
        $liveSites++

        [void]$findings.Add([pscustomobject]@{
            Path = $Path
            Line = $s.Line
            Kind = 'uncounted'
            Detail = "skip site records nothing: $($s.Literal.Trim())"
        })
    }

    # unreported: skips exist, but the verdict line never names a count.
    if ($liveSites -gt 0 -and $verdictLines.Count -gt 0 -and -not $verdictReports) {
        [void]$findings.Add([pscustomobject]@{
            Path = $Path
            Line = $logical[$verdictLines[0]].Line
            Kind = 'unreported'
            Detail = "$liveSites skip site(s), but the ALL PASS line names no skip count"
        })
    }

    return $findings
}

# Scripts not yet converted, each with the task that converts it. This list may
# only SHRINK: the acceptance script fails an entry that no longer violates
# (so a converted script cannot linger here) and fails a violating script that
# is not listed (so nothing new joins). It is here rather than in a data file
# because it is a statement about work, and it belongs where the rule is.
$script:SkipAuditPending = @{
    'overlay-zorder.ps1' = 'T731'
    'split-divider.ps1'  = 'T731'
}

function Get-SkipAuditPending { return $script:SkipAuditPending }

# Sweep a directory tree of .ps1 files. Returns every finding, flattened.
function Get-SkipAuditSweep([string]$Root) {
    $all = New-Object System.Collections.ArrayList
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -Filter *.ps1 -File)) {
        foreach ($x in @(Get-SkipAuditFindings -Path $f.FullName)) { [void]$all.Add($x) }
    }
    return $all
}
