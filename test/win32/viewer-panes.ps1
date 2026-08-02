# T90b acceptance: the viewer-pane IPC/CLI floor.
#
# This is the SEED of the script that grows across the whole Phase K band
# (pane-banner.ps1 model). Today viewer panes do not exist on win32 -- T90c
# retypes the split tree and T90d brings the WebView2 host -- so what is
# asserted here is the FLOOR that has to hold until then, and the shape the
# later tasks fill in:
#
#   - `--view` is answered EXPLICITLY. It used to fall into the verb parser's
#     unknown-flag drop, so `+new-window --view=README.md` opened a plain
#     TERMINAL and reported success. Silently doing the wrong thing is the
#     defect; the interim error is the fix.
#   - `--view` + `--command`/`-e` is rejected with the MAC string, and it is
#     checked FIRST -- that check is permanent and survives T90d, while the
#     not-yet-supported one is deleted by it.
#   - `+list --json` carries the additive `"type"` / `"url"` pane fields on
#     every leaf, which is what `src/cli/list.zig` already reads to render a
#     `view:` row. Terminals report `"terminal"` / null, exactly as the Mac
#     server encodes them (IPCMessage.swift:103-104).
#
# Oracles, and why each has a POSITIVE CONTROL: every "nothing was created"
# assertion here is trivially true if the IPC path is simply broken -- a green
# and empty run (T216's lesson). So each rejection is paired with the same verb
# WITHOUT `--view`, which must create exactly what the rejected one did not.
#
# Relative/absolute `--view=` path resolution is NOT asserted here: it happens
# entirely CLI-side before the request is sent, is invisible from the outside
# (the error text does not echo the path), and is unit tested in the
# none-runtime lane -- `src/cli/view_args.zig`, including the `C:\...` and UNC
# cases that the retired `rest[0] == '/'` test called relative.
#
# Runs on the BACKGROUND test desktop (lib\TestDesktop.ps1), so it never
# steals the user's foreground. Only touches ghoztty processes running from
# this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\viewer-panes.ps1
param(
    [string]$ExePath,
    [switch]$Interactive
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }

# Isolate the IPC endpoint (inherited through CreateProcessW): an instance
# answering the shared pipe would let another run's windows into this one.
$env:GHOZTTY_PIPE_SUFFIX = '-vptest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0

# Write-Host, not the pipeline: a helper that asserts must never also return a
# value, or its return silently becomes an array (T217 batch 5).
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

