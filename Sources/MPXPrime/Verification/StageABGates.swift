#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
import Foundation
import MPXPrimeCore

func multibandCouplingComparisonScenarios() -> [VerificationScenario] {
    var denseNoiseL = DeterministicNoise(seed: 0xC011_0000_0000_0001)
    var denseNoiseR = DeterministicNoise(seed: 0xC011_0000_0000_0002)
    var speechNoise = DeterministicNoise(seed: 0xC011_0000_0000_0003)
    return [
        VerificationScenario(
            name: "bass_dense",
            description: "Dense bass-heavy music bed",
            quality: QualityExpectations(
                maxCorrelationDelta: nil,
                maxOutputCorrelation: nil,
                minSideRetention: nil,
                maxAbsRMSDeltaDB: nil,
                maxOccupied999Hz: nil,
                maxAbove60kRatioDB: nil,
                maxAbove67kRatioDB: nil
            )
        ) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            let kickEnv = pow(max(0.0, sin(2.0 * Double.pi * 2.1 * t)), 8.0)
            let bass = (0.50 + (0.35 * kickEnv)) * sin(2.0 * Double.pi * 62.0 * t)
            let lowMid = 0.20 * sin(2.0 * Double.pi * 240.0 * t)
            let vocal = 0.18 * sin(2.0 * Double.pi * 1_300.0 * t)
            let air = 0.10 * sin(2.0 * Double.pi * 7_200.0 * t)
            let l = Float(bass + lowMid + vocal + air) + (denseNoiseL.next() * 0.025)
            let r = Float((0.92 * bass) + (0.18 * lowMid) - (0.14 * vocal) + (0.08 * air))
                + (denseNoiseR.next() * 0.025)
            return (l, r)
        },
        VerificationScenario(
            name: "kick_vocal",
            description: "Kick/bass under vocal presence",
            quality: QualityExpectations(
                maxCorrelationDelta: nil,
                maxOutputCorrelation: nil,
                minSideRetention: nil,
                maxAbsRMSDeltaDB: nil,
                maxOccupied999Hz: nil,
                maxAbove60kRatioDB: nil,
                maxAbove67kRatioDB: nil
            )
        ) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            let beat = pow(max(0.0, sin(2.0 * Double.pi * 2.0 * t)), 10.0)
            let kick = beat * sin(2.0 * Double.pi * 78.0 * t)
            let bass = 0.44 * sin(2.0 * Double.pi * 118.0 * t)
            let vowel = 0.22 * sin(2.0 * Double.pi * 720.0 * t)
            let consonant = 0.16 * sin(2.0 * Double.pi * 3_100.0 * t)
            let l = Float((0.46 * kick) + bass + vowel + consonant + (0.05 * sin(2.0 * Double.pi * 6_400.0 * t)))
            let r = Float((0.43 * kick) + (0.96 * bass) + (0.20 * vowel) - (0.13 * consonant))
            return (l, r)
        },
        VerificationScenario(
            name: "italo_pump",
            description: "Four-on-floor dance-style bass and bright synths",
            quality: QualityExpectations(
                maxCorrelationDelta: nil,
                maxOutputCorrelation: nil,
                minSideRetention: nil,
                maxAbsRMSDeltaDB: nil,
                maxOccupied999Hz: nil,
                maxAbove60kRatioDB: nil,
                maxAbove67kRatioDB: nil
            )
        ) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            let kickEnv = pow(max(0.0, sin(2.0 * Double.pi * 2.0 * t)), 12.0)
            let kick = kickEnv * sin(2.0 * Double.pi * 54.0 * t)
            let bass = 0.46 * sin(2.0 * Double.pi * 108.0 * t)
            let synth = 0.22 * sin(2.0 * Double.pi * 1_700.0 * t)
            let hat = 0.13 * sin(2.0 * Double.pi * 9_200.0 * t)
            return (
                Float((0.62 * kick) + bass + synth + hat),
                Float((0.58 * kick) + (0.92 * bass) - (0.18 * synth) + (0.10 * hat))
            )
        },
        VerificationScenario(
            name: "wide_bass",
            description: "Wide bass stereo stress from standard verifier",
            quality: QualityExpectations(
                maxCorrelationDelta: nil,
                maxOutputCorrelation: nil,
                minSideRetention: nil,
                maxAbsRMSDeltaDB: nil,
                maxOccupied999Hz: nil,
                maxAbove60kRatioDB: nil,
                maxAbove67kRatioDB: nil
            )
        ) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            let bass = sin(2.0 * Double.pi * 72.0 * t)
            let upper = sin(2.0 * Double.pi * 1_600.0 * t)
            return (
                Float((0.62 * bass) + (0.20 * upper)),
                Float((-0.38 * bass) + (0.18 * upper))
            )
        },
        VerificationScenario(
            name: "speech_bed",
            description: "Speech-like mids over a music bed",
            quality: QualityExpectations(
                maxCorrelationDelta: nil,
                maxOutputCorrelation: nil,
                minSideRetention: nil,
                maxAbsRMSDeltaDB: nil,
                maxOccupied999Hz: nil,
                maxAbove60kRatioDB: nil,
                maxAbove67kRatioDB: nil
            )
        ) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            let bed = 0.30 * sin(2.0 * Double.pi * 95.0 * t)
            let speechEnv = 0.42 + (0.20 * sin(2.0 * Double.pi * 3.7 * t))
            let speech =
                speechEnv
                * ((0.20 * sin(2.0 * Double.pi * 480.0 * t))
                    + (0.18 * sin(2.0 * Double.pi * 1_250.0 * t))
                    + (0.10 * sin(2.0 * Double.pi * 2_800.0 * t)))
            let n = Double(speechNoise.next()) * 0.030
            return (Float(bed + speech + n), Float((0.96 * bed) + (0.92 * speech) + n))
        }
    ]
}

