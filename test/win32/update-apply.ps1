# T1178 acceptance: the Windows in-app update (download + apply the MSI).
#
# T24 gave Windows an update NOTIFICATION. This is the other half: the app
# finds the release's .msi asset, downloads it into a per-lineage staging
# directory, refuses anything that is not a package, and hands it to a
# detached applier that waits for the app to exit, lets msiexec replace the
# install, and relaunches. The decisions are unit-tested in
# src/apprt/win32/update_apply.zig; this script drives the parts that need a
# real process on a real box.
#
# Everything runs off canned file:// feeds and a canned file:// "package", so
# nothing here publishes, downloads from GitHub, or installs over the user's
# Ghoztty. The one thing deliberately NOT exercised is msiexec succeeding:
# that needs a signed, versioned MSI and would replace the installed app.
# Instead the applier is driven to the point of running msiexec against a
# package msiexec REJECTS, and the assertions are that it got there, that it
# survived the rejection, and that it still relaunched the terminal.
#
# Scenarios (each = one GUI launch, stderr captured; Debug builds use the
# console subsystem so std.log lands on stderr):
#   1. feed with an .msi asset       -> available + pre-downloaded + staged
#   2. asset that is not a package   -> refused, nothing staged
#   3. feed with only the zip asset  -> available, notify-only (no staging)
#   4. --auto-update=check           -> available, no background download
#   5. --auto-update=off             -> no check at all
#   6. leftover sidelined image      -> swept at launch
#   7. applier with a malformed spec -> does nothing, exit 2
#   8. applier with a real spec      -> waits, runs msiexec, relaunches
param([string]$ExePath)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
# T675: suppress the app's startup job self-escape - this harness tracks the
# pids it launches.
$env:GHOZTTY_NO_STARTUP_ESCAPE = '1'
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't1178')
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
if (-not (Test-Path $exe)) { Write-Host "SETUP FAIL: $exe missing (zig build first)"; exit 1 }
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

# ---------------------------------------------------------------- fixtures
$work = Join-Path $env:TEMP 'ghoztty-t1178'
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null

# The staging directory a DEBUG build uses. Asserting the name is part of the
# test: a debug run that staged into the release's directory could hand the
# installed app a package it never asked for.
$staging = Join-Path $env:LOCALAPPDATA 'ghoztty\updates-debug'
$releaseStaging = Join-Path $env:LOCALAPPDATA 'ghoztty\updates'

# The asset URL must contain /download/win-v<version>/ - that is how the
# scanner proves an asset belongs to the release it is offering - so the fake
# assets live under a directory tree of that exact shape.
$assetDir = Join-Path $work 'download\win-v9.9.9'
New-Item -ItemType Directory -Force $assetDir | Out-Null

function New-FakePackage([string]$path) {
    # 8 KB starting with the OLE compound-file signature every MSI carries.
    $bytes = New-Object byte[] 8192
    $magic = [byte[]](0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1)
    [Array]::Copy($magic, $bytes, 8)
    [IO.File]::WriteAllBytes($path, $bytes)
}

$msiPath = Join-Path $assetDir 'Ghoztty-9.9.9-x64.msi'
New-FakePackage $msiPath
$msiUrl = 'file:///' + ($msiPath -replace '\\', '/')

# An asset that answers with an HTML error page instead of a package - the
# real-world shape of a rate limit, a redirect to a login page, or an asset
# that is still uploading.
$badPath = Join-Path $assetDir 'Ghoztty-9.9.9-x64.msi.html'
[IO.File]::WriteAllText($badPath, '<!DOCTYPE html><html><body>404 Not Found</body></html>')
# Named .msi so only the CONTENT check can reject it.
$badMsi = Join-Path $assetDir 'Ghoztty-bad-9.9.9-x64.msi'
Move-Item $badPath $badMsi -Force
$badUrl = 'file:///' + ($badMsi -replace '\\', '/')

$zipPath = Join-Path $assetDir 'Ghoztty-portable-9.9.9-x64.zip'
[IO.File]::WriteAllText($zipPath, 'not really a zip')
$zipUrl = 'file:///' + ($zipPath -replace '\\', '/')

