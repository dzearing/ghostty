# The cleanup screen (tracker T1188): inventory every Ghoztty on this box, with
# provenance, and let the user remove the temporary and dev ones so the official
# release installs onto a clean machine.
#
# WHY IT EXISTS
#
# T1179 - the clean-machine proof - asserts "no prior Ghoztty" before the user
# walks the website -> installer -> working terminal path. This box has at least
# four of them (the installed release, the Desktop portable, the network share
# copy, and every `zig-out*` dev prefix in the repo) plus the sediment an install
# leaves behind: MSI ARP registrations, a user PATH entry, a Start Menu shortcut,
# an HKCU Run entry for the agent, named pipes, the DPAPI credential store and
# the session state directory. Every previous "clean machine" claim on this box
# was a memory of which folders someone deleted, and a memory cannot be checked
# for holes. This script is the enumeration, and its verdict is the evidence.
#
# TWO HARD GUARDS, BOTH ALREADY PAID FOR
#
#   1. It NEVER offers `msiexec /x` on a protected product code. The registered
#      "Ghoztty 26.7.502" entry {A10466B5-D625-4A80-95D2-8AA648F5086C} is a ghost
#      of the broken 2026-07-05 install; its files are long gone but its recorded
#      install path is the LIVE install at %LOCALAPPDATA%\Programs\Ghoztty, so
#      uninstalling it would delete the user's primary terminal out from under
#      them. Protected codes are reported with the refusal and the reason, and
#      no command string is ever emitted for them - `test\win32\ghoztty-cleanup.ps1`
#      section B asserts that by searching the emitted plan text.
#      The same rule is derived, not only hardcoded: any ARP entry whose
#      InstallLocation is a live install directory it did not itself produce is
#      protected on the same grounds.
#   2. NOTHING is removed without explicit per-item confirmation. The screen
#      proposes; the user disposes. There is no `-Force`, no "remove all", and an
#      unanswered item defaults to KEEP.
#
# WHAT "CLEAN" MEANS HERE
#
# Not "nothing exists" - the user may deliberately keep something, and T1179's
# criterion is that each location is "gone or deliberately kept". So the verdict
# is about ACCOUNTING: an item is accounted for when it is gone, explicitly kept
# (`keep <id> -Reason ...`, recorded on disk), or permanently protected. An
# unaccounted removable item is what makes the box dirty, and it is the only
# thing that does.
#
# Usage:
#   powershell -NoProfile -File scripts\ghoztty-cleanup.ps1 inventory
#   powershell -NoProfile -File scripts\ghoztty-cleanup.ps1 clean
#   powershell -NoProfile -File scripts\ghoztty-cleanup.ps1 verdict
#   powershell -NoProfile -File scripts\ghoztty-cleanup.ps1 keep <id> -Reason "..."
#   powershell -NoProfile -File scripts\ghoztty-cleanup.ps1 unkeep <id>
#
# Exit codes: 0 inventory printed / box accounted-for clean,
#             1 unaccounted removable artifacts remain (verdict, clean),
#             2 the run was never viable (bad arguments).
[CmdletBinding(PositionalBinding = $false)]
param(
    # The verb, then (for keep/unkeep) the item id. Collected from the remaining
    # arguments rather than declared positional: PositionalBinding=$false is what
    # keeps every option below named-only, and it makes `Position` attributes a
    # no-op - a verb written as `[Parameter(Position=0)]` here binds nothing and
    # silently falls back to the default, which is how a `clean` run once read as
    # an `inventory` run that exited 0.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest = @(),

    # Why an item is being kept. Required by `keep`: a keep with no reason is
    # indistinguishable from an oversight when T1179 reads the verdict back.
    [string]$Reason = '',

    # ---- Where to look. Every root is a parameter so the acceptance harness can
    # run the real code against a throwaway sandbox instead of the user's box.
    [string]$ReleaseDir = (Join-Path $env:LOCALAPPDATA 'Programs\Ghoztty'),
    [string[]]$PortableDirs = @(
        'D:\Users\David\Desktop\Ghoztty-portable-x64',
        '\\homeassistant\share\ghoztty-windows\Ghoztty-portable-x64'
    ),
    # Repo root whose `zig-out*` prefixes are the dev builds. Resolved below
    # rather than here: $PSScriptRoot is not yet bound while param defaults are
    # evaluated, so a default written here binds to an empty string.
    [string]$DevRoot = '',
    [string]$StateDir = (Join-Path $env:LOCALAPPDATA 'ghoztty'),
    [string]$StartMenuDir = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
    [string]$StartupDir = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'),
    [string]$RunKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
    [string]$AppRegKeyPath = 'HKCU:\Software\dzearing',
    [string[]]$UninstallKeyPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    ),
    [string]$PathRegKey = 'HKCU:\Environment',

    # Product codes that must never be offered for uninstall. See guard 1.
    [string[]]$ProtectedProductCodes = @('{A10466B5-D625-4A80-95D2-8AA648F5086C}'),

    # Where deliberate keeps are recorded. On disk, because the verdict has to
    # survive the pane it was printed in (T1179 kills every pane).
    [string]$KeepFile = '',

    # Scripted confirmations for the acceptance harness: `-Answer id1=y,id2=n`.
    # Anything unlisted answers NO. Supplying this makes `clean` non-interactive.
    [string[]]$Answer = @(),

    [switch]$DryRun,
    [switch]$NoProcessScan,
    [switch]$NoPipeScan,
    [switch]$NoTaskScan
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version 2.0

