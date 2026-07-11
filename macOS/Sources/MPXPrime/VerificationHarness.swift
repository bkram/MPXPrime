#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
import Foundation
import MPXPrimeCore

private struct StereoSignalMetrics {
    var rms: Float = 0.0
    var peak: Float = 0.0
    var correlation: Float = 0.0
    var sideToMidRatio: Float = 0.0
}

private struct AudioBandRMSMetrics {
    var lowDBFS: Float = -160.0
    var midDBFS: Float = -160.0
    var highDBFS: Float = -160.0
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
    var maxPostInjectionOvershoot: Float = 0.0
    /// 4x-oversampled true-peak of the composite (ITU-R BS.1770-style
    /// inter-sample peak). Computed offline on the captured MPX samples.
    var truePeakAbs: Float = 0.0
    var overBudget: Bool = false
    var minBudgetMarginDB: Float = .greatestFiniteMagnitude
    var pilotPercent: Float = 0.0
    var rdsPercent: Float = 0.0
    var maxAGCReductionDB: Float = 0.0
    var detectorDBAtMaxReduction: Float = -120.0
    var inputSignal = StereoSignalMetrics()
    var outputSignal = StereoSignalMetrics()
    var outputBands = AudioBandRMSMetrics()
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
        maxPostInjectionOvershoot = max(maxPostInjectionOvershoot, calibration.postInjectionOvershoot)
        overBudget = overBudget || calibration.overBudget
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

private struct ToneVector {
    var sin: Double = 0.0
    var cos: Double = 0.0

    var amplitude: Double {
        sqrt((sin * sin) + (cos * cos))
    }

    static func + (lhs: ToneVector, rhs: ToneVector) -> ToneVector {
        ToneVector(sin: lhs.sin + rhs.sin, cos: lhs.cos + rhs.cos)
    }

    static func - (lhs: ToneVector, rhs: ToneVector) -> ToneVector {
        ToneVector(sin: lhs.sin - rhs.sin, cos: lhs.cos - rhs.cos)
    }

    func scaled(by gain: Double) -> ToneVector {
        ToneVector(sin: sin * gain, cos: cos * gain)
    }
}

private struct ReceiverToneMetrics {
    let toneHz: Double
    let wantedDBFS: Float
    let crosstalkDBFS: Float
    let separationDB: Float
}

private struct ReceiverMonoMetrics {
    let midDBFS: Float
    let sideDBFS: Float
    let sideRejectionDB: Float
}

private struct ReceiverPLLRoundTripMetrics {
    let toneHz: Double
    let wantedDBFS: Float
    let crosstalkDBFS: Float
    let separationDB: Float
    let decodedRMSDBFS: Float
    let decodedPeakDBFS: Float
    let correlation: Float
    let sideToMidRatio: Float
}

private struct ReceiverIdealDecodeMetrics {
    let toneHz: Double
    let wantedDBFS: Float
    let crosstalkDBFS: Float
    let separationDB: Float
    let monoDBFS: Float
    let sideDBFS: Float
    let monoSideDeltaDB: Float
}

private struct ReceiverNoPilotMetrics {
    let pilotPercent: Float
    let midDBFS: Float
    let sideDBFS: Float
    let sideRejectionDB: Float
    let correlation: Float
}

private struct ReceiverSubcarrierMetrics {
    let pilotPercent: Float
    let pilotPhaseDegrees: Float
    let rdsBandDBFS: Float
    let rdsCenterDBFS: Float
}

private struct ReceiverToneAnalysis {
    let coherent: ReceiverToneMetrics
    let pll: ReceiverPLLRoundTripMetrics
    let ideal: ReceiverIdealDecodeMetrics
    let encoderSideband: EncoderSidebandMetrics
}

/// Encoder-side raw-MPX sideband measurement. Used to separate
/// encoder-side stereo-separation loss from receiver-model loss when
/// chasing premium-grade HF separation. Tap point is the raw MPX
/// waveform pre-MPXDecoder, so no receiver-side deemphasis, pilot/RDS
/// notch, or 15.5 kHz lowpass contaminates the numbers.
///
/// Driven by a single-channel sine (L-only or R-only). For perfect
/// DSB-SC stereo encoding with `sumLevel == diffLevel`, lower and
/// upper sidebands should match in amplitude and the side-sum should
/// equal the baseband mono. Deviations are encoder-side fingerprints:
/// FIR rolloff between 24 / 28 / 37 / 39 / 48 / 52 kHz produces
/// `asymmetryDB`; differential attenuation between baseband and
/// sideband bands produces `sideMonoDeltaDB`.
private struct EncoderSidebandMetrics {
    /// "L" or "R" — which channel was driven.
    let drivenChannel: String
    let toneHz: Double
    /// Baseband bin at toneHz (raw MPX, Goertzel extraction).
    let monoDBFS: Float
    /// Lower DSB-SC sideband at |38000 - toneHz|.
    let lowerSidebandDBFS: Float
    /// Upper DSB-SC sideband at 38000 + toneHz.
    let upperSidebandDBFS: Float
    /// |lower - upper| in dB. Direct signal of encoder FIR / clipper
    /// asymmetry across the sideband frequency span.
    let asymmetryDB: Float
    /// Side-sum amplitude as `20·log10(|lower| + |upper|)`, the
    /// amplitude an ideal coherent receiver would recover from the
    /// two mirror sidebands when they are in phase.
    let sideSumDBFS: Float
    /// `sideSumDBFS - monoDBFS`. For ideal DSB-SC with the encoder's
    /// default `sumLevel == diffLevel`, this is 0 dB. Negative values
    /// mean the side path is being attenuated relative to mono in the
    /// post-encoder chain (composite clipper / audio bandwidth FIR /
    /// safety limiter rolling off the sideband region more than
    /// baseband).
    let sideMonoDeltaDB: Float
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
                maxAbsRMSDeltaDB: 5.0,
                maxOccupied999Hz: 58_500.0,
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
                maxAbove67kRatioDB: -52.0
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
            description: "Transient-heavy program to stress AGC, PrimeBass hold, and limiter feel",
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
        }
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
        )
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
    metrics.outputBands = computeAudioBandRMSMetrics(
        left: monitorLeft,
        right: monitorRight,
        sampleRate: Float(sampleRate)
    )

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
    metrics.truePeakAbs = truePeak4x(mpxSamples).truePeak

    return metrics
}

private func dbfsString(_ linear: Float) -> String {
    guard linear > 1e-9 else { return "-inf" }
    return String(format: "%.2f", 20.0 * log10(Double(linear)))
}

/// 4x-oversampled true-peak of a composite sample array (offline,
/// ITU-R BS.1770-style inter-sample peak detection). The composite is
/// band-limited to ~60 kHz, well below the 96 kHz Nyquist at 192 kHz, so
/// a windowed-sinc fractional-delay interpolator reconstructs inter-sample
/// peaks faithfully. Returns both the true-peak and the plain sample-peak
/// so callers can report the overshoot (true minus sample).
private func truePeak4x(_ samples: [Float]) -> (truePeak: Float, samplePeak: Float) {
    let n = samples.count
    guard n > 0 else { return (0.0, 0.0) }

    let oversample = 4
    let halfTaps = 16
    let taps = 2 * halfTaps
    // Precompute the 3 non-integer polyphase fractional-delay kernels
    // (phase 0 is the identity — the original sample — so skip it).
    var kernels = [[Float]](repeating: [Float](repeating: 0.0, count: taps), count: oversample)
    for p in 1..<oversample {
        let frac = Float(p) / Float(oversample)
        var sum: Float = 0.0
        for j in 0..<taps {
            let k = Float(j - halfTaps + 1)
            let x = k - frac
            let sinc: Float = abs(x) < 1e-6 ? 1.0 : sinf(.pi * x) / (.pi * x)
            let wn = Float(j) / Float(taps - 1)
            let w = 0.42 - 0.5 * cosf(2.0 * .pi * wn) + 0.08 * cosf(4.0 * .pi * wn)
            let tap = sinc * w
            kernels[p][j] = tap
            sum += tap
        }
        if sum > 1e-9 {
            for j in 0..<taps { kernels[p][j] /= sum }
        }
    }

    var samplePeak: Float = 0.0
    for v in samples { samplePeak = max(samplePeak, abs(v)) }

    var truePeak = samplePeak
    for i in 0..<n {
        for p in 1..<oversample {
            var acc: Float = 0.0
            let kp = kernels[p]
            for j in 0..<taps {
                let idx = i + j - halfTaps + 1
                if idx >= 0 && idx < n {
                    acc += samples[idx] * kp[j]
                }
            }
            truePeak = max(truePeak, abs(acc))
        }
    }
    return (truePeak, samplePeak)
}

private func dbfs(_ linear: Double) -> Float {
    guard linear > 1e-12 else { return -240.0 }
    return Float(20.0 * log10(linear))
}

private func dbfsValue(_ linear: Float) -> Float {
    guard linear > 1e-9 else { return -160.0 }
    return Float(20.0 * log10(Double(linear)))
}

private func ratioDB(_ numerator: Float, _ denominator: Float) -> Float {
    guard numerator > 1e-9, denominator > 1e-9 else { return 0.0 }
    return Float(20.0 * log10(Double(numerator / denominator)))
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
        postInjectionOvershoot: metrics.maxPostInjectionOvershoot,
        overBudget: metrics.overBudget,
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
        above67kRatioDB: metrics.bandwidth.above67kRatioDB,
        truePeakOvershootDB: truePeakOvershootDB(metrics: metrics)
    )
}

