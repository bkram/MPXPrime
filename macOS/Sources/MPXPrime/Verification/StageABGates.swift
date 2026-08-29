#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
import Foundation
import MPXPrimeCore

func runCompositeMultibandClipperComparison(
    baseConfig: AppConfig,
    durationSeconds: Double
) -> Int32 {
    let compareDuration = max(1.0, min(durationSeconds, 5.0))
    let scenarios = verificationScenarios().filter {
        ["bright_dense", "vocal_sibilant", "hf_edge_12k", "hard_panned_hf", "transient_push", "wide_bass"].contains($0.name)
    }
    var disabledConfig = baseConfig
    disabledConfig.compositeClipperEnabled = true
    disabledConfig.compositeMultibandClipperEnabled = false

    var enabledConfig = disabledConfig
    enabledConfig.compositeMultibandClipperEnabled = true

    print("Composite Multiband Clipper A/B")
    print("Toggle: mpx_multiband_clipper_enabled")
    print("Scope: dense/HF verifier scenarios, broadband composite clipper forced on")
    print("")
    print("Scenario              PeakDelta  AudioPkDelta  MarginDelta  POvrOn  CorrDelta  SideDelta  >60kDelta")
    print("--------------------  ---------  ------------  -----------  ------  ---------  ---------  ---------")

    var warnings: [String] = []
    var usefulCount = 0
    // Collected for the shortcoming-characterization table printed after
    // the peak-control table: the two metrics that fail in the main
    // --verify when this stage is enabled (decoded RMS drift + HF
    // leakage above 60/67 kHz). Captured OFF vs ON so the numbers form a
    // baseline yardstick to measure the band-limited-clip (A1) and
    // ceiling-retune (B1) fixes against. See plan.md "multiband clipper
    // shortcomings".
    var characterization: [(name: String, rmsOff: Float, rmsOn: Float,
                            b60Off: Float, b60On: Float,
                            b67Off: Float, b67On: Float)] = []
    for scenario in scenarios {
        let off = verifyScenario(
            config: disabledConfig,
            durationSeconds: compareDuration,
            scenario: scenario
        )
        let on = verifyScenario(
            config: enabledConfig,
            durationSeconds: compareDuration,
            scenario: scenario
        )
        characterization.append((
            name: scenario.name,
            rmsOff: off.rmsDeltaDB, rmsOn: on.rmsDeltaDB,
            b60Off: off.bandwidth.above60kRatioDB, b60On: on.bandwidth.above60kRatioDB,
            b67Off: off.bandwidth.above67kRatioDB, b67On: on.bandwidth.above67kRatioDB
        ))
        let peakDelta = dbfsValue(on.peakAbs) - dbfsValue(off.peakAbs)
        let audioPeakDelta = dbfsValue(on.maxAudioCompositePeak) - dbfsValue(off.maxAudioCompositePeak)
        let marginDelta = on.minBudgetMarginDB - off.minBudgetMarginDB
        let corrDelta = on.outputSignal.correlation - off.outputSignal.correlation
        let sideDelta = ratioDB(on.outputSignal.sideToMidRatio, off.outputSignal.sideToMidRatio)
        let widthDelta = on.bandwidth.above60kRatioDB - off.bandwidth.above60kRatioDB

        if on.maxPostInjectionOvershoot > 1e-4 || on.overBudget {
            warnings.append("\(scenario.name): enabled path exceeded composite budget")
        }
        if widthDelta > 6.0 {
            warnings.append("\(scenario.name): >60 kHz energy worsened by \(String(format: "%.1f", widthDelta)) dB")
        }
        if abs(corrDelta) > 0.18 {
            warnings.append("\(scenario.name): output correlation changed by \(String(format: "%+.2f", corrDelta))")
        }
        if audioPeakDelta < -0.15 || peakDelta < -0.15 {
            usefulCount += 1
        }

        print(
            "\(padded(scenario.name, width: 20))  "
                + "\(String(format: "%+9.2f", peakDelta))"
                + "  \(String(format: "%+12.2f", audioPeakDelta))"
                + "  \(String(format: "%+11.2f", marginDelta))"
                + "  \(String(format: "%6.4f", on.maxPostInjectionOvershoot))"
                + "  \(String(format: "%+9.2f", corrDelta))"
                + "  \(String(format: "%+9.2f", sideDelta))"
                + "  \(String(format: "%+9.2f", widthDelta))"
        )
    }

    // Shortcoming characterization: the two metrics that fail in the main
    // --verify with this stage on. RMSdrift is decoded-output vs input RMS
    // (dB); a larger magnitude ON than OFF means the stage is reshaping the
    // decoded audio (the high band carries the 23-53 kHz L-R subcarrier, so
    // clipping it bleeds into decoded level). >60k/>67k are composite energy
    // above those edges relative to in-band (dB); higher ON = clipping
    // splatter / IM landing in the upper composite. Use the ON-OFF deltas as
    // the baseline to measure A1 (band-limited clip) and B1 (ceiling retune).
    print("")
    print("Shortcoming characterization (decoded RMS drift + HF leakage, OFF vs ON)")
    print("Scenario              RMSdrift_off  RMSdrift_on    >60k_off   >60k_on    >67k_off   >67k_on")
    print("--------------------  ------------  -----------    --------   -------    --------   -------")
    var worstRMSWorsenDB: Float = 0.0
    var worst60WorsenDB: Float = 0.0
    var worst67WorsenDB: Float = 0.0
    for row in characterization {
        worstRMSWorsenDB = max(worstRMSWorsenDB, fabsf(row.rmsOn) - fabsf(row.rmsOff))
        worst60WorsenDB = max(worst60WorsenDB, row.b60On - row.b60Off)
        worst67WorsenDB = max(worst67WorsenDB, row.b67On - row.b67Off)
        print(
            "\(padded(row.name, width: 20))  "
                + "\(String(format: "%+12.2f", row.rmsOff))"
                + "  \(String(format: "%+11.2f", row.rmsOn))"
                + "    \(String(format: "%8.1f", row.b60Off))"
                + "  \(String(format: "%8.1f", row.b60On))"
                + "    \(String(format: "%8.1f", row.b67Off))"
                + "  \(String(format: "%8.1f", row.b67On))"
        )
    }
    print("")
    print("Worst-case worsening with stage ON:")
    print("  decoded RMS drift: \(String(format: "%+.1f", worstRMSWorsenDB)) dB")
    print("  >60k leakage:      \(String(format: "%+.1f", worst60WorsenDB)) dB")
    print("  >67k leakage:      \(String(format: "%+.1f", worst67WorsenDB)) dB")

    print("")
    print("Assessment")
    if usefulCount == 0 {
        warnings.append("enabled path did not reduce peak/audio-composite peak on the comparison scenarios")
    }
    if warnings.isEmpty {
        print("Result: OK - enabled path stayed safe and showed measurable peak-control benefit.")
        return 0
    }
    print("Comparison notes:")
    for warning in warnings {
        print("- \(warning)")
    }
    print("Result: TIGHT - enabled path is implemented, but preset use needs review.")
    return 1
}

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
    if costRatio > 1.25 {
        warnings.append("enabled path cost ratio \(String(format: "%.2fx", costRatio)) exceeds 1.25x")
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

func advancedDynamicsComparisonScenarios() -> [VerificationScenario] {
    var denseNoiseL = DeterministicNoise(seed: 0xAD00_0000_0000_0001)
    var denseNoiseR = DeterministicNoise(seed: 0xAD00_0000_0000_0002)
    let neutral = QualityExpectations(
        maxCorrelationDelta: nil,
        maxOutputCorrelation: nil,
        minSideRetention: nil,
        maxAbsRMSDeltaDB: nil,
        maxOccupied999Hz: nil,
        maxAbove60kRatioDB: nil,
        maxAbove67kRatioDB: nil
    )
    return [
        VerificationScenario(
            name: "level_jump",
            description: "Program jumping -26 -> -6 dB mid-scenario (the leveler's core case)",
            quality: neutral
        ) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            // Alternate quiet / loud every 1.25 s: a 20 dB program jump.
            let loud = Int(t / 1.25) % 2 == 1
            let amp = loud ? 0.50 : 0.05
            let bass = 0.6 * sin(2.0 * Double.pi * 82.0 * t)
            let vocal = 0.5 * sin(2.0 * Double.pi * 1_100.0 * t)
            let air = 0.25 * sin(2.0 * Double.pi * 6_800.0 * t)
            let l = Float(amp * (bass + vocal + air))
            let r = Float(amp * ((0.9 * bass) + (0.8 * vocal) + (1.1 * air)))
            return (l, r)
        },
        VerificationScenario(
            name: "bass_dense",
            description: "Dense bass-heavy music bed",
            quality: neutral
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
            name: "quiet_ballad",
            description: "Low-level sparse program (max-lift territory)",
            quality: neutral
        ) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            let piano = 0.05 * sin(2.0 * Double.pi * 440.0 * t)
                * (0.6 + 0.4 * sin(2.0 * Double.pi * 0.7 * t))
            let bass = 0.035 * sin(2.0 * Double.pi * 110.0 * t)
            let l = Float(piano + bass)
            let r = Float((0.85 * piano) + bass)
            return (l, r)
        },
        VerificationScenario(
            name: "hf_transients",
            description: "Percussive HF content (transient-catch check)",
            quality: neutral
        ) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            let hatEnv = pow(max(0.0, sin(2.0 * Double.pi * 4.0 * t)), 24.0)
            let hat = (0.55 * hatEnv) * sin(2.0 * Double.pi * 9_000.0 * t)
            let snap = (0.4 * pow(max(0.0, sin(2.0 * Double.pi * 2.0 * t + 1.2)), 30.0))
                * sin(2.0 * Double.pi * 3_400.0 * t)
            let bed = 0.22 * sin(2.0 * Double.pi * 520.0 * t)
            let l = Float(hat + snap + bed)
            let r = Float((0.8 * hat) + (1.1 * snap) + (0.9 * bed))
            return (l, r)
        }
    ]
}

