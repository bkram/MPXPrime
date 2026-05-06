# MPX Prime Roadmap

## Positioning

**Goal: the best amateur-grade free FM processor available.**

MPX Prime is *not* trying to be a $5–15k Optimod / Omnia / Stereotool replacement. It is trying to be the obvious choice for hobbyist, community radio, pirate, SDR-fed exciter, and DIY broadcast workflows where commercial processors are unaffordable or overkill. That framing is load-bearing for prioritisation:
yes
**Current focus: macOS.** Linux is on the future roadmap (see "Cross-platform" section below) but is not the current priority. Get the macOS experience exceptional first; widening to Linux is a separate later effort that benefits from a more mature DSP / preset / UX baseline.

**In scope** (amateur-grade differentiators):
- Just-works defaults — sounds good without expert tuning.
- Genuinely clean DSP — the cross-domain IM cancellation is competitive with patent-grade enterprise practice; the bar for clean output is high even at this tier.
- Lightweight install, sane defaults, readable INI, no studio integration overhead.
- macOS-native UI that respects HIG and gives operators a desktop control surface — the polished UI is what differentiates MPX Prime from headless / shell-only open-source alternatives.

**Out of scope** (enterprise-only, deliberate non-goals):
- MPX-over-AES3 / Baseband192 / AES10 transport. Amateurs don't have AES rack infrastructure; they want analog out, software-routed audio, or direct exciter feed.
- Studio automation integration (Livewire, Dante, Ravenna).
- Multi-site clustering, hot-swap redundancy, SNMP monitoring.
- ITU-R SM.1268 RF-mask feedback loop (Stokkemask) at production grade. *(Cheap simulation in the verifier is fine; real-time RF spectrum-analyser feedback is not.)*
- Multipath mitigation / L/R matrix limiter as Orban ships it.

**Deferred** (valid future work, not current focus):
- Linux port. Significant unmet need in the amateur LPFM / community-radio / Pi-station scene, but it's a multi-month effort and the macOS chain still has preset tuning, smoke-testing, and operator-facing polish that needs to land first. Re-evaluate once the macOS baseline is "great" rather than "good".

When evaluating a new feature, the test is "does this make MPX Prime sound or feel better for an amateur operator?" Features that only matter to a station with a $3M tower stack are out.

## Next up

1. **Preset tuning — make it sound great out of the box.** Composite clipper now ships clean (delta-based per-band substitution; (L-R) subcarrier sidebands within ~1 dB across the audio band). Time to push it. Tune `mpx_clipper_threshold_db`, `mpx_clipper_ceiling_db`, AGC density curve, and stereo widener defaults so a fresh install with no operator knowledge already sounds noticeably better than `mpxgen` / PiFmRds. Probably also: a small set of named presets (e.g. `clean`, `loud`, `community-radio`, `lpfm-conservative`) as INI fragments. Estimated scope: a focused listening session + tuning pass.

2. **Smoke-test pass.** Validate live-apply vs restart-required settings on difficult real material. Catch any transients / clicks / dropouts on toggle changes. Pre-release blocking item.

3. **Extend baselines to `--verify-presets` and `--verify-long`.** Same `VerifierBaselineFile` schema, different scenario sets. Once preset tuning lands the verify presets become more meaningful.

4. **Operator getting-started README pass.** Plug-in flow, what the meters mean, how to pick a preset, common pitfalls. The polished macOS UX is the project's edge over headless open-source alternatives; the README should reflect that.

5. **7.6 — Dynamic pre-emphasis ("Smart HF").** Lookahead-based HF envelope follower; dynamically relax the pre-emphasis curve during HF transients to reduce clipper workload. Significant algorithm effort. **Must preserve M/S-domain pre-emphasis placement** (see "Pre-emphasis placement" note below) — if a sidechain-only HF-boost feed into the pre-encode limiter is needed, build it as a dedicated sidechain path, not by moving pre-emphasis upstream. Lower priority for amateur-grade — current pre-emphasis behaviour is fine for the target audience; this is a polish item.

## Broadcast-tier follow-ups

These close the gap from "best amateur-grade" toward prosumer/lower-commercial. Stretch goals — preset tuning + smoke-testing + README still come first since the amateur-grade audience benefits more from those than from any of these. Listed in rough priority order.

### Multiband DSP modernisation

