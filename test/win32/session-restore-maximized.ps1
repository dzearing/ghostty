# T748 acceptance: session restore round-trips a window's MAXIMIZED state and
# its normal rect, instead of leaving a window Windows still calls maximized
# sitting at a normal window's size.
#
# The reported symptom (user, 2026-08-11): after an upgrade, every restored
# window came back "maximized" with no window border and odd rendering. The
# mechanism: by the time restore applies a window's recorded frame the window
# has ALREADY been shown - and shown maximized whenever the T85 placement
# memory says the user's last window was, which for a user who works maximized
# is every window on every launch. `SetWindowPos` then moves and resizes that
# window WITHOUT clearing WS_MAXIMIZE, so IsZoomed stays true (the caption drops
# its resize border and lays itself out for a maximized window) at a normal
# window's size, and the ShowWindow(SW_MAXIMIZE) behind it is a no-op because
# the window is already in the state it asks for. `SetWindowPlacement` sets both
# halves at once, which is the fix.
#
# Two directions, because the placement memory and the manifest can disagree
# either way:
#
#   A. memory maximized + manifest maximized -> the window really fills the
#      screen (the report's case).
#   B. memory maximized + manifest NOT maximized -> the window really is a
#      normal window at its recorded size (the mirror image, which the same
#      SetWindowPos defect produced).
#
# The "really" is the whole point, so the predicate is asserted twice: once
# against a window maximized live through the real WM_SYSCOMMAND path (the
# positive control - it proves the predicate recognizes a genuinely maximized
# window) and once after the relaunch (the subject).
#
# Section B constructs its state by editing the manifest on disk between the
# kill and the relaunch: the manifest is restore's own input, the local file
# wins over any agent-held blob for the same window (session_layout.reconcile),
# and the placement memory is left alone at maximized=1.
#
# Isolation: LOCALAPPDATA points at a throwaway dir for every launched
# instance, so the placement memory, the manifest and the agent state dir are
# all this run's own. Session persistence stays ON - it is what restore needs.
# Runs on a BACKGROUND desktop (lib\TestDesktop.ps1); only touches ghoztty
# processes running from this repo's zig-out*.
param([string]$ExePath, [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
# Isolate the IPC endpoint (inherited through CreateProcessW): a launch that
# found the user's instance on the shared pipe would forward and exit.
$env:GHOZTTY_PIPE_SUFFIX = '-restoremaxtest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# Throwaway LOCALAPPDATA: placement memory, manifest AND the agent's state dir
# all derive from it, so the run is fully isolated from the user.
$fakeLocal = Join-Path $env:TEMP ("ghoztty-t748-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $fakeLocal | Out-Null
$memFile = Join-Path $fakeLocal 'ghoztty\window_placement-debug'
$manifest = Join-Path $fakeLocal 'ghoztty\session-layout-debug.json'

function Read-Mem {
    if (Test-Path $memFile) { (Get-Content $memFile -Raw).Trim() } else { '<absent>' }
}

function Read-Manifest {
    if (Test-Path $manifest) { Get-Content $manifest -Raw } else { '<absent>' }
}

function Kill-RepoInstances {
    foreach ($f in @("Name='ghoztty.exe'", "Name='ghoztty-agent.exe'")) {
        Get-CimInstance Win32_Process -Filter $f |
            Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 500
}

# Does this window actually FILL the screen? A maximized window's outer frame
# may overhang the work area by the resize border, so the test is ">= the work
# area, minus a couple of pixels of slack", never equality. On the background
# desktop there is no taskbar, so the work area is the whole screen.
function Test-FillsScreen([IntPtr]$h) {
    $r = Get-TestWindowRect -Window $h
    $w = Get-TestWorkArea
    return (($r.Width -ge ($w.Width - 8)) -and ($r.Height -ge ($w.Height - 8)))
}

function Show-Geometry([IntPtr]$h, [string]$tag) {
    $r = Get-TestWindowRect -Window $h
    $z = Test-TestWindowZoomed -Window $h
    Write-Host ("      {0}: {1}x{2} at {3},{4} zoomed={5}" -f $tag, $r.Width, $r.Height, $r.Left, $r.Top, $z)
}

# Launch with LOCALAPPDATA redirected; sets $script:app / $script:top.
# -KeepWindowPlacement: the relaunch half of each section must see what the
# previous launch persisted - deleting it would delete half the subject.
function Launch {
    $savedLocal = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $fakeLocal
    try {
        # persistence: ON - the manifest restore path IS the subject.
        $a = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=true') -KeepWindowPlacement
    } finally {
        $env:LOCALAPPDATA = $savedLocal
    }
    Start-Sleep -Seconds 3
    if ($a.Process -and $a.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $t = Wait-TestWindow -ProcessId $a.Pid -Class 'GhozttyWindow'
    if ($t -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    $script:app = $a
    $script:top = $t
    $script:launched += $a.Pid
}

function Stop-App {
    if ($script:app) { Stop-Process -Id $script:app.Pid -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 600
}

$script:launched = @()
Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # ---------------------------------------------------------------- A
    # Fresh profile, maximize, kill, relaunch: the window must come back
    # actually maximized, not merely flagged.
    Write-Host ''
    Write-Host '--- A: a maximized window restores maximized ---'
    Remove-Item -Recurse -Force (Join-Path $fakeLocal 'ghoztty') -ErrorAction SilentlyContinue

    Launch
    $init = Get-TestWindowRect -Window $top
    Assert ($init.Width -eq 800 -and $init.Height -eq 600) "fresh profile opens at the 800x600 default (got $($init.Width)x$($init.Height))"
    Assert (-not (Test-TestWindowZoomed -Window $top)) 'fresh profile opens un-maximized'
    Assert (-not (Test-FillsScreen $top)) 'negative control: an 800x600 window does NOT fill the screen'

    # The real maximize path (WM_SYSCOMMAND), which is what writes both stores:
    # manifest first, placement memory second - so the memory reading "... 1"
    # proves the manifest already carries maximized:true.
    Send-TestSysCommand -Window $top -Command maximize | Out-Null
    $mem = ''
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 100
        $mem = Read-Mem
        if ($mem -match ' 1$') { break }
    }
    Assert ($mem -match ' 1$') "maximize persisted the placement memory as maximized (got '$mem')"
    Show-Geometry $top 'live maximize'
    Assert (Test-TestWindowZoomed -Window $top) 'live maximize: IsZoomed'
    Assert (Test-FillsScreen $top) 'positive control: a genuinely maximized window fills the screen'

    Stop-App
    $mtext = Read-Manifest
    Assert ($mtext -match '"maximized"\s*:\s*true') 'manifest recorded maximized:true'
    $frame = if ($mtext -match '"frame"\s*:\s*\{\s*"x"\s*:\s*(-?\d+)\s*,\s*"y"\s*:\s*(-?\d+)\s*,\s*"w"\s*:\s*(\d+)\s*,\s*"h"\s*:\s*(\d+)') {
        [pscustomobject]@{ X = [int]$Matches[1]; Y = [int]$Matches[2]; W = [int]$Matches[3]; H = [int]$Matches[4] }
    } else { $null }
    Assert ($null -ne $frame) 'manifest recorded the maximized window''s restore-down frame'

    Launch
    Show-Geometry $top 'restored'
    Assert (Test-TestWindowZoomed -Window $top) 'restored window is flagged maximized'
    # THE T748 ASSERTION: pre-fix this window is flagged maximized at 800x600.
    Assert (Test-FillsScreen $top) 'restored window actually fills the screen (T748)'
    # ...and the restore-down rect made the trip too, which is what says the
    # placement was really applied rather than the call having done nothing at
    # all (a maximized window that STAYS maximized looks the same either way).
    if ($frame) {
        $n = Get-TestWindowNormalRect -Window $top
        Write-Host ("      restored normal rect: {0}x{1} at {2},{3} (manifest {4}x{5} at {6},{7})" -f `
            $n.Width, $n.Height, $n.Left, $n.Top, $frame.W, $frame.H, $frame.X, $frame.Y)
        Assert ($n.Width -eq $frame.W -and $n.Height -eq $frame.H -and
                $n.Left -eq $frame.X -and $n.Top -eq $frame.Y) "restored window's restore-down rect is the manifest's frame"
    }
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'A: no crash'

    # ---------------------------------------------------------------- B
    # The mirror image: the placement memory still says maximized (so the
    # window is shown maximized before the frame is applied) while the
    # manifest says this window was NOT. It must come back a normal window.
    Write-Host ''
    Write-Host '--- B: a NON-maximized window restores un-maximized, over a maximized memory ---'
    Stop-App

    $mem = Read-Mem
    Assert ($mem -match ' 1$') "B setup: the placement memory still says maximized (got '$mem')"
    $mtext = Read-Manifest
    $patched = $mtext -replace '"maximized"\s*:\s*true', '"maximized":false'
    Assert ($patched -ne $mtext) 'B setup: manifest patched to maximized:false'
    # NOT Set-Content -Encoding UTF8: PowerShell 5.1 writes a BOM, the JSON
    # parser rejects the file, restore silently falls back to "no local
    # manifest" - and the fresh window it opens instead looks enough like a
    # restored one to score this section green for the wrong reason (measured
    # while writing this script).
    [System.IO.File]::WriteAllText($manifest, $patched, (New-Object System.Text.UTF8Encoding $false))
    Assert (([System.IO.File]::ReadAllBytes($manifest))[0] -eq 0x7B) 'B setup: patched manifest starts with { (no BOM)'
    $want = if ((Read-Manifest) -match '"w"\s*:\s*(\d+)\s*,\s*"h"\s*:\s*(\d+)') {
        [pscustomobject]@{ W = [int]$Matches[1]; H = [int]$Matches[2] }
    } else { $null }
    Assert ($null -ne $want) 'B setup: manifest carries a normal-rect w/h to restore to'

    Launch
    Show-Geometry $top 'restored (manifest says normal)'
    # THE MIRROR ASSERTION: pre-fix this window is flagged maximized at the
    # recorded 800x600 rect - the same hybrid, reached from the other side.
    Assert (-not (Test-TestWindowZoomed -Window $top)) 'restored window is NOT flagged maximized (T748 mirror)'
    Assert (-not (Test-FillsScreen $top)) 'restored window does not fill the screen'
    if ($want) {
        $r = Get-TestWindowRect -Window $top
        Assert ($r.Width -eq $want.W -and $r.Height -eq $want.H) "restored window is the manifest's $($want.W)x$($want.H) frame (got $($r.Width)x$($r.Height))"
    }
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'B: no crash'
    Stop-App
} finally {
    Remove-TestDesktop
    Kill-RepoInstances
    Remove-Item -Recurse -Force $fakeLocal -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($script:launched | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Write-Host ''
Write-TestVerdict -Label 'T748 RESTORE-MAXIMIZED' -Pass $script:pass -Fail $script:fail -MinPass 16
