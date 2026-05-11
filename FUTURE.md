# MPX Prime Future Roadmap

## Plan.md Alignment Check (2026-05-11)

`plan.md` is the controlling product direction: MPX Prime is targeting the
best amateur-grade free FM processor first, not a direct enterprise rack
replacement. Enterprise DSP ideas remain valid stretch goals, but they
should not displace preset tuning, smoke testing, calibration, and the
macOS operator experience.

Important status changes against this file:

| Area | Current code status | Planning implication |
| --- | --- | --- |
| Cross-platform DSP language | `plan.md` now argues to keep the DSP core in Swift. The current DSP is mostly pure Swift math; the platform-specific work is audio I/O, locks, device enumeration, conditional imports, CI, and packaging. | Treat the C++ rewrite/JUCE section below as an older option, not the preferred plan. A rewrite would throw away a large amount of verification-backed DSP for no immediate audio win. |
| Composite clipper look-ahead | Landed in `CompositeClipper`: configurable `mpx_clipper_lookahead_ms`, 0-5 ms, default off. It uses an oversampled sliding-window detector, delay line, smoothed gain, and reports look-ahead gain reduction. | Remove "no look-ahead exists" from future assumptions. Remaining work is default tuning, listening evaluation, and deciding whether to enable a small default value in presets. |
| Pilot/RDS delay alignment | Landed: `subcarrierDelayLine` delays pilot/RDS by the composite clipper plus final limiter delay so the receiver's pilot-derived 38 kHz reference aligns with the audio composite. | No longer a roadmap item; keep regression tests around delay sizing and stereo separation. |
| Final post-injection clamp | Landed: composite budget governor enforces `audioCeil = (threshold/outputGain - reserved - margin) * outputGain` before pilot/RDS injection, and `compositeCalibrationStatus.overBudget` surfaces configs where subcarrier reservation cannot fit. The final `clampf(mpx, -1, 1)` remains as a last-resort numeric guard. | Tests pin overshoot near zero for default + hot-but-sane configs; pathological gains surface the over-budget flag rather than silently clipping. |
| Pre-encode limiter live apply | Landed: threshold and release are in runtime config and live-applied through the generator. | No longer a risk item. |
| Receiver-model verification | Partly present in tests, but not yet a reusable verifier output with PLL, decoded L/R metrics, pilot error, RDS band metrics, and post-injection overshoot counts. | Keep as a high-value verification roadmap item. |
| Transient-aware multiband | Not landed for `MonoCompressor`. PrimeBass has its own transient detector, and the wideband AGC has program-density logic, but the per-band compressor is still single-pole abs-envelope driven. | Still a valid DSP quality upgrade. |
| Inter-band gain coupling | Not landed. Current multiband linking is L/R sidechain linking inside each band, not low-band gain driving mid/high thresholds. | Still open. |
| Multiband composite clipping | Not landed. Current `CompositeClipper` is fullband composite clipping with differential residual cancellation and protected-band substitution. | Still open and higher effort. |
| Dynamic pre-emphasis load manager | Not landed. Pre-emphasis placement is now correct in L/R before the pre-encode limiter, but there is no HF sidechain relaxation. | Still open. |
| Composite peak-to-RMS governor | Not landed. `BS412PowerLimiter` controls regulatory average MPX power; it is not a crest/peak-to-RMS density governor. | Still open. |

## Current Direction: Swift First

For now, MPX Prime stays Swift. The priority is to make the current
macOS/Swift DSP chain correct, verified, tunable, and operator-friendly
before spending effort on a rewrite or broad cross-platform expansion.

Practical order:

1. Finish the Swift DSP chain properly: clamp prevention, verifier
   metrics, presets, calibration, and live-apply smoke tests.
2. Keep the DSP code portable in principle: isolate platform audio I/O,
   locks, device enumeration, and UI concerns from `MPXGenerator`.
3. Revisit Linux once the Swift/macOS baseline is mature. Per `plan.md`,
   the preferred Linux route is still Swift DSP with a JACK/ALSA backend,
   not a C++ rewrite.
4. Treat Windows/JUCE/VST work as later optional product expansion, not
   near-term DSP work.

## Cross-Platform Vision

Longer term, MPX Prime can become a cross-platform FM audio processor
that runs on:

- macOS (current)
- Linux
- Windows

## Strategy

Status note: this C++/JUCE strategy predates the current direction in
`plan.md` and is not the active plan. The active plan is Swift-first:
finish the existing DSP, then add platform-specific backends if/when
cross-platform work becomes worth the cost.

### 1. Port MPXGenerator to C++

