# Architecture

## Overview

MPX Prime is a native macOS audio application built with Swift and SwiftUI. It provides real-time FM stereo MPX generation with RDS support using AVAudioEngine.

```
SwiftUI UI  <->  App State (ObservableObject)
                        |
                        v
                 Audio Engine
                 (AVAudioEngine)
```

## Block Diagram

```
Audio Input (L/R) @ interface rate (typically 192 kHz)
│
├──► Phase rotation (optional)
│    └── 4-pole allpass chain at ~200 Hz — reduces waveform asymmetry
│        by 3–4 dB, yielding free headroom for downstream stages
│
├──► Input conditioning (audio domain)
│    ├── Wideband AGC (optional)
│    ├── High-pass ~20–30 Hz (infrasonic removal)
│    ├── 15 kHz low-pass
│    └── HF trim shelf (optional)
│
├──► Tonal shaping (audio domain)
│    └── 4-band parametric EQ (optional)
│        Low shelf + 2 peaking + high shelf, placed before dynamics
│
├──► Dynamics and image shaping (audio domain, float)
│    ├── Orbass bass enhancement (optional)
│    ├── Mono bass management (optional)
│    ├── Stereo widener with image protection (optional)
│    └── Multiband compressor (optional)
│        ├── TX path: linear-phase FIR splitters (sum-to-flat, all bands
│        │   share group delay — eliminates IIR-LR4 transient smear)
│        ├── Monitor path: IIR Linkwitz-Riley LR4 crossovers (low latency)
│        ├── Per-band downward expander (optional noise reduction)
│        └── Per-band fast peak limiter (optional transient control)
│
├──► Peak control (audio domain, L/R)
│    ├── Bass clipper (optional) — dedicated LF clipper with LR4 split
│    │   reduces bass-induced IMD in downstream stages
│    └── Distortion-cancelled clipper (optional) — Orban-principle LF
│        distortion cancellation: clip, extract LF error, subtract
│
├──► Encoder HF guard
│    └── Dynamic HF reduction to protect pre-emphasis compliance
│
├──► Encoder program lowpass (~15 kHz)
│    ├── TX path: Kaiser-windowed linear-phase FIR, >80 dB stop-band
│    │   (~1.67 ms latency at 192 kHz). Pushes DC-clipper / composite-
│    │   clipper aliasing well below the stereo subcarrier floor.
│    └── Monitor path: 12th-order Butterworth cascade, ~13 dB at 17 kHz,
│        ~0.2 ms latency — keeps live monitor responsive
│
├──► Stereo-image protection
│    └── Limits side-channel expansion from Orbass/widener
│
├──► Pre-encode audio limiter (L/R domain, stereo-linked)
│    └── True-peak limiter on L/R before stereo encoding
│
├──► Pre-emphasis stage (region specific)
│    ├── Pre-emphasis 50 us / 75 us
│    └── Applied during stereo encoding
│
├──► Stereo encoder (phase-coherent)
│    ├── M = (L+R)/2
│    ├── S = (L-R)/2
│    └── DSB-SC: S x cos(2pi*38 kHz)   where 38 kHz = 2xpilot (phase locked)
│
├──► RDS path (parallel, MPX domain @ output rate)
│    ├── RDS baseband (biphase / shaping)
│    ├── Gaussian filter (spectral containment)
│    └── 57 kHz subcarrier (3xpilot, phase locked)
│
├──► Final MPX chain (audio composite only)
│    ├── Final Drive (audio-composite domain)
│    ├── Composite clipper (8x oversampled tanh soft-clip, delta-based
│    │   per-band substitution: pilot/stereo/RDS guards kept clean via
│    │   bandpass-isolated clip-residual subtraction; vvtanhf-batched)
│    ├── BS.412 MPX power limiter (optional, EU regulatory compliance)
│    │   Rolling 60-second average power measurement with slow gain reduction
│    ├── MPX output calibration
│    └── Final-MPX safety limiter (audio composite only — no pilot, no RDS)
│
├──► Post-clipper subcarrier injection
│    ├── Pilot 19 kHz (approx 8–10% injection, constant amplitude)
│    ├── RDS 57 kHz (approx 3–7% injection, constant amplitude)
│    └── Subcarriers bypass all peak-control stages to preserve constant
│        amplitude for reliable stereo decoding and RDS reception
│        (professional broadcast standard: Omnia, Orban, Stereotool)
│
├──► Output formatting
│    └── Output: PCM to DAC via AVAudioEngine
│
└──► Monitor path (optional)
     └── Demodulated L/R for headphone monitoring
```

## Major Components

