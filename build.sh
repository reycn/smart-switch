#!/bin/bash
# Build, sign, install and launch SmartSwitch.
#   ./build.sh            build + sign + install to /Applications + relaunch
#   ./build.sh build      build + sign only (into build/SmartSwitch.app)
#   SIGN_IDENTITY="Apple Development: …" ./build.sh   pick a specific identity
set -euo pipefail
cd "$(dirname "$0")"

APP=SmartSwitch
OUT=build/$APP.app
DEST=${DEST:-/Applications/$APP.app}
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')}
[ -n "$IDENTITY" ] || { echo "no Apple Development identity found; set SIGN_IDENTITY" >&2; exit 1; }

echo "▸ cargo build"
MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --release --manifest-path core/Cargo.toml

echo "▸ swift build"
swift build -c release --product "$APP" 2>&1 | grep -vE '^\[|Compiling|Emitting|Linking|Build complete|Fetching|Fetched|Computing|Creating working|Working copy|Resolved' || true
BIN=$(swift build -c release --show-bin-path)
[ -x "$BIN/$APP" ] || { echo "swift build failed" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN/$APP" "$OUT/Contents/MacOS/$APP"
cp -R "$BIN"/*.bundle "$OUT/Contents/Resources/"   # PermissionFlow localized strings
cp app/Info.plist "$OUT/Contents/Info.plist"
printf 'APPL????' > "$OUT/Contents/PkgInfo"

echo "▸ icon"
rm -rf build/AppIcon.iconset
swift tools/make-icon.swift icon.png build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$OUT/Contents/Resources/AppIcon.icns"

echo "▸ codesign ($IDENTITY)"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$OUT"
codesign --verify --strict "$OUT"

[ "${1:-install}" = build ] && { echo "built $OUT"; exit 0; }

echo "▸ install → $DEST"
pkill -x "$APP" 2>/dev/null && sleep 1 || true
rm -rf "$DEST"
ditto "$OUT" "$DEST"
open "$DEST" || { sleep 1; open "$DEST"; }   # LaunchServices can still hold the old process for a moment
echo "launched $DEST"
