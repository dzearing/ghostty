# ChooserControls.ps1 - the ONE place an acceptance script learns how to FIND
# the machine chooser's controls.
#
# Why this file exists (T294). Seven acceptance scripts drive the chooser, and
# every one of them kept a private copy of "find the management button" / "find
# the account control" / "find Restore All". T177 packed an **Activity** button
# into the detail pane's action row and broke two of them at once, in the
# quietest way there is:
#
#   * `chooser-menu.ps1` and `host-settings.ps1` both said "the management menu
#     is the first button to the RIGHT of New Window". After T177 that is
#     Activity - so host-settings would have CLICKED Activity, opening an
#     Activity Monitor panel, while asserting about a management menu.
#   * `relay-account.ps1` identified the account button by EXCLUDING the labels
#     it is not (`New Window`, `Open`, `Cancel`) - an exclusion list that grows
#     silently, and had just gained a fourth member.
#
# Both were repaired in T177, against shape rather than label. What was not
# fixed is the SHAPE of the problem, and the prediction in T294's own text came
# true before it was picked up: `Restore All` (T335) landed in that same row and
# grew TWO more private locators (`chooser-restore-all.ps1`,
# `chooser-restore-all-remote.ps1`), and `chooser-link-hover.ps1` grew a fifth
# copy of "the topmost visible button is the account control".
#
# ---------------------------------------------------------------------------
# HOW A CONTROL IS IDENTIFIED HERE - and why it is not by label or by geometry
#
# By its **control ID**. `MachineChooser.zig` creates every one of these
# controls with an explicit id (its `hMenu` argument), because that is how
# WM_COMMAND is routed back to the right handler - so the id is the app's OWN
# name for the control, not a second description of it invented out here.
# `GetDlgCtrlID` reads it straight off the HWND, needing neither the app's
# message loop nor a pixel.
#
# That makes every failure mode of the private copies impossible:
#
#   * a control that is RELABELED is still found (a label is a product decision
#     and is what several of these scripts assert ABOUT - keying the lookup on
#     it made those assertions circular),
#   * a control that MOVES, or that gains a neighbour in its row, is still
#     found (that is exactly what T177 broke),
#   * a control that is HIDDEN is still found, with `Visible` reporting the
#     state rather than the lookup silently answering "absent" (T335's Restore
#     All needs to read that state),
#   * and an id that is RENUMBERED fails LOUDLY - the lookup returns $null and
#     the script goes red - instead of quietly returning the wrong control.
#
# The ids are restated in `$ChooserIds` below. That is a coupling, and it is
# the good kind: it is an identity, not a layout number, so it does not drift
# under a redesign, and `chooser-controls.ps1` section A reads
# `MachineChooser.zig` and fails if the two tables ever disagree.
#
# The ONE thing here that is still measured off the live window is the pair of
# STATICs (the account status and the footer hint): both are created with a
# null id, so there is no id to ask for and "topmost" / "lowest" is the only
# statement available. It is written once, here, instead of three times.

# --- the app's control ids ---------------------------------------------------
#
# Mirrors the constants at the top of `src/apprt/win32/MachineChooser.zig`
# (IDOK/IDCANCEL come from `win32.zig`). Section A of
# `test\win32\chooser-controls.ps1` parses that file and fails if this table
# drifts from it.
$script:ChooserIds = @{
    primary     = 1     # IDOK          - "New Window", the detail pane's primary action
    cancel      = 2     # IDCANCEL      - the footer, alone
    filter      = 100   # FILTER_ID     - the machine filter EDIT
    list        = 101   # LIST_ID       - the machine LISTBOX
    account     = 102   # ACCOUNT_ID    - the account row's bordered button (signed OUT)
    menu        = 103   # MENU_ID       - the management "..." button (square)
    activity    = 104   # ACTIVITY_ID   - "Activity", created hidden
    accountLink = 105   # ACCOUNT_LINK_ID - the "Sign Out" link (signed IN)
    restoreAll  = 106   # RESTORE_ALL_ID  - "Restore All", created hidden
    share       = 107   # SHARE_ID      - the account band's "Share this machine" checkbox
}