func runMultibandCouplingComparison(
    baseConfig: AppConfig,
    durationSeconds: Double
) -> Int32 {
    let compareDuration = max(1.0, min(durationSeconds, 5.0))
    var disabledConfig = baseConfig
    disabledConfig.widebandAGCEnabled = false
    disabledConfig.multibandEnabled = true
    disabledConfig.multibandMode = 5
    disabledConfig.multibandLowThresholdDB = -30.0
    disabledConfig.multibandMidThresholdDB = -22.0
    disabledConfig.multibandHighThresholdDB = -20.0
    disabledConfig.multibandLowRatio = 4.0
    disabledConfig.multibandMidRatio = 1.8
    disabledConfig.multibandHighRatio = 1.45
    disabledConfig.multibandLinkStrength = 0.65
    disabledConfig.multibandInterBandCouplingEnabled = false

    var enabledConfig = disabledConfig
    enabledConfig.multibandInterBandCouplingEnabled = true

    print("Multiband Inter-Band Coupling A/B")
    print("Toggle: multiband_inter_band_coupling_enabled")
    print("Scope: forced multiband-on, AGC-off program scenarios; production default remains toggle-off")
    print("")
    print("Scenario              LowDelta  MidDelta  HighDelta  RMSDelta  CorrDelta  SideDelta  PeakDelta  POvrOn")
    print("--------------------  --------  --------  ---------  --------  ---------  ---------  ---------  ------")

    var warnings: [String] = []
    var usefulCount = 0
    var offNanos: UInt64 = 0
    var onNanos: UInt64 = 0

    for scenario in multibandCouplingComparisonScenarios() {
        let offStart = DispatchTime.now().uptimeNanoseconds
        let off = verifyScenario(
            config: disabledConfig,
            durationSeconds: compareDuration,
            scenario: scenario
        )
        offNanos += DispatchTime.now().uptimeNanoseconds - offStart

        let onStart = DispatchTime.now().uptimeNanoseconds
        let on = verifyScenario(
            config: enabledConfig,
            durationSeconds: compareDuration,
            scenario: scenario
        )
        onNanos += DispatchTime.now().uptimeNanoseconds - onStart

        let lowDelta = on.outputBands.lowDBFS - off.outputBands.lowDBFS
        let midDelta = on.outputBands.midDBFS - off.outputBands.midDBFS
        let highDelta = on.outputBands.highDBFS - off.outputBands.highDBFS
        let rmsDelta = on.rmsDeltaDB - off.rmsDeltaDB
        let corrDelta = on.outputSignal.correlation - off.outputSignal.correlation
        let sideDelta = ratioDB(on.outputSignal.sideToMidRatio, off.outputSignal.sideToMidRatio)
        let peakDelta = dbfsValue(on.peakAbs) - dbfsValue(off.peakAbs)

        if on.maxPostInjectionOvershoot > 1e-4 || on.overBudget {
            warnings.append("\(scenario.name): enabled path exceeded composite budget")
        }
        if abs(corrDelta) > 0.15 {
            warnings.append("\(scenario.name): output correlation changed by \(String(format: "%+.2f", corrDelta))")
        }
        if sideDelta < -1.5 {
            warnings.append("\(scenario.name): side/mid fell by \(String(format: "%.1f", -sideDelta)) dB")
        }
        if highDelta < -0.05 || midDelta < -0.05 {
            usefulCount += 1
        }

        print(
            "\(padded(scenario.name, width: 20))  "
                + "\(String(format: "%+8.2f", lowDelta))"
                + "  \(String(format: "%+8.2f", midDelta))"
                + "  \(String(format: "%+9.2f", highDelta))"
                + "  \(String(format: "%+8.2f", rmsDelta))"
                + "  \(String(format: "%+9.2f", corrDelta))"
                + "  \(String(format: "%+9.2f", sideDelta))"
                + "  \(String(format: "%+9.2f", peakDelta))"
                + "  \(String(format: "%6.4f", on.maxPostInjectionOvershoot))"
        )
    }

    let costRatio = Double(onNanos) / max(1.0, Double(offNanos))
    print("")
    print("Cost ratio: \(String(format: "%.2fx", costRatio)) (enabled/offline render wall time)")
    print("")
    print("Assessment")
    if usefulCount == 0 {
        warnings.append("enabled path did not measurably reduce mid/high energy on the comparison scenarios")
    }
    // Wall time is reported, not judged: on a shared or busy machine it
    // measures the host, and it used to turn the gate TIGHT on its own
    // (test-suite review 2026-10 finding 16). DSPThroughputTests
    // own the relative cost budgets.
    if costRatio > 1.25 {
        print("Note: enabled path cost ratio \(String(format: "%.2fx", costRatio)) exceeds 1.25x (wall time, informational).")
    }
    if warnings.isEmpty {
        print("Result: OK - coupling stayed safe and measurably shaped upper-band energy.")
        return 0
    }
    print("Comparison notes:")
    for warning in warnings {
        print("- \(warning)")
    }
    print("Result: TIGHT - coupling is implemented, but preset use needs review.")
    return 1
}

/// 90-degree L/R program: the one case where SSB RAISES the composite
/// peak (Orban's documented overshoot case). L and R carry the same tone
/// in quadrature, so M and S have equal envelopes that peak a quarter
/// cycle apart: DSB peaks at sqrt 2 (relative), SSB at 1 + amount because
/// the S envelope sqrt(S^2 + H{S}^2) is flat and still full when M peaks.
func ssbQuadratureScenario() -> VerificationScenario {
    VerificationScenario(
        name: "quadrature_lr",
        description: "L/R 1 kHz tone correlated at 90 degrees (SSB peak cost case)",
        quality: .none
    ) { frame, sampleRate in
        // -16.5 dBFS: with the audio processing bypassed and the shipped
        // +4 dB drive the composite stays well under the budget, so the
        // always-on 1x safety soft clip never touches it and the +3 dB
        // cost is measurable (at 0.5 both variants flatten to -1.1 dBFS).
        // 100 ms raised-cosine fade-in: `verifyScenario` keeps the peak
        // of the WHOLE render, and the cosine channel's step at frame 0
        // becomes a pre-emphasis spike that would be the reading.
        let t = Double(frame) / sampleRate
        let fade = t >= 0.1 ? 1.0 : 0.5 * (1.0 - cos(Double.pi * t / 0.1))
        let phase = 2.0 * Double.pi * 1_000.0 * t
        return (Float(0.15 * fade * sin(phase)), Float(0.15 * fade * cos(phase)))
    }
}

/// Single-tone-pair theory for the 90-degree L/R composite peak cost of
/// SSB at `amount`: max(1 + amount, sqrt 2) over the DSB peak sqrt 2.
/// +3.01 dB at amount 1, +1.60 dB at 0.7, 0 dB below 0.41.
func ssbQuadraturePeakCostDB(amount: Float) -> Float {
    let root2 = Float(2.0).squareRoot()
    return 20.0 * log10f(max(1.0 + amount, root2) / root2)
}