Deferred. Do not start this unless the Swift-first route hits a concrete
blocker that cannot be solved with conditional compilation and
platform-specific audio backends.

The DSP core (MPXGenerator) is the "crown jewel" - the real-time FM MPX generation engine.

**Approach:**
- Rewrite MPXGenerator in clean C++ (C++17)
- Use only standard C++ libraries (no platform-specific code)
- Create C API wrapper (extern "C") for language bindings
- Keep same architecture: per-sample processing, filter cascades, RDS coder

**Benefits:**
- Portable to any platform with a C compiler
- Can be called from Swift, Python, Rust, etc.
- JUCE framework integration ready

### 2. Cross-Platform GUI

**Recommended: JUCE**

| Framework | Pros                                                  | Cons                 |
| --------- | ----------------------------------------------------- | -------------------- |
| **JUCE**  | Built for audio, VST/AU export, cross-platform native | Less flexible UI     |
| **Qt**    | Excellent cross-platform, flexible                    | Larger, more complex |
| **ImGui** | Fast, simple                                          | Not native-looking   |

**Recommendation: JUCE**
- Built specifically for audio applications
- Native look on each platform
- Easy integration with C++ DSP code
- Can export as VST3/AU plugins

### 3. Architecture

```
┌─────────────────────────────────────────────┐
│              Cross-Platform UI              │
│              (JUCE on Win/Lin,             │
│               SwiftUI on macOS)            │
└─────────────────┬───────────────────────────┘
                  │ C API
┌─────────────────▼───────────────────────────┐
│           MPXGenerator C++ Core             │
│  - Stereo encoder                           │
│  - RDS coder                                │
│  - DSP processing                           │
│  - All platform-agnostic                    │
└─────────────────────────────────────────────┘
```

### 4. Platform-Specific Audio

- **macOS**: AVAudioEngine (current)
- **Linux**: ALSA or PipeWire + JACK
- **Windows**: WASAPI or ASIO

Each platform has its own audio I/O layer calling into the shared C++ DSP core.

## Implementation Notes

### C++ Core Requirements
- No Swift/Objective-C dependencies
- No platform APIs (CoreAudio, ALSA, WASAPI)
- Thread-safe configuration updates
- Lock-free audio callback interface

### Swift Integration (macOS)
- Keep current SwiftUI app
- Use C bridging header to call C++ core
- Gradually migrate DSP to C++

### Performance Target
- Maintain real-time performance on mid-range hardware
- i7-7700K / Ryzen 5 2600 equivalent or better
- < 10% CPU with full processing chain

## Current Status

- macOS/SwiftUI version in active development; latest release **0.24** (2026-05-10); 0.25 work accumulating on `develop/v.025` (chain-order modernization landed: pre-emphasis relocated L/R upstream of pre-encode limiter, PrimeBass moved post-multiband, stereo widener moved post-multiband — chain now matches Optimod / Omnia / Stereotool canonical ordering at every load-bearing position)
- Current macOS chain ships pre-encode L/R true-peak limiter (Audio Limiter tab — Threshold + Release exposed in GUI), Final Stage workflow tab (Broadcast Preset + Final Drive + Composite Deviation + Final-MPX Safety Limiter card), Engine — TX path card on Core (linear-phase FIR encoder lowpass + FIR multiband splitter toggles), 8× oversampled composite clipper with linear-phase FIR decimation + differential topology + delta-based per-band IM cancellation (per-band cancel toggles all in GUI), linear-phase FIR multiband crossovers in TX path, PrimeBass adaptive LF enhancement (MaxxBass equal-loudness harmonics + Aphex pre-waveshaper allpass + Werrbach transient-discriminate gain + Werrbach Big Bottom envelope follower), comprehensive RDS live-apply (PI/PTY/PTYN/ECC/LIC/TP/TA/MS/DI/AF/group-sequence/scheduler/CT all live without restart), AF Method B + TA-flag auto-injection, first-class Test Tone tab with Stereo Tool parity (sine / pink / white, four stereo modes, frequency presets, dBFS level, ⌘T), adaptive on-screen FPS for meters / scopes / spectrum, vDSP/vForce SIMD on hot loops, italo / disco / dance presets, mono bass + stereo-image handling, an optional deep DSP combination test suite (`MPXPRIME_DEEP=1`), and (0.24) **direct AUHAL input capture** via `InputAUHAL` — closes the AVAudioEngine first-start failure on non-default input devices (the auto-start Stop+Start watchdog is gone)
- C++ core - not started
- JUCE GUI - not started
- Linux/Windows ports - not started

## Near-Term Priorities Before Cross-Platform Work

