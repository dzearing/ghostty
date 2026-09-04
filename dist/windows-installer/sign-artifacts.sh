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
# TWO BACKENDS, BECAUSE EV CERTIFICATES ARE NOT FILES. Decision D89
# (2026-09-04) reversed D87 and chose to buy an EV certificate, and an EV
# certificate bought today does not arrive as an exportable .pfx: the CA/B
# Forum rules require the private key to live on a FIPS-140 hardware token or
# in a cloud HSM, so no issuer will hand one over. A pfx-only pipeline is
# therefore a pipeline the certificate we are actually buying cannot use. The
# second backend is PKCS#11 rather than any one issuer's CLI, because PKCS#11
# is the interface all of them already expose - SafeNet and YubiKey tokens,
# DigiCert KeyLocker, SSL.com eSigner, Azure Trusted Signing - so the choice
# of issuer stops being a code change here, and osslsigncode already speaks
# it, so no new tool joins the release runner. The key never leaves the
# token in either direction: osslsigncode sends it a hash and gets a
# signature back.
#
# Exactly one backend may be configured. Both at once is a hard error rather
# than a precedence rule, because "which certificate signed this release" is
# not a question anybody should have to answer by reading this file.
#
# Environment:
#   WINDOWS_SIGN_PFX_BASE64   PFX BACKEND. base64 of the PKCS#12 (.pfx)
#                             certificate. Base64 because a GitHub secret is a
#                             string and a .pfx is binary.
#   WINDOWS_SIGN_PKCS11_MODULE
#                             PKCS#11 BACKEND. Path to the issuer's PKCS#11
#                             library on the runner (opensc-pkcs11.so for a
#                             token, the issuer's .so for a cloud HSM). Setting
#                             this selects the backend.
#   WINDOWS_SIGN_PKCS11_ENGINE
#                             Path to OpenSSL's pkcs11 engine. Defaults to the
#                             first of the usual Debian/Ubuntu locations that
#                             exists, so a stock `libengine-pkcs11-openssl`
#                             install needs no configuration.
#   WINDOWS_SIGN_PKCS11_CERT  PKCS#11 URI of the CERTIFICATE on the token,
#                             e.g. 'pkcs11:object=Ghoztty;type=cert'. Optional
#                             when the chain is supplied as a file instead.
#   WINDOWS_SIGN_PKCS11_KEY   PKCS#11 URI of the PRIVATE KEY. Required.
#   WINDOWS_SIGN_CERT_CHAIN_BASE64
#                             base64 of a PEM certificate chain, for a token
#                             that holds only the key. Mutually exclusive with
#                             WINDOWS_SIGN_PKCS11_CERT; one of the two is
#                             required, since a signature with no certificate
#                             attached is not an Authenticode signature.
#   WINDOWS_SIGN_PASSWORD     The pfx password, or the token/HSM PIN. Optional
#                             only for a pfx that has none.
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
P11_MODULE="${WINDOWS_SIGN_PKCS11_MODULE:-}"

if [[ -n "$PFX_B64" && -n "$P11_MODULE" ]]; then
    echo "::error::both signing backends are configured" \
         "(\$WINDOWS_SIGN_PFX_BASE64 and \$WINDOWS_SIGN_PKCS11_MODULE)." \
         "Unset one: which certificate signed a release must not depend on a" \
         "precedence rule buried in sign-artifacts.sh." >&2
    exit 1
fi

if [[ -z "$PFX_B64" && -z "$P11_MODULE" ]]; then
    echo "==> code signing: NOT CONFIGURED (no \$WINDOWS_SIGN_PFX_BASE64," \
         "no \$WINDOWS_SIGN_PKCS11_MODULE)"
    echo "    These artifacts are UNSIGNED. Windows SmartScreen will show"
    echo "    'Windows protected your PC' with an unknown publisher the first"
    echo "    time a downloaded copy is run, and on some machines Defender"
    echo "    removes the files outright instead of warning about them."
    echo "    That is not a build failure: a release must never be held"
    echo "    hostage to a certificate the build cannot obtain for itself."
    echo "    Decision D89 chose to buy an EV certificate; until it is loaded"
    echo "    into the repo secrets, releases ship openly unsigned and say so"
    echo "    (T1246)."
    for f in "$@"; do echo "    unsigned: $f"; done
    exit 0
