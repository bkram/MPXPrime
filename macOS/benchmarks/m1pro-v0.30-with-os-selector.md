# MPXPrime DSP benchmark

Captured: 2026-05-21T19:37:11Z
Machine: MacBookPro18,1 / Apple M1 Pro
Cores: 10 logical, 10 active
OS: Version 26.5 (Build 25F71)
Build: release
Branch: develop/v.030 (post composite-clipper oversampling selector)
Reproduce: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer MPXPRIME_BENCH=1 swift test -c release --package-path macOS --filter Benchmark`

## Rate sweep (full chain)

| Rate (kHz) | RDS+stereo | Wall (s) | Audio (s) | % of real-time |
| ---------: | :--------: | -------: | --------: | -------------: |
|       96.0 |         no |   0.2115 |    1.0000 |         21.15% |
|      128.0 |        yes |   0.2739 |    1.0000 |         27.39% |
|      176.4 |        yes |   0.3793 |    1.0000 |         37.93% |
|      192.0 |        yes |   0.4142 |    1.0000 |         41.42% |

96 kHz row has RDS+stereo off because RDS at 57 kHz exceeds 96 kHz Nyquist; it isolates audio-only cost.

## Composite clipper oversampling sweep (full chain @ 192 kHz)

| Oversampling | Wall (s) | Delta vs 16x | % of real-time |
| -----------: | -------: | -----------: | -------------: |
|           8x |   0.3510 |  -61.66 ms/s |         35.10% |
|          16x |   0.4127 |  (reference) |         41.27% |
|          32x |   0.5345 | +121.83 ms/s |         53.45% |

New UI knob (Composite Clipper inspector). 16x is the default and matches Optimod / Omnia.11 / Stereotool. 8x trades ~6 dB alias suppression for ~6 percentage points of real-time headroom — useful on slower hardware. 32x adds ~6 dB further alias suppression at hot drives but costs ~12 percentage points of real-time vs 16x — recommended only with hardware headroom. Restart-required (changes FIR decimator tap count + Lagrange interpolator step count + per-host batch buffer sizes).

## Per-stage cost @ 192 kHz (full chain on, stage A/B)

| Stage                     | Domain | With (s) | Without (s) | Delta (ms/s) | % of real-time |
| :------------------------ | :----- | -------: | ----------: | -----------: | -------------: |
| (baseline, all on)        | -      |   0.4146 |           - |            - |         41.46% |
| Multiband (5-band, FIR)   | audio  |   0.4146 |      0.3654 |        49.19 |          4.92% |
| Wideband AGC              | audio  |   0.4146 |      0.4114 |         3.14 |          0.31% |
| Parametric EQ             | audio  |   0.4146 |      0.4098 |         4.82 |          0.48% |
| PrimeBass                 | audio  |   0.4146 |      0.3913 |        23.30 |          2.33% |
| Stereo widener            | audio  |   0.4146 |      0.4113 |         3.27 |          0.33% |
| Mono bass                 | audio  |   0.4146 |      0.4122 |         2.40 |          0.24% |
| Phase rotation            | audio  |   0.4146 |      0.4108 |         3.82 |          0.38% |
| Bass clipper              | audio  |   0.4146 |      0.3640 |        50.56 |          5.06% |
| DC clipper                | audio  |   0.4146 |      0.3578 |        56.77 |          5.68% |
| Multiband limiter         | audio  |   0.4146 |      0.4078 |         6.81 |          0.68% |
| Pre-emphasis              | audio  |   0.4146 |      0.4059 |         8.71 |          0.87% |
| Pre-encode limiter        | audio  |   0.4146 |      0.3770 |        37.61 |          3.76% |
| Pre-encode look-ahead     | audio  |   0.4146 |      0.4143 |         0.34 |          0.03% |
| Composite clipper         | MPX    |   0.4146 |      0.2738 |       140.74 |         14.07% |
| BS.412                    | MPX    |   0.4146 |      0.4124 |         2.22 |          0.22% |
| RDS encoder               | MPX    |   0.4146 |      0.4037 |        10.94 |          1.09% |

**Sum audio-domain deltas:** 250.74 ms/s (25.07% of real-time)
**Sum MPX-domain deltas:**   153.90 ms/s (15.39% of real-time)

Deltas are not strictly additive — stages can interact (e.g. a hot stage feeding more limiter work). Treat as first-order estimate, not algebra.

## Summary

Current chain cost @ 192 kHz, full features (16x composite clipper): **41.42% of real-time**
- audio-domain stages contribute ~24.85% of real-time
- MPX-domain stages contribute   ~15.35% of real-time

Estimated dual-rate cost (audio @ 48 kHz, MPX @ 192 kHz, +5% resampler): **24.85% of real-time**
Estimated savings: **16.57 percentage points** (40% relative)

## Notes vs pre-OS-selector run

- Numbers reproduce the earlier `m1pro-v0.30-pre-dualrate.md` baseline within run-to-run noise (~±0.5 pp on most rows) — adding the configurable oversampling did not regress the 16x default path. Composite clipper row label is now "Composite clipper" rather than "Composite clipper (16x)" since the factor is operator-selectable.
- New oversampling sweep section captures the per-knob CPU cost, giving operators a measured number to weigh against the marginal alias-suppression improvement that 32x buys.
- Dual-rate refactor (plan.md "Next up" #1) projection is unchanged: composite clipper stays at MPX rate regardless of audio-domain rate, so its 14.07% RT cost survives the refactor. The combination dual-rate + 32x clipper lands at roughly 24.85% RT (post dual-rate baseline) + 14 pp (32x premium over 16x) = ~39% RT — comparable to today's 16x cost, just with the spec-sheet 32x defended.
