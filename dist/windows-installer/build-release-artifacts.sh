#!/usr/bin/env bash
# build-release-artifacts.sh -- produce the full set of Windows release
# artifacts for one version (T38).
#
# This is the single definition of "what a Windows release ships", shared by
# the two callers that ship it:
#
#   * .github/workflows/release-windows.yml -- fires on the same vX.Y.Z tag
#     push that builds the macOS DMG, so one release produces both
#     platforms' artifacts at the same version.
#   * scripts/publish-windows-release.ps1 -- the on-box manual path
#     (cross-checks and publishes from the Windows machine).
#
# Both end up with byte-identical artifact SETS because the layout, the
# names, and the build flags live here and nowhere else.
#
# Produces, in --out-dir (default zig-out):
#   Ghoztty-<semver>-x64.msi           per-user installer (build-msi.sh)
#   Ghoztty-portable-<semver>-x64.zip  no-installer layout (build-portable-zip.sh)
#
# Usage:
#   dist/windows-installer/build-release-artifacts.sh --semver <X.Y.Z>
#       [--build-num <N>] [--stamp <s>] [--out-dir <dir>] [--skip-build]
#
#   --skip-build  reuse zig-out/bin/ghoztty.exe + zig-out/share. The exe
#                 must ALREADY carry -Dversion-string=<semver>+<hash> (the
#                 on-box script builds natively on Windows, then packages
#                 here); this script verifies that rather than assuming it.
#
# Requires: wixl + msiinfo + python3 (packaging), and zig unless
# --skip-build. Everything runs on Linux/macOS -- no Windows box needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

SEMVER=""
BUILD_NUM=1
STAMP=""
OUT_DIR=""
SKIP_BUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --semver)      SEMVER="${2:?--semver needs a value}"; shift 2 ;;
    --semver=*)    SEMVER="${1#*=}"; shift ;;
    --build-num)   BUILD_NUM="${2:?--build-num needs a value}"; shift 2 ;;
    --build-num=*) BUILD_NUM="${1#*=}"; shift ;;
    --stamp)       STAMP="${2:?--stamp needs a value}"; shift 2 ;;
    --stamp=*)     STAMP="${1#*=}"; shift ;;
    --out-dir)     OUT_DIR="${2:?--out-dir needs a value}"; shift 2 ;;
    --out-dir=*)   OUT_DIR="${1#*=}"; shift ;;
    --skip-build)  SKIP_BUILD=1; shift ;;
    -h|--help)     sed -n '2,34p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)             echo "error: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$SEMVER" ]] || { echo "error: --semver <X.Y.Z> is required" >&2; exit 2; }
[[ "$SEMVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "error: --semver must be X.Y.Z (got '$SEMVER')" >&2; exit 2; }

cd "$REPO_ROOT"
HASH="$(git rev-parse --short HEAD)"
[[ -n "$STAMP" ]] || STAMP="$(date +%Y%m%d)-$HASH"
[[ -n "$OUT_DIR" ]] || OUT_DIR="$REPO_ROOT/zig-out"
mkdir -p "$OUT_DIR"

MSI="$OUT_DIR/Ghoztty-$SEMVER-x64.msi"
ZIP="$OUT_DIR/Ghoztty-portable-$SEMVER-x64.zip"

# The FILEVERSION rule lives in build-msi.sh; ask for it (see its
# --print-file-version) instead of keeping a second copy of the formula.
FILE_VERSION="$(bash "$SCRIPT_DIR/build-msi.sh" --print-file-version --build-num "$BUILD_NUM")"

echo "== windows release artifacts: $SEMVER+$HASH (stamp $STAMP, FILEVERSION $FILE_VERSION) =="

# -- 1. the exe ----------------------------------------------------------
if [[ "$SKIP_BUILD" -eq 0 ]]; then
  command -v zig >/dev/null || { echo "error: zig not found (needed without --skip-build)" >&2; exit 1; }
  echo "==> zig build (ReleaseFast, x86_64-windows-gnu, win32 apprt)"
  # -Dwindows-update-check=true: only channel builds phone home (T24).
  # -Dagent-semver: the agent sibling's VERSIONINFO matches the tag (T89h).
  # -Dstrip=false: a stripped release produces undebuggable crash dumps --
  # the same reason the on-box delivery build carries it (CLAUDE.md).
  zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast \
    -Dstrip=false \
    "-Dwindows-file-version=$FILE_VERSION" \
    "-Dversion-string=$SEMVER+$HASH" \
    "-Dagent-semver=$SEMVER" \
    "-Dwindows-update-check=true"
fi

EXE="$REPO_ROOT/zig-out/bin/ghoztty.exe"
[[ -f "$EXE" ]] || { echo "error: $EXE not found" >&2; exit 1; }

# The exe must carry the release semver: it is what the in-app update check
# compares against the win-v<semver> tag (T24), and under --skip-build it is
# the only thing standing between a stale zig-out and a mislabelled release.
# Scanned out of the binary rather than executed, so this works on a Linux
# CI runner where the exe cannot run at all.
python3 - "$EXE" "$SEMVER+$HASH" <<'PYEOF'
import sys
exe, want = sys.argv[1], sys.argv[2]
data = open(exe, "rb").read()
needle = want.encode("utf-8")
if needle not in data and needle.decode().encode("utf-16-le") not in data:
    sys.exit(f"error: {exe} does not embed version string {want} "
             "(stale zig-out, or the build lost -Dversion-string)")
print(f"==> exe embeds {want}")
PYEOF

# -- 2. MSI + portable ZIP ----------------------------------------------
echo "==> MSI"
bash "$SCRIPT_DIR/build-msi.sh" --skip-build \
  --semver "$SEMVER" --build-num "$BUILD_NUM" --version "$STAMP" --out "$MSI"

echo "==> portable ZIP"
bash "$SCRIPT_DIR/build-portable-zip.sh" \
  --semver "$SEMVER" --stamp "$STAMP" --out "$ZIP"

# -- 3. report ------------------------------------------------------------
for f in "$MSI" "$ZIP"; do
  [[ -f "$f" ]] || { echo "error: $f missing after build" >&2; exit 1; }
done
echo ""
echo "== windows release artifacts for $SEMVER =="
ls -lh "$MSI" "$ZIP" | sed 's/^/    /'
