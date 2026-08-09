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
#   NO AGENT (J) - T398. Kill the app AND the agent, point the agent binary
#   override at a path that does not exist, and relaunch. Restore used to
#   resolve the connection FIRST and give up without one - correct for a
#   terminal (there is nothing to ATTACH to) and true of no viewer pane at all,
#   so a manifest whose windows are viewers was dropped for a reason that
#   applied to none of its leaves. Now the viewer-only window comes back at its
#   recorded location, the mixed window comes back with its terminal degraded to
#   a fresh local pane in place, and a terminal-ONLY window would still be
#   dropped (its every leaf is a gone session). J5/J6 are the controls that no
#   agent quietly came back to make any of it true the easy way.
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
# T652: the "attached is not alive" oracle for TERMINAL panes. The viewer half
# of that claim has no shell to type into and is built below (Wait-ViewerTitleNum
# over a local page server), honoring the same GHOZTTY_TEST_LIVENESS_BREAK
# teeth-switch.
. (Join-Path $PSScriptRoot 'lib\PaneLiveness.ps1')

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

# ---- the viewer liveness oracle (T652) --------------------------------------
# A viewer has no shell, so "type into it and require an answer" has no meaning
# here. The equivalent claim is that the PAGE still responds: a reload must
# reach the WebView2, be fetched from origin, run, and have its result arrive
# back in the app. This little raw-TCP server (viewer-panes.ps1's shape - no
# HttpListener URL-ACL to register) answers every GET with a page whose <title>
# carries that request's ordinal and Cache-Control: no-store. `+list --json`
# reports a viewer leaf's title, so an ADVANCING number is proof of the whole
# round trip; a pane holding a last painted frame keeps the number it had.
$vrPort = 47652
$vrHits = Join-Path $env:TEMP "ghoztty-vr-hits-$PID.txt"
Remove-Item $vrHits -ErrorAction SilentlyContinue
$vrUrl = "http://127.0.0.1:$vrPort/"

# By WINDOW target: `--target=` names the window, and its lone viewer pane
# carries only an auto-registered name of its own.
function Get-ViewerTitle($target) {
    $w = Get-Win $target
    if ($null -eq $w) { return '' }
    $leaves = @(Get-Leaves $w.tabs[0].splits)
    if ($leaves.Count -lt 1) { return '' }
    return [string]$leaves[0].title
}

# Poll until the pane reports a title ordinal greater than $afterN. Returns the
# number, or -1 on timeout. GHOZTTY_TEST_LIVENESS_BREAK looks for a title the
# server never serves, so this arm goes red with the terminal ones.
function Wait-ViewerTitleNum($name, $afterN, $timeoutSec = 30) {
    $pattern = '^vrlive(\d+)$'
    if ($env:GHOZTTY_TEST_LIVENESS_BREAK -eq '1') { $pattern = '^vrliveBREAK(\d+)$' }
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $t = Get-ViewerTitle $name
        if ($t -match $pattern -and [int]$Matches[1] -gt $afterN) { return [int]$Matches[1] }
        Start-Sleep -Milliseconds 600
    }
    return -1
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

