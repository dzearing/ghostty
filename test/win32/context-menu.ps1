# T102 acceptance: Mac-parity right-click context menu on win32.
#
# Sections:
#   F: WM_CONTEXTMENU (VK_APPS / Shift+F10 path) opens the menu on a virgin
#      pane; full Mac-parity item list with Copy grayed (no selection yet).
#   A: posted right-click opens the menu; right-click ON text pre-selects
#      the word (Mac parity) so Copy enables.
#   B: keyboard selection dispatches - "P" picks Paste and the clipboard
#      sentinel lands in the pane (TrackPopupMenuEx TPM_RETURNCMD wiring).
#   C: "T" toggles Terminal Read-only; reopened menu shows MF_CHECKED;
#      toggling again clears it.
#   D: with mouse reporting active in the pane, a plain right-click STILL
#      opens the context menu (T240). This section asserted the opposite
#      until 2026-07-31 - that every pane running a TUI loses the menu - and
#      that is precisely the state the user reported as "there is no right
#      click context menu like in the mac version". Every pane they keep open
#      (Claude Code, vim, lazygit) turns reporting on, so a menu gated on the
#      core's "unconsumed" verdict is a menu that never appears.
#      Shift+right-click still opens it too (now redundant, not wrong).
#   D2: the same reporting fixture with `right-click-action = paste` shows NO
#      menu - the click goes to the app. That is both the documented opt-out
#      and this run's ORACLE that reporting is genuinely active: without it,
#      D's assertion would pass trivially on a pane whose mode never landed.
#   E: `right-click-action = paste` opt-out - right-click pastes, no menu
#      (the Windows-Terminal-style behavior, as a config choice).
#   G: T129 discoverability - the menu carries "Set Pane Banner..." labeled
#      with its accelerator (Ctrl+Shift+B, NOT the Mac cmd+r), the label
#      tracks the live keybind set (a rebind relabels it), and choosing the
#      row opens the banner editor.
#
# T218: migrated onto the BACKGROUND test desktop (test/win32/lib/TestDesktop.ps1),
# so the run never takes the user's foreground - asserted here, not assumed.
#
# The script was ALREADY all-PostMessage, so the input half needed nothing: it
# is window ENUMERATION that is desktop-bound (EnumWindows walks the CALLING
# thread's desktop), which is why every FindTop/FindPane/MenuWindow now goes
# through the harness's worker thread. Two things worth carrying forward:
#
#   * Section A used to park the physical cursor with SetCursorPos because the
#     core resolves the right-clicked word through `rt_surface.getCursorPos()`.
#     SetCursorPos is dead off the input desktop (T218 batch 3) - and it is no
#     longer needed: T216 gave `win32.Surface.getCursorPos` a fallback to
#     `last_cursor_client`, the position carried by the last mouse MESSAGE, so
#     the posted click's own coordinates are what the word-select resolves
#     against. Verified in src/apprt/win32/Surface.zig (getCursorPos +
#     noteCursorFromLparam). The SetCursorPos call is gone, not replaced.
#   * The clipboard is a WINDOW STATION resource, not a desktop one, so the
#     script (interactive desktop) and the app (test desktop) share it and the
#     paste sections migrate unchanged.
#
# -NegativeControl flips section F's Copy expectation to "enabled" on a pane
# that has no selection, which MUST fail; it is how a run proves the menu-state
# read still discriminates.
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
# Always isolated, not just under -ExePath: the IPC probes below (+list, +read)
# must reach THIS run's app and nothing else on the box.
$env:GHOZTTY_PIPE_SUFFIX = '-ctxmenutest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# Clipboard without the trailing CRLF that PS5.1 Set-Clipboard appends (a
# newline would trip the core's unsafe-paste confirmation instead of
# pasting).
Add-Type -AssemblyName System.Windows.Forms
function Set-ClipText([string]$s) { [System.Windows.Forms.Clipboard]::SetText($s) }

