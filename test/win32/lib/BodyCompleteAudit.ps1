# BodyCompleteAudit (T1039) - find the scripts whose run can UNWIND and still
# reach a green verdict.
#
# The runtime half of this rule is `lib\TestScore.ps1` (the body-completion
# marker, and `Write-TestVerdict` refusing a pass without it). This is the
# static half: the sweep that says whether any script still has a path around
# it, and - because the marker only works where it is PLACED correctly - the
# only thing that can tell a marker that proves something from one that does
# not.
#
# The shape, measured in T329 on `activity-monitor-dialed.ps1`: a top-level
#
#     try { ...the whole run... } finally { ...cleanup... }
#
# with no `catch`. A statement-terminating error inside it unwinds the try under
# `$ErrorActionPreference = 'Continue'`, runs the finally, and then falls
# through to the statements after it - the guard stamp and the verdict - with
# the failure count untouched. 95 of the 155 scripts in this suite were in that
# exact shape.
#
# THE RULE, in the form this file checks:
#
#     Every top-level `try` in a scored script either SCORES ITS OWN THROW in a
#     `catch`, or ENDS in `Complete-TestBody`. And every scored script marks
#     completion somewhere, or its green verdict is unreachable.
#
# Both halves are the same statement seen from two sides: a run may not arrive
# at a pass verdict along a path that skipped part of the body.
#
# Findings:
#
#   * `missing`      - a scored script with no top-level `Complete-TestBody`
#                      call at all. Its ALL PASS is now unreachable (every run
#                      would print RUN DID NOT FINISH), so this is a broken
#                      script rather than a risky one - loud on the first run.
#   * `uncaught-try`  - a top-level `try` with no `catch` whose body does not END
#                      with `Complete-TestBody`. The defect itself: an unwind
#                      here skips the rest of the body and lands on the verdict.
#   * `silent-catch` - a top-level `try` whose `catch` neither scores a failure,
#                      rethrows, nor ends the run. It swallows the throw, which
#                      is the same green-over-nothing with an extra step.
#   * `parse-error`  - the file does not parse; nothing can be claimed about it.
#
# Only a MEASURED try is judged: one whose body can lose assertions if it
# unwinds. `try { $x = [int]$raw } catch { $x = 0 }` at the top level of a
# script is a guarded expression rather than the run, and six of them in this
# suite were the first sweep's entire "silent-catch" list. What counts as
# measuring is derived per file from what its own helpers DO to a pass/fail/skip
# counter, not from a list of names this suite does not share.
#
# Scope: only files that dot-source `lib\TestScore.ps1`, because only those are
# scored by the marker. The other ~175 scripts in this suite hand-roll their
# verdict and are outside this rule until T775 converts them - stating that
# plainly is better than a sweep that quietly covers a third of the suite.
#
# Exemption, narrow and stated: a `# body-audit: <reason>` marker anywhere in
# the file, the same state-your-intent convention the `# persistence:`,
# `# exitcode-audit:`, `# skip-audit:`, `# verdict-audit:` and
# `# asserted-nothing-audit:` markers use.
#
# This reads the AST rather than the text, and here that is not a preference:
# "the last statement of the try body" and "at the top level rather than inside
# a function" are structural questions that no regex answers. Helper names are
# kept distinct from the sibling audits' on purpose - several of them are
# dot-sourced into the same acceptance script.

# Deliberately sets no StrictMode: this file is dot-sourced INTO suite scripts,
# and a mode set here would silently change how every one of them evaluates.

function Get-BodyAst {
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

# The script's own statements: the end block, minus anything nested inside a
# function definition. A `try` inside a helper function is that function's
# business - it cannot skip the verdict, because the verdict is not in it.
function Get-BodyTopLevelStatements($Ast) {
    if ($null -eq $Ast.EndBlock) { return @() }
    return @($Ast.EndBlock.Statements)
}

function Get-BodyTopLevelTries($Ast) {
    return @(Get-BodyTopLevelStatements $Ast |
        Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] })
}

