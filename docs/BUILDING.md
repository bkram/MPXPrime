# Building from source

This document covers building, running, testing, and packaging MPX Prime from
source. If you only want to run the app, download the release DMG instead -- see
the [Download](../README.md#download) section of the README.

## Requirements

- macOS 15 or later
- Swift 6 toolchain (Xcode 16+ or the matching Command Line Tools)
- For running the **test suite**: a full Xcode install (the Command Line Tools
  do not ship `Testing.framework`)

The package is a Swift Package Manager project rooted at the repository root (`Package.swift`). Its SwiftPM
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

The one-step way (works from any directory; sets `DEVELOPER_DIR`, the
Homebrew `PATH` and a shared module cache, see `scripts/build-env.sh`):

```bash
scripts/build.sh                        # release, Studio + Meter
scripts/build.sh debug                  # debug build
scripts/build.sh --product MPXPrime     # the encoder only (no SDR libs needed)
scripts/build.sh --clean                # wipe .build first
```

Or the plain SwiftPM commands it wraps, from the repository root:

```bash
swift build                # debug
swift build -c release     # release
```

> **Debug builds are not real-time capable.** `swift build` (no `-c release`)
> and `swift run` produce a debug binary without compiler optimizations. The
> audio render thread shares CPU with the main-thread UI loop, and on a debug
> build the meter / scope / spectrum work in `refreshMonitoringSnapshot` is slow
> enough to occasionally preempt the audio thread -- you will hear clicks, buffer
> underruns, or input-ring overflows. Debug builds are fine for development,
> unit testing, and `--verify` runs (which do not touch real audio devices), but
> **for actual on-air or monitor playback always use a release build**: either
> `swift build -c release` followed by running
> `.build/release/MPXPrime`, or use the DMG produced by `scripts/build-release.sh`.

### Fast rebuilds

On an M1 Pro an incremental `swift build --build-tests` after editing one
encoder file takes about 10 s, and very little of that is compiling the file
(`MPXGenerator.swift` compiles in 1.1 s in a debug build). About 2 s is SwiftPM
loading the package -- more on the first build in a new shell, when it
re-evaluates every dependency manifest, so build from a long-lived terminal --
and the rest is emitting module interfaces and building the encoder target a
second time for the tests. Build the tests only when you are about to run them;
`swift build` is enough while iterating on the app. A release build is bound by
one serial whole-module optimisation job of about 45 s.

Keep type-checking cheap:

- Give a stored property an explicit type when its initialiser is not a
  literal (`let telemetry: LiveTelemetry = LiveTelemetry()`); otherwise every
  file that uses the type re-checks the expression. That one line cost 4 s of
  CPU per build across 14 jobs.
- In SwiftUI, move long ternaries, `String(format:)` chains and `+`-joined
  help strings out of the view builder into small typed helpers or
  `static let` constants (the Meter's `metricsSection` went from 2.8 s to under
  0.1 s this way).

To find slow spots, build into a separate scratch path (the flags force a full
rebuild) and fix anything reported in our sources:

```bash
swift build --scratch-path /tmp/mpx-typecheck \
  -Xswiftc -Xfrontend -Xswiftc -warn-long-expression-type-checking=200 \
  -Xswiftc -Xfrontend -Xswiftc -warn-long-function-bodies=200
```

## Install and run the apps

`scripts/build-run.sh` builds MPX Prime Studio and MPX Prime Meter as release
apps for this Mac, signs them, installs them in `/Applications` and opens the
Studio. Run the apps from there: one fixed path and one stable signature keep
the Dock item, Launch Services and the Microphone permission pointing at the
same app.

```bash
scripts/make-signing-identity.sh       # once per Mac: the signing identity
scripts/build-run.sh                   # both apps, then open the Studio
scripts/build-run.sh --meter           # both apps, then open the Meter
scripts/build-run.sh --studio-only     # the Studio only (no Homebrew tuner libraries)
scripts/build-run.sh --no-open         # build and install, open nothing
scripts/build-run.sh -- --nogui        # arguments after -- go to the opened app
```

`scripts/make-signing-identity.sh` creates a self-signed "MPX Prime
Development" certificate in its own keychain, usable over SSH. With it the
signature stays the same across builds, so macOS asks for the Microphone
once; without it the apps are signed ad hoc and macOS asks again after every
build. Never re-create the certificate once apps are signed with it. A running
app is quit gracefully before it is replaced, never killed; a copy started
from `.build` by `scripts/run.sh` is left running, and the new app is not
opened. `scripts/build-release.sh` and `scripts/build-run.sh` assemble the
bundles with the same functions in `scripts/app-bundle.sh`.

## Run from the build

`scripts/run.sh` builds a release `MPXPrime` and runs it; every argument is
passed to the binary unchanged (`--debug` and `--no-build` are the only flags
the script itself consumes):

```bash
scripts/run.sh                                     # GUI
scripts/run.sh --nogui                             # headless
scripts/run.sh --nogui --seconds 10                # fixed runtime
scripts/run.sh --config "/path/to/MPX Prime Studio.ini"
scripts/run.sh --verify --seconds 5                # offline verification gate
scripts/run.sh --debug --verify --seconds 5        # the same on a debug build
scripts/run.sh --no-build --nogui                  # run the existing binary
```

The equivalent plain commands, from the repository root (debug build, see the
warning above):

```bash
swift run MPXPrime                       # GUI
swift run MPXPrime --nogui               # headless
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
[Meter Operator Guide](meter-operator-guide.md) for the full control surface.

## Linux (web dashboard encoder)

The encoder also builds and runs on Linux as a **web-operated** encoder: a
headless service whose interface is the web dashboard (supported since 0.50; tested on Ubuntu 24.04 and 26.04, x86_64; recommended
on CPUs with AVX2, see docs/performance.md). The GUI, the MPX Prime
Meter and the SDR tuner remain macOS-only (the Monitor output plays on a
second ALSA device); the DSP kernels carry an AVX2 clone next to the SSE2
baseline and pick per CPU at load (`mpxprime --version` shows which), so the
package built on one x86_64 box runs on any other; and the web dashboard / REST API is the only operator interface (the package enables
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
swift build -c release
swift test
.build/release/MPXPrime --verify --seconds 5
.build/release/MPXPrime --nogui --config /path/to/config.ini
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
  `--baseline-strict` file, `Tests/Verification/baselines/default-linux-x86_64.json`
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
  artifact into `Tests/Verification/baselines/`
  (`.github/workflows/linux-baseline.yml`: physical thresholds first, then
  capture, then a strict round-trip).
- **Loopback smoke test** without audio hardware: `sudo modprobe snd-aloop`,
  point `output_device_uid` at `hw:Loopback,0,0`, run the encoder with
  `source_mode = tone`, and capture the composite from the other end:
  `arecord -D hw:Loopback,1,0 -f FLOAT_LE -r 192000 -c 2 -d 8 capture.wav`.
  The pilot (19 kHz, 8 percent) and RDS sidebands (around a suppressed 57 kHz
  carrier) should be visible in any spectrum tool.

### Checking the Linux build from a Mac (Docker)

Without a Linux box, the official Swift images build and test the Linux
target in minutes; this is also how the Linux baseline
(`Tests/Verification/baselines/default-linux-x86_64.json`) is recaptured after a
DSP change moves it. From a checkout with no `.build/` inside it:

```bash
docker run --rm -v "$PWD:/src" -w /src swift:6.4-noble bash -c '
  apt-get update -qq >/dev/null && apt-get install -y -qq libasound2-dev >/dev/null
  swift build -c release --product MPXPrime
  swift test
  .build/release/MPXPrime --verify --seconds 5
  .build/release/MPXPrime --verify --baseline-strict
  .build/release/MPXPrime --verify --capture-baseline --seconds 5   # only to recapture the Linux baseline
'
```

`swift:6.2-noble` is the oldest image worth testing (the CI runner installs
`swiftly install latest`, 6.4 at the time of writing). The container's
`.build/` is owned by root; delete it with the container (`docker run --rm
... rm -rf .build`) rather than from the host.

### Debian/Ubuntu package

`scripts/build-deb.sh <version> [distro-label]` builds `mpxprime_<ver>_amd64.deb`
(`mpxprime_<ver>-<label>_amd64.deb` with the distro label, which the release
workflow always passes)
from a release build (`swift build -c release
--product MPXPrime --static-swift-stdlib` first -- the Swift runtime is
linked statically; remaining system deps are computed by dpkg-shlibdeps).
The package installs `/usr/bin/mpxprime` (+ the web-dashboard resource
bundle), a `mpxprime.service` systemd unit (dedicated `mpxprime` system
user in the `audio` group, config at `/var/lib/mpxprime/MPXPrime.ini`;
`LimitRTPRIO` grants the audio threads real-time scheduling), the sample INI, and the docs. On a FRESH install
postinst seeds `/var/lib/mpxprime/MPXPrime.ini` from the sample INI with
`control_enabled = True`, `control_bind = 0.0.0.0` and a random 32-character
`control_api_key` from `/dev/urandom` (printed once; an existing INI is never
touched, so upgrades keep the operator's key and settings, and postinst
restarts a service the upgrade stopped), and the unit runs
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
are untouched. The hot paths (`vDSP_dotpr`/`vDSP_conv`/`vvtanhf`) are C
SIMD kernels in `MPXPrimeNative/MPXPrimeSIMD.c`, built on Linux/x86_64 as an
SSE2 and an AVX2 variant behind a glibc ifunc that picks per CPU at load
(bit-identical numerics, no FMA; `mpxprime --version` prints the variant) --
this is what lets the full chain (FIR multiband crossovers + 16x composite
clipper) run in real time on modest x86 CPUs: ~26% of a core at 192 kHz on
an AVX2 Ryzen 5 PRO 2400GE, ~37% with the SSE2 variant (the scalar versions
would not fit a low-end core at all). The shim is pinned
against real Accelerate by a golden
fixture plus SIMD accuracy tests (`AccelerateShimTests`; regenerate the
fixture on macOS with `MPXPRIME_CAPTURE_GOLDEN=1`). The ALSA engine lives
in `Sources/MPXPrime/ALSAAudioEngine.swift`.

## Remote control server

`--control` (alias: `--web`) / `--control-port N` enable the REST API + web dashboard for a
headless run (or set `[CONTROL] control_enabled = True`). See the user
manual's "Remote control" section for endpoints and the security model. `scripts/run-build-web.sh`
(repo root, macOS + Linux) builds the release binary and runs it headless
with the dashboard in one step; it prints the dashboard URL and API key
first and refuses to start a second instance on a port that is in use.

## Offline verification

The verification harness renders deterministic test scenarios without opening
any audio devices, so it runs safely on a debug build:

```bash
swift run MPXPrime --verify --seconds 5                  # scenario sweep
swift run MPXPrime --verify-presets --seconds 5          # 5-band preset sweep
swift run MPXPrime --verify-long --seconds 30            # long-run regression
swift run MPXPrime --verify-receiver --seconds 5         # receiver-model decode
swift run MPXPrime --verify-multiband-coupling --seconds 2    # A/B inter-band coupling
swift run MPXPrime --verify-advanced-dynamics --seconds 4     # A/B single-stage leveler
swift run MPXPrime --verify-ssb-stereo --seconds 4            # A/B SSB stereo encoder
swift run MPXPrime --verify-hf-transients --seconds 5         # hi-hat / cymbal distortion gate (per chain variant)
swift run MPXPrime --verify-stereo-guard --seconds 4          # composite clipper stereo-guard share sweep (duty / separation / SINAD table)
swift run MPXPrime --verify-final-ride --seconds 3            # Final-MPX limiter duty attribution (one clipper candidate off per row)
.build/release/MPXPrime --verify-program-ab <file-or-dir> --seconds 30        # real-music A/B: AGC+multiband vs Advanced Dynamics on captured audio (macOS only; --ab-profile, --ab-csv; corpus via scripts/capture-program.sh)
.build/release/MPXPrime --bench-blocks                                        # block (buffer) size sweep: worst-block cost, latency, bit-identity, device HAL range
scripts/capture-program.sh --seconds 60 --name <label>                             # record program audio from BlackHole 2ch into $MPXPRIME_MUSIC_DIR (the --verify-program-ab corpus)
scripts/ab-music-live.sh --cycles 4 --window 30 [--soak <hours>]                          # LIVE real-music A/B + soak on two BlackHole devices while you play music (xruns / safety clip / budget / deviation gates)
scripts/smoke-live.sh [--ini <path>]                                                      # LIVE engine smoke on a virtual output (BlackHole 2ch): device start, tone deviation vs expected, pilot, Safety Clip, xruns, live-apply + restart via REST
```

Baseline capture + strict compare:

```bash
swift run MPXPrime --capture-baseline    # writes Tests/Verification/baselines/default.json
swift run MPXPrime --verify --baseline-strict
```

Exit codes: `0` = PASS, `1` = TIGHT (near limits, review), `2` = WARN, `3` =
FAIL (post-injection composite overshoot). The exit code is the strongest of all
findings, so a TIGHT can never mask a WARN or FAIL; a worst 4x true peak above
0 dBFS is TIGHT and above +0.25 dBFS WARN; `--baseline-strict` with a missing,
undecodable or other-schema baseline exits 2. `64` = usage error -- most often `Tests/Verification/Verification.ini` not
findable because the gate was not run from the repo root.

### What the report contains

One row per scenario, with the composite figures first and the decoded-audio
quality metrics after them:

- MPX peak in dBFS and estimated deviation in kHz
- composite clipper gain reduction, safety limiter gain reduction
- audio-composite peak before the pilot/RDS sum, and the budget margin
- pilot and RDS injection percentages, AGC reduction
- decoded-audio quality per scenario: input/output correlation, input/output
  side-to-mid ratio, RMS drift

The deterministic scenarios are `mono_1khz`, `stereo_diff_400hz`,
`program_mix`, `bright_dense`, `vocal_sibilant`, `hf_edge_12k`,
`transient_push`, `hard_panned_hf`, `wide_bass` and `bass_kick` (0.65: the one scenario that drives the Bass Clipper hard enough for the strict baseline to see it). `--verify-presets` runs
the same measurements across the shipped 5-band presets (`5B AC/Pop`,
`5B CHR/EDM`, `5B Rock`, `5B Talk`, `5B News`, `5B Urban`, `5B Dance`), and
each `--verify-*` A/B mode prints its own comparison table (the one-line
descriptions in the command block above say what each one compares).

## Tests

Tests use **Swift Testing** (`import Testing`, `@Test` / `#expect`) -- not
XCTest. Running them requires a full Xcode install, so `DEVELOPER_DIR` must point
at Xcode (the Command Line Tools ship no `Testing.framework`):

```bash
# Full default suite (~40 s); scripts/test.sh sets DEVELOPER_DIR for you
scripts/test.sh

# Single suite / filter
scripts/test.sh --filter BassClipperTests

# The plain command the script wraps
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Optional deep DSP combination suite (~3 min; opt-in, catches stage-interaction
regressions -- run before a release or when touching multiple stages):

```bash
MPXPRIME_DEEP=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter Deep
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

- Repo root: no scripts. Everything lives in `scripts/`, and every shell
  script there changes to the repo root itself, so `scripts/run.sh` works
  from any directory.
- `scripts/`, the everyday entry points: `build.sh` (swift build with the
  right environment), `run.sh` (release build + run the Studio),
  `test.sh` (swift test with `DEVELOPER_DIR` set), `run-meter.sh` (the
  Meter), `run-build-web.sh` (headless + dashboard). They all source
  `build-env.sh`, which is the one place the Xcode path, Homebrew `PATH`,
  module cache and job count are set.
- `scripts/`, the release entry points the workflows call:
  `build-release.sh <version>` (universal binary + DMG under `dist/`)
  and `build-deb.sh <version> [label]` (Debian package, written to the repo
  root).
- `scripts/`, maintainer tools: `smoke-live.sh`, `ab-music-live.sh`,
  `calibrate-tx.sh`, `capture-program.sh` (+ `CaptureToWav.swift`), the docs
  checks (`check-doc-anchors.py`, `check-english.sh`, `lt-report-filter.py`,
  `extract-ui-strings.py`, `english-dictionary.txt`) and the dashboard render
  check (`check-webui.sh` + `check-webui.cjs`).
- `scripts/dist/`: the operator-facing helpers that SHIP with the app --
  `nowplaying.sh` and `push-nowplaying.sh` (Now Playing metadata for RDS).
  `scripts/build-release.sh` copies them into `MPX Prime Studio.app/Contents/Resources/Scripts/`
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

English is proofread with LanguageTool (`brew install languagetool`; Java).
This one is a writing aid rather than a gate -- it is deliberately **not** part
of CI, because most of what it reports is style a human has to judge:

```bash
scripts/check-english.sh docs/studio-operator-guide.md README.md   # Markdown prose (code, links and tables stripped first)
scripts/check-english.sh --ui                       # the apps' operator-facing strings (scripts/extract-ui-strings.py)
scripts/check-english.sh --all                      # everything
```

Spelling hits on project vocabulary are filtered through
`scripts/english-dictionary.txt`; add a word there only when it is a real
term, never to hide a typo. The two Claude Code skills in `.claude/skills/`
(`markdown-lint`, `proofread-english`) carry the rules and the fix workflow;
they are checked in so every contributor and agent gets the same checks.

## Dependencies

### Pulling them in

Nothing to do by hand. The first `scripts/build.sh` (or `swift build`)
resolves the SwiftPM dependencies from `Package.resolved`, clones them
into `.build/checkouts/` and builds them; later builds reuse the
checkouts. To fetch without building, or to re-fetch after a pull that
changed the pins:

```bash
swift package resolve      # fetch exactly the pinned versions
swift package show-dependencies   # the resolved tree
```

Resolution needs network access to github.com the first time and after a pin
changes; after that a build is fully offline. When SwiftPM refuses to resolve
("dependency graph could not be resolved", a stale checkout after a force
push, a corrupt clone), wipe its state and start again:

```bash
swift package reset         # drops .build/checkouts and the pins cache
swift package resolve
```

`scripts/build.sh --clean` does the heavier version of this (it removes all
of `.build`, so the next build also recompiles everything).

The Meter's native libraries are not SwiftPM packages: install them once with
`brew install librtlsdr liquid-dsp` (Apple Silicon; see Requirements above).
Without them, build the encoder only with `scripts/build.sh --product
MPXPrime`.

### Adding a new package

1. Declare it in `Package.swift`: add
   `.package(url: ..., from: "<lowest version you tested>")` to the
   `dependencies:` array, and add
   `.product(name: "<Product>", package: "<package-name>")` to the
   `dependencies:` of every target that imports it. The package name is the
   repository name without `.git` (`hummingbird` for
   `hummingbird-project/hummingbird.git`).
2. Resolve: `swift package resolve`. SwiftPM picks the
   newest version the range allows and appends the pin (and any transitive
   pins) to `Package.resolved`.
3. Build and test both platforms. A package that imports Foundation-only
   APIs is fine; anything touching AppKit, Accelerate or CoreAudio must sit
   behind `#if os(macOS)` or in a macOS-only target, because the same
   manifest builds the Linux encoder (`buildingForLinux` in `Package.swift`
   shows how the platform split is done).
4. Commit `Package.swift` and `Package.resolved` together, with the version
   in the message, and add the package to the pinned list below.

### Updating

What is pinned, and where:

- **SwiftPM**: `Package.swift` declares `swift-atomics` and
  `hummingbird` with `from:` minimums; `Package.resolved` (tracked)
  pins the exact versions of those two and of everything Hummingbird pulls
  in (SwiftNIO, swift-log, swift-crypto, ...). Every build and every CI job
  uses the committed pins, so a bump is a deliberate commit, never a side
  effect of a build.
- **Toolchains**: macOS builds with the Xcode the machine has (the
  Requirements above state the floor); Linux installs `swiftly install
  latest` (`ci.yml`, `release.yml`, `linux-baseline.yml`), so the Linux
  compiler moves on its own and a toolchain regression shows up in CI first.
- **GitHub Actions**: `actions/checkout`, `actions/upload-artifact`,
  `actions/setup-node`, `softprops/action-gh-release` are pinned by major
  (`@vN`) in `.github/workflows/*.yml`.
- **Node**: only the dashboard render check, `scripts/check-webui.sh`,
  which installs `jsdom@<major>` into the gitignored `.webui-check/` cache
  on first run. There is no `package.json`.
- **Homebrew**: `swiftlint` (CI installs whatever brew ships and runs it
  `--strict`), `librtlsdr` and `liquid-dsp` for the Meter.

The procedure, when a bump is wanted (a security fix, a feature we need, or
a quarterly sweep). `. scripts/build-env.sh` puts the shell in the repo root
with `DEVELOPER_DIR` and the Homebrew `PATH` set, the same environment the
scripts use:

```bash
. scripts/build-env.sh

# 1. See what is behind: the pins vs each repo's newest tag.
swift package show-dependencies | head -30
git ls-remote --tags https://github.com/hummingbird-project/hummingbird | tail -5

# 2. Bump. `update` moves every pin to the newest version the `from:` ranges
#    allow and rewrites Package.resolved; name one package to bump only it.
#    To go PAST a `from:` floor (a new major), raise the floor in
#    Package.swift first, then update.
swift package update                 # everything
swift package update hummingbird     # one package
git diff Package.resolved                           # review what moved

# 3. Re-run the gates. A dependency bump is a code change.
scripts/build.sh
scripts/test.sh
.build/release/MPXPrime --verify --seconds 5
.build/release/MPXPrime --verify --baseline-strict
swiftlint --strict
scripts/check-webui.sh
scripts/build-release.sh <version>                       # the universal slice still links

# 4. Linux leg (Ubuntu 24.04 box or let CI do it on the push):
#    swift build ... --static-swift-stdlib, swift test, the two --verify gates.

# 5. Commit Package.resolved (and Package.swift if a `from:` floor moved)
#    with a message that names the packages and versions.
```

Rules of thumb:

- Read the release notes of a MINOR bump of Hummingbird before taking it: it
  raises its Swift floor inside a major (2.27 needs Swift 6.2), and when it
  does, raise the Requirements line above and the `from:` in `Package.swift`
  in the same commit, so a fresh clone cannot resolve below the tested set.
- A transitive major (for example swift-crypto 4 -> 5) only lands if
  Hummingbird's own ranges allow it; `git diff Package.resolved` shows it.
- Bump the Actions majors together, in every workflow, so the four files
  stay on one line; read the action's release note for runner or Node
  requirements first.
- Bump `jsdom` in `check-webui.sh`, delete `.webui-check/`, re-run the check.
- Never pin by commit hash to work around a bug; pin the last good release
  and record the reason in the CHANGELOG.

## Versioning

The version lives in exactly one place, `Sources/MPXPrimeCore/Version.swift`
(`MPXPrimeVersion.string`). Studio (`--version`, the About box, the REST
`/api/status`) and the Meter read it, so an unbundled binary reports the same
number as the DMG. For shell, `scripts/version.sh` prints it: the packagers
use it when called without a version argument, the dashboard render check
reads it, and the release workflow fails when the pushed tag disagrees with
it. To bump: change that one line, rename the integration branch to
`develop/v.NNN`, and note the change in the CHANGELOG. Nothing else carries
a copy.

## Release build and DMG

Build a universal release app bundle and DMG:

```bash
scripts/build-release.sh          # version from scripts/version.sh
scripts/build-release.sh 0.65-rc1 # or an explicit one
```

Artifacts are written to `dist/`. The script builds the arm64 products,
copies them aside, builds the x86_64 encoder, and only then runs `lipo`: with
the Swift Build backend (the default in Swift 6.4) every architecture lands in
the same `.build/out/Products/Release`, so the second build overwrites the
first. Each slice is checked with `lipo -info` before it is used. After
packaging, `.build/release` holds the x86_64 encoder; `scripts/build.sh`
restores the native one.

Releases ship by merging the integration branch (`develop/v.NNN`) into `main`,
tagging `v<version>` from `main`, and pushing the tag -- which triggers
`.github/workflows/release.yml`, runs `scripts/build-release.sh <version>`, and
publishes the resulting DMG as a GitHub Release.

## See also

- [studio-operator-guide.md](studio-operator-guide.md) -- MPX Prime Studio Operator Guide (install, setup, levels, RDS, troubleshooting)
- [studio-settings-reference.md](studio-settings-reference.md) -- MPX Prime Studio Settings and API Reference (every INI key, the REST API)
- [meter-operator-guide.md](meter-operator-guide.md) -- MPX Prime Meter Operator Guide
- [ARCHITECTURE.md](ARCHITECTURE.md) -- detailed DSP chain and stage descriptions
- [`AGENTS.md`](../AGENTS.md) -- full contributor / agent workflow guidance,
  conventions, and the release validation checklist
- [`project-roadmap.md`](project-roadmap.md) -- project roadmap and open work
