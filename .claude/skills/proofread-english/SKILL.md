---
name: proofread-english
description: Proofread the English in the docs and in the apps' operator-facing strings (SwiftUI labels, tooltips, help text, preset summaries, dashboard schema titles) with LanguageTool, filtered through the project dictionary. Use before a release, after writing or rewriting manual sections, or when asked to check grammar / spelling / wording.
---

# Perfect English in the docs and the apps

Grammar and spelling are checked with **LanguageTool** (the Java grammar
checker; `brew install languagetool`, Java comes with it) through
`scripts/check-english.sh`, which strips Markdown down to prose, disables the
rules that only fire on technical layout, and drops spelling hits on words
in `scripts/english-dictionary.txt` (the project vocabulary: MPX, RDS, dBFS,
PrimeBass, ...).

This check is **not** part of CI and never blocks a commit or a release: it
reports style opinions alongside real errors, so a human decides. CI enforces
only the mechanical doc rules (see the `markdown-lint` skill).

## Commands (repo root)

```bash
scripts/check-english.sh docs/studio-operator-guide.md README.md   # one or more Markdown files
scripts/check-english.sh --ui                       # the apps' operator-facing strings
scripts/check-english.sh --all                      # every tracked .md plus the UI strings
python3 scripts/extract-ui-strings.py               # see exactly which strings --ui reads (one per line, source file as comment)
```

Output is one line per finding: `file:line:col [RULE] message | 'flagged' -> suggestion`,
then a count. Exit 1 while findings remain. The `--ui` line numbers refer to
the extractor's output; the trailing comment there names the Swift / JSON file.

## What to do with findings

- **Fix real errors** (agreement, tense, missing article, doubled word,
  misspelling) in the source file, not in the extracted text.
- **Extend the dictionary** only for genuine project or broadcast terms
  (a unit, a product, a standard). A real typo never goes into the
  dictionary to make the report green; if a term is a one-off, reword.
- **Disable a rule** (the `DISABLED` list in the script) only when it fires
  on layout the house style requires: ASCII `--` and `->` (DASH_RULE,
  ARROWS), straight quotes (EN_QUOTES), repeated spaces in aligned tables
  (WHITESPACE_RULE). Never disable grammar rules to silence a finding.
- **Ignore judgement calls** LanguageTool gets wrong for technical prose
  (comma before "so" in a long compound sentence, sentence starts with a
  code word) after reading the sentence yourself; do not rewrite good text
  to satisfy a style suggestion.

## House style the checker cannot judge (apply while fixing)

- **Outcome language on labels, jargon in tooltips** (AGENTS.md "UI/UX"):
  a control says what it does for the signal ("Protect Stereo Pilot"),
  the mechanism (topology, patent, filter order) goes into `.help()`.
  Keep established broadcast terms (pre-emphasis, pilot, RDS, deviation).
- **One vocabulary across the GUI, the web dashboard and the manual**: the
  manual quotes GUI labels verbatim in backticks; if a label changes, the
  manual, `schema.json` titles and the inspector change with it.
- **Units and numbers**: `dBFS`, `dB`, `kHz`, `us` (ASCII, no micro sign),
  `+/-`, a space between number and unit, ranges with `..` in INI context
  and `-` in prose.
- **Tone**: plain, declarative, second person for operator instructions
  ("set", "pick", "watch"), no marketing adjectives, no exclamation marks.
- **ASCII only** everywhere (see the `markdown-lint` skill); LanguageTool's
  typographic-quote suggestions are disabled for that reason.

## Dialect

The checker runs `en-US`, so British spellings (`programme` outside the RDS
term, `centre`, `artefact`, `neighbours`, `afterwards`) are reported as
spelling findings. The docs are currently mixed; pick one dialect per file
when you touch it and prefer American in new text. `Programme Type` stays:
it is the EN 50067 term and is in the dictionary.

## Workflow

1. `scripts/check-english.sh <the files you changed>` (or `--ui` after a UI
   string change).
2. Fix, re-run until `0 finding(s)` or every remaining line is a reviewed
   false positive you can name.
3. Docs edits then go through the `markdown-lint` skill; UI string edits
   through `swiftlint` and the manual's matching label text.
