# MPX Prime Future Roadmap

## Plan.md Alignment Check (2026-05-11)

`plan.md` is the controlling product direction: MPX Prime is targeting the
best amateur-grade free FM processor first, not a direct enterprise rack
replacement. Enterprise DSP ideas remain valid stretch goals, but they
should not displace preset tuning, smoke testing, calibration, and the
macOS operator experience.

Important status changes against this file:

| Area | Current code status | Planning implication |
| --- | --- | --- |
| Cross-platform DSP language | DSP core stays Swift per `plan.md`; platform work is audio I/O, locks, device enumeration, CI, packaging. | Treat the C++/JUCE section below as a historical option, not the active plan. |
| Composite clipper look-ahead | Landed (0.26 DSP + 0.27 allocation-free silent live-resize). | Tuning + listening evaluation only — see `plan.md` "Next up" #2. |
| Receiver-model verification | Landed in 0.27: reusable `MPXDecoder` + `--verify-receiver` CLI mode reports separation at 1 / 10 / 14 kHz, mono compatibility, pilot percent + phase, RDS sideband levels. | Promote per-scenario thresholds from TIGHT to hard failure once defaults are tuned; extend to preset sweep. |
| Anti-aliased clipping (US 6,937,912) | Phase A + Phase B candidate landed in 0.27: `BandLimitedStep` + `AcceleratedBandlimitedResidualClipper` opt-in kernel behind `pre_encode_bandlimited_residual_enabled`, operator-tunable taps + cutoff, parameter-sweep-validated defaults, full-MPX-chain A/B + CPU-cost regression coverage. | Keep opt-in until program-material A/B proves a preset benefit; Phase C remains applying the same primitive to the `audioCompositeSoftClipEnabled` shaper. |
| Transient-aware multiband | Landed in 0.28 behind `multiband_transient_aware_attack_enabled = False`: RMS/peak hybrid detector with transient-aware attack stretch. | Validation/listening and preset-use decision only — see roadmap #1 below. |
| Inter-band gain coupling | Landed in 0.28 behind `multiband_inter_band_coupling_enabled = False`: low-band GR biases upper-band thresholds through a smoothed control envelope. | Validation/listening and preset-use decision only — see roadmap #2 below. |
| Multiband composite clipping | Phase 1 landed in 0.28 behind `mpx_multiband_clipper_enabled = False`: host-rate linear-phase low/mid/high composite splitting and independent band clipping, with `--verify-composite-multiband` A/B. | Dense-program listening, preset decision, and any oversampled/guarded refinement remain — see roadmap #3 below. |
| Dynamic pre-emphasis load manager | Not landed. Placement is correct in L/R upstream of pre-encode limiter; no HF sidechain relaxation. | See roadmap #4 below. |
| Composite peak-to-RMS governor | Not landed. `BS412PowerLimiter` controls regulatory average MPX power, not crest/peak-to-RMS density. | See roadmap #6 below. |

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

### 1. Transient-aware multiband envelope follower (landed opt-in in 0.28)

Goal: stop the multiband from flattening kick/snare fronts while still controlling sustained energy. Enterprise processors do this with peak/RMS hybrid detection and transient-dependent attack.

Current implementation: `multiband_transient_aware_attack_enabled = False` keeps the legacy detector as the default path. When enabled, `MonoCompressor` blends RMS and peak level and briefly stretches attack on peak-vs-RMS transient hits. Tests prove transient bursts pass hotter while sustained material converges near the classic detector level. Remaining work is preset A/B and deciding where, if anywhere, to enable it.

Core arithmetic per band:

```text
peakEnv[n] = max(abs(x[n]), peakEnv[n-1] * peakDecay)
rmsEnv[n] = sqrt((rmsCoeff * rmsEnv2[n-1]) + ((1 - rmsCoeff) * x[n]^2))
crest = peakEnv / max(rmsEnv, 1e-6)
transient = clamp((crest - crestStart) / (crestFull - crestStart), 0, 1)
attackMS = lerp(baseAttackMS, transientAttackMS, transient)
```

For transient preservation, `transientAttackMS` is usually slower than the normal attack for the first few milliseconds.

Example:

```text
peakEnv = 0.90
rmsEnv = 0.28
crest = 0.90 / 0.28 = 3.21
crestStart = 2.0
crestFull = 5.0
transient = (3.21 - 2.0) / (5.0 - 2.0) = 0.40
baseAttackMS = 8 ms
transientAttackMS = 28 ms
attackMS = 8 + (28 - 8) * 0.40 = 16 ms
```

Result: a percussive hit gets a slower attack and keeps punch. Sustained dense audio, with crest near 1.5, uses the normal faster attack.

### 2. Inter-band gain coupling

Goal: make the multiband behave more like an Optimod-style processor: heavy low-band gain reduction can gently soften upper-band drive so bass does not punch holes into the rest of the spectrum or make highs sound disconnected.

Current implementation: `multiband_inter_band_coupling_enabled = False` keeps defaults unchanged. When enabled, low-band GR is smoothed with 20 ms attack / 300 ms release and biases upper-band thresholds lower. The 3-band mapping is mid = -0.15 x lowGR and high = -0.25 x lowGR; the 5-band mapping ramps from -0.10 to -0.25 x lowGR across bands 2-5. Tests verify the arithmetic, zero-bias transparency, and stronger upper-band control under bias. `--verify-multiband-coupling` now provides program-material A/B measurements; remaining work is listening and deciding whether a loud preset should enable it.

Core arithmetic:

```text
lowGR = max(0, -lowBandGainDB)
midBiasDB = -0.20 * lowGR
highBiasDB = -0.35 * lowGR
midThresholdEffective = midThresholdDB + midBiasDB
highThresholdEffective = highThresholdDB + highBiasDB
```

