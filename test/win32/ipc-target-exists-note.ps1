# T135 acceptance: `+new-window --target=<name>` against an EXISTING target
# focuses it (idempotent, exit 0) but must no longer be silent about the
# flags it drops: the server replies outcome=focused plus a note naming the
# ignored flags, and the CLI prints that note to stderr. The CLI's own
# auto-inserted cwd (marked --cwd-implicit) must NOT trigger the note.
#
#   powershell -NoProfile -File test\win32\ipc-target-exists-note.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$tmp = Join-Path $env:TEMP "ghoztty-t135-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')
. (Join-Path $PSScriptRoot 'lib\Isolation.ps1')
[void](Set-GhozttyTestIsolation -Tag 't135')

function Stop-DebugGhoztty {
    Reset-GhozttyTestState -Exe $Exe -SettleMs 1000 | Out-Null
}

# Run one CLI call with stdout/stderr split into files; returns the exit code.
function Invoke-Cli([string]$CliArgs) {
    cmd /c "`"$Exe`" $CliArgs > `"$tmp\out.txt`" 2> `"$tmp\err.txt`"" | Out-Null
    return $LASTEXITCODE
}
function Get-CliErr { (Get-Content "$tmp\err.txt" -Raw -ErrorAction SilentlyContinue) }

function Get-List {
    cmd /c "`"$Exe`" +list > `"$tmp\list.txt`" 2>&1" | Out-Null
    Get-Content "$tmp\list.txt" -Raw
}
function Wait-ListMatch([string]$Pattern, [int]$TimeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $l = Get-List
        if ($l -match $Pattern) { return $l }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $l
}

$transcript = Join-Path $env:TEMP 'ghoztty-t135-last.log'

& {

Stop-DebugGhoztty
Assert-GhozttyPrivateEndpoint -Exe $Exe

"== 1: fresh create is quiet"
$code = Invoke-Cli "+new-window --target=t135win"
Assert "create exit 0" ($code -eq 0)
[void](Wait-ListMatch '\[target: t135win\]')
Assert "no note on create" ([string]::IsNullOrWhiteSpace((Get-CliErr)))

"== 2: focus with create-only flags prints the note, exit stays 0"
$code = Invoke-Cli "+new-window --target=t135win --working-directory=$env:TEMP --command=whoami"
Assert "focus exit 0" ($code -eq 0)
$err = Get-CliErr
Assert "note names the target" ($err -match "target 't135win' already exists")
Assert "note names --command" ($err -match '--command')
Assert "note names --working-directory" ($err -match '--working-directory')
Assert "note suggests +close" ($err -match '\+close')
# The request must have been a focus, not a create: still exactly one window
# with that target name in the list.
$list = Get-List
Assert "still one t135win" (([regex]::Matches($list, '\[target: t135win\]')).Count -eq 1)

"== 3: bare re-focus stays silent (implicit cwd never counts)"
$code = Invoke-Cli "+new-window --target=t135win"
Assert "bare focus exit 0" ($code -eq 0)
Assert "no note on bare focus" ([string]::IsNullOrWhiteSpace((Get-CliErr)))

"== 4: explicit --working-directory alone still warns"
$code = Invoke-Cli "+new-window --target=t135win --working-directory=$env:TEMP"
Assert "explicit-cwd focus exit 0" ($code -eq 0)
$err = Get-CliErr
Assert "note names --working-directory only" (($err -match '--working-directory') -and ($err -notmatch '--command'))

"== teardown"
Invoke-Cli "+close --target=t135win" | Out-Null
Stop-DebugGhoztty
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

} 2>&1 | Tee-Object -FilePath $transcript

""
if ($script:failures -eq 0) {
    "T135 ACCEPTANCE: ALL PASS"
    exit 0
} else {
    $trailer = "T135 ACCEPTANCE: $script:failures FAILURE(S) - details: $transcript"
    Add-Content $transcript $trailer
    $trailer
    exit 1
}
