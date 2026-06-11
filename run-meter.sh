#!/usr/bin/env bash
#
# Build (release) and run the MPX Prime Meter -- the companion MPX composite
# analyzer. Defaults to the external USB DAC (device 0), composite on the
# RIGHT channel, decoded-audio monitor ON. These defaults always apply; pass
# your own --device / --channel to override (your value wins -- the meter
# takes the first occurrence of each flag). Examples:
#
#   ./run-meter.sh                               # device 0, right, monitor on
#   ./run-meter.sh --seconds 30                  # ...still device 0 + right
#   ./run-meter.sh --channel left                # override to left
#   ./run-meter.sh --list-devices
#
# RDS needs the input device at >= 128 kHz (192 kHz recommended); set that in
# Audio MIDI Setup. First run may prompt for microphone/input access -- allow it.
set -euo pipefail

cd "$(dirname "$0")"

echo "Building MPXPrimeMeter (release)..."
swift build --package-path macOS -c release --product MPXPrimeMeter

BIN="macOS/.build/release/MPXPrimeMeter"

# Append rig defaults AFTER the user's args so an explicit --device/--channel
# (given first) wins; if the user omits them, these supply device 0 + right.
echo "Running: $BIN $* --device 0 --channel right"
exec "$BIN" "$@" --device 0 --channel right
