#!/usr/bin/env bash
# build-msi.sh — build the per-user Windows MSI for the Ghoztty terminal.
#
# Generates a WiX source (wixl/WiX-v3 subset) that packages ghoztty.exe plus
# the share/ resource tree (themes, shell-integration, terminfo sentinel that
# src/os/resourcesdir.zig climbs for), compiles it with wixl (GNOME msitools)
# and validates the result with msiinfo — no Windows box needed.
#
# Usage:
#   dist/windows-installer/build-msi.sh [--version <stamp>] [--build-num <N>]
#                                       [--out <path>] [--skip-build]
#                                       [--test-identity <Name>]
#
# Defaults:
#   version    $(date +%Y%m%d)-$(git rev-parse --short HEAD) build stamp,
#              shown in Apps & Features via ARPCOMMENTS. The numeric MSI
#              ProductVersion is derived as yy.m.dNN (e.g. 26.7.501 =
#              2026-07-05 build 01) so newer builds always compare greater
#              and MSI major upgrades fire.
#   build-num  1 — same-day rebuild counter (bump when publishing twice in
#              a day: same ProductVersion refuses to install over itself).
#   out        zig-out/Ghoztty-<yy.m.dNN>-x64.msi
#   --skip-build  reuse zig-out/bin/ghoztty.exe + zig-out/share instead of
#              running zig build (which needs the zig@0.15 PATH exports).
#   --test-identity <Name>  build a THROWAWAY MSI under a distinct product
#              identity (Name, install dir, UpgradeCode, registry key, and
#              component-GUID namespace all derived from <Name>) so on-box
#              install/upgrade/uninstall E2E tests never touch the real
#              Ghoztty product or install dir. Never ship these.
#
# Upgrade-safety design (T23, the 26.7.502 vanishing-exe postmortem):
#   - ghoztty.exe is built with a real per-build FILEVERSION
#     (-Dwindows-file-version=yy.m.d.NN, strictly increasing), and this
#     script mirrors the exe's ACTUAL PE version into the MSI File table
#     (wixl cannot read PE resources, so it emits an empty Version column —
#     Windows Installer then treats the packaged exe as UNVERSIONED, refuses
#     to overwrite the versioned installed exe, and RemoveExistingProducts
#     deletes it: net result "upgrade removed the exe").
#   - The MsiFileHash table is dropped: costing runs BEFORE the early
#     RemoveExistingProducts removes the old product's files, so any
#     unversioned file whose hash matched the installed copy was skipped by
#     InstallFiles and then deleted with the old product. Without hashes,
#     unversioned files fall back to the created/modified-date rule, which
#     always recopies MSI-installed (never user-edited) files.
#
# Requires: wixl, msiinfo (brew install msitools), python3 (GUID derivation).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

VERSION=""
BUILD_NUM=1
OUT=""
SKIP_BUILD=0
TEST_IDENTITY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)     VERSION="${2:?--version needs a value}"; shift 2 ;;
    --version=*)   VERSION="${1#*=}"; shift ;;
    --build-num)   BUILD_NUM="${2:?--build-num needs a value}"; shift 2 ;;
    --build-num=*) BUILD_NUM="${1#*=}"; shift ;;
    --out)         OUT="${2:?--out needs a value}"; shift 2 ;;
    --out=*)       OUT="${1#*=}"; shift ;;
    --skip-build)  SKIP_BUILD=1; shift ;;
    --test-identity)   TEST_IDENTITY="${2:?--test-identity needs a value}"; shift 2 ;;
    --test-identity=*) TEST_IDENTITY="${1#*=}"; shift ;;
    -h|--help)     sed -n '2,50p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)             echo "error: unknown arg: $1" >&2; exit 2 ;;
  esac
done

for tool in wixl msiinfo python3; do
  command -v "$tool" >/dev/null || { echo "error: $tool not found (brew install msitools)" >&2; exit 1; }
done

cd "$REPO_ROOT"

# Per-build FILEVERSION: yy.m.d.NN, strictly increasing across builds so MSI
# file versioning always prefers the newer package exe (see header).
FILE_VERSION="$(date +%-y).$(date +%-m).$(date +%-d).$BUILD_NUM"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  echo "==> zig build (ReleaseFast, x86_64-windows-gnu, win32 apprt, FILEVERSION $FILE_VERSION)"
  zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast \
    "-Dwindows-file-version=$FILE_VERSION"
