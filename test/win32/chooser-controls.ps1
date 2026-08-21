# Chooser control-locator acceptance (T294) - the harness module every other
# chooser script now asks "which control is this".
#
#   powershell -NoProfile -File test\win32\chooser-controls.ps1
#
# `lib\ChooserControls.ps1` replaced seven private copies of "find the
# management button" / "find the account control" / "find Restore All", each of
# which identified a control by its LABEL, by its POSITION in a row, or by
# EXCLUDING the labels it is not. T177 added one button to the detail pane's
# action row and two of those copies silently started naming the new button;
# T335 added another and grew two more copies. The module asks the app for the
# control's own ID instead (`GetDlgCtrlID` - the `hMenu` MachineChooser.zig
# passed to CreateWindowEx, which is what WM_COMMAND is routed on).
#
# That trades one failure mode for another, and this script measures both:
#
#   A. THE COUPLING. The ids are restated in the harness, so they can drift
#      from the app's. Section A parses `src/apprt/win32/MachineChooser.zig`
#      (and `win32.zig` for IDOK/IDCANCEL) and fails if the two tables ever
#      disagree - in either direction, including an id the app grew that the
#      harness does not know about. No GUI: this half runs anywhere.
#
#   B. THE LOOKUPS, against the real dialog. Every named control resolves, to
#      distinct windows, of the right class, and - the property the label and
#      geometry copies could not keep - a HIDDEN control is still FOUND, with
#      `Visible` reporting the state rather than the lookup answering "absent".
#      The claims those private copies made as premises (the primary is
#      labeled "New Window"; the menu button is square; the account row holds
#      exactly two controls of which one is visible) are assertions here, which
#      is the point: a lookup keyed on a label cannot also test the label.
#
#      B also scores the module's one non-lookup, `Focus-ChooserControl` (T342):
#      the Tab walk three restore-all scripts used to keep a private copy of.
#      It is a POSITIVE CONTROL wherever it is used, so both directions are
#      scored - it lands on a reachable control, AND a walk at an unreachable
#      one comes back false with a trail naming the step that lost focus. A
#      walk that fails intermittently and says nothing is what T342 was filed
#      for.
#
# -NegativeControl inverts B's hidden-control assertion to expect Activity to be
# MISSING while it is hidden, which MUST fail; it is how a run proves the lookup
# really does see through visibility rather than getting lucky.
#
# T218-era rules: runs on a BACKGROUND test desktop, so it never takes the
# user's foreground (asserted at the end, not assumed), and only ever touches
# ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [switch]$NegativeControl,
    [switch]$Interactive
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
# Isolate the IPC endpoint (inherited through CreateProcessW): an instance
# answering the shared pipe would let another run's windows into this one.
$env:GHOZTTY_PIPE_SUFFIX = '-choosectl'

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:pass = 0
$script:fail = 0
$script:negReached = $false
# A drive that throws part way unwinds to `finally` and would otherwise reach
# the summary having scored only section A - i.e. announce a pass for a run that
# never opened the dialog.
$script:drove = $false

