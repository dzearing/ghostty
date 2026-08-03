# T90b/T374 acceptance: viewer panes on win32.
#
# The script that grows across the whole Phase K band (pane-banner.ps1 model).
# T374 flipped the biggest assertion in it: `+new-window --view=<url>` and
# `+split --view=<url>` now BUILD a real viewer pane in web mode, where they
# used to be refused outright. What is asserted:
#
#   - a web `--view` creates a pane whose leaf reports `"type":"viewer"` and
#     the `url` it was opened with, renders in a `GhozttyViewer` host window,
#     and prints a `view:` row in the human `+list`.
#   - the terminal-only verbs (`+read`, `+send-keys`, `+set-state`,
#     `+set-banner`) refuse a viewer target with the Mac's string and exit 1,
#     while `+close` takes it silently -- the line between "this pane has no
#     shell" and "this pane is a normal tree citizen".
#   - a FILE `--view` is still answered EXPLICITLY (T90e brings the renderer).
#     It used to fall into the verb parser's unknown-flag drop, so
#     `+new-window --view=README.md` opened a plain TERMINAL and reported
#     success. Silently doing the wrong thing is the defect; the interim error
#     is the fix, and handing a markdown file to a browser would be the same
#     defect one level down.
#   - `--view` + `--command`/`-e` is rejected with the MAC string, and it is
#     checked FIRST -- that check is permanent, while the file-mode one is
#     deleted by T90e.
#   - `+list --json` carries the additive `"type"` / `"url"` pane fields on
#     every leaf, which is what `src/cli/list.zig` reads to render a `view:`
#     row. Terminals report `"terminal"` / null, exactly as the Mac server
#     encodes them (IPCMessage.swift:103-104).
#
# Oracles, and why each has a POSITIVE CONTROL: every "nothing was created"
# assertion here is trivially true if the IPC path is simply broken -- a green
# and empty run (T216's lesson). So each rejection is paired with the same verb
# WITHOUT `--view`, which must create exactly what the rejected one did not.
#
# `about:blank` is the location the created-pane cases use, deliberately: it is
# the one URL that reaches `Navigate` without a network, so a box with no route
# out still exercises the whole path (P11 makes it a product feature too).
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

function Get-Leaf($target, $name) {
    $w = Get-Win $target
    if (-not $w) { return $null }
    foreach ($leaf in @(Get-Leaves $w.tabs[0].splits)) {
        if ($leaf.name -eq $name) { return $leaf }
    }
    return $null
}

