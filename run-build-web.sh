#!/usr/bin/env bash
#
# Build (release) and run MPX Prime Studio headless with the remote-control
# REST API + web dashboard. Works on macOS and Linux (same tree, same
# script). The dashboard URL is printed at startup; open it in any browser.
#
#   ./run-build-web.sh                          # default config, port 8737
#   ./run-build-web.sh --control-port 9000      # different port
#   ./run-build-web.sh --config /path/to/My.ini # specific config
#
# Remote access: set control_bind = 0.0.0.0 AND control_api_key = <secret>
# in the config's [CONTROL] section (the server refuses to start
# remote-exposed without a key). See docs/manual.md "Remote control".
set -euo pipefail

cd "$(dirname "$0")"

# Linux: swiftly installs the toolchain but only login shells source its
# env; pick it up here so the script works from any shell/cron.
if ! command -v swift >/dev/null 2>&1; then
    for env_candidate in "$HOME/.local/share/swiftly/env.sh" "$HOME/.swiftly/env.sh"; do
        if [ -f "$env_candidate" ]; then
            # shellcheck disable=SC1090
            . "$env_candidate"
            break
        fi
    done
fi
if ! command -v swift >/dev/null 2>&1; then
    echo "error: swift toolchain not found (install via swiftly; see docs/BUILDING.md)" >&2
    exit 1
fi

echo "Building MPXPrime (release)..."
swift build --package-path macOS -c release --product MPXPrime

BIN="macOS/.build/release/MPXPrime"

echo "Running: $BIN --web $*"
exec "$BIN" --web "$@"
