# Clipper aliasing measurements

The tests in this directory drive each clipper with a worst-case synthetic tone and measure the energy at aliased harmonic locations via FFT. They are written as regression gates: the aliasing threshold is set at the TARGET value and the test **fails on current code** because the clippers run at native sample rate without oversampling. The failure message prints the measured aliasing energy so progress can be tracked.

> **Status as of 0.11**: Phase 7.1 oversampling wrappers shipped for `BassClipper` (4x), `DistortionCancelledClipper` (8x), and `CompositeClipper` (8x), all sharing the `Lagrange4Interp` + `BiquadCascade6` (12th-order Butterworth) pattern with `vvtanhf`-batched soft-clip. The pre-Phase-7.1 numbers below are kept as a historical reference so post-refactor deltas in `--verify --baseline-strict` can be attributed to the oversampling change versus other regressions. Re-run the tests on current code to capture the post-refactor measurements; the pre-refactor table here is no longer the live-fail state.

## Current measurements (native-rate clippers, no oversampling)

| Clipper | Test signal | Measured alias energy | Test threshold |
|---|---|---|---|
| `DistortionCancelledClipper` | 5111 Hz @ 48 kHz, amp 0.95, ceiling -3 dB, cancelFreq 2 kHz; sum of 5 alias bins {22445, 17334, 12223, 7112, 2000} Hz | **-28.73 dBFS** | -75 dBFS |
| `BassClipper` | 113 Hz @ 48 kHz, amp 0.95, crossover 150 Hz, threshold -3 dB, drive 1.5; sum across alias bins in [1k, 16k] spaced 113 Hz apart, offset -25 Hz from the real harmonic ladder | **-56.50 dBFS** | -75 dBFS |

Both tests fail by clear margins, which is the documented pre-refactor state. When Phase 7.1 lands (oversampling wrappers around these nonlinearities), both should drop below the threshold.

## What Phase 7.1 needs to clear this bar

A prior 7.1 attempt with a 4–8× Lagrange-upsample + 12th-order Butterworth decimation LP delivered:

- `BassClipper`: < -75 dBFS (threshold met comfortably)
- `DistortionCancelledClipper`: **-39.05 dBFS** — improvement of 10 dB, but 37 dB short of target

The DC clipper's 5th harmonic of 5111 Hz lands at 25555 Hz — only 7% above native Nyquist. Butterworth decimation is not sharp enough to reject it without compromising the audio passband. A linear-phase FIR brick-wall with >80 dB stopband (Phase 7.5 in plan.md) is the architecturally correct decimation filter to pair with the oversampling wrapper. When both lands together, the DC clipper should clear -75 dBFS.

The prior 7.1 attempt also exposed a separate chain-level regression (unrelated to aliasing) via `--verify` that was traced to subtle interactions between the oversampled wrappers and the surrounding generator state even when clippers were disabled. That regression needs deeper investigation before 7.1 is re-attempted — the test infrastructure in this directory is the measurement scaffolding that will tell a future refactor whether it's actually working.

## Repeatability

Measurements are bit-identical across consecutive runs of `swift test`.

## How to reproduce

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path macOS --filter "aliasing"
```
