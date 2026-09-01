# T1209 acceptance: the in-app update over a RUNNING terminal, all the way
# through - close, replace, reopen - with a live session on the other side.
#
# THE CLAIM this exists to make, in the words a user would use: "I clicked the
# update, my terminal closed and came back on the new version, my shells were
# still there, and nothing asked me to reboot my PC."
#
# Until now that was three claims measured in three places and never joined:
#
#   * `test\win32\update-apply.ps1` (T1178) drives the applier end to end
#     against a package msiexec REJECTS. Everything up to msiexec's verdict.
#   * `test\win32\update-real-msi.ps1` (T1194) gets a real msiexec to succeed
#     under a throwaway product identity - but it KILLS the app first and hands
#     the applier a pid that has already exited, so the wait, the graceful
#     close and the reopen are all stubbed out of the run.
#   * `test\win32\install-restart.ps1` (T1204) measures the app agreeing to a
#     Restart Manager close and exiting - but drives it with the messages an
#     installer would send, with no installer behind them.
#
# The join is here: the app is RUNNING, with a live session behind it, when the
# applier is armed on its pid; it is then closed the way an installer closes it
# (WM_QUERYENDSESSION / WM_ENDSESSION with ENDSESSION_CLOSEAPP, which is
# literally what the Restart Manager sends); the applier waits for that exit,
# sidelines what is locked, and runs the real msiexec over the throwaway
# product - whose package carries T1207's `--install-prepare` custom action and
# T1204's REBOOT=ReallySuppress. Then the terminal has to come back by itself,
# on the new version, with the session still attachable.
#
# Sections:
#   A  packages: two published releases rewritten to a throwaway identity
#   B  install the older one for real, and start it with a live session
#   C  the app finds the newer release and stages its package
#   D  THE JOIN: arm on the LIVE pid, close the app the installer's way, and
#      let the applier install over the running product
#   E  the terminal came back by itself, on the new version
#   F  nothing asked for a reboot
#   G  the session survived and its pane still answers
#   H  nothing of the user's was touched, and nothing is left behind
#
# THE PAIR, and why it is one release rather than two. An upgrade is graceful
# only when the build being REPLACED knows how to be closed by an installer, and
# that landed in win-v1.36.0 (T1204) - so win-v1.35.0 -> win-v1.36.0 measures a
# predecessor that predates the feature, and it does exactly what you would
# expect: the old build does not close, the applier refuses to install over a
# live app, and the run is red about history rather than about the code.
# Measured on 2026-09-01, and the reason `-ProductVersion` exists on the
# identity rewriter.
#
# So both sides here are the SAME published package: the OLD one is registered
# at a lower ProductVersion (the payload is untouched, only the version moves),
# the NEW one is the published package as it shipped, offered by the canned feed
# under the next tag up so the running build sees something newer than itself. The install is a real
# major upgrade between two real products, and both builds carry the shipping
# close-and-reopen code. The price is that the exe's own semver cannot move
# across the update - `test\win32\update-real-msi.ps1` is where that claim
# lives; what moves here is the REGISTERED product version, which is what
# Windows Installer actually decides an upgrade on.
#
# What is deliberately NOT driven: the tray balloon click and the "Install and
# Restart" confirmation. Those are two mouse events in front of
# `App.applyStagedUpdate`, and that function's whole body is `arm()` followed by
# a quit - which is exactly what section D performs. Everything from the armed
# applier onward is the shipping code.
#
# preflight: none - the binaries here come out of a PUBLISHED MSI, so they are
# release builds by definition and `Assert-GhozttyIsolatedBuild` would refuse
# them. The isolation is bought a different way: `-ReleaseSandbox` gives the run
# its own pipe, its own agent lineage and its own LOCALAPPDATA, and the product
# itself is a throwaway identity installed in its own directory, which section H
# measures against the user's install on every run.
#
# persistence: session persistence is left at its default (ON) on purpose - a
# restored, still-live session on the far side of the update IS the subject of
# section G. It cannot poison a neighbour: every launch here runs under the
# per-run `-ReleaseSandbox` LOCALAPPDATA, so the layout it writes is deleted
# with the sandbox.
#
# isolation: full - private pipe suffix, private agent lineage, per-run
# LOCALAPPDATA, and a product identity that is not the user's.
#
#   powershell -NoProfile -File test\win32\update-graceful.ps1

