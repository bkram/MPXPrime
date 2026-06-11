#!/usr/bin/env bash
#
# Tune an RTL-SDR with the FM-SDR-Tuner project and pipe its MPX composite into
# the MPX Prime Meter over a FIFO -- decode + measure + hear a live station.
#
#   ./run-meter-sdr.sh --freq 88.6
#   ./run-meter-sdr.sh --freq 101.1 --no-monitor --wav ~/cap.wav
#   ./run-meter-sdr.sh --freq 88.6 --pilot-ref-khz 6.8
#
# --freq <MHz> is required. Every other argument is forwarded verbatim to
# MPXPrimeMeter (--channel is irrelevant here; the piped MPX is mono).
#
# A FIFO carries the 16-bit/192 kHz mono MPX; the tuner's stdout logs go to a
# logfile so they don't corrupt the stream. Monitor (decoded audio) is on by
# default -- you hear the station. Requires an RTL-SDR connected and the
# FM-SDR-Tuner binary built at ~/Projects/git/FM-SDR-Tuner/build/fm-sdr-tuner.
set -euo pipefail

cd "$(dirname "$0")"

TUNER="${FM_SDR_TUNER:-$HOME/Projects/git/FM-SDR-Tuner/build/fm-sdr-tuner}"
RATE=192000

# Parse --freq (MHz); forward the rest to the meter.
FREQ_MHZ=""
METER_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --freq) FREQ_MHZ="$2"; shift 2 ;;
    --freq=*) FREQ_MHZ="${1#*=}"; shift ;;
    *) METER_ARGS+=("$1"); shift ;;
  esac
done

if [ -z "$FREQ_MHZ" ]; then
  echo "usage: ./run-meter-sdr.sh --freq <MHz> [meter args...]" >&2
  exit 2
fi
if [ ! -x "$TUNER" ]; then
  echo "FM-SDR-Tuner binary not found/executable: $TUNER" >&2
  echo "Build it in ~/Projects/git/FM-SDR-Tuner, or set FM_SDR_TUNER=<path>." >&2
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

echo "Tuning ${FREQ_MHZ} MHz (${KHZ} kHz). Tuner log: $LOG"
# Tuner: tune, start immediately, no 48 kHz audio, MPX -> FIFO as WAV @ 192 kHz.
"$TUNER" -f "$KHZ" --auto-start --no-audio \
  --mpx-wav "$FIFO" --mpx-rate "$RATE" >"$LOG" 2>&1 &
TUNER_PID=$!

# Meter reads the MPX from the FIFO via stdin. Monitor is on by default.
# --full-scale-khz 150 matches the tuner's default -6 dB MPX gain (demod is
# 1.0 = 75 kHz, so full scale = 150 kHz): all deviation readouts -- including
# PILOT -- are then absolute measurements, no pilot-injection assumption.
"$METER" --stdin --sample-rate "$RATE" --full-scale-khz 150 "${METER_ARGS[@]}" < "$FIFO"
