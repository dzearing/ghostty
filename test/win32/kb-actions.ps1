# Keyboard-action acceptance: drives REAL key chords into the debug build's
# surface HWND and asserts GUI-side behavior.
#
#   T50: ctrl+shift+r opens the real "Rename Window" dialog (caption, edit
#        prefilled, OK/Cancel, owner-centered, owner disabled); Enter
#        commits via titleOverride (wins over shell titles, T10), Escape
#        cancels, empty text clears the override. Supersedes the T44
#        rename-edit assertions (no crash in a single-tab window).
#   T47: ctrl+k clears the primary screen (+ scrollback); on the alternate
#        screen the performable binding is unconsumed and falls through.
#
# Mechanics: SetForegroundWindow + AttachThreadInput + SetFocus(surface)
# then a short SendInput burst. Foreground is verified immediately before
# each injection and the test ABORTS (not fails) if another window owns
# it, so keystrokes can never leak into other apps. Run on an idle desktop
# for reliable results.
#
# Only touches ghoztty processes running from this repo's zig-out.
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
$errlog = Join-Path $env:TEMP "ghoztty-kb-actions-stderr.log"
Remove-Item $errlog -ErrorAction SilentlyContinue

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

Add-Type @'
using System;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
public class KbDrv {
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr w, string l);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder sb, int max);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int L; public int T; public int R; public int B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public KEYBDINPUT ki; public ulong pad; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    public delegate bool EnumProc(IntPtr h, IntPtr l);

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

    static void Key(ushort vk, bool up) {
        var i = new INPUT[1];
        i[0].type = 1;
        i[0].ki.wVk = vk;
        i[0].ki.dwFlags = up ? 2u : 0u;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }

    // Send mods+vk to the surface. Returns "SENT" or an ABORT/failure reason.
    public static string Chord(IntPtr top, IntPtr surface, ushort[] mods, ushort vk) {
        uint pid; uint tid = GetWindowThreadProcessId(top, out pid);
        uint cur = GetCurrentThreadId();
        SetForegroundWindow(top);
        Thread.Sleep(150);
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

    // The "Rename Window" dialog is a top-level popup of its own class.
    public static IntPtr FindDialog() {
        return FindWindowExW(IntPtr.Zero, IntPtr.Zero, "GhozttyRenameDialog", null);
    }

    // Send ctrl+shift+r and wait for the rename dialog to appear.
    public static string OpenRenameDialog(IntPtr top, IntPtr surface) {
        string r = Chord(top, surface, new ushort[] { 0x11, 0x10 }, 0x52); // ctrl+shift+r
        if (r != "SENT") return r;
        for (int t = 0; t < 100; t++) {
            Thread.Sleep(10);
            if (FindDialog() != IntPtr.Zero) return "OPEN";
        }
        return "NO DIALOG within 1s";
    }

    public static string WindowText(IntPtr h) {
        var sb = new StringBuilder(512);
        GetWindowTextW(h, sb, 512);
        return sb.ToString();
    }

    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);

    // Deterministic direct-child lookup by class name (case-insensitive).
    // Avoids FindWindowExW's title-matching ambiguity when the title arg is
    // a PowerShell $null (which marshals to "" and only matches empty
    // titles) — the dialog's edit is prefilled, so it has a non-empty title.
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    public static IntPtr ChildByClass(IntPtr parent, string cls) {
        IntPtr c = GetWindow(parent, 5); // GW_CHILD
        while (c != IntPtr.Zero) {
            var sb = new StringBuilder(64);
            GetClassNameW(c, sb, 64);
            if (string.Equals(sb.ToString(), cls, StringComparison.OrdinalIgnoreCase))
                return c;
            c = GetWindow(c, 2); // GW_HWNDNEXT
        }
        return IntPtr.Zero;
    }

    public static string DumpChildren(IntPtr parent) {
        var outp = new StringBuilder();
        EnumChildWindows(parent, (h, l) => {
            var cls = new StringBuilder(64); GetClassNameW(h, cls, 64);
            var txt = new StringBuilder(128); GetWindowTextW(h, txt, 128);
            outp.AppendLine("  " + h.ToString("X") + "  class=[" + cls + "]  text=[" + txt + "]");
            return true;
        }, IntPtr.Zero);
        return outp.ToString();
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr w, StringBuilder sb);

    // GetWindowTextW cannot read another process's edit control - WM_GETTEXT
    // is marshaled cross-process for standard controls.
    public static string ControlText(IntPtr h) {
        var sb = new StringBuilder(512);
        SendMessageW(h, 0x000D, (IntPtr)512, sb); // WM_GETTEXT
        return sb.ToString();
    }
}
'@

