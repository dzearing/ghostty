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
#   9. applier inside the install dir -> refuses, relaunches
#  11. the repo build survived the run  (T1268; -NegativeControl proves it can
#      score red — a stray planted before section 6 is swept by the app itself,
#      so the only honest way to observe the alarm is to arm it where the
#      damage actually happened: after the applier arms have run)
#  12. the repair that puts a sidelined build back
param([string]$ExePath, [switch]$NegativeControl)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
# T675: suppress the app's startup job self-escape - this harness tracks the
# pids it launches.
$env:GHOZTTY_NO_STARTUP_ESCAPE = '1'
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
# T1241: every launch below - the app and the applier copy - goes to the
# background test desktop.
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
[void](Set-GhozttyTestIsolation -Tag 't1178')
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
if (-not (Test-Path $exe)) { Write-Host "SETUP FAIL: $exe missing (zig build first)"; exit 1 }
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null

$td = New-TestDesktop

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

# T1268: the applier sections run against a COPY of the build in a scratch
# install directory, so the process that is allowed to rename ghoztty.exe aside
# can never be pointed at the one binary the rest of the turn depends on. That
# copy is not under the repo, so `Stop-RepoGhoztty` refuses it (by design) -
# this is the path-exact equivalent for it.
function Kill-SandboxInstances([string]$Path, [int]$SettleMs = 500) {
    $leaf = Split-Path -Leaf $Path
    Get-CimInstance Win32_Process -Filter "Name='$leaf'" |
        Where-Object { $_.ExecutablePath -eq $Path } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if ($SettleMs -gt 0) { Start-Sleep -Milliseconds $SettleMs }
}

# T1268, belt and braces: put the repo build back if ANYTHING in this run
# sidelined it. On 2026-09-01 section 8's applier found zig-out\bin\ghoztty.exe
# locked by a straggler, renamed it aside so msiexec could write a fresh one,
# and msiexec then rejected the fake package - leaving the turn with no build at
# all. The sandbox above is why that cannot happen again; this is what a FUTURE
# harness reaching the same state would hit instead of stranding the build.
function Restore-RepoBuild([string]$ExePath) {
    if (-not $ExePath) { $ExePath = $exe }
    $binDir = Split-Path $ExePath -Parent
    $sidelined = @(Get-ChildItem -LiteralPath $binDir -Filter 'ghoztty.exe.old-*' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^ghoztty\.exe\.old-\d+$' } |
        Sort-Object LastWriteTime -Descending)
    if ($sidelined.Count -eq 0) { return }
    $restored = $false
    foreach ($s in $sidelined) {
        if (-not $restored -and -not (Test-Path -LiteralPath $ExePath)) {
            Move-Item -LiteralPath $s.FullName -Destination $ExePath -Force
            Write-Host "  T1268: restored $ExePath from $($s.Name)"
            $restored = $true
        } else {
            Remove-Item -LiteralPath $s.FullName -Force -ErrorAction SilentlyContinue
            Write-Host "  T1268: removed stray $($s.Name)"
        }
    }
}
# However this script ends - an assertion failure walks off the bottom, a throw
# does not - the repo build is put back on the way out.
trap { Restore-RepoBuild; break }

# T1206: a non-zero msiexec now raises Ghoztty's own modal and HOLDS it until it
# is read, so the applier no longer exits on its own after a rejection. That
# message is `update-failure-visible.ps1`'s subject; here it is just something
# to dismiss so the choreography this script tests can finish.

