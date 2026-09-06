# T41 acceptance: the close confirmation is skipped when the pane's shell is
# IDLE, and still shown when something is running under it.
#
# Why the product change exists: the core decides "a process is still running"
# from `cursorIsAtPrompt`, which is fed by the shell's OSC 133 semantic prompt
# marks. cmd.exe and stock PowerShell emit none, so on Windows the answer was
# ALWAYS "running" - closing a tab that was just cmd.exe sitting at a prompt
# asked for confirmation every time. The Windows-native tiebreaker is the
# process table: a shell with no descendants has nothing to lose.
#
# Both backends are covered, because the user runs the one this script would
# otherwise miss:
#
#   Section A - session-persistence OFF: the pane's shell is a direct child of
#     ghoztty.exe (the `exec` termio backend).
#   Section B - session-persistence ON (the DEFAULT): the shell runs under
#     ghoztty-agent.exe and the app only knows the pid the agent reports (the
#     `remote` backend, local connection). A fix that only handles `exec`
#     leaves every real user pane confirming.
#   Section C - a CROSS-MACHINE pane, dialed over TCP to a listening
#     ghoztty-agent. Here the app has no pid it may walk at all: the shell's pid
#     indexes the far machine's process table, so `Surface.shellPid` returns 0 by
#     design. The BUSY answer comes from the machine that owns the process
#     (T356): the agent samples its own table each second and pushes
#     `META{has_descendants}` on change, which the app reads synchronously at
#     close time. The agent here listens on loopback, so the same Win32_Process
#     oracle still works.
#
#     Its IDLE case is the one T1390 reversed. An idle cross-machine pane used
#     to close with no dialog, like an idle local one; it now confirms, because
#     ending a process on another machine is not the recoverable thing an idle
#     local shell is - and the confirmation offers Disconnect. Section A is the
#     discriminator: the same chord on a LOCAL idle pane still closes silently.
#
#   Section D - `confirm-close-surface = always` (T357). The user asked for a
#     confirmation unconditionally, so the shell's state is not a question we
#     get to ask: `Surface.shellIsIdle` answers FALSE on that config before it
#     ever looks at the process table, and an IDLE shell must still confirm.
#   Section E - a READ-ONLY surface (T357). Same shape, different forced
#     branch: a pane the user has marked read-only confirms whatever the
#     process table says.
#
# Sections A-C prove a dialog can be ABSENT; D and E prove it is still there
# where it was never the shell's call. That pairing is the point: until T41
# every close confirmed, so a regression in the forced branches was invisible,
# and now the absence of a dialog is a normal outcome - a bug that suppressed
# `always` or read-only would look exactly like the feature working.
#
# Sections A-C run the same two cases in ONE window, busy first:
#
#   1. BUSY (`ping -n 100 127.0.0.1` running) + ctrl+w -> the confirm dialog
#      appears. This is also the POSITIVE CONTROL for case 2: it proves the
#      chord reaches the app in this window, so "no dialog" below cannot be
#      "no keystroke". Escape cancels it.
#   2. IDLE (ping stopped, shell back at its prompt) + the SAME chord -> no
#      dialog, and the window actually closes. Both halves are asserted: a
#      swallowed chord also produces no dialog.
#
# Independent oracle for the busy/idle state itself: the shell's descendants
# read straight out of Win32_Process, never from anything the app says. The
# pane's shell pid comes from `ghoztty +list --json`, and is asserted to name a
# LIVE process - on Windows the agent used to report the child's HANDLE value
# there, a number that is a pid in no process at all.
#
# Each section also runs `+list --pid=<a process inside the pane>`, the same
# shell pid read back through its other consumer (this is how a process finds
# its own pane, e.g. /reset-context) - it has no other on-box coverage.
#
# -NegativeControl inverts case 2's verdict (asserts the idle close DOES
# confirm), so a passing run proves the script discriminates.
#
# T217/T218: runs on a BACKGROUND Win32 desktop (test/win32/lib/TestDesktop.ps1)
# and never takes the user's foreground.
# T267: sets its own window size rather than inheriting whatever the last GUI
# script left in window_placement-debug.
#
#   powershell -NoProfile -File test\win32\close-confirm-idle.ps1
#
# Only touches ghoztty processes running from this repo's zig-out.
param(
    [string]$Exe = 'D:\git\ghoztty\zig-out\bin\ghoztty.exe',
    [string]$AgentExe = '',
    [int]$Port = 47741,
    [switch]$NegativeControl,
    [switch]$Interactive
)

# T351: the shared reset/kill helpers (Stop-RepoGhoztty). Dot-sourced HERE, ahead
# of any isolation setup, because it drops an inherited $GHOZTTY_IPC_SOCKET - a
# test never wants the caller pane's endpoint.
. (Join-Path $PSScriptRoot 'lib\CleanSlate.ps1')

