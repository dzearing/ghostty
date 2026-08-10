# PersistenceSweep.ps1 - T158. Enumerate every launch of the app under test in
# test\win32 and answer, per site, whether that launch STATES what it wants
# session persistence to do.
#
# WHY THIS EXISTS
#
# Session persistence is ON by default, so a GUI launched without
# `--session-persistence=false` restores whatever panes the last launch left
# behind - and then the script's own setup assertions describe someone else's
# layout. It is not a stale-box problem that a clean machine fixes: each section
# of a script writes the manifest the NEXT section restores, so a script poisons
# itself on its second launch. T131 hit it in pane-banner.ps1; T155 hit it again
# in split-dim.ps1 and split-zoom-nav.ps1, where both scripts failed
# `default setup: 2 visible panes` against a build whose geometry was
# independently verified correct. The failure presents as a product regression in
# whatever change happens to be in flight, which is what makes it expensive.
#
# WHY A SWEEP AND NOT A LINT FOR "THE FLAG IS MISSING"
#
# Roughly a third of the suite WANTS persistence on - the session-*, agent-* and
# chooser-* families, plus anything whose subject is restore. For them the flag's
# absence is the fixture, not an oversight. So the checkable property is not
# "every launch passes the flag"; it is "every launch DECLARES its intent", which
# a reader (and this sweep) can tell apart from a launch that never considered
# the question. Three ways to declare, in descending order of preference:
#
#   1. pass `--session-persistence=false` (or `=true`/`=on`/`=off`) in the
#      launch statement itself;
#   2. pass it through a variable or splat built in the same file - the sweep
#      resolves those definitions;
#   3. write a `# persistence: <reason>` marker on the launch statement or in
#      the six lines above it, for a site where neither fits: a CLI invocation
#      that opens no window, a launch into a throwaway `$env:LOCALAPPDATA` where
#      there is no shared manifest to restore from, or a helper whose callers
#      each pass their own choice.
#
# The marker is a comment, so a site can be declared without touching behavior -
# which is the whole reason this is a static sweep rather than a runtime guard in
# Start-OnTestDesktop. A runtime guard would force ~60 live edits into the
# session/agent family to say what they already do, and every one of those would
# need re-validating to prove it changed nothing.
#
# Usage:
#
#     . (Join-Path $PSScriptRoot 'lib\PersistenceSweep.ps1')
#     $sites = Get-GhozttyLaunchSites -Root (Join-Path $PSScriptRoot '..')
#     $sites | Where-Object { -not $_.Declared }

Set-StrictMode -Off

# How far after a variable's assignment we look for the flag. A launch-argument
# array is written near its own `$x = @(` line; 800 characters covers the long
# multi-line ones in this suite without reaching the next assignment.
$script:PersistenceVarWindow = 800

# The flag, WITH a value the CLI actually accepts. `parseBool`
# (src/cli/args.zig) takes 1/t/T/true/on/yes and 0/f/F/false/off/no and nothing
# else; anything else is an InvalidValue that is logged and dropped, leaving the
# setting at its default. So a site spelling `--session-persistence=nope` has
# not declared anything - it has written a launch that LOOKS explicit and still
# restores. (`on`/`off`/`yes`/`no` were only added to that list on 2026-08-04,
# in 8f7af4466; a comment in the suite still says they are rejected.)
$script:PersistenceFlagPattern = '--session-persistence=(1|t|T|true|on|yes|0|f|F|false|off|no)(\b|$|[''"])'

# Lines above a launch statement that a `# persistence:` marker may sit on. Six
# is enough for a marker written above a short comment block explaining the
# launch, and short enough that it cannot be credited to the wrong site.
$script:PersistenceMarkerLookback = 6

