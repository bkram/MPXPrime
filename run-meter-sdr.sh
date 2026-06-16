#!/usr/bin/env bash
#
# Tune an RTL-SDR with the vendored mpx-tuner (built on demand from tuner/;
# falls back to an external fm-sdr-tuner) and pipe its MPX composite into
# the MPX Prime Meter over a FIFO -- decode + measure + hear a live station.
#
#   ./run-meter-sdr.sh --freq 88.6
#   ./run-meter-sdr.sh --freq 101.1 --no-monitor --wav ~/cap.wav
#   ./run-meter-sdr.sh --freq 88.6 --pilot-ref-khz 6.8
#   ./run-meter-sdr.sh --freq 88.6 --gui      # open the dashboard window instead
#
# --freq <MHz> is required. With --gui this opens the MPX Prime Meter window
# pre-tuned to that frequency (the GUI spawns its own tuner -- no FIFO). Without
# --gui it pipes the MPX into the headless terminal meter over a FIFO; every
# other argument is forwarded verbatim to MPXPrimeMeter (--channel is
# irrelevant there; the piped MPX is mono).
#
# A FIFO carries the 16-bit/192 kHz mono MPX; the tuner's stdout logs go to a
# logfile so they don't corrupt the stream. Monitor (decoded audio) is on by
# default -- you hear the station. Requires an RTL-SDR connected and the
# FM-SDR-Tuner binary (place it in bin/ -- see bin/README.md for where to get
# it -- or set FM_SDR_TUNER).
set -euo pipefail

cd "$(dirname "$0")"

RATE=192000

# Locate a tuner binary. Order: FM_SDR_TUNER override, the vendored mpx-tuner
# (tuner/build/mpx-tuner -- built on demand below), a local bin/fm-sdr-tuner,
# then a sibling source checkout. The launch flags differ per binary (see below).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -n "${FM_SDR_TUNER:-}" ]; then
  TUNER="$FM_SDR_TUNER"
elif [ -x "$SCRIPT_DIR/tuner/build/mpx-tuner" ]; then
  TUNER="$SCRIPT_DIR/tuner/build/mpx-tuner"
elif [ -x "$SCRIPT_DIR/bin/fm-sdr-tuner" ]; then
  TUNER="$SCRIPT_DIR/bin/fm-sdr-tuner"
else
  TUNER="$HOME/Projects/git/FM-SDR-Tuner/build/fm-sdr-tuner"
fi

# Parse --freq (MHz) and --gui; forward the rest to the meter.
FREQ_MHZ=""
GUI=0
METER_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --freq) FREQ_MHZ="$2"; shift 2 ;;
    --freq=*) FREQ_MHZ="${1#*=}"; shift ;;
    --gui) GUI=1; shift ;;
    *) METER_ARGS+=("$1"); shift ;;
  esac
done

if [ -z "$FREQ_MHZ" ]; then
  echo "usage: ./run-meter-sdr.sh --freq <MHz> [--gui] [meter args...]" >&2
  exit 2
fi

# GUI mode: the window spawns its own tuner via its native SDR source, so we
# just build and launch it pre-tuned -- no FIFO / external tuner plumbing here.
if [ "$GUI" -eq 1 ]; then
  echo "Building MPXPrimeMeter (release)..."
  swift build --package-path macOS -c release --product MPXPrimeMeter
  echo "Opening MPX Prime Meter, tuned to ${FREQ_MHZ} MHz (SDR)..."
  exec "macOS/.build/release/MPXPrimeMeter" --gui --sdr-freq "$FREQ_MHZ"
fi
# Nothing resolved yet -> build the vendored mpx-tuner on demand (needs cmake +
# librtlsdr + liquid-dsp).
if [ ! -x "$TUNER" ] && command -v cmake >/dev/null 2>&1; then
  echo "Building vendored mpx-tuner..."
  if cmake -S "$SCRIPT_DIR/tuner" -B "$SCRIPT_DIR/tuner/build" -DCMAKE_BUILD_TYPE=Release >/dev/null 2>&1 \
     && cmake --build "$SCRIPT_DIR/tuner/build" -j >/dev/null 2>&1; then
    TUNER="$SCRIPT_DIR/tuner/build/mpx-tuner"
  fi
fi
if [ ! -x "$TUNER" ]; then
  echo "No tuner binary available: $TUNER" >&2
  echo "Install cmake + librtlsdr + liquid-dsp to build the vendored mpx-tuner," >&2
  echo "or place an fm-sdr-tuner in bin/ (see bin/README.md) / set FM_SDR_TUNER=<path>." >&2
  exit 1
fi

# MHz -> integer kHz (the tuner's -f unit).
KHZ=$(awk "BEGIN { printf \"%d\", $FREQ_MHZ * 1000 }")

echo "Building MPXPrimeMeter (release)..."
swift build --package-path macOS -c release --product MPXPrimeMeter
METER="macOS/.build/release/MPXPrimeMeter"

FIFO="$(mktemp -u /tmp/mpxprime-mpx.XXXXXX).fifo"
LOG="$(mktemp -t fm-sdr-tuner).log"
mkfifo "$FIFO"

cleanup() {
  [ -n "${TUNER_PID:-}" ] && kill "$TUNER_PID" 2>/dev/null || true
  rm -f "$FIFO"
}
trap cleanup EXIT INT TERM

echo "Tuning ${FREQ_MHZ} MHz (${KHZ} kHz) via $(basename "$TUNER"). Tuner log: $LOG"
# Launch flags differ: the vendored mpx-tuner uses -o; fm-sdr-tuner uses
# --mpx-wav (+ --auto-start --no-audio). Both write the MPX WAV to the FIFO.
if [ "$(basename "$TUNER")" = "mpx-tuner" ]; then
  "$TUNER" -f "$KHZ" -o "$FIFO" --mpx-rate "$RATE" >"$LOG" 2>&1 &
else
  "$TUNER" -f "$KHZ" --auto-start --no-audio \
    --mpx-wav "$FIFO" --mpx-rate "$RATE" >"$LOG" 2>&1 &
fi
TUNER_PID=$!

# Meter reads the MPX from the FIFO via stdin. Monitor is on by default.
# --full-scale-khz 150 matches the tuner's default -6 dB MPX gain (demod is
# 1.0 = 75 kHz, so full scale = 150 kHz): all deviation readouts -- including
# PILOT -- are then absolute measurements, no pilot-injection assumption.
"$METER" --stdin --sample-rate "$RATE" --full-scale-khz 150 "${METER_ARGS[@]}" < "$FIFO"
