# AssertedNothingAudit (T271) - find the places where a script can announce
# ALL PASS and exit 0 having asserted nothing.
#
# The runtime half of this rule is `lib\TestScore.ps1` (`Write-TestVerdict`),
# which refuses to call a zero-assertion run a pass. This is the static half:
# the sweep that says whether any script still has a path around it.
#
# Two finding kinds are the defect itself and must stay at zero:
#
#   * `zero-count`  - a verdict whose own text hardcodes a zero assertion count
#                     (`ALL PASS (0 checks, 1 SKIPPED)`). Provable by reading it.
#   * `early-green` - a pass verdict that ENDS THE RUN with exit 0 somewhere
#                     other than the script's final verdict: a precondition or
#                     whole-run-skip branch that scores the run green. This is
#                     the exact shape T271 was filed for, and the three sites
#                     that had it (`host-settings`, `agent-user-env`,
#                     `agent-instance-lineage -Release`) each reached it for a
#                     different, entirely ordinary reason - a held port, a box
#                     without a usable PATH entry, a missing staging build.
#
# One kind is reported but NOT yet enforced:
#
#   * `uncounted-final` - the final verdict prints no assertion count at all
#                     (`"ALL PASS"`), so neither a human nor a machine can tell
#                     a full run from an empty one by reading it. 50-odd scripts
#                     are in this state; converting them onto `Write-TestVerdict`
#                     is T775's job, and the acceptance script prints the number
#                     so the ratchet is visible rather than asserting a list of
#                     names that would be pure noise today.
#
# Exemption, narrow and stated: an `# asserted-nothing-audit: <reason>` marker
# anywhere in the file, the same state-your-intent convention the
# `# persistence:`, `# exitcode-audit:`, `# skip-audit:` and `# verdict-audit:`
# markers use.
#
# This reads the AST rather than the text, for the reason VerdictExitAudit does:
# `exit 0` shares a line with the verdict in most of this suite
# (`if ($fail -eq 0) { "ALL PASS"; exit 0 }`), and branch membership is a
# structural question. Helpers are named apart from that file's on purpose -
# both are dot-sourced into the same acceptance script, and two files quietly
# redefining each other's `Get-VerdictSite` is a trap nobody would see.

# Deliberately sets no StrictMode: this file is dot-sourced INTO suite scripts,
# and a mode set here would silently change how every one of them evaluates.

function Get-ScoreAst {
    param([string]$Path, [string[]]$Text)
    $tokens = $null
    $errors = $null
    if ($null -ne $Text) {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            ($Text -join "`n"), [ref]$tokens, [ref]$errors)
    } else {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref]$tokens, [ref]$errors)
    }
    return [pscustomobject]@{ Ast = $ast; Errors = @($errors) }
}

# A string that is an operand of a comparison is somebody ELSE's verdict being
# scored (`$laneText -match 'ALL PASS'`), not one this script emits.
function Test-ScoreComparisonOperand($Node) {
    $p = $Node.Parent
    while ($p) {
        if ($p -is [System.Management.Automation.Language.BinaryExpressionAst]) { return $true }
        if ($p -is [System.Management.Automation.Language.StatementAst]) { return $false }
        $p = $p.Parent
    }
    return $false
}

# Every pass verdict this file EMITS, in source order.
function Get-ScoreVerdictSites($Ast) {
    return @($Ast.FindAll({ param($n)
        ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
         $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and
        $n.Extent.Text -match 'ALL PASS' }, $true) |
        Where-Object { -not (Test-ScoreComparisonOperand $_) })
}

function Get-ScoreEnclosingStatement($Node) {
    $n = $Node
    while ($n) {
        if ($n -is [System.Management.Automation.Language.StatementAst] -and
            $n.Parent -is [System.Management.Automation.Language.StatementBlockAst]) { return $n }
        if ($n -is [System.Management.Automation.Language.StatementAst] -and
            $n.Parent -is [System.Management.Automation.Language.NamedBlockAst]) { return $n }
        $n = $n.Parent
    }
    return $null
}

# `exit 0`, a bare `exit`, and `exit $anything` are three different answers.
function Get-ScoreExitKind($ExitStatement) {
    if ($null -eq $ExitStatement.Pipeline) { return 'zero' }
    $t = $ExitStatement.Pipeline.Extent.Text.Trim()
    if ($t -eq '0') { return 'zero' }
    if ($t -match '^-?\d+$') { return 'nonzero' }
    return 'unknown'
}