<#
Drop a trailing `# comment` from one line, leaving a `#` that sits inside a
quoted string alone (`'--background=#101014'`). Quote tracking is single-pass
and does not model escapes, which is enough for argument arrays.
#>
function Remove-PsLineComment {
    param([string]$Line)
    if ($null -eq $Line) { return '' }
    $inS = $false; $inD = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($c -eq "'" -and -not $inD) { $inS = -not $inS; continue }
        if ($c -eq '"' -and -not $inS) { $inD = -not $inD; continue }
        if ($c -eq '#' -and -not $inS -and -not $inD) { return $Line.Substring(0, $i) }
    }
    return $Line
}

<#
Net bracket depth of a (comment-stripped) fragment: `(` and `{` open, `)` and
`}` close, quoted text ignored.
#>
function Measure-BracketDepth {
    param([string]$Text)
    $depth = 0; $inS = $false; $inD = $false
    foreach ($c in $Text.ToCharArray()) {
        if ($c -eq "'" -and -not $inD) { $inS = -not $inS; continue }
        if ($c -eq '"' -and -not $inS) { $inD = -not $inD; continue }
        if ($inS -or $inD) { continue }
        if ($c -eq '(' -or $c -eq '{') { $depth++ }
        elseif ($c -eq ')' -or $c -eq '}') { $depth-- }
    }
    return $depth
}

<#
The assignment EXPRESSION at the head of $Window: everything up to the first
line end at which the brackets balance. Without this the scan credits a variable
for a flag that merely sits somewhere in the following few hundred characters -
which reads `$errlog = ...` as declaring the persistence of the launch two lines
below it.
#>
function Get-AssignmentSpan {
    param([string]$Window)
    $lines = $Window -split "`r?`n"
    $span = ''
    $depth = 0
    foreach ($line in $lines) {
        $clean = Remove-PsLineComment $line
        $span += $clean + "`n"
        $depth += (Measure-BracketDepth $clean)
        if ($depth -le 0 -and $clean -notmatch '[`,]\s*$') { break }
    }
    return $span
}

<#
The value assignments a variable gets in one file, as raw text. Used to answer
both "which image does $exe name" and "does $argv carry the flag".
#>
function Get-VarAssignmentText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $out = @()
    # $x = ... / $x += ... at the start of a line, and `param([string]$x = '...')`.
    # Each element is parenthesised: `,` binds tighter than `+` in a PowerShell
    # array literal, so an unbracketed `'a' + $n + 'b', 'c' + $n + 'd'` folds into
    # ONE nonsense pattern that matches nothing.
    $patterns = @(
        ('(?m)^\s*\$' + [regex]::Escape($Name) + '\s*\+?=\s*'),
        ('\$' + [regex]::Escape($Name) + '\s*\+?=\s*')
    )
    foreach ($p in $patterns) {
        foreach ($m in [regex]::Matches($Text, $p)) {
            $len = [Math]::Min($script:PersistenceVarWindow, $Text.Length - $m.Index)
            $out += (Get-AssignmentSpan $Text.Substring($m.Index, $len))
        }
    }
    return $out
}

<#
Does $Name - or anything it is built from - carry the flag?

One level of indirection is the common shape here: a script builds
`$launchArgs = @('--session-persistence=false') + $extra`, folds it into a splat
`$sp = @{ Exe = $exe; Arguments = $launchArgs }`, and launches `@sp`. Following
the references (bounded, and never twice) keeps that idiom declared without
asking those scripts to repeat themselves.
#>
function Test-VarDeclaresPersistence {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$Depth = 3,
        [System.Collections.Generic.HashSet[string]]$Seen = $null
    )
    if ($Depth -le 0) { return $false }
    if ($null -eq $Seen) { $Seen = New-Object 'System.Collections.Generic.HashSet[string]' }
    if (-not $Seen.Add($Name.ToLowerInvariant())) { return $false }

    $defs = @(Get-VarAssignmentText -Text $Text -Name $Name)
    foreach ($def in $defs) {
        if ($def -match $script:PersistenceFlagPattern) { return $true }
    }
    foreach ($def in $defs) {
        foreach ($m in [regex]::Matches($def, '\$(\w+)')) {
            $inner = $m.Groups[1].Value
            if ($inner -imatch '^(exe|PSScriptRoot|null|true|false|PID|env)$') { continue }
            if (Test-VarDeclaresPersistence -Text $Text -Name $inner -Depth ($Depth - 1) -Seen $Seen) { return $true }
        }
    }
    return $false
}

