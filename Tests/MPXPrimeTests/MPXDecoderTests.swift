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

    private func rms(_ x: ArraySlice<Float>) -> Double {
        var acc = 0.0
        for v in x { acc += Double(v) * Double(v) }
        return sqrt(acc / Double(max(1, x.count)))
    }

    @Test func recoversAfterNonFiniteBurst() {
        // 1 s of composite: clean decode for 0.25 s, a 256-sample NaN/Inf
        // burst, then clean composite again from 0.5 s. Recovery is judged
        // against a REFERENCE decoder fed the same composite without the
        // burst, over the last 0.25 s: "some energy" was also met by the
        // documented 0.50 failure (recovery 8-12 dB down, loss of pilot lock),
        // see test-suite review 2026-10 finding 13.
        let frames = Int(1.0 * sampleRate)
        let mpx = renderLOnlyComposite(frames: frames)

        var reference = MPXDecoder()
        reference.configure(sampleRate: sampleRate, preemphasisUS: 50)
        var refL = [Float](repeating: 0.0, count: frames)
        var refR = [Float](repeating: 0.0, count: frames)
        for i in 0..<frames {
            (refL[i], refR[i]) = reference.process(mpx[i], programActivity: 0.4, expectedSide: 0.0)
        }

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
        // match the undisturbed decoder.
        let postStart = frames / 2
        var outL = [Float](repeating: 0.0, count: frames)
        var outR = [Float](repeating: 0.0, count: frames)
        for i in postStart..<frames {
            let (l, r) = decoder.process(mpx[i], programActivity: 0.4, expectedSide: 0.0)
            #expect(l.isFinite && r.isFinite, "post-burst output non-finite at \(i)")
            outL[i] = l
            outR[i] = r
        }
        let window = (3 * frames / 4)..<frames
        let refLeft = rms(refL[window])
        let gotLeft = rms(outL[window])
        let levelDB = 20.0 * log10(max(gotLeft, 1e-12) / max(refLeft, 1e-12))
        let sepRef = 20.0 * log10(max(refLeft, 1e-12) / max(rms(refR[window]), 1e-12))
        let sepGot = 20.0 * log10(max(gotLeft, 1e-12) / max(rms(outR[window]), 1e-12))
        print(String(format: "[decoder recovery] left %+.2f dB re undisturbed, separation %.1f dB (undisturbed %.1f dB)",
                     levelDB, sepGot, sepRef))
        #expect(refLeft > 0.05, "fixture problem: the undisturbed decode carries no signal (\(refLeft))")
        #expect(abs(levelDB) < 1.0,
                "after the burst the left channel is \(levelDB) dB off the undisturbed decoder -- the decoder did not recover")
        #expect(sepGot > 30.0,
                "after the burst the decode has \(sepGot) dB separation (undisturbed \(sepRef) dB) -- pilot lock not regained")
    }
}
