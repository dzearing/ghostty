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
# THE RULE (widened by T276):
#
#     A script under `test\win32\` that can only run on the INPUT DESKTOP must
#     be DECLARED as interactive-by-design in `lib\TestDesktop.ps1`'s header.
#     An undeclared site is a miss.
#
# Being un-runnable in the loop is the property that matters; stealing focus is
# one cause of it, not the definition of it. T272 wrote the rule as "takes the
# foreground" and its sweep therefore could not see `color-contrast.ps1`, which
# calls neither `SendInput` nor `SetForegroundWindow` and was nonetheless
# input-desktop-only: it read the COMPOSITED SCREEN with `GetDC(NULL)` +
# `GetPixel`, and DWM composes only the input desktop. `split-dim.ps1` used the
# same mechanism and made T272's list only because it ALSO grabbed foreground -
# luck, not coverage. So two families of site count, and they share one
# declaration list because they are one exemption:
#
#   * INJECTION / FOREGROUND  - `Get-ForegroundAuditApis`.
#   * SCREEN-DC PROBES        - `Get-ForegroundAuditScreenDcApis`: a read of the
#                               composited screen rather than of a named window
#                               (`CopyFromScreen`, `GetDC`/`GetWindowDC`/
#                               `Graphics.FromHwnd` on a NULL or desktop hwnd).
#
# WHERE A PROBE READS IS NOT WHAT IT READS (the classification rule T225
# measured). `split-dim`'s probe was carried as a terminal-content probe by
# three task files because it sampled a point that lay OVER the terminal; what
# it actually sampled was a layered window in front of it. The question is
# always which window's painter owns those pixels - and a screen DC is exactly
# the mechanism that makes that unanswerable by inspection, because a window
# capture names its target while a screen DC names a point. That is the second
# reason to flag one, beyond the desktop it needs.
#
# What the screen-DC detector cannot see, stated rather than implied: a null
# handle that arrives through a VARIABLE (`$screen = [IntPtr]::Zero;
# GetDC($screen)`) is invisible to a textual rule, as is a P/Invoke declaration
# whose parameter is only ever filled at runtime. The literal call sites are
# what every screen probe in this suite has ever used, and the teeth check
# plants one of those.
#
# It also cannot see the difference between a call and a STRING that spells one,
# and that is not fixable by excluding string tokens: the P/Invoke declarations
# this whole check exists to find live inside `Add-Type` here-strings, which are
# string tokens. A file whose subject is these APIs therefore carries the
# `# foreground-audit:` marker below rather than a narrower pattern.
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
# WHAT COUNTS AS A SITE. Live code only: a token that is not a PowerShell
# comment, and not a `//` or `/* */` comment inside an embedded C# here-string.
# Two thirds of the suite MENTIONS `SendInput` - in a header explaining that it
# is dead on a background desktop - and reading those as violations would push
# 22 innocent scripts onto the exception list, which is the same rot from the
# other direction. That is not hypothetical for the screen-DC family either:
# eleven scripts name `CopyFromScreen` in a header saying it is dead there, and
# exactly one calls it. Three shapes count:
#
#   1. One of the watched user32 entry points (`Get-ForegroundAuditApis`) in
#      live code, including inside an `Add-Type` here-string, which is where the
#      P/Invoke declarations actually live.
#   1b. A screen-DC read (`Get-ForegroundAuditScreenDcPattern`) in live code.
#      The NULL is load-bearing: `GetDC($hwnd)` is a window DC and is not a
#      finding, so a P/Invoke DECLARATION (`extern IntPtr GetDC(IntPtr hWnd)`)
#      never trips this - only a call site that names the screen does.
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
# finds ZERO sites - re-measured the same day with the widened screen-DC family
# (29 files, still zero). Those are tools the user RUNS - a launcher that raises
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

# The screen-DC family (T276): a read of the COMPOSITED SCREEN rather than of a
# named window. Dead off the input desktop - DWM composes only that one - and
# unable to say which window's painter owns the pixels it returns. Reported for
# documentation; the pattern below is what actually matches.
function Get-ForegroundAuditScreenDcApis {
    return @(
        'CopyFromScreen'
        'GetDC(NULL)'
        'GetWindowDC(NULL)'
        'Graphics.FromHwnd(NULL)'
    )
}

