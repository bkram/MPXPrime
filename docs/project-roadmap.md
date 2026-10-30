# MPX Prime -- Project Roadmap and Open Work

<!-- markdownlint-disable MD025 -->
<!-- Planning document: two deliberate top-level parts (open work and
     anti-rework guardrails), each a `#` heading so they read as separate
     papers. -->

Open work and anti-rework guardrails. **Not** a readme: positioning,
architecture and build live in `README.md`, `docs/ARCHITECTURE.md` and
`docs/BUILDING.md`; shipped work lives in `CHANGELOG.md` and git history.
Do not re-plan shipped work as pending -- cross-check CHANGELOG before acting.

## Status

Status on 2026-10-30: pre-release. The last tag is **0.50** (2026-09-11,
`v0.50`, AGPL-3.0); everything since is "Unreleased" in CHANGELOG, and 0.65
is the next release, built on `develop/v.065`. There are no existing users or
stations yet. Pruned 2026-10-16: every finished item and campaign history
removed; this file holds only open work and the guardrails. The 2026-10
audio-chain overhaul (`feature/audio-chain-overhaul`) closed the stereo-link
blend, the Advanced Dynamics parity remainder, the budget hygiene items and
the working programme-separation metric; what it left open is the first
section below.

---

# Open work

## Audio-chain overhaul: open items (2026-10-30)

Recorded from the overhaul's reports (budget, clipper, protector, BS.412,
separation gates, device volume, levelling) and the 2026-10-20 air log. In
the order decided on 2026-10-30:

1. **Second composite clipper after the 55 kHz FIR** (clip -> FIR -> clip,
   the Omnia / Stereo Tool arrangement) -- the next task. The clip depth
   measured that deeper clipping buys 0.0-0.2 dB of RMS per dB of depth,
   because 70-85 % of what the kernel removes returns as the restored
   guard-band share of the residual plus decimator / 55 kHz FIR overshoot,
   which the true-peak final limiter then rides (0.78 dB of duty at depth 1).
   The Music - Clean loudness goal is not met (program_mix 0.925 of the
   budget, wide_bass 0.79, goal 0.97) and no target / drive split reaches it
   while the 20 dB hi-hat SINAD floor holds. The only path to it that does
   not lower that floor is an overshoot-compensating second clip: a second,
   oversampled, guard-protected `CompositeClipper` instance (or the same
   kernel without its look-ahead) after the 55 kHz FIR with its ceiling on
   the budget, the final limiter kept as the true-peak bound behind it, with
   the pilot / RDS guard problem solved for the second stage (the 1x shaper
   is guard-less, which is why 0.45 made it idle). It changes
   `processFinalComposite`'s stage order, so it is its own verifier-backed
   task, never an opportunistic edit (report-clipper.md section 4).
2. **The level model** (audit-level-controls.md section D, P1-P7), after the
   checkpoint: one **MPX Output Level** in MPX mode (retire `output_gain_db`
   there with a load-time fold into `mpx_line_output_dbfs`), a 400 Hz / 100 %
   calibration tone with the expected kHz shown on both front ends, pilot and
   RDS in kHz and %, the DAC volume held at 0 dB.
3. **Unexplained 200-400 Hz crosstalk on Music - Loud / Dense.** Panned
   programme reads 31-32 dB in the silent channel in that band with the
   composite clipper OFF (bypass 40-49 dB, encoder-only 96 dB), so something
   in the audio-domain chain of those two profiles (PrimeBass / bass clipper /
   Advanced Dynamics, not the clipper) puts 220 Hz into the quiet channel.
   Not gated today: `--verify-receiver` marks the band `mb` while mono bass is
   on. The stereo-guard decision excluded it.
4. **One pilot / RDS phase convention.** `--verify-receiver` prints "Phase
   247.9 deg", the Meter reads about 10 deg "out of spec" off air (also on a
   silent carrier) and the two cannot both describe EN 50067's pilot-to-RDS
   angle. Needs one definition and a direct DAC capture (no RTL channel
   filter in the path) before anyone touches the encoder (air-log.md; the
   relabelling item under "Enterprise-parity roadmap" is the same question).
5. **Second on-air round** (variants A-F of `ab-air.sh`, F = pre-encode
   limiter off) waits for a transmitter; the first round's figures and
   method are in the audit folder's air-log.md (player restarted per variant
   next time, so the correlation column is comparable).
6. **HF transient floors not re-derived.** The clip depth was chosen to fit
   the existing `--verify-hf-transients` floors (ride 30 dB, hat 20 / 15 dB)
   with 2 dB in hand; a deeper default needs a product decision on those
   floors (Speech's hat floor has only 1.8 dB in hand at every depth,
   including 0). Lowering the Clean hat floor to 19 dB would buy about 1 dB of
   net level (program_mix 0.98-0.99) without item 1.
7. **Dashboard budget state.** The web dashboard shows only the
   whole-composite margin plus OVER BUDGET; a Safe / Tight / Risk word there
   needs the audio ceiling in `/api/meters` (preferably `audioCeiling` on
   `MPXGenerator.CompositeCalibrationStatus`, carried through both meter
   snapshots, so the GUI's `CompositeBudgetState` stops re-deriving the budget
   arithmetic) and a `Budget State` row next to the margin.

Also noted, lower priority: `--verify`'s `truePeakOvershootDB` column reads
the 4x true peak over the sample peak of the complete multiplex after pilot /
RDS injection (0.26 dB on `hard_panned_hf`, unchanged by the true-peak
detector, which bounds the audio composite); whether the column should read
the audio composite is a verifier question. The final-stage "Broadcast
Preset" table still carries Speech 4.3 dB and Classical 3.0 dB of drive;
profiles override them.

## Next up

1. **Anti-aliased clipping kernel (US 6,937,912).** Phase A/B landed opt-in
   (`pre_encode_bandlimited_residual_enabled`). Remaining: A/B real program
   with it on, decide whether any loud preset enables it; optional Phase C
   applies the primitive to `softClipSafety`.
2. **Tune/validate composite clipper look-ahead.** `mpx_clipper_lookahead_ms`
   shipped and the 2026-10 `Clip Depth` defines what the look-ahead rides
   (everything above ceiling + depth); remaining: dense real-program A/B at
   0.5 / 1 / 2 ms and verify pilot/RDS guard cleanliness. Capture via
   `MPXPRIME_AUDIT_CAPTURE=1`.
3. **Smoke-test pass.** Live-apply vs restart-required on difficult real
   material; catch transients / clicks / dropouts on toggle. New RDS live-apply
   paths (PI / PTY / flags / AF / scheduler) need real-receiver checks beyond
   the bit-stream tests.

## Audit remainders (October 2026)

The October 2026 audits of peak control, levelling and bass, encoder / RDS /
outputs, the test suite and the UI layout are fixed and recorded in CHANGELOG;
the UI rules live in `docs/ui-style-guide.md`. Left open:

- **Decision: FIR splitter taps with the dual-rate domain off.** Above 96 kHz
  the splitters use up to 4097 taps so the lowest crossover keeps its designed
  transition; CPU 75 % -> 96 % of real time at 192 kHz on hikari in that
  non-default setup. Revert: `maxTaps` back to 2049.
