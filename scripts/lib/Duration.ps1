# Duration.ps1 - one human-readable duration, formatted the same way everywhere.
#
# It is its own file for one reason: `[int]$ts.TotalMinutes` ROUNDS. .NET's
# double-to-int conversion is round-to-nearest, not truncation, so 116.2 seconds
# formatted as "$([int]$ts.TotalMinutes)m $($ts.Seconds)s" prints **2m 56s** - a
# number that is wrong by a minute, in the direction that flatters nothing and
# reads as perfectly plausible. It was printed against a real suite run before
# anybody compared it with the recorded seconds beside it.
#
# A duration nobody can check is exactly the kind of number a test-suite report
# must not contain, so the formatter lives where a test can call it:
#
#     . (Join-Path $PSScriptRoot 'lib\Duration.ps1')
#     Format-Duration 116.2      # -> 1m 56s

function Format-Duration {
    param([double]$Seconds)

    if ($Seconds -lt 0) { $Seconds = 0 }
    $ts = [TimeSpan]::FromSeconds($Seconds)
    if ($ts.TotalHours -ge 1) {
        return ('{0}h {1:00}m {2:00}s' -f [math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds)
    }
    if ($ts.TotalMinutes -ge 1) {
        return ('{0}m {1:00}s' -f [math]::Floor($ts.TotalMinutes), $ts.Seconds)
    }
    return ('{0:0.0}s' -f $ts.TotalSeconds)
}
