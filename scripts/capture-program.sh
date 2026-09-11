#!/bin/bash
# capture-program.sh -- record program audio from BlackHole into a WAV, one
# building block of the --verify-program-ab real-music corpus.
#
# Workflow: route your player's output to BlackHole 2ch (or pass another
# input device UID), start playback, run this script once per track/section.
# Collect the WAVs in one directory (e.g. $MPXPRIME_MUSIC_DIR) and feed it to:
#   macOS/.build/release/MPXPrime --verify-program-ab "$MPXPRIME_MUSIC_DIR"
#
# Usage:
#   scripts/capture-program.sh [--seconds 60] [--out <path.wav>]
#                              [--device-uid BlackHole2ch_UID] [--name <label>]
set -euo pipefail

SECONDS_ARG=60
DEVICE_UID="BlackHole2ch_UID"
OUT=""
NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --seconds) SECONDS_ARG="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --device-uid) DEVICE_UID="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "$OUT" ]]; then
  CORPUS_DIR="${MPXPRIME_MUSIC_DIR:-$PWD}"
  STAMP="$(date +%Y%m%d-%H%M%S)"
  LABEL="${NAME:-capture}"
  OUT="$CORPUS_DIR/${LABEL}-${STAMP}.wav"
fi
mkdir -p "$(dirname "$OUT")"

BUILD_DIR="$(mktemp -d /tmp/mpxprime-capture.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT
echo "Compiling capture helper..."
swiftc -O -o "$BUILD_DIR/capture-to-wav" "$SCRIPT_DIR/CaptureToWav.swift"

echo "Start playback into '$DEVICE_UID' now; recording ${SECONDS_ARG}s in 3s..."
sleep 3
"$BUILD_DIR/capture-to-wav" --out "$OUT" --device-uid "$DEVICE_UID" --seconds "$SECONDS_ARG"
echo "Captured: $OUT"
