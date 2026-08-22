# T154 acceptance: ctrl+v must PASTE when the clipboard holds text, and must
# FALL THROUGH to the pane (as a raw ^V) when it does not.
#
# T156 extends it to shift+insert (sections E/F): the generic non-darwin
# default bound shift+insert to paste_from_selection, which the win32 apprt
# can never satisfy (no selection clipboard), so the chord was swallowed
# outright - no paste, and the pane never saw the key. The Windows mirror
# block now re-binds it to paste_from_clipboard, performable.
#
# Why this matters: Claude Code (and other TUIs) read images off the system
# clipboard themselves when they receive ^V. Before T154 the Windows
# ctrl-mirror block bound ctrl+v with a plain put() and no `performable`
# flag, so ghoztty swallowed the chord unconditionally, pasted nothing (no
# CF_UNICODETEXT on an image-only clipboard) and the TUI never saw the key.
#
# Oracle: a tiny PowerShell probe runs INSIDE the pane and blocks on
# [Console]::ReadKey($true), then prints the character code it received.
# That distinguishes the three outcomes precisely:
#   text clipboard  + ctrl+v       -> probe sees the token's FIRST char (paste)
#   image clipboard + ctrl+v       -> probe sees 22 (0x16 = ^V, fall-through)
#   image clipboard + ctrl+shift+v -> probe sees 22 (already performable)
# A swallowed chord shows up as the probe never printing at all.
#
# T217: runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1),
# so it never takes the user's foreground - asserted at the end, not assumed.
# The private ClipDrv driver (T86 GrabForeground + SendInput) is gone; the
# harness supplies the equivalents, and the app is launched ONTO the desktop
# instead of by Start-Process.
#
# The CLIPBOARD is unaffected by the move: it is scoped to the WINDOW STATION,
# and CreateDesktopW makes the test desktop inside this process's own
# WinSta0 - so the fixtures this script sets are the ones the app reads. That
# is also why this script still needs an STA host.
#
# Only touches ghoztty processes running from this repo's zig-out.
#
#   powershell -NoProfile -File test\win32\clipboard-paste.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
$errlog = Join-Path $env:TEMP 'ghoztty-clipboard-paste-stderr.log'
Remove-Item $errlog -ErrorAction SilentlyContinue

# Isolate the IPC endpoint unconditionally: the app inherits this through
# CreateProcessW and so does every `& $Exe +...` below, so a run can never
# drive whatever instance happens to own the shared pipe.
$env:GHOZTTY_PIPE_SUFFIX = '-clippastetest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- clipboard helpers --------------------------------------------------------
# powershell.exe is STA by default, which System.Windows.Forms.Clipboard
# requires. Bail loudly rather than producing confusing failures if not.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host 'SETUP FAIL: run under an STA host (powershell.exe, not -MTA)'
    exit 1
}

function Set-TextClipboard([string]$text) {
    for ($t = 0; $t -lt 10; $t++) {
        try {
            [System.Windows.Forms.Clipboard]::Clear()
            if ($text -ne '') { [System.Windows.Forms.Clipboard]::SetText($text) }
            return $true
        } catch { Start-Sleep -Milliseconds 200 }
    }
    return $false
}

# An IMAGE with NO text format at all - this is the screenshot case that
# T154 is about (GetClipboardData(CF_UNICODETEXT) returns null).
function Set-ImageOnlyClipboard {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Red)
    $g.Dispose()
    try {
        for ($t = 0; $t -lt 10; $t++) {
            try {
                [System.Windows.Forms.Clipboard]::Clear()
                [System.Windows.Forms.Clipboard]::SetImage($bmp)
                return $true
            } catch { Start-Sleep -Milliseconds 200 }
        }
    } finally { $bmp.Dispose() }
    return $false
}

