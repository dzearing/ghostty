<#
.SYNOPSIS
  Acceptance test for scripts\lib\CommitHeadroom.ps1 and floor-lane.ps1's
  commit preflight (T453).

.DESCRIPTION
  A lane launched with no system commit left does not report "out of memory".
  It dies somewhere in the middle in a zig.exe access violation, which reads
  exactly like broken code -- T449 spent a whole task on that shape before
  measuring commit and clearing it. The preflight exists so the run says which
  it was, and the rule it must never break is that an UNREADABLE number is not
  a bad one: a gate that cannot measure must not refuse.

  Arms 1-8 drive the pure library across every band (ok / warn / fail /
  unknown) and check that a refusal always names a way out. Arms 9-11 are the
  wiring: an impossible commit floor refuses before any lane launches, the
  refusal reads as a preflight rather than a red lane, and the default floor
  lets a real run through on this box.

  Prints a single ALL PASS / N FAILURE(S) line, like every other script here.

  ASCII-only by design (PS 5.1 on this box mangles non-ASCII on rewrite).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $RepoRoot 'scripts\lib\CommitHeadroom.ps1')
. (Join-Path $PSScriptRoot 'lib\TestScore.ps1')

$script:Failures = 0
$script:Passes = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host ("PASS  {0}" -f $Name); $script:Passes++ }
    else {
        Write-Host ("FAIL  {0}{1}" -f $Name, $(if ($Detail) { " - $Detail" } else { '' }))
        $script:Failures++
    }
}

# ---- arms 1-8: the pure verdict ------------------------------------------

# The box as T453 found it on 2026-09-04: a 139.7 GB limit with 33.1 GB in use.
$ok = Get-CommitHeadroomState -CommittedGB 33.1 -LimitGB 139.7
Check '1 a box with 106 GB free is ok' ($ok.Verdict -eq 'ok') ($ok | Out-String)
Check '2 the free number is the limit minus what is committed' ($ok.FreeGB -eq 106.6) ($ok.FreeGB)

# The box as T449 measured it at its worst: 49.4 GB peak against a 67.7 GB
# limit. 18 GB of headroom -- tight enough to name, not tight enough to refuse.
$warn = Get-CommitHeadroomState -CommittedGB 49.4 -LimitGB 67.7
Check '3 T449 worst measured moment warns and does not refuse' ($warn.Verdict -eq 'warn') ($warn | Out-String)
Check '4 the warning names the lane draw it is close to' ($warn.Reason -match '16 GB') $warn.Reason

$fail = Get-CommitHeadroomState -CommittedGB 64 -LimitGB 67.7
Check '5 under the floor refuses' ($fail.Verdict -eq 'fail') ($fail | Out-String)
Check '6 the refusal says a lane cannot complete' ($fail.Reason -match 'cannot complete') $fail.Reason

# The T1133 rule from the other side: a gate that cannot measure must not
# pretend it did. An unreadable counter is 'unknown', and unknown never refuses.
$unknown = Get-CommitHeadroomState -CommittedGB $null -LimitGB $null
Check '7 an unreadable counter is unknown, never a refusal' ($unknown.Verdict -eq 'unknown') ($unknown | Out-String)

# Every refusal names a way out -- the T1054 precedent: the message that
# refuses is also the message that fixes it. A small page file beside a large
# limit is the T453 condition itself, so it is named when it holds.
$advice = @(Get-CommitHeadroomAdvice -Verdict 'fail' -PageFileGB 4 -LimitGB 67.7)
Check '8 a refusal names a remedy, the small page file among them' `
    ($advice.Count -ge 2 -and ($advice -join ' ') -match 'page file is 4 GB') ($advice -join ' | ')
$noAdvice = @(Get-CommitHeadroomAdvice -Verdict 'ok' -PageFileGB 4 -LimitGB 67.7)
Check '8b an ok verdict prints no remedy' ($noAdvice.Count -eq 0) ($noAdvice -join ' | ')
# A page file that is already proportionate is not mentioned (the box after
# T453's measurement: 76 GB behind a 139.7 GB limit).
$bigPf = @(Get-CommitHeadroomAdvice -Verdict 'warn' -PageFileGB 76 -LimitGB 139.7)
Check '8c a proportionate page file is not named as a remedy' `
    (($bigPf -join ' ') -notmatch 'page file') ($bigPf -join ' | ')

# ---- arms 9-11: the wiring ------------------------------------------------

$floor = Join-Path $RepoRoot 'scripts\floor-lane.ps1'

# The negative control: an impossible commit floor makes the gate fire on a
# healthy box, which is the demonstration that it CAN say something other than
# "fine" (T1133). -MinFreeGB 0 keeps the disk gate out of the way so the
# refusal under test is unambiguously this one.
$out = (& powershell -NoProfile -ExecutionPolicy Bypass -File $floor `
        -Lane lib -MinFreeGB 0 -MinCommitFreeGB 9999999 2>&1 |
    ForEach-Object { $_.ToString() }) -join "`n"
$code = $LASTEXITCODE
Check '9 an impossible commit floor refuses the run' ($out -match 'FLOOR PREFLIGHT FAIL: less than 9999999 GB') $out
Check '10 the refusal is a preflight verdict, not a red lane' `
    (($out -match 'preflight=FAIL') -and ($out -notmatch 'LANE lib') -and $code -eq 1) "exit=$code`n$out"
Check '10b the refusal reports the measured number it refused on' ($out -match 'COMMIT: only .* GB of commit free') $out

# And the default floor lets a real run through on this box -- the other half
# of a gate that can fail is that it does not fail when it should not. The lib
# lane is the cheapest thing here (a compile, seconds cached).
$out2 = (& powershell -NoProfile -ExecutionPolicy Bypass -File $floor -Lane lib 2>&1 |
    ForEach-Object { $_.ToString() }) -join "`n"
Check '11 the default commit floor does not refuse a healthy box' `
    ($out2 -notmatch 'FLOOR PREFLIGHT FAIL') $out2

Complete-TestBody  # T1039: the run reached the end of its body

if ($script:Failures -eq 0) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\guard-due.ps1') `
        update -Guard lane-commit-headroom -Repo $RepoRoot 2>&1 | ForEach-Object { "  $_" }
}

Write-Host ''
Write-TestVerdict -Pass $script:Passes -Fail $script:Failures