$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo 'zig-out\bin\ghoztty.exe' }
if (-not (Test-Path $Exe)) { Write-Host "SETUP FAIL: no exe at $Exe"; exit 1 }
if (-not $AgentExe) { $AgentExe = Join-Path (Split-Path $Exe -Parent) 'ghoztty-agent.exe' }

# Isolate the IPC endpoint (inherited through CreateProcessW) so a stray
# instance on the shared pipe cannot answer our +list.
$env:GHOZTTY_PIPE_SUFFIX = "-t41$PID"

. (Join-Path $PSScriptRoot 'lib\TestDesktop.ps1')

$script:pass = 0
$script:fail = 0
function Assert($cond, $name) {
    if ($cond) { Write-Host "  PASS $name"; $script:pass++ }
    else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fail++ }
}

function Stop-RepoProcesses([string[]]$Names) {
    # T351: the ghoztty halves go through the one shared, path-exact kill
    # (lib\CleanSlate.ps1) - every private copy answered "does the agent go too"
    # alone. Anything else in $Names is this script's own litter, so it stays local.
    if ($Names -contains 'ghoztty') {
        [void](Stop-RepoGhoztty -Exe $Exe -AppOnly:(-not ($Names -contains 'ghoztty-agent')) -SettleMs 0)
    }
    foreach ($name in ($Names | Where-Object { $_ -notin @('ghoztty', 'ghoztty-agent') })) {
        Get-CimInstance Win32_Process -Filter "Name='$name.exe'" | ForEach-Object {
            if ($_.ExecutablePath -and $_.ExecutablePath.StartsWith((Join-Path $repo 'zig-out'), 'OrdinalIgnoreCase')) {
                try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}
            }
        }
    }
    Start-Sleep -Milliseconds 600
}

function Reset-AgentState {
    $dir = Join-Path $env:LOCALAPPDATA 'ghoztty\local-agent-debug'
    foreach ($f in @('sessions.json', 'port.json')) {
        Remove-Item (Join-Path $dir $f) -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path $dir 'rings') -Recurse -Force -ErrorAction SilentlyContinue
    # A restored layout would hand this run the previous run's panes.
    Remove-Item (Join-Path $env:LOCALAPPDATA 'ghoztty\session-layout-debug.json') -ErrorAction SilentlyContinue
}

# Every live descendant pid of $Root, from the OS process table.
function Get-DescendantPids([int]$Root) {
    $all = Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name
    $byParent = @{}
    foreach ($p in $all) {
        $key = [int]$p.ParentProcessId
        if (-not $byParent.ContainsKey($key)) { $byParent[$key] = @() }
        $byParent[$key] += $p
    }
    $out = @()
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($Root)
    $seen = @{}
    while ($queue.Count -gt 0) {
        $cur = [int]$queue.Dequeue()
        if ($seen.ContainsKey($cur)) { continue }
        $seen[$cur] = $true
        foreach ($child in $byParent[$cur]) {
            $out += $child
            $queue.Enqueue([int]$child.ProcessId)
        }
    }
    return $out
}

# Every PTY HOLDER process this repo's build has running (T905/T909): the
# per-session `ghoztty-agent.exe --pty-host` that owns the ConPTY, the shell and
# its kill-on-close job. It is spawned to ESCAPE the agent's job, so depending on
# which escape tier won it may not be an agent descendant at all - which is why
# it is found by command line rather than by walking down from the agent.
function Get-PtyHolderPids {
    $out = @()
    $zigOut = Join-Path $repo 'zig-out'
    foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='ghoztty-agent.exe'" -ErrorAction SilentlyContinue)) {
        if (-not $p.ExecutablePath) { continue }
        if (-not $p.ExecutablePath.StartsWith($zigOut, 'OrdinalIgnoreCase')) { continue }
        if ($p.CommandLine -and $p.CommandLine -match '--pty-host') { $out += [int]$p.ProcessId }
    }
    # Plain `return`, never `return ,$out`: the comma form wraps an EMPTY array
    # in a one-element array, so `@(Get-PtyHolderPids)` would count 1 holder
    # when there are none.
    return $out
}

function Wait-Descendants([int]$Root, [bool]$Want, [int]$TimeoutMs = 15000) {
    $waited = 0
    while ($waited -lt $TimeoutMs) {
        $d = @(Get-DescendantPids $Root)
        if ($Want -and $d.Count -gt 0) { return $d }
        if (-not $Want -and $d.Count -eq 0) { return @() }
        Start-Sleep -Milliseconds 400
        $waited += 400
    }
    return @(Get-DescendantPids $Root)
}

