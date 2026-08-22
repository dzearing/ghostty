# T85 acceptance: new windows remember the last user-chosen size.
#
# Memory precedence: explicit window-width/height config > remembered
# placement (%LOCALAPPDATA%\ghoztty\window_placement-debug for Debug
# builds) > 800x600 default. Only USER-interactive changes persist:
# drag resizes (WM_EXITSIZEMOVE) and maximize/restore transitions.
# Programmatic resizes (initial_size, reset_window_size) never write it,
# so reset_window_size stays the escape hatch (T66 semantics intact).
#
# Isolation: LOCALAPPDATA is pointed at a throwaway temp dir for every
# launched instance, so this script never touches the real user memory.
#
# Interactive resizes are simulated with the real message sequence a drag
# produces: WM_ENTERSIZEMOVE -> SetWindowPos -> WM_EXITSIZEMOVE (the
# product code reads GetWindowRect at WM_EXITSIZEMOVE, exactly what a
# mouse drag exercises) - Invoke-TestDragResize. Maximize/restore go
# through the real WM_SYSCOMMAND path - Send-TestSysCommand. The
# distinction is the whole test: Set-TestWindowSize is the programmatic
# resize that must NOT persist.
#
# Actions are bound to bare F-keys and delivered as posted WM_KEYDOWN/UP to
# the surface HWND - handleKeyEvent reads the VK from wparam and modifiers
# from GetKeyState, so no modifier state is needed. Positive control (T55
# pattern): f8=toggle_maximize with an IsZoomed oracle proves posted-key
# dispatch works before the reset assert depends on it; on failure the
# script ABORTS (not a T85 verdict).
#
# T217: runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1),
# so it never takes the user's foreground - asserted at the end, not assumed.
# The private win32 driver this script used to carry is gone. Case E's work
# area is read from the TEST desktop (Get-TestWorkArea): a background desktop
# has no taskbar, so the interactive desktop's work area is the wrong
# rectangle to clamp-check the app against.
#
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
# Isolate the IPC endpoint (inherited through CreateProcessW): a launch that
# found the user's instance on the shared pipe would forward and exit.
$env:GHOZTTY_PIPE_SUFFIX = "-winsizememtest$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# Throwaway LOCALAPPDATA so the real user memory is never touched.
$fakeLocal = Join-Path $env:TEMP ("ghoztty-t85-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $fakeLocal | Out-Null
$memFile = Join-Path $fakeLocal 'ghoztty\window_placement-debug'

function Read-Mem {
    if (Test-Path $memFile) { (Get-Content $memFile -Raw).Trim() } else { '<absent>' }
}

function Kill-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

# "width,height" of the OUTER window rect / the client area / the RESTORED
# (normal) size, which stays readable while the window is maximized.
function Get-Outer([IntPtr]$h) { $r = Get-TestWindowRect -Window $h; "$($r.Width),$($r.Height)" }
function Get-Client([IntPtr]$h) { $r = Get-TestWindowRect -Window $h -Client; "$($r.Width),$($r.Height)" }
function Get-Normal([IntPtr]$h) { $r = Get-TestWindowNormalRect -Window $h; "$($r.Width),$($r.Height)" }

# Poll until the memory file's content equals $want, return last content.
function Wait-Mem([string]$want, [int]$ms = 4000) {
    $last = ''
    for ($t = 0; $t -lt [int]($ms / 200); $t++) {
        Start-Sleep -Milliseconds 200
        $last = Read-Mem
        if ($last -eq $want) { return $last }
    }
    return $last
}

# Launch with LOCALAPPDATA redirected; sets $script:app / $script:top.
function Launch([string[]]$configArgs) {
    Kill-RepoInstances
    $savedLocal = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $fakeLocal
    try {
        # --session-persistence=false: with it ON, a section's app re-attaches
        # to the still-running agent and restores the LAYOUT MANIFEST, whose
        # geometry then competes with the placement memory this test is about.
        # The manifest write races the force-kill between sections, so the
        # relaunch size becomes nondeterministic (observed 2026-07-31: case B
        # opened 800x600 once in three runs). The T131/T155 trap.
        $cliArgs = @(
            '--session-persistence=false'
            '--keybind=f9=reset_window_size'
            '--keybind=f8=toggle_maximize'
        ) + $configArgs
        # -KeepWindowPlacement: the launch helper deletes
        # window_placement-debug before every ghoztty launch (T267) so no
        # script inherits another's geometry. Here that file IS the subject -
        # every case reads what the PREVIOUS launch persisted - so this is the
        # documented opt-out.
        $a = Start-OnTestDesktop -Exe $exe -Arguments $cliArgs -KeepWindowPlacement
    } finally {
        $env:LOCALAPPDATA = $savedLocal
    }
    Start-Sleep -Seconds 3
    if ($a.Process -and $a.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $t = Wait-TestWindow -ProcessId $a.Pid -Class 'GhozttyWindow'
    if ($t -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    $extra = Get-TestWindow -ProcessId $a.Pid -Class 'GhozttyWindow' -Exclude $t
    if ($extra -ne [IntPtr]::Zero) { Write-Host 'SETUP FAIL: more than one top window'; exit 1 }
    # Isolation, asserted per launch: the window was found on the test desktop
    # and it must NOT be enumerable on the user's.
    Assert (-not (Test-TestDesktopLeak -ProcessId $a.Pid)) 'launch: window is NOT enumerable on the interactive desktop'
    $script:app = $a
    $script:top = $t
    $script:launched += $a.Pid
}

function Stop-Instance {
    Stop-Process -Id $script:app.Pid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400
}

function Post-Key([string]$key) {
    $pane = Get-TestChildWindow -Window $script:top -Class 'GhozttyTerminal'
    if ($pane -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no terminal pane'; exit 1 }
    Send-TestKeys -Window $script:top -Target $pane -Key $key | Out-Null
}

$script:launched = @()
Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # --- Case A: fresh memory -> default, drag-resize persists ----------------
    Launch @()
    Assert ((Read-Mem) -eq '<absent>') 'A: fresh profile has no memory file'
    $init = Get-Outer $top
    Assert ($init -eq '800,600') "A: no config + no memory opens at the 800x600 default (got $init)"

    Invoke-TestDragResize -Window $top -DeltaWidth 150 -DeltaHeight 100 | Out-Null
    $mem = Wait-Mem '950 700 0'
    Assert ($mem -eq '950 700 0') "A: drag-resize persisted '950 700 0' (got '$mem')"
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'A: no crash'
    Stop-Instance

    # --- Case B: new window opens at the remembered size ----------------------
    Launch @()
    $outer = Get-Outer $top
    Assert ($outer -eq '950,700') "B: relaunch opened at remembered 950,700 (got $outer)"

    # Positive control: posted f8 (toggle_maximize) must zoom the window -
    # proves posted-key binding dispatch works before Case C's reset assert
    # depends on it. Also persists the maximize via the real action path.
    Post-Key 'F8'
    $zoomed = $false
    for ($t = 0; $t -lt 15; $t++) { Start-Sleep -Milliseconds 200; if (Test-TestWindowZoomed -Window $top) { $zoomed = $true; break } }
    if (-not $zoomed) {
        Write-Host 'ABORT: posted f8 did not maximize - key injection/binding broken, not a T85 verdict'
        Stop-Instance; exit 1
    }
    Write-Host 'OK    positive control: posted f8 maximized the window'
    $mem = Wait-Mem '950 700 1'
    Assert ($mem -eq '950 700 1') "B: maximize persisted flag + RESTORED size (got '$mem')"
    Stop-Instance   # killed while maximized -> memory says maximized

    # --- Case C: maximized memory -> opens maximized, restores to normal size -
    Launch @()
    Assert (Test-TestWindowZoomed -Window $top) 'C: relaunch with maximized memory opened maximized'
    $normal = Get-Normal $top
    Assert ($normal -eq '950,700') "C: restored size underneath is the remembered 950,700 (got $normal)"
    Send-TestSysCommand -Window $top -Command restore | Out-Null
    $mem = Wait-Mem '950 700 0'
    Assert ($mem -eq '950 700 0') "C: restore transition persisted maximized=0 (got '$mem')"
    $outer = Get-Outer $top
    Assert ($outer -eq '950,700') "C: restore returned to 950,700 (got $outer)"

    # reset_window_size is the escape hatch: client returns to the 800x600
    # default (no config), and the MEMORY FILE is untouched (programmatic).
    Post-Key 'F9'
    $client = ''
    for ($t = 0; $t -lt 20; $t++) { Start-Sleep -Milliseconds 200; $client = Get-Client $top; if ($client -eq '800,600') { break } }
    Assert ($client -eq '800,600') "C: reset_window_size still resets to the default client size (got $client)"
    $mem = Read-Mem
    # -NegativeControl inverts this expectation, so a passing run proves the
    # assertion still discriminates rather than being true of everything.
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: asserting the programmatic reset DID rewrite the memory - this run MUST fail'
        Assert ($mem -ne '950 700 0') "C (inverted): reset rewrote the memory (got '$mem')"
    } else {
        Assert ($mem -eq '950 700 0') "C: reset did NOT rewrite the memory (got '$mem')"
    }
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'C: no crash'
    Stop-Instance

    # --- Case D: explicit config wins over the memory -------------------------
    # Reference: config size with NO memory.
    Remove-Item $memFile -Force
    Launch @('--window-width=120', '--window-height=20')
    $cfgRef = Get-Client $top
    Assert ($cfgRef -ne '800,600') "D: configured 120x20 produces a non-default client ($cfgRef)"
    Stop-Instance
    # Same config with a very different memory: client must be identical.
    Set-Content -Path $memFile -Value '950 700 0' -Encoding Ascii
    Launch @('--window-width=120', '--window-height=20')
    $cfgMem = Get-Client $top
    Assert ($cfgMem -eq $cfgRef) "D: config beat the memory ($cfgMem == $cfgRef)"
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'D: no crash'
    Stop-Instance

    # --- Case E: remembered size is clamped to the work area ------------------
    Set-Content -Path $memFile -Value '25000 25000 0' -Encoding Ascii
    Launch @()
    $outer = Get-Outer $top
    $ow, $oh = ($outer -split ',') | ForEach-Object { [int]$_ }
    # The TEST desktop's work area - the one the app itself is clamping to.
    $wa = Get-TestWorkArea
    Assert ($wa.Width -gt 0 -and $wa.Height -gt 0) "E: test-desktop work area readable ($($wa.Width)x$($wa.Height))"
    Assert ($ow -le $wa.Width -and $oh -le $wa.Height) "E: oversized memory clamped to work area ($outer <= $($wa.Width),$($wa.Height))"
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'E: no crash'
    Stop-Instance

    # --- Case F: corrupt memory file falls back to the default ----------------
    Set-Content -Path $memFile -Value 'not a placement' -Encoding Ascii
    Launch @()
    $outer = Get-Outer $top
    Assert ($outer -eq '800,600') "F: corrupt memory ignored, default used (got $outer)"
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'F: no crash'
    Stop-Instance
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
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
