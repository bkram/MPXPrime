#!/bin/bash
# Build MPX Prime in release mode for the host architecture.

set -e

cd "$(dirname "$0")"

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export CLANG_MODULE_CACHE_PATH=${CLANG_MODULE_CACHE_PATH:-/tmp/swift-module-cache}
export SWIFTPM_MODULECACHE_OVERRIDE=${SWIFTPM_MODULECACHE_OVERRIDE:-/tmp/swift-module-cache}
BUILD_JOBS=${BUILD_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 1)}

echo "Building MPX Prime ($(uname -m) release, $BUILD_JOBS jobs)..."
xcrun swift build --package-path macOS -c release -j "$BUILD_JOBS"

echo "Build complete!"