$Action = 'inventory'
$Id = ''
$valid = @('inventory', 'clean', 'verdict', 'keep', 'unkeep')
if ($Rest.Count -ge 1) {
    $Action = $Rest[0]
    if ($valid -notcontains $Action) {
        Write-Host "unknown action '$Action' - expected one of: $($valid -join ', ')" -ForegroundColor Red
        exit 2
    }
}
if ($Rest.Count -ge 2) { $Id = $Rest[1] }
if ($Rest.Count -gt 2) {
    Write-Host "too many positional arguments: $($Rest -join ' ')" -ForegroundColor Red
    exit 2
}

if (-not $DevRoot) { $DevRoot = Split-Path $PSScriptRoot -Parent }
if (-not $KeepFile) {
    $KeepFile = Join-Path $DevRoot 'temp\ghoztty-cleanup-keep.json'
}

# ---------------------------------------------------------------- output ----

function Say($m) { Write-Host $m }
function Head($m) { Write-Host ''; Write-Host $m -ForegroundColor Cyan }
function Warn($m) { Write-Host $m -ForegroundColor Yellow }
function Bad($m) { Write-Host $m -ForegroundColor Red }

function Format-Size([double]$bytes) {
    if ($bytes -ge 1GB) { return ('{0:N1} GB' -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ('{0:N1} MB' -f ($bytes / 1MB)) }
    if ($bytes -ge 1KB) { return ('{0:N0} KB' -f ($bytes / 1KB)) }
    return ('{0} B' -f [int]$bytes)
}

# ------------------------------------------------------------- keep store ----

function Read-Keeps {
    if (-not (Test-Path -LiteralPath $KeepFile)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $KeepFile -Raw -ErrorAction Stop
        if (-not $raw -or $raw.Trim().Length -eq 0) { return @{} }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Warn "  keep file unreadable ($KeepFile): $($_.Exception.Message) - treating as empty"
        return @{}
    }
    $map = @{}
    foreach ($p in $obj.PSObject.Properties) { $map[$p.Name] = [string]$p.Value }
    return $map
}

function Write-Keeps($map) {
    $dir = Split-Path $KeepFile -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $o = New-Object psobject
    foreach ($k in ($map.Keys | Sort-Object)) {
        Add-Member -InputObject $o -MemberType NoteProperty -Name $k -Value $map[$k]
    }
    # UTF8 without a BOM would be nicer, but this file is machine-written and
    # machine-read only; ConvertTo-Json + Set-Content -Encoding utf8 is what the
    # rest of the repo's scratch state uses.
    ($o | ConvertTo-Json) | Set-Content -LiteralPath $KeepFile -Encoding utf8
}

# ----------------------------------------------------------- exe metadata ----

# Ask a Ghoztty exe what it is. Never fatal: an exe that will not answer is
# still an artifact, it just has no version to report.
function Get-GhozttyExeInfo([string]$exe) {
    $info = [pscustomobject]@{
        Version = ''
        Built   = $null
        Bytes   = 0
    }
    if (-not (Test-Path -LiteralPath $exe)) { return $info }
    try {
        $fi = Get-Item -LiteralPath $exe -ErrorAction Stop
        $info.Built = $fi.LastWriteTime
        $info.Bytes = $fi.Length
    } catch { }
    try {
        $vi = (Get-Item -LiteralPath $exe).VersionInfo
        if ($vi -and $vi.FileVersion) { $info.Version = [string]$vi.FileVersion }
    } catch { }
    return $info
}

# Which directories currently host a running ghoztty/ghoztty-agent? Removing a
# directory out from under a live process half-succeeds and reads as a mystery
# later, so an in-use item is BLOCKED rather than offered.
function Get-RunningGhozttyPaths {
    if ($NoProcessScan) { return @() }
    $out = @()
    try {
        $procs = Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -match '^ghoztty' }
        foreach ($p in $procs) {
            $path = ''
            try { $path = [string]$p.Path } catch { }
            if ($path) { $out += [pscustomobject]@{ Pid = $p.Id; Path = $path } }
        }
    } catch { }
    return $out
}

