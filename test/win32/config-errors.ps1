# T69 acceptance: config load diagnostics are surfaced in a visible dialog
# (class 'GhozttyConfirmDialog', T80 pattern) instead of only log.err -
# which a GUI-subsystem release build sends nowhere.
#
# Covered:
#   1. Startup with a broken config -> the Configuration Errors dialog
#        appears, renders DARK, carries the custom button captions
#        ("Open Config" / "Ignore"), and Escape (=Ignore) dismisses it
#        with the terminal window staying up.
#   2. Startup with a clean config -> NO dialog.
#   3. reload_config (ctrl+shift+comma) after the file turns bad -> the
#        dialog appears (same path as startup); after fixing the file, a
#        second reload shows nothing. Positive control: ctrl+shift+r must
#        open (and Escape close) the rename dialog first, proving chord
#        injection works before any negative is trusted.
#   4. T137: the documented switch spellings (off/on, no/yes) parse with no
#        diagnostic, and a value that is not a boolean at all is REPORTED -
#        headless via +validate-config, then through the startup path where
#        the swallowed value used to cost the user their setting.
#
# Config isolation: XDG_CONFIG_HOME points at a temp dir for every launch
# (xdg.zig prefers it over LOCALAPPDATA), so the box's real config never
# leaks into these asserts and the script never touches it. The env var is
# inherited through CreateProcessW, so it reaches the test-desktop child.
#
# A dialog that never appears after a verified chord is a product FAIL;
# a chord whose positive control fails is a SETUP FAIL.
#
# T217: runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1),
# so it never takes the user's foreground - asserted at the end, not assumed.
# The private win32 driver this script used to carry is gone. Notes on the
# mechanics:
#
#   * Both dialogs here (ConfirmDialog, RenameDialog) run their keyboard
#     handling off RAW WM_KEYDOWN - ConfirmDialog in its own nested pump,
#     RenameDialog via the App.run intercept - so a POSTED Escape reaches
#     them (Send-TestControlKey). A standard #32770 would not see it.
#   * The dark-render probe reads the DIALOG's pixels (GDI chrome, so
#     PrintWindow captures them) and is guarded by Get-TestDistinctColors: a
#     capture taken mid-paint is solid black, which satisfies "is it dark?"
#     while proving nothing (T216).
#   * Button captions are read with WM_GETTEXT, not GetWindowTextW, which is
#     cross-process cached.
#
# Only touches ghoztty processes running from this repo's zig-out.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
# Isolate the IPC endpoint (inherited through CreateProcessW) so a stray
# instance answering the shared pipe cannot open windows in this run.
$env:GHOZTTY_PIPE_SUFFIX = '-cfgerrtest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

# Mean luminance of a dialog's client area, retried until the capture holds
# real content (see the header note on mid-paint black).
#
# Synchronous capture (T943): the dialog draws the frame itself under
# WM_PRINTCLIENT before the call returns. That route throws on a window that
# drew nothing instead of returning a blank frame, which is the same case this
# loop retries for - so the throw is caught and retried rather than ending the
# run on a capture taken a moment too early.
function Get-DialogDark([IntPtr]$dlg) {
    $lum = -1; $colors = 0
    for ($t = 0; $t -lt 15; $t++) {
        Start-Sleep -Milliseconds 200
        $shot = $null
        try { $shot = Get-TestWindowPixels -Window $dlg -Sync } catch { continue }
        try {
            $c = Get-TestWindowRect -Window $dlg -Client
            $colors = Get-TestDistinctColors -Shot $shot
            $lum = Get-TestBrightness -Shot $shot -Rect @($c.Left, $c.Top, $c.Right, $c.Bottom)
        } finally { Close-TestWindowPixels $shot }
        if ($colors -ge 8) { break }
    }
    return [pscustomobject]@{ Lum = $lum; Colors = $colors }
}

# Captions of every BUTTON child, read with WM_GETTEXT. Class comparison in
# the harness is exact, so enumerate all children and match case-insensitively
# (win32 reports both 'Button' and 'BUTTON' depending on how it was created).
function Get-ButtonTexts([IntPtr]$dlg) {
    $btns = @(Get-TestChildWindows -Window $dlg -Class '*' | Where-Object { $_.Class -match '^button$' })
    return @($btns | ForEach-Object { Get-TestControlText -Control ([IntPtr]$_.Hwnd) })
}

# Wait for a visible window of $cls in $gpid to appear (or to go away).
function Wait-Class([int]$gpid, [string]$cls, [bool]$appear, [int]$timeoutMs = 3000) {
    if ($appear) { return Wait-TestWindow -ProcessId $gpid -Class $cls -TimeoutMs $timeoutMs }
    $waited = 0
    while ($waited -lt $timeoutMs) {
        $d = Get-TestWindow -ProcessId $gpid -Class $cls
        if ($d -eq [IntPtr]::Zero) { return $d }
        Start-Sleep -Milliseconds 100
        $waited += 100
    }
    return (Get-TestWindow -ProcessId $gpid -Class $cls)
}

