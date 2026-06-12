#!/bin/bash
# Build MPX Prime release DMG with universal binary

set -e

cd "$(dirname "$0")"

VERSION=${1:-0.36}
OUTPUT_DIR="macOS/dist"
APP_NAME="MPX Prime"
EXECUTABLE_NAME="MPXPrime"
CONFIG_NAME="MPX Prime.ini"
ICON_FILE="macOS/Resources/MPXPrime.icns"
ENTITLEMENTS="macOS/MPXPrime.entitlements"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export CLANG_MODULE_CACHE_PATH=${CLANG_MODULE_CACHE_PATH:-/tmp/swift-module-cache}
export SWIFTPM_MODULECACHE_OVERRIDE=${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/swift-module-cache}
BUILD_JOBS=${BUILD_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 1)}

echo "Building MPX Prime $VERSION release (universal binary)..."
echo "Using $BUILD_JOBS parallel build jobs..."

# Clean output directory
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# Build release binary for both architectures with entitlements
echo "Building arm64..."
xcrun swift build --package-path macOS -c release --arch arm64 -j "$BUILD_JOBS"

echo "Building x86_64..."
xcrun swift build --package-path macOS -c release --arch x86_64 -j "$BUILD_JOBS"

# Create .app bundle structure
APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy universal binary to app bundle
echo "Creating universal binary..."
lipo -create \
    "macOS/.build/arm64-apple-macosx/release/MPXPrime" \
    "macOS/.build/x86_64-apple-macosx/release/MPXPrime" \
    -output "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"

if [ -f "$ICON_FILE" ]; then
    cp "$ICON_FILE" "$APP_DIR/Contents/Resources/"
fi

# Create Info.plist
cat > "$APP_DIR/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${EXECUTABLE_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.mpxprime.app</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>MPXPrime.icns</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>MPX Prime needs microphone access to capture audio input for FM signal processing.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2024. All rights reserved.</string>
</dict>
</plist>
EOF

# Embed entitlements in the app bundle
cp "$ENTITLEMENTS" "$APP_DIR/Contents/Resources/MPXPrime.entitlements"

# Ship the canonical sample INI as the bundled default config. The
# previous heredoc template used the wrong section names ([ mpxprime ],
# [pilot ], etc.) — the parser only recognizes [MPX] / [RDS] /
# [INTERFACES], so every key in those sections silently fell back to
# defaults. Copying macOS/MPXPrime.ini directly fixes that and also
# means anything tested by SampleINIRoundTripTests is what ships.
cp "macOS/MPXPrime.ini" "$OUTPUT_DIR/$CONFIG_NAME"

# Copy default config to app resources
cp "$OUTPUT_DIR/$CONFIG_NAME" "$APP_DIR/Contents/Resources/"

# Ship the example RDS now-playing poller scripts (VLC + Cog) inside the
# bundle so they always travel with the app. They are also placed at the top
# level of the DMG (below) for easy discovery.
mkdir -p "$APP_DIR/Contents/Resources/Scripts"
cp scripts/nowplaying.sh "$APP_DIR/Contents/Resources/Scripts/"
chmod +x "$APP_DIR/Contents/Resources/Scripts/"*.sh

# Ad-hoc sign the completed app bundle so macOS sees a valid bundle structure.
echo "Ad-hoc signing app bundle..."
codesign --force --deep --sign - "$APP_DIR"

# Verify signature
echo "Verifying signature..."
if spctl --assess --type exec "$APP_DIR" 2>&1 | grep -q "accepted"; then
    echo "Signature: accepted (ad-hoc)"
else
    echo "Note: App uses ad-hoc signature. Run: xattr -cr '$APP_DIR' if needed."
fi

# --- MPX Prime Meter companion app (same universal release build) ---
METER_APP_NAME="MPX Prime Meter"
METER_EXECUTABLE_NAME="MPXPrimeMeter"
METER_APP_DIR="$OUTPUT_DIR/$METER_APP_NAME.app"
echo "Creating $METER_APP_NAME.app..."
rm -rf "$METER_APP_DIR"
mkdir -p "$METER_APP_DIR/Contents/MacOS"
mkdir -p "$METER_APP_DIR/Contents/Resources"
lipo -create \
    "macOS/.build/arm64-apple-macosx/release/MPXPrimeMeter" \
    "macOS/.build/x86_64-apple-macosx/release/MPXPrimeMeter" \
    -output "$METER_APP_DIR/Contents/MacOS/$METER_EXECUTABLE_NAME"
if [ -f "$ICON_FILE" ]; then
    cp "$ICON_FILE" "$METER_APP_DIR/Contents/Resources/"
fi
cat > "$METER_APP_DIR/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${METER_EXECUTABLE_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.mpxprime.meter</string>
    <key>CFBundleName</key>
    <string>${METER_APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${METER_APP_NAME}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>MPXPrime.icns</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>MPX Prime Meter needs microphone/input access to capture the MPX composite for analysis.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2024. All rights reserved.</string>
</dict>
</plist>
EOF
echo "Ad-hoc signing $METER_APP_NAME.app..."
codesign --force --deep --sign - "$METER_APP_DIR"

# Create DMG with Applications symlink for drag-to-install
echo "Creating DMG..."
DMG_PATH="$OUTPUT_DIR/MPX_Prime-$VERSION.dmg"
DMG_STAGING="$OUTPUT_DIR/dmg_staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_DIR" "$DMG_STAGING/"
cp -R "$METER_APP_DIR" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
mkdir -p "$DMG_STAGING/Now Playing Scripts"
cp scripts/nowplaying.sh "$DMG_STAGING/Now Playing Scripts/"
chmod +x "$DMG_STAGING/Now Playing Scripts/"*.sh
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH" || {
    echo "Failed to create DMG, keeping .app bundle"
}
rm -rf "$DMG_STAGING"

echo ""
echo "Build complete!"
echo "Output: $DMG_PATH"
echo "App: $APP_DIR"
ls -la "$OUTPUT_DIR/"
