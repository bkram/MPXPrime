# Changelog

Versions are sequential point releases (0.7 → 0.8 → 0.9 → 0.10 → 0.11 → 0.20 → 0.21),
not decimals. 0.20 was a deliberate jump from 0.11 to mark the magnitude
of the post-0.11 work — composite clipper differential topology with
linear-phase FIR decimation, RDS live-apply for the full operationally-
toggled surface, GUI restructure with status-first Control tab,
PrimeBass (renamed from Orbass) with MaxxBass / Aphex / Werrbach
patent-grade harmonic synthesis, adaptive on-screen FPS, and an
optional deep DSP combination test suite. Newest first.

## 0.21 — 2026-05-09

### Docs
- **Patent-attribution list complete.** The "Compared to commercial processors" paragraph in README previously credited only `US 4,460,871` and `US 5,737,434` (the 0.11 references). Updated to list all six expired patents whose published claims are used as design references: those two (Orban distortion-cancelled composite clipping) plus `US 6,337,999` (Orban differential composite clipper topology, expired 2022), `US 5,930,373` (Waves MaxxBass equal-loudness harmonics, expired 2017), `US 4,150,253` (Aphex Aural Exciter pre-waveshaper topology adapted for bass via allpass, expired 1996), and `US 5,424,488` (Werrbach transient-discriminate harmonic gain, expired 2013). Each linked to Google Patents; framed as public-domain prior art, not licensed reproductions.
- **Trademarks and affiliations** subsection added to README. Names referenced descriptively throughout the project (Orban, Optimod, Omnia, Stereo Tool / Stereotool, Aphex, Waves / MaxxBass, BBE, DTS, Music Tribe, Inovonics, DEVA, Audemat, BW, JUCE, Qt, Apple, macOS / AVFoundation / CoreAudio / vDSP / vForce, JACK, ALSA, AES3, DAB+, Livewire, Dante, Ravenna) are trademarks of their respective owners; MPX Prime is independent and not affiliated with any of them. The PrimeBass rename in 0.20 was specifically to remove the unintended trademark adjacency to Orban.

No source changes vs 0.20. Audio path bit-identical; binary identical except for the `appVersion` string.

## 0.20 — 2026-05-09

### Added
- **Optional deep DSP combination test suite.** New `DeepDSPTests.swift` adds an opt-in test suite that catches stage-interaction bugs the existing per-stage tests miss. Five layers: (1) per-stage isolation smoke tests for the previously-unstested stages — Phase Rotator, Parametric EQ, Mono Bass, Stereo Widener, BS.412, Pre-encode limiter, DC clipper, 3-band multiband, multiband limiter, encoder FIR, final MPX safety limiter (12 tests). (2) Universal invariants on 200 deterministically-seeded random valid configs × 7 adversarial programs (HF-rich pop / sustained bass / percussive transients / pink noise / silence / DC offset / full-scale step) — asserts no NaN / inf, composite peak ≤ 1.05, pilot RMS within tolerance when stereo subcarriers are emitted, RDS energy present when active. (3) Pairwise enable/disable matrix on 11 high-impact stage flags (12 covering rows). (4) Counteract detection — for 10 suspect pairs (AGC × Multiband, PrimeBass × BassClipper, CompositeClipper × BS.412, Pre-encode × CompositeClipper, Widener × MonoBass, etc.) renders A-only / B-only / A∧B and asserts no amplitude conspiracy (combined peak ≤ max single × 1.10) and no cancellation conspiracy (combined 1 kHz energy ≥ min single − 6 dB). (5) Per-preset safety check on five 5-band presets (`5_ac`, `5_talk`, `5_chr`, `5_rock`, `5_dance`) × three programs. The whole suite is gated behind `MPXPRIME_DEEP=1` so the default `swift test` stays at ~10 s; running deep takes ~4 min on M1. Invocation: `MPXPRIME_DEEP=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path macOS --filter Deep`.