/// SSB Stereo compatibility gate: the fixed lower-sideband SSB / VSB
/// encoder against classic DSB. It makes NO loudness claim: the
/// composite-peak reclaim is printed for information only (0.00 dB
/// measured, the SSB stereo review -- SSB cannot lower a composite
/// peak). It FAILs (exit 1) when SSB breaks compatibility:
/// - the composite budget or the output correlation on program;
/// - coherent separation (below 20 dB, or more than 6 dB under DSB);
/// - the kept sideband: at amount 1.0 in the linear chain the upper
///   sideband (38 + f) must sit at least 40 dB below the lower one at
///   1 and 10 kHz (a wrong sign shows the mirror image);
/// - decoder phase tolerance: with the 38 kHz reference 10 degrees off,
///   SSB-on separation at 1 kHz must stay at or above 20 dB (theory:
///   20 log10 cot 5 deg = 21.2 dB; DSB keeps 42 dB);
/// - the composite-peak cost on 90-degree L/R program, which must not
///   exceed the tone-pair theory `ssbQuadraturePeakCostDB` by more than
///   0.5 dB (a delay mismatch or a sign fault adds more).
func runSSBStereoComparison(
    baseConfig: AppConfig,
    durationSeconds: Double
) -> Int32 {
    let compareDuration = max(2.0, min(durationSeconds, 6.0))
    var offConfig = baseConfig
    offConfig.ssbStereoEnabled = false
    var onConfig = offConfig
    onConfig.ssbStereoEnabled = true
    var onFull = onConfig
    onFull.ssbStereoAmount = 1.0

    // The encoder's own peak effect needs a LINEAR composite: downstream
    // peak controllers flatten both variants to the same ceiling. The
    // scenario table, the kept-sideband check and the quadrature peak
    // cost run with clipper / limiter / soft-clip off; the tone table and
    // the reference-error sweep run the full production chain.
    var offLinear = offConfig
    offLinear.compositeClipperEnabled = false
    offLinear.limitMPX = false
    offLinear.audioCompositeSoftClipEnabled = false
    var onLinear = offLinear
    onLinear.ssbStereoEnabled = true
    var onLinearFull = onLinear
    onLinearFull.ssbStereoAmount = 1.0

    let amount = Float(onConfig.ssbStereoAmount)
    print("SSB Stereo A/B (classic DSB stereo vs fixed lower-sideband SSB/VSB encoder)")
    print("Toggle: mpx_ssb_stereo_enabled  (ssb_amount \(String(format: "%.2f", amount)); sideband, phase and peak-cost checks at 1.00)")
    print("Scope: program scenarios (LINEAR composite -- peak controllers off, so the")
    print("encoder's raw peak effect is visible; informational, SSB claims no loudness)")
    print("+ tone sidebands and coherent decode on the full chain + kept-sideband depth")
    print("+ decoder reference-error sweep + 90-degree L/R peak cost; default stays off")
    print("")
    print("Scenario              PeakDelta  AudioPkDelta  CorrDelta  SideDelta  POvrOn")
    print("--------------------  ---------  ------------  ---------  ---------  ------")

    var failures: [String] = []
    var totalReclaimDB: Float = 0.0
    var scenarioCount = 0

    for scenario in advancedDynamicsComparisonScenarios() + [ssbQuadratureScenario()] {
        let off = verifyScenario(
            config: offLinear, durationSeconds: compareDuration, scenario: scenario)
        let on = verifyScenario(
            config: onLinear, durationSeconds: compareDuration, scenario: scenario)

        let peakDelta = dbfsValue(on.peakAbs) - dbfsValue(off.peakAbs)
        let audioPkDelta = dbfsValue(on.maxAudioCompositePeak) - dbfsValue(off.maxAudioCompositePeak)
        let corrDelta = on.outputSignal.correlation - off.outputSignal.correlation
        let sideDelta = ratioDB(on.outputSignal.sideToMidRatio, off.outputSignal.sideToMidRatio)
        totalReclaimDB += -audioPkDelta
        scenarioCount += 1

        if on.maxPostInjectionOvershoot > 1e-4 || on.overBudget {
            failures.append("\(scenario.name): SSB path exceeded composite budget")
        }
        if abs(corrDelta) > 0.2 {
            failures.append("\(scenario.name): output correlation changed by \(String(format: "%+.2f", corrDelta))")
        }

        print(
            "\(padded(scenario.name, width: 20))  "
                + "\(String(format: "%+9.2f", peakDelta))"
                + "  \(String(format: "%+12.2f", audioPkDelta))"
                + "  \(String(format: "%+9.2f", corrDelta))"
                + "  \(String(format: "%+9.2f", sideDelta))"
                + "  \(String(format: "%6.4f", on.maxPostInjectionOvershoot))"
        )
    }

    // Tone-based sideband shape: the SSB action itself (asymmetry should
    // GROW with the toggle) and the receiver-decode cost (coherent
    // separation must stay within tolerance).
    let tones = [1_000.0, 10_000.0, 14_000.0]
    print("")
    print("Tone      AsymOff   AsymOn   SepOff    SepOn    SepDelta")
    print("--------  -------  -------  -------  -------  ---------")
    let toneDuration = max(3.0, compareDuration)
    var minSeparationOn: Float = 1_000.0
    for toneHz in tones {
        let sbOff = encoderSidebandMetrics(
            config: offConfig, toneHz: toneHz, drivenChannel: "L", durationSeconds: toneDuration)
        let sbOn = encoderSidebandMetrics(
            config: onConfig, toneHz: toneHz, drivenChannel: "L", durationSeconds: toneDuration)
        let sepOff = receiverToneAnalysis(
            config: offConfig, toneHz: toneHz, durationSeconds: toneDuration).coherent.separationDB
        let sepOn = receiverToneAnalysis(
            config: onConfig, toneHz: toneHz, durationSeconds: toneDuration).coherent.separationDB
        minSeparationOn = min(minSeparationOn, sepOn)
        let sepDelta = sepOn - sepOff
        if sepDelta < -6.0 {
            failures.append("\(Int(toneHz)) Hz: coherent separation dropped \(String(format: "%.1f", -sepDelta)) dB (> 6 dB)")
        }
        print(
            "\(padded("\(Int(toneHz)) Hz", width: 8))  "
                + "\(String(format: "%7.2f", sbOff.asymmetryDB))"
                + "  \(String(format: "%7.2f", sbOn.asymmetryDB))"
                + "  \(String(format: "%7.1f", sepOff))"
                + "  \(String(format: "%7.1f", sepOn))"
                + "  \(String(format: "%+9.1f", sepDelta))"
        )
    }

    // Kept sideband: the LOWER one (38 - f), always. Linear chain so the
    // composite clipper cannot regenerate the suppressed side.
    print("")
    print("Kept sideband (linear chain, amount 1.00, L drive; Lower = 38 - f, Upper = 38 + f)")
    print("Tone      Lower    Upper    Lower-Upper")
    print("--------  -------  -------  -----------")
    for toneHz in tones {
        let sb = encoderSidebandMetrics(
            config: onLinearFull, toneHz: toneHz, drivenChannel: "L", durationSeconds: toneDuration)
        let depth = sb.lowerSidebandDBFS - sb.upperSidebandDBFS
        if toneHz <= 10_000.0 && depth < 40.0 {
            failures.append("\(Int(toneHz)) Hz: upper sideband only \(String(format: "%.1f", depth)) dB below the lower one (>= 40 dB required)")
        }
        print(
            "\(padded("\(Int(toneHz)) Hz", width: 8))  "
                + "\(String(format: "%7.1f", sb.lowerSidebandDBFS))"
                + "  \(String(format: "%7.1f", sb.upperSidebandDBFS))"
                + "  \(String(format: "%+11.1f", depth))"
        )
    }

    // Decoder reference-error sweep: the published objection to SSB
    // stereo. DSB crosstalk goes as (1 - cos phi), SSB as sin phi.
    let referenceErrors = [0.0, 5.0, 10.0]
    print("")
    print("Decoder 38 kHz reference error (coherent decode, full chain; SSB on at amount 1.00)")
    print("Tone      Error    SepOff    SepOn    Delta")
    print("--------  -------  -------  -------  -------")
    for toneHz in tones {
        let sepOff = receiverToneSeparationUnderReferenceError(
            config: offConfig, toneHz: toneHz, durationSeconds: toneDuration,
            referenceErrorsDegrees: referenceErrors)
        let sepOn = receiverToneSeparationUnderReferenceError(
            config: onFull, toneHz: toneHz, durationSeconds: toneDuration,
            referenceErrorsDegrees: referenceErrors)
        for (index, degrees) in referenceErrors.enumerated() {
            if toneHz == 1_000.0 && degrees == 10.0 && sepOn[index] < 20.0 {
                failures.append("1 kHz: SSB-on separation with a 10 degree reference error is \(String(format: "%.1f", sepOn[index])) dB (>= 20 dB required)")
            }
            print(
                "\(padded("\(Int(toneHz)) Hz", width: 8))  "
                    + "\(leftPadded(String(format: "%.0f deg", degrees), width: 7))"
                    + "  \(String(format: "%7.1f", sepOff[index]))"
                    + "  \(String(format: "%7.1f", sepOn[index]))"
                    + "  \(String(format: "%+7.1f", sepOn[index] - sepOff[index]))"
            )
        }
    }

    // 90-degree L/R: the composite-peak COST of SSB, against theory. The
    // audio processing is bypassed (encode stages stay active) so the AGC
    // cannot re-level the pair and the composite sits under the budget:
    // the 1x safety soft clip is the one peak controller that cannot be
    // switched off, and a touched ceiling would hide the cost. SafetyClip
    // prints its duty so a ceiling-limited reading is visible.
    let quadrature = ssbQuadratureScenario()
    var quadOffConfig = offLinear
    quadOffConfig.processingBypass = true
    var quadOnConfig = onLinearFull
    quadOnConfig.processingBypass = true
    let quadOff = verifyScenario(config: quadOffConfig, durationSeconds: compareDuration, scenario: quadrature)
    let quadOn = verifyScenario(config: quadOnConfig, durationSeconds: compareDuration, scenario: quadrature)
    let quadDelta = dbfsValue(quadOn.maxAudioCompositePeak) - dbfsValue(quadOff.maxAudioCompositePeak)
    let quadTheory = ssbQuadraturePeakCostDB(amount: 1.0)
    print("")
    print("90-degree L/R audio-composite peak (processing bypassed, peak controllers off, amount 1.00): "
        + "off \(String(format: "%.2f", dbfsValue(quadOff.maxAudioCompositePeak))) dBFS, "
        + "on \(String(format: "%.2f", dbfsValue(quadOn.maxAudioCompositePeak))) dBFS, "
        + "delta \(String(format: "%+.2f", quadDelta)) dB (tone-pair theory \(String(format: "%+.2f", quadTheory)) dB; "
        + "\(String(format: "%+.2f", ssbQuadraturePeakCostDB(amount: amount))) dB at amount \(String(format: "%.2f", amount)); "
        + "SafetyClip on \(String(format: "%.2f", quadOn.maxSafetyClipDB)) dB)")
    if quadOn.maxSafetyClipDB > 0.05 {
        failures.append("quadrature_lr: the safety soft clip worked \(String(format: "%.2f", quadOn.maxSafetyClipDB)) dB, so the peak-cost reading is ceiling-limited")
    }
    if quadDelta > quadTheory + 0.5 {
        failures.append("quadrature_lr: SSB added \(String(format: "%.2f", quadDelta)) dB of composite peak, more than the \(String(format: "%.2f", quadTheory)) dB theory + 0.5 dB")
    }

    let meanReclaimDB = scenarioCount > 0 ? totalReclaimDB / Float(scenarioCount) : 0.0
    print("")
    print("Mean audio-composite peak reclaim (informational, no claim): \(String(format: "%.2f", meanReclaimDB)) dB")
    print("")
    print("Assessment")
    if minSeparationOn < 20.0 {
        failures.append("coherent separation fell below 20 dB with SSB on (\(String(format: "%.1f", minSeparationOn)) dB)")
    }
    if failures.isEmpty {
        print("Result: OK - lower-sideband SSB stays decode-compatible: sideband, phase-error and peak-cost checks passed.")
        return 0
    }
    print("Comparison notes:")
    for failure in failures {
        print("- \(failure)")
    }
    print("Result: FAIL - SSB Stereo broke a compatibility check.")
    return 1
}

