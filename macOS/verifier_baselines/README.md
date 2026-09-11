# Verifier baselines

Stored measurements that the offline `--verify*` gates compare against on
every run. They catch the class of silent regression where the pass / warn /
fail table reads the same as before while the underlying composite metrics
drifted.

## Files

| File | Gate | Contents |
|---|---|---|
| `default.json` | `--verify` | 9 scenarios x 20 metrics (schema 3) plus a global encoder-side sideband fingerprint; macOS |
| `default-linux-x86_64.json` | `--verify` on Linux x86_64 | same schema, captured with the Linux SIMD-shim numerics (Glibc libm, SSE2 dotpr/conv/tanh); an arm64 Linux build would look for `default-linux-arm64.json` |
| `presets.json` | `--verify-presets` | 21 records keyed `<presetID>/<scenario>`, same schema 3 |
| `long.json` | `--verify-long` | 5 long-run scenarios at the documented 30 s duration, same schema 3 |
| `receiver.json` | `--verify-receiver` | 10 receiver-side metrics (separation at 1 / 10 / 14 kHz, pilot, RDS, guard-band depth, phase-lock drift; schema 1, `ReceiverMetricTolerances`) |

`presets.json`, `long.json` and `receiver.json` are platform-suffixed the same
way as `default.json` when captured on Linux (`presets-linux-x86_64.json`, and
so on); today only the default baseline exists for Linux, and the CI linux job
compares only that one.

The 20 per-scenario metrics: `peakDBFS`, `deviationKHz`, `limiterGRDB`,
`safetyGRDB`, `audioCompositePeakDBFS`, `postInjectionOvershoot`,
`overBudget`, `pilotPercent`, `rdsPercent`, `budgetMarginDB`,
`agcReductionDB`, `inputCorrelation`, `outputCorrelation`, `inputSideToMid`,
`outputSideToMid`, `rmsDeltaDB`, `occupied999Hz`, `above60kRatioDB`,
`above67kRatioDB`, `truePeakOvershootDB` (4x-oversampled inter-sample
overshoot). `limiterGRDB` keeps its historical name but reads the COMPOSITE
CLIPPER gain reduction (the `CompositeTruePeakLimiter` it once described was
removed in 0.11); `safetyGRDB` is the final look-ahead MPX limiter.

## How it works

- Every run of a gate loads its baseline (if the file exists) and compares
  each metric with a per-metric tolerance (`MetricTolerances.default` and
  `ReceiverMetricTolerances.default` in
  `macOS/Sources/MPXPrime/VerifierBaseline.swift`). A missing file prints
  `Baseline: none` and the gate runs on physical thresholds only.
- Drift is reported as `Baseline drift (<n> findings):` followed by one line
  per metric (`<scenario>: <metric> measured X, baseline Y (delta, tolerance
  +/-T)`), and elevates the result to at least TIGHT (exit 1). With
  `--baseline-strict` drift escalates to WARN (exit 2) -- this is what CI
  runs. Exit 3 (FAIL) is reserved for a post-injection composite overshoot
  and is checked first, so a coinciding TIGHT finding can never mask it.
- Tightest gates: `peakDBFS` +/-0.10 dB, `limiterGRDB` and `safetyGRDB`
  +/-0.15 dB, `above60kRatioDB` / `above67kRatioDB` +/-1.0 dB (the RDS
  guard-band check that would have caught the 2026-04 pre-emphasis-reorder
  regression), `outputSideToMid` +/-0.02.

## When to recapture

Recapture ONLY after a DELIBERATE DSP change whose new measurements you have
validated (by the other gates, by independent instrumentation, or by
listening on a release build). Recapturing to make CI green is how silent
regressions get in. A change that moves composite output recaptures ALL
baselines in the same commit -- the four macOS files and the Linux one:

```bash
# From the repo root, on an otherwise idle machine (the gates are single-thread
# CPU-bound and a running GUI starves them):
swift run --package-path macOS MPXPrime --verify --capture-baseline
swift run --package-path macOS MPXPrime --verify-presets --capture-baseline --seconds 5
swift run --package-path macOS MPXPrime --verify-long --capture-baseline --seconds 30
swift run --package-path macOS MPXPrime --verify-receiver --capture-baseline --seconds 5

# Then prove the fresh files round-trip:
swift run --package-path macOS MPXPrime --verify --baseline-strict
git add macOS/verifier_baselines/*.json
```

The Linux x86_64 file can only be written on x86_64 Linux (Rosetta cannot run
the Linux toolchain; an arm64 container writes `default-linux-arm64.json`).
Either run `MPXPrime --verify --capture-baseline` on an x86_64 box, or use the
manual GitHub workflow `.github/workflows/linux-baseline.yml`
(`gh workflow run linux-baseline.yml --ref <branch>`, or on a not-yet-shipped
integration branch push a commit whose message contains `[linux-baseline]`),
then download its `linux-x86_64-baseline` artifact into this directory. The
workflow runs the physical thresholds first (they must pass -- a recapture must
never launder a broken chain), captures, and round-trips under
`--baseline-strict`. The 2026-09-04 Linux recapture matched the macOS file at
rounding level (every dB metric within 0.005 dB), which is the expected
relationship: the two platforms differ only in libm and SIMD summation order.

## Determinism note

Measurements are stable within small floating-point / FFT jitter (about 1e-4
on correlations, about 0.01 dB on the above-60k ratios); the tolerances sit
well above that floor. Back-to-back captures differ slightly byte for byte
(timestamps, last digits) -- that is not drift. Two things DO break run-to-run
identity and are excluded from the baselines by construction: the RDS text
scheduler paces PS / RT by wall clock (the scenarios render with the same
group sequence but any sample-wise comparison of two renders must run with
RDS off), and timing-dependent tests are not baseline material.

## Scope of the other gates

`--verify-multiband-coupling`, `--verify-ssb-stereo`,
`--verify-advanced-dynamics`, `--verify-hf-transients`,
`--verify-stereo-guard`, `--verify-final-ride` and `--verify-program-ab` are
A/B or attribution gates with their own thresholds; none of them reads or
writes a file in this directory, and the committed baselines always describe
the toggle-off production chain.
