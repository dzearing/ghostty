# T69 acceptance: config load diagnostics are surfaced in a visible dialog
# (class 'GhozttyConfirmDialog', T80 pattern) instead of only log.err —
# which a GUI-subsystem release build sends nowhere.
#
# Covered:
#   1. Startup with a broken config -> the Configuration Errors dialog
#        appears, renders DARK, carries the custom button captions
#        ("Open Config" / "Ignore"), and Escape (=Ignore) dismisses it
#        with the terminal window staying up.
#   2. Startup with a clean config -> NO dialog.
#   3. reload_config (ctrl+shift+comma) after the file turns bad -> the
#        dialog appears (same path as startup); after fixing the file, a
#        second reload shows nothing. Positive control: ctrl+shift+r must
#        open (and Escape close) the rename dialog first, proving chord
#        injection works before any negative is trusted.
#
# Config isolation: XDG_CONFIG_HOME points at a temp dir for every launch
# (xdg.zig prefers it over LOCALAPPDATA), so the box's real config never
# leaks into these asserts and the script never touches it.
#
# A dialog that never appears after a verified chord is a product FAIL;
# a chord whose positive control fails is a SETUP FAIL.
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
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class CfgDrv {
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern int MapWindowPoints(IntPtr from, IntPtr to, ref RECT r, uint points);
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

    // Captions of all BUTTON children, in z-order.
    public static string[] ButtonTexts(IntPtr top) {
        var texts = new List<string>();
        EnumChildWindows(top, (h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString() == "Button" || sb.ToString() == "BUTTON") {
                var tb = new StringBuilder(128);
                GetWindowTextW(h, tb, 128);
                texts.Add(tb.ToString());
            }
            return true;
        }, IntPtr.Zero);
        return texts.ToArray();
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
}
'@
[CfgDrv]::BeDpiAware()

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

# Wait for a visible window of $cls in $gpid (or its disappearance).
function Wait-Class([uint32]$gpid, [string]$cls, [bool]$appear, [int]$tries = 30) {
    for ($t = 0; $t -lt $tries; $t++) {
        $d = [CfgDrv]::FindClass($gpid, $cls)
        $vis = ($d -ne [IntPtr]::Zero)
        if ($vis -eq $appear) { return $d }
        Start-Sleep -Milliseconds 100
    }
    if ($appear) { return [IntPtr]::Zero } else { return $d }
}

# Isolated config home for every launch in this script.
$cfgHome = Join-Path $env:TEMP 'ghoztty-t69-xdg'
$cfgDir = Join-Path $cfgHome 'ghostty'
New-Item -ItemType Directory -Force $cfgDir | Out-Null
$cfgFile = Join-Path $cfgDir 'config'

$BAD_CONFIG = "not-a-real-key = 1`nbackground = notacolor`n"
$GOOD_CONFIG = "# valid on purpose`nwindow-height = 30`n"

