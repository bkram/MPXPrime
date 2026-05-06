#!/bin/zsh

is_playing=$(
osascript <<'EOF' 2>/dev/null
if application "VLC" is not running then return "0"
tell application "VLC"
	try
		if playing then
			return "1"
		end if
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
osascript <<'EOF' 2>/dev/null
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
osascript <<'EOF' 2>/dev/null
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
  artist="${track%% – *}"
  title="${track#* – }"
fi

artist="${artist## }"
artist="${artist%% }"
title="${title## }"
title="${title%% }"

print -- "display=$track"
if [[ -n "$artist" ]]; then
  print -- "artist=$artist"
fi
if [[ -n "$title" ]]; then
  print -- "title=$title"
fi
