import Foundation
import Testing

@testable import MPXPrime

// Pins for levelling review 2026-10 (2026-10-15): the
// downward expander's ratio, the wideband AGC's waveform-independent
// detector and history-independent rest point, the band limiter's bass
// distortion and overshoot, the multiband stereo link amount, and the
// allpass-compensated IIR monitor crossovers. The Advanced Dynamics items
// live in LevellingAdvancedDynamicsTests.swift.
@Suite("Levelling review fixes")
struct LevellingReviewTests {
    private let sampleRate: Float = 48_000.0

    // MARK: - Helpers

    /// Amplitude of the `frequency` component of `x` (single-bin DFT over a
    /// whole number of cycles is not required: the window is long).
    private static func toneAmplitude(_ x: ArraySlice<Float>, frequency: Double, sampleRate: Double) -> Double {
        var re = 0.0
        var im = 0.0
        let w = 2.0 * Double.pi * frequency / sampleRate
        for (n, v) in x.enumerated() {
            let a = w * Double(n)
            re += Double(v) * cos(a)
            im -= Double(v) * sin(a)
        }
        return 2.0 * (re * re + im * im).squareRoot() / Double(x.count)
    }

    private static func rmsDB(_ x: ArraySlice<Float>) -> Double {
        var sum = 0.0
        for v in x { sum += Double(v) * Double(v) }
        return 10.0 * log10(max(1e-30, sum / Double(x.count)))
    }

