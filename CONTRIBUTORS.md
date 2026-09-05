# Contributors and credits

MPX Prime (MPX Prime Studio and MPX Prime Meter) is free software under the
GPL-3.0; see [LICENSE](LICENSE). This file records who wrote what and which
outside work the project builds on.

## Authors

- **Mark de Bruijn** ([bkram](https://github.com/bkram)) -- author and
  maintainer. The DSP chain, the FM composite encoder, the RDS generator, both
  macOS apps, the Linux CLI port, the REST API and web dashboard, the
  verification harness and the documentation.

## Initial RDS port

- **Ryan Ginn** ([ryanginn](https://github.com/ryanginn)) -- the block-level
  RDS bit encoder in `BasicRDSCoder` was **initially ported** from the Python
  `RDSHelper` in [ryanginn/rds-master](https://github.com/ryanginn/rds-master).
  What came from there: the CRC generator polynomial (`0x5B9`), the offset
  words, and the four-block group assembly shared by groups 0 / 2 / 3A / 4A /
  10A / 11A / 15A -- the part of RDS that EN 50067 fixes and that every encoder
  must get bit-exact.

  Everything built around it is this project's own work: the 1187.5 bit/s
  biphase encoding and Gaussian shaping FIR, the pilot-locked 57 kHz subcarrier
  (derived from the pilot oscillator's recurrence, not a free-running
  oscillator), the real-time audio-thread pipeline (pre-allocated bit buffer,
  atomic clock-time cache, monotonic timing), the `RDSRuntimeConfig` live-apply
  path, AF Method B, RT+ ODA (AID `0x4BD7`), Group 4A clock-time with MJD and
  timezone, Group 10A PTYN, Group 15A Long PS, Group 1A ECC / LIC, the
  Stereotool-compatible text grammar, the receive-side `RDSStreamDecoder`, and
  the FM composite chain the encoder feeds.

## Vendored code

- **FM-SDR-Tuner** (<https://github.com/bkram/FM-SDR-Tuner>), GPL-3.0, by the
  same author -- `tuner/` is a stripped subset (capture, FM demodulation, MPX
  output) compiled as `CMPXTuner` and linked into MPX Prime Meter. The exact
  upstream commit is recorded in `tuner/UPSTREAM_COMMIT.txt`; both projects are
  GPL-3.0, so vendoring is license-clean.

## Libraries

Build-time and runtime dependencies, each under its own license:

- [swift-atomics](https://github.com/apple/swift-atomics) (Apache-2.0) --
  lock-free primitives on the audio path.
- [Hummingbird](https://github.com/hummingbird-project/hummingbird) 2.x
  (Apache-2.0) -- the embedded HTTP server behind the REST API and dashboard.
- [librtlsdr](https://github.com/librtlsdr/librtlsdr) (GPL-2.0-or-later) and
  [liquid-dsp](https://github.com/jgaeddert/liquid-dsp) (MIT) -- RTL-SDR
  capture and DSP primitives for the Meter's in-process tuner.
- The **SDRplay API** -- loaded at run time with `dlopen` when the SDK is
  present, never linked, so a build without it simply omits SDRplay support.

## Standards and prior art

The RDS implementation follows EN 50067 / IEC 62106 and UECP SPB 490; the FM
composite follows ITU-R BS.450 and 47 CFR 73.322. Several processing stages are
built on expired patents, each credited in the source next to the code that
implements it and listed in
[docs/project-roadmap.md](docs/project-roadmap.md#anti-rework-guardrails----do-not-re-plan--re-implement).
Product names used for comparison belong to their owners; see the Trademarks
note in the [README](README.md#trademarks).
