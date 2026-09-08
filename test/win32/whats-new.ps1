# T624 acceptance: bundled release notes reach a Windows build, the
# new-since-your-last-version split is the one Mac makes, and the "What's New
# in Ghoztty" window opens with its two tabs.
#
# WHAT THIS PROVES, and why each half needs a different oracle:
#
#   - THE SPLIT is a DECISION, and a decision is invisible in pixels. A
#     screenshot of a notes list cannot say whether the release above the
#     running build was correctly dropped, or whether the anchor was the
#     version the user was running BEFORE this launch rather than the one they
#     are running now. So the split is read through the debug-only `whats-new`
#     IPC action (src/apprt/win32/ipc_whats_new.zig), which reports the model
#     out of the SAME `release_notes.Store` the window paints.
#   - THE WINDOW is structural: a top-level `GhozttyWhatsNew` with Mac's
#     title, one per process however many times it is asked for, with a Client
#     tab and an Agent tab that answer when selected.
#
# THE ANCHOR IS DRIVEN, NOT OBSERVED. `%LOCALAPPDATA%\ghoztty\
# whats-new-seen-debug` is this build's own store (a debug build never touches
# the release app's anchor). The script seeds it before launch, so "an upgrade
# from 1.0.0" and "a first run with no store at all" are both reachable states
# rather than whatever this box happens to be in. The real file is backed up
# and restored in `finally`.
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1), so it never
# steals the user's foreground.
#
# -NegativeControl inverts a load-bearing claim (the split is anchored on the
# SEEDED version rather than on the running one) - that run MUST fail.
#
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

# T351: the shared reset/kill helpers. Dot-sourced HERE, ahead of any isolation
# setup, because it drops an inherited $GHOZTTY_IPC_SOCKET.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-whatsnew$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\PaneCapture.ps1')   # Invoke-GhozttyIpc
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')

[void](Assert-GhozttyIsolatedBuild -Exe $exe)

$script:pass = 0
$script:fail = 0
$script:skipped = 0
$script:negReached = $false

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

function Invoke-WhatsNew([string]$op, [string]$tab) {
    $ipcArgs = @("--op=$op")
    if ($tab) { $ipcArgs += "--tab=$tab" }
    return Invoke-GhozttyIpc -Action 'whats-new' -Arguments $ipcArgs
}

# The debug build's own anchor file. NOT the release app's - `whats_new_seen`
# suffixes it, which is the whole reason a dev build can be driven like this.
$storeDir = Join-Path $env:LOCALAPPDATA 'ghoztty'
$storePath = Join-Path $storeDir 'whats-new-seen-debug'
$storeBackup = $null
$storeExisted = Test-Path $storePath

function Set-SeenVersion([string]$version) {
    if (-not (Test-Path $storeDir)) { New-Item -ItemType Directory -Path $storeDir -Force | Out-Null }
    if ($null -eq $version) { return }
    [System.IO.File]::WriteAllText($storePath, $version)
}

function Clear-SeenVersion {
    Remove-Item $storePath -Force -ErrorAction SilentlyContinue
}

function Get-SeenVersion {
    if (-not (Test-Path $storePath)) { return $null }
    return ([System.IO.File]::ReadAllText($storePath)).Trim()
}

# Compare two dotted versions numerically, the way release_notes.triple does.
function Compare-Ver([string]$a, [string]$b) {
    $pa = @(($a -split '[-+]')[0] -split '\.' | ForEach-Object { [int]$_ })
    $pb = @(($b -split '[-+]')[0] -split '\.' | ForEach-Object { [int]$_ })
    for ($i = 0; $i -lt 3; $i++) {
        $x = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }
        $y = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }
        if ($x -ne $y) { return $x - $y }
    }
    return 0
}

function Test-DescendingVersions($list) {
    $arr = @($list)
    for ($i = 1; $i -lt $arr.Count; $i++) {
        if ((Compare-Ver $arr[$i - 1] $arr[$i]) -le 0) { return $false }
    }
    return $true
}

