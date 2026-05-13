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
Audio Input device (L/R) @ device's native rate (e.g. 48 / 96 / 192 kHz)
│  via `InputAUHAL` (direct AUHAL audio unit) → `StereoInputRingBuffer`
│  Adaptive cubic resampler in the output render callback absorbs
│  input/render rate mismatch + clock drift up to 50 ppm.
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
│    ├── Mono bass management (optional)
│    ├── Multiband compressor (optional)
│    │   ├── TX path: linear-phase FIR splitters (sum-to-flat, all bands
│    │   │   share group delay — eliminates IIR-LR4 transient smear)
│    │   ├── Monitor path: IIR Linkwitz-Riley LR4 crossovers (low latency)
│    │   ├── Per-band downward expander (optional noise reduction)
│    │   └── Per-band fast peak limiter (optional transient control)
│    ├── Stereo widener (optional, post-multiband)
│    └── PrimeBass (optional, post-multiband)
│        └── Multiband doesn't compress synthesised harmonics back down
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
│    └── Limits side-channel expansion from PrimeBass/widener
│
├──► Pre-emphasis (L/R domain, region specific)
│    ├── 50 us (Europe) / 75 us (Americas / Japan / Australia)
│    └── Applied L/R immediately upstream of the pre-encode limiter
│        so the limiter peak-controls the +10..12 dB HF-boosted signal
│        (canonical Optimod / Stereotool placement)
│
├──► Pre-encode audio limiter (L/R domain, stereo-linked oversampled)
│    └── True-peak limiter on L/R before stereo encoding —
│        `StereoLinkedOversampledPeakLimiter` uses a max(|L|, |R|)
│        detector so both channels receive identical gain reduction
│        (no asymmetric pumping). Optional band-limited residual ceiling
│        uses the 33-tap / 0.25-cutoff kernel when enabled. Threshold,
│        release, residual enable, and residual kernel shape live-apply
│        via `RuntimeConfig`.
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
│    │   bandpass-isolated clip-residual subtraction; vvtanhf-batched;
│    │   optional OS-rate sliding-window-max look-ahead peak control
│    │   gated by `mpx_clipper_lookahead_ms`)
│    ├── Audio composite bandwidth FIR (linear-phase cleanup before
│    │   pilot/RDS injection — group delay folded into the subcarrier
│    │   delay line so phase alignment is preserved)
│    ├── BS.412 MPX power limiter (optional, EU regulatory compliance)
│    │   Rolling 60-second average power measurement with slow gain reduction
│    ├── Final-MPX safety limiter (audio composite only — no pilot, no RDS)
│    ├── Composite budget governor (smoothed gain ride on the audio
│    │   path enforces `audioCeil = (threshold/outputGain - reserved -
│    │   margin) × outputGain` BEFORE pilot/RDS injection so the
│    │   post-injection clamp is unreachable for sane configs;
│    │   `overBudget` flag classifies impossible configs explicitly)
│    └── MPX output calibration
│
├──► Post-clipper subcarrier injection (delay-aligned)
│    ├── Pilot 19 kHz (approx 8–10% injection, constant amplitude)
│    ├── RDS 57 kHz (approx 3–7% injection, constant amplitude)
│    ├── `subcarrierDelayLine` delays pilot+RDS by composite-clipper
│    │   total delay + safety-limiter lookahead so the receiver's
│    │   pilot-derived 38 kHz reference aligns with the audio
│    │   composite's internal stereo subcarrier modulation
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

