import Accelerate
import Foundation

private struct StereoSignalMetrics {
    var rms: Float = 0.0
    var peak: Float = 0.0
    var correlation: Float = 0.0
    var sideToMidRatio: Float = 0.0
}

private struct MPXBandwidthMetrics {
    var occupied999Hz: Float = 0.0
    var above60kRatioDB: Float = -160.0
    var above67kRatioDB: Float = -160.0
}

private struct VerificationMetrics {
    var sampleCount: Int = 0
    var peakAbs: Float = 0.0
    var sumSquares: Double = 0.0
    var maxLimiterGRDB: Float = 0.0
    var maxSafetyGRDB: Float = 0.0
    var maxAudioCompositePeak: Float = 0.0
    var minBudgetMarginDB: Float = .greatestFiniteMagnitude
    var pilotPercent: Float = 0.0
    var rdsPercent: Float = 0.0
    var maxAGCReductionDB: Float = 0.0
    var detectorDBAtMaxReduction: Float = -120.0
    var inputSignal = StereoSignalMetrics()
    var outputSignal = StereoSignalMetrics()
    var bandwidth = MPXBandwidthMetrics()

    mutating func ingest(
        sample: Float,
        agc: MPXGenerator.AGCStatus,
        limiter: MPXGenerator.FinalLimiterStatus,
        calibration: MPXGenerator.CompositeCalibrationStatus
    ) {
        sampleCount += 1
        let absSample = fabsf(sample)
        peakAbs = max(peakAbs, absSample)
        sumSquares += Double(sample * sample)
        maxLimiterGRDB = max(maxLimiterGRDB, limiter.gainReductionDB)
        maxSafetyGRDB = max(maxSafetyGRDB, limiter.safetyGainReductionDB)
        maxAudioCompositePeak = max(maxAudioCompositePeak, calibration.audioPeak)
        minBudgetMarginDB = min(minBudgetMarginDB, calibration.budgetMarginDB)
        pilotPercent = calibration.pilotPercent
        rdsPercent = calibration.rdsPercent
        let reduction = max(0.0, -agc.gainDB)
        if reduction >= maxAGCReductionDB {
            maxAGCReductionDB = reduction
            detectorDBAtMaxReduction = agc.detectorDB
        }
    }

    var rms: Float {
        guard sampleCount > 0 else { return 0.0 }
        return Float(sqrt(sumSquares / Double(sampleCount)))
    }

    var rmsDeltaDB: Float {
        guard inputSignal.rms > 1e-9, outputSignal.rms > 1e-9 else { return 0.0 }
        return Float(20.0 * log10(Double(outputSignal.rms / inputSignal.rms)))
    }
}

private struct VerificationScenario {
    let name: String
    let description: String
    let quality: QualityExpectations
    let sample: (_ frameIndex: Int, _ sampleRate: Double) -> (Float, Float)
}

private struct QualityExpectations {
    let maxCorrelationDelta: Float?
    let maxOutputCorrelation: Float?
    let minSideRetention: Float?
    let maxAbsRMSDeltaDB: Float?
    let maxOccupied999Hz: Float?
    let maxAbove60kRatioDB: Float?
    let maxAbove67kRatioDB: Float?

    static let none = QualityExpectations(
        maxCorrelationDelta: nil,
        maxOutputCorrelation: nil,
        minSideRetention: nil,
        maxAbsRMSDeltaDB: nil,
        maxOccupied999Hz: nil,
        maxAbove60kRatioDB: nil,
        maxAbove67kRatioDB: nil
    )
}

private struct VerificationPresetSweep {
    let id: String
    let title: String
    let apply: (inout AppConfig) -> Void
}

private struct LongRunSignatureReference {
    let peakDBFS: Float
    let minMarginDB: Float
    let outCorrelation: Float
    let occ999Hz: Float
    let above60kRatioDB: Float
}

private struct DeterministicNoise {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1
        let upper = UInt32((state >> 32) & 0xFFFF_FFFF)
        let normalized = Float(upper) / Float(UInt32.max)
        return (normalized * 2.0) - 1.0
    }
}

