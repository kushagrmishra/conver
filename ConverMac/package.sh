#!/bin/bash
# Builds Conver.app and Conver.dmg from the Swift package and compiles conver.icon natively via actool.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=dist/Conver.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Conver "$APP/Contents/MacOS/Conver"

# --- Compile conver.icon natively using Apple's actool (NO PNG rasterization!) ---
if [ -d "conver.icon" ]; then
  echo "Compiling conver.icon bundle natively with xcrun actool..."
  xcrun actool conver.icon \
    --compile "$APP/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 15.0 \
    --app-icon conver \
    --output-partial-info-plist dist/assetcatalog_generated_info.plist
fi

cat > "$APP/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Conver</string>
<key>CFBundleDisplayName</key><string>Conver</string>
<key>CFBundleIdentifier</key><string>dev.conver.app</string>
<key>CFBundleExecutable</key><string>Conver</string>
<key>CFBundleIconFile</key><string>conver</string>
<key>CFBundleIconName</key><string>conver</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSAppleEventsUsageDescription</key><string>Conver automatically drops your selected Finder files into the Drop Wheel when you press Shift+Z.</string>
</dict></plist>
PL
codesign --force --deep --options runtime --entitlements Conver.entitlements --sign - "$APP"

# --- DMG ---
STAGE=dist/dmg; mkdir -p "$STAGE"; cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Conver" -srcfolder "$STAGE" -ov -format UDZO dist/Conver.dmg >/dev/null
rm -rf "$STAGE" dist/assetcatalog_generated_info.plist
echo "Built: $(pwd)/dist/Conver.dmg"
