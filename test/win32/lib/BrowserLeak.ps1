# Browser-leak tripwire (T594).
#
# A test must never reach the user's desktop, and the harness runs on a
# background desktop to make that true for OUR windows -- but `ShellExecuteW`
# on a URL launches the DEFAULT BROWSER in the interactive session no matter
# which desktop the caller lives on, so one escaped handoff is an Edge window
# left on the user's screen (the T594 report: t390-style loopback test pages
# accumulating in Edge until closed by hand). The product's test builds now
# refuse shell-opens outright (`builtin.is_test` in ViewerPane.zig); this is
# the harness-side arm that catches the acceptance-lane equivalent, where the
# app under test is a REAL build that can still shell-open.
#
# Mechanics: a WMI instance-creation subscription records every browser
# process born while the watch is up; at stop, launches whose command line
# carries a loopback URL are reported as leaks (a browser opening a page a
# test served is a leak by definition -- no user asks Edge for 127.0.0.1).
# Known honest limitation: `WITHIN 1` polls, so a launcher that lives under a
# second can slip by -- this is a tripwire with very good odds, not a proof.
# The zero-leak PROOF for unit lanes is the comptime guard above.
#
# Dot-source next to the other libs, then:
#   Start-TestBrowserWatch
#   ... run the suite ...
#   $leaks = @(Stop-TestBrowserWatch)   # also best-effort kills the launchers
#   Assert ($leaks.Count -eq 0) "no test page escaped to the default browser"

$script:BrowserWatchSid = $null

function Start-TestBrowserWatch {
    $sid = "ghoztty-browser-watch-$PID"
    # A stale registration from a crashed prior run under the same PID: clear it.
    Unregister-Event -SourceIdentifier $sid -ErrorAction SilentlyContinue
    Get-Event -SourceIdentifier $sid -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Event -EventIdentifier $_.EventIdentifier -ErrorAction SilentlyContinue }
    $query = "SELECT * FROM __InstanceCreationEvent WITHIN 1 " +
        "WHERE TargetInstance ISA 'Win32_Process' AND (" +
        "TargetInstance.Name = 'msedge.exe' OR " +
        "TargetInstance.Name = 'chrome.exe' OR " +
        "TargetInstance.Name = 'firefox.exe' OR " +
        "TargetInstance.Name = 'iexplore.exe')"
    try {
        Register-CimIndicationEvent -Query $query -SourceIdentifier $sid -ErrorAction Stop | Out-Null
        $script:BrowserWatchSid = $sid
    } catch {
        # WMI eventing unavailable: the watch is a tripwire, not a gate -- say
        # so and let the suite run rather than failing it over the sensor.
        Write-Host "WARN  browser-leak watch unavailable: $($_.Exception.Message)"
        $script:BrowserWatchSid = $null
    }
}

function Stop-TestBrowserWatch {
    $sid = $script:BrowserWatchSid
    $script:BrowserWatchSid = $null
    if (-not $sid) { return @() }
    $leaks = @()
    foreach ($e in @(Get-Event -SourceIdentifier $sid -ErrorAction SilentlyContinue)) {
        $p = $e.SourceEventArgs.NewEvent.TargetInstance
        if ($p.CommandLine -match 'https?://(127\.0\.0\.1|localhost)[:/]') {
            $leaks += ("{0} pid={1} cmd={2}" -f $p.Name, $p.ProcessId, $p.CommandLine)
            # A failed assert cleans up after itself: the URL-bearing launcher
            # is the window when the browser was cold, and merely a hand-off
            # when it was warm -- killing it is best-effort either way.
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Remove-Event -EventIdentifier $e.EventIdentifier -ErrorAction SilentlyContinue
    }
    Unregister-Event -SourceIdentifier $sid -ErrorAction SilentlyContinue
    # A bare array return unrolls (PS5.1): empty comes back as nothing, which
    # @() at the call site counts as 0 -- never `return ,$leaks`, a one-element
    # comma wrapper here makes an EMPTY result count as 1 (see memory: PS5.1
    # null/comma traps).
    return $leaks
}
