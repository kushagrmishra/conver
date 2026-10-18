#!/bin/bash
# Builds Conver.app and styled Retina Conver.dmg
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Compiling native Swift release binary..."
swift build -c release

APP="dist/Conver.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Conver "$APP/Contents/MacOS/Conver"

# --- Compile conver.icon bundle natively with actool ---
if [ -d "conver.icon" ]; then
  echo "==> Compiling conver.icon bundle natively with actool..."
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

echo "==> Signing application bundle..."
codesign --force --deep --options runtime --entitlements Conver.entitlements --sign - "$APP"

# --- Generate Retina DMG Background ---
if [ -f "make_dmg_bg.js" ]; then
  echo "==> Generating Retina DMG background graphic..."
  NODE_BIN=$(which node 2>/dev/null || ls /opt/homebrew/Cellar/node/*/bin/node 2>/dev/null | head -n 1 || echo "node")
  "$NODE_BIN" make_dmg_bg.js || true
fi

# --- Create Styled DMG with Custom Finder Layout ---
echo "==> Building custom styled Conver.dmg..."
DMG_VOL="Conver"
DMG_TMP="dist/temp.dmg"
DMG_FINAL="dist/Conver.dmg"
rm -f "$DMG_TMP" "$DMG_FINAL"

# Create a temporary read-write sparse/dmg (60MB)
hdiutil create -size 60m -fs HFS+ -volname "$DMG_VOL" -ov "$DMG_TMP" >/dev/null

# Unmount any existing Conver volume first
diskutil unmount force "/Volumes/$DMG_VOL" 2>/dev/null || true

# Mount DMG
ATTACH_OUT=$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_TMP")
MOUNT_DIR=$(echo "$ATTACH_OUT" | grep -o '/Volumes/.*' | head -n 1)

if [ -z "$MOUNT_DIR" ] || [ ! -d "$MOUNT_DIR" ]; then
  echo "Error: Failed to find mount directory for DMG"
  exit 1
fi
echo "Mounted at: $MOUNT_DIR"

# Populate DMG contents
cp -R "$APP" "$MOUNT_DIR/"
ln -s /Applications "$MOUNT_DIR/Applications"

if [ -f "dmg_background.png" ]; then
  mkdir -p "$MOUNT_DIR/.background"
  cp "dmg_background.png" "$MOUNT_DIR/.background/bg.png"
fi

# Configure Finder visual layout with AppleScript
echo "==> Configuring Finder window layout & icon positions..."
osascript <<EOF
tell application "Finder"
  activate
  tell disk "$DMG_VOL"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {300, 150, 960, 590}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 110
    if exists file ".background:bg.png" then
      set background picture of theViewOptions to file ".background:bg.png"
    end if
    delay 1
    set position of item "Conver.app" to {180, 230}
    set position of item "Applications" to {480, 230}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

# Sync and unmount
sync
hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force -quiet || true
sleep 1

# Convert into final compressed read-only DMG
hdiutil convert "$DMG_TMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_FINAL" >/dev/null
rm -f "$DMG_TMP" dist/assetcatalog_generated_info.plist

echo "==> Finished! Styled DMG built at: $(pwd)/$DMG_FINAL"
