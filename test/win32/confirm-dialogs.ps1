# T80 acceptance: the light MessageBoxW prompts are replaced by the dark
# ConfirmDialog (T50 pattern, class 'GhozttyConfirmDialog').
#
# Covered sites + semantics:
#   1. ctrl+w (close_surface with a BUSY shell - see Launch-Gui) -> surface
#        close confirm:
#        appears, renders DARK (avg lum < 90), Escape cancels (pane stays),
#        Enter on the DEFAULT button cancels (MB_DEFBUTTON2 parity - an
#        accidental Enter must never approve), Tab+Enter approves (window
#        closes).
#   2. title-bar X (WM_CLOSE to the window) -> aggregate window close
#        confirm: appears dark, Escape keeps the window open.
#   3. command palette "About Ghoztty" -> OK-only About box: appears dark,
#        Enter dismisses, app stays alive.
# The clipboard paste-protection confirm shares the exact same
# ConfirmDialog.show code path (not separately scripted - it needs a
# paste-protection trigger).
#
# A dialog that never appears after a verified chord is a SETUP FAIL
# (injection broken), not a product verdict.
#
# T217: runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1),
# so it never takes the user's foreground - asserted at the end, not assumed.
# The private win32 driver this script used to carry is gone. Two notes on the
# mechanics the harness enforces here:
#
#   * ConfirmDialog is NOT a standard dialog - it runs its own nested pump
#     (ConfirmDialog.runModal) that reads WM_KEYDOWN straight off the queue,
#     so a POSTED Escape/Enter/Tab reaches it (Send-TestControlKey). That is
#     the opposite of a real #32770, which only sees translated messages and
#     needs Send-TestWindowClose.
#   * The dark-render probes read the DIALOG's pixels, which are GDI chrome
#     and therefore capturable via PrintWindow. They are guarded by
#     Get-TestDistinctColors: a window captured mid-paint comes back solid
#     black, and black satisfies "is it dark?" without proving anything (T216).
#
# Only touches ghoztty processes running from this repo's zig-out.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
# Isolate the IPC endpoint (inherited through CreateProcessW) even though this
# script drives only the GUI: an instance answering the shared pipe would let
# another run's +new-window land in this window.
$env:GHOZTTY_PIPE_SUFFIX = '-confirmtest'

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
# real content. A mid-paint capture is solid black (1 distinct color) and
# would pass a "< 90" assertion while proving nothing - so the number is only
# believed once the chrome is actually there.
function Get-DialogDark([IntPtr]$dlg) {
    $lum = -1; $colors = 0
    for ($t = 0; $t -lt 15; $t++) {
        Start-Sleep -Milliseconds 200
        $shot = Get-TestWindowPixels -Window $dlg
        try {
            $c = Get-TestWindowRect -Window $dlg -Client
            $colors = Get-TestDistinctColors -Shot $shot
            $lum = Get-TestBrightness -Shot $shot -Rect @($c.Left, $c.Top, $c.Right, $c.Bottom)
        } finally { Close-TestWindowPixels $shot }
        if ($colors -ge 8) { break }
    }
    return [pscustomobject]@{ Lum = $lum; Colors = $colors }
}

function Assert-Dark([IntPtr]$dlg, [string]$label) {
    $d = Get-DialogDark $dlg
    Assert ($d.Colors -ge 8) "$label capture has real content ($($d.Colors) distinct colors)"
    Assert ($d.Lum -ge 0 -and $d.Lum -lt 90) "$label renders dark (avg $($d.Lum) < 90)"
}

# Wait for the confirm dialog to appear (or to go away).
function Wait-Dialog([int]$gpid, [bool]$appear, [int]$timeoutMs = 3000) {
    if ($appear) { return Wait-TestWindow -ProcessId $gpid -Class 'GhozttyConfirmDialog' -TimeoutMs $timeoutMs }
    $waited = 0
    while ($waited -lt $timeoutMs) {
        $d = Get-TestWindow -ProcessId $gpid -Class 'GhozttyConfirmDialog'
        if ($d -eq [IntPtr]::Zero) { return $d }
        Start-Sleep -Milliseconds 100
        $waited += 100
    }
    return (Get-TestWindow -ProcessId $gpid -Class 'GhozttyConfirmDialog')
}

