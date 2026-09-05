#!/bin/bash
# scripts/calibrate-tx.sh -- closed-loop deviation calibration of MPX Prime Studio
# against an off-air RTL-SDR measurement (the small, scripted version of the
# Studio<->Meter closed-loop trim in meter-plan.md).
#
# Method: the 19 kHz pilot is a constant-amplitude reference, so its measured
# deviation is program-independent. The script reads Studio's configured
# injection (pilot_level x mpx_deviation_khz), measures the actual pilot
# deviation off air through the honest chain (clean manual RF gain -- auto
# gain rails on a strong local -- and an explicit 200 kHz channel filter via
# mpx-offline; see meter-plan.md, bench 2026-08-31), and trims Studio's
# output_gain_db over the REST API until the two agree. output_gain_db is
# attenuation-only in composite mode: if calibration would need gain ABOVE
# 0 dB the script says to raise the exciter's input sensitivity instead.
#
# Prerequisites:
#   - MPX Prime Studio running with the control API (--control-port 8737 or
#     the GUI with the API enabled), transmitting on the target frequency.
#   - An RTL-SDR dongle attached, antenna receiving the TX.
#   - Homebrew rtl-sdr (rtl_sdr), python3, curl, jq.
#   - Release builds: macOS/.build/release/MPXPrimeMeter (swift build -c
#     release) and tuner mpx-offline (built automatically if cmake is there).
#
# Usage:
#   scripts/calibrate-tx.sh --freq 85.8 [--api http://127.0.0.1:8737]
#                     [--api-key KEY] [--gain <dB>|auto] [--seconds 20]
#                     [--iterations 5] [--tolerance-db 0.1] [--dry-run]
#                     [--watch] [--tone [level_db]]
#
# --watch: no PATCHing -- print a fresh off-air measurement every few seconds
# so you can turn the EXCITER's input-sensitivity trimmer until the error
# reads 0.0 dB (the move when Studio is already at digital full scale and the
# DAC volume is maxed, so software has no gain left to give). Ctrl-C to stop.
#
# --tone: switch Studio to its built-in test tone (the 0.45 calibration
# source: a mono 997 Hz sine, default -20 dBFS, bypassing every gain stage)
# for the duration of the run, restoring the previous program source on exit.
# The pilot is constant-amplitude either way, but dense program puts
# pre-emphasized HF right next to 19 kHz and wobbles the measurement by
# ~+/-0.1 dB pass to pass; a steady low tone removes that, so use --tone
# whenever a minute of tone on air is acceptable.
#
# Exit 0: calibrated within tolerance (or --dry-run measured cleanly).

set -u

FREQ_MHZ=""
API="http://127.0.0.1:8737"
API_KEY=""
GAIN="auto"
SECONDS_PER_PASS=20
ITERATIONS=5
TOL_DB=0.1
DRY_RUN=0
WATCH=0
TONE=0
TONE_LEVEL_DB=-20