/// True-peak minus sample-peak, in dB (>= 0). The inter-sample overshoot.
private func truePeakOvershootDB(metrics: VerificationMetrics) -> Float {
    guard metrics.truePeakAbs > 1e-9, metrics.peakAbs > 1e-9 else { return 0.0 }
    return max(0.0, Float(20.0 * log10(Double(metrics.truePeakAbs) / Double(metrics.peakAbs))))
}

/// Captures the encoder-side sideband fingerprint (L-only tone drive at
/// 1 / 10 / 14 kHz) for the baseline. Reuses the same per-tone
/// `encoderSidebandMetrics` measurement the receiver model prints, so a
/// `--baseline-strict` run gates the exact numbers a human reads in
/// `--verify-receiver`.
private func buildEncoderSidebandBaseline(
    config: AppConfig,
    durationSeconds: Double
) -> EncoderSidebandBaselineRecord {
    func measure(_ toneHz: Double) -> EncoderSidebandMetrics {
        encoderSidebandMetrics(
            config: config,
            toneHz: toneHz,
            drivenChannel: "L",
            durationSeconds: durationSeconds
        )
    }
    let m1 = measure(1_000.0)
    let m10 = measure(10_000.0)
    let m14 = measure(14_000.0)
    return EncoderSidebandBaselineRecord(
        asymmetryDB1k: m1.asymmetryDB,
        sideMonoDeltaDB1k: m1.sideMonoDeltaDB,
        asymmetryDB10k: m10.asymmetryDB,
        sideMonoDeltaDB10k: m10.sideMonoDeltaDB,
        asymmetryDB14k: m14.asymmetryDB,
        sideMonoDeltaDB14k: m14.sideMonoDeltaDB
    )
}

private func renderReceiverMPX(
    config: AppConfig,
    durationSeconds: Double,
    source: (_ frameIndex: Int, _ sampleRate: Double) -> (Float, Float)
) -> [Float] {
    let sampleRate = max(8_000.0, config.sampleRate)
    let frames = max(1, Int((durationSeconds * sampleRate).rounded()))
    let generator = MPXGenerator(config: config, sampleRate: sampleRate)
    var samples = [Float](repeating: 0.0, count: frames)
    for frame in 0..<frames {
        let input = source(frame, sampleRate)
        samples[frame] = generator.renderSingleSample(leftIn: input.0, rightIn: input.1)
    }
    return samples
}

private func toneVector(
    samples: [Float],
    sampleRate: Double,
    frequencyHz: Double,
    start: Int,
    count: Int
) -> ToneVector {
    guard count > 0, start >= 0, start + count <= samples.count else {
        return ToneVector()
    }
    let omega = 2.0 * Double.pi * frequencyHz / sampleRate
    var sinSum = 0.0
    var cosSum = 0.0
    for i in 0..<count {
        let phase = omega * Double(start + i)
        let sample = Double(samples[start + i])
        sinSum += sample * sin(phase)
        cosSum += sample * cos(phase)
    }
    let scale = 2.0 / Double(count)
    return ToneVector(sin: sinSum * scale, cos: cosSum * scale)
}

private func receiverAnalysisWindow(sampleCount: Int, sampleRate: Double) -> (start: Int, count: Int) {
    let desiredCount = min(sampleCount / 2, max(4096, Int((0.25 * sampleRate).rounded())))
    let count = max(1024, desiredCount)
    let start = max(0, sampleCount - count)
    return (start, min(count, sampleCount - start))
}

private func estimatePilotPhase(
    samples: [Float],
    sampleRate: Double,
    start: Int,
    count: Int
) -> (amplitude: Double, phase: Double) {
    let pilot = toneVector(
        samples: samples,
        sampleRate: sampleRate,
        frequencyHz: 19_000.0,
        start: start,
        count: count
    )
    return (pilot.amplitude, atan2(pilot.cos, pilot.sin))
}

private func toneBandEnergyDBFS(
    samples: [Float],
    sampleRate: Double,
    lowerHz: Double,
    upperHz: Double,
    start: Int,
    count: Int,
    stepHz: Double = 250.0
) -> Float {
    guard lowerHz <= upperHz, stepHz > 0.0 else { return -200.0 }
    var power = 0.0
    var frequency = lowerHz
    while frequency <= upperHz {
        let vector = toneVector(
            samples: samples,
            sampleRate: sampleRate,
            frequencyHz: frequency,
            start: start,
            count: count
        )
        let amplitude = max(vector.amplitude, 1e-12)
        power += amplitude * amplitude
        frequency += stepHz
    }
    return dbfs(sqrt(max(power, 1e-24)))
}

private func demodulatedSideVector(
    samples: [Float],
    sampleRate: Double,
    audioHz: Double,
    pilotPhase: Double,
    start: Int,
    count: Int
) -> ToneVector {
    guard count > 0, start >= 0, start + count <= samples.count else {
        return ToneVector()
    }
    let audioOmega = 2.0 * Double.pi * audioHz / sampleRate
    let pilotOmega = 2.0 * Double.pi * 19_000.0 / sampleRate
    var sinSum = 0.0
    var cosSum = 0.0
    for i in 0..<count {
        let absoluteIndex = Double(start + i)
        let sub = sin(2.0 * ((pilotOmega * absoluteIndex) + pilotPhase))
        let demod = Double(samples[start + i]) * 2.0 * sub
        let audioPhase = audioOmega * absoluteIndex
        sinSum += demod * sin(audioPhase)
        cosSum += demod * cos(audioPhase)
    }
    let scale = 2.0 / Double(count)
    return ToneVector(sin: sinSum * scale, cos: cosSum * scale)
}

private func decodeMPXWithReference(
    samples: [Float],
    pilotPhase: Double,
    config: AppConfig,
    programActivity: Float,
    expectedSide: Float
) -> (left: [Float], right: [Float]) {
    var decoder = MPXDecoder()
    decoder.configure(sampleRate: Float(config.sampleRate), preemphasisUS: config.preemphasisUS)
    var left = [Float](repeating: 0.0, count: samples.count)
    var right = [Float](repeating: 0.0, count: samples.count)
    let omega = 2.0 * Double.pi * 19_000.0 / config.sampleRate
    for i in 0..<samples.count {
        let ref = Float(sin(2.0 * ((omega * Double(i)) + pilotPhase)))
        let decoded = decoder.process(
            samples[i],
            referenceSubcarrier: ref,
            programActivity: programActivity,
            expectedSide: expectedSide
        )
        left[i] = decoded.0
        right[i] = decoded.1
    }
    return (left, right)
}

private func decodeMPXWithPLL(
    samples: [Float],
    config: AppConfig,
    programActivity: Float,
    expectedSide: Float
) -> (left: [Float], right: [Float]) {
    var decoder = MPXDecoder()
    decoder.configure(sampleRate: Float(config.sampleRate), preemphasisUS: config.preemphasisUS)
    var left = [Float](repeating: 0.0, count: samples.count)
    var right = [Float](repeating: 0.0, count: samples.count)
    for i in 0..<samples.count {
        let decoded = decoder.process(
            samples[i],
            referenceSubcarrier: nil,
            programActivity: programActivity,
            expectedSide: expectedSide
        )
        left[i] = decoded.0
        right[i] = decoded.1
    }
    return (left, right)
}

