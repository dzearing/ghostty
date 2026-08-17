# Machine-chooser SESSION-LIST SORT acceptance (tracker T602).
#
# Upstream 2389d3182 lifted the machine identity into the chooser's header band
# and made the session list sortable: CPU and Name are clickable column headers
# over the roster - click to sort, click the active one to flip, a chevron
# marks the active column - and the chosen order persists like the viewer's own
# chrome preferences. This script drives the win32 twin end to end against a
# REAL local agent:
#
#   1. a fresh chooser loads the DEFAULT order (name asc) and says so;
#   2. clicking the Name header flips to desc and the first DISPLAYED row is
#      the alphabetically-last session; clicking again flips back and the
#      first row is the alphabetically-first one;
#   3. clicking the CPU header activates it busiest-first;
#   4. the choice SURVIVES an app restart (the pref file, and the reopened
#      chooser's own "sort loaded" line);
#   5. keyboard navigation still works over the sorted list (Right enters the
#      roster, Return resumes the cursored row);
#   6. the roster cards are painted at their NEW, higher position (the
#      identity left the detail pane), and the header line has real pixels.
#
# WHY LOG LINES ARE THE ORACLE: the roster and its headers are owner-drawn -
# there is no HWND to read an order back from. Every sort toggle logs
# `chooser roster: sort key=<k> dir=<d> first=<id>`, and the first displayed
# row's id is cross-checked against ids mapped INDEPENDENTLY via
# `+sessions --json` (argv discriminates the fixture sessions).
#
# FIXTURE: two extra sessions launched as `cmd /K title <name>` with names that
# bracket the alphabet (aaaa / zzzz), so whatever the initial shell's own title
# is, name-asc must lead with aaaa's session and name-desc with zzzz's.
#
# NEGATIVE CONTROL (run 3): with no agent the roster resolves to `failed`, no
# rows exist, and the header line must NOT be drawn - headers over "No active
# sessions" are furniture (the same pixels that prove presence in run 1 prove
# absence here).
#
#   powershell -NoProfile -File test\win32\chooser-session-sort.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }

# Isolate the IPC endpoint (inherited through CreateProcessW).
$env:GHOZTTY_PIPE_SUFFIX = '-t602'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0

function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

function Stop-RepoProcesses {
    foreach ($name in @('ghoztty', 'ghoztty-agent')) {
        Get-CimInstance Win32_Process -Filter "Name='$name.exe'" | ForEach-Object {
            if ($_.ExecutablePath -and $_.ExecutablePath.StartsWith((Join-Path $repo 'zig-out'), 'OrdinalIgnoreCase')) {
                try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}
            }
        }
    }
    Start-Sleep -Milliseconds 500
}

function Reset-AgentState {
    $dir = Join-Path $env:LOCALAPPDATA 'ghoztty\local-agent-debug'
    foreach ($f in @('sessions.json', 'port.json')) {
        Remove-Item (Join-Path $dir $f) -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path $dir 'rings') -Recurse -Force -ErrorAction SilentlyContinue
}

# The persisted sort preference under test (the -debug twin: dev builds never
# move the release app's choice). Dropped at setup so run 1 sees the default.
$prefFile = Join-Path $env:LOCALAPPDATA 'ghoztty\chooser_session_sort-debug'

function Get-Sessions {
    $out = (& $Exe +sessions --json 2>$null | Out-String)
    if (-not $out -or $out.Trim().Length -eq 0) { return @() }
    try { $j = $out | ConvertFrom-Json } catch { return @() }
    if ($null -eq $j) { return @() }
    return @($j)
}

function Get-RosterGeometry([double]$s) { return Get-TestChooserRosterGeometry -Scale $s }

function Launch-Gui($errlog, [string]$persistence = 'true') {
    $args = @('--window-width=100', '--window-height=30', "--session-persistence=$persistence")
    $app = Start-OnTestDesktop -Exe $Exe -Arguments $args -StdErr $errlog
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { return $null }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { return $null }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { return $null }
    return @{ App = $app; Pid = $app.Pid; Top = $top; Surface = $surface }
}

function Open-Chooser($g) {
    if (Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl, shift -Key N) {
        return Wait-TestWindow -ProcessId $g.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 4000
    }
    return [IntPtr]::Zero
}

function Wait-LogCount($path, $pattern, $want, $timeoutMs) {
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if (Test-Path $path) {
            $m = @(Select-String -Path $path -Pattern $pattern -ErrorAction SilentlyContinue)
            if ($m.Count -ge $want) { return $m[$want - 1].Line }
        }
        Start-Sleep -Milliseconds 200
        $waited += 200
    }
    return $null
}

function Wait-LogLine($path, $pattern, $timeoutMs) {
    return Wait-LogCount $path $pattern 1 $timeoutMs
}

