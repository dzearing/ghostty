# T1194 acceptance: the in-app update, all the way through msiexec SUCCEEDING.
#
# T1178's harness (test\win32\update-apply.ps1) drives the whole update path
# against canned feeds and a canned "package", and stops one inch short on
# purpose: it runs msiexec against a package msiexec REJECTS, because a real
# install would replace the user's Ghoztty. So "the new version is actually on
# disk afterwards" was the one claim nothing could make.
#
# This closes it, with two REAL published releases and no rebuild:
#
#   * `scripts\msi-test-identity.ps1` rewrites each published
#     `Ghoztty-<v>-x64.msi` into a throwaway product - its own ProductCode,
#     UpgradeCode, install directory, component GUIDs, registry key and Start
#     Menu name. The payload, the sequences and the custom actions are the
#     published ones; only the identity moves. Installing it therefore lands
#     in %LOCALAPPDATA%\Programs\GhozttyT1194Test and cannot upgrade, remove
#     or refcount anything belonging to the user's Ghoztty.
#   * The older release is installed for real. The app is then pointed at a
#     canned feed offering the newer release, and downloads and stages it the
#     way it would from GitHub. The applier is armed exactly as `arm()` arms
#     it - a copy of the exe in the staging directory, the spec in
#     GHOZTTY_UPDATE_APPLY - and msiexec is expected to exit 0.
#
# What is deliberately NOT driven here: the tray balloon click and the "Install
# and Restart" confirmation. Those are two mouse events in front of
# `applyStagedUpdate`, and update-apply.ps1 already covers the shape on the
# other side of them. Everything from the staged package onward is real.
#
# Sections:
#   A  packages: the published MSIs, rewritten to a throwaway identity
#   B  install the older release for real (msiexec exit 0)
#   C  the app finds the newer release and stages its package
#   D  the applier installs it (msiexec exit 0) and the version moves
#   E  nothing is left behind, and the user's Ghoztty was never touched
# preflight: none - the binaries here come out of a PUBLISHED MSI, so they are
# release builds by definition and `Assert-GhozttyIsolatedBuild` would refuse
# them. The isolation is bought a different way: `-ReleaseSandbox` below gives
# the run its own pipe, its own agent lineage and its own LOCALAPPDATA, and the
# product itself is a throwaway identity installed in its own directory, which
# section E measures against the user's install on every run.
param(
    [string]$Identity = 'GhozttyT1194Test',
    [string]$OldTag = 'win-v1.35.0',
    [string]$NewTag = 'win-v1.36.0',
    [switch]$KeepInstall
)
$ErrorActionPreference = 'Stop'

# The install directory is chosen by Windows Installer from the SHELL's idea of
# LocalAppData, which -ReleaseSandbox below is about to move out from under
# $env:LOCALAPPDATA. Capture the real one FIRST or every path assertion in this
# file points at the sandbox and passes while measuring nothing.
$realLocalAppData = $env:LOCALAPPDATA

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$env:GHOZTTY_NO_STARTUP_ESCAPE = '1'
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
# -ReleaseSandbox, not a bare suffix: everything this script launches is a
# RELEASE build (it is a published package), so without the sandbox it would
# dial the agent that owns the user's live sessions and stage its package into
# the user's own updates directory.
[void](Set-GhozttyTestIsolation -Tag 't1194' -ReleaseSandbox)

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$work = Join-Path $env:TEMP 'ghoztty-t1194'
New-Item -ItemType Directory -Force $work | Out-Null

$oldVer = $OldTag -replace '^win-v', ''
$newVer = $NewTag -replace '^win-v', ''
$installDir = Join-Path $realLocalAppData "Programs\$Identity"
$userInstallDir = Join-Path $realLocalAppData 'Programs\Ghoztty'
$stagingDir = Join-Path $env:LOCALAPPDATA 'ghoztty\updates'

$script:pass = 0
$script:fail = 0
$script:skip = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Skip([string]$label) { $script:skip++; Write-Host "SKIP  $label" -ForegroundColor Yellow }

