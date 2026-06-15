#!/bin/bash
# Run MPX Prime Studio with a debug build for development work.

set -e

cd "$(dirname "$0")"

echo "Running MPX Prime Studio (debug, $(uname -m))..."
swift run --package-path macOS -c debug MPXPrime "$@"
