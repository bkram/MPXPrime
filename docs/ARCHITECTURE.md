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
│    │   │   share group delay — eliminates IIR-LR4 transient smear;
│    │   │   -6 dB at each crossover, transition = fc, 9.3 ms at 48 kHz)
│    │   ├── Monitor path: IIR Linkwitz-Riley LR4 crossovers (low latency)
│    │   ├── Optional transient-aware attack detector
│    │   │   (`multiband_transient_aware_attack_enabled`) blends RMS/peak
│    │   │   detection and briefly stretches attack on percussive fronts
│    │   ├── Optional inter-band coupling
│    │   │   (`multiband_inter_band_coupling_enabled`) lets low-band GR
│    │   │   gently bias upper-band thresholds
│    │   ├── Per-band downward expander (optional noise reduction)
│    │   └── Per-band fast peak limiter (optional transient control)
│    ├── Advanced Dynamics (experimental, `advanced_dynamics_enabled`):
│    │   single-stage 5-band leveler that REPLACES the wideband AGC and
│    │   the multiband compressor when on (both are bypassed) — fused
│    │   leveling + density shaping with program-adaptive time constants
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
│    └── Fixed <= 2 dB stereo-linked HF ride ahead of the encoder lowpass;
│        measured load-bearing for receiver-side HF separation (0.45)
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
│    ├── Applied L/R immediately upstream of the pre-encode limiter
│    │   so the limiter peak-controls the +10..12 dB HF-boosted signal
│    │   (canonical Optimod / Stereotool placement)
│    └── Network: `PreemphasisDesign` biquad fitted to the analog curve
│        |1 + j omega tau| (<0.05 dB to 15.5 kHz at 48 kHz; the textbook
│        matched-z zero was -1.4 dB at 15 kHz there). The decoder's
│        de-emphasis is its exact inverse. (0.45)
│
├──► HF limiter (L/R domain, gain-riding, default-ON in every profile since 0.45)
│    └── Program-controlled pre-emphasis (Orban US 4,103,243, expired):
│        rides only the pre-emphasis BOOST `pre - flat` so an overshooting
│        cymbal / hi-hat briefly loses part of its boost instead of being
│        clipped or dragging the whole mix down in the limiter below.
│        Boost-dominance guard (bass peaks leave HF alone), 1.5 ms attack,
│        5 ms hold, 20 ms release, max reduction 12 dB; live-apply.
│        `hf_limiter_*`. Added 0.45 (hi-hat / cymbal field finding).
│
├──► Pre-emphasis-aware HF clipper (L/R domain, oversampled, optional, default-off)
│    └── Waveshaper on the *pre-emphasised* high band, between pre-emphasis
│        and the pre-encode limiter. Superseded by the HF limiter above
│        (it distorts the cymbal band it controls; no profile uses it since
│        0.45) but kept as an opt-in last resort for maximum HF density.
│        Configurable crossover (3-8 kHz, default 5 kHz), threshold
│        (-12..0 dB, default -3), drive (0.5-3.0, default 1.2); live-apply.
│        `hf_clipper_*`. Added 0.35.
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
│    └── DSB-SC: S x sin(2*theta)   pilot = sin(theta), 38 kHz = 2xpilot from
│        the same recurrence. Standard polarity (47 CFR 73.322 / BS.450-3):
│        the subcarrier crosses zero with positive slope at every pilot zero
│        crossing, a receiver forms L = M + S. Pre-0.45 the encoder sent
│        (R-L)/2 and MPXDecoder negated it back -- real receivers swapped L/R.
│        MPXDecoder is now a plain textbook decoder (no sign compensation);
│        StereoPolarityTests pin both sides against an independent decode and
│        --verify-receiver scores separation against the DRIVEN channel.
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

## Test tone (calibration source)

When the engine renders the built-in test tone (`source_mode = tone`), `MPXGenerator` raises `renderingCalibrationTone` for each tone sample: `processProgramStereo` / `processAudioDomain` skip input gain and every dynamics / enhancement / clipping / limiting stage (the same gates `processingBypass` uses, plus the encoder HF guard), pre-emphasis and the encoder lowpass stay in (noise types need the band limit), and in `processFinalComposite` the drive is replaced by the audio-composite budget so 0 dBFS = 100% audio modulation, BS.412 is skipped, and the composite clipper and final limiter are kept in the path only for their delay (their inputs are scaled 8x below threshold so they pass the tone untouched and pilot/RDS alignment is preserved). Sine tones are pre-compensated for the pre-emphasis magnitude at the tone frequency (`updateToneGain`, the analog curve `sqrt(1 + (2 pi f tau)^2)`, which the fitted pre-emphasis network matches). Pinned by `TestToneGeneratorTests`: composite peak = budget x 10^(level/20) within 0.25 dB across 0 / -6 / -20 / -40 dBFS, independent of Final Drive / AGC / processing, flat across 400 Hz / 1 kHz / 10 kHz, equal across mono / left / L=-R routing; the input path is checked to still respond to Final Drive.

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
  at the audio device rate, typically 48 kHz -- `setAudioOutputOnly` re-derives
  EVERY audio-domain stage for that rate when it switches the boundary off; until
  0.45 nothing was re-derived and pre-emphasis / limiters ran 48 kHz coefficients
  at the output rate in this mode). The composite path is byte-identical
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

The SPM package (`macOS/Package.swift`) has (on macOS) eight non-test targets: **`MPXPrime`** (the encoder executable — UI, engine, generator, config; ships universal), **`MPXPrimeMeter`** (the companion receive/analyze executable — captures an MPX composite from an audio device or SDR and decodes stereo + RDS in a SwiftUI dashboard; shipped since 0.37. **Apple-Silicon-only**, because it links the arm64 RTL-SDR libraries below; build the x86_64 release slice with `--product MPXPrime` to skip it) The tuner keeps TWO rates: a **capture rate** (the IQ the device delivers, set by `iq_rate_khz`) and a **demod rate** (250 kHz SDRplay / 256 kHz RTL) that the FM demod chain always runs at, bridged by a polyphase `ComplexDecimator`. Only the capture rate changes when the operator widens the **RF spectrum** span, so a wider capture cannot move any MPX measurement. At the narrow setting the decimation factor is 1 and both backends are byte-identical to the pre-split path -- the RTL branch explicitly keeps its original packed-uint8 `processSplit` call there, because the complex path reproduces neither its normalization LUT nor its raw-byte saturation detection. The RF spectrum itself is a 1024-point Hann-windowed complex FFT of the wide IQ, computed on the capture thread at ~20 frames/s, fftshifted to dB bins and published under a mutex via `mpxtuner_rf_spectrum()`; `RFSpectrumView` (MPXPrimeUI) plots it against the tuned centre frequency with a 100 kHz-raster grid, selected by the **MPX | RF** switch in the spectrum card header (SDR only)., **`MPXPrimeCore`** (a shared DSP library: `MPXDecoder`, `RDSStreamDecoder`, `DSPPrimitives`, plus the Meter's measurement engine `MeterAnalysis` + `MeteringPrimitives` — moved here from the executable so the metering math is unit-testable; depended on by both executables; hot per-sample `process()` methods are `@inlinable` so they inline across the module boundary), **`MPXPrimeUI`** (shared Canvas-based SwiftUI components — scope, spectrum, vertical meter, vectorscope, trend, style tokens, the `LiveTelemetryView` isolation wrapper — used by both apps; each live Canvas view disables implicit animations via `.transaction { $0.animation = nil }` so 25 Hz repaints don't queue frame-interpolation transactions that accumulate into GUI lag), **`MPXPrimeNative`** (a tiny C target, `MPXPrimeNative.c`, that sets the FTZ/DAZ denormal-handling CPU flags on the audio thread), **`MPXPrimeRecording`** (a pure-Foundation library — `CanonicalWavWriter` + `MeterRecorder` — so the Meter's WAV recording path is unit-testable without importing the executable), and **`CMPXTuner`** (the vendored RTL-SDR / SDRplay -> FM demod -> MPX tuner compiled as a C++ library with a pure-C ABI `mpx_tuner_capi.h`; thin shims in `Sources/CMPXTuner/` include the canonical sources in repo-root `tuner/`, links Homebrew librtlsdr + liquid-dsp and — when the SDRplay SDK is present at build — the dlopened SDRplay API, depended on only by `MPXPrimeMeter`). `MPXPrimeAcceleration` (present on both platforms) is the platform acceleration shim: on macOS it compiles to an empty module and DSP code links the real Accelerate / os frameworks; on Linux it provides same-name, same-signature implementations of the small vDSP/vForce surface the encoder uses (dotpr/conv/reductions/vector ops, Hann window, packed-real FFT `vDSP_fft_zrip` with vDSP's exact packing and 2x forward scaling, `vvtanhf`) plus an `OSAllocatedUnfairLock` polyfill over a priority-inheriting pthread mutex. A golden fixture captured from real Accelerate on macOS (`AccelerateShimTests`, `MPXPRIME_CAPTURE_GOLDEN=1` to regenerate) pins the shim's numerics. The file list below notes each file's target.

