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
    Assert ($r.Out -match [regex]::Escape($notTerminal)) "+read against a file viewer reports '$notTerminal'"

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
    Assert ($r.Out -match [regex]::Escape("target 'vpterm' is a terminal pane, nothing to reload")) `
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
    Assert ($r.Out -match [regex]::Escape("focused pane of 'vpterms' is a terminal pane, nothing to reload")) `
        '+reload on a terminal-focused window reports the OTHER Mac string'

    $r = Invoke-Verb @('+reload', '--target=no-such-pane')
    Assert ($r.Code -ne 0) "+reload on an unknown target exits nonzero (got $($r.Code))"
    Assert ($r.Out -match 'not found in registry') '+reload on an unknown target says so'

    $r = Invoke-Verb @('+reload')
    Assert ($r.Code -ne 0) "+reload with no --target exits nonzero (got $($r.Code))"
    Assert ($r.Out -match [regex]::Escape('--target is required for +reload')) `
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
        Assert ($r.Out -match [regex]::Escape($conflict)) "--view with $($case.Label) reports the Mac conflict string"
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

    # --- 12. app survived all of it ------------------------------------------
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
