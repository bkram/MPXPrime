#!/bin/bash
# Compatibility wrapper: default to the optimized release launcher.

set -e

cd "$(dirname "$0")"

exec ./run-build.sh "$@"
