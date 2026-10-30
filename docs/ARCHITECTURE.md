# Architecture

## Overview

MPX Prime Studio is a native macOS audio application built with Swift and SwiftUI. It provides real-time FM stereo MPX generation with RDS support using AVAudioEngine (direct AUHAL input capture). Per-tick meter values live on a separate `@Observable` `LiveTelemetry` object rather than the view model; the Linux CLI build runs the same generator headless on `ALSAAudioEngine` with the web dashboard as its interface.

```text
SwiftUI UI  <->  App State (ObservableObject)
                        |
                        v
                 Audio Engine
                 (AVAudioEngine)
```

## Block Diagram

```text
Audio Input device (L/R) @ device's native rate (e.g. 48 / 96 / 192 kHz)
|  via `InputAUHAL` (direct AUHAL audio unit) -> `StereoInputRingBuffer`
|  Adaptive 32-tap Kaiser-windowed sinc resampler (15 frames of history,
|  no clamped taps at block edges) in the output render callback absorbs
|  input/render rate mismatch + clock drift up to 50 ppm; flat to 0.001 dB
|  at 15 kHz on the 48 -> 192 -> 48 kHz round trip.
|
+--> Phase rotation (optional)
|    +-- 4-pole allpass chain at ~200 Hz -- reduces waveform asymmetry
|        by 3-4 dB, yielding free headroom for downstream stages
|
+--> Input conditioning (audio domain)
|    +-- Wideband AGC (optional)
|    +-- High-pass ~20-30 Hz (infrasonic removal)
|    +-- 15 kHz low-pass
|    +-- HF trim shelf (optional)
|
+--> Tonal shaping (audio domain)
|    +-- 4-band parametric EQ (optional)
|        Low shelf + 2 peaking + high shelf, placed before dynamics
|
+--> Dynamics and image shaping (audio domain, float)
|    +-- Mono bass management (optional)
|    +-- Multiband compressor (optional)
|    |   +-- TX path: linear-phase FIR splitters (sum-to-flat, all bands
|    |   |   share group delay -- eliminates IIR-LR4 transient smear;
|    |   |   -6 dB at each crossover, transition = fc, 9.3 ms at 48 kHz)
|    |   +-- Monitor path: IIR Linkwitz-Riley LR4 crossovers (low latency)
|    |   +-- Optional transient-aware attack detector
|    |   |   (`multiband_transient_aware_attack_enabled`) blends RMS/peak
|    |   |   detection and briefly stretches attack on percussive fronts
|    |   +-- Optional inter-band coupling
|    |   |   (`multiband_inter_band_coupling_enabled`) lets low-band GR
|    |   |   gently bias upper-band thresholds
|    |   +-- Per-band downward expander (optional noise reduction)
|    |   +-- Per-band fast peak limiter (optional transient control)
|    +-- Advanced Dynamics (default since 2026-10-15, `advanced_dynamics_enabled`):
|    |   one wideband adaptive gain + bounded per-band spectral correction;
|    |   REPLACES the wideband AGC and the multiband compressor when on
|    +-- PrimeBass (optional, post-multiband)
|        +-- Multiband doesn't compress synthesised harmonics back down
|
+--> Peak control (audio domain, L/R)
|    +-- Bass clipper (optional) -- dedicated LF clipper with LR4 split
|    |   reduces bass-induced IMD in downstream stages
|    +-- Distortion-cancelled clipper (optional) -- Orban-principle LF
|        distortion cancellation: clip at 8x, decimate the clipping error
|        through a Kaiser FIR, remove it below the cancellation frequency
|        with a zero-phase (linear-phase) lowpass; never adds distortion
|
+--> Encoder HF guard
|    +-- Fixed <= 2 dB stereo-linked HF ride ahead of the encoder lowpass;
|        measured load-bearing for receiver-side HF separation (0.45)
|
+--> Encoder program lowpass (~15 kHz)
|    +-- TX path: Kaiser-windowed linear-phase FIR, >80 dB stop-band
|    |   (~1.67 ms latency at 192 kHz). Pushes DC-clipper / composite-
|    |   clipper aliasing well below the stereo subcarrier floor.
|    +-- Monitor path: 12th-order Butterworth cascade, ~13 dB at 17 kHz,
|        ~0.2 ms latency -- keeps live monitor responsive
|
+--> Stereo-image protection (operator option, default OFF since 2026-10)
|    +-- Side/mid envelope limiter: holds the output side under
|        `stereo_image_max_side_ratio` x mid (1.55 = the former fixed cap)
|        or 1.16 x the source's own ratio, whichever is higher, with a
|        1.025 floor; reference delay-matched to the output tap; idle when
|        the input mid is under -34 dBFS (no reference, so pure-side content
|        passes). Always on until 2026-10 (the removed widener's safety net);
|        the stereo audit found it capping the source's own width, so it is
|        an option now (`stereo_image_protect_enabled`).
|
+--> Pre-emphasis (L/R domain, region specific)
|    +-- 50 us (Europe) / 75 us (Americas / Japan / Australia)
|    +-- Applied L/R immediately upstream of the pre-encode limiter
|    |   so the limiter peak-controls the +10..12 dB HF-boosted signal
|    |   (canonical Optimod / Stereotool placement)
|    +-- Network: `PreemphasisDesign` biquad fitted to the analog curve
|        |1 + j omega tau| (<0.05 dB to 15.5 kHz at 48 kHz; the textbook
|        matched-z zero was -1.4 dB at 15 kHz there). The decoder's
|        de-emphasis is its exact inverse. (0.45)
|
+--> HF limiter (L/R domain, gain-riding, default-ON in every profile since 0.45)
|    +-- Program-controlled pre-emphasis (Orban US 4,103,243, expired):
|        rides only the pre-emphasis BOOST `pre - flat` so an overshooting
|        cymbal / hi-hat briefly loses part of its boost instead of being
|        clipped or dragging the whole mix down in the limiter below.
|        Per-channel programme gate (a bass peak in either channel leaves
|        the HF alone), 1.5 ms attack,
|        5 ms hold, 20 ms release, max reduction 12 dB; live-apply.
|        `hf_limiter_*`. Added 0.45 (hi-hat / cymbal field finding).
|
+--> Pre-encode audio limiter (L/R domain, stereo-linked oversampled, look-ahead)
|    +-- True-peak limiter on L/R before stereo encoding --
|        `StereoLinkedOversampledPeakLimiter` uses a max(|L|, |R|)
|        detector so both channels receive identical gain reduction
|        (no asymmetric pumping). `pre_encode_stereo_link` (0..1, default
|        1, live) blends in a per-channel envelope: below 1 the quieter
|        channel is attenuated less while the louder one limits; the
|        composite peak stays bounded by max(|L|, |R|) either way.
|        4x linear-phase Kaiser FIR interpolator
|        (7 samples of extra latency at 48 kHz) and Kaiser FIR decimator.
|        Default 1.0 ms look-ahead (Phase 1,
|        delay+detector primitive, US 4,208,548 prior art) so the
|        gain ramp engages before the peak reaches the gain stage.
|        Default-on Dolby HF-subband-aware detector (Phase 2, US 5,579,404
|        / EP 0685130, expired 2013) high-passes the detector at 4 kHz
|        so look-ahead engages only on HF transients (where pre-emphasis
|        concentrates peaks), leaving LF punch untouched. Audio path
|        stays full-band. Optional band-limited residual ceiling uses
|        the 33-tap / 0.25-cutoff kernel when enabled. Threshold,
|        release, residual enable, and residual kernel shape live-apply
|        via `RuntimeConfig`; look-ahead settings are restart-required.
|

+--> Stereo encoder (phase-coherent)
|    +-- M = (L+R)/2
|    +-- S = (L-R)/2
|    +-- DSB-SC: S x sin(2*theta)   pilot = sin(theta), 38 kHz = 2xpilot from
|        the same recurrence. Standard polarity (47 CFR 73.322 / BS.450-3):
|        the subcarrier crosses zero with positive slope at every pilot zero
|        crossing, a receiver forms L = M + S. Pre-0.45 the encoder sent
|        (R-L)/2 and MPXDecoder negated it back -- real receivers swapped L/R.
|        MPXDecoder is now a plain textbook decoder (no sign compensation);
|        StereoPolarityTests pin both sides against an independent decode and
|        --verify-receiver scores separation against the DRIVEN channel.
|
+--> RDS path (parallel, MPX domain @ output rate)
|    +-- RDS baseband (biphase / shaping)
|    +-- Gaussian filter (spectral containment)
|    +-- 57 kHz subcarrier (3xpilot, phase locked)
|
+--> Final MPX chain (audio composite only)
|    +-- Final Drive (audio-composite domain)
|    +-- Composite clipper (16x oversampled tanh soft-clip, differential
|    |   topology: 2x Kaiser FIR interpolation then Lagrange-4 to the full
|    |   factor; the clip residual is Kaiser-FIR decimated (293 taps at
|    |   16x) and one coherent linear-phase FIR guard keeps it out of the
|    |   pilot, stereo (x share) and RDS bands; vvtanhf-batched; OS-rate
|    |   sliding-window-max look-ahead with a step-free gain ramp,
|    |   `mpx_clipper_lookahead_ms`, default 2 ms, riding to
|    |   ceiling + `mpx_clipper_lookahead_depth_db` so the kernel clips
|    |   the depth and the ride removes only the excess)
|    +-- Audio composite bandwidth FIR (linear-phase cleanup before
|    |   pilot/RDS injection -- group delay folded into the subcarrier
|    |   delay line so phase alignment is preserved)
|    +-- BS.412 multiplex power limiter (optional, EU regulatory compliance)
|    |   Rolling 60-second average power measurement with slow gain reduction
|    +-- Final-MPX safety limiter (audio composite only -- no pilot, no RDS;
|    |   look-ahead, 4x true-peak detector, gain ramped over the window,
|    |   never stepped)
|    +-- Shaper `softClipSafety` (1x budget safety soft clip: knee from
|    |   0.99 x budget, asymptote at the budget; idle behind clipper +
|    |   limiter, `Safety Clip` telemetry reads 0.0 on programme)
|    +-- `output_gain_db` (MPX Output Level; `mpx_line_output_dbfs` is
|    |   applied later, in the audio engine, after metering)
|    +-- Composite budget governor (smoothed gain ride on the audio
|    |   path enforces `audioCeil = (threshold x min(1, deviation / 75 kHz)
|    |   / outputGain - reserved - margin) x outputGain` BEFORE pilot/RDS
|    |   injection, so Composite Deviation is the peak target of the whole
|    |   multiplex and the post-injection clamp is unreachable for sane
|    |   configs; `overBudget` flag classifies impossible configs explicitly)
|    +-- (pilot/RDS reservation -- the nominal on-air peak of each service,
|    |   pilot level + RDS injection -- feeds the governor's `reserved` term)
|
+--> Post-clipper subcarrier injection (delay-aligned)
|    +-- Pilot 19 kHz (approx 8-10% injection, constant amplitude)
|    +-- RDS 57 kHz (approx 3-7% injection, constant amplitude)
|    +-- `subcarrierDelayLine` delays pilot+RDS by composite-clipper
|    |   total delay + safety-limiter lookahead so the receiver's
|    |   pilot-derived 38 kHz reference aligns with the audio
|    |   composite's internal stereo subcarrier modulation
|    +-- Subcarriers bypass all peak-control stages to preserve constant
|        amplitude for reliable stereo decoding and RDS reception
|        (professional broadcast standard: Omnia, Orban, Stereotool)
|
+--> Output formatting
|    +-- Output: PCM to DAC via AVAudioEngine
|
+--> Monitor path (optional)
|    +-- Demodulated L/R for headphone monitoring
|
+--> Processed-audio output (optional, `processedAudio` mode)
     +-- Post-pre-encode-limiter stereo L/R (no composite/pilot/RDS), for
         feeding an external stereo coder. Skips composite assembly entirely;
         runs at the audio device rate (e.g. 48 kHz). Pre-emphasis selectable.
         The limiter ceiling is mapped to full scale and the true-peak guard
         (2 ms look-ahead) holds it in FM Output as well as HD and AM.
```

## Test tone (calibration source)

When the engine renders the built-in test tone (`source_mode = tone`), `MPXGenerator` raises `renderingCalibrationTone` for each tone sample: `processProgramStereo` / `processAudioDomain` skip input gain and every dynamics / enhancement / clipping / limiting stage (the same gates `processingBypass` uses, plus the encoder HF guard), pre-emphasis and the encoder lowpass stay in (noise types need the band limit), and in `processFinalComposite` the drive is replaced by the audio-composite budget so 0 dBFS = 100% audio modulation, BS.412 is skipped, and the composite clipper and final limiter are kept in the path only for their delay (their inputs are scaled 8x below threshold so they pass the tone untouched and pilot/RDS alignment is preserved). Sine tones are pre-compensated for the pre-emphasis magnitude at the tone frequency (`updateToneGain`, the analogue curve `sqrt(1 + (2 pi f tau)^2)`, which the fitted pre-emphasis network matches). Pinned by `TestToneGeneratorTests`: composite peak = budget x 10^(level/20) within 0.25 dB across 0 / -6 / -20 / -40 dBFS, independent of Final Drive / AGC / processing, flat across 400 Hz / 1 kHz / 10 kHz, equal across mono / left / L=-R routing; the input path is checked to still respond to Final Drive.

## Operating modes

`AppConfig.OperatingMode` (`operating_mode`, restart-class) has four cases --
`mpx`, `fm`, `hd`, `am` -- and is the ONLY answer to "which mode are we in".
`AudioOutputMode` (`AudioOutputEngine.swift`) is the engine-side mapping. The
monitor is NOT one of these: since 0.50 it is a second output device running
alongside whichever mode is selected (see "Monitor output" below), so it no
longer competes with the mode for the one output.

### Monitor output

The monitor is a SECOND output device, playing alongside the transmitter feed
in every operating mode, so an operator can listen without tuning a receiver to
their own transmitter. Data flow per block, all on the render thread except the
player:

```text
mpx      : renderFromInputInPlace(left/right = composite, monitor -> scratch)
           the SAME pass demodulates each composite sample (MPXDecoder, with the
           encoder's delay-aligned subcarrier reference), so the composite is
           bit-identical whether or not anyone is listening
fm/hd/am : renderAudioOnly* -> output buffers; the monitor takes a COPY
all      : MonitorConditioner (de-emphasis where the chain emphasised, monitor
           level, clamp) -> StereoInputRingBuffer.write
           RingBufferPlayer drains it on the monitor device's own thread via
           readAdaptive, because the two devices' clocks are independent
```

The ring is allocated at `start()` and sized against the PRODUCER's block
(target `max(4 x blocksize, 40 ms)`, capacity `nextPow2(4 x target)`) -- the
Meter's lesson that a target below the producer's burst drags the sawtooth
through zero and clicks. `MonitorOutput.decide` holds the rules that protect
the air feed: an empty monitor selection is off (never the system default,
which may be the transmitter), the monitor never shares the transmitter's
output channels (same device is allowed only on disjoint `ChannelPair`s, and
the pair the player actually took is re-checked after start, because a pair
the device lacks falls back to 1, 2), a device or channel change restarts
only the player, and a vanished device stops it until
the same device returns. A monitor that cannot start is a routing note, never a
failed engine start. `monitor_enabled` / `monitor_device_uid` /
`monitor_channels` / `monitor_gain_db` ride `RuntimeConfig` (like `mpx_line_output_dbfs`: carried
there, consumed by the engine) so their live disposition stays DERIVED.
On Linux the DSP's SIMD kernels (the FIR dot product behind `vDSP_dotpr` /
`vDSP_conv`, and `vvtanhf`) are C with per-CPU clones: an AVX2 variant and
the SSE2 baseline, selected by the dynamic linker at load time, so the same
package serves CPUs with and without AVX2. The clones are
bit-identical to each other and to the shim's Swift references (same lane
structure, same reduction order, no FMA), which is why one Linux strict
baseline covers every CPU; `mpxprime --version` prints which variant runs.

