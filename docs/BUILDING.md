# Building from source

This document covers building, running, testing, and packaging MPX Prime from
source. If you only want to run the app, download the release DMG instead -- see
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
Homebrew SDR libraries its in-process tuner links -- `brew install librtlsdr
liquid-dsp` -- and, optionally, the SDRplay API SDK (installed under
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
> enough to occasionally preempt the audio thread -- you will hear clicks, buffer
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
`brew install librtlsdr liquid-dsp`). The `scripts/run-meter.sh` helper builds a release
Meter and launches it:

```bash
scripts/run-meter.sh                       # GUI; auto-detects an SDRplay / RTL-SDR dongle, else audio
scripts/run-meter.sh --sdr-freq 88.6       # GUI pre-tuned to an SDR station, capturing
scripts/run-meter.sh --device 0 --channel right --seconds 30   # headless audio-device capture
scripts/run-meter.sh --stdin --full-scale-khz 150              # headless, composite piped on stdin
```

The in-process SDR (RTL-SDR / SDRplay) is GUI-only; the headless dashboard takes
an audio device (`--device`) or a composite on stdin (`--stdin`). See the
[Meter manual](manual-meter.md) for the full control surface.

## Linux (CLI-only)

The encoder also builds and runs on Linux as a **command-line-only** port
(experimental; dev-tested on Ubuntu 24.04 x86_64). The GUI, the MPX Prime
Meter, the SDR tuner and the Monitor operating mode remain macOS-only, and the
web dashboard / REST API is the only operator interface (the package enables
it on all interfaces behind a generated API key; a hand-run build passes
`--web`). Everything
the headless encoder offers works: `--nogui` live encoding into an ALSA
device, the `--verify*` modes (except `--verify-program-ab`, which decodes
audio files through AVFoundation), `--capture-baseline`, and `--bench*`. The
live scripts (`scripts/smoke-live.sh`, `scripts/ab-music-live.sh`, `scripts/capture-program.sh`)
need BlackHole / Core Audio and are macOS-only.

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
  Studio.ini` (the XDG mapping of Application Support; the Debian package's
  service uses `/var/lib/mpxprime/MPXPrime.ini` instead). Same INI format and
  keys as macOS; the `<config>.devicecal.json` and `<config>.snapshots.json`
  sidecars sit next to it exactly as on macOS.
- **Real-time scheduling** is best-effort: the audio threads request
  SCHED_FIFO and silently fall back if the rtprio rlimit forbids it
  (`ulimit -r`; configure `/etc/security/limits.d/` for production use).
  Xrun counts are printed at stop.
- **Per-platform strict baseline.** Apple and Glibc libm (and vvtanhf vs the
  scalar tanh shim) differ at rounding level, so Linux pins its own
  `--baseline-strict` file, `macOS/verifier_baselines/default-linux-x86_64.json`
  (`default.json` stays macOS-only). The physical `--verify` thresholds are
  identical on both platforms. A deliberate chain change that recaptured the
  macOS baselines must recapture this one on x86_64 Linux too, or the CI
  linux job goes red on stored-baseline drift: either run
  `MPXPrime --verify --capture-baseline` on an x86_64 box (Rosetta cannot run
  the Linux toolchain; an arm64 Linux container writes `default-linux-arm64.json`
  instead), or trigger the manual GitHub workflow
  `gh workflow run linux-baseline.yml --ref <branch>` (or, on an integration
  branch that has not shipped to `main` yet, push a commit whose message
  contains `[linux-baseline]`) and download its `linux-x86_64-baseline`
  artifact into `macOS/verifier_baselines/`
  (`.github/workflows/linux-baseline.yml`: physical thresholds first, then
  capture, then a strict round-trip).
- **Loopback smoke test** without audio hardware: `sudo modprobe snd-aloop`,
  point `output_device_uid` at `hw:Loopback,0,0`, run the encoder with
  `source_mode = tone`, and capture the composite from the other end:
  `arecord -D hw:Loopback,1,0 -f FLOAT_LE -r 192000 -c 2 -d 8 capture.wav`.
  The pilot (19 kHz, 8 percent) and RDS sidebands (around a suppressed 57 kHz
  carrier) should be visible in any spectrum tool.

### Debian/Ubuntu package

`./build-deb.sh <version> [distro-label]` builds `mpxprime_<ver>_amd64.deb`
(`mpxprime_<ver>-<label>_amd64.deb` with the distro label, which the release
workflow always passes)
from a release build (`swift build --package-path macOS -c release
--product MPXPrime --static-swift-stdlib` first -- the Swift runtime is
linked statically; remaining system deps are computed by dpkg-shlibdeps).
The package installs `/usr/bin/mpxprime` (+ the web-dashboard resource
bundle), a `mpxprime.service` systemd unit (dedicated `mpxprime` system
user in the `audio` group, config at `/var/lib/mpxprime/MPXPrime.ini`;
`LimitRTPRIO` grants the audio threads real-time scheduling), the sample INI, and the docs. On a FRESH install
postinst seeds `/var/lib/mpxprime/MPXPrime.ini` from the sample INI with
`control_enabled = True`, `control_bind = 0.0.0.0` and a random 32-character
`control_api_key` from `/dev/urandom` (printed once; an existing INI is never
touched, so upgrades keep the operator's key and settings), and the unit runs
`mpxprime --nogui --web --config /var/lib/mpxprime/MPXPrime.ini` -- `--web`
forces the control server on while bind, port and key come from `[CONTROL]`
-- so the dashboard is reachable from another machine from `systemctl enable
--now mpxprime` onward. Release tags build and attach the Ubuntu 24.04 deb automatically
(`.github/workflows/release.yml`); the 26.04 leg was removed until Swift.org
ships a 26.04 toolchain -- the 24.04 deb uses a static Swift stdlib and
installs/runs on 26.04 in the meantime. Pushes to `develop/**` and PRs to
`main` run CI (`.github/workflows/ci.yml`): build + tests on both platforms,
`swiftlint --strict` and `--verify-receiver` on macOS, and the fast verify
gates (`--verify --seconds 5` and `--verify --baseline-strict` against each
platform's own baseline) on macOS and Ubuntu 24.04.

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
manual's "Remote control" section for endpoints and the security model. `scripts/run-build-web.sh`
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
swift run --package-path macOS MPXPrime --verify-multiband-coupling --seconds 2    # A/B inter-band coupling
swift run --package-path macOS MPXPrime --verify-advanced-dynamics --seconds 4     # A/B single-stage leveler
swift run --package-path macOS MPXPrime --verify-ssb-stereo --seconds 4            # A/B SSB stereo encoder
swift run --package-path macOS MPXPrime --verify-hf-transients --seconds 5         # hi-hat / cymbal distortion gate (per chain variant)
swift run --package-path macOS MPXPrime --verify-stereo-guard --seconds 4          # composite clipper stereo-guard share sweep (duty / separation / SINAD table)
swift run --package-path macOS MPXPrime --verify-final-ride --seconds 3            # Final-MPX limiter duty attribution (one clipper candidate off per row)
macOS/.build/release/MPXPrime --verify-program-ab <file-or-dir> --seconds 30        # real-music A/B: AGC+multiband vs Advanced Dynamics on captured audio (macOS only; --ab-profile, --ab-csv; corpus via scripts/capture-program.sh)
macOS/.build/release/MPXPrime --bench-blocks                                        # block (buffer) size sweep: worst-block cost, latency, bit-identity, device HAL range
scripts/capture-program.sh --seconds 60 --name <label>                             # record program audio from BlackHole 2ch into $MPXPRIME_MUSIC_DIR (the --verify-program-ab corpus)
scripts/ab-music-live.sh --cycles 4 --window 30 [--soak <hours>]                          # LIVE real-music A/B + soak on two BlackHole devices while you play music (xruns / safety clip / budget / deviation gates)
scripts/smoke-live.sh [--ini <path>]                                                      # LIVE engine smoke on a virtual output (BlackHole 2ch): device start, tone deviation vs expected, pilot, Safety Clip, xruns, live-apply + restart via REST
```

Baseline capture + strict compare:

```bash
swift run --package-path macOS MPXPrime --capture-baseline    # writes macOS/verifier_baselines/default.json
swift run --package-path macOS MPXPrime --verify --baseline-strict
```

Exit codes: `0` = PASS, `1` = TIGHT (near limits, review), `2` = WARN, `3` =
FAIL (post-injection composite overshoot; checked first so a TIGHT finding can
never mask it), `64` = usage error -- most often `macOS/Verification.ini` not
findable because the gate was not run from the repo root.

See the [Offline verification](manual.md#offline-verification) section of the
user manual for what each report field means.

## Tests

Tests use **Swift Testing** (`import Testing`, `@Test` / `#expect`) -- not
XCTest. Running them requires a full Xcode install, so `DEVELOPER_DIR` must point
at Xcode (the Command Line Tools ship no `Testing.framework`):

```bash
# Full default suite (~40 s)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path macOS

# Single suite / filter
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path macOS --filter BassClipperTests
```

Optional deep DSP combination suite (~3 min; opt-in, catches stage-interaction
regressions -- run before a release or when touching multiple stages):

```bash
MPXPRIME_DEEP=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path macOS --filter Deep
```

## Accessibility lint

UI changes should pass the accessibility lint before committing:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftlint
```

The project's `.swiftlint.yml` enables the two accessibility rules
(`accessibility_label_for_image`, `accessibility_trait_for_button`) plus a set
of opt-in bug-catcher rules (force unwrapping, `first(where:)`, unowned
captures, ...); the style rules that fight intentional DSP patterns are
disabled. CI runs it with `--strict`.

## Scripts layout

- Repo root: only the two release entry points the workflows call,
  `build-release.sh` (universal binary + DMG) and `build-deb.sh` (Debian
  package). Run them from the root.
- `scripts/`: developer and maintainer tools -- `run-build-web.sh`,
  `run-meter.sh`, `smoke-live.sh`, `ab-music-live.sh`, `calibrate-tx.sh`,
  `capture-program.sh` (+ `CaptureToWav.swift`), the docs checks
  (`check-doc-anchors.py`, `check-english.sh`, `lt-report-filter.py`,
  `extract-ui-strings.py`, `english-dictionary.txt`). Every shell script
  changes to the repo root itself, so `scripts/smoke-live.sh` works from any
  directory.
- `dist-scripts/`: the operator-facing helpers that SHIP with the app --
  `nowplaying.sh` and `push-nowplaying.sh` (Now Playing metadata for RDS).
  `build-release.sh` copies them into `MPX Prime Studio.app/Contents/Resources/Scripts/`
  and into the DMG's `Now Playing Scripts/` folder; the manual documents them
  from the operator's side. Put a script here only if an end user runs it.

## Documentation lint and proofreading

Every tracked Markdown file must pass `markdownlint` with the repo config
(`.markdownlint-cli2.jsonc`: all rules on except line length, sibling-only
duplicate headings, table padding), every intra-repo link and heading anchor
must resolve, and docs are ASCII-only (AGENTS.md); the CI `docs` job enforces
all three on every push. From the repo root:

```bash
npx --yes markdownlint-cli2            # lint all tracked .md (Node from Homebrew; nothing installed in the repo)
npx --yes markdownlint-cli2 --fix      # auto-fix blank-line / list-marker findings first
python3 scripts/check-doc-anchors.py   # relative links + #anchors (GitHub slug rules)
```

English is proofread with LanguageTool (`brew install languagetool`; Java):

```bash
scripts/check-english.sh docs/manual.md README.md   # Markdown prose (code, links and tables stripped first)
scripts/check-english.sh --ui                       # the apps' operator-facing strings (scripts/extract-ui-strings.py)
scripts/check-english.sh --all                      # everything
```

Spelling hits on project vocabulary are filtered through
`scripts/english-dictionary.txt`; add a word there only when it is a real
term, never to hide a typo. The two Claude Code skills in `.claude/skills/`
(`markdown-lint`, `proofread-english`) carry the rules and the fix workflow;
they are checked in so every contributor and agent gets the same checks.

## Release build and DMG

Build a universal release app bundle and DMG:

```bash
./build-release.sh 0.41
```

Artifacts are written to `macOS/dist/`.

Releases ship by merging the integration branch (`develop/v.NNN`) into `main`,
tagging `v<version>` from `main`, and pushing the tag -- which triggers
`.github/workflows/release.yml`, runs `./build-release.sh <version>`, and
publishes the resulting DMG as a GitHub Release.

## See also

- [ARCHITECTURE.md](ARCHITECTURE.md) -- detailed DSP chain and stage descriptions
- [`AGENTS.md`](../AGENTS.md) -- full contributor / agent workflow guidance,
  conventions, and the release validation checklist
- [`plan.md`](../plan.md) -- roadmap
