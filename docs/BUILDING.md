# Building from source

This document covers building, running, testing, and packaging MPX Prime from
source. If you only want to run the app, download the release DMG instead — see
the [Download](../README.md#download) section of the README.

## Requirements

- macOS 15 or later
- Swift 6 toolchain (Xcode 16+ or the matching Command Line Tools)
- For running the **test suite**: a full Xcode install (the Command Line Tools
  do not ship `Testing.framework`)

The package is a Swift Package Manager project rooted at `macOS/`. Its SwiftPM
dependencies are `swift-atomics` and `hummingbird` (2.x, pulling in SwiftNIO --
the embedded remote-control REST server, compiled into `MPXPrime` on both
platforms). Building the **`MPXPrime`** encoder needs nothing else. Building the **`MPXPrimeMeter`** analyzer additionally requires the
Homebrew SDR libraries its in-process tuner links — `brew install librtlsdr
liquid-dsp` — and, optionally, the SDRplay API SDK (installed under
`/Library/SDRplayAPI/`) to compile the SDRplay RSP backend; without the SDK the
Meter still builds and falls back to RTL-SDR. Because the Meter links the
arm64-only RTL-SDR libraries it is **Apple-Silicon-only**; build the x86_64
release slice with `--product MPXPrime` to skip the Meter and its `CMPXTuner`.

## Build

Debug build:

```bash
swift build --package-path macOS
```

Release build:

```bash
swift build --package-path macOS -c release
```

> **Debug builds are not real-time capable.** `swift build` (no `-c release`)
> and `swift run` produce a debug binary without compiler optimizations. The
> audio render thread shares CPU with the main-thread UI loop, and on a debug
> build the meter / scope / spectrum work in `refreshMonitoringSnapshot` is slow
> enough to occasionally preempt the audio thread — you will hear clicks, buffer
> underruns, or input-ring overflows. Debug builds are fine for development,
> unit testing, and `--verify` runs (which do not touch real audio devices), but
> **for actual on-air or monitor playback always use a release build**: either
> `swift build --package-path macOS -c release` followed by running
> `macOS/.build/release/MPXPrime`, or use the DMG produced by `./build-release.sh`.

## Run

From the repository root:

```bash
swift run --package-path macOS MPXPrime                       # GUI
swift run --package-path macOS MPXPrime --nogui               # headless
swift run --package-path macOS MPXPrime --seconds 10          # fixed runtime
swift run --package-path macOS MPXPrime --config "/path/to/MPX Prime Studio.ini"
```

The default user config lives at
`~/Library/Application Support/MPX Prime Studio/MPX Prime Studio.ini`.

### Running the Meter (`MPXPrimeMeter`)

The companion analyzer builds and runs the same way (Apple Silicon; needs
`brew install librtlsdr liquid-dsp`). The `run-meter.sh` helper builds a release
Meter and launches it:

```bash
./run-meter.sh                       # GUI; auto-detects an SDRplay / RTL-SDR dongle, else audio
./run-meter.sh --sdr-freq 88.6       # GUI pre-tuned to an SDR station, capturing
./run-meter.sh --device 0 --channel right --seconds 30   # headless audio-device capture
./run-meter.sh --stdin --full-scale-khz 150              # headless, composite piped on stdin
```

The in-process SDR (RTL-SDR / SDRplay) is GUI-only; the headless dashboard takes
an audio device (`--device`) or a composite on stdin (`--stdin`). See the
[Meter manual](manual-meter.md) for the full control surface.

## Linux (CLI-only)

The encoder also builds and runs on Linux as a **command-line-only** port
(experimental; dev-tested on Ubuntu 24.04 x86_64). The GUI, the MPX Prime
Meter, and the SDR tuner remain macOS-only. Everything the headless encoder
offers works: `--nogui` live encoding into an ALSA device, all `--verify*`
modes, `--capture-baseline`, and `--bench`.

Install the toolchain and dependencies:

```bash
sudo apt install -y build-essential curl pkg-config binutils libc6-dev \
  libcurl4-openssl-dev libedit2 libgcc-13-dev libpython3-dev libsqlite3-0 \
  libstdc++-13-dev libxml2-dev libz3-dev tzdata unzip zlib1g-dev \
  libasound2-dev alsa-utils
# Swift 6 via swiftly (the official toolchain manager):
curl -O "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz"
tar zxf "swiftly-$(uname -m).tar.gz" && ./swiftly init
swiftly install latest
```

Build, verify, and test exactly as on macOS, except no `DEVELOPER_DIR`
override is needed (the Linux toolchain ships Testing.framework):

```bash
swift build --package-path macOS -c release
swift test --package-path macOS
macOS/.build/release/MPXPrime --verify --seconds 5
macOS/.build/release/MPXPrime --nogui --config /path/to/config.ini
```

Linux specifics:

- **Devices are ALSA PCM names.** The `input_device_uid` / `output_device_uid`
  INI keys hold ALSA device strings (`default`, `hw:0,0`,
  `plughw:CARD=Loopback,DEV=0`) instead of CoreAudio UIDs; empty means
  `default`. List devices with `aplay -l` / `arecord -l`. A `hw:` device must
  support the configured `sample_rate` natively or start-up fails with a clear
  error; `plughw:`/`default` let alsa-lib convert (with an SRC warning printed).
  Your user must be in the `audio` group.
- **Default config path** is `~/.local/share/MPX Prime Studio/MPX Prime
  Studio.ini` (the XDG mapping of Application Support).
- **Real-time scheduling** is best-effort: the audio threads request
  SCHED_FIFO and silently fall back if the rtprio rlimit forbids it
  (`ulimit -r`; configure `/etc/security/limits.d/` for production use).
  Xrun counts are printed at stop.
- **Per-platform strict baseline.** Apple and Glibc libm (and vvtanhf vs the
  scalar tanh shim) differ at rounding level, so Linux pins its own
  `--baseline-strict` file, `macOS/verifier_baselines/default-linux-x86_64.json`
  (`default.json` stays macOS-only). The physical `--verify` thresholds are
  identical on both platforms.
- **Loopback smoke test** without audio hardware: `sudo modprobe snd-aloop`,
  point `output_device_uid` at `hw:Loopback,0,0`, run the encoder with
  `source_mode = tone`, and capture the composite from the other end:
  `arecord -D hw:Loopback,1,0 -f FLOAT_LE -r 192000 -c 2 -d 8 capture.wav`.
  The pilot (19 kHz, 8 percent) and RDS sidebands (around a suppressed 57 kHz
  carrier) should be visible in any spectrum tool.

### Debian/Ubuntu package

`./build-deb.sh <version> [distro-label]` builds `mpxprime_<ver>_amd64.deb`
from a release build (`swift build --package-path macOS -c release
--product MPXPrime --static-swift-stdlib` first -- the Swift runtime is
linked statically; remaining system deps are computed by dpkg-shlibdeps).
The package installs `/usr/bin/mpxprime` (+ the web-dashboard resource
bundle), a `mpxprime.service` systemd unit (dedicated `mpxprime` system
user in the `audio` group, config at `/var/lib/mpxprime/MPXPrime.ini`,
created with defaults on first run; `LimitRTPRIO` grants the audio threads
real-time scheduling), the sample INI, and the docs. Enable with
`systemctl enable --now mpxprime`. Release tags build and attach the Ubuntu 24.04 deb automatically
(`.github/workflows/release.yml`); the 26.04 leg was removed until Swift.org
ships a 26.04 toolchain -- the 24.04 deb uses a static Swift stdlib and
installs/runs on 26.04 in the meantime. Pushes to `develop/**` and PRs to
`main` run CI (`.github/workflows/ci.yml`): build + tests + the fast verify
gates (incl. `--verify --baseline-strict`) on macOS and Ubuntu 24.04.

Internals: the `MPXPrimeAcceleration` target supplies same-name implementations
of the small vDSP/vForce surface the encoder uses (plus an
`OSAllocatedUnfairLock` polyfill) on platforms without Accelerate -- on macOS it
compiles to an empty module and the real Accelerate is used, so macOS numerics
are untouched. The hot paths (`vDSP_dotpr`/`vDSP_conv`/`vvtanhf`) are
vectorized with portable Swift SIMD (SSE2 on x86-64 baseline; no AVX
required) -- this is what lets the full chain (FIR multiband crossovers +
16x composite clipper) run in real time on small CPUs like the Celeron
J4105 (~92% of a core at 192 kHz, zero xruns; the scalar versions were
~102% and starved). The shim is pinned against real Accelerate by a golden
fixture plus SIMD accuracy tests (`AccelerateShimTests`; regenerate the
fixture on macOS with `MPXPRIME_CAPTURE_GOLDEN=1`). The ALSA engine lives
in `macOS/Sources/MPXPrime/ALSAAudioEngine.swift`.

## Remote control server

`--control` (alias: `--web`) / `--control-port N` enable the REST API + web dashboard for a
headless run (or set `[CONTROL] control_enabled = True`). See the user
manual's "Remote control" section for endpoints and the security model. `./run-build-web.sh`
(repo root, macOS + Linux) builds the release binary and runs it headless
with the dashboard in one step.

## Offline verification

The verification harness renders deterministic test scenarios without opening
any audio devices, so it runs safely on a debug build:

```bash
swift run --package-path macOS MPXPrime --verify --seconds 5                  # scenario sweep
swift run --package-path macOS MPXPrime --verify-presets --seconds 5          # 5-band preset sweep
swift run --package-path macOS MPXPrime --verify-long --seconds 30            # long-run regression
swift run --package-path macOS MPXPrime --verify-receiver --seconds 5         # receiver-model decode
swift run --package-path macOS MPXPrime --verify-composite-multiband --seconds 2   # A/B multiband clipper
swift run --package-path macOS MPXPrime --verify-multiband-coupling --seconds 2    # A/B inter-band coupling
swift run --package-path macOS MPXPrime --verify-advanced-dynamics --seconds 4     # A/B single-stage leveler
swift run --package-path macOS MPXPrime --verify-rulebreaker --seconds 4            # A/B SSB stereo encoder
```

Baseline capture + strict compare:

```bash
swift run --package-path macOS MPXPrime --capture-baseline    # writes macOS/verifier_baselines/default.json
swift run --package-path macOS MPXPrime --verify --baseline-strict
```

Exit codes: `0` = PASS, `1` = TIGHT (near limits, review), `2` = WARN.

See the [Offline verification](../README.md#offline-verification) section of the
README for what each report field means.

## Tests

Tests use **Swift Testing** (`import Testing`, `@Test` / `#expect`) — not
XCTest. Running them requires a full Xcode install, so `DEVELOPER_DIR` must point
at Xcode (the Command Line Tools ship no `Testing.framework`):

```bash
# Full default suite (fast, ~10 s)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path macOS

# Single suite / filter
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path macOS --filter BassClipperTests
```

Optional deep DSP combination suite (~3 min; opt-in, catches stage-interaction
regressions — run before a release or when touching multiple stages):

```bash
MPXPRIME_DEEP=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path macOS --filter Deep
```

## Accessibility lint

UI changes should pass the accessibility lint before committing:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftlint
```

The project ships a `.swiftlint.yml` that runs only
`accessibility_label_for_image` and `accessibility_trait_for_button`.

## Release build and DMG

Build a universal release app bundle and DMG:

```bash
./build-release.sh 0.41
```

Artifacts are written to `macOS/dist/`.

Releases ship by merging the integration branch (`develop/v.NNN`) into `main`,
tagging `v<version>` from `main`, and pushing the tag — which triggers
`.github/workflows/release.yml`, runs `./build-release.sh <version>`, and
publishes the resulting DMG as a GitHub Release.

## See also

- [ARCHITECTURE.md](ARCHITECTURE.md) — detailed DSP chain and stage descriptions
- [`AGENTS.md`](../AGENTS.md) — full contributor / agent workflow guidance,
  conventions, and the release validation checklist
- [`plan.md`](../plan.md) — roadmap
