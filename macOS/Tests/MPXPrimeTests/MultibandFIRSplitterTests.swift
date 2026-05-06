import Testing
import Foundation
@testable import MPXPrime

// Linear-phase FIR multiband crossover tests.
//
// The load-bearing assertion for these splitters is **sum-to-flat**: when
// the bands are summed back, the result must equal the input delayed by
// `groupDelaySamples` to within the numerical noise floor. This is the
// property that makes phase-coherent multiband possible — IIR LR4 only
// gives sum-to-allpass (magnitude-flat with phase rotation), which is why
// transients smear when bands compress independently.
//
// If this test fails the FIR splitter has a design bug and the multiband
// chain in TX mode is broken.

@Suite("Multiband FIR splitter")
struct MultibandFIRSplitterTests {

    private let sampleRate: Float = 192_000.0

    // MARK: - Test signals

    /// Deterministic broadband test signal — mix of audio-band sines and
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
            // Splittable mix LFSR pseudo-noise + tones.
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let n = Float(Int64(bitPattern: rng) >> 32) / Float(Int32.max) * 0.05
            let t = Double(i)
            out[i] = Float(0.20 * sin(w1 * t) + 0.18 * sin(w2 * t) +
                          0.16 * sin(w3 * t) + 0.14 * sin(w4 * t) +
                          0.12 * sin(w5 * t)) + n
        }
        return out
    }

    // MARK: - 5-band sum-to-flat

    @Test func fiveBandSplitterSumsToFlatDelayedInput() {
        var splitter = LinearPhaseMultibandSplitter5()
        splitter.configure(
            x1Hz: 90.0, x2Hz: 350.0, x3Hz: 1800.0, x4Hz: 6800.0,
            sampleRate: sampleRate,
            stopBandDB: 60.0, transitionHz: 1500.0
        )
        let delay = splitter.groupDelaySamples
        #expect(delay > 0, "Splitter group delay must be > 0 (FIR is configured)")

        let frames = 16384
        let signal = makeProgramSignal(frames: frames)
        var summed = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let bands = splitter.process(left: signal[i], right: signal[i])
            // Sum all 5 bands of the LEFT channel; right is identical here.
            summed[i] = bands.0.0 + bands.1.0 + bands.2.0 + bands.3.0 + bands.4.0
        }

        // Reconstruction error is `summed[i] - signal[i - delay]`. Compare
        // post-warmup (skip first 2× the FIR length so steady-state is
        // reached). Error floor should be very deep — dominant error is
        // the FIR's stop-band attenuation in the differencing math.
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
        splitter.configure(
            lowHz: 320.0, highHz: 2550.0,
            sampleRate: sampleRate,
            stopBandDB: 60.0, transitionHz: 1500.0
        )
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

    // MARK: - Time alignment

    @Test func fiveBandImpulseResponseIsTimeAligned() {
        // Feed an impulse, check that every band's peak sample lands at
        // the SAME index. With IIR LR4, this would not hold — each band
        // would peak at slightly different sample indices.
        var splitter = LinearPhaseMultibandSplitter5()
        splitter.configure(
            x1Hz: 90.0, x2Hz: 350.0, x3Hz: 1800.0, x4Hz: 6800.0,
            sampleRate: sampleRate,
            stopBandDB: 60.0, transitionHz: 1500.0
        )
        let delay = splitter.groupDelaySamples
        let frames = max(delay * 3, 2048)

        var b1 = [Float](repeating: 0, count: frames)
        var b2 = [Float](repeating: 0, count: frames)
        var b3 = [Float](repeating: 0, count: frames)
        var b4 = [Float](repeating: 0, count: frames)
        var b5 = [Float](repeating: 0, count: frames)

        for i in 0..<frames {
            let x: Float = i == 0 ? 1.0 : 0.0
            let bands = splitter.process(left: x, right: x)
            b1[i] = bands.0.0
            b2[i] = bands.1.0
            b3[i] = bands.2.0
            b4[i] = bands.3.0
            b5[i] = bands.4.0
        }

        // For each band, find the index of maximum |amplitude|. They
        // should all coincide at `delay`.
        func peakIdx(_ a: [Float]) -> Int {
            var best = 0
            var bestAbs: Float = 0
            for (i, v) in a.enumerated() {
                let av = abs(v)
                if av > bestAbs { bestAbs = av; best = i }
            }
            return best
        }
        let peaks = [peakIdx(b1), peakIdx(b2), peakIdx(b3), peakIdx(b4), peakIdx(b5)]
        print("Impulse-response peaks per band: \(peaks); group delay: \(delay)")
        // Lower bands have wider transition windows so the peak might
        // sit a couple samples either side of `delay`. Tighten only the
        // band-to-band consistency: every band's peak within ±2 samples
        // of every other band.
        let minPeak = peaks.min() ?? 0
        let maxPeak = peaks.max() ?? 0
        #expect(maxPeak - minPeak <= 2,
            "All bands' impulse-response peaks must coincide within 2 samples; got peaks \(peaks)")
    }

    // MARK: - Frequency response sanity

    @Test func fiveBandSpectralAssignmentRespectsCrossovers() {
        // Pure-tone test: feed a 1 kHz tone, expect band 3 (350-1800 Hz)
        // to carry it. Other bands should be down by >20 dB.
        var splitter = LinearPhaseMultibandSplitter5()
        splitter.configure(
            x1Hz: 90.0, x2Hz: 350.0, x3Hz: 1800.0, x4Hz: 6800.0,
            sampleRate: sampleRate,
            stopBandDB: 60.0, transitionHz: 800.0
        )
        let delay = splitter.groupDelaySamples
        let frames = max(delay * 4, 8192)
        let w = 2.0 * Double.pi * 1000.0 / Double(sampleRate)

        var b1Sum: Float = 0
        var b2Sum: Float = 0
        var b3Sum: Float = 0
        var b4Sum: Float = 0
        var b5Sum: Float = 0

        for i in 0..<frames {
            let x = Float(sin(w * Double(i)))
            let bands = splitter.process(left: x, right: x)
            // Skip warmup; accumulate squared magnitudes after.
            if i > delay * 2 {
                b1Sum += bands.0.0 * bands.0.0
                b2Sum += bands.1.0 * bands.1.0
                b3Sum += bands.2.0 * bands.2.0
                b4Sum += bands.3.0 * bands.3.0
                b5Sum += bands.4.0 * bands.4.0
            }
        }
        let allBands: [Float] = [b1Sum, b2Sum, b3Sum, b4Sum, b5Sum]
        let dominant = allBands.max() ?? 0
        let dominantBand = allBands.firstIndex(of: dominant) ?? -1
        print("1 kHz energy per band: \(allBands.map { String(format: "%.4f", $0) })")
        #expect(dominantBand == 2,
            "1 kHz tone must land predominantly in band 3 (350-1800 Hz); got band \(dominantBand + 1)")
        // The dominant band should hold ≥80% of the energy (allowing for
        // crossover transition leakage).
        let totalEnergy = allBands.reduce(0, +)
        let dominantFraction = Double(dominant) / Double(max(totalEnergy, 1e-12))
        #expect(dominantFraction > 0.8,
            "Dominant band must hold >80% of 1 kHz energy; got \(dominantFraction)")
    }
}
