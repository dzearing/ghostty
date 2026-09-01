# LaneSolo.ps1 - the pure half of floor-lane.ps1's solo confirm pass (T1170).
#
# A lane that goes red because 5000+ tests and a live WebView2 were competing
# for the box is not the same event as a lane that goes red because the code is
# broken, and until T1170 every turn discovered the difference by hand. The
# re-run itself lives in floor-lane.ps1 (it needs Invoke-Lane); what lives here
# is everything that can be answered without launching anything, so it can be
# covered by test\win32\floor-lane-solo-confirm.ps1 without staging a red lane.

<#
.SYNOPSIS
Names the zig tests a red lane log blames.

.DESCRIPTION
The build runner writes one line per failing test:

    error: 'apprt.win32.ViewerPane.test.host floor: a real controller ...' failed: ...
    error: 'pkg.Thing.test.does a thing' logged errors: ...

What comes back is the part AFTER the last `.test.` - the title as it was
written in the source - because that is what `-Dtest-filter` matches and it is
the only part a human recognises. The runner also prints

    error: while executing test 'benchmark.OscParser.decltest.OscParser', the
           following test command failed:

which names the test COMMAND, not a second failure, and is the line the T1170
report says everyone chases first. It is deliberately not matched.
#>
function Get-FailedTestName {
    param([string]$LogPath)
    $names = @()
    if (-not $LogPath -or -not (Test-Path $LogPath)) { return $names }
    foreach ($line in (Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue)) {
        if ($line -match "^\s*error: '(.+?)' (failed|logged errors)") {
            $full = $Matches[1]
            $idx = $full.LastIndexOf('.test.')
            $title = if ($idx -ge 0) { $full.Substring($idx + 6) } else { $full }
            if ($title -and $names -notcontains $title) { $names += $title }
        }
    }
    return $names
}

<#
.SYNOPSIS
The one-line annotation a solo re-run's verdict earns, for the run summary.

.DESCRIPTION
`PASS` alone means the loaded run was a harness/timing failure. Anything else
means the failure is in the code. Neither answer changes the lane's verdict:
red stays red, and the run still exits non-zero -- "passes alone" is a
diagnosis, not a pass. That rule is asserted by the acceptance harness, because
an annotation that quietly greened a lane would hide exactly the regressions
the floor exists to catch.
#>
function Get-SoloVerdictNote {
    param([Parameter(Mandatory)][string]$SoloResult)
    if ($SoloResult -eq 'PASS') {
        return 'PASS alone - NOT reproduced -> harness/timing, not the product'
    }
    return "$SoloResult alone - reproduced"
}