Phase 1 (linear-phase FIR crossovers) shipped — phase-flat band reconstruction with –155 dB sum-to-flat error floor; eliminates the transient smear and inter-band pumping that made IIR-LR4 multiband sound worse than single-band on percussive content. Remaining phases:

- **Phase 2: Transient-aware attack + RMS/peak hybrid `EnvelopeFollower`.** Current detector is single-pole peak-only; commercial processors (Optimod's "Smart Attack") detect percussive transients and briefly stretch the attack so kick/snare fronts pass through without being squashed. Build a transient detector (peak-vs-RMS envelope ratio crossing threshold) and modify `MonoCompressor` to take a transient hint. Largest remaining audible win for percussive sources after Phase 1. Scope: ~1 week.
- **Phase 3: Per-band look-ahead.** Reuse `LookaheadLimiter`'s ring-buffer pattern per band so each band's compressor sees its peaks ~1–5 ms before they arrive. Largely redundant with Phase 2 once that's in. Scope: ~3–5 days.
- **Phase 4: Inter-band gain coupling.** Optimod-style "loud bass softens the highs" cross-band coupling. Refinement after the foundation is right; subtle. Scope: ~1 week.

### Composite clipper improvements

1. **Linear-phase FIR decimation in `CompositeClipper`.** The current 6th-order Butterworth biquad-cascade decimation LP at ~57.6 kHz introduces ~150° group delay at the upper subcarrier edge (37 kHz) vs ~6° at audio frequencies. Real receivers tolerate this, but it shows up as an apparent L/R reconstruction error in our own tests and is a cleanliness gap commercial processors don't have. Replace with a Kaiser-windowed linear-phase FIR (same trade-off the encoder FIR already accepts: ~1.5 ms TX-path latency for phase-flat behaviour). Slot into the existing `LinearPhaseFIRLowpass` infrastructure. Estimated scope: 2–4 days.

2. **Look-ahead composite peak control.** Modern processors (Optimod 8x00, Omnia.9, Stereotool) drive composite peak control from a sidechain that knows future peak amplitude, so gain reduction is applied before the peak arrives and overshoots are mathematically bounded. Today the composite clipper is purely time-symmetric soft-clip with no look-ahead; the final-stage MPX limiter has look-ahead but operates after pilot/RDS injection. Add a delay line + predictive peak detector to the composite clipper. Estimated scope: 1–2 weeks.

3. **Multiband composite clipping.** Spectral-band-specific clip thresholds give more loudness for the same peak modulation and avoid the tonal-shift artifact heavy clipping produces. Optimod 8x00's loudness lift on dense program comes from this. Single-band clipping hits a wall ~1.5 dB earlier. Larger lift than 1+2 — split the audio composite at e.g. 200 Hz / 2 kHz / 8 kHz, clip each band against its own threshold, recombine. Estimated scope: 2–4 weeks. Builds on 1 (FIR decimation) for clean spectral splits.

4. **Stereo-band cancellation depth via FIR bandpass.** *Optional / depth-only.* The new delta-based per-band substitution gets ~5–10 dB cancellation in the stereo subband — bounded by LR4 phase rolloff in the protected bands. A linear-phase FIR bandpass for the substitution would push this to 20+ dB without affecting subcarrier preservation. Worth doing only if listening evaluation in "Next up" #1 says the residual cross-domain IM is audible at amateur drive levels.

*Linux port — deferred. See the "Cross-platform" section below for scoping; revisit once the macOS preset / smoke-test / README work has landed.*

## Open gaps

1. **Calibration workflow** — monitoring card shows deviation/pilot/RDS/margin, but exciter-facing guidance and operational long-run use need more hardening.
2. **AGC validation** — wideband AGC defaults and range need broader validation against the current final stage on real program. Pending: listening evaluation on real program to tune the density scaling and decide whether a lookahead path is worth the audio-path latency cost.
3. **Stereo image validation** — mono bass, widener, Orbass, and multiband interactions need preset-level validation on difficult real program. Width behavior still needs broader validation now that the composite clipper preserves subcarrier sidebands properly.
4. **Live-apply boundaries** — live DSP updates work, but need a smoke-test pass to verify no transient artifacts and that restart-only boundaries stay obvious.

## Phase 7 — remaining items

### 7.6. Dynamic pre-emphasis
See "Next up" #5. **Constraint:** must stay in M/S domain inside `makeCompositeComponents`, or implement as a dedicated sidechain feed into the pre-encode limiter. Moving the audio-path pre-emphasis upstream of the limiter (the `b806053` pattern) is verified to cause ring-overflow dropouts and is now guarded by `DSPThroughputTests.preEmphasisDoesNotExplodeFullChainCost`.

### 7.7. Pilot-synchronized clipper control
Defer indefinitely. If the composite clipper's gain-reduction envelope modulates near 19 kHz, it can induce sidebands around the pilot. The 8x oversampling + 12th-order Butterworth decimation already keeps clipper-band IM out of 17–21 kHz, but a control-envelope coupling could in principle reintroduce it. Measure first, then phase-lock the clipper's release to a pilot subharmonic if needed. Likely below the audibility threshold for amateur use; revisit only if a real operator complaint surfaces.

### 7.9. Input-side restoration
Defer. Declipper / dehumfilter / delossifier are genuinely complex algorithms (Omnia.9 "Undo"-class). Out of scope for amateur-grade — most amateur operators have control over their source material and don't need source restoration. Revisit only if MPX Prime starts being used for degraded streaming sources at scale.

## Tactical backlog

### Release-blocking
1. Smoke-test pass for live-apply vs restart-required settings.
2. Tune composite clipper defaults so a fresh install audibly outperforms `mpxgen` / PiFmRds with no operator tweaking.

### Sprint
1. Validate Orbass, mono bass, widener, and multiband interaction on difficult real material.
2. Refine calibration workflow only where real operator friction exists.
3. Build a small set of named presets (`clean`, `loud`, `community-radio`, `lpfm-conservative`) — INI fragments shipped alongside the binary.
4. Document the amateur-operator getting-started flow in README — what to plug where, what the meters mean, how to pick a preset, common pitfalls.

### Medium-term
1. Reduce duplicated filter configuration logic in biquad/crossover helpers.
2. Replace undocumented DSP magic numbers with named constants.
3. Simplify and test RDS group scheduler modes more deterministically.
4. Add AGC / filter-primitive unit tests, `AppConfig` round-trip and invalid-input tests.
5. Split the monolithic SwiftUI view model into smaller focused view models.
6. Loosen tight coupling between engine and generator; add DI seams for system-facing services.
7. Harden config file watching/reload behavior against race conditions.
8. Move RDS byte-string preparation off the audio render path.

## Code-quality priorities

### P0 — Confidence and safety
1. Add deterministic unit tests for AGC envelope behavior, filter primitives (PreemphasisFilter, DeemphasisFilter, Biquad, BiquadCascade6), stereo coding M/S round-trip sanity, and bypass-path null-signal tests.
2. Fix the verifier bandwidth metric so RDS does not produce misleading occupied-width failures (`bright_dense` occ999 warning disappears when `en_rds = False`).
3. Add config round-trip and invalid-input tests for `AppConfig`.
4. Define and test live-apply vs restart-required behavior as code, not just UI guidance.

### P1 — Structural cleanup
1. Split `MPXGenerator.swift` (~6300 lines now) into stage-focused components.
2. Split `AudioOutputEngine.swift` by concern (device routing, capture, render loop, metering, monitoring).
3. Split `SwiftUIControlApp.swift` (~7200 lines now) into smaller views and state holders.
4. Reduce hidden coupling between engine, config, generator, and UI state.

### P2 — Harden behavior
1. Strengthen `AppConfig` validation (invalid ranges, illegal combinations, impossible sample-rate/block-size).
2. Re-tune final-stage composite headroom for vocal/transient stability (`sum_level` 1.0 → 0.9 investigation).
3. Harden device and routing edge cases.
4. Make error reporting more structured.

### P3 — Performance
1. Further vDSP utilization where profiling shows value.
2. Cache RDS byte preparation to avoid repeated string allocations.
3. Add benchmarks for the hottest paths.
4. Capture baseline Instruments data and keep it current.

## Cross-platform — Linux as first-tier target

MPX Prime is currently Mac-only. A Linux port is **the single
biggest move for the amateur-grade goal** — most LPFM and
community-radio stations run on Linux/Pi/SDR, and today no
open-source project covers this audience with a real processing
chain (`mpxgen` does no processing; PiFmRds is Pi-only and
toy-grade; Stereotool's free version is closed-source and
crippled). Linux as **first-tier**, not a best-effort side-build.

**Scope decision — stay in Swift.** The DSP core
(`MPXGenerator`, all stage structs, `WidebandAGCRider`,
`CompositeClipper`, `LinearPhaseFIRLowpass`, the filters, the
RDS coder, `RDSTextParser`) is pure Swift math with zero Apple
framework dependencies. Swift toolchain is mature on Linux and
`swift-atomics` is already cross-platform. There is no need to
rewrite the DSP in C++ — that would be 6000+ lines of
verification-backed code thrown away for no measurable benefit.
Keep Swift.

**What actually needs replacing:**

1. **Audio I/O** (`AudioOutputEngine.swift` equivalent for Linux).
   Choose one backend to start — JACK is the broadcast-friendly
   default because stations already run JACK/PipeWire for routing;
   ALSA is the lowest-common-denominator fallback. Implement as a
   protocol `AudioBackend` with current macOS (`AVAudioEngine`)
   and new Linux (`JACKBackend` / `ALSABackend`) conformances.
   Keep the render-callback contract identical so the DSP path
   doesn't change.
2. **Lock primitive.** `OSAllocatedUnfairLock` is Darwin-only.
   Provide a `PriorityInheritingLock` abstraction with:
   - macOS: wraps `OSAllocatedUnfairLock`
   - Linux: wraps `pthread_mutex_t` with `PTHREAD_PRIO_INHERIT`
     protocol set. Priority inheritance is the critical property;
     the naive `NSLock` / bare `pthread_mutex` would cause the
     same dropouts we saw in the 0.10 session.
3. **Device enumeration.** Wrap CoreAudio's property-ID idioms
   and ALSA/JACK's enumeration behind an `AudioDeviceDirectory`
   protocol. Platform-specific implementations, common shape to
   the UI.
4. **UI — headless first.** Don't port SwiftUI to Linux. On
   Linux, launch with `--nogui` (already supported) and operate
   via CLI args + config file. Later: add an optional web
   dashboard (Vapor or Kitura serving a small SPA) that reads the
   existing `currentRDSLiveSnapshot` / meter data and exposes a
   subset of the controls. Web dashboard is additive and also
   usable from macOS over SSH.
5. **Accelerate / vDSP usage.** Audit; replace each `vDSP_*`
   call with either a plain Swift loop (the autovectoriser is
   decent) or a cross-platform kernel (FFTW for FFTs, naive
   scalar for the rest). The hot paths that actually benefit
   from vDSP are metering and spectrum FFT — not the audio
   render callback — so the cost of losing vDSP is modest.
6. **Build system.** SPM already supports Linux targets. Add a
   `ConditionalDependencies` block so AVFoundation / AppKit
   sources are only compiled on `.macOS`. Add Linux CI
   (GitHub Actions `ubuntu-latest` with the Swift toolchain) so
   the Linux build is verified on every PR.
7. **Testing.** All existing tests run on Linux once
   AVFoundation imports are conditionalised. The DSP signal,
   bitstream, orchestration, and throughput tests are pure. The
   tests that construct an `MPXGenerator` work unchanged; the
   ones that would need an `AudioOutputEngine` are mostly
   integration tests and they can stay macOS-specific.
8. **Distribution.** macOS keeps the signed `.app` bundle.
   Linux ships as:
   - static Swift binary in a tarball
   - Debian `.deb` and RPM `.rpm` with systemd service
   - (optional) Flatpak for community radio ops who prefer it
   - Docker image for containerised stations

**Estimated scope:**

| Piece | Effort | Blocking |
|---|---|---|
| Backend protocol + JACK impl | 2-3 weeks | Audio I/O |
| ALSA fallback impl | 1 week | Audio I/O |
| Lock primitive abstraction | 2 days | All audio-thread code |
| Device enumeration abstraction | 3-5 days | UI + CLI |
| Headless Linux CLI polish | 3-5 days | Usability |
| vDSP audit + replacement | 1 week | Metering / spectrum |
| SPM conditional compilation | 2-3 days | Build |
| Linux CI | 1 day | CI |
| Web dashboard (optional) | 2-3 weeks | Better UX |
| Distribution packaging | 1 week | Ship |

**Total realistic: 2-3 months for production-grade Linux tier-1 with
JACK backend + headless; +2-4 weeks for web dashboard.**

**Consequences worth naming:**

- The Linux port makes MPX Prime the **only** open-source FM
  processor with a real processing chain on Mac and Linux.
  That's the entire amateur-grade market position — today
  there's `mpxgen` (no processing) and PiFmRds (Pi-only, toy)
  in open-source space, and nothing else.
- Two platforms = two distributions to maintain. CI discipline and
  the backend protocol abstraction are non-negotiable, or the
  Linux build will rot.
- A `JACKBackend` slots naturally into the Liquidsoap / Ardour /
  Rivendell / Pi-station workflows that LPFM and community-radio
  operators already run.
- Pi 4/5 specifically is worth load-testing — a Pi class device is
  the most common amateur-station compute platform, and the
  current chain at 192 kHz with cross-domain cancellation needs
  to fit inside its real-time budget. Likely fine but unmeasured.

## Pre-emphasis placement (process note)

Commit `b806053` on the path from 0.9 → 0.10 relocated pre-emphasis from M/S domain (inside `makeCompositeComponents`, 2 filter passes on M and S) to L/R domain (upstream of the pre-encode limiter in `processSampleDetailed`, still 2 filter passes but feeding the limiter a signal with a 10–12 dB HF boost). The motivation was reasonable — let the pre-encode limiter peak-control the pre-emphasized signal — but the side effect was that the limiter ran in near-continuous gain reduction on HF-rich program. Combined per-sample cost on the audio thread exceeded the real-time budget, causing the input ring to fill from empty to capacity (~1.35 s) within 3–5 s of every engine start.

**Resolution:** 0.10 branches directly from `9747de3` (the commit before `b806053`) and skips the relocation. Pre-emphasis remains in M/S. The `DSPThroughputTests.preEmphasisDoesNotExplodeFullChainCost` test guards against reintroducing the pattern.

**If dynamic pre-emphasis (7.6) ever wants peak-control of the boosted signal:** build a dedicated sidechain — compute an HF-emphasized version as the limiter's detector input while keeping the audio path in M/S — rather than moving the audio-domain filter upstream.

## Design constraints

- Keep realtime callbacks lock-free and allocation-free. Snapshot writes use `OSAllocatedUnfairLock` (priority-inheriting) — any new audio-thread cross-thread communication must use the same primitive or an atomic, never `NSLock`.
- Do not move shell/file/network work into DSP paths.
- Preserve integrated RDS and monitoring workflow.
- Keep monitor-output latency separate from transmit-path quality.
- Pre-emphasis stays in M/S inside `makeCompositeComponents`. Enforced by `DSPThroughputTests`.

## References

### Prior art / DSP background
- [US 4,460,871 — Variable-frequency-shift demodulator (Orban, expired)](https://patents.google.com/patent/US4460871A/en)
- [US 5,168,526 — Distortion-cancellation circuit (Orban, expired)](https://patents.google.com/patent/US5168526A/en)
- [US 5,737,434 — Multi-band audio compressor (Orban, expired)](https://patents.google.com/patent/US5737434A/en)
- [US 6,434,241 — Half-cosine interpolation composite limiter (Orban, expired)](https://patents.google.com/patent/US6434241B1/en)
- [US 6,937,912 — Anti-aliased clipping with band-limited step functions (Orban, expired)](https://patents.google.com/patent/US6937912B1/en)
- [Stereotool — Limiting and Clipping documentation](https://www.thimeo.com/documentation/limiting_and_clipping.html)
- [Telos RDS guidance](https://docs.telosalliance.com/docs/rds)

### Enterprise processors (not direct competitors — for reference / inspiration only)
- [Orban 8700i specs](https://www.orban.com/specifications-optimod8700i)
- [Stereotool FM transmitter](https://www.thimeo.com/documentation/fm-transmitter.html)
- [BreakawayOne](https://www.breakawaysoftware.com/breakawayone)

### Open-source FM scene (the actual peer set)
- `mpxgen` — composite generator, no processing.
- `PiFmRds` — Raspberry Pi FM transmitter with RDS, toy-grade.
- Stereotool free build — closed-source, feature-limited.
- Liquidsoap — common amateur-station audio backbone; potential JACK integration target.
