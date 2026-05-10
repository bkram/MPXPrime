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

## Patent-backed improvements backlog

Expired patents (public domain) that map onto specific stages of the
chain. Listed in priority order by expected impact on the verifier-
flagged stress scenarios (`hf_edge_12k` >67k IM, side retention;
`bright_dense` rms drift). Caveat: the verifier scenarios run with
`mpx_clipper_enabled = False`, so improvements to the
`CompositeClipper` itself do not move the verifier numbers — they
land on the user-facing audio path only when the clipper is
explicitly enabled.

### Active backlog

| Priority | Patent                                                           | Title                                                  | Expires          | Stage                                                                              | Why                                                                                                                                                                                                                                                                                                                                                         |
| -------- | ---------------------------------------------------------------- | ------------------------------------------------------ | ---------------- | ---------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **P0**   | [US 6,937,912](https://patents.google.com/patent/US6937912B1/en) | Anti-aliased clipping with band-limited step functions | 2025-09          | `OversampledPeakLimiter` (pre-encode L/R) + `audioCompositeSoftClipEnabled` shaper | Replaces the inner clip kernel: when a peak crosses threshold, substitute a band-limited polyBLEP-style step matched to the host filter's group delay. Stops IM from being generated rather than relying on decimation to remove it. Both stages are engaged in the verifier scenarios — this is the patent that moves the `>67k/in` and `>60k/in` numbers. |
| **P1**   | [US 6,434,241](https://patents.google.com/patent/US6434241B1/en) | Half-cosine signal peak control                        | 2014-08 (lapsed) | Same stages as P0, alternative kernel                                              | Continuous-first-derivative half-cosine peak; overshoot drops from ~10 % to 0.1–0.2 %. Less effective than US 6,937,912 for IM rejection but lower CPU. Useful as a selectable kernel or fallback.                                                                                                                                                          |
| **P2**   | [US 5,737,434](https://patents.google.com/patent/US5737434A/en)  | Multi-band audio compressor with cross-band coupling   | Expired          | `MonoCompressor` per-band logic in multiband stage                                 | Inter-band gain coupling — "loud bass softens highs", the Optimod 8500/8600 multiband behaviour we don't have. Already in plan.md item 4 of multiband DSP modernisation; named here for the patent reference.                                                                                                                                               |
| **P3**   | [US 5,892,833](https://patents.google.com/patent/US5892833A/en)  | Gain calibration for audio compressors                 | Expired          | `MonoCompressor` makeup-gain stage                                                 | Algorithmic gain-staging that tracks compressor's average GR to keep makeup gain roughly compensating. Polish item — low priority.                                                                                                                                                                                                                          |

### Already implemented or structurally equivalent (do not re-implement)

| Patent                                                                                                                                       | Title                                                     | Where in code                                                                                | Note                                                                                                                                                                                                                                                                                                                                                                                                           |
| -------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- | -------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [US 6,337,999](https://patents.google.com/patent/US6337999B1/en)                                                                             | Oversampled differential clipper                          | `CompositeClipper` (commit `d1d8180`, post-0.11)                                             | Differential topology now standard; only the clipping residual goes through decimation.                                                                                                                                                                                                                                                                                                                        |
| [US 6,618,486](https://patents.google.com/patent/US6618486B2/en) (= [US 2003/0142840](https://patents.google.com/patent/US20030142840A1/en)) | BS.412 dual-integrator MPX power controller               | `BS412PowerLimiter` ([`MPXGenerator.swift:1167`](macOS/Sources/MPXPrime/MPXGenerator.swift)) | Functionally equivalent: power-detect → first integrator (rolling 60-s window) → sample-and-hold (per-block flush) → second integrator (currentGain attack/release smoothing) → feedback gain ride. We use a flat rolling-average window instead of a leaky integrator (gives a harder, more compliance-predictable boundary). Lapsed 2015-09-09.                                                              |
| [US 5,913,152](https://patents.google.com/patent/US5913152A/en)                                                                              | FM composite signal processor with pilot extract / re-sum | Different architecture, same end-state                                                       | We achieve pilot protection through (1) post-clipper subcarrier injection (the project invariant — pilot is never IN the audio composite when the clipper sees it) and (2) RBJ bandpass cancellation in the 17-21 kHz pilot guard inside `CompositeClipper`. Both end-results: clipper IM does not corrupt the pilot. Adopting the patent's extract/re-sum path on top would be redundant. Expired 2015-12-29. |
| [US 4,737,725](https://patents.google.com/patent/US4737725A/en)                                                                              | Pre-LPF overshoot compensation (Inovonics analog circuit) | `OversampledPeakLimiter` (4× oversampled)                                                    | The patent's analog technique (clip → phase-lag → re-clip → recover clippings → re-inject) is what modern oversampled true-peak limiters achieve digitally. We have one. Expired 1996-04-17.                                                                                                                                                                                                                   |

### Bass enhancement (PrimeBass) — secondary backlog

Patents informing improvements to the `PrimeBass` adaptive low-band
enhancer (renamed from `Orbass` in 0.20 to remove the Orban-trademark
adjacency). Goal: enhance perceived bass while *reducing* true-peak
LF amplitude (so downstream bass clipper / pre-encode limiter /
composite clipper see less LF energy).

**B1, B2, B3, and B4 all landed.** B1 + B4 in 0.20 (commit `4d4a70f`),
B2 in 0.20 (commit `af7b883`), B3 queued for 0.23 on `develop/v.023`.
The bass-enhancement patent backlog is now complete; further LF
enhancement work would need new design directions (e.g., the
Music Tribe / DTS active patents listed below as "skipped" — both
have active patent claims through ~2032 so any work in those
directions needs a clear design-around or a wait).

**Already implemented:**

| Patent                                                          | Title                                                       | Where in code                                                       | Note                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| --------------------------------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [US 5,930,373](https://patents.google.com/patent/US5930373A/en) | Waves MaxxBass — equal-loudness-weighted harmonic synthesis | `processPrimeBass` + `configurePrimeBassFilters` (commit `4d4a70f`) | Even (asymmetric squarer) + odd (tanh-difference) harmonic generators with separate per-order weights derived from an ISO 226 phon-curve approximation evaluated at 2..5×F0 at configure time. Direct LF gain tapered down with the harmonics knob (`primeBassDirectGainReduction = 0.62`) so perceived bass shifts onto the weighted harmonics — buys headroom in the downstream bass clipper / pre-encode limiter without changing subjective bass weight.        |
| [US 4,150,253](https://patents.google.com/patent/US4150253A/en) | Aphex Aural Exciter — HP-then-clip topology                 | `processPrimeBass` (commit `4d4a70f`)                               | Adapted for bass extension: a pre-waveshaper *allpass* biquad at F0 (rather than a HPF, which would attenuate F0 itself) rotates phase ~180° without amplitude loss, decorrelating synthesised harmonics' phase from the direct lowboost path. Stops harmonics from summing coherently with the direct boost and comb-filtering at the bass clipper input.                                                                                                          |
| [US 5,424,488](https://patents.google.com/patent/US5424488A/en) | Werrbach transient-discriminate harmonics (Aphex)           | `processPrimeBass` Phase 2 (commit `af7b883`)                       | Dual-envelope transient detector — fast (5 ms / 30 ms) follower minus slow (50 ms / 250 ms) baseline, normalized — modulates the harmonic-band gain from a 0.7× sustain floor to a 1.4× peak on real onsets. "Punchy not boomy" character: reduces continuous HF energy on sustained material while preserving peak harmonic intensity on attacks. Verified via internal `transientGainObserved` accessor at three time points (pre-onset / 25 ms post / 350 ms sustained). |
| [US 5,359,665](https://patents.google.com/patent/US5359665A/en) | Werrbach Big Bottom — dynamic bass extension (Aphex)        | `processPrimeBass` Phase 3 (queued for 0.23 on `develop/v.023`)     | Direct LF-level envelope follower with fast attack (~10 ms) / slow release (~300 ms) drives `primeBassAdaptiveGain`. Replaces the prior spectral-ratio detector + transient-hold machinery (which tracked compositional balance over seconds and so couldn't engage on a typical drum hit before the hit was over). Net per-patent effect: "envelope duration extension" — same peak boost as a static gain, just held longer through the note tail. Verified via internal `primeBassAdaptiveGain` accessor at three phases (pre-onset / sustained / post-release). |

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
| [US 4,412,100](https://patents.google.com/patent/US4412100A/en)       | Audio limiter using FET attenuator                                                                | Expired                                                      | Analog circuit patent (1981, JFET as voltage-controlled resistor). Pre-DSP era; the modern DSP equivalent (envelope-driven gain reduction with attack/release) is how every compressor in this codebase already works.                                                                                                                                                                    |
| [US 7,587,254](https://patents.google.com/patent/US7587254B2/en)      | Dynamic range processor with auxiliary decorrelation in slowly-time-varying L+R limiter sidechain | ~2029                                                        | Filed 2004; not yet expired. Revisit post-2029.                                                                                                                                                                                                                                                                                                                                           |

## Next up

1. **Look-ahead composite peak control** — the highest-payoff loudness improvement remaining and the largest single remaining gap toward Optimod 8x00 / Omnia.9 / Stereotool. Today the composite clipper is purely time-symmetric soft-clip with no look-ahead; the final-stage MPX limiter has look-ahead but operates after pilot/RDS injection and so cannot help peak-bound the audio composite. Add a delay line + predictive peak detector to the composite clipper so gain reduction is applied before the peak arrives and overshoots are mathematically bounded. Estimated scope: 1–2 weeks. After this lands, preset tuning becomes more meaningful (the clipper's behaviour on dense program will be different).

2. **Preset tuning — make it sound great out of the box.** Composite clipper now ships clean (delta-based per-band substitution; (L-R) subcarrier sidebands within ~1 dB across the audio band) and the chain has been brought to canonical industry order. Time to push it. Tune `mpx_clipper_threshold_db`, `mpx_clipper_ceiling_db`, AGC density curve, and stereo widener defaults so a fresh install with no operator knowledge already sounds noticeably better than `mpxgen` / PiFmRds. Probably also: a small set of named presets (e.g. `clean`, `loud`, `community-radio`, `lpfm-conservative`) as INI fragments. Best done after #1 lands so defaults are tuned for the new clipper behaviour.

3. **Smoke-test pass.** Validate live-apply vs restart-required settings on difficult real material. Catch any transients / clicks / dropouts on toggle changes. Pre-release blocking item. The new RDS live-apply paths (PI / PTY / flags / AF / scheduler) need particular attention — most are tested at the bit-stream level but not against real receivers.

4. **Extend baselines to `--verify-presets` and `--verify-long`.** Same `VerifierBaselineFile` schema, different scenario sets. Once preset tuning lands the verify presets become more meaningful.

5. **7.6 — Dynamic pre-emphasis ("Smart HF").** Lookahead-based HF envelope follower; dynamically relax the pre-emphasis curve during HF transients to reduce clipper workload. Significant algorithm effort. Pre-emphasis is now in L/R upstream of the pre-encode limiter, so dynamic relaxation can either modulate the existing `preL` / `preR` filters in place or build a dedicated sidechain detector — both paths are now compatible with the production chain. Lower priority for amateur-grade; this is a polish item.

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

### Multiband DSP modernisation

Phase 1 (linear-phase FIR crossovers) shipped — phase-flat band reconstruction with –155 dB sum-to-flat error floor; eliminates the transient smear and inter-band pumping that made IIR-LR4 multiband sound worse than single-band on percussive content. Remaining phases:

- **Phase 2: Transient-aware attack + RMS/peak hybrid `EnvelopeFollower`.** Current detector is single-pole peak-only; commercial processors (Optimod's "Smart Attack") detect percussive transients and briefly stretch the attack so kick/snare fronts pass through without being squashed. Build a transient detector (peak-vs-RMS envelope ratio crossing threshold) and modify `MonoCompressor` to take a transient hint. Largest remaining audible win for percussive sources after Phase 1. Scope: ~1 week.
- **Phase 3: Per-band look-ahead.** Reuse `LookaheadLimiter`'s ring-buffer pattern per band so each band's compressor sees its peaks ~1–5 ms before they arrive. Largely redundant with Phase 2 once that's in. Scope: ~3–5 days.
- **Phase 4: Inter-band gain coupling.** Optimod-style "loud bass softens the highs" cross-band coupling. Refinement after the foundation is right; subtle. Scope: ~1 week.

### Composite clipper improvements

1. **Look-ahead composite peak control.** Modern processors (Optimod 8x00, Omnia.9, Stereotool) drive composite peak control from a sidechain that knows future peak amplitude, so gain reduction is applied before the peak arrives and overshoots are mathematically bounded. Today the composite clipper is purely time-symmetric soft-clip with no look-ahead; the final-stage MPX limiter has look-ahead but operates after pilot/RDS injection. Add a delay line + predictive peak detector to the composite clipper. Estimated scope: 1–2 weeks. **Highest-payoff loudness improvement remaining.**

2. **Multiband composite clipping.** Spectral-band-specific clip thresholds give more loudness for the same peak modulation and avoid the tonal-shift artifact heavy clipping produces. Optimod 8x00's loudness lift on dense program comes from this. Single-band clipping hits a wall ~1.5 dB earlier. Larger lift than #1 alone — split the audio composite at e.g. 200 Hz / 2 kHz / 8 kHz, clip each band against its own threshold, recombine. Estimated scope: 2–4 weeks. Builds on the linear-phase FIR decimation already shipped for clean spectral splits.

3. **Stereo-band cancellation depth via FIR bandpass.** *Optional / depth-only.* The delta-based per-band substitution gets ~5–10 dB cancellation in the stereo subband — bounded by LR4 phase rolloff in the protected bands. A linear-phase FIR bandpass for the substitution would push this to 20+ dB without affecting subcarrier preservation. Worth doing only if listening evaluation in "Next up" #1 says the residual cross-domain IM is audible at amateur drive levels.

### Chain-order audit (industry comparison) — RESOLVED

Audit done 2026-05-09 against published Orban Optimod 8500/8600, Omnia.9/.11, and Stereo Tool architectures. The current chain matches industry practice on every load-bearing position — phase rotator early, AGC before EQ, multiband with per-band limiters, encoder lowpass before stereo encoding, composite clipper before BS.412, and pilot/RDS injection post-clipper at constant amplitude (the professional invariant). Three deviations from canonical ordering existed; **all three landed in the post-0.24 cycle** following a Phase 1 audit (see `macOS/.audit-out/chain_order/REPORT.md` if still on the local filesystem):

| Deviation | Status | Notes |
|---|---|---|
| **PrimeBass before multiband** | **Resolved.** Moved post-multiband. | Multiband no longer compresses synthesised harmonics. Phase 1 audit showed zero verifier-baseline drift on standard scenarios; listening confirmed on real program. |
| **Stereo widener before multiband** | **Resolved.** Moved post-multiband (still L/R domain; M/S variant skipped per audit decision). | Mono bass stays inside `processStereoImageStage`. Zero verifier drift; listening confirmed. |
| **Pre-emphasis in M/S after pre-encode L/R limiter** | **Resolved.** Moved to L/R immediately upstream of the pre-encode limiter; renamed `preSum`/`preDiff` → `preL`/`preR`. | The b806053 cost regression that originally motivated the M/S placement is no longer reproducible — chain optimizations between 0.10 and 0.24 cut absolute cost from ~95% to ~28% of real-time, so the 7% relative cost increase from upstream pre-emphasis is comfortably absorbed. C1 PASS at 1.07× release-build ratio; C2 sustained-load PASS over 30 s; HF guard band cleaner above 60/67 kHz on 5 verifier scenarios. |

The only known remaining drift is `hard_panned_hf` showing asymmetric L/R limiter response (per-channel limiters produce a +15 dB side-to-mid metric blowup on synthetic-pathological L-only HF chirps + R-only rumble). Listening on real program found no audible regression. If a future operator complaint surfaces on hard-panned material, the cheap fix is a stereo-linked `PreEncodeAudioLimiter` whose detector is `max(|L|, |R|)` (~1 day work).

### Enterprise-parity status

Where MPX Prime stands today against Optimod 8500/8600, Omnia.9/.11, and Stereotool. Structural ordering is now identical to all three; what's missing is feature depth, not architecture.

**Landed (the chain matches industry canon):**
- Phase rotator early; AGC before EQ; multiband with per-band limiters; encoder lowpass before stereo encoding; composite clipper before BS.412; pilot/RDS injection post-clipper at constant amplitude (the professional invariant)
- Pre-emphasis L/R immediately upstream of pre-encode limiter (canonical Optimod / Stereotool placement)
- PrimeBass post-multiband (canonical MaxxBass / Aural Exciter / Big Bottom placement)
- Stereo widener post-multiband (canonical Optimod placement)
- Differential-topology composite clipper with delta-based per-band substitution (Orban US 6,337,999 + US 4,460,871 lineage, expired)
- Linear-phase FIR multiband splitters (sum-to-flat at -155 dB)
- BS.412 dual-integrator power controller (US 6,618,486 functional equivalent)
- PrimeBass full bass-enhancement patent backlog (MaxxBass + Aphex + Werrbach transient gain + Big Bottom)
- vDSP / vForce SIMD on hot loops (vvtanhf-batched soft-clip, vDSP_dotpr FIR — competitive with what enterprise DSP looks like under the hood)

**Open, ranked impact-per-effort:**

| Priority | Item | Where | Effort | Impact |
|---|---|---|---|---|
| **1** | Look-ahead composite peak control | "Next up" #1; `CompositeClipper` | 1–2 weeks | **Highest** — mathematically bounded overshoot vs time-symmetric soft-clip; measurable loudness lift |
| **2** | Multiband Phase 2: transient-aware attack + RMS/peak hybrid envelope | "Multiband DSP modernisation Phase 2" below | ~1 week | High — eliminates multiband over-squashing on kicks / snares; "Smart Attack" character |
| **3** | Multiband composite clipping | "Composite clipper improvements" #2 | 2–4 weeks | High — per-band thresholds avoid tonal shift; ~1.5 dB more loudness on dense program |
| **4** | Inter-band gain coupling ("loud bass softens highs") | "Multiband DSP modernisation Phase 4" | ~1 week | Medium — subtle Optimod-style polish |
| 5 | Stereo-linked `PreEncodeAudioLimiter` (closes `hard_panned_hf` asymmetry) | new helper next to `PreEncodeAudioLimiter` | ~1 day | Polish; only matters if operator complaint surfaces |

**Honest rating, today, structurally:**
- vs. **Optimod 8500/8600**: ~60–70% of audible chain quality. Missing pieces are #1 (look-ahead composite) and #3 (multiband composite clipping); both are real loudness-level gaps.
- vs. **Omnia.9/.11**: ~60–70%. Omnia "Undo" declipper and the depth of their multiband are out of scope.
- vs. **Stereotool free build**: substantially ahead on structural completeness. Stereotool full license is comparable to Optimod 8x00 — same gap as above.
- vs. **mpxgen / PiFmRds**: different category. MPX Prime is the only open-source FM processor with a real processing chain at this point.

The amateur-grade goal is now structurally complete. Remaining work is specific feature additions (look-ahead, multiband clipping, transient attack), not architectural rewiring.

*Linux port — deferred. See the "Cross-platform" section below for scoping; revisit once the macOS preset / smoke-test / README work has landed.*

## Open gaps

1. **Calibration workflow** — monitoring card shows deviation/pilot/RDS/margin, but exciter-facing guidance and operational long-run use need more hardening.
2. **AGC validation** — wideband AGC defaults and range need broader validation against the current final stage on real program. Pending: listening evaluation on real program to tune the density scaling and decide whether a lookahead path is worth the audio-path latency cost.
3. **Stereo image validation** — mono bass, widener, PrimeBass, and multiband interactions need preset-level validation on difficult real program. Width behavior still needs broader validation now that the composite clipper preserves subcarrier sidebands properly.
4. **Live-apply smoke testing** — DSP and RDS live-apply paths both work; the RDS path was substantially expanded post-0.11 (every operationally-toggled setting now applies live). Still want a focused smoke-test pass on real material to verify no transient artifacts on toggle changes, particularly for TA-edge auto-injection and AF Method B switching. The bit-stream tests cover correctness; the smoke test covers operator perception.

## Phase 7 — remaining items

### 7.6. Dynamic pre-emphasis
See "Next up" #4. Pre-emphasis itself is now in L/R upstream of the pre-encode limiter (post-0.24 chain-order modernization, see "Broadcast-tier follow-ups → Chain-order audit"). A dynamic / lookahead-driven HF envelope follower that relaxes the pre-emphasis curve during transients is still future work. If implemented, it can either modulate `preL`/`preR` in place, or — for a sidechain-only HF-boost feed — be built as a dedicated detector path that doesn't disturb the audio-domain `preL`/`preR` filters. The previous `DSPThroughputTests.preEmphasisDoesNotExplodeFullChainCost` constraint (which guarded the b806053 M/S→L/R relocation against budget overrun) is now historical — the current chain has ~70% real-time headroom and the relocation it guarded against is now what ships.

### 7.7. Pilot-synchronized clipper control
Defer indefinitely. If the composite clipper's gain-reduction envelope modulates near 19 kHz, it can induce sidebands around the pilot. The 8x oversampling + 12th-order Butterworth decimation already keeps clipper-band IM out of 17–21 kHz, but a control-envelope coupling could in principle reintroduce it. Measure first, then phase-lock the clipper's release to a pilot subharmonic if needed. Likely below the audibility threshold for amateur use; revisit only if a real operator complaint surfaces.

### 7.9. Input-side restoration
Defer. Declipper / dehumfilter / delossifier are genuinely complex algorithms (Omnia.9 "Undo"-class). Out of scope for amateur-grade — most amateur operators have control over their source material and don't need source restoration. Revisit only if MPX Prime starts being used for degraded streaming sources at scale.

## Tactical backlog

### Release-blocking
1. Smoke-test pass for live-apply vs restart-required settings.
2. Tune composite clipper defaults so a fresh install audibly outperforms `mpxgen` / PiFmRds with no operator tweaking.

### Sprint
1. Validate PrimeBass, mono bass, widener, and multiband interaction on difficult real material.
2. Refine calibration workflow only where real operator friction exists.
3. Build a small set of named presets (`clean`, `loud`, `community-radio`, `lpfm-conservative`) — INI fragments shipped alongside the binary.

### Medium-term
1. Reduce duplicated filter configuration logic in biquad/crossover helpers.
2. Replace undocumented DSP magic numbers with named constants.
3. Simplify and test RDS group scheduler modes more deterministically.
4. Add AGC / filter-primitive unit tests. (`AppConfig` round-trip + invalid-input coverage shipped — see `AppConfigInvalidInputTests`.)
5. Split the monolithic SwiftUI view model into smaller focused view models.
6. Loosen tight coupling between engine and generator; add DI seams for system-facing services.
7. Harden config file watching/reload behavior against race conditions.
8. Move RDS byte-string preparation off the audio render path.

## Code-quality priorities

### P0 — Confidence and safety
1. Add deterministic unit tests for AGC envelope behavior, filter primitives (PreemphasisFilter, DeemphasisFilter, Biquad, BiquadCascade6), stereo coding M/S round-trip sanity, and bypass-path null-signal tests.
2. Fix the verifier bandwidth metric so RDS does not produce misleading occupied-width failures (`bright_dense` occ999 warning disappears when `en_rds = False`).

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

**Currently shipping:** L/R domain, immediately upstream of the pre-encode limiter (canonical Optimod / Stereotool placement). Implemented as `preL` / `preR` in `processSampleDetailed`.

This was *not* always the case. Commit `b806053` on the path from 0.9 → 0.10 originally attempted the same relocation but caused real-time budget overrun: combined per-sample cost on the audio thread exceeded budget, the input ring filled from empty to capacity (~1.35 s) within 3–5 s of every engine start. 0.10 reverted to M/S inside `makeCompositeComponents` and added `DSPThroughputTests.preEmphasisDoesNotExplodeFullChainCost` as a regression canary.

**The b806053 cost regression is no longer reproducible** on the post-0.24 chain. Optimizations between 0.10 and 0.24 (vvtanhf-batched soft-clip, vDSP_dotpr FIR, linear-phase FIR multiband, composite clipper differential topology) cut absolute chain cost from ~95% to ~28% of real-time, comfortably absorbing the ~7% relative cost increase from pre-emphasis upstream of the limiter. Phase 1 chain-order audit (post-0.24, see `macOS/.audit-out/chain_order/REPORT.md`) confirmed C1 PASS at 1.07× ratio + C2 PASS over 30 s sustained load. The relocation now ships as the production placement.

**If dynamic pre-emphasis (7.6) ever wants further refinement:** build a dedicated sidechain detector that doesn't disturb the audio-domain `preL` / `preR` filters; or modulate the existing filters' tau in real time. Either path is now compatible with the production chain.

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
