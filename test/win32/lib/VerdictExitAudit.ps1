# VerdictExitAudit (T221) - a script whose LAST LINE says FAILURE(S) and whose
# EXIT CODE says 0 is a red run wearing a green hat.
#
# The shape this exists for, measured: `chooser-menu.ps1` and
# `host-settings.ps1` both ended
#
#     if ($script:fail -eq 0) { "ALL PASS (...)" } else { "$($script:fail) FAILURE(S) (...)" }
#
# with no `exit` anywhere near it, so a run with five red assertions fell off
# the end of the script and left `$LASTEXITCODE` at 0. The summary line was
# correct and a human reading it saw the failure; anything SCORING the script -
# a suite driver, a `; if ($?)` chain, CI later - read it as a pass. (Both were
# fixed in passing by T218/T219 before this task reached them; the class was
# closed here.) `config-errors.ps1` had the identical bug and was fixed in T217.
#
# THE RULE:
#
#     The failure path of a script's verdict must terminate the script with a
#     nonzero exit code, and the pass path must not fall into the failure
#     verdict on its way out.
#
# Both halves matter, and the second is not hypothetical: the suite's other
# common verdict shape is an early return
#
#     if ($script:fail -eq 0) { "ALL PASS"; exit 0 }
#     "$script:fail FAILURE(S)"
#     exit 1
#
# where dropping the `exit 0` makes a GREEN run print FAILURE(S) and exit 1.
# One rule, two directions, which is what T221 asked for: exits 1 on failure
# AND exits 0 on success.
#
# Findings:
#
#   * `fallthrough`  - the failure path never reaches a nonzero exit. The whole
#                      defect.
#   * `exits-zero`   - the failure path reaches `exit 0` (or a bare `exit`).
#                      Worse than falling off the end, because it looks
#                      deliberate.
#   * `pass-falls-through` - the pass branch does not terminate, and the code
#                      after the verdict `if` prints a failure verdict. A green
#                      run announces failure.
#   * `no-verdict`   - the file emits no `ALL PASS` at all, so there is no
#                      verdict to score. Legitimate for a helper (see the
#                      marker below); a defect for an acceptance script.
#
# Exemption, narrow and stated: a `# verdict-audit: <reason>` marker anywhere in
# the file, the same state-your-intent convention the `# persistence:`,
# `# exitcode-audit:` and `# skip-audit:` markers use. `ipc-fake-server.ps1`
# carries one - it is a helper process with no verdict to report, and "fixing"
# it would be inventing a verdict for something that does not assert anything.
#
# What this does NOT see, so a clean sweep is not read as more than it is:
# whether the code the failure path exits with is nonzero when it is COMPUTED
# rather than written (`exit ([int]($failures -gt 0))`, `exit $(if (...) {0} else {1})`).
# No static reader can evaluate that, and two scripts legitimately do it. Such
# an exit satisfies the rule here; the on-the-wire section of
# `verdict-exit-audit.ps1` is what measures the real code, both directions.
#
# This reads the AST rather than the text, unlike its two sibling audits, and
# the reason is specific: `exit 1` lives on the SAME line as the verdict in most
# of this suite (`else { "$fail FAILURE(S)"; exit 1 }`), and a line-oriented
# reader must then decide what "near" means. A naive one written first reported
# 128 of 160 scripts. Branch membership is a structural question, so ask the
# parser.

# Deliberately sets no StrictMode: this file is dot-sourced INTO suite scripts,
# and a mode set here would silently change how every one of them evaluates.

# ---------------------------------------------------------------------------
# AST helpers.
# ---------------------------------------------------------------------------

function Get-VerdictAst {
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

function Get-VerdictStrings($Ast) {
    return @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true))
}

# The verdict site: the LAST `ALL PASS` this script EMITS. Filtering matters -
# `go-loop-guard`, `crash-stacks` and `skip-visibility` all compare against
# somebody else's `ALL PASS`, and `skip-visibility` writes one into a fixture
# file. An operand of a comparison is somebody else's verdict; taking the last
# emission steps past a fixture written earlier in the file.
function Test-VerdictOperand($Node) {
    $p = $Node.Parent
    while ($p) {
        if ($p -is [System.Management.Automation.Language.BinaryExpressionAst]) { return $true }
        if ($p -is [System.Management.Automation.Language.StatementAst]) { return $false }
        $p = $p.Parent
    }
    return $false
}