# The confirm dialog, waited for in either direction.
function Wait-Dialog([int]$gpid, [bool]$appear, [int]$timeoutMs = 3000) {
    if ($appear) { return Wait-TestWindow -ProcessId $gpid -Class 'GhozttyConfirmDialog' -TimeoutMs $timeoutMs }
    $waited = 0
    while ($waited -lt $timeoutMs) {
        if ((Get-TestWindow -ProcessId $gpid -Class 'GhozttyConfirmDialog') -eq [IntPtr]::Zero) {
            Start-Sleep -Milliseconds 250
            $waited += 250
            continue
        }
        return (Get-TestWindow -ProcessId $gpid -Class 'GhozttyConfirmDialog')
    }
    return [IntPtr]::Zero
}

# The pane's shell pid, straight from the app. With session-persistence ON this
# is the pid the AGENT reported, which is the half a fix that only knows about
# direct children would get wrong.
function Get-PaneShellPid {
    $json = & $Exe +list --json 2>$null | Out-String
    if (-not $json) { return 0 }
    try { $tree = $json | ConvertFrom-Json } catch { return 0 }
    # {"type":"leaf","terminal":{...}} / {"type":"split","left":...,"right":...}
    $root = if ($tree.PSObject.Properties.Name -contains 'data') { $tree.data } else { $tree }
    foreach ($w in @($root.windows)) {
        foreach ($t in @($w.tabs)) {
            $stack = New-Object System.Collections.Stack
            $stack.Push($t.splits)
            while ($stack.Count -gt 0) {
                $n = $stack.Pop()
                if ($null -eq $n) { continue }
                if ($n.type -eq 'leaf') {
                    if ($n.terminal -and [int]$n.terminal.pid -gt 0) { return [int]$n.terminal.pid }
                } else {
                    if ($n.right) { $stack.Push($n.right) }
                    if ($n.left) { $stack.Push($n.left) }
                }
            }
        }
    }
    return 0
}

# The pid `+list --json` reports for the pane of the window registered under
# $Target, or -1 when that window/pane is not there at all. Distinct from
# `Get-PaneShellPid` (which takes the first pane with a pid > 0) because for a
# CROSS-MACHINE pane the interesting value IS zero: `Surface.shellPid` refuses to
# hand back a pid that indexes another machine's process table.
function Get-TargetPaneShellPid([string]$Target) {
    $json = & $Exe +list --json 2>$null | Out-String
    if (-not $json) { return -1 }
    try { $tree = $json | ConvertFrom-Json } catch { return -1 }
    $root = if ($tree.PSObject.Properties.Name -contains 'data') { $tree.data } else { $tree }
    foreach ($w in @($root.windows)) {
        if ($w.target -ne $Target) { continue }
        foreach ($t in @($w.tabs)) {
            $stack = New-Object System.Collections.Stack
            $stack.Push($t.splits)
            while ($stack.Count -gt 0) {
                $n = $stack.Pop()
                if ($null -eq $n) { continue }
                if ($n.type -eq 'leaf') {
                    if ($n.terminal) { return [int]$n.terminal.pid }
                } else {
                    if ($n.right) { $stack.Push($n.right) }
                    if ($n.left) { $stack.Push($n.left) }
                }
            }
        }
    }
    return -1
}

function Launch-Gui([string[]]$ExtraArgs) {
    # persistence: caller supplies - section A runs with =false and section B with =true, and the PAIR is what this script is for.
    $app = Start-OnTestDesktop -Exe $Exe -Arguments $ExtraArgs
    Start-Sleep -Seconds 3
    if ($app.Process -and $app.Process.HasExited) { return $null }
    $top = Wait-TestWindow -ProcessId $app.Pid -Class 'GhozttyWindow'
    if ($top -eq [IntPtr]::Zero) { return $null }
    Set-TestWindowSize -Window $top -Width 1100 -Height 700 | Out-Null
    Start-Sleep -Milliseconds 400
    $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
    if ($surface -eq [IntPtr]::Zero) { return $null }
    return @{ App = $app; Pid = $app.Pid; Top = $top; Surface = $surface }
}

