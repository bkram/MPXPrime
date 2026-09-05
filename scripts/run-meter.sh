#!/usr/bin/env bash
#
# Build (release) and run MPX Prime Meter -- the companion MPX composite
# analyzer. With no arguments it opens the graphical dashboard, which
# auto-detects an attached SDR dongle (SDRplay RSP or RTL-SDR, decoded
# in-process) and starts capturing it, or falls back to the audio-device input
# (the 192 kHz-capable device, composite on the RIGHT channel) when no dongle is
# present. Examples:
#
#   scripts/run-meter.sh                       # GUI: SDR if a dongle is attached, else audio
#   scripts/run-meter.sh --sdr-freq 96.8       # GUI pre-tuned to an SDR station, capturing
#   scripts/run-meter.sh --device 0 --channel right --seconds 30   # headless audio capture
#   scripts/run-meter.sh --list-devices
#
# Headless terminal modes: pass --device <spec> (audio input) or --stdin (a WAV
# stream / raw composite on stdin) to run the text dashboard instead of the
# window. The in-process SDR is GUI-only; for the audio path, RDS needs the input
# device at >= 128 kHz (192 kHz recommended) -- set that in Audio MIDI Setup.
# First run may prompt for microphone/input access -- allow it.
set -euo pipefail

cd "$(dirname "$0")/.."  # repo root

echo "Building MPXPrimeMeter (release)..."
swift build --package-path macOS -c release --product MPXPrimeMeter

BIN="macOS/.build/release/MPXPrimeMeter"

echo "Running: $BIN $*"
exec "$BIN" "$@"
