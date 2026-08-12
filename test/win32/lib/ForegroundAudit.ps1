# ForegroundAudit (T272) - find the acceptance scripts that can still take the
# user's foreground, and keep the interactive-by-design exceptions DECLARED.
#
# T211-T218 moved the GUI suite onto a background desktop (`lib\TestDesktop.ps1`)
# because the user's complaint was that a test run kept stealing their focus.
# T217 closed at 23 of 23 and T218 at 13 of 13, and the fleet-wide claim became
# "the acceptance scripts no longer steal the user's foreground". A later sweep
# found two scripts (`overlay-zorder.ps1`, `split-dim.ps1`) in neither bucket,
# still grabbing - nothing had counted the remainder, so nothing said so. They
# were migrated by T224/T225; this file is what stops the property regrowing.
#
# THE RULE:
#
#     A script under `test\win32\` that injects input or takes the foreground
#     must be DECLARED as interactive-by-design in `lib\TestDesktop.ps1`'s
#     header. An undeclared grab site is a miss.
#
# The declaration and the check are deliberately the same list: an exception
# nobody wrote down is indistinguishable from an oversight, which is exactly how
# those two scripts went quiet. The list lives in the harness header - where a
# reader meets the `-Interactive` escape hatch - and is PARSED from there rather
# than restated here, so the prose a human reads and the set the check enforces
# cannot drift apart.
#
# Declaration grammar, one entry per line, anywhere in `lib\TestDesktop.ps1`:
#
#     # @input-desktop-exception: <script>.ps1 -- <one-line reason>
#
# Three finding kinds, all of them the defect, all enforced at zero:
#
#   * `undeclared`            - a live grab site in a script that is not on the
#                               list. File the migration, or declare it.
#   * `stale-declaration`     - a declared script that no longer grabs (or no
#                               longer exists). A list naming scripts that do not
#                               need naming is how a real miss gets waved through.
#   * `malformed-declaration` - a marker line the parser could not read, or a
#                               header with no declarations at all. A list that
#                               silently evaporates would turn every violation
#                               into a pass.
#
# The declaration list is how an INTERACTIVE script is exempted, and it is the
# only way: a grab that is not on it is a finding, full stop. There is a second,
# narrower marker for a different thing - a file that NAMES these APIs without
# calling them:
#
#     # foreground-audit: <reason>
#
# the same state-your-intent convention the `# persistence:`, `# exitcode-audit:`,
# `# skip-audit:`, `# verdict-audit:` and `# asserted-nothing-audit:` markers
# use. Today it is carried by exactly one file, this rule's own acceptance
# script, whose fixtures are string literals holding the very P/Invokes it
# detects. It is NOT an alternative to declaring an interactive script: a marked
# file must still not take the foreground, and the reason has to say why it
# cannot.
#
# WHAT COUNTS AS A GRAB SITE. Live code only: a token that is not a PowerShell
# comment, and not a `//` or `/* */` comment inside an embedded C# here-string.
# Two thirds of the suite MENTIONS `SendInput` - in a header explaining that it
# is dead on a background desktop - and reading those as violations would push
# 22 innocent scripts onto the exception list, which is the same rot from the
# other direction. Two shapes count:
#
#   1. One of the watched user32 entry points (`Get-ForegroundAuditApis`) in
#      live code, including inside an `Add-Type` here-string, which is where the
#      P/Invoke declarations actually live.
#   2. `New-TestDesktop -Interactive` hardcoded. The hatch skips the desktop
#      entirely and drives the app the old way; the header says it is "for
#      debugging by hand only ... never how an acceptance run is scored", and a
#      script that pins it on is a foreground grab with no P/Invoke in it.
#      `-Interactive:$Interactive` is the normal forwarding of a debug switch
#      and is not a finding.
#
# Sweep is NOT recursive, for the reason the sibling audits are not: an
# acceptance script is a top-level file in `test\win32`, while `lib\` holds the
# harness itself - `TestDesktop.ps1` owns the interactive hatch and therefore
# owns a legitimate `SendInput`.
#
# `scripts\` is out of scope on purpose, and the scope was measured rather than
# assumed: run over `scripts\*.ps1` + `scripts\lib\*.ps1` on 2026-08-11 this
# finds ZERO grab sites. Those are tools the user RUNS - a launcher that raises
# the window it just started is doing its job - so the rule "declare it or it is
# a miss" does not transfer, and widening the sweep would mean writing a second
# policy for a set that is currently empty.
#
# Acceptance: `test\win32\foreground-audit.ps1` (analyzer both directions, the
# live sweep, and a `-TeethCheck` that plants a real violator in the swept
# directory and requires the sweep to find it).

