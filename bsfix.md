# BS.412 compliance fix handoff

Written 2026-09-11 for the next implementation agent. Read `AGENTS.md` and
the "Audio-chain audit" section of `docs/project-roadmap.md` before changing
code. This document narrows the remaining problem in the completed P0-6 work
and gives a test-first implementation plan.

## Bottom line

The new `BS412MultiplexPowerMeter` measures the right quantity:

- the complete multiplex, including pilot and RDS;
- in dBr relative to a sine causing +/-19 kHz peak deviation;
- over a uniform rolling 60-second window.

Do not replace or weaken that measurement.

The remaining defect is the actuator and its state reporting. The current
`BS412GainController` eventually converges, but it does not keep every
60-second interval at or below the selected ceiling. It starts at unity and
uses a 25-second attack around a lagging 60-second measurement. A steady
+6.02 dBr input is still about +2.35 dBr in the first completed 60-second
window. The controller later crosses below the ceiling and rebounds across
it while settling. The existing full-chain test misses this because it checks
only the final 60 seconds of a 200-second render and allows 0.3 dB tolerance.

There is a second correctness gap: both BS.412 measurement and control stop
while Test Tone is active. A transmitted calibration tone is still part of
the complete multiplex. It may bypass gain control to preserve its calibration
meaning, but it must not disappear from the measurement, and the application
must not claim compliance while control is suspended.

The fix must make three concepts separate and explicit:

1. Measurement: what was actually emitted over the rolling 60-second window.
2. Transparent control: the slow audio gain ride used during normal operation.
3. Compliance guard: a last-resort energy-budget constraint that prevents a
   completed rolling window from exceeding the ceiling.

The pilot and RDS amplitudes remain fixed. Only the reducible audio composite
may be attenuated.

## Standards contract

ITU-R BS.412-9 section 2.5.1 says that the power of the complete multiplex,
including pilot and additional signals, integrated over any 60-second
interval, must not exceed the power of a single sine producing +/-19 kHz peak
deviation.

In this engine, after removing the hardware output trim, amplitude 1.0 means
75 kHz deviation. Therefore:

```text
referenceMeanSquare = ((19 / 75) ^ 2) / 2
ceilingMeanSquare   = referenceMeanSquare * 10 ^ (ceilingDBr / 10)
```

The regulator controls power, so all threshold ratios use `10^(dB/10)`.
Audio gain is an amplitude gain, so solving an audio-only power budget uses a
square root.

The compliance calculation must use the final reducible audio component and
the delayed pilot/RDS component at the point immediately before they are
summed. Do not estimate subcarrier power by subtraction from total power. For
short windows the audio/subcarrier cross term is not guaranteed to be zero.

Normative source:

