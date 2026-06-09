import Foundation
import Testing

@testable import MPXPrime

// Unit tests for the pre-emphasis-aware HF clipper core (step 1: isolated, not
// yet wired into the chain). Proves the band split + oversampled HF soft-clip
// behaves -- HF transients reduced, low band left alone, and disabled is an
// exact passthrough (the bit-identical guarantee for the future chain wiring).
@Suite struct HFClipperTests {

    private func rms(_ xs: [Float]) -> Float {
        guard !xs.isEmpty else { return 0 }
        var s: Float = 0
        for x in xs { s += x * x }
        return sqrtf(s / Float(xs.count))
    }

    @Test func disabledIsExactPassthrough() {
        var hf = HFClipper()
        hf.configure(enabled: false, sampleRate: 192_000, crossoverHz: 5_000,
                     thresholdDB: -6, drive: 2.0)
        for n in 0..<256 {
            let s = sinf(2.0 * Float.pi * 9_000 * Float(n) / 192_000)
            let (l, r) = hf.process(left: s, right: s * 0.5)
            #expect(l == s)
            #expect(r == s * 0.5)
        }
    }

    @Test func reducesHotHFBandPeak() {
        var hf = HFClipper()
        hf.configure(enabled: true, sampleRate: 192_000, crossoverHz: 5_000,
                     thresholdDB: -6, drive: 2.0)
        // Hot 10 kHz tone (above the 5 kHz crossover) at full scale -> the HF
        // band is driven well past threshold, so the clipped output peak must
        // sit clearly below the input peak.
        var maxOut: Float = 0
        for n in 0..<3_000 {
            let s = sinf(2.0 * Float.pi * 10_000 * Float(n) / 192_000)
            let (l, _) = hf.process(left: s, right: s)
            if n > 800 { maxOut = max(maxOut, fabsf(l)) }
        }
        #expect(maxOut < 0.9)
    }

    @Test func lowBandLargelyPreserved() {
        var hf = HFClipper()
        hf.configure(enabled: true, sampleRate: 192_000, crossoverHz: 5_000,
                     thresholdDB: -6, drive: 2.0)
        // A 1 kHz tone is in the low band, which the HF clipper leaves alone, so
        // output RMS should track input RMS closely (allowing LR4 / decimation
        // tolerance).
        var ins: [Float] = []
        var outs: [Float] = []
        for n in 0..<3_000 {
            let s = 0.8 * sinf(2.0 * Float.pi * 1_000 * Float(n) / 192_000)
            let (l, _) = hf.process(left: s, right: s)
            if n > 800 { ins.append(s); outs.append(l) }
        }
        let ri = rms(ins)
        let ro = rms(outs)
        #expect(ri > 0.01)
        #expect(abs(ro - ri) / ri < 0.1)
    }
}
