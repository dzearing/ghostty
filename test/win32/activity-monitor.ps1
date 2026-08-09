# T285 + T286 acceptance: the win32 Activity Monitor panel and its process
# control.
#
# T284 built the arithmetic (activity_layout.zig / trend_gauge.zig) and T285
# built the window: an owner-drawn panel fed by the LOCAL process/metrics
# samplers, opened from the command palette, one panel per source.
#
# What only the running app can answer, and what this script asserts:
#
#   A. the palette command opens a real top-level `GhozttyActivityMonitor`
#      window titled "Activity - Local", with the three native controls the
#      layout module places (filter EDIT, "Show all" checkbox, a "New Process..."
#      button that is DISABLED until T286 gives it something to do);
#   B. the table POPULATES - the local sampler really ran and produced rows;
#   C. the registry FOCUSES rather than duplicates: a second palette invocation
#      leaves exactly one panel and says so;
#   D. the filter narrows the table, including against a KNOWN pid (the app's
#      own), and a needle that matches nothing empties it;
#   E. "Show all" widens it from the ghoztty-spawned tree to every process;
#   H. (T286) "New Process..." opens a modal dialog whose Start is disabled
#      until a command is typed, and starting one puts a REAL process on the box
#      and a row for it in the table;
#   I. (T286) Kill appears only with a selection, its confirmation names the
#      process and its pid, CANCELLING LEAVES THE PROCESS ALIVE (the negative
#      control for "the confirmation is mandatory") and confirming terminates it;
#      (T292) the panel KEEPS POLLING behind that open dialog, and a kill
#      confirmed after several snapshots have been retired underneath it still
#      lands on the right pid;
#   J. (T286) a failed action raises the dismissable error banner, and clicking
#      its glyph removes it;
#   K. (T290) a panel nobody can see does not enumerate: minimizing STOPS the
#      1.5s process sweep, restoring resumes it within one interval, and the
#      resume clears the trend history rather than stitching a gap across it;
#   L. (T289) keyboard focus is VISIBLE and it ROUTES: Tab walks filter ->
#      "Show all" -> [Kill] -> "New Process..." -> table and steps over a Kill
#      that is not on screen, the row keys reach the table only while the TABLE
#      holds focus, and the table - an owner-drawn region no theme rings for us
#      - paints design system 2.2's ring on its caret row exactly while it has
#      the keyboard.
#
# NOTHING THE BOX NEEDS IS EVER A TARGET. H spawns `cmd.exe /C pause` - a
# throwaway that blocks forever with no child process - and I only ever kills
# the pid the confirmation dialog ITSELF named, so a mis-targeted row makes the
# script fail rather than kill a bystander.
#
# ORACLE. A GDI-painted table has no text to read back, so the oracle is the
# app's own log line, emitted by `ActivityMonitor.rebuild` on every input
# change:
#
#   activity monitor: source=Local total=312 shown=7 needle="" show_all=false ...
#
# That is a derivation of the same state the painter walks, not a restatement of
# the assertion - `rebuild` computes `order_len` and then both paints it and
# logs it. A row count that is logged but not painted would still be a defect,
# which is why A also asserts the window and its controls exist for real.
#
# CONTROLS. A positive control (ctrl+shift+p opening the palette) runs first, so
# a broken injection aborts instead of reading as a T285 regression. The
# `-NegativeControl` switch inverts two load-bearing claims - D's (a needle that
# matches nothing is asserted to still show every row) and L's (the focus ring
# is asserted to be painted while the FILTER holds focus) - and that run MUST
# fail.
#
# T211/T217: runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1)
# and asserts at the end that it never took the user's foreground. The panel is
# a native window, so `Get-TestWindows` / `Find-TestWindowEx` read it faithfully
# (the capture limit is only the OpenGL terminal surface).
#
# T248: the repo's agent is killed and the app launched with
# --session-persistence=false, so a restored manifest cannot hand this run a
# previous run's panes.
#
# Only touches ghoztty processes running from this repo's zig-out*.
param([string]$ExePath, [switch]$NegativeControl, [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if (-not (Test-Path $exe)) { $exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe' }
if ($ExePath) { $exe = $ExePath }
$errlog = Join-Path $env:TEMP 'ghoztty-activity-monitor-stderr.log'
$env:GHOZTTY_PIPE_SUFFIX = '-activitytest'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\ColorMath.ps1')

# The panel's colors are DERIVED from the surface `window-theme` puts the app
# on (T308), which under the default `auto` is the terminal background - so the
# probes below need to know it. Pinned rather than assumed: every pasted
# literal in this script (the header band, the banner fill, the dismiss glyph)
# is now recomputed from this one value with the same rule the app uses, and a
# change to a wash amount moves the app and this oracle together.
$PANEL_BG = @(0x1E, 0x1E, 0x1E)
$PANEL_BG_HEX = Format-Rgb $PANEL_BG
$PANEL_HEADER = Get-PanelHeader $PANEL_BG
$PANEL_DIVIDER = Get-PanelRaised $PANEL_BG

$script:pass = 0
$script:fail = 0
# The T286 throwaway process, so the finally block can clean it up after an abort.
$script:spawnPid = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Kill-RepoInstances {
    foreach ($name in @('ghoztty.exe', 'ghoztty-agent.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$name'" |
            Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out*') } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 500
}

# The panel's most recent state line, or $null when it has never logged one.
function Get-PanelState {
    if (-not (Test-Path $errlog)) { return $null }
    $pat = 'activity monitor: source=(\S+) total=(\d+) shown=(\d+) needle="([^"]*)" show_all=(\w+) sort=(\w+)/(\w+) selected=(\d+)'
    $m = @(Select-String -Path $errlog -Pattern $pat) | Select-Object -Last 1
    if (-not $m) { return $null }
    $g = $m.Matches[0].Groups
    return [pscustomobject]@{
        Source   = $g[1].Value
        Total    = [int]$g[2].Value
        Shown    = [int]$g[3].Value
        Needle   = $g[4].Value
        ShowAll  = ($g[5].Value -eq 'true')
        SortKey  = $g[6].Value
        SortDir  = $g[7].Value
        Selected = [int]$g[8].Value
    }
}

# Wait until the panel has logged a state line whose needle/show_all match what
# we just set AND which is newer than $sinceCount lines. Returns the state.
function Wait-PanelState([int]$sinceCount, [int]$TimeoutMs = 6000) {
    $pat = 'activity monitor: source='
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $n = 0
        if (Test-Path $errlog) { $n = @(Select-String -Path $errlog -Pattern $pat).Count }
        if ($n -gt $sinceCount) { return Get-PanelState }
        Start-Sleep -Milliseconds 200
    }
    return Get-PanelState
}

function Count-PanelLines {
    if (-not (Test-Path $errlog)) { return 0 }
    return @(Select-String -Path $errlog -Pattern 'activity monitor: source=').Count
}

# Open the palette on $pane, type $filter, press Enter.
function Invoke-Palette([IntPtr]$top, [IntPtr]$pane, [string]$filter, [string]$label) {
    $popup = [IntPtr]::Zero
    foreach ($try in 1..3) {
        if (-not (Send-TestKeys -Window $top -Target $pane -Modifiers ctrl, shift -Key P)) { continue }
        $popup = Wait-TestWindow -ProcessId $script:app.Pid -Class 'GhozttyTerminal' -TimeoutMs 5000
        if ($popup -ne [IntPtr]::Zero) { break }
    }
    Assert ($popup -ne [IntPtr]::Zero) "$label palette opened"
    if ($popup -eq [IntPtr]::Zero) { return $false }
    $edit = Find-TestWindowEx -Parent $popup -Class 'EDIT'
    if ($edit -eq [IntPtr]::Zero) { Write-Host "SETUP FAIL: $label palette edit not found"; return $false }
    Send-TestControlText -Control $edit -Text $filter | Out-Null
    $sent = Send-TestControlKey -Control $edit -Key Enter
    Start-Sleep -Milliseconds 900
    return $sent
}

# Is there a pixel of EXACTLY $Rgb in the screen-coordinate box?
#
# Exact, not "bluer than it is red": ClearType renders body text with COLOR
# FRINGES, so a channel-dominance probe finds bluish pixels wherever there is
# text and would have passed against a panel whose charts never painted. GDI
# fills a solid brush / strokes a solid pen with no antialiasing, so the tint
# lands as its literal constant and an exact match is both stricter and
# quieter.
#
# The constants are ActivityMonitor.zig's COLOR_CPU / COLOR_MEM.
function Test-ExactPixel($Shot, [int]$X0, [int]$Y0, [int]$X1, [int]$Y1, [int[]]$Rgb) {
    for ($y = $Y0; $y -lt $Y1; $y += 1) {
        for ($x = $X0; $x -lt $X1; $x += 1) {
            $c = Get-TestPixel -Shot $Shot -X $x -Y $y
            if ($null -eq $c) { continue }
            if ($c.R -eq $Rgb[0] -and $c.G -eq $Rgb[1] -and $c.B -eq $Rgb[2]) { return $true }
        }
    }
    return $false
}

function Get-Panels {
    return @(Get-TestWindows -ProcessId $script:app.Pid -Class 'GhozttyActivityMonitor')
}

# How many pixels in the box are NOT $Rgb. "The rim is bare background" and
# "the rim got painted" are the same measurement, read in two directions.
function Count-NonMatching($Shot, [int]$X0, [int]$Y0, [int]$X1, [int]$Y1, [int[]]$Rgb) {
    $n = 0
    for ($y = $Y0; $y -lt $Y1; $y += 1) {
        for ($x = $X0; $x -lt $X1; $x += 1) {
            $c = Get-TestPixel -Shot $Shot -X $x -Y $y
            if ($null -eq $c) { continue }
            if ($c.R -ne $Rgb[0] -or $c.G -ne $Rgb[1] -or $c.B -ne $Rgb[2]) { $n++ }
        }
    }
    return $n
}

# The FIRST screen coordinate in the box whose pixel is exactly $Rgb, or $null.
# Test-ExactPixel answers "is it there"; this answers "where", which is what a
# click on a PAINTED control (the banner's dismiss glyph) needs.
function Find-ExactPixel($Shot, [int]$X0, [int]$Y0, [int]$X1, [int]$Y1, [int[]]$Rgb) {
    for ($y = $Y0; $y -lt $Y1; $y += 1) {
        for ($x = $X0; $x -lt $X1; $x += 1) {
            $c = Get-TestPixel -Shot $Shot -X $x -Y $y
            if ($null -eq $c) { continue }
            if ($c.R -eq $Rgb[0] -and $c.G -eq $Rgb[1] -and $c.B -eq $Rgb[2]) {
                return [pscustomobject]@{ X = $x; Y = $y }
            }
        }
    }
    return $null
}

# Click a control by POSTING a mouse pair to it.
#
# Send-TestControlClick SENDS BM_CLICK, and every T286 action button opens a
# MODAL dialog whose nested pump does not return until the user answers - a sent
# click would sit in it until the harness's send timeout expired. Posted input is
# also what a real click is.
function Click-TestPosted([IntPtr]$Top, $Ctl) {
    $h = [IntPtr]$Ctl.Hwnd
    $r = Get-TestWindowRect -Window $h
    return Send-TestMouse -Window $Top -Target $h `
        -X ([int](($r.Left + $r.Right) / 2)) -Y ([int](($r.Top + $r.Bottom) / 2)) `
        -Button left -Action click
}

# The most recent stderr line matching $Pattern, as a regex Match, or $null.
function Get-LogMatch([string]$Pattern) {
    if (-not (Test-Path $errlog)) { return $null }
    $m = @(Select-String -Path $errlog -Pattern $Pattern) | Select-Object -Last 1
    if (-not $m) { return $null }
    return $m.Matches[0]
}

function Wait-LogMatch([string]$Pattern, [int]$TimeoutMs = 10000) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $m = Get-LogMatch $Pattern
        if ($m) { return $m }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Test-PidAlive([int]$ProcessId) {
    if ($ProcessId -le 0) { return $false }
    return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

# T291: every VISIBLE console-hosting top-level on the test desktop, any
# process. Both classes matter: this box delegates the default terminal to
# Windows Terminal, so a CREATE_NEW_CONSOLE flash can surface as a CASCADIA
# window rather than classic conhost's ConsoleWindowClass.
function Get-ConsoleWindows {
    return @(@(Get-TestWindows -ProcessId 0 -Class '*') |
        Where-Object { $_.Class -in @('ConsoleWindowClass', 'CASCADIA_HOSTING_WINDOW_CLASS') })
}

# The panel's action buttons, by caption. Hidden children are included (Kill is
# created hidden), so a caller can assert visibility separately.
function Get-PanelButton([IntPtr]$Panel, [string]$Like) {
    return @(Get-TestChildWindows -Window $Panel -Class 'Button') |
        Where-Object { (Get-TestControlText -Control ([IntPtr]$_.Hwnd)) -like $Like } |
        Select-Object -First 1
}

# Screen Y of the table's FIRST row, FOUND rather than derived: scan down the
# panel's right edge for the header band's fill (COLOR_HEADER_BG), then past it
# and past its bottom rule (COLOR_DIVIDER). Re-deriving the layout module's band
# offsets here is exactly what T257 is about.
function Get-TestFirstRowY([IntPtr]$Panel, $Client, $Fr) {
    $shot = Get-TestWindowPixels -Window $Panel
    try {
        $x = $Client.Right - 20
        $headerY = -1
        for ($y = [int]$Fr.Bottom; $y -lt $Client.Bottom; $y++) {
            $c = Get-TestPixel -Shot $shot -X $x -Y $y
            if ($null -ne $c -and $c.R -eq $PANEL_HEADER[0] -and $c.G -eq $PANEL_HEADER[1] -and $c.B -eq $PANEL_HEADER[2]) { $headerY = $y; break }
        }
        if ($headerY -lt 0) { return @(-1, -1) }
        for ($y = $headerY; $y -lt $Client.Bottom; $y++) {
            $c = Get-TestPixel -Shot $shot -X $x -Y $y
            if ($null -eq $c) { continue }
            if ($c.R -eq $PANEL_HEADER[0] -and $c.G -eq $PANEL_HEADER[1] -and $c.B -eq $PANEL_HEADER[2]) { continue }
            if ($c.R -eq $PANEL_DIVIDER[0] -and $c.G -eq $PANEL_DIVIDER[1] -and $c.B -eq $PANEL_DIVIDER[2]) { continue }
            return @($headerY, $y)
        }
        return @($headerY, -1)
    } finally {
        Close-TestWindowPixels -Shot $shot
    }
}

Kill-RepoInstances
Remove-Item $errlog -ErrorAction SilentlyContinue
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    $script:app = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false', "--background=$PANEL_BG_HEX") -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: top window not found'; exit 1 }
    $pane = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($pane -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no pane'; exit 1 }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'window is NOT enumerable on the interactive desktop'
    Assert ((@(Get-Panels)).Count -eq 0) 'setup: no Activity Monitor panel before the command runs'

    # --- Positive control ----------------------------------------------------
    # Opening the palette at all proves the chord injection path works, so a
    # later "the panel never opened" is a product verdict and not a dead probe.
    $ctlPopup = [IntPtr]::Zero
    foreach ($try in 1..3) {
        if (-not (Send-TestKeys -Window $top -Target $pane -Modifiers ctrl, shift -Key P)) { continue }
        $ctlPopup = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyTerminal' -TimeoutMs 5000
        if ($ctlPopup -ne [IntPtr]::Zero) { break }
    }
    if ($ctlPopup -eq [IntPtr]::Zero) {
        Write-Host 'ABORT: positive control failed (palette never opened) - injection broken, not a T285 verdict'
        exit 1
    }
    Write-Host 'OK    positive control: ctrl+shift+p opens the palette'
    $ctlEdit = Find-TestWindowEx -Parent $ctlPopup -Class 'EDIT'
    if ($ctlEdit -ne [IntPtr]::Zero) { Send-TestControlKey -Control $ctlEdit -Key Escape | Out-Null }
    Start-Sleep -Milliseconds 400

    # --- A. The command opens a real panel with its controls -----------------
    if (-not (Invoke-Palette $top $pane 'ACTIVITY MONITOR' 'A')) {
        Write-Host 'SETUP FAIL: palette dispatch not delivered'; exit 1
    }
    $panel = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyActivityMonitor' -TimeoutMs 8000
    Assert ($panel -ne [IntPtr]::Zero) 'A "Open Activity Monitor" opens a GhozttyActivityMonitor window'
    if ($panel -eq [IntPtr]::Zero) { throw 'no panel to test' }

    $title = Get-TestWindowText -Window $panel
    Assert ($title -like 'Activity*Local*') "A the panel is titled for its source (got '$title')"

    $filterEdit = Find-TestWindowEx -Parent $panel -Class 'EDIT'
    Assert ($filterEdit -ne [IntPtr]::Zero) 'A the filter EDIT exists'

    # The window class is "Button", and Get-TestChildWindows compares class
    # names EXACTLY - 'BUTTON' matches nothing.
    $buttons = @(Get-TestChildWindows -Window $panel -Class 'Button')
    $showAll = $buttons | Where-Object { (Get-TestControlText -Control ([IntPtr]$_.Hwnd)) -eq 'Show all' } | Select-Object -First 1
    $newProc = $buttons | Where-Object { (Get-TestControlText -Control ([IntPtr]$_.Hwnd)) -like 'New Process*' } | Select-Object -First 1
    Assert ($null -ne $showAll) 'A the "Show all" checkbox exists'
    Assert ($null -ne $newProc) 'A the "New Process..." button exists'
    if ($newProc) {
        # T286 gave it something to do, so it is live now. (Until then it was
        # deliberately disabled - an honest state, design system 2.2.)
        Assert (Test-TestWindowEnabled -Window ([IntPtr]$newProc.Hwnd)) 'A "New Process..." is ENABLED (T286)'
    }
    # Kill is absent until rows are selected (Mac shows it only then). Created
    # hidden rather than omitted, so it must not be VISIBLE.
    $killBtn = $buttons | Where-Object { (Get-TestControlText -Control ([IntPtr]$_.Hwnd)) -like 'Kill*' } | Select-Object -First 1
    Assert ($null -ne $killBtn) 'A the Kill button exists as a control'
    if ($killBtn) {
        Assert (-not (Test-TestWindowVisible -Window ([IntPtr]$killBtn.Hwnd))) 'A Kill is HIDDEN while nothing is selected'
    }

    # The panel is resizable and opens at the layout module's default client.
    $rect = Get-TestWindowRect -Window $panel
    Assert (($rect.Right - $rect.Left) -ge 620) 'A the panel opens at least min_client_w wide'
    Assert (($rect.Bottom - $rect.Top) -ge 380) 'A the panel opens at least min_client_h tall'

    # --- B. The table populated ----------------------------------------------
    $st = Wait-PanelState 0
    Assert ($null -ne $st) 'B the panel logged its table state'
    if ($null -eq $st) { throw 'no panel state to test' }
    Assert ($st.Source -eq 'Local') 'B the source is Local'
    Assert ($st.Total -gt 10) "B the local sampler produced a real process table (total=$($st.Total))"
    Assert ($st.Shown -ge 1) "B the ghoztty-spawned tree has at least the app itself (shown=$($st.Shown))"
    Assert ($st.Shown -le $st.Total) 'B the spawned tree is a subset of every process'
    Assert (-not $st.ShowAll) 'B "Show all" starts off (Mac default)'
    Assert ($st.SortKey -eq 'cpu' -and $st.SortDir -eq 'desc') 'B the initial sort is cpu-descending, like Mac'

    # --- B2. It PAINTED. ------------------------------------------------------
    # The state line above proves the model; these prove the painter ran. The
    # probes are anchored to the FILTER CONTROL's own screen rect (which the
    # layout module placed), never to numbers re-derived from that module -
    # the T257 lesson. Everything above the filter is the gauge band, and
    # everything below it is the table.
    # Wait for a THIRD poll first: a chart with one sample has no segment to
    # stroke and paints nothing, which is correct and would read here as "the
    # chart never painted". Each adopted snapshot logs one state line, at
    # trend_gauge.sample_interval_ms.
    $deadline = (Get-Date).AddSeconds(12)
    while ((Count-PanelLines) -lt 3 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
    Assert ((Count-PanelLines) -ge 3) 'B2 the panel keeps polling on its timer (3+ samples)'

    $client = Get-TestWindowRect -Window $panel -Client
    $fr = Get-TestWindowRect -Window $filterEdit
    $shot = Get-TestWindowPixels -Window $panel
    try {
        $colors = Get-TestDistinctColors -Shot $shot
        Assert ($colors -ge 8) "B2 the panel painted a real surface, not a flat fill ($colors distinct colors)"
        # The two gauges split the band 50/50, so the CPU chart is in its left
        # half and the Memory chart in its right half.
        $gTop = $client.Top
        $gBot = $fr.Top
        $mid = [int](($client.Left + $client.Right) / 2)
        # `panel_theme.cpu_base` / `mem_base`, floored to 3:1 against the
        # panel - both already clear it on this background, so the expected
        # pixel is the hue itself.
        $CPU_TINT = $PANEL_CPU_BASE
        $MEM_TINT = $PANEL_MEM_BASE
        Assert (Test-ExactPixel $shot $client.Left $gTop $mid $gBot $CPU_TINT) 'B2 the CPU trend chart painted in its blue tint'
        Assert (Test-ExactPixel $shot $mid $gTop $client.Right $gBot $MEM_TINT) 'B2 the Memory trend chart painted in its green tint'
        # Control probes for the two above: each tint belongs to ONE gauge, so
        # finding it in the other half would mean the probe is measuring
        # something other than the chart it names.
        Assert (-not (Test-ExactPixel $shot $mid $gTop $client.Right $gBot $CPU_TINT)) 'B2 (control) the CPU tint is confined to the CPU half'
        Assert (-not (Test-ExactPixel $shot $client.Left $gTop $mid $gBot $MEM_TINT)) 'B2 (control) the Memory tint is confined to the Memory half'
        # And neither tint appears in the TABLE, below the control bar - so a
        # pass above is the gauge band and not some panel-wide accent.
        Assert (-not (Test-ExactPixel $shot $client.Left $fr.Bottom $client.Right $client.Bottom $CPU_TINT)) 'B2 (control) the CPU tint does not appear in the table'
    } finally {
        Close-TestWindowPixels -Shot $shot
    }

    # --- C. A second open FOCUSES, it does not duplicate ---------------------
    $before = Count-PanelLines
    Invoke-Palette $top $pane 'ACTIVITY MONITOR' 'C' | Out-Null
    Start-Sleep -Milliseconds 700
    $panels = @(Get-Panels)
    Assert ($panels.Count -eq 1) "C a second `"Open Activity Monitor`" leaves exactly ONE panel (found $($panels.Count): $(($panels | ForEach-Object { $_.Class }) -join ','))"
    Assert (Select-String -Path $errlog -Pattern 'activity monitor: focusing existing panel' -Quiet) 'C the registry reported a focus, not a second open'
    Assert (@(Select-String -Path $errlog -Pattern 'activity monitor: opening source=').Count -eq 1) 'C only one panel was ever opened'

    # --- D. The filter narrows -----------------------------------------------
    $baseline = Get-PanelState
    $before = Count-PanelLines
    Send-TestControlText -Control $filterEdit -Text 'ghoztty' | Out-Null
    $st = Wait-PanelState $before
    Assert ($st.Needle -eq 'ghoztty') "D the filter text reached the panel (needle='$($st.Needle)')"
    Assert ($st.Shown -le $baseline.Shown) "D filtering never widens the table ($($st.Shown) <= $($baseline.Shown))"

    # A KNOWN pid: the app's own must be in the spawned tree, and filtering on
    # it must find it.
    $before = Count-PanelLines
    Set-TestControlText -Control $filterEdit -Text "$($app.Pid)" | Out-Null
    $st = Wait-PanelState $before
    Assert ($st.Needle -eq "$($app.Pid)") 'D the pid filter reached the panel'
    Assert ($st.Shown -ge 1) "D the table finds the app's own pid $($app.Pid) (shown=$($st.Shown))"

    # A needle nothing matches empties the table. This is the claim the
    # negative control inverts.
    $before = Count-PanelLines
    Set-TestControlText -Control $filterEdit -Text 'zzqqxx-no-such-process' | Out-Null
    $st = Wait-PanelState $before
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: asserting an unmatchable needle still shows every row - this run MUST fail'
        Assert ($st.Shown -eq $st.Total) "D (inverted): unmatchable needle shows all $($st.Total) rows (really shown=$($st.Shown))"
    } else {
        Assert ($st.Shown -eq 0) "D an unmatchable needle empties the table (shown=$($st.Shown))"
    }

    # --- E. "Show all" widens from the spawned tree to every process ---------
    $before = Count-PanelLines
    Set-TestControlText -Control $filterEdit -Text '' | Out-Null
    $st = Wait-PanelState $before
    Assert ($st.Needle -eq '') 'E the filter cleared'
    $spawnedOnly = $st.Shown

    $before = Count-PanelLines
    Send-TestControlClick -Control ([IntPtr]$showAll.Hwnd) | Out-Null
    $st = Wait-PanelState $before
    Assert ($st.ShowAll) 'E clicking "Show all" reaches the panel'
    Assert ($st.Shown -eq $st.Total) "E Show-all shows every process ($($st.Shown) of $($st.Total))"
    Assert ($st.Shown -gt $spawnedOnly) "E the spawned-only view really was narrower ($spawnedOnly -> $($st.Shown))"

    # --- G. Clicking a column header re-sorts --------------------------------
    # The header band is FOUND, not derived: scan down the panel's right edge
    # for the first row painted in the derived header band. Re-deriving the
    # layout module's band offsets here is what T257 is about.
    $shot2 = Get-TestWindowPixels -Window $panel
    $headerY = -1
    try {
        for ($y = [int]$fr.Bottom; $y -lt $client.Bottom -and $headerY -lt 0; $y++) {
            $c = Get-TestPixel -Shot $shot2 -X ($client.Right - 20) -Y $y
            if ($null -ne $c -and $c.R -eq $PANEL_HEADER[0] -and $c.G -eq $PANEL_HEADER[1] -and $c.B -eq $PANEL_HEADER[2]) { $headerY = $y }
        }
    } finally {
        Close-TestWindowPixels -Shot $shot2
    }
    Assert ($headerY -ge 0) 'G the table header band was located by its own paint'
    if ($headerY -ge 0) {
        # The last column (Path) is unbounded, so a point 20px inside the
        # client's right edge is inside it at any width. Send-TestMouse takes
        # SCREEN coordinates (it SetCursorPos's them and ScreenToClient's them
        # itself) - passing client coords lands the click somewhere else
        # entirely.
        $cx = $client.Right - 20
        $cy = $headerY + 4
        $before = Count-PanelLines
        Send-TestMouse -Window $panel -X $cx -Y $cy -Button left -Action click | Out-Null
        $st = Wait-PanelState $before
        Assert ($st.SortKey -eq 'path' -and $st.SortDir -eq 'asc') "G clicking the last header sorts by it, ascending (got $($st.SortKey)/$($st.SortDir))"
        $before = Count-PanelLines
        Send-TestMouse -Window $panel -X $cx -Y $cy -Button left -Action click | Out-Null
        $st = Wait-PanelState $before
        Assert ($st.SortKey -eq 'path' -and $st.SortDir -eq 'desc') "G clicking it again flips the direction (got $($st.SortKey)/$($st.SortDir))"
    }

    # --- H. New Process starts a real process (T286) --------------------------
    # A THROWAWAY: `cmd.exe /C pause` blocks forever on its own console with no
    # child process, so killing it in I leaves nothing orphaned and nothing this
    # box needs is ever a target.
    $newProcBtn = Get-PanelButton $panel 'New Process*'
    Assert ($null -ne $newProcBtn) 'H the New Process button is reachable'
    # T291 baseline: visible console windows on the test desktop BEFORE the
    # spawn, any process (the console window belongs to conhost or the
    # delegated terminal, never to the app or the spawned child) - plus the
    # console-DELEGATION host processes. On a box whose default terminal is
    # Windows Terminal (this one), a CREATE_NEW_CONSOLE spawn's window opens in
    # WT on the INTERACTIVE desktop, which no test-desktop enumeration can see;
    # what IS observable from here is the OpenConsole.exe/WindowsTerminal.exe
    # process the delegation starts. CREATE_NO_WINDOW never delegates (a
    # headless console goes to classic conhost), so a new delegation host
    # appearing during the spawn IS the flash. Measured, not assumed: the
    # experiment in T291's progress log showed the old flag starting
    # conhost.exe + OpenConsole.exe from a test-desktop spawner.
    $consolesBefore = Get-ConsoleWindows
    $delegationBefore = @(Get-Process -Name 'OpenConsole', 'WindowsTerminal' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    Click-TestPosted $panel $newProcBtn | Out-Null
    $dlg = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyNewProcess' -TimeoutMs 8000
    Assert ($dlg -ne [IntPtr]::Zero) 'H "New Process..." opens the GhozttyNewProcess dialog'
    if ($dlg -ne [IntPtr]::Zero) {
        # IsWindowEnabled on the owner is the cross-process-safe modality check.
        Assert (-not (Test-TestWindowEnabled -Window $panel)) 'H the dialog is MODAL to the panel'

        $edits = @(Get-TestChildWindows -Window $dlg -Class 'Edit') | Sort-Object Top
        Assert ($edits.Count -eq 2) "H the dialog has a command field and a working-directory field (found $($edits.Count))"
        $dlgBtns = @(Get-TestChildWindows -Window $dlg -Class 'Button')
        $startBtn = $dlgBtns | Where-Object { (Get-TestControlText -Control ([IntPtr]$_.Hwnd)) -eq 'Start' } | Select-Object -First 1
        Assert ($null -ne $startBtn) 'H the dialog has a Start button'
        if ($startBtn) {
            Assert (-not (Test-TestWindowEnabled -Window ([IntPtr]$startBtn.Hwnd))) 'H Start is DISABLED while the command is blank (Mac parity)'
        }

        if ($edits.Count -eq 2 -and $startBtn) {
            Send-TestControlText -Control ([IntPtr]$edits[0].Hwnd) -Text 'pause' | Out-Null
            Start-Sleep -Milliseconds 400
            Assert (Test-TestWindowEnabled -Window ([IntPtr]$startBtn.Hwnd)) 'H typing a command ENABLES Start'
            Send-TestControlClick -Control ([IntPtr]$startBtn.Hwnd) | Out-Null
        } else {
            Send-TestWindowClose -Window $dlg | Out-Null
        }
        Start-Sleep -Milliseconds 600
    }
    Assert (Test-TestWindowEnabled -Window $panel) 'H the panel is interactive again once the dialog closes'

    $m = Wait-LogMatch 'activity monitor: spawn result ok=true pid=(\d+)'
    Assert ($null -ne $m) 'H the spawn reported success with a pid'
    $spawnPid = 0
    if ($m) { $spawnPid = [int]$m.Groups[1].Value; $script:spawnPid = $spawnPid }
    Assert (Test-PidAlive $spawnPid) "H the spawned process $spawnPid is really running"

    # T291: the spawn must not flash a console window. CREATE_NO_WINDOW gives
    # the child a WINDOWLESS console, so the throwaway `cmd.exe /C pause` stays
    # alive (asserted just above - the whole risk of this change is trading the
    # visible console for a dead child) while nothing appears on the desktop.
    Start-Sleep -Milliseconds 300
    $consolesAfter = Get-ConsoleWindows
    Assert ($consolesAfter.Count -le $consolesBefore.Count) "H no console window appeared on the test desktop (before=$($consolesBefore.Count) after=$($consolesAfter.Count))"

    # The delegation probe waits out a cold start: a NEGATIVE needs a bounded
    # watch, and the experiment showed the delegation host up well inside 3s.
    $newDelegation = @()
    $probeDeadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $probeDeadline) {
        $newDelegation = @(Get-Process -Name 'OpenConsole', 'WindowsTerminal' -ErrorAction SilentlyContinue |
            Where-Object { $delegationBefore -notcontains $_.Id })
        if ($newDelegation.Count -gt 0) { break }
        Start-Sleep -Milliseconds 300
    }
    Assert ($newDelegation.Count -eq 0) "H the spawn started no delegated-terminal host (new: $(@($newDelegation | ForEach-Object { "$($_.Name):$($_.Id)" }) -join ' '))"

    # And the MECHANISM: the diag note reports the dwCreationFlags value that
    # CreateProcessW actually received. CREATE_NO_WINDOW (0x08000000) must be
    # set and CREATE_NEW_CONSOLE (0x10) clear.
    $mFlags = Get-LogMatch 'activity monitor: spawn result ok=true pid=\d+ note=diag: flags=0x([0-9a-fA-F]+)'
    $flagsVal = [int64]0
    if ($mFlags) { $flagsVal = [Convert]::ToInt64($mFlags.Groups[1].Value, 16) }
    Assert (($null -ne $mFlags) -and (($flagsVal -band 0x08000000) -ne 0) -and (($flagsVal -band 0x10) -eq 0)) "H the spawn passed CREATE_NO_WINDOW and not CREATE_NEW_CONSOLE (flags=0x$('{0:x8}' -f $flagsVal))"

    # ...and it reaches the TABLE, which is the claim a log line alone cannot make.
    $before = Count-PanelLines
    Set-TestControlText -Control $filterEdit -Text "$spawnPid" | Out-Null
    $st = Wait-PanelState $before
    Assert ($st.Shown -ge 1) "H the spawned pid $spawnPid appears in the table (shown=$($st.Shown))"

    # --- I. Kill goes through a mandatory confirmation ------------------------
    # Sort by PID ASCENDING first, so row 0 is deterministic: any OTHER pid whose
    # decimal string contains this one's has more digits, hence is numerically
    # larger. Without that, "the first row" is whatever the previous section's
    # sort left behind.
    $rowInfo = Get-TestFirstRowY $panel $client $fr
    $headerY2 = $rowInfo[0]
    Assert ($headerY2 -ge 0) 'I the table header band was located by its own paint'
    if ($headerY2 -ge 0) {
        $before = Count-PanelLines
        Send-TestMouse -Window $panel -X ($client.Left + 20) -Y ($headerY2 + 4) -Button left -Action click | Out-Null
        $st = Wait-PanelState $before
        Assert ($st.SortKey -eq 'pid' -and $st.SortDir -eq 'asc') "I sorted by PID ascending (got $($st.SortKey)/$($st.SortDir))"
    }

    $rowInfo = Get-TestFirstRowY $panel $client $fr
    $rowY = $rowInfo[1]
    Assert ($rowY -ge 0) 'I the first table row was located by its own paint'
    if ($rowY -ge 0) {
        $before = Count-PanelLines
        Send-TestMouse -Window $panel -X ($client.Left + 20) -Y ($rowY + 4) -Button left -Action click | Out-Null
        $st = Wait-PanelState $before
        Assert ($st.Selected -eq 1) "I clicking a row selects exactly one (selected=$($st.Selected))"
    }

    $killBtn2 = Get-PanelButton $panel 'Kill*'
    Assert ($null -ne $killBtn2) 'I the Kill button is reachable'
    if ($killBtn2) {
        Assert (Test-TestWindowVisible -Window ([IntPtr]$killBtn2.Hwnd)) 'I Kill BECOMES visible once a row is selected'
        Assert ((Get-TestControlText -Control ([IntPtr]$killBtn2.Hwnd)) -eq 'Kill') 'I one selected row labels it "Kill", not "Kill 1"'
    }

    # I.1 CANCEL - the negative control for "the confirmation is mandatory".
    # If the dialog were cosmetic, this alone would kill the process.
    $confirmedPid = 0
    if ($killBtn2) {
        Click-TestPosted $panel $killBtn2 | Out-Null
        $confirm = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyConfirmDialog' -TimeoutMs 8000
        Assert ($confirm -ne [IntPtr]::Zero) 'I Kill opens a confirmation dialog'
        if ($confirm -ne [IntPtr]::Zero) {
            $ctitle = Get-TestWindowText -Window $confirm
            Assert ($ctitle -like "*(PID $spawnPid)*") "I the confirmation names the process and its pid (got '$ctitle')"
            if ($ctitle -like "*(PID $spawnPid)*") { $confirmedPid = $spawnPid }

            # I.1a (T292) The panel keeps POLLING behind the open confirmation -
            # Mac's sheet is presented over a model that never stops, and a chart
            # that freezes for as long as a dialog is up is the divergence this
            # arm exists to catch. Same oracle section B uses: each adopted
            # snapshot logs one state line.
            $duringBefore = Count-PanelLines
            $deadline = (Get-Date).AddSeconds(8)
            while ((Count-PanelLines) -lt ($duringBefore + 2) -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 300
            }
            $duringAfter = Count-PanelLines
            Assert ($duringAfter -ge $duringBefore + 2) "I the gauges keep advancing while the confirmation is open ($duringBefore -> $duringAfter)"

            $cbtns = @(Get-TestChildWindows -Window $confirm -Class 'Button')
            $cancelBtn = $cbtns | Where-Object { (Get-TestControlText -Control ([IntPtr]$_.Hwnd)) -eq 'Cancel' } | Select-Object -First 1
            Assert ($null -ne $cancelBtn) 'I the confirmation offers Cancel'
            if ($cancelBtn) { Send-TestControlClick -Control ([IntPtr]$cancelBtn.Hwnd) | Out-Null }
            else { Send-TestWindowClose -Window $confirm | Out-Null }
            Start-Sleep -Milliseconds 700
        }
        Assert ($null -ne (Wait-LogMatch 'activity monitor: kill dialog n=1 choice=cancel' 5000)) 'I cancelling is reported as a cancel'
        Assert (Test-PidAlive $spawnPid) "I CANCELLING LEAVES THE PROCESS ALIVE ($spawnPid)"
    }

    # I.2 CONFIRM - and only against the pid the dialog itself named, so a
    # mis-targeted row can never make this script kill something else.
    if ($confirmedPid -eq $spawnPid -and $spawnPid -gt 0) {
        Click-TestPosted $panel $killBtn2 | Out-Null
        $confirm = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyConfirmDialog' -TimeoutMs 8000
        Assert ($confirm -ne [IntPtr]::Zero) 'I Kill opens the confirmation a second time'
        if ($confirm -ne [IntPtr]::Zero) {
            $ctitle = Get-TestWindowText -Window $confirm
            $cbtns = @(Get-TestChildWindows -Window $confirm -Class 'Button')
            $okBtn = $cbtns | Where-Object { (Get-TestControlText -Control ([IntPtr]$_.Hwnd)) -eq 'Kill' } | Select-Object -First 1
            Assert ($null -ne $okBtn) 'I the affirmative button carries the Kill verb, not "OK"'
            # (T292) Let a couple of polls land underneath before confirming, so
            # the batch this kills was marshaled out of a snapshot that has since
            # been retired. The result assertions below are what proves it: the
            # kill still targets the right pid and its report still names it.
            $killBefore = Count-PanelLines
            $deadline = (Get-Date).AddSeconds(8)
            while ((Count-PanelLines) -lt ($killBefore + 2) -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 300
            }
            if ($okBtn -and $ctitle -like "*(PID $spawnPid)*") {
                Send-TestControlClick -Control ([IntPtr]$okBtn.Hwnd) | Out-Null
            } else {
                Send-TestWindowClose -Window $confirm | Out-Null
            }
            Start-Sleep -Milliseconds 900
        }
        Assert ($null -ne (Wait-LogMatch 'activity monitor: kill result total=1 killed=1 failed=0' 6000)) 'I the kill reported one killed, none failed'
        $gone = $false
        $deadline = (Get-Date).AddSeconds(5)
        while ((Get-Date) -lt $deadline) {
            if (-not (Test-PidAlive $spawnPid)) { $gone = $true; break }
            Start-Sleep -Milliseconds 200
        }
        Assert $gone "I CONFIRMING really terminates the process ($spawnPid)"
        if ($gone) { $script:spawnPid = 0 }
    }

    # --- J. A failed action raises the dismissable error banner ---------------
    # Forced honestly: a working directory that does not exist makes
    # CreateProcessW fail, which is the same failure path an access-denied kill
    # takes. Nothing is spawned, so there is nothing to clean up.
    $before = Count-PanelLines
    Set-TestControlText -Control $filterEdit -Text '' | Out-Null
    Wait-PanelState $before | Out-Null

    $newProcBtn = Get-PanelButton $panel 'New Process*'
    Click-TestPosted $panel $newProcBtn | Out-Null
    $dlg = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyNewProcess' -TimeoutMs 8000
    Assert ($dlg -ne [IntPtr]::Zero) 'J the New Process dialog opens again'
    if ($dlg -ne [IntPtr]::Zero) {
        $edits = @(Get-TestChildWindows -Window $dlg -Class 'Edit') | Sort-Object Top
        $dlgBtns = @(Get-TestChildWindows -Window $dlg -Class 'Button')
        $startBtn = $dlgBtns | Where-Object { (Get-TestControlText -Control ([IntPtr]$_.Hwnd)) -eq 'Start' } | Select-Object -First 1
        if ($edits.Count -eq 2 -and $startBtn) {
            Send-TestControlText -Control ([IntPtr]$edits[0].Hwnd) -Text 'pause' | Out-Null
            Send-TestControlText -Control ([IntPtr]$edits[1].Hwnd) -Text 'Z:\no\such\dir\ghoztty-t286' | Out-Null
            Start-Sleep -Milliseconds 300
            Send-TestControlClick -Control ([IntPtr]$startBtn.Hwnd) | Out-Null
        } else {
            Send-TestWindowClose -Window $dlg | Out-Null
        }
        Start-Sleep -Milliseconds 700
    }
    Assert ($null -ne (Wait-LogMatch 'activity monitor: spawn result ok=false' 6000)) 'J the spawn really failed'
    Assert ($null -ne (Wait-LogMatch "activity monitor: action error: Couldn't start" 6000)) 'J the failure became an action error'

    # It PAINTED. The log proves the model; this proves the band exists on
    # screen, in the warn hue composited over the panel at `banner_alpha`.
    $BANNER_BG = Get-PanelBanner $PANEL_BG
    $GLYPH = Get-PanelSecondary $PANEL_BG   # the dismiss glyph rides the secondary ramp
    $shotB = Get-TestWindowPixels -Window $panel
    $xspot = $null
    try {
        Assert (Test-ExactPixel $shotB $client.Left ($client.Bottom - 60) $client.Right $client.Bottom $BANNER_BG) 'J the error banner painted at the panel bottom'
        # Control: the banner is a BAND at the bottom, not a panel-wide tint.
        Assert (-not (Test-ExactPixel $shotB $client.Left $client.Top $client.Right $fr.Bottom $BANNER_BG)) 'J (control) the banner tint is confined to the bottom band'
        $xspot = Find-ExactPixel $shotB ($client.Right - 40) ($client.Bottom - 60) $client.Right $client.Bottom $GLYPH
        Assert ($null -ne $xspot) 'J the banner has a dismiss glyph at its trailing edge'
    } finally {
        Close-TestWindowPixels -Shot $shotB
    }

    if ($null -ne $xspot) {
        Send-TestMouse -Window $panel -X $xspot.X -Y $xspot.Y -Button left -Action click | Out-Null
        Start-Sleep -Milliseconds 600
        $shotC = Get-TestWindowPixels -Window $panel
        try {
            Assert (-not (Test-ExactPixel $shotC $client.Left ($client.Bottom - 60) $client.Right $client.Bottom $BANNER_BG)) 'J clicking the glyph DISMISSES the banner'
        } finally {
            Close-TestWindowPixels -Shot $shotC
        }
    }

    # --- K. A panel nobody can see does not enumerate (T290) -----------------
    # Every poll is a FULL process enumeration - a snapshot plus an OpenProcess
    # and two queries per pid, ~300 of them - and it used to run every 1.5s for
    # as long as the panel existed, minimized or not. The oracle is the same
    # state line the rest of this script reads: one per adopted sample, so "the
    # count stopped growing" IS "the enumeration stopped".
    #
    # The negative control runs FIRST and is load-bearing: asserting a counter
    # stopped is trivially true of a counter that never moved.
    $k0 = Count-PanelLines
    Start-Sleep -Seconds 5
    $k1 = Count-PanelLines
    Assert ($k1 -gt $k0) "K (control) an open panel really is sampling ($k0 -> $k1)"

    Send-TestSysCommand -Window $panel -Command minimize | Out-Null
    Start-Sleep -Milliseconds 1200
    # WS_MINIMIZE, not the rect: this desktop has no Explorer, so an iconic
    # window parks at a real on-screen rect and a rect oracle would call a
    # working minimize broken (the caption-bar.ps1 lesson).
    $minStyle = Get-TestWindowStyle -Window $panel
    Assert (($minStyle -band 0x20000000) -ne 0) 'K the panel really iconified (WS_MINIMIZE set)'
    Assert ($null -ne (Wait-LogMatch 'activity monitor: sampling suspended' 4000)) 'K minimizing suspended sampling'

    $k2 = Count-PanelLines
    Start-Sleep -Seconds 5
    $k3 = Count-PanelLines
    Assert ($k3 -eq $k2) "K a minimized panel enumerates NOTHING across 3+ intervals ($k2 -> $k3)"

    Send-TestSysCommand -Window $panel -Command restore | Out-Null
    # Promptly, not on the next tick. 900ms is under one 1500ms interval, so a
    # resume that waited for the timer could only pass this by coincidence -
    # and the pair of assertions below closes that gap: the message-driven path
    # logs BEFORE it kicks the sample, so the line lands in tens of
    # milliseconds while a real sample follows a moment later.
    $promptMs = 900
    $resumeLine = $null
    $deadline = (Get-Date).AddMilliseconds($promptMs)
    while ((Get-Date) -lt $deadline) {
        $resumeLine = Get-LogMatch 'activity monitor: sampling resumed'
        if ($resumeLine) { break }
        Start-Sleep -Milliseconds 50
    }
    Assert ($null -ne $resumeLine) "K restoring resumes within ${promptMs}ms, not on the next tick"
    Assert ($null -ne (Wait-LogMatch 'activity monitor: sampling resumed .*trend=cleared' 4000)) 'K the resume CLEARED the trend history rather than stitching a gap across it'

    $k4 = $k3
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline) {
        $k4 = Count-PanelLines
        if ($k4 -gt $k3) { break }
        Start-Sleep -Milliseconds 200
    }
    Assert ($k4 -gt $k3) "K a restored panel samples again ($k3 -> $k4)"
    Start-Sleep -Milliseconds 500

    # --- L. Keyboard focus is VISIBLE, and it routes the keys (T289) ---------
    # Two claims, and they are the same claim from either end: the panel knows
    # where the keyboard is (so a key goes to the control that has it), and it
    # SAYS where the keyboard is (design system 2.2 - "if a control can be
    # tabbed to, it draws the ring; missing focus rings are an accessibility
    # defect, not a polish item").
    #
    # The oracles are the panel's own state line for the routing half and the
    # panel's own paint for the ring. Narrow the table to the app's own pid
    # first: one row makes "the caret row" unambiguous and leaves the rest of
    # the table area bare, which is what the control probe below reads.
    $before = Count-PanelLines
    Set-TestControlText -Control $filterEdit -Text "$($app.Pid)" | Out-Null
    $st = Wait-PanelState $before
    Assert ($st.Shown -ge 1) "L the table narrowed to the app's own pid (shown=$($st.Shown))"

    $rowInfo = Get-TestFirstRowY $panel $client $fr
    $rowY = $rowInfo[1]
    Assert ($rowY -ge 0) 'L the first table row was located by its own paint'

    # Clear the selection by clicking the bare area below the last row, so the
    # ring probe measures a rim and not a selection fill, and so the Kill stop
    # is genuinely absent from the Tab cycle below.
    $before = Count-PanelLines
    Send-TestMouse -Window $panel -X ($client.Left + 20) -Y ($client.Bottom - 30) -Button left -Action click | Out-Null
    $st = Wait-PanelState $before
    Assert ($st.Selected -eq 0) "L the selection cleared for the focus probes (selected=$($st.Selected))"
    $killVisible = $killBtn -and (Test-TestWindowVisible -Window ([IntPtr]$killBtn.Hwnd))
    Assert (-not $killVisible) 'L Kill is out of the Tab cycle while nothing is selected'

    # Put the caret in the filter field the way a user would.
    $fr2 = Get-TestWindowRect -Window $filterEdit
    Send-TestMouse -Window $panel -Target $filterEdit `
        -X ([int](($fr2.Left + $fr2.Right) / 2)) -Y ([int](($fr2.Top + $fr2.Bottom) / 2)) `
        -Button left -Action click | Out-Null
    Start-Sleep -Milliseconds 300
    Assert ((Get-TestFocusedWindow -Window $panel) -eq $filterEdit) 'L clicking the filter field focuses it'

    # L1. The row keys do NOT reach the table while the filter holds focus.
    # Before T289 they applied unconditionally, which is exactly what makes a
    # missing ring confusing rather than merely plain: Down moved a selection
    # the user could not see, from a caret that was somewhere else entirely.
    Send-TestControlKey -Control $filterEdit -Key Down | Out-Null
    Send-TestControlKey -Control $filterEdit -Key Down | Out-Null
    $before = Count-PanelLines
    $st = Wait-PanelState $before
    Assert ($st.Selected -eq 0) "L1 Down in the filter field selects NOTHING (selected=$($st.Selected))"

    # The ring's absence, measured before anything is tabbed: the caret row's
    # left rim, 6px in from the client edge, is bare panel background. The band
    # is clear of text (a cell is inset by 8 DIP) and clear of fills (nothing is
    # selected, and the pointer is over the filter field, not a row).
    $ringX1 = $client.Left + 6
    $ringY0 = $rowY + 3
    $ringY1 = $rowY + 10
    $shotL = Get-TestWindowPixels -Window $panel
    try {
        $bare = Count-NonMatching $shotL $client.Left $ringY0 $ringX1 $ringY1 $PANEL_BG
        if ($NegativeControl) {
            Write-Host 'NEGATIVE CONTROL: asserting the focus ring is painted while the FILTER holds focus - this run MUST fail'
            Assert ($bare -gt 0) "L (inverted): the caret row's rim is painted with focus in the filter ($bare px)"
        } else {
            Assert ($bare -eq 0) "L the caret row's rim is bare while the filter holds focus ($bare px painted)"
        }
    } finally {
        Close-TestWindowPixels -Shot $shotL
    }

    # L2. Tab walks the cycle, stepping OVER the hidden Kill stop.
    Send-TestControlKey -Control $filterEdit -Key Tab | Out-Null
    Start-Sleep -Milliseconds 250
    Assert ((Get-TestFocusedWindow -Window $panel) -eq ([IntPtr]$showAll.Hwnd)) 'L2 Tab from the filter reaches "Show all"'

    Send-TestControlKey -Control ([IntPtr]$showAll.Hwnd) -Key Tab | Out-Null
    Start-Sleep -Milliseconds 250
    Assert ((Get-TestFocusedWindow -Window $panel) -eq ([IntPtr]$newProc.Hwnd)) 'L2 Tab STEPS OVER the hidden Kill to "New Process..."'

    Send-TestControlKey -Control ([IntPtr]$newProc.Hwnd) -Key Tab | Out-Null
    Start-Sleep -Milliseconds 400
    Assert ((Get-TestFocusedWindow -Window $panel) -eq $panel) 'L2 Tab reaches the TABLE (the panel window owns the owner-drawn region)'

    # L3. The ring is now painted on the caret row - the same band that was bare
    # a moment ago, with nothing else about the panel changed.
    $shotL2 = Get-TestWindowPixels -Window $panel
    try {
        $ring = Count-NonMatching $shotL2 $client.Left $ringY0 $ringX1 $ringY1 $PANEL_BG
        Assert ($ring -gt 0) "L3 the table's focus ring PAINTS on the caret row once the table holds focus ($ring px)"
        # Control: the same band further down the (single-row) table stays
        # bare, so what was measured is a rim on the caret row and not a
        # table-wide repaint or a panel-wide accent.
        $belowY0 = $client.Bottom - 40
        $below = Count-NonMatching $shotL2 $client.Left $belowY0 $ringX1 ($belowY0 + 7) $PANEL_BG
        Assert ($below -eq 0) "L3 (control) the empty table area below the caret row is still bare ($below px)"
    } finally {
        Close-TestWindowPixels -Shot $shotL2
    }

    # L4. And the keys now reach the table: Down selects, from the caret the
    # ring is drawn on.
    $before = Count-PanelLines
    Send-TestControlKey -Control $panel -Key Down | Out-Null
    $st = Wait-PanelState $before
    Assert ($st.Selected -eq 1) "L4 Down with the table focused selects exactly one row (selected=$($st.Selected))"

    # L5. A selection puts Kill back INTO the cycle - the skip is dynamic, not
    # a one-time reading of the layout.
    Assert ($killBtn -and (Test-TestWindowVisible -Window ([IntPtr]$killBtn.Hwnd))) 'L5 Kill is visible again with a row selected'
    Send-TestControlKey -Control $panel -Key Tab | Out-Null
    Start-Sleep -Milliseconds 250
    Assert ((Get-TestFocusedWindow -Window $panel) -eq $filterEdit) 'L5 Tab from the table wraps to the filter (no carousel on a single-source panel)'
    Send-TestControlKey -Control $filterEdit -Key Tab | Out-Null
    Start-Sleep -Milliseconds 250
    Send-TestControlKey -Control ([IntPtr]$showAll.Hwnd) -Key Tab | Out-Null
    Start-Sleep -Milliseconds 250
    Assert ((Get-TestFocusedWindow -Window $panel) -eq ([IntPtr]$killBtn.Hwnd)) 'L5 Kill is now a Tab stop'

    # L6. The ring means "the keyboard is HERE", so it goes away when the
    # keyboard goes elsewhere. Focus the terminal window - the same GUI thread,
    # so the panel really does lose the focus rather than merely the z-order -
    # and the caret row's rim is bare again.
    # Clear the selection first, so the band under the probe carries a RIM and
    # not a selection fill - the two are different signals and this is the one
    # that has to follow the keyboard. The click focuses the table and drops the
    # caret with it, so Tab the whole cycle round to re-establish one: table ->
    # filter -> "Show all" -> (Kill, hidden again) -> "New Process..." -> table.
    $before = Count-PanelLines
    Send-TestMouse -Window $panel -X ($client.Left + 20) -Y ($client.Bottom - 30) -Button left -Action click | Out-Null
    $st = Wait-PanelState $before
    Assert ($st.Selected -eq 0) 'L6 (setup) the selection cleared'
    foreach ($i in 1..4) {
        Send-TestControlKey -Control $panel -Key Tab | Out-Null
        Start-Sleep -Milliseconds 200
    }
    Start-Sleep -Milliseconds 300
    Assert ((Get-TestFocusedWindow -Window $panel) -eq $panel) 'L6 (setup) the table holds focus again'

    # Tabbing in gave the table a caret WITHOUT selecting anything - so this
    # rim is focus and nothing else.
    $shotL4 = Get-TestWindowPixels -Window $panel
    try {
        $rimOnly = Count-NonMatching $shotL4 $client.Left $ringY0 $ringX1 $ringY1 $PANEL_BG
        Assert ($rimOnly -gt 0) "L6 tabbing in rings the caret row without selecting it ($rimOnly px)"
        Assert ($st.Selected -eq 0) 'L6 ...and the selection really is still empty'
    } finally {
        Close-TestWindowPixels -Shot $shotL4
    }

    # And it LEAVES when focus does. The caret has not moved - Tab does not
    # touch it - so a rim that survived here would be painting a row's state
    # rather than the keyboard's position, which is the difference between a
    # focus ring and decoration.
    #
    # Focus moving to another STOP, not the panel being deactivated: posted
    # input cannot activate a window off the input desktop (activation comes
    # from WM_MOUSEACTIVATE on real input), so the deactivated case has no
    # honest oracle here and is left unasserted rather than faked.
    Send-TestControlKey -Control $panel -Key Tab | Out-Null
    Start-Sleep -Milliseconds 400
    Assert ((Get-TestFocusedWindow -Window $panel) -eq $filterEdit) 'L6 Tab moved focus off the table'
    $shotL5 = Get-TestWindowPixels -Window $panel
    try {
        $gone = Count-NonMatching $shotL5 $client.Left $ringY0 $ringX1 $ringY1 $PANEL_BG
        Assert ($gone -eq 0) "L6 the ring LEAVES with the focus ($gone px still painted)"
    } finally {
        Close-TestWindowPixels -Shot $shotL5
    }

    # --- F. Escape closes the panel ------------------------------------------
    Send-TestControlKey -Control $filterEdit -Key Escape | Out-Null
    Start-Sleep -Milliseconds 800
    Assert ((@(Get-Panels)).Count -eq 0) 'F Escape closes the panel'
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'F the app survives the panel closing'
    Assert (Select-String -Path $errlog -Pattern 'activity monitor: closed source=' -Quiet) 'F the panel tore itself down (sampler joined, registry slot freed)'
} finally {
    # The throwaway from H, if I never got to kill it (an abort mid-section).
    if ($script:spawnPid -gt 0) {
        Stop-Process -Id $script:spawnPid -Force -ErrorAction SilentlyContinue
    }
    Remove-TestDesktop
    Kill-RepoInstances
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ACTIVITY MONITOR ACCEPTANCE: ALL PASS ($script:pass assertions)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red; exit 1 }
