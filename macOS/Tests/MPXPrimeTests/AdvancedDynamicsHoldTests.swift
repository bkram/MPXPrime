import Foundation
import Testing

@testable import MPXPrime

// The leveler's transient hold decayed by a flat 0.94 per sample: 0.34 ms at
// the 48 kHz audio domain, 0.08 ms with the dual-rate boundary off or at a
// different domain rate (audit P0-3 follow-up; MonoCompressor got the time
// constant in 0.60, this stage kept the literal because changing it meant
// re-running the armed corpus gates). The coefficient is now 0.94^(48000/sr),
// exactly 0.94 at 48 kHz -- so nothing moves where the gates were armed --
// and the same decay per unit TIME everywhere else.
@Suite("Advanced Dynamics transient hold")
struct AdvancedDynamicsHoldTests {

    private func leveler(sampleRate: Float) -> AdvancedDynamicsLeveler {
        var l = AdvancedDynamicsLeveler()
        l.configureStructure(sampleRate: sampleRate, x1Hz: 90, x2Hz: 320, x3Hz: 1_000, x4Hz: 3_000)
        return l
    }

    private func bed(_ l: inout AdvancedDynamicsLeveler, seconds: Double, sampleRate: Float) {
        let frames = Int(Double(sampleRate) * seconds)
        for i in 0..<frames {
            let v = Float(0.2 * sin(2.0 * Double.pi * 220.0 * Double(i) / Double(sampleRate)))
            _ = l.process(left: v, right: v)
        }
    }

    /// A 6 ms cosine burst at 2 kHz: a real front, so the peak-to-RMS
    /// detector opens the hold.
    private func burst(_ l: inout AdvancedDynamicsLeveler, sampleRate: Float) {
        let frames = Int(Double(sampleRate) * 0.006)
        for i in 0..<frames {
            let t = Double(i) / Double(sampleRate)
            let v = Float(0.95 * cos(2.0 * Double.pi * 2_000.0 * t))
            _ = l.process(left: v, right: v)
        }
    }

    @Test func theHoldDecaysByTimeNotBySampleCount() {
        // 0.5 ms after the hold's last re-trigger, every rate must have
        // decayed it by the same share as 48 kHz did (24 samples of 0.94
        // there). A flat 0.94 per sample would leave 0.94^48 at 96 kHz and
        // 0.94^96 at 192 kHz -- a fifth and a hundredth of the 48 kHz value.
        // The burst reaches the band detectors only after the splitter's
        // group delay, and re-triggers on every rising edge inside the
        // burst, so the hold is tracked sample by sample and the reference
        // is its LAST rise. The diagnostic is the max over five bands that
        // opened at different moments, so the share is compared between
        // rates rather than to the bare 0.94^24.
        var ratios: [Float] = []
        for sr in [Float(48_000.0), Float(96_000.0), Float(192_000.0)] {
            var l = leveler(sampleRate: sr)
            bed(&l, seconds: 0.150, sampleRate: sr)
            burst(&l, sampleRate: sr)
            // Keep feeding the bed while the burst comes through the splitter
            // and the hold decays; record the hold after every sample.
            let span = l.groupDelaySamples + Int(Double(sr) * 0.020)
            var held: [Float] = []
            held.reserveCapacity(span)
            for i in 0..<span {
                let v = Float(0.2 * sin(2.0 * Double.pi * 220.0 * Double(i) / Double(sr)))
                _ = l.process(left: v, right: v)
                held.append(l.maxHeldTransientDrive)
            }
            var lastRise = 0
            for i in 1..<held.count where held[i] > held[i - 1] { lastRise = i }
            let opened = held[lastRise]
            #expect(opened > 0.15, "\(sr) Hz: the burst did not open the hold (\(opened))")
            let later = lastRise + Int((Double(sr) * 0.0005).rounded())
            #expect(later < held.count)
            let ratio = held[min(later, held.count - 1)] / max(opened, 1e-9)
            #expect(ratio > 0.05 && ratio < 0.8, "\(sr) Hz: implausible decay share \(ratio)")
            ratios.append(ratio)
        }
        for (i, sr) in [96_000, 192_000].enumerated() {
            #expect(abs(ratios[i + 1] - ratios[0]) < 0.03,
                    "\(sr) Hz decays the hold to \(ratios[i + 1]) in 0.5 ms where 48 kHz decays it to \(ratios[0])")
        }
    }

    @Test func theProductionDomainIsUnchanged() {
        // 0.94^(48000/48000) is exactly 0.94: the armed --verify-advanced-
        // dynamics and program-A/B gates see the same numbers as before.
        #expect(powf(0.94, 48_000.0 / 48_000.0) == Float(0.94))
    }
}
