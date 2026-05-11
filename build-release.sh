#!/bin/bash
# Build MPX Prime release DMG with universal binary

set -e

cd "$(dirname "$0")"

VERSION=${1:-0.26}
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

# Create DMG with Applications symlink for drag-to-install
echo "Creating DMG..."
DMG_PATH="$OUTPUT_DIR/MPX_Prime-$VERSION.dmg"
DMG_STAGING="$OUTPUT_DIR/dmg_staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_DIR" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH" || {
    echo "Failed to create DMG, keeping .app bundle"
}
rm -rf "$DMG_STAGING"

echo ""
echo "Build complete!"
echo "Output: $DMG_PATH"
echo "App: $APP_DIR"
ls -la "$OUTPUT_DIR/"
