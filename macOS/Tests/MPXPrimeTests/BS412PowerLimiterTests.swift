import Testing
import Foundation
@testable import MPXPrime

// ITU-R BS.412 modulation-power limiter. The limiter holds the rolling
// (windowed) average power at/below a configured threshold. These tests
// drive the standalone limiter with a synthetic steady tone and a short
// (1 s) window so the rolling average fills quickly, instead of paying a
// 60 s composite render. They verify the two contract properties:
//   * a sustained over-threshold hotspot is pulled back to the budget
//   * an under-threshold signal passes essentially untouched

@Suite("BS.412 power limiter")
struct BS412PowerLimiterTests {

    private let sampleRate: Float = 48_000.0
    private let thresholdDB: Float = -10.0

    /// Peak amplitude of a sine whose mean power sits `overDB` relative to
    /// `thresholdDB` (sine mean power = peak^2 / 2).
    private func sinePeak(forPowerOverDB overDB: Float) -> Float {
        let thresholdPower = powf(10.0, thresholdDB / 10.0)
        let power = thresholdPower * powf(10.0, overDB / 10.0)
        return sqrtf(2.0 * power)
    }

    private func renderAndMeasureOutputDBr(peak: Float, freqHz: Float, seconds: Float) -> Float {
        var limiter = BS412PowerLimiter()
        limiter.configure(sampleRate: sampleRate, thresholdDB: thresholdDB, windowSeconds: 1.0)
        let total = Int(seconds * sampleRate)
        let measureFrom = Int((seconds - 1.0) * sampleRate)  // final 1 s, fully settled
        let omega = 2.0 * Float.pi * freqHz / sampleRate
        var outPower: Double = 0.0
        var measured = 0
        for i in 0..<total {
            let x = peak * sinf(omega * Float(i))
            let y = limiter.process(x)
            if i >= measureFrom {
                outPower += Double(y * y)
                measured += 1
            }
        }
        let meanPower = Float(outPower / Double(max(1, measured)))
        let thresholdPower = powf(10.0, thresholdDB / 10.0)
        return 10.0 * log10f(max(1e-12, meanPower) / thresholdPower)
    }

    @Test func sustainedHotspotIsPulledBackToBudget() {
        // +6 dB over threshold, sustained. After the window fills and the
        // gain settles, output power must sit at the threshold (0 dBr).
        let outDBr = renderAndMeasureOutputDBr(peak: sinePeak(forPowerOverDB: 6.0), freqHz: 1_000.0, seconds: 6.0)
        #expect(abs(outDBr) < 1.0,
                "BS.412 settled output power \(outDBr) dBr, expected within 1 dB of the -10 dB budget")
    }

    @Test func louderHotspotStillHeldAtBudget() {
        // +12 dB over threshold should still be pulled to the budget, just
        // with more gain reduction.
        let outDBr = renderAndMeasureOutputDBr(peak: sinePeak(forPowerOverDB: 12.0), freqHz: 1_000.0, seconds: 6.0)
        #expect(abs(outDBr) < 1.0,
                "BS.412 settled output power \(outDBr) dBr at +12 dB drive, expected within 1 dB of budget")
    }

    @Test func underThresholdSignalPassesUntouched() {
        // -6 dB under threshold: the limiter must not pull it down.
        let outDBr = renderAndMeasureOutputDBr(peak: sinePeak(forPowerOverDB: -6.0), freqHz: 1_000.0, seconds: 4.0)
        // Output should remain ~6 dB below threshold (no gain reduction).
        #expect(outDBr < -5.0 && outDBr > -7.0,
                "under-threshold signal moved to \(outDBr) dBr; limiter should pass it ~-6 dBr untouched")
    }
}