param(
    [string]$Identity = 'GhozttyT1209Test',
    # ONE published release, on both sides. See "the pair" in the header.
    [string]$Tag = 'win-v1.36.0',
    [string]$OldProductVersion = '26.8.3109',
    # The tag the canned feed OFFERS. It has to read as newer than the running
    # build's own semver or the app has nothing to offer and never downloads -
    # and the running build here is the published one, so the offer is the
    # next number up. The bytes behind it are the published package; only the
    # release NAME is invented, in a feed that is invented anyway.
    [string]$FeedTag = 'win-v1.36.1',
    [switch]$Interactive,
    [switch]$KeepInstall
)
$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

# The install directory is chosen by Windows Installer from the SHELL's idea of
# LocalAppData, which -ReleaseSandbox below is about to move out from under
# $env:LOCALAPPDATA. Capture the real one FIRST or every path assertion in this
# file points at the sandbox and passes while measuring nothing.
$realLocalAppData = $env:LOCALAPPDATA

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$env:GHOZTTY_NO_STARTUP_ESCAPE = '1'
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')
. (Join-Path $PSScriptRoot 'lib\ThrowawayProduct.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

# -ReleaseSandbox, not a bare suffix: everything this script launches is a
# RELEASE build (it is a published package), so without the sandbox it would
# dial the agent that owns the user's live sessions and stage its package into
# the user's own updates directory.
[void](Set-GhozttyTestIsolation -Tag 't1209' -ReleaseSandbox)

# The declared opt-in for a run whose SUBJECT is a release build (T1158). It is
# checked rather than taken on trust: the assert re-derives whether all three
# isolating knobs are held - the pipe suffix, GHOZTTY_AGENT_INSTANCE and
# LOCALAPPDATA - which is exactly what the -ReleaseSandbox above just set. An
# upgrade test cannot be run against a debug build: the thing being installed is
# a published package, and a published package contains a release build.
$env:GHOZTTY_TEST_ALLOW_RELEASE = '1'

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$work = Join-Path $env:TEMP 'ghoztty-t1209'
New-Item -ItemType Directory -Force $work | Out-Null

$ver = $Tag -replace '^win-v', ''
$installDir = Get-ThrowawayInstallDir -RealLocalAppData $realLocalAppData -Identity $Identity
$userInstallDir = Get-ThrowawayUserInstallDir -RealLocalAppData $realLocalAppData
$stagingDir = Join-Path $env:LOCALAPPDATA 'ghoztty\updates'
$testExe = Join-Path $installDir 'ghoztty.exe'
# Resolved after the install, not here: `ghoztty.exe` is GUI-subsystem in a
# release build and prints to nothing, so every CLI call in this file goes
# through the console twin the package ships beside it (T245).
$cli = $testExe

$script:pass = 0
$script:fail = 0
$script:skip = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Skip([string]$label) { $script:skip++; Write-Host "SKIP  $label" -ForegroundColor Yellow }

# What the Restart Manager sends a GUI app whose files an installer needs.
$WM_QUERYENDSESSION = 0x0011
$WM_ENDSESSION = 0x0016
$ENDSESSION_CLOSEAPP = 1

# The user's install, measured before anything runs and again in H. If either
# of these moves, this harness upgraded the user's terminal.
$pathBefore = Get-UserPathEntryCount
$userInstallBefore = if (Test-Path $userInstallDir) {
    @(Get-ChildItem $userInstallDir -Recurse -File -ErrorAction SilentlyContinue).Count
} else { -1 }
$userExeStampBefore = if (Test-Path (Join-Path $userInstallDir 'ghoztty.exe')) {
    (Get-Item (Join-Path $userInstallDir 'ghoztty.exe')).LastWriteTimeUtc.Ticks
} else { 0 }

# ===================================================== A. packages (preflight)
Write-Host "`n-- A. throwaway packages from the published releases --"

$msiNew = Get-ThrowawayPackage -Tag $Tag -Version $ver -Work $work -Identity $Identity -Repo $repo
$msiOld = Get-ThrowawayPackage -Tag $Tag -Version $ver -Work $work -Identity $Identity -Repo $repo `
    -AsProductVersion $OldProductVersion

if (-not $msiOld -or -not $msiNew) {
    # No network, or no `gh`. The published package IS the subject here, so
    # there is nothing to substitute - say so and stop, rather than reporting
    # green over a test that never ran (T271).
    Write-TestAssertedNothing -Reason "could not obtain the published package ($Tag)" `
        -Label 'update-graceful'
}
Assert (Test-Path $msiNew) "A1 $Tag rewritten to the $Identity identity"
Assert (Test-Path $msiOld) "A2 and again as its own predecessor at $OldProductVersion"