private func verificationScenarios() -> [VerificationScenario] {
    var programNoiseL = DeterministicNoise(seed: 0x1234_5678_ABCD_EF01)
    var programNoiseR = DeterministicNoise(seed: 0x0FED_CBA9_8765_4321)
    var brightNoiseL = DeterministicNoise(seed: 0xCAFE_BABE_F00D_0001)
    var brightNoiseR = DeterministicNoise(seed: 0xCAFE_BABE_F00D_0002)
    var vocalNoiseL = DeterministicNoise(seed: 0x5150_CAFE_0000_0001)
    var vocalNoiseR = DeterministicNoise(seed: 0x5150_CAFE_0000_0002)
    var transientNoiseL = DeterministicNoise(seed: 0xA11C_E123_0000_0001)
    var transientNoiseR = DeterministicNoise(seed: 0xA11C_E123_0000_0002)
    var bassStressL = DeterministicNoise(seed: 0x0BAD_F00D_1000_0001)
    var bassStressR = DeterministicNoise(seed: 0x0BAD_F00D_1000_0002)

    return [
        VerificationScenario(
            name: "mono_1khz",
            description: "Mono 1 kHz sine at moderate level",
            quality: QualityExpectations(
                maxCorrelationDelta: 0.05,
                maxOutputCorrelation: 1.0,
                minSideRetention: nil,
                maxAbsRMSDeltaDB: 6.0,
                maxOccupied999Hz: nil,
                maxAbove60kRatioDB: nil,
                maxAbove67kRatioDB: nil
            )
        ) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            let tone = Float(sin(2.0 * Double.pi * 1000.0 * t)) * 0.55
            return (tone, tone)
        },
        VerificationScenario(
            name: "stereo_diff_400hz",
            description: "Out-of-phase stereo stress tone",
            quality: QualityExpectations(
                maxCorrelationDelta: 0.08,
                maxOutputCorrelation: nil,
                minSideRetention: nil,
                maxAbsRMSDeltaDB: 30.0,
                maxOccupied999Hz: nil,
                maxAbove60kRatioDB: nil,
                maxAbove67kRatioDB: nil
            )
        ) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            let tone = Float(sin(2.0 * Double.pi * 400.0 * t)) * 0.50
            return (tone, -tone)
        },
        VerificationScenario(
            name: "program_mix",
            description: "Deterministic multitone and noise program-like mix",
            quality: QualityExpectations(
                maxCorrelationDelta: 0.12,
                maxOutputCorrelation: 0.92,
                minSideRetention: 0.75,
                maxAbsRMSDeltaDB: 2.5,
                maxOccupied999Hz: 58_500.0,
                maxAbove60kRatioDB: -50.0,
                maxAbove67kRatioDB: -60.0
            )
        ) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            let envelope =
                0.42
                + (0.18 * (0.5 + 0.5 * sin(2.0 * Double.pi * 0.37 * t)))
                + (0.08 * (0.5 + 0.5 * sin(2.0 * Double.pi * 0.071 * t)))

            let bass = sin(2.0 * Double.pi * 55.0 * t)
            let lowMid = sin(2.0 * Double.pi * 220.0 * t)
            let mid = sin(2.0 * Double.pi * 880.0 * t)
            let high = sin(2.0 * Double.pi * 3200.0 * t)

            let left =
                Float(envelope)
                * Float((0.42 * bass) + (0.24 * lowMid) + (0.16 * mid) + (0.08 * high))
                + (programNoiseL.next() * 0.025)
            let right =
                Float(envelope)
                * Float((0.39 * bass) + (0.21 * lowMid) - (0.12 * mid) + (0.10 * high))
                + (programNoiseR.next() * 0.025)

            return (left, right)
        },
        VerificationScenario(
            name: "bright_dense",
            description: "Bright dense program to stress multiband and HF behavior",
            quality: QualityExpectations(
                maxCorrelationDelta: 0.45,
                maxOutputCorrelation: 0.55,
                minSideRetention: 0.55,
                maxAbsRMSDeltaDB: 3.0,
                maxOccupied999Hz: 56_100.0,
                maxAbove60kRatioDB: -40.0,
                maxAbove67kRatioDB: -44.0
            )
        ) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            let slowEnv = 0.55 + (0.20 * sin(2.0 * Double.pi * 0.43 * t))
            let fastEnv = 0.20 + (0.18 * max(0.0, sin(2.0 * Double.pi * 3.6 * t)))
            let envelope = max(0.20, slowEnv + fastEnv)

            let lowMid = sin(2.0 * Double.pi * 280.0 * t)
            let presence = sin(2.0 * Double.pi * 2500.0 * t)
            let brilliance = sin(2.0 * Double.pi * 6200.0 * t)
            let air = sin(2.0 * Double.pi * 9800.0 * t)

            let left =
                Float(envelope)
                * Float((0.18 * lowMid) + (0.26 * presence) + (0.22 * brilliance) + (0.14 * air))
                + (brightNoiseL.next() * 0.050)
            let right =
                Float(envelope)
                * Float((0.16 * lowMid) - (0.22 * presence) + (0.24 * brilliance) - (0.12 * air))
                + (brightNoiseR.next() * 0.050)

            return (left, right)
        },
        VerificationScenario(
            name: "vocal_sibilant",
            description: "Vocal-forward and sibilance-heavy material stress",
            quality: QualityExpectations(
                maxCorrelationDelta: 0.20,
                maxOutputCorrelation: 0.92,
                minSideRetention: 0.68,
                maxAbsRMSDeltaDB: 2.5,
                maxOccupied999Hz: 58_500.0,
                maxAbove60kRatioDB: -41.0,
                maxAbove67kRatioDB: -52.0
            )
        ) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            let phraseEnv =
                0.42
                + (0.16 * (0.5 + 0.5 * sin(2.0 * Double.pi * 0.61 * t)))
                + (0.12 * max(0.0, sin(2.0 * Double.pi * 2.8 * t)))

            let chest = sin(2.0 * Double.pi * 180.0 * t)
            let vocalBody = sin(2.0 * Double.pi * 730.0 * t)
            let presence = sin(2.0 * Double.pi * 2800.0 * t)
            let sibilance = sin(2.0 * Double.pi * 6800.0 * t)
            let air = sin(2.0 * Double.pi * 11_500.0 * t)

            let sibilantBurst = max(0.0, sin(2.0 * Double.pi * 4.2 * t))
            let burstGain = 0.06 + (0.10 * sibilantBurst)

            let left =
                Float(phraseEnv)
                * Float((0.16 * chest) + (0.28 * vocalBody) + (0.16 * presence) + (0.07 * sibilance) + (0.03 * air))
                + (vocalNoiseL.next() * Float(burstGain))
            let right =
                Float(phraseEnv)
                * Float((0.14 * chest) + (0.27 * vocalBody) - (0.13 * presence) + (0.09 * sibilance) - (0.02 * air))
                + (vocalNoiseR.next() * Float(burstGain))

            return (left, right)
        },
        VerificationScenario(
            name: "hf_edge_12k",
            description: "High-frequency edge stress near the program low-pass limit",
            quality: QualityExpectations(
                maxCorrelationDelta: 0.12,
                maxOutputCorrelation: 0.98,
                minSideRetention: 0.80,
                maxAbsRMSDeltaDB: 2.0,
                maxOccupied999Hz: 58_500.0,
                maxAbove60kRatioDB: -46.0,
                maxAbove67kRatioDB: -58.0
            )
        ) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            let envelope = 0.42 + (0.18 * (0.5 + 0.5 * sin(2.0 * Double.pi * 0.9 * t)))
            let left = Float(envelope) * Float(
                (0.34 * sin(2.0 * Double.pi * 12_200.0 * t))
                    + (0.10 * sin(2.0 * Double.pi * 9_800.0 * t))
            )
            let right = Float(envelope) * Float(
                (0.28 * sin(2.0 * Double.pi * 12_800.0 * t))
                    - (0.12 * sin(2.0 * Double.pi * 10_400.0 * t))
            )
            return (left, right)
        },
        VerificationScenario(
            name: "transient_push",
            description: "Transient-heavy program to stress AGC, Orbass hold, and limiter feel",
            quality: QualityExpectations(
                maxCorrelationDelta: 0.15,
                maxOutputCorrelation: 0.88,
                minSideRetention: 0.70,
                maxAbsRMSDeltaDB: 3.0,
                maxOccupied999Hz: 58_500.0,
                maxAbove60kRatioDB: -45.0,
                maxAbove67kRatioDB: -53.0
            )
        ) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            let beat = fmod(t, 0.125)
            let attack = exp(-beat * 42.0)
            let accent = beat < 0.018 ? attack : 0.0
            let body = 0.30 + (0.22 * max(0.0, sin(2.0 * Double.pi * 2.0 * t)))

            let kick = sin(2.0 * Double.pi * 62.0 * t)
            let snareBody = sin(2.0 * Double.pi * 190.0 * t)
            let crack = sin(2.0 * Double.pi * 3100.0 * t)

            let left =
                Float((0.42 * body * kick) + (0.18 * body * snareBody) + (0.34 * accent * crack))
                + (transientNoiseL.next() * Float(0.018 + (0.08 * accent)))
            let right =
                Float((0.40 * body * kick) - (0.16 * body * snareBody) + (0.30 * accent * crack))
                + (transientNoiseR.next() * Float(0.018 + (0.08 * accent)))

            return (left, right)
        },
        VerificationScenario(
            name: "wide_bass",
            description: "Wide low-end stereo stress for mono bass and image protection",
            quality: QualityExpectations(
                maxCorrelationDelta: nil,
                maxOutputCorrelation: 0.60,
                minSideRetention: 0.30,
                maxAbsRMSDeltaDB: 2.5,
                maxOccupied999Hz: 58_500.0,
                maxAbove60kRatioDB: -50.0,
                maxAbove67kRatioDB: -60.0
            )
        ) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            let swell = 0.45 + (0.22 * (0.5 + 0.5 * sin(2.0 * Double.pi * 0.27 * t)))
            let lowWide = sin(2.0 * Double.pi * 72.0 * t)
            let upperBass = sin(2.0 * Double.pi * 118.0 * t)
            let vocalMid = sin(2.0 * Double.pi * 920.0 * t)
            let sparkle = sin(2.0 * Double.pi * 4200.0 * t)

            let left =
                Float(swell)
                * Float((0.34 * lowWide) + (0.20 * upperBass) + (0.15 * vocalMid) + (0.06 * sparkle))
                + (bassStressL.next() * 0.018)
            let right =
                Float(swell)
                * Float((-0.34 * lowWide) + (0.18 * upperBass) - (0.11 * vocalMid) + (0.08 * sparkle))
                + (bassStressR.next() * 0.018)

            return (left, right)
        },
        VerificationScenario(
            name: "hard_panned_hf",
            description:
                "Hard-panned 10 kHz tone — informational baseline for HF side retention",
            quality: QualityExpectations(
                // Informational scenario: full-chain pure-side content
                // collides with AGC gating and multiband behaviour at HF.
                // Baseline tracking catches regressions in this corner;
                // unit tests cover the composite clipper itself directly.
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
            let tone = Float(sin(2.0 * Double.pi * 10_000.0 * t)) * 0.85
            return (tone, -tone)
        },
    ]
}