- `main.swift`: CLI entry point, config loading, audio engine lifecycle.
- `AudioOutputEngine.swift`: AVAudioEngine setup, render callback, input tap.
- `MPXGenerator.swift`: Real-time MPX/DSP generation, RDS encoding.
- `AppConfig.swift`: Configuration model, INI parsing/serialization.
- `SwiftUIControlApp.swift`: SwiftUI views, state management.
- `AudioDevices.swift`: CoreAudio device enumeration.
- `INIParser.swift`: INI file read/write.

## Threading Model

- Main thread: SwiftUI UI, user interaction
- Audio render callback: Real-time thread (no locks, no allocations)
- Background metering: DispatchQueue with `.userInteractive` QoS for scope/meter updates

## Current processing order

Within the main audio path, MPX Prime runs:

1. Input gain and mono fold
2. **Phase rotation** (4-pole allpass, optional)
3. Wideband AGC
4. Input HPF
5. Program lowpass
6. HF trim
7. **Parametric EQ** (4-band: low shelf + 2 peaking + high shelf, optional)
8. Orbass
9. Mono bass + stereo widener
10. Multiband compressor (3-band or 5-band)
    - **TX path**: linear-phase FIR splitters (sum-to-flat, ~5.3 ms latency at 192 kHz)
    - **Monitor path**: IIR Linkwitz-Riley LR4 crossovers (low latency)
    - Per-band downward expander (optional)
    - Per-band fast peak limiter (optional)
11. Bass clipper (LR4 split + tanh-clipped LF band, vvtanhf-batched, optional)
12. Distortion-cancelled clipper (Orban-principle LF cancellation, vvtanhf-batched, optional)
13. Encoder HF guard
14. Encoder program lowpass (~15 kHz final audio-bandwidth guard before stereo encoding) — linear-phase FIR on TX, Butterworth cascade on monitor
15. Stereo-image protection
16. Pre-encode audio limiter (L/R domain, stereo-linked true-peak; uses `OversampledPeakLimiter` per channel)
17. Pre-emphasis (M/S domain inside `makeCompositeComponents`)
18. Stereo encoder (M/S encoding, 38 kHz DSB-SC subcarrier)
19. Composite clipper (8× oversampled tanh soft-clip with delta-based per-band substitution for pilot / stereo / RDS guards; vvtanhf-batched)
20. BS.412 MPX power limiter (60s rolling average, optional, EU compliance)
21. Final-MPX safety limiter (audio composite only)
22. Pilot and RDS injection (post-clipper, constant amplitude)

All optional stages are disabled by default and can be enabled via config/UI; multiband, bass clipper, and composite clipper are on by default per `AppConfig`.

When `Mono Mode` is enabled, MPX Prime suppresses the pilot, stereo subcarrier, and RDS injection so the transmitted composite is true mono.

## External Dependencies

- AVFoundation / CoreAudio for audio I/O
- Accelerate framework for vDSP (SIMD-optimized metering)
- SwiftUI for native macOS UI

## DSP Stage Details

### Phase Rotator
4-pole cascaded second-order allpass filters at configurable frequency (default 200 Hz). Reduces waveform asymmetry (especially male voice) by 3-4 dB, providing free headroom for downstream AGC, compressors, and limiters. Standard in Orban Optimod, Stereotool, and BreakawayOne.

### Parametric EQ
4-band EQ placed before dynamics processing: band 1 (low shelf), bands 2-3 (peaking), band 4 (high shelf). All bands expose frequency and gain (+/-12 dB). Q is exposed only for the peaking bands; the shelves use an RBJ slope=1.0 (Butterworth) shape. Provides tonal shaping that feeds into the multiband crossover splitting.

### Multiband Limiter
Per-band fast peak limiters operating after multiband compression and before band summation. Fast attack, high ratio brick-wall limiting controls instantaneous transient peaks independently from the compressor's ratio-based dynamics. Prevents transient leakage without forcing the compressor to be overly aggressive.

### Downward Expander
Per-band noise reduction within the multiband compressor stage. Threshold-based gain reduction on quiet bands prevents AGC from lifting the noise floor during quiet passages.

### Bass Clipper
Dedicated clipper for low-frequency content using LR4 crossover to split, tanh-clip the low band, and recombine. Pre-clipping bass peaks independently before the final stages dramatically reduces bass-induced intermodulation distortion. Used by Omnia, Breakaway, and Stereotool.

