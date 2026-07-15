# P2 acceptance (spec Phases P2 / tracker T12): +split, +rename, +send-keys
# against a debug build. Non-interactive; exits nonzero on any failure.
# Only ever touches ghoztty processes running from the repo zig-out.
#
#   powershell -NoProfile -File test\win32\ipc-p2.ps1
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$tmp = Join-Path $env:TEMP "ghoztty-ipc-p2-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}
function Stop-DebugGhoztty {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        Where-Object { $_.CommandLine -like '*zig-out*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
}
function Get-List {
    cmd /c "`"$Exe`" +list > `"$tmp\list.txt`" 2>&1" | Out-Null
    Get-Content "$tmp\list.txt" -Raw
}
function Get-IdeJson {
    cmd /c "`"$Exe`" +list --json > `"$tmp\list.json`" 2>&1" | Out-Null
    $j = Get-Content "$tmp\list.json" -Raw | ConvertFrom-Json
    $j.data.windows | Where-Object { $_.target -eq 'p2ide' }
}

Stop-DebugGhoztty

"== 1: three-pane layout by name (CLAUDE.md example shape)"
& $Exe +new-window --target=p2ide 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $Exe +split --target=p2ide --name=p2term --direction=down 2>&1 | Out-Null
Assert "split 1 exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 1
& $Exe +split --target=p2ide --name=p2logs --direction=right 2>&1 | Out-Null
Assert "split 2 exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 2
$list = Get-List
Assert "p2term registered" ($list -match '\[name: p2term\]')
Assert "p2logs registered" ($list -match '\[name: p2logs\]')
$ide = Get-IdeJson
$ideText = $ide | ConvertTo-Json -Depth 15
Assert "3 leaves in p2ide" (([regex]::Matches($ideText, '"type":\s*"leaf"')).Count -eq 3)

"== 2: idempotent +split --name (no new pane)"
& $Exe +split --target=p2ide --name=p2term --direction=down 2>&1 | Out-Null
Assert "exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 1
$ideText = Get-IdeJson | ConvertTo-Json -Depth 15
Assert "still 3 leaves" (([regex]::Matches($ideText, '"type":\s*"leaf"')).Count -eq 3)

"== 3: +split --pane targeting"
& $Exe +split --pane=p2term --direction=right --name=p2deep --percent=30 2>&1 | Out-Null
Assert "exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 2
$ideText = Get-IdeJson | ConvertTo-Json -Depth 15
Assert "p2deep created" ($ideText -match 'p2deep')
Assert "percent ratio applied" ($ideText -match '0\.7')

"== 4: +send-keys executes (shell title change observable via +list)"
& $Exe +send-keys --target=p2term "title P2-SENT-OK" Enter 2>&1 | Out-Null
Assert "exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 2
Assert "command ran in pane" ((Get-List) -match 'P2-SENT-OK')

"== 5: +send-keys escapes (\n) and C-c accepted"
& $Exe +send-keys --target=p2term "title P2-ESCAPED\n" 2>&1 | Out-Null
Start-Sleep -Seconds 2
Assert "escape-run title" ((Get-List) -match 'P2-ESCAPED')
& $Exe +send-keys --target=p2term C-c 2>&1 | Out-Null
Assert "C-c exit 0" ($LASTEXITCODE -eq 0)

"== 6: +send-keys missing target errors"
& $Exe +send-keys --target=p2ghost "x" 2>&1 | Out-Null
Assert "nonzero exit" ($LASTEXITCODE -ne 0)

"== 7: +rename override wins over terminal titles"
& $Exe +rename --target=p2ide --title=P2-OVERRIDE 2>&1 | Out-Null
Assert "rename exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 1
# Debug builds append a " [DEBUG]" marker inside the quoted title.
Assert "window title is override" ((Get-List) -match 'Window: "P2-OVERRIDE( \[DEBUG\])?"')
& $Exe +send-keys --target=p2term "title P2-SHELL-FIGHTS\n" 2>&1 | Out-Null
Start-Sleep -Seconds 2
$list = Get-List
Assert "override still wins" ($list -match 'Window: "P2-OVERRIDE( \[DEBUG\])?"')
Assert "tab title tracks shell" ($list -match 'P2-SHELL-FIGHTS')

"== 8: +rename missing target errors"
& $Exe +rename --target=p2ghost --title=x 2>&1 | Out-Null
Assert "nonzero exit" ($LASTEXITCODE -ne 0)

"== teardown"
& $Exe +close --target=p2ide 2>&1 | Out-Null
Stop-DebugGhoztty
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

""
if ($script:failures -eq 0) {
    "P2 ACCEPTANCE: ALL PASS"
    exit 0
} else {
    "P2 ACCEPTANCE: $script:failures FAILURE(S)"
    exit 1
}