On Linux `ALSAMonitorOutput` plays the same ring on a second ALSA PCM from
its own thread (`LinuxMonitorRules.decide` carries the same rules over ALSA
device names). There the division of labour differs from macOS on purpose:
the render thread writes the RAW feed (the composite in MPX Output) and the
monitor thread demodulates it with a standalone `MPXDecoder` on its own PLL
(the verifier's receiver model) and runs the `MonitorConditioner`. The rig's
render thread needs 95 % of its period for the chain alone (`renderLoadPercent`
in `/api/meters`), and decoding there cost 34 xruns per 20 s; with the
decode on the monitor thread the rig read 16 then 0 xruns per minute at
`blocksize` 2048 and 0 at 4096, whose 170 ms buffer rides out the bursts.

Which parts of the chain exist in which mode is ONE table,
`ChainFeature` (`Control/StageApplicability.swift`), read by the engine, the
GUI's sidebar (`Stage.chainFeature`), the dashboard schema (`modes` on a page
or a widget) and the tests (`ModeGatingTests`). A feature absent from a mode is
inert AND invisible: outside `mpx` the RDS encoder does not run whatever
`en_rds` says (gated in `MPXGenerator.applyRDSRuntimeConfig`, on the engine's
own immutable mode), the Now Playing poller does not poll
(`NowPlayingScriptRunner.Settings`), and the SSB stereo option cannot reach
the chain. The gates deliberately live on the ENGINE and not in
`makeRuntimeConfig` / `RDSRuntimeConfig.make`: `ConfigPatch` derives its
dispositions by diffing those factories, so a mode-dependent field there would
make a restart-class mode change report itself as a live RDS edit.

Pre-0.50 configs stored the mode as `processed_audio_output` +
`processed_audio_target`. Those are migrated on load
(`AppConfig.migratedOperatingMode`) and still accepted by the REST API, which
resolves them onto `operating_mode` in `ConfigPatch.resolvedOverlay` -- one
boundary, so storage keeps a single key.

`MPXGenerator` also seeds
`audioOutputOnly` from `processed_audio_output` at construction (0.50), so an
engine that never calls `setAudioOutputOnly` -- the ALSA engine -- still runs
the audio-only chain correctly (before the seed, Linux processed-audio kept
the dual-rate boundary on, running 48 kHz coefficients at the output rate,
and the optional final clipper could never engage); the macOS engine's
`setAudioOutputOnly` call at start() is an idempotent re-assert, pinned by
`configSeedMatchesExplicitSetAudioOutputOnly`.

- **`mpxComposite`** (default): the per-sample render is `processSampleDetailed`
  -> `processAudioDomain` (audio half) -> `processMPXDomain` (stereo encode,
  composite clipper, BS.412, pilot/RDS injection). Output device runs at the
  configured MPX rate (stereo and the pilot need at least 111 kHz -- 38 kHz plus
  the encoder lowpass's 17.5 kHz stop edge below Nyquist -- and RDS 118.8 kHz;
  below that they are switched off with a routing note on macOS and Linux;
  192 kHz standard). This is the canonical FM-composite path.
- **`monitorAudio`** (legacy, being retired): generated the composite and
  demodulated it back to L/R, REPLACING the transmitter feed on the monitor
  device. The concurrent monitor below supersedes it -- listening no longer
  costs the air feed.
- **`processedAudio`** (0.33): emits the processed stereo L/R after the pre-encode
  limiter and **skips `processMPXDomain` entirely** -- no stereo encode, composite
  clipper, BS.412, pilot, or RDS. Render path `renderAudioOnly*` calls
  `processAudioDomain` directly (dual-rate boundary forced off; whole engine runs
  at the audio device rate, typically 48 kHz -- `setAudioOutputOnly` re-derives
  EVERY audio-domain stage for that rate when it switches the boundary off; until
  0.45 nothing was re-derived and pre-emphasis / limiters ran 48 kHz coefficients
  at the output rate in this mode). The composite path is byte-identical
  to before -- the audio-only path simply branches off the existing `preMPX` tap.
  Two audio-domain stages still run for output quality: the encoder lowpass FIR (the
  15 kHz band-limit) and the FIR multiband crossovers. The post-limiter level is
  normalised so the binding ceiling maps to ~0 dBFS times the operator output gain.
  Pre-emphasis is selectable (`preemphasis_us`); an optional final loudness clipper
  (a dedicated `DistortionCancelledClipper` instance driven by
  `processed_audio_final_clip_drive_db`) engages only when the operator marks the
  external coder as having no clipper of its own
  (`processed_audio_coder_has_clipper = false`) -- the one-clipper rule, mirroring
  pre-emphasis ownership. Config: `operating_mode = fm` (restart-required). The
  UI hides every composite/RDS surface in this mode (RDS section, Stereo Coder /
  Composite Clipper / BS.412 / Loudness and Output tabs, pilot level,
  deviation/modulation meters, MPX Spectrum + Scopes windows, composite
  signal-flow pills).

## Audio I/O and level calibration (0.50)

Devices, the operating mode, and the three level-calibration keys
(`input_gain_db`, `output_gain_db`, `mpx_line_output_dbfs`) live in the GUI's
dedicated **Audio I/O** sidebar section (`UI/AudioIOTab.swift`; the web
dashboard's matching page is the retitled `interfaces` tools page). They are
installation state, not sound:

- **Device channels** (`MPXPrimeCore/ChannelPair.swift`, ported from Prime
  Mixer's route table). `input_channels` / `output_channels` /
  `monitor_channels` name one or two zero-based device channels, one-based in
  the INI and UI. `ChannelPair.resolve` falls back to 1, 2 with a routing note
  when the pair is not on the device. Input: `InputAUHAL` keeps its 2-channel
  planar client format and sets `kAudioOutputUnitProperty_ChannelMap` to the
  pair. Output: when the pair is not 1, 2, `AudioOutputEngine` and
  `RingBufferPlayer` build the source node with a
  `kAudioChannelLayoutTag_DiscreteInOrder` layout of the hardware's channel
  count, connect the main mixer to the output node with the same layout (no
  layout matrixing), render into the two chosen buffers and zero the rest.
  The 1, 2 path is the historical code, untouched, so the strict baselines
  do not move. Device enumeration (`AudioDevices.list`) also reports
  transport, rates, bit depth, buffer size and the defaults, and
  `AudioDevices.startObserving` drives hot-plug refresh in both apps. The
  shared `MPXPrimeUI` `AudioDeviceSelector` and `DeviceListPopover` views take
  that data in and never touch CoreAudio.
- **Telemetry domains.** Deviation is a MODULATION-domain readout: both engines
  divide `output_gain_db` back out of the metered composite
  (`modulationReferenceScale`) so the kHz display no longer under-reads by the
  operator's exciter trim (field-measured 30.2 kHz displayed
  vs ~75 on air at -7.89 dB trim; `DeviationTelemetryTests` pins the
  invariance). The kHz scale itself is fixed: composite amplitude 1.0 is
  75 kHz whatever `mpx_deviation_khz` is (the generator scales the whole
  composite by `mpx_deviation_khz / 75`), so `DeviationReadout.kilohertz`
  multiplies by `MPXGenerator.referenceDeviationKHz`, never by the configured
  deviation -- the pre-0.65 engines did, and under-read by that ratio away
  from 75 (`DeviationReadoutTests`). The electrical counterpart is `dacPeakDBFS` in `/api/meters` and
  the Audio I/O Output card: the peak actually presented to the converter, post
  `output_gain_db` AND `mpx_line_output_dbfs`. The calibration test tone rides
  the same trims, so `scripts/smoke-live.sh`'s budget-arithmetic expectation is correct
  at any station trim (it silently required 0 dB before).
- **Per-device calibration memory** (`Control/DeviceCalibrationStore.swift`): a
  JSON sidecar (`<configPath>.devicecal.json`, the SnapshotStore pattern)
  remembers Input Gain per input device and MPX Output Level + Line Output per
  output device -- per operating mode, because composite `output_gain_db`
  (modulation trim, clamp -40..0) and processed-audio (line feed, +/-40) are
  different physical calibrations. Write-through happens on every config
  persist (GUI debounced save; headless `persist()`); recall fires only on an
  effective device-UID or mode change, commits to config WITHOUT live-applying
  (a device change is restart-class; the old rig keeps its calibration until
  the restart, and both start paths re-apply the config), and explicitly
  patched level keys win over recall. UID drift after a USB re-plug falls back
  to the newest same-name entry, migrating on the next capture; a hand-edited
  INI reload never recalls (the INI is authoritative). Both backends inject
  their device enumeration so tests stay HAL-free.
- **Snapshots restore the sound, not the wiring**
  (`Control/InstallationKeys.swift`): snapshot LOAD preserves
  `AppConfig.installationPreservedKeysBySection` -- devices + names,
  sample_rate/blocksize, the mode booleans, the three calibration levels, and
  the `control_*` keys (a snapshot loaded over REST must not turn off the
  server it arrived through) -- from the live config, in both the GUI and the
  headless backend. Save and export stay full-config. The "edited since
  loaded" comparison normalises installation keys, so calibration/device churn
  never flips a preset to modified.

## Major Components

The SPM package (`Package.swift`) has (on macOS) eight non-test targets: **`MPXPrime`** (the encoder executable -- UI, engine, generator, config; ships universal), **`MPXPrimeMeter`** (the companion receive/analyse executable -- captures an MPX composite from an audio device or SDR and decodes stereo + RDS in a SwiftUI dashboard; shipped since 0.37. **Apple-Silicon-only**, because it links the arm64 RTL-SDR libraries below; build the x86_64 release slice with `--product MPXPrime` to skip it) The tuner keeps TWO rates: a **capture rate** (the IQ the device delivers, set by `iq_rate_khz`) and a **demod rate** (250 kHz SDRplay / 256 kHz RTL) that the FM demod chain always runs at, bridged by a polyphase `ComplexDecimator`. Only the capture rate changes when the operator widens the **RF spectrum** span, so a wider capture cannot move any MPX measurement. At the narrow setting the decimation factor is 1 and both backends are byte-identical to the pre-split path -- the RTL branch explicitly keeps its original packed-uint8 `processSplit` call there, because the complex path reproduces neither its normalisation LUT nor its raw-byte saturation detection. The RF spectrum itself is a 1024-point Hann-windowed complex FFT of the wide IQ, computed on the capture thread at ~20 frames/s, fftshifted to dB bins and published under a mutex via `mpxtuner_rf_spectrum()`; `RFSpectrumView` (MPXPrimeUI) plots it against the tuned centre frequency with a 100 kHz-raster grid, selected by the **MPX | RF** switch in the spectrum card header (SDR only)., **`MPXPrimeCore`** (a shared DSP library: `MPXDecoder`, `RDSStreamDecoder`, `DSPPrimitives`, plus the Meter's measurement engine `MeterAnalysis` + `MeteringPrimitives` -- moved here from the executable so the metering maths is unit-testable; depended on by both executables; hot per-sample `process()` methods are `@inlinable` so they inline across the module boundary), **`MPXPrimeUI`** (shared Canvas-based SwiftUI components -- scope, spectrum, vertical meter, vectorscope, trend, style tokens, the `LiveObservationView` isolation wrapper (in `MPXPrimeUI/LiveTelemetryView.swift`) -- used by both apps; each live Canvas view disables implicit animations via `.transaction { $0.animation = nil }` so 25 Hz repaints don't queue frame-interpolation transactions that accumulate into GUI lag), **`MPXPrimeNative`** (a tiny C target, `MPXPrimeNative.c`, that sets the FTZ/DAZ denormal-handling CPU flags on the audio thread), **`MPXPrimeRecording`** (a pure-Foundation library -- `CanonicalWavWriter` + `MeterRecorder` -- so the Meter's WAV recording path is unit-testable without importing the executable), and **`CMPXTuner`** (the vendored RTL-SDR / SDRplay -> FM demod -> MPX tuner compiled as a C++ library with a pure-C ABI `mpx_tuner_capi.h`; thin shims in `Sources/CMPXTuner/` include the canonical sources in repo-root `tuner/`, links Homebrew librtlsdr + liquid-dsp and -- when the SDRplay SDK is present at build -- the dlopened SDRplay API, depended on only by `MPXPrimeMeter`). `MPXPrimeAcceleration` (present on both platforms) is the platform acceleration shim: on macOS it compiles to an empty module and DSP code links the real Accelerate / os frameworks; on Linux it provides same-name, same-signature implementations of the small vDSP/vForce surface the encoder uses (dotpr/conv/reductions/vector ops, Hann window, packed-real FFT `vDSP_fft_zrip` with vDSP's exact packing and 2x forward scaling, `vvtanhf`) plus an `OSAllocatedUnfairLock` polyfill over a priority-inheriting pthread mutex. A golden fixture captured from real Accelerate on macOS (`AccelerateShimTests`, `MPXPRIME_CAPTURE_GOLDEN=1` to regenerate) pins the shim's numerics. The file list below notes each file's target.

**Linux web dashboard encoder (Tier 1 since 0.50):** the same manifest builds the `MPXPrime` executable on Linux (`#if os(Linux)` at manifest level) with targets `MPXPrime`/`MPXPrimeCore`/`MPXPrimeNative`/`MPXPrimeRecording`/`MPXPrimeAcceleration`/`CAlsa` (libasound system library). GUI, Meter, and tuner targets are macOS-only; GUI/CoreAudio source files carry whole-file `#if os(macOS)` wraps. The Linux runtime replaces `AudioOutputEngine` with `ALSAAudioEngine.swift` (`#if os(Linux)`): a blocking-write ALSA playback thread pulls `StereoInputRingBuffer` -> `MPXGenerator.render*` -> interleave/convert (FLOAT_LE -> S32_LE -> S16_LE negotiation) -> `snd_pcm_writei` with `snd_pcm_recover` xrun handling, and a capture thread feeds the same lock-free ring from `snd_pcm_readi`; both threads request SCHED_FIFO best-effort and enable FTZ/DAZ. Device names are ALSA PCM strings carried in the same `input_device_uid`/`output_device_uid` INI keys. The verifier gates run identically on Linux; strict baselines are per-platform (`Tests/Verification/baselines/default-linux-x86_64.json` vs macOS `default.json`) because Glibc libm and the shim's SIMD tanh differs from Apple libm + vvtanhf at rounding level.

The Meter's SDR input runs **in-process**: `SDRLibraryInputSource` opens the dongle through `CMPXTuner` (`mpxtuner_open`), and the library's capture+demod thread delivers float MPX blocks (1.0 == 150 kHz, the -6 dB headroom) straight to the engine's `frameSink` -- no subprocess, no FIFO, no int16 WAV round-trip. Live controls (frequency, IF bandwidth, gain / auto gain, PPM, Bias-T, RTL2832 digital AGC) enqueue commands applied on the capture thread between IQ blocks, so they never interrupt the stream. `mpxtuner_list_devices` enumerates attached units across both backends (name + serial); `MpxTunerConfig.backend` / `device_serial` pin a specific unit (multi-RSP / multi-RTL benches; the Meter persists the choice by serial and offers an SDR picker when more than one unit is attached, plus a live-apply monitor Output picker so two app instances can meter two stations). The standalone `tuner/` CMake executable (`mpx-tuner`) still builds for CLI debugging but is no longer shipped; the in-process backend is GUI-only, so a headless terminal SDR readout means piping an external `fm-sdr-tuner`/`mpx-tuner` composite into `scripts/run-meter.sh --stdin`. `scripts/run-meter.sh` is the single launcher (the old `run-meter-sdr.sh` was folded in once SDR went in-process and the GUI auto-detects a dongle; `--sdr-freq <MHz>` opens the GUI pre-tuned). The SDR deviation scale is **math-absolute** (set by the discriminator's kHz-per-sample, independent of tuner gain/AGC), so it needs no calibration -- only the audio-device path is pilot-referenced (unknown analogue gain).

