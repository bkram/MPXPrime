# MPX Prime Studio

Version: 0.50

MPX Prime Studio turns your programme audio into the signal an FM transmitter
needs. You feed it the station's audio; it makes it loud, clean and consistent
the way broadcast processors do, adds stereo and RDS (the station name and
text on the radio's display), and sends the finished signal to a sound card
that is wired to your transmitter. It also has other output modes for a
transmitter that does its own stereo coding, for a web stream or DAB+ encoder,
and for an AM transmitter.

It comes with **MPX Prime Meter**, a separate app that does the opposite:
it receives an FM signal (from a sound card or a cheap USB radio dongle) and
measures what is on air -- deviation, stereo, RDS -- so you can check your
own transmitter or somebody else's.

> **Intended use and status.** MPX Prime Studio is for **experimental, hobby, and small-budget broadcast** -- community / LPFM stations, pirate and SDR-fed exciters, prosumer encoding, and study of FM signal processing. It implements core behavior from EN 50067 / IEC 62106 and common FM-stereo practice, but it is **experimental and not certified -- no conformity or compliance is promised.** Do not rely on it for regulated production broadcast.

## Two ways to run it

- **On a Mac** -- a normal Mac application with windows, meters and menus
  (`MPX Prime Studio.app`), plus the Meter app, both in one download. Every
  setting is also reachable from a web browser if you want it.
- **On a small Linux computer** -- as an appliance: you install one package,
  the encoder runs in the background from the moment the machine boots, and
  you operate it from **a web page** on any computer or phone in your
  network. There is no screen or keyboard to attach; the web page has every
  control the Mac app has, laid out the same way.

The sound is identical on both: it is the same processing, checked in the
same automated tests.

## What it does

- **Makes your station sound like a station.** A full broadcast processing
  chain -- levelling, multiband compression, bass enhancement, clipping and
  peak control -- with ready-made **Format Profiles** (music, loud music,
  speech, ...) so you can start from a sound that fits your programme and
  fine-tune from there.
- **Stereo and RDS.** Pilot, stereo subcarrier and an RDS encoder with
  station name, radiotext (including "now playing" from your player), clock
  time, alternative frequencies, traffic flags and more. RDS text changes go
  on air immediately.
- **Four operating modes**, one choice for what leaves the sound card:
  - **MPX Output** -- the complete FM signal for a transmitter with a
    composite / MPX input (the usual case).
  - **FM Output** -- processed stereo audio for a transmitter that has its own
    stereo coder and RDS encoder.
  - **HD Output** -- clean, full-range audio for a web stream or a DAB+ /
    digital radio encoder.
  - **AM Output** -- a mono feed shaped for an AM transmitter.
- **Listen to yourself.** A **Monitor** output plays what you are putting out
  on a second sound card or headphones, so you can hear the result without
  tuning a radio to your own transmitter.
- **Test tone and meters.** A built-in calibration tone, live level and
  deviation meters, and (on the Mac) scopes and a spectrum view of the signal.
- **Presets and settings that survive.** Eight preset slots for complete
  setups; the levels you calibrate for a particular sound card are remembered
  per device, so switching transmitters brings back the right settings.
- **Remote control.** A web dashboard and a REST API, off by default on the
  Mac and always on for the Linux appliance, protected by an access key.

The [Operator Guide](docs/studio-operator-guide.md) explains all of this
step by step; the [Settings and API Reference](docs/studio-settings-reference.md)
lists every setting.

## What you need

- **A Mac** (macOS 15 or newer -- any Apple Silicon Mac, or an Intel Mac from
  2018 on), **or a Linux PC** (Debian / Ubuntu, 64-bit Intel or AMD; tested on
  Ubuntu 24.04 and 26.04). Old low-power PCs are not enough: the processing
  runs on one CPU core, and that core needs to be a reasonably modern one --
  an Intel N100-class mini PC is the smallest that fits, a Core i3 or a Ryzen 5
  is comfortable. [docs/performance.md](docs/performance.md) has measured
  figures and a simple test (`--bench`) to check a machine before you buy.
- **A sound card for the transmitter.** For the complete FM signal (MPX
  Output) it must run at **192 kHz** -- an external USB or Thunderbolt audio
  interface; built-in Mac audio cannot. For the other three modes any sound
  card at 48 kHz will do.
- **Any input** for your programme audio: a sound card, a virtual audio device
  from your playout software, or the built-in test tone to start with.

## Download

Ready-made builds are on the project's GitHub Releases page:

**[github.com/bkram/MPXPrime/releases](https://github.com/bkram/MPXPrime/releases)**

**Mac:** download `MPX_Prime-<version>.dmg`, open it and drag the apps into
`/Applications`. It contains both apps; install the one(s) you need. The
apps are signed by the project, not by Apple, so the **first launch** shows
the standard "Apple cannot check it for malicious software" message: open
**System Settings -> Privacy & Security**, click **Open Anyway** next to the
message, and launch again. Once per version.

**Linux:** download `mpxprime_<version>-ubuntu24.04_amd64.deb` (it runs on
newer Ubuntu releases too) and install it:

```bash
sudo apt install ./mpxprime_*.deb
sudo systemctl enable --now mpxprime
```

The installer prints the dashboard's **access key** once (you can read it
back later with `sudo grep control_api_key /var/lib/mpxprime/MPXPrime.ini`).
Open `http://<the computer's address>:8737/` in a browser, paste the key, pick
your sound card on the Audio I/O page, and you are on air. Upgrades keep your
settings and restart the service. The [Operator Guide's Linux chapter](docs/studio-operator-guide.md#running-on-linux-the-web-dashboard-encoder)
walks through it; [docs/BUILDING.md](docs/BUILDING.md) covers building from
source on either platform.

## How this project is built

MPX Prime is written largely **with AI assistance**: the signal processing,
both apps, the tooling and this documentation were produced by directing
Claude (Claude Code) and reviewing the result. That is a reason for extra
care, not less: nothing here is trusted because it reads well. The processing
is scored by automated measurements -- deviation, peak control, stereo
separation, distortion -- against numbers that are pinned per platform, so a
change that alters the signal has to be made deliberately or the build fails;
several hundred tests run on every change on macOS and Linux; and the
readings were cross-checked against a commercial measuring receiver and on
real radios. That discipline has found faults that read perfectly fine as
code -- an inverted stereo difference signal that every in-house check agreed
with, and a distortion problem that turned out to be two stages in the wrong
order. Only measurement found them. Details are in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [`AGENTS.md`](AGENTS.md).

## Documentation

- [docs/studio-operator-guide.md](docs/studio-operator-guide.md) -- **MPX Prime Studio Operator Guide**: install, first-time setup, audio devices and levels, Format Profiles, RDS, monitoring, running on Linux, troubleshooting
- [docs/studio-settings-reference.md](docs/studio-settings-reference.md) -- **Settings and API Reference**: every configuration key, the RDS text grammar, the now-playing script protocol, the REST API
- [docs/meter-operator-guide.md](docs/meter-operator-guide.md) -- **MPX Prime Meter Operator Guide**: SDR / audio input, the measurement readouts, WAV recording, calibration notes
- [docs/rds-country-and-pty-tables.md](docs/rds-country-and-pty-tables.md) -- **RDS country codes and programme types**
- [docs/performance.md](docs/performance.md) -- what the processing costs on the machines it has been measured on, and the minimum / recommended CPU
- [docs/BUILDING.md](docs/BUILDING.md) -- build, run, verify, test, and package from source
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) -- the signal chain in detail, for the technically minded
- [`AGENTS.md`](AGENTS.md) -- contributor / agent workflow guidance and release checklist
- [docs/project-roadmap.md](docs/project-roadmap.md) -- project roadmap
- [`CHANGELOG.md`](CHANGELOG.md) -- version history
- [`CONTRIBUTORS.md`](CONTRIBUTORS.md) -- authors, the initial RDS port, vendored code and library licenses

## References

- Standards PDFs live in `standards/` (EN 50067 / IEC 62106-2 / IEC 62106-6 / UECP SPB 490 / ITU-R BS.450); they are not redistributed, see [standards/README.md](standards/README.md)

## Acknowledgements

The block-level RDS bit encoder in `BasicRDSCoder` was initially ported from
the Python `RDSHelper` in
[ryanginn/rds-master](https://github.com/ryanginn/rds-master); the Meter's
in-process tuner is a vendored subset of
[FM-SDR-Tuner](https://github.com/bkram/FM-SDR-Tuner). Full credits, what came
from where, and the library licenses are in
[CONTRIBUTORS.md](CONTRIBUTORS.md).

## Trademarks

MPX Prime Studio is an independent open-source project and is not affiliated with,
endorsed by, or sponsored by any of the companies named in this documentation.
Product and company names -- including Orban, Optimod, Omnia, Stereo Tool /
Stereotool, Aphex, Waves, and others -- are trademarks of their respective owners
and are used here descriptively only, to identify published behavior, prior art,
and platform APIs for comparison.

The names **MPX Prime**, **MPX Prime Studio** and **MPX Prime Meter** identify
this project. They may not be used in any **commercial offering** -- a product,
a service, a hosted instance, a bundle, or its marketing -- without the prior
written approval or a license from the project maintainer (ask via the
[GitHub repository](https://github.com/bkram/MPXPrime)). This is a trademark
condition, not a software-license condition: the code stays AGPL-3.0 and may be
used, modified and sold under that license, but a commercial fork or service
built on it ships under its own name unless approval was given.

## License

**AGPL-3.0** (GNU Affero General Public License, version 3). See `LICENSE`.
Since 0.50; releases up to 0.44 were GPL-3.0. The Affero clause matters for
the web dashboard encoder: whoever runs a modified version as a service for
others must offer them the source, exactly as a distributor of the binary
would. The vendored `tuner/` code stays GPL-3.0 (its own license permits
combining it with an AGPL-3.0 program); dependencies keep their own licenses
(see `CONTRIBUTORS.md`).
