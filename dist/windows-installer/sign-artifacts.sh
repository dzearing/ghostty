#!/usr/bin/env bash
#
# Authenticode-sign the Windows release payload (T1203).
#
# WHY THIS EXISTS. macOS ships signed and notarized; Windows shipped
# unsigned, so the first thing a new user met was SmartScreen's full-screen
# "Windows protected your PC / Unknown publisher" wall. CLAUDE.md calls that
# asymmetry the defect rather than a platform difference, and it lands on the
# exact sentence the install epic exists to make true: install on a new
# machine and it should just work.
#
# WHY IT IS A SCRIPT AND NOT SIX LINES OF YAML. The same rule
# build-release-artifacts.sh follows: CI and the on-box publish path
# (scripts/publish-windows-release.ps1) must not be able to drift. A signing
# step that lives only in release-windows.yml is a step the manual path never
# runs, which is how one channel ships signed bits and the other does not.
#
# WHY THE ABSENT-CERTIFICATE PATH EXITS 0. The certificate itself is the
# user's to obtain - it needs payment and identity validation, neither of
# which a build can do - so until one exists in the repo secrets every
# release, every fork-ci run and every on-box publish must still produce
# artifacts. Absent config is therefore a loud UNSIGNED banner and success.
# Config that is PRESENT and does not work is a hard failure: a half-applied
# certificate that silently produced unsigned bits would be the "reported
# success over a delivery that never happened" shape this repo keeps paying
# for.
#
# Usage:
#   bash sign-artifacts.sh <file> [<file> ...]
#
# Always through `bash`, never `./sign-artifacts.sh`. This repo has
# core.fileMode off on the Windows seat, so a +x bit set here cannot be
# committed from this box and the file ships 100644 -- which a direct
# invocation in CI would discover as "Permission denied" on the first release
# that needed it. build-release-artifacts.sh calls it the safe way; keep it
# that way rather than chasing the mode bit.
#
# Both PE images (.exe/.com/.dll) and MSI packages are accepted; osslsigncode
# handles both, which is the reason it is the tool here rather than
# signtool.exe - the release builds on ubuntu-latest and cross-compiles, so
# there is no Windows runner to run signtool on.
#
# Environment:
#   WINDOWS_SIGN_PFX_BASE64   base64 of the PKCS#12 (.pfx) certificate.
#                             Base64 because a GitHub secret is a string and
#                             a .pfx is binary.
#   WINDOWS_SIGN_PASSWORD     its password. Optional only if the pfx has none.
#   WINDOWS_SIGN_TIMESTAMP_URL
#                             RFC3161 timestamp authority. Defaults to
#                             DigiCert's. A timestamp is what keeps already
#                             shipped builds trusted after the certificate
#                             itself expires, so this is not optional in
#                             practice - it is only defaulted.
#   WINDOWS_SIGN_NAME / _URL  the description and URL embedded in the
#                             signature. Defaulted; overridable.
#
# Exit codes: 0 signed, or deliberately unsigned. 1 configured and failed.
# 2 called wrong.
set -uo pipefail

if [[ $# -eq 0 ]]; then
    echo "usage: sign-artifacts.sh <file> [<file> ...]" >&2
    exit 2
fi

for f in "$@"; do
    if [[ ! -f "$f" ]]; then
        echo "error: $f does not exist -- sign-artifacts.sh is called after the" \
             "thing it signs is built" >&2
        exit 2
    fi
done

PFX_B64="${WINDOWS_SIGN_PFX_BASE64:-}"

if [[ -z "$PFX_B64" ]]; then
    echo "==> code signing: NOT CONFIGURED (no \$WINDOWS_SIGN_PFX_BASE64)"
    echo "    These artifacts are UNSIGNED. Windows SmartScreen will show"
    echo "    'Windows protected your PC' with an unknown publisher the first"
    echo "    time a downloaded copy is run. That is expected until a code"
    echo "    signing certificate is added to the repo secrets (T1203); it is"
    echo "    not a build failure."
    for f in "$@"; do echo "    unsigned: $f"; done
    exit 0
fi

TIMESTAMP_URL="${WINDOWS_SIGN_TIMESTAMP_URL:-http://timestamp.digicert.com}"
SIGN_NAME="${WINDOWS_SIGN_NAME:-Ghoztty}"
SIGN_URL="${WINDOWS_SIGN_URL:-https://github.com/dzearing/ghoztty}"

if ! command -v osslsigncode >/dev/null 2>&1; then
    echo "::error::code signing is configured (\$WINDOWS_SIGN_PFX_BASE64 is set)" \
         "but osslsigncode is not installed. Install it before building, or" \
         "unset the secret to publish deliberately unsigned artifacts." >&2
    exit 1
fi

# The certificate and its password only ever exist as files, mode 600, in a
# directory that is removed on any exit. Two things this is not: the password
# is never an argv element (osslsigncode -readpass), because argv is visible
# to every process on the box; and neither is ever echoed, because a release
# log is a public artifact.
WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

PFX="$WORKDIR/cert.pfx"
PASSFILE="$WORKDIR/cert.pass"

umask 077
if ! printf '%s' "$PFX_B64" | base64 -d > "$PFX" 2>/dev/null; then
    echo "::error::\$WINDOWS_SIGN_PFX_BASE64 is not valid base64. Re-encode the" \
         ".pfx with 'base64 -w0 cert.pfx' and update the secret." >&2
    exit 1
fi
if [[ ! -s "$PFX" ]]; then
    echo "::error::\$WINDOWS_SIGN_PFX_BASE64 decoded to an empty file." >&2
    exit 1
fi
printf '%s' "${WINDOWS_SIGN_PASSWORD:-}" > "$PASSFILE"

echo "==> code signing $# artifact(s) with the configured certificate"
echo "    timestamp authority: $TIMESTAMP_URL"

rc=0
for f in "$@"; do
    signed="$WORKDIR/$(basename "$f").signed"

    # SHA-256 throughout: SHA-1 Authenticode signatures are no longer trusted
    # by any supported Windows.
    if ! osslsigncode sign \
            -pkcs12 "$PFX" \
            -readpass "$PASSFILE" \
            -h sha256 \
            -ts "$TIMESTAMP_URL" \
            -n "$SIGN_NAME" \
            -i "$SIGN_URL" \
            -in "$f" \
            -out "$signed" >/dev/null 2>"$WORKDIR/err.txt"; then
        echo "::error::failed to sign $f" >&2
        sed 's/^/    /' "$WORKDIR/err.txt" >&2
        rc=1
        continue
    fi

    # Read the result back before it replaces the original. "osslsigncode
    # returned 0" is the same class of evidence as "Copy-Item did not throw",
    # and this repo has already shipped one delivery that was verified only
    # that far.
    if ! osslsigncode verify -in "$signed" >"$WORKDIR/verify.txt" 2>&1; then
        echo "::error::$f was signed but the signature does not verify" >&2
        sed 's/^/    /' "$WORKDIR/verify.txt" >&2
        rc=1
        continue
    fi

    mv "$signed" "$f"
    echo "    signed: $f"
done

if [[ $rc -ne 0 ]]; then
    echo "::error::code signing failed. The artifacts are NOT publishable --" \
         "a release that claims to be signed and is not is worse than an" \
         "openly unsigned one." >&2
fi
exit $rc