function Launch-Gui {
    # --session-persistence=false: a restored layout manifest would hand a
    # later section the previous section's panes (the T131/T155 trap).
    $app = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: surface not found'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'window is NOT enumerable on the interactive desktop'
    # T41: an IDLE shell no longer confirms - the close paths ask the process
    # table now, because no Windows shell emits the OSC 133 marks the core's
    # `cursorIsAtPrompt` reads. Every case below is about the DIALOG, so give
    # the shell a live child; otherwise these dialogs correctly never appear.
    # (T41's own behavior - idle vs busy - is close-confirm-idle.ps1.)
    Send-TestText -Window $top -Target $surface -Text 'ping -n 600 127.0.0.1' | Out-Null
    Send-TestKeys -Window $top -Target $surface -Key Enter | Out-Null
    $busy = $false
    for ($t = 0; $t -lt 30 -and -not $busy; $t++) {
        Start-Sleep -Milliseconds 400
        $busy = [bool](Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" |
            Where-Object { $_.ParentProcessId -and (Test-Ancestor $_.ProcessId $app.Pid) })
    }
    if (-not $busy) { Write-Host 'SETUP FAIL: could not make the pane busy (no ping under the app)'; exit 1 }
    return @{ App = $app; Pid = $app.Pid; Top = $top; Surface = $surface }
}

# Is $Root anywhere in $Pid's parent chain? Used only to confirm the setup
# ping really belongs to this run's app.
function Test-Ancestor([int]$ProcessIdToCheck, [int]$Root) {
    $map = @{}
    Get-CimInstance Win32_Process | ForEach-Object { $map[[int]$_.ProcessId] = [int]$_.ParentProcessId }
    $cur = $ProcessIdToCheck
    for ($d = 0; $d -lt 32; $d++) {
        if ($cur -eq $Root) { return $true }
        if (-not $map.ContainsKey($cur)) { return $false }
        $next = $map[$cur]
        if ($next -eq 0 -or $next -eq $cur) { return $false }
        $cur = $next
    }
    return $false
}

