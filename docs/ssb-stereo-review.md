# SSB Stereo Encoder -- correctness review (2026-10-10)

Asked: audit the SSB-leaning stereo encoder and fix it. Modelled on Stereo
Tool's SSB stereo option. Line numbers refer to
`Sources/MPXPrime/DSP/SSBStereoEncoder.swift`,
`MPXGenerator.swift` and `Verification/StageABGates.swift` at `1ffbf10`.

## What it does

A 511-tap type-III Kaiser Hilbert FIR (80-86) makes the quadrature L-R;
base and diff ride a 255-sample ring (103; 1.33 ms at 192 kHz) equal to the
FIR group delay. Per sample `quad = amount * H{diff} * cos(2 theta)`, two
candidates `base + dsb -/+ quad` (180-181), a 5 ms leaky peak per candidate,
3 % hysteresis, a 5 ms crossfade of the selection, output `dsb - sel * quad`
(191). Assembly is inside `processFinalComposite` (MPXGenerator 3954-3962),
BEFORE the composite clipper, the 55 kHz FIR and the final limiter; the
38 kHz sine and cosine come from the pilot recurrence at the current step,
so pilot and RDS phase need no compensation. Gated off outside MPX mode.

## Measured (hikari, `--verify-ssb-stereo --seconds 5`)

Composite-peak reclaim at amount 0.7 and 1.0: **0.00 dB** on all four
scenarios (the gate exits 1, "TIGHT", by design when reclaim < 0.05 dB).

| Tone | Asym off | Asym on 0.7 | Asym on 1.0 | Sep off | Sep on 0.7 | Sep on 1.0 |
| ---- | -------- | ----------- | ----------- | ------- | ---------- | ---------- |
| 1 kHz | 0.00 | 15.04 | 66.46 | 95.8 | 94.9 | 93.9 |
| 10 kHz | 0.10 | 15.53 | 35.32 | 41.2 | 39.1 | 37.4 |
| 14 kHz | 0.09 | 20.20 | 20.86 | 25.5 | 24.7 | 24.2 |

`--verify-receiver` PLL separation off / 0.7 / 1.0: 1 kHz 64.4 / 64.2 /
64.1; 10 kHz 40.5 / 38.7 / 37.1; 14 kHz 25.2 / 24.5 / 24.1. Mono rejection
117.6 dB unchanged. Pilot / RDS lock drift at most 0.13 degrees. The
encoder-side sideband table at amount 1.0 keeps the LOWER sideband for a
1 kHz L drive and the UPPER one at 10 and 14 kHz: the kept sideband
wanders with program. With the composite clipper off, asymmetry at 10 and
14 kHz rises by 78 dB: clipping regenerates the suppressed sideband.

## Findings, by impact

1. **Design error: the selector compares two signals with identical
   envelopes.** `base + d sin - q cos` and `base + d sin + q cos` are
   time-mirror images with envelope `|base| +/- sqrt(d^2 + q^2)`; over any
   5 ms window both peak identically, so the trackers chase sample-grid
   noise and the choice is effectively random. Stereo Tool's opportunistic
   mode switches between DSB and SSB ("DSB and SSB have peaks at different
   locations"), never between the two SSB sidebands. Consequence: zero
   headroom reclaim, measured. The CHANGELOG (1806-1825) already records
   the null result; the manual's "81+ dB" separation claim is stale (gate:
   24-95 dB, the same as DSB). High confidence.
2. **The kept sideband is not fixed, so the one real SSB benefit is lost.**
   Orban 8600, Omnia and Stereo Tool "Standard" keep the LOWER sideband
   (23-38 kHz, DSB below about 150 Hz): RF occupancy shrinks and 38-53 kHz
   is freed, which is the multipath and RDS-protection argument. Here the
   kept side flips with program; half the time the full-amplitude sideband
   sits at 38-53 kHz, riding the 53 kHz clipper guard and FIR edge, and
   every flip moves 30 kHz of spectrum through a 5 ms crossfade. High.
