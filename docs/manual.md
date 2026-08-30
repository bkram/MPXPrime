# MPX Prime Studio — User Manual

Operation, configuration, and reference for running MPX Prime Studio (the encoder). For a project overview see the [README](../README.md); to build from source see [BUILDING.md](BUILDING.md); for the DSP chain internals see [ARCHITECTURE.md](ARCHITECTURE.md).

## Platforms

The encoder runs on two platforms with the **same DSP**; only the front end and audio backend differ:

- **macOS** — the full **GUI application** (`MPX Prime Studio.app`), Core Audio, plus a headless `--nogui` mode. The companion **MPX Prime Meter** analyzer ships in the same DMG (macOS only — see its [manual](manual-meter.md)).
- **Linux** — the **encoder only, headless** (`--nogui`, ALSA output, no GUI). Its interface is the built-in [web dashboard / REST API](#remote-control-rest-api--web-dashboard). Installed from the Debian/Ubuntu package as the `mpxprime` systemd service (config at `/var/lib/mpxprime/MPXPrime.ini`). **There is no GUI and no Meter on Linux.** Setup: [BUILDING.md → Linux (CLI-only)](BUILDING.md#linux-cli-only).

Most of this manual (controls, RDS, config keys, presets) applies to both; where a control is GUI-only, Linux operators reach the equivalent through the web dashboard, which mirrors the GUI layout. Platform-specific differences (device names, config path) are flagged inline.

## Usage

**macOS.** Launch MPX Prime Studio from `/Applications` (or wherever you copied it). On first run,
grant input access when macOS prompts — this is required to capture audio. Then
pick your input and MPX output devices in the app and start the engine.

Command-line flags (run the binary inside the app bundle):

```bash
"/Applications/MPX Prime Studio.app/Contents/MacOS/MPXPrime" --nogui       # headless, no UI
"/Applications/MPX Prime Studio.app/Contents/MacOS/MPXPrime" --seconds 10  # run for a fixed time then exit
"/Applications/MPX Prime Studio.app/Contents/MacOS/MPXPrime" --config "/path/to/MPX Prime Studio.ini"
"/Applications/MPX Prime Studio.app/Contents/MacOS/MPXPrime" --web         # headless + web dashboard
```

**Linux.** The package installs `/usr/bin/mpxprime` and runs it as a service:
`sudo systemctl enable --now mpxprime`, then open `http://<host>:8737/` for the
dashboard (see [Remote control](#remote-control-rest-api--web-dashboard) for
the [CONTROL] settings and the API key needed for non-local access). To run it
by hand: `mpxprime --nogui --config /var/lib/mpxprime/MPXPrime.ini`, or
`mpxprime --web` for a headless run that also serves the dashboard. Devices are
ALSA PCM names, not Core Audio devices.

To build, run, verify, test, or package from source, see
[docs/BUILDING.md](docs/BUILDING.md).

## Quick start (first-time use)

This is the minimum to hear MPX Prime Studio processing your audio and feeding a transmitter / SDR / loopback. Defaults are tuned to sound good out of the box — the chain ships processing-on with AGC, multiband, bass clipping, and the composite clipper engaged.

**1. Plug audio in and out.** MPX Prime Studio reads from a Core Audio input device and writes the composite (MPX) signal to a Core Audio output device. Typical setups:

- Soundcard input from your studio mixer / streaming source → soundcard output into an FM exciter that accepts MPX baseband.
- BlackHole 2ch (virtual loopback) input from a music player or DAW → soundcard output into an SDR transmitter or RF generator.
- Test tone source (built-in) → output to verify metering and routing without external audio.

192 kHz output is **required for the full composite with RDS.** RDS sits at 57 kHz, which exceeds the 48 kHz Nyquist of 96 kHz sample rates — the RDS subcarrier cannot be represented at 96 kHz or below. 96 kHz is just enough to carry the FM stereo composite alone (M + 19 kHz pilot + 38 kHz DSB-SC stereo subcarrier) provided the audio bandwidth is limited so the upper L−R sideband doesn't push past 48 kHz; pilot-locked stereo decoding works, but disable RDS at this rate. Below 96 kHz the stereo subcarrier itself doesn't fit. 192 kHz is the recommended rate for everything because it gives Nyquist headroom for the post-clipper pilot/RDS injection plus the oversampled peak-control stages the chain runs above the host rate.

> **External sound card required for RDS.** Apple's built-in audio output on Mac laptops and most desktops tops out at **96 kHz**, which cannot carry RDS — the 57 kHz subcarrier exceeds 48 kHz Nyquist. For any FM-with-RDS chain you need a USB / Thunderbolt audio interface that natively runs at **192 kHz**. Most pro and prosumer interfaces (RME, MOTU, Focusrite Scarlett 3rd-gen+, Apogee, etc.) support 192 kHz on at least the analog or AES outputs — check the spec sheet before ordering. The internal Mac speakers / headphone jack are fine for *listening to a test tone* through MPX Prime Studio, but they cannot be the production output if RDS is in play.

### Audio MIDI Setup — required device configuration

macOS configures Core Audio device parameters via **Audio MIDI Setup** (`/Applications/Utilities/Audio MIDI Setup.app`). MPX Prime Studio tells the engine what rate it wants, but the device-side format and volume are owned by the OS — wrong values there silently corrupt the composite before it leaves the Mac.

**Output device** (feeding your exciter / SDR / RF generator):

1. **Format / sample rate**: set to **192 000 Hz**. Match what the engine is configured to (`sample_rate = 192000` in INI). If the device runs at a different rate Core Audio inserts a sample-rate converter that cannot represent the upper composite band cleanly. **Required for RDS** — the 57 kHz RDS subcarrier needs at least ~119 kHz Nyquist; 176.4 kHz is the lowest device rate that carries it correctly, 192 kHz is the canonical default. On start MPX Prime Studio now **sets the output device to the configured rate itself** (and restores the device's prior rate on stop); if the device can't run that rate it surfaces a routing note telling you to set it in Audio MIDI Setup, rather than letting Core Audio quietly resample.
2. **Bit depth**: **24-bit integer or 32-bit float**. Either is fine; 32-bit float is the AVAudioEngine native format. 16-bit also *works* for the composite (96 dB SNR is well above any FM receiver's noise floor and you cannot hear the difference at the listener), but 24/32-bit is best practice — no extra dither/truncation step at the chain output, and headroom for downstream tools that further process the composite (resamplers, SDR DSPs).
3. **Volume / output gain**: **100 % (0 dB) on every channel**. This is the critical one. The macOS volume slider is post-mix — it scales the engine's already-finalised composite. If output volume is at, say, 75 %, the FM exciter receives a signal at 0.75× amplitude and your modulation undershoots by ~2.5 dB; the loudness target the chain just enforced is silently wrong. Audio MIDI Setup → device → "Master Stream" or per-channel volume sliders. Lock these at unity for any broadcast use.

**Device selection is remembered by UID and name.** Each selected input / output / monitor device is stored by its Core Audio UID *and* its name (`input_device_uid` / `input_device_name`, etc.). At launch the device is matched by UID first, then by name — so moving a USB interface to a different port (which can change its UID) still re-finds the same device. If a remembered device is simply unplugged, MPX Prime Studio **keeps** your selection (and shows a status note) instead of silently switching to whatever device is first in the list; reconnect it, or pick another.

**Input device** (your audio source — interface, BlackHole loopback, or built-in audio):

1. **Format / sample rate**: **48 000 Hz, 24-bit** is the recommended sweet spot. The reason is the dual-rate audio chain (default-on since 0.30) — the entire audio domain (multiband, AGC, EQ, image protection, pre-emphasis, pre-encode limiter) runs at 48 kHz internally, then upsamples to the MPX rate at the stereo encoder boundary. Setting the input device to 48 kHz means the source audio passes into the audio domain without any Core Audio upsampling on the way in (no information gain from higher input rates anyway — audio source material has zero useful content above ~20 kHz). 44.1 kHz also works fine; Core Audio's input-side SRC handles the small upsample to 48 kHz cleanly.
2. **Bit depth**: **24-bit** is recommended. 16-bit is fine for the audio itself, but the chain runs in 32-bit float internally through many stages and 24-bit input keeps the noise margin below the audible threshold even under hot processing.
3. **Volume**: per-device — set whatever produces a sensible input level on the `IN L/R` meter at the top of the app. Aim for peaks around -12 to -6 dBFS on the input meter so the wideband AGC has something to work with.

If your output device is BlackHole or a virtual loopback, the same rules apply — check both the loopback device's format and the receiving app's input format. Mismatch there is the #1 cause of "the chain looks right but the receiver sounds wrong" reports.

**2. Set your region.** Pre-emphasis differs by region:

- **USA / Canada / South Korea**: 75 µs
- **Everywhere else (EU, ROW)**: 50 µs (current default)

Open `Processing` → `Core` and change `Pre-emphasis (μs)` to `75` if you are in a 75 µs region. Wrong pre-emphasis will sound either dull (50 into 75 deemph) or shrill / over-modulated (75 into 50 deemph). EU operators required to comply with ITU-R BS.412 should also enable `Processing` → `BS.412`. Every setting referenced in this guide is also reachable from the GUI; the INI is written automatically and is mainly there for inspection or out-of-band edits.

**3. Launch and Start.** Open MPX Prime Studio, pick your input and output devices in `Settings`, then press `Start` (⌘Return) on the toolbar. The status bar at the top of the window shows live IN L/R, MPX peak, deviation in kHz, modulation as a percentage of the configured deviation target (MOD), gain reduction, safety-limiter GR, composite budget, and pilot/RDS injection — if those move with your audio, the chain is processing.

**4. Calibrate composite output level.** On `Monitoring`, watch the `Composite Budget` chip:

- **Safe**: nominal modulation, headroom available
- **Tight**: near 100% modulation, fine for normal broadcast
- **Risk**: peaks exceeding 100% — back off `MPX Output Level` on the `Core` tab

`Final Drive` (on the `Final Stage` tab) controls perceived loudness; `MPX Output Level` (on the `Core` tab) calibrates the final voltage to your exciter / SDR. Use `Final Drive` for loudness and `MPX Output Level` only for hardware calibration.

**5. Verify on a receiver.** Tune a real FM radio or RTL-SDR to your transmitter's frequency. You should hear stereo audio with a steady stereo-pilot indicator, see RDS PS and Radiotext on the radio's display (if your radio supports RDS), and the audio should sound louder and more present than the same source through `mpxgen` / PiFmRds.

If you cannot hear anything, check `Settings` → output device routing, that the engine is started, and that `Processing` → `Core` → `Bypass Processing` is **off** (the default).

### Block (buffer) size

`Settings` -> `Interfaces` -> `Block Size` (`blocksize` in `[INTERFACES]`, 256..8192 frames). The DSP itself does not depend on it -- the composite rendered in 64-, 480-, 1024- or 8192-frame blocks is bit-identical to 512 (pinned by a test) -- so the choice is only about latency versus dropout safety. Round-trip I/O latency is two blocks: at 192 kHz, 256 = 2.7 ms, 512 = 5.3 ms, 1024 = 10.7 ms, 2048 = 21 ms, 4096 = 43 ms, 8192 = 85 ms. Measure your machine with `--bench-blocks` on a release build: it reports the worst single block's render time as a fraction of that block's duration (100% = a dropout) -- keep at least 2x margin. On an Apple M1 Pro with the full chain the worst block is 17% at 512 and 23% at 256, so **512 is the recommended default** (256 works on Apple Silicon if you need the latency; 64 is marginal at 46%). Intel and small Linux boxes (the fanless Celeron runs the chain near 92% of real time) want 1024-2048. Two hardware caveats: CoreAudio devices clamp the buffer to their own range and the engine logs "clamped HAL buffer" when that happens (the built-in output allows 15..4096, so 8192 is never honoured there), and many USB interfaces glitch below 256 regardless of CPU headroom.

## Configuration

> **Linux (experimental CLI port):** the encoder also runs headless on Linux
> (`--nogui`; no GUI, no Meter). The same INI works, with two differences:
> the default config path is `~/.local/share/MPX Prime Studio/MPX Prime
> Studio.ini`, and the `input_device_uid` / `output_device_uid` keys hold
> ALSA PCM names (`default`, `hw:0,0`, `plughw:...`) instead of CoreAudio
> UIDs. See docs/BUILDING.md "Linux (CLI-only)" for setup and device notes.
>
> **A missing audio device does not crash the encoder.** If the configured
> ALSA device can't be opened at start, the control server still comes up;
> open the dashboard, pick a present device on the **Interfaces** page, and
> press **Start**. Note that USB cards can change their `hw:CARD=<name>`
> across reboots when two audio cards are present (ALSA assigns Device /
> Device_1 by probe order) -- if the service comes up stopped after a
> reboot, reselect the device in the dashboard.

Default config location:

```text
~/Library/Application Support/MPX Prime Studio/MPX Prime Studio.ini
```

Relevant config sections:

- `INTERFACES`: input/output/monitor device UIDs, source mode, monitor enable, block size
- `MPX`: processing, levels, stereo coding, limiter behavior
- `RDS`: program service, radiotext, flags, carrier settings

### Format Profiles (Station Format selector)

For one-click "make this sound right", MPX Prime Studio ships four complete Format Profiles plus a `Custom` sentinel, on the **Processing → Format Profile** tab. Since the 2026-08 rework a profile owns the FULL chain state — not just tonal color: every profile enables the AGC, the pre-encode Audio Limiter, the composite clipper (with 2 ms look-ahead) and the final safety limiter, then sets the format-appropriate multiband / PrimeBass / widener / drive on top (every profile also enables the HF Limiter; Music - Loud adds the Bass Clipper). Picking a profile can never leave the always-on safety soft-clips as the de-facto peak controller (the failure mode of the old 8-profile set). Per-stage knobs stay editable afterwards; pick `Custom` to flag "my settings are bespoke".

**Upgrading from a pre-0.45 config.** An INI that still carries one of the old profile ids (`chr_top40`, `pop_ac`, `community_radio`, `rock`, `edm_dance`, `urban_hiphop`, `jazz_classical`, `news_talk`) is **reset on load**: its processing (`[MPX]`) is rebuilt from the nearest new Format Profile (`chr_top40` / `rock` / `edm_dance` / `urban_hiphop` -> Music - Loud, `community_radio` / `pop_ac` -> Music - Clean, `news_talk` -> Speech, `jazz_classical` -> Classical), while **RDS, interfaces (devices, sample rate, block size), the control server and the hardware calibration keys (pilot level, deviation, MPX output level, output gain, pre-emphasis, mono mode, test tone) are kept exactly as they were**. The reset config is saved back to disk and both apps say so at startup (status bar in Studio, a line on stderr headless). Reason: those configs typically had the Audio Limiter and Composite Clipper off with the safety soft clips doing all the clipping -- the hi-hat / cymbal distortion field finding -- and carrying that forward under a new label would keep the station distorting. If a current-profile config still has both peak controllers off, the apps warn (but do not reset); re-apply a Format Profile or enable the Composite Clipper.

| Profile | Character | AGC target | Drive | Extras |
|---|---|---|---|---|
| **Music — Clean** (default) | Transparent leveling, honest peaks, low clipper work | -16 dB | +4 dB | — |
| **Music — Loud** | Competitive loudness into the clipper | -15 dB | +8 dB | HF + bass clippers, PrimeBass, wide image |
| **Speech / Talk** | Voice-optimized | -16 dB | +4.5 dB | Phase rotator on |
| **Classical / Wide Dynamics** | Dynamic-preserving | -18 dB | +3 dB | Light multiband, gentle limiter |

Pick once, tune as needed. The selected profile is stored as `format_profile_id`; switching profiles overwrites the per-stage settings to the new profile (except `custom`, a no-op label). Assume a nominal input level around **-12 dBFS** (pro line-up convention) — the AGC absorbs source variation from there; 0 dBFS masters work but arrive with no headroom of their own.

### Preset slots (snapshots)

Eight operator preset slots store complete configurations -- every INI
setting, not just one stage -- so you can capture a tuned state and A/B
whole setups. In the GUI they live under **Presets** in the sidebar; since
0.44 the web dashboard's Presets page exposes the same eight slots (they
are shared storage, so a slot saved in the GUI loads from the dashboard
and vice versa). Per slot: a name, save (capture the current config),
load (applies the whole snapshot as one change, with live-apply where
possible and a restart flag where not), rename, and clear. Slots can be
exported as INI text -- the export is a complete config file you can pass
to `--config` -- and an INI file can be imported into an empty slot. The
slot list marks which snapshot was loaded last and whether the config has
been edited since -- the edited marker is an exact comparison against the
loaded preset, and a load reports honestly what it did: "no changes" when
the preset matches the live config, "applied live" when only live-apply
settings differed, and a restart prompt only when a restart-class setting
actually changed.

### Recommended DSP enablement (current default starting point)

For typical FM broadcast use (clean / community / LPFM), the recommended set of processing stages to **enable** is:

- **Phase Rotator** — voice waveform symmetrization (f ≈ 200 Hz)
- **Wideband AGC** — long-term level riding (target ≈ -14 dBLU, range ±10 dB, K-weighted, program-dependent release)
- **Parametric EQ** — 4-band tonal shaping (shelf + 2 peaks + shelf)
- **Multiband Compressor** — 3-band LR4 (or 5-band FIR on TX path); the `5_jazz` preset is a balanced starting point for mixed music + speech
- **Downward Expander** — gates noise floor (threshold ≈ -45 dB, ratio 2.0:1)
- **MB Limiter** — per-band peak control (threshold ≈ -3 dB, atk 0.5 ms, rel 50 ms)
- **DC Clipper** — distortion-cancelled audio-band clipping with pilot/RDS protection
- **HF Limiter** — pre-emphasis-aware, gain-riding HF control (`Processing` -> `HF Limiter / Clipper`; `hf_limiter_enabled`, `hf_limiter_threshold_db` -2 dB, `hf_limiter_attack_ms` 1.5, `hf_limiter_release_ms` 20, `hf_limiter_max_reduction_db` 12). On by default in every Format Profile (0.45). It rides only the pre-emphasis *boost*: a cymbal or hi-hat that overshoots after pre-emphasis briefly loses part of its boost instead of being clipped or dragging the whole mix down in the Audio Limiter, and it can never cut HF below the flat (un-emphasised) program level. Bass-driven peaks with little HF boost are ignored, so a kick cannot flutter the highs. The receiver's fixed de-emphasis turns the action into a brief, bounded HF dip -- the trade every broadcast HF limiter makes (Optimod topology). Threshold: set at or a little below the Audio Limiter threshold. All controls live-apply. Measured with `--verify-hf-transients`: on Music - Loud it keeps the decoded hi-hat SINAD at 18 dB where the HF clipper gave 12 dB. Note that a separate, fixed 2 dB "encoder HF guard" ahead of the encoder lowpass stays in the chain: measurements showed it protects receiver-side HF stereo separation (composite-clipper IM) at levels where this limiter does not engage.
- **Audio Limiter** — pre-encode L/R true-peak limiter with default-on Phase 1 + Phase 2 look-ahead (Dolby `US 5,579,404`, HF-subband-aware) — see 0.30 CHANGELOG
- **Composite Clipper** — 16x oversampled differential composite clipper (threshold -1.0 dB, ceiling -0.3 dB, drive 6 dB). Oversampling factor is configurable (`mpx_clipper_oversampling`, default 16): 8 for older hardware that needs the CPU back, 32 for Omnia.9-class spec-sheet parity at roughly double this stage's CPU cost. See the comment block in the sample `MPXPrime.ini` for when each value makes sense.

Recommended **off** by default (enable only when needed):

- **Stereo Widener** — leave off unless the source program needs subtle width enhancement; aggressive widening risks mono-compatibility on FM (see "Stereo image control" below)
- **PrimeBass** — bass-enhancement harmonics; useful for thin source material, but adds harmonic content that competes with the audio composite headroom. Enable per-format.
- **Bass Clipper** — engage only when LF transients are pushing the chain past the downstream limiters; if PrimeBass is off, usually unnecessary.
- **HF Clipper** — pre-emphasis-aware HF *clipper* (same tab; `hf_clipper_*`). Off by default and no longer used by any profile: it is a waveshaper on the pre-emphasised high band, so it distorts the cymbals and hi-hats it controls (the 2026-08 field finding). Keep it as a last resort for maximum HF density on dense EDM after the HF Limiter is already on; leave off for talk / classical. Controls live-apply.
- **BS.412 MPX Power Limiter** — required only for regulatory compliance in DE/AT/CH/SE/CZ/SI. NL, US, UK, FR, ES, IT etc. do not enforce BS.412; leaving it off recovers loudness headroom. See "When to leave BS.412 and the Composite Clipper off" below.
- **Advanced Dynamics** — experimental single-stage leveler that REPLACES the AGC and Multiband stages while enabled (`advanced_dynamics_enabled`; `Processing` -> `Adv Dyn`). See "Advanced Dynamics" below. Leave off until you have A/B'd it against your tuned AGC+Multiband on your own program material.
- **SSB Stereo Encoder** — experimental SSB-leaning stereo encoder (`mpx_ssb_stereo_enabled` + `mpx_ssb_stereo_amount`, the dedicated `Stereo Coder` tab/page in both UIs, between Audio Limiter and Composite Clipper -- chain position of the stereo encoder itself). Leans the 38 kHz L-R subcarrier toward single-sideband, opportunistically keeping whichever sideband currently peaks lower. Decode-compatible (coherent separation measured 81+ dB with it on) and mono-transparent, but the loudness benefit is not yet demonstrated on synthetic program — treat it as a listening experiment, verify with `--verify-ssb-stereo` and a real receiver, and leave it off otherwise.

This is a sensible amateur-grade starting point. Tune from there based on listening A/B against your typical program material. Heavier formats (CHR, EDM, dance) may benefit from PrimeBass + Bass Clipper on; talk-heavy or classical formats may want Multiband intensity dropped and Composite Clipper drive reduced.

### Setting levels — input, AGC, Final Drive, exciter

Three knobs do most of the work between your source and the exciter. They sit at three different points in the chain and each does a specific job — get them right in order and the chain sounds clean without much fiddling.

**The chain (left to right):**

```
source → IN meter → AGC → [DSP] → Final Drive → composite clipper → MPX Output Level → exciter
                  ^                ^                                 ^
                  level control    loudness lever                   hardware calibration
```

**1. Get your input into the AGC's working range.** Open `Monitoring`. The `IN` meter shows the level coming into MPX Prime Studio from your source (before any processing). Aim for input peaks landing roughly in the **−12 to −6 dBFS** range on busy program — bright but not pinned. If the source is consistently below −18 dBFS the AGC has to push hard to reach its target; if it's above −3 dBFS it's eating its own headroom before the chain even sees it.

The level adjustment lives upstream of MPX Prime Studio — in your studio mixer, DAW, OS audio output, or BlackHole loopback source's gain. There's also `Processing` → `Core` → `Input Gain` (±24 dB) inside MPX Prime Studio, but use that only to trim — the further upstream you fix the level, the less you stack noise floors.

**2. Let AGC do the level-evening.** Open `Processing` → `AGC`. The AGC's job is to ride out the long-term level differences between songs / shows / sources so the chain downstream sees a roughly constant program level. The two knobs that matter:

- `Platform Target` — the level the AGC drives the program *toward*. **Default −14 dBFS** (`wideband_agc_target_db`) is a good starting point and matches what Orban / Omnia / Stereo Tool ship by default. Lower target = AGC pulls more, denser sound; higher = lighter touch.
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

**4. Set MPX Output Level to match the exciter's input.** `Processing` → `Core` → `MPX Output Level` (±18 dB) is the final calibration knob — it scales the composite signal between MPX Prime Studio and the exciter. The right value depends on your exciter / SDR / RF generator's input sensitivity.

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

### Test Tone (calibration source)

`Tools` -> `Test Tone` (`source_mode = tone`, `test_tone_*`) replaces the audio input with a sine, pink or white source, live. Since 0.45 it is a **calibration source, not program**: the tone bypasses every gain-changing stage -- input gain, AGC, EQ, multiband / Advanced Dynamics, enhancers, bass / HF / audio clippers, HF and Audio Limiters, Final Drive, the composite clipper, BS.412 and the final limiter -- while the delay-bearing stages stay in the path so pilot and RDS remain aligned. **0 dBFS = 100% of the audio modulation** left after the pilot/RDS reservation, and the scale is linear in dB, so the composite audio deviation is exactly `mpx_deviation_khz x budget x 10^(level/20)` (budget ~0.85 with 8% pilot and 2 kHz RDS at 75 kHz: -20 dBFS gives ~6.4 kHz of audio deviation plus ~8 kHz of pilot/RDS). A sine is pre-compensated for the pre-emphasis curve, so it reads the same deviation at 400 Hz, 1 kHz or 10 kHz; pink / white noise are peak-normalised and not compensated. The Test Tone card shows the expected audio and total deviation for the current level, pilot and RDS settings -- compare it with the Meter or a modulation monitor to calibrate the exciter. Before 0.45 the tone ran through the whole processing chain, so any level was lifted by the AGC into the clipper and produced full, clipped deviation ("way too loud, and the level slider does nothing"); `TestToneGeneratorTests` now pins level-in / deviation-out. The `Left` / `Right` routing modes double as a **channel-assignment check** on a real receiver: a left-routed tone must come out of the receiver's left speaker. Until 0.45 the encoder sent the stereo difference with the opposite sign to 47 CFR 73.322 / ITU-R BS.450-3, so every real receiver played L and R swapped (the built-in monitor and MPX Prime Meter compensated silently and could not show it); if you calibrated channel assignment against that behaviour, re-check it after upgrading.

### Final-stage presets and clipper workflow

The `Processing` -> `Final Stage` tab contains the workflow-level loudness controls (Broadcast Preset, Final Drive, Composite Deviation) and the **Final-MPX Safety Limiter** card (Enable, Threshold, Look-Ahead enable + ms — restart-required). The `Audio Limiter` tab handles the pre-encode peak limiter on its own.

- `Broadcast Preset`: loads a matched AGC + final-stage starting point
- `Final Drive`: drives the composite clipper harder or softer
- `MPX Output Level`: final output calibration, not the main loudness control

**How the final stage controls peaks (0.45).** The composite clipper is the loudness stage; its `Threshold` and `Ceiling` (Composite Clipper tab, `mpx_clipper_threshold_db` / `mpx_clipper_ceiling_db`) are read against the *audio-composite budget* -- the part of the composite left after the pilot and RDS reservation -- with the Ceiling landing exactly on that budget, so the composite uses all of it and your calibrated deviation does not move. Behind the clipper, the Final-MPX Safety Limiter (look-ahead) rides down the small in-band overshoot the clipper's pilot / stereo / RDS guard protection leaves (about 1-1.5 dB of gain riding on the densest program is normal), and the always-on safety soft-clips sit idle behind both. Before 0.45 the soft-clips ran ahead of the clipper at a lower threshold and did all the clipping themselves -- the cause of the hi-hat / cymbal distortion field report; `--verify-hf-transients` measures that this is no longer the case.

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
- `Composite Clipper` (`Processing` -> `Composite Clipper`): trades stereo image and HF cleanliness for raw loudness. Leave `Enable Composite Clipper` off when loudness is not the priority. If you do enable it, the per-band protection toggles let you choose what to keep clean:
  - `Protect Stereo Pilot`, `Protect Stereo Subcarrier`, `Protect RDS` — leave on (defaults). These keep the 19 kHz pilot, 38 kHz L-R subcarrier, and 57 kHz RDS regions clean of clip IM.
  - `Protect Audio Highs` — off by default for maximum loudness. Turn on to recover audible HF detail at the cost of some loudness when the clipper is driven hard.

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

### Advanced Dynamics (experimental single-stage leveler)

`advanced_dynamics_enabled` (default `False`) replaces the wideband AGC **and** the multiband compressor with one fused 5-band leveling stage. The point of the fusion is that slow leveling and per-band density shaping can no longer fight each other (the classic AGC-pulls-down-while-multiband-pushes-up pumping); each band rides toward a target level with program-adaptive speed — near-instant on transients, frozen when the band already sits at target, slower on dense material. You configure the sound you want instead of attack/release times:

- `advanced_dynamics_target_db` (default `-16.0`) — the level every band is brought toward.
- `advanced_dynamics_low_offset_db` / `advanced_dynamics_mid_offset_db` / `advanced_dynamics_high_offset_db` (defaults `0 / -3 / -9`) — tonal balance anchors relative to the target; the 5 bands interpolate between them (the same low/mid/high anchor scheme the multiband compressor uses).
- `advanced_dynamics_max_gain_db` (default `12.0`) — maximum lift for quiet program (the reduction side is fixed at 24 dB). The default was lowered from 18 after field testing: high boost both chases natural fades harder and lowers the silence gate (`target - max_gain - 10 dB`), pumping tails on sparse material. Raise it deliberately for wide-dynamics formats.
- `advanced_dynamics_density` (`0..1`, default `0.5`) — denser = tighter hold window and faster leveling.
- `advanced_dynamics_speed` (`0.25..4`, default `1.0`) — overall time-constant scale.

A built-in **decay guard** distinguishes "program actively fading" from "program is quiet": while a band's envelope sits well below its recent peak (a note or song decaying naturally), the leveler holds instead of lifting, resuming when the level stabilizes or new material arrives. Without it a solo decaying sound (a bell, a fade-out) gets its fade flattened and extended -- heard as added ringing/sustain.

Band layout follows `multiband_x1_hz..multiband_x4_hz`. All keys are live-apply. When the stage is enabled the AGC and Multiband settings are ignored (those stages are bypassed); when it is disabled the chain is bit-identical to before the stage existed. It is evaluated with `--verify-advanced-dynamics` and must pass program-material A/B plus listening before any preset enables it.

In the GUI the stage lives at `Processing -> Adv Dyn` (sidebar entry "Advanced Dynamics", between Multiband and Expander, with a card on the Processing Overview grid); in the web dashboard it is the "Advanced Dynamics" card on the same page as Multiband.

While the stage is enabled, both UIs ghost the stages it replaces: the AGC, Multiband, Expander, and MB Limiter tabs/cards dim, their controls disable, a "bypassed" banner links back to Advanced Dynamics, and the sidebar/overview enabled-dots show the EFFECTIVE state (off while bypassed). The stored flags are untouched -- disabling Advanced Dynamics restores the exact previous AGC/Multiband behavior. A test pins the bypass as total: with the leveler on, extreme AGC/multiband settings produce bit-identical output to having those stages off.

### Now Playing script output

The RDS Radiotext section can poll an external script for now-playing metadata.

A ready-to-use example poller ships with MPX Prime Studio, in the DMG's
`Now Playing Scripts/` folder and inside the app at
`MPX Prime Studio.app/Contents/Resources/Scripts/`:

- `nowplaying.sh` — auto-detects the running player and reads its metadata via
  AppleScript: **VLC** (current item, only while playing) first, then
  [**Cog**](https://github.com/losnoco/cog) (current entry via its `currentEntry`
  dictionary). Note: Cog exposes no play/pause state, so it reports the loaded
  track even while paused (it clears the entry on Stop). The shared title cleanup
  and output formatting are written once; only the per-player fetch differs, so use
  it as a template for another player by adding one fetch function.

The script strips parenthetical `(Radio Edit)` / `(feat. X)` and bracketed
`[Official Video]` / `[Remastered]` decorations from the title — they routinely
push the RadioText / PS over length, e.g. `Song Title (Radio Edit) [Official Video]`
becomes `Song Title`. Both are **on by default**; set `STRIP_TITLE_PARENS=0` and/or
`STRIP_TITLE_BRACKETS=0` in the script's environment to keep them. If stripping
would empty the title, the original is kept.

Copy it somewhere stable (for example your home folder) and point the
Radiotext now-playing script setting at it. The first run prompts once for
Automation permission to control the player.

Expected script behavior:

- Exit with status `0` only when active playback metadata is available
- Write metadata to `stdout`
- Plain single-line output is accepted and treated as the display text
- Structured `key=value` lines are preferred for correct RT+ tagging

No-data behavior:

- Exit with status `1` when no song is currently playing or no usable metadata is available
- MPX Prime Studio treats `exit 1` and empty output as `No Song Data`
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

MPX Prime Studio accepts the same RDS text grammar as Stereotool for PS, PTYN, Long PS, and Radiotext fields. Unsupported markers are accepted silently where practical so existing Stereotool presets load without modification.

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
| `\w"url"` | Fetch text from a URL. MPX Prime Studio extension, not in Stereotool. |

Example mixing timing modes and separators:

```text
1.5s:MPX Prime Studio/3t:In STEREO on RDS/10s:Now: {artist} - {title}
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
- Program lowpass default: `16.0 kHz` (`program_lowpass_hz`)
- Scope auto gain default: enabled

## Processed-audio output mode

By default MPX Prime Studio emits the finished FM composite (pilot + stereo subcarrier +
optional RDS) for a transmitter / exciter that accepts a composite/MPX baseband
input. **Processed-audio output mode** instead emits the processed stereo **L/R
audio** — for transmitters that only accept L/R analog or AES3 audio and have
their own built-in stereo coder + RDS encoder (the classic separate-processor
topology). You keep MPX Prime Studio's full audio chain (AGC, EQ, multiband, stereo,
bass, clippers, pre-emphasis, pre-encode limiter); you give up the composite-only
stages (composite clipper, BS.412, pilot-locked RDS), which the external box now
provides.

The composite path always sounds louder/denser because the composite clipper is
the main loudness stage. Where a transmitter accepts a composite input, prefer
composite-direct and switch the exciter's own stereo coder off. Use processed-audio
mode only for gear that cannot take a composite.

### Enabling it

Settings (Cmd-,) -> **Output Mode** -> select **Processed Audio**. This is
restart-required (it changes render rate, device format, and filtering). When
active, the composite-only surfaces are hidden automatically: the RDS section, the
Composite Clipper / BS.412 / Final Stage tabs, the pilot level control, the MOD
(deviation) meter, the composite readouts on the Monitoring dashboard, and the MPX
Spectrum + Scopes windows. The status bar shows `MODE: PROC AUDIO`.

### Pre-emphasis ownership

Exactly one device in the chain may apply pre-emphasis (50 us EU / 75 us US).
Pick in Settings -> Output Mode -> **Pre-emphasis**:

- **Coder has NO pre-emphasis (or it is switched off):** select `50`/`75 us` so
  MPX Prime Studio applies it. Its pre-emphasis-aware limiter then controls the
  HF peaks. (Common for cheap exciters.)
- **Coder applies pre-emphasis:** select `Off` so MPX Prime Studio stays flat.
- **Never both** — two pre-emphasis stages in series over-deviate.

### Optional final loudness clipper

To narrow the loudness gap when the external coder has no clipper of its own,
Settings -> Output Mode -> **External coder has its own clipper**:

- Leave **ON** (default) if your coder clips/limits its input — MPX Prime Studio stays
  clean to avoid double-clipping.
- Turn **OFF** if it does not — MPX Prime Studio then applies an oversampled
  distortion-cancelled final clipper, with a **Final Clipper Drive** slider
  (0-12 dB) to set density. Two clippers in series sound harsh, so only enable
  this when the coder genuinely does not clip.

### Output level and rates

- **Output level:** the Core tab's **Output Level** slider (`output_gain_db`). The
  processed feed is normalized so peaks reach ~0 dBFS at 0 dB; lower it to match
  your coder's input reference, raise it for a hotter feed.
- **Sample rate / bit depth:** run **48 kHz / 24-bit** end to end (the >=110 kHz
  rule is composite-only). Match the output device format in Audio MIDI Setup to
  `sample_rate`. See BUILDING.md / the rate notes for the full rationale.
- **Auditioning:** because the output is plain L/R, you can route it to any
  monitors/DAW to A/B processing changes. Listen with pre-emphasis **Off** so the
  monitored signal is not artificially bright; the decoded-MPX monitor remains the
  reference for final on-air sound.

INI keys: `processed_audio_output`, `preemphasis_us`,
`processed_audio_coder_has_clipper`, `processed_audio_final_clip_drive_db`,
`output_gain_db`.

## Monitoring and output notes

The DSP status card's **Safety GR** is the final look-ahead MPX limiter's gain reduction (about 1-1.5 dB on dense program is normal: it rides the composite clipper's guard-band overshoot). **Safety Clip** next to it is how far, in dB, the composite exceeded the budget and had to be caught by the 1x safety soft clip; it must read 0.0 in normal operation -- anything above zero means the composite clipper and final limiter are not controlling the peaks (both off, or an impossible gain structure) and the distortion class fixed in 0.45 is back. The same value is `safetyClipDB` in `GET /api/telemetry` and "Safety Clip" on the dashboard.

- `MPX Output Device` is the composite/baseband output device
- `Monitor Output Device (Decoded MPX Simulation)` is used when monitor output is enabled
- The orange microphone indicator in the macOS menu bar is the system privacy indicator and appears when MPX Prime Studio is actively using audio input
- `Mono Mode` now transmits true mono composite and suppresses pilot, stereo subcarrier, and RDS while enabled
- If a remembered input / output / monitor device is not connected, **Start is refused** with an alert rather than silently streaming to the OS default -- reconnect the device or pick another in `Settings`. (Devices are remembered by UID and name, so moving an interface to another USB port keeps the selection.)

### Monitoring windows

Beyond the `Monitoring` dashboard tab, Studio offers detachable instrument
windows (from the toolbar / Window menu). Like the Meter's displays, they are
dark instrument panels and repaint in `Canvas` so a live value change never
triggers a layout pass:

- **Spectrum** -- the composite (MPX) spectrum after stereo encoding, with the
  same FM band-region overlay the Meter draws: **Mono L+R**, **19 kHz Pilot**,
  **Stereo L-R** (lower and upper sideband -- the same L-R signal mirrored around 38 kHz), **57 kHz RDS**, and **SCA** captions mark where each component
  sits, so you can confirm the pilot, subcarrier, and RDS land in the right
  places at the right levels.
- **Pre-MPX Spectrum** -- an RTA-style bar spectrum of the processed L/R audio
  before composite assembly (the audio the encoder is about to modulate).
- **Scopes** -- composite / decoded-monitor waveforms.
- **Levels** -- the vertical deviation / level meters as a standalone window.

## Remote control (REST API + web dashboard)

The encoder embeds an HTTP control server for remote and automation use --
on macOS (GUI or `--nogui`) and on the Linux CLI build. It is **disabled by
default**.

Enable it in the INI (`[CONTROL]` section, also editable in the GUI's
Settings tab; GUI changes take effect at the next app launch):

```ini
[CONTROL]
control_enabled = True
control_bind = 127.0.0.1   ; 0.0.0.0 = all interfaces (requires API key)
control_port = 8737
control_api_key =          ; required for any non-127.0.0.1 bind
```

The web session reads and writes the SAME configuration file as the
Studio GUI (the default `~/Library/Application Support/MPX Prime
Studio/MPX Prime Studio.ini`, or whatever `--config` names) -- so it
starts from your existing station setup, and its changes persist for
the next GUI launch. The resolved path is printed at startup.

For one-off runs, `--control` (alias: `--web`) or `--control-port 9000`
enables it without editing the INI; these flags imply `--nogui` (run
headless, serve the dashboard). In the GUI app, use the Settings tab.
From a source checkout, `./run-build-web.sh` builds the release binary and
starts it headless with the dashboard, on macOS and Linux alike.

**Security:** binding 127.0.0.1 needs no key. Binding any other interface
REQUIRES `control_api_key` -- the server refuses to start remote-exposed
without one. Clients send the key as `Authorization: Bearer <key>` or
`X-API-Key: <key>`. The server speaks plain HTTP; for access beyond a
trusted network, front it with a TLS reverse proxy (nginx/caddy).

Open `http://<host>:8737/` in a browser for the dashboard. Since 0.44 it
mirrors the Studio GUI page-for-page: a pinned broadcast status bar
(transport Start/Stop/Restart plus the transport-level **Bypass** button,
IN/MPX level bars, AGC/limiter/clipper gain-reduction meters, deviation /
pilot / RDS injection / budget-margin readouts, restart-pending badge)
above four sidebar sections:

- **Monitoring** -- source/output devices, input meters, MPX deviation /
  modulation, per-stage gain-reduction readouts, subcarrier injection +
  budget margin, and stream health (uptime, ring-buffer fill, OVR/UND
  drop counters, resample trim), plus a signal-chain card grid.
- **Processing** -- the GUI's tab set one page each: Overview (stage grid
  with enable switches), Profile (station-format picker), Core, Phase
  Rotator, AGC, Parametric EQ, Multiband (incl. crossovers X1-X4),
  Advanced Dynamics, Expander, MB Limiter, Stereo Widener, PrimeBass,
  Bass Clipper, Audio Clipper, HF Clipper, Audio Limiter, Composite
  Clipper (incl. look-ahead + oversampling), BS.412, Final Stage. Real
  switches and sliders with the GUI's control vocabulary, applied live on
  release; each page has the GUI's "Reset This Tab" button.
- **RDS** -- Status (on-air PS/RT/PTYN/Long PS), Identity, Radiotext
  (mode, rotation, the 4 manual buffers, RT+ formats, Now Playing
  configuration), Long PS, Alt. Frequencies (list + method), Schedule
  (group sequence, scheduler toggles, CT/TZ), Subcarrier.
- **Tools** -- Test Tone, Interfaces (input/output/monitor device
  pickers; selecting one is a restart-class change; the read-only Remote
  Control card shows the server's own settings, which stay INI/GUI-only
  by design), Presets (per-stage preset pickers plus the 8 operator
  preset slots: name, Save/Load/Export/Clear, Import into empty slots),
  and an Advanced page holding the raw all-settings editor.

Every change reports back live / live-RDS / needs-restart. The Bypass
button mirrors the GUI's Cmd-B exactly: it flips `processing_bypass`
(restart-class, so it restarts the engine when running), shows a red
BYPASSED state, and asks for confirmation before putting unprocessed
audio on air. With `processed_audio_output` enabled the dashboard hides
the same pages the GUI hides (RDS group, Composite Clipper, BS.412,
Final Stage) and Monitoring swaps the MPX/subcarrier cards for a
processed-audio output card. The dashboard is a single self-contained
page (no internet access needed) and prompts for the API key when one is
configured.

### Endpoints

| Method | Path | Description |
| --- | --- | --- |
| GET | `/api/status` | running state, platform, version, sample rate, uptime, restart-pending |
| GET | `/api/meters` | levels, gain reduction, pilot/RDS injection %, deviation, budget margin, and (macOS input source) input-ring health (subset on Linux) |
| GET | `/api/rds` | on-air PS/RT snapshot + PI/PTY/TA/TP and configured text |
| PUT | `/api/rds` | curated update: `{"ps": ..., "rt": ..., "ta": true, "pty": 8, "pi": "83E1", "tp": ..., "enabled": ...}` -- applies live; `ps` writes bank A |
| GET | `/api/config` | every INI setting, grouped by section |
| PATCH | `/api/config` | `{"<ini_key>": "<value>", ...}` -- any key from this manual's tables |
| GET | `/api/schema` | the dashboard's control schema: widget definitions (label/range/unit) + page model for every exposed INI key -- the single source the web UI renders from |
| GET | `/api/config/defaults` | factory defaults, grouped like `/api/config` -- diff against it for "reset to defaults" |
| GET | `/api/presets` | available preset ids by kind (primebass / widener / multiband / finalstage / format_profile -- all kinds on BOTH backends since 0.44) |
| GET | `/api/telemetry` | live scope waveforms + MPX spectrum (display-decimated, ~6 KB; `?window_ms=` picks the scope timebase); 503 while stopped or on a platform without a scope tap |
| GET | `/api/devices` | the machine's audio devices (CoreAudio / ALSA) with the selected input, output, AND monitor slots (`selectedMonitor` + `monitorEnabled` since 0.44) |
| POST | `/api/nowplaying` | push the current track: `{"artist": ..., "title": ..., "display": ...}` -- feeds the RT / PS / RT+ templates (see "Now-playing push" below) |
| GET | `/api/snapshots` | the 8 operator preset slots (name, saved-at, active/modified) -- shared with the native GUI's Presets sidebar |
| POST | `/api/snapshots/N/save`, `/load` | capture the current config into slot N (body `{"name": ...}` optional) / apply slot N as one full config patch |
| PATCH / DELETE | `/api/snapshots/N` | rename / clear slot N |
| GET / PUT | `/api/snapshots/N/export`, import | the slot's full INI text (doubles as a `--config` file) / import INI (body `{"name": ..., "ini": "..."}`) |
| POST | `/api/presets` | `{"kind": "multiband", "id": "3_chr", "intensity": 1.0}` (intensity <0.75 light / >1.25 heavy) |
| POST | `/api/transport/start\|stop\|restart` | engine lifecycle |

`PATCH /api/config` responds with a per-key **disposition**: `live` /
`liveRDS` (hot-applied to the running engine, no restart), `restartRequired`
(saved; takes effect at the next start -- e.g. `rds_level`, `pilot_level`,
`sample_rate`, devices), or `unchanged` (value identical after
clamping/parsing, or unknown key). The classification is derived from the
same runtime structures the engine hot-applies, so it always matches what
the engine actually does. Every change is saved to the INI immediately.
Values follow INI text conventions (booleans `True`/`False`; no `;` in
values).

When the macOS input source is running, `/api/meters` also reports
capture->render ring health: `inputRingBufferedFrames` (fill level, hovers
near the engine target), `inputRingOverflows` / `inputRingUnderflows`
(input clock faster / slower than render), `inputRingTornReads`,
`inputResampleMode`, and `inputRatioTrim` (the drift corrector's current
adjustment). These are diagnostics for clock-drift between the input and
output devices; steady buffer with zero over/underflows means the bridge is
healthy. They are null in headless/ALSA and when no input source is active.

The now-playing script integration (see RDS) keeps working alongside the
API; automation systems that only need RT/PS updates can use `PUT /api/rds`
instead of a polling script.

### Now-playing push (remote RadioText)

Feed the current track to the encoder over the API instead of a local script --
useful when the player and the encoder are on different machines (players on
your Mac, encoder headless on a Linux box).

`POST /api/nowplaying` with `{"artist": "...", "title": "...", "display": "..."}`
(display optional; defaults to "Artist - Title") writes the same now-playing
state the local script feeds, so your RT / PS / RT+ templates fill in and RT+
artist/title tagging works. The response `{"ok":true,"nowPlayingEnabled":bool}`
reports whether rendering is on.

Setup on the encoder (once): set `now_playing_enabled = True`, an `rt_text`
template using the macros -- e.g. `10s:{artist} - {title}/10s:My Station` --
and leave `now_playing_script` empty (the push is the source). A `/`-segmented
template shows the static segment when nothing is playing; a line whose
`{artist}`/`{title}` is missing is skipped rather than aired half-filled.

From a source checkout on macOS, `scripts/push-nowplaying.sh` does this for
VLC and Cog:

```bash
./scripts/push-nowplaying.sh --url http://mpxbox:8737 --api-key <key>
# or: MPXPRIME_URL=... MPXPRIME_API_KEY=... ./scripts/push-nowplaying.sh --interval 5
```

It reuses `scripts/nowplaying.sh` for extraction and pushes only on track
change (no RadioText thrash), clearing the track when playback stops.

### MPX line output calibration (dBFS)

`mpx_line_output_dbfs` ([MPX], default `0.0`, range -40..0, live-apply; GUI:
Processing > Core > "Line Output"; also on the web dashboard) sets the
ABSOLUTE converter level of 100% modulation: at `-12.0`, a 75 kHz-deviation
composite peaks at -12 dBFS on the output interface. It is applied at the
DAC write, after every processing stage and meter tap -- deviation readouts,
the composite budget, and all internal levels keep the classic
0 dBFS = 100% convention. Use it to match an exciter's input sensitivity
once, in software: keep the operating system / interface output volume at
0 dB (a mixer attenuation scales pilot and RDS injection along with the
audio, and an accidental 0% mixer silences the transmitter -- calibrate
here instead). `output_gain_db` remains the in-chain MPX level trim that
participates in the composite budget -- and since 0.45 it is **attenuation-only in composite mode** (clamped to <= 0 dB on load; the slider stops at 0): a positive value divided the whole budget by the gain, so the audio composite was clipped deeper while pilot and RDS went on air above their configured injection and nothing got louder (the governor caps the composite regardless). The processed-audio output keeps the full range; the line output is pure output-stage
calibration -- attenuation only. Positive line gain is deliberately not
offered because it is unphysical at a DAC: full scale is the hardware
ceiling, so "+3 dBFS" cannot raise the peak voltage your exciter sees.
All it can do is lift everything below the clamp (pilot 8% becomes 11.3%,
RDS likewise) and clip the summed composite during audio peaks --
momentarily clipping pilot and RDS, which must stay constant-amplitude.
The field symptom is characteristic: deviation looks right (peaks still
stop at full scale) while pilot and RDS read ~3 dB high. If your exciter
under-deviates with the line output at 0.0 dBFS, correct it on the analog
side: trim the exciter's input sensitivity so full scale equals 75 kHz,
and pilot/RDS return to their configured injection automatically.

## Offline verification

MPX Prime Studio includes an offline MPX verification mode that renders deterministic test scenarios without opening audio devices.

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
./macOS/.build/debug/MPXPrime --verify-multiband-coupling --seconds 2
```


`--verify-multiband-coupling` forces multiband on, disables AGC for isolation, and toggles `multiband_inter_band_coupling_enabled` off/on across 5 program scenarios (bass-heavy, kick/vocal, dance, wide-bass, speech-bed), reporting per-band Low/Mid/High deltas + correlation / side-to-mid / peak / overshoot / render-cost ratio.

`--verify-advanced-dynamics` A/Bs the classic AGC + multiband chain against the single-stage Advanced Dynamics leveler on 4 program scenarios (a 20 dB level jump, dense bass, a quiet ballad, HF transients), reporting RMS / per-band / correlation / side / peak / overshoot deltas plus two leveler-specific metrics: re-processing idempotency (feeding the leveler's output through a fresh leveler should barely change it) and the render-cost ratio against the two stages it replaces.

`--verify-hf-transients [--seconds 5]` is the hi-hat / cymbal distortion gate (0.45). It renders three deterministic HF-transient scenarios -- `ride_multitone` (three sustained partials at 8.9 / 11.3 / 13.1 kHz over a bed), `hat_multitone` (the same partials gated 4 times a second) and `cymbal_wash` (6-14 kHz noise bursts over a sustained wash) -- through a table of chain variants: the pre-0.45 field chain (no limiter / clipper, +8 dB drive), every shipped Format Profile, and per-stage isolation rows on Music - Loud (HF limiter off, HF clipper on, composite clipper off, Audio Limiter off, `cancel_audio`, Advanced Dynamics, safety soft-clips off, ...). Each row is decoded receiver-side (`MPXDecoder`, de-emphasised) and reports **HF SINAD** (power at the known partials vs everything else in 300 Hz-15 kHz -- clipping IM and harmonics land in the "everything else" sum), **HF crest loss** (decoded >6 kHz 99.9th-percentile crest minus the input's; negative = attacks crushed), the **15-23 kHz composite spill** (nothing but the pilot belongs there) and the worst composite peak. Shipped profiles are gated: ride SINAD >= 30 dB, hat SINAD >= 20 dB (>= 15 dB for Music - Loud, whose 8 dB drive is the loudness it promises), crest loss > -6 dB, spill < -36 dB. The diagnostic rows only report; read them to see which stage moves a number before touching DSP.

`--verify-ssb-stereo` A/Bs classic DSB stereo encoding against the SSB Stereo encoder: program scenarios on a LINEAR composite (peak controllers off, so the encoder's raw headroom effect is visible) plus tone measurements on the full chain -- 38 kHz sideband asymmetry at 1/10/14 kHz (confirms the SSB action; matches theory exactly) and coherent decode separation off/on. This is the stage's hard gate: it goes TIGHT when separation drops more than 6 dB (or below 20 dB absolute), when the composite budget is exceeded, or when no headroom is measurably reclaimed.

Current verification is strongest for composite safety, budget behavior, receiver-model stereo separation, hi-hat / cymbal HF distortion, and the inter-band-coupling / Advanced Dynamics / SSB A/B measurements. It is not yet a full listening-quality oracle for multiband crossover tone, stereo-image feel, or PrimeBass character, so final tuning still requires real program listening.

Exit status:

- `0` means no obvious composite-budget or safety-limiter issue was found
- `1` means the configuration is close to the limit and should be reviewed
- `2` means at least one verification warning was triggered
- `3` means the composite violated the subcarrier budget after pilot/RDS injection (hard failure -- never acceptable, checked before every softer finding)

### Listening test playlist

Measurement first, then ears: `docs/test-playlist.md` is a sourced list of reference tracks that broadcast, mastering and PA engineers use to expose specific artifacts -- asymmetrical peaks, sibilance and cymbals (the pre-emphasis stress that `--verify-hf-transients` models), dense bass, leveler pumping, wide dynamics, stereo image, speech -- mapped to the MPX Prime stage each one exercises, with a minimal per-stage regression set at the end. Use the release build against a real 192 kHz device and A/B by toggling the named stage.

### Reference-receiver validation (Profline SFP-X)

The composite output has been validated on a Profline SFP-X measuring receiver
against a 75 kHz total-deviation reference. The headline subcarrier levels read as
expected and, importantly, read steady -- both subcarriers are injected after all
peak-control stages at constant amplitude, so their deviation does not move with
program audio.

| Subcarrier | Setting | Measured (SFP-X) | % of 75 kHz |
|------------|---------|------------------|-------------|
| 19 kHz pilot | 10% | 7.3-7.4 kHz (steady, last-digit dither) | ~9.8% |
| 57 kHz RDS | `rds_level` 2.4 kHz | 2.4 kHz (steady) | ~3.2% |

Notes:

- The 7.3/7.4 kHz pilot reading is the analyzer rounding a ~7.35 kHz value across
  its display resolution, not the pilot modulating. A pilot that genuinely wandered
  with program would indicate a fault -- by design the pilot here is constant
  amplitude (post-clipper injection).
- Pilot is at the top of the 8-10% legal window; RDS at 3.2% is comfortably inside
  the EN 50067 / IEC 62106 range (2.0 kHz nominal, 1.0-7.5 kHz permitted) and a touch
  above the 2.0 kHz default for more robust data decoding.
- Subcarriers (~9.75 kHz combined) share the +/-75 kHz peak budget with the audio
  composite; the audio path is clipped to leave room for them, which is why they can
  be injected at fixed amplitude without pushing total deviation over target.
- Confirm the analyzer's total-deviation reference is 75 kHz before reading the
  percentages. On a 50 kHz reduced-deviation mandate the same kHz figures correspond
  to different percentages (and the pilot/RDS levels should be scaled accordingly).

The receive side has the same pedigree: **MPX Prime Meter's readings were
cross-validated against the same SFP-X on a live commercial station** -- pilot
and RDS matched exactly (5.6-5.7 / 3.5-3.7 kHz on both instruments), and max
deviation agreed within 1-2 kHz measured side-by-side at the same moment,
inside ITU-R SM.1268's +/-2 kHz instrument accuracy requirement. When
comparing peak deviation against any reference receiver, always compare live
at the same moment: deviation peaks are program-dependent, and a weaker
reception path (multipath) inflates them.

## Processing bypass

The `Bypass` control does not create a true wire bypass. It disables the creative processing blocks while keeping essential FM encode stages active. It is available in the GUI (Cmd-B / toolbar) and, since 0.44, on the web dashboard's status strip -- the flag is restart-class, so toggling it remotely restarts the engine (the dashboard asks for confirmation first).

Always active:

- Input gain
- Program lowpass
- Pre-emphasis
- MPX encoding
- Final drive, deviation scaling, and limiting
- Output gain

Disabled by bypass:

- Phase rotator
- Wideband AGC
- Audio HPF
- HF trim
- Parametric EQ
- PrimeBass
- Mono bass
- Multiband processing (incl. per-band expander and MB limiter)
- Advanced Dynamics
- Stereo widener
- Bass / audio / HF clippers
- Pre-encode audio limiter
- Stereo-image protection


## MPX Prime Meter (companion analyzer)

MPX Prime Meter is the receive/analyze counterpart to the encoder, shipped
as `MPX Prime Meter.app` in the same DMG. It takes an FM MPX composite (from
an audio device or an in-process RTL-SDR / SDRplay tuner), decodes stereo +
full RDS, and measures deviation, MPX power (ITU-R BS.412), and SM.1268
compliance on one dashboard window.

It has its own manual: **[MPX Prime Meter — User Manual](manual-meter.md)**.
The RDS PI/ECC and PTY reference tables below serve both apps (the encoder
sets these fields; the Meter decodes them).

## Appendix: RDS PI and ECC Country Table

RDS country identity is derived from:

- the top hex digit of the `PI` code, also called the country identifier or PI symbol
- the `ECC` value transmitted in group `1A`

Together they identify a country or area. There is no special "pirate" country code.

Group `1A` also carries the `LIC` language code (e.g. `15` Italian, `09` English, `0F` French, `08` German, `0A` Spanish, `1D` Dutch) and an optional Programme Item Number (PIN). PIN is off by default (transmits 0); enable it in **RDS → Program → Station Identity** to send the current programme item's scheduled day / hour / minute (config keys `pin_enabled`, `pin_day`, `pin_hour`, `pin_minute`). PIN is a legacy field that few modern receivers decode.

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

## Appendix: RDS Programme Type (PTY) Codes

`PTY` is a 5-bit programme-type ("genre") code carried in every group. The code
is the same field worldwide, but **Europe (RDS) and North America (RBDS) assign
different genres to the same number** — there is no in-band flag telling a
receiver which table to use, so receivers pick by region. The **PTY Region**
toggle in the RDS identity tab (`Europe (RDS)` / `USA (RBDS)`, INI key
`pty_rbds`) switches which table labels the picker and the status display; the
transmitted 5-bit code is identical either way. Pick the table that matches your
audience — e.g. code 10 reads as `Pop Music` on an RDS receiver but `Country` on
an RBDS receiver.

### Europe (RDS, EN 50067 / IEC 62106)

| Code | Programme type | Code | Programme type |
| ---: | :------------- | ---: | :------------- |
| 0 | None / undefined | 16 | Weather |
| 1 | News | 17 | Finance |
| 2 | Current Affairs | 18 | Children's programmes |
| 3 | Information | 19 | Social Affairs |
| 4 | Sport | 20 | Religion |
| 5 | Education | 21 | Phone-In |
| 6 | Drama | 22 | Travel |
| 7 | Culture | 23 | Leisure |
| 8 | Science | 24 | Jazz Music |
| 9 | Varied | 25 | Country Music |
| 10 | Pop Music | 26 | National Music |
| 11 | Rock Music | 27 | Oldies Music |
| 12 | Easy Listening | 28 | Folk Music |
| 13 | Light Classical | 29 | Documentary |
| 14 | Serious Classical | 30 | Alarm Test |
| 15 | Other Music | 31 | Alarm (emergency) |

### North America (RBDS, NRSC-4-B)

| Code | Programme type | Code | Programme type |
| ---: | :------------- | ---: | :------------- |
| 0 | None / undefined | 16 | Rhythm and Blues |
| 1 | News | 17 | Soft Rhythm and Blues |
| 2 | Information | 18 | Language (Foreign) |
| 3 | Sports | 19 | Religious Music |
| 4 | Talk | 20 | Religious Talk |
| 5 | Rock | 21 | Personality |
| 6 | Classic Rock | 22 | Public |
| 7 | Adult Hits | 23 | College |
| 8 | Soft Rock | 24 | Spanish Talk |
| 9 | Top 40 | 25 | Spanish Music |
| 10 | Country | 26 | Hip-Hop |
| 11 | Oldies | 27 | Unassigned |
| 12 | Soft | 28 | Unassigned |
| 13 | Nostalgia | 29 | Weather |
| 14 | Jazz | 30 | Emergency Test |
| 15 | Classical | 31 | Emergency (ALERT!) |

Notes:

- Codes 30 / 31 are reserved for emergency use in both tables (test + live
  alert) and should not be used for normal programming.
- RBDS codes 24 / 25 / 26 (`Spanish Talk` / `Spanish Music` / `Hip-Hop`) were
  added in later NRSC-4 revisions; older receivers may show them as
  `Unassigned`.
- Receivers display short (8-character) and long (16-character) abbreviations of
  these names; the exact wording varies by manufacturer, but the code-to-genre
  mapping is fixed by the standard.

