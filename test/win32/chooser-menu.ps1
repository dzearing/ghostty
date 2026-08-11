# Machine-chooser management-menu acceptance (tracker T176, the behavioral
# half of T173): the per-row "..." menu and the two relay account operations
# behind it.
#
# Mac's `managementActions` (MachineChooserView.swift:1114) is reachable two
# ways - the ellipsis button in the detail header and a right-click on a
# master-list row - and both show the same items, derived from the row. The
# Local row has no menu at all. This drives the REAL GUI against a stateful
# fake relay and asserts:
#
#   1. the "..." button is hidden on the Local row and shown on a device row;
#   2. clicking it opens a popup menu whose items are exactly Host Settings...
#      | separator | Rename... | separator | Remove from Account... (mac's
#      order; T174 built the store behind the first item, and its behavior is
#      host-settings.ps1's - this script owns the menu SHAPE);
#   3. a right-click on a row opens the same menu (and selects that row);
#   4. Rename... opens a prompt SEEDED with the current name, and committing it
#      PATCHes /v1/client/devices/<id> with {"name":...} - proven by the relay
#      recording the method, path and body - after which the list re-lists;
#   5. Remove from Account... confirms FIRST, and Enter on that confirmation
#      cancels (destructive default), with no DELETE sent;
#   6. choosing Remove for real DELETEs the device and the row disappears.
#
#   powershell -NoProfile -File test\win32\chooser-menu.ps1
#
# T218 (batch 5): migrated onto the BACKGROUND test desktop
# (test/win32/lib/TestDesktop.ps1), so the run never takes the user's
# foreground - asserted at the end, not assumed. The private win32 driver
# (CmDrv) is gone; what remains of it is the HMENU reader below, because
# GetMenuItemCount/GetMenuStringW/GetMenuState take a menu HANDLE and a menu is
# not a desktop object (T218 batch 4's rule: ask what the call takes - HWND goes
# through the harness, HMENU does not).
#
# What the migration changed beyond the mechanics:
#
#   * It no longer SKIPs. The whole drive used to be wrapped in "if the
#     foreground grab aborted, SKIP", so a busy box scored a green run that had
#     asserted nothing. On the test desktop the chord always lands and a missing
#     chooser is a SETUP FAIL.
#   * Clicks are POSTED at the window that would really have received them: the
#     "..." BUTTON control for the button path, and the LISTBOX for the
#     right-click (MachineChooser.zig's list subclass handles WM_RBUTTONDOWN /
#     WM_RBUTTONUP itself and reads the row out of its own lparam, so a posted
#     click at list-client coordinates is the same evidence a real one is).
#     Neither menu entry point reads the cursor - openRowMenuFromButton anchors
#     off GetWindowRect and the right-click path off its own lparam - so nothing
#     here depends on SetCursorPos, which is dead off the input desktop.
#   * Typing into the rename field is WM_CHAR through Send-TestControlText (the
#     standard-control convention), which still lands on the EDIT's own input
#     path, so "typing replaces the pre-selected seed" is unchanged as a claim.
#   * Dialog keys are posted at the dialog: ConfirmDialog runs a NESTED modal
#     pump that filters WM_KEYDOWN for hwnds it owns (ConfirmDialog.zig:549), so
#     Enter/Tab reach handleKey without the dialog manager.
#
# -NegativeControl inverts the destructive-default assertion ("Enter on the
# Remove confirmation sends no DELETE") to expect a DELETE, which MUST fail; it
# is how a run proves the wire log still discriminates.
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [int]$DirPort = 47931,
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
# Isolate the IPC endpoint (inherited through CreateProcessW): an instance
# answering the shared pipe would let another run's windows into this one.
$env:GHOZTTY_PIPE_SUFFIX = '-cmenutest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
$script:skip = 0
$script:negReached = $false
# Write-Host, not the pipeline: a helper that asserts must never also return a
# value, or its caller gets @('  PASS ...', $value).
function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