    /// Deterministic Gaussian noise (xorshift + Box-Muller), unit variance.
    private struct Gaussian {
        var state: UInt64
        mutating func uniform() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return (Double(state >> 11) + 0.5) / Double(1 << 53)
        }
        mutating func next() -> Float {
            let u1 = uniform()
            let u2 = uniform()
            return Float((-2.0 * log(u1)).squareRoot() * cos(2.0 * Double.pi * u2))
        }
    }

    // MARK: - Finding 3: downward expander ratio

    private func expanderGainDB(ratio: Float) -> Float {
        var expander = DownwardExpander()
        expander.configure(sampleRate: sampleRate, thresholdDB: -45.0, ratio: ratio, attackMS: 5.0, releaseMS: 100.0)
        // 1 kHz sine with its PEAK 10 dB below the threshold.
        let amplitude = powf(10.0, -55.0 / 20.0)
        var gain: Float = 1.0
        for i in 0..<Int(sampleRate * 2.0) {
            let x = amplitude * sinf(2.0 * Float.pi * 1_000.0 * Float(i) / sampleRate)
            gain = expander.expanderGain(left: x, right: x)
        }
        return 20.0 * log10f(gain)
    }

    @Test func expanderRatioIsOneToR() {
        // A 1:r expander's gain is (r - 1) x the distance below the
        // threshold. The detector reads ~0.8 dB under the sine peak, so the
        // distance is ~10.8 dB. Before the fix ratio 2 gave -21.5 dB (1:3)
        // and ratio 1 gave -10.8 dB (1:2).
        let two = expanderGainDB(ratio: 2.0)
        let one = expanderGainDB(ratio: 1.0)
        let three = expanderGainDB(ratio: 3.0)
        print(String(format: "Expander gain 10 dB below threshold: ratio 1 %.2f dB, 2 %.2f dB, 3 %.2f dB", one, two, three))
        #expect(abs(two + 10.0) <= 1.0, "ratio 2 gain \(two) dB, expected about -10 dB")
        #expect(abs(three - 2.0 * two) <= 0.2, "ratio 3 must expand twice as hard as ratio 2 (\(three) vs \(two) dB)")
        #expect(one == 0.0, "ratio 1 must be a no-op, got \(one) dB")
    }

    // MARK: - Finding 4: wideband AGC

    private func makeAGC() -> WidebandAGCRider {
        var agc = WidebandAGCRider()
        agc.configure(
            sampleRate: sampleRate, targetDB: -16.0, attackMS: 80.0, releaseMS: 1_200.0,
            minGainDB: -12.0, maxGainDB: 12.0, kWeightingEnabled: false, programDependentRelease: true)
        return agc
    }

    @Test func agcLevelIsWaveformIndependent() {
        // A sine and Gaussian noise at the same power must come out at the
        // same level. Before the fix the asymmetric power average read the
        // sine +2.3 dB and noise +4.7 dB high: sine out -21.28, noise out
        // -23.38 dBFS (2.1 dB apart) at -26 dBFS in.
        let inputRMS = powf(10.0, -26.0 / 20.0)
        let frames = Int(sampleRate * 20.0)
        let measure = frames - Int(sampleRate * 5.0)
        var sineAGC = makeAGC()
        var noiseAGC = makeAGC()
        var noise = Gaussian(state: 0x9E37_79B9_7F4A_7C15)
        var sineOut: [Float] = []
        var noiseOut: [Float] = []
        for i in 0..<frames {
            let s = inputRMS * sqrtf(2.0) * sinf(2.0 * Float.pi * 1_000.0 * Float(i) / sampleRate)
            let n = inputRMS * noise.next()
            let ys = sineAGC.process(left: s, right: s)
            let yn = noiseAGC.process(left: n, right: n)
            if i >= measure {
                sineOut.append(ys.0)
                noiseOut.append(yn.0)
            }
        }
        let sineDB = Self.rmsDB(sineOut[...])
        let noiseDB = Self.rmsDB(noiseOut[...])
        print(String(format: "AGC at -26 dBFS in: sine out %.2f dBFS, noise out %.2f dBFS", sineDB, noiseDB))
        #expect(abs(sineDB - noiseDB) <= 0.5, "sine \(sineDB) vs noise \(noiseDB) dBFS at equal input power")
    }

    @Test func agcSteadyStateDoesNotDependOnHistory() {
        // The same steady -26 dBFS input (30 s) after 20 s of a louder or a
        // quieter predecessor. Before the fix the 3 dB window FROZE the gain
        // wherever it entered it, so the two ended up to 6 dB apart (the
        // review measured -18.27 vs -12.27 dBFS); now the gain creeps to the
        // target inside the window (12 s at the 1.2 s release).
        func run(predecessorDB: Float) -> Double {
            var agc = makeAGC()
            let predecessor = powf(10.0, predecessorDB / 20.0) * sqrtf(2.0)
            let steady = powf(10.0, -26.0 / 20.0) * sqrtf(2.0)
            let first = Int(sampleRate * 20.0)
            let total = first + Int(sampleRate * 30.0)
            var out: [Float] = []
            for i in 0..<total {
                let a = i < first ? predecessor : steady
                let x = a * sinf(2.0 * Float.pi * 1_000.0 * Float(i) / sampleRate)
                let y = agc.process(left: x, right: x)
                if i >= total - Int(sampleRate * 2.0) { out.append(y.0) }
            }
            return Self.rmsDB(out[...])
        }
        let afterLoud = run(predecessorDB: -10.0)
        let afterQuiet = run(predecessorDB: -36.0)
        print(String(format: "AGC steady -26 dBFS: after loud %.2f dBFS, after quiet %.2f dBFS", afterLoud, afterQuiet))
        #expect(abs(afterLoud - afterQuiet) <= 1.5, "rest point depends on history: \(afterLoud) vs \(afterQuiet) dBFS")
    }

    // MARK: - Finding 5: band limiter

    @Test func bandLimiterBassDistortion() {
        // 60 Hz at 0 dBFS into a -3 dB band limiter (the default 0.5 / 50 ms
        // settings). Before the fix the follower drooped -1.4 dB between
        // half-cycle peaks: H3 -35.0 dB and the output peak 0.730 against a
        // 0.708 threshold.
        var limiter = BandLimiter()
        limiter.configure(sampleRate: sampleRate, thresholdDB: -3.0, attackMS: 0.5, releaseMS: 50.0)
        let frames = Int(sampleRate * 2.0)
        var out = [Float](repeating: 0.0, count: frames)
        for i in 0..<frames {
            let x = sinf(2.0 * Float.pi * 60.0 * Float(i) / sampleRate)
            out[i] = limiter.process(left: x, right: x).0
        }
        let tail = out[(frames - Int(sampleRate))...]
        let h1 = Self.toneAmplitude(tail, frequency: 60.0, sampleRate: Double(sampleRate))
        let h3 = Self.toneAmplitude(tail, frequency: 180.0, sampleRate: Double(sampleRate))
        let h3DB = 20.0 * log10(max(1e-12, h3 / h1))
        let peak = tail.map { abs($0) }.max() ?? 0.0
        let threshold = powf(10.0, -3.0 / 20.0)
        let overDB = 20.0 * log10f(peak / threshold)
        print(String(format: "Band limiter 60 Hz, 3 dB GR: H3 %.1f dB, output peak %.4f (%+.2f dB re threshold)", h3DB, peak, overDB))
        #expect(h3DB < -50.0, "H3 \(h3DB) dB on a 60 Hz band at 3 dB of reduction")
        #expect(overDB <= 0.1, "output peak \(peak) is \(overDB) dB over the threshold")
    }

    // MARK: - Finding 6: multiband stereo link amount

    @Test func linkAmountSharesTheDetectorBetweenChannels() {
        // A hard-left signal: at amount 0 the right channel's detector sees
        // nothing of it, at 1 both channels see the linked level, and the
        // amount in between moves the right channel's detector between the
        // two (the old control was a binary link above 1e-4).
        let l: Float = 0.8
        let r: Float = 0.0
        let none = MultibandStereoLink.sidechains(absLeft: l, absRight: r, amount: 0.0)
        let some = MultibandStereoLink.sidechains(absLeft: l, absRight: r, amount: 0.2)
        let full = MultibandStereoLink.sidechains(absLeft: l, absRight: r, amount: 1.0)
        #expect(none.left == l && none.right == r)
        #expect(full.left == full.right, "amount 1 must give one shared detector")
        #expect(abs(full.left - l / sqrtf(2.0)) < 1e-6)
        #expect(some.right > none.right && some.right < full.right, "amount 0.2 must sit between independent and linked")
        // A centred source has nothing to link: every amount gives the same
        // detector, which is what an L/R link should do.
        let centred = MultibandStereoLink.sidechains(absLeft: 0.5, absRight: 0.5, amount: 0.3)
        #expect(abs(centred.left - 0.5) < 1e-6 && abs(centred.right - 0.5) < 1e-6)
    }

    // MARK: - Finding 7: IIR monitor crossovers

    /// Worst magnitude deviation (dB) of an impulse response from 0 dB over
    /// 20 Hz - 20 kHz, on a log grid.
    private static func worstDeviationDB(_ h: [Float], sampleRate: Double) -> (dB: Double, atHz: Double) {
        var worst = 0.0
        var at = 0.0
        var f = 20.0
        while f <= 20_000.0 {
            var re = 0.0
            var im = 0.0
            let w = 2.0 * Double.pi * f / sampleRate
            for (n, v) in h.enumerated() where v != 0 {
                re += Double(v) * cos(w * Double(n))
                im -= Double(v) * sin(w * Double(n))
            }
            let db = 10.0 * log10(re * re + im * im)
            if abs(db) > abs(worst) {
                worst = db
                at = f
            }
            f *= 1.05
        }
        return (worst, at)
    }

    @Test func iirCrossoverSumIsFlat() {
        let n = 32_768
        var splitter = StereoIIRMultibandSplitter5()
        splitter.configure(x1Hz: 90.0, x2Hz: 350.0, x3Hz: 1_800.0, x4Hz: 6_800.0, sampleRate: sampleRate)
        var h = [Float](repeating: 0.0, count: n)
        for i in 0..<n {
            let b = splitter.process(left: i == 0 ? 1.0 : 0.0, right: 0.0)
            h[i] = b.0.0 + b.1.0 + b.2.0 + b.3.0 + b.4.0
        }
        let compensated = Self.worstDeviationDB(h, sampleRate: Double(sampleRate))

        // The uncompensated tree the monitor path used before (for the
        // record: the review's model read -0.81 dB at 119 Hz).
        var s1 = StereoLinkwitzRiley4(), s2 = StereoLinkwitzRiley4()
        var s3 = StereoLinkwitzRiley4(), s4 = StereoLinkwitzRiley4()
        s1.configure(cutoffHz: 90.0, sampleRate: sampleRate)
        s2.configure(cutoffHz: 350.0, sampleRate: sampleRate)
        s3.configure(cutoffHz: 1_800.0, sampleRate: sampleRate)
        s4.configure(cutoffHz: 6_800.0, sampleRate: sampleRate)
        var tree = [Float](repeating: 0.0, count: n)
        for i in 0..<n {
            let a = s1.process(left: i == 0 ? 1.0 : 0.0, right: 0.0)
            let b = s2.process(left: a.0.1, right: 0.0)
            let c = s3.process(left: b.0.1, right: 0.0)
            let d = s4.process(left: c.0.1, right: 0.0)
            tree[i] = a.0.0 + b.0.0 + c.0.0 + d.0.0 + d.0.1
        }
        let uncompensated = Self.worstDeviationDB(tree, sampleRate: Double(sampleRate))
        print(String(format: "IIR 5-band sum: compensated %+.3f dB at %.0f Hz, uncompensated tree %+.3f dB at %.0f Hz",
                     compensated.dB, compensated.atHz, uncompensated.dB, uncompensated.atHz))
        #expect(abs(compensated.dB) <= 0.05, "compensated 5-band sum deviates \(compensated.dB) dB at \(compensated.atHz) Hz")
        #expect(abs(uncompensated.dB) > 0.5, "the reference tree should show the defect (\(uncompensated.dB) dB)")

        var three = StereoIIRMultibandSplitter3()
        three.configure(x1Hz: 320.0, x2Hz: 2_550.0, sampleRate: sampleRate)
        var h3 = [Float](repeating: 0.0, count: n)
        for i in 0..<n {
            let b = three.process(left: 0.0, right: i == 0 ? 1.0 : 0.0)
            h3[i] = b.0.1 + b.1.1 + b.2.1
        }
        let threeDev = Self.worstDeviationDB(h3, sampleRate: Double(sampleRate))
        print(String(format: "IIR 3-band sum: %+.3f dB at %.0f Hz", threeDev.dB, threeDev.atHz))
        #expect(abs(threeDev.dB) <= 0.05, "compensated 3-band sum deviates \(threeDev.dB) dB at \(threeDev.atHz) Hz")
    }
}
