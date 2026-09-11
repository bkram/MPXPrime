import Testing
import Foundation
@testable import MPXPrime

// The digital delivery target's true-peak guard (DSP/TruePeakGuard.swift): the
// stage that turns `processed_audio_ceiling_dbtp` from a sample-peak claim into
// a true-peak one. The pre-encode limiter's post-clip decimation FIR rings on
// hard transients, so its output can exceed its own ceiling by more than a dB
// (measured +1.4 dB on a click program); this guard sits after the make-up
// gain and rides a stereo-linked gain against a 4x reconstruction detector.
@Suite("Stereo true-peak guard (digital target)")
struct TruePeakGuardTests {

    private let sampleRate: Float = 48_000.0

    /// 8x Kaiser-sinc reconstruction, 90 dB stopband: a sharper estimate than
    /// the guard's own 4x detector, so the guard is not checked against itself.
    private func truePeak(_ left: [Float], _ right: [Float], skip: Int) -> Float {
        var peak: Float = 0
        var os = [Float](repeating: 0, count: 8)
        for buf in [left, right] {
            var interp = LinearPhaseFIRInterpolator()
            interp.configure(cutoffHz: sampleRate * 0.45, sampleRateOS: sampleRate * 8,
                             interpolateFactor: 8, stopBandDB: 90.0, transitionHz: sampleRate * 0.06)
            let lead = interp.groupDelayInputSamples
            for (i, x) in buf.enumerated() {
                os.withUnsafeMutableBufferPointer { o in interp.push(x, into: o.baseAddress!) }
                if i - lead >= skip { for v in os { peak = max(peak, abs(v)) } }
            }
        }
        return peak
    }

    private func run(_ guardStage: inout StereoTruePeakGuard, left: [Float], right: [Float]) -> ([Float], [Float]) {
        var outL = [Float](repeating: 0, count: left.count)
        var outR = [Float](repeating: 0, count: right.count)
        for i in 0..<left.count {
            (outL[i], outR[i]) = guardStage.process(left: left[i], right: right[i])
        }
        return (outL, outR)
    }

    /// Clicks + a hot tone: the click program that defeated the limiter alone.
    private func adversarialProgram(frames: Int) -> ([Float], [Float]) {
        var l = [Float](repeating: 0, count: frames)
        var r = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let t = Double(i) / Double(sampleRate)
            let tone = Float(0.7 * sin(2.0 * .pi * 997.0 * t))
            l[i] = tone
            r[i] = -tone * 0.8
            if i % 4_800 == 2_400 {          // 10 clicks per second, alternating polarity
                let sign: Float = (i / 4_800) % 2 == 0 ? 1.0 : -1.0
                l[i] += sign * 1.6
                r[i] -= sign * 1.6
            }
        }
        return (l, r)
    }

    @Test func holdsTheCeilingOnTruePeakForAdversarialProgram() {
        var guardStage = StereoTruePeakGuard()
        let ceiling: Float = 0.891_25   // -1 dBTP
        guardStage.configure(sampleRate: sampleRate, ceilingLinear: ceiling, lookaheadMS: 2.0, enabled: true)
        let (l, r) = adversarialProgram(frames: Int(sampleRate))
        let (outL, outR) = run(&guardStage, left: l, right: r)
        let peak = truePeak(outL, outR, skip: 0)
        let peakDB = 20.0 * log10(peak)
        #expect(peakDB <= -1.0 + 0.05, "guarded true peak \(peakDB) dBTP exceeds the -1.0 dBTP ceiling")
        // And it is a guard, not a gate: the program is still there.
        #expect(peakDB > -1.0 - 0.5, "guarded true peak \(peakDB) dBTP sits far under the ceiling")
    }

    @Test func isTransparentBelowTheCeilingApartFromItsDelay() {
        var guardStage = StereoTruePeakGuard()
        guardStage.configure(sampleRate: sampleRate, ceilingLinear: 0.891_25, lookaheadMS: 2.0, enabled: true)
        let frames = 4_800
        let l = (0..<frames).map { Float(0.3 * sin(2.0 * .pi * 3_000.0 * Double($0) / Double(sampleRate))) }
        let r = (0..<frames).map { Float(0.2 * sin(2.0 * .pi * 440.0 * Double($0) / Double(sampleRate))) }
        let (outL, outR) = run(&guardStage, left: l, right: r)
        let d = guardStage.latencySamples
        #expect(d >= Int(sampleRate * 0.002), "look-ahead delay \(d) is shorter than the requested 2 ms")
        var worst: Float = 0
        for i in d..<frames {
            worst = max(worst, abs(outL[i] - l[i - d]), abs(outR[i] - r[i - d]))
        }
        #expect(worst < 1e-6, "below the ceiling the guard must be a pure delay; worst sample error \(worst)")
        #expect(guardStage.gainReductionDB == 0.0)
    }

    @Test func disabledIsAPassThrough() {
        var guardStage = StereoTruePeakGuard()
        guardStage.configure(sampleRate: sampleRate, ceilingLinear: 0.5, lookaheadMS: 2.0, enabled: false)
        let (l, r) = adversarialProgram(frames: 9_600)
        let (outL, outR) = run(&guardStage, left: l, right: r)
        #expect(outL == l && outR == r, "a disabled guard must not touch or delay the signal")
    }

    @Test func gainIsStereoLinked() {
        // A peak on one channel reduces both by the same factor, so the image
        // does not lurch toward the quiet side on every transient.
        var guardStage = StereoTruePeakGuard()
        guardStage.configure(sampleRate: sampleRate, ceilingLinear: 0.5, lookaheadMS: 2.0, enabled: true)
        let frames = 9_600
        var l = [Float](repeating: 0, count: frames)
        var r = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let t = Double(i) / Double(sampleRate)
            l[i] = Float(0.9 * sin(2.0 * .pi * 1_000.0 * t))   // over the 0.5 ceiling
            r[i] = Float(0.2 * sin(2.0 * .pi * 1_000.0 * t))   // well under it
        }
        let (outL, outR) = run(&guardStage, left: l, right: r)
        let d = guardStage.latencySamples
        var worstRatioError: Float = 0
        for i in (frames / 2)..<frames where abs(l[i - d]) > 0.5 {
            let gL = outL[i] / l[i - d]
            let gR = outR[i] / r[i - d]
            worstRatioError = max(worstRatioError, abs(gL - gR))
            #expect(gL < 0.999, "the loud channel must be reduced")
        }
        #expect(worstRatioError < 1e-5, "left and right must share one gain; worst difference \(worstRatioError)")
    }

    @Test func liveCeilingChangeTakesEffect() {
        var guardStage = StereoTruePeakGuard()
        guardStage.configure(sampleRate: sampleRate, ceilingLinear: 0.891_25, lookaheadMS: 2.0, enabled: true)
        guardStage.ceiling = 0.5
        let frames = 24_000
        let l = (0..<frames).map { Float(0.9 * sin(2.0 * .pi * 1_000.0 * Double($0) / Double(sampleRate))) }
        let (outL, outR) = run(&guardStage, left: l, right: l)
        let peak = truePeak(outL, outR, skip: frames / 2)
        #expect(peak <= 0.5 * 1.006, "after a live ceiling change the guard must hold the new ceiling; got \(peak)")
    }
}
