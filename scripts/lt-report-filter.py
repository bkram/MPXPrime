#!/usr/bin/env python3
"""Filter LanguageTool's command-line report (stdin) into one line per finding.

Usage: languagetool -l en-US file.txt 2>&1 | scripts/lt-report-filter.py <label> scripts/english-dictionary.txt

Drops spelling findings whose flagged word is in the dictionary (or is the
CODE / URL placeholder the Markdown stripper inserts). Prints
`label:line:col [RULE] message | 'flagged' -> suggestion` and a count; exits 1
when findings remain. Called by scripts/check-english.sh.
"""
import re
import sys

label, dictpath = sys.argv[1], sys.argv[2]
# Optional 3rd arg: line stride of the checked text (2 when every string was
# separated by a blank line) so reported lines map back to the source list.
stride = int(sys.argv[3]) if len(sys.argv) > 3 else 1
words = {l.strip().lower() for l in open(dictpath, encoding="utf-8") if l.strip() and not l.startswith("#")}
raw = sys.stdin.read()
count = 0
for block in re.split(r"\n(?=\d+\.\) Line )", raw):
    m = re.match(r"\d+\.\) Line (\d+), column (\d+), Rule ID: (\S+)", block)
    if not m:
        continue
    line, col, rule = m.groups()
    if stride > 1:
        line = str((int(line) + stride - 1) // stride)
    msg = re.search(r"Message: (.*)", block)
    msg = msg.group(1) if msg else ""
    flagged = ""
    ctx = re.search(r"\n(.*)\n(\s*)(\^+)", block)
    if ctx:
        text, lead, carets = ctx.group(1), ctx.group(2), ctx.group(3)
        flagged = text[len(lead):len(lead) + len(carets)].strip()
    if rule.startswith("MORFOLOGIK") and (
        flagged.lower() in words or flagged.lower().rstrip("s") in words or flagged in ("CODE", "URL")
        or all(part.lower() in words for part in flagged.replace("/", "-").split("-") if part)
    ):
        continue
    sug = re.search(r"Suggestion: (.*)", block)
    sug = f" -> {sug.group(1).strip()}" if sug and sug.group(1).strip() else ""
    count += 1
    print(f"{label}:{line}:{col} [{rule}] {msg} | '{flagged}'{sug}")
print(f"# {label}: {count} finding(s)")
sys.exit(1 if count else 0)
