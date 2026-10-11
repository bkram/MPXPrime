#!/usr/bin/env bash
#
# Build (release) and run MPX Prime Studio. Every argument is passed to the
# binary unchanged, so this is `swift run` without the debug-build trap:
#
#   scripts/run.sh                            # GUI
#   scripts/run.sh --nogui                    # headless encoder
#   scripts/run.sh --nogui --seconds 30       # ... for 30 s
#   scripts/run.sh --config /path/to/My.ini   # specific config
#   scripts/run.sh --verify --seconds 5       # offline verification gate
#   scripts/run.sh --debug --verify           # same on a debug build
#   scripts/run.sh --no-build --nogui         # skip the build, run what is there
#
# --debug and --no-build are the only flags this script eats; everything else
# goes to MPXPrime (run it with no arguments and an unknown flag such as
# --help to see its usage). A debug build is NOT real-time capable: use it for
# --verify and development, never for on-air or monitor playback.
#
# For the web dashboard use scripts/run-build-web.sh, for the Meter
# scripts/run-meter.sh.
set -euo pipefail

# shellcheck source=scripts/build-env.sh
. "$(dirname "$0")/build-env.sh"

CONFIG="release"
BUILD=1
ARGS=()
for a in "$@"; do
    case "$a" in
    --debug) CONFIG="debug" ;;
    --no-build) BUILD=0 ;;
    *) ARGS+=("$a") ;;
    esac
done

BIN="$BUILD_DIR/$CONFIG/MPXPrime"
if [ "$BUILD" = 1 ]; then
    scripts/build.sh "$CONFIG" --product MPXPrime
elif [ ! -x "$BIN" ]; then
    echo "error: $BIN is missing; run without --no-build" >&2
    exit 1
fi

if [ "$CONFIG" = "debug" ]; then
    echo "note: debug build, not real-time capable (clicks and underruns on live audio are expected)"
fi
echo "+ $BIN ${ARGS[*]:-}"
exec "$BIN" "${ARGS[@]+"${ARGS[@]}"}"
