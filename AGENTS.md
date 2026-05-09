# Agent Instructions

This file is the single source of truth for AI coding agents (Claude Code, Codex, etc.) working in this repo. `CLAUDE.md` is a symlink to this file.

## Project

Native macOS FM composite (MPX) generator — real-time broadcast-style stereo encoder with RDS. Swift 6 / SwiftUI / AVAudioEngine, SPM package rooted at `macOS/`. Targets macOS 15+. Single executable target `MPXPrime`; sole external dep is `swift-atomics`.

- Primary entrypoint: `macOS/Package.swift`
- Default user config: `~/Library/Application Support/MPX Prime/MPX Prime.ini`

See also: `ARCHITECTURE.md` (detailed DSP chain and stage descriptions), `plan.md` (roadmap).

## Commands

```bash
# Build (debug / release)
swift build --package-path macOS
swift build --package-path macOS -c release

# Run
swift run --package-path macOS MPXPrime              # GUI
swift run --package-path macOS MPXPrime --nogui      # headless
swift run --package-path macOS MPXPrime --config "/path/to/MPX Prime.ini"

# Offline verification (no audio devices touched)
swift run --package-path macOS MPXPrime --verify --seconds 5
swift run --package-path macOS MPXPrime --verify-presets --seconds 5
swift run --package-path macOS MPXPrime --verify-long --seconds 30

# Baseline capture + strict compare
swift run --package-path macOS MPXPrime --capture-baseline      # writes macOS/verifier_baselines/default.json
swift run --package-path macOS MPXPrime --verify --baseline-strict

# Tests — MUST override DEVELOPER_DIR; CLT ships no Testing.framework, Xcode does.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path macOS

# Single test / filter
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path macOS --filter BassClipperTests

# Release bundle + DMG
./build-release.sh 0.21

# Optional deep DSP combination test suite (~3 min; opt-in)
MPXPRIME_DEEP=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path macOS --filter Deep
```

Verifier exit codes: `0` = PASS, `1` = TIGHT (near limits, review), `2` = WARN.

Tests use **Swift Testing** (`import Testing`, `@Test` / `#expect`) — not XCTest. Do not add XCTest-based tests.

The default `swift test` is fast (~10 s, 255 tests) and runs on every change. The optional deep suite (`DeepDSPTests.swift`, gated by `MPXPRIME_DEEP=1`) covers stage-interaction bugs: per-stage isolation, 50 random configs × 4 adversarial programs, pairwise enable/disable matrix, counteract pair detection, per-preset safety. Run on demand before a release or when touching multiple stages.

## Architecture

### Layout
- `macOS/Sources/MPXPrime/` — all runtime code (no sub-modules)
  - `main.swift` — CLI entry, arg parsing, verify-mode dispatch
  - `AppConfig.swift` — INI-backed config model + live-apply routing (`RuntimeConfig`, `RDSRuntimeConfig`)
  - `INIParser.swift`, `AudioDevices.swift` — file and CoreAudio plumbing
  - `AudioOutputEngine.swift` — AVAudioEngine lifecycle, input tap, render callback
  - `MPXGenerator.swift` (~7100 lines) — DSP core + `BasicRDSCoder`. All stages of the chain live here
  - `StereoInputRingBuffer.swift` — lock-free input → render bridge
  - `SwiftUIControlApp.swift` (~7000 lines) — SwiftUI views + view-model state
  - `UIBroadcastStatusBar.swift` / `UIBroadcastMeter.swift` / `UIBroadcastStyle.swift` — pinned-top status header, vertical meter strips, shared style tokens
  - `UISignalFlowStrip.swift` — read-only DSP-chain pill strip
  - `UIInspector.swift` — stage-aware right-pane inspector
  - `UIProcessingOverview.swift` — Processing-section landing grid (per-stage cards)
  - `VerificationHarness.swift` / `VerifierBaseline.swift` — offline scenario renderer + baseline compare
  - `NowPlayingSupport.swift` — external script polling for RDS RT metadata
- `macOS/Tests/MPXPrimeTests/` — Swift Testing suite (DSP primitives, ring buffer, analysis helpers, RDS bitstream + live-apply)
- `macOS/verifier_baselines/` — JSON baselines + `ClipperAliasingBaseline.md` documenting pre-Phase-7.1 aliasing so post-refactor deltas are attributable
- `macOS/{MPXPrime.ini,Verification.ini}` — sample configs; user config lives at `~/Library/Application Support/MPX Prime/MPX Prime.ini`
- `documents/` — standards PDFs (EN 50067 / IEC 62106-2 / IEC 62106-6 / UECP SPB 490 / ITU-R BS.450)
- `.vscode/settings.json` — sets `swift.searchSubfoldersForPackages: true` so sourcekit-lsp discovers `macOS/Package.swift` (workspace root is the repo root, package lives one level down)

### Signal chain (critical invariants)

