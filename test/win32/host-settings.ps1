# Per-host remote defaults acceptance (tracker T174): the "Host Settings..."
# editor behind the machine chooser's per-row "..." menu, and the three places
# the stored defaults are allowed to apply.
#
# Mac keeps a per-host default working directory + shell for every remote
# machine (MachineSettingsStore, keyed by relay device id or host:port), edits
# them from the chooser row menu (promptHostSettings), and applies them to NEW
# remote windows (cwd + shell) and to new tabs/splits on a remote window
# (shell ONLY - the cwd inherits from the parent pane). Windows had no store at
# all. This drives the REAL GUI and a REAL loopback agent and asserts:
#
#   A. the store + editor
#      1. the row menu now leads with "Host Settings..." (mac's order);
#      2. it opens a two-field dialog: a working-directory EDIT and an
#         EDITABLE shell COMBOBOX carrying the 6 presets, with Save/Cancel;
#      3. Enter and Escape while the drop-down is OPEN belong to the LIST -
#         they must not save/cancel the dialog behind it;
#      4. Cancel writes nothing;
#      5. Save writes the key + both values, keyed on the DEVICE ID;
#      6. reopening seeds both fields from the store;
#      7. clearing both fields removes the entry (no blank rows).
#
#   B. where the defaults apply, against a loopback ghoztty-agent
#      8. a NEW remote window with no flags starts in the stored cwd with the
#         stored shell (proven by a before/after shell-banner flip, so it does
#         not assume what the box default is);
#      9. explicit --working-directory beats the store;
#      10. a +split on that window takes the stored SHELL but keeps the
#          PARENT's live cwd (the mac rule: a per-host default cwd must not
#          yank a split away from its parent).
#
#   powershell -NoProfile -File test\win32\host-settings.ps1
#
# Mechanics mirror chooser-menu.ps1: T86-hardened foreground grab, then real
# SendInput keystrokes and mouse_event clicks; EDIT/COMBOBOX contents are read
# with WM_GETTEXT, never GetWindowTextW (which reads USER32's cross-process
# cache and would pass against a control the app sees as unchanged). The run
# ABORTS-to-SKIP if another window owns the foreground. Only touches ghoztty
# processes from this repo's zig-out, and the store is redirected to a scratch
# file via GHOSTTY_HOST_DEFAULTS so the real settings are never touched.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [int]$DirPort = 47941,
    [int]$AgentPort = 47942
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
if (-not (Test-Path $AgentExe)) { $AgentExe = Join-Path $repo 'zig-out\bin\ghoztty-agent.exe' }

$tmp = Join-Path $env:TEMP "ghoztty-hs-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$storeFile = Join-Path $tmp 'host_defaults.json'
$storeDir = Join-Path $tmp 't174-store'
$otherDir = Join-Path $tmp 't174-elsewhere'
New-Item -ItemType Directory -Force $storeDir | Out-Null
New-Item -ItemType Directory -Force $otherDir | Out-Null

Add-Type @'
using System;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
public class HsDrv {
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
    [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint data, IntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr hMenu);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuStringW(IntPtr hMenu, uint id, StringBuilder sb, int max, uint flags);
    [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr hMenu, uint id, uint flags);
    [DllImport("user32.dll")] public static extern short VkKeyScanW(char ch);
    [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }

    // A control's REAL contents. A cross-process GetWindowTextW returns
    // USER32's cached window text, which is not the control's buffer (the T176
    // trap); WM_GETTEXT is marshaled to the control itself. Works for an EDIT
    // and for a COMBOBOX (which forwards to its inner edit).
    public static string TextOf(IntPtr h) {
        var sb = new StringBuilder(1024);
        SendMessageW(h, 0x000D, (IntPtr)1024, sb); // WM_GETTEXT
        return sb.ToString();
    }

    // "text|left|top|right|bottom|visible" for every `cls` child.
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

