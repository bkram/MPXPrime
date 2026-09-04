#!/bin/bash
# Live real-music A/B + soak for the Advanced Dynamics default-flip campaign.
#
# YOU play the music (route your player to the input BlackHole device); this
# script runs the headless encoder on it, alternates the dynamics engine
# every window (PATCH advanced_dynamics_enabled false/true -- live-apply),
# logs /api/meters at 2 Hz to CSV, and asserts the live invariants: zero
# xruns/ring overflows, Safety Clip idle, never over budget, deviation sane,
# every PATCH applied live with no spike. Precise A/B numbers are
# --verify-program-ab's job (sample-aligned, offline); this leg proves the
# LIVE engine under the toggle and over time.
#
# Usage:
#   ./ab-music-live.sh [--cycles 4] [--window 30] [--soak <hours>]
#                      [--ini <path>] [--input-uid BlackHole2ch_UID]
#                      [--output-uid BlackHole16ch_UID] [--port 8799]
#                      [--csv <path>]
#
# Needs TWO distinct BlackHole devices (brew install blackhole-2ch
# blackhole-16ch): player -> input device (48 kHz), encoder -> output device
# (192 kHz in Audio MIDI Setup). One shared device would feed the composite
# back into the encoder input.
# Do NOT run while MPX Prime Studio is on air (same device class).

set -u
cd "$(dirname "$0")"

INI_DEFAULT="$HOME/Library/Application Support/MPX Prime Studio/MPX Prime Studio.ini"
INI="$INI_DEFAULT"; [ -f "$INI" ] || INI="macOS/Verification.ini"
INPUT_UID="BlackHole2ch_UID"
OUTPUT_UID="BlackHole16ch_UID"
PORT=8799
WINDOW=30
CYCLES=4
SOAK_HOURS=0
CSV=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ini) INI="$2"; shift 2 ;;
    --input-uid) INPUT_UID="$2"; shift 2 ;;
    --output-uid) OUTPUT_UID="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --window) WINDOW="$2"; shift 2 ;;
    --cycles) CYCLES="$2"; shift 2 ;;
    --soak) SOAK_HOURS="$2"; shift 2 ;;
    --csv) CSV="$2"; shift 2 ;;
    *) echo "unknown option $1"; exit 64 ;;
  esac
done

if [ "$INPUT_UID" = "$OUTPUT_UID" ]; then
  echo "FAIL: input and output device must differ -- a shared device feeds the composite back into the encoder input."
  exit 64
fi
if pgrep -f "MPX Prime Studio.app|MPXPrime --gui" >/dev/null; then
  echo "FAIL: MPX Prime Studio appears to be running -- stop it first (this test opens the audio device)."
  exit 3
fi

BIN=macOS/.build/release/MPXPrime
if [ ! -x "$BIN" ]; then
  echo "[ab] building release binary..."
  swift build --package-path macOS -c release --product MPXPrime >/dev/null 2>&1 || { echo "FAIL: build"; exit 3; }
fi

WORK=$(mktemp -d /tmp/mpxprime-abmusic.XXXXXX)
TMP_INI="$WORK/ab.ini"
LOG="$WORK/engine.log"
[ -n "$CSV" ] || CSV="$WORK/ab-music.csv"
trap 'kill $ENGINE_PID 2>/dev/null; wait $ENGINE_PID 2>/dev/null' EXIT

# Copy the INI, rewriting only what the A/B needs (same rewriter block as
# smoke-live.sh): live input from the player device, composite to the other
# device, control API on loopback, AD off so phase A starts deterministic.
python3 - "$INI" "$TMP_INI" "$INPUT_UID" "$OUTPUT_UID" "$PORT" <<'EOF'
import sys, re
src, dst, in_uid, out_uid, port = sys.argv[1:6]
text = open(src).read()
sections = {}
order = []
cur = ""
for line in text.split("\n"):
    m = re.match(r"^\[(.+)\]\s*$", line.strip())
    if m:
        cur = m.group(1); order.append(cur); sections.setdefault(cur, [])
        continue
    sections.setdefault(cur, []).append(line)
def setkey(section, key, value):
    lines = sections.setdefault(section, [])
    if section not in order: order.append(section)
    for i, l in enumerate(lines):
        if re.match(r"^\s*" + re.escape(key) + r"\s*=", l):
            lines[i] = f"{key} = {value}"; return
    lines.append(f"{key} = {value}")
