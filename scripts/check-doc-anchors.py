#!/usr/bin/env python3
"""Check every intra-repo Markdown link and heading anchor.

Usage: scripts/check-doc-anchors.py            (from the repo root; scans all tracked .md files)
Exit 1 when a relative link points at a missing file or a heading anchor that
does not exist in the target file. Anchors follow GitHub's slug rules
(lowercase, punctuation dropped, spaces -> hyphens, duplicates suffixed -1, -2).
Run it after renaming a heading or normalizing punctuation in one.
"""
import re, sys, pathlib, unicodedata
import subprocess
files = [f for f in subprocess.run(["git", "ls-files", "*.md", "**/*.md"], capture_output=True, text=True).stdout.split("\n") if f]
def slug(h):
    h = h.strip().lower()
    h = re.sub(r"[^\w\- ]", "", h)      # GitHub: drop punctuation except hyphen/space (unicode word chars kept)
    return h.replace(" ", "-")
heads = {}
for f in files:
    p = pathlib.Path(f)
    if not p.exists(): continue
    text = p.read_text(encoding="utf-8")
    seen = {}
    slugs = set()
    infence = False
    for line in text.splitlines():
        if line.startswith("```"): infence = not infence; continue
        if infence: continue
        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            s = slug(re.sub(r"`", "", m.group(2)))
            n = seen.get(s, 0); seen[s] = n + 1
            slugs.add(s if n == 0 else f"{s}-{n}")
    heads[f] = slugs
bad = 0
for f in files:
    p = pathlib.Path(f)
    if not p.exists(): continue
    text = p.read_text(encoding="utf-8")
    for m in re.finditer(r"\]\(([^)\s]+?)(?:#([^)\s]+))?\)", text):
        target, anchor = m.group(1), m.group(2)
        if target.startswith("http") or target.startswith("mailto"): continue
        if target.startswith("#"):
            anchor = target[1:]; tf = f
        else:
            tf = str((p.parent / target).resolve().relative_to(pathlib.Path.cwd())) if not target.startswith("/") else target
            if not pathlib.Path(tf).exists():
                print(f"MISSING FILE {f}: {target}"); bad += 1; continue
            if anchor is None: continue
        if tf not in heads: continue
        if anchor not in heads[tf]:
            print(f"BAD ANCHOR {f}: {target or ''}#{anchor}"); bad += 1
print("anchor problems:", bad)
sys.exit(1 if bad else 0)