$script:vrJob = Start-Job -ScriptBlock {
    param($port, $hitsFile)
    $n = 0
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
    $listener.Start()
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            Start-Sleep -Milliseconds 50
            $buf = New-Object byte[] 8192
            $req = ''
            while ($stream.DataAvailable) {
                $r = $stream.Read($buf, 0, $buf.Length)
                if ($r -le 0) { break }
                $req += [Text.Encoding]::UTF8.GetString($buf, 0, $r)
            }
            $line = ($req -split "`r`n")[0]
            if ($line -match '^GET ') {
                $n++
                Add-Content -Path $hitsFile -Value "GET $n $line"
                $html = '<html><head><title>vrlive' + $n + '</title></head><body>vrlive' + $n + '</body></html>'
                $payload = [Text.Encoding]::UTF8.GetBytes($html)
                $head = "HTTP/1.1 200 OK`r`nContent-Type: text/html`r`nCache-Control: no-store`r`n" +
                    "Content-Length: $($payload.Length)`r`nConnection: close`r`n`r`n"
                $out = [Text.Encoding]::UTF8.GetBytes($head) + $payload
                $stream.Write($out, 0, $out.Length)
                $stream.Flush()
            }
        } catch {}
        $client.Close()
    }
} -ArgumentList $vrPort, $vrHits

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

    # A web viewer, for the T652 liveness claim: a restored FILE viewer's title
    # is its basename either way, so only a served page can say whether the pane
    # is still fetching and reporting or holding a picture.
    $r = Invoke-Verb @('+new-window', '--target=vrweb', "--view=$vrUrl")
    Assert ($r.Code -eq 0) "+new-window --view=<http> exits 0 (got $($r.Code))"
    $vrN0 = Wait-ViewerTitleNum 'vrweb' 0 40
    Assert ($vrN0 -gt 0) `
        "L0 the page server's title reaches the app pre-restore (positive control, got $vrN0)"

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
        # H2 (T652): ATTACHED IS NOT ALIVE. H1 is the agent's answer about a
        # session id, and D-G are read off `+list --json`; a pane that came back
        # as a frozen picture satisfies every one of them. Type into the
        # re-attached terminal that shares this window with the viewers.
        Assert (Test-PaneLive -Exe $exe -Target 'vrterm' -Tmp $root -Tag 'VRT') `
            'H2 the re-attached terminal is LIVE: input reaches the child, output returns'
    }

    # ---- L: the restored VIEWERS still respond (the viewer half of T652) -----
    # A viewer has no shell, so the equivalent of typing is asking the page for
    # something new. The restore itself re-navigates, so the pane must first
    # report a HIGHER ordinal than it did before the app died; then a `+reload`
    # must fetch again and report higher still. E1/E2 above only say the pane is
    # POINTED at a location - true of a dead WebView showing its last frame.
    Say '== L: the restored viewers still respond'
    $vrN1 = Wait-ViewerTitleNum 'vrweb' $vrN0 45
    Assert ($vrN1 -gt $vrN0) `
        "L1 the restored web viewer fetched its page again (title $vrN0 -> $vrN1)"
    $r = Invoke-Verb @('+reload', '--target=vrweb')
    Assert ($r.Code -eq 0) "L2 +reload of the restored viewer exits 0 (got $($r.Code))"
    $vrN2 = Wait-ViewerTitleNum 'vrweb' $vrN1 30
    Assert ($vrN2 -gt $vrN1) `
        "L3 the reload LANDED: the page was re-fetched and its title came back (title $vrN1 -> $vrN2)"

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

    # ---- J: restore with NO local agent at all (T398) ------------------------
    # Kill the app AND the agent, then point the binary override at a path that
    # does not exist so the relaunch cannot spawn one either. Every recorded
    # terminal session is now genuinely gone; every recorded viewer never needed
    # one.
    Say '== J: restore with no local agent'
    Stop-RepoInstances
    $env:LOCALAPPDATA = $tmp
    $env:GHOSTTY_LOCAL_AGENT_BIN = (Join-Path $root 'no-such-agent.exe')
    Assert (-not (Test-Path $env:GHOSTTY_LOCAL_AGENT_BIN)) `
        'J0 the agent binary override points at nothing (setup control)'

    $agentless = Start-OnTestDesktop -Exe $exe
    if ((Wait-TestWindow -ProcessId $agentless.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Say 'SETUP FAIL: agentless app has no GhozttyWindow'
    }

    $missJ = @(Wait-Panes 'vrmiss' 1 45)
    Assert ($missJ.Count -eq 1) `
        "J1 the viewer-only window restored with no agent (got $($missJ.Count) panes)"
    if ($missJ.Count -eq 1) {
        Assert ($missJ[0].type -eq 'viewer' -and $missJ[0].url -eq $missingFile) `
            "J2 it came back at its recorded location (got '$($missJ[0].type)' '$($missJ[0].url)')"
    }

    $vrJ = @(Wait-Panes 'vr' 3 45)
    Assert ($vrJ.Count -eq 3) "J3 the mixed window restored all three panes (got $($vrJ.Count))"
    if ($vrJ.Count -eq 3) {
        $kindsJ = @($vrJ | ForEach-Object { $_.type })
        Assert (($kindsJ -join ',') -eq 'viewer,terminal,viewer') `
            "J4 its terminal degraded to a fresh pane in place (got $($kindsJ -join ','))"
    }

    # The controls. Without these, an agent that quietly came back would make
    # J1-J4 pass as an ordinary re-attach and prove nothing about T398.
    $agentProcs = @(Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') })
    Assert ($agentProcs.Count -eq 0) `
        "J5 no local agent is running (control, got $($agentProcs.Count))"
    Assert ((@(Alive-Ids)).Count -eq 0) `
        'J6 no agent session is reachable (control: there was nothing to ATTACH to)'

    # J7 (T652): the agentless restore rebuilds viewers on a path of its own, so
    # it gets its own liveness reading rather than inheriting L's.
    $vrN3 = Wait-ViewerTitleNum 'vrweb' $vrN2 45
    Assert ($vrN3 -gt $vrN2) `
        "J7 the agentless restore's web viewer is LIVE too (title $vrN2 -> $vrN3)"

} finally {
    Say '== cleanup'
    if ($null -ne $script:vrJob) {
        Stop-Job $script:vrJob -ErrorAction SilentlyContinue
        Remove-Job $script:vrJob -Force -ErrorAction SilentlyContinue
    }
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