# --- the in-pane probe --------------------------------------------------------
# Blocks on ReadKey and prints the raw character code it received. Written
# to TEMP so no quoting has to survive +send-keys.
$probe = Join-Path $env:TEMP 'ghoztty-clip-probe.ps1'
@'
param([string]$Tag)
[Console]::Out.Write("PROBE_READY_" + $Tag + "`r`n")
$k = [Console]::ReadKey($true)
[Console]::Out.Write("PROBE_" + $Tag + "_CHAR=" + [int]$k.KeyChar + "`r`n")
'@ | Set-Content -Path $probe -Encoding ASCII

function Read-Tail([int]$lines = 20) {
    return (& $Exe +read --name=$script:pane --lines=$lines | Out-String)
}

function Wait-Text([string]$pattern, [int]$timeoutSec = 12) {
    for ($t = 0; $t -lt $timeoutSec * 5; $t++) {
        Start-Sleep -Milliseconds 200
        $tail = Read-Tail
        if ($tail -match $pattern) { return $tail }
    }
    return $null
}

# Start the probe and wait until it is actually blocked in ReadKey.
function Start-Probe([string]$tag) {
    & $Exe +send-keys --target=$script:pane 'cls' Enter | Out-Null
    Start-Sleep -Milliseconds 600
    & $Exe +send-keys --target=$script:pane "powershell -NoProfile -File $probe -Tag $tag" Enter | Out-Null
    $seen = Wait-Text "PROBE_READY_$tag"
    if ($null -eq $seen) { return $false }
    Start-Sleep -Milliseconds 500   # ReadKey is entered right after the print
    return $true
}

# Unblock a probe that never received a key, and get back to a prompt.
function Stop-Probe {
    & $Exe +send-keys --target=$script:pane 'q' | Out-Null
    Start-Sleep -Milliseconds 400
    & $Exe +send-keys --target=$script:pane Enter | Out-Null
    Start-Sleep -Milliseconds 800
}

function Get-AnyLeaf($node) {
    if ($node.type -eq 'leaf') { return $node.terminal }
    return (Get-AnyLeaf $node.left)
}

# --- Setup: fresh debug instance on the test desktop -------------------------
# --session-persistence=false so a restore cannot hand back a previous run's
# window (the T131 lesson), and so the surviving agent cannot replay a layout
# manifest over what this run asserts (the batch-2 lesson).
[void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 800)
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$app = $null

