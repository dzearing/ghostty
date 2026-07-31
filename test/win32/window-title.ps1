# T92 acceptance: three-level title model (window pin -> tab title -> pane
# title), Mac parity.
#
#   S1  OSC baseline: a shell `title X` drives pane + tab + titlebar.
#   S2  Window pin via IPC: +rename pins the titlebar over shell titles;
#       +rename --title="" CLEARS the pin (Mac 9c7665354 parity).
#   S3  ctrl+shift+r (prompt_window_title) opens the "Change Window Title"
#       dialog; commit pins, reopen prefills, empty commit clears.
#   S4  Palette "Change Pane Title": sets a pane title that survives shell
#       OSC updates; empty commit restores the remembered terminal title.
#   S5  Palette "Change Tab Title": pins the tab label against pane-driven
#       updates; empty commit re-derives from the focused pane.
#   S6  Precedence stack: window pin > tab pin > pane title, peeled one
#       level at a time.
#
# Titles are asserted via `+list --json` (window.title = real titlebar
# text incl. the Debug marker; tabs[].title; leaf terminal.title = pane).
#
# T217: runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1),
# so it never takes the user's foreground - asserted at the end, not assumed.
# The private win32 driver this script used to carry is gone; the harness
# supplies the equivalents. Two conventions it enforces, both load-bearing
# here:
#
#   * Dialog/palette OPENING is a chord on the TERMINAL surface
#     (Send-TestKeys), but everything typed into the dialog or the palette
#     goes to a STANDARD EDIT, which needs WM_CHAR / plain posted navigation
#     keys (Send-TestControlText / Send-TestControlKey).
#   * The prefilled-dialog assertions read the EDIT with WM_GETTEXT
#     (Get-TestControlText), never GetWindowTextW - across a process
#     boundary that returns a cache the app never refreshes.
#
# Only touches ghoztty processes running from this repo's zig-out.
#
#   powershell -NoProfile -File test\win32\window-title.ps1
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$errlog = Join-Path $env:TEMP 'ghoztty-window-title-stderr.log'
Remove-Item $errlog -ErrorAction SilentlyContinue
# Isolate the IPC endpoint (inherited through CreateProcessW), so every
# +list / +rename below is answered by THIS instance and never the user's.
$env:GHOZTTY_PIPE_SUFFIX = '-windowtitletest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# --- helpers -----------------------------------------------------------------
function Get-State {
    $j = & $exe +list --json | ConvertFrom-Json
    $w = $j.data.windows[0]
    @{ Win = [string]$w.title; Tab = [string]$w.tabs[0].title; Pane = [string]$w.tabs[0].splits.terminal.title }
}
function Wait-Cond([scriptblock]$cond, [int]$ms = 8000) {
    $dl = [DateTime]::Now.AddMilliseconds($ms)
    do {
        if (& $cond) { return $true }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::Now -lt $dl)
    return $false
}
# Titlebar text = base title + optional " [DEBUG]" marker.
function TitlebarIs([string]$base) {
    (Get-State).Win -match ('^' + [regex]::Escape($base) + '( \[DEBUG\])?$')
}
function Send-Title([string]$t) {
    & $exe +send-keys --target=$script:win "title $t" Enter | Out-Null
}
function Find-Dialog {
    Get-TestWindow -ProcessId $script:app.Pid -Class 'GhozttyRenameDialog'
}
# Open the title dialog via the command palette: ctrl+shift+p, type the
# filter, Enter. Returns the dialog HWND or IntPtr.Zero.
function Open-DialogViaPalette([string]$filter) {
    $popup = [IntPtr]::Zero
    foreach ($try in 1..3) {
        if (-not (Send-TestKeys -Window $top -Target $surface -Modifiers ctrl, shift -Key P)) { continue }
        $popup = Wait-TestWindow -ProcessId $script:app.Pid -Class 'GhozttyTerminal' -TimeoutMs 5000
        if ($popup -ne [IntPtr]::Zero) { break }
    }
    if ($popup -eq [IntPtr]::Zero) { Write-Host '  (palette popup not found)'; return [IntPtr]::Zero }
    $palEdit = Find-TestWindowEx -Parent $popup -Class 'EDIT'
    if ($palEdit -eq [IntPtr]::Zero) { Write-Host '  (palette edit not found)'; return [IntPtr]::Zero }
    Send-TestControlText -Control $palEdit -Text $filter | Out-Null
    Send-TestControlKey -Control $palEdit -Key Enter | Out-Null
    $dlg = [IntPtr]::Zero
    for ($t = 0; $t -lt 100 -and $dlg -eq [IntPtr]::Zero; $t++) { Start-Sleep -Milliseconds 50; $dlg = Find-Dialog }
    return $dlg
}
# Commit $text through an open title dialog (empty string clears). WM_SETTEXT
# rather than typing: the dialog arrives PREFILLED, and clearing it first
# would need a select-all chord, which does not reach a standard control.
function Commit-Dialog([IntPtr]$dlg, [string]$text) {
    $edit = Find-TestWindowEx -Parent $dlg -Class 'EDIT'
    if ($edit -eq [IntPtr]::Zero) { return $false }
    Set-TestControlText -Control $edit -Text $text | Out-Null
    Send-TestControlKey -Control $edit -Key Enter | Out-Null
    Wait-Cond { (Find-Dialog) -eq [IntPtr]::Zero } 3000
}