function Get-VerdictSite($Ast) {
    $cands = @(Get-VerdictStrings $Ast | Where-Object {
        $_.Extent.Text -match 'ALL PASS' -and -not (Test-VerdictOperand $_) })
    if ($cands.Count -eq 0) { return $null }
    return $cands[-1]
}

# Which branch of a candidate `if` holds the pass verdict, which are the others,
# and what runs after the whole statement. One place, because the verdict-`if`
# search and the analyzer proper both need the same split.
function Split-VerdictBranches($If, $Site) {
    $passBody = $null
    $otherBodies = New-Object System.Collections.ArrayList
    foreach ($c in $If.Clauses) {
        if ($c.Item2.Extent.StartOffset -le $Site.Extent.StartOffset -and
            $c.Item2.Extent.EndOffset -ge $Site.Extent.EndOffset) { $passBody = $c.Item2 }
        else { [void]$otherBodies.Add($c.Item2) }
    }
    if ($null -ne $If.ElseClause) {
        if ($If.ElseClause.Extent.StartOffset -le $Site.Extent.StartOffset -and
            $If.ElseClause.Extent.EndOffset -ge $Site.Extent.EndOffset) { $passBody = $If.ElseClause }
        else { [void]$otherBodies.Add($If.ElseClause) }
    }
    return [pscustomobject]@{
        PassBody    = $passBody
        OtherBodies = $otherBodies
        After       = @(Get-StatementsAfter $If)
    }
}

# The verdict `if` is not always the INNERMOST one around the `ALL PASS` (T963).
# `tab-tooltip.ps1` picks its wording inside the pass branch:
#
#     if ($script:fail -eq 0) {
#         if ($script:skipped) { "ALL PASS (N, K SKIPPED)" } else { stamp; "ALL PASS (N)" }
#     } else { "$script:fail FAILURE(S)"; exit 1 }
#
# The innermost `if` around the last `ALL PASS` there partitions SKIPPED from
# clean, not pass from fail. Scored against that one the file reads as a
# `fallthrough` - neither of its branches exits and nothing follows it - while
# the real failure path exits 1 correctly. The other direction is the dangerous
# one: an `exit 0` sitting in such a nested branch would ANSWER for a failure
# path that never runs it, and the audit would go quiet over the very defect it
# exists for.
#
# So walk outward and take the innermost enclosing `if` whose failure path
# actually ANNOUNCES failure - its other branches if it has any, otherwise the
# code after it. That is the pass/fail branch point by the only static evidence
# there is. If no enclosing `if` qualifies (a script that words its failure
# verdict outside what `Test-EmitsFailureVerdict` reads), fall back to the
# innermost, which is what this did before.
function Get-VerdictIf($Site) {
    $innermost = $null
    $n = $Site
    while ($n) {
        if ($n -is [System.Management.Automation.Language.IfStatementAst]) {
            if ($null -eq $innermost) { $innermost = $n }
            $split = Split-VerdictBranches $n $Site
            $failStatements = New-Object System.Collections.ArrayList
            foreach ($b in $split.OtherBodies) {
                foreach ($s in $b.Statements) { [void]$failStatements.Add($s) }
            }
            $announces = if ($failStatements.Count -gt 0) {
                Test-EmitsFailureVerdict $failStatements
            } else {
                Test-EmitsFailureVerdict $split.After
            }
            if ($announces) { return $n }
        }
        $n = $n.Parent
    }
    return $innermost
}

