# Architecture

## Overview

MPX Prime Studio is a native macOS audio application built with Swift and SwiftUI. It provides real-time FM stereo MPX generation with RDS support using AVAudioEngine.

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
│    │   ├── Optional transient-aware attack detector
│    │   │   (`multiband_transient_aware_attack_enabled`) blends RMS/peak
│    │   │   detection and briefly stretches attack on percussive fronts
│    │   ├── Optional inter-band coupling
│    │   │   (`multiband_inter_band_coupling_enabled`) lets low-band GR
│    │   │   gently bias upper-band thresholds
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
├──► Pre-emphasis-aware HF clipper (L/R domain, oversampled, optional, default-off)
│    └── Dedicated HF peak control on the *pre-emphasised* high band,
│        between pre-emphasis and the pre-encode limiter, so the broadband
│        limiter doesn't pull gain across the whole signal and dull it
│        (de-emphasis-correct — the receiver's fixed de-emphasis restores
│        the curve). Configurable crossover (3-8 kHz, default 5 kHz),
│        threshold (-12..0 dB, default -3), drive (0.5-3.0, default 1.2);
│        live-apply. `hf_clipper_*`. Added 0.35.
│
├──► Pre-encode audio limiter (L/R domain, stereo-linked oversampled, look-ahead)
│    └── True-peak limiter on L/R before stereo encoding —
│        `StereoLinkedOversampledPeakLimiter` uses a max(|L|, |R|)
│        detector so both channels receive identical gain reduction
│        (no asymmetric pumping). Default 1.0 ms look-ahead (Phase 1,
│        delay+detector primitive, US 4,208,548 prior art) so the
│        gain ramp engages before the peak reaches the gain stage.
│        Default-on Dolby HF-subband-aware detector (Phase 2, US 5,579,404
│        / EP 0685130, expired 2013) high-passes the detector at 4 kHz
│        so look-ahead engages only on HF transients (where pre-emphasis
│        concentrates peaks), leaving LF punch untouched. Audio path
│        stays full-band. Optional band-limited residual ceiling uses
│        the 33-tap / 0.25-cutoff kernel when enabled. Threshold,
│        release, residual enable, and residual kernel shape live-apply
│        via `RuntimeConfig`; look-ahead settings are restart-required.
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
│    ├── Composite clipper (16x oversampled tanh soft-clip, delta-based
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
├──► Monitor path (optional)
│    └── Demodulated L/R for headphone monitoring
│
└──► Processed-audio output (optional, `processedAudio` mode)
     └── Post-pre-encode-limiter stereo L/R (no composite/pilot/RDS), for
         feeding an external stereo coder. Skips composite assembly entirely;
         runs at the audio device rate (e.g. 48 kHz). Pre-emphasis selectable.
```

## Output modes

`AudioOutputMode` (`AudioOutputEngine.swift`) has three cases; the engine resolves
which to use at `start()` from config and routes the render callback accordingly.

- **`mpxComposite`** (default): the per-sample render is `processSampleDetailed`
  -> `processAudioDomain` (audio half) -> `processMPXDomain` (stereo encode,
  composite clipper, BS.412, pilot/RDS injection). Output device runs at the
  configured MPX rate (>=110 kHz required, 192 kHz standard so the 57 kHz RDS
  sideband is representable). This is the canonical FM-composite path.
- **`monitorAudio`**: generates the composite internally and demodulates it back to
  L/R via `MPXDecoder` for headphone monitoring on a second device. Low-latency
  IIR filtering (Butterworth encoder lowpass, LR4 multiband). A listening aid, not
  the on-air signal.
- **`processedAudio`** (0.33): emits the processed stereo L/R after the pre-encode
  limiter and **skips `processMPXDomain` entirely** — no stereo encode, composite
  clipper, BS.412, pilot, or RDS. Render path `renderAudioOnly*` calls
  `processAudioDomain` directly (dual-rate boundary forced off; whole engine runs
  at the audio device rate, typically 48 kHz). The composite path is byte-identical
  to before — the audio-only path simply branches off the existing `preMPX` tap.
  Two audio-domain stages still run for output quality: the encoder lowpass FIR (the
  15 kHz band-limit) and the FIR multiband crossovers. The post-limiter level is
  normalized so the binding ceiling maps to ~0 dBFS times the operator output gain.
  Pre-emphasis is selectable (`preemphasis_us`); an optional final loudness clipper
  (a dedicated `DistortionCancelledClipper` instance driven by
  `processed_audio_final_clip_drive_db`) engages only when the operator marks the
  external coder as having no clipper of its own
  (`processed_audio_coder_has_clipper = false`) — the one-clipper rule, mirroring
  pre-emphasis ownership. Config: `processed_audio_output` (restart-required). The
  UI hides every composite/RDS surface in this mode (RDS section, Composite Clipper
  / BS.412 / Final Stage tabs, pilot level, deviation/modulation meters, MPX
  Spectrum + Scopes windows, composite signal-flow pills).

## Major Components

The SPM package (`macOS/Package.swift`) has five targets: **`MPXPrime`** (the encoder executable — UI, engine, generator, config), **`MPXPrimeMeter`** (the companion receive/analyze executable — captures an MPX composite from an audio device or RTL-SDR and decodes stereo + RDS in a SwiftUI dashboard; shipped since 0.37), **`MPXPrimeCore`** (a shared DSP library: `MPXDecoder`, `RDSStreamDecoder`, `DSPPrimitives` — depended on by both executables; hot per-sample `process()` methods are `@inlinable` so they inline across the module boundary), **`MPXPrimeUI`** (shared Canvas-based SwiftUI components — scope, spectrum, vertical meter, vectorscope, trend, style tokens, the `LiveTelemetryView` isolation wrapper — used by both apps), and **`MPXPrimeNative`** (a tiny C target, `MPXPrimeNative.c`, that sets the FTZ/DAZ denormal-handling CPU flags on the audio thread). The file list below notes each file's target.

- `main.swift`: CLI entry point, config loading, audio engine lifecycle. Verifier modes: `--verify`, `--verify-presets`, `--verify-long`, `--verify-receiver` (0.27), `--verify-composite-multiband` and `--verify-multiband-coupling` (0.28). 0.36 extended `--verify-receiver` with composite-clipper guard-band cancellation depth (pilot 17-21 kHz / RDS 55-59 kHz) and a pilot/RDS phase-lock drift gate, added a 4x-oversampled true-peak (BS.1770-style) inter-sample-overshoot metric to `--verify`, and bumped the `--baseline-strict` baseline to schema 3 (adds the true-peak field plus a global encoder-side sideband fingerprint — asymmetry + side/mono delta at 1/10/14 kHz).
- `AudioOutputEngine.swift`: AVAudioEngine output setup, render callback, transport orchestration. Delegates input capture to `InputAUHAL`.
- `InputAUHAL.swift`: Direct AUHAL (`kAudioUnitSubType_HALOutput`) input-capture wrapper. Replaces a second `AVAudioEngine` instance the engine used to spin up for input — AVAudioEngine's first `start()` with a non-default input device intermittently failed to deliver tap callbacks. The two-AUHAL pattern (separate input AU + output AVAudioEngine + `StereoInputRingBuffer` as the only bridge) is what TN2091 / CAPlayThrough / Stereotool / AudioKit's non-default-device path use on macOS.
- `MPXGenerator.swift`: Real-time MPX/DSP generation, RDS encoding.
- `MPXDecoder.swift` (0.27, PLL refactor in 0.28): Reusable FM-stereo demodulator. Used both by the audio render callback for monitor output (with the internally generated, delay-aligned 38 kHz reference) and by the offline verifier (with a pilot-PLL recovered reference). 0.28 replaced the bandpass + phase-discriminator PLL with an I/Q coherent lockin demodulator — slow IIR-smoothed estimates of `mpx · sin(ω_p · t)` and `mpx · cos(ω_p · t)` at the local oscillator, then the doubled-phase subcarrier is recovered via trig identities. Effect: external-style PLL decode now matches synthetic-reference coherent decode within 0.1 dB at every test tone. Includes a smoothed noise gate and a stereo-collapse cooldown that re-initialises the PLL if it ever drifts off-lock. Lives in the `MPXPrimeCore` SPM target (shared by the transmit app and the verifier; the hot `process()` is `@inlinable` so it still inlines across the module boundary). 0.36 added non-finite-input sanitization at the top of `process()` — a single NaN/Inf sample used to permanently poison the pilot-lock I/Q and envelope state (the exponential smoothers never flush NaN and the self-heal could not re-arm).
- `RDSStreamDecoder.swift` (MPXPrimeCore, 0.31): Symmetric receive-side RDS decoder — the counterpart to `BasicRDSCoder`. Operates on recovered RDS data bits (differentially-decoded 1187.5 bps stream): BCH offset-word block synchronization, CRC-checked group assembly, and PI/PTY/TP/TA/MS/DI/PS field accumulation. Exports public `RDSGroup` / `RDSReceiverState`. Used by the offline verifier and the `MPXPrimeMeter` analyzer app; round-trip tested against `BasicRDSCoder`.
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

Within the main audio path, MPX Prime Studio runs:

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
18. Pre-emphasis-aware HF clipper (L/R domain, oversampled, optional, default-off; clips only the pre-emphasised high band so the broadband limiter doesn't dull the whole signal; configurable crossover ~5 kHz / threshold / drive; live-apply; added 0.35)
19. Pre-encode audio limiter (L/R domain, `StereoLinkedOversampledPeakLimiter` — `max(|L|, |R|)` detector drives both channels identically; 0.30: default-on look-ahead with Dolby HF-subband-aware detector per `US 5,579,404`)
20. Stereo encoder (M/S encoding, 38 kHz DSB-SC subcarrier)
21. Composite clipper (16× oversampled tanh soft-clip with differential topology + linear-phase FIR decimation + delta-based per-band substitution for pilot / stereo / RDS guards; vvtanhf-batched; optional OS-rate sliding-window-max look-ahead)
22. Audio composite bandwidth FIR (linear-phase HF cleanup before pilot/RDS injection)
23. BS.412 MPX power limiter (60s rolling average, optional, EU compliance)
24. Final-MPX safety limiter (audio composite only)
25. Composite budget governor (smoothed gain ride on audio path so post-injection clamp is unreachable for sane configs)
26. Pilot and RDS injection (post-clipper, constant amplitude, delay-aligned via `subcarrierDelayLine`)

Most optional stages are disabled by default and can be enabled via config/UI. The default processing chain intentionally ships with multiband, bass clipper, composite clipper, pre-encode limiter, final MPX safety, encoder FIR, and multiband FIR enabled per `AppConfig`.

When `Mono Mode` is enabled, MPX Prime Studio suppresses the pilot, stereo subcarrier, and RDS injection so the transmitted composite is true mono.

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

### Multiband Transient-Aware Attack (0.28, optional)
`multiband_transient_aware_attack_enabled` keeps the legacy peak detector as the default. When enabled, `MonoCompressor` runs an RMS envelope (10 ms attack / 90 ms release) alongside the peak follower; the peak-to-RMS ratio drives a transient indicator that triggers when peak rises above 1.65× RMS, latched for 10 ms. On a transient the detector blends mostly RMS (peakWeight drops 0.58 → 0.18) and the attack coefficient stretches to 3.2× the base attack — kick/snare fronts pass hotter than the classic peak-only detector while sustained content converges back near the classic level. Matches Optimod "Smart Attack" character. `MultibandPhase2Tests` covers transient-burst vs classic, sustained convergence, and runtime-config flag propagation. Wired through both 3-band and 5-band compressor pairs via `configureCompressorPair`.

### Multiband Inter-Band Coupling (0.28, optional)
`multiband_inter_band_coupling_enabled` keeps the default chain unchanged when off. When enabled, low-band gain reduction is smoothed with a 20 ms attack / 300 ms release control envelope and converted into small negative threshold biases for upper bands. In 3-band mode the current mapping is `midBiasDB = -0.15 * lowGR` and `highBiasDB = -0.25 * lowGR`; in 5-band mode the biases are -0.10 / -0.15 / -0.22 / -0.25 times the low-band GR for bands 2-5. This is an Optimod-style tonal-glue control law: heavy bass control makes mids/highs slightly more controlled without applying one wideband gain ride. `MultibandInterBandCouplingTests` covers runtime plumbing, arithmetic ratios, zero-bias transparency, and increased upper-band control under bias. `--verify-multiband-coupling` performs the program-material A/B gate with multiband forced on and AGC off for isolation.

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
Oversampled tanh soft-clipper on the audio composite, sitting after the pre-encode audio limiter and before BS.412 / final-MPX safety limiter. The oversampling factor is operator-selectable across {8, 16, 32} via `mpx_clipper_oversampling` (default 16; restart-required) — 8× for CPU-constrained hardware, 16× for industry-standard parity (Optimod 8X00 / Omnia.11 / Stereotool default), 32× for Omnia.9-class spec-sheet defence at roughly double this stage's CPU cost. Numbers in the rest of this section assume the 16× default unless stated otherwise; tap counts, batch sizes, and internal rates scale linearly with the active factor. Since 0.11 this is the **only** non-linearity on the audio composite — the prior `CompositeTruePeakLimiter` (memoryless tanh on `|composite|` peak detection) was deleted because its IM bled into the 38 kHz stereo sidebands and demodulated as `(L−R)` cancellation. As of 0.20 the clipper runs the **differential topology** of Orban US 6,337,999 (expired 2022, public domain): only the *clipping residual* (input − clipped) goes through decimation, while the wanted signal rides a 1× delay-matched bypass and the residual is subtracted at the output. The decimator's stopband leakage and any phase non-flatness now only colour the residual subtracted at output, not the wanted (L−R) sideband content. Decimation itself uses `LinearPhaseFIRDecimator` (Kaiser-windowed sinc, ~147 taps, `vDSP_dotpr` polyphase, ≥90 dB stopband, flat passband 0–53 kHz) — replaces the prior `BiquadCascade6` 12th-order Butterworth which had ~70-80 dB stopband and 1-2 dB rolloff at the upper subcarrier edge. Cost: ~9 host samples (~47 µs at 192 kHz) of TX-path latency. The clipper does double duty: peak control plus loudness, the same role Orban's "Half-Cosine" / "Smart Clipper" stages play in the 8500/8600 line.

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

Soft-clip via `vvtanhf` (vForce SIMD) batched in 16-element groups (one batch per host sample at 16× OS): per OS-step the upsampled inputs are pre-computed into a batch buffer, the tanh is run as a vector op, then the per-OS-step state-dependent work (linear-phase FIR decimation push, bandpass updates) runs sequentially. At batch=16 `vvtanhf` is ~9× faster than scalar `tanhf` per call — see `TanhBatchSizeBench` for the curve; this partially offsets the doubled per-host work the 16× OS rate would otherwise impose on the soft-clip stage. The FIR convolution itself runs through `vDSP_dotpr` for the polyphase commutator path.

Topologically inspired by three expired Orban patents: US 4,460,871 (1984) introduced the delta-cancellation primitive on a single audio band; US 5,737,434 (1998) layered it across multiple guard bands for FM composite; US 6,337,999 (1998 / expired 2022) added the differential-clipper topology where only the residual is decimated. Per-band RBJ bandpass implementation, the linear-phase FIR decimator, and the `vvtanhf`-batched 16× oversampled core are project-specific.

Live-apply via `RuntimeConfig`. INI keys `mpx_clipper_enabled`, `mpx_clipper_threshold_db`, `mpx_clipper_ceiling_db`, `mpx_clipper_cancel_audio`, `mpx_clipper_cancel_pilot`, `mpx_clipper_cancel_stereo`, `mpx_clipper_cancel_rds`, and (0.26) `mpx_clipper_lookahead_ms`. The legacy `composite_clipper_enabled` key (which used to control the now-deleted composite *limiter*) was removed in 0.11 — see the Verification.ini key-collision warning in AGENTS.md.

**Look-ahead peak control (0.26, optional).** When `mpx_clipper_lookahead_ms > 0`, an OS-rate (3.072 MHz at 192 kHz × 16) sliding-window-max detector with Lagrange-interpolated intersample peak detection feeds a gain envelope smoothed by a 200 Hz one-pole LP. The gain is applied identically to both the clipper's `up` input and the per-band `orig*` filters, so the differential-topology cancellation linearity holds. A separate `lookaheadGainReductionDB` telemetry value distinguishes clean predictive ducking from soft-clip distortion-producing GR on the meter. Single INI knob; attack/release/smoother cutoff are hardcoded (exponential attack tied to the look-ahead window, ~80 ms release, 200 Hz smoother). 0.0 disables (default); 2.0 ms is the recommended value for loudness-priority presets. Algorithmic primitives — Lemire monotonic deque (sliding-window max), half-cosine attack LUT (US 6,434,241, expired 2014), 200 Hz gain-modulation smoother (US 5,737,434, expired ~2017) — are expired or public-domain.

**Multiband composite clipping (experimental, off by default).** `mpx_multiband_clipper_enabled` inserts `CompositeMultibandClipper` after the broadband composite clipper and before the audio-composite bandwidth FIR. It uses two `LinearPhaseFIRLowpass` instances with shared tap count to form low, mid, and high composite bands (`LP180`, `LP4200 - LP180`, delayed input minus `LP4200`), clips each band independently (current fixed ceilings: low 0.90, mid 0.62, high 0.38), then recombines. Its group delay is included in `recomputeSubcarrierDelay()` only when enabled, while delay-line capacity is reserved at configure time so live toggling does not allocate on the audio thread. `--verify-composite-multiband` A/Bs dense/HF verifier scenarios with the toggle off/on. This is a loudness experiment, not a preset default: it still needs dense-program listening before any shipped preset uses it.

`CompositeClipperCrossDomainTests` and `CompositeClipperStereoSeparationTests` are the regression guards. The first asserts cross-domain IM drop with each guard band engaged; the second asserts that decoded L/R separation is preserved within tolerance when the stereo guard is on. `CompositeClipperLookaheadTests` covers the (0.26) look-ahead path: overshoot bound (`max(|out|) <= ceiling x 1.005` at 2 ms), steady-state transparency on pink noise, pilot/stereo/RDS guard regression with look-ahead engaged, cross-domain cancellation regression (catches asymmetric per-band gain leak), and total-delay reporting. `CompositeMultibandClipperTests` covers the 0.28 experimental multiband clipper: runtime flag plumbing, delay accounting, below-threshold reconstruction, finite peak reduction on hot signal, enabled-chain sideband symmetry, and HF-edge A/B benefit; `DSPThroughputTests.compositeMultibandClipperCostStaysBounded` guards relative real-time cost. Together they catch regressions in cancellation depth, over-cancellation that would collapse the stereo image, look-ahead detector / gain-application asymmetry, latency-reporting drift, and experimental multiband loudness cost.

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

- **Transmit / processed-audio (`mpxComposite` / `processedAudio`)**: Kaiser-windowed linear-phase FIR with ~80 dB stop-band attenuation. Tap count is derived from sample rate to maintain ~1.5 kHz transition at 15 kHz cutoff (≈641 taps at 192 kHz, ≈160 taps at 48 kHz). Group delay ~1.67 ms. The steep roll-off prevents downstream nonlinear stages (DC clipper, composite clipper) from re-broadening audio content into the 19 kHz pilot region, bringing DC-clipper aliasing from ≈-38 dBFS (Butterworth) to below -75 dBFS. In processed-audio output this same FIR is the 15 kHz band-limit on the L/R feed.
- **Monitor mode (`monitorAudio`)**: 12th-order Butterworth cascade (six biquads). ~0.2 ms latency, ~13 dB attenuation at 17 kHz. Intentionally shallower for low-latency live monitoring. The monitor is documented as "an idea of how it would sound" — the transmitted composite uses the FIR.

The choice is resolved once per engine start by `AudioOutputEngine.start()` via `MPXGenerator.setEncoderFIREnabled(_:)` (enabled for everything except the low-latency monitor). Both filters remain configured so toggling output mode on engine restart is immediate. The AppConfig `encoder_fir_enabled` flag allows bypassing the FIR entirely (defaults to true).

`DSPThroughputTests.preEmphasisDoesNotExplodeFullChainCost` and `EncoderBandwidthTests` guard this stage: the former catches any regression in the combined limiter+encoder cost on HF-rich program, the latter characterises the FIR's stop-band depth directly and asserts a ≥20 dB gap over the Butterworth baseline.

## RDS encoder (`BasicRDSCoder`)

### Origin and scope

The block-level bit encoder — `crc` / `withCheckword` / `buildGroupBits` and the B1/B2/B3/B4 layout — was initially ported from the Python `RDSHelper` in [ryanginn/rds-master](https://github.com/ryanginn/rds-master). The CRC polynomial (`0x5B9`), offset words A/B/C/D, the `(groupType << 12) | (versionB << 11) | (tp << 10) | (pty << 5) | b2Tail` B2 composition, and the segment-counter patterns in Group 0 (mod 4, DI bit) and Group 2 (mod 16, A/B flag) all follow the Python implementation's structure. The Cp offset value diverged during the port (Python uses `0x350`, this implementation uses `0x1E0`).

Everything else in this section — the 1187.5 bit/s biphase impulse + Gaussian shaping FIR, the pilot-locked 57 kHz subcarrier generation (`nextSampleWithPilotLock`), the real-time audio-thread safety work (pre-allocated `bitBuffer`, atomic CT cache, `monotonicSeconds()` timing), the `RDSRuntimeConfig` live-apply pipeline, AF Method B encoding, RT+ ODA registration (AID `0x4BD7`, group 3A/11A), Group 4A clock-time with MJD + TZ, Group 10A PTYN, Group 15A Long PS, and Group 1A ECC/LIC variants — is MPX Prime Studio's own work and has no counterpart in the source Python project.

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
- 57 kHz subcarrier locked to 19 kHz pilot at 3:1 (`nextSampleWithPilotLock`):
  the carrier is `sin(3*theta)` recovered from the pilot oscillator's
  instantaneous `sin(theta)` (`pilotOsc.s`, supplied per sample via
  `updateRDSPilotSin`) through the triple-angle identity `3s - 4s^3`. 0.36
  replaced the prior separate additive phase accumulator, which drifted
  ~9 deg / 5 s against the emitted pilot; the `--verify-receiver` pilot/RDS
  phase-lock drift check guards against regressing it.
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

- PrimeBass adds perceived bass weight by synthesising controlled harmonics of low-frequency content, so the listener hears more bass while the chain pushes less LF peak amplitude. Saves headroom for the downstream bass clipper, pre-encode limiter, and composite clipper.
- The multiband stage uses complementary Linkwitz-Riley 4th-order stereo crossover stages. This provides clean band separation and reduces recombination smear and tonal instability when adjacent bands compress differently.
- The final MPX chain remains verification-backed. Structural cleanup there is intentionally done in small steps because even behavior-preserving refactors can change composite output measurably.
- Verification covers both composite safety and decoded-audio quality signals. In addition to the base offline verifier, a focused preset sweep exists for the main 5-band preset family (`5B AC/Pop`, `5B CHR/EDM`, `5B Rock`, `5B Talk`, `5B News`, `5B Urban`, `5B Dance`).
- All new DSP stages (phase rotator, parametric EQ, multiband limiter, downward expander, bass clipper, distortion-cancelled clipper, BS.412) are disabled by default and have zero impact on the signal chain until enabled. All support live-apply via RuntimeConfig.