# HMENU reads only. These take a menu HANDLE, not a window, so they are not
# desktop-bound and run fine from this process; window enumeration is the part
# that has to go through the harness.
Add-Type @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;
public class CtxMenuRead {
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuStringW(IntPtr menu, uint idItem, StringBuilder sb, int max, uint flags);
    [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr menu, uint id, uint flags);

    // Item strings by position; separators come back as "---"; grayed and
    // checked states append ":grayed"/":checked".
    public static string[] Items(IntPtr menu) {
        if (menu == IntPtr.Zero) return new string[0];
        int n = GetMenuItemCount(menu);
        var items = new List<string>();
        for (uint i = 0; i < (uint)n; i++) {
            uint state = GetMenuState(menu, i, 0x400); // MF_BYPOSITION
            if ((state & 0x800) != 0) { items.Add("---"); continue; } // MF_SEPARATOR
            var sb = new StringBuilder(128);
            GetMenuStringW(menu, i, sb, 128, 0x400);
            string flags = "";
            if ((state & 0x3) != 0) flags += ":grayed";   // MF_GRAYED|MF_DISABLED
            if ((state & 0x8) != 0) flags += ":checked";  // MF_CHECKED
            items.Add(sb.ToString() + flags);
        }
        return items.ToArray();
    }
}
'@