fi

TIMESTAMP_URL="${WINDOWS_SIGN_TIMESTAMP_URL:-http://timestamp.digicert.com}"
SIGN_NAME="${WINDOWS_SIGN_NAME:-Ghoztty}"
SIGN_URL="${WINDOWS_SIGN_URL:-https://github.com/dzearing/ghoztty}"

if [[ -n "$PFX_B64" ]]; then BACKEND="pfx"; else BACKEND="pkcs11"; fi

# The configuration is validated BEFORE the toolchain is looked for, so that
# "your PKCS#11 secrets are wrong" is answerable on any box rather than only
# on one that already has osslsigncode. That ordering is also what lets
# sections G17-G21 of test\win32\release-artifacts.ps1 watch every one of
# these refusals actually fire from this Windows seat.

# The certificate and its password only ever exist as files, mode 600, in a
# directory that is removed on any exit. Two things this is not: the password
# is never an argv element (osslsigncode -readpass), because argv is visible
# to every process on the box; and neither is ever echoed, because a release
# log is a public artifact.
WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

PASSFILE="$WORKDIR/cert.pass"
umask 077
printf '%s' "${WINDOWS_SIGN_PASSWORD:-}" > "$PASSFILE"

# SIGN_ARGS holds the backend-specific half of the osslsigncode invocation.
# Building it once here rather than branching inside the per-file loop keeps
# there being exactly ONE place that decides how a Ghoztty artifact is signed.
SIGN_ARGS=()

if [[ "$BACKEND" == "pfx" ]]; then
    PFX="$WORKDIR/cert.pfx"
    if ! printf '%s' "$PFX_B64" | base64 -d > "$PFX" 2>/dev/null; then
        echo "::error::\$WINDOWS_SIGN_PFX_BASE64 is not valid base64. Re-encode the" \
             ".pfx with 'base64 -w0 cert.pfx' and update the secret." >&2
        exit 1
    fi
    if [[ ! -s "$PFX" ]]; then
        echo "::error::\$WINDOWS_SIGN_PFX_BASE64 decoded to an empty file." >&2
        exit 1
    fi
    SIGN_ARGS+=(-pkcs12 "$PFX" -readpass "$PASSFILE")