- Composite bandwidth FIR: redesign so it also protects the RDS band (today
  only the composite clipper's RDS guard does). Low impact.
- `MonoBassFilter` is clamped to 2049 taps with the dual-rate domain off, so a
  low corner at 192 kHz gets a wider transition than designed.
- MPX Prime Meter: migrate `VerticalMeterStrip` to `LadderMeterView`.
- Tests: a call-site test for the line-output trim; `RDSRestartParity` still
  paces by wall clock.
- Linux: CPU of the sinc input ring and the linear-phase mono bass not yet
  measured on x86_64.

## Real-time correctness (from the 0.50 external review)

An external review of 0.50 (revision `aaf0521`) reported seven chain defects
and two real-time defects; the seven are fixed (CHANGELOG, Unreleased). The
two real-time items stay open, measured and deliberately not yet fixed:

- **P1-1 -- live-apply rebuilds on the render thread.** Both engines call
  `generator.applyRuntimeConfig` from the render thread after the try-lock
  mailbox. Inside: the BS.412 ring is reallocated on a window change, the
  multiband / Advanced Dynamics FIR splitters are redesigned on a crossover or
  enable change (four Kaiser kernels), the composite clipper reconfigures,
  strings are lowercased. **Measured 2026-09-12** (Ryzen 5 PRO 2400GE,
  192 kHz, blocksize 4096, Advanced Dynamics on, twelve live PATCHes in 20 s):
  zero xruns; Render Load median 30.9 %, the worst period was the crossover redesign at
  **50.5 %** (about 4 ms of one 21.3 ms period); BS.412 enable / disable peaked
  at 42 %, the bass clipper toggle at 38 %. Harmless at 4096, but a 4 ms
  rebuild does not fit a 512-frame period (2.7 ms). Keep 4096 the Linux
  recommendation. The fix, if small blocks on air become a requirement:
  preallocate the BS.412 ring once, design FIR kernels producer-side as a
  prepared field of `RuntimeConfig` (pure functions of crossovers and rate),
  lowercase strings in `makeRuntimeConfig`; acceptance through
  `scripts/ab-music-live.sh` with the crossover toggle added.
- **P1-2 -- RDS group generation takes locks and allocates on the audio
  thread.** `buildGroup2` builds a String plus bytes in `currentRTFrame`,
  `writeSnapshot(rt:)` takes `snapshotLock` on every 2A group,
  `currentNowPlayingSnapshot` takes the Now Playing `NSLock`, and every
  `buildGroup*` returns a fresh `[UInt8]`. One group every 87.7 ms and zero
  xruns in every soak so far, including a Linux rig at 95 % render load:
  real-time-correctness debt, not an observed fault. Fix: publish the RT
  segment / PS index as an atomic the API side resolves to text, consume the
  Now Playing snapshot through a preallocated double buffer with a sequence
  counter (never releasing a Swift object on the render thread), reuse one
  fixed 104-bit buffer for the group (make `RDSBitBufferReuseTests` prove
  storage reuse). A pre-encoded group bank only if instrumentation shows
  deadline misses.

Parked from the same review, not adopted: its phases 3-6 (tuner / recording
hardening, an encoder-to-IQ-to-tuner oracle, splitting `MPXGenerator` by
orchestration concern, lifecycle protocols for every stage, a latency ledger)
are a multi-release programme, and the generator split collides with the rule
not to refactor `processFinalComposite` opportunistically. The "versioned
prepared-state handoff" for P1-1 and the full producer / consumer split for
P1-2 re-architect the two best-tested parts of the product: do the cheap fixes
above first and let measurement decide.

## Checks that need the rig, a receiver or the maintainer

- **Band waveshaper listening pass** (maintainer): `docs/test-playlist.md` bass
  tracks on a RELEASE build, old curve vs new. If it sounds worse the knee
  (`defaultKnee = 0.9`) moves, not the curve -- the discontinuity is not
  coming back.
- **BS.412 on-air smoke**: no live check yet of the compliance guard; needs
  the rig and an off-air Meter comparison.
- **AM Output against hardware**: measured (mono sum, the NRSC curve, the band
  limit, both peak cases) but never checked on a modulation monitor with a
  real AM transmitter. Until then it is a first implementation, and the docs
  say so.
- **Stereo polarity fix on a car radio** (Step 1 of the chain design review).

## Web dashboard taxonomy -- remaining

Phases 1-4 (structure, labels, disclosure, aids) shipped in both front ends.
Left:

- **Phase 5 -- operator round.** A think-aloud run of ten task cards on the
  result ("make the station louder", "change the PS text", "calibrate the
  exciter", "switch to FM Output", "why is Render Load red", "load last week's
  setup", and so on), measuring clicks-to-complete against the old tree; fix
  what it finds.
- **Setup > Remote access page.** `[CONTROL]` keys are GUI-Settings only;
  exposing them on the dashboard needs a decision on configuring the control
  server over the API it serves. `ControlSchemaTests.deliberatelyUnexposed`
  shrinks when it lands.

## Clipper and peak-control work

From the clipper campaign (approved 2026-10-10, prompted by Stereo Tool's
RuleBreaker 2 notes). Each item ships only through the real-music A/B
(`--verify-program-ab`) with a loudness gain at unchanged crest / IMD /
separation:

- **Transient-aware clipper drive**: a sidechain that admits short transients
  at higher drive and backs off on sustained dense material. Medium.
- **Pumping-sound removal**: detect narrow-band bursts (a lone hat, a
  sibilant) and handle them per band instead of in the broadband limiter.
  Large.
- **Tonal crackle in the distortion-cancelled clipper**: research first.
- FM presence tilt: Music -- Loud carries +1.5 dB at 80 Hz / +1.0 dB at 3 kHz
  in the PEQ; a 10 kHz / 5 kHz pair stays an option once the real-music A/B
  can run.

HF transients (hi-hats / cymbals), remainders of the 2026-08-29 campaign,
lowest effort first:

- `mpx_clipper_cancel_audio` low-band-only variant -- measured no effect once
  the HF clipper is out of the path; low priority.
- Pre-encode limiter: half-cosine attack + HF-only gain path (enterprise item
  B5 below).
- `hf_limiter_stereo_link` -- Orban prefers UN-linked fast HF limiters; A/B
  against the image metrics.
- L/R 15-19 kHz residual of the pre-encode limiter's tanh ceiling (the last
  L/R nonlinearity sits after the 15 kHz FIR; Orban band-limits the
  "clippings" of that stage, US 6,337,999): gate = 15-19 kHz energy at the
  encoder input on dense program; the fix, if it shows, is a differential /
  band-limited residual, NOT a post-limiter LPF.
- Dynamic pre-emphasis load manager (an HF-excess sidechain that relaxes a
  little pre-emphasis gain ahead of the limiter on bright transients, never
  switching the curve): the unwired 0.44 attempt was removed in 0.45; only
  worth revisiting through the `--verify-hf-transients` gate.
- Stereo Tool's recipe for bright program (no HF gain rider; raise the HF
  compressor / lower the HF limiter) -- try as a Music -- Loud preset tweak.

## Chain design review (approved 2026-08-30) -- remaining steps

Steps 1-4a and the enterprise items A1 / A1b / B1 / B2 shipped (CHANGELOG has
the measurements). Left, in the approved order:

