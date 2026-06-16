# Agent Instructions

This file is the single source of truth for AI coding agents (Claude Code, Codex, etc.) working in this repo. `CLAUDE.md` is a symlink to this file.

## Project

Native macOS FM composite (MPX) generator — real-time broadcast-style stereo encoder with RDS, "MPX Prime Studio". Swift 6 / SwiftUI / AVAudioEngine, SPM package rooted at `macOS/`. Targets macOS 15+. Two executable targets: `MPXPrime` (the encoder, ships as "MPX Prime Studio.app", **universal**) and `MPXPrimeMeter` (the companion receive/analyze app "MPX Prime Meter.app" — captures an MPX composite from an audio device or RTL-SDR and decodes stereo + RDS in a SwiftUI dashboard; **Apple-Silicon-only**, because it statically links the arm64-only RTL-SDR tuner — see below); they share `MPXPrimeCore` (DSP) and `MPXPrimeUI` (Canvas SwiftUI components), and both ship in the same DMG. The Meter links `CMPXTuner` — the vendored RTL-SDR -> FM-demod -> MPX tuner (repo-root `tuner/`, GPL-3.0) compiled as a C++ library with a pure-C ABI (`mpx_tuner_capi.h`), decoding the dongle **in-process** (no subprocess, no FIFO); it links Homebrew `librtlsdr` + `liquid-dsp`. Build the x86_64 release slice with `--product MPXPrime` so the Meter/CMPXTuner are skipped on Intel. Swift dep is `swift-atomics`.

- Primary entrypoint: `macOS/Package.swift`
- Default user config: `~/Library/Application Support/MPX Prime Studio/MPX Prime Studio.ini`
- **Platform tiers: Apple Silicon (arm64) is Tier 1** (primary, fully-supported, optimization target). **Intel (x86_64) is Tier 2, best-effort** — ships in the universal binary with an identical audio chain, but perf work targets arm64 first; give Intel lighter-weight fallbacks where cheap (e.g. the arch-tiered GUI refresh profile), don't block on Intel-only optimization.

See also: `docs/manual.md` (user manual: usage / configuration / RDS / reference tables), `docs/ARCHITECTURE.md` (detailed DSP chain and stage descriptions), `docs/BUILDING.md` (build / run / test / package from source), `plan.md` (roadmap).

## Commands

```bash
# Build (debug / release)
swift build --package-path macOS
swift build --package-path macOS -c release

# Run
swift run --package-path macOS MPXPrime              # GUI
swift run --package-path macOS MPXPrime --nogui      # headless
swift run --package-path macOS MPXPrime --config "/path/to/MPX Prime Studio.ini"

# Offline verification (no audio devices touched)
swift run --package-path macOS MPXPrime --verify --seconds 5
swift run --package-path macOS MPXPrime --verify-presets --seconds 5
swift run --package-path macOS MPXPrime --verify-long --seconds 30
swift run --package-path macOS MPXPrime --verify-receiver --seconds 5  # coherent receiver-side decode (separation @ 1/10/14 kHz, pilot, RDS); 0.36 adds guard-band cancellation depth + pilot/RDS phase-lock drift gate
swift run --package-path macOS MPXPrime --verify-composite-multiband --seconds 2  # A/B experimental composite multiband clipper toggle
swift run --package-path macOS MPXPrime --verify-multiband-coupling --seconds 2  # A/B experimental multiband inter-band coupling toggle

# Baseline capture + strict compare
swift run --package-path macOS MPXPrime --capture-baseline      # writes macOS/verifier_baselines/default.json
swift run --package-path macOS MPXPrime --verify --baseline-strict

# Tests — MUST override DEVELOPER_DIR; CLT ships no Testing.framework, Xcode does.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path macOS

# Single test / filter
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path macOS --filter BassClipperTests

# Release bundle + DMG
./build-release.sh 0.28

# Optional deep DSP combination test suite (~3 min; opt-in)
MPXPRIME_DEEP=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path macOS --filter Deep
```