The audio path runs ~24 stages, ending with **post-clipper pilot + RDS injection**. Anything that touches the chain order needs to preserve two non-obvious invariants:

1. **Subcarriers (19 kHz pilot, 57 kHz RDS) MUST be injected after all peak-control stages.** They bypass the composite clipper, BS.412, and final-MPX safety limiter. Constant-amplitude subcarriers are required for reliable stereo decoding and RDS reception — this matches professional broadcast practice (Omnia, Orban, Stereotool). The clipper has explicit pilot-guard (17–21 kHz) and RDS-guard (55–59 kHz) cancellation — clipping IM in those bands is removed before subcarrier injection so the receiver doesn't see clipper noise vector-summed with the cleanly-injected pilot/RDS.
2. **Pre-emphasis runs in M/S domain inside `makeCompositeComponents`**, not in L/R domain upstream of the pre-encode limiter. The relocation experiment (`b806053`) caused real-time-budget overruns and is now guarded by `DSPThroughputTests.preEmphasisDoesNotExplodeFullChainCost`.

Peak control:
- **Pre-encode audio limiter** — L/R, stereo-linked, after pre-emphasis, before stereo encoding. Uses `OversampledPeakLimiter` per channel (4× oversampled true-peak with tanh ceiling).
- **Composite clipper** — 8× oversampled tanh soft-clipper on the audio composite, with delta-based per-band substitution that protects audio (0–17 kHz, opt-in), pilot guard (17–21 kHz), stereo subcarrier (22–53 kHz), and RDS guard (55–59 kHz) bands. Replaces the old `CompositeTruePeakLimiter` (deleted in 0.11) which used `|composite|` peak detection + memoryless tanh and produced intermod that demodulated as `(L-R)` cancellation. Inspired by Orban US 4,460,871 / 5,737,434 (expired).

`Mono Mode` suppresses pilot, stereo subcarrier, and RDS — true mono composite.

Oversampled clippers (BassClipper 4×, DistortionCancelledClipper 8×, CompositeClipper 8×) share a `Lagrange4Interp` + `BiquadCascade6` pattern (12th-order Butterworth decimation LP). Soft-clip `tanhf` calls inside these clippers are batched through `vvtanhf` (vForce SIMD) for ~5–9× speedup vs scalar tanhf at 8/16-element batches — see `TanhBatchSizeBench` for the curve. Follow these patterns for any new oversampled nonlinearity.

The multiband compressor has two crossover backends, picked at engine start by output mode:
- **TX path** uses `LinearPhaseMultibandSplitter5` / `3` — Kaiser-windowed-sinc FIR splitters with parallel-cumulative-LP topology, all bands sharing group delay so summed bands reconstruct the input delayed-by-`groupDelaySamples` exactly (sum-to-flat at –155 dB). Eliminates IIR-LR4's transient smear and inter-band pumping. ~5.3 ms latency at 192 kHz with the default 90 Hz lowest crossover. Convolution runs through `vDSP_dotpr` (double-buffered delay line) — without that the FIR path overruns real-time budget on most machines (manifests as audio crackle + RDS BCH corruption from sample dropouts).
- **Monitor path** keeps the IIR `StereoLinkwitzRiley4` chain for low latency.

RDS baseband uses EN 50067 biphase shaping and a pilot-locked subcarrier. RDS carrier frequency is config-only; the UI exposes carrier level and program data.

### Configuration + live-apply

`AppConfig` maps INI keys to runtime settings. Most DSP params and **every operationally-toggled RDS setting** are live-apply (no engine restart); a few are restart-only. When adding a setting, classify it explicitly via `runtimeDisposition:`.

Three live-apply dispositions:

- `.live` — DSP-domain setting. Routes through `applyLiveRuntimeConfigIfRunning` → `RuntimeConfig` → audio thread.
- `.liveRDS` — RDS-domain setting. Routes through `applyLiveRDSConfigIfRunning` → `RDSRuntimeConfig` → `BasicRDSCoder.applyRDSRuntimeConfig`. The `RDSRuntimeConfig.make(from: AppConfig)` factory is the single canonical AppConfig→runtime mapping; both the engine builder and the test suite call it.
- `.restart` — requires transport stop/start. Use this for physical-layer settings that reconfigure the modulator FIR / oversampler / sample-rate plumbing.
- `.none` — handled via a side channel (e.g. now-playing script reload), no runtime apply needed.

RDS settings that stay restart-only: `rds_level` (injection kHz), `rds_freq` (subcarrier frequency), `rds_gaussian_*` (FIR taps + BW). Everything else — master enable, PI, PTY, PTYN, ECC, LIC, TP/TA/MS/DI, AF list/method, group sequence, scheduler, CT/ID/TZ, all RT/PS/Long PS text — applies live.

When toggling `rds_ta` live, `BasicRDSCoder.applyRDSRuntimeConfig` sets `forceNextGroupForTAEdge`. The next `nextGroupBits()` call honours it by emitting a forced 0A ahead of the schedule (UECP §2.5.1.1). CT (4A, minute-aligned) keeps higher priority than the TA-edge force flag.

