# MPX Prime Roadmap

Active work list + anti-rework guardrails. **Not** a readme: positioning, architecture, and build live in `README.md` / `docs/ARCHITECTURE.md` / `docs/BUILDING.md`; shipped-feature history lives in `CHANGELOG.md`. Don't re-plan shipped work as pending — cross-check CHANGELOG before acting.

## Status

Released through **0.41** (2026-07-10). **Active branch: `develop/v.042`**; 0.42 is the Unreleased target (see `CHANGELOG.md` for its accumulated content). Shipped-feature history lives in CHANGELOG — this file tracks only pending work; cross-check CHANGELOG before planning anything here as pending.

Major work landed since the roadmap was last pruned: MPX Prime Meter (0.37, receive/analyze companion + measurement-grade metering); the **Linux CLI port** of the encoder (headless + ALSA, SIMD acceleration shim, Debian/Ubuntu packages); and the **REST API + embedded web dashboard** (remote control, both platforms). All three were previously listed here as future work and have been removed from the sections below.

---

# Open work

## Next up

1. **Anti-aliased clipping kernel (US 6,937,912).** Phase A/B landed opt-in (`pre_encode_bandlimited_residual_enabled`). Remaining: A/B real program with it on, decide whether any loud preset enables it; optional Phase C applies the primitive to `softClipSafety` in `processFinalComposite` only if B proves benefit (keep pilot/RDS injection post-processing + budget-governor invariant); refresh baselines on real program.
2. **Tune/validate composite clipper look-ahead.** `mpx_clipper_lookahead_ms` shipped; dense real-program A/B at 0.5 / 1 / 2 ms, verify pilot/RDS guard cleanliness, decide loud-preset default. Capture via `MPXPRIME_AUDIT_CAPTURE=1` → `macOS/.audit-out/lookahead/`.
3. **Smoke-test pass.** Live-apply vs restart-required on difficult real material; catch transients/clicks/dropouts on toggle. New RDS live-apply paths (PI/PTY/flags/AF/scheduler) need real-receiver checks beyond the bit-stream tests.
4. **Extend baselines to `--verify-presets` and `--verify-long`.** Same `VerifierBaselineFile` schema, different scenario sets.
5. **Receiver-model verifier hardening.** v.036 added the pilot/RDS phase-lock gate + guard-band-depth measurement to `--verify-receiver` and the encoder-sideband baseline. Remaining: promote unexpected `postInjectionOvershoot > 0` from TIGHT/WARN to a hard failure for normal presets; add stored receiver-side baselines (separation @ 1/10/14 kHz — now ~98/86/97 dB, pilot error, RDS-band RMS, correlation, mono/no-pilot, sideband balance) so the decoder gains are pinned against regression.
6. **HF stereo separation — `MPXDecoder` audit. DONE (develop/v.037).** Root cause was the pre-demod pilot/RDS notches clipping the S-channel sidebands; removed them — separation 65/51.6/44.2 → 98.3/86.1/97.2 dB at 1/10/14 kHz, composite untouched. See "Settled findings".

## Opt-in advanced stages — validate + decide default

Highest-leverage audible-gap closer vs the enterprise tier: these stages are implemented and shipped but **default-off and not preset-validated**, so a fresh install runs below the chain's real capability. Each needs a verifier/listening A/B → a per-preset enablement decision. OFF must stay bit-identical (`--verify --baseline-strict` green); ON validated via `--verify-receiver` (separation + pilot/RDS guards unchanged).

1. **Pre-emphasis-aware HF clipper** (`hf_clipper_*`, shipped 0.35, default off). Dense EDM/pop A/B; decide which loud presets enable it. One of the two real audible gaps vs an Optimod.
2. **Multiband Phase 2 — transient-aware attack** (`multiband_transient_aware_attack_enabled`). Verifier + dense-percussive listening A/B; preset decision.
3. **Multiband inter-band coupling** (`multiband_inter_band_coupling_enabled`, `--verify-multiband-coupling`). "Loud bass softens highs" — listening A/B; preset decision.
4. **Anti-aliased residual clipping** (`pre_encode_bandlimited_residual_enabled`) — see Next up #1.
5. **Composite multiband clipping** (`mpx_multiband_clipper_enabled`) — see Broadcast-tier follow-ups.