### Distortion-Cancelled Clipper
L/R domain audio clipper implementing Orban's distortion-cancellation principle: clip the signal, extract the error (clipped minus original), lowpass-filter the error below a configurable cancellation frequency (~2 kHz), and subtract it from the clipped signal. This cancels low-frequency distortion products while leaving only high-frequency distortion that is psychoacoustically masked by the signal. The error path uses a Linkwitz-Riley 4th-order LP (two cascaded 2nd-order Butterworth sections at Q=0.707), giving a 24 dB/oct rolloff with -6 dB at the cancellation cutoff.

### BS.412 MPX Power Limiter
ITU-R BS.412 rolling average power measurement with slow gain reduction for European regulatory compliance (required in DE, AT, CH, SE, CZ, SI, and others). Measures decimated RMS power over a configurable sliding window (default 60 seconds) and applies slow gain reduction when average power exceeds the threshold. Operates on the audio composite before the safety limiter.

Structurally a **dual-integrator power AGC**: power-detect (square sample) → first integrator (per-block sum + 60-s rolling window) → sample-and-hold (per-64-sample boundary flush) → second integrator (gain smoothing with 1 s attack / 5 s release) → feedback gain ride. Functionally equivalent to the topology described in US 6,618,486 (CRL Systems / Harman, expired 2015-09-09). We use a flat rolling-average window instead of the patent's leaky-integrator first stage — gives a harder, more compliance-predictable boundary at the 60-s mark, generally preferred for type-approval testing.

### Composite Clipper (with delta-based per-band substitution)
8× oversampled tanh soft-clipper on the audio composite, sitting after the pre-encode audio limiter and before BS.412 / final-MPX safety limiter. As of 0.11 this is the **only** non-linearity on the audio composite — the prior `CompositeTruePeakLimiter` (memoryless tanh on `|composite|` peak detection) was deleted because its IM bled into the 38 kHz stereo sidebands and demodulated as `(L−R)` cancellation. The clipper does double duty: peak control plus loudness, the same role Orban's "Half-Cosine" / "Smart Clipper" stages play in the 8500/8600 line.

The bare clipper produces cubic IM that scatters across the FM baseband: M^n self-products in the audio band, M²·S / M·S² cross-products in the 23–53 kHz stereo sidebands, and broadband harmonic energy that lands inside the pilot guard band (17–21 kHz) and RDS guard band (55–59 kHz). The stereo-sideband products demodulate as audio in the S channel ("breathing") and the guard-band products vector-sum with the cleanly-injected pilot/RDS, degrading stereo decoding and RDS BCH integrity.

**Delta-based per-band substitution.** For each band we compute the bandpassed clean input `o<band>` and the bandpassed clipped output `c<band>`, then add the **delta** `(o<band> − c<band>)` back into the clipper output. That delta is exactly the per-band distortion the clipper introduced; subtracting it restores the band to the clean input while leaving every other band still clipped. Because the bandpass filters are applied identically to both `up` and `clipped`, group delay is matched within each band by construction — there is no IIR phase mismatch the way an LP-only error path would produce.

```
output = clipped
       + cancelAudio  ? (oAudio  − cAudio)  : 0
       + cancelPilot  ? (oPilot  − cPilot)  : 0
       + cancelStereo ? (oStereo − cStereo) : 0
       + cancelRDS    ? (oRDS    − cRDS)    : 0
```

The four guard bands and their default behaviour:

| Band | Filter | Default | Why |
|---|---|---|---|
| 0–15 kHz audio | LR4 LP @ 15 kHz | off | Removing audio-band distortion costs loudness; off by default for full clipper drive. Inspired by Orban US 5,168,526. |
| 17–21 kHz pilot | RBJ BP Q=4 @ 19 kHz | on | Eliminates clipper IM under the cleanly-injected 19 kHz pilot. Required for reliable stereo decoding. |
| 22–53 kHz stereo | LP@53 − LP@22 difference | on | Cancels M²·S cross-products that demodulate as `(L−R)` "breathing". |
| 55–59 kHz RDS | RBJ BP Q=14 @ 57 kHz | on | Removes clipper energy under the RDS subcarrier. Without this, BCH error rate climbs as the clipper drives. |

The pilot and RDS guards use narrow RBJ bandpass biquads (constant 0 dB peak gain, Q tuned to match the actual subcarrier guard width) rather than LP-pair difference math — at the narrow bandwidths required (4 kHz at 19 kHz, 4 kHz at 57 kHz) the LP-pair approach has poor stop-band rejection and would partially cancel the audio composite content immediately adjacent to the guard band.

Soft-clip via `vvtanhf` (vForce SIMD) batched in 8-element groups: per OS-step the upsampled inputs are pre-computed into a batch buffer, the tanh is run as a vector op, then the per-OS-step state-dependent work (decimation biquad cascade, bandpass updates) runs sequentially. ~5–9× faster than scalar `tanhf` per call — see `TanhBatchSizeBench` for the curve.

