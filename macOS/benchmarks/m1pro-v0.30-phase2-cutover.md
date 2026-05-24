# MPXPrime DSP benchmark

Captured: 2026-05-23T18:04:44Z
Machine: MacBookPro18,1 / Apple M1 Pro
Cores: 10 logical, 10 active
OS: Version 26.5 (Build 25F71)
Build: release
Branch: develop/v.030 (post Phase 2 cutover — audio domain runs at 48 kHz inside the boundary)
Reproduce: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer MPXPRIME_BENCH=1 swift test -c release --package-path macOS --filter Benchmark`

## Rate sweep (full chain)

| Rate (kHz) | RDS+stereo | Wall (s) | Audio (s) | % of real-time |
| ---------: | :--------: | -------: | --------: | -------------: |
|       96.0 |         no |   0.2147 |    1.0000 |         21.47% |
|      128.0 |        yes |   0.2786 |    1.0000 |         27.86% |
|      176.4 |        yes |   0.3850 |    1.0000 |         38.50% |
|      192.0 |        yes |   0.4185 |    1.0000 |         41.85% |

Reference for the dual-rate-off path. Within run-to-run noise of the pre-cutover captures (`m1pro-v0.30-with-os-selector.md` measured 41.4-41.6% at 192 kHz).

## Composite clipper oversampling sweep (full chain @ 192 kHz)

| Oversampling | Wall (s) | Delta vs 16x | % of real-time |
| -----------: | -------: | -----------: | -------------: |
|           8x |   0.3538 |  -64.88 ms/s |         35.38% |
|          16x |   0.4187 |  (reference) |         41.87% |
|          32x |   0.5456 | +126.89 ms/s |         54.56% |

Composite clipper stays at MPX rate regardless of the dual-rate boundary — the cost is unchanged from prior captures.

## Dual-rate boundary sweep (full chain @ 192 kHz, audio 48 kHz)

| Boundary | Wall (s) | Delta vs off | % of real-time |
| -------- | -------: | -----------: | -------------: |
| off      |   0.4185 |  (reference) |         41.85% |
| on       |   0.2426 | -175.90 ms/s |         24.26% |

**Savings: -17.59 percentage points (-42.0% relative).** This is the actual measured payoff of the Phase 2 cutover — the audio domain now runs at 48 kHz inside the boundary instead of at 192 kHz after a no-op roundtrip. The savings match the original projection from the pre-dualrate baseline (16.5 pp / 40% relative).

Receiver verification confirms the cutover preserves stereo separation:

| Frequency | Boundary off (dB) | Boundary on (dB) |
| --------- | ----------------: | ---------------: |
|     1 kHz |              42.9 |             42.9 |
|    10 kHz |              26.0 |             26.1 |
|    14 kHz |              26.4 |             33.4 |

(14 kHz separation is slightly *better* with the boundary on — likely a beneficial side effect of the audio-rate FIR splitter's coefficient profile vs the MPX-rate version. Confirmed via `--verify-receiver` after the cutover fix landed.)

## Per-stage cost @ 192 kHz (full chain on, stage A/B, boundary OFF)

Per-stage breakdown still reflects MPX-rate processing for the A/B (each stage is toggled with the rest of the chain at MPX rate). Use the dual-rate boundary sweep above for actual boundary-on costs.

| Stage                     | Domain | With (s) | Without (s) | Delta (ms/s) | % of real-time |
| :------------------------ | :----- | -------: | ----------: | -----------: | -------------: |
| (baseline, all on)        | -      |   0.4188 |           - |            - |         41.88% |
| Multiband (5-band, FIR)   | audio  |   0.4188 |      0.3705 |        48.30 |          4.83% |
| Wideband AGC              | audio  |   0.4188 |      0.4161 |         2.64 |          0.26% |
| Parametric EQ             | audio  |   0.4188 |      0.4155 |         3.28 |          0.33% |
| PrimeBass                 | audio  |   0.4188 |      0.3962 |        22.56 |          2.26% |
| Stereo widener            | audio  |   0.4188 |      0.4165 |         2.24 |          0.22% |
| Mono bass                 | audio  |   0.4188 |      0.4172 |         1.52 |          0.15% |
| Phase rotation            | audio  |   0.4188 |      0.4153 |         3.45 |          0.34% |
| Bass clipper              | audio  |   0.4188 |      0.3678 |        50.97 |          5.10% |
| DC clipper                | audio  |   0.4188 |      0.3622 |        56.52 |          5.65% |
| Multiband limiter         | audio  |   0.4188 |      0.4131 |         5.62 |          0.56% |
| Pre-emphasis              | audio  |   0.4188 |      0.4096 |         9.14 |          0.91% |
| Pre-encode limiter        | audio  |   0.4188 |      0.3813 |        37.49 |          3.75% |
| Pre-encode look-ahead     | audio  |   0.4188 |      0.4180 |         0.73 |          0.07% |
| Composite clipper         | MPX    |   0.4188 |      0.2759 |       142.86 |         14.29% |
| BS.412                    | MPX    |   0.4188 |      0.4174 |         1.38 |          0.14% |
| RDS encoder               | MPX    |   0.4188 |      0.4097 |         9.11 |          0.91% |

**Sum audio-domain deltas:** 244.47 ms/s (24.45% of real-time)
**Sum MPX-domain deltas:**   153.34 ms/s (15.33% of real-time)

## Closing notes

- Phase 2 cutover landed cleanly with default-disabled bit-identical regression preserved (`DualRateBoundaryTests.defaultDisabledIsBitIdenticalToBaseline` + 384 default tests pass).
- Two cutover-specific bugs were caught and fixed during validation: (1) interp output buffer was being read in wrong order — `[L-1], [0], [1], ..., [L-2]` instead of `[0], [1], ..., [L-1]`, creating a per-cycle temporal discontinuity that destroyed phase coherence; (2) `recomputeSubcarrierDelay()` was over-delaying the pilot by the boundary delay — the boundary sits upstream of the encoder, so the freshly-generated pilot and embedded 38 kHz subcarrier don't traverse it, and adding boundary delay to the pilot side rotated the pilot ~94° at 19 kHz relative to the embedded carrier (which trashes production decoder separation while leaving the ideal-coherent decode intact).
- The composite clipper at 14.29% RT remains the single largest stage cost; it stays at MPX rate by design (DSB-SC subcarrier + RDS need the high rate's bandwidth). Composite-clipper acceleration would need a separate effort (e.g. higher OS internal rate vs current 16×, or a different decimator design).
