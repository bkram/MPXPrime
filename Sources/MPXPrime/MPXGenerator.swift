// Platform split: on macOS these resolve to the real Accelerate / Darwin /
// os modules (numerics and locking untouched); on Linux the
// MPXPrimeAcceleration shim provides same-name vDSP/vvtanhf functions and an
// OSAllocatedUnfairLock polyfill, and Glibc provides libm.
#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
import Atomics
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import MPXPrimeCore
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession/URLRequest on Linux corelibs
#endif
#if canImport(os)
import os
#endif

final class MPXGenerator {
    struct AnalysisBuffers {
        let postAGCLeft: UnsafeMutablePointer<Float>?
        let postAGCRight: UnsafeMutablePointer<Float>?
        let preMPXLeft: UnsafeMutablePointer<Float>?
        let preMPXRight: UnsafeMutablePointer<Float>?

        static var none: AnalysisBuffers {
            AnalysisBuffers(
                postAGCLeft: nil,
                postAGCRight: nil,
                preMPXLeft: nil,
                preMPXRight: nil
            )
        }
    }

    struct AGCStatus {
        let enabled: Bool
        let detectorDB: Float
        let gainDB: Float
        let gateActive: Bool
    }

    struct AdvancedDynamicsStatus {
        let enabled: Bool
        /// Per-band leveler gains in dB, low to high (5 bands).
        let bandGainsDB: (Float, Float, Float, Float, Float)
        let densityDB: Float
    }

    struct FinalLimiterStatus {
        let enabled: Bool
        let gainReductionDB: Float
        let preEncodeGainReductionDB: Float
        let safetyGainReductionDB: Float
        /// How far (dB) the audio composite exceeded the budget and had to be
        /// caught by the 1x safety soft clip, as a 250 ms decaying peak. Should
        /// read 0.0 with the clipper + final limiter on; anything else means the
        /// shaper is doing peak control (the distortion class fixed in 0.45).
        let safetyClipDB: Float
        /// Composite-clipper look-ahead gain reduction in dB. Reported
        /// separately from `gainReductionDB` so operators can distinguish
        /// predictive shaving (clean) from soft-clip shaving (distortion).
        let compositeLookaheadGainReductionDB: Float
    }

    struct CompositeCalibrationStatus {
        let pilotPercent: Float
        let rdsPercent: Float
        let audioPeak: Float
        let budgetMarginDB: Float
        /// Post-injection overshoot envelope: the maximum amount by
        /// which `audioComposite·outputGain + subcarriers·outputGain`
        /// exceeds the ±1.0 clamp at the final MPX output, decayed at
        /// ~50 ms. Should be 0.0 in normal operation — non-zero means
        /// pilot/RDS subcarriers are being clipped at the final clamp,
        /// destroying the constant-amplitude invariant. Operationally
        /// reportable as a warning condition.
        let postInjectionOvershoot: Float
        /// True when the composite budget governor has been forced to
        /// mute audio (audio composite ceiling reached 0) because
        /// `outputGain × subcarrier reservation` left no headroom.
        /// Audio is silenced but pilot/RDS keep operator-chosen
        /// amplitude — the chain is "valid but useless"; UI should
        /// surface this as a config error.
        let overBudget: Bool
    }

    private struct FinalCompositeThresholds {
        let effectiveThreshold: Float
        /// The audio-composite budget: the ceiling every audio-path peak stage is referenced to.
        let audioCeiling: Float
        /// True when the operator's outputGain × subcarrier reservation
        /// leaves no real headroom for audio composite (audio ceiling
        /// has been forced to ≤0). The chain still produces sensible
        /// output (audio muted, subcarriers preserved at operator-
        /// chosen amplitude), but the operator should reduce
        /// outputGain or subcarrier levels to recover audio.
        let overBudget: Bool
    }

    /// Composite-budget safety margin. The audio-composite ceiling is
    /// computed as `effectiveThreshold - reserved - safetyMargin`, where
    /// `effectiveThreshold = threshold x min(1, deviation / 75 kHz) /
    /// outputGain`, `reserved` is the pilot+RDS peak reservation and the
    /// margin is scaled exactly like the threshold. This leaves ~2% of the
    /// budget unallocated as headroom against numerical jitter and the
    /// limiter's Float rounding. The final post-injection clamp is the
    /// last-resort numeric guard; it should never engage for valid configs.
    private static let finalCompositeBudgetSafetyMargin: Float = 0.02

    private struct EncoderComplianceConfig {
        let programLowpassHz: Float
        let encoderLowpassHz: Float
        let hfGuardCrossoverHz: Float
    }

    struct RuntimeConfig: Equatable {
        let inputGainDB: Float
        let outputGainDB: Float
        /// Line output calibration (dBFS at 100% modulation); consumed by
        /// the audio engines at the DAC write, not by the generator.
        let mpxLineOutputDBFS: Float
        /// The operator's listening output. Consumed by the audio engine (it
        /// owns the second device), not by the generator -- carried here for
        /// the same reason as the line output above: it is what makes
        /// `ConfigPatch` DERIVE a live disposition for these keys instead of
        /// calling a monitor change restart-class.
        let monitorEnabled: Bool
        let monitorDeviceUID: String
        /// INI spelling of the monitor's device channels ("" = 1, 2); here
        /// so a channel change on the monitor is live like its device.
        let monitorChannels: String
        let monitorGainDB: Float
        /// 19 kHz pilot injection as a fraction of full deviation (0.08 = 8%).
        /// Live-applied as a gain on the pilot oscillator; no restart needed.
        let pilotLevel: Float
        let finalDriveDB: Float
        let widebandAGCEnabled: Bool
        let widebandAGCTargetDB: Float
        let widebandAGCMaxGainDB: Float
        let widebandAGCMinGainDB: Float
        let widebandAGCAttackMS: Float
        let widebandAGCReleaseMS: Float
        let widebandAGCKWeightingEnabled: Bool
        let widebandAGCReleaseProgramDependent: Bool
        let widebandAGCBassDesensitizeEnabled: Bool
        let preEncodeAudioLimiterEnabled: Bool
        let preEncodeThreshold: Float
        let preEncodeReleaseMS: Float
        let preEncodeBandlimitedResidualEnabled: Bool
        let preEncodeBandlimitedResidualTapCount: Int
        let preEncodeBandlimitedResidualCutoffFraction: Float
        let mpxDeviationKHz: Float
        let primeBassEnabled: Bool
        let primeBassAmount: Float
        let primeBassHarmonics: Float
        let primeBassDrive: Float
        let primeBassDensity: Float
        let primeBassSubharmonicsEnabled: Bool
        let primeBassSubharmonicsAmount: Float
        let primeBassFreqHz: Float
        let monoBassEnabled: Bool
        let monoBassFreqHz: Float
        let multibandEnabled: Bool
        let multibandMode: Int
        let multibandMakeupDB: Float
        let multibandKneeDB: Float
        let multibandLinkStrength: Float
        let multibandReleaseProgramDependent: Bool
        let multibandTransientAwareAttackEnabled: Bool
        let multibandInterBandCouplingEnabled: Bool
        let multibandX1Hz: Float
        let multibandX2Hz: Float
        let multibandX3Hz: Float
        let multibandX4Hz: Float
        let multibandLowThresholdDB: Float
        let multibandMidThresholdDB: Float
        let multibandHighThresholdDB: Float
        let multibandLowRatio: Float
        let multibandMidRatio: Float
        let multibandHighRatio: Float
        let multibandLowAttackMS: Float
        let multibandMidAttackMS: Float
        let multibandHighAttackMS: Float
        let multibandLowReleaseMS: Float
        let multibandMidReleaseMS: Float
        let multibandHighReleaseMS: Float
        // Advanced Dynamics single-stage leveler (replaces AGC+multiband
        // when enabled; experimental, default off).
        let advancedDynamicsEnabled: Bool
        let advancedDynamicsTargetDB: Float
        let advancedDynamicsLowOffsetDB: Float
        let advancedDynamicsMidOffsetDB: Float
        let advancedDynamicsHighOffsetDB: Float
        let advancedDynamicsMaxGainDB: Float
        let advancedDynamicsDensity: Float
        let advancedDynamicsSpeed: Float
        let phaseRotationEnabled: Bool
        let phaseRotationFreqHz: Float
        let parametricEQEnabled: Bool
        // Bands 1 and 4 are shelves (no Q control); bands 2 and 3 are peaking.
        let peqB1FreqHz: Float
        let peqB1GainDB: Float
        let peqB2FreqHz: Float
        let peqB2GainDB: Float
        let peqB2Q: Float
        let peqB3FreqHz: Float
        let peqB3GainDB: Float
        let peqB3Q: Float
        let peqB4FreqHz: Float
        let peqB4GainDB: Float
        let multibandLimiterEnabled: Bool
        let multibandLimiterThresholdDB: Float
        let multibandLimiterAttackMS: Float
        let multibandLimiterReleaseMS: Float
        let downwardExpanderEnabled: Bool
        let expanderThresholdDB: Float
        let expanderRatio: Float
        let expanderAttackMS: Float
        let expanderReleaseMS: Float
        let bassClipperEnabled: Bool
        let bassClipperCrossoverHz: Float
        let bassClipperThresholdDB: Float
        let bassClipperDrive: Float
        let hfLimiterEnabled: Bool
        let hfLimiterThresholdDB: Float
        let hfLimiterTopThresholdDB: Float
        let hfLimiterAttackMS: Float
        let hfLimiterReleaseMS: Float
        let hfLimiterMaxReductionDB: Float
        let dcClipperEnabled: Bool
        let dcClipperCeilingDB: Float
        let dcClipperCancelFreqHz: Float
        let processedAudioCoderHasClipper: Bool
        let processedAudioFinalClipDriveDB: Float
        let processedAudioCeilingDBTP: Float
        let amPositivePeakPct: Float
        let bs412Enabled: Bool
        let bs412CeilingDBr: Float
        let compositeClipperEnabled: Bool
        let compositeClipperThresholdDB: Float
        let compositeClipperCeilingDB: Float
        let compositeClipperCancelAudio: Bool
        let compositeClipperStereoGuard: Float
        let compositeClipperCancelPilot: Bool
        let compositeClipperCancelRDS: Bool
        let compositeClipperLookaheadMS: Float
        let compositeClipperOversampling: Int
        // SSB Stereo encoder (SSB-leaning stereo encoding) (experimental, default off).
        let ssbStereoEnabled: Bool
        let ssbStereoAmount: Float

        // Tone-generator parameters. Live-applicable so the Test Tone
        // tab can toggle source / type / freq / mode / level without
        // restarting the engine.
        let sourceMode: String        // "input" | "tone"
        let testToneType: String      // "sine" | "pink" | "white"
        let testToneMode: String      // "mono" | "stereo" | "left" | "right"
        let testToneFreq: Float
        let testToneLevelDB: Float
    }

    /// Factory: convert AppConfig → RuntimeConfig. Used by
    /// AudioOutputEngine.applyRuntimeConfig and shared with tests so
    /// runtime live-apply semantics can be exercised end-to-end.
    static func makeRuntimeConfig(from config: AppConfig) -> RuntimeConfig {
        RuntimeConfig(
            inputGainDB: Float(config.inputGainDB),
            outputGainDB: Float(config.outputGainDB),
            mpxLineOutputDBFS: Float(config.mpxLineOutputDBFS),
            monitorEnabled: config.monitorEnabled,
            monitorDeviceUID: config.monitorDeviceUID ?? "",
            monitorChannels: AppConfig.channelsINIValue(config.monitorChannels),
            monitorGainDB: Float(config.monitorGainDB),
            pilotLevel: Float(config.pilotLevel),
            finalDriveDB: Float(config.finalDriveDB),
            widebandAGCEnabled: config.widebandAGCEnabled,
            widebandAGCTargetDB: Float(config.widebandAGCTargetDB),
            widebandAGCMaxGainDB: Float(config.widebandAGCMaxGainDB),
            widebandAGCMinGainDB: Float(config.widebandAGCMinGainDB),
            widebandAGCAttackMS: Float(config.widebandAGCAttackMS),
            widebandAGCReleaseMS: Float(config.widebandAGCReleaseMS),
            widebandAGCKWeightingEnabled: config.widebandAGCKWeightingEnabled,
            widebandAGCReleaseProgramDependent: config.widebandAGCReleaseProgramDependent,
            widebandAGCBassDesensitizeEnabled: config.widebandAGCBassDesensitizeEnabled,
            preEncodeAudioLimiterEnabled: config.preEncodeAudioLimiterEnabled,
            preEncodeThreshold: Float(config.preEncodeThreshold),
            preEncodeReleaseMS: Float(config.preEncodeReleaseMS),
            preEncodeBandlimitedResidualEnabled: config.preEncodeBandlimitedResidualEnabled,
            preEncodeBandlimitedResidualTapCount: config.preEncodeBandlimitedResidualTapCount,
            preEncodeBandlimitedResidualCutoffFraction: Float(config.preEncodeBandlimitedResidualCutoffFraction),
            mpxDeviationKHz: Float(config.mpxDeviationKHz),
            primeBassEnabled: config.primeBassEnabled,
            primeBassAmount: Float(config.primeBassAmount),
            primeBassHarmonics: Float(config.primeBassHarmonics),
            primeBassDrive: Float(config.primeBassDrive),
            primeBassDensity: Float(config.primeBassDensity),
            primeBassSubharmonicsEnabled: config.primeBassSubharmonicsEnabled,
            primeBassSubharmonicsAmount: Float(config.primeBassSubharmonicsAmount),
            primeBassFreqHz: Float(config.primeBassFreqHz),
            monoBassEnabled: config.monoBassEnabled,
            monoBassFreqHz: Float(config.monoBassFreqHz),
            multibandEnabled: config.multibandEnabled,
            multibandMode: config.multibandMode,
            multibandMakeupDB: Float(config.multibandMakeupDB),
            multibandKneeDB: Float(config.multibandKneeDB),
            multibandLinkStrength: Float(config.multibandLinkStrength),
            multibandReleaseProgramDependent: config.multibandReleaseProgramDependent,
            multibandTransientAwareAttackEnabled: config.multibandTransientAwareAttackEnabled,
            multibandInterBandCouplingEnabled: config.multibandInterBandCouplingEnabled,
            multibandX1Hz: Float(config.multibandX1Hz),
            multibandX2Hz: Float(config.multibandX2Hz),
            multibandX3Hz: Float(config.multibandX3Hz),
            multibandX4Hz: Float(config.multibandX4Hz),
            multibandLowThresholdDB: Float(config.multibandLowThresholdDB),
            multibandMidThresholdDB: Float(config.multibandMidThresholdDB),
            multibandHighThresholdDB: Float(config.multibandHighThresholdDB),
            multibandLowRatio: Float(config.multibandLowRatio),
            multibandMidRatio: Float(config.multibandMidRatio),
            multibandHighRatio: Float(config.multibandHighRatio),
            multibandLowAttackMS: Float(config.multibandLowAttackMS),
            multibandMidAttackMS: Float(config.multibandMidAttackMS),
            multibandHighAttackMS: Float(config.multibandHighAttackMS),
            multibandLowReleaseMS: Float(config.multibandLowReleaseMS),
            multibandMidReleaseMS: Float(config.multibandMidReleaseMS),
            multibandHighReleaseMS: Float(config.multibandHighReleaseMS),
            advancedDynamicsEnabled: config.advancedDynamicsEnabled,
            advancedDynamicsTargetDB: Float(config.advancedDynamicsTargetDB),
            advancedDynamicsLowOffsetDB: Float(config.advancedDynamicsLowOffsetDB),
            advancedDynamicsMidOffsetDB: Float(config.advancedDynamicsMidOffsetDB),
            advancedDynamicsHighOffsetDB: Float(config.advancedDynamicsHighOffsetDB),
            advancedDynamicsMaxGainDB: Float(config.advancedDynamicsMaxGainDB),
            advancedDynamicsDensity: Float(config.advancedDynamicsDensity),
            advancedDynamicsSpeed: Float(config.advancedDynamicsSpeed),
            phaseRotationEnabled: config.phaseRotationEnabled,
            phaseRotationFreqHz: Float(config.phaseRotationFreqHz),
            parametricEQEnabled: config.parametricEQEnabled,
            peqB1FreqHz: Float(config.peqB1FreqHz),
            peqB1GainDB: Float(config.peqB1GainDB),
            peqB2FreqHz: Float(config.peqB2FreqHz),
            peqB2GainDB: Float(config.peqB2GainDB),
            peqB2Q: Float(config.peqB2Q),
            peqB3FreqHz: Float(config.peqB3FreqHz),
            peqB3GainDB: Float(config.peqB3GainDB),
            peqB3Q: Float(config.peqB3Q),
            peqB4FreqHz: Float(config.peqB4FreqHz),
            peqB4GainDB: Float(config.peqB4GainDB),
            multibandLimiterEnabled: config.multibandLimiterEnabled,
            multibandLimiterThresholdDB: Float(config.multibandLimiterThresholdDB),
            multibandLimiterAttackMS: Float(config.multibandLimiterAttackMS),
            multibandLimiterReleaseMS: Float(config.multibandLimiterReleaseMS),
            downwardExpanderEnabled: config.downwardExpanderEnabled,
            expanderThresholdDB: Float(config.expanderThresholdDB),
            expanderRatio: Float(config.expanderRatio),
            expanderAttackMS: Float(config.expanderAttackMS),
            expanderReleaseMS: Float(config.expanderReleaseMS),
            bassClipperEnabled: config.bassClipperEnabled,
            bassClipperCrossoverHz: Float(config.bassClipperCrossoverHz),
            bassClipperThresholdDB: Float(config.bassClipperThresholdDB),
            bassClipperDrive: Float(config.bassClipperDrive),
            hfLimiterEnabled: config.hfLimiterEnabled,
            hfLimiterThresholdDB: Float(config.hfLimiterThresholdDB),
            hfLimiterTopThresholdDB: Float(config.hfLimiterTopThresholdDB),
            hfLimiterAttackMS: Float(config.hfLimiterAttackMS),
            hfLimiterReleaseMS: Float(config.hfLimiterReleaseMS),
            hfLimiterMaxReductionDB: Float(config.hfLimiterMaxReductionDB),
            dcClipperEnabled: config.dcClipperEnabled,
            dcClipperCeilingDB: Float(config.dcClipperCeilingDB),
            dcClipperCancelFreqHz: Float(config.dcClipperCancelFreqHz),
            processedAudioCoderHasClipper: config.processedAudioCoderHasClipper,
            processedAudioFinalClipDriveDB: Float(config.processedAudioFinalClipDriveDB),
            processedAudioCeilingDBTP: Float(config.processedAudioCeilingDBTP),
            amPositivePeakPct: Float(config.amPositivePeakPct),
            bs412Enabled: config.bs412Enabled,
            bs412CeilingDBr: Float(config.bs412CeilingDBr),
            compositeClipperEnabled: config.compositeClipperEnabled,
            compositeClipperThresholdDB: Float(config.compositeClipperThresholdDB),
            compositeClipperCeilingDB: Float(config.compositeClipperCeilingDB),
            compositeClipperCancelAudio: config.compositeClipperCancelAudio,
            compositeClipperStereoGuard: Float(config.compositeClipperStereoGuard),
            compositeClipperCancelPilot: config.compositeClipperCancelPilot,
            compositeClipperCancelRDS: config.compositeClipperCancelRDS,
            compositeClipperLookaheadMS: Float(config.compositeClipperLookaheadMS),
            compositeClipperOversampling: config.compositeClipperOversampling,
            ssbStereoEnabled: config.ssbStereoEnabled,
            ssbStereoAmount: Float(config.ssbStereoAmount),
            sourceMode: config.sourceMode,
            testToneType: config.testToneType,
            testToneMode: config.testToneMode,
            testToneFreq: Float(config.testToneFreq),
            testToneLevelDB: Float(config.testToneLevelDB)
        )
    }

    /// Runtime-applicable RDS state. Anything an operator can change
    /// without restarting transport flows through this struct. The
    /// only RDS settings NOT here are physical-layer (subcarrier
    /// frequency, Gaussian shaping FIR, RDS injection level) — those
    /// touch DSP allocation and stay restart-only.
    struct RDSRuntimeConfig: Equatable {
        // Master + injection. `var` only so the engine can gate it off in a
        // mode that carries no composite (see `applyRDSRuntimeConfig`); the
        // factory never varies it by mode.
        var enabled: Bool

        // Identification
        let pi: Int
        let pty: Int
        let ptynText: String
        let ptynEnabled: Bool
        let ptynCentered: Bool
        let eccCode: Int
        let licCode: Int
        let pinCode: Int

        // Flags (operationally toggled)
        let tp: Bool
        let ta: Bool
        let ms: Bool
        let diStereo: Bool
        let diHead: Bool
        let diComp: Bool
        let diDyn: Bool

        // Program Service
        let psBanks: [String]        // 4 PS text banks (A, B, C, D)
        let psActiveBank: String     // "A" / "B" / "C" / "D"
        let psCentered: Bool
        let psFrameSeconds: Double   // fallback per-segment duration when no Ns: marker

        // Long PS (15A)
        let longPSText: String
        let lpsEnabled: Bool
        let lpsCentered: Bool
        let lpsCR: Bool

        // Radiotext + RT+
        let rtText: String
        let rtBuffers: [String]
        let rtBufferEnabled: [Bool]
        let rtCR: Bool
        let rtCentered: Bool
        let rtMode2B: Bool
        let rtCycleTime: Double
        let rtCycleAB: Bool
        let rtABCycleCount: Int
        let rtPlusEnabled: Bool
        let rtPlusFormatA: String
        let rtPlusFormatB: String
        let nowPlayingEnabled: Bool

        // Alternative Frequencies
        let afEnabled: Bool
        let afCodes: [Int]
        let afMethod: String

        // Clock + scheduler
        let enableCT: Bool
        let enableID: Bool
        let tzOffset: Double
        /// Raw `0A 0A 2A 0A` group-sequence string. Parsed by the
        /// consumer; keeps RDSRuntimeConfig free of file-private types.
        let groupSequenceRaw: String
        let schedulerAuto: Bool
        let schedulerStandard: Bool
        let schedulerStandardLPS: Bool

        /// Build a runtime config snapshot from the current `AppConfig`.
        /// Single source of truth for the AppConfig → RDS-runtime mapping
        /// (used by both `AudioOutputEngine.applyRDSRuntimeConfig` and
        /// the test suite).
        static func make(from config: AppConfig) -> RDSRuntimeConfig {
            RDSRuntimeConfig(
                enabled: config.enRDS && config.rdsLevel > 0.0,
                pi: BasicRDSCoder.parseHexWord(config.rdsPI),
                pty: max(0, min(31, config.rdsPTY)),
                ptynText: config.rdsPTYN,
                ptynEnabled: config.rdsEnablePTYN,
                ptynCentered: config.rdsPTYNCentered,
                eccCode: BasicRDSCoder.parseHexByte(config.rdsECC),
                licCode: BasicRDSCoder.parseHexByte(config.rdsLIC),
                pinCode: config.rdsPINValue,
                tp: config.rdsTP,
                ta: config.rdsTA,
                ms: config.rdsMS,
                diStereo: config.rdsDI_STEREO,
                diHead: config.rdsDI_HEAD,
                diComp: config.rdsDI_COMP,
                diDyn: config.rdsDI_DYN,
                psBanks: [config.rdsPSA, config.rdsPSB, config.rdsPSC, config.rdsPSD],
                psActiveBank: config.rdsPSActiveBank,
                psCentered: config.rdsPSCentered,
                psFrameSeconds: config.rdsPSFrameSeconds,
                longPSText: config.rdsLongPS32,
                lpsEnabled: config.rdsEnableLPS,
                lpsCentered: config.rdsLPSCentered,
                lpsCR: config.rdsLPSCR,
                rtText: config.rdsRTText,
                rtBuffers: [config.rdsRTA, config.rdsRTB, config.rdsRTC, config.rdsRTD],
                rtBufferEnabled: [
                    config.rdsRTBufferAEnabled,
                    config.rdsRTBufferBEnabled,
                    config.rdsRTBufferCEnabled,
                    config.rdsRTBufferDEnabled
                ],
                rtCR: config.rdsRTCR,
                rtCentered: config.rdsRTCentered,
                rtMode2B: config.rdsRTMode.uppercased() == "2B",
                rtCycleTime: config.rdsRTCycleTime,
                rtCycleAB: config.rdsRTCycleAB,
                rtABCycleCount: config.rdsRTABCycleCount,
                rtPlusEnabled: config.rdsEnableRTPlus,
                rtPlusFormatA: config.rdsRTPlusFormatA,
                rtPlusFormatB: config.rdsRTPlusFormatB,
                nowPlayingEnabled: config.rdsNowPlayingEnabled,
                afEnabled: config.rdsEnableAF,
                afCodes: BasicRDSCoder.parseAFList(config.rdsAFList),
                afMethod: config.rdsAFMethod,
                enableCT: config.rdsEnableCT,
                enableID: config.rdsEnableID,
                tzOffset: config.rdsTZOffset,
                groupSequenceRaw: config.rdsGroupSequence,
                schedulerAuto: config.rdsSchedulerAuto,
                schedulerStandard: config.rdsSchedulerStandard,
                schedulerStandardLPS: config.rdsSchedulerStandardLPS
            )
        }
    }

    private var sampleRate: Float
    private let preemphasisUS: Int
    /// WHICH standard's network the audio rides. AM is NRSC-1, which is
    /// not the FM 75 us curve however similar the key looks.
    private let preemphasisCurve: PreemphasisCurve
    /// Processed-audio DIGITAL delivery (stream / DAB+ encoder ahead of us).
    /// False for every composite render, so the FM chain is untouched by
    /// construction. Seeded at init like `audioOutputOnly`; restart-class.
    private let digitalDelivery: Bool

    /// The operating mode this engine was built for. Restart-class and seeded
    /// at construction like `audioOutputOnly`, so every mode-conditional branch
    /// reads one immutable value and the composite path cannot be reached from
    /// a non-MPX mode by construction.
    private let operatingMode: AppConfig.OperatingMode

    /// AM Output: mono sum in, NRSC shaping, asymmetric peak headroom out.
    private var amDelivery: Bool { operatingMode == .am }

    /// Linear ceiling for the NEGATIVE half of the AM feed. 47 CFR 73.1570
    /// allows positive peaks to 125 % while the negative side stays at 100 %,
    /// so the negative side is held at 100/pct of full scale and the operator
    /// calibrates the transmitter so THAT reads 100 % modulation.
    private var amNegativeCeiling: Float = 0.8
    /// True-peak ceiling for the digital target, linear. The pre-encode
    /// limiter is already a 4x oversampled true-peak limiter, so mapping its
    /// threshold onto this value IS the ceiling; live-apply.
    private var processedAudioCeiling: Float = 0.891_25
    /// Post-make-up true-peak guard for the digital target (see
    /// `StereoTruePeakGuard`): the pre-encode limiter's decimation FIR rings
    /// above the limiter's ceiling on hard transients, and on this target
    /// nothing else follows to catch it.
    private var truePeakGuard = StereoTruePeakGuard()
    private let encoderHFGuardEnabled: Bool
    // Tone-generator parameters. All `var` for live-apply through
    // `applyRuntimeConfig` — the Test Tone tab adjusts these on a
    // running engine without restart.
    private var toneFreq: Float
    private var toneMode: String
    private var toneType: String = "sine"
    private var toneLevel: Float = 0.1   // 10^(-20/20) — −20 dBFS default
    private let monoMode: Bool
    private let processingBypass: Bool
    private var pilotLevel: Float
    private var pilotInjectionPercent: Float
    private let rdsInjectionPercent: Float
    private let sumLevel: Float
    private let diffLevel: Float
    private var inputGain: Float
    private var outputGain: Float
    private var finalDrive: Float
    private let limitEnabled: Bool
    private let threshold: Float
    /// Composite amplitude 1.0 is this many kHz of deviation at EVERY
    /// `mpx_deviation_khz`: the whole composite is scaled by
    /// `mpx_deviation_khz / referenceDeviationKHz`, so the pilot stays at
    /// `pilot_level` of the chosen deviation (8 % by default) and every kHz
    /// readout multiplies a
    /// composite peak by this constant (`DeviationReadout`).
    static let referenceDeviationKHz: Float = 75.0
    private var deviationScale: Float
    /// `rds_level` is kHz of deviation (EN 50067 sec 1.4) at EVERY
    /// `mpx_deviation_khz`. The coder emits it on the 75 kHz scale
    /// (`rds_level / 75`) and the subcarriers are then scaled by
    /// `deviationScale` with the rest of the composite, so the RDS sample is
    /// multiplied by this first. Until 2026-10 it was not, and the injection
    /// was `rds_level x mpx_deviation_khz / 75`: 1.33 kHz on air for 2.0 at a
    /// 50 kHz setting, 0.67 kHz at 25 kHz -- under the standard's 1.0 kHz
    /// minimum (review 2026-10 finding 5). Exactly 1.0 at 75 kHz. The pilot
    /// is a share of the chosen deviation and keeps following it.
    @inline(__always)
    private var rdsLevelCompensation: Float { 1.0 / max(1e-3, deviationScale) }
    private let programLowpassHz: Float

    private var widebandAGCEnabled: Bool
    private var widebandAGCTargetDB: Float
    private var widebandAGCMaxGainDB: Float
    private var widebandAGCMinGainDB: Float
    private var widebandAGCAttackMS: Float
    private var widebandAGCReleaseMS: Float
    private var widebandAGCKWeightingEnabled: Bool = true
    private var widebandAGCReleaseProgramDependent: Bool = true
    private var widebandAGCBassDesensitizeEnabled: Bool = false
    private var widebandAGC = WidebandAGCRider()

    private var phaseRotationEnabled: Bool
    private var phaseRotationFreqHz: Float
    private var phaseRotator = StereoPhaseRotator()

    private var parametricEQEnabled: Bool
    private var peqB1FreqHz: Float
    private var peqB1GainDB: Float
    private var peqB2FreqHz: Float
    private var peqB2GainDB: Float
    private var peqB2Q: Float
    private var peqB3FreqHz: Float
    private var peqB3GainDB: Float
    private var peqB3Q: Float
    private var peqB4FreqHz: Float
    private var peqB4GainDB: Float
    private var parametricEQ = ParametricEQ4Band()