Topologically inspired by Orban US 4,460,871 (1984) and US 5,737,434 (1998), both expired. The 4,460,871 patent introduced the delta-cancellation primitive on a single audio band; 5,737,434 layered it across multiple guard bands for FM composite. Per-band RBJ bandpass implementation and the vvtanhf-batched 8× oversampled core are project-specific.

Live-apply via `RuntimeConfig`. INI keys `mpx_clipper_enabled`, `mpx_clipper_drive_db`, `mpx_clipper_ceiling_db`, `mpx_clipper_cancel_audio`, `mpx_clipper_cancel_pilot`, `mpx_clipper_cancel_stereo`, `mpx_clipper_cancel_rds`. The legacy `composite_clipper_enabled` key (which used to control the now-deleted composite *limiter*) was removed in 0.11 — see the Verification.ini key-collision warning in AGENTS.md.

`CompositeClipperCrossDomainTests` and `CompositeClipperStereoSeparationTests` are the regression guards. The first asserts cross-domain IM drop with each guard band engaged; the second asserts that decoded L/R separation is preserved within tolerance when the stereo guard is on. Together they catch both regressions in cancellation depth and over-cancellation that would collapse the stereo image.

### Encoder program lowpass (FIR / Butterworth split)
Final audio-bandwidth guard sitting immediately before stereo encoding. Two implementations co-exist and the engine picks per output mode:

- **Transmit mode (`mpxComposite`)**: Kaiser-windowed linear-phase FIR with ~80 dB stop-band attenuation. Tap count is derived from sample rate to maintain ~1.5 kHz transition at 15 kHz cutoff (≈641 taps at 192 kHz, ≈160 taps at 48 kHz). Group delay ~1.67 ms. The steep roll-off prevents downstream nonlinear stages (DC clipper, composite clipper) from re-broadening audio content into the 19 kHz pilot region, bringing DC-clipper aliasing from ≈-38 dBFS (Butterworth) to below -75 dBFS.
- **Monitor mode (`monitorAudio`)**: 12th-order Butterworth cascade (six biquads). ~0.2 ms latency, ~13 dB attenuation at 17 kHz. Intentionally shallower for low-latency live monitoring. The monitor is documented as "an idea of how it would sound" — the transmitted composite uses the FIR.

The choice is resolved once per engine start by `AudioOutputEngine.start()` via `MPXGenerator.setEncoderFIREnabled(_:)`. Both filters remain configured so toggling output mode on engine restart is immediate. The AppConfig `encoder_fir_enabled` flag allows bypassing the FIR entirely (defaults to true).

`DSPThroughputTests.preEmphasisDoesNotExplodeFullChainCost` and `EncoderBandwidthTests` guard this stage: the former catches any regression in the combined limiter+encoder cost on HF-rich program, the latter characterises the FIR's stop-band depth directly and asserts a ≥20 dB gap over the Butterworth baseline.

## RDS encoder (`BasicRDSCoder`)

### Group repertoire

| Group | Purpose | Builder |
|---|---|---|
| **0A** | PS + AF + flags | `buildGroup0(versionB: false)` |
| **0B** | PS + PI repeat (no AF) | `buildGroup0(versionB: true)` |
| **1A** | Slow Labelling — ECC + LIC variants | `buildGroup1A` |
| **2A / 2B** | Radiotext (64-char / 32-char) | `buildGroup2(versionB:)` |
| **3A** | ODA registration (RT+ AID 0x4BD7) | `buildGroup3A` |
| **4A** | Clock Time — MJD + hour + minute + TZ | `buildClockTimeGroupImmediate` |
| **10A** | PTYN (8-char Program Type Name) | `buildGroup10A` |
| **11A** | RT+ tags via ODA | `buildGroup11A` |
| **15A** | Long PS — 32-char (basic-RDS character set) | `buildGroup15A` |

Not currently implemented: 14A/14B (EON), 8A (TMC), 9A (EWS), 6A (IH),
5A/7A/13A (paging), 12A (other ODA). Multi-PSN / Data Sets — single PI only.

### Bit-level correctness

- 1187.5 bit/s (57000/48), differential coding, biphase impulse shaping,
  Gaussian shaping FIR (configurable BW + taps).
- CRC polynomial 0x5B9; offset words A=0x0FC, B=0x198, C=0x168,
  Cp=0x1E0, D=0x1B4 per IEC 62106-2 Table 2.