# Count pixels on the header line that differ from the dialog surface - text
# antialiasing included, so any drawn label registers. The probe scans the NAME
# zone, whose x-range comes from the same shared geometry the app's layout is
# asserted against.
function Get-HeaderInkPixels($chooser, $geo) {
    $shot = Get-TestWindowPixels -Window $chooser
    try {
        $client = Get-TestWindowRect -Window $chooser -Client
        # The dialog surface, sampled left of the name zone on the same line
        # (between the CPU and Name headers there is bare surface; sampling one
        # point risks landing on the CPU label, so take the far right end of
        # the region, which no header reaches).
        $bg = Get-TestPixel -Shot $shot -X ($client.Left + $geo.Right - 4) -Y ($client.Top + $geo.HeaderY)
        if (-not $bg) { return -1 }
        $ink = 0
        for ($x = $geo.NameHeaderX - 8; $x -lt $geo.NameHeaderX + 60; $x += 1) {
            $p = Get-TestPixel -Shot $shot -X ($client.Left + $x) -Y ($client.Top + $geo.HeaderY)
            if ($p -and ([math]::Abs([int]$p.R - [int]$bg.R) -gt 24 -or
                    [math]::Abs([int]$p.G - [int]$bg.G) -gt 24 -or
                    [math]::Abs([int]$p.B - [int]$bg.B) -gt 24)) { $ink++ }
        }
        return $ink
    } finally { Close-TestWindowPixels -Shot $shot }
}

Write-Host 'T602 chooser session-list sort'
Stop-RepoProcesses
Reset-AgentState
Remove-Item $prefFile -ErrorAction SilentlyContinue
New-TestDesktop | Out-Null

$errlog = Join-Path $env:TEMP "ghoztty-t602-stderr-$PID.log"
$errlog2 = Join-Path $env:TEMP "ghoztty-t602-stderr2-$PID.log"
$errlog3 = Join-Path $env:TEMP "ghoztty-t602-stderr3-$PID.log"
Remove-Item $errlog, $errlog2, $errlog3 -ErrorAction SilentlyContinue