- **Step 0 -- measurement first (remaining):** end-to-end latency
  (`totalChainDelaySamples`, impulse test, `--verify` + `/api/status`);
  protection in dB re subcarrier (pilot / RDS / 38 kHz / SCA); RDS BLER under
  load; THD / SMPTE / CCIF of decoded audio; BS.1770 + BS.412 on the verifier
  output; verifier <-> Meter cross-check; stale tests moved to the 48 kHz
  audio rate (`MultibandFIRSplitterTests`, `EncoderBandwidthTests`,
  `DualRateHFResponseTests` tolerances). (The programme-separation metric
  shipped 2026-10 as the per-band panned-programme crosstalk gate.)
- **Step 4b -- remaining clipper items:** 1-2 POCS re-projection passes
  (measure the bound probe and the hot-config ride with them); knee default
  -0.5 / -0.3 dB after an HF-SINAD A/B; bandwidth FIR 53 kHz / 2 kHz
  transition. Settled 2026-10: the final-limiter ride is understood (the
  restored guard-band share plus filter overshoot, 0.8 dB at clip depth 1 by
  design) and its release buys nothing (95 / 50 / 30 ms identical); the
  clip -> FIR -> clip item above is the successor of the "look-ahead removes
  the ride" lead.
- **Step 5 -- dynamics practice gaps (remaining):** pre-encode limiter
  full-band look-ahead with attack ~ look-ahead (B5). The partial-link
  experiment is done: `pre_encode_stereo_link` ships at 1.0 and measured
  identical at every setting because the limiter idles at the shipped levels.
- **Step 6 -- budget hygiene + defaults (remaining):** reservation from
  the delayed subcarriers, pilot default 9 % (today 8 %), document 3 kHz RDS
  as the field choice (margin 0.005 and `limit_threshold` 1.0 shipped
  2026-10). The Thimeo-style post-injection pilot-aware clipper (~0.5-1 dB
  realised) waits until steps 4-5 are measured.
- **Step 7 -- optional structure:** Omnia-style band sync (clamp gain
  disparity to a master band), switchable PrimeBass placement (every vendor
  places the bass enhancer BEFORE the multiband so it controls the energy it
  adds; ours sits after, mitigated by the bass clipper + stereo-image
  protection), speech detector easing clipper drive, per-band `BandLimiter`
  on `music_loud` as the density path before more clipping.

### Enterprise-parity roadmap (approved 2026-08-30) -- remaining items

Rating vs Orban 8600 / Omnia.11 / Stereo Tool: encoder side professional-grade;
processor side mid-tier with untuned dynamics. Payoff per effort, each item
measured before it is heard:

- **A2** POCS re-projection passes (`mpx_clipper_iterations` 1-3, cascade of
  `CompositeClipperPass`, delay summed into `recomputeSubcarrierDelay`);
  default 1, Music -- Loud -> 2 after the table.
- **B4** per-band `BandLimiter` as the density path on Music -- Loud (5 ms
  hold, HF tilt, profile fields).
- **B3** Omnia-style band sync (`multiband_sync_db`, clamp target GR to master
  +/- D) -- also the cure for the Advanced Dynamics crossover-skirt lift.
- **B5** pre-encode limiter attack = look-ahead / 4, sliding-window-max
  detector (the A1b detector, applied to the L/R limiter), look-ahead 2-3 ms.
- **A3** clipper knee -0.5 / -0.3, bandwidth FIR 53 / 2 kHz, pilot 9 % for
  new installations (the margin and threshold part shipped 2026-10).
- **B6** speech / music detector easing clipper drive
  (`mpx_speech_drive_ease_db`).
- **C** measurement the vendors publish (Step 0 list above).
- **B7** clip-detection metric only (no declipper this cycle); **D** optional
  structure (enhancer placement, AGC window, density macro, x1 120 Hz).
- Relabel the receiver report's "Pilot ... Phase 45.4 deg" (it is the pilot's
  absolute phase at the analysis window, not pilot-to-RDS; one half of open
  item 4 of the audio-chain overhaul above); explain the 10 kHz
  PLL-path separation (~51-54 dB vs 95 dB at 1 / 14 kHz -- a decoder-PLL
  artefact); give `processEncoderHFGuard` named constants + a test.

## Digital delivery target -- open items

The digital target for Processed Audio (`processed_audio_target`,
`processed_audio_ceiling_dbtp`, 20 kHz bandwidth, no pre-emphasis, true-peak
ceiling) shipped; see CHANGELOG and `docs/ARCHITECTURE.md`. Still open:

- **BS.1770-4 loudness metering** (momentary / short-term / integrated LUFS +
  true-peak max) on the Monitoring dashboard and `/api/meters`. Design: a
  `LoudnessMeter` in `DSP/` (K-weighting -> 400 ms / 3 s windows -> absolute
  -70 LUFS and relative -10 LU gating -> integrated; true-peak max from the
  existing 4x path) fed from the audio-only render path, published as
  `lufsMomentary`, `lufsShortTerm`, `lufsIntegrated`, `truePeakDBTP` with a
  Reset and validity flags like the Meter's, shown in place of the MOD meter
  on the digital target. Test with BS.1770-4 known-answer signals (-23 LUFS
  1 kHz sine reads -23.0 +/- 0.1) and the EBU Tech 3341 gating vectors; follow
  BS.1770-4 exactly on silence and very short programme. Without it the
  operator sets loudness by the AGC target and an external meter.
- **A "Digital -- Streaming / DAB" Format Profile** (AGC target about -18,
  light multiband, PrimeBass off, bass clipper off, drive low), which wants
  the meter first so the target can be verified rather than asserted;
  `FormatProfileTests` pin its keys. Targets: AES TD1008 recommends
  DELIVERING -16 LUFS for music, -18 for speech, -17 where one chain carries
  both; EBU R128 broadcast (DAB in Europe) is -23 LUFS. The -14 LUFS figure
  quoted for Spotify / YouTube / Tidal is a PLAYBACK normalisation level, not
  a delivery spec; the profile does not chase it.
