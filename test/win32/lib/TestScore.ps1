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

# ---------------------------------------------------------------------------
# T1039 - and a run that DID NOT FINISH is not a pass either.
#
# The shape this exists for, measured in T329 on
# `test\win32\activity-monitor-dialed.ps1`: `Get-Content -Raw` answers $null for
# an empty file and `$null.Trim()` is a statement-terminating error. It landed at
# the top of the script's last section, inside the top-level
#
#     try { ...the whole run... } finally { ...cleanup... }
#
# which has NO catch. Under `$ErrorActionPreference = 'Continue'` such an error
# unwinds the try, runs the finally, and then falls through to the statements
# AFTER it with the failure count still 0 - so the script stamped its guard and
# printed `ALL PASS (27 assertions)` over a section that had measured nothing.
# 95 of the 155 scripts in `test\win32` were in exactly that shape, so fixing
# the one script it was found in fixes nothing.
#
# THE RULE:
#
#     A pass verdict must be backed by a run that REACHED THE END OF ITS BODY.
#     A scorer about to announce ALL PASS over a body that unwound must say so
#     and exit nonzero.
#
# The marker, in the two lines a script spends on it:
#
#     . (Join-Path $PSScriptRoot 'lib\TestScore.ps1')   # arms the run
#     try {
#         ...sections...
#         Complete-TestBody                              # the LAST statement
#     } finally { ...cleanup... }
#     Write-TestVerdict -Pass $script:pass -Fail $script:fail
#
# Arming is the dot-source itself rather than a call the script must remember:
# a script that forgets to arm is exactly the script with the bug, and a rule
# that only protects those who opted in protects nobody. The placement is what
# gives the marker its meaning - as the last statement of the try body it is
# skipped by any unwind, and reaching it proves every statement before it ran.
# `lib\BodyCompleteAudit.ps1` is the static half that enforces the placement
# across the suite (every top-level `try` either scores its own throw in a
# `catch` or ends in `Complete-TestBody`).
#
#   * exit 2 - `RUN DID NOT FINISH (...)` - same news, and the same code, as
#     ASSERTED NOTHING: the run is UNMEASURED past the point it unwound, which
#     is a statement about the harness rather than about the product. A script
#     that would rather call a throw a product failure keeps doing what T329's
#     `catch` arm does - score it as a FAILURE - and lands on exit 1; both are
#     red, and neither is the green this rule exists to refuse.
#
# THE STAMP is the half that outlives the run, and it is gated in the same
# breath: `Complete-TestBody` publishes the state into the environment as
# `GHOZTTY_TEST_BODY` (`pending` while armed, `complete` once reached), and
# `scripts\guard-due.ps1 update` - a CHILD PROCESS of the harness, which
# inherits it - refuses to write a stamp while it reads `pending`. Without that,
# an unwound run still records every file it covers as freshly proven and the
# guard stops asking, which is the damage that outlasts the red line.
#
# What this deliberately does not do: a script that runs ANOTHER scored script
# in-process (`& .\other.ps1`) inherits that script's completion, since the
# state is per-process. Every acceptance script in this suite is its own
# process, which is what makes the simple state honest here.
# ---------------------------------------------------------------------------

# Deliberately sets no StrictMode: this file is dot-sourced INTO suite scripts,
# and a mode set here would silently change how every one of them evaluates.

function Reset-TestBody {
    <#
      Arm the run: its body has not reached its end yet. Called once by
      the dot-source below, and by this rule's own acceptance script when it
      needs to re-arm inside one process.
    #>
    $global:GhozttyTestBody = [pscustomobject]@{ Armed = $true; Complete = $false }
    $env:GHOZTTY_TEST_BODY = 'pending'
}

function Complete-TestBody {
    <#
      The run reached the end of its body. The LAST statement of the top-level
      try, so that an unwind cannot reach it.
    #>
    if ($null -eq $global:GhozttyTestBody) { Reset-TestBody }
    $global:GhozttyTestBody.Complete = $true
    $env:GHOZTTY_TEST_BODY = 'complete'
}

function Test-TestBodyComplete {
    # Unarmed answers TRUE: nothing was claimed, so nothing is being broken.
    # Only the dot-source above arms, so in this suite that is a caller which
    # reached the scorer without loading it - impossible by construction.
    if ($null -eq $global:GhozttyTestBody) { return $true }
    if (-not $global:GhozttyTestBody.Armed) { return $true }
    return [bool]$global:GhozttyTestBody.Complete
}

function Get-TestVerdictLine {
    <#
      The verdict as a STRING, with no side effects, so the acceptance script
      can assert the wording without spawning a process and so a caller that
      wants to tee/log it can. `Write-TestVerdict` is this plus printing and
      exiting; the decision itself lives here, once.

      Returns an object: Line (what to print), Code (what to exit with),
      Kind ('pass' | 'fail' | 'incomplete' | 'nothing' | 'too-little').

      `-Incomplete` is the T1039 half: the run unwound before the end of its
      body. It is a PARAMETER rather than a read of the marker so this function
      stays pure and its wording testable without arming anything;
      `Write-TestVerdict` is what reads the marker.
    #>
    param(
        [int]$Pass,
        [int]$Fail,
        [int]$Skipped = 0,
        [string]$Label,
        [string]$Unit = 'assertions',
        [int]$MinPass = 1,
        [switch]$Incomplete
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

    # Last of the non-green arms on purpose: this one only ever fires over a
    # verdict that would otherwise be GREEN, which is the whole rule ("a pass
    # must be backed by a run that finished"). Putting it earlier would rewrite
    # the wording of the deliberate early exits - a failed precondition scored
    # by `Write-TestAssertedNothing` has not reached the end of its body either,
    # and ASSERTED NOTHING is the honest name for that one, not an unwind.
    if ($Incomplete) {
        return [pscustomobject]@{
            Kind = 'incomplete'
            Code = 2
            Line = "${prefix}RUN DID NOT FINISH ($Pass $Unit passed$skipNote) - the body unwound before its end; everything past that point is unmeasured, so this is not a pass"
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
        -Label $Label -Unit $Unit -MinPass $MinPass `
        -Incomplete:(-not (Test-TestBodyComplete))

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

# Arm the run (T1039). The dot-source IS the arming, so there is no second
# thing for a script to remember and no opt-in for the script with the bug to
# have missed. Already-armed is left alone: a library dot-sourcing this file a
# second time inside one process must not un-finish a body that has finished.
if ($null -eq $global:GhozttyTestBody) { Reset-TestBody }