fi

EXE="$REPO_ROOT/zig-out/bin/ghoztty.exe"
SHARE="$REPO_ROOT/zig-out/share"
[[ -f "$EXE" ]] || { echo "error: $EXE not found (build first)" >&2; exit 1; }
[[ -f "$SHARE/terminfo/ghostty.terminfo" ]] || { echo "error: $SHARE/terminfo/ghostty.terminfo missing — resourcesDir sentinel would break" >&2; exit 1; }

# The exe's ACTUAL PE file version (authoritative even under --skip-build):
# scan for the VS_FIXEDFILEINFO signature (0xFEEF04BD little-endian) and read
# dwFileVersionMS/LS. This is what gets mirrored into the MSI File table.
EXE_FILE_VERSION="$(python3 - "$EXE" <<'PYEOF'
import struct, sys
data = open(sys.argv[1], "rb").read()
i = data.find(b"\xbd\x04\xef\xfe")  # VS_FIXEDFILEINFO dwSignature
if i < 0:
    sys.exit("error: no VS_FIXEDFILEINFO in exe (version resource missing)")
ms, ls = struct.unpack_from("<II", data, i + 8)
print(f"{ms >> 16}.{ms & 0xFFFF}.{ls >> 16}.{ls & 0xFFFF}")
PYEOF
)"
if [[ "$SKIP_BUILD" -eq 0 && "$EXE_FILE_VERSION" != "$FILE_VERSION" ]]; then
  echo "error: built exe reports FILEVERSION $EXE_FILE_VERSION, expected $FILE_VERSION" >&2
  exit 1
fi
if [[ "$EXE_FILE_VERSION" == "0.1.0.0" ]]; then
  echo "warning: exe carries the 0.1.0.0 dev FILEVERSION — MSI upgrades over an equal/higher version will not replace it (rebuild without --skip-build, or with -Dwindows-file-version)" >&2
fi

# Build stamp + numeric MSI ProductVersion (yy.m.dNN).
if [[ -z "$VERSION" ]]; then
  VERSION="$(date +%Y%m%d)-$(git rev-parse --short HEAD)"
fi
YY="$(date +%y)"; M="$(date +%-m)"; D="$(date +%-d)"
NN="$(printf '%02d' "$BUILD_NUM")"
PRODUCT_VERSION="$YY.$M.$D$NN"
[[ -n "$OUT" ]] || OUT="$REPO_ROOT/zig-out/Ghoztty-$PRODUCT_VERSION-x64.msi"

echo "==> stamp:          $VERSION"
echo "==> ProductVersion: $PRODUCT_VERSION"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WXS="$WORK/ghoztty.wxs"

# Generate the WiX source. Directory tree + one component per file with
# GUIDs derived deterministically from the install path (uuid5) so component
# identity is stable across builds (MSI component rules).
python3 - "$EXE" "$SHARE" "$WXS" "$TEST_IDENTITY" <<'PYEOF'
import os, sys, uuid, hashlib
from xml.sax.saxutils import escape

exe, share, out = sys.argv[1], sys.argv[2], sys.argv[3]
identity = sys.argv[4] if len(sys.argv) > 4 else ""

# Stable namespace for component GUID derivation. NEVER change this, or
# every component changes identity and upgrades misbehave.
NS = uuid.UUID("a934c3a7-a4fa-426d-8aab-2d260aa7563b")

# Throwaway test identity (--test-identity): distinct product name, install
# dir, UpgradeCode, registry key, AND component-GUID namespace, so a test
# install/upgrade/uninstall cycle shares nothing with the real product.
PRODUCT_NAME = identity or "Ghoztty"
UPGRADE_CODE = (
    "5EB02044-7F06-498B-B7A9-7EFD65486CFB"
    if not identity
    else str(uuid.uuid5(NS, "upgradecode::" + identity)).upper()
)
if identity:
    NS = uuid.uuid5(NS, "identity::" + identity)

def guid(install_path: str) -> str:
    return str(uuid.uuid5(NS, install_path)).upper()