function Test-InUse([string]$dir, $running) {
    if (-not $dir) { return $null }
    $norm = $dir.TrimEnd('\') + '\'
    foreach ($r in $running) {
        if ($r.Path -and $r.Path.StartsWith($norm, [StringComparison]::OrdinalIgnoreCase)) {
            return $r
        }
    }
    return $null
}

# ------------------------------------------------------------- item model ----

$script:Items = @()

function New-Item2 {
    param(
        [string]$ItemId,
        [string]$Category,
        [string]$Title,
        [string]$Target,
        [string]$Provenance,
        [string]$Detail = '',
        [bool]$Removable = $true,
        [bool]$Advisory = $false,
        [string]$Command = '',
        [bool]$Protected = $false,
        [string]$ProtectReason = '',
        [scriptblock]$Remove = $null
    )
    $script:Items += [pscustomobject]@{
        Id            = $ItemId
        Category      = $Category
        Title         = $Title
        Target        = $Target
        Provenance    = $Provenance
        Detail        = $Detail
        Removable     = $Removable
        Advisory      = $Advisory
        Command       = $Command
        Protected     = $Protected
        ProtectReason = $ProtectReason
        Blocked       = ''
        Remove        = $Remove
    }
}

# ------------------------------------------------------------- collectors ----

function Add-InstallDir {
    param([string]$id, [string]$title, [string]$dir, [string]$provenance, $running)
    if (-not $dir) { return }
    if (-not (Test-Path -LiteralPath $dir)) { return }

    # Three shapes, one probe: the release keeps the exe at the root, both
    # portables nest one level (`<root>\Ghoztty\ghoztty.exe`), and a dev prefix
    # puts it under `bin\`. Probing for all three beats encoding the shape per
    # location - a dev prefix reported as "no ghoztty.exe present" is exactly
    # the kind of quietly-wrong inventory line this screen exists to replace.
    $exe = ''
    foreach ($cand in @('ghoztty.exe', 'Ghoztty\ghoztty.exe', 'bin\ghoztty.exe')) {
        $try = Join-Path $dir $cand
        if (Test-Path -LiteralPath $try) { $exe = $try; break }
    }
    $detail = ''
    if ($exe) {
        $i = Get-GhozttyExeInfo $exe
        $built = ''
        if ($i.Built) { $built = $i.Built.ToString('yyyy-MM-dd HH:mm') }
        $detail = ("ghoztty.exe {0} built {1}, {2}" -f $i.Version, $built, (Format-Size $i.Bytes)).Trim()
    } else {
        $detail = 'no ghoztty.exe present'
    }

    $d = $dir
    $rm = { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop }.GetNewClosure()
    New-Item2 -ItemId $id -Category 'install' -Title $title -Target $dir `
        -Provenance $provenance -Detail $detail -Remove $rm

    $inUse = Test-InUse $dir $running
    if ($inUse) {
        ($script:Items | Where-Object { $_.Id -eq $id })[0].Blocked =
            ("in use by pid {0} ({1})" -f $inUse.Pid, (Split-Path $inUse.Path -Leaf))
    }
}

function Add-Installs($running) {
    Add-InstallDir 'install-release' 'Installed release' $ReleaseDir `
        'MSI or upgrade-script install; owns the user PATH entry and the ghoztty-<user> pipe' $running

    $n = 0
    foreach ($p in $PortableDirs) {
        $n++
        if (-not $p) { continue }
        $reachable = $false
        try { $reachable = Test-Path -LiteralPath $p -ErrorAction SilentlyContinue } catch { }
        if (-not $reachable) {
            # An absent or unreachable location is not a finding. A sleeping NAS
            # must not read as a dirty box (same rule deliver-windows-build.ps1
            # applies to delivery).
            Say ("  portable location {0} unreachable or absent - skipped: {1}" -f $n, $p)
            continue
        }
        Add-InstallDir ("install-portable-$n") ("Portable copy $n") $p `
            'extracted portable ZIP; delivered by scripts\deliver-windows-build.ps1' $running
    }

    if ($DevRoot -and (Test-Path -LiteralPath $DevRoot)) {
        $prefixes = Get-ChildItem -LiteralPath $DevRoot -Directory -Filter 'zig-out*' -ErrorAction SilentlyContinue
        foreach ($pre in $prefixes) {
            $bin = Join-Path $pre.FullName 'bin'
            if (-not (Test-Path -LiteralPath (Join-Path $bin 'ghoztty.exe'))) { continue }
            Add-InstallDir ("install-dev-" + $pre.Name) ("Dev build prefix " + $pre.Name) $pre.FullName `
                'built in this repo by `zig build`; never shipped, never on PATH' $running
        }
    }
}

