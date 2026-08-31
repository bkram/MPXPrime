# MPX Prime Roadmap

Active work list + anti-rework guardrails. **Not** a readme: positioning, architecture, and build live in `README.md` / `docs/ARCHITECTURE.md` / `docs/BUILDING.md`; shipped-feature history lives in `CHANGELOG.md`. Don't re-plan shipped work as pending — cross-check CHANGELOG before acting.

## Status

Released through **0.44** (2026-08-03). **Active branch: `develop/v.045`**; 0.45 is the Unreleased target (see `CHANGELOG.md` for its accumulated content). Shipped-feature history lives in CHANGELOG — this file tracks only pending work; cross-check CHANGELOG before planning anything here as pending.

Major work landed since the roadmap was last pruned: MPX Prime Meter (0.37, receive/analyze companion + measurement-grade metering); the **Linux CLI port** of the encoder (headless + ALSA, SIMD acceleration shim, Debian/Ubuntu packages); and the **REST API + embedded web dashboard** (remote control, both platforms). All three were previously listed here as future work and have been removed from the sections below.

---

# Open work

## Next up (0): hi-hats / cymbals distort too much (field finding 2026-08-29)

Symptom: hi-hats and cymbals come through audibly distorted on air. Plan is
measurement-first (find the stage, then fix the stage), with the prior-art
table below backing each fix idea so nothing is re-invented or infringes.

### Why HF transients are the chain's weak spot (code facts, not guesses)

- 50 us pre-emphasis boosts 5-15 kHz by up to ~+10 dB (stage 17), so after it
  hats/cymbals ARE the peaks. Every nonlinearity downstream of stage 17 acts on
  them first: the HF clipper (18), the pre-encode limiter's tanh ceiling (19),
  the composite clipper (21) and the always-on `softClipSafety` pair on the
  audio composite (`processFinalComposite`).
- **The field INI runs no peak controller at all.** The operator's live config
  (last written 2026-08-03 20:44, i.e. BEFORE the 0.45 profile rework in
  71cdf78) still carries the deleted profile id `chr_top40`, with
  `pre_encode_limiter_enabled = False`, `mpx_clipper_enabled = False`,
  `hf_clipper_enabled = False`, `bass_clipper_enabled = False` and
  `final_drive_db = 8.0`. On that chain the ONLY peak control is
  `softClipSafety`: a tanh knee whose headroom above threshold is clamped to
  0.4-3% (`margin = clamp(0.08*(1-thr), 0.004, 0.03)`), i.e. effectively a
  hard clipper, at 1x rate, on the full composite INCLUDING the 38 kHz L-R
  subcarrier, with no guard-band cancellation. Pre-emphasised hats at +8 dB
  drive hit it on every strike. `PresetCatalog.formatProfile(forID:)` returns
  nil for legacy ids and nothing migrates them, so a running station keeps the
  broken gain structure after upgrading; there is also no telemetry that says
  "the safety clip is doing the work" (grep: no soft-clip engagement counter).
- **`mpx_clipper_cancel_audio = True` (set in the field INI) defeats audio
  peak control.** The audio-band delta substitution restores 0-15 kHz to the
  CLEAN input, so the composite clipper cannot reduce any audio-band peak; the
  peaks fall through to `softClipSafety` (hard, unguarded). Turning the
  clipper on therefore does not help that config -- it moves the clipping to a
  worse clipper. Orban's own distortion-cancel (US 5,168,526, expired, already
  in `DistortionCancelledClipper`) cancels only BELOW ~2 kHz for exactly this
  reason; the composite clipper's audio cancel is full-band.
- **`music_loud` enables the HF *clipper*, and it is a waveshaper on cymbals
  by construction.** `HFClipper` tanh-clips the >5 kHz pre-emphasised band at
  -3 dB / drive 1.2 (4x OS). Cymbals live in that band, so it distorts them by
  design; broadcast "HF limiters" (Optimod 8100/8200) are gain riders, not
  clippers. Worse, its products are NOT band-limited afterwards: the encoder
  program LP (stage 15) and the 19 kHz `pilotNotchL/R` (stage ~14) are
  upstream of it, and with the default dual-rate audio domain (48 kHz) its
  decimation LP sits at 0.45 x 48k = 21.6 kHz and the boundary interpolator
  cutoff at 0.9 x 24k = 21.6 kHz -- so 15-21.6 kHz clipping products go
  straight into the composite (the 17-21 kHz pilot guard and the foot of the
  lower L-R sideband), and 24-27 kHz products alias down to 21-24 kHz. The
  composite clipper's pilot-guard cancellation removes only ITS OWN residual,
  not this. (The pre-encode limiter is the exception: its decimation LP is
  `min(0.30*fs, ...)` = 14.4 kHz at 48 kHz audio rate, so its ceiling-clip
  harmonics are filtered -- at the cost of -3 dB at 14.4 kHz, pinned by
  `DualRateHFResponseTests`.)
- **Pre-encode limiter attack = 0.25 ms exponential, hold 4 ms, release
  50 ms, ONE gain for the whole band.** With hats as the peaks, every strike
  yanks the full mix down in 0.25 ms (gain-modulation IM, "spitting") and the
  1 ms HF-only look-ahead only pre-arms it. The peaks that outrun it hit the
  ceiling knee (`ceiling - threshold = max(0.012, 0.65*(1-thr))`, ~0.1 at
  0.85), a narrow tanh. This is the classic "broadband limiter fighting
  pre-emphasis" artifact the HF limiter exists to prevent.
- **Advanced Dynamics (ON in the field INI, `high_offset_db = -9`).** Band 5
  (>6.2 kHz) has a 5 ms envelope attack, a near-instant gain smoother on
  transients (`attackFast` = 30 us; hats have the highest peak-to-RMS so
  `heldDrive` ~ 1) and a 0.3-1.2 s release. Each hat strike is ducked inside
  its own 5 ms attack and the band stays 6-12 dB down until release -- heard
  as crushed / spitty hats and HF pumping rather than harmonic distortion,
  but "distorted cymbals" is how an operator describes it. `hf_transients`
  in `--verify-advanced-dynamics` exercises this but only reports deltas.
