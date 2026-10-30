import Foundation
import Testing
@testable import MPXPrime

// Pinning tests for the 2026-10 peak-control review, generator level
// (peak-control review 2026-10): F1 and F2 (regulatory), F5, F11,
// F12. Each test failed on the code the review audited.

@Suite("Peak control: deviation and multiplex budget (2026-10 review)")
struct PeakControlRegulatoryTests {

    private static let sampleRate = 192_000.0

    private func compositeConfig() -> AppConfig {
        var cfg = AppConfig()
        cfg.sampleRate = Self.sampleRate
        cfg.sourceMode = "input"
        cfg.monitorEnabled = false
        cfg.outputGainDB = 0.0
        return cfg
    }

    /// Render dense, hot programme through the full composite chain; returns
    /// the emitted multiplex peak after `skipSeconds` and the generator.
    private func renderPeak(_ cfg: AppConfig, seconds: Double = 0.6, skipSeconds: Double = 0.3,
                            monoToneHz: Double? = nil) -> (peak: Float, gen: MPXGenerator) {
        let gen = MPXGenerator(config: cfg, sampleRate: Self.sampleRate)
        let frames = Int(Self.sampleRate * seconds)
        var programme = PeakControlSignals.denseStereo(frames: frames, sampleRate: Self.sampleRate, peak: 0.95)
        if let hz = monoToneHz {
            for i in 0..<frames {
                let s = Float(0.98 * sin(2.0 * .pi * hz * Double(i) / Self.sampleRate))
                programme.left[i] = s
                programme.right[i] = s
            }
        }
        let skip = Int(Self.sampleRate * skipSeconds)
        var peak: Float = 0
        for i in 0..<frames {
            let y = gen.renderSingleSample(leftIn: programme.left[i], rightIn: programme.right[i])
            if i >= skip { peak = max(peak, abs(y)) }
        }
        return (peak, gen)
    }

    // MARK: F1

    @Test(arguments: [50.0, 75.0])
    func deviationSettingBoundsPeakDeviation(deviationKHz: Double) {
        // Final Drive +8 dB, dense bright programme: the emitted multiplex
        // (pilot and RDS included) must not exceed the Composite Deviation
        // setting. At 50 kHz the budget ignored the setting and peaks
        // reached ~71 kHz.
        var cfg = compositeConfig()
        cfg.finalDriveDB = 8.0
        cfg.mpxDeviationKHz = deviationKHz
        let (peak, _) = renderPeak(cfg)
        let kHz = DeviationReadout.kilohertz(compositePeak: peak, modulationReferenceScale: 1.0)
        print("PEAKCONTROL F1 \(deviationKHz) kHz setting: peak \(kHz) kHz")
        #expect(Double(kHz) <= deviationKHz + 0.1, "peak deviation \(kHz) kHz at a \(deviationKHz) kHz setting")
        // And it is still a loud, fully modulated multiplex, not a muted one.
        #expect(Double(kHz) >= deviationKHz * 0.85, "only \(kHz) kHz at a \(deviationKHz) kHz setting")
    }

    // MARK: F2

