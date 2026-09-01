# The THROWAWAY PRODUCT IDENTITY - shared by every harness that installs a real
# published Ghoztty package with a real msiexec (T1194, then T1209).
#
# Why it exists at all: this repo's first non-negotiable is that a test never
# touches the user's installed Ghoztty, and for a long time that ruled out the
# one thing an installer harness most wants to do - run the installer. The way
# through is `scripts\msi-test-identity.ps1`, which rewrites a published
# `Ghoztty-<v>-x64.msi` into a product with its own ProductCode, UpgradeCode,
# install directory, component GUIDs, registry key and Start Menu name. The
# payload, the sequences and the custom actions stay the published ones; only
# the identity moves. Installing the result lands in
# `%LOCALAPPDATA%\Programs\<Identity>` and cannot upgrade, remove or refcount
# anything belonging to the user's Ghoztty.
#
# Everything in here is scoped to ONE install directory, passed in by the
# caller, and `Stop-ThrowawayInstances` REFUSES a directory that is the user's
# install (or inside it) rather than merely preferring not to be pointed there -
# the same shape `Stop-RepoGhoztty` uses for the repo build, and for the same
# reason: a filter that can be pointed at the wrong thing eventually is.
#
# This is deliberately NOT `lib\CleanSlate.ps1`. That library's guarantee is
# "the exe is under the repo" and it refuses anything else, which is exactly
# right for the ~290 harnesses that drive `zig-out`; the two harnesses here
# drive a build that by definition is NOT under the repo, because it arrived
# through a real installer.

Set-StrictMode -Off

# Per-user MSI products register their Apps & Features entry through the
# Windows Installer service, and depending on package platform and Windows
# version the key lands in HKCU, HKLM 64-bit or HKLM WOW6432Node. Search all
# three (the same three msi-upgrade.ps1 learned to search).
$script:ThrowawayUninstallRoots = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

function Get-ThrowawayInstallDir {
    <#
      Where Windows Installer will put the throwaway product. Resolved from the
      SHELL's idea of LocalAppData, which a caller running under
      `Set-GhozttyTestIsolation -ReleaseSandbox` has moved out from under
      $env:LOCALAPPDATA - so a caller must capture the real one BEFORE it
      sandboxes and hand it in here, or every path assertion points at the
      sandbox and passes while measuring nothing.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RealLocalAppData,
        [Parameter(Mandatory = $true)][string]$Identity
    )
    return (Join-Path $RealLocalAppData "Programs\$Identity")
}

function Get-ThrowawayUserInstallDir {
    param([Parameter(Mandatory = $true)][string]$RealLocalAppData)
    return (Join-Path $RealLocalAppData 'Programs\Ghoztty')
}

function Get-MsiProperty {
    <#
      One row out of a package's Property table, without msitools and without
      Docker - the Windows Installer automation object is already on every box
      that can run an MSI at all.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Msi,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $inst = New-Object -ComObject WindowsInstaller.Installer
    $db = $inst.OpenDatabase($Msi, 0)
    $v = $db.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$Name'")
    [void]$v.Execute()
    $r = $v.Fetch()
    $out = if ($null -eq $r) { '' } else { [string]$r.StringData(1) }
    [void]$v.Close()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($v)
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($db)
    return $out
}

function Get-ThrowawayPackage {
    <#
      A published release, rewritten to the throwaway identity. Downloads the
      package once into $Work and rewrites it once; both steps are cached, so a
      second harness in the same session pays neither.

      Returns the rewritten path, or $null when the published package could not
      be obtained (no network, no `gh`, no such release). A caller must treat
      $null as "this run proved nothing" rather than as a failure of the
      product - see `Write-TestAssertedNothing`.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Work,
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter(Mandatory = $true)][string]$Repo,
        # Register the SAME payload at a lower ProductVersion, so one published
        # package can act as its own predecessor. See the parameter comment in
        # scripts\msi-test-identity.ps1 for why that is sometimes the only
        # honest pair to test an upgrade with.
        [string]$AsProductVersion = ''
    )
    New-Item -ItemType Directory -Force $Work | Out-Null
    $published = Join-Path $Work "Ghoztty-$Version-x64.msi"
    $suffix = if ($AsProductVersion) { "-$AsProductVersion" } else { '' }
    $rewritten = Join-Path $Work "test-$Version$suffix.msi"
    if (-not (Test-Path $published)) {
        Write-Host "  downloading $Tag ..."
        & gh release download $Tag --repo dzearing/ghoztty --pattern '*.msi' --dir $Work --clobber 2>&1 | Out-Null
    }
    if (-not (Test-Path $published)) { return $null }
    if (-not (Test-Path $rewritten) -or
        (Get-Item $rewritten).LastWriteTimeUtc -lt (Get-Item $published).LastWriteTimeUtc) {
        $rewriteArgs = @('-Msi', $published, '-Out', $rewritten, '-Identity', $Identity)
        if ($AsProductVersion) { $rewriteArgs += @('-ProductVersion', $AsProductVersion) }
        & powershell -NoProfile -File (Join-Path $Repo 'scripts\msi-test-identity.ps1') @rewriteArgs 2>&1 | Out-Null
    }
    if (-not (Test-Path $rewritten)) { return $null }
    return $rewritten
}