<#
A launch inside a helper (`Launch-Gui`, `Start-App`, `Measure-Startup`) usually
takes its arguments from a parameter, so the CHOICE lives at every call of that
helper. Credit the site when there is at least one such call and EVERY one of
them passes the flag - which is a checkable claim, unlike a "callers supply it"
comment that stops being true the day someone adds a call.

Returns the helper's name when it qualifies, else $null.
#>
function Get-HelperCallerDeclaration {
    param(
        # NOT [Parameter(Mandatory)]: a mandatory [string[]] rejects any array
        # holding a blank line, which every script here has.
        [string[]]$Lines,
        [int]$Index
    )
    $name = $null
    for ($k = $Index; $k -ge 0; $k--) {
        if ($Lines[$k] -match '^\s*function\s+([\w\-]+)') { $name = $matches[1]; break }
    }
    if (-not $name) { return $null }

    $calls = 0
    $declared = 0
    for ($k = 0; $k -lt $Lines.Count; $k++) {
        $line = $Lines[$k]
        if ($line -match '^\s*#') { continue }
        if ($line -match ('^\s*function\s+' + [regex]::Escape($name) + '\b')) { continue }
        if ($line -notmatch ('(^|[^\w\-])' + [regex]::Escape($name) + '([^\w\-]|$)')) { continue }
        # Join the call's own continuation lines the same way a launch statement
        # is joined, so a multi-line call is judged whole.
        $call = (Remove-PsLineComment $line)
        $m = $k
        $guard = 0
        while ($m + 1 -lt $Lines.Count -and $guard -lt 20) {
            if ((Measure-BracketDepth $call) -le 0 -and $call -notmatch '[`,]\s*$') { break }
            $m++; $guard++
            $call += ' ' + (Remove-PsLineComment $Lines[$m]).Trim()
        }
        $calls++
        if ($call -match $script:PersistenceFlagPattern) { $declared++ }
    }
    if ($calls -gt 0 -and $calls -eq $declared) { return $name }
    return $null
}

<#
Does this launch statement start the app under test?

Resolved from the image variable's own assignments: a script that launches
`av.exe` (crash-diagnostics), the agent, or a fake relay is not a GUI launch of
Ghoztty and has no persistence to declare. An image we cannot resolve is treated
as the app - a sweep that guesses "not ours" would hide exactly the site nobody
has looked at.
#>
function Test-GhozttyImage {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Stmt
    )
    $var = $null
    if ($Stmt -match '-Exe\s+\$(\w+)') { $var = $matches[1] }
    elseif ($Stmt -match '-FilePath\s+\$(\w+)') { $var = $matches[1] }
    elseif ($Stmt -match 'Start-Process\s+\$(\w+)') { $var = $matches[1] }
    elseif ($Stmt -match '-(Exe|FilePath)\s+"([^"]+)"') { return ($matches[2] -imatch 'ghoztty\.exe|ghoztty\.com') }
    elseif ($Stmt -match '@(\w+)\s*$' -or $Stmt -match 'Start-OnTestDesktop\s+@(\w+)') {
        # splat: the hash carries Exe = $exe
        $var = $matches[1]
        foreach ($def in (Get-VarAssignmentText -Text $Text -Name $var)) {
            if ($def -match 'Exe\s*=\s*\$(\w+)') { $var = $matches[1]; break }
        }
    }
    if (-not $var) { return $false }
    if ($var -imatch 'agent|relay|fixture|crash') { return $false }

    $defs = Get-VarAssignmentText -Text $Text -Name $var
    if ($defs.Count -eq 0) { return $true }
    foreach ($def in $defs) {
        # Only the head of the assignment names the image; the window past it is
        # unrelated code.
        $head = $def.Substring(0, [Math]::Min(200, $def.Length))
        if ($head -imatch 'ghoztty(-debug)?\.(exe|com)') { return $true }
    }
    # Every assignment named something else (av.exe, ghoztty-agent.exe, ...).
    foreach ($def in $defs) {
        $head = $def.Substring(0, [Math]::Min(200, $def.Length))
        if ($head -imatch '\.exe|\.com') { return $false }
    }
    return $true
}

