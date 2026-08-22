# Keyboard navigation of the machine chooser's SESSION ROSTER, shared (T1107).
#
# The roster is owner-drawn: it has no child HWNDs, so a harness cannot read a
# row back the way it reads an EDIT. Two consequences shape everything here.
#
#   1. THE DISPLAYED ORDER IS NOT THE AGENT'S ORDER. Since T602 the roster is
#      sorted by name or by CPU (a persisted preference), so an index computed
#      from `+sessions --json` is not the cursor's index space and "press Down
#      N times" lands on a different row than the one that was counted.
#   2. RIGHT CAN SILENTLY DO NOTHING. `enterSessions` bails when the roster has
#      no rows yet, and the roster is fetched asynchronously when the dialog
#      opens - so on a loaded box Right arrives before there is a list to enter,
#      no cursor is ever set, and Return falls through to the MACHINE row's
#      default action: a window opens, no session is resumed, and the assertion
#      that reads the agent back fails with nothing to point at.
#
# So the app says where the cursor landed after every step ("chooser roster:
# cursor on session id=..."), and every walk here reads that line back instead
# of assuming an order or assuming a keystroke landed. That is the T602/T620
# contract, and this file is the one copy of it: it lived inline in
# chooser-resume.ps1, was pasted into chooser-resume-remote.ps1 with a
# different timeout, and orphan-notify.ps1 was never converted at all - which
# is what scored it `2 FAILURE(S)` in the 242-script sweep against an attach
# path that works (T1107).
#
# Requires lib\TestDesktop.ps1 (Send-TestKeys) to be dot-sourced first.

$script:ChooserCursorPattern = 'chooser roster: cursor (on session id=([0-9a-fA-F]+)|left the list)'

function Get-ChooserCursorLineCount($Log) {
    # PS5.1 turns a $null argument bound to a string into '', and `Test-Path ''`
    # throws rather than answering false - so the emptiness check comes first.
    if (-not $Log -or -not (Test-Path $Log)) { return 0 }
    return @(Select-String -Path $Log -Pattern $script:ChooserCursorPattern -ErrorAction SilentlyContinue).Count
}

<#
Send one cursor key to the chooser and wait for the app to say where the cursor
landed.

    $id = Step-ChooserCursor -Chooser $chooser -Filter $filter -Log $errlog -Key 'Right'

Keys go to the filter EDIT, which is where focus sits when the chooser opens -
the state a real user is in when they press Right. Returns the landed session
id, '' when the cursor left the list, or $null when no landing was logged
within the timeout (the key was not roster navigation, or the roster was not
there to enter).
#>
function Step-ChooserCursor {
    param(
        [Parameter(Mandatory)] $Chooser,
        [Parameter(Mandatory)] $Filter,
        [Parameter(Mandatory)] [string]$Log,
        [Parameter(Mandatory)] [string]$Key,
        [int]$TimeoutMs = 4000
    )
    $before = Get-ChooserCursorLineCount $Log
    Send-TestKeys -Window $Chooser -Target $Filter -Key $Key | Out-Null
    $waited = 0
    while ($waited -lt $TimeoutMs) {
        $m = @(Select-String -Path $Log -Pattern $script:ChooserCursorPattern -ErrorAction SilentlyContinue)
        if ($m.Count -gt $before) {
            $last = $m[-1]
            if ($last.Matches[0].Groups[2].Success) { return $last.Matches[0].Groups[2].Value }
            return ''
        }
        Start-Sleep -Milliseconds 100
        $waited += 100
    }
    return $null
}

<#
Park the keyboard cursor on the first displayed roster row whose id is in
$TargetIds.

    $landed = Walk-ChooserCursorToId -Chooser $c -Filter $f -Log $log -TargetIds @($id) -MaxRows 8

Resets to the top (Left leaves the list, Right re-enters at displayed row 0),
then Down-scans, reading each landing back from the log. Returns the landed id,
or $null when the walk never entered the list or ran off the end without a
match - which is a real failure to report, not a reason to press Return anyway.

`-EnterRetries` covers the async roster: a Right that logs nothing means there
was no list to enter yet, so it is retried rather than counted as absent.
#>
function Walk-ChooserCursorToId {
    param(
        [Parameter(Mandatory)] $Chooser,
        [Parameter(Mandatory)] $Filter,
        [Parameter(Mandatory)] [string]$Log,
        [Parameter(Mandatory)] [string[]]$TargetIds,
        [int]$MaxRows = 16,
        [int]$EnterRetries = 3
    )
    Step-ChooserCursor -Chooser $Chooser -Filter $Filter -Log $Log -Key 'Left' | Out-Null
    $cur = $null
    for ($try = 0; $try -lt $EnterRetries; $try++) {
        $cur = Step-ChooserCursor -Chooser $Chooser -Filter $Filter -Log $Log -Key 'Right'
        if ($null -ne $cur -and $cur -ne '') { break }
        Start-Sleep -Milliseconds 500
    }
    for ($i = 0; $i -le $MaxRows; $i++) {
        if ($null -eq $cur -or $cur -eq '') { return $null }
        if ($TargetIds -contains $cur) { return $cur }
        $prev = $cur
        $cur = Step-ChooserCursor -Chooser $Chooser -Filter $Filter -Log $Log -Key 'Down'
        # The last row clamps: a Down that lands on the same id is the end.
        if ($cur -eq $prev) { return $null }
    }
    return $null
}
