import Foundation
import Testing
@testable import MPXPrime

// Pinning tests for the 2026-10 peak-control review, stage level
// (peak-control review 2026-10): F3, F4, F6, F7, F8, F9, F10, F13,
// F14, and the bass clipper's split precision (levelling review item 9).
// Each test failed on the code the review audited.

@Suite("Peak control: stages (2026-10 review)")
struct PeakControlStageTests {

    // MARK: F3 -- guard bands are coherent

    private func clipperResidual(stereoGuard: Float, pilot: Bool, rds: Bool,
                                 frames: Int) -> [Float] {
        let sr: Float = 192_000.0
        var clip = CompositeClipper()
        clip.configure(sampleRate: sr, thresholdDB: -6.0, ceilingDB: -1.0,
                       cancelAudio: false, stereoGuard: stereoGuard,
                       cancelPilot: pilot, cancelRDS: rds, lookaheadMS: 0.0,
                       oversamplingFactor: 16)
        let delay = clip.totalDelayHostSamples
        var noise = PeakControlSignals.Noise(seed: 777)
        var input = [Float](repeating: 0, count: frames)
        for i in 0..<frames { input[i] = 1.6 * noise.next() }
        var residual = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let y = clip.process(input[i])
            let x = i >= delay ? input[i - delay] : 0.0
            residual[i] = x - y
        }
        return residual
    }

    @Test func guardBandResidualDepth() {
        // White noise far over the threshold. With every guard on (share 1)
        // the residual the clipper leaves in the pilot, stereo and RDS bands
        // must be >= 30 dB under the unguarded clipper's, and no frequency
        // may carry MORE residual than unguarded. The IIR guards left
        // -2.4 dB at 30 kHz and +2.5 dB at 23 and 53 kHz.
        let frames = 8_192 * 9
        let guarded = clipperResidual(stereoGuard: 1.0, pilot: true, rds: true, frames: frames)
        let bare = clipperResidual(stereoGuard: 0.0, pilot: false, rds: false, frames: frames)
        func ratioDB(_ f: Double) -> Double {
            let g = PeakControlSignals.bandPower(guarded, freqHz: f, sampleRate: 192_000, start: 8_192)
            let b = PeakControlSignals.bandPower(bare, freqHz: f, sampleRate: 192_000, start: 8_192)
            return 10.0 * log10(max(1e-30, g) / max(1e-30, b))
        }
        var worstInBand = -200.0
        var inBandAt = 0.0
        let protected = Array(stride(from: 17_500.0, through: 20_500.0, by: 500.0))
            + Array(stride(from: 23_500.0, through: 52_500.0, by: 1_000.0))
            + Array(stride(from: 55_500.0, through: 58_500.0, by: 500.0))
        for f in protected {
            let r = ratioDB(f)
            if r > worstInBand { worstInBand = r; inBandAt = f }
        }
        #expect(worstInBand <= -30.0, "guarded residual only \(worstInBand) dB under unguarded at \(inBandAt) Hz")
        var worstAnywhere = -200.0
        var anywhereAt = 0.0
        for f in stride(from: 1_000.0, through: 90_000.0, by: 500.0) {
            let r = ratioDB(f)
            if r > worstAnywhere { worstAnywhere = r; anywhereAt = f }
        }
        #expect(worstAnywhere <= 0.5, "a guard AMPLIFIES the residual: +\(worstAnywhere) dB at \(anywhereAt) Hz")
        print("PEAKCONTROL F3 guarded vs bare residual: worst protected \(worstInBand) dB at \(inBandAt) Hz, worst anywhere \(worstAnywhere) dB at \(anywhereAt) Hz")
    }

    // MARK: F8 -- the residual lines up with the bypass

    @Test func differentialBypassAlignment() {
        // One clipped impulse: the residual the clipper subtracts must be
        // centred on the bypass sample. The rounded decimator delay put it
        // 1/8 host sample late at 16x.
        for factor in [8, 16, 32] {
            var clip = CompositeClipper()
            clip.configure(sampleRate: 192_000, thresholdDB: -6.0, ceilingDB: -1.0,
                           cancelAudio: false, stereoGuard: 0.0, cancelPilot: false,
                           cancelRDS: false, lookaheadMS: 0.0, oversamplingFactor: factor)
            let delay = clip.totalDelayHostSamples
            let frames = 2_048
            let at = 512
            var residual = [Double](repeating: 0, count: frames)
            for i in 0..<frames {
                let x: Float = i == at ? 3.0 : 0.0
                let y = clip.process(x)
                let xd: Float = (i - delay) == at ? 3.0 : 0.0
                residual[i] = Double(xd - y)
            }
            var num = 0.0
            var den = 0.0
            for (i, r) in residual.enumerated() {
                num += Double(i) * r
                den += r
            }
            let centroid = num / den
            let expected = Double(at + delay)
            print("PEAKCONTROL F8 \(factor)x residual centroid offset \(centroid - expected) host samples")
            #expect(abs(centroid - expected) < 0.03,
                    "\(factor)x: residual centred at \(centroid), bypass at \(expected)")
        }
    }

    // MARK: F10 -- the look-ahead gain is at depth when the peak arrives

    @Test func clipperLookaheadDepthOnArrival() {
        // A burst at twice the ceiling after silence. With the look-ahead at
        // full depth on arrival the clip kernel never sees more than the
        // ceiling, so its gain reduction never exceeds the knee's own at the
        // ceiling. The exponential attack + 200 Hz smoother reached 81 %.
        let sr: Float = 192_000.0
        var clip = CompositeClipper()
        let thresholdDB: Float = -3.0
        let ceilingDB: Float = -1.0
        clip.configure(sampleRate: sr, thresholdDB: thresholdDB, ceilingDB: ceilingDB,
                       cancelAudio: false, stereoGuard: 0.0, cancelPilot: false,
                       cancelRDS: false, lookaheadMS: 2.0, oversamplingFactor: 16)
        let thr = powf(10.0, thresholdDB / 20.0)
        let ceil = powf(10.0, ceilingDB / 20.0)
        let kneeGainAtCeiling = (thr + ((ceil - thr) * tanhf(1.0))) / ceil
        let allowedDB = -20.0 * log10f(kneeGainAtCeiling) + 0.05
        var worstDB: Float = 0.0
        for n in 0..<Int(sr * 0.05) {
            let on = n >= Int(sr * 0.02)
            let x: Float = on ? 2.0 * ceil * sinf(2.0 * .pi * 5_000.0 * Float(n) / sr) : 0.0
            _ = clip.process(x)
            worstDB = max(worstDB, clip.gainReductionDB)
        }
        print("PEAKCONTROL F10 clip-kernel GR \(worstDB) dB, full-depth bound \(allowedDB) dB")
        #expect(worstDB <= allowedDB,
                "clip kernel cut \(worstDB) dB; at full look-ahead depth it is \(allowedDB) dB at most")
    }

    // MARK: F4 -- distortion cancellation never amplifies

    private func dccProducts(cancelHz: Float) -> [Double: Double] {
        let sr: Float = 48_000.0
        var dcc = DistortionCancelledClipper()
        dcc.configure(sampleRate: sr, ceilingDB: -6.0, cancelFreqHz: cancelHz)
        let frames = 48_000
        var out = [Float](repeating: 0, count: frames)
        for n in 0..<frames {
            let t = Float(n) / sr
            let x = 0.6 * sinf(2.0 * .pi * 1_000.0 * t) + 0.6 * sinf(2.0 * .pi * 1_300.0 * t)
            out[n] = dcc.process(left: x, right: x).0
        }
        // Odd-order products below 4 kHz (the band the stage claims to clean).
        let products: [Double] = [700, 1_600, 3_000, 3_300, 3_600, 3_900, 400, 1_900, 2_200]
        var result: [Double: Double] = [:]
        for f in products {
            result[f] = 20.0 * log10(max(1e-12,
                PeakControlSignals.toneAmplitude(out, freqHz: f, sampleRate: 48_000, start: 8_000)))
        }
        return result
    }

    @Test func distortionCancellationNeverAmplifies() {
        // Same clipper, cancellation at 2 kHz vs effectively none (100 Hz):
        // no product below 4 kHz may come out louder with cancellation. The
        // LR4 error path made the 1.6 kHz product +4.3 dB louder.
        let cancelled = dccProducts(cancelHz: 2_000)
        let plain = dccProducts(cancelHz: 100)
        for f in cancelled.keys.sorted() {
            print("PEAKCONTROL F4 product \(f) Hz: cancelled \(cancelled[f] ?? 0) dB, plain \(plain[f] ?? 0) dB")
        }
        for (f, level) in cancelled {
            let ref = plain[f] ?? -240
            #expect(level <= ref + 0.5 || level < -100,
                    "\(f) Hz product: \(level) dB with cancellation vs \(ref) dB without")
        }
        // And it does cancel below the corner.
        #expect((cancelled[700] ?? 0) < (plain[700] ?? 0) - 20.0)
    }

    // MARK: F6 -- look-ahead gains never step

    private func levelJumpProgramme(frames: Int, sampleRate: Float) -> [Float] {
        (0..<frames).map { n in
            let t = Float(n) / sampleRate
            let jump: Float = n < frames / 2 ? 1.0 : 1.6
            let m = 0.5 * sinf(2.0 * .pi * 1_000.0 * t)
            let s = 0.4 * sinf(2.0 * .pi * 3_000.0 * t) * sinf(2.0 * .pi * 38_000.0 * t)
            return jump * (m + s)
        }
    }

    @Test func lookaheadGainHasNoStep() {
        let sr: Float = 192_000.0
        var limiter = LookaheadLimiter()
        limiter.configure(sampleRate: sr, lookaheadMS: 5.0, threshold: 0.9, enabled: true)
        let x = levelJumpProgramme(frames: Int(sr * 0.2), sampleRate: sr)
        var lastGR: Float = 0
        var worstStep: Float = 0
        var peak: Float = 0
        for (n, v) in x.enumerated() {
            let y = limiter.process(v)
            let gr = limiter.gainReductionDB
            if n > 0 { worstStep = max(worstStep, abs(gr - lastGR)) }
            lastGR = gr
            peak = max(peak, abs(y))
        }
        print("PEAKCONTROL F6 final limiter worst step \(worstStep) dB, peak \(peak)")
        #expect(worstStep < 0.05, "one-sample gain step of \(worstStep) dB")
        #expect(peak <= 0.9 * 1.000_01, "limiter let \(peak) through a 0.9 threshold")
    }

    @Test(arguments: [(5.0 as Float, 0.05 as Float), (2.0, 0.12)])
    func truePeakGuardGainHasNoStep(lookaheadMS: Float, maxStepDB: Float) {
        // At 48 kHz a 2 ms look-ahead leaves a ~76-sample ramp after the
        // detector's own delay, so a 4 dB move is ~0.1 dB per sample at its
        // steepest: a ramp, not a step. The floor-in-the-state design moved
        // the whole new reduction in one sample.
        let sr: Float = 48_000.0
        var guardStage = StereoTruePeakGuard()
        guardStage.configure(sampleRate: sr, ceilingLinear: 0.8, lookaheadMS: lookaheadMS, enabled: true)
        let frames = Int(sr * 0.4)
        var lastGR: Float = 0
        var worstStep: Float = 0
        var peak: Float = 0
        for n in 0..<frames {
            let t = Float(n) / sr
            let jump: Float = n < frames / 2 ? 1.0 : 1.6
            let l = jump * (0.5 * sinf(2.0 * .pi * 1_000.0 * t) + 0.3 * sinf(2.0 * .pi * 7_000.0 * t))
            let r = jump * (0.5 * sinf(2.0 * .pi * 1_100.0 * t) - 0.3 * sinf(2.0 * .pi * 9_000.0 * t))
            let (yl, yr) = guardStage.process(left: l, right: r)
            let gr = guardStage.gainReductionDB
            if n > 0 { worstStep = max(worstStep, abs(gr - lastGR)) }
            lastGR = gr
            peak = max(peak, abs(yl), abs(yr))
        }
        print("PEAKCONTROL F6 true-peak guard \(lookaheadMS) ms worst step \(worstStep) dB, peak \(peak)")
        #expect(worstStep < maxStepDB, "one-sample gain step of \(worstStep) dB")
        #expect(peak <= 0.8 * 1.000_01, "guard let \(peak) through a 0.8 ceiling")
    }

    // MARK: F7 -- one channel's bass does not duck the other's HF

    @Test func hfLimiterIgnoresOppositeChannelBass() {
        let sr: Float = 48_000.0
        var limiter = HFLimiter()
        limiter.configure(enabled: true, sampleRate: sr, thresholdDB: -0.4, topThresholdDB: -1.4,
                          attackMS: 1.5, releaseMS: 20.0, maxReductionDB: 12.0)
        var minGain: Float = 1.0
        for n in 0..<Int(sr * 0.5) {
            let t = Float(n) / sr
            let hat = sinf(2.0 * .pi * 10_000.0 * t)
            let bass = 0.97 * sinf(2.0 * .pi * 60.0 * t)
            // L: a quiet hat with ~+9.5 dB of pre-emphasis boost. R: bass
            // just over the threshold, with the tiny boost a real network
            // gives it at 60 Hz.
            _ = limiter.process(flatL: 0.05 * hat, flatR: bass,
                                emphasizedL: 0.15 * hat, emphasizedR: bass * 1.000_5)
            if n > Int(sr * 0.05) { minGain = min(minGain, limiter.gain) }
        }
        print("PEAKCONTROL F7 L boost gain \(20 * log10f(minGain)) dB")
        #expect(minGain > 0.999, "L's HF boost was cut to \(20 * log10f(minGain)) dB by R's bass")
    }

    // MARK: F9 -- the pre-encode limiter's detector is accurate

    @Test func oversampledDetectorAccuracy() {
        // Steady 14 kHz tone 3 dB over the threshold must settle within
        // 0.1 dB of the threshold. The Lagrange upsampler settled it 0.58 dB
        // under.
        let sr: Float = 48_000.0
        var limiter = PreEncodeAudioLimiter()
        limiter.configure(sampleRate: sr, threshold: 0.9)
        let frames = 48_000
        var out = [Float](repeating: 0, count: frames)
        let amp: Float = 0.9 * powf(10.0, 3.0 / 20.0)
        for n in 0..<frames {
            let x = amp * sinf(2.0 * .pi * 14_000.0 * Float(n) / sr)
            out[n] = limiter.process(left: x, right: x).0
        }
        let a = PeakControlSignals.toneAmplitude(out, freqHz: 14_000, sampleRate: 48_000, start: 24_000)
        let errDB = 20.0 * log10(a / 0.9)
        print("PEAKCONTROL F9 14 kHz settles \(errDB) dB from the threshold")
        #expect(abs(errDB) < 0.1, "14 kHz settled \(errDB) dB from the threshold")
    }

    // MARK: F13 -- knee from the clamped threshold

    @Test func kneeUsesClampedThreshold() {
        for requested: Float in [0.6, 1.0] {
            var limiter = StereoLinkedOversampledPeakLimiter()
            limiter.configure(sampleRate: 48_000, threshold: requested)
            let expected = limiter.ceiling - limiter.threshold
            #expect(abs(limiter.ceilingKnee - expected) < 1e-6,
                    "threshold \(requested): knee \(limiter.ceilingKnee), expected \(expected)")
            #expect(limiter.ceilingKnee > 0.003, "threshold \(requested): knee collapsed to a hard clip")
        }
    }

    // MARK: F14 -- reported latency is the real one

    @Test func preEncodeLatencyIncludesResidualClipper() {
        for residual in [false, true] {
            var limiter = PreEncodeAudioLimiter()
            limiter.configure(sampleRate: 48_000, threshold: 0.9, bandlimitedResidualEnabled: residual)
            let frames = 1_024
            let at = 100
            var num = 0.0
            var den = 0.0
            for n in 0..<frames {
                let x: Float = n == at ? 0.2 : 0.0
                let y = Double(limiter.process(left: x, right: x).0)
                num += Double(n) * y
                den += y
            }
            let measured = num / den - Double(at)
            print("PEAKCONTROL F14 residual \(residual): impulse at \(measured), reported \(limiter.latencySamples)")
            #expect(abs(measured - Double(limiter.latencySamples)) <= 0.5,
                    "residual \(residual): impulse delayed \(measured), reported \(limiter.latencySamples)")
        }
    }

    // MARK: Bass clipper split at 768 kHz OS

    @Test func bassClipperSplitIsAllpassAtThe192kDomain() {
        // Dual-rate boundary off: the audio domain is 192 kHz, the bass
        // clipper runs at 768 kHz. Below threshold the stage must pass a
        // low tone at unity; the Float RBJ split ran the low band ~0.6 dB hot.
        let sr: Float = 192_000.0
        var clipper = BassClipper()
        clipper.configure(sampleRate: sr, crossoverHz: 150, thresholdDB: 0.0, drive: 1.0)
        let frames = Int(sr)
        var out = [Float](repeating: 0, count: frames)
        for n in 0..<frames {
            let x = 0.1 * sinf(2.0 * .pi * 40.0 * Float(n) / sr)
            out[n] = clipper.process(left: x, right: x).0
        }
        let a = PeakControlSignals.toneAmplitude(out, freqHz: 40, sampleRate: 192_000, start: frames / 2)
        let errDB = 20.0 * log10(a / 0.1)
        print("PEAKCONTROL bass 40 Hz gain \(errDB) dB")
        #expect(abs(errDB) < 0.05, "40 Hz through the bass clipper: \(errDB) dB")
    }
}
// Shared signals and measurements for the PeakControl* suites (2026-10
// peak-control review). Deterministic: every generator is seeded.

