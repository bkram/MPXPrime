# HF Limiter -- correctness review (2026-10-10)

Asked: is the HF Limiter proper, do we still need it, and does it need a fix.
Line numbers refer to `Sources/MPXPrime/DSP/AudioClippers.swift` and
`Sources/MPXPrime/MPXGenerator.swift` at `1ffbf10`.

## What it is and why the chain needs it

FM pre-emphasis (50 or 75 us) lifts the top octaves by up to about 17 dB.
Something has to catch the cymbals and hi-hats that overshoot after that
lift, or they clip in the broadband limiter, which ducks the whole mix on
every bright transient. Every FM processor has a stage for this; ours is the
Orban program-controlled pre-emphasis topology (US 4,103,243): the gain
element sits only in the boost path, `out = flat + g * boost`, so it can
never cut treble below the flat program level. `HFLimiter` (AudioClippers
333-397) runs after `preL/preR` and before the pre-encode limiter
(MPXGenerator 3588-3593), zero latency, 1.5 ms attack, 5 ms hold, 20 ms
release, one stereo-linked gain from `max(|L|, |R|)`. It is on in every
Format Profile and gated by `--verify-hf-transients`. Keep it.

## Verified correct

- Gain law: `target = max(minGain, 1 - excess / boostAbs)` with `minGain =
  10^(-maxReduction/20)`; g stays in [minGain, 1]. A 3 kHz and a 10 kHz tone
  overshooting by 0.8 and 0.3 dB both land on the threshold within 0.01 dB
  (simulated against the real pre-emphasis biquad).
- De-emphasis mapping: after the receiver's de-emphasis the action is a
  smooth program-controlled shelf (-1.1 dB at g = 0.87, -8.3 dB at 10 kHz at
  the 12 dB floor), which is exactly what Orban's "program-controlled
  filter" is. The boost's phase term is not an artefact.
- Release: the 5 ms hold refreshes on every crest of a sustained tone, so a
  steady 10 kHz tone has no gain ripple and no sidebands. Stereo link holds
  the image (pinned by `stereoLinkKeepsChannelRatio`). No denormal or NaN
  path; live-apply keeps the gain state; clamps agree across the three
  configure sites.
- Overlap with the encoder HF guard (flat domain, 4/80 ms, <= 2 dB) and the
  pre-encode limiter's HF-only lookahead (detector only) is staggered, not a
  fight; the 2026-08-29 measurement stands.

## Findings