Further Meter runtime behaviour (0.41 cycle): an **MPX pass-through** duplicates the raw composite into its own ring and plays it via a second `MeterMonitor` to a user-chosen device with a 0..+12 dB gain (the device's nominal rate is forced to the capture rate while active and restored after -- a 48 kHz output would SRC away the subcarriers); a **decode-path DC blocker** (2 Hz `DCTracker`, live-toggleable checkbox, default on) sits ahead of `MPXDecoder` only -- a transmitter carrier offset becomes DC after demod (off-centre vectorscope, DC in monitor/recordings); pilot PLL, RDS decode, composite scope, and the always-tracked measurement path are unaffected. The frequency field takes **1 kHz resolution** (audio links sit off the broadcast raster; numeric fields clamp but never snap typed values to the scroll step). The vectorscope's display gain **auto-rides the program level** (fast shrink / slow release toward ~85% field fill; smoothed on the VM, delivered via telemetry). **SIGTERM is routed through `NSApp.terminate`** so scripted kills release the SDRplay selection and RTL handle -- an unclean kill leaves the SDRplay service ghost-holding the RSP for a dead PID (unit vanishes from enumeration until replug); a device-lost RTL handle is deliberately abandoned rather than closed (`rtlsdr_close` writes registers over USB and SEGVs on a dead handle; the abandoned unit's USB claim persists until replug or app exit, and the status line says so).

**Meter measurement engine** (`MeterAnalysis` + `MeteringPrimitives`, MPXPrimeCore; rewritten post-0.38 against ITU-R SM.1268-5 / BS.412-9 and instrument practice, with a deterministic test suite `MeterAnalysisTests` that synthesizes composites of exactly-known deviation and asserts the readings): the deviation/MPX-power path is DC-tracked (sub-Hz one-pole; fast 5 Hz acquisition during the 1 s warm-up -- an SDR carrier offset otherwise skews +/- peaks apart) and band-limited to 60 kHz with a **linear-phase Kaiser FIR** (`BlockFIRFilter`, `vDSP_conv`) -- linear-phase because the previous 6th-order Butterworth IIR overshot/rang on clipped-composite edges and read deviation the transmitter never emitted; the FIR also rejects the RTL-SDR FM-demod noise triangle. Scopes/spectrum/IN stay raw. Peak statistics use **50 ms peak-hold slots** (20/s, Pira / SM.1268 heritage): MAX DEV = trailing 1 s max, PEAK +/- = trailing 60 s max (self-recovering; impulses age out instead of latching until reset), plus the **SM.1268-5 sec 4 compliance statistic** -- % of deviation samples above 77 kHz (75 + 2 kHz tolerance; the recommendation's violation criterion is 10^-4 %). MPX power is a **uniform sliding 60 s window** (ring of 1 s mean-squares, sample-exact slot rolls, oldest slot complement-weighted against the current partial second so the window is exactly 60 s at any instant -- BS.412's "any interval of 60 s", matching the transmit-side `BS412PowerLimiter`'s ring-buffer approach, not an EMA), with a max-over-placements readout (MPX MAX) since compliance is judged on the worst window. RDS deviation is measured **coherently**: quadrature mix at 57 kHz -> 6th-order Butterworth 3 kHz anti-alias on I/Q -> decimate to ~12 kHz -> linear-phase FIR (2.6 kHz pass / 3.6 kHz stop) -> in-band RMS `2*sqrt(E[|z|^2])` scaled by the **EN 50067 shaped-biphase peak/RMS form factor** (`shapedBiphasePeakOverRMSSqrt2` = 1.320, a constant of the spec's cos(pi*f*td/4) pulse shaping, measured from the spec-exact BasicRDSCoder). The displayed value is the **peak deviation of the subcarrier -- the injection level the encoder was set to** (the industry display convention: encoders peak-normalize the shaped waveform, EN 50067 sec 1.3's +/-1.0..7.5 kHz range is a peak range, FCC/NRSC budget injection as peak deviation, and Inovonics/R&S/Pira instruments read/set peak -- R&S K7S's factory default detector is +/-Peak/2). Deriving it from the RMS rather than a raw envelope-peak detector matters off-air: a raw RMS reading sits ~24% LOW on shaped biphase (the 0.39 under-read -- the envelope dips through zero at symbol transitions), while a raw PEAK detector rides composite-clipper intermod inside the 57 kHz window on heavily-processed stations (measured 2.5-3x over-read, unsteady; R&S 7BM105 documents the same PK-under-noise bias). RMS + spec form factor reports the peak-convention number with power-domain (quadratic, not linear) sensitivity to in-band IM/noise. The encoder round-trip test (`encoderRoundTripReadsTheSetInjection`: set 2.0 -> read 2.0, guard > 1.85) pins the convention; note an UNMODULATED 57 kHz test carrier deliberately reads its amplitude x 1.320 (the calibration target is spec-shaped data, not a bare tone). 53 kHz stereo-difference energy is rejected > 85 dB where the old single Q=10 biquad leaked it into the reading. The **pilot-to-RDS subcarrier phase** (EN 50067 sec 1.2 -- the angle to the third harmonic of the pilot, which the standard requires to be 0 or 90 deg +/- 10) is measured by `PilotRDSPhaseMeter`: one free-running 19 kHz NCO supplies both references (the 57 kHz one via the triple-angle identities, so they are phase-coherent by construction), each driving an **identical** `QuadratureLockInChain`, and the answer is `phi_rds - 3*phi_pilot`. The chains are identical on purpose, not for tidiness: the NCO never sits exactly on the pilot (transmitter +/-2 Hz plus capture-clock ppm), so both baseband phasors rotate -- the 57 kHz one three times faster -- and mismatched filter group delays would turn that into an error of `3w(tau_p - tau_r)` (2 Hz through a 2.5 ms mismatch = 5.4 deg, half the spec window); matched chains cancel it identically, with no frequency estimator or loop. Reusing `PilotPLL` here would NOT work -- its 20 ms lock-in is unmatched and 0.5 Hz of offset alone would bias the reading ~11 deg. The BPSK 180 deg ambiguity of the suppressed-carrier subcarrier is removed by squaring (Viterbi & Viterbi m=2) before a ~2 s average, so the result is known modulo 180 deg and is folded to an unsigned 0..90 (0 = in phase, 90 = quadrature -- folding also avoids a signed reading flickering between +90 and -90 on a quadrature station). Validity needs all three of pilot presence, a coherence (`|E[z^2]|/E[|z|^2]`, which is exactly the in-band SNR) at or above 0.3, and at least 0.8 kHz of RDS -- the level gate is NOT redundant, since coherence is scale-free and the residual pilot leakage into the 57 kHz chain is perfectly coherent, so a station with no RDS reads a confident angle on ~0.01 kHz of leakage without it. `MeterRDSPhaseTests` pins the conventions (0 / 90 / anti-phase / 45), the offset immunity, the 53 kHz rejection, both gates, and an encoder round-trip, plus an accuracy contract stated against the instrument the readout is modelled on -- the Pira P175/P275 specifies +/- 4 deg for this measurement, and the sweep test requires under 1 deg across 0..90 (measured worst case 0.12 deg clean, 0.00 deg under a 10 Hz pilot offset, 0.14 deg at the 0.8 kHz gate floor). The display conventions deliberately match Pira's too (unsigned 0..90 fold, +/- 10 deg tolerance, blank when the phase relation is not stable): MPX Prime Studio derives its 57 kHz carrier from the emitted pilot's recurrence via the same triple-angle identity, so it must read in phase. MPX power remains only trustworthy on a strong, clean, multipath-free signal (weak/noisy reception inflates both peak deviation and MPX power). Alongside MAX DEV the same trailing-1 s slot array yields **AVE** and **MIN** (the in-progress slot is excluded -- it has seen only part of its 50 ms and would drag both down); MAX far above AVE is a peaky, lightly-processed signal. The slots also feed a **deviation histogram**: 1 kHz bins over 0..120 kHz plus an overflow bin, accumulated since the last peak reset and binned with the previous block's kHz scale (the same one-block lag as the exceedance threshold), from which `devDistributionAtOrAbove(kHz)` gives the accumulated distribution and `devHistogramMaxKHz` the highest bin ever filled. The distribution is the metric a single MAX number cannot substitute for -- it answers "how much of the programme reaches the limit" -- and wants 15-60 minutes of programme to be representative. Three further quantities come free from the existing measurement path: **carrier offset** (the DC tracker's estimate scaled to kHz -- an FM demod turns a transmitter carrier offset into composite DC), **baseband noise** (the exact complement of the 60 kHz measurement FIR, recovered as `delayed - filtered` through a delay line of the FIR's own group delay, which is phase-exact and cheaper than a second FIR; nothing is legitimately modulated above 60 kHz so it is demod noise and interference), and from it a 0..4 **signal quality** scale on fixed noise thresholds. **Stereo balance** is a heavily-smoothed (~3 s) L/R RMS ratio in dB, gated on both channels carrying signal. On the RDS side `RDSReceiverState.groupOrder` keeps the last 18 group buckets in transmission ORDER: the counts say what an encoder sends, the order shows how it interleaves them (a scheduler pattern, a starved type, one type bursting). All of these are covered by `MeterDeviationStatisticsTests` / `MeterQualityMetricsTests` and pinned against known-answer synthetic composites. The engine's headline readings were cross-validated against a commercial measuring receiver on a live commercial station (2026-07-07): pilot and RDS matched exactly (5.6-5.7 / 3.5-3.7 kHz on both instruments), and max deviation agreed within 1-2 kHz side-by-side -- inside SM.1268's +/-2 kHz instrument accuracy requirement. When comparing peak deviation against a reference receiver, compare LIVE at the same moment: peaks are program-dependent, and reception path (multipath) inflates them.

**Meter measurement integrity** (0.45 audit, one plumbing layer per finding class): the dashboard must never present a confident number it cannot stand behind. Three signals feed it. (1) **Dropped samples** -- the composite ring between capture and analysis reports overflows and torn reads through `StereoInputRingBuffer.transportSnapshot()`, and the tuner's own IQ ring reports overwrites through `mpxtuner_iq_drops()` (added 0.45: the SDRplay ring counted nothing at all and the RTL counter was a function-local static nothing could read; retune flushes are deliberately not counted). Either one rising raises a red SAMPLES DROPPED badge, because a gap is baked into every accumulated reading -- peak-hold MAX DEV, the distribution, the BS.412 max window, the SM.1268 exceedance count -- and it stays up until Reset Peaks. (2) **Liveness** -- the frame sink timestamps each delivery, and over a second of silence while capture still claims to run raises NO INPUT (a wedged USB device keeps `alive` true, so the readings froze while looking live). (3) **Decode state** -- `MPXDecoder.stereoDecodeActive` reaches the snapshot, and a mono decode raises an amber MONO DECODE badge while separation / balance / phase correlation read `--` (`MeterAnalysis` also stops updating the separation peak-hold and the balance smoother, which would otherwise hold their stereo-era values through a lock loss). (4) **Input faults** (0.65) -- the ingress guard replaces NaN / Inf with silence and counts them, and a repaired sample is treated as a HOLE: its block stays out of the exceedance and histogram accumulators, `peakValid` is withheld while the hole is inside the peak window and `mpxPowerValid` (plus the compliance max) while it is inside the BS.412 window (`inputFaultInWindow`), and `nonFiniteInputSamples` raises a red BAD INPUT badge that stays until Reset Peaks (`MeterInputFaultTests`). Beyond those three, every readout carries an explicit validity flag and shows `--` rather than a number it cannot justify: `peakValid` / `devScaleValid` (no kHz-per-unit scale -> the deviation strips, PEAK +/- and MPX power blank instead of reading 0.00; the pilot-referenced scale requires the SAME pilot-presence threshold the PILOT indicator uses, held ~0.4 s across a fade, where it used to be accepted from pilot amplitude 1e-5 -- 200x lower, so lock-in noise on a dead frequency produced an enormous scale and a fake max deviation with nearly every sample "over 77 kHz"), `exceedanceValid` only after a full minute (the SM.1268-5 criterion is one sample in a million; a 1 s window at 192 kHz resolves 5.2e-4 %, so `exceedanceBoundPct` publishes the supported upper bound until then), `pilotRDSPhaseValid` gated on one full averaging time constant plus a fast-vs-slow STABILITY comparison (`PilotRDSPhaseMeter.driftDegrees` <= 4 deg -- coherence primes at exactly 1.0 on its first sample and is scale-free, so it neither proves averaging happened nor that the angle stands still; both failure modes are pinned by tests), `stereoCorrelationValid` on a mean-removed Pearson coefficient gated on programme in both channels, `qualityValid` separating no-data from a measured Unusable, and an expiry on the balance smoother. Retune resets the decoder, pilot PLL and decode-path DC blocker along with the accumulators, and a calibration change (pilot reference or absolute full scale) resets the peak / exceedance / distribution / BS.412-max accumulators that were measured at the old scale. Two conventions were also made explicit in 0.45 (audit P2): the DECODE path's receiver de-emphasis is a live setting (`MeterAnalysis.setPreemphasisUS`, 50 / 75 us, persisted, an input-bar picker and the `--deemphasis` CLI flag; it was hard-wired to 50 with nothing able to reach it, so 75 us markets monitored and recorded ~3.4 dB bright at 15 kHz -- it reconfigures the decoder only on a real change, and `MeterDeemphasisTests` pins both curves against the analogue formula), and `--full-scale-khz` now works on the audio-DEVICE path as well as `--stdin`, with the startup line naming the calibration convention actually in use. On the SDR side the shipped default IQ capture rate STAYS at 1000 kHz: the audit reasoned from the code that 0 (narrow) was preferable because factor 1 keeps the byte-exact packed-uint8 RTL path, but an RTL bench A/B refuted it -- at factor 1 with `bandwidth_khz = 0` nothing band-limits the IQ ahead of the FM demod, and peak deviation read +21 kHz high, RDS level +46%, baseband noise +50%, with an unstable pilot/RDS phase; at factor 4 the decimator supplies the channel filtering as a side effect, and setting an explicit 200 kHz bandwidth at factor 1 reproduces the factor-4 figures exactly (numbers in project-roadmap.md and meter-operator-guide.md). The underlying defect -- the demod's ctor installs a +/-110 kHz IQ filter but leaves `m_bandwidthMode` at 0 unapplied, so "auto" is not the filter it appears to be -- is recorded for a decision rather than patched under one dongle's evidence. The wide path's `ComplexDecimator` went from 12 to 32 taps/phase (48 -> 128 taps at factor 4) so it is no longer the dominant channel filter inside an FM signal's +/-90 kHz Carson band, and its overload detection now shares one threshold with the packed path (`isIqSampleSaturated`, the normalised value of the innermost byte code the byte test calls saturated -- the old hard-coded 0.995f was asymmetric against the byte mapping). GUI-side (0.45 audit P3): the spectrum card's RF span chip reads a pre-formatted `rfSpanText` from telemetry INSIDE a `LiveObservationView` (reading the raw Hz in the root body re-triggered the 0.34 toolbar-relayout leak at 20 Hz in RF mode, cancelling the isolation), `statusText` is a Combine subject rather than `@Published` (no body reads it, but every retune re-laid-out the window and toolbar), and the display gate polls the dashboard window's own occlusion instead of an arbitrary `NSApp` window. The decoded monitor and the MPX pass-through drain their rings through `readAdaptive` (their producer is the capture/SDR clock, so a plain read drifted into an underrun click or a saturated ring), a monitor device swap no longer tears down the independent pass-through player, and both players report a start failure instead of swallowing it. Teardown ordering is fixed on both sides of the C ABI: the engine's `deinit` stops the input before freeing the buffer the capture callback writes, `SDRLibraryInputSource` has a `deinit { stop() }` (the tuner callback holds an unretained pointer), and `mpxtuner_close`/`_fast` wait for the capture thread's own acknowledgement with a deadline -- on a miss they detach and deliberately leak the tuner rather than freeing state it still dereferences. Stop and device loss run `MeterTelemetry.reset()` so nothing on screen outlives the capture that produced it, and capture refuses to start below 128 kHz -- the measurement band is 0-60 kHz with RDS at 57 kHz, and lower rates silently excluded the stereo sidebands and counted them as noise. The recording path carries its own contract (see the WAV recorder note under "Project" in AGENTS.md): 64-bit byte counter with a clean stop at the RIFF 4 GiB limit, NaN/Inf sanitised before packing, the header patched every ~2 s so an interrupted capture stays readable, `failureReason` polled per tick to stop the recording and tell the operator why, and finalization off the caller thread.

- `main.swift`: CLI entry point, config loading, audio engine lifecycle (platform-split runtime: NSApplication + `AudioOutputEngine` on macOS, `dispatchMain()` + `ALSAAudioEngine` on Linux; verify/bench dispatch is shared). Verifier modes: `--verify`, `--verify-presets`, `--verify-long`, `--verify-receiver` (0.27), `--verify-multiband-coupling` (0.28; the 0.28 `--verify-composite-multiband` mode left with its stage in 0.45), `--verify-advanced-dynamics` (0.44), `--verify-ssb-stereo` and `--verify-hf-transients` (0.45; the latter is the hi-hat / cymbal distortion gate: receiver-side HF SINAD, HF crest loss and 15-23 kHz composite spill per chain variant -- field chain, every Format Profile, per-stage isolation rows), `--verify-stereo-guard` (0.45: sweeps the composite clipper's stereo-guard share 0...1 on the Music - Loud profile and the loaded config -- clipper / Final-MPX limiter duty, peak, deviation, 10 / 14 kHz separation, encoder-side M/S balance at 14 kHz, decoded hard-panned side/mid, ride / hat HF SINAD -- the table the `mpx_clipper_stereo_guard` default is chosen from), `--verify-final-ride` (0.45: attributes the Final-MPX limiter's duty by switching one composite-clipper candidate off per row -- guards, oversampling, knee, look-ahead, limiter, shaper -- on a hot chain and Music - Loud, printing clipper GR, limiter GR, safety-clip duty, audio-composite and true peaks), `--verify-program-ab <file-or-dir>` (0.45, macOS-only: real-music A/B for the Advanced Dynamics default-flip campaign -- decodes user-captured audio via AVFoundation, renders each excerpt through the shipped Format Profile with AGC+multiband vs Advanced Dynamics, measures both composites with the Meter engine (BS.412 power, max/ave deviation, SM.1268 exceedance) plus decoded crest / HF crest / image / band-balance deltas and a 0.5-4.5 Hz pumping index of the B/A envelope ratio; RDS off for render determinism, pilot on; thresholds calibrated + armed 2026-09-04 on a captured operator corpus (`programABGatesArmed`), the pumping index aligning the chains' envelopes first (~10 ms leveller group delay would otherwise read as beat-rate wiggle); `--ab-profile` picks the profile, `--ab-csv` exports rows; corpus captured with `scripts/capture-program.sh`). 0.36 extended `--verify-receiver` with composite-clipper guard-band cancellation depth (pilot 17-21 kHz / RDS 55-59 kHz) and a pilot/RDS phase-lock drift gate, added a 4x-oversampled true-peak (BS.1770-style) inter-sample-overshoot metric to `--verify`, and bumped the `--baseline-strict` baseline to schema 3 (adds the true-peak field plus a global encoder-side sideband fingerprint -- asymmetry + side/mono delta at 1/10/14 kHz). Also dispatched here: `--capture-baseline` (writes the platform-suffixed baseline for the selected gate), `--bench` and `--bench-blocks` (`BenchmarkRunner.swift`: full-chain cost report and the block-size sweep).
- `AudioOutputEngine.swift`: AVAudioEngine output setup, render callback, transport orchestration. Delegates input capture to `InputAUHAL`.
- `InputAUHAL.swift` (MPXPrimeCore): Direct AUHAL (`kAudioUnitSubType_HALOutput`) input-capture wrapper. Replaces a second `AVAudioEngine` instance the engine used to spin up for input -- AVAudioEngine's first `start()` with a non-default input device intermittently failed to deliver tap callbacks. The two-AUHAL pattern (separate input AU + output AVAudioEngine + `StereoInputRingBuffer` as the only bridge) is what TN2091 / CAPlayThrough / Stereotool / AudioKit's non-default-device path use on macOS.
- `MPXGenerator.swift`: the real-time engine class (chain wiring, live-apply, telemetry). Stages live one-per-concern in `DSP/` (`DSPSupport`, `PeakLimiters`, `ToneShaping`, `Dynamics`, `AudioClippers`, `CompositeClipper`, `LinearPhaseFIR`, `SSBStereoEncoder`), the RDS encoder in `RDS/BasicRDSCoder.swift` (0.45 split, pure moves).
- `MPXDecoder.swift` (0.27, PLL refactor in 0.28): Reusable FM-stereo demodulator. Used both by the audio render callback for monitor output (with the internally generated, delay-aligned 38 kHz reference) and by the offline verifier (with a pilot-PLL recovered reference). 0.28 replaced the bandpass + phase-discriminator PLL with an I/Q coherent lockin demodulator -- slow IIR-smoothed estimates of `mpx | sin(omega_p | t)` and `mpx | cos(omega_p | t)` at the local oscillator, then the doubled-phase subcarrier is recovered via trig identities. Effect: external-style PLL decode now matches synthetic-reference coherent decode within 0.1 dB at every test tone. Includes a smoothed noise gate and a stereo-collapse cooldown that re-initialises the PLL if it ever drifts off-lock. Lives in the `MPXPrimeCore` SPM target (shared by the transmit app and the verifier; the hot `process()` is `@inlinable` so it still inlines across the module boundary). 0.36 added non-finite-input sanitization at the top of `process()` -- a single NaN/Inf sample used to permanently poison the pilot-lock I/Q and envelope state (the exponential smoothers never flush NaN and the self-heal could not re-arm). 0.45 closed the loop and gated the decode (Meter audit M1/M2/M16): the lock-in phase correction is now driven by a second-order PLL (loop bandwidth ~2 Hz, critically damped: `kp = 2 omega_n / fs`, `ki = omega_n^2 / fs^2`, integrator into the NCO step) so a pilot frequency offset no longer leaves a residual phase error -- the fixed-lag correction measured 47.7 dB separation at 25 ppm and 24.8 dB at 100 ppm against 64.4 dB on frequency (an untrimmed RTL dongle's capture clock is ~100 ppm), and all three now read 64.4 dB; on-frequency decode is bit-comparable, so the stored `receiver.json` baseline did not move (`MeterDecodeIntegrityTests` pins the sweep, with a measured A/B of the tracking disabled). The pilot-lock gate became LEVEL-RELATIVE (pilot carrying at least ~2.5% of the composite mean square, tiny absolute floor for true silence) instead of an absolute magnitude that required pilot amplitude 0.02 in raw units -- 100x the Meter's own pilot-present threshold, which left a 20 dB window where the decode was silently mono; `stereoDecodeActive` publishes the state so the Meter can blank the stereo-image readouts (see the Meter section) rather than presenting the mono decode as a measurement, and the reference path (Studio monitor, verifier) reports it as always active. A sub-Nyquist capture rate (no room for the 38 kHz subcarrier) now decodes exact mono instead of demodulating aliases, and two dead biquad cascades were removed from the `@inlinable` hot path.
- `RDSStreamDecoder.swift` (MPXPrimeCore, 0.31): Symmetric receive-side RDS decoder -- the counterpart to `BasicRDSCoder`. Operates on recovered RDS data bits (differentially-decoded 1187.5 bps stream): BCH offset-word block synchronization, CRC-checked group assembly, and PI/PTY/TP/TA/MS/DI/PS field accumulation. Exports public `RDSGroup` / `RDSReceiverState`. Used by the offline verifier and the `MPXPrimeMeter` analyser app; round-trip tested against `BasicRDSCoder`.
- `BandLimitedStep.swift` (0.27): Allocation-free BLEP/BLAMP correction helper for the US 6,937,912 anti-aliased clipping work. Detects fractional threshold crossings and schedules normalised finite correction windows in impulse / step / ramp shapes.
- `AcceleratedBandlimitedResidualClipper.swift` (0.27): vDSP-accelerated patent-style residual-bandlimiting candidate clipper (hard-clip -> bandlimit the residual -> reconstruct as delayed-clean + filtered-residual). Wired as the inner kernel of `OversampledPeakLimiter` / `StereoLinkedOversampledPeakLimiter` behind the off-by-default `pre_encode_bandlimited_residual_enabled` opt-in.
- `AppConfig.swift`: Configuration model, INI parsing/serialization.
- `MPXPrimeViewModel.swift` + `AppDelegate.swift` + `UI/*.swift`: SwiftUI views and state management (0.45 split of the former `SwiftUIControlApp.swift`: navigation model, root views, monitoring dashboard, processing tabs, settings/RDS tabs, help/about, shared controls). `VerificationHarness.swift` + `Verification/*.swift`: the offline verifier, one file per mode.
- `AudioDevices.swift` (MPXPrimeCore): CoreAudio device enumeration; resolves UIDs to `AudioDeviceID`s and provides the `defaultInputDeviceID()` helper AUHAL needs (AUHAL requires an explicit device, unlike AVAudioEngine which inferred the default implicitly).
- `INIParser.swift`: INI file read/write.
- `Control/`: the remote-control plane (`ControlServer`, `ControlBackend`, `HeadlessControlBackend`, `GUIControlBackend`, `ConfigPatch`, `PresetCatalog`, `SnapshotStore`, `DeviceCalibrationStore`, `InstallationKeys`, `AudioDeviceListing`, `WebUI/`).
- `Verification/`: one file per verify mode (`VerificationCore`, `ReceiverModel`, `QualityMetrics`, `PresetSweep`, `StageABGates`, `AdvancedDynamicsGate`, `HFTransientGate`, `FinalRideIsolation`, `ProgramABGate`) behind the `VerificationHarness.swift` dispatcher; `VerifierBaseline.swift` holds the baseline schema + compare; `BenchmarkRunner.swift` implements `--bench` / `--bench-blocks`.
- `UI/`: `AppConstants`, `NavigationModel`, `RootViews`, `PageScaffold`, `RestartKeys`, `MonitoringDashboard`, `MonitoringWindows`, `AudioIOTab`, `ProcessingTabs`, `RDSTabs`, `SettingsWindow`, `SnapshotsAndTestTone`, `HelpAndAbout`, `SharedControls`; plus the pre-split `UIBroadcastStatusBar`, `UISignalFlowStrip`, `UIProcessingOverview` and `UILiveTelemetry.swift` (the `@Observable` per-tick `LiveTelemetry` object). `NowPlayingSupport.swift` + `RDSTextParser.swift` feed RT metadata from an external script.

## Audio output modes: FM, HD and AM (0.50)

The three audio-output modes differ from each other in the table below.
`hd` is resolved through `AppConfig.processedAudioDigitalDelivery`
(`operatingMode == .hd`). `MPXGenerator` seeds
`digitalDelivery` from it at construction (the same rule as `audioOutputOnly`,
so the verifier and the Linux ALSA engine see it too), and every difference is
gated on that single flag, which is why the composite path cannot be reached
by this feature:

| Stage | `fm` | `hd` | `am` |
| --- | --- | --- | --- |
| Program + encoder lowpass | FM caps (15.3 / 14.9 kHz emphasised, 16 kHz flat) via `effectiveProgramLowpassHz` / `effectiveEncoderLowpassHz` | the configured `program_lowpass_hz`, up to 20 kHz | `am_lowpass_hz` (3-10 kHz), applied by seeding `programLowpassHz` |
| Pre-encode limiter decimator passband | 15 kHz (it doubles as the emphasised-domain band limit) | the program bandwidth, via the `passbandHz` parameter | 15 kHz (the AM band limit is far below it) |
| Pre-emphasis + encoder HF guard | as configured (the analogue FM network) | forced off (the guard disables itself at 0 us) | `am_preemphasis_us` selects the NRSC-1-C curve or flat -- a DIFFERENT network from FM's, zero at 2122 Hz AND pole at 8700 Hz, so it reaches exactly +10.00 dB at 10 kHz where the FM 75 us curve would be 3.66 dB hotter and still climbing; guard off |
| Stereo-image protection | as configured (`stereo_image_protect_enabled`, default off since 2026-10) | bypassed (no deviation or multipath to protect) | bypassed (the feed is mono) |
| Final loudness clipper | optional, when the coder has none | never | never (the peak guard owns the peaks) |
| Output make-up | limiter ceiling normalised to full scale | limiter ceiling mapped onto `processed_audio_ceiling_dbtp`, less a 0.1 dB margin | limiter ceiling normalised to full scale (the POSITIVE bound) |
| Channel handling | stereo | stereo | L+R summed BEFORE the chain, so every stage levels the on-air signal |
| Output peak guard (`StereoTruePeakGuard`, `DSP/TruePeakGuard.swift`) | the same stage as `hd`, ceiling at full scale; adds 2 ms of delay | after the make-up: stereo-linked gain rider on a 4x Kaiser reconstruction detector, 2 ms look-ahead, gain ramped over the look-ahead by `LookaheadGainRamp` (no step; an output floor absorbs Float rounding only), no clipping; adds 2 ms of delay | same stage with ASYMMETRIC ceilings: positive at full scale, negative at `100 / am_positive_peak_pct` |

`oversampledLimiterCeiling(threshold:)` in `DSP/PeakLimiters.swift` is the one
rule for the limiter's hard bound, shared by the limiter's own `configure` and
by the make-up, so the two cannot drift: mapping the THRESHOLD instead reads
about 1.3 dB hot, which is how the sharing was found.

AM's asymmetry (47 CFR 73.1570: positive peaks to 125 % with the negative peak
at 100 %) is why the guard's two ceilings are separate. The make-up normalises
onto the POSITIVE bound and the guard holds the negative one: normalising onto
the negative bound instead would cap both halves there and the asymmetry could
never be used, because the pre-encode limiter bounds |x| symmetrically. So
symmetric program lands symmetric and only positive-heavy program (speech, most
single-instrument material) uses the extra room. `AMOutputTests` pins the mono
sum, the NRSC-1 curve (checked against the standard's table, and against
the FM curve so the two cannot be confused again), the band limit and both
peak cases.

The guard exists because the limiter alone is not a true-peak bound on hard
transients: it clips in its 4x domain and then decimates, and the decimation
FIR rings on what it just clipped, so the limiter's output read +1.4 dB over
its ceiling on a click program (a 3 ms look-ahead in the limiter did not
help; the ringing is downstream of the clip). On the composite path the
composite clipper and the final look-ahead limiter follow and catch it; on
the processed-audio targets the guard does, in FM Output too since 2026-10
(before that FM had no guard, and dense programme reached the hard clamp).
Measured with an independent 8x / 90 dB reconstruction: bright dense,
hard-panned HF and click programmes all land within 0.05 dB of the ceiling
with the guard in place. The limiter's interpolator is a 4x linear-phase
Kaiser FIR, flat to 0.001 dB; the one-sided Lagrange-4 it replaced in
2026-10 rippled the response by +0.32 dB at fs/4 and -0.41 dB at 3fs/8, on
the FM chain too.

## Measurement provenance

The composite output has been validated on a commercial measuring receiver
against a 75 kHz total-deviation reference. The headline subcarrier levels read as
expected and, importantly, read steady -- both subcarriers are injected after all
peak-control stages at constant amplitude, so their deviation does not move with
program audio.

| Subcarrier | Setting | Measured (reference receiver) | % of 75 kHz |
|------------|---------|-------------------------------|-------------|
| 19 kHz pilot | 10% | 7.3-7.4 kHz (steady, last-digit dither) | ~9.8% |
| 57 kHz RDS | `rds_level` 2.4 kHz | 2.4 kHz (steady) | ~3.2% |

Notes:

- The 7.3/7.4 kHz pilot reading is the analyser rounding a ~7.35 kHz value across
  its display resolution, not the pilot modulating. A pilot that genuinely wandered
  with program would indicate a fault -- by design the pilot here is constant
  amplitude (post-clipper injection).
- Pilot is at the top of the 8-10% legal window; RDS at 3.2% is comfortably inside
  the EN 50067 / IEC 62106 range (2.0 kHz nominal, 1.0-7.5 kHz permitted) and a touch
  above the 2.0 kHz default for more robust data decoding.
- Subcarriers (~9.75 kHz combined) share the +/-75 kHz peak budget with the audio
  composite; the audio path is clipped to leave room for them, which is why they can
  be injected at fixed amplitude without pushing total deviation over target.
- Confirm the analyser's total-deviation reference is 75 kHz before reading the
  percentages. On a 50 kHz reduced-deviation mandate the same kHz figures correspond
  to different percentages (and the pilot/RDS levels should be scaled accordingly).

The receive side has the same pedigree: **MPX Prime Meter's readings were
cross-validated against the same reference receiver on a live commercial station** -- pilot
and RDS matched exactly (5.6-5.7 / 3.5-3.7 kHz on both instruments), and max
deviation agreed within 1-2 kHz measured side-by-side at the same moment,
inside ITU-R SM.1268's +/-2 kHz instrument accuracy requirement. When
comparing peak deviation against any reference receiver, always compare live
at the same moment: deviation peaks are program-dependent, and a weaker
reception path (multipath) inflates them.

**Offline separation gates (2026-10 audio-chain overhaul).** The verifier
gates stereo separation where it can regress, with one measurement shared by
every gate (`Verification/SeparationGates.swift`: render through
`MPXGenerator`, exact pilot-phase fit, coherent decode, one 2^17-point Hann
FFT over the settled tail, L - R per octave band from 200 Hz to 15 kHz).
`--verify` carries `panned_program` (program_mix into the left channel only;
decoded side retention >= 0.95 and the per-band crosstalk gate, 40 dB up to
10 kHz and 30 dB above, in its own verdict) and `wide_program` (program_mix
re-balanced to S/M 1.3; retention >= 0.95), `stereo_diff_400hz` allows 12 dB
of RMS drift (was 30) and `wide_bass` demands 0.90 side retention (was 0.30).
`--verify-receiver` holds coherent separation at 40 / 40 / 30 dB (1 / 10 /
14 kHz; was 18 / 16), prints a left-only tone set (1 / 5 / 10 / 14 kHz at
0.1 / 0.3 / 0.5 FS on Music - Clean and Music - Loud, processed against
`processing_bypass`; >= 40 / 30 dB processed, <= 6 dB loss at 1 / 10 kHz, the
A/B taken on figures clamped at 60 dB so a 120 -> 98 dB "loss" at the
numerical floor cannot fire) and the panned-programme crosstalk table
(processed / bypass / encoder-only / protector toggled per band), and its
stage-isolation sweep covers mono bass, Advanced Dynamics, the HF limiter and
the image protector. Two exclusions are printed as marks and not gated: `mb`
(a band under 3x the mono-bass corner while mono bass is on -- the stage
fills the quiet channel by design) and `nc` (a driven band more than 30 dB
under the loudest one; program_mix holds tones at 220 / 880 / 3200 Hz and
about -45 dBFS of noise, so 400-800 Hz and 6.4-15 kHz measure distortion
against nothing). The bypass row is not a clean reference on hot material
(`processing_bypass` keeps Final Drive and the composite clipper); the
"encoder only" row (bypass with Final Drive 0 dB, 96 dB in every content
band) is. `--verify-stereo-guard` scores every share with the same helpers
(acceptance: final-limiter duty <= 1.0 dB, 14 kHz separation >= 20 dB, the
crosstalk floors) and fails when the shipped share misses them; the 0.5
default comes from that table (Music - Loud content bands 60-72 dB at 0.5
against 37-58 dB at 0 and 1.0).

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
- Peaks: the audio thread folds every block's input and output peaks into a
  `MultiReaderPeakAccumulator` (MPXPrimeCore; lock-free, allocation-free, a
  compare-exchange max into each active reader's slot). The GUI, each
  `/api/meters/stream` connection and the headless status tick take and clear
  only their own slot, so no consumer steals another's peak; both engines use
  it.
- GUI refresh: `MonitoringRefreshPolicy` picks the timer tier (live / background
  / quiet 4 Hz) from the engine state and what is on screen, and which
  analyses run (scope history, MPX and audio spectrum) from which monitoring
  windows are visible. A remote `/api/telemetry` or `/api/meters` read keeps the
  taps it needs on for 3 s.

## Current processing order

Within the main audio path, MPX Prime Studio runs:

1. Input gain and mono fold
2. **Phase rotation** (4-pole allpass, optional)
3. Wideband AGC (K-weighted RMS rider; attack default 150 ms since 0.45 -- the 6 ms it shipped with was limiter-fast and ducked program 3.4 dB on a 30 ms drum hit, 0.02 dB now; profiles 100-200 ms; `--verify` flags < 50 ms)
4. Input HPF
5. Program lowpass
6. HF trim
7. **Parametric EQ** (4-band: low shelf + 2 peaking + high shelf, optional)
8. Mono bass (inside `processStereoImageStage`): `MonoBassFilter`, a linear-phase
   complementary pair -- side = delay(side) - KaiserLP(side), -6 dB at the corner,
   mid = the same delay, so the sum is flat and the mid keeps its polarity. Latency
   about 1070 / fc ms when on (10 ms at 110 Hz, 8 ms at 140 Hz). The corner
   (`mono_bass_freq_hz`, 60-250 Hz, live) is per Format Profile: 110 Hz on Music -
   Clean, Speech and Music - Dense (and the shipped default), 115 Hz on Music - Loud,
   90 Hz on Classical. Clean and Speech were 140 Hz until 2026-10-30, the high end of
   broadcast practice (80-120 Hz); that corner alone kept `wide_bass` (its largest
   component is 72 Hz anti-phase) from meeting the width goal on the music profiles.
   The pre-2026-10 `side - LP2(side)`
   was not a highpass: side bass only 4 dB down at 60 Hz and +1.8 dB at 140 Hz.
9. Multiband compressor (3-band or 5-band)
    - **TX path**: linear-phase FIR splitters (sum-to-flat; per-crossover transition = fc floored at 120 Hz, -6 dB exactly at each crossover, 40 dB stopband, kernels zero-padded to one shared group delay -- 446 samples = 9.3 ms at the 48 kHz audio domain with the default 90 Hz lowest crossover; before 0.45 the design ignored the requested transition, sat on the 2049-tap clamp at 21.3 ms and pre-rang ~12 ms at the upper crossovers)
    - **Monitor path**: IIR Linkwitz-Riley LR4 crossovers (low latency)
    - Program-dependent (dual-slope) release per band, default on (0.45): `MonoCompressor` applies its GR through a smoother with a ~1.5 s platform of the demanded reduction -- excursions below the platform (drum hits) release at the configured rate, recovery above it (average level dropped) 3x slower; the pre-0.45 flag only scaled the release time by a constant 1.1
    - Per-band downward expander (optional)
    - Per-band fast peak limiter (optional)
    - **Advanced Dynamics** (`advanced_dynamics_enabled`, default ON since 2026-10-15) runs
      in this slot when enabled and REPLACES steps 3 and 9 entirely: the wideband AGC
      call (step 3) is skipped and the single-stage 5-band leveller runs instead of the
      multiband compressor (including its per-band expander and limiter)
10. (Stereo widener -- removed in 0.50; measured as adding nothing beneficial. The stereo-image protection ratio it used to scale kept the former default, so every widener-off chain stayed bit-identical, until the protection itself became an option in 2026-10, step 16.)
11. PrimeBass (post-multiband; canonical MaxxBass / Aural Exciter / Big Bottom placement so multiband doesn't compress the synthesised harmonics)
12. Bass clipper (LR4 split + tanh-clipped LF band, vvtanhf-batched, optional)
13. Distortion-cancelled clipper (Orban-principle LF cancellation with a zero-phase linear-phase error path, so it only ever removes distortion; 8x, Kaiser FIR decimator, about 2.6 ms at 48 kHz with the 2 kHz corner; vvtanhf-batched, optional)
14. Encoder HF guard (a fixed <= 2 dB stereo-linked HF ride ahead of the encoder lowpass; kept in 0.45 after measurement -- removing it cost 20-40 dB of receiver-side HF separation on the tone test because un-attenuated HF drives the composite clipper into audio-band IM, and the pre-emphasis-domain HF limiter does not engage at those levels)
15. Encoder program lowpass (~15 kHz final audio-bandwidth guard before stereo encoding) -- linear-phase FIR on TX, Butterworth cascade on monitor. (The 19 kHz audio-path notch that followed it was removed in 0.45: the FIR's >80 dB stopband already covers 19 kHz -- receiver gate identical to 0.01 dB with and without it.)
16. Stereo-image protection (operator option since 2026-10, `stereo_image_protect_enabled`, default OFF; `stereo_image_max_side_ratio` 1.0-3.0, 1.55 = the former fixed cap): side/mid envelope limiter, 10 ms / 300 ms, allowed ratio `min(cap, max(1.025, 1.16 x input ratio))`, input reference delay-matched to the output tap (mono bass + leveller FIR split + distortion-cancelled clipper + encoder FIR), idle without a mid reference (input mid under -34 dBFS) so pure-side content passes. Always on before 2026-10 with an absolute 0.008 side floor: anti-phase content lost 24 dB of RMS and wide content was clamped to S/M 1.55 (stereo audit A3); with the widener gone and every dynamics stage linked, the only width left to limit was the source's own. OFF skips the call, bit-identical to a chain without the stage (`StereoImageProtectorOptionTests`); `--verify` gates the width (`stereo_diff_400hz` 12 dB, `wide_bass` 0.90) and `--verify-receiver` prints the stage's cost in both tables
17. Pre-emphasis (L/R domain, immediately upstream of pre-encode limiter; canonical Optimod / Stereotool placement so the limiter peak-controls the +10-12 dB HF-boosted signal; `PreemphasisDesign` biquad fitted to the analogue curve at configure time, 0.45 -- the matched-z zero it replaced under-boosted 0.6 dB at 10 kHz / 1.4 dB at 15 kHz at the 48 kHz audio rate)
18. HF limiter (0.45; L/R domain, default-on in every profile): program-controlled pre-emphasis after Orban US 4,103,243 -- rides only the boost component `pre - flat` with a stereo-linked feed-forward detector, a programme gate per channel (each channel gates its own target, the link takes the more demanding one), 1.5 ms attack / 5 ms hold / 20 ms release; can never cut HF below the flat program level; live-apply (`hf_limiter_*`)
19. Pre-encode audio limiter (L/R domain, `StereoLinkedOversampledPeakLimiter` -- `max(|L|, |R|)` detector drives both channels identically; 2026-10: `pre_encode_stereo_link` (0..1, default 1 = the linked behaviour, bit-identical) drives each channel with `link x shared + (1 - link) x own` envelope, which never attenuates the loud channel less than its own peak needs -- measured to change nothing on any verifier scenario at the shipped levels, because the composite stage after Final Drive, not this limiter, is the peak controller there; 0.30: default-on look-ahead with Dolby HF-subband-aware detector per `US 5,579,404`; 2026-10: the 1:4 interpolator is a linear-phase Kaiser FIR, flat to 0.001 dB (the causal Lagrange-4 it replaced imaged 15 kHz at -16 dB and left a steady 14 kHz tone 0.58 dB under the threshold); 0.45: the 4:1 decimator is a linear-phase Kaiser FIR flat to 15 kHz and 80 dB down from 16.5 kHz at the 48 kHz audio domain, ~640 taps / 1.7 ms -- it is the chain's 15 kHz band-limit in the pre-emphasised domain, since the encoder FIR runs before pre-emphasis and its transition tail arrives +14 dB hotter; the 6th-order Butterworth at 14.4 kHz it replaced cost -2.3 dB at 14 kHz on air and had -27 dB alias rejection)
20. Stereo encoder (M/S encoding, 38 kHz DSB-SC subcarrier)
    - **SSB Stereo** (`mpx_ssb_stereo_enabled`, optional, default off): SSB-leaning
      assembly `diff*sin(2t) - sel*amount*hilbert(diff)*cos(2t)` -- a linear-phase 511-tap
      Hilbert FIR with matched base/diff program delay, opportunistically keeping whichever
      38 kHz sideband currently peaks lower (leaky-peak selection, 3% hysteresis, 5 ms
      crossfade). Decode-compatible with standard receivers; hard-gated by
      `--verify-ssb-stereo` (sideband asymmetry matches theory, coherent separation
      preserved, mono bit-transparent). Both subcarrier phases come from the same pilot
      recurrence (`sin2x`/`cos2x` double-angle), so pilot/subcarrier coherence is untouched.
21. Composite clipper (16x oversampled tanh soft-clip with differential topology: 2x Kaiser FIR + Lagrange-4 interpolation, linear-phase FIR decimation of the clip residual, one coherent linear-phase FIR guard for the audio / pilot / stereo / RDS bands; vvtanhf-batched; OS-rate sliding-window-max look-ahead, 2 ms by default, riding to the ceiling plus the profile's clip depth `mpx_clipper_lookahead_depth_db` since the 2026-10 overhaul). Since 0.45 its ceiling is mapped onto the audio-composite BUDGET (what is left of the composite after the pilot/RDS reservation) instead of digital full scale -- see "Final-stage order and budget reference" below
22. Audio composite bandwidth FIR (55 kHz linear-phase cleanup before pilot/RDS injection)
23. BS.412 multiplex power limiter (uniform 60 s window on the COMPLETE multiplex, dBr-referenced, optional, EU compliance)
24. Final look-ahead MPX limiter (audio composite only, threshold on the budget; rides the in-band overshoot the clipper's guard-band restoration leaves -- the composite-domain overshoot controller, Orban's "half-cosine composite limiter" role; since 2026-10 its detector reads the 4x true peak so inter-sample peaks of the 55 kHz-limited composite are held too; its gain ramps over the look-ahead and never steps)
25. Shaper: the single always-on budget safety soft clip (`audio_composite_softclip_enabled`, 1x; untouched below 0.995 x budget (0.99 until the 2026-10 budget overhaul), then a tanh knee whose asymptote is the budget, so its output never exceeds it; idle behind clipper + limiter, pinned by `CompositeShaperOrderingTests`; catches impossible configurations and the case where both peak stages are disabled). 0.45 removed the duplicate second soft clip, the 54 kHz "smoother" one-pole between them and the idle 0.98 post-gain soft clip (`audio_composite_smoother_enabled` / `final_mpx_softclip_enabled` keys gone)
26. Composite budget governor (smoothed gain ride on audio path so post-injection clamp is unreachable for sane configs; the budget scales with `mpx_deviation_khz` up to 75 kHz, so Composite Deviation is the multiplex peak target)
27. Pilot and RDS injection (post-clipper, constant amplitude, delay-aligned via `subcarrierDelayLine`; their reservation in the budget is the nominal on-air peak of each)

Most optional stages are disabled by default and can be enabled via config/UI. The default processing chain intentionally ships with the wideband AGC, multiband, mono bass, bass clipper, HF limiter, composite clipper, pre-encode limiter, final MPX safety, encoder FIR, and multiband FIR enabled per `AppConfig`.

When `Mono Mode` is enabled, MPX Prime Studio suppresses the pilot, stereo subcarrier, and RDS injection so the transmitted composite is true mono.

## External Dependencies

- AVFoundation / CoreAudio for audio I/O (macOS; the Linux CLI build uses ALSA / libasound)
- Accelerate framework for vDSP (SIMD-optimized metering; on Linux the `MPXPrimeAcceleration` shim substitutes SIMD-vectorized same-name implementations (Swift SIMD8 / SSE2))
- SwiftUI for native macOS UI (macOS-only; on Linux the web dashboard is the interface)
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

`multiband_transient_aware_attack_enabled` keeps the legacy peak detector as the default. When enabled, `MonoCompressor` runs an RMS envelope (10 ms attack / 90 ms release) alongside the peak follower; the peak-to-RMS ratio drives a transient indicator that triggers when peak rises above 1.65x RMS, latched for 10 ms. On a transient the detector blends mostly RMS (peakWeight drops 0.58 -> 0.18) and the attack coefficient stretches to 3.2x the base attack -- kick/snare fronts pass hotter than the classic peak-only detector while sustained content converges back near the classic level. Matches Optimod "Smart Attack" character. `MultibandPhase2Tests` covers transient-burst vs classic, sustained convergence, and runtime-config flag propagation. Wired through both 3-band and 5-band compressor pairs via `configureCompressorPair`.

### Multiband Inter-Band Coupling (0.28, optional)

`multiband_inter_band_coupling_enabled` keeps the default chain unchanged when off. When enabled, low-band gain reduction is smoothed with a 20 ms attack / 300 ms release control envelope and converted into small negative threshold biases for upper bands. In 3-band mode the current mapping is `midBiasDB = -0.15 * lowGR` and `highBiasDB = -0.25 * lowGR`; in 5-band mode the biases are -0.10 / -0.15 / -0.22 / -0.25 times the low-band GR for bands 2-5. This is an Optimod-style tonal-glue control law: heavy bass control makes mids/highs slightly more controlled without applying one wideband gain ride. `MultibandInterBandCouplingTests` covers runtime plumbing, arithmetic ratios, zero-bias transparency, and increased upper-band control under bias. `--verify-multiband-coupling` performs the program-material A/B gate with multiband forced on and AGC off for isolation.

### Advanced Dynamics single-stage leveller (0.44; the default since 2026-10-15)

Gain law since 2026-10-15: `G_band = G_wideband + C_band`. `G_wideband` comes from one detector on the sum of the split bands (time-aligned with them) with a symmetric 50 ms power average -- an asymmetric average read steady tones 1.8 dB hot -- and is weighted with 0.3 of the chain's pre-emphasis time constant (detector only: `1 + 0.3 tau fs (1 - z^-1)`, +4.5 dB at 10 kHz, close to the classic AGC's K-weighting shelf), then a symmetric 100 ms smoother (5 ms rise for 250 ms after leaving the gate), and carries every adaptive ballistic (transient-accelerated attack in the time domain, hold window with hysteresis, distance acceleration, decay guard, density-slowed release via `liftCoefficient`, gate). `C_band` is a one-pole-smoothed correction toward `k * (share_longterm - share_now)`, bounded to +3 / -3 dB (-6 dB on bands 4-5), plus the user tilt and the bass-excess coupling; `share` is the band's level relative to the wideband level with an 8 s memory (0.5 s for its first 2 s). The cut time is per band (50 / 50 / 10 / 5 / 5 ms, at least two band periods), the restore 500 ms, and the correction honours the decay guard. Pinned by `AdvancedDynamicsToneTests`.

`advanced_dynamics_enabled` (default on) swaps the wideband AGC + multiband compressor pair for one fused 5-band levelling stage (`AdvancedDynamicsLeveler`, `DSP/AdvancedDynamics.swift`); when off the chain is bit-identical to before the stage existed (the AGC gate is `widebandAGCEnabled && !advancedDynamicsEnabled`). Rationale: two cascaded gain-riding stages can fight (AGC pulling programme down while multiband pushes bands up), a classic pumping source; one stage has no second controller to disagree with. The gain law is the one above. Band split is an own-instance `LinearPhaseMultibandSplitter5` at the multiband crossovers, configured lazily so the disabled stage allocates nothing; the band limiters hold one period of each band's lowest frequency. All parameters are live-apply (`RuntimeConfig`); the FIR split rebuilds only on an enable toggle or a crossover change. `AdvancedDynamicsTests`, `AdvancedDynamicsToneTests` and `LevellingAdvancedDynamicsTests` pin the law; `advancedDynamicsCostStaysBounded` bounds its cost against the two stages it replaces; `--verify-advanced-dynamics` is the programme A/B gate: per-scenario image, RMS drift and occupied bandwidth, loudness parity against the classic chain (bound 3.0 dB), beat-rate band modulation (pumping), decoded decay swell and re-processing idempotency (within 1 dB). Two of its bounds were calibrated on the classic chain and were exceeded on bass_dense (drift 7.1 dB against 6.0, parity 4.3 dB against 3.0) while every profile set the leveller 2 dB under its AGC target. Since the 2026-10 levelling change the target IS the AGC target (2 dB under it only on the two PrimeBass profiles, Music - Loud and Dense, where `--verify-primebass` needs the 2 dB: IMD -56 dB at the AGC target against the -70 dB gate), and the gate passes on Verification.ini: parity -2.3 dB, drift -5.4 dB, idempotency -0.26 dB. Final Drive per profile was re-derived with it against the `--verify-hf-transients` floors (0.5 dB in hand at least): Music - Clean 3.5 dB (was 4), Speech 2.8 (was 4.3), Classical 5 at clip depth 1 (was 3 at depth 2), Loud 8 and Dense 9 unchanged; `LevellingDriveCouplingTests` pins the rule, the parity and the per-profile budget reach.

Telemetry (0.45): `MPXGenerator.advancedDynamicsStatus` reports `enabled`, the five per-band gains (allocation-free tuple via `AdvancedDynamicsLeveler.bandGainsDBFixed` -- the render-thread-safe sibling of the heap-allocating `bandGainsDB`), and the density estimate. It flows through both engines' meter snapshots into `GET /api/meters` (`advancedDynamicsActive` / `advancedDynamicsBandGainsDB` / `advancedDynamicsDensityDB`, null while off) and the GUI dashboard, whose AGC chain pill switches identity to "Adv Dyn" while the leveller is active. In the same change `agcStatus` stopped lying while the leveller owns the dynamics: `enabled` now includes `!advancedDynamicsEnabled`, and detector/gain/gate read neutral whenever the AGC is not the active stage (previously stale AGC telemetry kept displaying while bypassed). Bit-identical for AD-off configs; pinned by the status tests in `AdvancedDynamicsTests`.

### Downward Expander

Per-band noise reduction within the multiband compressor stage. Threshold-based gain reduction on quiet bands prevents AGC from lifting the noise floor during quiet passages.

### Bass Clipper

Dedicated clipper for low-frequency content using an LR4 crossover to split, soft-clip the low band at 4x oversampling, and recombine. Pre-clipping bass peaks independently before the final stages dramatically reduces bass-induced intermodulation distortion. Used by Omnia, Breakaway, and Stereotool.

**The transfer curve (0.65).** `BassClipper` and `HFClipper` share one waveshaper, `BandWaveshaper` in `DSP/AudioClippers.swift`. Until 0.65 both passed the driven band untouched up to the threshold and then switched to `threshold * tanh(x / threshold)` -- which at the join drops to `tanh(1)` = 0.76 of the pass-through value. That is a discontinuous, non-monotonic transfer: it cut a notch into the crest of every peak that crossed the threshold, and oversampling cannot repair a discontinuity, only reduce how far its energy folds (0.65 audit, P0-2). The replacement is a shifted soft knee -- untouched below `0.9 * threshold`, then `x0 + w * tanh((|x| - x0) / w)` with `w` the remaining headroom -- continuous in value and slope at the join, monotonic, odd-symmetric, with the same asymptote, so "Threshold" still means the ceiling. The knee was chosen by measuring THROUGH the real oversampled stage at the shipped operating point rather than on the bare curve: at moderate drive (a kick a little over threshold, the regime a bass clipper lives in) THD went from -19.6 dB to -34.4 dB, and the new curve is never worse than the old one at any level; the widest knee won because it removes the notch with the least added curvature (a bare-curve sweep had suggested the opposite, an artefact of leaving the stage's own filters out). Through the stage the old curve's output also dipped 0.16 dB as input rose through threshold; the new one is monotonic. No strict gate reported drift from the change, but only because every movement stayed inside tolerance -- `transient_push` shifted 0.25 kHz of peak deviation against a 0.30 kHz tolerance -- so all four baselines were recaptured with it; and because no scenario drove the stage hard enough to exceed a tolerance, `BassClipperTests` carries chain-level monotonicity and splatter checks and the verifier gained the `bass_kick` scenario, which moves 1.1 dB of composite peak against a 0.10 dB tolerance.

### Distortion-Cancelled Clipper

L/R domain audio clipper implementing Orban's distortion-cancellation principle: clip the signal, extract the error (clipped minus original), lowpass-filter the error below a configurable cancellation frequency (`dc_clipper_cancel_freq_hz`, default 2 kHz), and subtract it from the clipped signal. This cancels low-frequency distortion products while leaving only high-frequency distortion that is psychoacoustically masked by the signal.

Since 2026-10 the stage is differential and linear-phase throughout. The pair is clipped at 8x (Lagrange-4 interpolation) on the `BandWaveshaper` soft knee with its asymptote at the ceiling; the clipping error is decimated by a linear-phase Kaiser FIR (flat to 0.4 x host rate, 80 dB down at the host Nyquist), and a linear-phase Kaiser lowpass at the host rate (-6 dB at the cancellation frequency) removes it below the corner. The wanted signal rides a delay-matched bypass: `out = x delayed + e delayed - LP(e)`. The distortion left is `e x (1 - LP)` with a zero-phase `1 - LP` between 0 and 1, so the stage can only remove distortion, never add it. Latency is about 2.6 ms at 48 kHz with the 2 kHz corner. Until 2026-10 the error path was an LR4 lowpass, whose -180 degrees at the corner made `1 - LP` peak at +4.3 dB at 1.56 kHz: the stage made distortion worse from 0.7 to 3.8 kHz; the 12th-order Butterworth decimator it also replaced was only -21 dB at the first folding frequency.

### BS.412 MPX Power Limiter

ITU-R BS.412-9 multiplex power, for European regulatory compliance (required in DE, AT, CH, SE, CZ, SI, and others). Rebuilt in 0.65 (`DSP/BS412Power.swift`) after an audit found it implemented none of the Recommendation's three defining conditions -- see "What 0.65 corrected" below.

**Measurement** (`BS412MultiplexPowerMeter`) is of the COMPLETE multiplex, pilot and RDS included, taken on the finished composite just before the final clamp, in the modulation domain (`output_gain_db` divided back out; amplitude 1.0 is 75 kHz). The window is a uniform sliding 60 seconds, decimated to 64-sample blocks, and it runs whenever the engine renders a composite -- whether or not the limiter is enabled -- so switching the limiter on acts on a full window instead of waiting a minute. The reference is dBr: 0 dBr is the power of a sine causing +/- 19 kHz deviation, i.e. a normalised mean square of `(19/75)^2 / 2`.

**Control** is two stages, because a single feedback loop cannot satisfy "any interval of 60 s". `BS412Rider` is the transparent one that owns the audible behaviour: FEED-FORWARD from the audio as it arrives, BEFORE its own gain, together with the subcarriers that will be added to it. Feeding a loop from a measurement that already contains its own gain is what made the first rebuild converge slowly and overshoot -- from unity, a steady +6.02 dBr input still averaged about +2.35 dBr across its first completed minute and then rebounded across the ceiling while settling. Since 2026-10-20 the rider rides the REMAINING 60 s budget rather than every second. It predicts the coming minute from the pre-control power (the next second from the most recent second, the rest from the quieter of a 5 s mean and that second, so a level drop is followed within a second while a rise still has to earn its way into the long mean), keeps a ledger of what it is emitting -- its own gain applied to the pre-control audio, plus the subcarriers -- in the same `BS412WindowLedger` arithmetic the guard proves with, and at every 64-sample block solves, for every whole-second horizon to the end of the window, the largest gain at which the window at that horizon still fits the limit if the programme carries on as predicted; the tightest horizon wins, smoothed by a 0.1 s attack and a 1 s release. On steady programme that is the mean-power rule the 0.65 rider applied to every second; on programme whose 1 s power varies around its mean it keeps the second-to-second dynamics and spends the quiet seconds' budget on the loud ones; after a sustained step up it repays the few seconds of prediction lag as a shallow sag spread over the rest of the window instead of a deep cut at its end. Unwritten ledger slots are charged at the ceiling, so the first minute is paced at the mean-power rule with no invented deficit to spend. Each block is booked at no more than the guard's own remaining allowance (`guardLimit - pastEnergy`, the guard's 0.01 dB margin against the rider's 0.05 dB): the guard never emits more than that, and booking it would have the rider repay, as a debt, energy the guard had already removed -- a second dip measured at -1 dB over 5 s after a +6 dB step. The cap keeps the rider's ledger at or above the guard's and at or below the guard's limit, so the debt it can ever show is bounded by the band between the two margins and is repaid over 3 s as a shallow dip. A ledger over the budget after the ceiling was lowered live is forgiven as the guard forgives it (`historyForgivenCount`), not repaid with silence. Measured on +2 dBr +/-3 dB-per-second programme (`BS412BudgetRiderTests`): the 1 s / 50 s rider completed its windows at -1.74 dBr and, after a quiet minute, handed the end of the first hot minute to the guard (-6 dBr for a second); this one completes them at -0.10 dBr (worst -0.02) with the guard idle, settles a +6 dBr passage after a quiet minute 0.6 dB under the ceiling, and recovers within 3 s after a 5 s burst that the 5 s mean alone held down for 7 s. The greedy law of "remaining budget over the next second" was measured and rejected: after a quiet minute it passed +6 dBr untouched for 11 s and then held -6 dBr for the remaining 48 s. Do not shorten the horizon set to make the rider louder.

`BS412ComplianceGuard` is what actually proves the limit, and it is not another smoother. It is an energy-accounting invariant: after every 64-sample block, the total energy in the rolling window is at or below `ceiling * windowSampleCount`. It runs after all audio-only peak control and the budget governor and BEFORE pilot and RDS are summed -- the last point at which the reducible and fixed parts are still separable. Per sample it divides the block's remaining budget evenly, and when the unmodified sample would overspend it solves the largest `h` in [0, 1] with `abs(h * audio + subcarriers) <= limit` as an interval, never by iteration. It accounts the exact emitted sample, cross term included, so estimating the subcarrier share by subtraction cannot hide an overage.

Slots not yet emitted are pre-charged with a subcarrier-only reserve rather than treated as silent: pilot and RDS are not reducible, so an early hot passage that spent a whole minute's budget would leave later pilot-only samples impossible at any audio gain. The reserve bounds their mean square at `(pilotPeak + rdsPeak)^2 / 2`, the worst case of perfect coherence. Do not drop the halving -- the peak square is 3 dB pessimistic, and a reserve above the ceiling makes the guard call a perfectly feasible configuration unachievable.

History the guard did not control is forgiven, not repaid. When enforcement starts, or the ceiling is lowered while it runs, and the window already holds more than the new budget, the guard restarts from the cold-start state above (`forgiveUncontrolledHistory`). Repaying that debt is only possible by muting the audio until the over-budget minute ages out: behind Advanced Dynamics, switching BS.412 on after a hot minute dropped the composite from -12 dB RMS to the pilot alone for the whole minute. A window straddling the switch is over the ceiling whatever the guard does, so muting buys nothing; every window wholly after the switch is still proved. History that fits the budget is kept.

Both stages ride the AUDIO path only -- pilot and RDS are injected after every peak stage at constant amplitude by design, so they are not the actuator's to touch. An impossible budget (subcarriers alone over the ceiling, judged per block over a sustained run, not on one sample near a sinusoid's peak) is REPORTED through `BS412Status.unachievable`, never met by attenuating them.

Both stages step once per 64-sample block, not per sample: the measurement only changes at that rate, and at these time constants a per-sample step underflows Float32 and stalls the gain short of its target (measured: 0.84 dB past the ceiling, stable and wrong).

**Test Tone.** The reporting meter keeps running; a transmitted calibration tone is part of the complete multiplex and omitting it would leave a hole in the power history. The rider and guard are suspended so the tone's calibrated amplitude is exact, and `controlSuspended` is published so neither front end shows a compliance reading while that is true.

**Telemetry.** `BS412Status` reaches `/api/meters` and the GUI as `bs412PowerDBr`, `bs412PowerValid`, `bs412SecondsObserved`, `bs412GainReductionDB`, `bs412OverCeiling`, `bs412Unachievable`, `bs412GuardActive` and `bs412ControlSuspended`. Both front ends show priming progress (`42 / 60 s`) rather than a number until a full window exists, and never a compliant-looking value while control is suspended.

**What 0.65 corrected.** The pre-0.65 stage observed the audio composite BEFORE pilot / RDS injection, so it was blind to roughly a tenth of the power it was limiting; treated its threshold as dB relative to normalised full-scale power rather than dBr, on which the shipped default of -10 was about +4.9 dBr -- five dB ABOVE the limit it claimed to enforce; allowed 30-90 second windows while the UI still said BS.412; only advanced its history while enabled; and reallocated its window on any parameter change, so editing the threshold erased the compliance history. Its own tests used the same internally-consistent dBFS arithmetic on both sides and therefore passed. `BS412PowerLimiterTests` now measures against the standard's reference, and the opt-in `BS412FullChainTests` (`MPXPRIME_DEEP=1`) renders past the 60 s window and requires the encoder's figure and `MeterAnalysis`' independent one to agree within 0.2 dB.

### HF Limiter (0.45, default-on)

`HFLimiter` implements program-controlled pre-emphasis after Orban US 4,103,243 (the Optimod-FM 8100 HF limiter, expired 1997): the pre-emphasised L/R signal is treated as `flat + boost` and only the boost component rides a gain, `out = flat + g * (pre - flat)`, `g` in `[gMin, 1]`. g = 1 is full pre-emphasis, g = 0 the flat response, so the stage can never cut HF below the program's own level; the receiver's fixed de-emphasis turns the action into a brief, bounded HF dip -- the trade every broadcast HF limiter makes. Detector: feed-forward, stereo-linked; when the pre-emphasised peak exceeds the threshold AND the boost itself covers the excess (a programme gate on two short peak-hold envelopes since 0.65; the 0.45 gate keyed on the boost carrying 20% of the peak -- Dolby US 4,498,055-style modulation control: bass/mid-driven peaks with little boost are left to the broadband limiter), the target gain removes exactly the excess from the boost, floored at `-hf_limiter_max_reduction_db`. Attack 1.5 ms, 5 ms hold, release 20 ms (Orban's analogue original: 3 ms / 10 ms); whatever leaks during the attack is caught by the pre-encode look-ahead limiter that follows (Orban's clipper-after-HF-limiter division of labour). Since 2026-10 the programme gate runs per channel: each channel opens only when its own boost covers its own excess, and the stereo link takes the more demanding of the gated targets, so a bass peak just over the threshold in one channel no longer cuts the other channel's hi-hat by 5-7 dB. Runs inside the dual-rate audio domain; all parameters live-apply. It replaced the HF *clipper* in the Music - Loud profile because the clipper -- a waveshaper on the very band cymbals live in -- cost 17 dB of decoded HF SINAD on hi-hats (`--verify-hf-transients`, 2026-08-29). `HFLimiterTests` pins passthrough when off, pull-to-threshold, the bass-peak guard, release, the reduction cap, stereo-link ratio, and INI/RuntimeConfig round-trips. Prior-art table: project-roadmap.md "HF transient / pre-emphasis limiting prior art".

### Composite Clipper (differential topology with delta-based per-band substitution)

Oversampled tanh soft-clipper on the audio composite, sitting after the pre-encode audio limiter and before BS.412 / final-MPX safety limiter. The oversampling factor is operator-selectable across {8, 16, 32} via `mpx_clipper_oversampling` (default 16; live-apply, Composite Clipper > Advanced in the app) -- 8x for CPU-constrained hardware, 16x for industry-standard parity (Optimod 8X00 / Omnia.11 / Stereotool default), 32x for Omnia.9-class spec-sheet defence at roughly double this stage's CPU cost. Numbers in the rest of this section assume the 16x default unless stated otherwise; tap counts, batch sizes, and internal rates scale linearly with the active factor. Since 0.11 this is the **only** non-linearity on the audio composite -- the prior `CompositeTruePeakLimiter` (memoryless tanh on `|composite|` peak detection) was deleted because its IM bled into the 38 kHz stereo sidebands and demodulated as `(L-R)` cancellation. As of 0.20 the clipper runs the **differential topology** of Orban US 6,337,999 (expired 2022, public domain): only the *clipping residual* (input - clipped) goes through decimation, while the wanted signal rides a 1x delay-matched bypass and the residual is subtracted at the output. The decimator's stopband leakage and any phase non-flatness now only colour the residual subtracted at output, not the wanted (L-R) sideband content. Upsampling is a 2x linear-phase Kaiser FIR followed by the causal Lagrange-4 to the full factor: Lagrange alone from the host rate imaged 53 kHz content at -21 dB, so clip decisions were taken on a waveform up to 9 % wrong; on the 2x stream the image is -44 dB. Decimation uses `LinearPhaseFIRDecimator` (Kaiser-windowed sinc, 293 taps at 16x (147 at 8x, 585 at 32x), `vDSP_dotpr` polyphase, 90 dB stopband from 113 kHz, flat passband 0-53 kHz) -- replaces the prior `BiquadCascade6` 12th-order Butterworth which had ~70-80 dB stopband and 1-2 dB rolloff at the upper subcarrier edge. The decimator's half-length is padded with an OS-rate delay so interpolator + decimator delay is a whole number of host samples and the bypass matches it exactly (it used to round 9.125 host samples to 9, leaving -16 dB of uncancelled residual at 38 kHz). Cost: 25 host samples (~130 us at 192 kHz) of TX-path latency, plus about 140 host samples for the guard FIR whenever any guard band is on (up from ~9 before 2026-10). The clipper does double duty: peak control plus loudness, the same role Orban's "Half-Cosine" / "Smart Clipper" stages play in the 8500/8600 line.

The bare clipper produces cubic IM that scatters across the FM baseband: M^n self-products in the audio band, M^2*S / M*S^2 cross-products in the 23-53 kHz stereo sidebands, and broadband harmonic energy that lands inside the pilot guard band (17-21 kHz) and RDS guard band (55-59 kHz). The stereo-sideband products demodulate as audio in the S channel ("breathing") and the guard-band products vector-sum with the cleanly-injected pilot/RDS, degrading stereo decoding and RDS BCH integrity.

**Guard bands: one coherent linear-phase FIR on the residual (2026-10).** The decimated host-rate clipping residual `r` passes through one linear-phase Kaiser FIR, the weighted sum of the enabled band-pass kernels, and only what the guard does NOT pass is subtracted from the delayed wanted signal:

```text
r_kept = r delayed - sum(w_band * band(r))
output = x delayed - r_kept
```

`w_band` is 1 for an enabled audio, pilot or RDS guard and the 0...1 share `mpx_clipper_stereo_guard` for the stereo band. The band edges sit in the gaps between the services, with a 2 kHz transition and 50 dB of depth, so 17-21, 23-53 and 55-59 kHz are protected in full:

| Band | Kernel band | Default | Why |
|---|---|---|---|
| audio | 0-16 kHz | off | Removing audio-band distortion costs loudness; off by default for full clipper drive. Inspired by Orban US 5,168,526. |
| pilot | 16-22 kHz | on | Eliminates clipper IM under the cleanly-injected 19 kHz pilot. Required for reliable stereo decoding. |
| stereo | 22-54 kHz x share | on (share 1.0) | Cancels M^2*S cross-products that demodulate as `(L-R)` "breathing". |
| RDS | 54-60 kHz | on | Removes clipper energy under the RDS subcarrier. Without this, BCH error rate climbs as the clipper drives. |

Until 2026-10 each guard subtracted an IIR band (LR4 or RBJ band-pass) from the residual. `r - BP(r)` is "r without the band" only if the band-pass has zero phase across it, which an IIR does not: the stereo guard left the residual at -2.4 dB at 30 kHz and AMPLIFIED it by about +2 dB at 23 and 53 kHz, and stereo content above ~8 kHz was not protected at all. With the coherent FIR, products next to the bands are no longer amplified and 10 kHz separation reads 98 dB. The guard FIR's group delay is added to the bypass and to `totalDelayHostSamples`, so the subcarrier delay line follows it.

Soft-clip via `vvtanhf` (vForce SIMD) batched in 16-element groups (one batch per host sample at 16x OS): per OS-step the upsampled inputs are pre-computed into a batch buffer, the tanh is run as a vector op, then the per-OS-step state-dependent work (linear-phase FIR decimation push) runs sequentially; the guard FIR runs once per host sample on the decimated residual. At batch=16 `vvtanhf` is ~9x faster than scalar `tanhf` per call -- see `TanhBatchSizeBench` for the curve; this partially offsets the doubled per-host work the 16x OS rate would otherwise impose on the soft-clip stage. The FIR convolution itself runs through `vDSP_dotpr` for the polyphase commutator path.

Topologically inspired by three expired Orban patents: US 4,460,871 (1984) introduced the delta-cancellation primitive on a single audio band; US 5,737,434 (1998) layered it across multiple guard bands for FM composite; US 6,337,999 (1998 / expired 2022) added the differential-clipper topology where only the residual is decimated. The coherent FIR guard, the 2x Kaiser + Lagrange interpolator, the linear-phase FIR decimator, and the `vvtanhf`-batched 16x oversampled core are project-specific.

Live-apply via `RuntimeConfig`. INI keys `mpx_clipper_enabled`, `mpx_clipper_threshold_db`, `mpx_clipper_ceiling_db`, `mpx_clipper_cancel_audio`, `mpx_clipper_cancel_pilot`, `mpx_clipper_stereo_guard` (0.45: a 0...1 share of the 22-53 kHz residual restored; replaced the `mpx_clipper_cancel_stereo` toggle, which loads as 1.0 / 0.0. At 1 the clipper only ever removes the MONO share of an M+S peak -- chain-review finding B1 -- so the composite overshoots the ceiling by up to ~1.7 dB on a 12 dB overdrive and the Final-MPX limiter rides it; at 0 it clips the full composite like Orban's half-cosine limiter (US 6,434,241, which does not protect 23-53 kHz) and Thimeo / Omnia. `--verify-stereo-guard` sweeps the share on the Music - Loud profile and the loaded config and is where the default comes from. 0.5 since the 2026-10 overhaul: the sweep's programme-crosstalk table (`panned_program`, program_mix into the left channel only, decoded, left minus right per octave band -- the `SeparationGates.swift` measurement `--verify-receiver` gates) reads 25 dB on Music - Loud at 1.0, 27 dB at 0.0 and 60-72 dB at 0.5. The clipping residual is a train of short pulses at the 38 kHz crests whose demodulated L-R share is about twice its baseband share, so the two shares cancel in the silent channel when HALF of the L-R residual is removed; 1.0 leaves the whole clipped mono share there, 0 the whole L-R share. Costs about 3 dB of ride-cymbal SINAD at equal clip depth against 1.0), `mpx_clipper_cancel_rds`, (0.26) `mpx_clipper_lookahead_ms` and (2026-10) `mpx_clipper_lookahead_depth_db` (the clip depth, below). The legacy `composite_clipper_enabled` key (which used to control the now-deleted composite *limiter*) was removed in 0.11 -- see the Verification.ini key-collision warning in AGENTS.md.

**Look-ahead peak control (0.26; reworked 2026-10).** When `mpx_clipper_lookahead_ms > 0` (default 2.0 ms), an OS-rate (3.072 MHz at 192 kHz x 16) sliding-window-max detector runs on its own copy of the 2x Kaiser + Lagrange interpolator, fed the UN-delayed input, so intersample peaks count. The window spans one host sample more than the delay, so the OS interval the audio path is about to clip is always inside it. The window-minimum required gain drives a `LookaheadGainRamp` (instant-attack hold, ~80 ms release, two cascaded moving averages spanning the window): the gain starts moving a full window ahead and arrives at the required value exactly when the peak reaches the clip kernel, with no step. The gain is applied to the delayed input before the interpolator, so the differential-topology cancellation linearity holds. A separate `lookaheadGainReductionDB` telemetry value (`Look-Ahead Gain Reduction` in the app) distinguishes clean predictive ducking from soft-clip distortion-producing GR on the meter. Until 2026-10 an exponential attack (time constant window / 4) followed by a 200 Hz one-pole reached only 81 % of the needed reduction on arrival; the box cascade reaches full depth exactly on arrival. It is also the better spectral guard: two 1 ms boxes are -46 dB at a 4 kHz offset where the one-pole was -26 dB, so the gain cannot move 15 kHz programme into the pilot band. Algorithmic primitives -- Lemire monotonic deque (sliding-window max) and moving-average gain smoothing -- are public-domain.

**Clip depth (2026-10 audio-chain overhaul, gain-structure audit C1).** The F10 rework above made the look-ahead arrive at full depth, and its target was the ceiling itself, so from then on 100 % of every overshoot was removed by the gain ride and the tanh kernel only bent peaks already sitting on the ceiling: a constant 0.16 dB of kernel GR on every scenario of every baseline (Music - Loud clipper GR 2.07 -> 0.14 dB) and -4 dB RMS on bright programme. "Enable Composite Clipper" had become a 2 ms look-ahead LIMITER with an 80 ms release, and Final Drive was undone on dense programme. The ride now targets `ceiling x 10^(depth / 20)` with `mpx_clipper_lookahead_depth_db` (0...6 dB, live, per Format Profile): the ride removes only what exceeds the depth above the ceiling and the oversampled, guard-band-protected kernel clips the rest; the ride's release is 25 ms (was 80). 0 dB is the pre-overhaul behaviour. The per-profile depths (1.0 dB on every profile; Classical had 2.0 until the levelling task raised its drive to 5 dB, where depth 2 took its ride SINAD to 27.3 dB and depth 1 keeps 33.8 dB) are the largest values that keep every `--verify-hf-transients` SINAD floor (ride >= 30 dB, hat >= 20 dB / 15 dB loud) with at least 2 dB in hand at the shipped stereo guard of 0.5 (ride SINAD 33.9-34.3 dB at 1.0 dB, 29.4-29.7 dB at 1.5 dB on the music profiles); they are not taste. What the depth buys is measured, not assumed: the kernel now does the clipping its readout shows (GR = depth on dense programme) and the look-ahead idles below the depth, but the loudness gain is small -- 0.0 dB RMS on bright_dense through Music - Clean, 0.2 dB through Loud / Dense -- because most of what the kernel removes returns as the restored guard-band share of the residual plus the decimator / 55 kHz FIR overshoot (final-limiter duty 0.78 dB at depth 1, 1.44 dB at depth 2 against 0 at depth 0) and the true-peak final limiter rides it. Its release (95 / 50 / 30 ms measured) does not change that. Deeper clipping buys loudness only with a second clip after the filters, which this chain does not have (the 1x shaper is guard-less and kept idle on purpose). `CompositeClipDepthTests` pins the mechanism, the live scalar apply, the guard floors with the kernel working and the measured dense-programme figures.

**Final-stage order and budget reference (0.45).** Until 0.45 the final stage ran shaper -> clipper -> bandwidth FIR -> BS.412 -> final limiter, with the clipper's -1 dB threshold and the final limiter's 0.98 threshold both read against digital full scale. The audio composite's budget (0.98 minus the pilot/RDS reservation minus a 0.02 margin, ~0.85 with 8% pilot and 2 kHz RDS) sits BELOW those thresholds, so the 1x, un-oversampled, guard-less `softClipSafety` shaper did every bit of the clipping and neither the oversampled clipper nor the limiter ever engaged (`--verify-hf-transients`: clipper on/off bit-identical on Music - Loud; the shaper cost ~13 dB of decoded HF SINAD). The stage now runs composite clipper -> bandwidth FIR -> BS.412 -> final look-ahead limiter -> shaper, and the two peak stages are normalised onto the budget per sample: the clipper's configured ceiling lands exactly on the budget (`x / (budget / ceilingLinear)` in, `* (budget / ceilingLinear)` out, so the operator's threshold/ceiling pair keeps its knee width and the composite uses the whole budget -- deviation stays where operators calibrated it), and the limiter's threshold lands on the budget (0.985 x budget until the A1b fix below). The budget is a slowly varying envelope (subcarrier reservation, 0.5 ms attack / 12 ms release) against the clipper's ~0.1 ms internal delay, so scaling in and out by the same current value keeps the differential-topology cancellation exact in practice. Why a limiter must follow the clipper: the guard-band substitution restores the protected bands (pilot, 22-53 kHz stereo, RDS) to the CLEAN input, so the clipper output legitimately exceeds its own ceiling in-band (`CompositeClipperBoundProbeTests`: 1.18 vs a 0.966 ceiling on a 12 dB overdrive, and the 55 kHz FIR removes none of it). That excess is the price of clean guards and is taken by a gain ride, never by a waveshaper -- the verifier expects ~1 dB of final-limiter duty on `bright_dense` (Music - Loud) and only flags it above 3 dB (TIGHT) / 4 dB (WARN). **A1b (0.45):** the ride is a true look-ahead limiter now: `LookaheadLimiter` feeds a `SlidingWindowMax` over the sample leaving its 5 ms delay line plus everything still inside it, so nothing above the threshold ever exits (release ~95 ms, short hold). Since 2026-10 that target drives a `LookaheadGainRamp`: the gain ramps smoothly over the whole look-ahead and reaches the required value exactly when the peak exits. The 0.45 design attacked with a time constant of window / 4 and floored the gain state at the target, so a larger peak entering the window stepped the gain by up to 1.5 dB in one sample and spread spill above 60 kHz, which nothing behind the final limiter filters; an output floor now absorbs Float rounding only and never feeds back into the gain. With the limiter's look-ahead disabled it adds no delay, and the subcarrier delay no longer counts it. **True-peak detector (2026-10):** the sliding window is fed the largest of the sample and its four 4x-interpolated estimates (a 60 dB Kaiser FIR, 9-10 taps per phase at 192 kHz, the `StereoTruePeakGuard` pattern), so the inter-sample peaks of the 55 kHz-limited composite -- which the exciter sees and the 1x detector could not -- are held to the budget as well; the ramp is shortened by the interpolator's delay plus two samples so it stays a bound, the audio path is untouched and the stage's delay is unchanged. On air the programme's negative peaks had sat 0.35 dB above a full-scale tone's at the same sample budget (2026-10-20 off-air log). `TruePeakFinalLimiterTests` pins "nothing above the threshold leaves" on the 4x true peak, the step-free ramp and the sample-detector negative control. The pre-A1b detector was the instantaneous |x| into a 0.35 ms one-pole; on program whose peaks move faster than that it tracked a blurred target and leaked 0.9 dB (Music - Loud) to 2.7 dB (hot chain) past its threshold into the 1x shaper while reporting 0.02 / 5.8 dB of GR -- found by `--verify-final-ride`, whose safety-clip column now reads 0.00 in every row with the limiter on. `LookaheadLimiterTests` pin the contract (+0.000 dB worst case at 12 dB overdrive, burst leading edge caught, pure delay below threshold). This matches Orban's documented architecture (composite clipper -> pilot/SCA protection filtering -> 512 kHz "half-cosine" composite limiter acting as overshoot compensator -> pilot re-added), with the caveat that our residual safety soft-clips run at 1x, which is harmless only while they stay idle -- hence the ordering test.

**Multiband composite clipping -- removed in 0.45.** The 0.28 experimental `CompositeMultibandClipper` (`mpx_multiband_clipper_enabled`) never reached a preset, and its own A/B gate went TIGHT (>60 kHz leakage +8.7 dB on `vocal_sibilant`) once the final stage was corrected; deleted with its INI key, dashboard toggle, tests and verify mode.

`CompositeClipperCrossDomainTests` and `CompositeClipperStereoSeparationTests` are the regression guards. The first asserts cross-domain IM drop with each guard band engaged; the second asserts that decoded L/R separation is preserved within tolerance when the stereo guard is on. `CompositeClipperLookaheadTests` covers the (0.26) look-ahead path at depth 0 (the `configure` default): overshoot bound (`max(|out|) <= ceiling x 1.05` at 2 ms -- a bound that assumes the ride alone places the peak on the ceiling, which is why it stays at depth 0), steady-state transparency on pink noise, pilot/stereo/RDS guard regression with look-ahead engaged, cross-domain cancellation regression (catches asymmetric per-band gain leak), and total-delay reporting; `CompositeClipDepthTests` covers the depth > 0 case, where the kernel places the peak and only the restored guard-band share can leave above the ceiling. Together they catch regressions in cancellation depth, over-cancellation that would collapse the stereo image, look-ahead detector / gain-application asymmetry and latency-reporting drift.

### Audio Composite Bandwidth FIR (0.26)

Linear-phase FIR cleanup stage placed after the composite clipper and before BS.412 / final-MPX safety limiting. Its passband runs to 55 kHz (0 dB at 54.6 kHz, -2.8 dB at 57, -44 dB at 59.4, below -85 dB from 60.5 kHz, pinned by `EncoderRDSShapingTests`); it does NOT protect the RDS band -- the composite clipper's RDS guard does. Strips shaper/clipper spill that would otherwise live above the upper stereo sideband and beat with the cleanly-injected pilot/RDS. Group delay (~112 host samples at 192 kHz) folds into `recomputeSubcarrierDelay()` so the post-clipper subcarrier delay line tracks the new audio path delay automatically.

### Safety-clip duty telemetry (0.45)

`FinalLimiterStatus.safetyClipDB` is a 250 ms decaying peak of `20 log10(|composite| / budget)` measured at the shaper's input -- how far the audio composite exceeded the budget and had to be caught by the 1x safety soft clip. The shaper passes everything below 0.99 x budget untouched and bends into a tanh knee whose asymptote is the budget, so its output never exceeds the budget (the earlier curve could). Both engines forward it (`mpxSafetyClipDB` in the CoreAudio meter snapshot, `safetyClipDB` in the ALSA state) to the GUI Monitoring page's Headroom card ("Safety Clip") and the control DTO (`safetyClipDB` in `/api/telemetry`, "Safety Clip" on the dashboard). Contract: 0.0 with the composite clipper and final limiter enabled; anything above zero means the shaper is doing peak control.

### Composite Budget Governor (0.26)

Smoothed gain ride on the audio composite that runs *before* pilot/RDS injection. `MPXGenerator.makeFinalCompositeThresholds(outputGain:threshold:deviationScale:reserved:)` derives

```text
deviationShare     = min(1, mpx_deviation_khz / 75)
effectiveThreshold = threshold * deviationShare / max(1.0, outputGain)
margin             = 0.005 * deviationShare / max(1.0, outputGain)
allowedAudioAbs    = max(0, effectiveThreshold - reservedSubcarrier - margin)
overBudget         = allowedAudioAbs <= 0
```

with `threshold` = `limit_threshold`, default 1.0 (clamped 0.5...1.0). At the defaults (pilot 8 %, RDS 2 kHz) the audio budget is `1.0 - 0.1067 - 0.005 = 0.8883` (66.6 kHz) and the worst-case multiplex, audio and subcarrier crests coinciding, 0.995 (74.6 kHz); the 0.005 covers Float rounding and the inter-sample peak of the 55 kHz-limited composite, which the 4x true-peak rule in the verifier checks. Until 2026-10 `limit_threshold` defaulted to 0.98 and the margin was 0.02: two static reserves for the same purpose (the threshold was the final limiter's absolute threshold before 0.45 and survived only as a bite out of the budget once the limiter was normalised onto it), 3 kHz of headroom that capped the multiplex at 72 kHz and measured 69-70.6 kHz on dense programme (the subcarrier crests rarely coincide with the audio crest). The clipper's tanh kernel still leaves ceiling-pinned peaks 0.16-0.27 dB under the budget; closing that is the clip-depth work, not the budget.

Composite Deviation is therefore the peak target of the whole multiplex: composite amplitude 1.0 is 75 kHz at every setting, and a 50 kHz station's multiplex peaks at 50/75 of it (the verifier's worst peak is 47 kHz). Until 2026-10 only the drive and the pilot / RDS amplitudes followed the setting while the budget stayed at its 75 kHz value, so the clipper and the final limiter normalised the audio back up to ~0.88 x 75 kHz: 70.8 kHz peaks at a 50 kHz setting. Above 75 kHz the budget stays at full scale, the hard bound of the digital domain. The `compositeBudgetMarginDB` readout is still measured against 75 kHz, so at 50 kHz it reads about 4 dB with the clipper at work.

`reservedSubcarrier` (`updateSubcarrierReservation`) is the nominal on-air peak of each service, `pilot_level` plus the RDS injection, scaled by the deviation share, so pilot and RDS fit at every allowed setting (pilot 12 % with RDS 7.5 kHz used to overshoot to 75 kHz and clip both). The audio sits about 0.3 dB lower than before at the defaults, more at high pilot or RDS levels. The value is constant while the subcarrier configuration is, so the budget the clipper and limiter normalise onto does not wobble at the RDS symbol rate; a service that goes off-air releases its reserve over seconds instead of stepping it down.

`processFinalComposite` applies a smoothed gain ride driven by `audioCeilOut = postLimiterCeiling x outputGain`. The audible work is done by the smoothed ride (separate attack/release time constants); a hard ceiling remains at the same value as a last-sample guard for attack-time transients. Pilot and RDS are *not* scaled or clipped -- only the audio composite is reduced. The final `clampf(mpx, -1, 1)` survives only as a numeric guard against illegal samples reaching CoreAudio; for valid configs it should never engage. `CompositeCalibrationStatus.overBudget` re-derives from current `outputGain` and the smoothed `subcarrierReservationEnv`, exposing impossible configs (e.g. very hot output gain where pilot reservation alone exceeds the threshold) to UI and verifier. `postInjectionOvershoot` (50 ms decayed envelope) reports the size of any residual clamp engagement so transient governor lag is visible too. The verifier reports both `worstPostInjectionOvershoot` and `compositeBudgetExceeded` per scenario.

### Subcarrier Delay Alignment (0.26)

A new host-rate `subcarrierDelayLine` ring buffer delays pilot+RDS by the composite clipper's total delay plus the safety-limiter lookahead samples. `recomputeSubcarrierDelay()` sizes the line dynamically from the active stage delays (composite clipper interpolator + decimator delay + guard FIR group delay + composite-clipper look-ahead samples + audio-composite bandwidth FIR group delay + safety limiter look-ahead, counted only while that look-ahead is in the path). The receiver's pilot-derived 38 kHz reference is now phase-coherent with the audio composite's internal L-R subcarrier modulation, closing a stereo-decode degradation that grew with the differential-topology + audio-bandwidth-FIR + look-ahead stack. `StereoSeparationReceiverTests` is the regression guard.

### Encoder program lowpass (FIR / Butterworth split)

Final audio-bandwidth guard sitting immediately before stereo encoding. Two implementations co-exist and the engine picks per output mode:

- **Transmit / processed-audio (`mpxComposite` / `processedAudio`)**: Kaiser-windowed linear-phase FIR with ~80 dB stop-band attenuation. Tap count is derived from sample rate to maintain ~1.5 kHz transition at 15 kHz cutoff (~641 taps at 192 kHz, ~160 taps at 48 kHz). Group delay ~1.67 ms. The steep roll-off prevents downstream nonlinear stages (DC clipper, composite clipper) from re-broadening audio content into the 19 kHz pilot region, bringing DC-clipper aliasing from ~-38 dBFS (Butterworth) to below -75 dBFS. In processed-audio output this same FIR is the 15 kHz band-limit on the L/R feed.
- **Band-limit per path (2026-10-16).** The composite keeps the 6th-order programme Butterworth (`programLP`, 15.3 kHz at 50 us) in series with the 1.5 kHz-transition FIR: -0.47 dB at 14 kHz and -2.06 dB at 15 kHz on the 48 kHz audio domain. With the dual-rate boundary off (whole engine at an integer multiple of 48 kHz) that Butterworth runs as the 48 kHz design applied as H(z^k) (`StridedProgramLowpass`), so boundary on and off are identical below 24 kHz; designed at the full rate, a bilinear Butterworth drooped 1.24 dB at 14 kHz at 192 kHz. In FM / HD / AM Output (`processedAudio`, the whole engine at the device rate) the FIR is the ONLY band-limit and its transition is 1 kHz (flat to 14.9 kHz, -6 dB at 15.4, 82 dB down from 15.9 kHz; about 249 taps / 2.6 ms at 48 kHz, 991 taps at 192 kHz), so the output follows the analogue 50 / 75 us curve, NRSC-1 (to 9 kHz) or flat within 0.01 dB at any device rate (`OutputResponseTests`).
- **Monitor mode (`monitorAudio`)**: 12th-order Butterworth cascade (six biquads). ~0.2 ms latency, ~13 dB attenuation at 17 kHz. Intentionally shallower for low-latency live monitoring. The monitor is documented as "an idea of how it would sound" -- the transmitted composite uses the FIR.

`MPXGenerator` seeds the choice from `encoder_fir_enabled` / `multiband_fir_enabled` at construction (so the verifier, the Linux ALSA engine and processed-audio output all run the TX FIRs); on macOS `AudioOutputEngine.start()` re-asserts it via `setEncoderFIREnabled(_:)` and switches the FIRs OFF only for the low-latency monitor mode. Both filters remain configured so toggling output mode on engine restart is immediate. The AppConfig `encoder_fir_enabled` flag allows bypassing the FIR entirely (defaults to true).

`DSPThroughputTests.preEmphasisDoesNotExplodeFullChainCost` and `EncoderBandwidthTests` guard this stage: the former catches any regression in the combined limiter+encoder cost on HF-rich program, the latter characterises the FIR's stop-band depth directly and asserts a >=20 dB gap over the Butterworth baseline.

## RDS encoder (`BasicRDSCoder`)

### Origin and scope

The block-level bit encoder -- `crc` / `withCheckword` / `buildGroupBits` and the B1/B2/B3/B4 layout -- was initially ported from the Python `RDSHelper` in [ryanginn/rds-master](https://github.com/ryanginn/rds-master). The CRC polynomial (`0x5B9`), offset words A/B/C/D, the `(groupType << 12) | (versionB << 11) | (tp << 10) | (pty << 5) | b2Tail` B2 composition, and the segment-counter patterns in Group 0 (mod 4, DI bit) and Group 2 (mod 16, A/B flag) all follow the Python implementation's structure. The Cp offset value diverged during the port (Python uses `0x350`, this implementation uses `0x1E0`).

Everything else in this section -- the 1187.5 bit/s biphase impulse + Gaussian shaping FIR, the pilot-locked 57 kHz subcarrier generation (`nextSampleWithPilotLock`), the real-time audio-thread safety work (pre-allocated `bitBuffer`, atomic CT cache, `monotonicSeconds()` timing), the `RDSRuntimeConfig` live-apply pipeline, AF Method B encoding, RT+ ODA registration (AID `0x4BD7`, group 3A/11A), Group 4A clock-time with MJD + TZ, Group 10A PTYN, Group 15A Long PS, and Group 1A ECC/LIC variants -- is MPX Prime Studio's own work and has no counterpart in the source Python project.

### Group repertoire

| Group | Purpose | Builder |
|---|---|---|
| **0A** | PS + AF + flags | `buildGroup0(versionB: false)` |
| **0B** | PS + PI repeat (no AF) | `buildGroup0(versionB: true)` |
| **1A** | Slow Labelling -- ECC + LIC variants | `buildGroup1A` |
| **2A / 2B** | Radiotext (64-char / 32-char) | `buildGroup2(versionB:)` |
| **3A** | ODA registration (RT+ AID 0x4BD7) | `buildGroup3A` |
| **4A** | Clock Time -- MJD + hour + minute + TZ | `buildClockTimeGroupImmediate` |
| **10A** | PTYN (8-char Program Type Name) | `buildGroup10A` |
| **11A** | RT+ tags via ODA | `buildGroup11A` |
| **15A** | Long PS -- 32-char (basic-RDS character set) | `buildGroup15A` |

Not currently implemented: 14A/14B (EON), 8A (TMC), 9A (EWS), 6A (IH),
5A/7A/13A (paging), 12A (other ODA). Multi-PSN / Data Sets -- single PI only.

### Bit-level correctness

- 1187.5 bit/s (57000/48), differential coding, biphase impulse shaping,
  Gaussian shaping FIR (configurable BW + taps).
- CRC polynomial 0x5B9; offset words A=0x0FC, B=0x198, C=0x168,
  Cp=0x350, D=0x1B4 per EN 50067 Table A.1 / IEC 62106 Annex A (Cp was 0x1E0 until
  2026-10-15, which receivers rejected on every version-B group).
- 57 kHz subcarrier locked to 19 kHz pilot at 3:1 (`nextSampleWithPilotLock`):
  the carrier is `sin(3*theta)` recovered from the pilot oscillator's
  instantaneous `sin(theta)` (`pilotOsc.s`, supplied per sample via
  `updateRDSPilotSin`) through the triple-angle identity `3s - 4s^3`. 0.36
  replaced the prior separate additive phase accumulator, which drifted
  ~9 deg / 5 s against the emitted pilot; the `--verify-receiver` pilot/RDS
  phase-lock drift check guards against regressing it.
- AF Method A and Method B encoding both supported; Method B repeats
  the tuned frequency per pair so receivers can group AF lists across
  regional variants (EN 50067 sec. 3.2.1.6.4 / IEC 62106-2 sec. 7.5.3).

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

Per UECP sec. 2.5.1.1, TA flag transitions force an immediate Group 0A
ahead of the regular schedule so traffic-aware receivers see the
flip within one group time. `applyRDSRuntimeConfig` detects the edge
by diffing the previous flag value before assignment; `nextGroupBits`
honours the resulting force flag (after CT, which keeps priority
because it's minute-aligned).

### Real-time safety

- Pre-allocated 104-byte bit buffer (`bitBuffer`) reused across
  `buildGroupBits` calls; subscript-assigned in place. Test callers
  trigger Swift CoW for retained references -- paid by the test, not
  the audio thread.
- Cached `cachedAutoSchedule` / `cachedStandardSchedule` -- rebuilt
  only when `rtMode2B` / `rtPlusEnabled` / `rdsGroupSequence` change.
- Atomic CT cache (`cachedCTMinuteToken` + `cachedCTPacked`) updated
  from the background `clockUpdateQueue` once per second.
- Audio-thread elapsed-time maths uses `BasicRDSCoder.monotonicSeconds()`
  (`ProcessInfo.systemUptime`, commpage-backed `mach_continuous_time`,
  no syscall) instead of `Date()`. `Date()` is retained only on the
  background CT-refresh path and the RT `{time}/{date}` macro
  expansion.

### Standards references

- EN 50067:1998 -- original RDS standard. PI / PS / RT / AF / EON / CT
  / TDC / IH / EWS / RP / TMC / ODA feature taxonomy.
- IEC 62106-2:2018 -- current RDS bit-level spec (extends Long PS
  with UTF-8 character set; UTF-8 toggle not currently implemented).
- IEC 62106-6:2023 -- RT+ / ODA / eRT extensions.
- UECP SPB 490 v7.05 -- encoder control protocol (not currently
  implemented; TA-edge behaviour follows the sec. 2.5.1.1 pattern).

PDFs in `standards/` for reference.

## General DSP notes

- PrimeBass adds perceived bass weight by synthesising controlled harmonics of low-frequency content, so the listener hears more bass while the chain pushes less LF peak amplitude. Saves headroom for the downstream bass clipper, pre-encode limiter, and composite clipper.
- The multiband stage's TX path uses linear-phase FIR splitters (parallel-cumulative-LP topology, sum-to-flat); the complementary Linkwitz-Riley 4th-order IIR crossovers remain as the low-latency monitor-path fallback. Both give clean band separation without recombination smear when adjacent bands compress differently.
- The final MPX chain remains verification-backed. Structural cleanup there is intentionally done in small steps because even behaviour-preserving refactors can change composite output measurably.
- Verification covers both composite safety and decoded-audio quality signals. In addition to the base offline verifier, a focused preset sweep exists for the main 5-band preset family (`5B AC/Pop`, `5B CHR/EDM`, `5B Rock`, `5B Talk`, `5B News`, `5B Urban`, `5B Dance`).
- The optional stages (phase rotator, parametric EQ, multiband limiter, downward expander, distortion-cancelled clipper, BS.412, SSB stereo) are disabled by default; Advanced Dynamics is the default levelling since 2026-10-15 and have zero impact on the signal chain until enabled; the bass clipper and the HF limiter ship enabled. All support live-apply via RuntimeConfig.
