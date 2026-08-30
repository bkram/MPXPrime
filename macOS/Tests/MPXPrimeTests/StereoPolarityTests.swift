import Testing
import Foundation
@testable import MPXPrime
import MPXPrimeCore

// Stereo subcarrier polarity (47 CFR 73.322 / ITU-R BS.450-3).
//
// The standard composite is M + S * sin(2 theta) with the pilot sin(theta),
// S = (L - R)/2: the 38 kHz subcarrier crosses zero with positive slope at
// every pilot zero crossing and a receiver forms L = M + S. Until 0.45 the
// encoder emitted (R - L)/2 and MPXDecoder carried a compensating negation,
// so every in-repo gate was self-consistent while real receivers played L
// and R swapped. These tests pin the polarity from BOTH sides with a
// hand-written textbook reference that shares no code with the decoder.

@Suite("Stereo subcarrier polarity")
struct StereoPolarityTests {

    private let sampleRate: Double = 192_000.0
    private let toneHz: Double = 1_000.0

    /// Projection of `samples` (from `start`) onto sin/cos of `hz`.
    private func project(_ samples: [Float], hz: Double, start: Int) -> (sin: Double, cos: Double) {
        let omega = 2.0 * Double.pi * hz / sampleRate
        var s = 0.0, c = 0.0
        for i in start..<samples.count {
            let phase = omega * Double(i)
            s += Double(samples[i]) * sin(phase)
            c += Double(samples[i]) * cos(phase)
        }
        let scale = 2.0 / Double(samples.count - start)
        return (s * scale, c * scale)
    }

    /// Textbook receiver on a composite: pilot phase from the 19 kHz
    /// projection, 38 kHz reference sin(2(omega t + phi)), S = 2 mpx ref,
    /// L = M + S. Returns the recovered tone amplitude per channel.
    private func textbookDecodeTone(_ mpx: [Float], start: Int) -> (left: Double, right: Double) {
        let pilot = project(mpx, hz: 19_000.0, start: start)
        let phi = atan2(pilot.cos, pilot.sin)
        let pilotOmega = 2.0 * Double.pi * 19_000.0 / sampleRate
        var demod = [Float](repeating: 0.0, count: mpx.count)
        for i in start..<mpx.count {
            let ref = sin(2.0 * ((pilotOmega * Double(i)) + phi))
            demod[i] = Float(2.0 * Double(mpx[i]) * ref)
        }
        let m = project(mpx, hz: toneHz, start: start)
        let s = project(demod, hz: toneHz, start: start)
        let left = hypot(m.sin + s.sin, m.cos + s.cos)
        let right = hypot(m.sin - s.sin, m.cos - s.cos)
        return (left, right)
    }

    private func rms(_ x: ArraySlice<Float>) -> Double {
        var acc = 0.0
        for v in x { acc += Double(v * v) }
        return sqrt(acc / Double(max(1, x.count)))
    }

    // MARK: - Decoder side: a standard composite must decode LEFT as left

    @Test func decoderRecoversLeftOnlyToneOnTheLeft() {
        let frames = Int(1.0 * sampleRate)
        let start = Int(0.5 * sampleRate)
        var mpx = [Float](repeating: 0.0, count: frames)
        let wt = 2.0 * Double.pi * toneHz / sampleRate
        let wp = 2.0 * Double.pi * 19_000.0 / sampleRate
        for i in 0..<frames {
            let l = 0.4 * sin(wt * Double(i))
            let r = 0.0
            let m = (l + r) * 0.5
            let s = (l - r) * 0.5
            let theta = wp * Double(i)
            mpx[i] = Float(m + (s * sin(2.0 * theta)) + (0.09 * sin(theta)))
        }

        for usePLL in [false, true] {
            var decoder = MPXDecoder()
            decoder.configure(sampleRate: Float(sampleRate), preemphasisUS: 50)
            var left = [Float](repeating: 0.0, count: frames)
            var right = [Float](repeating: 0.0, count: frames)
            for i in 0..<frames {
                let ref: Float? = usePLL ? nil : Float(sin(2.0 * wp * Double(i)))
                let d = decoder.process(mpx[i], referenceSubcarrier: ref, programActivity: 0.4, expectedSide: 0.0)
                left[i] = d.0
                right[i] = d.1
            }
            let lRMS = rms(left[start...])
            let rRMS = rms(right[start...])
            let sepDB = 20.0 * log10(max(lRMS, 1e-12) / max(rRMS, 1e-12))
            #expect(sepDB > 30.0,
                "\(usePLL ? "PLL" : "coherent") decode of a left-only standard composite must land LEFT; L/R = \(sepDB) dB")
        }
    }

    // MARK: - Encoder side: the generator's composite must decode LEFT as left on a textbook receiver

    private func renderToneComposite(driveLeft: Bool) -> [Float] {
        var config = AppConfig()
        config.sampleRate = sampleRate
        config.enRDS = false
        config.monoMode = false
        config.processingBypass = true
        let generator = MPXGenerator(config: config, sampleRate: sampleRate)
        let frames = Int(1.0 * sampleRate)
        var mpx = [Float](repeating: 0.0, count: frames)
        let wt = 2.0 * Double.pi * toneHz / sampleRate
        for i in 0..<frames {
            let tone = Float(0.3 * sin(wt * Double(i)))
            mpx[i] = generator.renderSingleSample(leftIn: driveLeft ? tone : 0.0, rightIn: driveLeft ? 0.0 : tone)
        }
        return mpx
    }

    @Test func encoderLeftOnlyToneDecodesLeftOnATextbookReceiver() {
        let mpx = renderToneComposite(driveLeft: true)
        let decoded = textbookDecodeTone(mpx, start: Int(0.5 * sampleRate))
        let sepDB = 20.0 * log10(max(decoded.left, 1e-12) / max(decoded.right, 1e-12))
        #expect(sepDB > 30.0,
            "left-driven tone must decode LEFT on a standard receiver; L/R = \(sepDB) dB")
    }

    @Test func encoderRightOnlyToneDecodesRightOnATextbookReceiver() {
        let mpx = renderToneComposite(driveLeft: false)
        let decoded = textbookDecodeTone(mpx, start: Int(0.5 * sampleRate))
        let sepDB = 20.0 * log10(max(decoded.right, 1e-12) / max(decoded.left, 1e-12))
        #expect(sepDB > 30.0,
            "right-driven tone must decode RIGHT on a standard receiver; R/L = \(sepDB) dB")
    }

    // MARK: - Verifier scoring is polarity-aware

    @Test func drivenChannelSeparationGoesNegativeOnASwap() {
        let driven = ToneVector(sin: 0.01, cos: 0.0)
        let other = ToneVector(sin: 1.0, cos: 0.0)
        let sep = drivenChannelSeparation(driven: driven, other: other)
        #expect(sep.separationDB < -30.0, "a swapped decode must read as negative separation, got \(sep.separationDB)")
    }
}
