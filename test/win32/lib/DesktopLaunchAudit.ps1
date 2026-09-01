# DesktopLaunchAudit (T1193) - find the acceptance scripts that open a Ghoztty
# WINDOW on the user's own desktop, and keep the exceptions DECLARED.
#
# The sibling of `lib\ForegroundAudit.ps1`, and deliberately not the same check.
# That one asks "does this script CALL an API that only works on the input
# desktop" - SendInput, SetForegroundWindow, a screen DC. This one asks a
# question no API name answers: "does this script LAUNCH THE APP from a process
# that is sitting on the user's desktop?" A script can be spotless by the first
# rule and still throw an 800x600 window across whatever the user is reading,
# because the window arrives on the desktop of whoever started the process, and
# nothing in the launch names a desktop.
#
# That is how 60-odd scripts stayed invisible while the fleet-wide claim was
# "the acceptance suite no longer steals the user's foreground" - including
# `ipc-p1.ps1`, `ipc-p2.ps1` and `ipc-p3.ps1`, the three CLAUDE.md names as the
# floor for every change. The loop ran them on essentially every task.
#
# THE RULE:
#
#     A script under `test\win32\` that starts the ghoztty app must start it
#     through the harness (`Start-OnTestDesktop` / `Invoke-OnTestDesktop`), so
#     it lands on the background test desktop. An undeclared launch on the
#     caller's desktop is a miss.
#
# WHAT COUNTS AS STARTING THE APP (measured, not assumed). Only two argv shapes
# put a window on screen:
#
#   * A BARE launch - `Start-Process $Exe`, `& $Exe --config-file=...`, any
#     invocation whose first argument is not a `+verb`. That is the app itself.
#   * `+new-window` - the ONLY verb that auto-launches. `performIpc` in
#     `src\apprt\win32\App.zig` answers `error.NoRunningInstance` by spawning
#     the app for `.new_window` and for nothing else, so `+list`, `+close`,
#     `+read`, `+send-keys` and the rest cannot create a process, and an
#     invocation of one is not a finding. Re-measure this list if that switch
#     grows an arm.
#
# The desktop is inherited, which is the whole reason a fix is cheap: a CLI
# process started with `STARTUPINFO.lpDesktop` pointing at the test desktop
# auto-launches the GUI onto that same desktop. Measured on box 2026-09-01 -
# `Start-OnTestDesktop -Exe ghoztty.exe -Arguments '+new-window'` from cold put
# both the auto-launched startup window and the named one on the test desktop,
# and no ghoztty process reported a MainWindowHandle to the user's session. So a
# CLI-driven script migrates by routing its `& $Exe` calls through
# `Invoke-OnTestDesktop`, not by being rewritten around window handles.
#
# WHAT THIS CANNOT SEE, stated rather than implied. An invocation assembled as a
# STRING and handed to another interpreter - `cmd /c "`"$Exe`" +new-window"`,
# `Invoke-Expression` - is not a command in the AST and no textual rule can tell
# it from prose about one. Every launch site in this suite has been a real
# PowerShell command; the teeth check plants one of those. A file whose SUBJECT
# is these patterns carries the `# desktop-launch-audit:` marker below instead
# of being scanned.
#
# Declaration grammar, one entry per line, anywhere in `lib\TestDesktop.ps1`:
#
#     # @user-desktop-launch: <script>.ps1 -- <one-line reason>
#
# Three finding kinds, all of them the defect, all enforced at zero:
#
#   * `undeclared`             - a live launch site in a script that is not on
#                                the list. Migrate it, or declare it.
#   * `stale-declaration`      - a declared script that no longer launches on
#                                the caller's desktop (or is gone). This is what
#                                makes the list burn DOWN: a migration that does
#                                not delete its entry fails the sweep.
#   * `malformed-declaration`  - a marker line the parser cannot read, so the
#                                prose and the enforced set have drifted.
#
# The pending-migration entries carry their task id in the reason, so the
# remaining distance is readable off the list rather than remembered.

