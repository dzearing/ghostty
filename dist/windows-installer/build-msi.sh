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
#
# Requires: wixl, msiinfo (brew install msitools), python3 (GUID derivation).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

VERSION=""
BUILD_NUM=1
OUT=""
SKIP_BUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)     VERSION="${2:?--version needs a value}"; shift 2 ;;
    --version=*)   VERSION="${1#*=}"; shift ;;
    --build-num)   BUILD_NUM="${2:?--build-num needs a value}"; shift 2 ;;
    --build-num=*) BUILD_NUM="${1#*=}"; shift ;;
    --out)         OUT="${2:?--out needs a value}"; shift 2 ;;
    --out=*)       OUT="${1#*=}"; shift ;;
    --skip-build)  SKIP_BUILD=1; shift ;;
    -h|--help)     sed -n '2,26p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)             echo "error: unknown arg: $1" >&2; exit 2 ;;
  esac
done

for tool in wixl msiinfo python3; do
  command -v "$tool" >/dev/null || { echo "error: $tool not found (brew install msitools)" >&2; exit 1; }
done

cd "$REPO_ROOT"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  echo "==> zig build (ReleaseFast, x86_64-windows-gnu, win32 apprt)"
  zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
fi

EXE="$REPO_ROOT/zig-out/bin/ghoztty.exe"
SHARE="$REPO_ROOT/zig-out/share"
[[ -f "$EXE" ]] || { echo "error: $EXE not found (build first)" >&2; exit 1; }
[[ -f "$SHARE/terminfo/ghostty.terminfo" ]] || { echo "error: $SHARE/terminfo/ghostty.terminfo missing — resourcesDir sentinel would break" >&2; exit 1; }

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
python3 - "$EXE" "$SHARE" "$WXS" <<'PYEOF'
import os, sys, uuid
from xml.sax.saxutils import escape

exe, share, out = sys.argv[1], sys.argv[2], sys.argv[3]

# Stable namespace for component GUID derivation. NEVER change this, or
# every component changes identity and upgrades misbehave.
NS = uuid.UUID("a934c3a7-a4fa-426d-8aab-2d260aa7563b")

def guid(install_path: str) -> str:
    return str(uuid.uuid5(NS, install_path)).upper()

def ident(s: str) -> str:
    # MSI identifiers: alnum/underscore/dot, must not start with a digit.
    out = "".join(c if (c.isalnum() or c in "._") else "_" for c in s)
    return ("_" + out) if out[:1].isdigit() else out

lines = []
comp_refs = []

def emit_file_component(rel_install_dir, src_path, indent):
    """One component per file, file is the keypath (fine for per-user)."""
    name = os.path.basename(src_path)
    install_path = (rel_install_dir + "\\" + name) if rel_install_dir else name
    cid = ident("C_" + install_path)
    fid = ident("F_" + install_path)
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
            did = ident("D_" + (rel_install_dir + "\\" + e if rel_install_dir else e))
            lines.append(f'{pad}<Directory Id="{did}" Name="{escape(e)}">')
            emit_dir(p, (rel_install_dir + "\\" + e) if rel_install_dir else e, indent + 2)
            lines.append(f'{pad}</Directory>')
        else:
            emit_file_component(rel_install_dir, p, indent)

# INSTALLDIR contents: ghoztty.exe + share tree.
emit_file_component("", exe, 12)
lines.append('            <Directory Id="D_share" Name="share">')
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
           Name="Ghoztty"
           Manufacturer="dzearing"
           Version="@PRODUCT_VERSION@"
           UpgradeCode="5EB02044-7F06-498B-B7A9-7EFD65486CFB"
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

    <Upgrade Id="5EB02044-7F06-498B-B7A9-7EFD65486CFB">
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
          <Directory Id="INSTALLDIR" Name="Ghoztty">
@FILES@
            <!-- Uninstall cleanup for the install root. -->
            <Component Id="C_InstallDirCleanup" Guid="@CLEANUP_GUID@">
              <RegistryValue Root="HKCU"
                             Key="Software\\dzearing\\Ghoztty"
                             Name="InstallDir" Value="[INSTALLDIR]"
                             Type="string" KeyPath="yes"/>
              <RemoveFolder Id="RemoveInstallDir" On="uninstall"/>
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
                    Name="Ghoztty"
                    Target="[INSTALLDIR]ghoztty.exe"
                    WorkingDirectory="INSTALLDIR"
                    Description="Ghoztty terminal emulator"/>
        </Component>
      </Directory>
    </Directory>

    <Feature Id="Ghoztty" Level="1" Title="Ghoztty">
@REFS@
      <ComponentRef Id="C_InstallDirCleanup"/>
      <ComponentRef Id="C_StartMenuShortcut"/>
    </Feature>

    <!-- Stop a running Ghoztty so its exe isn't locked during install,
         upgrade, or uninstall. taskkill exits nonzero when no process
         matches; Return="ignore" makes that a no-op. -->
    <CustomAction Id="SetKillGhozttyCmd"
                  Property="KILLGHOZTTYCMD"
                  Value="[SystemFolder]taskkill.exe"/>
    <CustomAction Id="KillGhoztty"
                  Property="KILLGHOZTTYCMD"
                  ExeCommand="/F /IM ghoztty.exe"
                  Execute="immediate"
                  Return="ignore"/>

    <InstallExecuteSequence>
      <Custom Action="SetKillGhozttyCmd" Before="KillGhoztty"/>
      <Custom Action="KillGhoztty" Before="InstallValidate"/>
      <RemoveExistingProducts After="InstallValidate"/>
    </InstallExecuteSequence>
  </Product>
</Wix>
"""

xml = template.replace("@FILES@", files_xml).replace("@REFS@", refs_xml)
xml = xml.replace("@CLEANUP_GUID@", guid("__installdir_cleanup__"))
xml = xml.replace("@SHORTCUT_GUID@", guid("__startmenu_shortcut__"))
# Version/stamp substituted by the shell (python only handles layout).
with open(out, "w") as f:
    f.write(xml)
print(f"generated {out}: {len(comp_refs)} file components")
PYEOF

# Substitute version/stamp placeholders.
sed -i '' -e "s/@PRODUCT_VERSION@/$PRODUCT_VERSION/g" -e "s/@STAMP@/$VERSION/g" "$WXS"

echo "==> wixl compile"
wixl -o "$OUT" "$WXS"

echo "==> validate"
msiinfo suminfo "$OUT" | head -12
SIZE="$(du -h "$OUT" | cut -f1)"
echo ""
echo "MSI created: $OUT ($SIZE)"
