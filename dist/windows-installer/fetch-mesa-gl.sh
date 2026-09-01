#!/usr/bin/env bash
# fetch-mesa-gl.sh -- vendor (or re-verify) the fallback OpenGL implementation
# Ghoztty ships on Windows (T1252).
#
# This is a MAINTENANCE tool, not a build step. The bytes live in the repo at
# vendor/mesa-gl/ so that an offline build, a CI runner and a release all
# package the same implementation with no network and no `7z` anywhere in the
# pipeline. This script is what puts them there, and what proves afterwards
# that they are what they claim to be.
#
#   fetch-mesa-gl.sh --verify              re-download the PINNED asset, check
#                                          its hash, extract it again, and
#                                          compare byte for byte with the files
#                                          committed in vendor/mesa-gl/.
#                                          Prints DIFFERS and exits 1 on any
#                                          mismatch.
#   fetch-mesa-gl.sh --version <X.Y.Z>     bump to a newer Mesa: download,
#                                          extract, write the files, and
#                                          rewrite PINNED.json from what
#                                          actually arrived.
#
# Options: --driver <name> (default d3d12), --arch <x64> (default x64),
#          --keep <dir> (leave the download there instead of a temp dir).
#
# Requires: curl, sha256sum (or shasum), python3, and one of 7z / 7zr / 7za.
# The 7-Zip dependency is why this is not a build step: the upstream asset uses
# the BCJ2 filter, which py7zr cannot decode, so there is no stdlib-only way to
# open it. Getting one is easy on either platform -- `7zr.exe` from
# https://www.7-zip.org/ on Windows, `p7zip-full` on Linux -- and it is needed
# only when the pinned version changes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
VENDOR="$REPO_ROOT/vendor/mesa-gl"
PINNED="$VENDOR/PINNED.json"

MODE="verify"
VERSION=""
DRIVER="d3d12"
ARCH="x64"
KEEP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify)     MODE="verify"; shift ;;
    --version)    MODE="update"; VERSION="${2:?--version needs a value}"; shift 2 ;;
    --version=*)  MODE="update"; VERSION="${1#*=}"; shift ;;
    --driver)     DRIVER="${2:?--driver needs a value}"; shift 2 ;;
    --driver=*)   DRIVER="${1#*=}"; shift ;;
    --arch)       ARCH="${2:?--arch needs a value}"; shift 2 ;;
    --arch=*)     ARCH="${1#*=}"; shift ;;
    --keep)       KEEP="${2:?--keep needs a value}"; shift 2 ;;
    --keep=*)     KEEP="${1#*=}"; shift ;;
    -h|--help)    sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)            echo "error: unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v curl >/dev/null || { echo "error: curl not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 not found" >&2; exit 1; }

SEVENZIP=""
for c in 7z 7zr 7za; do
  if command -v "$c" >/dev/null; then SEVENZIP="$c"; break; fi
done
[[ -n "$SEVENZIP" ]] || {
  echo "error: none of 7z/7zr/7za found on PATH." >&2
  echo "       The upstream asset is a .7z using the BCJ2 filter; py7zr cannot read it." >&2
  echo "       Windows: the standalone 7zr.exe from https://www.7-zip.org/ is enough." >&2
  echo "       Linux:   apt-get install p7zip-full" >&2
  exit 1
}

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# What the repo currently claims, so --verify has something to compare against
# and --update has defaults to inherit. Read into a variable first rather than
# nesting a command substitution inside the `read` heredoc: the nested form
# works but is exactly the shape that breaks silently under a different shell.
PIN_LINE="$(python3 - "$PINNED" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1]))
dll = next(f for f in p["files"] if f["path"].endswith("opengl32.dll"))
print(p["mesaVersion"], p["driver"], p["source"]["url"], p["source"]["sha256"],
      dll["path"], dll["sha256"])
PYEOF
)"
read -r PIN_VERSION PIN_DRIVER PIN_URL PIN_ARCHIVE_SHA PIN_DLL_REL PIN_DLL_SHA <<< "$PIN_LINE"

if [[ "$MODE" == "verify" ]]; then
  VERSION="$PIN_VERSION"
  DRIVER="$PIN_DRIVER"
  URL="$PIN_URL"
else
  URL="https://github.com/mmozeiko/build-mesa/releases/download/$VERSION/mesa-$DRIVER-$ARCH-$VERSION.7z"
fi

if [[ -n "$KEEP" ]]; then
  WORK="$KEEP"; mkdir -p "$WORK"
else
  WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fi

ARCHIVE="$WORK/$(basename "$URL")"
echo "==> $URL"
curl -fsSL --retry 3 -o "$ARCHIVE" "$URL"
ARCHIVE_SHA="$(sha256 "$ARCHIVE")"
ARCHIVE_SIZE="$(python3 -c 'import os,sys; print(os.path.getsize(sys.argv[1]))' "$ARCHIVE")"
echo "    sha256 $ARCHIVE_SHA ($ARCHIVE_SIZE bytes)"

if [[ "$MODE" == "verify" && "$ARCHIVE_SHA" != "$PIN_ARCHIVE_SHA" ]]; then
  echo "DIFFERS: the pinned asset no longer hashes to what PINNED.json records." >&2
  echo "  expected $PIN_ARCHIVE_SHA" >&2
  echo "  got      $ARCHIVE_SHA" >&2
  echo "  A release asset that changed under a fixed tag is a supply-chain event," >&2
  echo "  not a version bump -- investigate before touching anything here." >&2
  exit 1
fi

