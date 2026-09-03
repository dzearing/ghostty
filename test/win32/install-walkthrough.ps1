# Somebody actually installs the installer, and clicks through it (T1299).
#
# THE GAP THIS CLOSES. Every claim this repo makes about the Windows installer
# is made at its SOURCE (`test\win32\install-launch.ps1`, `install-prepare.ps1`,
# `install-maintenance.ps1` section A read `dist\windows-installer\build-msi.sh`)
# or at BUILD time (the read-back verifiers inside build-msi.sh, compiled on
# every push by fork-ci). Nothing on this box had ever run `msiexec /i` against
# a real package and looked at what came out. So the way an installer defect was
# found was that the user installed it and it broke - three times in a fortnight
# (T1204 the reboot demand, T1205, T1291 the silent same-version exit).
#
# WHY THAT WAS HARD, and how each half is bought here:
#
#   * Building a package needs wixl (GNOME msitools), which on this box lives
#     only inside Docker, and starting Docker is the user's call. So the package
#     is not built here: it is DOWNLOADED. The default subject is the newest
#     PUBLISHED `win-v*` release - the bytes a user actually installs - and
#     `-Msi` takes any local package instead (one pulled from a CI run, or one
#     built on a box that has wixl).
#   * Installing the real product would replace the user's Ghoztty, which is
#     this repo's first non-negotiable. `scripts\msi-test-identity.ps1` is the
#     answer already in the tree: it rewrites the published package into a
#     product with its own ProductCode, UpgradeCode, install directory,
#     component GUIDs, registry key and Start Menu name. What installs here
#     lands in %LOCALAPPDATA%\Programs\GhozttyT1299Test and cannot upgrade,
#     remove or refcount anything of the user's. `-TeethCheck` is the
#     demonstration that the refusal enforcing that actually fires.
#
# THE FOUR-ACT WALK, which is the whole point - each act asserts the OUTCOME a
# person would see, never msiexec's exit code alone:
#
#   A  the package: obtained, rewritten, and provably not the shipping product.
#   B  FRESH INSTALL. Files on disk (all three exes and the fallback OpenGL),
#      the PATH entry, the Start Menu shortcut, an Apps & Features entry at the
#      right version, the installed exe answering +version, and a real terminal
#      window opening on a test desktop (T1176).
#   C  UPGRADE over an older version. The exe SURVIVES (T23's 26.7.502
#      postmortem: the "upgraded" install had no ghoztty.exe), the registered
#      version moves, no reboot is demanded (T1204), and the PATH entry is not
#      duplicated.
#   D  SAME VERSION AGAIN - the case this task was filed from (T1291). The
#      package enters maintenance mode, the app's Repair / Cancel dialog appears
#      on screen, and Cancel ends the transaction at 1602 with the install
#      untouched. Skipped, named, when the package predates the feature: a
#      release published before T1291 has no MaintenancePrompt row to run.
#   E  OLDER PACKAGE OVER A NEWER INSTALL. A plain explanation, not a bare 1638,
#      and nothing about the install moves.
#   F  UNINSTALL. Nothing left behind: no directory, no Apps & Features entry,
#      no PATH entry, no shortcut.
#   G  and the user's Ghoztty is measured before and after, every run.
#
# The version pair acts B/C/E need is minted from ONE package:
# `msi-test-identity.ps1 -ProductVersion` registers the same payload at a lower
# ProductVersion, which is the only honest predecessor available without a
# second published release.
#
# preflight: none - the binaries here come out of a PUBLISHED package, so they
# are release builds by definition and `Assert-GhozttyIsolatedBuild` would
# refuse them. The isolation is bought a different way: `-ReleaseSandbox` gives
# the run its own pipe, its own agent lineage and its own LOCALAPPDATA, the
# product is a throwaway identity in its own directory, and section G measures
# the user's install on every run.
#
#   powershell -NoProfile -File test\win32\install-walkthrough.ps1
#   powershell -NoProfile -File test\win32\install-walkthrough.ps1 -TeethCheck
#   powershell -NoProfile -File test\win32\install-walkthrough.ps1 -Msi C:\pkg.msi
param(
    [string]$Repo = 'D:\git\ghoztty',
    [string]$Identity = 'GhozttyT1299Test',
    # A local package to walk instead of the newest published release.
    [string]$Msi = '',
    # The version the predecessor is registered at. Any value below the
    # package's own works; this one is unmistakably synthetic.
    [string]$OldProductVersion = '0.9.0',
    # Prove the guard that keeps all of this off the user's product goes red,
    # and assert nothing else. Installs nothing, needs no network.
    [switch]$TeethCheck,
    [switch]$KeepInstall
)

