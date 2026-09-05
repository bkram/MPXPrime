#!/usr/bin/env bash
# Proofread English in the docs and the app's operator-facing strings with
# LanguageTool (brew install languagetool; Java). Used by the
# `proofread-english` skill (.claude/skills/proofread-english).
#
#   scripts/check-english.sh docs/studio-operator-guide.md README.md      # Markdown files
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
        --all) mode_ui=1; while IFS= read -r f; do files+=("$f"); done < <(git ls-files '*.md' '**/*.md' | grep -vE '^standards/|^tuner/build') ;;
        *) files+=("$a") ;;
    esac
done
[ ${#files[@]} -eq 0 ] && [ $mode_ui -eq 0 ] && { sed -n '2,12p' "$0"; exit 2; }

strip_markdown() {  # $1 in, $2 out -- LINE-PRESERVING, so findings map to source lines
    python3 - "$1" "$2" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
out, in_fence = [], False
for line in lines:
    if line.lstrip().startswith("```"):          # fenced code: blank it, keep the line
        in_fence = not in_fence
        out.append("")
        continue
    if in_fence:
        out.append("")
        continue
    s = line
    s = re.sub(r"`[^`]*`", " CODE ", s)           # inline code -> a real word, spaced
    s = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", s)      # images
    s = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", s)  # links -> their text
    s = re.sub(r"https?://\S+", "URL", s)
    if re.match(r"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$", s):
        s = ""                                    # table rule rows
    s = re.sub(r"^\s*#{1,6}\s+", "", s)           # heading markers
    s = re.sub(r"^\s*[-*+]\s+", "", s)            # bullets
    s = re.sub(r"^\s*\d+\.\s+", "", s)           # numbered lists
    s = re.sub(r"[*_]{1,3}([^*_]+)[*_]{1,3}", r"\1", s)   # emphasis
    s = re.sub(r"<!--.*?-->", "", s)
    out.append(s.replace("|", " "))
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(out))
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