    private let hpfHz: Float
    private let hfTrimDB: Float
    private let hfTrimHz: Float
    private var inputHPF = StereoBiquad()
    private var hfTrim = StereoBiquad()

    private let limitLookaheadEnabled: Bool
    private let limitLookaheadMS: Float
    private var lookaheadLimiter = LookaheadLimiter()
    private let audioCompositeSoftClipEnabled: Bool

    private var primeBassEnabled: Bool
    private var primeBassAmount: Float
    private var primeBassHarmonics: Float
    private var primeBassDrive: Float
    private var primeBassDensity: Float
    private var primeBassSubharmonicsEnabled: Bool
    private var primeBassSubharmonicsAmount: Float
    private var primeBassFreqHz: Float
    // PrimeBass: psychoacoustic missing-fundamental enhancer (MaxxBass /
    // Larsen-Aarts topology), rewritten 2026-10-10 after
    // the PrimeBass review. Mid channel only:
    //
    //   band = LR4 LP(F0) . LR4 HP(0.35 F0) (mid)       fundamental band
    //   env  = peak follower |band|, 1 ms / 150 ms, floor -60 dBFS
    //   x    = band / env                                 unit amplitude
    //   h    = evenW * 2 x^2  +  oddW * (tanh(d x) - b1 x) / b3
    //   out  = mid + env * level * LR4 LP(5 F0) . LR4 HP(F0) (h)
    //
    // For a unit sine 2 x^2 is a pure 2nd harmonic plus DC (the output
    // highpass removes the DC); tanh(d x) is an odd series b1 sin t +
    // b3 sin 3t + b5 sin 5t ..., so subtracting b1 x leaves the 3rd, 5th,
    // 7th with NO fundamental and dividing by b3 makes the 3rd unit. Both
    // coefficients come from a configure-time Fourier sum. Normalising
    // the band to unit amplitude before the device and multiplying by the
    // envelope after it makes the harmonic-to-fundamental ratio
    // level-invariant (an x^2 law enhances loud bass most). No gate, no
    // allpass, no per-sample limiter: every level-dependent element is a
    // one-pole envelope (review findings 1-6).
    //
    // Knobs: `amount` = harmonic series level relative to the fundamental
    // (0.22 -> about -11 dB at 2 F0 on a sustained 50 Hz tone); `harmonics`
    // = even/odd balance (0 = 2nd only with a little 3rd, 1 = 3rd/5th
    // dominant); `drive` = hardness of the odd device (soft cubic -> hard
    // clip, raising the 5th and 7th); `density` = upward compression of
    // the harmonic layer (0 = tracks the bass level exactly, 1 = bass
    // 20 dB below -20 dBFS gets up to +6 dB more: MaxxBass's loop
    // compressor, Big Bottom's inverse law); `freq` = F0.
    private var primeBassInHPF = LR4Section()
    private var primeBassInLPF = LR4Section()
    private var primeBassOutHPF = LR4Section()
    private var primeBassOutLPF = LR4Section()
    private var primeBassSubLPF = LR4Section()
    // Exact DC zero after the output band: a Float direct-form highpass
    // at F0 / 192 kHz leaks DC at about -40 dB (its numerator sum is
    // rounding noise over a 1e-5 denominator), audible as a -67 dBFS
    // offset from the squarer; (1 - z^-1) is exact.
    private var primeBassDCBlock = DCBlocker1p()
    private var primeBassSubPrevSample: Float = 0.0
    private var primeBassSubPhase: Int = 0
    // tanh device: drive d and its unit-sine Fourier coefficients.
    private var primeBassOddDrive: Float = 1.0
    private var primeBassOddFundamental: Float = 0.0
    private var primeBassOddThirdInv: Float = 1.0
    /// Level-normaliser envelope (peak of the fundamental band). `internal`
    /// so tests can verify its attack / release directly.
    var primeBassLevelEnv: Float = 0.0
    private var primeBassLevelAttackCoeff: Float = 0.0
    private var primeBassLevelReleaseCoeff: Float = 0.0
    // Envelope-based peak guard: the enhancement may add at most +1.5 dB of
    // peak (the Bass Clipper after the stage holds the rest). Smoothed peak
    // envelopes of the dry mid and of the candidate output set a harmonic
    // gain that moves at 5 ms / 100 ms -- never per sample.
    private var primeBassDryPeakEnv: Float = 0.0
    private var primeBassWetPeakEnv: Float = 0.0
    private var primeBassGuardGain: Float = 1.0
    private var primeBassPeakReleaseCoeff: Float = 0.0
    private var primeBassGuardAttackCoeff: Float = 0.0
    private var primeBassGuardReleaseCoeff: Float = 0.0
    private static let primeBassLevelFloor: Float = 0.001  // -60 dBFS
    private static let primeBassPeakGrowthMax: Float = 1.175  // +1.4 dB target, +1.5 dB bound
    private static let primeBassNormClamp: Float = 1.5
    // Werrbach transient-discriminate harmonic gain (US 5,424,488,
    // Aphex Sound Enhancement System, expired 2013). The harmonic-band
    // gain is modulated by a transient detector built from two
    // envelopes on the fundamental band -- a fast follower (~5 ms
    // attack) tracking the current attack and a slow follower (~50 ms
    // attack) tracking its baseline. Their normalized difference is
    // positive on real onsets (drum hits, plucked bass) and decays to
    // zero as the slow follower catches up, ~50-150 ms post-attack.
    // Mapped through a floor -> peak range to give a brief harmonic
    // burst on attacks and a lower sustain floor on continuous program:
    // "punchy not boomy."
    // `internal` access on these three so tests can verify the
    // transient detector directly.
    var primeBassFastEnv: Float = 0.0
    var primeBassSlowEnv: Float = 0.0
    var primeBassTransientGainObserved: Float = primeBassTransientFloor
    private var primeBassFastAttackCoeff: Float = 0.0
    private var primeBassFastReleaseCoeff: Float = 0.0
    private var primeBassSlowAttackCoeff: Float = 0.0
    private var primeBassSlowReleaseCoeff: Float = 0.0
    private static let primeBassTransientFloor: Float = 0.7
    private static let primeBassTransientPeak: Float = 1.4

    private var multibandEnabled: Bool
    private var multibandMode: Int
    private var multibandMakeup: Float
    private var multibandKneeDB: Float
    private var multibandLinkStrength: Float
    private var multibandReleaseProgramDependent: Bool
    private var multibandTransientAwareAttackEnabled: Bool
    private var multibandInterBandCouplingEnabled: Bool
    private var multibandCouplingGRDB: Float = 0.0
    private var multibandCouplingAttackCoeff: Float = 0.0
    private var multibandCouplingReleaseCoeff: Float = 0.0
    private var multibandX1Hz: Float
    private var multibandX2Hz: Float
    private var multibandX3Hz: Float
    private var multibandX4Hz: Float
    private var multibandLowThresholdDB: Float
    private var multibandMidThresholdDB: Float
    private var multibandHighThresholdDB: Float
    private var multibandLowRatio: Float
    private var multibandMidRatio: Float
    private var multibandHighRatio: Float
    private var multibandLowAttackMS: Float
    private var multibandMidAttackMS: Float
    private var multibandHighAttackMS: Float
    private var multibandLowReleaseMS: Float
    private var multibandMidReleaseMS: Float
    private var multibandHighReleaseMS: Float

    // IIR (allpass-compensated LR4) splitter for the low-latency path; the
    // bands sum to an allpass, so the magnitude is flat.
    private var mb3IIRSplitter = StereoIIRMultibandSplitter3()
    // Linear-phase FIR splitter — used in TX mode in place of the IIR
    // splitter to keep transients time-coherent across bands.
    private var mb3FIRSplitter = LinearPhaseMultibandSplitter3()
    private var mbLowCompL = MonoCompressor()
    private var mbLowCompR = MonoCompressor()
    private var mbMidCompL = MonoCompressor()
    private var mbMidCompR = MonoCompressor()
    private var mbHighCompL = MonoCompressor()
    private var mbHighCompR = MonoCompressor()

    private var mb5IIRSplitter = StereoIIRMultibandSplitter5()
    // Linear-phase FIR splitter — used in TX mode in place of
    // mb5IIRSplitter to keep transients time-coherent across bands.
    private var mb5FIRSplitter = LinearPhaseMultibandSplitter5()
    private var mb5Comp1L = MonoCompressor()
    private var mb5Comp1R = MonoCompressor()
    private var mb5Comp2L = MonoCompressor()
    private var mb5Comp2R = MonoCompressor()
    private var mb5Comp3L = MonoCompressor()
    private var mb5Comp3R = MonoCompressor()
    private var mb5Comp4L = MonoCompressor()
    private var mb5Comp4R = MonoCompressor()
    private var mb5Comp5L = MonoCompressor()
    private var mb5Comp5R = MonoCompressor()

    // Advanced Dynamics: experimental single-stage 5-band leveler that
    // REPLACES the wideband AGC + multiband compressor when enabled
    // (default off). Owns its own FIR splitter; structure is configured
    // lazily (only when enabled) so a disabled stage costs nothing.
    private var advancedDynamicsEnabled = false
    private var advancedDynamicsTargetDB: Float = -16.0
    private var advancedDynamicsLowOffsetDB: Float = 0.0
    private var advancedDynamicsMidOffsetDB: Float = -3.0
    private var advancedDynamicsHighOffsetDB: Float = -9.0
    private var advancedDynamicsMaxGainDB: Float = 12.0
    private var advancedDynamicsDensity: Float = 0.5
    private var advancedDynamicsSpeed: Float = 1.0
    private var advancedDynamicsStructureConfigured = false
    private var advancedDynamics = AdvancedDynamicsLeveler()

    // Multiband limiter: per-band fast peak limiters after compression
    private var multibandLimiterEnabled: Bool
    private var multibandLimiterThresholdDB: Float
    private var multibandLimiterAttackMS: Float
    private var multibandLimiterReleaseMS: Float
    private var mbLimLow = BandLimiter()
    private var mbLimMid = BandLimiter()
    private var mbLimHigh = BandLimiter()
    private var mbLim5B1 = BandLimiter()
    private var mbLim5B2 = BandLimiter()
    private var mbLim5B3 = BandLimiter()
    private var mbLim5B4 = BandLimiter()
    private var mbLim5B5 = BandLimiter()

    // Downward expander: per-band noise reduction
    private var downwardExpanderEnabled: Bool
    private var expanderThresholdDB: Float
    private var expanderRatio: Float
    private var expanderAttackMS: Float
    private var expanderReleaseMS: Float
    private var mbExpLow = DownwardExpander()
    private var mbExpMid = DownwardExpander()
    private var mbExpHigh = DownwardExpander()
    private var mbExp5B1 = DownwardExpander()
    private var mbExp5B2 = DownwardExpander()
    private var mbExp5B3 = DownwardExpander()
    private var mbExp5B4 = DownwardExpander()
    private var mbExp5B5 = DownwardExpander()

    // Bass clipper: dedicated LF clipper before final limiter
    private var bassClipperEnabled: Bool
    private var bassClipperCrossoverHz: Float
    private var bassClipperThresholdDB: Float
    private var bassClipperDrive: Float
    private var bassClipper = BassClipper()
    private var hfLimiterEnabled: Bool
    private var hfLimiterThresholdDB: Float
    private var hfLimiterTopThresholdDB: Float
    private var hfLimiterAttackMS: Float
    private var hfLimiterReleaseMS: Float
    private var hfLimiterMaxReductionDB: Float
    private var hfLimiter = HFLimiter()

    // Distortion-cancelled clipper: L/R domain with LF distortion cancellation
    private var dcClipperEnabled: Bool
    private var dcClipperCeilingDB: Float
    private var dcClipperCancelFreqHz: Float
    private var dcClipper = DistortionCancelledClipper()

    // Processed-audio output: optional final loudness clipper on the L/R feed.
    // A dedicated DistortionCancelledClipper instance fed by `processedAudioFinalClipDrive`
    // (drive pre-gain). Only applied in the audio-only render path, so the composite
    // chain is untouched. Engaged when in processed-audio mode AND the external coder
    // has no clipper of its own.
    private var processedAudioCoderHasClipper: Bool
    private var processedAudioFinalClipDrive: Float = 1.0
    private var processedAudioFinalClipper = DistortionCancelledClipper()
    private static let processedAudioFinalClipCeilingDB: Float = -0.3

    // BS.412 MPX power limiter
    private var bs412Enabled: Bool
    private var bs412CeilingDBr: Float
    /// The compliance statistic runs whether or not anything acts on it, so
    /// enabling the limiter does not start a 60 s wait (0.65 audit, P0-6).
    private var bs412Meter = BS412MultiplexPowerMeter()
    private var bs412Rider = BS412Rider()
    private var bs412Guard = BS412ComplianceGuard()
    private var bs412StatusState = BS412Status()

    /// Compliance state for telemetry. Updated once per rendered sample.
    var bs412Status: BS412Status { bs412StatusState }
    /// Diagnostics for the generator-level wiring tests, not operator
    /// telemetry: what the guard charges unobserved slots with, and how much
    /// history each control stage has accounted. Component tests cannot see
    /// a wiring mistake; these let a test read the wired state directly.
    var bs412GuardSubcarrierReserveMeanSquare: Float { bs412Guard.subcarrierReserveMeanSquare }
    var bs412GuardObservedSeconds: Float { bs412Guard.observedSeconds }
    var bs412RiderObservedSeconds: Float { bs412Rider.observedSeconds }

    /// Upper bound on the mean square of the subcarriers alone, for the
    /// guard's unobserved-history reserve.
    ///
    /// Pilot and RDS are bounded oscillatory signals whose instantaneous sum
    /// never exceeds the sum of their peaks, so over the window their mean
    /// square is at most that of a single sinusoid of that combined
    /// amplitude: `(pilotPeak + rdsPeak)^2 / 2`. That is the worst case of
    /// perfect coherence and is the bound used here.
    ///
    /// Do NOT use the peak square without the halving: it is 3 dB
    /// pessimistic, and a reserve above the ceiling makes the guard declare
    /// a perfectly feasible configuration unachievable.
    private var bs412SubcarrierReserve: Float {
        let pilotPeak: Float = pilotSupported ? pilotLevel : 0.0
        // The coder normalises its shaped output to unit peak before scaling,
        // so the nominal injection IS the peak; 1.25 covers that estimate
        // being taken over a finite test pattern.
        let rdsPeak: Float = rdsSupported
            ? (1.25 * rdsInjectionPercent * 0.01 * rdsLevelCompensation) : 0.0
        // Deliberately NOT gated on mono mode or the stereo-services flag:
        // the reserve must bound whatever the next minute may carry, and
        // over-reserving only costs headroom in the first window.
        let peak: Float = (pilotPeak + rdsPeak) * deviationScale
        return (peak * peak) * 0.5
    }
    // CompositeClipper: disabled by default, field only for size/layout test.
    private var compositeClipperEnabled: Bool = false
    private var compositeClipperThresholdDB: Float = -3.0
    private var compositeClipperCeilingDB: Float = -0.5
    private var compositeClipperCancelAudio: Bool = true
    private var compositeClipperStereoGuard: Float = 1.0
    private var compositeClipperCancelPilot: Bool = true
    private var compositeClipperCancelRDS: Bool = true
    private var compositeClipperLookaheadMS: Float = 0.0
    private var compositeClipperOversampling: Int = 16
    // SSB Stereo: experimental SSB-leaning stereo encoder ahead of the
    // composite clipper (default off; Hilbert FIR allocated lazily so a
    // disabled stage costs nothing).
    private var ssbStereoEnabled: Bool = false
    private var ssbStereoAmount: Float = 0.7
    private var ssbStereoConfigured = false
    private var ssbStereo = SSBStereoEncoder()
    private var compositeClipper = CompositeClipper()
    private var audioCompositeBandwidthFIR = LinearPhaseFIRLowpass()

    // === Dual-rate audio chain boundary (Phase 1, no-op infrastructure) ===
    //
    // When `dualRateBoundaryEnabled` is true, per-OS-sample input gets
    // pushed through a decim → interp pair so the downstream chain sees
    // band-limited and roundtripped input. Phase 1 keeps the audio chain
    // at MPX rate — no stages move below the boundary yet. The point of
    // this step is to validate the resampler primitives at chain scale
    // and surface any latency / bit-difference issues before Phase 2
    // starts migrating stages.
    private var dualRateBoundaryEnabled: Bool = false
    /// `dual_rate_audio_domain_enabled` as configured: whether the boundary
    /// is WANTED. `dualRateBoundaryEnabled` is whether it runs, which also
    /// needs an integer ratio at the current MPX rate (re-derived by
    /// `setSampleRate`) and not the processed-audio mode.
    private var dualRateRequested: Bool = false
    private var dualRateAudioRate: Float = 48_000.0
    private var dualRateFactor: Int = 1
    // Processed-audio output mode: the render path emits the post-pre-encode-limiter
    // L/R instead of building the FM composite (no stereo encode / composite clipper
    // / BS.412 / pilot / RDS). Set by the engine via `setAudioOutputOnly`. Forces the
    // dual-rate boundary off (the whole engine runs at the audio rate in this mode).
    private(set) var audioOutputOnly: Bool = false
    private var inputDecimL = LinearPhaseFIRDecimator()
    private var inputDecimR = LinearPhaseFIRDecimator()
    private var inputInterpL = LinearPhaseFIRInterpolator()
    private var inputInterpR = LinearPhaseFIRInterpolator()
    /// L OS-rate samples emitted by the most recent interp push; consumed
    /// round-robin via `dualRateBoundaryPhase`.
    private var interpOutBufferL: [Float] = []
    private var interpOutBufferR: [Float] = []
    /// Counts pushes into the decimator since its last emit. When it
    /// reaches `dualRateFactor`, the decimator has just emitted and we
    /// pump that sample into the interpolator (refilling the buffers).
    private var dualRateBoundaryPushCount: Int = 0
    /// Position 0..L-1 to read next from `interpOutBuffer{L,R}`.
    private var dualRateBoundaryPhase: Int = 0
    /// Most recent `processAudioDomain` analysis snapshot. Held between
    /// audio-rate ticks so MPX-domain stages can read it on every OS
    /// tick even though audio domain only runs once per L OS ticks.
    private var latestAudioAnalysisStereo = ProgramStereoState(
        left: 0, right: 0, referenceLeft: 0, referenceRight: 0,
        postAGCLeft: 0, postAGCRight: 0, inputActivity: 0
    )
    /// Most recent input activity from the audio domain (carried across
    /// OS ticks between audio-rate refreshes).
    private var latestAudioInputActivity: Float = 0

    /// Audio-domain sample rate. When the dual-rate boundary is on, audio
    /// stages run at the lower `dualRateAudioRate`; otherwise they run
    /// at the engine's `sampleRate`. All audio-domain stage configures
    /// must use this property so the cutover is a one-line change inside
    /// each configure helper.
    private var audioDomainSampleRate: Float {
        dualRateBoundaryEnabled ? dualRateAudioRate : sampleRate
    }

    // Subcarrier delay line — keeps pilot+RDS phase-aligned with the
    // delayed audio composite. Pilot and the embedded 38 kHz stereo
    // subcarrier are generated at the same oscillator step in
    // `makeCompositeComponents`, but the audio composite (containing
    // the stereo subcarrier × diff modulator) then passes through the
    // composite clipper's FIR group delay and the final-stage MPX
    // limiter's look-ahead delay before output. Adding the pilot+RDS
    // un-delayed introduces a phase mismatch between the audio
    // composite's internal 38 kHz reference and the pilot the receiver
    // locks to — measured up to ~280° phase rotation at default config
    // (~9-sample FIR delay + 960-sample look-ahead at 192 kHz). The
    // receiver demodulates L−R with that phase error, producing
    // dramatic stereo separation loss. Delaying subcarriers by the
    // same chain delay restores the phase alignment.
    internal var subcarrierDelayLine: [Float] = []
    internal var subcarrierDelayActiveCount: Int = 0
    internal var subcarrierDelayWriteIdx: Int = 0
    private var stereoSubcarrierDelayLine: [Float] = []
    private var subcarrierDelayResizeScratch: [Float] = []
    private var stereoSubcarrierDelayResizeScratch: [Float] = []
    private var stereoSubcarrierDelayWriteIdx: Int = 0

    private var monoBassEnabled: Bool
    private var monoBassFreqHz: Float
    private var monoBassFilter = MonoBassFilter()
    private var stereoProtectInputMidEnv: Float = 0.0
    private var stereoProtectInputSideEnv: Float = 0.0
    private var stereoProtectMidEnv: Float = 0.0
    private var stereoProtectSideEnv: Float = 0.0
    private var stereoProtectGain: Float = 1.0
    private var stereoProtectAttackCoeff: Float = 0.0
    private var stereoProtectReleaseCoeff: Float = 0.0
    private let rdsCoder: BasicRDSCoder?

    private var preEncodeAudioLimiterEnabled: Bool
    private var preEncodeAudioLimiter = PreEncodeAudioLimiter()
    /// Audio-domain samples of delay the pre-encode limiter adds (look-ahead +
    /// decimator group delay). Test hook for the live-apply rate contract.
    var preEncodeLimiterLatencySamples: Int { preEncodeAudioLimiter.latencySamples }
    private var preEncodeThreshold: Float = 0.85
    private var preEncodeReleaseMS: Float = 50.0
    private var preEncodeBandlimitedResidualEnabled: Bool = false
    private var preEncodeBandlimitedResidualTapCount: Int = 33
    private var preEncodeBandlimitedResidualCutoffFraction: Float = 0.25
    private var preEncodeLookaheadMS: Float = 0.0
    private var preEncodeLookaheadHFOnly: Bool = false
    private var preEncodeLookaheadHFCutoffHz: Float = 4_000.0

    private var toneStep: Float
    /// Level applied to the raw tone sample: `toneLevel`, times 1/|H_pre(f)|
    /// for a sine so the composite peak is the set level regardless of
    /// where the tone sits on the pre-emphasis curve.
    private var toneGain: Float = 0.1
    /// True only while a test-tone sample is inside `processSampleDetailed`:
    /// the tone is a CALIBRATION source (0 dBFS = 100% of the audio-composite
    /// budget), so every gain-changing stage -- input gain, AGC, EQ, multiband,
    /// enhancers, clippers, limiters, final drive, BS.412 -- is bypassed for
    /// it while the delay-bearing stages stay in the path (pilot/RDS alignment).
    private var renderingCalibrationTone = false
    private var audioStagesBypassed: Bool { processingBypass || renderingCalibrationTone }
    private var tonePhase: Float = 0.0
    /// Paul Kellet's 4-pole pink-noise IIR state. Cheap, well-known
    /// approximation (~3 dB/octave from ~0.4 Hz upward). Cycle artefacts
    /// above ~10 kHz aren't a concern at the test-tone level / use
    /// case (broadband fill, not deterministic measurement).
    private var pinkB0: Float = 0.0
    private var pinkB1: Float = 0.0
    private var pinkB2: Float = 0.0
    private var pinkB3: Float = 0.0
    private var pinkB4: Float = 0.0
    private var pinkB5: Float = 0.0
    private var pinkB6: Float = 0.0
    /// xorshift64* seed for white noise. Initialised on engine start;
    /// the audio thread mutates it without locks (xorshift is a pure
    /// scalar update; the noise stream doesn't need to be reproducible
    /// across runs).
    private var toneNoiseRNG: UInt64 = 0xCAFE_BABE_DEAD_BEEF
    private var pilotOsc = SineCosOsc()
    private var subPhase: Float = 0.0

    private var pilotSupported: Bool = false
    private var stereoSubcarrierSupported: Bool = false
    private var rdsSupported: Bool = false

    // MARK: Composite services a render rate can carry

    /// The highest audio frequency that can reach the stereo encoder at a
    /// significant level: the -80 dB point of the widest encoder lowpass
    /// (the 16 kHz cap with pre-emphasis off; 14.6 / 14.9 kHz with it on).
    static let stereoAudioBandEdgeHz = 17_500.0
    /// RDS occupies 57 kHz +/- 2.4 kHz (EN 50067 sec 1.4).
    static let rdsUpperBandEdgeHz = 59_400.0
    /// Lowest render rate whose Nyquist frequency holds the upper L-R
    /// sideband (38 kHz + the audio band edge = 55.5 kHz): 111 kHz. Below it
    /// the sideband folds about Nyquist into the L-R band a receiver decodes
    /// (at 96 kHz a 12 kHz L-only tone puts an 8 kHz L-R alias 6 dB under
    /// the wanted L-R, review 2026-10 finding 4), so stereo -- and the pilot
    /// that would announce it -- stay off and the composite is mono.
    static let minimumStereoSampleRate = 2.0 * (38_000.0 + stereoAudioBandEdgeHz)
    /// Lowest render rate whose Nyquist frequency holds the whole RDS band:
    /// 118.8 kHz.
    static let minimumRDSSampleRate = 2.0 * rdsUpperBandEdgeHz

    struct CompositeRateSupport: Equatable {
        var stereo: Bool
        var rds: Bool
    }

    static func compositeRateSupport(sampleRate: Double) -> CompositeRateSupport {
        CompositeRateSupport(
            stereo: sampleRate >= minimumStereoSampleRate,
            rds: sampleRate >= minimumRDSSampleRate)
    }

    /// The operator-facing note for a composite render rate that cannot
    /// carry every service, nil when it can. Both engines report it.
    static func compositeRateNote(sampleRate: Double) -> String? {
        let support = compositeRateSupport(sampleRate: sampleRate)
        let rate = Int(sampleRate.rounded())
        if !support.stereo {
            return "The composite renders at \(rate) Hz, too low for stereo and RDS "
                + "(stereo needs at least \(Int(minimumStereoSampleRate)) Hz, RDS "
                + "\(Int(minimumRDSSampleRate.rounded())) Hz): the pilot, stereo and RDS are off "
                + "and the composite is mono. Use a 192 kHz output."
        }
        if !support.rds {
            return "The composite renders at \(rate) Hz, too low for RDS (it needs at least "
                + "\(Int(minimumRDSSampleRate.rounded())) Hz): RDS is off. Use a 192 kHz output."
        }
        return nil
    }

    // Pre-emphasis runs in L/R domain immediately upstream of the pre-encode
    // limiter (canonical Optimod / Stereotool placement). The limiter then
    // peak-controls the HF-boosted signal before it crosses into composite
    // assembly. Moved here from M/S inside `makeCompositeComponents` in the
    // 2026-05 chain-order audit — see docs/project-roadmap.md "Pre-emphasis placement" and
    // the chain-order-audit report at .audit-out/chain_order/REPORT.md.
    private var preL = PreemphasisFilter()
    private var preR = PreemphasisFilter()
    private var programLP = ProgramLowpass()
    private var encoderProgramLP = ProgramLowpass()
    private var encoderHFGuardSplit = StereoLinkwitzRiley4()
    private var encoderHFGuardEnv: Float = 0.0
    private var encoderHFGuardGain: Float = 1.0
    private var encoderHFGuardAttackCoeff: Float = 0.0
    private var encoderHFGuardReleaseCoeff: Float = 0.0
    private var encoderProgramFIR = LinearPhaseFIRLowpass()
    /// Whether the 6th-order Butterworth program lowpass runs in the audio
    /// path. It is the band-limit on the low-latency monitor path (no encoder
    /// FIR) and stays in series with the FIR on the composite, where it is
    /// -0.47 dB at 14 kHz on the 48 kHz audio domain (inside the +/-0.5 dB
    /// spec) and where removing it moved `--verify-hf-transients` (speech hat
    /// SINAD 20.1 -> 19.7 dB against a 20 dB gate, 2026-10-16). In the
    /// processed-audio modes (FM / HD / AM Output) the encoder FIR alone is the
    /// band-limit: the audio domain runs at the device rate there, and a
    /// bilinear Butterworth's droop grows with the rate (-1.10 dB at 14 kHz at
    /// 96 kHz, -1.24 dB at 192 kHz), which is what an external coder received.
    private var programLowpassInPath: Bool { !useEncoderFIR || !audioOutputOnly }
    /// The program lowpass as its 48 kHz-domain design, for a composite whose
    /// audio domain runs at the full render rate (boundary off): see
    /// `StridedProgramLowpass`. Used only with the encoder FIR on (it removes
    /// the strided filter's images) and when that rate is an integer multiple
    /// of `programLowpassReferenceRate`; otherwise `programLP` runs.
    private var programLPStrided = StridedProgramLowpass()
    /// The audio-domain rate the program lowpass is defined at: the configured
    /// dual-rate audio rate (48 kHz default), whether or not the boundary is on.
    private var programLowpassReferenceRate: Float = 48_000.0
    /// Encoder FIR transition: flat to the encoder cutoff (14.9 kHz at 50 us),
    /// -6 dB at cutoff + transition / 2, 82 dB down from cutoff + transition.
    /// 1.5 kHz in series with the Butterworth; 1 kHz where the FIR is the only
    /// band-limit, so the 15.5-16.4 kHz tail the Butterworth used to take
    /// down stays below the old cascade (modelled on pre-emphasised white
    /// noise: 15-23 kHz gap -30 dB against -22 dB for the cascade; 1.5 kHz
    /// alone measured -32 dB composite spill against -36 dB on
    /// `--verify-hf-transients`). 249 taps / 2.6 ms at 48 kHz, 991 at 192 kHz.
    private var encoderFIRTransitionHz: Float { programLowpassInPath ? 1_500.0 : 1_000.0 }
    // Selects the TX-grade FIR over the low-latency Butterworth. Set by
    // AudioOutputEngine based on output mode (composite → FIR, monitor →
    // Butterworth) and the `encoderFirEnabled` config toggle.
    private var useEncoderFIR: Bool = false
    // Selects linear-phase FIR multiband crossovers over the IIR LR4
    // chain. TX mode default; monitor mode keeps LR4 for low latency.
    // Phase-flat band reconstruction prevents transient smear and
    // inter-band phase artifacts.
    private var useMultibandFIR: Bool = false
    private var monitorDecoder = MPXDecoder()
    private var lastSubcarrierSample: Float = 0.0
    private var audioCompositePeakState: Float = 0.0
    /// Decaying peak of the shaper's excess over budget (dB); see `FinalLimiterStatus.safetyClipDB`.
    private var safetyClipExcessDB: Float = 0.0
    private var audioCompositePeakDecayCoeff: Float = 0.0
    private var compositeBudgetGain: Float = 1.0
    private var compositeBudgetGainAttackCoeff: Float = 0.0
    private var compositeBudgetGainReleaseCoeff: Float = 0.0
    /// Decayed envelope of `max(0, |unclampedMPX| - 1)` — captures how
    /// far the post-injection MPX exceeded the ±1.0 clamp at any
    /// recent sample. Non-zero = pilot/RDS subcarriers are being
    /// clipped at the final clamp (the constant-amplitude invariant
    /// is broken). See Finding #3 in the chain audit.
    private var postInjectionOvershootEnv: Float = 0.0
    private var postInjectionOvershootDecayCoeff: Float = 0.0
    private var subcarrierReservationEnv: Float = 0.0
    /// Per-sample decay of the subcarrier presence and peak holds (~2 s).
    private var subcarrierReservationReleaseCoeff: Float = 0.0
    private var pilotPresenceEnv: Float = 0.0
    private var rdsPresenceEnv: Float = 0.0
    private var subcarrierPeakHoldEnv: Float = 0.0
    private var lastProgramActivity: Float = 0.0
    private struct ProgramStereoState {
        var left: Float
        var right: Float
        var referenceLeft: Float
        var referenceRight: Float
        var postAGCLeft: Float
        var postAGCRight: Float
        var inputActivity: Float
    }