Kill-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # ------------------------------------------------------------ case 1:
    # surface close confirm (ctrl+w with live cmd.exe).
    $g = Launch-Gui
    $gpid = $g.Pid

    $r = Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl -Key W
    if (-not $r) { Write-Host 'SETUP FAIL: ctrl+w not injected'; exit 1 }
    $dlg = Wait-Dialog $gpid $true
    Assert ($dlg -ne [IntPtr]::Zero) 'ctrl+w opens the surface close confirm dialog'
    if ($dlg -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no dialog to score'; exit 1 }

    Assert-Dark $dlg 'close confirm'

    Send-TestControlKey -Control $dlg -Key Escape | Out-Null
    $gone = Wait-Dialog $gpid $false
    Assert ($gone -eq [IntPtr]::Zero) 'Escape dismisses the dialog'
    Assert ((-not ($g.App.Process -and $g.App.Process.HasExited)) -and (Test-TestWindowVisible -Window $g.Top)) 'Escape cancels: window stays open'

    # Enter on the default button must CANCEL (MB_DEFBUTTON2 parity).
    Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl -Key W | Out-Null
    $dlg = Wait-Dialog $gpid $true
    Assert ($dlg -ne [IntPtr]::Zero) 'second ctrl+w reopens the dialog'
    if ($dlg -ne [IntPtr]::Zero) {
        Send-TestControlKey -Control $dlg -Key Enter | Out-Null
        $gone = Wait-Dialog $gpid $false
        Assert ($gone -eq [IntPtr]::Zero) 'Enter (default) dismisses the dialog'
        $alive = (-not ($g.App.Process -and $g.App.Process.HasExited)) -and (Test-TestWindowVisible -Window $g.Top)
        # -NegativeControl inverts the assertion that carries the whole point
        # of the case, so a passing run proves it discriminates rather than
        # being true of any outcome.
        if ($NegativeControl) {
            Write-Host 'NEGATIVE CONTROL: asserting Enter APPROVED the close - this run MUST fail'
            Assert (-not $alive) 'Enter on the default button closed the window (inverted)'
        } else {
            Assert $alive 'Enter defaults to Cancel: window stays open'
        }
    }

    # Tab moves focus to OK; Enter then approves -> last pane closes the window.
    Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl -Key W | Out-Null
    $dlg = Wait-Dialog $gpid $true
    Assert ($dlg -ne [IntPtr]::Zero) 'third ctrl+w reopens the dialog'
    if ($dlg -ne [IntPtr]::Zero) {
        Send-TestControlKey -Control $dlg -Key Tab | Out-Null
        Start-Sleep -Milliseconds 150
        Send-TestControlKey -Control $dlg -Key Enter | Out-Null
        $closed = $false
        for ($t = 0; $t -lt 50 -and -not $closed; $t++) {
            Start-Sleep -Milliseconds 100
            $closed = (-not (Test-TestWindowExists -Window $g.Top)) -or (-not (Test-TestWindowVisible -Window $g.Top))
        }
        Assert $closed 'Tab+Enter approves: window closes'
    }
    Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    # ------------------------------------------------------------ case 2:
    # window-level aggregate close confirm (title-bar X -> WM_CLOSE).
    $g = Launch-Gui
    $gpid = $g.Pid
    Send-TestWindowClose -Window $g.Top | Out-Null
    $dlg = Wait-Dialog $gpid $true
    Assert ($dlg -ne [IntPtr]::Zero) 'WM_CLOSE (title-bar X) opens the window close confirm'
    if ($dlg -ne [IntPtr]::Zero) {
        Assert-Dark $dlg 'window close confirm'
        Send-TestControlKey -Control $dlg -Key Escape | Out-Null
        $gone = Wait-Dialog $gpid $false
        Assert ($gone -eq [IntPtr]::Zero) 'Escape dismisses the window close confirm'
        Assert ((-not ($g.App.Process -and $g.App.Process.HasExited)) -and (Test-TestWindowVisible -Window $g.Top)) 'window survives the cancelled X-close'
    }

    # ------------------------------------------------------------ case 3:
    # About box via the command palette (OK-only + info icon), same GUI.
    $r = Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl, shift -Key P
    if (-not $r) { Write-Host 'SETUP FAIL: ctrl+shift+p not injected'; exit 1 }
    # The palette is a top-level GhozttyTerminal popup, so exclude the window's
    # own class match by naming the main window.
    $popup = [IntPtr]::Zero
    for ($t = 0; $t -lt 30 -and $popup -eq [IntPtr]::Zero; $t++) {
        Start-Sleep -Milliseconds 100
        $popup = Get-TestWindow -ProcessId $gpid -Class 'GhozttyTerminal' -Exclude $g.Top
    }
    Assert ($popup -ne [IntPtr]::Zero) 'command palette opens via ctrl+shift+p'
    if ($popup -ne [IntPtr]::Zero) {
        $edit = Find-TestWindowEx -Parent $popup -Class 'EDIT'
        Assert ($edit -ne [IntPtr]::Zero) 'palette search edit found'
        if ($edit -ne [IntPtr]::Zero) {
            # The search box is a standard EDIT: text goes in as WM_CHAR and
            # Enter as a posted navigation key.
            Send-TestControlText -Control $edit -Text 'about' | Out-Null
            $sent = Send-TestControlKey -Control $edit -Key Enter
            Assert $sent 'palette filter "about" + Enter delivered'
            $dlg = Wait-Dialog $gpid $true 5000
            Assert ($dlg -ne [IntPtr]::Zero) 'About Ghoztty dialog opens from the palette'
            if ($dlg -ne [IntPtr]::Zero) {
                Assert-Dark $dlg 'About box'
                Send-TestControlKey -Control $dlg -Key Enter | Out-Null   # OK-only: Enter dismisses
                $gone = Wait-Dialog $gpid $false
                Assert ($gone -eq [IntPtr]::Zero) 'Enter dismisses the About box'
                Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) 'no crash after About round-trip'
            }
        }
    }
} finally {
    Remove-TestDesktop
    Kill-RepoInstances
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
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red; exit 1 }
