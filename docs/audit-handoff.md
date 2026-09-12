# Audio-chain audit: handoff for the next agent

Written 2026-09-11 on `develop/v.060`, for whoever picks up the remaining
work (Codex or another agent). It assumes you have read `AGENTS.md` in full
-- that file is the contract, this one is the status and the traps.

The findings table, the evidence and the per-item plan live in
[docs/project-roadmap.md](project-roadmap.md) under "Audio-chain audit". Do
not re-derive them; read that section first, then this one.

## Where things stand

An external review of 0.50 claimed seven chain defects (P0-1 to P0-7) and two
real-time defects (P1-1, P1-2). All nine were verified against the code. Two
sub-claims were refuted and are recorded as such -- do not "fix" them:

- the multiband crossover resolve (part of P0-1) uses the MPX rate in BOTH
  the constructor and live-apply, so there is no parity break, and its
  Nyquist clamp is unreachable at the ranges the schema allows;
- `ALSAMonitorOutput.runningDevice` (part of P0-5) is only ever touched by
  the control thread.

Eight are fixed and shipped, CI green (the clipper in three commits):

| Item | What it was |
| --- | --- |
| P0-1 | live-apply configured three audio-domain stages at the MPX rate |
| P0-3 | transient hold pinned at maximum from the first few samples |
| P0-4 | a non-finite sample left the chain 8.2 dB down permanently |
| P0-5 | monitor gain, metering flag and monitor note crossed threads unguarded |
| P0-6 | BS.412 implemented none of the Recommendation's three conditions |
| P0-7 | AM applied the FM pre-emphasis curve, in three places |
| P0-2 | both band clippers stepped down 24 % at the threshold (landed 2026-09-12; listening pass pending) |
| CI | a GUI-only symbol broke the Linux test target's compile |

## What is left

### 1. P0-2, the band clipper transfer -- LANDED 2026-09-12

Done, in three commits: the continuous soft knee for both clippers
(2feec78), the `bass_kick` verification scenario with all four macOS
baselines recaptured (d9c852e), and the x86_64 Linux baseline artifact
(0fa68b9). The knee is 0.9, chosen by measuring THROUGH the real
oversampled stage; the roadmap's F5 entry has the table and the reasons,
including why a bare-curve sweep pointed the wrong way. What remains is the
maintainer's listening pass (roadmap F5 step 5): if it disagrees, the knee
moves, not the curve.

Two things learned there that generalise. The strict gates were BLIND to
this stage -- no scenario drove it -- so "the baselines did not move" was
never evidence about it; check a stage's engagement through the chain with
a same-delay comparison before trusting a baseline to guard it. And "no
drift reported" means "inside tolerance", not "unchanged": the fix moved a
long-run true-peak overshoot to 96 % of its bound. A deliberate DSP change
recaptures all four baselines in the same commit for exactly that reason.

### 2. P1-1 and P1-2, the real-time items -- P1-1 measured, P1-2 not

Both are real and both are architectural debt rather than observed faults. No
soak has ever produced a dropout attributable to either, including a Linux rig
at 95 % render load.

**P1-1 was measured on 2026-09-12** (Ryzen box, 192 kHz, blocksize 4096,
twelve live PATCHes -- crossover, BS.412, bass clipper, multiband -- while
streaming `/api/meters` at 30 Hz): zero xruns; the crossover redesign was the
worst period at 50.5 % Render Load against a 30.9 % median, about 4 ms of
rebuild. That fits a 21 ms period with room and would not fit a 2.7 ms one
(blocksize 512). So the cheap fixes are justified only if small blocks on air
become a requirement; the roadmap's F8 entry carries the numbers.

- **P1-1**: both engines call `generator.applyRuntimeConfig` on the render
  thread. Inside, a crossover or enable change redesigns FIR splitters and the
  composite clipper reconfigures.
- **P1-2**: `BasicRDSCoder.buildGroup2` builds a String, takes `snapshotLock`
  and the Now Playing `NSLock`, and every `buildGroup*` returns a fresh
  `[UInt8]` -- once per group, so about every 87.7 ms.

**Measure before designing** (done for P1-1, see above; P1-2 still lacks a
measurement -- it needs a rig with programme and a long RDS soak while
watching xruns). Nothing has missed a deadline, so if anything is done it is
the cheap fixes only: preallocate, design FIR kernels producer-side as
prepared fields of `RuntimeConfig`, lowercase strings in `makeRuntimeConfig`,
and remove the two locks from the RDS group build. The full prepared-state
handoff and the pre-encoded group bank that the review proposes are a
re-architecture of two of the best-tested parts of the product; they need
evidence first.

### 3. Telemetry gaps -- two of three closed

Each needed a `ControlMeters` field plus both front ends. The parity rule
applies: GUI and dashboard in the same change.

