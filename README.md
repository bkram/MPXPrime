# MPX Prime Studio

Version: 0.44

MPX Prime Studio is an FM composite (MPX) generator written in Swift. It takes live audio input or a test tone, applies optional broadcast-style processing, generates stereo FM baseband with pilot and optional RDS, and sends the MPX (plus optional decoded monitor audio) to the sound hardware.

**It runs on two platforms:**

- **macOS** — a native SwiftUI application: the **MPX Prime Studio** encoder plus its companion **MPX Prime Meter** analyzer, both shipped in one DMG (Core Audio, full GUI).
- **Linux** — the **encoder** runs headless from the command line (ALSA output, no GUI), with the embedded REST API + **web dashboard** as its interface. SIMD-accelerated so the full chain runs in real time on low-power hardware (a fanless Celeron J4105 handles it); shipped as a Debian/Ubuntu package with a systemd service.

The same DSP core drives both: a full broadcast-style processing chain — phase rotator, wideband AGC, 4-band parametric EQ, 3-/5-band multiband compressor, stereo widener, PrimeBass, bass and audio-band clippers, L/R pre-emphasis, pre-encode true-peak limiter, BS.412 power limiting, and an oversampled composite clipper — ahead of a pilot-locked stereo encoder, keeping the pilot and RDS subcarriers out of all peak control (post-clipper injection). The Linux build is bit-for-bit the same processing; only the audio backend and the front end differ.

> **Intended use and status.** MPX Prime Studio is for **experimental, hobby, and small-budget broadcast** — community / LPFM stations, pirate and SDR-fed exciters, prosumer encoding, and study of FM signal processing. It implements core behavior from EN 50067 / IEC 62106 and common FM-stereo practice, but it is **experimental and not certified — no conformity or compliance is promised.** Do not rely on it for regulated production broadcast.

## App structure

