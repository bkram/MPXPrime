# MPX Prime Studio -- Operator Guide

How to install, set up and run the encoder: audio devices, levels, picking a
sound, RDS, and what to watch while you are on air. The instructions name the
macOS app's controls; Linux operators do the same things on the web dashboard,
which mirrors the same layout.

Looking for something else?

- Every configuration key, the RDS text grammar, the now-playing script
  protocol and the REST API: [Settings and API Reference](studio-settings-reference.md).
- RDS country codes and programme types: [RDS Country Codes and Programme
  Types](rds-country-and-pty-tables.md).
- The companion analyzer: [MPX Prime Meter -- Operator Guide](meter-operator-guide.md).
- What the project is: [README](../README.md). Building, testing and the
  offline verification gates: [BUILDING.md](BUILDING.md). How the DSP chain
  works inside: [ARCHITECTURE.md](ARCHITECTURE.md).

## Which platform you are on

The encoder runs on two platforms with the **same DSP**; only the front end and audio backend differ:

- **macOS** -- the full **GUI application** (`MPX Prime Studio.app`), Core Audio, plus a headless `--nogui` mode. The companion **MPX Prime Meter** analyzer ships in the same DMG (macOS only -- see its [manual](meter-operator-guide.md)).
- **Linux** -- the **encoder only, headless** (`--nogui`, ALSA output, no GUI). Its interface is the built-in [web dashboard / REST API](#operating-it-from-a-browser). Installed from the Debian/Ubuntu package as the `mpxprime` systemd service (config at `/var/lib/mpxprime/MPXPrime.ini`). **There is no GUI and no Meter on Linux.** Setup: [BUILDING.md -> Linux (CLI-only)](BUILDING.md#linux-cli-only).

Everything in this guide applies to both platforms; where a control is GUI-only, Linux operators reach the equivalent on the web dashboard, which mirrors the same layout. Platform differences are flagged inline; at a glance:

| | macOS | Linux |
|---|---|---|
| Operator interface | GUI app (`MPX Prime Studio.app`); optional web dashboard | **Web dashboard / REST API only** (the package enables it on all interfaces behind a generated API key -- see Usage) |
| Audio backend and device keys | Core Audio; `*_device_uid` keys hold Core Audio UIDs, picked in the app | ALSA; `*_device_uid` keys hold PCM names (`default`, `hw:0,0`, `plughw:...`) |
| Default config file | `~/Library/Application Support/MPX Prime Studio/MPX Prime Studio.ini` | `~/.local/share/MPX Prime Studio/MPX Prime Studio.ini` (source build); `/var/lib/mpxprime/MPXPrime.ini` (Debian package) |
| Operating modes | MPX / FM / HD / AM Output, plus the decoded Monitor switch (GUI only, not in `--nogui`) | MPX / FM / HD / AM Output (no Monitor) |
| Companion analyzer / SDR | MPX Prime Meter (Apple Silicon only) | none |
| Offline gates | all `--verify*` modes, `--bench*`, the live smoke / A/B scripts (need BlackHole) | all `--verify*` modes and `--bench*` except `--verify-program-ab` (needs AVFoundation); no live scripts |

The same INI keys, presets, RDS features and verifier thresholds apply on both; a config file moves between platforms once the device keys are re-pointed.

## Installing and starting

**macOS.** Launch MPX Prime Studio from `/Applications` (or wherever you copied it). On first run,
grant input access when macOS prompts -- this is required to capture audio. Then
pick your input and MPX output devices in the app and start the engine.

Command-line flags (run the binary inside the app bundle):

```bash
"/Applications/MPX Prime Studio.app/Contents/MacOS/MPXPrime" --nogui       # headless, no UI
"/Applications/MPX Prime Studio.app/Contents/MacOS/MPXPrime" --seconds 10  # run for a fixed time then exit
"/Applications/MPX Prime Studio.app/Contents/MacOS/MPXPrime" --config "/path/to/MPX Prime Studio.ini"
"/Applications/MPX Prime Studio.app/Contents/MacOS/MPXPrime" --web         # headless + web dashboard
```

**Linux.** There is no GUI: the web dashboard is the only operator interface,
and the package sets it up so a headless box is configurable from another
machine right after install. `dpkg -i` installs `/usr/bin/mpxprime` and a
`mpxprime` systemd service (its unit runs the encoder with `--web`), and on a
fresh install it creates the config `/var/lib/mpxprime/MPXPrime.ini` from the
code defaults with the dashboard **enabled on all interfaces behind a randomly
generated API key**. The installer prints that key once; it is stored in the
INI, so you can always read it back:

```bash
sudo dpkg -i mpxprime_*.deb                        # prints "web dashboard API key: ..."
sudo systemctl enable --now mpxprime               # encodes into ALSA `default`
sudo grep control_api_key /var/lib/mpxprime/MPXPrime.ini   # the key, any time later
```

Then open `http://<host>:8737/` from any machine on the network and paste the
key when the dashboard asks for it (it remembers the key in that browser).
Everything else -- devices, operating mode, levels, processing, RDS -- is set on
the dashboard and persists in that INI. To rotate the key, edit
`control_api_key` in the INI and restart the service; to keep the dashboard
local only, set `control_bind = 127.0.0.1`. An existing INI is never touched
by an upgrade. The server speaks plain HTTP; on an untrusted network front
it with a TLS reverse proxy (see
[Remote control](#operating-it-from-a-browser)). To run by hand
instead of as a service: `mpxprime --web --config /path/to/MPXPrime.ini`
(`--web` implies `--nogui` and forces the server on; bind, port and key still
come from the INI). Devices are ALSA PCM names (`default`, `hw:0,0`,
`plughw:...`), not Core Audio devices; the Monitor operating mode does not
exist on Linux.

To build, run, verify, test, or package from source, see
[docs/BUILDING.md](BUILDING.md).

## First-time setup in five steps

This is the minimum to hear MPX Prime Studio processing your audio and feeding a transmitter / SDR / loopback. Defaults are tuned to sound good out of the box -- the chain ships processing-on with AGC, multiband, bass clipping, and the composite clipper engaged.

**1. Plug audio in and out.** MPX Prime Studio reads from a Core Audio input device and writes the composite (MPX) signal to a Core Audio output device (on Linux: ALSA PCM devices, selected on the web dashboard's Audio I/O page or by name in the INI). Typical setups:

- Soundcard input from your studio mixer / streaming source -> soundcard output into an FM exciter that accepts MPX baseband.
- BlackHole 2ch (virtual loopback) input from a music player or DAW -> soundcard output into an SDR transmitter or RF generator.
- Test tone source (built-in) -> output to verify metering and routing without external audio.

192 kHz output is **required for the full composite with RDS.** RDS sits at 57 kHz, which exceeds the 48 kHz Nyquist of 96 kHz sample rates -- the RDS subcarrier cannot be represented at 96 kHz or below. 96 kHz is just enough to carry the FM stereo composite alone (M + 19 kHz pilot + 38 kHz DSB-SC stereo subcarrier) provided the audio bandwidth is limited so the upper L-R sideband doesn't push past 48 kHz; pilot-locked stereo decoding works, but disable RDS at this rate. Below 96 kHz the stereo subcarrier itself doesn't fit. 192 kHz is the recommended rate for everything because it gives Nyquist headroom for the post-clipper pilot/RDS injection plus the oversampled peak-control stages the chain runs above the host rate.

> **External sound card required for RDS.** Apple's built-in audio output on Mac laptops and most desktops tops out at **96 kHz**, which cannot carry RDS -- the 57 kHz subcarrier exceeds 48 kHz Nyquist. For any FM-with-RDS chain you need a USB / Thunderbolt audio interface that natively runs at **192 kHz**. Most pro and prosumer interfaces (RME, MOTU, Focusrite Scarlett 3rd-gen+, Apogee, etc.) support 192 kHz on at least the analog or AES outputs -- check the spec sheet before ordering. The internal Mac speakers / headphone jack are fine for *listening to a test tone* through MPX Prime Studio, but they cannot be the production output if RDS is in play.

### Preparing the audio devices (macOS Audio MIDI Setup)

macOS configures Core Audio device parameters via **Audio MIDI Setup** (`/Applications/Utilities/Audio MIDI Setup.app`). MPX Prime Studio tells the engine what rate it wants, but the device-side format and volume are owned by the OS -- wrong values there silently corrupt the composite before it leaves the Mac.

**Output device** (feeding your exciter / SDR / RF generator):

1. **Format / sample rate**: set to **192 000 Hz**. Match what the engine is configured to (`sample_rate = 192000` in INI). If the device runs at a different rate Core Audio inserts a sample-rate converter that cannot represent the upper composite band cleanly. **Required for RDS** -- the 57 kHz RDS subcarrier needs at least ~119 kHz Nyquist; 176.4 kHz is the lowest device rate that carries it correctly, 192 kHz is the canonical default. On start MPX Prime Studio now **sets the output device to the configured rate itself** (and restores the device's prior rate on stop); if the device can't run that rate it surfaces a routing note telling you to set it in Audio MIDI Setup, rather than letting Core Audio quietly resample.
2. **Bit depth**: **24-bit integer or 32-bit float**. Either is fine; 32-bit float is the AVAudioEngine native format. 16-bit also *works* for the composite (96 dB SNR is well above any FM receiver's noise floor and you cannot hear the difference at the listener), but 24/32-bit is best practice -- no extra dither/truncation step at the chain output, and headroom for downstream tools that further process the composite (resamplers, SDR DSPs).
3. **Volume / output gain**: **100 % (0 dB) on every channel**. This is the critical one. The macOS volume slider is post-mix -- it scales the engine's already-finalised composite. If output volume is at, say, 75 %, the FM exciter receives a signal at 0.75x amplitude and your modulation undershoots by ~2.5 dB; the loudness target the chain just enforced is silently wrong. Audio MIDI Setup -> device -> "Master Stream" or per-channel volume sliders. Lock these at unity for any broadcast use.

**Device selection is remembered by UID and name.** Each selected input / output / monitor device is stored by its Core Audio UID *and* its name (`input_device_uid` / `input_device_name`, etc.). At launch the device is matched by UID first, then by name -- so moving a USB interface to a different port (which can change its UID) still re-finds the same device. If a remembered device is simply unplugged, MPX Prime Studio **keeps** your selection (and shows a status note) instead of silently switching to whatever device is first in the list; reconnect it, or pick another.

**Input device** (your audio source -- interface, BlackHole loopback, or built-in audio):

1. **Format / sample rate**: **48 000 Hz, 24-bit** is the recommended sweet spot. The reason is the dual-rate audio chain (default-on since 0.30) -- the entire audio domain (multiband, AGC, EQ, image protection, pre-emphasis, pre-encode limiter) runs at 48 kHz internally, then upsamples to the MPX rate at the stereo encoder boundary. Setting the input device to 48 kHz means the source audio passes into the audio domain without any Core Audio upsampling on the way in (no information gain from higher input rates anyway -- audio source material has zero useful content above ~20 kHz). 44.1 kHz also works fine; Core Audio's input-side SRC handles the small upsample to 48 kHz cleanly.
2. **Bit depth**: **24-bit** is recommended. 16-bit is fine for the audio itself, but the chain runs in 32-bit float internally through many stages and 24-bit input keeps the noise margin below the audible threshold even under hot processing.
3. **Volume**: per-device -- set whatever produces a sensible input level on the `IN L/R` meter at the top of the app. Aim for peaks around -12 to -6 dBFS on the input meter so the wideband AGC has something to work with.

If your output device is BlackHole or a virtual loopback, the same rules apply -- check both the loopback device's format and the receiving app's input format. Mismatch there is the #1 cause of "the chain looks right but the receiver sounds wrong" reports.

**2. Set your region.** Pre-emphasis differs by region:

- **USA / Canada / South Korea**: 75 us
- **Everywhere else (EU, ROW)**: 50 us (current default)

Open `Processing` -> `Core` and change `Pre-emphasis` to `75` if you are in a 75 us region. Wrong pre-emphasis will sound either dull (50 into 75 deemph) or shrill / over-modulated (75 into 50 deemph). The curve itself is matched to the analog network within 0.05 dB up to 15 kHz, and since 0.45 the whole chain's receiver-side response follows it within 0.5 dB to 14 kHz -- earlier builds were 1-3.5 dB low above 10 kHz at the receiver (a limiter decimation filter and the digital pre-emphasis approximation both rolled off the top of the band), so a station that added treble EQ to compensate should re-check that EQ after upgrading. EU operators required to comply with ITU-R BS.412 should also enable `Processing` -> `BS.412`. Every setting referenced in this guide is also reachable from the GUI; the INI is written automatically and is mainly there for inspection or out-of-band edits.

**3. Launch and Start.** Open MPX Prime Studio, pick your input and output devices in the sidebar's `Audio I/O` section, then press `Start` (Cmd-Return) on the toolbar. The status bar at the top of the window shows live IN L/R, MPX peak, deviation in kHz, modulation as a percentage of the configured deviation target (MOD), gain reduction, safety-limiter GR, composite budget, and pilot/RDS injection -- if those move with your audio, the chain is processing.

**4. Calibrate composite output level.** On `Monitoring`, watch the `Composite Budget` chip:

- **Safe**: nominal modulation, headroom available
- **Tight**: near 100% modulation, fine for normal broadcast
- **Risk**: peaks exceeding 100% -- back off `MPX Output Level` on the `Audio I/O` Output card

`Final Drive` (on the `Final Stage` tab) controls perceived loudness; `MPX Output Level` (on the `Audio I/O` Output card, remembered per device) calibrates the final voltage to your exciter / SDR. Use `Final Drive` for loudness and `MPX Output Level` only for hardware calibration.

**5. Verify on a receiver.** Tune a real FM radio or RTL-SDR to your transmitter's frequency. You should hear stereo audio with a steady stereo-pilot indicator, see RDS PS and Radiotext on the radio's display (if your radio supports RDS), and the audio should sound louder and more present than the same source through `mpxgen` / PiFmRds.

If you cannot hear anything, check `Audio I/O` -> output device routing, that the engine is started, and that `Processing` -> `Core` -> `Bypass Processing` is **off** (the default).

### Choosing a block size

`Audio I/O` -> `Engine` -> `Block Size` (`blocksize` in `[INTERFACES]`, 256..8192 frames). The DSP itself does not depend on it -- the composite rendered in 64-, 480-, 1024- or 8192-frame blocks is bit-identical to 512 (pinned by a test) -- so the choice is only about latency versus dropout safety. Round-trip I/O latency is two blocks: at 192 kHz, 256 = 2.7 ms, 512 = 5.3 ms, 1024 = 10.7 ms, 2048 = 21 ms, 4096 = 43 ms, 8192 = 85 ms. Measure your machine with `--bench-blocks` on a release build: it reports the worst single block's render time as a fraction of that block's duration (100% = a dropout) -- keep at least 2x margin. On an Apple M1 Pro with the full chain the worst block is 17% at 512 and 23% at 256, so **512 is the recommended setting on Apple Silicon** (the shipped default is 1024, safe on every machine; 256 works on Apple Silicon if you need the latency; 64 is marginal at 46%). Intel and small Linux boxes (the fanless Celeron runs the chain near 92% of real time) want 1024-2048. Two hardware caveats: CoreAudio devices clamp the buffer to their own range and the engine logs "clamped HAL buffer" when that happens (the built-in output allows 15..4096, so 8192 is never honoured there), and many USB interfaces glitch below 256 regardless of CPU headroom.

## Where your settings live

Default config location (the same INI format and keys on every platform; `--config <path>` overrides, and the resolved path is printed at startup):

| Platform | Default config file |
|---|---|
| macOS (GUI app or `--nogui`) | `~/Library/Application Support/MPX Prime Studio/MPX Prime Studio.ini` |
| Linux, run by hand from a source build | `~/.local/share/MPX Prime Studio/MPX Prime Studio.ini` |
| Linux, Debian/Ubuntu package (`mpxprime` service) | `/var/lib/mpxprime/MPXPrime.ini` |

The per-device calibration memory (`<config>.devicecal.json`) and the preset slots (`<config>.snapshots.json`) live next to the INI on all three.

Relevant config sections:

- `INTERFACES`: input/output/monitor device UIDs, source mode, monitor enable, block size
- `MPX`: processing, levels, stereo coding, limiter behavior
- `RDS`: program service, radiotext, flags, carrier settings

## The Audio I/O section: devices, operating mode, level calibration

The sidebar's **Audio I/O** section (on Linux: the web dashboard's **Audio I/O** page) is the installation page: where the signal enters and leaves the app. It holds the input / MPX output / monitor device pickers, the **Operating Mode** (one segmented four-way choice, `operating_mode`: MPX Output for a transmitter, FM Output for an external stereo coder, HD Output for streaming or digital radio, AM Output for an AM transmitter -- plus the Monitor switch under MPX Output, which decodes the composite back to speakers so you can audition the FM sound with no transmitter), the engine format (sample rate, block size, auto start), and the three **level calibration** controls: `Input Gain` on the Input card, `MPX Output Level` + `Line Output` (with a live **DAC Peak** readout) on the Output card. **Monitor is GUI-only**: headless runs (`--nogui` / `--web` on macOS, and the whole Linux build) offer all four operating modes, ignore `monitor_enabled = True`, and the ALSA engine has no monitor device.

Calibration is deliberately separated from the DSP tabs because it belongs to the RIG, not the sound -- and it is **remembered per device** (`<config>.devicecal.json` next to the INI): switch the output from one exciter to another and each device's own MPX Output Level / Line Output come back automatically (input devices remember their Input Gain; output levels are kept per operating mode). A device that was re-plugged into a different USB port is matched by name. Format Profiles, presets, and per-tab resets never touch these values, and loading a preset keeps this installation's devices, mode, calibration, and control-server settings (see Presets below).

Two readouts, two domains: the **deviation** meter is a modulation-domain figure -- `output_gain_db` and `mpx_line_output_dbfs` are divided back out, so it reads the same kHz regardless of how the exciter drive is trimmed (before 0.50 it under-read by exactly the output trim). **DAC Peak** is the electrical figure -- the level actually presented to the converter, post both trims. Calibrate deviation at the exciter; watch DAC Peak to know how hot the wire is.

## Setting levels: input, AGC, Final Drive, exciter

Three knobs do most of the work between your source and the exciter. They sit at three different points in the chain and each does a specific job -- get them right in order and the chain sounds clean without much fiddling.

**The chain (left to right):**

```text
source -> IN meter -> AGC -> [DSP] -> Final Drive -> composite clipper -> MPX Output Level -> Line Output -> exciter
                  ^                ^                                 ^                  ^
                  level control    loudness lever                    deviation trim     DAC calibration
```

**1. Get your input into the AGC's working range.** Open `Monitoring`. The `IN` meter shows the level coming into MPX Prime Studio from your source (before any processing). Aim for input peaks landing roughly in the **-12 to -6 dBFS** range on busy program -- bright but not pinned. If the source is consistently below -18 dBFS the AGC has to push hard to reach its target; if it's above -3 dBFS it's eating its own headroom before the chain even sees it.

The level adjustment lives upstream of MPX Prime Studio -- in your studio mixer, DAW, OS audio output, or BlackHole loopback source's gain. There's also `Audio I/O` -> `Input` -> `Input Gain` (+/-24 dB) inside MPX Prime Studio, but use that only to trim -- the further upstream you fix the level, the less you stack noise floors. The trim is remembered per input device.

**2. Let AGC do the level-evening.** Open `Processing` -> `AGC`. The AGC's job is to ride out the long-term level differences between songs / shows / sources so the chain downstream sees a roughly constant program level. The two knobs that matter:

- `Platform Target` -- the level the AGC drives the program *toward*. **Default -14 dBFS** (`wideband_agc_target_db`) is a good starting point and matches what Orban / Omnia / Stereo Tool ship by default. Lower target = AGC pulls more, denser sound; higher = lighter touch.
- `Enable Wideband AGC` -- leave on. Even amateur source material (mixed-era MP3s, podcasts, vinyl rips) needs level-evening; without AGC, single-band peak limiting downstream pumps on bass-heavy program. Keep `Attack` at 100 ms or slower (default 150 ms, profiles 100-200 ms): the AGC is a gain rider, and a fast attack turns every drum hit into a level dip that the release then drags out -- peaks are the Audio Limiter's and composite clipper's job. `--verify` flags an attack below 50 ms.

Watch the `AGC GR` field in `DSP Overview` (or the AGC card itself). Healthy operation:

- **0 to 3 dB occasional pulls** = source feeding cleanly, AGC riding lightly. Goal state.
- **Sustained 6+ dB pulls** = source is too hot. Back off upstream.
- **AGC pushing 6+ dB consistently (positive gain)** = source is too quiet. Boost upstream.
- **AGC parked at min/max gain limit** = source is so far off the AGC can't keep up -- fix the source level.

Don't use AGC `Platform Target` as a loudness knob. It tunes the chain's working point, not perceived broadcast loudness.

**3. Set Final Drive for the loudness you want.** `Processing` -> `Final Stage` -> `Final Drive` is the primary loudness lever. It drives the audio composite into the composite clipper -- higher drive = harder clipping = louder, denser, but also harsher. Range 0..12 dB.

- Pick the `Broadcast Preset` matching your content (Balanced Music / CHR-Dance / Punchy / Speech-Talk) -- that sets a sensible Final Drive starting point along with matched AGC tuning.
- Nudge from there. Watch the **composite clipper `GR`** in `Monitoring`:
  - 0 to 3 dB occasional GR = clean, dynamic. Good for talk and acoustic music.
  - 3 to 6 dB regular GR = competitive loudness, contemporary radio sound.
  - Sustained 6+ dB = clipper is the loudness ceiling, you're trading dynamics and HF cleanliness for level.

Final Drive is not the same thing as MPX Output Level. Final Drive shapes loudness *inside* the chain; MPX Output Level and Line Output adjust the *voltage* leaving the Mac.

**4. Calibrate the exciter on the Audio I/O Output card.** Two knobs, both remembered per output device:

- `MPX Output Level` (-18..0 dB, attenuation-only in composite mode) trims the whole composite -- pilot and RDS included -- so it is the **deviation calibration**: with the exciter's own input sensitivity fixed, trim it until the exciter shows exactly 100 % modulation (75 kHz) on peaks. Positive values are deliberately not offered: they would squeeze the audio budget (deeper clipping) and push pilot/RDS above their set injection without adding loudness.
- `Line Output` (-40..0 dBFS) sets the absolute DAC level of 100 % modulation -- the **input-sensitivity match** to the exciter. Keep the OS/interface volume at 0 dB and calibrate here. 0.0 dBFS is the classic full-scale convention and the maximum a converter can produce; an exciter that is still under-driven with both knobs at 0 needs its own input sensitivity raised (menu/trimmer) -- no software knob can exceed full scale.
- Watch the **DAC Peak** readout on the same card (the post-both-trims level at the converter) and the `Composite Budget` chip on `Monitoring`:
  - **Safe** -- nominal modulation, headroom available
  - **Tight** -- near 100 % modulation, fine for normal broadcast
  - **Risk** -- peaks exceeding 100 %, back off
- On the exciter side: aim for **100 % modulation on peaks** on its modulation meter, or match the input-level recommendation in its manual. *Don't* use these knobs to chase loudness -- that's Final Drive's job.

The deviation readout stays put while you calibrate: it reads the modulation domain (the trims divided back out), so trimming exciter drive changes DAC Peak and what the exciter sees, not the displayed kHz.

**Scripted version with an RTL-SDR** -- `scripts/calibrate-tx.sh --freq <MHz>` (repo root) closes this loop automatically against an off-air measurement: it reads the configured pilot injection over the REST API (start Studio with the control API on), measures the actual pilot deviation with an RTL-SDR through MPX Prime Meter's analysis (refusing railed captures and applying a proper channel filter), and trims `output_gain_db` until they agree -- the pilot is constant-amplitude, so this works with program on air. Because the output gain is attenuation-only in composite mode, a transmitter that under-deviates at full scale is reported as "raise the exciter's input sensitivity by N dB" rather than silently mis-calibrated; `--watch` prints a fresh measurement every few seconds so you can turn the exciter's trimmer until the error reads 0.0. `--dry-run` measures without changing anything. `--tone` switches Studio to the built-in test tone (a mono 997 Hz sine at -20 dBFS, the 0.45 calibration source) for the duration of the run and restores the program source on exit -- dense program puts pre-emphasized HF next to the 19 kHz pilot and wobbles the measurement by about +/-0.1 dB between passes, while with the tone repeat passes agree to a few hundredths of a dB.

The same measurement also verifies the RDS injection end to end: if the reported `rds` kHz sits below `rds_level`, the DAC/exciter path is rolling off toward 57 kHz (the 19 kHz pilot is unaffected, so pilot calibration does not correct it). The dependable fix is to raise `rds_level` by the measured ratio so the ON-AIR injection lands on the intended value -- a restart-class key, so restart the transport and re-measure to confirm.

**Common mistakes:**

- Driving Final Drive hard while MPX Output Level is low -> audio sounds limited but exciter is under-modulated -> quiet on-air. Check the modulation meter.
- Cranking MPX Output Level for loudness -> exciter over-modulates -> splatter / distortion / regulatory issues. Final Drive is the loudness knob.
- Source too quiet -> AGC pushing 8+ dB -> noise floor lifts, breathing on quiet program. Boost upstream.
- AGC off / bypassed -> multiband and final stage see widely-varying program levels -> pumping on dense material. Leave AGC on.

## Picking a Format Profile

For one-click "make this sound right", MPX Prime Studio ships four complete Format Profiles plus a `Custom` sentinel, on the **Processing -> Format Profile** tab. Since the 2026-08 rework a profile owns the FULL chain state -- not just tonal color: every profile enables the AGC, the pre-encode Audio Limiter, the composite clipper (with 2 ms look-ahead) and the final safety limiter, then sets the format-appropriate multiband / PrimeBass / mono bass / drive on top (every profile also enables the HF Limiter; Music - Loud adds the Bass Clipper). Picking a profile can never leave the always-on safety soft-clips as the de-facto peak controller (the failure mode of the old 8-profile set). Per-stage knobs stay editable afterwards; pick `Custom` to flag "my settings are bespoke".

**Upgrading from a pre-0.45 config.** An INI that still carries one of the old profile ids (`chr_top40`, `pop_ac`, `community_radio`, `rock`, `edm_dance`, `urban_hiphop`, `jazz_classical`, `news_talk`) is **reset on load**: its processing (`[MPX]`) is rebuilt from the nearest new Format Profile (`chr_top40` / `rock` / `edm_dance` / `urban_hiphop` -> Music - Loud, `community_radio` / `pop_ac` -> Music - Clean, `news_talk` -> Speech, `jazz_classical` -> Classical), while **RDS, interfaces (devices, sample rate, block size), the control server and the hardware calibration keys (pilot level, deviation, MPX output level, output gain, pre-emphasis, mono mode, test tone) are kept exactly as they were**. The reset config is saved back to disk and both apps say so at startup (status bar in Studio, a line on stderr headless). Reason: those configs typically had the Audio Limiter and Composite Clipper off with the safety soft clips doing all the clipping -- the hi-hat / cymbal distortion field finding -- and carrying that forward under a new label would keep the station distorting. If a current-profile config still has both peak controllers off, the apps warn (but do not reset); re-apply a Format Profile or enable the Composite Clipper.

| Profile | Character | AGC target | Drive | Extras |
|---|---|---|---|---|
| **Music -- Clean** (default) | Transparent leveling, honest peaks, low clipper work | -16 dB | +4 dB | -- |
| **Music -- Loud** | Competitive loudness into the clipper | -15 dB | +8 dB | HF Limiter + Bass Clipper, PrimeBass, mono bass at 115 Hz |
| **Speech / Talk** | Voice-optimized | -16 dB | +4.5 dB | Phase rotator on |
| **Classical / Wide Dynamics** | Dynamic-preserving | -18 dB | +3 dB | Light multiband, gentle limiter |

Pick once, tune as needed. The selected profile is stored as `format_profile_id`; switching profiles overwrites the per-stage settings to the new profile (except `custom`, a no-op label). Assume a nominal input level around **-12 dBFS** (pro line-up convention) -- the AGC absorbs source variation from there; 0 dBFS masters work but arrive with no headroom of their own.

## Loudness and the final stage

The `Processing` -> `Final Stage` tab contains the workflow-level loudness controls (Broadcast Preset, Final Drive, Composite Deviation) and the **Final-MPX Safety Limiter** card (Enable, Threshold, Look-Ahead enable + ms -- restart-required). The `Audio Limiter` tab handles the pre-encode peak limiter on its own.

- `Broadcast Preset`: loads a matched AGC + final-stage starting point
- `Final Drive`: drives the composite clipper harder or softer
- `MPX Output Level`: final output calibration, not the main loudness control

**How the final stage controls peaks (0.45).** The composite clipper is the loudness stage; its `Threshold` and `Ceiling` (Composite Clipper tab, `mpx_clipper_threshold_db` / `mpx_clipper_ceiling_db`) are read against the *audio-composite budget* -- the part of the composite left after the pilot and RDS reservation -- with the Ceiling landing exactly on that budget, so the composite uses all of it and your calibrated deviation does not move. Behind the clipper, the Final-MPX Safety Limiter (look-ahead) rides down the small in-band overshoot the clipper's pilot / stereo / RDS guard protection leaves (about 1 dB of gain riding on the densest program is normal), and the always-on safety soft-clips sit idle behind both -- since 0.45 the limiter's detector looks at every sample inside its 5 ms window, so nothing above its threshold reaches the soft-clips and the `SAFETY CLIP` readout stays at 0.0 on dense program (earlier 0.45 builds leaked up to about 1 dB there while the limiter reported almost no gain reduction). Before 0.45 the soft-clips ran ahead of the clipper at a lower threshold and did all the clipping themselves -- the cause of the hi-hat / cymbal distortion field report; `--verify-hf-transients` measures that this is no longer the case.

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

Both stages are loudness / regulatory tools and both visibly cost stereo image and high-frequency detail when engaged. If you do not need them, leave them off -- the chain still produces a fully compliant FM composite.

- `BS.412` (`Processing` -> `BS.412`): only required if you operate under EU power-limiting rules (rolling 60-second MPX power cap). Outside that regulatory context, leave `Enable BS.412` off -- it actively pulls level back over long windows and dulls dynamics.
- `Composite Clipper` (`Processing` -> `Composite Clipper`): trades stereo image and HF cleanliness for raw loudness. Leave `Enable Composite Clipper` off when loudness is not the priority. If you do enable it, the per-band protection toggles let you choose what to keep clean:
  - `Protect Stereo Pilot`, `Protect RDS` -- leave on (defaults). These keep the 19 kHz pilot and 57 kHz RDS regions clean of clip IM.
  - `Protect Stereo Subcarrier` (`mpx_clipper_stereo_guard`, 0.00-1.00; since 0.45 a share instead of an on/off toggle, the old `mpx_clipper_cancel_stereo = True/False` is read as 1.00/0.00) -- how much of the clipper's distortion is kept out of the 22-53 kHz stereo (L-R) subcarrier. At 1.00 the subcarrier passes exactly as it went in, so HF stereo separation is preserved but the clipper only ever removes the mono share of a peak and the Final-MPX Safety Limiter rides whatever overshoot that leaves. At 0.00 the clipper clips the whole composite the way Orban, Omnia and Stereo Tool do: the most loudness per dB of drive and the least HF separation on dense program. Values in between blend. The shipped default (1.00) is picked from the `--verify-stereo-guard` sweep (see Verification), which prints clipper and Final-MPX limiter duty, peak, deviation, 10 / 14 kHz separation, the encoder-side M/S balance at 14 kHz and the hi-hat / ride HF SINAD for every share: on Music - Loud the share makes no measurable difference, and on a hot chain 1.00 buys about 3 dB of decoded hi-hat cleanliness for about 5 dB of 14 kHz tone separation. Run the sweep on your own INI before moving the slider.
  - `Protect Audio Highs` -- off by default for maximum loudness. Turn on to recover audible HF detail at the cost of some loudness when the clipper is driven hard.

All of these are exposed in the GUI; no INI editing is required.

## Bass and stereo image

Mono Bass lives on the `Processing` -> `PrimeBass` tab (its own card below the PrimeBass controls -- both are post-multiband bass-domain image controls): it collapses low-frequency side energy below a configurable crossover, protecting deviation and FM mono compatibility. Every shipped Format Profile keeps it on (140 Hz for Clean / Speech / Classical, 115 Hz for Loud). The stereo widener that used to share a tab with it was **removed in 0.50** -- measured on air as adding nothing beneficial; the always-on stereo-image protection stage (which used to scale with the widener's Width) keeps its former default behaviour. An INI that still carries `stereo_widen_*` keys loads fine; they are ignored.

Recommended starting point:

- `Mono Bass`: on
- `Bass Mono Freq`: `110-140 Hz`

This keeps bass more mono-compatible while leaving the upper image open enough for FM.

### PrimeBass and multiband

The current low-frequency enhancement and multiband stages are now tuned more conservatively than earlier builds.

- `PrimeBass` adds perceived bass weight by synthesising controlled harmonics of low-frequency content. The listener hears more bass without the chain having to push LF peaks higher, which saves headroom for the rest of the dynamics chain.
- `Multiband` uses linear-phase Kaiser-windowed FIR crossovers in TX mode (parallel-cumulative-LP topology, sum-to-flat at `-155 dB`), so percussive transients land time-aligned across all bands and the recombined signal only changes spectral balance when the band gains move -- not when bands fall out of phase. Monitor mode keeps the IIR Linkwitz-Riley 4 cascade for low latency. Since 0.45 each crossover sits at exactly -6 dB with a slope of about half an octave to -40 dB (steeper than a Linkwitz-Riley 4, far gentler than the near-brick-wall edges of earlier builds), and the crossovers cost 9.3 ms of processing latency at the 48 kHz audio domain instead of 21 ms. Both 3-band and 5-band modes are supported. INI key `multiband_fir_enabled` toggles the FIR path (default on). Two advanced options are default-off while being evaluated: `multiband_transient_aware_attack_enabled` for peak/RMS transient handling, and `multiband_inter_band_coupling_enabled` for low-band-GR-driven upper-band threshold bias. `multiband_release_program_dependent` (default on) gives each band a dual-slope release since 0.45: a drum hit's extra gain reduction comes back at the band's release time (no hole after the hit), while a genuine drop in average level releases three times more gently (no breathing when a chorus ends); earlier builds only lengthened the release by 10% under this flag.

Recommended starting point:

- `PrimeBass`: `AC/Pop` or `Rock` preset first
- `Multiband`: `5B AC/Pop` for general music, `5B Talk` for speech, `5B CHR/EDM` for a denser contemporary result, `5B Italo` / `3B Italo` for italo / disco / dance pumping character

The current defaults are intentionally moderate and are meant to be tuned upward from a clean starting point, not downward from a hyped one.

## Advanced Dynamics (experimental)

`advanced_dynamics_enabled` (default `False`) replaces the wideband AGC **and** the multiband compressor with one fused 5-band leveling stage. The point of the fusion is that slow leveling and per-band density shaping can no longer fight each other (the classic AGC-pulls-down-while-multiband-pushes-up pumping); each band rides toward a target level with program-adaptive speed -- near-instant on transients, frozen when the band already sits at target, slower on dense material. You configure the sound you want instead of attack/release times:

- `advanced_dynamics_target_db` (default `-16.0`) -- the level every band is brought toward.
- `advanced_dynamics_low_offset_db` / `advanced_dynamics_mid_offset_db` / `advanced_dynamics_high_offset_db` (defaults `0 / -3 / -9`) -- tonal balance anchors relative to the target; the 5 bands interpolate between them (the same low/mid/high anchor scheme the multiband compressor uses).
- `advanced_dynamics_max_gain_db` (default `12.0`) -- maximum lift for quiet program (the reduction side is fixed at 24 dB). The default was lowered from 18 after field testing: high boost both chases natural fades harder and lowers the silence gate (`target - max_gain - 10 dB`), pumping tails on sparse material. Raise it deliberately for wide-dynamics formats.
- `advanced_dynamics_density` (`0..1`, default `0.5`) -- denser = tighter hold window and faster leveling.
- `advanced_dynamics_speed` (`0.25..4`, default `1.0`) -- overall time-constant scale.

A built-in **decay guard** distinguishes "program actively fading" from "program is quiet": while a band's envelope sits well below its recent peak (a note or song decaying naturally), the leveler holds instead of lifting, resuming when the level stabilizes or new material arrives. Without it a solo decaying sound (a bell, a fade-out) gets its fade flattened and extended -- heard as added ringing/sustain.

Band layout follows `multiband_x1_hz..multiband_x4_hz`. All keys are live-apply. When the stage is enabled the AGC and Multiband settings are ignored (those stages are bypassed); when it is disabled the chain is bit-identical to before the stage existed. It is evaluated with `--verify-advanced-dynamics` and must pass program-material A/B plus listening before any preset enables it.

In the GUI the stage lives at `Processing -> Adv Dyn` (sidebar entry "Advanced Dynamics", between Multiband and Expander, with a card on the Processing Overview grid); in the web dashboard it has its own "Advanced Dynamics" page.

While the stage is active, the Monitoring dashboard's Signal Chain "AGC" pill switches identity to **Adv Dyn** and reads the leveler's density plus its five per-band gains (low to high, dB); the web dashboard's Headroom card gains the matching "Adv Dynamics" row. The AGC readouts honestly report the AGC as Off (gain 0.0) while it is bypassed -- the leveler replaces it, so a moving "AGC gain" would be stale telemetry. Over the API the same values are `advancedDynamicsActive`, `advancedDynamicsBandGainsDB` (5 floats, low to high), and `advancedDynamicsDensityDB` in `GET /api/meters` (null while the stage is off).

While the stage is enabled, both UIs ghost the stages it replaces: the AGC, Multiband, Expander, and MB Limiter tabs/cards dim, their controls disable, a "bypassed" banner links back to Advanced Dynamics, and the sidebar/overview enabled-dots show the EFFECTIVE state (off while bypassed). The stored flags are untouched -- disabling Advanced Dynamics restores the exact previous AGC/Multiband behavior. A test pins the bypass as total: with the leveler on, extreme AGC/multiband settings produce bit-identical output to having those stages off.

## Saving setups: the eight preset slots

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

Since 0.50, **loading a preset restores the sound, not the wiring**: this
installation's device selections, sample rate / block size, operating mode,
the three level-calibration values (input gain, MPX output level, line
output), and the control-server settings are kept from the live config --
a colleague's preset can no longer retarget your transmitter feed, wreck a
per-rig calibration, or (loaded over the REST API) turn off the very
control server it arrived through. Saves and exports remain complete
configs, so an exported slot is still a full `--config` file; the filter
applies only when a slot is loaded into the live config. Device or
calibration changes after a load do not flip the "edited" marker -- they
are not part of a preset's identity.

## Test Tone

`Tools` -> `Test Tone` (`source_mode = tone`, `test_tone_*`) replaces the audio input with a sine, pink or white source, live. Since 0.45 it is a **calibration source, not program**: the tone bypasses every gain-changing stage -- input gain, AGC, EQ, multiband / Advanced Dynamics, enhancers, bass / HF / audio clippers, HF and Audio Limiters, Final Drive, the composite clipper, BS.412 and the final limiter -- while the delay-bearing stages stay in the path so pilot and RDS remain aligned. **0 dBFS = 100% of the audio modulation** left after the pilot/RDS reservation, and the scale is linear in dB, so the composite audio deviation is exactly `mpx_deviation_khz x budget x 10^(level/20)` (budget ~0.85 with 8% pilot and 2 kHz RDS at 75 kHz: -20 dBFS gives ~6.4 kHz of audio deviation plus ~8 kHz of pilot/RDS). A sine is pre-compensated for the pre-emphasis curve, so it reads the same deviation at 400 Hz, 1 kHz or 10 kHz; pink / white noise are peak-normalised and not compensated. The Test Tone card shows the expected audio and total deviation for the current level, pilot and RDS settings -- compare it with the Meter or a modulation monitor to calibrate the exciter. Before 0.45 the tone ran through the whole processing chain, so any level was lifted by the AGC into the clipper and produced full, clipped deviation ("way too loud, and the level slider does nothing"); `TestToneGeneratorTests` now pins level-in / deviation-out. The `Left` / `Right` routing modes double as a **channel-assignment check** on a real receiver: a left-routed tone must come out of the receiver's left speaker. Until 0.45 the encoder sent the stereo difference with the opposite sign to 47 CFR 73.322 / ITU-R BS.450-3, so every real receiver played L and R swapped (the built-in monitor and MPX Prime Meter compensated silently and could not show it); if you calibrated channel assignment against that behaviour, re-check it after upgrading.

## Getting RDS on air

RDS rides a 57 kHz subcarrier, so it needs the full 192 kHz composite: at
96 kHz or below there is no RDS at all. Everything below lives in the `RDS`
sidebar section (web dashboard: the RDS pages), and every field applies live
except the injection level.

1. **Turn it on.** `RDS` -> `Status` -> `Enable RDS` (`en_rds` in the `[RDS]`
   section). The same page shows what is actually going out right now: PS,
   Radiotext, PTYN and Long PS as receivers see them.
2. **Identify the station.** `RDS` -> `Program`: the four-hex-digit `PI` code
   (it encodes country and coverage -- look yours up in the [country
   table](rds-country-and-pty-tables.md#rds-pi-and-ecc-country-table)), the
   `PTY` programme type ([code
   list](rds-country-and-pty-tables.md#rds-programme-type-pty-codes)), and the
   eight-character `PS` station name. Set `ECC` as well if you want receivers
   to resolve the country unambiguously. The `PTY Region` switch picks which
   table labels the picker (Europe RDS or North America RBDS); the five bits
   transmitted are the same either way.
3. **Say what is playing.** `RDS` -> `Radiotext` carries up to 64 characters.
   It accepts timed and scrolling segments and the `{artist}` / `{title}`
   placeholders that a now-playing script or the REST API fills in; the
   grammar is in the [Settings and API
   Reference](studio-settings-reference.md#rds-text-syntax).
4. **Set the injection level.** `RDS` -> `Subcarrier` -> `rds_level` is in
   **kHz of deviation**, not a percentage (default 2.0, permitted 1.0-7.5).
   Between 2.0 and 3.0 kHz is the usual field choice: higher decodes more
   robustly in weak signal at the cost of a little audio headroom. This one
   takes effect at the next engine start.
5. **Confirm on a real receiver.** A car radio or an RTL-SDR should show the
   PS name within a few seconds and the Radiotext shortly after. Text that
   never appears usually means the output device is not running at 192 kHz.

Non-ASCII characters are folded to the RDS character set before transmission
(curly quotes and dashes become straight ones, accents are stripped), so a
track title pasted from a streaming service goes out readable rather than as
question marks.

## Operating modes

**What leaves the output device is one choice.** Sidebar -> **Audio I/O** ->
**Operating Mode** (INI: `operating_mode` in `[INTERFACES]`; restart-class,
because the modes differ in render rate, device format and filtering).

| Mode | Output | Use it for |
| --- | --- | --- |
| **MPX Output** (default) | the finished FM composite: pilot + stereo subcarrier + RDS | a transmitter / exciter with a composite (MPX) baseband input |
| **FM Output** | FM-shaped stereo L/R | a transmitter or exciter with its own stereo coder and RDS encoder |
| **HD Output** | flat, full-bandwidth stereo L/R with a true-peak ceiling | a stream encoder or a digital-radio box (DAB+, AAC) |
| **AM Output** | mono, NRSC-shaped, asymmetric peaks | an AM transmitter |

Everything that has no function in the selected mode is switched off and
hidden, in the app and on the dashboard alike: outside MPX Output there is no
composite, so the RDS section, the Stereo Coder / Composite Clipper / BS.412 /
Final Stage tabs, the pilot level, the MOD (deviation) meter, the MPX Spectrum
and Scopes windows and the decoded monitor all disappear, RDS stops being
generated and the Now Playing script stops being polled. The status bar shows
the mode.

Migration is automatic: a pre-0.50 INI with `processed_audio_output` /
`processed_audio_target` is read into the new key on load, and the REST API
still accepts both old spellings.

### MPX Output vs FM Output

The composite path always sounds louder and denser, because the composite
clipper is the main loudness stage. Where a transmitter accepts a composite
input, prefer MPX Output and switch the exciter's own stereo coder off. Use FM
Output only for gear that cannot take a composite: you keep the full audio
chain (AGC, EQ, multiband, bass, clippers, pre-emphasis, pre-encode limiter)
and give up the composite-only stages, which the external box then provides.

### HD Output (streaming and digital radio)

The FM-only stages leave the path: the audio keeps its full bandwidth (up to
the `Program Lowpass` setting, allowed to 20 kHz here), pre-emphasis is forced
off, stereo-image protection is skipped because a digital carrier has neither
deviation nor multipath to protect, and the final loudness clipper is not
offered -- clipping into a codec costs quality. Peaks are held at the true-peak
ceiling instead of being normalised to full scale.

### AM Output

The AM feed is **mono**: left and right are summed before the processing, so
every stage levels and limits the signal that actually goes on air, and both
output channels carry it.

- **AM Pre-emphasis** (`am_preemphasis_us`, restart-class): 75 us is the NRSC-1
  curve an NRSC receiver de-emphasises. Switch it off only when the
  transmitter or an outboard box already applies it -- the same one-stage rule
  as on FM.
- **AM Bandwidth** (`am_lowpass_hz`, restart-class, 3-10 kHz): NRSC-1 specifies
  10 kHz; many stations run 4.5-6 kHz to fit the channel and the receivers.
- **Positive Peak Headroom** (`am_positive_peak_pct`, live, 100-125 %):
  asymmetric modulation. 47 CFR 73.1570 allows positive peaks to 125 % while
  the negative peak stays at 100 %, so MPX Prime Studio holds the **negative**
  side at 100/125 of full scale and lets positive peaks use the rest.
  **Calibrate the transmitter on the negative peak**: set it so a negative peak
  at full modulation reads 100 %. Symmetric program lands symmetric; speech and
  most single-instrument material is what actually uses the extra positive
  room. At 100 % the mode is symmetric again and the feed is simply normalised.

The composite stages, the stereo coder, the pilot and RDS are not generated in
AM Output. This mode is new in 0.50 and has been verified by measurement (mono
sum, the NRSC curve, the band limit and the peak asymmetry each have a test);
it has not yet been checked against a modulation monitor on a real AM
transmitter.

**True-peak ceiling.** In HD Output, `Audio I/O` ->
`Operating Mode` -> `True-peak Ceiling` (`processed_audio_ceiling_dbtp`,
live-apply) sets where peaks land. **-1.0 dBTP** is the default and the shared
recommendation of EBU R128, AES TD1008 and the streaming platforms. Use
**-2.0 dBTP** when the next box is a data-reduction codec such as DAB+ or AAC:
lossy encoding pushes inter-sample peaks up, and the extra headroom is what
keeps them from clipping in the listener's decoder. The ceiling is a true-peak
figure: a look-ahead guard after the limiter holds inter-sample peaks to it
on every program, at the cost of 2 ms of extra delay on this target only.

**Loudness is set upstream**, by the AGC's Platform Target, not by this
ceiling. Useful numbers: about **-16 LUFS** for a music stream and -18 for
speech (AES TD1008 delivery levels), or **-23 LUFS** for EBU R128 broadcast,
which is the usual DAB case in Europe. The -14 LUFS figure quoted for Spotify
or YouTube is a playback normalisation level, not a delivery target; aiming at
it only costs you dynamics.

### Pre-emphasis ownership

Exactly one device in the chain may apply pre-emphasis (50 us EU / 75 us US).
Pick in Audio I/O -> Operating Mode -> **Pre-emphasis**:

- **Coder has NO pre-emphasis (or it is switched off):** select `50`/`75 us` so
  MPX Prime Studio applies it. Its pre-emphasis-aware limiter then controls the
  HF peaks. (Common for cheap exciters.)
- **Coder applies pre-emphasis:** select `Off` so MPX Prime Studio stays flat.
- **Never both** -- two pre-emphasis stages in series over-deviate.

### Optional final loudness clipper

To narrow the loudness gap when the external coder has no clipper of its own,
Audio I/O -> Operating Mode -> **External coder has its own clipper**:

- Leave **ON** (default) if your coder clips/limits its input -- MPX Prime Studio stays
  clean to avoid double-clipping.
- Turn **OFF** if it does not -- MPX Prime Studio then applies an oversampled
  distortion-cancelled final clipper, with a **Final Clipper Drive** slider
  (0-12 dB) to set density. Two clippers in series sound harsh, so only enable
  this when the coder genuinely does not clip.

### Output level and rates

- **Output level:** the Audio I/O Output card's **Output Level** slider (`output_gain_db`, remembered per output device and per mode). The
  processed feed is normalized so peaks reach ~0 dBFS at 0 dB; lower it to match
  your coder's input reference, raise it for a hotter feed.
- **Sample rate / bit depth:** run **48 kHz / 24-bit** end to end (the >=110 kHz
  rule is composite-only). Match the output device format in Audio MIDI Setup to
  `sample_rate`. See BUILDING.md / the rate notes for the full rationale.
- **Auditioning:** because the output is plain L/R, you can route it to any
  monitors/DAW to A/B processing changes. Listen with pre-emphasis **Off** so the
  monitored signal is not artificially bright; the decoded-MPX monitor remains the
  reference for final on-air sound.

INI keys: `operating_mode`, `preemphasis_us`,
`processed_audio_coder_has_clipper`, `processed_audio_final_clip_drive_db`,
`output_gain_db`.

## Watching the signal

The DSP status card's **Safety GR** is the final look-ahead MPX limiter's gain reduction (about 1 dB on dense program is normal: it rides the composite clipper's guard-band overshoot; since 0.45 it reports the true amount it removes). **Safety Clip** next to it is how far, in dB, the composite exceeded the budget and had to be caught by the 1x safety soft clip; it must read 0.0 in normal operation -- anything above zero means the composite clipper and final limiter are not controlling the peaks (both off, or an impossible gain structure) and the distortion class fixed in 0.45 is back. The same value is `safetyClipDB` in `GET /api/meters` and "Safety Clip" on the dashboard.

- `Audio I/O` -> `Output` is the composite/baseband output device
- `Audio I/O` -> `Monitor (Decoded MPX Simulation)` is the device the Monitor operating mode plays the decoded composite to
- The orange microphone indicator in the macOS menu bar is the system privacy indicator and appears when MPX Prime Studio is actively using audio input
- `Mono Mode` now transmits true mono composite and suppresses pilot, stereo subcarrier, and RDS while enabled
- If a remembered input / output / monitor device is not connected, **Start is refused** with an alert rather than silently streaming to the OS default -- reconnect the device or pick another in `Audio I/O`. (Devices are remembered by UID and name, so moving an interface to another USB port keeps the selection.)

### Monitoring windows

Beyond the `Monitoring` dashboard tab, Studio offers detachable instrument
windows (from the toolbar / Window menu). Like the Meter's displays, they are
dark instrument panels and repaint in `Canvas` so a live value change never
triggers a layout pass:

- **MPX Spectrum** -- the composite (MPX) spectrum after stereo encoding, with the
  same FM band-region overlay the Meter draws: **Mono L+R**, **19 kHz Pilot**,
  **Stereo L-R** (lower and upper sideband -- the same L-R signal mirrored around 38 kHz), **57 kHz RDS**, and **SCA** captions mark where each component
  sits, so you can confirm the pilot, subcarrier, and RDS land in the right
  places at the right levels.
- **Audio Spectrum** (pre-MPX) -- an RTA-style bar spectrum of the processed L/R audio
  before composite assembly (the audio the encoder is about to modulate).
- **Scopes** -- composite / decoded-monitor waveforms.
- **Levels** -- the vertical deviation / level meters as a standalone window.

## Operating it from a browser

The encoder embeds an HTTP control server for remote and automation use --
on macOS (GUI or `--nogui`) and on the Linux CLI build. It is **disabled by
default**.

Enable it in the INI (`[CONTROL]` section; on macOS also editable in the
GUI's Settings window, where changes take effect at the next app launch). On
Linux the dashboard IS the operator interface, so the Debian package seeds
`/var/lib/mpxprime/MPXPrime.ini` on a fresh install with `control_enabled =
True`, `control_bind = 0.0.0.0` and a randomly generated `control_api_key`
(printed at install, readable from that file with `sudo grep control_api_key
/var/lib/mpxprime/MPXPrime.ini`), and its service unit passes `--web` so the
server is on regardless; edit the keys below there to rotate the key or
restrict the bind. A hand-run build uses the `--web` flag the same way:

```ini
[CONTROL]
control_enabled = True
control_bind = 127.0.0.1   ; 0.0.0.0 = all interfaces (requires API key)
control_port = 8737
control_api_key =          ; required for any non-127.0.0.1 bind
```

The web session reads and writes the SAME configuration file as the
Studio GUI (the platform's default INI listed under
[Configuration](#where-your-settings-live), or whatever `--config` names) -- so it
starts from your existing station setup, and its changes persist for
the next launch (on macOS, also for the next GUI launch). The resolved
path is printed at startup.

For one-off runs, `--control` (alias: `--web`) or `--control-port 9000`
enables it without editing the INI; these flags imply `--nogui` (run
headless, serve the dashboard). In the macOS GUI app, use the Settings window.
From a source checkout, `scripts/run-build-web.sh` builds the release binary and
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
above four sidebar sections (the native GUI's Audio I/O section is the
dashboard's Audio I/O page under Tools):

- **Monitoring** -- source/output devices, input meters, MPX deviation /
  modulation, per-stage gain-reduction readouts, subcarrier injection +
  budget margin, and stream health (uptime, ring-buffer fill, OVR/UND
  drop counters, resample trim), plus a signal-chain card grid.
- **Processing** -- the GUI's tab set one page each: Overview (stage grid
  with enable switches), Profile (station-format picker), Core, Phase
  Rotator, AGC, Parametric EQ, Multiband (incl. crossovers X1-X4),
  Advanced Dynamics, Expander, MB Limiter, PrimeBass (+ Mono Bass),
  Bass Clipper, Audio Clipper, HF Limiter (incl. the HF clipper), Audio
  Limiter, Stereo Coder, Composite Clipper (incl. look-ahead +
  oversampling), BS.412, Final Stage. Real
  switches and sliders with the GUI's control vocabulary, applied live on
  release; each page has the GUI's "Reset This Tab" button.
- **RDS** -- Status (on-air PS/RT/PTYN/Long PS), Identity, Radiotext
  (mode, rotation, the 4 manual buffers, RT+ formats, Now Playing
  configuration), Long PS, Alt. Frequencies (list + method), Schedule
  (group sequence, scheduler toggles, CT/TZ), Subcarrier.
- **Tools** -- Test Tone, Audio I/O (input / output / monitor device
  pickers -- selecting one is a restart-class change; the Operating Mode
  toggle; the level calibration sliders Input Gain, Output Level, Line
  Output, remembered per device like the native GUI; the engine format:
  sample rate, block size, auto start, spectrum window, monitor enable;
  and the read-only Remote Control card showing the server's own settings,
  which stay INI/GUI-only by design), Presets (per-stage preset pickers plus the 8 operator
  preset slots: name, Save/Load/Export/Clear, Import into empty slots),
  and an Advanced page holding the raw all-settings editor.

Every change reports back live / live-RDS / needs-restart. The Bypass
button mirrors the GUI's Cmd-B exactly: it flips `processing_bypass`
(restart-class, so it restarts the engine when running), shows a red
BYPASSED state, and does it without a confirmation dialog (0.50: it is a
deliberate engineer's action and the state is visible). The dashboard hides
exactly what the GUI hides for the operating mode -- the same
`ChainFeature` table drives both -- down to individual controls, and
Monitoring swaps the MPX/subcarrier cards for a processed-audio output
card outside MPX Output. The dashboard is a single self-contained
page (no internet access needed) and prompts for the API key when one is
configured.

## Bypassing the processing

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
- Bass / audio / HF clippers
- Pre-encode audio limiter
- Stereo-image protection

## The MPX Prime Meter companion

MPX Prime Meter is the receive/analyze counterpart to the encoder, shipped
as `MPX Prime Meter.app` in the same DMG. It takes an FM MPX composite (from
an audio device or an in-process RTL-SDR / SDRplay tuner), decodes stereo +
full RDS, and measures deviation, MPX power (ITU-R BS.412), and SM.1268
compliance on one dashboard window.

It has its own manual: **[MPX Prime Meter -- User Manual](meter-operator-guide.md)**.
The RDS PI/ECC and PTY reference tables below serve both apps (the encoder
sets these fields; the Meter decodes them).

## When something sounds wrong

Start here before changing the processing.

- **No audio at all on air.** Check that the engine is started, that
  `Audio I/O` -> `Output` points at the device actually wired to the exciter,
  and that `Processing` -> `Core` -> `Bypass Processing` is off (the default).
  A remembered device that is no longer connected refuses to start rather than
  silently falling back to the built-in speakers.
- **Stereo works but there is no RDS.** The output device is not running at
  192 kHz. The 57 kHz subcarrier does not exist below that rate; check the
  device format in Audio MIDI Setup against `sample_rate`.
- **Clicks, dropouts, or the input meter showing overflows.** Two usual
  causes, in this order: you are running a debug build (use the app from the
  DMG, or a release build), and the device format in Audio MIDI Setup does not
  match `sample_rate` -- Core Audio then resamples behind the engine and
  starves the render thread. Raising the block size buys margin on slower
  machines.
- **On-air level is low even though the processing looks busy.** Final Drive
  sets loudness inside the chain; `MPX Output Level` and `Line Output`
  calibrate the voltage leaving the machine. See [Setting
  levels](#setting-levels-input-agc-final-drive-exciter) and check the
  exciter's own modulation meter rather than the app's.
- **Pilot and RDS read high while deviation looks right.** Something upstream
  of the exciter is adding gain (an OS volume above 0 dB, or a positive line
  trim). Keep the operating system and interface at unity and calibrate with
  the two Audio I/O trims instead.
- **The sound is harsh on cymbals or sibilance.** Back off Final Drive first,
  then check that the HF Limiter is on and the HF Clipper is off (the default
  in every Format Profile).

For an ears-on check after any change, `docs/test-playlist.md` lists reference
tracks chosen to expose specific artifacts -- asymmetrical peaks, sibilance,
dense bass, wide stereo -- with what to listen for in each.

To prove a change measurably rather than by ear, the offline verification
gates render deterministic scenarios without touching audio hardware; they are
documented in [BUILDING.md](BUILDING.md#offline-verification).