# The action row's composition, in the order `chooser_layout.actionRow` packs it
# (primary, restore_all?, activity?, menu?). Kept as ids so the row's ORDER can
# be asserted against the labels without the lookup having consulted them.
$script:ChooserActionOrder = @('primary', 'restoreAll', 'activity', 'menu')

# The enumerator itself is generic - `Get-TestControls` in TestDesktop.ps1 -
# because the same shape serves the Host Settings dialog and the rename/confirm
# prompts, which are not the chooser. What lives here is the chooser's
# VOCABULARY: which of those controls is which.

<#
The chooser control named `$Name` (a key of `$ChooserIds`), or $null when this
chooser state does not have it.

This is the lookup every other function here is built on, and the one a script
should reach for: `Get-ChooserControl -Chooser $c -Name menu` says what it
wants, and cannot be confused by a neighbour, a relabel or a move.
#>
function Get-ChooserControl {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Chooser,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$VisibleOnly,
        $Desktop
    )
    if (-not $script:ChooserIds.ContainsKey($Name)) {
        throw "Get-ChooserControl: unknown chooser control '$Name' (known: $(($script:ChooserIds.Keys | Sort-Object) -join ', '))"
    }
    $want = $script:ChooserIds[$Name]
    return @(Get-TestControls -Window $Chooser -Class '*' -VisibleOnly:$VisibleOnly -Desktop $Desktop |
        Where-Object { $_.Id -eq $want }) | Select-Object -First 1
}

# --- the detail pane's action row -------------------------------------------

<#
The detail pane's action RUN, left to right:

    [ New Window ]  [ Restore All ]?  [ Activity ]?  [ ... ]?

Composition changes with the selected machine (`chooser_layout.Composition`),
so this returns what is actually there. VISIBLE members only by default, since
"what does this machine offer" is the usual question; -IncludeHidden returns
every member the dialog owns, which is what a test reading the hidden state
wants.

Sorted by Left - the packing order is a property of the layout and is worth
asserting, so it is measured here rather than assumed from `$ChooserActionOrder`.
#>
function Get-ChooserActionRow {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Chooser,
        [switch]$IncludeHidden,
        $Desktop
    )
    $ids = @($script:ChooserActionOrder | ForEach-Object { $script:ChooserIds[$_] })
    return @(Get-TestControls -Window $Chooser -Class 'Button' -Desktop $Desktop |
        Where-Object { $ids -contains $_.Id -and ($IncludeHidden -or $_.Visible) } |
        Sort-Object Left)
}

# "New Window" - always present; every machine row can open a window.
function Get-ChooserPrimaryButton {
    param([Parameter(Mandatory = $true)][IntPtr]$Chooser, $Desktop)
    return Get-ChooserControl -Chooser $Chooser -Name primary -Desktop $Desktop
}

# The management menu: the SQUARE glyph button at the end of the action row. Its
# label is a non-ASCII ellipsis and it used to be found as "the button after New
# Window" (T177 made that Activity) or by its shape.
function Get-ChooserMenuButton {
    param([Parameter(Mandatory = $true)][IntPtr]$Chooser, $Desktop)
    return Get-ChooserControl -Chooser $Chooser -Name menu -Desktop $Desktop
}

# "Activity" (T177) - created hidden; only a remote machine row offers it.
function Get-ChooserActivityButton {
    param([Parameter(Mandatory = $true)][IntPtr]$Chooser, $Desktop)
    return Get-ChooserControl -Chooser $Chooser -Name activity -Desktop $Desktop
}

# "Restore All" (T335) - created hidden; needs two or more live sessions, so the
# row grows and shrinks by one while the chooser is open.
function Get-ChooserRestoreAllButton {
    param([Parameter(Mandatory = $true)][IntPtr]$Chooser, $Desktop)
    return Get-ChooserControl -Chooser $Chooser -Name restoreAll -Desktop $Desktop
}

# "Share this machine" (T547) - the account band's CHECKBOX, at the band's
# leading edge in every account state. A plain BS_CHECKBOX, not an autocheckbox:
# its check state is set only from persisted or pending truth, so reading it is
# reading what the app believes rather than what the last click did.
function Get-ChooserShareToggle {
    param([Parameter(Mandatory = $true)][IntPtr]$Chooser, $Desktop)
    return Get-ChooserControl -Chooser $Chooser -Name share -Desktop $Desktop
}

