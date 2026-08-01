# T285 acceptance: the win32 Activity Monitor panel.
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
#   E. "Show all" widens it from the ghoztty-spawned tree to every process.
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
# `-NegativeControl` switch inverts D's load-bearing claim - a needle that
# matches nothing is asserted to still show every row - and that run MUST fail.
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

$script:pass = 0
$script:fail = 0
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

Kill-RepoInstances
Remove-Item $errlog -ErrorAction SilentlyContinue
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    $script:app = Start-OnTestDesktop -Exe $exe -Arguments @('--session-persistence=false') -StdErr $errlog
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
        # T286 enables it. A live button that does nothing would be the defect;
        # a disabled one is an honest state (design system 2.2).
        Assert (-not (Test-TestWindowEnabled -Window ([IntPtr]$newProc.Hwnd))) 'A "New Process..." is DISABLED until T286 wires it'
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
        $CPU_TINT = @(80, 160, 235)   # ActivityMonitor.zig COLOR_CPU
        $MEM_TINT = @(90, 190, 120)   # ActivityMonitor.zig COLOR_MEM
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
    # for the first row painted in COLOR_HEADER_BG (40,40,40). Re-deriving the
    # layout module's band offsets here is what T257 is about.
    $shot2 = Get-TestWindowPixels -Window $panel
    $headerY = -1
    try {
        for ($y = [int]$fr.Bottom; $y -lt $client.Bottom -and $headerY -lt 0; $y++) {
            $c = Get-TestPixel -Shot $shot2 -X ($client.Right - 20) -Y $y
            if ($null -ne $c -and $c.R -eq 40 -and $c.G -eq 40 -and $c.B -eq 40) { $headerY = $y }
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

    # --- F. Escape closes the panel ------------------------------------------
    Send-TestControlKey -Control $filterEdit -Key Escape | Out-Null
    Start-Sleep -Milliseconds 800
    Assert ((@(Get-Panels)).Count -eq 0) 'F Escape closes the panel'
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'F the app survives the panel closing'
    Assert (Select-String -Path $errlog -Pattern 'activity monitor: closed source=' -Quiet) 'F the panel tore itself down (sampler joined, registry slot freed)'
} finally {
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
