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
#   2. clicking it opens a popup menu whose items are exactly Rename... |
#      separator | Remove from Account... (no Host Settings... - that is
#      T174's, and it is gated off);
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
# Mechanics mirror ipc-machine-chooser.ps1: T86-hardened foreground grab, then
# SendInput. The run ABORTS-to-SKIP (never fails, never leaks keys) if another
# window owns the foreground. Only touches ghoztty processes from this repo's
# zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [int]$DirPort = 47931
)

$ErrorActionPreference = 'Continue'
$script:pass = 0
$script:fail = 0
$script:skip = 0
function Assert($cond, $name) {
    if ($cond) { "  PASS $name"; $script:pass++ } else { "  FAIL $name"; $script:fail++ }
}
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }

Add-Type @'
using System;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
public class CmDrv {
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr w, StringBuilder l);

    // An EDIT's REAL contents. GetWindowTextW across a process boundary
    // returns USER32's cached window text, which is NOT the edit's buffer:
    // a cross-process SetWindowTextW updated the cache while the control kept
    // the old string, so the app read the old name back and the rename became
    // a silent no-op. WM_GETTEXT is marshaled to the control itself.
    public static string EditText(IntPtr edit) {
        var sb = new StringBuilder(512);
        SendMessageW(edit, 0x000D, (IntPtr)512, sb); // WM_GETTEXT
        return sb.ToString();
    }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint data, IntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr hMenu);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuStringW(IntPtr hMenu, uint id, StringBuilder sb, int max, uint flags);
    [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr hMenu, uint id, uint flags);
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }

    // "text|left|top|right|bottom|visible" for every `cls` child, so a control
    // can be found by LABEL or by GEOMETRY instead of creation order. The
    // management button's label is a non-ASCII ellipsis, so this script finds
    // it by position (same row as "New Window", to its right).
    public static string[] ChildInfo(IntPtr parent, string cls) {
        var rows = new System.Collections.Generic.List<string>();
        EnumChildWindows(parent, (h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (string.Equals(sb.ToString(), cls, StringComparison.OrdinalIgnoreCase)) {
                var t = new StringBuilder(256);
                GetWindowTextW(h, t, 256);
                RECT r; GetWindowRect(h, out r);
                rows.Add(t.ToString() + "|" + r.left + "|" + r.top + "|" + r.right + "|" + r.bottom
                    + "|" + (IsWindowVisible(h) ? 1 : 0));
            }
            return true;
        }, IntPtr.Zero);
        return rows.ToArray();
    }

    public static IntPtr FindChild(IntPtr parent, string cls, int nth) {
        IntPtr found = IntPtr.Zero;
        int seen = 0;
        EnumChildWindows(parent, (h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (string.Equals(sb.ToString(), cls, StringComparison.OrdinalIgnoreCase)) {
                if (seen == nth) { found = h; return false; }
                seen++;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static IntPtr FindTop(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h)) {
                var sb = new StringBuilder(64);
                GetClassNameW(h, sb, 64);
                if (sb.ToString() == "GhozttyWindow") { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static IntPtr FindByClass(string cls) {
        return FindWindowExW(IntPtr.Zero, IntPtr.Zero, cls, null);
    }

    public static string WindowText(IntPtr h) {
        var sb = new StringBuilder(512);
        GetWindowTextW(h, sb, 512);
        return sb.ToString();
    }

    // The live items of the open popup menu, one per line as
    // "SEP" or the item's caption. MN_GETHMENU (0x01E1) turns the "#32768"
    // popup WINDOW into the HMENU behind it, which is the only way to read a
    // menu the app built privately.
    public static string[] MenuItems(IntPtr popup) {
        IntPtr hmenu = SendMessageW(popup, 0x01E1, IntPtr.Zero, IntPtr.Zero);
        if (hmenu == IntPtr.Zero) return new string[0];
        int n = GetMenuItemCount(hmenu);
        if (n < 0) n = 0;
        var outp = new string[n];
        for (uint i = 0; i < n; i++) {
            uint state = GetMenuState(hmenu, i, 0x400); // MF_BYPOSITION
            if ((state & 0x800) != 0) { outp[i] = "SEP"; continue; } // MF_SEPARATOR
            var sb = new StringBuilder(256);
            GetMenuStringW(hmenu, i, sb, 256, 0x400);
            outp[i] = sb.ToString();
        }
        return outp;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public KEYBDINPUT ki; public ulong pad; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);

    static void Key(ushort vk, bool up) {
        var i = new INPUT[1];
        i[0].type = 1;
        i[0].ki.wVk = vk;
        i[0].ki.dwFlags = up ? 2u : 0u;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    // T86-hardened foreground grab (see ipc-machine-chooser.ps1).
    public static bool GrabForeground(IntPtr top) {
        uint cur = GetCurrentThreadId();
        bool fg = (GetForegroundWindow() == top);
        for (int attempt = 0; attempt < 5 && !fg; attempt++) {
            IntPtr curFg = GetForegroundWindow();
            uint fgTid = 0;
            if (curFg != IntPtr.Zero && curFg != top) {
                uint fgPid; fgTid = GetWindowThreadProcessId(curFg, out fgPid);
                if (fgTid != 0) AttachThreadInput(cur, fgTid, true);
            }
            Key(0x12, false); Key(0x12, true);
            SetForegroundWindow(top);
            if (fgTid != 0) AttachThreadInput(cur, fgTid, false);
            Thread.Sleep(150 + attempt * 200);
            fg = (GetForegroundWindow() == top);
        }
        return fg;
    }

    public static string Chord(IntPtr top, IntPtr surface, ushort[] mods, ushort vk) {
        uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
        uint cur = GetCurrentThreadId();
        GrabForeground(top);
        if (!AttachThreadInput(cur, tid, true)) return "ATTACH FAILED";
        try {
            SetFocus(surface);
            Thread.Sleep(60);
            if (GetForegroundWindow() != top) return "ABORT: foreground owned by another window";
            foreach (var m in mods) Key(m, false);
            Thread.Sleep(20);
            Key(vk, false); Thread.Sleep(20); Key(vk, true);
            Thread.Sleep(20);
            for (int j = mods.Length - 1; j >= 0; j--) Key(mods[j], true);
            Thread.Sleep(100);
            return "SENT";
        } finally { AttachThreadInput(cur, tid, false); }
    }

    // A key to whatever the foreground window has focused. `raise` false when
    // a modal popup menu already owns input (raising would dismiss it).
    public static void Press(IntPtr win, ushort vk, bool raise) {
        if (raise) GrabForeground(win);
        Key(vk, false); Thread.Sleep(25); Key(vk, true);
        Thread.Sleep(90);
    }

    // Type lowercase ASCII letters into whatever has focus. Real keystrokes,
    // not SetWindowText: only the injected path proves the field's contents
    // reach the commit.
    public static void TypeLower(IntPtr win, string s) {
        GrabForeground(win);
        foreach (char c in s) {
            ushort vk = (ushort)(char.ToUpperInvariant(c));
            Key(vk, false); Thread.Sleep(15); Key(vk, true); Thread.Sleep(15);
        }
        Thread.Sleep(120);
    }

    // A real click at a SCREEN point. mouse_event (not SendInput) keeps the
    // struct simple; both land on the same injection path.
    public static void Click(int x, int y, bool right) {
        SetCursorPos(x, y);
        Thread.Sleep(60);
        uint down = right ? 0x0008u : 0x0002u; // RIGHTDOWN : LEFTDOWN
        uint up = right ? 0x0010u : 0x0004u;   // RIGHTUP   : LEFTUP
        mouse_event(down, 0, 0, 0, IntPtr.Zero);
        Thread.Sleep(40);
        mouse_event(up, 0, 0, 0, IntPtr.Zero);
        Thread.Sleep(250);
    }
}
'@
[void][CmDrv]::SetProcessDPIAware()

function Get-Controls($parent, $cls) {
    foreach ($row in [CmDrv]::ChildInfo($parent, $cls)) {
        $f = $row -split '\|'
        [pscustomobject]@{
            Text = $f[0]; Left = [int]$f[1]; Top = [int]$f[2]
            Right = [int]$f[3]; Bottom = [int]$f[4]; Visible = ([int]$f[5] -eq 1)
        }
    }
}

# The management button: the detail-pane button sharing the "New Window" row
# and sitting to its right. Found by geometry because its label is a non-ASCII
# ellipsis glyph.
function Get-MenuButton($chooser) {
    $buttons = @(Get-Controls $chooser 'Button')
    $primary = $buttons | Where-Object { $_.Text -eq 'New Window' } | Select-Object -First 1
    if (-not $primary) { return $null }
    $buttons |
        Where-Object { $_.Left -ge $primary.Right -and $_.Top -eq $primary.Top -and $_.Text -ne 'New Window' } |
        Sort-Object Left | Select-Object -First 1
}

function Wait-Window($cls, $ms = 2500) {
    for ($t = 0; $t -lt ($ms / 25); $t++) {
        $h = [CmDrv]::FindByClass($cls)
        if ($h -ne [IntPtr]::Zero) { return $h }
        Start-Sleep -Milliseconds 25
    }
    return [IntPtr]::Zero
}

function Stop-DebugGhoztty {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 700
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

# --- Launch a debug GUI signed in via the env token --------------------------
Stop-DebugGhoztty
$acctDir = Join-Path $env:TEMP "ghoztty-cm-acct-$PID"
$env:GHOSTTY_RELAY_BASE = "http://127.0.0.1:$DirPort"
$env:GHOSTTY_RELAY_TOKEN = 'faketoken-e2e'
$env:GHOSTTY_ACCOUNT_STORE = (Join-Path $acctDir 'account.dat')
$errlog = Join-Path $env:TEMP "ghoztty-cm-stderr-$PID.log"
Remove-Item $errlog -ErrorAction SilentlyContinue
$proc = Start-Process -FilePath $Exe -PassThru -RedirectStandardError $errlog
foreach ($k in 'GHOSTTY_RELAY_BASE', 'GHOSTTY_RELAY_TOKEN', 'GHOSTTY_ACCOUNT_STORE') {
    Remove-Item "env:$k" -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 3

if ($proc.HasExited) {
    "SETUP FAIL: GUI died at launch"
    $script:fail++
} else {
    $top = [CmDrv]::FindTop([uint32]$proc.Id)
    $surface = [CmDrv]::FindWindowExW($top, [IntPtr]::Zero, 'GhozttyTerminal', $null)
    if ($top -eq [IntPtr]::Zero -or $surface -eq [IntPtr]::Zero) {
        "SETUP FAIL: GhozttyWindow/GhozttyTerminal not found"
        $script:fail++
    } else {
        $r = [CmDrv]::Chord($top, $surface, @([uint16]0x11, [uint16]0x10), [uint16]0x4E)
        if ($r -like 'ABORT*') {
            "  SKIP chooser-menu drive: $r"
            $script:skip++
        } else {
            $chooser = Wait-Window 'GhozttyMachineChooser' 3500
            Assert ($chooser -ne [IntPtr]::Zero) 'chooser opened'
            Assert ((Get-Hits) -match 'GET /v1/client/devices') 'chooser listed the fake account directory'

            if ($chooser -ne [IntPtr]::Zero) {
                [void][CmDrv]::GrabForeground($chooser)
                Start-Sleep -Milliseconds 350
                $LB_GETCOUNT = 0x018B
                $LB_GETITEMHEIGHT = 0x01A1
                $list = [CmDrv]::FindChild($chooser, 'ListBox', 0)
                $count = [int][CmDrv]::SendMessageW($list, $LB_GETCOUNT, [IntPtr]::Zero, [IntPtr]::Zero)
                Assert ($count -eq 2) "list shows Local + the fetched device (got $count)"

                # --- (1) the button exists, and it is HIDDEN on the Local row
                # The Local row is selected on open; Mac gives it no management
                # actions, so an ellipsis over it would open nothing.
                $mb = Get-MenuButton $chooser
                Assert ($null -ne $mb) 'the detail header has a management button beside "New Window"'
                if ($mb) {
                    Assert (-not $mb.Visible) 'management button is hidden while the Local row is selected'
                }

                # --- arrow onto the relay device row
                [CmDrv]::Press($chooser, [uint16]0x28, $false) # VK_DOWN
                Start-Sleep -Milliseconds 250
                $mb = Get-MenuButton $chooser
                Assert ($null -ne $mb -and $mb.Visible) 'management button appears on a relay device row'

                # --- (2) clicking it opens the mac item list
                if ($mb -and $mb.Visible) {
                    $cx = [int](($mb.Left + $mb.Right) / 2)
                    $cy = [int](($mb.Top + $mb.Bottom) / 2)
                    [CmDrv]::Click($cx, $cy, $false)
                    $popup = Wait-Window '#32768' 2000
                    Assert ($popup -ne [IntPtr]::Zero) 'the management button opens a popup menu'
                    if ($popup -ne [IntPtr]::Zero) {
                        $items = @([CmDrv]::MenuItems($popup))
                        $want = @('Rename...', 'SEP', 'Remove from Account...')
                        Assert (($items -join '|') -eq ($want -join '|')) `
                            "menu is Rename | sep | Remove from Account (got: $($items -join ' | '))"
                        # Host Settings... is T174's; gated off, it must be
                        # ABSENT rather than present-and-dead.
                        Assert (($items -join '|') -notmatch 'Host Settings') 'Host Settings... is absent while T174 is unbuilt'
                        [CmDrv]::Press($popup, [uint16]0x1B, $false) # VK_ESCAPE
                        Start-Sleep -Milliseconds 300
                        Assert ([CmDrv]::FindByClass('#32768') -eq [IntPtr]::Zero) 'Escape closed the menu'
                    }
                }

                # --- (3) right-click on the row opens the same menu
                $lr = New-Object CmDrv+RECT
                [void][CmDrv]::GetWindowRect($list, [ref]$lr)
                $rowH = [int][CmDrv]::SendMessageW($list, $LB_GETITEMHEIGHT, [IntPtr]::Zero, [IntPtr]::Zero)
                # The middle of row 1 (the device), off the list's own top edge.
                $rx = $lr.left + 40
                $ry = $lr.top + 1 + [int]($rowH * 1.5)
                [CmDrv]::Click($rx, $ry, $true)
                $popup2 = Wait-Window '#32768' 2000
                Assert ($popup2 -ne [IntPtr]::Zero) 'right-clicking a row opens the management menu'
                if ($popup2 -ne [IntPtr]::Zero) {
                    $items2 = @([CmDrv]::MenuItems($popup2))
                    Assert (($items2 -join '|') -eq 'Rename...|SEP|Remove from Account...') `
                        "right-click menu matches the button's (got: $($items2 -join ' | '))"

                    # --- (4) Rename...: first item, seeded prompt, PATCH
                    [CmDrv]::Press($popup2, [uint16]0x28, $false) # DOWN -> Rename...
                    [CmDrv]::Press($popup2, [uint16]0x0D, $false) # ENTER
                    $prompt = Wait-Window 'GhozttyConfirmDialog' 2500
                    Assert ($prompt -ne [IntPtr]::Zero) 'Rename... opens a prompt'
                    if ($prompt -ne [IntPtr]::Zero) {
                        $edit = [CmDrv]::FindChild($prompt, 'Edit', 0)
                        Assert ($edit -ne [IntPtr]::Zero) 'the rename prompt has a text field'
                        if ($edit -ne [IntPtr]::Zero) {
                            $seed = [CmDrv]::EditText($edit)
                            Assert ($seed -eq 'E2E-Box') "the field is seeded with the current name (got '$seed')"
                            $btns = @(Get-Controls $prompt 'Button')
                            Assert (@($btns | Where-Object { $_.Text -eq 'Rename' }).Count -eq 1) `
                                "the prompt's affirmative button says Rename (got: $(($btns | ForEach-Object { $_.Text }) -join ', '))"

                            # The seed is pre-selected, so typing REPLACES it -
                            # the rename dialog's whole point.
                            [CmDrv]::TypeLower($prompt, 'renamedbox')
                            $typed = [CmDrv]::EditText($edit)
                            Assert ($typed -eq 'renamedbox') "typing replaces the selected seed (got '$typed')"
                            [CmDrv]::Press($prompt, [uint16]0x0D, $true) # ENTER commits
                            Start-Sleep -Milliseconds 900

                            $hits = Get-Hits
                            Assert ($hits -match 'PATCH /v1/client/devices/dev-e2e') 'rename PATCHed the device resource'
                            Assert ($hits -match '"name":"renamedbox"') 'the PATCH body carried the typed name'
                            Assert ([CmDrv]::FindByClass('GhozttyConfirmDialog') -eq [IntPtr]::Zero) 'the prompt closed after committing'
                            # The chooser re-lists so the row shows the new name.
                            $getsAfter = ([regex]::Matches($hits, 'GET /v1/client/devices')).Count
                            Assert ($getsAfter -ge 2) "the chooser re-listed after the rename ($getsAfter GETs)"
                            # ...and the re-list must not throw the user back
                            # to the Local row: the machine they just renamed
                            # stays selected, so its management button (and the
                            # detail pane describing it) are still there.
                            $mbAfter = Get-MenuButton $chooser
                            Assert ($null -ne $mbAfter -and $mbAfter.Visible) `
                                'the renamed machine stays selected after the re-list'
                        }
                    }
                }

                # --- (5) Remove: confirmation first, and Enter CANCELS it
                $mb = Get-MenuButton $chooser
                if ($mb -and $mb.Visible) {
                    $cx = [int](($mb.Left + $mb.Right) / 2)
                    $cy = [int](($mb.Top + $mb.Bottom) / 2)
                    [CmDrv]::Click($cx, $cy, $false)
                    $popup3 = Wait-Window '#32768' 2000
                    if ($popup3 -ne [IntPtr]::Zero) {
                        [CmDrv]::Press($popup3, [uint16]0x28, $false) # Rename...
                        [CmDrv]::Press($popup3, [uint16]0x28, $false) # Remove from Account...
                        [CmDrv]::Press($popup3, [uint16]0x0D, $false)
                    }
                    $confirm = Wait-Window 'GhozttyConfirmDialog' 2500
                    Assert ($confirm -ne [IntPtr]::Zero) 'Remove from Account... confirms before deleting'
                    if ($confirm -ne [IntPtr]::Zero) {
                        $cbtns = @(Get-Controls $confirm 'Button')
                        Assert (@($cbtns | Where-Object { $_.Text -eq 'Remove' }).Count -eq 1) `
                            "the confirmation's affirmative button says Remove (got: $(($cbtns | ForEach-Object { $_.Text }) -join ', '))"
                        Assert (@($cbtns | Where-Object { $_.Text -eq 'Cancel' }).Count -eq 1) 'the confirmation offers Cancel'
                        Assert ((Get-Hits) -notmatch 'DELETE ') 'nothing was deleted before the user answered'

                        [CmDrv]::Press($confirm, [uint16]0x0D, $true) # ENTER
                        Start-Sleep -Milliseconds 600
                        Assert ([CmDrv]::FindByClass('GhozttyConfirmDialog') -eq [IntPtr]::Zero) 'Enter dismissed the confirmation'
                        Assert ((Get-Hits) -notmatch 'DELETE ') 'Enter defaults to Cancel on a destructive confirmation (no DELETE)'
                        $stillThere = [int][CmDrv]::SendMessageW($list, $LB_GETCOUNT, [IntPtr]::Zero, [IntPtr]::Zero)
                        Assert ($stillThere -eq 2) "the device row survived the cancelled removal (got $stillThere)"
                    }

                    # --- (6) and for real: Tab onto Remove, Enter, row goes
                    [void][CmDrv]::GrabForeground($chooser)
                    Start-Sleep -Milliseconds 250
                    $mb = Get-MenuButton $chooser
                    if ($mb -and $mb.Visible) {
                        [CmDrv]::Click([int](($mb.Left + $mb.Right) / 2), [int](($mb.Top + $mb.Bottom) / 2), $false)
                        $popup4 = Wait-Window '#32768' 2000
                        if ($popup4 -ne [IntPtr]::Zero) {
                            [CmDrv]::Press($popup4, [uint16]0x28, $false)
                            [CmDrv]::Press($popup4, [uint16]0x28, $false)
                            [CmDrv]::Press($popup4, [uint16]0x0D, $false)
                        }
                        $confirm2 = Wait-Window 'GhozttyConfirmDialog' 2500
                        if ($confirm2 -ne [IntPtr]::Zero) {
                            [void][CmDrv]::GrabForeground($confirm2)
                            Start-Sleep -Milliseconds 200
                            [CmDrv]::Press($confirm2, [uint16]0x09, $false) # TAB: Cancel -> Remove
                            [CmDrv]::Press($confirm2, [uint16]0x0D, $false) # ENTER
                            Start-Sleep -Milliseconds 1200

                            $hits = Get-Hits
                            Assert ($hits -match 'DELETE /v1/client/devices/dev-e2e') 'confirming Remove DELETEd the device resource'
                            $after = [int][CmDrv]::SendMessageW($list, $LB_GETCOUNT, [IntPtr]::Zero, [IntPtr]::Zero)
                            Assert ($after -eq 1) "the removed machine's row disappeared (got $after rows, want Local only)"
                        } else {
                            "  SKIP remove-for-real: confirmation did not appear"
                            $script:skip++
                        }
                    }
                }

                [CmDrv]::Press($chooser, [uint16]0x1B, $true) # VK_ESCAPE
                Start-Sleep -Milliseconds 400
                Assert ([CmDrv]::FindByClass('GhozttyMachineChooser') -eq [IntPtr]::Zero) 'Escape closed the chooser'
            }
            Assert (-not $proc.HasExited) 'app survived the whole menu/rename/remove flow'
        }
    }
}

# --- teardown ---------------------------------------------------------------
$script:hitsFinal = Get-Hits
Stop-DebugGhoztty
Stop-Job $dirJob -ErrorAction SilentlyContinue | Out-Null
Remove-Job $dirJob -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item $hitFile -ErrorAction SilentlyContinue
Remove-Item $acctDir -Recurse -Force -ErrorAction SilentlyContinue

""
if ($script:fail -gt 0 -and $env:CM_DEBUG) {
    "--- app stderr (T176DBG) ---"
    Select-String -Path $errlog -Pattern 'T176DBG|machine chooser' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Line }
    "--- relay hits ---"
    $script:hitsFinal
}
Remove-Item $errlog -ErrorAction SilentlyContinue
if ($script:fail -eq 0) {
    "ALL PASS ($($script:pass) assertions, $($script:skip) skipped)"
} else {
    "$($script:fail) FAILURE(S) ($($script:pass) passed, $($script:skip) skipped)"
}