// MARK: - Composite clipper stereo guard sweep (--verify-stereo-guard)
//
// Chain review 2026-08-30, finding B1: with the stereo guard at 1 the 22-53 kHz
// clipping residual is restored in full, so the composite clipper only ever
// removes the MONO share of an M+S peak. The output then exceeds the ceiling and
// the Final-MPX limiter rides the difference. Orban's half-cosine limiter
// (US 6,434,241) does not protect 23-53 kHz at all and Thimeo / Omnia clip the
// full composite; the trade is HF stereo separation on dense program against
// loudness / limiter duty. This sweep prints that trade, on the shipped Music -
// Loud profile and on the config as loaded, so the default is a measured choice.

// MARK: Bass polarity / bass loss (Clipper campaign item 2)
//
// The bass-protection stages -- mono bass (`processStereoImageStage`), the
// 4x bass clipper (`BassClipper`) and the FM side-channel guard
// (`protectStereoImage`) -- must never invert or drop the bass; Stereo Tool
// once shipped exactly that inversion. Mono bass and the side-channel guard
// touch the side channel only, so on the decoded mono (L+R) the bass clipper
// is the one protection stage that can reach the bass at all.
//
// Scenario: 50 + 80 Hz L/R bass pair at -12 dBFS per tone with a 2 kHz
// left-only tone at -20 dBFS, rendered through the generator as configured
// and once more with the bass clipper off, both decoded with the coherent
// receiver model, 40-120 Hz band of the mono (L+R).
//
// `BassPol`: normalised cross-correlation of the configured chain's decoded
// bass band against the clipper-off chain's at the best lag within +/- 5 ms
// (the clipper's own LR4 phase is a ~3 ms delay at 50-80 Hz), reported
// signed: +1 upright, -1 inverted, near 0 phase-smeared. FAIL below +0.90.
// Measured 2026-10-10: correlating against the INPUT cannot work at that
// bound -- the 30 Hz HPF leads 50 / 80 Hz by 53 / 32 degrees and the bass
// clipper's LR4 lags them by 56 / 94 degrees, so at the chain's 19 ms
// latency the pair reads about +0.2 (phase, not polarity), and the pair's
// half-period aliases 30 and 60 ms away read -0.95 and +0.99. Referencing the
// clipper-off chain cancels everything the stage does not do.
//
// `InPol` (loose, FAIL below +0.50): the input-referenced correlation at the
// chain's measured latency, signed maximum within +/- 3 ms, so a flip
// anywhere upstream of the clipper (which `BassPol` would hide) still fails:
// a 180-degree flip reads at or below about -0.3 there, filter phase alone
// about +0.9. The latency comes from an aperiodic marker, a 100 ms dip in
// the 2 kHz tone 0.8 s into the render, read at the dip's leading edge in the
// band-passed input and decoded 2 kHz envelopes.
//
// `BassLoss`: decoded bass-band RMS over the input's, in dB, minus the same
// ratio on the 2 kHz tone (the chain's static gain), configured chain minus
// clipper-off chain: the bass the protection stage costs. FAIL below -1.5 dB.
// The raw bass-versus-2 kHz tilt is printed per table: on Music - Loud it is
// -2.9 dB, of which the clipper is 0.02 dB and the rest is the multiband
// compressing the far hotter low band (-0.35 dB with multiband off).

/// One render's reading, plus what the chain-versus-chain comparison needs.
struct BassPolarityMeasurement {
    /// Input-referenced correlation at the measured latency (+/- 3 ms, signed max).
    let inputPolarity: Float
    /// Bass-band gain minus the 2 kHz reference gain, dB.
    let tiltDB: Float
    /// Chain plus receiver-model latency from the 2 kHz dip's leading edge, ms.
    let latencyMS: Float
    /// Decoded-over-input gain of the 2 kHz reference tone, dB.
    let referenceGainDB: Float
    /// Decoded mono 40-120 Hz band, full render.
    let bassBand: [Float]
    /// Analysis window into `bassBand`.
    let windowStart: Int
    let windowCount: Int
    let sampleRate: Double
}

struct BassPolarityMetrics {
    /// Configured chain against the clipper-off chain, best lag within +/- 5 ms.
    let polarity: Float
    /// Configured chain against the input at the measured latency, +/- 3 ms.
    let inputPolarity: Float
    /// Bass level the bass-protection stage costs, dB (negative = loss).
    let lossDB: Float
    /// Raw bass-band gain minus the 2 kHz reference gain, chain as configured.
    let tiltDB: Float
    /// Chain plus receiver-model latency, ms.
    let latencyMS: Float
    /// Decoded-over-input gain of the 2 kHz reference tone, dB.
    let referenceGainDB: Float

    static let minPolarity: Float = 0.90
    static let minInputPolarity: Float = 0.50
    static let minLossDB: Float = -1.5
    /// Lag search for the chain-versus-chain correlation.
    static let stageLagHalfWidthSeconds = 0.005
    /// Lag search around the measured latency for the input-referenced correlation.
    static let inputLagHalfWidthSeconds = 0.003
    /// Longest latency the 2 kHz dip is searched for.
    static let maxLatencySeconds = 0.250

    var polarityPasses: Bool { polarity >= Self.minPolarity }
    var inputPolarityPasses: Bool { inputPolarity >= Self.minInputPolarity }
    var lossPasses: Bool { lossDB >= Self.minLossDB }

    init(measured: BassPolarityMeasurement, unprotected: BassPolarityMeasurement) {
        let halfWidth = Int((Self.stageLagHalfWidthSeconds * measured.sampleRate).rounded())
        let count = min(measured.windowCount, unprotected.windowCount)
        let correlation = bestBassCorrelation(
            output: measured.bassBand,
            input: unprotected.bassBand,
            start: measured.windowStart,
            count: count,
            minLag: -halfWidth,
            maxLag: halfWidth,
            signed: false
        )
        polarity = correlation.value
        inputPolarity = measured.inputPolarity
        lossDB = measured.tiltDB - unprotected.tiltDB
        tiltDB = measured.tiltDB
        latencyMS = measured.latencyMS
        referenceGainDB = measured.referenceGainDB
    }
}

