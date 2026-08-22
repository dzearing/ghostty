# T220 acceptance: a force-kill right after a drag-resize must NOT restore
# the pre-resize window frame.
#
# Two stores record window geometry: the placement memory
# (window_placement-debug, T85 - one global "last user-chosen size", read by
# NEW windows) and the session-layout manifest (per-window frame, replayed by
# restore). Before T220 the placement file was written synchronously at drag
# end while the manifest ride was a 250ms debounce, so a kill/crash inside
# that window stranded the manifest - and the agent's layout blobs - at the
# pre-resize frame, and the relaunch restored a window that had "forgotten"
# its size (observed intermittently while migrating window-size-memory.ps1,
# 2026-07-31). The fix writes both stores at the same gesture, manifest FIRST.
#
# The proof exploits that ordering: after a drag-resize, this script waits
# only for the PLACEMENT file to show the new size - which the handler writes
# AFTER the manifest sync - then kills the app with no further delay. If the
# manifest were still on a debounce, the kill would land well inside 250ms
# and the restore would come back at the old size. Post-fix, the manifest is
# provably already on disk (asserted directly, after the kill), and the
# relaunched app restores the new frame. Three iterations, because the
# original defect was intermittent - a single green run is not evidence.
#
# Session persistence stays ON (it is the subject); the relaunch goes through
# the real manifest+agent-blob restore path. Runs on a background desktop
# (TestDesktop.ps1). Only touches ghoztty processes running from this repo's
# zig-out*.
param([string]$ExePath, [switch]$Interactive)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$env:GHOZTTY_PIPE_SUFFIX = "-geomracetest$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# Throwaway LOCALAPPDATA: the placement memory, the manifest AND the agent's
# state dir all derive from it, so the run is fully isolated from the user.
$fakeLocal = Join-Path $env:TEMP ("ghoztty-t220-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $fakeLocal | Out-Null
$memFile = Join-Path $fakeLocal 'ghoztty\window_placement-debug'
$manifest = Join-Path $fakeLocal 'ghoztty\session-layout-debug.json'

function Read-Mem {
    if (Test-Path $memFile) { (Get-Content $memFile -Raw).Trim() } else { '<absent>' }
}

function Kill-RepoInstances([switch]$Agent) {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy. -Agent maps straight onto the shared switch: without it the sibling agent
    # is left alone, which is what this script wants between its restore arms.
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly:(-not $Agent) -SettleMs 500)
}

function Get-Outer([IntPtr]$h) { $r = Get-TestWindowRect -Window $h; "$($r.Width),$($r.Height)" }

# Launch with LOCALAPPDATA redirected; sets $script:app / $script:top.
function Launch {
    $savedLocal = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $fakeLocal
    try {
        # -KeepWindowPlacement: the relaunch half of each iteration must see
        # what the previous launch persisted - deleting it would delete the
        # subject (the window-size-memory.ps1 opt-out shape).
        $a = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=true') -KeepWindowPlacement
    } finally {
        $env:LOCALAPPDATA = $savedLocal
    }
    Start-Sleep -Seconds 3
    if ($a.Process -and $a.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $t = Wait-TestWindow -ProcessId $a.Pid -Class 'GhozttyWindow'
    if ($t -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $a.Pid)) 'launch: window is NOT enumerable on the interactive desktop'
    $script:app = $a
    $script:top = $t
    $script:launched += $a.Pid
}

$script:launched = @()
Kill-RepoInstances -Agent
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    for ($iter = 1; $iter -le 3; $iter++) {
        # Fresh stores each iteration so the assertions never ride on a
        # previous iteration's writes. The whole state dir, not just the two
        # geometry files: the AGENT's blob store lives here too, and a fresh
        # agent materializes it from disk - a leftover blob would restore the
        # previous iteration's window into this one's "fresh profile" check.
        Kill-RepoInstances -Agent
        Remove-Item -Recurse -Force (Join-Path $fakeLocal 'ghoztty') -ErrorAction SilentlyContinue

        Launch
        $init = Get-Outer $top
        Assert ($init -eq '800,600') "[$iter] fresh profile opens at the 800x600 default (got $init)"

        # The real drag message sequence: ENTERSIZEMOVE -> SetWindowPos ->
        # EXITSIZEMOVE. The handler syncs the manifest, THEN writes the
        # placement file - so the placement file appearing with the new size
        # proves the manifest write already happened.
        Invoke-TestDragResize -Window $top -DeltaWidth 150 -DeltaHeight 100 | Out-Null
        $mem = ''
        for ($t = 0; $t -lt 40; $t++) {
            Start-Sleep -Milliseconds 100
            $mem = Read-Mem
            if ($mem -eq '950 700 0') { break }
        }
        Assert ($mem -eq '950 700 0') "[$iter] drag-resize persisted the placement memory (got '$mem')"

        # Kill NOW - no settle sleep. Pre-T220 this lands inside the 250ms
        # manifest debounce and loses the frame update.
        Stop-Process -Id $script:app.Pid -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400

        # Direct evidence: the manifest on disk already carries the resized
        # frame (it was written BEFORE the placement file this run keyed on).
        $mtext = if (Test-Path $manifest) { Get-Content $manifest -Raw } else { '<absent>' }
        Assert ($mtext -match '"w"\s*:\s*950' -and $mtext -match '"h"\s*:\s*700') "[$iter] manifest frame is 950x700 after the kill"

        # And the behavior: a relaunch restores the resized window, not the
        # pre-resize one.
        Launch
        $outer = Get-Outer $top
        Assert ($outer -eq '950,700') "[$iter] relaunch restored the resized 950,700 frame (got $outer)"
        Assert (-not ($app.Process -and $app.Process.HasExited)) "[$iter] no crash"
        Stop-Process -Id $script:app.Pid -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400
    }
} finally {
    Remove-TestDesktop
    Kill-RepoInstances -Agent
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
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