# Which of this file's own functions MEASURE something? Every script here names
# its assertion helper differently (`Assert`, `AssertEq`, `Ok`, `Check`, `Skip`,
# `Assert-GhozttyIsolated`), so the helper is found by what it does rather than
# by what it is called: it moves a pass/fail/skip counter, or it calls something
# that does. Computed to a fixed point, so a section written as
# `try { Run-SectionA } finally { }` is seen for what it is.
function Get-BodyMeasuringFunctions($Ast) {
    $funcs = @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
    $names = @($funcs | ForEach-Object { $_.Name })
    $measuring = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)

    foreach ($f in $funcs) {
        if (Test-BodyCountsSomething $f.Body) { [void]$measuring.Add($f.Name) }
    }
    # Fixed point: a wrapper around a measuring helper measures too.
    for ($i = 0; $i -lt $names.Count; $i++) {
        $grew = $false
        foreach ($f in $funcs) {
            if ($measuring.Contains($f.Name)) { continue }
            if (Test-BodyCallsAny -Node $f.Body -Names $measuring) {
                [void]$measuring.Add($f.Name); $grew = $true
            }
        }
        if (-not $grew) { break }
    }
    return $measuring
}

# A counter move: `$script:pass++`, `$fail += 1`, `$script:skipped = $skipped + 1`.
function Test-BodyCountsSomething($Node) {
    $t = $Node.Extent.Text
    return ($t -match '(?i)\$(script:|global:)?\w*(pass|fail|skip)\w*\s*(\+\+|\+=)')
}