    // A DIRECT child of `parent` only. EnumChildWindows walks every
    // descendant, and an editable COMBOBOX owns an inner EDIT - without the
    // parentage filter, "the dialog's first Edit" could be the combo's.
    public static IntPtr FindChild(IntPtr parent, string cls, int nth) {
        IntPtr found = IntPtr.Zero;
        int seen = 0;
        EnumChildWindows(parent, (h, l) => {
            if (GetParent(h) != parent) return true;
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

    // The live items of the open popup menu ("SEP" for a separator).
    // MN_GETHMENU (0x01E1) turns the "#32768" popup WINDOW into the HMENU
    // behind it - the only way to read a menu the app built privately.
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
    // a modal popup already owns input (raising would dismiss it).
    public static void Press(IntPtr win, ushort vk, bool raise) {
        if (raise) GrabForeground(win);
        Key(vk, false); Thread.Sleep(25); Key(vk, true);
        Thread.Sleep(90);
    }

    public static void PressN(IntPtr win, ushort vk, int n) {
        GrabForeground(win);
        for (int i = 0; i < n; i++) { Key(vk, false); Thread.Sleep(8); Key(vk, true); Thread.Sleep(8); }
        Thread.Sleep(80);
    }

    // Type arbitrary text with REAL keystrokes, resolving each character to a
    // vk + shift state for the active layout (so ':' and '\' work, which a
    // letters-only typer could not do). SetWindowTextW is deliberately not
    // used: only the injected path proves the field's contents reach the save.
    public static void Type(IntPtr win, string s) {
        GrabForeground(win);
        foreach (char c in s) {
            short r = VkKeyScanW(c);
            if (r == -1) continue;
            ushort vk = (ushort)(r & 0xFF);
            bool shift = ((r >> 8) & 1) != 0;
            if (shift) Key(0x10, false);
            Key(vk, false); Thread.Sleep(10); Key(vk, true);
            if (shift) Key(0x10, true);
            Thread.Sleep(14);
        }
        Thread.Sleep(120);
    }

    public static void Click(int x, int y, bool right) {
        SetCursorPos(x, y);
        Thread.Sleep(60);
        uint down = right ? 0x0008u : 0x0002u;
        uint up = right ? 0x0010u : 0x0004u;
        mouse_event(down, 0, 0, 0, IntPtr.Zero);
        Thread.Sleep(40);
        mouse_event(up, 0, 0, 0, IntPtr.Zero);
        Thread.Sleep(250);
    }
}
'@
[void][HsDrv]::SetProcessDPIAware()

function Get-Controls($parent, $cls) {
    foreach ($row in [HsDrv]::ChildInfo($parent, $cls)) {
        $f = $row -split '\|'
        [pscustomobject]@{
            Text = $f[0]; Left = [int]$f[1]; Top = [int]$f[2]
            Right = [int]$f[3]; Bottom = [int]$f[4]; Visible = ([int]$f[5] -eq 1)
        }
    }
}

# The management button: the detail-pane button sharing the "New Window" row,
# to its right. Found by geometry - its label is a non-ASCII ellipsis glyph.
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
        $h = [HsDrv]::FindByClass($cls)
        if ($h -ne [IntPtr]::Zero) { return $h }
        Start-Sleep -Milliseconds 25
    }
    return [IntPtr]::Zero
}

function Stop-DebugGhoztty {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
}

function Get-Store {
    if (Test-Path $storeFile) { return (Get-Content $storeFile -Raw) }
    return ''
}

# Open the chooser's Host Settings dialog for the currently selected row via
# the "..." button, and return its HWND (IntPtr.Zero on failure).
#
# Retried twice: a single injected click can be swallowed while the desktop is
# busy, and "the menu did not open this instant" is a harness flake, not a
# product claim - every product claim in this script is asserted on the dialog
# and the store AFTER it is open.
function Open-HostSettings($chooser) {
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        [void][HsDrv]::GrabForeground($chooser)
        Start-Sleep -Milliseconds 300
        $mb = Get-MenuButton $chooser
        if (-not $mb -or -not $mb.Visible) { continue }
        [HsDrv]::Click([int](($mb.Left + $mb.Right) / 2), [int](($mb.Top + $mb.Bottom) / 2), $false)
        $popup = Wait-Window '#32768' 2000
        if ($popup -eq [IntPtr]::Zero) { continue }
        [HsDrv]::Press($popup, [uint16]0x28, $false) # DOWN -> Host Settings...
        [HsDrv]::Press($popup, [uint16]0x0D, $false) # ENTER
        $dlg = Wait-Window 'GhozttyHostSettings' 2500
        if ($dlg -ne [IntPtr]::Zero) { return $dlg }
    }
    return [IntPtr]::Zero
}

