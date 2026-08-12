# T190 acceptance: the Windows menu system - tab-strip button, HMENU host,
# dispatch, state, and keyboard activation.
#
# T189 landed the pure model (commands.zig + menu_bar.zig) and the single
# dispatch entry point; NONE of it was reachable. This script measures the
# reachable half, always by OUTCOME:
#
#   A: the menu HOST button exists and opens a menu - and it is a BUTTON, not
#      "anywhere in the strip": clicking the "+" opens a tab instead, and
#      clicking bare strip does nothing. Plus a pixel check that the glyph is
#      actually painted, with a blank strip region as its negative control.
#      Since T260 the host depends on the window: a window that draws its own
#      caption hosts the menu in the caption's "..." and its strip carries NO
#      second button (asserted here by hit test AND by pixels), while a
#      caption-less window still hosts it in the strip - which is section H.
#   B: the whole tree is there - walked RECURSIVELY, so a missing submenu
#      cannot hide behind a matching item count.
#   C: choosing a row performs its command, one representative per submenu,
#      asserted by outcome (File>New Tab grows +list; View>Terminal Read-only
#      comes back CHECKED; Window>Zoom Split hides a pane's window).
#   D: state gating is live (Copy, Close Tab, Zoom Split, the split submenus).
#   E: Exit says "(keep sessions)" only with session-persistence on (T89e).
#   F: a rebind relabels its row - the label comes from the LIVE keybind set.
#   G: keyboard activation - F10 and a lone Alt open the menu; alt+<key> does
#      not; and F10 is passed through to a full-screen TUI (alternate screen)
#      instead of opening the menu, then works again on the primary screen.
#   I: T191 - Window>Float on Top flips the window's live WS_EX_TOPMOST and the
#      row comes back CHECKED, then both revert. The action shipped with the
#      first win32 commit and had no surface whatsoever; this is the oracle for
#      the surface AND for the bit actually sticking.
#   H: T260 - a `window-decoration = none` window has no caption to host the
#      menu, so the strip keeps its "=" button there and it opens the same
#      menu. The positive control for A's "the strip has no button": without
#      it, a build that deleted the button outright would pass just as well.
#
# Menu contents are read from the LIVE popup via MN_GETHMENU + cross-process
# GetMenuItemInfo-family calls (never GetWindowTextW, which reads a cache the
# app never sees).
#
# T218: migrated onto the BACKGROUND test desktop (test/win32/lib/TestDesktop.ps1),
# so the run never takes the user's foreground - asserted here, not assumed.
# Everything except the A(pixels) probe was already PostMessage-driven, so the
# migration is about WHERE those calls run:
#
#   * Window enumeration is desktop-bound (EnumWindows walks the CALLING
#     thread's desktop), so FindTop/FindPane/MenuWindow/VisiblePanes now go
#     through the harness's worker thread. HMENU reads are NOT - a menu handle
#     is not a desktop object - so they stay in-process here.
#   * A(pixels) dropped GrabForeground + CopyFromScreen for PrintWindow
#     (Get-TestWindowPixels). The tab strip is GDI-painted chrome, which is the
#     half of the CAPTURE LIMIT that survives a window capture (measured in
#     T218 batch 2 by tab-strip/tab-color). That also retires the section's
#     "SKIP if the box will not hand over the foreground" branch: the probe now
#     always runs, and a capture with no real content in it is a FAIL rather
#     than a silently-skipped assertion.
#   * F10 and the lone-Alt press need WM_SYSKEYDOWN/UP as separate halves (the
#     contract is about the pairing), which is what Send-TestSysKey exists for.
#
# -NegativeControl inverts the A(pixels) button-ink expectation and MUST fail;
# it is how a run proves that probe reads ink rather than returning a constant.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
# Always isolated: every oracle below is an IPC probe (+list, +read,
# +send-keys) and must reach THIS run's app, not whatever else is on the box.
$env:GHOZTTY_PIPE_SUFFIX = '-menubartest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

# Non-ASCII menu text is built from code points: this file stays ASCII so no
# editor/shell in the chain can mojibake it (the standing PS5.1 trap).
$EL = [char]0x2026   # HORIZONTAL ELLIPSIS, as used by the "..." menu rows

Add-Type -AssemblyName System.Drawing

