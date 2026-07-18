# T80 acceptance: the light MessageBoxW prompts are replaced by the dark
# ConfirmDialog (T50 pattern, class 'GhozttyConfirmDialog').
#
# Covered sites + semantics:
#   1. ctrl+w (close_surface with a live cmd.exe) -> surface close confirm:
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
# Only touches ghoztty processes running from this repo's zig-out.
param([string]$ExePath)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
public class CfmDrv {
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern int MapWindowPoints(IntPtr from, IntPtr to, ref RECT r, uint points);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, UIntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public KEYBDINPUT ki; public ulong pad; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    public static void BeDpiAware() {
        SetProcessDpiAwarenessContext((IntPtr)(-4)); // PER_MONITOR_AWARE_V2
    }

    public static IntPtr FindClass(uint pid, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h)) {
                var sb = new StringBuilder(64);
                GetClassNameW(h, sb, 64);
                if (sb.ToString() == cls) { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static IntPtr FindChild(IntPtr top, string cls) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(top, (h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString() == cls && IsWindowVisible(h)) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // Visible palette popup: top-level owned GhozttyTerminal (WS_POPUP).
    public static IntPtr FindPalettePopup(uint pid, IntPtr top) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && h != top && IsWindowVisible(h)) {
                var sb = new StringBuilder(64);
                GetClassNameW(h, sb, 64);
                if (sb.ToString() == "GhozttyTerminal") { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // Client rect of h in SCREEN coordinates.
    public static int[] ClientOnScreen(IntPtr h) {
        RECT r; GetClientRect(h, out r);
        MapWindowPoints(h, IntPtr.Zero, ref r, 2);
        return new int[] { r.left, r.top, r.right, r.bottom };
    }

    static void Key(ushort vk, bool up) {
        var i = new INPUT[1];
        i[0].type = 1;
        i[0].ki.wVk = vk;
        i[0].ki.dwFlags = up ? 2u : 0u;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void Press(ushort vk) {
        Key(vk, false); Thread.Sleep(30); Key(vk, true);
    }

    // Send mods+vk with focus on `surface`. Returns "SENT" or a reason.
    public static string Chord(IntPtr top, IntPtr surface, ushort[] mods, ushort vk) {
        uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
        uint cur = GetCurrentThreadId();
        bool fg = false;
        for (int attempt = 0; attempt < 5 && !fg; attempt++) {
            SetForegroundWindow(top);
            Thread.Sleep(150 + attempt * 200);
            fg = (GetForegroundWindow() == top);
        }
        if (!fg) return "ABORT: could not foreground";
        if (!AttachThreadInput(cur, tid, true)) return "ATTACH FAILED";
        try {
            SetFocus(surface);
            Thread.Sleep(60);
            if (GetForegroundWindow() != top) return "ABORT: foreground lost";
            foreach (var m in mods) Key(m, false);
            Thread.Sleep(20);
            Key(vk, false); Thread.Sleep(20); Key(vk, true);
            Thread.Sleep(20);
            for (int j = mods.Length - 1; j >= 0; j--) Key(mods[j], true);
            Thread.Sleep(100);
            return "SENT";
        } finally { AttachThreadInput(cur, tid, false); }
    }

    // Type plain VKs into `edit` in one attachment burst.
    public static string TypeKeys(IntPtr owner, IntPtr edit, ushort[] vks) {
        uint pid; uint tid = GetWindowThreadProcessId(owner, out pid);
        uint cur = GetCurrentThreadId();
        if (!AttachThreadInput(cur, tid, true)) return "ATTACH FAILED";
        try {
            SetFocus(edit);
            Thread.Sleep(60);
            foreach (var vk in vks) {
                Key(vk, false); Thread.Sleep(15); Key(vk, true); Thread.Sleep(30);
            }
            Thread.Sleep(100);
            return "SENT";
        } finally { AttachThreadInput(cur, tid, false); }
    }
}
'@
[CfmDrv]::BeDpiAware()

function Kill-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

# Average brightness (0-255) of a screen rect, 8px inset, 4px grid.
function Get-RectBrightness([int[]]$r) {
    $w = $r[2] - $r[0] - 16
    $h = $r[3] - $r[1] - 16
    if ($w -le 0 -or $h -le 0) { return -1 }
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r[0] + 8, $r[1] + 8, 0, 0, $bmp.Size)
    $g.Dispose()
    $sum = 0.0; $n = 0
    for ($y = 0; $y -lt $h; $y += 4) {
        for ($x = 0; $x -lt $w; $x += 4) {
            $c = $bmp.GetPixel($x, $y)
            $sum += (0.2126 * $c.R + 0.7152 * $c.G + 0.0722 * $c.B)
            $n++
        }
    }
    $bmp.Dispose()
    if ($n -eq 0) { return -1 }
    return [int]($sum / $n)
}

# Wait for a visible GhozttyConfirmDialog in $gpid (or its disappearance).
function Wait-Dialog([uint32]$gpid, [bool]$appear, [int]$tries = 30) {
    for ($t = 0; $t -lt $tries; $t++) {
        $d = [CfmDrv]::FindClass($gpid, 'GhozttyConfirmDialog')
        $vis = ($d -ne [IntPtr]::Zero)
        if ($vis -eq $appear) { return $d }
        Start-Sleep -Milliseconds 100
    }
    if ($appear) { return [IntPtr]::Zero } else { return $d }
}

function Launch-Gui {
    $proc = Start-Process -FilePath $exe -PassThru
    Start-Sleep -Seconds 3
    if ($proc.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top = [CfmDrv]::FindClass([uint32]$proc.Id, 'GhozttyWindow')
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; Stop-Process -Id $proc.Id -Force; exit 1 }
    $surface = [CfmDrv]::FindChild($top, 'GhozttyTerminal')
    if ($surface -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: surface not found'; Stop-Process -Id $proc.Id -Force; exit 1 }
    return @{ Proc = $proc; Top = $top; Surface = $surface }
}

$VK_CTRL = [uint16]0x11; $VK_SHIFT = [uint16]0x10
$VK_RETURN = [uint16]0x0D; $VK_ESCAPE = [uint16]0x1B; $VK_TAB = [uint16]0x09
$VK_W = [uint16]0x57; $VK_P = [uint16]0x50

Kill-RepoInstances

# ---------------------------------------------------------------- case 1:
# surface close confirm (ctrl+w with live cmd.exe).
$g = Launch-Gui
$gpid = [uint32]$g.Proc.Id

$r = [CfmDrv]::Chord($g.Top, $g.Surface, @($VK_CTRL), $VK_W)
if ($r -ne 'SENT') { Write-Host "SETUP FAIL: ctrl+w not injected ($r)"; Stop-Process -Id $gpid -Force; exit 1 }
$dlg = Wait-Dialog $gpid $true
Assert ($dlg -ne [IntPtr]::Zero) 'ctrl+w opens the surface close confirm dialog'
if ($dlg -eq [IntPtr]::Zero) { Stop-Process -Id $gpid -Force; exit 1 }

Start-Sleep -Milliseconds 300   # let it finish painting
$b = Get-RectBrightness ([CfmDrv]::ClientOnScreen($dlg))
Assert ($b -ge 0 -and $b -lt 90) "close confirm renders dark (avg $b < 90)"

[CfmDrv]::Press($VK_ESCAPE)
$gone = Wait-Dialog $gpid $false
Assert ($gone -eq [IntPtr]::Zero) 'Escape dismisses the dialog'
Assert (-not $g.Proc.HasExited -and [CfmDrv]::IsWindowVisible($g.Top)) 'Escape cancels: window stays open'

# Enter on the default button must CANCEL (MB_DEFBUTTON2 parity).
$r = [CfmDrv]::Chord($g.Top, $g.Surface, @($VK_CTRL), $VK_W)
$dlg = Wait-Dialog $gpid $true
Assert ($dlg -ne [IntPtr]::Zero) 'second ctrl+w reopens the dialog'
if ($dlg -ne [IntPtr]::Zero) {
    [CfmDrv]::Press($VK_RETURN)
    $gone = Wait-Dialog $gpid $false
    Assert ($gone -eq [IntPtr]::Zero) 'Enter (default) dismisses the dialog'
    Assert (-not $g.Proc.HasExited -and [CfmDrv]::IsWindowVisible($g.Top)) 'Enter defaults to Cancel: window stays open'
}

# Tab moves focus to OK; Enter then approves -> last pane closes the window.
$r = [CfmDrv]::Chord($g.Top, $g.Surface, @($VK_CTRL), $VK_W)
$dlg = Wait-Dialog $gpid $true
Assert ($dlg -ne [IntPtr]::Zero) 'third ctrl+w reopens the dialog'
if ($dlg -ne [IntPtr]::Zero) {
    [CfmDrv]::Press($VK_TAB)
    Start-Sleep -Milliseconds 100
    [CfmDrv]::Press($VK_RETURN)
    $closed = $false
    for ($t = 0; $t -lt 50; $t++) {
        Start-Sleep -Milliseconds 100
        if (-not [CfmDrv]::IsWindow($g.Top) -or -not [CfmDrv]::IsWindowVisible($g.Top)) { $closed = $true; break }
    }
    Assert $closed 'Tab+Enter approves: window closes'
}
Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

# ---------------------------------------------------------------- case 2:
# window-level aggregate close confirm (title-bar X -> WM_CLOSE).
$g = Launch-Gui
$gpid = [uint32]$g.Proc.Id
[void][CfmDrv]::PostMessageW($g.Top, 0x0010, [UIntPtr]::Zero, [IntPtr]::Zero) # WM_CLOSE
$dlg = Wait-Dialog $gpid $true
Assert ($dlg -ne [IntPtr]::Zero) 'WM_CLOSE (title-bar X) opens the window close confirm'
if ($dlg -ne [IntPtr]::Zero) {
    Start-Sleep -Milliseconds 300
    $b = Get-RectBrightness ([CfmDrv]::ClientOnScreen($dlg))
    Assert ($b -ge 0 -and $b -lt 90) "window close confirm renders dark (avg $b < 90)"
    [CfmDrv]::Press($VK_ESCAPE)
    $gone = Wait-Dialog $gpid $false
    Assert ($gone -eq [IntPtr]::Zero) 'Escape dismisses the window close confirm'
    Assert (-not $g.Proc.HasExited -and [CfmDrv]::IsWindowVisible($g.Top)) 'window survives the cancelled X-close'
}

# ---------------------------------------------------------------- case 3:
# About box via the command palette (OK-only + info icon), same GUI.
$r = [CfmDrv]::Chord($g.Top, $g.Surface, @($VK_CTRL, $VK_SHIFT), $VK_P)
if ($r -ne 'SENT') { Write-Host "SETUP FAIL: ctrl+shift+p not injected ($r)"; Stop-Process -Id $gpid -Force; exit 1 }
$popup = [IntPtr]::Zero
for ($t = 0; $t -lt 30; $t++) {
    Start-Sleep -Milliseconds 100
    $popup = [CfmDrv]::FindPalettePopup($gpid, $g.Top)
    if ($popup -ne [IntPtr]::Zero) { break }
}
Assert ($popup -ne [IntPtr]::Zero) 'command palette opens via ctrl+shift+p'
if ($popup -ne [IntPtr]::Zero) {
    $edit = [CfmDrv]::FindChild($popup, 'Edit')
    Assert ($edit -ne [IntPtr]::Zero) 'palette search edit found'
    if ($edit -ne [IntPtr]::Zero) {
        # Type "about" then Enter to run "About Ghoztty".
        $vks = [uint16[]]@(0x41, 0x42, 0x4F, 0x55, 0x54, $VK_RETURN) # A B O U T Enter
        $r = [CfmDrv]::TypeKeys($g.Top, $edit, $vks)
        Assert ($r -eq 'SENT') "palette keys typed ($r)"
        $dlg = Wait-Dialog $gpid $true
        Assert ($dlg -ne [IntPtr]::Zero) 'About Ghoztty dialog opens from the palette'
        if ($dlg -ne [IntPtr]::Zero) {
            Start-Sleep -Milliseconds 300
            $b = Get-RectBrightness ([CfmDrv]::ClientOnScreen($dlg))
            Assert ($b -ge 0 -and $b -lt 90) "About box renders dark (avg $b < 90)"
            [CfmDrv]::Press($VK_RETURN)   # OK-only: Enter dismisses
            $gone = Wait-Dialog $gpid $false
            Assert ($gone -eq [IntPtr]::Zero) 'Enter dismisses the About box'
            Assert (-not $g.Proc.HasExited) 'no crash after About round-trip'
        }
    }
}

Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue
Kill-RepoInstances
Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