**Debug builds are not real-time capable.** `swift build` / `swift run` produce a debug binary without optimizer pass; the meter / scope / spectrum work in `refreshMonitoringSnapshot` runs slow enough to preempt the audio thread on a debug build, producing clicks, buffer underruns, or input-ring overflows. Use debug for development, unit tests, and `--verify` (which doesn't touch real audio devices). For any test that involves live audio I/O — bug-reproducing on real hardware, listening tests, regression checks of the actual chain — build release first: `swift build --package-path macOS -c release` and run `macOS/.build/release/MPXPrime`, or use the `./build-release.sh` DMG. If a user reports buffer issues, ask whether they're on a debug or release build before chasing a DSP regression. If buffer issues persist on a release build, check that Audio MIDI Setup's device format matches the configured `sample_rate` in the INI — CoreAudio's implicit SRC will starve the render thread on a mismatch, producing input-ring overflows and silent output that look identical to a DSP fault.

Verifier exit codes: `0` = PASS, `1` = TIGHT (near limits, review), `2` = WARN.

The `--verify --baseline-strict` baseline is schema 3 (`VerifierBaseline.swift`): besides the per-scenario composite metrics it pins a 4x-oversampled true-peak inter-sample-overshoot field and a global encoder-side sideband fingerprint (asymmetry + side/mono delta at 1/10/14 kHz). A DSP change that moves composite output requires recapturing via `--capture-baseline`.

Tests use **Swift Testing** (`import Testing`, `@Test` / `#expect`) — not XCTest. Do not add XCTest-based tests.

The default `swift test` is fast (~18 s; latest observed suite is 426 tests / 64 suites) and runs on every change. The optional deep suite (`DeepDSPTests.swift`, gated by `MPXPRIME_DEEP=1`) covers stage-interaction bugs: per-stage isolation, 50 random configs × 4 adversarial programs, pairwise enable/disable matrix, counteract pair detection, per-preset safety. Run on demand before a release or when touching multiple stages.

For DSP differences, prefer measurement-first validation wherever technically possible before asking the operator to listen. If a behavior can be characterized with deterministic signals, FFT/band-energy analysis, receiver decode metrics, alias/IM checks, peak/ceiling checks, stereo-link checks, CPU budget tests, or verifier/baseline comparisons, add or run those tests first. Listening tests are still useful for final subjective confirmation, but they should not be the primary regression detector for measurable DSP behavior.

## Architecture

### Layout
- `macOS/Sources/MPXPrime/` — all runtime code (no sub-modules)
  - `main.swift` — CLI entry, arg parsing, verify-mode dispatch
  - `AppConfig.swift` — INI-backed config model + live-apply routing (`RuntimeConfig`, `RDSRuntimeConfig`)
  - `INIParser.swift`, `AudioDevices.swift` — file and CoreAudio plumbing
  - `AudioOutputEngine.swift` — AVAudioEngine lifecycle, input tap, render callback
  - `MPXGenerator.swift` (~9900 lines) — DSP core + `BasicRDSCoder`. All stages of the chain live here
  - `MPXDecoder.swift` (0.27) — reusable FM stereo demod (pilot PLL, deemphasis, noise gate, stereo-collapse cooldown). Lives in the `MPXPrimeCore` SPM target (not `MPXPrime`); hot `process()` is `@inlinable`. Used by the monitor path with the delay-aligned reference and by `--verify-receiver` with a PLL-recovered reference. Sanitizes non-finite inputs (0.36) — one NaN/Inf sample used to permanently poison the pilot-lock I/Q + envelope state (smoothers never flush NaN, self-heal can't re-arm); keep the `isFinite` guard at the top of `process()`.
  - `BandLimitedStep.swift` (0.27) — BLEP/BLAMP correction primitive for the US 6,937,912 anti-aliased clipping work
  - `AcceleratedBandlimitedResidualClipper.swift` (0.27) — vDSP-accelerated patent-style residual-bandlimiting clipper, opt-in via `pre_encode_bandlimited_residual_enabled`
  - `StereoInputRingBuffer.swift` — lock-free input → render bridge
  - `SwiftUIControlApp.swift` (~9250 lines) — SwiftUI views + view-model state
  - `UIBroadcastStatusBar.swift` / `UIBroadcastMeter.swift` / `UIBroadcastStyle.swift` — pinned-top status header, vertical meter strips, shared style tokens
  - `UISignalFlowStrip.swift` — read-only DSP-chain pill strip
  - `UIInspector.swift` — stage-aware right-pane inspector
  - `UIProcessingOverview.swift` — Processing-section landing grid (per-stage cards)
  - `VerificationHarness.swift` / `VerifierBaseline.swift` — offline scenario renderer + baseline compare
  - `NowPlayingSupport.swift` — external script polling for RDS RT metadata
- `macOS/Tests/MPXPrimeTests/` — Swift Testing suite (DSP primitives, ring buffer, analysis helpers, RDS bitstream + live-apply)
- `macOS/verifier_baselines/` — JSON baselines for `--verify --baseline-strict`
- `macOS/{MPXPrime.ini,Verification.ini}` — sample configs; user config lives at `~/Library/Application Support/MPX Prime Studio/MPX Prime Studio.ini`
- `documents/` — standards PDFs (EN 50067 / IEC 62106-2 / IEC 62106-6 / UECP SPB 490 / ITU-R BS.450)
- `.vscode/settings.json` — sets `swift.searchSubfoldersForPackages: true` so sourcekit-lsp discovers `macOS/Package.swift` (workspace root is the repo root, package lives one level down)

### Signal chain (critical invariants)

The audio path runs ~24 stages, ending with **post-clipper pilot + RDS injection**. Anything that touches the chain order needs to preserve two non-obvious invariants:

1. **Subcarriers (19 kHz pilot, 57 kHz RDS) MUST be injected after all peak-control stages.** They bypass the composite clipper, BS.412, and final-MPX safety limiter. Constant-amplitude subcarriers are required for reliable stereo decoding and RDS reception — this matches professional broadcast practice (Omnia, Orban, Stereotool). The clipper has explicit pilot-guard (17–21 kHz) and RDS-guard (55–59 kHz) cancellation — clipping IM in those bands is removed before subcarrier injection so the receiver doesn't see clipper noise vector-summed with the cleanly-injected pilot/RDS.
2. **Pre-emphasis runs in L/R domain immediately upstream of the pre-encode limiter** (canonical Optimod / Stereotool placement; relocated post-0.24). The limiter peak-controls the +10..12 dB HF-boosted signal before composite assembly. The pre-2026 M/S placement and the b806053 cost-regression history that originally motivated it are recorded in plan.md "Pre-emphasis placement (history)"; the b806053 regression class is no longer reproducible on the current chain.

Peak control:
- **Pre-encode audio limiter** — L/R, stereo-linked, after pre-emphasis, before stereo encoding. Uses `StereoLinkedOversampledPeakLimiter` (4× oversampled true-peak with tanh ceiling, shared gain envelope from `max(|L|, |R|)`). 0.30: default-on look-ahead (`pre_encode_lookahead_ms = 1.0`, audio-rate delay + un-delayed `futurePeak` detector into `stereoStep`, US 4,208,548 prior art) and default-on Dolby HF-subband-aware detector (`pre_encode_lookahead_hf_only = True`, `pre_encode_lookahead_hf_cutoff_hz = 4000`, US 5,579,404 / EP 0685130, expired 2013) — detector path high-passes input so look-ahead engages only on HF transients where pre-emphasis concentrates peaks; audio path stays full-band. Look-ahead settings are restart-required (allocate delay buffer / reconfigure detector biquad).
- **Composite clipper** — 16× oversampled tanh soft-clipper on the audio composite, **differential topology** (only the clipping residual goes through decimation; wanted signal rides a 1× delay-matched bypass), with delta-based per-band substitution that protects audio (0–17 kHz, opt-in), pilot guard (17–21 kHz), stereo subcarrier (22–53 kHz), and RDS guard (55–59 kHz) bands. Decimation via `LinearPhaseFIRDecimator` (Kaiser-windowed sinc, auto-sized to OS rate, `vDSP_dotpr` polyphase, ≥90 dB stopband). Replaces the old `CompositeTruePeakLimiter` (deleted in 0.11) which used `|composite|` peak detection + memoryless tanh and produced intermod that demodulated as `(L-R)` cancellation. Inspired by Orban US 4,460,871 + US 5,737,434 (delta-cancellation primitive, expired) and US 6,337,999 (differential topology, expired 2022 — landed in 0.20).
- **Multiband composite clipper** — experimental, off by default via `mpx_multiband_clipper_enabled`. Runs after the broadband composite clipper and before the audio-composite bandwidth FIR, using linear-phase low/mid/high splitting (`LP180`, `LP4200 - LP180`, delayed input minus `LP4200`) and independent band clipping with current ceilings 0.90 / 0.62 / 0.38. `--verify-composite-multiband` and `DSPThroughputTests.compositeMultibandClipperCostStaysBounded` provide the current measurement gate; dense-program listening and preset A/B are still required before using it in presets.

`Mono Mode` suppresses pilot, stereo subcarrier, and RDS — true mono composite.

Oversampled clippers: `BassClipper` 4× and `DistortionCancelledClipper` 8× share a `Lagrange4Interp` + `BiquadCascade6` decimation pattern (12th-order Butterworth LP). `CompositeClipper` runs at the `mpx_clipper_oversampling` rate (default 16×, operator-selectable across {8, 16, 32} since 0.30; restart-required) with `Lagrange4Interp` + `LinearPhaseFIRDecimator` (Kaiser-windowed sinc, `vDSP_dotpr` polyphase) — linear phase and tighter stopband than the Butterworth cascade, at the cost of group-delay latency folded into `subcarrierDelayLine`. Per-host batch buffers default-size to 32 elements (the supported max) so swapping between factors is non-allocating after first `configure()`. Soft-clip `tanhf` calls in all three are batched through `vvtanhf` (vForce SIMD) for ~5–9× speedup vs scalar tanhf at 8/16-element batches — see `TanhBatchSizeBench` for the curve. Follow these patterns for any new oversampled nonlinearity.

The multiband compressor has two crossover backends, picked at engine start by output mode:
- **TX path** uses `LinearPhaseMultibandSplitter5` / `3` — Kaiser-windowed-sinc FIR splitters with parallel-cumulative-LP topology, all bands sharing group delay so summed bands reconstruct the input delayed-by-`groupDelaySamples` exactly (sum-to-flat at –155 dB). Eliminates IIR-LR4's transient smear and inter-band pumping. ~5.3 ms latency at 192 kHz with the default 90 Hz lowest crossover. Convolution runs through `vDSP_dotpr` (double-buffered delay line) — without that the FIR path overruns real-time budget on most machines (manifests as audio crackle + RDS BCH corruption from sample dropouts).
- **Monitor path** keeps the IIR `StereoLinkwitzRiley4` chain for low latency.

Multiband Phase 2 is implemented but opt-in: `multiband_transient_aware_attack_enabled = false` by default. When enabled, `MonoCompressor` uses an RMS/peak hybrid detector and briefly stretches attack on peak-vs-RMS transients so percussive fronts pass hotter while sustained material settles near the classic peak-detector level. Keep it verifier-backed before enabling it in presets.

Multiband inter-band coupling is implemented but opt-in: `multiband_inter_band_coupling_enabled = false` by default. When enabled, low-band gain reduction is smoothed (20 ms attack / 300 ms release) and gently biases upper-band thresholds lower so bass-heavy passages keep tonal glue without wideband pumping. Keep it preset-gated until program-material A/B confirms the balance.

RDS baseband uses EN 50067 biphase shaping and a pilot-locked subcarrier. The 57 kHz carrier is derived from the pilot oscillator's recurrence (`pilotOsc.s`) via the triple-angle identity (`3s - 4s^3`), passed into `BasicRDSCoder.updateRDSPilotSin` per sample — NOT a separate additive phase accumulator. The old accumulator path drifted ~9 deg / 5 s against the emitted pilot (it added `Float(w)` while the broadcast pilot / 38 kHz subcarrier ride the s/c recurrence); fixed 0.36, gated by the pilot/RDS phase-lock drift check in `--verify-receiver`. Do not regress the production path to a free-running 57 kHz oscillator. RDS carrier frequency is config-only; the UI exposes carrier level and program data.

### Configuration + live-apply

`AppConfig` maps INI keys to runtime settings. Most DSP params and **every operationally-toggled RDS setting** are live-apply (no engine restart); a few are restart-only. When adding a setting, classify it explicitly via `runtimeDisposition:`.

Three live-apply dispositions:

- `.live` — DSP-domain setting. Routes through `applyLiveRuntimeConfigIfRunning` → `RuntimeConfig` → audio thread.
- `.liveRDS` — RDS-domain setting. Routes through `applyLiveRDSConfigIfRunning` → `RDSRuntimeConfig` → `BasicRDSCoder.applyRDSRuntimeConfig`. The `RDSRuntimeConfig.make(from: AppConfig)` factory is the single canonical AppConfig→runtime mapping; both the engine builder and the test suite call it.
- `.restart` — requires transport stop/start. Use this for physical-layer settings that reconfigure the modulator FIR / oversampler / sample-rate plumbing.
- `.none` — handled via a side channel (e.g. now-playing script reload), no runtime apply needed.

RDS settings that stay restart-only: `rds_level` (injection kHz), `rds_gaussian_*` (FIR taps + BW). Everything else — master enable, PI, PTY, PTYN, ECC, LIC, TP/TA/MS/DI, AF list/method, group sequence, scheduler, CT/ID/TZ, all RT/PS/Long PS text — applies live. The 57 kHz subcarrier frequency is spec-fixed (EN 50067 Sec 2.1.4, locked to 3x pilot) and is not user-configurable.

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
- **After ANY change, update ALL affected docs in the same change — always.** Docs are part of "done", like tests. Before calling a task done, ask which docs the change touches and update them together: `docs/ARCHITECTURE.md` (DSP chain / signal flow / stage behavior / output modes / RDS / verifier surface / targets), `docs/manual.md` (user-facing behavior, UI labels/controls, config keys, presets, operator workflow), `README.md` (product name, features, install, what ships in the DMG), `CHANGELOG.md` (an entry under the current Unreleased / version section), and **this file `AGENTS.md`** (project structure, targets, conventions). Edit `AGENTS.md` directly — `CLAUDE.md` is a symlink to it; never write through the symlink (a `perl -i` once replaced it with a regular file). Do not let docs drift behind the code: e.g. the 0.35 relabel renamed the composite-clipper guards `Cancel ...` -> `Protect ...` (UI + manual both), and MPX Prime Meter shipping in 0.37 needed README/manual/ARCHITECTURE coverage.
- Keep `MPXGenerator.swift` and `SwiftUIControlApp.swift` splittable-in-principle (both >6k lines); prefer new helpers over growing them further, but **do not** opportunistically refactor the final MPX chain — even behavior-preserving edits can measurably move composite output. Structural cleanup there is done in small, verifier-backed steps.
- Device UIDs are platform-specific — always enumerate, never hardcode.
- New DSP stages ship **disabled by default** and must support live-apply via `RuntimeConfig` unless there is a specific reason not to.
- Avoid reintroducing separate Stereo/RDS menus; use unified navigation.
- **High-frequency monitoring UI must not invalidate the view model.** Meters, scopes, spectrum, and live numeric readouts update at the metering rate (up to 30 Hz). Two rules, both load-bearing (see CHANGELOG 0.34 — the multi-hour GUI freeze):
  - **Draw moving graphics in `Canvas`, never as layout** — no SwiftUI subview whose `.frame(width:/height:)` or `.offset` tracks a live value. A value change must be a repaint, not an Auto Layout pass.
  - **Read live values from the `LiveTelemetry` observable, not `@Published` on `MPXPrimeViewModel`.** Per-tick values live on `LiveTelemetry` (the view model keeps one-line forwarding properties so writer code is unchanged); wrap live readouts in `LiveTelemetryView` so a tick re-evaluates only those leaves. Putting per-tick state back on the view model recreates the window toolbar every tick (documented SwiftUI-on-macOS leak) and progressively freezes the GUI over hours. Detached high-refresh windows also set `NSHostingController.sizingOptions = []`. The 8 Hz "readout pulse" experiment was tried and reverted — don't reintroduce it.

## UI/UX (Apple HIG)

- Use native macOS window chrome (standard close / minimize / zoom).
- A toolbar is the HIG-endorsed home for frequently used commands, controls, navigation, and search; on macOS it occupies the unified title bar. Put the app's primary, frequently-used actions there rather than forcing every control into the content area. (An earlier revision of this file banned toolbar buttons outright -- that contradicted the HIG ("a toolbar provides convenient access to frequently used commands") and was removed. Do not re-add the ban.)
- Prefer `NavigationSplitView` for sidebar navigation: a collapsible sidebar (toggle + Cmd-Opt-S) is standard, expected macOS behavior. `HSplitView` is only the legacy fallback for a genuinely fixed, non-collapsing two-pane split.
- `.listStyle(.sidebar)` for sidebar navigation.
- `.buttonStyle(.bordered)` for buttons; `.buttonStyle(.borderedProminent)` for the single default / primary action in a given context.
- `.pickerStyle(.segmented)` for small mutually-exclusive option sets / view switchers; `.pickerStyle(.menu)` for dropdowns (pop-up buttons).
- Project visual convention (house style, NOT a HIG rule): content "cards" use `LabeledContent` with 10pt corner radius and 16pt spacing. `LabeledContent` is the native control; the radius/spacing are ours. macOS-native grouping (`GroupBox`, `Form` sections) is equally acceptable and is what the HIG actually prescribes.
- **One source of tab help — no duplicated prose.** Each Processing / RDS tab already shows its description in the shared bottom `TabHelpBox` (fed by the tab enum's `helpText`, e.g. `ProcessingTab.helpText` / `RDSTab.helpText`). Do NOT add an in-card `Text` that restates the stage description — it shows the same information twice. In-card captions are only for **distinct actionable guidance the box doesn't cover** (a usage tip, a "start with X" recommendation, a control-interaction note) or a safety-critical one-liner. When adding a tab, put the description in `helpText`, not in the card.
- **Disclaimer / license: one source of truth.** The full intended-use / not-certified disclaimer lives only in `README.md` (line ~9); GPL-3.0 / no-warranty terms live only in `LICENSE`. The About panel (`AboutSectionView` in `SwiftUIControlApp.swift`) must NOT restate the full disclaimer — it quotes README's canonical key phrase ("experimental and not certified — no conformity or compliance is promised") plus links to GitHub / User Manual / License. If the disclaimer wording changes, edit README (and the About's one-liner only if that key phrase changes); never grow a second copy.
- **Control labels use outcome language; jargon lives in tooltips.** The target operator is broadcast/RF-literate but not a DSP engineer. KEEP established broadcast terms on labels (pre-emphasis, pilot, RDS, PTY/PI/ECC, deviation, composite clipper, BS.412, phase rotator, AGC, multiband). Do NOT put patent/topology/DSP-implementation phrasing on a label — say what the control does for the signal ("Protect Stereo Pilot", "Reduce Clipping Distortion", "Audio Clipper"), and push the mechanism (distortion-cancellation topology, LR4/Gaussian/FIR internals, Orban/US-patent references) into the `.help()` tooltip or the bottom help box. When two views control the same thing, use one vocabulary across both (the inspector matches the main tab). Collapse expert / set-once / experimental controls into a `DisclosureGroup` (reuse the Audio Limiter "Advanced" pattern) so common controls stay prominent.
- **Accessibility lint** — the project ships a `.swiftlint.yml` that runs only `accessibility_label_for_image` and `accessibility_trait_for_button` (no broader style enforcement; DSP code uses many intentional patterns that fight the default SwiftLint rule pack). Run with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftlint` from the project root before committing UI changes. Decorative SF Symbols (icons next to descriptive text, info-circle in help boxes) should use `.accessibilityHidden(true)`; icon-only buttons need `.accessibilityLabel(...)`.

## Release prep

- Bump version in `AppConfig.swift` (`appVersion`), `build-release.sh` (default), `README.md`, and `CHANGELOG.md`.
- `swift build --package-path macOS -c release` is clean.
- Manual smoke test with `--gui`: monitoring + processing tabs work.
- `./build-release.sh <version>` produces the universal binary + DMG under `macOS/dist/`.
- Branch model: `main` is the default branch and tracks released versions. The integration branch is always named **`develop/v.NNN`** — three digits, leading zero — after the next target version (currently `develop/v.037`; 0.35 shipped 2026-06-09, and 0.36 is staged on `develop/v.036` awaiting the maintainer's tag). Unreleased work accumulates there; feature work either commits directly on the integration branch or on short-lived branches off it. Releases ship by **squash-merging** the integration branch into `main` (one commit per shipped version, NOT `--ff-only`), tagging `v<version>` from `main`, and pushing the tag — which triggers `.github/workflows/release.yml`, runs `./build-release.sh <version>`, and publishes the resulting DMG as a GitHub Release. After a release ships, cut a new `develop/v.NNN` branch off `main` for the next target version. Tags themselves use `v<version>` without zero-padding (e.g., `v0.21`, `v0.28`); only branch names use the `v.NNN` form.
- **Release prep vs. tagging is split.** An agent prepares a release — version bump in the four files, CHANGELOG entry, commit + push to the integration branch — but does NOT merge to `main` or push the tag. The maintainer runs the hardware-dependent checklist items (live 192 kHz device smoke, RDS receiver smoke, VoiceOver pass) and pushes the `v<version>` tag, since those cannot be done from a headless agent and the tag push publishes a public DMG.
- Optionally run the deep DSP combination suite (`MPXPRIME_DEEP=1 swift test --filter Deep`, ~3 min) before tagging — catches stage-interaction regressions the default suite misses.

### Release validation checklist

Run before tagging. None of these should be skipped on a release commit; partial coverage is how regressions ship.

**Run the offline `--verify*` gates on an otherwise-idle machine — quit the GUI app, and ideally browsers / media players too.** They are single-threaded CPU-bound renderers (no GUI, no audio devices — already headless). A running MPX Prime Studio GUI or other heavy apps starve them to ~20-37% of one core, so an 8-16 s gate can crawl to 20+ minutes and look hung when it is only contended. On an idle machine: `--verify` ~16 s, `--verify-presets` ~8 s. The slowness is contention, not a regression — don't chase it as one, and don't run the verify sweep next to a soak/listening instance.

- [ ] `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path macOS` — full default suite passes
- [ ] `swift build --package-path macOS -c release` — release build clean
- [ ] `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftlint` — 0 violations (accessibility lint)
- [ ] `swift run --package-path macOS MPXPrime --verify --seconds 5` — exit 0 (PASS)
- [ ] `swift run --package-path macOS MPXPrime --verify-presets --seconds 5` — exit 0
- [ ] `swift run --package-path macOS MPXPrime --verify-receiver --seconds 5` — exit 0 (separation @ 1/10/14 kHz, pilot, RDS)
- [ ] `swift run --package-path macOS MPXPrime --verify --baseline-strict` — composite shape matches the captured baseline
- [ ] **Release build live smoke**: run `macOS/.build/release/MPXPrime --gui` against a real 192 kHz output device (NOT debug, NOT 96 kHz) — RDS reads cleanly on a real receiver, no clicks/dropouts over 30+ seconds of dense program
- [ ] **Device-rate match**: Audio MIDI Setup output format matches `sample_rate` in INI (see CLAUDE.md "buffer issues" diagnostic)
- [ ] **RDS receiver smoke**: at minimum one car radio + one portable RDS receiver + one SDR decoder verify live PI / PS / PTY / RT A/B / TA edge / AF / CT / Long PS
- [ ] **UI**: if any UI change in the release, manual VoiceOver pass + high-contrast appearance verification
- [ ] **Optional but recommended**: `MPXPRIME_DEEP=1 swift test --filter Deep` (catches stage-interaction regressions; ~3 min)