- 57 kHz subcarrier locked to 19 kHz pilot at 3:1 phase ratio
  (`nextSampleWithPilotLock`).
- AF Method A and Method B encoding both supported; Method B repeats
  the tuned frequency per pair so receivers can group AF lists across
  regional variants (EN 50067 §3.2.1.6.4 / IEC 62106-2 §7.5.3).

### Live-apply pipeline

`AppConfig` is the source-of-truth for every RDS setting. Edits flow
through `RDSRuntimeConfig.make(from: AppConfig)` (single canonical
factory used by both `AudioOutputEngine.applyRDSRuntimeConfig` and
the test suite) into the audio thread, which calls
`BasicRDSCoder.applyRDSRuntimeConfig(_:)` at the head of the next
render block.

The runtime-apply path rebuilds derived caches (PTYN frames, Long PS
frames, `psSequence`, `rtSequence`, group schedule) only when the
inputs that affect them change. Other fields (PI, PTY, flag bits,
TZ offset, scheduler enables) are direct assignments.

| Setting category | Disposition |
|---|---|
| Master enable, all flags (TP/TA/MS/DI) | Live |
| Identification (PI, PTY, PTYN, ECC, LIC) | Live |
| All text content (PS, RT, RT+, PTYN, Long PS) | Live |
| Alternative frequencies + method | Live |
| Group sequence + scheduler policy + CT/ID/TZ | Live |
| RDS injection level (`rds_level`) | Restart-only |
| Subcarrier frequency (`rds_freq`) | Restart-only |
| Gaussian shaping (BW + taps) | Restart-only |

The restart-only settings reconfigure the modulator FIR at engine
start and cannot be live-applied without a render-thread allocation.

### TA-edge auto-injection

Per UECP §2.5.1.1, TA flag transitions force an immediate Group 0A
ahead of the regular schedule so traffic-aware receivers see the
flip within one group time. `applyRDSRuntimeConfig` detects the edge
by diffing the previous flag value before assignment; `nextGroupBits`
honours the resulting force flag (after CT, which keeps priority
because it's minute-aligned).

### Real-time safety

- Pre-allocated 104-byte bit buffer (`bitBuffer`) reused across
  `buildGroupBits` calls; subscript-assigned in place. Test callers
  trigger Swift CoW for retained references — paid by the test, not
  the audio thread.
- Cached `cachedAutoSchedule` / `cachedStandardSchedule` — rebuilt
  only when `rtMode2B` / `rtPlusEnabled` / `rdsGroupSequence` change.
- Atomic CT cache (`cachedCTMinuteToken` + `cachedCTPacked`) updated
  from the background `clockUpdateQueue` once per second.
- Audio-thread elapsed-time math uses `BasicRDSCoder.monotonicSeconds()`
  (`ProcessInfo.systemUptime`, commpage-backed `mach_continuous_time`,
  no syscall) instead of `Date()`. `Date()` is retained only on the
  background CT-refresh path and the RT `{time}/{date}` macro
  expansion.

### Standards references

- EN 50067:1998 — original RDS standard. PI / PS / RT / AF / EON / CT
  / TDC / IH / EWS / RP / TMC / ODA feature taxonomy.
- IEC 62106-2:2018 — current RDS bit-level spec (extends Long PS
  with UTF-8 character set; UTF-8 toggle not currently implemented).
- IEC 62106-6:2023 — RT+ / ODA / eRT extensions.
- UECP SPB 490 v7.05 — encoder control protocol (not currently
  implemented; TA-edge behaviour follows the §2.5.1.1 pattern).

PDFs in `/documents/` for reference.

## General DSP notes

- Orbass is intentionally conservative. It uses adaptive low-band enhancement with restrained harmonic and optional subharmonic support, plus gated makeup behavior to reduce bass pumping and low-level artifacts.
- The multiband stage uses complementary Linkwitz-Riley 4th-order stereo crossover stages. This provides clean band separation and reduces recombination smear and tonal instability when adjacent bands compress differently.
- The final MPX chain remains verification-backed. Structural cleanup there is intentionally done in small steps because even behavior-preserving refactors can change composite output measurably.
- Verification covers both composite safety and decoded-audio quality signals. In addition to the base offline verifier, a focused preset sweep exists for the main 5-band preset family (`5B AC/Pop`, `5B CHR/EDM`, `5B Rock`, `5B Talk`, `5B News`, `5B Urban`, `5B Dance`).
- All new DSP stages (phase rotator, parametric EQ, multiband limiter, downward expander, bass clipper, distortion-cancelled clipper, BS.412) are disabled by default and have zero impact on the signal chain until enabled. All support live-apply via RuntimeConfig.