<#
Every launch site in $Root's *.ps1 scripts, with a Declared flag and how it was
declared. Shape per row: File, Line, Kind (TD|SP), Declared, How, Stmt.
#>
function Get-GhozttyLaunchSites {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$Exclude = @()
    )
    $rows = @()
    foreach ($f in (Get-ChildItem (Join-Path $Root '*.ps1') | Sort-Object Name)) {
        if ($Exclude -contains $f.Name) { continue }
        $text = Get-Content $f.FullName -Raw
        $lines = @(Get-Content $f.FullName)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line -match '^\s*#') { continue }
            $isTd = $line -match 'Start-OnTestDesktop'
            $isSp = $line -match 'Start-Process'
            if (-not ($isTd -or $isSp)) { continue }

            # Join continuation lines until the brackets balance. The naive
            # "ends with a comma or a backtick" rule stops early on the shape
            # this suite writes most often - a multi-line argument array whose
            # elements carry trailing `# comments` - and the flag is routinely
            # on a later element of exactly those arrays.
            $stmt = (Remove-PsLineComment $line)
            $j = $i
            $guard = 0
            while ($j + 1 -lt $lines.Count -and $guard -lt 40) {
                $depth = (Measure-BracketDepth $stmt)
                if ($depth -le 0 -and $stmt -notmatch '[`,]\s*$') { break }
                $j++
                $guard++
                $stmt += ' ' + (Remove-PsLineComment $lines[$j]).Trim()
            }
            $stmt = ($stmt.Trim() -replace '\s+', ' ')

            if (-not (Test-GhozttyImage -Text $text -Stmt $stmt)) { continue }

            $how = ''
            if ($stmt -match $script:PersistenceFlagPattern) {
                $how = 'literal'
            } elseif ($stmt -match '--session-persistence=(\S+)') {
                # A value the config parser does not accept is worse than no
                # flag: `parseCLI` logs an InvalidValue and moves on, so the
                # setting keeps its default and the launch that looks explicit
                # restores anyway.
                $how = ''
            } else {
                foreach ($m in [regex]::Matches($stmt, '[@$](\w+)')) {
                    $v = $m.Groups[1].Value
                    if ($v -imatch '^(exe|PSScriptRoot|null|true|false)$') { continue }
                    if (Test-VarDeclaresPersistence -Text $text -Name $v) { $how = "var:`$$v"; break }
                }
            }
            if (-not $how) {
                $helper = Get-HelperCallerDeclaration -Lines $lines -Index $i
                if ($helper) { $how = "callers:$helper" }
            }
            if (-not $how) {
                $from = [Math]::Max(0, $i - $script:PersistenceMarkerLookback)
                for ($k = $from; $k -le $j; $k++) {
                    if ($lines[$k] -match '#\s*persistence:') { $how = 'marker'; break }
                }
            }

            $rows += [pscustomobject]@{
                File     = $f.Name
                Line     = $i + 1
                Kind     = $(if ($isTd) { 'TD' } else { 'SP' })
                Declared = [bool]$how
                How      = $how
                Stmt     = $stmt
            }
        }
    }
    return $rows
}
