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
        cfg.phaseRotationEnabled = false
        cfg.parametricEQEnabled = false
        cfg.primeBassEnabled = false
        cfg.stereoWidenEnabled = false
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

    @Test func whiteNoiseProducesBoundedRandomOutput() {
        // White noise should fill the buffer with non-trivial random
        // content. Verify: not constant (more than just one value
        // present), bounded by ~level (peak no more than 6 dB above
        // configured level — uniform [-1,+1] white scaled by toneLevel).
        let cfg = makeMinimalToneConfig(levelDB: -20.0, toneType: "white")
        let composite = renderTone(config: cfg, frames: warmupFrames + measureFrames)

        var peak: Float = 0.0
        var distinctSamples = Set<Int32>()
        for i in warmupFrames..<composite.count {
            let v = abs(composite[i])
            if v > peak { peak = v }
            // Count distinct quantised samples to verify it's not stuck
            distinctSamples.insert(Int32(composite[i] * 10_000.0))
            if distinctSamples.count > 100 { break }
        }
        #expect(distinctSamples.count > 50,
            "White noise should produce many distinct values; got \(distinctSamples.count) in window")
        // Peak amplitude bounded — uniform [-1,+1] scaled by 0.1 = peaks
        // up to 0.1; small headroom for chain-side pre-emphasis biquad
        // and sumLevel.
        #expect(peak < 0.2,
            "White noise peak at −20 dBFS should be bounded under 0.2; got \(peak)")
    }

    @Test func pinkNoiseProducesBoundedRandomOutput() {
        // Pink noise: similar constraints. The Paul Kellet recipe is
        // scaled to ~±1 in our wrapper so −20 dBFS pink should peak
        // under ~0.2.
        let cfg = makeMinimalToneConfig(levelDB: -20.0, toneType: "pink")
        let composite = renderTone(config: cfg, frames: warmupFrames + measureFrames)

        var peak: Float = 0.0
        var distinctSamples = Set<Int32>()
        for i in warmupFrames..<composite.count {
            let v = abs(composite[i])
            if v > peak { peak = v }
            distinctSamples.insert(Int32(composite[i] * 10_000.0))
            if distinctSamples.count > 100 { break }
        }
        #expect(distinctSamples.count > 50,
            "Pink noise should produce many distinct values; got \(distinctSamples.count) in window")
        #expect(peak < 0.3,
            "Pink noise peak at −20 dBFS should be bounded under 0.3; got \(peak)")
    }
}