- Multiband high band (5_chr: 8 ms attack, 1.6:1) is mild; not a suspect.

### Step 1 -- measure before touching DSP (metric-first, per AGENTS.md)

1. **New deterministic scenarios** in `VerificationHarness.swift`:
   `cymbal_hats` (band-limited 6-14 kHz noise bursts, 2-3 ms attack, 60-300 ms
   decays, 8th-note pattern, plus a sustained ride/crash wash, over a dense
   bed; render at the -12 dBFS nominal AND at 0 dBFS hot input) and
   `hat_multitone` (3 fixed partials, e.g. 8.9 / 11.3 / 13.1 kHz, gated with
   the same envelope) so IM products land in exactly-known bins.
2. **New receiver-side HF distortion metric.** Decode with `MPXDecoder`
   (de-emphasised L/R), then report per scenario: (a) HF SINAD -- energy in
   bins that were empty at the input vs the wanted partials (multitone);
   (b) HF envelope fidelity -- correlation of the decoded 6-15 kHz envelope
   with the input envelope, plus attack-window energy ratio (spit detector)
   and gain-modulation depth; (c) composite 15-23 kHz spill from L/R-domain
   nonlinearities (pilot region 17-21 kHz separately) -- the HF clipper
   finding above predicts this is non-zero today.
3. **Per-stage isolation sweep** (pattern: the `--verify-receiver` per-stage
   separation sweep, `VerificationHarness.swift` ~1301): toggle each
   nonlinearity one at a time (safety soft-clips via limiter/clipper state,
   HF clipper, pre-encode ceiling vs gain-ride only, composite clipper with
   and without `cancel_audio`, Advanced Dynamics, multiband) and print the
   metric. Run it on (i) the field INI as-is, (ii) each of the four 0.45
   profiles, (iii) the field INI with `music_loud` applied. This names the
   culprit(s) with numbers before any fix is written.
4. Ship all of it as `--verify-hf-transients [--seconds N]` (A/B-gate style
   like `--verify-ssb-stereo`), exit codes 0/1/2, baseline-capable, plus
   unit tests on the new primitives. Only then listen.

### Step 2 -- fixes, ordered by expected payoff (each verifier-gated)

1. **Gain-structure hygiene (cheap, likely the field fix).** (a) Migrate
   legacy `format_profile_id`s on load (`chr_top40`/hot ids -> `music_loud`,
   talk ids -> `speech`, classical -> `classical_wide`, rest ->
   `music_clean`) so an upgraded station gets the 0.45 structure; log it.
   (b) Runtime version of the `profilesOwnTheFullGainStructure` contract: if a
   loaded INI leaves `softClipSafety` as the de-facto peak controller, warn
   in Studio status + dashboard + CLI. (c) Telemetry: soft-clip engagement
   (% of samples / dB over) on the status bar, meters and `/api/telemetry`,
   so "the safety clip is doing the work" is visible. (d) Change
   `mpx_clipper_cancel_audio` to cancel only the LOW audio band (Orban
   US 5,168,526 principle, corner ~2-5 kHz, verifier-pinned: peak reduction
   must survive with cancel on) -- or at minimum warn in both UIs.
2. **Pre-emphasis-aware HF LIMITER (the canonical fix).** A gain-riding
   (not waveshaping) stage on the pre-emphasised >~5 kHz band, between
   pre-emphasis and the broadband limiter: stereo-linked, 0.5-1 ms look-ahead
   reusing the limiter's delay pattern, half-cosine attack tied to the
   look-ahead window (US 6,434,241, expired 2014), hold, program-dependent
   release, 0..-12 dB range. Seed: `processEncoderHFGuard` already IS a mini
   HF limiter (LR4 split @ 6.2 kHz, 4 ms attack, capped at 2 dB, fixed 0.11
   threshold) but sits pre-emphasis at stage 14 -- move the concept post
   pre-emphasis with real range and a de-emphasis-aware detector. Concrete
   recipe (all expired, see the prior-art table): Orban US 4,103,243
   actuator (`y = x + g(t) * BP(x)`, the pre-emphasis boost itself is
   program-controlled, ~3 ms / ~10 ms), Orban US 5,574,791 HF-to-total
   log-ratio detector (engage on HF dominance, not overall loudness), Dolby
   US 4,490,691 spectral skewing on the detector. Sliding-band variant
   (Dolby US 3,631,365 / 3,846,719: the compressed band's corner slides UP
   with HF level so only the offending top octave is reduced, action
   substitution US 4,736,433 to fill gaps) as phase 2 if the fixed-band
   version still dulls presence. Orban's paper says HF limiters sound best
   un-linked per channel -- A/B linked vs un-linked with the separation and
   image metrics before deciding. Keep the HF *clipper* as an optional
   last-resort stage AFTER the HF limiter, band-limited (see 3). Ships
   default-off; `music_loud` switches from HF clipper to HF limiter once the
   gate is green.
3. **Band-limit the HF clipper** (and any post-pre-emphasis waveshaper): set
   its decimation LP to <=15 kHz or add a linear-phase LP so no product
   reaches the pilot guard / L-R sideband; retune defaults (higher threshold,
   drive 1.0). Gate: the new 15-23 kHz spill metric AND `--verify-receiver`
   pilot lock unchanged.
4. **Pre-encode limiter attack shaping.** Replace the 0.25 ms exponential
   attack with a half-cosine ramp spanning the look-ahead window, and make the
   HF-only detector also drive an HF-only gain path when item 2 is off
   (completes US 5,579,404 / Dolby split-band limiting -- detector is done,
   gain path is not). Bit-identical when look-ahead = 0 (existing regression
   guard).
5. **Advanced Dynamics HF band.** Cap band-5 transient acceleration (floor
   the attack at ~2-3 ms on the top band, or make `heldDrive` weight
   band-dependent) and re-check `high_offset_db = -9` semantics in the manual;
   `hf_transients` gets the new envelope-fidelity metric as a hard gate.
