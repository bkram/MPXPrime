#!/bin/zsh
emulate -L zsh

# Now-playing extractor for Cog (https://github.com/losnoco/cog), the
# counterpart to scripts/vlc-nowplaying.sh. Cog ships an AppleScript
# dictionary (Cog.sdef) exposing `currentEntry` -> playlistentry with
# `artist` / `title` / `album` / `url`, so no patching of Cog is needed.
#
# Output contract (consumed by NowPlayingSupport.swift): key=value lines on
# stdout, exit 1 when there is nothing to report. Recognised keys are
# `display`, `artist`, `title` (and `now_playing` as an alias of display).
#   display=<Artist - Title, or Title alone>
#   artist=<artist>     (printed only when non-empty)
#   title=<title>
#
# Never launches Cog: the pgrep gate below is a pure process check (no Apple
# events), so when Cog is not running the script reports nothing and exits 1.
# `application "Cog" is running` is NOT used because, on some macOS versions,
# resolving the application reference can start the app. The AppleScript
# `tell` is reached only when Cog is already running.
#
# Play state: Cog's dictionary has no `playing` boolean, so this reports
# whatever entry is current -- including paused. Cog clears the current entry
# on Stop, so a stopped player reports nothing (exit 1).

if ! pgrep -x Cog >/dev/null 2>&1; then
  exit 1
fi

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

# Pull artist + title in one round-trip, tab-delimited. Each property is read
# inline off `currentEntry` -- storing it in a variable and re-referencing it
# fails with AppleEvent error -10000, since Cog hands back a fresh specifier
# per call. Each read has its own try so a missing tag (or nothing loaded)
# yields an empty field instead of aborting the fetch.
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

if [[ -z "$fields" ]]; then
  exit 1
fi

artist="${fields%%$'\t'*}"
title="${fields#*$'\t'}"

# Strip stray CR and surrounding whitespace.
artist="${artist//$'\r'/}"
title="${title//$'\r'/}"
artist="${artist## }"; artist="${artist%% }"
title="${title## }"; title="${title%% }"

# Untagged files: fall back to the URL's basename (without extension).
if [[ -z "$title" ]]; then
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

if [[ -z "$artist" && -z "$title" ]]; then
  exit 1
fi

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