- `main.swift`: CLI entry point, config loading, audio engine lifecycle. New `--verify-receiver` mode added in 0.27.
- `AudioOutputEngine.swift`: AVAudioEngine output setup, render callback, transport orchestration. Delegates input capture to `InputAUHAL`.
- `InputAUHAL.swift`: Direct AUHAL (`kAudioUnitSubType_HALOutput`) input-capture wrapper. Replaces a second `AVAudioEngine` instance the engine used to spin up for input — AVAudioEngine's first `start()` with a non-default input device intermittently failed to deliver tap callbacks. The two-AUHAL pattern (separate input AU + output AVAudioEngine + `StereoInputRingBuffer` as the only bridge) is what TN2091 / CAPlayThrough / Stereotool / AudioKit's non-default-device path use on macOS.
- `MPXGenerator.swift`: Real-time MPX/DSP generation, RDS encoding.
- `MPXDecoder.swift` (0.27): Reusable FM-stereo demodulator. Used both by the audio render callback for monitor output (with the internally generated, delay-aligned 38 kHz reference) and by the offline verifier (with a pilot-PLL recovered reference). Includes a smoothed noise gate and a stereo-collapse cooldown that re-initialises the PLL if it ever drifts off-lock.
- `BandLimitedStep.swift` (0.27): Allocation-free BLEP/BLAMP correction helper for the US 6,937,912 anti-aliased clipping work. Detects fractional threshold crossings and schedules normalized finite correction windows in impulse / step / ramp shapes.
- `AcceleratedBandlimitedResidualClipper.swift` (0.27): vDSP-accelerated patent-style residual-bandlimiting candidate clipper (hard-clip → bandlimit the residual → reconstruct as delayed-clean + filtered-residual). Wired as the inner kernel of `OversampledPeakLimiter` / `StereoLinkedOversampledPeakLimiter` behind the off-by-default `pre_encode_bandlimited_residual_enabled` opt-in.
- `AppConfig.swift`: Configuration model, INI parsing/serialization.
- `SwiftUIControlApp.swift`: SwiftUI views, state management.
- `AudioDevices.swift`: CoreAudio device enumeration; resolves UIDs to `AudioDeviceID`s and provides the `defaultInputDeviceID()` helper AUHAL needs (AUHAL requires an explicit device, unlike AVAudioEngine which inferred the default implicitly).
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
8. Mono bass (inside `processStereoImageStage`)
9. Multiband compressor (3-band or 5-band)
    - **TX path**: linear-phase FIR splitters (sum-to-flat, ~5.3 ms latency at 192 kHz)
    - **Monitor path**: IIR Linkwitz-Riley LR4 crossovers (low latency)
    - Per-band downward expander (optional)
    - Per-band fast peak limiter (optional)