# MSI Component/File/Directory key columns are s72 — max 72 chars. Deriving
# an identifier from the full install path blows past that for deeply nested
# files (e.g. share/ghostty/shell-integration/fish/vendor_conf.d/...), and
# Windows Installer then REJECTS the package at validation and silently rolls
# back the install. So identifiers are a short prefix + a hash of the install
# path: always well under 72 chars, unique, and stable across builds (the
# path is the identity). The human-readable path lives in File.Name /
# Directory.Name, which are l255/l255 and have no such limit.
def ident(prefix: str, install_path: str) -> str:
    h = hashlib.sha1(install_path.encode("utf-8")).hexdigest()[:20]
    return f"{prefix}{h}"  # e.g. c1a2b3... — <=21 chars, starts with a letter

lines = []
comp_refs = []

def emit_file_component(rel_install_dir, src_path, indent):
    """One component per file, file is the keypath (fine for per-user)."""
    name = os.path.basename(src_path)
    install_path = (rel_install_dir + "\\" + name) if rel_install_dir else name
    cid = ident("c", install_path)
    fid = ident("f", install_path)
    pad = " " * indent
    lines.append(f'{pad}<Component Id="{cid}" Guid="{guid(install_path)}">')
    lines.append(f'{pad}  <File Id="{fid}" Name="{escape(name)}" KeyPath="yes" Source="{escape(src_path)}"/>')
    lines.append(f'{pad}</Component>')
    comp_refs.append(cid)

def emit_dir(fs_dir, rel_install_dir, indent):
    pad = " " * indent
    entries = sorted(os.listdir(fs_dir))
    for e in entries:
        p = os.path.join(fs_dir, e)
        if os.path.islink(p):
            # zig terminfo trees can contain symlinks; skip them (MSI/Windows
            # ZIP-style consumers can't represent them; the .terminfo source
            # file is what resourcesDir needs).
            continue
        if os.path.isdir(p):
            rel = (rel_install_dir + "\\" + e) if rel_install_dir else e
            did = ident("d", rel)
            lines.append(f'{pad}<Directory Id="{did}" Name="{escape(e)}">')
            emit_dir(p, rel, indent + 2)
            lines.append(f'{pad}</Directory>')
        else:
            emit_file_component(rel_install_dir, p, indent)

# INSTALLDIR contents: ghoztty.exe + share tree.
emit_file_component("", exe, 12)
lines.append(f'            <Directory Id="{ident("d", "share")}" Name="share">')
emit_dir(share, "share", 14)
lines.append('            </Directory>')

files_xml = "\n".join(lines)
refs_xml = "\n".join(f'      <ComponentRef Id="{c}"/>' for c in comp_refs)