# Run a ghoztty verb and return its exit code plus merged output. A PIPE, not
# a `>` redirect: `ghoztty +verb > file` from PowerShell writes zero bytes
# (T245), and the server's error text is the whole oracle here.
function Invoke-Verb([string[]]$VerbArgs) {
    $out = (& $exe @VerbArgs 2>&1 | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

function Get-Data {
    $json = (& $exe +list --json 2>$null | Out-String).Trim()
    if (-not $json) { return $null }
    return ($json | ConvertFrom-Json).data
}

function Get-Win($target) {
    $data = Get-Data
    if (-not $data) { return $null }
    foreach ($w in $data.windows) { if ($w.target -eq $target) { return $w } }
    return $null
}

function Get-Leaves($node) {
    if ($node.type -eq 'leaf') { return @($node.terminal) }
    return @(Get-Leaves $node.left) + @(Get-Leaves $node.right)
}

function Get-PaneCount($target) {
    $w = Get-Win $target
    if (-not $w) { return 0 }
    return @(Get-Leaves $w.tabs[0].splits).Count
}

function Wait-Win($target) {
    for ($t = 0; $t -lt 25; $t++) {
        $w = Get-Win $target
        if ($w) { return $w }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

$viewFile = Join-Path $repo 'README.md'
$notSupported = 'viewers are not yet supported on Windows'
$conflict = '--view cannot be combined with --command/-e'

Stop-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # Session persistence OFF so the run starts from a BLANK layout: otherwise
    # a previous run's manifest restores its own `vp` window and
    # `+new-window --target=vp` idempotently FOCUSES that stale window instead
    # of making a fresh one, which makes run 1 pass and every later run fail
    # (the T131/T155 lesson). Launched onto the test desktop rather than by IPC
    # auto-spawn, which would put the GUI on the user's desktop.
    $errlog = Join-Path $env:TEMP 'ghoztty-viewer-panes-stderr.log'
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $appPid = $app.Pid
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI is NOT enumerable on the interactive desktop'

    # --- 1. positive control: the plain verbs work ----------------------------
    # Without this every "no window/pane was created" assertion below passes
    # for free if IPC is simply dead.
    Invoke-Verb @('+new-window', '--target=vp') | Out-Null
    $vp = Wait-Win 'vp'
    Assert ($null -ne $vp) 'CONTROL: +new-window without --view creates a window'
    $panesBefore = Get-PaneCount 'vp'
    Assert ($panesBefore -ge 1) "CONTROL: the window has a pane (got $panesBefore)"

    # --- 2. +new-window --view is refused, and creates nothing ----------------
    $winsBefore = @((Get-Data).windows).Count
    $r = Invoke-Verb @('+new-window', '--target=vpview', "--view=$viewFile")
    Assert ($r.Code -ne 0) "+new-window --view exits nonzero (got $($r.Code))"
    Assert ($r.Out -match [regex]::Escape($notSupported)) '+new-window --view reports the interim error'
    Start-Sleep -Seconds 2
    $winsAfter = @((Get-Data).windows).Count
    Assert ($winsAfter -eq $winsBefore) "no window was created ($winsBefore -> $winsAfter)"
    Assert ($null -eq (Get-Win 'vpview')) 'the rejected target is NOT registered'

    # --- 3. +split --view is refused, and creates nothing ---------------------
    $r = Invoke-Verb @('+split', '--target=vp', '--name=vpsplit', "--view=$viewFile")
    Assert ($r.Code -ne 0) "+split --view exits nonzero (got $($r.Code))"
    Assert ($r.Out -match [regex]::Escape($notSupported)) '+split --view reports the interim error'
    Start-Sleep -Seconds 2
    $panesAfter = Get-PaneCount 'vp'
    Assert ($panesAfter -eq $panesBefore) "no pane was created ($panesBefore -> $panesAfter)"

    # --- 4. positive control: the same +split WITHOUT --view does split ------
    Invoke-Verb @('+split', '--target=vp', '--name=vpterm', '--direction=right') | Out-Null
    $grew = $false
    for ($t = 0; $t -lt 25 -and -not $grew; $t++) {
        if ((Get-PaneCount 'vp') -eq ($panesBefore + 1)) { $grew = $true } else { Start-Sleep -Milliseconds 200 }
    }
    Assert $grew "CONTROL: +split without --view DOES add a pane (now $(Get-PaneCount 'vp'))"

    # --- 5. --view + --command / -e: the Mac string, and it wins the race ----
    # Ordering matters: the conflict check is permanent and the not-supported
    # one is deleted by T90d, so an ambiguous command line must report the
    # conflict on both platforms rather than the interim Windows-only error.
    foreach ($case in @(
            @{ Label = '--command'; Args = @('+new-window', '--target=vpx', "--view=$viewFile", '--command=cmd.exe') },
            @{ Label = '-e'; Args = @('+new-window', '--target=vpx', "--view=$viewFile", '-e', 'cmd.exe') },
            @{ Label = '+split --command'; Args = @('+split', '--target=vp', "--view=$viewFile", '--command=cmd.exe') }
        )) {
        $r = Invoke-Verb $case.Args
        Assert ($r.Code -ne 0) "--view with $($case.Label) exits nonzero (got $($r.Code))"
        Assert ($r.Out -match [regex]::Escape($conflict)) "--view with $($case.Label) reports the Mac conflict string"
        Assert ($r.Out -notmatch [regex]::Escape($notSupported)) "--view with $($case.Label) does NOT report the interim error instead"
    }

    # --- 6. --split-command is NOT a conflict -------------------------------
    # It configures the OTHER pane of an inline split, which stays a terminal.
    # Mac checks `config.command` only, so this must fall through to the
    # interim error rather than the conflict.
    $r = Invoke-Verb @('+new-window', '--target=vpy', "--view=$viewFile", '--split-command=cmd.exe')
    Assert ($r.Out -match [regex]::Escape($notSupported)) '--view + --split-command reaches the interim error, not the conflict'

    # --- 7. additive list shape: every leaf carries type/url -----------------
    $data = Get-Data
    Assert ($null -ne $data) '+list --json still parses'
    $leaves = @()
    foreach ($w in $data.windows) { foreach ($tab in $w.tabs) { $leaves += @(Get-Leaves $tab.splits) } }
    Assert ($leaves.Count -ge 2) "found terminal leaves to inspect (got $($leaves.Count))"
    $typed = @($leaves | Where-Object { $_.type -eq 'terminal' })
    Assert ($typed.Count -eq $leaves.Count) "every leaf reports type=terminal ($($typed.Count)/$($leaves.Count))"
    # `url` is PRESENT and null for a terminal, matching the Mac encoder --
    # `-contains` on the property list, because a null value is not the same
    # as an absent key and only the property list can tell them apart.
    $withUrlKey = @($leaves | Where-Object { $_.PSObject.Properties.Name -contains 'url' })
    Assert ($withUrlKey.Count -eq $leaves.Count) "every leaf carries a url key ($($withUrlKey.Count)/$($leaves.Count))"
    $nullUrl = @($leaves | Where-Object { $null -eq $_.url })
    Assert ($nullUrl.Count -eq $leaves.Count) "every terminal leaf reports url=null ($($nullUrl.Count)/$($leaves.Count))"

    # --- 8. the human renderer is unchanged for terminals --------------------
    # `src/cli/list.zig` only switches to its `view:` row when type == viewer,
    # so a terminal must still print its cwd/pid row.
    $human = (& $exe +list 2>&1 | Out-String)
    Assert ($human -match 'pid:\d+') '+list (human) still prints terminal rows'
    Assert ($human -notmatch '(?m)^\s*view:') '+list (human) prints no view: rows while there are no viewers'

    # --- 9. app survived all of it -------------------------------------------
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'GUI process alive after all scenarios'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI never became visible on the interactive desktop'
} finally {
    Remove-TestDesktop
    Stop-RepoInstances
}

# Runs AFTER the cleanup, so it reads the surviving all-pids list -- the live
# one is emptied by Remove-TestDesktop and would score against nothing.
$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)"; exit 1 }