/// Dedicated bass scenario: 50 Hz + 80 Hz L/R pair at -12 dBFS per tone,
/// in phase but with the two tones panned opposite ways by 3 dB so mono bass
/// has side energy to fold, plus a 2 kHz left-only tone at -20 dBFS as the
/// static-gain reference. The 2 kHz tone dips out for 100 ms at 0.8 s (2 ms
/// raised-cosine edges) as the latency marker.
enum BassPolarityScenario {
    static let dipStartSeconds = 0.8
    static let dipSeconds = 0.1
    static let dipEdgeSeconds = 0.002

    static func referenceGate(at t: Double) -> Double {
        let edge = dipEdgeSeconds
        let fallStart = dipStartSeconds - edge
        let riseEnd = dipStartSeconds + dipSeconds + edge
        if t <= fallStart || t >= riseEnd { return 1.0 }
        if t < dipStartSeconds {
            return 0.5 * (1.0 + cos(Double.pi * (t - fallStart) / edge))
        }
        if t <= dipStartSeconds + dipSeconds { return 0.0 }
        return 0.5 * (1.0 - cos(Double.pi * (t - (dipStartSeconds + dipSeconds)) / edge))
    }

    static func sample(frame: Int, sampleRate: Double) -> (Float, Float) {
        let t = Double(frame) / sampleRate
        let bassAmplitude = 0.251  // -12 dBFS
        let pannedAmplitude = bassAmplitude * 0.708  // -3 dB
        let tone50 = sin(2.0 * Double.pi * 50.0 * t)
        let tone80 = sin(2.0 * Double.pi * 80.0 * t)
        let tone2k = 0.1 * referenceGate(at: t) * sin(2.0 * Double.pi * 2_000.0 * t)  // -20 dBFS
        let left = (bassAmplitude * tone50) + (pannedAmplitude * tone80) + tone2k
        let right = (pannedAmplitude * tone50) + (bassAmplitude * tone80)
        return (Float(left), Float(right))
    }
}

func bassPolarityScenarioSample(frame: Int, sampleRate: Double) -> (Float, Float) {
    BassPolarityScenario.sample(frame: frame, sampleRate: sampleRate)
}

struct BassPolarityRender {
    let inputLeft: [Float]
    let inputRight: [Float]
    let mpx: [Float]
}

/// Render the bass scenario through the generator (stereo, RDS off, as the
/// other receiver-side helpers do).
func renderBassPolarityScenario(config: AppConfig, durationSeconds: Double) -> BassPolarityRender {
    var cfg = config
    cfg.monoMode = false
    cfg.enRDS = false
    let sampleRate = max(8_000.0, cfg.sampleRate)
    let frames = max(1, Int((durationSeconds * sampleRate).rounded()))
    var inputLeft = [Float](repeating: 0.0, count: frames)
    var inputRight = [Float](repeating: 0.0, count: frames)
    for frame in 0..<frames {
        let source = bassPolarityScenarioSample(frame: frame, sampleRate: sampleRate)
        inputLeft[frame] = source.0
        inputRight[frame] = source.1
    }
    let generator = MPXGenerator(config: cfg, sampleRate: sampleRate)
    var mpx = [Float](repeating: 0.0, count: frames)
    for frame in 0..<frames {
        mpx[frame] = generator.renderSingleSample(leftIn: inputLeft[frame], rightIn: inputRight[frame])
    }
    return BassPolarityRender(inputLeft: inputLeft, inputRight: inputRight, mpx: mpx)
}

/// Two Butterworth biquads per edge (4th order). The same filter runs on
/// input and output, so its own phase cancels in the correlations.
private func bandpass(_ signal: [Float], lowHz: Float, highHz: Float, sampleRate: Double) -> [Float] {
    var highpassA = Biquad()
    var highpassB = Biquad()
    var lowpassA = Biquad()
    var lowpassB = Biquad()
    let rate = Float(sampleRate)
    highpassA.configureHighpass(cutoffHz: lowHz, sampleRate: rate)
    highpassB.configureHighpass(cutoffHz: lowHz, sampleRate: rate)
    lowpassA.configureLowpass(cutoffHz: highHz, sampleRate: rate)
    lowpassB.configureLowpass(cutoffHz: highHz, sampleRate: rate)
    var band = [Float](repeating: 0.0, count: signal.count)
    for i in 0..<signal.count {
        band[i] = lowpassB.process(lowpassA.process(highpassB.process(highpassA.process(signal[i]))))
    }
    return band
}

/// 2 kHz envelope per 1 ms block of a 1.2-3.3 kHz band-passed mono:
/// |projection on sin/cos of 2 kHz|.
private func referenceToneEnvelope(mono: [Float], sampleRate: Double) -> [Double] {
    let banded = bandpass(mono, lowHz: 1_200.0, highHz: 3_300.0, sampleRate: sampleRate)
    let blockLength = max(1, Int((0.001 * sampleRate).rounded()))
    let blocks = banded.count / blockLength
    let omega = 2.0 * Double.pi * 2_000.0 / sampleRate
    var envelope = [Double](repeating: 0.0, count: blocks)
    for block in 0..<blocks {
        var sinSum = 0.0
        var cosSum = 0.0
        for i in 0..<blockLength {
            let index = (block * blockLength) + i
            let phase = omega * Double(index)
            sinSum += Double(banded[index]) * sin(phase)
            cosSum += Double(banded[index]) * cos(phase)
        }
        envelope[block] = sqrt((sinSum * sinSum) + (cosSum * cosSum))
    }
    return envelope
}

/// Block index of the 2 kHz dip's leading edge: the first block from the
/// dip start where the envelope falls under half its level over the 40 ms
/// before the dip. `nil` when no edge is found within `searchBlocks`.
private func dipLeadingEdgeBlock(envelope: [Double], dipStartBlock: Int, searchBlocks: Int) -> Int? {
    let referenceStart = max(0, dipStartBlock - 40)
    guard dipStartBlock > referenceStart, dipStartBlock < envelope.count else { return nil }
    var reference = 0.0
    for block in referenceStart..<dipStartBlock {
        reference += envelope[block]
    }
    reference /= Double(dipStartBlock - referenceStart)
    guard reference > 1e-9 else { return nil }
    let end = min(envelope.count, dipStartBlock + searchBlocks)
    return (dipStartBlock..<end).first(where: { envelope[$0] < 0.5 * reference })
}

/// Unnormalised cross-correlation of `output[start ..< start+count]` against
/// `input` shifted by `lag` samples, sampled every `step` samples.
private func bassCrossCorrelation(
    output: [Float], input: [Float], start: Int, count: Int, lag: Int, step: Int
) -> Double {
    var sum = 0.0
    var i = 0
    while i < count {
        sum += Double(output[start + i]) * Double(input[start + i - lag])
        i += step
    }
    return sum
}

/// Normalised cross-correlation at the best lag in `minLag...maxLag`: the
/// largest |value| (`signed == false`) or the largest value. Coarse search
/// on a ~6 kHz grid (the band tops out at 120 Hz), then sample-exact around
/// the coarse winner. `input` must cover `start - maxLag ..< start + count - minLag`.
private func bestBassCorrelation(
    output: [Float], input: [Float], start: Int, count: Int, minLag: Int, maxLag: Int, signed: Bool
) -> (value: Float, lag: Int) {
    guard count > 0, start - maxLag >= 0, start + count - minLag <= input.count, start + count <= output.count
    else { return (0.0, 0) }
    func score(_ value: Double) -> Double { signed ? value : abs(value) }
    let step = 32
    var bestLag = minLag
    var bestScore = -Double.infinity
    var lag = minLag
    while lag <= maxLag {
        let value = bassCrossCorrelation(output: output, input: input, start: start, count: count, lag: lag, step: step)
        if score(value) > bestScore {
            bestScore = score(value)
            bestLag = lag
        }
        lag += step
    }
    var fineLag = bestLag
    var fineValue = 0.0
    bestScore = -Double.infinity
    for candidate in max(minLag, bestLag - step)...min(maxLag, bestLag + step) {
        let value = bassCrossCorrelation(output: output, input: input, start: start, count: count, lag: candidate, step: 1)
        if score(value) > bestScore {
            bestScore = score(value)
            fineLag = candidate
            fineValue = value
        }
    }
    var outputEnergy = 0.0
    var inputEnergy = 0.0
    for i in 0..<count {
        let out = Double(output[start + i])
        let inp = Double(input[start + i - fineLag])
        outputEnergy += out * out
        inputEnergy += inp * inp
    }
    return (Float(fineValue / max(1e-18, sqrt(outputEnergy * inputEnergy))), fineLag)
}

