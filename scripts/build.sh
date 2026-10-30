#!/usr/bin/env bash
#
# Build MPX Prime. Release by default, because a debug build is not
# real-time capable (see docs/BUILDING.md): fine for --verify and tests,
# not for anything that opens an audio device.
#
#   scripts/build.sh                      # release, every product (Studio + Meter)
#   scripts/build.sh debug                # debug build
#   scripts/build.sh --product MPXPrime   # one product only (the encoder)
#   scripts/build.sh --clean              # wipe .build first
#   scripts/build.sh release --product MPXPrimeMeter -v   # extra args go to swift build
#
# The binaries land in .build/<config>/ (MPXPrime, MPXPrimeMeter); the
# path of the one you asked for is printed at the end. Needs
# `brew install librtlsdr liquid-dsp` for the Meter; pass --product MPXPrime
# to build the encoder without them.
set -euo pipefail

# shellcheck source=scripts/build-env.sh
. "$(dirname "$0")/build-env.sh"

CONFIG="release"
PRODUCT=""
CLEAN=0
EXTRA=()
while [ $# -gt 0 ]; do
    case "$1" in
    debug | release) CONFIG="$1" ;;
    --product)
        PRODUCT="${2:?--product needs a name}"
        shift
        ;;
    --clean) CLEAN=1 ;;
    -h | --help)
        sed -n '2,/^set -/p' "$0" | sed '$d' | cut -c3-
        exit 0
        ;;
    *) EXTRA+=("$1") ;;
    esac
    shift
done

if [ "$CLEAN" = 1 ]; then
    echo "Removing $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi

CMD=(swift build -c "$CONFIG" -j "$BUILD_JOBS")
[ -n "$PRODUCT" ] && CMD+=(--product "$PRODUCT")
[ "${#EXTRA[@]}" -gt 0 ] && CMD+=("${EXTRA[@]}")

echo "+ ${CMD[*]}"
"${CMD[@]}"

echo
echo "Built ($CONFIG): $BUILD_DIR/$CONFIG/${PRODUCT:-MPXPrime}"