Verification.ini key name collisions are a known sharp edge — when adding a setting, grep `AppConfig.swift` for the exact config-key string before naming a new one. The composite clipper itself uses `mpx_clipper_*` keys; the legacy `composite_clipper_enabled` key (which used to control the now-removed composite limiter) was deleted in 0.11.

### Threading

- **Audio render callback**: real-time thread. Lock-free, allocation-free. No blocking I/O, no dispatch, no `Task { ... }`, no string formatting, no `NSRegularExpression` compilation. Cache compiled regex as `static let`. **Use `BasicRDSCoder.monotonicSeconds()` (`ProcessInfo.systemUptime`, commpage-backed) for elapsed-time math, not `Date()`** — the only `Date()` calls retained on a render-reachable path are the RT `{time}/{date}` macro substitution (justified — needs wall clock) and the CT cache refresh (runs on background queue). New code must follow the same pattern.
- **Main thread**: SwiftUI UI. For timer callbacks into `@MainActor` state, use `MainActor.assumeIsolated {}`, **not** `Task { @MainActor in ... }` — the latter heap-allocates and accumulates pressure on long-running meters.
- **Background metering**: `.userInteractive` QoS dispatch queue. Skip calculations when `meteringEnabled` is false (UI not visible).
- **RDS clock cache**: `clockUpdateQueue` (utility QoS) refreshes the atomic CT cache once per second. `enCT` / `enID` toggling on at runtime calls `startClockCacheIfNeeded()` to prime + start the timer if it isn't already running (idempotent).

Hot-path optimization: prefer `vDSP_*` (Accelerate) over Swift loops. Pre-allocate buffers at engine start. Use `@inline(__always)` on tiny hot helpers. CPU profiling: use Instruments (Time Profiler).

Concrete vDSP wins already in place:
- `vDSP_dotpr` for FIR convolution (encoder bandwidth FIR + multiband FIR splitters). 5–10× vs manual loop. Required for FIR multiband to fit real-time budget.
- `vvtanhf` (vForce) for batched soft-clip in `CompositeClipper`, `BassClipper`, `DistortionCancelledClipper`. Pre-compute oversampled inputs, batch the tanh, then run per-OS-step state-dependent work. ~5× at 8-element batches, ~9× at 16-element.
The structural pattern in both cases is the same: extract the parallelisable transcendental/dot-product work from inside the per-sample/per-OS-step loop, do it as a vector, then continue the recursive (biquad/delay-line) work sequentially.

## Conventions

- **ASCII only** in source and docs. No non-ASCII punctuation / symbols.
- Keep `MPXGenerator.swift` and `SwiftUIControlApp.swift` splittable-in-principle (both >6k lines); prefer new helpers over growing them further, but **do not** opportunistically refactor the final MPX chain — even behavior-preserving edits can measurably move composite output. Structural cleanup there is done in small, verifier-backed steps.
- Device UIDs are platform-specific — always enumerate, never hardcode.
- New DSP stages ship **disabled by default** and must support live-apply via `RuntimeConfig` unless there is a specific reason not to.
- Avoid reintroducing separate Stereo/RDS menus; use unified navigation.

## UI/UX (Apple HIG)

- **No buttons in title bars / toolbars.** All controls live in the content area.
- Use native macOS window chrome (standard close / minimize / zoom).
- Use `HSplitView` for static sidebars; `NavigationSplitView` only when sidebar collapse is required.
- `.listStyle(.sidebar)` for sidebar navigation.
- Cards use `LabeledContent`, 10pt corner radius, 16pt spacing.
- `.buttonStyle(.bordered)` / `.buttonStyle(.borderedProminent)` for buttons.
- `.pickerStyle(.segmented)` for tab pickers within sections; `.pickerStyle(.menu)` for dropdowns.

## Release prep

- Bump version in `AppConfig.swift` (`appVersion`), `build-release.sh` (default), `README.md`, and `CHANGELOG.md`.
- `swift build --package-path macOS -c release` is clean.
- Manual smoke test with `--gui`: monitoring + processing tabs work.
- `./build-release.sh <version>` produces the universal binary + DMG under `macOS/dist/`.
- Branch model: `main` is the default branch and tracks released versions. The integration branch is named after the next target version (currently `v.23`) and is where unreleased work accumulates. Feature work either commits directly on the integration branch or on short-lived branches off it. Releases ship by merging the integration branch into `main`, tagging `v<version>` from `main`, and pushing the tag — which triggers `.github/workflows/release.yml`, runs `./build-release.sh <version>`, and publishes the resulting DMG as a GitHub Release. After a release ships, create a new integration branch for the next target version (e.g., `v.24`) off `main`.
- Optionally run the deep DSP combination suite (`MPXPRIME_DEEP=1 swift test --filter Deep`, ~3 min) before tagging — catches stage-interaction regressions the default suite misses.
