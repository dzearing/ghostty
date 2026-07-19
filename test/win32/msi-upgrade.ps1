# T23 acceptance: MSI install -> major upgrade -> uninstall, end to end.
#
# The 26.7.502 postmortem: on major upgrade, file costing ran before the
# early RemoveExistingProducts removed the old product's files, and wixl's
# empty File.Version made the packaged exe "unversioned" -- so InstallFiles
# skipped the exe copy, RExP deleted the old exe, and the "upgraded" install
# had no ghoztty.exe. The fix (build-msi.sh): per-build FILEVERSION stamped
# into the exe AND mirrored into the MSI File table, plus an emptied
# MsiFileHash table so unchanged unversioned share/ files are recopied
# instead of skipped-then-deleted.
#
# This script drives a THROWAWAY product identity (GhozttyT23Test: its own
# name, install dir, UpgradeCode, registry key, component-GUID namespace)
# built by build-msi.sh --test-identity, so the real Ghoztty product and
# install dir are never touched. Build inputs (see windows-parity-details.md
# T23 for the exact recipe):
#   zig build -Dapp-runtime=win32 -Doptimize=Debug -Dwindows-file-version=26.7.19.1
#   build-msi.sh --skip-build --test-identity GhozttyT23Test --build-num 1 --version t23v1 --out zig-out/t23-v1.msi
#   (same again with .2 / --build-num 2 / t23-v2.msi)
param(
    [string]$MsiV1,
    [string]$MsiV2,
    [string]$TestName = 'GhozttyT23Test',
    [string]$V1FileVer = '26.7.19.1',
    [string]$V2FileVer = '26.7.19.2',
    [string]$V2ProductVer = '26.7.1902'
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $MsiV1) { $MsiV1 = Join-Path $repo 'zig-out\t23-v1.msi' }
if (-not $MsiV2) { $MsiV2 = Join-Path $repo 'zig-out\t23-v2.msi' }

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

$installDir = Join-Path $env:LOCALAPPDATA "Programs\$TestName"
# Per-user MSI products register their Apps & Features entry via the Windows
# Installer service; depending on package platform / Windows version the key
# lands in HKCU, HKLM 64-bit, or HKLM WOW6432Node -- search all three.
$uninstRoots = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

