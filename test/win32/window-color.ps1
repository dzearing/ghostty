# T67 acceptance: window/pane background tint (`--color` / `--split-color`)
# + split-inheritance shift + context-menu "Background Color..." picker.
#
# Oracles:
#   - `+list --json` panes carry an additive `background_tint` (#rrggbb)
#     field when tinted (absent otherwise).
#   - A screen-pixel probe at the pane center must read ~= the tint (proves
#     the color reaches the glass, not just the data model).
#   - The plain-split inheritance value is pinned exactly: #334455 parent
#     -> #384b5e child (the color_math.zig unit-test oracle, Mac
#     shiftedTint parity: HSB brightness +5% toward white on dark parents).
#   - Picker: right-click menu -> "B" mnemonic -> ChooseColorW (comdlg
#     #32770) -> Enter accepts the CC_RGBINIT initial color (= the pane's
#     effective background) -> the untinted launch window gains an explicit
#     tint equal to the configured background.
#
# Only touches ghoztty processes running from this repo's zig-out*.
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

Add-Type @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
public class ColorDrv {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] public static extern uint GetPixel(IntPtr dc, int x, int y);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUTK { public uint type; public KEYBDINPUT ki; public ulong pad; }
    [DllImport("user32.dll", EntryPoint = "SendInput")] public static extern uint SendInputK(uint n, INPUTK[] inputs, int size);

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUTM { public uint type; public MOUSEINPUT mi; }
    [DllImport("user32.dll", EntryPoint = "SendInput")] public static extern uint SendInputM(uint n, INPUTM[] inputs, int size);

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

    // Visible GhozttyTerminal children: "left,top,right,bottom" lines.
    public static string[] Panes(IntPtr top) {
        var lines = new List<string>();
        EnumChildWindows(top, (h, l) => {
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString() == "GhozttyTerminal" && IsWindowVisible(h)) {
                RECT r; GetWindowRect(h, out r);
                lines.Add(r.left + "," + r.top + "," + r.right + "," + r.bottom);
            }
            return true;
        }, IntPtr.Zero);
        return lines.ToArray();
    }

    // Any visible standard dialog (#32770, ChooseColorW) owned by pid?
    public static bool HasDialog(uint pid) {
        bool found = false;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p != pid || !IsWindowVisible(h)) return true;
            var sb = new StringBuilder(64);
            GetClassNameW(h, sb, 64);
            if (sb.ToString() == "#32770") { found = true; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // Composited screen pixel as "r,g,b".
    public static string ScreenPixel(int x, int y) {
        IntPtr dc = GetDC(IntPtr.Zero);
        uint c = GetPixel(dc, x, y); // COLORREF 0x00BBGGRR
        ReleaseDC(IntPtr.Zero, dc);
        return (c & 0xFF) + "," + ((c >> 8) & 0xFF) + "," + ((c >> 16) & 0xFF);
    }

    public static void Key(ushort vk, bool up) {
        var i = new INPUTK[1];
        i[0].type = 1;
        i[0].ki.wVk = vk;
        i[0].ki.dwFlags = up ? 2u : 0u;
        SendInputK(1, i, Marshal.SizeOf(typeof(INPUTK)));
    }

    public static void RightClick() {
        var i = new INPUTM[1];
        i[0].type = 0;
        i[0].mi.dwFlags = 0x0008; // RIGHTDOWN
        SendInputM(1, i, Marshal.SizeOf(typeof(INPUTM)));
        Thread.Sleep(60);
        i[0].mi.dwFlags = 0x0010; // RIGHTUP
        SendInputM(1, i, Marshal.SizeOf(typeof(INPUTM)));
    }

    public static string Foreground(IntPtr top) {
        uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
        uint cur = GetCurrentThreadId();
        SetForegroundWindow(top);
        Thread.Sleep(200);
        if (!AttachThreadInput(cur, tid, true)) return "ATTACH FAILED";
        AttachThreadInput(cur, tid, false);
        if (GetForegroundWindow() != top) return "NOT FOREGROUND";
        return "OK";
    }
}
'@

function Kill-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