private func longRunVerificationScenarios() -> [VerificationScenario] {
    verificationScenarios().filter {
        ["program_mix", "bright_dense", "vocal_sibilant", "transient_push", "wide_bass"]
            .contains($0.name)
    }
}

private func longRunSignatureReferences() -> [String: LongRunSignatureReference] {
    [
        "program_mix": LongRunSignatureReference(
            peakDBFS: -1.63,
            minMarginDB: 1.2,
            outCorrelation: 0.88,
            occ999Hz: 57_921.0,
            above60kRatioDB: -84.3
        ),
        "bright_dense": LongRunSignatureReference(
            peakDBFS: -0.33,
            minMarginDB: 0.2,
            outCorrelation: 0.27,
            occ999Hz: 56_191.0,
            above60kRatioDB: -42.9
        ),
        "vocal_sibilant": LongRunSignatureReference(
            peakDBFS: -0.46,
            minMarginDB: 0.3,
            outCorrelation: 0.75,
            occ999Hz: 57_810.0,
            above60kRatioDB: -67.8
        ),
        "transient_push": LongRunSignatureReference(
            peakDBFS: -0.27,
            minMarginDB: 0.3,
            outCorrelation: 0.83,
            occ999Hz: 58_062.0,
            above60kRatioDB: -62.3
        ),
        "wide_bass": LongRunSignatureReference(
            peakDBFS: -3.58,
            minMarginDB: 3.3,
            outCorrelation: -0.22,
            occ999Hz: 58_112.0,
            above60kRatioDB: -83.6
        ),
    ]
}

private func verifyScenario(
    config: AppConfig,
    durationSeconds: Double,
    scenario: VerificationScenario
) -> VerificationMetrics {
    let sampleRate = max(8_000.0, config.sampleRate)
    let frames = max(1, Int((durationSeconds * sampleRate).rounded()))
    var metrics = VerificationMetrics()
    var inputLeft = [Float](repeating: 0.0, count: frames)
    var inputRight = [Float](repeating: 0.0, count: frames)

    for frame in 0..<frames {
        let source = scenario.sample(frame, sampleRate)
        inputLeft[frame] = source.0
        inputRight[frame] = source.1
    }

    var monitorLeft = inputLeft
    var monitorRight = inputRight
    var mpxLeft = [Float](repeating: 0.0, count: frames)
    var mpxRight = [Float](repeating: 0.0, count: frames)
    var mpxSamples = [Float](repeating: 0.0, count: frames)
    let monitorGenerator = MPXGenerator(config: config, sampleRate: sampleRate)

    monitorLeft.withUnsafeMutableBufferPointer { monL in
        monitorRight.withUnsafeMutableBufferPointer { monR in
            mpxLeft.withUnsafeMutableBufferPointer { mpxL in
                mpxRight.withUnsafeMutableBufferPointer { mpxR in
                    guard let monLBase = monL.baseAddress,
                        let monRBase = monR.baseAddress,
                        let mpxLBase = mpxL.baseAddress,
                        let mpxRBase = mpxR.baseAddress
                    else { return }
                    monitorGenerator.renderFromInputAndMonitorInPlace(
                        frameCount: frames,
                        left: monLBase,
                        right: monRBase,
                        mpxLeft: mpxLBase,
                        mpxRight: mpxRBase
                    )
                }
            }
        }
    }

    metrics.inputSignal = computeStereoSignalMetrics(left: inputLeft, right: inputRight)
    metrics.outputSignal = computeStereoSignalMetrics(left: monitorLeft, right: monitorRight)

    let generator = MPXGenerator(config: config, sampleRate: sampleRate)

    for frame in 0..<frames {
        let mpx = generator.renderSingleSample(leftIn: inputLeft[frame], rightIn: inputRight[frame])
        mpxSamples[frame] = mpx
        metrics.ingest(
            sample: mpx,
            agc: generator.agcStatus,
            limiter: generator.finalLimiterStatus,
            calibration: generator.compositeCalibrationStatus
        )
    }
    metrics.bandwidth = computeMPXBandwidthMetrics(samples: mpxSamples, sampleRate: sampleRate)

    return metrics
}

private func dbfsString(_ linear: Float) -> String {
    guard linear > 1e-9 else { return "-inf" }
    return String(format: "%.2f", 20.0 * log10(Double(linear)))
}

private func deviationString(peakAbs: Float, targetDeviationKHz: Double) -> String {
    String(format: "%.1f", Double(peakAbs) * max(1.0, targetDeviationKHz))
}

private func padded(_ text: String, width: Int) -> String {
    if text.count >= width {
        return String(text.prefix(width))
    }
    return text + String(repeating: " ", count: width - text.count)
}