function Get-TestUninstallEntries {
    foreach ($root in $uninstRoots) {
        Get-ChildItem $root -ErrorAction SilentlyContinue | Where-Object {
            (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DisplayName -eq $TestName
        }
    }
}

function Invoke-Msi([string[]]$msiArgs, [string]$label) {
    $p = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
    Assert ($p.ExitCode -eq 0) "$label (msiexec exit $($p.ExitCode))"
    return $p.ExitCode
}

function Remove-TestProduct {
    foreach ($e in @(Get-TestUninstallEntries)) {
        $code = Split-Path $e.PSPath -Leaf
        Start-Process msiexec.exe -ArgumentList @('/x', $code, '/qn') -Wait | Out-Null
    }
    if (Test-Path $installDir) { Remove-Item $installDir -Recurse -Force -ErrorAction SilentlyContinue }
}

function Get-UserPathEntryCount {
    $val = (Get-ItemProperty 'HKCU:\Environment' -ErrorAction SilentlyContinue).Path
    if (-not $val) { return 0 }
    @($val -split ';' | Where-Object { $_.TrimEnd('\') -ieq $installDir.TrimEnd('\') }).Count
}

function Test-ExeRuns([string]$label) {
    $exe = Join-Path $installDir 'ghoztty.exe'
    $out = Join-Path $env:TEMP 't23-version-out.txt'
    $p = Start-Process $exe -ArgumentList '+version' -RedirectStandardOutput $out `
        -NoNewWindow -PassThru
    if (-not $p.WaitForExit(15000)) {
        try { $p.Kill() } catch {}
        Assert $false "$label (+version hung)"
        return
    }
    $text = ''
    if (Test-Path $out) { $text = [IO.File]::ReadAllText($out) }
    Assert ($text -match 'ersion') "$label (+version output)"
}

if (-not (Test-Path $MsiV1) -or -not (Test-Path $MsiV2)) {
    Write-Host "SETUP FAIL: missing $MsiV1 / $MsiV2 (build both throwaway MSIs first)" -ForegroundColor Red
    exit 1
}

Write-Host "== pre-clean any leftover $TestName install =="
Remove-TestProduct

Write-Host "== install v1 =="
$log1 = Join-Path $env:TEMP 't23-install-v1.log'
Invoke-Msi @('/i', "`"$MsiV1`"", '/qn', '/l*v', "`"$log1`"") 'v1 install' | Out-Null
$exePath = Join-Path $installDir 'ghoztty.exe'
Assert (Test-Path $exePath) 'v1: exe present'
$v1Ver = ''
if (Test-Path $exePath) { $v1Ver = (Get-Item $exePath).VersionInfo.FileVersionRaw.ToString() }
Assert ($v1Ver -eq $V1FileVer) "v1: exe FileVersion $v1Ver == $V1FileVer"
Assert (Test-Path (Join-Path $installDir 'share\terminfo\ghostty.terminfo')) 'v1: terminfo sentinel present'
$v1Count = 0
if (Test-Path $installDir) { $v1Count = @(Get-ChildItem $installDir -Recurse -File).Count }
Assert ($v1Count -gt 400) "v1: file count sane ($v1Count files)"
$v1Entries = @(Get-TestUninstallEntries)
Assert ($v1Entries.Count -eq 1) "v1: exactly one Apps & Features entry ($($v1Entries.Count))"
$v1Code = if ($v1Entries.Count -ge 1) { Split-Path $v1Entries[0].PSPath -Leaf } else { '' }
Assert ((Get-UserPathEntryCount) -eq 1) 'v1: user PATH entry present once'
Test-ExeRuns 'v1: exe runs'

Write-Host "== upgrade to v2 =="
$log2 = Join-Path $env:TEMP 't23-install-v2.log'
Invoke-Msi @('/i', "`"$MsiV2`"", '/qn', '/l*v', "`"$log2`"") 'v2 upgrade' | Out-Null
Assert (Test-Path $exePath) 'v2: exe STILL PRESENT after major upgrade (the 26.7.502 bug)'
$v2Ver = ''
if (Test-Path $exePath) { $v2Ver = (Get-Item $exePath).VersionInfo.FileVersionRaw.ToString() }
Assert ($v2Ver -eq $V2FileVer) "v2: exe FileVersion $v2Ver == $V2FileVer (new exe copied)"
Assert (Test-Path (Join-Path $installDir 'share\terminfo\ghostty.terminfo')) 'v2: terminfo sentinel survived upgrade'
$v2Count = 0
if (Test-Path $installDir) { $v2Count = @(Get-ChildItem $installDir -Recurse -File).Count }
Assert ($v2Count -eq $v1Count) "v2: all files survived upgrade ($v2Count == $v1Count)"
$disallow = Select-String -Path $log2 -Pattern 'Disallowing installation of component' -SimpleMatch -Quiet
Assert (-not $disallow) 'v2: no "Disallowing installation" skips in upgrade log'
$v2Entries = @(Get-TestUninstallEntries)
Assert ($v2Entries.Count -eq 1) "v2: exactly one Apps & Features entry ($($v2Entries.Count))"
$v2Code = if ($v2Entries.Count -ge 1) { Split-Path $v2Entries[0].PSPath -Leaf } else { '' }
Assert ($v2Code -ne $v1Code) 'v2: entry is the new product (old product removed)'
$v2Display = if ($v2Entries.Count -ge 1) { (Get-ItemProperty $v2Entries[0].PSPath).DisplayVersion } else { '' }
Assert ($v2Display -eq $V2ProductVer) "v2: DisplayVersion $v2Display == $V2ProductVer"
Assert ((Get-UserPathEntryCount) -eq 1) 'v2: user PATH entry still present exactly once'
Test-ExeRuns 'v2: exe runs'

Write-Host "== uninstall =="
if ($v2Code) {
    Invoke-Msi @('/x', $v2Code, '/qn') 'uninstall' | Out-Null
} else {
    Assert $false 'uninstall (no product code found)'
}
Assert (-not (Test-Path $installDir)) 'uninstall: install dir removed'
Assert (@(Get-TestUninstallEntries).Count -eq 0) 'uninstall: Apps & Features entry removed'
Assert ((Get-UserPathEntryCount) -eq 0) 'uninstall: user PATH entry removed'

# The box carries a ghost of the broken 26.7.502 install: the product is
# registered but its files are long gone (the vanishing-exe bug deleted the
# exe; the dir was later overwritten by script-delivered files). The fixed
# MSI must recover that state on upgrade: RExP unregisters the ghost and,
# because nothing is ever skipped by costing anymore, every file is laid
# down fresh. Simulate exactly that: install v1, delete its files behind
# the installer's back, then upgrade to v2.
Write-Host "== ghost recovery (registered product, files deleted) =="
Invoke-Msi @('/i', "`"$MsiV1`"", '/qn') 'ghost: v1 install' | Out-Null
Remove-Item $installDir -Recurse -Force
Assert (-not (Test-Path $installDir)) 'ghost: files deleted behind installer'
$log3 = Join-Path $env:TEMP 't23-install-ghost.log'
Invoke-Msi @('/i', "`"$MsiV2`"", '/qn', '/l*v', "`"$log3`"") 'ghost: v2 upgrade over ghost' | Out-Null
Assert (Test-Path $exePath) 'ghost: exe present after upgrade over ghost'
$gVer = ''
if (Test-Path $exePath) { $gVer = (Get-Item $exePath).VersionInfo.FileVersionRaw.ToString() }
Assert ($gVer -eq $V2FileVer) "ghost: exe FileVersion $gVer == $V2FileVer"
$gCount = 0
if (Test-Path $installDir) { $gCount = @(Get-ChildItem $installDir -Recurse -File).Count }
Assert ($gCount -eq $v1Count) "ghost: full file tree restored ($gCount == $v1Count)"
$gEntries = @(Get-TestUninstallEntries)
Assert ($gEntries.Count -eq 1) "ghost: exactly one Apps & Features entry ($($gEntries.Count))"
Write-Host "== final cleanup =="
Remove-TestProduct
Assert (-not (Test-Path $installDir)) 'cleanup: install dir removed'
Assert (@(Get-TestUninstallEntries).Count -eq 0) 'cleanup: no Apps & Features entries left'
Assert ((Get-UserPathEntryCount) -eq 0) 'cleanup: user PATH entry removed'

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red }
exit ([int]($script:fail -ne 0))