- [ITU-R BS.412-9, section 2.5.1](https://www.itu.int/dms_pubrec/itu-r/rec/bs/r-rec-bs.412-9-199812-i!!pdf-e.pdf)

For samples `a[i]` (reducible audio) and `s[i]` (pilot plus RDS), a constant
audio gain `g` produces exact block energy:

```text
A = sum(a[i] * a[i])
B = sum(a[i] * s[i])
S = sum(s[i] * s[i])

E(g) = A*g*g + 2*B*g + S
```

The cross term matters to an exact guard even though it approaches zero over
the full minute.

## Why coefficient tuning alone is not a fix

Do not merely change the 25-second attack constant.

- A faster feedback loop still reads a delayed window and can oscillate.
- A negative ceiling margin can reduce the size of an error but cannot prove
  that no transition exceeds the limit.
- Checking only the final settled window proves convergence, not compliance.
- A validity flag alone makes the UI honest but leaves an enabled limiter able
  to exceed its advertised ceiling.

Keep a slow rider for sound quality, but put a mathematically bounded guard
behind it.

## Recommended architecture

### 1. Keep the reporting meter independent

Retain `BS412MultiplexPowerMeter` as the reporting oracle. It must process the
actual final multiplex continuously, whether the controller is enabled or
disabled and whether the source is program or Test Tone.

Move the call so it observes the sample that is actually returned to the
output path. Work in modulation-domain units by dividing out `output_gain_db`
exactly as the current code does. Continue publishing post-injection overshoot
separately; a final hard clamp must not silently turn broken pilot/RDS into an
apparently compliant reading.

The meter needs two readiness values:

```text
windowValid       // a complete 60 seconds has been observed
secondsObserved   // progress before windowValid
```

Before `windowValid`, the displayed power may be published as a provisional
value, but it must not be labelled compliant. Follow the Meter validity rules
already established in `AGENTS.md`.

### 2. Replace feedback-only limiting with a primary rider plus hard guard

The primary rider owns the audible behavior. It should normally keep the hard
guard idle.

Use a short prediction window over the pre-control reducible audio and the
actual delayed subcarriers to detect a sustained power increase quickly. A
reasonable starting point for measurement is one second, with a fast downward
gain move and the existing slow release. These are starting values, not
requirements; deterministic transition tests decide them.

Requirements for the primary rider:

- calculate its requested audio gain from pre-control energy, not from a
  window that already contains its changing gain;
- attack quickly enough that a steady hot signal does not spend most of the
  first minute above target;
- release slowly and monotonically;
- never request gain above unity;
- reserve a small internal margin below the operator ceiling for block
  granularity and floating-point error;
- perform no allocation, lock, clock call, or coefficient design on the audio
  thread.

Start by testing a 1-second predictor, approximately 100 ms attack, 50-second
release, and a 0.05 dB internal margin. Do not ship those constants merely
because they are written here. Sweep them against the transition tests and
report guard duty, gain modulation, and settling behavior.

### 3. Add an exact rolling-energy guard

The hard guard is not another smoother. It is an energy-accounting invariant.
It runs after all audio-only clipper, limiter, shaper, and budget-governor work,
but before pilot/RDS are summed. At this point call the reducible component
`audio` and the fixed component `subcarriers`.

Reuse the existing 64-sample accounting granularity unless measurement shows
that it is too expensive or too coarse. Preallocate all storage in
`configure(sampleRate:)`.

Maintain a ring of complete emitted block energies. At the start of a block:

```text
windowLimitEnergy = ceilingMeanSquare * windowSampleCount
pastEnergy = rollingEnergy - energyOfSlotBeingReplaced
allowedBlockEnergy = max(0, windowLimitEnergy - pastEnergy)
```

Treat unobserved reducible-audio history at engine start as zero-energy
samples. Pilot and RDS are not reducible, so a literal all-zero history is not
safe: early audio could consume the entire minute budget and make later
pilot-only samples impossible even with audio gain at zero. Reserve their
unavoidable future energy:

- initialize unobserved guard slots with a conservative subcarrier-only block
  energy, not literal zero;
- derive the reserve from configured pilot/RDS levels and a proved upper bound
  on shaped RDS block energy;
- when pilot or RDS configuration changes, update the reserve before accepting
  more audio energy;
- never assume future subcarrier energy is zero merely because RDS is between
  symbols or the current pilot sample crosses zero;
- add a test showing that an early hot audio burst cannot spend energy needed
  by the following 60 seconds of pilot/RDS.

The reporting meter still starts empty and becomes valid only after observing
real output. The synthetic reserve belongs to the guard only and must never be
shown as measured power.

Keep reporting validity separate, so the guard can protect the first complete
window without falsely claiming that a complete window has already been
measured.

For each sample, distribute the remaining block energy over the remaining
samples so one early sample cannot spend the entire block budget:

```text
sampleAllowance = remainingBlockEnergy / remainingSamples
limit = sqrt(max(0, sampleAllowance))
candidate = audio + subcarriers
```

If `abs(candidate) <= limit`, pass the audio unchanged. Otherwise find the
largest `h` in `[0, 1]` for which:

```text
abs(h * audio + subcarriers) <= limit
```

Solve this as an interval, not by iteration:

```text
r0 = (-limit - subcarriers) / audio
r1 = ( limit - subcarriers) / audio
feasible = [min(r0, r1), max(r0, r1)] intersect [0, 1]
h = upper bound of feasible
```

Special cases:

- If `audio == 0`, no audio gain can change the sample.
- If the feasible interval is empty, choose the value in `[0, 1]` nearest
  `-subcarriers/audio`, which minimizes absolute total output, and set
  `unachievable = true`.
- Sanitize every intermediate. A non-finite value must never enter either
  energy ring.
- Apply `h` to audio only. Never attenuate pilot or RDS to make the number
  look compliant.

Accumulate the energy of the exact emitted candidate after the guard. At block
completion, insert that energy into the rolling ring and update the total in
Double precision.

This guard proves the limit for every block-aligned rolling window. The block
is about 0.33 ms at 192 kHz. To cover windows beginning between block
boundaries, use a conservative internal ceiling margin derived from the
maximum one-block energy error. With final output bounded to unity, 0.01 dB is
already larger than the alignment error at normal MPX rates; calculate and
test the bound instead of hard-coding that assertion.

If review rejects sample-varying emergency gain, the alternative is a
preallocated 64-sample staging buffer and one constant gain per block, using
the exact quadratic `E(g)` above. That adds 64 samples of latency and requires
an explicit decision about live enable/disable delay. Do not silently put a
new fixed delay in the default, BS.412-disabled chain because that would move
all baselines.

### 4. Make Test Tone behavior honest

The Test Tone is a calibration source and its documented amplitude must not be
quietly changed by the BS.412 rider. Preserve that contract unless the
maintainer explicitly changes it.

While Test Tone is active:

- continue feeding every emitted sample into the BS.412 reporting meter;
- suspend the primary rider and hard guard if calibration amplitude must stay
  exact;
- publish `controlSuspended = true` and `complianceValid = false`;
- show an operator note such as `BS.412 control suspended by Test Tone` in both
  front ends;
- keep the accumulated Test Tone energy in the rolling window when program
  resumes.

The other valid policy is to refuse Test Tone while BS.412 compliance is
armed. That is a product decision. Do not leave the current silent third
policy, where the tone transmits but is omitted from the power history.

### 5. Publish state in both front ends

The operator cannot safely use this stage without knowing whether it is ready
or suspended. Add fields through `ControlMeters` and the GUI telemetry path in
the same change:

```text
bs412PowerDBr
bs412PowerValid
bs412SecondsObserved
bs412GainReductionDB
bs412OverCeiling
bs412Unachievable
bs412GuardActive
bs412ControlSuspended
```

Suggested UI behavior:

- show `--` for the compliance value until a full 60-second window exists;
- show progress such as `42 / 60 s` while priming;
- distinguish `measuring`, `controlling`, `guard active`, `suspended`, and
  `unachievable`;
- never show a green/compliant state while Test Tone suspends control;
- never hide pilot/RDS-only over-budget configurations behind audio gain.

Follow the repository parity rule: GUI and dashboard fields land together.
Update `schema.json`, `check-webui`, manuals, and API tests in the same commit.

## Source changes expected

The exact split is up to the implementation, but keep the concern out of
`MPXGenerator.swift` as much as possible.

- `macOS/Sources/MPXPrime/DSP/BS412Power.swift`
  - retain the standards meter;
  - replace or narrow `BS412GainController` into the primary rider;
  - add a separately testable rolling-energy guard;
  - expose a small value-type status snapshot.
- `macOS/Sources/MPXPrime/MPXGenerator.swift`
  - keep components separate until the guard point;
  - run reporting measurement for Test Tone too;
  - wire status into composite calibration/telemetry;
  - do not grow this file with the guard implementation.
- `macOS/Sources/MPXPrime/AudioOutputEngine.swift`
- `macOS/Sources/MPXPrime/ALSAAudioEngine.swift`
  - publish the same fields on both platforms.
- `macOS/Sources/MPXPrime/Control/ControlBackend.swift`
- `macOS/Sources/MPXPrime/Control/WebUI/schema.json`
- the matching GUI views and dashboard JavaScript
  - expose readiness, actual power, gain reduction, and faults.
- `macOS/Tests/MPXPrimeTests/BS412PowerLimiterTests.swift`
- `macOS/Tests/MPXPrimeTests/BS412FullChainTests.swift`
  - replace settled-only assertions with transition and every-window checks.

Remove the stale `AppConfig.normalize()` comment that still describes an
operator-selectable 30-to-90-second BS.412 window. The setting was removed by
P0-6.

## Tests to write first

Every new regression test must fail on the current branch for the stated
reason before implementation begins.

### Fast deterministic controller tests

1. `firstCompleteWindowNeverExceedsCeiling`
   - steady 38 kHz-deviation sine, no subcarriers, ceiling 0 dBr;
   - inspect the first complete 60-second window, not a 480-second endpoint;
   - current code should fail near +2.35 dBr.

2. `hotProgramAfterQuietNeverExceedsAnyWindow`
   - prime with compliant or quiet program, then step to +6 dBr;
   - check every completed block/window through attack and recovery.

3. `releaseDoesNotReboundAcrossCeiling`
   - hot, then quiet, then hot again;
   - catch the current underdamped crossing during release.

4. `pilotAndRDSRemainConstantWhileAudioIsReduced`
   - use coherent pilot and RDS-like components;
   - verify their samples are bit-identical before and after the controller;
   - verify only audio gain changes.

5. `subcarriersAloneOverBudgetIsUnachievable`
   - no audio;
   - guard reports the state and does not alter subcarriers.

6. `crossTermCannotHideAnOverage`
   - construct audio and subcarrier blocks with positive and negative
     correlation;
   - compare exact `(g*a+s)^2` energy with the guard result.

7. `earlyAudioCannotConsumeFutureSubcarrierBudget`
   - start with a hot audio burst and then emit pilot/RDS with no audio;
   - assert every completed window stays within the ceiling and the
     subcarriers remain untouched.

8. `guardIsIdleOnCompliantProgram`
   - assert bit identity and zero guard duty below the ceiling.

9. `blockBoundaryOffsetsHaveTheSameVerdict`
   - shift a hot burst across all 64 possible phases;
   - prove the chosen margin covers non-aligned 60-second windows.

10. `testToneAdvancesThePowerWindow`
    - render Test Tone for a known duration;
    - `secondsObserved` must advance and measured dBr must include it;
    - compliance validity must be false if control is suspended.

11. `enableUsesExistingHistory`
    - measure while disabled, enable on a hot full window, and verify there is
      no new 60-second blind period.

Use a block-energy test helper so most controller tests do not synthesize tens
of millions of individual samples. Keep at least one sample-path test to prove
that the optimized path and the block-energy oracle agree.

### Deep full-chain tests

Keep these behind `MPXPRIME_DEEP=1`:

- render at least one startup, quiet-to-hot, and hot-to-quiet-to-hot case;
- feed the emitted composite into the independent `MeterAnalysis` engine;
- check every available rolling window, not only `suffix(60 seconds)`;
- enable pilot and deterministic RDS so complete-multiplex wiring is exercised;
- test `mpx_deviation_khz` at 50 and 75 while retaining the 1.0 == 75 kHz
  modulation-domain convention;
- test non-zero `output_gain_db` and verify trim compensation;
- assert pilot/RDS levels and phase remain unchanged;
- assert the final clamp and post-injection overshoot remain idle;
- report hard-guard duty. Normal program should use the transparent rider,
  not live in the emergency guard.

The current `theLimiterBringsTheCompleteMultiplexUnderTheCeiling` may remain as
a settling test, but it is not a compliance test and should be renamed.

## Performance and real-time requirements

- Allocate all rings and scratch storage in `configure`, never in `process`.
- Keep rolling sums in Double; samples and ring entries may remain Float if
  an error-bound test justifies it.
- No locks, clock reads, strings, array creation, or filter design in the
  render path.
- Keep the normal path branch-light. Only solve the gain interval when the
  unmodified candidate would spend more than its allowance.
- Add a relative DSP-cost test and run `--bench-blocks` on a release build.
- If 64-sample accounting remains, document the exact duration and alignment
  bound at every supported MPX rate.
- Preserve reset and live-apply semantics. A ceiling edit must not discard the
  accumulated 60-second history.

## Validation gates

Run, and record the actual results in the commit message:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path macOS
MPXPRIME_DEEP=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path macOS --filter BS412
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftlint --strict
swift run --package-path macOS MPXPrime --verify --baseline-strict --seconds 5
scripts/check-webui.sh
npx --yes markdownlint-cli2 '**/*.md'
python3 scripts/check-doc-anchors.py
```

Also run the Linux suite in the native x86_64 environment used for the Tier 1
baseline. The default chain has BS.412 disabled, so a correct isolated change
should leave all stored baselines bit-identical. Do not recapture a baseline
to hide movement in the disabled path.

For a live smoke test, enable BS.412 before routing to the exciter, wait until
the window is valid, step between quiet and dense program, and compare the
encoder readout with MPX Prime Meter off-air. The encoder and Meter should
agree within the existing measurement tolerance, the hard guard should remain
idle in normal operation, and no pilot/RDS level or phase movement is allowed.

## Acceptance criteria

The work is complete only when all of these are true:

- every tested 60-second interval is at or below the selected ceiling;
- the first complete window and program transitions are covered;
- the reporting meter never pauses for Test Tone;
- suspended calibration operation is explicit and never shown as compliant;
- pilot and RDS remain constant;
- an impossible subcarrier budget is reported, not hidden;
- the hard guard is normally idle and allocation-free;
- GUI, dashboard, REST, docs, and tests expose the same state;
- the BS.412-disabled chain remains baseline-identical on macOS and Linux.