- **A separate digital clipper drive** defaulting to off (Thimeo's
  "Web/HD/DAB clipper drive": "audio for FM needs to be clipped much harder
  than streams"). Today the final clipper is simply inactive on the digital
  target, which is the right default but not the full control.
- **Codec conditioning** stays out of scope, gated on a measurement: encode
  the verifier scenarios through an AAC encoder, decode, time-align and score
  the difference (see "Codec conditioning prior art"). All three vendors
  pre-condition for the encoder (Omnia Sensus, Thimeo "Prepare for lossy
  compression"); we leave the codec real headroom and stop clipping into it.

Facts that constrain this work: -1 dBTP is the common ceiling (EBU R128, AES
TD1008, the streaming platforms), but EBU production guidance asks for
-2 dBTP ahead of a data-reduction codec, because lossy encoding pushes
inter-sample peaks up. No simultaneous FM + digital: the vendors run both
chains at once with up to 12 s of diversity delay; one MPX Prime instance
emits one thing, and diversity delay is out of scope. A true loudness
NORMALISER (automatic gain to a LUFS target over a whole programme) is out of
scope until the meter exists.

Sources: Orban OPTIMOD 8600 in-depth description
(<https://www.orban.com/indepth-optimodfm8600>), Telos Alliance Omnia.11
(<https://telosalliance.com/radio-processing/radio-processors/omnia11>) and
Omnia VOLT HD-Pro (<https://bgs.cc/omnia-volt-hd-pro/>), Thimeo Stereo Tool
documentation on limiting and clipping
(<https://www.thimeo.com/documentation/limiting_and_clipping.html>),
EBU R 128 (<https://tech.ebu.ch/docs/r/r128.pdf>), AES TD1008
(<https://aes2.org/wp-content/uploads/2024/01/20210924_TD1008_v3.13.pdf>),
Telos Alliance on streaming loudness
(<https://docs.telosalliance.com/docs/understanding-loudness-for-streaming-audio>).

## Operating modes -- open items

- **AM processing tuning.** The chain's defaults are FM-shaped: an AM Format
  Profile (denser, narrower, heavier low-mid control, no HF sizzle) is the
  natural follow-up.
- **A "what would this mode change?" preview** before a restart-class mode
  switch (the operator sees the new controls only after the restart today).
- Deliberate: the Advanced page is un-gated. It is the raw INI editor and
  shows every key in every mode; a mode-aware view there would hide keys an
  operator may need to fix by hand.

## Opt-in advanced stages -- validate + decide default

These stages are implemented and shipped but **default-off and not
preset-validated**, so a fresh installation runs below the chain's real capability.
Each needs a verifier/listening A/B -> a per-preset enablement decision. OFF
must stay bit-identical (`--verify --baseline-strict` green); ON validated via
`--verify-receiver` (separation + pilot/RDS guards unchanged).

1. **Multiband Phase 2 -- transient-aware attack**
   (`multiband_transient_aware_attack_enabled`). Verifier + dense-percussive
   listening A/B; preset decision.
2. **Multiband inter-band coupling** (`multiband_inter_band_coupling_enabled`,
   `--verify-multiband-coupling`). "Loud bass softens highs" -- listening A/B;
   preset decision.
3. **Anti-aliased residual clipping** (`pre_encode_bandlimited_residual_enabled`)
   -- see Next up #1.

## Experimental candidates -- composite-processing ideas (parked 2026-08-01, user decision)

Analysis of a third-party processor's press release (loudness/cleanliness claims) mapped onto our chain; all would ship off-by-default and verifier-gated. We cannot know the vendor's actual method -- these are our own defensible readings backed by the interleaving maths.

1. **`mpx_clipper_iterations` (moderate).** POCS-style iterative clip -> re-project (bandlimit + protected bands) composite peak control; our differential clipper + guard-band cancellation is one iteration of exactly this. 2-4 iterations at OS rate, CPU-gated by `DSPThroughputTests`, measured by guard-band depth / >60k leakage / receiver separation.
2. **Studio<->Meter closed-loop RF trim (large).** Their "analyzes RF bandwidth after the exciter" loop; the Meter's RF spectrum (0.43) is the sensor. Auto-trim clipper drive against occupied-bandwidth targets. Needs the control API on the Studio side + a Meter export path first.
3. **Composite peak-to-RMS governor (from the retired FUTURE.md).** A slow
   loudness governor on the audio composite that holds a target peak-to-RMS
   ratio (density) rather than a peak, so Final Drive stops being the only
   loudness lever; verifier metric first (composite RMS / peak per scenario),
   then an opt-in stage. Sketch: `crestDB = 20 log10(peak / rms)` over a
   rolling window, `driveTrimDB = -k * max(0, crestDB - targetCrestDB)`
   applied with 1-3 s attack / 5-10 s release (an automatic preset guardrail,
   not a limiter). Composite peak-to-RMS also drives FM multipath rejection at
   the receiver, and nothing in the chain tracks it yet. Compare with the
   existing BS.412 limiter, which already bounds MPX power.

## Broadcast-tier follow-ups

- **Multiband Phase 3 -- per-band look-ahead.** Reuse `LookaheadLimiter` ring-buffer per band. Largely redundant with Phase 2; skip unless dense percussive listening shows Phase 2 isn't enough. ~3-5 d.
- **Stereo-band cancellation depth via FIR bandpass.** Optional/depth-only. Delta substitution gets ~5-10 dB in the stereo subband (LR4 phase-bounded); linear-phase FIR bandpass would push to 20+ dB. Only if listening (Next-up #1) says residual cross-domain IM is audible at amateur drive.
- **Audio-clipper oversampling bump.** `BassClipper` 4x->16x, `DistortionCancelledClipper` 8x->16-32x, likely swapping `BiquadCascade6` decimation for `LinearPhaseFIRDecimator`. Polish (aliasing already inaudible at amateur drive); ~1-2 d each + baseline refresh. Aliasing gate: `DistortionCancelledClipperTests.aliasingEnergy` (-38 dBFS now; pro chains push past -75).

## Open gaps

1. **Calibration workflow** -- exciter-facing guidance + long-run operational hardening.
2. **AGC validation** -- density-scaling tuning on real program; decide whether a lookahead path is worth the latency.
3. **Stereo image validation** -- mono bass / PrimeBass / multiband interaction on difficult real program.
4. **Live-apply smoke testing** -- TA-edge auto-injection and AF Method B switching in particular.

## Verifier coverage follow-ups

- **Tighten bandwidth baseline tolerance** (+/-1.0 -> +/-0.5 dB) with a multi-frame averaged FFT to cut spectral leakage in the `>60k/>67k` ratios.

## Tactical backlog

**Sprint:** validate PrimeBass / mono bass / multiband on difficult real material; refine calibration workflow where real operator friction exists; per-Format-Profile clipper-drive A/B (eight 0.30 profiles).

**Medium-term:** dedupe biquad/crossover filter-config logic; name DSP magic numbers; deterministic RDS-scheduler tests; more AGC / filter-primitive unit tests.

## Code-quality priorities

### P0 -- confidence/safety

1. Fix verifier bandwidth metric so RDS doesn't skew occupied-width (`bright_dense` occ999 reads differently with `en_rds` on/off). NOTE: this is a metric *redefinition* (exclude the 57 kHz RDS band from the occupied-width / above-60k/67k power sums), not an active bug -- the threshold + baseline already account for RDS. Cascades into 3 baselined bandwidth fields -> recapture. Decide the metric's intended meaning (audio-only width vs total composite) before doing it.

**P1 -- modularization** (MPXPrimeCore is the forcing function; companion-app needs the same boundaries)

- extract the RDS subcarrier front-end (57 kHz mixdown -> biphase symbol+clock recovery -> differential decode) feeding `RDSStreamDecoder`, and an `MPXAnalysisTap`/FFT helper; split `MPXGenerator.swift` into stage files; split `AudioOutputEngine.swift` by concern; reduce engine/config/generator/UI coupling.

**P2 -- harden behaviour:** stronger `AppConfig` validation; `sum_level` 1.0->0.9 investigation; device/routing edge cases; structured error reporting.

**P3 -- performance:** more vDSP where profiling shows value; cache RDS byte prep; hot-path benchmarks; keep an Instruments baseline.

## UX / accessibility polish

Open items after the 0.37 HIG pass, lower priority:

1. **Format-profile drift indicator.** When the config drifts from the selected Format Profile, show the picker as "edited". Real feature but needs `applyFormatProfile` refactored into a pure function + a decision on which fields count as drift; the model author deferred it ("no dirty indicator in v1"). A half-correct version gives false "edited" flags, so do it properly or not at all.
2. **Prose-to-tooltip sweep.** Mostly already appropriate -- the house rule keeps *distinct actionable guidance* inline; little remains safe to move. Low value.
3. **Dynamic Type pass.** Manual: launch with large system text, verify no clipping/overlap across tabs (fonts are already semantic, so likely nothing to fix). Eyes-on, not a code task.
4. **Sidebar-row enabled affordance.** Overview cards now carry status dots; the `StageSidebarRow` 6 pt dot is unchanged -- optional native status badge / contrast check.

## RDS enterprise tier (stretch -- only if direction shifts to multi-station)

1. **UECP SPB 490 minimal subset over TCP/IP** (port 5570, DLE framing, MEC parse for PI/PS/PTY/RT/AF/TA/scheduler/master-enable, address fields). Hooks into `applyRDSRuntimeConfig`. ~1-2 wk, new `UECPServer.swift`.
2. **EON (14A/14B)** -- linked-network PI/PS/AF/TP/TA mirroring across PSNs. ~3-5 d.
3. **Multi-PSN / Data Sets** -- per-PSN `RDSRuntimeConfig`, boundary switchover without PI flap. ~1 wk, builds on UECP.
4. **Ops: SNMP MIB + watchdog + time-of-day scheduler + on-air loopback verify.** ~2-3 wk.

- Deferred standards item: Group 15A UTF-8 Long PS toggle bit (IEC 62106-2:2018 sec. 6.8; ASCII Long PS is correct for amateur use today).

## Meter -- open items

The 2026-08-31 Meter audit and the RTL-SDR bench are closed; their history is
in CHANGELOG. The open remainder (tuner channel-filter fix blocked on a second
dongle, the Meter-integrated calibration loop, the maintainer's hardware
validation queue, parked items) lives in [meter-roadmap.md](meter-roadmap.md).

## Linux port -- remaining / possible follow-ups

- JACK backend behind an `AudioBackend` protocol (today ALSA-only); Pi 4/5
  real-time budget still unmeasured.
- Meter CLI on Linux (the tuner C++ is already portable; SDRplay dlopen
  needs `.so` names).
- ALSA output device enumeration is in the dashboard picker; a headless
  `--list-devices` equivalent could mirror it.

### arm64 SIMD kernels for Linux (long-term, not started)

Worth doing only for **Linux on arm64** -- a Pi 5, an Ampere box, an arm64
VM. macOS on Apple Silicon needs nothing: `MPXPrimeAcceleration` compiles
EMPTY there and the hot kernels are Accelerate's own `vDSP_dotpr` /
`vDSP_conv` / `vvtanhf`, which are already hand-tuned for the part. The C
kernels in `MPXPrimeNative/MPXPrimeSIMD.c` are x86-only today (SSE2 default
plus an AVX2 clone behind a glibc ifunc), so an arm64 Linux build falls back
to the portable Swift reference (`mpxReferenceDot` / `mpxReferenceTanh`) and
runs the chain unaccelerated. Nobody has measured what that costs -- that
measurement is step one, not the kernels.

What it would take, in order:

1. **Measure first.** `--bench` on arm64 Linux (an arm64 container on an
   Apple Silicon Mac runs natively and is enough for a first number, a real
   Pi 5 for a decision). If the reference path already fits the budget, stop:
   the kernels are not worth a third numerics path.
2. **NEON variants** of the same two kernels, selected at load the way the
   x86 ones are -- except every arm64 CPU that matters has NEON, so this is a
   compile-time target rather than an ifunc.
3. **The bit-parity contract is the hard part.** One Linux baseline is valid
   for every CPU only because AVX2 and SSE2 compute bit-identical results:
   same 8-lane vectors, same accumulation and reduction ORDER, and FMA
   contraction off (`#pragma clang fp contract(off)`). NEON must meet the
   same three conditions or Linux needs a baseline per architecture, which is
   a policy change, not a flag. NEON's fused multiply-add is exactly the trap
   -- `vfmaq_f32` would silently change results. `AccelerateShimTests` holds
   the C kernels to the Swift reference bit for bit and is the gate.
4. **Decide the baseline question deliberately.** There is no
   `default-linux-aarch64.json` today and nothing looks for one. Adding arm64
   as a supported Linux target means either proving bit-parity with the
   x86_64 capture (preferred) or accepting a second stored baseline and a
   second CI leg.

**Verification note, because it is easy to get wrong:** an **amd64** Docker
image cannot test any of this. On an Apple Silicon Mac an amd64 image runs
under emulation, executing x86 instructions -- it exercises the SSE2 path,
not NEON. Use a NATIVE arm64 Linux container (`swift:noble` on this Mac runs
arm64 at full speed) for correctness and bit-parity, and real arm64 hardware
for any timing claim; an emulated container's timings are meaningless.
Conversely, the x86_64 strict baseline cannot be checked in an arm64
container either -- it looks for a per-architecture file, finds none, and
reports "Baseline: none", which is why the x86_64 comparison stays CI's job.

---

# Anti-rework guardrails -- do not re-plan / re-implement

## Active patent backlog

| Priority | Patent | Title | Expires | Stage | Why |
| -------- | ------ | ----- | ------- | ----- | --- |
| **P0 -- validate / Phase C** | [US 6,937,912](https://patents.google.com/patent/US6937912B1/en) | Anti-aliased clipping with band-limited step functions | 2025-09 | `OversampledPeakLimiter` (pre-encode L/R) landed opt-in; `audioCompositeSoftClipEnabled` shaper still candidate | Phase A/B landed opt-in via `pre_encode_bandlimited_residual_enabled`. Remaining: program validation, then optional Phase C on the audio-composite shaper. |
| **P1** | [US 6,434,241](https://patents.google.com/patent/US6434241B1/en) | Half-cosine signal peak control | 2014-08 (lapsed) | Same stages as P0, alternative kernel | Continuous-first-derivative half-cosine peak; overshoot ~10% -> 0.1-0.2%. Less IM rejection than US 6,937,912 but lower CPU. Selectable kernel / fallback. |
| **P3** | [US 5,892,833](https://patents.google.com/patent/US5892833A/en) | Gain calibration for audio compressors | Expired | `MonoCompressor` makeup stage | Track average GR to keep makeup roughly compensating. Polish, low priority. |
| **P6** | [US 7,076,071](https://patents.google.com/patent/US7076071B2/en) | Ambience/imaging enhancement (mono-null bus) | Expired | Stereo widener | Invariant: any enhancement term must cancel in `L+R`. Land first as a verifier metric (mono-sum delta widener on/off), then constrain the widener to meet it. FM-safe answer to Open-gaps #3. |
| **P7** | [US 4,567,607](https://patents.google.com/patent/US4567607A/en) | Stereo image recovery (frequency-bounded crossfeed) | Expired 2003-01-28 | Stereo widener | Crossfeed below ~1-5 kHz, bounded phase difference, shaped mono dip ~200-900 Hz. Pairs with P6 as widener guardrails. |

P4 (US 4,249,042) + P5 (US 3,790,896) landed in 0.34 as the bass-desensitised wideband AGC (`wideband_agc_bass_desensitize`, opt-in). Optional extension: **silence-sense freeze** ([US 4,500,753](https://patents.google.com/patent/US4500753A/en), Gentner, expired 2003) -- freeze AGC recovery during near-silence.

## HF transient / pre-emphasis limiting prior art (survey 2026-08-29)

Backs the HF limiter and the HF transient work. Verdict: every classic HF-limiter,
sliding-band, dynamic-pre-emphasis and automatic-threshold technique is
EXPIRED and free to implement; three ACTIVE patents overlap the space and are
listed with design-arounds. Orban's MX limiter (8600, 2010) has no located
patent -- treat as trade secret, not as a constraint. US term rule used: in
force on 1995-06-08 -> later of 17 y from grant / 20 y from filing; filed
after -> 20 y from filing.

| Fix idea | Patent / publication | Status | What it covers, how it maps |
| -------- | -------------------- | ------ | --------------------------- |
| **HF limiter (primary actuator)** | [US 4,103,243](https://patents.google.com/patent/US4103243A/en) Orban, "Controlling peak signal levels in a bandlimited ... system employing HF pre-emphasis" (Optimod-FM 8100 HF limiter) | Expired 1997 | Split path: direct + bandpassed HF (peak ~+21.6 dB near 19.5 kHz, Q 1.09) through a VCA, summed; VCA gain from dual comparators on the SUMMED output, ~3 ms attack / ~10 ms recovery. The pre-emphasis boost itself is program-controlled: `y = x + g(t) * BP(x)`. Clipper follows, then a shelving overshoot filter. Implemented as `HFLimiter` (`docs/ARCHITECTURE.md`). |
| HF limiter (sidechain) | [US 5,574,791](https://patents.google.com/patent/US5574791A/en) Orban/AKG, combined de-esser + HF enhancer | Expired 2014-06 | HF power vs loudness-weighted total power as a LOG RATIO drives HF reduction -- engage only when HF dominates the frame (a lone cymbal crash), not merely when the mix is loud. Use as the detector for the 4,103,243 actuator. |
| HF limiter (historical baseline) | [US 3,529,244](https://patents.google.com/patent/US3529244A/en) CBS Labs (Torick/Allen), FM Volumax "frequency sensitive amplitude limiting" | Expired 1987 | Program-controlled 6 dB/oct shelf between limiter and clipper. Simplest form; colours everything above the corner, so prefer 4,103,243's bandpass form. |
| HF limiter (supporting) | [US 3,621,151](https://patents.google.com/patent/US3621151) GRT, frequency-selective audio limiter | Expired 1988 | Resonant detector tuned to the saturation-prone HF region drives a frequency-selective attenuator; explicitly contrasted with clipping. |
| **Sliding-band variant (HF limiter phase 2)** | [US 3,631,365](https://patents.google.com/patent/US3631365A/en) / [Re 28,426](https://patents.google.com/patent/USRE28426E/en) Dolby, "Signal compressors and expanders" (Dolby B); [US 3,846,719](https://patents.google.com/patent/US3846719A/en) Dolby, "Noise reduction systems" | Expired 1988 / 1991 | Side path HP + variable filter whose cutoff slides UP as HF amplitude rises, so only the region above the dominant HF component is compressed -- mids/vocals untouched while 8-15 kHz is reduced. Dolby FM applied exactly this to FM. |
| Sliding-band refinements | [US 4,490,691](https://patents.google.com/patent/US4490691A/en) Dolby (spectral skewing + anti-saturation); [US 4,498,055](https://patents.google.com/patent/US4498055A/en) Dolby (modulation control); [US 4,736,433](https://patents.google.com/patent/US4736433) Dolby (action substitution, SR/S) | Expired 2001 / 2002 / 2005 | Skewing: weight the HF detector so 15 kHz shimmer does not drive more GR than the 5-10 kHz region. Anti-saturation IS dynamic pre-emphasis for a saturating medium. Modulation control: stop mid/bass energy pumping the HF band. Action substitution: `max(sliding-band GR, fixed HF-band GR)` keeps control when a cymbal sits just below the slid cutoff. |
| Dynamic / distributed pre-emphasis | [US 5,848,167](https://patents.google.com/patent/US5848167A/en) Aphex (Werrbach), distributed pre-emphasis equalizer; [US 4,112,254](https://patents.google.com/patent/US4112254A/en) dbx (Blackmer), signal compander | Lapsed 2006 / expired ~1996 | Split the 75 us curve: partial (75/50 us quotient) before the limiter, final 50 us after, so the limiter "sees 50 us" while the air curve stays 75 us; the post-limiter EQ re-grows peaks, so the composite clipper must follow. dbx: pole-zero weighting in the level-sensing path so detection tracks what overloads the channel. |
| Automatic-threshold HF band limiting | [US 4,843,626](https://patents.google.com/patent/US4843626A/en) Aphex Dominator (Werrbach), multiband limiter with ALT | Expired 2006-07 | Per-band limiters to a common reference; the summed output sets all bands' thresholds so the recombined signal fills the ceiling without pumping -- a lone hi-hat gets the full ceiling, bass + hi-hat lowers the HF threshold just enough. Keep parallel-bands + ONE final limiter (see active E3 below). |
| Clip-product monitor | [US 5,737,432](https://patents.google.com/patent/US5737432A/en) Aphex, split-band clipper | Expired 2016-11 | Watches the band NOT being clipped for the clipper's IM products and backs off clip depth. Reusable inverted: monitor 0-5 kHz for difference-frequency IM while clipping pre-emphasised HF. |
| Tonality-gated clip depth | [US 4,241,266](https://patents.google.com/patent/US4241266A/en) Orban, peak-limiting apparatus | Expired 1999 | Clip depth from waveform predictability: noise-like program (cymbals) may be clipped harder, periodic program less; less clipping when no LF masks IM. Candidate gate for clipping vs HF gain-ride routing. |
| Published (no patent needed) | Orban, "Transmission Audio Processing" ([PDF](https://static1.squarespace.com/static/58f8d954b8a79b4ccf726c3b/t/5996db51f5e231b4a279db2f/1503058769976/Broadcast+Transmission+Audio+Processing.pdf)); Orban/Foti AES 5469 (2001, [reprint](https://static1.squarespace.com/static/58f8d954b8a79b4ccf726c3b/t/5996dc63d7bdceeb0f5bc325/1503059043905/The+Truth+about+Audio+Processing+in+Radio.pdf)); Optimod 8200 manual ([archive.org](https://archive.org/download/orban_8200_Section_1/8200_Section_1.pdf)); Optimod 8100A manual 1986 ([scan](https://www.worldradiohistory.com/Archive-Catalogs/Orban/Optimod-8100A-Manual-1986.pdf)) | Prior art | "Placing a wide-band peak limiter after the pre-emphasis filter proved unsatisfactory ... cymbal crashes would cause the sound to literally collapse"; "HF limiting is usually performed partially by HF gain reduction and partially by distortion-cancelled clipping"; "simple clipping ... produces difference-frequency IM distortion which the de-emphasis in the radio then exaggerates ... particularly offensive on cymbals and sibilance"; HF limiters "sound best when operated independently (without stereo coupling)". 8200: explicit HF LIMITER (OFF..150 us) plus bands 4/5 coupled to band 3 acting as HF limiter. |

**ACTIVE -- design around, do not copy:**

| Patent | Holder | Expires | Claim gist | Our design-around |
| ------ | ------ | ------- | ---------- | ----------------- |
| [US 9,762,198](https://patents.google.com/patent/US9762198B2/en) | Dolby (Seefeldt), frequency band compression with dynamic thresholds | ~2034-04 | Per-band compressor thresholds made TIME-VARYING by a distortion-audibility (masking) model. | Keep thresholds fixed. If a masking model is ever used, let it act on the clipper's distortion RESIDUAL (how much to cancel / which band's residual to substitute -- the US 6,337,999 lineage we already run), never on thresholds. |
| [US 9,385,679](https://patents.google.com/patent/US9385679) | Maxim (Polleros), staggered-Y multiband limiter | ~2034-06 | Band limiters summed pairwise with a "summer limiter" after each summer. | Parallel band limiters + ONE final wideband limiter/clipper (Werrbach 4,843,626 topology = our current chain). No cascaded per-summer limiters. |
| [US 7,991,171](https://patents.google.com/patent/US7991171B1/en) | Wheatstone (Snow), 30+ harmonically related bands | ~2030-05 | Gains chosen jointly across fundamental + harmonic bands. | Peripheral; do not select multiband gains jointly across harmonically related bands. |

Not located / unverified (treat as trade secret): Orban MX limiter (no filing after US 6,618,486 under Orban's name); Telos/Omnia clippers (only Foti's expired composite-filter [US 4,991,212](https://patents.google.com/patent/US4991212A/en) verified); Thimeo/Stereo Tool "Advanced Clipper"; CRL and Texar HF limiters.

Recommended detector combination for further HF-limiter work (the 4,103,243 actuator is in `HFLimiter`): 5,574,791's HF/total log-ratio detector with 4,490,691's spectral-skewing weight, driving 4,103,243's `x + g*BP(x)` actuator, sliding cutoff (3,631,365 / 3,846,719) as the phase-2 option, action substitution (4,736,433) if the slid band leaves gaps; per Orban's paper run it per channel (un-linked) and A/B that against the project's stereo-link discipline with the new separation + image metrics.

## Already implemented or structurally equivalent (do not re-implement)

| Patent | Title | Where in code | Note |
| ------ | ----- | ------------- | ---- |
| [US 6,337,999](https://patents.google.com/patent/US6337999B1/en) | Oversampled differential clipper | `CompositeClipper` (commit `d1d8180`, post-0.11) | Differential topology standard; only the clipping residual is decimated. |
| [US 6,618,486](https://patents.google.com/patent/US6618486B2/en) | BS.412 dual-integrator MPX power controller | `DSP/BS412Power.swift` | Same purpose, different control: a flat rolling 60 s window over the complete multiplex (harder and more compliance-predictable than a leaky integrator), a feed-forward `BS412Rider` and a `BS412ComplianceGuard` energy invariant instead of a feedback ride. Lapsed 2015-09-09. |
| [US 5,913,152](https://patents.google.com/patent/US5913152A/en) | FM composite processor with pilot extract/re-sum | Different architecture, same end-state | Pilot protected by (1) post-clipper subcarrier injection (project invariant) + (2) RBJ-BPF cancellation in the 17-21 kHz guard inside `CompositeClipper`. Extract/re-sum on top would be redundant. Expired 2015-12-29. |
| [US 4,737,725](https://patents.google.com/patent/US4737725A/en) | Pre-LPF overshoot compensation (Inovonics) | `OversampledPeakLimiter` (4x OS) | The analog clip->phase-lag->re-clip->recover technique is what modern oversampled true-peak limiters do digitally. Expired 1996-04-17. |
| [US 5,737,434](https://patents.google.com/patent/US5737434A/en) | Multi-band compressor with cross-band coupling | `MonoCompressor` per-band logic | Inter-band coupling landed opt-in 0.28 (`multiband_inter_band_coupling_enabled`, `--verify-multiband-coupling`). Listening validation pending. Expired. |
| [US 5,579,404](https://patents.google.com/patent/US5579404A/en) / [EP 0685130 B1](https://patents.google.com/patent/EP0685130B1/en) | Digital audio limiter -- subband-aware look-ahead | `StereoLinkedOversampledPeakLimiter` (pre-encode L/R) | Both phases default-on in 0.30 (textbook delay+detector look-ahead, US 4,208,548 prior art, 1 ms; Dolby split-band 4 kHz HF detector). Dolby; US expired ~2013-11, EP ~2014-02. |

## Bass enhancement (PrimeBass) -- patent map

The design-around record for PrimeBass. The generator was rebuilt in 2026-10
(CHANGELOG, Unreleased): an LR4 band-pass -> envelope-normalised asymmetric
device (`2 x^2` plus a tanh odd device with its linear term removed) -> LR4
band-pass F0..5 F0 -> envelope -> peak guard; `--verify-primebass` is the
gate. The earlier "even" generator `x * |x|` was odd-symmetric and produced
no even harmonic; do not reintroduce it. The Werrbach transient burst and the
Big Bottom law (on the harmonic layer via `density`) still apply.

| Patent | Title | Where in code | Note |
| ------ | ----- | ------------- | ---- |
| [US 5,930,373](https://patents.google.com/patent/US5930373A/en) | Waves MaxxBass -- equal-loudness-weighted harmonic synthesis | `processPrimeBass` + `configurePrimeBassFilters` | Even (asymmetric `2 x^2`) + odd (tanh) generators with weights for the 2..5xF0 harmonics; perceived bass shifts onto harmonics, buying downstream headroom. |
| [US 4,150,253](https://patents.google.com/patent/US4150253A/en) | Aphex Aural Exciter -- HP-then-clip | `processPrimeBass` | Adapted as a band-pass ahead of the waveshaper (the earlier allpass variant was removed in 2026-10). |
| [US 5,424,488](https://patents.google.com/patent/US5424488A/en) | Werrbach transient-discriminate harmonics (Aphex) | `processPrimeBass` Phase 2 | Dual-envelope transient detector (fast - slow, normalised) modulates harmonic-band gain on onsets (`primeBassTransientFloor` / `primeBassTransientPeak`). |
| [US 5,359,665](https://patents.google.com/patent/US5359665A/en) | Werrbach Big Bottom -- dynamic bass extension (Aphex) | `processPrimeBass` Phase 3 (0.23) | LF-envelope follower drives the harmonic level -- "envelope duration extension", now through `density`. |

## Codec conditioning prior art (survey 2026-09-05, for the digital delivery target)

Checked before proposing any "prepare for lossy" feature. Conclusion: the
core idea is free, the neighbouring codec-internal work is not, and the
level-and-bandwidth part was never patentable in the first place.

| What | Reference | Status | Verdict |
| --- | --- | --- | --- |
| Simulate the target codec, compare against the delayed original, pre-condition the input so the predicted artifacts shrink | [WO 2007/098258](https://patents.google.com/patent/WO2007098258A1/en) / US 2007/0239295 (Neural Audio Corp, priority 2006-02-24) | **Never granted**: PCT ceased, US application abandoned | FREE to implement. This is also the published description of what "codec conditioning" means, and it doubles as our measurement method |
| Complementary spectral shaping around a lossy encoder (the "prepare for lossy" idea) | FM pre-emphasis (1930s), Dolby A / B companding (1960s) | Long expired | FREE, but note we control only the encoder INPUT: any half of a complementary pair that would have to run after the codec is not available to us |
| True-peak headroom before the encoder, lower clipper drive on the digital path, band-limiting to the codec's rate | EBU R128, AES TD1008, ITU-R BS.1770 | Standards, not patents | FREE. Parameter choices, not patentable subject matter |
| Transient / pre-echo handling INSIDE the codec (encoder-decoder pairs, side information, post-processors) | [US 10,720,170](https://patents.google.com/patent/US10720170B2/en) and US 11,094,331 (Fraunhofer), [US 2011/0178617](https://patents.google.com/patent/US20110178617) and US 2015/0170668 (Orange) | ACTIVE | DESIGN AROUND: we process the encoder's input only and signal nothing to the decoder. Do not add anything that requires decoder cooperation |
| Orban "PreCode" | Trademark; the published description is deliberately vague ("energy and spectrum aware band detection"), and Orban holds granted patents | Assume protected | Do not reimplement from their marketing copy, and never use the name. Build from the Neural Audio disclosure and our own measurements |

**How this would be gated.** The Neural Audio disclosure describes the same
loop we would need as a TEST: encode a rendered scenario through the target
codec, decode it, time-align against the original, and score the difference.
That gate has to exist and show a real improvement before any conditioning
knob ships -- exactly the rule the rest of this file applies to DSP claims.
Ordering: build the measurement first, and only then decide whether
conditioning earns its place.

## Skipped -- active patents or non-additive (design-around noted)

| Patent | Status | Reason |
| ------ | ------ | ------ |
| [US 9,712,916](https://patents.google.com/patent/US9712916B2/en) DTS "Bass Enhancement System" | **ACTIVE** to ~2032-12-19 | Headroom-coupled adaptive gain on MaxxBass. Design-around: fixed/program-dependent gain not driven by instantaneous headroom. |
| [US 9,319,789](https://patents.google.com/patent/US9319789B1/en) Music Tribe "Bass Substitution Filter" | **ACTIVE (reinstated)** to ~2032-02-11 | Level-tracking centre-frequency modulation of the harmonic filter. Design-around: fixed centre frequency, amplitude-only modulation. |
| [US 4,482,866](https://patents.google.com/patent/US4482866A/en) BBE Sonic Maximizer | Expired 2002-02-26 | Frequency-dependent group-delay correction -- actively harmful in FM (breaks pilot/subcarrier coherence). |
| [US 4,748,669](https://patents.google.com/patent/US4748669A/en) SRS / Hughes | Expired | Stereo enhancement via L-R, not bass. Misclassified in earlier surveys. |

## Skipped -- evaluated and rejected

| Patent | Title | Status | Reason |
| ------ | ----- | ------ | ------ |
| [US 7,295,628](https://patents.google.com/patent/US7295628B2/en) | DSP MPX with sample-frequency-aligned vestigial sideband | Expired 2024-07-30 | Requires `fs = 2 x fmod` (76 kHz chain). Our chain runs 192 kHz throughout; adopting means a full chain-rate refactor. Niche AM/SSB technique; FM's DSB-SC is what receivers expect / IEC 62106 mandates. |
| [WO 2017/186756](https://patents.google.com/patent/WO2017186756A1/en) | Frequency-domain L+R/L-R protector | PCT ceased; **CA3021918 possibly enforceable to 2037** | Legal: verify before any CA distribution. Technical: per-block FFT of M and S is CPU-expensive + adds OLA latency; M/S-domain dynamic L-R limiter achieves similar mono-compat without FFTs. |
| [US 4,412,100](https://patents.google.com/patent/US4412100A/en) | Multiband signal processor (Orban) | Expired 2001-09-21 | 1981 distributed-crossover multiband+clippers -- structurally the prior art for what we already ship (FIR multiband + per-band `MonoCompressor` + differential composite clipper), at a less modern level. Nothing to adopt. |
| [US 7,587,254](https://patents.google.com/patent/US7587254B2/en) | DR processor with auxiliary decorrelation in L+R limiter sidechain | ~2029 | Filed 2004; not yet expired. Revisit post-2029. |

## Settled findings

**Pre-emphasis placement.** Ships in L/R immediately upstream of the pre-encode limiter (`preL`/`preR` in `processSampleDetailed`; canonical Optimod/Stereotool). The b806053 cost regression that reverted this in 0.10 is no longer reproducible post-0.24 (vvtanhf / vDSP_dotpr / FIR multiband / differential clipper cut chain cost ~95% -> ~28% RT, absorbing the ~7% relative increase). Do not relocate to M/S.

**MPXDecoder has no pre-demod pilot/RDS notch (do not re-add).** The decoder used to notch the 19 kHz pilot and 57 kHz RDS on the common signal before the M/S split; the notch skirts asymmetrically attenuated the S-channel DSB-SC sidebands (38 +/- f), the dominant HF stereo-separation limiter (14 kHz capped ~44 dB). Removed on develop/v.037 -> 97 dB at 14 kHz. Pilot/RDS are handled by the 15.5 kHz M-path lowpass + S-path `diffLP` + the post-recombination `pilotNotchL/R`. The decoder only sees the app's own clean composite (monitor path + `--verify-receiver`), so there is no off-air noise the notches protected against. If `MPXPrimeMeter` later decodes noisy off-air composite, add input conditioning *there*, not back in the shared decoder.

**Composite-clipper guard cancellation depth (measured, not a defect).** v.036 measured the clipper's guard cancellation in isolation (upstream nonlinearities off, clipper driven hard): pilot guard ~11.8 dB, RDS guard ~12.7 dB, residual IM ~-50 dBFS in both -- clean in absolute terms. Aligning the decimator group delay to an exact integer host-sample count (removing the ~2 OS-sample bypass/residual offset) was implemented and measured: **no change** to depth or residual, at ~10% more clipper taps -> reverted. The misalignment noted in `LinearPhaseFIRDecimator.groupDelayHostSamples` is confirmed negligible. If depth ever needs to go deeper, the binding constraint is the guard bandpass Q / delta-substitution match, not decimator alignment.

## Design constraints

- Real-time callbacks stay lock-free / allocation-free. Cross-thread audio-thread comms use `OSAllocatedUnfairLock` (priority-inheriting) or an atomic -- never `NSLock`.
- No shell/file/network work in DSP paths.
- Preserve integrated RDS + monitoring workflow; keep monitor-output latency separate from transmit-path quality.
- Subcarriers (19 kHz pilot, 57 kHz RDS) injected after all peak-control stages; pre-emphasis in L/R before the pre-encode limiter. (Full invariants in CLAUDE.md.)

## References

- [US 4,460,871 -- Variable-frequency-shift demodulator (Orban)](https://patents.google.com/patent/US4460871A/en) | [US 5,168,526 -- Distortion-cancellation circuit (Orban)](https://patents.google.com/patent/US5168526A/en)
- [Stereotool -- Limiting and Clipping](https://www.thimeo.com/documentation/limiting_and_clipping.html) | [Telos RDS guidance](https://docs.telosalliance.com/docs/rds)
- Anti-aliasing background: Valimaki "Discrete-Time Modelling..." (1995), Brandt "Hard Sync without Aliasing" (2001), Stilson/Smith "Alias-Free Digital Synthesis..." (1996).
- Open-source peer set: `mpxgen` (no processing), `PiFmRds` (Pi-only), Stereotool free (closed-source); Liquidsoap is the common amateur-station backbone / future JACK target.