# The two packages must share ONE UpgradeCode, or the newer one installs beside
# the older instead of replacing it - which would pass every version check
# below while testing the opposite of an upgrade.
$upOld = Get-MsiProperty -Msi $msiOld -Name 'UpgradeCode'
$upNew = Get-MsiProperty -Msi $msiNew -Name 'UpgradeCode'
Assert ($upOld -eq $upNew -and $upOld -ne '') 'A3 both packages share one throwaway UpgradeCode'
Assert ($upOld -ne '{5EB02044-7F06-498B-B7A9-7EFD65486CFB}') "A4 that UpgradeCode is NOT the shipping product's"
Assert ((Get-MsiProperty -Msi $msiNew -Name 'ProductName') -eq $Identity) 'A5 both packages are the throwaway product'
$prodOld = Get-MsiProperty -Msi $msiOld -Name 'ProductVersion'
$prodNew = Get-MsiProperty -Msi $msiNew -Name 'ProductVersion'
Assert ($prodOld -eq $OldProductVersion) "A6 the predecessor registers as $OldProductVersion (got '$prodOld')"
Assert ([version]$prodOld -lt [version]$prodNew) "A7 and BELOW the published one, so the install is an upgrade ($prodOld -> $prodNew)"
$codeOld = Get-MsiProperty -Msi $msiOld -Name 'ProductCode'
$codeNew = Get-MsiProperty -Msi $msiNew -Name 'ProductCode'
Assert ($codeOld -ne $codeNew) 'A8 they are two distinct products under that one UpgradeCode'

$td = New-TestDesktop -Interactive:$Interactive
$appProc = $null
$applier = Join-Path $stagingDir 'ghoztty-updater.exe'