# Cancel - alone in the footer.
function Get-ChooserCancelButton {
    param([Parameter(Mandatory = $true)][IntPtr]$Chooser, $Desktop)
    return Get-ChooserControl -Chooser $Chooser -Name cancel -Desktop $Desktop
}

function Get-ChooserFilterField {
    param([Parameter(Mandatory = $true)][IntPtr]$Chooser, $Desktop)
    return Get-ChooserControl -Chooser $Chooser -Name filter -Desktop $Desktop
}

function Get-ChooserList {
    param([Parameter(Mandatory = $true)][IntPtr]$Chooser, $Desktop)
    return Get-ChooserControl -Chooser $Chooser -Name list -Desktop $Desktop
}

# --- the account row ---------------------------------------------------------

<#
The account row's LIVE control: the owner-drawn "Sign Out" link when signed in,
the bordered sign-in button when not (T311). Both HWNDs exist at all times and
the chooser hides the one this state does not use, so visibility - not the
label, and not a position - is what tells them apart.

-IncludeHidden returns both, in id order (button, then link), for a test whose
subject IS the pair.
#>
function Get-ChooserAccountButton {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Chooser,
        [switch]$IncludeHidden,
        $Desktop
    )
    $ids = @($script:ChooserIds['account'], $script:ChooserIds['accountLink'])
    $found = @(Get-TestControls -Window $Chooser -Class 'Button' -Desktop $Desktop |
        Where-Object { $ids -contains $_.Id } | Sort-Object Id)
    if ($IncludeHidden) { return $found }
    return @($found | Where-Object { $_.Visible }) | Select-Object -First 1
}

<#
The chooser's two STATICs, the one lookup here that is still MEASURED.

Both are created with a null id (`MachineChooser.zig`), so there is nothing to
ask for: the account status is the topmost STATIC and the footer hint is the
lowest, which is a structural fact of the dialog (the account row sits above
the header rule; the hint sits under the body, beside Cancel).
#>
function Get-ChooserStatic {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Chooser,
        [ValidateSet('top', 'bottom')][string]$Edge = 'top',
        $Desktop
    )
    $statics = @(Get-TestControls -Window $Chooser -Class 'Static' -Desktop $Desktop)
    if ($statics.Count -eq 0) { return $null }
    if ($Edge -eq 'top') { return @($statics | Sort-Object Top)[0] }
    return @($statics | Sort-Object Top)[-1]
}

function Get-ChooserAccountStatusText {
    param([Parameter(Mandatory = $true)][IntPtr]$Chooser, $Desktop)
    $s = Get-ChooserStatic -Chooser $Chooser -Edge top -Desktop $Desktop
    if ($null -eq $s) { return $null }
    return $s.Text
}

function Get-ChooserHintText {
    param([Parameter(Mandatory = $true)][IntPtr]$Chooser, $Desktop)
    $s = Get-ChooserStatic -Chooser $Chooser -Edge bottom -Desktop $Desktop
    if ($null -eq $s) { return $null }
    return $s.Text
}

# --- clicking ----------------------------------------------------------------

<#
Click the CENTRE of a control returned by any of the lookups above.