# Per-user MSI products register their Apps & Features entry through the
# Windows Installer service, and depending on package platform and Windows
# version the key lands in HKCU, HKLM 64-bit or HKLM WOW6432Node. Search all
# three (the same three msi-upgrade.ps1 learned to search).
$uninstRoots = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
function Get-TestUninstallEntries {
    foreach ($root in $uninstRoots) {
        Get-ChildItem $root -ErrorAction SilentlyContinue | Where-Object {
            (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DisplayName -eq $Identity
        }
    }
}
function Remove-TestProduct {
    foreach ($e in @(Get-TestUninstallEntries)) {
        $code = Split-Path $e.PSPath -Leaf
        Start-Process msiexec.exe -ArgumentList @('/x', $code, '/qn') -Wait | Out-Null
    }
    if (Test-Path $installDir) {
        Remove-Item $installDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
function Get-UserPathEntryCount {
    $p = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if (-not $p) { return 0 }
    return @($p -split ';' | Where-Object { $_ -ne '' }).Count
}
function Get-TestProcesses([string[]]$Names) {
    $out = @()
    foreach ($name in $Names) {
        foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $path = try { $p.Path } catch { $null }
            if ($path -and $path.StartsWith($installDir, [StringComparison]::OrdinalIgnoreCase)) { $out += $p }
        }
    }
    return $out
}

function Stop-TestInstances {
    # Only processes running out of the THROWAWAY install directory. The user's
    # Ghoztty is a different image in a different directory and is never a
    # candidate - which is the same rule the repo applies to its own builds.
    #
    # -AppOnly leaves the agent and its per-session pty-host holders alone,
    # which is what a real update does: the app closes, the holders keep the
    # user's shells alive, and the installer renames their image aside rather
    # than asking the Restart Manager to terminate them.
    param([switch]$AppOnly)
    $names = if ($AppOnly) { @('ghoztty') } else { @('ghoztty', 'ghoztty-agent') }
    foreach ($name in $names) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            $path = try { $_.Path } catch { $null }
            if ($path -and $path.StartsWith($installDir, [StringComparison]::OrdinalIgnoreCase)) {
                try { $_.Kill() } catch {}
            }
        }
    }
    Start-Sleep -Milliseconds 500
}

function Get-ExeVersion([string]$exe) {
    # `+version` over a private endpoint (Set-GhozttyTestIsolation above), so
    # the answer is about THIS binary and never about the user's running app.
    #
    # Ask the `.com` console twin when it is there: ghoztty.exe is
    # GUI-subsystem in a release build and has no console to print to. And the
    # banner still says "Ghostty" - the fork kept upstream's wording in
    # src/cli/version.zig - so the version is read from the `- version:` line,
    # which is spelled the same either way.
    $com = [IO.Path]::ChangeExtension($exe, '.com')
    $bin = if (Test-Path $com) { $com } else { $exe }
    # Stringified before Out-String (T883): a merged stream handed to the
    # formatter is wrapped at the HOST's width, so the `- version:` line can
    # arrive folded and the match silently fails on a narrow console.
    $out = & $bin +version 2>&1 | ForEach-Object { $_.ToString() } | Out-String
    if ($out -match '(?m)^\s*-\s*version:\s*(\d+\.\d+\.\d+)') { return $Matches[1] }
    if ($out -match '(?m)^Gho[sz]tty\s+(\d+\.\d+\.\d+)') { return $Matches[1] }
    return ''
}

$pathBefore = Get-UserPathEntryCount
$userInstallBefore = if (Test-Path $userInstallDir) {
    @(Get-ChildItem $userInstallDir -Recurse -File -ErrorAction SilentlyContinue).Count
} else { -1 }
$userExeVersionBefore = if (Test-Path (Join-Path $userInstallDir 'ghoztty.exe')) {
    (Get-Item (Join-Path $userInstallDir 'ghoztty.exe')).LastWriteTimeUtc.Ticks
} else { 0 }