function Launch-Gui {
    $env:XDG_CONFIG_HOME = $cfgHome
    try { $proc = Start-Process -FilePath $exe -PassThru }
    finally { Remove-Item Env:XDG_CONFIG_HOME -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 3
    if ($proc.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top = [CfgDrv]::FindClass([uint32]$proc.Id, 'GhozttyWindow')
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; Stop-Process -Id $proc.Id -Force; exit 1 }
    return @{ Proc = $proc; Top = $top }
}

$VK_CTRL = [uint16]0x11; $VK_SHIFT = [uint16]0x10
$VK_ESCAPE = [uint16]0x1B
$VK_R = [uint16]0x52; $VK_OEM_COMMA = [uint16]0xBC

Kill-RepoInstances

# ---------------------------------------------------------------- case 1:
# broken config at startup -> dialog with custom captions, Escape ignores.
Set-Content -Path $cfgFile -Value $BAD_CONFIG -Encoding ascii
$g = Launch-Gui
$gpid = [uint32]$g.Proc.Id

$dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 80
Assert ($dlg -ne [IntPtr]::Zero) 'broken config at startup shows the Configuration Errors dialog'
if ($dlg -eq [IntPtr]::Zero) { Stop-Process -Id $gpid -Force; exit 1 }

Start-Sleep -Milliseconds 300   # let it finish painting
$b = Get-RectBrightness ([CfgDrv]::ClientOnScreen($dlg))
Assert ($b -ge 0 -and $b -lt 90) "config errors dialog renders dark (avg $b < 90)"

$btns = [CfgDrv]::ButtonTexts($dlg)
Assert (($btns -contains 'Open Config') -and ($btns -contains 'Ignore')) "buttons are Open Config / Ignore (got: $($btns -join ', '))"

# Escape = Ignore: dialog goes away, terminal window survives.
[CfgDrv]::Press($VK_ESCAPE)
$gone = Wait-Class $gpid 'GhozttyConfirmDialog' $false
Assert ($gone -eq [IntPtr]::Zero) 'Escape (Ignore) dismisses the dialog'
Start-Sleep -Milliseconds 300
Assert (-not $g.Proc.HasExited -and [CfgDrv]::IsWindowVisible($g.Top)) 'app keeps running with remaining settings'
Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

# ---------------------------------------------------------------- case 2:
# clean config at startup -> no dialog.
Set-Content -Path $cfgFile -Value $GOOD_CONFIG -Encoding ascii
$g = Launch-Gui
$gpid = [uint32]$g.Proc.Id

$dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 15
Assert ($dlg -eq [IntPtr]::Zero) 'clean config at startup shows no dialog'

# ---------------------------------------------------------------- case 3:
# reload_config picks up a newly-broken file (same instance as case 2).
$surface = [CfgDrv]::FindChild($g.Top, 'GhozttyTerminal')
if ($surface -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: surface not found'; Stop-Process -Id $gpid -Force; exit 1 }

# Positive control: chord injection must demonstrably work before any
# negative below can be trusted. ctrl+shift+r opens the rename dialog.
$r = [CfgDrv]::Chord($g.Top, $surface, @($VK_CTRL, $VK_SHIFT), $VK_R)
if ($r -ne 'SENT') { Write-Host "SETUP FAIL: control chord not injected ($r)"; Stop-Process -Id $gpid -Force; exit 1 }
$ren = Wait-Class $gpid 'GhozttyRenameDialog' $true
if ($ren -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: positive control (rename dialog) did not open'; Stop-Process -Id $gpid -Force; exit 1 }
[CfgDrv]::Press($VK_ESCAPE)
$ren = Wait-Class $gpid 'GhozttyRenameDialog' $false
if ($ren -ne [IntPtr]::Zero) { Write-Host 'SETUP FAIL: positive control dialog stuck open'; Stop-Process -Id $gpid -Force; exit 1 }
Write-Host 'OK    positive control: chords reach the app'

Set-Content -Path $cfgFile -Value $BAD_CONFIG -Encoding ascii
$r = [CfgDrv]::Chord($g.Top, $surface, @($VK_CTRL, $VK_SHIFT), $VK_OEM_COMMA)
if ($r -ne 'SENT') { Write-Host "SETUP FAIL: reload chord not injected ($r)"; Stop-Process -Id $gpid -Force; exit 1 }
$dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 50
Assert ($dlg -ne [IntPtr]::Zero) 'reload_config on a broken file shows the dialog'
if ($dlg -ne [IntPtr]::Zero) {
    [CfgDrv]::Press($VK_ESCAPE)
    $gone = Wait-Class $gpid 'GhozttyConfirmDialog' $false
    Assert ($gone -eq [IntPtr]::Zero) 'Escape dismisses the reload dialog'
}

# Fix the file; a second reload must stay silent.
Set-Content -Path $cfgFile -Value $GOOD_CONFIG -Encoding ascii
$r = [CfgDrv]::Chord($g.Top, $surface, @($VK_CTRL, $VK_SHIFT), $VK_OEM_COMMA)
if ($r -ne 'SENT') { Write-Host "SETUP FAIL: second reload chord not injected ($r)"; Stop-Process -Id $gpid -Force; exit 1 }
$dlg = Wait-Class $gpid 'GhozttyConfirmDialog' $true 15
Assert ($dlg -eq [IntPtr]::Zero) 'reload_config on a fixed file shows no dialog'
Assert (-not $g.Proc.HasExited) 'app alive at the end'

Stop-Process -Id $gpid -Force -ErrorAction SilentlyContinue
Kill-RepoInstances
Remove-Item -Recurse -Force $cfgHome -ErrorAction SilentlyContinue

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" }
else { Write-Host "$script:fail FAILURE(S), $script:pass pass" }