/// Measure one rendered bass scenario: decode with the coherent receiver
/// model, band the mono, locate the latency from the 2 kHz dip, correlate
/// against the input and take the bass-band and 2 kHz gains.
func bassPolarityMeasurement(config: AppConfig, render: BassPolarityRender) -> BassPolarityMeasurement {
    var cfg = config
    cfg.monoMode = false
    cfg.enRDS = false
    let sampleRate = max(8_000.0, cfg.sampleRate)
    let frames = min(render.inputLeft.count, render.inputRight.count, render.mpx.count)
    let pilotWindow = receiverAnalysisWindow(sampleCount: frames, sampleRate: sampleRate)
    let pilot = estimatePilotPhase(
        samples: render.mpx,
        sampleRate: sampleRate,
        start: pilotWindow.start,
        count: pilotWindow.count
    )
    let decoded = decodeMPXWithReference(
        samples: render.mpx,
        pilotPhase: pilot.phase,
        config: cfg,
        programActivity: 0.5,
        expectedSide: 0.0
    )
    var monoIn = [Float](repeating: 0.0, count: frames)
    var monoOut = [Float](repeating: 0.0, count: frames)
    for i in 0..<frames {
        monoIn[i] = (render.inputLeft[i] + render.inputRight[i]) * 0.5
        monoOut[i] = (decoded.left[i] + decoded.right[i]) * 0.5
    }
    let bandIn = bandpass(monoIn, lowHz: 40.0, highHz: 120.0, sampleRate: sampleRate)
    let bandOut = bandpass(monoOut, lowHz: 40.0, highHz: 120.0, sampleRate: sampleRate)

    // Analysis window: up to 1.5 s (at most half the render) ending 250 ms
    // before the end, which leaves the chain's AGC, the 2 kHz dip's release
    // and the band filters settled and keeps the whole lag range of input
    // history on both sides of the window.
    let margin = Int((BassPolarityMetrics.maxLatencySeconds * sampleRate).rounded())
    let count = max(1, min(frames / 2, Int((1.5 * sampleRate).rounded())))
    let start = frames - margin - count
    let failed = BassPolarityMeasurement(
        inputPolarity: 0.0, tiltDB: -120.0, latencyMS: 0.0, referenceGainDB: 0.0,
        bassBand: bandOut, windowStart: max(0, start), windowCount: 0, sampleRate: sampleRate)
    guard start >= margin, count > margin else { return failed }

    // Latency: the 2 kHz dip's leading edge, decoded minus input, in 1 ms blocks.
    let envelopeIn = referenceToneEnvelope(mono: monoIn, sampleRate: sampleRate)
    let envelopeOut = referenceToneEnvelope(mono: monoOut, sampleRate: sampleRate)
    let dipStartBlock = Int((BassPolarityScenario.dipStartSeconds * 1_000.0).rounded())
    let searchBlocks = Int((BassPolarityMetrics.maxLatencySeconds * 1_000.0).rounded())
    guard let edgeIn = dipLeadingEdgeBlock(envelope: envelopeIn, dipStartBlock: dipStartBlock, searchBlocks: searchBlocks),
        let edgeOut = dipLeadingEdgeBlock(envelope: envelopeOut, dipStartBlock: dipStartBlock, searchBlocks: searchBlocks)
    else { return failed }
    let blockLength = max(1, Int((0.001 * sampleRate).rounded()))
    let latencySamples = max(0, (edgeOut - edgeIn) * blockLength)
    let halfWidth = Int((BassPolarityMetrics.inputLagHalfWidthSeconds * sampleRate).rounded())
    let inputCorrelation = bestBassCorrelation(
        output: bandOut,
        input: bandIn,
        start: start,
        count: count,
        minLag: max(0, latencySamples - halfWidth),
        maxLag: min(margin, latencySamples + halfWidth),
        signed: true
    )

    var outputEnergy = 0.0
    var inputEnergy = 0.0
    for i in 0..<count {
        let out = Double(bandOut[start + i])
        let inp = Double(bandIn[start + i - latencySamples])
        outputEnergy += out * out
        inputEnergy += inp * inp
    }
    let bassGainDB = Float(10.0 * log10(max(1e-18, outputEnergy) / max(1e-18, inputEnergy)))

    // Static-gain reference: the 2 kHz left-only tone (mono carries half of it).
    let referenceIn = toneVector(
        samples: monoIn, sampleRate: sampleRate, frequencyHz: 2_000.0, start: start - latencySamples, count: count)
    let referenceOut = toneVector(
        samples: monoOut, sampleRate: sampleRate, frequencyHz: 2_000.0, start: start, count: count)
    let referenceGainDB = Float(
        20.0 * log10(max(1e-12, referenceOut.amplitude) / max(1e-12, referenceIn.amplitude)))

    return BassPolarityMeasurement(
        inputPolarity: inputCorrelation.value,
        tiltDB: bassGainDB - referenceGainDB,
        latencyMS: Float(Double(latencySamples) * 1_000.0 / sampleRate),
        referenceGainDB: referenceGainDB,
        bassBand: bandOut,
        windowStart: start,
        windowCount: count,
        sampleRate: sampleRate
    )
}

/// Render and measure the chain as configured and with the bass clipper
/// off; the metrics compare the two.
func bassPolarityMetrics(config: AppConfig, durationSeconds: Double) -> BassPolarityMetrics {
    let measured = bassPolarityMeasurement(
        config: config,
        render: renderBassPolarityScenario(config: config, durationSeconds: durationSeconds)
    )
    var unprotectedConfig = config
    unprotectedConfig.bassClipperEnabled = false
    let unprotected = bassPolarityMeasurement(
        config: unprotectedConfig,
        render: renderBassPolarityScenario(config: unprotectedConfig, durationSeconds: durationSeconds)
    )
    return BassPolarityMetrics(measured: measured, unprotected: unprotected)
}

private func bassPolarityFailures(label: String, metrics: BassPolarityMetrics) -> [String] {
    var failures: [String] = []
    if !metrics.polarityPasses {
        failures.append(
            "\(label): BassPol \(String(format: "%+.3f", metrics.polarity)) < "
                + "\(String(format: "%.2f", BassPolarityMetrics.minPolarity)) (bass clipper inverted or "
                + "phase-smeared the decoded 40-120 Hz mono bass against the clipper-off chain)")
    }
    if !metrics.inputPolarityPasses {
        failures.append(
            "\(label): InPol \(String(format: "%+.3f", metrics.inputPolarity)) < "
                + "\(String(format: "%.2f", BassPolarityMetrics.minInputPolarity)) (decoded mono bass against the input "
                + "at the chain's \(String(format: "%.1f", metrics.latencyMS)) ms latency: a flip upstream of the bass clipper)")
    }
    if !metrics.lossPasses {
        failures.append(
            "\(label): BassLoss \(String(format: "%+.2f", metrics.lossDB)) dB < "
                + "\(String(format: "%.1f", BassPolarityMetrics.minLossDB)) dB (bass protection dropped the bass; "
                + "raw bass-vs-2 kHz tilt \(String(format: "%+.2f", metrics.tiltDB)) dB)")
    }
    return failures
}

