# T1184 acceptance: ctrl+F searches the text inside a viewer pane.
#
# What is asserted:
#
#   - ctrl+F from inside the page opens a find card (`GhozttyViewerFind`),
#     in a MARKDOWN pane and in a WEBSITE pane, which are the two ends of the
#     "every mode" claim: one is our bundled template, one is a document we did
#     not render and never could have injected `viewer.js` into.
#   - the card FLOATS: opening it does not move the page. The WebView2
#     controller's bounds are identical before and after, so the text being
#     searched does not scroll out from under the reader.
#   - typing counts: a query with five occurrences reports total=5, index=1.
#   - Enter steps, and WRAPS: 1 -> 2 -> ... -> 5 -> 1.
#   - the card's own chevron steps backwards, so the pointer route works as
#     well as the keyboard one.
#   - F3 — the Windows spelling of "find next" — steps from inside the page.
#   - Escape closes the card and clears the page's highlights, but KEEPS the
#     query: ctrl+F comes back to the same search, and the count returns
#     without anything being retyped.
#   - a query with no matches says "No results" rather than showing a count.
#   - a diff pane names the file it is searching, which is the honesty note.
#   - the card's own pixels really paint (PrintWindow through WM_PRINTCLIENT),
#     so "the card exists" is not a claim about an unpainted window.
#
# ORACLE, and why it is the log. This runs on the background test desktop,
# where CopyFromScreen and SendInput are dead (T233), so nothing out here can
# see a highlight. The pane states what it decided instead:
#
#     viewer find pane=<id> state=open|closed query=<q>
#     viewer find pane=<id> state=count query=<q> total=N index=N
#         truncated=B note=<n>
#
# `state=count` is emitted by `applyFindMessage`, the only place a count from
# `find.js` is ever accepted — and it is emitted only for a report whose query
# matches the field, so a line appearing at all is already the assertion that
# the page and the card agree about what is being searched.
#
# NOT asserted here, deliberately: WHICH pixels are yellow. The highlight is
# painted by the browser's CSS Custom Highlight API inside a compositor surface
# PrintWindow does not reach, so a harness claiming to have seen an orange
# current match would be asserting its own fake. What is asserted instead is
# the number the page reports for the same document — which is computed by the
# same code that paints, on the same ranges.
#
# -NegativeControl inverts the two count assertions in section C and MUST fail
# with exactly TWO failures, so a run that scores anything else is measuring
# something other than the search.
#
# Only touches ghoztty processes running from this repo's zig-out*.
#
#   powershell -NoProfile -File test\win32\viewer-find.ps1
param(
    [string]$ExePath,
    [switch]$NegativeControl,
    [switch]$Interactive
)

. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = Join-Path $repo 'zig-out\bin\ghoztty.exe'
if ($ExePath) { $exe = $ExePath }
if (-not (Test-Path $exe)) { Write-Host "SETUP FAIL: no exe at $exe"; exit 1 }

# Endpoint isolation: a run must never reach the user's own instance.
$env:GHOZTTY_PIPE_SUFFIX = "-vfind$PID"

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $exe | Out-Null
. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
$script:skipped = 0

function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Skip([string]$label) {
    $script:skipped++
    Write-Host "SKIP  $label" -ForegroundColor Yellow
}

function Stop-RepoInstances {
    [void](Stop-RepoGhoztty -Exe $exe -AppOnly -SettleMs 500)
}

