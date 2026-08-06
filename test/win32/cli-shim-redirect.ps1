# T245 acceptance: ghoztty CLI output survives PowerShell '>' redirection.
#
# PowerShell keys its wait-and-redirect decision on the PE subsystem field:
# a GUI-subsystem ghoztty.exe under `> file` is launched without waiting and
# the pipeline is torn down instantly - 0 bytes, $LASTEXITCODE empty, silent.
# The fix is `ghoztty.com`, a console-subsystem TWIN of ghoztty.exe (same
# bytes, one PE header WORD flipped) installed next to it: PATHEXT resolves
# .COM before .EXE, so bare `ghoztty` from PowerShell or cmd finds the twin,
# waits for it, and wires redirection like for any console program (the
# devenv.com pattern). CLI verbs run IN the twin directly; a GUI launch
# through it respawns the sibling ghoztty.exe detached and exits, so a shell
# never blocks on the terminal it just launched. (A small relay shim was the
# first cut and Windows Defender quarantined it on sight - see
# src/cli/com_shim.zig for the whole story.)
#
# Covers:
#   1. ghoztty.com exists, is byte-sized like the exe, and its PE subsystem
#      field is console (3).
#   2. PS '>' redirect through the twin captures the verb's full output, and
#      the content matches a cmd.exe redirect of ghoztty.exe (the known-good
#      path). PS re-encodes native output (BOM/CRLF) for every console
#      program, so the compare is content-normalized, not byte-for-byte.
#   3. Exit codes: 0 for a passing verb, nonzero for a failing one, and
#      $LASTEXITCODE is actually set (it stayed EMPTY against the bare GUI
#      exe - that emptiness was T245's second symptom).
#   4. The task's literal repro shape from a child PowerShell process.
#   5. GUI mode (no +action) respawns the SIBLING ghoztty.exe detached with
#      the command-line tail passed through, and returns promptly with exit
#      0. Proven against a fake sibling (a cmd.exe copy) that drops a marker
#      file - which also proves the twin resolves the sibling from its OWN
#      directory, never from PATH, and never runs the GUI in-process.
#   6. Pipe capture through the twin is identical to pipe capture from the
#      exe directly.
#
# No instance is launched and no +new-window is sent; every verb used here
# answers without a server. Safe to run alongside a live session.
#
#   powershell -NoProfile -File test\win32\cli-shim-redirect.ps1
param(
    [string]$Com = 'D:\git\ghoztty\zig-out\bin\ghoztty.com',
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

. (Join-Path $PSScriptRoot 'lib\BuildMode.ps1')
Assert-GhozttyIsolatedBuild -Exe $Exe | Out-Null

if (-not (Test-Path $Com)) {
    "SETUP FAIL: $Com not found - the build did not produce the CLI twin"
    exit 1
}

# Isolate the IPC endpoint so no instance (the user's or a test's) answers;
# every verb below is exercised in its no-instance shape on purpose.
$env:GHOZTTY_PIPE_SUFFIX = '-t245shim'
$tmp = Join-Path $env:TEMP "ghoztty-cli-shim-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Get-NormalizedContent($path) {
    $raw = Get-Content $path -Raw -ErrorAction SilentlyContinue
    if ($null -eq $raw) { return '' }
    return $raw.Replace("`r`n", "`n").TrimEnd("`n")
}

function Get-PeSubsystem($path) {
    $b = [IO.File]::ReadAllBytes($path)
    $lfanew = [BitConverter]::ToUInt32($b, 0x3C)
    return [BitConverter]::ToUInt16($b, $lfanew + 4 + 20 + 68)
}