**Linux CLI port (milestone 1):** the same manifest builds the `MPXPrime` executable on Linux (`#if os(Linux)` at manifest level) with targets `MPXPrime`/`MPXPrimeCore`/`MPXPrimeNative`/`MPXPrimeRecording`/`MPXPrimeAcceleration`/`CAlsa` (libasound system library). GUI, Meter, and tuner targets are macOS-only; GUI/CoreAudio source files carry whole-file `#if os(macOS)` wraps. The Linux runtime replaces `AudioOutputEngine` with `ALSAAudioEngine.swift` (`#if os(Linux)`): a blocking-write ALSA playback thread pulls `StereoInputRingBuffer` -> `MPXGenerator.render*` -> interleave/convert (FLOAT_LE -> S32_LE -> S16_LE negotiation) -> `snd_pcm_writei` with `snd_pcm_recover` xrun handling, and a capture thread feeds the same lock-free ring from `snd_pcm_readi`; both threads request SCHED_FIFO best-effort and enable FTZ/DAZ. Device names are ALSA PCM strings carried in the same `input_device_uid`/`output_device_uid` INI keys. The verifier gates run identically on Linux; strict baselines are per-platform (`verifier_baselines/default-linux-x86_64.json` vs macOS `default.json`) because Glibc libm and the shim's SIMD tanh differs from Apple libm + vvtanhf at rounding level.

The Meter's SDR input runs **in-process**: `SDRLibraryInputSource` opens the dongle through `CMPXTuner` (`mpxtuner_open`), and the library's capture+demod thread delivers float MPX blocks (1.0 == 150 kHz, the -6 dB headroom) straight to the engine's `frameSink` — no subprocess, no FIFO, no int16 WAV round-trip. Live controls (frequency, IF bandwidth, gain / auto gain, PPM, Bias-T, RTL2832 digital AGC) enqueue commands applied on the capture thread between IQ blocks, so they never interrupt the stream. `mpxtuner_list_devices` enumerates attached units across both backends (name + serial); `MpxTunerConfig.backend` / `device_serial` pin a specific unit (multi-RSP / multi-RTL benches; the Meter persists the choice by serial and offers an SDR picker when more than one unit is attached, plus a live-apply monitor Output picker so two app instances can meter two stations). The standalone `tuner/` CMake executable (`mpx-tuner`) still builds for CLI debugging but is no longer shipped; the in-process backend is GUI-only, so a headless terminal SDR readout means piping an external `fm-sdr-tuner`/`mpx-tuner` composite into `./run-meter.sh --stdin`. `run-meter.sh` is the single launcher (the old `run-meter-sdr.sh` was folded in once SDR went in-process and the GUI auto-detects a dongle; `--sdr-freq <MHz>` opens the GUI pre-tuned). The SDR deviation scale is **math-absolute** (set by the discriminator's kHz-per-sample, independent of tuner gain/AGC), so it needs no calibration — only the audio-device path is pilot-referenced (unknown analog gain).