The macOS GUI is organised into these sections. The Linux build has no GUI — the **web dashboard** (see [Remote control](#remote-control)) mirrors this same layout (Monitoring, per-stage Processing incl. the Format Profile picker, RDS, Interfaces, Test Tone, Presets with the shared 8 operator preset slots), so the two front ends feel the same.

- `Monitoring`: live status, transport, interfaces summary, DSP status, RDS snapshot
- `Processing`: Overview, Core, Phase Rotator, AGC, Parametric EQ, Multiband (with optional transient-aware attack + inter-band gain coupling), experimental single-stage Advanced Dynamics leveler (replaces AGC+multiband when enabled), Expander, MB Limiter, Stereo Widener, PrimeBass, Bass Clipper, DC Clipper, Audio Limiter, Composite Clipper (optional look-ahead peak control, experimental multiband composite clipping, and the experimental SSB Stereo encoder (SSB-leaning stereo encoding) on top of the soft-clipper), BS.412, Final Stage
- `RDS`: status (master enable + live snapshot), identity (PI / PTY / PTYN / ECC + PS banks + runtime flags TP / TA / MS / DI), radiotext (RT / RT+ / Now Playing), long PS, alt. frequencies (AF), schedule (group sequence + clock-time), subcarrier (injection level + frequency + Gaussian shaping)
- `Tools`: Test Tone (sine / pink / white, four stereo modes, frequency presets, dBFS level — replaces the audio input live when enabled, ⌘T)
- `Settings`: configuration path, interfaces, output mode (MPX composite vs processed audio), audio engine, spectrum options
- Separate windows: `Scopes`, `Spectrum` (composite spectrum with FM band captions -- Mono L+R, 19 kHz Pilot, Stereo L-R, 57 kHz RDS, SCA), `Levels`, `Help`

The RDS detail tabs are organised per UECP message-class taxonomy
(AF is a peer of PS, RT+ lives under ODA, etc.). Every operationally
toggled RDS setting applies live without restarting the transport —
PI, PTY, PTYN, TP/TA/MS/DI flags, AF list, group sequence, CT
enable, all RT/PS/Long PS text. Only physical-layer settings
(`rds_level`, Gaussian shaping FIR taps/BW) require a
transport restart since they reconfigure the modulator.

## MPX Prime Studio — the encoder (macOS + Linux)

Makes the FM multiplex. Runs as a macOS GUI app or headless on macOS/Linux.

- Real-time MPX generation with 19 kHz pilot and 38 kHz stereo subcarrier
- **Premium receiver-side stereo separation** at the default config (0.28): 65 dB at 1 kHz, 50.5 dB at 10 kHz, 43.4 dB at 14 kHz, measured by `--verify-receiver` through the reusable `MPXDecoder` (matches Optimod 8x00 / Stereotool published numbers)
- Optional RDS generation with pilot-locked 57 kHz subcarrier
- Live input source or built-in **Test Tone** generator (sine / pink / white, mono / L=−R / left-only / right-only modes, frequency presets, −60..0 dBFS level slider, live Enable toggle that replaces the audio input without restarting the engine)
- Optional wideband AGC, HPF, program lowpass, HF trim, PrimeBass, mono bass, stereo widener, and multiband processing (including 0.28 opt-in transient-aware attack + inter-band gain coupling)
- Broadcast-style **Final Stage** (Broadcast Preset + Final Drive + Composite Deviation + Final-MPX safety limiter with look-ahead) and a separate **Audio Limiter** tab (pre-encode 4× oversampled stereo-linked true-peak limiter with default-on look-ahead and Dolby HF-subband-aware detector — `US 5,579,404`, expired 2013 — for audibly cleaner HF transients and preserved LF punch), feeding the 16× oversampled composite clipper (with optional OS-rate sliding-window-max look-ahead peak control and experimental default-off multiband composite clipping) with live clipper telemetry
- Calibrated **MPX line output** in dBFS for repeatable exciter drive
- TX-path engine toggles on the Core tab: linear-phase FIR encoder lowpass and FIR multiband splitters (latency vs. quality choices, restart-required)
- Composite budget telemetry with pilot/RDS/audio visibility, safety-limiter readout, and a composite budget governor that holds the audio path under the post-injection clamp so pilot/RDS subcarrier amplitude stays constant for sane configs (over-budget flag for impossible configs)
- Broadcast preset picker for AGC/final-stage tuning (`Balanced Music`, `CHR / Dance`, `Punchy Music`, `Speech / Talk`)
- Italo / disco / dance multiband presets (`5B Italo`, `3B Italo`) with pumped low-band character
- Decoded MPX monitor output on a selectable monitor device
- **Processed-audio output mode** (Settings - Output Mode): emit processed stereo L/R instead of the FM composite, to feed an external stereo coder + RDS encoder on transmitters that only accept L/R / AES3 audio. Runs the full audio chain (no composite clipper / BS.412 / pilot / RDS), with selectable pre-emphasis (apply it here, or stay flat if the coder does); runs at the audio device rate (48 kHz / 24-bit recommended). Composite-only and RDS controls hide while it is active.
- Scopes, spectrum, levels, sticky peaks, and live monitoring views (macOS GUI; the dashboard shows live meters/readouts and exposes the scope/spectrum data via `GET /api/telemetry` for external tooling — no in-browser graphs)
- **Remote control** — an embedded, default-off REST API + web dashboard for local or remote operation ([see below](#remote-control)); it is the primary interface on the headless Linux build. Since 0.44 the dashboard has **full parity with the native GUI**: every setting, station formats + final-stage presets, the 8 operator preset slots (shared with the GUI), and a scope/spectrum telemetry endpoint for external tooling
- **Linux command-line build** (experimental): the encoder runs headless with ALSA output, SIMD-accelerated so the full chain fits low-power hardware; shipped as Debian/Ubuntu packages with a systemd service. No GUI, no Meter.
- Config persisted to the INI (`~/Library/Application Support/MPX Prime Studio/MPX Prime Studio.ini` on macOS; `~/.local/share/...` or `/var/lib/mpxprime/` on Linux)

## MPX Prime Meter — the analyzer (macOS only)

The receive/analyze counterpart, shipped as `MPX Prime Meter.app` in the same
DMG. Where Studio *makes* the composite, the Meter *measures* it: feed it an
MPX composite (a Core Audio input device, or a live station via an in-process
RTL-SDR / SDRplay tuner) and it decodes stereo + full RDS on one dashboard
window. Its deviation, MPX-power, and SM.1268 readings were cross-validated
against a Profline SFP-X measuring receiver (pilot / RDS matched exactly, peak
deviation within the SM.1268 +/-2 kHz tolerance). **macOS only, Apple Silicon
(the SDR tuner is arm64) — there is no Linux or Intel Meter.**

- Decoded scopes (composite, decoded L, decoded R) and a stereo vectorscope
- MPX spectrum (0-100 kHz) with band captions (Mono L+R, 19 kHz Pilot,
  Stereo L-R, 57 kHz RDS, 67.65 kHz Direct Band, 92 kHz SCA), and on SDR an
  **RF spectrum** of the band around the tuned carrier (span up to ~+/-1 MHz)
  for spotting adjacent channels and splatter
- Measurement-grade deviation + modulation metering to ITU-R SM.1268-5 /
  BS.412-9: IN / L / R / M / S levels + correlation; pilot / RDS / total
  **MAX / AVE / MIN** deviation; **MPX power (ITU-R BS.412** uniform sliding
  60 s window) with the worst-window **MPX MAX**; trailing-60 s **peak +/-
  deviation**; the **OVER 77 kHz** SM.1268 exceedance statistic; the
  accumulated **deviation distribution** (1 kHz bins -- what share of the
  programme reaches each deviation, the reading a single MAX number cannot
  give); best stereo separation; **L/R balance**; **carrier frequency
  offset**; a **signal-quality** rating from the noise above the modulated
  baseband; **SIGNAL** (SDR RSSI); and deviation / MPX-power trend graphs
- Full RDS decode: PI / PS / PTY / RT / RT+ / Long PS / CT / AF / group
  histogram (counts + shares) and the last 18 groups **in transmission
  order** + live BER, plus the **RDS subcarrier phase** (EN 50067 sec 1.2:
  the angle to the pilot's third harmonic, which must be 0 or 90 deg within
  10 deg -- flagged when an encoder sits between the two)
- **WAV recording**: the decoded stereo audio, or the raw MPX composite
  (24-bit, capture rate), for later re-analysis
- Input: an audio device, or **in-process SDR** tuning (`Source -> SDR`) --
  **RTL-SDR** and **SDRplay RSP** (auto-preferred when present) are decoded by a
  linked-in tuner library (no helper process, no Homebrew for end users), just a
  connected dongle. Frequency, IF bandwidth, gain / auto gain,
  LNA, antenna, Bias-T, PPM, and RTL AGC all retune **live** (no restart).
  Headless terminal modes also exist (`./run-meter.sh --device <n>` / `--stdin`)

See the [MPX Prime Meter manual](docs/manual-meter.md) for details.

## Remote control

An embedded, default-off **REST API + web dashboard** (`[CONTROL]` in the
INI, or the GUI Settings tab) controls the encoder locally or remotely:
transport, live meters, RDS text/TA, sound presets, and every INI setting
with live-apply where the engine supports it. Localhost needs no
authentication; any wider bind requires an API key. See the
[user manual](docs/manual.md#remote-control-rest-api--web-dashboard).

This is a **MPX Prime Studio (encoder)** feature only — on both macOS and
Linux. The **MPX Prime Meter has no REST API or web interface** for now;
it is operated from its own window (or its headless terminal modes).

## Output modes

MPX Prime Studio drives its main output device in one of two modes, chosen in
**Settings → Output Mode** (restart-required). What you need from your hardware
depends on which you use:

- **MPX Composite** (default) — the finished FM multiplex: mono sum + 38 kHz
  stereo subcarrier + 19 kHz pilot + optional 57 kHz RDS, for a transmitter /
  exciter that accepts a composite ("MPX" / "wideband" / baseband) input.
  **Needs a 192 kHz output device** so the ~59 kHz upper RDS sideband stays below
  Nyquist. A 96 kHz device can carry stereo but **not** RDS.
- **Processed Audio** — the processed stereo **L/R** audio only (no pilot /
  subcarrier / RDS / composite clipper / BS.412), for transmitters that accept
  only L/R analog or AES3 audio and have their own stereo coder + RDS encoder.
  **48 kHz / 24-bit is all you need** — the high composite sample rates do not
  apply. Pre-emphasis is selectable (apply it here, or stay flat if the coder
  does), with an optional final loudness clipper. See the
  [user manual](docs/manual.md#processed-audio-output-mode).

A separate, optional **Decoded Monitor** output (any sample rate) demodulates the
internal composite back to L/R for headphone monitoring on a second device — a
listening aid, not the on-air signal.

## Requirements

- macOS 15+ (primary platform). An experimental **Linux command-line port**
  of the encoder (headless `--nogui` into an ALSA device, verifier, benchmark;
  no GUI, no Meter) builds from the same source tree -- see
  [docs/BUILDING.md](docs/BUILDING.md#linux-cli-only).
- **Platform support tiers:** **Apple Silicon (arm64) is Tier 1** — the primary, fully-supported target. **Intel (x86_64) is Tier 2, best-effort** — the universal binary runs and the audio chain is identical, but performance tuning (e.g. the GUI refresh profile) targets Apple Silicon first; Intel gets lighter-weight fallbacks where they help but is not the optimization priority.
- Xcode command line tools / Swift 6 toolchain (only needed for building from source — download the DMG below if you just want to run it)
- **Audio output device — depends on the output mode (see above):**
  - *MPX Composite with RDS:* an external USB / Thunderbolt interface that runs
    **192 kHz** natively. Built-in Mac audio tops out at 96 kHz, which cannot
    carry the 57 kHz RDS subcarrier; 96 kHz can do stereo-without-RDS.
  - *Processed Audio (feeding an external coder):* **48 kHz / 24-bit is
    sufficient** — built-in audio or any interface works.
- The output device's format in Audio MIDI Setup must match the configured
  `sample_rate`, or Core Audio's implicit resampling starves the render thread.
- Input devices may run at any rate; the app converts internally.

## Download

Pre-built universal binaries (Apple Silicon + Intel) ship as macOS `.dmg` files on the project's GitHub Releases page:

**[github.com/bkram/MPXPrime/releases](https://github.com/bkram/MPXPrime/releases)**

Each release is built and signed by GitHub Actions from the matching tag. Pick the latest version, download `MPX_Prime-<version>.dmg`, and drag the apps into `/Applications` (or any folder you prefer). The DMG contains **two** apps: **MPX Prime Studio** (the encoder) and **MPX Prime Meter** (the companion analyzer, below) — install whichever you need.

**Linux (encoder only):** the same releases attach Debian/Ubuntu packages
`mpxprime_<version>-ubuntu24.04_amd64.deb` (static Swift stdlib; installs and runs on later Ubuntu releases too).
Install with `sudo dpkg -i mpxprime_*.deb` (or `sudo apt install ./mpxprime_*.deb`
to pull dependencies); it provides the headless encoder as a `mpxprime`
systemd service with the web dashboard. This is the CLI encoder only — no GUI,
no Meter. See [docs/BUILDING.md](docs/BUILDING.md#linux-cli-only) for setup.

### First-launch security note

MPX Prime Studio is **ad-hoc signed**, not Apple-notarized. The DMG is built and signed by an automated GitHub Actions workflow with a self-managed signing identity — it is *not* enrolled in the Apple Developer Notary Service. As a result, macOS Gatekeeper will refuse to open the app on first launch with a message similar to:

> *"MPX Prime Studio" cannot be opened because Apple cannot check it for malicious software.*

This is the standard macOS warning for any app distributed outside the Mac App Store / Apple Notarization. To approve the app once:

1. Open **System Settings → Privacy & Security**.
2. Scroll to the **Security** section near the bottom. You will see a message like *"MPX Prime Studio was blocked from use because it is not from an identified developer"*.
3. Click **Open Anyway** next to that message.
4. The next time you launch MPX Prime Studio, macOS will prompt one more time — click **Open**.

After the first approval, MPX Prime Studio launches normally on subsequent runs. This is a one-time per-version operation; updating to a new release will trigger the prompt again on first launch.

If you would rather skip the Gatekeeper dialog entirely, build from source (see [docs/BUILDING.md](docs/BUILDING.md)) — locally built binaries are not subject to the same check.


## Documentation

- [docs/manual.md](docs/manual.md) — **MPX Prime Studio manual**: usage, first-time setup, configuration, RDS text, monitoring windows, verification, and the RDS PI/ECC + PTY reference tables
- [docs/manual-meter.md](docs/manual-meter.md) — **MPX Prime Meter manual**: SDR/audio input, the measurement readouts, WAV recording, and calibration
- [docs/BUILDING.md](docs/BUILDING.md) — build, run, verify, test, and package from source
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — detailed DSP chain and stage descriptions
- [`AGENTS.md`](AGENTS.md) — contributor / agent workflow guidance and release checklist
- [`plan.md`](plan.md) — roadmap
- [`CHANGELOG.md`](CHANGELOG.md) — version history

## References

- Standards PDFs and notes live in `documents/` (EN 50067 / IEC 62106-2 / IEC 62106-6 / UECP SPB 490 / ITU-R BS.450)


## Acknowledgements

The block-level RDS bit encoder in `BasicRDSCoder` — CRC (`0x5B9`), offset words, and the four-block group assembly shared by groups 0/2/3A/4A/10A/11A/15A — was initially ported from the Python `RDSHelper` in [ryanginn/rds-master](https://github.com/ryanginn/rds-master). Everything around it is MPX Prime Studio's own work: the 1187.5 bit/s biphase + Gaussian shaping FIR, the pilot-locked 57 kHz subcarrier generation, the audio-thread real-time pipeline (pre-allocated bit buffer, atomic CT cache, monotonic-clock timing), the `RDSRuntimeConfig` live-apply path, AF Method B, RT+ ODA (AID 0x4BD7), Group 4A clock-time with MJD + TZ, Group 10A PTYN, Group 15A Long PS, Group 1A ECC/LIC, the Stereotool-compatible text grammar, and the full FM composite chain that the encoder feeds into.

## Trademarks

MPX Prime Studio is an independent open-source project and is not affiliated with,
endorsed by, or sponsored by any of the companies named in this documentation.
Product and company names — including Orban, Optimod, Omnia, Stereo Tool /
Stereotool, Aphex, Waves, and others — are trademarks of their respective owners
and are used here descriptively only, to identify published behavior, prior art,
and platform APIs for comparison.

## License

GPL-3.0. See `LICENSE`.
