#!/bin/bash
# Run MPX Prime Studio with an optimized release build for normal use.

set -e

cd "$(dirname "$0")"

echo "Running MPX Prime Studio (release, $(uname -m))..."
swift run --package-path macOS -c release MPXPrime "$@"