# Statements that run AFTER $Node, walking outward through every enclosing
# block. The verdict `if` sits at the end of the script, so in practice this is
# "the rest of the file", but a verdict nested in a try/finally still resolves.
function Get-StatementsAfter($Node) {
    $out = New-Object System.Collections.ArrayList
    $cur = $Node
    while ($cur -and $cur.Parent) {
        $parent = $cur.Parent
        $stmts = $null
        if ($parent -is [System.Management.Automation.Language.StatementBlockAst]) { $stmts = $parent.Statements }
        elseif ($parent -is [System.Management.Automation.Language.NamedBlockAst]) { $stmts = $parent.Statements }
        if ($null -ne $stmts) {
            $seen = $false
            foreach ($s in $stmts) {
                if ($seen) { [void]$out.Add($s); continue }
                if ($s -eq $cur) { $seen = $true }
            }
        }
        $cur = $parent
    }
    return $out
}

# `exit 0`, bare `exit`, and `exit $anything` are three different answers.
#   zero    - provably exits 0
#   nonzero - provably exits nonzero
#   unknown - a computed code; no static reader can say (see the header)
function Get-ExitKind($ExitStatement) {
    if ($null -eq $ExitStatement.Pipeline) { return 'zero' }
    $t = $ExitStatement.Pipeline.Extent.Text.Trim()
    if ($t -eq '0') { return 'zero' }
    if ($t -match '^-?\d+$') { return 'nonzero' }
    return 'unknown'
}

# The first exit reached by running these statements in order, or $null.
function Get-FirstExit($Statements) {
    foreach ($s in @($Statements)) {
        if ($null -eq $s) { continue }
        $exits = @($s.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true))
        if ($exits.Count -gt 0) { return $exits[0] }
    }
    return $null
}

