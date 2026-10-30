#!/usr/bin/env bash
# Build MPX Prime release DMG with universal binary. Works from any
# directory; the output lands in dist/.
#
#   scripts/build-release.sh               # the source version (scripts/version.sh)
#   scripts/build-release.sh 0.65-rc1      # an explicit version string

set -euo pipefail

# shellcheck source=scripts/build-env.sh
. "$(dirname "$0")/build-env.sh" # repo root + DEVELOPER_DIR, caches, BUILD_JOBS
# shellcheck source=scripts/app-bundle.sh
. scripts/app-bundle.sh # bundle_studio / bundle_meter, shared with scripts/build-run.sh

VERSION="${1:-$(scripts/version.sh)}"
OUTPUT_DIR="dist"

echo "Building MPX Prime $VERSION release (universal binary)..."
echo "Using $BUILD_JOBS parallel build jobs..."

# Clean output directory
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# Build each architecture, then copy its products aside before the next
# build. The toolchain decides where products land (the classic backend
# uses .build/<triple>/release, the Swift Build backend one shared
# .build/out/Products/Release for every arch, so a second --arch build
# OVERWRITES the first); --show-bin-path is the only reliable answer, and
# the copy is what keeps the arm64 slice from being a stale or wrong-arch
# file when lipo runs.
SLICES="$OUTPUT_DIR/.slices"
mkdir -p "$SLICES/arm64" "$SLICES/x86_64"

echo "Building arm64..."
xcrun swift build -c release --arch arm64 -j "$BUILD_JOBS"
BIN_ARM64="$(xcrun swift build -c release --arch arm64 --show-bin-path)"
cp "$BIN_ARM64/MPXPrime" "$BIN_ARM64/MPXPrimeMeter" "$SLICES/arm64/"

# x86_64: the encoder only. MPX Prime Meter links the arm64-only RTL-SDR tuner
# libs (CMPXTuner -> librtlsdr/liquid-dsp), so it is Apple-Silicon-only; building
# the whole package for x86_64 would try to link those and fail. --product keeps
# the Intel slice to the universal encoder.
echo "Building x86_64 (encoder only; Meter is Apple-Silicon-only)..."
xcrun swift build -c release --arch x86_64 --product MPXPrime -j "$BUILD_JOBS"
BIN_X86="$(xcrun swift build -c release --arch x86_64 --product MPXPrime --show-bin-path)"
cp "$BIN_X86/MPXPrime" "$SLICES/x86_64/"

# Each slice must be what its name says, or the universal binary is a lie.
for pair in "arm64:$SLICES/arm64/MPXPrime" "arm64:$SLICES/arm64/MPXPrimeMeter" "x86_64:$SLICES/x86_64/MPXPrime"; do
    want="${pair%%:*}"
    file="${pair#*:}"
    if ! lipo -info "$file" | grep -q "architecture: $want"; then
        echo "error: $file is not an $want binary: $(lipo -info "$file")" >&2
        exit 1
    fi
done

APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
bundle_studio "$APP_DIR" "$VERSION" "$SLICES/arm64/MPXPrime" "$SLICES/x86_64/MPXPrime"
# The bundled default config also sits at the top of dist/.
cp "Resources/MPXPrime.ini" "$OUTPUT_DIR/$CONFIG_NAME"

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
METER_APP_DIR="$OUTPUT_DIR/$METER_APP_NAME.app"
bundle_meter "$METER_APP_DIR" "$VERSION" "$SLICES/arm64/MPXPrimeMeter"

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
cp scripts/dist/nowplaying.sh scripts/dist/push-nowplaying.sh "$DMG_STAGING/Now Playing Scripts/"
chmod +x "$DMG_STAGING/Now Playing Scripts/"*.sh
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH" || {
    echo "Failed to create DMG, keeping .app bundle"
}
rm -rf "$DMG_STAGING" "$SLICES"

echo ""
echo "Build complete!"
echo "Note: .build/release now holds the x86_64 encoder (the last build);"
echo "      scripts/build.sh restores the native one."
echo "Output: $DMG_PATH"
echo "App: $APP_DIR"
ls -la "$OUTPUT_DIR/"