- **Bass enhancer renamed `Orbass` → `PrimeBass`.** The previous name read as a portmanteau of "Orban bass" — too close to a registered broadcast-equipment trademark for comfort. New name anchors to the MPXPrime brand. Renamed across Swift identifiers (`primeBassEnabled`, `processPrimeBass`, etc.), UI labels, INI keys (`primebass_enabled`, `primebass_amount`, ...), and tests. **Backwards compatibility:** the legacy `orbass_*` INI keys are still read as fallback values when the new `primebass_*` keys are missing, so existing user configurations keep working. The legacy keys will be removed in a later release. INI files written by the app now emit only `primebass_*`.
- **PrimeBass Phase 2: Werrbach transient-discriminate harmonic gain** (Aphex US 5,424,488, expired 2013-06-08 — public domain). The harmonic-band gain in `processPrimeBass` is now modulated by a dual-envelope transient detector: a fast follower (~5 ms attack / 30 ms release) tracks the LF input's leading edge while a slow follower (~50 ms attack / 250 ms release) tracks its baseline. Their normalized difference saturates positive on real onsets (drum hits, plucked-bass attacks) and decays to zero as the slow follower catches up — typically within 50–150 ms of the burst. Mapped onto a 0.7×–1.4× gain range, this gives a brief harmonic burst on attacks and a lower sustain floor on continuous program — the "punchy not boomy" character of the original Aphex Sound Enhancement System. Average HF energy on continuous program drops by ~3 dB versus a static gain (which indirectly helps the verifier `>67k/in` metric on sustained material), while peak-attack harmonic intensity is preserved. New `transientGainBurstsOnAttackAndDecaysOnSustain` test verifies the gain modulator's behaviour at three known time points (pre-onset / 25 ms post-onset / 350 ms sustained) via an internal accessor — direct-state inspection rather than spectral analysis, since FFT measurement of harmonics this close to the fundamental gets muddied by window leakage at FFT sizes practical for short bursts.
- **PrimeBass Phase 1: MaxxBass equal-loudness harmonics + Aphex phase-shift topology** (Waves US 5,930,373 expired 2017, Aphex US 4,150,253 expired 1996 — both public domain). The harmonic-synthesis stage in `processPrimeBass` now produces separately-weighted *even* (2nd / 4th, asymmetric squarer) and *odd* (3rd / 5th, tanh difference) harmonic terms, each multiplied by an ISO 226 phon-curve approximation evaluated at the harmonic frequency at configure time. Pre-waveshaper allpass biquad at the configured F0 rotates phase ~180° without amplitude loss, so the synthesised harmonics are phase-decorrelated from the direct lowboost path (the bass-extension adaptation of Aphex's HP-then-clip topology — a HPF would attenuate F0 itself). Direct LF gain is tapered down with the harmonics knob (`primeBassDirectGainReduction = 0.62`): perceived bass is now carried more by the weighted harmonics, less by raw LF amplitude — buys headroom in the bass clipper and pre-encode limiter without changing subjective bass weight (the existing makeup-gain stage compensates absolute level). New `PrimeBassMaxxBassTests` suite (4 tests) verifies harmonic generation, F0/harmonic balance shift with the harmonics knob, equal-loudness shape (3rd > 5th near 80 Hz F0), and clean pass-through with PrimeBass off. Tests use a mono-mode minimal-chain `MPXGenerator` render so the composite output equals baseband audio. The default verifier baseline (PrimeBass off) is bit-identical to the previous build — the audio path itself only changes when PrimeBass is enabled, by design.

- **Composite clipper modernised: linear-phase FIR decimation + differential topology** (Orban US 6,337,999, expired 2022 — public domain). New `LinearPhaseFIRDecimator` struct (Kaiser-windowed sinc, ~147 taps, `vDSP_dotpr` polyphase) replaces the prior `BiquadCascade6` 12th-order Butterworth as the OS-rate decimation filter. `CompositeClipper.process` restructured so only the *clipping residual* goes through the decimator while the wanted signal rides a 1× delay-matched bypass — the decimator's stopband leakage and any phase non-flatness now only colour the residual subtracted at output, not the wanted signal itself. Per-band IM cancellation still works: cancelled bands are subtracted from the residual before decimation. Net behaviour: flat passband response across 0–53 kHz (versus Butterworth's 1–2 dB rolloff at the upper subcarrier edge), 90 dB FIR stopband (versus Butterworth's ~70–80 dB), and no decimator-induced phase rotation on the wanted (L−R) sidebands. Cost: ~9 host samples (~47 µs at 192 kHz) of TX-path latency. Cross-domain cancellation depth on the synthetic test drops 1–2 dB (architectural trade-off; receiver-perceived behaviour is improved). Reference: Kahles, Esqueda, Vаlimaki (JAES 2019) on filter choice for nonlinear waveshaping.

- **Comprehensive RDS live-apply.** Every operationally-toggled RDS setting now applies to the running encoder without a transport restart. Previously only RT/PS text content was live; the rest required engine cycle. Now live: master `enRDS`, `rdsPI`, `rdsPTY`, `rdsPTYN`, `rdsECC`, `rdsLIC`, `rdsTP`, `rdsTA`, `rdsMS`, all four `rdsDI_*` bits, RT text + buffers + mode + cycle, PTYN text + enable + centering, Long PS text + enable + centering + CR, AF enable + list + method, group sequence, scheduler auto/standard/standard-LPS, CT/ID/TZ/LIC. Only restart-only settings remaining are physical-layer (`rdsLevel` injection kHz, `rdsFreq` subcarrier, Gaussian shaping FIR taps/BW). `RDSRuntimeConfig` struct expanded from 17 fields to 38; consolidated `RDSRuntimeConfig.make(from: AppConfig)` factory is the single source of truth used by both `AudioOutputEngine.applyRDSRuntimeConfig` and the test suite. `BasicRDSCoder.applyRDSRuntimeConfig` rebuilds derived caches (PTYN/Long PS frames, group schedule) only when relevant inputs change. New `RuntimeChangeDisposition.liveRDS` case routes RDS-only edits through `applyLiveRDSConfigIfRunning` (parallel to the existing `.live` for DSP edits).
- **RDS GUI restructure with status-first Control tab.** New top-level Control tab is the default RDS landing page: master Enable, RDS injection level, live PI/PS/RT readout, and runtime flags (TP/TA/MS/DI). Detail tabs reorganised per UECP message-class taxonomy: Identity (PI/PTY/PTYN/ECC + PS banks), Radiotext (RT/RT+/Now Playing), Long PS, Alt. Frequencies (split out — was buried in Flags), Schedule (group sequence + clock — split out from Carrier), Subcarrier (physical layer only). Old Flags tab removed; TP/TA/MS/DI now live on Control where operators expect them. Snapshot card moved from Identity to bottom of Control. Modeled on DEVA SmartGen 5 / BW RDS3 / Audemat conventions.
- **AF Method B encoding (IEC 62106-2 §7.5.3 / EN 50067 §3.2.1.6.4).** Group 0A block C now correctly emits the paired `(tuned, alt)` Method-B variant when `rds_af_method = B`. Previous code dispatched everything through Method A. Convention: `afCodes[0]` is the tuned frequency; `afCodes[1...]` are alternatives. Receivers deduce Method B from the repeated tuned frequency. EN 50067 12-pair cap honoured. Three new tests cover first-block layout, subsequent-block cycling, and Method-A vs Method-B byte-stream divergence.
- **TA-flag auto-injection (UECP §2.5.1.1).** TA-flag transitions now force an immediate Group 0A ahead of the regular schedule. Traffic-aware receivers see the flag flip within one group time of the operator pressing the TA button, regardless of whether the configured schedule is 0A-heavy or sparse. Previously TA edges had to wait for the next scheduled 0A — potentially hundreds of ms with a 2A-heavy custom schedule. Three new tests cover both edges (off→on / on→off) and confirm non-TA config changes do not trigger spurious forced 0As.
- **MOD chip in broadcast status bar.** The persistent header bar now shows MPX modulation as a percentage (`peak_dev / configured_dev × 100`) alongside the existing kHz DEV chip — the standard Stereotool / Omnia / Optimod readout. Width 80 pt; same colour thresholds as DEV (green safe / amber tight / red over).

### Changed
- **`Date()` deferred from audio render thread.** The RDS encoder's PS / RT / PTYN / Long PS sequence-advance helpers and `applyRDSRuntimeConfig` seq-start markers were calling `Date().timeIntervalSinceReferenceDate` on the audio thread. Replaced with `BasicRDSCoder.monotonicSeconds()` (`@inline(__always)` wrapper around `ProcessInfo.systemUptime`, commpage-backed `mach_continuous_time`, no syscall). 9 audio-thread `Date()` reads removed. Two `Date()` calls intentionally retained: `refreshClockCache` runs on the background `clockUpdateQueue` and needs wall-clock for CT (4A) generation; the RT `{time}/{date}` macro substitution path also needs wall-clock and is handled separately (its DateFormatter cost dwarfs the `Date()` call).
- **CT live-toggle now starts the clock-cache timer.** Enabling `rds_enable_ct` via runtime config without a restart now correctly primes the clock cache and starts the per-second update timer. Previously the cache only initialised at engine init, so live-enabling CT after start emitted Group 4A frames with stale data until the next restart.

### Removed
- **Per-band Multiband gain-reduction meter.** Built and iterated through four smoothing topologies (peak-hold + multiplicative decay, asymmetric one-pole, peak-hold + linear decay at 30 dB/s, peak-hold + linear decay at 6 dB/s); none produced visible meter movement on real program material. Root cause was a combination of compressor producing tiny GR values on default-tuned program, UI sample-rate mismatch with display ballistic, and display scale choices. Cut the feature cleanly: removed `MonoCompressor.lastGainReductionDB`, the five smoothed per-band fields, decay coefficient, `MultibandStatus` struct, `multibandStatus` getter, the per-sample write-throughs in `processThreeBandMultiband` / `processFiveBandMultiband`, the `MeterSnapshot` per-band fields, the `multibandBandGRDB` view-model array, and the `MultibandGRRow` view. Dead-code grep confirms zero residual references.

### Fixed
- **VSCode SourceKit "not in scope" phantom diagnostics for `StageInspector` and `SignalFlowStrip`.** `Package.swift` lives in the `macOS/` subdirectory rather than the workspace root. Without a workspace setting, the Swift extension's sourcekit-lsp didn't discover the SPM target and fell back to single-file compilation mode for individual `.swift` files — each file analysed in isolation, with no knowledge of sibling files in the same target. New `.vscode/settings.json` sets `swift.searchSubfoldersForPackages: true`; window reload required for the setting to apply.

### Tests
- **+23 tests across the new RDS live-apply suite (204 → 227 across 25 → 26 suites):**
  - `RDSLiveApplyTests` (17) — covers PI / PTY / PTYN / Long PS / AF list / group sequence / CT-enable round-trips through `applyRDSRuntimeConfig`, master-enable disengage cleanly, runtime config factory roundtrip, AF Method B encoding (3 tests), TA-edge auto-injection (3 tests).

### Added
- **Configurable PS rotation default duration.** New `rds_ps_frame_seconds` INI key (default 3.0 s, range 0.5–10 s). Sets the per-segment duration when PS text has no explicit `Ns:` / `Nt:` timing marker. Stereotool-style markers (`3s:NEWS/4s:WEATHER`) still take precedence — the configured default only kicks in for unmarked text. Live-applied via `RDSRuntimeConfig.psFrameSeconds`. New PS Frame slider in the RDS Program tab. `PSFrameSecondsTests` locks in marker-precedence behavior.
- **Auto-start input stall watchdog.** `applicationDidFinishLaunching` now arms a 1.5 s watchdog after auto-start that detects the AVAudioEngine first-start input stall (`isRunning == true` but ring stays at 0 frames) and triggers an automatic Stop+Start cycle. Mirrors the manual recovery the user was doing by hand. Marked `WORKAROUND` inline; the proper fix (replacing AVAudioEngine input capture with a direct AUHAL render callback) is tracked in plan.md.
- **`os.Logger` instrumentation in input capture.** Subsystem `com.mpxprime.app`, category `input-capture`. Logs permission status, `setCurrentDevice` outcome, `inputFormat`, tap install, capture start, first tap callback (frames + peak), and a 2 s "tap has not fired" warning. Stream via `/usr/bin/log stream --predicate 'subsystem == "com.mpxprime.app"'` to diagnose future input issues without rebuilding.
- **Microphone permission gate.** `AudioOutputEngine.start()` now calls `AVCaptureDevice.requestAccess(for: .audio)` synchronously when `useInputSource` is true and TCC status is `.notDetermined`. Eliminates the first-launch race where the engine would start before the system permission prompt resolved.

### Changed
- **RT+ scheduling.** Two fixes after operator-reported intermittent RT+ display on car radios:
  - 11A is suppressed (replaced by 0A in the schedule slot) when `rtPlusTags` is empty. The previous all-zero-content-type 11A read as "RT+ withdrawn" on Pioneer / Sony receivers and made RT+ flicker on / off as content changed.
  - Auto schedule appends 3A every cycle (~2.3 s) instead of every other cycle (~4.5 s). Receivers that need to see AID 0x4BD7 within 5–10 s of tune-in are now well inside the window.

### Fixed
- **Levels window meter strip readability.** Replaced `.fixedSize()` on each strip's value Text with `.minimumScaleFactor(0.6)` + `.frame(maxWidth: .infinity)`. Long readouts no longer spill into adjacent meter columns. Strip the trailing `"   N.N pk"` suffix from the value text on vertical strips — the white peak-hold tick already conveys peak position visually, so the duplicate text only added clutter and overflowed the 58 pt column.

### Removed
- **Loudness meter + `MonitorLoudnessAnalyzer` DSP path.** Dropped the Loudness card from the Levels window plus its entire backing DSP plumbing (K-weighting biquads, energy ring buffer, momentary / short-term / integrated LUFS gating, `setAnalysisCapture(loudness:)` parameter, ~200 lines total). Operator feedback was that the on-screen LUFS readouts were noise — broadcast loudness is judged on the receiver, not in the GUI. The audio thread no longer runs the per-sample K-weighting on the monitor path.
- **Dead `HelpSectionView` struct (~40 lines).** Defined but never instantiated — leftover from an earlier Help layout that was superseded by `HelpInputLevelsView` / `HelpRDSTextView`.

### DSP audit (perf / correctness, output bit-identical)
- **Cached RDS auto / standard schedules.** `generateAutoSchedule` / `generateStandardSchedule` were called from `nextGroupBits` on every group (~11×/sec at the RDS bitstream rate), each call allocating a fresh `[RDSGroupSpec]`. After the post-0.11 RT+ fix the schedules became pure functions of feature flags, so they can be cached. Schedules now rebuild only on init and when `rtMode2B` / `rtPlusEnabled` toggle in `applyRDSRuntimeConfig`. Removed the dead `scheduleGenerateCounter` (still incremented but never read after the RT+ change). Output verified bit-identical via `--verify --baseline-strict`.
- **Reused 104-byte `bitBuffer` in `buildGroupBits`.** Each `buildGroupBits` call previously allocated a fresh `[UInt8]` of capacity 104, plus an inner 4-element `[block1..block4]` array literal — both ~11×/sec on the audio thread. `bitBuffer` is now pre-allocated once and subscript-assigned in place; CoW gives test callers their own logical array on retention. The block iteration uses an unrolled `writeBlockBits` helper with explicit offsets. Output verified bit-identical via `--verify --baseline-strict`.

### Tooling / docs
- **DMG bundled INI now matches the canonical sample.** `build-release.sh` previously hand-authored a stub config with lowercase / spaced section headers (`[ mpxprime ]`, `[pilot ]`, etc.). The parser only recognises canonical uppercase `[MPX]` / `[RDS]` / `[INTERFACES]`, so every value in those mismatched sections silently fell back to AppConfig defaults — most visibly `preemphasis_us = 75` in the template was being ignored, so US-region operators got 50 µs pre-emphasis after a fresh install. Replaced the heredoc with `cp macOS/MPXPrime.ini` so the DMG ships the same canonical INI that `SampleINIRoundTripTests` already validates.
- **Help window updated for the post-0.11 PS frame seconds.** The "Untimed plain text" help line now distinguishes single-chunk (10 s hold) from multi-chunk (configurable PS Frame default for PS, 2.5 s for RT / PTYN / Long PS).

### Tests
- **+38 tests across 5 new suites** — 166 → 204 across 18 → 25 suites:
  - `PSFrameSecondsTests` (6) — locks in marker-precedence semantics for the new configurable default.
  - `AppConfigInvalidInputTests` (8) — type coercion robustness (garbage numerics, bool synonyms, empty values, inline comments, unknown sections).
  - `RDSSchedulerCadenceTests` (8) — auto / standard scheduler cadences including the 3A-every-cycle regression guard.
  - `RDSBitBufferReuseTests` (5) — alloc-free `buildGroupBits` correctness (first-call validity, CoW, no cross-call leakage).
  - `FilterPrimitiveTests` (11) — direct coverage for `Lagrange4Interp`, `LinkwitzRiley4`, `BiquadCascade6`.

## 0.11 — 2026-05-06

### Added
- **Linear-phase FIR multiband crossovers (TX path).** Replaces the IIR LR4 cascade with Kaiser-windowed-sinc FIR splitters that all share group delay, so summed bands reconstruct the input delayed-by-`groupDelaySamples` exactly (–155 dB sum-to-flat error floor). Eliminates the inter-band phase rotation that smears transients and the inter-band gain-modulation that causes spectral pumping when bands compress at different rates — the core reason multiband-on tended to sound worse than multiband-off on percussive material in 0.10. New `LinearPhaseFIRSplitter`, `LinearPhaseMultibandSplitter3`, `LinearPhaseMultibandSplitter5` structs (simultaneous-split / parallel-cumulative-LP topology). Monitor mode keeps the low-latency LR4 path. New `multiband_fir_enabled` INI key (default true), restart-required. Latency cost: ~5.3 ms at 192 kHz with the default 90 Hz lowest crossover (the binding constraint for Kaiser-FIR transition width).
- **vDSP-backed FIR convolution.** `LinearPhaseFIRLowpass.process` now runs through `vDSP_dotpr` instead of a pure-Swift accumulator loop, with a double-buffered delay line so the read window is always contiguous. ~5–10× speedup measured against the manual loop; FIR-path multiband ends up only ~24% more expensive than the IIR path, well inside real-time budget. Without this acceleration the multiband-FIR path overruns budget on most machines (manifested as audio crackle + RDS BCH corruption from sample dropouts). New `DSPThroughputTests.multibandFIRStaysInsideRelativeBudget` guards the FIR/IIR cost ratio (<5×) so a regression that bypasses vDSP would surface immediately rather than at user-facing dropout time.
- **vvtanhf-batched soft-clipping in oversampled clippers.** `CompositeClipper`, `BassClipper`, and `DistortionCancelledClipper` previously called scalar `tanhf` per oversample step (8 / 8 / 16 calls per host sample respectively). The clippers now restructure their `process()` into a 3-phase pattern — pre-compute oversampled inputs, batch the `tanhf` evaluation through `vvtanhf` on the gathered N-element buffer, then run the per-OS-step filter cascades using the precomputed clipped values. Measured on Apple Silicon: 8-element batches give ~5× speedup vs scalar; 16-element batches give ~9×. Output is bit-exact identical (vvtanhf uses the same math kernel as libm tanhf) — verifier strict baseline unchanged. New `TanhBatchSizeBench` micro-benchmark documents the batch-size/speedup curve so the trade-off stays visible.
- **Italo / Pump multiband presets (`5_italo`, `3_italo`).** Tempo-synchronised low-band release tuned for 120 BPM four-on-the-floor — at `5_italo` the band-2 (kick band, 80–280 Hz) effective release sits ~90 ms = ~18% of a quarter note for audible kick-driven ducking, while the high band stays light (1.3:1, 100 ms) so cymbals and synths sparkle. Lower link strength (0.30 vs 0.52 default) widens the bass image. Research-backed against published EDM/dance mastering practice and Orban Optimod dance-preset design. Selectable from the Multiband preset picker.

### Changed
- **Default `multibandIntensity` `light` → `normal`** + per-band AppConfig defaults updated to the published `5_ac` recipe (no Light multiplier baked in). The previous "Light" intensity offset thresholds +1.5 dB and scaled ratios ×0.9 — combined with the soft-knee soft-release `5_ac` numbers, the result was a multiband chain so transparent operators reported it sounded like nothing was happening. Normal is audible but still clean; Light is still a one-click option in the picker for operators who want maximum transparency.
- **Default audio block size 2048 → 1024.** Drops TX-path latency by ~5 ms (10.7 ms → 5.3 ms of block-driven delay at 192 kHz) for tighter off-air monitor sync. No quality cost — just more callbacks per second. Chain is throughput-validated at blockSize 512 by `DSPThroughputTests`, so 1024 has comfortable headroom. Operators on lower-CPU machines can revert via `blocksize = 2048` in INI.

### Fixed
- **Composite clipper pilot / RDS guard regression.** During the post-0.10 clipper rewrite the `cancelPilot` / `cancelRDS` flags became no-ops because the documentation rationale ("subcarriers inject post-clipper, so receiver doesn't see clipper IM in those bands") was wrong — clipper IM at 19 kHz / 57 kHz vector-sums with the cleanly-injected pilot and RDS at the receiver, masking pilot PLL lock and adding noise to RDS demodulation. With audio-band clipping engaged (the new `cancel_audio = false` default), this manifested as RDS being readable when the chain was stopped but corrupted when it was running. Fix: replaced the inert pilot/RDS LR4 cancellation paths with RBJ bandpass biquads centred at 19 kHz (Q=4) and 57 kHz (Q=14). Centre-frequency cancellation now drops pilot and RDS regions to –80 / –127 dBFS under hot drive. New `clipperKeepsPilotAndRDSCentreFrequenciesClean` test guards this.
- **Composite clipper no longer collapses HF stereo image.** The 0.10 cross-domain cancellation used 2× cascaded LR4 splits at 23 / 53 kHz to bound the stereo subcarrier band. The cascade gives -12 dB at the corners, which attenuated the (L-R) DSB-SC subcarrier sidebands generated by HF audio (~10–14 kHz panned content modulating to 24/52 kHz) and visibly collapsed stereo image at the receiver. The new clipper uses a single-LR4 split with the stereo cutoff moved from 23 to 22 kHz so the actual 23–53 kHz subcarrier sits in the passband, not on the corner. Sideband preservation now within ~1 dB across the full HF audio range; new `CompositeClipperStereoSeparationTests` suite locks this in.

### Removed
- **`CompositeTruePeakLimiter` deleted.** The composite-domain limiter used `|composite|` peak detection (driven hardest by stereo subcarrier crests) and a memoryless `tanhf` ceiling that produced intermod across 23–53 kHz, demodulating as `(L-R)` cancellation at the receiver — i.e. it actively destroyed stereo separation when enabled. The old struct's per-channel use inside `PreEncodeAudioLimiter` (audio-domain L/R limiting, where the failure mode doesn't apply) was preserved by renaming it to `OversampledPeakLimiter`. The composite-domain instance, chain call, UI toggle, preset field, and `compositeLimiterGainReductionDB` telemetry are gone; the meter's headroom-reduction value is now sourced from the composite clipper.
- **Legacy INI key `composite_clipper_enabled` removed.** This key was wired to the (now-removed) composite limiter, not the clipper — flagged as a sharp edge in `CLAUDE.md`. The actual composite clipper toggle stays at `mpx_clipper_enabled`. INI files containing the old key will silently lose that setting; the limiter no longer exists, so this is a no-op for output behaviour.

