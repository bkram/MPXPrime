# MPX Prime Meter — SwiftUI GUI

## Context

The MPX Prime Meter is a working **headless CLI** (`MPXPrimeMeter` target): it captures an FM MPX composite (audio device or stdin pipe), decodes stereo + full RDS (PI/PS/PTY/TP/TA/MS/RT/RT+/CT/AF/Long PS + BER), measures SFP-style kHz deviation, plays a decoded-audio monitor, and records WAV. It has no window yet. This plan adds the **GUI** the original request asked for — live scopes, spectrum, level meters and an RDS panel "as in MPX Prime" — by sharing the transmit app's (already Canvas-based, decoupled) SwiftUI components through a new `MPXPrimeUI` library target, and feeding them from the existing analysis engine.

Exploration confirmed the reusable views (`ScopeView`, `MPXSpectrumView`, `VerticalMeterStrip`, `BroadcastStyle`, the `LiveTelemetryView` isolation wrapper) take plain `[Float]`/`Double` with **zero transmit coupling** and all draw in `Canvas`. The Meter's `MeterSnapshot` currently carries only scalars + RDS, so it must grow waveform/spectrum buffers — added via the same `isolatedSnapshot()` deep-copy that fixed the recent cross-thread heap-corruption crash.

**Decisions (confirmed):** single resizable **dashboard window** (one signal, see-everything-at-once); deliver the **full GUI + a packaged double-clickable `MPX Prime Meter.app`**.

## Hard constraints (load-bearing — a multi-hour GUI freeze came from violating these)
- High-frequency graphics draw in `Canvas`, never a value-tracking `.frame`/`.offset`. (Reused views already comply.)
- Per-tick values flow through a `LiveTelemetry`-style `ObservableObject` read via `LiveTelemetryView` — NEVER `@Published` on the main view model (per-tick VM invalidation recreates the window toolbar every tick → freeze).
- Detached/high-refresh hosting controllers set `NSHostingController.sizingOptions = []`.
- Every new `[Float]` snapshot field MUST be deep-copied in `MeterAnalysis.isolatedSnapshot()` (omission = the cross-thread CoW crash again).
- MPXPrime (transmit) must build and behave **unchanged**; `--verify`/`--verify-receiver --baseline-strict` exit codes unchanged. Native macOS chrome, Apple HIG. swiftlint 0 (accessibility rules — new Canvas views need the `accessibilityElement`/label/traits the originals already carry).

## Reference patterns already in the tree (reuse, don't reinvent)
- Dual-mode binary + AppDelegate + window hosting: `macOS/Sources/MPXPrime/main.swift` (~178-300) and `SwiftUIControlApp.swift` (`AppDelegate` ~875; main window build ~980-1006 with `sizingOptions=[]`, `setFrameAutosaveName`).
- Per-tick isolation: `macOS/Sources/MPXPrime/UILiveTelemetry.swift` (`LiveTelemetry` + `LiveTelemetryView`); refresh timer pattern `applyMonitoringRefreshRate()` / occlusion observers (`SwiftUIControlApp.swift` ~1010-1040, ~2066).
- Reused views: `ScopeView` (`SwiftUIControlApp.swift` ~6686), `MPXSpectrumView` (~6765), `VerticalMeterStrip` (`UIBroadcastMeter.swift`), `BroadcastStyle` (`UIBroadcastStyle.swift`).
- Meter side: `MeterSnapshot`/`MeterAnalysis` (`MeterAnalysis.swift`), `MeterAudioEngine` (lock + `isolatedSnapshot()` publish), `AudioDevices` + `AUHALInputSource` (Core), `MPXSpectrumAnalyzer` (`MPXPrimeCore/SpectrumAnalyzer.swift`, public, not yet used by the Meter).

---

