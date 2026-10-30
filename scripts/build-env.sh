#!/usr/bin/env bash
#
# Shared build environment for the scripts in scripts/. Sourced, not run:
#
#   . "$(dirname "$0")/build-env.sh"
#
# It changes to the repo root (every script here works from any directory),
# then exports what a Swift build of this package needs on this machine:
#
#   DEVELOPER_DIR   full Xcode when it is installed (Testing.framework and
#                   the x86_64 slice need it; the Command Line Tools do not
#                   ship Testing). Honours a value already in the environment.
#   PATH            Homebrew first (swiftlint, node, the SDR libs' pkg-config).
#   module caches   one shared Clang/SwiftPM module cache instead of a new
#                   one per shell, which is what makes a rebuild fast.
#   BUILD_JOBS      parallel jobs for swift build; defaults to the core count.
#
# Nothing in here is macOS-only by accident: on Linux the Xcode and Homebrew
# lines are skipped and the plain swift toolchain on PATH is used.

# BASH_SOURCE in bash, $0 when an interactive zsh sources this file (zsh sets
# $0 to the sourced file). Refuse to continue from anywhere that is not the
# package root rather than let a build land in some other directory.
# shellcheck disable=SC2034  # BUILD_DIR is used by the sourcing scripts
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
if [ ! -f "$REPO_ROOT/Package.swift" ]; then
    echo "build-env.sh: no Package.swift at $REPO_ROOT; source this file as scripts/build-env.sh from the repo" >&2
    return 1 2>/dev/null || exit 1
fi
cd "$REPO_ROOT" || exit 1
BUILD_DIR=".build"

if [ "$(uname -s)" = "Darwin" ]; then
    if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
    case ":$PATH:" in
    *:/opt/homebrew/bin:*) ;;
    *) [ -d /opt/homebrew/bin ] && export PATH="/opt/homebrew/bin:$PATH" ;;
    esac
    export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${TMPDIR:-/tmp}/swift-module-cache}"
    export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$CLANG_MODULE_CACHE_PATH}"
    BUILD_JOBS="${BUILD_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 1)}"
else
    BUILD_JOBS="${BUILD_JOBS:-$(nproc 2>/dev/null || echo 1)}"
fi
export BUILD_JOBS