# One section: launch, make the shell busy, confirm the dialog appears, let the
# shell go idle, and close again.
function Invoke-Section([string]$Label, [string[]]$ExtraArgs) {
    Write-Host ""
    Write-Host "== $Label =="

    $g = Launch-Gui $ExtraArgs
    if (-not $g) { Write-Host "SETUP FAIL: $Label GUI did not come up"; $script:fail++; return }
    Assert (-not (Test-TestDesktopLeak -ProcessId $g.Pid)) "$Label window is NOT on the interactive desktop"

    $shell = Get-PaneShellPid
    if ($shell -le 0) {
        # Not a product verdict for T41's dialog rule, but the section's whole
        # oracle rests on it - and with persistence ON it is the same code path
        # the fix uses, so say so loudly rather than skipping quietly.
        Write-Host "SETUP FAIL: $Label +list reported no shell pid for the pane"
        $script:fail++
        Stop-Process -Id $g.Pid -Force -ErrorAction SilentlyContinue
        return
    }
    # The pid must name a LIVE process, or every descendant answer below is a
    # confident zero about nothing - which is exactly how a fix that returns a
    # meaningless pid would look green here.
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$shell" -ErrorAction SilentlyContinue
    Assert ($null -ne $proc) "$Label shell pid $shell names a live process"
    if ($proc) { Write-Host "       shell = $($proc.Name) ppid=$($proc.ParentProcessId)" }

    $idle0 = @(Get-DescendantPids $shell)
    Assert ($idle0.Count -eq 0) "$Label a fresh shell has no descendants (found $($idle0.Count))"

    # ---------------------------------------------------------------- busy
    Send-TestText -Window $g.Top -Target $g.Surface -Text 'ping -n 100 127.0.0.1' | Out-Null
    Send-TestKeys -Window $g.Top -Target $g.Surface -Key Enter | Out-Null
    # @(): a PS 5.1 function's array return UNROLLS, so a single descendant
    # would arrive as a bare object whose .Count is $null.
    $busy = @(Wait-Descendants $shell $true)
    Assert ($busy.Count -gt 0) "$Label ping is running under the shell ($($busy.Count) descendants)"
    if ($busy.Count -eq 0) {
        Write-Host "SETUP FAIL: $Label could not make the shell busy"
        Stop-Process -Id $g.Pid -Force -ErrorAction SilentlyContinue
        return
    }

    # Same shell pid, read back through the OTHER consumer of it: a process
    # running inside the pane must be able to find its own pane by pid. This is
    # what `/reset-context` uses, and with session-persistence ON it answered
    # "no pane" for years - the app read a pid the agent never had (see B/agent).
    $probe = [int]$busy[0].ProcessId
    $match = (& $Exe +list --pid=$probe 2>$null | Out-String).Trim()
    Assert ($match -and $match.Length -gt 0) "$Label +list --pid finds the pane from a process inside it ('$match')"

    Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl -Key W | Out-Null
    $dlg = Wait-Dialog $g.Pid $true 5000
    Assert ($dlg -ne [IntPtr]::Zero) "$Label busy shell: ctrl+w opens the confirm dialog"
    if ($dlg -ne [IntPtr]::Zero) {
        Send-TestControlKey -Control $dlg -Key Escape | Out-Null
        $gone = Wait-Dialog $g.Pid $false
        Assert ($gone -eq [IntPtr]::Zero) "$Label Escape dismisses the busy confirm"
        Assert (Test-TestWindowVisible -Window $g.Top) "$Label window survives the cancelled close"
    }

    # ---------------------------------------------------------------- idle
    # Ctrl+C the ping and wait for the process table to agree it is gone.
    Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl -Key C | Out-Null
    $left = @(Wait-Descendants $shell $false)
    Assert ($left.Count -eq 0) "$Label ctrl+c leaves the shell with no descendants (found $($left.Count))"
    if ($left.Count -ne 0) {
        Write-Host "SETUP FAIL: $Label shell never went idle: $(($left | ForEach-Object { $_.Name }) -join ',')"
        Stop-Process -Id $g.Pid -Force -ErrorAction SilentlyContinue
        return
    }
    Start-Sleep -Milliseconds 500

    Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl -Key W | Out-Null
    $dlg = Wait-Dialog $g.Pid $true 2500
    $closed = $false
    for ($t = 0; $t -lt 40 -and -not $closed; $t++) {
        Start-Sleep -Milliseconds 100
        $closed = (-not (Test-TestWindowExists -Window $g.Top)) -or (-not (Test-TestWindowVisible -Window $g.Top))
    }

    if ($NegativeControl) {
        Write-Host "NEGATIVE CONTROL: asserting the IDLE close still confirms - this run MUST fail"
        Assert ($dlg -ne [IntPtr]::Zero) "$Label idle shell: ctrl+w opens the confirm dialog (inverted)"
    } else {
        Assert ($dlg -eq [IntPtr]::Zero) "$Label idle shell: ctrl+w opens NO confirm dialog"
    }
    # The chord must have DONE something: no dialog plus an open window is a
    # swallowed keystroke, not a skipped confirmation.
    Assert $closed "$Label idle shell: the last pane closed without confirming"

    if ($dlg -ne [IntPtr]::Zero) { Send-TestControlKey -Control $dlg -Key Escape | Out-Null }
    Stop-Process -Id $g.Pid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

# How long to allow for the agent's pushed answer to reach the app (T356). The
# agent samples once a second and pushes only on change, so this is that tick
# plus slack for the frame. It is a WAIT, not a poll of anything the app says -
# every busy/idle verdict below is still anchored on Win32_Process.
$script:PushSettleMs = 3000

# Section C: a CROSS-MACHINE pane. A loopback `ghoztty-agent --listen` stands in
# for the other machine - the app dials it over TCP, so the connection is
# `remote` and NOT `local`, which is exactly the case where `Surface.shellPid`
# returns 0 and the local process walk has nothing to walk.
function Invoke-RemoteSection([string]$Label) {
    Write-Host ""
    Write-Host "== $Label =="

    if (-not (Test-Path $AgentExe)) {
        Write-Host "SETUP FAIL: no agent at $AgentExe"
        $script:fail++
        return
    }

    # A unique lock path so this harness agent never fights a real agent's
    # single-instance guard (the ipc-remote.ps1 precedent).
    $env:GHOSTTY_AGENT_LOCK = Join-Path $env:TEMP 'ghoztty-t356-agent.lock'
    $agent = Start-Process -FilePath $AgentExe `
        -ArgumentList "--listen", "127.0.0.1:$Port", "--headless" `
        -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2
    if ($agent.HasExited) {
        Write-Host "SETUP FAIL: $Label listening agent exited immediately"
        $script:fail++
        return
    }

    $g = $null
    try {
        # Persistence OFF for the app's own first window, so the ONLY
        # ghoztty-agent on the box is our listener and the shell-pid oracle
        # below cannot pick up a local-agent session by mistake.
        $g = Launch-Gui @('--session-persistence=false')
        if (-not $g) { Write-Host "SETUP FAIL: $Label GUI did not come up"; $script:fail++; return }
        Assert (-not (Test-TestDesktopLeak -ProcessId $g.Pid)) "$Label window is NOT on the interactive desktop"

        $before = @(Get-TestWindows -ProcessId $g.Pid | ForEach-Object { $_.Hwnd })
        & $Exe +new-remote-window --host=127.0.0.1 --port=$Port --name=t356rem 2>&1 | Out-Null
        $top = [IntPtr]::Zero
        for ($t = 0; $t -lt 60 -and $top -eq [IntPtr]::Zero; $t++) {
            Start-Sleep -Milliseconds 250
            foreach ($w in (Get-TestWindows -ProcessId $g.Pid)) {
                if ($before -notcontains $w.Hwnd) { $top = [IntPtr]$w.Hwnd; break }
            }
        }
        Assert ($top -ne [IntPtr]::Zero) "$Label +new-remote-window opened a window"
        if ($top -eq [IntPtr]::Zero) { return }
        Set-TestWindowSize -Window $top -Width 1100 -Height 700 | Out-Null
        Start-Sleep -Milliseconds 400
        $surface = Get-TestChildWindow -Window $top -Class 'GhozttyTerminal'
        if ($surface -eq [IntPtr]::Zero) {
            Write-Host "SETUP FAIL: $Label remote window has no terminal surface"
            $script:fail++
            return
        }

        # THIS is what makes the section a cross-machine one rather than an
        # accidental re-run of B: the app must report NO pid for the pane. A
        # non-zero pid here would mean the local walk could have answered, and
        # every verdict below would be about the wrong code path.
        $reported = Get-TargetPaneShellPid 't356rem'
        Assert ($reported -eq 0) "$Label the app reports no local pid for the remote pane (got $reported)"

        # The shell itself, from the OS. Since T905/T909 a session's ConPTY and
        # shell live in a per-session HOLDER process (`ghoztty-agent.exe
        # --pty-host`) that deliberately escapes the agent's job - and, on the
        # shell-parent-hop escape tier, its parent link with it. So the agent's
        # own descendants are no longer where the shell is, and this section
        # spent a while reporting "the agent spawned a shell" as a failure over
        # a session that had one (T1090). Both roots are searched, because the
        # in-process fallback (`GHOZTTY_AGENT_PTY_HOLDER=0`, or a holder that
        # would not start) still parents the shell to the agent.
        $shell = 0
        for ($t = 0; $t -lt 40 -and $shell -eq 0; $t++) {
            foreach ($root in (@($agent.Id) + @(Get-PtyHolderPids))) {
                foreach ($p in (Get-DescendantPids $root)) {
                    if ($p.Name -match '^(conhost|openconsole)\.exe$') { continue }
                    # A holder reached through the agent is a waypoint, not the
                    # shell; its own descendants are enumerated by this walk.
                    if ($p.Name -eq 'ghoztty-agent.exe') { continue }
                    $shell = [int]$p.ProcessId
                    break
                }
                if ($shell -ne 0) { break }
            }
            if ($shell -eq 0) { Start-Sleep -Milliseconds 250 }
        }
        Assert ($shell -gt 0) "$Label the agent spawned a shell for the remote session"
        if ($shell -le 0) { return }

        $idle0 = @(Get-DescendantPids $shell)
        Assert ($idle0.Count -eq 0) "$Label a fresh remote shell has no descendants (found $($idle0.Count))"

        # Let the agent push the IDLE answer BEFORE anything runs. This is what
        # makes the busy dialog below evidence of a real transition: without it,
        # a confirm could just as well be the app's "I was never told" default,
        # which is also a confirm.
        Start-Sleep -Milliseconds $script:PushSettleMs

        # ---------------------------------------------------------------- busy
        Send-TestText -Window $top -Target $surface -Text 'ping -n 100 127.0.0.1' | Out-Null
        Send-TestKeys -Window $top -Target $surface -Key Enter | Out-Null
        $busy = @(Wait-Descendants $shell $true)
        Assert ($busy.Count -gt 0) "$Label ping is running under the remote shell ($($busy.Count) descendants)"
        if ($busy.Count -eq 0) { return }
        Start-Sleep -Milliseconds $script:PushSettleMs

        Send-TestKeys -Window $top -Target $surface -Modifiers ctrl -Key W | Out-Null
        $dlg = Wait-Dialog $g.Pid $true 5000
        Assert ($dlg -ne [IntPtr]::Zero) "$Label busy remote shell: ctrl+w opens the confirm dialog"
        if ($dlg -ne [IntPtr]::Zero) {
            Send-TestControlKey -Control $dlg -Key Escape | Out-Null
            $gone = Wait-Dialog $g.Pid $false
            Assert ($gone -eq [IntPtr]::Zero) "$Label Escape dismisses the busy confirm"
            Assert (Test-TestWindowVisible -Window $top) "$Label remote window survives the cancelled close"
        }

        # ---------------------------------------------------------------- idle
        Send-TestKeys -Window $top -Target $surface -Modifiers ctrl -Key C | Out-Null
        $left = @(Wait-Descendants $shell $false)
        Assert ($left.Count -eq 0) "$Label ctrl+c leaves the remote shell with no descendants (found $($left.Count))"
        if ($left.Count -ne 0) { return }
        Start-Sleep -Milliseconds $script:PushSettleMs

        # T1390 SUPERSEDED THIS CASE, deliberately. Until then an idle
        # cross-machine pane closed with no dialog, exactly like an idle local
        # one - which is what T356 built and what this block used to assert.
        # Ending a process on ANOTHER machine is not the recoverable thing an
        # idle local shell is, so the gate is now widened for a remote pane and
        # the close offers Disconnect instead. The claim here is therefore the
        # opposite one, and the discriminator for it is section A: the same
        # harness, the same chord, the same idle oracle on a LOCAL pane, where
        # the close still does not confirm. Where the Disconnect offer itself is
        # exercised is test/win32/remote-disconnect.ps1.
        Send-TestKeys -Window $top -Target $surface -Modifiers ctrl -Key W | Out-Null
        $dlg = Wait-Dialog $g.Pid $true 5000

        if ($NegativeControl) {
            Write-Host "NEGATIVE CONTROL: asserting the IDLE remote close does NOT confirm - this run MUST fail"
            Assert ($dlg -eq [IntPtr]::Zero) "$Label idle remote shell: ctrl+w opens the confirm dialog (inverted)"
        } else {
            Assert ($dlg -ne [IntPtr]::Zero) "$Label idle remote shell: ctrl+w still confirms (T1390)"
        }
        if ($dlg -ne [IntPtr]::Zero) {
            $offer = @(Get-TestControls -Window $dlg -Class 'Button' |
                Where-Object { $_.Text -eq 'Disconnect' })
            Assert ($offer.Count -eq 1) "$Label idle remote shell: the confirmation offers Disconnect"
            Send-TestControlKey -Control $dlg -Key Escape | Out-Null
            $gone = Wait-Dialog $g.Pid $false
            Assert ($gone -eq [IntPtr]::Zero) "$Label idle remote shell: Escape dismisses the confirm"
            Assert (Test-TestWindowVisible -Window $top) "$Label idle remote shell: the window survives the cancelled close"
        }
    } finally {
        if ($g) { Stop-Process -Id $g.Pid -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $agent.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }
}

# ---------------------------------------------------------------------------
# The FORCED confirmations (T357): the two branches `Surface.shellIsIdle`
# refuses to answer "idle" for, whatever the process table says.
#
# Both sections run an IDLE shell - descendant-free, asserted straight out of
# Win32_Process exactly as A-C do - because idle is the ONLY state in which the
# forced branch is the sole reason a dialog can appear. A busy shell confirms
# anyway and would prove nothing about either branch.
# ---------------------------------------------------------------------------

# Launch, then assert the pane's shell is up and sitting at its prompt with
# nothing under it. Returns the GUI handle plus the shell pid, or $null after
# reporting the setup failure itself.
function Start-IdleShellWindow([string]$Label, [string[]]$ExtraArgs) {
    $g = Launch-Gui $ExtraArgs
    if (-not $g) { Write-Host "SETUP FAIL: $Label GUI did not come up"; $script:fail++; return $null }
    Assert (-not (Test-TestDesktopLeak -ProcessId $g.Pid)) "$Label window is NOT on the interactive desktop"

    $shell = Get-PaneShellPid
    if ($shell -le 0) {
        Write-Host "SETUP FAIL: $Label +list reported no shell pid for the pane"
        $script:fail++
        Stop-Process -Id $g.Pid -Force -ErrorAction SilentlyContinue
        return $null
    }
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$shell" -ErrorAction SilentlyContinue
    Assert ($null -ne $proc) "$Label shell pid $shell names a live process"

    # @(): a PS 5.1 function's array return unrolls, so one descendant would
    # arrive as a bare object whose .Count is $null.
    $idle = @(Wait-Descendants $shell $false 8000)
    Assert ($idle.Count -eq 0) "$Label the shell is idle before the close ($($idle.Count) descendants)"
    if ($idle.Count -ne 0) {
        Write-Host "SETUP FAIL: $Label shell was never idle: $(($idle | ForEach-Object { $_.Name }) -join ',')"
        Stop-Process -Id $g.Pid -Force -ErrorAction SilentlyContinue
        return $null
    }
    Start-Sleep -Milliseconds 500
    $g.Shell = $shell
    return $g
}

# One forced-confirm check: fire $Send, expect the dialog, escape it, and
# require the window to survive. -NegativeControl inverts the verdict, so a
# negative-control run fails here too.
function Assert-ForcedConfirm([string]$Name, $Gui, [IntPtr]$Top, [scriptblock]$Send) {
    & $Send
    $dlg = Wait-Dialog $Gui.Pid $true 5000
    if ($NegativeControl) {
        Write-Host "NEGATIVE CONTROL: asserting the forced close does NOT confirm - this run MUST fail"
        Assert ($dlg -eq [IntPtr]::Zero) "$Name (inverted)"
    } else {
        Assert ($dlg -ne [IntPtr]::Zero) $Name
    }
    if ($dlg -ne [IntPtr]::Zero) {
        Send-TestControlKey -Control $dlg -Key Escape | Out-Null
        $gone = Wait-Dialog $Gui.Pid $false
        Assert ($gone -eq [IntPtr]::Zero) "$Name - Escape dismisses it"
        Assert (Test-TestWindowVisible -Window $Top) "$Name - the window survives the cancelled close"
    }
}

# Section D: `confirm-close-surface = always`.
#
# The discriminator is section A above rather than a toggle inside this
# section: nothing in a running app can turn `always` off, and A is the same
# harness, the same chord and the same idle oracle under the default config -
# where the idle close does NOT confirm. The pair is the control.
#
# Both consumers of the branch are exercised, because they are separate call
# sites: Ctrl+W is `Surface.close` -> `shellIsIdleNow`, and WM_CLOSE (the
# title-bar X / Alt+F4 path) is `Window.confirmCloseIfNeeded`, which asks
# `shellIsIdle` once per pane against one shared snapshot.
function Invoke-AlwaysSection([string]$Label) {
    Write-Host ""
    Write-Host "== $Label =="

    $g = Start-IdleShellWindow $Label @('--session-persistence=false', '--confirm-close-surface=always')
    if (-not $g) { return }
    try {
        Assert-ForcedConfirm "$Label idle shell + confirm-close-surface=always: ctrl+w still confirms" `
            $g $g.Top { Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl -Key W | Out-Null }

        Assert-ForcedConfirm "$Label idle shell + confirm-close-surface=always: the window close still confirms" `
            $g $g.Top { Send-TestWindowClose -Window $g.Top | Out-Null }
    } finally {
        Stop-Process -Id $g.Pid -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }
}

# Section E: a READ-ONLY surface.
#
# Read-only is reachable here only through a binding action (there is no
# default chord and no CLI verb), so the window is launched with one bound -
# the same route test\win32\readonly-badge.ps1 uses.
#
# The badge (class GhozttyReadonlyBadge) is the independent oracle that the
# toggle actually landed, and doubles as this section's positive control: it
# proves chords reach this window, so "no dialog" later cannot be "no
# keystroke". And unlike `always`, read-only CAN be turned back off - so the
# section carries its own discriminator, closing the identical pane with the
# identical chord and requiring the dialog to be gone.
function Invoke-ReadonlySection([string]$Label) {
    Write-Host ""
    Write-Host "== $Label =="

    $g = Start-IdleShellWindow $Label @('--session-persistence=false', '--keybind=ctrl+shift+o=toggle_readonly')
    if (-not $g) { return }
    $closed = $false
    try {
        $badges = @(Get-TestWindows -ProcessId $g.Pid -Class 'GhozttyReadonlyBadge' | Where-Object Visible)
        Assert ($badges.Count -eq 0) "$Label no read-only badge before the toggle ($($badges.Count))"

        Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl, shift -Key O | Out-Null
        $badges = @()
        for ($t = 0; $t -lt 30 -and $badges.Count -ne 1; $t++) {
            Start-Sleep -Milliseconds 100
            $badges = @(Get-TestWindows -ProcessId $g.Pid -Class 'GhozttyReadonlyBadge' | Where-Object Visible)
        }
        Assert ($badges.Count -eq 1) "$Label the pane is read-only (badge visible: $($badges.Count))"
        if ($badges.Count -ne 1) { return }

        Assert-ForcedConfirm "$Label idle read-only shell: ctrl+w still confirms" `
            $g $g.Top { Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl -Key W | Out-Null }

        # ------------------------------------------------- the discriminator
        # Same pane, same chord, read-only turned back OFF: the dialog must be
        # gone. Without this, a section that confirmed for some unrelated
        # reason would read as green.
        Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl, shift -Key O | Out-Null
        $badges = @(Get-TestWindows -ProcessId $g.Pid -Class 'GhozttyReadonlyBadge' | Where-Object Visible)
        for ($t = 0; $t -lt 30 -and $badges.Count -ne 0; $t++) {
            Start-Sleep -Milliseconds 100
            $badges = @(Get-TestWindows -ProcessId $g.Pid -Class 'GhozttyReadonlyBadge' | Where-Object Visible)
        }
        Assert ($badges.Count -eq 0) "$Label read-only turned back off (badge gone: $($badges.Count))"

        $left = @(Get-DescendantPids $g.Shell)
        Assert ($left.Count -eq 0) "$Label the shell is still idle for the control close ($($left.Count))"

        Send-TestKeys -Window $g.Top -Target $g.Surface -Modifiers ctrl -Key W | Out-Null
        $dlg = Wait-Dialog $g.Pid $true 2500
        for ($t = 0; $t -lt 40 -and -not $closed; $t++) {
            Start-Sleep -Milliseconds 100
            $closed = (-not (Test-TestWindowExists -Window $g.Top)) -or (-not (Test-TestWindowVisible -Window $g.Top))
        }
        Assert ($dlg -eq [IntPtr]::Zero) "$Label no longer read-only: the idle close confirms nothing"
        # No dialog plus an open window would be a swallowed chord, not a
        # skipped confirmation.
        Assert $closed "$Label no longer read-only: the pane closed without confirming"
        if ($dlg -ne [IntPtr]::Zero) { Send-TestControlKey -Control $dlg -Key Escape | Out-Null }
    } finally {
        Stop-Process -Id $g.Pid -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }
}

Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
Reset-AgentState
Start-TestForegroundWatch
$td = New-TestDesktop -Interactive:$Interactive

try {
    Invoke-Section 'A/exec' @('--session-persistence=false')
    Stop-RepoProcesses @('ghoztty')
    Reset-AgentState
    Invoke-Section 'B/agent' @('--session-persistence=true')
    Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
    Reset-AgentState
    Invoke-RemoteSection 'C/remote'
    Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
    Reset-AgentState
    Invoke-AlwaysSection 'D/always'
    Stop-RepoProcesses @('ghoztty')
    Reset-AgentState
    Invoke-ReadonlySection 'E/readonly'
} finally {
    Stop-RepoProcesses @('ghoztty', 'ghoztty-agent')
    $fgSeen = @(Stop-TestForegroundWatch)
    $leaked = @(Get-TestLaunchedPids | Where-Object { $fgSeen -contains $_ })
    Assert ($leaked.Count -eq 0) 'no test-desktop app ever became foreground'
    Remove-TestDesktop $td
}

Write-Host ""
if ($script:fail -eq 0) { Write-Host "ALL PASS ($script:pass checks)" }
else { Write-Host "$script:fail FAILURE(S) ($script:pass passed)" -ForegroundColor Red }
exit ([int]($script:fail -gt 0))
