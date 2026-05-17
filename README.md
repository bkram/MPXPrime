# MPX Prime

Version: 0.30

MPX Prime is a native macOS FM composite (MPX) generator written in Swift and SwiftUI. It takes live audio input or a test tone, applies optional broadcast-style processing, generates stereo FM baseband with pilot and optional RDS, and sends MPX plus optional decoded monitor audio to Core Audio devices.

MPX Prime is experimental and not suitable for production broadcast use. It targets core behavior from EN 50067 / IEC 62106 and common FM stereo practice, but it is not certified and no compliance warranty is implied.

## Positioning

**Goal: be the best amateur-grade FM processor available** — for hobbyist LPFM, community radio, pirate, SDR-fed exciters, and DIY broadcast workflows. MPX Prime is *not* trying to be a $5–15k Optimod / Omnia / Stereo Tool replacement; it is trying to be the obvious choice where commercial processors are unaffordable or overkill. See [`plan.md`](plan.md) "Positioning" for the full scope-in / scope-out list.

**Compared to open-source FM generators** (mpxgen, PiFmRds), MPX Prime runs a real processing chain in front of the encoder — phase rotator, wideband AGC with K-weighted detector + program-dependent release, 4-band parametric EQ, mono bass, 3- or 5-band multiband compressor with per-band expander and limiter (linear-phase FIR multiband crossovers in TX path), stereo widener, PrimeBass, bass clipper, audio-band distortion-cancelled clipper, L/R pre-emphasis, pre-encode L/R true-peak limiter (0.30: with default-on look-ahead and Dolby HF-subband-aware detector per `US 5,579,404`), BS.412, and a 16× oversampled composite clipper with delta-based per-band IM cancellation plus an experimental default-off multiband composite clipper — and enforces the professional invariant that pilot and RDS bypass all peak control (post-clipper subcarrier injection). Stage ordering matches Optimod / Omnia / Stereotool canon at every load-bearing position (PrimeBass and stereo widener post-multiband; pre-emphasis L/R upstream of pre-encode limiter). Add to that linear-phase Kaiser-windowed FIR encoder lowpass with ≥80 dB stop-band, 19 kHz pilot notch on the audio path, pilot-locked RDS with 301-tap biphase + optional Gaussian shaping, lock-free real-time DSP with vDSP/vForce SIMD acceleration on hot loops, and an offline verification harness with scenario / stereo / width / receiver / composite-multiband A/B tables. Open-source generators typically emit a valid MPX waveform without any of that.

**Compared to commercial processors**, MPX Prime's topology matches what Orban / Omnia / Stereo Tool publish, and individual stages (phase rotator, multiband with linear-phase FIR crossovers and stereo linking, post-clipper subcarrier injection, BS.412, delta-based per-band IM cancellation in the composite clipper, oversampled differential composite clipping, equal-loudness-weighted bass harmonic synthesis, transient-discriminate harmonic gain) are implemented at professional quality. The published claims used as design references are all expired (Orban [US 4,460,871](https://patents.google.com/patent/US4460871A) and [US 5,737,434](https://patents.google.com/patent/US5737434A) for distortion-cancelled composite clipping, [US 6,337,999](https://patents.google.com/patent/US6337999B1) for the differential topology, Waves [US 5,930,373](https://patents.google.com/patent/US5930373A) for MaxxBass-style equal-loudness harmonics, Aphex [US 4,150,253](https://patents.google.com/patent/US4150253A) for the pre-waveshaper allpass topology, and Werrbach [US 5,424,488](https://patents.google.com/patent/US5424488A) for transient-discriminate harmonic gain) — i.e., the techniques are public-domain prior art, not licensed reproductions. What's deliberately *out of scope* for amateur-grade: MPX-over-AES3 / Baseband192 transport, studio automation (Livewire/Dante/Ravenna), multi-site clustering, ITU-R SM.1268 RF-mask feedback at production grade, multipath mitigation. Lower-priority polish items still pending: heavier (16–32×) oversampling on the clipping nonlinearities, dynamic pre-emphasis, input-side restoration (declipper, dehumfilter). See [`plan.md`](plan.md) "Next up" for the current roadmap.

In short: well past the hobbyist baseline, sized for amateur broadcast use. Use MPX Prime for LPFM, community radio, pirate, prosumer broadcast-style encoding, and study of FM signal processing — not for certified production broadcast.

### Trademarks and affiliations

MPX Prime is an independent open-source project. Names referenced in this README, the changelog, and the source — including but not limited to **Orban**, **Optimod**, **Omnia**, **Stereo Tool** / **Stereotool**, **Aphex** (Aural Exciter, Sound Enhancement System, Big Bottom), **Waves** (MaxxBass), **BBE** (Sonic Maximizer), **DTS**, **Music Tribe**, **Inovonics**, **DEVA** (SmartGen), **Audemat**, **BW** (RDS3), **JUCE**, **Qt**, **Apple**, **macOS**, **AVFoundation**, **CoreAudio**, **AVAudioEngine**, **vDSP**, **vForce**, **JACK**, **ALSA**, **AES3**, **DAB+**, **Livewire**, **Dante**, **Ravenna** — are trademarks or registered trademarks of their respective owners. Their use here is descriptive only (to identify and compare against published behavior, prior art, and platform APIs); MPX Prime is not affiliated with, endorsed by, or sponsored by any of them.

## Current app structure

- `Monitoring`: live status, transport, interfaces summary, DSP status, RDS snapshot
- `Processing`: Overview, Core, Phase Rotator, AGC, Parametric EQ, Multiband (with optional transient-aware attack + inter-band gain coupling), Expander, MB Limiter, Stereo Widener, PrimeBass, Bass Clipper, DC Clipper, Audio Limiter, Composite Clipper (optional look-ahead peak control and experimental multiband composite clipping on top of the soft-clipper), BS.412, Final Stage
- `RDS`: status (master enable + live snapshot), identity (PI / PTY / PTYN / ECC + PS banks + runtime flags TP / TA / MS / DI), radiotext (RT / RT+ / Now Playing), long PS, alt. frequencies (AF), schedule (group sequence + clock-time), subcarrier (injection level + frequency + Gaussian shaping)
- `Tools`: Test Tone (sine / pink / white, four stereo modes, frequency presets, dBFS level — replaces the audio input live when enabled, ⌘T)
- `Settings`: configuration path, interfaces, audio engine, spectrum options
- Separate windows: `Scopes`, `Spectrum`, `Levels`, `Help`