# Launch the GUI on the test desktop with the store seeded to $seed (or, when
# $seed is empty, with no store at all) and the running version reported as
# $version. Returns the app handle, or $null.
#
# The version override (GHOZTTY_WHATS_NEW_VERSION, debug builds only) is what
# makes the cap testable at all: the notes are keyed by the version line a
# RELEASE carries, while this dev build's own version comes from the branch's
# git description and sits below every bundled file - so without it every
# assertion about "what is new" would be an assertion about an empty list.
function Start-App([string]$seed, [string]$version) {
    Kill-RepoInstances
    if ($null -eq $seed -or $seed -eq '') { Clear-SeenVersion } else { Set-SeenVersion $seed }
    if ($version) { $env:GHOZTTY_WHATS_NEW_VERSION = $version }
    else { Remove-Item Env:GHOZTTY_WHATS_NEW_VERSION -ErrorAction SilentlyContinue }
    $sp = @{
        Exe       = $exe
        Arguments = @('--session-persistence=false', '--background=#101014')
    }
    if (-not $ExePath) { $sp.StdErr = $errlog }
    $a = Start-OnTestDesktop @sp
    Start-Sleep -Seconds 3
    if ($a.Process -and $a.Process.HasExited) { return $null }
    $script:launched += $script:GhozttyTestDesktopPids
    $top = Wait-TestWindow -ProcessId $a.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { return $null }
    return $a
}

