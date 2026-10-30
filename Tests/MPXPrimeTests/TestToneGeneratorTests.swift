import Testing
import Foundation
@testable import MPXPrime

// Tests for the test-tone generator (sine / pink / white) introduced
// alongside the Test Tone sidebar tab. Covers AppConfig defaults +
// clamps + INI roundtrip, plus end-to-end render-amplitude checks
// through a mono-mode minimal-chain MPXGenerator (same pattern the
// PrimeBass tests use to isolate one stage from chain noise).

@Suite("Test tone generator")
struct TestToneGeneratorTests {

    private let sampleRate: Float = 192_000.0
    private let warmupFrames: Int = 4_096
    private let measureFrames: Int = 16_384

    // MARK: - AppConfig

    @Test func defaultsAreBroadcastReference() {
        let cfg = AppConfig()
        #expect(cfg.testToneFreq == 1000.0,
            "Default test tone frequency should be 1 kHz (broadcast standard); got \(cfg.testToneFreq)")
        #expect(cfg.testToneMode == "mono",
            "Default test tone mode should be mono; got \(cfg.testToneMode)")
        #expect(cfg.testToneType == "sine",
            "Default test tone type should be sine; got \(cfg.testToneType)")
        #expect(cfg.testToneLevelDB == -20.0,
            "Default test tone level should be −20 dBFS (broadcast line reference); got \(cfg.testToneLevelDB)")
    }

    @Test func levelClampsToValidRange() {
        var cfg = AppConfig()
        cfg.testToneLevelDB = -200.0
        cfg.validate()
        #expect(cfg.testToneLevelDB == -60.0,
            "−200 should clamp to −60 (lower bound); got \(cfg.testToneLevelDB)")

        cfg.testToneLevelDB = 30.0
        cfg.validate()
        #expect(cfg.testToneLevelDB == 0.0,
            "+30 should clamp to 0 (upper bound); got \(cfg.testToneLevelDB)")
    }

    @Test func typeFallsBackToSineOnInvalid() {
        var cfg = AppConfig()
        cfg.testToneType = "garbage"
        cfg.validate()
        #expect(cfg.testToneType == "sine",
            "Invalid type should fall back to sine; got \(cfg.testToneType)")
    }

    @Test func modeFallsBackToMonoOnInvalid() {
        var cfg = AppConfig()
        cfg.testToneMode = "quadraphonic"
        cfg.validate()
        #expect(cfg.testToneMode == "mono",
            "Invalid mode should fall back to mono; got \(cfg.testToneMode)")
    }

    // MARK: - End-to-end amplitude

    /// Build a config that's transparent to the tone except for the
    /// stereo encoder + final-MPX safety limiter, so the rendered
    /// composite reads back near the input amplitude. Mirrors the
    /// pattern used in `PrimeBassMaxxBassTests.makeMinimalChainConfig`.
    private func makeMinimalToneConfig(
        levelDB: Double = -20.0,
        toneType: String = "sine",
        toneFreq: Double = 1000.0
    ) -> AppConfig {
        var cfg = AppConfig()
        cfg.sampleRate = Double(sampleRate)
        cfg.blockSize = 512
        cfg.sourceMode = "tone"
        cfg.monitorEnabled = false
        cfg.monoMode = true   // strip pilot / stereo / RDS so composite ≈ baseband mono
        cfg.processingBypass = true   // bypass AGC / multiband / clippers / limiters
        cfg.preemphasisUS = 0
        cfg.limitMPX = false
        cfg.preEncodeAudioLimiterEnabled = false
        cfg.audioCompositeSoftClipEnabled = false
        cfg.encoderFIREnabled = false
        cfg.widebandAGCEnabled = false
        cfg.advancedDynamicsEnabled = false  // AD is the default levelling since 2026-10-15
        cfg.phaseRotationEnabled = false
        cfg.parametricEQEnabled = false
        cfg.primeBassEnabled = false
        cfg.monoBassEnabled = false
        cfg.multibandEnabled = false
        cfg.multibandLimiterEnabled = false
        cfg.bassClipperEnabled = false
        cfg.dcClipperEnabled = false
        cfg.bs412Enabled = false
        cfg.compositeClipperEnabled = false
        cfg.enRDS = false
        cfg.rdsNowPlayingEnabled = false
        cfg.programLowpassHz = 19_000.0
        // Zero post-encode drive / output gain so the composite reads
        // back the calibrated input level. AppConfig defaults
        // finalDriveDB to 6 dB which would otherwise add 6 dB to every
        // peak measurement.
        cfg.finalDriveDB = 0.0
        cfg.outputGainDB = 0.0
        cfg.inputGainDB = 0.0
        cfg.testToneType = toneType
        cfg.testToneFreq = toneFreq
        cfg.testToneLevelDB = levelDB
        cfg.testToneMode = "mono"
        return cfg
    }

    private func renderTone(config: AppConfig, frames: Int) -> [Float] {
        let gen = MPXGenerator(config: config, sampleRate: Double(sampleRate))
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        var mpxLeft = [Float](repeating: 0.0, count: frames)
        var mpxRight = [Float](repeating: 0.0, count: frames)
        left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                mpxLeft.withUnsafeMutableBufferPointer { mlBuf in
                    mpxRight.withUnsafeMutableBufferPointer { mrBuf in
                        gen.renderToneAndMonitorNonInterleaved(
                            frameCount: frames,
                            left: lBuf.baseAddress!,
                            right: rBuf.baseAddress!,
                            mpxLeft: mlBuf.baseAddress!,
                            mpxRight: mrBuf.baseAddress!
                        )
                    }
                }
            }
        }
        return mpxLeft  // composite (mono — both channels identical in mono mode)
    }

    @Test func sineAtMinus20dBFSRendersAtCalibratedLevel() {
        // Render a 1 kHz sine at −20 dBFS through the minimal mono
        // chain. With processingBypass + monoMode + no clippers /
        // limiters / encoder FIR, the composite output should reflect
        // the input tone amplitude (~0.1 linear = −20 dBFS) within
        // small tolerance for sumLevel scaling and the encoder pre-
        // emphasis biquads (which run even with preemphasisUS = 0,
        // and pass through near-flat in that case).
        let cfg = makeMinimalToneConfig(levelDB: -20.0, toneType: "sine", toneFreq: 1000.0)
        let totalFrames = warmupFrames + measureFrames
        let composite = renderTone(config: cfg, frames: totalFrames)

        // Skip warmup; measure peak amplitude over the steady state.
        var peak: Float = 0.0
        for i in warmupFrames..<totalFrames {
            let v = abs(composite[i])
            if v > peak { peak = v }
        }

        // Expected: ~0.1 (−20 dBFS). Tolerance ±3 dB to absorb sumLevel
        // (1.0 default), encoder pre-emphasis biquad pass-through, and
        // the chain's other always-on stages (programLP, inputHPF) at
        // 1 kHz which sit firmly in passband.
        let peakDB = 20.0 * log10f(max(peak, 1e-9))
        #expect(peakDB > -23.0,
            "Composite peak for −20 dBFS sine should be ≥ −23 dBFS; got \(peakDB)")
        #expect(peakDB < -17.0,
            "Composite peak for −20 dBFS sine should be ≤ −17 dBFS; got \(peakDB)")
    }

    @Test func sineAtMinus40dBFSRendersAtCalibratedLevel() {
        // Same chain, lower level. Verifies the level scaling is
        // linear-in-dB and not stuck at full-scale (the pre-fix
        // behaviour where tone was always rendered at amplitude 1.0).
        let cfg = makeMinimalToneConfig(levelDB: -40.0, toneType: "sine", toneFreq: 1000.0)
        let composite = renderTone(config: cfg, frames: warmupFrames + measureFrames)
        var peak: Float = 0.0
        for i in warmupFrames..<composite.count {
            let v = abs(composite[i])
            if v > peak { peak = v }
        }
        let peakDB = 20.0 * log10f(max(peak, 1e-9))
        #expect(peakDB > -43.0 && peakDB < -37.0,
            "Composite peak for −40 dBFS sine should be in [−43, −37] dBFS; got \(peakDB)")
    }

    /// Peak, RMS and distinct-value count over the whole measurement window.
    private func noiseStats(_ composite: [Float]) -> (peak: Float, rms: Double, distinct: Int) {
        var peak: Float = 0.0
        var acc = 0.0
        var distinctSamples = Set<Int32>()
        for i in warmupFrames..<composite.count {
            peak = max(peak, abs(composite[i]))
            acc += Double(composite[i]) * Double(composite[i])
            if distinctSamples.count <= 100 { distinctSamples.insert(Int32(composite[i] * 10_000.0)) }
        }
        return (peak, sqrt(acc / Double(composite.count - warmupFrames)), distinctSamples.count)
    }

    /// White and pink noise: random, bounded, AND at the configured level.
    /// The old checks (peak under 0.2 / 0.3, over a window that stopped
    /// after 100 distinct values) passed noise 40 dB low
    /// (test-suite review 2026-10 finding 13). The level is pinned
    /// two ways: the RMS at -20 dBFS is not tens of dB down (40 dB low reads
    /// about 5e-4), and -20 vs -40 dBFS differ by 20 dB.
    @Test(arguments: [("white", Float(0.2)), ("pink", Float(0.3))])
    func noiseProducesBoundedRandomOutputAtItsLevel(toneType: String, peakBound: Float) {
        let hot = noiseStats(renderTone(config: makeMinimalToneConfig(levelDB: -20.0, toneType: toneType),
                                        frames: warmupFrames + measureFrames))
        let quiet = noiseStats(renderTone(config: makeMinimalToneConfig(levelDB: -40.0, toneType: toneType),
                                          frames: warmupFrames + measureFrames))
        let stepDB = 20.0 * log10(hot.rms / max(quiet.rms, 1e-12))
        print(String(format: "[tone noise] %@: -20 dBFS RMS %.4f peak %.3f, -40 dBFS RMS %.5f, step %.2f dB",
                     toneType, hot.rms, hot.peak, quiet.rms, stepDB))
        #expect(hot.distinct > 50,
            "\(toneType) noise should produce many distinct values; got \(hot.distinct)")
        // Uniform [-1, +1] scaled by 0.1 peaks at 0.1; headroom for the
        // pre-emphasis biquad and sumLevel.
        #expect(hot.peak < peakBound,
            "\(toneType) noise peak at -20 dBFS should be bounded under \(peakBound); got \(hot.peak)")
        #expect(hot.rms > 0.01,
            "\(toneType) noise at -20 dBFS has RMS \(hot.rms): far below its level")
        #expect(abs(stepDB - 20.0) < 1.0,
            "\(toneType) noise -20 vs -40 dBFS differ by \(stepDB) dB, not 20")
    }

    // MARK: - Calibration semantics (0.45)

    /// The shipped default chain -- AGC, multiband, HF limiter, pre-encode
    /// limiter, composite clipper at 6 dB drive, final limiter -- all ON.
    /// Pilot and RDS are switched off so the composite is the audio alone
    /// and the budget is exactly `limit_threshold` 1.0 - 0.005 margin = 0.995
    /// (0.98 - 0.02 = 0.96 until the 2026-10 budget overhaul removed the
    /// duplicated static headroom).
    private func makeFullChainToneConfig(levelDB: Double, toneFreq: Double = 1_000.0,
                                         mode: String = "mono", type: String = "sine") -> AppConfig {
        var cfg = AppConfig()
        cfg.sampleRate = Double(sampleRate)
        cfg.blockSize = 512
        cfg.sourceMode = "tone"
        cfg.monitorEnabled = false
        cfg.pilotLevel = 0.0
        cfg.enRDS = false
        cfg.rdsNowPlayingEnabled = false
        cfg.testToneType = type
        cfg.testToneFreq = toneFreq
        cfg.testToneLevelDB = levelDB
        cfg.testToneMode = mode
        return cfg
    }

    private func steadyStatePeakDB(_ cfg: AppConfig) -> Float {
        let settle = 38_400   // 0.2 s: dual-rate boundary, FIR and look-ahead delays
        let composite = renderTone(config: cfg, frames: settle + measureFrames)
        var peak: Float = 0.0
        for i in settle..<composite.count { peak = max(peak, abs(composite[i])) }
        return 20.0 * log10f(max(peak, 1e-9))
    }

    /// 0 dBFS = the audio-composite budget (0.995 here, -0.04 dBFS), and the
    /// scale is linear in dB: -20 dBFS lands at -20.04 dBFS on the composite.
    @Test func fullChainToneLevelIsCalibratedToTheBudget() {
        let budgetDB = 20.0 * log10f(0.995)
        for levelDB in [0.0, -6.0, -20.0, -40.0] {
            let peakDB = steadyStatePeakDB(makeFullChainToneConfig(levelDB: levelDB))
            let expected = budgetDB + Float(levelDB)
            #expect(abs(peakDB - expected) < 0.25,
                    "tone at \(levelDB) dBFS: composite peak \(peakDB) dBFS, expected \(expected)")
        }
    }

    /// The tone is a calibration source: AGC target, Final Drive and the
    /// processing stages must not move it (the pre-0.45 behaviour was the
    /// opposite -- any level produced full, clipped deviation).
    @Test func toneLevelIsIndependentOfDriveAndProcessing() {
        let reference = steadyStatePeakDB(makeFullChainToneConfig(levelDB: -12.0))
        var loud = makeFullChainToneConfig(levelDB: -12.0)
        loud.finalDriveDB = 12.0
        loud.widebandAGCTargetDB = -6.0
        loud.inputGainDB = 10.0
        var lean = makeFullChainToneConfig(levelDB: -12.0)
        lean.finalDriveDB = 0.0
        lean.compositeClipperEnabled = false
        lean.preEncodeAudioLimiterEnabled = false
        lean.multibandEnabled = false
        lean.widebandAGCEnabled = false
        lean.advancedDynamicsEnabled = false  // AD is the default levelling since 2026-10-15
        #expect(abs(steadyStatePeakDB(loud) - reference) < 0.05)
        #expect(abs(steadyStatePeakDB(lean) - reference) < 0.05)
    }

    /// Pre-emphasis compensation: a sine reads the same composite level at
    /// 1 kHz and 10 kHz (50 us would otherwise add ~10 dB at 10 kHz).
    @Test func sineLevelIsFlatAcrossFrequencyDespitePreemphasis() {
        let at1k = steadyStatePeakDB(makeFullChainToneConfig(levelDB: -12.0, toneFreq: 1_000.0))
        let at10k = steadyStatePeakDB(makeFullChainToneConfig(levelDB: -12.0, toneFreq: 10_000.0))
        let at400 = steadyStatePeakDB(makeFullChainToneConfig(levelDB: -12.0, toneFreq: 400.0))
        #expect(abs(at10k - at1k) < 0.3, "1 kHz \(at1k) vs 10 kHz \(at10k)")
        #expect(abs(at400 - at1k) < 0.3, "1 kHz \(at1k) vs 400 Hz \(at400)")
    }

    /// Mono, left-only and L=-R routing all peak the composite at the same
    /// level (M + S reaches the same envelope for a single-channel source).
    /// 997 Hz, not 1 kHz: 1 kHz and the 38 kHz subcarrier are both exact
    /// divisors of 192 kHz, so that composite repeats every 192 samples and
    /// its SAMPLED peak depends on which grid sample lands on the envelope
    /// maximum (a subcarrier polarity flip alone moved it 0.4 dB). An
    /// incommensurate tone sweeps every alignment inside the window.
    @Test func routingModesHitTheSameCompositePeak() {
        let f = 997.0
        let mono = steadyStatePeakDB(makeFullChainToneConfig(levelDB: -12.0, toneFreq: f, mode: "mono"))
        let left = steadyStatePeakDB(makeFullChainToneConfig(levelDB: -12.0, toneFreq: f, mode: "left"))
        let stereo = steadyStatePeakDB(makeFullChainToneConfig(levelDB: -12.0, toneFreq: f, mode: "stereo"))
        #expect(abs(left - mono) < 0.3, "mono \(mono) vs left \(left)")
        #expect(abs(stereo - mono) < 0.3, "mono \(mono) vs L=-R \(stereo)")
    }

    /// The live-input path is untouched by the tone semantics: with the
    /// source set to input, the chain still processes program normally.
    @Test func inputPathStillProcesses() {
        var cfg = makeFullChainToneConfig(levelDB: 0.0)
        cfg.sourceMode = "input"
        let gen = MPXGenerator(config: cfg, sampleRate: Double(sampleRate))
        var peakA: Float = 0.0
        var peakB: Float = 0.0
        // Same -12 dBFS sine fed as INPUT through two drives: the processed
        // path must respond to Final Drive (the calibration path must not).
        for drive in [0.0, 12.0] {
            var c = cfg; c.finalDriveDB = drive
            let g = MPXGenerator(config: c, sampleRate: Double(sampleRate))
            var peak: Float = 0.0
            for n in 0..<(38_400 + measureFrames) {
                let x = 0.25 * sinf(2.0 * Float.pi * 1_000.0 * Float(n) / sampleRate)
                let y = g.renderSingleSample(leftIn: x, rightIn: x)
                if n >= 38_400 { peak = max(peak, abs(y)) }
            }
            if drive == 0.0 { peakA = peak } else { peakB = peak }
        }
        _ = gen
        #expect(peakB > peakA * 1.05, "input path ignored Final Drive: \(peakA) vs \(peakB)")
    }
}
