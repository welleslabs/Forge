#!/bin/bash
# Builds a double-clickable TrendDemoLauncher.app (no install needed).
# Run:  ./build-app.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="TrendDemoLauncher"    # must match the executable target name
DISPLAY_NAME="Forge"            # shown under the Dock/Finder icon
BUNDLE_ID="com.trendmicro.forge"
APP="$DISPLAY_NAME.app"

echo "▶ Building release binary (this can take a couple of minutes)…"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
[ -x "$BIN" ] || { echo "✗ build failed: $BIN not found"; exit 1; }

echo "▶ Generating app icon…"
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift AppIcon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$(dirname "$ICONSET")/AppIcon.icns"

echo "▶ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$(dirname "$ICONSET")/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

echo "▶ Ad-hoc codesigning…"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "  (codesign skipped)"

# Copy to the Desktop for easy double-clicking.
DESKTOP="$HOME/Desktop/$APP"
rm -rf "$DESKTOP"
cp -R "$APP" "$DESKTOP" 2>/dev/null && echo "✓ Copied to Desktop: $DESKTOP" || true

echo "✓ Built: $(pwd)/$APP"