private func receiverToneMetrics(
    config: AppConfig,
    toneHz: Double,
    durationSeconds: Double
) -> ReceiverToneMetrics {
    var cfg = config
    cfg.monoMode = false
    cfg.enRDS = false
    let amplitude = 0.45
    let samples = renderReceiverMPX(config: cfg, durationSeconds: durationSeconds) { frame, sampleRate in
        let tone = Float(amplitude * sin(2.0 * Double.pi * toneHz * Double(frame) / sampleRate))
        return (tone, 0.0)
    }
    let window = receiverAnalysisWindow(sampleCount: samples.count, sampleRate: cfg.sampleRate)
    let pilot = estimatePilotPhase(
        samples: samples,
        sampleRate: cfg.sampleRate,
        start: window.start,
        count: window.count
    )
    let decoded = decodeMPXWithReference(
        samples: samples,
        pilotPhase: pilot.phase,
        config: cfg,
        programActivity: Float(amplitude),
        expectedSide: 0.0
    )
    let left = toneVector(
        samples: decoded.left,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let right = toneVector(
        samples: decoded.right,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    // The synthetic pilot reference may lock with either 38 kHz polarity,
    // which swaps decoded L/R. Separation is therefore scored as stronger
    // decoded channel vs weaker decoded channel.
    let wanted = max(max(left.amplitude, right.amplitude), 1e-12)
    let crosstalk = max(min(left.amplitude, right.amplitude), 1e-12)
    return ReceiverToneMetrics(
        toneHz: toneHz,
        wantedDBFS: dbfs(wanted),
        crosstalkDBFS: dbfs(crosstalk),
        separationDB: Float(20.0 * log10(wanted / crosstalk))
    )
}

private func encoderSidebandMetrics(
    config: AppConfig,
    toneHz: Double,
    drivenChannel: String,
    durationSeconds: Double
) -> EncoderSidebandMetrics {
    var cfg = config
    cfg.monoMode = false
    cfg.enRDS = false
    let amplitude = 0.45
    let driveLeft = drivenChannel == "L"
    // Single-channel sine: produces a baseband (L+R)/2 component at
    // toneHz plus symmetric DSB-SC sidebands at 38 +/- toneHz. Any
    // encoder-side asymmetry between those sidebands (e.g., audio
    // composite bandwidth FIR rolling off 52 kHz harder than 24 kHz
    // for a 14 kHz tone) becomes a direct fingerprint of encoder-side
    // separation loss.
    let samples = renderReceiverMPX(config: cfg, durationSeconds: durationSeconds) { frame, sampleRate in
        let tone = Float(amplitude * sin(2.0 * Double.pi * toneHz * Double(frame) / sampleRate))
        return driveLeft ? (tone, 0.0) : (0.0, tone)
    }
    let window = receiverAnalysisWindow(sampleCount: samples.count, sampleRate: cfg.sampleRate)

    let mono = toneVector(
        samples: samples,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let lower = toneVector(
        samples: samples,
        sampleRate: cfg.sampleRate,
        frequencyHz: 38_000.0 - toneHz,
        start: window.start,
        count: window.count
    )
    let upper = toneVector(
        samples: samples,
        sampleRate: cfg.sampleRate,
        frequencyHz: 38_000.0 + toneHz,
        start: window.start,
        count: window.count
    )

    let monoAmp = max(mono.amplitude, 1e-12)
    let lowerAmp = max(lower.amplitude, 1e-12)
    let upperAmp = max(upper.amplitude, 1e-12)
    let sideSumAmp = max(lowerAmp + upperAmp, 1e-12)

    let lowerDB = dbfs(lowerAmp)
    let upperDB = dbfs(upperAmp)
    let monoDB = dbfs(monoAmp)
    let sideSumDB = dbfs(sideSumAmp)
    return EncoderSidebandMetrics(
        drivenChannel: drivenChannel,
        toneHz: toneHz,
        monoDBFS: monoDB,
        lowerSidebandDBFS: lowerDB,
        upperSidebandDBFS: upperDB,
        asymmetryDB: abs(lowerDB - upperDB),
        sideSumDBFS: sideSumDB,
        sideMonoDeltaDB: sideSumDB - monoDB
    )
}

private func encoderSidebandMetricsFromSamples(
    samples: [Float],
    config: AppConfig,
    toneHz: Double,
    drivenChannel: String
) -> EncoderSidebandMetrics {
    let window = receiverAnalysisWindow(sampleCount: samples.count, sampleRate: config.sampleRate)

    let mono = toneVector(
        samples: samples,
        sampleRate: config.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let lower = toneVector(
        samples: samples,
        sampleRate: config.sampleRate,
        frequencyHz: 38_000.0 - toneHz,
        start: window.start,
        count: window.count
    )
    let upper = toneVector(
        samples: samples,
        sampleRate: config.sampleRate,
        frequencyHz: 38_000.0 + toneHz,
        start: window.start,
        count: window.count
    )

    let monoAmp = max(mono.amplitude, 1e-12)
    let lowerAmp = max(lower.amplitude, 1e-12)
    let upperAmp = max(upper.amplitude, 1e-12)
    let sideSumAmp = max(lowerAmp + upperAmp, 1e-12)

    let lowerDB = dbfs(lowerAmp)
    let upperDB = dbfs(upperAmp)
    let monoDB = dbfs(monoAmp)
    let sideSumDB = dbfs(sideSumAmp)
    return EncoderSidebandMetrics(
        drivenChannel: drivenChannel,
        toneHz: toneHz,
        monoDBFS: monoDB,
        lowerSidebandDBFS: lowerDB,
        upperSidebandDBFS: upperDB,
        asymmetryDB: abs(lowerDB - upperDB),
        sideSumDBFS: sideSumDB,
        sideMonoDeltaDB: sideSumDB - monoDB
    )
}

private func receiverToneAnalysis(
    config: AppConfig,
    toneHz: Double,
    durationSeconds: Double
) -> ReceiverToneAnalysis {
    var cfg = config
    cfg.monoMode = false
    cfg.enRDS = false
    let amplitude = 0.45
    let samples = renderReceiverMPX(config: cfg, durationSeconds: durationSeconds) { frame, sampleRate in
        let tone = Float(amplitude * sin(2.0 * Double.pi * toneHz * Double(frame) / sampleRate))
        return (tone, 0.0)
    }
    let window = receiverAnalysisWindow(sampleCount: samples.count, sampleRate: cfg.sampleRate)
    let pilot = estimatePilotPhase(
        samples: samples,
        sampleRate: cfg.sampleRate,
        start: window.start,
        count: window.count
    )

    let coherentDecoded = decodeMPXWithReference(
        samples: samples,
        pilotPhase: pilot.phase,
        config: cfg,
        programActivity: Float(amplitude),
        expectedSide: 0.0
    )
    let coherentLeft = toneVector(
        samples: coherentDecoded.left,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let coherentRight = toneVector(
        samples: coherentDecoded.right,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let coherentWanted = max(max(coherentLeft.amplitude, coherentRight.amplitude), 1e-12)
    let coherentCrosstalk = max(min(coherentLeft.amplitude, coherentRight.amplitude), 1e-12)

    let pllDecoded = decodeMPXWithPLL(
        samples: samples,
        config: cfg,
        programActivity: Float(amplitude),
        expectedSide: 0.0
    )
    let pllLeft = toneVector(
        samples: pllDecoded.left,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let pllRight = toneVector(
        samples: pllDecoded.right,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let pllWanted = max(max(pllLeft.amplitude, pllRight.amplitude), 1e-12)
    let pllCrosstalk = max(min(pllLeft.amplitude, pllRight.amplitude), 1e-12)
    let pllDecodedMetrics = computeStereoSignalMetrics(
        left: Array(pllDecoded.left[window.start..<(window.start + window.count)]),
        right: Array(pllDecoded.right[window.start..<(window.start + window.count)])
    )

    let mono = toneVector(
        samples: samples,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let side = demodulatedSideVector(
        samples: samples,
        sampleRate: cfg.sampleRate,
        audioHz: toneHz,
        pilotPhase: pilot.phase,
        start: window.start,
        count: window.count
    )
    let monoAmp = max(mono.amplitude, 1e-12)
    let sideAmp = max(side.amplitude, 1e-12)
    let normalizedSide = side.scaled(by: monoAmp / sideAmp)
    let idealPlus = mono + normalizedSide
    let idealMinus = mono - normalizedSide
    let idealWanted = max(max(idealPlus.amplitude, idealMinus.amplitude), 1e-12)
    let idealCrosstalk = max(min(idealPlus.amplitude, idealMinus.amplitude), 1e-12)

    return ReceiverToneAnalysis(
        coherent: ReceiverToneMetrics(
            toneHz: toneHz,
            wantedDBFS: dbfs(coherentWanted),
            crosstalkDBFS: dbfs(coherentCrosstalk),
            separationDB: Float(20.0 * log10(coherentWanted / coherentCrosstalk))
        ),
        pll: ReceiverPLLRoundTripMetrics(
            toneHz: toneHz,
            wantedDBFS: dbfs(pllWanted),
            crosstalkDBFS: dbfs(pllCrosstalk),
            separationDB: Float(20.0 * log10(pllWanted / pllCrosstalk)),
            decodedRMSDBFS: dbfs(Double(max(pllDecodedMetrics.rms, 1e-12))),
            decodedPeakDBFS: dbfs(Double(max(pllDecodedMetrics.peak, 1e-12))),
            correlation: pllDecodedMetrics.correlation,
            sideToMidRatio: pllDecodedMetrics.sideToMidRatio
        ),
        ideal: ReceiverIdealDecodeMetrics(
            toneHz: toneHz,
            wantedDBFS: dbfs(idealWanted),
            crosstalkDBFS: dbfs(idealCrosstalk),
            separationDB: Float(20.0 * log10(idealWanted / idealCrosstalk)),
            monoDBFS: dbfs(monoAmp),
            sideDBFS: dbfs(sideAmp),
            monoSideDeltaDB: dbfs(sideAmp) - dbfs(monoAmp)
        ),
        encoderSideband: encoderSidebandMetricsFromSamples(
            samples: samples,
            config: cfg,
            toneHz: toneHz,
            drivenChannel: "L"
        )
    )
}

/// Per-stage isolation sweep for the HF stereo-separation
/// investigation. Renders L-only sines at 1 / 10 / 14 kHz through the
/// chain with each stage individually disabled, and reports the
/// resulting asymmetry + side-vs-mono delta against the baseline (all
/// stages enabled). The stage whose row most-moves the metric is the
/// stage contributing that loss.
private struct StageIsolationRow {
    let label: String
    let metricsByTone: [Double: EncoderSidebandMetrics]
}

private func runEncoderStageIsolationSweep(
    baseConfig: AppConfig,
    durationSeconds: Double
) -> [StageIsolationRow] {
    let tones: [Double] = [1_000.0, 10_000.0, 14_000.0]

    func measure(label: String, mutate: (inout AppConfig) -> Void) -> StageIsolationRow {
        var cfg = baseConfig
        mutate(&cfg)
        var byTone: [Double: EncoderSidebandMetrics] = [:]
        for tone in tones {
            byTone[tone] = encoderSidebandMetrics(
                config: cfg,
                toneHz: tone,
                drivenChannel: "L",
                durationSeconds: durationSeconds
            )
        }
        return StageIsolationRow(label: label, metricsByTone: byTone)
    }

    var rows: [StageIsolationRow] = []
    rows.append(measure(label: "baseline (full chain)") { _ in })
    rows.append(measure(label: "bass clipper OFF") { $0.bassClipperEnabled = false })
    rows.append(measure(label: "HF clipper OFF") { $0.hfClipperEnabled = false })
    rows.append(measure(label: "distortion-cancel clip OFF") { $0.dcClipperEnabled = false })
    rows.append(measure(label: "composite clipper OFF") { $0.compositeClipperEnabled = false })
    rows.append(measure(label: "audio composite softclip OFF") { $0.audioCompositeSoftClipEnabled = false })
    rows.append(measure(label: "audio composite smoother OFF") { $0.audioCompositeSmootherEnabled = false })
    rows.append(measure(label: "final MPX safety OFF") { $0.finalMPXSoftClipEnabled = false })
    rows.append(measure(label: "encoder FIR OFF") { $0.encoderFIREnabled = false })
    rows.append(measure(label: "pre-encode limiter OFF") { $0.preEncodeAudioLimiterEnabled = false })
    // Pre-emphasis disable also disables the 19 kHz pilot notch in
    // the audio path (they share the `preemphasisUS > 0` gate in
    // `configureAudioPath`). The pilot notch is only meaningful when
    // pre-emphasis is on, so the joint toggle is the right unit.
    rows.append(measure(label: "pre-emphasis + pilot notch OFF") { $0.preemphasisUS = 0 })
    return rows
}

/// Pilot/RDS phase-lock stability. The RDS 57 kHz subcarrier must stay
/// locked to 3x the 19 kHz pilot (EN 50067 Sec 2.1.4). If the encoder
/// derives the two from different phase representations they slowly slip;
/// this measures that slip by comparing the pilot-vs-RDS phase
/// relationship in an early window against a late window of one long
/// render. A locked encoder holds the relationship flat (~0 deg drift);
/// a slipping one accumulates degrees over the render.
private struct PilotRDSLockMetrics {
    let earlyPilotPhaseDeg: Float
    let latePilotPhaseDeg: Float
    let earlyRDSPhaseDeg: Float
    let lateRDSPhaseDeg: Float
    /// Change in (RDS carrier phase - 3x pilot phase) from early to late
    /// window, wrapped to +/-90 deg (squaring recovery is mod 180).
    let lockDriftDeg: Float
    let renderSeconds: Double
}

/// Squaring carrier-phase recovery for the BPSK RDS subcarrier. A 57 kHz
/// bandpass isolates the RDS band; complex demod against an absolute-
/// sample-index 57 kHz reference brings it to baseband; squaring strips
/// the +/-1 biphase modulation. Returns 0.5*arg of the coherent sum --
/// the RDS carrier phase relative to the ideal 57 kHz reference, in
/// radians, ambiguous mod pi.
private func rdsCarrierResidualPhase(
    samples: [Float],
    sampleRate: Double,
    start: Int,
    count: Int
) -> Double {
    guard count > 0, start >= 0, start + count <= samples.count else { return 0.0 }
    var bp = Biquad()
    bp.configureBandpass(freqHz: 57_000.0, sampleRate: Float(sampleRate), q: 14.0)
    // Prime the filter on a short run-up so its state is settled at the
    // window start.
    let primeStart = max(0, start - 2048)
    for i in primeStart..<start {
        _ = bp.process(samples[i])
    }
    let omega = 2.0 * Double.pi * 57_000.0 / sampleRate
    var reAcc = 0.0
    var imAcc = 0.0
    for i in 0..<count {
        let n = Double(start + i)
        let s = Double(bp.process(samples[start + i]))
        let zr = s * cos(omega * n)
        let zi = -s * sin(omega * n)
        reAcc += (zr * zr) - (zi * zi)
        imAcc += 2.0 * zr * zi
    }
    return 0.5 * atan2(imAcc, reAcc)
}

private func pilotRDSLockMetrics(
    baseConfig: AppConfig,
    durationSeconds: Double
) -> PilotRDSLockMetrics {
    var cfg = baseConfig
    cfg.monoMode = false
    cfg.enRDS = true
    // Stereo content so the pilot reads cleanly; modest level so nothing
    // saturates and shifts phase.
    let amplitude = 0.30
    let samples = renderReceiverMPX(config: cfg, durationSeconds: durationSeconds) { frame, sampleRate in
        let t = Double(frame) / sampleRate
        let l = Float(amplitude * sin(2.0 * Double.pi * 1_000.0 * t))
        let r = Float(amplitude * sin(2.0 * Double.pi * 1_000.0 * t + 0.6))
        return (l, r)
    }
    let sr = cfg.sampleRate
    let n = samples.count
    // Early / late analysis windows, each ~0.2 s, taken near the ends.
    let win = max(4096, min(n / 4, Int((0.2 * sr).rounded())))
    let earlyStart = min(max(0, n / 8), max(0, n - win))
    let lateStart = max(earlyStart + win, n - win)

    func pilotPhase(_ start: Int) -> Double {
        estimatePilotPhase(samples: samples, sampleRate: sr, start: start, count: win).phase
    }
    let earlyPilot = pilotPhase(earlyStart)
    let latePilot = pilotPhase(lateStart)
    let earlyRDS = rdsCarrierResidualPhase(samples: samples, sampleRate: sr, start: earlyStart, count: win)
    let lateRDS = rdsCarrierResidualPhase(samples: samples, sampleRate: sr, start: lateStart, count: win)

    // Lock error = RDS phase - 3*pilot phase. Compare early vs late; the
    // absolute value is meaningless (mod-pi ambiguity from squaring),
    // only the drift between windows matters. Wrap to +/- pi/2.
    func wrapHalfPi(_ x: Double) -> Double {
        var v = x
        let pi = Double.pi
        while v > pi / 2 { v -= pi }
        while v < -pi / 2 { v += pi }
        return v
    }
    let earlyErr = earlyRDS - 3.0 * earlyPilot
    let lateErr = lateRDS - 3.0 * latePilot
    let drift = wrapHalfPi(lateErr - earlyErr)
    let toDeg = 180.0 / Double.pi
    return PilotRDSLockMetrics(
        earlyPilotPhaseDeg: Float(earlyPilot * toDeg),
        latePilotPhaseDeg: Float(latePilot * toDeg),
        earlyRDSPhaseDeg: Float(earlyRDS * toDeg),
        lateRDSPhaseDeg: Float(lateRDS * toDeg),
        lockDriftDeg: Float(drift * toDeg),
        renderSeconds: Double(n) / sr
    )
}

/// Guard-band cancellation depth for the composite clipper. The clipper
/// removes its own intermod from the pilot guard (17-21 kHz) and RDS
/// guard (55-59 kHz) bands before the constant-amplitude subcarriers are
/// injected. This measures how deep that removal actually is.
///
/// Methodology: drive the clipper hard with a dense stereo program but
/// suppress the cleanly-injected subcarriers that would otherwise mask
/// the residual — pilot level forced to 0 (the 17-21 kHz band then holds
/// only clipper IM) and RDS off (the 55-59 kHz band holds only clipper
/// IM). The 38 kHz stereo DSB-SC stays on so the clipper sees a full
/// 0-53 kHz composite and generates realistic out-of-band IM. Render
/// once with the guard's cancellation flag on, once off; depth is the
/// band-energy delta. Larger = the guard is doing more work.
private struct GuardBandCancellationMetrics {
    let pilotGuardResidualOnDBFS: Float
    let pilotGuardResidualOffDBFS: Float
    let pilotGuardDepthDB: Float
    let rdsGuardResidualOnDBFS: Float
    let rdsGuardResidualOffDBFS: Float
    let rdsGuardDepthDB: Float
}

private func guardBandCancellationMetrics(
    baseConfig: AppConfig,
    durationSeconds: Double
) -> GuardBandCancellationMetrics {
    func render(cancelPilot: Bool, cancelRDS: Bool) -> [Float] {
        var cfg = baseConfig
        cfg.monoMode = false
        cfg.enRDS = false
        cfg.pilotLevel = 0.0
        cfg.compositeClipperEnabled = true
        cfg.compositeClipperCancelPilot = cancelPilot
        cfg.compositeClipperCancelRDS = cancelRDS
        // Isolate the composite clipper: disable every other nonlinearity
        // so the only source of guard-band IM is the composite clipper
        // itself. Otherwise upstream clipper/limiter IM dominates the
        // guard bands and masks the cancellation depth we want to gate.
        cfg.bassClipperEnabled = false
        cfg.hfClipperEnabled = false
        cfg.dcClipperEnabled = false
        cfg.audioCompositeSoftClipEnabled = false
        cfg.finalMPXSoftClipEnabled = false
        cfg.preEncodeAudioLimiterEnabled = false
        // Push the clipper hard so the guard bands carry measurable IM.
        cfg.finalDriveDB = min(20.0, baseConfig.finalDriveDB + 8.0)
        return renderReceiverMPX(config: cfg, durationSeconds: durationSeconds) { frame, sampleRate in
            let t = Double(frame) / sampleRate
            // Dense, hard-panned multitone with HF energy so clipping
            // throws IM up into the stereo / RDS region.
            let env = 0.85 + (0.10 * sin(2.0 * Double.pi * 0.5 * t))
            let a = sin(2.0 * Double.pi * 440.0 * t)
            let b = sin(2.0 * Double.pi * 3100.0 * t)
            let c = sin(2.0 * Double.pi * 7700.0 * t)
            let d = sin(2.0 * Double.pi * 13_500.0 * t)
            let left = Float(env) * Float((0.30 * a) + (0.26 * b) + (0.24 * c) + (0.20 * d))
            let right = Float(env) * Float((0.28 * a) - (0.24 * b) + (0.22 * c) - (0.20 * d))
            return (left, right)
        }
    }

    func bandEnergy(_ samples: [Float], lowerHz: Double, upperHz: Double) -> Float {
        let window = receiverAnalysisWindow(sampleCount: samples.count, sampleRate: baseConfig.sampleRate)
        return toneBandEnergyDBFS(
            samples: samples,
            sampleRate: baseConfig.sampleRate,
            lowerHz: lowerHz,
            upperHz: upperHz,
            start: window.start,
            count: window.count,
            stepHz: 250.0
        )
    }

    let bothOn = render(cancelPilot: true, cancelRDS: true)
    let pilotOff = render(cancelPilot: false, cancelRDS: true)
    let rdsOff = render(cancelPilot: true, cancelRDS: false)

    let pilotOnDB = bandEnergy(bothOn, lowerHz: 17_000.0, upperHz: 21_000.0)
    let pilotOffDB = bandEnergy(pilotOff, lowerHz: 17_000.0, upperHz: 21_000.0)
    let rdsOnDB = bandEnergy(bothOn, lowerHz: 55_000.0, upperHz: 59_000.0)
    let rdsOffDB = bandEnergy(rdsOff, lowerHz: 55_000.0, upperHz: 59_000.0)

    return GuardBandCancellationMetrics(
        pilotGuardResidualOnDBFS: pilotOnDB,
        pilotGuardResidualOffDBFS: pilotOffDB,
        pilotGuardDepthDB: pilotOffDB - pilotOnDB,
        rdsGuardResidualOnDBFS: rdsOnDB,
        rdsGuardResidualOffDBFS: rdsOffDB,
        rdsGuardDepthDB: rdsOffDB - rdsOnDB
    )
}

private func receiverPLLRoundTripMetrics(
    config: AppConfig,
    toneHz: Double,
    durationSeconds: Double
) -> ReceiverPLLRoundTripMetrics {
    var cfg = config
    cfg.monoMode = false
    cfg.enRDS = false
    let amplitude = 0.45
    let samples = renderReceiverMPX(config: cfg, durationSeconds: durationSeconds) { frame, sampleRate in
        let tone = Float(amplitude * sin(2.0 * Double.pi * toneHz * Double(frame) / sampleRate))
        return (tone, 0.0)
    }
    let window = receiverAnalysisWindow(sampleCount: samples.count, sampleRate: cfg.sampleRate)
    let decoded = decodeMPXWithPLL(
        samples: samples,
        config: cfg,
        programActivity: Float(amplitude),
        expectedSide: 0.0
    )
    let left = toneVector(
        samples: decoded.left,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let right = toneVector(
        samples: decoded.right,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let wanted = max(max(left.amplitude, right.amplitude), 1e-12)
    let crosstalk = max(min(left.amplitude, right.amplitude), 1e-12)
    let decodedMetrics = computeStereoSignalMetrics(
        left: Array(decoded.left[window.start..<(window.start + window.count)]),
        right: Array(decoded.right[window.start..<(window.start + window.count)])
    )
    return ReceiverPLLRoundTripMetrics(
        toneHz: toneHz,
        wantedDBFS: dbfs(wanted),
        crosstalkDBFS: dbfs(crosstalk),
        separationDB: Float(20.0 * log10(wanted / crosstalk)),
        decodedRMSDBFS: dbfs(Double(max(decodedMetrics.rms, 1e-12))),
        decodedPeakDBFS: dbfs(Double(max(decodedMetrics.peak, 1e-12))),
        correlation: decodedMetrics.correlation,
        sideToMidRatio: decodedMetrics.sideToMidRatio
    )
}

private func receiverMonoMetrics(
    config: AppConfig,
    durationSeconds: Double
) -> ReceiverMonoMetrics {
    var cfg = config
    cfg.monoMode = false
    cfg.enRDS = false
    let toneHz = 1_000.0
    let amplitude = 0.45
    let samples = renderReceiverMPX(config: cfg, durationSeconds: durationSeconds) { frame, sampleRate in
        let tone = Float(amplitude * sin(2.0 * Double.pi * toneHz * Double(frame) / sampleRate))
        return (tone, tone)
    }
    let window = receiverAnalysisWindow(sampleCount: samples.count, sampleRate: cfg.sampleRate)
    let pilot = estimatePilotPhase(
        samples: samples,
        sampleRate: cfg.sampleRate,
        start: window.start,
        count: window.count
    )
    let decoded = decodeMPXWithReference(
        samples: samples,
        pilotPhase: pilot.phase,
        config: cfg,
        programActivity: Float(amplitude),
        expectedSide: 0.0
    )
    let mid = toneVector(
        samples: decoded.left,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    ) + toneVector(
        samples: decoded.right,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let side = toneVector(
        samples: decoded.left,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    ) - toneVector(
        samples: decoded.right,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let midAmp = max(mid.amplitude * 0.5, 1e-12)
    let sideAmp = max(side.amplitude * 0.5, 1e-12)
    return ReceiverMonoMetrics(
        midDBFS: dbfs(midAmp),
        sideDBFS: dbfs(sideAmp),
        sideRejectionDB: Float(20.0 * log10(midAmp / sideAmp))
    )
}

private func receiverNoPilotMetrics(
    config: AppConfig,
    durationSeconds: Double
) -> ReceiverNoPilotMetrics {
    var cfg = config
    cfg.monoMode = true
    cfg.enRDS = false
    let toneHz = 1_000.0
    let amplitude = 0.45
    let samples = renderReceiverMPX(config: cfg, durationSeconds: durationSeconds) { frame, sampleRate in
        let tone = Float(amplitude * sin(2.0 * Double.pi * toneHz * Double(frame) / sampleRate))
        return (tone, tone)
    }
    let window = receiverAnalysisWindow(sampleCount: samples.count, sampleRate: cfg.sampleRate)
    let pilot = estimatePilotPhase(
        samples: samples,
        sampleRate: cfg.sampleRate,
        start: window.start,
        count: window.count
    )
    let decoded = decodeMPXWithPLL(
        samples: samples,
        config: cfg,
        programActivity: Float(amplitude),
        expectedSide: 0.0
    )
    let leftVector = toneVector(
        samples: decoded.left,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let rightVector = toneVector(
        samples: decoded.right,
        sampleRate: cfg.sampleRate,
        frequencyHz: toneHz,
        start: window.start,
        count: window.count
    )
    let mid = leftVector + rightVector
    let side = leftVector - rightVector
    let midAmp = max(mid.amplitude * 0.5, 1e-12)
    let sideAmp = max(side.amplitude * 0.5, 1e-12)
    let decodedMetrics = computeStereoSignalMetrics(
        left: Array(decoded.left[window.start..<(window.start + window.count)]),
        right: Array(decoded.right[window.start..<(window.start + window.count)])
    )
    return ReceiverNoPilotMetrics(
        pilotPercent: Float(pilot.amplitude * 100.0),
        midDBFS: dbfs(midAmp),
        sideDBFS: dbfs(sideAmp),
        sideRejectionDB: Float(20.0 * log10(midAmp / sideAmp)),
        correlation: decodedMetrics.correlation
    )
}

private func receiverSubcarrierMetrics(
    config: AppConfig,
    durationSeconds: Double
) -> ReceiverSubcarrierMetrics {
    var cfg = config
    cfg.monoMode = false
    let samples = renderReceiverMPX(config: cfg, durationSeconds: durationSeconds) { _, _ in
        (0.0, 0.0)
    }
    let window = receiverAnalysisWindow(sampleCount: samples.count, sampleRate: cfg.sampleRate)
    let pilot = estimatePilotPhase(
        samples: samples,
        sampleRate: cfg.sampleRate,
        start: window.start,
        count: window.count
    )
    let rdsBand = toneBandEnergyDBFS(
        samples: samples,
        sampleRate: cfg.sampleRate,
        lowerHz: 55_000.0,
        upperHz: 59_000.0,
        start: window.start,
        count: window.count
    )
    let rdsCenter = toneVector(
        samples: samples,
        sampleRate: cfg.sampleRate,
        frequencyHz: 57_000.0,
        start: window.start,
        count: window.count
    )
    let wrappedDegrees = fmod((pilot.phase * 180.0 / Double.pi) + 360.0, 360.0)
    return ReceiverSubcarrierMetrics(
        pilotPercent: Float(pilot.amplitude * 100.0),
        pilotPhaseDegrees: Float(wrappedDegrees),
        rdsBandDBFS: rdsBand,
        rdsCenterDBFS: dbfs(rdsCenter.amplitude)
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

private func computeAudioBandRMSMetrics(
    left: [Float],
    right: [Float],
    sampleRate: Float
) -> AudioBandRMSMetrics {
    let frameCount = min(left.count, right.count)
    guard frameCount > 0 else { return AudioBandRMSMetrics() }

    var lowL = Biquad()
    var lowR = Biquad()
    var lowMidL = Biquad()
    var lowMidR = Biquad()
    lowL.configureLowpass(cutoffHz: 180.0, sampleRate: sampleRate)
    lowR.configureLowpass(cutoffHz: 180.0, sampleRate: sampleRate)
    lowMidL.configureLowpass(cutoffHz: 4_200.0, sampleRate: sampleRate)
    lowMidR.configureLowpass(cutoffHz: 4_200.0, sampleRate: sampleRate)

    var lowPower: Double = 0.0
    var midPower: Double = 0.0
    var highPower: Double = 0.0
    for i in 0..<frameCount {
        let l = left[i]
        let r = right[i]
        let lLow = lowL.process(l)
        let rLow = lowR.process(r)
        let lLowMid = lowMidL.process(l)
        let rLowMid = lowMidR.process(r)
        let lMid = lLowMid - lLow
        let rMid = rLowMid - rLow
        let lHigh = l - lLowMid
        let rHigh = r - rLowMid

        lowPower += Double((lLow * lLow) + (rLow * rLow)) * 0.5
        midPower += Double((lMid * lMid) + (rMid * rMid)) * 0.5
        highPower += Double((lHigh * lHigh) + (rHigh * rHigh)) * 0.5
    }

    func db(_ power: Double) -> Float {
        Float(10.0 * log10(max(power / Double(frameCount), 1e-16)))
    }
    return AudioBandRMSMetrics(
        lowDBFS: db(lowPower),
        midDBFS: db(midPower),
        highDBFS: db(highPower)
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
        metrics.inputSignal.sideToMidRatio > 0.05 {
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
        }
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
    print("Preset                Peak dBFS  Margin  POvr   Bdg  Result")
    print("--------------------  ---------  ------  -----  ---  ------")

    for sweep in sweeps {
        var config = baseConfig
        sweep.apply(&config)

        var presetWorstPeak: Float = 0.0
        var presetWorstMargin: Float = .greatestFiniteMagnitude
        var presetWarnings: [String] = []
        var presetWorstOvershoot: Float = 0.0
        var presetOverBudget = false

        for scenario in scenarios {
            let metrics = verifyScenario(
                config: config,
                durationSeconds: sweepDuration,
                scenario: scenario
            )
            let expectationsOverride = presetQualityOverride(for: sweep, scenario: scenario)
            presetWorstPeak = max(presetWorstPeak, metrics.peakAbs)
            presetWorstMargin = min(presetWorstMargin, metrics.minBudgetMarginDB)
            presetWorstOvershoot = max(presetWorstOvershoot, metrics.maxPostInjectionOvershoot)
            presetOverBudget = presetOverBudget || metrics.overBudget
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
        if presetOverBudget || presetWorstOvershoot > 1e-4 || presetWorstMargin < -0.25 {
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
                + "  \(String(format: "%5.4f", presetWorstOvershoot))"
                + "  \(presetOverBudget ? "YES" : " no")"
                + "  \(resultText)"
        )

        for warning in presetWarnings {
            print("  - \(warning)")
        }
    }

    print("")
    return worstExit
}

private func runCompositeMultibandClipperComparison(
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

private func multibandCouplingComparisonScenarios() -> [VerificationScenario] {
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

private func runMultibandCouplingComparison(
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

private func runReceiverModelVerification(
    baseConfig: AppConfig,
    configPath: String,
    durationSeconds: Double,
    captureBaseline: Bool = false,
    strictBaseline: Bool = false
) -> Int32 {
    let duration = max(1.0, durationSeconds)
    let pllDuration = max(3.0, durationSeconds)
    let diagnosticDuration = max(0.5, min(duration, 0.75))
    let toneFrequencies = [1_000.0, 10_000.0, 14_000.0]
    let receiverToneAnalyses = toneFrequencies.map {
        receiverToneAnalysis(config: baseConfig, toneHz: $0, durationSeconds: pllDuration)
    }
    let toneMetrics = receiverToneAnalyses.map(\.coherent)
    let pllRoundTripMetrics = receiverToneAnalyses.map(\.pll)
    let idealDecodeMetrics = receiverToneAnalyses.map(\.ideal)
    var encoderSidebandMetricsList: [EncoderSidebandMetrics] = []
    for analysis in receiverToneAnalyses {
        encoderSidebandMetricsList.append(analysis.encoderSideband)
        encoderSidebandMetricsList.append(
            encoderSidebandMetrics(
                config: baseConfig,
                toneHz: analysis.encoderSideband.toneHz,
                drivenChannel: "R",
                durationSeconds: diagnosticDuration
            )
        )
    }
    let stageIsolationRows = runEncoderStageIsolationSweep(
        baseConfig: baseConfig,
        durationSeconds: diagnosticDuration
    )
    let mono = receiverMonoMetrics(config: baseConfig, durationSeconds: duration)
    let noPilot = receiverNoPilotMetrics(config: baseConfig, durationSeconds: duration)
    let subcarriers = receiverSubcarrierMetrics(config: baseConfig, durationSeconds: duration)
    let guardBands = guardBandCancellationMetrics(
        baseConfig: baseConfig,
        durationSeconds: pllDuration
    )
    let pilotRDSLock = baseConfig.enRDS
        ? pilotRDSLockMetrics(baseConfig: baseConfig, durationSeconds: max(5.0, durationSeconds))
        : nil

    print("Receiver Model")
    print("Scope: coherent stereo decode, PLL external-style decode, mono/no-pilot behavior, pilot/RDS spectral checks")
    print("")
    print("Stereo Decode")
    print("Tone Hz  Wanted   Xtalk    Sep")
    print("-------  -------  -------  -----")

    var warnings: [String] = []
    var notes: [String] = []
    for metric in toneMetrics {
        let minimumSeparation: Float = metric.toneHz >= 14_000.0 ? 16.0 : 18.0
        if metric.separationDB < minimumSeparation {
            warnings.append(
                "\(Int(metric.toneHz)) Hz separation \(String(format: "%.1f", metric.separationDB)) dB < \(String(format: "%.1f", minimumSeparation)) dB"
            )
        }
        print(
            "\(leftPadded(String(format: "%.0f", metric.toneHz), width: 7))"
                + "  \(leftPadded(String(format: "%.1f", metric.wantedDBFS), width: 7))"
                + "  \(leftPadded(String(format: "%.1f", metric.crosstalkDBFS), width: 7))"
                + "  \(String(format: "%5.1f", metric.separationDB))"
        )
    }

    for metric in pllRoundTripMetrics {
        let minimumSeparation: Float = metric.toneHz >= 14_000.0 ? 16.0 : 18.0
        if metric.separationDB < minimumSeparation {
            warnings.append(
                "PLL external-style \(Int(metric.toneHz)) Hz separation \(String(format: "%.1f", metric.separationDB)) dB < \(String(format: "%.1f", minimumSeparation)) dB"
            )
        }
        if metric.decodedRMSDBFS < -42.0 {
            warnings.append(
                "PLL external-style \(Int(metric.toneHz)) Hz decoded RMS \(String(format: "%.1f", metric.decodedRMSDBFS)) dBFS is unexpectedly low"
            )
        }
    }
    for ideal in idealDecodeMetrics {
        guard let production = toneMetrics.first(where: { $0.toneHz == ideal.toneHz }) else { continue }
        let gap = ideal.separationDB - production.separationDB
        if gap > 6.0 {
            notes.append(
                "ideal receiver \(Int(ideal.toneHz)) Hz separation is \(String(format: "%.1f", gap)) dB above production decoder; audit MPXDecoder filters before encoder tuning"
            )
        }
    }
    if mono.sideRejectionDB < 26.0 {
        warnings.append(
            "mono side rejection \(String(format: "%.1f", mono.sideRejectionDB)) dB < 26.0 dB"
        )
    }
    if noPilot.pilotPercent > 0.50 {
        warnings.append(
            "mono MPX no-pilot residual \(String(format: "%.2f", noPilot.pilotPercent))% > 0.50%"
        )
    }
    if noPilot.sideRejectionDB < 26.0 {
        warnings.append(
            "mono MPX no-pilot side rejection \(String(format: "%.1f", noPilot.sideRejectionDB)) dB < 26.0 dB"
        )
    }
    if subcarriers.pilotPercent < 6.5 || subcarriers.pilotPercent > 9.5 {
        warnings.append(
            "pilot level \(String(format: "%.2f", subcarriers.pilotPercent))% outside 6.5-9.5%"
        )
    }
    if baseConfig.enRDS && subcarriers.rdsBandDBFS < -60.0 {
        warnings.append(
            "RDS band energy \(String(format: "%.1f", subcarriers.rdsBandDBFS)) dBFS below -60 dBFS"
        )
    }
    if baseConfig.enRDS && subcarriers.rdsCenterDBFS > subcarriers.rdsBandDBFS - 8.0 {
        warnings.append(
            "RDS center null \(String(format: "%.1f", subcarriers.rdsCenterDBFS)) dBFS is not at least 8 dB below band energy \(String(format: "%.1f", subcarriers.rdsBandDBFS)) dBFS"
        )
    }

    print("")
    print("PLL External-Style Decode")
    print("Tone Hz  Wanted   Xtalk    Sep    RMS     Peak   Corr   S/M")
    print("-------  -------  -------  -----  ------  ------  -----  ----")
    for metric in pllRoundTripMetrics {
        print(
            "\(leftPadded(String(format: "%.0f", metric.toneHz), width: 7))"
                + "  \(leftPadded(String(format: "%.1f", metric.wantedDBFS), width: 7))"
                + "  \(leftPadded(String(format: "%.1f", metric.crosstalkDBFS), width: 7))"
                + "  \(String(format: "%5.1f", metric.separationDB))"
                + "  \(leftPadded(String(format: "%.1f", metric.decodedRMSDBFS), width: 6))"
                + "  \(leftPadded(String(format: "%.1f", metric.decodedPeakDBFS), width: 6))"
                + "  \(String(format: "%5.2f", metric.correlation))"
                + "  \(String(format: "%4.2f", metric.sideToMidRatio))"
        )
    }

    print("")
    print("Ideal Receiver Decode (raw coherent M/S, no receiver filters)")
    print("Separation is scored after ideal side-gain normalization; S-M Delta reports raw side-vs-mono balance.")
    print("Tone Hz  Wanted   Xtalk    Sep    Mono    Side   S-M Delta  Gap vs Prod")
    print("-------  -------  -------  -----  ------  ------  ---------  -----------")
    for metric in idealDecodeMetrics {
        let productionSep = toneMetrics.first(where: { $0.toneHz == metric.toneHz })?.separationDB
            ?? metric.separationDB
        let gap = metric.separationDB - productionSep
        print(
            "\(leftPadded(String(format: "%.0f", metric.toneHz), width: 7))"
                + "  \(leftPadded(String(format: "%.1f", metric.wantedDBFS), width: 7))"
                + "  \(leftPadded(String(format: "%.1f", metric.crosstalkDBFS), width: 7))"
                + "  \(String(format: "%5.1f", metric.separationDB))"
                + "  \(leftPadded(String(format: "%.1f", metric.monoDBFS), width: 6))"
                + "  \(leftPadded(String(format: "%.1f", metric.sideDBFS), width: 6))"
                + "  \(String(format: "%+9.2f", metric.monoSideDeltaDB))"
                + "  \(String(format: "%+11.1f", gap))"
        )
    }

    print("")
    print("Encoder-Side Sidebands (raw MPX, pre-MPXDecoder)")
    print("Tap point: composite output before deemphasis / 15.5 kHz LP / pilot/RDS notches.")
    print("Drive: single-channel sine. Lower/Upper at 38 +/- toneHz. Asymm = |lower-upper|.")
    print("SideSum = |lower|+|upper|. SideDelta = SideSum - Mono (0 dB = perfect DSB-SC balance).")
    print("")
    print("Ch  Tone Hz  Mono     Lower    Upper    Asymm  SideSum  SideDelta")
    print("--  -------  -------  -------  -------  -----  -------  ---------")
    for metric in encoderSidebandMetricsList {
        print(
            "\(padded(metric.drivenChannel, width: 2))"
                + "  \(leftPadded(String(format: "%.0f", metric.toneHz), width: 7))"
                + "  \(leftPadded(String(format: "%.1f", metric.monoDBFS), width: 7))"
                + "  \(leftPadded(String(format: "%.1f", metric.lowerSidebandDBFS), width: 7))"
                + "  \(leftPadded(String(format: "%.1f", metric.upperSidebandDBFS), width: 7))"
                + "  \(String(format: "%5.2f", metric.asymmetryDB))"
                + "  \(leftPadded(String(format: "%.1f", metric.sideSumDBFS), width: 7))"
                + "  \(String(format: "%+8.2f", metric.sideMonoDeltaDB))"
        )
    }

    print("")
    print("Stage-Isolation Sweep (encoder-side, L-only sine, deltas vs baseline)")
    print("SideDelta col: SideSum - Mono (0 dB = balanced DSB-SC).")
    print("Asym col: |lower - upper| sideband dB. Bigger delta-vs-baseline = bigger contribution from that stage.")
    print("")
    print("Stage                          1k Asym  1k SideDel  10k Asym  10k SideDel  14k Asym  14k SideDel")
    print("-----------------------------  -------  ----------  --------  -----------  --------  -----------")
    if let baseline = stageIsolationRows.first {
        for row in stageIsolationRows {
            let a1 = row.metricsByTone[1_000.0]
            let a10 = row.metricsByTone[10_000.0]
            let a14 = row.metricsByTone[14_000.0]
            let label = padded(row.label, width: 29)
            let isBaseline = row.label == baseline.label
            func diffOrAbs(
                _ row: EncoderSidebandMetrics?,
                _ base: EncoderSidebandMetrics?,
                _ keyPath: KeyPath<EncoderSidebandMetrics, Float>
            ) -> String {
                guard let row = row else { return "  -    " }
                let value = row[keyPath: keyPath]
                if isBaseline { return String(format: "%+6.2f ", value) }
                guard let base = base else { return String(format: "%+6.2f ", value) }
                let delta = value - base[keyPath: keyPath]
                return String(format: "%+6.2f ", delta)
            }
            let b1 = baseline.metricsByTone[1_000.0]
            let b10 = baseline.metricsByTone[10_000.0]
            let b14 = baseline.metricsByTone[14_000.0]
            print(
                "\(label)"
                    + "  \(diffOrAbs(a1, b1, \.asymmetryDB))"
                    + "  \(diffOrAbs(a1, b1, \.sideMonoDeltaDB))"
                    + "    \(diffOrAbs(a10, b10, \.asymmetryDB))"
                    + "   \(diffOrAbs(a10, b10, \.sideMonoDeltaDB))"
                    + "    \(diffOrAbs(a14, b14, \.asymmetryDB))"
                    + "   \(diffOrAbs(a14, b14, \.sideMonoDeltaDB))"
            )
        }
    }

    print("")
    print("Mono Compatibility")
    print(
        "Mid \(String(format: "%.1f", mono.midDBFS)) dBFS"
            + "  Side \(String(format: "%.1f", mono.sideDBFS)) dBFS"
            + "  Rejection \(String(format: "%.1f", mono.sideRejectionDB)) dB"
    )
    print(
        "No-pilot MPX: Pilot \(String(format: "%.2f", noPilot.pilotPercent))%"
            + "  Mid \(String(format: "%.1f", noPilot.midDBFS)) dBFS"
            + "  Side \(String(format: "%.1f", noPilot.sideDBFS)) dBFS"
            + "  Rejection \(String(format: "%.1f", noPilot.sideRejectionDB)) dB"
            + "  Corr \(String(format: "%.2f", noPilot.correlation))"
    )

    print("")
    print("Subcarriers")
    print(
        "Pilot \(String(format: "%.2f", subcarriers.pilotPercent))%"
            + "  Phase \(String(format: "%.1f", subcarriers.pilotPhaseDegrees)) deg"
            + "  RDS band \(String(format: "%.1f", subcarriers.rdsBandDBFS)) dBFS"
            + "  center \(String(format: "%.1f", subcarriers.rdsCenterDBFS)) dBFS"
    )

    print("")
    print("Guard-Band Cancellation (clipper driven hard, subcarriers suppressed)")
    print("Depth = residual with guard OFF minus guard ON. Larger = guard removes more clipper IM.")
    print("Guard        Band        Resid ON   Resid OFF  Depth")
    print("-----------  ----------  ---------  ---------  -----")
    print(
        "pilot 17-21  17-21 kHz "
            + "  \(leftPadded(String(format: "%.1f", guardBands.pilotGuardResidualOnDBFS), width: 9))"
            + "  \(leftPadded(String(format: "%.1f", guardBands.pilotGuardResidualOffDBFS), width: 9))"
            + "  \(String(format: "%5.1f", guardBands.pilotGuardDepthDB))"
    )
    print(
        "rds 55-59    55-59 kHz "
            + "  \(leftPadded(String(format: "%.1f", guardBands.rdsGuardResidualOnDBFS), width: 9))"
            + "  \(leftPadded(String(format: "%.1f", guardBands.rdsGuardResidualOffDBFS), width: 9))"
            + "  \(String(format: "%5.1f", guardBands.rdsGuardDepthDB))"
    )
    // Soft floor: an enabled guard that removes essentially nothing is a
    // regression (cancellation FIR misconfigured / mis-aligned). The
    // threshold is deliberately low so this gates true breakage, not the
    // exact depth (the exact number is the human-read / baseline metric).
    if baseConfig.compositeClipperEnabled && baseConfig.compositeClipperCancelPilot
        && guardBands.pilotGuardDepthDB < 3.0 {
        warnings.append(
            "pilot guard cancellation depth \(String(format: "%.1f", guardBands.pilotGuardDepthDB)) dB < 3.0 dB (guard enabled but not removing IM)"
        )
    }
    if baseConfig.compositeClipperEnabled && baseConfig.compositeClipperCancelRDS
        && guardBands.rdsGuardDepthDB < 3.0 {
        warnings.append(
            "RDS guard cancellation depth \(String(format: "%.1f", guardBands.rdsGuardDepthDB)) dB < 3.0 dB (guard enabled but not removing IM)"
        )
    }

    if let lock = pilotRDSLock {
        print("")
        print("Pilot/RDS Phase Lock (RDS 57 kHz must track 3x pilot; drift over the render)")
        print("Render \(String(format: "%.1f", lock.renderSeconds)) s   Pilot early/late deg   RDS early/late deg   Lock drift")
        print(
            "             "
                + "  \(String(format: "%+7.1f", lock.earlyPilotPhaseDeg)) / \(String(format: "%+7.1f", lock.latePilotPhaseDeg))"
                + "   \(String(format: "%+7.1f", lock.earlyRDSPhaseDeg)) / \(String(format: "%+7.1f", lock.lateRDSPhaseDeg))"
                + "   \(String(format: "%+6.2f", lock.lockDriftDeg)) deg"
        )
        // A locked encoder holds RDS at exactly 3x pilot, so the relative
        // phase is flat over the render. Visible drift means the two
        // subcarriers are derived from diverging phase representations.
        if abs(lock.lockDriftDeg) > 3.0 {
            warnings.append(
                "pilot/RDS lock drift \(String(format: "%.2f", lock.lockDriftDeg)) deg over \(String(format: "%.1f", lock.renderSeconds)) s exceeds 3.0 deg (RDS not strictly locked to 3x pilot)"
            )
        }
    }

    // Stored receiver baseline (separate receiver.json): pin the decode
    // separation + subcarrier health so regressions are caught instead of
    // sailing past the loose inline thresholds. tone/pll metrics are indexed
    // by toneFrequencies [1k, 10k, 14k].
    let receiverRecord = ReceiverBaselineRecord(
        coherentSep1k: toneMetrics[0].separationDB,
        coherentSep10k: toneMetrics[1].separationDB,
        coherentSep14k: toneMetrics[2].separationDB,
        pllSep1k: pllRoundTripMetrics[0].separationDB,
        pllSep10k: pllRoundTripMetrics[1].separationDB,
        pllSep14k: pllRoundTripMetrics[2].separationDB,
        noPilotPilotPercent: noPilot.pilotPercent,
        subcarrierPilotPercent: subcarriers.pilotPercent,
        pilotGuardDepthDB: guardBands.pilotGuardDepthDB,
        rdsGuardDepthDB: guardBands.rdsGuardDepthDB
    )
    let receiverBaselineURL = defaultReceiverBaselinePath()
    var receiverDrift: [BaselineDriftFinding] = []
    var captureNote: String?
    if captureBaseline {
        let file = ReceiverBaselineFile(
            schemaVersion: ReceiverBaselineFile.currentSchemaVersion,
            capturedAt: verifierBaselineTimestampNow(),
            configPath: configPath,
            renderSampleRateHz: Int(baseConfig.sampleRate),
            metrics: receiverRecord
        )
        do {
            try saveReceiverBaseline(file, to: receiverBaselineURL)
            captureNote = "Receiver baseline captured: \(receiverBaselineURL.path)"
        } catch {
            captureNote = "Receiver baseline capture FAILED: \(error)"
        }
    } else if FileManager.default.fileExists(atPath: receiverBaselineURL.path) {
        do {
            let stored = try loadReceiverBaseline(from: receiverBaselineURL)
            receiverDrift = compareReceiverMetrics(measured: receiverRecord, baseline: stored.metrics)
        } catch {
            print("Receiver baseline: failed to load (\(error))")
        }
    }

    print("")
    print("Assessment")
    if !notes.isEmpty {
        print("Receiver notes:")
        for note in notes { print("- \(note)") }
    }
    if let captureNote { print(captureNote) }
    if !receiverDrift.isEmpty {
        print("Receiver baseline drift (\(receiverDrift.count) finding\(receiverDrift.count == 1 ? "" : "s")):")
        for finding in receiverDrift { print("- \(finding.formattedLine)") }
    }
    if !warnings.isEmpty {
        print("Receiver warnings:")
        for warning in warnings { print("- \(warning)") }
    }

    // Exit code, mirroring the composite path: stored-baseline drift is a hard
    // WARN (2) under --baseline-strict, else TIGHT (1); inline warnings are
    // TIGHT (1); otherwise PASS (0).
    if !receiverDrift.isEmpty {
        if strictBaseline {
            print("Result: WARN - stored receiver-baseline drift in --baseline-strict mode.")
            return 2
        }
        print("Result: TIGHT - receiver-baseline drift detected (use --baseline-strict to fail the run).")
        return 1
    }
    if !warnings.isEmpty {
        print("Result: TIGHT - receiver-model checks need review.")
        return 1
    }
    print("Result: OK - receiver-model decode checks passed.")
    return 0
}

func runVerificationHarness(
    configPath: String,
    durationSeconds: Double,
    presetSweep: Bool = false,
    longRun: Bool = false,
    receiverModel: Bool = false,
    compositeMultibandClipperComparison: Bool = false,
    multibandCouplingComparison: Bool = false,
    captureBaseline: Bool = false,
    strictBaseline: Bool = false
) throws -> Int32 {
    let config = try AppConfig.load(fromINI: configPath)
    if multibandCouplingComparison {
        print("MPX Prime Multiband Coupling Verification")
        print("Config: \(configPath)")
        print(
            "Render: \(Int(config.sampleRate)) Hz - Duration \(String(format: "%.1f", max(1.0, durationSeconds))) s"
        )
        print("")
        return runMultibandCouplingComparison(
            baseConfig: config,
            durationSeconds: durationSeconds
        )
    }
    if compositeMultibandClipperComparison {
        print("MPX Prime Composite Multiband Verification")
        print("Config: \(configPath)")
        print(
            "Render: \(Int(config.sampleRate)) Hz - Duration \(String(format: "%.1f", max(1.0, durationSeconds))) s"
        )
        print("")
        return runCompositeMultibandClipperComparison(
            baseConfig: config,
            durationSeconds: durationSeconds
        )
    }
    if receiverModel {
        print("MPX Prime Receiver Verification")
        print("Config: \(configPath)")
        print(
            "Render: \(Int(config.sampleRate)) Hz • Duration \(String(format: "%.1f", max(1.0, durationSeconds))) s"
        )
        print("")
        return runReceiverModelVerification(
            baseConfig: config,
            configPath: configPath,
            durationSeconds: durationSeconds,
            captureBaseline: captureBaseline,
            strictBaseline: strictBaseline
        )
    }
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
                let loaded = try loadVerifierBaseline(from: baselineURL)
                loadedBaseline = loaded
                print("Baseline: \(baselineURL.lastPathComponent) (captured \(loaded.capturedAt))")
            } catch {
                print("Baseline: failed to load (\(error))")
            }
        } else {
            print("Baseline: none — run with --capture-baseline to create.")
        }
    }

    print("")
    print(
        "Scenario              Peak dBFS  Dev kHz  LimGR  SafeGR  AudioPk  POvr   Bdg  Pilot  RDS   Margin  AGC"
    )
    print(
        "--------------------  ---------  -------  -----  ------  -------  -----  ---  -----  ----  ------  ----"
    )

    var worstPeak: Float = 0.0
    var worstSafety: Float = 0.0
    var worstMargin: Float = .greatestFiniteMagnitude
    var worstPostInjectionOvershoot: Float = 0.0
    var worstTruePeakOvershootDB: Float = 0.0
    var anyOverBudget = false
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
        worstPostInjectionOvershoot = max(worstPostInjectionOvershoot, metrics.maxPostInjectionOvershoot)
        worstTruePeakOvershootDB = max(worstTruePeakOvershootDB, truePeakOvershootDB(metrics: metrics))
        anyOverBudget = anyOverBudget || metrics.overBudget
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
            + "  \(String(format: "%5.4f", metrics.maxPostInjectionOvershoot))"
            + "  \(metrics.overBudget ? "YES" : " no")"
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
            uniqueKeysWithValues: scenarioMetrics.map { scenario, metrics in
                (scenario.name, buildBaselineRecord(
                    metrics: metrics,
                    targetDeviationKHz: config.mpxDeviationKHz
                ))
            }
        )
        // Encoder-side sideband fingerprint: computed only when capturing
        // or when there is a stored fingerprint to compare against, so a
        // plain `--verify` with no baseline doesn't pay the extra renders.
        let needSidebands = captureBaseline || (loadedBaseline?.encoderSidebands != nil)
        let sidebandDuration = max(0.75, min(durationSeconds, 1.0))
        let measuredSidebands: EncoderSidebandBaselineRecord? = needSidebands
            ? buildEncoderSidebandBaseline(config: config, durationSeconds: sidebandDuration)
            : nil

        if captureBaseline {
            let file = VerifierBaselineFile(
                schemaVersion: VerifierBaselineFile.currentSchemaVersion,
                capturedAt: verifierBaselineTimestampNow(),
                configPath: configPath,
                renderSampleRateHz: Int(config.sampleRate),
                blockSize: config.blockSize,
                durationSeconds: durationSeconds,
                scenarios: measured,
                encoderSidebands: measuredSidebands
            )
            do {
                try saveVerifierBaseline(file, to: baselineURL)
                print("")
                print("Baseline captured: \(baselineURL.path)")
                print("  \(measured.count) scenarios written.")
                if measuredSidebands != nil {
                    print("  encoder sideband fingerprint written (1/10/14 kHz).")
                }
            } catch {
                print("")
                print("Baseline capture FAILED: \(error)")
            }
        } else if let baseline = loadedBaseline {
            baselineDrift = compareBaseline(measured: measured, baseline: baseline)
            if let storedSidebands = baseline.encoderSidebands,
                let measuredSidebands = measuredSidebands {
                baselineDrift.append(contentsOf: compareEncoderSidebands(
                    measured: measuredSidebands,
                    baseline: storedSidebands
                ))
            }
        }
    }

    print("")
    print("Assessment")
    print("Worst MPX peak: \(dbfsString(worstPeak)) dBFS")
    print("Worst safety limiter GR: \(String(format: "%.1f", nonNegative(worstSafety))) dB")
    print("Worst composite margin: \(String(format: "%.1f", worstMargin)) dB")
    print("Worst post-injection overshoot: \(String(format: "%.6f", worstPostInjectionOvershoot))")
    print("Worst inter-sample (4x true-peak) overshoot: \(String(format: "%.2f", worstTruePeakOvershootDB)) dB")
    print("Composite budget exceeded: \(anyOverBudget ? "yes" : "no")")

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
    } else if anyOverBudget || worstPostInjectionOvershoot > 1e-4 { naturalResult = 2
    } else if worstSafety > 1.0 { naturalResult = 2
    } else if worstMargin < -0.25 { naturalResult = 2
    } else if worstMargin < 0.0 || worstSafety > 0.25 { naturalResult = 1
    } else { naturalResult = 0 }

    let result: Int32
    if baselineDrift.isEmpty { result = naturalResult } else if strictBaseline { result = 2 } else { result = max(naturalResult, 1) }

    switch result {
    case 2:
        if strictBaseline && !baselineDrift.isEmpty {
            print("Result: WARN - stored-baseline drift in --baseline-strict mode.")
        } else if worstSafety > 1.0 {
            print("Result: WARN - safety limiter is doing significant work.")
        } else if anyOverBudget || worstPostInjectionOvershoot > 1e-4 {
            print("Result: WARN - post-injection composite budget exceeded.")
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
