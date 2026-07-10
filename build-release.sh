#!/bin/bash
# Build MPX Prime release DMG with universal binary

set -e

cd "$(dirname "$0")"

VERSION=${1:-0.41}
OUTPUT_DIR="macOS/dist"
APP_NAME="MPX Prime Studio"
EXECUTABLE_NAME="MPXPrime"
CONFIG_NAME="MPX Prime Studio.ini"
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

# x86_64: the encoder only. MPX Prime Meter links the arm64-only RTL-SDR tuner
# libs (CMPXTuner -> librtlsdr/liquid-dsp), so it is Apple-Silicon-only; building
# the whole package for x86_64 would try to link those and fail. --product keeps
# the Intel slice to the universal encoder.
echo "Building x86_64 (encoder only; Meter is Apple-Silicon-only)..."
xcrun swift build --package-path macOS -c release --arch x86_64 --product MPXPrime -j "$BUILD_JOBS"

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
# MPX Prime Meter is Apple-Silicon-only (it links the arm64 RTL-SDR tuner libs),
# so it ships as an arm64 binary; the encoder above stays universal.
cp "macOS/.build/arm64-apple-macosx/release/MPXPrimeMeter" \
    "$METER_APP_DIR/Contents/MacOS/$METER_EXECUTABLE_NAME"
chmod u+w "$METER_APP_DIR/Contents/MacOS/$METER_EXECUTABLE_NAME"
# The Meter has its own icon (analyzer VU gauge) so it is distinct from
# MPX Prime Studio in the Dock; fall back to the shared icon if it is missing.
METER_ICON_FILE="macOS/Resources/MPXPrimeMeter.icns"
if [ -f "$METER_ICON_FILE" ]; then
    cp "$METER_ICON_FILE" "$METER_APP_DIR/Contents/Resources/"
    METER_ICON_NAME="MPXPrimeMeter"
elif [ -f "$ICON_FILE" ]; then
    cp "$ICON_FILE" "$METER_APP_DIR/Contents/Resources/"
    METER_ICON_NAME="MPXPrime"
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
    <string>${METER_ICON_NAME}</string>
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

# --- Bundle the RTL-SDR dylibs the Meter links + relocate them to @rpath ---
# The Meter statically links the vendored tuner C++ (CMPXTuner), which pulls in
# Homebrew librtlsdr + liquid-dsp (and transitively libusb + fftw). Bundle the 4
# dylibs into the app and rewrite the Meter binary's load commands so it runs
# without Homebrew. arm64-only. These are REQUIRED now (the Meter links them) --
# a missing dylib means the Meter would have failed to link above.
TUNER_RTLSDR_DYLIB="/opt/homebrew/opt/librtlsdr/lib/librtlsdr.0.dylib"
TUNER_LIQUID_DYLIB="/opt/homebrew/opt/liquid-dsp/lib/libliquid.dylib"
TUNER_USB_DYLIB="/opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib"
TUNER_FFTW_DYLIB="/opt/homebrew/opt/fftw/lib/libfftw3f.3.dylib"
METER_BIN="$METER_APP_DIR/Contents/MacOS/$METER_EXECUTABLE_NAME"
if [ -f "$TUNER_RTLSDR_DYLIB" ] && [ -f "$TUNER_LIQUID_DYLIB" ] \
    && [ -f "$TUNER_USB_DYLIB" ] && [ -f "$TUNER_FFTW_DYLIB" ]; then
    echo "Bundling RTL-SDR dylibs into $METER_APP_NAME.app..."
    FRAMEWORKS_DIR="$METER_APP_DIR/Contents/Frameworks"
    mkdir -p "$FRAMEWORKS_DIR"
    for d in "$TUNER_RTLSDR_DYLIB" "$TUNER_LIQUID_DYLIB" "$TUNER_USB_DYLIB" "$TUNER_FFTW_DYLIB"; do
        cp "$d" "$FRAMEWORKS_DIR/"; chmod u+w "$FRAMEWORKS_DIR/$(basename "$d")"
    done
    # Rewrite any Homebrew load command pointing at one of our 4 dylibs to @rpath.
    relocate_macho() {
        local f="$1"
        otool -L "$f" | awk 'NR>1 {print $1}' | grep -E '^/(opt/homebrew|usr/local)/' | while read -r dep; do
            case "$(basename "$dep")" in
                librtlsdr.0.dylib|libliquid.dylib|libusb-1.0.0.dylib|libfftw3f.3.dylib)
                    install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$f" ;;
            esac
        done
    }
    for b in librtlsdr.0.dylib libliquid.dylib libusb-1.0.0.dylib libfftw3f.3.dylib; do
        install_name_tool -id "@rpath/$b" "$FRAMEWORKS_DIR/$b"
        relocate_macho "$FRAMEWORKS_DIR/$b"
    done
    # The Meter binary links librtlsdr + liquid directly; point them at @rpath.
    relocate_macho "$METER_BIN"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$METER_BIN"
    # Sign the relocated dylibs (the --deep below also covers them, but sign
    # explicitly so the rewritten load commands have valid signatures).
    for b in librtlsdr.0.dylib libliquid.dylib libusb-1.0.0.dylib libfftw3f.3.dylib; do
        codesign --force --sign - "$FRAMEWORKS_DIR/$b"
    done
else
    echo "ERROR: RTL-SDR dylibs not found, but the Meter links them."
    echo "  Install them first: brew install librtlsdr liquid-dsp"
    exit 1
fi

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
