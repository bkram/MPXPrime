# Advanced Dynamics -- correctness review (2026-10-10)

Asked: audit the single-stage leveler and fix what is wrong. Line numbers
refer to `macOS/Sources/MPXPrime/DSP/Dynamics.swift` and
`macOS/Sources/MPXPrime/MPXGenerator.swift` at `1ffbf10`.

## What it does

`AdvancedDynamicsLeveler` (Dynamics 570-874) owns a
`LinearPhaseMultibandSplitter5` configured like the classic multiband path
(same crossover clamps, 40 dB stop-band, same group delay; sum-to-flat is
pinned at -156 dB). It replaces the AGC (MPXGenerator 3665) and
`processMultibandStereo` (3703-3712); the per-band Expander and the five
`BandLimiter`s live inside the replaced path and vanish with it, so leveled
band peaks go straight to the HF limiter, the pre-encode limiter and the
composite clipper. Per band: feed-forward linked RMS detector (10 / 90 ms)
blended with 18 % instantaneous |x| (58 % under transient hold), 5 / 60 ms
envelope, dB domain; one gain per band for L and R (image exact); per-sample
gain interpolation (no zipper). Gain law: `desired = clamp(target_i +
couplingBias - level, -24, +maxLift)`, gate at `target - maxGain - 10 dB`,
hold window +/- 1.9 dB at density 0.5, reduce coefficient lerped in the
COEFFICIENT domain between 30 ms and 30 us by `accel^2`, release 0.8 s
(0.2 s far from target) slowed toward 2.0 / 0.5 s by "program density".
Coupling: the bass band's cut lowers the upper bands' targets by
0 / 10 / 15 / 22 / 25 %; nothing else. Tonal offsets are target offsets
(correct and intended). The decay guard cannot latch; the transient hold is
per band and time-based.

## Measured (hikari, 192 kHz, `--verify-advanced-dynamics --seconds 4`: OK)

| Scenario | RMSd | Lowd | Midd | Highd | Peakd |
| -------- | ---- | ---- | ---- | ----- | ----- |
| level_jump | +4.72 | +5.89 | +3.91 | +3.91 | -0.11 |
| bass_dense | +0.90 | -0.67 | +2.79 | +6.78 | +0.14 |
| quiet_ballad | +0.43 | +0.13 | +0.53 | +0.76 | +0.47 |
| hf_transients | +3.88 | +5.42 | +4.85 | -1.43 | +0.05 |
| crossover_skirt | +4.12 | +3.08 | +4.12 | +4.11 | +2.21 |
| solo_bell_decay | +0.66 | -0.14 | +0.52 | +3.39 | +1.69 |

`--verify-hf-transients` (ride SINAD / hat SINAD, dB): music_loud 38.0 /
18.0, with Advanced Dynamics 29.1 / 13.9; music_clean 41.6 / 25.5 vs 35.8 /
18.6; classical_wide 41.8 / 25.7 vs 36.7 / 21.6. The ride-cymbal cost
(about -9 dB) is larger than the hat cost the roadmap tracks and was not
recorded there. No real-music A/B: `MPXPRIME_MUSIC_DIR` is unset on hikari.

## Findings, by audible impact

1. **The HF cost has three stacked causes and no gate separates them.**
   (a) The per-band limiters are gone with the replaced path, so band-5
   peaks reach the clippers raw. (b) The stage runs 3.9 dB RMS and 5 dB
   low/mid hotter on the hat scenario, so the clippers make more IM around
   the hat partials ("drive 4" recovering 2 dB fits this). (c) No upward
   coupling: band 5 ducks alone on every burst. No gate measures the
   leveler's OWN output distortion, so smoother cost and chain cost cannot
   be told apart today. High confidence on the facts, medium on weighting.
2. **Defect: the attack law reaches sub-cycle time constants.** The
   coefficient-domain lerp at 843 is wildly non-linear in time: accel 0.1
   gives 3.6 ms, 0.2 gives 1.0 ms, 0.5 gives 0.15 ms, 1.0 gives 30 us (half
   the remaining error per sample). Any jump more than about 14 dB past the
   window slews every band, the 60 Hz band included, within one cycle:
   modulation splatter. Giannoulis, Massberg and Reiss (JAES 2012) use
   log-domain smoothing with millisecond-range constants. The gate measures
   RMS, not distortion, so it cannot see this. High confidence.
3. **Design gap: band coupling is bass-down only.** Orban couples every
   adjacent pair (default 30 %), Thimeo couples by octave distance,
   Wheatstone holds a target spectral mix, Omnia's limiters adapt to the
   AGC. The crossover-skirt double lift (+10 / +8 dB on one tone) and the
   lone band-5 duck are the direct consequence. Roadmap B3 / Step 7 already
   names it. High confidence.
4. **Design gap: "density" works backwards.** `programDensity` is the
   fast/slow envelope DIVERGENCE in dB (750-751), which the AGC's own
   comment calls "busy". Dense, already-compressed program yields about
   0 dB and gets the FASTEST release; sparse dynamic program gets the slow
   one. The settings reference promises the opposite. Idempotency passes
   only because of the hold window. Medium-high confidence.
5. Detector window vs band 1: 10 ms RMS plus a permanent 18 %
   instantaneous term on a 60 Hz band leaves about +/-0.5 dB ripple at
   120 Hz in the level; harmless inside the window, 2f gain modulation
   (3rd harmonic on a kick) in the reduce branch with the fast coefficient.
   `MonoCompressor` weights the opposite way; one of the two is inverted.