/// A/B: (A) classic wideband AGC + 5-band multiband compressor vs (B) the
/// single-stage Advanced Dynamics leveler, on identical program scenarios.
/// Also measures re-processing idempotency: feeding the leveler's output
/// through a fresh leveler should barely change it ("inaudible doubling").
func runAdvancedDynamicsComparison(
    baseConfig: AppConfig,
    durationSeconds: Double
) -> Int32 {
    let compareDuration = max(2.0, min(durationSeconds, 6.0))
    // A: the production two-stage path, forced on.
    var classicConfig = baseConfig
    classicConfig.advancedDynamicsEnabled = false
    classicConfig.widebandAGCEnabled = true
    classicConfig.multibandEnabled = true
    classicConfig.multibandMode = 5

    // B: the fused single-stage leveler (AGC + multiband auto-bypassed).
    var leveledConfig = classicConfig
    leveledConfig.advancedDynamicsEnabled = true

    print("Advanced Dynamics A/B (classic AGC+multiband vs single-stage leveler)")
    print("Toggle: advanced_dynamics_enabled")
    print("Scope: forced dynamics-on program scenarios; production default remains toggle-off")
    print("")
    print("Scenario              RMSDelta  LowDelta  MidDelta  HighDelta  CorrDelta  SideDelta  PeakDelta  POvrOn")
    print("--------------------  --------  --------  --------  ---------  ---------  ---------  ---------  ------")

    var warnings: [String] = []
    var offNanos: UInt64 = 0
    var onNanos: UInt64 = 0
    var maxAbsRMSDelta: Float = 0.0

    for scenario in advancedDynamicsComparisonScenarios() {
        let offStart = DispatchTime.now().uptimeNanoseconds
        let off = verifyScenario(
            config: classicConfig,
            durationSeconds: compareDuration,
            scenario: scenario
        )
        offNanos += DispatchTime.now().uptimeNanoseconds - offStart

        let onStart = DispatchTime.now().uptimeNanoseconds
        let on = verifyScenario(
            config: leveledConfig,
            durationSeconds: compareDuration,
            scenario: scenario
        )
        onNanos += DispatchTime.now().uptimeNanoseconds - onStart

        let rmsDelta = on.rmsDeltaDB - off.rmsDeltaDB
        let lowDelta = on.outputBands.lowDBFS - off.outputBands.lowDBFS
        let midDelta = on.outputBands.midDBFS - off.outputBands.midDBFS
        let highDelta = on.outputBands.highDBFS - off.outputBands.highDBFS
        let corrDelta = on.outputSignal.correlation - off.outputSignal.correlation
        let sideDelta = ratioDB(on.outputSignal.sideToMidRatio, off.outputSignal.sideToMidRatio)
        let peakDelta = dbfsValue(on.peakAbs) - dbfsValue(off.peakAbs)
        maxAbsRMSDelta = max(maxAbsRMSDelta, abs(rmsDelta))

        if on.maxPostInjectionOvershoot > 1e-4 || on.overBudget {
            warnings.append("\(scenario.name): leveler path exceeded composite budget")
        }
        if abs(corrDelta) > 0.2 {
            warnings.append("\(scenario.name): output correlation changed by \(String(format: "%+.2f", corrDelta))")
        }
        if sideDelta < -3.0 {
            warnings.append("\(scenario.name): side/mid fell by \(String(format: "%.1f", -sideDelta)) dB")
        }

        print(
            "\(padded(scenario.name, width: 20))  "
                + "\(String(format: "%+8.2f", rmsDelta))"
                + "  \(String(format: "%+8.2f", lowDelta))"
                + "  \(String(format: "%+8.2f", midDelta))"
                + "  \(String(format: "%+9.2f", highDelta))"
                + "  \(String(format: "%+9.2f", corrDelta))"
                + "  \(String(format: "%+9.2f", sideDelta))"
                + "  \(String(format: "%+9.2f", peakDelta))"
                + "  \(String(format: "%6.4f", on.maxPostInjectionOvershoot))"
        )
    }

    // Idempotency: process program through the leveler, then feed that
    // output through a FRESH leveler. A target-density design should
    // barely move the second time (Stereo Tool's "inaudible doubling").
    let idempotencyDeltaDB = advancedDynamicsIdempotencyDeltaDB(config: leveledConfig)
    let costRatio = Double(onNanos) / max(1.0, Double(offNanos))
    print("")
    print("Re-processing idempotency: \(String(format: "%+.2f", idempotencyDeltaDB)) dB RMS change on second pass (target ~0)")
    print("Cost ratio vs AGC+multiband: \(String(format: "%.2fx", costRatio))")
    print("")
    print("Assessment")
    if abs(idempotencyDeltaDB) > 2.0 {
        warnings.append("second-pass RMS moved \(String(format: "%+.2f", idempotencyDeltaDB)) dB (>2 dB): leveler is not settling at its own target density")
    }
    if costRatio > 1.5 {
        warnings.append("leveler cost ratio \(String(format: "%.2fx", costRatio)) exceeds 1.5x the two stages it replaces")
    }
    if warnings.isEmpty {
        print("Result: OK - single-stage leveler tracks the classic chain safely.")
        return 0
    }
    print("Comparison notes:")
    for warning in warnings {
        print("- \(warning)")
    }
    print("Result: TIGHT - Advanced Dynamics is implemented, but preset use needs review.")
    return 1
}