# HMENU reads only. A menu handle is not a desktop object, so these run in this
# process; every WINDOW lookup goes through the harness instead.
Add-Type @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;
public class MenuRead {
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuStringW(IntPtr menu, uint idItem, StringBuilder sb, int max, uint flags);
    [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr menu, uint id, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetSubMenu(IntPtr menu, int pos);

    // The whole tree, one line per row:
    //   "<path>/<label>[\t<accel>][:grayed][:checked]", submenus as "<label> >".
    //
    // GetSubMenu is checked BEFORE the MF_SEPARATOR bit on purpose: for a
    // popup row GetMenuState returns the submenu's ITEM COUNT in the high
    // byte, so any submenu with 8..15 items sets 0x800 and reads as a
    // separator. (That mis-read cost a debugging round on the first run.)
    public static string[] Tree(IntPtr menu) {
        var acc = new List<string>();
        if (menu != IntPtr.Zero) Walk(menu, "", acc);
        return acc.ToArray();
    }
    static void Walk(IntPtr menu, string prefix, List<string> acc) {
        int n = GetMenuItemCount(menu);
        for (uint i = 0; i < (uint)n; i++) {
            uint state = GetMenuState(menu, i, 0x400); // MF_BYPOSITION
            IntPtr sub = GetSubMenu(menu, (int)i);
            if (sub == IntPtr.Zero && (state & 0x800) != 0) { acc.Add(prefix + "---"); continue; }
            var sb = new StringBuilder(160);
            GetMenuStringW(menu, i, sb, 160, 0x400);
            string label = sb.ToString();
            if (sub != IntPtr.Zero) {
                acc.Add(prefix + label + " >");
                Walk(sub, prefix + label + "/", acc);
            } else {
                string flags = "";
                if ((state & 0x3) != 0) flags += ":grayed";  // MF_GRAYED|MF_DISABLED
                if ((state & 0x8) != 0) flags += ":checked"; // MF_CHECKED
                acc.Add(prefix + label + flags);
            }
        }
    }
}
'@

function Kill-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

function Start-Gui([string]$label, [string[]]$extraArgs) {
    Kill-RepoInstances
    # A stale debug layout manifest would restore a previous run's windows
    # over the one under test (the T131 lesson).
    Remove-Item "$env:LOCALAPPDATA\ghoztty\session-layout-debug.json" -Force -ErrorAction SilentlyContinue
    # A black background makes the strip's three surfaces unmistakable in a
    # capture - content-black chiclet, lifted inactive tab, bar-gray strip -
    # which is what Strip-Geometry measures the tab run against (T256). On a
    # light theme an inactive tab's 6% lift is ~1 level and unreadable.
    # --window-show-tab-bar=always because T234 made `auto` hide the strip at
    # one tab. This script is about the STRIP's menu button, which only exists
    # when the strip does; without the flag every section here would be
    # measuring a window that has no strip at all. The caption's "..." host
    # that replaced it as the default route is asserted in
    # tab-strip-autohide.ps1, not here.
    $argList = @(
        '--config-default-files=false',
        '--background=#000000',
        '--window-show-tab-bar=always'
    ) + $extraArgs
    $app = Start-OnTestDesktop -Exe $exe -Arguments $argList
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host "SETUP FAIL ($label): GUI died at launch"; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL ($label): top window not found"; exit 1 }
    # SIZE IT (T205/T267). Section A probes two places it needs to be EMPTY -
    # mid-strip and the strip's right end - and both are only empty if the tab
    # run is short relative to the strip. Since T205 the strip's half of the
    # merged row is `clientW - 175` at this DPI, so on the app's default ~800 px
    # window two tabs reach past mid-strip and the "+" is pushed to its limit:
    # both probes then measure real chrome and read 282 and 81 ink pixels
    # against a correct build. The script never set a size and had been
    # inheriting `window_placement-debug` from whatever ran before it (T267).
    Set-TestWindowSize -Window $top -Width 1400 -Height 800 | Out-Null
    Start-Sleep -Milliseconds 1200
    $pane = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($pane -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL ($label): pane not found"; exit 1 }

    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) `
        "$label window is NOT enumerable on the interactive desktop"
    if (-not (Focus-TestWindow -Window $top -Child $pane)) {
        Write-Host "SETUP FAIL ($label): could not focus the GUI"; Stop-Process -Id $app.Pid -Force; exit 1
    }
    [pscustomobject]@{ App = $app; Proc = $app.Process; Top = $top; Pane = $pane; Pid = [int]$app.Pid }
}

function List-Json { & $exe +list --json 2>$null | ConvertFrom-Json }

# `+read`'s exit code, with its stderr swallowed. A bare native command that
# writes to stderr is a TERMINATING error under $ErrorActionPreference=Stop
# (PS5.1 wraps each line in a NativeCommandError), and here a FAILING read is
# the measurement, not a fault.
function Read-Exit([string]$name) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & $exe +read --name=$name --lines=3 2>&1
        return $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
}

# Pane text, or '' when the read fails (same stderr caveat as Read-Exit).
function Read-Text([string]$name, [int]$lines = 20) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $exe +read --name=$name --lines=$lines 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { return '' }
        return $out
    } finally { $ErrorActionPreference = $old }
}
function Pane-Name {
    $j = List-Json
    $t = $j.data.windows[0].tabs[0].splits
    if ($t.type -eq 'leaf') { return $t.terminal.name }
    return $t.left.terminal.name
}

# The name of the pane that has KEYBOARD focus, in the selected tab. Sending
# a pane's shell one thing while typing at another is how the first run of
# section G lied to itself (the zoomed pane was not the one it had switched
# to the alternate screen).
function Walk-Focused($node) {
    if ($null -eq $node) { return $null }
    if ($node.type -eq 'leaf') {
        if ($node.terminal.focused) { return $node.terminal.name }
        return $null
    }
    $l = Walk-Focused $node.left
    if ($null -ne $l) { return $l }
    return Walk-Focused $node.right
}
function Focused-Pane-Name {
    $j = List-Json
    foreach ($tab in $j.data.windows[0].tabs) {
        if (-not $tab.selected) { continue }
        $n = Walk-Focused $tab.splits
        if ($null -ne $n) { return $n }
    }
    return (Pane-Name)
}
function Tab-Count { @((List-Json).data.windows[0].tabs).Count }

# How many terminal children are VISIBLE (the Zoom Split oracle: zooming HIDES
# the other panes).
function Visible-Panes([IntPtr]$top) {
    @(Get-TestChildWindows -Window $top -Class 'GhozttyTerminal' | Where-Object { $_.Visible }).Count
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

# The live popup's tree. MN_GETHMENU is SENT: the app's GUI thread is inside
# TrackPopupMenuEx's modal loop, which pumps messages, so a cross-process send
# is answered (and SMTO_ABORTIFHUNG does not trip on a pumping thread).
function Get-MenuTree([IntPtr]$menuWnd) {
    $r = Invoke-TestMessage -Window $menuWnd -Message 0x01E1
    if ($r -eq [long]::MinValue -or $r -eq 0) { return @() }
    return [MenuRead]::Tree([IntPtr]$r)
}

function Cancel-Menu([IntPtr]$w) {
    [void](Invoke-TestMessage -Window $w -Message 0x001F) # WM_CANCELMODE
}

# Post a key into the menu's modal loop: the loop retrieves queue messages
# regardless of target hwnd, and Send-TestControlKey posts without touching
# focus (Send-TestKeys would SetFocus first and dismiss the menu).
function Send-MenuKey([IntPtr]$w, [string]$key) {
    [void](Send-TestControlKey -Control $w -Key $key)
}

# Where the strip STARTS used to live here, as `Strip-Top`, and it moved three
# times in three tasks: client y = 0, then y = captionHeight when T254 pulled
# the caption band into the client area, then back to 0 when T205 merged the
# strip INTO that band. Each move cost this script a pile of assertions that
# were pointing at the caption (where a click drags the window or hits
# minimize/maximize/close) while the product was healthy.
#
# It is gone since T231: every point below comes from a rect the app published
# in CLIENT coordinates, so there is no strip-relative y left to offset and
# nothing here to move a fourth time. `Strip-Geometry(...).Band` is the strip's
# own band when a section needs one.

# Click a CLIENT point in the window. The strip is painted AND hit-tested by
# the top-level window, so that is where the click is posted (T216: name the
# window a real click would reach).
#
# CLIENT, not strip-relative, since T231: every point below now comes from a
# rect the app PUBLISHED in client coordinates, so converting it back into the
# strip's space just to add the strip's top again would reintroduce the one
# number T254 moved out from under this script.
function Click-Client([IntPtr]$top, [int]$x, [int]$y) {
    $cr = Get-TestWindowRect -Window $top -Client
    [void](Send-TestMouse -Window $top -Target $top -X ($cr.Left + $x) -Y ($cr.Top + $y) -Button left -Action click)
}

# Where the strip's regions ARE, in CLIENT coordinates - ASKED OF THE PRODUCT
# (T231), not re-derived here.
#
# The history is the argument. The section first clicked a hard-coded "46px
# left of the right edge" for the "+". That constant was written when a SINGLE
# tab stretched to fill the strip, which parked the "+" hard against the menu
# button; T202 stopped the stretch and the "+" now TRAVELS with the last tab,
# so with one tab it sits ~260px from the LEFT. It was doubly wrong at 125%
# DPI, where the scaled button group is wide enough that 46px from the right
# edge lands INSIDE the menu button - the "+" click opened the menu and no tab
# ever appeared.
#
# T256 replaced it with a re-implementation of `tab_strip_layout`'s tab SIZING,
# which broke the same way one rule change later: T235 made a tab's width its
# measured TITLE plus padding, so the modelled "equal share, capped at 200 DIP"
# width was ~250px against a real ~344px tab and the click landed back inside
# tab 1. T257 then measured the run off a capture instead, and kept a private
# copy of the "+"'s own rule - `min(tabsRight + group_gap, plus_limit)` - which
# is still a second implementation of a layout the product owns.
#
# T231 ended that: `+list --json` reports the strip's hit regions, which ARE
# the rects the app hit-tests. All this function does now is name the four
# points the sections below aim at. Nothing here models a width, an anchor or a
# travel rule, so there is nothing left to rot.
function Strip-Geometry([IntPtr]$top, [int]$tabCount = 1) {
    $m = Get-TestChromeMetrics -Window $top -StripVisible $true
    $r = Get-TestStripRegions -Window $top -Exe $exe
    if ($null -eq $r) { throw "Strip-Geometry: window $top reports no tab strip" }
    if ($null -eq $r.NewTab) { throw "Strip-Geometry: the strip reports no '+' (did it never paint?)" }

    # Where the strip's own half ENDS. On a merged row (T205) that is the seam,
    # not the window edge: right of it is the caption's half, and a point picked
    # there would be the close button rather than bare strip. Published, so this
    # is right on both window shapes with no branch.
    $stripRight = $r.Band.Right
    $deadRight = if ($null -ne $r.Menu) { $r.Menu.Left } else { $stripRight }

    [pscustomobject]@{
        Dpi = $r.Dpi; ClientW = $m.ClientW; BtnW = $m.BtnPaint; TabsRight = $r.TabsRight
        # The floor a tab shrinks to under pressure - the one width constant
        # T235 kept. Used only to size the reflow section's tab count.
        MinTabW = $m.MinTabW
        # The strip's content band, so a caller has the strip's y without
        # re-deriving where the strip starts (the datum T254 moved).
        Band = $r.Band
        # $null on a caption window - there is no strip menu button there
        # (T260); `Menu-Host` is what names the host that DOES exist.
        MenuX = if ($null -ne $r.Menu) { $r.Menu.CenterX } else { $null }
        PlusX = $r.NewTab.CenterX
        PlusY = $r.NewTab.CenterY
        # Strip that belongs to neither a tab, the "+", nor any button: halfway
        # between the "+"'s HIT box and the next thing right of it - the menu
        # button where there is one, else the strip's own right end. Hit boxes
        # on purpose: the claim is that a click there reaches nothing, and a hit
        # box is exactly what a click can reach.
        DeadX = [int](($r.NewTab.Right + $deadRight) / 2)
        # The center of the RIGHT-MOST square slot in the STRIP: where the "="
        # button is on a caption-less window (and where it used to be on every
        # window). On a caption window this is bare strip and must behave like
        # it - that is T260's user-visible claim - so there is no published rect
        # to ask for and the slot is placed against the published band's right
        # end with the shared 28 DIP square, which is a constant, not a layout.
        StripRightX = if ($null -ne $r.Menu) { $r.Menu.CenterX } else { $stripRight - [int]($m.BtnPaint / 2) }
        StripY = $r.Band.CenterY
    }
}

# WHERE this window's menu host button is, in CLIENT coordinates, and which
# one it is (T260).
#
# There is exactly one menu host per window and it depends on the window, not
# on the script's preference: a window that draws its own caption carries the
# "..." button up there, and the strip's "=" is not painted at all - two
# controls one band apart opening the same menu is the "undifferentiated
# cluster" complaint in a new place. A caption-less window (`window-decoration
# = none`) has no such button, and there the strip IS the host.
#
# Asking the metrics rather than the launch flags is deliberate: the app's own
# rule is `!customCaption()`, read off the window's style bits, so this cannot
# drift from it by the script believing something about how it launched.
function Menu-Host([IntPtr]$top) {
    $m = Get-TestChromeMetrics -Window $top -StripVisible $true
    if ($m.HasStripMenu) {
        return [pscustomobject]@{ Kind = 'strip'; X = $m.MenuX; Y = $m.StripTopClient + 8; M = $m }
    }
    return [pscustomobject]@{ Kind = 'caption'; X = $m.CaptionOverflowX; Y = [int]($m.CaptionH / 2); M = $m }
}

# Click this window's menu host, wherever it is, and return the hit-test code
# the app answered for that point (HTCLIENT for the strip, which is client area
# like any other control).
#
# The two hosts take DIFFERENT message paths, and since T263 that is the
# HARNESS's business rather than this script's: the caption band is client
# pixels the window claims back through WM_NCHITTEST, so Windows delivers
# WM_NCLBUTTONDOWN there, and Send-TestMouse now asks the same question and
# delivers the same pair. This used to hand-roll that (a WM_NCHITTEST probe
# plus a posted WM_NCLBUTTONDOWN) because a plain posted client click reached
# nothing at all - measured in T260, where every menu-open assertion failed
# while F10 still passed.
#
# DOWN only, no release: the "..." opens a TrackPopupMenu that blocks the GUI
# thread inside the down handler, so a matching up would be retrieved by the
# menu's own modal loop rather than by the button. Close-Menu ends it.
function Click-MenuHost([IntPtr]$top) {
    $h = Menu-Host $top
    $cr = Get-TestWindowRect -Window $top -Client
    $sx = $cr.Left + $h.X
    $sy = $cr.Top + $h.Y
    if ($h.Kind -eq 'strip') {
        [void](Send-TestMouse -Window $top -Target $top -X $sx -Y $sy -Button left -Action click)
        return 1
    }
    # The code is READ from the app, not assumed, so a "..." that stopped
    # answering HTSYSMENU reads as a moved button rather than as a menu that
    # did not open.
    $code = (Get-TestMouseRoute -Window $top -X $sx -Y $sy).Code
    [void](Send-TestMouse -Window $top -Target $top -X $sx -Y $sy -Button left -Action down)
    return $code
}

# Open the menu from this window's menu host button and return the live tree.
function Open-Menu($g, [int]$waitMs = 3000) {
    [void](Click-MenuHost $g.Top)
    $m = Wait-Menu $g.Pid $waitMs
    if ($m -eq [IntPtr]::Zero) { return $null }
    Get-MenuTree $m
}

function Close-Menu($g) {
    Send-MenuKey $g.Top 'Escape'
    if (-not (Test-MenuGone $g.Pid 1500)) {
        Cancel-Menu $g.Top
        [void](Test-MenuGone $g.Pid 2000)
    }
}

# "path/Label<tab>Accel:flags" -> its parts.
function Split-Row([string]$s) {
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
    [pscustomobject]@{ Path = $s; Accel = $accel; Flags = $flags }
}
function Rows($tree) { @($tree | ForEach-Object { Split-Row $_ }) }
function Row($tree, [string]$path) {
    $r = @(Rows $tree | Where-Object { $_.Path -eq $path })
    if ($r.Count -eq 0) { return $null }
    $r[0]
}
function Row-Flags($tree, [string]$path) {
    $r = Row $tree $path
    if ($null -eq $r) { return '<missing>' }
    $r.Flags
}

# The tree the model says exists (menu_bar.zig `root`), as paths in order.
$expectedTree = @(
    '&File >'
    "&File/&New Window"
    "&File/New &Remote Window"
    "&File/New &Tab"
    '&File/---'
    "&File/Split R&ight"
    "&File/Split &Left"
    "&File/Split &Down"
    "&File/Split &Up"
    '&File/---'
    "&File/&Close Pane"
    "&File/Close Ta&b"
    "&File/Close &Window"
    "&File/Close &All Windows"
    '&File/---'
    "&File/E&xit"
    '&Edit >'
    "&Edit/&Copy"
    "&Edit/&Paste"
    "&Edit/Select &All"
    '&Edit/---'
    "&Edit/&Find$EL"
    "&Edit/Find &Next"
    "&Edit/Find Pre&vious"
    "&Edit/&Hide Find Bar"
    '&Edit/---'
    "&Edit/&Use Selection for Find"
    "&Edit/&Jump to Selection"
    '&View >'
    "&View/&Reset Font Size"
    "&View/&Increase Font Size"
    "&View/&Decrease Font Size"
    '&View/---'
    "&View/Command &Palette"
    '&View/---'
    "&View/Change &Window Title$EL"
    "&View/Change &Tab Title$EL"
    "&View/Change Pan&e Title$EL"
    "&View/Set Pane &Banner$EL"
    '&View/---'
    "&View/Terminal Read-&only"
    '&View/---'
    "&View/&Quick Terminal"
    '&Window >'
    "&Window/Toggle &Full Screen"
    "&Window/Ma&ximize"
    "&Window/Show/&Hide All Terminals"
    '&Window/---'
    "&Window/&Zoom Split"
    "&Window/Toggle Hero &Mode"
    "&Window/Select &Previous Split"
    "&Window/Select &Next Split"
    '&Window/&Select Split >'
    "&Window/&Select Split/Select Split &Above"
    "&Window/&Select Split/Select Split &Below"
    "&Window/&Select Split/Select Split &Left"
    "&Window/&Select Split/Select Split &Right"
    '&Window/S&wap Split >'
    "&Window/S&wap Split/Swap Split &Up"
    "&Window/S&wap Split/Swap Split &Down"
    "&Window/S&wap Split/Swap Split &Left"
    "&Window/S&wap Split/Swap Split &Right"
    '&Window/&Resize Split >'
    "&Window/&Resize Split/&Equalize Splits"
    '&Window/&Resize Split/---'
    "&Window/&Resize Split/Move Divider &Up"
    "&Window/&Resize Split/Move Divider &Down"
    "&Window/&Resize Split/Move Divider &Left"
    "&Window/&Resize Split/Move Divider &Right"
    '&Window/---'
    "&Window/Previous &Tab"
    "&Window/Next Ta&b"
    "&Window/&Last Tab"
    '&Window/---'
    "&Window/Return To &Default Size"
    "&Window/Fl&oat on Top"
    '&Help >'
    "&Help/Ghoztty &Help"
    '&Help/---'
    "&Help/Check for &Updates$EL"
    "&Help/Install &Claude Code Integration"
    '&Help/---'
    "&Help/&About Ghoztty"
    '---'
    "&Settings"
    "&Reload Configuration"
)

if ($NegativeControl) {
    Write-Host 'NEGATIVE CONTROL: A(pixels) asserts the menu button paints NOTHING - this run MUST fail'
}

Kill-RepoInstances

# Watch the user's desktop for the whole run: nothing we launch may ever take
# foreground there. That is the complaint the test desktop exists to fix.
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {

# ===========================================================================
# Run 1: sections A, B, C, D, G (session-persistence off).
# ===========================================================================
$g = Start-Gui 'main' @('--session-persistence=false')

# --- A: the button ---------------------------------------------------------
$host0 = Menu-Host $g.Top
Write-Host "      A: menu host is the $($host0.Kind) button at client x=$($host0.X)"
# The app's OWN hit test, at the point the metrics say the "..." is: HTSYSMENU
# (3). Asserted before the click so a miss reads as "the button is not where
# the layout module puts it" rather than as "the menu did not open".
$hostCode = Click-MenuHost $g.Top
Assert ($hostCode -eq 3) "A: the caption menu button hit-tests as HTSYSMENU (got $hostCode)"
$m = Wait-Menu $g.Pid 3000
$tree = if ($m -eq [IntPtr]::Zero) { $null } else { Get-MenuTree $m }
Assert ($null -ne $tree) "A: clicking the $($host0.Kind) menu button opens the menu"
Close-Menu $g

# T260: this window draws its own caption, so the caption's "..." IS the host
# and the strip must NOT carry a second button doing the same thing. Clicking
# the right-most square slot of the strip - where the "=" used to be, and still
# is on a caption-less window (section H) - has to do nothing at all.
Assert ($host0.Kind -eq 'caption') 'A: a normal window hosts the menu in its caption, not in the strip'
$tabsAtStripRight = Tab-Count
$geoRight = Strip-Geometry $g.Top
Click-Client $g.Top $geoRight.StripRightX $geoRight.StripY
$m = Wait-Menu $g.Pid 1200
Assert ($m -eq [IntPtr]::Zero) 'A(T260): the strip has no menu button on a caption window'
if ($m -ne [IntPtr]::Zero) { Close-Menu $g }
Assert ((Tab-Count) -eq $tabsAtStripRight) 'A(T260): ...and clicking there opens no tab either'

# It is a button, not "the strip": the bare strip between the "+" and the
# strip's right end is dead space, and the "+" is its own hit box.
$tabsBefore = Tab-Count
$geo = Strip-Geometry $g.Top $tabsBefore
Write-Host "      A: dpi=$($geo.Dpi) client=$($geo.ClientW) -> plus@$($geo.PlusX) dead@$($geo.DeadX) stripRight@$($geo.StripRightX) tabsRight@$($geo.TabsRight)"
Click-Client $g.Top $geo.DeadX $geo.StripY
$m = Wait-Menu $g.Pid 1200
Assert ($m -eq [IntPtr]::Zero) 'A: clicking bare strip does NOT open the menu'
if ($m -ne [IntPtr]::Zero) { Close-Menu $g }
Assert ((Tab-Count) -eq $tabsBefore) 'A: ...and does not open a tab either (it is dead space)'

Click-Client $g.Top $geo.PlusX $geo.PlusY
Start-Sleep -Milliseconds 900
$m = Wait-Menu $g.Pid 300
Assert ($m -eq [IntPtr]::Zero) 'A: the "+" button did not open the menu'
if ($m -ne [IntPtr]::Zero) { Close-Menu $g }
$tabsAfterPlus = Tab-Count
Assert ($tabsAfterPlus -eq $tabsBefore + 1) "A: the rect after the last tab is the + (tabs $tabsBefore -> $tabsAfterPlus)"

# --- A(pixels): the glyph is painted --------------------------------------
# Everything else here is hit-testing; this is the only assertion that the
# button is VISIBLE. PrintWindow, not a screen grab: the strip is GDI-painted
# chrome, so it survives a window capture on the background desktop.
$shot = Get-TestWindowPixels -Window $g.Top
try {
    # A capture with nothing in it satisfies "no ink" for entirely the wrong
    # reason, so real content is a precondition, not an assumption (T216).
    $colors = Get-TestDistinctColors -Shot $shot
    Assert ($colors -ge 8) "A: the window capture holds real content ($colors distinct colors)"

    $cr = Get-TestWindowRect -Window $g.Top -Client
    # Re-read, not `$geo`: the "+" click above opened a tab, so the run is
    # longer and the "+" and the dead space right of it have both moved.
    #
    # `Band` is the strip's published content band (T231); its top is where
    # every strip button's square starts, which is the datum T254 moved out
    # from under the private `caption_h` this block used to add.
    $geoInk = Strip-Geometry $g.Top
    $band = $geoInk.Band
    # Ink = pixels far from the rect's own most-common color (the band
    # background), measured in SCREEN coordinates against the capture.
    # `$yTop` is a SCREEN y, because since T260 the two things this probes -
    # the caption's "..." and the strip's right end - are in different bands.
    function Ink([int]$xClient, [int]$yTop, [int]$w, [int]$h) {
        $counts = @{}
        $px = New-Object 'System.Drawing.Color[,]' $w, $h
        for ($yy = 0; $yy -lt $h; $yy++) { for ($xx = 0; $xx -lt $w; $xx++) {
            $c = Get-TestPixel -Shot $shot -X ($cr.Left + $xClient + $xx) -Y ($yTop + $yy)
            if ($null -eq $c) { $c = [System.Drawing.Color]::Transparent }
            $px[$xx, $yy] = $c
            $k = $c.ToArgb()
            if ($counts.ContainsKey($k)) { $counts[$k]++ } else { $counts[$k] = 1 }
        } }
        $modal = ($counts.GetEnumerator() | Sort-Object -Property Value -Descending)[0]
        $base = [System.Drawing.Color]::FromArgb($modal.Key)
        $ink = 0
        for ($yy = 0; $yy -lt $h; $yy++) { for ($xx = 0; $xx -lt $w; $xx++) {
            $p = $px[$xx, $yy]
            if ([Math]::Abs($p.R - $base.R) -gt 24 -or [Math]::Abs($p.G - $base.G) -gt 24 -or [Math]::Abs($p.B - $base.B) -gt 24) { $ink++ }
        } }
        $ink
    }
    # The HOST's square, wherever it is: the caption's "..." on this window.
    # Both probes are the same 34x26 box around a 28 DIP square, just in
    # different bands.
    $hm = $host0.M
    # The painted squares, from the metrics rather than from a 34x26 box that
    # happened to overlap one at this DPI: a caption button paints at
    # `pad_sm` below the band top, a strip button at `tab_top_pad + pad_sm`
    # below the strip top, and both are `btn_paint` on a side.
    # T205: `CaptionBtnTop`, not `PadSm` - on a merged row the caption buttons
    # drop onto the STRIP's button baseline (tab_top_pad + pad_sm) so they share
    # one frame with the "+" and the tab close "x".
    $probeW = $hm.BtnPaint + 4
    $capY = $cr.Top + $hm.CaptionBtnTop
    # A strip button's painted square starts `pad_sm` below the content band's
    # own top (the band IS the buttons' band - see tab_strip_layout.buttonHit).
    $stripY = $cr.Top + $band.Top + $hm.PadSm
    # The strip's own right-most square. T205: on a merged row the strip ends at
    # the seam, and `clientW - PadR - BtnPaint` is the caption's CLOSE button - which
    # does paint a glyph, so the "no menu glyph here" probe below would have
    # failed against a correct build. The published band's right edge is that
    # end on both window shapes, so there is no branch to get wrong.
    $stripRightL = $band.Right - $hm.BtnPaint
    $hostInk = if ($host0.Kind -eq 'caption') {
        Ink ($hm.CaptionOverflowLeft - 2) $capY $probeW $hm.BtnPaint
    } else {
        Ink ($stripRightL - 2) $stripY $probeW $hm.BtnPaint
    }
    # The "does this probe measure ink at all?" control, in a square that is
    # blank BY CONSTRUCTION rather than by luck: `DeadX` is the midpoint between
    # the "+"'s PUBLISHED hit box and the next thing right of it (T231). It used
    # to be `clientW / 2`, and that stopped being blank when T205 shortened the
    # strip's half of the row - mid-strip landed inside a tab's title and read
    # 63-282 ink pixels against a correct build.
    $blankInk = Ink ($geoInk.DeadX - [int]($probeW / 2)) $stripY $probeW $hm.BtnPaint
    # T260's pixel half: the strip's right-most square is BARE. The hit test
    # above says nothing lands there; this says nothing is drawn there either,
    # which is the part the user actually complained about seeing twice.
    $stripRightInk = Ink ($stripRightL - 2) $stripY $probeW $hm.BtnPaint
    if ($NegativeControl) {
        Assert ($hostInk -le 2) "A(neg): the menu button paints NO glyph ($hostInk ink pixels)"
    } else {
        Assert ($hostInk -gt 8) "A: the $($host0.Kind) menu button paints a glyph ($hostInk ink pixels)"
    }
    Assert ($blankInk -le 2) "A: blank strip control has no ink ($blankInk pixels) - the probe measures ink"
    Assert ($stripRightInk -le 2) "A(T260): the strip's right end paints no menu glyph ($stripRightInk ink pixels)"
} finally {
    Close-TestWindowPixels $shot
}

# --- B: the whole tree -----------------------------------------------------
$tree = Open-Menu $g
Assert ($null -ne $tree) 'B: menu opens for the tree walk'
if ($null -ne $tree) {
    $paths = @(Rows $tree | ForEach-Object { $_.Path })
    Assert ($paths.Count -eq $expectedTree.Count) "B: tree has $($expectedTree.Count) rows (got $($paths.Count))"
    $bad = @()
    for ($i = 0; $i -lt [Math]::Min($paths.Count, $expectedTree.Count); $i++) {
        if ($paths[$i] -ne $expectedTree[$i]) { $bad += "row $i got '$($paths[$i])' want '$($expectedTree[$i])'" }
    }
    Assert ($bad.Count -eq 0) 'B: every submenu, row and separator matches the model, in order'
    if ($bad.Count) { $bad | Select-Object -Last 12 | ForEach-Object { Write-Host "      $_" } }

    # Accelerators come from the live keybind set, menu-wide.
    $withAccel = @(Rows $tree | Where-Object { $_.Accel -ne '' })
    Assert ($withAccel.Count -ge 10) "B: bound rows carry their chord ($($withAccel.Count) labeled rows)"
    $newTab = Row $tree "&File/New &Tab"
    Assert ($null -ne $newTab -and $newTab.Accel -eq 'Ctrl+T') "B: File>New Tab is labeled Ctrl+T (got '$($newTab.Accel)')"
    # A command with no binding behind it must show a bare label, never the
    # placeholder action's chord.
    $remote = Row $tree "&File/New &Remote Window"
    Assert ($null -ne $remote -and $remote.Accel -eq '') "B: New Remote Window (no binding) shows no chord (got '$($remote.Accel)')"
    $about = Row $tree "&Help/&About Ghoztty"
    Assert ($null -ne $about -and $about.Accel -eq '') "B: About (no binding) shows no chord (got '$($about.Accel)')"
}

# --- D: state gating, single pane / two tabs -------------------------------
if ($null -ne $tree) {
    Assert ((Row-Flags $tree "&Edit/&Copy") -eq ':grayed') 'D: Copy is grayed with no selection'
    Assert ((Row-Flags $tree "&Window/&Zoom Split") -eq ':grayed') 'D: Zoom Split is grayed in a single-pane tab'
    Assert ((Row-Flags $tree "&Window/&Select Split/Select Split &Left") -eq ':grayed') 'D: Select Split rows are grayed in a single-pane tab'
    Assert ((Row-Flags $tree "&Window/&Resize Split/Move Divider &Up") -eq ':grayed') 'D: Move Divider rows are grayed in a single-pane tab'
    # Run 1 opened a second tab in section A, so the tab rows are live.
    Assert ((Row-Flags $tree "&File/Close Ta&b") -eq '') 'D: Close Tab is enabled with two tabs'
    Assert ((Row-Flags $tree "&Window/Previous &Tab") -eq '') 'D: tab cycling is enabled with two tabs'
    # E(off): the Exit row only advertises session keeping when it is on.
    Assert ($null -ne (Row $tree "&File/E&xit")) 'E: Exit reads plain "E&xit" with session-persistence off'
}
Close-Menu $g

# --- C: Edit>Select All dispatches, and Copy then enables ------------------
[void](Click-MenuHost $g.Top)
$m = Wait-Menu $g.Pid 3000
Assert ($m -ne [IntPtr]::Zero) 'C: menu opens for the Select All dispatch'
Send-MenuKey $g.Top 'E'  # Edit submenu
Start-Sleep -Milliseconds 300
Send-MenuKey $g.Top 'A'  # Select All
Assert (Test-MenuGone $g.Pid 2500) 'C: choosing Select All closes the menu'
Start-Sleep -Milliseconds 600
$tree = Open-Menu $g
Assert ($null -ne $tree -and (Row-Flags $tree "&Edit/&Copy") -eq '') 'C/D: Copy is enabled after menu>Edit>Select All (dispatch AND live state)'
Close-Menu $g

# --- C: File>New Tab dispatches -------------------------------------------
$before = Tab-Count
[void](Click-MenuHost $g.Top)
$m = Wait-Menu $g.Pid 3000
Assert ($m -ne [IntPtr]::Zero) 'C: menu opens for the New Tab dispatch'
Send-MenuKey $g.Top 'F'  # File submenu
Start-Sleep -Milliseconds 300
Send-MenuKey $g.Top 'T'  # New Tab
Assert (Test-MenuGone $g.Pid 2500) 'C: choosing New Tab closes the menu'
$grew = $false
for ($t = 0; $t -lt 20; $t++) { Start-Sleep -Milliseconds 250; if ((Tab-Count) -gt $before) { $grew = $true; break } }
Assert $grew "C: File>New Tab opened a tab ($before -> $(Tab-Count))"

# --- C: View>Terminal Read-only round-trips through the check state --------
[void](Click-MenuHost $g.Top)
$m = Wait-Menu $g.Pid 3000
Assert ($m -ne [IntPtr]::Zero) 'C: menu opens for the read-only toggle'
Send-MenuKey $g.Top 'V'  # View
Start-Sleep -Milliseconds 300
Send-MenuKey $g.Top 'O'  # Terminal Read-only
[void](Test-MenuGone $g.Pid 2500)
Start-Sleep -Milliseconds 500
$tree = Open-Menu $g
Assert ($null -ne $tree -and (Row-Flags $tree "&View/Terminal Read-&only") -eq ':checked') 'C: View>Terminal Read-only performs and comes back CHECKED'
Close-Menu $g
# ...and off again, so the rest of the run types normally.
[void](Click-MenuHost $g.Top)
[void](Wait-Menu $g.Pid 3000)
Send-MenuKey $g.Top 'V'
Start-Sleep -Milliseconds 300
Send-MenuKey $g.Top 'O'
[void](Test-MenuGone $g.Pid 2500)
Start-Sleep -Milliseconds 400
$tree = Open-Menu $g
Assert ($null -ne $tree -and (Row-Flags $tree "&View/Terminal Read-&only") -eq '') 'C: a second choice clears the check'
Close-Menu $g

# --- I: Window>Float on Top (T191) -----------------------------------------
# The row is the whole point of T191 - the ACTION existed from the first win32
# commit and had no surface at all. So this asserts both halves by outcome: the
# window's live WS_EX_TOPMOST (read off the window, never a mirrored flag) and
# the checkmark the next menu open reports.
function Test-WindowTopmost([IntPtr]$h) {
    return ((Get-TestWindowStyle -Window $h -ExStyle) -band 0x8) -ne 0
}
$tree = Open-Menu $g
Assert ($null -ne $tree -and (Row-Flags $tree "&Window/Fl&oat on Top") -eq '') `
    'I: Float on Top is enabled and UNCHECKED on a plain window'
Close-Menu $g
Assert (-not (Test-WindowTopmost $g.Top)) 'I: the window does not start out topmost'

[void](Click-MenuHost $g.Top)
[void](Wait-Menu $g.Pid 3000)
Send-MenuKey $g.Top 'W'  # Window
Start-Sleep -Milliseconds 300
Send-MenuKey $g.Top 'O'  # Float on Top
[void](Test-MenuGone $g.Pid 2500)
$floated = $false
for ($t = 0; $t -lt 20; $t++) {
    Start-Sleep -Milliseconds 250
    if (Test-WindowTopmost $g.Top) { $floated = $true; break }
}
Assert $floated 'I: Window>Float on Top put WS_EX_TOPMOST on the window'
$tree = Open-Menu $g
Assert ($null -ne $tree -and (Row-Flags $tree "&Window/Fl&oat on Top") -eq ':checked') `
    'I: the row comes back CHECKED, from the live ex-style'
Close-Menu $g
# The bit must still be there after all of that menu traffic - a float that
# only holds until the next window message is not a float (T277).
Assert (Test-WindowTopmost $g.Top) 'I: the window is STILL topmost after reopening the menu'

# ...and off again, so the rest of the run is not fighting a topmost window.
[void](Click-MenuHost $g.Top)
[void](Wait-Menu $g.Pid 3000)
Send-MenuKey $g.Top 'W'
Start-Sleep -Milliseconds 300
Send-MenuKey $g.Top 'O'
[void](Test-MenuGone $g.Pid 2500)
$unfloated = $false
for ($t = 0; $t -lt 20; $t++) {
    Start-Sleep -Milliseconds 250
    if (-not (Test-WindowTopmost $g.Top)) { $unfloated = $true; break }
}
Assert $unfloated 'I: a second choice clears WS_EX_TOPMOST again'
$tree = Open-Menu $g
Assert ($null -ne $tree -and (Row-Flags $tree "&Window/Fl&oat on Top") -eq '') `
    'I: and the checkmark goes with it'
Close-Menu $g

# --- C/D: Window>Zoom Split, with a real split ----------------------------
$paneName = Pane-Name
& $exe +split --target=$paneName --direction=right 2>&1 | Out-Null
Start-Sleep -Seconds 2
$panesBefore = Visible-Panes $g.Top
Assert ($panesBefore -ge 2) "C: the tab has two panes to zoom (visible=$panesBefore)"
$tree = Open-Menu $g
Assert ($null -ne $tree -and (Row-Flags $tree "&Window/&Zoom Split") -eq '') 'D: Zoom Split is ENABLED once the tab has two panes'
Close-Menu $g
[void](Click-MenuHost $g.Top)
[void](Wait-Menu $g.Pid 3000)
Send-MenuKey $g.Top 'W'  # Window
Start-Sleep -Milliseconds 300
Send-MenuKey $g.Top 'Z'  # Zoom Split
Assert (Test-MenuGone $g.Pid 2500) 'C: choosing Zoom Split closes the menu'
$zoomed = $false
for ($t = 0; $t -lt 20; $t++) {
    Start-Sleep -Milliseconds 250
    if ((Visible-Panes $g.Top) -lt $panesBefore) { $zoomed = $true; break }
}
Assert $zoomed "C: Window>Zoom Split hid the other pane ($panesBefore -> $(Visible-Panes $g.Top) visible)"

# --- G: keyboard activation ------------------------------------------------
# Re-resolve the surface: every tab open, split and zoom makes a NEW
# GhozttyTerminal child, and a key posted at a stale HWND is silently dropped
# (the T218 batch-1 lesson).
$pane = Get-TestChildWindow -Window $g.Top -Class 'GhozttyTerminal'
[void](Send-TestSysKey -Window $pane -Key F10 -Action down)
[void](Send-TestSysKey -Window $pane -Key F10 -Action up)
$m = Wait-Menu $g.Pid 3000
Assert ($m -ne [IntPtr]::Zero) 'G: F10 opens the menu'
Close-Menu $g

[void](Send-TestSysKey -Window $pane -Key alt -Action down)
Start-Sleep -Milliseconds 150
[void](Send-TestSysKey -Window $pane -Key alt -Action up)   # ...with nothing between
$m = Wait-Menu $g.Pid 3000
Assert ($m -ne [IntPtr]::Zero) 'G: a lone Alt press opens the menu'
Close-Menu $g

[void](Send-TestSysKey -Window $pane -Key alt -Action down)
Start-Sleep -Milliseconds 100
# A non-printing key: a letter here would be typed at the shell prompt and
# would then swallow the next command the script sends (which is exactly how
# the alternate-screen check below silently skipped on its first run).
Send-MenuKey $pane 'Left'   # VK_LEFT while Alt is down
Start-Sleep -Milliseconds 100
[void](Send-TestSysKey -Window $pane -Key alt -Action up)
$m = Wait-Menu $g.Pid 1500
Assert ($m -eq [IntPtr]::Zero) 'G: alt+<key> does NOT open the menu (alt stays a modifier)'
if ($m -ne [IntPtr]::Zero) { Close-Menu $g }

# F10 belongs to a full-screen TUI. Those run on the ALTERNATE screen, so
# that is the discriminator: switch the pane to it and F10 must pass through.
# It has to be the FOCUSED pane - that is the one F10 is delivered to.
$paneName = Focused-Pane-Name
# Clear whatever the earlier key probes left on the prompt line before
# typing a command that has to actually run.
& $exe +send-keys --target=$paneName C-c 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
# The child switches BOTH ways itself and prints a marker on its way out.
# Do not use ^C plus "+read works again" as the return oracle: a killed child
# does not necessarily leave the alternate screen, and +read's failure means
# "nothing to read", which is not the same question.
$marker = 'MENUBAR_PRIMARY_OK_41'
$inner = '[Console]::Write((-join @([char]27,"[?1049h"))); Start-Sleep 12; ' +
         '[Console]::Write((-join @([char]27,"[?1049l"))); Write-Host "' + $marker + '"'
$b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
& $exe +send-keys --target=$paneName "powershell -NoProfile -EncodedCommand $b64" Enter 2>&1 | Out-Null
# T193 (2026-08-06) changed what this measurement looks like: +read on an
# alternate-screen pane now SUCCEEDS and returns the visible screen, so "the
# read fails" - what this loop used to poll for - stopped being reachable and
# section G went red on a stale oracle rather than on a defect. The switch is
# still trivially observable, just from the other side: the alternate screen
# starts EMPTY, so the pane that was echoing a prompt and a typed command line
# reads back blank the moment it lands there.
$onAlt = $false
for ($t = 0; $t -lt 20; $t++) {
    Start-Sleep -Milliseconds 400
    if ((Read-Exit $paneName) -ne 0) { continue }
    if ((Read-Text $paneName 40).Trim().Length -eq 0) { $onAlt = $true; break }
}
Assert $onAlt 'G: the pane switched to the alternate screen (setup for the F10 pass-through)'
if ($onAlt) {
    $pane = Get-TestChildWindow -Window $g.Top -Class 'GhozttyTerminal'
    [void](Send-TestSysKey -Window $pane -Key F10 -Action down)
    [void](Send-TestSysKey -Window $pane -Key F10 -Action up)
    $m = Wait-Menu $g.Pid 2000
    Assert ($m -eq [IntPtr]::Zero) 'G: F10 is passed through on the alternate screen (no menu)'
    if ($m -ne [IntPtr]::Zero) { Close-Menu $g }

    # The marker is printed AFTER the child switches back, so seeing it in
    # the pane is positive proof the primary screen is live again.
    $backOnPrimary = $false
    for ($t = 0; $t -lt 40; $t++) {
        Start-Sleep -Milliseconds 500
        if ((Read-Text $paneName 20) -match $marker) { $backOnPrimary = $true; break }
    }
    Assert $backOnPrimary 'G: the pane is back on the primary screen (its own marker is visible)'
    if ($backOnPrimary) {
        [void](Send-TestSysKey -Window $pane -Key F10 -Action down)
        [void](Send-TestSysKey -Window $pane -Key F10 -Action up)
        $m = Wait-Menu $g.Pid 3000
        Assert ($m -ne [IntPtr]::Zero) 'G: F10 opens the menu again on the primary screen (it is the screen, not a dead key)'
        Close-Menu $g
    }
}

# --- A(reflow): the button survives the strip filling up ------------------
# Tabs stop shrinking at their minimum width (60pt), so past a point they
# overrun the strip and anything drawn AFTER the last tab lands off-screen -
# which used to cost only the "+" and would now cost the whole menu. The
# count is computed from this window, not guessed: at 96 DPI and a 1810px
# client, 21 tabs still fit and would have proved nothing.
# Last in the run, because it leaves the window full of tabs.
$geo = Strip-Geometry $g.Top (Tab-Count)
$needTabs = [int][Math]::Floor(($geo.ClientW - 2 * $geo.BtnW) / $geo.MinTabW) + 4
Write-Host "      A(reflow): client=$($geo.ClientW) dpi=$($geo.Dpi) -> opening $needTabs tabs (min tab $($geo.MinTabW)px)"
$have = Tab-Count
while ((Tab-Count) -lt $needTabs -and $have -lt $needTabs + 8) {
    # The "+" travels as tabs are added, so its rect is re-read every click
    # rather than assumed to sit next to the menu button.
    $gp = Strip-Geometry $g.Top (Tab-Count)
    Click-Client $g.Top $gp.PlusX $gp.PlusY
    $have++
    Start-Sleep -Milliseconds 250
}
$manyTabs = Tab-Count
Assert ($manyTabs -ge $needTabs) "A: opened $manyTabs tabs, past the $needTabs that overrun the strip"
$tree = Open-Menu $g 4000
Assert ($null -ne $tree) 'A: the menu button is still reachable with the strip overrun by tabs'
if ($null -ne $tree) { Close-Menu $g }

Assert (-not ($g.Proc -and $g.Proc.HasExited)) 'run 1: no crash'
Stop-Process -Id $g.Pid -Force -ErrorAction SilentlyContinue

# ===========================================================================
# Run 1b: section H - the strip KEEPS its button where nothing else hosts the
# menu. T260's other half, and the reason the button is conditional rather
# than deleted: `window-decoration = none` has no caption, so the strip is the
# only host there. Its own window because the property is per-window - and
# because an assertion that only ever ran on caption windows would pass just
# as well against a build that deleted the button outright.
# ===========================================================================
$g = Start-Gui 'no-decoration' @('--session-persistence=false', '--window-decoration=none')
$hostN = Menu-Host $g.Top
Assert ($hostN.Kind -eq 'strip') 'H: a caption-less window hosts the menu in the strip'
Assert ((Get-TestChromeMetrics -Window $g.Top -StripVisible $true).CaptionH -eq 0) 'H: ...because it has no caption band at all'
$tree = Open-Menu $g 4000
Assert ($null -ne $tree) 'H: the strip menu button opens the menu there'
if ($null -ne $tree) {
    Assert ((@(Rows $tree | ForEach-Object { $_.Path })).Count -eq $expectedTree.Count) `
        'H: ...and it is the same menu, not a stub'
    Close-Menu $g
}
Assert (-not ($g.Proc -and $g.Proc.HasExited)) 'run 1b: no crash'
Stop-Process -Id $g.Pid -Force -ErrorAction SilentlyContinue

# ===========================================================================
# Run 2: section E - Exit advertises session keeping when persistence is on.
# ===========================================================================
$g = Start-Gui 'persistence-on' @('--session-persistence=true')
$tree = Open-Menu $g
Assert ($null -ne $tree) 'E: menu opens with session-persistence on'
if ($null -ne $tree) {
    $plain = Row $tree "&File/E&xit"
    $keep = Row $tree "&File/E&xit (keep sessions)"
    Assert ($null -ne $keep) 'E: Exit reads "E&xit (keep sessions)" with session-persistence on'
    Assert ($null -eq $plain) 'E: ...and the plain Exit row is gone (one row, relabeled)'
}
Close-Menu $g
Assert (-not ($g.Proc -and $g.Proc.HasExited)) 'run 2: no crash'
# Close via the window so the agent ENDS this run's session (T89e close intent)
# instead of leaving it to re-attach into a later test.
Cancel-Menu $g.Top
Stop-Process -Id $g.Pid -Force -ErrorAction SilentlyContinue

# ===========================================================================
# Run 3: section F - a rebind relabels its row.
# ===========================================================================
$g = Start-Gui 'rebind' @('--session-persistence=false', '--keybind=ctrl+alt+k=prompt_surface_banner')
$tree = Open-Menu $g
Assert ($null -ne $tree) 'F: menu opens under the rebind config'
if ($null -ne $tree) {
    $banner = Row $tree "&View/Set Pane &Banner$EL"
    Assert ($null -ne $banner -and $banner.Accel -eq 'Ctrl+Alt+K') "F: rebinding relabels the row (got '$($banner.Accel)')"
}
Close-Menu $g
Assert (-not ($g.Proc -and $g.Proc.HasExited)) 'run 3: no crash'

# --- C: File>Close Window, the row that destroys the window that owns the
# menu. `Window.close()` calls DestroyWindow synchronously and `onDestroy`
# frees the Window allocation, so anything the host touches after dispatch is
# a use-after-free. This is the assertion for that: the app must go away
# cleanly, not abort.
[void](Click-MenuHost $g.Top)
$m = Wait-Menu $g.Pid 3000
Assert ($m -ne [IntPtr]::Zero) 'C: menu opens for the Close Window dispatch'
Send-MenuKey $g.Top 'F'  # File
Start-Sleep -Milliseconds 300
Send-MenuKey $g.Top 'W'  # Close &Window
# A pane with a live shell counts as a running process, so the close path
# asks first (Window.confirmCloseIfNeeded). Take the affirmative - and note
# that this makes the assertion stronger, since the dispatch now runs a modal
# dialog before it destroys the window that owns the menu.
$confirm = Wait-TestWindow -ProcessId $g.Pid -Class 'GhozttyConfirmDialog' -TimeoutMs 3000
if ($confirm -ne [IntPtr]::Zero) {
    Write-Host '      C: close confirmation shown, accepting'
    # Enter alone CANCELS by design (MB_DEFBUTTON2 parity - an accidental
    # Enter must never approve a close), and posted keys do not move the
    # dialog's focus cross-process. Post the OK command the dialog's own
    # WM_COMMAND handler reads (IDOK), which is what a click on Close does.
    [void](Send-TestRawMessage -Window $confirm -Message 0x0111 -WParam ([IntPtr]1))
}
$windowGone = $false
for ($t = 0; $t -lt 40; $t++) {
    Start-Sleep -Milliseconds 250
    if ((Get-TestWindow -ProcessId $g.Pid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) { $windowGone = $true; break }
}
Assert $windowGone 'C: File>Close Window destroyed the window that owns the menu'
Start-Sleep -Milliseconds 800
# The app does not exit with its last window (`quit-after-last-window-closed`
# is off), so "still answering IPC" is the liveness check - and it is the one
# that matters here, because the Window allocation was freed underneath the
# menu host.
if ($g.Proc -and $g.Proc.HasExited) {
    Assert ($g.Proc.ExitCode -eq 0) "C: ...and the app exited cleanly (code $($g.Proc.ExitCode))"
} else {
    $healthy = $false
    try { $healthy = (List-Json).success -eq $true } catch { $healthy = $false }
    Assert $healthy 'C: ...and the app is still healthy afterwards (answers +list)'
}

Stop-Process -Id $g.Pid -Force -ErrorAction SilentlyContinue

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
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