function Get-ThrowawayUninstallEntries {
    param([Parameter(Mandatory = $true)][string]$Identity)
    $out = @()
    foreach ($root in $script:ThrowawayUninstallRoots) {
        foreach ($k in @(Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if ($p -and $p.DisplayName -eq $Identity) { $out += $k }
        }
    }
    # Returned plain, and every caller wraps the call in `@(...)`: `return ,@()`
    # would look right and be wrong - PS 5.1 unrolls the outer array on output
    # and hands an EMPTY result to `@(...)` as ONE element, so "no product is
    # registered" would count as one registered product.
    return $out
}

function Get-ThrowawayProcesses {
    <#
      Processes running out of $InstallDir, path-exact. The user's Ghoztty is a
      different image in a different directory and is never a candidate.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [string[]]$Names = @('ghoztty', 'ghoztty-agent')
    )
    $out = @()
    foreach ($name in $Names) {
        foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $path = try { $p.Path } catch { $null }
            if ($path -and $path.StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase)) { $out += $p }
        }
    }
    # Plain, for the reason spelled out in Get-ThrowawayUninstallEntries.
    return $out
}

function Assert-ThrowawayInstallDir {
    <#
      The refusal that makes this library safe to hand a directory. A caller
      that computes the install directory wrongly - or a default that drifts -
      would otherwise point every kill and every delete in here at the user's
      terminal.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [Parameter(Mandatory = $true)][string]$RealLocalAppData
    )
    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        throw 'ThrowawayProduct: an empty install directory would match every process'
    }
    $user = Get-ThrowawayUserInstallDir -RealLocalAppData $RealLocalAppData
    $norm = $InstallDir.TrimEnd('\')
    $userNorm = $user.TrimEnd('\')
    if ($norm.Equals($userNorm, [StringComparison]::OrdinalIgnoreCase) -or
        $norm.StartsWith($userNorm + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "ThrowawayProduct: refusing to operate on the user's install ($InstallDir)"
    }
    return $true
}

function Stop-ThrowawayInstances {
    <#
      Stop what this harness installed, and only that.

      -AppOnly leaves the agent and its per-session pty-host holders alone,
      which is what a real update does: the app closes, the holders keep the
      user's shells alive, and the installer renames their image aside rather
      than asking the Restart Manager to terminate them.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [Parameter(Mandatory = $true)][string]$RealLocalAppData,
        [switch]$AppOnly,
        [int]$SettleMs = 500
    )
    [void](Assert-ThrowawayInstallDir -InstallDir $InstallDir -RealLocalAppData $RealLocalAppData)
    $names = if ($AppOnly) { @('ghoztty') } else { @('ghoztty', 'ghoztty-agent') }
    foreach ($p in @(Get-ThrowawayProcesses -InstallDir $InstallDir -Names $names)) {
        try { $p.Kill() } catch {}
    }
    if ($SettleMs -gt 0) { Start-Sleep -Milliseconds $SettleMs }
}

function Remove-ThrowawayProduct {
    param(
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [Parameter(Mandatory = $true)][string]$RealLocalAppData
    )
    [void](Assert-ThrowawayInstallDir -InstallDir $InstallDir -RealLocalAppData $RealLocalAppData)
    foreach ($e in @(Get-ThrowawayUninstallEntries -Identity $Identity)) {
        $code = Split-Path $e.PSPath -Leaf
        Start-Process msiexec.exe -ArgumentList @('/x', $code, '/qn') -Wait | Out-Null
    }
    if (Test-Path $InstallDir) {
        Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-ThrowawayExeVersion {
    <#
      `+version` over whatever endpoint the caller isolated onto, so the answer
      is about THIS binary and never about the user's running app.

      Ask the `.com` console twin when it is there: ghoztty.exe is
      GUI-subsystem in a release build and has no console to print to. And the
      banner still says "Ghostty" - the fork kept upstream's wording in
      src/cli/version.zig - so the version is read from the `- version:` line,
      which is spelled the same either way.
    #>
    param([Parameter(Mandatory = $true)][string]$Exe)
    if (-not (Test-Path $Exe)) { return '' }
    $com = [IO.Path]::ChangeExtension($Exe, '.com')
    $bin = if (Test-Path $com) { $com } else { $Exe }
    # Stringified before Out-String (T883): a merged stream handed to the
    # formatter is wrapped at the HOST's width, so the `- version:` line can
    # arrive folded and the match silently fails on a narrow console.
    $out = & $bin +version 2>&1 | ForEach-Object { $_.ToString() } | Out-String
    if ($out -match '(?m)^\s*-\s*version:\s*(\d+\.\d+\.\d+)') { return $Matches[1] }
    if ($out -match '(?m)^Gho[sz]tty\s+(\d+\.\d+\.\d+)') { return $Matches[1] }
    return ''
}

function Get-UserPathEntryCount {
    $p = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if (-not $p) { return 0 }
    return @($p -split ';' | Where-Object { $_ -ne '' }).Count
}
