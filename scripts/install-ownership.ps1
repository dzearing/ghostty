# Who is allowed to write the user's installed Ghoztty (T1218, decision D85).
#
# THE RULE. `%LOCALAPPDATA%\Programs\Ghoztty` is the product the user installed.
# The ONLY thing that may replace those bytes is the app's own updater taking a
# PUBLISHED release. No repo build, no staging prefix, no morning job, no script
# in this directory may overwrite it - not even "just this once", because the
# failure mode is silent by construction: the swap succeeds, the terminal keeps
# working, and the version it reports describes bytes nobody ever released.
#
# WHY IT IS A RULE AND NOT A HABIT. Until 2026-08-31 the loop refreshed the
# user's install out of a repo build every morning (T525). It was deliberate and
# it worked, but D85 put the question to the user directly and the answer was
# the option the loop had NOT assumed:
#
#   "the terminal should only ever run something that was actually published"
#
# So the swap is retired rather than merely discouraged. A habit is not
# enforceable; this file is, and `test\win32\install-ownership.ps1` is the
# demonstration that the refusal can actually fire.
#
# WHAT IS STILL ALLOWED. Everything about building and running a dev build:
# `zig-out\bin\ghoztty.exe` is run directly, and a dev *install* (a private
# copy the delivery scripts may swap freely) lives at
# `%LOCALAPPDATA%\ghoztty\dev-install`. The distinction is ownership, not
# mechanism - the loop may overwrite anything it owns, and owns nothing under
# `Programs\Ghoztty`.
#
# Dot-source it:
#
#   . (Join-Path $PSScriptRoot 'install-ownership.ps1')
#   Assert-NotUserInstall -Path $InstallDir -Who 'upgrade-ghoztty-windows.ps1'

# The user's installed product. Not a parameter: a caller that could move it
# could also move around the refusal.
function Get-UserInstallDir {
    Join-Path $env:LOCALAPPDATA 'Programs\Ghoztty'
}

# The private install the loop DOES own, for anyone who needs a swap target
# that behaves like an install without being the user's.
function Get-DevInstallDir {
    Join-Path $env:LOCALAPPDATA 'ghoztty\dev-install'
}

# True when $Path is the user's install or anything inside it.
#
# Compared as normalised, trailing-separator-free, case-insensitive paths, and
# WITHOUT touching the filesystem: the answer must be the same whether or not
# the directory exists, or a delivery to a not-yet-created install path would
# slip through the one check that is supposed to be unconditional.
function Test-IsUserInstallPath {
    param([string]$Path)
    if (-not $Path) { return $false }
    $install = Get-UserInstallDir
    if (-not $install) { return $false }
    $norm = {
        param($p)
        try { $p = [IO.Path]::GetFullPath($p) } catch { }
        $p.TrimEnd('\', '/')
    }
    $a = & $norm $Path
    $b = & $norm $install
    if ($a -eq $b) { return $true }
    return $a.StartsWith($b + '\', [StringComparison]::OrdinalIgnoreCase)
}

# The refusal message, as a function so every caller says the same thing and the
# acceptance test can match one string.
function Get-InstallOwnershipRefusal {
    param([string]$Path, [string]$Who = 'this script')
    @(
        "REFUSED: $Who will not write the user's installed Ghoztty ($Path).",
        "The installed app is the product; only the in-app updater may replace it, and only with a published release (decision D85, task T1218).",
        "To ship today's work to the user, PUBLISH it: scripts\publish-windows-release.ps1 - the terminal then offers the update like it does for every other user.",
        "To run what you just built, use zig-out\bin\ghoztty.exe, or point -InstallDir at the dev install ($(Get-DevInstallDir))."
    ) -join "`n"
}

# Refuse, loudly, if $Path is the user's install. Returns the message instead of
# exiting when -Quiet is passed, so a caller with its own logging can decide how
# to report it; otherwise it writes the refusal and exits with $ExitCode.
function Assert-NotUserInstall {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Who = 'this script',
        [int]$ExitCode = 3,
        [switch]$Quiet
    )
    if (-not (Test-IsUserInstallPath -Path $Path)) { return '' }
    $msg = Get-InstallOwnershipRefusal -Path $Path -Who $Who
    if ($Quiet) { return $msg }
    Write-Host $msg
    [Console]::Error.WriteLine($msg)
    exit $ExitCode
}