function Test-BodyCallsAny($Node, $Names) {
    if ($Names.Count -eq 0) { return $false }
    foreach ($c in @($Node.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
        $name = $c.GetCommandName()
        if ($name -and $Names.Contains($name)) { return $true }
    }
    return $false
}

# Is this try one that MEASURES - i.e. can an unwind of it lose assertions? A
# `try { $x = [int]$raw } catch { $x = 0 }` at the top level of a script is a
# guarded expression, not the run: nothing inside it is scored, so nothing is
# lost when it throws, and reporting it would bury the real finding in noise.
function Test-BodyTryIsMeasured($Try, $Measuring) {
    if (Test-BodyCountsSomething $Try.Body) { return $true }
    return (Test-BodyCallsAny -Node $Try.Body -Names $Measuring)
}

function Test-BodyCompleteCall($Statement) {
    if ($null -eq $Statement) { return $false }
    if ($Statement -isnot [System.Management.Automation.Language.PipelineAst]) { return $false }
    $elements = @($Statement.PipelineElements)
    if ($elements.Count -ne 1) { return $false }
    $cmd = $elements[0]
    if ($cmd -isnot [System.Management.Automation.Language.CommandAst]) { return $false }
    return ($cmd.GetCommandName() -eq 'Complete-TestBody')
}

# Does this `catch` do anything with the throw it caught? A catch that scores a
# failure, rethrows, or ends the run is an honest arm; one that does none of
# those has silently turned a defect into a pass. Read as text on purpose - the
# failure counter is named differently in nearly every script here
# (`$script:fail`, `$script:failures`, `$fails`), and what matters is that the
# arm reaches for one at all.
function Test-BodyCatchScores($CatchClause) {
    $t = $CatchClause.Body.Extent.Text
    if ($t -match '(?i)\bfail') { return $true }
    if ($t -match '(?i)\bthrow\b') { return $true }
    if ($t -match '(?i)Write-TestVerdict') { return $true }
    if ($t -match '(?i)\bexit\b') { return $true }
    return $false
}

# ---------------------------------------------------------------------------
# The analyzer. One object per finding; an empty result is a clean file.
# `-Text` may be passed instead of `-Path` so the acceptance script drives it
# from fixtures without writing them to disk.
# ---------------------------------------------------------------------------
function Get-BodyCompleteFindings {
    param(
        [string]$Path,
        [string[]]$Text
    )
    $findings = New-Object System.Collections.ArrayList
    $lines = if ($null -ne $Text) { $Text } else { @(Get-Content -LiteralPath $Path) }

    $scored = $false
    foreach ($l in $lines) {
        if ($l -match '#\s*body-audit:') { return $findings }
        if ($l -match 'TestScore\.ps1') { $scored = $true }
    }
    # Not scored by the shared scorer => this rule has nothing to say about it.
    if (-not $scored) { return $findings }

    $parsed = Get-BodyAst -Path $Path -Text $Text
    if ($parsed.Errors.Count -gt 0) {
        [void]$findings.Add([pscustomobject]@{
            Path = $Path; Line = $parsed.Errors[0].Extent.StartLineNumber
            Kind = 'parse-error'; Detail = $parsed.Errors[0].Message })
        return $findings
    }

    $top = Get-BodyTopLevelStatements $parsed.Ast
    $measuring = Get-BodyMeasuringFunctions $parsed.Ast
    $allTries = @(Get-BodyTopLevelTries $parsed.Ast)
    $tries = @($allTries | Where-Object { Test-BodyTryIsMeasured -Try $_ -Measuring $measuring })

    foreach ($t in $tries) {
        $body = @($t.Body.Statements)
        $last = if ($body.Count -gt 0) { $body[-1] } else { $null }
        $ends = Test-BodyCompleteCall $last
        $catches = @($t.CatchClauses)

        if ($catches.Count -eq 0) {
            if (-not $ends) {
                [void]$findings.Add([pscustomobject]@{
                    Path = $Path; Line = $t.Extent.StartLineNumber; Kind = 'uncaught-try'
                    Detail = "a top-level try with no catch whose body does not end in Complete-TestBody: an unwind here skips the rest of the run and still reaches the verdict" })
            }
            continue
        }

        foreach ($c in $catches) {
            if (-not (Test-BodyCatchScores $c)) {
                [void]$findings.Add([pscustomobject]@{
                    Path = $Path; Line = $c.Extent.StartLineNumber; Kind = 'silent-catch'
                    Detail = "a top-level catch that neither scores a failure, rethrows, nor ends the run: the throw is swallowed and the verdict stays green" })
            }
        }
    }

    # The marker itself, anywhere the script's own flow reaches it: the last
    # statement of a top-level try body, or a top-level statement of its own.
    $marked = $false
    foreach ($s in $top) { if (Test-BodyCompleteCall $s) { $marked = $true } }
    foreach ($t in $allTries) {
        $body = @($t.Body.Statements)
        if ($body.Count -gt 0 -and (Test-BodyCompleteCall $body[-1])) { $marked = $true }
    }
    if (-not $marked) {
        [void]$findings.Add([pscustomobject]@{
            Path = $Path; Line = 1; Kind = 'missing'
            Detail = "a script scored by lib\TestScore.ps1 with no Complete-TestBody call: every run of it now ends in RUN DID NOT FINISH" })
    }

    return $findings
}

# Every kind here is the defect. There is no reported-but-not-enforced kind:
# this rule arrived with its suite already converted, so a finding is a
# regression rather than a backlog.
function Get-BodyCompleteHardKinds { return @('missing', 'uncaught-try', 'silent-catch', 'parse-error') }

# Sweep the acceptance scripts. NOT recursive, for the reason its sibling audits
# are not: an acceptance script is a top-level file in `test\win32`, while
# `lib\` holds dot-sourced libraries with no run of their own to finish.
function Get-BodyCompleteSweep([string]$Root) {
    $all = New-Object System.Collections.ArrayList
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Filter *.ps1 -File)) {
        foreach ($x in @(Get-BodyCompleteFindings -Path $f.FullName)) { [void]$all.Add($x) }
    }
    return $all
}