    private struct CompositeComponents {
        var base: Float
        var diff: Float
        var sub: Float
        var pilot: Float
        var rds: Float
    }

    private struct StereoImageState {
        var left: Float
        var right: Float
    }
    private var monitorExpectedSideEnv: Float = 0.0
    private var monitorExpectedSideAttackCoeff: Float = 0.0
    private var monitorExpectedSideReleaseCoeff: Float = 0.0

    init(config: AppConfig, sampleRate: Double, nowPlayingState: NowPlayingState? = nil) {
        self.sampleRate = Float(max(8_000.0, sampleRate))
        // Digital delivery drops the FM-only stages. Pre-emphasis is forced OFF
        // rather than merely recommended off: the transmission curve has no
        // meaning ahead of a codec, and with it gone the HF limiter has no
        // boost to ride and the encoder HF guard disables itself. The INI value
        // is untouched, so switching back to the FM-coder target restores it.
        let mode = config.operatingMode
        self.operatingMode = mode
        let digital = mode == .hd
        let am = mode == .am
        self.digitalDelivery = digital
        // AM rides the NRSC curve (75 us or flat), chosen by its own key: the
        // FM pre-emphasis picker has no function on an AM feed.
        self.preemphasisUS = digital ? 0 : (am ? config.amPreemphasisUS : config.preemphasisUS)
        // AM rides NRSC-1 (zero 2122 Hz, pole 8700 Hz), NOT the FM curve:
        // until 0.65 `am_preemphasis_us = 75` was handed to the FM network,
        // which keeps climbing where NRSC-1's pole flattens it -- 3.6 dB
        // too much at 10 kHz and worse above.
        self.preemphasisCurve = digital
            ? .none
            : (am ? (config.amPreemphasisUS > 0 ? .nrsc : PreemphasisCurve.none)
                  : (config.preemphasisUS > 0 ? .fm(tauUS: config.preemphasisUS) : .none))
        self.encoderHFGuardEnabled = !digital && !am && config.preemphasisUS > 0
        self.toneFreq = Float(config.testToneFreq)
        self.toneMode = config.testToneMode.lowercased()
        self.toneType = config.testToneType.lowercased()
        self.toneLevel = powf(10.0, Float(config.testToneLevelDB) / 20.0)
        self.monoMode = config.monoMode
        self.processingBypass = config.processingBypass
        self.pilotLevel = Float(config.pilotLevel)
        self.pilotInjectionPercent = Float(config.pilotLevel * 100.0)
        self.rdsInjectionPercent = Float(max(0.0, config.rdsLevel / 75.0 * 100.0))
        self.sumLevel = Float(config.sumLevel)
        self.diffLevel = Float(config.diffLevel)
        self.inputGain = powf(10.0, Float(config.inputGainDB) / 20.0)
        self.outputGain = powf(10.0, Float(config.outputGainDB) / 20.0)
        self.finalDrive = powf(10.0, Float(config.finalDriveDB) / 20.0)
        self.limitEnabled = config.limitMPX
        self.threshold = clampf(Float(config.limitThreshold), 0.5, 0.999)
        self.deviationScale = Float(config.mpxDeviationKHz / Double(Self.referenceDeviationKHz))
        // AM narrows the program band to its own bandwidth key (NRSC-1 is
        // 10 kHz; narrower is common). Everything downstream reads this one
        // value, so no stage needs an AM branch of its own.
        self.programLowpassHz = am
            ? Float(min(config.programLowpassHz, config.amLowpassHz))
            : Float(config.programLowpassHz)

        self.widebandAGCEnabled = config.widebandAGCEnabled
        self.widebandAGCTargetDB = Float(config.widebandAGCTargetDB)
        self.widebandAGCMaxGainDB = Float(config.widebandAGCMaxGainDB)
        self.widebandAGCMinGainDB = Float(config.widebandAGCMinGainDB)
        self.widebandAGCAttackMS = Float(config.widebandAGCAttackMS)
        self.widebandAGCReleaseMS = Float(config.widebandAGCReleaseMS)
        self.widebandAGCKWeightingEnabled = config.widebandAGCKWeightingEnabled
        self.widebandAGCReleaseProgramDependent = config.widebandAGCReleaseProgramDependent
        self.widebandAGCBassDesensitizeEnabled = config.widebandAGCBassDesensitizeEnabled

        self.phaseRotationEnabled = config.phaseRotationEnabled
        self.phaseRotationFreqHz = clampf(Float(config.phaseRotationFreqHz), 50.0, 500.0)

        self.parametricEQEnabled = config.parametricEQEnabled
        self.peqB1FreqHz = clampf(Float(config.peqB1FreqHz), 20.0, 500.0)
        self.peqB1GainDB = clampf(Float(config.peqB1GainDB), -12.0, 12.0)
        self.peqB2FreqHz = clampf(Float(config.peqB2FreqHz), 100.0, 5000.0)
        self.peqB2GainDB = clampf(Float(config.peqB2GainDB), -12.0, 12.0)
        self.peqB2Q = clampf(Float(config.peqB2Q), 0.1, 10.0)
        self.peqB3FreqHz = clampf(Float(config.peqB3FreqHz), 500.0, 12000.0)
        self.peqB3GainDB = clampf(Float(config.peqB3GainDB), -12.0, 12.0)
        self.peqB3Q = clampf(Float(config.peqB3Q), 0.1, 10.0)
        self.peqB4FreqHz = clampf(Float(config.peqB4FreqHz), 1000.0, 16000.0)
        self.peqB4GainDB = clampf(Float(config.peqB4GainDB), -12.0, 12.0)

        self.hpfHz = clampf(Float(config.hpfHz), 10.0, 200.0)
        self.hfTrimDB = clampf(Float(config.hfTrimDB), -12.0, 0.0)
        self.hfTrimHz = clampf(Float(config.hfTrimHz), 500.0, 12_000.0)

        self.limitLookaheadEnabled = config.limitLookaheadEnabled
        self.limitLookaheadMS = clampf(Float(config.limitLookaheadMS), 0.0, 20.0)
        self.preEncodeAudioLimiterEnabled = config.preEncodeAudioLimiterEnabled
        self.preEncodeBandlimitedResidualEnabled = config.preEncodeBandlimitedResidualEnabled
        self.preEncodeBandlimitedResidualTapCount = max(5, min(129, config.preEncodeBandlimitedResidualTapCount | 1))
        self.preEncodeBandlimitedResidualCutoffFraction = clampf(Float(config.preEncodeBandlimitedResidualCutoffFraction), 0.05, 0.49)
        self.audioCompositeSoftClipEnabled = config.audioCompositeSoftClipEnabled

        self.primeBassEnabled = config.primeBassEnabled
        self.primeBassAmount = clampf(Float(config.primeBassAmount), 0.0, 1.0)
        self.primeBassHarmonics = clampf(Float(config.primeBassHarmonics), 0.0, 1.0)
        self.primeBassDrive = clampf(Float(config.primeBassDrive), 0.0, 2.5)
        self.primeBassDensity = clampf(Float(config.primeBassDensity), 0.0, 1.0)
        self.primeBassSubharmonicsEnabled = config.primeBassSubharmonicsEnabled
        self.primeBassSubharmonicsAmount = clampf(Float(config.primeBassSubharmonicsAmount), 0.0, 1.0)
        self.primeBassFreqHz = clampf(Float(config.primeBassFreqHz), 45.0, 220.0)

        self.multibandEnabled = config.multibandEnabled
        self.multibandMode = (config.multibandMode == 5) ? 5 : 3
        self.multibandMakeup = powf(10.0, Float(config.multibandMakeupDB) / 20.0)
        self.multibandKneeDB = clampf(Float(config.multibandKneeDB), 0.0, 12.0)
        self.multibandLinkStrength = ChainFeature.stereoProgram.applies(in: mode)
            ? clampf(Float(config.multibandLinkStrength), 0.0, 1.0) : 0.0
        self.multibandReleaseProgramDependent = config.multibandReleaseProgramDependent
        self.multibandTransientAwareAttackEnabled = config.multibandTransientAwareAttackEnabled
        self.multibandInterBandCouplingEnabled = config.multibandInterBandCouplingEnabled
        let crossovers = Self.resolveMultibandCrossovers(
            sampleRate: self.sampleRate,
            x1: Float(config.multibandX1Hz),
            x2: Float(config.multibandX2Hz),
            x3: Float(config.multibandX3Hz),
            x4: Float(config.multibandX4Hz)
        )
        self.multibandX1Hz = crossovers.x1
        self.multibandX2Hz = crossovers.x2
        self.multibandX3Hz = crossovers.x3
        self.multibandX4Hz = crossovers.x4
        self.multibandLowThresholdDB = Float(config.multibandLowThresholdDB)
        self.multibandMidThresholdDB = Float(config.multibandMidThresholdDB)
        self.multibandHighThresholdDB = Float(config.multibandHighThresholdDB)
        self.multibandLowRatio = Float(config.multibandLowRatio)
        self.multibandMidRatio = Float(config.multibandMidRatio)
        self.multibandHighRatio = Float(config.multibandHighRatio)
        self.multibandLowAttackMS = Float(config.multibandLowAttackMS)
        self.multibandMidAttackMS = Float(config.multibandMidAttackMS)
        self.multibandHighAttackMS = Float(config.multibandHighAttackMS)
        self.multibandLowReleaseMS = Float(config.multibandLowReleaseMS)
        self.multibandMidReleaseMS = Float(config.multibandMidReleaseMS)
        self.multibandHighReleaseMS = Float(config.multibandHighReleaseMS)

        self.advancedDynamicsEnabled = config.advancedDynamicsEnabled
        self.advancedDynamicsTargetDB = clampf(Float(config.advancedDynamicsTargetDB), -30.0, -6.0)
        self.advancedDynamicsLowOffsetDB = clampf(Float(config.advancedDynamicsLowOffsetDB), -12.0, 6.0)
        self.advancedDynamicsMidOffsetDB = clampf(Float(config.advancedDynamicsMidOffsetDB), -12.0, 6.0)
        self.advancedDynamicsHighOffsetDB = clampf(Float(config.advancedDynamicsHighOffsetDB), -12.0, 6.0)
        self.advancedDynamicsMaxGainDB = clampf(Float(config.advancedDynamicsMaxGainDB), 0.0, 24.0)
        self.advancedDynamicsDensity = clampf(Float(config.advancedDynamicsDensity), 0.0, 1.0)
        self.advancedDynamicsSpeed = clampf(Float(config.advancedDynamicsSpeed), 0.25, 4.0)

        self.multibandLimiterEnabled = config.multibandLimiterEnabled
        self.multibandLimiterThresholdDB = clampf(Float(config.multibandLimiterThresholdDB), -20.0, 0.0)
        self.multibandLimiterAttackMS = clampf(Float(config.multibandLimiterAttackMS), 0.01, 10.0)
        self.multibandLimiterReleaseMS = clampf(Float(config.multibandLimiterReleaseMS), 10.0, 500.0)

        self.downwardExpanderEnabled = config.downwardExpanderEnabled
        self.expanderThresholdDB = clampf(Float(config.expanderThresholdDB), -60.0, -20.0)
        self.expanderRatio = clampf(Float(config.expanderRatio), 1.0, 8.0)
        self.expanderAttackMS = clampf(Float(config.expanderAttackMS), 0.1, 100.0)
        self.expanderReleaseMS = clampf(Float(config.expanderReleaseMS), 10.0, 2000.0)

        self.bassClipperEnabled = config.bassClipperEnabled
        self.bassClipperCrossoverHz = clampf(Float(config.bassClipperCrossoverHz), 60.0, 300.0)
        self.bassClipperThresholdDB = clampf(Float(config.bassClipperThresholdDB), -12.0, 0.0)
        self.bassClipperDrive = clampf(Float(config.bassClipperDrive), 0.5, 3.0)

        self.hfLimiterEnabled = config.hfLimiterEnabled
            && ChainFeature.hfLimiter.applies(in: mode)
        self.hfLimiterThresholdDB = clampf(Float(config.hfLimiterThresholdDB), -12.0, 0.0)
        self.hfLimiterTopThresholdDB = clampf(Float(config.hfLimiterTopThresholdDB), -12.0, 0.0)
        self.hfLimiterAttackMS = clampf(Float(config.hfLimiterAttackMS), 0.2, 20.0)
        self.hfLimiterReleaseMS = clampf(Float(config.hfLimiterReleaseMS), 5.0, 500.0)
        self.hfLimiterMaxReductionDB = clampf(Float(config.hfLimiterMaxReductionDB), 1.0, 24.0)

        self.dcClipperEnabled = config.dcClipperEnabled
        self.dcClipperCeilingDB = clampf(Float(config.dcClipperCeilingDB), -6.0, 0.0)
        self.dcClipperCancelFreqHz = clampf(Float(config.dcClipperCancelFreqHz), 500.0, 4000.0)
        self.processedAudioCoderHasClipper = config.processedAudioCoderHasClipper
        self.processedAudioFinalClipDrive =
            powf(10.0, clampf(Float(config.processedAudioFinalClipDriveDB), 0.0, 12.0) / 20.0)
        self.processedAudioCeiling =
            powf(10.0, clampf(Float(config.processedAudioCeilingDBTP), -6.0, 0.0) / 20.0)
        self.amNegativeCeiling = 100.0 / clampf(Float(config.amPositivePeakPct), 100.0, 125.0)

        self.bs412Enabled = config.bs412Enabled
        self.bs412CeilingDBr = clampf(Float(config.bs412CeilingDBr), -10.0, 0.0)
        self.compositeClipperEnabled = config.compositeClipperEnabled
        self.compositeClipperThresholdDB = clampf(Float(config.compositeClipperThresholdDB), -12.0, 0.0)
        self.compositeClipperCeilingDB = clampf(Float(config.compositeClipperCeilingDB), -6.0, 0.0)
        self.compositeClipperCancelAudio = config.compositeClipperCancelAudio
        self.compositeClipperStereoGuard = Float(config.compositeClipperStereoGuard)
        self.compositeClipperCancelPilot = config.compositeClipperCancelPilot
        self.compositeClipperCancelRDS = config.compositeClipperCancelRDS
        self.compositeClipperLookaheadMS = clampf(Float(config.compositeClipperLookaheadMS), 0.0, 5.0)
        self.compositeClipperOversampling = config.compositeClipperOversampling
        // SSB leaning is a property of the stereo ENCODER; there is no
        // encoder outside MPX Output, so the flag never reaches the chain in
        // another mode (it also stops the Hilbert FIRs from being allocated
        // for a subcarrier nobody generates).
        self.ssbStereoEnabled = config.ssbStereoEnabled
            && ChainFeature.stereoCoder.applies(in: mode)
        self.ssbStereoAmount = clampf(Float(config.ssbStereoAmount), 0.0, 1.0)

        // Processed-audio output mode, seeded from config at construction so
        // an engine that never calls setAudioOutputOnly (the ALSA engine) still
        // gets the audio-only path with the dual-rate boundary OFF and every
        // audio-domain stage derived at the output rate -- before this seed,
        // Linux processed-audio ran 48 kHz coefficients at the output rate and
        // the optional final clipper could never engage. The macOS engine's
        // setAudioOutputOnly call at start() is now an idempotent re-assert.
        self.audioOutputOnly = config.processedAudioOutput

        // Dual-rate audio chain boundary. Only enable if the requested
        // audio rate divides the engine rate evenly (Phase 1 integer-
        // ratio only). Non-integer ratios (176.4k → 48k) silently fall
        // back to disabled.
        let audioRateRequest = Float(max(8_000.0, config.dualRateAudioDomainRateHz))
        let factor = Int((self.sampleRate / audioRateRequest).rounded())
        let ratioIsClean = factor >= 2 && abs(self.sampleRate - Float(factor) * audioRateRequest) < 0.5
        self.dualRateRequested = config.dualRateAudioDomainEnabled
        self.dualRateBoundaryEnabled = config.dualRateAudioDomainEnabled && ratioIsClean && !audioOutputOnly
        self.dualRateAudioRate = ratioIsClean ? audioRateRequest : self.sampleRate
        self.programLowpassReferenceRate = audioRateRequest
        self.dualRateFactor = ratioIsClean ? factor : 1

        self.monoBassEnabled = config.monoBassEnabled
            && ChainFeature.stereoProgram.applies(in: mode)
        self.monoBassFreqHz = clampf(Float(config.monoBassFreqHz), 60.0, 250.0)
        // The coder is built from the mode-gated config, as the live path
        // (applyRDSRuntimeConfig) gates it: RDS exists only where a
        // composite does, so an engine built in FM / HD / AM Output with
        // en_rds on must not run an enabled coder.
        var rdsConfig = config
        rdsConfig.enRDS = config.enRDS && ChainFeature.rds.applies(in: mode)
        self.rdsCoder = BasicRDSCoder(
            config: rdsConfig,
            sampleRate: self.sampleRate,
            nowPlayingState: nowPlayingState
        )

        self.toneStep = 0.0

        // Audio-domain stages run at `audioDomainSampleRate` — equal to
        // `self.sampleRate` when the dual-rate boundary is disabled (so
        // behavior is bit-identical to pre-cutover), but drops to
        // `dualRateAudioRate` (typically 48 kHz) when the boundary is
        // on so each stage's filter coefficients land on the lower-rate
        // grid. Helpers like configureMultibandFilters() etc. read the
        // property directly.
        let audioRate = audioDomainSampleRate
        preL.configure(curve: preemphasisCurve, sampleRate: audioRate)
        preR.configure(curve: preemphasisCurve, sampleRate: audioRate)
        // Transmit-grade filters are the generator's DEFAULT: the linear-phase
        // encoder FIR and FIR multiband crossovers follow the config flags from
        // construction, so the offline verifier, the Linux ALSA engine and the
        // macOS engine all render the same chain. Only the low-latency monitor
        // output turns them off (AudioOutputEngine calls the setters). Until
        // 0.45 both defaulted to false and only AudioOutputEngine ever enabled
        // them, so every --verify* gate and the Linux build measured / shipped
        // the IIR monitor-path filters instead of the TX chain.
        useEncoderFIR = config.encoderFIREnabled
        useMultibandFIR = config.multibandFIREnabled
        applyEncoderComplianceConfiguration(sampleRate: self.sampleRate)

        widebandAGC.configure(
            sampleRate: audioRate,
            targetDB: widebandAGCTargetDB,
            attackMS: widebandAGCAttackMS,
            releaseMS: widebandAGCReleaseMS,
            minGainDB: widebandAGCMinGainDB,
            maxGainDB: widebandAGCMaxGainDB,
            kWeightingEnabled: widebandAGCKWeightingEnabled,
            programDependentRelease: widebandAGCReleaseProgramDependent,
            bassDesensitizeEnabled: widebandAGCBassDesensitizeEnabled
        )
        inputHPF.configureHighpass(cutoffHz: hpfHz, sampleRate: audioRate)
        hfTrim.configureHighShelf(gainDB: hfTrimDB, cutoffHz: hfTrimHz, sampleRate: audioRate)
        phaseRotator.configure(freqHz: phaseRotationFreqHz, sampleRate: audioRate)
        configureParametricEQ()
        configurePrimeBassFilters()
        configureMultibandFilters()
        configureMultibandCompressors()
        configureAdvancedDynamics()
        configureSSBStereo()
        configureMultibandLimiters()
        configureDownwardExpanders()
        configureStereoImage()
        bassClipper.configure(
            sampleRate: audioRate,
            crossoverHz: bassClipperCrossoverHz,
            thresholdDB: bassClipperThresholdDB,
            drive: bassClipperDrive
        )
        hfLimiter.configure(
            enabled: hfLimiterEnabled,
            sampleRate: audioRate,
            thresholdDB: hfLimiterThresholdDB,
            topThresholdDB: hfLimiterTopThresholdDB,
            attackMS: hfLimiterAttackMS,
            releaseMS: hfLimiterReleaseMS,
            maxReductionDB: hfLimiterMaxReductionDB
        )
        configureDistortionCancelledClipper()
        configureProcessedAudioFinalClipper()
        lookaheadLimiter.configure(
            sampleRate: self.sampleRate,
            lookaheadMS: limitLookaheadMS,
            threshold: threshold,
            enabled: limitEnabled && limitLookaheadEnabled
        )
        preEncodeThreshold = clampf(Float(config.preEncodeThreshold), 0.5, 0.999)
        preEncodeReleaseMS = clampf(Float(config.preEncodeReleaseMS), 10.0, 200.0)
        preEncodeLookaheadMS = clampf(Float(config.preEncodeLookaheadMS), 0.0, 5.0)
        preEncodeLookaheadHFOnly = config.preEncodeLookaheadHFOnly
        preEncodeLookaheadHFCutoffHz = clampf(Float(config.preEncodeLookaheadHFCutoffHz), 1_000.0, 12_000.0)
        preEncodeAudioLimiter.configure(
            sampleRate: audioRate,
            threshold: preEncodeThreshold,
            releaseMS: preEncodeReleaseMS,
            bandlimitedResidualEnabled: preEncodeBandlimitedResidualEnabled,
            residualTapCount: preEncodeBandlimitedResidualTapCount,
            residualCutoffFraction: preEncodeBandlimitedResidualCutoffFraction,
            lookaheadMS: preEncodeLookaheadMS,
            lookaheadHFOnly: preEncodeLookaheadHFOnly,
            lookaheadHFCutoffHz: preEncodeLookaheadHFCutoffHz,
            passbandHz: preEncodeLimiterPassbandHz
        )
        configureTruePeakGuard(sampleRate: audioRate)
        bs412Meter.configure(sampleRate: self.sampleRate)
        bs412Rider.configure(sampleRate: self.sampleRate)
        bs412Guard.configure(sampleRate: self.sampleRate,
                             subcarrierReserveMeanSquare: bs412SubcarrierReserve)
        compositeClipper.configure(
            sampleRate: self.sampleRate,
            thresholdDB: compositeClipperThresholdDB,
            ceilingDB: compositeClipperCeilingDB,
            cancelAudio: compositeClipperCancelAudio,
            stereoGuard: compositeClipperStereoGuard,
            cancelPilot: compositeClipperCancelPilot,
            cancelRDS: compositeClipperCancelRDS,
            lookaheadMS: compositeClipperLookaheadMS,
            oversamplingFactor: compositeClipperOversampling
        )
        configureDualRateBoundary()
        recomputeSubcarrierDelay()
        updateDerivedRates()
        configureMonitorDemod()
    }

    /// Configure (or disable) the dual-rate audio chain boundary. Called
    /// at engine init and on any AppConfig change that touches the
    /// boundary. Allocates / resizes the decimator + interpolator state
    /// — restart-required from the operator's perspective.
    private func configureDualRateBoundary() {
        guard dualRateBoundaryEnabled && dualRateFactor >= 2 else {
            // Disabled: clear state so the boundary path no-ops cleanly.
            inputDecimL.reset()
            inputDecimR.reset()
            inputInterpL.reset()
            inputInterpR.reset()
            if interpOutBufferL.count != max(1, dualRateFactor) {
                interpOutBufferL = [Float](repeating: 0.0, count: max(1, dualRateFactor))
                interpOutBufferR = [Float](repeating: 0.0, count: max(1, dualRateFactor))
            } else {
                for i in 0..<interpOutBufferL.count {
                    interpOutBufferL[i] = 0
                    interpOutBufferR[i] = 0
                }
            }
            dualRateBoundaryPushCount = 0
            dualRateBoundaryPhase = 0
            return
        }
        // Cutoff at 90% of audio-rate Nyquist so the transition band sits
        // safely below the audio-rate Nyquist; 4 kHz transition width.
        // Stopband 90 dB matches the composite clipper's decimator.
        let cutoffHz = dualRateAudioRate * 0.5 * 0.9
        let transitionHz: Float = 4_000.0
        inputDecimL.configure(
            cutoffHz: cutoffHz,
            sampleRateOS: self.sampleRate,
            decimateFactor: dualRateFactor,
            stopBandDB: 90.0,
            transitionHz: transitionHz
        )
        inputDecimR.configure(
            cutoffHz: cutoffHz,
            sampleRateOS: self.sampleRate,
            decimateFactor: dualRateFactor,
            stopBandDB: 90.0,
            transitionHz: transitionHz
        )
        inputInterpL.configure(
            cutoffHz: cutoffHz,
            sampleRateOS: self.sampleRate,
            interpolateFactor: dualRateFactor,
            stopBandDB: 90.0,
            transitionHz: transitionHz
        )
        inputInterpR.configure(
            cutoffHz: cutoffHz,
            sampleRateOS: self.sampleRate,
            interpolateFactor: dualRateFactor,
            stopBandDB: 90.0,
            transitionHz: transitionHz
        )
        if interpOutBufferL.count != dualRateFactor {
            interpOutBufferL = [Float](repeating: 0.0, count: dualRateFactor)
            interpOutBufferR = [Float](repeating: 0.0, count: dualRateFactor)
        } else {
            for i in 0..<dualRateFactor {
                interpOutBufferL[i] = 0
                interpOutBufferR[i] = 0
            }
        }
        dualRateBoundaryPushCount = 0
        dualRateBoundaryPhase = 0
    }

    /// Per-OS-sample dual-rate boundary application. Pushes input into the
    /// decim → audio-domain → interp pair and reads back the corresponding
    /// OS-rate audio-domain output. When decim emits (every Lth OS tick),
    /// the whole audio domain (`processAudioDomain`) runs at the lower
    /// audio rate on the just-emitted sample, then its L/R output is
    /// pushed through interp to produce L OS-rate samples that the MPX
    /// domain consumes one-per-tick. Side outputs (analysisStereo,
    /// inputActivity) are stored on the engine so the MPX domain can read
    /// them every OS tick even though they only refresh once per L ticks.
    ///
    /// Real-time safe; no allocations. Caller checks
    /// `dualRateBoundaryEnabled` before invoking.
    @inline(__always)
    private func applyDualRateBoundary(left: inout Float, right: inout Float) {
        let decimL = inputDecimL.push(left)
        let decimR = inputDecimR.push(right)
        dualRateBoundaryPushCount += 1
        if dualRateBoundaryPushCount >= dualRateFactor {
            dualRateBoundaryPushCount = 0
            // Decim just emitted one audio-rate L/R sample. Run the
            // entire audio-domain chain on it at audio rate — every
            // stage's filter coefficients were configured against
            // `audioDomainSampleRate` at engine init.
            let audio = processAudioDomain(leftIn: decimL, rightIn: decimR)
            latestAudioAnalysisStereo = audio.analysisStereo
            latestAudioInputActivity = audio.inputActivity
            // Push audio-domain output through interp; refill the L-
            // element output buffer with the upsampled MPX-rate samples.
            interpOutBufferL.withUnsafeMutableBufferPointer { lBuf in
                // baseAddress non-nil for pre-allocated arrays.
                // swiftlint:disable:next force_unwrapping
                inputInterpL.push(audio.left, into: lBuf.baseAddress!)
            }
            interpOutBufferR.withUnsafeMutableBufferPointer { rBuf in
                // swiftlint:disable:next force_unwrapping
                inputInterpR.push(audio.right, into: rBuf.baseAddress!)
            }
            // Reset the read phase to 0 on refill so the next L OS-rate
            // reads walk buffer[0..L-1] in chronological order
            // (out[0] is the earliest upsampled sample, out[L-1] is the
            // latest — see LinearPhaseFIRInterpolator emission contract).
            // Reading in any other order — e.g. starting from the just-
            // filled buffer[L-1] and wrapping to [0] on the next tick —
            // introduces a per-cycle L-1-sample temporal discontinuity
            // that destroys phase coherence and trashes stereo
            // separation at the receiver.
            dualRateBoundaryPhase = 0
        }
        left = interpOutBufferL[dualRateBoundaryPhase]
        right = interpOutBufferR[dualRateBoundaryPhase]
        dualRateBoundaryPhase += 1
        if dualRateBoundaryPhase >= dualRateFactor { dualRateBoundaryPhase = 0 }
    }