## Experimental candidates -- RuleBreaker-inspired (parked 2026-08-01, user decision)

Analysis of Thimeo's RuleBreaker press release (loudness/cleanliness claims) mapped onto our chain; all would ship off-by-default and verifier-gated. We cannot know Thimeo's actual method -- these are our own defensible readings backed by the interleaving math.

1. **`pre_encode_stereo_link` blend (small).** The audio composite is bounded by `max(|L|,|R|)` at every instant (convex-combination identity), but `StereoLinkedOversampledPeakLimiter` rides ONE shared gain from `max(|L|,|R|)` -- needlessly attenuating the quiet channel whenever the loud one limits. A link factor 0..1 (1 = current linked behavior) recovers ~2-3 dB integrated loudness on wide program at IDENTICAL composite peak, distortion-free (gain riding, not clipping); cost is momentary image shift toward the limited side. The shared-envelope code already exists; the experiment is the blend + an image-stability verifier scenario.
2. **`mpx_clipper_iterations` (moderate).** POCS-style iterative clip -> re-project (bandlimit + protected bands) composite peak control; our differential clipper + guard-band cancellation is one iteration of exactly this. 2-4 iterations at OS rate, CPU-gated by `DSPThroughputTests`, measured by guard-band depth / >60k leakage / receiver separation.
3. **Studio<->Meter closed-loop RF trim (large).** Their "analyzes RF bandwidth after the exciter" loop; the Meter's RF spectrum (0.43) is the sensor. Auto-trim clipper drive against occupied-bandwidth targets. Needs the control API on the Studio side + a Meter export path first.

## Broadcast-tier follow-ups