6. **Dynamic pre-emphasis ("Smart HF")** -- the unwired `DynamicPreemphasis`
   sidechain core and its tests were DELETED in 0.45 (dead code, "less is
   more"); re-derive from the prior-art table if this is ever pursued.
   Lowest priority: it trades a bounded HF dip at the receiver for headroom
   (spec-visible), so only after 1-5 if the metric still says HF is the
   limiter's whole problem. Needs schema + both UIs if wired.

### Prior art / expired patents backing the fixes

See the table in "Anti-rework guardrails -> HF transient / pre-emphasis
limiting prior art" below (survey 2026-08-29).

### Status 2026-08-29 (implemented on develop/v.045, see CHANGELOG)

DONE: Step 1 (`--verify-hf-transients`, 3 scenarios, 18 chain variants,
gated on shipped profiles); Step 2 #1a legacy profile-id migration, #1b
startup warning (CLI + GUI status), #2 HF limiter (Orban 4,103,243
topology, on in Music - Loud, HF clipper off in every profile). The
measurement changed the diagnosis: the DOMINANT cause in every shipped
profile was not on this list -- the final-stage ORDER. The 1x shaper ran
before the composite clipper at a lower threshold (budget < clipper
threshold read against full scale), so the shaper did all the clipping and
the clipper + final limiter never engaged. Fixed (clipper -> FIR -> BS.412
-> look-ahead limiter -> shaper, both peak stages normalised onto the
budget); all four baselines recaptured. Measured: hat SINAD +13..14 dB in
every profile, ride SINAD +11..30 dB, deviation unchanged.