# --- read-only fake relay device directory -----------------------------------
$hitFile = Join-Path $tmp 'hits.txt'
$dirJob = Start-Job -ScriptBlock {
    param($port, $hitFile)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
    $listener.Start()
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
            for ($i = 0; $i -lt 40; $i++) {
                if ($stream.DataAvailable) {
                    $n = $stream.Read($buf, 0, $buf.Length)
                    [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $n))
                    if ($sb.ToString() -match "`r`n`r`n") { break }
                }
                Start-Sleep -Milliseconds 25
            }
            Add-Content -Path $hitFile -Value (($sb.ToString() -split "`r`n")[0])
            Send $stream '200 OK' '{"devices":[{"id":"dev-e2e","name":"E2E-Box","hostname":"e2e.local","online":true}]}'
        } catch {}
        $client.Close()
    }
} -ArgumentList $DirPort, $hitFile
Start-Sleep -Milliseconds 700

# The fake directory MUST be listening before the GUI opens, or the chooser
# degrades to a Local-only list and section A has no device row to manage. A
# port still held by a previous run is box state, so say SKIP - never let it
# read as a product failure.
$dirUp = $false
for ($t = 0; $t -lt 20 -and -not $dirUp; $t++) {
    try {
        $probe = New-Object Net.Sockets.TcpClient
        $probe.Connect('127.0.0.1', $DirPort)
        $dirUp = $probe.Connected
        $probe.Close()
    } catch { Start-Sleep -Milliseconds 250 }
}
if (-not $dirUp) {
    "  SKIP whole run: the fake relay directory never came up on port $DirPort (port in use?)"
    $script:skip++
    Stop-Job $dirJob -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $dirJob -Force -ErrorAction SilentlyContinue | Out-Null
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    "ALL PASS (0 assertions, 1 skipped)"
    exit 0
}

