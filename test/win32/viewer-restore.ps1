# T90h acceptance: viewer panes survive a session restore.
#
# A viewer owns no agent session, so there is nothing for restore to ATTACH to -
# re-opening its recorded location IS its restore. That makes this a different
# oracle from session-reattach.ps1 (which proves the SAME pids come back) and it
# gets its own script rather than a section there: this one needs
# session-persistence ON and a viewer in the tree, and session-reattach's F10/F11
# are knowingly RED on T223, so a new assertion buried in it could never be read
# as a clean pass.
#
# What is asserted, in two halves:
#
#   CAPTURE (A-C) - the manifest records a viewer leaf as a viewer:
#     A. a mixed window (viewer + terminal + viewer) captures three leaves, of
#        which exactly two carry kind=viewer, and the terminal leaf carries a
#        session_id while neither viewer does.
#     B. each viewer leaf records viewer_location, viewer_home_location and
#        viewer_origin_directory (the CLI seeds the last one with the caller's
#        cwd for every --view= open), plus the pane's IPC name.
#     C. a viewer-ONLY window is captured too, including one whose file does not
#        exist - the pane the user is looking at is a real pane either way.
#
#   RESTORE (D-H) - kill ONLY the app (the agent keeps the terminal's PTY),
#   relaunch, and read the rebuilt layout back through +list --json:
#     D. the mixed window comes back with all three panes in the same order and
#        the same kinds - the viewer arms of the restore walk (window root, and
#        a split whose new pane is a viewer).
#     E. each restored viewer is pointed at the location it was showing, and
#        kept its IPC name.
#     F. the viewer-only window comes back AT ALL. This is the never-all-dead
#        rule: it has no session-backed leaf, so the pre-T90h reachability probe
#        would have dropped it as "every session gone".
#     G. the missing-file viewer restores as a live viewer pane (the error card
#        is IN the page) rather than being skipped.
#     H. the terminal in the mixed window re-ATTACHed rather than re-OPENing -
#        the positive control that this script did not simply rebuild everything
#        from scratch, which would make D-G true for the wrong reason.
#
# Hermetic: per-run LOCALAPPDATA, per-run agent binary override, a private IPC
# pipe suffix, and it only ever kills ghoztty processes launched from this
# repo's zig-out. Runs on the BACKGROUND test desktop, so it never takes the
# user's foreground.
#
#   powershell -NoProfile -File test\win32\viewer-restore.ps1
param(
    [string]$ExePath,
    [string]$AgentExe,
    [switch]$NegativeControl,
    [switch]$Interactive
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
$agent = Join-Path $repo 'zig-out\bin\ghoztty-agent.exe'
if ($AgentExe) { $agent = $AgentExe }

$script:pass = 0
$script:fail = 0
$root = Join-Path $env:TEMP "ghoztty-viewer-restore-$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

# Write-Host, not the pipeline: a helper that asserts must never also return a
# value, or its return silently becomes an array (T217 batch 5).
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}
function Say($m) { Write-Host $m }