# +list --json -> the window object registered under $target, or (with an
# 'id:<hwnd>' argument) the window whose id matches — window ids are the
# decimal HWND, so a window found via FindTop can be addressed exactly.
function Get-Win($target) {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    $data = ($json | ConvertFrom-Json).data
    foreach ($w in $data.windows) {
        if ($target -like 'id:*') { if ($w.id -eq $target.Substring(3)) { return $w } }
        elseif ($w.target -eq $target) { return $w }
    }
    return $null
}

# All leaf terminals of a splits node, in traversal order.
function Get-Leaves($node) {
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    return @(Get-Leaves $node.left) + @(Get-Leaves $node.right)
}

# Poll for a pane tint: window $target, leaf index $i, expected value (or
# 'ANY' for present, 'NONE' for absent). Returns the observed value.
function Wait-Tint($target, [int]$i, [string]$expect) {
    for ($t = 0; $t -lt 25; $t++) {
        $w = Get-Win $target
        if ($w) {
            $leaves = @(Get-Leaves $w.tabs[0].splits)
            if ($leaves.Count -gt $i) {
                $tint = $leaves[$i].background_tint
                if ($expect -eq 'NONE' -and -not $tint) { return '(absent)' }
                if ($expect -eq 'ANY' -and $tint) { return $tint }
                if ($tint -eq $expect) { return $tint }
            }
        }
        Start-Sleep -Milliseconds 200
    }
    $w = Get-Win $target
    if ($w) {
        $leaves = @(Get-Leaves $w.tabs[0].splits)
        if ($leaves.Count -gt $i -and $leaves[$i].background_tint) { return $leaves[$i].background_tint }
    }
    return '(absent)'
}

# Poll the composited pixel at fraction (fx,fy) of the FOREGROUND window's
# pane area until within $tol per channel of $hex. Returns "r,g,b".
function Wait-Pixel([IntPtr]$top, [double]$fx, [double]$fy, [string]$hex, [int]$tol = 8) {
    $er = [Convert]::ToInt32($hex.Substring(1, 2), 16)
    $eg = [Convert]::ToInt32($hex.Substring(3, 2), 16)
    $eb = [Convert]::ToInt32($hex.Substring(5, 2), 16)
    $px = ''
    for ($t = 0; $t -lt 25; $t++) {
        $panes = @([ColorDrv]::Panes($top))
        if ($panes.Count -ge 1) {
            $c = $panes[0] -split ','
            $x = [int]([int]$c[0] + ([int]$c[2] - [int]$c[0]) * $fx)
            $y = [int]([int]$c[1] + ([int]$c[3] - [int]$c[1]) * $fy)
            $px = [ColorDrv]::ScreenPixel($x, $y)
            $p = $px -split ','
            if ([math]::Abs([int]$p[0] - $er) -le $tol -and
                [math]::Abs([int]$p[1] - $eg) -le $tol -and
                [math]::Abs([int]$p[2] - $eb) -le $tol) { return $px }
        }
        Start-Sleep -Milliseconds 200
    }
    return $px
}

Kill-RepoInstances