try {

"== 1: the twin exists with a console subsystem"
Assert "same size as ghoztty.exe" ((Get-Item $Com).Length -eq (Get-Item $Exe).Length)
Assert "PE subsystem is console (3)" ((Get-PeSubsystem $Com) -eq 3)

"== 2: PS '>' redirect through the twin captures the output"
& $Com +version > "$tmp\v-ps.txt" 2>&1
Assert "exit code is 0 and set" ($LASTEXITCODE -eq 0)
$psBytes = (Get-Item "$tmp\v-ps.txt" -ErrorAction SilentlyContinue).Length
Assert "redirected file is non-empty ($psBytes bytes)" ($psBytes -gt 0)
cmd /c "`"$Exe`" +version > `"$tmp\v-cmd.txt`" 2>&1"
$psTxt = Get-NormalizedContent "$tmp\v-ps.txt"
$cmdTxt = Get-NormalizedContent "$tmp\v-cmd.txt"
Assert "content matches the cmd.exe redirect of ghoztty.exe" (($psTxt.Length -gt 0) -and ($psTxt -eq $cmdTxt))
Assert "output is a +version document" ($psTxt -match 'build mode')

"== 3: exit codes propagate"
& $Com +version 2>&1 | Out-Null
Assert "passing verb exits 0" ($LASTEXITCODE -eq 0)
$listOut = & $Com +list 2>&1 | Out-String
Assert "failing verb (no instance) exits nonzero" ($LASTEXITCODE -ne 0)
Assert "failing verb's error text is visible" ($listOut.Trim().Length -gt 0)

"== 4: the literal T245 repro shape, from a child PowerShell"
$child = "& '$Com' +version > '$tmp\v-child.txt' 2>&1; if (`$null -eq `$LASTEXITCODE) { exit 99 }; exit `$LASTEXITCODE"
powershell -NoProfile -Command $child
Assert "child PS exits 0 (LASTEXITCODE was set)" ($LASTEXITCODE -eq 0)
Assert "child PS redirect captured output" ((Get-Item "$tmp\v-child.txt" -ErrorAction SilentlyContinue).Length -gt 0)

"== 5: GUI mode respawns the sibling detached (fake sibling)"
# The twin resolves ghoztty.exe from its own directory, so a copy of the
# twin next to a fake ghoztty.exe drives the fake - no real GUI launches.
# The fake is cmd.exe: the twin's GUI respawn hands it our tail verbatim,
# so `/c copy NUL <marker>` makes the DETACHED sibling drop a marker file -
# observable proof the sibling ran with the tail intact, from the twin's
# own directory, while the twin itself already returned.
Copy-Item $Com "$tmp\ghoztty.com" -Force
Copy-Item "$env:SystemRoot\System32\cmd.exe" "$tmp\ghoztty.exe" -Force
$marker = "$tmp\respawn-marker.txt"
$sw = [Diagnostics.Stopwatch]::StartNew()
& "$tmp\ghoztty.com" /c copy NUL $marker 2>&1 | Out-Null
$sw.Stop()
Assert "GUI-mode launch exits 0" ($LASTEXITCODE -eq 0)
Assert "GUI-mode launch returns promptly ($($sw.ElapsedMilliseconds)ms)" ($sw.ElapsedMilliseconds -lt 5000)
$seen = $false
foreach ($try in 1..30) {
    if (Test-Path $marker) { $seen = $true; break }
    Start-Sleep -Milliseconds 100
}
Assert "detached sibling ran with the tail passed through" $seen
# And a CLI verb through the copied twin answers in-process - the sibling
# (still fake) is never involved for actions.
$fakeDirOut = & "$tmp\ghoztty.com" +version 2>&1 | Out-String
Assert "CLI verb runs in the twin itself, not the sibling" (($LASTEXITCODE -eq 0) -and ($fakeDirOut -match 'Ghostty'))

"== 6: pipe capture through the twin matches the exe's"
$viaCom = & $Com +version 2>&1 | Out-String
$viaExe = & $Exe +version 2>&1 | Out-String
Assert "pipe output identical through the twin" ($viaCom -eq $viaExe)

} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    Remove-Item Env:\GHOZTTY_PIPE_SUFFIX -ErrorAction SilentlyContinue
}

""
if ($script:failures -eq 0) {
    "T245 ACCEPTANCE: ALL PASS"
    exit 0
} else {
    "T245 ACCEPTANCE: $script:failures FAILURE(S)"
    exit 1
}