## Phase 0 — Open the input device at 192 kHz (prerequisite bug fix, do first)
**Bug:** `InputAUHAL.configure` (`MPXPrimeCore/InputAUHAL.swift` ~180-214) opens the client format at the device's *current* stream-format rate — AUHAL has no sample-rate conversion, so it can't request a rate the device isn't already at. Nothing raises the device's nominal rate, so a DAC that *supports* 192 kHz but is sitting at 48/96 kHz is captured at that lower rate. Worse, `runLive` (`MPXPrimeMeter/main.swift`) builds `MeterAnalysis` from a *separate* `nominalSampleRate()` query, so the configured analysis rate can disagree with the real capture rate → RDS at 57 kHz aliases. Affects the CLI today.
**Fix (confirmed behavior: auto-switch to 192 kHz, restore prior rate on stop):**
- `AudioDevices` (Core): add `public static func availableNominalSampleRates(deviceID) -> [Double]` (`kAudioDevicePropertyAvailableNominalSampleRates`, `AudioValueRange[]`), `currentNominalSampleRate(deviceID) -> Double?`, and `setNominalSampleRate(deviceID, _) -> Double?` (set `kAudioDevicePropertyNominalSampleRate`, then poll `currentNominalSampleRate` until it matches or ~1.5 s timeout — the switch is async). Mirror the existing `setBufferFrameSize`/`bufferFrameSizeRange` style/section.
- Meter engine start (a small `startCapture` helper shared by `runLive` and the future GUI): target = 192000 if in available rates, else the highest available ≥128000; if none ≥128000, warn (RDS impossible) and proceed. Save the device's prior nominal rate, `setNominalSampleRate(target)`, open, and on `stop()` restore the saved prior rate (best-effort).
- Build `MeterAudioEngine` from the AUHAL's **actual** returned rate (`fmt.deviceSampleRate` from `input.start()`), not the pre-query; warn if AUHAL actual ≠ requested. (The `--stdin` path is unaffected — it already uses `--sample-rate`.)
- Gate: with the DAC at 48/96 kHz in Audio MIDI Setup, the Meter switches it to 192 kHz, the banner reads 192000, RDS decodes; on exit the device returns to its prior rate. `swift test` green; transmit app untouched.

## Phase 1 — `MPXPrimeUI` shared target (Commit 1)
- `Package.swift`: add `.target(name: "MPXPrimeUI", dependencies: ["MPXPrimeCore"], path: "Sources/MPXPrimeUI")`; add `"MPXPrimeUI"` to `MPXPrime`, `MPXPrimeMeter`, and `MPXPrimeTests` deps. Create `Sources/MPXPrimeUI/MPXPrimeUI.swift` placeholder so SPM resolves the empty target.
- Gate: both products build; nothing observable changes.

