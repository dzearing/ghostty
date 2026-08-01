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
# T218 (batch 5): migrated onto the BACKGROUND test desktop
# (test/win32/lib/TestDesktop.ps1), so the run never takes the user's
# foreground - asserted at the end, not assumed. The private win32 driver
# (HsDrv) is gone; only the HMENU reader survives, because
# GetMenuItemCount/GetMenuStringW/GetMenuState take a menu HANDLE and a menu is
# not a desktop object.
#
# What the migration changed beyond the mechanics:
#
#   * It no longer SKIPs on a busy box. The whole GUI half was wrapped in "if
#     the foreground grab aborted, SKIP", so another window owning the
#     foreground scored a green run that had asserted nothing.
#   * Dialog keys are posted at the FOCUSED control, which is what a real
#     keystroke reaches. That distinction is load-bearing here: section A(3)'s
#     whole claim is that Enter/Escape with the drop-down open belong to the
#     LIST, and HostSettingsDialog.handleKey deliberately returns false in that
#     state so the message falls through to the control (HostSettingsDialog.zig
#     :629-645). Posted at the DIALOG it would fall through to the dialog and
#     the list would never see it - the assertion would then be measuring the
#     harness, not the product.
#   * The dialog's nested modal pump (the ConfirmDialog shape) filters
#     WM_KEYDOWN for hwnds it owns and runs TranslateMessage over the rest, so
#     posted keys reach handleKey AND posted VK_BACK still becomes a WM_CHAR
#     for the edit.
#   * Section B never needed the desktop at all: it drives `+new-remote-window`
#     / `+list` / `+read` / `+send-keys` over IPC, and the only change is that
#     the app it talks to now lives on the test desktop.
#
# EDIT/COMBOBOX contents are still read with WM_GETTEXT (Get-TestControlText),
# never GetWindowTextW - which reads USER32's cross-process cache and would
# pass against a control the app sees as unchanged.
#
# -NegativeControl inverts A(6) ("the shell field is seeded from the store") to
# expect an unseeded field, which MUST fail; it is how a run proves the
# save -> reopen -> read chain still discriminates.
#
# Only touches ghoztty processes from this repo's zig-out, and the store is
# redirected to a scratch file via GHOSTTY_HOST_DEFAULTS so the real settings
# are never touched.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = 'D:\git\ghoztty\zig-out\bin\ghoztty-agent.exe',
    [int]$DirPort = 47941,
    [int]$AgentPort = 47942,
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$script:pass = 0
$script:fail = 0
$script:skip = 0
$script:negReached = $false
function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
if (-not (Test-Path $AgentExe)) { $AgentExe = Join-Path $repo 'zig-out\bin\ghoztty-agent.exe' }
# Isolate the IPC endpoint. Section B's CLI calls inherit it from this shell and
# the GUI inherits it through CreateProcessW, so both ends of every +list /
# +read / +send-keys are this run's instance and nothing else on the box.
$env:GHOZTTY_PIPE_SUFFIX = '-hstest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$tmp = Join-Path $env:TEMP "ghoztty-hs-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$storeFile = Join-Path $tmp 'host_defaults.json'
$storeDir = Join-Path $tmp 't174-store'
$otherDir = Join-Path $tmp 't174-elsewhere'
New-Item -ItemType Directory -Force $storeDir | Out-Null
New-Item -ItemType Directory -Force $otherDir | Out-Null