- **Multiband Phase 3 — per-band look-ahead.** Reuse `LookaheadLimiter` ring-buffer per band. Largely redundant with Phase 2; skip unless dense percussive listening shows Phase 2 isn't enough. ~3–5 d.
- **Multiband composite clipping** (`mpx_multiband_clipper_enabled`, `--verify-composite-multiband`). Phase 1 opt-in landed. Remaining: dense-program listening, oversampling refinement if HF aliasing audible, preset decision.
- **Stereo-band cancellation depth via FIR bandpass.** Optional/depth-only. Delta substitution gets ~5–10 dB in the stereo subband (LR4 phase-bounded); linear-phase FIR bandpass would push to 20+ dB. Only if listening (Next-up #1) says residual cross-domain IM is audible at amateur drive.
- **Audio-clipper oversampling bump.** `BassClipper` 4×→16×, `DistortionCancelledClipper` 8×→16–32×, likely swapping `BiquadCascade6` decimation for `LinearPhaseFIRDecimator`. Polish (aliasing already inaudible at amateur drive); ~1–2 d each + baseline refresh. Aliasing gate: `DistortionCancelledClipperTests.aliasingEnergy` (−38 dBFS now; pro chains push past −75).

## Open gaps

1. **Calibration workflow** — exciter-facing guidance + long-run operational hardening.
2. **AGC validation** — density-scaling tuning on real program; decide whether a lookahead path is worth the latency.
3. **Stereo image validation** — mono bass / widener / PrimeBass / multiband interaction on difficult real program.
4. **Live-apply smoke testing** — TA-edge auto-injection and AF Method B switching in particular.

## Verifier coverage follow-ups

1. **Tighten bandwidth baseline tolerance** (±1.0 → ±0.5 dB) with a multi-frame averaged FFT to cut spectral leakage in the `>60k/>67k` ratios.
2. **AppConfig-vs-sample-INI default lint** — flag drift between code defaults and shipped sample INIs (Verification.ini intentionally differs; whitelist it).
3. **BS.412 full-chain long-run scenario** — component limiter is unit-tested (`BS412PowerLimiterTests`); a `--verify-long`-style full-chain check over 30+ s is still uncovered (deferred for render cost).

## Tactical backlog

**Release-blocking:** smoke-test live-apply vs restart-required; tune composite clipper defaults (drive / ceiling / `mpx_clipper_lookahead_ms`) so a fresh install audibly beats `mpxgen` / PiFmRds untweaked.

**Sprint:** validate PrimeBass / mono bass / widener / multiband on difficult real material; refine calibration workflow where real operator friction exists; per-Format-Profile clipper-drive A/B (eight 0.30 profiles).

**Medium-term:** dedupe biquad/crossover filter-config logic; name DSP magic numbers; deterministic RDS-scheduler tests; more AGC / filter-primitive unit tests.

## Code-quality priorities

**P0 — confidence/safety**
1. Deterministic primitive tests: Biquad/BiquadCascade6/LR4/Lagrange/FIR decimator (`FilterPrimitiveTests`), AGC envelope (`AGCDetectorTests`), and Preemphasis/Deemphasis (`PreemphasisFilterTests`, added v.037) are all covered. Remaining low-value gaps only: an isolated M/S encode round-trip (algebra is trivial; chain separation tests already exercise it) and a focused bypass-null contract (the `DeepDSPTests` "Silence" input already covers it at chain level). Effectively done.
2. Fix verifier bandwidth metric so RDS doesn't skew occupied-width (`bright_dense` occ999 reads differently with `en_rds` on/off). NOTE: this is a metric *redefinition* (exclude the 57 kHz RDS band from the occupied-width / above-60k/67k power sums), not an active bug — the threshold + baseline already account for RDS. Cascades into 3 baselined bandwidth fields → recapture. Decide the metric's intended meaning (audio-only width vs total composite) before doing it.
3. **DONE.** Render-path scratch growth already guarded: `ensureMonitorScratchCapacity`/`ensureAnalysisScratchCapacity` carry an `assertionFailure` debug trap + release-only graceful grow, `recordObservedRenderFrames`/`maxObservedRenderFrameCount` track the max off the render path, and `preAllocateBuffers` sizes to ~100 ms (>> any CoreAudio block).
4. **DONE (v.037 + already).** Stored receiver baseline landed (`receiver.json`, `--verify-receiver --baseline-strict`). `postInjectionOvershoot > 0` is already a hard fail (`naturalResult = 2`) on the composite path.

**P1 — modularization** (MPXPrimeCore is the forcing function; companion-app needs the same boundaries)
- `MPXPrimeCore` target landed: `MPXDecoder` + DSP primitives (Biquad/BiquadCascade6/DeemphasisFilter) + symmetric `RDSStreamDecoder`. Hot `process()` is `@inlinable` so it still inlines across the module boundary.
- Remaining: extract the RDS subcarrier front-end (57 kHz mixdown → biphase symbol+clock recovery → differential decode) feeding `RDSStreamDecoder`, and an `MPXAnalysisTap`/FFT helper; split `MPXGenerator.swift` into stage files; split `AudioOutputEngine.swift` by concern; split `SwiftUIControlApp.swift` one-card-per-file; reduce engine/config/generator/UI coupling.

**P2 — harden behavior:** stronger `AppConfig` validation; `sum_level` 1.0→0.9 investigation; device/routing edge cases; structured error reporting; consolidate `plan.md`/`FUTURE.md` overlap.

**P3 — performance:** more vDSP where profiling shows value; cache RDS byte prep; hot-path benchmarks; keep an Instruments baseline.

## UX / accessibility polish

The GUI HIG/professional/usability/accessibility pass landed on develop/v.037 (state feedback: restart badges + clickable pending chip + RDS counters; overview live status; About rework; dropout WCAG fix; flow-strip bypass; `BroadcastStyle` tokens; status-bar + meter VoiceOver incl. the Levels group summary). Meter accessibility (the old item 3) and dense-tab DisclosureGroups (old item 4, started 0.35) are done. Remaining, lower-priority:

1. **Format-profile drift indicator.** When the config drifts from the selected Format Profile, show the picker as "edited". Real feature but needs `applyFormatProfile` refactored into a pure function + a decision on which fields count as drift; the model author deferred it ("no dirty indicator in v1"). A half-correct version gives false "edited" flags, so do it properly or not at all.
2. **Prose-to-tooltip sweep.** Mostly already appropriate — the house rule keeps *distinct actionable guidance* inline; little remains safe to move. Low value.
3. **Dynamic Type pass.** Manual: launch with large system text, verify no clipping/overlap across tabs (fonts are already semantic, so likely nothing to fix). Eyes-on, not a code task.
4. **Sidebar-row enabled affordance.** Overview cards now carry status dots; the `StageSidebarRow` 6 pt dot is unchanged — optional native status badge / contrast check.

## RDS enterprise tier (stretch — only if direction shifts to multi-station)

1. **UECP SPB 490 minimal subset over TCP/IP** (port 5570, DLE framing, MEC parse for PI/PS/PTY/RT/AF/TA/scheduler/master-enable, address fields). Hooks into `applyRDSRuntimeConfig`. ~1–2 wk, new `UECPServer.swift`.
2. **EON (14A/14B)** — linked-network PI/PS/AF/TP/TA mirroring across PSNs. ~3–5 d.
3. **Multi-PSN / Data Sets** — per-PSN `RDSRuntimeConfig`, boundary switchover without PI flap. ~1 wk, builds on UECP.
4. **Ops: SNMP MIB + watchdog + time-of-day scheduler + on-air loopback verify.** ~2–3 wk.
- Deferred standards item: Group 15A UTF-8 Long PS toggle bit (IEC 62106-2:2018 §6.8; ASCII Long PS is correct for amateur use today).

## Shipped (was future here) — see CHANGELOG for detail

- **MPX Prime Meter** (0.37+): the receive/analyze companion — SDR / audio
  input, standards-grade metering, RDS decode, WAV recording. No longer
  future work.
- **Linux CLI port** of the encoder: headless `--nogui` into ALSA, all
  `--verify*` / `--bench`, SIMD acceleration shim (SSE2; full FIR + 16x
  clipper chain fits a Celeron J4105 at ~92% CPU), Debian/Ubuntu packages
  + systemd service, per-platform strict baseline. Delivered ALSA-only
  (no JACK / no `AudioBackend` protocol abstraction — the render-callback
  contract is shared via the existing engine entry points).
- **REST API + embedded web dashboard** (remote control, both platforms):
  built on **Hummingbird 2** (not the Vapor originally sketched here);
  `[CONTROL]` INI section, `--web`/`--control-port`, config/RDS/preset/
  transport endpoints, GUI-parity dashboard.

## Linux port — remaining / possible follow-ups

- JACK backend behind an `AudioBackend` protocol (today ALSA-only); Pi 4/5
  real-time budget still unmeasured.
- Meter CLI on Linux (the tuner C++ is already portable; SDRplay dlopen
  needs `.so` names).
- ALSA output device enumeration is in the dashboard picker; a headless
  `--list-devices` equivalent could mirror it.

---

# Anti-rework guardrails — do not re-plan / re-implement

## Active patent backlog

| Priority | Patent | Title | Expires | Stage | Why |
| -------- | ------ | ----- | ------- | ----- | --- |
| **P0 — validate / Phase C** | [US 6,937,912](https://patents.google.com/patent/US6937912B1/en) | Anti-aliased clipping with band-limited step functions | 2025-09 | `OversampledPeakLimiter` (pre-encode L/R) landed opt-in; `audioCompositeSoftClipEnabled` shaper still candidate | Phase A/B landed opt-in via `pre_encode_bandlimited_residual_enabled`. Remaining: program validation, then optional Phase C on the audio-composite shaper. |
| **P1** | [US 6,434,241](https://patents.google.com/patent/US6434241B1/en) | Half-cosine signal peak control | 2014-08 (lapsed) | Same stages as P0, alternative kernel | Continuous-first-derivative half-cosine peak; overshoot ~10% → 0.1–0.2%. Less IM rejection than US 6,937,912 but lower CPU. Selectable kernel / fallback. |
| **P3** | [US 5,892,833](https://patents.google.com/patent/US5892833A/en) | Gain calibration for audio compressors | Expired | `MonoCompressor` makeup stage | Track average GR to keep makeup roughly compensating. Polish, low priority. |
| **P6** | [US 7,076,071](https://patents.google.com/patent/US7076071B2/en) | Ambience/imaging enhancement (mono-null bus) | Expired | Stereo widener | Invariant: any enhancement term must cancel in `L+R`. Land first as a verifier metric (mono-sum delta widener on/off), then constrain the widener to meet it. FM-safe answer to Open-gaps #3. |
| **P7** | [US 4,567,607](https://patents.google.com/patent/US4567607A/en) | Stereo image recovery (frequency-bounded crossfeed) | Expired 2003-01-28 | Stereo widener | Crossfeed below ~1–5 kHz, bounded phase difference, shaped mono dip ~200–900 Hz. Pairs with P6 as widener guardrails. |

P4 (US 4,249,042) + P5 (US 3,790,896) landed in 0.34 as the bass-desensitised wideband AGC (`wideband_agc_bass_desensitize`, opt-in). Optional extension: **silence-sense freeze** ([US 4,500,753](https://patents.google.com/patent/US4500753A/en), Gentner, expired 2003) — freeze AGC recovery during near-silence.

## Already implemented or structurally equivalent (do not re-implement)

| Patent | Title | Where in code | Note |
| ------ | ----- | ------------- | ---- |
| [US 6,337,999](https://patents.google.com/patent/US6337999B1/en) | Oversampled differential clipper | `CompositeClipper` (commit `d1d8180`, post-0.11) | Differential topology standard; only the clipping residual is decimated. |
| [US 6,618,486](https://patents.google.com/patent/US6618486B2/en) | BS.412 dual-integrator MPX power controller | `BS412PowerLimiter` | Functionally equivalent: power-detect → rolling 60-s window → per-block S&H → gain attack/release → feedback ride. Flat rolling window instead of leaky integrator (harder, more compliance-predictable). Lapsed 2015-09-09. |
| [US 5,913,152](https://patents.google.com/patent/US5913152A/en) | FM composite processor with pilot extract/re-sum | Different architecture, same end-state | Pilot protected by (1) post-clipper subcarrier injection (project invariant) + (2) RBJ-BPF cancellation in the 17–21 kHz guard inside `CompositeClipper`. Extract/re-sum on top would be redundant. Expired 2015-12-29. |
| [US 4,737,725](https://patents.google.com/patent/US4737725A/en) | Pre-LPF overshoot compensation (Inovonics) | `OversampledPeakLimiter` (4× OS) | The analog clip→phase-lag→re-clip→recover technique is what modern oversampled true-peak limiters do digitally. Expired 1996-04-17. |
| [US 5,737,434](https://patents.google.com/patent/US5737434A/en) | Multi-band compressor with cross-band coupling | `MonoCompressor` per-band logic | Inter-band coupling landed opt-in 0.28 (`multiband_inter_band_coupling_enabled`, `--verify-multiband-coupling`). Listening validation pending. Expired. |
| [US 5,579,404](https://patents.google.com/patent/US5579404A/en) / [EP 0685130 B1](https://patents.google.com/patent/EP0685130B1/en) | Digital audio limiter — subband-aware look-ahead | `StereoLinkedOversampledPeakLimiter` (pre-encode L/R) | Both phases default-on in 0.30 (textbook delay+detector look-ahead, US 4,208,548 prior art, 1 ms; Dolby split-band 4 kHz HF detector). Dolby; US expired ~2013-11, EP ~2014-02. |

## Bass enhancement (PrimeBass) — already implemented (do not re-implement)

| Patent | Title | Where in code | Note |
| ------ | ----- | ------------- | ---- |
| [US 5,930,373](https://patents.google.com/patent/US5930373A/en) | Waves MaxxBass — equal-loudness-weighted harmonic synthesis | `processPrimeBass` + `configurePrimeBassFilters` (`4d4a70f`) | Even (asymmetric squarer) + odd (tanh-difference) generators with per-order weights from an ISO 226 phon-curve approx at 2..5×F0; direct LF gain tapered (`primeBassDirectGainReduction = 0.62`) so perceived bass shifts onto harmonics, buying downstream headroom. |
| [US 4,150,253](https://patents.google.com/patent/US4150253A/en) | Aphex Aural Exciter — HP-then-clip | `processPrimeBass` (`4d4a70f`) | Adapted: a pre-waveshaper *allpass* at F0 (not HPF) rotates phase ~180° without amplitude loss, decorrelating harmonic phase from the direct path so they don't comb-filter at the bass-clipper input. |
| [US 5,424,488](https://patents.google.com/patent/US5424488A/en) | Werrbach transient-discriminate harmonics (Aphex) | `processPrimeBass` Phase 2 (`af7b883`) | Dual-envelope transient detector (fast − slow, normalized) modulates harmonic-band gain 0.7× sustain → 1.4× peak on onsets. Verified via `transientGainObserved`. |
| [US 5,359,665](https://patents.google.com/patent/US5359665A/en) | Werrbach Big Bottom — dynamic bass extension (Aphex) | `processPrimeBass` Phase 3 (0.23) | LF-envelope follower (~10 ms attack / ~300 ms release) drives `primeBassAdaptiveGain` — "envelope duration extension". Verified via `primeBassAdaptiveGain`. |

## Skipped — active patents or non-additive (design-around noted)

| Patent | Status | Reason |
| ------ | ------ | ------ |
| [US 9,712,916](https://patents.google.com/patent/US9712916B2/en) DTS "Bass Enhancement System" | **ACTIVE** to ~2032-12-19 | Headroom-coupled adaptive gain on MaxxBass. Design-around: fixed/program-dependent gain not driven by instantaneous headroom. |
| [US 9,319,789](https://patents.google.com/patent/US9319789B1/en) Music Tribe "Bass Substitution Filter" | **ACTIVE (reinstated)** to ~2032-02-11 | Level-tracking centre-frequency modulation of the harmonic filter. Design-around: fixed centre frequency, amplitude-only modulation. |
| [US 4,482,866](https://patents.google.com/patent/US4482866A/en) BBE Sonic Maximizer | Expired 2002-02-26 | Frequency-dependent group-delay correction — actively harmful in FM (breaks pilot/subcarrier coherence). |
| [US 4,748,669](https://patents.google.com/patent/US4748669A/en) SRS / Hughes | Expired | Stereo enhancement via L−R, not bass. Misclassified in earlier surveys. |

## Skipped — evaluated and rejected

| Patent | Title | Status | Reason |
| ------ | ----- | ------ | ------ |
| [US 7,295,628](https://patents.google.com/patent/US7295628B2/en) | DSP MPX with sample-frequency-aligned vestigial sideband | Expired 2024-07-30 | Requires `fs = 2 × fmod` (76 kHz chain). Our chain runs 192 kHz throughout; adopting means a full chain-rate refactor. Niche AM/SSB technique; FM's DSB-SC is what receivers expect / IEC 62106 mandates. |
| [WO 2017/186756](https://patents.google.com/patent/WO2017186756A1/en) | Frequency-domain L+R/L−R protector | PCT ceased; **CA3021918 possibly enforceable to 2037** | Legal: verify before any CA distribution. Technical: per-block FFT of M and S is CPU-expensive + adds OLA latency; M/S-domain dynamic L−R limiter achieves similar mono-compat without FFTs. |
| [US 4,412,100](https://patents.google.com/patent/US4412100A/en) | Multiband signal processor (Orban) | Expired 2001-09-21 | 1981 distributed-crossover multiband+clippers — structurally the prior art for what we already ship (FIR multiband + per-band `MonoCompressor` + differential composite clipper), at a less modern level. Nothing to adopt. |
| [US 7,587,254](https://patents.google.com/patent/US7587254B2/en) | DR processor with auxiliary decorrelation in L+R limiter sidechain | ~2029 | Filed 2004; not yet expired. Revisit post-2029. |

## Settled findings

**Pre-emphasis placement.** Ships in L/R immediately upstream of the pre-encode limiter (`preL`/`preR` in `processSampleDetailed`; canonical Optimod/Stereotool). The b806053 cost regression that reverted this in 0.10 is no longer reproducible post-0.24 (vvtanhf / vDSP_dotpr / FIR multiband / differential clipper cut chain cost ~95% → ~28% RT, absorbing the ~7% relative increase). Do not relocate to M/S.

**MPXDecoder has no pre-demod pilot/RDS notch (do not re-add).** The decoder used to notch the 19 kHz pilot and 57 kHz RDS on the common signal before the M/S split; the notch skirts asymmetrically attenuated the S-channel DSB-SC sidebands (38 +/- f), the dominant HF stereo-separation limiter (14 kHz capped ~44 dB). Removed on develop/v.037 → 97 dB at 14 kHz. Pilot/RDS are handled by the 15.5 kHz M-path lowpass + S-path `diffLP` + the post-recombination `pilotNotchL/R`. The decoder only sees the app's own clean composite (monitor path + `--verify-receiver`), so there is no off-air noise the notches protected against. If `MPXPrimeMeter` later decodes noisy off-air composite, add input conditioning *there*, not back in the shared decoder.

**Composite-clipper guard cancellation depth (measured, not a defect).** v.036 measured the clipper's guard cancellation in isolation (upstream nonlinearities off, clipper driven hard): pilot guard ~11.8 dB, RDS guard ~12.7 dB, residual IM ~−50 dBFS in both — clean in absolute terms. Aligning the decimator group delay to an exact integer host-sample count (removing the ~2 OS-sample bypass/residual offset) was implemented and measured: **no change** to depth or residual, at ~10% more clipper taps → reverted. The misalignment noted in `LinearPhaseFIRDecimator.groupDelayHostSamples` is confirmed negligible. If depth ever needs to go deeper, the binding constraint is the guard bandpass Q / delta-substitution match, not decimator alignment.

## Design constraints

- Realtime callbacks stay lock-free / allocation-free. Cross-thread audio-thread comms use `OSAllocatedUnfairLock` (priority-inheriting) or an atomic — never `NSLock`.
- No shell/file/network work in DSP paths.
- Preserve integrated RDS + monitoring workflow; keep monitor-output latency separate from transmit-path quality.
- Subcarriers (19 kHz pilot, 57 kHz RDS) injected after all peak-control stages; pre-emphasis in L/R before the pre-encode limiter. (Full invariants in CLAUDE.md.)

## References

- [US 4,460,871 — Variable-frequency-shift demodulator (Orban)](https://patents.google.com/patent/US4460871A/en) · [US 5,168,526 — Distortion-cancellation circuit (Orban)](https://patents.google.com/patent/US5168526A/en)
- [Stereotool — Limiting and Clipping](https://www.thimeo.com/documentation/limiting_and_clipping.html) · [Telos RDS guidance](https://docs.telosalliance.com/docs/rds)
- Anti-aliasing background: Välimäki "Discrete-Time Modelling…" (1995), Brandt "Hard Sync without Aliasing" (2001), Stilson/Smith "Alias-Free Digital Synthesis…" (1996).
- Open-source peer set: `mpxgen` (no processing), `PiFmRds` (Pi-only), Stereotool free (closed-source); Liquidsoap is the common amateur-station backbone / future JACK target.
