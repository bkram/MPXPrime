#!/bin/bash
# Live engine smoke test against a null/virtual output (BlackHole 2ch by default).
#
# Exercises the REAL CoreAudio path that the offline --verify* gates cannot:
# engine start on a device, HAL buffer negotiation, the calibration test tone
# end to end (deviation telemetry vs the value the Test Tone card predicts),
# pilot injection, the Safety Clip readout, a live-apply PATCH and a
# restart-class PATCH + transport restart through the REST API -- headless,
# without touching an exciter. Exit 0 = every check passed.
#
# Usage: ./smoke-live.sh [--ini <path>] [--device-uid <uid>] [--port <n>] [--seconds <n>]
#   --ini         INI to smoke (default: your station INI in Application Support;
#                 falls back to macOS/Verification.ini). The file is COPIED; the
#                 original is never modified.
#   --device-uid  CoreAudio UID of the virtual device (default BlackHole2ch_UID;
#                 `brew install blackhole-2ch`, set it to 192 kHz in Audio MIDI Setup).
#
# Do NOT run this while MPX Prime Studio is on air: it opens the same device
# class and its build/render load starves a live capture.

set -u
cd "$(dirname "$0")"

INI_DEFAULT="$HOME/Library/Application Support/MPX Prime Studio/MPX Prime Studio.ini"
INI="$INI_DEFAULT"; [ -f "$INI" ] || INI="macOS/Verification.ini"
DEVICE_UID="BlackHole2ch_UID"
PORT=8799
SECONDS_RUN=60
while [ $# -gt 0 ]; do
  case "$1" in
    --ini) INI="$2"; shift 2 ;;
    --device-uid) DEVICE_UID="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --seconds) SECONDS_RUN="$2"; shift 2 ;;
    *) echo "unknown option $1"; exit 64 ;;
  esac
done

if pgrep -f "MPX Prime Studio.app|MPXPrime --gui" >/dev/null; then
  echo "FAIL: MPX Prime Studio appears to be running -- stop it first (this test opens the audio device)."
  exit 3
fi

BIN=macOS/.build/release/MPXPrime
if [ ! -x "$BIN" ]; then
  echo "[smoke] building release binary..."
  swift build --package-path macOS -c release --product MPXPrime >/dev/null 2>&1 || { echo "FAIL: build"; exit 3; }
fi

WORK=$(mktemp -d /tmp/mpxprime-smoke.XXXXXX)
TMP_INI="$WORK/smoke.ini"
LOG="$WORK/engine.log"
trap 'kill $ENGINE_PID 2>/dev/null; wait $ENGINE_PID 2>/dev/null' EXIT

# Copy the INI and rewrite ONLY what the smoke needs: virtual device in/out,
# tone source, control server on loopback. Everything else (processing, RDS,
# calibration) is what the operator runs.
python3 - "$INI" "$TMP_INI" "$DEVICE_UID" "$PORT" <<'EOF'
import sys, re
src, dst, uid, port = sys.argv[1:5]
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
setkey("INTERFACES", "input_device_uid", uid)
setkey("INTERFACES", "output_device_uid", uid)
setkey("INTERFACES", "monitor_enabled", "False")
setkey("INTERFACES", "source_mode", "tone")
setkey("MPX", "source_mode", "tone")
setkey("MPX", "test_tone_type", "sine")
setkey("MPX", "test_tone_mode", "mono")
setkey("MPX", "test_tone_freq", "1000.0")
setkey("MPX", "test_tone_level_db", "-12.0")
setkey("CONTROL", "control_enabled", "True")
setkey("CONTROL", "control_bind", "127.0.0.1")
setkey("CONTROL", "control_port", str(port))
setkey("CONTROL", "control_api_key", "")
setkey("RDS", "auto_start", "True")
out = []
for s in order:
    out.append(f"[{s}]"); out.extend(sections[s]); out.append("")
if "" in sections and sections[""]:
    out = sections[""] + out
open(dst, "w").write("\n".join(out))
EOF

echo "[smoke] INI:     $INI"
echo "[smoke] device:  $DEVICE_UID   port $PORT   run ${SECONDS_RUN}s"
echo "[smoke] work:    $WORK"
"$BIN" --nogui --config "$TMP_INI" --control-port "$PORT" --seconds "$SECONDS_RUN" >"$LOG" 2>&1 &
ENGINE_PID=$!

API="http://127.0.0.1:$PORT/api"
PASS=0; FAILS=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL  $1"; FAILS=$((FAILS+1)); }

# Wait for the engine to run.
for _ in $(seq 1 60); do
  if curl -sf "$API/status" 2>/dev/null | jq -e '.running == true' >/dev/null 2>&1; then break; fi
  sleep 0.5
