import Testing
import Foundation
@testable import MPXPrime

// Regression guard for the audit finding that pilot/RDS injection was
// not delay-aligned with the audio composite. Composite-clipper FIR
// group delay and the final MPX limiter's look-ahead window delay the
// stereo subcarrier (embedded in `audioComposite`) by ~Δ samples, but
// pilot/RDS were being added with the current oscillator phase — so
// receiver-side stereo demod (using a pilot-locked 38 kHz reference)
// recovered L-R amplitude scaled by cos(2Δ·Δφ_19k), a 5-10 dB loss at
// default config.
//
// These tests validate the fix at two levels:
// 1. recomputeSubcarrierDelay sizes the delay line to match the total
//    audio-path delay (algorithmic correctness).
// 2. The full chain (composite clipper on, 5 ms final look-ahead) decodes
//    with real stereo separation on a textbook receiver that shares no
//    code with the encoder: pilot phase from the 19 kHz projection,
//    38 kHz reference sin(2(theta + phi)), L = M + S. A pilot misaligned
//    against the subcarrier embedded in the audio composite shows up
//    directly as lost (or inverted) separation.
//
// The old tests 2 and 3 only showed that the output with the delay
// differed from the output without it, and test 1 reads the same reported
// latencies that recomputeSubcarrierDelay adds up: with `+ 2` samples
// (about 142 deg at 38 kHz) added to the delay, all of them stayed green
// (test-suite review 2026-10 finding 4).

@Suite("Subcarrier delay alignment")
struct StereoSeparationReceiverTests {

    private let sampleRate: Double = 192_000.0
    private let audioToneHz: Double = 1_000.0

    private func makeStereoConfig() -> AppConfig {
        var cfg = AppConfig()
        cfg.sampleRate = sampleRate
        cfg.blockSize = 1024
        cfg.processingBypass = false
        cfg.compositeClipperEnabled = true
        cfg.compositeClipperLookaheadMS = 0.0
        cfg.limitMPX = true
        cfg.limitLookaheadMS = 5.0
        cfg.widebandAGCEnabled = false
        cfg.advancedDynamicsEnabled = false  // AD is the default levelling since 2026-10-15
        cfg.multibandEnabled = false
        cfg.multibandLimiterEnabled = false
        cfg.downwardExpanderEnabled = false
        cfg.primeBassEnabled = false
        cfg.monoBassEnabled = false
        cfg.phaseRotationEnabled = false
        cfg.parametricEQEnabled = false
        cfg.bassClipperEnabled = false
        cfg.dcClipperEnabled = false
        cfg.bs412Enabled = false
        cfg.preEncodeAudioLimiterEnabled = true
        cfg.preEncodeThreshold = 0.95
        cfg.preEncodeReleaseMS = 50.0
        cfg.preemphasisUS = 0
        cfg.enRDS = false
        cfg.monoMode = false
        cfg.pilotLevel = 0.08
        return cfg
    }

