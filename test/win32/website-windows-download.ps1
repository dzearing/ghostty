# The website offers the Windows build, and keeps offering the right one (T39).
#
# T38 made every release PRODUCE the Windows artifacts. This is the other
# half: a user who lands on the site can actually get them. The failure mode
# it guards is the one T38 already paid for once -- the macOS channel reached
# v1.28.0 while Windows sat at win-v1.4.1, because the Windows half of the
# release needed a human to remember it. So the site's Windows links are NOT
# hand-edited: release-windows.yml retargets them from the release it just
# published, using dist/website/update-windows-links.py.
#
# What this asserts:
#
#   A  page shape: the Windows card sits beside the macOS card, its href is a
#      real win-v<version> asset whose FILENAME carries the same version plus
#      the arch, the portable ZIP alternative is offered, and the minimum-OS
#      note is there, and the unsigned/SmartScreen caveat warns the user
#      before they download rather than after the scary dialog (T349). Also
#      that the card and the caveat reuse existing CSS classes rather than
#      inventing their own (the design-system rule, applied to the site).
#   B  name agreement: the asset names in the rewrite script are the names the
#      workflow publishes and the shared build script produces. Three writers,
#      one convention -- the same check release-artifacts.ps1 makes.
#   C  the rewrite script, run for real: it moves all three Windows anchors,
#      it does NOT touch the macOS download (a version regex loose enough to
#      find "the version" also finds Ghoztty-X.Y.Z-arm64.dmg), it is
#      idempotent, and a page it cannot find an anchor in is an ERROR rather
#      than a silent no-op. "Reported success and changed nothing" is the
#      failure shape this repo keeps re-learning (T214, T303).
#   D  wiring: the workflow really calls it, after the publish and gated on
#      it, and both writers of the gh-pages branch retry on a rejected push
#      (release.yml pushes appcast.xml on the same tag push -- concurrent).
#   E  live: the URLs on the page answer 200. Needs network; SKIPs without.
#   F  drift: the in-repo mirror matches the deployed gh-pages page. It has
#      silently drifted twice.
#
# Read-only apart from a temp dir. Never launches the app, never publishes.
#
#   powershell -NoProfile -File test\win32\website-windows-download.ps1
param(
    [string]$Repo = 'D:\git\ghoztty',
    # No network is a SKIP by default (only E and F need it);
    # -RequireNetwork turns those skips into failures.
    [switch]$RequireNetwork
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:skipped = 0

function Assert($name, $cond) {
    if ($cond) { "  PASS $name" } else { "  FAIL $name"; $script:failures++ }
}
function AssertEq($name, $expected, $actual) {
    if ($expected -eq $actual) { "  PASS $name" }
    else { "  FAIL $name (expected '$expected', got '$actual')"; $script:failures++ }
}
function Skip($name, $why) {
    if ($RequireNetwork) { "  FAIL $name ($why)"; $script:failures++ }
    else { "  SKIP $name ($why)"; $script:skipped++ }
}

$indexPath = Join-Path $Repo 'relay\deploy\ghpages\index.html'
$cssPath   = Join-Path $Repo 'relay\deploy\ghpages\landing\styles.css'
$pyPath    = Join-Path $Repo 'dist\website\update-windows-links.py'
$wfPath    = Join-Path $Repo '.github\workflows\release-windows.yml'
$macWfPath = Join-Path $Repo '.github\workflows\release.yml'
$sharedSh  = Join-Path $Repo 'dist\windows-installer\build-release-artifacts.sh'

foreach ($p in @($indexPath, $cssPath, $pyPath, $wfPath, $macWfPath, $sharedSh)) {
    if (-not (Test-Path -LiteralPath $p)) {
        "FATAL: missing $p"
        "1 FAILURE(S)"
        exit 1
    }
}

$html   = Get-Content -LiteralPath $indexPath -Raw
$css    = Get-Content -LiteralPath $cssPath -Raw
$py     = Get-Content -LiteralPath $pyPath -Raw
$wf     = Get-Content -LiteralPath $wfPath -Raw
$macWf  = Get-Content -LiteralPath $macWfPath -Raw
$shared = Get-Content -LiteralPath $sharedSh -Raw

"=== A. page shape ==="

$msiMatches = [regex]::Matches($html, 'id="win-msi-link"[^>]*?href="([^"]+)"')
AssertEq 'A1 exactly one win-msi-link with an href' 1 $msiMatches.Count

$msiHref = ''
if ($msiMatches.Count -eq 1) { $msiHref = $msiMatches[0].Groups[1].Value }

# The tag version and the FILENAME version must be the same number: a link
# whose tag says win-v1.5.0 and whose filename says 1.4.1 is a 404 that looks
# fine in review.
$msiRe = '^https://github\.com/dzearing/ghoztty/releases/download/win-v(\d+\.\d+\.\d+)/Ghoztty-(\d+\.\d+\.\d+)-x64\.msi$'
$msiOk = $msiHref -match $msiRe
Assert 'A2 msi href is a win-v release asset URL' $msiOk

$winVersion = ''
if ($msiOk) {
    $winVersion = $Matches[1]
    AssertEq 'A3 msi filename version matches its tag' $Matches[1] $Matches[2]
} else {
    Assert 'A3 msi filename version matches its tag' $false
}
Assert 'A4 msi filename carries the arch' ($msiHref -match '-x64\.msi$')

$zipMatches = [regex]::Matches($html, 'id="win-zip-link"[^>]*?href="([^"]+)"')
AssertEq 'A5 exactly one win-zip-link with an href' 1 $zipMatches.Count
$zipHref = ''
if ($zipMatches.Count -eq 1) { $zipHref = $zipMatches[0].Groups[1].Value }
# The ZIP link is allowed to point at the release PAGE while a published
# release predates the portable ZIP (win-v1.4.1 shipped the MSI only) -- the
# release page always lists whatever assets exist, so it is never a 404. What
# it may NOT do is point at a different release than the MSI card.
Assert 'A6 zip link targets the same win-v release as the msi' `
    ($winVersion -ne '' -and $zipHref -match ("win-v" + [regex]::Escape($winVersion) + '(/|$)'))
Assert 'A7 zip link is offered as the portable alternative' `
    ($html -match 'id="win-zip-link"[^>]*>\s*portable ZIP\s*</a>')

Assert 'A8 win-version label agrees with the msi link' `
    ($winVersion -ne '' -and $html -match ('<span id="win-version">v' + [regex]::Escape($winVersion) + '</span>'))

# Minimum-OS note. 1809 is the ConPTY floor the app actually requires
# (src/apprt/win32 targets it; see windows-parity-details.md).
Assert 'A9 minimum-OS note names the Windows floor' ($html -match 'Windows 10 1809\+')
Assert 'A10 minimum-OS note names the architecture' ($html -match '64-bit')

# The Windows artifacts are unsigned (no code-signing cert -- the macOS half
# is signed and notarized, which the page says two lines up). A download that
# trips "Windows protected your PC" with no warning on the page reads as
# broken, and a user who backs out of that dialog never runs Ghoztty. The
# portable ZIP's READ-ME-FIRST already says this (build-portable-zip.sh); the
# page is where a user reads it BEFORE downloading. T349.
$ssNote = [regex]::Match($html, '(?s)<p class="download-note" id="win-smartscreen-note">(.*?)</p>')
Assert 'A15 the page carries the unsigned/SmartScreen caveat' $ssNote.Success
if ($ssNote.Success) {
    $ssText = $ssNote.Groups[1].Value
    Assert 'A15b it names SmartScreen and the dialog wording' `
        ($ssText -match 'SmartScreen' -and $ssText -match 'Windows protected your PC')
    Assert 'A15c it says what to click' `
        ($ssText -match 'More info' -and $ssText -match 'Run anyway')
    # It must not claim the Windows build is signed -- the section header
    # says "signed and notarized on macOS" and this line is the other half.
    Assert 'A15d it says the build is not signed' ($ssText -match 'not code-signed|unsigned')
}
# Same design-system rule as A14: the caveat reuses .download-note rather
# than introducing a class of its own.
Assert 'A16 the caveat reuses the existing download-note class' `
    ($html -match 'class="download-note" id="win-smartscreen-note"')

# The Windows card must live in the SAME .download-cards container as the
# macOS one -- "alongside the existing platform links", not a section of its
# own further down the page.
$cardsBlock = [regex]::Match($html, '(?s)<div class="download-cards">(.*?)</div>\s*<p class="download-note">')
Assert 'A11 download-cards block found' $cardsBlock.Success
if ($cardsBlock.Success) {
    $cards = $cardsBlock.Groups[1].Value
    Assert 'A12 macOS dmg card is in it' ($cards -match 'Ghoztty-\d+\.\d+\.\d+-arm64\.dmg')
    Assert 'A13 windows msi card is in it' ($cards -match 'id="win-msi-link"')
}

# Design-system rule, applied to the site: reuse the existing vocabulary
# instead of inventing a class for the new card.
$newClasses = @('download-card', 'download-icon', 'download-info', 'download-action', 'download-note')
$missingClass = @()
foreach ($c in $newClasses) {
    if ($css -notmatch ('\.' + [regex]::Escape($c) + '[\s,{:]')) { $missingClass += $c }
}
AssertEq 'A14 the windows card reuses only existing CSS classes' 0 $missingClass.Count

"=== B. asset names agree across their three writers ==="

Assert 'B1 rewrite script MSI name is Ghoztty-<v>-x64.msi' `
    ($py -match 'MSI_NAME\s*=\s*"Ghoztty-\{v\}-x64\.msi"')
Assert 'B2 rewrite script ZIP name is Ghoztty-portable-<v>-x64.zip' `
    ($py -match 'ZIP_NAME\s*=\s*"Ghoztty-portable-\{v\}-x64\.zip"')
Assert 'B3 workflow publishes that MSI name' `
    ($wf -match 'MSI=zig-out/Ghoztty-\$VERSION-x64\.msi')
Assert 'B4 workflow publishes that ZIP name' `
    ($wf -match 'ZIP=zig-out/Ghoztty-portable-\$VERSION-x64\.zip')
Assert 'B5 workflow tag is win-v<version>' ($wf -match 'TAG=win-v\$VERSION')
Assert 'B6 shared build script produces the same names' `
    ($shared -match 'Ghoztty-\$\{?SEMVER' -or $shared -match 'Ghoztty-\$SEMVER' -or $shared -match 'Ghoztty-.*-x64\.msi')

"=== C. the rewrite script, run for real ==="

# Find an interpreter. On this box `python3` is the Microsoft Store alias
# (prints an ad and exits non-zero); CI has a real python3.
$interp = $null
foreach ($cand in @('python', 'python3', 'py')) {
    $v = & $cand --version 2>&1
    if ($LASTEXITCODE -eq 0 -and "$v" -match 'Python 3') { $interp = $cand; break }
}

if (-not $interp) {
    Skip 'C1-C7 rewrite script behavior' 'no python 3 interpreter on PATH'
} else {
    $work = Join-Path $env:TEMP ('ghoztty-t39-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $target = '9.9.9'
        $sample = Join-Path $work 'index.html'
        Copy-Item -LiteralPath $indexPath -Destination $sample

        $macBefore = [regex]::Matches($html, 'Ghoztty-\d+\.\d+\.\d+-arm64\.dmg') |
            ForEach-Object { $_.Value }

        $out1 = & $interp $pyPath $sample $target 2>&1
        $rc1 = $LASTEXITCODE
        AssertEq 'C1 rewrite exits 0' 0 $rc1

        $after = Get-Content -LiteralPath $sample -Raw
        Assert 'C2 msi link moved to the new release' `
            ($after -match ('id="win-msi-link"[^>]*?href="https://github\.com/dzearing/ghoztty/releases/download/win-v' + [regex]::Escape($target) + '/Ghoztty-' + [regex]::Escape($target) + '-x64\.msi"'))
        Assert 'C3 zip link moved to the new release asset' `
            ($after -match ('id="win-zip-link"[^>]*?href="https://github\.com/dzearing/ghoztty/releases/download/win-v' + [regex]::Escape($target) + '/Ghoztty-portable-' + [regex]::Escape($target) + '-x64\.zip"'))
        Assert 'C4 version label moved' `
            ($after -match ('<span id="win-version">v' + [regex]::Escape($target) + '</span>'))

        # The whole reason the script matches by element id.
        $macAfter = [regex]::Matches($after, 'Ghoztty-\d+\.\d+\.\d+-arm64\.dmg') |
            ForEach-Object { $_.Value }
        AssertEq 'C5 macOS dmg link is untouched' ($macBefore -join ',') ($macAfter -join ',')

        # Idempotent: a re-run must not churn the file (the workflow diffs
        # before committing, and a no-op commit on every release is noise).
        $out2 = & $interp $pyPath $sample $target 2>&1
        $rc2 = $LASTEXITCODE
        $after2 = Get-Content -LiteralPath $sample -Raw
        AssertEq 'C6 second run exits 0' 0 $rc2
        Assert 'C6b second run says nothing to do' ("$out2" -match 'nothing to do')
        AssertEq 'C6c second run changed nothing' $after $after2

        # A page it cannot find an anchor in must FAIL, not quietly succeed.
        $broken = Join-Path $work 'broken.html'
        ($html -replace 'id="win-msi-link"', 'id="win-msi-link-renamed"') |
            Set-Content -LiteralPath $broken -Encoding UTF8
        $out3 = & $interp $pyPath $broken $target 2>&1
        $rc3 = $LASTEXITCODE
        Assert 'C7 missing anchor is an error, not a silent no-op' ($rc3 -ne 0)
        Assert 'C7b and it says which id it could not find' ("$out3" -match 'win-msi-link')

        # A bad version must be rejected before it reaches the page.
        $out4 = & $interp $pyPath $sample 'v9.9.9' 2>&1
        Assert 'C8 leading-v version is rejected' ($LASTEXITCODE -ne 0)
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

"=== D. release wiring ==="

Assert 'D1 workflow calls the rewrite script' `
    ($wf -match 'dist/website/update-windows-links\.py')
Assert 'D2 the website step is gated on PUBLISH' `
    ($wf -match "(?s)Update website Windows download links.*?if:\s*env\.PUBLISH == 'true'")
# Ordering matters: links must never precede the assets they point at.
$iPublish = $wf.IndexOf('Publish win-v release')
$iWeb     = $wf.IndexOf('Update website Windows download links')
Assert 'D3 the website step runs after the publish step' `
    ($iPublish -ge 0 -and $iWeb -gt $iPublish)
Assert 'D4 windows gh-pages push retries on rejection' `
    ($wf -match '(?s)Update website Windows download links.*?git pull --rebase origin gh-pages')
Assert 'D5 mac appcast push retries on rejection too' `
    ($macWf -match 'git pull --rebase origin gh-pages')
Assert 'D6 both writers target the gh-pages branch' `
    (($wf -match 'clone --branch gh-pages') -and ($macWf -match 'clone --branch gh-pages'))

# T577. The workflow was correct for two weeks and had still never run once,
# because a workflow runs from the tree of the ref that triggered it and the
# only trigger was `v*` -- a tag cut from main, which carries neither this
# file nor the win32 apprt it builds. So the wiring check is not "does the
# file exist", it is "is there a tag shape THIS tree can be tagged with that
# reaches this workflow", plus "does the version parse survive that shape".
$tagBlock = ''
if ($wf -match '(?s)on:\s*\r?\n\s*push:\s*\r?\n(.*?)\r?\n\s*workflow_dispatch:') { $tagBlock = $Matches[1] }
Assert 'D7 workflow triggers on a tag the windows branch can carry (win-v*)' `
    ($tagBlock -match '(?m)^\s*-\s*"win-v\*"\s*$')
Assert 'D8 workflow still triggers on v* for after the merge-back' `
    ($tagBlock -match '(?m)^\s*-\s*"v\*"\s*$')
# A win-v tag must parse to a bare X.Y.Z or the version regex rejects it and
# the release dies on a version that was never malformed.
Assert 'D9 the version parse strips the win- prefix before the v' `
    ($wf -match '(?s)VERSION=\$\{TAG_NAME#win-\}.*?VERSION=\$\{VERSION#v\}')
# What the workflow builds has to be present in the same tree as the
# workflow, which is the whole point of D7.
Assert 'D10 this tree carries the win32 apprt the workflow builds' `
    (Test-Path -LiteralPath (Join-Path $Repo 'src\apprt\win32'))

"=== E. the links answer (live) ==="

function Test-Url($url) {
    try {
        # HEAD first; GitHub's asset redirect answers HEAD fine. -MaximumRedirection
        # default follows to the S3 blob.
        $r = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 25
        return [int]$r.StatusCode
    } catch {
        $resp = $_.Exception.Response
        if ($resp -ne $null) { return [int]$resp.StatusCode }
        return -1
    }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$online = (Test-Url 'https://github.com') -eq 200

if (-not $online) {
    Skip 'E1-E2 live link checks' 'github.com unreachable'
} else {
    $codeMsi = Test-Url $msiHref
    AssertEq "E1 msi link answers 200 ($msiHref)" 200 $codeMsi
    $codeZip = Test-Url $zipHref
    AssertEq "E2 portable-zip link answers 200 ($zipHref)" 200 $codeZip
}

"=== F. the in-repo mirror matches the deployed page ==="

Push-Location $Repo
try {
    $live = & git show origin/gh-pages:index.html 2>$null
    $haveLive = ($LASTEXITCODE -eq 0 -and $live -ne $null)
} catch {
    $haveLive = $false
}
Pop-Location

if (-not $haveLive) {
    Skip 'F1 mirror == deployed gh-pages index.html' 'origin/gh-pages not fetched'
} else {
    # Compare line-by-line so a CRLF/LF checkout difference is not a failure.
    $liveText   = ($live -join "`n").TrimEnd()
    $mirrorText = (($html -split "`r?`n") -join "`n").TrimEnd()
    if ($liveText -ceq $mirrorText) {
        "  PASS F1 mirror == deployed gh-pages index.html"
    } else {
        "  FAIL F1 mirror != deployed gh-pages index.html (the mirror has drifted twice before; sync it)"
        $script:failures++
        $lm = ($mirrorText -split "`n")
        $ll = ($liveText -split "`n")
        $n = [Math]::Max($lm.Count, $ll.Count)
        $shown = 0
        for ($i = 0; $i -lt $n -and $shown -lt 6; $i++) {
            $a = if ($i -lt $lm.Count) { $lm[$i] } else { '<eof>' }
            $b = if ($i -lt $ll.Count) { $ll[$i] } else { '<eof>' }
            if ($a -cne $b) {
                "       line $($i + 1):"
                "         mirror: $a"
                "         live  : $b"
                $shown++
            }
        }
    }
}

""
if ($script:skipped -gt 0) { "$($script:skipped) SKIPPED" }
if ($script:failures -eq 0) { "ALL PASS" } else { "$($script:failures) FAILURE(S)" }
exit ([int]($script:failures -gt 0))