# The verbs whose invocation cannot create a process. Anything not here - and
# an argv with no verb at all - is a launch.
function Get-DesktopLaunchAuditQuietVerbs {
    # Every verb `src\cli\ghostty.zig`'s Action enum declares, minus the one
    # that auto-launches. `+split` and `+new-remote-window` are on this list on
    # purpose and it is the interesting half: both answer
    # `error.NoRunningInstance` by printing "Start one with +new-window first"
    # and returning 1, so neither can put a window anywhere.
    return @(
        '+version', '+help', '+list-fonts', '+list-keybinds', '+list-themes',
        '+list-colors', '+list-actions', '+ssh-cache', '+edit-config',
        '+show-config', '+explain-config', '+validate-config', '+show-face',
        '+crash-report', '+boo', '+split', '+close', '+rename', '+rearrange',
        '+list', '+sessions', '+read', '+send-keys', '+set-state',
        '+set-banner', '+reload', '+json', '+new-remote-window'
    )
}

# The verb that auto-launches (src\apprt\win32\App.zig, performIpc).
function Get-DesktopLaunchAuditLaunchVerb { return '+new-window' }

# The harness entry points. A launch through one of these names a desktop.
function Get-DesktopLaunchAuditHarnessCommands {
    return @('Start-OnTestDesktop', 'Invoke-OnTestDesktop')
}

# A file that NAMES these patterns without being a launcher - the audit itself,
# and its acceptance script, whose fixtures are literal launch sites.
function Test-DesktopLaunchAuditExempt {
    param(
        [string]$Path,
        [string[]]$Text
    )
    $lines = if ($null -ne $Text) { $Text } else { @(Get-Content -LiteralPath $Path) }
    foreach ($l in $lines) { if ($l -match '#\s*desktop-launch-audit:') { return $true } }
    return $false
}

# ---------------------------------------------------------------------------
# The declaration list, parsed out of the harness header. Same grammar and the
# same three shapes as ForegroundAudit's, deliberately: two lists a reader meets
# side by side should not need two grammars.
# ---------------------------------------------------------------------------
function Get-DesktopLaunchAuditDeclarations {
    param(
        [string]$Path,
        [string[]]$Text
    )
    $lines = if ($null -ne $Text) { $Text } else { @(Get-Content -LiteralPath $Path) }
    $out = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -notmatch '@user-desktop-launch:') { continue }
        $rest = ($l -split '@user-desktop-launch:', 2)[1]
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

# ---------------------------------------------------------------------------
# Launch sites in one script.
# ---------------------------------------------------------------------------

# Does this command element name the ghoztty executable? Two shapes cover every
# call site in the suite: a variable the script resolved once (`$Exe`,
# `$GhozttyExe`, `$script:exe`) and a literal path.
function Test-DesktopLaunchAuditGhozttyRef($El) {
    if ($null -eq $El) { return $false }
    if ($El -is [System.Management.Automation.Language.VariableExpressionAst]) {
        $n = $El.VariablePath.UserPath
        # `$Exe`, `$AppExe`, `$exePath` - but not `$exeVersionText`, which is a
        # string about one. The suffix rule is what every launcher here uses.
        return ($n -match '(?i)(^|[^a-z])exe(path|)$')
    }
    if ($El -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return ($El.Value -match '(?i)ghoztty(-agent)?\.exe$')
    }
    if ($El -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
        return ($El.Value -match '(?i)ghoztty(-agent)?\.exe$')
    }
    return $false
}

# The first real argument of an invocation, as text - $null when there is none.
function Get-DesktopLaunchAuditFirstArg($Elements) {
    for ($i = 1; $i -lt $Elements.Count; $i++) {
        $el = $Elements[$i]
        if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
            return '-' + $el.ParameterName
        }
        if ($el -is [System.Management.Automation.Language.ConstantExpressionAst]) {
            return "$($el.Value)"
        }
        if ($el -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
            return $el.Value
        }
        return '<expr>'
    }
    return $null
}

# Classify an argv against the shapes that can create a ghoztty PROCESS.
# Returns 'bare-launch', 'new-window', 'unknown' or $null.
function Get-DesktopLaunchAuditKind([string]$FirstArg) {
    if ($null -eq $FirstArg -or $FirstArg -eq '') { return 'bare-launch' }
    if ($FirstArg -eq '<expr>') { return 'unknown' }
    if ($FirstArg -eq (Get-DesktopLaunchAuditLaunchVerb)) { return 'new-window' }
    if ($FirstArg -like '+*') {
        $verb = ($FirstArg -split '[ =]')[0]
        if ((Get-DesktopLaunchAuditQuietVerbs) -contains $verb) { return $null }
        # An unrecognised verb is reported rather than waved through: the quiet
        # list is measured against one enum and one switch statement, and a new
        # arm on either must be a finding until somebody looks.
        return 'new-window'
    }
    # A flag or a path: the app itself, started with settings.
    return 'bare-launch'
}

