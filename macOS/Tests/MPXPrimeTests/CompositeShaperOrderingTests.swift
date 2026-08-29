import Foundation
import Testing

@testable import MPXPrime

// 0.45 final-stage ordering contract: composite clipper -> bandwidth FIR ->
// final look-ahead limiter, both peak stages referenced to the audio-
// composite budget, and the always-on `softClipSafety` shaper an idle safety
// net behind them. Before the fix the shaper ran first at a LOWER threshold
// than the clipper's and did every bit of the clipping (1x rate, no guard-
// band cancellation) while the final limiter sat idle above it at an absolute
// 0.98; --verify-hf-transients measured that as ~13 dB of lost decoded HF
// SINAD.
@Suite struct CompositeShaperOrderingTests {

    private func hotConfig() -> AppConfig {
        var config = AppConfig()
        config.sampleRate = 192_000.0
        config.enRDS = true
        config.compositeClipperEnabled = true
        config.compositeClipperLookaheadMS = 0.0
        config.compositeMultibandClipperEnabled = false
        config.finalDriveDB = 12.0       // hot: the clipper must work hard
        config.limitMPX = true           // clipper + final limiter own the peaks
        config.limitLookaheadEnabled = true
        config.limitLookaheadMS = 5.0
        config.widebandAGCEnabled = false
        config.multibandEnabled = false
        config.preEncodeAudioLimiterEnabled = false
        return config
    }

    private func render(_ config: AppConfig, frames: Int) -> [Float] {
        let generator = MPXGenerator(config: config, sampleRate: config.sampleRate)
        var out = [Float](repeating: 0.0, count: frames)
        for n in 0..<frames {
            let t = Double(n) / config.sampleRate
            let l = Float(0.7 * sin(2.0 * Double.pi * 1_000.0 * t) + 0.3 * sin(2.0 * Double.pi * 9_000.0 * t))
            let r = Float(0.6 * sin(2.0 * Double.pi * 1_300.0 * t) - 0.3 * sin(2.0 * Double.pi * 11_000.0 * t))
            out[n] = generator.renderSingleSample(leftIn: l, rightIn: r)
        }
        return out
    }

    @Test func shaperIsIdleWhenTheCompositeClipperRuns() {
        // With the clipper active, toggling the shaper off must not change a
        // single sample: the clipper's budget-referenced ceiling keeps the
        // audio composite below the shaper's threshold at all times.
        let frames = 96_000
        var withShaper = hotConfig()
        withShaper.audioCompositeSoftClipEnabled = true
        var withoutShaper = hotConfig()
        withoutShaper.audioCompositeSoftClipEnabled = false
        let a = render(withShaper, frames: frames)
        let b = render(withoutShaper, frames: frames)
        // Skip the first 0.5 s: the differential clipper's bypass delay line
        // and the subcarrier-reservation envelope prime there, and the shaper
        // legitimately catches that start-up transient (its safety-net job).
        let start = frames / 2
        var maxDelta: Float = 0.0
        var worstIndex = 0
        var deltaPower: Double = 0.0
        var signalPower: Double = 0.0
        for i in start..<frames {
            let d = fabsf(a[i] - b[i])
            if d > maxDelta { maxDelta = d; worstIndex = i }
            deltaPower += Double(d * d)
            signalPower += Double(b[i] * b[i])
        }
        let relativeDB = 10.0 * log10(max(1e-30, deltaPower) / max(1e-30, signalPower))
        #expect(relativeDB < -40.0,
                "shaper action \(relativeDB) dB relative to the composite (max delta \(maxDelta) at sample \(worstIndex): with \(a[worstIndex]) without \(b[worstIndex])) -- it is no longer a safety net behind the clipper")
    }

    @Test func compositeClipperDoesTheClippingWork() {
        // Turning the clipper OFF on the hot program must change the output
        // (the shaper takes over) -- i.e. the clipper is actually engaged
        // rather than sitting above the budget where it could never act.
        let frames = 96_000
        let on = render(hotConfig(), frames: frames)
        var offConfig = hotConfig()
        offConfig.compositeClipperEnabled = false
        let off = render(offConfig, frames: frames)
        var maxDelta: Float = 0.0
        for i in (frames / 2)..<frames { maxDelta = max(maxDelta, fabsf(on[i] - off[i])) }
        #expect(maxDelta > 0.01, "composite clipper on/off is bit-identical: the clipper is not engaging")
    }
}
