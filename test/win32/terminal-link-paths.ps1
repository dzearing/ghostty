# T757 acceptance: a Windows path printed into a pane is a LINK.
#
# The fix is one shared-core regex (`src/config/url.zig`), asserted
# exhaustively in the `none` lane. What that lane cannot answer is whether the
# terminal surface on this box actually finds a Windows path in its own screen
# contents and treats it as a link, which is the thing the user complained
# about. This script asks the running app.
#
# THE ORACLE is a ctrl+RIGHT-click, which SELECTS rather than opens. A
# right-press with the default `right-click-action = context-menu` runs
# `linkAtPos` and, when it finds a link, selects exactly that link (else the
# plain word) before showing the menu - so the selection it leaves behind is
# the terminal's own answer to "what link is here", readable through ctrl+c
# and the clipboard. Nothing is launched, which a left-click would do.
#
# Ctrl because that is the configured `hover_mods` of the default link: the
# same modifier a user holds to click one.
#
# Column 0 is what makes the answer unambiguous. `:` is a word boundary
# (Config.SelectionWordChars) and `\`, `/` and `.` are not, so clicking the
# `Q` of `Q:\Users\...`:
#
#   * with link detection  -> the whole path, `Q:\Users\David\clip.mp4`
#   * without it (word)    -> the single character `Q`
#
# Those cannot be confused, and section C is the control that proves the
# difference is link detection and not a fat word: the same click at the same
# column on `Z: not a path here` must come back as the lone `Z`.
#
# UNC (`\\server\share\a.txt`) is deliberately NOT probed here. It carries no
# word-boundary character, so word-select and link-select return the same
# string and the assertion would pass on a build with no Windows branch at
# all. It is covered by `test "url regex"` in the none lane.
#
# Runs on a BACKGROUND desktop (test/win32/lib/TestDesktop.ps1) - it never
# takes the user's foreground, asserted at the end rather than assumed.
#
# -NegativeControl flips section A to assert the path is NOT selected whole,
# and MUST fail.
#
# Only touches ghoztty processes running from this repo's zig-out.
#   powershell -NoProfile -File test\win32\terminal-link-paths.ps1
param([string]$Exe, [switch]$NegativeControl, [switch]$Interactive)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $Exe) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
[void](Assert-GhozttyIsolatedBuild -Exe $Exe)

# Isolate the IPC endpoint: inherited by the app through CreateProcessW and by
# every `& $Exe +...` below, so this run cannot drive the user's terminal.
$env:GHOZTTY_PIPE_SUFFIX = '-linkpath'
$errlog = Join-Path $env:TEMP 'ghoztty-linkpath-stderr.log'
Remove-Item $errlog -ErrorAction SilentlyContinue

$script:pass = 0
$script:fail = 0
function Assert([bool]$cond, [string]$label) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" }
    else { $script:fail++; Write-Host "FAIL  $label" -ForegroundColor Red }
}

function Stop-RepoGhoztty {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.ExecutablePath -like (Join-Path $repo 'zig-out\*') -or $_.ExecutablePath -eq $Exe } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
}

function Get-ActiveSurface {
    $h = [IntPtr](Get-TestFocusedWindow -Window $script:top)
    if ($h -eq [IntPtr]::Zero -or (Get-TestWindowClass -Window $h) -ne 'GhozttyTerminal') {
        $h = Get-TestChildWindow -Window $script:top -Class 'GhozttyTerminal'
    }
    return $h
}

# Fill the screen with one line, repeated, so a probe row lands on it. `cls`
# first: without it the rows above are whatever the shell's startup printed.
#
# The command goes through `--keys-file=`, not as a positional argument, for
# the reason CLAUDE.md gives: a positional is checked for key notation and
# then for escape sequences, and `Q:\Users\...` is full of backslashes that
# are not escapes it knows. The first draft of this script sent it as a
# positional and the pane received `Q:UsersDavidclip.mp4` - three assertions
# red against a build whose regex was correct.
function Write-Lines([string]$text, [int]$count = 14) {
    & $Exe +send-keys --target=$script:pane "cls" Enter | Out-Null
    Start-Sleep -Milliseconds 700
    $keys = Join-Path $env:TEMP 'ghoztty-linkpath-keys.txt'
    [System.IO.File]::WriteAllText($keys, "echo $text", (New-Object System.Text.UTF8Encoding($false)))
    for ($i = 0; $i -lt $count; $i++) {
        & $Exe +send-keys --target=$script:pane "--keys-file=$keys" Enter | Out-Null
    }
    Start-Sleep -Seconds 2
    Remove-Item $keys -ErrorAction SilentlyContinue
    # Transport control: what the pane HOLDS, before anything is asserted
    # about what it selects.
    $tail = (& $Exe +read --name=$script:pane --lines=6 | Out-String)
    return $tail.Contains($text)
}