# Isolated config home for every launch in this script.
$cfgHome = Join-Path $env:TEMP 'ghoztty-t69-xdg'
$cfgDir = Join-Path $cfgHome 'ghostty'
New-Item -ItemType Directory -Force $cfgDir | Out-Null
$cfgFile = Join-Path $cfgDir 'config'

$BAD_CONFIG = "not-a-real-key = 1`nbackground = notacolor`n"
$GOOD_CONFIG = "# valid on purpose`nwindow-height = 30`n"

function Launch-Gui([string[]]$ExtraArgs = @()) {
    $env:XDG_CONFIG_HOME = $cfgHome
    try {
        # --session-persistence=false: a restored layout manifest would hand a
        # later case the previous case's panes (the T131/T155 trap), and the
        # manifest write races the kill between cases. Case 4 overrides the
        # spelling on purpose; every spelling it passes is still false.
        $argv = @('--session-persistence=false') + $ExtraArgs
        $app = Start-OnTestDesktop -Exe $exe -Arguments $argv
    } finally { Remove-Item Env:XDG_CONFIG_HOME -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'window is NOT enumerable on the interactive desktop'
    return @{ App = $app; Pid = $app.Pid; Top = $top }
}

Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # ------------------------------------------------------------- case 1:
    # broken config at startup -> dialog with custom captions, Escape ignores.
    Set-Content -Path $cfgFile -Value $BAD_CONFIG -Encoding ascii
    $g = Launch-Gui
    $gpid = $g.Pid

    $dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 8000
    Assert ($dlg -ne [IntPtr]::Zero) 'broken config at startup shows the Configuration Errors dialog'
    if ($dlg -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no dialog to score'; exit 1 }

    $d = Get-DialogDark $dlg
    Assert ($d.Colors -ge 8) "config errors dialog capture has real content ($($d.Colors) distinct colors)"
    Assert ($d.Lum -ge 0 -and $d.Lum -lt 90) "config errors dialog renders dark (avg $($d.Lum) < 90)"

    $btns = Get-ButtonTexts $dlg
    Assert (($btns -contains 'Open Config') -and ($btns -contains 'Ignore')) "buttons are Open Config / Ignore (got: $($btns -join ', '))"

    # Escape = Ignore: dialog goes away, terminal window survives.
    Send-TestControlKey -Control $dlg -Key Escape | Out-Null
    $gone = Wait-Class $gpid 'GhozttyConfirmDialog' $false
    Assert ($gone -eq [IntPtr]::Zero) 'Escape (Ignore) dismisses the dialog'
    Start-Sleep -Milliseconds 300
    Assert ((-not ($g.App.Process -and $g.App.Process.HasExited)) -and (Test-TestWindowVisible -Window $g.Top)) 'app keeps running with remaining settings'
    Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    # ------------------------------------------------------------- case 2:
    # clean config at startup -> no dialog.
    Set-Content -Path $cfgFile -Value $GOOD_CONFIG -Encoding ascii
    $g = Launch-Gui
    $gpid = $g.Pid

    $dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 2000
    # -NegativeControl inverts the load-bearing "silence means clean" claim,
    # so a passing run proves the assertion discriminates rather than being
    # true of any outcome.
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: asserting a CLEAN config still shows the dialog - this run MUST fail'
        Assert ($dlg -ne [IntPtr]::Zero) 'clean config at startup shows a dialog (inverted)'
    } else {
        Assert ($dlg -eq [IntPtr]::Zero) 'clean config at startup shows no dialog'
    }

    # ------------------------------------------------------------- case 3:
    # reload_config picks up a newly-broken file (same instance as case 2).
    $surface = Get-TestChildWindow -Window $g.Top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: surface not found'; exit 1 }

    # Positive control: chord injection must demonstrably work before any
    # negative below can be trusted. ctrl+shift+r opens the rename dialog.
    $r = Send-TestKeys -Window $g.Top -Target $surface -Modifiers ctrl, shift -Key R
    if (-not $r) { Write-Host 'SETUP FAIL: control chord not injected'; exit 1 }
    $ren = Wait-Class $gpid 'GhozttyRenameDialog' $true
    if ($ren -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: positive control (rename dialog) did not open'; exit 1 }
    Send-TestControlKey -Control $ren -Key Escape | Out-Null
    $ren = Wait-Class $gpid 'GhozttyRenameDialog' $false
    if ($ren -ne [IntPtr]::Zero) { Write-Host 'SETUP FAIL: positive control dialog stuck open'; exit 1 }
    Write-Host 'OK    positive control: chords reach the app'

    Set-Content -Path $cfgFile -Value $BAD_CONFIG -Encoding ascii
    $r = Send-TestKeys -Window $g.Top -Target $surface -Modifiers ctrl, shift -Key comma
    if (-not $r) { Write-Host 'SETUP FAIL: reload chord not injected'; exit 1 }
    $dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 6000
    Assert ($dlg -ne [IntPtr]::Zero) 'reload_config on a broken file shows the dialog'
    if ($dlg -ne [IntPtr]::Zero) {
        Send-TestControlKey -Control $dlg -Key Escape | Out-Null
        $gone = Wait-Class $gpid 'GhozttyConfirmDialog' $false
        Assert ($gone -eq [IntPtr]::Zero) 'Escape dismisses the reload dialog'
    }

    # Fix the file; a second reload must stay silent.
    Set-Content -Path $cfgFile -Value $GOOD_CONFIG -Encoding ascii
    $r = Send-TestKeys -Window $g.Top -Target $surface -Modifiers ctrl, shift -Key comma
    if (-not $r) { Write-Host 'SETUP FAIL: second reload chord not injected'; exit 1 }
    $dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 2000
    Assert ($dlg -eq [IntPtr]::Zero) 'reload_config on a fixed file shows no dialog'
    Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) 'app alive at the end'
    Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    # ------------------------------------------------------------- case 4:
    # T137 - the documented switch spellings are ACCEPTED, and a value that is
    # genuinely not a boolean is REPORTED rather than swallowed.
    #
    # `session-persistence = off` is what docs/claude/sessions.md and the tracker tell a user
    # to write. It used to be error.InvalidValue, and because a bad value for a
    # known key is a diagnostic rather than a fatal error, the setting silently
    # stayed at its default `true` - the exact opposite of the request. Two
    # sessions were burned on that (T131, T234) and it was filed twice (T414).
    #
    # Oracle is the DIAGNOSTIC TEXT, never the exit code: `+validate-config`
    # exits 1 on this box even for a clean file (filed separately), so scoring
    # the code would pass on any outcome.
    $probeDir = Join-Path $env:TEMP 'ghoztty-t137-probe'
    New-Item -ItemType Directory -Force $probeDir | Out-Null
    function Get-ConfigDiagnostics([string]$body) {
        $p = Join-Path $probeDir 'probe.conf'
        Set-Content -Path $p -Value $body -Encoding ascii
        $out = & $exe +validate-config --config-file="$p" 2>&1 | ForEach-Object { $_.ToString() } | Out-String
        return $out.Trim()
    }

    foreach ($spelling in 'off', 'on', 'no', 'yes', 'false', 'true') {
        $diag = Get-ConfigDiagnostics "session-persistence = $spelling"
        Assert ($diag -eq '') "session-persistence = $spelling parses with no diagnostic (got: '$diag')"
    }
    # Negative control for the loop above: the assertion has to be able to fail,
    # or six silent passes prove nothing.
    $diag = Get-ConfigDiagnostics 'session-persistence = nope'
    Assert ($diag -match 'session-persistence' -and $diag -match 'invalid value') `
        "a non-boolean value is reported as a diagnostic (got: '$diag')"
    Remove-Item -Recurse -Force $probeDir -ErrorAction SilentlyContinue

    # And the same two states through the STARTUP path, which is where the
    # value actually reached the user: the documented spelling must be silent,
    # a bad one must raise the dialog.
    Set-Content -Path $cfgFile -Value $GOOD_CONFIG -Encoding ascii
    $g = Launch-Gui @('--session-persistence=off')
    $gpid = $g.Pid
    $dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 2500
    Assert ($dlg -eq [IntPtr]::Zero) '--session-persistence=off starts with no config-errors dialog'
    Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    $g = Launch-Gui @('--session-persistence=nope')
    $gpid = $g.Pid
    $dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 8000
    Assert ($dlg -ne [IntPtr]::Zero) '--session-persistence=nope raises the config-errors dialog'
    if ($dlg -ne [IntPtr]::Zero) {
        Send-TestControlKey -Control $dlg -Key Escape | Out-Null
        Wait-Class $gpid 'GhozttyConfirmDialog' $false | Out-Null
    }
    Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) 'app alive after case 4'
} finally {
    Remove-TestDesktop
    Kill-RepoInstances
    Remove-Item -Recurse -Force $cfgHome -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    # Get-TestLaunchedPids, not the live pid list: Remove-TestDesktop has run
    # by now and emptied the live one, which would score this against nothing.
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Write-Host ''
# The old copy of this script printed its failure count and exited 0, so a
# suite run scored a red script as green. It exits 1 now.
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red; exit 1 }