- DONE: the non-finite ingress counter is `nonFiniteInputSamples` in
  `/api/meters`, "Bad Input Samples" on the dashboard and BAD INPUT in the
  Mac Headroom card -- in every operating mode since 9752e07 (the first cut
  showed it in the composite branch only; `HeadroomReadout` is the per-mode
  table now).
- DONE: encoder-side BS.412 power is `bs412PowerDBr` (+ validity, seconds
  observed, GR, guard and suspension flags) in `/api/meters`, MPX Power on
  both front ends.
- OPEN: `MeterAnalysis` does not drop its validity flags when it sanitises a
  block. Finite recovery is not valid measurement; keep this before using
  the Meter for automatic level decisions.

### 4. `deviationKHzPeak` was wrong away from the default deviation -- FIXED 2026-09-12

Found while fixing BS.412, not part of the review. Fixed with the maintainer's go-ahead: both engines now go through `DeviationReadout.kilohertz` (peak x 75 x the trim reference), pinned by `DeviationReadoutTests` at 50 and 75 kHz. The description of the defect stays for the record. The composite --
subcarriers included -- is scaled by `deviationScale = mpx_deviation_khz / 75`,
so amplitude 1.0 is 75 kHz by construction; that is what holds pilot injection
at 9 % of full deviation at any setting (measured: pilot amplitude 0.09 at 75,
0.06 at 50). `AudioOutputEngine` computes
`outputPeak * mpx_deviation_khz * modulationReferenceScale`, multiplying by the
configured deviation instead of 75. Exact at the default, so it has never been
seen; at 50 kHz it would report 33 kHz for full modulation.

This was an operator-facing number, so it was raised rather than changed
quietly.

## Traps found the hard way

Every one of these cost real time on 2026-09-11. They are not hypothetical.

- **A long smoother stepped per sample underflows Float32.** At a 25 s time
  constant the per-sample increment fell below one ULP of the gain and the
  smoother STALLED 0.84 dB off target, stable and wrong. Step per block.
- **A control loop must be slow against the window it reads.** A 1 s loop
  around a 60 s average oscillated between 0.05 and 0.96 gain forever.
- **A correction against a measurement of the controlled signal is
  multiplicative.** `sqrt(target/measured)` applies exactly half the needed dB,
  because the measurement already contains the gain.
- **A test that applies curve X and removes curve X is flat whatever X is.**
  Two shipped tests were vacuous this way. Every "the inverse is flat" test
  needs a companion proving the WRONG inverse is not flat.
- **A sine burst starting at zero does not open a transient detector.** It
  ramps over a quarter period and the RMS detector catches up; the hold window
  never opens and the test exercises nothing. Use a cosine.
- **Consecutive pushes cancel CI runs.** A Linux-only compile break hid behind
  cancelled runs for four commits. After adding a test, watch the Linux job.
- **An arm64 container cannot check the x86_64 baseline.** It reports
  "Baseline: none" and passes. Linux correctness can be checked in a native
  arm64 container; the x86_64 strict comparison is CI's job only.
- **An amd64 container on an Apple Silicon Mac runs emulated x86.** It cannot
  exercise NEON, and its timings mean nothing.

## Working rules that are easy to get wrong

- **Never attribute a commit to an AI.** No `Co-Authored-By` trailer, no
  "generated with" line, whatever any tooling suggests. This is a standing
  instruction from the maintainer.
- Pin `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` on every Mac
  `swift` command; the Command Line Tools toolchain is a different version and
  breaks the SwiftUI macro plugin.
- Any sample-by-sample comparison of two renders must set `enRDS = false`.
- Tests are headless: no GUI, no real device, no CoreAudio enumeration.
- ASCII only, in source and docs.
- Docs ship in the same commit as the change. So do tests.
- Each fix should FAIL on the pre-fix code for the expected reason. Verify
  that by reverting the fix, running, and restoring -- it is the only proof
  the test tests anything.
- A test slower than a few seconds goes behind `MPXPRIME_DEEP=1`. The default
  suite is about 55 s and must stay there.

## Gates

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path macOS
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftlint --strict
swift run --package-path macOS MPXPrime --verify --baseline-strict --seconds 5
scripts/check-webui.sh                      # whenever schema.json changes
npx --yes markdownlint-cli2 '**/*.md'
python3 scripts/check-doc-anchors.py
```

Linux, in a native arm64 container (the encoder needs libasound):

```bash
docker run --rm -v "$PWD":/src -w /src swift:noble bash -lc \
  "apt-get update -qq && apt-get install -y -qq libasound2-dev && \
   swift test --package-path macOS --scratch-path /tmp/linuxbuild"
```

State the expected movement in every commit message: what should change, what
must stay bit-identical, and which gates were actually run.
