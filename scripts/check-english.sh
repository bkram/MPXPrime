#!/usr/bin/env bash
# Proofread English in the docs and the app's operator-facing strings with
# LanguageTool (brew install languagetool; Java). Used by the
# `proofread-english` skill (.claude/skills/proofread-english).
#
#   scripts/check-english.sh docs/manual.md README.md      # Markdown files
#   scripts/check-english.sh --ui                          # Swift/JSON UI strings
#   scripts/check-english.sh --all                         # every tracked .md + UI strings
#
# Markdown is pre-processed so the checker sees prose only: fenced code blocks,
# inline code spans, URLs, link targets, table rules and heading markers are
# removed. Findings are filtered: spelling hits on words listed in
# scripts/english-dictionary.txt are dropped, and rules that only fire on
# technical layout (repeated whitespace, typographic quotes -- the house style
# is ASCII) are disabled. Exit 1 when findings remain.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v languagetool >/dev/null || { echo "languagetool not found: brew install languagetool" >&2; exit 2; }

DISABLED="WHITESPACE_RULE,EN_QUOTES,EN_UNPAIRED_QUOTES,DASH_RULE,HYPHEN_TO_EN,UNIT_SPACE,ARROWS,EN_UNPAIRED_BRACKETS,COMMA_PARENTHESIS_WHITESPACE,CONSECUTIVE_SPACES,UPPERCASE_SENTENCE_START,ENGLISH_WORD_REPEAT_BEGINNING_RULE,SENTENCE_WHITESPACE,DOUBLE_PUNCTUATION,PUNCTUATION_PARAGRAPH_END"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mode_ui=0; files=()
for a in "$@"; do
    case "$a" in
        --ui) mode_ui=1 ;;
        --all) mode_ui=1; while IFS= read -r f; do files+=("$f"); done < <(git ls-files '*.md' '**/*.md' | grep -vE '^documents/|^tuner/build') ;;
        *) files+=("$a") ;;
    esac
done
[ ${#files[@]} -eq 0 ] && [ $mode_ui -eq 0 ] && { sed -n '2,12p' "$0"; exit 2; }

strip_markdown() {  # $1 in, $2 out
    python3 - "$1" "$2" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
text = re.sub(r"```.*?```", "", text, flags=re.S)                 # fenced code
text = re.sub(r"`[^`\n]*`", "CODE", text)                         # inline code -> placeholder word
text = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", text)                  # images
text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)              # links -> text
text = re.sub(r"https?://\S+", "URL", text)
text = re.sub(r"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$", "", text, flags=re.M)  # table rules
text = re.sub(r"^\s*#{1,6}\s+", "", text, flags=re.M)             # heading markers
text = re.sub(r"^\s*[-*+]\s+", "", text, flags=re.M)              # bullets
text = re.sub(r"^\s*\d+\.\s+", "", text, flags=re.M)              # numbered lists
text = re.sub(r"[*_]{1,3}([^*_\n]+)[*_]{1,3}", r"\1", text)       # emphasis
text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
text = text.replace("|", " ")
open(sys.argv[2], "w", encoding="utf-8").write(text)
PY
}

run_lt() {  # $1 text file, $2 label, $3 line stride (default 1)
    languagetool -l en-US --disable "$DISABLED" "$1" 2>&1 \
    | python3 scripts/lt-report-filter.py "$2" scripts/english-dictionary.txt "${3:-1}"
}

status=0
for f in "${files[@]}"; do
    strip_markdown "$f" "$WORK/prose.txt"
    run_lt "$WORK/prose.txt" "$f" || status=1
done
if [ $mode_ui -eq 1 ]; then
    python3 scripts/extract-ui-strings.py "$WORK/ui.txt" >/dev/null
    # One blank line between strings: each UI string is its own paragraph, so
    # LanguageTool never reads two adjacent labels as one repeated phrase.
    sed 's/    # .*$//' "$WORK/ui.txt" | sed G > "$WORK/ui-prose.txt"
    run_lt "$WORK/ui-prose.txt" "ui-strings" 2 || status=1
    echo "# (ui-strings line N = line N of: scripts/extract-ui-strings.py output, which names the source file)"
fi
exit $status