private func leftPadded(_ text: String, width: Int) -> String {
    if text.count >= width {
        return String(text.suffix(width))
    }
    return String(repeating: " ", count: width - text.count) + text
}

private func nonNegative(_ value: Float) -> Float {
    if value <= 0.0005 {
        return 0.0
    }
    return value
}

private func ratioString(_ value: Float, width: Int) -> String {
    guard value.isFinite else { return leftPadded("inf", width: width) }
    if value >= 99.95 {
        return leftPadded("99+", width: width)
    }
    return leftPadded(String(format: "%.2f", value), width: width)
}

private func buildBaselineRecord(
    metrics: VerificationMetrics,
    targetDeviationKHz: Double
) -> VerifierBaselineRecord {
    let peakDB = metrics.peakAbs > 1e-9
        ? Float(20.0 * log10(Double(metrics.peakAbs)))
        : -160.0
    let audioPeakDB = metrics.maxAudioCompositePeak > 1e-9
        ? Float(20.0 * log10(Double(metrics.maxAudioCompositePeak)))
        : -160.0
    return VerifierBaselineRecord(
        peakDBFS: peakDB,
        deviationKHz: Float(Double(metrics.peakAbs) * max(1.0, targetDeviationKHz)),
        limiterGRDB: nonNegative(metrics.maxLimiterGRDB),
        safetyGRDB: nonNegative(metrics.maxSafetyGRDB),
        audioCompositePeakDBFS: audioPeakDB,
        pilotPercent: metrics.pilotPercent,
        rdsPercent: metrics.rdsPercent,
        budgetMarginDB: metrics.minBudgetMarginDB,
        agcReductionDB: metrics.maxAGCReductionDB,
        inputCorrelation: metrics.inputSignal.correlation,
        outputCorrelation: metrics.outputSignal.correlation,
        inputSideToMid: metrics.inputSignal.sideToMidRatio,
        outputSideToMid: metrics.outputSignal.sideToMidRatio,
        rmsDeltaDB: metrics.rmsDeltaDB,
        occupied999Hz: metrics.bandwidth.occupied999Hz,
        above60kRatioDB: metrics.bandwidth.above60kRatioDB,
        above67kRatioDB: metrics.bandwidth.above67kRatioDB
    )
}

private func computeStereoSignalMetrics(
    left: [Float],
    right: [Float]
) -> StereoSignalMetrics {
    let frameCount = min(left.count, right.count)
    guard frameCount > 0 else { return StereoSignalMetrics() }

    var sumL: Double = 0.0
    var sumR: Double = 0.0
    var dotLR: Double = 0.0
    var midEnergy: Double = 0.0
    var sideEnergy: Double = 0.0
    var peak: Float = 0.0

    for i in 0..<frameCount {
        let l = left[i]
        let r = right[i]
        peak = max(peak, max(fabsf(l), fabsf(r)))

        let ld = Double(l)
        let rd = Double(r)
        sumL += ld * ld
        sumR += rd * rd
        dotLR += ld * rd

        let mid = 0.5 * (ld + rd)
        let side = 0.5 * (ld - rd)
        midEnergy += mid * mid
        sideEnergy += side * side
    }

    let rmsL = sqrt(sumL / Double(frameCount))
    let rmsR = sqrt(sumR / Double(frameCount))
    let rms = Float(sqrt((rmsL * rmsL + rmsR * rmsR) * 0.5))
    let correlation = Float(dotLR / max(1e-12, sqrt(sumL * sumR)))
    let sideToMidRatio = Float(sqrt(sideEnergy / max(1e-12, midEnergy)))

    return StereoSignalMetrics(
        rms: rms,
        peak: peak,
        correlation: correlation.isFinite ? correlation : 0.0,
        sideToMidRatio: sideToMidRatio.isFinite ? sideToMidRatio : 0.0
    )
}

private func computeMPXBandwidthMetrics(
    samples: [Float],
    sampleRate: Double
) -> MPXBandwidthMetrics {
    let maxFFTSize = min(samples.count, 131_072)
    let log2n = Int(floor(log2(Double(maxFFTSize))))
    let fftSize = 1 << max(10, log2n)
    guard fftSize >= 1024, fftSize <= samples.count else {
        return MPXBandwidthMetrics()
    }

    var window = [Float](repeating: 0.0, count: fftSize)
    vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

    let signal = Array(samples.prefix(fftSize))
    var windowed = [Float](repeating: 0.0, count: fftSize)
    vDSP_vmul(signal, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

    let halfSize = fftSize / 2
    var real = [Float](repeating: 0.0, count: halfSize)
    var imag = [Float](repeating: 0.0, count: halfSize)

    real.withUnsafeMutableBufferPointer { realPtr in
        imag.withUnsafeMutableBufferPointer { imagPtr in
            guard let realBase = realPtr.baseAddress,
                let imagBase = imagPtr.baseAddress
            else { return }
            var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
            windowed.withUnsafeBufferPointer { windowedPtr in
                guard let windowedBase = windowedPtr.baseAddress else { return }
                windowedBase.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexPtr in
                    vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfSize))
                }
            }
            guard let fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Double(fftSize))), FFTRadix(kFFTRadix2))
            else { return }
            vDSP_fft_zrip(
                fftSetup,
                &split,
                1,
                vDSP_Length(log2(Double(fftSize))),
                FFTDirection(FFT_FORWARD)
            )
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    var mags = [Float](repeating: 0.0, count: halfSize)
    mags.withUnsafeMutableBufferPointer { magsPtr in
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                guard let magsBase = magsPtr.baseAddress,
                    let realBase = realPtr.baseAddress,
                    let imagBase = imagPtr.baseAddress
                else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                vDSP_zvmags(&split, 1, magsBase, 1, vDSP_Length(halfSize))
            }
        }
    }

    let binHz = Float(sampleRate) / Float(fftSize)
    var totalPower: Double = 0.0
    var inBandPower: Double = 0.0
    var above60Power: Double = 0.0
    var above67Power: Double = 0.0
    var cumulativePower: Double = 0.0
    var occupied999Hz: Float = 0.0

    for bin in 1..<halfSize {
        let freq = Float(bin) * binHz
        let power = Double(mags[bin])
        totalPower += power
        if freq <= 60_000.0 {
            inBandPower += power
        } else {
            above60Power += power
        }
        if freq > 67_000.0 {
            above67Power += power
        }
    }

    let targetPower = totalPower * 0.999
    if targetPower > 0.0 {
        for bin in 1..<halfSize {
            cumulativePower += Double(mags[bin])
            if cumulativePower >= targetPower {
                occupied999Hz = Float(bin) * binHz
                break
            }
        }
    }

    func ratioDB(_ num: Double, _ den: Double) -> Float {
        guard num > 1e-18, den > 1e-18 else { return -160.0 }
        return Float(10.0 * log10(num / den))
    }

    return MPXBandwidthMetrics(
        occupied999Hz: occupied999Hz,
        above60kRatioDB: ratioDB(above60Power, inBandPower),
        above67kRatioDB: ratioDB(above67Power, inBandPower)
    )
}