    /// Recompute the pilot+RDS delay-line length so it matches the audio
    /// composite's total chain delay through audio-composite bandwidth
    /// cleanup + composite clipper + final MPX limiter look-ahead. Called
    /// after any stage configure() that could change the audio path delay
    /// (init, setSampleRate, runtime reconfigure on compositeClipper change).
    private func recomputeSubcarrierDelay() {
        let clipperDelay = compositeClipperEnabled
            ? compositeClipper.totalDelayHostSamples : 0
        let clipperDelayCapacity = compositeClipperEnabled
            ? compositeClipper.maxTotalDelayHostSamples : 0
        let compositeBandwidthDelay = audioCompositeBandwidthFIR.groupDelaySamples
        // Only a limiter that RUNS delays the audio: with
        // `limit_lookahead_enabled = false` the stage is configured disabled
        // and returns its input with no delay, and counting its look-ahead
        // here rotated the pilot against the audio's 38 kHz carrier (about
        // 170 degrees at a 1.3 ms look-ahead; peak-control review F12).
        let limiterDelay = limitEnabled ? lookaheadLimiter.latencySamples : 0
        // NB: the dual-rate boundary's decim+interp delay is NOT added
        // here. The boundary sits upstream of the stereo encoder; the
        // 38 kHz subcarrier embedded in the audio composite is generated
        // FRESH by the encoder at each OS tick, AFTER the boundary. So
        // is the pilot. Both traverse only the post-encoder stages
        // (audio-composite bandwidth FIR, composite clipper, final-MPX
        // safety limiter), and the pilot
        // needs to delay by exactly those to stay phase-locked with the
        // embedded carrier at the receiver. Adding the boundary delay
        // here over-delays the pilot and trashes stereo separation at
        // the production decoder (the encoder-side sidebands stay
        // balanced, but the pilot PLL recovers a 38 kHz reference that
        // is phase-rotated relative to the actual embedded carrier).
        let total = compositeBandwidthDelay + clipperDelay + limiterDelay
        let capacity = compositeBandwidthDelay + clipperDelayCapacity + limiterDelay
        if total != subcarrierDelayActiveCount || capacity > subcarrierDelayLine.count {
            Self.resizeDelayPreservingContentsInPlace(
                line: &subcarrierDelayLine,
                scratch: &subcarrierDelayResizeScratch,
                writeIdx: subcarrierDelayWriteIdx,
                oldCount: subcarrierDelayActiveCount,
                newCount: total,
                requiredCapacity: capacity
            )
            subcarrierDelayWriteIdx = 0
            Self.resizeDelayPreservingContentsInPlace(
                line: &stereoSubcarrierDelayLine,
                scratch: &stereoSubcarrierDelayResizeScratch,
                writeIdx: stereoSubcarrierDelayWriteIdx,
                oldCount: subcarrierDelayActiveCount,
                newCount: total,
                requiredCapacity: capacity
            )
            stereoSubcarrierDelayWriteIdx = 0
            subcarrierDelayActiveCount = total
        }
    }

    /// Change a delay line's active logical length while preserving the most
    /// recent samples in time order. If the required capacity is already
    /// available, this is allocation-free and only copies within preallocated
    /// storage. Structural changes may grow storage outside normal slider-drag
    /// use; live composite-lookahead updates should stay inside capacity.
    private static func resizeDelayPreservingContentsInPlace(
        line: inout [Float],
        scratch: inout [Float],
        writeIdx: Int,
        oldCount: Int,
        newCount: Int,
        requiredCapacity: Int
    ) {
        let capacity = max(0, requiredCapacity)
        if line.count < capacity {
            line = Self.resizedDelayPreservingContents(
                line: line,
                writeIdx: writeIdx,
                oldCount: oldCount,
                newCount: newCount,
                requiredCapacity: capacity
            )
            scratch = [Float](repeating: 0.0, count: capacity)
            return
        }
        if scratch.count < line.count {
            scratch = [Float](repeating: 0.0, count: line.count)
        }
        guard newCount > 0 else { return }
        for i in 0..<newCount {
            scratch[i] = 0.0
        }
        guard oldCount > 0 else {
            for i in 0..<newCount {
                line[i] = 0.0
            }
            return
        }
        let copyN = min(oldCount, newCount)
        let dstStart = newCount - copyN
        var srcIdx = (writeIdx + oldCount - copyN) % oldCount
        for i in 0..<copyN {
            scratch[dstStart + i] = line[srcIdx]
            srcIdx = (srcIdx + 1) % oldCount
        }
        for i in 0..<newCount {
            line[i] = scratch[i]
        }
    }

    private static func resizedDelayPreservingContents(
        line: [Float],
        writeIdx: Int,
        oldCount: Int,
        newCount: Int,
        requiredCapacity: Int
    ) -> [Float] {
        if requiredCapacity == 0 { return [] }
        var result = [Float](repeating: 0.0, count: requiredCapacity)
        guard newCount > 0, oldCount > 0 else { return result }
        let copyN = min(oldCount, newCount)
        let dstStart = newCount - copyN
        var srcIdx = (writeIdx + oldCount - copyN) % oldCount
        for i in 0..<copyN {
            result[dstStart + i] = line[srcIdx]
            srcIdx = (srcIdx + 1) % oldCount
        }
        return result
    }

    /// Called by AudioOutputEngine at start() to pick the TX-grade FIR or
    /// low-latency Butterworth for the encoder program lowpass, based on the
    /// engine's output mode (composite/monitor) and the user's config toggle.
    /// Enable processed-audio output mode. Must be set before `setSampleRate` /
    /// config application so the dual-rate boundary is computed with it off.
    func setAudioOutputOnly(_ enabled: Bool) {
        audioOutputOnly = enabled
        if enabled, dualRateBoundaryEnabled {
            // The whole engine runs at the output rate in this mode; no
            // MPX-rate upsampling boundary. Switching the boundary off moves
            // `audioDomainSampleRate` from 48 kHz to the output rate, so EVERY
            // audio-domain stage must be re-derived -- until 0.45 nothing was,
            // and processed-audio output ran pre-emphasis, limiters and
            // crossovers with 48 kHz coefficients at 192 kHz (only the encoder
            // FIR / multiband setters happened to reconfigure afterwards).
            dualRateBoundaryEnabled = false
            configureDualRateBoundary()
            reconfigureStagesForCurrentRates()
        }
    }

    func setEncoderFIREnabled(_ enabled: Bool) {
        if enabled == useEncoderFIR { return }
        useEncoderFIR = enabled
        // CRITICAL: encoderProgramLP / encoderProgramFIR are AUDIO-DOMAIN
        // stages — they run at `audioDomainSampleRate`, which is the
        // engine's MPX sample rate when the dual-rate boundary is off but
        // drops to `dualRateAudioRate` (48 kHz default) when on. Using
        // `self.sampleRate` here would clobber the correct configuration
        // applied in `applyEncoderComplianceConfiguration(sampleRate:)`
        // and produce a filter designed for the wrong rate — at boundary-
        // on the 14.9 kHz cutoff would effectively become 14.9/4 ≈ 3.7 kHz
        // when applied to 48 kHz data, catastrophically destroying HF.
        // Pre-0.30.1 this was the v0.30 "lost a lot of high frequencies"
        // regression.
        let audioRate = audioDomainSampleRate
        encoderProgramLP.configure(
            cutoffHz: effectiveEncoderLowpassHz(
                configured: programLowpassHz, preemphasisUS: preemphasisUS,
                digital: digitalDelivery),
            sampleRate: audioRate
        )
        encoderProgramFIR.configure(
            cutoffHz: effectiveEncoderLowpassHz(
                configured: programLowpassHz, preemphasisUS: preemphasisUS,
                digital: digitalDelivery),
            sampleRate: audioRate,
            transitionHz: encoderFIRTransitionHz
        )
    }

    var encoderFIRTapCount: Int { encoderProgramFIR.tapCount }
    var encoderFIRGroupDelaySamples: Int { encoderProgramFIR.groupDelaySamples }

    /// Called by AudioOutputEngine at start() to pick linear-phase FIR
    /// multiband crossovers (TX) over IIR LR4 (monitor). Phase-flat
    /// reconstruction kills the transient-smear / inter-band-pumping
    /// artifacts that make multiband sound worse than single-band on
    /// percussive content.
    func setMultibandFIREnabled(_ enabled: Bool) {
        if enabled == useMultibandFIR { return }
        useMultibandFIR = enabled
        configureMultibandFilters()
    }

    var multibandFIRGroupDelaySamples: Int {
        useMultibandFIR
            ? max(mb5FIRSplitter.groupDelaySamples, mb3FIRSplitter.groupDelaySamples)
            : 0
    }

    func setSampleRate(_ newSampleRate: Double) {
        let sr = Float(max(8_000.0, newSampleRate))
        if fabsf(sr - sampleRate) < 0.1 {
            return
        }
        sampleRate = sr
        // The boundary's factor is a property of the MPX rate: 192 -> 96 kHz
        // must go from 4 to 2 (it stayed at 4, so the audio domain ran at
        // 24 kHz on 48 kHz coefficients), and a rate that is not an integer
        // multiple of the audio rate turns the boundary off, as at
        // construction. The resamplers are rebuilt for the new rate.
        deriveDualRateBoundary()
        configureDualRateBoundary()
        reconfigureStagesForCurrentRates()
    }

    /// The dual-rate factor, audio rate and on/off state for the current MPX
    /// rate -- the same rule the initialiser applies.
    private func deriveDualRateBoundary() {
        let audioRateRequest = programLowpassReferenceRate
        let factor = Int((sampleRate / audioRateRequest).rounded())
        let ratioIsClean = factor >= 2 && abs(sampleRate - Float(factor) * audioRateRequest) < 0.5
        dualRateBoundaryEnabled = dualRateRequested && ratioIsClean && !audioOutputOnly
        dualRateAudioRate = ratioIsClean ? audioRateRequest : sampleRate
        dualRateFactor = ratioIsClean ? factor : 1
    }

    /// Re-derive every stage's coefficients for the current MPX rate and
    /// audio-domain rate. Audio-domain stages run at `audioDomainSampleRate`
    /// (= MPX rate when the dual-rate boundary is off, audio rate when on);
    /// using `self.sampleRate` for them would produce filters designed for
    /// the wrong rate -- the pre-0.30.1 setEncoderFIR regression. Called on
    /// a sample-rate change and whenever the boundary itself is switched.
    private func reconfigureStagesForCurrentRates() {
        let audioRate = audioDomainSampleRate
        preL.configure(curve: preemphasisCurve, sampleRate: audioRate)
        preR.configure(curve: preemphasisCurve, sampleRate: audioRate)
        applyEncoderComplianceConfiguration(sampleRate: sampleRate)
        widebandAGC.configure(
            sampleRate: audioRate,
            targetDB: widebandAGCTargetDB,
            attackMS: widebandAGCAttackMS,
            releaseMS: widebandAGCReleaseMS,
            minGainDB: widebandAGCMinGainDB,
            maxGainDB: widebandAGCMaxGainDB,
            kWeightingEnabled: widebandAGCKWeightingEnabled,
            programDependentRelease: widebandAGCReleaseProgramDependent,
            bassDesensitizeEnabled: widebandAGCBassDesensitizeEnabled
        )
        inputHPF.configureHighpass(cutoffHz: hpfHz, sampleRate: audioRate)
        hfTrim.configureHighShelf(gainDB: hfTrimDB, cutoffHz: hfTrimHz, sampleRate: audioRate)
        phaseRotator.configure(freqHz: phaseRotationFreqHz, sampleRate: audioRate)
        configureParametricEQ()
        configurePrimeBassFilters()
        configureMultibandFilters()
        configureMultibandCompressors()
        configureAdvancedDynamics()
        configureSSBStereo()
        configureMultibandLimiters()
        configureDownwardExpanders()
        configureStereoImage()
        bassClipper.configure(
            sampleRate: audioRate,
            crossoverHz: bassClipperCrossoverHz,
            thresholdDB: bassClipperThresholdDB,
            drive: bassClipperDrive
        )
        hfLimiter.configure(
            enabled: hfLimiterEnabled,
            sampleRate: audioRate,
            thresholdDB: hfLimiterThresholdDB,
            topThresholdDB: hfLimiterTopThresholdDB,
            attackMS: hfLimiterAttackMS,
            releaseMS: hfLimiterReleaseMS,
            maxReductionDB: hfLimiterMaxReductionDB
        )
        configureDistortionCancelledClipper()
        configureProcessedAudioFinalClipper()
        lookaheadLimiter.configure(
            sampleRate: sampleRate,
            lookaheadMS: limitLookaheadMS,
            threshold: threshold,
            enabled: limitEnabled && limitLookaheadEnabled
        )
        // preEncodeAudioLimiter is audio-domain (L/R, runs before stereo
        // encode) → audioRate. lookaheadLimiter and bs412Limiter are
        // MPX-domain (composite-side) → sampleRate.
        preEncodeAudioLimiter.configure(
            sampleRate: audioRate,
            threshold: preEncodeThreshold,
            releaseMS: preEncodeReleaseMS,
            bandlimitedResidualEnabled: preEncodeBandlimitedResidualEnabled,
            residualTapCount: preEncodeBandlimitedResidualTapCount,
            residualCutoffFraction: preEncodeBandlimitedResidualCutoffFraction,
            lookaheadMS: preEncodeLookaheadMS,
            lookaheadHFOnly: preEncodeLookaheadHFOnly,
            lookaheadHFCutoffHz: preEncodeLookaheadHFCutoffHz,
            passbandHz: preEncodeLimiterPassbandHz
        )
        configureTruePeakGuard(sampleRate: audioRate)
        bs412Meter.configure(sampleRate: sampleRate)
        bs412Rider.configure(sampleRate: sampleRate)
        bs412Guard.configure(sampleRate: sampleRate,
                             subcarrierReserveMeanSquare: bs412SubcarrierReserve)
        compositeClipper.configure(
            sampleRate: sampleRate,
            thresholdDB: compositeClipperThresholdDB,
            ceilingDB: compositeClipperCeilingDB,
            cancelAudio: compositeClipperCancelAudio,
            stereoGuard: compositeClipperStereoGuard,
            cancelPilot: compositeClipperCancelPilot,
            cancelRDS: compositeClipperCancelRDS,
            lookaheadMS: compositeClipperLookaheadMS,
            oversamplingFactor: compositeClipperOversampling
        )
        recomputeSubcarrierDelay()
        rdsCoder?.setSampleRate(sampleRate)
        updateDerivedRates()
        configureMonitorDemod()
    }

    func applyRuntimeConfig(_ config: RuntimeConfig) {
        // Rate domains, named so a call site cannot pick the wrong one by
        // accident. Audio-domain stages (everything before stereo encoding)
        // run at `audioRate`; composite-side stages run at `mpxRate`. Until
        // 0.65 the AGC, the phase rotator and the bass clipper took the MPX
        // rate here while construction gave them the audio rate, so one live
        // edit made their time constants and corners 4x wrong until restart.
        let audioRate = audioDomainSampleRate
        let mpxRate = sampleRate
        inputGain = powf(10.0, config.inputGainDB / 20.0)
        outputGain = powf(10.0, config.outputGainDB / 20.0)
        finalDrive = powf(10.0, config.finalDriveDB / 20.0)
        deviationScale = config.mpxDeviationKHz / Self.referenceDeviationKHz
        pilotLevel = config.pilotLevel
        // Both of the above feed the BS.412 guard's future-subcarrier
        // reserve, and both are live-apply. Refreshing it is O(1) and keeps
        // the accumulated window; leaving it stale under-charges the
        // unobserved slots and lets a completed window run over.
        bs412Guard.setSubcarrierReserve(bs412SubcarrierReserve)
        pilotInjectionPercent = config.pilotLevel * 100.0
        let preEncodeLimiterChanged =
            preEncodeAudioLimiterEnabled != config.preEncodeAudioLimiterEnabled
            || fabsf(preEncodeThreshold - config.preEncodeThreshold) > 0.0001
            || fabsf(preEncodeReleaseMS - config.preEncodeReleaseMS) > 0.001
            || preEncodeBandlimitedResidualEnabled != config.preEncodeBandlimitedResidualEnabled
            || preEncodeBandlimitedResidualTapCount != config.preEncodeBandlimitedResidualTapCount
            || fabsf(preEncodeBandlimitedResidualCutoffFraction - config.preEncodeBandlimitedResidualCutoffFraction) > 0.0001
        preEncodeAudioLimiterEnabled = config.preEncodeAudioLimiterEnabled
        preEncodeThreshold = clampf(config.preEncodeThreshold, 0.5, 0.999)
        preEncodeReleaseMS = clampf(config.preEncodeReleaseMS, 10.0, 200.0)
        preEncodeBandlimitedResidualEnabled = config.preEncodeBandlimitedResidualEnabled
        preEncodeBandlimitedResidualTapCount = max(5, min(129, config.preEncodeBandlimitedResidualTapCount | 1))
        preEncodeBandlimitedResidualCutoffFraction = clampf(config.preEncodeBandlimitedResidualCutoffFraction, 0.05, 0.49)
        if preEncodeLimiterChanged {
            // Preserve the existing lookahead settings on live-apply
            // reconfigure. lookahead + HF-only + HF cutoff are restart-only
            // (not in RuntimeConfig), so the current values held on the audio
            // thread are authoritative; without passing them explicitly the
            // limiter would reset to defaults and silently drop the
            // operator's lookahead config. Audio-domain stage: configure at
            // audioDomainSampleRate (until 0.45 this passed the MPX rate, so
            // one live threshold change made look-ahead / attack / release /
            // hold 4x too long and moved the HF detector from 4 kHz to 1 kHz).
            preEncodeAudioLimiter.configure(
                sampleRate: audioRate,
                threshold: preEncodeThreshold,
                releaseMS: preEncodeReleaseMS,
                bandlimitedResidualEnabled: preEncodeBandlimitedResidualEnabled,
                residualTapCount: preEncodeBandlimitedResidualTapCount,
                residualCutoffFraction: preEncodeBandlimitedResidualCutoffFraction,
                lookaheadMS: preEncodeLookaheadMS,
                lookaheadHFOnly: preEncodeLookaheadHFOnly,
                lookaheadHFCutoffHz: preEncodeLookaheadHFCutoffHz,
                passbandHz: preEncodeLimiterPassbandHz
            )
            configureTruePeakGuard(sampleRate: audioRate)
        }

        let agcChanged =
            widebandAGCEnabled != config.widebandAGCEnabled
            || fabsf(widebandAGCTargetDB - config.widebandAGCTargetDB) > 0.0001
            || fabsf(widebandAGCMaxGainDB - config.widebandAGCMaxGainDB) > 0.0001
            || fabsf(widebandAGCMinGainDB - config.widebandAGCMinGainDB) > 0.0001
            || fabsf(widebandAGCAttackMS - config.widebandAGCAttackMS) > 0.0001
            || fabsf(widebandAGCReleaseMS - config.widebandAGCReleaseMS) > 0.0001

        widebandAGCEnabled = config.widebandAGCEnabled
        widebandAGCTargetDB = config.widebandAGCTargetDB
        widebandAGCMaxGainDB = config.widebandAGCMaxGainDB
        widebandAGCMinGainDB = config.widebandAGCMinGainDB
        widebandAGCAttackMS = config.widebandAGCAttackMS
        widebandAGCReleaseMS = config.widebandAGCReleaseMS

        let agcFlagsChanged =
            widebandAGCKWeightingEnabled != config.widebandAGCKWeightingEnabled
            || widebandAGCReleaseProgramDependent != config.widebandAGCReleaseProgramDependent
            || widebandAGCBassDesensitizeEnabled != config.widebandAGCBassDesensitizeEnabled
        widebandAGCKWeightingEnabled = config.widebandAGCKWeightingEnabled
        widebandAGCReleaseProgramDependent = config.widebandAGCReleaseProgramDependent
        widebandAGCBassDesensitizeEnabled = config.widebandAGCBassDesensitizeEnabled

        if agcChanged || agcFlagsChanged {
            widebandAGC.configure(
                sampleRate: audioRate,
                targetDB: widebandAGCTargetDB,
                attackMS: widebandAGCAttackMS,
                releaseMS: widebandAGCReleaseMS,
                minGainDB: widebandAGCMinGainDB,
                maxGainDB: widebandAGCMaxGainDB,
                kWeightingEnabled: widebandAGCKWeightingEnabled,
                programDependentRelease: widebandAGCReleaseProgramDependent,
                bassDesensitizeEnabled: widebandAGCBassDesensitizeEnabled
            )
        }

        let primeBassFiltersChanged =
            primeBassEnabled != config.primeBassEnabled
            || fabsf(primeBassFreqHz - config.primeBassFreqHz) > 0.0001
        primeBassEnabled = config.primeBassEnabled
        primeBassAmount = clampf(config.primeBassAmount, 0.0, 1.0)
        primeBassHarmonics = clampf(config.primeBassHarmonics, 0.0, 1.0)
        primeBassDensity = clampf(config.primeBassDensity, 0.0, 1.0)
        primeBassSubharmonicsEnabled = config.primeBassSubharmonicsEnabled
        primeBassSubharmonicsAmount = clampf(config.primeBassSubharmonicsAmount, 0.0, 1.0)
        let primeBassDriveChanged =
            fabsf(primeBassDrive - clampf(config.primeBassDrive, 0.0, 2.5)) > 0.0001
        primeBassDrive = clampf(config.primeBassDrive, 0.0, 2.5)
        primeBassFreqHz = clampf(config.primeBassFreqHz, 45.0, 220.0)
        if primeBassFiltersChanged {
            configurePrimeBassFilters()
        } else if primeBassDriveChanged {
            configurePrimeBassOddDevice()
        }

        let effectiveMonoBassEnabled = config.monoBassEnabled
            && ChainFeature.stereoProgram.applies(in: operatingMode)
        let stereoImageChanged =
            monoBassEnabled != effectiveMonoBassEnabled
            || fabsf(monoBassFreqHz - config.monoBassFreqHz) > 0.0001
        monoBassEnabled = effectiveMonoBassEnabled
        monoBassFreqHz = clampf(config.monoBassFreqHz, 60.0, 250.0)
        if stereoImageChanged {
            configureStereoImage()
        }

        let resolvedCrossovers = Self.resolveMultibandCrossovers(
            sampleRate: mpxRate,
            x1: config.multibandX1Hz,
            x2: config.multibandX2Hz,
            x3: config.multibandX3Hz,
            x4: config.multibandX4Hz
        )
        let multibandStructureChanged =
            multibandEnabled != config.multibandEnabled
            || multibandMode != (config.multibandMode == 5 ? 5 : 3)
            || fabsf(multibandX1Hz - resolvedCrossovers.x1) > 0.0001
            || fabsf(multibandX2Hz - resolvedCrossovers.x2) > 0.0001
            || fabsf(multibandX3Hz - resolvedCrossovers.x3) > 0.0001
            || fabsf(multibandX4Hz - resolvedCrossovers.x4) > 0.0001
        let multibandCompressorChanged =
            fabsf(multibandKneeDB - config.multibandKneeDB) > 0.0001
            || multibandReleaseProgramDependent != config.multibandReleaseProgramDependent
            || multibandTransientAwareAttackEnabled != config.multibandTransientAwareAttackEnabled
            || multibandInterBandCouplingEnabled != config.multibandInterBandCouplingEnabled
            || fabsf(multibandLowThresholdDB - config.multibandLowThresholdDB) > 0.0001
            || fabsf(multibandMidThresholdDB - config.multibandMidThresholdDB) > 0.0001
            || fabsf(multibandHighThresholdDB - config.multibandHighThresholdDB) > 0.0001
            || fabsf(multibandLowRatio - config.multibandLowRatio) > 0.0001
            || fabsf(multibandMidRatio - config.multibandMidRatio) > 0.0001
            || fabsf(multibandHighRatio - config.multibandHighRatio) > 0.0001
            || fabsf(multibandLowAttackMS - config.multibandLowAttackMS) > 0.0001
            || fabsf(multibandMidAttackMS - config.multibandMidAttackMS) > 0.0001
            || fabsf(multibandHighAttackMS - config.multibandHighAttackMS) > 0.0001
            || fabsf(multibandLowReleaseMS - config.multibandLowReleaseMS) > 0.0001
            || fabsf(multibandMidReleaseMS - config.multibandMidReleaseMS) > 0.0001
            || fabsf(multibandHighReleaseMS - config.multibandHighReleaseMS) > 0.0001
        multibandEnabled = config.multibandEnabled
        multibandMode = (config.multibandMode == 5) ? 5 : 3
        multibandMakeup = powf(10.0, config.multibandMakeupDB / 20.0)
        multibandKneeDB = clampf(config.multibandKneeDB, 0.0, 12.0)
        multibandLinkStrength = ChainFeature.stereoProgram.applies(in: operatingMode)
            ? clampf(config.multibandLinkStrength, 0.0, 1.0) : 0.0
        multibandReleaseProgramDependent = config.multibandReleaseProgramDependent
        multibandTransientAwareAttackEnabled = config.multibandTransientAwareAttackEnabled
        multibandInterBandCouplingEnabled = config.multibandInterBandCouplingEnabled
        multibandX1Hz = resolvedCrossovers.x1
        multibandX2Hz = resolvedCrossovers.x2
        multibandX3Hz = resolvedCrossovers.x3
        multibandX4Hz = resolvedCrossovers.x4
        multibandLowThresholdDB = config.multibandLowThresholdDB
        multibandMidThresholdDB = config.multibandMidThresholdDB
        multibandHighThresholdDB = config.multibandHighThresholdDB
        multibandLowRatio = config.multibandLowRatio
        multibandMidRatio = config.multibandMidRatio
        multibandHighRatio = config.multibandHighRatio
        multibandLowAttackMS = config.multibandLowAttackMS
        multibandMidAttackMS = config.multibandMidAttackMS
        multibandHighAttackMS = config.multibandHighAttackMS
        multibandLowReleaseMS = config.multibandLowReleaseMS
        multibandMidReleaseMS = config.multibandMidReleaseMS
        multibandHighReleaseMS = config.multibandHighReleaseMS
        if multibandStructureChanged {
            configureMultibandFilters()
        }
        if multibandStructureChanged || multibandCompressorChanged {
            configureMultibandCompressors()
        }

        // Advanced Dynamics (single-stage leveler). Structure (FIR split)
        // rebuilds only on enable-toggle or crossover change -- the same
        // rare-operator-action allocation the multiband FIR reconfigure
        // above already performs. Parameter tweaks are cheap coefficient
        // updates.
        let advancedDynamicsToggled =
            advancedDynamicsEnabled != config.advancedDynamicsEnabled
        let advancedDynamicsParamsChanged =
            fabsf(advancedDynamicsTargetDB - config.advancedDynamicsTargetDB) > 0.0001
            || fabsf(advancedDynamicsLowOffsetDB - config.advancedDynamicsLowOffsetDB) > 0.0001
            || fabsf(advancedDynamicsMidOffsetDB - config.advancedDynamicsMidOffsetDB) > 0.0001
            || fabsf(advancedDynamicsHighOffsetDB - config.advancedDynamicsHighOffsetDB) > 0.0001
            || fabsf(advancedDynamicsMaxGainDB - config.advancedDynamicsMaxGainDB) > 0.0001
            || fabsf(advancedDynamicsDensity - config.advancedDynamicsDensity) > 0.0001
            || fabsf(advancedDynamicsSpeed - config.advancedDynamicsSpeed) > 0.0001
        advancedDynamicsEnabled = config.advancedDynamicsEnabled
        advancedDynamicsTargetDB = clampf(config.advancedDynamicsTargetDB, -30.0, -6.0)
        advancedDynamicsLowOffsetDB = clampf(config.advancedDynamicsLowOffsetDB, -12.0, 6.0)
        advancedDynamicsMidOffsetDB = clampf(config.advancedDynamicsMidOffsetDB, -12.0, 6.0)
        advancedDynamicsHighOffsetDB = clampf(config.advancedDynamicsHighOffsetDB, -12.0, 6.0)
        advancedDynamicsMaxGainDB = clampf(config.advancedDynamicsMaxGainDB, 0.0, 24.0)
        advancedDynamicsDensity = clampf(config.advancedDynamicsDensity, 0.0, 1.0)
        advancedDynamicsSpeed = clampf(config.advancedDynamicsSpeed, 0.25, 4.0)
        if advancedDynamicsToggled
            || (advancedDynamicsEnabled
                && (multibandStructureChanged || !advancedDynamicsStructureConfigured)) {
            configureAdvancedDynamics()
        } else if advancedDynamicsEnabled && advancedDynamicsParamsChanged {
            applyAdvancedDynamicsParameters()
        }

        // Phase rotator
        let phaseRotChanged =
            phaseRotationEnabled != config.phaseRotationEnabled
            || fabsf(phaseRotationFreqHz - config.phaseRotationFreqHz) > 0.0001
        phaseRotationEnabled = config.phaseRotationEnabled
        phaseRotationFreqHz = clampf(config.phaseRotationFreqHz, 50.0, 500.0)
        if phaseRotChanged {
            phaseRotator.configure(freqHz: phaseRotationFreqHz, sampleRate: audioRate)
        }

        // Parametric EQ
        let peqChanged =
            parametricEQEnabled != config.parametricEQEnabled
            || fabsf(peqB1FreqHz - config.peqB1FreqHz) > 0.0001
            || fabsf(peqB1GainDB - config.peqB1GainDB) > 0.0001
            || fabsf(peqB2FreqHz - config.peqB2FreqHz) > 0.0001
            || fabsf(peqB2GainDB - config.peqB2GainDB) > 0.0001
            || fabsf(peqB2Q - config.peqB2Q) > 0.0001
            || fabsf(peqB3FreqHz - config.peqB3FreqHz) > 0.0001
            || fabsf(peqB3GainDB - config.peqB3GainDB) > 0.0001
            || fabsf(peqB3Q - config.peqB3Q) > 0.0001
            || fabsf(peqB4FreqHz - config.peqB4FreqHz) > 0.0001
            || fabsf(peqB4GainDB - config.peqB4GainDB) > 0.0001
        parametricEQEnabled = config.parametricEQEnabled
        peqB1FreqHz = clampf(config.peqB1FreqHz, 20.0, 500.0)
        peqB1GainDB = clampf(config.peqB1GainDB, -12.0, 12.0)
        peqB2FreqHz = clampf(config.peqB2FreqHz, 100.0, 5000.0)
        peqB2GainDB = clampf(config.peqB2GainDB, -12.0, 12.0)
        peqB2Q = clampf(config.peqB2Q, 0.1, 10.0)
        peqB3FreqHz = clampf(config.peqB3FreqHz, 500.0, 12000.0)
        peqB3GainDB = clampf(config.peqB3GainDB, -12.0, 12.0)
        peqB3Q = clampf(config.peqB3Q, 0.1, 10.0)
        peqB4FreqHz = clampf(config.peqB4FreqHz, 1000.0, 16000.0)
        peqB4GainDB = clampf(config.peqB4GainDB, -12.0, 12.0)
        if peqChanged {
            configureParametricEQ()
        }

        // Multiband limiter
        let mbLimChanged =
            multibandLimiterEnabled != config.multibandLimiterEnabled
            || fabsf(multibandLimiterThresholdDB - config.multibandLimiterThresholdDB) > 0.0001
            || fabsf(multibandLimiterAttackMS - config.multibandLimiterAttackMS) > 0.0001
            || fabsf(multibandLimiterReleaseMS - config.multibandLimiterReleaseMS) > 0.0001
        multibandLimiterEnabled = config.multibandLimiterEnabled
        multibandLimiterThresholdDB = clampf(config.multibandLimiterThresholdDB, -20.0, 0.0)
        multibandLimiterAttackMS = clampf(config.multibandLimiterAttackMS, 0.01, 10.0)
        multibandLimiterReleaseMS = clampf(config.multibandLimiterReleaseMS, 10.0, 500.0)
        if mbLimChanged {
            configureMultibandLimiters()
        }

        // Downward expander
        let expChanged =
            downwardExpanderEnabled != config.downwardExpanderEnabled
            || fabsf(expanderThresholdDB - config.expanderThresholdDB) > 0.0001
            || fabsf(expanderRatio - config.expanderRatio) > 0.0001
            || fabsf(expanderAttackMS - config.expanderAttackMS) > 0.0001
            || fabsf(expanderReleaseMS - config.expanderReleaseMS) > 0.0001
        downwardExpanderEnabled = config.downwardExpanderEnabled
        expanderThresholdDB = clampf(config.expanderThresholdDB, -60.0, -20.0)
        expanderRatio = clampf(config.expanderRatio, 1.0, 8.0)
        expanderAttackMS = clampf(config.expanderAttackMS, 0.1, 100.0)
        expanderReleaseMS = clampf(config.expanderReleaseMS, 10.0, 2000.0)
        if expChanged {
            configureDownwardExpanders()
        }

        // Bass clipper
        let bassClipChanged =
            bassClipperEnabled != config.bassClipperEnabled
            || fabsf(bassClipperCrossoverHz - config.bassClipperCrossoverHz) > 0.0001
            || fabsf(bassClipperThresholdDB - config.bassClipperThresholdDB) > 0.0001
            || fabsf(bassClipperDrive - config.bassClipperDrive) > 0.0001
        bassClipperEnabled = config.bassClipperEnabled
        bassClipperCrossoverHz = clampf(config.bassClipperCrossoverHz, 60.0, 300.0)
        bassClipperThresholdDB = clampf(config.bassClipperThresholdDB, -12.0, 0.0)
        bassClipperDrive = clampf(config.bassClipperDrive, 0.5, 3.0)
        if bassClipChanged {
            bassClipper.configure(
                sampleRate: audioRate,
                crossoverHz: bassClipperCrossoverHz,
                thresholdDB: bassClipperThresholdDB,
                drive: bassClipperDrive
            )
        }

        // HF limiter (pre-emphasis-aware, gain-riding). The stage runs inside
        // the dual-rate audio domain: coefficients belong to the audio-domain
        // rate (init/setSampleRate already use it).
        let effectiveHFLimiterEnabled = config.hfLimiterEnabled
            && ChainFeature.hfLimiter.applies(in: operatingMode)
        let hfLimiterChanged =
            hfLimiterEnabled != effectiveHFLimiterEnabled
            || fabsf(hfLimiterThresholdDB - config.hfLimiterThresholdDB) > 0.0001
            || fabsf(hfLimiterTopThresholdDB - config.hfLimiterTopThresholdDB) > 0.0001
            || fabsf(hfLimiterAttackMS - config.hfLimiterAttackMS) > 0.0001
            || fabsf(hfLimiterReleaseMS - config.hfLimiterReleaseMS) > 0.0001
            || fabsf(hfLimiterMaxReductionDB - config.hfLimiterMaxReductionDB) > 0.0001
        hfLimiterEnabled = effectiveHFLimiterEnabled
        hfLimiterThresholdDB = clampf(config.hfLimiterThresholdDB, -12.0, 0.0)
        hfLimiterTopThresholdDB = clampf(config.hfLimiterTopThresholdDB, -12.0, 0.0)
        hfLimiterAttackMS = clampf(config.hfLimiterAttackMS, 0.2, 20.0)
        hfLimiterReleaseMS = clampf(config.hfLimiterReleaseMS, 5.0, 500.0)
        hfLimiterMaxReductionDB = clampf(config.hfLimiterMaxReductionDB, 1.0, 24.0)
        if hfLimiterChanged {
            hfLimiter.configure(
                enabled: hfLimiterEnabled,
                sampleRate: audioRate,
                thresholdDB: hfLimiterThresholdDB,
                topThresholdDB: hfLimiterTopThresholdDB,
                attackMS: hfLimiterAttackMS,
                releaseMS: hfLimiterReleaseMS,
                maxReductionDB: hfLimiterMaxReductionDB
            )
        }

        // Distortion-cancelled clipper
        let dcClipChanged =
            dcClipperEnabled != config.dcClipperEnabled
            || fabsf(dcClipperCeilingDB - config.dcClipperCeilingDB) > 0.0001
            || fabsf(dcClipperCancelFreqHz - config.dcClipperCancelFreqHz) > 0.0001
        dcClipperEnabled = config.dcClipperEnabled
        dcClipperCeilingDB = clampf(config.dcClipperCeilingDB, -6.0, 0.0)
        dcClipperCancelFreqHz = clampf(config.dcClipperCancelFreqHz, 500.0, 4000.0)
        if dcClipChanged {
            configureDistortionCancelledClipper()
        }

        // Processed-audio final loudness clipper (drive + coder-has-clipper flag).
        // The clipper config (rate/ceiling) is fixed, so only the drive pre-gain and
        // the engage flag change live — no reconfigure needed.
        processedAudioCoderHasClipper = config.processedAudioCoderHasClipper
        processedAudioFinalClipDrive =
            powf(10.0, clampf(config.processedAudioFinalClipDriveDB, 0.0, 12.0) / 20.0)
        processedAudioCeiling =
            powf(10.0, clampf(config.processedAudioCeilingDBTP, -6.0, 0.0) / 20.0)
        amNegativeCeiling = 100.0 / clampf(config.amPositivePeakPct, 100.0, 125.0)
        truePeakGuard.ceiling = digitalDelivery ? processedAudioCeiling : 1.0

        // BS.412. The ceiling is a threshold, not a topology: changing it
        // must NOT wipe the 60 s window. The old stage reallocated its ring
        // on any change, so editing the threshold erased the compliance
        // history it was supposed to be accumulating (0.65 audit, P0-6).
        bs412Enabled = config.bs412Enabled
        bs412CeilingDBr = clampf(config.bs412CeilingDBr, -10.0, 0.0)

        // Split into "structural" (FIR / bandpass / bypass / clipper-kernel
        // reset) vs "lookahead-only" so a GUI slider drag of
        // `mpx_clipper_lookahead_ms` doesn't clack every tick. Lookahead-only
        // changes go through `setLookaheadMS` which preserves filter state +
        // ducking envelopes.
        let compClipStructuralChanged =
            compositeClipperEnabled != config.compositeClipperEnabled
            || fabsf(compositeClipperThresholdDB - config.compositeClipperThresholdDB) > 0.0001
            || fabsf(compositeClipperCeilingDB - config.compositeClipperCeilingDB) > 0.0001
            || compositeClipperCancelAudio != config.compositeClipperCancelAudio
            || fabsf(compositeClipperStereoGuard - config.compositeClipperStereoGuard) > 0.0001
            || compositeClipperCancelPilot != config.compositeClipperCancelPilot
            || compositeClipperCancelRDS != config.compositeClipperCancelRDS
            || compositeClipperOversampling != config.compositeClipperOversampling
        let compClipLookaheadChanged =
            fabsf(compositeClipperLookaheadMS - config.compositeClipperLookaheadMS) > 0.0001
        compositeClipperEnabled = config.compositeClipperEnabled
        compositeClipperThresholdDB = clampf(config.compositeClipperThresholdDB, -12.0, 0.0)
        compositeClipperCeilingDB = clampf(config.compositeClipperCeilingDB, -6.0, 0.0)
        compositeClipperCancelAudio = config.compositeClipperCancelAudio
        compositeClipperStereoGuard = clampf(config.compositeClipperStereoGuard, 0.0, 1.0)
        compositeClipperCancelPilot = config.compositeClipperCancelPilot
        compositeClipperCancelRDS = config.compositeClipperCancelRDS
        compositeClipperLookaheadMS = clampf(config.compositeClipperLookaheadMS, 0.0, 5.0)
        compositeClipperOversampling = config.compositeClipperOversampling
        if compClipStructuralChanged {
            compositeClipper.configure(
                sampleRate: mpxRate,
                thresholdDB: compositeClipperThresholdDB,
                ceilingDB: compositeClipperCeilingDB,
                cancelAudio: compositeClipperCancelAudio,
                stereoGuard: compositeClipperStereoGuard,
                cancelPilot: compositeClipperCancelPilot,
                cancelRDS: compositeClipperCancelRDS,
                lookaheadMS: compositeClipperLookaheadMS,
                oversamplingFactor: compositeClipperOversampling
            )
            recomputeSubcarrierDelay()
        } else if compClipLookaheadChanged {
            compositeClipper.setLookaheadMS(
                compositeClipperLookaheadMS,
                sampleRate: mpxRate
            )
            recomputeSubcarrierDelay()
        }

        // SSB Stereo encoder (SSB-leaning stereo encoding). The Hilbert FIR
        // allocates lazily on enable (same rare-operator-action pattern
        // as the FIR reconfigures above); the SSB amount is a cheap
        // per-sample scalar applied live. No subcarrier-delay impact:
        // the base/diff alignment happens BEFORE composite assembly and
        // the 38 kHz carrier is applied at the current oscillator step,
        // so pilot / subcarrier phase coherence is untouched.
        let ssbStereoToggled = ssbStereoEnabled != config.ssbStereoEnabled
        let ssbStereoAmountChanged =
            fabsf(ssbStereoAmount - config.ssbStereoAmount) > 0.0001
        ssbStereoEnabled = config.ssbStereoEnabled
            && ChainFeature.stereoCoder.applies(in: operatingMode)
        ssbStereoAmount = clampf(config.ssbStereoAmount, 0.0, 1.0)
        if ssbStereoToggled || (ssbStereoEnabled && !ssbStereoConfigured) {
            configureSSBStereo()
        } else if ssbStereoEnabled && ssbStereoAmountChanged {
            ssbStereo.setAmount(ssbStereoAmount)
        }

        // Tone-generator parameters. Recompute `toneStep` when freq
        // changes (preserving phase across a freq update — no zero-
        // crossing artefacts on the change), `toneLevel` from dBFS.
        // Reset noise-state on type change so a Pink ↔ White switch
        // doesn't carry filter state across types.
        let newToneFreq = clampf(config.testToneFreq, 20.0, 20_000.0)
        if newToneFreq != toneFreq {
            toneFreq = newToneFreq
            toneStep = twoPi * toneFreq / mpxRate
        }
        let normalisedMode = config.testToneMode.lowercased()
        if ["mono", "stereo", "left", "right"].contains(normalisedMode) {
            toneMode = normalisedMode
        }
        let normalisedType = config.testToneType.lowercased()
        let typeChanged = normalisedType != toneType
        if ["sine", "pink", "white"].contains(normalisedType) {
            toneType = normalisedType
        }
        if typeChanged {
            // Clear pink filter state and re-prime the white-noise RNG
            // so a type switch lands cleanly without DC offset or stuck
            // pink filter values from the prior generator.
            pinkB0 = 0; pinkB1 = 0; pinkB2 = 0; pinkB3 = 0
            pinkB4 = 0; pinkB5 = 0; pinkB6 = 0
            tonePhase = 0
        }
        toneLevel = powf(10.0, clampf(config.testToneLevelDB, -60.0, 0.0) / 20.0)
        updateToneGain()
    }