try {

$app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -StdErr $errlog
Start-Sleep -Seconds 3
if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
$top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'window is NOT enumerable on the interactive desktop'

$lj = $null
for ($t = 0; $t -lt 25 -and $null -eq $lj; $t++) {
    $lj = & $Exe +list --json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($null -eq $lj -or @($lj.data.windows).Count -eq 0) { $lj = $null; Start-Sleep -Milliseconds 300 }
}
if ($null -eq $lj) { Write-Host 'SETUP FAIL: no window in +list'; exit 1 }
$win0 = $lj.data.windows[0]
$script:pane = (Get-AnyLeaf $win0.tabs[0].splits).name
if ([string]::IsNullOrEmpty($script:pane)) { Write-Host 'SETUP FAIL: no pane name'; exit 1 }
# The window id in +list --json IS the decimal HWND (IpcHandlers.zig formats
# @intFromPtr(hwnd)), so this ties the pane NAME the IPC verbs use to the
# HWND the chords go to - rather than trusting they found the same window.
Assert ([int64]$win0.id -eq [int64]$top) '+list window id is the HWND the harness found'
Assert ((Get-TestWindowClass -Window $top) -eq 'GhozttyWindow') 'that HWND really is a GhozttyWindow'
Write-Host "pane=$script:pane top=$top"

# The surface the app itself considers active. GhozttyWindow hands WM_KEYDOWN
# to DefWindowProc and only forwards FOCUS to the active pane, so a posted
# chord aimed at the window is silently dropped (batch-3 lesson).
Focus-TestWindow -Window $top | Out-Null
Start-Sleep -Milliseconds 500
$surface = [IntPtr](Get-TestFocusedWindow -Window $top)
Assert ((Get-TestWindowClass -Window $surface) -eq 'GhozttyTerminal') 'window forwarded focus to a terminal surface'

# --- Positive control: typed text must echo ----------------------------------
& $Exe +send-keys --target=$script:pane 'cls' Enter | Out-Null
Start-Sleep -Milliseconds 600
$sent = Send-TestText -Window $top -Target $surface -Text 'clipctl'
if (-not $sent) { Write-Host 'SKIP ALL: harness could not post keys'; exit 0 }
$tail = Wait-Text 'clipctl' 8
if ($null -eq $tail) {
    Write-Host 'SKIP ALL: positive control failed - injected keys never reached the pane'
    exit 0
}
Assert $true 'positive control: typed keys reach the pane'
& $Exe +send-keys --target=$script:pane C-c | Out-Null
Start-Sleep -Milliseconds 600

# --- Harness sanity: the clipboard fixtures are what we claim -----------------
Assert (Set-TextClipboard 'ZQTOKEN') 'harness: text clipboard set'
Assert ([System.Windows.Forms.Clipboard]::ContainsText()) 'harness: text clipboard reports text'
Assert (Set-ImageOnlyClipboard) 'harness: image clipboard set'
Assert ([System.Windows.Forms.Clipboard]::ContainsImage()) 'harness: image clipboard reports an image'
Assert (-not [System.Windows.Forms.Clipboard]::ContainsText()) 'harness: image clipboard has NO text format'

# --- A: text clipboard + ctrl+v -> pastes (probe sees the token, not ^V) ------
Set-TextClipboard 'ZQTOKEN' | Out-Null
if (-not (Start-Probe 'A')) {
    Assert $false 'A: probe became ready'
} else {
    $sent = Send-TestKeys -Window $top -Target $surface -Modifiers ctrl -Key V
    Assert $sent 'A: ctrl+v injected'
    $tail = Wait-Text 'PROBE_A_CHAR=(\d+)' 10
    $code = if ($tail -match 'PROBE_A_CHAR=(\d+)') { [int]$Matches[1] } else { -1 }
    Assert ($code -eq 90) "A: ctrl+v with text on the clipboard pastes (probe char=$code, want 90 'Z')"
    Assert ($code -ne 22) 'A: ctrl+v does NOT leak a stray ^V when the paste succeeds'
    Stop-Probe
}

# --- B: image-only clipboard + ctrl+v -> falls through as ^V ------------------
# THE T154 CASE. Pre-fix this fails with code=-1: ghoztty swallows the chord.
Set-ImageOnlyClipboard | Out-Null
if (-not (Start-Probe 'B')) {
    Assert $false 'B: probe became ready'
} else {
    $sent = Send-TestKeys -Window $top -Target $surface -Modifiers ctrl -Key V
    Assert $sent 'B: ctrl+v injected'
    $tail = Wait-Text 'PROBE_B_CHAR=(\d+)' 10
    $code = if ($tail -match 'PROBE_B_CHAR=(\d+)') { [int]$Matches[1] } else { -1 }
    # -NegativeControl inverts the load-bearing claim of the whole script -
    # that an image-only clipboard lets ctrl+v through as ^V. The run MUST
    # fail here, which is what proves the assertion discriminates.
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: asserting ctrl+v is SWALLOWED on an image-only clipboard - this run MUST fail'
        Assert ($code -eq -1) "B (inverted): ctrl+v is swallowed with an image-only clipboard (probe char=$code, want none)"
    } else {
        Assert ($code -eq 22) "B: ctrl+v with an image-only clipboard reaches the pane as ^V (probe char=$code, want 22)"
    }
    Stop-Probe
}

