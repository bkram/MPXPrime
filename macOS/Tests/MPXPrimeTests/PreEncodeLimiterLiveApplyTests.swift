import Testing
import Foundation
@testable import MPXPrime

// Regression guard for an audit finding: pre-encode limiter threshold and
// release controls were marked `.live` in the UI but only the enable flag
// was wired through RuntimeConfig. Live changes appeared to apply but
// left the audio-thread limiter running at the old values until restart.
//
// These tests pin the live-apply contract: changing threshold (or
// release) via RuntimeConfig must take effect within one applyRuntimeConfig
// + a few samples of render, without restarting the engine or
// reconfiguring sample rate.

@Suite("Pre-encode limiter live-apply")
struct PreEncodeLimiterLiveApplyTests {

    private let sampleRate: Double = 192_000.0

    /// Render a 1 kHz stereo sine through MPXGenerator for `seconds` and
    /// return the peak absolute MPX sample observed across the rendered
    /// window. The peak reflects what the limiter (and downstream stages)
    /// pass through.
    private func renderPeak(generator: MPXGenerator, seconds: Double,
                            inputAmplitude: Float) -> Float {
        let frames = Int(sampleRate * seconds)
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        let w = 2.0 * Double.pi * 1_000.0 / sampleRate
        for i in 0..<frames {
            let v = Float(Double(inputAmplitude) * sin(w * Double(i)))
            left[i] = v
            right[i] = v
        }
        var output = [Float](repeating: 0.0, count: frames)
        left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                output.withUnsafeMutableBufferPointer { _ in
                    let blockSize = 1024
                    var offset = 0
                    while offset < frames {
                        let chunk = min(blockSize, frames - offset)
                        generator.renderFromInputInPlace(
                            frameCount: chunk,
                            left: lBuf.baseAddress!.advanced(by: offset),
                            right: rBuf.baseAddress!.advanced(by: offset)
                        )
                        offset += chunk
                    }
                }
            }
        }
        // After renderFromInputInPlace, left/right buffers contain the
        // mono MPX sample (both channels equal). Take peak from left.
        var peak: Float = 0.0
        // Skip the first 5 ms — limiter settling, FIR group delay, etc.
        let warmup = Int(sampleRate * 0.005)
        for i in warmup..<frames {
            peak = max(peak, fabsf(left[i]))
        }
        return peak
    }

    private func makeMinimalConfig(threshold: Double, releaseMS: Double) -> AppConfig {
        var cfg = AppConfig()
        cfg.sampleRate = sampleRate
        cfg.blockSize = 1024
        // The pre-encode limiter is gated by !processingBypass — must
        // leave processing enabled for the limiter to engage. Disable
        // every other DSP stage individually to isolate limiter
        // behavior in the output peak measurement.
        cfg.processingBypass = false
        cfg.preEncodeAudioLimiterEnabled = true
        cfg.preEncodeThreshold = threshold
        cfg.preEncodeReleaseMS = releaseMS
        cfg.widebandAGCEnabled = false
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
        cfg.compositeClipperEnabled = false
        cfg.limitMPX = false
        cfg.enRDS = false
        cfg.preemphasisUS = 0
        return cfg
    }

    /// Read the pre-encode limiter's gain-reduction meter after rendering
    /// a hot sine through the chain. Returns the peak GR observed during
    /// the steady-state portion.
    private func limiterGRAfterRender(generator: MPXGenerator,
                                      inputAmplitude: Float,
                                      seconds: Double) -> Float {
        let frames = Int(sampleRate * seconds)
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        let w = 2.0 * Double.pi * 1_000.0 / sampleRate
        for i in 0..<frames {
            let v = Float(Double(inputAmplitude) * sin(w * Double(i)))
            left[i] = v
            right[i] = v
        }
        left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                var offset = 0
                while offset < frames {
                    let chunk = min(1024, frames - offset)
                    generator.renderFromInputInPlace(
                        frameCount: chunk,
                        left: lBuf.baseAddress!.advanced(by: offset),
                        right: rBuf.baseAddress!.advanced(by: offset)
                    )
                    offset += chunk
                }
            }
        }
        return generator.finalLimiterStatus.preEncodeGainReductionDB
    }

    @Test func preEncodeLimiterThresholdRespondsToLiveRuntimeConfig() {
        // High threshold (0.95) — input amplitude 0.99 just barely
        // clips, so GR is small (~0.5 dB).
        let highThresholdCfg = makeMinimalConfig(threshold: 0.95, releaseMS: 50.0)
        let gen = MPXGenerator(config: highThresholdCfg, sampleRate: sampleRate)
        let grBefore = limiterGRAfterRender(generator: gen, inputAmplitude: 0.99, seconds: 0.05)

        // Live-apply a much tighter threshold. OversampledPeakLimiter
        // internally clamps threshold to ≥0.75, so we go from 0.95 down
        // to the floor: substantial GR (~2.5 dB).
        var tightCfg = highThresholdCfg
        tightCfg.preEncodeThreshold = 0.5   // clamps to 0.75 inside the limiter
        let runtime = MPXGenerator.makeRuntimeConfig(from: tightCfg)
        gen.applyRuntimeConfig(runtime)

        // Re-render — limiter should now report much higher GR.
        let grAfter = limiterGRAfterRender(generator: gen, inputAmplitude: 0.99, seconds: 0.05)

        print(String(format: "[preencode-live] threshold 0.95→0.5 (→0.75 clamped): GR %.2f dB → %.2f dB",
                     grBefore, grAfter))

        // High threshold: GR should be small (< 1 dB for 0.99 input vs 0.95 threshold).
        #expect(grBefore < 1.0,
            "high-threshold (0.95) limiter should produce <1 dB GR for 0.99 input; got \(grBefore) dB")
        // Tight threshold (0.75 effective): GR should be ≥1.5 dB for 0.99 input.
        #expect(grAfter >= 1.5,
            "tight-threshold (0.75 effective) limiter must produce ≥1.5 dB GR for 0.99 input; got \(grAfter) dB")
        // Live change must produce a meaningful delta.
        #expect(grAfter - grBefore > 1.0,
            "live threshold change must produce ≥1 dB GR delta; got Δ \(grAfter - grBefore) dB")
    }

    /// Live-apply must reconfigure the limiter at the AUDIO-DOMAIN rate. Until
    /// 0.45 the live path passed the MPX rate, so one threshold change made
    /// the look-ahead delay (and attack / release / hold) 4x too long at the
    /// 48 kHz audio domain. The latency figure is the observable: it must
    /// be identical before and after a live threshold change and sized for
    /// 48 kHz (1 ms look-ahead = 48 samples + the decimator's group delay).
    @Test func liveApplyKeepsTheAudioDomainRate() {
        var cfg = makeMinimalConfig(threshold: 0.95, releaseMS: 50.0)
        cfg.dualRateAudioDomainEnabled = true
        cfg.dualRateAudioDomainRateHz = 48_000.0
        cfg.preEncodeLookaheadMS = 1.0
        let gen = MPXGenerator(config: cfg, sampleRate: sampleRate)
        let before = gen.preEncodeLimiterLatencySamples
        #expect(before >= 48 && before < 48 + 96,
            "1 ms look-ahead at 48 kHz plus the FIR decimator delay (<2 ms) expected, got \(before) samples")

        var tight = cfg
        tight.preEncodeThreshold = 0.8
        gen.applyRuntimeConfig(MPXGenerator.makeRuntimeConfig(from: tight))
        let after = gen.preEncodeLimiterLatencySamples
        #expect(after == before,
            "live-apply changed the limiter's rate: latency \(before) -> \(after) samples")
    }

    @Test func preEncodeLimiterReleaseRespondsToLiveRuntimeConfig() {
        // Slow release vs fast release — push the limiter hard, then
        // drop input level. With a slow release, output recovery is
        // delayed; with a fast release, output recovers quickly. Measure
        // the post-burst trailing average.
        var cfg = makeMinimalConfig(threshold: 0.6, releaseMS: 200.0)
        let gen = MPXGenerator(config: cfg, sampleRate: sampleRate)

        // Hit it with a transient burst (0.95 amplitude) to charge GR.
        _ = renderPeak(generator: gen, seconds: 0.05, inputAmplitude: 0.95)

        // Now feed a low-amplitude input. With releaseMS=200, GR
        // decays slowly. Measure RMS over 50 ms.
        func renderRMS(generator: MPXGenerator, seconds: Double, amp: Float) -> Float {
            let frames = Int(sampleRate * seconds)
            var left = [Float](repeating: 0.0, count: frames)
            var right = [Float](repeating: 0.0, count: frames)
            let w = 2.0 * Double.pi * 1_000.0 / sampleRate
            for i in 0..<frames {
                let v = Float(Double(amp) * sin(w * Double(i)))
                left[i] = v
                right[i] = v
            }
            left.withUnsafeMutableBufferPointer { lBuf in
                right.withUnsafeMutableBufferPointer { rBuf in
                    var offset = 0
                    while offset < frames {
                        let chunk = min(1024, frames - offset)
                        generator.renderFromInputInPlace(
                            frameCount: chunk,
                            left: lBuf.baseAddress!.advanced(by: offset),
                            right: rBuf.baseAddress!.advanced(by: offset)
                        )
                        offset += chunk
                    }
                }
            }
            var sumSq: Double = 0.0
            for v in left { sumSq += Double(v) * Double(v) }
            return Float(sqrt(sumSq / Double(left.count)))
        }
        let rmsSlowRelease = renderRMS(generator: gen, seconds: 0.05, amp: 0.4)

        // Now flip release to fast (10 ms) via live-apply.
        cfg.preEncodeReleaseMS = 10.0
        gen.applyRuntimeConfig(MPXGenerator.makeRuntimeConfig(from: cfg))

        // Re-pin GR via a burst, then measure post-burst RMS.
        _ = renderPeak(generator: gen, seconds: 0.05, inputAmplitude: 0.95)
        let rmsFastRelease = renderRMS(generator: gen, seconds: 0.05, amp: 0.4)

        print(String(format: "[preencode-live] release 200→10ms: post-burst RMS %.4f → %.4f", rmsSlowRelease, rmsFastRelease))

        // Fast release should give higher RMS during the 0.4-amp window
        // (because GR has had more time to release).
        #expect(rmsFastRelease > rmsSlowRelease,
            "fast release (10 ms) should recover faster than slow (200 ms); RMS slow=\(rmsSlowRelease), fast=\(rmsFastRelease)")
    }
}
