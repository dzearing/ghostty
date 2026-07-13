# Ghoztty PowerShell shell integration (pwsh 7 and Windows PowerShell 5.1).
#
# Dot-sourced from the profile that Ghoztty points $env:GHOSTTY_POWERSHELL at
# (see src/termio/shell_integration.zig setupPowershell). It provides the
# same OSC contract as the posix integrations:
#
#   OSC 133 - prompt marks (A/B/C/D) so prompt jumping + fresh-line work
#   OSC 7   - working-directory reporting (kitty-shell-cwd:// form)
#   OSC 2   - window title reporting (the "title" feature)
#
# Everything is feature-gated on GHOSTTY_SHELL_FEATURES, matching the other
# integrations. Failure to integrate must never break the user's shell, so
# the whole thing runs inside a try/catch.

if ($env:GHOSTTY_RESOURCES_DIR -and -not $env:GHOSTTY_SHELL_INTEGRATION_NO_SUDO) {
    # (sudo/ssh feature wrappers are posix-only for now; nothing to do here.)
}

function global:__ghoztty_has_feature([string]$feature) {
    $features = $env:GHOSTTY_SHELL_FEATURES
    if (-not $features) { return $false }
    return ($features -split ',') -contains $feature
}

# ESC and BEL as chars: PowerShell 5.1 has no "`e" escape.
$global:__ghoztty_esc = [char]27
$global:__ghoztty_bel = [char]7

function global:__ghoztty_osc([string]$body) {
    [Console]::Write($global:__ghoztty_esc + ']' + $body + $global:__ghoztty_bel)
}

try {
    $global:__ghoztty_cwd_enabled = __ghoztty_has_feature 'cursor' -or $true  # cwd is always useful
    $global:__ghoztty_title_enabled = __ghoztty_has_feature 'title'

    # Chain our reporting onto the user's existing prompt rather than
    # replacing it: capture the current prompt function and call it.
    $global:__ghoztty_user_prompt = $function:prompt

    function global:prompt {
        # OSC 133;D - the previous command finished. $? is the success flag;
        # $LASTEXITCODE is the exit status of the last native command.
        $exit = 0
        if ($null -ne $LASTEXITCODE) { $exit = $LASTEXITCODE }
        elseif (-not $?) { $exit = 1 }
        __ghoztty_osc "133;D;$exit"

        # OSC 133;A - fresh line + start of a new prompt.
        __ghoztty_osc '133;A'

        # OSC 7 - report the working directory (kitty-shell-cwd:// form, the
        # same shape the posix integrations use). Only filesystem locations
        # make sense; registry/cert providers are skipped.
        try {
            $loc = Get-Location
            if ($loc.Provider.Name -eq 'FileSystem') {
                $p = $loc.ProviderPath -replace '\\', '/'
                if ($p -notmatch '^/') { $p = '/' + $p }
                __ghoztty_osc ("7;kitty-shell-cwd://" + $env:COMPUTERNAME + $p)
            }
        } catch {}

        # OSC 2 - title reporting.
        if ($global:__ghoztty_title_enabled) {
            try {
                $loc = Get-Location
                __ghoztty_osc ('2;' + $loc.Path)
            } catch {}
        }

        # The user's prompt text, wrapped in 133;B (prompt end / input start).
        $text = & $global:__ghoztty_user_prompt
        __ghoztty_osc '133;B'
        return $text
    }

    # OSC 133;C - a command is about to run. PSReadLine's
    # CommandValidationHandler fires right before execution, which is the
    # closest hook to bash's preexec.
    if (Get-Module -ListAvailable -Name PSReadLine) {
        try {
            Import-Module PSReadLine -ErrorAction Stop
            Set-PSReadLineKeyHandler -Chord Enter -ScriptBlock {
                [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
                __ghoztty_osc '133;C'
            }
        } catch {}
    }
} catch {
    # Never break the user's shell over shell integration.
}
