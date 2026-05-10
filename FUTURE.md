# MPX Prime Future Roadmap

## Cross-Platform Vision

The goal is to make MPX Prime a truly cross-platform FM audio processor that runs on:
- macOS (current)
- Linux
- Windows

## Strategy

### 1. Port MPXGenerator to C++

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

- macOS/SwiftUI version in active development; latest release **0.23** (2026-05-10); 0.24 work accumulating on `develop/v.024`
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

## Composite peak-control follow-ups

The composite-clipper cleanup (0.11) removed the broken
`CompositeTruePeakLimiter` and replaced it with an 8x oversampled
delta-based clipper using RBJ bandpass guards for pilot/RDS and an
LP-difference guard for the stereo subbands (Orban US 4,460,871 /
5,737,434, expired). What's deliberately deferred:

- **True look-ahead with zero-overshoot guarantee.** Modern processors
  (Optimod 8x00, Omnia.9, Stereo Tool) drive the composite clipper from
  a sidechain that knows future peak amplitude, so gain reduction is
  applied before the peak arrives and overshoots are mathematically
  bounded. Today the clipper is purely time-symmetric soft-clip with no
  look-ahead.
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

