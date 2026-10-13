#!/usr/bin/env bash
#
# build-kext-clt.sh — build IntelBluetoothFirmware on a macOS box that has only the
# Command Line Tools (no full Xcode).
#
# Background: `xcodebuild` refuses to run against a CLT-only install
#   ("requires Xcode, but active developer directory ... is a command line tools instance")
# but the CLT SDK *does* ship Kernel.framework headers and clang can emit and link
# kext bundles directly. Verified on macOS 15.8.1 with CLT SDK MacOSX.sdk:
#     Mach-O 64-bit kext bundle x86_64
#
# Run from the repo root (the directory containing IntelBluetoothFirmware/ and
# IntelBluetoothFirmware.xcodeproj/).
#
#   ./build-kext-clt.sh
#
# Output: build/IntelBluetoothFirmware.kext
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

APP="IntelBluetoothFirmware"
KEXT="build/${APP}.kext"
STAGE="build/${APP}.stage"
BUNDLE_ID="com.zxystd.IntelBluetoothFirmware"
MODULE_VERSION="2.5.0"
DEPLOY="10.12"
SDK="$(xcrun --show-sdk-path)"
KHEADERS="${SDK}/System/Library/Frameworks/Kernel.framework/Headers"

say() { printf '  %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------- injector target
# A second, plist-only target. IntelBluetoothInjector.kext has no executable: it
# exists solely to add Intel device IDs to Apple's Bluetooth USB transport
# personalities. Its source Info.plist is an Xcode template containing
# $(PRODUCT_BUNDLE_IDENTIFIER) and friends, and "building" it means substituting
# those. Xcode does that automatically; this script has to do it by hand, and
# skipping it produces a bundle whose CFBundleIdentifier is the literal string
# "$(PRODUCT_BUNDLE_IDENTIFIER)", which cannot load.
#
# Usage: ./build-kext-clt.sh IntelBluetoothInjector
if [ "${1:-IntelBluetoothFirmware}" = "IntelBluetoothInjector" ]; then
    APP="IntelBluetoothInjector"
    KEXT="build/${APP}.kext"
    BUNDLE_ID="com.zxystd.IntelBluetoothInjector"
    MODULE_VERSION="2.5.0"

    [ -f "${APP}/Info.plist" ] || die "run this from the repo root."
    say "building plist-only target: ${APP}"

    rm -rf "$KEXT"
    mkdir -p "${KEXT}/Contents"

    python3 - "${APP}/Info.plist" "${KEXT}/Contents/Info.plist" \
             "$BUNDLE_ID" "$APP" "$MODULE_VERSION" <<'PYSUB'
import plistlib, sys
src, dst, bundle_id, name, version = sys.argv[1:6]
subs = {
    '$(DEVELOPMENT_LANGUAGE)':       'en',
    '$(PRODUCT_BUNDLE_IDENTIFIER)':  bundle_id,
    '$(PRODUCT_NAME)':               name,
    '$(PRODUCT_NAME:rfc1034identifier)': name,
    '$(PRODUCT_BUNDLE_PACKAGE_TYPE)':'KEXT',
    '$(MODULE_VERSION)':             version,
}
def fix(v):
    if isinstance(v, str):
        return subs.get(v, v)
    if isinstance(v, dict):
        return {k: fix(x) for k, x in v.items()}
    if isinstance(v, list):
        return [fix(x) for x in v]
    return v

d = fix(plistlib.load(open(src, 'rb')))

# A codeless kext must NOT declare CFBundleExecutable at all. Present-but-empty
# panics the kernel in OSKext::setVMAttributes during prelinked injection, so
# remove it rather than blank it.
d.pop('CFBundleExecutable', None)

plistlib.dump(d, open(dst, 'wb'))
PYSUB

    # Verify the three properties that make this a valid codeless injector.
    python3 - "$KEXT" <<'PYCHK'
import plistlib, sys, os
kext = sys.argv[1]
info = os.path.join(kext, 'Contents', 'Info.plist')
d = plistlib.load(open(info, 'rb'))
raw = open(info).read()
assert '$(' not in raw, "unsubstituted Xcode build variable remains"
assert 'CFBundleExecutable' not in d, "codeless kext must not declare CFBundleExecutable"
assert not os.path.exists(os.path.join(kext, 'Contents', 'MacOS')), \
    "codeless kext must not have Contents/MacOS"
assert d['CFBundleIdentifier'].startswith('com.'), d['CFBundleIdentifier']
assert d['CFBundlePackageType'] == 'KEXT', d['CFBundlePackageType']
n = len(d.get('IOKitPersonalities', {}))
assert n > 0, "no personalities"
print(f"  personalities: {n}")
print(f"  bundle id:     {d['CFBundleIdentifier']}")
print(f"  codeless:      no CFBundleExecutable, no Contents/MacOS")
PYCHK

    say "ad-hoc signing..."
    codesign --force --sign - --timestamp=none "$KEXT" >/dev/null 2>&1 || true

    echo
    say "built: $KEXT"
    find "$KEXT" -type f | sed 's/^/  /'
    echo
    echo "install it (SIP must be off for the kext to load):"
    echo "  sudo cp -R $KEXT /Library/Extensions/ && sudo chown -R root:wheel /Library/Extensions/${APP}.kext"
    echo "or add it to OpenCore: EFI/OC/Kexts + a Kernel->Add entry in EFI/OC/config.plist"
    exit 0
fi

# ----------------------------------------------------------------- preflight
[ -f "${APP}/IntelBluetoothFirmware.cpp" ] || die "run this from the repo root."
command -v python3 >/dev/null || die "python3 required (used to generate FwBinary.cpp)."
[ -d "$KHEADERS" ] || die "Kernel.framework headers not found at $KHEADERS"
say "SDK:        $SDK"
say "kernel hdr: $KHEADERS"

# ----------------------------------------------------------------- MacKernelSDK
if [ ! -d MacKernelSDK ]; then
    say "cloning MacKernelSDK..."
    git clone -q --depth=1 https://github.com/acidanthera/MacKernelSDK.git || die "MacKernelSDK clone failed"
fi

# ----------------------------------------------------------------- Lilu SDK (headers only)
# The kext includes Lilu's plugin_start.cpp and its headers.
if [ ! -d Lilu.kext/Contents/Resources/Library ]; then
    say "fetching Lilu SDK (headers only)..."
    rm -rf .lilu-src
    git clone -q --depth=1 https://github.com/acidanthera/Lilu.git .lilu-src || die "Lilu clone failed"
    # Lilu ships several headers as SYMLINKS into ../hde/ and ../PrivateHeaders/
    # (e.g. Headers/hde64.h -> ../../hde/hde64.h). Copy with -L so every header
    # becomes a real file and no relative link can dangle. hde/ first, so its
    # symlink targets exist while dereferencing.
    rm -rf Lilu.kext/Contents
    mkdir -p Lilu.kext/Contents/Resources
    for d in hde PrivateHeaders Headers Library; do
        [ -e ".lilu-src/Lilu/$d" ] || continue
        cp -RL ".lilu-src/Lilu/$d" Lilu.kext/Contents/Resources/
    done
    rm -rf .lilu-src
    [ -f "Lilu.kext/Contents/Resources/Headers/plugin_start.hpp" ] || die "Lilu SDK staging failed"
    [ -f "Lilu.kext/Contents/Resources/Headers/hde64.h" ] || die "Lilu hde64.h missing after staging"
fi

# ----------------------------------------------------------------- firmware table
say "generating FwBinary.cpp from fw/ ..."
rm -f "${APP}/FwBinary.cpp"
python3 -c "
import sys
sys.path.append('scripts')
import zlib_compress_fw
zlib_compress_fw.process_files('${APP}/FwBinary.cpp', '${APP}/fw/')
"
[ -s "${APP}/FwBinary.cpp" ] || die "FwBinary.cpp generation failed"
say "FwBinary.cpp: $(wc -c < "${APP}/FwBinary.cpp") bytes"

# ----------------------------------------------------------------- sources
# Target IntelBluetoothFirmware sources (plugin_start.cpp comes from Lilu).
# zutil.c is a .c file but is compiled as C++: it already wraps its bodies in
# extern "C" and it pulls in FwData.h, which is a C++ header.
CPP_SOURCES=(
    "${APP}/BtIntel.cpp"
    "${APP}/BtIntelFw.cpp"
    "${APP}/BtIntelVSC.cpp"
    "${APP}/IntelBluetoothFirmware.cpp"
    "${APP}/IntelBluetoothOpsGen1.cpp"
    "${APP}/IntelBluetoothOpsGen2.cpp"
    "${APP}/IntelBluetoothOpsGen3.cpp"
    "${APP}/USBDeviceController.cpp"
    "${APP}/FwBinary.cpp"
    "${APP}/zutil.c"
    "${APP}/kmodinfo.cpp"
)
# NOTE: Lilu's Library/plugin_start.cpp is deliberately NOT linked in.
# The kext uses no Lilu APIs; plugin_start.cpp was the only thing pulling in
# _lilu_os_log / LiluAPI::* / _PRODUCT_NAME_config, and linking it without
# declaring a Lilu dependency makes the kernel-collection builder reject the
# kext with "Failed to bind ... as could not find a kext which exports this
# symbol". Lilu is instead declared as a library dependency in Info.plist.
C_SOURCES=(
)

for f in "${CPP_SOURCES[@]}"; do
    [ -f "$f" ] || die "missing source: $f"
done

# ----------------------------------------------------------------- compile
rm -rf "$STAGE"; mkdir -p "$STAGE"

INCLUDES=(
    -IMacKernelSDK/Headers
    -I"${APP}"
    -I"Lilu.kext/Contents/Resources"
)
COMMON=(
    -mkernel -fno-builtin -fno-common -fno-exceptions -fno-rtti
    -DKERNEL=1
    -DKMOD_NAME="\"${BUNDLE_ID}\""
    -DKMOD_VERSION="\"${MODULE_VERSION}\""
    -mmacosx-version-min="$DEPLOY" -isysroot "$SDK"
    -Wno-everything
)
OBJS=()

say "compiling..."
for src in "${CPP_SOURCES[@]}"; do
    obj="${STAGE}/$(basename "${src%.*}").o"
    xcrun clang++ "${COMMON[@]}" "${INCLUDES[@]}" -std=gnu++14 \
        -include "${APP}/FwData.h" -c "$src" -o "$obj" \
        || die "compile failed: $src"
    OBJS+=("$obj")
done
for src in "${C_SOURCES[@]:-}"; do
    [ -n "$src" ] || continue
    obj="${STAGE}/$(basename "${src%.*}").o"
    xcrun clang "${COMMON[@]}" "${INCLUDES[@]}" -std=gnu11 \
        -c "$src" -o "$obj" \
        || die "compile failed: $src"
    OBJS+=("$obj")
done
say "compiled ${#OBJS[@]} objects"

# ----------------------------------------------------------------- bundle
rm -rf "$KEXT"
mkdir -p "${KEXT}/Contents/MacOS"
EXE="${KEXT}/Contents/MacOS/${APP}"

xcrun clang++ -mkernel -nostdlib -r -Xlinker -kext \
    -mmacosx-version-min="$DEPLOY" -isysroot "$SDK" \
    "${OBJS[@]}" -o "$EXE" || die "link failed"

xcrun strip -x "$EXE" 2>/dev/null || true

cat > "${KEXT}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>${APP}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${APP}</string>
	<key>CFBundlePackageType</key>
	<string>KEXT</string>
	<key>CFBundleShortVersionString</key>
	<string>2.4.0</string>
	<key>CFBundleVersion</key>
	<string>2.4.0</string>
	<key>OSBundleLibraries</key>
	<dict>
		<key>com.apple.iokit.IOUSBHostFamily</key>
		<string>1.2</string>
		<key>com.apple.kpi.iokit</key>
		<string>16.7</string>
		<key>com.apple.kpi.libkern</key>
		<string>16.7</string>
		<key>com.apple.kpi.mach</key>
		<string>16.7</string>
	</dict>
</dict>
</plist>
PLIST

# IOKitPersonalities must come from the patched Info.plist (adds idProduct 55).
python3 - "$APP/Info.plist" "${KEXT}/Contents/Info.plist" <<'PY'
import plistlib, sys
src = plistlib.load(open(sys.argv[1], 'rb'))
dst = plistlib.load(open(sys.argv[2], 'rb'))
dst['IOKitPersonalities'] = src['IOKitPersonalities']
dst['NSHumanReadableCopyright'] = src.get('NSHumanReadableCopyright', '')
ids = sorted(p.get('idProduct') for p in src['IOKitPersonalities'].values())
plistlib.dump(dst, open(sys.argv[2], 'wb'))
print(f"    personalities: {len(ids)}; idProducts: {ids}")
assert 55 in ids, "idProduct 55 missing from merged Info.plist"
print("    idProduct 55 present: OK")
PY

# Ad-hoc sign. Must come AFTER the Info.plist is final, and macOS 15's kmutil
# rejects an unsigned kext ("Bad code signature").
say "ad-hoc signing..."
codesign --force --sign - --timestamp=none "$KEXT" >/dev/null 2>&1 \
    || die "codesign failed"
codesign -dv "$KEXT" 2>&1 | grep -E 'Signature|Format' | sed 's/^/  /'

echo
say "built: $KEXT"
ls -l "$EXE" | awk '{printf "  executable: %s bytes\n", $5}'
file "$EXE" | sed 's/^/  /'
echo
echo "install it (SIP must be off for the kext to load):"
echo "  sudo cp -R $KEXT /Library/Extensions/ && sudo chown -R root:wheel /Library/Extensions/${APP}.kext"
echo "  sudo kmutil load -p /Library/Extensions/${APP}.kext"
echo "or add it to OpenCore: EFI/OC/Kexts + a Kernel->Add entry in EFI/OC/config.plist"