/// RMS change (dB) between the leveler's first-pass output and a second
/// pass of that output through a fresh leveler instance. Small = the stage
/// recognises already-processed material and stops.
func advancedDynamicsIdempotencyDeltaDB(config: AppConfig) -> Float {
    let sampleRate: Float = 48_000.0
    let seconds: Float = 8.0
    let frames = Int(sampleRate * seconds)
    let measureStart = frames - Int(sampleRate * 2.0)

    func makeLeveler() -> AdvancedDynamicsLeveler {
        var leveler = AdvancedDynamicsLeveler()
        leveler.configureStructure(
            sampleRate: sampleRate,
            x1Hz: Float(config.multibandX1Hz),
            x2Hz: Float(config.multibandX2Hz),
            x3Hz: Float(config.multibandX3Hz),
            x4Hz: Float(config.multibandX4Hz)
        )
        leveler.setParameters(
            targetDB: Float(config.advancedDynamicsTargetDB),
            lowOffsetDB: Float(config.advancedDynamicsLowOffsetDB),
            midOffsetDB: Float(config.advancedDynamicsMidOffsetDB),
            highOffsetDB: Float(config.advancedDynamicsHighOffsetDB),
            maxGainDB: Float(config.advancedDynamicsMaxGainDB),
            density: Float(config.advancedDynamicsDensity),
            speed: Float(config.advancedDynamicsSpeed)
        )
        return leveler
    }

    var first = makeLeveler()
    var firstOutL = [Float](repeating: 0.0, count: frames)
    var firstOutR = [Float](repeating: 0.0, count: frames)
    var firstSumSq: Double = 0.0
    for i in 0..<frames {
        let t = Float(i) / sampleRate
        let bass = 0.35 * sinf(2.0 * Float.pi * 90.0 * t)
        let vocal = 0.3 * sinf(2.0 * Float.pi * 1_200.0 * t)
        let air = 0.12 * sinf(2.0 * Float.pi * 7_000.0 * t)
        let x = bass + vocal + air
        let (l, r) = first.process(left: x, right: 0.9 * x)
        firstOutL[i] = l
        firstOutR[i] = r
        if i >= measureStart {
            firstSumSq += Double((l * l) + (r * r)) * 0.5
        }
    }

    var second = makeLeveler()
    var secondSumSq: Double = 0.0
    for i in 0..<frames {
        let (l, r) = second.process(left: firstOutL[i], right: firstOutR[i])
        if i >= measureStart {
            secondSumSq += Double((l * l) + (r * r)) * 0.5
        }
    }

    let n = Double(frames - measureStart)
    let firstRMS = sqrt(firstSumSq / n)
    let secondRMS = sqrt(secondSumSq / n)
    return Float(20.0 * log10(max(1e-9, secondRMS) / max(1e-9, firstRMS)))
}

