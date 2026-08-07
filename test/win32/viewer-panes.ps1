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
#   - a FILE `--view` (T90e) builds a pane too -- markdown, code, and a path
#     that does not exist, which opens a pane carrying the error IN the page
#     rather than refusing. `+list` cannot see inside a WebView2, so what is
#     asserted here is the pane's identity and location; that the file's
#     CONTENT reaches the page is the win32 lane's live "host floor" test,
#     which reads a two-heading markdown file's headings back up T375's
#     bridge.
#   - a viewer NAMES itself (T383): the leaf's `title` is the file's basename
#     (or the location, for a host-less URL like `about:blank`), that name
#     reaches the window caption through the T92 pane->tab->titlebar chain, and
#     the human `view:` row prints it. A website's real `document.title`
#     arriving over `DocumentTitleChanged` is the win32 lane's live test --
#     nothing out here can see inside a WebView2.
#   - `+reload` (T390) reloads a viewer pane and a viewer-focused window, and
#     refuses a terminal pane and a terminal-focused window with the Mac's two
#     DIFFERENT strings. That it really re-rendered (and did not just return
#     success) is read out of the GUI's own log: the missing-file viewer files
#     a second "cannot read file" line when its content is re-rendered.
#   - `--view` + `--command`/`-e` is rejected with the MAC string. That is the
#     only remaining `--view` refusal; the interim "file viewers are not yet
#     supported on Windows" error was deleted with T90e.
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
# Relative/absolute `--view=` path resolution is mostly NOT asserted here: it
# happens entirely CLI-side before the request is sent, is invisible from the
# outside (the error text does not echo the path), and is unit tested in the
# none-runtime lane -- `src/cli/view_arg.zig`, including the `C:\...` and UNC
# cases that the retired `rest[0] == '/'` test called relative. The one leg
# asserted here is `~` expansion (T388, section 8a2), because the resolved
# path IS visible from outside: it comes back as the pane's `url`.
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
        # T383: a viewer NAMES itself. `about:blank` has no host, so the
        # location is its own name -- and an empty title here is the defect
        # this replaces (`+list` printed a nameless `view:` row).
        Assert ($webLeaves[0].title -eq $blank) "its leaf reports title=$blank (got '$($webLeaves[0].title)')"
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

    # --- 3b. the nav chrome exists (T159) ------------------------------------
    # Every viewer host carries a `GhozttyViewerNav` child window with a real
    # EDIT inside it -- the back/forward/reload/home bar and the address
    # field. Both are BORN HIDDEN: the bar is hover-revealed, and hover cannot
    # be proven from the background test desktop (SendInput and the real
    # cursor are dead there), so the reveal DECISION is unit-tested in
    # `viewer_nav_layout.hoverTick` and what is asserted here is the native
    # window structure the reveal shows. The about:blank pane's address field
    # is EMPTY by design (Mac parity: the blank page shows the placeholder).
    $navBars = @()
    foreach ($h in $hosts) {
        $navBars += @(Get-TestChildWindows -Window ([IntPtr]$h.Hwnd) -Class 'GhozttyViewerNav')
    }
    Assert ($navBars.Count -ge 1) "a GhozttyViewerNav bar exists under the viewer host (got $($navBars.Count))"
    $navEdits = @()
    foreach ($nb in $navBars) {
        $navEdits += @(Get-TestChildWindows -Window ([IntPtr]$nb.Hwnd) -Class 'Edit')
    }
    Assert ($navEdits.Count -ge 1) "the nav bar carries an EDIT address field (got $($navEdits.Count))"
    $blankAddr = @($navEdits | ForEach-Object { Get-TestControlText ([IntPtr]$_.Hwnd) })
    Assert (@($blankAddr | Where-Object { $_ -eq '' }).Count -ge 1) `
        "the about:blank pane's address field is empty (got '$($blankAddr -join "','")')"

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
        Assert (($r.Out -replace '\s+', ' ') -match [regex]::Escape($notTerminal)) "$($case.Label) reports '$notTerminal'"
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

    # --- 8. a FILE --view BUILDS a viewer pane (T90e) ------------------------
    # The exact inverse of the assertion it replaces. Until T90e a `--view`
    # naming a file was refused explicitly, because handing markdown to a
    # browser renders it as raw text; the offline renderer exists now, so the
    # same command line has to build a pane instead.
    #
    # What is checkable from OUT HERE is the pane's identity and location --
    # `+list` cannot see inside a WebView2. That the file's CONTENT reaches the
    # page is proven live in the win32 lane's "host floor" test, which opens a
    # two-heading markdown file and reads the headings back up T375's bridge:
    # nothing short of the interception, the resolver, the template load and
    # the `window.__viewer.setMarkdown` injection produces them.
    $panesNow = Get-PaneCount 'vp'
    $r = Invoke-Verb @('+new-window', '--target=vpfile', "--view=$viewFile")
    Assert ($r.Code -eq 0) "+new-window --view=<file> exits 0 (got $($r.Code))"
    $vpfile = Wait-Win 'vpfile'
    Assert ($null -ne $vpfile) '+new-window --view=<file> creates a window'
    $fileLeaves = @()
    if ($vpfile) { $fileLeaves = @(Get-Leaves $vpfile.tabs[0].splits) }
    Assert ($fileLeaves.Count -eq 1) "the file viewer window has exactly one pane (got $($fileLeaves.Count))"
    if ($fileLeaves.Count -eq 1) {
        Assert ($fileLeaves[0].type -eq 'viewer') "its leaf reports type=viewer (got '$($fileLeaves[0].type)')"
        Assert ($fileLeaves[0].url -eq $viewFile) "its leaf reports url=<the file> (got '$($fileLeaves[0].url)')"
    }

    # --- 8b0. the address field shows the file's path (T159) -----------------
    # The Mac display rule: a file pane's address is the path the user can
    # retype, pushed into the native EDIT the moment the pane navigates. Read
    # with WM_GETTEXT (Get-TestControlText) -- the T175 lesson, since a
    # cross-process GetWindowTextW on another process's control reads a cache
    # the app never sets. Scanned across every viewer host because the file
    # window is not distinguishable by class alone.
    $fileAddrs = @()
    foreach ($top in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
        foreach ($h in @(Get-TestChildWindows -Window ([IntPtr]$top.Hwnd) -Class 'GhozttyViewer')) {
            foreach ($nb in @(Get-TestChildWindows -Window ([IntPtr]$h.Hwnd) -Class 'GhozttyViewerNav')) {
                foreach ($ed in @(Get-TestChildWindows -Window ([IntPtr]$nb.Hwnd) -Class 'Edit')) {
                    $fileAddrs += (Get-TestControlText ([IntPtr]$ed.Hwnd))
                }
            }
        }
    }
    Assert (@($fileAddrs | Where-Object { $_ -eq $viewFile }).Count -ge 1) `
        "a nav address field shows the viewed file's path (got '$($fileAddrs -join "','")')"

    # --- 8a. titles (T383) ---------------------------------------------------
    # A file viewer is named by its FILE, and that name walks the whole T92
    # chain the same way a shell-reported terminal title does: pane -> tab ->
    # titlebar. Before this the pane's title was allocated, freed, and never
    # set, so `+list` printed an empty `view:` row and the caption read
    # "Ghoztty" for a pane that knew exactly what it was showing.
    #
    # The window title is the load-bearing half: the JSON field alone could be
    # right while nothing reached the window, which is the only place the user
    # sees it. `vpfile` is a single-pane viewer window, so its caption can only
    # mean one thing.
    $viewLeafName = Split-Path $viewFile -Leaf
    $fileLeaf = $null
    if ($fileLeaves.Count -eq 1) { $fileLeaf = $fileLeaves[0] }
    Assert ($fileLeaf -and $fileLeaf.title -eq $viewLeafName) `
        "the file viewer's leaf reports title=$viewLeafName (got '$($fileLeaf.title)')"

    # The caption, read off a top-level window of the app. GetWindowTextW is
    # the right reader here and not the T175 cache trap: this is a TOP-LEVEL
    # window whose text the owning app sets with SetWindowTextW, which is
    # exactly the value the cross-process read returns (the stale-cache hazard
    # is for controls whose text only ever answers WM_GETTEXT).
    $titled = $false
    for ($t = 0; $t -lt 25 -and -not $titled; $t++) {
        foreach ($top in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
            $caption = Get-TestWindowText -Window ([IntPtr]$top.Hwnd)
            if ($caption -match ('^' + [regex]::Escape($viewLeafName) + '( \[DEBUG\])?$')) { $titled = $true }
        }
        if (-not $titled) { Start-Sleep -Milliseconds 200 }
    }
    Assert $titled "a window caption reads '$viewLeafName' (the pane title reached the titlebar)"

    # And the human `+list` prints it: the row used to be `view:` followed by a
    # location and nothing else where the Mac prints the document's name.
    $human = (& $exe +list 2>&1 | Out-String)
    # Anchored right after `view:` -- the row is `view: <title>  <url>`, so a
    # loose match would be satisfied by the URL's own basename and pass with the
    # title still empty.
    Assert ($human -match ('(?m)^\s*view:\s+' + [regex]::Escape($viewLeafName) + '\s')) `
        '+list (human) prints the viewer title on its view: row'

    # A CODE file, split beside a terminal: the two file modes take different
    # branches of the injection (`setMarkdown` vs `setCode` + a language id), so
    # one of them working says nothing about the other.
    $codeFile = Join-Path $repo 'build.zig'
    $r = Invoke-Verb @('+split', '--target=vp', '--name=vpcode', "--view=$codeFile")
    Assert ($r.Code -eq 0) "+split --view=<code file> exits 0 (got $($r.Code))"
    $codeLeaf = Wait-Leaf 'vp' 'vpcode'
    Assert ($null -ne $codeLeaf) '+split --view=<code file> registers the pane'
    if ($codeLeaf) {
        Assert ($codeLeaf.type -eq 'viewer') "the code leaf reports type=viewer (got '$($codeLeaf.type)')"
        Assert ($codeLeaf.url -eq $codeFile) "the code leaf reports url=<the file> (got '$($codeLeaf.url)')"
    }
    Assert ((Get-PaneCount 'vp') -eq ($panesNow + 1)) "the file split grew the window by one pane (now $(Get-PaneCount 'vp'))"

    # A FILE viewer is not a second class of viewer: the terminal-only verbs
    # refuse it with the same string a web one gets.
    $r = Invoke-Verb @('+read', '--name=vpcode', '--lines=1')
    Assert ($r.Code -ne 0) "+read against a file viewer exits nonzero (got $($r.Code))"
    Assert (($r.Out -replace '\s+', ' ') -match [regex]::Escape($notTerminal)) "+read against a file viewer reports '$notTerminal'"

    # A MISSING file still opens a pane. The error belongs IN the page, where
    # the user can read the path that failed, not in a refusal that leaves
    # nothing on screen to correct.
    $missing = Join-Path $repo 'no-such-file-t90e.md'
    $r = Invoke-Verb @('+new-window', '--target=vpmissing', "--view=$missing")
    Assert ($r.Code -eq 0) "+new-window --view=<missing file> exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 'vpmissing')) 'a missing file still opens a viewer window'

    # And the human renderer prints the file on its view: row, the same way it
    # prints a URL.
    $human = (& $exe +list 2>&1 | Out-String)
    Assert ($human -match [regex]::Escape((Split-Path $viewFile -Leaf))) '+list (human) prints the viewed file on a view: row'

    # The GUI's OWN log is the only oracle out here for whether the page
    # actually loaded, and one line carries the whole chain. "viewer file
    # error" is written from the NavigationCompleted handler, which fires only
    # after the template has been SERVED -- through an interception, from a
    # synthetic origin that does not exist in DNS, out of the bundled assets
    # the app resolved for itself. So the missing-file pane reporting its error
    # says the REAL app (not just the unit test, which overrides the assets
    # path) got all the way to the injection.
    $applog = ''
    for ($t = 0; $t -lt 25; $t++) {
        $applog = (Get-Content $errlog -Raw -ErrorAction SilentlyContinue)
        if ($applog -match 'viewer file error') { break }
        Start-Sleep -Milliseconds 200
    }
    Assert ($applog -match 'viewer file error: Cannot read file') 'the missing file reached the in-page error card, so the template loaded in the GUI'
    Assert ($applog -notmatch 'no bundled viewer assets found') 'the app resolved its own bundled viewer assets'
    Assert ($applog -notmatch 'viewer resource not found: (viewer\.|vendor/)') 'every template asset the page asked for was served'
    Assert ($applog -notmatch 'ExecuteScript failed') 'the content injection was accepted'

    # --- 8a1. the table-of-contents card (T160) ------------------------------
    # README.md renders with 2+ headings, so its pane must grow a native
    # `GhozttyViewerTOC` card window -- proof the page posted its headings up
    # the bridge and the REAL app built the card from them. Which LAYOUT the
    # card is in (gutter vs overlay, shown vs toggled closed) depends on the
    # pane's width in DIP on this desktop, so presentation behavior lives in
    # the win32 lane's live host-floor test, which drives both layouts by
    # resizing; what is asserted here is structure, with the COUNT as the
    # negative control: the blank, code and missing-file panes opened above
    # must not have one (code files and 0/1-heading documents get no card).
    $tocCount = -1
    for ($t = 0; $t -lt 50; $t++) {
        $tocs = @()
        foreach ($top in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
            foreach ($h in @(Get-TestChildWindows -Window ([IntPtr]$top.Hwnd) -Class 'GhozttyViewer')) {
                $tocs += @(Get-TestChildWindows -Window ([IntPtr]$h.Hwnd) -Class 'GhozttyViewerTOC')
            }
        }
        $tocCount = @($tocs).Count
        if ($tocCount -ge 1) { break }
        Start-Sleep -Milliseconds 300
    }
    Assert ($tocCount -eq 1) "exactly the README pane grew a GhozttyViewerTOC card (got $tocCount)"

    # --- 8a2. a ~ --view path resolves against the home directory (T388) -----
    # `--view=~/x.md` used to reach the server as `<cwd>\~\x.md`: the tilde was
    # never expanded (the one leg of Mac's `expandingTildeInPath` that T90e's
    # port could not carry, because resolution happens CLI-side before the
    # server sees the path). The pane's `url` is the externally visible product
    # of that resolution, so it is the oracle: a real file under %USERPROFILE%
    # opened through `~` must list back as the absolute path. Both separators,
    # because a Windows user types a backslash.
    # The fixture is deleted in the OUTER finally, after the app is stopped:
    # the two panes below WATCH this file (live reload), and deleting it while
    # they are open re-renders them into error cards mid-run -- WebView2
    # activity that blurred the focused terminal and broke the T395 fallback
    # case two hundred lines later.
    $tildeName = "t388-tilde-$PID.md"
    $tildeAbs = Join-Path $env:USERPROFILE $tildeName
    Set-Content -Path $tildeAbs -Value '# t388 fixture' -Encoding utf8
    foreach ($case in @(
            @{ View = "~/$tildeName"; Pane = 'vptildef' },
            @{ View = "~\$tildeName"; Pane = 'vptildeb' }
        )) {
        $r = Invoke-Verb @('+split', '--target=vp', "--name=$($case.Pane)", "--view=$($case.View)")
        Assert ($r.Code -eq 0) "+split --view=$($case.View) exits 0 (got $($r.Code))"
        $leaf = Wait-Leaf 'vp' $case.Pane
        Assert ($null -ne $leaf) "+split --view=$($case.View) registers the pane"
        if ($leaf) {
            Assert ($leaf.url -eq $tildeAbs) "the $($case.View) leaf reports the absolute home path (got '$($leaf.url)')"
        }
    }

    # --- 8b. +reload (T390) --------------------------------------------------
    # The verb's contract is entirely about WHICH pane it accepts and what it
    # says about the ones it does not, so every rejection is asserted on its
    # exact text: the two terminal refusals are different strings on purpose
    # (a named terminal is a mistake about that pane; a window is a mistake
    # about which pane has focus) and neither is the `is a viewer pane, not a
    # terminal` string the terminal-only verbs use.
    $r = Invoke-Verb @('+reload', '--target=vpcode')
    Assert ($r.Code -eq 0) "+reload on a viewer pane exits 0 (got $($r.Code))"
    Assert ($r.Out.Trim() -eq '') "+reload on a viewer prints nothing (got '$($r.Out.Trim())')"

    $r = Invoke-Verb @('+reload', '--target=vpfile')
    Assert ($r.Code -eq 0) "+reload on a WINDOW whose focused pane is a viewer exits 0 (got $($r.Code))"

    $r = Invoke-Verb @('+reload', '--target=vpterm')
    Assert ($r.Code -ne 0) "+reload on a terminal pane exits nonzero (got $($r.Code))"
    # `-replace '\s+', ' '` before every string match on stderr: PS 5.1 wraps
    # a native command's error records at the CONSOLE width, so on a narrow
    # runner the asserted sentence arrives with a newline in the middle of a
    # word and the raw match fails width-dependently (seen 2026-08-06: the
    # wrap fell inside "reload" and only on this runner's width).
    Assert (($r.Out -replace '\s+', ' ') -match [regex]::Escape("target 'vpterm' is a terminal pane, nothing to reload")) `
        '+reload on a terminal pane reports the Mac string'

    # A window target resolves to its FOCUSED pane, so this case needs a window
    # whose focus is unambiguous. `vp` is not one: it has grown viewer splits,
    # and the last split created is the focused one -- pointing at it here
    # asserted the wrong pane and passed for the wrong reason. A window with a
    # single terminal in it can only mean one thing.
    Invoke-Verb @('+new-window', '--target=vpterms') | Out-Null
    Assert ($null -ne (Wait-Win 'vpterms')) 'a terminal-only window exists to aim at'
    $r = Invoke-Verb @('+reload', '--target=vpterms')
    Assert ($r.Code -ne 0) "+reload on a terminal-focused WINDOW exits nonzero (got $($r.Code))"
    Assert (($r.Out -replace '\s+', ' ') -match [regex]::Escape("focused pane of 'vpterms' is a terminal pane, nothing to reload")) `
        '+reload on a terminal-focused window reports the OTHER Mac string'

    $r = Invoke-Verb @('+reload', '--target=no-such-pane')
    Assert ($r.Code -ne 0) "+reload on an unknown target exits nonzero (got $($r.Code))"
    Assert (($r.Out -replace '\s+', ' ') -match 'not found in registry') '+reload on an unknown target says so'

    $r = Invoke-Verb @('+reload')
    Assert ($r.Code -ne 0) "+reload with no --target exits nonzero (got $($r.Code))"
    Assert (($r.Out -replace '\s+', ' ') -match [regex]::Escape('--target is required for +reload')) `
        '+reload with no --target says which flag is missing'

    # And it RELOADED, rather than returning success from a handler that found
    # the pane and did nothing. The missing-file viewer re-renders its file on
    # reload, which means it re-reads a path that is still not there and writes
    # a SECOND `viewer file error` line -- an oracle inside the GUI process, on
    # the same code path the file watcher will use (T391).
    $before = @(Select-String -Path $errlog -Pattern 'viewer file error: Cannot read file' -ErrorAction SilentlyContinue).Count
    $r = Invoke-Verb @('+reload', '--target=vpmissing')
    Assert ($r.Code -eq 0) "+reload on the missing-file viewer exits 0 (got $($r.Code))"
    $after = $before
    for ($t = 0; $t -lt 25 -and $after -le $before; $t++) {
        Start-Sleep -Milliseconds 200
        $after = @(Select-String -Path $errlog -Pattern 'viewer file error: Cannot read file' -ErrorAction SilentlyContinue).Count
    }
    Assert ($after -gt $before) "+reload re-rendered the file in the GUI (error lines $before -> $after)"

    # --- 9. --view + --command / -e: the Mac string -------------------------
    # The one permanent check. Asserted with a FILE and a URL both: it is the
    # command line that is ambiguous, not the destination, and a conflict that
    # only fired for one mode would be a conflict check that quietly stopped
    # covering the other.
    foreach ($case in @(
            @{ Label = '--command (file)'; Args = @('+new-window', '--target=vpx', "--view=$viewFile", '--command=cmd.exe') },
            @{ Label = '-e (file)'; Args = @('+new-window', '--target=vpx', "--view=$viewFile", '-e', 'cmd.exe') },
            @{ Label = '--command (url)'; Args = @('+new-window', '--target=vpx', "--view=$blank", '--command=cmd.exe') },
            @{ Label = '-e (url)'; Args = @('+new-window', '--target=vpx', "--view=$blank", '-e', 'cmd.exe') },
            @{ Label = '+split --command (url)'; Args = @('+split', '--target=vp', "--view=$blank", '--command=cmd.exe') }
        )) {
        $r = Invoke-Verb $case.Args
        Assert ($r.Code -ne 0) "--view with $($case.Label) exits nonzero (got $($r.Code))"
        Assert (($r.Out -replace '\s+', ' ') -match [regex]::Escape($conflict)) "--view with $($case.Label) reports the Mac conflict string"
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

    # --- 11. a terminal split FROM a viewer starts where the file is (T395) --
    # A viewer runs no shell, so there is no parent cwd to inherit; Mac takes
    # the viewed FILE's own directory (`splitConfigFromViewer`). The fixture
    # dir is deliberately somewhere the app was NEVER started from, so "it
    # matched" cannot be the app's own cwd leaking through.
    #
    # The control needs care, because "no override" is NOT "no cwd": the core
    # already seeds a new surface from the last focused TERMINAL's pwd
    # (`apprt/surface.zig:194-201`), and focusing a viewer does not change that
    # -- a viewer is not a core surface. So the fallback is a REAL directory,
    # and the two cases are told apart by making it a KNOWN one: a base pane in
    # `$t395other`. The file viewer must beat it; the web viewer must not.
    $t395dir = Join-Path $env:TEMP 'ghoztty-t395-splitcwd'
    $t395other = Join-Path $env:TEMP 'ghoztty-t395-other'
    New-Item -ItemType Directory -Force -Path $t395dir | Out-Null
    New-Item -ItemType Directory -Force -Path $t395other | Out-Null
    Set-Content -Path (Join-Path $t395dir 'doc.md') -Value "# T395`n" -Encoding utf8
    $t395doc = Join-Path $t395dir 'doc.md'

    # Normalizes for comparison: `+list` reports the cwd as the shell sees it,
    # which can differ from the fixture path in separator and case only.
    function Test-SameDir([string]$a, [string]$b) {
        if (-not $a -or -not $b) { return $false }
        $na = $a.Replace('/', '\').TrimEnd('\')
        $nb = $b.Replace('/', '\').TrimEnd('\')
        return $na -ieq $nb
    }

    # Reads a leaf's cwd, retrying: it lands on the leaf a moment after the
    # pane does (seeded from termio by the first `+list` that sees it).
    function Get-LeafCwd($target, $name, $want) {
        $cwd = ''
        for ($t = 0; $t -lt 25; $t++) {
            $leaf = Get-Leaf $target $name
            if ($leaf) {
                $cwd = $leaf.working_directory
                if (Test-SameDir $cwd $want) { break }
            }
            Start-Sleep -Milliseconds 200
        }
        return $cwd
    }

    # The known fallback: a terminal in a directory that is NOT the file's.
    # It is the last focused core surface from here on, so it is what a split
    # gets when the viewer contributes nothing.
    $r = Invoke-Verb @('+split', '--target=vp', '--name=t395base', "--working-directory=$t395other")
    Assert ($r.Code -eq 0) "+split --working-directory=<other dir> exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Leaf 'vp' 't395base')) 'the base terminal exists'
    Assert (Test-SameDir (Get-LeafCwd 'vp' 't395base' $t395other) $t395other) 'the base terminal is in the other dir'

    # NEGATIVE CONTROL first, while the fallback is unambiguous: a WEB viewer
    # has no file (Mac's `fileURL` is nil), so it must contribute nothing and
    # the split must land on the fallback. Without this, the assertion below
    # passes for a fix that hands every split off a viewer some fixed path.
    $r = Invoke-Verb @('+split', '--target=vp', '--name=t395web', "--view=$blank")
    Assert ($r.Code -eq 0) "+split --view=$blank exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Leaf 'vp' 't395web')) 'the web viewer pane exists'
    $r = Invoke-Verb @('+split', '--pane=t395web', '--name=t395webterm')
    Assert ($r.Code -eq 0) "+split off the web viewer exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Leaf 'vp' 't395webterm')) 'the terminal split off the web viewer exists'
    $wcwd = Get-LeafCwd 'vp' 't395webterm' $t395other
    Assert (Test-SameDir $wcwd $t395other) "a web viewer contributes no cwd, so the fallback stands (got '$wcwd')"

    # And the case under test: a FILE viewer's directory beats that fallback.
    $r = Invoke-Verb @('+split', '--target=vp', '--name=t395doc', "--view=$t395doc")
    Assert ($r.Code -eq 0) "+split --view=<file in the fixture dir> exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Leaf 'vp' 't395doc')) 'the file viewer pane exists'
    # No `--working-directory`, so nothing but the viewer parent can answer.
    $r = Invoke-Verb @('+split', '--pane=t395doc', '--name=t395term')
    Assert ($r.Code -eq 0) "+split off the file viewer exits 0 (got $($r.Code))"
    $t395term = Wait-Leaf 'vp' 't395term'
    Assert ($null -ne $t395term) 'the terminal split off the file viewer exists'
    if ($t395term) {
        Assert ($t395term.type -eq 'terminal') "the split off a viewer is a terminal (got $($t395term.type))"
        $cwd = Get-LeafCwd 'vp' 't395term' $t395dir
        Assert (Test-SameDir $cwd $t395dir) "it starts in the viewed file's directory (got '$cwd', want '$t395dir')"
        Assert (-not (Test-SameDir $cwd $t395other)) 'and NOT in the last-focused-terminal fallback'
    }

    # The fixture dirs are left in %TEMP% on purpose: a terminal pane's cwd IS
    # one of them, so Windows would refuse to remove it anyway, and the next
    # run recreates them idempotently.

    # --- 11b. T394: app keybind chords forward OUT of a focused viewer -------
    # The user's 2026-08-05 report: with a viewer focused, ctrl+w and ctrl+f4
    # did nothing and there was no keyboard way out of the pane. The chords
    # here go to the WebView2 (Chromium) child HWND via Send-TestViewerChord,
    # which shares the modifier state with BOTH the Chromium thread (it
    # classifies the accelerator) and the app's UI thread (its
    # AcceleratorKeyPressed callback reads GetKeyState).
    #
    # T157's lesson drives the shape: the terminal-side chord comes FIRST as
    # the positive control, so a dead viewer chord below cannot be blamed on
    # keybinds being broken in general.

    function Get-TabCount($target) {
        $w = Get-Win $target
        if (-not $w) { return 0 }
        return @($w.tabs).Count
    }
    # Get-Leaf/Wait-Leaf above only read tabs[0]; the T394 fixture puts its
    # viewer in tab 2, so this pair searches every tab.
    function Get-LeafAnyTab($target, $name) {
        $w = Get-Win $target
        if (-not $w) { return $null }
        foreach ($tab in @($w.tabs)) {
            foreach ($leaf in @(Get-Leaves $tab.splits)) {
                if ($leaf.name -eq $name) { return $leaf }
            }
        }
        return $null
    }
    function Wait-LeafAnyTab($target, $name) {
        for ($t = 0; $t -lt 25; $t++) {
            $leaf = Get-LeafAnyTab $target $name
            if ($leaf) { return $leaf }
            Start-Sleep -Milliseconds 200
        }
        return $null
    }
    function Wait-TabCount($target, [int]$want) {
        for ($t = 0; $t -lt 25; $t++) {
            if ((Get-TabCount $target) -eq $want) { return $true }
            Start-Sleep -Milliseconds 200
        }
        return $false
    }
    # The command palette is a WS_POPUP of the terminal class with an EDIT
    # child (Surface.ensureCommandPalette); "open" = such a window is visible.
    function Test-PaletteOpen {
        foreach ($w in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyTerminal')) {
            if (-not $w.Visible) { continue }
            if (@(Get-TestChildWindows -Window ([IntPtr]$w.Hwnd) -Class 'Edit').Count -ge 1) { return $true }
        }
        return $false
    }

    # A fresh window, so tab/pane counts start from a known shape.
    $topsBefore = @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow' | ForEach-Object { $_.Hwnd })
    Invoke-Verb @('+new-window', '--target=t394') | Out-Null
    Assert ($null -ne (Wait-Win 't394')) 'T394 window created'
    $t394top = [IntPtr]::Zero
    for ($t = 0; $t -lt 25 -and $t394top -eq [IntPtr]::Zero; $t++) {
        foreach ($w in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
            if ($topsBefore -notcontains $w.Hwnd) { $t394top = [IntPtr][int64]$w.Hwnd }
        }
        if ($t394top -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 200 }
    }
    Assert ($t394top -ne [IntPtr]::Zero) 'T394 found the new top-level window'

    if ($t394top -ne [IntPtr]::Zero) {
        # POSITIVE CONTROL: the same chord from the TERMINAL pane must work,
        # or nothing below means anything.
        Focus-TestWindow -Window $t394top | Out-Null
        Start-Sleep -Milliseconds 400
        $t394surface = [IntPtr](Get-TestFocusedWindow -Window $t394top)
        Assert ((Get-TestWindowClass -Window $t394surface) -eq 'GhozttyTerminal') 'T394 CONTROL: focus starts on a terminal surface'
        Assert (Send-TestKeys -Window $t394top -Target $t394surface -Modifiers ctrl -Key T) 'T394 CONTROL: ctrl+t injected at the terminal'
        Assert (Wait-TabCount 't394' 2) 'T394 CONTROL: ctrl+t from a terminal added a tab'

        # Split a viewer into the now-active tab. The new pane takes focus.
        Invoke-Verb @('+split', '--target=t394', '--name=t394view', "--view=$blank") | Out-Null
        $t394viewLeaf = Wait-LeafAnyTab 't394' 't394view'
        Assert ($null -ne $t394viewLeaf) 'T394 viewer pane created'

        # The Chromium input HWND arrives with the async controller; wait for
        # it. The visible GhozttyViewer host belongs to the ACTIVE tab.
        # Chrome_WidgetWin_1, specifically: WebView2's hwnd chain under our
        # host is Chrome_WidgetWin_0 -> Chrome_WidgetWin_1 ->
        # Chrome_RenderWidgetHostHWND, and _1 is the only one whose message
        # loop turns a posted WM_KEYDOWN into an AcceleratorKeyPressed event
        # (probed on-box, 2026-08-06: _0 and RenderWidgetHost both ignore it).
        $chrome = [IntPtr]::Zero
        for ($t = 0; $t -lt 50 -and $chrome -eq [IntPtr]::Zero; $t++) {
            foreach ($h in @(Get-TestChildWindows -Window $t394top -Class 'GhozttyViewer')) {
                if (-not $h.Visible) { continue }
                $kids = @(Get-TestChildWindows -Window ([IntPtr][int64]$h.Hwnd) -Class '*')
                $widget = @($kids | Where-Object { $_.Class -eq 'Chrome_WidgetWin_1' })
                if ($widget.Count -ge 1) { $chrome = [IntPtr][int64]$widget[0].Hwnd; $t394host = [IntPtr][int64]$h.Hwnd }
            }
            if ($chrome -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 200 }
        }
        Assert ($chrome -ne [IntPtr]::Zero) 'T394 found the Chromium input child under the viewer host'

        if ($chrome -ne [IntPtr]::Zero) {
            # ctrl+shift+p from INSIDE the viewer opens the command palette.
            Assert (Send-TestViewerChord -Window $t394top -Target $chrome -Modifiers ctrl,shift -Key P) 'T394 ctrl+shift+p injected at the viewer'
            $palette = $false
            for ($t = 0; $t -lt 25 -and -not $palette; $t++) { $palette = Test-PaletteOpen; if (-not $palette) { Start-Sleep -Milliseconds 200 } }
            Assert $palette 'T394 ctrl+shift+p from a viewer opened the command palette'
            if ($palette) {
                # Escape closes it again (palette keys are app-side).
                foreach ($w in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyTerminal')) {
                    if ($w.Visible) {
                        foreach ($e in @(Get-TestChildWindows -Window ([IntPtr][int64]$w.Hwnd) -Class 'Edit')) {
                            Send-TestControlKey -Control ([IntPtr][int64]$e.Hwnd) -Key Escape | Out-Null
                        }
                    }
                }
                Start-Sleep -Milliseconds 500
            }

            # ctrl+t from INSIDE the viewer adds a tab.
            Focus-TestWindow -Window $t394top -Child $t394host | Out-Null
            Start-Sleep -Milliseconds 400
            Assert (Send-TestViewerChord -Window $t394top -Target $chrome -Modifiers ctrl -Key T) 'T394 ctrl+t injected at the viewer'
            Assert (Wait-TabCount 't394' 3) 'T394 ctrl+t from a viewer added a tab'

            # Walk back to the viewer's tab (ctrl+shift+[ = previous_tab,
            # from the fresh tab's terminal), re-focus the viewer, and close
            # it with ctrl+w -- the exact chord the user pressed into a dead
            # pane on 2026-08-05.
            Focus-TestWindow -Window $t394top | Out-Null
            Start-Sleep -Milliseconds 400
            $tabSurface = [IntPtr](Get-TestFocusedWindow -Window $t394top)
            Send-TestKeys -Window $t394top -Target $tabSurface -Modifiers ctrl,shift -Key 0xDB | Out-Null
            Start-Sleep -Milliseconds 600
            Focus-TestWindow -Window $t394top -Child $t394host | Out-Null
            Start-Sleep -Milliseconds 400
            Assert (Send-TestViewerChord -Window $t394top -Target $chrome -Modifiers ctrl -Key W) 'T394 ctrl+w injected at the viewer'
            $gone = $false
            for ($t = 0; $t -lt 25 -and -not $gone; $t++) {
                $gone = ($null -eq (Get-LeafAnyTab 't394' 't394view'))
                if (-not $gone) { Start-Sleep -Milliseconds 200 }
            }
            Assert $gone 'T394 ctrl+w from a viewer closed the viewer pane'
            Assert (-not ($app.Process -and $app.Process.HasExited)) 'T394 no crash closing a viewer from its own accelerator'
        }
    }

    # --- 11c. T396: the three viewer palette entries -------------------------
    # The Mac palette carries "Viewer: Open File in Pane…", "Viewer: Open URL
    # in Pane…" and "Viewer: Open Browser Pane"; before T396 the win32 palette
    # had none, so there was no interactive way to open a viewer at all. Each
    # entry is asserted by OUTCOME through the palette (the command-registry
    # lesson: a row that is absent cannot dispatch, so an outcome proves
    # presence AND dispatch in one move). One fresh window per case, because a
    # created viewer split takes focus and the next case's palette chord needs
    # a terminal surface to land on.

    function Open-T396Window([string]$target, [array]$topsKnown) {
        Invoke-Verb @('+new-window', "--target=$target") | Out-Null
        if ($null -eq (Wait-Win $target)) { return $null }
        $newTop = [IntPtr]::Zero
        for ($t = 0; $t -lt 25 -and $newTop -eq [IntPtr]::Zero; $t++) {
            foreach ($w in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
                if ($topsKnown -notcontains $w.Hwnd) { $newTop = [IntPtr][int64]$w.Hwnd }
            }
            if ($newTop -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 200 }
        }
        return $newTop
    }

    # Open the palette on $top's focused terminal, type $filter, press Enter.
    function Invoke-T396Palette([IntPtr]$top, [string]$filter, [string]$label) {
        Focus-TestWindow -Window $top | Out-Null
        Start-Sleep -Milliseconds 400
        $pane = [IntPtr](Get-TestFocusedWindow -Window $top)
        if ((Get-TestWindowClass -Window $pane) -ne 'GhozttyTerminal') {
            Write-Host "  (${label}: focus is not on a terminal surface)"; return $false
        }
        $popup = [IntPtr]::Zero
        foreach ($try in 1..3) {
            if (-not (Send-TestKeys -Window $top -Target $pane -Modifiers ctrl, shift -Key P)) { continue }
            $popup = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyTerminal' -TimeoutMs 5000
            if ($popup -ne [IntPtr]::Zero) { break }
        }
        if ($popup -eq [IntPtr]::Zero) { Write-Host "  (${label}: palette popup not found)"; return $false }
        $palEdit = Find-TestWindowEx -Parent $popup -Class 'EDIT'
        if ($palEdit -eq [IntPtr]::Zero) { Write-Host "  (${label}: palette edit not found)"; return $false }
        Send-TestControlText -Control $palEdit -Text $filter | Out-Null
        return (Send-TestControlKey -Control $palEdit -Key Enter)
    }

    # A viewer leaf in $target whose url matches $urlPattern (the T396 panes
    # are unnamed — the palette cannot name them — so they are found by kind).
    function Wait-T396ViewerLeaf($target, [string]$urlPattern) {
        for ($t = 0; $t -lt 25; $t++) {
            $w = Get-Win $target
            if ($w) {
                foreach ($leaf in @(Get-Leaves $w.tabs[0].splits)) {
                    if ($leaf.type -eq 'viewer' -and $leaf.url -match $urlPattern) { return $leaf }
                }
            }
            Start-Sleep -Milliseconds 200
        }
        return $null
    }

    $topsKnown = @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow' | ForEach-Object { $_.Hwnd })

    # --- T396 case A: "Viewer: Open Browser Pane" ----------------------------
    $t396aTop = Open-T396Window 't396a' $topsKnown
    Assert ($null -ne $t396aTop -and $t396aTop -ne [IntPtr]::Zero) 'T396A window created'
    if ($t396aTop -ne [IntPtr]::Zero) {
        Assert (Invoke-T396Palette $t396aTop 'Open Browser Pane' 'T396A') 'T396A palette filter + Enter delivered'
        $leaf = Wait-T396ViewerLeaf 't396a' '^about:blank$'
        Assert ($null -ne $leaf) 'T396A "Open Browser Pane" split an about:blank viewer beside the terminal'
        Assert ((Get-PaneCount 't396a') -eq 2) "T396A the window has terminal + viewer (got $(Get-PaneCount 't396a'))"
    }
    $topsKnown += @($t396aTop)

    # --- T396 case B: "Viewer: Open URL in Pane…" ----------------------------
    # The typed address has no scheme, so the leaf's url proves the omnibox
    # completion ran (localhost is completed to plain http, T159's rule —
    # https://localhost would just fail). Port 1 so nothing answers and no
    # real network is touched; a failed LOAD is fine, the location stands.
    $t396bTop = Open-T396Window 't396b' $topsKnown
    Assert ($null -ne $t396bTop -and $t396bTop -ne [IntPtr]::Zero) 'T396B window created'
    if ($t396bTop -ne [IntPtr]::Zero) {
        Assert (Invoke-T396Palette $t396bTop 'Open URL in Pane' 'T396B') 'T396B palette filter + Enter delivered'
        $urlDlg = Wait-TestWindow -ProcessId $appPid -Class 'GhozttyRenameDialog' -TimeoutMs 5000
        Assert ($urlDlg -ne [IntPtr]::Zero) 'T396B the URL prompt opened'
        if ($urlDlg -ne [IntPtr]::Zero) {
            Assert ((Get-TestWindowText -Window $urlDlg) -eq 'Open URL in Viewer Pane') `
                "T396B the prompt carries the Mac caption (got '$(Get-TestWindowText -Window $urlDlg)')"
            $urlEdit = Find-TestWindowEx -Parent $urlDlg -Class 'EDIT'
            Assert ($urlEdit -ne [IntPtr]::Zero) 'T396B the prompt has an edit field'
            if ($urlEdit -ne [IntPtr]::Zero) {
                Set-TestControlText -Control $urlEdit -Text 'localhost:1' | Out-Null
                Send-TestControlKey -Control $urlEdit -Key Enter | Out-Null
                $leaf = Wait-T396ViewerLeaf 't396b' '^http://localhost:1/?$'
                Assert ($null -ne $leaf) 'T396B "Open URL in Pane" completed localhost:1 to http:// and split a viewer'
            }
        }
    }
    $topsKnown += @($t396bTop)

    # --- T396 case C: "Viewer: Open File in Pane…" ---------------------------
    # The entry opens the standard open-file dialog (#32770). What is asserted:
    # the dialog opens (dispatch reached it), the IPC pump stays LIVE while it
    # is up (the dialog's modal loop still dispatches WM_APP_IPC — the design
    # constraint the task named), and Escape cancels without a pane appearing.
    $t396cTop = Open-T396Window 't396c' $topsKnown
    Assert ($null -ne $t396cTop -and $t396cTop -ne [IntPtr]::Zero) 'T396C window created'
    if ($t396cTop -ne [IntPtr]::Zero) {
        Assert (Invoke-T396Palette $t396cTop 'Open File in Pane' 'T396C') 'T396C palette filter + Enter delivered'
        $fileDlg = Wait-TestWindow -ProcessId $appPid -Class '#32770' -TimeoutMs 8000
        Assert ($fileDlg -ne [IntPtr]::Zero) 'T396C "Open File in Pane" opened the standard file dialog'
        if ($fileDlg -ne [IntPtr]::Zero) {
            $data = Get-Data
            Assert ($null -ne $data) 'T396C IPC still answers while the file dialog is up'
            Send-TestControlKey -Control $fileDlg -Key Escape | Out-Null
            $gone = $false
            for ($t = 0; $t -lt 25 -and -not $gone; $t++) {
                $gone = ((Get-TestWindow -ProcessId $appPid -Class '#32770') -eq [IntPtr]::Zero)
                if (-not $gone) { Start-Sleep -Milliseconds 200 }
            }
            Assert $gone 'T396C Escape dismissed the file dialog'
            Assert ((Get-PaneCount 't396c') -eq 1) "T396C cancel opened no pane (got $(Get-PaneCount 't396c'))"
        }
        Assert (-not ($app.Process -and $app.Process.HasExited)) 'T396C app alive after the file dialog'
    }

    # --- 11d. T161: pane-scoped chords + keyboard page zoom ------------------
    # The chords that mean something different while a viewer holds focus:
    # ctrl+r reloads the pane, ctrl+d / ctrl+l / alt+d focus the address bar,
    # and ctrl+plus/minus/0 zoom the page. Oracles, because nothing outside a
    # WebView2 can see its render:
    #   - reload: a raw-TCP page server (relay-account.ps1's shape -- no
    #     HttpListener URL-ACL) logs one line per GET and answers no-store, so
    #     a real reload MUST produce a new hit line.
    #   - zoom: the served page mirrors window.devicePixelRatio into
    #     document.title, which DocumentTitleChanged carries into the leaf's
    #     title in `+list --json`. put_ZoomFactor changes the ratio by exactly
    #     the step, so the title is a zoom readout (ratio math, not absolute:
    #     the test desktop's DPI scale is part of the number).
    #   - address bar: the focused hwnd becomes the nav bar's EDIT
    #     (Get-TestFocusedWindow), and the pane count does NOT move -- the
    #     negative that proves ctrl+d outranked its global split-right.
    # T157's lesson: the terminal-side ctrl+d split comes FIRST as the
    # positive control that chords are being delivered at all.

    $t161Hits = Join-Path $env:TEMP 'ghoztty-t161-hits.txt'
    Remove-Item $t161Hits -ErrorAction SilentlyContinue
    $t161Port = 47161
    $t161Job = Start-Job -ScriptBlock {
        param($port, $hitsFile)
        $html = '<html><head><title>dpr</title></head><body>t161' +
            '<script>function u(){document.title="dpr="+window.devicePixelRatio.toFixed(4)}' +
            'u();setInterval(u,100);</script></body></html>'
        $payload = [Text.Encoding]::UTF8.GetBytes($html)
        $head = "HTTP/1.1 200 OK`r`nContent-Type: text/html`r`nCache-Control: no-store`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n"
        $out = ([Text.Encoding]::UTF8.GetBytes($head) + $payload)
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        $listener.Start()
        while ($true) {
            $client = $listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                Start-Sleep -Milliseconds 50
                $buf = New-Object byte[] 8192
                $req = ''
                while ($stream.DataAvailable) {
                    $n = $stream.Read($buf, 0, $buf.Length)
                    if ($n -le 0) { break }
                    $req += [Text.Encoding]::UTF8.GetString($buf, 0, $n)
                }
                $line = ($req -split "`r`n")[0]
                if ($line -match '^GET ') { Add-Content -Path $hitsFile -Value $line }
                $stream.Write($out, 0, $out.Length)
                $stream.Flush()
            } catch {}
            $client.Close()
        }
    } -ArgumentList $t161Port, $t161Hits
    function Get-T161Hits {
        if (-not (Test-Path $t161Hits)) { return 0 }
        return @(Get-Content $t161Hits -ErrorAction SilentlyContinue).Count
    }
    function Wait-T161Hits([int]$above) {
        for ($t = 0; $t -lt 25; $t++) {
            if ((Get-T161Hits) -gt $above) { return $true }
            Start-Sleep -Milliseconds 200
        }
        return $false
    }
    # The leaf title as a devicePixelRatio readout; 0 while it is anything else.
    function Get-T161Dpr {
        $leaf = Get-LeafAnyTab 't161' 't161view'
        if ($leaf -and $leaf.title -match '^dpr=([0-9.]+)$') { return [double]$matches[1] }
        return 0.0
    }
    function Wait-T161Dpr([scriptblock]$ok) {
        for ($t = 0; $t -lt 25; $t++) {
            $d = Get-T161Dpr
            if ($d -gt 0 -and (& $ok $d)) { return $d }
            Start-Sleep -Milliseconds 200
        }
        return (Get-T161Dpr)
    }
    # The nav bar's address EDIT under a viewer host (EnumChildWindows
    # recurses, so one call from the host finds the nested EDIT).
    function Get-T161NavEdit($hostHwnd) {
        foreach ($nb in @(Get-TestChildWindows -Window $hostHwnd -Class 'GhozttyViewerNav')) {
            $edits = @(Get-TestChildWindows -Window ([IntPtr][int64]$nb.Hwnd) -Class 'Edit')
            if ($edits.Count -ge 1) { return [IntPtr][int64]$edits[0].Hwnd }
        }
        return [IntPtr]::Zero
    }
    function Wait-T161AddressFocused($top, $hostHwnd) {
        for ($t = 0; $t -lt 25; $t++) {
            $edit = Get-T161NavEdit $hostHwnd
            if ($edit -ne [IntPtr]::Zero -and
                ([IntPtr](Get-TestFocusedWindow -Window $top)) -eq $edit) { return $true }
            Start-Sleep -Milliseconds 200
        }
        return $false
    }

    $t161ok = $false
    foreach ($i in 1..20) {
        try {
            $probe = [System.Net.Sockets.TcpClient]::new(); $probe.Connect('127.0.0.1', $t161Port); $probe.Close()
            $t161ok = $true; break
        } catch { Start-Sleep -Milliseconds 250 }
    }
    Assert $t161ok 'T161 page server is listening'

    $topsKnown = @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow' | ForEach-Object { $_.Hwnd })
    $t161top = Open-T396Window 't161' $topsKnown
    Assert ($null -ne $t161top -and $t161top -ne [IntPtr]::Zero) 'T161 window created'

    if ($t161ok -and $t161top -ne [IntPtr]::Zero) {
        # POSITIVE CONTROL: ctrl+d on the TERMINAL is still the global
        # split-right. Proves chord delivery works before any negative below.
        Focus-TestWindow -Window $t161top | Out-Null
        Start-Sleep -Milliseconds 400
        $t161surface = [IntPtr](Get-TestFocusedWindow -Window $t161top)
        Assert ((Get-TestWindowClass -Window $t161surface) -eq 'GhozttyTerminal') 'T161 CONTROL: focus starts on a terminal surface'
        Assert (Send-TestKeys -Window $t161top -Target $t161surface -Modifiers ctrl -Key D) 'T161 CONTROL: ctrl+d injected at the terminal'
        $split = $false
        for ($t = 0; $t -lt 25 -and -not $split; $t++) {
            $split = ((Get-PaneCount 't161') -eq 2)
            if (-not $split) { Start-Sleep -Milliseconds 200 }
        }
        Assert $split 'T161 CONTROL: ctrl+d from a terminal split right (global meaning intact)'

        # The viewer under test, on the page server.
        Invoke-Verb @('+split', '--target=t161', '--name=t161view', "--view=http://127.0.0.1:$t161Port/") | Out-Null
        Assert ($null -ne (Wait-LeafAnyTab 't161' 't161view')) 'T161 viewer pane created'
        $dpr0 = Wait-T161Dpr { param($d) $d -gt 0 }
        Assert ($dpr0 -gt 0) "T161 page loaded and mirrors devicePixelRatio into the title (got '$dpr0')"

        # The Chromium input child, same discovery as T394.
        $t161chrome = [IntPtr]::Zero
        $t161host = [IntPtr]::Zero
        for ($t = 0; $t -lt 50 -and $t161chrome -eq [IntPtr]::Zero; $t++) {
            foreach ($h in @(Get-TestChildWindows -Window $t161top -Class 'GhozttyViewer')) {
                if (-not $h.Visible) { continue }
                $kids = @(Get-TestChildWindows -Window ([IntPtr][int64]$h.Hwnd) -Class '*')
                $widget = @($kids | Where-Object { $_.Class -eq 'Chrome_WidgetWin_1' })
                if ($widget.Count -ge 1) { $t161chrome = [IntPtr][int64]$widget[0].Hwnd; $t161host = [IntPtr][int64]$h.Hwnd }
            }
            if ($t161chrome -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 200 }
        }
        Assert ($t161chrome -ne [IntPtr]::Zero) 'T161 found the Chromium input child under the viewer host'

        if ($t161chrome -ne [IntPtr]::Zero) {
            Focus-TestWindow -Window $t161top -Child $t161host | Out-Null
            Start-Sleep -Milliseconds 400

            # ctrl+r reloads: the no-store page MUST be fetched again.
            $hits0 = Get-T161Hits
            Assert (Send-TestViewerChord -Window $t161top -Target $t161chrome -Modifiers ctrl -Key R) 'T161 ctrl+r injected at the viewer'
            Assert (Wait-T161Hits $hits0) 'T161 ctrl+r from a viewer re-fetched the page from the server'

            # The reload navigated; give the title mirror a beat, then zoom.
            $dpr0 = Wait-T161Dpr { param($d) $d -gt 0 }
            Assert (Send-TestViewerChord -Window $t161top -Target $t161chrome -Modifiers ctrl -Key plus) 'T161 ctrl+plus injected at the viewer'
            $dprIn = Wait-T161Dpr { param($d) [Math]::Abs($d / $dpr0 - 1.1) -lt 0.02 }
            Assert ([Math]::Abs($dprIn / $dpr0 - 1.1) -lt 0.02) "T161 ctrl+plus zoomed the page one 1.1 step (got $dpr0 -> $dprIn)"

            Assert (Send-TestViewerChord -Window $t161top -Target $t161chrome -Modifiers ctrl -Key '0') 'T161 ctrl+0 injected at the viewer'
            $dprReset = Wait-T161Dpr { param($d) [Math]::Abs($d / $dpr0 - 1.0) -lt 0.02 }
            Assert ([Math]::Abs($dprReset / $dpr0 - 1.0) -lt 0.02) "T161 ctrl+0 reset the zoom (got $dprReset, want $dpr0)"

            Assert (Send-TestViewerChord -Window $t161top -Target $t161chrome -Modifiers ctrl -Key minus) 'T161 ctrl+minus injected at the viewer'
            $dprOut = Wait-T161Dpr { param($d) [Math]::Abs($d / $dpr0 - (1.0 / 1.1)) -lt 0.02 }
            Assert ([Math]::Abs($dprOut / $dpr0 - (1.0 / 1.1)) -lt 0.02) "T161 ctrl+minus zoomed out one step (got $dpr0 -> $dprOut)"
            Send-TestViewerChord -Window $t161top -Target $t161chrome -Modifiers ctrl -Key '0' | Out-Null

            # ctrl+d from the VIEWER focuses the address bar and does NOT
            # split -- the pane-scoped chord outranks the global binding.
            $panes161 = Get-PaneCount 't161'
            Assert (Send-TestViewerChord -Window $t161top -Target $t161chrome -Modifiers ctrl -Key D) 'T161 ctrl+d injected at the viewer'
            Assert (Wait-T161AddressFocused $t161top $t161host) 'T161 ctrl+d from a viewer focused the address bar'
            Assert ((Get-PaneCount 't161') -eq $panes161) 'T161 ctrl+d from a viewer did NOT split (pane chord outranks global)'

            # ctrl+r AT the address field still reloads the pane: the chords
            # are pane-scoped, not page-scoped, and the field is in the pane.
            $hits1 = Get-T161Hits
            $t161edit = [IntPtr](Get-TestFocusedWindow -Window $t161top)
            Assert (Send-TestKeys -Window $t161top -Target $t161edit -Modifiers ctrl -Key R) 'T161 ctrl+r injected at the address field'
            Assert (Wait-T161Hits $hits1) 'T161 ctrl+r from the address field re-fetched the page'

            # ctrl+l and alt+d are the Windows-native address-bar aliases.
            Focus-TestWindow -Window $t161top -Child $t161host | Out-Null
            Start-Sleep -Milliseconds 400
            Assert (Send-TestViewerChord -Window $t161top -Target $t161chrome -Modifiers ctrl -Key L) 'T161 ctrl+l injected at the viewer'
            Assert (Wait-T161AddressFocused $t161top $t161host) 'T161 ctrl+l from a viewer focused the address bar'

            Focus-TestWindow -Window $t161top -Child $t161host | Out-Null
            Start-Sleep -Milliseconds 400
            Assert (Send-TestViewerChord -Window $t161top -Target $t161chrome -Modifiers alt -Key D) 'T161 alt+d injected at the viewer'
            Assert (Wait-T161AddressFocused $t161top $t161host) 'T161 alt+d from a viewer focused the address bar'

            Assert (-not ($app.Process -and $app.Process.HasExited)) 'T161 app alive after all viewer chords'
        }
    }

    # --- 12. app survived all of it ------------------------------------------
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'GUI process alive after all scenarios'
    Assert (-not (Test-TestDesktopLeak -ProcessId $appPid)) 'GUI never became visible on the interactive desktop'
} finally {
    Remove-TestDesktop
    Stop-RepoInstances
    # The T161 page server: a job blocked in AcceptTcpClient, stopped by force.
    if ($t161Job) {
        Stop-Job $t161Job -ErrorAction SilentlyContinue
        Remove-Job $t161Job -Force -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path $env:TEMP 'ghoztty-t161-hits.txt') -ErrorAction SilentlyContinue
    # The T388 home-dir fixture, deletable only now: while the app was alive
    # two viewer panes watched it, and a mid-run delete re-rendered them into
    # error cards (see section 8a2).
    if ($tildeAbs) { Remove-Item -Path $tildeAbs -Force -ErrorAction SilentlyContinue }
}

# Runs AFTER the cleanup, so it reads the surviving all-pids list -- the live
# one is emptied by Remove-TestDesktop and would score against nothing.
$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)"; exit 1 }