10. Stereo widener (post-multiband; canonical Optimod placement so multiband doesn't compress widened side-channel HF)
11. PrimeBass (post-multiband; canonical MaxxBass / Aural Exciter / Big Bottom placement so multiband doesn't compress the synthesised harmonics)
12. Bass clipper (LR4 split + tanh-clipped LF band, vvtanhf-batched, optional)
13. Distortion-cancelled clipper (Orban-principle LF cancellation, vvtanhf-batched, optional)
14. Encoder HF guard
15. Encoder program lowpass (~15 kHz final audio-bandwidth guard before stereo encoding) — linear-phase FIR on TX, Butterworth cascade on monitor
16. Stereo-image protection
17. Pre-emphasis (L/R domain, immediately upstream of pre-encode limiter; canonical Optimod / Stereotool placement so the limiter peak-controls the +10–12 dB HF-boosted signal)
18. Pre-encode audio limiter (L/R domain, `StereoLinkedOversampledPeakLimiter` — `max(|L|, |R|)` detector drives both channels identically)
19. Stereo encoder (M/S encoding, 38 kHz DSB-SC subcarrier)
20. Composite clipper (8× oversampled tanh soft-clip with differential topology + linear-phase FIR decimation + delta-based per-band substitution for pilot / stereo / RDS guards; vvtanhf-batched; optional OS-rate sliding-window-max look-ahead)
21. Audio composite bandwidth FIR (linear-phase HF cleanup before pilot/RDS injection)
22. BS.412 MPX power limiter (60s rolling average, optional, EU compliance)
23. Final-MPX safety limiter (audio composite only)
24. Composite budget governor (smoothed gain ride on audio path so post-injection clamp is unreachable for sane configs)
25. Pilot and RDS injection (post-clipper, constant amplitude, delay-aligned via `subcarrierDelayLine`)

Most optional stages are disabled by default and can be enabled via config/UI. The default processing chain intentionally ships with multiband, bass clipper, composite clipper, pre-encode limiter, final MPX safety, encoder FIR, and multiband FIR enabled per `AppConfig`.

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

### Composite Clipper (differential topology with delta-based per-band substitution)
8× oversampled tanh soft-clipper on the audio composite, sitting after the pre-encode audio limiter and before BS.412 / final-MPX safety limiter. Since 0.11 this is the **only** non-linearity on the audio composite — the prior `CompositeTruePeakLimiter` (memoryless tanh on `|composite|` peak detection) was deleted because its IM bled into the 38 kHz stereo sidebands and demodulated as `(L−R)` cancellation. As of 0.20 the clipper runs the **differential topology** of Orban US 6,337,999 (expired 2022, public domain): only the *clipping residual* (input − clipped) goes through decimation, while the wanted signal rides a 1× delay-matched bypass and the residual is subtracted at the output. The decimator's stopband leakage and any phase non-flatness now only colour the residual subtracted at output, not the wanted (L−R) sideband content. Decimation itself uses `LinearPhaseFIRDecimator` (Kaiser-windowed sinc, ~147 taps, `vDSP_dotpr` polyphase, ≥90 dB stopband, flat passband 0–53 kHz) — replaces the prior `BiquadCascade6` 12th-order Butterworth which had ~70-80 dB stopband and 1-2 dB rolloff at the upper subcarrier edge. Cost: ~9 host samples (~47 µs at 192 kHz) of TX-path latency. The clipper does double duty: peak control plus loudness, the same role Orban's "Half-Cosine" / "Smart Clipper" stages play in the 8500/8600 line.

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

Soft-clip via `vvtanhf` (vForce SIMD) batched in 8-element groups: per OS-step the upsampled inputs are pre-computed into a batch buffer, the tanh is run as a vector op, then the per-OS-step state-dependent work (linear-phase FIR decimation push, bandpass updates) runs sequentially. ~5–9× faster than scalar `tanhf` per call — see `TanhBatchSizeBench` for the curve. The FIR convolution itself runs through `vDSP_dotpr` for the polyphase commutator path.

Topologically inspired by three expired Orban patents: US 4,460,871 (1984) introduced the delta-cancellation primitive on a single audio band; US 5,737,434 (1998) layered it across multiple guard bands for FM composite; US 6,337,999 (1998 / expired 2022) added the differential-clipper topology where only the residual is decimated. Per-band RBJ bandpass implementation, the linear-phase FIR decimator, and the `vvtanhf`-batched 8× oversampled core are project-specific.

Live-apply via `RuntimeConfig`. INI keys `mpx_clipper_enabled`, `mpx_clipper_drive_db`, `mpx_clipper_ceiling_db`, `mpx_clipper_cancel_audio`, `mpx_clipper_cancel_pilot`, `mpx_clipper_cancel_stereo`, `mpx_clipper_cancel_rds`, and (0.26) `mpx_clipper_lookahead_ms`. The legacy `composite_clipper_enabled` key (which used to control the now-deleted composite *limiter*) was removed in 0.11 — see the Verification.ini key-collision warning in AGENTS.md.

**Look-ahead peak control (0.26, optional).** When `mpx_clipper_lookahead_ms > 0`, an OS-rate (1.536 MHz at 192 kHz × 8) sliding-window-max detector with Lagrange-interpolated intersample peak detection feeds a gain envelope smoothed by a 200 Hz one-pole LP. The gain is applied identically to both the clipper's `up` input and the per-band `orig*` filters, so the differential-topology cancellation linearity holds. A separate `lookaheadGainReductionDB` telemetry value distinguishes clean predictive ducking from soft-clip distortion-producing GR on the meter. Single INI knob; attack/release/smoother cutoff are hardcoded (exponential attack tied to the look-ahead window, ~80 ms release, 200 Hz smoother). 0.0 disables (default); 2.0 ms is the recommended value for loudness-priority presets. Algorithmic primitives — Lemire monotonic deque (sliding-window max), half-cosine attack LUT (US 6,434,241, expired 2014), 200 Hz gain-modulation smoother (US 5,737,434, expired ~2017) — are expired or public-domain.

`CompositeClipperCrossDomainTests` and `CompositeClipperStereoSeparationTests` are the regression guards. The first asserts cross-domain IM drop with each guard band engaged; the second asserts that decoded L/R separation is preserved within tolerance when the stereo guard is on. `CompositeClipperLookaheadTests` covers the (0.26) look-ahead path: overshoot bound (`max(|out|) ≤ ceiling × 1.005` at 2 ms), steady-state transparency on pink noise, pilot/stereo/RDS guard regression with look-ahead engaged, cross-domain cancellation regression (catches asymmetric per-band gain leak), and total-delay reporting. Together they catch regressions in cancellation depth, over-cancellation that would collapse the stereo image, look-ahead detector / gain-application asymmetry, and latency-reporting drift.

### Audio Composite Bandwidth FIR (0.26)
Linear-phase FIR cleanup stage placed after the composite clipper and before BS.412 / final-MPX safety limiting. Strips shaper/clipper spill that would otherwise live above the upper stereo sideband and beat with the cleanly-injected pilot/RDS. Group delay (~112 host samples at 192 kHz) folds into `recomputeSubcarrierDelay()` so the post-clipper subcarrier delay line tracks the new audio path delay automatically.

### Composite Budget Governor (0.26)
Smoothed gain ride on the audio composite that runs *before* pilot/RDS injection. `MPXGenerator.makeFinalCompositeThresholds(outputGain:threshold:reserved:)` derives
```
effectiveThreshold = threshold / max(1.0, outputGain)
allowedAudioAbs    = max(0, effectiveThreshold - reservedSubcarrier - safetyMargin)  // safetyMargin = 0.02
overBudget         = allowedAudioAbs <= 0
```
`processFinalComposite` applies a smoothed gain ride driven by `audioCeilOut = postLimiterCeiling × outputGain`. The audible work is done by the smoothed ride (separate attack/release time constants); a hard ceiling remains at the same value as a last-sample guard for attack-time transients. Pilot and RDS are *not* scaled or clipped — only the audio composite is reduced. The final `clampf(mpx, -1, 1)` survives only as a numeric guard against illegal samples reaching CoreAudio; for valid configs it should never engage. `CompositeCalibrationStatus.overBudget` re-derives from current `outputGain` and the smoothed `subcarrierReservationEnv`, exposing impossible configs (e.g. very hot output gain where pilot reservation alone exceeds the threshold) to UI and verifier. `postInjectionOvershoot` (50 ms decayed envelope) reports the size of any residual clamp engagement so transient governor lag is visible too. The verifier reports both `worstPostInjectionOvershoot` and `compositeBudgetExceeded` per scenario.

### Subcarrier Delay Alignment (0.26)
A new host-rate `subcarrierDelayLine` ring buffer delays pilot+RDS by the composite clipper's total delay plus the safety-limiter lookahead samples. `recomputeSubcarrierDelay()` sizes the line dynamically from the active stage delays (composite clipper FIR decimator group delay + composite-clipper look-ahead samples + audio-composite bandwidth FIR group delay + safety limiter look-ahead). The receiver's pilot-derived 38 kHz reference is now phase-coherent with the audio composite's internal L−R subcarrier modulation, closing a stereo-decode degradation that grew with the differential-topology + audio-bandwidth-FIR + look-ahead stack. `StereoSeparationReceiverTests` is the regression guard.

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

- PrimeBass (formerly Orbass — renamed in 0.20 to avoid trademark adjacency) is intentionally conservative. It uses adaptive low-band enhancement with restrained harmonic and optional subharmonic support, plus gated makeup behavior to reduce bass pumping and low-level artifacts. The harmonic synth in 0.20 follows the MaxxBass principle (US 5,930,373, expired 2017): per-order equal-loudness weighting at configure time, separate even (asymmetric squarer) and odd (tanh difference) generators, and a pre-waveshaper allpass at F0 that phase-decorrelates synthesised harmonics from the direct lowboost path (Aphex US 4,150,253 topology, adapted for bass extension via allpass instead of HPF). A Werrbach transient-discriminate gain modulator (US 5,424,488) layers on top — a dual-envelope detector briefly bursts harmonics on real onsets and settles to a lower floor during sustained content. The direct LF gain is tapered down with the harmonics knob so perceived bass is carried more by the weighted harmonics and less by raw LF amplitude — buying headroom in the bass clipper and pre-encode limiter while the makeup-gain stage compensates absolute level.
- The multiband stage uses complementary Linkwitz-Riley 4th-order stereo crossover stages. This provides clean band separation and reduces recombination smear and tonal instability when adjacent bands compress differently.
- The final MPX chain remains verification-backed. Structural cleanup there is intentionally done in small steps because even behavior-preserving refactors can change composite output measurably.
- Verification covers both composite safety and decoded-audio quality signals. In addition to the base offline verifier, a focused preset sweep exists for the main 5-band preset family (`5B AC/Pop`, `5B CHR/EDM`, `5B Rock`, `5B Talk`, `5B News`, `5B Urban`, `5B Dance`).
- All new DSP stages (phase rotator, parametric EQ, multiband limiter, downward expander, bass clipper, distortion-cancelled clipper, BS.412) are disabled by default and have zero impact on the signal chain until enabled. All support live-apply via RuntimeConfig.