private func qualityFindings(
    scenario: VerificationScenario,
    metrics: VerificationMetrics,
    expectationsOverride: QualityExpectations? = nil
) -> [String] {
    let tolerance: Float = 0.005
    var findings: [String] = []
    let expectations = expectationsOverride ?? scenario.quality

    if let maxCorrelationDelta = expectations.maxCorrelationDelta {
        let delta = fabsf(metrics.outputSignal.correlation - metrics.inputSignal.correlation)
        if delta > (maxCorrelationDelta + tolerance) {
            findings.append(
                "corr delta \(String(format: "%.2f", delta)) > \(String(format: "%.2f", maxCorrelationDelta))"
            )
        }
    }

    if let maxOutputCorrelation = expectations.maxOutputCorrelation {
        let outputCorrelation = fabsf(metrics.outputSignal.correlation)
        if outputCorrelation > (maxOutputCorrelation + tolerance) {
            findings.append(
                "out corr \(String(format: "%.2f", outputCorrelation)) > \(String(format: "%.2f", maxOutputCorrelation))"
            )
        }
    }

    if let minSideRetention = expectations.minSideRetention,
        metrics.inputSignal.sideToMidRatio > 0.05
    {
        let retention = metrics.outputSignal.sideToMidRatio / max(0.001, metrics.inputSignal.sideToMidRatio)
        if retention < (minSideRetention - tolerance) {
            findings.append(
                "side retention \(String(format: "%.2f", retention)) < \(String(format: "%.2f", minSideRetention))"
            )
        }
    }

    if let maxAbsRMSDeltaDB = expectations.maxAbsRMSDeltaDB {
        let delta = fabsf(metrics.rmsDeltaDB)
        if delta > (maxAbsRMSDeltaDB + tolerance) {
            findings.append(
                "rms drift \(String(format: "%.1f", delta)) dB > \(String(format: "%.1f", maxAbsRMSDeltaDB)) dB"
            )
        }
    }

    if let maxOccupied999Hz = expectations.maxOccupied999Hz {
        let occupied = metrics.bandwidth.occupied999Hz
        if occupied > (maxOccupied999Hz + 150.0) {
            findings.append(
                "occ999 \(String(format: "%.0f", occupied)) Hz > \(String(format: "%.0f", maxOccupied999Hz)) Hz"
            )
        }
    }

    if let maxAbove60kRatioDB = expectations.maxAbove60kRatioDB {
        let ratio = metrics.bandwidth.above60kRatioDB
        if ratio > (maxAbove60kRatioDB + 0.75) {
            findings.append(
                ">60k/in \(String(format: "%.1f", ratio)) dB > \(String(format: "%.1f", maxAbove60kRatioDB)) dB"
            )
        }
    }

    if let maxAbove67kRatioDB = expectations.maxAbove67kRatioDB {
        let ratio = metrics.bandwidth.above67kRatioDB
        if ratio > (maxAbove67kRatioDB + 0.75) {
            findings.append(
                ">67k/in \(String(format: "%.1f", ratio)) dB > \(String(format: "%.1f", maxAbove67kRatioDB)) dB"
            )
        }
    }

    return findings
}

private func longRunSignatureFindings(
    scenario: VerificationScenario,
    metrics: VerificationMetrics,
    reference: LongRunSignatureReference
) -> [String] {
    var findings: [String] = []
    let peakDBFS = metrics.peakAbs > 1e-9 ? Float(20.0 * log10(Double(metrics.peakAbs))) : -160.0
    if peakDBFS > (reference.peakDBFS + 0.6) {
        findings.append(
            "peak \(String(format: "%.2f", peakDBFS)) dBFS > \(String(format: "%.2f", reference.peakDBFS + 0.6)) dBFS"
        )
    }
    if metrics.minBudgetMarginDB < (reference.minMarginDB - 0.35) {
        findings.append(
            "margin \(String(format: "%.1f", metrics.minBudgetMarginDB)) dB < \(String(format: "%.1f", reference.minMarginDB - 0.35)) dB"
        )
    }
    if fabsf(metrics.outputSignal.correlation - reference.outCorrelation) > 0.08 {
        findings.append(
            "out corr drift \(String(format: "%.2f", metrics.outputSignal.correlation)) vs \(String(format: "%.2f", reference.outCorrelation))"
        )
    }
    if metrics.bandwidth.occupied999Hz > (reference.occ999Hz + 200.0) {
        findings.append(
            "occ999 \(String(format: "%.0f", metrics.bandwidth.occupied999Hz)) Hz > \(String(format: "%.0f", reference.occ999Hz + 200.0)) Hz"
        )
    }
    if metrics.bandwidth.above60kRatioDB > (reference.above60kRatioDB + 1.5) {
        findings.append(
            ">60k/in \(String(format: "%.1f", metrics.bandwidth.above60kRatioDB)) dB > \(String(format: "%.1f", reference.above60kRatioDB + 1.5)) dB"
        )
    }
    _ = scenario
    return findings
}