# Deliberately sets no StrictMode: this file is dot-sourced INTO suite scripts,
# and a mode set here would silently change how every one of them evaluates.

# The user32 entry points that take the input desktop. Injection and foreground
# theft both, because a script that only moves the cursor has still reached out
# of its sandbox and onto the user's screen.
function Get-ForegroundAuditApis {
    return @(
        'SendInput'
        'SetForegroundWindow'
        'keybd_event'
        'mouse_event'
        'SetCursorPos'
        'SwitchToThisWindow'
    )
}

function Get-ForegroundAuditPattern {
    return '\b(' + ((Get-ForegroundAuditApis) -join '|') + ')\b'
}

# Strip the comments an embedded C# body can carry, so a `// SendInput is dead
# here` note inside an Add-Type here-string is not read as a call.
function Remove-ForegroundAuditEmbeddedComments([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = [regex]::Replace($Text, '/\*.*?\*/', '', 'Singleline')
    # Not http:// - a URL is not a comment, and eating one would hide a match
    # that follows it on the same line.
    $t = [regex]::Replace($t, '(?<!:)//[^\r\n]*', '')
    return $t
}

# ---------------------------------------------------------------------------
# The declaration list, parsed out of the harness header.
# ---------------------------------------------------------------------------
function Get-ForegroundAuditDeclarations {
    <#
      Returns one object per marker line: Script, Reason, Line, Malformed.
      `-Text` may be passed instead of `-Path` so the acceptance script can drive
      the parser from fixtures without writing a harness to disk.
    #>
    param(
        [string]$Path,
        [string[]]$Text
    )
    $lines = if ($null -ne $Text) { $Text } else { @(Get-Content -LiteralPath $Path) }
    $out = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -notmatch '@input-desktop-exception:') { continue }
        $rest = ($l -split '@input-desktop-exception:', 2)[1]
        if ($rest -match '^\s*(?<s>[A-Za-z0-9._\-]+\.ps1)\s+--\s+(?<r>\S.*)$') {
            [void]$out.Add([pscustomobject]@{
                Script    = $Matches['s'].Trim()
                Reason    = $Matches['r'].Trim()
                Line      = $i + 1
                Malformed = $false
            })
        } else {
            [void]$out.Add([pscustomobject]@{
                Script    = ''
                Reason    = $rest.Trim()
                Line      = $i + 1
                Malformed = $true
            })
        }
    }
    return $out
}

# A file that NAMES the watched APIs without calling them - see the header. The
# marker is read off the raw lines rather than the AST, so a file can carry it
# in its comment-based help as well as in a plain comment.
function Test-ForegroundAuditExempt {
    param(
        [string]$Path,
        [string[]]$Text
    )
    $lines = if ($null -ne $Text) { $Text } else { @(Get-Content -LiteralPath $Path) }
    foreach ($l in $lines) { if ($l -match '#\s*foreground-audit:') { return $true } }
    return $false
}

# ---------------------------------------------------------------------------
# Grab sites in one script.
# ---------------------------------------------------------------------------
function Get-ForegroundAuditSites {
    param(
        [string]$Path,
        [string[]]$Text
    )
    $sites = New-Object System.Collections.ArrayList
    $tokens = $null
    $errors = $null
    if ($null -ne $Text) {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            ($Text -join "`n"), [ref]$tokens, [ref]$errors)
    } else {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref]$tokens, [ref]$errors)
    }

    $pattern = Get-ForegroundAuditPattern
    foreach ($tok in $tokens) {
        if ($tok.Kind -eq 'Comment') { continue }
        $body = Remove-ForegroundAuditEmbeddedComments $tok.Text
        foreach ($m in [regex]::Matches($body, $pattern)) {
            # A here-string starts many lines above its match; report where the
            # call actually is, so the finding is something you can go and read.
            $before = $body.Substring(0, $m.Index)
            $line = $tok.Extent.StartLineNumber +
                ([regex]::Matches($before, "`n")).Count
            [void]$sites.Add([pscustomobject]@{
                Line = $line
                What = $m.Value
            })
        }
    }

    foreach ($cmd in @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
        if ($cmd.GetCommandName() -ne 'New-TestDesktop') { continue }
        foreach ($el in $cmd.CommandElements) {
            if ($el -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            if ($el.ParameterName -ne 'Interactive') { continue }
            $arg = $el.Argument
            $hardcoded = $false
            if ($null -eq $arg) { $hardcoded = $true }
            elseif ($arg -is [System.Management.Automation.Language.VariableExpressionAst]) {
                # `-Interactive:$true` pins it; `-Interactive:$Interactive` forwards.
                if ($arg.VariablePath.UserPath -eq 'true') { $hardcoded = $true }
            } elseif ($arg -is [System.Management.Automation.Language.ConstantExpressionAst]) {
                if ("$($arg.Value)" -eq '1' -or "$($arg.Value)" -eq 'True') { $hardcoded = $true }
            }
            if ($hardcoded) {
                [void]$sites.Add([pscustomobject]@{
                    Line = $el.Extent.StartLineNumber
                    What = 'New-TestDesktop -Interactive'
                })
            }
        }
    }

    return $sites
}

