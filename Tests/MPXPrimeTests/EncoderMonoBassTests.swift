import Foundation
import Testing
@testable import MPXPrime

/// Mono bass (`MonoBassFilter`): the side is highpassed, the mid only phase-
/// shifted, and the two stay phase-matched above the corner
/// (levelling review 2026-10, finding 1: the old `side - LP2(side)` was
/// -4.1 dB at 60 Hz, +0.1 dB at 100 Hz and +1.8 dB at the 140 Hz corner).
@Suite("Encoder mono bass")
struct EncoderMonoBassTests {
    static let sampleRate: Float = 48_000.0
    static let corner: Float = 140.0

    /// Complex response (left, right outputs) to a unit sine at `hz` on the
    /// given input channels, after one second of settling, over one second.
    static func response(hz: Double, left: Double, right: Double) -> (left: Double, right: Double) {
        var filter = MonoBassFilter()
        filter.configure(cutoffHz: corner, sampleRate: sampleRate)
        let fs = Double(sampleRate)
        let n = Int(fs)
        var ls = 0.0, lc = 0.0, rs = 0.0, rc = 0.0
        for i in 0..<(2 * n) {
            let x = sin(2.0 * Double.pi * hz * Double(i) / fs)
            let out = filter.process(left: Float(left * x), right: Float(right * x))
            guard i >= n else { continue }
            let phase = 2.0 * Double.pi * hz * Double(i) / fs
            ls += Double(out.0) * sin(phase)
            lc += Double(out.0) * cos(phase)
            rs += Double(out.1) * sin(phase)
            rc += Double(out.1) * cos(phase)
        }
        let scale = 2.0 / Double(n)
        return ((ls * ls + lc * lc).squareRoot() * scale, (rs * rs + rc * rc).squareRoot() * scale)
    }

    static func dB(_ x: Double) -> Double { 20.0 * log10(max(x, 1e-12)) }

    @Test func sideIsHighpassedAndNeverBoosted() {
        // Pure side input: L = +x, R = -x; the side gain is the left output.
        let expectations: [(hz: Double, low: Double, high: Double)] = [
            (30, -200, -32),
            (60, -200, -30),   // measured -33.2 dB; the old stage: -4.1 dB
            (100, -200, -8),   // the old stage: +0.1 dB
            (140, -6.5, -5.5), // -6 dB at the corner (the old stage: +1.8 dB)
            (250, -0.15, 0.15),
            (1_000, -0.15, 0.15),
            (5_000, -0.15, 0.15),
        ]
        for e in expectations {
            let gain = Self.dB(Self.response(hz: e.hz, left: 1, right: -1).left)
            #expect(gain >= e.low && gain <= e.high, "side gain at \(Int(e.hz)) Hz: \(gain) dB")
        }
        // Never boosted beyond the 40 dB design's +/-0.1 dB ripple (the old
        // stage peaked at +2.1 dB at 179 Hz).
        var hz = 150.0
        while hz < 1_500 {
            let gain = Self.dB(Self.response(hz: hz, left: 1, right: -1).left)
            #expect(gain < 0.15, "side gain at \(Int(hz)) Hz: \(gain) dB")
            hz *= 1.12
        }
    }

    @Test func midIsOnlyDelayed() {
        for hz in [30.0, 60.0, 100.0, 140.0, 179.0, 400.0, 2_000.0, 10_000.0] {
            let gain = Self.dB(Self.response(hz: hz, left: 1, right: 1).left)
            #expect(abs(gain) < 0.001, "mid gain at \(Int(hz)) Hz: \(gain) dB")
        }
    }

    /// Mid and side stay aligned: a left-only input above the corner keeps
    /// the right channel silent (a phase mismatch would leak into it), and a
    /// left-only bass below it becomes centred.
    @Test func leftOnlyStaysLeftAboveTheCorner() {
        for hz in [1_000.0, 5_000.0] {
            let out = Self.response(hz: hz, left: 1, right: 0)
            #expect(Self.dB(out.right) < -45.0, "right leak at \(Int(hz)) Hz: \(Self.dB(out.right)) dB")
            #expect(abs(Self.dB(out.left)) < 0.1, "left gain at \(Int(hz)) Hz: \(Self.dB(out.left)) dB")
        }
        let low = Self.response(hz: 40, left: 1, right: 0)
        #expect(abs(Self.dB(low.left) - Self.dB(low.right)) < 1.0)
    }

    /// The bass keeps its waveform: a mid bass tone comes out as the input
    /// delayed by exactly `groupDelaySamples`, sample for sample.
    @Test func midBassIsAPureDelay() {
        var filter = MonoBassFilter()
        filter.configure(cutoffHz: Self.corner, sampleRate: Self.sampleRate)
        let delay = filter.groupDelaySamples
        var input: [Float] = []
        var output: [Float] = []
        for i in 0..<20_000 {
            let x = Float(0.5 * sin(2.0 * Double.pi * 60.0 * Double(i) / 48_000.0))
            input.append(x)
            output.append(filter.process(left: x, right: x).0)
        }
        let maxError = (delay..<input.count).map { abs(output[$0] - input[$0 - delay]) }.max() ?? 1
        #expect(maxError < 1e-6, "mid error \(maxError)")
    }
}