/// A/B: classic DSB stereo encoding vs the SSB-leaning
/// encoder, on program scenarios plus tone-based sideband and
/// receiver-decode measurements. This is the HARD GATE for the SSB
/// asymmetry: it reports the composite-peak headroom actually reclaimed
/// AND fails to TIGHT when coherent decode separation degrades past
/// tolerance, so the trick can never ship a separation regression.
func runSSBStereoComparison(
    baseConfig: AppConfig,
    durationSeconds: Double
) -> Int32 {
    let compareDuration = max(2.0, min(durationSeconds, 6.0))
    var offConfig = baseConfig
    offConfig.ssbStereoEnabled = false
    var onConfig = offConfig
    onConfig.ssbStereoEnabled = true

    // Headroom-reclaim measurement needs a LINEAR composite: downstream
    // peak controllers flatten both variants to the same ceiling, hiding
    // exactly the effect being measured. The scenario table therefore runs
    // with clipper/limiter/soft-clip off; the tone table below runs the
    // full production chain for the safety metrics.
    var offLinear = offConfig
    offLinear.compositeClipperEnabled = false
    offLinear.limitMPX = false
    offLinear.audioCompositeSoftClipEnabled = false
    offLinear.audioCompositeSmootherEnabled = false
    offLinear.finalMPXSoftClipEnabled = false
    var onLinear = offLinear
    onLinear.ssbStereoEnabled = true

    print("SSB Stereo A/B (classic DSB stereo vs SSB-leaning encoder)")
    print("Toggle: mpx_ssb_stereo_enabled  (ssb_amount \(String(format: "%.2f", onConfig.ssbStereoAmount)))")
    print("Scope: program scenarios (LINEAR composite -- peak controllers off, so the")
    print("encoder's raw headroom effect is visible) + tone sidebands + coherent decode")
    print("on the full chain; production default remains toggle-off")
    print("")
    print("Scenario              PeakDelta  AudioPkDelta  CorrDelta  SideDelta  POvrOn")
    print("--------------------  ---------  ------------  ---------  ---------  ------")

    var warnings: [String] = []
    var totalReclaimDB: Float = 0.0
    var scenarioCount = 0

    for scenario in advancedDynamicsComparisonScenarios() {
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
            warnings.append("\(scenario.name): SSB path exceeded composite budget")
        }
        if abs(corrDelta) > 0.2 {
            warnings.append("\(scenario.name): output correlation changed by \(String(format: "%+.2f", corrDelta))")
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
    print("")
    print("Tone      AsymOff   AsymOn   SepOff    SepOn    SepDelta")
    print("--------  -------  -------  -------  -------  ---------")
    let toneDuration = max(3.0, compareDuration)
    var minSeparationOn: Float = 1_000.0
    for toneHz in [1_000.0, 10_000.0, 14_000.0] {
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
            warnings.append("\(Int(toneHz)) Hz: coherent separation dropped \(String(format: "%.1f", -sepDelta)) dB (> 6 dB)")
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

    let meanReclaimDB = scenarioCount > 0 ? totalReclaimDB / Float(scenarioCount) : 0.0
    print("")
    print("Mean audio-composite peak reclaim: \(String(format: "%.2f", meanReclaimDB)) dB")
    print("")
    print("Assessment")
    if minSeparationOn < 20.0 {
        warnings.append("coherent separation fell below 20 dB with SSB on (\(String(format: "%.1f", minSeparationOn)) dB)")
    }
    if meanReclaimDB < 0.05 {
        warnings.append("SSB path reclaimed no measurable composite headroom on the comparison scenarios")
    }
    if warnings.isEmpty {
        print("Result: OK - SSB leaning reclaimed headroom without a decode regression.")
        return 0
    }
    print("Comparison notes:")
    for warning in warnings {
        print("- \(warning)")
    }
    print("Result: TIGHT - SSB Stereo is implemented, but preset use needs review.")
    return 1
}