template = """<?xml version="1.0" encoding="utf-8"?>
<!--
  ghoztty.wxs — per-user MSI for the Ghoztty terminal (Windows beta).
  GENERATED by dist/windows-installer/build-msi.sh — do not edit.

  Modeled on relay/deploy/msi/ghoztty-agent.wxs (the proven wixl pipeline):
  per-user (no elevation), %LOCALAPPDATA%\\Programs\\Ghoztty, Start Menu
  shortcut, permanent UpgradeCode for major upgrades, taskkill custom action
  so a running terminal doesn't trip files-in-use.
-->
<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">
  <Product Id="*"
           Name="@PRODUCT_NAME@"
           Manufacturer="dzearing"
           Version="@PRODUCT_VERSION@"
           UpgradeCode="@UPGRADE_CODE@"
           Language="1033">

    <Package InstallerVersion="500"
             InstallScope="perUser"
             Compressed="yes"
             Description="Ghoztty terminal emulator (Windows beta)"
             Comments="Build @STAMP@"/>

    <Media Id="1" Cabinet="ghoztty.cab" EmbedCab="yes"/>

    <Property Id="MSIINSTALLPERUSER" Value="1"/>
    <Property Id="ARPCOMMENTS" Value="Build @STAMP@"/>
    <Property Id="ARPNOMODIFY" Value="1"/>

    <Upgrade Id="@UPGRADE_CODE@">
      <UpgradeVersion Minimum="0.0.0" IncludeMinimum="yes"
                      Maximum="@PRODUCT_VERSION@" IncludeMaximum="no"
                      Property="OLDERVERSIONFOUND" MigrateFeatures="yes"/>
      <UpgradeVersion Minimum="@PRODUCT_VERSION@" IncludeMinimum="yes"
                      OnlyDetect="yes"
                      Property="NEWERVERSIONFOUND"/>
    </Upgrade>

    <Condition Message="A newer version of Ghoztty is already installed.">NOT NEWERVERSIONFOUND</Condition>

    <Directory Id="TARGETDIR" Name="SourceDir">
      <Directory Id="LocalAppDataFolder">
        <Directory Id="ProgramsDir" Name="Programs">
          <Directory Id="INSTALLDIR" Name="@PRODUCT_NAME@">
@FILES@
            <!-- Uninstall cleanup for the install root. -->
            <Component Id="C_InstallDirCleanup" Guid="@CLEANUP_GUID@">
              <RegistryValue Root="HKCU"
                             Key="Software\\dzearing\\@PRODUCT_NAME@"
                             Name="InstallDir" Value="[INSTALLDIR]"
                             Type="string" KeyPath="yes"/>
              <RemoveFolder Id="RemoveInstallDir" On="uninstall"/>
            </Component>
            <!-- User PATH entry so `ghoztty` resolves from any shell (T70).
                 Removed automatically on uninstall (Permanent=no). The app
                 also self-heals this entry on launch (PathInstaller.zig),
                 which covers pre-existing installs and manual deletion. -->
            <Component Id="C_UserPathEntry" Guid="@PATHENV_GUID@">
              <RegistryValue Root="HKCU"
                             Key="Software\\dzearing\\@PRODUCT_NAME@"
                             Name="PathEntry" Value="1"
                             Type="integer" KeyPath="yes"/>
              <Environment Id="E_UserPath" Name="PATH"
                           Value="[INSTALLDIR]"
                           Part="last" Action="set" Permanent="no"
                           System="no"/>
            </Component>
          </Directory>
        </Directory>
      </Directory>

      <Directory Id="ProgramMenuFolder">
        <Component Id="C_StartMenuShortcut" Guid="@SHORTCUT_GUID@">
          <RegistryValue Root="HKCU"
                         Key="Software\\dzearing\\Ghoztty"
                         Name="Shortcut" Value="1"
                         Type="integer" KeyPath="yes"/>
          <Shortcut Id="GhozttyStartMenuShortcut"
                    Name="@PRODUCT_NAME@"
                    Target="[INSTALLDIR]ghoztty.exe"
                    WorkingDirectory="INSTALLDIR"
                    Description="Ghoztty terminal emulator"/>
        </Component>
      </Directory>
    </Directory>

    <Feature Id="Ghoztty" Level="1" Title="@PRODUCT_NAME@">
@REFS@
      <ComponentRef Id="C_InstallDirCleanup"/>
      <ComponentRef Id="C_UserPathEntry"/>
      <ComponentRef Id="C_StartMenuShortcut"/>
    </Feature>

    <!-- The beta deliberately omits a taskkill custom action. A type-50 EXE
         custom action running taskkill.exe pops a console window during
         install (alarming for a first-time install) and buys nothing on a
         fresh install. If a future upgrade needs to replace a running exe,
         the user is told to close Ghoztty first. Keep the install a pure
         file-copy + shortcut + registry write for maximum robustness. -->
    <InstallExecuteSequence>
      <RemoveExistingProducts After="InstallValidate"/>
    </InstallExecuteSequence>
  </Product>
</Wix>
"""

xml = template.replace("@FILES@", files_xml).replace("@REFS@", refs_xml)
xml = xml.replace("@CLEANUP_GUID@", guid("__installdir_cleanup__"))
xml = xml.replace("@SHORTCUT_GUID@", guid("__startmenu_shortcut__"))
xml = xml.replace("@PATHENV_GUID@", guid("__user_path_entry__"))
xml = xml.replace("@PRODUCT_NAME@", PRODUCT_NAME)
xml = xml.replace("@UPGRADE_CODE@", UPGRADE_CODE)
# Version/stamp substituted by the shell (python only handles layout).
with open(out, "w") as f:
    f.write(xml)