    /// Sine tones are pre-compensated for the pre-emphasis magnitude at the
    /// tone frequency (the same first-order digital network `PreemphasisFilter`
    /// runs, evaluated at the audio-domain rate), so the composite peak equals
    /// the configured level at any frequency. Noise types are left as-is.
    private func updateToneGain() {
        var compensation: Float = 1.0
        if toneType == "sine", preemphasisCurve != .none {
            // The pre-emphasis filter is fitted to the analog curve, so the
            // analog magnitude is the compensation -- of WHICHEVER curve this
            // mode rides. Computing the FM magnitude on an AM feed put the
            // calibration tone out by up to 3.6 dB (0.65 audit, P0-7).
            let gainDB = preemphasisCurve.analogGainDB(frequencyHz: Double(toneFreq))
            let magnitude = Float(pow(10.0, gainDB / 20.0))
            compensation = 1.0 / max(1e-6, magnitude)
        }
        toneGain = toneLevel * compensation
    }

    func currentRDSLiveSnapshot() -> BasicRDSCoder.LiveSnapshot? {
        rdsCoder?.currentLiveSnapshot()
    }

    /// RDS exists only where a composite carries it (`ChainFeature.rds`). The
    /// gate lives HERE, on the engine's own immutable mode, and NOT in
    /// `RDSRuntimeConfig.make`: the runtime planes must stay mode-free because
    /// `ConfigPatch` derives its dispositions by diffing them, and a mode
    /// change is restart-class, not a live RDS edit.
    func applyRDSRuntimeConfig(_ config: RDSRuntimeConfig) {
        var gated = config
        if !ChainFeature.rds.applies(in: operatingMode) { gated.enabled = false }
        rdsCoder?.applyRDSRuntimeConfig(gated)
    }

    private func makeEncoderComplianceConfig() -> EncoderComplianceConfig {
        let effectiveProgramLP = effectiveProgramLowpassHz(
            configured: programLowpassHz,
            preemphasisUS: preemphasisUS,
            digital: digitalDelivery
        )
        let effectiveEncoderLP = effectiveEncoderLowpassHz(
            configured: effectiveProgramLP,
            preemphasisUS: preemphasisUS,
            digital: digitalDelivery
        )
        return EncoderComplianceConfig(
            programLowpassHz: effectiveProgramLP,
            encoderLowpassHz: effectiveEncoderLP,
            hfGuardCrossoverHz: 6_200.0
        )
    }

    private func applyEncoderComplianceConfiguration(sampleRate: Float) {
        let config = makeEncoderComplianceConfig()
        let audioRate = audioDomainSampleRate
        // Audio-domain L/R filters — programLP, encoderProgramLP,
        // encoderProgramFIR, encoderHFGuardSplit — run at the audio rate when
        // the dual-rate boundary is on. (0.45 removed the 19 kHz audio-path
        // notch: the 14.9 kHz encoder FIR's >80 dB stopband already covers
        // 19 kHz -- measured identical to 0.01 dB on the receiver gate.)
        programLP.configure(cutoffHz: config.programLowpassHz, sampleRate: audioRate)
        programLPStrided.configure(cutoffHz: config.programLowpassHz, sampleRate: audioRate,
                                   referenceRate: programLowpassReferenceRate)
        encoderProgramLP.configure(cutoffHz: config.encoderLowpassHz, sampleRate: audioRate)
        encoderProgramFIR.configure(cutoffHz: config.encoderLowpassHz, sampleRate: audioRate,
                                    transitionHz: encoderFIRTransitionHz)
        // audioCompositeBandwidthFIR sits AFTER the stereo encoder on
        // the composite signal — it must stay at the MPX rate to cover
        // 0-55 kHz including the L-R subcarrier sidebands.
        audioCompositeBandwidthFIR.configure(
            cutoffHz: 55_000.0,
            sampleRate: sampleRate,
            stopBandDB: 92.0,
            transitionHz: 5_000.0
        )
        encoderHFGuardSplit.configure(cutoffHz: config.hfGuardCrossoverHz, sampleRate: audioRate)
    }

    var isProcessingBypassEnabled: Bool {
        processingBypass
    }

    var agcStatus: AGCStatus {
        let telemetry = widebandAGC.telemetry
        // Advanced Dynamics REPLACES the AGC; report the AGC inactive (and
        // its last-run gain as neutral) so stale telemetry can never display
        // or be ingested while the leveler owns the dynamics.
        let active = widebandAGCEnabled && !advancedDynamicsEnabled && !processingBypass
        return AGCStatus(
            enabled: active,
            detectorDB: active ? telemetry.detectorDB : 0.0,
            gainDB: active ? telemetry.gainDB : 0.0,
            gateActive: active ? telemetry.gateActive : false
        )
    }

    var advancedDynamicsStatus: AdvancedDynamicsStatus {
        let active = advancedDynamicsEnabled && !processingBypass
        return AdvancedDynamicsStatus(
            enabled: active,
            bandGainsDB: active ? advancedDynamics.bandGainsDBFixed : (0, 0, 0, 0, 0),
            densityDB: active ? advancedDynamics.currentDensityDB : 0.0
        )
    }

    var finalLimiterStatus: FinalLimiterStatus {
        FinalLimiterStatus(
            enabled: (compositeClipperEnabled || preEncodeAudioLimiterEnabled) && !processingBypass,
            gainReductionDB: compositeClipperEnabled ? compositeClipper.gainReductionDB : 0.0,
            preEncodeGainReductionDB: preEncodeAudioLimiter.gainReductionDB,
            safetyGainReductionDB: (limitEnabled && !processingBypass)
                ? lookaheadLimiter.gainReductionDB : 0.0,
            safetyClipDB: safetyClipExcessDB,
            compositeLookaheadGainReductionDB: compositeClipperEnabled
                ? compositeClipper.lookaheadGainReductionDB : 0.0
        )
    }

    var compositeCalibrationStatus: CompositeCalibrationStatus {
        let calibration = Self.makeCompositeCalibration(
            audioPeakState: audioCompositePeakState,
            reservationEnv: subcarrierReservationEnv,
            outputGain: outputGain
        )
        // Re-derive overBudget from current outputGain + smoothed
        // reservation envelope. Cheap (no DSP work) and always
        // tracks the same value the render path sees in
        // `makeFinalCompositeThresholds`.
        let thresholds = Self.makeFinalCompositeThresholds(
            outputGain: outputGain,
            threshold: threshold,
            deviationScale: deviationScale,
            reserved: subcarrierReservationEnv
        )
        return CompositeCalibrationStatus(
            pilotPercent: monoMode ? 0.0 : pilotInjectionPercent,
            rdsPercent: monoMode ? 0.0 : rdsInjectionPercent,
            audioPeak: calibration.audioPeak,
            budgetMarginDB: calibration.budgetMarginDB,
            postInjectionOvershoot: postInjectionOvershootEnv,
            overBudget: thresholds.overBudget
        )
    }

    private func updateDerivedRates() {
        toneStep = twoPi * toneFreq / sampleRate
        updateToneGain()
        pilotOsc.configure(freq: pilotFreq, sampleRate: sampleRate)
        let sr = max(8_000.0, sampleRate)
        audioCompositePeakDecayCoeff = expf(-1.0 / (0.250 * sr))
        compositeBudgetGainAttackCoeff = expf(-1.0 / (0.001 * sr))
        compositeBudgetGainReleaseCoeff = expf(-1.0 / (0.120 * sr))
        compositeBudgetGain = 1.0
        // Overshoot envelope decays at ~50 ms so a single transient
        // doesn't immediately disappear from the meter.
        postInjectionOvershootDecayCoeff = expf(-1.0 / (0.050 * sr))
        // Subcarrier reservation holds (instant attack, ~2 s release): see
        // `updateSubcarrierReservation`. Over the ~12 ms between observing a
        // subcarrier sample and injecting it the hold decays by 0.6 %, which
        // the 0.02 budget margin covers many times over.
        subcarrierReservationReleaseCoeff = expf(-1.0 / (2.0 * sr))
        encoderHFGuardEnv = 0.0
        encoderHFGuardGain = 1.0
        encoderHFGuardAttackCoeff = expf(-1.0 / (0.004 * sr))
        encoderHFGuardReleaseCoeff = expf(-1.0 / (0.080 * sr))
        // Which subcarriers this render rate can carry without aliasing
        // (`compositeRateSupport`). The pilot announces stereo, so it goes
        // with the stereo subcarrier.
        let support = Self.compositeRateSupport(sampleRate: Double(sampleRate))
        pilotSupported = support.stereo
        stereoSubcarrierSupported = support.stereo
        rdsSupported = support.rds
        // The BS.412 guard's reserve reads these flags. Its `configure` runs
        // earlier in both init and setSampleRate, when they are still false,
        // so a fresh generator reserved NOTHING until the first live apply
        // (found 2026-09-12 by the generator-level wiring test). Refresh it
        // here, where the flags become true; O(1), keeps history.
        bs412Guard.setSubcarrierReserve(bs412SubcarrierReserve)

        updateMonitorRecoveryRates()
        updatePrimeBassDynamicRates()
    }

    private func updateMonitorRecoveryRates() {
        let sr = max(8_000.0, sampleRate)
        monitorExpectedSideAttackCoeff = expf(-1.0 / (0.010 * sr))
        monitorExpectedSideReleaseCoeff = expf(-1.0 / (0.260 * sr))
    }

    private func updatePrimeBassDynamicRates() {
        // Audio-domain stage.
        let sr = max(8_000.0, audioDomainSampleRate)
        func coeff(_ milliseconds: Float) -> Float {
            expf(-1.0 / ((milliseconds * 0.001) * sr))
        }
        // Level normaliser on |band|: 1 ms attack so the envelope sits on
        // the band's peaks within a quarter cycle (a slower attack lets
        // band / env overshoot on every onset and the squarer turns the
        // overshoot into a thump), 150 ms release so the 6.5 % droop
        // between the peaks of a 50 Hz tone is the only ripple.
        primeBassLevelAttackCoeff = coeff(1.0)
        primeBassLevelReleaseCoeff = coeff(150.0)
        // Peak guard: peak-hold followers (100 ms release) on the dry mid
        // and on the candidate output; the harmonic gain they drive moves
        // at 5 ms / 100 ms.
        primeBassPeakReleaseCoeff = coeff(100.0)
        primeBassGuardAttackCoeff = coeff(5.0)
        primeBassGuardReleaseCoeff = coeff(100.0)
        // Werrbach dual-envelope transient detector. Fast envelope
        // follows the band quickly so its level reflects the *current*
        // attack; slow envelope tracks the recent baseline. Their
        // (fast - slow) / slow difference saturates positive on onsets
        // and decays to zero as the slow follower catches up, ~50-150 ms
        // post-attack. The asymmetric attack/release on each follower
        // keeps the response sharp at the leading edge without letting
        // it dip on cycle-by-cycle valleys of a sustained tone.
        primeBassFastAttackCoeff = coeff(5.0)
        primeBassFastReleaseCoeff = coeff(30.0)
        primeBassSlowAttackCoeff = coeff(50.0)
        primeBassSlowReleaseCoeff = coeff(250.0)
    }

    private func configureStereoImage() {
        // Audio-domain stage — runs at the audio rate when the dual-rate
        // boundary is on, otherwise at the engine's MPX rate.
        let sampleRate = audioDomainSampleRate
        let sr = max(8_000.0, sampleRate)
        monoBassFilter.configure(cutoffHz: monoBassFreqHz, sampleRate: sr)
        stereoProtectInputMidEnv = 0.0
        stereoProtectInputSideEnv = 0.0
        stereoProtectMidEnv = 0.0
        stereoProtectSideEnv = 0.0
        stereoProtectGain = 1.0
        truePeakGuard.reset()
        stereoProtectAttackCoeff = expf(-1.0 / (0.010 * sr))
        stereoProtectReleaseCoeff = expf(-1.0 / (0.300 * sr))
    }

    private func configureMonitorDemod() {
        monitorDecoder.configure(sampleRate: sampleRate, preemphasisUS: preemphasisUS)
        lastSubcarrierSample = 0.0
        lastProgramActivity = 0.0
    }

    private func demodulateMonitorFromMPXSample(_ mpx: Float) -> (Float, Float) {
        monitorDecoder.process(
            mpx,
            referenceSubcarrier: lastSubcarrierSample,
            programActivity: lastProgramActivity,
            expectedSide: monitorExpectedSideEnv
        )
    }

    private func configurePrimeBassFilters() {
        // Audio-domain stage.
        let sampleRate = audioDomainSampleRate
        let nyquist = max(200.0, (sampleRate * 0.5) - 200.0)
        let f0 = clampf(primeBassFreqHz, 45.0, nyquist)
        // Input band: the fundamentals below F0 and nothing above. LR4
        // (24 dB/oct) on both edges, so at the default F0 a 1 kHz vocal
        // reaches the nonlinearity about 80 dB down and cannot
        // intermodulate with the bass (review finding 2: the one-pole
        // lowpass passed it at -20 dB).
        primeBassInHPF.configureHighpass(cutoffHz: max(25.0, f0 * 0.35), sampleRate: sampleRate)
        primeBassInLPF.configureLowpass(cutoffHz: f0, sampleRate: sampleRate)
        // Output band F0 .. 5 F0: the highpass removes the fundamental
        // residue and the DC of x^2, the lowpass keeps the series where
        // the ear reconstructs the pitch and out of the midrange.
        let outHigh = clampf(f0 * 5.0, f0 + 20.0, nyquist)
        primeBassOutHPF.configureHighpass(cutoffHz: f0, sampleRate: sampleRate)
        primeBassOutLPF.configureLowpass(cutoffHz: outHigh, sampleRate: sampleRate)
        // Subharmonic band: the octave divider's square wave keeps only
        // its own fundamental (at or below 0.5 F0); the square's 3rd at
        // 1.5 F0 is 27 dB down.
        primeBassSubLPF.configureLowpass(cutoffHz: max(25.0, f0 * 0.7), sampleRate: sampleRate)
        primeBassDCBlock.configure(cutoffHz: 8.0, sampleRate: sampleRate)
        configurePrimeBassOddDevice()
    }

    /// tanh device coefficients. For a unit sine x = sin t, tanh(d x) is an
    /// odd Fourier series b1 sin t + b3 sin 3t + b5 sin 5t + ...; the per-
    /// sample device is (tanh(d x) - b1 x) / b3, so a unit sine yields a
    /// unit 3rd harmonic plus the higher odd orders and no fundamental
    /// (review finding 6: the previous tanh difference kept a 1.6x linear
    /// term that the output filter then subtracted from the direct path).
    /// 256-point rectangle rule over one period; the integrand is smooth
    /// and periodic, so the sum is exact to Float precision for orders
    /// well below 256. Configure-time only (also re-run when `drive`
    /// changes live).
    private func configurePrimeBassOddDevice() {
        // drive 0..2.5 -> d 0.8..3.8: soft cubic (3rd dominant) to a hard
        // clip (5th and 7th rise).
        let d = 0.8 + (1.2 * clampf(primeBassDrive, 0.0, 2.5))
        primeBassOddDrive = d
        let points = 256
        var b1: Float = 0.0
        var b3: Float = 0.0
        for k in 0..<points {
            let t = twoPi * (Float(k) + 0.5) / Float(points)
            let y = tanhf(d * sinf(t))
            b1 += y * sinf(t)
            b3 += y * sinf(3.0 * t)
        }
        b1 *= 2.0 / Float(points)
        b3 *= 2.0 / Float(points)
        primeBassOddFundamental = b1
        // b3 is negative (compression flattens the peaks); keep the sign so
        // the 3rd harmonic has a defined polarity, guard the magnitude.
        primeBassOddThirdInv = fabsf(b3) > 1e-6 ? 1.0 / b3 : 0.0
    }

    /// The crossovers the splitters actually use: the configured values
    /// clamped to an ascending, Nyquist-safe set at the audio-domain rate.
    /// The 3-band layout uses x1 / x2.
    private var resolvedMultibandCrossovers: (x1: Float, x2: Float, x3: Float, x4: Float) {
        let sampleRate = audioDomainSampleRate
        let x1 = clampf(multibandX1Hz, 40.0, max(60.0, (sampleRate * 0.5) - 300.0))
        let x2 = clampf(multibandX2Hz, x1 + 40.0, max(x1 + 60.0, (sampleRate * 0.5) - 200.0))
        let x3 = clampf(multibandX3Hz, x2 + 80.0, max(x2 + 100.0, (sampleRate * 0.5) - 120.0))
        let x4 = clampf(multibandX4Hz, x3 + 120.0, max(x3 + 140.0, (sampleRate * 0.5) - 60.0))
        return (x1, x2, x3, x4)
    }

    private func configureMultibandFilters() {
        // Audio-domain stage.
        let sampleRate = audioDomainSampleRate
        let (x1, x2, x3, x4) = resolvedMultibandCrossovers

        mb3IIRSplitter.configure(x1Hz: x1, x2Hz: x2, sampleRate: sampleRate)
        mb5IIRSplitter.configure(x1Hz: x1, x2Hz: x2, x3Hz: x3, x4Hz: x4, sampleRate: sampleRate)

        // Linear-phase FIR splitters (TX mode). The splitter owns the
        // crossover design (per-crossover transition = fc, floor 120 Hz,
        // 40 dB stopband, kernels padded to a shared length); with the
        // default 90 Hz lowest crossover that is ~893 taps at 48 kHz =
        // 446 samples = 9.3 ms of audio-domain latency (was 2049 taps /
        // 21.3 ms before 0.45).
        if useMultibandFIR {
            mb3FIRSplitter.configure(lowHz: x1, highHz: x2, sampleRate: sampleRate)
            mb5FIRSplitter.configure(x1Hz: x1, x2Hz: x2, x3Hz: x3, x4Hz: x4, sampleRate: sampleRate)
        }
        // The band limiters' peak hold spans one period of each band's lower
        // crossover, so a crossover edit re-designs them too.
        configureMultibandLimiters()
    }

    /// Advanced Dynamics structure setup. Lazy: a disabled stage never
    /// allocates its FIR splitter (default-off must cost nothing). Uses the
    /// same crossover clamps as configureMultibandFilters so the leveler's
    /// bands match the multiband compressor's layout exactly.
    private func configureAdvancedDynamics() {
        guard advancedDynamicsEnabled else {
            advancedDynamicsStructureConfigured = false
            return
        }
        let sampleRate = audioDomainSampleRate
        let x1 = clampf(multibandX1Hz, 40.0, max(60.0, (sampleRate * 0.5) - 300.0))
        let x2 = clampf(multibandX2Hz, x1 + 40.0, max(x1 + 60.0, (sampleRate * 0.5) - 200.0))
        let x3 = clampf(multibandX3Hz, x2 + 80.0, max(x2 + 100.0, (sampleRate * 0.5) - 120.0))
        let x4 = clampf(multibandX4Hz, x3 + 120.0, max(x3 + 140.0, (sampleRate * 0.5) - 60.0))
        advancedDynamics.configureStructure(
            sampleRate: sampleRate, x1Hz: x1, x2Hz: x2, x3Hz: x3, x4Hz: x4)
        advancedDynamics.setDetectorPreemphasis(tauUS: preemphasisUS)
        applyAdvancedDynamicsParameters()
        advancedDynamicsStructureConfigured = true
    }