function Kill-RepoInstances {
    # T351: one shared, path-exact kill (lib\CleanSlate.ps1) instead of a private
    # copy - the filter this replaced also matched a detached instance running from
    # zig-out-release (T53b), and every copy answered "does the agent go too" alone.
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

# ---- menu helpers (harness-backed) ----------------------------------------

function Wait-Menu([int]$gpid, [int]$ms = 3000) {
    Wait-TestPopupMenu -ProcessId $gpid -TimeoutMs $ms
}

function Test-MenuGone([int]$gpid, [int]$ms = 2000) {
    for ($t = 0; $t -lt $ms; $t += 50) {
        if ((Get-TestWindow -ProcessId $gpid -Class '#32768') -eq [IntPtr]::Zero) { return $true }
        Start-Sleep -Milliseconds 50
    }
    return $false
}

# The live popup's items. MN_GETHMENU is SENT: the app's GUI thread is inside
# TrackPopupMenuEx's modal loop, which pumps messages, so a cross-process send
# is answered (and SMTO_ABORTIFHUNG does not trip on a pumping thread).
function Get-MenuItems([IntPtr]$menuWnd) {
    $r = Invoke-TestMessage -Window $menuWnd -Message 0x01E1
    if ($r -eq [long]::MinValue -or $r -eq 0) { return @() }
    return [CtxMenuRead]::Items([IntPtr]$r)
}

# Cancel any active menu modal loop on the pane's thread.
function Cancel-Menu([IntPtr]$pane) {
    [void](Invoke-TestMessage -Window $pane -Message 0x001F) # WM_CANCELMODE
}

# Post a key into the menu's modal loop. The loop retrieves queue messages
# regardless of target hwnd, and Send-TestControlKey posts without touching
# focus (Send-TestKeys would SetFocus first and dismiss the menu).
function Send-MenuKey([IntPtr]$pane, [string]$key) {
    [void](Send-TestControlKey -Control $pane -Key $key)
}

# Right-button press at a CLIENT offset in the pane; -1,-1 means pane center.
# Send-TestMouse takes SCREEN coordinates, so the offset is resolved against
# the pane's client rect (which the harness already returns in screen space).
function Send-PaneRight {
    param(
        [IntPtr]$Top, [IntPtr]$Pane,
        [int]$X = -1, [int]$Y = -1,
        [ValidateSet('down', 'up')][string]$Action = 'down',
        [string[]]$Modifiers = @()
    )
    $pr = Get-TestWindowRect -Window $Pane -Client
    if ($X -lt 0) {
        $sx = [int](($pr.Left + $pr.Right) / 2); $sy = [int](($pr.Top + $pr.Bottom) / 2)
    } else {
        $sx = $pr.Left + $X; $sy = $pr.Top + $Y
    }
    [void](Send-TestMouse -Window $Top -Target $Pane -X $sx -Y $sy `
        -Button right -Action $Action -Modifiers $Modifiers)
}

function Start-Gui([string]$label, [string[]]$extraArgs) {
    Kill-RepoInstances
    # session-persistence=false (CLI bools take true/false, NOT on/off):
    # agent-backed panes would re-attach stale sessions across the script's
    # force-kills and leave the pane's shell dead/blank (paste has no live
    # pty to echo into; launch restore replaces the -e window). Also drop
    # any stale debug layout manifest so no prior test's layout restores.
    Remove-Item "$env:LOCALAPPDATA\ghoztty\session-layout-debug.json" -Force -ErrorAction SilentlyContinue
    $argList = @('--config-default-files=false', '--session-persistence=false') + $extraArgs
    $app = Start-OnTestDesktop -Exe $exe -Arguments $argList
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host "SETUP FAIL ($label): GUI died at launch"; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL ($label): top window not found"; exit 1 }
    $pane = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($pane -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL ($label): pane not found"; exit 1 }

    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) `
        "$label window is NOT enumerable on the interactive desktop"
    if (-not (Focus-TestWindow -Window $top -Child $pane)) {
        Write-Host "SETUP FAIL ($label): could not focus the GUI"; Stop-Process -Id $app.Pid -Force; exit 1
    }

    $listJson = & $exe +list --json | Out-String
    $paneName = $null
    if ($listJson -match '"name"\s*:\s*"([^"]+)"') { $paneName = $Matches[1] }
    [pscustomobject]@{ App = $app; Pid = [int]$app.Pid; Top = $top; Pane = $pane; PaneName = $paneName }
}

function Read-Pane([string]$paneName, [int]$lines = 30) {
    & $exe +read --name=$paneName --lines=$lines 2>$null | Out-String
}

function Dump-Items([string[]]$items, [string]$label) {
    Write-Host "      $label items: $($items -join ' | ')"
}

# Get-MenuItems returns "Base[<tab>Accel][:grayed][:checked]" (T129 added the
# accelerator half). Split it back apart so the item-list compare stays about
# labels/flags and the accelerator gets its own assertions.
function Split-Item([string]$s) {
    $flags = ''
    $more = $true
    while ($more) {
        $more = $false
        foreach ($f in @(':grayed', ':checked')) {
            if ($s.EndsWith($f)) { $flags = $f + $flags; $s = $s.Substring(0, $s.Length - $f.Length); $more = $true }
        }
    }
    $accel = ''
    $tab = $s.IndexOf("`t")
    if ($tab -ge 0) { $accel = $s.Substring($tab + 1); $s = $s.Substring(0, $tab) }
    [pscustomobject]@{ Base = $s; Accel = $accel; Flags = $flags; Label = ($s + $flags) }
}

function Split-Items([string[]]$items) { $items | ForEach-Object { Split-Item $_ } }

# Accelerator for a base label, or '' when the row has none / is missing.
function Accel-For($parsed, [string]$base) {
    $row = @($parsed | Where-Object { $_.Base -eq $base })
    if ($row.Count -eq 0) { return $null }
    $row[0].Accel
}

# The Mac surface menu (menu(for:)) + win32's Select All; the exact rows the
# pure context_menu.zig model must produce on a pane with no selection.
#
# Accelerator suffixes are stripped before the compare (see Split-Item);
# section G asserts those separately.
$expected = @(
    'Copy:grayed', 'Paste', 'Select All', '---',
    'Split Right', 'Split Left', 'Split Down', 'Split Up', '---',
    'Reset Terminal', 'Terminal Read-only', '---',
    'Background Color...', '---',
    'Change Tab Title...', 'Change Pane Title...', 'Set Pane Banner...'
)
if ($NegativeControl) {
    Write-Host 'NEGATIVE CONTROL: section F asserts Copy is ENABLED on a pane with no selection - this run MUST fail'
    $expected[0] = 'Copy'
}

Kill-RepoInstances

# Watch the user's desktop for the whole run: nothing we launch may ever take
# foreground there. That is the complaint the test desktop exists to fix.
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$launched = @()

try {

# ---------------------------------------------------------------------------
# Run 1: sections F, A, B, C (default config).
# ---------------------------------------------------------------------------
$g = Start-Gui 'default' @()
$launched += $g.Pid
$gpid = $g.Pid; $pane = $g.Pane; $paneName = $g.PaneName

# F: keyboard path on a virgin pane - no selection exists, so this is the
# deterministic Copy:grayed check plus the full item-list compare.
# WM_CONTEXTMENU with lparam -1 is the VK_APPS / Shift+F10 shape.
[void](Send-TestRawMessage -Window $pane -Message 0x007B -WParam $pane -LParam ([IntPtr](-1)))
$menuWnd = Wait-Menu $gpid 3000
Assert ($menuWnd -ne [IntPtr]::Zero) 'F: WM_CONTEXTMENU (VK_APPS path) opens the menu'
if ($menuWnd -ne [IntPtr]::Zero) {
    $items = Get-MenuItems $menuWnd
    $parsed = @(Split-Items $items)
    Assert ($items.Count -eq $expected.Count) "F: menu has $($expected.Count) rows (got $($items.Count))"
    $mismatch = @()
    for ($i = 0; $i -lt [Math]::Min($parsed.Count, $expected.Count); $i++) {
        if ($parsed[$i].Label -ne $expected[$i]) { $mismatch += "row $i got '$($parsed[$i].Label)' want '$($expected[$i])'" }
    }
    Assert ($mismatch.Count -eq 0) 'F: item order/labels/flags match the Mac surface menu'
    if ($mismatch.Count) { $mismatch | ForEach-Object { Write-Host "      $_" }; Dump-Items $items 'F' }

    # G: the banner row and its self-teaching accelerator (T129).
    $bannerAccel = Accel-For $parsed 'Set Pane Banner...'
    Assert ($null -ne $bannerAccel) 'G: menu carries a "Set Pane Banner..." row'
    Assert ($bannerAccel -eq 'Ctrl+Shift+B') "G: banner row is labeled Ctrl+Shift+B (got '$bannerAccel')"
    # The whole point of the row: the Windows chord is NOT the Mac one.
    Assert ($bannerAccel -notmatch 'Win\+R|Ctrl\+R$') 'G: banner accelerator is not the Mac cmd+r chord'
    # Accelerators are a menu-wide affordance, not a one-off for the banner.
    $withAccel = @($parsed | Where-Object { $_.Accel -ne '' })
    Assert ($withAccel.Count -ge 3) "G: bound items show their chords (got $($withAccel.Count) labeled rows)"
    Write-Host "      G accels: $(($withAccel | ForEach-Object { "$($_.Base)=$($_.Accel)" }) -join ' | ')"
    # An action with no default bind must show a bare label, not an empty tab.
    $unbound = @($parsed | Where-Object { $_.Base -eq 'Background Color...' })
    Assert ($unbound.Count -eq 1 -and $unbound[0].Accel -eq '') 'G: apprt-local row (Background Color...) shows no chord'
}
Cancel-Menu $pane
Assert (Test-MenuGone $gpid 2000) 'F: WM_CANCELMODE dismisses the menu'

# A: right-click ON text (the cmd banner on row 0) pre-selects the clicked
# word (Mac parity: right-click-down selects for the menu), enabling Copy.
# The core resolves the word through getCursorPos, which off the input desktop
# answers from the last mouse MESSAGE - i.e. from this click's own coordinates.
Send-PaneRight -Top $g.Top -Pane $pane -X 80 -Y 16 -Action down
$menuWnd = Wait-Menu $gpid 3000
Assert ($menuWnd -ne [IntPtr]::Zero) 'A: right-click opens the context menu'
if ($menuWnd -ne [IntPtr]::Zero) {
    $items = Get-MenuItems $menuWnd
    $parsed = @(Split-Items $items)
    $copyOk = ($parsed.Count -gt 0 -and $parsed[0].Label -eq 'Copy')
    Assert $copyOk 'A: right-click on text selects the word (Copy enabled)'
    if (-not $copyOk) { Dump-Items $items 'A' }
}
Cancel-Menu $pane
[void](Test-MenuGone $gpid 2000)

# B: keyboard selection dispatches - "P" = Paste; sentinel reaches the pty.
$sentinel = 'CTXMENU_PASTE_OK_77'
Set-ClipText $sentinel
Send-PaneRight -Top $g.Top -Pane $pane -Action down
$menuWnd = Wait-Menu $gpid 3000
Assert ($menuWnd -ne [IntPtr]::Zero) 'B: menu reopens for the paste test'
Send-MenuKey $pane 'P'   # unique match "Paste", executes
Assert (Test-MenuGone $gpid 2000) 'B: typing P closes the menu (item executed)'
$pasted = $false
for ($t = 0; $t -lt 20; $t++) {
    Start-Sleep -Milliseconds 250
    if ((Read-Pane $paneName) -match $sentinel) { $pasted = $true; break }
}
Assert $pasted 'B: menu Paste typed the clipboard sentinel into the pane'
Cancel-Menu $pane
[void](Test-MenuGone $gpid 2000)

# C: "T" toggles Terminal Read-only; reopened menu shows the check.
Send-PaneRight -Top $g.Top -Pane $pane -Action down
$menuWnd = Wait-Menu $gpid 3000
Assert ($menuWnd -ne [IntPtr]::Zero) 'C: menu reopens for the readonly test'
Send-MenuKey $pane 'T'   # unique match "Terminal Read-only"
[void](Test-MenuGone $gpid 2000)
Start-Sleep -Milliseconds 300
Send-PaneRight -Top $g.Top -Pane $pane -Action down
$menuWnd = Wait-Menu $gpid 3000
$checked = $false
if ($menuWnd -ne [IntPtr]::Zero) {
    $items = Get-MenuItems $menuWnd
    $checked = ($items -contains 'Terminal Read-only:checked')
}
Assert $checked 'C: Terminal Read-only shows checked after toggle'
Send-MenuKey $pane 'T'   # toggle back off
[void](Test-MenuGone $gpid 2000)
Start-Sleep -Milliseconds 300
Send-PaneRight -Top $g.Top -Pane $pane -Action down
$menuWnd = Wait-Menu $gpid 3000
$unchecked = $false
if ($menuWnd -ne [IntPtr]::Zero) {
    $items = Get-MenuItems $menuWnd
    $unchecked = ($items -contains 'Terminal Read-only')
}
Assert $unchecked 'C: Terminal Read-only unchecked after second toggle'
Cancel-Menu $pane
[void](Test-MenuGone $gpid 2000)

# G: choosing the banner row opens the editor. The row is last, so Up from a
# fresh menu lands on it (no letter key: Select All / the four Splits / Set
# Pane Banner all start with S).
Send-PaneRight -Top $g.Top -Pane $pane -Action down
$menuWnd = Wait-Menu $gpid 3000
Assert ($menuWnd -ne [IntPtr]::Zero) 'G: menu reopens for the banner-row test'
Send-MenuKey $pane 'Up'
Send-MenuKey $pane 'Enter'
Assert (Test-MenuGone $gpid 2000) 'G: choosing the banner row closes the menu'
$dlg = Wait-TestWindow -ProcessId $gpid -Class 'GhozttyBannerDialog' -TimeoutMs 3000
Assert ($dlg -ne [IntPtr]::Zero) 'G: banner row opens the banner editor (GhozttyBannerDialog)'
if ($dlg -ne [IntPtr]::Zero) {
    [void](Send-TestWindowClose -Window $dlg)
    $gone = $false
    for ($t = 0; $t -lt 40; $t++) {
        Start-Sleep -Milliseconds 50
        if ((Get-TestWindow -ProcessId $gpid -Class 'GhozttyBannerDialog') -eq [IntPtr]::Zero) { $gone = $true; break }
    }
    Assert $gone 'G: banner editor closes again'
}

Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) 'run 1: no crash'
Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Run 2: section D - the pane's command enables mouse reporting the way real
# Windows TUIs do: SetConsoleMode(ENABLE_MOUSE_INPUT), which conhost
# translates into an outward DECSET on the ConPTY. (A raw ?1002h written by
# the child does NOT propagate out of ConPTY - verified 2026-07-20.)
# ---------------------------------------------------------------------------
$inner = @'
$sig='[DllImport("kernel32.dll")]public static extern IntPtr GetStdHandle(int n);[DllImport("kernel32.dll")]public static extern bool GetConsoleMode(IntPtr h,out uint m);[DllImport("kernel32.dll")]public static extern bool SetConsoleMode(IntPtr h,uint m);'
$k=Add-Type -MemberDefinition $sig -Name K -Namespace W -PassThru
$h=$k::GetStdHandle(-10)
$m=0
$k::GetConsoleMode($h,[ref]$m)|Out-Null
$k::SetConsoleMode($h, ($m -bor 0x10 -bor 0x80) -band (-bnot 0x40))|Out-Null
Write-Host "MOUSEMODE-ON"
Start-Sleep 120
'@
$b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
# Start-OnTestDesktop quotes any argument containing a space, so --command is
# passed bare here (the pre-migration Start-Process needed the quotes inline).
$g = Start-Gui 'mouse-reporting' @("--command=powershell -NoProfile -EncodedCommand $b64")
$launched += $g.Pid
$gpid = $g.Pid; $pane = $g.Pane

# Wait for the child to say the console mode is set, rather than guessing at
# startup latency. The marker is printed AFTER SetConsoleMode, so seeing it
# means conhost has already emitted the outward DECSET.
$modeOn = $false
for ($t = 0; $t -lt 30; $t++) {
    if ((Read-Pane $g.PaneName 40) -match 'MOUSEMODE-ON') { $modeOn = $true; break }
    Start-Sleep -Milliseconds 500
}
Assert $modeOn 'D: fixture pane really did enable mouse reporting'

Send-PaneRight -Top $g.Top -Pane $pane -Action down
$menuWnd = Wait-Menu $gpid 3000
Assert ($menuWnd -ne [IntPtr]::Zero) 'D: plain right-click opens the menu under mouse reporting (T240)'
if ($menuWnd -ne [IntPtr]::Zero) { Cancel-Menu $pane; [void](Test-MenuGone $gpid 2000) }
Send-PaneRight -Top $g.Top -Pane $pane -Action up
Start-Sleep -Milliseconds 300

Send-PaneRight -Top $g.Top -Pane $pane -Action down -Modifiers shift
$menuWnd = Wait-Menu $gpid 3000
Assert ($menuWnd -ne [IntPtr]::Zero) 'D: shift+right-click bypasses mouse reporting (menu opens)'
Cancel-Menu $pane
[void](Test-MenuGone $gpid 2000)

Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) 'run 2: no crash'
Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Run 2b: section D2 - the SAME reporting fixture under
# `right-click-action = paste`. No menu: only the context-menu disposition
# was changed by T240, the opt-out still hands the click to the app.
#
# This is also the oracle for section D. D asserts a menu APPEARS, which is
# what a pane with no reporting at all does too - so without a case that
# proves the fixture's reporting is live and still able to swallow a click,
# D could pass on a broken fixture.
# ---------------------------------------------------------------------------
$g = Start-Gui 'mouse-reporting-paste' @("--command=powershell -NoProfile -EncodedCommand $b64", '--right-click-action=paste')
$launched += $g.Pid
$gpid = $g.Pid; $pane = $g.Pane

$modeOn = $false
for ($t = 0; $t -lt 30; $t++) {
    if ((Read-Pane $g.PaneName 40) -match 'MOUSEMODE-ON') { $modeOn = $true; break }
    Start-Sleep -Milliseconds 500
}
Assert $modeOn 'D2: fixture pane really did enable mouse reporting'

Send-PaneRight -Top $g.Top -Pane $pane -Action down
$menuWnd = Wait-Menu $gpid 1500
Assert ($menuWnd -eq [IntPtr]::Zero) 'D2: right-click-action=paste still gives the click to the reporting app (no menu)'
if ($menuWnd -ne [IntPtr]::Zero) { Cancel-Menu $pane; [void](Test-MenuGone $gpid 2000) }
Send-PaneRight -Top $g.Top -Pane $pane -Action up

Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) 'run 2b: no crash'
Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Run 3: section E - right-click-action=paste opt-out (WT-style).
# ---------------------------------------------------------------------------
$g = Start-Gui 'paste-optout' @('--right-click-action=paste')
$launched += $g.Pid
$gpid = $g.Pid; $pane = $g.Pane; $paneName = $g.PaneName

