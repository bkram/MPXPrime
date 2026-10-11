import Testing
import Foundation
@testable import MPXPrime

// Linear-phase FIR multiband crossover tests, at the 48 kHz audio-domain
// rate the production chain actually runs them at.
//
// The load-bearing assertion for these splitters is **sum-to-flat**: when
// the bands are summed back, the result must equal the input delayed by
// `groupDelaySamples` to within the numerical noise floor. This is the
// property that makes phase-coherent multiband possible -- IIR LR4 only
// gives sum-to-allpass (magnitude-flat with phase rotation), which is why
// transients smear when bands compress independently.
//
// Since 0.45 the splitter also owns the crossover design: -6 dB exactly at
// each crossover, a transition equal to the crossover frequency (floored at
// 120 Hz), and a latency budget -- the pre-0.45 design ignored the caller's
// transition, hit the 2049-tap clamp (21.3 ms at 48 kHz) and gave every
// crossover an ~85 Hz brick wall.

@Suite("Multiband FIR splitter")
struct MultibandFIRSplitterTests {

    private let sampleRate: Float = 48_000.0
    private let crossovers: [Float] = [90.0, 350.0, 1_800.0, 6_800.0]

    private func makeFiveBand() -> LinearPhaseMultibandSplitter5 {
        var splitter = LinearPhaseMultibandSplitter5()
        splitter.configure(x1Hz: crossovers[0], x2Hz: crossovers[1], x3Hz: crossovers[2], x4Hz: crossovers[3],
                           sampleRate: sampleRate)
        return splitter
    }

    // MARK: - Test signals