    private func applyAdvancedDynamicsParameters() {
        advancedDynamics.setParameters(
            targetDB: advancedDynamicsTargetDB,
            lowOffsetDB: advancedDynamicsLowOffsetDB,
            midOffsetDB: advancedDynamicsMidOffsetDB,
            highOffsetDB: advancedDynamicsHighOffsetDB,
            maxGainDB: advancedDynamicsMaxGainDB,
            density: advancedDynamicsDensity,
            speed: advancedDynamicsSpeed
        )
    }

    /// SSB Stereo structure setup. Lazy: a disabled stage never allocates
    /// its Hilbert FIR. Runs at the MPX (composite) rate -- the stage sits
    /// in composite assembly, not the audio domain.
    private func configureSSBStereo() {
        guard ssbStereoEnabled else {
            ssbStereoConfigured = false
            return
        }
        ssbStereo.configure(sampleRate: sampleRate)
        ssbStereo.setAmount(ssbStereoAmount)
        ssbStereoConfigured = true
    }

    private func configureMultibandCompressors() {
        // Audio-domain stage — coupling time constants tied to audio
        // rate so they scale correctly with the dual-rate boundary.
        let sampleRate = audioDomainSampleRate
        multibandCouplingAttackCoeff = expf(-1.0 / (max(1.0, sampleRate) * 0.020))
        multibandCouplingReleaseCoeff = expf(-1.0 / (max(1.0, sampleRate) * 0.300))
        multibandCouplingGRDB = 0.0

        configureCompressorPair(
            left: &mbLowCompL,
            right: &mbLowCompR,
            thresholdDB: multibandLowThresholdDB,
            ratio: multibandLowRatio,
            attackMS: multibandLowAttackMS,
            releaseMS: multibandLowReleaseMS,
            transientAwareAttackEnabled: multibandTransientAwareAttackEnabled
        )
        configureCompressorPair(
            left: &mbMidCompL,
            right: &mbMidCompR,
            thresholdDB: multibandMidThresholdDB,
            ratio: multibandMidRatio,
            attackMS: multibandMidAttackMS,
            releaseMS: multibandMidReleaseMS,
            transientAwareAttackEnabled: multibandTransientAwareAttackEnabled
        )
        configureCompressorPair(
            left: &mbHighCompL,
            right: &mbHighCompR,
            thresholdDB: multibandHighThresholdDB,
            ratio: multibandHighRatio,
            attackMS: multibandHighAttackMS,
            releaseMS: multibandHighReleaseMS,
            transientAwareAttackEnabled: multibandTransientAwareAttackEnabled
        )

        let t2 = lerpf(multibandLowThresholdDB, multibandMidThresholdDB, 0.5)
        let t4 = lerpf(multibandMidThresholdDB, multibandHighThresholdDB, 0.5)
        let r2 = lerpf(multibandLowRatio, multibandMidRatio, 0.5)
        let r4 = lerpf(multibandMidRatio, multibandHighRatio, 0.5)
        let a2 = lerpf(multibandLowAttackMS, multibandMidAttackMS, 0.5)
        let a4 = lerpf(multibandMidAttackMS, multibandHighAttackMS, 0.5)
        let rel2 = lerpf(multibandLowReleaseMS, multibandMidReleaseMS, 0.5)
        let rel4 = lerpf(multibandMidReleaseMS, multibandHighReleaseMS, 0.5)

        configureCompressorPair(
            left: &mb5Comp1L,
            right: &mb5Comp1R,
            thresholdDB: multibandLowThresholdDB,
            ratio: multibandLowRatio,
            attackMS: multibandLowAttackMS,
            releaseMS: multibandLowReleaseMS,
            transientAwareAttackEnabled: multibandTransientAwareAttackEnabled
        )
        configureCompressorPair(
            left: &mb5Comp2L,
            right: &mb5Comp2R,
            thresholdDB: t2,
            ratio: r2,
            attackMS: a2,
            releaseMS: rel2,
            transientAwareAttackEnabled: multibandTransientAwareAttackEnabled
        )
        configureCompressorPair(
            left: &mb5Comp3L,
            right: &mb5Comp3R,
            thresholdDB: multibandMidThresholdDB,
            ratio: multibandMidRatio,
            attackMS: multibandMidAttackMS,
            releaseMS: multibandMidReleaseMS,
            transientAwareAttackEnabled: multibandTransientAwareAttackEnabled
        )
        configureCompressorPair(
            left: &mb5Comp4L,
            right: &mb5Comp4R,
            thresholdDB: t4,
            ratio: r4,
            attackMS: a4,
            releaseMS: rel4,
            transientAwareAttackEnabled: multibandTransientAwareAttackEnabled
        )
        configureCompressorPair(
            left: &mb5Comp5L,
            right: &mb5Comp5R,
            thresholdDB: multibandHighThresholdDB,
            ratio: multibandHighRatio,
            attackMS: multibandHighAttackMS,
            releaseMS: multibandHighReleaseMS,
            transientAwareAttackEnabled: multibandTransientAwareAttackEnabled
        )
    }

    static func multibandCouplingBiases(lowGainReductionDB: Float) -> (mid: Float, high: Float) {
        let lowGR = clampf(lowGainReductionDB, 0.0, 24.0)
        return (-0.15 * lowGR, -0.25 * lowGR)
    }

    static func multibandFiveBandCouplingBiases(lowGainReductionDB: Float) -> (
        b2: Float,
        b3: Float,
        b4: Float,
        b5: Float
    ) {
        let lowGR = clampf(lowGainReductionDB, 0.0, 24.0)
        return (-0.10 * lowGR, -0.15 * lowGR, -0.22 * lowGR, -0.25 * lowGR)
    }

    private func updateMultibandCouplingGainReduction(_ lowGainReductionDB: Float) -> Float {
        guard multibandInterBandCouplingEnabled else {
            multibandCouplingGRDB = 0.0
            return 0.0
        }
        let target = clampf(lowGainReductionDB, 0.0, 24.0)
        let coeff = target > multibandCouplingGRDB
            ? multibandCouplingAttackCoeff
            : multibandCouplingReleaseCoeff
        multibandCouplingGRDB = (coeff * multibandCouplingGRDB) + ((1.0 - coeff) * target)
        multibandCouplingGRDB = zapDenorm(multibandCouplingGRDB)
        return multibandCouplingGRDB
    }

    private func configureCompressorPair(
        left: inout MonoCompressor,
        right: inout MonoCompressor,
        thresholdDB: Float,
        ratio: Float,
        attackMS: Float,
        releaseMS: Float,
        transientAwareAttackEnabled: Bool
    ) {
        // Audio-domain stage.
        let sampleRate = audioDomainSampleRate
        left.configure(
            sampleRate: sampleRate,
            thresholdDB: thresholdDB,
            ratio: ratio,
            attackMS: attackMS,
            releaseMS: releaseMS,
            makeupDB: 0.0,
            kneeDB: multibandKneeDB,
            transientAwareAttackEnabled: transientAwareAttackEnabled,
            programDependentRelease: multibandReleaseProgramDependent
        )
        right.configure(
            sampleRate: sampleRate,
            thresholdDB: thresholdDB,
            ratio: ratio,
            attackMS: attackMS,
            releaseMS: releaseMS,
            makeupDB: 0.0,
            kneeDB: multibandKneeDB,
            transientAwareAttackEnabled: transientAwareAttackEnabled,
            programDependentRelease: multibandReleaseProgramDependent
        )
    }

    private func configureParametricEQ() {
        // Audio-domain stage.
        let sampleRate = audioDomainSampleRate
        parametricEQ.configure(
            sampleRate: sampleRate,
            b1FreqHz: peqB1FreqHz, b1GainDB: peqB1GainDB,
            b2FreqHz: peqB2FreqHz, b2GainDB: peqB2GainDB, b2Q: peqB2Q,
            b3FreqHz: peqB3FreqHz, b3GainDB: peqB3GainDB, b3Q: peqB3Q,
            b4FreqHz: peqB4FreqHz, b4GainDB: peqB4GainDB
        )
    }

    private func configureMultibandLimiters() {
        // Audio-domain stage.
        let sampleRate = audioDomainSampleRate
        let thr = multibandLimiterThresholdDB
        let atk = multibandLimiterAttackMS
        let rel = multibandLimiterReleaseMS
        // Each limiter's peak hold spans one period of its band's LOWER
        // edge (the resolved crossover below it; the bottom band keeps the
        // 50 Hz default). Without it every band held for 20 ms, so the upper
        // bands released at least 40 ms later than configured.
        let (x1, x2, x3, x4) = resolvedMultibandCrossovers
        let bottom = BandLimiter.defaultLowestFrequencyHz
        func configure(_ limiter: inout BandLimiter, _ lowestHz: Float) {
            limiter.configure(sampleRate: sampleRate, thresholdDB: thr, attackMS: atk, releaseMS: rel,
                              lowestFrequencyHz: lowestHz)
        }
        configure(&mbLimLow, bottom)
        configure(&mbLimMid, x1)
        configure(&mbLimHigh, x2)
        configure(&mbLim5B1, bottom)
        configure(&mbLim5B2, x1)
        configure(&mbLim5B3, x2)
        configure(&mbLim5B4, x3)
        configure(&mbLim5B5, x4)
    }

    /// Each classic band limiter's peak-hold length in samples, by band
    /// (3-band layout, then 5-band). Test hook.
    var multibandLimiterHoldSamples: (three: [Int], five: [Int]) {
        ([mbLimLow.holdSamples, mbLimMid.holdSamples, mbLimHigh.holdSamples],
         [mbLim5B1.holdSamples, mbLim5B2.holdSamples, mbLim5B3.holdSamples,
          mbLim5B4.holdSamples, mbLim5B5.holdSamples])
    }

    private func configureDownwardExpanders() {
        // Audio-domain stage.
        let sampleRate = audioDomainSampleRate
        let thr = expanderThresholdDB
        let rat = expanderRatio
        let atk = expanderAttackMS
        let rel = expanderReleaseMS
        mbExpLow.configure(sampleRate: sampleRate, thresholdDB: thr, ratio: rat, attackMS: atk, releaseMS: rel)
        mbExpMid.configure(sampleRate: sampleRate, thresholdDB: thr, ratio: rat, attackMS: atk, releaseMS: rel)
        mbExpHigh.configure(sampleRate: sampleRate, thresholdDB: thr, ratio: rat, attackMS: atk, releaseMS: rel)
        mbExp5B1.configure(sampleRate: sampleRate, thresholdDB: thr, ratio: rat, attackMS: atk, releaseMS: rel)
        mbExp5B2.configure(sampleRate: sampleRate, thresholdDB: thr, ratio: rat, attackMS: atk, releaseMS: rel)
        mbExp5B3.configure(sampleRate: sampleRate, thresholdDB: thr, ratio: rat, attackMS: atk, releaseMS: rel)
        mbExp5B4.configure(sampleRate: sampleRate, thresholdDB: thr, ratio: rat, attackMS: atk, releaseMS: rel)
        mbExp5B5.configure(sampleRate: sampleRate, thresholdDB: thr, ratio: rat, attackMS: atk, releaseMS: rel)
    }

    private func configureDistortionCancelledClipper() {
        // Audio-domain stage.
        let sampleRate = audioDomainSampleRate
        dcClipper.configure(
            sampleRate: sampleRate,
            ceilingDB: dcClipperCeilingDB,
            cancelFreqHz: dcClipperCancelFreqHz
        )
    }

    private func configureProcessedAudioFinalClipper() {
        // Processed-audio final loudness clipper. Fixed near-0 dBFS ceiling; the
        // drive pre-gain (applied in the audio-only render loop) sets the density.
        processedAudioFinalClipper.configure(
            sampleRate: audioDomainSampleRate,
            ceilingDB: Self.processedAudioFinalClipCeilingDB,
            cancelFreqHz: 2000.0
        )
    }

    /// Generate one tone-source sample. Switches between sine /
    /// pink / white based on `toneType`. Sine advances `tonePhase` by
    /// `toneStep` and wraps; noise paths use the engine's xorshift RNG
    /// + Paul Kellet's pink IIR. Output is unscaled; callers multiply
    /// by `toneLevel` for the final output amplitude.
    @inline(__always)
    private func nextToneRawSample() -> Float {
        switch toneType {
        case "white":
            return nextWhiteSample()
        case "pink":
            return nextPinkSample()
        default:
            let s = sinf(tonePhase)
            tonePhase += toneStep
            if tonePhase >= twoPi { tonePhase -= twoPi }
            return s
        }
    }

    /// xorshift64* white noise → uniform [-1, +1]. Single scalar
    /// state mutation per sample; cheap.
    @inline(__always)
    private func nextWhiteSample() -> Float {
        var x = toneNoiseRNG
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        toneNoiseRNG = x
        let mixed = x &* 0x2545_F491_4F6C_DD1D
        // Top 24 bits → float in [0, 1) → [-1, +1)
        let u = Float(mixed >> 40) / Float(1 << 24)
        return (u * 2.0) - 1.0
    }

    /// Paul Kellet's 4-pole pink-noise IIR (the well-known short
    /// recipe). Produces ~3 dB/octave rolloff from white noise. Cycle
    /// artefacts above ~10 kHz are acceptable for a test-tone source
    /// — operators use pink for broadband response checks, not for
    /// deterministic measurement.
    @inline(__always)
    private func nextPinkSample() -> Float {
        let white = nextWhiteSample()
        pinkB0 = 0.99886 * pinkB0 + white * 0.0555179
        pinkB1 = 0.99332 * pinkB1 + white * 0.0750759
        pinkB2 = 0.96900 * pinkB2 + white * 0.1538520
        pinkB3 = 0.86650 * pinkB3 + white * 0.3104856
        pinkB4 = 0.55000 * pinkB4 + white * 0.5329522
        pinkB5 = -0.7616 * pinkB5 - white * 0.0168980
        let pink = pinkB0 + pinkB1 + pinkB2 + pinkB3 + pinkB4 + pinkB5 + pinkB6 + white * 0.5362
        pinkB6 = white * 0.115926
        // The recipe yields peaks around ±3.5; scale to roughly ±1
        // so `toneLevel` interpretation matches the sine path.
        return pink * 0.11
    }

    private static func resolveMultibandCrossovers(
        sampleRate: Float,
        x1: Float,
        x2: Float,
        x3: Float,
        x4: Float
    ) -> (x1: Float, x2: Float, x3: Float, x4: Float) {
        let nyquistLimit = max(600.0, (sampleRate * 0.5) - 100.0)
        let c1 = clampf(x1, 40.0, nyquistLimit - 400.0)
        var c2 = clampf(x2, c1 + 40.0, nyquistLimit - 300.0)
        var c3 = clampf(x3, c2 + 80.0, nyquistLimit - 200.0)
        var c4 = clampf(x4, c3 + 120.0, nyquistLimit - 100.0)
        if c2 <= c1 + 30.0 {
            c2 = c1 + 40.0
        }
        if c3 <= c2 + 60.0 {
            c3 = c2 + 80.0
        }
        if c4 <= c3 + 100.0 {
            c4 = c3 + 120.0
        }
        return (c1, c2, c3, c4)
    }

    func renderNonInterleaved(
        frameCount: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        analysis: AnalysisBuffers = .none
    ) {
        renderNonInterleaved(
            frameCount: frameCount, left: left, right: right, analysis: analysis,
            monitorLeft: nil, monitorRight: nil)
    }

    /// Tone counterpart of the monitor-aware composite render (see above).
    func renderNonInterleaved(
        frameCount: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        analysis: AnalysisBuffers,
        monitorLeft: UnsafeMutablePointer<Float>?,
        monitorRight: UnsafeMutablePointer<Float>?
    ) {
        guard frameCount > 0 else { return }
        for i in 0..<frameCount {
            // Tone source: sine / pink / white via `nextToneRawSample`,
            // scaled by `toneLevel` (linear; default ≈ 0.1 = −20 dBFS).
            // Pre-fix: this path used `sinf(tonePhase)` without
            // advancing the phase, generating DC silence.
            let raw = nextToneRawSample()
            let tone = raw * toneGain
            renderingCalibrationTone = true
            var l: Float
            var r: Float
            switch toneMode {
            case "left":
                l = tone
                r = 0.0
            case "right":
                l = 0.0
                r = tone
            case "stereo":
                l = tone
                r = -tone
            default:
                l = tone
                r = tone
            }
            let detail = processSampleDetailed(leftIn: l, rightIn: r)
            writeAnalysisSample(index: i, stereo: detail.analysisStereo, analysis: analysis)
            let mpx = detail.mpx
            left[i] = mpx
            right[i] = mpx
            if let monL = monitorLeft, let monR = monitorRight {
                let demod = demodulateMonitorFromMPXSample(mpx)
                monL[i] = demod.0
                monR[i] = demod.1
            }
        }
    }

    @inline(__always)
    func renderSingleSample(leftIn: Float, rightIn: Float) -> Float {
        processSample(leftIn: leftIn, rightIn: rightIn)
    }

    func renderFromInputInPlace(
        frameCount: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        analysis: AnalysisBuffers = .none
    ) {
        renderFromInputInPlace(
            frameCount: frameCount, left: left, right: right, analysis: analysis,
            monitorLeft: nil, monitorRight: nil)
    }

    /// Composite render that can ALSO hand back the decoded monitor audio.
    ///
    /// The transmitter feed is the composite, exactly as the four-argument
    /// form produces it; when `monitorLeft`/`monitorRight` are non-nil the
    /// same pass additionally demodulates each composite sample the way a
    /// receiver would, so the operator can listen on a second device while
    /// on air. The decode only reads the encoder's delay-aligned subcarrier
    /// reference and its own decoder state -- it cannot move the composite,
    /// which is what keeps the strict baselines valid.
    ///
    /// The two loops are selected ONCE per block rather than testing the
    /// optionals per sample.
    func renderFromInputInPlace(
        frameCount: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        analysis: AnalysisBuffers,
        monitorLeft: UnsafeMutablePointer<Float>?,
        monitorRight: UnsafeMutablePointer<Float>?
    ) {
        guard frameCount > 0 else { return }
        guard let monL = monitorLeft, let monR = monitorRight else {
            for i in 0..<frameCount {
                let detail = processSampleDetailed(leftIn: left[i], rightIn: right[i])
                writeAnalysisSample(index: i, stereo: detail.analysisStereo, analysis: analysis)
                let mpx = detail.mpx
                left[i] = mpx
                right[i] = mpx
            }
            return
        }
        for i in 0..<frameCount {
            let detail = processSampleDetailed(leftIn: left[i], rightIn: right[i])
            writeAnalysisSample(index: i, stereo: detail.analysisStereo, analysis: analysis)
            let mpx = detail.mpx
            let demod = demodulateMonitorFromMPXSample(mpx)
            left[i] = mpx
            right[i] = mpx
            monL[i] = demod.0
            monR[i] = demod.1
        }
    }

    /// True when the optional processed-audio final loudness clipper should run:
    /// only in processed-audio output, and only when the external coder has no
    /// clipper of its own (otherwise we would double-clip).
    @inline(__always)
    private var processedAudioFinalClipActive: Bool {
        audioOutputOnly && !processedAudioCoderHasClipper && !digitalDelivery && !amDelivery
    }

    /// Drive the L/R into the final loudness clipper (drive pre-gain sets density;
    /// the clipper caps peaks at its fixed ceiling).
    @inline(__always)
    private func processedAudioFinalClip(_ l: Float, _ r: Float) -> (Float, Float) {
        processedAudioFinalClipper.process(
            left: l * processedAudioFinalClipDrive,
            right: r * processedAudioFinalClipDrive)
    }

    /// Output makeup for processed-audio mode. The composite path applies output
    /// gain / final drive / deviation scaling downstream of the pre-encode limiter
    /// (in the MPX domain, skipped here), so without compensation the audio-only
    /// output sits at the limiter ceiling (~-1.4 dBFS) and reads quiet. Normalize
    /// so the binding ceiling maps to full scale (peaks reach ~0 dBFS), then apply
    /// the operator output gain. The clamp in the render loop catches any overs.
    /// Passband for the pre-encode limiter's 4:1 decimator, which doubles as
    /// the chain's band-limit in the pre-emphasised domain. 15 kHz is the FM
    /// band plan and stays the default; digital delivery hands it the program
    /// bandwidth instead, or that 15 kHz limit silently survives the target
    /// switch -- it did, and the 18 kHz probe in `ProcessedAudioOutputTests`
    /// is what caught it.
    private var preEncodeLimiterPassbandHz: Float {
        guard digitalDelivery else { return 15_000.0 }
        return min(20_000.0, max(10_000.0, programLowpassHz))
    }

    /// The digital make-up aims a hair under the requested ceiling and the
    /// true-peak guard holds the rest. With the guard in place the margin only
    /// covers the difference between its 4x Kaiser reconstruction and a real
    /// D/A or codec reconstruction; before the guard existed it had to cover
    /// the pre-encode limiter's decimation ringing as well (0.33 dB on a burst
    /// program, +1.4 dB on clicks -- not a margin's job).
    private static let processedAudioTruePeakMarginDB: Float = 0.1

    /// The output peak guard: a true-peak ceiling for HD Output, and the
    /// asymmetric positive/negative pair for AM Output. Both are gain rides on
    /// the same reconstruction detector -- neither clips.
    private func configureTruePeakGuard(sampleRate: Float) {
        if amDelivery {
            truePeakGuard.configure(sampleRate: sampleRate, ceilingLinear: 1.0,
                                    ceilingNegativeLinear: amNegativeCeiling,
                                    lookaheadMS: 2.0, enabled: true)
        } else {
            // HD: the configured dBTP ceiling. FM processed audio: full scale.
            // The FM feed used to have nothing between the make-up and the
            // render clamp, so the limiter's decimation ringing (and the final
            // loudness clipper's) was hard-clipped at 1x there (F5). The guard
            // is a gain ride, so it holds full scale without clipping. It runs
            // only in the audio-only render paths.
            truePeakGuard.configure(sampleRate: sampleRate,
                                    ceilingLinear: digitalDelivery ? processedAudioCeiling : 1.0,
                                    lookaheadMS: 2.0, enabled: true)
        }
    }

    /// Test-visible duty of the digital true-peak guard (dB of gain ride).
    var truePeakGuardGainReductionDB: Float { truePeakGuard.gainReductionDB }

    /// The HF limiter's boost gain on the last audio-domain sample (linear,
    /// 1 = full pre-emphasis); `--verify-hf-transients` reads its trajectory.
    var hfLimiterGain: Float { hfLimiter.gain }

    @inline(__always)
    private func audioOnlyOutputMakeup() -> Float {
        if amDelivery {
            // Normalise the limiter's ceiling onto FULL SCALE -- the positive
            // bound -- and let the guard hold the negative side at
            // 100/pct. Normalising onto the negative bound instead would cap
            // both halves there and the asymmetry could never be used: the
            // pre-encode limiter bounds |x| symmetrically, so positive peaks
            // have to be allowed above the negative ceiling to exist at all.
            // Symmetric program still lands symmetric (the guard rides both
            // halves down together); only positive-heavy program -- speech,
            // most single-instrument material -- uses the extra room.
            guard preEncodeAudioLimiterEnabled else { return outputGain }
            let limiterCeiling = oversampledLimiterCeiling(threshold: preEncodeThreshold)
            return outputGain / max(0.1, limiterCeiling)
        }
        if digitalDelivery {
            // Map the true-peak limiter's threshold onto the configured dBTP
            // ceiling instead of onto full scale: a codec wants headroom, not
            // a normalised feed. With the limiter off there is nothing holding
            // peaks, so the operator's gain stands and the render clamp is the
            // only guard.
            guard preEncodeAudioLimiterEnabled else { return outputGain }
            let limiterCeiling = oversampledLimiterCeiling(threshold: preEncodeThreshold)
            let margin = powf(10.0, -Self.processedAudioTruePeakMarginDB / 20.0)
            return outputGain * ((processedAudioCeiling * margin) / max(0.1, limiterCeiling))
        }
        if processedAudioFinalClipActive {
            // Peaks are capped by the final clipper; normalize its ceiling to
            // full scale. Its decimation filter can still ring a little over
            // it; the output guard (a gain ride) takes that, never the clamp.
            let ceilLin = powf(10.0, Self.processedAudioFinalClipCeilingDB / 20.0)
            return outputGain / max(0.1, ceilLin)
        }
        // FM: map the limiter's CEILING -- the bound it really imposes, knee
        // included -- onto full scale, as HD and AM do. Until 2026-10 this
        // mapped the THRESHOLD (`1 / preEncodeThreshold`), so the knee and
        // the decimator's ringing landed up to +1.07 dBFS and the render clamp
        // hard-clipped 0.78 % of the samples of dense programme 6 dB over
        // threshold (peak-control review F5).
        guard preEncodeAudioLimiterEnabled else { return outputGain }
        return outputGain / max(0.1, oversampledLimiterCeiling(threshold: preEncodeThreshold))
    }

    /// Processed-audio output: emit the post-pre-encode-limiter L/R (the exact
    /// signal captured as `preMPX*` for metering) and SKIP all composite-domain
    /// work (stereo encode, composite clipper, BS.412, pilot/RDS injection). Used
    /// when feeding an external stereo coder. Runs the full audio-domain chain via
    /// `processAudioDomain`, bypassing the dual-rate boundary entirely.
    func renderAudioOnlyFromInputInPlace(
        frameCount: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        analysis: AnalysisBuffers = .none
    ) {
        guard frameCount > 0 else { return }
        let makeup = audioOnlyOutputMakeup()
        let finalClip = processedAudioFinalClipActive
        let mono = amDelivery
        for i in 0..<frameCount {
            // AM is a mono service: sum FIRST so every stage downstream levels,
            // compresses and limits the signal that actually goes on air.
            let inL = mono ? (left[i] + right[i]) * 0.5 : left[i]
            let inR = mono ? inL : right[i]
            let audio = processAudioDomain(leftIn: inL, rightIn: inR)
            var l = audio.left
            var r = audio.right
            if finalClip {
                let c = processedAudioFinalClip(l, r)
                l = c.0
                r = c.1
            }
            var madeUpL = l * makeup
            var madeUpR = r * makeup
            // Every audio-only target runs the output guard: HD (true-peak
            // ceiling), AM (asymmetric pair) and FM (full scale, F5).
            (madeUpL, madeUpR) = truePeakGuard.process(left: madeUpL, right: madeUpR)
            let outL = clampf(madeUpL, -1.0, 1.0)
            let outR = clampf(madeUpR, -1.0, 1.0)
            writeAnalysisSample(
                index: i,
                postAGCLeft: audio.analysisStereo.postAGCLeft,
                postAGCRight: audio.analysisStereo.postAGCRight,
                preMPXLeft: outL,
                preMPXRight: outR,
                analysis: analysis)
            left[i] = outL
            right[i] = outR
        }
    }

    func renderAudioOnlyToneNonInterleaved(
        frameCount: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        analysis: AnalysisBuffers = .none
    ) {
        guard frameCount > 0 else { return }
        let makeup = audioOnlyOutputMakeup()
        let finalClip = processedAudioFinalClipActive
        for i in 0..<frameCount {
            let raw = nextToneRawSample()
            let tone = raw * toneGain
            renderingCalibrationTone = true
            var l: Float
            var r: Float
            switch toneMode {
            case "left":
                l = tone
                r = 0.0
            case "right":
                l = 0.0
                r = tone
            case "stereo":
                l = tone
                r = -tone
            default:
                l = tone
                r = tone
            }
            let audio = processAudioDomain(leftIn: l, rightIn: r)
            var pl = audio.left
            var pr = audio.right
            if finalClip {
                let c = processedAudioFinalClip(pl, pr)
                pl = c.0
                pr = c.1
            }
            var madeUpL = pl * makeup
            var madeUpR = pr * makeup
            (madeUpL, madeUpR) = truePeakGuard.process(left: madeUpL, right: madeUpR)
            let outL = clampf(madeUpL, -1.0, 1.0)
            let outR = clampf(madeUpR, -1.0, 1.0)
            writeAnalysisSample(
                index: i,
                postAGCLeft: audio.analysisStereo.postAGCLeft,
                postAGCRight: audio.analysisStereo.postAGCRight,
                preMPXLeft: outL,
                preMPXRight: outR,
                analysis: analysis)
            left[i] = outL
            right[i] = outR
        }
    }

    func renderMonitorFromInputInPlace(
        frameCount: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        analysis: AnalysisBuffers = .none
    ) {
        guard frameCount > 0 else { return }
        for i in 0..<frameCount {
            let direct = directMonitorStereo(leftIn: left[i], rightIn: right[i])
            writeAnalysisSample(index: i, postAGCLeft: direct.0, postAGCRight: direct.1, preMPXLeft: direct.0, preMPXRight: direct.1, analysis: analysis)
            left[i] = direct.0
            right[i] = direct.1
        }
    }

    func renderFromInputAndMonitorInPlace(
        frameCount: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        mpxLeft: UnsafeMutablePointer<Float>,
        mpxRight: UnsafeMutablePointer<Float>,
        analysis: AnalysisBuffers = .none
    ) {
        guard frameCount > 0 else { return }
        for i in 0..<frameCount {
            let inputL = left[i]
            let inputR = right[i]

            let detail = processSampleDetailed(leftIn: inputL, rightIn: inputR)
            writeAnalysisSample(index: i, stereo: detail.analysisStereo, analysis: analysis)
            let mpx = detail.mpx
            mpxLeft[i] = mpx
            mpxRight[i] = mpx

            let demod = demodulateMonitorFromMPXSample(mpx)
            left[i] = demod.0
            right[i] = demod.1
        }
    }