function New-Feed([string]$name, [string]$assetJson) {
    $json = '[{"tag_name":"v1.17.0","assets":[]},' +
            '{"tag_name":"win-v9.9.9","assets":[' + $assetJson + ']}]'
    $path = Join-Path $work $name
    [IO.File]::WriteAllText($path, $json)
    return 'file:///' + ($path -replace '\\', '/')
}

$feedMsi = New-Feed 'msi.json'  ('{"browser_download_url":"' + $msiUrl + '"}')
$feedBad = New-Feed 'bad.json'  ('{"browser_download_url":"' + $badUrl + '"}')
$feedZip = New-Feed 'zip.json'  ('{"browser_download_url":"' + $zipUrl + '"}')

function Clear-Staging {
    if (Test-Path $staging) { Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue }
}

# Launch the GUI with GHOZTTY_UPDATE_URL set, capture stderr, kill it, return
# the stderr text.
function Run-Scenario([string]$label, [string]$updateUrl, [string[]]$extraArgs = @(), [int]$waitSecs = 10) {
    Kill-RepoInstances
    $errFile = Join-Path $work "$label.err.txt"
    Remove-Item $errFile -ErrorAction SilentlyContinue
    if ($updateUrl) { $env:GHOZTTY_UPDATE_URL = $updateUrl }
    else { Remove-Item Env:GHOZTTY_UPDATE_URL -ErrorAction SilentlyContinue }
    # The 1h throttle is keyed on this file; the env override bypasses it, but
    # clearing it keeps the no-override scenarios deterministic too.
    Remove-Item (Join-Path $env:LOCALAPPDATA 'ghoztty\update_check_at') -ErrorAction SilentlyContinue
    try {
        $args = @('--session-persistence=false') + $extraArgs
        $proc = $null
        foreach ($attempt in 1, 2) {
            $proc = Start-Process -FilePath $exe -ArgumentList $args -PassThru -RedirectStandardError $errFile
            $null = $proc.Handle
            $deadline = (Get-Date).AddSeconds($waitSecs)
            while ((Get-Date) -lt $deadline -and -not $proc.HasExited) { Start-Sleep -Milliseconds 500 }
            if (-not $proc.HasExited) { break }
            Write-Host "NOTE ($label): GUI exited early (attempt $attempt)"
            Start-Sleep -Seconds 2
        }
        if ($proc.HasExited) {
            Write-Host "SETUP FAIL ($label): GUI exited early twice (code $($proc.ExitCode))"
            exit 1
        }
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    } finally {
        Remove-Item Env:GHOZTTY_UPDATE_URL -ErrorAction SilentlyContinue
    }
    if (Test-Path $errFile) { return [IO.File]::ReadAllText($errFile) }
    return ''
}

# -- 1. an .msi asset is found, downloaded and staged ---------------------
Clear-Staging
$releaseBefore = (Test-Path $releaseStaging)
$log1 = Run-Scenario 'msi' $feedMsi
Assert ($log1 -match 'update available: current=\S+ latest=win-v9\.9\.9 msi=file:') 'msi: the release''s .msi asset was found'
Assert ($log1 -match 'update staged for win-v9\.9\.9') 'msi: the package was pre-downloaded (auto-update default)'
Assert ($log1 -match 'showing update balloon for win-v9\.9\.9') 'msi: balloon shown'
$staged = Join-Path $staging 'Ghoztty-9.9.9-x64.msi'
Assert (Test-Path $staged) 'msi: the package is on disk in the staging directory'
if (Test-Path $staged) {
    $a = [IO.File]::ReadAllBytes($staged); $b = [IO.File]::ReadAllBytes($msiPath)
    Assert ($a.Length -eq $b.Length) 'msi: the staged package is the whole file'
}
# A debug build must never stage where the installed release would look.
if (-not $releaseBefore) {
    Assert (-not (Test-Path $releaseStaging)) 'msi: a debug run staged nothing into the release lineage'
} else {
    Write-Host 'SKIP  msi: release staging dir pre-existed; lineage separation not asserted'
}