setkey("INTERFACES", "input_device_uid", in_uid)
setkey("INTERFACES", "output_device_uid", out_uid)
setkey("INTERFACES", "monitor_enabled", "False")
setkey("INTERFACES", "source_mode", "input")
setkey("MPX", "source_mode", "input")
setkey("MPX", "advanced_dynamics_enabled", "False")
setkey("CONTROL", "control_enabled", "True")
setkey("CONTROL", "control_bind", "127.0.0.1")
setkey("CONTROL", "control_port", str(port))
setkey("CONTROL", "control_api_key", "")
out = []
for s in order:
    out.append(f"[{s}]"); out.extend(sections[s]); out.append("")
if "" in sections and sections[""]:
    out = sections[""] + out
open(dst, "w").write("\n".join(out))
EOF

if [ "$SOAK_HOURS" != "0" ]; then
  TOTAL=$(python3 -c "print(int($SOAK_HOURS*3600))")
  CYCLES=$(python3 -c "import math; print(max(1, math.ceil($TOTAL/(2*$WINDOW))))")
else
  TOTAL=$((CYCLES * 2 * WINDOW))
fi
RUN_SECONDS=$((TOTAL + 120))

echo "[ab] INI:     $INI"
echo "[ab] input:   $INPUT_UID -> output: $OUTPUT_UID   port $PORT"
echo "[ab] plan:    $CYCLES cycle(s) x 2 x ${WINDOW}s = ${TOTAL}s $( [ "$SOAK_HOURS" != "0" ] && echo "(soak ${SOAK_HOURS}h)" )"
echo "[ab] work:    $WORK   csv: $CSV"
"$BIN" --nogui --config "$TMP_INI" --control-port "$PORT" --seconds "$RUN_SECONDS" >"$LOG" 2>&1 &
ENGINE_PID=$!

API="http://127.0.0.1:$PORT/api"
PASS=0; FAILS=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL  $1"; FAILS=$((FAILS+1)); }

for _ in $(seq 1 60); do
  if curl -sf "$API/status" 2>/dev/null | jq -e '.running == true' >/dev/null 2>&1; then break; fi
  sleep 0.5
done
STATUS=$(curl -sf "$API/status" 2>/dev/null)
if [ -z "$STATUS" ]; then
  echo "FAIL: control server did not come up. Engine log:"; tail -20 "$LOG"; exit 2
fi
echo "[ab] status: $(echo "$STATUS" | jq -c '{running, sampleRateHz, sourceMode, restartPending}')"
echo "$STATUS" | jq -e '.running == true' >/dev/null && ok "engine running" || { fail "engine not running"; tail -20 "$LOG"; }
DEVKHZ=$(curl -sf "$API/config" | jq -r '.MPX.mpx_deviation_khz // 75' 2>/dev/null); DEVKHZ=${DEVKHZ:-75}
DEVLIMIT=$(python3 -c "print(float('$DEVKHZ') + 1.5)")

echo
echo ">>> Start your music playback into '$INPUT_UID' now (loop a playlist for soaks). <<<"
PROGRAM_SEEN=false
for _ in $(seq 1 120); do
  P=$(curl -sf "$API/meters" | jq -r '(.inputLeftPeak // 0)')
  if python3 -c "import sys; sys.exit(0 if $P > 0.02 else 1)"; then PROGRAM_SEEN=true; break; fi
  sleep 1
done
if [ "$PROGRAM_SEEN" = "true" ]; then ok "program present on the input"; else fail "no program on '$INPUT_UID' after 120 s"; fi

echo "ts,phase,adOn,deviationKHzPeak,agcGainDB,adDensityDB,adBandGainsDB,clipperGRDB,preLimGRDB,safetyGRDB,safetyClipDB,budgetMarginDB,overBudget,corr,captureXruns,ringOverflows,ringUnderflows,rssKB,uptime" >"$CSV"

BASE_XR=$(curl -sf "$API/meters" | jq -r '(.captureXruns // 0)')
BASE_OVR=$(curl -sf "$API/meters" | jq -r '(.inputRingOverflows // 0)')
MAXCLIP=0; OVER=false; MAXDEV=0; DEVIATION_VIOL=0
LAST_UPTIME=0; UPTIME_RESET=false
PATCH_FAILS=0; PATCH_SPIKES=0
RSS_AT_10MIN=""; START_TS=$(date +%s)