# --- launch a debug GUI signed in via the env token, store redirected --------
Stop-DebugGhoztty
$env:GHOSTTY_HOST_DEFAULTS = $storeFile
$env:GHOSTTY_RELAY_BASE = "http://127.0.0.1:$DirPort"
$env:GHOSTTY_RELAY_TOKEN = 'faketoken-e2e'
$env:GHOSTTY_ACCOUNT_STORE = (Join-Path $tmp 'account.dat')
$errlog = Join-Path $tmp 'stderr.log'
$proc = Start-Process -FilePath $Exe -ArgumentList '--session-persistence=false' -PassThru -RedirectStandardError $errlog
foreach ($k in 'GHOSTTY_RELAY_BASE', 'GHOSTTY_RELAY_TOKEN', 'GHOSTTY_ACCOUNT_STORE') {
    Remove-Item "env:$k" -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 3

"== A: the store + the Host Settings editor"
if ($proc.HasExited) {
    "SETUP FAIL: GUI died at launch"
    $script:fail++
} else {
    $top = [HsDrv]::FindTop([uint32]$proc.Id)
    $surface = [HsDrv]::FindWindowExW($top, [IntPtr]::Zero, 'GhozttyTerminal', $null)
    if ($top -eq [IntPtr]::Zero -or $surface -eq [IntPtr]::Zero) {
        "SETUP FAIL: GhozttyWindow/GhozttyTerminal not found"
        $script:fail++
    } else {
        $r = [HsDrv]::Chord($top, $surface, @([uint16]0x11, [uint16]0x10), [uint16]0x4E) # ctrl+shift+n
        if ($r -like 'ABORT*') {
            "  SKIP host-settings GUI drive: $r"
            $script:skip++
        } else {
            $chooser = Wait-Window 'GhozttyMachineChooser' 3500
            Assert ($chooser -ne [IntPtr]::Zero) 'chooser opened'
            if ($chooser -ne [IntPtr]::Zero) {
                [void][HsDrv]::GrabForeground($chooser)
                Start-Sleep -Milliseconds 350
                # onto the relay device row (Local is selected on open)
                [HsDrv]::Press($chooser, [uint16]0x28, $false)
                Start-Sleep -Milliseconds 250

                # --- (1) the menu now leads with Host Settings...
                $mb = Get-MenuButton $chooser
                Assert ($null -ne $mb -and $mb.Visible) 'management button shown on the device row'
                if ($mb -and $mb.Visible) {
                    [HsDrv]::Click([int](($mb.Left + $mb.Right) / 2), [int](($mb.Top + $mb.Bottom) / 2), $false)
                    $popup = Wait-Window '#32768' 2000
                    Assert ($popup -ne [IntPtr]::Zero) 'the management button opens a popup menu'
                    if ($popup -ne [IntPtr]::Zero) {
                        $items = @([HsDrv]::MenuItems($popup))
                        $want = @('Host Settings...', 'SEP', 'Rename...', 'SEP', 'Remove from Account...')
                        Assert (($items -join '|') -eq ($want -join '|')) `
                            "menu is Host Settings | Rename | Remove (got: $($items -join ' | '))"
                        Assert ($items[0] -eq 'Host Settings...') 'Host Settings... leads the menu (mac order)'
                        [HsDrv]::Press($popup, [uint16]0x1B, $false)
                        Start-Sleep -Milliseconds 300
                    }
                }

                # --- (2) the dialog and its two fields
                $dlg = Open-HostSettings $chooser
                Assert ($dlg -ne [IntPtr]::Zero) 'Host Settings... opens the editor'
                if ($dlg -ne [IntPtr]::Zero) {
                    $caption = New-Object Text.StringBuilder 256
                    [void][HsDrv]::GetWindowTextW($dlg, $caption, 256)
                    Assert ($caption.ToString() -like '*E2E-Box*') `
                        "the caption names the machine (got '$($caption.ToString())')"
                    $wd = [HsDrv]::FindChild($dlg, 'Edit', 0)
                    $combo = [HsDrv]::FindChild($dlg, 'ComboBox', 0)
                    Assert ($wd -ne [IntPtr]::Zero) 'there is a working-directory field'
                    Assert ($combo -ne [IntPtr]::Zero) 'the shell field is an editable combo box'
                    $btns = @(Get-Controls $dlg 'Button')
                    Assert (@($btns | Where-Object { $_.Text -eq 'Save' }).Count -eq 1) `
                        "the affirmative button says Save (got: $(($btns | ForEach-Object { $_.Text }) -join ', '))"
                    Assert (@($btns | Where-Object { $_.Text -eq 'Cancel' }).Count -eq 1) 'the dialog offers Cancel'
                    $labels = @(Get-Controls $dlg 'Static' | ForEach-Object { $_.Text })
                    Assert (($labels -join ' ') -like '*Working directory:*') 'the working-directory row is labeled'
                    Assert (($labels -join ' ') -like '*Shell:*') 'the shell row is labeled'
                    Assert (($labels -join ' ') -like "*remote machine*") 'the dialog says the values are remote-native'

                    if ($combo -ne [IntPtr]::Zero) {
                        $CB_GETCOUNT = 0x0146
                        $n = [int][HsDrv]::SendMessageW($combo, $CB_GETCOUNT, [IntPtr]::Zero, [IntPtr]::Zero)
                        Assert ($n -eq 6) "the shell combo carries the 6 presets (got $n)"
                    }
                    Assert ([HsDrv]::TextOf($wd) -eq '') 'the working-directory field starts empty (no stored default)'
                    Assert ([HsDrv]::TextOf($combo) -eq '') 'the shell field starts empty (no stored default)'

                    # --- (3) Enter / Escape belong to the OPEN drop-down
                    [void][HsDrv]::GrabForeground($dlg)
                    [HsDrv]::Press($dlg, [uint16]0x09, $false) # TAB: wd -> shell
                    [HsDrv]::Press($dlg, [uint16]0x73, $false) # F4: drop the list
                    Start-Sleep -Milliseconds 250
                    $CB_GETDROPPEDSTATE = 0x0157
                    $dropped = [int][HsDrv]::SendMessageW($combo, $CB_GETDROPPEDSTATE, [IntPtr]::Zero, [IntPtr]::Zero)
                    Assert ($dropped -ne 0) 'F4 opens the shell drop-down'
                    [HsDrv]::Press($dlg, [uint16]0x1B, $false) # ESCAPE
                    Start-Sleep -Milliseconds 250
                    Assert ([HsDrv]::FindByClass('GhozttyHostSettings') -ne [IntPtr]::Zero) `
                        'Escape closed the drop-down, NOT the dialog behind it'

                    [HsDrv]::Press($dlg, [uint16]0x73, $false) # F4 again
                    Start-Sleep -Milliseconds 200
                    [HsDrv]::Press($dlg, [uint16]0x28, $false) # DOWN -> first preset
                    [HsDrv]::Press($dlg, [uint16]0x0D, $false) # ENTER commits the LIST
                    Start-Sleep -Milliseconds 250
                    Assert ([HsDrv]::FindByClass('GhozttyHostSettings') -ne [IntPtr]::Zero) `
                        'Enter committed the drop-down, NOT the dialog'
                    Assert ([HsDrv]::TextOf($combo) -eq 'cmd.exe') `
                        "picking the first preset fills the field with cmd.exe (got '$([HsDrv]::TextOf($combo))')"

                    # --- (4) Cancel writes nothing
                    [HsDrv]::Press($dlg, [uint16]0x1B, $true) # ESCAPE (list closed)
                    Start-Sleep -Milliseconds 400
                    Assert ([HsDrv]::FindByClass('GhozttyHostSettings') -eq [IntPtr]::Zero) 'Escape closed the dialog'
                    Assert ((Get-Store) -notmatch 'dev-e2e') 'cancelling wrote nothing to the store'
                }

                # --- (5) Save writes both values, keyed on the device id
                $dlg = Open-HostSettings $chooser
                Assert ($dlg -ne [IntPtr]::Zero) 'the editor reopens'
                if ($dlg -ne [IntPtr]::Zero) {
                    $wd = [HsDrv]::FindChild($dlg, 'Edit', 0)
                    $combo = [HsDrv]::FindChild($dlg, 'ComboBox', 0)
                    [HsDrv]::Type($dlg, 'C:\t174-wd')
                    Assert ([HsDrv]::TextOf($wd) -eq 'C:\t174-wd') `
                        "typing lands in the working-directory field (got '$([HsDrv]::TextOf($wd))')"
                    [HsDrv]::Press($dlg, [uint16]0x09, $false) # TAB -> shell
                    [HsDrv]::Type($dlg, 'wsl.exe')
                    Assert ([HsDrv]::TextOf($combo) -eq 'wsl.exe') `
                        "free text is accepted in the shell combo (got '$([HsDrv]::TextOf($combo))')"
                    [HsDrv]::Press($dlg, [uint16]0x0D, $true) # ENTER saves
                    Start-Sleep -Milliseconds 600
                    Assert ([HsDrv]::FindByClass('GhozttyHostSettings') -eq [IntPtr]::Zero) 'Enter saved and closed the dialog'
                    $store = Get-Store
                    Assert ($store -match '"key"\s*:\s*"dev-e2e"') 'the store is keyed on the relay DEVICE ID'
                    Assert ($store -match 'C:\\\\t174-wd') "the stored working directory round-tripped (store: $($store -replace '\s+', ' '))"
                    Assert ($store -match '"shell"\s*:\s*"wsl.exe"') 'the stored shell round-tripped'
                }

                # --- (6) reopening seeds both fields from the store
                $dlg = Open-HostSettings $chooser
                Assert ($dlg -ne [IntPtr]::Zero) 'the editor reopens after a save'
                if ($dlg -ne [IntPtr]::Zero) {
                    $wd = [HsDrv]::FindChild($dlg, 'Edit', 0)
                    $combo = [HsDrv]::FindChild($dlg, 'ComboBox', 0)
                    Assert ([HsDrv]::TextOf($wd) -eq 'C:\t174-wd') `
                        "the working-directory field is seeded from the store (got '$([HsDrv]::TextOf($wd))')"
                    Assert ([HsDrv]::TextOf($combo) -eq 'wsl.exe') `
                        "the shell field is seeded from the store (got '$([HsDrv]::TextOf($combo))')"

                    # --- (7) clearing both fields removes the entry
                    [HsDrv]::Press($dlg, [uint16]0x23, $false)   # END
                    [HsDrv]::PressN($dlg, [uint16]0x08, 24)      # BACKSPACE x24
                    [HsDrv]::Press($dlg, [uint16]0x09, $false)   # TAB -> shell
                    [HsDrv]::Press($dlg, [uint16]0x23, $false)   # END
                    [HsDrv]::PressN($dlg, [uint16]0x08, 24)
                    Assert ([HsDrv]::TextOf($wd) -eq '') 'the working-directory field was cleared'
                    Assert ([HsDrv]::TextOf($combo) -eq '') 'the shell field was cleared'
                    [HsDrv]::Press($dlg, [uint16]0x0D, $true)    # ENTER saves the empties
                    Start-Sleep -Milliseconds 600
                    Assert ((Get-Store) -notmatch 'dev-e2e') 'clearing both fields removed the entry (no blank rows)'
                }

                [HsDrv]::Press($chooser, [uint16]0x1B, $true)
                Start-Sleep -Milliseconds 400
                Assert ([HsDrv]::FindByClass('GhozttyMachineChooser') -eq [IntPtr]::Zero) 'Escape closed the chooser'
            }
            Assert (-not $proc.HasExited) 'app survived the whole editor flow'
        }
    }
}

# --- B: where the defaults apply, against a real loopback agent --------------
""
"== B: applying the defaults (loopback agent)"

function Get-PaneNames {
    cmd /c "`"$Exe`" +list --json > `"$tmp\list.json`" 2>&1" | Out-Null
    $json = Get-Content "$tmp\list.json" -Raw
    $names = @()
    foreach ($m in [regex]::Matches($json, '"name":"([^"]*)"')) {
        if ($m.Groups[1].Value -ne '') { $names += $m.Groups[1].Value }
    }
    $names
}
function Read-Pane($name, $file) {
    cmd /c "`"$Exe`" +read --name=$name --lines=40 > `"$tmp\$file`" 2>&1" | Out-Null
    Get-Content "$tmp\$file" -Raw
}
# Write the store by hand rather than through ConvertTo-Json + Set-Content:
# PS 5.1's -Encoding utf8 emits a BOM, which a JSON parser rejects - the store
# would silently read as empty and the section would "pass" for the wrong
# reason. Backslashes are doubled for JSON.
function Set-HostDefault($key, $wd, $shell) {
    $j = '{"hosts":[{"key":"' + ($key -replace '\\', '\\') + '"'
    if ($wd) { $j += ',"working_directory":"' + ($wd -replace '\\', '\\') + '"' }
    if ($shell) { $j += ',"shell":"' + ($shell -replace '\\', '\\') + '"' }
    $j += '}]}'
    [IO.File]::WriteAllText($storeFile, $j, (New-Object Text.UTF8Encoding $false))
}

$agentKey = "127.0.0.1:$AgentPort"
$env:GHOSTTY_AGENT_LOCK = Join-Path $tmp 'agent.lock'
$agent = Start-Process -FilePath $AgentExe -ArgumentList "--listen", "127.0.0.1:$AgentPort", "--headless" -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2
Assert (-not $agent.HasExited) 'loopback agent is running'

if ($proc.HasExited -or $agent.HasExited) {
    "  SKIP section B: no app or no agent"
    $script:skip++
} else {
    # `--name` on +new-remote-window registers the WINDOW; the new pane's own
    # name is auto-generated, so it is found as the delta in +list.
    function New-RemotePane($winName, $extraArg, $file) {
        $before = @(Get-PaneNames)
        cmd /c "`"$Exe`" +new-remote-window --host=127.0.0.1 --port=$AgentPort --name=$winName $extraArg > `"$tmp\$file`" 2>&1"
        $code = $LASTEXITCODE
        Start-Sleep -Seconds 3
        $new = @(@(Get-PaneNames) | Where-Object { $before -notcontains $_ })
        [pscustomobject]@{ Exit = $code; Pane = $(if ($new.Count -eq 1) { $new[0] } else { $null }) }
    }

    # --- (8a) baseline: no stored defaults for this host
    Remove-Item $storeFile -ErrorAction SilentlyContinue
    $a = New-RemotePane 'remA' '' 'openA.txt'
    Assert ($a.Exit -eq 0) 'baseline remote window opened (no stored defaults)'
    Assert ($null -ne $a.Pane) 'baseline remote pane discovered'
    $baseline = ''
    if ($a.Pane) { $baseline = Read-Pane $a.Pane 'readA.txt' }
    $baseIsCmd = ($baseline -match 'Microsoft Windows \[Version')
    $baseIsPwsh = ($baseline -match 'PS [A-Za-z]:' -or $baseline -match 'Windows PowerShell')
    Assert ($baseIsCmd -or $baseIsPwsh) `
        "the baseline pane's shell is identifiable from its banner/prompt (cmd=$baseIsCmd pwsh=$baseIsPwsh)"

    # Pick the OTHER shell, so the assertion proves the STORE changed it rather
    # than matching whatever this box defaults to.
    if ($baseIsCmd) {
        $storeShell = 'powershell.exe'
        $shellMarker = 'PS [A-Za-z]:|Windows PowerShell'
    } else {
        $storeShell = 'cmd.exe'
        $shellMarker = 'Microsoft Windows \[Version'
    }
    "  (baseline shell is $(if ($baseIsCmd) { 'cmd' } else { 'powershell' }); the store will ask for $storeShell)"

    # --- (8b) a NEW remote window takes the stored cwd AND shell
    Set-HostDefault $agentKey $storeDir $storeShell
    $b = New-RemotePane 'remB' '' 'openB.txt'
    Assert ($b.Exit -eq 0) 'remote window opened with stored defaults in place'
    Assert ($null -ne $b.Pane) 'remote pane discovered'
    if ($b.Pane) {
        $dumpB = Read-Pane $b.Pane 'readB.txt'
        Assert ($dumpB -match $shellMarker) `
            "the new window used the stored SHELL ($storeShell), flipping the baseline banner"
        Assert ($dumpB -like '*t174-store*') 'the new window started in the stored working directory'
    }

    # --- (9) explicit flags beat the store
    $c = New-RemotePane 'remC' "`"--working-directory=$otherDir`"" 'openC.txt'
    Assert ($c.Exit -eq 0) 'remote window opened with an explicit --working-directory'
    if ($c.Pane) {
        $dumpC = Read-Pane $c.Pane 'readC.txt'
        Assert ($dumpC -like '*t174-elsewhere*') 'an explicit --working-directory beats the stored default'
        Assert (-not ($dumpC -like '*t174-store*')) 'the stored cwd did not leak into the explicit open'
    }

    # --- (10a) a split on a remote window takes the stored SHELL
    $beforeSplit = @(Get-PaneNames)
    cmd /c "`"$Exe`" +split --target=remB --name=remS --direction=right > `"$tmp\split.txt`" 2>&1"
    Assert ($LASTEXITCODE -eq 0) 'split on the remote window exit 0'
    Start-Sleep -Seconds 3
    $splitPane = @(@(Get-PaneNames) | Where-Object { $beforeSplit -notcontains $_ })
    Assert ($splitPane -contains 'remS') "the split pane is registered as remS (new: $($splitPane -join ', '))"
    if ($splitPane -contains 'remS') {
        $dumpS = Read-Pane 'remS' 'readS.txt'
        Assert ($dumpS -match $shellMarker) "the split used the stored SHELL ($storeShell)"
    }

    # --- (10b) ...but keeps the PARENT's live cwd, NOT the stored one.
    # This half needs a shell whose `cd` moves the OS process cwd, because the
    # inheritance is a GET_CWD on the live child: PowerShell's Set-Location
    # deliberately does NOT (5.1 keeps the process directory put), so the store
    # asks for cmd.exe here regardless of what the box defaults to.
    Set-HostDefault $agentKey $storeDir 'cmd.exe'
    $d = New-RemotePane 'remD' '' 'openD.txt'
    Assert ($d.Exit -eq 0) 'cmd-shell remote window opened for the cwd half'
    if ($d.Pane) {
        $dumpD = Read-Pane $d.Pane 'readD.txt'
        Assert ($dumpD -like '*t174-store*') 'the cmd window also started in the stored cwd'
        # +send-keys translates escapes in its text, so every backslash must be
        # doubled: `...\t174-elsewhere` would otherwise arrive as a literal TAB
        # (`\t`) and cmd would tab-complete something else entirely - the cd
        # silently would not happen and the split assertion below would blame
        # the product.
        $sendPath = $otherDir -replace '\\', '\\'
        & $Exe +send-keys --target=remD "cd $sendPath" Enter 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        # Prove the parent actually moved before asking where its split lands.
        $dumpD2 = Read-Pane $d.Pane 'readD2.txt'
        Assert ($dumpD2 -like '*t174-elsewhere>*') `
            "the parent pane really cd'd (its prompt moved to t174-elsewhere)"
        $beforeSplit2 = @(Get-PaneNames)
        cmd /c "`"$Exe`" +split --target=remD --name=remS2 --direction=right > `"$tmp\split2.txt`" 2>&1"
        Assert ($LASTEXITCODE -eq 0) 'split on the cmd-shell remote window exit 0'
        Start-Sleep -Seconds 3
        $splitPane2 = @(@(Get-PaneNames) | Where-Object { $beforeSplit2 -notcontains $_ })
        Assert ($splitPane2 -contains 'remS2') "the second split pane is registered (new: $($splitPane2 -join ', '))"
        if ($splitPane2 -contains 'remS2') {
            $dumpS2 = Read-Pane 'remS2' 'readS2.txt'
            Assert ($dumpS2 -like '*t174-elsewhere*') "the split kept the PARENT's live cwd"
            Assert (-not ($dumpS2 -like '*t174-store*')) `
                'the stored cwd did NOT yank the split away from its parent (mac rule)'
        }
    }

    Assert (-not $proc.HasExited) 'app survived the whole apply flow'
    Assert (-not $agent.HasExited) 'agent survived the whole apply flow'
}

# --- teardown ---------------------------------------------------------------
Stop-DebugGhoztty
Stop-Job $dirJob -ErrorAction SilentlyContinue | Out-Null
Remove-Job $dirJob -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "env:GHOSTTY_HOST_DEFAULTS" -ErrorAction SilentlyContinue
Remove-Item "env:GHOSTTY_AGENT_LOCK" -ErrorAction SilentlyContinue

""
if ($script:fail -gt 0 -and $env:HS_DEBUG) {
    "--- app stderr ---"
    Select-String -Path $errlog -Pattern 'host settings|host defaults|machine chooser|remote' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Line }
    "--- store ---"
    Get-Store
} else {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:fail -eq 0) {
    "ALL PASS ($($script:pass) assertions, $($script:skip) skipped)"
} else {
    "$($script:fail) FAILURE(S) ($($script:pass) passed, $($script:skip) skipped)"
}