private func keyMultibandPresetSweeps() -> [VerificationPresetSweep] {
    [
        VerificationPresetSweep(id: "5_ac", title: "5B AC/Pop") { config in
            config.multibandEnabled = true
            config.multibandMode = 5
            config.multibandPresetID = "5_ac"
            config.multibandIntensity = "normal"
            config.multibandX1Hz = 90.0
            config.multibandX2Hz = 350.0
            config.multibandX3Hz = 1800.0
            config.multibandX4Hz = 6800.0
            config.multibandLowThresholdDB = -17.5
            config.multibandMidThresholdDB = -16.0
            config.multibandHighThresholdDB = -14.5
            config.multibandLowRatio = 1.75
            config.multibandMidRatio = 1.55
            config.multibandHighRatio = 1.28
            config.multibandLowAttackMS = 28.0
            config.multibandMidAttackMS = 19.0
            config.multibandHighAttackMS = 13.0
            config.multibandLowReleaseMS = 375.0
            config.multibandMidReleaseMS = 300.0
            config.multibandHighReleaseMS = 225.0
            config.multibandKneeDB = 3.6
            config.multibandLinkStrength = 0.52
            config.multibandReleaseProgramDependent = true
        },
        VerificationPresetSweep(id: "5_chr", title: "5B CHR/EDM") { config in
            config.multibandEnabled = true
            config.multibandMode = 5
            config.multibandPresetID = "5_chr"
            config.multibandIntensity = "normal"
            config.multibandX1Hz = 90.0
            config.multibandX2Hz = 320.0
            config.multibandX3Hz = 1600.0
            config.multibandX4Hz = 6200.0
            config.multibandLowThresholdDB = -23.0
            config.multibandMidThresholdDB = -21.0
            config.multibandHighThresholdDB = -19.0
            config.multibandLowRatio = 2.25
            config.multibandMidRatio = 1.9
            config.multibandHighRatio = 1.6
            config.multibandLowAttackMS = 20.0
            config.multibandMidAttackMS = 13.0
            config.multibandHighAttackMS = 8.0
            config.multibandLowReleaseMS = 320.0
            config.multibandMidReleaseMS = 240.0
            config.multibandHighReleaseMS = 180.0
            config.multibandKneeDB = 2.6
            config.multibandLinkStrength = 0.48
            config.multibandReleaseProgramDependent = true
        },
        VerificationPresetSweep(id: "5_rock", title: "5B Rock") { config in
            config.multibandEnabled = true
            config.multibandMode = 5
            config.multibandPresetID = "5_rock"
            config.multibandIntensity = "normal"
            config.multibandX1Hz = 90.0
            config.multibandX2Hz = 340.0
            config.multibandX3Hz = 1550.0
            config.multibandX4Hz = 6100.0
            config.multibandLowThresholdDB = -21.0
            config.multibandMidThresholdDB = -19.0
            config.multibandHighThresholdDB = -18.0
            config.multibandLowRatio = 2.1
            config.multibandMidRatio = 1.85
            config.multibandHighRatio = 1.55
            config.multibandLowAttackMS = 20.0
            config.multibandMidAttackMS = 13.0
            config.multibandHighAttackMS = 8.0
            config.multibandLowReleaseMS = 320.0
            config.multibandMidReleaseMS = 240.0
            config.multibandHighReleaseMS = 175.0
            config.multibandKneeDB = 2.5
            config.multibandLinkStrength = 0.46
            config.multibandReleaseProgramDependent = true
        },
        VerificationPresetSweep(id: "5_talk", title: "5B Talk") { config in
            config.multibandEnabled = true
            config.multibandMode = 5
            config.multibandPresetID = "5_talk"
            config.multibandIntensity = "normal"
            config.multibandX1Hz = 110.0
            config.multibandX2Hz = 420.0
            config.multibandX3Hz = 2200.0
            config.multibandX4Hz = 7600.0
            config.multibandLowThresholdDB = -12.5
            config.multibandMidThresholdDB = -11.8
            config.multibandHighThresholdDB = -11.2
            config.multibandLowRatio = 1.24
            config.multibandMidRatio = 1.18
            config.multibandHighRatio = 1.08
            config.multibandLowAttackMS = 48.0
            config.multibandMidAttackMS = 40.0
            config.multibandHighAttackMS = 30.0
            config.multibandLowReleaseMS = 560.0
            config.multibandMidReleaseMS = 450.0
            config.multibandHighReleaseMS = 360.0
            config.multibandKneeDB = 5.2
            config.multibandLinkStrength = 0.46
            config.multibandReleaseProgramDependent = true
        },
        VerificationPresetSweep(id: "5_news", title: "5B News") { config in
            config.multibandEnabled = true
            config.multibandMode = 5
            config.multibandPresetID = "5_news"
            config.multibandIntensity = "normal"
            config.multibandX1Hz = 110.0
            config.multibandX2Hz = 450.0
            config.multibandX3Hz = 2100.0
            config.multibandX4Hz = 7600.0
            config.multibandLowThresholdDB = -15.0
            config.multibandMidThresholdDB = -14.0
            config.multibandHighThresholdDB = -13.0
            config.multibandLowRatio = 1.4
            config.multibandMidRatio = 1.35
            config.multibandHighRatio = 1.25
            config.multibandLowAttackMS = 40.0
            config.multibandMidAttackMS = 34.0
            config.multibandHighAttackMS = 24.0
            config.multibandLowReleaseMS = 500.0
            config.multibandMidReleaseMS = 400.0
            config.multibandHighReleaseMS = 320.0
            config.multibandKneeDB = 4.3
            config.multibandLinkStrength = 0.64
            config.multibandReleaseProgramDependent = true
        },
        VerificationPresetSweep(id: "5_urban", title: "5B Urban") { config in
            config.multibandEnabled = true
            config.multibandMode = 5
            config.multibandPresetID = "5_urban"
            config.multibandIntensity = "normal"
            config.multibandX1Hz = 85.0
            config.multibandX2Hz = 300.0
            config.multibandX3Hz = 1300.0
            config.multibandX4Hz = 5400.0
            config.multibandLowThresholdDB = -23.0
            config.multibandMidThresholdDB = -21.0
            config.multibandHighThresholdDB = -19.0
            config.multibandLowRatio = 2.3
            config.multibandMidRatio = 2.0
            config.multibandHighRatio = 1.7
            config.multibandLowAttackMS = 18.0
            config.multibandMidAttackMS = 12.0
            config.multibandHighAttackMS = 7.0
            config.multibandLowReleaseMS = 295.0
            config.multibandMidReleaseMS = 220.0
            config.multibandHighReleaseMS = 155.0
            config.multibandKneeDB = 2.2
            config.multibandLinkStrength = 0.42
            config.multibandReleaseProgramDependent = true
        },
        VerificationPresetSweep(id: "5_dance", title: "5B Dance") { config in
            config.multibandEnabled = true
            config.multibandMode = 5
            config.multibandPresetID = "5_dance"
            config.multibandIntensity = "normal"
            config.multibandX1Hz = 80.0
            config.multibandX2Hz = 290.0
            config.multibandX3Hz = 1200.0
            config.multibandX4Hz = 5000.0
            config.multibandLowThresholdDB = -24.0
            config.multibandMidThresholdDB = -22.0
            config.multibandHighThresholdDB = -20.0
            config.multibandLowRatio = 2.5
            config.multibandMidRatio = 2.1
            config.multibandHighRatio = 1.75
            config.multibandLowAttackMS = 16.0
            config.multibandMidAttackMS = 11.0
            config.multibandHighAttackMS = 6.0
            config.multibandLowReleaseMS = 285.0
            config.multibandMidReleaseMS = 215.0
            config.multibandHighReleaseMS = 150.0
            config.multibandKneeDB = 2.0
            config.multibandLinkStrength = 0.40
            config.multibandReleaseProgramDependent = true
        },
    ]
}