function Get-ForegroundAuditScreenDcPattern {
    # A null-ish hwnd, in every spelling this suite writes: PowerShell
    # (`[IntPtr]::Zero`), C# inside an Add-Type here-string (`IntPtr.Zero`,
    # `(IntPtr)0`), a bare `0`, and the desktop window itself.
    # `[\w.\[\]:]*` lets the desktop-window call carry its own qualifier -
    # `[Drv]::GetDesktopWindow()` in PowerShell, `Native.GetDesktopWindow()` in
    # an embedded C# body - without which the one spelling a script would
    # actually write is the one that slips through.
    $nul = '(?:\[IntPtr\]::Zero|IntPtr\.Zero|\(\s*IntPtr\s*\)\s*0|0|null|NULL|' +
           '[\w.\[\]:]*GetDesktopWindow\s*\(\s*\))'
    return '\bCopyFromScreen\b|\b(?:GetDC|GetWindowDC|FromHwnd)\s*\(\s*' + $nul + '\s*\)'
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

# The same erasure, LENGTH-PRESERVING: every removed character becomes a space
# and every newline survives, so offsets into the scrubbed text still name the
# line they came from. The screen-DC pass needs this and the foreground pass
# does not, because a screen-DC call site spans SEVERAL PowerShell tokens
# (`[Drv]`, `::`, `GetDC`, `(`, `[IntPtr]`, `::`, `Zero`, `)`) while every
# watched user32 name is one identifier token on its own.
function Hide-ForegroundAuditSpan([string]$Text, [int]$Start, [int]$Length) {
    $sb = New-Object System.Text.StringBuilder $Text
    for ($i = $Start; $i -lt ($Start + $Length) -and $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($c -ne "`n" -and $c -ne "`r") { [void]$sb.Replace($c, ' ', $i, 1) }
    }
    return $sb.ToString()
}

function Get-ForegroundAuditLiveText([string]$Source, $Tokens) {
    $t = $Source
    foreach ($tok in $Tokens) {
        if ($tok.Kind -ne 'Comment') { continue }
        $t = Hide-ForegroundAuditSpan $t $tok.Extent.StartOffset `
            ($tok.Extent.EndOffset - $tok.Extent.StartOffset)
    }
    # C# comments inside an Add-Type here-string, blanked in place for the same
    # reason. `(?<!:)` keeps a URL from eating the rest of its line.
    foreach ($rx in @('/\*[\s\S]*?\*/', '(?<!:)//[^\r\n]*')) {
        foreach ($m in @([regex]::Matches($t, $rx))) {
            $t = Hide-ForegroundAuditSpan $t $m.Index $m.Length
        }
    }
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
    # Parse the source string we hold, never the file directly, so token offsets
    # index the same string the screen-DC pass scrubs and scans.
    $src = if ($null -ne $Text) { $Text -join "`n" } else { Get-Content -Raw -LiteralPath $Path }
    if ($null -eq $src) { $src = '' }
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $src, [ref]$tokens, [ref]$errors)

    # Family 1 - one identifier, one token.
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
                Line   = $line
                What   = $m.Value
                Family = 'foreground'
            })
        }
    }

    # Family 2 - a call site that spans tokens, so it is matched over the whole
    # source with the comments blanked out rather than token by token.
    $live = Get-ForegroundAuditLiveText $src $tokens
    foreach ($m in [regex]::Matches($live, (Get-ForegroundAuditScreenDcPattern))) {
        $line = 1 + ([regex]::Matches($live.Substring(0, $m.Index), "`n")).Count
        [void]$sites.Add([pscustomobject]@{
            Line   = $line
            What   = ($m.Value -replace '\s+', '')
            Family = 'screen-dc'
        })
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
                    Line   = $el.Extent.StartLineNumber
                    What   = 'New-TestDesktop -Interactive'
                    Family = 'foreground'
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
            # Two patterns run over each token, so appended order is not line
            # order; point the finding at the earliest site so it is something
            # you can go and read.
            $first = @($sites | Sort-Object Line)[0]
            $how = if ($first.Family -eq 'screen-dc') {
                "reads the composited screen ($($first.What)), which only exists on the input desktop"
            } else {
                "takes the input desktop ($($first.What))"
            }
            [void]$findings.Add([pscustomobject]@{
                Path = $f; Line = $first.Line; Kind = 'undeclared'
                Detail = "$how and is not declared in lib\TestDesktop.ps1" })
        }
    }

    foreach ($d in $good) {
        if ($grabbers.ContainsKey($d.Script)) { continue }
        $exists = $null -ne ($Files | Where-Object { (Split-Path $_ -Leaf) -eq $d.Script })
        $why = if ($exists) { 'no longer needs the input desktop' } else { 'no longer exists' }
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