3. **Coverage gap: no decoder phase error in the receiver model.** Both
   decoders are product detectors with an exact 38 kHz reference. Consumer
   PLL / switching decoders have a few degrees of error phi: DSB crosstalk
   goes as (1 - cos phi), SSB crosstalk as sin phi, so at 5 degrees 54 dB
   becomes 27 dB, at 10 degrees 42 becomes 21, at 20 degrees 30 becomes 15.
   With the wandering selection that crosstalk flips polarity on every
   switch (image wobble). This is the published objection to SSB stereo
   and why Stereo Tool marks its pure-Hilbert mode "testing only". Not
   measured anywhere. High.
4. **The loudness claim is null and the gate cannot flag a regression**
   because it is TIGHT by design. Orban documents that SSB ADDS overshoot
   for L/R correlated at 90 degrees; the clipper then works harder and
   regenerates the other sideband. No scenario exercises phase-offset L/R.
5. Correct: the formulation `d sin -/+ H{d} cos` gives sideband gains
   (1 +/- a) / 2 summing to 1, Orban's compatibility condition; delay match
   is exact (66 dB null at 1 kHz); pilot, RDS and both carrier phases are
   current-step from one oscillator; mono passes through a pure delay; the
   stereo guard restores the whole 22-53 kHz residual, band-agnostic.
   Low-frequency roll-off of the Hilbert (about 750 Hz) degrades
   gracefully to DSB with gains still summing to 1. BS.412 sees the +3 dB
   subchannel power, so BS.412 markets lose loudness with it on.
6. RT: `process()` is allocation-free; the FIR allocates on the live-apply
   toggle (accepted pattern); the peak trackers decay toward denormal in
   silence (harmless under FTZ); latency +1.33 ms before the clipper.

## Fix plan, ranked

1. **Keep the lower sideband, always** (`sel = -1`, confirm the sign with
   the encoder-side sideband table of `--verify-receiver`: 38 - f must be
   the full one). Removes findings 1 and 2; drops the second candidate and
   its CPU. Hours.
2. **Phase-error sweep in the gate**: `decodeMPXWithReference(pilotPhase:
   fit +/- 5, 10 degrees)` exists (ReceiverModel 125-149); report
   separation on / off per angle and fail if SSB-on separation at
   10 degrees is below 20 dB. Half a day.
3. If loudness is wanted, switch between DSB and SSB (not between
   sidebands) inside or alongside the clipper, with a 90-degree-offset L/R
   scenario and a clipper-GR metric. Days.
4. Docs: drop "81+ dB", state that no composite-peak benefit is measured,
   describe the real benefit (narrower RF spectrum) and the receiver
   phase-error cost. An hour.
5. `zapDenorm` on the peak trackers.

Tests to pin the invariants: `ssbKeepsLowerSidebandAtEveryFrequency`
(1 / 5 / 10 / 14 kHz, L and R drive, 38 + f at least 40 dB below 38 - f),
`ssbSidebandGainsSumToUnity`, `ssbSeparationUnderDecoderPhaseError`,
`ssbSelectionDoesNotSwitch`, `ssbCompositePeakNeverExceedsDSBByMoreThan`
(90-degree L/R, at most +1 dB), and raise `fullSSBSuppressesOneSideband`
from 15 dB to 40 dB (the Hilbert delivers 66).

## Recommendation

Keep it opt-in and relabel it honestly: a lower-sideband SSB / VSB
experiment for multipath, with no loudness claim. Its 5-8 % CPU currently
buys nothing. Remove it if nobody will field-test it on real receivers.

## Sources

- Orban 8600 manual, SSB / VSB: <https://www.manualslib.com/manual/1267434/Orban-Optimod-Fm-8600.html?page=191>
- Orban 5500 SSB note (+3 dB subchannel power): <https://www.radioworld.com/tech-and-gear/optimodfm-5500-supports-ssb>
- Thimeo FM signal settings (SSB modes, L-R asymmetry): <https://www.thimeo.com/documentation/fm_signal_settings.html>
- Thimeo limiting and clipping: <https://www.thimeo.com/documentation/limiting_and_clipping.html>
- Stereo Tool forum: <https://forums.stereotool.com/viewtopic.php?t=4124>, <https://forums.stereotool.com/viewtopic.php?t=4988>
- Radio World: <https://www.radioworld.com/news-and-business/fm-ssbsc-faces-questions>, <https://www.radioworld.com/news-and-business/ssbsc-a-winwin-for-fm-radio>