Posted at the control itself: a posted message skips hit testing, so the target
has to be the window the OS would have routed to (T216). `Send-TestMouse`
converts to the WM_NC* family when the point does not hit-test to HTCLIENT
(T263), which is what makes this correct over chrome as well as over controls.
#>
function Invoke-ChooserClick {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Chooser,
        [Parameter(Mandatory = $true)]$Control,
        [ValidateSet('left', 'right')][string]$Button = 'left',
        $Desktop
    )
    if ($null -eq $Control) { return $false }
    $cx = [int](($Control.Left + $Control.Right) / 2)
    $cy = [int](($Control.Top + $Control.Bottom) / 2)
    return [bool](Send-TestMouse -Window $Chooser -Target ([IntPtr]$Control.Hwnd) `
            -X $cx -Y $cy -Button $Button -Desktop $Desktop)
}

# --- walking focus with the keyboard -----------------------------------------

# What control an HWND IS, in the chooser's own vocabulary, for a trail a human
# can read: "filter", "restoreAll", "Button#0" for something this dialog owns
# under no id of ours, "none" for 0.
#
# -Own is the set of windows the chooser owns. Pass it: an id is only the
# chooser's WORD for a control when the window is the chooser's, and every one
# of the app's windows lives on the same GUI thread, so a focus read can land on
# a window that shares an id with one of these and would otherwise be labelled
# as it. A window outside the set is named by class and handle instead: at that
# point WHICH window this is, is the whole question, and the chooser's word for
# an id would be an answer to a different one.
function Get-ChooserFocusLabel {
    param([Parameter(Mandatory = $true)][int64]$Hwnd, $Own, $Desktop)
    if ($Hwnd -eq 0) { return 'none' }
    $h = [IntPtr]$Hwnd
    $cls = Get-TestWindowClass -Window $h -Desktop $Desktop
    if (-not $cls) { $cls = 'window' }
    $id = Get-TestControlId -Control $h -Desktop $Desktop
    if ($null -ne $Own -and -not $Own.ContainsKey($Hwnd)) {
        return ("{0}#{1}!0x{2:X}" -f $cls, $id, $Hwnd)
    }
    foreach ($name in $script:ChooserIds.Keys) {
        if ($script:ChooserIds[$name] -eq $id) { return $name }
    }
    return "$cls#$id"
}

# Every window the chooser owns, as a hwnd set. One `EnumChildWindows` sweep,
# so treat it as a positive answer only: a hwnd it does not list is a reason to
# sweep again, not a foreign window. The dialog also grows and drops controls
# while it is open (the action row's composition follows the selected machine),
# which is the other reason one snapshot cannot be believed for a whole walk.
function Get-ChooserOwnWindows {
    param([Parameter(Mandatory = $true)][IntPtr]$Chooser, $Desktop)
    $own = @{}
    $own[[int64]$Chooser] = $true
    foreach ($c in @(Get-TestChildWindows -Window $Chooser -Class '*' -Desktop $Desktop)) {
        $own[[int64]$c.Hwnd] = $true
    }
    return $own
}

<#
Tab from `$From` onto `$To`, and answer whether focus actually LANDED there.

Every call site is a POSITIVE CONTROL: what follows presses the control and
then claims something about the result, and "nothing happened" is equally
consistent with the keys never having arrived (the T240 lesson). So this has to
be able to say WHY it failed and not merely that it did - a control that fails
intermittently and says nothing trains a turn to re-run until green, which is
exactly what T258 objects to. T342 was that failure: one FAIL and one PASS back
to back on the same binary, with nothing in either run naming a step.

Two properties make the walk work, and the private copies had only the first:

  * Each Tab is RE-AIMED at whatever now holds focus. `Send-TestKeys`
    SetFocus()es its -Target before posting, so six Tabs all aimed at the
    filter walk the SAME first step six times and focus never leaves the list.
    The copies got this right, and it is why the READ has to be right too:
    every step is aimed at whatever the previous read returned.
  * The move is POLLED FOR, not sampled once at a guessed delay. Focus here is
    asynchronous twice over - the app's SetFocus is deferred since T48, and the
    dialog manager moves focus on the app's own message loop - so a single read
    at a fixed 300ms is a race that reads the PREVIOUS control whenever the box
    is busy. Aimed at that stale control, the next Tab's SetFocus walks focus
    BACKWARDS and the step is spent for nothing; and a read that lands in the
    gap between two controls returns 0, which the copies treated as fatal on
    the spot. Both are transient states of a move in flight, not defects.

The TRAIL - what focus sat on after each Tab, how long each move took, and
which reads a 300ms sample would have got wrong - is printed as one line and
left in `$script:ChooserFocusTrail` for a caller that wants to assert on it.
#>
function Focus-ChooserControl {
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Chooser,
        [Parameter(Mandatory = $true)][IntPtr]$From,
        [Parameter(Mandatory = $true)][IntPtr]$To,
        [int]$MaxSteps = 6,
        [int]$SettleMs = 2000,
        [switch]$Quiet,
        $Desktop
    )
    # Which windows are the chooser's, so a walk can tell "focus moved on" from
    # "focus LEFT the dialog". Every window the app owns lives on ONE GUI
    # thread, so `Get-TestFocusedWindow` reads that thread's focus and will
    # happily name a control in another of its windows - which the old copies
    # then re-aimed the next Tab at, typing into whatever that was.
    $mine = Get-ChooserOwnWindows -Chooser $Chooser -Desktop $Desktop

    $steps = @("$(Get-ChooserFocusLabel -Hwnd ([int64]$From) -Own $mine -Desktop $Desktop)")
    $stale = 0
    $cur = [int64]$From
    $landed = $false
    $why = "focus never reached the target within $MaxSteps tabs"

    for ($i = 1; $i -le $MaxSteps; $i++) {
        Send-TestKeys -Window $Chooser -Target ([IntPtr]$cur) -Key Tab -Desktop $Desktop | Out-Null

        # The first read is taken where the private copies took theirs, so a
        # run says how often that sample WOULD have been wrong; the walk then
        # keeps polling for the move it is actually waiting on.
        Start-Sleep -Milliseconds 300
        $sample = [int64](Get-TestFocusedWindow -Window $Chooser -Desktop $Desktop)
        $f = $sample
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while (($f -eq 0 -or $f -eq $cur) -and $sw.ElapsedMilliseconds -lt $SettleMs) {
            Start-Sleep -Milliseconds 50
            $f = [int64](Get-TestFocusedWindow -Window $Chooser -Desktop $Desktop)
        }
        $sw.Stop()
        $ms = 300 + $sw.ElapsedMilliseconds

        # A hwnd the snapshot does not know is asked about AGAIN before it is
        # called an escape, because the snapshot is not evidence of absence: it
        # is one `EnumChildWindows` sweep of a dialog that adds and drops
        # controls while it is open, taken while the app is busy. T342's own
        # measurement is the reason - a walk reported focus on a window
        # carrying LIST_ID as foreign, in a run whose app log shows exactly one
        # chooser was ever opened, so the window can only have been that
        # chooser's own list and the first sweep simply did not have it.
        $rechecked = $false
        if ($f -ne 0 -and -not $mine.ContainsKey($f)) {
            $mine = Get-ChooserOwnWindows -Chooser $Chooser -Desktop $Desktop
            $rechecked = $mine.ContainsKey($f)
        }

        $label = "$(Get-ChooserFocusLabel -Hwnd $f -Own $mine -Desktop $Desktop)@$([math]::Round($ms / 1000, 2))s"
        if ($rechecked) { $label += '(re-read)' }
        if ($sample -ne $f) {
            $stale++
            $label += "(sample@0.3s=$(Get-ChooserFocusLabel -Hwnd $sample -Own $mine -Desktop $Desktop))"
        }
        $steps += $label

        if ($f -eq 0) {
            $why = "tab $i left focus UNREADABLE (0) for ${SettleMs}ms - the chooser's GUI thread has no focus at all"
            break
        }
        if ($f -eq $cur) {
            $why = "tab $i did not move focus off '$(Get-ChooserFocusLabel -Hwnd $cur -Own $mine -Desktop $Desktop)' within ${SettleMs}ms - the key never arrived"
            break
        }
        if (-not $mine.ContainsKey($f)) {
            $why = "tab $i moved focus onto $(Get-ChooserFocusLabel -Hwnd $f -Own $mine -Desktop $Desktop), which is NOT one of this chooser's $($mine.Count) windows (chooser=0x$('{0:X}' -f [int64]$Chooser)) - another of the app's windows took the GUI thread's focus mid-walk"
            break
        }
        $cur = $f
        if ($f -eq [int64]$To) { $landed = $true; break }
    }

    $verdict = if ($landed) { "landed in $($steps.Count - 1) tab(s)" } else { "LOST: $why" }
    if ($stale -gt 0) { $verdict += "; $stale sample(s) at 0.3s read a move still in flight" }
    $script:ChooserFocusTrail = "focus walk: $($steps -join ' -> ') ($verdict)"
    if (-not $Quiet) { Write-Host "  $script:ChooserFocusTrail" }
    return $landed
}