# HMENU reads only - see the header. These take a menu HANDLE, not a window, so
# they are not desktop-bound and run fine in this process.
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class CmMenuRead {
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuStringW(IntPtr menu, uint id, StringBuilder sb, int max, uint flags);
    [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr menu, uint id, uint flags);

    // One line per item: "SEP" or the item's caption.
    public static string[] Items(IntPtr menu) {
        if (menu == IntPtr.Zero) return new string[0];
        int n = GetMenuItemCount(menu);
        if (n < 0) n = 0;
        var outp = new string[n];
        for (uint i = 0; i < (uint)n; i++) {
            uint state = GetMenuState(menu, i, 0x400); // MF_BYPOSITION
            if ((state & 0x800) != 0) { outp[i] = "SEP"; continue; } // MF_SEPARATOR
            var sb = new StringBuilder(256);
            GetMenuStringW(menu, i, sb, 256, 0x400);
            outp[i] = sb.ToString();
        }
        return outp;
    }
}
'@

# --- window/control helpers (all through the test-desktop worker thread) ------

# {Hwnd, Text, Left, Top, Right, Bottom, Visible} for every $cls descendant, so
# a control can be found by LABEL or by GEOMETRY instead of creation order. Text
# via WM_GETTEXT, which unlike GetWindowTextW is not a stale cross-process cache.
function Get-Controls([IntPtr]$parent, [string]$cls) {
    return @(Get-TestChildWindows -Window $parent -Class $cls | ForEach-Object {
        [pscustomobject]@{
            Hwnd    = [IntPtr]$_.Hwnd
            Text    = (Get-TestControlText -Control ([IntPtr]$_.Hwnd))
            Left    = $_.Left; Top = $_.Top; Right = $_.Right; Bottom = $_.Bottom
            Visible = $_.Visible
        }
    })
}

function Get-NthChild([IntPtr]$parent, [string]$cls, [int]$nth) {
    $all = @(Get-TestChildWindows -Window $parent -Class $cls)
    if ($all.Count -le $nth) { return [IntPtr]::Zero }
    return [IntPtr]$all[$nth].Hwnd
}

# Every button sharing the primary action's row, left to right - the detail
# header's action RUN (T177: [New Window] [Restore All]? [Activity]? [...]).
# Row membership is the shared baseline, which every packing keeps; the row's
# composition is what changes with the selected machine.
function Get-ActionRow([IntPtr]$chooser, [switch]$IncludeHidden) {
    $buttons = @(Get-Controls $chooser 'Button')
    $primary = $buttons | Where-Object { $_.Text -eq 'New Window' } | Select-Object -First 1
    if (-not $primary) { return @() }
    return @($buttons |
        Where-Object { ($IncludeHidden -or $_.Visible) -and $_.Top -eq $primary.Top -and $_.Bottom -eq $primary.Bottom } |
        Sort-Object Left)
}

# The management button: the SQUARE glyph button in that row. Found by shape,
# not by label (its label is a non-ASCII ellipsis) and not by "the one after New
# Window" (that is Activity now).
function Get-MenuButton([IntPtr]$chooser) {
    $sq = @(Get-ActionRow $chooser -IncludeHidden |
        Where-Object { ($_.Right - $_.Left) -eq ($_.Bottom - $_.Top) })
    if ($sq.Count -eq 0) { return $null }
    return $sq[$sq.Count - 1]
}

function Get-ActivityButton([IntPtr]$chooser) {
    @(Get-ActionRow $chooser -IncludeHidden | Where-Object { $_.Text -eq 'Activity' }) |
        Select-Object -First 1
}

# Click the CENTRE of a control, posted at the control itself: posted messages
# skip hit testing, so the target has to be the window the OS would have routed
# to (T216).
function Click-Control([IntPtr]$window, $ctl, [string]$button = 'left') {
    $cx = [int](($ctl.Left + $ctl.Right) / 2)
    $cy = [int](($ctl.Top + $ctl.Bottom) / 2)
    [void](Send-TestMouse -Window $window -Target $ctl.Hwnd -X $cx -Y $cy -Button $button)
}