## Phase 2 — Move reusable SwiftUI into `MPXPrimeUI`, make `public` (Commits 2-4)
Incremental, one component per commit, `swift build` + transmit-GUI diff between each.
- **Commit 2 (standalone files):** `UIBroadcastStyle.swift` → `MPXPrimeUI/BroadcastStyle.swift` (`enum BroadcastStyle` + members + `Color.adaptive` → `public`); `UIBroadcastMeter.swift` → `MPXPrimeUI/VerticalMeterStrip.swift` (`struct` + `enum Scale` + explicit `public init` → `public`). Then `grep -rln "BroadcastStyle\|Color.adaptive\|VerticalMeterStrip" macOS/Sources/MPXPrime/` and add `import MPXPrimeUI` to each (build errors self-check).
- **Commit 3 (LiveTelemetry split):** move ONLY the generic wrapper `LiveTelemetryView` → `MPXPrimeUI/LiveTelemetryView.swift`, made `public` and generic: `public struct LiveTelemetryView<T: ObservableObject, Content: View>: View`. Leave the transmit `LiveTelemetry` class (its ~60 transmit-specific fields) in `MPXPrime` unchanged — the Meter declares its own focused `MeterTelemetry`. Update transmit call sites (type inference keeps `LiveTelemetryView(telemetry:) { t in … }` working).
- **Commit 4 (extract from the 9k-line file — riskiest):** cut `ScopeView` (~6686-6747) → `MPXPrimeUI/ScopeView.swift` and `MPXSpectrumView` (~6765-6940) → `MPXPrimeUI/MPXSpectrumView.swift`; `public` + explicit `public init`. Add an optional `public var markersHz: [Double]? = nil` to `MPXSpectrumView` (additive; default keeps transmit call sites unchanged) that draws thin vertical lines/labels in its existing Canvas — for the Meter's 19/38/57 kHz markers. Leave `AudioBarSpectrumView`/`StereoPreMPXSpectrumView`/`MonitoringWindowHeader` (transmit-only) in place. Verify: `git diff --stat` shows only expected deltas; `grep -c "ScopeView(\|MPXSpectrumView(" SwiftUIControlApp.swift` count unchanged; immediate `swift build`.
- **Gate (after Commit 4):** debug build both products; `swift test`; swiftlint 0; **`--verify-receiver --baseline-strict` unchanged** (proves extraction didn't perturb transmit DSP); launch transmit GUI — Scopes/Spectrum/Levels visually unchanged.

## Phase 3 — Meter data plumbing (Commit 5)
Extend `MeterSnapshot` (`MeterAnalysis.swift`):
```
var compositeScope: [Float] = []   // ~512-pt downsampled composite window (input scope)
var decodedLScope: [Float] = []    // ~512-pt decoded-L window
var decodedRScope: [Float] = []    // ~512-pt decoded-R window
var spectrumDB:   [Float] = []     // composite spectrum, ~512 display bins
var spectrumMaxHz: Double = 100_000
var spectrumNyquistHz: Double = 0
```
In `MeterAnalysis.process` (reusable scratch buffers, no per-block alloc): decimate the incoming block to fill `compositeScope` (stride-pick, point-to-point to match `ScopeView`); decimate `decodedL`/`decodedR[0..<lastBlockCount]` into the L/R scope buffers (publish these, NOT the raw 16384 arrays). Add `private let spectrum = MPXSpectrumAnalyzer()`; every 4th block copy the block into a reusable `[Float]` and call `spectrum.compute(samples:validCount:sampleRate:displayBins:512,maxDisplayHz:100_000)`, store `(dbBins,maxHz,nyquistHz)`.
**Critical:** extend `isolatedSnapshot()` to `.map { $0 }`-copy all four new arrays (scalars need no copy). CLI dashboard ignores the new fields — TTY output byte-identical.
- Gate: `--selftest`/`--stdin` dashboards unchanged; `swift test` green.

## Phase 4 — Meter GUI app (Commits 6-8), single dashboard window
- **Commit 6 (launch model):** restructure `main.swift` dispatch — any existing CLI verb/flag (`--list-devices`/`--selftest`/`--stdin`/`--device`/`--channel`/`--seconds`/`--no-monitor`/`--monitor-*`/`--wav`/`--pilot-ref-khz`/`--full-scale-khz`) → keep exact headless behavior (run-meter.sh unchanged). **No args (double-clicked .app) or `--gui`** → `NSApplication.shared` + `MeterAppDelegate` + `app.run()`.
- **Commit 7 (app), new files in `Sources/MPXPrimeMeter/`:**
  - `MeterAppDelegate.swift` — builds `MeterViewModel`, `RootMeterView`, one `NSWindow` (`.titled/.closable/.miniaturizable/.resizable`, unified toolbar, title "MPX Prime Meter"), `NSHostingController` with `sizingOptions=[]`, `setFrameAutosaveName`; starts the poll timer; occlusion/active observers drop the rate when hidden; `applicationShouldTerminateAfterLastWindowClosed → true`.
  - `MeterTelemetry.swift` — `final class MeterTelemetry: ObservableObject`, per-tick fields ONLY: normalized levels + display strings (input peak, L/R/M/S, correlation, PILOT/RDS/MAX kHz) and the four `[Float]` arrays + `spectrumMaxHz`/`spectrumNyquistHz`.
  - `MeterViewModel.swift` — `@MainActor final class MeterViewModel: ObservableObject` owning `let telemetry = MeterTelemetry()`. `@Published` holds ONLY low-frequency/structural state: device lists, selected input device/channel, monitor on/off + device + gain, running flag, and the **RDS text block** (changes per-second; written only on change). 25 Hz `Timer` (RunLoop `.common`, `MainActor.assumeIsolated`): read `engine.snapshot()`, push scalars+arrays into `telemetry`, diff-write RDS to `@Published`.
  - Engine control (on the VM): `AudioDevices.inputDevices()/outputDevices()`; `start()` resolves nominal rate (reuse `nominalSampleRate` from `main.swift` — promote to a shared helper), warns <128 kHz, builds `MeterAudioEngine(... input: AUHALInputSource(deviceID:))`, `try engine.start(monitorDeviceID:)`; device re-selection = `stop()` then `start()` (engine is constructed per-config); disable picker mid-transition.
  - `RootMeterView.swift` + section views: **Input bar** (input `Picker`, channel `Picker`, monitor `Toggle` + output `Picker` + gain `Slider`, Start/Stop — plain VM bindings). **Levels** `LiveTelemetryView(telemetry: vm.telemetry){…}` → L/R/M/S `VerticalMeterStrip(.dbfs)`, correlation, PILOT/RDS/MAX via `VerticalMeterStrip(.modulationKHz(limit:75))`. **Scopes** → `ScopeView(samples: t.compositeScope)` + `ScopeView(samples: t.decodedLScope, secondarySamples: t.decodedRScope)`. **Spectrum** → `MPXSpectrumView(dbBins:t.spectrumDB,maxHz:…,nyquistHz:…, markersHz:[19000,38000,57000])`. **RDS panel** reads VM `@Published` RDS (a `Grid`/`Form`: PI/PS/PTY/TP/TA/MS/RT/RT+/CT/AF/LongPS/BER + group-count histogram). All per-tick Canvas leaves sit inside `LiveTelemetryView` — VM `objectWillChange` fires only on device/RDS change.
- **Commit 8 (chrome):** main menu (App/Edit/Window/Help), About panel quoting README's key phrase (per house rule — no second disclaimer copy), app icon.

## Phase 5 — Packaging (Commit 9)
`build-release.sh`: add a universal build of `MPXPrimeMeter` (`lipo` arm64+x86_64), wrap in `MPX Prime Meter.app` with a new `macOS/Resources/MPXPrimeMeter-Info.plist` (own `CFBundleIdentifier`/`CFBundleName`, icon, `LSUIElement=false`), ad-hoc codesign, and include it in the DMG — mirroring the existing `MPXPrime.app` steps. Bump versions together; one README/CHANGELOG.

## Critical files
- Phase 0: `macOS/Sources/MPXPrimeCore/AudioDevices.swift` (+ `InputAUHAL.swift` if the rate-set happens there), `macOS/Sources/MPXPrimeMeter/{MeterAudioEngine.swift,main.swift}`
- `macOS/Package.swift`
- New: `macOS/Sources/MPXPrimeUI/{BroadcastStyle,VerticalMeterStrip,LiveTelemetryView,ScopeView,MPXSpectrumView}.swift`
- Edit (extraction): `macOS/Sources/MPXPrime/{SwiftUIControlApp.swift,UIBroadcastStyle.swift,UIBroadcastMeter.swift,UILiveTelemetry.swift}` + `import MPXPrimeUI` across transmit files
- Meter: `macOS/Sources/MPXPrimeMeter/{MeterAnalysis.swift,main.swift}` + new `{MeterAppDelegate,MeterTelemetry,MeterViewModel,RootMeterView}.swift`
- `build-release.sh`, new `macOS/Resources/MPXPrimeMeter-Info.plist`

## Verification
1. `swift build` debug + release, both apps — clean, 0 warnings.
2. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` — green.
3. `swiftlint` — 0.
4. `MPXPrime --verify --baseline-strict` and `--verify-receiver --baseline-strict` — exit codes UNCHANGED (extraction didn't perturb transmit DSP).
5. Transmit GUI smoke: Scopes/Spectrum/Levels windows visually unchanged.
6. Meter `--gui` smoke (`bin/fm-sdr-tuner` or device 0): window opens; scopes/spectrum/meters/RDS update live; no freeze. Device picker (re)starts capture.
7. Long-run soak (Meter `--gui` open, hours/accelerated): GUI stays responsive; confirm via Instruments the VM `objectWillChange` is quiet between RDS changes (the historical-freeze regression guard).
8. `./build-release.sh <ver>` produces `MPX Prime Meter.app` + DMG; double-click launches the GUI.

## Riskiest steps
- Extracting `ScopeView`/`MPXSpectrumView` from the 9k-line file (Commit 4): mechanical but brace-error-prone — diff-stat + call-site count + immediate build.
- `BroadcastStyle` going public touches many transmit files via missing `import MPXPrimeUI`: `--verify*` baselines + transmit-GUI launch are the gate.
- Snapshot deep-copy (Commit 5): every new `[Float]` MUST be `.map{$0}`-copied in `isolatedSnapshot()` — the single most important line-level requirement (re-introduces the heap-corruption crash if missed).
