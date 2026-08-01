#!/bin/zsh
emulate -L zsh
setopt pipefail

# Push the currently-playing track (VLC / Cog) to a remote MPX Prime Studio
# encoder over its REST API (POST /api/nowplaying). Runs where the player is
# (your Mac); the encoder can be anywhere reachable -- e.g. a headless mpxbox.
#
# It reuses the sibling `nowplaying.sh` for VLC/Cog metadata extraction (the
# AppleScript lives there, once), then POSTs artist/title/display so the
# encoder's RT / PS / RT+ templates fill in. Only pushes on change, so RDS
# RadioText does not thrash.
#
#   ./push-nowplaying.sh --url http://mpxbox:8737 --api-key <key>
#   MPXPRIME_URL=http://mpxbox:8737 MPXPRIME_API_KEY=<key> ./push-nowplaying.sh
#   ./push-nowplaying.sh --url ... --api-key ... --interval 5 --once
#
# On the ENCODER, enable now-playing rendering (this script only supplies the
# data): set now_playing_enabled = True, an rt_text template with macros --
# e.g.  10s:{artist} - {title}/10s:My Station  -- and leave now_playing_script
# empty (this push is the source). A "/"-segmented template gracefully shows
# the static segment when nothing is playing. RT+ is tagged automatically from
# artist/title.
#
# Flags:
#   --url URL           base URL of the encoder (env MPXPRIME_URL)
#   --api-key KEY       API key for non-local access (env MPXPRIME_API_KEY)
#   --interval N        poll seconds (default 8)
#   --once              push once and exit (no loop)
#   -h | --help

URL="${MPXPRIME_URL:-}"
API_KEY="${MPXPRIME_API_KEY:-}"
INTERVAL=8
ONCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    --api-key) API_KEY="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --once) ONCE=1; shift ;;
    -h|--help)
      sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) print -u2 "unknown option: $1"; exit 2 ;;
  esac
done

if [[ -z "$URL" ]]; then
  print -u2 "error: --url (or MPXPRIME_URL) is required, e.g. http://mpxbox:8737"
  exit 2
fi
URL="${URL%/}"

SCRIPT_DIR="${0:A:h}"
NP="$SCRIPT_DIR/nowplaying.sh"
[[ -x "$NP" ]] || { print -u2 "error: $NP not found/executable"; exit 2; }

command -v curl >/dev/null 2>&1 || { print -u2 "error: curl not found"; exit 2; }

# JSON string escaper (backslash, quote, control chars). Keeps it dependency-free.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/ }"
  s="${s//$'\n'/ }"
  s="${s//$'\r'/}"
  print -r -- "$s"
}

warned_disabled=0
last_payload="__init__"
last_push_epoch=0
# Re-send the current track at least this often even when unchanged, so the
# encoder recovers the RadioText after a restart without waiting for a track
# change.
HEARTBEAT=30

push_once() {
  local out artist title display payload code body
  # nowplaying.sh: key=value lines, exit 1 when nothing is playing.
  out=$("$NP" 2>/dev/null)
  if [[ $? -ne 0 || -z "$out" ]]; then
    artist=""; title=""; display=""
  else
    artist=$(print -r -- "$out" | sed -n 's/^artist=//p')
    title=$(print -r -- "$out"  | sed -n 's/^title=//p')
    display=$(print -r -- "$out" | sed -n 's/^display=//p')
  fi

  payload="{\"artist\":\"$(json_escape "$artist")\",\"title\":\"$(json_escape "$title")\",\"display\":\"$(json_escape "$display")\"}"

  # Send when something changed, or on the heartbeat interval (so an encoder
  # restart recovers even if the track has not changed). An empty state is
  # pushed once too, letting a "/"-segmented template fall back to its static
  # segment.
  local now_epoch
  now_epoch=$(date +%s)
  if [[ "$payload" == "$last_payload" && $((now_epoch - last_push_epoch)) -lt $HEARTBEAT ]]; then
    return 0
  fi
  last_payload="$payload"
  last_push_epoch=$now_epoch

  local -a hdr
  hdr=(-H 'Content-Type: application/json')
  [[ -n "$API_KEY" ]] && hdr+=(-H "X-API-Key: $API_KEY")

  body=$(curl -sS -m 5 -w $'\n%{http_code}' -X POST "${hdr[@]}" \
    -d "$payload" "$URL/api/nowplaying" 2>&1)
  code="${body##*$'\n'}"
  body="${body%$'\n'*}"

  if [[ "$code" != 2?? ]]; then
    print -u2 "push failed (HTTP ${code:-?}): $body"
    last_payload="__init__"   # retry next tick
    return 1
  fi

  if [[ -n "$display$artist$title" ]]; then
    print -r -- "pushed: ${display:-$artist - $title}"
  else
    print -r -- "pushed: (nothing playing -> cleared)"
  fi

  # One-time hint if the encoder has now-playing rendering off.
  if [[ "$warned_disabled" == 0 && "$body" == *'"nowPlayingEnabled":false'* ]]; then
    print -u2 "note: now-playing is DISABLED on the encoder -- pushes are stored but"
    print -u2 "      will not appear. Set now_playing_enabled=True + an rt_text template"
    print -u2 "      with {artist}/{title} (and leave now_playing_script empty)."
    warned_disabled=1
  fi
  return 0
}

if [[ "$ONCE" == 1 ]]; then
  push_once
  exit $?
fi

print -r -- "push-nowplaying: $URL every ${INTERVAL}s (VLC/Cog). Ctrl-C to stop."
while true; do
  push_once || true
  sleep "$INTERVAL"
done