done
STATUS=$(curl -sf "$API/status" 2>/dev/null)
if [ -z "$STATUS" ]; then
  echo "FAIL: control server did not come up. Engine log:"; tail -20 "$LOG"; exit 2
fi
echo "[smoke] status: $(echo "$STATUS" | jq -c '{running, sampleRateHz, sourceMode, outputMode, restartPending}')"
echo "$STATUS" | jq -r '.notes[]?' | sed 's/^/  note: /'
if echo "$STATUS" | jq -e '.running == true' >/dev/null; then ok "engine running on the device"; else fail "engine not running"; tail -20 "$LOG"; fi
DEVS=$(curl -sf "$API/devices")
SEL_OUT=$(echo "$DEVS" | jq -r '.selectedOutput')
OUT_NAME=$(echo "$DEVS" | jq -r --arg u "$SEL_OUT" '.outputs[] | select(.id == $u) | .name')
if [ "$SEL_OUT" = "$DEVICE_UID" ]; then ok "output device is $OUT_NAME ($SEL_OUT)"; else fail "output device is '$SEL_OUT' (wanted $DEVICE_UID); available: $(echo "$DEVS" | jq -c '[.outputs[].id]')"; fi
grep -E "clamped HAL buffer|Actual render sample rate|Hardware sample rate" "$LOG" | sed 's/^/  log: /'

# Expected tone deviation from the same arithmetic as the Test Tone card.
CFG=$(curl -sf "$API/config")
read -r PILOT RDSLVL ENRDS MONO DEVKHZ LEVEL <<<"$(echo "$CFG" | jq -r '[.MPX.pilot_level, .RDS.rds_level, .RDS.en_rds, .MPX.mono_mode, .MPX.mpx_deviation_khz, .MPX.test_tone_level_db] | @tsv' 2>/dev/null | tr '\t' ' ')"
if [ -z "${DEVKHZ:-}" ]; then
  # /api/config may be flat; fall back to the INI values.
  PILOT=$(grep -E "^pilot_level" "$TMP_INI" | awk -F= '{print $2}' | tr -d ' ')
  RDSLVL=$(grep -E "^rds_level" "$TMP_INI" | awk -F= '{print $2}' | tr -d ' ')
  ENRDS=$(grep -E "^en_rds" "$TMP_INI" | awk -F= '{print $2}' | tr -d ' ')
  MONO=$(grep -E "^mono_mode" "$TMP_INI" | awk -F= '{print $2}' | tr -d ' ')
  DEVKHZ=$(grep -E "^mpx_deviation_khz" "$TMP_INI" | awk -F= '{print $2}' | tr -d ' ')
  LEVEL=-12.0
