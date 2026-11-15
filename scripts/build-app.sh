#!/bin/bash
# Builds "Clipboard Memory.app" into ./dist (release, ad-hoc signed). Usage: scripts/build-app.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/Clipboard Memory.app"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/ClipboardMemory"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClipboardMemory"

ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Clipboard Memory</string>
  <key>CFBundleDisplayName</key><string>Clipboard Memory</string>
  <key>CFBundleIdentifier</key><string>com.clipboardmemory.app</string>
  <key>CFBundleExecutable</key><string>ClipboardMemory</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Local-only clipboard history. No data leaves this Mac.</string>
</dict></plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built: $APP"
if [[ "${1:-}" == "--install" ]]; then
  pkill -x ClipboardMemory 2>/dev/null || true
  rm -rf "/Applications/Clipboard Memory.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications"
fi