// MARK: - Programme crosstalk (2026-10 audio-chain overhaul, stereo audit C2 / D3)
//
// The tone sweep above cannot see what the stereo guard does to PROGRAMME:
// a steady tone is ridden by the look-ahead and barely clipped. The clipper
// restores `guard` of the 22-54 kHz (S) share of its clipping residual and
// removes the baseband (M) share in full, so for a signal in ONE channel the
// silent channel carries whatever the two shares do not cancel. The
// residual is a train of short pulses at the 38 kHz crests, whose
// demodulated S share is about TWICE its baseband share (a narrow pulse
// train's fundamental is twice its mean), so the shares cancel at a guard of
// about 0.5 -- not at 0 (full-composite clipping) and not at 1 (M-only
// clipping); the sweep below measures it. The measurement is the
// `SeparationGates.swift` one `--verify-receiver` gates: `panned_program`
// (program_mix into LEFT only) decoded coherently, L - R per octave band,
// gated where the driven channel holds programme and outside the mono-bass
// corner.

struct StereoGuardCrosstalk {
    let decoded: DecodedCrosstalkResult
    /// Mono-bass corner when the stage is on (its bands are not gated).
    let monoBassCornerHz: Double?
    /// Composite clipper kernel GR (dB) over the same programme.
    let clipperGRDB: Float
    /// Final-MPX limiter duty (dB) over the same programme.
    let finalGRDB: Float
    /// Composite sample peak (dBFS) over the same programme.
    let peakDBFS: Float

    func isGated(_ band: DecodedBandCrosstalk) -> Bool {
        let outsideMonoBass = monoBassCornerHz.map { band.band.lowerHz >= $0 * monoBassCrosstalkExclusionFactor } ?? true
        return outsideMonoBass && decoded.hasProgramme(band)
    }
    var gatedBands: [DecodedBandCrosstalk] { decoded.bands.filter(isGated) }
    /// Smallest (crosstalk - gate) over the gated bands; >= 0 passes.
    var worstMarginDB: Float {
        gatedBands.map { $0.crosstalkDB - $0.band.gateDB }.min() ?? 0.0
    }
    var passes: Bool { worstMarginDB >= 0.0 }
}

/// `panned_program` through `config`: the decoded per-band crosstalk from
/// `decodedBandCrosstalk` plus the clipper / limiter duty on the same
/// programme (a second render through `verifyScenario`; RDS off in both so
/// the renders are deterministic).
func stereoGuardCrosstalk(config: AppConfig, durationSeconds: Double) -> StereoGuardCrosstalk? {
    guard let scenario = verificationScenarios().first(where: { $0.name == "panned_program" }) else { return nil }
    var cfg = config
    cfg.monoMode = false
    cfg.enRDS = false
    let decoded = decodedBandCrosstalk(config: cfg, durationSeconds: durationSeconds, source: scenario.sample)
    // Fresh scenario table: the noise generators carry state.
    guard let fresh = verificationScenarios().first(where: { $0.name == "panned_program" }) else { return nil }
    let duty = verifyScenario(config: cfg, durationSeconds: durationSeconds, scenario: fresh)
    return StereoGuardCrosstalk(
        decoded: decoded,
        monoBassCornerHz: cfg.monoBassEnabled ? cfg.monoBassFreqHz : nil,
        clipperGRDB: duty.maxLimiterGRDB,
        finalGRDB: duty.maxSafetyGRDB,
        peakDBFS: dbfsValue(duty.peakAbs))
}

private struct StereoGuardPoint {
    let guardShare: Double
    let finalGR: Float
    let sep14: Float
    let crosstalk: StereoGuardCrosstalk?
}

private func crosstalkCells(_ x: StereoGuardCrosstalk, marks: Bool) -> String {
    x.decoded.bands.map { band in
        var mark = ""
        if marks && !x.isGated(band) {
            let outsideMonoBass = x.monoBassCornerHz.map { band.band.lowerHz >= $0 * monoBassCrosstalkExclusionFactor } ?? true
            mark = outsideMonoBass ? "nc" : "mb"
        }
        return String(format: "%7.1f%-2@", band.crosstalkDB, mark as NSString)
    }.joined(separator: " ")
}

private func printStereoGuardTable(label: String, config: AppConfig, durationSeconds duration: Double)
    -> (points: [StereoGuardPoint], failures: [String]) {
    let scenarios = verificationScenarios()
    guard let dense = scenarios.first(where: { $0.name == "bright_dense" }) else { return ([], []) }

    print("\(label): clipper drive \(String(format: "%.1f", config.finalDriveDB)) dB, threshold \(String(format: "%.1f", config.compositeClipperThresholdDB)) dB, ceiling \(String(format: "%.1f", config.compositeClipperCeilingDB)) dB, multiband \(config.multibandEnabled ? "on" : "off")")
    print("Guard  ClipGR  FinalGR  Peak dBFS  Dev kHz  Sep10k  Sep14k  S-M@14k  RideSINAD  HatSINAD  BassPol  BassLoss")
    print("-----  ------  -------  ---------  -------  ------  ------  -------  ---------  --------  -------  --------")
    var points: [StereoGuardPoint] = []
    var failures: [String] = []
    for share in [0.0, 0.25, 0.5, 0.75, 1.0] {
        var cfg = config
        cfg.compositeClipperStereoGuard = share
        let d = verifyScenario(config: cfg, durationSeconds: duration, scenario: dense)
        let tone14 = receiverToneAnalysis(config: cfg, toneHz: 14_000.0, durationSeconds: duration)
        let sep10 = receiverToneAnalysis(config: cfg, toneHz: 10_000.0, durationSeconds: duration).coherent.separationDB
        let sep14 = tone14.coherent.separationDB
        let sideMono14 = tone14.encoderSideband.sideMonoDeltaDB
        // Fresh HF scenarios per point: their noise generators carry state.
        let hf = hfTransientScenarios()
        let ride = hf.first(where: { $0.name == "ride_multitone" }).map {
            measureHFTransient(config: cfg, scenario: $0, durationSeconds: max(5.0, duration)).hfSINADDB ?? 0.0
        } ?? 0.0
        let hat = hf.first(where: { $0.name == "hat_multitone" }).map {
            measureHFTransient(config: cfg, scenario: $0, durationSeconds: max(5.0, duration)).hfSINADDB ?? 0.0
        } ?? 0.0
        let bass = bassPolarityMetrics(config: cfg, durationSeconds: duration)
        failures += bassPolarityFailures(label: "\(label), guard \(String(format: "%.2f", share))", metrics: bass)
        let deviationKHz = DeviationReadout.kilohertz(compositePeak: d.peakAbs, modulationReferenceScale: 1.0)
        let crosstalk = stereoGuardCrosstalk(config: cfg, durationSeconds: duration)
        points.append(StereoGuardPoint(guardShare: share, finalGR: d.maxSafetyGRDB, sep14: sep14, crosstalk: crosstalk))
        print(
            "\(String(format: "%5.2f", share))  "
                + "\(String(format: "%6.2f", d.maxLimiterGRDB))"
                + "  \(String(format: "%7.2f", d.maxSafetyGRDB))"
                + "  \(String(format: "%9.2f", dbfsValue(d.peakAbs)))"
                + "  \(String(format: "%7.2f", deviationKHz))"
                + "  \(String(format: "%6.1f", sep10))"
                + "  \(String(format: "%6.1f", sep14))"
                + "  \(String(format: "%+7.2f", sideMono14))"
                + "  \(String(format: "%9.1f", ride))"
                + "  \(String(format: "%8.1f", hat))"
                + "  \(String(format: "%+7.3f", bass.polarity))\(bass.polarityPasses ? " " : "!")"
                + " \(String(format: "%+8.2f", bass.lossDB))\(bass.lossPasses ? "" : "!")"
        )
    }
    // Programme crosstalk per guard share (2026-10, stereo audit C2 / D3):
    // panned_program (program_mix into L only), coherent decode, L - R band
    // level; `mb` = under 3 x the mono-bass corner (the stage fills the quiet
    // channel by design), `nc` = no programme in the driven band (noise and
    // IM only); neither is gated.
    print("")
    print("Programme crosstalk (panned_program: program_mix into L only; decoded L - R per band, dB; higher is cleaner)")
    print("Guard  200-400   400-800   800-1k6   1k6-3k2   3k2-6k4   6k4-10k   10k-15k   ClipGR  FinalGR  Peak dBFS  Margin  Verdict")
    print("-----  --------  --------  --------  --------  --------  --------  --------  ------  -------  ---------  ------  -------")
    for point in points {
        guard let x = point.crosstalk else { continue }
        print(
            "\(String(format: "%5.2f", point.guardShare))  \(crosstalkCells(x, marks: true))"
                + "  \(String(format: "%6.2f", x.clipperGRDB))"
                + "  \(String(format: "%7.2f", x.finalGRDB))"
                + "  \(String(format: "%9.2f", x.peakDBFS))"
                + "  \(String(format: "%+6.1f", x.worstMarginDB))"
                + "  \(x.passes ? "OK" : "FAIL")"
        )
    }
    var reference = config
    reference.compositeClipperEnabled = false
    if let referenceCrosstalk = stereoGuardCrosstalk(config: reference, durationSeconds: duration) {
        print(" off   \(crosstalkCells(referenceCrosstalk, marks: false))       -  \(String(format: "%7.2f", referenceCrosstalk.finalGRDB))  \(String(format: "%9.2f", referenceCrosstalk.peakDBFS))       -  (clipper off reference)")
    }
    print(
        "Acceptance: >= \(String(format: "%.0f", pannedProgramCrosstalkGateDB)) dB in every gated band to 10 kHz and "
            + ">= \(String(format: "%.0f", pannedProgramCrosstalkGateHFDB)) dB in 10-15 kHz with the clipper engaged "
            + "(SeparationGates.swift floors); Margin = worst gated band minus its floor.")
    if let shipped = points.first(where: { abs($0.guardShare - config.compositeClipperStereoGuard) < 0.001 }),
       let x = shipped.crosstalk, !x.passes {
        failures.append(
            "\(label), guard \(String(format: "%.2f", config.compositeClipperStereoGuard)): programme crosstalk "
                + "\(String(format: "%.1f", x.worstMarginDB)) dB under its floor in the worst gated band "
                + "with clipper GR \(String(format: "%.2f", x.clipperGRDB)) dB")
    }

    let configured = bassPolarityMetrics(config: config, durationSeconds: duration)
    failures += bassPolarityFailures(
        label: "\(label), bass scenario at guard \(String(format: "%.2f", config.compositeClipperStereoGuard))",
        metrics: configured)
    print(
        "Bass scenario at guard \(String(format: "%.2f", config.compositeClipperStereoGuard)): "
            + "BassPol \(String(format: "%+.3f", configured.polarity)) "
            + "(\(configured.polarityPasses ? "OK" : "FAIL"), min \(String(format: "%+.2f", BassPolarityMetrics.minPolarity))), "
            + "BassLoss \(String(format: "%+.2f", configured.lossDB)) dB "
            + "(\(configured.lossPasses ? "OK" : "FAIL"), min \(String(format: "%+.1f", BassPolarityMetrics.minLossDB)) dB), "
            + "InPol \(String(format: "%+.3f", configured.inputPolarity)) "
            + "(\(configured.inputPolarityPasses ? "OK" : "FAIL"), min \(String(format: "%+.2f", BassPolarityMetrics.minInputPolarity))) "
            + "at latency \(String(format: "%.1f", configured.latencyMS)) ms, "
            + "bass-vs-2 kHz tilt \(String(format: "%+.2f", configured.tiltDB)) dB, "
            + "2 kHz reference gain \(String(format: "%+.2f", configured.referenceGainDB)) dB")
    print("")
    return (points, failures)
}