The RDS detail tabs are organised per UECP message-class taxonomy
(AF is a peer of PS, RT+ lives under ODA, etc.). Every operationally
toggled RDS setting applies live without restarting the transport —
PI, PTY, PTYN, TP/TA/MS/DI flags, AF list, group sequence, CT
enable, all RT/PS/Long PS text. Only physical-layer settings
(`rds_level`, Gaussian shaping FIR taps/BW) require a
transport restart since they reconfigure the modulator.

## Features

- Native macOS app built with Swift + SwiftUI + AppKit windowing
- Real-time MPX generation with 19 kHz pilot and 38 kHz stereo subcarrier
- **Premium receiver-side stereo separation** at the default config (0.28): 65 dB at 1 kHz, 50.5 dB at 10 kHz, 43.4 dB at 14 kHz, measured by `--verify-receiver` through the reusable `MPXDecoder` (matches Optimod 8x00 / Stereotool published numbers)
- Optional RDS generation with pilot-locked 57 kHz subcarrier
- Live input source or built-in **Test Tone** generator (sine / pink / white, mono / L=−R / left-only / right-only modes, frequency presets, −60..0 dBFS level slider, live Enable toggle that replaces the audio input without restarting the engine)
- Optional wideband AGC, HPF, program lowpass, HF trim, PrimeBass, mono bass, stereo widener, and multiband processing (including 0.28 opt-in transient-aware attack + inter-band gain coupling)
- Broadcast-style **Final Stage** (Broadcast Preset + Final Drive + Composite Deviation + Final-MPX safety limiter with look-ahead) and a separate **Audio Limiter** tab (pre-encode 4× oversampled stereo-linked true-peak limiter with default-on look-ahead and Dolby HF-subband-aware detector — `US 5,579,404`, expired 2013 — for audibly cleaner HF transients and preserved LF punch), feeding the 16× oversampled composite clipper (with optional OS-rate sliding-window-max look-ahead peak control and experimental default-off multiband composite clipping) with live clipper telemetry
- TX-path engine toggles on the Core tab: linear-phase FIR encoder lowpass and FIR multiband splitters (latency vs. quality choices, restart-required)
- Composite budget telemetry with pilot/RDS/audio visibility, safety-limiter readout, and a composite budget governor that holds the audio path under the post-injection clamp so pilot/RDS subcarrier amplitude stays constant for sane configs (over-budget flag for impossible configs)
- Broadcast preset picker for AGC/final-stage tuning (`Balanced Music`, `CHR / Dance`, `Punchy Music`, `Speech / Talk`)
- Italo / disco / dance multiband presets (`5B Italo`, `3B Italo`) with pumped low-band character
- Decoded MPX monitor output on a selectable monitor device
- Scopes, spectrum, levels, sticky peaks, and live monitoring views
- Config persisted to `~/Library/Application Support/MPX Prime/MPX Prime.ini`

## Requirements

- macOS 15+
- Xcode command line tools / Swift 6 toolchain (only needed for building from source — download the DMG below if you just want to run it)
- **External USB / Thunderbolt audio interface that supports 192 kHz output is effectively required.** The built-in audio on Mac laptops and most desktops tops out at 96 kHz, which cannot carry RDS (RDS sits at 57 kHz, above the 48 kHz Nyquist of a 96 kHz device). For a full composite with stereo + RDS you need a sound card that runs at 192 kHz natively. 96 kHz devices can carry stereo-without-RDS only.
- Input devices may run at lower rates; the app handles conversion internally

## Download

Pre-built universal binaries (Apple Silicon + Intel) ship as macOS `.dmg` files on the project's GitHub Releases page:

**[github.com/bkram/MPXPrime/releases](https://github.com/bkram/MPXPrime/releases)**

Each release is built and signed by GitHub Actions from the matching tag. Pick the latest version, download `MPX_Prime-<version>.dmg`, drag `MPX Prime.app` into `/Applications` (or any folder you prefer), and launch.

### First-launch security note

MPX Prime is **ad-hoc signed**, not Apple-notarized. The DMG is built and signed by an automated GitHub Actions workflow with a self-managed signing identity — it is *not* enrolled in the Apple Developer Notary Service. As a result, macOS Gatekeeper will refuse to open the app on first launch with a message similar to:

> *"MPX Prime" cannot be opened because Apple cannot check it for malicious software.*

This is the standard macOS warning for any app distributed outside the Mac App Store / Apple Notarization. To approve the app once:

1. Open **System Settings → Privacy & Security**.
2. Scroll to the **Security** section near the bottom. You will see a message like *"MPX Prime was blocked from use because it is not from an identified developer"*.
3. Click **Open Anyway** next to that message.
4. The next time you launch MPX Prime, macOS will prompt one more time — click **Open**.

After the first approval, MPX Prime launches normally on subsequent runs. This is a one-time per-version operation; updating to a new release will trigger the prompt again on first launch.

If you would rather skip the Gatekeeper dialog entirely, build from source (see below) — locally built binaries are not subject to the same check.

## Build

If you prefer building from source instead of downloading the release DMG:

```bash
swift build --package-path macOS
```

> ⚠️ **Debug builds are not real-time capable.** `swift build` (no `-c release`) and `swift run` produce a debug binary without compiler optimizations. The audio render thread shares CPU with the main-thread UI loop, and on a debug build the meter / scope / spectrum work in `refreshMonitoringSnapshot` is slow enough to occasionally preempt the audio thread — you'll hear clicks, buffer underruns, or input ring overflows. Debug builds are fine for development / unit testing / `--verify` runs (which don't touch real audio devices), but **for actual on-air or monitor playback always use a release build**: either `swift build --package-path macOS -c release` followed by running `macOS/.build/release/MPXPrime`, or use the DMG produced by `./build-release.sh` / a GitHub Release.

## Run

From repo root:

```bash
swift run --package-path macOS MPXPrime
```

Headless mode:

```bash
swift run --package-path macOS MPXPrime --nogui
```

Fixed runtime:

```bash
swift run --package-path macOS MPXPrime --seconds 10
```

Offline verification:

```bash
swift run --package-path macOS MPXPrime --verify --seconds 5
```

Preset sweep verification:

```bash
swift run --package-path macOS MPXPrime --verify-presets --seconds 5
```

Long-run compliance/regression verification:

```bash
swift run --package-path macOS MPXPrime --verify-long --seconds 30
```

Receiver-model verification (0.27 reusable `MPXDecoder` + 0.28 expanded
analysis — coherent + PLL external-style decode, raw encoder-side
sideband symmetry, per-stage isolation sweep, and ideal-receiver A/B):

```bash
swift run --package-path macOS MPXPrime --verify-receiver --seconds 5
```