$sentinel2 = 'CTXMENU_RCA_PASTE_88'
Set-ClipText $sentinel2
Send-PaneRight -Top $g.Top -Pane $pane -Action down
$menuWnd = Wait-Menu $gpid 1500
Assert ($menuWnd -eq [IntPtr]::Zero) 'E: right-click-action=paste shows no menu'
if ($menuWnd -ne [IntPtr]::Zero) { Cancel-Menu $pane; [void](Test-MenuGone $gpid 2000) }
Send-PaneRight -Top $g.Top -Pane $pane -Action up
# The clipboard read can transiently fail (CLIPBRD_E_CANT_OPEN contention
# right after another process wrote it) and the shell may still be settling
# this early in the run - retry the click a few times.
$pasted2 = $false
for ($try = 0; $try -lt 3 -and -not $pasted2; $try++) {
    if ($try -gt 0) {
        Send-PaneRight -Top $g.Top -Pane $pane -Action down
        Start-Sleep -Milliseconds 300
        Send-PaneRight -Top $g.Top -Pane $pane -Action up
    }
    for ($t = 0; $t -lt 12; $t++) {
        Start-Sleep -Milliseconds 250
        if ((Read-Pane $paneName) -match $sentinel2) { $pasted2 = $true; break }
    }
}
Assert $pasted2 'E: right-click-action=paste pastes the clipboard'

Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) 'run 3: no crash'
Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Run 4: section G - the accelerator label is read from the live keybind set,
# not hardcoded. A user bind added after the defaults wins the reverse map, so
# the row must relabel itself (and the banner must still be reachable).
# ---------------------------------------------------------------------------
$g = Start-Gui 'rebind' @('--keybind=ctrl+alt+k=prompt_surface_banner')
$launched += $g.Pid
$gpid = $g.Pid; $pane = $g.Pane

[void](Send-TestRawMessage -Window $pane -Message 0x007B -WParam $pane -LParam ([IntPtr](-1)))
$menuWnd = Wait-Menu $gpid 3000
Assert ($menuWnd -ne [IntPtr]::Zero) 'G: menu opens under the rebind config'
if ($menuWnd -ne [IntPtr]::Zero) {
    $parsed = @(Split-Items (Get-MenuItems $menuWnd))
    $accel = Accel-For $parsed 'Set Pane Banner...'
    Assert ($accel -eq 'Ctrl+Alt+K') "G: rebinding relabels the row (got '$accel')"
}
Cancel-Menu $pane
[void](Test-MenuGone $gpid 2000)

Assert (-not ($g.App.Process -and $g.App.Process.HasExited)) 'run 4: no crash'
Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue

} finally {
    Remove-TestDesktop
    Kill-RepoInstances
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    # Get-TestLaunchedPids, not the live list: this runs AFTER Remove-TestDesktop
    # has emptied that one, and comparing against an empty set is an assertion
    # that passes because it checked nothing.
    $launched = @(@($launched) + @(Get-TestLaunchedPids) | Select-Object -Unique)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
