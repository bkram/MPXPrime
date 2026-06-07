# Building from source

This document covers building, running, testing, and packaging MPX Prime from
source. If you only want to run the app, download the release DMG instead — see
the [Download](../README.md#download) section of the README.

## Requirements

- macOS 15 or later
- Swift 6 toolchain (Xcode 16+ or the matching Command Line Tools)
- For running the **test suite**: a full Xcode install (the Command Line Tools
  do not ship `Testing.framework`)

The package is a Swift Package Manager project rooted at `macOS/`. The sole
external dependency is `swift-atomics`.

## Build

Debug build:

```bash
swift build --package-path macOS
```

Release build:

```bash
swift build --package-path macOS -c release
```

> **Debug builds are not real-time capable.** `swift build` (no `-c release`)
> and `swift run` produce a debug binary without compiler optimizations. The
> audio render thread shares CPU with the main-thread UI loop, and on a debug
> build the meter / scope / spectrum work in `refreshMonitoringSnapshot` is slow
> enough to occasionally preempt the audio thread — you will hear clicks, buffer
> underruns, or input-ring overflows. Debug builds are fine for development,
> unit testing, and `--verify` runs (which do not touch real audio devices), but
> **for actual on-air or monitor playback always use a release build**: either
> `swift build --package-path macOS -c release` followed by running
> `macOS/.build/release/MPXPrime`, or use the DMG produced by `./build-release.sh`.

## Run

From the repository root:

```bash
swift run --package-path macOS MPXPrime                       # GUI
swift run --package-path macOS MPXPrime --nogui               # headless
swift run --package-path macOS MPXPrime --seconds 10          # fixed runtime
swift run --package-path macOS MPXPrime --config "/path/to/MPX Prime.ini"
```

The default user config lives at
`~/Library/Application Support/MPX Prime/MPX Prime.ini`.

## Offline verification

The verification harness renders deterministic test scenarios without opening
any audio devices, so it runs safely on a debug build:

```bash
swift run --package-path macOS MPXPrime --verify --seconds 5                  # scenario sweep
swift run --package-path macOS MPXPrime --verify-presets --seconds 5          # 5-band preset sweep
swift run --package-path macOS MPXPrime --verify-long --seconds 30            # long-run regression
swift run --package-path macOS MPXPrime --verify-receiver --seconds 5         # receiver-model decode
swift run --package-path macOS MPXPrime --verify-composite-multiband --seconds 2   # A/B multiband clipper
swift run --package-path macOS MPXPrime --verify-multiband-coupling --seconds 2    # A/B inter-band coupling
```

Baseline capture + strict compare:

```bash
swift run --package-path macOS MPXPrime --capture-baseline    # writes macOS/verifier_baselines/default.json
swift run --package-path macOS MPXPrime --verify --baseline-strict
```

Exit codes: `0` = PASS, `1` = TIGHT (near limits, review), `2` = WARN.

See the [Offline verification](../README.md#offline-verification) section of the
README for what each report field means.

## Tests

Tests use **Swift Testing** (`import Testing`, `@Test` / `#expect`) — not
XCTest. Running them requires a full Xcode install, so `DEVELOPER_DIR` must point
at Xcode (the Command Line Tools ship no `Testing.framework`):

```bash
# Full default suite (fast, ~10 s)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path macOS

# Single suite / filter
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path macOS --filter BassClipperTests
```

Optional deep DSP combination suite (~3 min; opt-in, catches stage-interaction
regressions — run before a release or when touching multiple stages):

```bash
MPXPRIME_DEEP=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path macOS --filter Deep
```

## Accessibility lint

UI changes should pass the accessibility lint before committing:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftlint
```

The project ships a `.swiftlint.yml` that runs only
`accessibility_label_for_image` and `accessibility_trait_for_button`.

## Release build and DMG

Build a universal release app bundle and DMG:

```bash
./build-release.sh 0.32
```

Artifacts are written to `macOS/dist/`.

Releases ship by merging the integration branch (`develop/v.NNN`) into `main`,
tagging `v<version>` from `main`, and pushing the tag — which triggers
`.github/workflows/release.yml`, runs `./build-release.sh <version>`, and
publishes the resulting DMG as a GitHub Release.

## See also

- [ARCHITECTURE.md](ARCHITECTURE.md) — detailed DSP chain and stage descriptions
- [`AGENTS.md`](../AGENTS.md) — full contributor / agent workflow guidance,
  conventions, and the release validation checklist
- [`plan.md`](../plan.md) — roadmap