6. Live reconfiguration: a live crossover change or an engine toggle calls
   `configureStructure`, which calls `reset()` (666, 723-730): every band
   gain snaps to unity and the splitter flushes, an audible step on air.
   RT safety is otherwise fine (no allocation in `process`, envelopes
   denormal-zapped, no NaN guard).
7. Correct: band split, group delay, rate, stereo linkage, per-sample gain
   interpolation, target offsets, decay guard, transient hold.

## Fix plan, ranked

| Change | Where | Verify | Effort |
| ------ | ----- | ------ | ------ |
| Band sync: clamp each band's gain within D dB of its neighbours (distance-weighted) or of a master band | after Dynamics 860 | crossover_skirt bands 3/4 <= +4 dB; hf-transients AD hat SINAD | M |
| Per-band attack floor (>= 2 band periods: about 33 / 9 / 2.6 / 0.6 / 0.3 ms) and blend in the TIME domain, not the coefficient domain | 843 | level_jump, bass_dense p95 slew, new leveler-only distortion test | S |
| Reinstate `BandLimiter` per band before the sum (bands are already split; roadmap B4) | 770 | hf-transients AD hat SINAD / crest | M |
| Fix density semantics (invert 856-857, or derive from crest / spectral flatness) | 856 | idempotency, bass_dense RMS parity, new direction test | S |
| Keep band gains across `configureStructure`; reset only the splitter | 723-730 | live-change continuity test | S |
| Band-scaled RMS windows; drop the 18 % rest-state instantaneous term | 783-816 | kick 3rd-harmonic test | S |

Tests that pin the invariants: `levelerAloneHatSINAD` (the missing gate
that separates smoother cost from chain cost), `attackNeverFasterThanBandPeriod`,
`bandDisparityIsBounded`, `denseProgramReleasesSlowerThanSparse` (fails
today), `stereoGainIsLinked`, `slowFadeLiftIsBounded`,
`crossoverLiveChangeIsContinuous` (fails today), `nanInputRecovers`.

## Fix landed (2026-10-10)

In `AdvancedDynamicsLeveler` (Dynamics.swift), pinned by eleven new tests in
`AdvancedDynamicsReviewTests`; 874 tests pass; both gates print OK; AD is
off in every baseline, so none moved.

- Attack law in the TIME domain: `tau = lerp(base, fast_i, accel^2)` in
  seconds with `fast_i` floored at two band periods (33 / 22 / 5.7 / 1.1 /
  0.29 ms at the default crossovers). A +20 dB step on a 60 Hz tone now
  slews band 1 at most 1 dB/ms. The leveler alone on the hat multitone
  reads 90 dB SINAD: the leveler itself is not the hat cost.
- Density: dense programme (low fast/slow divergence) releases up to 2.5x
  SLOWER, sparse programme at full speed, as the manual always said.
- Band coupling: each band is bounded to within 6 dB of its ACTIVE
  neighbours; a band below its gate constrains nobody (it still gets pulled
  toward its neighbours and drifts to unity). Measured variants: with empty
  bands as references the skirt lift drops to +4 / +4 dB and hats gain up to
  +3.9 dB on classical, but a quiet ballad with empty bass and top bands
  levels 4 dB LESS than the classic chain, a loudness-consistency regression
  on air; the kept variant keeps the ballad within +0.8 dB, costs nothing on
  hats and leaves the skirt lift at +10 / +8 dB (both skirt bands are
  active, so only they bound each other). The hat-optimal variant is a
  one-line flip (`bandSyncGatedBandsAreReferences = true`, cut bound 10 dB)
  if skirt lift and hat SINAD ever outrank leveling range on sparse spectra.
- Five `BandLimiter`s (-3 dB, 0.5 / 50 ms) run on the bands before the sum,
  so leveled band peaks no longer reach the clippers raw.
- `configureStructure` keeps gains, envelopes and limiter state across a
  live crossover change (splitter rebuilt only when rate or a crossover
  changed); the step across a live x3 change is below 1 dB.
- Detector windows scale with the band (at least two periods); the 18 %
  rest-state instantaneous term is gone; NaN / Inf input recovers.
  `MonoCompressor`'s opposite weighting is untouched: nothing says which of
  the two was intended, and every baseline is armed on the classic chain.

Still open: the hat cost of Advanced Dynamics versus AGC + Multiband (about
-3 dB on music_loud) and the ride cost (-6 dB), so the default flip stays
blocked; the real-music A/B could not run (no `MPXPRIME_MUSIC_DIR` on hikari).

## Sources

- Giannoulis, Massberg, Reiss, "Digital Dynamic Range Compressor Design --
  A Tutorial and Analysis", JAES 2012: <https://aes2.org/publications/elibrary-page/?id=16354>
- Giannoulis, Massberg, Reiss, parameter automation, JAES 2013:
  <https://aes2.org/publications/elibrary-page/?id=16965>
- Thimeo Natural Dynamics: <https://www.thimeo.com/documentation/natural-dynamics.html>
- Thimeo multiband compressor: <https://www.thimeo.com/documentation/multiband-compressor.html>
- Orban 8600 in depth: <https://www.orban.com/indepth-optimodfm8600>
- Orban 8100A manual (full coupling "preserves frequency balances"):
  <https://worldradiohistory.com/Archive-Catalogs/Orban/Optimod-8100A-Manual-1986.pdf>
- Wheatstone, Understanding the Vorsis SST:
  <https://www.wheatstone.com/joomlatools-files/docman-files/downloadables/AN2008-01A%20Understanding%20the%20Vorsis%20SST.pdf>
- Telos, Omnia.11 v3.0 G-Force: <https://telosalliance.com/news/Omnia11-v30-Enables-Exciting-New-Processing-Features>