try {

    # ============================================ B. install it, and run it
    Write-Host "`n-- B. install the $OldProductVersion predecessor for real, and open a session on it --"
    Stop-ThrowawayInstances -InstallDir $installDir -RealLocalAppData $realLocalAppData
    Remove-ThrowawayProduct -Identity $Identity -InstallDir $installDir -RealLocalAppData $realLocalAppData

    $installLog = Join-Path $work 'install-old.log'
    # LAUNCHAPP=0: this run starts the app itself, on the test desktop, a few
    # lines down. /qn because nobody is watching this one.
    $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$msiOld`"", '/qn', '/norestart',
        'LAUNCHAPP=0', '/l*v', "`"$installLog`"") -Wait -PassThru
    $null = $p.Handle
    Assert ($p.ExitCode -eq 0) "B1 msiexec installed the predecessor (exit $($p.ExitCode))"
    Assert (Test-Path $testExe) "B2 ghoztty.exe is in $installDir"
    $com = Join-Path $installDir 'ghoztty.com'
    if (Test-Path $com) { $cli = $com }
    $verInstalled = Get-ThrowawayExeVersion -Exe $testExe
    Assert ($verInstalled -eq $ver) "B3 the terminal it installed runs (reports $ver, got '$verInstalled')"
    # WHICH product Windows has registered, by ProductCode - the identity
    # Windows Installer itself decides an upgrade against. Not DisplayVersion:
    # both packages carry the published `ARPDISPLAYVERSION` (1.36.0), because
    # only the registered ProductVersion was moved, so Apps & Features shows the
    # same string on both sides and could never tell them apart.
    $regBefore = @(Get-ThrowawayUninstallEntries -Identity $Identity)
    $codeBefore = if ($regBefore.Count -eq 1) { Split-Path $regBefore[0].PSPath -Leaf } else { '' }
    Assert ($codeBefore -eq $codeOld) "B3b and Windows has the PREDECESSOR registered (got '$codeBefore')"

    if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue }

    # The asset URL must sit under /download/<tag>/ - that is how the scanner
    # proves an asset belongs to the release it is offering - so the package is
    # published locally under a directory tree of exactly that shape.
    $assetDir = Join-Path $work "download\$FeedTag"
    New-Item -ItemType Directory -Force $assetDir | Out-Null
    $assetMsi = Join-Path $assetDir ("Ghoztty-" + ($FeedTag -replace '^win-v', '') + "-x64.msi")
    Copy-Item $msiNew $assetMsi -Force
    $assetUrl = 'file:///' + ($assetMsi -replace '\\', '/')
    $feedPath = Join-Path $work 'feed.json'
    [IO.File]::WriteAllText($feedPath,
        '[{"tag_name":"v1.0.0","assets":[]},' +
        '{"tag_name":"' + $FeedTag + '","assets":[{"browser_download_url":"' + $assetUrl + '"}]}]')

    $env:GHOZTTY_UPDATE_URL = 'file:///' + ($feedPath -replace '\\', '/')
    # The check re-runs on a timer, and this is the knob update-check.ps1 uses
    # to watch a second tick. Without it a slow launch gets exactly one attempt
    # and reads as "the app never offered the update".
    $env:GHOZTTY_UPDATE_RECHECK_MS = '10000'
    $app = $null
    try {
        $app = Start-OnTestDesktop -Exe $testExe -Arguments @()
        $appProc = $app.Process
        if ($appProc) { $null = $appProc.Handle }
        $win = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow' -TimeoutMs 60000
        Assert ($win -ne [IntPtr]::Zero) 'B4 the installed terminal came up with a window'

        # A pane means a session, and a session means a pty-host holder - the
        # process whose survival across the install is the whole of section G.
        $paneBefore = ''
        for ($i = 0; $i -lt 60 -and -not $paneBefore; $i++) {
            $raw = Get-GhozttyListRaw -Exe $cli
            if ($raw -match '"name"\s*:\s*"([^"]+)"') { $paneBefore = $Matches[1] }
            if (-not $paneBefore) { Start-Sleep -Seconds 1 }
        }
        Assert ($paneBefore -ne '') "B5 it registered a pane to work with (got '$paneBefore')"
        $liveBefore = $false
        if ($paneBefore) {
            $liveBefore = Test-PaneLive -Exe $cli -Target $paneBefore -Tmp $work -Tag 'B'
        }
        Assert $liveBefore 'B6 and that pane is a live shell BEFORE the update (the control for G)'

        $holdersBefore = @(Get-ThrowawayProcesses -InstallDir $installDir -Names @('ghoztty-agent'))
        Assert ($holdersBefore.Count -ge 1) "B7 a session agent/holder is running out of the install ($($holdersBefore.Count))"

        # ==================================== C. the app stages the update
        Write-Host "`n-- C. the app is offered $FeedTag and stages its package --"
        $staged = $null
        for ($i = 0; $i -lt 120; $i++) {
            Start-Sleep -Seconds 1
            if (Test-Path $stagingDir) {
                $hit = @(Get-ChildItem $stagingDir -Filter '*.msi' -File -ErrorAction SilentlyContinue)
                if ($hit.Count -gt 0) { $staged = $hit[0].FullName; break }
            }
        }
        Assert ($null -ne $staged) "C1 the app downloaded and staged a package into $stagingDir"
        if ($staged) {
            Assert ((Get-Item $staged).Length -eq (Get-Item $msiNew).Length) 'C2 the staged bytes are the package it was offered'
        }
    } finally {
        Remove-Item Env:GHOZTTY_UPDATE_URL -ErrorAction SilentlyContinue
        Remove-Item Env:GHOZTTY_UPDATE_RECHECK_MS -ErrorAction SilentlyContinue
    }

    # ============================================================ D. the join
    Write-Host "`n-- D. arm on the LIVE app, close it the installer's way, install --"

    if (-not $staged) {
        Skip 'D  nothing was staged, so there is no update to apply'
    } else {
        # `arm()`'s exact shape: a COPY of the exe in the staging directory (an
        # applier running out of the directory it clears would rename its own
        # image aside), the spec in GHOZTTY_UPDATE_APPLY, and - the part every
        # earlier harness stubbed - the pid of an app that is STILL RUNNING.
        Copy-Item $testExe $applier -Force
        $appAliveAtArm = ($appProc -and -not $appProc.HasExited)
        Assert $appAliveAtArm 'D1 the app is still running at the moment the applier is armed'

        # Windows Installer's own account of what happened, read in section F.
        # Taken here because the file msiexec writes cannot be relied on: it
        # lives beside the staged package and the terminal the applier relaunches
        # sweeps that whole directory on startup (App.zig, `update_install.sweep`),
        # so on a fast box the log is gone before the applier has even exited -
        # measured, twice. The Application event log outlives all of it.
        $sinceInstall = (Get-Date).AddSeconds(-2)

        $env:GHOZTTY_UPDATE_APPLY = "$($app.Pid)|$staged|$testExe"
        $ap = $null
        try {
            $ap = Start-OnTestDesktop -Exe $applier -Arguments @()
        } finally {
            Remove-Item Env:GHOZTTY_UPDATE_APPLY -ErrorAction SilentlyContinue
        }
        $apProc = if ($ap) { $ap.Process } else { $null }
        if ($apProc) { $null = $apProc.Handle }
        Assert ($null -ne $apProc) 'D2 the applier started'

        # It must WAIT rather than install over a live app: half-replacing a
        # running terminal is the one outcome this choreography exists to
        # prevent. Give it a beat and require it to still be there, with the
        # app still up.
        Start-Sleep -Seconds 3
        $waiting = ($apProc -and -not $apProc.HasExited) -and ($appProc -and -not $appProc.HasExited)
        Assert $waiting 'D3 it waits for the app instead of installing over it'

        # Now the close, the way an installer performs it. This is the whole
        # point of the section: not a Kill(), which no installer can do to a
        # user's terminal, but the two messages the Restart Manager sends.
        $agreed = 0
        if ($win -ne [IntPtr]::Zero) {
            $agreed = Invoke-TestMessage -Window $win -Message ([uint32]$WM_QUERYENDSESSION) `
                -WParam ([IntPtr]::Zero) -LParam ([IntPtr]$ENDSESSION_CLOSEAPP)
        }
        Assert ($agreed -ne 0) "D4 the running terminal agrees to close for the update (returned $agreed)"
        if ($win -ne [IntPtr]::Zero) {
            [void](Invoke-TestMessage -Window $win -Message ([uint32]$WM_ENDSESSION) `
                -WParam ([IntPtr]1) -LParam ([IntPtr]$ENDSESSION_CLOSEAPP))
        }
        $appExited = $false
        if ($appProc) { $appExited = $appProc.WaitForExit(30000) }
        Assert $appExited 'D5 and it exits, instead of leaving its files locked'

        $apExited = $false
        if ($apProc) { $apExited = $apProc.WaitForExit(600000) }
        Assert $apExited 'D6 the applier finished instead of hanging'
        $apCode = if ($apProc -and $apExited) { $apProc.ExitCode } else { -1 }
        # THE claim. The applier returns 0 only when msiexec returned 0 (or
        # 3010) AND the terminal was relaunched.
        Assert ($apCode -eq 0) "D7 msiexec succeeded over the closed terminal and it was relaunched (applier exit $apCode)"

        # ================================== E. the terminal came back by itself
        Write-Host "`n-- E. the terminal came back, on the new version --"

        # Nothing in this script started it: the app this run launched is the
        # process asserted dead at D5, and the applier is the process asserted
        # exited at D6.
        $back = @()
        for ($i = 0; $i -lt 60; $i++) {
            $back = @(Get-ThrowawayProcesses -InstallDir $installDir -Names @('ghoztty'))
            if ($back.Count -gt 0) { break }
            Start-Sleep -Seconds 1
        }
        Assert ($back.Count -ge 1) "E1 a terminal is running again without anybody starting one ($($back.Count))"
        $reopenedIsNew = $true
        foreach ($b in $back) { if ($b.Id -eq $app.Pid) { $reopenedIsNew = $false } }
        Assert $reopenedIsNew 'E2 and it is a NEW process, not the one that was asked to close'

        $verAfter = Get-ThrowawayExeVersion -Exe $testExe
        Assert ($verAfter -eq $ver) "E3 and it is a working terminal, not a half-replaced one (reports '$verAfter')"

        $entries = @(Get-ThrowawayUninstallEntries -Identity $Identity)
        Assert ($entries.Count -eq 1) "E4 still ONE product registered - an upgrade, not a second install ($($entries.Count))"
        $codeAfter = if ($entries.Count -eq 1) { Split-Path $entries[0].PSPath -Leaf } else { '' }
        # THE claim about what the install DID, against what B3b measured
        # before it: the registered product is now the newer one, and the
        # predecessor is gone rather than sitting beside it (E4).
        Assert ($codeAfter -eq $codeNew) "E5 the registered product moved $prodOld -> $prodNew (now '$codeAfter')"

        # ================================================ F. no reboot, anywhere
        Write-Host "`n-- F. nothing asked for a reboot --"

        # What Windows Installer itself logged, not what our applier reported.
        # Event 1033 is the one it writes at the end of every install, and it
        # carries the product, the version and the status in one line.
        $msiEvents = @()
        try {
            $msiEvents = @(Get-WinEvent -FilterHashtable @{
                    LogName = 'Application'; ProviderName = 'MsiInstaller'; Id = 1033
                    StartTime = $sinceInstall
                } -ErrorAction SilentlyContinue)
        } catch { $msiEvents = @() }
        $ourEvent = $null
        foreach ($e in $msiEvents) {
            if ($e.Message -match [regex]::Escape($Identity) -and
                $e.Message -match [regex]::Escape($prodNew)) { $ourEvent = $e; break }
        }
        Assert ($null -ne $ourEvent) "F1 Windows Installer logged the $Identity $prodNew install itself"
        $msg = if ($ourEvent) { $ourEvent.Message } else { '' }
        # 3010 is msiexec for "done, but reboot to finish". The applier maps it
        # onto success, so its exit code alone could never have said this.
        Assert ($msg -match 'success or error status: 0') `
            "F2 and recorded plain success, not 3010 ($(if ($msg -match 'status: (\d+)') { 'status ' + $Matches[1] } else { 'no status line' }))"

        # What Windows Installer would have used had it scheduled the
        # replacement for a reboot instead of taking the graceful route.
        $pfro = @()
        try {
            $pfro = @((Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
                -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue).PendingFileRenameOperations)
        } catch { $pfro = @() }
        $ours = @($pfro | Where-Object { $_ -and $_.IndexOf($Identity, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
        Assert ($ours.Count -eq 0) "F3 and no file replacement was deferred to a reboot ($($ours.Count) queued)"

        # ============================== G. the session survived and still answers
        Write-Host "`n-- G. the session survived the update --"

        $survived = 0
        foreach ($h in $holdersBefore) { if (-not $h.HasExited) { $survived++ } }
        Assert ($survived -eq $holdersBefore.Count) `
            "G1 every session holder survived the install ($survived of $($holdersBefore.Count))"

        # And the user-visible half of the same claim: the terminal that came
        # back has a pane, and that pane is a LIVE shell rather than a picture
        # of one (T532). B6 is its control - the same probe passed before the
        # update, so a failure here is the update's.
        $paneAfter = ''
        for ($i = 0; $i -lt 60 -and -not $paneAfter; $i++) {
            $raw = Get-GhozttyListRaw -Exe $cli
            if ($raw -match '"name"\s*:\s*"([^"]+)"') { $paneAfter = $Matches[1] }
            if (-not $paneAfter) { Start-Sleep -Seconds 1 }
        }
        Assert ($paneAfter -ne '') "G2 the reopened terminal has a pane (got '$paneAfter')"
        $liveAfter = $false
        if ($paneAfter) {
            $liveAfter = Test-PaneLive -Exe $cli -Target $paneAfter -Tmp $work -Tag 'G'
        }
        Assert $liveAfter 'G3 and it is a live shell, not a repaint of one'

        # The relaunched terminal belongs to this harness now.
        Stop-ThrowawayInstances -InstallDir $installDir -RealLocalAppData $realLocalAppData -AppOnly
    }

    # ==================================== H. nothing of the user's was touched
    Write-Host "`n-- H. nothing of the user's was touched --"

    Assert (Test-Path $userInstallDir) "H1 the user's Ghoztty install directory is still there"
    $userInstallAfter = if (Test-Path $userInstallDir) {
        @(Get-ChildItem $userInstallDir -Recurse -File -ErrorAction SilentlyContinue).Count
    } else { -1 }
    Assert ($userInstallAfter -eq $userInstallBefore) "H2 its file count is unchanged ($userInstallBefore -> $userInstallAfter)"
    $userExeStampAfter = if (Test-Path (Join-Path $userInstallDir 'ghoztty.exe')) {
        (Get-Item (Join-Path $userInstallDir 'ghoztty.exe')).LastWriteTimeUtc.Ticks
    } else { 0 }
    Assert ($userExeStampAfter -eq $userExeStampBefore) "H3 the user's ghoztty.exe was not rewritten"

    # LAST statement of the top-level try (T1039): an unwind from anywhere above
    # must not reach the verdict as if the run had finished.
    Complete-TestBody
} finally {
    Write-Host "`n-- cleanup --"
    Remove-TestDesktop
    if (-not $KeepInstall) {
        Stop-ThrowawayInstances -InstallDir $installDir -RealLocalAppData $realLocalAppData
        Remove-ThrowawayProduct -Identity $Identity -InstallDir $installDir -RealLocalAppData $realLocalAppData
        $pathAfter = Get-UserPathEntryCount
        Assert ($pathAfter -eq $pathBefore) "H4 the user PATH is back to $pathBefore entries (got $pathAfter)"
        Assert (-not (Test-Path $installDir)) 'H5 the throwaway install directory is gone'
        Assert ((@(Get-ThrowawayUninstallEntries -Identity $Identity)).Count -eq 0) 'H6 no throwaway product left registered'
        Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host '  install kept (-KeepInstall)'
    }
}

# --- stamp (T783) ----------------------------------------------------------
# Only a clean, fully-run sweep re-stamps. A run that SKIPPED (no network, no
# `gh`, no published packages) proves nothing about the code and must leave the
# guard due.
if ($script:fail -eq 0 -and $script:skip -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard update-graceful -Repo $repo 2>&1 |
        ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skip -Label 'update-graceful' -MinPass 20
