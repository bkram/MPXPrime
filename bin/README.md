# bin/

**You normally need nothing here.** RTL-SDR support is built from the vendored
`tuner/` source:

- The packaged **MPX Prime Meter.app** bundles its own stripped helper
  (`mpx-tuner`) with its dylibs, so the GUI needs no binary here and no
  Homebrew.
- The headless **`run-meter-sdr.sh`** builds `tuner/build/mpx-tuner` on demand
  (needs `cmake` + `brew install librtlsdr liquid-dsp`).

See `tuner/README.md`.

## Optional: `fm-sdr-tuner` (legacy fallback)

`run-meter-sdr.sh` resolves a tuner in this order: `FM_SDR_TUNER` env, the
vendored `tuner/build/mpx-tuner`, `bin/fm-sdr-tuner`, then a sibling
`~/Projects/git/FM-SDR-Tuner/build/`. So you only need to put something here if
you specifically want the **full upstream** [FM-SDR-Tuner](https://github.com/bkram/FM-SDR-Tuner)
instead of the vendored subset. It is not committed (see `.gitignore`):

```bash
git clone https://github.com/bkram/FM-SDR-Tuner.git
cd FM-SDR-Tuner
cmake -S . -B build && cmake --build build -j
cp build/fm-sdr-tuner /path/to/MPXPrime/bin/
```

Requires an RTL-SDR dongle. The vendored `mpx-tuner` is preferred and is what
the app ships.