Reports per-tone stereo separation (1 / 10 / 14 kHz) on both coherent
and PLL decode, raw `(L-R)` lower/upper sideband balance, a per-stage
on/off sweep that attributes encoder-side loss to specific blocks, an
"ideal receiver" decode that isolates phase alignment from filter
shape, mono compatibility, pilot percent and phase, and RDS sideband
+ center-null levels. Default-config decode at 0.28: 65.0 / 50.5 /
43.4 dB at 1 / 10 / 14 kHz.

Composite multiband clipper A/B verification (0.28 - compares the default
chain with `mpx_multiband_clipper_enabled = True` on dense/HF scenarios):

```bash
swift run --package-path macOS MPXPrime --verify-composite-multiband --seconds 2
```

Multiband inter-band coupling A/B verification (0.28 - forces multiband on,
disables AGC for isolation, and compares `multiband_inter_band_coupling_enabled`
off/on):

```bash
swift run --package-path macOS MPXPrime --verify-multiband-coupling --seconds 2
```

Custom config file:

```bash
swift run --package-path macOS MPXPrime --config "/path/to/MPX Prime.ini"
```

## Quick start (first-time use)

This is the minimum to hear MPX Prime processing your audio and feeding a transmitter / SDR / loopback. Defaults are tuned to sound good out of the box — the chain ships processing-on with AGC, multiband, bass clipping, and the composite clipper engaged.

**1. Plug audio in and out.** MPX Prime reads from a Core Audio input device and writes the composite (MPX) signal to a Core Audio output device. Typical setups:

- Soundcard input from your studio mixer / streaming source → soundcard output into an FM exciter that accepts MPX baseband.
- BlackHole 2ch (virtual loopback) input from a music player or DAW → soundcard output into an SDR transmitter or RF generator.
- Test tone source (built-in) → output to verify metering and routing without external audio.

192 kHz output is **required for the full composite with RDS.** RDS sits at 57 kHz, which exceeds the 48 kHz Nyquist of 96 kHz sample rates — the RDS subcarrier cannot be represented at 96 kHz or below. 96 kHz is just enough to carry the FM stereo composite alone (M + 19 kHz pilot + 38 kHz DSB-SC stereo subcarrier) provided the audio bandwidth is limited so the upper L−R sideband doesn't push past 48 kHz; pilot-locked stereo decoding works, but disable RDS at this rate. Below 96 kHz the stereo subcarrier itself doesn't fit. 192 kHz is the recommended rate for everything because it gives Nyquist headroom for the post-clipper pilot/RDS injection plus the oversampled peak-control stages the chain runs above the host rate.

> **External sound card required for RDS.** Apple's built-in audio output on Mac laptops and most desktops tops out at **96 kHz**, which cannot carry RDS — the 57 kHz subcarrier exceeds 48 kHz Nyquist. For any FM-with-RDS chain you need a USB / Thunderbolt audio interface that natively runs at **192 kHz**. Most pro and prosumer interfaces (RME, MOTU, Focusrite Scarlett 3rd-gen+, Apogee, etc.) support 192 kHz on at least the analog or AES outputs — check the spec sheet before ordering. The internal Mac speakers / headphone jack are fine for *listening to a test tone* through MPX Prime, but they cannot be the production output if RDS is in play.

### Audio MIDI Setup — required output configuration

macOS configures Core Audio device parameters via **Audio MIDI Setup** (`/Applications/Utilities/Audio MIDI Setup.app`). MPX Prime tells the engine what rate it wants, but the device-side format and volume are owned by the OS — wrong values there silently corrupt the composite before it leaves the Mac.

For the output device feeding your exciter / SDR / RF generator:

1. **Format / sample rate**: set to **192 000 Hz**. Match what the engine is configured to (`sample_rate = 192000` in INI). If the device runs at a different rate Core Audio inserts a sample-rate converter that cannot represent the upper composite band cleanly.
2. **Bit depth**: **24-bit integer or 32-bit float**. Either is fine; 32-bit float is the AVAudioEngine native format. 16-bit also *works* for the composite (96 dB SNR is well above any FM receiver's noise floor and you cannot hear the difference at the listener), but 24/32-bit is best practice — no extra dither/truncation step at the chain output, and headroom for downstream tools that further process the composite (resamplers, SDR DSPs).
3. **Volume / output gain**: **100 % (0 dB) on every channel**. This is the critical one. The macOS volume slider is post-mix — it scales the engine's already-finalised composite. If output volume is at, say, 75 %, the FM exciter receives a signal at 0.75× amplitude and your modulation undershoots by ~2.5 dB; the loudness target the chain just enforced is silently wrong. Audio MIDI Setup → device → "Master Stream" or per-channel volume sliders. Lock these at unity for any broadcast use.

If your output device is BlackHole or a virtual loopback, the same rules apply — check both the loopback device's format and the receiving app's input format. Mismatch there is the #1 cause of "the chain looks right but the receiver sounds wrong" reports.

**2. Set your region.** Pre-emphasis differs by region:

- **USA / Canada / South Korea**: 75 µs
- **Everywhere else (EU, ROW)**: 50 µs (current default)

Open `Processing` → `Core` and change `Pre-emphasis (μs)` to `75` if you are in a 75 µs region. Wrong pre-emphasis will sound either dull (50 into 75 deemph) or shrill / over-modulated (75 into 50 deemph). EU operators required to comply with ITU-R BS.412 should also enable `Processing` → `BS.412`. Every setting referenced in this guide is also reachable from the GUI; the INI is written automatically and is mainly there for inspection or out-of-band edits.

**3. Launch and Start.** Open MPX Prime, pick your input and output devices in `Settings`, then press `Start` (⌘Return) on the toolbar. The status bar at the top of the window shows live IN L/R, MPX peak, deviation in kHz, modulation as a percentage of the configured deviation target (MOD), gain reduction, safety-limiter GR, composite budget, and pilot/RDS injection — if those move with your audio, the chain is processing.

**4. Calibrate composite output level.** On `Monitoring`, watch the `Composite Budget` chip:

- **Safe**: nominal modulation, headroom available
- **Tight**: near 100% modulation, fine for normal broadcast
- **Risk**: peaks exceeding 100% — back off `MPX Output Level` on the `Core` tab

`Final Drive` (on the `Final Stage` tab) controls perceived loudness; `MPX Output Level` (on the `Core` tab) calibrates the final voltage to your exciter / SDR. Use `Final Drive` for loudness and `MPX Output Level` only for hardware calibration.

**5. Verify on a receiver.** Tune a real FM radio or RTL-SDR to your transmitter's frequency. You should hear stereo audio with a steady stereo-pilot indicator, see RDS PS and Radiotext on the radio's display (if your radio supports RDS), and the audio should sound louder and more present than the same source through `mpxgen` / PiFmRds.

If you cannot hear anything, check `Settings` → output device routing, that the engine is started, and that `Processing` → `Core` → `Bypass Processing` is **off** (the default).

## Configuration

Default config location:

```text
~/Library/Application Support/MPX Prime/MPX Prime.ini
```

Relevant config sections:

- `INTERFACES`: input/output/monitor device UIDs, source mode, monitor enable, block size
- `MPX`: processing, levels, stereo coding, limiter behavior
- `RDS`: program service, radiotext, flags, carrier settings

### Recommended DSP enablement (current default starting point)

For typical FM broadcast use (clean / community / LPFM), the recommended set of processing stages to **enable** is:

- **Phase Rotator** — voice waveform symmetrization (f ≈ 200 Hz)
- **Wideband AGC** — long-term level riding (target ≈ -14 dBLU, range ±10 dB, K-weighted, program-dependent release)
- **Parametric EQ** — 4-band tonal shaping (shelf + 2 peaks + shelf)
- **Multiband Compressor** — 3-band LR4 (or 5-band FIR on TX path); the `5_jazz` preset is a balanced starting point for mixed music + speech
- **Downward Expander** — gates noise floor (threshold ≈ -45 dB, ratio 2.0:1)
- **MB Limiter** — per-band peak control (threshold ≈ -3 dB, atk 0.5 ms, rel 50 ms)
- **DC Clipper** — distortion-cancelled audio-band clipping with pilot/RDS protection
- **Audio Limiter** — pre-encode L/R true-peak limiter with default-on Phase 1 + Phase 2 look-ahead (Dolby `US 5,579,404`, HF-subband-aware) — see 0.30 CHANGELOG
- **Composite Clipper** — 16x oversampled differential composite clipper (threshold -1.0 dB, ceiling -0.3 dB, drive 6 dB)

Recommended **off** by default (enable only when needed):

- **Stereo Widener** — leave off unless the source program needs subtle width enhancement; aggressive widening risks mono-compatibility on FM (see "Stereo image control" below)
- **PrimeBass** — bass-enhancement harmonics; useful for thin source material, but adds harmonic content that competes with the audio composite headroom. Enable per-format.
- **Bass Clipper** — engage only when LF transients are pushing the chain past the downstream limiters; if PrimeBass is off, usually unnecessary.
- **BS.412 MPX Power Limiter** — required only for regulatory compliance in DE/AT/CH/SE/CZ/SI. NL, US, UK, FR, ES, IT etc. do not enforce BS.412; leaving it off recovers loudness headroom. See "When to leave BS.412 and the Composite Clipper off" below.

This is a sensible amateur-grade starting point. Tune from there based on listening A/B against your typical program material. Heavier formats (CHR, EDM, dance) may benefit from PrimeBass + Bass Clipper on; talk-heavy or classical formats may want Multiband intensity dropped and Composite Clipper drive reduced.

### Setting levels — input, AGC, Final Drive, exciter

Three knobs do most of the work between your source and the exciter. They sit at three different points in the chain and each does a specific job — get them right in order and the chain sounds clean without much fiddling.

**The chain (left to right):**

```
source → IN meter → AGC → [DSP] → Final Drive → composite clipper → MPX Output Level → exciter
                  ^                ^                                 ^
                  level control    loudness lever                   hardware calibration
```

**1. Get your input into the AGC's working range.** Open `Monitoring`. The `IN` meter shows the level coming into MPX Prime from your source (before any processing). Aim for input peaks landing roughly in the **−12 to −6 dBFS** range on busy program — bright but not pinned. If the source is consistently below −18 dBFS the AGC has to push hard to reach its target; if it's above −3 dBFS it's eating its own headroom before the chain even sees it.

The level adjustment lives upstream of MPX Prime — in your studio mixer, DAW, OS audio output, or BlackHole loopback source's gain. There's also `Processing` → `Core` → `Input Gain` (±24 dB) inside MPX Prime, but use that only to trim — the further upstream you fix the level, the less you stack noise floors.

**2. Let AGC do the level-evening.** Open `Processing` → `AGC`. The AGC's job is to ride out the long-term level differences between songs / shows / sources so the chain downstream sees a roughly constant program level. The two knobs that matter:

- `Platform Target` — the level the AGC drives the program *toward*. **Default −16 dBFS** (Balanced Music preset) is a good starting point and matches what Orban / Omnia / Stereo Tool ship by default. Lower target = AGC pulls more, denser sound; higher = lighter touch.
- `Enable Wideband AGC` — leave on. Even amateur source material (mixed-era MP3s, podcasts, vinyl rips) needs level-evening; without AGC, single-band peak limiting downstream pumps on bass-heavy program.

Watch the `AGC GR` field in `DSP Overview` (or the AGC card itself). Healthy operation:

- **0 to 3 dB occasional pulls** = source feeding cleanly, AGC riding lightly. Goal state.
- **Sustained 6+ dB pulls** = source is too hot. Back off upstream.
- **AGC pushing 6+ dB consistently (positive gain)** = source is too quiet. Boost upstream.
- **AGC parked at min/max gain limit** = source is so far off the AGC can't keep up — fix the source level.

Don't use AGC `Platform Target` as a loudness knob. It tunes the chain's working point, not perceived broadcast loudness.

**3. Set Final Drive for the loudness you want.** `Processing` → `Final Stage` → `Final Drive` is the primary loudness lever. It drives the audio composite into the composite clipper — higher drive = harder clipping = louder, denser, but also harsher. Range 0..12 dB.

- Pick the `Broadcast Preset` matching your content (Balanced Music / CHR-Dance / Punchy / Speech-Talk) — that sets a sensible Final Drive starting point along with matched AGC tuning.
- Nudge from there. Watch the **composite clipper `GR`** in `Monitoring`:
  - 0 to 3 dB occasional GR = clean, dynamic. Good for talk and acoustic music.
  - 3 to 6 dB regular GR = competitive loudness, contemporary radio sound.
  - Sustained 6+ dB = clipper is the loudness ceiling, you're trading dynamics and HF cleanliness for level.

Final Drive is not the same thing as MPX Output Level. Final Drive shapes loudness *inside* the chain; MPX Output Level adjusts the *voltage* leaving the Mac.

**4. Set MPX Output Level to match the exciter's input.** `Processing` → `Core` → `MPX Output Level` (±18 dB) is the final calibration knob — it scales the composite signal between MPX Prime and the exciter. The right value depends on your exciter / SDR / RF generator's input sensitivity.

- Watch the `Composite Budget` chip on `Monitoring`:
  - **Safe** — nominal modulation, headroom available
  - **Tight** — near 100 % modulation, fine for normal broadcast
  - **Risk** — peaks exceeding 100 %, back off
- And on the exciter side:
  - If your exciter has a modulation meter, aim for **100 % modulation on peaks** (75 kHz deviation in US-style FM, or whatever your local mandate is).
  - If the exciter has an input-level meter, match what its manual recommends — typically a peak hits around `0 dBu` / `0 dBV` at full modulation.
- Adjust **MPX Output Level until the exciter shows correct modulation**. *Don't* use MPX Output Level to chase loudness — that's Final Drive's job. Use MPX Output Level only for level-matching to hardware.

**Common mistakes:**

- Driving Final Drive hard while MPX Output Level is low → audio sounds limited but exciter is under-modulated → quiet on-air. Check the modulation meter.
- Cranking MPX Output Level for loudness → exciter over-modulates → splatter / distortion / regulatory issues. Final Drive is the loudness knob.
- Source too quiet → AGC pushing 8+ dB → noise floor lifts, breathing on quiet program. Boost upstream.
- AGC off / bypassed → multiband and final stage see widely-varying program levels → pumping on dense material. Leave AGC on.

### Final-stage presets and clipper workflow

The `Processing` -> `Final Stage` tab contains the workflow-level loudness controls (Broadcast Preset, Final Drive, Composite Deviation) and the **Final-MPX Safety Limiter** card (Enable, Threshold, Look-Ahead enable + ms — restart-required). The `Audio Limiter` tab handles the pre-encode peak limiter on its own.

- `Broadcast Preset`: loads a matched AGC + final-stage starting point
- `Final Drive`: drives the composite clipper harder or softer
- `MPX Output Level`: final output calibration, not the main loudness control

Included presets:

- `Balanced Music`: general-purpose music default
- `CHR / Dance`: hotter final stage for denser contemporary music
- `Punchy Music`: more assertive than balanced, but less hot than CHR
- `Speech / Talk`: tighter AGC with lower final drive

Clipper telemetry in `Monitoring` and `DSP Overview` shows:

- `Drive`: current configured final drive
- `GR`: live composite clipper gain reduction
- `Max`: held peak gain reduction
- `Safe`: full-MPX safety limiter gain reduction
- `Peak`: final MPX output peak

Practical tuning target:

- `GR` occasionally in the `1 to 3 dB` range is a healthy working zone
- sustained higher GR usually means `Final Drive` is too high for the source
- use `MPX Output Level` only for exciter or interface calibration

Monitoring also shows composite calibration status:

- `Pilot`: configured pilot injection
- `RDS`: configured RDS injection
- `Audio`: audio-composite peak before pilot/RDS sum
- `Margin`: estimated remaining composite headroom
- `Composite Budget`: `Safe`, `Tight`, or `Risk`

### When to leave BS.412 and the Composite Clipper off

Both stages are loudness / regulatory tools and both visibly cost stereo image and high-frequency detail when engaged. If you do not need them, leave them off — the chain still produces a fully compliant FM composite.

- `BS.412` (`Processing` -> `BS.412`): only required if you operate under EU power-limiting rules (rolling 60-second MPX power cap). Outside that regulatory context, leave `Enable BS.412` off — it actively pulls level back over long windows and dulls dynamics.
- `Composite Clipper` (`Processing` -> `Composite Clipper`): trades stereo image and HF cleanliness for raw loudness. Leave `Enable Composite Clipper` off when loudness is not the priority. If you do enable it, the per-band cancellation toggles let you choose what to protect:
  - `Cancel pilot guard`, `Cancel stereo subcarrier`, `Cancel RDS guard` — leave on (defaults). These keep the 19 kHz pilot, 38 kHz L-R subcarrier, and 57 kHz RDS regions clean of clip IM.
  - `Cancel audio band` — off by default for maximum loudness. Turn on to recover audible HF detail at the cost of some loudness when the clipper is driven hard.
  - `Experimental Multiband Composite Clipping` — off by default. It is an A/B loudness experiment for HF-heavy program material; current verifier numbers show useful peak/audio reduction, but it should stay out of presets until dense-program listening confirms the trade.

All of these are exposed in the GUI; no INI editing is required.

### Stereo image control

The `Processing` -> `Widener` tab now contains two separate image controls:

- `Mono Bass`: collapses low-frequency side energy below a configurable crossover
- `Stereo Widener`: applies restrained upper-band widening with stereo-image protection

Recommended starting point:

- `Mono Bass`: on
- `Bass Mono Freq`: `110-140 Hz`
- `Width`: around `0.50`
- `Center`: around `0.50`
- `Mix`: around `0.70-1.00`

This keeps bass more mono-compatible while leaving the upper image open enough for FM.

### PrimeBass and multiband

The current low-frequency enhancement and multiband stages are now tuned more conservatively than earlier builds.

- `PrimeBass` adds perceived bass weight by synthesising controlled harmonics of low-frequency content. The listener hears more bass without the chain having to push LF peaks higher, which saves headroom for the rest of the dynamics chain.
- `Multiband` uses linear-phase Kaiser-windowed FIR crossovers in TX mode (parallel-cumulative-LP topology, sum-to-flat at `−155 dB`), so percussive transients land time-aligned across all bands and the recombined signal only changes spectral balance when the band gains move — not when bands fall out of phase. Monitor mode keeps the IIR Linkwitz-Riley 4 cascade for low latency. Both 3-band and 5-band modes are supported. INI key `multiband_fir_enabled` toggles the FIR path (default on). Two advanced options are default-off while being evaluated: `multiband_transient_aware_attack_enabled` for peak/RMS transient handling, and `multiband_inter_band_coupling_enabled` for low-band-GR-driven upper-band threshold bias.

Recommended starting point:

- `PrimeBass`: `AC/Pop` or `Rock` preset first
- `Multiband`: `5B AC/Pop` for general music, `5B Talk` for speech, `5B CHR/EDM` for a denser contemporary result, `5B Italo` / `3B Italo` for italo / disco / dance pumping character

The current defaults are intentionally moderate and are meant to be tuned upward from a clean starting point, not downward from a hyped one.

### Now Playing script output

The RDS Radiotext section can poll an external script for now-playing metadata.

Expected script behavior:

- Exit with status `0` only when active playback metadata is available
- Write metadata to `stdout`
- Plain single-line output is accepted and treated as the display text
- Structured `key=value` lines are preferred for correct RT+ tagging

No-data behavior:

- Exit with status `1` when no song is currently playing or no usable metadata is available
- MPX Prime treats `exit 1` and empty output as `No Song Data`
- Any RT segment containing `{now_playing}`, `{display}`, `{artist}`, or `{title}` is discarded entirely when no song data is available
- This works for both slash-separated timed RT and consecutive timed markers

Supported keys:

- `display`: full on-air text, for example `The Dizzy DJ - I Venti Megamix`
- `artist`: artist field for RT+
- `title`: title field for RT+
- `now_playing`: alias for `display`

Example script output:

```text
display=The Dizzy DJ - I Venti Megamix
artist=The Dizzy DJ
title=I Venti Megamix
```

Example Radiotext / RT+ settings:

```text
Radiotext: 10s:In STEREO on RDS/10s:Now: {artist} - {title}
```

If the script reports no song data, the transmitted RT falls back cleanly to:

```text
10s:In STEREO on RDS
```

When the now-playing script is enabled, RT+ tags are derived automatically from structured script output (`artist`, `title`, `display`). There is no separate RT+ format field to maintain for this workflow.

Available Radiotext macros:

- `{now_playing}`
- `{display}`
- `{artist}`
- `{title}`
- `{date}` as local date in `YYYY-MM-DD`
- `{time}` as local time in `HH:mm`

### RDS text syntax

MPX Prime accepts the same RDS text grammar as Stereotool for PS, PTYN, Long PS, and Radiotext fields. Unsupported markers are accepted silently where practical so existing Stereotool presets load without modification.

| Marker | Meaning |
| --- | --- |
| `Ns:TEXT` | Timed segment, `N` seconds. Fractional accepted (`1.5s:`). |
| `Nt:TEXT` | Transmit-count segment. Advances after `N` full transmissions of the field. |
| `/` | Separates repeating segments. |
| `<TEXT` / `>TEXT` | Scroll left / right. **PS only** — too slow to be useful on Radiotext. Repeat the marker for more chars per tick: `<<TEXT` scrolls twice as fast. |
| `\|\|` | Word-wrap toggle. Word-wrap is always on; accepted as a no-op. |
| `\\<`  `\\>`  `\\\|`  `\\:`  `\\/`  `\\\\` | Escape the special character so it transmits literally. |
| `\R"path"` / `\r"path"` | Load file contents (uppercase / as-is). |
| `\F"path"` / `\f"path"` | Aliases for `\R` / `\r`. |
| `\w"url"` | Fetch text from a URL. MPX Prime extension, not in Stereotool. |

Example mixing timing modes and separators:

```text
1.5s:MPX Prime/3t:In STEREO on RDS/10s:Now: {artist} - {title}
```

Scrolling PS marquee (PS is 8 characters wide):

```text
<<MPX PRIME - FM BROADCAST ENCODER
```

Escape a colon so it is not parsed as a timing prefix:

```text
Visit us\: https\://example.com/10s:Alt text
```

Important defaults:

- Input HPF default: `30 Hz`
- Program lowpass default: `16.4 kHz`
- Scope auto gain default: enabled

## Monitoring and output notes

- `MPX Output Device` is the composite/baseband output device
- `Monitor Output Device (Decoded MPX Simulation)` is used when monitor output is enabled
- The orange microphone indicator in the macOS menu bar is the system privacy indicator and appears when MPX Prime is actively using audio input
- `Mono Mode` now transmits true mono composite and suppresses pilot, stereo subcarrier, and RDS while enabled

## Offline verification

MPX Prime includes an offline MPX verification mode that renders deterministic test scenarios without opening audio devices.

Example:

```bash
./macOS/.build/debug/MPXPrime --verify --seconds 5
```

For key multiband-preset validation:

```bash
./macOS/.build/debug/MPXPrime --verify-presets --seconds 5
```

The report includes:

- MPX peak in dBFS
- estimated deviation in kHz
- composite clipper gain reduction
- safety limiter gain reduction
- audio-composite peak before pilot/RDS sum
- pilot and RDS injection percentages
- composite budget margin
- AGC reduction
- decoded-audio quality metrics per scenario:
  - input/output correlation
  - input/output side-to-mid ratio
  - RMS drift

Current deterministic scenarios include:

- `mono_1khz`
- `stereo_diff_400hz`
- `program_mix`
- `bright_dense`
- `vocal_sibilant`
- `hf_edge_12k`
- `transient_push`
- `hard_panned_hf`
- `wide_bass`

`--verify-presets` runs a shorter focused sweep across the main 5-band presets:

- `5B AC/Pop`
- `5B CHR/EDM`
- `5B Rock`
- `5B Talk`
- `5B News`
- `5B Urban`
- `5B Dance`

Current post-build preset sweep status:

- `5B AC/Pop`: `OK`
- `5B CHR/EDM`: `OK`
- `5B Rock`: `OK`
- `5B Talk`: `OK`
- `5B News`: `OK`
- `5B Urban`: `OK`
- `5B Dance`: `OK`

Two opt-in-feature A/B modes (0.28+) compare default-chain vs feature-enabled across stress scenarios:

```bash
./macOS/.build/debug/MPXPrime --verify-composite-multiband --seconds 2
./macOS/.build/debug/MPXPrime --verify-multiband-coupling --seconds 2
```

`--verify-composite-multiband` toggles `mpx_multiband_clipper_enabled` off/on across 5 dense/HF scenarios and reports peak / audio-peak / margin / overshoot / correlation / side / >60 kHz deltas. Current tuning shows ~1.4-1.6 dB peak reduction on HF-heavy program with zero post-injection overshoot.

`--verify-multiband-coupling` forces multiband on, disables AGC for isolation, and toggles `multiband_inter_band_coupling_enabled` off/on across 5 program scenarios (bass-heavy, kick/vocal, dance, wide-bass, speech-bed), reporting per-band Low/Mid/High deltas + correlation / side-to-mid / peak / overshoot / render-cost ratio.

Current verification is strongest for composite safety, budget behavior, receiver-model stereo separation, and composite-multiband + inter-band-coupling A/B measurements. It is not yet a full listening-quality oracle for multiband crossover tone, stereo-image feel, or PrimeBass character, so final tuning still requires real program listening.

Exit status:

- `0` means no obvious composite-budget or safety-limiter issue was found
- `1` means the configuration is close to the limit and should be reviewed
- `2` means at least one verification warning was triggered

## Processing bypass

The `Bypass` control does not create a true wire bypass. It disables the creative processing blocks while keeping essential FM encode stages active.

Always active:

- Input gain
- Program lowpass
- Pre-emphasis
- MPX encoding
- Final drive, deviation scaling, and limiting
- Output gain

Disabled by bypass:

- Wideband AGC
- HF trim
- PrimeBass
- Mono bass
- Multiband processing
- Stereo widener

## Release build

Build a release app bundle / DMG:

```bash
./build-release.sh 0.29
```

Artifacts are written to `macOS/dist/`.

## References

- Standards PDFs and notes live in `documents/`
- Project-specific workflow guidance lives in `AGENTS.md`

## Appendix: RDS PI and ECC Country Table

RDS country identity is derived from:

- the top hex digit of the `PI` code, also called the country identifier or PI symbol
- the `ECC` value transmitted in group `1A`

Together they identify a country or area. There is no special "pirate" country code.

This appendix is a practical reference table for the published RDS country and area allocations. It is grouped the same way the published tables are grouped, so some countries and areas appear in more than one regional list.

### Europe / EBU area

| Country or area | ISO | PI symbol | ECC |
| --- | --- | --- | --- |
| Albania | ALB | 9 | E0 |
| Algeria | ALG | 2 | E0 |
| Andorra | AND | 3 | E0 |
| Austria | AUT | A | E0 |
| Azores [Portugal] | AZR | 8 | E0 |
| Belgium | BEL | 6 | E0 |
| Belarus (ex-USSR) | BLR | F | E3 |
| Bosnia-Herzegovina (ex-Yugoslavia) | BIH | F | E4 |
| Bulgaria | BUL | 8 | E1 |
| Canaries [Spain] | CNR | E | E0 |
| Croatia (ex-Yugoslavia) | HRV | C | E3 |
| Cyprus | CYP | 2 | E1 |
| Czech Republic | CZE | 2 | E2 |
| Denmark | DNK | 9 | E1 |
| Egypt | EG | F | E0 |
| Estonia (ex-USSR) | EE | 2 | E4 |
| Faroe Islands [Denmark] | DK | 9 | E1 |
| Finland | FI | 6 | E1 |
| France | FR | F | E1 |
| Germany | DE | D or 1 | E0 |
| Gibraltar [United Kingdom] | GI | A | E1 |
| Greece | GR | 1 | E1 |
| Hungary | HU | B | E0 |
| Iceland | IS | A | E2 |
| Iraq | IQ | B | E1 |
| Ireland | IE | 2 | E3 |
| Israel | IL | 4 | E0 |
| Italy | IT | 5 | E0 |
| Jordan | JO | 5 | E1 |
| Latvia (ex-USSR) | LV | 9 | E3 |
| Lebanon | LB | A | E3 |
| Libya | LY | D | E1 |
| Liechtenstein | LI | 9 | E2 |
| Lithuania (ex-USSR) | LT | C | E2 |
| Luxembourg | LU | 7 | E1 |
| North Macedonia (ex-Yugoslavia) | MK | 4 | E3 |
| Madeira [Portugal] | PT | 8 | E2 |
| Malta | MT | C | E0 |
| Morocco | MA | 1 | E2 |
| Moldova (ex-USSR) | MD | 1 | E4 |
| Monaco | MC | B | E2 |
| Netherlands | NL | 8 | E3 |
| Norway | NO | F | E2 |
| Palestine | PS | 8 | E0 |
| Poland | PL | 3 | E2 |
| Portugal | PT | 8 | E4 |
| Romania | RO | E | E1 |
| Russian Federation (ex-USSR) | RU | 7 | E0 |
| San Marino | SM | 3 | E1 |
| Slovakia | SK | 5 | E2 |
| Slovenia (ex-Yugoslavia) | SI | 9 | E4 |
| Spain | ES | E | E2 |
| Sweden | SE | E | E3 |
| Switzerland | CH | 4 | E1 |
| Syrian Arab Republic | SY | 6 | E2 |
| Tunisia | TN | 7 | E2 |
| Turkey | TR | 3 | E3 |
| Ukraine (ex-USSR) | UA | 6 | E4 |
| United Kingdom | GB | C | E1 |
| Vatican | VA | 4 | E2 |
| Yugoslavia | YU | 6 | E3 |

### African broadcasting area

| Country or area | ISO | PI symbol | ECC |
| --- | --- | --- | --- |
| Ascension Island | - | A | D1 |
| Cabinda | - | 4 | D3 |
| Angola | AO | 6 | D0 |
| Algeria | DZ | 2 | E0 |
| Burundi | BI | 9 | D1 |
| Benin | BJ | E | D0 |
| Burkina Faso | BF | B | D0 |
| Botswana | BW | B | D1 |
| Cameroon | CM | 1 | D0 |
| Canary Islands [Spain] | ES | E | E0 |
| Central African Republic | CF | 2 | D0 |
| Chad | TD | 9 | D2 |
| Congo | CG | C | D0 |
| Comoros | KM | C | D1 |
| Cape Verde | CV | 6 | D1 |
| Cote d'Ivoire | CI | C | D2 |
| Djibouti | DJ | 3 | D0 |
| Egypt | EG | F | E0 |
| Ethiopia | ET | E | D1 |
| Gabon | GA | 8 | D0 |
| Ghana | GH | 3 | D1 |
| Gambia | GM | 8 | D1 |
| Guinea-Bissau | GW | A | D2 |
| Equatorial Guinea | GQ | 7 | D0 |
| Republic of Guinea | GN | 9 | D0 |
| Kenya | KE | 6 | D2 |
| Liberia | LR | 2 | D1 |
| Libya | LY | D | E1 |
| Lesotho | LS | 6 | D3 |
| Mauritius | MU | A | D3 |
| Madagascar | MG | 4 | D0 |
| Mali | ML | 5 | D0 |
| Mozambique | MZ | 3 | D2 |
| Morocco | MA | 1 | E2 |
| Mauritania | MR | 4 | D1 |
| Malawi | MW | F | D0 |
| Niger | NE | 8 | D2 |
| Nigeria | NG | F | D1 |
| Namibia | NA | 1 | D1 |
| Rwanda | RW | 5 | D3 |
| Sao Tome and Principe | ST | 5 | D1 |
| Seychelles | SC | 8 | D3 |
| Senegal | SN | 7 | D1 |
| Sierra Leone | SL | 1 | D2 |
| Somalia | SO | 7 | D2 |
| South Africa | ZA | A | D0 |
| Sudan | SD | C | D3 |
| Swaziland | SZ | 5 | D2 |
| Togo | TG | D | D0 |
| Tunisia | TN | 7 | E2 |
| Tanzania | TZ | D | D1 |
| Uganda | UG | 4 | D2 |
| Western Sahara | EH | 3 | D3 |
| Zaire | ZR | B | D2 |
| Zambia | ZM | E | D2 |
| Zanzibar | - | D | D2 |
| Zimbabwe | ZW | 2 | D2 |

### Former Soviet Union allocations

| Country or area | ISO | PI symbol | ECC |
| --- | --- | --- | --- |
| Armenia | AM | A | E4 |
| Azerbaijan | AZ | B | E3 |
| Belarus | BY | F | E3 |
| Estonia | EE | 2 | E4 |
| Georgia | GE | C | E4 |
| Kazakhstan | KZ | D | E3 |
| Kyrgyzstan | KG | 3 | E4 |
| Latvia | LV | 9 | E3 |
| Lithuania | LT | C | E2 |
| Moldova | MD | 1 | E4 |
| Russian Federation | RU | 7 | E0 |
| Tajikistan | TJ | 5 | E3 |
| Turkmenistan | TM | E | E4 |
| Ukraine | UA | 6 | E4 |
| Uzbekistan | UZ | B | E4 |

### ITU Region 2

| Country or area | ISO | PI symbol | ECC |
| --- | --- | --- | --- |
| Anguilla | AI | 1 | A2 |
| Antigua and Barbuda | AG | 2 | A2 |
| Argentina | AR | A | A2 |
| Aruba | AW | 3 | A4 |
| Bahamas | BS | F | A2 |
| Barbados | BB | 5 | A2 |
| Belize | BZ | 6 | A2 |
| Bermuda | BM | C | A2 |
| Bolivia | BO | 1 | A3 |
| Brazil | BR | B | A2 |
| Canada | CA | C | A1 |
| Cayman Islands | KY | 7 | A2 |
| Chile | CL | C | A3 |
| Colombia | CO | 2 | A3 |
| Costa Rica | CR | 8 | A2 |
| Cuba | CU | 9 | A2 |
| Dominica | DM | A | A3 |
| Dominican Republic | DO | B | A3 |
| Ecuador | EC | 3 | A2 |
| El Salvador | SV | C | A4 |
| Falkland Islands | FK | 4 | A2 |
| Greenland | GL | F | A1 |
| Grenada | GD | D | A3 |
| Guadeloupe | GP | E | A2 |
| Guatemala | GT | 1 | A4 |
| Guiana | GF | 5 | A3 |
| Guyana | GY | F | A3 |
| Haiti | HT | D | A4 |
| Honduras | HN | 2 | A4 |
| Jamaica | JM | 3 | A3 |
| Martinique | MQ | 4 | A3 |
| Mexico | MX | F | A4 |
| Montserrat | MS | 5 | A4 |
| Netherlands Antilles | AN | D | A2 |
| Nicaragua | NI | 7 | A3 |
| Panama | PA | 9 | A3 |
| Paraguay | PY | 6 | A3 |
| Peru | PE | 7 | A4 |
| Puerto Rico | PR | 8 | A3 |
| Saint Kitts | KN | A | A4 |
| Saint Lucia | LC | B | A4 |
| St Pierre and Miquelon | PM | F | A6 |
| Saint Vincent | VC | C | A5 |
| Suriname | SR | 8 | A4 |
| Trinidad and Tobago | TT | 6 | A4 |
| Turks and Caicos Islands | TC | E | A3 |
| United States of America | US | 1..9, A, B, D, E | A0 |
| Uruguay | UY | 9 | A4 |
| Venezuela | VE | E | A4 |
| Virgin Islands [British] | VG | F | A5 |
| Virgin Islands [USA] | VI | F | A5 |

### ITU Region 3

| Country or area | ISO | PI symbol | ECC |
| --- | --- | --- | --- |
| Afghanistan | AF | A | F0 |
| Saudi Arabia | SA | 9 | F0 |
| Australia - Australian Capital Territory | - | 1 | F0 |
| Australia - New South Wales | - | 2 | F0 |
| Australia - Victoria | - | 3 | F0 |
| Australia - Queensland | - | 4 | F0 |
| Australia - South Australia | - | 5 | F0 |
| Australia - Western Australia | - | 6 | F0 |
| Australia - Tasmania | - | 7 | F0 |
| Australia - Northern Territory | - | 8 | F0 |
| Bangladesh | BD | 3 | F1 |
| Bahrain | BH | E | F0 |
| Myanmar [Burma] | MM | B | F0 |
| Brunei Darussalam | BN | B | F1 |
| Bhutan | BT | 2 | F1 |
| Cambodia | KH | 3 | F2 |
| China | CN | C | F0 |
| Sri Lanka | LK | C | F1 |
| Fiji | FJ | 5 | F1 |
| Hong Kong | HK | F | F1 |
| India | IN | 5 | F2 |
| Indonesia | ID | C | F2 |
| Iran | IR | 8 | F0 |
| Iraq | IQ | B | E1 |
| Japan | JP | 9 | F2 |
| Kiribati | KI | 1 | F1 |
| Korea [South] | KR | E | F1 |
| Korea [North] | KP | D | F0 |
| Kuwait | KW | 1 | F2 |
| Laos | LA | 1 | F3 |
| Macau | MO | 6 | F2 |
| Malaysia | MY | F | F0 |
| Maldives | MV | B | F2 |
| Micronesia | FM | E | F3 |
| Mongolia | MN | F | F3 |
| Nepal | NP | E | F2 |
| Nauru | NR | 7 | F1 |
| New Zealand | NZ | 9 | F1 |
| Oman | OM | 6 | F1 |
| Pakistan | PK | 4 | F1 |
| Philippines | PH | 8 | F2 |
| Papua New Guinea | PG | 9 | F3 |
| Qatar | QA | 2 | F2 |
| Solomon Islands | SB | A | F1 |
| Western Samoa | WS | 4 | F2 |
| Singapore | SG | A | F2 |
| Taiwan | TW | D | F1 |
| Thailand | TH | 2 | F3 |
| Tonga | TO | 3 | F3 |
| UAE | AE | D | F2 |
| Vietnam | VN | 7 | F2 |
| Vanuatu | VU | F | F2 |
| Yemen | YE | B | F3 |

### Notes

- The `PI symbol` is the top hex digit of the four-digit `PI` code.
- The remaining three hex digits identify the programme service within the country or area allocation.
- The United States uses `RBDS` PI allocation rules, so the country row above is only the country-area level identifier.
- Australia commonly uses a state-based `PI` symbol scheme in practice, which is why the published list is shown by state and territory rather than one national symbol.

## Acknowledgements

The block-level RDS bit encoder in `BasicRDSCoder` — CRC (`0x5B9`), offset words, and the four-block group assembly shared by groups 0/2/3A/4A/10A/11A/15A — was initially ported from the Python `RDSHelper` in [ryanginn/rds-master](https://github.com/ryanginn/rds-master). Everything around it is MPX Prime's own work: the 1187.5 bit/s biphase + Gaussian shaping FIR, the pilot-locked 57 kHz subcarrier generation, the audio-thread real-time pipeline (pre-allocated bit buffer, atomic CT cache, monotonic-clock timing), the `RDSRuntimeConfig` live-apply path, AF Method B, RT+ ODA (AID 0x4BD7), Group 4A clock-time with MJD + TZ, Group 10A PTYN, Group 15A Long PS, Group 1A ECC/LIC, the Stereotool-compatible text grammar, and the full FM composite chain that the encoder feeds into.

## License

GPL-3.0. See `LICENSE`.