func runStereoGuardSweep(
    baseConfig: AppConfig,
    durationSeconds: Double
) -> Int32 {
    let duration = max(3.0, min(durationSeconds, 6.0))
    var loud = baseConfig
    _ = PresetCatalog.applyFormatProfile(id: "music_loud", to: &loud)

    print("Per point: bright_dense (ClipGR = composite clipper, FinalGR = Final-MPX limiter duty, peak,")
    print("deviation), 10 / 14 kHz left-only tones (coherent separation; S-M@14k = encoder-side")
    print("sideband-sum minus mono at 14 kHz, 0 = balanced M/S), ride / hat HF SINAD (receiver-side,")
    print("de-emphasised). Measured 2026-08-30: on Music - Loud the share changes nothing; on a hot")
    print("config the Final-MPX ride is 1.19 dB at 0 and 1.33 dB at 1 (the ride is NOT the guard's),")
    print("guard 1 costs ~5 dB of 14 kHz tone separation and buys ~3 dB of decoded hat / ride SINAD.")
    print("BassPol / BassLoss: 50 + 80 Hz L/R bass pair at -12 dBFS with a 2 kHz left-only tone at")
    print("-20 dBFS (100 ms dip at 0.8 s as the latency marker), rendered as configured and with the")
    print("bass clipper off, decoded, mono 40-120 Hz band. BassPol = configured chain correlated with")
    print("the clipper-off chain at the best lag within 5 ms (+1 upright, -1 inverted, ~0 smeared;")
    print("FAIL below +0.90). BassLoss = bass-band RMS gain minus the 2 kHz reference gain, configured")
    print("minus clipper-off, i.e. what bass protection costs (FAIL below -1.5 dB; the raw tilt is")
    print("the multiband's band balance, printed per table). The bass line also checks InPol, the")
    print("input-referenced correlation at the measured latency (FAIL below +0.50: a flip upstream).")
    print("A '!' marks a failing cell.")
    print("")
    let loudTable = printStereoGuardTable(label: "Profile Music - Loud", config: loud, durationSeconds: duration)
    let loadedTable = printStereoGuardTable(label: "Config as loaded", config: baseConfig, durationSeconds: duration)
    let loudPoints = loudTable.points
    let failures = loudTable.failures + loadedTable.failures

    print("Assessment")
    print("Shipped default: mpx_clipper_stereo_guard = \(String(format: "%.2f", AppConfig().compositeClipperStereoGuard))")
    // Acceptance (2026-10): final-limiter duty <= 1.0 dB (the clip depth hands the final limiter its restored guard share, 0.7-0.9 dB at depth 1.0), 14 kHz tone
    // separation >= 20 dB AND the programme-crosstalk floors with the
    // clipper engaged. The tone criterion alone chose 1.0 in 2026-08; the
    // programme criterion is what the operator hears (stereo audit A1).
    let acceptable = loudPoints.filter { $0.finalGR <= 1.0 && $0.sep14 >= 20.0 && ($0.crosstalk?.passes ?? false) }
    if let best = acceptable.max(by: { ($0.crosstalk?.worstMarginDB ?? 0) < ($1.crosstalk?.worstMarginDB ?? 0) }) {
        print("Music - Loud: guard shares with final-limiter duty <= 1.0 dB, 14 kHz separation >= 20 dB and the "
            + "programme-crosstalk floors: "
            + acceptable.map { String(format: "%.2f", $0.guardShare) }.joined(separator: ", ")
            + "; cleanest programme crosstalk among them at \(String(format: "%.2f", best.guardShare)).")
    } else {
        print("Music - Loud: no guard share meets final-limiter duty <= 1.0 dB, 14 kHz separation >= 20 dB and the programme-crosstalk floors.")
    }
    if failures.isEmpty {
        print("Result: OK - sweep printed; the shipped default is chosen from this table (docs/studio-settings-reference.md, Composite Clipper); programme crosstalk, bass polarity and bass level hold at the shipped share.")
        return 0
    }
    print("Findings:")
    for failure in failures {
        print("- \(failure)")
    }
    print("Result: FAIL - the shipped guard share fails the programme-crosstalk floors, or a bass-protection stage inverted, smeared or dropped the bass.")
    return 1
}
