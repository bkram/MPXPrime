# MPX Prime Future Roadmap

## Plan.md Alignment Check (2026-05-11)

`plan.md` is the controlling product direction: MPX Prime is targeting the
best amateur-grade free FM processor first, not a direct enterprise rack
replacement. Enterprise DSP ideas remain valid stretch goals, but they
should not displace preset tuning, smoke testing, calibration, and the
macOS operator experience.

Important status changes against this file:

| Area | Status | What's left |
| --- | --- | --- |
| Cross-platform DSP language | Swift-first per plan.md. C++/JUCE rewrite shelved. | — |
| Anti-aliased clipping (US 6,937,912) | Phase A + B opt-in via `pre_encode_bandlimited_residual_enabled` (0.27). | Program-material A/B; optional Phase C on `audioCompositeSoftClipEnabled`. |
| Transient-aware multiband | Opt-in via `multiband_transient_aware_attack_enabled` (0.28). | Listening + preset decision — see roadmap #1. |
| Inter-band gain coupling | Opt-in via `multiband_inter_band_coupling_enabled` (0.28). | Listening + preset decision — see roadmap #2. |
| Multiband composite clipping | Phase 1 opt-in via `mpx_multiband_clipper_enabled` (0.28). | Listening + Phase 2 (4-band w/ stereo-sideband cancel) — see roadmap #3. |
| Dynamic pre-emphasis load manager | Not landed. | See roadmap #4. |
| Composite peak-to-RMS governor | Not landed. | See roadmap #6. |

## Current Direction: Swift First

For now, MPX Prime stays Swift. The priority is to make the current
macOS/Swift DSP chain correct, verified, tunable, and operator-friendly
before spending effort on a rewrite or broad cross-platform expansion.

Practical order:

1. Finish the Swift DSP chain properly: clamp prevention, verifier
   metrics, presets, calibration, and live-apply smoke tests.
2. Keep the DSP code portable in principle: isolate platform audio I/O,
   locks, device enumeration, and UI concerns from `MPXGenerator`.
3. Revisit Linux once the Swift/macOS baseline is mature. Per `plan.md`,
   the preferred Linux route is still Swift DSP with a JACK/ALSA backend,
   not a C++ rewrite.
4. Treat Windows/JUCE/VST work as later optional product expansion, not
   near-term DSP work.

## Cross-Platform Vision

Long-term: macOS (current) + Linux + Windows. The active Linux plan is **Swift DSP + JACK/ALSA backend** (see `plan.md` "Cross-platform — Linux as first-tier target" for scoping). The earlier C++/JUCE rewrite proposal is shelved — rewriting ~6000 lines of verification-backed Swift DSP for no measurable audio gain is not the right trade. Revisit C++/JUCE only if the Swift-first route hits a concrete blocker that conditional compilation + platform backends can't solve.

## Near-Term Priorities Before Cross-Platform Work

- validate transient-aware multiband attack (Phase 2 implementation shipped opt-in in 0.28; FIR crossovers shipped 0.11)
- validate inter-band gain coupling (implementation shipped opt-in in 0.28)
- broaden deterministic MPX verification and stereo/mono-compatibility checks
- tighten pilot/RDS/deviation calibration workflow
- stabilize presets for PrimeBass, widener, mono bass, and final-stage loudness

## DSP Enterprise-Level Roadmap

These are DSP additions that would move MPX Prime closer to an enterprise MPX processor. They are ranked by practical payoff, not novelty. The common theme: add explicit control laws and measurable invariants instead of relying on "sounds OK" tuning.

### 1. Transient-aware multiband envelope follower — landed opt-in in 0.28

Status: `multiband_transient_aware_attack_enabled` toggle. RMS/peak hybrid detector with crest-driven transient attack stretch. Remaining: program-material listening + preset-use decision. Arithmetic and design notes in CHANGELOG 0.28.

### 2. Inter-band gain coupling — landed opt-in in 0.28

Status: `multiband_inter_band_coupling_enabled` toggle. Low-band GR smoothed with 20 ms attack / 300 ms release biases upper-band thresholds (3-band mid -0.15 / high -0.25; 5-band bands 2-5 at -0.10 / -0.15 / -0.22 / -0.25 × lowGR). `--verify-multiband-coupling` provides the program-material A/B gate. Remaining: listening + preset-use decision.

### 3. Multiband composite clipper — Phase 1 landed opt-in in 0.28

Status: `mpx_multiband_clipper_enabled` toggle. Host-rate linear-phase 3-band split at 180 / 4200 Hz with per-band ceilings 0.90 / 0.62 / 0.38. `--verify-composite-multiband` shows useful HF-heavy peak reduction with zero post-injection overshoot.

Future enterprise refinement (Phase 2 if preset listening proves Phase 1 worth tuning further):

```text
Band A: 0-180 Hz
Band B: 180-2,000 Hz
Band C: 2,000-15,000 Hz audio
Band D: 23,000-53,000 Hz stereo subcarrier sideband (no clip; substitution/cancellation only — preserves separation)
```

The 4-band split with a dedicated stereo-sideband-cancellation policy is the structural upgrade over Phase 1's audio-only 3-band split. Oversampling the clipper kernel is the other obvious refinement if HF aliasing turns out audible in listening tests.

### 4. Dynamic pre-emphasis load manager

Goal: reduce pre-emphasis-driven limiter stress on bright transients without changing the static 50/75 us compliance target during normal material.

Do not switch pre-emphasis curves abruptly. Use a sidechain that detects excess HF energy and blends a small relaxation gain after the pre-emphasis filter, before the pre-encode limiter.

Core arithmetic:

```text
hf = highpass(program, 6 kHz)
hfEnv = envelope(abs(hf), attack=1 ms, release=80 ms)
over = max(0, db(hfEnv) - hfTargetDB)
relaxDB = -min(maxRelaxDB, over * ratio)
hfGain = 10^(relaxDB / 20)
output = lowBand + hfGain * highBand
```

Example:

```text
hfEnv = -9 dBFS
hfTargetDB = -15 dBFS
over = 6 dB
ratio = 0.35
maxRelaxDB = 3.0
relaxDB = -min(3.0, 6 * 0.35) = -2.1 dB
hfGain = 10^(-2.1 / 20) = 0.785
```

The listener hears almost the same tonal balance, but the pre-encode limiter sees fewer extreme HF peaks.

### 5. Receiver-model verification loop (followup — landed groundwork in 0.27, see plan.md "Next up" #6)

Goal: make every DSP change answerable by receiver-facing metrics, not just waveform peak metrics.

Offline verifier should decode the generated MPX like a simple FM stereo receiver:

```text
M = lowpass(mpx, 15 kHz)
pilotPhase = PLL(mpx around 19 kHz)
carrier38 = sin(2 * pilotPhase)
S = lowpass(2 * mpx * carrier38, 15 kHz)
L = M - S
R = M + S
```

Example metrics:

```text
input: L=1 kHz sine at -6 dBFS, R=silence
decoded L RMS = -9.1 dBFS
decoded R RMS = -49.5 dBFS
separation = decodedL - decodedR = 40.4 dB
pass threshold: > 35 dB through full chain at default loudness
```

Add verifier outputs for:

- stereo separation at 1 kHz, 10 kHz, and 14 kHz,
- mono compatibility correlation,
- pilot amplitude error,
- RDS band RMS and centre null,
- post-injection overshoot count,
- MPX power average and peak-to-RMS ratio.

### 6. Composite peak-to-RMS governor

Goal: reduce multipath-sensitive "spiky" composite output without just crushing peaks. This is a higher-level controller around final drive and composite clipper drive.

Core arithmetic over a rolling window:

```text
peak = max(abs(mpx))
rms = sqrt(mean(mpx^2))
crestDB = 20 * log10(peak / max(rms, 1e-6))
driveTrimDB = -k * max(0, crestDB - targetCrestDB)
```

Example:

```text
peak = 0.98
rms = 0.31
crestDB = 20 * log10(0.98 / 0.31) = 10.0 dB
targetCrestDB = 8.5 dB
k = 0.4
driveTrimDB = -0.4 * (10.0 - 8.5) = -0.6 dB
```

Apply `driveTrimDB` slowly, e.g. 1-3 s attack and 5-10 s release. This is not a limiter; it is an automatic preset guardrail that keeps long-term composite density in a controlled window.

### Expired patent candidates to evaluate

These are expired or inactive patent families that look useful for enterprise-level DSP work. Status must be rechecked by jurisdiction before any commercial release; this list is a technical backlog, not legal advice.

Already used, partially landed, or structurally equivalent (do not re-propose as greenfield work; see plan.md "Patent-backed improvements backlog" for code pointers): US6337999B1 (oversampled differential clipper), US6937912B1 Phase A/B (`BandLimitedStep` + opt-in accelerated residual ceiling), US4460871A / US4249042A (Orban overshoot/cross-coupled compressor — partial via per-band cancellation), US6618486B2 (BS.412 multiplex power controller), and the PrimeBass set (US5930373A, US4150253A, US5424488A, US5359665A).

High-value candidates still worth evaluating:

| Priority | Patent | Idea | Why it matters |
| --- | --- | --- | --- |
| 1 | US6434241B1, half-cosine FM composite peak control | Fit half-cosine curves to composite clipping-error peaks, filter the error, subtract it from composite. | Good candidate for bounded composite peak correction without adding a nonlinear stage after pilot/RDS injection. |
| 2 | US5737434A, multiband compressor with look-ahead clipper | Delayed audio path, center-clip sidechain, retriggerable sample/hold, LPF, reciprocal gain law. | Useful for a smoother pre-encode limiter or per-band limiter that produces less clipping-like distortion. |
| 3 | US5913152, FM composite signal processor | Pilot protection plus adjustable limiting and overshoot compensation. | Some is redundant with post-injection pilot/RDS and guard cancellation, but it may contain useful composite overshoot-control details. |

Candidate arithmetic sketch (half-cosine composite correction):

```text
error = composite - clamp(composite, -ceiling, ceiling)
peakA = previousErrorPeak
peakB = currentErrorPeak
halfCos[k] = (peakA + peakB) / 2 + ((peakA - peakB) / 2) * cos(2*pi*k/N)
filteredError = lowpassAndPilotNotch(halfCos)
correctedComposite = composite - filteredError
```

## Composite peak-control still-open

- **Zero-overshoot enterprise proof.** Look-ahead bounds peaks better than the old time-symmetric soft clipper but is a practical control law, not a formal bound on every possible intersample transient through all downstream stages.
- **Multipath-robustness peak-to-RMS constraint.** Composite peak-to-RMS ratio strongly affects FM multipath rejection at the receiver; nothing in the chain explicitly tracks or constrains it yet. (Same item as roadmap #6 above.)

Explicit skip:

- **Sidechain-the-limiter-from-`L+R` per Orban US 4,134,074 / 4,377,728.** With per-band distortion cancellation in place, gain reduction is multiplicative and stereo separation is preserved by construction regardless of sidechain source. The `L+R` trick buys ~1–2 dB more loudness on stereo content — character, not a correctness fix.