### Changed
- Composite clipper `cancel_audio` default flipped `True → False`. The old default with the substitution algorithm made the clipper a near no-op for peak reduction; the new delta-based algorithm under `cancel_audio = False` keeps the audio band fully clipped (which is where the loudness lift comes from) while still preserving subcarrier integrity via `cancel_stereo`.
- Composite clipper `cancel_pilot` and `cancel_rds` defaults flipped `False → True`. They were stubs in 0.10; the new algorithm actually subtracts clip residual in the 17–21 kHz pilot guard and 55–59 kHz RDS guard, so receiver-side pilot PLL lock and RDS BER are no longer corrupted by clipper IM in those bands.
- Existing `audioBandCancellationDropsMonoIM` and `stereoBandCancellationDropsCrossDomainMixingProducts` cross-domain tests relaxed from >20 dB / >10 dB to >3 dB / >7 dB drops respectively. The delta-based cancellation is bounded by LR4 phase rolloff in the protected bands; the trade-off (less aggressive cancellation depth, full sideband preservation) is intentional and what fixes the user-reported "stereo image disappears" issue.

## 0.10

### Added
- **Composite clipper: cross-domain IM cancellation via Linkwitz-Riley substitution.** Splits both the clipper input and its clipped output into 4 bands at 15 / 23 / 53 kHz crossovers, then substitutes the clean input band for the distorted clipped band in the audio (0-15 kHz) and stereo subband (23-53 kHz) regions. LR4 LP+HP form a phase-coherent allpass pair so the cancellation is delay-matched. Measured drops on the cross-domain IM test suite: M³ at 3 kHz drops 56 dB with audio cancellation; M²·S at 2400 Hz drops 12-14 dB with stereo cancellation; combined hot-drive cleanup −39 dBFS → −64 dBFS. Inspired by Orban US 5,168,526 + US 6,434,241 (both expired and public domain). New INI keys `mpx_clipper_cancel_audio` / `mpx_clipper_cancel_stereo` (live-apply, default true).
- **Wideband AGC broadcast-grade upgrade.** K-weighted detector (BS.1770-flavoured HPF ~38 Hz Q 0.5 + high-shelf +4 dB @ ~1.5 kHz) on the detector sidechain. Program-dependent release tracks fast-vs-slow envelope divergence (50 ms vs 1 s); effective release scales 1×–3× with a ~0.5 s smoothed density estimate. Release cap extended from 1.2 s to 5 s. Toggleable via `agc_k_weighting` and `agc_release_program_dependent` (default on).
- **Linear-phase FIR brick-wall 15 kHz on TX path.** Kaiser-windowed FIR replaces the Butterworth program lowpass when running in composite output mode. ≥80 dB stop-band at 17 kHz, ≈1.67 ms group delay at 192 kHz. Monitor mode retains the Butterworth cascade for low latency. Config toggle `encoder_fir_enabled` (default on).
- **Stereo Tool-compatible RDS text grammar.** Fractional `Ns:`, `Nt:` transmit-count, `/` top-level separation, escape handling for `< > | : / \\`, `||` word-wrap toggle (no-op), `<`/`>` scroll markers for PS with speed-by-repeat, `\F`/`\f` file-load aliases for `\R`/`\r`. Pure parser extracted to `RDSTextParser.swift` with early-exit escape encode/decode.
- **4 PS banks with exclusive active selector.** `rds_ps_a/b/c/d` + `rds_ps_active_bank`. Live-apply via `RDSRuntimeConfig` — switching active bank rebuilds the PS sequence without engine restart. INI migrates legacy `ps_dynamic` into bank A.
- **Live RDS snapshot in Monitoring.** Monitoring card now reads the actual transmitted PS, RT, PTYN, Long PS from the running coder — not a UI-side simulation. Writes guarded by `OSAllocatedUnfairLock` so UI contention never stalls the render callback.
- **Broadcast-console look pass.** Orban Optimod silhouette, HIG-compliant, follows system appearance. `BroadcastStatusBar` pinned under window chrome shows transport + IN L/R / MPX / DEV / GR / SAFE / BUDGET / PILOT / RDS on every screen. Monitoring embeds compact scopes and MPX spectrum with pop-out arrows. Processing gains an Overview grid (13 stage cards) as the default landing tab. Levels window uses 8 vertical meter strips. RDS snapshot cards use a dark meter-plate style.
- **57 tooltips (`.help`) across DSP controls** covering AGC, Orbass, Parametric EQ, Multiband, Stereo Widener, Composite Limiter, Phase Rotator, Bass Clipper, DC Clipper, BS.412, Composite Clipper.
- **107 new tests across 9 suites** including RDS parser/orchestration/advance/bitstream/signal/PS-bank coverage, DSP throughput regression suite, encoder bandwidth FIR characterisation, and cross-domain IM cancellation regression guards. 141 tests / 14 suites green.
- **macOS HIG polish** — Edit menu (Cut/Copy/Paste/Undo/Redo + Emoji & Symbols + Start Dictation), Close Window ⌘W, Start/Stop on ⌘Return, Scopes on ⇧⌘0, accessibility labels, semantic colors, Dynamic Type on meters.
- **Sane out-of-box defaults.** AGC on, multiband on (5-band AC/Pop, light intensity), bass clipper on, composite clipper on with cross-domain IM cancellation. Stereo widener and Orbass off (responsible defaults — both color the signal and degrade fringe-listener SNR). BS.412 off (US default; EU operators flip to True). Sample `MPXPrime.ini` rewritten to mirror these defaults with rationale comments per stage. A fresh install audibly outperforms `mpxgen` / PiFmRds with zero operator action.