while [ $# -gt 0 ]; do
  case "$1" in
    --freq) FREQ_MHZ="$2"; shift 2 ;;
    --api) API="$2"; shift 2 ;;
    --api-key) API_KEY="$2"; shift 2 ;;
    --gain) GAIN="$2"; shift 2 ;;
    --seconds) SECONDS_PER_PASS="$2"; shift 2 ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --tolerance-db) TOL_DB="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --watch) WATCH=1; shift ;;
    --tone)
      TONE=1; shift
      # Optional level argument (a number, e.g. --tone -16).
      if [ $# -gt 0 ] && python3 -c "float('$1')" 2>/dev/null; then TONE_LEVEL_DB="$1"; shift; fi ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$FREQ_MHZ" ] || { echo "calibrate-tx: --freq <MHz> is required (e.g. --freq 85.8)" >&2; exit 2; }

for tool in rtl_sdr python3 curl jq; do
  command -v "$tool" >/dev/null || { echo "calibrate-tx: $tool not found" >&2; exit 2; }
done

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
METER="$REPO_DIR/macOS/.build/release/MPXPrimeMeter"
[ -x "$METER" ] || { echo "calibrate-tx: $METER missing -- run: swift build --package-path macOS -c release" >&2; exit 2; }

# mpx-offline: the device-free demod harness (applies the explicit 200 kHz
# channel filter the live factor-1 path lacks). Build it on first use.
OFFLINE="${MPX_OFFLINE:-$REPO_DIR/tuner/build-offline/mpx-offline}"
if [ ! -x "$OFFLINE" ]; then
  command -v cmake >/dev/null || { echo "calibrate-tx: mpx-offline not built and cmake not found" >&2; exit 2; }
  echo "[cal] building mpx-offline..."
  cmake -S "$REPO_DIR/tuner" -B "$REPO_DIR/tuner/build-offline" -DCMAKE_BUILD_TYPE=Release >/dev/null \
    && cmake --build "$REPO_DIR/tuner/build-offline" --target mpx-offline >/dev/null \
    || { echo "calibrate-tx: mpx-offline build failed (need liquid-dsp: brew install liquid-dsp)" >&2; exit 2; }
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/calibrate-tx.XXXXXX")"
RESTORE_PATCH=""   # set when --tone switched the program source
cleanup() {
  if [ -n "$RESTORE_PATCH" ]; then
    echo "[cal] restoring the previous program source"
    api_patch "$RESTORE_PATCH" >/dev/null 2>&1 || echo "calibrate-tx: could not restore source_mode -- check Studio" >&2
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

AUTH=()
[ -n "$API_KEY" ] && AUTH=(-H "X-API-Key: $API_KEY")

# ${AUTH[@]+...}: bash 3.2 under set -u treats an empty array as unbound.
api_get() { curl -sf ${AUTH[@]+"${AUTH[@]}"} "$API$1"; }
api_patch() { curl -sf ${AUTH[@]+"${AUTH[@]}"} -X PATCH -H 'Content-Type: application/json' -d "$1" "$API/api/config"; }

# --- Studio state -----------------------------------------------------------
STATUS="$(api_get /api/status)" || { echo "calibrate-tx: Studio API not reachable at $API" >&2; exit 1; }
echo "$STATUS" | jq -e '.running == true' >/dev/null || { echo "calibrate-tx: Studio transport is not running" >&2; exit 1; }

CFG="$(api_get /api/config)" || { echo "calibrate-tx: /api/config failed" >&2; exit 1; }
# Search every section the keys we use live in: [MPX] (levels, tone),
# [INTERFACES] (source_mode -- reading only .MPX here once silently
# "restored" a tone-running rig to live input), then flat.
cfgval() {
  echo "$CFG" | jq -r \
    ".MPX.\"$1\" // .mpx.\"$1\" // .INTERFACES.\"$1\" // .interfaces.\"$1\" // .\"$1\" // empty"
}
PILOT_LEVEL="$(cfgval pilot_level)"
DEV_KHZ="$(cfgval mpx_deviation_khz)"
RDS_LEVEL="$(echo "$CFG" | jq -r '.RDS.rds_level // .rds.rds_level // .rds_level // empty')"
OUT_GAIN="$(cfgval output_gain_db)"
[ -n "$PILOT_LEVEL" ] && [ -n "$DEV_KHZ" ] || { echo "calibrate-tx: could not read pilot_level / mpx_deviation_khz from /api/config" >&2; exit 1; }
TARGET_PILOT="$(python3 -c "print('%.3f' % (float('$PILOT_LEVEL') * float('$DEV_KHZ')))")"
echo "[cal] Studio: pilot_level=$PILOT_LEVEL deviation=${DEV_KHZ} kHz -> target pilot ${TARGET_PILOT} kHz; rds_level=${RDS_LEVEL:-?} kHz; output_gain_db=$OUT_GAIN"

FREQ_HZ="$(python3 -c "print(int(float('$FREQ_MHZ') * 1e6))")"

# --- Optional: steady tone as the measurement program ------------------------
if [ "$TONE" = "1" ]; then
  ORIG_SOURCE="$(cfgval source_mode)"; ORIG_SOURCE="${ORIG_SOURCE:-input}"
  ORIG_TONE_LEVEL="$(cfgval test_tone_level_db)"
  ORIG_TONE_TYPE="$(cfgval test_tone_type)"
  ORIG_TONE_FREQ="$(cfgval test_tone_freq)"
  ORIG_TONE_MODE="$(cfgval test_tone_mode)"
  RESTORE_PATCH="{\"source_mode\":\"$ORIG_SOURCE\""
  [ -n "$ORIG_TONE_LEVEL" ] && RESTORE_PATCH="$RESTORE_PATCH,\"test_tone_level_db\":\"$ORIG_TONE_LEVEL\""
  [ -n "$ORIG_TONE_TYPE" ] && RESTORE_PATCH="$RESTORE_PATCH,\"test_tone_type\":\"$ORIG_TONE_TYPE\""
  [ -n "$ORIG_TONE_FREQ" ] && RESTORE_PATCH="$RESTORE_PATCH,\"test_tone_freq\":\"$ORIG_TONE_FREQ\""
  [ -n "$ORIG_TONE_MODE" ] && RESTORE_PATCH="$RESTORE_PATCH,\"test_tone_mode\":\"$ORIG_TONE_MODE\""
  RESTORE_PATCH="$RESTORE_PATCH}"
  echo "[cal] switching Studio to the test tone (997 Hz sine, ${TONE_LEVEL_DB} dBFS, mono) for the run"
  R="$(api_patch "{\"source_mode\":\"tone\",\"test_tone_type\":\"sine\",\"test_tone_freq\":\"997\",\"test_tone_mode\":\"mono\",\"test_tone_level_db\":\"$TONE_LEVEL_DB\"}")" \
    || { echo "calibrate-tx: could not switch to the test tone" >&2; exit 1; }
  if echo "$R" | jq -e '.restartPending == true' >/dev/null 2>&1; then
    curl -sf ${AUTH[@]+"${AUTH[@]}"} -X POST "$API/api/transport/restart" >/dev/null
    sleep 4
  fi
  sleep 2   # let the tone settle on air before measuring
fi

# --- Capture helpers --------------------------------------------------------
# Saturation share of a packed-uint8 IQ capture (0..1), sampled as 8 windows
# spread across the WHOLE file -- one fixed slice once missed a signal swell
# that railed a later portion while the gate declared the capture clean.
# Railed IQ inflates every level reading (measured: +5% pilot, +24% RDS,
# 4x baseband noise).
sat_share() {
  python3 - "$1" <<'PY'
import os, sys
path = sys.argv[1]
size = os.path.getsize(path)
if size < 100000:
    print('1.00000')  # too short to trust: fail the gate, not pass it
    sys.exit(0)
win, nwin = 200000, 8
railed = total = 0
with open(path, 'rb') as f:
    for k in range(nwin):
        f.seek(max(0, (size - win) * k // (nwin - 1)))
        v = f.read(win)
        railed += sum(1 for b in v if b < 2 or b > 253)
        total += len(v)
print('%.5f' % (railed / max(1, total)))
PY
}

capture() { # $1 = seconds, $2 = gain dB, $3 = out path
  rm -f "$3"
  rtl_sdr -f "$FREQ_HZ" -s 256000 -g "$2" -n $((256000 * $1)) "$3" >/dev/null 2>&1
  # rtl_sdr exits nonzero on a busy/absent dongle, and a truncated file means
  # the capture died early -- either way the pass must fail loudly instead of
  # letting an empty file read as a perfectly clean capture.
  [ -s "$3" ] || { echo "calibrate-tx: capture produced no data -- dongle busy (Meter running?) or absent" >&2; return 1; }
  local want=$((256000 * $1 * 2))
  local got; got=$(wc -c < "$3")
  [ "$got" -ge $((want * 9 / 10)) ] \
    || { echo "calibrate-tx: capture truncated ($got of $want bytes) -- USB stall or dongle contention" >&2; return 1; }
}

# Highest RTL gain that does not rail (best SNR without clipping products).
if [ "$GAIN" = "auto" ]; then
  for g in 33.8 28.0 22.9 19.7 15.7 12.5 8.7 3.7 0.9; do
    capture 3 "$g" "$WORK/gain.iq" || exit 1
    s="$(sat_share "$WORK/gain.iq")"
    if python3 -c "exit(0 if float('$s') < 0.0005 else 1)"; then GAIN="$g"; break; fi
  done
  [ "$GAIN" = "auto" ] && { echo "calibrate-tx: front end rails even at 0.9 dB -- attenuate the antenna" >&2; exit 1; }
  echo "[cal] RF gain: $GAIN dB (highest setting with a clean, unrailed capture)"
fi

# Measure pilot/RDS/MAX deviation off air. Prints "pilot rds max" in kHz.
measure() { # $1 = seconds
  capture "$1" "$GAIN" "$WORK/pass.iq" || return 1
  local s; s="$(sat_share "$WORK/pass.iq")"
  python3 -c "exit(0 if float('$s') < 0.001 else 1)" \
    || { echo "calibrate-tx: capture railed (share $s) -- rerun with a lower --gain" >&2; return 1; }
  "$OFFLINE" --iq-in "$WORK/pass.iq" --path packed --bandwidth-khz 200 --mpx-rate 192000 2>/dev/null \
    | "$METER" --stdin --sample-rate 192000 --full-scale-khz 150 --no-monitor 2>&1 \
    | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | grep -a "^DEV " | grep -av "PILOT 0.00" | tail -1 \
    | awk '{print $3, $5, $7}'
}

# --- Watch mode: live readout for a hardware (exciter trimmer) adjustment ---
if [ "$WATCH" = "1" ]; then
  echo "[cal] watch mode: turn the exciter's input-sensitivity trimmer until error reads 0.0 dB (Ctrl-C to stop)"
  while :; do
    # Capture into a variable FIRST: `read <<< "$(cmd)"` succeeds even when
    # cmd fails, so testing read's status silently ignored measure() errors.
    M_OUT="$(measure 6)" || continue
    read -r PILOT RDS MAXDEV <<< "$M_OUT"
    [ -n "${PILOT:-}" ] || { echo "[cal] no pilot decoded"; continue; }
    ERR_DB="$(python3 -c "import math; print('%+.2f' % (20*math.log10(float('$TARGET_PILOT')/float('$PILOT'))))")"
    echo "[cal] pilot ${PILOT} kHz (target ${TARGET_PILOT})  rds ${RDS} kHz  max ${MAXDEV} kHz  error ${ERR_DB} dB"
  done
fi

# --- Calibration loop -------------------------------------------------------
FINAL_PILOT=""
for i in $(seq 1 "$ITERATIONS"); do
  M_OUT="$(measure "$SECONDS_PER_PASS")" || exit 1
  read -r PILOT RDS MAXDEV <<< "$M_OUT"
  [ -n "${PILOT:-}" ] || { echo "calibrate-tx: no pilot decoded -- is the TX on $FREQ_MHZ MHz and the antenna connected?" >&2; exit 1; }
  ERR_DB="$(python3 -c "import math; print('%.2f' % (20*math.log10(float('$TARGET_PILOT')/float('$PILOT'))))")"
  echo "[cal] pass $i: pilot ${PILOT} kHz (target ${TARGET_PILOT})  rds ${RDS} kHz  max ${MAXDEV} kHz  error ${ERR_DB} dB"
  FINAL_PILOT="$PILOT"
  if python3 -c "exit(0 if abs(float('$ERR_DB')) <= float('$TOL_DB') else 1)"; then
    echo "[cal] within ${TOL_DB} dB -- calibrated."
    break
  fi
  [ "$DRY_RUN" = "1" ] && { echo "[cal] dry run: would set output_gain_db=$(python3 -c "print('%.2f' % min(0.0, float('$OUT_GAIN')+float('$ERR_DB')))")"; exit 0; }
  NEW_GAIN="$(python3 -c "print('%.2f' % min(0.0, float('$OUT_GAIN') + float('$ERR_DB')))")"
  if python3 -c "exit(0 if float('$OUT_GAIN')+float('$ERR_DB') > 0.005 else 1)"; then
    echo "[cal] WARNING: full calibration needs +$(python3 -c "print('%.2f' % (float('$OUT_GAIN')+float('$ERR_DB')))") dB, but output_gain_db is attenuation-only."
    echo "[cal]          Raise the EXCITER's input sensitivity/drive by that amount, then rerun."
    if [ "$NEW_GAIN" != "$OUT_GAIN" ]; then
      api_patch "{\"output_gain_db\":\"$NEW_GAIN\"}" >/dev/null || { echo "calibrate-tx: PATCH failed" >&2; exit 1; }
      OUT_GAIN="$NEW_GAIN"
    fi
    break   # iterating cannot close a positive-gain gap; verify and report
  fi
  echo "[cal] PATCH output_gain_db: $OUT_GAIN -> $NEW_GAIN"
  api_patch "{\"output_gain_db\":\"$NEW_GAIN\"}" >/dev/null || { echo "calibrate-tx: PATCH failed" >&2; exit 1; }
  OUT_GAIN="$NEW_GAIN"
  sleep 2   # live-apply + air settle before the next measurement
done

# --- Final verification ------------------------------------------------------
echo "[cal] verification pass (30 s)..."
M_OUT="$(measure 30)" || exit 1
read -r PILOT RDS MAXDEV <<< "$M_OUT"
VERR="$(python3 -c "import math; print('%+.2f' % (20*math.log10(float('$TARGET_PILOT')/float('$PILOT'))))")"
echo "[cal] RESULT: pilot ${PILOT} kHz (target ${TARGET_PILOT}, ${VERR} dB)   rds ${RDS} kHz (set ${RDS_LEVEL:-?})   max dev ${MAXDEV} kHz   output_gain_db ${OUT_GAIN}"
python3 -c "exit(0 if abs(float('$VERR')) <= float('$TOL_DB') else 1)" \
  && { echo "[cal] PASS"; exit 0; } \
  || { echo "[cal] verification pass reads ${VERR} dB (tolerance ${TOL_DB}) -- program/reception wobble; try --tone, or accept if repeat runs straddle 0"; exit 1; }