function Stop-App($a) {
    if ($a) { Stop-Process -Id $a.Pid -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 400
}

$errlog = Join-Path $env:TEMP 'ghoztty-whats-new-stderr.log'
# The version sections A-D pretend to be running: above every bundled note,
# so 'what is new' is a real list rather than an empty one. Section F drives
# a LOW version to prove the cap.
$ASIF = '1.40.0'
$CAPPED = '1.20.0'
$script:launched = @()
$app = $null

Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: section B asserts the split is anchored on the RUNNING version instead of the seeded one - this run MUST fail'
    }
    Remove-Item $errlog -ErrorAction SilentlyContinue

    # Back up the real store so this box's own anchor survives the run.
    if ($storeExisted) { $storeBackup = [System.IO.File]::ReadAllText($storePath) }

    # =====================================================================
    # A: the notes are IN THE BUILD, and the split is the shape Mac makes.
    # Seeded from an ancient version so every bundled file is "new".
    # =====================================================================
    $app = Start-App '1.0.0' $ASIF
    if (-not $app) {
        Write-TestAssertedNothing -Reason 'GUI did not come up' -Label 'whats-new'
        exit 1
    }

    $model = Invoke-WhatsNew 'model' ''
    if ($null -eq $model -or -not $model.success) {
        Write-TestAssertedNothing -Reason 'the whats-new IPC action never answered' -Label 'whats-new'
        exit 1
    }
    $current = [string]$model.data.current
    Write-Host "INFO  running version=$current previous_seen=$($model.data.previous_seen)"

    # The bundle reached the exe at all. macOS copies release-notes/ into
    # Contents/Resources; a Windows exe has no Resources dir, so a zero here
    # is the whole feature silently missing.
    Assert ([int]$model.data.tabs.client.bundled -gt 0) `
        "A: client release notes are bundled into the exe ($($model.data.tabs.client.bundled))"
    Assert ([int]$model.data.tabs.agent.bundled -gt 0) `
        "A: agent release notes are bundled into the exe ($($model.data.tabs.agent.bundled))"

    foreach ($scope in @('client', 'agent')) {
        $tab = $model.data.tabs.$scope
        $fresh = @($tab.new)
        $installed = @($tab.installed)

        Assert ($fresh.Count -gt 0) "A: $scope has notes to show from a 1.0.0 anchor ($($fresh.Count))"
        Assert ($installed.Count -eq 0) `
            "A: nothing is 'already installed' when the anchor predates every note ($($installed.Count))"
        Assert (Test-DescendingVersions $fresh) "A: $scope new notes are newest-first"

        # The cap: a bundle can carry notes for a release this build is not.
        $above = @($fresh | Where-Object { (Compare-Ver $_ $current) -gt 0 })
        Assert ($above.Count -eq 0) `
            "A: $scope announces nothing newer than the running build (saw $($above -join ','))"
    }

    # =====================================================================
    # B: the anchor is the version the user was running BEFORE this launch,
    # and the store is advanced so the next launch anchors on this build.
    # =====================================================================
    Stop-App $app
    $seed = '1.30.0'
    $app = Start-App $seed $ASIF
    if (-not $app) {
        Write-TestAssertedNothing -Reason 'GUI did not come up for the anchored run' -Label 'whats-new'
        exit 1
    }
    $model = Invoke-WhatsNew 'model' ''
    Assert ($null -ne $model -and $model.success) 'B: the model answered on the anchored run'

    $expectedAnchor = if ($NegativeControl) { $current } else { $seed }
    $script:negReached = $true
    Assert ([string]$model.data.previous_seen -eq $expectedAnchor) `
        "B: the split is anchored on the version running before this launch (want $expectedAnchor, got $($model.data.previous_seen))"

    foreach ($scope in @('client', 'agent')) {
        $tab = $model.data.tabs.$scope
        # Everything at or below the anchor is "already installed"; everything
        # above it (and at or below the running build) is new.
        $wrongSide = @(@($tab.new) | Where-Object { (Compare-Ver $_ $seed) -le 0 })
        Assert ($wrongSide.Count -eq 0) `
            "B: $scope files nothing at or below the anchor as new (saw $($wrongSide -join ','))"
        $wrongOther = @(@($tab.installed) | Where-Object { (Compare-Ver $_ $seed) -gt 0 })
        Assert ($wrongOther.Count -eq 0) `
            "B: $scope files nothing above the anchor as already installed (saw $($wrongOther -join ','))"
    }

    # The store advanced, which is what makes the NEXT launch show nothing new.
    Assert ((Get-SeenVersion) -eq $current) `
        "B: the launch advanced the stored version to this build (got $(Get-SeenVersion))"

    # =====================================================================
    # C: a first run has no anchor, so everything bundled at or below the
    # running build is new and nothing is filed as already installed.
    # =====================================================================
    Stop-App $app
    $app = Start-App '' $ASIF
    if (-not $app) {
        Write-TestAssertedNothing -Reason 'GUI did not come up for the first-run case' -Label 'whats-new'
        exit 1
    }
    $model = Invoke-WhatsNew 'model' ''
    Assert ($null -ne $model -and $model.success) 'C: the model answered on a first run'
    Assert ($null -eq $model.data.previous_seen) `
        "C: a first run reports no anchor at all (got $($model.data.previous_seen))"
    foreach ($scope in @('client', 'agent')) {
        Assert (@($model.data.tabs.$scope.installed).Count -eq 0) `
            "C: $scope files nothing as already installed on a first run"
    }

    # =====================================================================
    # D: the window itself - one per process, Mac's title, two tabs.
    # =====================================================================
    $r = Invoke-WhatsNew 'open' ''
    Assert ($null -ne $r -and $r.success -and $r.data.open) 'D: the window reports itself open'

    $wins = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWhatsNew')
    Assert ($wins.Count -eq 1) "D: exactly one What's New window exists ($($wins.Count))"
    if ($wins.Count -ge 1) {
        $title = Get-TestWindowText -Window ([IntPtr]$wins[0].Hwnd)
        # Mac's title verbatim, typographic apostrophe included.
        $wantTitle = "What" + [char]0x2019 + "s New in Ghoztty"
        Assert ($title -eq $wantTitle) "D: the window carries Mac's title (got '$title')"
        Assert ($wins[0].Visible) 'D: the window is visible'
    }

    # A second ask focuses the open window; it never stacks a second copy
    # (Mac keeps one lazily created NSWindow for exactly this).
    [void](Invoke-WhatsNew 'open' '')
    $wins = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWhatsNew')
    Assert ($wins.Count -eq 1) "D: asking twice does not stack a second window ($($wins.Count))"

    $state = Invoke-WhatsNew 'state' ''
    Assert ([string]$state.data.selected -eq 'client') `
        "D: the Client tab is selected on open (got $($state.data.selected))"
    $clientNew = [int]$state.data.new_count

    $state = Invoke-WhatsNew 'select' 'agent'
    Assert ([string]$state.data.selected -eq 'agent') `
        "D: selecting the Agent tab takes (got $($state.data.selected))"
    $agentNew = [int]$state.data.new_count
    Assert ($agentNew -gt 0) "D: the Agent tab has notes of its own to render ($agentNew)"
    Assert ($clientNew -gt 0) "D: the Client tab has notes of its own to render ($clientNew)"

    # The two tabs are separate lists, not one list shown twice - that is the
    # reason the window has tabs at all (agent notes are the reasons to
    # restart your sessions; client notes are everything else).
    Assert ($agentNew -ne $clientNew -or $agentNew -eq 0) `
        "D: Client and Agent are different lists (client=$clientNew agent=$agentNew)"

    $state = Invoke-WhatsNew 'select' 'client'
    Assert ([string]$state.data.selected -eq 'client') 'D: selecting back to Client takes'

    [void](Invoke-WhatsNew 'close' '')
    $wins = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyWhatsNew')
    Assert ($wins.Count -eq 0) "D: closing removes the window ($($wins.Count))"

    # =====================================================================
    # E: refusals are typed, never a silent default.
    # =====================================================================
    $bad = Invoke-GhozttyIpc -Action 'whats-new' -Arguments @('--op=explode')
    Assert ($null -ne $bad -and -not $bad.success) 'E: an unknown op is refused'
    $noTab = Invoke-GhozttyIpc -Action 'whats-new' -Arguments @('--op=select')
    Assert ($null -ne $noTab -and -not $noTab.success) 'E: select with no tab is refused'
    $closed = Invoke-WhatsNew 'select' 'agent'
    Assert ($null -ne $closed -and -not $closed.success) `
        'E: selecting a tab with no window open is refused rather than opening one'

    # =====================================================================
    # F: the cap - a bundle carrying notes for a release this build is NOT
    # must announce none of them. Nothing else in this script can see that:
    # from a high version every bundled file is showable, so the rule would
    # pass vacuously.
    # =====================================================================
    Stop-App $app
    $app = Start-App '1.0.0' $CAPPED
    if (-not $app) {
        Write-TestAssertedNothing -Reason 'GUI did not come up for the capped run' -Label 'whats-new'
        exit 1
    }
    $model = Invoke-WhatsNew 'model' ''
    Assert ($null -ne $model -and $model.success) 'F: the model answered on the capped run'
    Assert ([string]$model.data.current -eq $CAPPED) `
        "F: the run reports the capped version (got $($model.data.current))"
    foreach ($scope in @('client', 'agent')) {
        $tab = $model.data.tabs.$scope
        $above = @(@($tab.new) | Where-Object { (Compare-Ver $_ $CAPPED) -gt 0 })
        Assert ($above.Count -eq 0) `
            "F: $scope announces nothing above the running build (saw $($above -join ','))"
        # And the drop is a DROP, not a demotion: a version above the running
        # build is not "already installed" either - the user has neither.
        $demoted = @(@($tab.installed) | Where-Object { (Compare-Ver $_ $CAPPED) -gt 0 })
        Assert ($demoted.Count -eq 0) `
            "F: $scope does not file an unshipped release as already installed (saw $($demoted -join ','))"
    }
    # The bundle really does carry something above the cap, or F proves nothing.
    $anyAbove = @(@($model.data.tabs.client.new) + @($model.data.tabs.client.installed)).Count
    Assert ([int]$model.data.tabs.client.bundled -gt $anyAbove) `
        "F: the bundle really holds versions above $CAPPED, so the cap had something to drop"

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash'

    # The last statement of the body: an unwind cannot reach it, so reaching
    # it is what proves every section above actually ran (lib\TestScore.ps1).
    Complete-TestBody
} catch {
    Write-Host "ERROR $_" -ForegroundColor Red
    $script:fail++
} finally {
    Stop-App $app
    Remove-Item Env:GHOZTTY_WHATS_NEW_VERSION -ErrorAction SilentlyContinue
    # Put this box's own anchor back exactly as it was.
    try {
        if ($storeExisted) {
            if ($null -ne $storeBackup) { [System.IO.File]::WriteAllText($storePath, $storeBackup) }
        } else {
            Clear-SeenVersion
        }
    } catch {}
    Remove-TestDesktop
    Kill-RepoInstances
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $script:launched = @($script:launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($script:launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"
}

if ($NegativeControl -and -not $script:negReached) {
    Assert $false 'NEGATIVE CONTROL never reached its inverted assertion'
}

# --- stamp (T783) ---------------------------------------------------------
# A green run records the content of the What's New sources and this script,
# so scripts\guard-due.ps1 can answer "has anybody run this harness against
# the code as it now stands?". A red run leaves the stamp alone on purpose,
# and a -NegativeControl run never stamps.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard whats-new -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-TestVerdict -Pass $script:pass -Fail $script:fail -Skipped $script:skipped -Label 'whats-new'