function Get-DesktopLaunchAuditSites {
    param(
        [string]$Path,
        [string[]]$Text
    )
    $sites = New-Object System.Collections.ArrayList
    $tokens = $null
    $errors = $null
    $src = if ($null -ne $Text) { $Text -join "`n" } else { Get-Content -Raw -LiteralPath $Path }
    if ($null -eq $src) { $src = '' }
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $src, [ref]$tokens, [ref]$errors)

    $harness = Get-DesktopLaunchAuditHarnessCommands
    foreach ($cmd in @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {

        $els = @($cmd.CommandElements)
        if ($els.Count -eq 0) { continue }
        $name = $cmd.GetCommandName()
        if ($name -and ($harness -contains $name)) { continue }

        # Shape 1 - Start-Process / [Diagnostics.Process]::Start.
        if ($name -and ($name -in @('Start-Process', 'saps', 'start'))) {
            $exeEl = $null
            $argsText = $null
            for ($i = 1; $i -lt $els.Count; $i++) {
                $el = $els[$i]
                if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
                    $pn = $el.ParameterName
                    $val = $el.Argument
                    if ($null -eq $val -and ($i + 1) -lt $els.Count) { $val = $els[$i + 1] }
                    if ($pn -match '(?i)^(FilePath|Path)') {
                        if (Test-DesktopLaunchAuditGhozttyRef $val) { $exeEl = $val }
                    } elseif ($pn -match '(?i)^Arg') {
                        $argsText = $val
                    }
                    continue
                }
                if ($null -eq $exeEl -and (Test-DesktopLaunchAuditGhozttyRef $el)) { $exeEl = $el }
            }
            if ($null -eq $exeEl) { continue }
            $first = $null
            if ($null -ne $argsText) { $first = Get-DesktopLaunchAuditArgListFirst $argsText }
            $kind = Get-DesktopLaunchAuditKind $first
            if ($null -ne $kind) {
                [void]$sites.Add([pscustomobject]@{
                    Line = $cmd.Extent.StartLineNumber; Kind = $kind
                    What = 'Start-Process ' + $exeEl.Extent.Text
                })
            }
            continue
        }

        # Shape 2 - a direct invocation: `& $Exe +new-window ...`, `$Exe --flag`.
        if (-not (Test-DesktopLaunchAuditGhozttyRef $els[0])) { continue }
        $kind = Get-DesktopLaunchAuditKind (Get-DesktopLaunchAuditFirstArg $els)
        if ($null -eq $kind) { continue }
        [void]$sites.Add([pscustomobject]@{
            Line = $cmd.Extent.StartLineNumber; Kind = $kind
            What = ($els[0].Extent.Text + ' ' + (Get-DesktopLaunchAuditFirstArg $els)).Trim()
        })
    }

    return $sites
}