# ---------------------------------------------------------------------------
# The analyzer. One object per finding; an empty result is a clean suite.
# ---------------------------------------------------------------------------
function Get-ForegroundAuditFindings {
    <#
      -Files       the scripts to score (paths). Defaults to `$Root\*.ps1`.
      -Root        the acceptance directory (`test\win32`).
      -Declared    override the declaration list, for the self-test.
    #>
    param(
        [string]$Root,
        [string[]]$Files,
        [object[]]$Declared
    )
    $findings = New-Object System.Collections.ArrayList

    if ($null -eq $Declared) {
        $harness = Join-Path $Root 'lib\TestDesktop.ps1'
        if (-not (Test-Path -LiteralPath $harness)) {
            [void]$findings.Add([pscustomobject]@{
                Path = $harness; Line = 0; Kind = 'malformed-declaration'
                Detail = 'the harness that holds the declaration list is missing' })
            return $findings
        }
        $Declared = @(Get-ForegroundAuditDeclarations -Path $harness)
    }
    $Declared = @($Declared)

    foreach ($d in ($Declared | Where-Object { $_.Malformed })) {
        [void]$findings.Add([pscustomobject]@{
            Path = 'lib\TestDesktop.ps1'; Line = $d.Line; Kind = 'malformed-declaration'
            Detail = "cannot read this declaration; expected '<script>.ps1 -- <reason>', got '$($d.Reason)'" })
    }
    $good = @($Declared | Where-Object { -not $_.Malformed })
    if ($good.Count -eq 0) {
        [void]$findings.Add([pscustomobject]@{
            Path = 'lib\TestDesktop.ps1'; Line = 0; Kind = 'malformed-declaration'
            Detail = 'the declaration list is empty - every grab site would read as undeclared' })
    }

    if ($null -eq $Files) {
        $Files = @(Get-ChildItem -LiteralPath $Root -Filter *.ps1 -File |
            ForEach-Object { $_.FullName })
    }

    $grabbers = @{}
    foreach ($f in $Files) {
        $name = Split-Path $f -Leaf
        if (Test-ForegroundAuditExempt -Path $f) { continue }
        $sites = @(Get-ForegroundAuditSites -Path $f)
        if ($sites.Count -eq 0) { continue }
        $grabbers[$name] = $sites
        $decl = @($good | Where-Object { $_.Script -eq $name })
        if ($decl.Count -eq 0) {
            $first = $sites[0]
            [void]$findings.Add([pscustomobject]@{
                Path = $f; Line = $first.Line; Kind = 'undeclared'
                Detail = "takes the input desktop ($($first.What)) and is not declared in lib\TestDesktop.ps1" })
        }
    }

    foreach ($d in $good) {
        if ($grabbers.ContainsKey($d.Script)) { continue }
        $exists = $null -ne ($Files | Where-Object { (Split-Path $_ -Leaf) -eq $d.Script })
        $why = if ($exists) { 'no longer takes the input desktop' } else { 'no longer exists' }
        [void]$findings.Add([pscustomobject]@{
            Path = 'lib\TestDesktop.ps1'; Line = $d.Line; Kind = 'stale-declaration'
            Detail = "$($d.Script) is declared interactive-by-design but $why" })
    }

    return $findings
}

# Every kind is the defect here - there is no reported-but-unenforced tier.
function Get-ForegroundAuditHardKinds {
    return @('undeclared', 'stale-declaration', 'malformed-declaration')
}

function Get-ForegroundAuditSweep([string]$Root) {
    return @(Get-ForegroundAuditFindings -Root $Root)
}