Further Meter runtime behavior (0.41 cycle): an **MPX pass-through** duplicates the raw composite into its own ring and plays it via a second `MeterMonitor` to a user-chosen device with a 0..+12 dB gain (the device's nominal rate is forced to the capture rate while active and restored after — a 48 kHz output would SRC away the subcarriers); a **decode-path DC blocker** (2 Hz `DCTracker`, live-toggleable checkbox, default on) sits ahead of `MPXDecoder` only — a transmitter carrier offset becomes DC after demod (off-center vectorscope, DC in monitor/recordings); pilot PLL, RDS decode, composite scope, and the always-tracked measurement path are unaffected. The frequency field takes **1 kHz resolution** (audio links sit off the broadcast raster; numeric fields clamp but never snap typed values to the scroll step). The vectorscope's display gain **auto-rides the program level** (fast shrink / slow release toward ~85% field fill; smoothed on the VM, delivered via telemetry). **SIGTERM is routed through `NSApp.terminate`** so scripted kills release the SDRplay selection and RTL handle — an unclean kill leaves the SDRplay service ghost-holding the RSP for a dead PID (unit vanishes from enumeration until replug); a device-lost RTL handle is deliberately abandoned rather than closed (`rtlsdr_close` writes registers over USB and SEGVs on a dead handle; the abandoned unit's USB claim persists until replug or app exit, and the status line says so).

**Meter measurement engine** (`MeterAnalysis` + `MeteringPrimitives`, MPXPrimeCore; rewritten post-0.38 against ITU-R SM.1268-5 / BS.412-9 and instrument practice, with a deterministic test suite `MeterAnalysisTests` that synthesizes composites of exactly-known deviation and asserts the readings): the deviation/MPX-power path is DC-tracked (sub-Hz one-pole; fast 5 Hz acquisition during the 1 s warm-up — an SDR carrier offset otherwise skews +/- peaks apart) and band-limited to 60 kHz with a **linear-phase Kaiser FIR** (`BlockFIRFilter`, `vDSP_conv`) — linear-phase because the previous 6th-order Butterworth IIR overshot/rang on clipped-composite edges and read deviation the transmitter never emitted; the FIR also rejects the RTL-SDR FM-demod noise triangle. Scopes/spectrum/IN stay raw. Peak statistics use **50 ms peak-hold slots** (20/s, Pira / SM.1268 heritage): MAX DEV = trailing 1 s max, PEAK +/- = trailing 60 s max (self-recovering; impulses age out instead of latching until reset), plus the **SM.1268-5 sec 4 compliance statistic** — % of deviation samples above 77 kHz (75 + 2 kHz tolerance; the recommendation's violation criterion is 10^-4 %). MPX power is a **uniform sliding 60 s window** (ring of 1 s mean-squares, sample-exact slot rolls, oldest slot complement-weighted against the current partial second so the window is exactly 60 s at any instant — BS.412's "any interval of 60 s", matching the transmit-side `BS412PowerLimiter`'s ring-buffer approach, not an EMA), with a max-over-placements readout (MPX MAX) since compliance is judged on the worst window. RDS deviation is measured **coherently**: quadrature mix at 57 kHz -> 6th-order Butterworth 3 kHz anti-alias on I/Q -> decimate to ~12 kHz -> linear-phase FIR (2.6 kHz pass / 3.6 kHz stop) -> in-band RMS `2*sqrt(E[|z|^2])` scaled by the **EN 50067 shaped-biphase peak/RMS form factor** (`shapedBiphasePeakOverRMSSqrt2` = 1.320, a constant of the spec's cos(pi*f*td/4) pulse shaping, measured from the spec-exact BasicRDSCoder). The displayed value is the **peak deviation of the subcarrier -- the injection level the encoder was set to** (the industry display convention: encoders peak-normalize the shaped waveform, EN 50067 sec 1.3's +/-1.0..7.5 kHz range is a peak range, FCC/NRSC budget injection as peak deviation, and Inovonics/R&S/Pira instruments read/set peak -- R&S K7S's factory default detector is +/-Peak/2). Deriving it from the RMS rather than a raw envelope-peak detector matters off-air: a raw RMS reading sits ~24% LOW on shaped biphase (the 0.39 under-read -- the envelope dips through zero at symbol transitions), while a raw PEAK detector rides composite-clipper intermod inside the 57 kHz window on heavily-processed stations (measured 2.5-3x over-read, unsteady; R&S 7BM105 documents the same PK-under-noise bias). RMS + spec form factor reports the peak-convention number with power-domain (quadratic, not linear) sensitivity to in-band IM/noise. The encoder round-trip test (`encoderRoundTripReadsTheSetInjection`: set 2.0 -> read 2.0, guard > 1.85) pins the convention; note an UNMODULATED 57 kHz test carrier deliberately reads its amplitude x 1.320 (the calibration target is spec-shaped data, not a bare tone). 53 kHz stereo-difference energy is rejected > 85 dB where the old single Q=10 biquad leaked it into the reading. The **pilot-to-RDS subcarrier phase** (EN 50067 sec 1.2 -- the angle to the third harmonic of the pilot, which the standard requires to be 0 or 90 deg +/- 10) is measured by `PilotRDSPhaseMeter`: one free-running 19 kHz NCO supplies both references (the 57 kHz one via the triple-angle identities, so they are phase-coherent by construction), each driving an **identical** `QuadratureLockInChain`, and the answer is `phi_rds - 3*phi_pilot`. The chains are identical on purpose, not for tidiness: the NCO never sits exactly on the pilot (transmitter +/-2 Hz plus capture-clock ppm), so both baseband phasors rotate -- the 57 kHz one three times faster -- and mismatched filter group delays would turn that into an error of `3w(tau_p - tau_r)` (2 Hz through a 2.5 ms mismatch = 5.4 deg, half the spec window); matched chains cancel it identically, with no frequency estimator or loop. Reusing `PilotPLL` here would NOT work -- its 20 ms lock-in is unmatched and 0.5 Hz of offset alone would bias the reading ~11 deg. The BPSK 180 deg ambiguity of the suppressed-carrier subcarrier is removed by squaring (Viterbi & Viterbi m=2) before a ~2 s average, so the result is known modulo 180 deg and is folded to an unsigned 0..90 (0 = in phase, 90 = quadrature -- folding also avoids a signed reading flickering between +90 and -90 on a quadrature station). Validity needs all three of pilot presence, a coherence (`|E[z^2]|/E[|z|^2]`, which is exactly the in-band SNR) at or above 0.3, and at least 0.8 kHz of RDS -- the level gate is NOT redundant, since coherence is scale-free and the residual pilot leakage into the 57 kHz chain is perfectly coherent, so a station with no RDS reads a confident angle on ~0.01 kHz of leakage without it. `MeterRDSPhaseTests` pins the conventions (0 / 90 / anti-phase / 45), the offset immunity, the 53 kHz rejection, both gates, and an encoder round-trip, plus an accuracy contract stated against the instrument the readout is modelled on -- the Pira P175/P275 specifies +/- 4 deg for this measurement, and the sweep test requires under 1 deg across 0..90 (measured worst case 0.12 deg clean, 0.00 deg under a 10 Hz pilot offset, 0.14 deg at the 0.8 kHz gate floor). The display conventions deliberately match Pira's too (unsigned 0..90 fold, +/- 10 deg tolerance, blank when the phase relation is not stable): MPX Prime Studio derives its 57 kHz carrier from the emitted pilot's recurrence via the same triple-angle identity, so it must read in phase. MPX power remains only trustworthy on a strong, clean, multipath-free signal (weak/noisy reception inflates both peak deviation and MPX power). Alongside MAX DEV the same trailing-1 s slot array yields **AVE** and **MIN** (the in-progress slot is excluded -- it has seen only part of its 50 ms and would drag both down); MAX far above AVE is a peaky, lightly-processed signal. The slots also feed a **deviation histogram**: 1 kHz bins over 0..120 kHz plus an overflow bin, accumulated since the last peak reset and binned with the previous block's kHz scale (the same one-block lag as the exceedance threshold), from which `devDistributionAtOrAbove(kHz)` gives the accumulated distribution and `devHistogramMaxKHz` the highest bin ever filled. The distribution is the metric a single MAX number cannot substitute for -- it answers "how much of the programme reaches the limit" -- and wants 15-60 minutes of programme to be representative. Three further quantities come free from the existing measurement path: **carrier offset** (the DC tracker's estimate scaled to kHz -- an FM demod turns a transmitter carrier offset into composite DC), **baseband noise** (the exact complement of the 60 kHz measurement FIR, recovered as `delayed - filtered` through a delay line of the FIR's own group delay, which is phase-exact and cheaper than a second FIR; nothing is legitimately modulated above 60 kHz so it is demod noise and interference), and from it a 0..4 **signal quality** scale on fixed noise thresholds. **Stereo balance** is a heavily-smoothed (~3 s) L/R RMS ratio in dB, gated on both channels carrying signal. On the RDS side `RDSReceiverState.groupOrder` keeps the last 18 group buckets in transmission ORDER: the counts say what an encoder sends, the order shows how it interleaves them (a scheduler pattern, a starved type, one type bursting). All of these are covered by `MeterDeviationStatisticsTests` / `MeterQualityMetricsTests` and pinned against known-answer synthetic composites. The engine's headline readings were cross-validated against a Profline SFP-X measuring receiver on a live commercial station (2026-07-07): pilot and RDS matched exactly (5.6-5.7 / 3.5-3.7 kHz on both instruments), and max deviation agreed within 1-2 kHz side-by-side -- inside SM.1268's +/-2 kHz instrument accuracy requirement. When comparing peak deviation against a reference receiver, compare LIVE at the same moment: peaks are program-dependent, and reception path (multipath) inflates them.

**Meter measurement integrity** (0.45 audit, one plumbing layer per finding class): the dashboard must never present a confident number it cannot stand behind. Three signals feed it. (1) **Dropped samples** -- the composite ring between capture and analysis reports overflows and torn reads through `StereoInputRingBuffer.transportSnapshot()`, and the tuner's own IQ ring reports overwrites through `mpxtuner_iq_drops()` (added 0.45: the SDRplay ring counted nothing at all and the RTL counter was a function-local static nothing could read; retune flushes are deliberately not counted). Either one rising raises a red SAMPLES DROPPED badge, because a gap is baked into every accumulated reading -- peak-hold MAX DEV, the distribution, the BS.412 max window, the SM.1268 exceedance count -- and it stays up until Reset Peaks. (2) **Liveness** -- the frame sink timestamps each delivery, and over a second of silence while capture still claims to run raises NO INPUT (a wedged USB device keeps `alive` true, so the readings froze while looking live). (3) **Decode state** -- `MPXDecoder.stereoDecodeActive` reaches the snapshot, and a mono decode raises an amber MONO DECODE badge while separation / balance / phase correlation read `--` (`MeterAnalysis` also stops updating the separation peak-hold and the balance smoother, which would otherwise hold their stereo-era values through a lock loss). Beyond those three, every readout carries an explicit validity flag and shows `--` rather than a number it cannot justify: `peakValid` / `devScaleValid` (no kHz-per-unit scale -> the deviation strips, PEAK +/- and MPX power blank instead of reading 0.00; the pilot-referenced scale requires the SAME pilot-presence threshold the PILOT indicator uses, held ~0.4 s across a fade, where it used to be accepted from pilot amplitude 1e-5 -- 200x lower, so lock-in noise on a dead frequency produced an enormous scale and a fake max deviation with nearly every sample "over 77 kHz"), `exceedanceValid` only after a full minute (the SM.1268-5 criterion is one sample in a million; a 1 s window at 192 kHz resolves 5.2e-4 %, so `exceedanceBoundPct` publishes the supported upper bound until then), `pilotRDSPhaseValid` gated on one full averaging time constant plus a fast-vs-slow STABILITY comparison (`PilotRDSPhaseMeter.driftDegrees` <= 4 deg -- coherence primes at exactly 1.0 on its first sample and is scale-free, so it neither proves averaging happened nor that the angle stands still; both failure modes are pinned by tests), `stereoCorrelationValid` on a mean-removed Pearson coefficient gated on programme in both channels, `qualityValid` separating no-data from a measured Unusable, and an expiry on the balance smoother. Retune resets the decoder, pilot PLL and decode-path DC blocker along with the accumulators, and a calibration change (pilot reference or absolute full scale) resets the peak / exceedance / distribution / BS.412-max accumulators that were measured at the old scale. Two conventions were also made explicit in 0.45 (audit P2): the DECODE path's receiver de-emphasis is a live setting (`MeterAnalysis.setPreemphasisUS`, 50 / 75 us, persisted, an input-bar picker and the `--deemphasis` CLI flag; it was hard-wired to 50 with nothing able to reach it, so 75 us markets monitored and recorded ~3.4 dB bright at 15 kHz -- it reconfigures the decoder only on a real change, and `MeterDeemphasisTests` pins both curves against the analog formula), and `--full-scale-khz` now works on the audio-DEVICE path as well as `--stdin`, with the startup line naming the calibration convention actually in use. On the SDR side the shipped default IQ capture rate STAYS at 1000 kHz: the audit reasoned from the code that 0 (narrow) was preferable because factor 1 keeps the byte-exact packed-uint8 RTL path, but an RTL bench A/B refuted it -- at factor 1 with `bandwidth_khz = 0` nothing band-limits the IQ ahead of the FM demod, and peak deviation read +21 kHz high, RDS level +46%, baseband noise +50%, with an unstable pilot/RDS phase; at factor 4 the decimator supplies the channel filtering as a side effect, and setting an explicit 200 kHz bandwidth at factor 1 reproduces the factor-4 figures exactly (numbers in plan.md and manual-meter.md). The underlying defect -- the demod's ctor installs a +/-110 kHz IQ filter but leaves `m_bandwidthMode` at 0 unapplied, so "auto" is not the filter it appears to be -- is recorded for a decision rather than patched under one dongle's evidence. The wide path's `ComplexDecimator` went from 12 to 32 taps/phase (48 -> 128 taps at factor 4) so it is no longer the dominant channel filter inside an FM signal's +/-90 kHz Carson band, and its overload detection now shares one threshold with the packed path (`isIqSampleSaturated`, the normalized value of the innermost byte code the byte test calls saturated -- the old hard-coded 0.995f was asymmetric against the byte mapping). GUI-side (0.45 audit P3): the spectrum card's RF span chip reads a pre-formatted `rfSpanText` from telemetry INSIDE a `LiveObservationView` (reading the raw Hz in the root body re-triggered the 0.34 toolbar-relayout leak at 20 Hz in RF mode, cancelling the isolation), `statusText` is a Combine subject rather than `@Published` (no body reads it, but every retune re-laid-out the window and toolbar), and the display gate polls the dashboard window's own occlusion instead of an arbitrary `NSApp` window. The decoded monitor and the MPX pass-through drain their rings through `readAdaptive` (their producer is the capture/SDR clock, so a plain read drifted into an underrun click or a saturated ring), a monitor device swap no longer tears down the independent pass-through player, and both players report a start failure instead of swallowing it. Teardown ordering is fixed on both sides of the C ABI: the engine's `deinit` stops the input before freeing the buffer the capture callback writes, `SDRLibraryInputSource` has a `deinit { stop() }` (the tuner callback holds an unretained pointer), and `mpxtuner_close`/`_fast` wait for the capture thread's own acknowledgement with a deadline -- on a miss they detach and deliberately leak the tuner rather than freeing state it still dereferences. Stop and device loss run `MeterTelemetry.reset()` so nothing on screen outlives the capture that produced it, and capture refuses to start below 128 kHz -- the measurement band is 0-60 kHz with RDS at 57 kHz, and lower rates silently excluded the stereo sidebands and counted them as noise. The recording path carries its own contract (see the WAV recorder note under "Project" in AGENTS.md): 64-bit byte counter with a clean stop at the RIFF 4 GiB limit, NaN/Inf sanitised before packing, the header patched every ~2 s so an interrupted capture stays readable, `failureReason` polled per tick to stop the recording and tell the operator why, and finalization off the caller thread.

- `main.swift`: CLI entry point, config loading, audio engine lifecycle (platform-split runtime: NSApplication + `AudioOutputEngine` on macOS, `dispatchMain()` + `ALSAAudioEngine` on Linux; verify/bench dispatch is shared). Verifier modes: `--verify`, `--verify-presets`, `--verify-long`, `--verify-receiver` (0.27), `--verify-multiband-coupling` (0.28; the 0.28 `--verify-composite-multiband` mode left with its stage in 0.45), `--verify-advanced-dynamics` (0.44), `--verify-ssb-stereo` and `--verify-hf-transients` (0.45; the latter is the hi-hat / cymbal distortion gate: receiver-side HF SINAD, HF crest loss and 15-23 kHz composite spill per chain variant -- field chain, every Format Profile, per-stage isolation rows), `--verify-stereo-guard` (0.45: sweeps the composite clipper's stereo-guard share 0...1 on the Music - Loud profile and the loaded config -- clipper / Final-MPX limiter duty, peak, deviation, 10 / 14 kHz separation, encoder-side M/S balance at 14 kHz, decoded hard-panned side/mid, ride / hat HF SINAD -- the table the `mpx_clipper_stereo_guard` default is chosen from), `--verify-final-ride` (0.45: attributes the Final-MPX limiter's duty by switching one composite-clipper candidate off per row -- guards, oversampling, knee, look-ahead, limiter, shaper -- on a hot chain and Music - Loud, printing clipper GR, limiter GR, safety-clip duty, audio-composite and true peaks). 0.36 extended `--verify-receiver` with composite-clipper guard-band cancellation depth (pilot 17-21 kHz / RDS 55-59 kHz) and a pilot/RDS phase-lock drift gate, added a 4x-oversampled true-peak (BS.1770-style) inter-sample-overshoot metric to `--verify`, and bumped the `--baseline-strict` baseline to schema 3 (adds the true-peak field plus a global encoder-side sideband fingerprint — asymmetry + side/mono delta at 1/10/14 kHz).
- `AudioOutputEngine.swift`: AVAudioEngine output setup, render callback, transport orchestration. Delegates input capture to `InputAUHAL`.
- `InputAUHAL.swift`: Direct AUHAL (`kAudioUnitSubType_HALOutput`) input-capture wrapper. Replaces a second `AVAudioEngine` instance the engine used to spin up for input — AVAudioEngine's first `start()` with a non-default input device intermittently failed to deliver tap callbacks. The two-AUHAL pattern (separate input AU + output AVAudioEngine + `StereoInputRingBuffer` as the only bridge) is what TN2091 / CAPlayThrough / Stereotool / AudioKit's non-default-device path use on macOS.
- `MPXGenerator.swift`: the real-time engine class (chain wiring, live-apply, telemetry). Stages live one-per-concern in `DSP/` (`DSPSupport`, `PeakLimiters`, `ToneShaping`, `Dynamics`, `AudioClippers`, `CompositeClipper`, `LinearPhaseFIR`, `SSBStereoEncoder`), the RDS encoder in `RDS/BasicRDSCoder.swift` (0.45 split, pure moves).
- `MPXDecoder.swift` (0.27, PLL refactor in 0.28): Reusable FM-stereo demodulator. Used both by the audio render callback for monitor output (with the internally generated, delay-aligned 38 kHz reference) and by the offline verifier (with a pilot-PLL recovered reference). 0.28 replaced the bandpass + phase-discriminator PLL with an I/Q coherent lockin demodulator — slow IIR-smoothed estimates of `mpx · sin(ω_p · t)` and `mpx · cos(ω_p · t)` at the local oscillator, then the doubled-phase subcarrier is recovered via trig identities. Effect: external-style PLL decode now matches synthetic-reference coherent decode within 0.1 dB at every test tone. Includes a smoothed noise gate and a stereo-collapse cooldown that re-initialises the PLL if it ever drifts off-lock. Lives in the `MPXPrimeCore` SPM target (shared by the transmit app and the verifier; the hot `process()` is `@inlinable` so it still inlines across the module boundary). 0.36 added non-finite-input sanitization at the top of `process()` — a single NaN/Inf sample used to permanently poison the pilot-lock I/Q and envelope state (the exponential smoothers never flush NaN and the self-heal could not re-arm). 0.45 closed the loop and gated the decode (Meter audit M1/M2/M16): the lock-in phase correction is now driven by a second-order PLL (loop bandwidth ~2 Hz, critically damped: `kp = 2 omega_n / fs`, `ki = omega_n^2 / fs^2`, integrator into the NCO step) so a pilot frequency offset no longer leaves a residual phase error — the fixed-lag correction measured 47.7 dB separation at 25 ppm and 24.8 dB at 100 ppm against 64.4 dB on frequency (an untrimmed RTL dongle's capture clock is ~100 ppm), and all three now read 64.4 dB; on-frequency decode is bit-comparable, so the stored `receiver.json` baseline did not move (`MeterDecodeIntegrityTests` pins the sweep, with a measured A/B of the tracking disabled). The pilot-lock gate became LEVEL-RELATIVE (pilot carrying at least ~2.5% of the composite mean square, tiny absolute floor for true silence) instead of an absolute magnitude that required pilot amplitude 0.02 in raw units — 100x the Meter's own pilot-present threshold, which left a 20 dB window where the decode was silently mono; `stereoDecodeActive` publishes the state so the Meter can blank the stereo-image readouts (see the Meter section) rather than presenting the mono decode as a measurement, and the reference path (Studio monitor, verifier) reports it as always active. A sub-Nyquist capture rate (no room for the 38 kHz subcarrier) now decodes exact mono instead of demodulating aliases, and two dead biquad cascades were removed from the `@inlinable` hot path.
- `RDSStreamDecoder.swift` (MPXPrimeCore, 0.31): Symmetric receive-side RDS decoder — the counterpart to `BasicRDSCoder`. Operates on recovered RDS data bits (differentially-decoded 1187.5 bps stream): BCH offset-word block synchronization, CRC-checked group assembly, and PI/PTY/TP/TA/MS/DI/PS field accumulation. Exports public `RDSGroup` / `RDSReceiverState`. Used by the offline verifier and the `MPXPrimeMeter` analyzer app; round-trip tested against `BasicRDSCoder`.
- `BandLimitedStep.swift` (0.27): Allocation-free BLEP/BLAMP correction helper for the US 6,937,912 anti-aliased clipping work. Detects fractional threshold crossings and schedules normalized finite correction windows in impulse / step / ramp shapes.
- `AcceleratedBandlimitedResidualClipper.swift` (0.27): vDSP-accelerated patent-style residual-bandlimiting candidate clipper (hard-clip → bandlimit the residual → reconstruct as delayed-clean + filtered-residual). Wired as the inner kernel of `OversampledPeakLimiter` / `StereoLinkedOversampledPeakLimiter` behind the off-by-default `pre_encode_bandlimited_residual_enabled` opt-in.
- `AppConfig.swift`: Configuration model, INI parsing/serialization.
- `MPXPrimeViewModel.swift` + `AppDelegate.swift` + `UI/*.swift`: SwiftUI views and state management (0.45 split of the former `SwiftUIControlApp.swift`: navigation model, root views, monitoring dashboard, processing tabs, settings/RDS tabs, help/about, shared controls). `VerificationHarness.swift` + `Verification/*.swift`: the offline verifier, one file per mode.
- `AudioDevices.swift`: CoreAudio device enumeration; resolves UIDs to `AudioDeviceID`s and provides the `defaultInputDeviceID()` helper AUHAL needs (AUHAL requires an explicit device, unlike AVAudioEngine which inferred the default implicitly).
- `INIParser.swift`: INI file read/write.

## Remote control plane

An embedded Hummingbird 2 HTTP server (`Control/ControlServer.swift`, default
off via `[CONTROL]`) exposes REST endpoints plus a self-contained web
dashboard. All routes speak to a `ControlBackend` protocol with two
implementations: `HeadlessControlBackend` (an actor owning AppConfig + engine
lifecycle for `--nogui` on macOS and Linux; API restarts rebuild
generator+engine via a platform engine factory from main.swift) and
`GUIControlBackend` (macOS GUI: a MainActor adapter over the view model, so
remote changes flow through the same setConfigValue-style choke points as
window controls and the GUI stays consistent). Config PATCHes use
`ConfigPatch`: the request's INI keys are overlaid onto the current config
through the existing INI parser (defaults/validators/clamps apply), and each
key's live/liveRDS/restartRequired disposition is DERIVED by diffing the
engine's own `RuntimeConfig`/`RDSRuntimeConfig` value structs -- the API can
never disagree with what `applyRuntimeConfig` actually hot-applies. Live
planes route through the same lock+atomic pending-config hand-off the GUI
uses (AudioOutputEngine on macOS; the equivalent surface added to
ALSAAudioEngine on Linux, consumed at the top of each render period).
Security: loopback binds are open; any other bind refuses to start without
`control_api_key`, checked constant-time as Bearer/X-API-Key on /api routes.

The dashboard renders itself from **`GET /api/schema`** (backed by `Control/WebUI/schema.json` -- widget definitions + page model for the whole exposed INI vocabulary); `index.html` carries no hardcoded control tables. `ControlSchemaTests` pins the schema against the INI vocabulary in both directions: every config key needs a widget or a reasoned exemption, every widget must name a real key, and every page key must have a widget (the pre-0.44 dashboard silently dropped ten controls exactly this way). `GET /api/config/defaults` serves factory defaults for client-side reset. Preset kinds `finalstage` and `format_profile` are served by BOTH backends -- the tables live in `PresetCatalog` (moved out of the GUI view model, which previously made station formats unreachable on a headless box). The 8 operator snapshot slots are a REST surface (`/api/snapshots...`) backed by the shared `SnapshotStore` (`Control/SnapshotStore.swift`, same `<config>.snapshots.json` file the GUI writes -- web and native operate on the same slots); loading a slot applies it as ONE full config patch through the canonical classifier. `GET /api/telemetry` serves display-decimated scope waveforms + a server-computed MPX spectrum (`MPXSpectrumAnalyzer`, 4096-point vDSP FFT per request at the browser's ~4 Hz poll -- ~6 KB, ~5 ms) via a `ControlledEngine.controlTelemetry` default-nil extension point, so the ALSA engine simply reports 503 until it grows a scope tap. The endpoint is API-only: an in-dashboard canvas page was tried and removed (a 4 Hz poll cannot look like an instrument; browser visuals would need SSE/WebSocket push).

## Threading Model

- Main thread: SwiftUI UI, user interaction
- Audio render callback: Real-time thread (no locks, no allocations)
- Background metering: DispatchQueue with `.userInteractive` QoS for scope/meter updates

## Current processing order

Within the main audio path, MPX Prime Studio runs:

1. Input gain and mono fold
2. **Phase rotation** (4-pole allpass, optional)
3. Wideband AGC (K-weighted RMS rider; attack default 150 ms since 0.45 -- the 6 ms it shipped with was limiter-fast and ducked program 3.4 dB on a 30 ms drum hit, 0.02 dB now; profiles 100-200 ms; `--verify` flags < 50 ms)
4. Input HPF
5. Program lowpass
6. HF trim
7. **Parametric EQ** (4-band: low shelf + 2 peaking + high shelf, optional)
8. Mono bass (inside `processStereoImageStage`)
9. Multiband compressor (3-band or 5-band)
    - **TX path**: linear-phase FIR splitters (sum-to-flat; per-crossover transition = fc floored at 120 Hz, -6 dB exactly at each crossover, 40 dB stopband, kernels zero-padded to one shared group delay -- 446 samples = 9.3 ms at the 48 kHz audio domain with the default 90 Hz lowest crossover; before 0.45 the design ignored the requested transition, sat on the 2049-tap clamp at 21.3 ms and pre-rang ~12 ms at the upper crossovers)
    - **Monitor path**: IIR Linkwitz-Riley LR4 crossovers (low latency)
    - Program-dependent (dual-slope) release per band, default on (0.45): `MonoCompressor` applies its GR through a smoother with a ~1.5 s platform of the demanded reduction -- excursions below the platform (drum hits) release at the configured rate, recovery above it (average level dropped) 3x slower; the pre-0.45 flag only scaled the release time by a constant 1.1
    - Per-band downward expander (optional)
    - Per-band fast peak limiter (optional)
    - **Advanced Dynamics** (`advanced_dynamics_enabled`, experimental, default off) runs
      in this slot when enabled and REPLACES steps 3 and 9 entirely: the wideband AGC
      call (step 3) is skipped and the single-stage 5-band leveler runs instead of the
      multiband compressor (including its per-band expander and limiter)
10. Stereo widener (post-multiband; canonical Optimod placement so multiband doesn't compress widened side-channel HF)
11. PrimeBass (post-multiband; canonical MaxxBass / Aural Exciter / Big Bottom placement so multiband doesn't compress the synthesised harmonics)
12. Bass clipper (LR4 split + tanh-clipped LF band, vvtanhf-batched, optional)
13. Distortion-cancelled clipper (Orban-principle LF cancellation, vvtanhf-batched, optional)
14. Encoder HF guard (a fixed <= 2 dB stereo-linked HF ride ahead of the encoder lowpass; kept in 0.45 after measurement -- removing it cost 20-40 dB of receiver-side HF separation on the tone test because un-attenuated HF drives the composite clipper into audio-band IM, and the pre-emphasis-domain HF limiter does not engage at those levels)
15. Encoder program lowpass (~15 kHz final audio-bandwidth guard before stereo encoding) — linear-phase FIR on TX, Butterworth cascade on monitor. (The 19 kHz audio-path notch that followed it was removed in 0.45: the FIR's >80 dB stopband already covers 19 kHz -- receiver gate identical to 0.01 dB with and without it.)
16. Stereo-image protection
17. Pre-emphasis (L/R domain, immediately upstream of pre-encode limiter; canonical Optimod / Stereotool placement so the limiter peak-controls the +10–12 dB HF-boosted signal; `PreemphasisDesign` biquad fitted to the analog curve at configure time, 0.45 -- the matched-z zero it replaced under-boosted 0.6 dB at 10 kHz / 1.4 dB at 15 kHz at the 48 kHz audio rate)
18. HF limiter (0.45; L/R domain, default-on in every profile): program-controlled pre-emphasis after Orban US 4,103,243 -- rides only the boost component `pre - flat` with a stereo-linked feed-forward detector, boost-dominance guard, 1.5 ms attack / 5 ms hold / 20 ms release; can never cut HF below the flat program level; live-apply (`hf_limiter_*`)
18a. Pre-emphasis-aware HF clipper (L/R domain, oversampled, optional, default-off, no longer used by any profile; clips only the pre-emphasised high band -- a waveshaper on the cymbal band, superseded by the HF limiter; configurable crossover ~5 kHz / threshold / drive; live-apply; added 0.35)
19. Pre-encode audio limiter (L/R domain, `StereoLinkedOversampledPeakLimiter` — `max(|L|, |R|)` detector drives both channels identically; 0.30: default-on look-ahead with Dolby HF-subband-aware detector per `US 5,579,404`; 0.45: the 4:1 decimator is a linear-phase Kaiser FIR flat to 15 kHz and 80 dB down from 16.5 kHz at the 48 kHz audio domain, ~640 taps / 1.7 ms -- it is the chain's 15 kHz band-limit in the pre-emphasised domain, since the encoder FIR runs before pre-emphasis and its transition tail arrives +14 dB hotter; the 6th-order Butterworth at 14.4 kHz it replaced cost -2.3 dB at 14 kHz on air and had -27 dB alias rejection)
20. Stereo encoder (M/S encoding, 38 kHz DSB-SC subcarrier)
    - **SSB Stereo** (`mpx_ssb_stereo_enabled`, experimental, default off): SSB-leaning
      assembly `diff*sin(2t) - sel*amount*hilbert(diff)*cos(2t)` -- a linear-phase 511-tap
      Hilbert FIR with matched base/diff program delay, opportunistically keeping whichever
      38 kHz sideband currently peaks lower (leaky-peak selection, 3% hysteresis, 5 ms
      crossfade). Decode-compatible with standard receivers; hard-gated by
      `--verify-ssb-stereo` (sideband asymmetry matches theory, coherent separation
      preserved, mono bit-transparent). Both subcarrier phases come from the same pilot
      recurrence (`sin2x`/`cos2x` double-angle), so pilot/subcarrier coherence is untouched.
21. Composite clipper (16× oversampled tanh soft-clip with differential topology + linear-phase FIR decimation + delta-based per-band substitution for pilot / stereo / RDS guards; vvtanhf-batched; optional OS-rate sliding-window-max look-ahead). Since 0.45 its ceiling is mapped onto the audio-composite BUDGET (what is left of the composite after the pilot/RDS reservation) instead of digital full scale -- see "Final-stage order and budget reference" below
22. Audio composite bandwidth FIR (55 kHz linear-phase cleanup before pilot/RDS injection)
23. BS.412 MPX power limiter (60s rolling average, optional, EU compliance)
24. Final look-ahead MPX limiter (audio composite only, threshold just under the budget; rides the in-band overshoot the clipper's guard-band restoration leaves -- the composite-domain overshoot controller, Orban's "half-cosine composite limiter" role)
25. Shaper: the single always-on budget safety soft clip (`audio_composite_softclip_enabled`, 1x; idle behind clipper + limiter, pinned by `CompositeShaperOrderingTests`; catches impossible configurations and the case where both peak stages are disabled). 0.45 removed the duplicate second soft clip, the 54 kHz "smoother" one-pole between them and the idle 0.98 post-gain soft clip (`audio_composite_smoother_enabled` / `final_mpx_softclip_enabled` keys gone)
26. Composite budget governor (smoothed gain ride on audio path so post-injection clamp is unreachable for sane configs)
27. Pilot and RDS injection (post-clipper, constant amplitude, delay-aligned via `subcarrierDelayLine`)

Most optional stages are disabled by default and can be enabled via config/UI. The default processing chain intentionally ships with multiband, bass clipper, composite clipper, pre-encode limiter, final MPX safety, encoder FIR, and multiband FIR enabled per `AppConfig`.

When `Mono Mode` is enabled, MPX Prime Studio suppresses the pilot, stereo subcarrier, and RDS injection so the transmitted composite is true mono.

## External Dependencies

- AVFoundation / CoreAudio for audio I/O (macOS; the Linux CLI build uses ALSA / libasound)
- Accelerate framework for vDSP (SIMD-optimized metering; on Linux the `MPXPrimeAcceleration` shim substitutes SIMD-vectorized same-name implementations (Swift SIMD8 / SSE2))
- SwiftUI for native macOS UI (macOS-only; Linux is CLI-only)
- swift-atomics (lock-free ring buffer + live-apply atomics; both platforms)
- Hummingbird 2 (+ SwiftNIO, transitive) for the embedded remote-control REST server + web dashboard; compiled into `MPXPrime` on both platforms
- ALSA / libasound (Linux CLI audio I/O, via the `CAlsa` system-library target)

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

### Advanced Dynamics single-stage leveler (0.44, experimental, optional)
`advanced_dynamics_enabled` (default off) swaps the wideband AGC + multiband compressor pair for one fused 5-band leveling stage (`AdvancedDynamicsLeveler`); when off the chain is bit-identical to before the stage existed (the AGC gate reduces to the previous check). Rationale: two cascaded gain-riding stages can fight (AGC pulling program down while multiband pushes bands up), which is a classic pumping source; a single stage levels each band toward a target with no second controller to disagree with. Per band: linked-RMS sidechain (one shared gain per band keeps the stereo image exact), the `MonoCompressor`-pattern RMS/peak hybrid transient detector, and a gain smoother with *program-adaptive* coefficients — a transient blends the attack toward a near-instant anchor coefficient (~1000x the 30 ms base, precomputed so there is no per-sample `expf`), inside the target window the gain freezes entirely, and the dual-envelope program-density estimator (the `WidebandAGCRider` pattern) slows release on busy material, and a per-band decay guard (slow-release peak tracker; env > 3 dB below it = an active fade) holds the lift while program decays naturally so solo fades are not flattened into audible ringing. Gain range is -24 dB..+`advanced_dynamics_max_gain_db` per band; low/mid/high target offsets interpolate across 5 bands exactly like the multiband threshold anchors; the low band's smoothed reduction biases upper-band targets with the multiband coupling curve (-0.10/-0.15/-0.22/-0.25). Band split is an own-instance `LinearPhaseMultibandSplitter5` at the multiband crossovers, configured lazily so the disabled stage allocates nothing. All parameters are live-apply (`RuntimeConfig`); structure (FIR split) rebuilds only on enable-toggle or crossover change. `AdvancedDynamicsTests` covers plumbing, INI round-trip, quiet/loud convergence, the at-target freeze, transient catch, the silence gate, hostile input, and chain inertness when off; `advancedDynamicsCostStaysBounded` bounds cost at <2x the two stages it replaces (measured ~1.0x); `--verify-advanced-dynamics` is the program-material A/B gate and additionally measures re-processing idempotency (second pass through a fresh leveler moves RMS < 0.3 dB — already-processed material passes essentially untouched). Measured 2026-08-29 with `--verify-hf-transients`: enabling the stage on Music - Loud costs ~3 dB of decoded hi-hat SINAD and ~1 dB of cymbal-wash crest versus the AGC + multiband pair; a 2.5 ms attack floor on the top band changed neither number, so the transient attack is not the cause (next suspect: the -9 dB top-band target offset lifting sparse HF).

### Downward Expander
Per-band noise reduction within the multiband compressor stage. Threshold-based gain reduction on quiet bands prevents AGC from lifting the noise floor during quiet passages.

### Bass Clipper
Dedicated clipper for low-frequency content using LR4 crossover to split, tanh-clip the low band, and recombine. Pre-clipping bass peaks independently before the final stages dramatically reduces bass-induced intermodulation distortion. Used by Omnia, Breakaway, and Stereotool.

### Distortion-Cancelled Clipper
L/R domain audio clipper implementing Orban's distortion-cancellation principle: clip the signal, extract the error (clipped minus original), lowpass-filter the error below a configurable cancellation frequency (~2 kHz), and subtract it from the clipped signal. This cancels low-frequency distortion products while leaving only high-frequency distortion that is psychoacoustically masked by the signal. The error path uses a Linkwitz-Riley 4th-order LP (two cascaded 2nd-order Butterworth sections at Q=0.707), giving a 24 dB/oct rolloff with -6 dB at the cancellation cutoff.

### BS.412 MPX Power Limiter
ITU-R BS.412 rolling average power measurement with slow gain reduction for European regulatory compliance (required in DE, AT, CH, SE, CZ, SI, and others). Measures decimated RMS power over a configurable sliding window (default 60 seconds) and applies slow gain reduction when average power exceeds the threshold. Operates on the audio composite before the safety limiter.

Structurally a **dual-integrator power AGC**: power-detect (square sample) → first integrator (per-block sum + 60-s rolling window) → sample-and-hold (per-64-sample boundary flush) → second integrator (gain smoothing with 1 s attack / 5 s release) → feedback gain ride. Functionally equivalent to the topology described in US 6,618,486 (CRL Systems / Harman, expired 2015-09-09). We use a flat rolling-average window instead of the patent's leaky-integrator first stage — gives a harder, more compliance-predictable boundary at the 60-s mark, generally preferred for type-approval testing.

### HF Limiter (0.45, default-on)
`HFLimiter` implements program-controlled pre-emphasis after Orban US 4,103,243 (the Optimod-FM 8100 HF limiter, expired 1997): the pre-emphasised L/R signal is treated as `flat + boost` and only the boost component rides a gain, `out = flat + g * (pre - flat)`, `g` in `[gMin, 1]`. g = 1 is full pre-emphasis, g = 0 the flat response, so the stage can never cut HF below the program's own level; the receiver's fixed de-emphasis turns the action into a brief, bounded HF dip -- the trade every broadcast HF limiter makes. Detector: feed-forward, stereo-linked; when the pre-emphasised peak exceeds the threshold AND the boost carries at least 20% of that peak (Dolby US 4,498,055-style modulation control -- bass/mid-driven peaks with little boost are left to the broadband limiter), the target gain removes exactly the excess from the boost, floored at `-hf_limiter_max_reduction_db`. Attack 1.5 ms, 5 ms hold, release 20 ms (Orban's analog original: 3 ms / 10 ms); whatever leaks during the attack is caught by the pre-encode look-ahead limiter that follows (Orban's clipper-after-HF-limiter division of labour). Runs inside the dual-rate audio domain; all parameters live-apply. It replaced the HF *clipper* in the Music - Loud profile because the clipper -- a waveshaper on the very band cymbals live in -- cost 17 dB of decoded HF SINAD on hi-hats (`--verify-hf-transients`, 2026-08-29). `HFLimiterTests` pins passthrough when off, pull-to-threshold, the bass-peak guard, release, the reduction cap, stereo-link ratio, and INI/RuntimeConfig round-trips. Prior-art table: plan.md "HF transient / pre-emphasis limiting prior art".

### Composite Clipper (differential topology with delta-based per-band substitution)
Oversampled tanh soft-clipper on the audio composite, sitting after the pre-encode audio limiter and before BS.412 / final-MPX safety limiter. The oversampling factor is operator-selectable across {8, 16, 32} via `mpx_clipper_oversampling` (default 16; restart-required) — 8× for CPU-constrained hardware, 16× for industry-standard parity (Optimod 8X00 / Omnia.11 / Stereotool default), 32× for Omnia.9-class spec-sheet defence at roughly double this stage's CPU cost. Numbers in the rest of this section assume the 16× default unless stated otherwise; tap counts, batch sizes, and internal rates scale linearly with the active factor. Since 0.11 this is the **only** non-linearity on the audio composite — the prior `CompositeTruePeakLimiter` (memoryless tanh on `|composite|` peak detection) was deleted because its IM bled into the 38 kHz stereo sidebands and demodulated as `(L−R)` cancellation. As of 0.20 the clipper runs the **differential topology** of Orban US 6,337,999 (expired 2022, public domain): only the *clipping residual* (input − clipped) goes through decimation, while the wanted signal rides a 1× delay-matched bypass and the residual is subtracted at the output. The decimator's stopband leakage and any phase non-flatness now only colour the residual subtracted at output, not the wanted (L−R) sideband content. Decimation itself uses `LinearPhaseFIRDecimator` (Kaiser-windowed sinc, ~147 taps, `vDSP_dotpr` polyphase, ≥90 dB stopband, flat passband 0–53 kHz) — replaces the prior `BiquadCascade6` 12th-order Butterworth which had ~70-80 dB stopband and 1-2 dB rolloff at the upper subcarrier edge. Cost: ~9 host samples (~47 µs at 192 kHz) of TX-path latency. The clipper does double duty: peak control plus loudness, the same role Orban's "Half-Cosine" / "Smart Clipper" stages play in the 8500/8600 line.

The bare clipper produces cubic IM that scatters across the FM baseband: M^n self-products in the audio band, M²·S / M·S² cross-products in the 23–53 kHz stereo sidebands, and broadband harmonic energy that lands inside the pilot guard band (17–21 kHz) and RDS guard band (55–59 kHz). The stereo-sideband products demodulate as audio in the S channel ("breathing") and the guard-band products vector-sum with the cleanly-injected pilot/RDS, degrading stereo decoding and RDS BCH integrity.

**Delta-based per-band substitution.** For each band we compute the bandpassed clean input `o<band>` and the bandpassed clipped output `c<band>`, then add the **delta** `(o<band> − c<band>)` back into the clipper output. That delta is exactly the per-band distortion the clipper introduced; subtracting it restores the band to the clean input while leaving every other band still clipped. Because the bandpass filters are applied identically to both `up` and `clipped`, group delay is matched within each band by construction — there is no IIR phase mismatch the way an LP-only error path would produce.

```
output = clipped
       + cancelAudio  ? (oAudio  − cAudio)  : 0
       + cancelPilot  ? (oPilot  − cPilot)  : 0
       + stereoGuard * (oStereo − cStereo)      (0...1 share, `mpx_clipper_stereo_guard`)
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

Live-apply via `RuntimeConfig`. INI keys `mpx_clipper_enabled`, `mpx_clipper_threshold_db`, `mpx_clipper_ceiling_db`, `mpx_clipper_cancel_audio`, `mpx_clipper_cancel_pilot`, `mpx_clipper_stereo_guard` (0.45: a 0...1 share of the 22-53 kHz residual restored; replaced the `mpx_clipper_cancel_stereo` toggle, which loads as 1.0 / 0.0. At 1 the clipper only ever removes the MONO share of an M+S peak -- chain-review finding B1 -- so the composite overshoots the ceiling by up to ~1.7 dB on a 12 dB overdrive and the Final-MPX limiter rides it; at 0 it clips the full composite like Orban's half-cosine limiter (US 6,434,241, which does not protect 23-53 kHz) and Thimeo / Omnia. `--verify-stereo-guard` sweeps the share on the Music - Loud profile and the loaded config and is where the default comes from), `mpx_clipper_cancel_rds`, and (0.26) `mpx_clipper_lookahead_ms`. The legacy `composite_clipper_enabled` key (which used to control the now-deleted composite *limiter*) was removed in 0.11 — see the Verification.ini key-collision warning in AGENTS.md.

**Look-ahead peak control (0.26, optional).** When `mpx_clipper_lookahead_ms > 0`, an OS-rate (3.072 MHz at 192 kHz × 16) sliding-window-max detector with Lagrange-interpolated intersample peak detection feeds a gain envelope smoothed by a 200 Hz one-pole LP. The gain is applied identically to both the clipper's `up` input and the per-band `orig*` filters, so the differential-topology cancellation linearity holds. A separate `lookaheadGainReductionDB` telemetry value distinguishes clean predictive ducking from soft-clip distortion-producing GR on the meter. Single INI knob; attack/release/smoother cutoff are hardcoded (exponential attack tied to the look-ahead window, ~80 ms release, 200 Hz smoother). 0.0 disables (default); 2.0 ms is the recommended value for loudness-priority presets. Algorithmic primitives — Lemire monotonic deque (sliding-window max), half-cosine attack LUT (US 6,434,241, expired 2014), 200 Hz gain-modulation smoother (US 5,737,434, expired ~2017) — are expired or public-domain.

**Final-stage order and budget reference (0.45).** Until 0.45 the final stage ran shaper -> clipper -> bandwidth FIR -> BS.412 -> final limiter, with the clipper's -1 dB threshold and the final limiter's 0.98 threshold both read against digital full scale. The audio composite's budget (0.98 minus the pilot/RDS reservation minus a 0.02 margin, ~0.85 with 8% pilot and 2 kHz RDS) sits BELOW those thresholds, so the 1x, un-oversampled, guard-less `softClipSafety` shaper did every bit of the clipping and neither the oversampled clipper nor the limiter ever engaged (`--verify-hf-transients`: clipper on/off bit-identical on Music - Loud; the shaper cost ~13 dB of decoded HF SINAD). The stage now runs composite clipper -> bandwidth FIR -> BS.412 -> final look-ahead limiter -> experimental multiband clipper -> shaper, and the two peak stages are normalised onto the budget per sample: the clipper's configured ceiling lands exactly on the budget (`x / (budget / ceilingLinear)` in, `* (budget / ceilingLinear)` out, so the operator's threshold/ceiling pair keeps its knee width and the composite uses the whole budget -- deviation stays where operators calibrated it), and the limiter's threshold lands on the budget (0.985 x budget until the A1b fix below). The budget is a slowly varying envelope (subcarrier reservation, 0.5 ms attack / 12 ms release) against the clipper's ~0.1 ms internal delay, so scaling in and out by the same current value keeps the differential-topology cancellation exact in practice. Why a limiter must follow the clipper: the guard-band substitution restores the protected bands (pilot, 22-53 kHz stereo, RDS) to the CLEAN input, so the clipper output legitimately exceeds its own ceiling in-band (`CompositeClipperBoundProbeTests`: 1.18 vs a 0.966 ceiling on a 12 dB overdrive, and the 55 kHz FIR removes none of it). That excess is the price of clean guards and is taken by a gain ride, never by a waveshaper -- the verifier expects ~1 dB of final-limiter duty on `bright_dense` (Music - Loud) and only flags it above 3 dB (TIGHT) / 4 dB (WARN). **A1b (0.45):** the ride is a true look-ahead limiter now: `LookaheadLimiter` feeds a `SlidingWindowMax` over the sample leaving its 5 ms delay line plus everything still inside it, attacks with a time constant of window / 4 so the gain is at depth before the peak leaves, and floors the gain at the required value so nothing above the threshold ever exits (release ~95 ms, 4 ms hold). The pre-A1b detector was the instantaneous |x| into a 0.35 ms one-pole; on program whose peaks move faster than that it tracked a blurred target and leaked 0.9 dB (Music - Loud) to 2.7 dB (hot chain) past its threshold into the 1x shaper while reporting 0.02 / 5.8 dB of GR -- found by `--verify-final-ride`, whose safety-clip column now reads 0.00 in every row with the limiter on. `LookaheadLimiterTests` pin the contract (+0.000 dB worst case at 12 dB overdrive, burst leading edge caught, pure delay below threshold). This matches Orban's documented architecture (composite clipper -> pilot/SCA protection filtering -> 512 kHz "half-cosine" composite limiter acting as overshoot compensator -> pilot re-added), with the caveat that our residual safety soft-clips run at 1x, which is harmless only while they stay idle -- hence the ordering test.

**Multiband composite clipping -- removed in 0.45.** The 0.28 experimental `CompositeMultibandClipper` (`mpx_multiband_clipper_enabled`) never reached a preset, and its own A/B gate went TIGHT (>60 kHz leakage +8.7 dB on `vocal_sibilant`) once the final stage was corrected; deleted with its INI key, dashboard toggle, tests and verify mode.

`CompositeClipperCrossDomainTests` and `CompositeClipperStereoSeparationTests` are the regression guards. The first asserts cross-domain IM drop with each guard band engaged; the second asserts that decoded L/R separation is preserved within tolerance when the stereo guard is on. `CompositeClipperLookaheadTests` covers the (0.26) look-ahead path: overshoot bound (`max(|out|) <= ceiling x 1.005` at 2 ms), steady-state transparency on pink noise, pilot/stereo/RDS guard regression with look-ahead engaged, cross-domain cancellation regression (catches asymmetric per-band gain leak), and total-delay reporting. Together they catch regressions in cancellation depth, over-cancellation that would collapse the stereo image, look-ahead detector / gain-application asymmetry and latency-reporting drift.

### Audio Composite Bandwidth FIR (0.26)
Linear-phase FIR cleanup stage placed after the composite clipper and before BS.412 / final-MPX safety limiting. Strips shaper/clipper spill that would otherwise live above the upper stereo sideband and beat with the cleanly-injected pilot/RDS. Group delay (~112 host samples at 192 kHz) folds into `recomputeSubcarrierDelay()` so the post-clipper subcarrier delay line tracks the new audio path delay automatically.

### Safety-clip duty telemetry (0.45)
`FinalLimiterStatus.safetyClipDB` is a 250 ms decaying peak of `20 log10(|composite| / budget)` measured at the shaper's input -- how far the audio composite exceeded the budget and had to be caught by the 1x safety soft clip. Both engines forward it (`mpxSafetyClipDB` in the CoreAudio meter snapshot, `safetyClipDB` in the ALSA state) to the GUI Monitoring card ("SAFETY CLIP") and the control DTO (`safetyClipDB` in `/api/telemetry`, "Safety Clip" on the dashboard). Contract: 0.0 with the composite clipper and final limiter enabled; anything above zero means the shaper is doing peak control.

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