    func renderMonitorToneNonInterleaved(
        frameCount: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        analysis: AnalysisBuffers = .none
    ) {
        guard frameCount > 0 else { return }
        for i in 0..<frameCount {
            // Phase advance is handled inside `nextToneRawSample` for
            // the sine path; pink / white paths ignore phase.
            let raw = nextToneRawSample()
            let tone = raw * toneGain
            renderingCalibrationTone = true
            var l: Float
            var r: Float
            switch toneMode {
            case "left":
                l = tone
                r = 0.0
            case "right":
                l = 0.0
                r = tone
            case "stereo":
                l = tone
                r = -tone
            default:
                l = tone
                r = tone
            }
            let direct = directMonitorStereo(leftIn: l, rightIn: r)
            writeAnalysisSample(index: i, postAGCLeft: direct.0, postAGCRight: direct.1, preMPXLeft: direct.0, preMPXRight: direct.1, analysis: analysis)
            left[i] = direct.0
            right[i] = direct.1
        }
    }

    func renderToneAndMonitorNonInterleaved(
        frameCount: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        mpxLeft: UnsafeMutablePointer<Float>,
        mpxRight: UnsafeMutablePointer<Float>,
        analysis: AnalysisBuffers = .none
    ) {
        guard frameCount > 0 else { return }
        for i in 0..<frameCount {
            let raw = nextToneRawSample()
            let tone = raw * toneGain
            renderingCalibrationTone = true
            var srcL: Float
            var srcR: Float
            switch toneMode {
            case "left":
                srcL = tone
                srcR = 0.0
            case "right":
                srcL = 0.0
                srcR = tone
            case "stereo":
                srcL = tone
                srcR = -tone
            default:
                srcL = tone
                srcR = tone
            }

            let detail = processSampleDetailed(leftIn: srcL, rightIn: srcR)
            writeAnalysisSample(index: i, stereo: detail.analysisStereo, analysis: analysis)
            let mpx = detail.mpx
            mpxLeft[i] = mpx
            mpxRight[i] = mpx

            let demod = demodulateMonitorFromMPXSample(mpx)
            left[i] = demod.0
            right[i] = demod.1
        }
    }

    private func processSample(leftIn: Float, rightIn: Float) -> Float {
        processSampleDetailed(leftIn: leftIn, rightIn: rightIn).mpx
    }

    /// Output of one audio-domain pass. Carries the L/R signal plus the
    /// metering / activity side outputs that the MPX-domain composite
    /// encoder needs downstream.
    private struct AudioDomainOutput {
        var left: Float
        var right: Float
        var analysisStereo: ProgramStereoState
        var inputActivity: Float
    }

    // MARK: - DSP ingress

    /// Non-finite input samples the ingress guard has replaced with silence
    /// since this generator was built. Non-zero means something upstream --
    /// a plug-in, a driver, a decoded file -- handed the encoder NaN or Inf.
    private let nonFiniteInputSamples = ManagedAtomic<UInt64>(0)

    var nonFiniteInputSampleCount: UInt64 {
        nonFiniteInputSamples.load(ordering: .relaxed)
    }

    /// The ingress policy (0.65, audit P0-4): a non-finite input sample is
    /// silence, and every finite value passes through untouched -- including
    /// legitimately over-range ones, which the peak stages exist to handle.
    ///
    /// Without this one sample of NaN or Inf is permanent: it propagates into
    /// every recursive filter and envelope detector in the chain, and neither
    /// a one-pole smoother nor the self-heal paths can ever flush it, so the
    /// encoder goes silent until the transport restarts. `MPXDecoder` has
    /// guarded its own input exactly this way since 0.36; this is the same
    /// policy at the encoder's ingress, applied at each point where samples
    /// the engine did not generate itself enter the DSP.
    @inline(__always)
    private func sanitizeIngress(_ x: Float) -> Float {
        if x.isFinite { return x }
        nonFiniteInputSamples.wrappingIncrement(ordering: .relaxed)
        return 0.0
    }

    private func processSampleDetailed(leftIn: Float, rightIn: Float) -> (mpx: Float, analysisStereo: ProgramStereoState) {
        defer { renderingCalibrationTone = false }
        let leftIn = sanitizeIngress(leftIn)
        let rightIn = sanitizeIngress(rightIn)
        // High-level chain order:
        // 0. Dual-rate audio chain boundary (when enabled, audio domain
        //    runs at the lower audio rate INSIDE the boundary; otherwise
        //    the audio domain runs at the MPX rate after the boundary).
        // 1. Audio domain (AGC, multiband, EQ, image, pre-emphasis, pre-encode limiter)
        // 2. MPX domain (composite assembly, BS.412, composite clipper, pilot/RDS inject)
        if dualRateBoundaryEnabled {
            // Audio domain runs once per L OS-rate ticks at audio rate
            // inside applyDualRateBoundary; the returned l/r are the
            // upsampled audio-domain output at MPX rate. Side outputs
            // (analysisStereo, inputActivity) are buffered between
            // audio-rate ticks via `latestAudio*` so MPX-domain stages
            // see consistent values every OS tick.
            var l = leftIn
            var r = rightIn
            applyDualRateBoundary(left: &l, right: &r)
            let mpx = processMPXDomain(
                left: l,
                right: r,
                inputActivity: latestAudioInputActivity
            )
            return (mpx, latestAudioAnalysisStereo)
        }
        // Boundary off: audio domain runs at MPX rate as before
        // (bit-identical to the pre-cutover chain).
        let audio = processAudioDomain(leftIn: leftIn, rightIn: rightIn)
        let mpx = processMPXDomain(left: audio.left, right: audio.right, inputActivity: audio.inputActivity)
        return (mpx, audio.analysisStereo)
    }

    /// All audio-domain (L/R) processing: program-stereo block (AGC,
    /// multiband, EQ, image, etc.), stereo-image protection, pre-emphasis,
    /// pre-encode limiter. Returns the post-limiter L/R signal plus the
    /// metering snapshots (`analysisStereo` taken before stereo-image
    /// protection, and `inputActivity` from the raw input).
    private func processAudioDomain(leftIn: Float, rightIn: Float) -> AudioDomainOutput {
        let leftIn = sanitizeIngress(leftIn)
        let rightIn = sanitizeIngress(rightIn)
        var stereo = processProgramStereo(leftIn: leftIn, rightIn: rightIn)
        // Snapshot the program-stereo state BEFORE stereo-image protection so
        // analysis and metering callers see the unprotected program signal.
        // Image protection is a downstream side-channel limiter — it should
        // not colour upstream analysis readouts (mid/side, scopes).
        let analysisStereo = stereo

        // Stereo-image protection is an FM deviation / multipath guard: a
        // digital carrier has neither, so the full image goes to the encoder.
        if !audioStagesBypassed && !digitalDelivery && !amDelivery {
            let protected = protectStereoImage(
                inputL: stereo.referenceLeft,
                inputR: stereo.referenceRight,
                outputL: stereo.left,
                outputR: stereo.right
            )
            stereo.left = protected.0
            stereo.right = protected.1
        }

        updateStereoImageMonitor(left: stereo.left, right: stereo.right)

        // Pre-emphasis on L/R immediately upstream of the pre-encode limiter,
        // so the limiter peak-controls the HF-boosted signal. See `preL`/`preR`.
        let flatL = stereo.left
        let flatR = stereo.right
        stereo.left = preL.process(stereo.left)
        stereo.right = preR.process(stereo.right)

        // HF limiter: program-controlled pre-emphasis (Orban US 4,103,243
        // topology). Rides only the boost component `pre - flat`, so an HF
        // transient that overshoots loses (part of) its pre-emphasis boost
        // for a few ms instead of dragging the whole mix down in the
        // broadband limiter below. Default off -> not invoked.
        if hfLimiterEnabled && !audioStagesBypassed {
            let limited = hfLimiter.process(
                flatL: flatL, flatR: flatR,
                emphasizedL: stereo.left, emphasizedR: stereo.right)
            stereo.left = limited.0
            stereo.right = limited.1
        }

        if preEncodeAudioLimiterEnabled && !audioStagesBypassed {
            let limited = preEncodeAudioLimiter.process(left: stereo.left, right: stereo.right)
            stereo.left = limited.0
            stereo.right = limited.1
        }

        return AudioDomainOutput(
            left: stereo.left,
            right: stereo.right,
            analysisStereo: analysisStereo,
            inputActivity: stereo.inputActivity
        )
    }

    /// MPX-domain composite assembly and final loudness/safety stages.
    /// Runs at the engine's MPX rate regardless of dual-rate boundary
    /// state (the boundary is upstream; pilot / L-R sidebands / RDS need
    /// the high rate's bandwidth).
    private func processMPXDomain(left: Float, right: Float, inputActivity: Float) -> Float {
        let composite = makeCompositeComponents(
            left: left,
            right: right,
            inputActivity: inputActivity
        )
        return processFinalComposite(
            base: composite.base,
            diff: composite.diff,
            sub: composite.sub,
            pilot: composite.pilot,
            rds: composite.rds
        )
    }

    private func processProgramStereo(leftIn: Float, rightIn: Float) -> ProgramStereoState {
        let gainIn: Float = renderingCalibrationTone ? 1.0 : inputGain
        var left = leftIn * gainIn
        var right = rightIn * gainIn

        if monoMode {
            let mono = (left + right) * 0.5
            left = mono
            right = mono
        }
        let inputActivity = max(fabsf(left), fabsf(right))

        if !audioStagesBypassed {
            // Phase rotation: reduce waveform asymmetry before AGC
            if phaseRotationEnabled {
                let rotated = phaseRotator.process(left: left, right: right)
                left = rotated.0
                right = rotated.1
            }

            // Advanced Dynamics replaces BOTH the wideband AGC and the
            // multiband compressor with one fused leveling stage (its whole
            // point is that the two can no longer fight). When it is off
            // this condition reduces to the previous `widebandAGCEnabled`
            // check -- bit-identical chain, zero-drift by construction.
            if widebandAGCEnabled && !advancedDynamicsEnabled {
                let adjusted = widebandAGC.process(left: left, right: right)
                left = adjusted.0
                right = adjusted.1
            }

            let filteredInput = inputHPF.process(left: left, right: right)
            left = filteredInput.0
            right = filteredInput.1
        }

        let postAGCLeft = left
        let postAGCRight = right
        // Program lowpass only where `programLowpassInPath` says so: in the
        // processed-audio modes the encoder FIR below is the band-limit (its
        // cutoff is never above this one -- both derive from
        // `programLowpassHz`, the encoder's capped lower). A composite whose
        // audio domain runs at the full rate gets the 48 kHz-domain design
        // (`programLPStrided`), so its response no longer depends on whether
        // the dual-rate boundary is on
        // (`DualRateHFResponseTests.dualRateOnMatchesOffNearEncoderCutoff`,
        // `OutputResponseTests`).
        if programLowpassInPath {
            let programBand = (useEncoderFIR && programLPStrided.isStrided)
                ? programLPStrided.process(left: left, right: right)
                : programLP.process(left: left, right: right)
            left = programBand.0
            right = programBand.1
        }
        let referenceLeft = left
        let referenceRight = right

        if !audioStagesBypassed {
            let trimmed = hfTrim.process(left: left, right: right)
            left = trimmed.0
            right = trimmed.1

            // Parametric EQ: tonal shaping before dynamics processing
            if parametricEQEnabled {
                let eqd = parametricEQ.process(left: left, right: right)
                left = eqd.0
                right = eqd.1
            }

            // Stereo image stage: mono bass + side-energy protection. (The
            // stereo widener that used to follow the multiband was removed in
            // 0.50 -- measured as adding nothing beneficial on air.)
            let stereoImage = processStereoImageStage(left: left, right: right)
            left = stereoImage.left
            right = stereoImage.right

            if advancedDynamicsEnabled {
                // Single-stage leveler in the multiband slot (AGC skipped
                // above); the FIR split's group delay matches the multiband
                // FIR path's treatment -- audio-domain latency, no
                // subcarrier alignment impact.
                let leveled = advancedDynamics.process(left: left, right: right)
                left = leveled.0
                right = leveled.1
            } else if multibandEnabled {
                let multiband = processMultibandStereo(left: left, right: right)
                left = multiband.0
                right = multiband.1
            }

            // PrimeBass post-multiband: multiband no longer compresses the
            // MaxxBass / Aural Exciter / Big Bottom-style harmonics back
            // down. Canonical industry placement for bass enhancers.
            if primeBassEnabled {
                let primeBassOut = processPrimeBass(left: left, right: right)
                left = primeBassOut.0
                right = primeBassOut.1
            }

            // Bass clipper: pre-clip bass peaks independently to reduce LF-induced IMD
            if bassClipperEnabled {
                let bassClipped = bassClipper.process(left: left, right: right)
                left = bassClipped.0
                right = bassClipped.1
            }

            // Distortion-cancelled clipper: LF distortion cancellation
            if dcClipperEnabled {
                let dcOut = dcClipper.process(left: left, right: right)
                left = dcOut.0
                right = dcOut.1
            }
        }

        // Encoder HF guard: a small (<= 2 dB) stereo-linked HF gain ride ahead
        // of the encoder lowpass. NOT redundant with the HF limiter (measured
        // 2026-08-29): removing it cost 20-40 dB of receiver-side HF stereo
        // separation on the tone test, because the un-attenuated HF drives the
        // composite clipper into audio-band cubic IM that decodes as crosstalk,
        // while the pre-emphasis-domain HF limiter does not engage at those
        // levels. Keep it.
        if encoderHFGuardEnabled && !renderingCalibrationTone {
            let guarded = processEncoderHFGuard(left: left, right: right)
            left = guarded.0
            right = guarded.1
        }

        // Final encoder-facing bandwidth guard. This sits immediately ahead of
        // stereo encoding and pre-emphasis so later nonlinear stages do not
        // re-broaden the transmitted audio spectrum.
        //
        // Transmit mode uses a Kaiser-windowed linear-phase FIR for a >80 dB
        // stop-band (~1.67 ms latency at 192 kHz). Monitor mode uses the
        // Butterworth cascade for minimum latency. The choice is made per
        // engine start by AudioOutputEngine via setEncoderFIREnabled(_:).
        let encoderBand: (Float, Float)
        if useEncoderFIR {
            encoderBand = encoderProgramFIR.process(left: left, right: right)
        } else {
            encoderBand = encoderProgramLP.process(left: left, right: right)
        }
        left = encoderBand.0
        right = encoderBand.1

        return ProgramStereoState(
            left: left,
            right: right,
            referenceLeft: referenceLeft,
            referenceRight: referenceRight,
            postAGCLeft: postAGCLeft,
            postAGCRight: postAGCRight,
            inputActivity: inputActivity
        )
    }

    @inline(__always)
    private func directMonitorStereo(leftIn: Float, rightIn: Float) -> (Float, Float) {
        var left = sanitizeIngress(leftIn) * inputGain
        var right = sanitizeIngress(rightIn) * inputGain
        if monoMode {
            let mono = (left + right) * 0.5
            left = mono
            right = mono
        }
        return (clampf(left, -1.0, 1.0), clampf(right, -1.0, 1.0))
    }

    @inline(__always)
    private func writeAnalysisSample(index: Int, stereo: ProgramStereoState, analysis: AnalysisBuffers) {
        writeAnalysisSample(
            index: index,
            postAGCLeft: stereo.postAGCLeft,
            postAGCRight: stereo.postAGCRight,
            preMPXLeft: stereo.left,
            preMPXRight: stereo.right,
            analysis: analysis
        )
    }

    @inline(__always)
    private func writeAnalysisSample(
        index: Int,
        postAGCLeft: Float,
        postAGCRight: Float,
        preMPXLeft: Float,
        preMPXRight: Float,
        analysis: AnalysisBuffers
    ) {
        analysis.postAGCLeft?[index] = postAGCLeft
        analysis.postAGCRight?[index] = postAGCRight
        analysis.preMPXLeft?[index] = preMPXLeft
        analysis.preMPXRight?[index] = preMPXRight
    }

    private func processEncoderHFGuard(left: Float, right: Float) -> (Float, Float) {
        let split = encoderHFGuardSplit.process(left: left, right: right)
        let lowL = split.0.0
        let highL = split.0.1
        let lowR = split.1.0
        let highR = split.1.1

        let hfDrive = max(fabsf(highL), fabsf(highR))
        encoderHFGuardEnv = Self.smoothEnvelope(
            current: encoderHFGuardEnv,
            input: hfDrive,
            attackCoeff: encoderHFGuardAttackCoeff,
            releaseCoeff: encoderHFGuardReleaseCoeff
        )

        let threshold: Float = 0.11
        let over = max(0.0, encoderHFGuardEnv - threshold)
        let targetReductionDB = min(2.0, over * 24.0)
        let targetGain = powf(10.0, -targetReductionDB / 20.0)
        encoderHFGuardGain = Self.smoothTowardTarget(
            current: encoderHFGuardGain,
            target: targetGain,
            attackCoeff: encoderHFGuardAttackCoeff,
            releaseCoeff: encoderHFGuardReleaseCoeff
        )

        return (
            lowL + (highL * encoderHFGuardGain),
            lowR + (highR * encoderHFGuardGain)
        )
    }

    private func makeCompositeComponents(left: Float, right: Float, inputActivity: Float)
        -> CompositeComponents {
        let base = ((left + right) * 0.5) * sumLevel
        // S = (L - R)/2 on a 38 kHz subcarrier that crosses zero with positive
        // slope at every pilot zero crossing (47 CFR 73.322, ITU-R BS.450-3):
        // a standard receiver forms L = M + S. Until 0.45 this was (R - L)/2,
        // which every real receiver decoded with L and R swapped; MPXDecoder
        // carried a compensating negation so no in-repo gate could see it.
        let diff = monoMode ? 0.0 : (((left - right) * 0.5) * diffLevel)
        // Pre-emphasis ran here pre-2026-05; it now runs in L/R domain
        // immediately upstream of the pre-encode limiter. See `preL` / `preR`.
        lastProgramActivity = inputActivity

        // (Phase advance for the tone source moved into
        // `nextToneRawSample` — was a side-effect here that only
        // worked when the source was a tone going through
        // `processSampleDetailed`. The render-time helper now owns
        // phase advance for all three tone paths.)

        pilotOsc.step()
        let stereoServicesEnabled = !monoMode
        let pilot = (stereoServicesEnabled && pilotSupported) ? (pilotOsc.s * pilotLevel) : 0.0
        let sub = (stereoServicesEnabled && stereoSubcarrierSupported) ? pilotOsc.sin2x() : 0.0
        lastSubcarrierSample = sub

        if stereoServicesEnabled {
            // Lock RDS to the emitted pilot: hand the coder the pilot
            // oscillator's instantaneous sin(theta); it derives the 57 kHz
            // carrier as sin(3*theta) from the same recurrence value.
            rdsCoder?.updateRDSPilotSin(pilotOsc.s)
        }
        let rds =
            (stereoServicesEnabled && rdsSupported)
            ? (rdsCoder?.nextSampleWithPilotLock() ?? 0.0) * rdsLevelCompensation
            : 0.0

        return CompositeComponents(base: base, diff: diff, sub: sub, pilot: pilot, rds: rds)
    }

    private func processStereoImageStage(left: Float, right: Float) -> StereoImageState {
        var state = StereoImageState(left: left, right: right)

        if monoBassEnabled {
            let monoBass = processMonoBass(left: state.left, right: state.right)
            state.left = monoBass.0
            state.right = monoBass.1
        }

        return state
    }

    private func processFinalComposite(
        base: Float,
        diff: Float,
        sub: Float,
        pilot: Float,
        rds: Float
    ) -> Float {
        let subcarriers = (pilot + rds) * deviationScale
        // Phase-align pilot/RDS with the delayed audio composite (the
        // 38 kHz stereo subcarrier embedded in `diff·sub` was generated
        // at this oscillator step; the audio composite about to be
        // assembled will then traverse the composite clipper and final
        // limiter delays before output, while pilot/RDS would otherwise
        // be added with the current phase. Delaying pilot+RDS by the
        // same chain delay keeps the receiver-side stereo decoder's
        // pilot-locked 38 kHz reference aligned with the audio
        // composite's internal subcarrier modulation.
        let delayedSubcarriers: Float
        let subDelayN = subcarrierDelayActiveCount
        if subDelayN > 0 {
            delayedSubcarriers = subcarrierDelayLine[subcarrierDelayWriteIdx]
            subcarrierDelayLine[subcarrierDelayWriteIdx] = subcarriers
            subcarrierDelayWriteIdx += 1
            if subcarrierDelayWriteIdx >= subDelayN {
                subcarrierDelayWriteIdx = 0
            }
            lastSubcarrierSample = stereoSubcarrierDelayLine[stereoSubcarrierDelayWriteIdx]
            stereoSubcarrierDelayLine[stereoSubcarrierDelayWriteIdx] = sub
            stereoSubcarrierDelayWriteIdx += 1
            if stereoSubcarrierDelayWriteIdx >= subDelayN {
                stereoSubcarrierDelayWriteIdx = 0
            }
        } else {
            delayedSubcarriers = subcarriers
            lastSubcarrierSample = sub
        }
        let reserved = updateSubcarrierReservation(pilot: pilot, rds: rds)
        let thresholds = Self.makeFinalCompositeThresholds(
            outputGain: outputGain,
            threshold: threshold,
            deviationScale: deviationScale,
            reserved: reserved
        )

        // Keep the loudness work in the audio composite before the calibrated
        // pilot/RDS subcarriers are added back into the final MPX waveform.
        // Calibration tone: the drive IS the budget, so a 0 dBFS tone sits at
        // exactly 100% of the available audio modulation (deviation is then
        // `75 kHz x budget x 10^(level/20)`, plus pilot/RDS; the budget already
        // carries `mpx_deviation_khz`, so the composite's deviation scaling is
        // divided back out of the tone's drive).
        let compositeBudget = max(0.01, thresholds.audioCeiling)
        let driveNow = renderingCalibrationTone
            ? compositeBudget / max(1e-3, deviationScale) : finalDrive
        let rawAudioComposite: Float
        if ssbStereoEnabled && ssbStereoConfigured {
            // SSB Stereo: SSB-leaning stereo assembly. Base and diff ride
            // the encoder's matched delay; the 38 kHz carrier (both phases)
            // is applied at the CURRENT oscillator step, so pilot/subcarrier
            // phase coherence -- and the guard bands the composite clipper
            // protects -- are exactly as in the classic path.
            let ssb = ssbStereo.process(
                base: base, diff: diff, sub: sub, cos2: pilotOsc.cos2x())
            rawAudioComposite = (ssb.base + ssb.stereo) * deviationScale * driveNow
        } else {
            rawAudioComposite = Self.makeDrivenAudioComposite(
                base: base,
                diff: diff,
                sub: sub,
                deviationScale: deviationScale,
                finalDrive: driveNow
            )
        }
        let audioCompositeShaperActive = audioCompositeSoftClipEnabled
        var audioComposite = rawAudioComposite

        // Composite clipper FIRST, with its threshold/ceiling referenced to
        // the audio-composite BUDGET (what is left of the composite after
        // the pilot/RDS reservation), not to digital full scale. Until
        // 0.45 the order was shaper -> clipper with the clipper's -1 dB
        // threshold read against 1.0: the budget (~0.85 with pilot + RDS)
        // sat BELOW that threshold, so the 1x, un-oversampled, guard-less
        // `softClipSafety` shaper did every bit of the clipping and the
        // oversampled guard-band-protected clipper never engaged (measured
        // by --verify-hf-transients: clipper on/off was bit-identical on
        // music_loud; the shaper cost 13 dB of decoded HF SINAD). The
        // budget is a slowly-varying envelope (subcarrier reservation,
        // ~ms time constants) against the clipper's ~0.1 ms internal
        // delay, so scaling in and out by the same current value keeps
        // the differential-topology cancellation exact in practice.
        // Normalisation maps the clipper's CEILING onto the budget (so the
        // operator's ceiling/threshold pair keeps its knee width while the
        // audio composite may use the whole budget, exactly as the pre-0.45
        // shaper let it -- deviation stays where operators calibrated it).
        // Calibration tone: the peak stages stay in the path for their DELAY
        // (pilot/RDS alignment) but are made transparent by scaling the tone
        // far below their thresholds -- a sine at any level is a calibrated
        // level, never a clipping subject.
        let calibrationHeadroom: Float = renderingCalibrationTone ? 8.0 : 1.0
        if compositeClipperEnabled {
            let scale = (compositeBudget / compositeClipper.ceilingLinear) * calibrationHeadroom
            audioComposite = compositeClipper.process(audioComposite / scale) * scale
        }

        // Audio-composite bandwidth cleanup. Any real program content should
        // live below the upper stereo sideband, so remove clipper spill
        // before pilot/RDS injection. The FIR's group delay is included in
        // `recomputeSubcarrierDelay()` so subcarriers remain phase-aligned.
        // It runs BEFORE the shaper: the differential clipper's output is
        // `clipped + (residual above 53 kHz)` -- bounded only once this FIR
        // has removed that un-cancelled HF residual. Shaping before the FIR
        // hard-clipped that residual at 1x rate (measured on a 12 dB
        // overdrive: ~-9 dB of shaper action relative to the composite).
        audioComposite = audioCompositeBandwidthFIR.processMono(audioComposite)

        // BS.412, part 1 of 2: the transparent rider. It observes the audio
        // BEFORE its own gain (feed-forward -- a loop closed around the
        // 60-second measurement lags by design and cannot hold "any interval
        // of 60 s") together with the subcarriers that will be added to it,
        // and rides the AUDIO path only. Pilot and RDS are injected after
        // every peak stage at constant amplitude; they are never the
        // actuator's to touch. The hard guard further down is what proves
        // the limit; this is what keeps the guard idle and the sound clean.
        //
        // The rider OBSERVES whether or not the stage is enabled, so that
        // switching it on acts on real recent history rather than starting a
        // fresh prediction window; only the gain application is gated.
        let bs412Controlling = bs412Enabled && !renderingCalibrationTone
        bs412Rider.observe(
            audio: audioComposite, subcarriers: delayedSubcarriers,
            ceilingDBr: bs412CeilingDBr)
        if bs412Controlling {
            audioComposite *= bs412Rider.gain
        }

        // Final look-ahead MPX limiter on the audio composite, budget-
        // referenced like the clipper. The clipper's guard-band cancellation
        // restores the protected bands (pilot / 22-53 kHz stereo / RDS) to
        // the CLEAN input, so its output legitimately exceeds its own
        // ceiling in-band (probe: 1.18 vs a 0.966 ceiling on a 12 dB
        // overdrive; the 55 kHz FIR removes none of it). That excess is the
        // price of clean guards and must be taken by a gain ride, not a
        // waveshaper: this limiter (5 ms look-ahead, a step-free ramp over
        // the whole look-ahead, hold, ~95 ms release) rides it down without
        // IM. Until 0.45 it ran AFTER
        // the shaper against an absolute 0.98 threshold -- above the
        // shaper's budget ceiling, so it never engaged in any profile.
        // Pilot and RDS are injected after all of this at constant
        // amplitude (Omnia / Orban / Stereotool practice).
        if limitEnabled {
            // Threshold mapped exactly onto the budget: the limiter starts
            // where the clipper's ceiling ends and rides only the guard
            // overshoot. Its windowed look-ahead detector plus gain floor
            // (0.45, A1b) mean nothing above the threshold leaves it, so the
            // 0.985 margin that used to absorb the old detector's attack
            // leakage is no longer needed and the shaper behind it sits idle.
            let scale = (compositeBudget / lookaheadLimiter.threshold) * calibrationHeadroom
            audioComposite = lookaheadLimiter.process(audioComposite / scale) * scale
        }

        // Shaper: the ONE budget safety net behind clipper + limiter. It only
        // catches what those cannot (limiter attack leakage, impossible
        // configurations, both stages disabled). Memoryless, so its position
        // changes no delay accounting. (Until 0.45 this was two identical
        // soft clips around a 54 kHz one-pole "smoother" plus a third clip
        // at an absolute 0.98 after output gain -- all idle or redundant
        // once the clipper and limiter own the peaks; removed.)
        if audioCompositeShaperActive {
            let excess = fabsf(audioComposite) / max(1e-6, thresholds.audioCeiling)
            let excessDB: Float = excess > 1.0 ? 20.0 * log10f(excess) : 0.0
            safetyClipExcessDB = max(excessDB, safetyClipExcessDB * audioCompositePeakDecayCoeff)
            audioComposite = Self.softClipSafety(
                audioComposite,
                threshold: thresholds.audioCeiling
            )
        }

        var mpx = audioComposite * outputGain

        // Composite budget governor. A smoothed gain ride does the
        // audible work, reducing only the audio path before pilot/RDS
        // injection. The hard ceiling remains as a last-sample guard
        // for attack-time transients and impossible configurations.
        let audioCeilOut = thresholds.audioCeiling * outputGain
        let audioAbsOut = fabsf(mpx)
        let budgetTargetGain = audioAbsOut > audioCeilOut
            ? audioCeilOut / max(1e-9, audioAbsOut)
            : 1.0
        compositeBudgetGain = Self.smoothTowardTarget(
            current: compositeBudgetGain,
            target: budgetTargetGain,
            attackCoeff: compositeBudgetGainAttackCoeff,
            releaseCoeff: compositeBudgetGainReleaseCoeff
        )
        mpx *= compositeBudgetGain
        if fabsf(mpx) > audioCeilOut {
            mpx = copysignf(audioCeilOut, mpx)
        }

        // Meter the governed audio path, not the pre-governor composite.
        // `audioPeak` is reported post-outputGain by
        // `makeCompositeCalibration`, so store the equivalent pre-gain
        // value here.
        let governedAudioPreGainAbs = fabsf(mpx) / max(1e-6, outputGain)
        audioCompositePeakState = max(
            governedAudioPreGainAbs,
            audioCompositePeakState * audioCompositePeakDecayCoeff
        )

        // Inject pilot and RDS after all limiting — constant amplitude.
        // Use the delay-aligned subcarriers so receiver-side stereo
        // demod sees pilot phase consistent with the audio composite's
        // internal 38 kHz subcarrier modulation.
        // BS.412, part 2 of 2: the compliance guard. Last point at which the
        // reducible audio and the fixed subcarriers are still separable, and
        // after every audio-only peak stage and the budget governor -- so
        // this is where the energy budget can be enforced exactly.
        // The guard ACCOUNTS every sample whether or not it is enforcing, so
        // its 60-second window is real history the moment the operator
        // enables the stage. Only the attenuation is gated.
        let inverseOutputGain = 1.0 / max(1e-6, outputGain)
        let emitted = bs412Guard.process(
            audio: mpx * inverseOutputGain,
            subcarriers: delayedSubcarriers,
            ceilingDBr: bs412CeilingDBr,
            enforcing: bs412Controlling)
        mpx = emitted * outputGain

        // Telemetry: measure how far the unclamped MPX exceeds ±1.0.
        // Non-zero envelope ⇒ pilot/RDS are being clipped at the
        // final clamp, breaking the constant-amplitude subcarrier
        // invariant. Reported through `CompositeCalibrationStatus`
        // so operators / verifier can detect over-budget config.
        let overshoot = max(0.0, fabsf(mpx) - 1.0)
        postInjectionOvershootEnv = max(
            overshoot,
            postInjectionOvershootEnv * postInjectionOvershootDecayCoeff
        )

        let output = clampf(mpx, -1.0, 1.0)

        // BS.412 reporting: the COMPLETE multiplex, pilot and RDS included,
        // exactly as it leaves here, in the modulation domain (|x| = 1.0 is
        // 75 kHz, so `output_gain_db` divides back out). It runs whether or
        // not the limiter is enabled AND during Test Tone -- a transmitted
        // calibration tone is still part of the multiplex, and omitting it
        // would leave a hole in the power history. Enabling the limiter
        // therefore acts on a window that is already full.
        //
        // This observes the CLAMPED sample, i.e. what is really emitted;
        // post-injection overshoot is published separately so a final clamp
        // can never turn broken pilot / RDS into an apparently compliant
        // reading.
        // Status is rebuilt only at a block boundary. Doing it per sample
        // cost 1.3 points of chain time with the stage DISABLED, because
        // `powerDBr` takes a logarithm and `meanSquare` a Double divide --
        // per sample, for a value that cannot change more than once per 64.
        let bs412BlockComplete = bs412Meter.process(output * inverseOutputGain)
        if bs412BlockComplete {
            bs412StatusState = BS412Status(
                powerDBr: bs412Meter.powerDBr,
                powerValid: bs412Meter.windowValid && !renderingCalibrationTone,
                secondsObserved: bs412Meter.secondsObserved,
                gainReductionDB: bs412Controlling ? bs412Rider.gainReductionDB : 0.0,
                overCeiling: bs412Meter.windowValid && bs412Meter.powerDBr > bs412CeilingDBr,
                unachievable: bs412Controlling && (bs412Rider.unachievable || bs412Guard.unachievable),
                guardActive: bs412Controlling && bs412Guard.active,
                controlSuspended: bs412Enabled && renderingCalibrationTone
            )
        }

        return output
    }