function Assert([bool]$cond, [string]$name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

function Stop-DebugGhoztty {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 800 | Out-Null
}

# --- A: the harness's id table vs the app's ----------------------------------
Write-Host ''
Write-Host '=== A: the restated control ids match MachineChooser.zig ==='

$chooserSrc = Join-Path $repo 'src\apprt\win32\MachineChooser.zig'
$win32Src = Join-Path $repo 'src\apprt\win32\win32.zig'
if (-not (Test-Path $chooserSrc)) {
    Write-TestAssertedNothing -Label 'CHOOSER-CONTROLS ACCEPTANCE' `
        -Reason "MachineChooser.zig not found at $chooserSrc"
}

# `const NAME_ID: u16 = 103;` -> @{ NAME_ID = 103 }, plus the two dialog-manager
# ids the chooser reuses from win32.zig. Every id the APP defines has to be in
# the harness table: an id we do not know about is a control a script will end
# up finding some other, rottable way.
$appIds = @{}
foreach ($m in [regex]::Matches((Get-Content $chooserSrc -Raw), '(?m)^const\s+(\w+_ID)\s*:\s*u16\s*=\s*(\d+)\s*;')) {
    $appIds[$m.Groups[1].Value] = [int]$m.Groups[2].Value
}
foreach ($m in [regex]::Matches((Get-Content $win32Src -Raw), '(?m)^pub const (IDOK|IDCANCEL)\s*:\s*i32\s*=\s*(\d+)\s*;')) {
    $appIds[$m.Groups[1].Value] = [int]$m.Groups[2].Value
}
Assert ($appIds.Count -ge 9) "the app's control ids were parsed (found $($appIds.Count): $(($appIds.Keys | Sort-Object) -join ', '))"

# harness key -> the app constant it mirrors.
$mirror = @{
    primary     = 'IDOK'
    cancel      = 'IDCANCEL'
    filter      = 'FILTER_ID'
    list        = 'LIST_ID'
    account     = 'ACCOUNT_ID'
    menu        = 'MENU_ID'
    activity    = 'ACTIVITY_ID'
    accountLink = 'ACCOUNT_LINK_ID'
    restoreAll  = 'RESTORE_ALL_ID'
    share       = 'SHARE_ID'
}
foreach ($k in ($mirror.Keys | Sort-Object)) {
    $want = $mirror[$k]
    $have = $script:ChooserIds[$k]
    Assert ($appIds.ContainsKey($want) -and $appIds[$want] -eq $have) `
        "ChooserIds.$k = $have matches $want = $(if ($appIds.ContainsKey($want)) { $appIds[$want] } else { '<absent>' })"
}
# The other direction: an id the app grew and the harness never learned. This is
# the arm that keeps the table honest as the dialog gains controls.
$unknown = @($appIds.Keys | Where-Object { $mirror.Values -notcontains $_ })
Assert ($unknown.Count -eq 0) `
    "every control id the app defines is named in ChooserIds (unmirrored: $($unknown -join ', '))"

# A name nobody defined must throw rather than quietly return $null: a typo in a
# lookup would otherwise read as "this dialog has no such control".
$threw = $false
try { Get-ChooserControl -Chooser ([IntPtr]::Zero) -Name 'nosuchcontrol' | Out-Null }
catch { $threw = $true }
Assert $threw 'an unknown control name throws instead of answering $null'

# --- B: the lookups against the real dialog ----------------------------------
Write-Host ''
Write-Host '=== B: the lookups find the real controls ==='

if (-not (Test-Path $Exe)) {
    Write-TestAssertedNothing -Label 'CHOOSER-CONTROLS ACCEPTANCE' -Reason "$Exe not found"
}
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

$tmp = Join-Path $env:TEMP "ghoztty-choosectl-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$errlog = Join-Path $tmp 'stderr.log'

Stop-DebugGhoztty
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    # persistence: explicitly off - this script restores nothing and must not
    # inherit whatever panes the previous run left in the manifest.
    #
    # The client id is pinned so the account row lands in its signed-OUT state
    # (a bordered button, with the link hidden), which is the pair section 7
    # below is about. With none resolvable the row is `unconfigured` and draws
    # neither control (T747) - a legitimate state, measured by section 8 of
    # relay-account.ps1, but not this script's subject, and which one a build
    # lands in depends on the box rather than on the code. Nothing here signs
    # in, so the value is never used.
    $env:GHOSTTY_GOOGLE_CLIENT_ID = 'cid-chooser-controls'
    $app = Start-OnTestDesktop -Exe $Exe -Arguments @('--session-persistence=false') -StdErr $errlog
    Remove-Item env:GHOSTTY_GOOGLE_CLIENT_ID -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) {
        Write-Host 'SETUP FAIL: GUI died at launch'
        Write-TestVerdict -Label 'CHOOSER-CONTROLS ACCEPTANCE' -Pass $script:pass -Fail ($script:fail + 1)
    }

    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: GhozttyWindow not found'
        Write-TestVerdict -Label 'CHOOSER-CONTROLS ACCEPTANCE' -Pass $script:pass -Fail ($script:fail + 1)
    }
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    Assert (-not (Test-TestDesktopLeak -ProcessId $app.Pid)) 'the GUI is NOT enumerable on the interactive desktop'

    [void](Send-TestKeys -Window $top -Target $surface -Modifiers ctrl, shift -Key N)
    $chooser = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyMachineChooser' -TimeoutMs 5000
    Assert ($chooser -ne [IntPtr]::Zero) 'ctrl+shift+n opened the chooser'
    if ($chooser -eq [IntPtr]::Zero) {
        Write-Host 'SETUP FAIL: no chooser to score'
        Write-TestVerdict -Label 'CHOOSER-CONTROLS ACCEPTANCE' -Pass $script:pass -Fail ($script:fail + 1)
    }
    Start-Sleep -Milliseconds 600

    # (1) every named control resolves, and to a DISTINCT window. One id
    # answering for two names would make half these lookups aliases.
    $named = @{}
    foreach ($k in ($script:ChooserIds.Keys | Sort-Object)) {
        $named[$k] = Get-ChooserControl -Chooser $chooser -Name $k
    }
    $missing = @($named.Keys | Where-Object { $null -eq $named[$_] } | Sort-Object)
    Assert ($missing.Count -eq 0) "every named chooser control resolves (missing: $($missing -join ', '))"
    $hwnds = @($named.Values | Where-Object { $_ } | ForEach-Object { [int64]$_.Hwnd })
    Assert ($hwnds.Count -eq (@($hwnds | Sort-Object -Unique).Count)) `
        "each name resolves to a DISTINCT window ($($hwnds.Count) controls, $((@($hwnds | Sort-Object -Unique)).Count) distinct)"

    # (2) the classes are what the vocabulary says they are.
    Assert ($named['list'] -and $named['list'].Class -eq 'ListBox') "the machine list is a LISTBOX (got '$(if ($named['list']) { $named['list'].Class })')"
    Assert ($named['filter'] -and $named['filter'].Class -eq 'Edit') "the filter is an EDIT (got '$(if ($named['filter']) { $named['filter'].Class })')"
    Assert ($named['primary'] -and $named['primary'].Class -eq 'Button') 'the primary action is a BUTTON'

    # (3) the labels. These were the PREMISES of the old lookups - they found
    # the control by the caption and then asserted the caption - so they only
    # become real assertions once identification stops using them.
    Assert ($named['primary'] -and $named['primary'].Text -eq 'New Window') `
        "the primary action is labeled 'New Window' (got '$(if ($named['primary']) { $named['primary'].Text })')"
    Assert ($named['cancel'] -and $named['cancel'].Text -eq 'Cancel') `
        "the footer button is labeled 'Cancel' (got '$(if ($named['cancel']) { $named['cancel'].Text })')"
    Assert ($named['restoreAll'] -and $named['restoreAll'].Text -eq 'Restore All') `
        "the restore-all button is labeled 'Restore All' (got '$(if ($named['restoreAll']) { $named['restoreAll'].Text })')"
    Assert ($named['activity'] -and $named['activity'].Text -eq 'Activity') `
        "the activity button is labeled 'Activity' (got '$(if ($named['activity']) { $named['activity'].Text })')"

    # (4) the SHAPE rule two private copies used as their locator: the
    # management button is square. An assertion now, not a premise.
    $mb = Get-ChooserMenuButton -Chooser $chooser
    Assert ($null -ne $mb) 'the management button is found'
    if ($mb) {
        Assert ($mb.Width -eq $mb.Height) "the management button is square ($($mb.Width)x$($mb.Height))"
    }

    # (5) HIDDEN controls are still found. The Local row is selected on open and
    # offers neither Activity nor the management menu, so both exist and are
    # hidden - which is the state a label lookup reports as "absent" and a
    # visible-only geometry lookup reports as the wrong control.
    $ab = Get-ChooserActivityButton -Chooser $chooser
    if ($NegativeControl) {
        $script:negReached = $true
        Assert ($null -eq $ab) 'NEGATIVE CONTROL: Activity is not found while hidden (MUST FAIL)'
    } else {
        Assert ($null -ne $ab) 'Activity is FOUND while hidden'
    }
    if ($ab) { Assert (-not $ab.Visible) 'and reports itself hidden on the Local row' }
    $ra = Get-ChooserRestoreAllButton -Chooser $chooser
    Assert ($null -ne $ra) 'Restore All is FOUND while hidden'

    # (6) the visible action ROW is the packed run, left to right, starting at
    # the primary - and on the Local row that is the whole row.
    $row = @(Get-ChooserActionRow -Chooser $chooser)
    Assert ($row.Count -ge 1 -and [int64]$row[0].Hwnd -eq [int64]$named['primary'].Hwnd) `
        "the action row starts at the primary action (row: $(($row | ForEach-Object { $_.Text }) -join ', '))"
    $sortedLefts = @($row | ForEach-Object { $_.Left })
    Assert (@(Compare-Object $sortedLefts (@($sortedLefts | Sort-Object)) -SyncWindow 0).Count -eq 0) `
        'the action row comes back left to right'
    $rowAll = @(Get-ChooserActionRow -Chooser $chooser -IncludeHidden)
    Assert ($rowAll.Count -gt $row.Count) `
        "-IncludeHidden returns the hidden members too (visible=$($row.Count), all=$($rowAll.Count))"

    # (7) the account row: two controls by id, one visible, and the plain
    # lookup returns the one the user can see. This is what the "exclude the
    # labels it is not" copy was trying to say.
    $acctBoth = @(Get-ChooserAccountButton -Chooser $chooser -IncludeHidden)
    $acctLive = Get-ChooserAccountButton -Chooser $chooser
    Assert ($acctBoth.Count -eq 2) "the account row owns two controls (found $($acctBoth.Count))"
    Assert ($null -ne $acctLive -and $acctLive.Visible) 'the account lookup returns a VISIBLE control'
    if ($acctLive) {
        Assert (@($acctBoth | Where-Object { $_.Visible }).Count -eq 1) 'exactly one of the two is visible at a time'
        Assert ([int64]$acctLive.Hwnd -eq [int64](@($acctBoth | Where-Object { $_.Visible })[0].Hwnd)) `
            'and it is that one'
    }

    # (8) the two STATICs, the one thing here still identified by geometry
    # (they carry no id, so there is nothing to ask for).
    $statusTop = Get-ChooserStatic -Chooser $chooser -Edge top
    $hintBottom = Get-ChooserStatic -Chooser $chooser -Edge bottom
    Assert ($null -ne $statusTop -and $null -ne $hintBottom) 'both chooser STATICs are found'
    if ($statusTop -and $hintBottom) {
        Assert ([int64]$statusTop.Hwnd -ne [int64]$hintBottom.Hwnd) 'the account status and the footer hint are different windows'
        Assert ($statusTop.Top -lt $hintBottom.Top) `
            "the account status sits above the hint (status top=$($statusTop.Top), hint top=$($hintBottom.Top))"
        Assert ((Get-ChooserHintText -Chooser $chooser) -eq $hintBottom.Text) 'Get-ChooserHintText reads the lowest STATIC'
    }

    # (9) the Tab walk, and - the part that matters - its ORACLE (T342).
    #
    # `Focus-ChooserControl` is a POSITIVE CONTROL wherever it is used: the
    # caller presses the control it lands on and then claims something about
    # the result, so a walk that quietly answers $false turns the assertion
    # after it into "nothing happened", which is what a broken key press looks
    # like too. T342 was filed for exactly that: one FAIL, one PASS, same
    # binary, and neither run said which step lost focus.
    #
    # So both directions are scored here. The walk lands on a reachable
    # control and its TRAIL names the controls it passed through; and a walk
    # at an UNREACHABLE one (Restore All is hidden with a single session, so
    # no number of Tabs can reach it) comes back false with a trail that says
    # LOST and why - proving the trail reports rather than decorating.
    $filterCtl = Get-ChooserFilterField -Chooser $chooser
    $primaryCtl = Get-ChooserPrimaryButton -Chooser $chooser
    $hiddenCtl = Get-ChooserRestoreAllButton -Chooser $chooser
    Assert ($null -ne $filterCtl -and $null -ne $primaryCtl -and $null -ne $hiddenCtl) `
        'the walk has a start, a reachable target and an unreachable one'
    Assert ($null -ne $hiddenCtl -and -not $hiddenCtl.Visible) `
        'Restore All is HIDDEN here (one session), so it is genuinely unreachable by Tab'
    if ($filterCtl -and $primaryCtl -and $hiddenCtl) {
        $landed = Focus-ChooserControl -Chooser $chooser `
            -From ([IntPtr]$filterCtl.Hwnd) -To ([IntPtr]$primaryCtl.Hwnd)
        $trail = $script:ChooserFocusTrail
        Assert $landed 'Tab walks focus from the filter onto New Window'
        Assert ([int64](Get-TestFocusedWindow -Window $chooser) -eq [int64]$primaryCtl.Hwnd) `
            'and focus is READ BACK on that button, not merely reported'
        Assert ($trail -match '^focus walk: filter ->' -and $trail -match 'primary@') `
            "the trail names the controls it walked ($trail)"

        # The oracle's negative control. Three tabs is plenty to prove the
        # point and keeps the deliberate failure short.
        $lost = Focus-ChooserControl -Chooser $chooser `
            -From ([IntPtr]$filterCtl.Hwnd) -To ([IntPtr]$hiddenCtl.Hwnd) -MaxSteps 3
        $lostTrail = $script:ChooserFocusTrail
        Assert (-not $lost) 'a walk at a HIDDEN control does not claim to have landed'
        Assert ($lostTrail -match 'LOST:') `
            "and the trail says which step lost it ($lostTrail)"
    }

    # (10) the click helper reaches the control it names: Cancel closes the
    # dialog. Nothing else in this script proves the geometry it computes lands
    # inside the right window.
    Assert ($null -ne $named['cancel']) 'there is a Cancel to click'
    [void](Invoke-ChooserClick -Chooser $chooser -Control $named['cancel'])
    Start-Sleep -Milliseconds 800
    Assert (-not (Test-TestWindowExists -Window $chooser)) 'Invoke-ChooserClick on Cancel closed the chooser'
    Assert (-not ($app.Process -and $app.Process.HasExited)) 'the app survived the whole drive'
    $script:drove = $true
    Complete-TestBody  # T1039: the run reached the end of its body

} finally {
    Remove-TestDesktop
    Stop-DebugGhoztty
}

