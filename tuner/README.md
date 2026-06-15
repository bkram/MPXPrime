# mpx-tuner

A minimal RTL-SDR -> FM-demodulator -> MPX-composite helper used by **MPX
Prime Meter** to take live FM off-air for analysis. It tunes an RTL-SDR,
FM-demodulates, and writes the raw MPX composite (pilot + L-R + RDS) as a
16-bit / 192 kHz mono WAV stream to stdout (or a FIFO) -- the format the
Meter's `--stdin` / SDR input expects.

## Provenance

This is a **stripped, vendored subset of FM-SDR-Tuner**
(https://github.com/bkram/FM-SDR-Tuner), GPL-3.0, by the same author. The
upstream commit it was taken from is recorded in `UPSTREAM_COMMIT.txt`. Both
projects are GPL-3.0, so vendoring is license-clean.

Only the capture + demod + writer path is kept:

- `rtl_sdr_device.{h,cpp}` -- librtlsdr USB capture
- `fm_demod.{h,cpp}` -- FM discriminator (produces the MPX composite)
- `wav_writer.{h,cpp}` -- gain + int16 clamp + resample + WAV stream to a pipe
- `dsp/liquid_primitives.{h,cpp}`, `dsp/multipath_eq.{h,cpp}`, `dsp/iq_saturation.h`
- `mpx_tuner_main.cpp` -- a small CLI (new; not from upstream)

Everything else from upstream is intentionally dropped: the XDR server
(removing the openssl dependency), its own 48 kHz audio output (removing
CoreAudio/AudioToolbox), RDS decoding (the Meter decodes RDS itself),
calibration / band scan, the rtl_tcp source, and INI config. Remaining
external deps: **librtlsdr + liquid-dsp** only.

## Build

```bash
cmake -S tuner -B tuner/build -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"
cmake --build tuner/build
```

Requires `librtlsdr` and `liquid-dsp` (e.g. `brew install librtlsdr liquid-dsp`).
`build-release.sh` builds this universal and bundles it -- with its two dylibs --
inside `MPX Prime Meter.app`, so end users need neither Homebrew nor a
separately-placed `fm-sdr-tuner`.

## Usage

```bash
mpx-tuner -f 88600                 # 88.6 MHz -> MPX WAV stream on stdout
mpx-tuner -f 88600 -o /tmp/mpx.fifo --mpx-rate 192000
mpx-tuner -f 105900 -g 30          # manual 30 dB tuner gain (default: auto)
```