    private func renderMPX(amplitude: Float, seconds: Double,
                          disableSubcarrierDelay: Bool) -> [Float] {
        let cfg = makeStereoConfig()
        let gen = MPXGenerator(config: cfg, sampleRate: sampleRate)
        if disableSubcarrierDelay {
            // Emulate the pre-fix code path (no subcarrier delay).
            gen.subcarrierDelayActiveCount = 0
            gen.subcarrierDelayWriteIdx = 0
        }
        let frames = Int(sampleRate * seconds)
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        if amplitude > 0 {
            let w = 2.0 * Double.pi * audioToneHz / sampleRate
            for i in 0..<frames {
                // Hard-panned L for stereo-encode stress.
                left[i] = Float(Double(amplitude) * sin(w * Double(i)))
            }
        }
        left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                var offset = 0
                while offset < frames {
                    let chunk = min(1024, frames - offset)
                    gen.renderFromInputInPlace(
                        frameCount: chunk,
                        left: lBuf.baseAddress!.advanced(by: offset),
                        right: rBuf.baseAddress!.advanced(by: offset)
                    )
                    offset += chunk
                }
            }
        }
        return left
    }

    // MARK: - Test 1: algorithmic correctness of delay size

    @Test func subcarrierDelayLineSizeMatchesAudioPathDelay() {
        // With composite clipper enabled (lookaheadMS = 0 — only FIR
        // group delay) and final MPX lookahead at 5 ms, audio path
        // delay should be FIR_group_delay + audio-composite bandwidth
        // FIR group delay + lookahead_samples. At 192 kHz with default
        // decimator (~150 Kaiser-windowed taps at 8× OS = ~9 host
        // samples), audio-composite bandwidth FIR (~112 host samples),
        // and 5 ms lookahead (= 960 samples), the total is ~1081 samples.
        // Since the 2026-10 peak-control review (F3/F8/F9) the clipper adds
        // a 2x FIR interpolator and a padded decimator (25 samples together)
        // and its linear-phase guard-band FIR (140 samples with the default
        // pilot/stereo/RDS guards): ~1237 samples.
        let cfg = makeStereoConfig()
        let gen = MPXGenerator(config: cfg, sampleRate: sampleRate)
        let actual = gen.subcarrierDelayActiveCount
        print("[delay-size] subcarrierDelayLine.count = \(actual) (expected ≈1237)")
        #expect(actual > 1220 && actual < 1255,
            "subcarrier delay line size \(actual) outside expected ~1237-sample window (clipper + audio bandwidth FIR + lookahead)")
    }

    @Test func subcarrierDelayLineRespondsToCompositeClipperFlag() {
        // When composite clipper is disabled at config time, the
        // audio path through it is bypassed — recomputeSubcarrierDelay
        // should drop the decimator FIR group delay contribution from
        // the subcarrier delay total. (Audio-composite bandwidth FIR
        // and lookahead limiter contributions remain.)
        var cfg = makeStereoConfig()
        cfg.compositeClipperEnabled = false
        let gen = MPXGenerator(config: cfg, sampleRate: sampleRate)
        let actual = gen.subcarrierDelayActiveCount
        // Expected: 960 lookahead + ~112 audio bandwidth FIR = ~1072.
        print("[delay-size] composite clipper OFF, subcarrierDelayLine.count = \(actual) (expected ≈1072)")
        #expect(actual >= 1060 && actual <= 1085,
            "with composite clipper off, delay should be ~1072 (audio bandwidth FIR + lookahead); got \(actual)")
    }

    @Test func liveCompositeLookaheadResizeChangesActiveDelayWithoutGrowingStorage() {
        var cfg = makeStereoConfig()
        cfg.compositeClipperLookaheadMS = 0.0
        let gen = MPXGenerator(config: cfg, sampleRate: sampleRate)
        let initialCapacity = gen.subcarrierDelayLine.count
        let initialActive = gen.subcarrierDelayActiveCount

        cfg.compositeClipperLookaheadMS = 3.0
        gen.applyRuntimeConfig(MPXGenerator.makeRuntimeConfig(from: cfg))

        let resizedCapacity = gen.subcarrierDelayLine.count
        let resizedActive = gen.subcarrierDelayActiveCount
        let expectedDelta = Int(round(3.0 / 1000.0 * sampleRate))

        #expect(resizedCapacity == initialCapacity)
        #expect(resizedActive - initialActive == expectedDelta)

        cfg.compositeClipperLookaheadMS = 0.5
        gen.applyRuntimeConfig(MPXGenerator.makeRuntimeConfig(from: cfg))

        #expect(gen.subcarrierDelayLine.count == initialCapacity)
        #expect(gen.subcarrierDelayActiveCount - initialActive == Int(round(0.5 / 1000.0 * sampleRate)))
    }

    // MARK: - Test 2: receiver-side separation on the full chain

    /// Projection of `samples` (from `start`) onto sin/cos of `hz`.
    private func project(_ samples: [Float], hz: Double, start: Int) -> (sin: Double, cos: Double) {
        let omega = 2.0 * Double.pi * hz / sampleRate
        var s = 0.0, c = 0.0
        for i in start..<samples.count {
            let phase = omega * Double(i)
            s += Double(samples[i]) * sin(phase)
            c += Double(samples[i]) * cos(phase)
        }
        let scale = 2.0 / Double(samples.count - start)
        return (s * scale, c * scale)
    }

    /// Textbook receiver (the oracle of `StereoPolarityTests`): pilot phase
    /// from the 19 kHz projection of the composite, coherent 38 kHz
    /// reference at twice that phase, S = 2 * mpx * ref, L = M + S,
    /// R = M - S. Returns the recovered amplitude of `toneHz` per channel.
    private func textbookDecode(_ mpx: [Float], toneHz: Double, start: Int) -> (left: Double, right: Double) {
        let pilot = project(mpx, hz: 19_000.0, start: start)
        let phi = atan2(pilot.cos, pilot.sin)
        let pilotOmega = 2.0 * Double.pi * 19_000.0 / sampleRate
        var demod = [Float](repeating: 0.0, count: mpx.count)
        for i in start..<mpx.count {
            let ref = sin(2.0 * ((pilotOmega * Double(i)) + phi))
            demod[i] = Float(2.0 * Double(mpx[i]) * ref)
        }
        let m = project(mpx, hz: toneHz, start: start)
        let side = project(demod, hz: toneHz, start: start)
        return (hypot(m.sin + side.sin, m.cos + side.cos), hypot(m.sin - side.sin, m.cos - side.cos))
    }

    /// Hard-panned L tone through the file's full config (composite clipper
    /// on, 5 ms final look-ahead, pre-encode limiter on) and decoded on the
    /// textbook receiver. 1 kHz and 10 kHz: a fixed sample offset between
    /// pilot and subcarrier costs separation in proportion to frequency
    /// error at 38 kHz, so both must hold. 0.3 keeps the pre-encode
    /// limiter (threshold 0.95) idle: the measurement is alignment, not
    /// limiter IM.
    @Test(arguments: [1_000.0, 10_000.0])
    func fullChainDecodesWithRealSeparationOnATextbookReceiver(toneHz: Double) {
        let cfg = makeStereoConfig()
        let gen = MPXGenerator(config: cfg, sampleRate: sampleRate)
        let frames = Int(sampleRate * 0.6)
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        let w = 2.0 * Double.pi * toneHz / sampleRate
        for i in 0..<frames { left[i] = Float(0.3 * sin(w * Double(i))) }
        left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                var offset = 0
                while offset < frames {
                    let chunk = min(1024, frames - offset)
                    gen.renderFromInputInPlace(
                        frameCount: chunk,
                        // swiftlint:disable force_unwrapping
                        left: lBuf.baseAddress!.advanced(by: offset),
                        right: rBuf.baseAddress!.advanced(by: offset)
                        // swiftlint:enable force_unwrapping
                    )
                    offset += chunk
                }
            }
        }
        // Past the composite clipper, look-ahead and limiter warm-up.
        let decoded = textbookDecode(left, toneHz: toneHz, start: Int(0.2 * sampleRate))
        let sepDB = 20.0 * log10(max(decoded.left, 1e-12) / max(decoded.right, 1e-12))
        print(String(format: "[separation] %.0f Hz full chain: L %.4f, R %.5f, separation %.1f dB",
                     toneHz, decoded.left, decoded.right, sepDB))
        #expect(decoded.left > 0.05, "fixture problem: the tone did not reach the composite (L \(decoded.left))")
        #expect(sepDB > 30.0,
            "\(Int(toneHz)) Hz left-only decodes with \(sepDB) dB separation on a textbook receiver -- pilot and subcarrier are misaligned on the full chain")
    }
}
