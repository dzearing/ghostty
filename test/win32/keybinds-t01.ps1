# T01 acceptance: verify the Windows ctrl-mirror keybinds end-to-end by
# driving REAL key chords into the debug build and asserting GUI state via
# +list/+read/clipboard.
#
# Coverage (the T01 checklist from windows-parity-details.md):
#   ctrl+t        new tab            (tab count via +list)
#   ctrl+1/2/9    goto_tab/last_tab  (tabs[].selected via +list)
#   ctrl+f4       close tab          (T02 binding, used to restore layout)
#   ctrl+d        split right        (leaf count via +list)
#   ctrl+shift+d  split down         (leaf count via +list)
#   ctrl+w        close pane         (leaf count; handles the confirm dialog)
#   ctrl+shift+p  command palette    (popup appears; Escape closes)
#   ctrl+c        SIGINT w/o selection (ping -t interrupted, shell prompt back)
#   ctrl+c        copy WITH selection  (double-click word select -> clipboard)
#   ctrl+v        paste              (clipboard token lands in the pane)
#   ctrl+n        new window         (window count via +list; closed via +close)
#
# T218: runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1), so
# it never takes the user's foreground - asserted at the end, not assumed. The
# private T01Drv driver (T86 GrabForeground + SendInput, keyboard AND mouse) is
# gone.
#
# This script moved from T217 to T218 because of ONE section: "ctrl+c WITH
# selection" word-selects by driving a real mouse double-click, so it needed
# the posted-mouse mechanism T216 proved before it could migrate. That is now
# Send-TestMouse -Action doubleclick, posted to the pane child (posted messages
# skip hit testing, so the window that would really have received the click has
# to be named). Everything else here is the plain T217 keyboard recipe.
#
# Chords go to the FOCUSED SURFACE, re-resolved before each one: GhozttyWindow
# hands WM_KEYDOWN to DefWindowProc and only forwards FOCUS to the active pane,
# and tab/split churn replaces the surface HWND under us. Get-TestFocusedWindow
# is what the old driver's "pass IntPtr.Zero to keep the last focus" meant.
#
# -NegativeControl inverts the ctrl+c-copy assertion (the mouse-driven one, the
# only new mechanism here) and MUST fail; it is how a run proves the
# double-click -> word-select -> clipboard probe still discriminates.
#
# Only touches ghoztty processes running from this repo's zig-out.
#
#   powershell -NoProfile -File test\win32\keybinds-t01.ps1
param(
    [string]$Exe,
    [switch]$NegativeControl,
    [switch]$Interactive
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $Exe) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
if (-not (Test-Path $Exe)) { $Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
$errlog = Join-Path $env:TEMP 'ghoztty-keybinds-t01-stderr.log'
Remove-Item $errlog -ErrorAction SilentlyContinue

# Isolate the IPC endpoint unconditionally - inherited by the app through
# CreateProcessW and by every `& $Exe +...` below.
$env:GHOZTTY_PIPE_SUFFIX = "-t01test$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# --- input helpers ------------------------------------------------------------
# The surface the app itself considers active RIGHT NOW. Every tab open, split
# and pane close makes a new GhozttyTerminal child, so this is re-read per
# chord rather than captured once.
function Get-ActiveSurface {
    $h = [IntPtr](Get-TestFocusedWindow -Window $script:top)
    if ($h -eq [IntPtr]::Zero -or (Get-TestWindowClass -Window $h) -ne 'GhozttyTerminal') {
        $h = Get-TestChildWindow -Window $script:top -Class 'GhozttyTerminal'
    }
    return $h
}

function Send-Chord([string]$Key, [string[]]$Mods = @()) {
    return (Send-TestKeys -Window $script:top -Target (Get-ActiveSurface) -Key $Key -Modifiers $Mods)
}

# --- JSON helpers -------------------------------------------------------------
function Get-ListJson { & $Exe +list --json | ConvertFrom-Json }
# Split-tree node shape (list.zig writeNode): leaf nodes are
# {"type":"leaf","terminal":{...}}, split nodes are FLAT:
# {"type":"split","direction":...,"ratio":...,"left":{...},"right":{...}}.
function Count-Leaves($node) {
    if ($node.type -eq 'leaf') { return 1 }
    return (Count-Leaves $node.left) + (Count-Leaves $node.right)
}
function Get-FocusedLeaf($node) {
    if ($node.type -eq 'leaf') {
        if ($node.terminal.focused) { return $node.terminal }
        return $null
    }
    $l = Get-FocusedLeaf $node.left
    if ($null -ne $l) { return $l }
    return (Get-FocusedLeaf $node.right)
}
function Get-AnyLeaf($node) {
    if ($node.type -eq 'leaf') { return $node.terminal }
    return (Get-AnyLeaf $node.left)
}
function Get-PaneName($node) {
    $leaf = Get-FocusedLeaf $node
    if ($null -eq $leaf) { $leaf = Get-AnyLeaf $node }
    return $leaf.name
}
function Get-SelectedTab($win) {
    $sel = $win.tabs | Where-Object { $_.selected } | Select-Object -First 1
    if ($null -eq $sel) { return @($win.tabs)[0] } # fallback; asserted separately
    return $sel
}
# Poll until the selected tab index matches (chord dispatch + list refresh
# are asynchronous); returns the last observed index.
function Wait-SelectedIndex([int]$expect) {
    $sel = $null
    for ($t = 0; $t -lt 20; $t++) {
        Start-Sleep -Milliseconds 150
        $lj = Get-ListJson
        $sel = $lj.data.windows[0].tabs | Where-Object { $_.selected } | Select-Object -First 1
        if ($null -ne $sel -and $sel.index -eq $expect) { return $expect }
    }
    if ($null -eq $sel) { return -1 }
    return $sel.index
}

# If a close-confirm dialog is up (cmd.exe lacks OSC 133 so process_active
# is always true), approve it by clicking OK. Send-TestControlClick posts
# BM_CLICK - a posted Enter would never reach a dialog, which routes keys
# through the dialog manager over TRANSLATED messages only.
function Approve-ConfirmDialog {
    for ($t = 0; $t -lt 15; $t++) {
        Start-Sleep -Milliseconds 100
        $dlg = Get-TestWindow -ProcessId $script:appPid -Class 'GhozttyConfirmDialog'
        if ($dlg -ne [IntPtr]::Zero) {
            $ok = Find-TestWindowEx -Parent $dlg -Class 'BUTTON' -Title 'OK'
            if ($ok -ne [IntPtr]::Zero) {
                [void](Send-TestControlClick -Control $ok)
                Start-Sleep -Milliseconds 400
                return $true
            }
        }
    }
    return $false
}

# --- Setup: fresh debug instance on the test desktop -------------------------
[void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 800)
# Watch the user's desktop for the whole run: nothing we launch may ever take
# foreground there. That is the complaint the test desktop exists to fix.
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$app = $null

try {

# --session-persistence=false: each launch would otherwise re-attach to the
# surviving agent and restore a layout manifest, whose tab/split shape is
# exactly what this script asserts on (batch-2 lesson).
$app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -StdErr $errlog
$script:appPid = $app.Pid
Start-Sleep -Seconds 3
if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
$script:top = Wait-TestWindow -ProcessId $script:appPid -Class 'GhozttyWindow'
if ($script:top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: window not found'; exit 1 }
Assert (-not (Test-TestDesktopLeak -ProcessId $script:appPid)) 'window is NOT enumerable on the interactive desktop'

Focus-TestWindow -Window $script:top | Out-Null
Start-Sleep -Milliseconds 500
Assert ((Get-TestWindowClass -Window (Get-ActiveSurface)) -eq 'GhozttyTerminal') 'window forwarded focus to a terminal surface'

$lj = Get-ListJson
$win0 = $lj.data.windows[0]
$pane = (Get-PaneName $win0.tabs[0].splits)
Assert (-not [string]::IsNullOrEmpty($pane)) 'pane name resolved from +list'

# --- Positive control: plain typed text must echo on the input line ----------
if (-not (Send-TestText -Window $script:top -Target (Get-ActiveSurface) -Text 'kbtctrl')) {
    Write-Host 'SKIP ALL: positive control not injectable'; exit 1
}
Start-Sleep -Milliseconds 700
$tail = & $Exe +read --name=$pane --lines=5 | Out-String
Assert ($tail -match 'kbtctrl') 'positive control: typed text visible in pane'
Send-Chord Escape | Out-Null   # clear the input line
Start-Sleep -Milliseconds 300

# --- ctrl+t: new tab ----------------------------------------------------------
Assert (Send-Chord T ctrl) 'ctrl+t chord posted'
Start-Sleep -Milliseconds 1500
$lj = Get-ListJson
$tabs = @($lj.data.windows[0].tabs)
Assert ($tabs.Count -eq 2) "ctrl+t opens a second tab (got $($tabs.Count))"
Assert ((Get-SelectedTab $lj.data.windows[0]).index -eq 1) 'ctrl+t selects the new tab'

# --- ctrl+1 / ctrl+2 / ctrl+9: tab selection ---------------------------------
Send-Chord 1 ctrl | Out-Null
$got = Wait-SelectedIndex 0
Assert ($got -eq 0) "ctrl+1 selects tab 1 (got index $got)"
Send-Chord 2 ctrl | Out-Null
$got = Wait-SelectedIndex 1
Assert ($got -eq 1) "ctrl+2 selects tab 2 (got index $got)"
Send-Chord 1 ctrl | Out-Null
Wait-SelectedIndex 0 | Out-Null
Send-Chord 9 ctrl | Out-Null
$got = Wait-SelectedIndex 1
Assert ($got -eq 1) "ctrl+9 selects the last tab (got index $got)"

# --- ctrl+f4: close tab (T02 binding; restores single-tab layout) ------------
Send-Chord f4 ctrl | Out-Null
Approve-ConfirmDialog | Out-Null
Start-Sleep -Milliseconds 800
$lj = Get-ListJson
$tabs = @($lj.data.windows[0].tabs)
Assert ($tabs.Count -eq 1) "ctrl+f4 closes the tab (got $($tabs.Count))"
# +list must still mark the survivor tab selected (regression oracle:
# run 1 of this script found selected=false on every tab here).
Assert (@($tabs | Where-Object { $_.selected }).Count -eq 1) 'surviving tab reports selected=true after tab close'

# --- ctrl+d: split right ------------------------------------------------------
Send-Chord D ctrl | Out-Null
Start-Sleep -Milliseconds 1500
$lj = Get-ListJson
$tab = Get-SelectedTab $lj.data.windows[0]
Assert ((Count-Leaves $tab.splits) -eq 2) 'ctrl+d creates a right split (2 leaves)'

# --- ctrl+shift+d: split down -------------------------------------------------
Send-Chord D ctrl,shift | Out-Null
Start-Sleep -Milliseconds 1500
$lj = Get-ListJson
$tab = Get-SelectedTab $lj.data.windows[0]
Assert ((Count-Leaves $tab.splits) -eq 3) 'ctrl+shift+d creates a down split (3 leaves)'

# --- ctrl+w: close pane (twice, back to a single leaf) ------------------------
foreach ($expect in 2, 1) {
    Send-Chord W ctrl | Out-Null
    Approve-ConfirmDialog | Out-Null
    Start-Sleep -Milliseconds 800
    $lj = Get-ListJson
    $tab = Get-SelectedTab $lj.data.windows[0]
    Assert ((Count-Leaves $tab.splits) -eq $expect) "ctrl+w closes a pane (down to $expect)"
}
Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash after tab/split churn'

# --- ctrl+shift+p: command palette opens; Escape closes ----------------------
# The palette is a visible top-level WS_POPUP of the TERMINAL class owned by
# the same pid (T57) - found by excluding the main window.
Send-Chord P ctrl,shift | Out-Null
$popup = [IntPtr]::Zero
for ($t = 0; $t -lt 20; $t++) {
    Start-Sleep -Milliseconds 100
    $popup = Get-TestWindow -ProcessId $script:appPid -Class 'GhozttyTerminal' -Exclude $script:top
    if ($popup -ne [IntPtr]::Zero) { break }
}
Assert ($popup -ne [IntPtr]::Zero) 'ctrl+shift+p opens the command palette popup'
if ($popup -ne [IntPtr]::Zero) {
    # Posted straight at the palette's own EDIT, and at the edit rather than
    # at the popup frame for a reason: the app routes palette keys in its
    # message loop on `msg.hwnd == surface.palette_edit` (App.zig:1051), which
    # is where a real user's Escape arrives too - setCommandPaletteActive
    # SetFocus()es the edit as it shows the popup, so the frame never holds
    # focus and never sees a key. Escape posted at the frame was silently
    # dropped, which is what made this assertion the run's only red (T157).
    # Send-TestKeys is still wrong here: it would SetFocus the pane first and
    # dismiss the palette out from under the key.
    # Find-TestWindowEx, not Get-TestChildWindow: the latter compares class
    # names with a case-SENSITIVE ==, and the control's registered class is
    # "Edit", so 'EDIT' silently found nothing. FindWindowExW is
    # case-insensitive, which is why the confirm-dialog 'BUTTON' lookup above
    # has never had this problem.
    $palEdit = Find-TestWindowEx -Parent $popup -Class 'EDIT'
    Assert ($palEdit -ne [IntPtr]::Zero) 'palette has a focused search edit to receive keys'
    [void](Send-TestControlKey -Control $palEdit -Key Escape)
    Start-Sleep -Milliseconds 500
    Assert ((Get-TestWindow -ProcessId $script:appPid -Class 'GhozttyTerminal' -Exclude $script:top) -eq [IntPtr]::Zero) 'Escape closes the palette'
}

# Re-resolve the focused pane name for the read/write tests below.
$lj = Get-ListJson
$pane = (Get-PaneName (Get-SelectedTab $lj.data.windows[0]).splits)

# --- ctrl+c without selection: SIGINT ----------------------------------------
# Focus positive control first: a plain typed char must echo, proving the
# chord path still reaches the focused surface after the palette round-trip.
Send-TestText -Window $script:top -Target (Get-ActiveSurface) -Text 'focusok' | Out-Null
Start-Sleep -Milliseconds 700
$tail = & $Exe +read --name=$pane --lines=5 | Out-String
Assert ($tail -match 'focusok') 'focus control: typing reaches the pane before SIGINT test'
Send-Chord Escape | Out-Null
Start-Sleep -Milliseconds 300

& $Exe +send-keys --target=$pane "ping -t 127.0.0.1" Enter | Out-Null
Start-Sleep -Seconds 3
Send-Chord C ctrl | Out-Null
Start-Sleep -Milliseconds 1200
& $Exe +send-keys --target=$pane "echo SIGINT_RECOVERED" Enter | Out-Null
Start-Sleep -Seconds 2
$tail = & $Exe +read --name=$pane --lines=10 | Out-String
$ok = $tail -match 'SIGINT_RECOVERED'
Assert $ok 'ctrl+c without selection interrupts (shell prompt back)'
if (-not $ok) { Write-Host "  pane tail after ctrl+c:`n$tail" }
# Cleanup: if ping survived, kill it directly so the copy/paste tests below
# still run against a responsive shell. Only touch the loopback ping this
# test started.
Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match '127\.0\.0\.1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 800

# --- ctrl+c WITH selection: copy (no SIGINT) ---------------------------------
# Fill the screen with solid X-runs so a double-click anywhere mid-screen
# word-selects a run of X characters.
& $Exe +send-keys --target=$pane "cls" Enter | Out-Null
Start-Sleep -Milliseconds 800
$xline = 'X' * 120
for ($i = 0; $i -lt 10; $i++) {
    & $Exe +send-keys --target=$pane "echo $xline" Enter | Out-Null
}
Start-Sleep -Seconds 2
Set-Clipboard -Value 'T01_CLIP_SENTINEL'
# Probe against the SURFACE rect, and post the click to the surface: that is
# the child a real click would land on, and posted messages skip hit testing.
$surface = Get-ActiveSurface
$sr = Get-TestWindowRect -Window $surface
$cx = [int](($sr.Left + $sr.Right) / 2)
# The X block sits at the TOP of the screen (cls + 10 echo pairs), and prompt
# rows between the X rows make any single fixed row a coin flip - so probe a
# few upper rows until the clipboard proves a word-select happened.
$ok = $false; $clip = ''
foreach ($frac in 0.08, 0.13, 0.18, 0.23, 0.28) {
    $cy = [int]($sr.Top + ($sr.Bottom - $sr.Top) * $frac)
    [void](Send-TestMouse -Window $script:top -Target $surface -X $cx -Y $cy -Action doubleclick)
    Start-Sleep -Milliseconds 400
    Send-Chord C ctrl | Out-Null
    Start-Sleep -Milliseconds 700
    $clip = (Get-Clipboard -Raw -ErrorAction SilentlyContinue) -join ''
    $ok = $clip -match 'X{20}'
    if ($ok) { break }
}
if ($NegativeControl) {
    Write-Host 'NEGATIVE CONTROL: asserting the double-click copy did NOT reach the clipboard - this run MUST fail'
    Assert (-not $ok) 'NEGATIVE CONTROL: ctrl+c with selection copies NOTHING to the clipboard'
} else {
    Assert $ok 'ctrl+c with selection copies to clipboard'
}
if (-not $ok) {
    $clipShow = if ($clip.Length -gt 80) { $clip.Substring(0, 80) + '...' } else { $clip }
    Write-Host "  clipboard after copy: [$clipShow]"
    $tail = & $Exe +read --name=$pane --lines=8 | Out-String
    Write-Host "  pane tail: $($tail -replace 'X{10,}', 'X...X')"
}
# The copy path must NOT have interrupted the shell: the input line is
# still empty and the shell still responds.
& $Exe +send-keys --target=$pane "echo COPY_NO_SIGINT" Enter | Out-Null
Start-Sleep -Seconds 2
$tail = & $Exe +read --name=$pane --lines=5 | Out-String
Assert ($tail -match 'COPY_NO_SIGINT') 'shell alive after copy'

# --- ctrl+v: paste ------------------------------------------------------------
Set-Clipboard -Value 'T01_PASTE_TOKEN'
Send-Chord V ctrl | Out-Null
Start-Sleep -Milliseconds 1000
$tail = & $Exe +read --name=$pane --lines=5 | Out-String
$ok = $tail -match 'T01_PASTE_TOKEN'
Assert $ok 'ctrl+v pastes clipboard text onto the input line'
if (-not $ok) { Write-Host "  pane tail after paste: $tail" }
Send-Chord Escape | Out-Null

# --- ctrl+n: new window -------------------------------------------------------
Send-Chord N ctrl | Out-Null
$wins = @()
for ($t = 0; $t -lt 30; $t++) {
    Start-Sleep -Milliseconds 200
    $lj = Get-ListJson
    $wins = @($lj.data.windows)
    if ($wins.Count -eq 2) { break }
}
Assert ($wins.Count -eq 2) "ctrl+n opens a second window (got $($wins.Count))"
if ($wins.Count -eq 2) {
    Assert (-not (Test-TestDesktopLeak -ProcessId $script:appPid)) 'the ctrl+n window is NOT on the interactive desktop either'
    # Close the new window (the one that is not window 0) via IPC.
    $newWin = $wins | Where-Object { $_.id -ne $win0.id } | Select-Object -First 1
    $newPane = (Get-PaneName $newWin.tabs[0].splits)
    & $Exe +close --target=$newPane | Out-Null
    Start-Sleep -Milliseconds 1000
    $lj = Get-ListJson
    Assert (@($lj.data.windows).Count -eq 1) 'new window closed via +close'
}
Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash at end of run'

} finally {
    # Read the launched pids BEFORE cleanup: Remove-TestDesktop empties the
    # live pid list as it kills, and an emptied list makes the leak assertion
    # below vacuous (the batch-3 lesson).
    $script:launched = @(Get-TestLaunchedPids)
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 800)
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($script:launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)"; exit 0 }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
