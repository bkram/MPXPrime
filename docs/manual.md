# MPX Prime Studio — User Manual

Operation, configuration, and reference for running MPX Prime Studio. For a project overview see the [README](../README.md); to build from source see [BUILDING.md](BUILDING.md); for the DSP chain internals see [ARCHITECTURE.md](ARCHITECTURE.md).

## Usage

Launch MPX Prime Studio from `/Applications` (or wherever you copied it). On first run,
grant input access when macOS prompts — this is required to capture audio. Then
pick your input and MPX output devices in the app and start the engine.

Command-line flags (run the binary inside the app bundle):

```bash
"/Applications/MPX Prime Studio.app/Contents/MacOS/MPXPrime" --nogui       # headless, no UI
"/Applications/MPX Prime Studio.app/Contents/MacOS/MPXPrime" --seconds 10  # run for a fixed time then exit
"/Applications/MPX Prime Studio.app/Contents/MacOS/MPXPrime" --config "/path/to/MPX Prime Studio.ini"
```

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

1. **Format / sample rate**: set to **192 000 Hz**. Match what the engine is configured to (`sample_rate = 192000` in INI). If the device runs at a different rate Core Audio inserts a sample-rate converter that cannot represent the upper composite band cleanly. **Required for RDS** — the 57 kHz RDS subcarrier needs at least ~119 kHz Nyquist; 176.4 kHz is the lowest device rate that carries it correctly, 192 kHz is the canonical default. The in-app warning chip flags this misconfiguration but it shouldn't get that far in practice.
2. **Bit depth**: **24-bit integer or 32-bit float**. Either is fine; 32-bit float is the AVAudioEngine native format. 16-bit also *works* for the composite (96 dB SNR is well above any FM receiver's noise floor and you cannot hear the difference at the listener), but 24/32-bit is best practice — no extra dither/truncation step at the chain output, and headroom for downstream tools that further process the composite (resamplers, SDR DSPs).
3. **Volume / output gain**: **100 % (0 dB) on every channel**. This is the critical one. The macOS volume slider is post-mix — it scales the engine's already-finalised composite. If output volume is at, say, 75 %, the FM exciter receives a signal at 0.75× amplitude and your modulation undershoots by ~2.5 dB; the loudness target the chain just enforced is silently wrong. Audio MIDI Setup → device → "Master Stream" or per-channel volume sliders. Lock these at unity for any broadcast use.

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

## Configuration

Default config location:

```text
~/Library/Application Support/MPX Prime Studio/MPX Prime Studio.ini
```

Relevant config sections:

- `INTERFACES`: input/output/monitor device UIDs, source mode, monitor enable, block size
- `MPX`: processing, levels, stereo coding, limiter behavior
- `RDS`: program service, radiotext, flags, carrier settings

### Format Profiles (Station Format selector)

For one-click "make this sound right for my format", MPX Prime Studio ships with eight atomic Format Profiles plus a `Custom` sentinel, accessible from the dedicated **Processing → Format Profile** tab. Selecting a profile applies a coherent bundle of Multiband + Final Stage + PrimeBass + Stereo Widener + Composite Clipper settings tuned for that programming format. Per-stage knobs stay editable after the profile is applied — operators can tune from the profile baseline rather than from a blank slate. Pick `Custom` to flag "my settings are bespoke — don't overwrite them" so re-visiting the picker won't reset your manual tuning.

| Profile | Multiband | Intensity | Final Stage | PrimeBass | Widener | Clipper drive | Use case |
|---|---|---|---|---|---|---|---|
| **Community Radio** (default) | `5_ac` | light | `balanced` | off | `safe_fm` | +4 dB | Conservative LPFM / community radio; broad source compatibility |
| **Pop / Adult Contemporary** | `5_ac` | normal | `balanced` | `ac` (on) | `open_music` | +6 dB | Mainstream music — balanced, gentle bass enhancement |
| **CHR / Top 40** | `5_chr` | normal | `chr` | `chr` (on) | `wide_chr` | +8 dB | Modern hits — bright, hot, wide stereo |
| **Rock** | `5_rock` | normal | `punchy` | `rock` (on) | `open_music` | +7 dB | Punchy multiband preserves rock transients |
| **EDM / Dance** | `5_dance` | heavy | `chr` | `chr` (on) | `wide_chr` | +9 dB | Peak loudness, deep bass, wide image |
| **Urban / Hip-Hop** | `5_urban` | normal | `chr` | `urban` (on) | `open_music` | +8 dB | Deep low end, urban-tuned PrimeBass |
| **Jazz / Classical** | `5_classic` | light | `balanced` | off | `safe_fm` | +3 dB | Dynamic-preserving, no harmonic enhancement |
| **News / Talk** | `5_talk` | light | `speech` | off | `safe_fm` | +4.5 dB | Speech-optimized multiband + final stage |
| **Custom** | — | — | — | — | — | — | Sentinel — leaves all per-stage settings as you tuned them |

Pick once, tune as needed. The selected profile is stored as `format_profile_id` in the INI; switching profiles overwrites the per-stage settings to the new format's defaults (except `custom`, which is a no-op label).

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
- **Composite Clipper** — 16x oversampled differential composite clipper (threshold -1.0 dB, ceiling -0.3 dB, drive 6 dB). Oversampling factor is configurable (`mpx_clipper_oversampling`, default 16): 8 for older hardware that needs the CPU back, 32 for Omnia.9-class spec-sheet parity at roughly double this stage's CPU cost. See the comment block in the sample `MPXPrime.ini` for when each value makes sense.

Recommended **off** by default (enable only when needed):

- **Stereo Widener** — leave off unless the source program needs subtle width enhancement; aggressive widening risks mono-compatibility on FM (see "Stereo image control" below)
- **PrimeBass** — bass-enhancement harmonics; useful for thin source material, but adds harmonic content that competes with the audio composite headroom. Enable per-format.
- **Bass Clipper** — engage only when LF transients are pushing the chain past the downstream limiters; if PrimeBass is off, usually unnecessary.
- **HF Clipper** — pre-emphasis-aware HF clipper (`Processing` -> `HF Clipper`; `hf_clipper_*`). Off by default. Clips only the *pre-emphasised* high band (crossover default 5 kHz, threshold -3 dB, drive 1.2) so HF transients are tamed by a dedicated stage instead of forcing the broadband limiter to pull gain across the whole signal and dull it — de-emphasis-correct, since the receiver's fixed de-emphasis restores the curve. Worth trying on dense EDM / contemporary pop where HF transients dominate; leave off for talk / classical. Controls live-apply.
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
- `Composite Clipper` (`Processing` -> `Composite Clipper`): trades stereo image and HF cleanliness for raw loudness. Leave `Enable Composite Clipper` off when loudness is not the priority. If you do enable it, the per-band protection toggles let you choose what to keep clean:
  - `Protect Stereo Pilot`, `Protect Stereo Subcarrier`, `Protect RDS` — leave on (defaults). These keep the 19 kHz pilot, 38 kHz L-R subcarrier, and 57 kHz RDS regions clean of clip IM.
  - `Protect Audio Highs` — off by default for maximum loudness. Turn on to recover audible HF detail at the cost of some loudness when the clipper is driven hard.
  - `Multiband Composite Clipping` — off by default. It is an A/B loudness experiment for HF-heavy program material; current verifier numbers show useful peak/audio reduction, but it should stay out of presets until dense-program listening confirms the trade.

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

- `MPX Output Device` is the composite/baseband output device
- `Monitor Output Device (Decoded MPX Simulation)` is used when monitor output is enabled
- The orange microphone indicator in the macOS menu bar is the system privacy indicator and appears when MPX Prime Studio is actively using audio input
- `Mono Mode` now transmits true mono composite and suppresses pilot, stereo subcarrier, and RDS while enabled

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


## MPX Prime Meter (companion analyzer)

MPX Prime Meter is the receive/analyze counterpart to the encoder, shipped as
`MPX Prime Meter.app` in the same DMG. It takes an FM MPX composite, decodes
stereo + full RDS, and shows everything on one dashboard window. Use it to
check your own air signal, compare against other stations, or validate a chain.

### Launching

- Double-click `MPX Prime Meter.app`, or run `macOS/.build/release/MPXPrimeMeter --gui`.
- Headless terminal dashboards also exist: `./run-meter.sh` (audio-device input)
  and `./run-meter-sdr.sh --freq <MHz>` (RTL-SDR input).

### Window layout

The toolbar carries only the frequent commands -- **Start/Stop** (⌘Return),
the **Source** switch (Audio / SDR), and the **Monitor** toggle. The detailed
input settings for the selected source (audio device + channel, or SDR
frequency / AGC / gain) live in a translucent **input bar** directly below the
toolbar. The scopes, spectrum, vectorscope, and trend graphs are deliberately
dark instrument displays in both Light and Dark appearance (the convention for
audio/SDR instruments) so the traces stay legible; the surrounding window
chrome follows the system appearance.

### Input

The **Source** defaults to **SDR** when an RTL-SDR dongle is detected at launch,
otherwise to **Audio**.

- **Audio device** (`Source -> Audio`): pick the input carrying the composite
  and the channel (L / R / Mix). The Meter raises the device to 192 kHz on
  start and restores the prior rate on exit. RDS at 57 kHz needs a capture rate
  >= 128 kHz, so the default input prefers a 192 kHz-capable device.
- **RTL-SDR** (`Source -> SDR`): set the frequency and Start. The Meter decodes
  the dongle **in-process** -- it links the vendored tuner (a stripped subset of
  FM-SDR-Tuner, from `tuner/`) as a library and runs the RTL-SDR capture + FM
  demod on its own thread, delivering the mono MPX at 192 kHz with absolute
  calibration (full scale = 150 kHz). No helper process, no Homebrew, no
  separately-placed binary -- just a connected dongle. The librtlsdr / liquid-dsp
  dylibs ship inside the app. **SDR support makes MPX Prime Meter Apple-Silicon
  only** (the RTL-SDR libraries are arm64-only); the MPX Prime Studio encoder
  remains universal. (The headless `run-meter-sdr.sh` still uses an external
  `fm-sdr-tuner` piped over stdin.) Tested with **Rafael Micro R820T** and
  **Elonics E4000** tuner dongles; other librtlsdr-supported tuners (R828D,
  FC0012/0013, FC2580) should work but are untested.

  **SDRplay RSP** is also supported and **auto-preferred** when an RSP is
  attached (its 14-bit ADC and front end give cleaner audio, better separation,
  and a lower MPX-power noise floor than an RTL dongle). It needs SDRplay's API
  service installed (the SDRplay driver); the app loads it at runtime and falls
  back to RTL-SDR if it's absent. Tested on an RSPdx.

  When a dongle is attached at launch the Meter opens **already capturing** in
  SDR mode with audio monitoring on, so it comes up live. Every numeric control
  below (Frequency, Gain, **LNA**, **PPM**, and the **IF BW** menu) also steps on
  **mouse-wheel / trackpad scroll** while the pointer is over it -- no need to
  type or open the menu.

  All SDR controls apply **live** -- no restart, no audio gap:
  - **Frequency** -- retunes in place (also clears the prior station's meters).
  - **IF BW** -- the IF channel bandwidth. RTL shows the demod channel-FIR steps
    (Auto, or 56-311 kHz); **SDRplay shows the RSP's analog IF filter widths**
    (Auto = 600, or 1536 / 600 / 300 / 200 kHz). Narrower **rejects adjacent-
    station interference** but rolls off the composite top; 300 kHz still passes
    the full composite, 200 kHz starts to lose the top (SCA / high RDS). Start
    wide; narrow only to fight a strong neighbour.
  - **Auto Gain** -- automatic gain (RTL: tuner gain mode; SDRplay: AGC on the IF
    gain). Off reveals a manual gain field -- RTL tuner gain in **dB**, or the
    SDRplay **IF** gain.
  - **LNA** (SDRplay only) -- the front-end LNA gain-reduction step (0 = most
    gain), separate from the IF gain / AGC. Raise it to relieve front-end
    overload on strong broadcast signals. (SDRplay thus has both gain stages:
    LNA front-end + IF.)
  - **Antenna** (SDRplay only) -- selects the RSP antenna input (e.g. A / B / C
    on an RSPdx).
  - **Bias-T** -- 5V bias tee to power an active antenna / inline LNA (RTL-SDR v3,
    or RSP models that support it). Never feed it into a DC short.
  - **PPM** / **RTL AGC** (RTL-SDR only) -- ppm frequency trim, and the RTL2832
    digital AGC separate from the tuner gain.

### What it shows

- **Audio**: IN / L / R / M / S levels and L/R correlation.
- **Deviation**: pilot / RDS / total (MAX) deviation meters, on the top row
  beside the audio levels.
- **Modulation**: MPX power (ITU-R BS.412, ~60 s integrated, in dBr vs a
  +/-19 kHz sine); peak-hold +/- deviation (with Reset); best stereo
  separation. Also on the top row. MPX power and the +/- peaks turn amber near
  and red at/over the limit (0 dBr, 75 kHz). On SDR it also shows **SIGNAL** --
  a relative received-level (dBFS) RSSI indicator (green strong / red weak);
  most meaningful with Auto Gain off.
- **Vectorscope**: stereo goniometer (vertical = mono, tilt = single channel,
  horizontal spread = out-of-phase / mono-incompatible). On the second row,
  beside the trends.
- **Trends**: deviation (kHz) and MPX power (dBr) over ~60 s, with limit lines.
- **Scopes**: composite, decoded L, decoded R. Click a decoded scope to toggle
  it between waveform and its audio spectrum (0-20 kHz).
- **Spectrum** with band captions (Mono L+R, 19 kHz Pilot, Stereo L-R, 57 kHz
  RDS, 67.65 kHz, 92 kHz SCA). A **60 / 100 kHz** span toggle in the header
  picks the display range; 60 kHz (the default) focuses on the modulated bands,
  100 kHz shows the full baseband including SCA.
- **RDS**: PI / PTY (code + name) / PTYN / ECC / PS / RT / RT+ / Long PS / CT /
  AF / group histogram and live block-error rate (BER under ~5% is a clean link).

Deviation is referenced to a 75 kHz total; on a weak/noisy signal the
deviation/MPX-power path is band-limited to 60 kHz so the FM demod noise
triangle above the modulated bands doesn't inflate the readings.

### Recording

The input bar (right side) has a format toggle and a **Record** button. Choose:

- **Stereo** -- the decoded L/R audio (a clean, high-quality stereo capture of
  what the decoder produced).
- **MPX** -- the raw MPX composite (mono): pilot + L-R + RDS, the same signal
  the analyzer sees. Useful to re-analyze a capture later or feed another tool.

Press **Record** while capturing to choose a file and start; press it again to
stop and finalize. Files are 24-bit PCM WAV: **Stereo at 48 kHz**, **MPX at the
capture rate** (192 kHz for SDR -- the composite needs the bandwidth for the
pilot / subcarriers / RDS). They are written as canonical RIFF/WAV (no padding
chunks) so any audio player or FFT/analysis tool reads them. Recording is only
available while capturing.

### Calibration and measurement validity

**SDR needs no level calibration.** On the SDR path the deviation scale is a
fixed property of the FM discriminator (kHz per sample is set by math, not by
the tuner gain, AGC, or RF level), so amplitude maps directly to kHz with no
calibration step. Tuning to an unmodulated carrier is unnecessary -- and FM
broadcast has none anyway (even dead air carries the 19 kHz pilot). The
audio-device path, by contrast, is **pilot-referenced** (`pilot_ref_khz`,
default 6.75) because the analog input gain is unknown: it scales deviation by
assuming the 19 kHz pilot equals the reference value. Set the **Pilot Ref (kHz)**
field on the audio input bar to the source's actual pilot deviation -- 6.75 kHz
is 9%, but stations vary, and a pilot that is really 5.7 kHz read against 6.75
inflates every kHz value by ~18%. The control applies live (the SDR path ignores
it). Two caveats: (1) pilot-referencing only fixes the *overall* scale -- if the
source's composite output rolls off above the audio band, the 57 kHz RDS reads
low relative to the pilot no matter the reference, so use the SDR path for an
accurate RDS-injection figure; (2) the only frequency trim is **PPM** for precise
tuning; the sample-clock error scales readings by far less than 0.01% at any sane
ppm, so it does not affect deviation.

**MPX power is only valid on a strong, clean signal.** MPX power follows
ITU-R BS.412 (the limit -- average power over 60 s must not exceed that of a
sinusoidal tone at +/-19 kHz peak deviation) measured under the ITU-R SM.1268
conditions: roughly >= 73 dBf signal, >= 50 dB signal-to-noise, and no
multipath (a directional antenna is effectively required). On a weak, noisy, or
multipath RTL-SDR reception both the peak deviation and MPX power **read high**
-- that is a reception artifact, not over-modulation and not a calibration
error. Rule of thumb: if the peak deviation exceeds about +/-80 kHz and the
station is not genuinely over-deviating, the signal is too poor for a valid
BS.412 measurement. For reference, on a clean signal:

| MPX power | Peak deviation of an equivalent sine |
|-----------|--------------------------------------|
| 0 dBr     | +/-19 kHz (the reference)            |
| 3 dBr     | +/-27 kHz                            |
| 6 dBr     | +/-38 kHz                            |
| 10 dBr    | +/-60 kHz                            |


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