- transient-aware multiband attack + per-band look-ahead (Phase 2 of multiband DSP modernisation; FIR crossovers shipped 0.11)
- inter-band gain coupling (Optimod-style "loud bass softens highs")
- broaden deterministic MPX verification and stereo/mono-compatibility checks
- tighten pilot/RDS/deviation calibration workflow
- stabilize presets for PrimeBass, widener, mono bass, and final-stage loudness

## DSP Enterprise-Level Roadmap

These are DSP additions that would move MPX Prime closer to an enterprise MPX processor. They are ranked by practical payoff, not novelty. The common theme: add explicit control laws and measurable invariants instead of relying on "sounds OK" tuning.

### 1. Composite budget governor (post-injection clamp eliminator) — LANDED

Landed in 0.26. The audio composite ceiling is now budgeted before pilot/RDS injection so their addition cannot exceed full scale. Pilot and RDS remain post-limiter (constant amplitude). The final `clampf(mpx, -1, 1)` is retained only as a last-resort numeric guard.

Implementation:

- `MPXGenerator.makeFinalCompositeThresholds(outputGain:threshold:reserved:)` computes `allowedAudioAbs = max(0, effectiveThreshold - reserved - safetyMargin)` and an `overBudget: Bool` flag. The old `finalCompositePreLimiterFloor` / `finalCompositePostLimiterFloor` hard floors are gone.
- `processFinalComposite` enforces `audioCeilOut = thresholds.postLimiterCeiling * outputGain` as a hard ceiling on `mpx` before pilot/RDS injection.
- `postInjectionOvershootEnv` (50 ms decayed envelope) and `compositeCalibrationStatus.overBudget` expose runtime status to UI and verifier.
- `PostInjectionClampTests` pins overshoot < 1e-4 for default and < 1e-2 for hot-but-sane (+6/+12 dB) configs; pathological (+24 dB) gain surfaces `overBudget == true`.

Follow-up: promote `postInjectionOvershoot > 0` from "TIGHT" to a hard verifier failure once the receiver-model verifier (item 2) gives finer-grained ground truth.

### 2. Transient-aware multiband envelope follower

Goal: stop the multiband from flattening kick/snare fronts while still controlling sustained energy. Enterprise processors do this with peak/RMS hybrid detection and transient-dependent attack.

Core arithmetic per band:

```text
peakEnv[n] = max(abs(x[n]), peakEnv[n-1] * peakDecay)
rmsEnv[n] = sqrt((rmsCoeff * rmsEnv2[n-1]) + ((1 - rmsCoeff) * x[n]^2))
crest = peakEnv / max(rmsEnv, 1e-6)
transient = clamp((crest - crestStart) / (crestFull - crestStart), 0, 1)
attackMS = lerp(baseAttackMS, transientAttackMS, transient)
```

For transient preservation, `transientAttackMS` is usually slower than the normal attack for the first few milliseconds.

Example:

```text
peakEnv = 0.90
rmsEnv = 0.28
crest = 0.90 / 0.28 = 3.21
crestStart = 2.0
crestFull = 5.0
transient = (3.21 - 2.0) / (5.0 - 2.0) = 0.40
baseAttackMS = 8 ms
transientAttackMS = 28 ms
attackMS = 8 + (28 - 8) * 0.40 = 16 ms
```

Result: a percussive hit gets a slower attack and keeps punch. Sustained dense audio, with crest near 1.5, uses the normal faster attack.

### 3. Inter-band gain coupling

Goal: make the multiband behave more like an Optimod-style processor: heavy low-band gain reduction can gently soften upper-band drive so bass does not punch holes into the rest of the spectrum or make highs sound disconnected.

Core arithmetic:

```text
lowGR = max(0, -lowBandGainDB)
midBiasDB = -0.20 * lowGR
highBiasDB = -0.35 * lowGR
midThresholdEffective = midThresholdDB + midBiasDB
highThresholdEffective = highThresholdDB + highBiasDB
```

Example:

```text
low band GR = 6 dB
midBiasDB = -0.20 * 6 = -1.2 dB
highBiasDB = -0.35 * 6 = -2.1 dB
mid threshold -16.0 dB -> -17.2 dB
high threshold -14.5 dB -> -16.6 dB
```

That makes the mid/high compressors slightly more active while bass is being heavily controlled. Smooth the bias with attack around 20 ms and release around 300 ms so it feels like program-dependent balance, not pumping.

### 4. Multiband composite clipper

Goal: get more loudness for the same peak deviation with less tonal shift than a single full-band composite clipper.

Suggested split:

```text
Band A: 0-180 Hz
Band B: 180-2,000 Hz
Band C: 2,000-15,000 Hz audio
Band D: 23,000-53,000 Hz stereo subcarrier sideband
```

