<#
.SYNOPSIS
  The WebView2 browser processes a test lane leaves behind, and waiting for
  them to actually be gone before the next lane asks for an environment (T592).

.DESCRIPTION
  Two of the four floor lanes (win32 and agent) stand up a REAL WebView2
  environment, and `floor-lane.ps1 -Lane all` starts the next lane the instant
  the previous one exits. Three times between 2026-08-08 and 2026-08-09 that
  produced a red floor that was not red code: the incoming lane asked for an
  environment while the outgoing lane's browser tree was still tearing down,
  got `hr=0x80004005`, and the host-floor test reported it as a failure. Each
  occurrence cost a turn, and -- worse -- taught the loop to re-run a red gate
  instead of reading it.

  What this file owns is the identity question and the wait:

  * WHICH msedgewebview2.exe processes belong to a test lane. They live under
    Program Files, so a path filter on zig-out or zig-cache never sees them.
    Two markers name them, and BOTH are needed: `--webview-exe-name=<test exe>`
    is on the browser process the test binary created, and
    `--user-data-dir=...\ghoztty-wv2test-<pid>` is on that browser AND on every
    renderer/GPU/utility child it spawned. Matching only the first counted the
    tree as one process, which is how a sweep could report "0 leaked hosts"
    while several children were still holding the profile open.

  * WAITING for them to be gone. `Stop-Process` returns before the process
    dies, and a lane that starts on that return is racing the same teardown
    the kill was meant to end.

  Nothing here ever touches a WebView2 process that is not a test lane's: the
  user's own Ghoztty runs its viewer panes out of the same exe, and a sweep
  that took those would close the panes they are reading this in.
#>

# Profile directories `webview2.TestProfile` mints, one per test-binary pid.
# The name is the contract between the Zig side and this file.
$script:WEBVIEW_LANE_PROFILE_PREFIX = 'ghoztty-wv2test-'

function Get-WebViewLaneHost {
    <#
    .SYNOPSIS
        Every live msedgewebview2.exe process belonging to a test lane.
    .PARAMETER ExeNames
        Test binary names (e.g. ghostty-test.exe) whose browser processes count.
    .OUTPUTS
        Zero or more Win32_Process instances. Wrap the call in @().
    #>
    param([string[]]$ExeNames)

    $found = @()
    $all = Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue
    foreach ($h in $all) {
        $cl = $h.CommandLine
        if (-not $cl) { continue }
        # The children carry the profile but not the embedder's exe name, so
        # the profile marker is checked first: it is the one that matches the
        # whole tree.
        if ($cl -like "*$script:WEBVIEW_LANE_PROFILE_PREFIX*") { $found += $h; continue }
        foreach ($n in @($ExeNames)) {
            if ($n -and $cl -like "*--webview-exe-name=$n*") { $found += $h; break }
        }
    }
    return $found
}

function Wait-WebViewLaneSettle {
    <#
    .SYNOPSIS
        Block until no test-lane WebView2 process remains, or the deadline.
    .DESCRIPTION
        Returns rather than throws on a deadline: a lane that starts anyway is
        the behavior we have today, and the caller's job is to SAY that it did
        so the next red result can be read against it.
    .OUTPUTS
        [pscustomobject] Settled (bool), WaitedMs (int), Remaining (int).
    #>
    param(
        [string[]]$ExeNames,
        [int]$TimeoutSeconds = 20,
        [int]$PollMs = 250
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $deadlineMs = [math]::Max(0, $TimeoutSeconds) * 1000
    $remaining = @(Get-WebViewLaneHost -ExeNames $ExeNames).Count
    while ($remaining -gt 0 -and $sw.ElapsedMilliseconds -lt $deadlineMs) {
        Start-Sleep -Milliseconds ([math]::Max(10, $PollMs))
        $remaining = @(Get-WebViewLaneHost -ExeNames $ExeNames).Count
    }
    $sw.Stop()
    return [pscustomobject]@{
        Settled   = ($remaining -eq 0)
        WaitedMs  = [int]$sw.ElapsedMilliseconds
        Remaining = [int]$remaining
    }
}

function Remove-WebViewLaneProfile {
    <#
    .SYNOPSIS
        Delete the private profile directories of test binaries that are gone.
    .DESCRIPTION
        A test cannot delete its own: the browser process outlives it and holds
        the files open. Only a directory whose owning pid is gone is removed,
        so a concurrent run's profile is never pulled out from under it.
    .OUTPUTS
        [int] directories removed.
    #>
    param([string]$Root = $env:TEMP)

    $removed = 0
    $dirs = Get-ChildItem $Root -Directory -Filter "$script:WEBVIEW_LANE_PROFILE_PREFIX*" -ErrorAction SilentlyContinue
    foreach ($d in @($dirs)) {
        $ownerPid = 0
        if ($d.Name -match "^$script:WEBVIEW_LANE_PROFILE_PREFIX(\d+)$") { $ownerPid = [int]$matches[1] }
        if ($ownerPid -and (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue)) { continue }
        try {
            Remove-Item $d.FullName -Recurse -Force -ErrorAction Stop
            $removed++
        }
        catch {}
    }
    return $removed
}

function Invoke-WebViewLaneSweep {
    <#
    .SYNOPSIS
        Kill a lane's leaked WebView2 processes, WAIT for them to exit, then
        remove the profile directories they were holding.
    .DESCRIPTION
        The order is the whole point. Killing and immediately deleting was the
        old shape, and it lost both halves on a loaded box: the delete failed
        because the browser still had the files open, and the next lane started
        while the tree was still unwinding.
    .OUTPUTS
        [pscustomobject] Killed (int), Settled (bool), WaitedMs (int),
        Remaining (int), ProfilesRemoved (int).
    #>
    param(
        [string[]]$ExeNames,
        [int]$TimeoutSeconds = 20,
        [switch]$NoKill
    )

    $hosts = @(Get-WebViewLaneHost -ExeNames $ExeNames)
    if (-not $NoKill) {
        foreach ($h in $hosts) {
            try { Stop-Process -Id $h.ProcessId -Force -ErrorAction Stop } catch {}
        }
    }

    $settle = Wait-WebViewLaneSettle -ExeNames $ExeNames -TimeoutSeconds $TimeoutSeconds
    $profiles = Remove-WebViewLaneProfile

    return [pscustomobject]@{
        Killed          = [int]$hosts.Count
        Settled         = $settle.Settled
        WaitedMs        = $settle.WaitedMs
        Remaining       = $settle.Remaining
        ProfilesRemoved = $profiles
    }
}

function Format-WebViewSettle {
    <#
    .SYNOPSIS
        The one line a lane prints about its settle, or '' when there was
        nothing to say.
    .DESCRIPTION
        Silence is the normal case and it has to stay silent, or the signal
        drowns: a settle that waited nothing gets no line at all. A settle that
        WAITED says how long, and one that gave up says so in the words a
        reader needs when the lane behind it goes red.
    #>
    param(
        [Parameter(Mandatory)]$Settle,
        [string]$Lane = ''
    )
    $where = if ($Lane) { "LANE $Lane " } else { '' }
    if (-not $Settle.Settled) {
        return ("${where}WEBVIEW NOT SETTLED: $($Settle.Remaining) browser process(es) still up after " +
            "$([int]($Settle.WaitedMs / 1000))s - a WebView2 failure in this lane may be that teardown, not this code (T592)")
    }
    if ($Settle.WaitedMs -ge 500) {
        return "${where}waited $($Settle.WaitedMs)ms for the previous lane's WebView2 processes to exit"
    }
    return ''
}
