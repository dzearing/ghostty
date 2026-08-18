# T695 acceptance: the focus-only ghoztty:// URL scheme on Windows.
#
# What is asserted:
#
#   A. REGISTRATION. A debug build writes HKCU\Software\Classes\ghoztty-debug
#      with the URL: description, the `URL Protocol` marker the shell gates on,
#      and a `shell\open\command` naming THIS exe with a quoted "%1" -- and it
#      leaves the RELEASE `ghoztty` class alone, so a dev build never steals the
#      links the user's installed release answers.
#   B. ACTIVATION. Running that exact command line focuses a window target, a
#      pane NAME and a pane ID, and the release spelling parses in a debug build
#      too (links clicked inside ghoztty never round-trip through the shell, so
#      a document that hardcodes ghoztty:// has to work in whichever build
#      renders it).
#   C. REFUSALS. An unknown verb, an empty target, a bare host and a target that
#      is not open all do NOTHING: no window created, and -- the teeth --
#      nothing else focused. `ghoztty-debug://<name>` where <name> IS an open
#      window is the case a lenient parser would "helpfully" focus.
#   D. THE SHELL RESOLVES IT. `Start-Process ghoztty-debug://focus/<t>` -- no
#      exe path anywhere in the call -- focuses the window, which is the thing a
#      user clicking a link in a browser actually does.
#   E. A FAILED LINK SAYS SO. Run without the quiet seam, a warning dialog
#      appears naming the one supported form, and a burst of links produces ONE
#      dialog rather than one each.
#
# ORACLE, and why it is the app's own log. Focus is a foreground change on a
# BACKGROUND test desktop (T233), where "which window is active" is not a
# question the user's desktop can answer for us. So the assertion is the server
# line `IPC: focused '<target>'`, which only IpcHandlers.handleFocus emits and
# which no other verb can produce -- plus the activation process's exit code,
# which distinguishes the two failures (1 not found / 2 unsupported) from
# success. Every refusal arm is paired with a positive control in the same run
# against the same app, so a green-and-empty run is impossible.
#
# persistence: --session-persistence=false on the one GUI launch (a restored
# pane would make the window count meaningless).
#
# Only touches ghoztty processes running from this repo's zig-out.
#
#   powershell -NoProfile -File test\win32\url-scheme.ps1
param(
    [string]$ExePath,
    [switch]$Interactive
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe

# Isolate the IPC endpoint (inherited through CreateProcessW -- and, as arm D
# measures, through the shell's own launch of the registered command).
$env:GHOZTTY_PIPE_SUFFIX = '-urlscheme'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

# Item strings of a LIVE popup menu, by position (separators come back as
# "---"). The same reader pane-banner.ps1 uses: a tracking menu's contents can
# only be read from its own handle, via MN_GETHMENU.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;
public class UrlMenuRead {
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuStringW(IntPtr menu, uint idItem, StringBuilder sb, int max, uint flags);
    [DllImport("user32.dll")] public static extern uint GetMenuState(IntPtr menu, uint id, uint flags);

    public static string[] Items(IntPtr menu) {
        if (menu == IntPtr.Zero) return new string[0];
        int n = GetMenuItemCount(menu);
        var items = new List<string>();
        for (uint i = 0; i < (uint)n; i++) {
            uint state = GetMenuState(menu, i, 0x400); // MF_BYPOSITION
            if ((state & 0x800) != 0) { items.Add("---"); continue; } // MF_SEPARATOR
            var sb = new StringBuilder(128);
            GetMenuStringW(menu, i, sb, 128, 0x400);
            items.Add(sb.ToString());
        }
        return items.ToArray();
    }
}
'@

$script:pass = 0
$script:fail = 0

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-RepoInstances {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

# Run the registered command line by hand: exactly what the shell does in arm D,
# minus the registry lookup. Returns the exit code.
function Invoke-Activation([string]$url) {
    $out = (& $exe $url 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Get-RegValue([string]$key, [string]$name) {
    try {
        $item = Get-ItemProperty -Path "Registry::$key" -ErrorAction Stop
        if ($name -eq '') { return $item.'(default)' }
        return $item.$name
    } catch { return $null }
}

function Get-Data {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    return ($json | ConvertFrom-Json).data
}

function Get-Leaves($node) {
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    return @(Get-Leaves $node.left) + @(Get-Leaves $node.right)
}

function Get-Win($target) {
    $data = Get-Data
    if (-not $data) { return $null }
    foreach ($w in $data.windows) { if ($w.target -eq $target) { return $w } }
    return $null
}

function Wait-Win($target) {
    for ($t = 0; $t -lt 25; $t++) {
        $w = Get-Win $target
        if ($w) { return $w }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Get-WindowCount {
    $data = Get-Data
    if (-not $data) { return -1 }
    return @($data.windows).Count
}

# How many times the app has said it focused something. The refusal arms read
# this before and after: a refusal that focused ANY window moves it.
function Get-FocusCount($errlog, $target) {
    if (-not (Test-Path $errlog)) { return 0 }
    $pattern = if ($target) { "IPC: focused '$([regex]::Escape($target))'" } else { "IPC: focused '" }
    return @(Select-String -Path $errlog -Pattern $pattern -ErrorAction SilentlyContinue).Count
}

function Wait-FocusCount($errlog, $target, [int]$want) {
    for ($t = 0; $t -lt 25; $t++) {
        if ((Get-FocusCount $errlog $target) -ge $want) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

$debugScheme = 'ghoztty-debug'
$releaseScheme = 'ghoztty'
$debugKey = "HKEY_CURRENT_USER\Software\Classes\$debugScheme"
$releaseKey = "HKEY_CURRENT_USER\Software\Classes\$releaseScheme"

# Snapshot the RELEASE class before anything of ours runs, so arm A3 compares
# rather than assumes. A box where the user's installed release has registered
# is the normal case, and it must come out the other side untouched.
$releaseBefore = Get-RegValue "$releaseKey\shell\open\command" ''

Stop-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    $errlog = Join-Path $env:TEMP 'ghoztty-url-scheme-stderr.log'
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $appPid = $app.Pid
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }

    # --- A. registration -----------------------------------------------------
    # Written on a background thread during launch, so it is waited for rather
    # than sampled once.
    $cmd = $null
    for ($t = 0; $t -lt 30; $t++) {
        $cmd = Get-RegValue "$debugKey\shell\open\command" ''
        if ($cmd) { break }
        Start-Sleep -Milliseconds 200
    }
    Assert ($null -ne $cmd) "a debug build registered $debugScheme`:// (got '$cmd')"
    Assert ($cmd -eq ('"' + $exe + '" "%1"')) `
        "...pointing at THIS exe with a quoted %1 (got '$cmd')"

    $desc = Get-RegValue $debugKey ''
    Assert ($desc -like 'URL:*') "the class describes itself as a protocol (got '$desc')"
    $marker = Get-RegValue $debugKey 'URL Protocol'
    Assert ($null -ne $marker) 'the `URL Protocol` marker the shell gates on is present'

    $releaseAfter = Get-RegValue "$releaseKey\shell\open\command" ''
    Assert ($releaseAfter -eq $releaseBefore) `
        "the release $releaseScheme`:// class is untouched by a debug build (before='$releaseBefore' after='$releaseAfter')"
    Assert (-not ($releaseAfter -like "*$repo*")) `
        "...and in particular does not point into this repo (got '$releaseAfter')"

    # --- B. activation focuses what the link names ---------------------------
    $env:GHOZTTY_URL_SCHEME_QUIET = '1'   # a modal warning would hang the run
    $r = & $exe +new-window --target=urlwin 2>&1 | Out-Null
    Assert ($null -ne (Wait-Win 'urlwin')) 'setup: the target window exists'
    & $exe +split --target=urlwin --name=urlpane 2>&1 | Out-Null
    Start-Sleep -Seconds 1

    $paneId = $null
    $w = Get-Win 'urlwin'
    if ($w) {
        foreach ($leaf in @(Get-Leaves $w.tabs[0].splits)) {
            if ($leaf.name -eq 'urlpane') { $paneId = $leaf.id }
        }
    }
    Assert ($null -ne $paneId) "setup: the named pane has an id (got '$paneId')"

    $r = Invoke-Activation "$debugScheme`://focus/urlwin"
    Assert ($r.Code -eq 0) "a window target focuses and exits 0 (got $($r.Code))"
    Assert (Wait-FocusCount $errlog 'urlwin' 1) 'the app reports it focused the window'

    $r = Invoke-Activation "$debugScheme`://focus/urlpane"
    Assert ($r.Code -eq 0) "a pane NAME focuses and exits 0 (got $($r.Code))"
    Assert (Wait-FocusCount $errlog 'urlpane' 1) 'the app reports it focused the named pane'

    $r = Invoke-Activation "$debugScheme`://focus/$paneId"
    Assert ($r.Code -eq 0) "a pane ID focuses and exits 0 (got $($r.Code))"
    Assert (Wait-FocusCount $errlog $paneId 1) 'the app reports it focused the pane by id'

    # The RELEASE spelling parses here too: an in-app link is short-circuited in
    # process, so a generated document hardcoding ghoztty:// must work in
    # whichever build renders it.
    $r = Invoke-Activation "$releaseScheme`://focus/urlwin"
    Assert ($r.Code -eq 0) "the release spelling parses in a debug build too (got $($r.Code))"

    # --- C. refusals do nothing ---------------------------------------------
    $windowsBefore = Get-WindowCount
    $focusedBefore = Get-FocusCount $errlog $null

    $r = Invoke-Activation "$debugScheme`://open/urlwin"
    Assert ($r.Code -eq 2) "an unknown verb is unsupported, not a guess (got $($r.Code))"

    $r = Invoke-Activation "$debugScheme`://focus/"
    Assert ($r.Code -eq 2) "an empty target is unsupported (got $($r.Code))"

    # The teeth: 'urlwin' IS open, so a lenient parser reading the host as a
    # target would focus it. A bare host has nowhere to put a verb and is not a
    # command at all.
    $r = Invoke-Activation "$debugScheme`://urlwin"
    Assert ($r.Code -eq 2) "a bare host is not a lenient spelling of focus (got $($r.Code))"

    $r = Invoke-Activation "$debugScheme`://focus/no-such-window"
    Assert ($r.Code -eq 1) "a target that is not open reports not-found (got $($r.Code))"

    Start-Sleep -Seconds 1
    $windowsAfter = Get-WindowCount
    $focusedAfter = Get-FocusCount $errlog $null
    Assert ($windowsAfter -eq $windowsBefore) `
        "no refusal created a window (before=$windowsBefore after=$windowsAfter)"
    Assert ($focusedAfter -eq $focusedBefore) `
        "no refusal focused something else instead (before=$focusedBefore after=$focusedAfter)"

    # --- D. the shell resolves the link --------------------------------------
    # No exe path in this call: everything comes out of the registry arm A just
    # checked, which is what a click in a browser actually does.
    $before = Get-FocusCount $errlog 'urlwin'
    Start-Process "$debugScheme`://focus/urlwin"
    Assert (Wait-FocusCount $errlog 'urlwin' ($before + 1)) `
        'a shell-resolved link focuses the window it names'

    # --- D2. a banner link is answered IN PROCESS ---------------------------
    # The in-app half: a `ghoztty://` link in a pane banner never leaves the
    # app, so a document rendered by a debug build focuses that build's window
    # rather than whichever one registered the scheme. Its oracle is the
    # `url scheme: in-app focus` line, which only the in-process path emits --
    # an activation would have logged `IPC: focused` instead, so the two paths
    # cannot be mistaken for each other.
    & $exe +new-window --target=bannerwin 2>&1 | Out-Null
    Assert ($null -ne (Wait-Win 'bannerwin')) 'setup: the banner window exists'
    & $exe +set-banner --target=bannerwin "[GOGOGO]($debugScheme`://focus/urlwin)" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 900

    # The banner window is the newest, so find its overlay by matching the pane
    # it is glued above -- the same rule pane-banner.ps1 uses.
    $bTop = [IntPtr]::Zero
    $ov = $null
    foreach ($w in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
        $panes = @(Get-TestChildWindows -Window ([IntPtr]$w.Hwnd) -Class 'GhozttyTerminal' |
            Where-Object { $_.Visible } | Sort-Object Top, Left)
        if ($panes.Count -lt 1) { continue }
        foreach ($o in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyBannerOverlay')) {
            if ([math]::Abs($o.Left - $panes[0].Left) -le 2 -and
                [math]::Abs($o.Bottom - $panes[0].Top) -le 2) { $ov = $o; $bTop = [IntPtr]$w.Hwnd }
        }
    }
    Assert ($null -ne $ov) 'setup: the banner overlay is on screen'
    if ($null -ne $ov) {
        $ovHwnd = [IntPtr]$ov.Hwnd
        $scale = (Get-TestWindowDpi -Window $ovHwnd) / 96.0
        # A single-line banner is not collapsible, so content starts at one
        # margin + one padding on the first text row (banner_layout's numbers,
        # the same derivation pane-banner.ps1 6i uses).
        $lx = [int][Math]::Round(24.0 * $scale)
        $ly = [int][Math]::Round((24.0 + 10.0) * $scale)

        $inAppBefore = @(Select-String -Path $errlog -Pattern "in-app focus 'urlwin'" `
            -ErrorAction SilentlyContinue).Count
        Send-TestMouse -Window $bTop -Target $ovHwnd -X ($ov.Left + $lx + 2) -Y ($ov.Top + $ly) `
            -Button left -Action up | Out-Null
        $got = $false
        for ($t = 0; $t -lt 25; $t++) {
            $n = @(Select-String -Path $errlog -Pattern "in-app focus 'urlwin'" `
                -ErrorAction SilentlyContinue).Count
            if ($n -gt $inAppBefore) { $got = $true; break }
            Start-Sleep -Milliseconds 200
        }
        Assert $got 'clicking a ghoztty:// banner link focuses the target in process'

        # ...and its right-click menu offers the one thing a command can do.
        Send-TestMouse -Window $bTop -Target $ovHwnd -X ($ov.Left + $lx + 2) -Y ($ov.Top + $ly) `
            -Button right -Action up | Out-Null
        $menu = Wait-TestPopupMenu -ProcessId $appPid -TimeoutMs 4000
        Assert ($menu -ne [IntPtr]::Zero) 'right-clicking a command link opens a menu'
        if ($menu -ne [IntPtr]::Zero) {
            $r = Invoke-TestMessage -Window $menu -Message 0x01E1  # MN_GETHMENU
            $items = if ($r -eq [long]::MinValue -or $r -eq 0) { @() } else { [UrlMenuRead]::Items([IntPtr]$r) }
            Write-Host "      command link menu: $($items -join ' | ')"
            Assert (($items -join '|') -eq 'Focus in Ghoztty|---|Copy Link') `
                'the menu is Focus + Copy, with no destination it has no content for'
            $panes = @(Get-TestChildWindows -Window $bTop -Class 'GhozttyTerminal' |
                Where-Object { $_.Visible } | Sort-Object Top, Left)
            if ($panes.Count -ge 1) {
                [void](Invoke-TestMessage -Window ([IntPtr]$panes[0].Hwnd) -Message 0x001F)  # WM_CANCELMODE
            }
            Start-Sleep -Milliseconds 400
        }
    }

    # --- E. a failed link says so, once --------------------------------------
    # Run WITHOUT the quiet seam and on the test desktop, so the modal warning
    # cannot land on the user's screen. Two activations, one dialog: the
    # cross-process coalescing a page firing a burst of links needs.
    Remove-Item Env:\GHOZTTY_URL_SCHEME_QUIET -ErrorAction SilentlyContinue
    # persistence: n/a - a URL activation, which is answered and exited before
    # the single-instance bind (main_ghostty.zig, T695). It opens no terminal
    # and never reaches the restore path, so there is nothing to declare.
    $a1 = Start-OnTestDesktop -Exe $exe -Arguments @("$debugScheme`://open/urlwin")
    $dlg = Wait-TestWindow -ProcessId $a1.Pid -Class '#32770' -TimeoutMs 15000
    Assert ($dlg -ne [IntPtr]::Zero) 'an unsupported link puts a warning on screen'
    if ($dlg -ne [IntPtr]::Zero) {
        $text = Get-TestWindowText $dlg
        Assert ($text -like '*Unsupported Ghoztty link*') `
            "...whose caption names the problem (got '$text')"
    }

    # persistence: n/a - a URL activation, as above: no terminal, no restore.
    $a2 = Start-OnTestDesktop -Exe $exe -Arguments @("$debugScheme`://open/urlwin")
    $second = Wait-TestWindow -ProcessId $a2.Pid -Class '#32770' -TimeoutMs 8000
    Assert ($second -eq [IntPtr]::Zero) `
        'a second link while the warning is up adds no second dialog'

    if ($dlg -ne [IntPtr]::Zero) { Send-TestWindowClose $dlg | Out-Null }
    Start-Sleep -Seconds 1
    Assert (-not (Test-TestWindowExists $dlg)) 'the warning closes (nothing is left modal)'

    # POSITIVE CONTROL for the arm above: with no dialog up, the SAME wait
    # finds one. Without this, "no second dialog" would also pass on a box
    # where the dialog simply takes longer than the wait -- or never appears at
    # all, which is how a coalescing test passes while coalescing is broken.
    # persistence: n/a - a URL activation, as above: no terminal, no restore.
    $a3 = Start-OnTestDesktop -Exe $exe -Arguments @("$debugScheme`://open/urlwin")
    $third = Wait-TestWindow -ProcessId $a3.Pid -Class '#32770' -TimeoutMs 8000
    Assert ($third -ne [IntPtr]::Zero) `
        'control: once the warning is dismissed, the next link shows its own'
    if ($third -ne [IntPtr]::Zero) { Send-TestWindowClose $third | Out-Null }
} finally {
    $env:GHOZTTY_URL_SCHEME_QUIET = '1'
    Stop-RepoInstances
    Remove-TestDesktop $td
    Stop-TestForegroundWatch
    Remove-Item Env:\GHOZTTY_URL_SCHEME_QUIET -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($($script:pass) checks)" }
else { Write-Host "$($script:fail) FAILURE(S) ($($script:pass) passed)" -ForegroundColor Red }
exit ([int]($script:fail -gt 0))