    @Test func compositePeakStaysUnderThresholdWithMaxSubcarriers() {
        // The largest pilot and RDS injection `sanitize()` accepts, audio
        // held on its budget by a hot mono tone (its crests walk across the
        // pilot and RDS crests): the total multiplex stays under the final
        // threshold and nothing reaches the final clamp (pilot and RDS keep
        // their amplitude). The 0.5 ms / 12 ms envelope under-read the
        // pilot+RDS peak and the clamp clipped them.
        var cfg = compositeConfig()
        cfg.finalDriveDB = 12.0
        cfg.pilotLevel = 0.12
        cfg.enRDS = true
        cfg.rdsLevel = 7.5
        let (peak, gen) = renderPeak(cfg, monoToneHz: 997.0)
        print("PEAKCONTROL F2 multiplex peak \(peak), overshoot \(gen.compositeCalibrationStatus.postInjectionOvershoot)")
        #expect(peak <= Float(cfg.limitThreshold) + 1e-4,
                "multiplex peak \(peak) over the \(cfg.limitThreshold) threshold")
        #expect(gen.compositeCalibrationStatus.postInjectionOvershoot == 0.0,
                "pilot/RDS reached the final clamp: overshoot \(gen.compositeCalibrationStatus.postInjectionOvershoot)")
    }

    // MARK: F11

    @Test func safetyShaperNeverExceedsBudget() {
        for threshold: Float in [0.3, 0.56, 0.85, 0.98] {
            var last: Float = 0
            var x: Float = 0
            while x <= 10.0 {
                let y = MPXGenerator.softClipSafety(x, threshold: threshold)
                #expect(y <= threshold, "softClipSafety(\(x)) = \(y) over a \(threshold) budget")
                #expect(y >= last - 1e-7, "softClipSafety is not monotonic at \(x)")
                #expect(abs(MPXGenerator.softClipSafety(-x, threshold: threshold) + y) < 1e-7)
                last = y
                x += 0.001
            }
            // Identity well under the knee.
            #expect(MPXGenerator.softClipSafety(0.9 * threshold, threshold: threshold) == 0.9 * threshold)
        }
    }

    // MARK: F12

    @Test func subcarrierDelayMatchesActiveStages() {
        // With `limit_lookahead_enabled = false` the final limiter is not in
        // the audio path, so the pilot must not be delayed by its look-ahead:
        // same subcarrier delay as with the limiter switched off entirely.
        var off = compositeConfig()
        off.limitMPX = false
        var noLookahead = compositeConfig()
        noLookahead.limitMPX = true
        noLookahead.limitLookaheadEnabled = false
        noLookahead.limitLookaheadMS = 1.3
        var running = compositeConfig()
        running.limitLookaheadMS = 1.3
        let dOff = MPXGenerator(config: off, sampleRate: Self.sampleRate).subcarrierDelayActiveCount
        let dNoLA = MPXGenerator(config: noLookahead, sampleRate: Self.sampleRate).subcarrierDelayActiveCount
        let dRun = MPXGenerator(config: running, sampleRate: Self.sampleRate).subcarrierDelayActiveCount
        print("PEAKCONTROL F12 subcarrier delay: limiter off \(dOff), look-ahead disabled \(dNoLA), running \(dRun)")
        #expect(dNoLA == dOff, "look-ahead disabled: pilot delayed \(dNoLA), limiter-off chain \(dOff)")
        #expect(dRun == dOff + Int((Self.sampleRate * 0.0013).rounded()),
                "running limiter: pilot delayed \(dRun), expected \(dOff) + look-ahead")
    }

    // MARK: F5

    private func fmAudioOnly(coderHasClipper: Bool) -> (clamped: Int, longestRun: Int, peak: Float) {
        var cfg = AppConfig()
        cfg.sampleRate = 48_000
        cfg.blockSize = 512
        cfg.sourceMode = "input"
        cfg.monitorEnabled = false
        cfg.operatingMode = .fm
        cfg.preEncodeAudioLimiterEnabled = true
        cfg.preEncodeThreshold = 0.90
        cfg.processedAudioCoderHasClipper = coderHasClipper
        cfg.widebandAGCEnabled = false
        cfg.advancedDynamicsEnabled = false
        cfg.multibandEnabled = false
        cfg.multibandLimiterEnabled = false
        let gen = MPXGenerator(config: cfg, sampleRate: cfg.sampleRate)
        gen.setAudioOutputOnly(true)
        gen.setEncoderFIREnabled(cfg.encoderFIREnabled)
        gen.setMultibandFIREnabled(cfg.multibandFIREnabled)
        let frames = 48_000
        // Dense programme 6 dB over the limiter threshold (before
        // pre-emphasis adds more on the HF partials).
        var programme = PeakControlSignals.denseStereo(frames: frames, sampleRate: 48_000, peak: 1.8)
        programme.left.withUnsafeMutableBufferPointer { l in
            programme.right.withUnsafeMutableBufferPointer { r in
                var offset = 0
                while offset < frames {
                    let n = min(512, frames - offset)
                    // swiftlint:disable:next force_unwrapping
                    gen.renderAudioOnlyFromInputInPlace(frameCount: n, left: l.baseAddress!.advanced(by: offset),
                                                        // swiftlint:disable:next force_unwrapping
                                                        right: r.baseAddress!.advanced(by: offset))
                    offset += n
                }
            }
        }
        var clamped = 0
        var run = 0
        var longest = 0
        var peak: Float = 0
        for i in 9_600..<frames {
            let m = max(abs(programme.left[i]), abs(programme.right[i]))
            peak = max(peak, m)
            if m >= 0.999_99 {
                clamped += 1
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        return (clamped, longest, peak)
    }

    @Test(arguments: [true, false])
    func fmAudioOutputNeverReachesTheClamp(coderHasClipper: Bool) {
        // FM processed-audio output: the make-up maps the limiter's real
        // ceiling (or the final clipper's) onto full scale and a gain-riding
        // guard holds it, so the render clamp never flat-tops a peak. It used
        // to map the THRESHOLD: 0.78 % of the samples were clamped.
        let r = fmAudioOnly(coderHasClipper: coderHasClipper)
        print("PEAKCONTROL F5 coderHasClipper \(coderHasClipper): clamped \(r.clamped), longest run \(r.longestRun), peak \(r.peak)")
        #expect(r.longestRun <= 1, "clamp flat-topped \(r.longestRun) consecutive samples")
        #expect(r.clamped <= 2, "\(r.clamped) samples at the clamp")
        #expect(r.peak >= 0.9, "output should still reach near full scale, peak \(r.peak)")
    }
}