# --- Setup: fresh debug instance with stderr captured -----------------------
Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
    Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out\*') } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

$proc = Start-Process -FilePath $exe -PassThru -RedirectStandardError $errlog
Start-Sleep -Seconds 3
if ($proc.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
$top = [KbDrv]::FindTop([uint32]$proc.Id)
$surface = [KbDrv]::FindWindowExW($top, [IntPtr]::Zero, 'GhozttyTerminal', $null)
if ($top -eq [IntPtr]::Zero -or $surface -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: windows not found'; exit 1 }

$listJson = & $exe +list --json | ConvertFrom-Json
$pane = $listJson.data.windows[0].tabs[0].splits.terminal.name
$win = $listJson.data.windows[0].target

# --- T50: "Rename Window" dialog (supersedes the T44 rename-edit path) ------
$r = [KbDrv]::OpenRenameDialog($top, $surface)
if ($r -like 'ABORT*') { Write-Host "SKIP T50: $r"; }
else {
    Assert ($r -eq 'OPEN') "T50 dialog opened on ctrl+shift+r ($r)"
    Assert (-not $proc.HasExited) 'T50 no crash after ctrl+shift+r (single tab)'
    $dlg = [KbDrv]::FindDialog()
    if ($dlg -ne [IntPtr]::Zero) {
        Assert ([KbDrv]::WindowText($dlg) -eq 'Rename Window') 'T50 dialog caption is "Rename Window"'
        $edit = [KbDrv]::ChildByClass($dlg, 'Edit')
        $okBtn = [KbDrv]::FindWindowExW($dlg, [IntPtr]::Zero, 'BUTTON', 'OK')
        $cancelBtn = [KbDrv]::FindWindowExW($dlg, [IntPtr]::Zero, 'BUTTON', 'Cancel')
        Assert ($edit -ne [IntPtr]::Zero) 'T50 dialog has an edit box'
        Assert ($okBtn -ne [IntPtr]::Zero) 'T50 dialog has an OK button'
        Assert ($cancelBtn -ne [IntPtr]::Zero) 'T50 dialog has a Cancel button'
        Assert (-not [KbDrv]::IsWindowEnabled($top)) 'T50 owner window disabled while dialog open (modal)'
        $dr = New-Object KbDrv+RECT; $tr = New-Object KbDrv+RECT
        [KbDrv]::GetWindowRect($dlg, [ref]$dr) | Out-Null
        [KbDrv]::GetWindowRect($top, [ref]$tr) | Out-Null
        $dcx = ($dr.L + $dr.R) / 2; $tcx = ($tr.L + $tr.R) / 2
        $dcy = ($dr.T + $dr.B) / 2; $tcy = ($tr.T + $tr.B) / 2
        Assert (([Math]::Abs($dcx - $tcx) -le 3) -and ([Math]::Abs($dcy - $tcy) -le 3)) 'T50 dialog centered on owner'

        # Enter commits via titleOverride.
        [KbDrv]::SendMessageW($edit, 0x000C, [IntPtr]::Zero, 'KBTEST_TITLE') | Out-Null  # WM_SETTEXT
        [KbDrv]::PostMessageW($edit, 0x0100, [IntPtr]0x0D, [IntPtr]0x001C0001) | Out-Null # Enter
        Start-Sleep -Milliseconds 500
        Assert ([KbDrv]::FindDialog() -eq [IntPtr]::Zero) 'T50 dialog closed on Enter'
        Assert (-not $proc.HasExited) 'T50 no crash after commit'
        Assert ([KbDrv]::IsWindowEnabled($top)) 'T50 owner re-enabled after close'
        $list = & $exe +list --json | Out-String
        Assert ($list -match 'KBTEST_TITLE') 'T50 window title committed (visible in +list)'

        # titleOverride precedence (T10): a shell-set title updates the TAB
        # label but the window caption keeps the override.
        & $exe +send-keys --target=$win "title SHELLSET_TITLE" Enter | Out-Null
        Start-Sleep -Seconds 2
        $listJson2 = & $exe +list --json | ConvertFrom-Json
        $tabTitle = $listJson2.data.windows[0].tabs[0].title
        if ($tabTitle -notmatch 'SHELLSET_TITLE') { Write-Host 'SKIP T50-precedence: shell title did not land' }
        else {
            Assert ([KbDrv]::WindowText($top) -match 'KBTEST_TITLE') 'T50 override beats shell title (T10 precedence)'
        }

        # Reopen: edit prefilled with the current override; Escape cancels
        # without applying.
        $r2 = [KbDrv]::OpenRenameDialog($top, $surface)
        if ($r2 -like 'ABORT*') { Write-Host "SKIP T50-cancel: $r2" }
        else {
            Assert ($r2 -eq 'OPEN') "T50 dialog reopened ($r2)"
            $dlg2 = [KbDrv]::FindDialog()
            $edit2 = [KbDrv]::ChildByClass($dlg2, 'Edit')
            Assert ([KbDrv]::ControlText($edit2) -eq 'KBTEST_TITLE') 'T50 edit prefilled with current title'
            [KbDrv]::SendMessageW($edit2, 0x000C, [IntPtr]::Zero, 'SHOULD_NOT_APPLY') | Out-Null
            [KbDrv]::PostMessageW($edit2, 0x0100, [IntPtr]0x1B, [IntPtr]0x00010001) | Out-Null # Escape
            Start-Sleep -Milliseconds 500
            Assert ([KbDrv]::FindDialog() -eq [IntPtr]::Zero) 'T50 dialog closed on Escape'
            $list3 = & $exe +list --json | Out-String
            Assert (($list3 -match 'KBTEST_TITLE') -and ($list3 -notmatch 'SHOULD_NOT_APPLY')) 'T50 Escape discarded the edit'
            Assert ([KbDrv]::IsWindowEnabled($top)) 'T50 owner re-enabled after cancel'
        }

        # Reopen: empty text clears the override (reverts to shell title).
        $r3 = [KbDrv]::OpenRenameDialog($top, $surface)
        if ($r3 -like 'ABORT*') { Write-Host "SKIP T50-clear: $r3" }
        else {
            $dlg3 = [KbDrv]::FindDialog()
            $edit3 = [KbDrv]::ChildByClass($dlg3, 'Edit')
            [KbDrv]::SendMessageW($edit3, 0x000C, [IntPtr]::Zero, '') | Out-Null
            [KbDrv]::PostMessageW($edit3, 0x0100, [IntPtr]0x0D, [IntPtr]0x001C0001) | Out-Null # Enter
            Start-Sleep -Milliseconds 500
            Assert ([KbDrv]::FindDialog() -eq [IntPtr]::Zero) 'T50 dialog closed on empty commit'
            Assert ([KbDrv]::WindowText($top) -notmatch 'KBTEST_TITLE') 'T50 empty text cleared the override'
        }
    }
}

# --- T47: ctrl+k clears primary screen ---------------------------------------
& $exe +send-keys --target=$win "dir C:\Windows\System32\drivers& echo KBFILL_MARKER" Enter | Out-Null
Start-Sleep -Seconds 2
$before = & $exe +read --name=$pane --lines=40 | Out-String
if ($before -notmatch 'KBFILL_MARKER') { Write-Host 'SKIP T47: fill did not land'; }
else {
    $r = [KbDrv]::Chord($top, $surface, @([uint16]0x11), 0x4B)  # ctrl+k
    if ($r -like 'ABORT*') { Write-Host "SKIP T47: $r" }
    else {
        Start-Sleep -Milliseconds 800
        Assert (-not $proc.HasExited) 'T47 no crash after ctrl+k'
        $after = & $exe +read --name=$pane --lines=40 | Out-String
        Assert ($after -notmatch 'KBFILL_MARKER') 'T47 primary screen cleared'
        Assert ((Select-String -Path $errlog -Pattern 'mailbox message=clear_screen' -Quiet)) 'T47 clear_screen io message logged'

        # Alternate screen: the performable binding must be unconsumed.
        & $exe +send-keys --target=$win "powershell -nop -c `"[console]::Write([char]27+'[?1049h')`"" Enter | Out-Null
        Start-Sleep -Seconds 3
        $clearsBefore = (Select-String -Path $errlog -Pattern 'mailbox message=clear_screen' -AllMatches | Measure-Object).Count
        $r2 = [KbDrv]::Chord($top, $surface, @([uint16]0x11), 0x4B)
        if ($r2 -like 'ABORT*') { Write-Host "SKIP T47-alt: $r2" }
        else {
            Start-Sleep -Milliseconds 800
            Assert (-not $proc.HasExited) 'T47 no crash after alt-screen ctrl+k'
            $clearsAfter = (Select-String -Path $errlog -Pattern 'mailbox message=clear_screen' -AllMatches | Measure-Object).Count
            Assert ($clearsAfter -eq $clearsBefore) 'T47 alt screen: clear_screen NOT consumed (fell through)'
        }
    }
}

# --- Teardown ----------------------------------------------------------------
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILED / $script:pass passed" -ForegroundColor Red; exit 1 }