function Wait-Leaf($target, $name) {
    for ($t = 0; $t -lt 25; $t++) {
        $leaf = Get-Leaf $target $name
        if ($leaf) { return $leaf }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

$viewFile = Join-Path $repo 'README.md'
$blank = 'about:blank'
$fileUnsupported = 'file viewers are not yet supported on Windows'
$conflict = '--view cannot be combined with --command/-e'
$notTerminal = 'is a viewer pane, not a terminal'

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

    # --- 2. terminals report the additive fields, BEFORE any viewer exists ---
    # The half of the list shape that has to keep holding: a terminal leaf is
    # `"terminal"` / null, and the `view:` row never appears for one.
    $data = Get-Data
    Assert ($null -ne $data) '+list --json parses'
    $leaves = @()
    foreach ($w in $data.windows) { foreach ($tab in $w.tabs) { $leaves += @(Get-Leaves $tab.splits) } }
    Assert ($leaves.Count -ge 1) "found terminal leaves to inspect (got $($leaves.Count))"
    $typed = @($leaves | Where-Object { $_.type -eq 'terminal' })
    Assert ($typed.Count -eq $leaves.Count) "every leaf reports type=terminal ($($typed.Count)/$($leaves.Count))"
    # `url` is PRESENT and null for a terminal, matching the Mac encoder --
    # `-contains` on the property list, because a null value is not the same
    # as an absent key and only the property list can tell them apart.
    $withUrlKey = @($leaves | Where-Object { $_.PSObject.Properties.Name -contains 'url' })
    Assert ($withUrlKey.Count -eq $leaves.Count) "every leaf carries a url key ($($withUrlKey.Count)/$($leaves.Count))"
    $nullUrl = @($leaves | Where-Object { $null -eq $_.url })
    Assert ($nullUrl.Count -eq $leaves.Count) "every terminal leaf reports url=null ($($nullUrl.Count)/$($leaves.Count))"
    $human = (& $exe +list 2>&1 | Out-String)
    Assert ($human -match 'pid:\d+') '+list (human) prints terminal rows'
    Assert ($human -notmatch '(?m)^\s*view:') '+list (human) prints no view: rows while there are no viewers'

    # --- 3. +new-window --view=<url> BUILDS a viewer window (T374) -----------
    $r = Invoke-Verb @('+new-window', '--target=vpweb', "--view=$blank")
    Assert ($r.Code -eq 0) "+new-window --view=$blank exits 0 (got $($r.Code))"
    $vpweb = Wait-Win 'vpweb'
    Assert ($null -ne $vpweb) '+new-window --view creates a window'
    # Assigned as a statement, never as `$x = if (...) { @(...) }`: the if
    # EXPRESSION sends its value down the pipeline, which unrolls a one-element
    # array back to a scalar whose `.Count` is $null (T217 batch 5's trap, one
    # construct over).
    $webLeaves = @()
    if ($vpweb) { $webLeaves = @(Get-Leaves $vpweb.tabs[0].splits) }
    Assert ($webLeaves.Count -eq 1) "the viewer window has exactly one pane (got $($webLeaves.Count))"
    if ($webLeaves.Count -eq 1) {
        Assert ($webLeaves[0].type -eq 'viewer') "its leaf reports type=viewer (got '$($webLeaves[0].type)')"
        Assert ($webLeaves[0].url -eq $blank) "its leaf reports url=$blank (got '$($webLeaves[0].url)')"
        # A viewer has no shell: the terminal-only fields must be empty rather
        # than carrying a terminal's leftovers.
        Assert ($webLeaves[0].pid -eq 0) "its leaf reports pid=0 (got '$($webLeaves[0].pid)')"
    }

    # The pane is a real HOST WINDOW, not just a registry entry: `GhozttyViewer`
    # is the class `ViewerPane.registerClass` creates, and a JSON row could be
    # green while nothing was ever put on screen.
    $hosts = @()
    foreach ($top in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
        $hosts += @(Get-TestChildWindows -Window ([IntPtr]$top.Hwnd) -Class 'GhozttyViewer')
    }
    Assert ($hosts.Count -ge 1) "a GhozttyViewer host window exists (got $($hosts.Count))"
    Assert (@($hosts | Where-Object { $_.Width -gt 0 -and $_.Height -gt 0 }).Count -ge 1) 'the host window has a non-empty rect'

    # --- 4. the human renderer switches to its view: row ---------------------
    $human = (& $exe +list 2>&1 | Out-String)
    Assert ($human -match '(?m)^\s*view:') '+list (human) prints a view: row for the viewer pane'
    Assert ($human -match [regex]::Escape($blank)) '+list (human) prints the viewer location'

    # --- 5. +split --view adds a viewer pane beside a terminal ---------------
    $r = Invoke-Verb @('+split', '--target=vp', '--name=vpsplit', '--direction=right', "--view=$blank")
    Assert ($r.Code -eq 0) "+split --view exits 0 (got $($r.Code))"
    $splitLeaf = Wait-Leaf 'vp' 'vpsplit'
    Assert ($null -ne $splitLeaf) '+split --view registers the pane under --name'
    if ($splitLeaf) {
        Assert ($splitLeaf.type -eq 'viewer') "the split leaf reports type=viewer (got '$($splitLeaf.type)')"
        Assert ($splitLeaf.url -eq $blank) "the split leaf reports url=$blank (got '$($splitLeaf.url)')"
    }
    Assert ((Get-PaneCount 'vp') -eq ($panesBefore + 1)) "the split window grew by one pane (now $(Get-PaneCount 'vp'))"
    # The terminal it split off is untouched -- a viewer joining the tree must
    # not retype its neighbor.
    $sibling = @(Get-Leaves (Get-Win 'vp').tabs[0].splits | Where-Object { $_.type -eq 'terminal' })
    Assert ($sibling.Count -eq $panesBefore) "the sibling terminal(s) stayed terminals ($($sibling.Count))"

    # --- 6. terminal-only verbs refuse a viewer, with the Mac string ---------
    foreach ($case in @(
            @{ Label = '+read'; Args = @('+read', '--name=vpsplit', '--lines=5') },
            @{ Label = '+send-keys'; Args = @('+send-keys', '--target=vpsplit', 'hello') },
            @{ Label = '+set-state'; Args = @('+set-state', '--target=vpsplit', '--state=busy') },
            @{ Label = '+set-banner'; Args = @('+set-banner', '--target=vpsplit', 'hi') }
        )) {
        $r = Invoke-Verb $case.Args
        Assert ($r.Code -ne 0) "$($case.Label) against a viewer exits nonzero (got $($r.Code))"
        Assert ($r.Out -match [regex]::Escape($notTerminal)) "$($case.Label) reports '$notTerminal'"
    }
    # POSITIVE CONTROL: the same verbs against the TERMINAL pane in the same
    # window succeed, so the rejections above are about the pane kind and not
    # about a broken verb.
    Invoke-Verb @('+split', '--target=vp', '--name=vpterm', '--direction=down') | Out-Null
    Wait-Leaf 'vp' 'vpterm' | Out-Null
    $r = Invoke-Verb @('+set-banner', '--target=vpterm', 'control')
    Assert ($r.Code -eq 0) "CONTROL: +set-banner against a TERMINAL exits 0 (got $($r.Code))"
    $r = Invoke-Verb @('+read', '--name=vpterm', '--lines=1')
    Assert ($r.Code -eq 0) "CONTROL: +read against a TERMINAL exits 0 (got $($r.Code))"

    # --- 7. +close takes a viewer silently ----------------------------------
    $beforeClose = Get-PaneCount 'vp'
    $r = Invoke-Verb @('+close', '--target=vpsplit')
    Assert ($r.Code -eq 0) "+close on a viewer exits 0 (got $($r.Code))"
    Assert ($r.Out.Trim() -eq '') "+close on a viewer prints nothing (got '$($r.Out.Trim())')"
    $shrank = $false
    for ($t = 0; $t -lt 25 -and -not $shrank; $t++) {
        if ((Get-PaneCount 'vp') -eq ($beforeClose - 1)) { $shrank = $true } else { Start-Sleep -Milliseconds 200 }
    }
    Assert $shrank "+close removed the viewer pane (now $(Get-PaneCount 'vp'))"
    Assert ($null -eq (Get-Leaf 'vp' 'vpsplit')) 'the closed viewer is gone from +list'

    # --- 8. a FILE --view is still refused, and creates nothing (T90e) -------
    $winsBefore = @((Get-Data).windows).Count
    $panesNow = Get-PaneCount 'vp'
    $r = Invoke-Verb @('+new-window', '--target=vpfile', "--view=$viewFile")
    Assert ($r.Code -ne 0) "+new-window --view=<file> exits nonzero (got $($r.Code))"
    Assert ($r.Out -match [regex]::Escape($fileUnsupported)) '+new-window --view=<file> reports the interim error'
    Start-Sleep -Seconds 2
    Assert (@((Get-Data).windows).Count -eq $winsBefore) 'no window was created for the file view'
    Assert ($null -eq (Get-Win 'vpfile')) 'the rejected target is NOT registered'

    $r = Invoke-Verb @('+split', '--target=vp', '--name=vpfilesplit', "--view=$viewFile")
    Assert ($r.Code -ne 0) "+split --view=<file> exits nonzero (got $($r.Code))"
    Assert ($r.Out -match [regex]::Escape($fileUnsupported)) '+split --view=<file> reports the interim error'
    Start-Sleep -Seconds 2
    Assert ((Get-PaneCount 'vp') -eq $panesNow) "no pane was created for the file view (still $panesNow)"

    # --- 9. --view + --command / -e: the Mac string, and it wins the race ----
    # Ordering matters: the conflict check is permanent and the file-mode one is
    # deleted by T90e, so an ambiguous command line must report the conflict on
    # both platforms rather than the interim Windows-only error. Checked with a
    # WEB url too, where there is no interim error left to hide behind -- a
    # conflict that only fires for files would be a conflict check that stopped
    # existing the moment T374 made the pane real.
    foreach ($case in @(
            @{ Label = '--command (file)'; Args = @('+new-window', '--target=vpx', "--view=$viewFile", '--command=cmd.exe') },
            @{ Label = '-e (file)'; Args = @('+new-window', '--target=vpx', "--view=$viewFile", '-e', 'cmd.exe') },
            @{ Label = '--command (url)'; Args = @('+new-window', '--target=vpx', "--view=$blank", '--command=cmd.exe') },
            @{ Label = '-e (url)'; Args = @('+new-window', '--target=vpx', "--view=$blank", '-e', 'cmd.exe') },
            @{ Label = '+split --command (url)'; Args = @('+split', '--target=vp', "--view=$blank", '--command=cmd.exe') }
        )) {
        $r = Invoke-Verb $case.Args
        Assert ($r.Code -ne 0) "--view with $($case.Label) exits nonzero (got $($r.Code))"
        Assert ($r.Out -match [regex]::Escape($conflict)) "--view with $($case.Label) reports the Mac conflict string"
        Assert ($r.Out -notmatch [regex]::Escape($fileUnsupported)) "--view with $($case.Label) does NOT report the interim error instead"
    }
    Assert ($null -eq (Get-Win 'vpx')) 'no window was created by any conflicting command line'

    # --- 10. --split-command is NOT a conflict ------------------------------
    # It configures the OTHER pane of an inline split, which stays a terminal.
    # Mac checks `config.command` only, so a web `--view` with it must SUCCEED.
    $r = Invoke-Verb @('+new-window', '--target=vpy', "--view=$blank", '--split-command=cmd.exe', '--split=right')
    Assert ($r.Code -eq 0) "--view + --split-command exits 0 (got $($r.Code))"
    $vpy = Wait-Win 'vpy'
    Assert ($null -ne $vpy) '--view + --split-command creates the window'
    if ($vpy) {
        $vpyLeaves = @(Get-Leaves $vpy.tabs[0].splits)
        Assert ($vpyLeaves.Count -eq 2) "it has both panes (got $($vpyLeaves.Count))"
        Assert (@($vpyLeaves | Where-Object { $_.type -eq 'viewer' }).Count -eq 1) 'one pane is the viewer'
        Assert (@($vpyLeaves | Where-Object { $_.type -eq 'terminal' }).Count -eq 1) 'the inline split stayed a terminal'
    }

    # --- 11. app survived all of it ------------------------------------------
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