### Changed
- AGC release cap extended 1.2 s → 5 s; defaults retuned to "Pop Medium" range (target -14 LUFS, range 20 dB, attack 6 ms, release 1.5 s).
- Multiband default intensity changed `normal` → `light` (thresholds offset +1.5 dB, ratios ×0.9).
- Composite clipper default thresholds tightened −3.0 / −0.5 dB → −1.0 / −0.3 dB so it actually engages on real program.
- Pre-emphasis confirmed in M/S domain inside `makeCompositeComponents`. Guarded by `DSPThroughputTests.preEmphasisDoesNotExplodeFullChainCost`.
- `RT dynamic-sequence cache` skips `parseTimedSequence` and `expandNowPlayingMacros` on the audio thread when inputs are stable.

### Fixed
- `composite_clipper_enabled` INI key collision documented in sample INI comments — that key is the composite *limiter* (legacy name); the actual composite clipper uses `mpx_clipper_*` keys.

## 0.85

### Added
- Configurable now-playing script support in the RDS Radiotext section with native file picker, poll interval, timeout, and runtime status display
- Radiotext macro expansion for now-playing metadata: `{now_playing}`, `{display}`, `{artist}`, and `{title}`
- Additional Radiotext template macros: `{date}` and `{time}`
- README documentation for the expected now-playing script output format and RT/RT+ configuration
- Broadcast preset picker for the final MPX stage: `Balanced Music`, `CHR / Dance`, `Punchy Music`, and `Speech / Talk`
- Final-stage limiter telemetry in Monitoring and DSP Overview showing live and held gain reduction
- Composite calibration telemetry showing pilot %, RDS %, audio-composite peak, budget margin, and a `Safe` / `Tight` / `Risk` composite-budget state
- Dedicated `Mono Bass` stage with configurable crossover in the Widener tab
- Orbass preset/config wiring for density and subharmonics, with the adaptive Orbass path now active in the live DSP chain
- Offline MPX verification mode with deterministic scenarios and exit codes
- Long-run compliance/regression verification mode:
  - `--verify-long`
  - focused on `program_mix`, `bright_dense`, `vocal_sibilant`, `transient_push`, and `wide_bass`
