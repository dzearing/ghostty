# HarnessLeak.ps1 - tear down (and detect) a ghoztty launched from a harness's
# own scratch directory (T199). Dot-source it:
#
#     . (Join-Path $PSScriptRoot 'lib\HarnessLeak.ps1')
#     $root = Join-Path $env:TEMP "ghoztty-myscript-$PID"
#     Register-HarnessGhozttyRoot -Root $root      # teardown, failure path included
#     ...
#     Stop-HarnessGhoztty -Root $root              # explicit teardown
#
# WHY THIS EXISTS
#
# On 2026-07-29 a debugging run pointed the delivery script at a stand-in
# install dir (`%TEMP%\gh-dbg2\install`). Delivering is exactly the job that
# ENDS by launching the app, so the run left a live GUI ghoztty behind - holding
# windows, a message loop and possibly an IPC pipe instance. It was still
# running NINETEEN HOURS later, and was found by eye while taking the pre-state
# for an unrelated delivery.
#
# A stray file is litter; a stray app is an oracle problem. Every later
# process/pipe assertion on this box has to answer "is that ghoztty mine or the
# leak's?", and the suite has been burned by exactly that ambiguity before
# (T111b's orphaned CLI child holding a redirect file open, T116's script
# driving the user's live terminal).
#
# WHY NOT Stop-RepoGhoztty
#
# lib\CleanSlate.ps1 already kills the app under test - but it REFUSES, by
# design, any exe that is not under the repo, so a mistyped -Exe can never reach
# the user's install. A stand-in install dir is by definition not under the
# repo, so that helper cannot be the teardown for one, and every harness that
# builds such a dir has had to write its own. This is the missing counterpart:
# same path-exact discipline, a different sanctioned root.
#
# SAFETY
#
# A root must be an absolute path under %TEMP% or under the repo, and must be a
# PROPER subdirectory of one of them - `-Root $env:TEMP` is refused, because a
# root that broad is a kill-everything switch waiting for a variable to be
# empty. Matching is on ExecutablePath, never on image name: a name match would
# take the user's installed release and its live sessions with it, which is the
# T116 lesson and the reason upgrade-ghoztty-windows.ps1 scopes its own kill to
# the install dir.

Set-StrictMode -Off

$script:HarnessLeakRepo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path

# Every image a harness can leave behind. `.com` is in the list because it is
# the CLI entry point from PowerShell (T245) and a GUI launch through it
# respawns `ghoztty.exe` detached - so a leak can wear either name.
# `ghoztty-agent.exe.bak` is in the list because that is the image name a real
# delivery leaves the RUNNING agent with (a running exe cannot be overwritten on
# Windows, so the upgrade renames it and copies the new build into the original
# path), and a harness that drives the T907 self-handoff has to reproduce it -
# Win32_Process.Name is the image name recorded at creation, so without this
# entry that agent is invisible to the leak sweep and outlives the run.
$script:HarnessLeakImages = @('ghoztty.exe', 'ghoztty.com', 'ghoztty-agent.exe', 'ghoztty-agent.exe.bak')

# The same set as Get-Process names them: no extension, so one entry covers both
# `ghoztty.exe` and `ghoztty.com`. Used by the exit-time teardown, which cannot
# reach Get-CimInstance (see Get-HarnessTeardownBlock).
# `ghoztty-agent.exe` is here as a NAME because Get-Process strips only the last
# extension: an agent running from `ghoztty-agent.exe.bak` (see above) is named
# `ghoztty-agent.exe`, which the `ghoztty-agent` entry does not match.
$script:HarnessLeakProcessNames = @('ghoztty', 'ghoztty-agent', 'ghoztty-agent.exe')