EXTRACT="$WORK/extract"
rm -rf "$EXTRACT"; mkdir -p "$EXTRACT"
"$SEVENZIP" e -y -o"$EXTRACT" "$ARCHIVE" opengl32.dll >/dev/null
[[ -f "$EXTRACT/opengl32.dll" ]] || { echo "error: the archive has no opengl32.dll" >&2; exit 1; }
DLL_SHA="$(sha256 "$EXTRACT/opengl32.dll")"
DLL_SIZE="$(python3 -c 'import os,sys; print(os.path.getsize(sys.argv[1]))' "$EXTRACT/opengl32.dll")"
echo "==> opengl32.dll sha256 $DLL_SHA ($DLL_SIZE bytes)"

# An x86 build under an x64 name would load nowhere and the only symptom would
# be a fallback that is never taken, so the machine word is checked rather than
# assumed.
MACHINE="$(python3 - "$EXTRACT/opengl32.dll" <<'PYEOF'
import struct, sys
d = open(sys.argv[1], "rb").read(4096)
pe = struct.unpack_from("<I", d, 0x3C)[0]
print("%04x" % struct.unpack_from("<H", d, pe + 4)[0])
PYEOF
)"
[[ "$MACHINE" == "8664" ]] || { echo "error: PE machine $MACHINE, expected 8664 (x86_64)" >&2; exit 1; }

if [[ "$MODE" == "verify" ]]; then
  ON_DISK="$VENDOR/$PIN_DLL_REL"
  [[ -f "$ON_DISK" ]] || { echo "DIFFERS: $ON_DISK is not in the tree" >&2; exit 1; }
  if ! cmp -s "$EXTRACT/opengl32.dll" "$ON_DISK"; then
    echo "DIFFERS: $PIN_DLL_REL in the tree is not what the pinned asset extracts to" >&2
    exit 1
  fi
  HAVE_SHA="$(sha256 "$ON_DISK")"
  [[ "$HAVE_SHA" == "$PIN_DLL_SHA" ]] || {
    echo "DIFFERS: $PIN_DLL_REL hashes $HAVE_SHA, PINNED.json says $PIN_DLL_SHA" >&2
    exit 1
  }
  echo ""
  echo "REPRODUCED: mesa $VERSION ($DRIVER) -> vendor/mesa-gl/$PIN_DLL_REL, byte for byte."
  exit 0
fi

# -- update --------------------------------------------------------------
mkdir -p "$VENDOR/$ARCH"
cp "$EXTRACT/opengl32.dll" "$VENDOR/$ARCH/opengl32.dll"

# The licence travels with the version: shipping 26.2.1's terms beside 26.3.0's
# binary is exactly the kind of drift a pinned manifest is supposed to prevent.
LIC_RST="$WORK/license.rst"
LIC_MIT="$WORK/MIT"
curl -fsSL -o "$LIC_RST" "https://gitlab.freedesktop.org/mesa/mesa/-/raw/mesa-$VERSION/docs/license.rst"
curl -fsSL -o "$LIC_MIT" "https://gitlab.freedesktop.org/mesa/mesa/-/raw/mesa-$VERSION/licenses/MIT"
{
  cat <<EOF
Mesa 3D Graphics Library $VERSION -- license and copyright
========================================================

The file $ARCH/opengl32.dll shipped in this directory is an unmodified build of
the Mesa 3D Graphics Library (https://mesa3d.org), redistributed with Ghoztty
as a fallback OpenGL implementation. See README.md in this directory for the
exact upstream artifact and its hashes.

The two sections below are Mesa's own docs/license.rst and licenses/MIT, taken
verbatim from the mesa-$VERSION tag.

--------------------------------------------------------------------------
docs/license.rst
--------------------------------------------------------------------------

EOF
  cat "$LIC_RST"
  cat <<'EOF'

--------------------------------------------------------------------------
licenses/MIT
--------------------------------------------------------------------------

EOF
  cat "$LIC_MIT"
} > "$VENDOR/LICENSE"

python3 - "$PINNED" "$VERSION" "$DRIVER" "$ARCH" "$URL" "$ARCHIVE_SHA" \
    "$ARCHIVE_SIZE" "$DLL_SHA" "$DLL_SIZE" <<'PYEOF'
import json, os, sys
pinned, version, driver, arch, url, asha, asize, dsha, dsize = sys.argv[1:10]
p = json.load(open(pinned))
p["mesaVersion"] = version
p["driver"] = driver
p["source"]["release"] = f"https://github.com/mmozeiko/build-mesa/releases/tag/{version}"
p["source"]["asset"] = os.path.basename(url)
p["source"]["url"] = url
p["source"]["sha256"] = asha
p["source"]["size"] = int(asize)
for f in p["files"]:
    if f["path"].endswith("opengl32.dll"):
        f["path"] = f"{arch}/opengl32.dll"
        f["memberOf"] = os.path.basename(url)
        f["sha256"] = dsha
        f["size"] = int(dsize)
    if f["path"] == "LICENSE":
        f["composedFrom"] = [
            f"https://gitlab.freedesktop.org/mesa/mesa/-/raw/mesa-{version}/docs/license.rst",
            f"https://gitlab.freedesktop.org/mesa/mesa/-/raw/mesa-{version}/licenses/MIT",
        ]
with open(pinned, "w", newline="\n") as fh:
    json.dump(p, fh, indent=2)
    fh.write("\n")
print(f"==> rewrote {pinned}")
PYEOF

echo ""
echo "UPDATED: mesa $VERSION ($DRIVER, $ARCH) vendored."
echo "  Next: update the size table in vendor/mesa-gl/README.md, rebuild, and run"
echo "        powershell -NoProfile -File test\\win32\\startup-failure.ps1"