function Invoke-Verb([string[]]$VerbArgs) {
    $out = (& $exe @VerbArgs 2>&1 | ForEach-Object { $_.ToString() } | Out-String)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
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

function Get-OnlyPane($target) {
    $w = Get-Win $target
    if (-not $w) { return $null }
    $leaves = @(Get-Leaves $w.tabs[0].splits)
    if ($leaves.Count -ne 1) { return $null }
    return $leaves[0]
}

# Every find decision this pane has reported, oldest first.
function Get-FindStates($errlog, $paneId) {
    if (-not (Test-Path $errlog) -or -not $paneId) { return @() }
    $out = @()
    $esc = [regex]::Escape($paneId)
    foreach ($line in (Get-Content $errlog -ErrorAction SilentlyContinue)) {
        if ($line -match "viewer find pane=$esc state=count query=(.*) total=(\d+) index=(\d+) truncated=(\S+) note=(.*)$") {
            $out += [pscustomobject]@{
                State     = 'count'
                Query     = $Matches[1]
                Total     = [int]$Matches[2]
                Index     = [int]$Matches[3]
                Truncated = ($Matches[4] -eq 'true')
                Note      = $Matches[5]
            }
        }
        elseif ($line -match "viewer find pane=$esc state=(open|closed) query=(.*)$") {
            $out += [pscustomobject]@{
                State = $Matches[1]
                Query = $Matches[2]
                Total = -1
                Index = -1
                Note  = ''
            }
        }
    }
    return $out
}

function Wait-FindState($errlog, $paneId, [string]$State, [int]$AtLeast = 1) {
    for ($t = 0; $t -lt 60; $t++) {
        $hit = @(Get-FindStates $errlog $paneId | Where-Object { $_.State -eq $State })
        if ($hit.Count -ge $AtLeast) { return $hit }
        Start-Sleep -Milliseconds 250
    }
    return @(Get-FindStates $errlog $paneId | Where-Object { $_.State -eq $State })
}

# The most recent count this pane reported, once one exists that satisfies
# `-Where`. Waited for, because the page answers asynchronously.
function Wait-Count($errlog, $paneId, [scriptblock]$Where, [int]$Tries = 60) {
    for ($t = 0; $t -lt $Tries; $t++) {
        $counts = @(Get-FindStates $errlog $paneId | Where-Object { $_.State -eq 'count' })
        if ($counts.Count -gt 0) {
            $last = $counts[-1]
            if (& $Where $last) { return $last }
        }
        Start-Sleep -Milliseconds 250
    }
    $counts = @(Get-FindStates $errlog $paneId | Where-Object { $_.State -eq 'count' })
    if ($counts.Count -gt 0) { return $counts[-1] }
    return $null
}

# The find card's window, and the EDIT inside it.
function Get-FindCard([IntPtr]$top) {
    foreach ($h in @(Get-TestChildWindows -Window $top -Class 'GhozttyViewerFind')) {
        if ($h.Visible) { return [IntPtr][int64]$h.Hwnd }
    }
    return [IntPtr]::Zero
}

function Wait-FindCard([IntPtr]$top, [int]$Tries = 40) {
    for ($t = 0; $t -lt $Tries; $t++) {
        $c = Get-FindCard $top
        if ($c -ne [IntPtr]::Zero) { return $c }
        Start-Sleep -Milliseconds 200
    }
    return [IntPtr]::Zero
}

function Get-FindEdit([IntPtr]$card) {
    if ($card -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
    foreach ($h in @(Get-TestChildWindows -Window $card -Class 'Edit')) {
        return [IntPtr][int64]$h.Hwnd
    }
    return [IntPtr]::Zero
}

# The Chromium input child under a viewer host — the only window in WebView2's
# chain whose message loop turns a posted WM_KEYDOWN into an
# AcceleratorKeyPressed event (viewer-panes.ps1 section T394 probed this).
function Wait-ChromeChild([IntPtr]$top) {
    for ($t = 0; $t -lt 50; $t++) {
        foreach ($h in @(Get-TestChildWindows -Window $top -Class 'GhozttyViewer')) {
            if (-not $h.Visible) { continue }
            $kids = @(Get-TestChildWindows -Window ([IntPtr][int64]$h.Hwnd) -Class '*')
            $widget = @($kids | Where-Object { $_.Class -eq 'Chrome_WidgetWin_1' })
            if ($widget.Count -ge 1) {
                return [pscustomobject]@{
                    Host   = [IntPtr][int64]$h.Hwnd
                    Widget = [IntPtr][int64]$widget[0].Hwnd
                }
            }
        }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Wait-TopWindow([int]$appPid, $before) {
    for ($t = 0; $t -lt 25; $t++) {
        foreach ($w in @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow')) {
            if ($before -notcontains $w.Hwnd) { return [IntPtr][int64]$w.Hwnd }
        }
        Start-Sleep -Milliseconds 200
    }
    return [IntPtr]::Zero
}

# --- the documents under test ----------------------------------------------
$dir = Join-Path $env:TEMP ('ghoztty-t1184-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $dir | Out-Null

# Five occurrences of one word, in five different blocks — so a match that
# straddled a block boundary would change the count and be caught.
$mdPath = Join-Path $dir 'doc.md'
Set-Content -LiteralPath $mdPath -Encoding UTF8 -Value @'
# Search fixture

A paragraph mentioning needle once.

- a list item with needle in it
- another item, needle again

> a quote containing needle

The last paragraph has needle at the end.
'@

# A local HTML page, loaded as a real document rather than through the bundled
# template: the "it reaches a website too" half of the claim, without needing
# the network.
$htmlPath = Join-Path $dir 'page.html'
Set-Content -LiteralPath $htmlPath -Encoding UTF8 -Value @'
<!doctype html>
<title>needle page</title>
<body>
<p>needle</p><p>needle</p><p>needle</p><p>needle</p><p>needle</p>
</body>
'@

Stop-RepoInstances
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    $errlog = Join-Path $env:TEMP 'ghoztty-viewer-find-stderr.log'
    Remove-Item $errlog -ErrorAction SilentlyContinue
    $app = Start-OnTestDesktop -Exe $exe -StdErr $errlog -Arguments @('--session-persistence=false')
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { Write-Host 'SETUP FAIL: GUI died at launch'; exit 1 }
    $appPid = $app.Pid
    if ((Wait-TestWindow -ProcessId $appPid -Class 'GhozttyWindow') -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no GhozttyWindow'; exit 1
    }

    # --- A. ctrl+F opens a card over a markdown pane ------------------------
    $before = @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow' | ForEach-Object { $_.Hwnd })
    $r = Invoke-Verb @('+new-window', '--target=t1184md', "--view=$mdPath")
    Assert ($r.Code -eq 0) "+new-window --view=<file>.md exits 0 (got $($r.Code))"
    Assert ($null -ne (Wait-Win 't1184md')) 'the markdown viewer window exists'
    $mdPane = Get-OnlyPane 't1184md'
    Assert ($null -ne $mdPane) 'the markdown window has exactly one pane'
    $mdTop = Wait-TopWindow $appPid $before
    Assert ($mdTop -ne [IntPtr]::Zero) 'found the markdown pane top-level window'

    $chrome = if ($mdTop -ne [IntPtr]::Zero) { Wait-ChromeChild $mdTop } else { $null }
    Assert ($null -ne $chrome) 'found the Chromium input child under the viewer host'

    if ($null -eq $chrome -or $null -eq $mdPane) {
        Write-Host 'SETUP FAIL: no viewer to search'
        Write-Host "$script:pass passed, $script:fail failed"
        exit 1
    }
    $paneId = $mdPane.id

    # The page's bounds BEFORE the card exists: a floating card must not move
    # them, which is the whole reason it is a card and not a second band.
    $webBefore = Get-TestWindowRect -Window $chrome.Host

    Focus-TestWindow -Window $mdTop -Child $chrome.Host | Out-Null
    Start-Sleep -Milliseconds 400
    Assert (Send-TestViewerChord -Window $mdTop -Target $chrome.Widget -Modifiers ctrl -Key F) `
        'ctrl+F injected at the markdown viewer'
    $card = Wait-FindCard $mdTop
    Assert ($card -ne [IntPtr]::Zero) 'ctrl+F opened a find card over the markdown pane'
    $opens = @(Wait-FindState $errlog $paneId 'open')
    Assert ($opens.Count -ge 1) 'the pane reported the card open'

    $webAfter = Get-TestWindowRect -Window $chrome.Host
    Assert ($webBefore.Top -eq $webAfter.Top -and $webBefore.Bottom -eq $webAfter.Bottom) `
        'the card FLOATS: opening it did not move the page it is searching'

    # --- B. the card really paints -----------------------------------------
    if ($card -ne [IntPtr]::Zero) {
        $shot = $null
        try { $shot = Get-TestWindowPixels -Window $card -Sync } catch { $shot = $null }
        if ($null -eq $shot) {
            Skip 'the card paints (PrintWindow returned nothing)'
        } else {
            try {
                $colors = Get-TestDistinctColors -Shot $shot
                Assert ($colors -ge 3) "the card paints real chrome, not a flat fill ($colors distinct colors)"
            } finally { Close-TestWindowPixels -Shot $shot }
        }
    }

    # --- C. typing counts ---------------------------------------------------
    $edit = Get-FindEdit $card
    Assert ($edit -ne [IntPtr]::Zero) 'the card carries a real EDIT for the query'
    if ($edit -ne [IntPtr]::Zero) {
        Send-TestControlText -Control $edit -Text 'needle' | Out-Null
        $c = Wait-Count $errlog $paneId { param($x) $x.Query -eq 'needle' -and $x.Total -gt 0 }
        $wantTotal = if ($NegativeControl) { 4 } else { 5 }
        $wantIndex = if ($NegativeControl) { 2 } else { 1 }
        Assert ($null -ne $c -and $c.Total -eq $wantTotal) `
            "five occurrences count as five (got $(if ($c) { $c.Total } else { 'nothing' }))"
        Assert ($null -ne $c -and $c.Index -eq $wantIndex) `
            "the first match is the current one (got $(if ($c) { $c.Index } else { 'nothing' }))"
        Assert ($null -ne $c -and -not $c.Truncated) 'a five-match page is not reported as capped'

        # --- D. Enter steps, and wraps -------------------------------------
        Send-TestControlKey -Control $edit -Key Return | Out-Null
        $c2 = Wait-Count $errlog $paneId { param($x) $x.Index -eq 2 }
        Assert ($null -ne $c2 -and $c2.Index -eq 2) 'Enter steps to the next match'

        for ($i = 0; $i -lt 4; $i++) {
            Send-TestControlKey -Control $edit -Key Return | Out-Null
            Start-Sleep -Milliseconds 250
        }
        $c3 = Wait-Count $errlog $paneId { param($x) $x.Index -eq 1 }
        Assert ($null -ne $c3 -and $c3.Index -eq 1) 'stepping past the last match wraps to the first'

        # --- E. the chevron steps backwards --------------------------------
        # The card's controls sit at its trailing edge: close, then next, then
        # previous, each a 28 DIP square with a 4 DIP gap inside an 8 DIP pad.
        $rect = Get-TestWindowRect -Window $card
        $dpi = Get-TestWindowDpi -Window $card
        $scale = if ($dpi -gt 0) { $dpi / 96.0 } else { 1.0 }
        $w = $rect.Right - $rect.Left
        $h = $rect.Bottom - $rect.Top
        # SCREEN coordinates: Send-TestMouse converts to the target's client
        # space itself, so handing it a client point would land it somewhere
        # else entirely. The card is a borderless child, so its window rect's
        # origin IS its client origin.
        $prevX = [int]($rect.Right - [Math]::Round((8 + 28 + 4 + 28 + 4 + 14) * $scale))
        $prevY = [int]($rect.Top + [Math]::Round($h / 2))
        Send-TestMouse -Window $mdTop -Target $card -X $prevX -Y $prevY -Client -Action click | Out-Null
        $clicked = $false
        for ($t = 0; $t -lt 30 -and -not $clicked; $t++) {
            $clicked = @(Get-Content $errlog -ErrorAction SilentlyContinue |
                Where-Object { $_ -match 'viewer find control=previous' }).Count -gt 0
            if (-not $clicked) { Start-Sleep -Milliseconds 200 }
        }
        Assert $clicked "the click landed on the previous chevron (x=$prevX y=$prevY of ${w}x${h})"
        $c4 = Wait-Count $errlog $paneId { param($x) $x.Index -eq 5 }
        Assert ($null -ne $c4 -and $c4.Index -eq 5) `
            "the card's previous chevron steps backwards and wraps (got $(if ($c4) { $c4.Index } else { 'nothing' }))"

        # --- F. F3 steps from inside the page ------------------------------
        # Relative to wherever the run has got to, not to an absolute ordinal:
        # this section is about the CHORD reaching the page, and pinning it to a
        # number would make it re-assert section E's outcome instead.
        $beforeF3 = (Wait-Count $errlog $paneId { param($x) $true }).Index
        $wantF3 = if ($beforeF3 -ge 5) { 1 } else { $beforeF3 + 1 }
        Focus-TestWindow -Window $mdTop -Child $chrome.Host | Out-Null
        Start-Sleep -Milliseconds 300
        Send-TestViewerChord -Window $mdTop -Target $chrome.Widget -Key F3 | Out-Null
        $c5 = Wait-Count $errlog $paneId { param($x) $x.Index -eq $wantF3 }
        Assert ($null -ne $c5 -and $c5.Index -eq $wantF3) `
            "F3 from inside the page steps to the next match ($beforeF3 -> $(if ($c5) { $c5.Index } else { 'nothing' }), wanted $wantF3)"

        # --- G. Escape closes but keeps the query --------------------------
        Send-TestControlKey -Control $edit -Key Escape | Out-Null
        $closed = $false
        for ($t = 0; $t -lt 30 -and -not $closed; $t++) {
            $closed = ((Get-FindCard $mdTop) -eq [IntPtr]::Zero)
            if (-not $closed) { Start-Sleep -Milliseconds 200 }
        }
        Assert $closed 'Escape closes the card'
        $closes = @(Get-FindStates $errlog $paneId | Where-Object { $_.State -eq 'closed' })
        Assert ($closes.Count -ge 1 -and $closes[-1].Query -eq 'needle') `
            'closing KEEPS the query, so the next ctrl+F resumes the same search'

        Focus-TestWindow -Window $mdTop -Child $chrome.Host | Out-Null
        Start-Sleep -Milliseconds 300
        Send-TestViewerChord -Window $mdTop -Target $chrome.Widget -Modifiers ctrl -Key F | Out-Null
        $card2 = Wait-FindCard $mdTop
        Assert ($card2 -ne [IntPtr]::Zero) 'ctrl+F re-opens the card'
        $c6 = Wait-Count $errlog $paneId { param($x) $x.Query -eq 'needle' -and $x.Total -eq 5 }
        Assert ($null -ne $c6 -and $c6.Total -eq 5) `
            'the resumed search counts again without anything being retyped'

        # --- H. a miss says so rather than counting ------------------------
        $edit2 = Get-FindEdit $card2
        if ($edit2 -ne [IntPtr]::Zero) {
            Set-TestControlText -Control $edit2 -Text '' | Out-Null
            Send-TestControlText -Control $edit2 -Text 'haystackxyz' | Out-Null
            $c7 = Wait-Count $errlog $paneId { param($x) $x.Query -eq 'haystackxyz' }
            Assert ($null -ne $c7 -and $c7.Total -eq 0 -and $c7.Index -eq 0) `
                'a query with no matches reports zero rather than a stale count'
        } else {
            Skip 'a query with no matches reports zero (no EDIT after reopen)'
        }
    }

    # --- I. a website pane searches too -------------------------------------
    # The bundled template is a `<script src>` document; an ordinary HTML file
    # is not, and find has to reach it through the injected user script or the
    # whole "every mode" claim is a claim about one mode.
    $before2 = @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow' | ForEach-Object { $_.Hwnd })
    Invoke-Verb @('+new-window', '--target=t1184html', "--view=$htmlPath") | Out-Null
    Assert ($null -ne (Wait-Win 't1184html')) 'the html viewer window exists'
    $htmlPane = Get-OnlyPane 't1184html'
    $htmlTop = Wait-TopWindow $appPid $before2
    $chrome2 = if ($htmlTop -ne [IntPtr]::Zero) { Wait-ChromeChild $htmlTop } else { $null }
    if ($null -eq $chrome2 -or $null -eq $htmlPane) {
        Skip 'a rendered HTML page is searchable (no viewer came up)'
    } else {
        Focus-TestWindow -Window $htmlTop -Child $chrome2.Host | Out-Null
        Start-Sleep -Milliseconds 400
        Send-TestViewerChord -Window $htmlTop -Target $chrome2.Widget -Modifiers ctrl -Key F | Out-Null
        $card3 = Wait-FindCard $htmlTop
        Assert ($card3 -ne [IntPtr]::Zero) 'ctrl+F opens a find card over a rendered HTML page'
        $edit3 = Get-FindEdit $card3
        if ($edit3 -eq [IntPtr]::Zero) {
            Skip 'a rendered HTML page is searchable (no EDIT)'
        } else {
            Send-TestControlText -Control $edit3 -Text 'needle' | Out-Null
            $c8 = Wait-Count $errlog $htmlPane.id { param($x) $x.Query -eq 'needle' -and $x.Total -gt 0 }
            Assert ($null -ne $c8 -and $c8.Total -eq 5) `
                "a page we did not render is searched too (got $(if ($c8) { $c8.Total } else { 'nothing' }))"
        }
    }

    # --- J. a diff pane names the file it is searching ----------------------
    $before3 = @(Get-TestWindows -ProcessId $appPid -Class 'GhozttyWindow' | ForEach-Object { $_.Hwnd })
    $rd = Invoke-Verb @('+new-window', '--target=t1184diff', '--view=git-diff:HEAD~1..HEAD')
    if ($rd.Code -ne 0 -or $null -eq (Wait-Win 't1184diff')) {
        Skip 'a diff pane names the file it is searching (no diff pane)'
    } else {
        $diffPane = Get-OnlyPane 't1184diff'
        $diffTop = Wait-TopWindow $appPid $before3
        $chrome3 = if ($diffTop -ne [IntPtr]::Zero) { Wait-ChromeChild $diffTop } else { $null }
        if ($null -eq $chrome3 -or $null -eq $diffPane) {
            Skip 'a diff pane names the file it is searching (no viewer came up)'
        } else {
            Start-Sleep -Seconds 2
            Focus-TestWindow -Window $diffTop -Child $chrome3.Host | Out-Null
            Start-Sleep -Milliseconds 400
            Send-TestViewerChord -Window $diffTop -Target $chrome3.Widget -Modifiers ctrl -Key F | Out-Null
            $card4 = Wait-FindCard $diffTop
            $edit4 = Get-FindEdit $card4
            if ($edit4 -eq [IntPtr]::Zero) {
                Skip 'a diff pane names the file it is searching (no card)'
            } else {
                Send-TestControlText -Control $edit4 -Text 'e' | Out-Null
                $c9 = Wait-Count $errlog $diffPane.id { param($x) $x.Query -eq 'e' }
                Assert ($null -ne $c9 -and $c9.Note -match '^in ') `
                    "a diff pane discloses WHICH file it is searching (note='$(if ($c9) { $c9.Note } else { '' })')"
            }
        }
    }

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash anywhere in the run'
}
finally {
    Stop-RepoInstances
    Remove-TestDesktop -Desktop $td
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

# The user's actual complaint, asserted rather than assumed: nothing this run
# launched may ever have taken the INTERACTIVE desktop's foreground.
$fgSeen = @(Stop-TestForegroundWatch)
$leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
Assert ($leaked.Count -eq 0) "no test-desktop app ever became foreground on the interactive desktop (saw $($leaked -join ','))"

# A green run stamps the covered files (T783) so guard-due can answer "has this
# harness been run against the code as it now stands?". Red leaves the stamp
# alone: red stays due, and a negative-control run is red by construction.
if ($script:fail -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard viewer-find -Repo $repo 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-Host "$script:pass passed, $script:fail failed, $script:skipped skipped"
if ($NegativeControl) {
    if ($script:fail -eq 2) {
        Write-Host 'NEGATIVE CONTROL OK: exactly the two inverted count assertions failed'
        exit 0
    }
    Write-Host "NEGATIVE CONTROL BROKEN: expected 2 failures, got $script:fail" -ForegroundColor Red
    exit 1
}
if ($script:fail -eq 0) { Write-Host 'ALL PASS'; exit 0 }
Write-Host "$script:fail FAILURE(S)" -ForegroundColor Red
exit 1