private func presetQualityOverride(
    for sweep: VerificationPresetSweep,
    scenario: VerificationScenario
) -> QualityExpectations? {
    guard sweep.id == "5_talk" || sweep.id == "5_news" else { return nil }
    switch scenario.name {
    case "vocal_sibilant":
        return QualityExpectations(
            maxCorrelationDelta: 0.24,
            maxOutputCorrelation: 0.95,
            minSideRetention: 0.60,
            maxAbsRMSDeltaDB: 3.2,
            maxOccupied999Hz: 58_500.0,
            maxAbove60kRatioDB: -40.0,
            maxAbove67kRatioDB: -50.0
        )
    case "transient_push":
        return QualityExpectations(
            maxCorrelationDelta: 0.18,
            maxOutputCorrelation: 0.92,
            minSideRetention: 0.68,
            maxAbsRMSDeltaDB: 3.4,
            maxOccupied999Hz: 58_500.0,
            maxAbove60kRatioDB: -44.0,
            maxAbove67kRatioDB: -52.0
        )
    default:
        return nil
    }
}

private func runPresetSweepVerification(
    baseConfig: AppConfig,
    durationSeconds: Double
) -> Int32 {
    let sweepDuration = min(durationSeconds, 1.0)
    let scenarios = verificationScenarios().filter {
        ["bright_dense", "vocal_sibilant", "transient_push"].contains($0.name)
    }
    let sweeps = keyMultibandPresetSweeps()
    var worstExit: Int32 = 0

    print("Preset Sweep")
    print("Count: \(sweeps.count)")
    print("Preset                Peak dBFS  Margin  Result")
    print("--------------------  ---------  ------  ------")

    for sweep in sweeps {
        var config = baseConfig
        sweep.apply(&config)

        var presetWorstPeak: Float = 0.0
        var presetWorstMargin: Float = .greatestFiniteMagnitude
        var presetWarnings: [String] = []

        for scenario in scenarios {
            let metrics = verifyScenario(
                config: config,
                durationSeconds: sweepDuration,
                scenario: scenario
            )
            let expectationsOverride = presetQualityOverride(for: sweep, scenario: scenario)
            presetWorstPeak = max(presetWorstPeak, metrics.peakAbs)
            presetWorstMargin = min(presetWorstMargin, metrics.minBudgetMarginDB)
            presetWarnings.append(
                contentsOf: qualityFindings(
                    scenario: scenario,
                    metrics: metrics,
                    expectationsOverride: expectationsOverride
                ).map {
                    "\(scenario.name): \($0)"
                }
            )
        }

        let resultText: String
        let exitCode: Int32
        if presetWorstMargin < -0.25 {
            resultText = "WARN"
            exitCode = 2
        } else if !presetWarnings.isEmpty || presetWorstMargin < 0.0 {
            resultText = "TIGHT"
            exitCode = 1
        } else {
            resultText = "OK"
            exitCode = 0
        }
        worstExit = max(worstExit, exitCode)

        print(
            "\(padded(sweep.title, width: 20))  "
                + "\(leftPadded(dbfsString(presetWorstPeak), width: 9))"
                + "  \(String(format: "%6.1f", presetWorstMargin))"
                + "  \(resultText)"
        )

        for warning in presetWarnings {
            print("  - \(warning)")
        }
    }

    print("")
    return worstExit
}