# --- C: image-only clipboard + ctrl+shift+v -> already falls through ----------
# The shared cross-platform binding has always carried performable=true; this
# is the control that proves the diagnosis is about the FLAG, not the chord.
Set-ImageOnlyClipboard | Out-Null
if (-not (Start-Probe 'C')) {
    Assert $false 'C: probe became ready'
} else {
    $sent = Send-TestKeys -Window $top -Target $surface -Modifiers ctrl,shift -Key V
    Assert $sent 'C: ctrl+shift+v injected'
    $tail = Wait-Text 'PROBE_C_CHAR=(\d+)' 10
    $code = if ($tail -match 'PROBE_C_CHAR=(\d+)') { [int]$Matches[1] } else { -1 }
    Assert ($code -eq 22) "C: ctrl+shift+v with an image-only clipboard reaches the pane as ^V (probe char=$code, want 22)"
    Stop-Probe
}

# --- D: text clipboard + ctrl+v at a normal prompt still pastes the text ------
# Section A proves the FIRST character; this proves the whole string lands on
# the input line (i.e. the paste path itself is untouched by the flag).
Set-TextClipboard 'ZQ_FULL_PASTE_TOKEN' | Out-Null
& $Exe +send-keys --target=$script:pane 'cls' Enter | Out-Null
Start-Sleep -Milliseconds 800
$sent = Send-TestKeys -Window $top -Target $surface -Modifiers ctrl -Key V
Assert $sent 'D: ctrl+v injected'
$tail = Wait-Text 'ZQ_FULL_PASTE_TOKEN' 10
Assert ($null -ne $tail) 'D: ctrl+v pastes the full clipboard text onto the input line'
& $Exe +send-keys --target=$script:pane C-c | Out-Null
Start-Sleep -Milliseconds 500

# --- E: text clipboard + shift+insert -> pastes (T156) ------------------------
# Windows Terminal / conhost parity chord. Pre-fix this fails with code=-1:
# the paste_from_selection binding can never perform on win32 and the chord
# was swallowed whole.
Set-TextClipboard 'ZQTOKEN' | Out-Null
if (-not (Start-Probe 'E')) {
    Assert $false 'E: probe became ready'
} else {
    $sent = Send-TestKeys -Window $top -Target $surface -Modifiers shift -Key insert
    Assert $sent 'E: shift+insert injected'
    $tail = Wait-Text 'PROBE_E_CHAR=(\d+)' 10
    $code = if ($tail -match 'PROBE_E_CHAR=(\d+)') { [int]$Matches[1] } else { -1 }
    Assert ($code -eq 90) "E: shift+insert with text on the clipboard pastes (probe char=$code, want 90 'Z')"
    Stop-Probe
}

# --- F: image-only clipboard + shift+insert -> reaches the pane (T156) --------
# With nothing to paste the performable binding must decline, letting the
# chord fall through to the pane as a keystroke (however ConPTY renders it -
# what matters is that the probe's ReadKey RETURNS, which a swallowed chord
# never causes).
Set-ImageOnlyClipboard | Out-Null
if (-not (Start-Probe 'F')) {
    Assert $false 'F: probe became ready'
} else {
    $sent = Send-TestKeys -Window $top -Target $surface -Modifiers shift -Key insert
    Assert $sent 'F: shift+insert injected'
    $tail = Wait-Text 'PROBE_F_CHAR=(\d+)' 10
    $code = if ($tail -match 'PROBE_F_CHAR=(\d+)') { [int]$Matches[1] } else { -1 }
    Assert ($code -ne -1) "F: shift+insert with an image-only clipboard reaches the pane instead of being swallowed (probe char=$code)"
    Stop-Probe
}

Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash at end of run'

} finally {
    # Read the launched pids BEFORE cleanup: Remove-TestDesktop empties the
    # live pid list as it kills, and an emptied list makes the leak assertion
    # below vacuous (the batch-3 lesson).
    $script:launched = @(Get-TestLaunchedPids)
    Set-TextClipboard '' | Out-Null
    Remove-TestDesktop
    [void](Stop-RepoGhoztty -Exe $Exe -AppOnly -SettleMs 800)
    Remove-Item $probe -ErrorAction SilentlyContinue
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