Each band has its own ceiling and cancellation policy. Recombine with linear-phase delay alignment.

Example thresholds:

```text
fullbandCeiling = -0.30 dBFS -> 0.966 lin
lowCeiling = -1.20 dBFS -> 0.871 lin
midCeiling = -0.60 dBFS -> 0.933 lin
highCeiling = -0.20 dBFS -> 0.977 lin
stereoSidebandCeiling = no clip; substitution/cancellation only
```

Arithmetic for per-band clip:

```text
over = max(0, abs(bandSample) - threshold)
shaped = sign(x) * (threshold + knee * tanh(over / knee))
residual = bandSample - shaped
```

For enterprise behavior, the stereo sideband band should prefer residual cancellation/substitution over direct clipping so stereo separation remains stable.

### 5. Dynamic pre-emphasis load manager

Goal: reduce pre-emphasis-driven limiter stress on bright transients without changing the static 50/75 us compliance target during normal material.

Do not switch pre-emphasis curves abruptly. Use a sidechain that detects excess HF energy and blends a small relaxation gain after the pre-emphasis filter, before the pre-encode limiter.

Core arithmetic:

```text
hf = highpass(program, 6 kHz)
hfEnv = envelope(abs(hf), attack=1 ms, release=80 ms)
over = max(0, db(hfEnv) - hfTargetDB)
relaxDB = -min(maxRelaxDB, over * ratio)
hfGain = 10^(relaxDB / 20)
output = lowBand + hfGain * highBand
```

Example:

```text
hfEnv = -9 dBFS
hfTargetDB = -15 dBFS
over = 6 dB
ratio = 0.35
maxRelaxDB = 3.0
relaxDB = -min(3.0, 6 * 0.35) = -2.1 dB
hfGain = 10^(-2.1 / 20) = 0.785
```

The listener hears almost the same tonal balance, but the pre-encode limiter sees fewer extreme HF peaks.

### 6. Receiver-model verification loop

Goal: make every DSP change answerable by receiver-facing metrics, not just waveform peak metrics.

Offline verifier should decode the generated MPX like a simple FM stereo receiver:

```text
M = lowpass(mpx, 15 kHz)
pilotPhase = PLL(mpx around 19 kHz)
carrier38 = sin(2 * pilotPhase)
S = lowpass(2 * mpx * carrier38, 15 kHz)
L = M - S
R = M + S
```

Example metrics:

```text
input: L=1 kHz sine at -6 dBFS, R=silence
decoded L RMS = -9.1 dBFS
decoded R RMS = -49.5 dBFS
separation = decodedL - decodedR = 40.4 dB
pass threshold: > 35 dB through full chain at default loudness
```

Add verifier outputs for:

- stereo separation at 1 kHz, 10 kHz, and 14 kHz,
- mono compatibility correlation,
- pilot amplitude error,
- RDS band RMS and centre null,
- post-injection overshoot count,
- MPX power average and peak-to-RMS ratio.

### 7. Composite peak-to-RMS governor

Goal: reduce multipath-sensitive "spiky" composite output without just crushing peaks. This is a higher-level controller around final drive and composite clipper drive.

Core arithmetic over a rolling window:

```text
peak = max(abs(mpx))
rms = sqrt(mean(mpx^2))
crestDB = 20 * log10(peak / max(rms, 1e-6))
driveTrimDB = -k * max(0, crestDB - targetCrestDB)
```

Example:

```text
peak = 0.98
rms = 0.31
crestDB = 20 * log10(0.98 / 0.31) = 10.0 dB
targetCrestDB = 8.5 dB
k = 0.4
driveTrimDB = -0.4 * (10.0 - 8.5) = -0.6 dB
```

Apply `driveTrimDB` slowly, e.g. 1-3 s attack and 5-10 s release. This is not a limiter; it is an automatic preset guardrail that keeps long-term composite density in a controlled window.

### Expired patent candidates to evaluate

These are expired or inactive patent families that look useful for enterprise-level DSP work. Status must be rechecked by jurisdiction before any commercial release; this list is a technical backlog, not legal advice.

Already used or structurally equivalent:

| Patent | Status | Current use |
| --- | --- | --- |
| US6337999B1, oversampled differential clipper | Expired / inactive | `CompositeClipper` already uses the differential residual topology: clean delay path plus oversampled clipped residual path. |
| US4460871A / US4249042A family, Orban overshoot/cross-coupled compressor ideas | Expired | Partly used through per-band clip residual cancellation; cross-band compressor coupling is not yet implemented. |
| US6618486B2, BS.412 multiplex power controller | Expired / inactive | `BS412PowerLimiter` is functionally similar: power measurement plus slow gain control. |
| US5930373A, US4150253A, US5424488A, US5359665A bass enhancement ideas | Expired | PrimeBass already implements MaxxBass / Aphex / Werrbach-style harmonic and envelope concepts. |