# Right-click column 0 of some row and return what the terminal selected.
#
# A right-press is what the core answers with `linkAtPos` -> `setSelection`,
# falling back to `selectWord` (Surface.zig, right_click_action =
# context-menu), so the selection it leaves behind IS the link the terminal
# found - or the plain word, when it found none.
#
# The obvious gesture, a double-click, is deliberately not used. It reaches
# link detection too (with no modifier at all), and the instrumented build
# showed it FINDING the whole link - and then the clipboard came back holding
# the plain word anyway, so something replaces the selection right after. That
# is filed as its own defect (T802); this script must not be a verdict on it,
# in either direction.
#
# The row is probed rather than computed: mapping a row index to a client y
# needs the cell height, which nothing reports - so walk down the pane until
# one of the repeated lines answers. Bounded, and every answer is recorded so
# a caller can assert on the whole SET, not just on the one it hoped for.
function Get-Column0Selections([int]$Rows = 12) {
    $surface = Get-ActiveSurface
    $pr = Get-TestWindowRect -Window $surface -Client
    # x: a few pixels in from the pane's left edge is inside cell column 0 for
    # any cell width the font can produce at any of our scale factors.
    $x = $pr.Left + 4
    $seen = @()
    for ($i = 1; $i -le $Rows; $i++) {
        $y = [int]($pr.Top + ($pr.Bottom - $pr.Top) * $i / ($Rows + 2))
        Set-Clipboard -Value 'T757_CLIP_SENTINEL'
        [void](Send-TestMouse -Window $script:top -Target $surface -X $x -Y $y `
            -Button right -Action down -Modifiers ctrl)
        Start-Sleep -Milliseconds 400
        # The menu's modal loop owns the GUI thread until it is cancelled, and
        # WM_CANCELMODE ends it without a keystroke (a key would risk
        # selection-clear-on-typing eating the very selection being measured).
        [void](Invoke-TestMessage -Window $surface -Message 0x001F)
        Start-Sleep -Milliseconds 250
        [void](Send-TestKeys -Window $script:top -Target $surface -Key C -Modifiers ctrl)
        Start-Sleep -Milliseconds 450
        $clip = (Get-Clipboard -Raw -ErrorAction SilentlyContinue) -join ''
        if ($null -eq $clip) { $clip = '' }
        $clip = $clip.TrimEnd("`r", "`n")
        if ($clip -ne 'T757_CLIP_SENTINEL' -and $clip -ne '') { $seen += $clip }
    }
    return , @($seen | Select-Object -Unique)
}

Stop-RepoGhoztty
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive
$app = $null
$launched = @()

try {
    # persistence: --session-persistence=false so a previous run's manifest is
    # never restored over the single pane this script measures.
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -StdErr $errlog
    $launched += $app.Pid
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) {
        Write-TestAssertedNothing -Reason 'GUI died at launch'
    }
    $script:top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($script:top -eq [IntPtr]::Zero) {
        Write-TestAssertedNothing -Reason 'top-level window never appeared'
    }
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'window is NOT enumerable on the interactive desktop'

    Focus-TestWindow -Window $script:top | Out-Null
    Start-Sleep -Milliseconds 600

    $lj = & $Exe +list --json | ConvertFrom-Json
    $splits = $lj.data.windows[0].tabs[0].splits
    $script:pane = if ($splits.type -eq 'leaf') { $splits.terminal.name } else { $splits.left.terminal.name }
    if ([string]::IsNullOrEmpty($script:pane)) {
        Write-TestAssertedNothing -Reason 'no pane name in +list --json'
    }

    # --- 0: positive control - a plain URL selects whole ----------------------
    # If this fails, nothing below is a verdict on T757: it means link
    # detection itself is not reaching this build.
    $ctl = 'https://example.com/a'
    Assert (Write-Lines $ctl) "0: transport control - the pane really holds $ctl"
    $sel0 = Get-Column0Selections
    Write-Host "  column-0 selections seen: $($sel0 -join ' | ')"
    if (-not ($sel0 -contains $ctl)) {
        Write-Host 'ABORT: the link path does not select a plain URL whole -'
        Write-Host '       link detection is not reaching this build, so nothing below is a T757 verdict.'
    }
    Assert ($sel0 -contains $ctl) '0: positive control - ctrl+right-click selects a whole URL'

    # --- A: a backslash drive path selects whole ------------------------------
    $pathA = 'Q:\Users\David\clip.mp4'
    Assert (Write-Lines $pathA) "A: transport control - the pane really holds $pathA"
    $selA = Get-Column0Selections
    Write-Host "  column-0 selections seen: $($selA -join ' | ')"
    $wholeA = $selA -contains $pathA
    if ($NegativeControl) {
        Write-Host 'NEGATIVE CONTROL: asserting the drive path is NOT selected whole - this run MUST fail'
        Assert (-not $wholeA) "NEGATIVE CONTROL: $pathA is not link-selected"
    } else {
        Assert $wholeA "A: ctrl+right-click on column 0 selects the whole drive path ($pathA)"
    }
    # The un-linked answer must not ALSO be present from the same rows: it
    # would mean some rows detect the link and some do not.
    Assert (-not ($selA -contains 'Q')) 'A: no probed row fell back to the bare drive letter'

    # --- B: a drive path spelled with forward slashes -------------------------
    $pathB = 'R:/tools/run.bat'
    Assert (Write-Lines $pathB) "B: transport control - the pane really holds $pathB"
    $selB = Get-Column0Selections
    Write-Host "  column-0 selections seen: $($selB -join ' | ')"
    Assert ($selB -contains $pathB) "B: forward-slash drive path selects whole ($pathB)"

    # --- C: control - the same click on prose is a WORD, not a path -----------
    # Without this, A and B would pass on a build where a double-click simply
    # grabbed the whole non-boundary run.
    Assert (Write-Lines 'Z: not a path here') 'C: transport control - the pane really holds the prose line'
    $selC = Get-Column0Selections
    Write-Host "  column-0 selections seen: $($selC -join ' | ')"
    Assert ($selC -contains 'Z') 'C: control - column 0 of prose selects the single word'
    Assert (-not ($selC -contains 'Z: not a path here')) 'C: control - prose with a colon is not treated as a path'

    Assert (-not ($app.Process -and $app.Process.HasExited)) 'no crash'
} finally {
    if ($app -and $app.Pid) { Stop-Process -Id $app.Pid -Force -ErrorAction SilentlyContinue }
    Remove-TestDesktop
    Stop-RepoGhoztty
}

$fgSeen = @(Stop-TestForegroundWatch)
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Write-Host ''
Write-TestVerdict -Pass $script:pass -Fail $script:fail
