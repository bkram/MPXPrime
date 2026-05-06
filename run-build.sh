#!/bin/bash
# Run MPX Prime with an optimized release build for normal use.

set -e

cd "$(dirname "$0")"

echo "Running MPX Prime (release, $(uname -m))..."
swift run --package-path macOS -c release MPXPrime "$@"
