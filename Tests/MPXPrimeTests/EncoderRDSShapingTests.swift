import Foundation
import Testing
@testable import MPXPrime

/// RDS symbol shaping (encoder review 2026-10, findings 7, 8
/// and 10): the spectrum must not depend on the render rate, the level
/// reference is the all-zeros stream EN 50067 sec 1.4 defines, and the
/// overlap-add emits every kernel tap on time.
@Suite("Encoder RDS shaping")
struct EncoderRDSShapingTests {
    static let bitrate = 1_187.5

    static func kernel(_ sampleRate: Float) -> [Float] {
        BasicRDSCoder.makeShapingKernel(
            sampleRate: sampleRate, gaussianEnabled: true, gaussianBandwidthHz: 2_400, gaussianTaps: 81)
    }

    /// Share of the random-data RDS baseband power above `edgeHz`, in dB.
    /// Random biphase data has the power spectrum |H(f)|^2 |2 sin(pi f td / 2)|^2
    /// (the +1 / -1 impulse pair half a bit apart), H the shaping kernel.
    static func outOfBandShareDB(kernel: [Float], sampleRate: Float, edgeHz: Double) -> Double {
        let fs = Double(sampleRate)
        let td = 1.0 / bitrate
        var inBand = 0.0
        var outOfBand = 0.0
        var f = 5.0
        while f < 30_000.0 {
            var re = 0.0
            var im = 0.0
            for (n, h) in kernel.enumerated() {
                let w = 2.0 * Double.pi * f * Double(n) / fs
                re += Double(h) * cos(w)
                im -= Double(h) * sin(w)
            }
            let pair = 2.0 * sin(Double.pi * f * td / 2.0)
            let power = (re * re + im * im) * pair * pair
            if f > edgeHz { outOfBand += power } else { inBand += power }
            f += 10.0
        }
        return 10.0 * log10(outOfBand / (inBand + outOfBand))
    }

    @Test func spectrumIsRateIndependent() {
        var shares: [Float: Double] = [:]
        for rate: Float in [176_400, 192_000, 228_000, 384_000] {
            shares[rate] = Self.outOfBandShareDB(kernel: Self.kernel(rate), sampleRate: rate, edgeHz: 3_500)
        }
        let reference = shares[192_000] ?? 0
        for (rate, share) in shares {
            #expect(share < -70.0, "\(Int(rate)) Hz: RDS power above 3.5 kHz \(share) dB")
            #expect(abs(share - reference) < 3.0, "\(Int(rate)) Hz: \(share) dB vs 192 kHz \(reference) dB")
        }
    }

    @Test func tapCountsAreUnchangedAt192kAndScaleWithTheRate() {
        #expect(BasicRDSCoder.rateScaledTapCount(301, sampleRate: 192_000) == 301)
        #expect(BasicRDSCoder.rateScaledTapCount(81, sampleRate: 192_000) == 81)
        #expect(BasicRDSCoder.rateScaledTapCount(301, sampleRate: 384_000) == 603)
        #expect(BasicRDSCoder.rateScaledTapCount(81, sampleRate: 384_000) == 163)
        #expect(BasicRDSCoder.rateScaledTapCount(81, sampleRate: 384_000) % 2 == 1)
    }

    /// Finding 8: all-zeros data (the differential bit constant), shaped by
    /// the coder's kernel and divided by the coder's level reference, peaks at
    /// exactly 1 -- so `rds_level` is the peak deviation of that stream. The
    /// all-ones reference read 0.18 dB low and put 2.04 kHz on air for 2.0.
    @Test func allZerosStreamPeaksAtTheConfiguredLevel() {
        for rate: Float in [192_000, 228_000] {
            let kernel = Self.kernel(rate)
            let reference = BasicRDSCoder.estimateShapingPeak(kernel: kernel, sampleRate: rate)
            // Independent all-zeros stream: +1 at every bit start, -1 at every
            // mid-bit, on the sample grid, convolved directly.
            let fs = Double(rate)
            let count = 40_000
            var impulses = [Double](repeating: 0, count: count)
            var bit = 0
            while true {
                let start = Int((Double(bit) * fs / Self.bitrate).rounded(.up))
                let mid = Int(((Double(bit) + 0.5) * fs / Self.bitrate).rounded(.up))
                guard mid < count else { break }
                impulses[start] -= 1.0
                impulses[mid] += 1.0
                bit += 1
            }
            var peak = 0.0
            for n in (kernel.count * 2)..<(count - kernel.count) {
                var y = 0.0
                for (k, h) in kernel.enumerated() { y += Double(h) * impulses[n - k] }
                peak = max(peak, abs(y))
            }
            let errorDB = 20.0 * log10(peak / Double(reference))
            #expect(abs(errorDB) < 0.02, "\(Int(rate)) Hz: all-zeros peak \(errorDB) dB off the reference")
        }
    }

    /// Finding 10: one impulse through the overlap-add comes out as the
    /// kernel, starting at once and ending after `kernel.count` samples --
    /// nothing a buffer later.
    @Test func overlapAddEmitsEveryTapOnTime() {
        let kernel = Self.kernel(192_000)
        var ola = [Float](repeating: 0, count: max(4_096, kernel.count * 8))
        var index = 0
        var out: [Float] = []
        for n in 0..<(ola.count * 2) {
            out.append(BasicRDSCoder.nextShapingSampleLocal(
                impulse: n == 0 ? 1.0 : 0.0, kernel: kernel, overlapAdd: &ola, index: &index))
        }
        for k in 0..<kernel.count {
            #expect(out[k] == kernel[k], "tap \(k)")
        }
        let late = out[kernel.count...].map { abs($0) }.max() ?? 0
        #expect(late == 0, "late output \(late)")
    }
}