High-value unused candidates:

| Priority | Patent | Idea | Why it matters |
| --- | --- | --- | --- |
| 1 | US6937912B1, anti-aliased clipping with band-limited step functions | Compute clipping residuals using band-limited steps around threshold crossings. | Replaces "clip then remove aliases" with "generate fewer aliases in the first place." Best candidate for cleaner pre-encode and composite clipping. |
| 2 | US6434241B1, half-cosine FM composite peak control | Fit half-cosine curves to composite clipping-error peaks, filter the error, subtract it from composite. | Good candidate for bounded composite peak correction without adding a nonlinear stage after pilot/RDS injection. |
| 3 | US5737434A, multiband compressor with look-ahead clipper | Delayed audio path, center-clip sidechain, retriggerable sample/hold, LPF, reciprocal gain law. | Useful for a smoother pre-encode limiter or per-band limiter that produces less clipping-like distortion. |
| 4 | US4249042A / US4460871A, multiband cross-coupled compressor | Master band energy controls slave-band gain, with local per-band protection. | Maps directly to inter-band coupling: loud bass can gently soften mids/highs without wideband pumping. |
| 5 | US5913152, FM composite signal processor | Pilot protection plus adjustable limiting and overshoot compensation. | Some is redundant with post-injection pilot/RDS and guard cancellation, but it may contain useful composite overshoot-control details. |

Candidate arithmetic sketches:

Band-limited clipping residual:

```text
crossingFrac = (threshold - x[n-1]) / max(x[n] - x[n-1], 1e-9)
clipResidual = x - clamp(x, -threshold, threshold)
aaResidual = clipResidual * bandlimitedPulse(crossingFrac)
output = input - aaResidual
```

Half-cosine composite correction:

```text
error = composite - clamp(composite, -ceiling, ceiling)
peakA = previousErrorPeak
peakB = currentErrorPeak
halfCos[k] = (peakA + peakB) / 2 + ((peakA - peakB) / 2) * cos(2*pi*k/N)
filteredError = lowpassAndPilotNotch(halfCos)
correctedComposite = composite - filteredError
```

Cross-band coupling:

```text
lowGR = max(0, -lowBandGainDB)
highThresholdBias = -0.35 * lowGR
highThresholdEffective = highThresholdDB + highThresholdBias
```

## Composite peak-control follow-ups

The composite-clipper cleanup (0.11) removed the broken
`CompositeTruePeakLimiter` and replaced it with an 8x oversampled
delta-based clipper using RBJ bandpass guards for pilot/RDS and an
LP-difference guard for the stereo subbands (Orban US 4,460,871 /
5,737,434, expired).

Current status: true composite clipper look-ahead has landed in code
(`mpx_clipper_lookahead_ms`, default off). It uses an oversampled
sliding-window detector and delay-matched gain application before the
soft-clip kernel. The future work is no longer "add look-ahead"; it is:

- tune the default/preset value after listening tests,
- verify dense real-program behavior through the offline verifier,
- decide whether to enable a conservative default in loud presets,
- keep the pilot/RDS guard and stereo sideband cancellation tests tight.

What's deliberately deferred:

- **Zero-overshoot enterprise proof.** The landed look-ahead bounds peaks
  better than the old time-symmetric soft clipper, but it is still a
  practical processor control law, not a formal proof that every possible
  intersample transient is bounded after all downstream stages.
- **Multiband composite limiting.** Spectral-band-specific clip thresholds
  give more loudness for the same peak modulation and avoid the "tonal
  shift under heavy clipping" Orban Optimod 8x00 series is famous for
  fixing.
- **Multipath-robustness peak-to-RMS constraint.** Composite peak-to-RMS
  ratio strongly affects FM multipath rejection at the receiver. Modern
  processors hold this ratio inside a target window. Today nothing in
  the chain explicitly tracks or constrains it.

What's *not* worth doing in this codebase:

- **Sidechain-the-limiter-from-`L+R` per Orban US 4,134,074 (1979) /
  4,377,728 (1983).** Once the clipper does proper per-band distortion
  cancellation (already shipped), gain reduction is multiplicative —
  stereo separation is preserved by construction regardless of what
  drives the sidechain. The `L+R` sidechain trick buys ~1–2 dB more
  loudness on stereo content, not a correctness fix. Skip.
