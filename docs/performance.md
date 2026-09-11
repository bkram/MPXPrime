# Performance

What the encoder costs on the machines it has been measured on, so a box can
be chosen (or ruled out) before it is wired to a transmitter. Every figure
here comes from the same release build of 0.50 and the same two probes; when
a number is missing, it has not been measured -- nothing is extrapolated.

## How the numbers are taken

- **Offline chain cost** -- `MPXPrime --bench` on a release build, from the
  repo root, on an otherwise idle machine. It renders the full chain at
  192 kHz with every feature on (5-band FIR multiband, 16x composite clipper,
  pilot + RDS) and reports wall-clock seconds per second of audio: 25 % means
  the render thread needs a quarter of one core. The per-stage rows switch one
  stage off at a time; deltas are first-order and do not add up exactly.
- **Live render load** -- the Linux engine's `renderLoadPercent`
  (`/api/meters`, dashboard "Render Load"): the worst share of one buffer
  period the real-time thread needed, with live programme through the card.
  It runs 10-20 points above the offline figure because it includes the
  ALSA I/O, the meters and a real period's scheduling jitter. The macOS engine
  does not publish it; there the offline figure and `--bench-blocks` are what
  you have.
- Loads above ~90 % drop buffers with live programme; an appliance should sit
  around 50-60 %. The operator guide's "CPU budget: what to turn off first"
  section turns these numbers into a recipe.

## Machines

| Machine | CPU | Cores | OS | DSP backend |
| --- | --- | --- | --- | --- |
| MacBook Pro 2021 | Apple M1 Pro | 8 P + 2 E | macOS 26.6 (arm64) | Accelerate |
| MacBook Pro 2019 | Intel Core i7-9750H, 2.6-4.5 GHz | 6 | macOS 26.6 (x86_64) | Accelerate |
| Ryzen box | AMD Ryzen 5 PRO 2400GE, 3.2-3.8 GHz | 4 (8 threads) | Ubuntu 26.04 (x86_64) | C kernels, AVX2 variant |
| Ryzen box (SSE2 build) | same | same | same | C kernels, SSE2 variant (what a CPU without AVX2 runs; same results, bit for bit) |

The encoder is single-thread-bound: one core carries the whole chain, the
other cores carry the control server, the meters and the monitor. Core count
past two buys nothing; per-core speed buys everything.

## Full chain, offline (`--bench`, 192 kHz, everything on)

| Machine | Chain cost | Composite clipper (16x) | Multiband (5-band FIR) | Pre-encode limiter | DC clipper | Bass clipper | RDS encoder |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| M1 Pro | **17.2 %** | 4.4 % | 4.3 % | 1.3 % | 1.3 % | 1.3 % | 0.6 % |
| i7-9750H | **22.4 %** | 4.6 % | 5.1 % | 1.1 % | 1.3 % | 0.7 % | 1.2 % |
| Ryzen 2400GE, AVX2 | **26.3 %** | 5.8 % | 6.0 % | -- | 1.7 % | 1.2 % | -- |
| Ryzen 2400GE, SSE2 | **36.6 %** | 12.7 % | 6.5 % | -- | 3.2 % | 1.7 % | -- |

The AVX2 kernels take 10 points off the Ryzen's chain, the composite clipper
alone halving from 12.7 % to 5.8 % -- and they compute bit-identical results
to the SSE2 variant, so the Linux strict baseline is one file for every CPU.

## Composite clipper oversampling (`--bench`, whole chain)

| Machine | 8x | 16x (default) | 32x |
| --- | ---: | ---: | ---: |
| M1 Pro | 15.2 % | 17.2 % | 21.2 % |
| i7-9750H | 20.1 % | 21.9 % | 25.4 % |
| Ryzen 2400GE, AVX2 | 24.3 % | 26.4 % | 30.5 % |
| Ryzen 2400GE, SSE2 | 31.4 % | 36.5 % | 46.2 % |

## Block size (`--bench-blocks`: worst single block as a share of its duration)

| Machine | 512 frames (2.7 ms) | 4096 frames (21 ms) |
| --- | ---: | ---: |
| M1 Pro | 20.7 % | 18.1 % |
| i7-9750H | 36.1 % | 25.8 % |
| Ryzen 2400GE, AVX2 | 33.4 % | 27.4 % |
| Ryzen 2400GE, SSE2 | 42.5 % | 37.7 % |

The DSP is block-invariant (every size renders bit-identical output); a
larger block only smooths the worst case. With a chain near its limit, 4096
was the difference between occasional dropouts and none with the Monitor on.

## Live render load (Linux, `renderLoadPercent`, live programme)

| Machine | Music - Loud, everything on | + SSB Stereo | Multiband off | Advanced Dynamics instead of AGC + multiband | Clipper 32x | Clipper 8x |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Ryzen 2400GE, AVX2 | **29 %** (the Mac's own configuration incl. SSB) | -- | -- | -- | -- | -- |
| Ryzen 2400GE, SSE2 | 43 % | 45 % | 37 % | 42 % | 54 % | 38 % |

Every row ran with zero dropouts. The chain that fits comfortably here is the
same chain that overran a low-end x86 core without AVX2 -- the point of the
per-CPU kernels and of measuring before choosing a box.

## What this means when choosing a box

- **Apple Silicon or a current Intel/AMD core**: everything on, every
  experimental stage included, at 17-30 %. Nothing to decide.
- **A small x86 box for a Linux appliance**: needs AVX2 and a modern core --
  an Intel N100-class part is the floor, an N305 or a Core i3 comfortable.
  The Ryzen 5 PRO 2400GE above is the smallest machine measured that runs
  everything with margin.
- **Older low-power x86 parts without AVX2**: run only with the chain trimmed
  (no SSB, the clipper at 8x or the multiband on IIR crossovers, blocksize
  4096) and with no headroom left. Not a transmitter-site machine.

Re-measure rather than extrapolate: `--bench` takes about a minute, and the
dashboard's Render Load reads the truth with the real programme.
