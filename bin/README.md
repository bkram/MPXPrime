# bin/

**You normally need nothing here.** RTL-SDR support is built from the vendored
`tuner/` source:

- The packaged **MPX Prime Meter.app** links the tuner in-process (the
  `CMPXTuner` library) and bundles the librtlsdr / liquid-dsp dylibs, so the GUI
  needs no binary here and no Homebrew. (This is why the Meter is
  Apple-Silicon-only.)
- The headless **`run-meter-sdr.sh`** builds the standalone `tuner/build/mpx-tuner`
  CLI on demand (needs `cmake` + `brew install librtlsdr liquid-dsp`) and pipes
  its WAV stream into the Meter's `--stdin`.

See `tuner/README.md`.


Requires an RTL-SDR dongle. An external `fm-sdr-tuner` placed here (or via
`$FM_SDR_TUNER`) is only used by the headless script's stdin path.