- Additional audible-quality verification scenarios:
  - `bright_dense`
  - `vocal_sibilant`
  - `transient_push`
  - `wide_bass`
- Preset-sweep verification mode:
  - `--verify-presets`
  - focused on `5B AC/Pop`, `5B CHR/EDM`, `5B Rock`, `5B Talk`, `5B News`, `5B Urban`, and `5B Dance`
- Window frame persistence for the main window and utility windows

### Fixed
- RT+ tagging now uses structured now-playing metadata more reliably for artist/title extraction
- RT+ tag ordering now follows the field positions in transmitted radiotext
- Now-playing script failures and empty output now clear the active metadata, show a friendly `No Song Data` status, and discard the affected RT segment instead of leaving blank labels behind
- `output_gain_db` and `limit_mpx` are now active in the final render path
- Added a proper `Final Drive` stage ahead of composite limiting and improved composite limiter behavior
- `Mono Mode` now suppresses pilot, stereo subcarrier, and RDS so it behaves as a true mono composite mode
- Final drive now affects the audio-composite path without dragging pilot and RDS injection levels along with it
- The main composite limiter now runs before pilot/RDS sum, with the full-MPX limiter acting as a safety stage
- Stereo widener no longer behaves as a raw full-band M/S gain stage and now includes stereo-image protection
- Orbass was retuned to be substantially more conservative and less artifact-prone
- Multiband now uses complementary Linkwitz-Riley crossover stages instead of one-pole residual splits
- Multiband defaults and presets were retuned toward more realistic broadcast-style starting points
- `5B AC/Pop`, `5B CHR/EDM`, `5B Rock`, `5B Talk`, `5B News`, `5B Urban`, and `5B Dance` were tuned and verified against the focused preset sweep
- MPX width/compliance is now explicitly verifier-backed with encoder-side bandwidth guarding and a dynamic HF compliance guard ahead of stereo encode/pre-emphasis
- Processing and RDS reset buttons now only reset the active tab
- External config reloads now correctly preserve pending apply state