function Add-Arp {
    param($running)
    foreach ($root in $UninstallKeyPaths) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $subs = Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue
        foreach ($s in $subs) {
            $props = $null
            try { $props = Get-ItemProperty -LiteralPath $s.PSPath -ErrorAction Stop } catch { continue }
            $name = ''
            if ($props.PSObject.Properties['DisplayName']) { $name = [string]$props.DisplayName }
            if ($name -notmatch 'hoztty') { continue }

            $code = $s.PSChildName
            $ver = ''
            if ($props.PSObject.Properties['DisplayVersion']) { $ver = [string]$props.DisplayVersion }
            $loc = ''
            if ($props.PSObject.Properties['InstallLocation']) { $loc = [string]$props.InstallLocation }

            $protected = $false
            $why = ''
            if ($ProtectedProductCodes -contains $code) {
                $protected = $true
                $why = 'known ghost registration: its recorded install path is a LIVE install, so its uninstall would delete files it never wrote'
            } elseif ($loc) {
                # Derived form of the same rule: an entry pointing at a directory
                # that exists and holds an exe this registration cannot account
                # for (its own payload is gone) would uninstall somebody else's
                # files from a shared path.
                $locExe = Join-Path ($loc.TrimEnd('\')) 'ghoztty.exe'
                if (Test-Path -LiteralPath $locExe) {
                    $i = Get-GhozttyExeInfo $locExe
                    if ($ver -and $i.Version -and ($i.Version -notlike ("*" + $ver + "*"))) {
                        $protected = $true
                        $why = ("registration says {0} but {1} holds {2} - uninstalling it would delete another install's files from a shared path" -f $ver, $loc, $i.Version)
                    }
                }
            }

            $detail = ("{0} {1} at {2}" -f $name, $ver, $(if ($loc) { $loc } else { '(no InstallLocation)' })).Trim()
            if ($protected) {
                New-Item2 -ItemId ("arp-" + $code) -Category 'registry' `
                    -Title 'Apps & Features registration (PROTECTED)' -Target ($root + '\' + $code) `
                    -Provenance 'Windows Installer product registration' -Detail $detail `
                    -Removable $false -Advisory $true -Command '' `
                    -Protected $true -ProtectReason $why
            } else {
                # Advisory, never executed here: an uninstall is the user's act,
                # run in their own shell where they can see what it does.
                New-Item2 -ItemId ("arp-" + $code) -Category 'registry' `
                    -Title 'Apps & Features registration' -Target ($root + '\' + $code) `
                    -Provenance 'Windows Installer product registration' -Detail $detail `
                    -Removable $false -Advisory $true `
                    -Command ("msiexec /x {0}" -f $code)
            }
        }
    }
}

function Add-RegistryValues {
    # HKCU Run entries for the agent.
    if (Test-Path -LiteralPath $RunKeyPath) {
        $props = $null
        try { $props = Get-ItemProperty -LiteralPath $RunKeyPath -ErrorAction Stop } catch { }
        if ($props) {
            foreach ($p in $props.PSObject.Properties) {
                if ($p.Name -like 'PS*') { continue }
                $val = [string]$p.Value
                if (($p.Name -notmatch 'hoztty') -and ($val -notmatch 'hoztty')) { continue }
                $keyPath = $RunKeyPath
                $valName = $p.Name
                # GetNewClosure: these are loop variables in a shared function
                # scope, so without it every item's removal would target the LAST
                # value seen - the classic PowerShell late-binding bug, and here
                # it would delete the wrong registry value.
                $rm = { Remove-ItemProperty -LiteralPath $keyPath -Name $valName -Force -ErrorAction Stop }.GetNewClosure()
                New-Item2 -ItemId ("run-" + $p.Name) -Category 'registry' `
                    -Title ('Autostart entry ' + $p.Name) -Target ($RunKeyPath + '\' + $p.Name) `
                    -Provenance 'HKCU Run value that starts a Ghoztty component at logon' -Detail $val `
                    -Remove $rm
            }
        }
    }

    # The product's own settings key (HKCU\Software\dzearing\Ghoztty and any
    # test identity beside it).
    if (Test-Path -LiteralPath $AppRegKeyPath) {
        $subs = Get-ChildItem -LiteralPath $AppRegKeyPath -ErrorAction SilentlyContinue
        foreach ($s in $subs) {
            if ($s.PSChildName -notmatch 'hoztty') { continue }
            $kp = $s.PSPath
            $rm = { Remove-Item -LiteralPath $kp -Recurse -Force -ErrorAction Stop }.GetNewClosure()
            New-Item2 -ItemId ("reg-app-" + $s.PSChildName) -Category 'registry' `
                -Title ('Settings key ' + $s.PSChildName) -Target ($AppRegKeyPath + '\' + $s.PSChildName) `
                -Provenance 'written by the MSI (InstallDir, PathEntry, Shortcut keypaths)' `
                -Remove $rm
        }
    }
}

function Add-PathEntry {
    if (-not (Test-Path -LiteralPath $PathRegKey)) { return }
    $props = $null
    try { $props = Get-ItemProperty -LiteralPath $PathRegKey -ErrorAction Stop } catch { return }
    if (-not $props.PSObject.Properties['Path']) { return }
    $cur = [string]$props.Path
    if (-not $cur) { return }
    $parts = $cur.Split(';')
    $hits = @($parts | Where-Object { $_ -and ($_ -match 'hoztty') })
    if ($hits.Count -eq 0) { return }

    $key = $PathRegKey
    $keep = @($parts | Where-Object { -not ($_ -and ($_ -match 'hoztty')) })
    $rm = { Set-ItemProperty -LiteralPath $key -Name 'Path' -Value ($keep -join ';') -ErrorAction Stop }.GetNewClosure()
    New-Item2 -ItemId 'path-user' -Category 'path' -Title 'User PATH entry' `
        -Target $PathRegKey -Provenance 'MSI Environment component, self-healed by PathInstaller.zig on launch' `
        -Detail ($hits -join ' ; ') `
        -Remove $rm
}

function Add-Shortcuts {
    foreach ($pair in @(
            @{ Dir = $StartMenuDir; Tag = 'startmenu'; Prov = 'MSI Start Menu shortcut component' },
            @{ Dir = $StartupDir; Tag = 'startup'; Prov = 'legacy agent autostart dropped in Startup (removed by msi_ca.zig on upgrade)' }
        )) {
        $dir = [string]$pair.Dir
        if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { continue }
        $files = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'hoztty' }
        foreach ($f in $files) {
            $fp = $f.FullName
            $rm = { Remove-Item -LiteralPath $fp -Force -ErrorAction Stop }.GetNewClosure()
            New-Item2 -ItemId ($pair.Tag + '-' + $f.Name) -Category 'shortcut' `
                -Title ($f.Name) -Target $f.FullName -Provenance ([string]$pair.Prov) `
                -Detail (Format-Size $f.Length) `
                -Remove $rm
        }
    }
}

function Add-State {
    if (-not $StateDir -or -not (Test-Path -LiteralPath $StateDir)) { return }
    $bytes = 0
    $count = 0
    try {
        $all = Get-ChildItem -LiteralPath $StateDir -Recurse -File -ErrorAction SilentlyContinue
        foreach ($f in $all) { $bytes += $f.Length; $count++ }
    } catch { }
    $notable = @()
    foreach ($n in @('relay.env', 'account.dat', 'session-layout.json')) {
        if (Test-Path -LiteralPath (Join-Path $StateDir $n)) { $notable += $n }
    }
    $sd = $StateDir
    New-Item2 -ItemId 'state-dir' -Category 'state' -Title 'Session state and credentials' `
        -Target $StateDir `
        -Provenance 'written at runtime: relay.env, the DPAPI account store, session-layout.json, agent logs' `
        -Detail (("{0} files, {1}" -f $count, (Format-Size $bytes)) +
                 $(if ($notable.Count -gt 0) { '; holds ' + ($notable -join ', ') } else { '' })) `
        -Remove ({ Remove-Item -LiteralPath $sd -Recurse -Force -ErrorAction Stop }.GetNewClosure())
}

# Scheduled tasks are an install artifact class in their own right: msi_ca.zig
# deletes a `GhozttyAgent` task on upgrade (the pre-Run-key autostart mechanism),
# and go-loop-boot.ps1 registers the revive task. A box with one of those still
# armed is not clean, and nothing else on this screen would notice.
function Add-ScheduledTasks {
    if ($NoTaskScan) { return }
    $rows = @()
    try {
        $rows = @(& schtasks /query /fo csv /nh 2>$null)
    } catch { return }
    $seen = @{}
    foreach ($r in $rows) {
        if (-not $r) { continue }
        if ($r -notmatch 'hoztty') { continue }
        $name = $r.Split(',')[0].Trim('"')
        if (-not $name) { continue }
        if ($seen.ContainsKey($name)) { continue }
        $seen[$name] = $true
        $tn = $name
        $rm = { & schtasks /Delete /TN $tn /F 2>&1 | Out-Null }.GetNewClosure()
        New-Item2 -ItemId ('task-' + $name.TrimStart('\')) -Category 'task' `
            -Title ('Scheduled task ' + $name) -Target $name `
            -Provenance 'Task Scheduler entry registered by an installer or a repo script' `
            -Remove $rm
    }
}

function Add-Pipes {
    if ($NoPipeScan) { return }
    $names = @()
    try {
        $names = @([System.IO.Directory]::GetFiles('\\.\pipe\') |
                ForEach-Object { Split-Path $_ -Leaf } |
                Where-Object { $_ -match 'hoztty' })
    } catch { return }
    if ($names.Count -eq 0) { return }
    # A pipe is a live process's endpoint, never a file to delete: it is reported
    # so the verdict can say WHY something is still running, and it disappears
    # when its owner does.
    New-Item2 -ItemId 'pipes-live' -Category 'pipe' -Title 'Live IPC endpoints' `
        -Target '\\.\pipe\' -Provenance 'open named pipes owned by running ghoztty / ghoztty-agent processes' `
        -Detail ($names -join ', ') -Removable $false -Advisory $true `
        -Command 'close the owning windows, or stop the agent, and re-run inventory'
}

function Add-Processes($running) {
    if ($NoProcessScan) { return }
    if ($running.Count -eq 0) { return }
    $lines = @($running | ForEach-Object { ("{0} (pid {1})" -f $_.Path, $_.Pid) })
    New-Item2 -ItemId 'processes-live' -Category 'process' -Title 'Running Ghoztty processes' `
        -Target '(live)' -Provenance 'anything still running holds its own files open and blocks their removal' `
        -Detail ($lines -join '; ') -Removable $false -Advisory $true `
        -Command 'close those windows (this loop runs inside one) before removing the install they run from'
}

function Build-Inventory {
    $script:Items = @()
    $running = @(Get-RunningGhozttyPaths)
    Add-Installs $running
    Add-Arp $running
    Add-RegistryValues
    Add-PathEntry
    Add-Shortcuts
    Add-ScheduledTasks
    Add-State
    Add-Pipes
    Add-Processes $running
    return $script:Items
}

# ----------------------------------------------------------------- render ----

function Show-Inventory($items, $keeps) {
    $byCat = @{}
    foreach ($i in $items) {
        if (-not $byCat.ContainsKey($i.Category)) { $byCat[$i.Category] = @() }
        $byCat[$i.Category] += $i
    }
    $order = @('install', 'registry', 'path', 'shortcut', 'task', 'state', 'pipe', 'process')
    $titles = @{
        install  = 'INSTALLS'
        registry = 'REGISTRY'
        path     = 'PATH'
        shortcut = 'SHORTCUTS'
        task     = 'SCHEDULED TASKS'
        state    = 'STATE AND CREDENTIALS'
        pipe     = 'LIVE ENDPOINTS'
        process  = 'RUNNING PROCESSES'
    }
    foreach ($cat in $order) {
        if (-not $byCat.ContainsKey($cat)) { continue }
        Head ("  " + $titles[$cat])
        foreach ($i in $byCat[$cat]) {
            $mark = '[ ]'
            if ($i.Protected) { $mark = '[P]' }
            elseif ($keeps.ContainsKey($i.Id)) { $mark = '[K]' }
            elseif ($i.Blocked) { $mark = '[!]' }
            elseif ($i.Advisory) { $mark = '[i]' }
            Say ("  {0} {1,-22} {2}" -f $mark, $i.Id, $i.Title)
            Say ("        at    {0}" -f $i.Target)
            if ($i.Detail) { Say ("        what  {0}" -f $i.Detail) }
            Say ("        from  {0}" -f $i.Provenance)
            if ($i.Protected) {
                Warn ("        HELD  will not be offered for removal: {0}" -f $i.ProtectReason)
            } elseif ($keeps.ContainsKey($i.Id)) {
                Say ("        kept  {0}" -f $keeps[$i.Id])
            } elseif ($i.Blocked) {
                Warn ("        held  {0}" -f $i.Blocked)
            } elseif ($i.Command) {
                Say ("        do    {0}" -f $i.Command)
            }
        }
    }
    Say ''
    Say '  [ ] removable, unaccounted   [K] deliberately kept   [P] protected, never offered'
    Say '  [!] blocked while in use     [i] advisory, act on it yourself'
}

# An item is ACCOUNTED FOR when it is gone (not in the inventory at all),
# explicitly kept, or permanently protected. Everything else is what makes the
# box dirty - including a blocked item, since "still running" is not clean.
function Get-Unaccounted($items, $keeps) {
    $out = @()
    foreach ($i in $items) {
        if ($i.Protected) { continue }
        if ($keeps.ContainsKey($i.Id)) { continue }
        $out += $i
    }
    return $out
}

function Show-Verdict($items, $keeps) {
    $un = @(Get-Unaccounted $items $keeps)
    $kept = @($items | Where-Object { $keeps.ContainsKey($_.Id) })
    $prot = @($items | Where-Object { $_.Protected })
    Say ''
    if ($un.Count -eq 0) {
        Say ("CLEANUP VERDICT: CLEAN - nothing unaccounted for ({0} deliberately kept, {1} protected)" -f $kept.Count, $prot.Count)
        foreach ($k in $kept) { Say ("  kept      {0}  ({1})" -f $k.Id, $keeps[$k.Id]) }
        foreach ($p in $prot) { Say ("  protected {0}" -f $p.Id) }
        return 0
    }
    Bad ("CLEANUP VERDICT: {0} UNACCOUNTED ({1} deliberately kept, {2} protected)" -f $un.Count, $kept.Count, $prot.Count)
    foreach ($i in $un) {
        $note = ''
        if ($i.Blocked) { $note = ' - ' + $i.Blocked }
        elseif ($i.Advisory) { $note = ' - ' + $i.Command }
        Say ("  remains   {0}  {1}{2}" -f $i.Id, $i.Target, $note)
    }
    Say ''
    Say '  Remove them with `ghoztty-cleanup.ps1 clean`, or record a deliberate keep with'
    Say '  `ghoztty-cleanup.ps1 keep <id> -Reason "<why>"`.'
    return 1
}

# ------------------------------------------------------------------ clean ----

function Get-ScriptedAnswers {
    # Split on `,` and `;` here rather than leaning on the parameter binder:
    # `powershell -File script.ps1 -Answer a=y,b=n` hands the whole thing over as
    # ONE string (the -File parser does not build arrays), and repeating the
    # switch replaces rather than appends. Both of those fail by silently
    # answering the first item something that is not "y" - which reads as a user
    # who declined, so the removal simply does not happen and nothing complains.
    $map = @{}
    foreach ($chunk in $Answer) {
        if (-not $chunk) { continue }
        foreach ($a in $chunk.Split(@(',', ';'), [System.StringSplitOptions]::RemoveEmptyEntries)) {
            $ix = $a.IndexOf('=')
            if ($ix -lt 1) { continue }
            $map[$a.Substring(0, $ix).Trim()] = $a.Substring($ix + 1).Trim().ToLowerInvariant()
        }
    }
    return $map
}

function Invoke-Clean($items, $keeps) {
    $scripted = Get-ScriptedAnswers
    $nonInteractive = ($Answer.Count -gt 0)
    $removed = 0
    $failed = 0

    Head '  REMOVAL - each item is proposed; nothing is removed without a yes'
    foreach ($i in $items) {
        if ($i.Protected) {
            Warn ("  skip {0} - PROTECTED: {1}" -f $i.Id, $i.ProtectReason)
            continue
        }
        if ($keeps.ContainsKey($i.Id)) {
            Say ("  skip {0} - already recorded as a deliberate keep" -f $i.Id)
            continue
        }
        if (-not $i.Removable) {
            Say ("  note {0} - not removable from here: {1}" -f $i.Id, $i.Command)
            continue
        }
        if ($i.Blocked) {
            Warn ("  skip {0} - {1}" -f $i.Id, $i.Blocked)
            continue
        }

        $ans = 'n'
        if ($nonInteractive) {
            if ($scripted.ContainsKey($i.Id)) { $ans = $scripted[$i.Id] }
        } else {
            Say ''
            Say ("  {0}  {1}" -f $i.Id, $i.Title)
            Say ("      {0}" -f $i.Target)
            if ($i.Detail) { Say ("      {0}" -f $i.Detail) }
            $r = Read-Host '      remove this? [y/N]'
            if ($r) { $ans = $r.Trim().ToLowerInvariant() }
        }

        if ($ans -ne 'y' -and $ans -ne 'yes') {
            Say ("  keep {0}" -f $i.Id)
            continue
        }

        if ($DryRun) {
            Say ("  WOULD REMOVE {0}  {1}" -f $i.Id, $i.Target)
            continue
        }
        try {
            & $i.Remove
            Say ("  removed {0}  {1}" -f $i.Id, $i.Target)
            $removed++
        } catch {
            Bad ("  FAILED  {0}  {1}: {2}" -f $i.Id, $i.Target, $_.Exception.Message)
            $failed++
        }
    }
    Say ''
    Say ("  removed {0}, failed {1}" -f $removed, $failed)
    return $failed
}

# ------------------------------------------------------------------- main ----

$keeps = Read-Keeps

switch ($Action) {
    'keep' {
        if (-not $Id) { Bad 'keep needs an item id'; exit 2 }
        if (-not $Reason) {
            Bad 'keep needs -Reason: a keep with no reason cannot be read back as a decision'
            exit 2
        }
        $keeps[$Id] = $Reason
        Write-Keeps $keeps
        Say ("recorded deliberate keep: {0} - {1}" -f $Id, $Reason)
        exit 0
    }
    'unkeep' {
        if (-not $Id) { Bad 'unkeep needs an item id'; exit 2 }
        if ($keeps.ContainsKey($Id)) {
            $keeps.Remove($Id)
            Write-Keeps $keeps
            Say ("removed deliberate keep: {0}" -f $Id)
        } else {
            Say ("no deliberate keep recorded for {0}" -f $Id)
        }
        exit 0
    }
}

Say 'Ghoztty cleanup screen (T1188)'
Say ("  keep file: {0}" -f $KeepFile)
$items = @(Build-Inventory)
Say ("  found {0} artifact(s)" -f $items.Count)
Show-Inventory $items $keeps

if ($Action -eq 'inventory') {
    $un = @(Get-Unaccounted $items $keeps)
    Say ''
    Say ("  {0} unaccounted, {1} deliberately kept, {2} protected" -f $un.Count, ($items.Count - $un.Count - (@($items | Where-Object { $_.Protected })).Count), (@($items | Where-Object { $_.Protected })).Count)
    exit 0
}

if ($Action -eq 'clean') {
    $failed = Invoke-Clean $items $keeps
    # Re-audit from scratch: the verdict must be measured against the box as it
    # now is, not derived from what the removal loop believes it did.
    Head '  RE-AUDIT'
    $keeps = Read-Keeps
    $items = @(Build-Inventory)
    Say ("  found {0} artifact(s)" -f $items.Count)
    Show-Inventory $items $keeps
    $rc = Show-Verdict $items $keeps
    if ($failed -gt 0) { exit 1 }
    exit $rc
}

exit (Show-Verdict $items $keeps)