try {
    # --- Run 1: default order, then click-to-sort ---------------------------
    Write-Host ''
    Write-Host '1. fixture: three sessions, two with bracketing names'
    $g = Launch-Gui $errlog
    if (-not $g) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }

    # Two named sessions whose console titles bracket the alphabet. `--shell=cmd`
    # makes the invocation `cmd /K title <name>` (the per-flavor rule), which
    # sets the ConPTY title the moment the shell starts - the label ladder's
    # top rung for a session open in one of our panes - and bakes the name into
    # the argv the agent records, which is how the ids are mapped below.
    & $Exe +new-window '--target=t602-a' '--shell=cmd' '--command=title aaaa-sort' 2>$null | Out-Null
    Start-Sleep -Seconds 1
    & $Exe +new-window '--target=t602-z' '--shell=cmd' '--command=title zzzz-sort' 2>$null | Out-Null
    Start-Sleep -Seconds 2

    $sessions = @(Get-Sessions)
    Assert ($sessions.Count -ge 3) "the agent lists the fixture sessions (found $($sessions.Count))"
    # The name is baked into the recorded argv AND becomes the console title
    # the agent captures - either field maps the id, whichever this agent
    # build filled.
    $idA = ($sessions | Where-Object { $_.argv -match 'aaaa-sort' -or $_.title -match 'aaaa-sort' } |
        Select-Object -First 1).id
    $idZ = ($sessions | Where-Object { $_.argv -match 'zzzz-sort' -or $_.title -match 'zzzz-sort' } |
        Select-Object -First 1).id
    Assert ($idA -and $idZ) "both named sessions are mapped to ids (a=$idA z=$idZ)"
    if (-not ($idA -and $idZ)) { Write-Host 'SETUP FAIL: fixture ids unmapped'; exit 1 }

    $chooser = Open-Chooser $g
    Assert ($chooser -ne [IntPtr]::Zero) 'ctrl+shift+n opens the chooser'
    if ($chooser -eq [IntPtr]::Zero) { Write-Host 'SETUP FAIL: no chooser'; exit 1 }

    $loadLine = Wait-LogLine $errlog 'chooser roster: sort loaded key=' 4000
    Assert ($null -ne $loadLine -and $loadLine -match 'key=name dir=asc') `
        'a fresh chooser loads the default order: name, A-to-z'
    $rosterLine = Wait-LogLine $errlog 'chooser roster: loaded (\d+) session' 6000
    Assert ($null -ne $rosterLine) 'the roster fetch landed'
    # The titles take a beat to reach the surfaces; the sort reads them live.
    Start-Sleep -Seconds 1

    Write-Host ''
    Write-Host '2. the Name header sorts, and clicking it again flips'
    $scale = (Get-TestWindowDpi -Window $chooser) / 96.0
    $geo = Get-RosterGeometry $scale
    $cr = Get-TestWindowRect -Window $chooser -Client

    Send-TestMouse -Window $chooser -X ($cr.Left + $geo.NameHeaderX) -Y ($cr.Top + $geo.HeaderY) `
        -Button left -Action click | Out-Null
    $desc = Wait-LogLine $errlog 'chooser roster: sort key=name dir=desc' 4000
    Assert ($null -ne $desc) 'clicking Name flips the active column to descending'
    Assert ($null -ne $desc -and $desc -match "first=$idZ") `
        "name-desc leads with the zzzz session ($desc)"

    Send-TestMouse -Window $chooser -X ($cr.Left + $geo.NameHeaderX) -Y ($cr.Top + $geo.HeaderY) `
        -Button left -Action click | Out-Null
    $asc = Wait-LogLine $errlog 'chooser roster: sort key=name dir=asc first=' 4000
    Assert ($null -ne $asc) 'clicking Name again flips back to ascending'
    Assert ($null -ne $asc -and $asc -match "first=$idA") `
        "name-asc leads with the aaaa session ($asc)"

    Write-Host ''
    Write-Host '3. the CPU header activates busiest-first'
    Send-TestMouse -Window $chooser -X ($cr.Left + $geo.CpuHeaderX) -Y ($cr.Top + $geo.HeaderY) `
        -Button left -Action click | Out-Null
    $cpu = Wait-LogLine $errlog 'chooser roster: sort key=cpu dir=desc' 4000
    Assert ($null -ne $cpu) "an inactive CPU header starts descending ($cpu)"

    Write-Host ''
    Write-Host '4. the cards and the header line are painted at their T602 positions'
    $shot = Get-TestWindowPixels -Window $chooser
    try {
        $distinct = Get-TestDistinctColors -Shot $shot
        Assert ($distinct -gt 3) "the capture is a real frame ($distinct colors)"
        $cardPx = Get-TestPixel -Shot $shot -X ($cr.Left + $geo.CardX) -Y ($cr.Top + $geo.CardY)
        $bgPx = Get-TestPixel -Shot $shot -X ($cr.Left + $geo.Left) -Y ($cr.Top + $geo.Bottom - 2)
        $cardLum = if ($cardPx) { [int]$cardPx.R } else { -1 }
        $bgLum = if ($bgPx) { [int]$bgPx.R } else { -1 }
        Assert ($cardLum -gt $bgLum) `
            "the first card's fill sits at the new, higher position ($cardLum vs $bgLum)"
    } finally { Close-TestWindowPixels -Shot $shot }
    $script:headerInk = Get-HeaderInkPixels $chooser $geo
    Assert ($script:headerInk -gt 0) "the Name header has real pixels ($($script:headerInk))"

    Write-Host ''
    Write-Host '5. keyboard navigation still works over the sorted list'
    Send-TestControlKey -Control $chooser -Key Right | Out-Null
    Start-Sleep -Milliseconds 300
    Send-TestControlKey -Control $chooser -Key Enter | Out-Null
    # Every fixture session is open in one of our own panes, so Return on the
    # cursored row focuses it rather than double-attaching (T330 divergence).
    $focusLine = Wait-LogLine $errlog 'session already open, focusing its pane' 4000
    Assert ($null -ne $focusLine) 'Right enters the sorted roster and Return acts on the cursored row'

    # --- Run 2: the choice survives a restart -------------------------------
    Write-Host ''
    Write-Host '6. the sort order survives an app restart'
    Assert ((Test-Path $prefFile) -and ((Get-Content $prefFile -Raw).Trim() -eq 'cpu desc')) `
        'the preference file holds the last choice (cpu desc)'
    Stop-RepoProcesses
    $g2 = Launch-Gui $errlog2
    if (-not $g2) { Write-Host 'SETUP FAIL: GUI died at relaunch'; exit 1 }
    $chooser2 = Open-Chooser $g2
    Assert ($chooser2 -ne [IntPtr]::Zero) 'the chooser reopens after the restart'
    if ($chooser2 -ne [IntPtr]::Zero) {
        $load2 = Wait-LogLine $errlog2 'chooser roster: sort loaded key=' 4000
        Assert ($null -ne $load2 -and $load2 -match 'key=cpu dir=desc') `
            "the reopened chooser loads the persisted order ($load2)"
    }

    # --- Run 3: negative control - no rows, no header -----------------------
    Write-Host ''
    Write-Host '7. negative control: no agent, no header line'
    Stop-RepoProcesses
    Reset-AgentState
    # No persistence: no agent runs, so the roster resolves to `failed` with
    # zero rows - the exact state the furniture rule is about.
    $g3 = Launch-Gui $errlog3 'false'
    if (-not $g3) { Write-Host 'SETUP FAIL: GUI died at launch (run 3)'; exit 1 }
    $chooser3 = Open-Chooser $g3
    Assert ($chooser3 -ne [IntPtr]::Zero) 'the chooser opens with no agent'
    if ($chooser3 -ne [IntPtr]::Zero) {
        Start-Sleep -Seconds 3
        $ink3 = Get-HeaderInkPixels $chooser3 $geo
        Assert ($ink3 -eq 0) `
            "headers over an empty roster are furniture and are not drawn ($ink3 vs run 1's $($script:headerInk))"
    }
} finally {
    Stop-RepoProcesses
    Remove-TestDesktop
}

# --- stamp (T783) ----------------------------------------------------------
# A clean green run records the covered files so scripts\guard-due.ps1 can
# answer "has anyone run this harness against the code as it now stands?".
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard chooser-session-sort -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass)" -ForegroundColor Green; exit 0 }
Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red
exit 1