1. **Defect: the bass-immunity gate tests the wrong quantity.** The comment
   at 326 says the stage engages only when "the boost accounts for at least
   half the excess"; the code at 349 and 384 engages when `boostAbs > 0.2 *
   peak`. Simulated: a 60 Hz kick at 0.95 with a 10 kHz hat 20 dB down gives
   an emphasised hat of about 0.3, the gate passes, `excess / boostAbs` is
   above 1 and the gain floors at -12 dB on every kick crest; at 60 Hz the
   release never completes between crests. Removing all of the boost cannot
   bring 1.25 down to 0.794, so the stage spends its whole range for nothing
   while the pre-encode limiter still does the job. Audible as a periodic HF
   duck at the beat rate on loud program with hats, and on "Music -- Loud"
   (+8 dB drive) as a top octave held near the floor much of the time. The
   same law, when the boost has the opposite sign to the peak, raises the
   peak to `threshold + 2 * excess` (rare). High confidence on the
   mechanism; the upstream bass clipper and band limiter soften the severity.
2. **Design gap: the threshold sits 0.6-1.1 dB below the broadband
   limiter's.** HF limiter -2 dB (0.794) against pre-encode thresholds of
   0.85 / 0.88 / 0.90 per profile. US 4,103,243 puts the HF comparators
   0.5 dB ABOVE the limiter threshold, and runs the broadband limiter first,
   so the HF stage only ever sees HF excess. Here both are inverted: the HF
   limiter engages first on every peak above 0.794, and with finding 1 it
   becomes a general HF compressor.
3. **Coverage gap: the gate cannot see either.** `--verify-hf-transients`
   has no tonal-balance metric (decoded 6-15 kHz level versus input) and no
   gain-trajectory ripple metric, and its +/-250 Hz "wanted" mask hides the
   40-200 Hz ripple a cymbal wash produces as the hold expires.
4. Design notes, not defects: the detector is a sample peak with a crude
   fraction gate, not the HF-to-total log-ratio detector the roadmap names
   (US 5,574,791); there is no lookahead, so the first 1.5 ms of a hat leaks
   to the pre-encode limiter (within Orban's "attack >= 1.5x the broadband
   attack" rule); Orban prefers UN-linked HF limiters, which is the open
   `hf_limiter_stereo_link` A/B.

## Fix plan

| Change | Where | Effect | Verify | Effort |
| ------ | ----- | ------ | ------ | ------ |
| Gate on the signed boost projection against the EXCESS (`boostProj >= k * excess`, k about 0.5), cap the removal at the excess, never raise a peak | AudioClippers 384-385 | No HF duck on bass-driven peaks | new tests; HatSINAD must not drop | S |
| Default threshold +0.5 dB above `preEncodeThreshold` (or derive it per profile) | AppConfig 434, PresetCatalog | The stage acts only on HF excess | HF-loss column | S |
| Add decoded HF-level-loss and gain-ripple columns, with a per-profile bound | HFTransientGate.swift | Makes 1, 2 and 3 measurable | gate rows | M |
| Optional 1.5 ms lookahead with latency accounting | HFLimiter | The stage owns its transients | HatCrest, pre-encode GR | M |
| Log-ratio detector | HFLimiter | HF-dominance engage | same | L |

Tests to pin the invariants: `bassDrivenPeakWithModerateHatIsIgnored`,
`reductionNeverExceedsTheExcess`, `oppositeSignBoostNeverRaisesThePeak`,
`neverBelowFlatAfterDeemphasis`, `steadyToneHasNoGainRipple`,
`cymbalWashRippleDepth`, `stereoBalanceAfterDeemphasis`.

## Fix landed (2026-10-10)

`HFLimiter` (AudioClippers.swift) now has a PROGRAMME gate instead of a
per-sample fraction: two 15 ms peak-hold envelopes (pre-emphasised peak and
boost magnitude) open the stage only when the boost covers the excess over
the threshold ("only start a ride you can finish"). The per-sample rule the
review proposed (`boostProj >= 0.5 * excess`) was tried and still engaged on
the review's own kick-plus-hat scenario: the boost there is 0.28 against an
excess of 0.47, more than half, and any per-sample rule engages on the
kick's flanks where the hat alone crosses the threshold for a moment. Once
open, the gain law uses the signed projection, lands exactly on the
threshold, never removes more than the excess and never touches an
opposite-signed boost. Thresholds sit 0.5 dB above each profile's pre-encode
threshold; `hf_limiter_top_threshold_db` (default 1 dB tighter) covers the
band above 13 kHz through a detector-side slide (an in-path IIR split
cannot feed a projection detector: an LR4 highpass is inverted at its
corner). Eighteen tests pin it; the gate gained HFLoss (the stage's own
cost: 0.3-0.7 dB on the shipped profiles), GRipple (0.00-0.01 dB) and an
average-GR column plus a sustained-wash scenario. All four macOS baselines
were recaptured; the deltas are 0.1-0.2 dB of side energy kept in the
hard-panned HF scenario and 0.1 dB of peak work moved to the pre-encode
limiter and the safety stage; one figure moved the wrong way and is worth
watching: the long gate's vocal-sibilant true-peak overshoot, 0.31 to
0.50 dB, still inside its bound. The HF Clipper was removed in the same
change.

## Sources

- US 4,103,243: <https://patents.google.com/patent/US4103243A/en>
- US 5,574,791: <https://patents.google.com/patent/US5574791A/en>
- Orban, Transmission Audio Processing:
  <https://static1.squarespace.com/static/58f8d954b8a79b4ccf726c3b/t/5996db51f5e231b4a279db2f/1503058769976/Broadcast+Transmission+Audio+Processing.pdf>
- Orban 8600 feature notes: <https://www.orban.com/keyfeatures-optimodfm8600>
- Stereo Tool FM documentation: <https://www.thimeo.com/documentation/fm-transmitter.html>
