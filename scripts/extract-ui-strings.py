#!/usr/bin/env python3
"""Extract operator-facing string literals from the Swift UI sources for proofreading.

Usage: scripts/extract-ui-strings.py [out.txt]      (from the repo root)

Pulls the literals that reach a human -- SwiftUI `Text("...")`, `.help("...")`,
`Label("...`, `Button("...`, `Toggle("...`, `Picker("...`, `Section("...`,
`title:` / `summary:` / `helpText` / `caption` arguments and `description:` in
the preset / navigation tables -- one per line, deduplicated, with the source
file in a trailing comment, so `scripts/check-english.sh` can run LanguageTool
over them. Format specifiers (`%.1f`, `\\(x)`) are replaced by `X` so the
grammar checker sees a word, not a token.
"""
import pathlib
import re
import sys

ROOTS = [
    "macOS/Sources/MPXPrime/UI",
    "macOS/Sources/MPXPrime/MPXPrimeViewModel.swift",
    "macOS/Sources/MPXPrime/AppDelegate.swift",
    "macOS/Sources/MPXPrime/UIBroadcastStatusBar.swift",
    "macOS/Sources/MPXPrime/UISignalFlowStrip.swift",
    "macOS/Sources/MPXPrime/UIInspector.swift",
    "macOS/Sources/MPXPrime/UIProcessingOverview.swift",
    "macOS/Sources/MPXPrime/Control/PresetCatalog.swift",
    "macOS/Sources/MPXPrime/Control/WebUI/schema.json",
    "macOS/Sources/MPXPrimeMeter",
    "macOS/Sources/MPXPrimeUI",
]
CALLS = r"(?:Text|Label|Button|Toggle|Picker|Section|Stepper|TextField|Menu|Tab|NavigationLink|help|accessibilityLabel|accessibilityHint|GroupBox|DisclosureGroup)"
PATTERNS = [
    re.compile(r"\." + CALLS + r"\(\s*\"((?:[^\"\\]|\\.){3,})\""),
    re.compile(r"\b" + CALLS + r"\(\s*\"((?:[^\"\\]|\\.){3,})\""),
    re.compile(r"\b(?:title|summary|helpText|caption|description|subtitle|placeholder|message|label|prompt|hint|note)\s*[:=]\s*\"((?:[^\"\\]|\\.){3,})\""),
    re.compile(r"\"(?:title|help|label|caption|description)\"\s*:\s*\"((?:[^\"\\]|\\.){3,})\""),  # schema.json
]
SKIP = re.compile(r"^[A-Za-z0-9_.:/%-]+$|^[^A-Za-z]*$|^\w+\.\w+")  # identifiers, keys, paths, numbers


def literals(path: pathlib.Path):
    text = path.read_text(encoding="utf-8", errors="replace")
    for pat in PATTERNS:
        for m in pat.finditer(text):
            s = m.group(1)
            s = re.sub(r"\\\((?:[^()]|\([^()]*\))*\)", "X", s)  # \(interpolation)
            s = re.sub(r"%[-+ 0#]*\d*(?:\.\d+)?[a-zA-Z@]", "X", s)  # %.1f
            s = s.replace('\\"', '"').replace("\\n", " ").strip()
            if len(s) < 3 or SKIP.match(s) or " " not in s and len(s) < 12:
                continue
            yield s


def main() -> int:
    out = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else None
    seen = {}
    for root in ROOTS:
        p = pathlib.Path(root)
        files = [p] if p.is_file() else sorted(p.rglob("*.swift")) + sorted(p.rglob("*.json")) if p.exists() else []
        for f in files:
            for s in literals(f):
                seen.setdefault(s, str(f))
    lines = [f"{s}    # {src}" for s, src in sorted(seen.items(), key=lambda kv: kv[1])]
    body = "\n".join(lines) + "\n"
    if out:
        out.write_text(body, encoding="utf-8")
        print(f"{len(lines)} strings -> {out}")
    else:
        sys.stdout.write(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