# The first element of a `-ArgumentList` value, whatever shape it was written
# in: an array literal, a single string, or a variable (unknowable - treated as
# a launch, which is the safe direction).
function Get-DesktopLaunchAuditArgListFirst($Node) {
    if ($null -eq $Node) { return $null }
    if ($Node -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        $first = @($Node.Elements)[0]
        if ($null -eq $first) { return $null }
        if ($first -is [System.Management.Automation.Language.ConstantExpressionAst]) { return "$($first.Value)" }
        if ($first -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { return $first.Value }
        return '<expr>'
    }
    if ($Node -is [System.Management.Automation.Language.ArrayExpressionAst]) {
        $inner = @($Node.SubExpression.Statements)
        if ($inner.Count -eq 0) { return $null }
        return (Get-DesktopLaunchAuditArgListFirst $inner[0].PipelineElements[0].Expression)
    }
    if ($Node -is [System.Management.Automation.Language.ConstantExpressionAst]) {
        return ("$($Node.Value)" -split '\s+')[0]
    }
    if ($Node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
        return ($Node.Value -split '\s+')[0]
    }
    return '<expr>'
}

# ---------------------------------------------------------------------------
# Which of a script's sites actually land on the CALLER's desktop.
#
# A script that never calls `New-TestDesktop` has no other desktop to land on,
# so every site counts. A script that owns one is a different case, and the
# distinction is worth stating because it is the whole difference between a
# check with 129 findings nobody can act on and one with the real set:
#
#   * A BARE launch still counts there. `Start-Process $exe` names no desktop
#     and creates the process from the PowerShell host, which is on the user's
#     desktop no matter how many desktops the script has created.
#   * `+new-window` and an unknowable argv do NOT. A desktop-owning script has
#     already started the app through `Start-OnTestDesktop` before it starts
#     sending verbs, so the CLI is talking to a running instance and creates no
#     process at all. This is the STATED LIMIT of the check: a desktop-owning
#     script whose FIRST contact with the app is a cold `+new-window` would
#     auto-launch onto the caller's desktop and is not flagged. Nothing in the
#     suite is shaped that way today, and a bare-launch site - which every one
#     of them has, because that is how they start the app - is what catches
#     them.
# ---------------------------------------------------------------------------
function Select-DesktopLaunchAuditSites {
    param(
        [string]$Path,
        [object[]]$Sites,
        [string[]]$Text
    )
    $src = if ($null -ne $Text) { $Text -join "`n" } else { Get-Content -Raw -LiteralPath $Path }
    if ($null -eq $src) { $src = '' }
    if ($src -notmatch 'New-TestDesktop') { return @($Sites) }
    return @($Sites | Where-Object { $_.Kind -eq 'bare-launch' })
}

# ---------------------------------------------------------------------------
# The analyzer. One object per finding; an empty result is a clean suite.
# ---------------------------------------------------------------------------
function Get-DesktopLaunchAuditFindings {
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
        $Declared = @(Get-DesktopLaunchAuditDeclarations -Path $harness)
    }
    $Declared = @($Declared)

    foreach ($d in ($Declared | Where-Object { $_.Malformed })) {
        [void]$findings.Add([pscustomobject]@{
            Path = 'lib\TestDesktop.ps1'; Line = $d.Line; Kind = 'malformed-declaration'
            Detail = "cannot read this declaration; expected '<script>.ps1 -- <reason>', got '$($d.Reason)'" })
    }
    $good = @($Declared | Where-Object { -not $_.Malformed })

    if ($null -eq $Files) {
        $Files = @(Get-ChildItem -LiteralPath $Root -Filter *.ps1 -File |
            ForEach-Object { $_.FullName })
    }

    $launchers = @{}
    foreach ($f in $Files) {
        $name = Split-Path $f -Leaf
        if (Test-DesktopLaunchAuditExempt -Path $f) { continue }
        $sites = @(Get-DesktopLaunchAuditSites -Path $f)
        if ($sites.Count -eq 0) { continue }
        $sites = @(Select-DesktopLaunchAuditSites -Path $f -Sites $sites)
        if ($sites.Count -eq 0) { continue }
        $launchers[$name] = $sites
        $decl = @($good | Where-Object { $_.Script -eq $name })
        if ($decl.Count -eq 0) {
            $first = @($sites | Sort-Object Line)[0]
            $how = if ($first.Kind -eq 'new-window') {
                "auto-launches the app ($($first.What)) on the caller's desktop"
            } else {
                "starts the app ($($first.What)) on the caller's desktop"
            }
            [void]$findings.Add([pscustomobject]@{
                Path = $f; Line = $first.Line; Kind = 'undeclared'
                Detail = "$how and is not declared in lib\TestDesktop.ps1" })
        }
    }

    foreach ($d in $good) {
        if ($launchers.ContainsKey($d.Script)) { continue }
        $exists = $null -ne ($Files | Where-Object { (Split-Path $_ -Leaf) -eq $d.Script })
        $why = if ($exists) { 'no longer launches on the caller''s desktop' } else { 'no longer exists' }
        [void]$findings.Add([pscustomobject]@{
            Path = 'lib\TestDesktop.ps1'; Line = $d.Line; Kind = 'stale-declaration'
            Detail = "$($d.Script) is declared as a user-desktop launcher but $why" })
    }

    return $findings
}

function Get-DesktopLaunchAuditHardKinds {
    return @('undeclared', 'stale-declaration', 'malformed-declaration')
}

function Get-DesktopLaunchAuditSweep([string]$Root) {
    return @(Get-DesktopLaunchAuditFindings -Root $Root)
}
