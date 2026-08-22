# T956 acceptance - Stage 0 of the upstream pull plan: the fork-identity overlay.
#
#   powershell -NoProfile -File test\win32\fork-identity.ps1
#
# Non-interactive. Launches no Ghoztty and touches no user state: the subject is
# a text-rewriting script, so this reads the repo and does all of its writing
# inside throwaway trees under $env:TEMP.
#
# isolation: none - no ghoztty binary is run and no CLI verb is invoked; the
# only executable this script starts is git (T680 meta-check reads this marker).
#
# WHY IT EXISTS
#
# T879 measured that 52 of the 131 merge-risk files carry a fork delta of ten
# lines or fewer, almost all of it mechanical - a branding string, an apprt enum
# arm, a binary name. scripts\fork-identity.ps1 is that overlay written down, so
# a U-file merge becomes "take theirs, run apply, run check" instead of 52 hand
# resolutions repeated at every stage.
#
# A rewriting script is exactly the kind of tool that is easy to believe and
# hard to trust, so every section here is an assertion about BEHAVIOUR:
#
# A - `check` is clean on this repo. The tree already carries the identity, so
#     any finding here is a false positive in a rule, and false positives are
#     how a verifier stops being read.
# B - `apply` is a no-op on a tree that is already overlaid, through the REAL
#     write path rather than -DryRun. Idempotence is what makes it safe to run
#     the overlay again after every future merge stage.
# C - the measurement, from the fork point. The 52 U-files are re-derived from
#     the plan's own appendix, checked out at 063ac3ecc, overlaid, and compared
#     against HEAD. The number this reports is the honest version of the plan's
#     claim: how many of the 52 the script really does resolve on its own, and
#     which files still need a human. It is asserted against a baseline so a
#     rule regression is red rather than merely quieter.
# D - the negative control. Every rule is fired at a fixture carrying the
#     upstream form; a rule that silently stopped matching would otherwise pass
#     A and B forever, because both of those are assertions that nothing
#     happened.
# E - the safety control, which is the half that matters most. A blanket
#     ghostty -> ghoztty rename would pass D. This fixture carries the strings
#     that must SURVIVE - the TERM value, the GHOSTTY_* variable names,
#     upstream's repository URL, the config directory path, the Xcode module
#     name, a .none arm in a switch that is not on app_runtime, and one that is
#     but already has its own .win32 arm - and asserts the tree comes back
#     byte-identical.
param(
    [string]$Repo,
    [switch]$NegativeControl
)

$ErrorActionPreference = 'Continue'
if (-not $Repo) { $Repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }

$script:failures = 0
$script:passes = 0
$script:skips = 0
function Assert($name, $cond, $detail = '') {
    if ($cond) { Write-Host "  PASS $name"; $script:passes++ }
    else { Write-Host "  FAIL $name $detail" -ForegroundColor Red; $script:failures++ }
}
function Skip($name, $why) { Write-Host "  SKIP $name - $why" -ForegroundColor Yellow; $script:skips++ }
function Say($m) { Write-Host $m }

$Overlay = Join-Path $Repo 'scripts\fork-identity.ps1'
$PlanRelative = 'docs\design\windows-parity-upstream-pull-plan.md'
$ForkPoint = '063ac3ecc'

# The number of the 52 U-files that the overlay reproduces byte-for-byte from
# the fork point. Measured, not aspirational: 24 of the 52 also carry real work
# (the selectively-applied CI guards, the PaneView type rename, and genuine
# feature deltas that happen to live in a small file), and no identity rule can
# or should produce those. Raise this when a rule earns it.
$ReproBaseline = 28

function Invoke-GitIn {
    param([string]$At, [string[]]$GitArgs)
    $ErrorActionPreference = 'SilentlyContinue'
    $out = @(& git -C $At @GitArgs 2>$null)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n"); Lines = $out }
}

# Per-record capture (T883): a merged 2>&1 stream on a native command is
# formatted to the host's buffer width, and an assertion over that text is an
# assertion about the console it ran in.
function Invoke-Overlay {
    param([string[]]$OverlayArgs)
    $ErrorActionPreference = 'SilentlyContinue'
    $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $Overlay @OverlayArgs 2>$null)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n"); Lines = $out }
}

