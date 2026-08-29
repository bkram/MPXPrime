#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
import Foundation
import MPXPrimeCore

struct StereoSignalMetrics {
    var rms: Float = 0.0
    var peak: Float = 0.0
    var correlation: Float = 0.0
    var sideToMidRatio: Float = 0.0
}

struct AudioBandRMSMetrics {
    var lowDBFS: Float = -160.0
    var midDBFS: Float = -160.0
    var highDBFS: Float = -160.0
}

struct MPXBandwidthMetrics {
    var occupied999Hz: Float = 0.0
    var above60kRatioDB: Float = -160.0
    var above67kRatioDB: Float = -160.0
}

struct VerificationMetrics {
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

struct VerificationScenario {
    let name: String
    let description: String
    let quality: QualityExpectations
    let sample: (_ frameIndex: Int, _ sampleRate: Double) -> (Float, Float)
}

struct QualityExpectations {
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

struct VerificationPresetSweep {
    let id: String
    let title: String
    let apply: (inout AppConfig) -> Void
}

struct LongRunSignatureReference {
    let peakDBFS: Float
    let minMarginDB: Float
    let outCorrelation: Float
    let occ999Hz: Float
    let above60kRatioDB: Float
}

struct ToneVector {
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

struct ReceiverToneMetrics {
    let toneHz: Double
    let wantedDBFS: Float
    let crosstalkDBFS: Float
    let separationDB: Float
}

struct ReceiverMonoMetrics {
    let midDBFS: Float
    let sideDBFS: Float
    let sideRejectionDB: Float
}

struct ReceiverPLLRoundTripMetrics {
    let toneHz: Double
    let wantedDBFS: Float
    let crosstalkDBFS: Float
    let separationDB: Float
    let decodedRMSDBFS: Float
    let decodedPeakDBFS: Float
    let correlation: Float
    let sideToMidRatio: Float
}

struct ReceiverIdealDecodeMetrics {
    let toneHz: Double
    let wantedDBFS: Float
    let crosstalkDBFS: Float
    let separationDB: Float
    let monoDBFS: Float
    let sideDBFS: Float
    let monoSideDeltaDB: Float
}

struct ReceiverNoPilotMetrics {
    let pilotPercent: Float
    let midDBFS: Float
    let sideDBFS: Float
    let sideRejectionDB: Float
    let correlation: Float
}

struct ReceiverSubcarrierMetrics {
    let pilotPercent: Float
    let pilotPhaseDegrees: Float
    let rdsBandDBFS: Float
    let rdsCenterDBFS: Float
}

struct ReceiverToneAnalysis {
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
struct EncoderSidebandMetrics {
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

struct DeterministicNoise {
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

func verificationScenarios() -> [VerificationScenario] {
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

func longRunVerificationScenarios() -> [VerificationScenario] {
    verificationScenarios().filter {
        ["program_mix", "bright_dense", "vocal_sibilant", "transient_push", "wide_bass"]
            .contains($0.name)
    }
}

// Long-run signature references: the expected 30 s per-scenario fingerprint
// of the CURRENT chain against macOS/Verification.ini. Unlike the schema-3
// composite baseline (default.json, recaptured via --capture-baseline), this
// table is maintained by hand -- and it had NOT been recaptured since 0.11
// while the chain moved deliberately through 0.20 (differential clipper
// topology), 0.35 (host-rate guard cancellation), 0.36 (pilot/RDS phase
// lock)... so --verify-long sat at TIGHT on pure staleness. Recaptured
// 2026-08-01 (0.43) from a canonical repo-root run; every intervening chain
// change was gated by --verify --baseline-strict, so these values describe
// the accepted chain, not an unreviewed drift. RECAPTURE THIS TABLE whenever
// a deliberate chain change moves the long-run report: run
// `swift run --package-path macOS MPXPrime --verify-long --seconds 30` from
// the repo root and copy the per-scenario Peak/Margin/OutCorr/Occ999/>60k
// values.
func longRunSignatureReferences() -> [String: LongRunSignatureReference] {
    [
        "program_mix": LongRunSignatureReference(
            peakDBFS: -0.85,
            minMarginDB: 0.8,
            outCorrelation: 0.83,
            occ999Hz: 57_625.0,
            above60kRatioDB: -90.1
        ),
        "bright_dense": LongRunSignatureReference(
            peakDBFS: -0.38,
            minMarginDB: 0.3,
            outCorrelation: 0.05,
            occ999Hz: 57_558.0,
            above60kRatioDB: -60.6
        ),
        "vocal_sibilant": LongRunSignatureReference(
            peakDBFS: -0.42,
            minMarginDB: 0.3,
            outCorrelation: 0.64,
            occ999Hz: 57_876.0,
            above60kRatioDB: -69.6
        ),
        "transient_push": LongRunSignatureReference(
            peakDBFS: -0.15,
            minMarginDB: 0.4,
            outCorrelation: 0.76,
            occ999Hz: 58_121.0,
            above60kRatioDB: -61.7
        ),
        "wide_bass": LongRunSignatureReference(
            peakDBFS: -2.21,
            minMarginDB: 1.7,
            outCorrelation: -0.41,
            occ999Hz: 57_964.0,
            above60kRatioDB: -88.1
        )
    ]
}

func verifyScenario(
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

func dbfsString(_ linear: Float) -> String {
    guard linear > 1e-9 else { return "-inf" }
    return String(format: "%.2f", 20.0 * log10(Double(linear)))
}

/// 4x-oversampled true-peak of a composite sample array (offline,
/// ITU-R BS.1770-style inter-sample peak detection). The composite is
/// band-limited to ~60 kHz, well below the 96 kHz Nyquist at 192 kHz, so
/// a windowed-sinc fractional-delay interpolator reconstructs inter-sample
/// peaks faithfully. Returns both the true-peak and the plain sample-peak
/// so callers can report the overshoot (true minus sample).
func truePeak4x(_ samples: [Float]) -> (truePeak: Float, samplePeak: Float) {
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

func dbfs(_ linear: Double) -> Float {
    guard linear > 1e-12 else { return -240.0 }
    return Float(20.0 * log10(linear))
}

func dbfsValue(_ linear: Float) -> Float {
    guard linear > 1e-9 else { return -160.0 }
    return Float(20.0 * log10(Double(linear)))
}

func ratioDB(_ numerator: Float, _ denominator: Float) -> Float {
    guard numerator > 1e-9, denominator > 1e-9 else { return 0.0 }
    return Float(20.0 * log10(Double(numerator / denominator)))
}

func deviationString(peakAbs: Float, targetDeviationKHz: Double) -> String {
    String(format: "%.1f", Double(peakAbs) * max(1.0, targetDeviationKHz))
}

func padded(_ text: String, width: Int) -> String {
    if text.count >= width {
        return String(text.prefix(width))
    }
    return text + String(repeating: " ", count: width - text.count)
}

func leftPadded(_ text: String, width: Int) -> String {
    if text.count >= width {
        return String(text.suffix(width))
    }
    return String(repeating: " ", count: width - text.count) + text
}

func nonNegative(_ value: Float) -> Float {
    if value <= 0.0005 {
        return 0.0
    }
    return value
}

func ratioString(_ value: Float, width: Int) -> String {
    guard value.isFinite else { return leftPadded("inf", width: width) }
    if value >= 99.95 {
        return leftPadded("99+", width: width)
    }
    return leftPadded(String(format: "%.2f", value), width: width)
}

func buildBaselineRecord(
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
func truePeakOvershootDB(metrics: VerificationMetrics) -> Float {
    guard metrics.truePeakAbs > 1e-9, metrics.peakAbs > 1e-9 else { return 0.0 }
    return max(0.0, Float(20.0 * log10(Double(metrics.truePeakAbs) / Double(metrics.peakAbs))))
}

/// Captures the encoder-side sideband fingerprint (L-only tone drive at
/// 1 / 10 / 14 kHz) for the baseline. Reuses the same per-tone
/// `encoderSidebandMetrics` measurement the receiver model prints, so a
/// `--baseline-strict` run gates the exact numbers a human reads in
/// `--verify-receiver`.
func buildEncoderSidebandBaseline(
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