func runVerificationHarness(
    configPath: String,
    durationSeconds: Double,
    presetSweep: Bool = false,
    longRun: Bool = false,
    captureBaseline: Bool = false,
    strictBaseline: Bool = false
) throws -> Int32 {
    let config = try AppConfig.load(fromINI: configPath)
    if presetSweep {
        print("MPX Prime Preset Verification")
        print("Config: \(configPath)")
        print(
            "Render: \(Int(config.sampleRate)) Hz • Block \(config.blockSize) • Sweep Duration \(String(format: "%.1f", min(durationSeconds, 1.0))) s"
        )
        print("")
        return runPresetSweepVerification(
            baseConfig: config,
            durationSeconds: durationSeconds
        )
    }
    let scenarios = longRun ? longRunVerificationScenarios() : verificationScenarios()

    print(longRun ? "MPX Prime Long-Run Verification" : "MPX Prime Verification")
    print("Config: \(configPath)")
    print(
        "Render: \(Int(config.sampleRate)) Hz • Block \(config.blockSize) • Duration \(String(format: "%.1f", durationSeconds)) s"
    )
    let audioCompositeShaperActive = config.audioCompositeSoftClipEnabled
    let audioCompositeSmootherActive =
        config.audioCompositeSmootherEnabled && audioCompositeShaperActive
    print(
        "Final Stage: shaper \(audioCompositeShaperActive ? "on" : "off")"
            + " • smoother \(audioCompositeSmootherActive ? "on" : "off")"
            + " • composite clipper \(config.compositeClipperEnabled ? "on" : "off")"
            + " • MPX safety \(config.limitMPX ? "on" : "off")"
            + " • MPX soft clip \(config.finalMPXSoftClipEnabled ? "on" : "off")"
    )
    if longRun {
        print("Scope: focused program-material compliance/regression scenarios")
    }

    let baselineURL = defaultVerifierBaselinePath()
    var loadedBaseline: VerifierBaselineFile?
    if !longRun && !captureBaseline {
        if FileManager.default.fileExists(atPath: baselineURL.path) {
            do {
                loadedBaseline = try loadVerifierBaseline(from: baselineURL)
                print("Baseline: \(baselineURL.lastPathComponent) (captured \(loadedBaseline!.capturedAt))")
            } catch {
                print("Baseline: failed to load (\(error))")
            }
        } else {
            print("Baseline: none — run with --capture-baseline to create.")
        }
    }

    print("")
    print(
        "Scenario              Peak dBFS  Dev kHz  LimGR  SafeGR  AudioPk  Pilot  RDS   Margin  AGC"
    )
    print(
        "--------------------  ---------  -------  -----  ------  -------  -----  ----  ------  ----"
    )

    var worstPeak: Float = 0.0
    var worstSafety: Float = 0.0
    var worstMargin: Float = .greatestFiniteMagnitude
    var scenarioMetrics: [(VerificationScenario, VerificationMetrics)] = []
    var qualityWarnings: [String] = []
    var signatureWarnings: [String] = []
    let signatureReferences = longRun ? longRunSignatureReferences() : [:]

    for scenario in scenarios {
        let metrics = verifyScenario(
            config: config,
            durationSeconds: durationSeconds,
            scenario: scenario
        )
        scenarioMetrics.append((scenario, metrics))
        worstPeak = max(worstPeak, metrics.peakAbs)
        worstSafety = max(worstSafety, metrics.maxSafetyGRDB)
        worstMargin = min(worstMargin, metrics.minBudgetMarginDB)
        qualityWarnings.append(
            contentsOf: qualityFindings(scenario: scenario, metrics: metrics).map { "\(scenario.name): \($0)" }
        )
        if longRun, let reference = signatureReferences[scenario.name] {
            signatureWarnings.append(
                contentsOf: longRunSignatureFindings(
                    scenario: scenario,
                    metrics: metrics,
                    reference: reference
                ).map { "\(scenario.name): \($0)" }
            )
        }

        let line =
            "\(padded(scenario.name, width: 20))  "
            + "\(leftPadded(dbfsString(metrics.peakAbs), width: 9))"
            + "  \(leftPadded(deviationString(peakAbs: metrics.peakAbs, targetDeviationKHz: config.mpxDeviationKHz), width: 7))"
            + "  \(String(format: "%5.1f", nonNegative(metrics.maxLimiterGRDB)))"
            + "  \(String(format: "%6.1f", nonNegative(metrics.maxSafetyGRDB)))"
            + "  \(leftPadded(dbfsString(metrics.maxAudioCompositePeak), width: 7))"
            + "  \(String(format: "%5.1f", metrics.pilotPercent))"
            + "  \(String(format: "%4.1f", metrics.rdsPercent))"
            + "  \(String(format: "%6.1f", metrics.minBudgetMarginDB))"
            + "  \(String(format: "%4.1f", metrics.maxAGCReductionDB))"
        print(line)
    }

    print("")
    print("Stereo Quality")
    print(
        "Scenario              InCorr  OutCorr  InSide  OutSide  dRMS"
    )
    print(
        "--------------------  ------  -------  ------  -------  -----"
    )

    for (scenario, metrics) in scenarioMetrics {
        let qualityFlag = qualityFindings(scenario: scenario, metrics: metrics).isEmpty ? "OK" : "WARN"
        let line =
            "\(padded(scenario.name, width: 20))  "
            + "\(String(format: "%6.2f", metrics.inputSignal.correlation))"
            + "  \(String(format: "%7.2f", metrics.outputSignal.correlation))"
            + "  \(ratioString(metrics.inputSignal.sideToMidRatio, width: 6))"
            + "  \(ratioString(metrics.outputSignal.sideToMidRatio, width: 7))"
            + "  \(String(format: "%5.1f", metrics.rmsDeltaDB))"
            + "  \(qualityFlag)"
        print(line)
    }

    print("")
    print("MPX Width")
    print(
        "Scenario              Occ999 Hz  >60k/In  >67k/In"
    )
    print(
        "--------------------  ---------  -------  -------"
    )

    for (scenario, metrics) in scenarioMetrics {
        let line =
            "\(padded(scenario.name, width: 20))  "
            + "\(leftPadded(String(format: "%.0f", metrics.bandwidth.occupied999Hz), width: 9))"
            + "  \(leftPadded(String(format: "%.1f", metrics.bandwidth.above60kRatioDB), width: 7))"
            + "  \(leftPadded(String(format: "%.1f", metrics.bandwidth.above67kRatioDB), width: 7))"
        print(line)
    }

    var baselineDrift: [BaselineDriftFinding] = []
    if !longRun {
        let measured: [String: VerifierBaselineRecord] = Dictionary(
            uniqueKeysWithValues: scenarioMetrics.map { (scenario, metrics) in
                (scenario.name, buildBaselineRecord(
                    metrics: metrics,
                    targetDeviationKHz: config.mpxDeviationKHz
                ))
            }
        )
        if captureBaseline {
            let file = VerifierBaselineFile(
                schemaVersion: VerifierBaselineFile.currentSchemaVersion,
                capturedAt: verifierBaselineTimestampNow(),
                configPath: configPath,
                renderSampleRateHz: Int(config.sampleRate),
                blockSize: config.blockSize,
                durationSeconds: durationSeconds,
                scenarios: measured
            )
            do {
                try saveVerifierBaseline(file, to: baselineURL)
                print("")
                print("Baseline captured: \(baselineURL.path)")
                print("  \(measured.count) scenarios written.")
            } catch {
                print("")
                print("Baseline capture FAILED: \(error)")
            }
        } else if let baseline = loadedBaseline {
            baselineDrift = compareBaseline(measured: measured, baseline: baseline)
        }
    }

    print("")
    print("Assessment")
    print("Worst MPX peak: \(dbfsString(worstPeak)) dBFS")
    print("Worst safety limiter GR: \(String(format: "%.1f", nonNegative(worstSafety))) dB")
    print("Worst composite margin: \(String(format: "%.1f", worstMargin)) dB")

    if longRun {
        print("Signature warnings: \(signatureWarnings.isEmpty ? "none" : "\(signatureWarnings.count)")")
    }
    if !baselineDrift.isEmpty {
        print("Baseline drift (\(baselineDrift.count) finding\(baselineDrift.count == 1 ? "" : "s")):")
        for finding in baselineDrift {
            print("- \(finding.formattedLine)")
        }
    }

    let naturalResult: Int32
    if !qualityWarnings.isEmpty {
        print("Quality warnings:")
        for warning in qualityWarnings { print("- \(warning)") }
        naturalResult = 1
    } else if !signatureWarnings.isEmpty {
        print("Signature drift warnings:")
        for warning in signatureWarnings { print("- \(warning)") }
        naturalResult = 1
    } else if worstSafety > 1.0 { naturalResult = 2
    } else if worstMargin < -0.25 { naturalResult = 2
    } else if worstMargin < 0.0 || worstSafety > 0.25 { naturalResult = 1
    } else { naturalResult = 0 }

    let result: Int32
    if baselineDrift.isEmpty { result = naturalResult }
    else if strictBaseline { result = 2 }
    else { result = max(naturalResult, 1) }

    switch result {
    case 2:
        if strictBaseline && !baselineDrift.isEmpty {
            print("Result: WARN - stored-baseline drift in --baseline-strict mode.")
        } else if worstSafety > 1.0 {
            print("Result: WARN - safety limiter is doing significant work.")
        } else {
            print("Result: WARN - composite budget exceeded on at least one scenario.")
        }
    case 1:
        if !qualityWarnings.isEmpty {
            print("Result: TIGHT - composite safety is OK, but decoded-audio quality drift exceeded expected bounds.")
        } else if !signatureWarnings.isEmpty {
            print("Result: TIGHT - long-run verifier drifted beyond the current reference signature.")
        } else if !baselineDrift.isEmpty {
            print("Result: TIGHT - stored-baseline drift detected (use --baseline-strict to fail the run).")
        } else {
            print("Result: TIGHT - verification stayed close to the composite budget limit.")
        }
    default:
        print(
            longRun
                ? "Result: OK - no obvious long-run compliance or safety regression."
                : "Result: OK - no obvious composite-budget or safety-limiter issue."
        )
    }
    return result
}