# Launch the GUI with a pinned config background so the picker section has
# a deterministic effective (untinted) background.
$proc = Start-Process $exe -ArgumentList '--background=#101014' -PassThru
Start-Sleep -Seconds 3
if ($proc.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
$launchTop = [ColorDrv]::FindTop([uint32]$proc.Id)
if ($launchTop -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: launch window not found'; exit 1 }

# --- 1. +new-window --color tints the first pane (model + glass) ---------
& $exe +new-window --target=cw --color=`#334455 | Out-Null
$tint = Wait-Tint 'cw' 0 '#334455'
Assert ($tint -eq '#334455') "new-window --color: background_tint reported (got $tint)"

$cwTop = [ColorDrv]::FindTop([uint32]$proc.Id)
$px = Wait-Pixel $cwTop 0.7 0.6 '#334455'
Assert ($px -eq '51,68,85') "new-window --color: screen pixel is the tint (got $px)"

# --- 2. plain +split inherits the shifted parent tint (exact oracle) -----
& $exe +split --target=cw --name=cp1 | Out-Null
$tint = Wait-Tint 'cw' 1 '#384b5e'
Assert ($tint -eq '#384b5e') "plain split: inherits #334455 shifted -> #384b5e (got $tint)"

# --- 3. +split --color explicit tint -------------------------------------
& $exe +split --pane=cp1 --name=cp2 --color=`#803020 | Out-Null
$tint = Wait-Tint 'cw' 2 '#803020'
Assert ($tint -eq '#803020') "split --color: explicit tint wins (got $tint)"

# --- 4. inline split: --split-color explicit, first pane untinted --------
& $exe +new-window --target=cw2 --split=right --split-color=`#204060 --name=cp3 | Out-Null
$tint = Wait-Tint 'cw2' 1 '#204060'
Assert ($tint -eq '#204060') "inline split --split-color applied (got $tint)"
$tint = Wait-Tint 'cw2' 0 'NONE'
Assert ($tint -eq '(absent)') "no --color: first pane reports no tint (got $tint)"

# --- 5. --color=random: dark muted color ---------------------------------
& $exe +new-window --target=cw3 --color=random | Out-Null
$tint = Wait-Tint 'cw3' 0 'ANY'
Assert ($tint -match '^#[0-9a-f]{6}$') "random: well-formed hex tint (got $tint)"
if ($tint -match '^#[0-9a-f]{6}$') {
    $r = [Convert]::ToInt32($tint.Substring(1, 2), 16)
    $g = [Convert]::ToInt32($tint.Substring(3, 2), 16)
    $b = [Convert]::ToInt32($tint.Substring(5, 2), 16)
    $lum = (0.299 * $r + 0.587 * $g + 0.114 * $b) / 255.0
    Assert ($lum -lt 0.2) "random: dark color (luminance $([math]::Round($lum,3)))"
}

# --- 6. invalid --color is rejected by the CLI (shared Mac behavior) -----
# (PS 5.1 wraps redirected native stderr in ErrorRecords that terminate
# under EAP=Stop, so relax EAP around the intentionally-failing call.)
$eap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $exe +new-window --target=cw4 --color=`#zzzzzz 2>$null | Out-Null
$ErrorActionPreference = $eap
Assert ($LASTEXITCODE -ne 0) 'invalid --color: CLI rejects with nonzero exit'
Assert ($null -eq (Get-Win 'cw4')) 'invalid --color: no window created'

# --- 7. context-menu picker: right-click -> "B" -> ChooseColorW -> Enter -
# The untinted LAUNCH window's effective background is the configured
# #101014; CC_RGBINIT seeds the dialog with it, Enter (OK) applies it as an
# explicit tint, observable in +list.
$fg = [ColorDrv]::Foreground($launchTop)
if ($fg -ne 'OK') {
    Write-Host "SKIP  picker section: cannot foreground launch window ($fg)"
    $script:fail++
} else {
    $panes = @([ColorDrv]::Panes($launchTop))
    $c = $panes[0] -split ','
    $x = [int](([int]$c[0] + [int]$c[2]) / 2)
    $y = [int](([int]$c[1] + [int]$c[3]) / 2)
    [ColorDrv]::SetCursorPos($x, $y) | Out-Null
    Start-Sleep -Milliseconds 150
    [ColorDrv]::RightClick()
    Start-Sleep -Milliseconds 500
    # Menu mnemonic: unique first letter executes "Background Color...".
    [ColorDrv]::Key(0x42, $false); [ColorDrv]::Key(0x42, $true)  # 'B'
    $dlg = $false
    for ($t = 0; $t -lt 20; $t++) {
        if ([ColorDrv]::HasDialog([uint32]$proc.Id)) { $dlg = $true; break }
        Start-Sleep -Milliseconds 150
    }
    Assert $dlg 'picker: ChooseColorW dialog opened from the context menu'
    if ($dlg) {
        Start-Sleep -Milliseconds 300
        [ColorDrv]::Key(0x0D, $false); [ColorDrv]::Key(0x0D, $true)  # Enter = OK
        $tint = Wait-Tint "id:$([int64]$launchTop)" 0 '#101014'
        Assert ($tint -eq '#101014') "picker: OK applies the effective background as tint (got $tint)"
    } else {
        [ColorDrv]::Key(0x1B, $false); [ColorDrv]::Key(0x1B, $true)  # Escape any stray menu
        $script:fail++
    }
}

# --- 8. app still alive and responsive -----------------------------------
$alive = -not $proc.HasExited
Assert $alive 'GUI process alive after all scenarios'
$json = (& $exe +list --json 2>$null | Out-String).Trim()
Assert ($json -match '"success":true') '+list still responds'

Kill-RepoInstances

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)"; exit 1 }