sample() { # $1=phase-label $2=adOn
  local M TS RSS UP
  M=$(curl -sf "$API/meters"); [ -n "$M" ] || return
  TS=$(( $(date +%s) - START_TS ))
  RSS=$(ps -o rss= -p "$ENGINE_PID" 2>/dev/null | tr -d ' ')
  UP=$(curl -sf "$API/status" | jq -r '.uptimeSeconds // 0')
  python3 -c "import sys; sys.exit(0 if $UP + 1 >= $LAST_UPTIME else 1)" || UPTIME_RESET=true
  LAST_UPTIME=$UP
  echo "$M" | jq -r --arg ts "$TS" --arg ph "$1" --arg ad "$2" --arg rss "${RSS:-0}" --arg up "$UP" \
    '[$ts, $ph, $ad, (.deviationKHzPeak // 0), (.agcGainDB // 0), (.advancedDynamicsDensityDB // 0),
      ((.advancedDynamicsBandGainsDB // []) | map(tostring) | join("/")),
      (.compositeClipperGainReductionDB // 0), (.preEncodeLimiterGainReductionDB // 0),
      (.safetyLimiterGainReductionDB // 0), (.safetyClipDB // 0), (.compositeBudgetMarginDB // 0),
      (.compositeOverBudget // false), (.stereoCorrelation // 0), (.captureXruns // 0),
      (.inputRingOverflows // 0), (.inputRingUnderflows // 0), $rss, $up] | @csv' >>"$CSV"
  local D C O
  D=$(echo "$M" | jq -r '.deviationKHzPeak // 0'); C=$(echo "$M" | jq -r '.safetyClipDB // 0')
  O=$(echo "$M" | jq -r '.compositeOverBudget // false')
  MAXDEV=$(python3 -c "print(max($MAXDEV,$D))"); MAXCLIP=$(python3 -c "print(max($MAXCLIP,$C))")
  [ "$O" = "true" ] && OVER=true
  python3 -c "import sys; sys.exit(0 if $D <= $DEVLIMIT else 1)" || DEVIATION_VIOL=$((DEVIATION_VIOL+1))
  # Soak bookkeeping: RSS reference after 10 min of warm-up.
  if [ -z "$RSS_AT_10MIN" ] && [ "$TS" -ge 600 ]; then RSS_AT_10MIN="${RSS:-0}"; fi
}

toggle_ad() { # $1 = true|false
  local R XR0 XR1
  XR0=$(curl -sf "$API/meters" | jq -r '(.captureXruns // 0)')
  R=$(curl -sf -X PATCH -H 'Content-Type: application/json' -d "{\"advanced_dynamics_enabled\":\"$1\"}" "$API/config")
  echo "$R" | jq -e '.appliedLive == true and .restartPending == false' >/dev/null || PATCH_FAILS=$((PATCH_FAILS+1))
  sleep 2
  XR1=$(curl -sf "$API/meters" | jq -r '(.captureXruns // 0)')
  local CLIP
  CLIP=$(curl -sf "$API/meters" | jq -r '.safetyClipDB // 0')
  python3 -c "import sys; sys.exit(0 if $XR1 <= $XR0 and $CLIP <= 0.05 else 1)" || PATCH_SPIKES=$((PATCH_SPIKES+1))
}

CYCLE=0
LAST_RSS_MIN=0
while [ "$CYCLE" -lt "$CYCLES" ]; do
  CYCLE=$((CYCLE+1))
  for PHASE in A B; do
    if [ "$PHASE" = "A" ]; then toggle_ad false; ADON=0; else toggle_ad true; ADON=1; fi
    LABEL="c${CYCLE}${PHASE}"
    END=$(( $(date +%s) + WINDOW - 2 ))
    while [ "$(date +%s)" -lt "$END" ]; do
      sample "$LABEL" "$ADON"
      sleep 0.5
    done
    [ "$SOAK_HOURS" = "0" ] && echo "[ab] cycle $CYCLE phase $PHASE done"
  done
  # Soak: one console heartbeat per ~10 min.
  if [ "$SOAK_HOURS" != "0" ]; then
    NOW_MIN=$(( ( $(date +%s) - START_TS ) / 600 ))
    if [ "$NOW_MIN" -gt "$LAST_RSS_MIN" ]; then
      LAST_RSS_MIN=$NOW_MIN
      echo "[ab] soak $(( ( $(date +%s) - START_TS ) / 60 )) min: rss $(ps -o rss= -p "$ENGINE_PID" | tr -d ' ') KB, maxdev $MAXDEV, clip $MAXCLIP"
    fi
  fi
  if ! kill -0 "$ENGINE_PID" 2>/dev/null; then fail "engine exited early"; break; fi
done

# Verdicts.
XR_END=$(curl -sf "$API/meters" | jq -r '(.captureXruns // 0)')
OVR_END=$(curl -sf "$API/meters" | jq -r '(.inputRingOverflows // 0)')
RSS_END=$(ps -o rss= -p "$ENGINE_PID" 2>/dev/null | tr -d ' ')
curl -sf -X POST "$API/transport/stop" >/dev/null 2>&1

python3 -c "import sys; sys.exit(0 if ${XR_END:-0} - ${BASE_XR:-0} == 0 else 1)" && ok "no capture xruns" || fail "capture xruns grew: $BASE_XR -> $XR_END"
python3 -c "import sys; sys.exit(0 if ${OVR_END:-0} - ${BASE_OVR:-0} == 0 else 1)" && ok "no input-ring overflows" || fail "ring overflows grew: $BASE_OVR -> $OVR_END"
python3 -c "import sys; sys.exit(0 if $MAXCLIP <= 0.05 else 1)" && ok "Safety Clip idle (max $MAXCLIP dB)" || fail "Safety Clip active: $MAXCLIP dB"
[ "$OVER" = "false" ] && ok "never over budget" || fail "composite over budget during the run"
[ "$DEVIATION_VIOL" = "0" ] && ok "deviation <= ${DEVLIMIT} kHz throughout (max $MAXDEV)" || fail "$DEVIATION_VIOL samples above ${DEVLIMIT} kHz (max $MAXDEV)"
[ "$PATCH_FAILS" = "0" ] && ok "every AD toggle applied live" || fail "$PATCH_FAILS AD toggles not applied live"
[ "$PATCH_SPIKES" = "0" ] && ok "no xrun/clip spike on any AD toggle" || fail "$PATCH_SPIKES AD toggles spiked xruns/safety clip"
[ "$UPTIME_RESET" = "false" ] && ok "uptime monotonic (no silent restart)" || fail "engine uptime went backwards (silent restart)"
if [ "$SOAK_HOURS" != "0" ] && [ -n "$RSS_AT_10MIN" ] && [ -n "$RSS_END" ]; then
  python3 -c "import sys; sys.exit(0 if $RSS_END <= $RSS_AT_10MIN * 1.10 else 1)" \
    && ok "RSS bounded (${RSS_AT_10MIN} -> ${RSS_END} KB)" || fail "RSS grew >10% after warm-up (${RSS_AT_10MIN} -> ${RSS_END} KB)"
fi

# A/B summary from the CSV (loose, informational -- live audio is not
# sample-aligned; --verify-program-ab owns precise deltas).
python3 - "$CSV" <<'EOF'
import csv, statistics, sys
rows = list(csv.reader(open(sys.argv[1])))[1:]
def col(rows, adon, idx):
    vals = [float(r[idx]) for r in rows if r[2] == adon and r[3] != "0"]
    return vals
for label, adon in (("A classic", "0"), ("B leveler", "1")):
    dev = col(rows, adon, 3)
    clip = col(rows, adon, 8)
    safety = col(rows, adon, 9)
    if not dev:
        print(f"[ab] {label}: no samples"); continue
    print(f"[ab] {label}: median dev {statistics.median(dev):.1f} kHz (p95 {sorted(dev)[int(0.95*(len(dev)-1))]:.1f}), "
          f"median pre-lim GR {statistics.median(clip):.2f} dB, median safety GR {statistics.median(safety):.2f} dB, n={len(dev)}")
EOF

echo
echo "[ab] engine log tail:"; grep -vE "^\[NowPlaying\]" "$LOG" | tail -6 | sed 's/^/  /'
echo
if [ "$FAILS" -eq 0 ]; then echo "AB-MUSIC PASS ($PASS checks) -- csv: $CSV"; exit 0; else echo "AB-MUSIC FAIL ($FAILS failed, $PASS passed) -- see $LOG / $CSV"; exit 1; fi