# The live popup's items. MN_GETHMENU is SENT: the app's GUI thread is inside
# TrackPopupMenuEx's modal loop, which pumps messages, so a cross-process send
# is answered.
function Get-MenuItems([IntPtr]$menuWnd) {
    $r = Invoke-TestMessage -Window $menuWnd -Message 0x01E1
    if ($r -eq [long]::MinValue -or $r -eq 0) { return @() }
    return @([CmMenuRead]::Items([IntPtr]$r))
}

# Post a key into the menu's modal loop. The loop retrieves queue messages
# regardless of target hwnd, and Send-TestControlKey posts without touching
# focus (Send-TestKeys would SetFocus first and dismiss the menu).
function Send-MenuKey([IntPtr]$w, [string]$key) {
    [void](Send-TestControlKey -Control $w -Key $key)
    Start-Sleep -Milliseconds 120
}

function Test-MenuGone([int]$gpid, [int]$ms = 2000) {
    for ($t = 0; $t -lt $ms; $t += 50) {
        if ((Get-TestWindow -ProcessId $gpid -Class '#32768') -eq [IntPtr]::Zero) { return $true }
        Start-Sleep -Milliseconds 50
    }
    return $false
}

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

# T248: one shared reset instead of a private copy — see lib\CleanSlate.ps1.
# Exact-exe rather than a '*zig-out*' CommandLine match (T53b), plus the
# sibling agent and the debug session-layout manifest, so a previous run's
# window cannot be restored under this run's target name.
function Stop-DebugGhoztty {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 800 | Out-Null
}

# --- Stateful fake relay device directory ------------------------------------
# Unlike ipc-machine-chooser.ps1's read-only fake, this one MUTATES: a PATCH
# renames the device it serves and a DELETE removes it, so the chooser's
# re-list after each operation shows the consequence. Every request is logged
# as "METHOD PATH >> body" for the wire assertions.
$hitFile = Join-Path $env:TEMP "ghoztty-cm-hits-$PID.txt"
Remove-Item $hitFile -ErrorAction SilentlyContinue
$dirJob = Start-Job -ScriptBlock {
    param($port, $hitFile)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
    $listener.Start()
    $name = 'E2E-Box'
    $deleted = $false
    function Send($stream, $status, $body) {
        $payload = [Text.Encoding]::UTF8.GetBytes($body)
        $head = "HTTP/1.1 $status`r`nContent-Type: application/json`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n"
        $bytes = [Text.Encoding]::UTF8.GetBytes($head) + $payload
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    }
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $sb = New-Object Text.StringBuilder
            $buf = New-Object byte[] 16384
            # Read until the headers are complete, then any declared body.
            for ($i = 0; $i -lt 60; $i++) {
                if ($stream.DataAvailable) {
                    $n = $stream.Read($buf, 0, $buf.Length)
                    [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $n))
                    $text = $sb.ToString()
                    if ($text -match "`r`n`r`n") {
                        $len = 0
                        if ($text -match '(?im)^Content-Length:\s*(\d+)') { $len = [int]$Matches[1] }
                        $bodySoFar = ($text -split "`r`n`r`n", 2)[1]
                        if ($bodySoFar.Length -ge $len) { break }
                    }
                }
                Start-Sleep -Milliseconds 25
            }
            $text = $sb.ToString()
            $reqLine = ($text -split "`r`n")[0]
            $body = ($text -split "`r`n`r`n", 2)[1]
            Add-Content -Path $hitFile -Value ("$reqLine >> " + ($body -replace "`r|`n", ''))

            $method = ($reqLine -split ' ')[0]
            switch ($method) {
                'PATCH' {
                    if ($body -match '"name"\s*:\s*"([^"]*)"') { $name = $Matches[1] }
                    Send $stream '200 OK' ('{"id":"dev-e2e","name":"' + $name + '","hostname":"e2e.local","online":true}')
                }
                'DELETE' {
                    $deleted = $true
                    Send $stream '204 No Content' ''
                }
                default {
                    if ($deleted) {
                        Send $stream '200 OK' '{"devices":[]}'
                    } else {
                        Send $stream '200 OK' ('{"devices":[{"id":"dev-e2e","name":"' + $name + '","hostname":"e2e.local","online":true}]}')
                    }
                }
            }
        } catch {}
        $client.Close()
    }
} -ArgumentList $DirPort, $hitFile
Start-Sleep -Milliseconds 700