enum PeakControlSignals {
    /// xorshift32 in -1...1.
    struct Noise {
        private var state: UInt32
        init(seed: UInt32) { state = seed == 0 ? 0x9E37_79B9 : seed }
        mutating func next() -> Float {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return (Float(state) / Float(UInt32.max)) * 2.0 - 1.0
        }
    }

    /// Dense, bright stereo programme: twelve partials per channel from 110 Hz
    /// to 12 kHz with independent phases, L and R different, peaking near
    /// `peak`. Stands in for the verifier's `bright_dense`.
    static func denseStereo(frames: Int, sampleRate: Double, peak: Float) -> (left: [Float], right: [Float]) {
        let freqs: [Double] = [110, 220, 330, 523, 880, 1_320, 2_100, 3_300, 4_700, 6_400, 8_800, 12_000]
        var noise = Noise(seed: 12_345)
        let phasesL = freqs.map { _ in Double(noise.next()) * .pi }
        let phasesR = freqs.map { _ in Double(noise.next()) * .pi }
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        var maxAbs: Float = 1e-9
        for n in 0..<frames {
            let t = Double(n) / sampleRate
            var l = 0.0
            var r = 0.0
            for (k, f) in freqs.enumerated() {
                let w = 1.0 / (1.0 + Double(k) * 0.15)
                l += w * sin((2.0 * .pi * f * t) + phasesL[k])
                r += w * sin((2.0 * .pi * f * 1.01 * t) + phasesR[k])
            }
            left[n] = Float(l)
            right[n] = Float(r)
            maxAbs = max(maxAbs, abs(left[n]), abs(right[n]))
        }
        let scale = peak / maxAbs
        for n in 0..<frames {
            left[n] *= scale
            right[n] *= scale
        }
        return (left, right)
    }