# HMENU reads only - these take a menu HANDLE, not a window, so they are not
# desktop-bound and run fine in this process.
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class HsMenuRead {
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuStringW(IntPtr menu, uint id, StringBuilder sb, int max, uint flags);
    [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr menu, uint id, uint flags);

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
# a control can be found by LABEL or by GEOMETRY instead of creation order.
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

# A DIRECT child of $parent only. Get-TestChildWindows walks every descendant,
# and an editable COMBOBOX owns an inner EDIT - without the parentage filter,
# "the dialog's first Edit" could be the combo's. FindWindowExW enumerates
# direct children only, which is exactly that filter.
function Get-DirectChild([IntPtr]$parent, [string]$cls) {
    return Find-TestWindowEx -Parent $parent -Class $cls
}

# The management button: the SQUARE glyph button in the detail pane's action
# row. Found by shape - its label is a non-ASCII ellipsis glyph, and "the first
# button right of New Window" stopped being it when T177 packed Activity into
# the same row.
function Get-MenuButton([IntPtr]$chooser) {
    $buttons = @(Get-Controls $chooser 'Button')
    $primary = $buttons | Where-Object { $_.Text -eq 'New Window' } | Select-Object -First 1
    if (-not $primary) { return $null }
    $sq = @($buttons |
        Where-Object {
            $_.Top -eq $primary.Top -and $_.Bottom -eq $primary.Bottom -and
            ($_.Right - $_.Left) -eq ($_.Bottom - $_.Top)
        } | Sort-Object Left)
    if ($sq.Count -eq 0) { return $null }
    return $sq[$sq.Count - 1]
}

function Click-Control([IntPtr]$window, $ctl) {
    $cx = [int](($ctl.Left + $ctl.Right) / 2)
    $cy = [int](($ctl.Top + $ctl.Bottom) / 2)
    [void](Send-TestMouse -Window $window -Target $ctl.Hwnd -X $cx -Y $cy)
}

function Get-MenuItems([IntPtr]$menuWnd) {
    $r = Invoke-TestMessage -Window $menuWnd -Message 0x01E1
    if ($r -eq [long]::MinValue -or $r -eq 0) { return @() }
    return @([HsMenuRead]::Items([IntPtr]$r))
}

# Post a key into a menu's modal loop: the loop retrieves queue messages
# regardless of target hwnd, and Send-TestControlKey posts without touching
# focus (Send-TestKeys would SetFocus first and dismiss the menu).
function Send-MenuKey([IntPtr]$w, [string]$key) {
    [void](Send-TestControlKey -Control $w -Key $key)
    Start-Sleep -Milliseconds 120
}

# A dialog key, posted at the control that REALLY has focus - see the header:
# the drop-down claims in section A(3) only mean anything if the message lands
# where a hardware keystroke would.
function Send-DlgKey([IntPtr]$dlg, [string]$key, [int]$settleMs = 150) {
    $focus = Get-TestFocusedWindow -Window $dlg
    $target = if ($focus -ne 0 -and $focus -ne [int64]0) { [IntPtr]$focus } else { $dlg }
    [void](Send-TestControlKey -Control $target -Key $key)
    Start-Sleep -Milliseconds $settleMs
}

function Send-DlgKeyN([IntPtr]$dlg, [string]$key, [int]$n) {
    $focus = Get-TestFocusedWindow -Window $dlg
    $target = if ($focus -ne 0 -and $focus -ne [int64]0) { [IntPtr]$focus } else { $dlg }
    for ($i = 0; $i -lt $n; $i++) { [void](Send-TestControlKey -Control $target -Key $key) }
    Start-Sleep -Milliseconds 200
}

# Type into whatever the dialog has focused (WM_CHAR - the standard-control
# convention; the terminal-surface convention would double every character).
function Send-DlgText([IntPtr]$dlg, [string]$text) {
    $focus = Get-TestFocusedWindow -Window $dlg
    $target = if ($focus -ne 0 -and $focus -ne [int64]0) { [IntPtr]$focus } else { $dlg }
    [void](Send-TestControlText -Control $target -Text $text)
    Start-Sleep -Milliseconds 150
}

function Stop-DebugGhoztty {
    foreach ($name in 'ghoztty.exe', 'ghoztty-agent.exe') {
        Get-CimInstance Win32_Process -Filter "Name='$name'" |
            Where-Object { $_.CommandLine -like '*zig-out*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 800
}

function Get-Store {
    if (Test-Path $storeFile) { return (Get-Content $storeFile -Raw) }
    return ''
}

# Open the chooser's Host Settings dialog for the currently selected row via
# the "..." button, and return its HWND (IntPtr.Zero on failure).
#
# Retried twice: "the menu did not open this instant" is a harness flake, not a
# product claim - every product claim in this script is asserted on the dialog
# and the store AFTER it is open.
function Open-HostSettings([IntPtr]$chooser, [int]$gpid) {
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        Start-Sleep -Milliseconds 250
        $mb = Get-MenuButton $chooser
        if (-not $mb -or -not $mb.Visible) { continue }
        Click-Control $chooser $mb
        $popup = Wait-TestPopupMenu -ProcessId $gpid -TimeoutMs 2500
        if ($popup -eq [IntPtr]::Zero) { continue }
        Send-MenuKey $chooser Down    # -> Host Settings...
        Send-MenuKey $chooser Enter
        $dlg = Wait-TestWindow -ProcessId $gpid -Class 'GhozttyHostSettings' -TimeoutMs 3000
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
    Write-Host "  SKIP whole run: the fake relay directory never came up on port $DirPort (port in use?)"
    Stop-Job $dirJob -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $dirJob -Force -ErrorAction SilentlyContinue | Out-Null
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'HOST-SETTINGS ACCEPTANCE: SETUP SKIP (0 assertions)'
    exit 1
}

$errlog = Join-Path $tmp 'stderr.log'
$agent = $null

Stop-DebugGhoztty
# Watch the user's desktop for the whole run: nothing we launch may ever take
# foreground there.
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # --- launch a debug GUI signed in via the env token, store redirected ----
    $env:GHOSTTY_HOST_DEFAULTS = $storeFile
    $env:GHOSTTY_RELAY_BASE = "http://127.0.0.1:$DirPort"
    $env:GHOSTTY_RELAY_TOKEN = 'faketoken-e2e'
    $env:GHOSTTY_ACCOUNT_STORE = (Join-Path $tmp 'account.dat')
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -StdErr $errlog
    foreach ($k in 'GHOSTTY_RELAY_BASE', 'GHOSTTY_RELAY_TOKEN', 'GHOSTTY_ACCOUNT_STORE') {
        Remove-Item "env:$k" -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3

    Write-Host '== A: the store + the Host Settings editor'
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: GhozttyWindow not found'; exit 1 }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: GhozttyTerminal not found'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'the GUI is NOT enumerable on the interactive desktop'

    [void](Send-TestKeys -Window $top -Target $surface -Modifiers ctrl, shift -Key N)
    $chooser = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000
    Assert ($chooser -ne [IntPtr]::Zero) 'chooser opened'
    if ($chooser -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no chooser to score'; exit 1 }

    Start-Sleep -Milliseconds 350
    # onto the relay device row (Local is selected on open)
    [void](Send-TestControlKey -Control $chooser -Key Down)
    Start-Sleep -Milliseconds 300

    # --- (1) the menu now leads with Host Settings...
    $mb = Get-MenuButton $chooser
    Assert ($null -ne $mb -and $mb.Visible) 'management button shown on the device row'
    if ($mb -and $mb.Visible) {
        Click-Control $chooser $mb
        $popup = Wait-TestPopupMenu -ProcessId $app.Pid -TimeoutMs 2500
        Assert ($popup -ne [IntPtr]::Zero) 'the management button opens a popup menu'
        if ($popup -ne [IntPtr]::Zero) {
            $items = Get-MenuItems $popup
            $want = @('Host Settings...', 'SEP', 'Rename...', 'SEP', 'Remove from Account...')
            Assert (($items -join '|') -eq ($want -join '|')) `
                "menu is Host Settings | Rename | Remove (got: $($items -join ' | '))"
            Assert ($items.Count -gt 0 -and $items[0] -eq 'Host Settings...') 'Host Settings... leads the menu (mac order)'
            Send-MenuKey $chooser Escape
            Start-Sleep -Milliseconds 200
        }
    }

    # --- (2) the dialog and its two fields
    $dlg = Open-HostSettings $chooser $app.Pid
    Assert ($dlg -ne [IntPtr]::Zero) 'Host Settings... opens the editor'
    if ($dlg -ne [IntPtr]::Zero) {
        $caption = Get-TestControlText -Control $dlg
        Assert ($caption -like '*E2E-Box*') "the caption names the machine (got '$caption')"
        $wd = Get-DirectChild $dlg 'Edit'
        $combo = Get-DirectChild $dlg 'ComboBox'
        Assert ($wd -ne [IntPtr]::Zero) 'there is a working-directory field'
        Assert ($combo -ne [IntPtr]::Zero) 'the shell field is an editable combo box'
        $btns = @(Get-Controls $dlg 'Button')
        Assert (@($btns | Where-Object { $_.Text -eq 'Save' }).Count -eq 1) `
            "the affirmative button says Save (got: $(($btns | ForEach-Object { $_.Text }) -join ', '))"
        Assert (@($btns | Where-Object { $_.Text -eq 'Cancel' }).Count -eq 1) 'the dialog offers Cancel'
        $labels = @(Get-Controls $dlg 'Static' | ForEach-Object { $_.Text })
        Assert (($labels -join ' ') -like '*Working directory:*') 'the working-directory row is labeled'
        Assert (($labels -join ' ') -like '*Shell:*') 'the shell row is labeled'
        Assert (($labels -join ' ') -like '*remote machine*') 'the dialog says the values are remote-native'

        if ($combo -ne [IntPtr]::Zero) {
            $CB_GETCOUNT = 0x0146
            $n = [int](Invoke-TestMessage -Window $combo -Message $CB_GETCOUNT)
            Assert ($n -eq 6) "the shell combo carries the 6 presets (got $n)"
        }
        Assert ((Get-TestControlText -Control $wd) -eq '') 'the working-directory field starts empty (no stored default)'
        Assert ((Get-TestControlText -Control $combo) -eq '') 'the shell field starts empty (no stored default)'

        # --- (3) Enter / Escape belong to the OPEN drop-down
        Send-DlgKey $dlg Tab            # wd -> shell
        Send-DlgKey $dlg F4 250         # drop the list
        $CB_GETDROPPEDSTATE = 0x0157
        $dropped = [int](Invoke-TestMessage -Window $combo -Message $CB_GETDROPPEDSTATE)
        Assert ($dropped -ne 0) 'F4 opens the shell drop-down'
        Send-DlgKey $dlg Escape 250
        Assert (Test-TestWindowExists -Window $dlg) 'Escape closed the drop-down, NOT the dialog behind it'

        Send-DlgKey $dlg F4 250         # F4 again
        Send-DlgKey $dlg Down           # -> first preset
        Send-DlgKey $dlg Enter 250      # commits the LIST
        Assert (Test-TestWindowExists -Window $dlg) 'Enter committed the drop-down, NOT the dialog'
        $comboText = Get-TestControlText -Control $combo
        Assert ($comboText -eq 'cmd.exe') "picking the first preset fills the field with cmd.exe (got '$comboText')"

        # --- (4) Cancel writes nothing
        Send-DlgKey $dlg Escape 450     # list closed, so this one is the dialog's
        Assert (-not (Test-TestWindowExists -Window $dlg)) 'Escape closed the dialog'
        Assert ((Get-Store) -notmatch 'dev-e2e') 'cancelling wrote nothing to the store'
    }

    # --- (5) Save writes both values, keyed on the device id
    $dlg = Open-HostSettings $chooser $app.Pid
    Assert ($dlg -ne [IntPtr]::Zero) 'the editor reopens'
    if ($dlg -ne [IntPtr]::Zero) {
        $wd = Get-DirectChild $dlg 'Edit'
        $combo = Get-DirectChild $dlg 'ComboBox'
        # The field opens focused with its seed selected, so typing replaces it.
        Send-DlgText $dlg 'C:\t174-wd'
        $wdText = Get-TestControlText -Control $wd
        Assert ($wdText -eq 'C:\t174-wd') "typing lands in the working-directory field (got '$wdText')"
        Send-DlgKey $dlg Tab            # -> shell
        Send-DlgText $dlg 'wsl.exe'
        $comboText = Get-TestControlText -Control $combo
        Assert ($comboText -eq 'wsl.exe') "free text is accepted in the shell combo (got '$comboText')"
        Send-DlgKey $dlg Enter 700      # saves
        Assert (-not (Test-TestWindowExists -Window $dlg)) 'Enter saved and closed the dialog'
        $store = Get-Store
        Assert ($store -match '"key"\s*:\s*"dev-e2e"') 'the store is keyed on the relay DEVICE ID'
        Assert ($store -match 'C:\\\\t174-wd') "the stored working directory round-tripped (store: $($store -replace '\s+', ' '))"
        Assert ($store -match '"shell"\s*:\s*"wsl.exe"') 'the stored shell round-tripped'
    }

    # --- (6) reopening seeds both fields from the store
    $dlg = Open-HostSettings $chooser $app.Pid
    Assert ($dlg -ne [IntPtr]::Zero) 'the editor reopens after a save'
    if ($dlg -ne [IntPtr]::Zero) {
        $wd = Get-DirectChild $dlg 'Edit'
        $combo = Get-DirectChild $dlg 'ComboBox'
        $wdText = Get-TestControlText -Control $wd
        Assert ($wdText -eq 'C:\t174-wd') "the working-directory field is seeded from the store (got '$wdText')"
        # The negative control: seeding is the visible end of the whole
        # save -> store -> reopen -> WM_GETTEXT chain, so inverting it proves
        # every link still discriminates.
        $comboText = Get-TestControlText -Control $combo
        $script:negReached = $true
        if ($NegativeControl) {
            Assert ($comboText -ne 'wsl.exe') "NEGATIVE CONTROL: the shell field is NOT seeded from the store (got '$comboText')"
        } else {
            Assert ($comboText -eq 'wsl.exe') "the shell field is seeded from the store (got '$comboText')"
        }

        # --- (7) clearing both fields removes the entry
        Send-DlgKey $dlg End 100
        Send-DlgKeyN $dlg Backspace 24
        Send-DlgKey $dlg Tab            # -> shell
        Send-DlgKey $dlg End 100
        Send-DlgKeyN $dlg Backspace 24
        Assert ((Get-TestControlText -Control $wd) -eq '') 'the working-directory field was cleared'
        Assert ((Get-TestControlText -Control $combo) -eq '') 'the shell field was cleared'
        Send-DlgKey $dlg Enter 700      # saves the empties
        Assert ((Get-Store) -notmatch 'dev-e2e') 'clearing both fields removed the entry (no blank rows)'
    }

    [void](Send-TestControlKey -Control $chooser -Key Escape)
    Start-Sleep -Milliseconds 500
    Assert (-not (Test-TestWindowExists -Window $chooser)) 'Escape closed the chooser'
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'app survived the whole editor flow'

    # --- B: where the defaults apply, against a real loopback agent ----------
    Write-Host ''
    Write-Host '== B: applying the defaults (loopback agent)'

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
    # PS 5.1's -Encoding utf8 emits a BOM, which a JSON parser rejects - the
    # store would silently read as empty and the section would "pass" for the
    # wrong reason. Backslashes are doubled for JSON.
    function Set-HostDefault($key, $wd, $shell) {
        $j = '{"hosts":[{"key":"' + ($key -replace '\\', '\\') + '"'
        if ($wd) { $j += ',"working_directory":"' + ($wd -replace '\\', '\\') + '"' }
        if ($shell) { $j += ',"shell":"' + ($shell -replace '\\', '\\') + '"' }
        $j += '}]}'
        [IO.File]::WriteAllText($storeFile, $j, (New-Object Text.UTF8Encoding $false))
    }

    $agentKey = "127.0.0.1:$AgentPort"
    $env:GHOSTTY_AGENT_LOCK = Join-Path $tmp 'agent.lock'
    $agent = Start-Process -FilePath $AgentExe -ArgumentList '--listen', "127.0.0.1:$AgentPort", '--headless' -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2
    Assert (-not $agent.HasExited) 'loopback agent is running'

    if (($app.Process -and $app.Process.HasExited) -or $agent.HasExited) {
        Write-Host '  SKIP section B: no app or no agent'
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

        # Pick the OTHER shell, so the assertion proves the STORE changed it
        # rather than matching whatever this box defaults to.
        if ($baseIsCmd) {
            $storeShell = 'powershell.exe'
            $shellMarker = 'PS [A-Za-z]:|Windows PowerShell'
        } else {
            $storeShell = 'cmd.exe'
            $shellMarker = 'Microsoft Windows \[Version'
        }
        Write-Host "  (baseline shell is $(if ($baseIsCmd) { 'cmd' } else { 'powershell' }); the store will ask for $storeShell)"

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
        # This half needs a shell whose `cd` moves the OS process cwd, because
        # the inheritance is a GET_CWD on the live child: PowerShell's
        # Set-Location deliberately does NOT (5.1 keeps the process directory
        # put), so the store asks for cmd.exe here regardless of the box default.
        Set-HostDefault $agentKey $storeDir 'cmd.exe'
        $d = New-RemotePane 'remD' '' 'openD.txt'
        Assert ($d.Exit -eq 0) 'cmd-shell remote window opened for the cwd half'
        if ($d.Pane) {
            $dumpD = Read-Pane $d.Pane 'readD.txt'
            Assert ($dumpD -like '*t174-store*') 'the cmd window also started in the stored cwd'
            # +send-keys translates escapes in its text, so every backslash must
            # be doubled: `...\t174-elsewhere` would otherwise arrive as a
            # literal TAB (`\t`) and cmd would tab-complete something else
            # entirely - the cd silently would not happen and the split
            # assertion below would blame the product.
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

        Assert (-not ($app.Process -and $app.Process.HasExited)) 'app survived the whole apply flow'
        Assert (-not $agent.HasExited) 'agent survived the whole apply flow'
    }

} finally {
    if ($agent -and -not $agent.HasExited) { Stop-Process -Id $agent.Id -Force -ErrorAction SilentlyContinue }
    Remove-TestDesktop
    Stop-DebugGhoztty
    Stop-Job $dirJob -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $dirJob -Force -ErrorAction SilentlyContinue | Out-Null
    Remove-Item 'env:GHOSTTY_HOST_DEFAULTS' -ErrorAction SilentlyContinue
    Remove-Item 'env:GHOSTTY_AGENT_LOCK' -ErrorAction SilentlyContinue
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
if ($script:fail -gt 0 -and $env:HS_DEBUG) {
    Write-Host '--- app stderr ---'
    Select-String -Path $errlog -Pattern 'host settings|host defaults|machine chooser|remote' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Line }
    Write-Host '--- store ---'
    Write-Host (Get-Store)
} else {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:skip -gt 0) { Write-Host "($($script:skip) section(s) SKIPPED)" }
if ($script:fail -eq 0) {
    Write-Host "HOST-SETTINGS ACCEPTANCE: ALL PASS ($($script:pass) assertions)"
    exit 0
} else {
    Write-Host "HOST-SETTINGS ACCEPTANCE: $($script:fail) FAILURE(S) ($($script:pass) passed)" -ForegroundColor Red
    exit 1
}