$ErrorActionPreference = 'Continue'

# The install directory and the Start Menu are chosen by Windows Installer from
# the SHELL's idea of the user profile, which -ReleaseSandbox below moves out
# from under $env:LOCALAPPDATA. Capture the real ones FIRST or every path
# assertion in this file points at the sandbox and passes while measuring
# nothing.
$realLocalAppData = $env:LOCALAPPDATA
$realAppData = $env:APPDATA

. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$env:GHOZTTY_NO_STARTUP_ESCAPE = '1'
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\ThrowawayProduct.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:passes = 0
$script:failures = 0
$script:skipped = 0
function Assert([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Skip([string]$name, [string]$why) {
    Write-Host "  SKIP $name ($why)" -ForegroundColor Yellow
    $script:skipped++
}

$work = Join-Path $env:TEMP 'ghoztty-t1299'
$msiexec = Join-Path $env:SystemRoot 'System32\msiexec.exe'
$installDir = Get-ThrowawayInstallDir -RealLocalAppData $realLocalAppData -Identity $Identity
$userInstallDir = Get-ThrowawayUserInstallDir -RealLocalAppData $realLocalAppData
$shortcut = Join-Path $realAppData "Microsoft\Windows\Start Menu\Programs\$Identity.lnk"
$installedExe = Join-Path $installDir 'ghoztty.exe'

# ---------------------------------------------------------------------------
# -TeethCheck: the refusal, on its own. Runs first and exits, so the proof that
# this harness cannot touch the user's product needs neither a package nor a
# network nor eight minutes of msiexec.
# ---------------------------------------------------------------------------
if ($TeethCheck) {
    Write-Host "`n== install-walkthrough TEETH: the user's product is out of reach =="

    $refused = $false
    try {
        [void](Assert-ThrowawayInstallDir -InstallDir $userInstallDir -RealLocalAppData $realLocalAppData)
    } catch { $refused = $true }
    Assert 'T1 pointing the kill/delete guard at the user''s install dir throws' $refused

    $refusedChild = $false
    try {
        [void](Assert-ThrowawayInstallDir -InstallDir (Join-Path $userInstallDir 'bin') `
            -RealLocalAppData $realLocalAppData)
    } catch { $refusedChild = $true }
    Assert 'T2 ... and so does a directory INSIDE it' $refusedChild

    $refusedEmpty = $false
    try { [void](Assert-ThrowawayInstallDir -InstallDir '' -RealLocalAppData $realLocalAppData) }
    catch { $refusedEmpty = $true }
    Assert 'T3 ... and an empty directory, which would match every process' $refusedEmpty

    Assert 'T4 this run''s own install dir is accepted (the guard is not simply always-red)' `
        (Assert-ThrowawayInstallDir -InstallDir $installDir -RealLocalAppData $realLocalAppData)
    Assert 'T5 and it is not the user''s directory' `
        ($installDir -ne $userInstallDir)

    Complete-TestBody
    Write-Host ''
    Write-TestVerdict -Pass $script:passes -Fail $script:failures -Skipped $script:skipped `
        -Label 'install-walkthrough TEETH'
}

# -ReleaseSandbox, not a bare suffix: everything launched here is a RELEASE
# build (it came out of a published package), so without the sandbox it would
# dial the agent that owns the user's live sessions.
[void](Set-GhozttyTestIsolation -Tag 't1299' -ReleaseSandbox)

# ---------------------------------------------------------------------------
# Reading a package without msitools. The Windows Installer automation object
# is on every box that can run an MSI at all, which is the whole reason this
# harness can exist here.
# ---------------------------------------------------------------------------
function Get-MsiTableColumn {
    param(
        [Parameter(Mandatory = $true)][string]$Package,
        [Parameter(Mandatory = $true)][string]$Query
    )
    $out = @()
    $inst = New-Object -ComObject WindowsInstaller.Installer
    $db = $inst.OpenDatabase($Package, 0)
    $v = $db.OpenView($Query)
    [void]$v.Execute()
    while ($true) {
        $r = $v.Fetch()
        if ($null -eq $r) { break }
        $out += [string]$r.StringData(1)
    }
    [void]$v.Close()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($v)
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($db)
    # Plain, and every caller wraps the call in `@(...)`: `return ,@()` reads
    # right and is wrong under PS 5.1, which hands an EMPTY array to `@(...)`
    # as ONE element (the trap ThrowawayProduct.ps1 spells out).
    return $out
}

function Get-ArpEntryVersion {
    param([Parameter(Mandatory = $true)][string]$Name)
    foreach ($e in @(Get-ThrowawayUninstallEntries -Identity $Name)) {
        $p = Get-ItemProperty $e.PSPath -ErrorAction SilentlyContinue
        if ($p) { return [string]$p.DisplayVersion }
    }
    return ''
}

function Test-UserPathHas {
    param([Parameter(Mandatory = $true)][string]$Dir)
    $p = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if (-not $p) { return $false }
    foreach ($e in ($p -split ';')) {
        if ($e.TrimEnd('\') -ieq $Dir.TrimEnd('\')) { return $true }
    }
    return $false
}

function Get-UserPathHits {
    param([Parameter(Mandatory = $true)][string]$Dir)
    $p = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if (-not $p) { return 0 }
    return @($p -split ';' | Where-Object { $_.TrimEnd('\') -ieq $Dir.TrimEnd('\') }).Count
}

# msiexec, waited for, with its exit code and its verbose log. `-Wait` holds the
# handle itself, so the T197 empty-ExitCode trap does not apply here.
function Invoke-Msiexec {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$LogName
    )
    $log = Join-Path $work $LogName
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    $args2 = @($Arguments) + @('/l*v', "`"$log`"")
    $p = Start-Process $msiexec -ArgumentList $args2 -Wait -PassThru
    $text = if (Test-Path -LiteralPath $log) {
        $t = Get-Content -LiteralPath $log -Raw -ErrorAction SilentlyContinue
        if ($null -eq $t) { '' } else { $t }
    } else { '' }
    return [pscustomobject]@{ ExitCode = $p.ExitCode; Log = $log; Text = $text }
}

# ---------------------------------------------------------------------------
# The subject: a real package, rewritten to a throwaway identity.
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force $work | Out-Null

function Get-NewestWindowsRelease {
    $out = & gh release list --repo dzearing/ghoztty --limit 30 2>&1 |
        ForEach-Object { $_.ToString() }
    foreach ($line in $out) {
        if ($line -match '(win-v(\d+\.\d+\.\d+))') { return $Matches[1] }
    }
    return ''
}

function Invoke-IdentityRewrite {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Out,
        [string]$ProductVersion = ''
    )
    $a = @('-Msi', $Source, '-Out', $Out, '-Identity', $Identity)
    if ($ProductVersion) { $a += @('-ProductVersion', $ProductVersion) }
    & powershell -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $Repo 'scripts\msi-test-identity.ps1') @a 2>&1 |
        ForEach-Object { $_.ToString() } | Out-Null
    if (Test-Path -LiteralPath $Out) { return $Out }
    return ''
}

$source = ''
$sourceName = ''
if ($Msi) {
    if (Test-Path -LiteralPath $Msi) { $source = (Resolve-Path -LiteralPath $Msi).Path; $sourceName = "-Msi $Msi" }
} else {
    $tag = Get-NewestWindowsRelease
    if ($tag) {
        $ver = $tag -replace '^win-v', ''
        $published = Join-Path $work "Ghoztty-$ver-x64.msi"
        if (-not (Test-Path -LiteralPath $published)) {
            Write-Host "  downloading $tag ..."
            & gh release download $tag --repo dzearing/ghoztty --pattern '*.msi' --dir $work --clobber 2>&1 |
                ForEach-Object { $_.ToString() } | Out-Null
        }
        if (Test-Path -LiteralPath $published) { $source = $published; $sourceName = "published $tag" }
    }
}

if (-not $source) {
    # The package IS the subject here, so there is nothing to substitute. Say so
    # and stop, rather than reporting green over a walk that never happened.
    Write-TestAssertedNothing -Label 'install-walkthrough' -Skipped 1 `
        -Reason 'no package to walk (no -Msi, and no published release could be downloaded - no gh, no network?)'
}

Write-Host "`n== install-walkthrough: $sourceName =="
Write-Host "  package : $source"
Write-Host "  identity: $Identity -> $installDir"

$pathHitsBefore = Get-UserPathHits -Dir $installDir
$userFilesBefore = if (Test-Path $userInstallDir) {
    @(Get-ChildItem $userInstallDir -Recurse -File -ErrorAction SilentlyContinue).Count
} else { -1 }
$userExeStampBefore = if (Test-Path (Join-Path $userInstallDir 'ghoztty.exe')) {
    (Get-Item (Join-Path $userInstallDir 'ghoztty.exe')).LastWriteTimeUtc.Ticks
} else { 0 }

$desktopUp = $false
try {

# =============================================================== A. the package
Write-Host "`n-- A. the package, rewritten to a throwaway identity --"

$sourceVersion = Get-MsiProperty -Msi $source -Name 'ProductVersion'
Write-Host "  ProductVersion: $sourceVersion"

$pkgNew = Invoke-IdentityRewrite -Source $source -Out (Join-Path $work "walk-$sourceVersion.msi")
Assert 'A1 the package was rewritten to the throwaway identity' ($pkgNew -ne '')
if (-not $pkgNew) {
    Write-TestAssertedNothing -Label 'install-walkthrough' -Skipped 1 `
        -Reason 'the identity rewrite produced nothing - the walk cannot run against the real product'
}

$pkgOld = ''
if ([version]$sourceVersion -gt [version]$OldProductVersion) {
    $pkgOld = Invoke-IdentityRewrite -Source $source `
        -Out (Join-Path $work "walk-$sourceVersion-as-$OldProductVersion.msi") `
        -ProductVersion $OldProductVersion
}

Assert 'A2 it is the throwaway product, by name' `
    ((Get-MsiProperty -Msi $pkgNew -Name 'ProductName') -eq $Identity)
$upgradeCode = Get-MsiProperty -Msi $pkgNew -Name 'UpgradeCode'
Assert 'A3 its UpgradeCode is NOT the shipping product''s' `
    ($upgradeCode -ne '' -and $upgradeCode -ne '{5EB02044-7F06-498B-B7A9-7EFD65486CFB}')

$customActions = @(Get-MsiTableColumn -Package $pkgNew -Query 'SELECT `Action` FROM `CustomAction`')
$hasMaintenancePrompt = ($customActions -contains 'MaintenancePrompt')
Write-Host "  maintenance prompt in this package: $hasMaintenancePrompt"

# T1301, found by F5 on this harness's first run and fixed in the rewriter: a
# component with an EMPTY ComponentId is never registered, so Windows Installer
# does not believe it is installed and does not remove it. The install still
# succeeds, which is what hid it - what fails is the UNINSTALL, silently, and
# C_StartMenuShortcut was the row it happened to. Asked of every row, because
# the next freed string will land somewhere else.
$compIds = @(Get-MsiTableColumn -Package $pkgNew -Query 'SELECT `ComponentId` FROM `Component`')
$blankComps = @($compIds | Where-Object { $_ -eq '' })
Assert "A4 every component in the rewritten package is registered ($($compIds.Count - $blankComps.Count) of $($compIds.Count) have a GUID)" `
    ($compIds.Count -gt 0 -and $blankComps.Count -eq 0)

# ... and the gate that says so can say no. A rewrite whose verification is
# never watched failing is indistinguishable from one that cannot fail, which is
# how T1301 survived three harnesses: the package it produced installed fine.
$negOut = Join-Path $work 'walk-negative-control.msi'
Remove-Item -LiteralPath $negOut -Force -ErrorAction SilentlyContinue
& powershell -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $Repo 'scripts\msi-test-identity.ps1') `
    -Msi $source -Out $negOut -Identity $Identity `
    -NegativeControlBlankComponent 'C_StartMenuShortcut' 2>&1 |
    ForEach-Object { $_.ToString() } | Out-Null
Assert 'A5 a rewrite that blanks one ComponentId is REFUSED, and the package deleted' `
    (-not (Test-Path -LiteralPath $negOut))

# Start from empty, whatever a previous run left behind.
Stop-ThrowawayInstances -InstallDir $installDir -RealLocalAppData $realLocalAppData
Remove-ThrowawayProduct -Identity $Identity -InstallDir $installDir -RealLocalAppData $realLocalAppData

# ============================================================ B. fresh install
Write-Host "`n-- B. a fresh install, the way a person does it --"

# The predecessor when there is one, so C has something to upgrade FROM; the
# package itself otherwise, which still makes B a real fresh install.
$firstPkg = if ($pkgOld) { $pkgOld } else { $pkgNew }
$firstVer = if ($pkgOld) { $OldProductVersion } else { $sourceVersion }

# LAUNCHAPP=0 so the install does not open a terminal on the user's desktop -
# B6 opens one deliberately, on a desktop nobody is looking at.
$b = Invoke-Msiexec -LogName 'b-fresh.log' `
    -Arguments @('/i', "`"$firstPkg`"", '/qn', '/norestart', 'LAUNCHAPP=0')
Assert "B1 msiexec installed it (exit $($b.ExitCode))" ($b.ExitCode -eq 0)
Assert 'B2 all three executables are on disk' `
    ((Test-Path $installedExe) -and
     (Test-Path (Join-Path $installDir 'ghoztty.com')) -and
     (Test-Path (Join-Path $installDir 'ghoztty-agent.exe')))
Assert 'B3 the fallback OpenGL came with them (T1252: without it there is no terminal over RDP)' `
    (Test-Path (Join-Path $installDir 'gl\opengl32.dll'))
Assert 'B4 it registered in Apps & Features at the version it installed' `
    ((Get-ArpEntryVersion -Name $Identity) -eq $firstVer)
Assert 'B5 the install directory is on the user PATH' (Test-UserPathHas -Dir $installDir)
Assert 'B6 a Start Menu shortcut exists' (Test-Path -LiteralPath $shortcut)

$installedVersion = Get-ThrowawayExeVersion -Exe $installedExe
Assert "B7 the installed exe answers +version ('$installedVersion')" ($installedVersion -ne '')

# And the thing the whole package exists to deliver: a window. On a background
# desktop, because a terminal appearing over the user's work is not a test
# result.
New-TestDesktop | Out-Null
$desktopUp = $true
$app = Start-OnTestDesktop -Exe $installedExe -AllowReleaseBuild
$win = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 45000
Assert 'B8 launching the installed exe opens a terminal window' ($win -ne [IntPtr]::Zero)
Stop-ThrowawayInstances -InstallDir $installDir -RealLocalAppData $realLocalAppData

# ================================================================= C. upgrade
Write-Host "`n-- C. an upgrade over the older version --"

if (-not $pkgOld) {
    Skip 'C  upgrade over an older version' `
        "this package is version $sourceVersion, so no lower predecessor can be minted from it"
} else {
    $c = Invoke-Msiexec -LogName 'c-upgrade.log' `
        -Arguments @('/i', "`"$pkgNew`"", '/qn', '/norestart', 'LAUNCHAPP=0')
    Assert "C1 msiexec upgraded it (exit $($c.ExitCode))" ($c.ExitCode -eq 0)
    # T1204: 3010 and 1641 are both "now reboot", which an editor-grade terminal
    # update has no business asking for.
    Assert 'C2 no reboot was demanded' `
        ($c.ExitCode -ne 3010 -and $c.ExitCode -ne 1641)
    # T23's postmortem, in one line: the "upgraded" install had no ghoztty.exe.
    Assert 'C3 the exe SURVIVED the upgrade' (Test-Path $installedExe)
    Assert 'C4 the agent survived it too' (Test-Path (Join-Path $installDir 'ghoztty-agent.exe'))
    Assert "C5 the registered version moved to $sourceVersion" `
        ((Get-ArpEntryVersion -Name $Identity) -eq $sourceVersion)
    Assert 'C6 exactly one product is registered, not two side by side' `
        ((@(Get-ThrowawayUninstallEntries -Identity $Identity)).Count -eq 1)
    Assert 'C7 the PATH entry was not duplicated' `
        ((Get-UserPathHits -Dir $installDir) -eq 1)
}

# ===================================================== D. the same version again
Write-Host "`n-- D. re-running the installer for the version already installed --"

if (-not $hasMaintenancePrompt) {
    # A package published before T1291 has no MaintenancePrompt row, so the
    # silent exit is what it WOULD do, correctly, for the build it is. Asserting
    # the fixed behaviour against it would be asserting the future; asserting
    # the old behaviour would freeze the defect. Name it and move on.
    Skip 'D  the Repair / Cancel prompt' `
        'this package has no MaintenancePrompt custom action - it predates T1291'
} elseif ($script:failures -gt 0) {
    Skip 'D  the Repair / Cancel prompt' 'the install this case re-runs did not come up clean'
} else {
    # /qr, because the prompt is gated on UILevel > 3 on purpose: the in-app
    # updater installs at /qb-! (UILevel 3) and a modal dialog inside an
    # unattended update would hang it forever.
    function Invoke-MaintenanceRun {
        param([Parameter(Mandatory = $true)][string]$Press)
        $log = Join-Path $work "d-maintenance-$($Press.ToLower()).log"
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
        $run = Start-OnTestDesktop -Exe $msiexec -Arguments @(
            '/i', $pkgNew, '/qr', '/norestart', 'LAUNCHAPP=0', '/l*v', $log)
        try { $null = $run.Process.Handle } catch { }

        # The prompt is a child ghoztty.exe out of the install directory. Poll
        # for it rather than guessing a sleep - a cold start on a busy box is
        # slow by design.
        $promptPid = 0
        for ($i = 0; $i -lt 60; $i++) {
            $hit = @(Get-ThrowawayProcesses -InstallDir $installDir -Names @('ghoztty'))
            if ($hit.Count -gt 0) { $promptPid = $hit[0].Id; break }
            Start-Sleep -Milliseconds 500
        }
        $labels = @()
        $target = [IntPtr]::Zero
        $dlg = [IntPtr]::Zero
        if ($promptPid -ne 0) {
            $dlg = Wait-TestWindow -ProcessId $promptPid -Class 'GhozttyConfirmDialog' -TimeoutMs 30000
            if ($dlg -ne [IntPtr]::Zero) {
                # Read every caption BEFORE pressing anything: the press
                # dismisses the dialog and a button read after it answers ''.
                foreach ($btn in (Get-TestChildWindows -Window $dlg -Class 'Button')) {
                    $cap = Get-TestControlText -Control ([IntPtr]$btn.Hwnd)
                    $labels += $cap
                    if ($cap -eq $Press) { $target = [IntPtr]$btn.Hwnd }
                }
            }
        }
        $pressed = $false
        if ($target -ne [IntPtr]::Zero) {
            Send-TestControlClick -Control $target | Out-Null
            $pressed = $true
        }
        $code = $null
        if ($run.Process) {
            if ($run.Process.WaitForExit(120000)) { $code = $run.Process.ExitCode }
        }
        if ($null -eq $code) {
            Stop-Process -Id $run.Pid -Force -ErrorAction SilentlyContinue
            Stop-ThrowawayInstances -InstallDir $installDir -RealLocalAppData $realLocalAppData
        }
        return [pscustomobject]@{ Dialog = $dlg; Labels = $labels; Pressed = $pressed; ExitCode = $code }
    }

    $cancel = Invoke-MaintenanceRun -Press 'Cancel'
    Assert 'D1 the installer says something instead of vanishing: a dialog appears' `
        ($cancel.Dialog -ne [IntPtr]::Zero)
    Assert 'D2 its buttons offer Repair and Cancel' `
        ((($cancel.Labels | Sort-Object) -join '|') -eq 'Cancel|Repair')
    Assert 'D3 Cancel ends the transaction cleanly (1602), not with an error' `
        ($cancel.Pressed -and $cancel.ExitCode -eq 1602)
    Assert 'D4 and Cancel left the install exactly where it was' `
        ((Test-Path $installedExe) -and
         ((Get-ArpEntryVersion -Name $Identity) -eq $sourceVersion))

    $repair = Invoke-MaintenanceRun -Press 'Repair'
    Assert 'D5 Repair runs the repair through to a plain success (0)' `
        ($repair.Pressed -and $repair.ExitCode -eq 0)
    Assert 'D6 and the product is still installed after it' `
        ((Test-Path $installedExe) -and
         ((Get-ArpEntryVersion -Name $Identity) -eq $sourceVersion))
}

# ================================================= E. an older package, after
Write-Host "`n-- E. the older package, over the newer install --"

if (-not $pkgOld) {
    Skip 'E  older package over a newer install' 'no lower predecessor could be minted'
} else {
    $e = Invoke-Msiexec -LogName 'e-older.log' `
        -Arguments @('/i', "`"$pkgOld`"", '/qn', '/norestart', 'LAUNCHAPP=0')
    # 1638 is ERROR_PRODUCT_VERSION - "another version of this product is
    # already installed", the raw engine answer with nothing a person can act
    # on. The package carries a LaunchCondition so the reason is a sentence.
    Assert "E1 it did not just install over the newer one (exit $($e.ExitCode))" `
        ($e.ExitCode -ne 0)
    Assert 'E2 and it is not the bare 1638 with no explanation' ($e.ExitCode -ne 1638)
    Assert 'E3 the reason given is the plain-English one' `
        ($e.Text -match 'A newer version of Ghoztty is already installed')
    Assert "E4 the newer install is untouched (still $sourceVersion)" `
        ((Get-ArpEntryVersion -Name $Identity) -eq $sourceVersion)
    Assert 'E5 and its exe is still there' (Test-Path $installedExe)
}

# ================================================================ F. uninstall
Write-Host "`n-- F. uninstall --"

$productCode = Get-MsiProperty -Msi $pkgNew -Name 'ProductCode'
$f = Invoke-Msiexec -LogName 'f-uninstall.log' -Arguments @('/x', $productCode, '/qn', '/norestart')
Assert "F1 msiexec uninstalled it (exit $($f.ExitCode))" ($f.ExitCode -eq 0)
Assert 'F2 the install directory is gone' (-not (Test-Path $installDir))
Assert 'F3 no Apps & Features entry is left' `
    ((@(Get-ThrowawayUninstallEntries -Identity $Identity)).Count -eq 0)
Assert "F4 the PATH entry is gone (was $pathHitsBefore before this run)" `
    ((Get-UserPathHits -Dir $installDir) -eq $pathHitsBefore)
Assert 'F5 the Start Menu shortcut is gone' (-not (Test-Path -LiteralPath $shortcut))

# =================================================== G. the user's Ghoztty
Write-Host "`n-- G. and the user's own Ghoztty, before and after --"

Assert 'G1 the user''s install directory is still there' (Test-Path $userInstallDir)
$userFilesAfter = if (Test-Path $userInstallDir) {
    @(Get-ChildItem $userInstallDir -Recurse -File -ErrorAction SilentlyContinue).Count
} else { -1 }
Assert "G2 its file count is unchanged ($userFilesBefore -> $userFilesAfter)" `
    ($userFilesAfter -eq $userFilesBefore)
$userExeStampAfter = if (Test-Path (Join-Path $userInstallDir 'ghoztty.exe')) {
    (Get-Item (Join-Path $userInstallDir 'ghoztty.exe')).LastWriteTimeUtc.Ticks
} else { 0 }
Assert 'G3 its ghoztty.exe was not rewritten' ($userExeStampAfter -eq $userExeStampBefore)

# LAST statement of the top-level try (T1039): reaching it is what makes a green
# verdict below a statement about the whole walk.
Complete-TestBody
} finally {
    if (-not $KeepInstall) {
        Stop-ThrowawayInstances -InstallDir $installDir -RealLocalAppData $realLocalAppData
        Remove-ThrowawayProduct -Identity $Identity -InstallDir $installDir -RealLocalAppData $realLocalAppData
        # Belt and braces after F4/F5 have already asserted these are gone: a
        # run that FAILED partway must not leave the box holding a shortcut or a
        # registry key of its own. Named by the THROWAWAY identity and refused
        # otherwise, so this can never reach for the user's shortcut or the
        # user's key: those are called 'Ghoztty', and this run's identity is not.
        if ($Identity -ne 'Ghoztty') {
            Remove-Item -LiteralPath $shortcut -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath "HKCU:\Software\dzearing\$Identity" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if ($desktopUp) { Remove-TestDesktop | Out-Null }
}

# --- stamp (T783) ----------------------------------------------------------
# Only a clean, fully-run walk re-stamps. A run that skipped a case (a package
# that predates the feature, no predecessor to upgrade from) did not cover
# everything the row claims, so it leaves the guard due.
if ($script:failures -eq 0 -and $script:skipped -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard install-walkthrough -Repo $Repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:passes -Fail $script:failures -Skipped $script:skipped `
    -Label 'install-walkthrough'