Example:

```text
low band GR = 6 dB
midBiasDB = -0.20 * 6 = -1.2 dB
highBiasDB = -0.35 * 6 = -2.1 dB
mid threshold -16.0 dB -> -17.2 dB
high threshold -14.5 dB -> -16.6 dB
```

That makes the mid/high compressors slightly more active while bass is being heavily controlled. Smooth the bias with attack around 20 ms and release around 300 ms so it feels like program-dependent balance, not pumping.

### 3. Multiband composite clipper (Phase 1 landed opt-in in 0.28)

Goal: get more loudness for the same peak deviation with less tonal shift than a single full-band composite clipper.

Current implementation: `mpx_multiband_clipper_enabled = False` inserts a host-rate `CompositeMultibandClipper` after the broadband composite clipper and before the audio-composite bandwidth FIR. It uses linear-phase lowpasses at 180 Hz and 4200 Hz to form low / mid / high composite bands, clips them independently with current ceilings 0.90 / 0.62 / 0.38, then recombines. `--verify-composite-multiband --seconds 2` shows useful HF-heavy peak/audio reduction with zero post-injection overshoot; dense-program listening is still the preset gate.

Future enterprise split:

```text
Band A: 0-180 Hz
Band B: 180-2,000 Hz
Band C: 2,000-15,000 Hz audio
Band D: 23,000-53,000 Hz stereo subcarrier sideband
```

Each band has its own ceiling and cancellation policy. Recombine with linear-phase delay alignment.

Example thresholds:

```text
fullbandCeiling = -0.30 dBFS -> 0.966 lin
lowCeiling = -1.20 dBFS -> 0.871 lin
midCeiling = -0.60 dBFS -> 0.933 lin
highCeiling = -0.20 dBFS -> 0.977 lin
stereoSidebandCeiling = no clip; substitution/cancellation only
```

Arithmetic for per-band clip:

```text
over = max(0, abs(bandSample) - threshold)
shaped = sign(x) * (threshold + knee * tanh(over / knee))
residual = bandSample - shaped
```

For enterprise behavior, the stereo sideband band should prefer residual cancellation/substitution over direct clipping so stereo separation remains stable.

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
| 1 | US6937912B1, anti-aliased clipping with band-limited step functions | Phase A/B are landed for the pre-encode limiter behind `pre_encode_bandlimited_residual_enabled`; remaining evaluation is program A/B and possible composite shaper use. | Replaces "clip then remove aliases" with "generate fewer aliases in the first place." Still the best candidate for cleaner pre-encode and composite clipping, but no longer unused. |
| 2 | US6434241B1, half-cosine FM composite peak control | Fit half-cosine curves to composite clipping-error peaks, filter the error, subtract it from composite. | Good candidate for bounded composite peak correction without adding a nonlinear stage after pilot/RDS injection. |
| 3 | US5737434A, multiband compressor with look-ahead clipper | Delayed audio path, center-clip sidechain, retriggerable sample/hold, LPF, reciprocal gain law. | Useful for a smoother pre-encode limiter or per-band limiter that produces less clipping-like distortion. |
| 4 | US4249042A / US4460871A, multiband cross-coupled compressor | Master band energy controls slave-band gain, with local per-band protection. | Maps directly to inter-band coupling: loud bass can gently soften mids/highs without wideband pumping. |
| 5 | US5913152, FM composite signal processor | Pilot protection plus adjustable limiting and overshoot compensation. | Some is redundant with post-injection pilot/RDS and guard cancellation, but it may contain useful composite overshoot-control details. |

Candidate arithmetic sketches:

Band-limited clipping residual:

```text
crossingFrac = (threshold - x[n-1]) / max(x[n] - x[n-1], 1e-9)
clipResidual = x - clamp(x, -threshold, threshold)
aaResidual = clipResidual * bandlimitedPulse(crossingFrac)
output = input - aaResidual
```

Half-cosine composite correction:

```text
error = composite - clamp(composite, -ceiling, ceiling)
peakA = previousErrorPeak
peakB = currentErrorPeak
halfCos[k] = (peakA + peakB) / 2 + ((peakA - peakB) / 2) * cos(2*pi*k/N)
filteredError = lowpassAndPilotNotch(halfCos)
correctedComposite = composite - filteredError
```

Cross-band coupling:

```text
lowGR = max(0, -lowBandGainDB)
highThresholdBias = -0.35 * lowGR
highThresholdEffective = highThresholdDB + highThresholdBias
```

## Composite peak-control follow-ups (still open)

Past the 0.26 look-ahead + 0.27 silent live-resize work, deliberately deferred:

- **Zero-overshoot enterprise proof.** Look-ahead bounds peaks better than the old time-symmetric soft clipper but is a practical control law, not a formal bound on every possible intersample transient through all downstream stages.
- **Multiband composite limiting.** Phase 1 is landed opt-in via `mpx_multiband_clipper_enabled` with verifier/cost coverage. The still-open part is dense-program listening, preset/default decision, and possible oversampled or guard-band-aware refinement. (Same item as roadmap #3 above.)
- **Multipath-robustness peak-to-RMS constraint.** Composite peak-to-RMS ratio strongly affects FM multipath rejection at the receiver; nothing in the chain explicitly tracks or constrains it yet. (Same item as roadmap #6 above.)

Explicit skip:

- **Sidechain-the-limiter-from-`L+R` per Orban US 4,134,074 / 4,377,728.** With per-band distortion cancellation in place, gain reduction is multiplicative and stereo separation is preserved by construction regardless of sidechain source. The `L+R` trick buys ~1–2 dB more loudness on stereo content — character, not a correctness fix.
