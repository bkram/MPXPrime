# bin/

External helper binaries used by the MPX Prime **helper scripts** (the headless
`run-meter-sdr.sh`). These are **not committed** (see `.gitignore`) — place the
binary here yourself.

> **You only need this for the headless `run-meter-sdr.sh` script.** The
> packaged **MPX Prime Meter.app** ships its own stripped, self-contained SDR
> helper (`mpx-tuner`, built from `tuner/` and bundled with its dylibs), so the
> GUI needs neither this binary nor Homebrew. See `tuner/README.md`.

## `fm-sdr-tuner`

The FM-SDR-Tuner — an RTL-SDR FM broadcast tuner that can emit the MPX
composite. `run-meter-sdr.sh` uses it to pipe a live station's MPX into the
MPX Prime Meter.

- Source / releases: https://github.com/bkram/FM-SDR-Tuner

Build it from source, then copy the binary here:

```bash
git clone https://github.com/bkram/FM-SDR-Tuner.git
cd FM-SDR-Tuner
cmake -S . -B build && cmake --build build -j
cp build/fm-sdr-tuner /path/to/MPXPrime/bin/
```

`run-meter-sdr.sh` looks for `bin/fm-sdr-tuner` first, then
`$HOME/Projects/git/FM-SDR-Tuner/build/fm-sdr-tuner`. Override with the
`FM_SDR_TUNER` environment variable to point at any other location.

Requires an RTL-SDR dongle and the MPX-streaming patches (streaming WAV to a
FIFO + MPX output headroom) — built into recent FM-SDR-Tuner.