# -- 2. an asset that is not a package is refused -------------------------
Clear-Staging
$log2 = Run-Scenario 'bad' $feedBad
Assert ($log2 -match 'is not an MSI package') 'bad: the content check rejected an HTML body'
Assert ($log2 -match 'update pre-download failed') 'bad: the download reported failure'
Assert ($log2 -notmatch 'update staged for') 'bad: nothing was staged'
Assert ($log2 -match 'showing update balloon for win-v9\.9\.9') 'bad: the user is still told an update exists'
Assert ((-not (Test-Path $staging)) -or (@(Get-ChildItem $staging -Filter *.msi -ErrorAction SilentlyContinue).Count -eq 0)) 'bad: no package left on disk'

# -- 3. a release with no .msi degrades to notify-only -------------------
Clear-Staging
$log3 = Run-Scenario 'zip' $feedZip
Assert ($log3 -match 'msi=\(none published\)') 'zip: no installable asset reported'
Assert ($log3 -notmatch 'update staged for') 'zip: nothing downloaded'
Assert ($log3 -match 'showing update balloon for win-v9\.9\.9') 'zip: notify-only behavior preserved'

# -- 4. auto-update = check notifies but does not download ---------------
Clear-Staging
$log4 = Run-Scenario 'check' $feedMsi @('--auto-update=check')
Assert ($log4 -match 'update available: current=\S+ latest=win-v9\.9\.9') 'check: the check still runs'
Assert ($log4 -notmatch 'update staged for') 'check: no background download'
Assert ((-not (Test-Path $staging)) -or (@(Get-ChildItem $staging -Filter *.msi -ErrorAction SilentlyContinue).Count -eq 0)) 'check: nothing staged'

# -- 5. auto-update = off does not check at all --------------------------
Clear-Staging
$log5 = Run-Scenario 'off' $feedMsi @('--auto-update=off')
Assert ($log5 -match 'update check disabled \(auto-update = off\)') 'off: the check is refused'
Assert ($log5 -notmatch 'update available') 'off: nothing offered'
Assert ($log5 -notmatch 'update staged for') 'off: nothing downloaded'

# -- 6. a leftover sidelined image is swept at launch --------------------
# What an update leaves behind when a PTY holder was still running out of the
# old agent image: the file was renamed aside rather than deleted, and the
# next launch is what cleans it up.
$leftover = Join-Path (Split-Path $exe -Parent) 'ghoztty-agent.exe.old-1'
[IO.File]::WriteAllText($leftover, 'leftover')
$keep = Join-Path (Split-Path $exe -Parent) 'ghoztty-agent.exe.old-keep'
[IO.File]::WriteAllText($keep, 'not a sidelined image')
$log6 = Run-Scenario 'sweep' $feedZip
Assert (-not (Test-Path $leftover)) 'sweep: the sidelined image was removed'
Assert (Test-Path $keep) 'sweep: a file that is not a sidelined image was left alone'
Remove-Item $keep -Force -ErrorAction SilentlyContinue

# -- 7. the applier refuses a spec it cannot read ------------------------
Kill-RepoInstances
# Production spawns the applier as a COPY in the staging directory, never as
# the installed exe - an applier running out of the directory it clears would
# rename itself aside and relaunch a path that no longer exists. The harness
# drives the same shape, so what is tested is what ships.
$applier = Join-Path $work 'ghoztty-updater.exe'
Copy-Item $exe $applier -Force
$errFile = Join-Path $work 'applier-bad.err.txt'
$env:GHOZTTY_UPDATE_APPLY = 'this is not a spec'
try {
    $p = Start-Process -FilePath $applier -PassThru -RedirectStandardError $errFile
    $null = $p.Handle
    $exited = $p.WaitForExit(20000)
} finally {
    Remove-Item Env:GHOZTTY_UPDATE_APPLY -ErrorAction SilentlyContinue
}
if (-not $exited) { try { $p.Kill() } catch {} }
$log7 = if (Test-Path $errFile) { [IO.File]::ReadAllText($errFile) } else { '' }
Assert $exited 'applier(bad): exited instead of becoming a terminal'
Assert ($log7 -match 'malformed GHOZTTY_UPDATE_APPLY') 'applier(bad): said what was wrong'
Assert ($log7 -notmatch 'msiexec') 'applier(bad): never reached msiexec'

