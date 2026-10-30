#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
python3 scripts/verify_assets.py
CONFIG="${CONFIGURATION:-debug}"
if [[ "$CONFIG" != debug && "$CONFIG" != release ]]; then echo "Invalid CONFIGURATION" >&2; exit 1; fi
swift build --build-system swiftbuild -c "$CONFIG" --product MDViewer
BIN="$(swift build --build-system swiftbuild -c "$CONFIG" --show-bin-path)"
APP="$ROOT/.build/MDViewer.app"
if [[ "$CONFIG" == release ]]; then APP="$ROOT/.build/release-package/MDViewer.app"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MDViewer" "$APP/Contents/MacOS/MDViewer"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :MDViewerBuildConfiguration string $CONFIG" "$APP/Contents/Info.plist"
rm -rf "$APP/Contents/Resources/Web"
cp -R "$ROOT/Resources/Web" "$APP/Contents/Resources/Web"
rm -rf "$APP/Contents/Resources/Notices"
cp -R "$ROOT/Resources/Notices" "$APP/Contents/Resources/Notices"
cp "$ROOT/vendor-manifest.json" "$APP/Contents/Resources/vendor-manifest.json"
python3 scripts/verify_assets.py --bundle "$APP"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "$APP"
