import Testing
import Foundation
@testable import MPXPrime
import MPXPrimeCore

// Reusable FM stereo demodulator robustness tests.
//
// The monitor path feeds live composite samples into MPXDecoder. A single
// non-finite sample (denormal blow-up, upstream glitch) used to poison the
// persistent pilot-lock I/Q and envelope state permanently, since the
// exponential smoothers never flush NaN and every self-heal comparison
// against NaN is false. B2 sanitizes the inputs so the decoder recovers.

@Suite("MPXDecoder robustness")
struct MPXDecoderTests {

    private let sampleRate: Float = 192_000.0

    /// Render an L-only 1 kHz tone through the full MPX encoder so the
    /// decoder sees a realistic pilot-locked composite.
    private func renderLOnlyComposite(frames: Int) -> [Float] {
        var config = AppConfig()
        config.enRDS = false
        config.monoMode = false
        let gen = MPXGenerator(config: config, sampleRate: Double(sampleRate))
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        let omega = 2.0 * Double.pi * 1_000.0 / Double(sampleRate)
        for i in 0..<frames {
            left[i] = Float(0.4 * sin(omega * Double(i)))
            right[i] = 0.0
        }
        var out = [Float](repeating: 0.0, count: frames)
        left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                gen.renderFromInputInPlace(
                    frameCount: frames,
                    left: lBuf.baseAddress!,
                    right: rBuf.baseAddress!
                )
                for i in 0..<frames { out[i] = lBuf[i] }
            }
        }
        return out
    }

    @Test func recoversAfterNonFiniteBurst() {
        let frames = Int(0.5 * sampleRate)
        let mpx = renderLOnlyComposite(frames: frames)

        var decoder = MPXDecoder()
        decoder.configure(sampleRate: sampleRate, preemphasisUS: 50)

        // Decode the first quarter cleanly; output must be finite.
        var preFiniteEnergy = 0.0
        for i in 0..<(frames / 4) {
            let (l, r) = decoder.process(mpx[i], programActivity: 0.4, expectedSide: 0.0)
            #expect(l.isFinite && r.isFinite, "pre-burst output non-finite at \(i)")
            preFiniteEnergy += Double(l * l + r * r)
        }
        #expect(preFiniteEnergy > 0.0, "decoder produced no signal before the burst")

        // Inject a burst of non-finite samples (NaN and Inf).
        for k in 0..<256 {
            let poison: Float = (k % 2 == 0) ? Float.nan : Float.infinity
            let (l, r) = decoder.process(poison, programActivity: 0.4, expectedSide: 0.0)
            #expect(l.isFinite && r.isFinite,
                    "decoder emitted non-finite output during the burst at \(k)")
        }

        // Continue with clean composite: output must be finite again and
        // carry real signal energy (the bug would leave it NaN forever).
        var postEnergy = 0.0
        let postStart = frames / 2
        for i in postStart..<frames {
            let (l, r) = decoder.process(mpx[i], programActivity: 0.4, expectedSide: 0.0)
            #expect(l.isFinite && r.isFinite, "post-burst output non-finite at \(i)")
            postEnergy += Double(l * l + r * r)
        }
        #expect(postEnergy > 0.0,
                "decoder did not recover signal after the non-finite burst")
    }
}
