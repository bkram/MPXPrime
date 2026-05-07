import Testing
import Foundation
@testable import MPXPrime

// Isolated unit tests for the foundational filter primitives.
// These structs are exercised heavily by the chain (oversampled
// clippers, multiband splitters, encoder bandwidth guard) but had
// no direct test coverage. Tests here lock in the contracts the
// chain relies on so a primitive-level regression surfaces here
// instead of at chain-output baseline drift.

@Suite("Filter primitives")
struct FilterPrimitiveTests {

    private let sampleRate: Float = 48_000.0

    // MARK: - Lagrange4Interp

    @Test func lagrangeInterpReturnsConstantForConstantHistory() {
        // Primed with a constant + advanced through more constant
        // samples, the interpolator must return that constant for
        // any fractional t.
        var lag = Lagrange4Interp()
        lag.prime(0.5)
        lag.advance(0.5)
        lag.advance(0.5)
        lag.advance(0.5)
        for t in stride(from: Float(0.0), through: 1.0, by: 0.1) {
            let y = lag.interpolate(t: t, cur: 0.5)
            #expect(abs(y - 0.5) < 1e-6,
                "Constant-history Lagrange must return the constant; t=\(t) gave \(y)")
        }
    }

    @Test func lagrangeInterpAtTZeroReturnsMostRecentSample() {
        // Lagrange kernel at t=0 picks up h1 (the most recent advanced
        // sample), not cur. Verify by priming with one value, advancing
        // a different value, then asking for t=0.
        var lag = Lagrange4Interp()
        lag.prime(0.0)
        lag.advance(0.7)  // h1 = 0.7
        let y = lag.interpolate(t: 0.0, cur: 0.9)
        #expect(abs(y - 0.7) < 1e-6,
            "Lagrange at t=0 should return h1 (0.7), got \(y)")
    }

    @Test func lagrangeInterpAtTOneReturnsCurrent() {
        // At t=1 the kernel picks up cur exclusively.
        var lag = Lagrange4Interp()
        lag.prime(0.0)
        lag.advance(0.0)
        lag.advance(0.0)
        let y = lag.interpolate(t: 1.0, cur: 0.5)
        #expect(abs(y - 0.5) < 1e-6,
            "Lagrange at t=1 should return cur (0.5), got \(y)")
    }

    @Test func lagrangeInterpReproducesLinearInputExactly() {
        // Lagrange-4 fits cubic polynomials exactly, so a true linear
        // ramp y = n is reproduced perfectly. To set up a real ramp the
        // four taps must form one — prime to -1 then advance through
        // 0, 1 so the history is h3=-1, h2=0, h1=1; cur=2 makes the
        // four taps a linear sequence -1,0,1,2. At t=0.5 (halfway
        // between h1 and cur) expected output is 1.5.
        var lag = Lagrange4Interp()
        lag.prime(-1.0)
        lag.advance(0.0)
        lag.advance(1.0)
        let y = lag.interpolate(t: 0.5, cur: 2.0)
        #expect(abs(y - 1.5) < 1e-5,
            "Linear ramp Lagrange at t=0.5 should be 1.5, got \(y)")
    }

    // MARK: - LinkwitzRiley4

    /// Drive a sine through the filter pair for 100 ms and return the
    /// peak magnitudes of the low and high outputs after the warm-up
    /// transient.
    private func lr4Magnitudes(
        _ lr4: inout LinkwitzRiley4, freqHz: Float, durationSec: Double = 0.1
    ) -> (low: Float, high: Float) {
        let frames = Int(Double(sampleRate) * durationSec)
        let warmup = frames / 4
        let omega = 2.0 * Double.pi * Double(freqHz) / Double(sampleRate)
        var lowMax: Float = 0
        var highMax: Float = 0
        for i in 0..<frames {
            let s = Float(sin(omega * Double(i)))
            let (low, high) = lr4.process(s)
            if i >= warmup {
                lowMax = max(lowMax, abs(low))
                highMax = max(highMax, abs(high))
            }
        }
        return (lowMax, highMax)
    }

    @Test func linkwitzRiley4PassesLowAtDCBlocksAtNyquist() {
        var lr4 = LinkwitzRiley4()
        lr4.configure(cutoffHz: 1_000.0, sampleRate: sampleRate)
        // Well below cutoff: low passes near unity, high near silent.
        let lowFreq = lr4Magnitudes(&lr4, freqHz: 50.0)
        #expect(lowFreq.low > 0.95,
            "LR4 lowpass at 50 Hz (well below 1 kHz cutoff) should pass; got \(lowFreq.low)")
        #expect(lowFreq.high < 0.05,
            "LR4 highpass at 50 Hz should reject; got \(lowFreq.high)")
    }

    @Test func linkwitzRiley4PassesHighAtNyquistBlocksAtDC() {
        var lr4 = LinkwitzRiley4()
        lr4.configure(cutoffHz: 1_000.0, sampleRate: sampleRate)
        // Well above cutoff.
        let highFreq = lr4Magnitudes(&lr4, freqHz: 12_000.0)
        #expect(highFreq.high > 0.95,
            "LR4 highpass at 12 kHz should pass; got \(highFreq.high)")
        #expect(highFreq.low < 0.05,
            "LR4 lowpass at 12 kHz should reject; got \(highFreq.low)")
    }

    @Test func linkwitzRiley4CrossesAtMinusSixDBOnCutoff() {
        // LR4 has -6 dB (≈0.5 linear) on each leg at the crossover
        // frequency by design. Tolerance loose because warmup-affected
        // peaks vary on a sine.
        var lr4 = LinkwitzRiley4()
        lr4.configure(cutoffHz: 1_000.0, sampleRate: sampleRate)
        let xover = lr4Magnitudes(&lr4, freqHz: 1_000.0, durationSec: 0.2)
        #expect(abs(xover.low - 0.5) < 0.1,
            "LR4 lowpass at fc should be ≈0.5; got \(xover.low)")
        #expect(abs(xover.high - 0.5) < 0.1,
            "LR4 highpass at fc should be ≈0.5; got \(xover.high)")
    }

    // MARK: - BiquadCascade6

    @Test func biquadCascade6IdentityPassesUnchanged() {
        var cascade = BiquadCascade6()
        cascade.configureIdentity()
        for value: Float in [0.0, 0.1, -0.5, 0.95, -0.95] {
            let y = cascade.process(value)
            #expect(abs(y - value) < 1e-6,
                "Identity cascade must return input unchanged; \(value) -> \(y)")
        }
    }

    @Test func biquadCascade6LowpassPassesDC() {
        // Driven with a constant DC, after warmup the cascade output
        // must approach DC (the lowpass passes 0 Hz fully).
        var cascade = BiquadCascade6()
        cascade.configureLowpass(cutoffHz: 1_000.0, sampleRate: sampleRate)
        var last: Float = 0
        for _ in 0..<1_000 {
            last = cascade.process(0.7)
        }
        #expect(abs(last - 0.7) < 0.01,
            "BiquadCascade6 LP must pass DC; converged to \(last)")
    }

    @Test func biquadCascade6LowpassRejectsHighFrequency() {
        // 12th-order LP at fc=2 kHz — drive a 16 kHz sine and verify
        // it's heavily attenuated.
        var cascade = BiquadCascade6()
        cascade.configureLowpass(cutoffHz: 2_000.0, sampleRate: sampleRate)
        let omega = 2.0 * Double.pi * 16_000.0 / Double(sampleRate)
        var peak: Float = 0
        for i in 0..<2_000 {
            let s = Float(sin(omega * Double(i)))
            let y = cascade.process(s)
            if i > 1_000 { peak = max(peak, abs(y)) }
        }
        #expect(peak < 0.001,
            "BiquadCascade6 LP at 2 kHz must crush 16 kHz to <-60 dB; got peak \(peak)")
    }

    @Test func biquadCascade6HighpassRejectsDC() {
        var cascade = BiquadCascade6()
        cascade.configureHighpass(cutoffHz: 1_000.0, sampleRate: sampleRate)
        var last: Float = 0
        for _ in 0..<2_000 {
            last = cascade.process(0.7)
        }
        #expect(abs(last) < 0.01,
            "BiquadCascade6 HP must reject DC; converged to \(last)")
    }
}
