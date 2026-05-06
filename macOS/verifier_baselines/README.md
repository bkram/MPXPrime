# Verifier baselines

Stored per-scenario metrics that `--verify` compares against on every run. Catches the class of silent regression where the ASCII-table pass/warn/fail decision reads the same as before but underlying metrics drift substantially.

## How it works

- `default.json` is the committed baseline for the default `--verify` run (9 scenarios × 17 metrics). Produced by `swift run --package-path macOS MPXPrime --verify --capture-baseline`.
- Every subsequent `--verify` run compares measured metrics against the stored baseline with per-metric tolerances defined in `macOS/Sources/MPXPrime/VerifierBaseline.swift`.
- Any metric that drifts beyond its tolerance is reported as `Baseline drift: <scenario>: <metric> measured X, baseline Y (delta, tolerance ±T)` in the verifier output.
- Drift elevates the result to at least `TIGHT` (exit code 1). Pass `--baseline-strict` to escalate to `WARN` (exit code 2) — useful for CI gates.

## When to recapture

Recapture the baseline **only** when you've intentionally changed the DSP chain and validated the new measurements by ear, by listening tests, or by independent instrumentation. Recapturing silently to make CI green is how silent regressions get in.

```bash
# Capture a new baseline after an intentional chain change:
swift run --package-path macOS MPXPrime --verify --capture-baseline

# Commit the resulting default.json so the new numbers are the new reference.
git diff macOS/verifier_baselines/default.json
git add macOS/verifier_baselines/default.json
```

## Tolerances

Stored in `MetricTolerances.default` in `VerifierBaseline.swift`. Tightest gates: `peakDBFS` ±0.10 dB, `limiterGRDB` ±0.15 dB, `above60kRatioDB` ±1.0 dB (the RDS-guard-band check that would have caught the 2026-04 pre-emphasis-reorder regression).

The `limiterGRDB` field name is preserved for baseline backward compatibility but now reflects the **composite clipper** gain reduction (the prior `CompositeTruePeakLimiter` was removed in 0.11). Treat any drift in this metric as clipper-engagement drift.

## Determinism note

Measurements are stable within small floating-point / FFT jitter (~10⁻⁴ on correlations, ~0.01 dB on above-60k ratios). The tolerances are set well above this jitter floor, so the comparison is robust across runs. The captured file will differ slightly byte-for-byte between back-to-back `--capture-baseline` runs; this is expected and does not indicate drift.

## Scope

- `--verify` (default 8 scenarios): covered by `default.json` in this directory.
- `--verify-presets`: not covered by stored baselines yet; uses `presetQualityOverride()` in `VerificationHarness.swift`.
- `--verify-long`: not covered by stored baselines yet; uses hardcoded `longRunSignatureReferences()` in `VerificationHarness.swift`. Migration to JSON is a follow-up (same pattern as `default.json`).