REMAINING from this list: #1c DONE (Safety Clip telemetry in both UIs +
`/api/telemetry.safetyClipDB`); #1d `cancel_audio` low-band-only (measured: no effect once the
HF clipper is out of the path, so lower priority); #3 band-limit the HF
clipper (opt-in only now); #4 pre-encode limiter half-cosine attack + HF-
only gain path; #5 Advanced Dynamics HF cost (-3 dB hat SINAD, -1 dB wash crest vs the
profile without it) -- a 2.5 ms top-band attack floor was TRIED 2026-08-29
and changed nothing (reverted); next suspect is the -9 dB top-band target
offset lifting sparse HF, measure that before touching the smoother; #6 dynamic pre-
emphasis. NEW from the industry-order research (2026-08-29, Orban 8100A /
8500 manuals + white paper, Omnia.11, Inovonics 719N, Thimeo docs + forum):
(a) every vendor places the stereo widener AND the bass enhancer BEFORE
the multiband so it controls the L-R / bass energy they add -- ours sit
after it (mitigated by the bass clipper + stereo-image protection that
follow); (b) `processEncoderHFGuard` MEASURED 2026-08-29 and KEPT: removing it cost
20-40 dB of receiver-side HF separation on the tone test (composite-clipper
audio-band IM) and the default-on HF limiter did not engage at those levels;
the 19 kHz audio-path notch and the experimental multiband composite clipper
were removed instead (notch identical to 0.01 dB; MB clipper A/B TIGHT); (c) the pre-encode limiter's tanh ceiling is the LAST L/R
nonlinearity and sits after the 15 kHz FIR with nothing band-limiting its
residual (Orban band-limits the "clippings" of the last L/R stage, US
6,337,999) -- gate: L/R 15-19 kHz energy at the encoder input on dense
program; fix, if it shows, is a differential/band-limited residual, NOT a
post-limiter LPF; (d) Orban prefers UN-linked fast HF/peak limiters --
offer `hf_limiter_stereo_link` and A/B with the image metrics; (e) the
guard-band restoration overshoot that the final limiter now rides
(~1.5 dB on bright_dense) could be reduced at the source with 2-4 POCS
iterations (`mpx_clipper_iterations`, see Experimental candidates #2).
Hans van Zutphen's stance (forum t=34742): audible cymbal distortion from
the clipper is "not normal"; Stereo Tool has no HF gain rider and
recovers brightness by raising the HF compressor / lowering the HF
limiter -- worth trying on Music - Loud as a preset tweak.

## Chain design review (approved 2026-08-30) -- what we did wrong vs published practice

Three domain reviews (audio dynamics vs Orban WP / Omnia.11 manual / Thimeo docs;
composite stage vs BS.450-3 / 47 CFR 73.322 / EN 50067 / Orban patents / Thimeo;
measurement coverage) plus a code inventory. Findings marked FACT were verified
in code. Work is sequenced as one measured commit per step; every step ends with
the full gate run and a baseline recapture where the composite moves.

- **Step 0 -- measurement first**: end-to-end latency (`totalChainDelaySamples`,
  impulse test, `--verify` + `/api/status`); decoded frequency-response sweep
  20 Hz-15 kHz (+/-0.5 dB to 14 kHz, will FAIL today -- see step 2); protection in
  dB re subcarrier (pilot / RDS / 38 kHz / SCA); RDS BLER under load; THD / SMPTE /
  CCIF of decoded audio; BS.1770 + BS.412 on the verifier output; verifier <->
  Meter cross-check; stale tests moved to the 48 kHz audio rate
  (`MultibandFIRSplitterTests`, `EncoderBandwidthTests`, `DualRateHFResponseTests`
  tolerances hide the 14.4 kHz roll-off). Polarity instruments DONE 2026-08-30
  (independent textbook decoder in `StereoPolarityTests`, driven-channel scoring
  in `--verify-receiver`).
- **Step 1 -- stereo polarity** DONE 2026-08-30: encoder sent `(R-L)/2` since the
  first commit, `MPXDecoder` negated it back (0.27), real receivers swapped L/R.
  Fixed both sides, baselines recaptured, manual tells operators to re-check
  channel assignment with the left-routed test tone. Hardware confirmation on a
  car radio pending (operator).
- **Step 2 -- receiver-side HF response** DONE 2026-08-30 (FACT): the pre-encode
  limiter's 4x decimator was a 6th-order Butterworth at 0.30 fs = 14.4 kHz
  (comments said 12th-order), -2.3 dB @14 kHz / -4 dB @14.9 kHz with only
  -27..-43 dB alias rejection -- a regression of the 48 kHz audio-domain move;
  the matched-z pre-emphasis under-boosted another -0.6 dB @10 kHz / -1.4 dB
  @15 kHz. Now: `LinearPhaseFIRDecimator` flat to 15 kHz / 80 dB by 16.5 kHz
  (measured: a 15.5/22 kHz or 15.5/17.5 kHz design left the gap spill at
  -31 dB -- the spill was the encoder FIR's pre-emphasised transition tail,
  which the old Butterworth had been re-attenuating by accident, so the
  decimator now defines the 15 kHz band edge in the emphasised domain);
  `PreemphasisDesign` biquad fit (<0.05 dB) shared by encoder and decoder
  (de-emphasis = exact inverse). Response sweep +/-0.5 dB to 14 kHz pinned.
  Ride SINAD 42.6 -> 46.8 dB, hats unchanged, gap spill floor -39 -> -36
  (gate -34). Side effect worth knowing: the receiver gate's 14 kHz tone now
  reaches the composite clipper at full level and shows the stereo-guard M/S
  imbalance (95 -> 31 dB) -- that is Step 4's B1, not an encoder loss. Also
  fixed a live-apply bug (limiter reconfigured at the MPX rate).
- **Step 3 -- multiband splitter** DONE 2026-08-30 (FACT): the splitters
  discarded `transitionHz`, hit the 2049-tap clamp -> 21.3 ms latency (docs said
  5.3 ms) and gave every crossover an ~85 Hz brick wall (12 ms pre-ringing at
  1.8 / 6.8 kHz). Now per-crossover transition = fc (floor 120 Hz), -6 dB AT the
  crossover, 40 dB stopband, kernels padded to a shared length: 446 samples =
  9.29 ms, -6 dB within 0.4 dB at all four crossovers, pre-ringing -28.8 dB /
  0.56 ms, FIR multiband cheaper than IIR (0.91x). Exposed a multiband-leveler
  property in Advanced Dynamics: a tone on a crossover skirt is lifted by the
  neighbouring band's full range (band coupling / sync, Step 7, is the cure);
  the unit test now uses one tone per band.
- **Step 4a -- stereo guard share** DONE 2026-08-30: `mpx_clipper_stereo_guard`
  (0 = industry full-composite clipping, 1 = former toggle on; old key migrates),
  GUI + web slider, `--verify-stereo-guard` sweep. RESULT REFUTES B1 as the ride's
  cause: Music - Loud shows no dependence at all (clipper GR 1.9 dB, final limiter
  idle 0.02 dB, sep 35 dB, HF SINAD equal); a hot config (multiband off, 5 dB
  clipper GR) rides 1.19 dB at guard 0 vs 1.33 at 1, guard 1 costs 5 dB of
  14 kHz tone separation and buys +3 dB decoded hat / ride SINAD. Default kept
  at 1.0 (measured). The final-limiter ride therefore comes from elsewhere
  (pilot / RDS guard restoration, knee, decimator) -- Step 4b below is where to
  look. Broken in the sweep and removed: a decoded hard-panned program side/mid
  column read -114 dB (decode returned mono) -- the P10 program-separation
  metric still needs a working implementation.
- **Step 4b -- remaining clipper items**: 1-2 POCS re-projection passes (measure
  the bound probe and the hot-config ride with them); final limiter threshold
  back to budget + 150-200 ms release + GR > 0.5 dB telemetry warning once the
  ride is understood; knee default -0.5 / -0.3 dB after an HF-SINAD A/B;
  bandwidth FIR 53 kHz / 2 kHz transition.
- **Step 5 -- dynamics practice gaps**: AGC default attack 6 ms is limiter-fast
  (Omnia: control peaks in the limiter, not the AGC) -> >= 150 ms with a burst
  test; multiband "program-dependent release" is a constant x1.1 -> real
  multi-slope release in `MonoCompressor`; pre-encode limiter full-band look-ahead
  with attack ~ look-ahead, partial-link experiment vs the hard-panned case.
- **Step 6 -- budget hygiene + defaults**: margin 0.02 -> 0.005, `limitThreshold`
  0.99, reservation from the delayed subcarriers, pilot default 9 % (new installs),
  document 3 kHz RDS as the field choice. The Thimeo-style post-injection
  pilot-aware clipper (~0.5-1 dB realised) waits until steps 4-5 are measured.
- **Step 7 -- optional structure**: Omnia-style band sync (clamp gain disparity to a
  master band), switchable widener / PrimeBass placement (Omnia puts enhancers
  BEFORE the multiband), speech detector easing clipper drive, per-band
  `BandLimiter` on `music_loud` as the density path before more clipping.

Also found and FIXED 2026-08-30: processed-audio output mode switched the
dual-rate boundary off after construction without re-deriving any audio-domain
stage (pre-emphasis 50 us ran as ~12.5 us at 192 kHz, limiter time constants 4x
off); `setAudioOutputOnly` now reuses the sample-rate-change reconfiguration and
`processedAudioKeepsThePreemphasisCurve` pins it.

Found 2026-08-30 while measuring Step 3 and FIXED: `useEncoderFIR` /
`useMultibandFIR` defaulted to false in `MPXGenerator` and only the macOS
`AudioOutputEngine` turned them on, so every offline gate and baseline -- and
the Linux ALSA engine on air -- ran the IIR monitor filters (Butterworth encoder
LP, LR4 crossovers). The generator now seeds both from config; verify sweeps and
baselines cover the TX chain for the first time. The Linux baseline
(`default-linux-x86_64.json`, stale since 0.42) must be recaptured on mpxbox.

### Enterprise-parity roadmap (approved 2026-08-30, after Steps 1-4a)

Rating vs Orban 8600 / Omnia.11 / Stereo Tool: encoder side professional-grade
(polarity, pre-emphasis 0.05 dB, response +/-0.5 dB to 14 kHz, RDS phase-locked,
budget-referenced peak stages); processor side mid-tier with untuned dynamics
(Music - Loud: 17.8 dB hat SINAD, 35 dB HF separation with the clipper working).
Order of work (payoff per effort; each item measured before it is heard):

- **A1** DONE 2026-08-30 (`--verify-final-ride`, parameterised bound probe). Result:
  pure band-limiting overshoot +0.55 dB, guards together +1.74 dB (not additive:
  stereo guard 0 alone reads +2.21), OS factor / knee irrelevant; the clipper's 2 ms
  look-ahead is the big lever (kernel GR 13.7 -> 3.1 dB, final ride 5.8 -> 0.08 dB
  on the hot chain). NEW DEFECT: `LookaheadLimiter` leaks -- Music - Loud reports
  0.02 dB limiter GR while 0.87 dB of dense program reaches the safety shaper
  (hot chain: 5.8 dB ride, 2.7 dB still leaking). **A1b DONE 2026-08-30:** the
  detector was instantaneous |x| into a 0.35 ms one-pole; now a `SlidingWindowMax`
  over the delay line + attack = window/4 + gain floor. Safety-clip column 0.00
  everywhere, honest GR (Music - Loud ~1.0 dB on bright_dense), threshold back on
  the budget, verifier bounds 3/4 dB, `LookaheadLimiterTests`. Open follow-up for
  A2/A3: the clipper's own 2 ms look-ahead cuts the ride to 0.08 dB on the hot
  chain -- evaluate enabling it in Music - Loud with the HF gate (it trades clipper
  density for a gain ride), and apply the same windowed detector to the
  pre-encode limiter (B5).
- **B1** DONE 2026-08-30: AGC attack default 6 -> 150 ms, presets 100-200 ms,
  burst test (30 ms +10 dB hit: 3.35 dB duck at 6 ms, 0.02 dB at 150 ms), step
  test, preset lint, `--verify` TIGHT below 50 ms, slider to 500 ms. Skipped: the
  `agcGainSwingDBPer100ms` verifier metric (optional; add if a later change needs it).
- **B2** DONE 2026-08-30: dual-slope release in `MonoCompressor` (platform = 1.5 s
  average of DEMANDED GR; fast below it, 3x slower above; detector release <= 30 ms
  so it is one pole). Kicks recover within 1 dB of single slope, level drops hold
  3 dB at 0.5 s vs 0. Lesson: averaging the applied GR froze the band at kick depth.
- **A2** POCS re-projection passes (`mpx_clipper_iterations` 1-3, cascade of
  `CompositeClipperPass`, delay summed into `recomputeSubcarrierDelay`); default 1,
  Music - Loud -> 2 after the table.
- **B4** per-band `BandLimiter` as the density path on Music - Loud (5 ms hold, HF
  tilt, profile fields).
- **B3** Omnia-style band sync (`multiband_sync_db`, clamp target GR to master +/- D).
- **B5** pre-encode limiter attack = look-ahead / 4, sliding-window-max detector,
  look-ahead 2-3 ms.
- **A3** clipper knee -0.5 / -0.3, bandwidth FIR 53 / 2 kHz, margin 0.005 +
  `limitThreshold` 0.99, pilot 9 % for new installs.
- **B6** speech / music detector easing clipper drive (`mpx_speech_drive_ease_db`).
- **C** measurement the vendors publish: end-to-end latency in `--verify` and
  `/api/status`, protection re subcarrier, RDS BLER, THD / SMPTE / CCIF, a WORKING
  program-separation metric, BS.1770 + BS.412 on the verifier, Meter cross-check,
  Linux baseline recapture.
- **B7** clip-detection metric only (no declipper this cycle); **D** optional structure
  (enhancer placement, AGC window, density macro, x1 120 Hz).

Also noted: the receiver report's "Pilot ... Phase 45.4 deg" is the pilot's
absolute phase at the analysis window, not pilot-to-RDS (both read ~45 deg, i.e.
in phase) -- relabel it. The 10 kHz PLL-path separation (~51-54 dB) vs 95 dB at
1 / 14 kHz is a decoder-PLL artefact still to be explained. FINE / no action:
AGC topology, multiband bands / ratios, dual-rate boundary, post-clipper
injection, encoder HF guard (give it named constants + a test).

## Meter audit (2026-08-31, 57 findings; full detail in the session plan file)

Three audits (measurement engine / input+SDR+recording / GUI). SHIPPED: P0
recording robustness (4 GiB trap, NaN trap, crash-safe header, failure
surfacing, off-thread finalize); P1.1 rates (analyzer rebuilt at the ACTUAL
opened rate, refuse < 128 kHz, range-reported device rates expanded, slice
constants tied); P1.2 Swift side (SAMPLES DROPPED + NO INPUT badges off the
ring transport counters and a last-delivery watchdog, dashboard blanks on
stop/device loss); P1.3 decode integrity (second-order ~2 Hz PLL closes the
38 kHz recovery -- measured A/B 24.8 dB separation at 100 ppm and 47.7 dB at
25 ppm before vs 64.4 dB at every offset after, on-frequency unchanged so
`receiver.json` did not move; the pilot-lock gate is now level-relative
(~2.5% of composite mean square) instead of an absolute magnitude that
silently decoded mono over a 20 dB window; `stereoDecodeActive` -> amber
"MONO DECODE" badge blanking separation / balance / correlation; sub-Nyquist
rate decodes exact mono; dead biquads out of the inlinable path;
`MeterDecodeIntegrityTests`). REMAINING, in order: P1.2b tuner drop counters
(`mpxtuner_iq_drops` C ABI; SDRplay ring has none, RTL's is a function-local
static); P1.4 validity flags (peaks freeze at the last station; scale accepted
from pilotAmp 1e-5; phase-meter coherence primes at 1.0 (the 45.4 deg
mystery) and 0.3 admits a drifting angle; exceedance "valid" after 1 s at
520x too-coarse resolution; calibration changes don't reset accumulators;
quality/-corr/balance gates); P2 conventions (de-emphasis hard-wired 50 us --
75 us markets decode +3.4 dB bright at 15 kHz; RDS-level 1.320 peak factor
documented wrongly in the primitive; --full-scale-khz ignored on the audio
CLI path; SDR default IQ rate bypasses the byte-validated packed path; the
wide-capture decimator is the dominant channel filter at factor 4 -- bench
A/B needed); P3 GUI (RF-span chip re-triggers the 0.34 toolbar leak at 20 Hz
in RF mode; statusText @Published; occlusion gate tests an arbitrary window;
window squeezable 240 pt below content minimum; error alerts; accessibility
pass -- readouts aren't elements, over-limit is colour-only, 9 unlabelled
AppKit fields; monitor uses read() not readAdaptive -> clock-drift clicks
into an exciter). Hardware for the maintainer: RTL ppm before/after the PLL
fix, factor 1 vs 4 IQ A/B, SFP-X re-check after P1, 75 us station after P2.

## Next up

0. **Rework the shipped Format Profiles + PrimeBass presets. DONE (71cdf78, 2026-08-04).** Four complete profiles own the gain structure; the PrimeBass preset re-tune at the new gain structure and the input-gain-reference question (nominal -12 dBFS documented in the manual) remain open as listening items.
1. **Anti-aliased clipping kernel (US 6,937,912).** Phase A/B landed opt-in (`pre_encode_bandlimited_residual_enabled`). Remaining: A/B real program with it on, decide whether any loud preset enables it; optional Phase C applies the primitive to `softClipSafety` in `processFinalComposite` only if B proves benefit (keep pilot/RDS injection post-processing + budget-governor invariant); refresh baselines on real program.
2. **Tune/validate composite clipper look-ahead.** `mpx_clipper_lookahead_ms` shipped; dense real-program A/B at 0.5 / 1 / 2 ms, verify pilot/RDS guard cleanliness, decide loud-preset default. Capture via `MPXPRIME_AUDIT_CAPTURE=1` → `macOS/.audit-out/lookahead/`.
3. **Smoke-test pass.** Live-apply vs restart-required on difficult real material; catch transients/clicks/dropouts on toggle. New RDS live-apply paths (PI/PTY/flags/AF/scheduler) need real-receiver checks beyond the bit-stream tests.
4. **Extend baselines to `--verify-presets` and `--verify-long`. DONE (develop/v.045).** Platform-suffixed `presets.json` / `long.json`, same schema; capture via `--capture-baseline` combined with the mode flag.
5. **Receiver-model verifier hardening. DONE (develop/v.045).** `postInjectionOvershoot > 1e-4` is now a hard failure (exit 3) in the main and preset sweeps, checked before the softer branches that used to mask it; receiver-side baselines (`receiver.json`) already existed since 0.36-0.43.
6. **HF stereo separation — `MPXDecoder` audit. DONE (develop/v.037).** Root cause was the pre-demod pilot/RDS notches clipping the S-channel sidebands; removed them — separation 65/51.6/44.2 → 98.3/86.1/97.2 dB at 1/10/14 kHz, composite untouched. See "Settled findings".

## Opt-in advanced stages — validate + decide default

Highest-leverage audible-gap closer vs the enterprise tier: these stages are implemented and shipped but **default-off and not preset-validated**, so a fresh install runs below the chain's real capability. Each needs a verifier/listening A/B → a per-preset enablement decision. OFF must stay bit-identical (`--verify --baseline-strict` green); ON validated via `--verify-receiver` (separation + pilot/RDS guards unchanged).

1. **Pre-emphasis-aware HF clipper** (`hf_clipper_*`). SUPERSEDED 2026-08-29: the HF limiter is default-on in every profile and the clipper is an opt-in last resort (it measured 17 dB worse hat SINAD). Decide in a later release whether to delete it.
2. **Multiband Phase 2 — transient-aware attack** (`multiband_transient_aware_attack_enabled`). Verifier + dense-percussive listening A/B; preset decision.
3. **Multiband inter-band coupling** (`multiband_inter_band_coupling_enabled`, `--verify-multiband-coupling`). "Loud bass softens highs" — listening A/B; preset decision.
4. **Anti-aliased residual clipping** (`pre_encode_bandlimited_residual_enabled`) — see Next up #1.

## Experimental candidates -- composite-processing ideas (parked 2026-08-01, user decision)

Analysis of a third-party processor's press release (loudness/cleanliness claims) mapped onto our chain; all would ship off-by-default and verifier-gated. We cannot know the vendor's actual method -- these are our own defensible readings backed by the interleaving math.

1. **`pre_encode_stereo_link` blend (small).** The audio composite is bounded by `max(|L|,|R|)` at every instant (convex-combination identity), but `StereoLinkedOversampledPeakLimiter` rides ONE shared gain from `max(|L|,|R|)` -- needlessly attenuating the quiet channel whenever the loud one limits. A link factor 0..1 (1 = current linked behavior) recovers ~2-3 dB integrated loudness on wide program at IDENTICAL composite peak, distortion-free (gain riding, not clipping); cost is momentary image shift toward the limited side. The shared-envelope code already exists; the experiment is the blend + an image-stability verifier scenario.
2. **`mpx_clipper_iterations` (moderate).** POCS-style iterative clip -> re-project (bandlimit + protected bands) composite peak control; our differential clipper + guard-band cancellation is one iteration of exactly this. 2-4 iterations at OS rate, CPU-gated by `DSPThroughputTests`, measured by guard-band depth / >60k leakage / receiver separation.
3. **Studio<->Meter closed-loop RF trim (large).** Their "analyzes RF bandwidth after the exciter" loop; the Meter's RF spectrum (0.43) is the sensor. Auto-trim clipper drive against occupied-bandwidth targets. Needs the control API on the Studio side + a Meter export path first.

## Broadcast-tier follow-ups

- **Multiband Phase 3 — per-band look-ahead.** Reuse `LookaheadLimiter` ring-buffer per band. Largely redundant with Phase 2; skip unless dense percussive listening shows Phase 2 isn't enough. ~3–5 d.
- **Stereo-band cancellation depth via FIR bandpass.** Optional/depth-only. Delta substitution gets ~5–10 dB in the stereo subband (LR4 phase-bounded); linear-phase FIR bandpass would push to 20+ dB. Only if listening (Next-up #1) says residual cross-domain IM is audible at amateur drive.
- **Audio-clipper oversampling bump.** `BassClipper` 4×→16×, `DistortionCancelledClipper` 8×→16–32×, likely swapping `BiquadCascade6` decimation for `LinearPhaseFIRDecimator`. Polish (aliasing already inaudible at amateur drive); ~1–2 d each + baseline refresh. Aliasing gate: `DistortionCancelledClipperTests.aliasingEnergy` (−38 dBFS now; pro chains push past −75).

## Open gaps

1. **Calibration workflow** — exciter-facing guidance + long-run operational hardening.
2. **AGC validation** — density-scaling tuning on real program; decide whether a lookahead path is worth the latency.
3. **Stereo image validation** — mono bass / widener / PrimeBass / multiband interaction on difficult real program.
4. **Live-apply smoke testing** — TA-edge auto-injection and AF Method B switching in particular.

## Verifier coverage follow-ups

1. **Tighten bandwidth baseline tolerance** (±1.0 → ±0.5 dB) with a multi-frame averaged FFT to cut spectral leakage in the `>60k/>67k` ratios.
2. **AppConfig-vs-sample-INI default lint. DONE (develop/v.045).** `SampleINIDefaultDriftTests` with a reviewed whitelist; first run caught the pre-0.37 product name in the sample's RT texts + a stale `fft_window_92khz`.
3. **BS.412 full-chain long-run scenario** — component limiter is unit-tested (`BS412PowerLimiterTests`); a `--verify-long`-style full-chain check over 30+ s is still uncovered (deferred for render cost).

## Tactical backlog

**Release-blocking:** ~~`output_gain_db` above 0 dB~~ DONE 2026-08-29: clamped to <= 0 dB in composite mode (validate + GUI slider), full range kept for the processed-audio output. The budget governor divides the whole composite budget by the output gain, so +2.79 dB on the operator's INI squeezed the audio budget from ~0.85 to ~0.58 (the same Final Drive then clipped ~3 dB deeper: hat SINAD 15.2 vs 18.3 dB, ride 31 vs 38 dB on the same processing) while pilot went on air at ~11% and RDS at ~4.1 kHz instead of 8% / 3.0 kHz. Positive output gain buys no loudness (the governor caps the composite at 0.98). Decide: clamp `output_gain_db` to <= 0 in `validate()` (with a migration note), or keep negative-only semantics and surface a status warning + a manual note that exciter drive belongs to `mpx_line_output_dbfs`. Also consider whether `output_gain_db` should stay in `legacyResetPreservedMPXKeys` (it is treated as calibration today; the reset kept the harmful value). Listening after the fix: "audio quality improved" (operator, 2026-08-29). ~~Test tone generator broken~~ FIXED 2026-08-29 (calibration-source semantics, see CHANGELOG). smoke-test live-apply vs restart-required; tune composite clipper defaults (drive / ceiling / `mpx_clipper_lookahead_ms`) so a fresh install audibly beats `mpxgen` / PiFmRds untweaked.

**Sprint:** ~~Unit tests must never touch audio hardware~~ DONE 2026-08-29 (`deviceLister` injection, `ViewModelDeviceSourceTests`). validate PrimeBass / mono bass / widener / multiband on difficult real material; refine calibration workflow where real operator friction exists; per-Format-Profile clipper-drive A/B (eight 0.30 profiles).

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

## HF transient / pre-emphasis limiting prior art (survey 2026-08-29)

Backs "Next up (0): hi-hats / cymbals". Verdict: every classic HF-limiter,
sliding-band, dynamic-pre-emphasis and automatic-threshold technique is
EXPIRED and free to implement; three ACTIVE patents overlap the space and are
listed with design-arounds. Orban's MX limiter (8600, 2010) has no located
patent -- treat as trade secret, not as a constraint. US term rule used: in
force on 1995-06-08 -> later of 17 y from grant / 20 y from filing; filed
after -> 20 y from filing.

| Fix idea | Patent / publication | Status | What it covers, how it maps |
| -------- | -------------------- | ------ | --------------------------- |
| **HF limiter (Step 2 #2, primary actuator)** | [US 4,103,243](https://patents.google.com/patent/US4103243A/en) Orban, "Controlling peak signal levels in a bandlimited ... system employing HF pre-emphasis" (Optimod-FM 8100 HF limiter) | Expired 1997 | Split path: direct + bandpassed HF (peak ~+21.6 dB near 19.5 kHz, Q 1.09) through a VCA, summed; VCA gain from dual comparators on the SUMMED output, ~3 ms attack / ~10 ms recovery. The pre-emphasis boost itself is program-controlled: `y = x + g(t) * BP(x)`. Clipper follows, then a shelving overshoot filter. This is the topology to implement between stage 17 and 19. |
| HF limiter (sidechain) | [US 5,574,791](https://patents.google.com/patent/US5574791A/en) Orban/AKG, combined de-esser + HF enhancer | Expired 2014-06 | HF power vs loudness-weighted total power as a LOG RATIO drives HF reduction -- engage only when HF dominates the frame (a lone cymbal crash), not merely when the mix is loud. Use as the detector for the 4,103,243 actuator. |
| HF limiter (historical baseline) | [US 3,529,244](https://patents.google.com/patent/US3529244A/en) CBS Labs (Torick/Allen), FM Volumax "frequency sensitive amplitude limiting" | Expired 1987 | Program-controlled 6 dB/oct shelf between limiter and clipper. Simplest form; colours everything above the corner, so prefer 4,103,243's bandpass form. |
| HF limiter (supporting) | [US 3,621,151](https://patents.google.com/patent/US3621151) GRT, frequency-selective audio limiter | Expired 1988 | Resonant detector tuned to the saturation-prone HF region drives a frequency-selective attenuator; explicitly contrasted with clipping. |
| **Sliding-band variant (Step 2 #2 phase 2)** | [US 3,631,365](https://patents.google.com/patent/US3631365A/en) / [Re 28,426](https://patents.google.com/patent/USRE28426E/en) Dolby, "Signal compressors and expanders" (Dolby B); [US 3,846,719](https://patents.google.com/patent/US3846719A/en) Dolby, "Noise reduction systems" | Expired 1988 / 1991 | Side path HP + variable filter whose cutoff slides UP as HF amplitude rises, so only the region above the dominant HF component is compressed -- mids/vocals untouched while 8-15 kHz is reduced. Dolby FM applied exactly this to FM. |
| Sliding-band refinements | [US 4,490,691](https://patents.google.com/patent/US4490691A/en) Dolby (spectral skewing + anti-saturation); [US 4,498,055](https://patents.google.com/patent/US4498055A/en) Dolby (modulation control); [US 4,736,433](https://patents.google.com/patent/US4736433) Dolby (action substitution, SR/S) | Expired 2001 / 2002 / 2005 | Skewing: weight the HF detector so 15 kHz shimmer does not drive more GR than the 5-10 kHz region. Anti-saturation IS dynamic pre-emphasis for a saturating medium. Modulation control: stop mid/bass energy pumping the HF band. Action substitution: `max(sliding-band GR, fixed HF-band GR)` keeps control when a cymbal sits just below the slid cutoff. |
| Dynamic / distributed pre-emphasis (Step 2 #6) | [US 5,848,167](https://patents.google.com/patent/US5848167A/en) Aphex (Werrbach), distributed pre-emphasis equalizer; [US 4,112,254](https://patents.google.com/patent/US4112254A/en) dbx (Blackmer), signal compander | Lapsed 2006 / expired ~1996 | Split the 75 us curve: partial (75/50 us quotient) before the limiter, final 50 us after, so the limiter "sees 50 us" while the air curve stays 75 us; the post-limiter EQ re-grows peaks, so the composite clipper must follow. dbx: pole-zero weighting in the level-sensing path so detection tracks what overloads the channel. |
| Automatic-threshold HF band limiting | [US 4,843,626](https://patents.google.com/patent/US4843626A/en) Aphex Dominator (Werrbach), multiband limiter with ALT | Expired 2006-07 | Per-band limiters to a common reference; the summed output sets all bands' thresholds so the recombined signal fills the ceiling without pumping -- a lone hi-hat gets the full ceiling, bass + hi-hat lowers the HF threshold just enough. Keep parallel-bands + ONE final limiter (see active E3 below). |
| Clip-product monitor | [US 5,737,432](https://patents.google.com/patent/US5737432A/en) Aphex, split-band clipper | Expired 2016-11 | Watches the band NOT being clipped for the clipper's IM products and backs off clip depth. Reusable inverted: monitor 0-5 kHz for difference-frequency IM while clipping pre-emphasised HF. |
| Tonality-gated clip depth | [US 4,241,266](https://patents.google.com/patent/US4241266A/en) Orban, peak-limiting apparatus | Expired 1999 | Clip depth from waveform predictability: noise-like program (cymbals) may be clipped harder, periodic program less; less clipping when no LF masks IM. Candidate gate for HF clipper vs HF gain-ride routing. |
| Published (no patent needed) | Orban, "Transmission Audio Processing" ([PDF](https://static1.squarespace.com/static/58f8d954b8a79b4ccf726c3b/t/5996db51f5e231b4a279db2f/1503058769976/Broadcast+Transmission+Audio+Processing.pdf)); Orban/Foti AES 5469 (2001, [reprint](https://static1.squarespace.com/static/58f8d954b8a79b4ccf726c3b/t/5996dc63d7bdceeb0f5bc325/1503059043905/The+Truth+about+Audio+Processing+in+Radio.pdf)); Optimod 8200 manual ([archive.org](https://archive.org/download/orban_8200_Section_1/8200_Section_1.pdf)); Optimod 8100A manual 1986 ([scan](https://www.worldradiohistory.com/Archive-Catalogs/Orban/Optimod-8100A-Manual-1986.pdf)) | Prior art | "Placing a wide-band peak limiter after the pre-emphasis filter proved unsatisfactory ... cymbal crashes would cause the sound to literally collapse"; "HF limiting is usually performed partially by HF gain reduction and partially by distortion-cancelled clipping"; "simple clipping ... produces difference-frequency IM distortion which the de-emphasis in the radio then exaggerates ... particularly offensive on cymbals and sibilance"; HF limiters "sound best when operated independently (without stereo coupling)". 8200: explicit HF LIMITER (OFF..150 us) plus bands 4/5 coupled to band 3 acting as HF limiter. |

**ACTIVE -- design around, do not copy:**

| Patent | Holder | Expires | Claim gist | Our design-around |
| ------ | ------ | ------- | ---------- | ----------------- |
| [US 9,762,198](https://patents.google.com/patent/US9762198B2/en) | Dolby (Seefeldt), frequency band compression with dynamic thresholds | ~2034-04 | Per-band compressor thresholds made TIME-VARYING by a distortion-audibility (masking) model. | Keep thresholds fixed. If a masking model is ever used, let it act on the clipper's distortion RESIDUAL (how much to cancel / which band's residual to substitute -- the US 6,337,999 lineage we already run), never on thresholds. |
| [US 9,385,679](https://patents.google.com/patent/US9385679) | Maxim (Polleros), staggered-Y multiband limiter | ~2034-06 | Band limiters summed pairwise with a "summer limiter" after each summer. | Parallel band limiters + ONE final wideband limiter/clipper (Werrbach 4,843,626 topology = our current chain). No cascaded per-summer limiters. |
| [US 7,991,171](https://patents.google.com/patent/US7991171B1/en) | Wheatstone (Snow), 30+ harmonically related bands | ~2030-05 | Gains chosen jointly across fundamental + harmonic bands. | Peripheral; do not select multiband gains jointly across harmonically related bands. |

Not located / unverified (treat as trade secret): Orban MX limiter (no filing after US 6,618,486 under Orban's name); Telos/Omnia clippers (only Foti's expired composite-filter [US 4,991,212](https://patents.google.com/patent/US4991212A/en) verified); Thimeo/Stereo Tool "Advanced Clipper"; CRL and Texar HF limiters.

Recommended combination for Step 2 #2: 5,574,791's HF/total log-ratio detector with 4,490,691's spectral-skewing weight, driving 4,103,243's `x + g*BP(x)` actuator, sliding cutoff (3,631,365 / 3,846,719) as the phase-2 option, action substitution (4,736,433) if the slid band leaves gaps; per Orban's paper run it per channel (un-linked) and A/B that against the project's stereo-link discipline with the new separation + image metrics.

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