    /// Headroom the audio composite leaves for pilot + RDS, in the composite
    /// domain (deviation scaling applied).
    ///
    /// It reserves the subcarriers' known PEAK -- `pilot_level` plus the RDS
    /// injection (the coder normalises its shaped output to unit peak) --
    /// for each one that is actually on air, and never less than an
    /// instant-attack, slow-release hold of the observed `|pilot + rds|`, so
    /// a data pattern that peaks above the nominal injection is covered too.
    /// The reservation is read from the UNDELAYED subcarriers while the audio
    /// it bounds leaves the peak stages beside the DELAYED ones, so the
    /// instant attack is ahead of every sample it has to cover.
    ///
    /// Until 2026-10 this was a 0.5 ms / 12 ms envelope of `|pilot + rds|`:
    /// on a 19 kHz sine the attack never reached the crest (0.074 for a 0.08
    /// pilot) and the RDS crests were barely seen, so the audio budget was
    /// too large by the difference. At pilot 10 % / RDS 4 kHz and above --
    /// inside the ranges `sanitize()` accepts -- the total multiplex crossed
    /// full scale and the final clamp clipped the pilot and RDS
    /// (peak-control review F2; verifier at 12 % / 7.5 kHz: 75.0 kHz,
    /// post-injection overshoot 0.0136).
    ///
    /// The result is constant while the subcarrier configuration is, so the
    /// budget the clipper and the limiter normalise onto does not wobble at
    /// the RDS symbol rate. A component that goes off air releases its
    /// reserve over seconds (presence hold), never stepping it down.
    @inline(__always)
    private func updateSubcarrierReservation(pilot: Float, rds: Float) -> Float {
        let decay = subcarrierReservationReleaseCoeff
        pilotPresenceEnv = max(fabsf(pilot), pilotPresenceEnv * decay)
        rdsPresenceEnv = max(fabsf(rds), rdsPresenceEnv * decay)
        subcarrierPeakHoldEnv = max(fabsf(pilot + rds), subcarrierPeakHoldEnv * decay)
        let pilotPeak = max(0.0, pilotLevel)
        let rdsPeak = max(0.0, rdsInjectionPercent * 0.01) * rdsLevelCompensation
        // Present (its own hold above a quarter of the nominal peak): the
        // full nominal peak. Absent or fading out: four times the hold, which
        // is continuous with the nominal value at the quarter point and
        // decays to zero -- so turning a service off never steps the budget.
        let pilotReserve = min(pilotPeak, 4.0 * pilotPresenceEnv)
        let rdsReserve = min(rdsPeak, 4.0 * rdsPresenceEnv)
        let peak = max(pilotReserve + rdsReserve, subcarrierPeakHoldEnv)
        subcarrierReservationEnv = peak * deviationScale
        return subcarrierReservationEnv
    }

    private func updateStereoImageMonitor(left: Float, right: Float) {
        let postSideAbs = fabsf((left - right) * 0.5)
        monitorExpectedSideEnv = Self.smoothEnvelope(
            current: monitorExpectedSideEnv,
            input: postSideAbs,
            attackCoeff: monitorExpectedSideAttackCoeff,
            releaseCoeff: monitorExpectedSideReleaseCoeff
        )
    }

    private static func makeFinalCompositeThresholds(
        outputGain: Float,
        threshold: Float,
        deviationScale: Float,
        reserved: Float
    ) -> FinalCompositeThresholds {
        // Composite budget governor (per 2026-05 chain audit Finding
        // #3). The audio composite must fit inside whatever budget is
        // left after the operator's outputGain × subcarrier reservation:
        //
        //   |audio·outputGain + subcarriers·outputGain| ≤ 1.0
        //   audio ≤ (1.0 - subcarriers·outputGain) / outputGain
        //   audio ≤ 1/outputGain - reserved
        //
        // We use the engine's `threshold` (default 0.98) instead of 1.0
        // to leave a small numeric guard below the hard ±1.0 clamp.
        // No headroom split between pre/post limiter ceilings; both
        // share the same `allowedAudioAbs`. The audio composite is
        // dynamically reduced when reservation grows; pilot/RDS stay
        // at the operator-chosen amplitude. When `allowedAudioAbs`
        // reaches 0, audio is muted and `overBudget` is reported via
        // telemetry — the operator must lower outputGain or
        // subcarrier levels.
        //
        // Composite Deviation (`mpx_deviation_khz`) is the PEAK target, so it
        // belongs in the budget: composite amplitude 1.0 is 75 kHz at every
        // setting (`referenceDeviationKHz`), and a 50 kHz station's whole
        // multiplex must peak at 50/75 of that. Until 2026-10 only the drive
        // and the pilot/RDS amplitudes followed the setting while the budget
        // stayed at the 75 kHz value, so the clipper and the final limiter
        // normalised the audio back up to ~0.88 x 75 kHz at every setting:
        // 70.8 kHz peaks at a 50 kHz setting on the verifier
        // (peak-control review F1). Above 75 kHz the budget stays at full
        // scale -- the +/-1.0 clamp is the hard bound of the digital domain.
        // The safety margin scales like the threshold it is taken from: with
        // the deviation (it guards against rounding and tracking error, which
        // are proportional to the signal, so a 50 kHz composite stays exactly
        // 2/3 of the 75 kHz one) and with the output gain (it is headroom
        // under the +/-1.0 clamp, so in the pre-gain domain it is
        // margin / gain like the threshold; taken whole it cost 0.16 of full
        // scale at +18 dB and declared a silent pilot+RDS multiplex that
        // peaks at 0.85 over budget once the reservation read the real
        // subcarrier peak).
        let gain = max(1.0, outputGain)
        let deviationShare = min(1.0, max(0.0, deviationScale))
        let effectiveThreshold = threshold * deviationShare / gain
        let margin = Self.finalCompositeBudgetSafetyMargin * deviationShare / gain
        let allowedAudioAbs = max(0.0, effectiveThreshold - reserved - margin)
        let overBudget = allowedAudioAbs <= 0.0
        return FinalCompositeThresholds(
            effectiveThreshold: effectiveThreshold,
            audioCeiling: allowedAudioAbs,
            overBudget: overBudget
        )
    }

    private static func makeCompositeCalibration(
        audioPeakState: Float,
        reservationEnv: Float,
        outputGain: Float
    ) -> (audioPeak: Float, budgetMarginDB: Float) {
        let postGain = max(0.0, outputGain)
        let reserved = max(0.0, min(1.2, reservationEnv * postGain))
        let audioPeak = audioPeakState * postGain
        let totalPeakBudget = max(1e-6, audioPeak + reserved)
        let budgetMarginDB = -20.0 * log10f(totalPeakBudget)
        return (audioPeak, budgetMarginDB)
    }

    @inline(__always)
    private static func makeDrivenAudioComposite(
        base: Float,
        diff: Float,
        sub: Float,
        deviationScale: Float,
        finalDrive: Float
    ) -> Float {
        (base + (diff * sub)) * deviationScale * finalDrive
    }

    @inline(__always)
    private static func makeOutputComposite(
        audioComposite: Float,
        subcarriers: Float,
        outputGain: Float
    ) -> Float {
        (audioComposite + subcarriers) * outputGain
    }

    @inline(__always)
    private static func smoothEnvelope(
        current: Float,
        input: Float,
        attackCoeff: Float,
        releaseCoeff: Float
    ) -> Float {
        let coeff = input > current ? attackCoeff : releaseCoeff
        return (coeff * current) + ((1.0 - coeff) * input)
    }

    @inline(__always)
    private static func smoothTowardTarget(
        current: Float,
        target: Float,
        attackCoeff: Float,
        releaseCoeff: Float
    ) -> Float {
        let coeff = target < current ? attackCoeff : releaseCoeff
        return (coeff * current) + ((1.0 - coeff) * target)
    }

    private func protectStereoImage(
        inputL: Float,
        inputR: Float,
        outputL: Float,
        outputR: Float
    ) -> (Float, Float) {
        let inputMid = (inputL + inputR) * 0.5
        let inputSide = (inputL - inputR) * 0.5
        let outputMid = (outputL + outputR) * 0.5
        let outputSide = (outputL - outputR) * 0.5

        let inputMidAbs = fabsf(inputMid)
        let inputSideAbs = fabsf(inputSide)
        let outputMidAbs = fabsf(outputMid)
        let outputSideAbs = fabsf(outputSide)

        stereoProtectInputMidEnv = Self.smoothEnvelope(
            current: stereoProtectInputMidEnv,
            input: inputMidAbs,
            attackCoeff: stereoProtectAttackCoeff,
            releaseCoeff: stereoProtectReleaseCoeff
        )
        stereoProtectInputSideEnv = Self.smoothEnvelope(
            current: stereoProtectInputSideEnv,
            input: inputSideAbs,
            attackCoeff: stereoProtectAttackCoeff,
            releaseCoeff: stereoProtectReleaseCoeff
        )
        stereoProtectMidEnv = Self.smoothEnvelope(
            current: stereoProtectMidEnv,
            input: outputMidAbs,
            attackCoeff: stereoProtectAttackCoeff,
            releaseCoeff: stereoProtectReleaseCoeff
        )
        stereoProtectSideEnv = Self.smoothEnvelope(
            current: stereoProtectSideEnv,
            input: outputSideAbs,
            attackCoeff: stereoProtectAttackCoeff,
            releaseCoeff: stereoProtectReleaseCoeff
        )

        let inputRatio = stereoProtectInputSideEnv / max(0.02, stereoProtectInputMidEnv)
        let configuredRatio = 0.70 + (Self.stereoProtectWidthReference * 0.65)
        let allowedRatio = min(1.55, max(configuredRatio, inputRatio * 1.16))
        let allowedSide = max(0.008, stereoProtectMidEnv * allowedRatio)

        var targetGain: Float = 1.0
        if stereoProtectSideEnv > allowedSide {
            targetGain = clampf(allowedSide / max(1e-5, stereoProtectSideEnv), 0.0, 1.0)
        }

        stereoProtectGain = Self.smoothTowardTarget(
            current: stereoProtectGain,
            target: targetGain,
            attackCoeff: stereoProtectAttackCoeff,
            releaseCoeff: stereoProtectReleaseCoeff
        )

        let protectedSide = outputSide * stereoProtectGain
        return (outputMid + protectedSide, outputMid - protectedSide)
    }

    /// The stereo-image protection's allowed side/mid ratio used to scale
    /// with the (removed) widener's Width; 0.5 was its default, so keeping
    /// the identical runtime expression leaves every widener-off chain --
    /// all strict baselines -- bit-identical. Music - Loud (Width 0.46 via
    /// the old wide_chr preset) moves from a 0.999 to a 1.025 ratio.
    private static let stereoProtectWidthReference: Float = 0.5

    private func processMonoBass(left: Float, right: Float) -> (Float, Float) {
        monoBassFilter.process(left: left, right: right)
    }

    private func processPrimeBass(left: Float, right: Float) -> (Float, Float) {
        let amount = clampf(primeBassAmount, 0.0, 1.0)
        let subAmount = primeBassSubharmonicsEnabled
            ? clampf(primeBassSubharmonicsAmount, 0.0, 1.0) : 0.0
        if amount <= 1e-4, subAmount <= 1e-4 {
            return (left, right)
        }
        let harmonics = clampf(primeBassHarmonics, 0.0, 1.0)
        let density = clampf(primeBassDensity, 0.0, 1.0)
        let mid = (left + right) * 0.5
        let side = (left - right) * 0.5

        // 1. Fundamental band, 0.35 F0 .. F0, 24 dB/oct both sides.
        let band = primeBassInLPF.process(primeBassInHPF.process(mid))
        let bandAbs = fabsf(band)

        // 2. Level normaliser: the device always sees a unit-amplitude
        //    waveform, so its harmonic ratios do not depend on level.
        let levelCoeff =
            bandAbs > primeBassLevelEnv ? primeBassLevelAttackCoeff : primeBassLevelReleaseCoeff
        primeBassLevelEnv = zapDenorm(
            (levelCoeff * primeBassLevelEnv) + ((1.0 - levelCoeff) * bandAbs))
        let env = max(Self.primeBassLevelFloor, primeBassLevelEnv)
        // Below the floor the band is divided by the floor instead, so the
        // harmonics fade quadratically into silence: no gate step.
        let x = clampf(band / env, -Self.primeBassNormClamp, Self.primeBassNormClamp)

        // 3. Harmonic device: even (2nd) and odd (3rd, 5th ...) parts,
        //    balanced by `harmonics`.
        let even = 2.0 * x * x
        let odd = (tanhf(primeBassOddDrive * x) - (primeBassOddFundamental * x)) * primeBassOddThirdInv
        let evenWeight = 1.0 - (0.55 * harmonics)
        let oddWeight = 0.25 + (0.75 * harmonics)
        let shaped = (evenWeight * even) + (oddWeight * odd)

        // 4. Werrbach transient-discriminate gain (US 5,424,488) on the
        //    band: fast (5 / 30 ms) vs slow (50 / 250 ms) follower, the
        //    normalised difference maps 0.7 (sustain) .. 1.4 (onset).
        let fastCoeff =
            bandAbs > primeBassFastEnv ? primeBassFastAttackCoeff : primeBassFastReleaseCoeff
        primeBassFastEnv = zapDenorm(
            (fastCoeff * primeBassFastEnv) + ((1.0 - fastCoeff) * bandAbs))
        let slowCoeff =
            bandAbs > primeBassSlowEnv ? primeBassSlowAttackCoeff : primeBassSlowReleaseCoeff
        primeBassSlowEnv = zapDenorm(
            (slowCoeff * primeBassSlowEnv) + ((1.0 - slowCoeff) * bandAbs))
        let transientDrive = clampf(
            (primeBassFastEnv - primeBassSlowEnv) / max(1e-3, primeBassSlowEnv),
            0.0,
            1.0
        )
        let transientGain =
            Self.primeBassTransientFloor
            + (transientDrive * (Self.primeBassTransientPeak - Self.primeBassTransientFloor))
        primeBassTransientGainObserved = transientGain

        // 5. Level law. `amount` sets the series level relative to the
        //    fundamental (x is unit, env is the fundamental's peak);
        //    `density` adds a bounded upward compression so quiet bass
        //    keeps its harmonic layer (gain FALLS with level, never rises:
        //    Big Bottom's law, review finding 5).
        let compression = clampf(powf(0.1 / env, 0.12 * density), 1.0, 2.0)
        //    Below the normaliser floor the band is no longer unit and the
        //    tanh device's small-signal linear term (d - b1) x would leak a
        //    copy of whatever reaches it (a 1 kHz tone through the input
        //    lowpass' numeric floor); fade the series out continuously
        //    with the envelope instead -- a slope, not a gate.
        let floorFade = min(1.0, primeBassLevelEnv / Self.primeBassLevelFloor)
        let harmonicLevel = amount * 3.2 * transientGain * compression * floorFade
        var enhancement =
            primeBassOutLPF.process(primeBassOutHPF.process(shaped)) * env * harmonicLevel

        // 6. Subharmonic octave divider (off by default). Square wave at
        //    half the band's zero-crossing rate, scaled by the same
        //    envelope, band-limited to its own fundamental. Below the
        //    normaliser floor the band is the input filters' rounding
        //    noise, whose crossings would free-run the divider as a random
        //    telegraph signal (measured -85 dB on a lone 1 kHz tone): hold
        //    the phase there, and fade the wave out with the envelope.
        if subAmount > 1e-4 {
            if primeBassLevelEnv > Self.primeBassLevelFloor, primeBassSubPrevSample <= 0.0, band > 0.0 {
                primeBassSubPhase ^= 1
            }
            primeBassSubPrevSample = band
            let square: Float = primeBassSubPhase == 0 ? -1.0 : 1.0
            let subWave = primeBassSubLPF.process(square * primeBassLevelEnv * floorFade)
            enhancement += subWave * subAmount * 1.2
        }

        // 7. Envelope-based peak guard (+1.5 dB max). Compares the smoothed
        //    peak of what the output WOULD be at full gain with the dry
        //    peak and scales the enhancement down smoothly; the Bass
        //    Clipper after the stage handles the rest, as it does for the
        //    broadcast processors.
        //    Peak-hold followers (instant attack, 100 ms release): a
        //    finite attack under-reads the sharper wet peaks and lets the
        //    growth through (measured 1.6-2.1 dB at 1 ms).
        primeBassDryPeakEnv = zapDenorm(max(fabsf(mid), primeBassDryPeakEnv * primeBassPeakReleaseCoeff))
        primeBassWetPeakEnv = zapDenorm(
            max(fabsf(mid + enhancement), primeBassWetPeakEnv * primeBassPeakReleaseCoeff))
        let allowedPeak = primeBassDryPeakEnv * Self.primeBassPeakGrowthMax
        var guardTarget: Float = 1.0
        if primeBassWetPeakEnv > allowedPeak {
            let added = primeBassWetPeakEnv - primeBassDryPeakEnv
            guardTarget = added > 1e-9
                ? clampf((allowedPeak - primeBassDryPeakEnv) / added, 0.0, 1.0) : 1.0
        }
        let guardCoeff =
            guardTarget < primeBassGuardGain ? primeBassGuardAttackCoeff : primeBassGuardReleaseCoeff
        primeBassGuardGain = (guardCoeff * primeBassGuardGain) + ((1.0 - guardCoeff) * guardTarget)

        // The DC blocker sits AFTER the guard gain: the gain's residual
        // ripple within a bass cycle is correlated with the waveform it
        // multiplies, which rectifies a little DC (-65 dBFS measured with
        // the subharmonic on); (1 - z^-1) removes it exactly.
        // Direct path is dry: no boost, no gain reduction, no delay (the
        // harmonic path carries no fundamental, so there is nothing to
        // comb against; measured in PrimeBassMaxxBassTests).
        let midOut = mid + primeBassDCBlock.process(enhancement * primeBassGuardGain)
        return (midOut + side, midOut - side)
    }

    private func processMultibandStereo(left: Float, right: Float) -> (Float, Float) {
        if multibandMode == 5 {
            return processFiveBandMultiband(left: left, right: right)
        }
        return processThreeBandMultiband(left: left, right: right)
    }

    private func processThreeBandMultiband(left: Float, right: Float) -> (Float, Float) {
        let lowBandL: Float, lowBandR: Float
        let midBandL: Float, midBandR: Float
        let highBandL: Float, highBandR: Float

        if useMultibandFIR {
            // Linear-phase FIR splitter — all 3 bands time-aligned at exit.
            let bands = mb3FIRSplitter.process(left: left, right: right)
            lowBandL = bands.0.0; lowBandR = bands.0.1
            midBandL = bands.1.0; midBandR = bands.1.1
            highBandL = bands.2.0; highBandR = bands.2.1
        } else {
            // Allpass-compensated LR4 tree -- low latency; the bands sum to
            // AP1 AP2 (flat magnitude, per-crossover phase rotation).
            let bands = mb3IIRSplitter.process(left: left, right: right)
            lowBandL = bands.0.0; lowBandR = bands.0.1
            midBandL = bands.1.0; midBandR = bands.1.1
            highBandL = bands.2.0; highBandR = bands.2.1
        }

        var lowOut = compressStereoBand(
            left: lowBandL,
            right: lowBandR,
            leftComp: &mbLowCompL,
            rightComp: &mbLowCompR
        )
        let couplingGR = updateMultibandCouplingGainReduction(Self.bandGainReductionDB(
            mbLowCompL,
            mbLowCompR
        ))
        let couplingBias = Self.multibandCouplingBiases(lowGainReductionDB: couplingGR)
        var midOut = compressStereoBand(
            left: midBandL,
            right: midBandR,
            leftComp: &mbMidCompL,
            rightComp: &mbMidCompR,
            thresholdBiasDB: couplingBias.mid
        )
        var highOut = compressStereoBand(
            left: highBandL,
            right: highBandR,
            leftComp: &mbHighCompL,
            rightComp: &mbHighCompR,
            thresholdBiasDB: couplingBias.high
        )

        // Per-band downward expander (noise reduction)
        if downwardExpanderEnabled {
            let lowExpGain = mbExpLow.expanderGain(left: lowOut.0, right: lowOut.1)
            lowOut = (lowOut.0 * lowExpGain, lowOut.1 * lowExpGain)
            let midExpGain = mbExpMid.expanderGain(left: midOut.0, right: midOut.1)
            midOut = (midOut.0 * midExpGain, midOut.1 * midExpGain)
            let highExpGain = mbExpHigh.expanderGain(left: highOut.0, right: highOut.1)
            highOut = (highOut.0 * highExpGain, highOut.1 * highExpGain)
        }

        // Per-band fast peak limiter (transient control)
        if multibandLimiterEnabled {
            lowOut = mbLimLow.process(left: lowOut.0, right: lowOut.1)
            midOut = mbLimMid.process(left: midOut.0, right: midOut.1)
            highOut = mbLimHigh.process(left: highOut.0, right: highOut.1)
        }

        return Self.sumStereoBands(
            lowOut,
            midOut,
            highOut,
            makeup: multibandMakeup
        )
    }

    private func processFiveBandMultiband(left: Float, right: Float) -> (Float, Float) {
        let b1L: Float, b1R: Float
        let b2L: Float, b2R: Float
        let b3L: Float, b3R: Float
        let b4L: Float, b4R: Float
        let b5L: Float, b5R: Float

        if useMultibandFIR {
            let bands = mb5FIRSplitter.process(left: left, right: right)
            b1L = bands.0.0; b1R = bands.0.1
            b2L = bands.1.0; b2R = bands.1.1
            b3L = bands.2.0; b3R = bands.2.1
            b4L = bands.3.0; b4R = bands.3.1
            b5L = bands.4.0; b5R = bands.4.1
        } else {
            // Allpass-compensated LR4 tree: the bands sum to AP1..AP4.
            let bands = mb5IIRSplitter.process(left: left, right: right)
            b1L = bands.0.0; b1R = bands.0.1
            b2L = bands.1.0; b2R = bands.1.1
            b3L = bands.2.0; b3R = bands.2.1
            b4L = bands.3.0; b4R = bands.3.1
            b5L = bands.4.0; b5R = bands.4.1
        }

        var o1 = compressStereoBand(
            left: b1L, right: b1R, leftComp: &mb5Comp1L, rightComp: &mb5Comp1R)
        let couplingGR = updateMultibandCouplingGainReduction(Self.bandGainReductionDB(
            mb5Comp1L,
            mb5Comp1R
        ))
        let couplingBias = Self.multibandFiveBandCouplingBiases(lowGainReductionDB: couplingGR)
        var o2 = compressStereoBand(
            left: b2L, right: b2R, leftComp: &mb5Comp2L, rightComp: &mb5Comp2R,
            thresholdBiasDB: couplingBias.b2)
        var o3 = compressStereoBand(
            left: b3L, right: b3R, leftComp: &mb5Comp3L, rightComp: &mb5Comp3R,
            thresholdBiasDB: couplingBias.b3)
        var o4 = compressStereoBand(
            left: b4L, right: b4R, leftComp: &mb5Comp4L, rightComp: &mb5Comp4R,
            thresholdBiasDB: couplingBias.b4)
        var o5 = compressStereoBand(
            left: b5L, right: b5R, leftComp: &mb5Comp5L, rightComp: &mb5Comp5R,
            thresholdBiasDB: couplingBias.b5)

        // Per-band downward expander (noise reduction)
        if downwardExpanderEnabled {
            let g1 = mbExp5B1.expanderGain(left: o1.0, right: o1.1)
            o1 = (o1.0 * g1, o1.1 * g1)
            let g2 = mbExp5B2.expanderGain(left: o2.0, right: o2.1)
            o2 = (o2.0 * g2, o2.1 * g2)
            let g3 = mbExp5B3.expanderGain(left: o3.0, right: o3.1)
            o3 = (o3.0 * g3, o3.1 * g3)
            let g4 = mbExp5B4.expanderGain(left: o4.0, right: o4.1)
            o4 = (o4.0 * g4, o4.1 * g4)
            let g5 = mbExp5B5.expanderGain(left: o5.0, right: o5.1)
            o5 = (o5.0 * g5, o5.1 * g5)
        }

        // Per-band fast peak limiter (transient control)
        if multibandLimiterEnabled {
            o1 = mbLim5B1.process(left: o1.0, right: o1.1)
            o2 = mbLim5B2.process(left: o2.0, right: o2.1)
            o3 = mbLim5B3.process(left: o3.0, right: o3.1)
            o4 = mbLim5B4.process(left: o4.0, right: o4.1)
            o5 = mbLim5B5.process(left: o5.0, right: o5.1)
        }

        return Self.sumStereoBands(
            o1,
            o2,
            o3,
            o4,
            o5,
            makeup: multibandMakeup
        )
    }

    private func compressStereoBand(
        left: Float,
        right: Float,
        leftComp: inout MonoCompressor,
        rightComp: inout MonoCompressor,
        thresholdBiasDB: Float = 0.0
    ) -> (Float, Float) {
        let absL = fabsf(left)
        let absR = fabsf(right)
        if multibandLinkStrength > 1e-4 {
            // Stereo link as an amount: each channel's detector blends from
            // its own |x| (0) to the shared linked level (1, equal L/R gain
            // reduction, image held exactly).
            let sc = MultibandStereoLink.sidechains(
                absLeft: absL, absRight: absR, amount: multibandLinkStrength)
            return (
                leftComp.process(left, sidechainAbs: sc.left, thresholdBiasDB: thresholdBiasDB),
                rightComp.process(right, sidechainAbs: sc.right, thresholdBiasDB: thresholdBiasDB)
            )
        }
        return (
            leftComp.process(left, thresholdBiasDB: thresholdBiasDB),
            rightComp.process(right, thresholdBiasDB: thresholdBiasDB)
        )
    }

    @inline(__always)
    private static func bandGainReductionDB(_ left: MonoCompressor, _ right: MonoCompressor) -> Float {
        max(0.0, max(-left.lastGainReductionDB, -right.lastGainReductionDB))
    }

    @inline(__always)
    private static func sumStereoBands(
        _ a: (Float, Float),
        _ b: (Float, Float),
        _ c: (Float, Float),
        makeup: Float
    ) -> (Float, Float) {
        ((a.0 + b.0 + c.0) * makeup, (a.1 + b.1 + c.1) * makeup)
    }

    @inline(__always)
    private static func sumStereoBands(
        _ a: (Float, Float),
        _ b: (Float, Float),
        _ c: (Float, Float),
        _ d: (Float, Float),
        _ e: (Float, Float),
        makeup: Float
    ) -> (Float, Float) {
        ((a.0 + b.0 + c.0 + d.0 + e.0) * makeup, (a.1 + b.1 + c.1 + d.1 + e.1) * makeup)
    }

    /// The 1x budget safety net behind the composite clipper and the final
    /// limiter: the `BandWaveshaper` soft knee, with its asymptote AT the
    /// budget (`threshold`). Below `kneeStart x threshold` it is the identity;
    /// above, the excess is compressed by a tanh scaled to the remaining
    /// headroom, continuous in value and slope, so no input can leave above
    /// the budget. Until 2026-10 the curve mapped the budget to `budget +
    /// margin` (0.012 at a 0.85 budget, slope 1.18 at the join): any input
    /// over the budget left over it, the governor behind hard-clamped it and
    /// started its 1 ms / 120 ms ride -- a 1x hard clip plus a programme dip
    /// whenever the shaper engaged (peak-control review F11). With the
    /// limiter holding the budget, the knee touches limited crests by at most
    /// 0.02 dB; the shaper's job is the impossible configurations.
    static let softClipSafetyKneeStart: Float = 0.99

    static func softClipSafety(_ x: Float, threshold: Float) -> Float {
        let thr = clampf(threshold, 0.001, 0.999)
        let x0 = thr * softClipSafetyKneeStart
        let ax = fabsf(x)
        if ax <= x0 {
            return x
        }
        let width = max(1e-6, thr - x0)
        let clipped = min(thr, x0 + (width * tanhf((ax - x0) / width)))
        return copysignf(clipped, x)
    }
}