function Write-Fixture {
    param([string]$Root, [string]$Relative, [string]$Text)
    $full = Join-Path $Root ($Relative -replace '/', '\')
    $dir = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($full, $Text, (New-Object System.Text.UTF8Encoding($false)))
    return $full
}

function Get-FileHashHex {
    param([string]$FullPath)
    return (Get-FileHash -LiteralPath $FullPath -Algorithm SHA256).Hash
}

# The U-file list comes out of the plan's own appendix, so a regenerated
# inventory moves this harness with it instead of leaving it asserting over a
# list nobody merges.
function Get-UFiles {
    $path = Join-Path $Repo $PlanRelative
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $files = New-Object System.Collections.ArrayList
    foreach ($line in (Get-Content -LiteralPath $path)) {
        $m = [regex]::Match($line, '^\|\s*`([^`]+)`\s*\|[^|]*\|[^|]*\|[^|]*\|\s*U\s*\|')
        if ($m.Success) { [void]$files.Add($m.Groups[1].Value) }
    }
    return $files
}

$sandbox = Join-Path $env:TEMP "ghoztty-fork-identity-$PID"
if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null

try {

    # -----------------------------------------------------------------------
    Say ''
    Say 'A. the verifier is clean on this repo'
    # -----------------------------------------------------------------------

    Assert 'A0 scripts\fork-identity.ps1 exists' (Test-Path -LiteralPath $Overlay)

    $chk = Invoke-Overlay @('check', '-Path', $Repo)
    Assert 'A1 check exits 0 on the working tree' ($chk.Code -eq 0) "exit=$($chk.Code)"
    Assert 'A2 check says CLEAN' ($chk.Text -match 'CLEAN') $chk.Text

    $rules = Invoke-Overlay @('rules', '-Path', $Repo, '-Json')
    Assert 'A3 rules -Json exits 0' ($rules.Code -eq 0) "exit=$($rules.Code)"
    # Assign, THEN wrap. PS 5.1's ConvertFrom-Json emits a JSON array as one
    # pipeline item, so `@($text | ConvertFrom-Json)` counts 1 no matter how
    # many rules there are - which reads as "the rule table collapsed".
    $ruleObj = @()
    try {
        $parsedRules = $rules.Text | ConvertFrom-Json
        $ruleObj = @($parsedRules)
    } catch { }
    Assert 'A4 rules -Json parses and names every rule' `
    ($ruleObj.Count -ge 8 -and @($ruleObj | Where-Object { $_.Name -eq 'apprt-arm' }).Count -eq 1) `
        "count=$($ruleObj.Count)"
    Assert 'A5 every rule carries a why' `
    (@($ruleObj | Where-Object { -not $_.Why }).Count -eq 0)

    # -----------------------------------------------------------------------
    Say ''
    Say 'B. apply is a no-op on a tree that already carries the identity'
    # -----------------------------------------------------------------------
    # Through the real write path, not -DryRun: a rule that rewrote in place
    # would still report "no change" if the only evidence were a dry run.

    $uFiles = @(Get-UFiles)
    Assert 'B0 the plan still lists U-files' ($uFiles.Count -gt 0) "count=$($uFiles.Count)"

    $headTree = Join-Path $sandbox 'head'
    $copied = 0
    foreach ($f in $uFiles) {
        $src = Join-Path $Repo ($f -replace '/', '\')
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
        Write-Fixture $headTree $f ([System.IO.File]::ReadAllText($src)) | Out-Null
        $copied++
    }
    Assert 'B1 U-files copied out of the working tree' ($copied -ge 40) "copied=$copied"

    $before = @{}
    foreach ($f in (Get-ChildItem -LiteralPath $headTree -Recurse -File)) { $before[$f.FullName] = Get-FileHashHex $f.FullName }

    $ap = Invoke-Overlay @('apply', '-Path', $headTree)
    Assert 'B2 apply exits 0' ($ap.Code -eq 0) "exit=$($ap.Code)"
    Assert 'B3 apply reports no change' ($ap.Text -match 'no change') $ap.Text

    $mutated = @()
    foreach ($f in (Get-ChildItem -LiteralPath $headTree -Recurse -File)) {
        if ($before[$f.FullName] -ne (Get-FileHashHex $f.FullName)) { $mutated += $f.FullName }
    }
    Assert 'B4 every file is byte-identical after apply' ($mutated.Count -eq 0) ($mutated -join ', ')

    # -----------------------------------------------------------------------
    Say ''
    Say 'C. the measurement: what the overlay really resolves, from the fork point'
    # -----------------------------------------------------------------------

    $haveForkPoint = (Invoke-GitIn $Repo @('cat-file', '-t', $ForkPoint)).Text.Trim() -eq 'commit'
    if (-not $haveForkPoint) {
        Skip 'C1 reproduction measurement' "$ForkPoint is not in this object store (run scripts\upstream-remote.ps1 ensure)"
    } else {
        $forkTree = Join-Path $sandbox 'forkpoint'
        $staged = 0
        foreach ($f in $uFiles) {
            $blob = Invoke-GitIn $Repo @('show', "${ForkPoint}:$f")
            if ($blob.Code -ne 0) { continue }
            Write-Fixture $forkTree $f (($blob.Lines -join "`n") + "`n") | Out-Null
            $staged++
        }
        Assert 'C1 U-files staged at the fork point' ($staged -ge 40) "staged=$staged"

        $ap2 = Invoke-Overlay @('apply', '-Path', $forkTree)
        Assert 'C2 apply exits 0 on the fork-point tree' ($ap2.Code -eq 0) "exit=$($ap2.Code)"
        Assert 'C3 apply actually rewrote files' ($ap2.Text -match 'rewrote \d+ file') $ap2.Text

        # git's `show` gives LF; the working tree may hold CRLF. The subject
        # here is CONTENT, so both sides are compared with line endings and
        # trailing whitespace-only differences normalized away.
        function Get-Normalized {
            param([string]$Text)
            return ((($Text -replace "`r`n", "`n").TrimEnd("`n")))
        }

        $repro = 0
        $residual = New-Object System.Collections.ArrayList
        foreach ($f in $uFiles) {
            $applied = Join-Path $forkTree ($f -replace '/', '\')
            if (-not (Test-Path -LiteralPath $applied)) { continue }
            $head = Invoke-GitIn $Repo @('show', "HEAD:$f")
            if ($head.Code -ne 0) { continue }
            $a = Get-Normalized ([System.IO.File]::ReadAllText($applied))
            $h = Get-Normalized (($head.Lines -join "`n"))
            if ($a -ceq $h) { $repro++ } else { [void]$residual.Add($f) }
        }

        Say ("     reproduced exactly: {0} of {1}" -f $repro, $staged)
        Say  '     residual (real work, not identity):'
        foreach ($r in $residual) { Say ("       {0}" -f $r) }

        Assert "C4 at least $ReproBaseline of the U-files reproduce from the fork point" `
        ($repro -ge $ReproBaseline) "reproduced=$repro baseline=$ReproBaseline"

        $chk2 = Invoke-Overlay @('check', '-Path', $forkTree)
        Assert 'C5 check is clean on the overlaid fork-point tree' ($chk2.Code -eq 0) $chk2.Text

        # The point of the exercise: an untouched upstream tree must FAIL the
        # verifier. If it did not, C5 would be asserting nothing.
        $rawTree = Join-Path $sandbox 'forkpoint-raw'
        foreach ($f in $uFiles) {
            $blob = Invoke-GitIn $Repo @('show', "${ForkPoint}:$f")
            if ($blob.Code -ne 0) { continue }
            Write-Fixture $rawTree $f (($blob.Lines -join "`n") + "`n") | Out-Null
        }
        $chk3 = Invoke-Overlay @('check', '-Path', $rawTree)
        Assert 'C6 check FAILS on the same tree before the overlay' ($chk3.Code -eq 1) "exit=$($chk3.Code)"
    }

    # -----------------------------------------------------------------------
    Say ''
    Say 'D. negative control: every rule fires on the upstream form'
    # -----------------------------------------------------------------------

    $ghost = ([string][char]0xD83D) + ([string][char]0xDC7B)
    $dTree = Join-Path $sandbox 'rules'

    Write-Fixture $dTree 'nix/tests.nix' 'systemctl("enable app-com.mitchellh.ghostty-debug.service")' | Out-Null
    Write-Fixture $dTree 'macos/Sources/Ghostty/Surface View/SurfaceView+Transferable.swift' `
        '    static let ghosttySurfaceId = UTType(exportedAs: "com.mitchellh.ghosttySurfaceId")' | Out-Null
    Write-Fixture $dTree 'macos/Sources/Features/Secure Input/SecureInput.swift' `
        "    private static let logger = Logger(`n        subsystem: Bundle.main.bundleIdentifier!,`n        category: String(describing: SecureInput.self)`n    )" | Out-Null
    Write-Fixture $dTree 'macos/Sources/Features/Update/UpdateDelegate.swift' `
    ('        case .tip: return "https://tip.files.ghostty.org/appcast.xml"' + "`n" + `
            '        case .stable: return "https://release.files.ghostty.org/appcast.xml"') | Out-Null
    Write-Fixture $dTree 'macos/Sources/Features/Terminal/Window Styles/W.swift' `
    ('    @Published var title: String = "' + $ghost + ' Ghostty"') | Out-Null
    Write-Fixture $dTree 'macos/Sources/App/iOS/iOSApp.swift' '            Text("Ghostty")' | Out-Null
    Write-Fixture $dTree 'src/shell-integration/bash/ghostty.bash' `
    ('        if "$GHOSTTY_BIN_DIR/ghostty" +ssh-cache --host="$h" >/dev/null 2>&1; then' + "`n" + `
            '          builtin echo "Warning: ghostty command not available for cache management." >&2') | Out-Null
    Write-Fixture $dTree 'src/shell-integration/nushell/vendor/autoload/ghostty.nu' `
        '      let ghostty = ($env.GHOSTTY_BIN_DIR? | default "") | path join "ghostty"' | Out-Null
    Write-Fixture $dTree 'src/shell-integration/elvish/lib/ghostty-integration.elv' `
        '        var ghostty = $E:GHOSTTY_BIN_DIR/"ghostty"' | Out-Null
    Write-Fixture $dTree 'src/build/webgen/main_commands.zig' `
        '                else => try writer.writeAll("ghostty +" ++ field.name ++ "\n"),' | Out-Null
    Write-Fixture $dTree 'src/global.zig' '        std.log.info("ghostty version={s}", .{build_config.version_string});' | Out-Null
    Write-Fixture $dTree 'src/font/face.zig' `
    ("    pub const getGObjectType = switch (build_config.app_runtime) {`n" + `
            "        .gtk => @import(`"gobject`").ext.defineEnum(DesiredSize, .{ .name = `"GhosttyFontDesiredSize`" }),`n" + `
            "`n" + `
            "        .none => void,`n" + `
            "    };") | Out-Null
    Write-Fixture $dTree 'src/apprt.zig' `
    ("pub const runtime = switch (build_config.app_runtime) {`n" + `
            "    .none => none,`n" + `
            "    .gtk => gtk,`n" + `
            "};") | Out-Null

    $dChk = Invoke-Overlay @('check', '-Path', $dTree, '-Json')
    Assert 'D1 check FAILS on the upstream fixture' ($dChk.Code -eq 1) "exit=$($dChk.Code)"
    $dObj = $null
    try { $dObj = $dChk.Text | ConvertFrom-Json } catch { }
    $firedRules = @()
    if ($dObj) { $firedRules = @($dObj.findings | ForEach-Object { $_.Rule } | Sort-Object -Unique) }
    foreach ($r in @('surface-uti', 'bundle-id', 'logger-subsystem', 'appcast-url', 'display-name',
            'display-name-literal', 'shell-bin', 'cli-name', 'apprt-arm')) {
        Assert "D2:$r reports on the upstream form" ($firedRules -contains $r) ("fired=" + ($firedRules -join ','))
    }
    # src\apprt.zig maps members to modules, so no .none arm can be widened for
    # it; the verifier must still say the switch needs an arm.
    $handWritten = @($dObj.findings | Where-Object { $_.File -eq 'src/apprt.zig' -and $_.Detail -match 'hand-written' })
    Assert 'D3 a module-mapping switch is reported as needing a hand-written arm' ($handWritten.Count -eq 1)

    $dApply = Invoke-Overlay @('apply', '-Path', $dTree)
    Assert 'D4 apply exits 0 on the fixture' ($dApply.Code -eq 0) "exit=$($dApply.Code)"

    function Read-Fixture { param([string]$Rel) return [System.IO.File]::ReadAllText((Join-Path $dTree ($Rel -replace '/', '\'))) }

    Assert 'D5 bundle id rewritten' ((Read-Fixture 'nix/tests.nix') -cmatch 'app-com\.dzearing\.ghoztty-debug')
    Assert 'D6 surface UTI rewritten to the fork spelling, not a prefix splice' `
    ((Read-Fixture 'macos/Sources/Ghostty/Surface View/SurfaceView+Transferable.swift') -cmatch 'com\.dzearing\.ghoztty\.surfaceId')
    Assert 'D7 logger subsystem rewritten' `
    ((Read-Fixture 'macos/Sources/Features/Secure Input/SecureInput.swift') -cmatch 'Bundle\.loggerSubsystem')
    Assert 'D8 appcast feed rewritten to the fork feed' `
    ((Read-Fixture 'macos/Sources/Features/Update/UpdateDelegate.swift') -cmatch 'dzearing\.github\.io/ghoztty/appcast-tip\.xml')
    Assert 'D9 window title rewritten, emoji preserved' `
    ((Read-Fixture 'macos/Sources/Features/Terminal/Window Styles/W.swift') -cmatch ([regex]::Escape($ghost) + ' Ghoztty'))
    Assert 'D10 display literal rewritten' ((Read-Fixture 'macos/Sources/App/iOS/iOSApp.swift') -cmatch 'Text\("Ghoztty"\)')
    $bash = Read-Fixture 'src/shell-integration/bash/ghostty.bash'
    Assert 'D11 shell binary name rewritten' ($bash -cmatch 'GHOSTTY_BIN_DIR/ghoztty')
    Assert 'D12 shell warning text rewritten' ($bash -cmatch 'ghoztty command not available')
    Assert 'D13 nushell path join rewritten' `
    ((Read-Fixture 'src/shell-integration/nushell/vendor/autoload/ghostty.nu') -cmatch 'path join "ghoztty"')
    Assert 'D14 elvish quoted binary rewritten' `
    ((Read-Fixture 'src/shell-integration/elvish/lib/ghostty-integration.elv') -cmatch 'GHOSTTY_BIN_DIR/"ghoztty"')
    Assert 'D15 generated command name rewritten' `
    ((Read-Fixture 'src/build/webgen/main_commands.zig') -cmatch '"ghoztty \+"')
    Assert 'D16 startup log line rewritten' ((Read-Fixture 'src/global.zig') -cmatch 'ghoztty version=\{s\}')
    Assert 'D17 apprt arm widened' ((Read-Fixture 'src/font/face.zig') -cmatch '\.none, \.win32 => void,')
    Assert 'D18 module-mapping switch left alone' ((Read-Fixture 'src/apprt.zig') -cmatch '(?m)^\s*\.none => none,\s*$')

    $dChk2 = Invoke-Overlay @('check', '-Path', $dTree, '-Json')
    $dObj2 = $null
    try { $dObj2 = $dChk2.Text | ConvertFrom-Json } catch { }
    $left = @()
    if ($dObj2) { $left = @($dObj2.findings | ForEach-Object { $_.Rule } | Sort-Object -Unique) }
    Assert 'D19 only the hand-written arm survives a second check' `
    ($left.Count -eq 1 -and $left[0] -eq 'apprt-arm') ("left=" + ($left -join ','))

    $dApply2 = Invoke-Overlay @('apply', '-Path', $dTree)
    Assert 'D20 a second apply changes nothing (idempotent)' ($dApply2.Text -match 'no change') $dApply2.Text

    # -----------------------------------------------------------------------
    Say ''
    Say 'E. safety control: the strings that must SURVIVE'
    # -----------------------------------------------------------------------
    # A blanket ghostty -> ghoztty rename passes every assertion in D. This is
    # the fixture that tells the two apart.

    $eTree = Join-Path $sandbox 'safe'

    Write-Fixture $eTree 'src/shell-integration/bash/ghostty.bash' `
    ("# TERM must match terminfo, and the variable names are a contract:`n" + `
            "if [ `"`$TERM`" = `"xterm-ghostty`" ]; then`n" + `
            "  export GHOSTTY_BIN_DIR GHOSTTY_RESOURCES_DIR GHOSTTY_SHELL_FEATURES`n" + `
            "  builtin source `"`$GHOSTTY_RESOURCES_DIR/shell-integration/bash/ghostty.bash`"`n" + `
            "fi`n" + `
            "__ghostty_precmd() { :; }") | Out-Null
    Write-Fixture $eTree 'dist/linux/com.dzearing.ghoztty.metainfo.xml.in' `
        '    <value key="flathub::manifest">https://github.com/ghostty-org/ghostty/blob/x/flatpak/com.mitchellh.ghostty.yml</value>' | Out-Null
    Write-Fixture $eTree 'po/de.po' `
    ("# German translations for com.mitchellh.ghostty package`n" + `
            '"Project-Id-Version: com.mitchellh.ghostty\n"') | Out-Null
    Write-Fixture $eTree 'macos/Sources/Features/Command Palette/PaletteHistory.swift' `
        '        configDir = (xdg as NSString).appendingPathComponent("ghostty")' | Out-Null
    Write-Fixture $eTree 'macos/Sources/Features/Terminal/Window Styles/Terminal.xib' `
    ('        <window title="' + $ghost + ' Ghoztty" customModule="Ghostty" customModuleProvider="target"/>') | Out-Null
    Write-Fixture $eTree 'macos/Sources/Ghostty/GhosttyPackageMeta.swift' `
    ("        Bundle.main.bundleIdentifier ?? `"com.dzearing.ghoztty`"`n" + `
            "        category: `"ghostty`"") | Out-Null
    Write-Fixture $eTree 'dist/macos/update_appcast_tip.py' `
        '    elem.set("url", f"https://tip.files.ghostty.org/{commit_long}/Ghostty.dmg")' | Out-Null
    # A .none arm in a switch that is NOT on the app runtime: 18 of the 29 such
    # arms at the fork point are this shape (box drawing, style, kitty graphics).
    Write-Fixture $eTree 'src/font/sprite/draw/box.zig' `
    ("    switch (self.thickness) {`n" + `
            "        .none => {},`n" + `
            "        .light => self.draw(canvas),`n" + `
            "    }") | Out-Null
    # An app_runtime switch that already carries its own .win32 arm: folding
    # .none into it would drop the Windows system libraries from every link.
    Write-Fixture $eTree 'src/build/SharedDeps.zig' `
    ("        switch (self.config.app_runtime) {`n" + `
            "            .none => {},`n" + `
            "            .gtk => try self.addGtkNg(step),`n" + `
            "            .win32 => {`n" + `
            "                step.linkSystemLibrary2(`"opengl32`", .{});`n" + `
            "            },`n" + `
            "        }") | Out-Null

    $eBefore = @{}
    foreach ($f in (Get-ChildItem -LiteralPath $eTree -Recurse -File)) { $eBefore[$f.FullName] = Get-FileHashHex $f.FullName }

    $eChk = Invoke-Overlay @('check', '-Path', $eTree, '-Json')
    $eObj = $null
    try { $eObj = $eChk.Text | ConvertFrom-Json } catch { }
    $eFindings = @()
    if ($eObj) { $eFindings = @($eObj.findings) }
    Assert 'E1 check reports nothing on the must-survive fixture' ($eFindings.Count -eq 0) `
    (@($eFindings | ForEach-Object { "$($_.File):$($_.Line) [$($_.Rule)]" }) -join '; ')
    Assert 'E2 check exits 0 there' ($eChk.Code -eq 0) "exit=$($eChk.Code)"

    $eApply = Invoke-Overlay @('apply', '-Path', $eTree)
    Assert 'E3 apply reports no change' ($eApply.Text -match 'no change') $eApply.Text
    $eMutated = @()
    foreach ($f in (Get-ChildItem -LiteralPath $eTree -Recurse -File)) {
        if ($eBefore[$f.FullName] -ne (Get-FileHashHex $f.FullName)) { $eMutated += $f.Name }
    }
    Assert 'E4 every must-survive file is byte-identical' ($eMutated.Count -eq 0) ($eMutated -join ', ')

    if ($NegativeControl) {
        Say ''
        Say 'NEGATIVE CONTROL: asserting the overlay is ABSENT - a wired repo MUST fail this'
        $nc = Invoke-Overlay @('check', '-Path', $Repo)
        Assert 'N1 check does NOT report the working tree clean (inverted)' ($nc.Code -ne 0)
    }

} catch {
    # A crash mid-run used to fall straight through to the verdict and print ALL
    # PASS over the handful of assertions that had run before it - the shape
    # verdict-exit-audit exists to distrust.
    Write-Host "  FAIL harness crashed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "    at $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
    $script:failures++
} finally {
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

# A clean green run stamps the covered files (T783) so scripts\guard-due.ps1 can
# answer "has anybody run this against the overlay as it now stands?". A red run
# - or the -NegativeControl run, which is red by construction - leaves the stamp
# alone, and a run with skipped sections does not stamp at all.
if ($script:failures -eq 0 -and $script:skips -eq 0 -and -not $NegativeControl) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'scripts\guard-due.ps1') `
        update -Guard fork-identity -Repo $Repo 2>&1 | ForEach-Object { "  $_" }
}

Say ''
if ($script:failures -eq 0) {
    $note = ''
    if ($script:skips -gt 0) { $note = " / $script:skips skipped" }
    Say "FORK-IDENTITY: ALL PASS ($script:passes$note)"
    exit 0
} else {
    Say "FORK-IDENTITY: $script:failures FAILURE(S) / $script:passes passed"
    exit 1
}