    /// Hann-windowed Goertzel power at `freqHz`, averaged over consecutive
    /// blocks of `blockSize` from `start`.
    static func bandPower(_ x: [Float], freqHz: Double, sampleRate: Double,
                          start: Int, blockSize: Int = 8_192) -> Double {
        var total = 0.0
        var blocks = 0
        var offset = start
        while offset + blockSize <= x.count {
            let omega = 2.0 * .pi * freqHz / sampleRate
            let coeff = 2.0 * cos(omega)
            var s1 = 0.0
            var s2 = 0.0
            for i in 0..<blockSize {
                let w = 0.5 - (0.5 * cos(2.0 * .pi * Double(i) / Double(blockSize - 1)))
                let s0 = (coeff * s1) - s2 + (Double(x[offset + i]) * w)
                s2 = s1
                s1 = s0
            }
            total += (s1 * s1) + (s2 * s2) - (coeff * s1 * s2)
            blocks += 1
            offset += blockSize
        }
        return blocks > 0 ? total / Double(blocks) : 0.0
    }

    /// Goertzel amplitude (linear) of a steady tone.
    static func toneAmplitude(_ x: [Float], freqHz: Double, sampleRate: Double, start: Int) -> Double {
        let span = x.count - start
        let k = (Double(span) * freqHz / sampleRate).rounded()
        let omega = 2.0 * .pi * k / Double(span)
        let cosw = cos(omega)
        let coeff = 2.0 * cosw
        var s1 = 0.0
        var s2 = 0.0
        for i in 0..<span {
            let s0 = (coeff * s1) - s2 + Double(x[start + i])
            s2 = s1
            s1 = s0
        }
        let re = s1 - (s2 * cosw)
        let im = s2 * sin(omega)
        return sqrt((re * re) + (im * im)) / Double(span) * 2.0
    }
}