$fgSeen = @(Stop-TestForegroundWatch)
Write-Host "foreground pids seen on the interactive desktop: $($fgSeen -join ' ')"
if (-not $Interactive -and $env:GHOZTTY_TEST_INTERACTIVE -ne '1') {
    $launched = @(Get-TestLaunchedPids)
    Assert ($fgSeen.Count -gt 0) 'the foreground watcher actually sampled (negative control)'
    Assert ($launched.Count -gt 0) 'the run actually launched apps on the test desktop'
    $leaked = @($launched | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground on the interactive desktop'
}

Assert $script:drove 'the drive ran to the end (nothing threw out of it)'
if ($NegativeControl -and -not $script:negReached) {
    Assert $false 'NEGATIVE CONTROL never reached its inverted assertion'
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

# --- stamp (T783) ------------------------------------------------------------
# A clean green run records the covered files so scripts\guard-due.ps1 can
# answer "has anyone run this harness against the code as it now stands?". The
# row exists because section A's answer went red unnoticed for a fortnight
# (T547 added SHARE_ID to the dialog; nothing asked this script about it).
if ($script:fail -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\guard-due.ps1') `
        update -Guard chooser-controls -Repo $repo 2>&1 | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-TestVerdict -Label 'CHOOSER-CONTROLS ACCEPTANCE' -Pass $script:pass -Fail $script:fail