# T1241: the dialog is on the TEST desktop now, where the private EnumWindows
# P/Invoke this used to call cannot see it - enumeration is per-desktop and runs
# on the caller's. The harness enumerates and closes on its own worker thread,
# which IS bound to that desktop, so the same "find every confirm dialog this pid
# owns and close it" is being done, one desktop over.
function Close-ApplierDialog([int]$procId, [int]$timeoutMs = 30000) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $found = @(Get-TestWindows -ProcessId $procId -Class 'GhozttyConfirmDialog')
        if ($found.Count -gt 0) {
            foreach ($w in $found) { [void](Send-TestWindowClose -Window ([IntPtr]$w.Hwnd)) }
            return $true
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
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
            # T1241: on the TEST desktop, so ten scenario launches do not throw
            # ten windows across the user's screen. -StdErr is the same capture
            # -RedirectStandardError was, and it is what every Assert reads.
            $app = Start-OnTestDesktop -Exe $exe -Arguments $args -StdErr $errFile
            $proc = $app.Process
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
    # T1241: the applier goes on the test desktop too. It is a COPY of
    # ghoztty.exe, so the analyzer's `$exe` rule never saw this launch - but a
    # copy relaunches a real terminal window in section 8 all the same.
    $pa = Start-OnTestDesktop -Exe $applier -StdErr $errFile
    $p = $pa.Process
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
#
# T1268: the install directory is a THROWAWAY holding a copy of the build, the
# way update-real-msi.ps1 uses a sandboxed product identity. The applier is
# designed to rename a locked ghoztty.exe aside so msiexec can write a fresh
# one; pointed at zig-out\bin with a package msiexec always rejects, that is a
# destructive operation aimed at the repo build, and one straggler holding the
# exe open is all it takes to leave the turn with no binary. Every assertion
# below reads the applier's own log, so it holds just as well against the copy.
Kill-RepoInstances
$installDir = Join-Path $work 'installdir'
New-Item -ItemType Directory -Force $installDir | Out-Null
$installExe = Join-Path $installDir 'ghoztty.exe'
Copy-Item $exe $installExe -Force
$dead = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'exit' -PassThru -WindowStyle Hidden
$null = $dead.Handle
[void]$dead.WaitForExit(10000)
$deadPid = $dead.Id

$applyMsi = Join-Path $work 'apply-me.msi'
New-FakePackage $applyMsi
$errFile = Join-Path $work 'applier-run.err.txt'
$env:GHOZTTY_UPDATE_APPLY = "$deadPid|$applyMsi|$installExe"
try {
    $pa = Start-OnTestDesktop -Exe $applier -StdErr $errFile
    $p = $pa.Process
    # The rejection raises the T1206 dialog and the applier waits on it; dismiss
    # it, then let the process finish the way it does once a user has read the
    # message.
    $dismissed = Close-ApplierDialog $pa.Pid
    $exited = $p.WaitForExit(120000)
} finally {
    Remove-Item Env:GHOZTTY_UPDATE_APPLY -ErrorAction SilentlyContinue
}
if (-not $exited) { try { $p.Kill() } catch {} }
$log8 = if (Test-Path $errFile) { [IO.File]::ReadAllText($errFile) } else { '' }
Assert $dismissed 'applier(run): said the install failed instead of vanishing (T1206)'
Assert $exited 'applier(run): finished instead of hanging'
Assert ($log8 -match 'waiting for app pid') 'applier(run): waited for the app to exit'
Assert ($log8 -match 'msiexec\.exe /i .*apply-me\.msi.* /qb-! /norestart /l\*v') 'applier(run): ran msiexec on the staged package, non-interactive and without a reboot'
Assert ($log8 -match 'msiexec exited \d+') 'applier(run): read msiexec''s verdict'
Assert ($log8 -match 'relaunched .*ghoztty\.exe as pid \d+') 'applier(run): gave the user their terminal back after a failed install'
Assert (Test-Path $applyMsi) 'applier(run): a package msiexec rejected is kept, not deleted'
Assert (Test-Path $installExe) 'applier(run): the install directory still has its terminal'
# The relaunch is a real app; it belongs to this harness now. It is the sandbox
# copy, which lives outside the repo, so it needs its own path-exact stop.
Kill-SandboxInstances $installExe
Kill-RepoInstances

# -- 9. an applier running out of the install directory refuses ----------
# The failure this guard exists to prevent: the applier renames its own image
# aside to make room for msiexec, and then relaunches a path that is no longer
# there. `arm` cannot produce this shape; a hand-driven variable can, and the
# cost of getting it wrong is the user's terminal deleted by its own updater.
Kill-RepoInstances
#
# T1268: "inside" is the sandbox install directory, not zig-out\bin. The whole
# point of this arm is to construct the state where an applier WOULD rename the
# image it is running from aside - so that image must be one we can afford to
# lose if the guard ever regresses.
$errFile = Join-Path $work 'applier-inside.err.txt'
$env:GHOZTTY_UPDATE_APPLY = "$deadPid|$applyMsi|$installExe"
try {
    $pi = Start-OnTestDesktop -Exe $installExe -StdErr $errFile
    $p = $pi.Process
    $exited = $p.WaitForExit(60000)
} finally {
    Remove-Item Env:GHOZTTY_UPDATE_APPLY -ErrorAction SilentlyContinue
}
if (-not $exited) { try { $p.Kill() } catch {} }
$log9 = if (Test-Path $errFile) { [IO.File]::ReadAllText($errFile) } else { '' }
Assert $exited 'applier(inside): exited'
Assert ($log9 -match 'refusing to install into') 'applier(inside): refused rather than renaming its own image aside'
Assert ($log9 -notmatch 'is in use; renamed it aside') 'applier(inside): nothing was renamed'
Assert (Test-Path $installExe) 'applier(inside): the terminal is still where it was'
Assert ($log9 -match 'relaunched .*ghoztty\.exe as pid \d+') 'applier(inside): still gave the user their terminal back'
Kill-SandboxInstances $installExe
Kill-RepoInstances

# -- 11. the harness left the repo build alone (T1268) --------------------
# The arms above are the only ones that drive a process whose JOB is to move
# ghoztty.exe out of the way. Whatever they did, they did it to the copy: this
# is the check that would have gone red on 2026-09-01, when the run finished
# with zig-out\bin\ghoztty.exe.old-1788324281 and no ghoztty.exe.
if ($NegativeControl) {
    # Reconstruct exactly what the 2026-09-01 run left behind, at the point in
    # the script where it left it.
    Copy-Item $exe (Join-Path (Split-Path $exe -Parent) 'ghoztty.exe.old-1788324281') -Force
    Write-Host '  NEGATIVE CONTROL: planted a sidelined repo build'
}
$strays = @(Get-ChildItem -LiteralPath (Split-Path $exe -Parent) -Filter 'ghoztty.exe.old-*' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^ghoztty\.exe\.old-\d+$' })
Assert (Test-Path $exe) 'harness: the repo build is exactly where it was'
Assert ($strays.Count -eq 0) "harness: nothing sidelined the repo build ($($strays.Count) stray .old-* left)"
# Reported first, then repaired: the assertion above is the finding, and a run
# that quietly fixed the damage before looking would never have one.
Restore-RepoBuild

# -- 12. the repair itself, demonstrated (T1268) --------------------------
# Section 11 is the alarm; this is the proof that the thing it triggers can
# actually put a build back. Run against scratch files rather than the repo bin
# - a safety net whose only exercise is the emergency it exists for is a net
# nobody has ever measured.
$restoreDir = Join-Path $work 'restore'
New-Item -ItemType Directory -Force $restoreDir | Out-Null
$restoreExe = Join-Path $restoreDir 'ghoztty.exe'
[IO.File]::WriteAllText((Join-Path $restoreDir 'ghoztty.exe.old-1788324281'), 'the build')
Restore-RepoBuild $restoreExe
Assert (Test-Path $restoreExe) 'restore: a sidelined build with no ghoztty.exe beside it is moved back'
Assert ((Test-Path $restoreExe) -and ([IO.File]::ReadAllText($restoreExe) -eq 'the build')) 'restore: it is the sidelined bytes, not an empty file'
Assert (@(Get-ChildItem -LiteralPath $restoreDir -Filter 'ghoztty.exe.old-*').Count -eq 0) 'restore: nothing sidelined is left behind'

[IO.File]::WriteAllText((Join-Path $restoreDir 'ghoztty.exe.old-1788324282'), 'stale')
Restore-RepoBuild $restoreExe
Assert ([IO.File]::ReadAllText($restoreExe) -eq 'the build') 'restore: a live ghoztty.exe is never overwritten by a stray'
Assert (@(Get-ChildItem -LiteralPath $restoreDir -Filter 'ghoztty.exe.old-*').Count -eq 0) 'restore: the stray is swept anyway'

$keepDir = Join-Path $work 'restore-keep'
New-Item -ItemType Directory -Force $keepDir | Out-Null
[IO.File]::WriteAllText((Join-Path $keepDir 'ghoztty.exe.old-keep'), 'not a sidelined image')
Restore-RepoBuild (Join-Path $keepDir 'ghoztty.exe')
Assert (Test-Path (Join-Path $keepDir 'ghoztty.exe.old-keep')) 'restore: a file that is not a sidelined image is left alone'
Assert (-not (Test-Path (Join-Path $keepDir 'ghoztty.exe'))) 'restore: and nothing is invented from it'

# -- 10. WHO gets the automatic check (T1217) -----------------------------
# The automatic check used to be gated on the build flag alone, which answers
# "did the MSI pipeline make these bytes?" - a different question from "is this
# the user's installed terminal". The loop's morning refresh writes a
# script-built exe over the install, so on 2026-08-31 a terminal installed from
# the website at 07:08 was reporting "update check: off (dev build)" by 07:49.
# The predicate now reads the exe's LOCATION, and it lives in one place so the
# app's gate, the provenance payload and `+version` cannot disagree. Its own
# table (installed dir vs portable vs zig-out vs a child of the install) is
# covered by the zig unit tests in install_location.zig; these arms hold the
# WIRING, which no compiler checks.
$appSrc = [IO.File]::ReadAllText((Join-Path $repo 'src\apprt\win32\App.zig'))
$provSrc = [IO.File]::ReadAllText((Join-Path $repo 'src\apprt\win32\provenance.zig'))
$verSrc = [IO.File]::ReadAllText((Join-Path $repo 'src\cli\version.zig'))
$locSrc = [IO.File]::ReadAllText((Join-Path $repo 'src\apprt\win32\install_location.zig'))
Assert ($appSrc -match 'if \(!self\.autoUpdateCheckAllowed\(\) and !overridden\) return;') `
    'gate: the automatic check asks the predicate, not the build flag'
Assert ($appSrc -notmatch 'if \(!build_config\.windows_update_check and !overridden\) return;') `
    'gate: the old build-flag-only gate is gone'
Assert ($locSrc -match 'if \(builtin\.mode == \.Debug\) return false;') `
    'gate: a Debug build never auto-checks, wherever it is running from'
Assert ($locSrc -match 'if \(build_config\.windows_update_check\) return true;') `
    'gate: an MSI-pipeline build still auto-checks, wherever it is running from'
Assert ($provSrc -match 'install_location\.autoUpdateCheckEnabled\(alloc\)') `
    'gate: provenance reports the same answer the app acts on'
Assert ($verSrc -match 'install_location\.autoUpdateCheckEnabled\(uc_arena\.allocator\(\)\)') `
    'gate: +version reports the same answer too'

Clear-Staging
Remove-TestDesktop | Out-Null
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