function Stop-RepoInstances {
    foreach ($n in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$n'" |
            Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 700
}

# Kill ONLY the app: the detached agent keeps its PTYs, which is the whole
# scenario (quit / crash / upgrade, then re-attach).
function Stop-AppOnly {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 900
}

# A PIPE, not a `>` redirect: `ghoztty +verb > file` from PowerShell writes zero
# bytes (T245).
function Invoke-Verb([string[]]$VerbArgs) {
    $out = (& $exe @VerbArgs 2>&1 | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Get-Data {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    try { return ($json | ConvertFrom-Json).data } catch { return $null }
}

function Get-Win($target) {
    $data = Get-Data
    if (-not $data) { return $null }
    foreach ($w in $data.windows) { if ($w.target -eq $target) { return $w } }
    return $null
}

# Leaves in tree order (left/top first), so position is assertable and not just
# membership: the restore walk rebuilds a split by anchoring the OLD pane left
# and creating the new one right, and a mixed tree is exactly where getting that
# inverted would show up.
function Get-Leaves($node) {
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    return @(Get-Leaves $node.left) + @(Get-Leaves $node.right)
}

function Get-PaneList($target) {
    $w = Get-Win $target
    if (-not $w) { return @() }
    return @(Get-Leaves $w.tabs[0].splits)
}

function Wait-Panes($target, $count, $timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $panes = @(Get-PaneList $target)
        if ($panes.Count -eq $count) { return $panes }
        Start-Sleep -Milliseconds 400
    }
    return @(Get-PaneList $target)
}

function Manifest-Path($tmp) { return (Join-Path $tmp 'ghoztty\session-layout-debug.json') }

function Read-Manifest($tmp) {
    $p = Manifest-Path $tmp
    if (-not (Test-Path $p)) { return $null }
    try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch { return $null }
}

function Wait-Manifest($tmp, $pred, $timeoutSec = 15) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $m = Read-Manifest $tmp
        if ($null -ne $m) { if (& $pred $m) { return $m } }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

function Manifest-Win($m, $name) {
    if ($null -eq $m) { return $null }
    $w = @($m.windows | Where-Object { $_.ipc_name -eq $name })
    if ($w.Count -ne 1) { return $null }
    return $w[0]
}

function Manifest-Leaves($w) {
    if ($null -eq $w) { return @() }
    $out = @()
    foreach ($tab in @($w.tabs)) {
        foreach ($n in @($tab.nodes)) { if ($n.leaf) { $out += @($n.leaf) } }
    }
    return $out
}

# Sessions the agent is keeping, straight from the agent (it answers even while
# the app is dead - that is the point of asking IT and not the app).
function Alive-Ids {
    $json = (& $exe +sessions --json 2>$null | Out-String).Trim()
    if (-not $json) { return @() }
    $rows = $null
    try { $rows = $json | ConvertFrom-Json } catch { return @() }
    return @(@($rows) | Where-Object { $_.alive -eq $true } | ForEach-Object { [string]$_.id })
}

$docFile = Join-Path $repo 'README.md'
$missingFile = Join-Path $env:TEMP "ghoztty-vr-missing-$PID.md"
Remove-Item $missingFile -ErrorAction SilentlyContinue
$blank = 'about:blank'

$savedLocalAppData = $env:LOCALAPPDATA
$savedAgentBin = $env:GHOSTTY_LOCAL_AGENT_BIN
$savedPipe = $env:GHOZTTY_PIPE_SUFFIX
$env:GHOZTTY_PIPE_SUFFIX = '-vrestore'

Stop-RepoInstances
New-Item -ItemType Directory -Force $root | Out-Null
$tmp = Join-Path $root 'app'
New-Item -ItemType Directory -Force (Join-Path $tmp 'ghoztty\local-agent-debug') | Out-Null
$env:LOCALAPPDATA = $tmp
$env:GHOSTTY_LOCAL_AGENT_BIN = $agent

Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    Assert (Test-Path $exe) "ghoztty exe exists in zig-out"
    Assert (Test-Path $agent) "ghoztty-agent exe exists in zig-out"

    $app = Start-OnTestDesktop -Exe $exe
    if ((Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Say 'SETUP FAIL: no GhozttyWindow'; exit 1
    }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'GUI is NOT enumerable on the interactive desktop'

    # ---- build the layout ---------------------------------------------------
    # A MIXED window: viewer root, a terminal split off it, then a second viewer
    # split off the terminal. Both viewer arms of the restore walk are covered -
    # the window's first pane, and a split whose new pane is a viewer.
    $r = Invoke-Verb @('+new-window', '--target=vr', "--view=$docFile")
    Assert ($r.Code -eq 0) "+new-window --view=<file> exits 0 (got $($r.Code))"
    Assert ((@(Wait-Panes 'vr' 1)).Count -eq 1) 'the viewer window came up with one pane'

    $r = Invoke-Verb @('+split', '--target=vr', '--name=vrterm', '--direction=right')
    Assert ($r.Code -eq 0) "+split (terminal) exits 0 (got $($r.Code))"
    $r = Invoke-Verb @('+split', '--target=vr', '--name=vrblank', '--direction=down', "--view=$blank")
    Assert ($r.Code -eq 0) "+split --view exits 0 (got $($r.Code))"
    $panes = @(Wait-Panes 'vr' 3)
    Assert ($panes.Count -eq 3) "the mixed window has three panes (got $($panes.Count))"

    # A viewer-ONLY window, pointed at a file that does not exist: the pane is
    # real either way (the error lives in the page), and this is the window with
    # no session-backed leaf at all.
    $r = Invoke-Verb @('+new-window', '--target=vrmiss', "--view=$missingFile")
    Assert ($r.Code -eq 0) "+new-window --view=<missing file> exits 0 (got $($r.Code))"
    Assert ((@(Wait-Panes 'vrmiss' 1)).Count -eq 1) 'the missing-file viewer window came up'

    # ---- A: the manifest records viewer leaves as viewers --------------------
    Say '== A: capture'
    $m = Wait-Manifest $tmp {
        param($mm)
        $w = Manifest-Win $mm 'vr'
        $null -ne $w -and (@(Manifest-Leaves $w)).Count -eq 3
    } 20
    $mv = Manifest-Win $m 'vr'
    $leaves = @(Manifest-Leaves $mv)
    Assert ($leaves.Count -eq 3) "A1 the mixed window captured three leaves (got $($leaves.Count))"
    $viewerLeaves = @($leaves | Where-Object { $_.kind -eq 'viewer' })
    $termLeaves = @($leaves | Where-Object { $_.kind -ne 'viewer' })
    Assert ($viewerLeaves.Count -eq 2) "A2 exactly two leaves carry kind=viewer (got $($viewerLeaves.Count))"
    Assert ($termLeaves.Count -eq 1 -and $termLeaves[0].session_id) `
        'A3 the terminal leaf carries an agent session_id'
    $noSid = @($viewerLeaves | Where-Object { $null -eq $_.session_id })
    Assert ($noSid.Count -eq 2) "A4 no viewer leaf claims a session_id (got $($noSid.Count)/2)"

    # ---- B: the four viewer fields ------------------------------------------
    Say '== B: the viewer fields'
    $docLeaf = @($viewerLeaves | Where-Object { $_.viewer_location -eq $docFile })
    Assert ($docLeaf.Count -eq 1) "B1 the file viewer recorded its location ($docFile)"
    if ($docLeaf.Count -eq 1) {
        # Home equals location for a pane that has not navigated anywhere - the
        # value only diverges once it does, and it is persisted separately so
        # that divergence survives (T90h).
        Assert ($docLeaf[0].viewer_home_location -eq $docFile) `
            "B2 the file viewer recorded its home (got '$($docLeaf[0].viewer_home_location)')"
        Assert ($docLeaf[0].viewer_origin_directory -eq $repo) `
            "B3 the file viewer recorded its origin directory (got '$($docLeaf[0].viewer_origin_directory)')"
    }
    $blankLeaf = @($viewerLeaves | Where-Object { $_.viewer_location -eq $blank })
    Assert ($blankLeaf.Count -eq 1) "B4 the blank viewer recorded its location ($blank)"
    if ($blankLeaf.Count -eq 1) {
        Assert ($blankLeaf[0].ipc_name -eq 'vrblank') `
            "B5 the named viewer split captured its IPC name (got '$($blankLeaf[0].ipc_name)')"
        # about:blank names no directory of its own, so the origin is the ONLY
        # provenance it will ever have - the reason the field exists.
        Assert ($blankLeaf[0].viewer_origin_directory -eq $repo) `
            "B6 the blank viewer recorded its origin directory (got '$($blankLeaf[0].viewer_origin_directory)')"
    }

    # ---- C: the viewer-only window ------------------------------------------
    Say '== C: the viewer-only window'
    $mMiss = Wait-Manifest $tmp {
        param($mm) $null -ne (Manifest-Win $mm 'vrmiss')
    } 15
    $missWin = Manifest-Win $mMiss 'vrmiss'
    $missLeaves = @(Manifest-Leaves $missWin)
    Assert ($missLeaves.Count -eq 1 -and $missLeaves[0].kind -eq 'viewer') `
        'C1 the viewer-only window captured one viewer leaf'
    Assert ($missLeaves.Count -eq 1 -and $missLeaves[0].viewer_location -eq $missingFile) `
        'C2 it recorded the missing file as its location'

    # ---- kill the app; the agent keeps the terminal's PTY --------------------
    $beforeIds = @(Alive-Ids)
    Assert ($beforeIds.Count -ge 1) "at least one agent session is alive pre-quit (got $($beforeIds.Count))"
    $vrTermSid = $termLeaves[0].session_id
    Stop-AppOnly
    $keptIds = @(Alive-Ids)
    Assert ($keptIds -contains $vrTermSid) 'the agent kept the terminal session alive after the app died'

    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = $agent
    $relaunched = Start-OnTestDesktop -Exe $exe
    if ((Wait-TestWindow -ProcessId $relaunched.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Say 'SETUP FAIL: relaunched app has no GhozttyWindow'
    }

    # ---- D/E: the mixed window is rebuilt with its viewers -------------------
    Say '== D/E: restore of the mixed window'
    $post = @(Wait-Panes 'vr' 3 45)
    Assert ($post.Count -eq 3) "D1 the mixed window restored all three panes (got $($post.Count))"
    if ($post.Count -eq 3) {
        $kinds = @($post | ForEach-Object { $_.type })
        Assert (($kinds -join ',') -eq 'viewer,terminal,viewer') `
            "D2 the panes came back in the same order and kinds (got $($kinds -join ','))"
        $restoredViewers = @($post | Where-Object { $_.type -eq 'viewer' })
        $urls = @($restoredViewers | ForEach-Object { $_.url })
        Assert ($urls -contains $docFile) "E1 a restored viewer is pointed at $docFile (got $($urls -join ' | '))"
        Assert ($urls -contains $blank) "E2 a restored viewer is pointed at $blank (got $($urls -join ' | '))"
        $named = @($post | Where-Object { $_.name -eq 'vrblank' })
        Assert ($named.Count -eq 1 -and $named[0].type -eq 'viewer') `
            'E3 the restored viewer split kept its IPC name'
    }

    # ---- F/G: the viewer-only window came back ------------------------------
    Say '== F/G: restore of the viewer-only window'
    $missPost = @(Wait-Panes 'vrmiss' 1 30)
    Assert ($missPost.Count -eq 1) `
        "F1 the viewer-only window restored (never-all-dead rule) (got $($missPost.Count) panes)"
    if ($missPost.Count -eq 1) {
        Assert ($missPost[0].type -eq 'viewer') "G1 it restored as a viewer pane (got '$($missPost[0].type)')"
        Assert ($missPost[0].url -eq $missingFile) `
            "G2 it is pointed at the missing file, error card and all (got '$($missPost[0].url)')"
    }

    # ---- H: the terminal RE-ATTACHED ---------------------------------------
    Say '== H: the terminal in the mixed window re-attached'
    $afterIds = @()
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline) {
        $afterIds = @(Alive-Ids)
        if ($afterIds -contains $vrTermSid) { break }
        Start-Sleep -Milliseconds 600
    }
    $sameSession = ($afterIds -contains $vrTermSid)
    if ($NegativeControl) {
        # Invert the claim: a build that rebuilt everything from scratch would
        # have re-OPENed this pane, and D-G would still be green for the wrong
        # reason. A control that PASSES here is scoring exactly that.
        Say 'NEGATIVE CONTROL: asserting the terminal was re-OPENed instead of attached - this run MUST fail'
        Assert (-not $sameSession) 'H1 restore replaced the terminal session with a new one (inverted)'
    } else {
        Assert $sameSession 'H1 the terminal pane re-ATTACHed to its original agent session'
    }

    # The manifest the restored app writes must say the same thing the pre-quit
    # one did: a round-trip that loses a field is a restore that works once.
    Say '== I: the rewritten manifest still describes the viewers'
    $m2 = Wait-Manifest $tmp {
        param($mm)
        $w = Manifest-Win $mm 'vr'
        $null -ne $w -and (@(Manifest-Leaves $w | Where-Object { $_.kind -eq 'viewer' })).Count -eq 2
    } 25
    $v2 = @(Manifest-Leaves (Manifest-Win $m2 'vr') | Where-Object { $_.kind -eq 'viewer' })
    Assert ($v2.Count -eq 2) "I1 the rewritten manifest still records two viewer leaves (got $($v2.Count))"
    $doc2 = @($v2 | Where-Object { $_.viewer_location -eq $docFile })
    Assert ($doc2.Count -eq 1 -and $doc2[0].viewer_home_location -eq $docFile) `
        'I2 the restored file viewer still records its home'
    Assert ($doc2.Count -eq 1 -and $doc2[0].viewer_origin_directory -eq $repo) `
        'I3 the restored file viewer still records its origin directory'

} finally {
    Say '== cleanup'
    Remove-TestDesktop
    Stop-RepoInstances
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $savedAgentBin) { $env:GHOSTTY_LOCAL_AGENT_BIN = $savedAgentBin }
    else { Remove-Item env:GHOSTTY_LOCAL_AGENT_BIN -ErrorAction SilentlyContinue }
    $env:GHOZTTY_PIPE_SUFFIX = $savedPipe
    if ($script:fail -eq 0) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
    else { Say "artifacts preserved at $root" }
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'Z1 the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'Z2 no test-desktop app ever became foreground on the interactive desktop'
}

Say ''
if ($script:fail -eq 0) { Say "ALL PASS ($script:pass)"; exit 0 }
Say "$script:fail FAILURE(S) ($script:pass passed)"
exit 1
