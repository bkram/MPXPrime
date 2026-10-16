import Testing
import Foundation
@testable import MPXPrime

// BS.412 ENFORCEMENT through the generator, in the default suite
// (test-suite review 2026-10 finding 2). The generator-level tests in
// `BS412PowerLimiterTests` read the meter, the reserve and the observed
// seconds; the Rig tests drive the rider and guard directly; the only
// enforced-power check (`BS412FullChainTests`) is opt-in. With the gain ride
// `audioComposite *= bs412Rider.gain` removed and `enforcing:` forced false,
// 35 tests stayed green: the limiter could report "enabled" and do nothing.
//
// This renders the real chain with the stage ON and OFF on a programme hot
// enough to need reduction, and measures the multiplex power of the
// RETURNED composite itself (independent arithmetic, not the stage's own
// meter): with the stage on it must be at or below the ceiling over the
// settled second, and well below the stage-off render.
@Suite("BS.412 enforcement through the generator")
struct BS412EnforcementTests {

    private let sampleRate = 192_000.0

    private func config(bs412: Bool, ceilingDBr: Double) -> AppConfig {
        var cfg = AppConfig()
        cfg.sampleRate = sampleRate
        cfg.blockSize = 4096
        cfg.operatingMode = .mpx
        cfg.processingBypass = false
        cfg.enRDS = false            // wall-clock-paced text; not needed for power
        cfg.bs412Enabled = bs412
        cfg.bs412CeilingDBr = ceilingDBr
        cfg.mpxDeviationKHz = 75.0
        cfg.outputGainDB = 0.0
        cfg.pilotLevel = 0.08
        return cfg
    }

    /// Render `seconds` of a hot two-tone programme (L != R so the stereo
    /// subcarrier carries power too) and return the composite.
    private func render(_ cfg: AppConfig, seconds: Double) -> (composite: [Float], status: BS412Status) {
        let generator = MPXGenerator(config: cfg, sampleRate: sampleRate)
        let frames = Int(sampleRate * seconds)
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        let w1 = 2.0 * Double.pi * 440.0 / sampleRate
        let w2 = 2.0 * Double.pi * 1_270.0 / sampleRate
        for i in 0..<frames {
            let t = Double(i)
            left[i] = Float(0.6 * sin(w1 * t) + 0.3 * sin(w2 * t))
            right[i] = Float(0.6 * sin(w1 * t) - 0.3 * sin(w2 * t))
        }
        left.withUnsafeMutableBufferPointer { lb in
            right.withUnsafeMutableBufferPointer { rb in
                var offset = 0
                while offset < frames {
                    let n = min(4096, frames - offset)
                    generator.renderFromInputInPlace(
                        frameCount: n,
                        // swiftlint:disable force_unwrapping
                        left: lb.baseAddress!.advanced(by: offset),
                        right: rb.baseAddress!.advanced(by: offset)
                        // swiftlint:enable force_unwrapping
                    )
                    offset += n
                }
            }
        }
        return (left, generator.bs412Status)
    }

    /// Multiplex power of `samples` in dBr: 0 dBr is the power of a sine at
    /// +/-19 kHz deviation, i.e. amplitude 19/75 with 1.0 = 75 kHz
    /// (ITU-R BS.412-9 sec 2.5; the composite is normalised that way at every
    /// `mpx_deviation_khz`). Computed here from the definition, not with the
    /// stage's meter.
    private func powerDBr(_ samples: ArraySlice<Float>) -> Double {
        var acc = 0.0
        for v in samples { acc += Double(v) * Double(v) }
        let meanSquare = acc / Double(max(1, samples.count))
        let reference = 0.5 * (19.0 / 75.0) * (19.0 / 75.0)
        return 10.0 * log10(max(1e-30, meanSquare) / reference)
    }

    @Test func theEnabledLimiterHoldsTheReturnedCompositeAtTheCeiling() {
        let ceiling = -1.0
        let seconds = 2.0
        let off = render(config(bs412: false, ceilingDBr: ceiling), seconds: seconds)
        let on = render(config(bs412: true, ceilingDBr: ceiling), seconds: seconds)
        // The rider predicts over 1 s with a 0.1 s attack: the last half
        // second of a 2 s render is settled.
        let tail = Int(sampleRate * 0.5)
        let offPower = powerDBr(off.composite.suffix(tail))
        let onPower = powerDBr(on.composite.suffix(tail))
        print(String(format: "BS.412 enforcement: off %+.2f dBr, on %+.2f dBr, ceiling %+.1f dBr, stage GR %.2f dB",
                     offPower, onPower, ceiling, on.status.gainReductionDB))

        // Negative control: the same programme with the stage off is hot and
        // unreduced, or the assertions below prove nothing.
        #expect(offPower > ceiling + 2.0,
                "fixture problem: the programme reads \(offPower) dBr with the stage off, not hot enough to need reduction")
        #expect(off.status.gainReductionDB == 0.0,
                "the disabled stage reports \(off.status.gainReductionDB) dB of reduction")

        #expect(on.status.gainReductionDB > 1.0,
                "the stage reports \(on.status.gainReductionDB) dB of gain reduction on a programme \(offPower - ceiling) dB over the ceiling")
        #expect(onPower <= ceiling + 0.1,
                "the returned composite reads \(onPower) dBr with BS.412 enabled at a \(ceiling) dBr ceiling -- the limiter is not acting on the output")
        #expect(offPower - onPower > 1.0,
                "enabling BS.412 moved the output power by only \(offPower - onPower) dB")
    }
}
