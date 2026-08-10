# T229 acceptance: the shared ghoztty.log must not LOSE lines under concurrent
# writers.
#
# %LOCALAPPDATA%\ghoztty\ghoztty.log is a single sink that the GUI app, the
# agent and every one-shot `ghoztty +...` CLI invocation append to at the same
# time - on a box driving Ghoztty from scripts there are several a second. The
# old writer opened the file, seeked to end, wrote and closed. That is not an
# append: two processes that both resolve end-of-file to N both write AT N, and
# the later write silently overwrites the earlier one's bytes.
#
# Why this is a T229 assertion and not a tidy-up: the whole primary evidence for
# T229 was "the app logged nothing after the confirm", and the fix for it is a
# trail of log lines through the destructive restart. Both are worthless if the
# sink drops lines whenever something else is running. The fix is
# FILE_APPEND_DATA (main_ghostty.zig openAppendW), which Windows defines as
# placing each write at the current end of file as one operation.
#
# The oracle is line COUNT and line SHAPE, measured on the real binary:
#   - every launched process contributes its startup banner, so the total is
#     deterministic per build;
#   - a clobbered line is detectable without knowing the count: the writer only
#     ever emits lines starting with a log level, so a line that does not is a
#     line something wrote over.
#
# Release build only - the file sink is compiled out of Debug builds (they log
# to stderr). Hermetic: its own LOCALAPPDATA and IPC pipe suffix, and it only
# runs `+list`, which touches nothing.
#
#   powershell -NoProfile -File test\win32\log-append.ps1
#   powershell -NoProfile -File test\win32\log-append.ps1 -Exe <pre-fix exe>   # negative control
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out-release\bin\ghoztty.exe',
    [int]$Writers = 24,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:passes = 0
function Assert($name, $cond) {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:failures++ }
}
function Say($m) { Write-Host $m }

$root = Join-Path $env:TEMP "ghoztty-log-append-$PID"
$saved = @{ lad = $env:LOCALAPPDATA; pipe = $env:GHOZTTY_PIPE_SUFFIX }
New-Item -ItemType Directory -Force (Join-Path $root 'ghoztty') | Out-Null
$env:LOCALAPPDATA = $root
# No server answers this suffix, so every +list fails fast and exits - the point
# is the startup banner each one writes on its way through.
$env:GHOZTTY_PIPE_SUFFIX = '-logappend'
$logPath = Join-Path $root 'ghoztty\ghoztty.log'

try {

Assert "setup: exe exists" (Test-Path $Exe)

# One warm-up run alone: its line count IS the per-process contribution, so the
# expected total is derived from the binary under test rather than hard-coded
# (a build that changes its banner must not silently turn this into a no-op).
# persistence: n/a - a CLI invocation, which opens no window.
$p = Start-Process -FilePath $Exe -ArgumentList @('+list') -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $root 'warm.out') -RedirectStandardError (Join-Path $root 'warm.err')
$null = $p.Handle
$p.WaitForExit(20000) | Out-Null
Assert "premise: the release build writes to ghoztty.log at all" (Test-Path $logPath)
$perProc = @(Get-Content $logPath).Count
Say "    one process writes $perProc line(s)"
Assert "premise: a run contributes at least a few lines" ($perProc -ge 3)

Remove-Item $logPath -Force -ErrorAction SilentlyContinue

# All writers at once. Start-Process returns immediately, so they overlap.
$procs = @()
for ($i = 0; $i -lt $Writers; $i++) {
    # persistence: n/a - a CLI invocation, which opens no window.
    $procs += Start-Process -FilePath $Exe -ArgumentList @('+list') -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $root "w$i.out") -RedirectStandardError (Join-Path $root "w$i.err")
}
foreach ($q in $procs) { $null = $q.Handle }
foreach ($q in $procs) { $q.WaitForExit(60000) | Out-Null }
Start-Sleep -Milliseconds 500

$lines = @(Get-Content $logPath)
$expected = $perProc * $Writers
Say "    $Writers concurrent writers => $($lines.Count) line(s), expected $expected"

# Every line this binary emits starts with a std.log level. Anything else is a
# line that was written over - detectable with no knowledge of the expected
# count, which is what makes this a shape assertion and not just arithmetic.
$malformed = @($lines | Where-Object { $_ -notmatch '^(debug|info|warning|error)' })
if ($malformed.Count -gt 0) {
    Say "    first malformed line: '$($malformed[0])'"
}

if ($NegativeControl) {
    Say 'NEGATIVE CONTROL: asserting the sink LOSES lines - a fixed build MUST fail this'
    Assert "N1 concurrent writers lose lines (inverted)" ($lines.Count -lt $expected)
} else {
    Assert "L1 no line was lost under $Writers concurrent writers" ($lines.Count -eq $expected)
    Assert "L2 no line was written over (every line starts with a log level)" ($malformed.Count -eq 0)
}

} finally {
    $env:LOCALAPPDATA = $saved.lad
    $env:GHOZTTY_PIPE_SUFFIX = $saved.pipe
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

Say ""
if ($script:failures -eq 0) { Say "LOG-APPEND: ALL PASS ($script:passes)"; exit 0 }
else { Say "LOG-APPEND: $script:failures FAILURE(S) / $script:passes passed"; exit 1 }
