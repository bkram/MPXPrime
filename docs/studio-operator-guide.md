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
- The companion analyser: [MPX Prime Meter -- Operator Guide](meter-operator-guide.md).
- What the project is: [README](../README.md). Building, testing and the
  offline verification gates: [BUILDING.md](BUILDING.md). How the DSP chain
  works inside: [ARCHITECTURE.md](ARCHITECTURE.md).

## Which platform you are on

The encoder runs on two platforms with the **same DSP**; only the front end and audio backend differ:

- **macOS** -- the full **GUI application** (`MPX Prime Studio.app`), Core Audio, plus a headless `--nogui` mode. The companion **MPX Prime Meter** analyser ships in the same DMG (macOS only -- see its [manual](meter-operator-guide.md)).
- **Linux** -- the encoder as a **web-operated appliance**: a service that encodes into ALSA and is run from the built-in [web dashboard / REST API](#operating-it-from-a-browser), with the same controls as the GUI. Installed from the Debian/Ubuntu package as the `mpxprime` systemd service (config at `/var/lib/mpxprime/MPXPrime.ini`). Same DSP chain and same sound as on macOS; the GUI and the Meter are macOS apps, and the dashboard's scope and spectrum views are not yet fed on Linux. Setup: [Running on Linux](#running-on-linux-the-web-dashboard-encoder) below and [BUILDING.md -> Linux](BUILDING.md#linux-web-dashboard-encoder).

Everything in this guide applies to both platforms; where a control is GUI-only, Linux operators reach the equivalent on the web dashboard, which mirrors the same layout. Platform differences are flagged inline; at a glance:

| | macOS | Linux |
|---|---|---|
| Operator interface | GUI app (`MPX Prime Studio.app`); optional web dashboard | **Web dashboard / REST API only** (the package enables it on all interfaces behind a generated API key -- see Usage) |
| Audio backend and device keys | Core Audio; `*_device_uid` keys hold Core Audio UIDs, picked in the app | ALSA; `*_device_uid` keys hold PCM names (`default`, `hw:0,0`, `plughw:...`) |
| Default config file | `~/Library/Application Support/MPX Prime Studio/MPX Prime Studio.ini` | `~/.local/share/MPX Prime Studio/MPX Prime Studio.ini` (source build); `/var/lib/mpxprime/MPXPrime.ini` (Debian package) |
| Operating modes | MPX / FM / HD / AM Output, each with the concurrent Monitor output | the same four, with the Monitor on a second ALSA device |
| Companion analyser / SDR | MPX Prime Meter (Apple Silicon only) | none |
| Offline gates | all `--verify*` modes, `--bench*`, the live smoke / A/B scripts (need BlackHole) | all `--verify*` modes and `--bench*` except `--verify-program-ab` (needs AVFoundation); no live scripts |

The same INI keys, presets, RDS features and verifier thresholds apply on both; a config file moves between platforms once the device keys are re-pointed.

## Installing and starting (macOS)

**Hardware.** One core carries the whole chain, so the CPU's per-core speed
decides whether a machine fits; nothing else about it matters much (2 GB of
RAM is plenty). Minimum: `MPXPrime --bench` reads under 40 % of real-time on
it; recommended: under 30 %. Every Apple Silicon Mac and every Intel Mac from
2018 on qualifies; on Linux use an x86_64 CPU with AVX2 -- Intel N100 class
at the least, N305 / Core i3 / Ryzen 5 comfortable. Measured figures for the
machines this has run on are in [docs/performance.md](performance.md); the
"CPU budget" section below says what to switch off when a box is close.

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

To build, run, verify, test, or package from source, see
[docs/BUILDING.md](BUILDING.md).

## Running on Linux: the web dashboard encoder

On Linux the encoder is a **web-operated appliance**: a `mpxprime` systemd
service that encodes into ALSA and serves the web dashboard, with the same
DSP chain and the same sound as on macOS. Everything else in this guide
applies here too; this chapter collects what is Linux-specific -- the
installation, the sound card's own mixer, the render-load readout and the CPU
budget, and the level question.

### Installing the package

The dashboard is the operator interface -- every control the macOS GUI has,
laid out the same way -- and the encoder itself runs as a service, so the box
is operated from a browser on any machine on the network. The package sets
that up right after install. `dpkg -i` installs `/usr/bin/mpxprime` and a
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
by an upgrade, and a running service is started again once the new files are
in place. The server speaks plain HTTP; on an untrusted network front
it with a TLS reverse proxy (see
[Remote control](#operating-it-from-a-browser)). To run by hand
instead of as a service: `mpxprime --web --config /path/to/MPXPrime.ini`
(`--web` implies `--nogui` and forces the server on; bind, port and key still
come from the INI). Devices are ALSA PCM names (`default`, `hw:0,0`,
`plughw:...`), not Core Audio devices; the Monitor plays on a second ALSA
device (see Monitor output below).

### Sound card mixer

On Linux the dashboard's `Audio I/O` page shows the sound card's own level
controls next to the devices they belong to: **Card Input Level** under the
input device and **Card Output Level** under the output device, in dB as the
card reports it. They are there because that mixer sits between the encoder
and the exciter and nothing else on a headless box shows it: the test rig came
back from a reboot at 96 %, 2 dB down, because its USB card has a hardware
volume knob.

Keep the output at 0 dB and do the calibration in the encoder with `MPX Output
Level` and `Line Output`. Moving a card slider from the dashboard also makes the
encoder remember it and put it back whenever something else (the knob, a
reboot) moves it, so you do not need `alsactl store`. The card's capture side
often carries analogue gain of its own -- the reference USB card showed +6 dB on
one box and +10 dB on another -- which is why
an input calibrated on macOS lands at a different level here; set the card
input to 0 dB and calibrate with `Input Gain`. On macOS the same card shows
the output and input devices' own CoreAudio volume (since 2026-10; see
"Preparing the audio devices" below), and the app's `Audio I/O` section shows
them as Device Output Level / Device Input Level.

### Render load

The dashboard's Stream Health card shows **Xruns R/C** (render / capture
dropouts since the engine started) and **Render Load**: the worst share of
one buffer period the encoder's real-time thread needed recently. It turns
red from 90 %. A CPU can sit in the nineties with no dropouts on a quiet
input and drop about one buffer a second as soon as live programme arrives,
so measure with programme. If the counter climbs, check Render Load first; a
longer `blocksize` buys safety at the cost of latency -- with the chain near
its limit, 2048 (85 ms of buffer) dropped an occasional burst with the
Monitor on and 4096 (170 ms) dropped none, so on a CPU reading over 90 % use
4096. The Monitor's own decoding runs on a separate thread and adds nothing
to this figure.

### CPU budget: what to turn off first

The processing chain is the same on every machine, so on a small CPU it is
the operator who decides what fits. **Render Load** is the figure to watch:
from 98 % the status line says so ("Render load at or over 98 %: the
processing chain does not fit this CPU"), and a single reading far above
100 % right after a start or restart is the first period priming, not the
chain. The shares below come from `--bench` on three machines (they agree
within a few points) and from live render load on the Ryzen 5 PRO 2400GE;
[docs/performance.md](performance.md) has every measurement. A slower CPU
scales everything up together, so the ORDER is what carries over.

| Stage (INI key) | Share of the chain's cost | Turn off? |
| --- | --- | --- |
| Everything else -- input, pre-emphasis, limiter, stereo encoder, RDS | about half | this is the floor |
| Composite clipper at 16x (`mpx_clipper_oversampling`) | about a quarter; 8x saves 8-12 % of the chain, 32x adds 15-25 % | 16x is the default for a reason; 8x is the safe way down on a small CPU (Composite Clipper > Advanced > Oversampling, applies live), 32x only where the load is well under 60 % |
| Multiband compressor, FIR crossovers (`multiband_enabled`, `multiband_fir_enabled`) | about a quarter | first candidate on a struggling CPU: `multiband_fir_enabled = False` keeps the compressor on the low-latency IIR crossovers for less than half of that (restart) |
| Advanced Dynamics instead of AGC + multiband (`advanced_dynamics_enabled`) | a little less than the multiband | the cheaper of the two levellers |
| SSB Stereo (`mpx_ssb_stereo_enabled`) | 5-8 % | first, when CPU is short -- it is the one stage that has tipped a chain from "fits" to "dropouts", and it buys spectrum, not loudness (it costs composite peak on wide stereo programme) |
| Monitor output (`monitor_enabled`) | 2-3 % on the render thread (its decoding runs on its own thread) | only when the chain already sits at the edge |
| PrimeBass, bass clipper, audio clipper (`primebass_enabled`, `bass_clipper_enabled`, ...) | 1-2 % each | as the sound requires |
| HF limiter, AGC, BS.412 (`hf_limiter_enabled`, `wideband_agc_enabled`, `bs412_enabled`) | under 1 % each | keep them |
| Encoder FIR (`encoder_fir_enabled`) | -- | never for CPU reasons: it is the transmitter's 15 kHz band limit |

The build uses AVX2 automatically on CPUs that have it (any Ryzen, Intel
N100 / Core); `mpxprime --version` shows `DSP kernels: avx2` or `sse2`. It
does not change the sound -- the two variants compute bit-identical
results -- only the cost: on a Ryzen 5 PRO 2400GE the full Music - Loud
chain with SSB Stereo reads 29 % with AVX2 against 45 % without, so that
class of machine runs everything with room to spare.

Recipe for a box that reads over 90 % with programme: SSB Stereo off; then
`blocksize = 4096` (buys tolerance, not CPU); then the composite clipper at 8x
or the multiband on IIR crossovers, whichever your ears prefer. Format
Profiles do not change this budget by themselves -- they set levels and
thresholds, not which stages run -- except that a profile copied from a
faster machine may bring SSB Stereo along.

### Why the box is "not loud enough"

The digital path is at full scale: the composite leaves the card at 0 dBFS
minus `MPX Output Level`, and the card's own output is at 0 dB. Two things
changed in 0.50 that make a rig upgraded from an older build quieter:
`MPX Output Level` is attenuation-only in MPX Output (a positive value used to
be accepted and pushed pilot and RDS above their set injection; it is clamped
to 0 now, the same on both platforms), and the card mixer is now watched, so a
knob at -2 dB no longer goes unnoticed. Beyond that the card is at its
maximum: more drive has to come from the exciter's input sensitivity, exactly
what `scripts/calibrate-tx.sh` tells you on macOS. To compare the two hosts
honestly, run the built-in Test Tone at 0 dBFS (100 % modulation by
definition) with the card at 0 dB on each and measure the same jack.

## First-time setup in five steps

This is the minimum to hear MPX Prime Studio processing your audio and feeding a transmitter / SDR / loopback. Defaults are tuned to sound good out of the box -- the chain ships processing-on with AGC, multiband, bass clipping, and the composite clipper engaged.

**1. Plug audio in and out.** MPX Prime Studio reads from a Core Audio input device and writes the composite (MPX) signal to a Core Audio output device (on Linux: ALSA PCM devices, selected on the web dashboard's Audio I/O page or by name in the INI). Typical setups:

- Sound card input from your studio mixer / streaming source -> sound card output into an FM exciter that accepts MPX baseband.
- BlackHole 2ch (virtual loopback) input from a music player or DAW -> sound card output into an SDR transmitter or RF generator.
- Test tone source (built-in) -> output to verify metering and routing without external audio.

192 kHz output is **required for the full composite with RDS.** RDS sits at 57 kHz, which exceeds the 48 kHz Nyquist of 96 kHz sample rates -- the RDS subcarrier cannot be represented at 96 kHz or below. 96 kHz is just enough to carry the FM stereo composite alone (M + 19 kHz pilot + 38 kHz DSB-SC stereo subcarrier) provided the audio bandwidth is limited so the upper L-R sideband doesn't push past 48 kHz; pilot-locked stereo decoding works, but disable RDS at this rate. Below 96 kHz the stereo subcarrier itself doesn't fit. 192 kHz is the recommended rate for everything because it gives Nyquist headroom for the post-clipper pilot/RDS injection plus the oversampled peak-control stages the chain runs above the host rate.

> **External sound card required for RDS.** Apple's built-in audio output on Mac laptops and most desktops tops out at **96 kHz**, which cannot carry RDS -- the 57 kHz subcarrier exceeds 48 kHz Nyquist. For any FM-with-RDS chain you need a USB / Thunderbolt audio interface that natively runs at **192 kHz**. Most pro and prosumer interfaces (RME, MOTU, Focusrite Scarlett 3rd-gen+, Apogee, etc.) support 192 kHz on at least the analogue or AES outputs -- check the spec sheet before ordering. The internal Mac speakers / headphone jack are fine for *listening to a test tone* through MPX Prime Studio, but they cannot be the production output if RDS is in play.

### Preparing the audio devices (macOS Audio MIDI Setup)

macOS configures Core Audio device parameters via **Audio MIDI Setup** (`/Applications/Utilities/Audio MIDI Setup.app`). MPX Prime Studio sets the output device's sample rate itself and shows and sets the devices' own volume (see item 3 below); the bit depth is the one device-side value that still lives only in Audio MIDI Setup.

**Output device** (feeding your exciter / SDR / RF generator):

1. **Format / sample rate**: set to **192 000 Hz**. Match what the engine is configured to (`sample_rate = 192000` in INI). If the device runs at a different rate Core Audio inserts a sample-rate converter that cannot represent the upper composite band cleanly. **Required for RDS** -- the 57 kHz RDS subcarrier needs at least ~119 kHz Nyquist; 176.4 kHz is the lowest device rate that carries it correctly, 192 kHz is the canonical default. On start MPX Prime Studio now **sets the output device to the configured rate itself** (and restores the device's prior rate on stop); if the device can't run that rate it surfaces a routing note telling you to set it in Audio MIDI Setup, rather than letting Core Audio quietly resample.
2. **Bit depth**: **24-bit integer or 32-bit float**. Either is fine; 32-bit float is the AVAudioEngine native format. 16-bit also *works* for the composite (96 dB SNR is well above any FM receiver's noise floor and you cannot hear the difference at the listener), but 24/32-bit is best practice -- no extra dither/truncation step at the chain output, and headroom for downstream tools that further process the composite (resamplers, SDR DSPs).
3. **Volume / output gain**: **0 dB (100 %)**. This is the critical one. The device's own volume is post-mix -- it scales the engine's already-finalised composite on its way to the exciter, and no meter in the app can see it. A DAC at -5 dB delivers a composite 5 dB low, so a station that reads 75 kHz on the Deviation meter is on air at 42 kHz. Since 0.65 the app reads this level itself: the `Audio I/O` Output card shows **Device Output Level** (the device's own dB and slider position, read live from CoreAudio) with a **Set to 0 dB** button, and the web dashboard's Sound Card Mixer card shows the same row as Card Output Level. Pressing Set to 0 dB (or moving the dashboard slider) also makes the encoder **hold** that level: it is re-asserted at every engine start and every 5 s, so nothing else on the Mac can quietly take it down again (`card_playback_volume_db` in the INI; blank it to hand the device back to macOS). A new installation leaves the device unmanaged, but when the engine starts with the output below -0.1 dB or muted the status line says so ("DX3 Pro+ output volume is -5.0 dB in CoreAudio; the composite reaches the exciter 5 dB low. Set it to 0 dB here or in Audio MIDI Setup."). A device without a volume control in CoreAudio (BlackHole) shows no row; there is nothing to set.

**Device selection is remembered by UID and name.** Each selected input / output / monitor device is stored by its Core Audio UID *and* its name (`input_device_uid` / `input_device_name`, etc.). At launch the device is matched by UID first, then by name -- so moving a USB interface to a different port (which can change its UID) still re-finds the same device. If a remembered device is simply unplugged, MPX Prime Studio **keeps** your selection (and shows a status note) instead of silently switching to whatever device is first in the list; reconnect it, or pick another.

**Input device** (your audio source -- interface, BlackHole loopback, or built-in audio):

1. **Format / sample rate**: **48 000 Hz, 24-bit** is the recommended sweet spot. The reason is the dual-rate audio chain (default-on since 0.30) -- the entire audio domain (multiband, AGC, EQ, image protection, pre-emphasis, pre-encode limiter) runs at 48 kHz internally, then upsamples to the MPX rate at the stereo encoder boundary. Setting the input device to 48 kHz means the source audio passes into the audio domain without any Core Audio upsampling on the way in (no information gain from higher input rates anyway -- audio source material has zero useful content above ~20 kHz). 44.1 kHz also works fine; Core Audio's input-side SRC handles the small upsample to 48 kHz cleanly.
2. **Bit depth**: **24-bit** is recommended. 16-bit is fine for the audio itself, but the chain runs in 32-bit float internally through many stages and 24-bit input keeps the noise margin below the audible threshold even under hot processing.
3. **Volume**: keep the device's own input level at **0 dB** and set the level with `Input Gain`, which is remembered per device. Where the input device has an input volume in CoreAudio (an audio interface; BlackHole has none) the Input card shows **Device Input Level** with its own Set to 0 dB button, and the dashboard shows it as Card Input Level; the encoder holds a level set there like the output's. Aim for peaks around -12 to -6 dBFS on the Post input meter so the AGC has something to work with.

If your output device is BlackHole or a virtual loopback, the same rules apply -- check both the loopback device's format and the receiving app's input format. Mismatch there is the #1 cause of "the chain looks right but the receiver sounds wrong" reports.

**2. Set your region.** Pre-emphasis differs by region:

- **USA / Canada / South Korea**: 75 us
- **Everywhere else (EU, ROW)**: 50 us (current default)

Open `Audio I/O` -> `Operating Mode` and set `Pre-emphasis` to `75 us` if you are in a 75 us region. Wrong pre-emphasis will sound either dull (50 into 75 deemph) or shrill / over-modulated (75 into 50 deemph). The curve itself is matched to the analogue network within 0.05 dB up to 15 kHz, and since 0.45 the whole chain's receiver-side response follows it within 0.5 dB to 14 kHz -- earlier builds were 1-3.5 dB low above 10 kHz at the receiver (a limiter decimation filter and the digital pre-emphasis approximation both rolled off the top of the band), so a station that added treble EQ to compensate should re-check that EQ after upgrading. EU operators required to comply with ITU-R BS.412 should also enable `Sound` -> `BS.412`. Every setting referenced in this guide is also reachable from the GUI; the INI is written automatically and is mainly there for inspection or out-of-band edits.

**3. Launch and Start.** Open MPX Prime Studio, pick your input and output devices in the sidebar's `Audio I/O` section, then press `Start` (Cmd-Return) on the toolbar. The status bar at the top of the window says whether the engine is Running, what the Source and Rate are and which operating Mode is selected. The `Monitoring` page (Go > On Air, Cmd-1) shows the live levels, peak deviation in kHz, modulation as a percentage of the configured Composite Deviation, gain reduction, the composite budget and the pilot / RDS injection -- if those move with your audio, the chain is processing.

**4. Calibrate composite output level.** On `Monitoring`, watch the `Composite Budget` row in the Headroom card (the whole-composite margin in dB, then its state). The state reads the headroom between the audio composite and the audio budget -- the part of the composite left after the pilot and RDS reservation -- not the whole-composite margin, which sits within a few hundredths of a dB of zero by design whenever the composite clipper is working:

- **Safe**: the audio composite has at least 0.5 dB to spare below its budget -- quiet or dynamic programme, or Final Drive set low
- **Tight**: the audio composite is within 0.5 dB of its budget -- the composite clipper is holding the peaks on the ceiling. This is the normal operating point on dense programme; nothing to correct
- **Risk**: a fault, not a loud programme -- the final clamp engaged after the pilot and RDS were added (the subcarriers were clipped) or the configuration leaves no audio budget at all (pilot and RDS levels too high for the deviation). Lower the pilot or RDS level

`Final Drive` (on the `Loudness and Output` page) controls perceived loudness; `MPX Output Level` (on the `Audio I/O` Output card, remembered per device) calibrates the final voltage to your exciter / SDR. Use `Final Drive` for loudness and `MPX Output Level` only for hardware calibration.

**5. Verify on a receiver.** Tune a real FM radio or RTL-SDR to your transmitter's frequency. You should hear stereo audio with a steady stereo-pilot indicator, see RDS PS and Radiotext on the radio's display (if your radio supports RDS), and the audio should sound louder and more present than the same source through `mpxgen` / PiFmRds.

If you cannot hear anything, check `Audio I/O` -> output device routing, that the engine is started, and that processing is not bypassed: the toolbar button reads `Bypass`, not `Bypassed`, and the status bar shows no red `Processing: Bypassed` chip.

### Choosing a block size

`Audio I/O` -> `Engine` -> `Block Size` (`blocksize` in `[INTERFACES]`, 256..8192 frames). The DSP itself does not depend on it -- the composite rendered in 64-, 480-, 1024- or 8192-frame blocks is bit-identical to 512 (pinned by a test) -- so the choice is only about latency versus dropout safety. Round-trip I/O latency is two blocks: at 192 kHz, 256 = 2.7 ms, 512 = 5.3 ms, 1024 = 10.7 ms, 2048 = 21 ms, 4096 = 43 ms, 8192 = 85 ms. Measure your machine with `--bench-blocks` on a release build: it reports the worst single block's render time as a fraction of that block's duration (100% = a dropout) -- keep at least 2x margin. On an Apple M1 Pro with the full chain the worst block is 17% at 512 and 23% at 256, so **512 is the recommended setting on Apple Silicon** (the shipped default is 1024, safe on every machine; 256 works on Apple Silicon if you need the latency; 64 is marginal at 46%). Intel Macs and Linux boxes want 1024-4096 (see [docs/performance.md](performance.md) for the block-size sweeps). Two hardware caveats: CoreAudio devices clamp the buffer to their own range and the engine logs "clamped HAL buffer" when that happens (the built-in output allows 15..4096, so 8192 is never honoured there), and many USB interfaces glitch below 256 regardless of CPU headroom.

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
- `MPX`: processing, levels, stereo coding, limiter behaviour
- `RDS`: programme service, radiotext, flags, carrier settings

## Finding your way around the app

The sidebar has five sections: **On Air** (Monitoring), **Setup** (Audio
I/O, Test Tone), **Sound**, **RDS** and **Presets and System**. Go > On Air
to Presets and System jump to them with Cmd-1 to Cmd-5. Sound starts with the
Overview and then groups the stages in signal order: **Input** (Basics, Phase
Rotator), **Levelling** (AGC, or Advanced Dynamics), **EQ** (Parametric EQ),
**Dynamics** (Multiband, Expander, Band Limiter), **Bass** (PrimeBass, Bass
Clipper), **Peak Control** (Audio Clipper, HF Limiter, Audio Limiter) and
**Transmission** (Stereo Coder, Composite Clipper, BS.412, Loudness and
Output). Pages that have no function in the current operating mode or
levelling engine are hidden; if one was open, the app shows the Overview.

Every page has the same layout: a title, a one-sentence subtitle, its cards,
a **Reset** button named after the page (for example `Reset Composite
Clipper`) and a help box at the bottom. Time constants and set-once options
sit in a collapsed **Advanced** group on each card. Thresholds read in dBFS
and amounts in percent.

**Status bar.** Always visible above every page: `Transport` (Running or
Stopped), `Source` (the input device, or `Test Tone` while the tone runs),
`Rate` and `Mode` (MPX Output, FM Output, HD Output or AM Output). Three chips
appear only while they apply: `Monitor: On`, a red `Processing: Bypassed`
(click it to process again) and `Restart: Restart to Apply` (click it to
restart the engine). A `RDS Warning: Rate < 192 kHz` chip appears when RDS is
on at a rate that cannot carry it.

**Toolbar.** Start/Stop and Bypass (it reads `Bypassed` while on), then
Levels, Audio Spectrum, MPX Spectrum and Scopes. Open and Save are in the
File menu only.

**Menus and shortcuts.**

| Menu item | Shortcut |
| --- | --- |
| Control > Start/Stop | Cmd-Return |
| Control > Bypass (checkmark while on) | Cmd-B |
| Control > Reset Peaks | Cmd-R |
| Control > Restart to Apply | Shift-Cmd-A |
| View > Test Tone | Cmd-T |
| Go > On Air, Setup, Sound, RDS, Presets and System | Cmd-1 to Cmd-5 |
| Window > MPX Prime Studio (the main window) | -- |
| Window > Levels, Audio Spectrum, MPX Spectrum, Scopes | Cmd-6 to Cmd-9 |
| Window > Minimise | Cmd-M |
| Help > MPX Prime Studio Help | Shift-Cmd-/ |

**Settings that need a restart.** Most controls apply live. A control that
only takes effect after an engine restart carries a restart badge; the list
is derived from the engine itself, and Help > MPX Prime Studio Help shows it
under "Settings That Need a Restart". Changing one while the engine runs
saves it and shows the `Restart to Apply` chip; click the chip, or use
Control > Restart to Apply, when a short break in the output is acceptable.
Pilot Level, the clipper oversampling, the Monitor, Composite Deviation and
the Output Level all apply live.

**What each page's Reset puts back.** A page's Reset returns that page's own
controls to the values the active Format Profile gives them (or the shipped
defaults for controls no profile sets). Monitoring, Audio I/O, Overview and
Presets have no Reset: Audio I/O is rig calibration, and the Overview's
choices each have their own control. Some pages reset less, or more, than a
first glance suggests:

| Page | Reset puts back | Restart |
| --- | --- | --- |
| Basics | Mono Mode, High-Pass Filter, HF Trim, HF Trim Frequency, Programme Lowpass (not Bypass, pre-emphasis or the gains) | yes, when running |
| Loudness and Output | Broadcast Preset, Final Drive and the Safety Limiter | yes, when running |
| Test Tone | the tone settings, and turns the tone off | no |
| RDS Status | Enable RDS and the TP, TA and MS flags | no |
| RDS Identity | PI, ECC, PTY, PTY Names, PS, PTYN, LIC, PIN, decoder information, ID and Long PS | no |
| RDS Schedule | group sequence, scheduler, Clock Time and Time Zone | no |
| RDS Subcarrier | Injection and the subcarrier shaping | yes |
| every other Sound or RDS page | the page's own controls | no |

Settings window (MPX Prime Studio > Settings, Cmd-,): the configuration path
with **Show in Finder** and **Reload from Disk**, and the Remote Control
server settings.

## The Audio I/O section: devices, operating mode, level calibration

The sidebar's **Audio I/O** section (on Linux: the web dashboard's **Audio I/O** page) is the installation page: where the signal enters and leaves the app. It holds the input / MPX output / monitor device pickers, the **Operating Mode** (one segmented four-way choice, `operating_mode`: MPX Output for a transmitter, FM Output for an external stereo coder, HD Output for streaming or digital radio, AM Output for an AM transmitter), the **Monitor** output (`Enable Monitor`), the **Engine** card (sample rate, block size, `Start Engine at Launch`; the encoder and multiband FIR choices and `96 kHz Spectrum` under Advanced), and the three **level calibration** controls: `Input Gain` on the Input card, `MPX Output Level` + `Line Output` (with a live **DAC Peak** readout) on the Output card. `Pre-emphasis` sits on the Operating Mode card in MPX and FM Output, and `Composite Deviation` on the Output card in MPX Output. The page has no Reset button: its values belong to the rig.

### Choosing devices and channels

Each device row on the Audio I/O page is a button showing the device and its
channels, for example `Inputs 3, 4, 48 kHz`. Click it to pick the device
from a menu that lists each one with its channel count and current rate,
then a pair from the **Channels** menu underneath: 1-2, 3-4, 5-6 and so on.
Left is the first channel of the pair, right the second. This is how a 4-,
8- or 16-channel interface is used: feed the exciter from outputs 7-8, say,
and take the programme from inputs 3-4. A mono channel or a non-adjacent
pair can still be set in the INI (`3`, or `1,4`); the menu then shows it
marked "from settings". Changing the input or output
device or channels restarts the engine. The Monitor's apply live. The keys
behind them are listed in the [Settings
Reference](studio-settings-reference.md#device-channels-multichannel-interfaces).

The **Devices** button at the top of the page lists every audio device the
Mac sees: transport, input and output channel counts, current sample rate,
bit depth and buffer size, with the system default input and output marked.
Plugging or unplugging an interface refreshes the list and the pickers by
itself. **Rescan** re-reads everything by hand. A remembered device that is
not connected stays selected and shows as not connected; the app never
swaps it for another.

Audio-over-IP sources (AES67, SMPTE ST 2110-30, Dante, RAVENNA) work through
the vendor's driver, which presents the stream as an ordinary input device:
on macOS Dante Virtual Soundcard or the Merging RAVENNA / AES67 Virtual Audio
Device, on Linux Merging's ALSA RAVENNA driver or `aes67-linux-daemon`. Pick
it like any other input; the input path's drift correction absorbs the
difference between the network clock and the output card's. Run it at
48 kHz.

### Monitor output

The Monitor is a second audio device that plays what you are putting out, so
you can listen without tuning a receiver to your own transmitter. It runs
ALONGSIDE the transmitter feed: switching it on, moving it to another device
or changing its level never interrupts what is on air, and never needs a
restart. It exists in every operating mode, and what it plays is conditioned
to sound like the receiving end:

| Mode | What the Monitor plays |
| --- | --- |
| MPX Output | the composite demodulated the way an FM receiver does it -- stereo, de-emphasis, pilot and all |
| FM Output | the processed feed with the pre-emphasis taken back out (or as-is when you left pre-emphasis off) |
| HD Output | the processed feed as the encoder receives it: flat, full bandwidth |
| AM Output | the mono feed with the NRSC pre-emphasis taken back out |

`Monitor Level` sets its loudness and cannot change anything on air. Two rules
protect the transmitter: the Monitor never falls back to the system default
device (that default may be the transmitter), and it never shares the MPX
output's channels. On a multichannel interface it may use the same device
on other channels, for example the transmitter on outputs 7 and 8 and
headphones on 1 and 2. If its device is unplugged it stops and stays
stopped until that device returns, with a note in the status line -- the
transmitter feed is untouched throughout. The Monitor is a listening aid, a
few tens of milliseconds behind the output, and never the signal on air.

Headless runs (`--nogui` / `--web`) support the Monitor exactly as the app
does, on Linux too: pick a second ALSA device on the dashboard's Audio I/O
page (the onboard codec, a second USB card, or the `Loopback` card from
`snd-aloop` when something else on the box should pick the feed up). The
same rules hold there: it refuses the transmitter's own card, and an empty
selection is off rather than ALSA's `default`.

Calibration is deliberately separated from the Sound pages because it belongs to the RIG, not the sound -- and it is **remembered per device** (`<config>.devicecal.json` next to the INI): switch the output from one exciter to another and each device's own MPX Output Level / Line Output come back automatically (input devices remember their Input Gain; output levels are kept per operating mode). A device that was re-plugged into a different USB port is matched by name. Format Profiles, presets, and page resets never touch these values, and loading a preset keeps this installation's devices, mode, calibration, and control-server settings (see Presets below).

Two readouts, two domains: the **deviation** meter is a modulation-domain figure -- `output_gain_db` and `mpx_line_output_dbfs` are divided back out, so it reads the same kHz regardless of how the exciter drive is trimmed (before 0.50 it under-read by exactly the output trim), and its kHz scale is fixed -- composite amplitude 1.0 is 75 kHz at any deviation setting, so a 50 kHz station reads 50 kHz at full modulation (before 0.65 it read 33 kHz there). **DAC Peak** is the electrical figure -- the level actually presented to the converter, post both trims. Calibrate deviation at the exciter; watch DAC Peak to know how hot the wire is.

## Setting levels: input, AGC, Final Drive, exciter

Three knobs do most of the work between your source and the exciter. They sit at three different points in the chain and each does a specific job -- get them right in order and the chain sounds clean without much fiddling.

**The chain (left to right):**

```text
source -> IN meter -> AGC -> [DSP] -> Final Drive -> composite clipper -> MPX Output Level -> Line Output -> exciter
                  ^                ^                                 ^                  ^
                  level control    loudness lever                    deviation trim     DAC calibration
```

**1. Get your input into the AGC's working range.** Open `Monitoring`. The `IN` meter shows the level coming into MPX Prime Studio from your source (before any processing). Aim for input peaks landing roughly in the **-12 to -6 dBFS** range on busy programme -- bright but not pinned. If the source is consistently below -18 dBFS the AGC has to push hard to reach its target; if it's above -3 dBFS it's eating its own headroom before the chain even sees it.

The level adjustment lives upstream of MPX Prime Studio -- in your studio mixer, DAW, OS audio output, or BlackHole loopback source's gain. There's also `Audio I/O` -> `Input` -> `Input Gain` (+/-24 dB) inside MPX Prime Studio, but use that only to trim -- the further upstream you fix the level, the less you stack noise floors. The trim is remembered per input device. The Input card's meters have a **Pre / Post** switch: **Pre** shows what the device delivers, **Post** the same signal after Input Gain, which is what the processing receives and what the -12 to -6 dBFS aim refers to. They are Prime Mixer's ladder meters: a 60 dB scale, a peak that falls back at 24 dB/s, a 1.5 s peak hold and a red cap that stays lit for 2 s after a full-scale peak.

**2. Let AGC do the level-evening.** Open `Sound` -> `AGC` (in the Levelling group; it is shown while the Levelling Engine is AGC + Multiband). The AGC's job is to ride out the long-term level differences between songs / shows / sources so the chain downstream sees a roughly constant programme level. The two knobs that matter:

- `Target Level` -- the level the AGC drives the programme *toward*. **Default -14 dBFS** (`wideband_agc_target_db`) is a good starting point and matches what Orban / Omnia / Stereo Tool ship by default. Lower target = AGC pulls more, denser sound; higher = lighter touch.
- `Enable AGC` -- leave on. Even amateur source material (mixed-era MP3s, podcasts, vinyl rips) needs level-evening; without AGC, single-band peak limiting downstream pumps on bass-heavy programme. Keep `Attack` at 100 ms or slower (default 150 ms, profiles 100-200 ms): the AGC is a gain rider, and a fast attack turns every drum hit into a level dip that the release then drags out -- peaks are the Audio Limiter's and composite clipper's job. `--verify` flags an attack below 50 ms.

Watch the AGC's `Gain` in the Monitoring page's Signal Chain card. Healthy operation:

- **0 to 3 dB occasional pulls** = source feeding cleanly, AGC riding lightly. Goal state.
- **Sustained 6+ dB pulls** = source is too hot. Back off upstream.
- **AGC pushing 6+ dB consistently (positive gain)** = source is too quiet. Boost upstream.
- **AGC parked at min/max gain limit** = source is so far off the AGC can't keep up -- fix the source level.

Don't use the AGC's `Target Level` as a loudness knob. It tunes the chain's working point, not perceived broadcast loudness.

**3. Set Final Drive for the loudness you want.** `Sound` -> `Loudness and Output` -> `Final Drive` is the primary loudness lever. It drives the audio composite into the composite clipper -- higher drive = harder clipping = louder, denser, but also harsher. Range 0..12 dB.

- Pick the `Broadcast Preset` matching your content (Balanced Music / CHR-Dance / Punchy / Speech-Talk) -- that sets a sensible Final Drive starting point along with matched AGC tuning.
- Nudge from there. Watch **Composite Clipper GR** in the Monitoring page's Headroom card: it is the clip kernel's gain reduction. The clipper's 2 ms look-ahead rides the composite down to the ceiling plus the profile's `Clip Depth` (Composite Clipper page, under Advanced) and the kernel clips that depth, so the readout follows the drive up to the depth and the look-ahead readout takes over above it. Read the drive off the signal as well:
  - `Composite Budget` reads **Safe** most of the time = clean, dynamic. Good for talk and acoustic music.
  - `Composite Budget` reads **Tight** on the loud passages and **Safe** between them = competitive loudness, contemporary radio sound.
  - **Tight** all the time with the `Audio Limiter GR` (pre-encode) pulling several dB = the clipper is the loudness ceiling; you are trading dynamics and HF cleanliness for level.
  - **Composite Clipper GR** near the profile's Clip Depth with the **Look-Ahead Gain Reduction** (Composite Clipper page) also moving = the programme is driven past the depth and the ride is taking the rest; lower Final Drive or raise Clip Depth, measuring the hi-hat distortion gate (`--verify-hf-transients`) before you keep a deeper setting.

Final Drive is not the same thing as MPX Output Level. Final Drive shapes loudness *inside* the chain; MPX Output Level and Line Output adjust the *voltage* leaving the Mac.

**4. Calibrate the exciter on the Audio I/O Output card.** Two knobs, both remembered per output device:

- `MPX Output Level` (-18..0 dB, attenuation-only in composite mode) trims the whole composite -- pilot and RDS included -- so it is the **deviation calibration**: with the exciter's own input sensitivity fixed, trim it until the exciter shows exactly 100 % modulation (75 kHz) on peaks. Positive values are deliberately not offered: they would squeeze the audio budget (deeper clipping) and push pilot/RDS above their set injection without adding loudness.
- `Line Output` (-40..0 dBFS) sets the absolute DAC level of 100 % modulation -- the **input-sensitivity match** to the exciter. Keep the OS/interface volume at 0 dB and calibrate here. 0.0 dBFS is the classic full-scale convention and the maximum a converter can produce; an exciter that is still under-driven with both knobs at 0 needs its own input sensitivity raised (menu/trimmer) -- no software knob can exceed full scale.
- Watch the **DAC Peak** readout on the same card (the post-both-trims level at the converter) and the `Composite Budget` row on `Monitoring`:
  - **Safe** -- the audio composite has at least 0.5 dB in hand below its budget
  - **Tight** -- the audio composite is on its budget; the normal operating point on dense programme
  - **Risk** -- the final clamp engaged after pilot / RDS injection, or the configuration leaves no audio budget; lower the pilot or RDS level
- On the exciter side: aim for **100 % modulation on peaks** on its modulation meter, or match the input-level recommendation in its manual. *Don't* use these knobs to chase loudness -- that's Final Drive's job.

The deviation readout stays put while you calibrate: it reads the modulation domain (the trims divided back out), so trimming exciter drive changes DAC Peak and what the exciter sees, not the displayed kHz.

**Scripted version with an RTL-SDR** -- `scripts/calibrate-tx.sh --freq <MHz>` (repo root) closes this loop automatically against an off-air measurement: it reads the configured pilot injection over the REST API (start Studio with the control API on), measures the actual pilot deviation with an RTL-SDR through MPX Prime Meter's analysis (refusing railed captures and applying a proper channel filter), and trims `output_gain_db` until they agree -- the pilot is constant-amplitude, so this works with programme on air. Because the output gain is attenuation-only in composite mode, a transmitter that under-deviates at full scale is reported as "raise the exciter's input sensitivity by N dB" rather than silently mis-calibrated; `--watch` prints a fresh measurement every few seconds so you can turn the exciter's trimmer until the error reads 0.0. `--dry-run` measures without changing anything. `--tone` switches Studio to the built-in test tone (a mono 997 Hz sine at -20 dBFS, the 0.45 calibration source) for the duration of the run and restores the programme source on exit -- dense programme puts pre-emphasized HF next to the 19 kHz pilot and wobbles the measurement by about +/-0.1 dB between passes, while with the tone repeat passes agree to a few hundredths of a dB.

The same measurement also verifies the RDS injection end to end: if the reported `rds` kHz sits below `rds_level`, the DAC/exciter path is rolling off toward 57 kHz (the 19 kHz pilot is unaffected, so pilot calibration does not correct it). The dependable fix is to raise `rds_level` by the measured ratio so the ON-AIR injection lands on the intended value -- a restart-class key, so restart the transport and re-measure to confirm.

**Common mistakes:**

- Driving Final Drive hard while MPX Output Level is low -> audio sounds limited but exciter is under-modulated -> quiet on-air. Check the modulation meter.
- Cranking MPX Output Level for loudness -> exciter over-modulates -> splatter / distortion / regulatory issues. Final Drive is the loudness knob.
- Source too quiet -> AGC pushing 8+ dB -> noise floor lifts, breathing on quiet programme. Boost upstream.
- AGC off / bypassed -> multiband and final stage see widely-varying programme levels -> pumping on dense material. Leave AGC on.

## Picking a Format Profile

For one-click "make this sound right", MPX Prime Studio ships five complete Format Profiles plus a `Custom` sentinel, in the **Format Profile** card at the top of `Sound` -> `Overview`. **Re-apply Profile** on the same card puts the selected profile's stage settings back, live. Since the 2026-08 rework a profile owns the FULL chain state -- not just tonal colour: every profile enables the AGC, the pre-encode Audio Limiter, the composite clipper (with 2 ms look-ahead) and the final safety limiter, then sets the format-appropriate multiband / PrimeBass / mono bass / drive on top (every profile also enables the HF Limiter; Music - Loud adds the Bass Clipper). Picking a profile can never leave the always-on safety soft-clips as the de-facto peak controller (the failure mode of the old 8-profile set). Per-stage knobs stay editable afterwards; pick `Custom` to flag "my settings are bespoke".

**Resetting a control.** Every slider has a reset arrow beside its value,
shown only while the slider is away from its reset value; double-clicking
the slider's name does the same. A control resets to the value the ACTIVE
Format Profile gives it, so on a Music - Loud station Final Drive goes back
to 8 dB, not to Music - Clean's 3.5 dB. Controls no profile sets reset to the
shipped default: Input Gain, Output Level, Line Output and Monitor Level to
0 dB, the HD true-peak ceiling to -1 dBTP, the final clipper drive to 6 dB.
A page's own Reset button (for example `Reset AGC`) uses the same values. The shipped defaults are Music -
Clean, so on a fresh install the two agree.

**Upgrading from a pre-0.45 config.** An INI that still carries one of the old profile IDs (`chr_top40`, `pop_ac`, `community_radio`, `rock`, `edm_dance`, `urban_hiphop`, `jazz_classical`, `news_talk`) is **reset on load**: its processing (`[MPX]`) is rebuilt from the nearest new Format Profile (`chr_top40` / `rock` / `urban_hiphop` -> Music - Loud, `edm_dance` -> Music - Dense, `community_radio` / `pop_ac` -> Music - Clean, `news_talk` -> Speech, `jazz_classical` -> Classical), while **RDS, interfaces (devices, sample rate, block size), the control server and the hardware calibration keys (pilot level, deviation, MPX output level, output gain, pre-emphasis, mono mode, test tone) are kept exactly as they were**. The reset config is saved back to disk and both apps say so at startup (status bar in Studio, a line on stderr headless). Reason: those configs typically had the Audio Limiter and Composite Clipper off with the safety soft clips doing all the clipping -- the hi-hat / cymbal distortion field finding -- and carrying that forward under a new label would keep the station distorting. If a current-profile config still has both peak controllers off, the apps warn (but do not reset); press **Re-apply Profile** or enable the Composite Clipper.

| Profile | Character | AGC target | Drive | Extras |
|---|---|---|---|---|
| **Music -- Clean** (default) | Transparent levelling, honest peaks, low clipper work | -16 dB | +3.5 dB | Bass Clipper at the defaults (every vendor structure bass-clips; idle at this drive) |
| **Music -- Loud** | Competitive loudness into the clipper | -15 dB | +8 dB | Bass Clipper, PrimeBass, Band Limiter, presence tilt (+1.5 dB at 80 Hz, +1 dB at 3 kHz), mono bass at 115 Hz |
| **Music -- Dense** (new 0.65) | The top density tier: dance / urban / CHR-dense | -15 dB | +9 dB | Dance multiband (heavy), Bass Clipper, PrimeBass, Band Limiter, mono bass at 110 Hz |
| **Speech / Talk** | Voice-optimized: fast, dense multiband that evens out substandard material | -14 dB | +2.8 dB | Phase rotator on |
| **Classical / Wide Dynamics** | Dynamic-preserving: a gentle 2:1-style ride, at most 6 dB of lift, 3 s release | -18 dB | +5 dB | Light multiband, mono bass at 90 Hz |

Every profile turns Advanced Dynamics on, with its target at the profile's
AGC target (2 dB lower on Music - Loud and Music - Dense, which run
PrimeBass) and its density from the profile's multiband intensity;
the AGC and Multiband settings the profile also carries apply when you switch
Advanced Dynamics off. Its HF Limiter thresholds sit 0.5 dB above its Audio
Limiter threshold (the top-band threshold 1 dB tighter). A fresh
installation's defaults equal Music -- Clean.

Pick once, tune as needed. The selected profile is stored as `format_profile_id`; switching profiles overwrites the per-stage settings to the new profile (except `custom`, a no-op label). Assume a nominal input level around **-12 dBFS** (pro line-up convention) -- the AGC absorbs source variation from there; 0 dBFS masters work but arrive with no headroom of their own.

## Loudness and the final stage

The `Sound` -> `Loudness and Output` page has two cards: **Loudness** (Broadcast Preset, Final Drive) and **Safety Limiter** (`Enable Safety Limiter`; `Threshold` in dBFS, `Enable Look-Ahead` and `Look-Ahead` under Advanced -- all restart-class, so `Reset Loudness and Output` restarts a running engine). `Composite Deviation` is on the `Audio I/O` Output card (MPX Output only) and applies live. The `Audio Limiter` page handles the pre-encode peak limiter on its own: `Enable Audio Limiter`, `Threshold`, `Release`, `Look-Ahead` and, since the 2026-10 overhaul, `Stereo Link` (`pre_encode_stereo_link`, 0-1, default 1, live). At 1 both channels take the louder channel's gain, so the image never moves while the limiter works; below 1 the quieter channel keeps more of its level while the louder one limits, at the cost of a brief image shift toward the quieter side. At the shipped profiles the Audio Limiter is idle on every verifier scenario (the composite clipper after Final Drive is the peak controller), so the control changes nothing audible there; it is for stations that run the limiter harder.

- `Broadcast Preset`: loads a matched AGC + final-stage starting point
- `Final Drive`: drives the composite clipper harder or softer
- `MPX Output Level`: final output calibration, not the main loudness control

**How the final stage controls peaks (0.45).** The composite clipper is the loudness stage; its `Threshold` and `Ceiling` (Composite Clipper page, `mpx_clipper_threshold_db` / `mpx_clipper_ceiling_db`) are read against the *audio-composite budget* -- the part of the composite left after the pilot and RDS reservation -- with the Ceiling landing exactly on that budget, so the composite uses all of it and your calibrated deviation does not move. The reservation is the nominal on-air peak of each service (the pilot level plus the RDS injection), so pilot and RDS fit at every allowed setting; at the defaults the audio sits about 0.3 dB lower than before this rule, more at high pilot or RDS levels. `Composite Deviation` is the peak target of the WHOLE multiplex: at 50 kHz the complete composite, pilot and RDS included, peaks at 50 kHz; above 75 kHz the budget stays at full scale. The `Composite Budget` margin is still measured against 75 kHz, so at 50 kHz it reads about 4 dB with the clipper at work. Behind the clipper, the Safety Limiter (look-ahead) rides down the small in-band overshoot the clipper's pilot / stereo / RDS guard protection leaves (about 1 dB of gain riding on the densest programme is normal), and the always-on safety soft-clips sit idle behind both -- since 0.45 the limiter's detector looks at every sample inside its 5 ms window, so nothing above its threshold reaches the soft-clips and the `Safety Clip` readout stays at 0.0 on dense programme (earlier 0.45 builds leaked up to about 1 dB there while the limiter reported almost no gain reduction). Since the 2026-10 overhaul the detector reads the 4x true peak, so the peaks between samples -- the ones the exciter sees and an off-air measurement showed 0.35 dB above the sample budget -- are held to the budget as well. The clipper's own look-ahead no longer rides every overshoot away: `Clip Depth` (Composite Clipper page, Advanced; `mpx_clipper_lookahead_depth_db`, 0-6 dB) is how far above the ceiling the programme may run before the ride starts, and the clip kernel clips that part. Every Format Profile sets 1.0 dB, the deepest setting that keeps the hi-hat distortion gate with 2 dB to spare on the music profiles (Classical used 2.0 dB until its drive was raised to 5 dB in the 2026-10 levelling work, where 2.0 dB cost the gate's cleanest scenario 6 dB); 0 dB turns the stage back into a look-ahead limiter, which is what every build before the overhaul was (the kernel read 0.16 dB at any drive and Final Drive was undone on dense programme). Before 0.45 the soft-clips ran ahead of the clipper at a lower threshold and did all the clipping themselves -- the cause of the hi-hat / cymbal distortion field report; `--verify-hf-transients` measures that this is no longer the case.

Included presets:

- `Balanced Music`: general-purpose music default
- `CHR / Dance`: hotter final stage for denser contemporary music
- `Punchy Music`: more assertive than balanced, but less hot than CHR
- `Speech / Talk`: tighter AGC with lower final drive

The Monitoring page's Headroom card shows:

- `Audio Limiter GR`: pre-encode limiter gain reduction
- `Composite Clipper GR`: live composite clipper gain reduction
- `Safety Limiter GR`: final safety limiter gain reduction
- `Safety Clip`: how far the composite reached the 1x safety soft clip (0.0 in normal operation)
- `Composite Budget`: remaining whole-composite headroom in dB (within a few hundredths of a dB of zero when the clipper is working, by design), then `Safe`, `Tight` or `Risk` read against the AUDIO budget (see step 4 of the Quick Start)
- `Multiplex Power` and `BS.412 GR`: the BS.412 reading (see below)
- `Bad Input`: non-finite input samples replaced with silence

Practical tuning target:

- `GR` occasionally in the `1 to 3 dB` range is a healthy working zone
- sustained higher GR usually means `Final Drive` is too high for the source
- use `MPX Output Level` only for exciter or interface calibration

In MPX Output, Monitoring also shows the composite calibration:

- `Pilot`, `RDS` (Subcarriers card): the injection in kHz with its share of the deviation, for example `6.0 kHz (8.0%)`
- `Audio Composite` (output card): the audio-composite peak before the pilot / RDS sum
- `Deviation` and `Modulation` (output card): the peak deviation in kHz and as a share of `Composite Deviation`

### When to leave BS.412 and the Composite Clipper off

Both stages are loudness / regulatory tools and both visibly cost stereo image and high-frequency detail when engaged. If you do not need them, leave them off -- the chain still produces a fully compliant FM composite.

- `BS.412` (`Sound` -> `BS.412`): only required if you operate under EU power-limiting rules (a cap on average multiplex power over any 60 seconds). Outside that regulatory context, leave `Enable BS.412` off -- it holds the average power of the whole multiplex to the ceiling, which on dense programme costs several decibels of loudness. When you do need it, the one control is `Ceiling`, in **dBr**: **0 dBr is the limit the Recommendation sets**, so 0.0 is the setting for compliance and a negative value is a safety margin below it. It measures the whole signal you transmit, pilot and RDS included, and it keeps measuring even when the limiter is switched off, so turning it on acts immediately instead of waiting a minute. Two readouts in the Monitoring page's Headroom card tell you where you are: **Multiplex Power** shows the figure in dBr once a full minute has been observed, and shows `42 / 60 s` while it is still filling. **BS.412 GR** shows how much it is holding the audio down. The limiter rides the whole minute's budget rather than every second: loud seconds pass hotter when quieter ones have left room, so on varied programme **Multiplex Power** settles within a few tenths of a decibel of the ceiling instead of 1 to 3 dB under it, and the GR moves gently with the programme instead of parking at the loudest second's value. After a long quiet passage, a loud passage settles about half a decibel under the ceiling for the rest of that first minute while the limiter repays its first seconds of lag -- that is the minute's integral being held, not a fault. A short loud burst is held while it lasts and the programme after it is back on the ceiling within about three seconds, not held down for the rest of the minute. While the Test Tone is running the limiter steps aside so the tone keeps its calibrated level, and the readout says `Suspended (tone)` -- do not read that as compliant. If it says `Pilot and RDS over budget`, your pilot and RDS injection alone exceed the ceiling and no amount of audio reduction can fix it; lower the injection or raise the ceiling. Before 0.65 this control was labelled `Threshold` and read in a different unit that did not correspond to the standard; an upgraded configuration adopts the standard's 0 dBr ceiling.
- `Composite Clipper` (`Sound` -> `Composite Clipper`): trades stereo image and HF cleanliness for raw loudness. Leave `Enable Composite Clipper` off when loudness is not the priority. If you do enable it, the **Protection** controls under Advanced let you choose what to keep clean:
  - `Protect Stereo Pilot`, `Protect RDS` -- leave on (defaults). These keep the 19 kHz pilot and 57 kHz RDS regions clean of clip IM.
  - `Protect Stereo Subcarrier` (shown as 0-100 %, stored as `mpx_clipper_stereo_guard` 0.00-1.00; since 0.45 a share instead of an on/off toggle, the old `mpx_clipper_cancel_stereo = True/False` is read as 1.00/0.00) -- how much of the clipper's distortion is kept out of the 23-53 kHz stereo (L-R) subcarrier. At 100 % the subcarrier passes exactly as it went in, so HF stereo separation is preserved but the clipper only ever removes the mono share of a peak and the Safety Limiter rides whatever overshoot that leaves. At 0 % the clipper clips the whole composite the way Orban, Omnia and Stereo Tool do: the most loudness per dB of drive and the least HF separation on dense programme. Values in between blend, and the blend is not a compromise: the clipper's distortion arrives in short bursts at the crests of the 38 kHz subcarrier, and a receiver decodes about twice as much of such a burst from the stereo subcarrier as from the mono part, so removing HALF of the subcarrier share is what cancels in the quiet channel. The shipped default is therefore **50 %** (since the 2026-10 overhaul; 100 % before): on Music - Loud, programme panned hard left decodes with 60 dB or more of separation in every band that carries programme against 25 dB at 100 % and 27 dB at 0 %, and a left-only 14 kHz tone with 43 dB against 25 dB. The price is about 3 dB of ride-cymbal cleanliness at the same clip depth. The figures come from the `--verify-stereo-guard` sweep (see Verification), which prints clipper and Final-MPX limiter duty, peak, deviation, 10 / 14 kHz separation, the encoder-side M/S balance at 14 kHz, the hi-hat / ride HF SINAD and the programme-crosstalk table for every share. Run the sweep on your own INI before moving the slider.
  - `Protect Audio Highs` -- off by default for maximum loudness. Turn on to recover audible HF detail at the cost of some loudness when the clipper is driven hard.

All of these are exposed in the GUI; no INI editing is required.

## Bass and stereo image

Mono Bass lives on the `Sound` -> `PrimeBass` page (its own card below the Enhancement card -- both are post-multiband bass-domain controls): it collapses low-frequency side energy below a configurable crossover, protecting deviation and FM mono compatibility. Every shipped Format Profile keeps it on (110 Hz for Clean, Speech and Dense, 115 Hz for Loud, 90 Hz for Classical; Clean and Speech were 140 Hz until 2026-10-30). The stereo widener that used to share a tab with it was **removed in 0.50** -- measured on air as adding nothing beneficial. An INI that still carries `stereo_widen_*` keys loads fine; they are ignored.

Recommended starting point:

- `Enable Mono Bass`: on
- `Mono Below`: `90-115 Hz` (the profiles: 110 Hz on Music -- Clean, Speech and Music -- Dense, 115 Hz on Music -- Loud, 90 Hz on Classical; 140 Hz is the high end of broadcast practice and was the default until 2026-10-30)

This keeps bass more mono-compatible while leaving the upper image open enough for FM. The split is linear-phase and sums flat: side bass is 6 dB down at the corner and about 33 dB down at 60 Hz with a 140 Hz corner (less with a lower corner, which is the point of lowering it), nothing above the corner is boosted, and it adds about 1070 / corner-Hz milliseconds of latency (10 ms at 110 Hz, 8 ms at 140 Hz).

**Stereo-image protection** (the `Stereo Image` card under the Mono Bass card, both controls under Advanced; `stereo_image_protect_enabled`, `stereo_image_max_side_ratio`) is a side/mid level limiter ahead of pre-emphasis: it holds the side (L-R) envelope under `Max Side/Mid Ratio` times the mid (L+R) envelope, or under 1.16 times the source's own ratio where that is higher, so a very wide or anti-phase source cannot over-deviate the stereo subcarrier. It was always on until the 2026-10 overhaul, with the former widener's default baked in, and it is **off by default now**: the widener it guarded is gone, every remaining dynamics stage is stereo-linked, and the only width left for it to limit was the source's own -- the stereo audit measured an anti-phase tone losing 24 dB of level against 1.4 dB for a mono tone at the same level, and very wide material clamped to a 1.55 side/mid ratio whatever the source did. Leave it off unless an exciter or studio-transmitter link needs the L-R held down; when you do enable it, `Max Side/Mid Ratio` sets the cap (1.55 is the former behaviour, 1.00 holds the image to ordinary stereo), pure-side content now passes untouched (the stage has no mid to compare against), and its reference is delay-matched to the processing so the end of a wide passage no longer ducks the side. Both keys apply live. `--verify` gates the width without the stage (`stereo_diff_400hz` within 12 dB of its input level, `wide_bass` keeping 90 % of its width) and `--verify-receiver` prints the stage's cost on panned programme and L-only tones in either direction.

### PrimeBass and multiband

The current low-frequency enhancement and multiband stages are now tuned more conservatively than earlier builds.

- `PrimeBass` adds perceived bass weight by synthesising a controlled 2nd + 3rd harmonic series of the bass below its cutoff (missing-fundamental effect): the listener hears more bass on small speakers and car radios without the chain pushing LF peaks higher. Rebuilt in 0.65 after a review found the old generator could not make a 2nd harmonic and let the midrange intermodulate with the bass; On the Enhancement card `Amount` sets the series level, `Harmonics` the 2nd-versus-3rd balance, `Drive` the hardness and `Density` how much quiet bass is lifted, all in percent; `Subharmonic Amount` sets the optional octave divider. Every slider ends where measurement shows the stage stops adding bass and starts adding peaks, pumping or midrange mud, so the full travel is usable. It is gated by `--verify-primebass`.
- `Multiband` uses linear-phase Kaiser-windowed FIR crossovers in TX mode (parallel-cumulative-LP topology, sum-to-flat at `-155 dB`), so percussive transients land time-aligned across all bands and the recombined signal only changes spectral balance when the band gains move -- not when bands fall out of phase. Monitor mode keeps the IIR Linkwitz-Riley 4 cascade for low latency. Since 0.45 each crossover sits at exactly -6 dB with a slope of about half an octave to -40 dB (steeper than a Linkwitz-Riley 4, far gentler than the near-brick-wall edges of earlier builds), and the crossovers cost 9.3 ms of processing latency at the 48 kHz audio domain instead of 21 ms. The `Bands` picker offers 3 or 5 bands (the 2-band mode is gone; a saved 2 loads as 3). With 5 bands the `Active Band` picker reads `Low (Band 1)`, `Mid (Band 3)` and `High (Band 5)`, and bands 2 and 4 take the values halfway between their neighbours. INI key `multiband_fir_enabled` toggles the FIR path (default on). Two advanced options are default-off while being evaluated: `multiband_transient_aware_attack_enabled` for peak/RMS transient handling, and `multiband_inter_band_coupling_enabled` for low-band-GR-driven upper-band threshold bias. `multiband_release_program_dependent` (default on) gives each band a dual-slope release since 0.45: a drum hit's extra gain reduction comes back at the band's release time (no hole after the hit), while a genuine drop in average level releases three times more gently (no breathing when a chorus ends); earlier builds only lengthened the release by 10% under this flag.

Recommended starting point:

- `PrimeBass`: `AC/Pop` or `Rock` preset first
- `Multiband`: `5B AC/Pop` for general music, `5B Talk` for speech, `5B CHR/EDM` for a denser contemporary result, `5B Italo` / `3B Italo` for italo / disco / dance pumping character

The current defaults are intentionally moderate and are meant to be tuned upward from a clean starting point, not downward from a hyped one.

## Advanced Dynamics

`advanced_dynamics_enabled` (default `True` since 2026-10-15; every Format Profile turns it on) replaces the wideband AGC **and** the multiband compressor with one fused 5-band levelling stage. The point of the fusion is that slow levelling and per-band density shaping can no longer fight each other (the classic AGC-pulls-down-while-multiband-pushes-up pumping); each band rides toward a target level with programme-adaptive speed -- near-instant on transients, frozen when the band already sits at target, slower on dense material. You configure the sound you want instead of attack/release times:

- `advanced_dynamics_target_db` (default `-16.0`) -- the wideband level the programme is brought toward. Every Format Profile sets it to its AGC target, which matches the classic chain's loudness into the final stage within the 3 dB the A/B gate allows; the two profiles that run PrimeBass (Music - Loud and Music - Dense) set it 2 dB below, which keeps PrimeBass intermodulation under the `--verify-primebass` limit and costs them no peak level. Until 2026-10 every profile was 2 dB below, and the leveller came out 4 dB quieter than the classic chain on dense programme.
- `advanced_dynamics_low_offset_db` / `advanced_dynamics_mid_offset_db` / `advanced_dynamics_high_offset_db` (defaults `0 / 0 / 0`, range -6..+6 dB) -- a tonal TILT relative to the programme's own balance; the 5 bands interpolate between them. 0 everywhere leaves the programme's spectrum as it is.
- `advanced_dynamics_max_gain_db` (default `12.0`) -- maximum lift for quiet programme (the reduction side is fixed at 24 dB). The default was lowered from 18 after field testing: high boost both chases natural fades harder and lowers the silence gate (`target - max_gain - 10 dB`), pumping tails on sparse material. Raise it deliberately for wide-dynamics formats.
- `advanced_dynamics_density` (`0..1`, default `0.5`) -- denser = tighter hold window and faster levelling. Independently of the knob, the release slows itself on already-dense programme (up to 2.5x at zero fast/slow envelope divergence) and runs at full speed on sparse, dynamic programme; until 0.65 the code had this backwards.
- `advanced_dynamics_speed` (`0.25..4`, default `1.0`) -- overall time-constant scale.

How it levels (since 2026-10-15). One wideband gain, measured on the whole programme, carries the loudness and all the adaptive ballistics. Each band then adds a slow correction for a SHORT-TERM departure from its own long-term share of the programme (an 8 s memory), bounded to +3 / -3 dB (-6 dB on the two top bands, which may cut in 5 ms to tame sibilance and cymbal bursts), plus the tilt above. A steady programme therefore keeps its spectrum and, because each band applies one gain to both channels, its stereo image. The earlier law levelled every band to an absolute target: it re-equalised all programme toward one spectrum (up to +10 dB on a single band) and on dense bass cut the correlated bass against lifted upper bands, dropping L/R correlation from 0.90 to 0.74.

A built-in **decay guard** distinguishes "programme actively fading" from "programme is quiet": while the programme's envelope sits well below its recent peak (a note or song decaying naturally), the leveller holds instead of lifting, resuming when the level stabilizes or new material arrives. Without it a solo decaying sound (a bell, a fade-out) gets its fade flattened and extended -- heard as added ringing/sustain.

Band layout follows `multiband_x1_hz..multiband_x4_hz`. All keys are live-apply. When the stage is enabled the AGC and Multiband settings are ignored (those stages are bypassed); when it is disabled the chain is bit-identical to before the stage existed. It is evaluated with `--verify-advanced-dynamics`. A profile carries its levelling character into the stage: its AGC target becomes the leveller target (2 dB lower with PrimeBass on), its multiband intensity the density (light 0.35, normal 0.5, heavy 0.7).

In both front ends the stage is one of two **Levelling** engines, chosen in the **Levelling Engine** card on the Sound Overview page (GUI and web dashboard alike): **Advanced Dynamics** (the default) or **AGC + Multiband** (the classic chain, with the per-band Expander and Band Limiter that run inside the multiband stage). The choice IS `advanced_dynamics_enabled` and applies live. The pages of the engine not in use are hidden -- sidebar, Overview grid, Monitoring signal chain and pill strip -- so there are no dimmed panes to scan past (until 0.65 they stayed visible, ghosted, behind a "bypassed" banner); if one of them was open, the app shows the Overview instead. The Advanced Dynamics page has no enable toggle of its own; the selector is the switch. Its band layout follows the Multiband page's crossovers; switch to AGC + Multiband to edit them.

While the stage is active, the Monitoring dashboard's Signal Chain "AGC" pill switches identity to **Adv Dyn** and reads the leveller's density plus its five per-band gains (low to high, dB); the web dashboard's Headroom card gains the matching "Adv Dynamics" row. The AGC readouts honestly report the AGC as Off (gain 0.0) while it is bypassed -- the leveller replaces it, so a moving "AGC gain" would be stale telemetry. Over the API the same values are `advancedDynamicsActive`, `advancedDynamicsBandGainsDB` (5 floats, low to high), and `advancedDynamicsDensityDB` in `GET /api/meters` (null while the stage is off).

The stored AGC, Multiband, Expander and Band Limiter settings are untouched while Advanced Dynamics is selected -- switching back restores the exact previous behaviour. A test pins the replacement as total: with the leveller on, extreme AGC/multiband settings produce bit-identical output to having those stages off.

## Saving setups: the eight preset slots

Eight operator preset slots store complete configurations -- every INI
setting, not just one stage -- so you can capture a tuned state and A/B
whole setups. In the GUI they live under **Presets** in the sidebar; since
0.44 the web dashboard's Presets page exposes the same eight slots (they
are shared storage, so a slot saved in the GUI loads from the dashboard
and vice versa). Per slot: a name field, **Load** (applies the whole
snapshot as one change, with live-apply where possible and Restart to
Apply where not), **Save** (capture the current config) and a **More**
menu with Import, Export and Clear. Slots can be
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

`Setup` -> `Test Tone` (View > Test Tone, Cmd-T; `source_mode = tone`, `test_tone_*`) replaces the audio input with a sine, pink or white source, live. Since 0.45 it is a **calibration source, not programme**: the tone bypasses every gain-changing stage -- input gain, AGC, EQ, multiband / Advanced Dynamics, enhancers, bass / HF / audio clippers, HF and Audio Limiters, Final Drive, the composite clipper, BS.412 and the final limiter -- while the delay-bearing stages stay in the path so pilot and RDS remain aligned. **0 dBFS = 100% of the audio modulation** left after the pilot/RDS reservation, and the scale is linear in dB, so the composite audio deviation is exactly `mpx_deviation_khz x budget x 10^(level/20)` (budget ~0.85 with 8% pilot and 2 kHz RDS at 75 kHz: -20 dBFS gives ~6.4 kHz of audio deviation plus ~8 kHz of pilot/RDS). A sine is pre-compensated for the pre-emphasis curve, so it reads the same deviation at 400 Hz, 1 kHz or 10 kHz; pink / white noise are peak-normalised and not compensated. The page shows the expected audio and total deviation for the current `Tone Level`, pilot and RDS settings, and the status bar's Source reads `Test Tone` while it runs -- compare it with the Meter or a modulation monitor to calibrate the exciter. Before 0.45 the tone ran through the whole processing chain, so any level was lifted by the AGC into the clipper and produced full, clipped deviation ("way too loud, and the level slider does nothing"); `TestToneGeneratorTests` now pins level-in / deviation-out. The `Left` / `Right` routing modes double as a **channel-assignment check** on a real receiver: a left-routed tone must come out of the receiver's left speaker. Until 0.45 the encoder sent the stereo difference with the opposite sign to 47 CFR 73.322 / ITU-R BS.450-3, so every real receiver played L and R swapped (the built-in monitor and MPX Prime Meter compensated silently and could not show it); if you calibrated channel assignment against that behaviour, re-check it after upgrading.

## Getting RDS on air

RDS rides a 57 kHz subcarrier, so it needs the full 192 kHz composite: at
96 kHz or below there is no RDS at all. Everything below lives in the `RDS`
sidebar section (web dashboard: the RDS pages), and every field applies live
except the injection. A page's Reset button follows the same rule: it applies
live on every RDS page except Subcarrier, which restarts the engine.

1. **Turn it on.** `RDS` -> `Status` -> `Enable RDS` (`en_rds` in the `[RDS]`
   section). The same page holds the TP, TA and MS switches and shows what is
   actually going out right now: PS, Radiotext, PTYN and Long PS as receivers
   see them.
2. **Identify the station.** `RDS` -> `Identity`, Station card: the four-hex-digit `PI` code
   (it encodes country and coverage -- look yours up in the [country
   table](rds-country-and-pty-tables.md#rds-pi-and-ecc-country-table)), the
   `PTY` programme type ([code
   list](rds-country-and-pty-tables.md#rds-programme-type-pty-codes)) under
   `Programme Type (PTY)`, and, on the Station Name (PS) card, the
   eight-character `PS` station name. Set `ECC` as well if you want receivers
   to resolve the country unambiguously. The `PTY Names` picker chooses which
   table labels the programme types (Europe RDS or North America RBDS); the
   five bits transmitted are the same either way. Long PS has its own card on
   the same page; LIC, PIN, PTYN, decoder information and `Enable ID` are under
   Advanced.
3. **Say what is playing.** `RDS` -> `Radiotext` carries up to 64 characters
   in the `Default Radiotext` field, with `Message A` to `Message D` for
   rotating manual messages. It accepts timed and scrolling segments and the `{artist}` / `{title}`
   placeholders that a now-playing script or the REST API fills in; the
   grammar is in the [Settings and API
   Reference](studio-settings-reference.md#rds-text-syntax).
4. **Set the injection level.** `RDS` -> `Subcarrier` -> `Injection`
   (`rds_level`) is in **kHz of deviation** at any Composite Deviation setting,
   referenced to the standard's all-zeros data stream, so 2.0 means 2.00 kHz on
   air (default 2.0, slider 0-7.5), with the share of 75 kHz shown underneath.
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
Loudness and Output pages, the pilot level and the MOD (deviation) meter
disappear, the MPX Spectrum and Scopes windows are disabled (greyed out in the
toolbar and the Window menu), RDS stops being generated and the Now Playing
script stops being polled. The Monitor plays the processed feed instead of a
decoded composite. The status bar's Mode chip names the mode.

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

### Feeding an external stereo coder or exciter (FM Output)

In FM Output the processor delivers finished, peak-controlled L/R audio and
the external box builds the multiplex. Two rules make that work:

1. **The processor limits, the coder does not.** Set the coder's input so the
   processor's peaks give exactly the target deviation, and keep the coder's
   own limiter or clipper above that point so it never acts.
2. **Exactly one device pre-emphasises.** Leave pre-emphasis on in MPX Prime
   Studio (50 us in Europe, 75 us in the Americas) and switch the coder's
   pre-emphasis OFF. Flat audio into a coder that adds 50 us gains about
   13.7 dB at 15 kHz, which defeats the peak control.

**Output Level.** Programme peaks leave at full scale at 0 dB. A coder wants
them at its reference level instead. The Output Level reset arrow gives -9 dB
in FM Output, which is the PROFline SFY's documented AES/EBU reference
(-9 dBFS) and +6 dBu on an interface aligned to the German broadcast
convention (+15 dBu at 0 dBFS). On other interfaces the target in dBFS is the
coder's dBu reference minus the interface's dBu at 0 dBFS:

| Interface alignment (0 dBFS =) | Peak for a +6 dBu coder | Peak for a +4 dBu coder |
|---|---|---|
| +15 dBu (ARD) | -9 dBFS | -11 dBFS |
| +18 dBu (EBU R68) | -12 dBFS | -14 dBFS |
| +24 dBu (SMPTE RP155) | -18 dBFS | -20 dBFS |

Reference levels in use: +4 dBu (US / AES), +6 dBu (EBU / BBC and German ARD
practice, about 1.55 V, peaks near +8 to +9 dBu), 0 dBu on some European
equipment, and +10 dBm into 600 ohm on older US exciters.

Known input ranges (from the manufacturers' data):

| Unit | Input | Level for full modulation |
|---|---|---|
| PROFline SFY stereo encoder | XLR 600 ohm balanced; AES/EBU | +6 dBu analogue, -9 dBFS digital (one sheet says -8), trim -20..+12 dB; pre-emphasis 0 / 50 / 75 us; audio deviation 40-75 kHz |
| PROFline DMM (SFY successor) | XLR 600 ohm or high-Z; AES/EBU 110 ohm | +6 dBu, -6 dBFS digital, referenced to 40 / 65 / 67.5 / 75 kHz |
| PROFline SFM | XLR L / R | not published; L / R trims -9..+6 dB |
| RVR TEX / Blues | XLR-F balanced; AES/EBU option | adjustable -13..+13 dBu; AES 0..-10 dBFS |
| Nautel | 600 ohm balanced, transformerless | adjustable -12..+12 dBu |
| Elenos | 10 kohm or 600 ohm balanced | adjustable -10..+15 dBu for 75 kHz |
| DB Elettronica | balanced | adjustable -6..+6 dBu for 75 kHz |

**Alignment.** Play the Test Tone (1 kHz or 400 Hz) at the processed full
level, set the coder's input gain (or "audio deviation") until a modulation
meter reads the target, typically 67.5 kHz of audio so pilot and RDS fit
inside 75 kHz total, then return to programme. Leave the coder's deviation
limiter a few kHz above the total so it only guards against faults.

### HD Output (streaming and digital radio)

The FM-only stages leave the path: the audio keeps its full bandwidth (up to
the `Programme Lowpass` setting under Basics > Advanced, allowed to 20 kHz here), pre-emphasis is forced
off, stereo-image protection (where enabled) is skipped because a digital carrier has neither
deviation nor multipath to protect, the pre-emphasis-aware HF Limiter page
is hidden and inactive, and the final loudness clipper is not offered --
clipping into a codec costs quality. Their saved settings are retained for the
next time the box returns to an FM or AM path. Peaks are held at the true-peak
ceiling instead of being normalised to full scale.

### AM Output

The AM feed is **mono**: left and right are summed before the processing, so
every stage levels and limits the signal that actually goes on air, and both
output channels carry it.

- **AM Pre-emphasis** (`am_preemphasis_us`, restart-class): 75 us is the NRSC-1
  curve an NRSC receiver de-emphasises. It is not the same curve as FM's 75 us
  even though both are named for the same time constant -- the AM one levels
  off above about 8.7 kHz, which is what keeps the top of the band from being
  over-emphasised into a channel that cannot carry it. Switch it off only when
  the transmitter or an outboard box already applies it -- the same one-stage
  rule as on FM.
- **AM Bandwidth** (`am_lowpass_hz`, restart-class, 3-10 kHz): NRSC-1 specifies
  10 kHz; many stations run 4.5-6 kHz to fit the channel and the receivers.
- **Positive Peak Headroom** (`am_positive_peak_pct`, live, 100-125 %):
  asymmetric modulation. 47 CFR 73.1570 allows positive peaks to 125 % while
  the negative peak stays at 100 %, so MPX Prime Studio holds the **negative**
  side at 100/125 of full scale and lets positive peaks use the rest.
  **Calibrate the transmitter on the negative peak**: set it so a negative peak
  at full modulation reads 100 %. Symmetric programme lands symmetric; speech and
  most single-instrument material is what actually uses the extra positive
  room. At 100 % the mode is symmetric again and the feed is simply normalised.

The composite stages, the stereo coder, the pilot and RDS are not generated in
AM Output. This mode is new in 0.50 and has been verified by measurement (mono
sum, the NRSC curve, the band limit and the peak asymmetry each have a test);
it has not yet been checked against a modulation monitor on a real AM
transmitter.

**True-peak ceiling.** In HD Output, `Audio I/O` ->
`Operating Mode` -> `True-Peak Ceiling` (`processed_audio_ceiling_dbtp`,
live-apply) sets where peaks land. **-1.0 dBTP** is the default and the shared
recommendation of EBU R128, AES TD1008 and the streaming platforms. Use
**-2.0 dBTP** when the next box is a data-reduction codec such as DAB+ or AAC:
lossy encoding pushes inter-sample peaks up, and the extra headroom is what
keeps them from clipping in the listener's decoder. The ceiling is a true-peak
figure: a look-ahead guard after the limiter holds inter-sample peaks to it
on every programme, at the cost of 2 ms of extra delay. The same guard runs in
FM Output, where it holds full scale, so dense programme never hard-clips at
the converter there either.

**Loudness is set upstream**, by the AGC's Target Level, not by this
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
Audio I/O -> Operating Mode -> **Coder Has Its Own Clipper**:

- Leave **ON** (default) if your coder clips/limits its input -- MPX Prime Studio stays
  clean to avoid double-clipping.
- Turn **OFF** if it does not -- MPX Prime Studio then applies an oversampled
  distortion-cancelled final clipper, with a **Final Clipper Drive** slider
  (0-12 dB) to set density. Two clippers in series sound harsh, so only enable
  this when the coder genuinely does not clip.

### Output level and rates

- **Output level:** the Audio I/O Output card's **Output Level** slider (`output_gain_db`, remembered per output device and per mode). The
  processed feed is normalised so the limiter ceiling lands at full scale at 0 dB; lower it to match
  your coder's input reference, raise it for a hotter feed.
- **Sample rate / bit depth:** run **48 kHz / 24-bit** end to end (the 111 kHz
  stereo / 118.8 kHz RDS rule is composite-only). Match the output device format in Audio MIDI Setup to
  `sample_rate`. See BUILDING.md / the rate notes for the full rationale.
- **Auditioning:** because the output is plain L/R, you can route it to any
  monitors/DAW to A/B processing changes. Listen with pre-emphasis **Off** so the
  monitored signal is not artificially bright; the decoded-MPX monitor remains the
  reference for final on-air sound.

INI keys: `operating_mode`, `preemphasis_us`,
`processed_audio_coder_has_clipper`, `processed_audio_final_clip_drive_db`,
`output_gain_db`.

## Watching the signal

The Monitoring page's Headroom card shows **Safety Limiter GR**, the final look-ahead MPX limiter's gain reduction (about 1 dB on dense programme is normal: it rides the composite clipper's guard-band overshoot and, since the 2026-10 overhaul, the peaks between samples that its 4x true-peak detector sees; since 0.45 it reports the true amount it removes). **Safety Clip** next to it is how far, in dB, the composite exceeded the budget and had to be caught by the 1x safety soft clip; it must read 0.0 in normal operation -- anything above zero means the composite clipper and final limiter are not controlling the peaks (both off, or an impossible gain structure) and the distortion class fixed in 0.45 is back. The same value is `safetyClipDB` in `GET /api/meters` and "Safety Clip" on the dashboard.

**Bad Input** in the same card ("Bad Input Samples" on the web dashboard,
`nonFiniteInputSamples` in `GET /api/meters`) counts input samples that
arrived as NaN or Inf and were replaced with silence. It reads `none` in
normal operation and is shown in every operating mode, because the guard runs
in every mode: anything else means something upstream of the encoder is
broken, even though the chain carried on.

- `Audio I/O` -> `Output` is the composite/baseband output device
- `Audio I/O` -> `Monitor` is the second device the Monitor output plays on, alongside the transmitter feed
- The orange microphone indicator in the macOS menu bar is the system privacy indicator and appears when MPX Prime Studio is actively using audio input
- `Mono Mode` now transmits true mono composite and suppresses pilot, stereo subcarrier, and RDS while enabled
- If a remembered input / output / monitor device is not connected, **Start is refused** with an alert rather than silently streaming to the OS default -- reconnect the device or pick another in `Audio I/O`. (Devices are remembered by UID and name, so moving an interface to another USB port keeps the selection.)

To save CPU the meters, scopes and spectra update only while you can see them:
at full rate while the app is in front, at 20 Hz (12 Hz on Intel) while a
window showing live values is visible behind another app, and at 4 Hz while
the engine is stopped, every window is covered or minimised, or no window
shows live values. The scopes and spectra are computed only while their
window is on screen. The web dashboard pauses its updates while its browser
tab is hidden and catches up when you return to it.

### Monitoring windows

Beyond the `Monitoring` page, Studio offers detachable instrument windows,
opened from the toolbar or the Window menu in the same order: Levels (Cmd-6),
Audio Spectrum (Cmd-7), MPX Spectrum (Cmd-8) and Scopes (Cmd-9). MPX Spectrum
and Scopes are disabled outside MPX Output, which is the only mode that
generates a composite. Like the Meter's displays, they are dark instrument
panels and repaint in `Canvas` so a live value change never triggers a layout
pass:

- **MPX Spectrum** -- the composite (MPX) spectrum after stereo encoding, with the
  same FM band-region overlay the Meter draws: **Mono L+R**, **19 kHz Pilot**,
  **Stereo L-R** (lower and upper sideband -- the same L-R signal mirrored around 38 kHz), **57 kHz RDS**, and **SCA** captions mark where each component
  sits, so you can confirm the pilot, subcarrier, and RDS land in the right
  places at the right levels.
- **Audio Spectrum** -- an RTA-style bar spectrum of the stereo audio with a
  **Pre / Post** switch: Pre is the input as it arrives, Post the processed
  audio about to be encoded (or leaving the output in FM, HD and AM Output).
  Both read at about 12 Hz resolution.
- **Scopes** -- composite / decoded-monitor waveforms.
- **Levels** -- ladder meters for every level you set, in their own window:
  input (with the same **Input Pre / Input Post** switch as the Audio I/O
  Input card) and the output, titled with the operating mode. In FM, HD and
  AM Output the output is a left / right pair; in MPX Output it is one
  composite bar plus
  **MOD**, the deviation on a 0-100 kHz ladder that turns red at your
  deviation limit and keeps its red cap lit for 2 s after a peak more than
  2 % over it. Under each ladder is the held peak of its loudest bar.

## Operating it from a browser

The encoder embeds an HTTP control server for remote and automation use --
on macOS (GUI or `--nogui`) and on the Linux CLI build. It is **disabled by
default**. The dashboard's meters follow the engine at up to 20 updates a
second (a push stream from the server; behind a proxy that buffers, or on an
older server, they fall back to a 300 ms poll).

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
starts it headless with the dashboard, on macOS and Linux alike. Before the
run it prints the dashboard URL, the config path and the API key the
dashboard will ask for (read from that config's `[CONTROL]` section), and it
refuses to start when something already listens on the control port --
usually an earlier instance -- naming the process, instead of launching a
second encoder beside it.

**Security:** binding 127.0.0.1 needs no key. Binding any other interface
REQUIRES `control_api_key` -- the server refuses to start remote-exposed
without one. A headless run whose control server cannot start (that refusal,
or the port already in use) exits with status 1 and says why: an encoder
without its dashboard cannot be reached, and a second copy on a port another
instance holds would only fight it for the audio devices. Clients send the key as `Authorization: Bearer <key>` or
`X-API-Key: <key>`. The server speaks plain HTTP; for access beyond a
trusted network, front it with a TLS reverse proxy (nginx/caddy).

Open `http://<host>:8737/` in a browser for the dashboard. Since 0.44 it
mirrors the Studio GUI page-for-page, with the same names: a pinned status
bar (Transport, Source, Rate and Mode, a Monitor chip while the Monitor plays,
the RDS rate warning and a Restart to Apply badge, then the Start/Stop,
**Bypass** and Restart buttons) above five sidebar sections -- the same five, in the same order, as the
native GUI's sidebar, named for what you are doing rather than for how the
engine is built. Sections fold and remember it; a page's breadcrumb (for
example "Sound > Dynamics") says where you are. A **Search settings** box at
the top of the sidebar finds any control by its label or setting name
("pilot", "release", "deviation") and jumps to it, opening the Advanced
card it lives in; the landing page offers task shortcuts (set my levels,
change the station text, load a preset, switch operating mode); and on a
phone the sidebar becomes a drawer behind the menu button and every slider
gains a numeric field for exact values:

- **On Air** -- Monitoring: source/output devices, input meters, MPX
  deviation / modulation, per-stage gain-reduction readouts, subcarrier
  injection + budget margin, and stream health (uptime, ring-buffer fill,
  OVR/UND drop counters, resample trim; on Linux xruns and render load),
  plus a signal-chain card grid.
- **Setup** -- everything done once per rig: Audio I/O (input / output /
  monitor device pickers -- selecting one is a restart-class change; the
  Operating Mode; the level calibration sliders Input Gain, Output Level,
  Line Output, remembered per device like the native GUI; Composite
  Deviation; the engine format: sample rate, block size, Start Engine at
  Launch, the FIR choices and 96 kHz Spectrum; the Monitor;
  the card mixer on Linux; and the read-only Remote Control card showing the
  server's own settings, which stay INI/GUI-only by design), and Test Tone.
- **Sound** -- Overview (start here: the Format Profile card with its
  **Re-apply Profile** button, the Levelling Engine card, and the Stages
  grid with enable switches), then the stages grouped by what they
  do to the signal, in signal order: **Input** (Basics, Phase Rotator),
  **Levelling** (AGC or Advanced Dynamics, one at a time; see Advanced
  Dynamics), **EQ** (Parametric EQ), **Dynamics** (Multiband incl.
  crossovers X1-X4, Expander, Band Limiter -- the last two run per band
  inside the multiband stage), **Bass** (PrimeBass + Mono Bass, Bass
  Clipper), **Peak Control** (Audio Clipper, HF Limiter, Audio Limiter)
  and, in MPX Output only, **Transmission** (Stereo Coder, Composite
  Clipper incl. look-ahead + oversampling, BS.412, Loudness and Output).
  Real switches and sliders with the GUI's control vocabulary, applied
  live on release; each page has the GUI's Reset button, named after the
  page, where the GUI has one.
  Every stage page shows first what you move while listening -- enables,
  thresholds, ratios, ceilings, drives, targets -- and folds time constants,
  topology choices and set-once protections into a collapsed **Advanced**
  card; the GUI folds the same controls into an "Advanced" group.
- **RDS** -- Status (Enable RDS, TP / TA / MS, on-air PS/RT/PTYN/Long
  PS), Identity (Station, Station Name (PS), Long PS, Advanced), Radiotext
  (Default Radiotext, Messages A-D, RT+, Now Playing), Alt. Frequencies
  (list + method), Schedule (group sequence, scheduler, Clock Time, Time
  Zone), Subcarrier (Injection).
- **Presets and System** -- Presets (per-stage preset pickers plus the 8
  operator preset slots: name, Save/Load/Export/Clear, Import into empty
  slots), an Advanced page holding the raw all-settings editor, and About.

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

The `Bypass` control does not create a true wire bypass. It disables the creative processing blocks while keeping essential FM encode stages active. It is available in the GUI (Control > Bypass, Cmd-B, which carries a checkmark while on; the toolbar button, which reads `Bypassed` in red; and the status bar's red `Processing: Bypassed` chip, which turns processing back on when clicked) and, since 0.44, on the web dashboard's status strip -- the flag is restart-class, so toggling it remotely restarts the engine (the dashboard asks for confirmation first).

Always active:

- Input gain
- Programme lowpass
- Pre-emphasis
- MPX encoding
- Final drive, deviation scaling, and limiting
- Output gain

Disabled by bypass:

- Phase rotator
- AGC
- High-pass filter
- HF trim
- Parametric EQ
- PrimeBass
- Mono bass
- Multiband processing (incl. the per-band Expander and Band Limiter)
- Advanced Dynamics
- Bass and audio clippers
- Audio Limiter (pre-encode)
- Stereo-image protection (where enabled; off by default since 2026-10)

## The MPX Prime Meter companion

MPX Prime Meter is the receive/analyse counterpart to the encoder, shipped
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
  and that processing is not bypassed (the toolbar button reads `Bypass`,
  not `Bypassed`).
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
  then check that the HF Limiter is on (the default in every Format
  Profile) and that its threshold still sits half a decibel above the Audio
  Limiter's.

For an ears-on check after any change, `docs/test-playlist.md` lists reference
tracks chosen to expose specific artifacts -- asymmetrical peaks, sibilance,
dense bass, wide stereo -- with what to listen for in each.

To prove a change measurably rather than by ear, the offline verification
gates render deterministic scenarios without touching audio hardware; they are
documented in [BUILDING.md](BUILDING.md#offline-verification).
