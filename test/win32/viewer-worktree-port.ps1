# T638 acceptance: leg 2 of viewer worktree provenance -- localhost:PORT ->
# the listening process -> that process's working directory.
#
# What is asserted:
#
#   - a pane on `http://localhost:<port>` where a server IS listening resolves
#     the SERVER's checkout, not the pane's origin directory. The two are
#     deliberately different working trees, so this can only pass if the port
#     lookup actually ran.
#   - a pane on a port where NOBODY is listening falls back to the pane's
#     origin directory (leg 3), rather than erroring, hanging, or going blank.
#   - a listener whose working directory is in NO repository resolves to no
#     worktree -- leg 2 won and honestly found nothing. This is Mac's shape
#     (`ViewerWorktree.candidateDirectory` returns the cwd and lets git decide),
#     not a fall-through to the origin, and it is the third distinct outcome the
#     same URL shape can produce.
#   - the resolution never wedges the UI: every case answers inside the poll
#     window and the app is still alive and serving IPC at the end.
#
# ORACLE: the same one T633's `viewer-worktree.ps1` uses, and for the same
# reason (native chrome on a background desktop cannot be screenshotted) --
#     viewer worktree pane=<id> feedback=shown|hidden worktree=<path>
# emitted from `pushWorktree`, the exact code path that hands the nav bar its
# feedback button.
#
# POSITIVE CONTROLS: the three cases run against ONE app in ONE run and produce
# three DIFFERENT answers (the temp repo / this repo / nothing). A run that
# resolved nothing at all, or resolved everything to the origin, fails -- which
# is what keeps a green-and-empty pass impossible.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\viewer-worktree-port.ps1
param(
    [string]$ExePath,
    [switch]$Interactive
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

# Isolate the IPC endpoint (inherited through CreateProcessW).
$env:GHOZTTY_PIPE_SUFFIX = '-wtport'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

function Invoke-Verb([string[]]$VerbArgs) {
    $out = (& $exe @VerbArgs 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Get-Data {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    return ($json | ConvertFrom-Json).data
}

function Get-Leaves($node) {
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    return @(Get-Leaves $node.left) + @(Get-Leaves $node.right)
}

function Get-Win($target) {
    $data = Get-Data
    if (-not $data) { return $null }
    foreach ($w in $data.windows) { if ($w.target -eq $target) { return $w } }
    return $null
}

function Wait-Win($target) {
    for ($t = 0; $t -lt 25; $t++) {
        $w = Get-Win $target
        if ($w) { return $w }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Get-OnlyPaneId($target) {
    $w = Get-Win $target
    if (-not $w) { return $null }
    $leaves = @(Get-Leaves $w.tabs[0].splits)
    if ($leaves.Count -ne 1) { return $null }
    return $leaves[0].id
}

function Get-WorktreeState($errlog, $paneId) {
    if (-not (Test-Path $errlog)) { return $null }
    if (-not $paneId) { return $null }
    $hit = $null
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match "viewer worktree pane=$([regex]::Escape($paneId)) feedback=(\w+) worktree=(.+)$") {
            $hit = [pscustomobject]@{ Shown = ($Matches[1] -eq 'shown'); Worktree = $Matches[2].Trim() }
        }
    }
    return $hit
}

function Wait-WorktreeState($errlog, $paneId, [bool]$Shown) {
    for ($t = 0; $t -lt 40; $t++) {
        $s = Get-WorktreeState $errlog $paneId
        if ($s -and $s.Shown -eq $Shown) { return $s }
        Start-Sleep -Milliseconds 250
    }
    return (Get-WorktreeState $errlog $paneId)
}

# A port nobody holds: bind an ephemeral one and let it go. A port that WAS
# free a moment ago beats a guessed number, which is how these scripts collide
# with whatever else is running on the box.
function Get-FreePort {
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $l.Start()
    $p = $l.LocalEndpoint.Port
    $l.Stop()
    return $p
}

# A dev server stand-in: a bare TCP listener that answers one minimal HTTP
# response per connection, started with its cwd set to $Directory. A raw socket
# rather than System.Net.HttpListener on purpose -- HttpListener's prefixes go
# through http.sys URL ACLs, and this test's subject is the port lookup, not
# the box's registration policy.
function Start-Listener([int]$Port, [string]$Directory) {
    $body = @"
`$l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
`$l.Start()
while (`$true) {
    `$c = `$l.AcceptTcpClient()
    try {
        `$s = `$c.GetStream()
        `$b = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: text/plain`r`nContent-Length: 5`r`nConnection: close`r`n`r`nhello")
        `$s.Write(`$b, 0, `$b.Length)
        `$s.Flush()
    } catch {}
    `$c.Close()
}
"@
    $script = Join-Path $env:TEMP ("ghoztty-t638-listener-$Port.ps1")
    Set-Content -Path $script -Value $body -Encoding utf8
    $p = Start-Process powershell -PassThru -WindowStyle Hidden `
        -WorkingDirectory $Directory `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script)
    # Wait until it is actually accepting: a pane opened before the socket is
    # up would resolve leg 3 and the test would blame the lookup.
    for ($t = 0; $t -lt 60; $t++) {
        try {
            $c = [System.Net.Sockets.TcpClient]::new()
            $c.Connect('127.0.0.1', $Port)
            $c.Close()
            return [pscustomobject]@{ Process = $p; Script = $script }
        } catch { Start-Sleep -Milliseconds 250 }
    }
    return [pscustomobject]@{ Process = $p; Script = $script; Failed = $true }
}

# --- setup ------------------------------------------------------------------

$repoRoot = (& git -C $repo rev-parse --show-toplevel 2>$null | Out-String).Trim()
if (-not $repoRoot) { Write-Host "SETUP FAIL: $repo is not a working tree"; exit 1 }
$repoRoot = $repoRoot -replace '/', '\'

# %TEMP% must be in NO working tree, or the "listener in no repo" case proves
# nothing and the "listener elsewhere" case might accidentally agree with the
# origin.
$outside = $env:TEMP
$outsideRoot = (& git -C $outside rev-parse --show-toplevel 2>$null | Out-String).Trim()
if ($outsideRoot) {
    Write-Host "SETUP FAIL: `$env:TEMP ($outside) is inside a working tree ($outsideRoot);"
    Write-Host '            the leg-2 cases could not be told apart from leg 3.'
    exit 1
}

# A SECOND working tree, so "the listener's checkout" and "the pane's origin"
# are different answers and the assertion has something to discriminate.
$serverRepo = Join-Path $outside ("ghoztty-t638-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $serverRepo -Force | Out-Null
& git -C $serverRepo init --quiet 2>&1 | Out-Null
$serverRoot = (& git -C $serverRepo rev-parse --show-toplevel 2>$null | Out-String).Trim()
if (-not $serverRoot) { Write-Host "SETUP FAIL: could not make a scratch repo at $serverRepo"; exit 1 }
$serverRoot = $serverRoot -replace '/', '\'
if ($serverRoot -ieq $repoRoot) { Write-Host 'SETUP FAIL: the scratch repo IS this repo'; exit 1 }

$livePort = Get-FreePort
$deadPort = Get-FreePort
$outsidePort = Get-FreePort

$listeners = @()
Stop-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    $inRepo = Start-Listener -Port $livePort -Directory $serverRepo
    $listeners += $inRepo
    if ($inRepo.Failed) { Write-Host "SETUP FAIL: no listener came up on $livePort"; exit 1 }
    $noRepo = Start-Listener -Port $outsidePort -Directory $outside
    $listeners += $noRepo
    if ($noRepo.Failed) { Write-Host "SETUP FAIL: no listener came up on $outsidePort"; exit 1 }

    $errlog = Join-Path $env:TEMP 'ghoztty-viewer-worktree-port-stderr.log'
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $appPid = $app.Pid
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }

    # --- 1. leg 2 beats leg 3 ------------------------------------------------
    # The pane is OPENED from this repo and POINTED at a server running out of
    # a different one. The server's checkout is the right answer: that is the
    # code the page came from.
    $r = Invoke-Verb @('+new-window', '--target=wtlive', "--view=http://localhost:$livePort/", "--working-directory=$repo")
    Assert ($r.Code -eq 0) "+new-window --view=http://localhost:$livePort/ exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 'wtlive')) 'the localhost viewer window exists'
    $livePane = Get-OnlyPaneId 'wtlive'
    Assert ($null -ne $livePane) "the localhost viewer window has exactly one pane (id '$livePane')"
    $s = Wait-WorktreeState $errlog $livePane $true
    Assert ($null -ne $s) 'the localhost pane reported a worktree resolution'
    Assert ($s -and $s.Shown) "a pane on a live dev server SHOWS the feedback button (state '$($s.Shown)')"
    Assert ($s -and $s.Worktree -ieq $serverRoot) `
        "...pointed at the LISTENER's working tree, not the pane's origin (got '$($s.Worktree)', want '$serverRoot')"
    Assert ($s -and -not ($s.Worktree -ieq $repoRoot)) `
        '...and specifically NOT the origin directory, so leg 2 really ran'

    # --- 2. no listener -> leg 3 --------------------------------------------
    # Same URL shape, nobody home: the pane still belongs to where it was
    # opened from. An unattributable port is a fallback, not a dead end.
    $r = Invoke-Verb @('+new-window', '--target=wtdead', "--view=http://localhost:$deadPort/", "--working-directory=$repo")
    Assert ($r.Code -eq 0) "+new-window --view=http://localhost:$deadPort/ (no listener) exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 'wtdead')) 'the dead-port viewer window exists'
    $deadPane = Get-OnlyPaneId 'wtdead'
    $s = Wait-WorktreeState $errlog $deadPane $true
    Assert ($null -ne $s) 'the dead-port pane reported a worktree resolution (it did not hang)'
    Assert ($s -and $s.Shown) "a port with no listener still SHOWS the button via the origin (state '$($s.Shown)')"
    Assert ($s -and $s.Worktree -ieq $repoRoot) `
        "...pointed at the origin directory's working tree (got '$($s.Worktree)', want '$repoRoot')"

    # --- 3. a listener in no repository -> no worktree ----------------------
    # Leg 2 answered; the answer is that this server runs out of nowhere in
    # particular. Mac's shape: the listener's cwd REPLACES the origin, and git
    # then finds nothing, so the button is honestly absent.
    $r = Invoke-Verb @('+new-window', '--target=wtnorepo', "--view=http://localhost:$outsidePort/", "--working-directory=$repo")
    Assert ($r.Code -eq 0) "+new-window --view=http://localhost:$outsidePort/ (listener in no repo) exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 'wtnorepo')) 'the no-repo-listener viewer window exists'
    $norepoPane = Get-OnlyPaneId 'wtnorepo'
    $s = Wait-WorktreeState $errlog $norepoPane $false
    Assert ($null -ne $s) 'the no-repo-listener pane reported a worktree resolution'
    Assert ($s -and -not $s.Shown) `
        "a server running out of no repository shows NO button, even from a repo pane (state '$($s.Shown)')"

    # --- 4. the app is still healthy ----------------------------------------
    # Three port lookups ran on worker threads; the message loop must be
    # untouched by them, which is observable as the app still answering IPC.
    $r = Invoke-Verb @('+list')
    Assert ($r.Code -eq 0) '+list still answers after every lookup (the UI thread never blocked)'
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'GUI process alive after all scenarios'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI never became visible on the interactive desktop'
} finally {
    Remove-TestDesktop
    Stop-RepoInstances
    foreach ($l in $listeners) {
        if ($l.Process -and -not $l.Process.HasExited) {
            Stop-Process -Id $l.Process.Id -Force -ErrorAction SilentlyContinue
        }
        if ($l.Script) { Remove-Item $l.Script -Force -ErrorAction SilentlyContinue }
    }
    # Only ever the scratch tree this run created, under %TEMP%.
    if ($serverRepo -and (Test-Path $serverRepo) -and $serverRepo.StartsWith($outside)) {
        Remove-Item $serverRepo -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)"; exit 1 }
