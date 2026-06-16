# mpx-tuner / CMPXTuner

A minimal RTL-SDR -> FM-demodulator -> MPX-composite tuner used by **MPX
Prime Meter** to take live FM off-air for analysis. It tunes an RTL-SDR,
FM-demodulates, and produces the raw MPX composite (pilot + L-R + RDS) at
192 kHz.

Two consumers share these sources:

- **`CMPXTuner`** (the primary path) -- the same C++ compiled as a **library
  with a pure-C ABI** (`capi-include`... see `macOS/Sources/CMPXTuner/include/mpx_tuner_capi.h`)
  and **linked directly into MPX Prime Meter**. The Meter opens the device with
  `mpxtuner_open(...)` and receives float MPX blocks (1.0 == 150 kHz) on a
  callback from the library's capture thread -- no subprocess, no FIFO. Live
  controls are direct function calls (`mpxtuner_set_*`). This is why the Meter
  is Apple-Silicon-only.
- **`mpx-tuner`** (the standalone CMake executable) -- the same demod behind a
  small CLI that writes a 16-bit / 192 kHz mono WAV stream to stdout or a FIFO.
  Kept for CLI debugging; no longer shipped in the app. The Meter's `--stdin`
  path (e.g. `./run-meter.sh --stdin`) still consumes a WAV stream like this.

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
This CMake build produces the standalone `mpx-tuner` debug CLI only. The shipped
app links these sources via the `CMPXTuner` SPM target instead; `build-release.sh`
bundles the librtlsdr / liquid-dsp / libusb / fftw dylibs (relocated to `@rpath`)
inside `MPX Prime Meter.app`, so end users need neither Homebrew nor a
separately-placed binary.

## Usage

```bash
mpx-tuner -f 88600                 # 88.6 MHz -> MPX WAV stream on stdout
mpx-tuner -f 88600 -o /tmp/mpx.fifo --mpx-rate 192000
mpx-tuner -f 105900 -g 30          # manual 30 dB tuner gain (default: auto)
mpx-tuner -f 88600 --control /tmp/ctl.fifo   # live commands while streaming
```

## Live control (`--control <fifo>`)

With `--control`, the standalone `mpx-tuner` reads newline commands from a FIFO
and applies them between IQ blocks -- a retune or gain change never interrupts
the MPX stream (no device re-open). (In the app, `CMPXTuner` exposes the same
operations as direct `mpxtuner_set_*` calls instead.) Commands:

- `freq <kHz>` -- retune
- `gain <dB>` -- manual gain (also switches to manual mode)
- `gainmode auto|manual`
- `agc 0|1` -- RTL2832 digital AGC
- `ppm <n>` -- frequency correction
- `bandwidth <kHz>` -- IF channel bandwidth (0 = auto / widest = full MPX)
- `bias 0|1` -- RTL-SDR v3 5V bias tee
