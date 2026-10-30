#!/usr/bin/env bash
#
# Build (release) and run MPX Prime Studio headless with the remote-control
# REST API + web dashboard. Works on macOS and Linux (same tree, same
# script). Before the run it prints the dashboard URL, the config in use and
# the API key the dashboard will ask for (from the config's [CONTROL]
# section), and it refuses to start when something already listens on the
# control port -- usually an earlier instance -- instead of launching a
# second encoder that fights the first for the audio devices.
#
#   scripts/run-build-web.sh                          # default config, port 8737
#   scripts/run-build-web.sh --control-port 9000      # different port
#   scripts/run-build-web.sh --config /path/to/My.ini # specific config
#
# Remote access: set control_bind = 0.0.0.0 AND control_api_key = <secret>
# in the config's [CONTROL] section (the server refuses to start
# remote-exposed without a key). See docs/studio-operator-guide.md "Operating it from a browser".
set -euo pipefail

cd "$(dirname "$0")/.." # repo root

# --- Where the dashboard will be, from the arguments and the INI -------------
# The binary parses the same arguments and file; this pass only feeds the
# banner and the port check, so an unknown flag is left for the binary to
# reject (it exits 64 on one).
CONFIG_PATH=""
PORT_ARG=""
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
    case "${args[$i]}" in
    --config)
        CONFIG_PATH="${args[$((i + 1))]:-}"
        i=$((i + 2))
        continue
        ;;
    --control-port)
        PORT_ARG="${args[$((i + 1))]:-}"
        i=$((i + 2))
        continue
        ;;
    esac
    i=$((i + 1))
done
if [ -z "$CONFIG_PATH" ]; then
    if [ "$(uname -s)" = "Darwin" ]; then
        CONFIG_PATH="$HOME/Library/Application Support/MPX Prime Studio/MPX Prime Studio.ini"
    else
        CONFIG_PATH="$HOME/.local/share/MPX Prime Studio/MPX Prime Studio.ini"
    fi
fi

# One key from the INI's [CONTROL] section; empty when the file or key is
# absent (a first run creates the file with defaults: loopback, 8737, no key).
ini_control_key() {
    [ -f "$CONFIG_PATH" ] || return 0
    awk -v key="$1" '
        /^[[:space:]]*\[/ { in_section = ($0 ~ /^[[:space:]]*\[CONTROL\][[:space:]]*$/); next }
        in_section && index($0, "=") {
            line = $0
            sub(/[[:space:]]*;.*$/, "", line)
            k = substr(line, 1, index(line, "=") - 1)
            v = substr(line, index(line, "=") + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            if (tolower(k) == tolower(key)) { print v; exit }
        }' "$CONFIG_PATH"
}

BIND="$(ini_control_key control_bind)"
BIND="${BIND:-127.0.0.1}"
PORT="${PORT_ARG:-$(ini_control_key control_port)}"
PORT="${PORT:-8737}"
API_KEY="$(ini_control_key control_api_key)"

# --- Refuse to run twice ------------------------------------------------------
# Prints "COMMAND (pid N)" per listener on the control port; nothing when the
# port is free. lsof is on every Mac and most Linux boxes, ss on any Linux
# with iproute2; without either, a plain connect at least tells us whether
# the port answers.
port_listeners() {
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $1 " (pid " $2 ")" }'
    elif command -v ss >/dev/null 2>&1; then
        ss -Hltnp "sport = :$PORT" 2>/dev/null | awk '{ print $NF }'
    elif (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
        echo "an unknown process (no lsof or ss here to name it)"
    fi
}

refuse_if_port_busy() {
    local who
    who="$(port_listeners || true)"
    [ -n "$who" ] || return 0
    {
        echo "MPX Prime not started: port $PORT is already in use by"
        while IFS= read -r line; do echo "    $line"; done <<<"$who"
        echo "If that is a running MPX Prime, its dashboard is at http://$BIND:$PORT/ -- use it,"
        echo "or stop it first. To run a second instance beside it, pass --control-port <other>."
    } >&2
    exit 1
}

refuse_if_port_busy # before the build: no point compiling for a port we cannot have

# --- Toolchain ----------------------------------------------------------------
# macOS must use the full Xcode toolchain. The Command Line Tools `swift`
# cannot load SwiftUI's macro plugin, which makes ordinary @State properties
# fail to compile. Keep Linux untouched: its swiftly/toolchain discovery is
# handled below and there is no DEVELOPER_DIR there.
if [ "$(uname -s)" = "Darwin" ]; then
    XCODE_DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
    if [ ! -d "$XCODE_DEVELOPER_DIR" ]; then
        echo "error: full Xcode not found at $XCODE_DEVELOPER_DIR" >&2
        echo "set DEVELOPER_DIR to your Xcode.app/Contents/Developer directory" >&2
        exit 1
    fi
    export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
fi

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
swift build -c release --product MPXPrime

BIN=".build/release/MPXPrime"

refuse_if_port_busy # again after the build: it takes long enough for someone to start one

# --- What you need to log in ---------------------------------------------------
echo
echo "Dashboard:  http://$BIND:$PORT/"
if [ "$BIND" = "0.0.0.0" ] || [ "$BIND" = "::" ]; then
    echo "            (all interfaces; from this machine use http://127.0.0.1:$PORT/)"
fi
echo "Config:     $CONFIG_PATH"
if [ -n "$API_KEY" ]; then
    echo "API key:    $API_KEY"
    echo "            The dashboard asks for it on first load. For the API:"
    echo "            curl -H 'X-API-Key: $API_KEY' http://$BIND:$PORT/api/status"
else
    echo "API key:    none in [CONTROL] -- fine on 127.0.0.1; any other bind refuses to start without control_api_key"
fi
echo

echo "Running: $BIN --web $*"
exec "$BIN" --web "$@"