# Does the run END, green, in the same block as this verdict? Only the SAME
# block is considered, deliberately: walking outward would find the script's own
# closing `exit 0` for every site in the file and report the whole suite.
function Get-ScoreTerminatingExit($Site) {
    $stmt = Get-ScoreEnclosingStatement $Site
    if ($null -eq $stmt) { return $null }
    $parent = $stmt.Parent
    $stmts = $null
    if ($parent -is [System.Management.Automation.Language.StatementBlockAst]) { $stmts = $parent.Statements }
    elseif ($parent -is [System.Management.Automation.Language.NamedBlockAst]) { $stmts = $parent.Statements }
    if ($null -eq $stmts) { return $null }

    $seen = $false
    foreach ($s in $stmts) {
        if (-not $seen) { if ($s -eq $stmt) { $seen = $true }; continue }
        $exits = @($s.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true))
        if ($exits.Count -gt 0) { return $exits[0] }
    }
    # `{ "ALL PASS"; exit 0 }` puts both in one pipeline-free block, but
    # `Write-TestVerdict` and `"...", exit` shapes can also hide the exit inside
    # the verdict statement itself - a call that exits is not an ExitStatement.
    return $null
}

# Does this site's own text name a pass COUNT? A verdict interpolating a counter
# (`ALL PASS ($script:pass assertions)`) reports what it measured; a bare
# `"ALL PASS"` reports nothing, and `(0 ...)` reports that it measured nothing.
function Test-ScoreCountsAssertions($Site) {
    $t = $Site.Extent.Text
    if ($t -match 'ALL PASS\s*\(\s*0\b') { return $false }
    return ($t -match '\$')
}

function Test-ScoreZeroCount($Site) {
    return ($Site.Extent.Text -match 'ALL PASS\s*\(\s*0\b')
}

# Is the verdict produced by the shared scorer rather than by a hand-rolled
# string? `Write-TestVerdict` cannot print a pass with a zero count, so a script
# that uses it satisfies the rule by construction.
function Test-ScoreUsesSharedScorer($Ast) {
    $calls = @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] }, $true))
    foreach ($c in $calls) {
        $name = $c.GetCommandName()
        if ($name -eq 'Write-TestVerdict' -or $name -eq 'Write-TestAssertedNothing') { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# The analyzer. One object per finding; an empty result is a clean file.
# `-Text` may be passed instead of `-Path` so the self-test drives it from
# fixtures without writing them to disk.
# ---------------------------------------------------------------------------
function Get-AssertedNothingFindings {
    param(
        [string]$Path,
        [string[]]$Text
    )
    $findings = New-Object System.Collections.ArrayList
    $lines = if ($null -ne $Text) { $Text } else { @(Get-Content -LiteralPath $Path) }

    foreach ($l in $lines) { if ($l -match '#\s*asserted-nothing-audit:') { return $findings } }

    $parsed = Get-ScoreAst -Path $Path -Text $Text
    if ($parsed.Errors.Count -gt 0) {
        [void]$findings.Add([pscustomobject]@{
            Path = $Path; Line = $parsed.Errors[0].Extent.StartLineNumber
            Kind = 'parse-error'; Detail = $parsed.Errors[0].Message })
        return $findings
    }

    $sites = @(Get-ScoreVerdictSites $parsed.Ast)
    # No verdict at all is VerdictExitAudit's finding, not this one - a helper
    # with nothing to score is not a script that scored nothing.
    if ($sites.Count -eq 0) { return $findings }

    $final = $sites[-1]

    foreach ($site in $sites) {
        if (Test-ScoreZeroCount $site) {
            [void]$findings.Add([pscustomobject]@{
                Path = $Path; Line = $site.Extent.StartLineNumber; Kind = 'zero-count'
                Detail = "the verdict names a zero assertion count: $($site.Extent.Text.Trim())" })
            continue
        }
        if ($site -eq $final) { continue }
        $exit = Get-ScoreTerminatingExit $site
        if ($null -ne $exit -and (Get-ScoreExitKind $exit) -eq 'zero') {
            [void]$findings.Add([pscustomobject]@{
                Path = $Path; Line = $site.Extent.StartLineNumber; Kind = 'early-green'
                Detail = "a pass verdict ends the run green before the final verdict: $($site.Extent.Text.Trim())" })
        }
    }

    if (-not (Test-ScoreCountsAssertions $final) -and -not (Test-ScoreUsesSharedScorer $parsed.Ast)) {
        [void]$findings.Add([pscustomobject]@{
            Path = $Path; Line = $final.Extent.StartLineNumber; Kind = 'uncounted-final'
            Detail = "the final verdict names no assertion count: $($final.Extent.Text.Trim())" })
    }

    return $findings
}

# The kinds that are the defect and must stay at zero. `uncounted-final` is
# reported and counted, not enforced - see the header.
function Get-AssertedNothingHardKinds { return @('zero-count', 'early-green', 'parse-error') }

# Sweep the acceptance scripts. NOT recursive, for the reason VerdictExitAudit
# is not: an acceptance script is a top-level file in `test\win32`, while `lib\`
# holds dot-sourced libraries with no verdict of their own.
function Get-AssertedNothingSweep([string]$Root) {
    $all = New-Object System.Collections.ArrayList
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Filter *.ps1 -File)) {
        foreach ($x in @(Get-AssertedNothingFindings -Path $f.FullName)) { [void]$all.Add($x) }
    }
    return $all
}