# -- 8. the applier waits, runs msiexec and relaunches -------------------
# The pid it waits on is one that has already exited, so the wait is
# satisfied immediately. The package is the fake one, which msiexec rejects
# (1620, "not a valid installer package") - exactly the failure the applier
# has to survive without leaving the user without a terminal.
Kill-RepoInstances
$dead = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'exit' -PassThru -WindowStyle Hidden
$null = $dead.Handle
[void]$dead.WaitForExit(10000)
$deadPid = $dead.Id

$applyMsi = Join-Path $work 'apply-me.msi'
New-FakePackage $applyMsi
$errFile = Join-Path $work 'applier-run.err.txt'
$env:GHOZTTY_UPDATE_APPLY = "$deadPid|$applyMsi|$exe"
try {
    $p = Start-Process -FilePath $applier -PassThru -RedirectStandardError $errFile
    $null = $p.Handle
    $exited = $p.WaitForExit(120000)
} finally {
    Remove-Item Env:GHOZTTY_UPDATE_APPLY -ErrorAction SilentlyContinue
}
if (-not $exited) { try { $p.Kill() } catch {} }
$log8 = if (Test-Path $errFile) { [IO.File]::ReadAllText($errFile) } else { '' }
Assert $exited 'applier(run): finished instead of hanging'
Assert ($log8 -match 'waiting for app pid') 'applier(run): waited for the app to exit'
Assert ($log8 -match 'msiexec\.exe /i .*apply-me\.msi.* /qb-! /norestart /l\*v') 'applier(run): ran msiexec on the staged package, non-interactive and without a reboot'
Assert ($log8 -match 'msiexec exited \d+') 'applier(run): read msiexec''s verdict'
Assert ($log8 -match 'relaunched .*ghoztty\.exe as pid \d+') 'applier(run): gave the user their terminal back after a failed install'
Assert (Test-Path $applyMsi) 'applier(run): a package msiexec rejected is kept, not deleted'
# The relaunch is a real app; it belongs to this harness now.
Kill-RepoInstances

# -- 9. an applier running out of the install directory refuses ----------
# The failure this guard exists to prevent: the applier renames its own image
# aside to make room for msiexec, and then relaunches a path that is no longer
# there. `arm` cannot produce this shape; a hand-driven variable can, and the
# cost of getting it wrong is the user's terminal deleted by its own updater.
Kill-RepoInstances
$errFile = Join-Path $work 'applier-inside.err.txt'
$env:GHOZTTY_UPDATE_APPLY = "$deadPid|$applyMsi|$exe"
try {
    $p = Start-Process -FilePath $exe -PassThru -RedirectStandardError $errFile
    $null = $p.Handle
    $exited = $p.WaitForExit(60000)
} finally {
    Remove-Item Env:GHOZTTY_UPDATE_APPLY -ErrorAction SilentlyContinue
}
if (-not $exited) { try { $p.Kill() } catch {} }
$log9 = if (Test-Path $errFile) { [IO.File]::ReadAllText($errFile) } else { '' }
Assert $exited 'applier(inside): exited'
Assert ($log9 -match 'refusing to install into') 'applier(inside): refused rather than renaming its own image aside'
Assert ($log9 -notmatch 'is in use; renamed it aside') 'applier(inside): nothing was renamed'
Assert (Test-Path $exe) 'applier(inside): the terminal is still where it was'
Assert ($log9 -match 'relaunched .*ghoztty\.exe as pid \d+') 'applier(inside): still gave the user their terminal back'
Kill-RepoInstances

Clear-Staging
Write-Host ''
# The captured stderr IS the evidence for most of these assertions, so it only
# goes away on a clean run - a red that deletes its own diagnostics costs the
# next turn a whole reproduction.
if ($script:fail -eq 0) { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
else { Write-Host "logs kept in $work" }
# --- stamp (T783) ----------------------------------------------------------
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\..\scripts\guard-due.ps1') `
        update -Guard update-apply -Repo $repo 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
