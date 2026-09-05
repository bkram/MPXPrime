---
name: markdown-lint
description: Write or fix Markdown so it passes markdownlint (markdownlint-cli2) with this repo's config, keeps the ASCII-only house rule, and keeps every intra-doc link and heading anchor valid. Use after editing any .md file, before committing docs, or when asked to lint / clean up Markdown.
---

# Markdown that passes markdownlint

The repo lints every tracked `.md` with `markdownlint-cli2`; the config is
`.markdownlint-cli2.jsonc` at the repo root (all rules on, except MD013
line-length off, MD024 duplicate headings only among siblings, MD060 table
cell padding off). CI fails on findings, so a doc change is not done until
the three commands below are clean.

## Commands (repo root)

```bash
npx --yes markdownlint-cli2                 # lint every tracked .md (uses the repo config + globs)
npx --yes markdownlint-cli2 --fix           # auto-fix blank lines around headings / lists / fences, list markers, trailing spaces
npx --yes markdownlint-cli2 docs/manual.md  # one file
python3 scripts/check-doc-anchors.py        # every relative link + #anchor resolves (GitHub slug rules)
```

`--fix` never changes meaning; run it first, then fix what remains by hand,
then re-run both checks. Node comes from Homebrew (`brew install node`);
`npx --yes` fetches markdownlint-cli2 on demand, nothing is installed in the repo.

## Rules that matter here and how to satisfy them

- **MD040 fenced code language**: every ``` fence names a language. Use
  `bash`, `swift`, `ini`, `json`, `text` (plain output, ASCII diagrams,
  signal-flow arrows). Never leave a bare fence.
- **MD022 / MD032 / MD031**: one blank line before and after every heading,
  list and fenced block. `--fix` handles it.
- **MD025 single H1**: one `#` title per file. Section breaks inside a file
  are `##`. Planning documents that deliberately carry several top-level
  parts start with `<!-- markdownlint-disable MD025 -->` and say why.
- **MD024 duplicate headings**: siblings may not repeat. Historical CHANGELOG
  sections that repeat `### Changed` are wrapped in
  `<!-- markdownlint-disable MD024 -->` / `<!-- markdownlint-enable MD024 -->`
  rather than rewritten; new entries get distinct headings.
- **MD036 emphasis as heading**: a bold line standing alone is a heading;
  make it one (`###`) or fold it into a sentence.
- **MD033 inline HTML**: none. Angle-bracket placeholders go in backticks:
  `` `<why>` ``. Comments (`<!-- -->`) are allowed and are how rules are
  disabled locally.
- **MD034 bare URLs**: wrap in `<...>` or make a link `[text](url)`.
- **MD004 list style**: `-` for bullets, consistently within a file.
- **MD012**: never two blank lines in a row.
- **Tables**: header row, a `|---|` rule row, same column count on every
  row; cell padding is free (MD060 off), but keep one table one style.

## House rules on top of markdownlint

- **ASCII only** (AGENTS.md). No em dashes (`--`), no arrows (`->`), no
  `x` as multiplication sign glyph, no curly quotes, no `+/-` glyph, no
  micro sign (`us`, `uV`), no box-drawing characters (`|`, `-`, `+`, `>`
  for diagrams). Check with:
  `grep -nP '[^\x00-\x7F]' file.md`. The only tolerated exceptions are
  literal non-ASCII examples that a passage is ABOUT (RDS character-set
  samples in the CHANGELOG).
- **Anchors**: headings are link targets. Renaming or re-punctuating a
  heading changes its slug; run `scripts/check-doc-anchors.py` after any
  heading edit. Slug = lowercase, punctuation dropped, spaces to `-`,
  duplicates suffixed `-1`, `-2`.
- **Code references in prose**: file names, INI keys, flags, symbols in
  backticks; commands and error text in fenced blocks.
- **One source of truth**: the manuals describe behaviour, ARCHITECTURE the
  mechanism, README the product, AGENTS the conventions; do not duplicate a
  paragraph across them, link instead.
- **Docs move with code** (AGENTS.md "After ANY change, update ALL affected
  docs"): run this skill's checks on every doc a code change touched, in
  the same commit.

## Workflow

1. Edit.
2. `npx --yes markdownlint-cli2 --fix <files>` then `npx --yes markdownlint-cli2 <files>`.
3. `grep -nP '[^\x00-\x7F]' <files>` -> empty.
4. `python3 scripts/check-doc-anchors.py` -> `anchor problems: 0`.
5. If the text is user-facing prose, also run the `proofread-english` skill.
