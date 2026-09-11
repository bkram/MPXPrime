# MPXPrime DSP benchmark

Captured: 2026-05-21T16:54:42Z
Machine: MacBookPro18,1 / Apple M1 Pro
Cores: 10 logical, 10 active
OS: Version 26.5 (Build 25F71)
Build: release
Branch: develop/v.030 (pre-dual-rate refactor)
Reproduce: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer MPXPRIME_BENCH=1 swift test -c release --package-path macOS --filter Benchmark`

## Rate sweep (full chain)

| Rate (kHz) | RDS+stereo | Wall (s) | Audio (s) | % of real-time |
| ---------: | :--------: | -------: | --------: | -------------: |
|       96.0 |         no |   0.2132 |    1.0000 |         21.32% |
|      128.0 |        yes |   0.2767 |    1.0000 |         27.67% |
|      176.4 |        yes |   0.3813 |    1.0000 |         38.13% |
|      192.0 |        yes |   0.4163 |    1.0000 |         41.63% |

Scaling is close to linear with rate (192/96 = 2.0; 41.6/21.3 = 1.95) -- confirms the model that audio-domain stage cost scales ~linearly with outer rate.

96 kHz row has RDS+stereo off because RDS at 57 kHz exceeds 96 kHz Nyquist; it isolates audio-only cost.

## Per-stage cost @ 192 kHz (full chain on, stage A/B)

| Stage                     | Domain | With (s) | Without (s) | Delta (ms/s) | % of real-time |
| :------------------------ | :----- | -------: | ----------: | -----------: | -------------: |
| (baseline, all on)        | -      |   0.4160 |           - |            - |         41.60% |
| Multiband (5-band, FIR)   | audio  |   0.4160 |      0.3680 |        48.00 |          4.80% |
| Wideband AGC              | audio  |   0.4160 |      0.4136 |         2.38 |          0.24% |
| Parametric EQ             | audio  |   0.4160 |      0.4131 |         2.88 |          0.29% |
| PrimeBass                 | audio  |   0.4160 |      0.3931 |        22.90 |          2.29% |
| Stereo widener            | audio  |   0.4160 |      0.4128 |         3.23 |          0.32% |
| Mono bass                 | audio  |   0.4160 |      0.4146 |         1.40 |          0.14% |
| Phase rotation            | audio  |   0.4160 |      0.4120 |         3.98 |          0.40% |
| Bass clipper              | audio  |   0.4160 |      0.3650 |        51.03 |          5.10% |
| DC clipper                | audio  |   0.4160 |      0.3593 |        56.68 |          5.67% |
| Multiband limiter         | audio  |   0.4160 |      0.4093 |         6.74 |          0.67% |
| Pre-emphasis              | audio  |   0.4160 |      0.4070 |         9.03 |          0.90% |
| Pre-encode limiter        | audio  |   0.4160 |      0.3770 |        38.96 |          3.90% |
| Pre-encode look-ahead     | audio  |   0.4160 |      0.4146 |         1.45 |          0.14% |
| Composite clipper (16x)   | MPX    |   0.4160 |      0.2737 |       142.25 |         14.23% |
| BS.412                    | MPX    |   0.4160 |      0.4144 |         1.58 |          0.16% |
| RDS encoder               | MPX    |   0.4160 |      0.4073 |         8.69 |          0.87% |

**Sum audio-domain deltas:** 248.66 ms/s (24.87% of real-time)
**Sum MPX-domain deltas:**   152.52 ms/s (15.25% of real-time)

Deltas are not strictly additive -- stages can interact (e.g. a hot stage feeding more limiter work). Treat as first-order estimate, not algebra.

## Summary

Current chain cost @ 192 kHz, full features: **41.54% of real-time**

- audio-domain stages contribute ~23.75% of real-time
- MPX-domain stages contribute   ~14.97% of real-time

Estimated dual-rate cost (audio @ 48 kHz, MPX @ 192 kHz, +5% resampler): **25.80% of real-time**
Estimated savings: **15.74 percentage points** (38% relative)

## Surprises vs prior assumptions

1. **Composite clipper (16x) is the single heaviest stage** at 14.23% RT, not the multiband splitter (4.80%). It is MPX-domain and stays at the high rate after the dual-rate refactor -- dual-rate does NOT directly reduce it. The multiband-FIR-is-the-bottleneck framing in earlier discussion was wrong on Apple Silicon; vDSP/NEON+AMX makes the FIR splitter much cheaper than expected here.
2. **DC clipper (5.67%) and Bass clipper (5.10%) are heavier than the multiband splitter** on M1 Pro. Both are audio-domain (move to 48 kHz under dual-rate). Their internal oversampling stays the same final rate (192k and 384k respectively), but the outer per-sample work scales with the outer rate.
3. **Pre-encode limiter (3.90%) and PrimeBass (2.29%)** are non-trivial. Both audio-domain.
4. **Wideband AGC, parametric EQ, stereo widener, mono bass, phase rotation, multiband limiter, BS.412, pre-encode look-ahead** are all <1% RT each. Mostly negligible.
5. **The rate sweep scales near-linearly** with sample rate (192/96 ratio = 2.0, cost ratio = 1.95). Validates the dual-rate scaling assumption.

## Implications for the dual-rate refactor

- The refactor is still worth doing -- 38% relative reduction is real -- but the headline value is "all audio-domain stages get cheaper proportionally," not "the multiband FIR drops to 1/4."
- On older Intel (MBP16,1, MBP15-Coffee-Lake-H), where AMX is unavailable and AVX2 is the SIMD floor, the audio-domain stages should be relatively heavier than on M1 Pro. The dual-rate win is expected to be larger in percentage points on those machines. Run this same benchmark on the 16,1 to confirm.
- The composite clipper at 14.23% RT is the obvious next acceleration target *independent* of dual-rate. It already uses LinearPhaseFIRDecimator + vDSP_dotpr, but at 16x from 192 kHz the internal rate is 3.072 MHz and the decimation FIR dominates. Worth profiling further.
- Resampler overhead at the 48k/192k boundary needs to come in under ~5% RT for the dual-rate to be net positive. A Kaiser-windowed sinc polyphase resampler at ~64 taps should sit well under that.