else
    # Everything below is checked BEFORE the first artifact is touched. A
    # misconfigured token that is only discovered on the third of four files
    # leaves a payload where some binaries are signed and some are not, which
    # is the one output shape worse than an openly unsigned release.
    if [[ ! -f "$P11_MODULE" ]]; then
        echo "::error::\$WINDOWS_SIGN_PKCS11_MODULE points at '$P11_MODULE'," \
             "which does not exist. It must be the issuer's PKCS#11 library on" \
             "this runner (opensc-pkcs11.so for a hardware token, the issuer's" \
             ".so for a cloud HSM)." >&2
        exit 1
    fi

    P11_ENGINE="${WINDOWS_SIGN_PKCS11_ENGINE:-}"
    if [[ -z "$P11_ENGINE" ]]; then
        # Stock libengine-pkcs11-openssl, wherever this runner's OpenSSL keeps
        # its engines. Defaulted rather than required so the common case is no
        # configuration at all.
        for candidate in \
            /usr/lib/x86_64-linux-gnu/engines-3/pkcs11.so \
            /usr/lib/x86_64-linux-gnu/engines-1.1/pkcs11.so \
            /usr/lib64/engines-3/pkcs11.so \
            /usr/lib/engines-3/pkcs11.so; do
            if [[ -f "$candidate" ]]; then P11_ENGINE="$candidate"; break; fi
        done
    fi
    if [[ -z "$P11_ENGINE" || ! -f "$P11_ENGINE" ]]; then
        echo "::error::no OpenSSL pkcs11 engine found. Install" \
             "libengine-pkcs11-openssl on the runner, or set" \
             "\$WINDOWS_SIGN_PKCS11_ENGINE to the engine's path." >&2
        exit 1
    fi

    P11_KEY="${WINDOWS_SIGN_PKCS11_KEY:-}"
    if [[ -z "$P11_KEY" ]]; then
        echo "::error::\$WINDOWS_SIGN_PKCS11_KEY is required with the PKCS#11" \
             "backend. It is the PKCS#11 URI of the private key, e.g." \
             "'pkcs11:object=Ghoztty;type=private'." >&2
        exit 1
    fi

    P11_CERT="${WINDOWS_SIGN_PKCS11_CERT:-}"
    CHAIN_B64="${WINDOWS_SIGN_CERT_CHAIN_BASE64:-}"
    if [[ -n "$P11_CERT" && -n "$CHAIN_B64" ]]; then
        echo "::error::\$WINDOWS_SIGN_PKCS11_CERT and" \
             "\$WINDOWS_SIGN_CERT_CHAIN_BASE64 are alternatives - the" \
             "certificate comes either off the token or out of a PEM file," \
             "not both. Unset one." >&2
        exit 1
    fi
    if [[ -z "$P11_CERT" && -z "$CHAIN_B64" ]]; then
        echo "::error::the PKCS#11 backend needs the CERTIFICATE as well as the" \
             "key: set \$WINDOWS_SIGN_PKCS11_CERT (it lives on the token) or" \
             "\$WINDOWS_SIGN_CERT_CHAIN_BASE64 (a PEM chain). A signature with" \
             "no certificate attached is not an Authenticode signature." >&2
        exit 1
    fi

    SIGN_ARGS+=(-pkcs11engine "$P11_ENGINE" -pkcs11module "$P11_MODULE")
    if [[ -n "$P11_CERT" ]]; then
        SIGN_ARGS+=(-pkcs11cert "$P11_CERT")
    else
        CHAIN="$WORKDIR/chain.pem"
        if ! printf '%s' "$CHAIN_B64" | base64 -d > "$CHAIN" 2>/dev/null; then
            echo "::error::\$WINDOWS_SIGN_CERT_CHAIN_BASE64 is not valid base64." \
                 "Re-encode the PEM chain with 'base64 -w0 chain.pem'." >&2
            exit 1
        fi
        if [[ ! -s "$CHAIN" ]]; then
            echo "::error::\$WINDOWS_SIGN_CERT_CHAIN_BASE64 decoded to an empty" \
                 "file." >&2
            exit 1
        fi
        SIGN_ARGS+=(-certs "$CHAIN")
    fi
    # -readpass carries the token PIN for exactly the argv reason above.
    SIGN_ARGS+=(-key "$P11_KEY" -readpass "$PASSFILE")
fi

if ! command -v osslsigncode >/dev/null 2>&1; then
    echo "::error::code signing is configured ($BACKEND backend) but" \
         "osslsigncode is not installed. Install it before building, or" \
         "unset the secret to publish deliberately unsigned artifacts." >&2
    exit 1
fi

echo "==> code signing $# artifact(s) with the configured certificate"
echo "    backend: $BACKEND"
echo "    timestamp authority: $TIMESTAMP_URL"

rc=0
for f in "$@"; do
    signed="$WORKDIR/$(basename "$f").signed"

    # SHA-256 throughout: SHA-1 Authenticode signatures are no longer trusted
    # by any supported Windows.
    if ! osslsigncode sign \
            "${SIGN_ARGS[@]}" \
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
