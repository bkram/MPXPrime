#!/usr/bin/env bash
#
# Build (release) and run the MPX Prime Meter -- the companion MPX composite
# analyzer. With no arguments it defaults to the external USB DAC (device 0)
# with the composite on the RIGHT channel and the decoded-audio monitor ON.
# Any arguments you pass replace the defaults and are forwarded verbatim, e.g.:
#
#   ./run-meter.sh --list-devices
#   ./run-meter.sh --device "HD USB Audio" --channel right
#   ./run-meter.sh --device 0 --channel right --no-monitor --seconds 30
#
# RDS needs the input device at >= 128 kHz (192 kHz recommended); set that in
# Audio MIDI Setup. First run may prompt for microphone/input access -- allow it.
set -euo pipefail

cd "$(dirname "$0")"

echo "Building MPXPrimeMeter (release)..."
swift build --package-path macOS -c release --product MPXPrimeMeter

BIN="macOS/.build/release/MPXPrimeMeter"

if [ "$#" -eq 0 ]; then
  set -- --device 0 --channel right
fi

echo "Running: $BIN $*"
exec "$BIN" "$@"