function ConvertTo-HarnessLeakDir {
    <#
    .SYNOPSIS
    Normalize a directory to a full path with exactly one trailing separator.
    #>
    param([string]$Path)
    if (-not $Path) { return '' }
    $full = [IO.Path]::GetFullPath($Path)
    return ($full.TrimEnd('\', '/') + '\')
}

function Test-HarnessLeakUnder {
    param([string]$Path, [string]$Dir)
    if (-not $Path -or -not $Dir) { return $false }
    return $Path.StartsWith($Dir, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-HarnessScratchRoot {
    <#
    .SYNOPSIS
    Throw unless $Root is a safe scratch root to kill inside of.

    .DESCRIPTION
    Returns the normalized root (full path, one trailing separator). The rules
    are deliberately narrow: absolute, and a PROPER subdirectory of %TEMP% or of
    the repo. An empty or relative root, %TEMP% itself, a drive root, or
    anything under the user's install is refused by name.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Root)

    if (-not $Root -or -not $Root.Trim()) {
        throw "Assert-HarnessScratchRoot: empty root. A blank root is how a teardown becomes a kill-everything switch."
    }
    if (-not [IO.Path]::IsPathRooted($Root)) {
        throw "Assert-HarnessScratchRoot refuses '$Root': not an absolute path."
    }

    $norm = ConvertTo-HarnessLeakDir $Root
    $temp = ConvertTo-HarnessLeakDir $env:TEMP
    $repo = ConvertTo-HarnessLeakDir $script:HarnessLeakRepo

    foreach ($base in @($temp, $repo)) {
        if (-not $base) { continue }
        if ($norm -eq $base) {
            throw "Assert-HarnessScratchRoot refuses '$Root': it IS the sanctioned base ($base), not a scratch root under it."
        }
        if (Test-HarnessLeakUnder $norm $base) { return $norm }
    }

    throw "Assert-HarnessScratchRoot refuses '$Root': not under `$env:TEMP ($temp) or the repo ($repo). Acceptance scripts never kill outside their own scratch."
}

function Get-HarnessGhozttyProcess {
    <#
    .SYNOPSIS
    Live ghoztty/ghoztty-agent processes whose exe lives under $Root.
    #>
    param([Parameter(Mandatory = $true)][string]$Root)
    $norm = Assert-HarnessScratchRoot -Root $Root
    $found = @()
    foreach ($name in $script:HarnessLeakImages) {
        $found += @(Get-CimInstance Win32_Process -Filter "Name='$name'" -ErrorAction SilentlyContinue |
            Where-Object { Test-HarnessLeakUnder $_.ExecutablePath $norm })
    }
    return @($found)
}

function Get-HarnessTeardownBlock {
    <#
    .SYNOPSIS
    The kill, as a scriptblock with $Root and the image names BAKED IN as
    literals. Emits the number of processes stopped.

    .DESCRIPTION
    ONE definition of the teardown, used two ways: run directly by
    Stop-HarnessGhoztty, and armed on PowerShell.Exiting by
    Register-HarnessGhozttyRoot. Generating it means the code that runs when a
    harness dies is byte-identical to the code that runs when it cleans up
    properly - the failure path is not a second implementation that nobody
    exercises.

    TWO RULES, both measured on 2026-08-10 while building this, both silent
    failures that make a handler simply do nothing:

    1. IT HAS TO BE LITERALS. A PowerShell.Exiting action runs in a scope that
       cannot resolve the registering scope's variables. An action referencing a
       $global: variable never fired; an action built with .GetNewClosure() never
       fired; an action of pure literals fired on both a normal exit and an
       unhandled throw. (Same wall lib\TestDesktop.ps1 hit in T179, which it
       answered by calling a static method on a loaded type.)
    2. ONLY ALREADY-LOADED CMDLETS. Module auto-loading does not work at exit, so
       `Get-CimInstance` - the process query every other helper here uses - is
       unusable unless something happened to load CimCmdlets earlier in the run.
       Get-Process and Stop-Process are core and always there, and `.Path` is the
       same ExecutablePath comparison by another name.
    #>
    param([Parameter(Mandatory = $true)][string]$NormalizedRoot)

    # Single-quoted literals; a path with an apostrophe in it is escaped by
    # doubling, exactly as PowerShell wants.
    $rootLit = $NormalizedRoot.Replace("'", "''")
    $lines = @('$killed = 0')
    foreach ($name in $script:HarnessLeakProcessNames) {
        $lines += @(
            "Get-Process -Name '$name' -ErrorAction SilentlyContinue |"
            "  Where-Object { `$_.Path -and `$_.Path.StartsWith('$rootLit', [StringComparison]::OrdinalIgnoreCase) } |"
            "  ForEach-Object { Stop-Process -Id `$_.Id -Force -ErrorAction SilentlyContinue; `$killed++ }"
        )
    }
    $lines += '$killed'
    return [scriptblock]::Create($lines -join "`n")
}

function Stop-HarnessGhoztty {
    <#
    .SYNOPSIS
    Kill every ghoztty process running out of $Root. Returns the count killed.

    .DESCRIPTION
    Path-exact and root-checked (see Assert-HarnessScratchRoot). Safe to call
    when nothing is running - it returns 0.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [int]$SettleMs = 400
    )
    $norm = Assert-HarnessScratchRoot -Root $Root
    $killed = [int](& (Get-HarnessTeardownBlock -NormalizedRoot $norm))
    if ($killed -gt 0 -and $SettleMs -gt 0) { Start-Sleep -Milliseconds $SettleMs }
    return [int]$killed
}

function Register-HarnessGhozttyRoot {
    <#
    .SYNOPSIS
    Tear $Root down when this PowerShell process exits - failure path included.

    .DESCRIPTION
    The teardown a harness writes by hand at the bottom of the script is exactly
    the teardown that does not run when the script dies half way through, which
    is when a leak actually happens. This hangs it on PowerShell.Exiting
    instead, so a throw, an `exit 1`, or a failed assertion still cleans up.
    (A hard kill of the host - taskkill, Ctrl-Break - is not covered by
    anything; the box sweep in test\win32\harness-process-leak.ps1 is the
    backstop for that.)

    ONE HANDLER PER ROOT, not one handler over a list: the handler cannot read a
    variable at exit time (see Get-HarnessTeardownBlock), so the root has to be
    baked into the block, and a second root means a second block. Every
    subscriber on PowerShell.Exiting fires, so they compose.

    Idempotent: registering the same root twice arms one handler.
    #>
    param([Parameter(Mandatory = $true)][string]$Root)

    $norm = Assert-HarnessScratchRoot -Root $Root

    if (-not $global:GhozttyHarnessRoots) {
        $global:GhozttyHarnessRoots = New-Object System.Collections.ArrayList
    }
    $already = @($global:GhozttyHarnessRoots | Where-Object { $_ -eq $norm })
    if ($already.Count -gt 0) { return $norm }
    [void]$global:GhozttyHarnessRoots.Add($norm)

    Register-EngineEvent -SourceIdentifier PowerShell.Exiting `
        -Action (Get-HarnessTeardownBlock -NormalizedRoot $norm) | Out-Null
    return $norm
}

# There is deliberately no Unregister-HarnessGhozttyRoot: the handler carries
# its root as a baked literal, so "forget this root" would have to hunt down the
# right subscriber to be true, and a teardown that only PRETENDS to have been
# cancelled is worse than no such verb. A harness that wants a process to
# outlive it should not register the root in the first place.

function Get-LeakedGhozttyProcess {
    <#
    .SYNOPSIS
    Every live ghoztty process running out of a TEMP directory - i.e. a leak.

    .DESCRIPTION
    The box-wide sweep, and the reason it can be a hard zero: nobody runs their
    terminal out of %TEMP%. Any ghoztty there was put there by a harness, and a
    harness that is still running one after it finished has leaked it.

    Returns objects carrying ProcessId, ExecutablePath, CreationDate and AgeHours
    so a failure can NAME the offender instead of just counting it.
    #>
    param([string]$TempRoot = $env:TEMP)

    $temp = ConvertTo-HarnessLeakDir $TempRoot
    if (-not $temp) { return @() }
    $now = Get-Date
    $found = @()
    foreach ($name in $script:HarnessLeakImages) {
        $found += @(Get-CimInstance Win32_Process -Filter "Name='$name'" -ErrorAction SilentlyContinue |
            Where-Object { Test-HarnessLeakUnder $_.ExecutablePath $temp } |
            ForEach-Object {
                $age = $null
                if ($_.CreationDate) { $age = [math]::Round(($now - $_.CreationDate).TotalHours, 1) }
                [pscustomobject]@{
                    ProcessId      = $_.ProcessId
                    ExecutablePath = $_.ExecutablePath
                    CreationDate   = $_.CreationDate
                    AgeHours       = $age
                }
            })
    }
    return @($found)
}