function Get-Hits { (Get-Content $hitFile -ErrorAction SilentlyContinue) -join "`n" }

$acctDir = Join-Path $env:TEMP "ghoztty-cm-acct-$PID"
$errlog = Join-Path $env:TEMP "ghoztty-cm-stderr-$PID.log"
Remove-Item $errlog -ErrorAction SilentlyContinue

$LB_GETCOUNT = 0x018B
$LB_GETITEMHEIGHT = 0x01A1

Stop-DebugGhoztty
# Watch the user's desktop for the whole run: nothing we launch may ever take
# foreground there. That is the complaint the test desktop exists to fix.
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # --- Launch a debug GUI signed in via the env token, isolated from any real
    # account so GHOSTTY_RELAY_TOKEN is what resolves. ------------------------
    $env:GHOSTTY_RELAY_BASE = "http://127.0.0.1:$DirPort"
    $env:GHOSTTY_RELAY_TOKEN = 'faketoken-e2e'
    $env:GHOSTTY_ACCOUNT_STORE = (Join-Path $acctDir 'account.dat')
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -StdErr $errlog
    foreach ($k in 'GHOSTTY_RELAY_BASE', 'GHOSTTY_RELAY_TOKEN', 'GHOSTTY_ACCOUNT_STORE') {
        Remove-Item "env:$k" -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }

    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: GhozttyWindow not found'; exit 1 }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: GhozttyTerminal not found'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'the GUI is NOT enumerable on the interactive desktop'

    [void](Send-TestKeys -Window $top -Target $surface -Modifiers ctrl, shift -Key N)
    $chooser = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000
    Assert ($chooser -ne [IntPtr]::Zero) 'chooser opened'
    Assert ((Get-Hits) -match 'GET /v1/client/devices') 'chooser listed the fake account directory'
    if ($chooser -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no chooser to score'; exit 1 }

    Start-Sleep -Milliseconds 350
    $list = Get-NthChild $chooser 'ListBox' 0
    $count = [int](Invoke-TestMessage -Window $list -Message $LB_GETCOUNT)
    Assert ($count -eq 2) "list shows Local + the fetched device (got $count)"

    # --- (1) the button exists, and it is HIDDEN on the Local row
    # The Local row is selected on open; Mac gives it no management actions, so
    # an ellipsis over it would open nothing.
    $mb = Get-MenuButton $chooser
    Assert ($null -ne $mb) 'the detail header has a management button beside "New Window"'
    if ($mb) {
        Assert (-not $mb.Visible) 'management button is hidden while the Local row is selected'
    }
    # T177: Activity is gated on the same thing the menu is (mac's single
    # `if case .remote(let machine)`), so the Local row shows neither.
    $ab = Get-ActivityButton $chooser
    Assert ($null -ne $ab) 'the detail header has an Activity button'
    if ($ab) { Assert (-not $ab.Visible) 'Activity is hidden while the Local row is selected' }
    $localRow = @(Get-ActionRow $chooser)
    Assert ($localRow.Count -eq 1 -and $localRow[0].Text -eq 'New Window') `
        "the Local row's action row is New Window alone (got: $(($localRow | ForEach-Object { $_.Text }) -join ', '))"

    # --- arrow onto the relay device row. The chooser reads raw WM_KEYDOWN
    # through App.run's routing (it is not a standard #32770), so a posted arrow
    # reaches it.
    [void](Send-TestControlKey -Control $chooser -Key Down)
    Start-Sleep -Milliseconds 300
    $mb = Get-MenuButton $chooser
    Assert ($null -ne $mb -and $mb.Visible) 'management button appears on a relay device row'

    # --- (1b) T177: the row's COMPOSITION and its PACKING on a remote row.
    # mac's detail header is [New Window] [Activity] [...] at one spacing
    # (MachineChooserView.swift:456-491); the win32 row is packed as a run, so
    # what is asserted is the order, one shared baseline, and one gap - not
    # three fixed slots.
    $row = @(Get-ActionRow $chooser)
    Assert ($row.Count -eq 3) "a remote row packs three actions (got $($row.Count): $(($row | ForEach-Object { $_.Text }) -join ', '))"
    if ($row.Count -eq 3) {
        Assert ($row[0].Text -eq 'New Window') "New Window leads the run (got '$($row[0].Text)')"
        Assert ($row[1].Text -eq 'Activity') "Activity follows it (got '$($row[1].Text)')"
        Assert (($row[2].Right - $row[2].Left) -eq ($row[2].Bottom - $row[2].Top)) `
            'the management glyph button trails the run, and is square'
        $gap1 = $row[1].Left - $row[0].Right
        $gap2 = $row[2].Left - $row[1].Right
        Assert ($gap1 -eq $gap2) "one gap across the run (got $gap1 and $gap2)"
        Assert ($gap1 -gt 0) "the buttons do not touch (gap $gap1)"
        # Sized to its own caption, not to the widest: Activity is the shorter
        # word, so its button cannot be as wide as New Window's.
        Assert (($row[1].Right - $row[1].Left) -lt ($row[0].Right - $row[0].Left)) `
            'each button is sized to its own caption'
        $crect = Get-TestWindowRect -Window $chooser
        $inside = ($row | Where-Object { $_.Right -gt ($crect.Right - $crect.Left - $gap1) }).Count
        Assert ($inside -eq 0) 'the whole run stays inside the detail pane'
    }

    # --- (1c) T177: Activity opens the Activity Monitor for THAT machine, and
    # dismisses the chooser on the way (mac's `finish(nil)` then
    # presentDialing, MachineChooserView.swift:1488-1492).
    $ab = Get-ActivityButton $chooser
    Assert ($null -ne $ab -and $ab.Visible) 'Activity appears on a relay device row'
    if ($ab -and $ab.Visible) {
        Click-Control $chooser $ab
        $panel = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyActivityMonitor' -TimeoutMs 8000
        Assert ($panel -ne [IntPtr]::Zero) 'Activity opens an Activity Monitor panel'
        if ($panel -ne [IntPtr]::Zero) {
            $ptitle = Get-TestWindowText -Window $panel
            Assert ($ptitle -like '*E2E-Box*') "the panel is titled for the SELECTED machine (got '$ptitle')"
            Assert (-not (Test-TestWindowExists -Window $chooser)) 'the chooser dismissed itself first'
            # T295: the button DIALS that machine. The fake directory relay
            # here serves the device list but is not an agent endpoint, so the
            # dial must fail - and the panel must say so rather than quietly
            # showing THIS machine's processes under that machine's name.
            # The log lines are the oracle; the empty state is painted text,
            # not a control.
            Start-Sleep -Seconds 3
            Assert (Select-String -Path $errlog -Pattern 'activity monitor: dialing source=E2E-Box' -Quiet) `
                'the Activity button DIALS the selected machine (T295)'
            Assert (Select-String -Path $errlog -Pattern 'activity monitor: dial failed source=E2E-Box' -Quiet) `
                'an unreachable machine reports the dial failure instead of falling back'
            $mislabeled = @(Select-String -Path $errlog -Pattern 'activity monitor: source=E2E-Box total=[1-9]' -ErrorAction SilentlyContinue).Count
            Assert ($mislabeled -eq 0) 'no rows are ever shown under a machine we could not reach (no mislabeled rows)'
        }

        # Re-open the chooser, land back on the device row, and press Activity
        # again: the registry is keyed per machine, so this focuses the panel
        # that is already open instead of opening a second one.
        [void](Send-TestKeys -Window $top -Target $surface -Modifiers ctrl, shift -Key N)
        $chooser = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000
        Assert ($chooser -ne [IntPtr]::Zero) 'the chooser re-opens after the panel took over'
        if ($chooser -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: chooser did not re-open'; exit 1 }
        $list = Get-NthChild $chooser 'ListBox' 0
        Start-Sleep -Milliseconds 350
        [void](Send-TestControlKey -Control $chooser -Key Down)
        Start-Sleep -Milliseconds 300

        $ab2 = Get-ActivityButton $chooser
        if ($ab2 -and $ab2.Visible) {
            Click-Control $chooser $ab2
            Start-Sleep -Milliseconds 1200
            $panels = @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyActivityMonitor')
            Assert ($panels.Count -eq 1) "a second Activity press focuses the same panel (got $($panels.Count) windows)"
        } else {
            Write-Host '  SKIP second-press: Activity button missing after re-open'
            $script:skip++
        }

        # Put the desktop back the way the rest of this script expects it:
        # panel closed, chooser open on the device row.
        foreach ($p in @(Get-TestWindows -ProcessId $app.Pid -Class 'GhozttyActivityMonitor')) {
            [void](Send-TestWindowClose -Window ([IntPtr]$p.Hwnd))
        }
        Start-Sleep -Milliseconds 500
        if (-not (Test-TestWindowExists -Window $chooser)) {
            [void](Send-TestKeys -Window $top -Target $surface -Modifiers ctrl, shift -Key N)
            $chooser = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000
            $list = Get-NthChild $chooser 'ListBox' 0
            Start-Sleep -Milliseconds 350
            [void](Send-TestControlKey -Control $chooser -Key Down)
            Start-Sleep -Milliseconds 300
        }
        $mb = Get-MenuButton $chooser
    }

    # --- (2) clicking it opens the mac item list
    if ($mb -and $mb.Visible) {
        Click-Control $chooser $mb
        $popup = Wait-TestPopupMenu -ProcessId $app.Pid -TimeoutMs 2500
        Assert ($popup -ne [IntPtr]::Zero) 'the management button opens a popup menu'
        if ($popup -ne [IntPtr]::Zero) {
            $items = Get-MenuItems $popup
            $want = @('Host Settings...', 'SEP', 'Rename...', 'SEP', 'Remove from Account...')
            Assert (($items -join '|') -eq ($want -join '|')) `
                "menu is Host Settings | sep | Rename | sep | Remove from Account (got: $($items -join ' | '))"
            # Host Settings... leads on mac (managementActions), and T174 built
            # the store behind it - what this script owns is the SHAPE;
            # host-settings.ps1 owns its behavior.
            Assert ($items.Count -gt 0 -and $items[0] -eq 'Host Settings...') 'Host Settings... leads the menu (mac order)'
            Send-MenuKey $chooser Escape
            Assert (Test-MenuGone $app.Pid) 'Escape closed the menu'
        }
    }

    # --- (3) right-click on the row opens the same menu. Posted at the LISTBOX:
    # its subclass handles WM_RBUTTONDOWN/UP itself and resolves the row from
    # its own lparam, so the click's coordinates are the evidence (no cursor).
    $lr = Get-TestWindowRect -Window $list
    $rowH = [int](Invoke-TestMessage -Window $list -Message $LB_GETITEMHEIGHT)
    # The middle of row 1 (the device), off the list's own top edge.
    $rx = $lr.Left + 40
    $ry = $lr.Top + 1 + [int]($rowH * 1.5)
    [void](Send-TestMouse -Window $chooser -Target $list -X $rx -Y $ry -Button right)
    $popup2 = Wait-TestPopupMenu -ProcessId $app.Pid -TimeoutMs 2500
    Assert ($popup2 -ne [IntPtr]::Zero) 'right-clicking a row opens the management menu'
    if ($popup2 -ne [IntPtr]::Zero) {
        $items2 = Get-MenuItems $popup2
        Assert (($items2 -join '|') -eq 'Host Settings...|SEP|Rename...|SEP|Remove from Account...') `
            "right-click menu matches the button's (got: $($items2 -join ' | '))"

        # --- (4) Rename...: seeded prompt, PATCH. Two DOWNs: Host Settings...
        # is the first item (separators are skipped by keyboard navigation).
        Send-MenuKey $chooser Down     # -> Host Settings...
        Send-MenuKey $chooser Down     # -> Rename...
        Send-MenuKey $chooser Enter
        $prompt = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyConfirmDialog' -TimeoutMs 3000
        Assert ($prompt -ne [IntPtr]::Zero) 'Rename... opens a prompt'
        if ($prompt -ne [IntPtr]::Zero) {
            $edit = Get-NthChild $prompt 'Edit' 0
            Assert ($edit -ne [IntPtr]::Zero) 'the rename prompt has a text field'
            if ($edit -ne [IntPtr]::Zero) {
                $seed = Get-TestControlText -Control $edit
                Assert ($seed -eq 'E2E-Box') "the field is seeded with the current name (got '$seed')"
                $btns = @(Get-Controls $prompt 'Button')
                Assert (@($btns | Where-Object { $_.Text -eq 'Rename' }).Count -eq 1) `
                    "the prompt's affirmative button says Rename (got: $(($btns | ForEach-Object { $_.Text }) -join ', '))"

                # The seed is pre-selected (EM_SETSEL at creation), so typing
                # REPLACES it - the rename dialog's whole point.
                [void](Send-TestControlText -Control $edit -Text 'renamedbox')
                $typed = Get-TestControlText -Control $edit
                Assert ($typed -eq 'renamedbox') "typing replaces the selected seed (got '$typed')"
                # Enter commits: ConfirmDialog's nested pump filters WM_KEYDOWN
                # for hwnds it owns, so a posted Enter reaches handleKey.
                [void](Send-TestControlKey -Control $prompt -Key Enter)
                Start-Sleep -Milliseconds 1000

                $hits = Get-Hits
                Assert ($hits -match 'PATCH /v1/client/devices/dev-e2e') 'rename PATCHed the device resource'
                Assert ($hits -match '"name":"renamedbox"') 'the PATCH body carried the typed name'
                Assert (-not (Test-TestWindowExists -Window $prompt)) 'the prompt closed after committing'
                # The chooser re-lists so the row shows the new name.
                $getsAfter = ([regex]::Matches($hits, 'GET /v1/client/devices')).Count
                Assert ($getsAfter -ge 2) "the chooser re-listed after the rename ($getsAfter GETs)"
                # ...and the re-list must not throw the user back to the Local
                # row: the machine they just renamed stays selected, so its
                # management button (and the detail pane describing it) are
                # still there.
                $mbAfter = Get-MenuButton $chooser
                Assert ($null -ne $mbAfter -and $mbAfter.Visible) `
                    'the renamed machine stays selected after the re-list'
            }
        }
    }

    # --- (5) Remove: confirmation first, and Enter CANCELS it
    $mb = Get-MenuButton $chooser
    if ($mb -and $mb.Visible) {
        Click-Control $chooser $mb
        $popup3 = Wait-TestPopupMenu -ProcessId $app.Pid -TimeoutMs 2500
        if ($popup3 -ne [IntPtr]::Zero) {
            Send-MenuKey $chooser Down   # Host Settings...
            Send-MenuKey $chooser Down   # Rename...
            Send-MenuKey $chooser Down   # Remove from Account...
            Send-MenuKey $chooser Enter
        }
        $confirm = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyConfirmDialog' -TimeoutMs 3000
        Assert ($confirm -ne [IntPtr]::Zero) 'Remove from Account... confirms before deleting'
        if ($confirm -ne [IntPtr]::Zero) {
            $cbtns = @(Get-Controls $confirm 'Button')
            Assert (@($cbtns | Where-Object { $_.Text -eq 'Remove' }).Count -eq 1) `
                "the confirmation's affirmative button says Remove (got: $(($cbtns | ForEach-Object { $_.Text }) -join ', '))"
            Assert (@($cbtns | Where-Object { $_.Text -eq 'Cancel' }).Count -eq 1) 'the confirmation offers Cancel'
            Assert ((Get-Hits) -notmatch 'DELETE ') 'nothing was deleted before the user answered'

            [void](Send-TestControlKey -Control $confirm -Key Enter)
            Start-Sleep -Milliseconds 700
            Assert (-not (Test-TestWindowExists -Window $confirm)) 'Enter dismissed the confirmation'
            # The destructive-default claim, and this run's negative control:
            # inverting it asserts a DELETE that a healthy build never sends.
            $deleted = ((Get-Hits) -match 'DELETE ')
            $script:negReached = $true
            if ($NegativeControl) {
                Assert $deleted 'NEGATIVE CONTROL: Enter DELETEd the device (it must not)'
            } else {
                Assert (-not $deleted) 'Enter defaults to Cancel on a destructive confirmation (no DELETE)'
            }
            $stillThere = [int](Invoke-TestMessage -Window $list -Message $LB_GETCOUNT)
            Assert ($stillThere -eq 2) "the device row survived the cancelled removal (got $stillThere)"
        }

        # --- (6) and for real: Tab onto Remove, Enter, row goes
        $mb = Get-MenuButton $chooser
        if ($mb -and $mb.Visible) {
            Click-Control $chooser $mb
            $popup4 = Wait-TestPopupMenu -ProcessId $app.Pid -TimeoutMs 2500
            if ($popup4 -ne [IntPtr]::Zero) {
                Send-MenuKey $chooser Down   # Host Settings...
                Send-MenuKey $chooser Down   # Rename...
                Send-MenuKey $chooser Down   # Remove from Account...
                Send-MenuKey $chooser Enter
            }
            $confirm2 = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyConfirmDialog' -TimeoutMs 3000
            if ($confirm2 -ne [IntPtr]::Zero) {
                # Tab order is OK -> Cancel with focus starting on Cancel
                # (MB_DEFBUTTON2 parity), so one Tab lands on Remove.
                [void](Send-TestControlKey -Control $confirm2 -Key Tab)
                Start-Sleep -Milliseconds 200
                [void](Send-TestControlKey -Control $confirm2 -Key Enter)
                Start-Sleep -Milliseconds 1400

                $hits = Get-Hits
                Assert ($hits -match 'DELETE /v1/client/devices/dev-e2e') 'confirming Remove DELETEd the device resource'
                $after = [int](Invoke-TestMessage -Window $list -Message $LB_GETCOUNT)
                Assert ($after -eq 1) "the removed machine's row disappeared (got $after rows, want Local only)"
            } else {
                Write-Host '  SKIP remove-for-real: confirmation did not appear'
                $script:skip++
            }
        }
    }

    [void](Send-TestControlKey -Control $chooser -Key Escape)
    Start-Sleep -Milliseconds 500
    Assert (-not (Test-TestWindowExists -Window $chooser)) 'Escape closed the chooser'
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'app survived the whole menu/rename/remove flow'

} finally {
    $script:hitsFinal = Get-Hits
    Remove-TestDesktop
    Stop-DebugGhoztty
    Stop-Job $dirJob -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $dirJob -Force -ErrorAction SilentlyContinue | Out-Null
    Remove-Item $hitFile -ErrorAction SilentlyContinue
    Remove-Item $acctDir -Recurse -Force -ErrorAction SilentlyContinue
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    # Get-TestLaunchedPids, not the live pid list: Remove-TestDesktop has run by
    # now and emptied the live one, which would score this against nothing.
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    Assert ($launched.Count -gt 0) 'the run actually launched apps on the test desktop'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

# A -NegativeControl run that never reached the inverted assertion proves
# nothing, so say so instead of exiting green.
if ($NegativeControl -and -not $script:negReached) {
    Assert $false 'NEGATIVE CONTROL never reached its inverted assertion'
}

Write-Host ''
if ($script:fail -gt 0 -and $env:CM_DEBUG) {
    Write-Host '--- app stderr (T176DBG) ---'
    Select-String -Path $errlog -Pattern 'T176DBG|machine chooser' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Line }
    Write-Host '--- relay hits ---'
    Write-Host $script:hitsFinal
}
Remove-Item $errlog -ErrorAction SilentlyContinue
if ($script:skip -gt 0) { Write-Host "($($script:skip) section(s) SKIPPED)" }
if ($script:fail -eq 0) {
    Write-Host "CHOOSER-MENU ACCEPTANCE: ALL PASS ($($script:pass) assertions$(if ($script:skip) { ", $($script:skip) SKIPPED" }))"
    exit 0
} else {
    Write-Host "CHOOSER-MENU ACCEPTANCE: $($script:fail) FAILURE(S) ($($script:pass) passed)" -ForegroundColor Red
    exit 1
}
