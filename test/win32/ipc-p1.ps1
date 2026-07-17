# P1 acceptance (spec Phases P1 / tracker T08): +new-window, +list, +close
# against a debug build. Non-interactive; asserts and exits nonzero on any
# failure. Only ever touches ghoztty processes running from the repo zig-out.
#
#   powershell -NoProfile -File test\win32\ipc-p1.ps1
#
# Covers: auto-launch from cold, named-window create, list shape (human +
# json), idempotent focus (no duplicate), inline split + named pane,
# -e direct exec, close pane / close window / close missing, second-instance
# forwarding.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$tmp = Join-Path $env:TEMP "ghoztty-ipc-p1-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}

function Stop-DebugGhoztty {
    Get-CimInstance Win32_Process -Filter "Name='ghoztty.exe'" |
        # Exact exe match only — '*zig-out*' also matched a detached soak
        # instance running from zig-out-release (T53b) and killed it.
        Where-Object { $_.ExecutablePath -eq $Exe } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
}

function Get-List {
    # Route through cmd redirection: PowerShell's own capture can interleave
    # and drop native stdout lines.
    cmd /c "`"$Exe`" +list > `"$tmp\list.txt`" 2>&1" | Out-Null
    Get-Content "$tmp\list.txt" -Raw
}

Stop-DebugGhoztty

"== 1: +new-window auto-launch from cold, all basic flags"
& $Exe +new-window --target=p1win --title=P1Title "--command=echo p1-marker" 2>&1 | Out-Null
Assert "exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 2
$list = Get-List
Assert "window registered under target" ($list -match '\[target: p1win\]')
Assert "title override shows" ($list -match 'P1Title')

"== 2: idempotent re-create focuses, no duplicate"
& $Exe +new-window --target=p1win 2>&1 | Out-Null
Assert "exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 1
$list = Get-List
Assert "still exactly one p1win" (([regex]::Matches($list, '\[target: p1win\]')).Count -eq 1)

"== 3: inline split + named pane + explicit cwd"
& $Exe +new-window --target=p1ide --split=down "--split-command=echo split-pane" --name=p1term --working-directory=C:\Windows 2>&1 | Out-Null
Assert "exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 2
$list = Get-List
Assert "second window registered" ($list -match '\[target: p1ide\]')
Assert "named pane registered" ($list -match '\[name: p1term\]')
Assert "cwd honored" ($list -match [regex]::Escape('C:\Windows'))

"== 4: -e direct exec"
& $Exe +new-window --target=p1exec -e cmd /K echo p1-direct 2>&1 | Out-Null
Assert "exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 2
$list = Get-List
Assert "exec window registered" ($list -match '\[target: p1exec\]')

"== 5: json shape"
cmd /c "`"$Exe`" +list --json > `"$tmp\list.json`" 2>&1" | Out-Null
$json = $null
try { $json = Get-Content "$tmp\list.json" -Raw | ConvertFrom-Json } catch {}
Assert "json parses" ($null -ne $json)
Assert "success true" ($json.success -eq $true)
Assert "windows array present" ($null -ne $json.data.windows)
$p1ide = $json.data.windows | Where-Object { $_.target -eq 'p1ide' }
Assert "split node shape" ($p1ide.tabs[0].splits.type -eq 'split' -and
    $p1ide.tabs[0].splits.left.type -eq 'leaf' -and
    $null -ne $p1ide.tabs[0].splits.ratio)

"== 6: +close named pane"
& $Exe +close --target=p1term 2>&1 | Out-Null
Assert "exit 0" ($LASTEXITCODE -eq 0)
Start-Sleep -Seconds 1
$list = Get-List
Assert "pane gone" (-not ($list -match '\[name: p1term\]'))
Assert "window still there" ($list -match '\[target: p1ide\]')

"== 7: +close windows"
& $Exe +close --target=p1ide 2>&1 | Out-Null
Assert "close window exit 0" ($LASTEXITCODE -eq 0)
& $Exe +close --target=p1exec 2>&1 | Out-Null
Start-Sleep -Seconds 1
$list = Get-List
Assert "p1ide gone" (-not ($list -match '\[target: p1ide\]'))

"== 8: +close missing target is silent success"
& $Exe +close --target=does-not-exist 2>&1 | Out-Null
Assert "exit 0" ($LASTEXITCODE -eq 0)

"== 9: second GUI launch forwards new-window and exits"
$before = ([regex]::Matches((Get-List), '(?m)^Window:')).Count
$second = Start-Process $Exe -PassThru
$exited = $second.WaitForExit(15000)
Assert "second instance exited" $exited
if ($exited) { Assert "exit code 0" ($second.ExitCode -eq 0) }
Start-Sleep -Seconds 2
$after = ([regex]::Matches((Get-List), '(?m)^Window:')).Count
Assert "window count grew" ($after -eq ($before + 1))

"== teardown"
Stop-DebugGhoztty
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

""
if ($script:failures -eq 0) {
    "P1 ACCEPTANCE: ALL PASS"
    exit 0
} else {
    "P1 ACCEPTANCE: $script:failures FAILURE(S)"
    exit 1
}