    /// Deterministic broadband test signal -- mix of audio-band sines and
    /// pseudo-noise so every band gets meaningful energy.
    private func makeProgramSignal(frames: Int) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        let w1 = 2.0 * Double.pi * 80.0 / Double(sampleRate)        // sub
        let w2 = 2.0 * Double.pi * 400.0 / Double(sampleRate)       // low
        let w3 = 2.0 * Double.pi * 1200.0 / Double(sampleRate)      // mid
        let w4 = 2.0 * Double.pi * 4500.0 / Double(sampleRate)      // presence
        let w5 = 2.0 * Double.pi * 9000.0 / Double(sampleRate)      // air
        var rng = UInt64(0xDEAD_BEEF_CAFE_F00D)
        for i in 0..<frames {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let n = Float(Int64(bitPattern: rng) >> 32) / Float(Int32.max) * 0.05
            let t = Double(i)
            out[i] = Float(0.20 * sin(w1 * t) + 0.18 * sin(w2 * t) +
                          0.16 * sin(w3 * t) + 0.14 * sin(w4 * t) +
                          0.12 * sin(w5 * t)) + n
        }
        return out
    }

    /// Steady-state amplitude of `samples` at `hz` by sin/cos projection
    /// over the second half of the buffer.
    private func amplitude(_ samples: [Float], hz: Float) -> Float {
        let start = samples.count / 2
        let omega = 2.0 * Double(Float.pi) * Double(hz) / Double(sampleRate)
        var s = 0.0, c = 0.0
        for i in start..<samples.count {
            s += Double(samples[i]) * sin(omega * Double(i))
            c += Double(samples[i]) * cos(omega * Double(i))
        }
        let scale = 2.0 / Double(samples.count - start)
        return Float(hypot(s * scale, c * scale))
    }

    private func dB(_ x: Float) -> Float { 20.0 * log10f(max(1e-9, x)) }

    // MARK: - Sum-to-flat

    @Test func fiveBandSplitterSumsToFlatDelayedInput() {
        var splitter = makeFiveBand()
        let delay = splitter.groupDelaySamples
        #expect(delay > 0, "Splitter group delay must be > 0 (FIR is configured)")

        let frames = 16384
        let signal = makeProgramSignal(frames: frames)
        var summed = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let bands = splitter.process(left: signal[i], right: signal[i])
            summed[i] = bands.0.0 + bands.1.0 + bands.2.0 + bands.3.0 + bands.4.0
        }

        var sumSqErr: Double = 0
        var sumSqRef: Double = 0
        let warm = max(delay * 4, 1024)
        for i in warm..<(frames - 1) {
            let ref = signal[i - delay]
            let err = summed[i] - ref
            sumSqErr += Double(err * err)
            sumSqRef += Double(ref * ref)
        }
        let errDB = 10.0 * log10(sumSqErr / max(sumSqRef, 1e-30))
        print(String(format: "5-band sum-to-flat reconstruction error: %.1f dB", errDB))
        #expect(errDB < -60.0,
            "5-band splitter must reconstruct delayed input within -60 dB; got \(errDB) dB")
    }

    @Test func threeBandSplitterSumsToFlatDelayedInput() {
        var splitter = LinearPhaseMultibandSplitter3()
        splitter.configure(lowHz: 320.0, highHz: 2550.0, sampleRate: sampleRate)
        let delay = splitter.groupDelaySamples
        #expect(delay > 0)

        let frames = 16384
        let signal = makeProgramSignal(frames: frames)
        var summed = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let bands = splitter.process(left: signal[i], right: signal[i])
            summed[i] = bands.0.0 + bands.1.0 + bands.2.0
        }

        var sumSqErr: Double = 0
        var sumSqRef: Double = 0
        let warm = max(delay * 4, 1024)
        for i in warm..<(frames - 1) {
            let ref = signal[i - delay]
            let err = summed[i] - ref
            sumSqErr += Double(err * err)
            sumSqRef += Double(ref * ref)
        }
        let errDB = 10.0 * log10(sumSqErr / max(sumSqRef, 1e-30))
        print(String(format: "3-band sum-to-flat reconstruction error: %.1f dB", errDB))
        #expect(errDB < -60.0,
            "3-band splitter must reconstruct delayed input within -60 dB; got \(errDB) dB")
    }

    // MARK: - Latency

    /// The whole point of the 0.45 redesign: the default crossovers must fit
    /// the 12 ms audio-domain budget (measured 9.3 ms), and the design must
    /// not sit on the 2049-tap clamp (which silently distorts the design).
    @Test func defaultCrossoversStayInsideTheLatencyBudget() {
        let splitter = makeFiveBand()
        let delayMS = Float(splitter.groupDelaySamples) * 1_000.0 / sampleRate
        print(String(format: "5-band splitter group delay: %d samples = %.2f ms at 48 kHz", splitter.groupDelaySamples, delayMS))
        #expect(delayMS < 12.0, "splitter latency \(delayMS) ms exceeds the 12 ms audio-domain budget")
        #expect(splitter.groupDelaySamples < 1_024, "design is sitting on the 2049-tap clamp")
    }

    // MARK: - Crossover shape

    /// -6 dB at every crossover, split evenly between the two adjacent bands:
    /// a tone at fc must appear at half amplitude in both. The pre-0.45
    /// design (Kaiser centred at fc + transition/2) put the -6 dB point
    /// above the nominal crossover.
    @Test func crossoversSitAtMinusSixDecibels() {
        for (k, fc) in crossovers.enumerated() {
            var splitter = makeFiveBand()
            let frames = 1 << 15
            var lower = [Float](repeating: 0, count: frames)
            var upper = [Float](repeating: 0, count: frames)
            let w = 2.0 * Double.pi * Double(fc) / Double(sampleRate)
            for i in 0..<frames {
                let x = Float(sin(w * Double(i)))
                let b = splitter.process(left: x, right: x)
                let bands = [b.0.0, b.1.0, b.2.0, b.3.0, b.4.0]
                lower[i] = bands[k]
                upper[i] = bands[k + 1]
            }
            let lowDB = dB(amplitude(lower, hz: fc))
            let highDB = dB(amplitude(upper, hz: fc))
            print(String(format: "crossover %.0f Hz: band %d %.2f dB, band %d %.2f dB", fc, k + 1, lowDB, k + 2, highDB))
            #expect(abs(lowDB + 6.0) < 0.5, "band \(k + 1) at \(Int(fc)) Hz is \(lowDB) dB, expected -6")
            #expect(abs(highDB + 6.0) < 0.5, "band \(k + 2) at \(Int(fc)) Hz is \(highDB) dB, expected -6")
        }
    }

    // MARK: - Time alignment

    @Test func fiveBandImpulseResponseIsTimeAligned() {
        var splitter = makeFiveBand()
        let delay = splitter.groupDelaySamples
        let frames = max(delay * 3, 2048)

        var bands = [[Float]](repeating: [Float](repeating: 0, count: frames), count: 5)
        for i in 0..<frames {
            let x: Float = i == 0 ? 1.0 : 0.0
            let b = splitter.process(left: x, right: x)
            bands[0][i] = b.0.0
            bands[1][i] = b.1.0
            bands[2][i] = b.2.0
            bands[3][i] = b.3.0
            bands[4][i] = b.4.0
        }

        func peakIdx(_ a: [Float]) -> Int {
            var best = 0
            var bestAbs: Float = 0
            for (i, v) in a.enumerated() where abs(v) > bestAbs {
                bestAbs = abs(v)
                best = i
            }
            return best
        }
        let peaks = bands.map(peakIdx)
        print("Impulse-response peaks per band: \(peaks); group delay: \(delay)")
        let minPeak = peaks.min() ?? 0
        let maxPeak = peaks.max() ?? 0
        #expect(maxPeak - minPeak <= 2,
            "All bands' impulse-response peaks must coincide within 2 samples; got peaks \(peaks)")
    }

    /// Pre-ringing when adjacent bands carry different gains -- the audible
    /// cost of a linear-phase crossover. Recombine with band 5 at half gain
    /// (a 6 dB inter-band disparity, more than the profiles ever apply) and
    /// measure the energy that arrives before the main lobe. The pre-0.45
    /// 85 Hz brick wall at 6.8 kHz rang for ~12 ms.
    @Test func preRingingWithABandGainDisparityIsBounded() {
        var splitter = makeFiveBand()
        let delay = splitter.groupDelaySamples
        let frames = delay * 2 + 64
        var out = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let x: Float = i == 0 ? 1.0 : 0.0
            let b = splitter.process(left: x, right: x)
            out[i] = b.0.0 + b.1.0 + b.2.0 + b.3.0 + (0.5 * b.4.0)
        }
        var total = 0.0
        var early = 0.0
        var earliest = frames
        for i in 0..<frames {
            let e = Double(out[i] * out[i])
            total += e
            if i < delay - 8 {
                early += e
                if abs(out[i]) > 1e-3, i < earliest { earliest = i }
            }
        }
        let preRingDB = 10.0 * log10(max(1e-30, early) / max(1e-30, total))
        let preRingMS = earliest < frames ? Float(delay - earliest) * 1_000.0 / sampleRate : 0.0
        print(String(format: "pre-ringing (band 5 at -6 dB): %.1f dB of the energy before the main lobe, first > -60 dB sample %.2f ms early", preRingDB, preRingMS))
        #expect(preRingDB < -20.0, "pre-ringing energy \(preRingDB) dB is too high")
        #expect(preRingMS < 3.0, "pre-ringing starts \(preRingMS) ms before the main lobe")
    }

    // MARK: - Frequency response sanity

    @Test func fiveBandSpectralAssignmentRespectsCrossovers() {
        // Pure-tone test: feed a 1 kHz tone, expect band 3 (350-1800 Hz)
        // to carry it. Other bands should be down by >20 dB.
        var splitter = makeFiveBand()
        let delay = splitter.groupDelaySamples
        let frames = max(delay * 4, 8192)
        let w = 2.0 * Double.pi * 1000.0 / Double(sampleRate)

        var sums = [Float](repeating: 0, count: 5)
        for i in 0..<frames {
            let x = Float(sin(w * Double(i)))
            let b = splitter.process(left: x, right: x)
            if i > delay * 2 {
                sums[0] += b.0.0 * b.0.0
                sums[1] += b.1.0 * b.1.0
                sums[2] += b.2.0 * b.2.0
                sums[3] += b.3.0 * b.3.0
                sums[4] += b.4.0 * b.4.0
            }
        }
        let dominant = sums.max() ?? 0
        let dominantBand = sums.firstIndex(of: dominant) ?? -1
        print("1 kHz energy per band: \(sums.map { String(format: "%.4f", $0) })")
        #expect(dominantBand == 2,
            "1 kHz tone must land predominantly in band 3 (350-1800 Hz); got band \(dominantBand + 1)")
        let totalEnergy = sums.reduce(0, +)
        let dominantFraction = Double(dominant) / Double(max(totalEnergy, 1e-12))
        #expect(dominantFraction > 0.8,
            "Dominant band must hold >80% of 1 kHz energy; got \(dominantFraction)")
    }
}
