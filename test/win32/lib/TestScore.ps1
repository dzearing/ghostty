# TestScore (T271) - a run that asserted NOTHING must not exit 0.
#
# The shape this exists for, measured: `host-settings.ps1`'s "the fake relay
# directory never came up on port $DirPort" branch printed
#
#       SKIP whole run: the fake relay directory never came up on port 47941
#     ALL PASS (0 assertions, 1 skipped)
#
# and exited 0. A port left held by the previous run - exactly the state a
# back-to-back re-run produces - therefore scored the whole T174 acceptance as
# green while asserting nothing at all. Two more sites did the same thing for
# their own reasons (`agent-user-env.ps1` when the box has no usable HKCU PATH
# entry, `agent-instance-lineage.ps1 -Release` with no staging build): a
# precondition failed, so every assertion was dropped, and the last line said
# ALL PASS.
#
# THE RULE:
#
#     A pass verdict must be backed by at least one PASSING assertion. A scorer
#     about to announce ALL PASS with a zero count has proved nothing and must
#     say so and exit nonzero.
#
# because a run that asserted nothing and a run that asserted everything are
# otherwise indistinguishable - both end in `exit 0` under a green line, which
# is the whole reason the class went unnoticed until a migration read one of
# them closely.
#
# `Write-TestVerdict` is that scorer, in one place rather than per script:
#
#     . (Join-Path $PSScriptRoot 'lib\TestScore.ps1')
#     ...
#     Write-TestVerdict -Label 'P1 ACCEPTANCE' -Pass $script:passes -Fail $script:failures
#
# Three verdicts, three exit codes, so a caller can tell them apart without
# parsing prose:
#
#   * exit 0 - `ALL PASS (N assertions[, K SKIPPED])`
#   * exit 1 - `N FAILURE(S) (...)`            - assertions ran and some failed
#   * exit 2 - `ASSERTED NOTHING (...)`        - nothing was proved either way
#
# Exit 2 rather than 1 because the two are different news: a 1 says the product
# is broken, a 2 says the HARNESS proved nothing and the product is unmeasured.
# Every existing consumer reads `ALL PASS` as a substring of the last line and
# treats any nonzero code as red, so both stay correct.
#
# `-MinPass` is the strong form of the same idea, for a script that knows how
# much it ought to score: a run that lands 3 of its 30 assertions is much closer
# to "asserted nothing" than to ALL PASS. It reports `ASSERTED TOO LITTLE` and
# exits 2 as well. It is opt-in - a floor nobody set is not a floor that failed.

# Deliberately sets no StrictMode: this file is dot-sourced INTO suite scripts,
# and a mode set here would silently change how every one of them evaluates.

function Get-TestVerdictLine {
    <#
      The verdict as a STRING, with no side effects, so the acceptance script
      can assert the wording without spawning a process and so a caller that
      wants to tee/log it can. `Write-TestVerdict` is this plus printing and
      exiting; the decision itself lives here, once.

      Returns an object: Line (what to print), Code (what to exit with),
      Kind ('pass' | 'fail' | 'nothing' | 'too-little').
    #>
    param(
        [int]$Pass,
        [int]$Fail,
        [int]$Skipped = 0,
        [string]$Label,
        [string]$Unit = 'assertions',
        [int]$MinPass = 1
    )

    if ($MinPass -lt 1) { $MinPass = 1 }
    $prefix = if ([string]::IsNullOrWhiteSpace($Label)) { '' } else { "${Label}: " }
    $skipNote = if ($Skipped -gt 0) { ", $Skipped SKIPPED" } else { '' }

    if ($Fail -gt 0) {
        return [pscustomobject]@{
            Kind = 'fail'
            Code = 1
            Line = "$prefix$Fail FAILURE(S) ($Pass $Unit passed$skipNote)"
        }
    }

    if ($Pass -le 0) {
        return [pscustomobject]@{
            Kind = 'nothing'
            Code = 2
            Line = "${prefix}ASSERTED NOTHING (0 $Unit$skipNote) - this run proved nothing; it is not a pass"
        }
    }

    if ($Pass -lt $MinPass) {
        return [pscustomobject]@{
            Kind = 'too-little'
            Code = 2
            Line = "${prefix}ASSERTED TOO LITTLE ($Pass of at least $MinPass $Unit$skipNote) - too much of this run was skipped to call it a pass"
        }
    }

    return [pscustomobject]@{
        Kind = 'pass'
        Code = 0
        Line = "${prefix}ALL PASS ($Pass $Unit$skipNote)"
    }
}

function Write-TestVerdict {
    <#
      Print the verdict and end the script with the matching exit code. This is
      the last line an acceptance script runs.

      `-NoExit` prints and RETURNS the verdict object instead of exiting, for
      the handful of callers that must clean up afterwards (and for this rule's
      own acceptance script, which scores itself with it).
    #>
    param(
        [int]$Pass,
        [int]$Fail,
        [int]$Skipped = 0,
        [string]$Label,
        [string]$Unit = 'assertions',
        [int]$MinPass = 1,
        [switch]$NoExit
    )

    $v = Get-TestVerdictLine -Pass $Pass -Fail $Fail -Skipped $Skipped `
        -Label $Label -Unit $Unit -MinPass $MinPass

    $color = switch ($v.Kind) {
        'pass'  { 'Green' }
        default { 'Red' }
    }
    Write-Host $v.Line -ForegroundColor $color

    if ($NoExit) { return $v }
    exit $v.Code
}

# skip-audit: this is the scorer itself. The `SKIP whole run:` literal below is
# the wording it PRINTS for its callers, not a section this library skipped -
# there is no run here to count skips against.
# A precondition that failed before any assertion could run. Same verdict as
# `Pass = 0` above and the same exit code - this is only sugar, so the call site
# reads as what it is instead of as a scorer with zeroes in it.
function Write-TestAssertedNothing {
    param(
        [string]$Reason,
        [string]$Label,
        [int]$Skipped = 0,
        [switch]$NoExit
    )
    if (-not [string]::IsNullOrWhiteSpace($Reason)) { Write-Host "  SKIP whole run: $Reason" }
    return Write-TestVerdict -Pass 0 -Fail 0 -Skipped $Skipped -Label $Label -NoExit:$NoExit
}
