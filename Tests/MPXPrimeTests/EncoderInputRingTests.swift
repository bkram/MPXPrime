import Foundation
import Testing
import MPXPrimeCore
@testable import MPXPrime

/// The input ring's adaptive (resampling) read path: block-edge continuity,
/// passband flatness of the 48 -> 192 -> 48 kHz round trip the macOS engine
/// runs on a 48 kHz input device, and subcarrier fidelity when the Linux
/// monitor pushes the raw composite through a clock-trimming read
/// (encoder review 2026-10, findings 2, 3 and 9).
@Suite("Encoder input ring resampling")
struct EncoderInputRingTests {
    /// Reads `blocks` blocks of `frameCount` frames, `nominal` input frames
    /// each, with a deadband so wide the clock trim never engages (the step
    /// stays exactly `nominal / frameCount`).
    private static func readBlocks(
        ring: StereoInputRingBuffer, blocks: Int, frameCount: Int, nominal: Int
    ) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(blocks * frameCount)
        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)
        for _ in 0..<blocks {
            _ = left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    ring.readAdaptive(
                        intoLeft: l.baseAddress!, outRight: r.baseAddress!,
                        frameCount: frameCount, nominalConsume: nominal,
                        targetBuffered: 1, deadband: 10_000_000)
                }
            }
            out.append(contentsOf: left)
        }
        return out
    }

    private static func filledRing(_ source: [Float], capacity: Int) -> StereoInputRingBuffer {
        let ring = StereoInputRingBuffer(capacityFrames: capacity)
        source.withUnsafeBufferPointer { ring.writeMono(mono: $0.baseAddress!, frameCount: source.count) }
        return ring
    }

    private static func rmsDB(_ x: ArraySlice<Float>) -> Double {
        let power = x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count))
        return 10.0 * log10(max(power, 1e-300))
    }

    /// Finding 2: the old Catmull-Rom read clamped its outer neighbours at
    /// every block edge (the previous frame was already consumed, the next one
    /// not yet fetched), so a block-wise read differed from one long read by
    /// products at the block rate (-45 dBc at 10 kHz). The read must not
    /// depend on where the blocks fall.
    @Test func blockwiseReadEqualsOneContinuousRead() {
        let fs = 48_000.0
        let source = (0..<8_192).map { Float(0.5 * sin(2.0 * Double.pi * 10_000.0 * Double($0) / fs)) }
        let blockwise = Self.readBlocks(
            ring: Self.filledRing(source, capacity: 16_384), blocks: 48, frameCount: 512, nominal: 128)
        let continuous = Self.readBlocks(
            ring: Self.filledRing(source, capacity: 16_384), blocks: 1, frameCount: 24_576, nominal: 6_144)
        let difference = zip(blockwise, continuous).map { $0 - $1 }
        let errorDB = Self.rmsDB(difference[...]) - Self.rmsDB(continuous[...])
        #expect(errorDB < -120.0, "block-edge error \(errorDB) dBc")
    }

    /// Finding 2/3: against the ideal band-limited signal, the 4x read of a
    /// 10 kHz tone at 48 kHz is clean (the old interpolator: -45 dBc).
    @Test func fourTimesReadMatchesTheIdealSine() {
        let fs = 48_000.0
        let f = 10_000.0
        let source = (0..<8_192).map { Float(0.5 * sin(2.0 * Double.pi * f * Double($0) / fs)) }
        let out = Self.readBlocks(
            ring: Self.filledRing(source, capacity: 16_384), blocks: 48, frameCount: 512, nominal: 128)
        // Skip the start-up (the history before the first frame is silence).
        let ideal = (0..<out.count).map { Float(0.5 * sin(2.0 * Double.pi * f * Double($0) * 0.25 / fs)) }
        let range = 1_024..<out.count
        let error = range.map { out[$0] - ideal[$0] }
        let errorDB = Self.rmsDB(error[...]) - Self.rmsDB(ideal[range])
        #expect(errorDB < -75.0, "interpolation error \(errorDB) dBc")
    }

    /// Finding 3: a 48 kHz input device on macOS goes 48 -> 192 kHz through
    /// this read and straight back to 48 kHz through the dual-rate decimator.
    /// The old interpolator drooped -0.28 dB at 10 kHz and -1.23 dB at 15 kHz
    /// ahead of the whole chain.
    @Test func roundTripThroughTheDualRateDecimatorIsFlat() {
        let fsIn = 48_000.0
        for f in [1_000.0, 10_000.0, 15_000.0, 18_000.0] {
            let source = (0..<16_384).map { Float(0.5 * sin(2.0 * Double.pi * f * Double($0) / fsIn)) }
            let upsampled = Self.readBlocks(
                ring: Self.filledRing(source, capacity: 32_768), blocks: 120, frameCount: 512, nominal: 128)
            // The engine's own boundary decimator (MPXGenerator.configureDualRateBoundary).
            var decimator = LinearPhaseFIRDecimator()
            decimator.configure(
                cutoffHz: 48_000.0 * 0.5 * 0.9, sampleRateOS: 192_000.0, decimateFactor: 4,
                stopBandDB: 90.0, transitionHz: 4_000.0)
            var decimated: [Float] = []
            for (i, x) in upsampled.enumerated() {
                let y = decimator.push(x)
                if i % 4 == 3 { decimated.append(y) }
            }
            // 4800 output samples = 0.1 s: an integer number of cycles at
            // every test frequency, so the projection is leak-free.
            let window = decimated[(decimated.count - 4_800 - 1_000)..<(decimated.count - 1_000)]
            var s = 0.0
            var c = 0.0
            for (n, x) in window.enumerated() {
                let phase = 2.0 * Double.pi * f * Double(n) / fsIn
                s += Double(x) * sin(phase)
                c += Double(x) * cos(phase)
            }
            let amplitude = 2.0 * sqrt(s * s + c * c) / Double(window.count)
            let gainDB = 20.0 * log10(amplitude / 0.5)
            #expect(abs(gainDB) < 0.01, "\(Int(f)) Hz round-trip gain \(gainDB) dB")
        }
    }

    /// Finding 9: the Linux monitor puts the raw COMPOSITE through this read,
    /// and while the monitor clock is trimmed the fraction sweeps slowly. The
    /// interpolator must carry the 38 kHz subcarrier and the 19 kHz pilot with
    /// the same fidelity at every fraction, or the decoded separation follows
    /// the fraction (the old read: 62 down to 32 dB).
    @Test func compositeSurvivesAClockTrimmingRead() {
        let fs = 192_000.0
        func composite(_ t: Double) -> Double {
            let theta = 2.0 * Double.pi * 19_000.0 * t
            let left = 0.8 * sin(2.0 * Double.pi * 1_000.0 * t)
            let rds = 0.03 * sin(3.0 * theta) * cos(2.0 * Double.pi * 1_187.5 * t)
            return left / 2.0 + left / 2.0 * sin(2.0 * theta) + 0.09 * sin(theta) + rds
        }
        let source = (0..<120_000).map { Float(composite(Double($0) / fs)) }
        // Step 1.0003: what a 300 ppm clock offset makes the trim do.
        let out = Self.readBlocks(
            ring: Self.filledRing(source, capacity: 131_072), blocks: 11, frameCount: 10_000, nominal: 10_003)
        let range = 1_000..<out.count
        let error = range.map { out[$0] - Float(composite(Double($0) * 1.0003 / fs)) }
        let ideal = range.map { Float(composite(Double($0) * 1.0003 / fs)) }
        let errorDB = Self.rmsDB(error[...]) - Self.rmsDB(ideal[...])
        #expect(errorDB < -70.0, "composite error \(errorDB) dBc")
    }
}