function Kill-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

# --- Setup: fresh debug instance, one window/one pane ------------------------
Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # --session-persistence=false: a restored manifest would hand this run a
    # previous run's panes and titles (the T131/T155 trap).
    $script:app = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false') -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: terminal surface not found'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'window is NOT enumerable on the interactive desktop'

    $listJson = & $exe +list --json | ConvertFrom-Json
    $script:win = $listJson.data.windows[0].target
    if (-not $script:win) { $script:win = $listJson.data.windows[0].tabs[0].splits.terminal.name }

    # --- S1: OSC baseline (positive control for the title plumbing) ----------
    Write-Host '== S1: shell OSC title drives pane + tab + titlebar'
    Send-Title 'T92OSCA'
    Assert (Wait-Cond { (Get-State).Pane -eq 'T92OSCA' }) 'S1 pane title tracks shell OSC'
    $s = Get-State
    Assert ($s.Tab -eq 'T92OSCA') 'S1 tab title follows the focused pane'
    Assert (TitlebarIs 'T92OSCA') 'S1 titlebar falls back to the tab title'

    # --- S2: window pin via +rename ------------------------------------------
    Write-Host '== S2: +rename pins the titlebar; --title="" clears'
    & $exe +rename --target=$script:win --title=T92WINPIN | Out-Null
    Assert (Wait-Cond { TitlebarIs 'T92WINPIN' }) 'S2 +rename pins the titlebar'
    Send-Title 'T92OSCB'
    Assert (Wait-Cond { (Get-State).Pane -eq 'T92OSCB' }) 'S2 pane title still tracks shell under the pin'
    $s = Get-State
    Assert ($s.Tab -eq 'T92OSCB') 'S2 tab title still tracks shell under the pin'
    Assert (TitlebarIs 'T92WINPIN') 'S2 window pin beats the shell title'
    & $exe +rename --target=$script:win --title= | Out-Null
    Assert (Wait-Cond { TitlebarIs 'T92OSCB' }) 'S2 +rename --title="" clears the pin (falls back to tab)'

    # --- S3: ctrl+shift+r -> Change Window Title dialog ----------------------
    # No SKIP branch any more: on the test desktop the chord always lands, so
    # a chord that does not open the dialog is a real failure (batch-1 lesson
    # - a SKIP branch hides un-run assertions).
    Write-Host '== S3: prompt_window_title dialog (ctrl+shift+r)'
    Assert (Send-TestKeys -Window $top -Target $surface -Modifiers ctrl, shift -Key R) 'S3 ctrl+shift+r delivered'
    $dlg = [IntPtr]::Zero
    for ($t = 0; $t -lt 100 -and $dlg -eq [IntPtr]::Zero; $t++) { Start-Sleep -Milliseconds 50; $dlg = Find-Dialog }
    Assert ($dlg -ne [IntPtr]::Zero) 'S3 dialog opens on ctrl+shift+r'
    if ($dlg -ne [IntPtr]::Zero) {
        Assert ((Get-TestWindowText -Window $dlg) -eq 'Change Window Title') 'S3 dialog caption is "Change Window Title"'
        Assert (Commit-Dialog $dlg 'T92DLG') 'S3 dialog closes on Enter'
        Assert (Wait-Cond { TitlebarIs 'T92DLG' }) 'S3 dialog commit pins the titlebar'
        # Reopen: prefilled with the pin; empty commit clears it.
        Send-TestKeys -Window $top -Target $surface -Modifiers ctrl, shift -Key R | Out-Null
        $dlg = [IntPtr]::Zero
        for ($t = 0; $t -lt 100 -and $dlg -eq [IntPtr]::Zero; $t++) { Start-Sleep -Milliseconds 50; $dlg = Find-Dialog }
        Assert ($dlg -ne [IntPtr]::Zero) 'S3 dialog reopens'
        if ($dlg -ne [IntPtr]::Zero) {
            $edit = Find-TestWindowEx -Parent $dlg -Class 'EDIT'
            Assert ((Get-TestControlText -Control $edit) -eq 'T92DLG') 'S3 reopen prefilled with the current pin'
            Assert (Commit-Dialog $dlg '') 'S3 empty commit closes the dialog'
            Assert (Wait-Cond { TitlebarIs 'T92OSCB' }) 'S3 empty commit clears the pin'
        }
    }

    # --- S4: palette Change Pane Title ---------------------------------------
    Write-Host '== S4: pane title prompt (palette)'
    $dlg = Open-DialogViaPalette 'pane ti'
    Assert ($dlg -ne [IntPtr]::Zero) 'S4 palette opens the pane-title dialog'
    if ($dlg -ne [IntPtr]::Zero) {
        Assert ((Get-TestWindowText -Window $dlg) -eq 'Change Pane Title') 'S4 dialog caption is "Change Pane Title"'
        Assert (Commit-Dialog $dlg 'T92PANE') 'S4 dialog commit'
        Assert (Wait-Cond { (Get-State).Pane -eq 'T92PANE' }) 'S4 pane title set'
        $s = Get-State
        Assert ($s.Tab -eq 'T92PANE') 'S4 tab follows the pane title'
        Assert (TitlebarIs 'T92PANE') 'S4 titlebar follows too'
        # A shell title must NOT displace the user's pane title.
        Send-Title 'T92OSCC'
        Start-Sleep -Seconds 3
        $s = Get-State
        # -NegativeControl inverts this one: it asserts the shell title DID
        # win, so a passing run proves the assertion discriminates rather than
        # being true of any title at all.
        if ($NegativeControl) {
            Write-Host 'NEGATIVE CONTROL: asserting the shell OSC overwrote the user pane title - this run MUST fail'
            Assert ($s.Pane -eq 'T92OSCC') "S4 (inverted): shell OSC displaced the user pane title (got $($s.Pane))"
        } else {
            Assert ($s.Pane -eq 'T92PANE') 'S4 user pane title survives shell OSC'
        }
        Assert ($s.Tab -eq 'T92PANE') 'S4 tab keeps the user pane title too'
        # Empty commit restores the REMEMBERED terminal title (OSCC, which
        # arrived while the user title was held).
        $dlg = Open-DialogViaPalette 'pane ti'
        Assert ($dlg -ne [IntPtr]::Zero) 'S4 pane-title dialog reopens'
        if ($dlg -ne [IntPtr]::Zero) {
            Assert (Commit-Dialog $dlg '') 'S4 empty commit'
            Assert (Wait-Cond { (Get-State).Pane -eq 'T92OSCC' }) 'S4 clear restores the remembered terminal title'
        }
    }

    # --- S5: palette Change Tab Title ----------------------------------------
    Write-Host '== S5: tab title pin (palette)'
    $dlg = Open-DialogViaPalette 'tab ti'
    Assert ($dlg -ne [IntPtr]::Zero) 'S5 palette opens the tab-title dialog'
    if ($dlg -ne [IntPtr]::Zero) {
        Assert ((Get-TestWindowText -Window $dlg) -eq 'Change Tab Title') 'S5 dialog caption is "Change Tab Title"'
        Assert (Commit-Dialog $dlg 'T92TAB') 'S5 dialog commit'
        Assert (Wait-Cond { (Get-State).Tab -eq 'T92TAB' }) 'S5 tab title pinned'
        $s = Get-State
        Assert ($s.Pane -eq 'T92OSCC') 'S5 pane title untouched by the tab pin'
        Assert (TitlebarIs 'T92TAB') 'S5 titlebar shows the tab pin'
        # Pane-driven updates leave a pinned tab alone.
        Send-Title 'T92OSCD'
        Assert (Wait-Cond { (Get-State).Pane -eq 'T92OSCD' }) 'S5 pane title still tracks shell'
        $s = Get-State
        Assert ($s.Tab -eq 'T92TAB') 'S5 tab pin survives shell OSC'
        Assert (TitlebarIs 'T92TAB') 'S5 titlebar keeps the tab pin'
        # Empty commit re-derives the tab title from the focused pane.
        $dlg = Open-DialogViaPalette 'tab ti'
        Assert ($dlg -ne [IntPtr]::Zero) 'S5 tab-title dialog reopens'
        if ($dlg -ne [IntPtr]::Zero) {
            Assert (Commit-Dialog $dlg '') 'S5 empty commit'
            Assert (Wait-Cond { (Get-State).Tab -eq 'T92OSCD' }) 'S5 clear re-derives from the focused pane'
        }
    }

    # --- S6: precedence stack window > tab > pane ----------------------------
    Write-Host '== S6: precedence stack'
    $dlg = Open-DialogViaPalette 'pane ti'
    if ($dlg -ne [IntPtr]::Zero) { Commit-Dialog $dlg 'T92PPP' | Out-Null }
    $dlg = Open-DialogViaPalette 'tab ti'
    if ($dlg -ne [IntPtr]::Zero) { Commit-Dialog $dlg 'T92TTT' | Out-Null }
    & $exe +rename --target=$script:win --title=T92WWW | Out-Null
    Assert (Wait-Cond { TitlebarIs 'T92WWW' }) 'S6 all three set: titlebar = window pin'
    $s = Get-State
    Assert ($s.Tab -eq 'T92TTT') 'S6 tab = tab pin'
    Assert ($s.Pane -eq 'T92PPP') 'S6 pane = pane title'
    & $exe +rename --target=$script:win --title= | Out-Null
    Assert (Wait-Cond { TitlebarIs 'T92TTT' }) 'S6 window pin cleared -> titlebar = tab pin'
    $dlg = Open-DialogViaPalette 'tab ti'
    if ($dlg -ne [IntPtr]::Zero) { Commit-Dialog $dlg '' | Out-Null }
    Assert (Wait-Cond { TitlebarIs 'T92PPP' }) 'S6 tab pin cleared -> titlebar = pane title'
    $s = Get-State
    Assert ($s.Tab -eq 'T92PPP') 'S6 tab re-derived from the pane'
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'S6 no crash through the whole sequence'

    & $exe +close --target=$script:win | Out-Null
    Start-Sleep -Seconds 1
} finally {
    Remove-TestDesktop
    Kill-RepoInstances
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @($script:GhozttyTestDesktopPids | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)"; exit 0 }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)"; exit 1 }