# Does this run of statements announce a FAILURE verdict? The caps are the
# signal and the match is case-sensitive on purpose: `Assert "no fail on close"`
# is an assertion name, `FAILURE(S)` / `FAILED` is a verdict.
function Test-EmitsFailureVerdict($Statements) {
    foreach ($s in @($Statements)) {
        if ($null -eq $s) { continue }
        foreach ($str in @(Get-VerdictStrings $s)) {
            if (Test-VerdictOperand $str) { continue }
            if ($str.Extent.Text -cmatch 'FAIL(URE|ED|S)?\b') { return $true }
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# The analyzer. Returns one object per VIOLATION; an empty result is a clean
# file. `-Text` may be passed instead of `-Path` so the self-test can drive it
# from fixtures without writing them to disk.
# ---------------------------------------------------------------------------
function Get-VerdictExitFindings {
    param(
        [string]$Path,
        [string[]]$Text
    )
    $findings = New-Object System.Collections.ArrayList
    $lines = if ($null -ne $Text) { $Text } else { @(Get-Content -LiteralPath $Path) }

    # The stated-intent exemption, file-scope.
    foreach ($l in $lines) { if ($l -match '#\s*verdict-audit:') { return $findings } }

    $parsed = Get-VerdictAst -Path $Path -Text $Text
    if ($parsed.Errors.Count -gt 0) {
        [void]$findings.Add([pscustomobject]@{
            Path = $Path; Line = $parsed.Errors[0].Extent.StartLineNumber
            Kind = 'parse-error'; Detail = $parsed.Errors[0].Message })
        return $findings
    }

    # T271: a script whose verdict goes through `lib\TestScore.ps1` emits no
    # `ALL PASS` literal of its own, because the scorer owns the wording AND the
    # exit code - 0 only for a pass, 1 for failures, 2 for a run that asserted
    # nothing. Both directions of this rule hold by construction there, so the
    # shared scorer satisfies it rather than reading as `no-verdict`. The one
    # hole is `-NoExit`, which hands the code back to the caller: that shape must
    # still contain an `exit` somewhere.
    $scorerCalls = @($parsed.Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        ($n.GetCommandName() -eq 'Write-TestVerdict' -or
         $n.GetCommandName() -eq 'Write-TestAssertedNothing') }, $true))
    if ($scorerCalls.Count -gt 0) {
        $noExit = @($scorerCalls | Where-Object { $_.Extent.Text -match '-NoExit' })
        if ($noExit.Count -eq 0) { return $findings }
        $exits = @($parsed.Ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true))
        if ($exits.Count -gt 0) { return $findings }
        [void]$findings.Add([pscustomobject]@{
            Path = $Path; Line = $noExit[0].Extent.StartLineNumber; Kind = 'fallthrough'
            Detail = 'Write-TestVerdict -NoExit hands back the exit code and nothing exits with it' })
        return $findings
    }

    $site = Get-VerdictSite $parsed.Ast
    if ($null -eq $site) {
        [void]$findings.Add([pscustomobject]@{
            Path = $Path; Line = 1; Kind = 'no-verdict'
            Detail = 'no ALL PASS verdict is ever emitted' })
        return $findings
    }

    $if = Get-VerdictIf $site
    if ($null -eq $if) {
        [void]$findings.Add([pscustomobject]@{
            Path = $Path; Line = $site.Extent.StartLineNumber; Kind = 'fallthrough'
            Detail = 'the ALL PASS verdict is not in a branch, so there is no failure path to score' })
        return $findings
    }

    # Which branch holds the pass verdict, and what are the others?
    $split = Split-VerdictBranches $if $site
    $passBody = $split.PassBody
    $otherBodies = $split.OtherBodies
    $after = $split.After

    # --- the failure path -----------------------------------------------
    # A failure branch that does not exit falls out of the `if` and continues
    # into whatever follows it, which is exactly how the early-return shape
    # works. So: the branch's own exit if it has one, else the code after.
    $failStatements = New-Object System.Collections.ArrayList
    foreach ($b in $otherBodies) { foreach ($s in $b.Statements) { [void]$failStatements.Add($s) } }
    $branchExit = Get-FirstExit $failStatements
    $exit = if ($null -ne $branchExit) { $branchExit } else { Get-FirstExit $after }

    if ($null -eq $exit) {
        [void]$findings.Add([pscustomobject]@{
            Path = $Path; Line = $if.Extent.StartLineNumber; Kind = 'fallthrough'
            Detail = 'the failure path falls off the end of the script, leaving $LASTEXITCODE at 0' })
    } elseif ((Get-ExitKind $exit) -eq 'zero') {
        [void]$findings.Add([pscustomobject]@{
            Path = $Path; Line = $exit.Extent.StartLineNumber; Kind = 'exits-zero'
            Detail = "the failure path exits 0: $($exit.Extent.Text)" })
    }

    # --- the pass path --------------------------------------------------
    # Only the early-return shape can get this wrong: if the pass branch does
    # not terminate and the code after the `if` announces failure, a GREEN run
    # prints FAILURE(S). A shared computed exit after an if/else (crash-stacks,
    # skip-visibility) prints nothing, so it is not this.
    if ($null -ne $passBody) {
        $passExit = Get-FirstExit $passBody.Statements
        if ($null -eq $passExit -and (Test-EmitsFailureVerdict $after)) {
            [void]$findings.Add([pscustomobject]@{
                Path = $Path; Line = $if.Extent.StartLineNumber; Kind = 'pass-falls-through'
                Detail = 'the pass branch does not exit, so a green run falls into the failure verdict' })
        }
    }

    return $findings
}

# Sweep the acceptance scripts. NOT recursive, and that is the rule rather than
# an oversight: an acceptance script is a top-level file in `test\win32`, while
# `lib\` holds dot-sourced libraries and `artifacts\` holds fixtures. Neither
# has a verdict to score, so recursing would report `no-verdict` against fifteen
# files that are correct - a sweep that cries wolf is a sweep nobody reads.
#
# `scripts\` is not swept for the same reason, and was checked by hand instead
# (T221, 2026-08-11): exactly two files there mention `ALL PASS`, and only
# `floor-lane.ps1` emits one as its own verdict - correctly, with a nonzero exit
# on failure. The rest of `scripts\` is tools, so a blanket sweep would be 60
# `no-verdict` findings about files that were never supposed to have one. If a
# second verdict-emitting tool ever lands there, point this at it explicitly
# rather than widening the root.
function Get-VerdictExitSweep([string]$Root) {
    $all = New-Object System.Collections.ArrayList
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Filter *.ps1 -File)) {
        foreach ($x in @(Get-VerdictExitFindings -Path $f.FullName)) { [void]$all.Add($x) }
    }
    return $all
}