try {

# =========================================================== A. packages
Write-Host "`n-- A. throwaway packages from the published releases --"

function Get-TestPackage([string]$tag, [string]$ver) {
    $published = Join-Path $work "Ghoztty-$ver-x64.msi"
    $rewritten = Join-Path $work "test-$ver.msi"
    if (-not (Test-Path $published)) {
        Write-Host "  downloading $tag ..."
        & gh release download $tag --repo dzearing/ghoztty --pattern '*.msi' --dir $work --clobber 2>&1 | Out-Null
    }
    if (-not (Test-Path $published)) { return $null }
    if (-not (Test-Path $rewritten) -or
        (Get-Item $rewritten).LastWriteTimeUtc -lt (Get-Item $published).LastWriteTimeUtc) {
        & powershell -NoProfile -File (Join-Path $repo 'scripts\msi-test-identity.ps1') `
            -Msi $published -Out $rewritten -Identity $Identity 2>&1 | Out-Null
    }
    if (-not (Test-Path $rewritten)) { return $null }
    return $rewritten
}

$msiOld = Get-TestPackage $OldTag $oldVer
$msiNew = Get-TestPackage $NewTag $newVer

if (-not $msiOld -or -not $msiNew) {
    # No network, or no `gh`. The published package IS the subject of this
    # harness, so there is nothing to substitute - say so and stop, rather
    # than reporting green over a test that never ran.
    Skip "A: could not obtain both published packages ($OldTag, $NewTag)"
    Write-Host "`nSKIPPED (no published packages available)"
    exit 0
}
Assert (Test-Path $msiOld) "A: $OldTag rewritten to the $Identity identity"
Assert (Test-Path $msiNew) "A: $NewTag rewritten to the $Identity identity"

# The two packages must share ONE UpgradeCode, or the newer one installs
# beside the older instead of replacing it - which would pass every version
# check below while testing the opposite of an upgrade.
function Get-MsiProperty([string]$msi, [string]$name) {
    $inst = New-Object -ComObject WindowsInstaller.Installer
    $db = $inst.OpenDatabase($msi, 0)
    $v = $db.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$name'")
    [void]$v.Execute()
    $r = $v.Fetch()
    $out = if ($null -eq $r) { '' } else { [string]$r.StringData(1) }
    [void]$v.Close()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($v)
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($db)
    return $out
}
$upOld = Get-MsiProperty $msiOld 'UpgradeCode'
$upNew = Get-MsiProperty $msiNew 'UpgradeCode'
Assert ($upOld -eq $upNew -and $upOld -ne '') 'A: both packages share one throwaway UpgradeCode'
Assert ($upOld -ne '{5EB02044-7F06-498B-B7A9-7EFD65486CFB}') "A: that UpgradeCode is NOT the shipping product's"
Assert ((Get-MsiProperty $msiOld 'ProductName') -eq $Identity) 'A: the older package is the throwaway product'

# ================================================ B. install the old release
Write-Host "`n-- B. install $OldTag for real --"
Stop-TestInstances
Remove-TestProduct

$installLog = Join-Path $work 'install-old.log'
# LAUNCHAPP=0 so a successful install does not open a terminal window on the
# user's desktop; /qn because nobody is watching this one.
$p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$msiOld`"", '/qn', '/norestart',
    'LAUNCHAPP=0', '/l*v', "`"$installLog`"") -Wait -PassThru
$null = $p.Handle
Assert ($p.ExitCode -eq 0) "B: msiexec installed $OldTag (exit $($p.ExitCode))"

$testExe = Join-Path $installDir 'ghoztty.exe'
Assert (Test-Path $testExe) "B: ghoztty.exe is in $installDir"
Assert (Test-Path (Join-Path $installDir 'ghoztty-agent.exe')) 'B: the agent came with it'
$verInstalled = Get-ExeVersion $testExe
Assert ($verInstalled -eq $oldVer) "B: it reports $oldVer (got '$verInstalled')"
Assert ((@(Get-TestUninstallEntries)).Count -ge 1) 'B: it registered as its own product in Apps & Features'

# ============================================ C. the app stages the update
Write-Host "`n-- C. the app finds $NewTag and stages its package --"

# The asset URL must sit under /download/<tag>/ - that is how the scanner
# proves an asset belongs to the release it is offering - so the package is
# published locally under a directory tree of exactly that shape.
$assetDir = Join-Path $work "download\$NewTag"
New-Item -ItemType Directory -Force $assetDir | Out-Null
$assetMsi = Join-Path $assetDir "Ghoztty-$newVer-x64.msi"
Copy-Item $msiNew $assetMsi -Force
$assetUrl = 'file:///' + ($assetMsi -replace '\\', '/')
$feedPath = Join-Path $work 'feed.json'
[IO.File]::WriteAllText($feedPath,
    '[{"tag_name":"v1.0.0","assets":[]},' +
    '{"tag_name":"' + $NewTag + '","assets":[{"browser_download_url":"' + $assetUrl + '"}]}]')
$feedUrl = 'file:///' + ($feedPath -replace '\\', '/')

if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue }

$env:GHOZTTY_UPDATE_URL = $feedUrl
# The check re-runs on a timer, and this is the knob update-check.ps1 already
# uses to watch a second tick. Without it the harness gets exactly one attempt
# at startup and a slow launch reads as "the app never offered the update" -
# which it did, once, on a box busy with the rest of a floor run.
$env:GHOZTTY_UPDATE_RECHECK_MS = '10000'
$app = $null
try {
    $app = Start-Process -FilePath $testExe -PassThru
    $null = $app.Handle
    # The check runs in the background at startup and the download follows it;
    # poll for the staged package rather than guessing a sleep. A released
    # build is GUI-subsystem, so its log lines are not available to read.
    $staged = $null
    for ($i = 0; $i -lt 120; $i++) {
        Start-Sleep -Seconds 1
        if (Test-Path $stagingDir) {
            $hit = @(Get-ChildItem $stagingDir -Filter '*.msi' -File -ErrorAction SilentlyContinue)
            if ($hit.Count -gt 0) { $staged = $hit[0].FullName; break }
        }
    }
} finally {
    Remove-Item Env:GHOZTTY_UPDATE_URL -ErrorAction SilentlyContinue
    Remove-Item Env:GHOZTTY_UPDATE_RECHECK_MS -ErrorAction SilentlyContinue
}

Assert ($null -ne $staged) "C: the app downloaded and staged a package into $stagingDir"
if ($staged) {
    Assert ((Get-Item $staged).Length -eq (Get-Item $msiNew).Length) 'C: the staged bytes are the package it was offered'
    Assert ($staged -like "*$newVer*") "C: it staged the $newVer package"
}

# The applier refuses to install while the app it must replace is running, and
# it is right to. Close the APP the way a real update does - and deliberately
# leave the agent and its per-session pty-host holders running, because those
# outliving the terminal is the whole feature the rename-aside design protects.
$holdersBefore = @(Get-TestProcesses @('ghoztty-agent'))
Stop-TestInstances -AppOnly

# =============================================== D. the applier installs it
Write-Host "`n-- D. the applier runs msiexec and the version moves --"

if (-not $staged) {
    Skip 'D: nothing was staged to install'
} else {
    # Exactly the shape `arm()` produces: a COPY of the exe in the staging
    # directory (an applier running out of the directory it clears would
    # rename its own image aside), and the spec in the environment. The pid it
    # waits on has already exited, so the wait is satisfied at once.
    $applier = Join-Path $stagingDir 'ghoztty-updater.exe'
    Copy-Item $testExe $applier -Force
    $dead = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'exit' -PassThru -WindowStyle Hidden
    $null = $dead.Handle
    [void]$dead.WaitForExit(10000)

    $env:GHOZTTY_UPDATE_APPLY = "$($dead.Id)|$staged|$testExe"
    try {
        $ap = Start-Process -FilePath $applier -PassThru
        $null = $ap.Handle
        $exited = $ap.WaitForExit(300000)
    } finally {
        Remove-Item Env:GHOZTTY_UPDATE_APPLY -ErrorAction SilentlyContinue
    }
    if (-not $exited) { try { $ap.Kill() } catch {} }

    Assert $exited 'D: the applier finished instead of hanging'
    # THE claim this harness exists to make. The applier returns 0 only when
    # msiexec returned 0 (or 3010) AND the terminal came back.
    Assert ($ap.ExitCode -eq 0) "D: msiexec SUCCEEDED and the terminal relaunched (applier exit $($ap.ExitCode))"

    # msiexec's own verbose log lands beside the package. It is often gone by
    # the time this reads: the applier RELAUNCHES the terminal, and a launching
    # app sweeps its staging directory (App.zig, `update_install.sweep`). Both
    # outcomes are evidence - one of msiexec's verdict, the other of the sweep
    # that clears the directory after an update - so both are checked, and
    # neither is allowed to be "the file is simply missing".
    $msiLog = Join-Path $stagingDir 'install.log'
    if (Test-Path $msiLog) {
        $logText = [IO.File]::ReadAllText($msiLog)
        Assert ($logText -match 'success or error status: 0') 'D: msiexec''s own log records success'
    } else {
        $pkgLeft = @(Get-ChildItem $stagingDir -Filter '*.msi' -File -ErrorAction SilentlyContinue)
        Assert ($pkgLeft.Count -eq 0) "D: the relaunched app already swept the package and the log ($($pkgLeft.Count) left)"
    }

    # The claim the rename-aside design exists to make: a session's holder
    # keeps running the image it already mapped, so the shells behind the
    # user's panes are still there after the installer replaced the files
    # underneath them. Nothing else in the suite can observe this - it needs a
    # real msiexec run over real running holders.
    if ($holdersBefore.Count -eq 0) {
        Skip 'D: no agent/holder was running to carry through the update'
    } else {
        $survived = 0
        foreach ($h in $holdersBefore) {
            if (-not $h.HasExited) { $survived++ }
        }
        Assert ($survived -eq $holdersBefore.Count) `
            "D: every session holder survived the install ($survived of $($holdersBefore.Count))"
    }

    # The relaunch is a real terminal and it belongs to this harness now.
    Stop-TestInstances

    $verAfter = Get-ExeVersion $testExe
    Assert ($verAfter -eq $newVer) "D: the installed build now reports $newVer (got '$verAfter')"

    $entries = @(Get-TestUninstallEntries)
    $displayed = if ($entries.Count -gt 0) {
        (Get-ItemProperty $entries[0].PSPath -ErrorAction SilentlyContinue).DisplayVersion
    } else { '' }
    Assert ($entries.Count -eq 1) "D: still ONE product in Apps & Features (an upgrade, not a second install) - found $($entries.Count)"
    # Apps & Features shows the MSI's numeric ProductVersion (yy.m.dNN), not
    # the semver - these packages carry no ARPDISPLAYVERSION - so the check is
    # that the REGISTERED product moved from the old package's number to the
    # new one's. Anything else means the update installed beside the old
    # product rather than over it.
    $prodOld = Get-MsiProperty $msiOld 'ProductVersion'
    $prodNew = Get-MsiProperty $msiNew 'ProductVersion'
    Assert ($prodOld -ne $prodNew) "D: the two packages have different ProductVersions ($prodOld / $prodNew)"
    Assert ($displayed -eq $prodNew) "D: the registered product is now $prodNew, was $prodOld (got '$displayed')"
}

# ================================================= E. nothing left behind
Write-Host "`n-- E. nothing left behind, nothing of the user's touched --"

if ($staged) {
    Assert (-not (Test-Path $staged)) 'E: the staged package was deleted after a successful install'
} else {
    Skip 'E: nothing was staged, so there is nothing to have been cleaned up'
}
# A holder that survived the install is still running the OLD agent image, and
# the installer got it out of msiexec's way by renaming it rather than killing
# the process - so a `.old-<stamp>` file here is the expected state, not a
# leak. What the task asks is that it does not OUTLIVE the holders.
$sidelined = @(Get-ChildItem $installDir -Filter '*.old-*' -File -Recurse -ErrorAction SilentlyContinue)
if ($holdersBefore.Count -gt 0) {
    Assert ($sidelined.Count -ge 1) 'E: the old agent image was renamed aside rather than the holder killed'
} else {
    Assert ($sidelined.Count -eq 0) "E: nothing was sidelined when no holder was running ($($sidelined.Count))"
}

# Two things survive the update's own sweep by design, both because they were
# in use at the time: the applier's copy of the exe (it was running the sweep's
# sibling) and any sidelined image a holder still had mapped. "Still in use is
# the normal answer... the next launch tries again" (update_install.sweep).
# The holders are stopped by now, so this launch is that next one - and it is
# the only thing that can prove the leftovers are temporary rather than
# permanent.
$again = Start-Process -FilePath $testExe -PassThru
$null = $again.Handle
$clean = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    $stagedLeft = @(Get-ChildItem $stagingDir -File -ErrorAction SilentlyContinue)
    $oldLeft = @(Get-ChildItem $installDir -Filter '*.old-*' -File -Recurse -ErrorAction SilentlyContinue)
    if ($stagedLeft.Count -eq 0 -and $oldLeft.Count -eq 0) { $clean = $true; break }
}
Stop-TestInstances
$leftNames = @()
foreach ($f in @(Get-ChildItem $stagingDir -File -ErrorAction SilentlyContinue)) { $leftNames += $f.Name }
foreach ($f in @(Get-ChildItem $installDir -Filter '*.old-*' -File -Recurse -ErrorAction SilentlyContinue)) { $leftNames += $f.Name }
Assert $clean "E: the next launch swept everything the update left ($($leftNames -join ', '))"

# The whole reason a throwaway identity was worth building. If any of these
# three moved, the test upgraded the user's terminal.
Assert (Test-Path $userInstallDir) 'E: the user''s Ghoztty install directory is still there'
$userInstallAfter = if (Test-Path $userInstallDir) {
    @(Get-ChildItem $userInstallDir -Recurse -File -ErrorAction SilentlyContinue).Count
} else { -1 }
Assert ($userInstallAfter -eq $userInstallBefore) "E: its file count is unchanged ($userInstallBefore -> $userInstallAfter)"
$userExeVersionAfter = if (Test-Path (Join-Path $userInstallDir 'ghoztty.exe')) {
    (Get-Item (Join-Path $userInstallDir 'ghoztty.exe')).LastWriteTimeUtc.Ticks
} else { 0 }
Assert ($userExeVersionAfter -eq $userExeVersionBefore) 'E: the user''s ghoztty.exe was not rewritten'

} finally {
    if (-not $KeepInstall) {
        Write-Host "`n-- cleanup --"
        Stop-TestInstances
        Remove-TestProduct
        $pathAfter = Get-UserPathEntryCount
        Assert ($pathAfter -eq $pathBefore) "cleanup: the user PATH is back to $pathBefore entries (got $pathAfter)"
        Assert (-not (Test-Path $installDir)) 'cleanup: the throwaway install directory is gone'
        Assert ((@(Get-TestUninstallEntries)).Count -eq 0) 'cleanup: no throwaway product left registered'
        Remove-Item (Join-Path $env:LOCALAPPDATA 'ghoztty\updates') -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "`n-- cleanup SKIPPED (-KeepInstall) --"
    }
}

Write-Host ''
# --- stamp (T783) ----------------------------------------------------------
# Only a clean, fully-run sweep re-stamps. A run that SKIPPED (no network, no
# `gh`, no published packages) proves nothing about the code and must leave the
# guard due.
if ($script:fail -eq 0 -and $script:skip -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard update-real-msi -Repo $repo 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

if ($script:fail -eq 0) { Write-Host "ALL PASS ($($script:pass) checks, $($script:skip) skipped)" }
else { Write-Host "$($script:fail) FAILURE(S) ($($script:pass) passed)" -ForegroundColor Red }
exit ([int]($script:fail -gt 0))
