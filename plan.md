# MPX Prime Roadmap

## Positioning

**Goal: the best amateur-grade free FM processor available.**

MPX Prime is *not* trying to be a $5–15k Optimod / Omnia / Stereotool replacement. It is trying to be the obvious choice for hobbyist, community radio, pirate, SDR-fed exciter, and DIY broadcast workflows where commercial processors are unaffordable or overkill. That framing is load-bearing for prioritisation.

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

## Patent-backed improvements backlog

Expired patents (public domain) that map onto specific stages of the
chain. Listed in priority order by expected DSP quality and future
loudness headroom now that the standard verifier and preset verifier
are clean. Caveat: the verifier scenarios run with
`mpx_clipper_enabled = False`, so improvements to the
`CompositeClipper` itself do not move the verifier numbers — they
land on the user-facing audio path only when the clipper is
explicitly enabled.

### Active backlog

| Priority | Patent                                                           | Title                                                  | Expires          | Stage                                                                              | Why                                                                                                                                                                                                                                                                                                                                                         |
| -------- | ---------------------------------------------------------------- | ------------------------------------------------------ | ---------------- | ---------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **P0 — VALIDATE / PHASE C** | [US 6,937,912](https://patents.google.com/patent/US6937912B1/en) | Anti-aliased clipping with band-limited step functions | 2025-09 | `OversampledPeakLimiter` (pre-encode L/R) landed opt-in; `audioCompositeSoftClipEnabled` shaper still candidate | Phase A/B landed, opt-in via `pre_encode_bandlimited_residual_enabled`. Remaining: program-material validation, then optional Phase C on the audio-composite shaper. |
| **P1** | [US 6,434,241](https://patents.google.com/patent/US6434241B1/en) | Half-cosine signal peak control | 2014-08 (lapsed) | Same stages as P0, alternative kernel | Continuous-first-derivative half-cosine peak; overshoot drops from ~10 % to 0.1–0.2 %. Less effective than US 6,937,912 for IM rejection but lower CPU. Useful as a selectable kernel or fallback. |
| **P3** | [US 5,892,833](https://patents.google.com/patent/US5892833A/en) | Gain calibration for audio compressors | Expired | `MonoCompressor` makeup-gain stage | Algorithmic gain-staging that tracks compressor's average GR to keep makeup gain roughly compensating. Polish item — low priority. |
| **P4** | [US 4,249,042](https://patents.google.com/patent/US4249042A/en) | Multiband cross-coupled compressor (FIG. 6 wideband variant) | Expired 1999-08-06 | `WidebandAGCRider` sidechain | Bass-desensitised wideband AGC: clip LF energy out of the AGC sidechain before the detector sees it, so kicks/bass don't drag the whole chain down. Distinct from the landed inter-band coupling (US 5,737,434, P2) — that couples *multiband-band* GR; this desensitises the *wideband* AGC. Ties into "Open gaps #2 — AGC validation." Pairs with P5. |
| **P5** | [US 3,790,896](https://patents.google.com/patent/US3790896A/en) | Automatic gain control circuit (duration-aware recovery) | Expired (1974 grant) | `WidebandAGCRider` release stage | Multiple time constants → short events recover fast, sustained reductions recover slow. Cheap detector tweak that complements P4 on the same AGC track; together they target "kick drum doesn't pump the chain" from sidechain shape + recovery curve. Extension: the same detector naturally covers **silence-sense freeze** ([US 4,500,753](https://patents.google.com/patent/US4500753A/en), Gentner, expired 2003) — at the long-duration end, freeze recovery during near-silence so the wideband AGC doesn't creep gain up during quiet intros / talk pauses. Land as a third tier of the same time-constant ladder, not a separate stage. |
| **P6** | [US 7,076,071](https://patents.google.com/patent/US7076071B2/en) | Process for enhancing ambience / imaging (mono-null enhancement bus) | Expired | Stereo widener | Invariant rule: any added enhancement term must algebraically cancel in `L+R`. Land first as a verifier metric (mono-sum delta widener-on vs widener-off), then constrain the widener algorithm to meet it. The FM-safe framing for any future widener work, and the right answer to "stereo image validation" (Open gaps #3). |
| **P7** | [US 4,567,607](https://patents.google.com/patent/US4567607A/en) | Stereo image recovery (frequency-bounded crossfeed) | Expired 2003-01-28 | Stereo widener | Crossfeed limited to below ~1-5 kHz; phase difference bounded; shaped mono dip around 200-900 Hz. Pairs with P6 as widener guardrails — prevents HF crossfeed hash and mono collapse while still giving perceived width. |

### Already implemented or structurally equivalent (do not re-implement)

| Patent                                                                                                                                       | Title                                                     | Where in code                                                                                | Note                                                                                                                                                                                                                                                                                                                                                                                                           |
| -------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- | -------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [US 6,337,999](https://patents.google.com/patent/US6337999B1/en)                                                                             | Oversampled differential clipper                          | `CompositeClipper` (commit `d1d8180`, post-0.11)                                             | Differential topology now standard; only the clipping residual goes through decimation.                                                                                                                                                                                                                                                                                                                        |
| [US 6,618,486](https://patents.google.com/patent/US6618486B2/en) (= [US 2003/0142840](https://patents.google.com/patent/US20030142840A1/en)) | BS.412 dual-integrator MPX power controller               | `BS412PowerLimiter` ([`MPXGenerator.swift:1167`](macOS/Sources/MPXPrime/MPXGenerator.swift)) | Functionally equivalent: power-detect → first integrator (rolling 60-s window) → sample-and-hold (per-block flush) → second integrator (currentGain attack/release smoothing) → feedback gain ride. We use a flat rolling-average window instead of a leaky integrator (gives a harder, more compliance-predictable boundary). Lapsed 2015-09-09.                                                              |
| [US 5,913,152](https://patents.google.com/patent/US5913152A/en)                                                                              | FM composite signal processor with pilot extract / re-sum | Different architecture, same end-state                                                       | We achieve pilot protection through (1) post-clipper subcarrier injection (the project invariant — pilot is never IN the audio composite when the clipper sees it) and (2) RBJ bandpass cancellation in the 17-21 kHz pilot guard inside `CompositeClipper`. Both end-results: clipper IM does not corrupt the pilot. Adopting the patent's extract/re-sum path on top would be redundant. Expired 2015-12-29. |
| [US 4,737,725](https://patents.google.com/patent/US4737725A/en)                                                                              | Pre-LPF overshoot compensation (Inovonics analog circuit) | `OversampledPeakLimiter` (4× oversampled)                                                    | The patent's analog technique (clip → phase-lag → re-clip → recover clippings → re-inject) is what modern oversampled true-peak limiters achieve digitally. We have one. Expired 1996-04-17.                                                                                                                                                                                                                   |
| [US 5,737,434](https://patents.google.com/patent/US5737434A/en) | Multi-band audio compressor with cross-band coupling | `MonoCompressor` per-band logic | Inter-band gain coupling landed opt-in in 0.28 via `multiband_inter_band_coupling_enabled`. Listening validation pending; lives in `--verify-multiband-coupling` and "Open ranked impact-per-effort" table. Expired. |
| [US 5,579,404](https://patents.google.com/patent/US5579404A/en) / [EP 0685130 B1](https://patents.google.com/patent/EP0685130B1/en) | Digital audio limiter — subband-aware look-ahead | `StereoLinkedOversampledPeakLimiter` (pre-encode L/R) | Both phases landed default-on in 0.30. Phase 1 = textbook delay+detector look-ahead (US 4,208,548 prior art, 1 ms default). Phase 2 = Dolby split-band variant, 4 kHz HF detector cutoff. Dolby; US expired ~2013-11, EP ~2014-02. |

### Bass enhancement (PrimeBass) — secondary backlog

PrimeBass is the adaptive low-band enhancer; goal is to lift perceived bass while *reducing* true-peak LF amplitude so downstream bass clipper / pre-encode limiter / composite clipper see less LF energy. The full B1/B2/B3/B4 patent backlog has shipped; further LF work would need new design directions (the active Music Tribe / DTS claims below are deliberate skips).

**Already implemented (do not re-implement):**

| Patent                                                          | Title                                                       | Where in code                                                       | Note                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| --------------------------------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [US 5,930,373](https://patents.google.com/patent/US5930373A/en) | Waves MaxxBass — equal-loudness-weighted harmonic synthesis | `processPrimeBass` + `configurePrimeBassFilters` (commit `4d4a70f`) | Even (asymmetric squarer) + odd (tanh-difference) harmonic generators with separate per-order weights derived from an ISO 226 phon-curve approximation evaluated at 2..5×F0 at configure time. Direct LF gain tapered down with the harmonics knob (`primeBassDirectGainReduction = 0.62`) so perceived bass shifts onto the weighted harmonics — buys headroom in the downstream bass clipper / pre-encode limiter without changing subjective bass weight.        |
| [US 4,150,253](https://patents.google.com/patent/US4150253A/en) | Aphex Aural Exciter — HP-then-clip topology                 | `processPrimeBass` (commit `4d4a70f`)                               | Adapted for bass extension: a pre-waveshaper *allpass* biquad at F0 (rather than a HPF, which would attenuate F0 itself) rotates phase ~180° without amplitude loss, decorrelating synthesised harmonics' phase from the direct lowboost path. Stops harmonics from summing coherently with the direct boost and comb-filtering at the bass clipper input.                                                                                                          |
| [US 5,424,488](https://patents.google.com/patent/US5424488A/en) | Werrbach transient-discriminate harmonics (Aphex)           | `processPrimeBass` Phase 2 (commit `af7b883`)                       | Dual-envelope transient detector — fast (5 ms / 30 ms) follower minus slow (50 ms / 250 ms) baseline, normalized — modulates the harmonic-band gain from a 0.7× sustain floor to a 1.4× peak on real onsets. "Punchy not boomy" character: reduces continuous HF energy on sustained material while preserving peak harmonic intensity on attacks. Verified via internal `transientGainObserved` accessor at three time points (pre-onset / 25 ms post / 350 ms sustained). |
| [US 5,359,665](https://patents.google.com/patent/US5359665A/en) | Werrbach Big Bottom — dynamic bass extension (Aphex)        | `processPrimeBass` Phase 3 (landed in 0.23)                         | Direct LF-level envelope follower with fast attack (~10 ms) / slow release (~300 ms) drives `primeBassAdaptiveGain`. Replaces the prior spectral-ratio detector + transient-hold machinery (which tracked compositional balance over seconds and so couldn't engage on a typical drum hit before the hit was over). Net per-patent effect: "envelope duration extension" — same peak boost as a static gain, just held longer through the note tail. Verified via internal `primeBassAdaptiveGain` accessor at three phases (pre-onset / sustained / post-release). |

### Bass-enhancement patents skipped (active or non-additive)

| Patent                                                                                                  | Status                                 | Reason                                                                                                                                                       |
| ------------------------------------------------------------------------------------------------------- | -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [US 9,712,916](https://patents.google.com/patent/US9712916B2/en) DTS "Bass Enhancement System"          | **ACTIVE** to ~2032-12-19              | Adds headroom-coupled adaptive gain on top of MaxxBass synthesis. Easy design-around: use fixed/program-dependent gain not driven by instantaneous headroom. |
| [US 9,319,789](https://patents.google.com/patent/US9319789B1/en) Music Tribe "Bass Substitution Filter" | **ACTIVE (reinstated)** to ~2032-02-11 | Adds level-tracking *centre-frequency* modulation of harmonic-boost filter. Easy design-around: fixed centre frequency, amplitude-only modulation.           |
| [US 4,482,866](https://patents.google.com/patent/US4482866A/en) BBE Sonic Maximizer                     | Expired 2002-02-26                     | Frequency-dependent group delay correction — actively *harmful* in FM-broadcast chain (breaks pilot/subcarrier coherence per CLAUDE.md invariant).           |
| [US 4,748,669](https://patents.google.com/patent/US4748669A/en) SRS / Hughes                            | Expired                                | Stereo enhancement via L−R manipulation, not bass. Misclassified in earlier surveys.                                                                         |

### Skipped (evaluated and rejected)

| Patent                                                                | Title                                                                                             | Status                                                       | Reason                                                                                                                                                                                                                                                                                                                                                                                    |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [US 7,295,628](https://patents.google.com/patent/US7295628B2/en)      | DSP MPX with sample-frequency-aligned vestigial sideband                                          | Expired 2024-07-30 (full term)                               | Requires `fs = 2 × fmod` (76 kHz chain rate) so the DAC reconstruction filter does half the SSB shaping for free. Our chain runs at 192 kHz throughout; adopting this means a complete chain-rate refactor or a dedicated SRC + secondary path just for the stereo subcarrier. Niche AM/SSB-broadcast technique; FM stereo's DSB-SC is what receivers expect and what IEC 62106 mandates. |
| [WO 2017/186756](https://patents.google.com/patent/WO2017186756A1/en) | Frequency-domain L+R/L−R protector                                                                | PCT ceased; **CA3021918 potentially enforceable until 2037** | Dual blockers. Legal: Canadian national-phase application may still be enforceable through 2037 (verify before any CA distribution). Technical: OLA-block FFT both M and S each block is CPU-expensive on the audio thread and adds OLA-block latency; M/S domain dynamic L−R limiter (Stereotool style) achieves similar mono-compatibility without FFTs.                                |
| [US 4,412,100](https://patents.google.com/patent/US4412100A/en)       | Multiband signal processor (Orban)                                                                | Expired 2001-09-21                                           | Distributed-crossover multiband peak-to-RMS processor with embedded clippers (1981 filing). Structurally the prior art for everything we already ship: FIR multiband + per-band `MonoCompressor` + differential composite clipper. The 1981 distributed-clipping concept is at a less modern level than the current chain — nothing to adopt. *(Description was wrong in earlier revisions: "Audio limiter using FET attenuator" is not this patent.)*                                       |
| [US 7,587,254](https://patents.google.com/patent/US7587254B2/en)      | Dynamic range processor with auxiliary decorrelation in slowly-time-varying L+R limiter sidechain | ~2029                                                        | Filed 2004; not yet expired. Revisit post-2029.                                                                                                                                                                                                                                                                                                                                           |

## Next up

1. **Dual-rate audio chain — 48 kHz audio domain, >=176.4 kHz MPX domain.** The entire chain currently runs at the device rate (192 kHz default), but input is universally 48 kHz and audio-domain content carries no information above 24 kHz. The 48 -> 192 kHz upsample at the input boundary makes everything above 24 kHz interpolated zeros - L/R EQ, multiband FIR splitter, pre-emphasis, and pre-encode limiter all process those zeros at 4x the necessary rate. Splitting into an audio domain (48 kHz, where the signal information lives) and an MPX domain (>=176.4 kHz, where pilot / L-R sidebands / 57 kHz RDS need bandwidth) is the textbook pro-encoder architecture (Orban, Stereotool, Omnia).
   - **Measured before-state on M1 Pro (release, develop/v.030)**: full chain @ 192 kHz = **41.54% of real-time**; audio-domain stages contribute ~23.75% RT, MPX-domain stages ~14.97% RT. Rate sweep is near-linear (96/128/176.4/192 kHz = 21.3 / 27.7 / 38.1 / 41.6% RT). Heaviest stages: **composite clipper 16x = 14.23% RT (MPX, stays at high rate)**, DC clipper = 5.67%, bass clipper = 5.10%, multiband FIR = 4.80%, pre-encode limiter = 3.90%, PrimeBass = 2.29%. Full report at `macOS/benchmarks/m1pro-v0.30-pre-dualrate.md`. Reproduce with `MPXPRIME_BENCH=1 swift test -c release --filter Benchmark` (suite is `BenchmarkSuite`, env-gated so it doesn't run in normal `swift test`).
   - **Estimated win**: dual-rate brings full chain @ 192 kHz from 41.54% RT down to ~25.80% RT on M1 Pro - **15.74 percentage points / 38% relative reduction** (audio stages drop to ~1/4 cost; MPX stages and ~5% resampler overhead remain). Smaller than the initial "multiband is the bottleneck" framing implied: composite clipper at 14.23% RT is the single heaviest stage and stays at MPX rate. On older Intel (MBP16,1, Coffee Lake-H, AVX2 no AMX), the audio-domain stages are expected to be relatively heavier than on M1 Pro, so dual-rate should save proportionally more there - benchmark needs to run on the 16,1 to confirm.
   - **Stages that move to 48 kHz**: input -> EQ -> multiband (FIR splitter) -> bass clipper outer rate -> DCC outer rate -> pre-emphasis -> pre-encode limiter -> PrimeBass -> wideband AGC -> stereo widener -> mono bass -> phase rotation -> multiband limiter. The 4x / 8x / 16x internal oversampling on `BassClipper`, `DistortionCancelledClipper`, `CompositeClipper` reaches the same final internal rates (192k, 384k, 3.07 MHz); only the outer rate changes. Anti-aliasing quality unchanged.
   - **Boundary**: polyphase Kaiser-windowed sinc resampler at the stereo encoder input, mirroring `LinearPhaseFIRDecimator` design (Kaiser-windowed sinc + `vDSP_dotpr` polyphase). Group delay folded into subcarrier-delay alignment and look-ahead sizing. Resampler overhead budget: <5% RT.
   - **Open risks**: (1) pre-emphasis at 48 kHz - RC-shelf bilinear biquad is fractionally less accurate near Nyquist than at 192 kHz; within broadcast tolerance (every professional plant does it at 48 kHz) but needs one-time response measurement against current behavior; (2) verifier baselines all move on re-render - capture pre-refactor baselines, then `--baseline-strict` gates each stage migration, refresh defaults after the resampler lands; (3) boundary audit - any non-linearity introduced after the lower-rate audio chain but before upsampling would alias; (4) look-ahead delay buffer sizing moves with the outer rate (restart-only setting already; no live-apply change needed).
   - **Approach**: introduce the resampler + boundary first as a no-op (audio stages still run at MPX rate, resampler only converts at engine boundary), then migrate stages across one at a time, baseline-gated. Bass clipper + DC clipper + multiband splitter are the largest single wins; PrimeBass and pre-encode limiter follow. Re-run `BenchmarkSuite` after each stage migration to confirm the predicted reduction.
   - **Phase 0 + Phase 1 LANDED (2026-05-22)**: `LinearPhaseFIRInterpolator` (1:L polyphase upsampler) primitive + tests landed; resampler boundary wired into `processSampleDetailed` as a no-op (off by default; opt-in via `dual_rate_audio_domain_enabled = true` with integer-ratio engine rates like 192/48 = 4 or 96/48 = 2). Non-integer engine rates (176.4 / 128 kHz with 48k audio) silently fall back to disabled — Phase 1 integer-ratio only.
   - **Phase 2 LANDED (2026-05-23)**: cutover complete — when boundary is on, the entire audio domain runs at 48 kHz inside the boundary instead of MPX rate after a roundtrip. Measured payoff on M1 Pro: full chain 41.85% RT → 24.26% RT, **-17.59 pp / -42.0% relative savings**. Matches the original projection. Stereo separation preserved (1k/10k/14k = 42.9/26.1/33.4 dB matches the off baseline). Two cutover bugs caught + fixed: interp buffer read order, and pilot over-delay via `recomputeSubcarrierDelay`. See CHANGELOG 0.30 (2026-05-23 entry) for the detailed implementation + bug post-mortems. Full benchmark at `macOS/benchmarks/m1pro-v0.30-phase2-cutover.md`.
   - **Default-ON LANDED (2026-05-23)**: `dualRateAudioDomainEnabled` flipped from default-false to default-true. Verifier baseline (`macOS/verifier_baselines/default.json`) recaptured under the new default; `--verify --baseline-strict` now passes. `DualRateBoundaryTests` regression guards updated. README gains the matching input-device configuration recommendation (48 kHz / 24-bit). 385 tests pass; all verifier modes OK.
   - **Open follow-ups**: real-program listening A/B at the new default (operator confirmation that 48 kHz audio-domain doesn't reveal audible regressions vs the legacy chain on dense / sibilant program), measure pre-emphasis bilinear-biquad response at 48 kHz vs 192 kHz to confirm broadcast-tolerance, Phase 3 (non-integer ratio polyphase resampler) for engine rates like 176.4 / 128 kHz that currently fall back to the legacy chain.
   - **Composite clipper acceleration is a separate, complementary track** - at 14.23% RT it's the single largest cost in the chain and dual-rate does not directly reduce it (stays at MPX rate). Worth investigating separately whether the 16x oversampling + LinearPhaseFIRDecimator path can be tightened.
   - **Scope**: target 0.31 / 0.32. ~1-2 weeks engineering + verifier baseline refresh.

2. **Anti-aliased clipping kernel (US 6,937,912; Orban; expired Sept 2025).** Phase A/B are landed behind `pre_encode_bandlimited_residual_enabled = False`. Goal remains the same: stop alias/IM products at the clipping event itself rather than relying on oversampling, decimation, and the composite cleanup FIR to remove them after they exist. Remaining:
   - **B finish.** A/B real program material with `pre_encode_bandlimited_residual_enabled = True`; decide whether any loud preset should enable the residual path.
   - **C. Apply same primitive to `softClipSafety` calls inside `processFinalComposite`** only if B proves benefit. Keep pilot/RDS injection post-processing and preserve the composite budget governor invariant.
   - **D. Refresh verifier baselines and listen on real program.** Do not relax current verifier thresholds unless measurement proves they are overfitting.
   References: Välimäki "Discrete-Time Modelling..." (1995), Brandt "Hard Sync without Aliasing" (2001), Stilson/Smith "Alias-Free Digital Synthesis..." (1996).

3. **Tune and validate composite clipper look-ahead.** `mpx_clipper_lookahead_ms` shipped (0.26) and silent live-resize shipped (0.27); listening work remains. Dense real-program A/B at 0.5 / 1 / 2 ms via the live slider; verify pilot and RDS guard cleanliness; decide whether loud presets ship with a small non-zero default. Captured WAVs land in `macOS/.audit-out/lookahead/` via the env-gated `MPXPRIME_AUDIT_CAPTURE=1` capture driver (directory is gitignored). Runs in parallel with #1 — listening is a separate track from DSP.

4. **Smoke-test pass.** Validate live-apply vs restart-required settings on difficult real material. Catch any transients / clicks / dropouts on toggle changes. Pre-release blocking item. The new RDS live-apply paths (PI / PTY / flags / AF / scheduler) need particular attention — most are tested at the bit-stream level but not against real receivers.

5. **Extend baselines to `--verify-presets` and `--verify-long`.** Same `VerifierBaselineFile` schema (now at schema v2 with `postInjectionOvershoot` / `overBudget` fields), different scenario sets. Once preset tuning lands the verify presets become more meaningful.

6. **Receiver-model verifier hardening.** The receiver verifier is now implemented and reports coherent decode, PLL external-style decode, ideal raw M/S decode, raw sideband balance, stage-isolation rows, mono/no-pilot behavior, and pilot/RDS spectral health. Next work is hardening: promote budget invariants such as unexpected `postInjectionOvershoot > 0` from TIGHT/WARN to a hard failure for normal presets, then add stored baselines for receiver metrics.

### High-frequency stereo separation — `MPXDecoder` audit (only remaining thread)

Receiver decode landed clean in 0.28 (1 kHz 65 dB / 10 kHz 50.5 dB / 14 kHz 43.4 dB, see CHANGELOG 0.28 for the audit). Outstanding: audit `MPXDecoder` deemphasis / notch / 15.5 kHz lowpass contribution if production decode needs to close further on the ideal-coherent ceiling. Receiver-verifier hardening ("Next up" #6) is the structural complement.

### Extended MPX monitoring

MPX Prime should treat "monitoring" as a real receive path, not only as a convenience downmix. The same reusable MPX decoder should support both internal generated-MPX monitoring and external MPX input monitoring from a high-rate USB audio interface.

Scope for the first phase:

- **Generated MPX monitor.** Continue decoding our own generated composite MPX back to L/R monitor audio through the shared `MPXDecoder`, so what the operator hears represents what an FM stereo receiver would recover, not a separate shortcut path.
- **External USB MPX monitor.** Add an `MPX Input Analyzer` mode that treats the selected USB audio input as composite MPX, decodes it to monitor L/R audio, and exposes receiver-style health metrics.
- **Shared analyzer metrics.** Report pilot level, pilot lock confidence, composite RMS/peak, decoded L/R levels, stereo correlation, side/mid balance, and RDS-band energy around 57 kHz.
- **Pilot-PLL receive mode.** Internal generated monitoring may use a known reference, but external USB MPX must use a real pilot-locked receive path. Add a stronger PLL mode to `MPXDecoder` for arbitrary input.
- **Real-time safety.** The analyzer path must obey the same audio-thread rules as the transmit chain: no allocations, locks, dispatch, logging, string formatting, or wall-clock calls in the render callback.
- **USB input expectations.** Target 192 kHz USB capture first. Warn in the UI when the selected input rate is too low for useful MPX analysis.
- **Deferred.** WAV/file analysis and full RDS group/text decoding are future receiver features. Phase 1 only measures RDS-band presence and level.

Implementation shape: keep this separate from the transmit DSP chain. Analyzer mode receives MPX, decodes it, meters it, and sends decoded L/R to monitor output; it must not reprocess external MPX through the generator chain.

7. **7.6 — Dynamic pre-emphasis ("Smart HF").** Lookahead-based HF envelope follower; dynamically relax the pre-emphasis curve during HF transients to reduce clipper workload. Significant algorithm effort. Pre-emphasis is now in L/R upstream of the pre-encode limiter, so dynamic relaxation can either modulate the existing `preL` / `preR` filters in place or build a dedicated sidechain detector — both paths are now compatible with the production chain. Lower priority for amateur-grade; this is a polish item.

## RDS roadmap toward enterprise tier

These are the items that would close the gap from "broadcast-station-grade
with comprehensive live-apply" to "enterprise-grade encoder that drops into
a station-automation rack". Stretch goals — they only matter if the project
direction shifts toward network-broadcaster / multi-station deployment,
which is not the current amateur-grade focus. Listed in priority order;
see audit notes from the current session for source citations.

1. **UECP SPB 490 minimal subset over TCP/IP.** Single biggest enterprise-tier unlock. Without UECP, the encoder cannot integrate into a station automation chain. Minimum viable: TCP server (port 5570 conventional), DLE-stuffed framing, MEC parsing for PI/PS/PTY/RT/AF/TA/scheduler/master-enable, Site/Encoder/DSN/PSN address fields parsed even if multi-PSN is not yet honoured. Hooks into the existing `applyRDSRuntimeConfig` so wire commands share live-apply infrastructure. Estimated scope: 1–2 weeks. New file `UECPServer.swift` (~400 lines).
2. **EON (Group 14A + 14B).** Linked-network station references: PI / PS / AF / TP / TA mirroring across multiple PSNs. Required for any group broadcaster. Add `RDSRuntimeConfig.eonLinks: [EONLink]`, build 14A / 14B group builders, wire into the scheduler, persist to AppConfig. New EON detail tab in the RDS sidebar. Estimated scope: 3–5 days.
3. **Multi-PSN / Data Sets.** Refactor `RDSRuntimeConfig` to be per-PSN keyed by Data Set Number + PSN. Boundary-switchover logic (no PI flap, no AF collapse, no RT garbage). Required for day-parting and regional opt-outs. Builds on UECP. Estimated scope: 1 week.
4. **Operations: SNMP + watchdog + scheduler + on-air loopback.** SNMP MIB exposing transport state and group-emission counters. Time-of-day scheduler for `RDSRuntimeConfig` switches. Optional FM-tuner loopback verification via the existing monitor output mode (compare modulated MPX → demod → expect known PI/PS). Estimated scope: 2–3 weeks.

Standards-compliance items not yet addressed (deferred per current session
direction; ASCII Long PS is correct for amateur-grade use):

- **Group 15A UTF-8 toggle bit.** IEC 62106-2:2018 §6.8 extends Long PS
  with a UTF-8 character-set indicator bit. The exact b2-tail bit position
  is in the paywalled portion of the IEC PDF. Currently shipping ASCII
  Long PS only (basic-RDS character set is ASCII for 0x20–0x7E, so the
  output is correct for ASCII content even without the toggle bit).
  Implement when full IEC 62106-2:2018 §6.8 / Figure 15 is acquired.

## Broadcast-tier follow-ups

These close the gap from "best amateur-grade" toward prosumer/lower-commercial. Stretch goals — preset tuning + smoke-testing + README still come first since the amateur-grade audience benefits more from those than from any of these. Listed in rough priority order.

### Multiband DSP modernisation — Phase 3 (only remaining)

Phases 1 / 2 / 4 already shipped (see CHANGELOG). Only open phase:

- **Phase 3: Per-band look-ahead.** Reuse `LookaheadLimiter`'s ring-buffer pattern per band so each band's compressor sees its peaks ~1–5 ms before they arrive. Largely redundant with Phase 2 once that's in. Scope: ~3–5 days. Probably skip unless listening shows Phase 2 isn't enough on dense percussive program.

### Composite clipper improvements

1. **Multiband composite clipping.** Phase 1 landed opt-in (`mpx_multiband_clipper_enabled`, host-rate linear-phase low/mid/high splitting with per-band ceilings, verifier A/B via `--verify-composite-multiband`). Remaining: dense-program listening, oversampling refinement if HF aliasing turns out audible, preset decision.

2. **Stereo-band cancellation depth via FIR bandpass.** *Optional / depth-only.* The delta-based per-band substitution gets ~5–10 dB cancellation in the stereo subband — bounded by LR4 phase rolloff in the protected bands. A linear-phase FIR bandpass for the substitution would push this to 20+ dB without affecting subcarrier preservation. Worth doing only if listening evaluation in "Next up" #2 says the residual cross-domain IM is audible at amateur drive levels.

### Audio-clipper oversampling refinement

`CompositeClipper` was raised from 8× to 16× post-0.29 for industry-standard parity (Optimod 8X00, Omnia 11, Stereotool all run their composite clipper at 16× or higher). 0.30 made the factor operator-selectable across {8, 16, 32} via `mpx_clipper_oversampling` (default 16) — 8× for CPU-constrained machines, 32× for Omnia.9-class spec-sheet parity. The same argument applies to the audio-domain clippers, which currently sit one tier below pro:

- **`BassClipper`** — 4× now; pro chains run 16×+ on the bass clipper.
- **`DistortionCancelledClipper`** — 8× now; pro chains run 16–32× on the audio-band clipper, often with look-ahead.

Both currently use `Lagrange4Interp` + `BiquadCascade6` (12th-order Butterworth decimation LP). Raising the OS rate likely also wants a switch to `LinearPhaseFIRDecimator` (Kaiser-windowed sinc + `vDSP_dotpr` polyphase) — same primitive the composite clipper now uses — for tighter stopband at the higher OS rate. The historical `DistortionCancelledClipper` aliasing test (5111 Hz × 5th harmonic landing at 25555 Hz, near native Nyquist) is the most stringent measurement gate; current threshold is −38 dBFS in `DistortionCancelledClipperTests.aliasingEnergy`, but pro chains push this past −75 dBFS.

**Why polish, not next-up**: at typical amateur drive levels the aliasing is already inaudible — the current 8× DC clipper + LR4 cancellation path measures cleanly on real program. The win is industry-standard headroom for hot-driven HF content and a defensible parity story against the pro chains. Diminishing returns; verify with `--verify --baseline-strict` and the aliasing-energy tests before committing to a tap-count increase.

**Scope estimate**: 1–2 days per clipper for the OS bump + decimation-filter swap + benchmark + verifier baseline refresh. The chain currently has ~70% real-time headroom (per `DSPThroughputTests`) so absolute CPU cost is comfortably absorbed.

### HF look-ahead clipper (mention)

Omnia.9 / Stereotool ship a dedicated HF clipper stage with predictive sidechain — a separate clipper sitting on top of the multiband chain that look-aheads on the high band only, shaving HF transients before they hit the broadband composite clipper. MPX Prime currently relies on the broadband composite clipper's look-ahead (`mpx_clipper_lookahead_ms`, 0.26) and the per-band multiband expander/limiter; there is no dedicated HF clipper stage.

Audible mostly on dense EDM / contemporary pop where HF transients hit the composite clipper hard enough to cost loudness or cleanliness. Marginal on top-shelf program material. One of the two real audible gaps versus a $15k Optimod (the other is dynamic pre-emphasis, "Next up" #7).

Implementation shape would be a new `HFClipper` stage between the multiband recombine and pre-emphasis, with its own oversampled tanh kernel + sliding-window-max detector (same primitive as the composite clipper's look-ahead). Significant algorithm + listening-validation effort; polish-tier, not next-up.

### Enterprise-parity status

Where MPX Prime stands today against Optimod 8500/8600, Omnia.9/.11, and Stereotool. Structural ordering is now identical to all three across every load-bearing position — chain canonical, differential-topology composite clipper with look-ahead and budget governor, stereo-linked pre-encode limiter, linear-phase FIR multiband, full PrimeBass patent backlog, vDSP/vForce SIMD on hot loops. What's missing is feature depth, not architecture. (Per-release detail in CHANGELOG.)

**Open, ranked impact-per-effort:**

| Priority | Item | Where | Effort | Impact |
|---|---|---|---|---|
| **1 - validate / Phase C** | Anti-aliased clipping kernel (US 6,937,912) | `pre_encode_bandlimited_residual_enabled`; optional `audioCompositeSoftClipEnabled` shaper follow-up | 2-4 days for program A/B; ~1 week if Phase C proceeds | **Highest** - Phase A/B are in and tested; remaining value is proving preset benefit and extending the primitive only where measurements justify it |
| **2** | Multiband Phase 2 opt-in validation | `multiband_transient_aware_attack_enabled` | 2–3 days | High - implementation is in; next step is verifier/listening A/B before deciding whether any preset should enable it |
| **3** | Multiband composite clipping validation | `mpx_multiband_clipper_enabled` / `--verify-composite-multiband` | 1 day | High - implementation and verifier A/B are in; next step is dense-program listening before preset use |
| **4** | Receiver verifier hardening | "Next up" #6 | 2–4 days | High — receiver verifier exists; next step is stored receiver baselines and harder failures for budget invariants |
| **5** | Inter-band gain coupling validation ("loud bass softens highs") | `multiband_inter_band_coupling_enabled` / `--verify-multiband-coupling` | 1 day | Medium — implementation and verifier A/B are in; next step is listening before preset use |
| 6 | Composite look-ahead default tuning (listening) | "Next up" #3 | ~3–5 days | Medium — turns the 0.26-landed feature into operator-visible loudness improvement |

**Honest rating, today, structurally:**
- vs. **Optimod 8500/8600**: ~70–80% of audible chain quality. Look-ahead composite peak control landed in 0.26 and Phase 1 multiband composite clipping landed opt-in in 0.28; the remaining real loudness-architecture gap is validation, preset tuning, and deeper refinements rather than basic topology.
- vs. **Omnia.9/.11**: ~70–80%. Omnia "Undo" declipper and the depth of their multiband are out of scope.
- vs. **Stereotool free build**: substantially ahead on structural completeness. Stereotool full license is comparable to Optimod 8x00 — same gap as above.
- vs. **mpxgen / PiFmRds**: different category. MPX Prime is the only open-source FM processor with a real processing chain at this point.

The amateur-grade goal is structurally complete. Remaining work is validation, preset tuning, receiver-verifier hardening, inter-band coupling, and listening-tuning, not architectural rewiring.

*Linux port — deferred. See the "Cross-platform" section below for scoping; revisit once the macOS preset / smoke-test / README work has landed.*

## Open gaps

1. **Calibration workflow** — monitoring card shows deviation/pilot/RDS/margin, but exciter-facing guidance and operational long-run use need more hardening.
2. **AGC validation** — wideband AGC defaults and range need broader validation against the current final stage on real program. Pending: listening evaluation on real program to tune the density scaling and decide whether a lookahead path is worth the audio-path latency cost.
3. **Stereo image validation** — mono bass, widener, PrimeBass, and multiband interactions need preset-level validation on difficult real program. Width behavior still needs broader validation now that the composite clipper preserves subcarrier sidebands properly.
4. **Live-apply smoke testing** — DSP and RDS live-apply paths both work; the RDS path was substantially expanded post-0.11 (every operationally-toggled setting now applies live). Still want a focused smoke-test pass on real material to verify no transient artifacts on toggle changes, particularly for TA-edge auto-injection and AF Method B switching. The bit-stream tests cover correctness; the smoke test covers operator perception.

## Phase 7 — remaining items

### 7.6. Dynamic pre-emphasis
See "Next up" #7. Pre-emphasis itself is now in L/R upstream of the pre-encode limiter (post-0.24 chain-order modernization, see "Broadcast-tier follow-ups → Chain-order audit"). A dynamic / lookahead-driven HF envelope follower that relaxes the pre-emphasis curve during transients is still future work. If implemented, it can either modulate `preL`/`preR` in place, or — for a sidechain-only HF-boost feed — be built as a dedicated detector path that doesn't disturb the audio-domain `preL`/`preR` filters. The previous `DSPThroughputTests.preEmphasisDoesNotExplodeFullChainCost` constraint (which guarded the b806053 M/S→L/R relocation against budget overrun) is now historical — the current chain has ~70% real-time headroom and the relocation it guarded against is now what ships.

### 7.7. Pilot-synchronized clipper control
Defer indefinitely. If the composite clipper's gain-reduction envelope modulates near 19 kHz, it can induce sidebands around the pilot. The 16× oversampling + linear-phase Kaiser FIR decimation already keeps clipper-band IM out of 17–21 kHz (and the pilot guard's RBJ-BPF residual cancellation removes whatever leaks through), but a control-envelope coupling could in principle reintroduce it. Measure first, then phase-lock the clipper's release to a pilot subharmonic if needed. Likely below the audibility threshold for amateur use; revisit only if a real operator complaint surfaces.

### 7.9. Input-side restoration
Defer. Declipper / dehumfilter / delossifier are genuinely complex algorithms (Omnia.9 "Undo"-class). Out of scope for amateur-grade — most amateur operators have control over their source material and don't need source restoration. Revisit only if MPX Prime starts being used for degraded streaming sources at scale.

## Tactical backlog

### Release-blocking
1. Smoke-test pass for live-apply vs restart-required settings.
2. Tune composite clipper defaults (drive, ceiling, and the 0.26-landed `mpx_clipper_lookahead_ms`) so a fresh install audibly outperforms `mpxgen` / PiFmRds with no operator tweaking.

### Sprint
1. Validate PrimeBass, mono bass, widener, and multiband interaction on difficult real material.
2. Refine calibration workflow only where real operator friction exists.
3. Real-program listening A/B per Format Profile (the eight 0.30 profiles) to fine-tune per-profile clipper drives.
4. **Intel benchmark capture (MBP16,1 i7-9750H / i9-9980HK).** `BenchmarkSuite` has only M1 Pro numbers; older Intel (AVX2 without AMX) is the hardware most likely to benefit from the 0.30 dual-rate cutover. Confirm the projected ~84% → ~48% RT improvement on a real 16,1 (or equivalent Coffee Lake-H machine) so the README guidance is backed by measurement. Reproduce via `MPXPRIME_BENCH=1 swift test -c release --filter Benchmark`.

### Medium-term
1. Reduce duplicated filter configuration logic in biquad/crossover helpers.
2. Replace undocumented DSP magic numbers with named constants.
3. Simplify and test RDS group scheduler modes more deterministically.
4. Add AGC / filter-primitive unit tests. (`AppConfig` round-trip + invalid-input coverage shipped — see `AppConfigInvalidInputTests`.)
5. Split the monolithic SwiftUI view model into smaller focused view models.
6. Loosen tight coupling between engine and generator; add DI seams for system-facing services.
7. Harden config file watching/reload behavior against race conditions.
8. Move RDS byte-string preparation off the audio render path.

### UX / accessibility polish (0.30 codex-review residue)

Items surfaced by the 0.30 codebase review that aren't immediate-fix but should land before the project is positioned as a polished amateur operator tool rather than a research console.

1. **Rename implementation-language UI labels.** Cards still expose patent / phase / topology terms that read as developer notes: "Use New Band-limited Limiter Ceiling", "HF-Only Look-ahead Detector (Phase 2 / Dolby)", "Experimental Multiband Composite Clipping", "Cancel pilot guard (17-21 kHz)", "Cancel RDS guard (55-59 kHz)". Replace with outcome-language operator-friendly equivalents and move the patent / source detail into tooltips and CHANGELOG. Per-label product judgment required, not a mechanical rename.
2. **Quiet the visible help prose.** `TabHelpBox` sits at the bottom of every Processing / RDS / Snapshots / Test Tone tab, plus several cards have explanatory `Text` blocks. Apple HIG-aligned pro apps keep primary control surfaces scannable. Move longer explanations into `.help()` tooltips, README, or an Advanced inspector; keep only safety-critical one-liners inline.
3. **Stronger sidebar enabled-state affordance.** `StageSidebarRow` shows a 6 pt accent dot with `accessibilityLabel("Enabled")`. The dot is subtle on its own — consider a small native status badge, a secondary text label, or both. Verify contrast in light mode, dark mode, increased contrast, and grayscale.
4. **Meter accessibility audit.** `UIBroadcastMeter` and `UIBroadcastStatusBar` have zero `accessibilityLabel/Element/Value` annotations. VoiceOver users get no meaningful summary of input level, output level, GR, budget, pilot/RDS state. Add semantic group summaries; mark high-frequency decorative visual updates as `accessibilityHidden` so they don't flood the announcer.
5. **Control density review.** Final Stage, Audio Limiter, Multiband, RDS Program / Schedule / Carrier tabs are dense for amateur operators. Consider disclosure groups (`DisclosureGroup`) for advanced / experimental controls so the common workflow stays clean. Format Profile already does most of the work here; this is the per-tab polish that follows.

## Code-quality priorities

### P0 — Confidence and safety
1. Add deterministic unit tests for AGC envelope behavior, filter primitives (PreemphasisFilter, DeemphasisFilter, Biquad, BiquadCascade6), stereo coding M/S round-trip sanity, and bypass-path null-signal tests.
2. Fix the verifier bandwidth metric so RDS does not produce misleading occupied-width failures (`bright_dense` occ999 warning disappears when `en_rds = False`).
3. **Render-path scratch growth is a real-time safety risk.** `AudioOutputEngine.ensureMonitorScratchCapacity(frames:)` and `ensureAnalysisScratchCapacity(frames:)` allocate arrays if the buffer is smaller than the render frame count. Normal operation uses the `preAllocateBuffers(maxFrames:)` path so it shouldn't fire, but the fallback exists and would allocate on the audio thread if CoreAudio delivers a larger-than-expected buffer (post device change, post hardware buffer duration change). Convert the runtime capacity check into a debug assertion or pre-start failure; track max observed frame count outside the render path.
4. **Stored receiver baseline file.** `--verify --baseline-strict` now passes against the composite-side `default.json` (refreshed 0.30 default-on), but receiver-side metrics (separation @ 1/10/14 kHz, pilot level error, RDS-band RMS, stereo correlation, mono/no-pilot, sideband balance) are NOT pinned. Promote unexpected `postInjectionOvershoot > 0` from TIGHT/WARN to a hard failure for normal presets, then add stored receiver baselines alongside the composite baseline.

### P1 — Structural cleanup
1. Split `MPXGenerator.swift` (~7900 lines now) into stage-focused components.
2. Split `AudioOutputEngine.swift` by concern (device routing, capture, render loop, metering, monitoring).
3. Split `SwiftUIControlApp.swift` (~7600 lines now) into smaller views and state holders.
4. Reduce hidden coupling between engine, config, generator, and UI state.

### P2 — Harden behavior
1. Strengthen `AppConfig` validation (invalid ranges, illegal combinations, impossible sample-rate/block-size).
2. Re-tune final-stage composite headroom for vocal/transient stability (`sum_level` 1.0 → 0.9 investigation).
3. Harden device and routing edge cases.
4. Make error reporting more structured.
5. **Consolidate `plan.md` and `FUTURE.md` overlap.** Both files describe current status and future DSP items; some items appear in one as landed and the other as remaining. Keep `plan.md` as the active prioritized roadmap; collapse `FUTURE.md` into pointers / "low-priority ideas only" or fold into `plan.md` directly. Remove status tables that duplicate `CHANGELOG.md`.

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

| Piece                          | Effort    | Blocking              |
| ------------------------------ | --------- | --------------------- |
| Backend protocol + JACK impl   | 2-3 weeks | Audio I/O             |
| ALSA fallback impl             | 1 week    | Audio I/O             |
| Lock primitive abstraction     | 2 days    | All audio-thread code |
| Device enumeration abstraction | 3-5 days  | UI + CLI              |
| Headless Linux CLI polish      | 3-5 days  | Usability             |
| vDSP audit + replacement       | 1 week    | Metering / spectrum   |
| SPM conditional compilation    | 2-3 days  | Build                 |
| Linux CI                       | 1 day     | CI                    |
| Web dashboard (optional)       | 2-3 weeks | Better UX             |
| Distribution packaging         | 1 week    | Ship                  |

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

## Pre-emphasis placement (history)

Ships in L/R, immediately upstream of the pre-encode limiter (canonical Optimod / Stereotool placement); `preL` / `preR` in `processSampleDetailed`. The b806053 cost regression that historically reverted this in 0.10 is no longer reproducible on the post-0.24 chain — vvtanhf, vDSP_dotpr, FIR multiband, and differential composite clipper optimizations cut absolute chain cost from ~95% to ~28% of real-time, absorbing the ~7% relative increase. If dynamic pre-emphasis (7.6) ever lands, either modulate `preL` / `preR` tau in place, or build a dedicated sidechain detector.

## Design constraints

- Keep realtime callbacks lock-free and allocation-free. Snapshot writes use `OSAllocatedUnfairLock` (priority-inheriting) — any new audio-thread cross-thread communication must use the same primitive or an atomic, never `NSLock`.
- Do not move shell/file/network work into DSP paths.
- Preserve integrated RDS and monitoring workflow.
- Keep monitor-output latency separate from transmit-path quality.

## References

### Prior art / DSP background
- [US 4,460,871 — Variable-frequency-shift demodulator (Orban, expired)](https://patents.google.com/patent/US4460871A/en)
- [US 5,168,526 — Distortion-cancellation circuit (Orban, expired)](https://patents.google.com/patent/US5168526A/en)
- [US 5,737,434 — Multi-band audio compressor (Orban, expired)](https://patents.google.com/patent/US5737434A/en)
- [US 6,434,241 — Half-cosine interpolation composite limiter (Orban, expired)](https://patents.google.com/patent/US6434241B1/en)
- [US 6,937,912 — Anti-aliased clipping with band-limited step functions (Orban, expired)](https://patents.google.com/patent/US6937912B1/en)
- [US 5,579,404 / EP 0685130 — Digital audio limiter with subband-aware look-ahead (Dolby, expired 2013-2014)](https://patents.google.com/patent/US5579404A/en)
- [US 4,208,548 — Peak-limiting audio frequency signals (delay+detector prior art, expired ~1997)](https://patents.google.com/patent/US4208548A/en)
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