tag = f" [TEST IDENTITY: {PRODUCT_NAME} / {UPGRADE_CODE}]" if identity else ""
print(f"generated {out}: {len(comp_refs)} file components{tag}")
PYEOF

# Substitute version/stamp placeholders (portable across BSD/GNU sed).
sed -e "s/@PRODUCT_VERSION@/$PRODUCT_VERSION/g" -e "s/@STAMP@/$VERSION/g" "$WXS" > "$WXS.tmp"
mv "$WXS.tmp" "$WXS"

echo "==> wixl compile (x64)"
# -a x64: without it wixl emits an x86 package (Template "Intel") for our
# 64-bit exe, and the product registers under the WOW6432Node registry view.
wixl -a x64 -o "$OUT" "$WXS"

# wixl (msitools <= 0.106) ignores Environment/@Permanent="no": it emits the
# Name column as `=PATH` instead of `=-PATH`, and without the `-` flag
# Windows Installer leaves the user PATH entry behind on uninstall (verified
# empirically on-box, T70). Patch the Environment table post-compile.
echo "==> patch Environment table (=PATH -> =-PATH for uninstall removal)"
TAB="$(printf '\t')"
msiinfo export "$OUT" Environment > "$WORK/Environment.idt"
grep -q "${TAB}=PATH${TAB}" "$WORK/Environment.idt" || {
  echo "error: Environment table has no =PATH row to patch (wixl behavior changed?)" >&2
  exit 1
}
sed -e "s/${TAB}=PATH${TAB}/${TAB}=-PATH${TAB}/" "$WORK/Environment.idt" > "$WORK/Environment.idt.new"
mv "$WORK/Environment.idt.new" "$WORK/Environment.idt"
msibuild "$OUT" -i "$WORK/Environment.idt"

# wixl cannot read PE version resources, so it leaves File.Version EMPTY for
# ghoztty.exe. Windows Installer then treats the packaged exe as UNVERSIONED
# and refuses to overwrite the (versioned) installed exe on major upgrade,
# while RemoveExistingProducts deletes the old copy — the 26.7.502
# vanishing-exe bug. Mirror the exe's actual PE version into the File table.
echo "==> patch File table (ghoztty.exe Version = $EXE_FILE_VERSION)"
msiinfo export "$OUT" File > "$WORK/File.idt"
python3 - "$WORK/File.idt" "$EXE_FILE_VERSION" <<'PYEOF'
import sys
path, ver = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8", newline="") as f:
    content = f.read()
sep = "\r\n" if "\r\n" in content else "\n"
lines = content.split(sep)
patched = 0
for i, line in enumerate(lines):
    fields = line.split("\t")
    if len(fields) >= 5 and fields[2] == "ghoztty.exe":
        fields[4] = ver
        lines[i] = "\t".join(fields)
        patched += 1
if patched != 1:
    sys.exit(f"error: expected exactly 1 ghoztty.exe row in File table, found {patched}")
with open(path, "w", encoding="utf-8", newline="") as f:
    f.write(sep.join(lines))
PYEOF
msibuild "$OUT" -i "$WORK/File.idt"

# Drop all MsiFileHash rows (import an empty table). File costing runs BEFORE
# the early RemoveExistingProducts deletes the old product's files, so an
# unversioned file whose hash matches the installed copy is skipped by
# InstallFiles and then deleted with the old product — every unchanged
# share/ file would vanish on upgrade. Without hashes, unversioned files use
# the created/modified-date rule, which always recopies MSI-installed files.
echo "==> drop MsiFileHash table (force unversioned-file recopy on upgrade)"
printf 'File_\tOptions\tHashPart1\tHashPart2\tHashPart3\tHashPart4\r\ns72\ti2\ti4\ti4\ti4\ti4\r\nMsiFileHash\tFile_\r\n' > "$WORK/MsiFileHash.idt"
msibuild "$OUT" -i "$WORK/MsiFileHash.idt"

echo "==> validate"
msiinfo suminfo "$OUT" | head -12
SIZE="$(du -h "$OUT" | cut -f1)"
echo ""
echo "MSI created: $OUT ($SIZE)"