fi
EXPECT=$(python3 -c "
pilot=float('${PILOT:-0.08}'); rds=float('${RDSLVL:-2.0}'); enrds='${ENRDS:-True}'.lower() in ('true','1','yes','on'); mono='${MONO:-False}'.lower() in ('true','1','yes','on')
dev=float('${DEVKHZ:-75}'); level=float('${LEVEL:--12}')
rdsamp = rds/75.0 if (enrds and not mono) else 0.0
pil = 0.0 if mono else pilot
budget = max(0.0, 0.98 - pil - rdsamp - 0.02)
audio = dev*budget*10**(level/20.0)
print(f'{audio:.2f} {dev*(pil+rdsamp):.2f} {audio+dev*(pil+rdsamp):.2f} {pil*100:.2f}')")
read -r EXP_AUDIO EXP_SUB EXP_TOTAL EXP_PILOT <<<"$EXPECT"
echo "[smoke] expected tone: audio ${EXP_AUDIO} kHz + pilot/RDS ${EXP_SUB} kHz = ${EXP_TOTAL} kHz peak; pilot ${EXP_PILOT}%"

# Settle, then sample telemetry.
sleep 3
MAXDEV=0; MAXCLIP=0; PILOTREAD=0; XR=0; OVER=false
for _ in $(seq 1 8); do
  M=$(curl -sf "$API/meters")
  D=$(echo "$M" | jq -r '.deviationKHzPeak // 0'); C=$(echo "$M" | jq -r '.safetyClipDB // 0')
  PILOTREAD=$(echo "$M" | jq -r '.pilotInjectionPercent // 0')
  X=$(echo "$M" | jq -r '(.renderXruns // 0) + (.captureXruns // 0)')
  O=$(echo "$M" | jq -r '.compositeOverBudget // false')
  MAXDEV=$(python3 -c "print(max($MAXDEV,$D))"); MAXCLIP=$(python3 -c "print(max($MAXCLIP,$C))")
  XR=$(python3 -c "print(max($XR,$X))"); [ "$O" = "true" ] && OVER=true
  sleep 0.5
done
echo "[smoke] measured: peak deviation ${MAXDEV} kHz, safetyClip ${MAXCLIP} dB, pilot ${PILOTREAD}%, xruns ${XR}, overBudget ${OVER}"
python3 -c "import sys; sys.exit(0 if abs($MAXDEV-$EXP_TOTAL) <= 1.5 else 1)" && ok "tone deviation ${MAXDEV} kHz within 1.5 kHz of expected ${EXP_TOTAL}" || fail "tone deviation ${MAXDEV} kHz vs expected ${EXP_TOTAL} kHz"
python3 -c "import sys; sys.exit(0 if $MAXCLIP <= 0.05 else 1)" && ok "Safety Clip idle (${MAXCLIP} dB)" || fail "Safety Clip active: ${MAXCLIP} dB (the 1x soft clip is doing peak control)"
python3 -c "import sys; sys.exit(0 if abs($PILOTREAD-$EXP_PILOT) <= 0.05 else 1)" && ok "pilot ${PILOTREAD}%" || fail "pilot ${PILOTREAD}% (expected ${EXP_PILOT})"
[ "$XR" = "0" ] && ok "no xruns" || fail "$XR xruns"
[ "$OVER" = "false" ] && ok "composite within budget" || fail "composite over budget"

# Live-apply: drop the tone 8 dB and expect the deviation to follow.
R=$(curl -sf -X PATCH -H 'Content-Type: application/json' -d '{"test_tone_level_db":"-20"}' "$API/config")
echo "[smoke] PATCH tone -20 dB -> $(echo "$R" | jq -c '{appliedLive, restartPending, outcomes: [.outcomes[]? | {key, disposition}]}')"
echo "$R" | jq -e '.appliedLive == true and .restartPending == false' >/dev/null && ok "live-apply reported live" || fail "live-apply not reported live"
# Sample for 6 s after the patch: the meter is a decaying peak hold (0.47/s),
# so the reading must settle onto the new level within a couple of seconds.
TRACE=""
for _ in $(seq 1 12); do sleep 0.5; TRACE="$TRACE $(curl -sf "$API/meters" | jq -r '.deviationKHzPeak // 0 | . * 10 | round / 10')"; done
D2=$(echo "$TRACE" | awk '{print $NF}')
echo "[smoke] deviation trace after patch (0.5 s steps):$TRACE"
EXP2=$(python3 -c "print(round(${EXP_AUDIO}*10**(-8/20.0)+${EXP_SUB},2))")
python3 -c "import sys; sys.exit(0 if abs($D2-$EXP2) <= 1.5 else 1)" && ok "deviation followed live patch (${D2} kHz, expected ${EXP2} kHz)" || fail "deviation after live patch ${D2} kHz vs expected ${EXP2} kHz -- live-apply of the tone level did not reach the running generator"

# Restart-class: final limiter look-ahead, then transport restart.
R=$(curl -sf -X PATCH -H 'Content-Type: application/json' -d '{"limit_lookahead_ms":"6.0"}' "$API/config")
echo "[smoke] PATCH limit_lookahead_ms 6 -> $(echo "$R" | jq -c '{appliedLive, restartPending, outcomes: [.outcomes[]? | {key, disposition}]}')"
echo "$R" | jq -e '.restartPending == true' >/dev/null && ok "restart-class change reported pending" || fail "restart-class change not reported pending"
S=$(curl -sf -X POST "$API/transport/restart")
for _ in $(seq 1 30); do
  S=$(curl -sf "$API/status"); echo "$S" | jq -e '.running == true and .restartPending == false' >/dev/null 2>&1 && break; sleep 0.5
done
echo "$S" | jq -e '.running == true and .restartPending == false' >/dev/null && ok "transport restart cleared pending and is running" || fail "restart: $(echo "$S" | jq -c '{running, restartPending}')"
sleep 2
M=$(curl -sf "$API/meters"); echo "[smoke] after restart: $(echo "$M" | jq -c '{deviationKHzPeak, safetyClipDB, pilotInjectionPercent}')"

curl -sf -X POST "$API/transport/stop" >/dev/null
echo
echo "[smoke] engine log tail:"; grep -vE "^\[NowPlaying\]" "$LOG" | tail -8 | sed 's/^/  /'
echo
if [ "$FAILS" -eq 0 ]; then echo "SMOKE PASS ($PASS checks) -- $WORK"; exit 0; else echo "SMOKE FAIL ($FAILS failed, $PASS passed) -- see $LOG"; exit 1; fi
