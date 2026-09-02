# ApplierSandbox.ps1 - a THROWAWAY INSTALL DIRECTORY for the harnesses that
# drive the real update applier, plus the alarm and the repair that go with it
# (T1268, then T1271). Dot-source it:
#
#     . (Join-Path $PSScriptRoot 'lib\ApplierSandbox.ps1')
#     $sandbox = New-ApplierSandbox -Exe $exe -Root $work
#     $env:GHOZTTY_UPDATE_APPLY = "$deadPid|$msi|$($sandbox.Exe)"
#
# WHY THIS EXISTS
#
# The applier's job, when it finds an image it cannot overwrite, is to RENAME
# IT ASIDE (`ghoztty.exe.old-<stamp>`) so msiexec can write a fresh one - see
# `clearInstallDir` in src\apprt\win32\update_install.zig. That is the right
# behaviour in production and a loaded gun in a harness: every one of these
# scripts installs a package msiexec is GUARANTEED to reject (a fake one, or a
# forced code through the Debug seam), so nothing ever writes the exe back.
# Point that at `zig-out\bin` and one straggler holding `ghoztty.exe` open is
# all it takes to leave the turn with no build at all.
#
# It is not hypothetical. On 2026-09-01 `update-apply.ps1` finished a run having
# left `zig-out\bin\ghoztty.exe.old-1788324281` and no `ghoztty.exe`; every
# script after it died with `CreateProcessW failed: 2`, for a reason that had
# nothing to do with the code under test.
#
# So the applier is handed a COPY of the build in a scratch directory. Every
# assertion those harnesses make reads the applier's own log or the install
# directory it was given, so they hold exactly as well against the copy - and
# the destructive operation can only ever reach something we can afford to lose.
#
# The second half is the alarm: `Get-SidelinedBuild` + `Restore-RepoBuild` are
# what a FUTURE harness reaching the same state hits instead of stranding the
# build. A run asserts on the strays FIRST (that is the finding) and repairs
# afterwards - a run that quietly fixed the damage before looking would never
# have one.

Set-StrictMode -Off

# Stop-HarnessGhoztty: the path-scoped kill used to reap the app the applier
# relaunches out of the sandbox. `Stop-RepoGhoztty` cannot do it - it refuses an
# exe that is not under the repo, by design, and the sandbox deliberately is not.
. (Join-Path $PSScriptRoot 'HarnessLeak.ps1')

# `ghoztty.exe.old-<unix stamp>`, exactly as update_apply.sidelineName spells it.
# Anchored so an unrelated `.old-keep` beside a build is never touched.
$script:SidelinedPattern = '^ghoztty\.exe\.old-\d+$'

function New-ApplierSandbox {
    <#
    .SYNOPSIS
    A throwaway install directory holding a copy of the build under test.

    .DESCRIPTION
    Returns an object with .Dir and .Exe. Point the applier's spec at .Exe and
    the rename-aside path can only reach the copy.

    The directory must be under the repo or $env:TEMP - Register-RepoBuildTeardown
    is armed on it, so anything the applier relaunches out of the sandbox is
    reaped when this PowerShell exits, however it exits.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string]$Root,
        [string]$Name = 'installdir'
    )

    if (-not (Test-Path -LiteralPath $Exe)) {
        throw "New-ApplierSandbox: '$Exe' does not exist; there is nothing to copy."
    }
    $dir = Join-Path $Root $Name
    New-Item -ItemType Directory -Force $dir | Out-Null
    $sandboxExe = Join-Path $dir 'ghoztty.exe'
    Copy-Item -LiteralPath $Exe -Destination $sandboxExe -Force

    # Assert-HarnessScratchRoot (inside this) is what refuses a sandbox pointed
    # somewhere it must never reap from.
    [void](Register-RepoBuildTeardown -Exe $sandboxExe -Quiet)

    return [pscustomobject]@{ Dir = $dir; Exe = $sandboxExe }
}

function Stop-ApplierSandbox {
    <#
    .SYNOPSIS
    Kill whatever the applier relaunched out of the sandbox. Returns the count.

    .DESCRIPTION
    Every arm ends with the applier having relaunched "the user's terminal" -
    a real app, out of the sandbox directory. It is not under the repo, so the
    repo-scoped kill in lib\CleanSlate.ps1 does not see it, and a leak is
    invisible to the script that causes it (T1094).
    #>
    param(
        [Parameter(Mandatory = $true)]$Sandbox,
        [int]$SettleMs = 400
    )
    $dir = if ($Sandbox -is [string]) { $Sandbox } else { $Sandbox.Dir }
    return [int](Stop-HarnessGhoztty -Root $dir -SettleMs $SettleMs)
}

function Get-SidelinedBuild {
    <#
    .SYNOPSIS
    Any `ghoztty.exe.old-<stamp>` sitting beside the build under test.

    .DESCRIPTION
    Newest first, so the caller restoring one restores the most recent. An
    empty array is the healthy answer, and is what the "the repo build survived"
    assertion is written against.
    #>
    param([Parameter(Mandatory = $true)][string]$ExePath)
    $binDir = Split-Path -Parent $ExePath
    if (-not $binDir) { return @() }
    return @(Get-ChildItem -LiteralPath $binDir -Filter 'ghoztty.exe.old-*' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $script:SidelinedPattern } |
        Sort-Object LastWriteTime -Descending)
}

function Restore-RepoBuild {
    <#
    .SYNOPSIS
    Put the build back if anything in this run sidelined it, and sweep the rest.

    .DESCRIPTION
    Belt and braces for the sandbox above: the sandbox is why this cannot
    happen any more, and this is what a future harness reaching the same state
    hits instead of stranding the build.

    A live `ghoztty.exe` is never overwritten - a stray beside a healthy build
    is stale, and the healthy build wins. A file that is not a sidelined image
    (`ghoztty.exe.old-keep`, say) is left alone, and nothing is ever invented
    from one.
    #>
    param([Parameter(Mandatory = $true)][string]$ExePath)

    $sidelined = @(Get-SidelinedBuild -ExePath $ExePath)
    if ($sidelined.Count -eq 0) { return }
    $restored = $false
    foreach ($s in $sidelined) {
        if (-not $restored -and -not (Test-Path -LiteralPath $ExePath)) {
            Move-Item -LiteralPath $s.FullName -Destination $ExePath -Force
            Write-Host "  restored $ExePath from $($s.Name)"
            $restored = $true
        } else {
            Remove-Item -LiteralPath $s.FullName -Force -ErrorAction SilentlyContinue
            Write-Host "  removed stray $($s.Name)"
        }
    }
}
