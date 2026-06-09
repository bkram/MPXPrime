#!/bin/zsh
emulate -L zsh

# Unified now-playing extractor for MPX Prime. Auto-detects the running player
# (VLC first, then Cog) and prints the metadata for the RDS Radiotext poller.
# Replaces the old per-player vlc-nowplaying.sh / cog-nowplaying.sh: the shared
# logic (title cleanup, artist/title split, output) is written once here; only the
# per-player metadata fetch differs.
#
# Output contract (NowPlayingSupport.swift): key=value lines on stdout, exit 1 when
# there is nothing to report.
#   display=<full track text>   artist=<artist>   title=<title>
#
# Never launches a player: each fetch is gated by a pgrep process check (no Apple
# events) before any `tell`, so a player that is not running is skipped silently.
# VLC reports only while actually playing; Cog has no play-state in its dictionary,
# so it reports the current entry even when paused (it clears the entry on Stop).

# ---- shared: title cleanup -----------------------------------------------------
# Strip parenthetical "(Radio Edit)" / "(feat. X)" and bracketed "[Official Video]"
# decorations from the title -- they routinely push the RDS RadioText / PS over
# length. Both on by default; set STRIP_TITLE_PARENS=0 and/or STRIP_TITLE_BRACKETS=0
# in the environment to keep them.
STRIP_TITLE_PARENS=${STRIP_TITLE_PARENS:-1}
STRIP_TITLE_BRACKETS=${STRIP_TITLE_BRACKETS:-1}

clean_title() {
  local out="$1"
  [[ "$STRIP_TITLE_PARENS" == 1 ]] && out=$(print -r -- "$out" | sed -E 's/[[:space:]]*\([^()]*\)//g')
  [[ "$STRIP_TITLE_BRACKETS" == 1 ]] && out=$(print -r -- "$out" | sed -E 's/[[:space:]]*\[[^][]*\]//g')
  out="${out## }"
  out="${out%% }"
  # Keep the original if stripping emptied the title.
  if [[ -n "$out" ]]; then
    print -r -- "$out"
  else
    print -r -- "$1"
  fi
}

# Strip stray CR and surrounding whitespace.
trim() {
  local s="${1//$'\r'/}"
  s="${s## }"
  s="${s%% }"
  print -r -- "$s"
}

# ---- shared: output emitter ----------------------------------------------------
# emit <artist> <title>: cleans the title, builds `display`, prints the key=value
# lines, and exits 0. Returns 1 (no exit) if there is no usable metadata, so the
# caller can fall through to the next player.
emit() {
  local artist title_clean display
  artist=$(trim "$1")
  title_clean=$(clean_title "$(trim "$2")")
  if [[ -z "$artist" && -z "$title_clean" ]]; then
    return 1
  fi
  if [[ -n "$artist" ]]; then
    display="$artist - $title_clean"
  else
    display="$title_clean"
  fi
  print -r -- "display=$display"
  [[ -n "$artist" ]] && print -r -- "artist=$artist"
  [[ -n "$title_clean" ]] && print -r -- "title=$title_clean"
  exit 0
}

# ---- per-player fetch ----------------------------------------------------------
try_vlc() {
  pgrep -x VLC >/dev/null 2>&1 || return 1

  local playing track artist title
  playing=$(
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
  [[ "$playing" == "1" ]] || return 1

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

  track="${track//$'\n'/ }"
  track=$(trim "$track")
  track="${track% - VLC media player}"
  track="${track% — VLC media player}"
  track="${track% - VLC}"
  track="${track% — VLC}"
  track=$(trim "$track")
  [[ -z "$track" ]] && return 1

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
  emit "$artist" "$title"
}

try_cog() {
  pgrep -x Cog >/dev/null 2>&1 || return 1

  # Each property is read inline off `currentEntry`; storing it in a variable and
  # re-referencing fails with AppleEvent -10000 (Cog hands back a fresh specifier
  # per call). Each read has its own try so a missing tag yields an empty field.
  local fields artist title url base
  fields=$(
osascript 2>/dev/null <<'EOF'
tell application "Cog"
	set theArtist to ""
	set theTitle to ""
	try
		set theTitle to (title of currentEntry) as text
	end try
	try
		set theArtist to (artist of currentEntry) as text
	end try
	return theArtist & tab & theTitle
end tell
EOF
  )
  [[ -z "$fields" ]] && return 1

  artist="${fields%%$'\t'*}"
  title="${fields#*$'\t'}"

  # Untagged files: fall back to the URL's basename (without extension).
  if [[ -z "$(trim "$title")" ]]; then
    url=$(
osascript 2>/dev/null <<'EOF'
tell application "Cog"
	try
		return (url of currentEntry) as text
	on error
		return ""
	end try
end tell
EOF
    )
    if [[ -n "$url" ]]; then
      base="${url##*/}"
      title="${base%.*}"
      title="${title//%20/ }"
    fi
  fi
  emit "$artist" "$title"
}

try_vlc
try_cog
exit 1
