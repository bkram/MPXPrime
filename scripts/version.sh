#!/usr/bin/env bash
#
# Print the project version: the one string in Sources/MPXPrimeCore/Version.swift.
# Everything that needs the version in shell (the packagers, the workflows)
# reads it from here rather than carrying its own copy.
set -euo pipefail

cd "$(dirname "$0")/.." # repo root

VERSION="$(sed -n 's/.*public static let string = "\([^"]*\)".*/\1/p' Sources/MPXPrimeCore/Version.swift)"
if [ -z "$VERSION" ]; then
    echo "version.sh: no version string found in Sources/MPXPrimeCore/Version.swift" >&2
    exit 1
fi
echo "$VERSION"
