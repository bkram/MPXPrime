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
        // RDS OFF: both tests compare two offline renders sample by sample,
        // and the RDS text scheduler paces PS/RT by WALL CLOCK, so two
        // renders that take different real time emit different bits. On a
        // contended CI runner (814 s suite) that showed up as a -24 dB
        // "shaper action" whose max delta was exactly twice the RDS
        // amplitude; on an idle machine the two renders happened to see the
        // same group sequence. The pilot stays on, so the subcarrier
        // reservation the shaper's threshold depends on is still exercised.
        config.enRDS = false
        config.compositeClipperEnabled = true
        config.compositeClipperLookaheadMS = 0.0
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
        renderWithGenerator(config, frames: frames).samples
    }

    private func renderWithGenerator(_ config: AppConfig, frames: Int) -> (samples: [Float], generator: MPXGenerator) {
        let generator = MPXGenerator(config: config, sampleRate: config.sampleRate)
        var out = [Float](repeating: 0.0, count: frames)
        for n in 0..<frames {
            let t = Double(n) / config.sampleRate
            let l = Float(0.7 * sin(2.0 * Double.pi * 1_000.0 * t) + 0.3 * sin(2.0 * Double.pi * 9_000.0 * t))
            let r = Float(0.6 * sin(2.0 * Double.pi * 1_300.0 * t) - 0.3 * sin(2.0 * Double.pi * 11_000.0 * t))
            out[n] = generator.renderSingleSample(leftIn: l, rightIn: r)
        }
        return (out, generator)
    }

    /// The shaper's threshold is the audio-composite budget
    /// (`threshold / outputGain - subcarrier reservation - margin`), so a
    /// failure message that carries the budget inputs says WHY it engaged.
    private func budgetDescription(_ generator: MPXGenerator) -> String {
        let cal = generator.compositeCalibrationStatus
        let lim = generator.finalLimiterStatus
        return String(
            format: "pilot %.2f%% rds %.2f%% audioPeak %.4f budgetMargin %.2f dB postInjOvershoot %.4f; "
                + "clipper GR %.2f dB, final limiter GR %.2f dB, safety clip %.2f dB",
            cal.pilotPercent, cal.rdsPercent, cal.audioPeak, cal.budgetMarginDB, cal.postInjectionOvershoot,
            lim.gainReductionDB, lim.safetyGainReductionDB, lim.safetyClipDB)
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
        let (a, shaperGenerator) = renderWithGenerator(withShaper, frames: frames)
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
                "shaper action \(relativeDB) dB relative to the composite (max delta \(maxDelta) at sample \(worstIndex): with \(a[worstIndex]) without \(b[worstIndex])) -- it is no longer a safety net behind the clipper. Budget inputs: \(budgetDescription(shaperGenerator))")
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