## 0.8

### Added
- Multiband dynamics presets (CHR/EDM, Rock, AC/Pop, Country, Talk, Urban, Dance, News, Jazz, Classical) with intensity control (Light/Normal/Heavy)
- FFT spectrum window toggle (96 kHz full / 60 kHz FM band)
- Reset Processing to Defaults button
- Default PTY set to Science
- Native MPX Prime app icon assets for runtime and release builds

### Changed
- Updated default RDS text to "MPX Prime: FM MPX + RDS Audio Processor"
- Unified window sizes for Scopes, Spectrum, and Levels windows (700x500, min 600x450)
- Processing section refactored with HIG-compliant plain Section style
- MPX spectrum display simplified (removed 19 kHz pilot marker)
- Window size constants centralized for easy configuration
- Main navigation reduced to Monitoring, Processing, and RDS; app-level controls moved into Settings
- Default config path changed to `~/Library/Application Support/MPX Prime/MPX Prime.ini`
- Default program lowpass changed to `16.4 kHz`
- Monitoring view and Settings were updated for more native macOS behavior and layout

### Fixed
- Level meters now properly displayed in Levels window
- Removed duplicate state variables in Processing section
- Main window close behavior now keeps the app running and supports reopen from Dock / Window menu

## 0.7

- Initial native macOS release built with Swift + SwiftUI.
- Real-time MPX generation using AVAudioEngine with AVAudioSourceNode.
- Input capture via AVAudioEngine input tap with ring buffer.
- Native macOS UI with SwiftUI sidebar navigation and monitoring dashboard.
- Phase-coherent stereo encoder with 19 kHz pilot and 38 kHz DSB-SC subcarrier.
- RDS encoding with EN 50067 biphase shaping and 57 kHz subcarrier.
- DSP features: input gain, wideband AGC, Orbass bass enhancement, multiband compression, stereo widener.
- Pre-emphasis support (0/50/75 µs) with HF trim control.
- Lookahead limiter for MPX protection.
- Lock-free real-time audio path with pre-allocated buffers.
- vDSP-accelerated metering for scope display.
