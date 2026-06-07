#!/bin/zsh
emulate -L zsh

# Now-playing extractor for VLC. Output contract (NowPlayingSupport.swift):
# key=value lines on stdout, exit 1 when there is nothing to report.
#   display=<full track text>
#   artist=<artist>   (when the track text splits on " - ")
#   title=<title>
#
# Never launches VLC: the pgrep gate is a pure process check (no Apple
# events), so when VLC is not running the script reports nothing and exits 1.
# The AppleScript `tell` blocks run only when VLC is already running.

# Strip parenthetical suffixes like "(Radio Edit)" / "(feat. X)" from the title --
# they often push the RDS RadioText / PS over length. On by default; set
# STRIP_TITLE_PARENS=0 in the environment to keep the full title.
STRIP_TITLE_PARENS=${STRIP_TITLE_PARENS:-1}
strip_parens() {
  if [[ "$STRIP_TITLE_PARENS" != 1 ]]; then
    print -r -- "$1"
    return
  fi
  local out
  out=$(print -r -- "$1" | sed -E 's/[[:space:]]*\([^()]*\)//g')
  out="${out## }"
  out="${out%% }"
  # Keep the original if the title was entirely parenthetical.
  if [[ -n "$out" ]]; then
    print -r -- "$out"
  else
    print -r -- "$1"
  fi
}

if ! pgrep -x VLC >/dev/null 2>&1; then
  exit 1
fi

is_playing=$(
osascript 2>/dev/null <<'EOF'
tell application "VLC"
	try
		if playing then return "1"
		return "0"
	on error
		return ""
	end try
end tell
EOF
)

if [[ "$is_playing" != "1" ]]; then
  exit 1
fi

track=$(
osascript 2>/dev/null <<'EOF'
tell application "VLC"
	try
		return name of current item
	on error
		return ""
	end try
end tell
EOF
)

if [[ -z "$track" ]]; then
  track=$(
osascript 2>/dev/null <<'EOF'
tell application "System Events"
	if not (exists process "VLC") then return ""
	tell process "VLC"
		try
			return name of front window
		on error
			return ""
		end try
	end tell
end tell
EOF
  )
fi

track="${track//$'\r'/}"
track="${track//$'\n'/ }"
track="${track## }"
track="${track%% }"
track="${track% - VLC media player}"
track="${track% — VLC media player}"
track="${track% - VLC}"
track="${track% — VLC}"

if [[ -z "$track" ]]; then
  exit 1
fi

artist=""
title="$track"

if [[ "$track" == *" - "* ]]; then
  artist="${track%% - *}"
  title="${track#* - }"
elif [[ "$track" == *" – "* ]]; then
  # Some tags use an en dash (U+2013) as the artist/title separator.
  artist="${track%% – *}"
  title="${track#* – }"
fi

artist="${artist## }"
artist="${artist%% }"
title="${title## }"
title="${title%% }"
title=$(strip_parens "$title")

if [[ -n "$artist" ]]; then
  display="$artist - $title"
else
  display="$title"
fi

print -r -- "display=$display"
if [[ -n "$artist" ]]; then
  print -r -- "artist=$artist"
fi
if [[ -n "$title" ]]; then
  print -r -- "title=$title"
fi
