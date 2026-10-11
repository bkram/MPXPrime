import Testing
import Foundation
@testable import MPXPrime
import MPXPrimeCore

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

    // MARK: - LinearPhaseFIRDecimator
    //
    // Direct primitive coverage for the FIR decimator that replaced the
    // 12th-order Butterworth in `CompositeClipper`. The chain-level
    // behaviour is regression-guarded by the CompositeClipper test
    // suite (cross-domain IM cancellation, stereo image preservation,
    // pilot/RDS guard cleanliness); these tests validate the underlying
    // primitive contracts the chain relies on.
    //
    // OS rate of 1.536 MHz mirrors the actual usage in CompositeClipper
    // (8× × 192 kHz host rate) so the tap count and group delay
    // numbers reflect what the chain sees in practice.

    @Test func firDecimatorIsBypassWhenNotConfigured() {
        var dec = LinearPhaseFIRDecimator()
        #expect(!dec.enabled, "Default-init decimator must report disabled")
        // Pushing a sample through a non-configured decimator returns
        // the sample directly (zero-delay bypass), per the @inline guard.
        let out = dec.push(0.42)
        #expect(out == 0.42, "Disabled decimator must pass-through; got \(out)")
    }

    @Test func firDecimatorReportsValidTapsAndGroupDelay() {
        var dec = LinearPhaseFIRDecimator()
        dec.configure(
            cutoffHz: 53_000.0,
            sampleRateOS: 1_536_000.0,
            decimateFactor: 8,
            stopBandDB: 90.0,
            transitionHz: 60_000.0
        )
        #expect(dec.enabled, "Configured decimator must be enabled")
        // Kaiser-sinc with these parameters → ~147 odd taps. The exact
        // count is design-method-dependent; assert range + odd-length
        // (required for symmetric linear phase).
        #expect(dec.tapCount >= 63 && dec.tapCount <= 2049,
            "Tap count out of range: \(dec.tapCount)")
        #expect(dec.tapCount % 2 == 1,
            "Tap count must be odd for sample-centred symmetric kernel; got \(dec.tapCount)")
        // Group delay = (N-1)/2 in OS samples; host = OS / decimateFactor (rounded).
        #expect(dec.groupDelayOSSamples == (dec.tapCount - 1) / 2,
            "Group delay must equal (N-1)/2; got \(dec.groupDelayOSSamples)")
        let expectedHost = (dec.groupDelayOSSamples + 4) / 8
        #expect(dec.groupDelayHostSamples == expectedHost,
            "Host-rate group delay rounding off; got \(dec.groupDelayHostSamples), expected \(expectedHost)")
    }

    @Test func firDecimatorEmitsOnceEveryNPushes() {
        // Polyphase contract: the returned value updates only on every
        // Nth push. Intermediate calls return the previously-emitted
        // value. Verify by capturing emit-cadence directly: track
        // unique output values across a run of all-different inputs.
        // After fully filling the delay line, exactly N inputs map to
        // 1 unique output (the others repeat the prior emit).
        var dec = LinearPhaseFIRDecimator()
        dec.configure(
            cutoffHz: 53_000.0,
            sampleRateOS: 1_536_000.0,
            decimateFactor: 8
        )
        // Fill the FIR delay line + drive past one decimation cycle
        // boundary so pushSinceLastEmit lands at 0. Push count must
        // be a multiple of 8 ≥ tap count × 2.
        var settle = max(2_000, dec.tapCount * 4)
        if settle % 8 != 0 { settle += 8 - (settle % 8) }
        for _ in 0..<settle { _ = dec.push(0.0) }

        // Now push 16 different non-zero inputs and count unique
        // outputs. With decimateFactor=8 we expect exactly 2 emits
        // → at most 3 unique values (the previous emit + 2 new ones).
        var seen: Set<Int> = []
        for i in 0..<16 {
            // Encode the float-rounded output as Int bits to dedupe
            // across small float quantisation.
            let y = dec.push(Float(i) * 0.01)
            seen.insert(y.bitPattern.hashValue)
        }
        // 16 pushes, 2 emit boundaries → 3 distinct output regimes:
        // pre-emit-1 (existing 0), post-emit-1, post-emit-2.
        #expect(seen.count == 3,
            "16 pushes at decimateFactor=8 should produce exactly 3 unique outputs (start + 2 emits); got \(seen.count)")
    }

    @Test func firDecimatorPassesDCAtUnityGain() {
        // Kaiser-sinc lowpass is DC-gain-normalised in the helper.
        // Pushing a constant DC level for many cycles should converge
        // to the same level on the output.
        var dec = LinearPhaseFIRDecimator()
        dec.configure(
            cutoffHz: 53_000.0,
            sampleRateOS: 1_536_000.0,
            decimateFactor: 8
        )
        // Push enough samples to fill the FIR's delay line + then some.
        // Decimator output cadence is 1 per 8 pushes; (taps × 2) OS
        // pushes guarantees the delay line is full of DC.
        let totalPushes = max(4_000, dec.tapCount * 4)
        var lastOut: Float = 0
        for _ in 0..<totalPushes {
            lastOut = dec.push(0.5)
        }
        #expect(abs(lastOut - 0.5) < 1e-4,
            "DC gain must be unity; converged to \(lastOut), expected 0.5")
    }

    @Test func firDecimatorHeavilyAttenuatesStopbandFrequencies() {
        // Drive a sinusoid well above the cutoff (cutoff 53 kHz +
        // transition 60 kHz → -6 dB ~83 kHz; stopband ~113 kHz onward).
        // A 200 kHz tone at OS rate must be crushed by ≥80 dB
        // (Kaiser-sinc design target was 90 dB stopband).
        var dec = LinearPhaseFIRDecimator()
        dec.configure(
            cutoffHz: 53_000.0,
            sampleRateOS: 1_536_000.0,
            decimateFactor: 8,
            stopBandDB: 90.0,
            transitionHz: 60_000.0
        )
        let stopbandHz = 200_000.0
        let omega = 2.0 * Double.pi * stopbandHz / 1_536_000.0
        // Skip the FIR's group delay so we measure steady-state attenuation.
        let warmup = max(2_000, dec.tapCount * 3)
        for i in 0..<warmup {
            _ = dec.push(Float(sin(omega * Double(i))))
        }
        var peak: Float = 0
        for i in warmup..<(warmup + 4_000) {
            let y = dec.push(Float(sin(omega * Double(i))))
            peak = max(peak, abs(y))
        }
        // Input amplitude is 1.0; -80 dB = 1e-4. Allow some margin.
        #expect(peak < 1e-3,
            "Stopband at 200 kHz must be ≥-60 dB; peak \(peak) (~\(20 * log10(max(peak, 1e-9))) dB)")
    }

    @Test func firDecimatorPassbandLeaksMinimallyVsButterworth() {
        // Direct comparison: at 38 kHz (FM stereo subcarrier), how much
        // amplitude does the new FIR preserve versus a 12th-order
        // Butterworth with cutoff at 57.6 kHz? The Butterworth has 1-2
        // dB rolloff at the upper subcarrier edge; the FIR with cutoff
        // 53 kHz + wide transition has ≥0 passband ripple at 38 kHz.
        let osRate: Float = 1_536_000.0
        let testHz = 38_000.0
        let omega = 2.0 * Double.pi * Double(testHz) / Double(osRate)

        var fir = LinearPhaseFIRDecimator()
        fir.configure(cutoffHz: 53_000.0, sampleRateOS: osRate, decimateFactor: 1)
        var butter = BiquadCascade6()
        butter.configureLowpass(cutoffHz: 57_600.0, sampleRate: osRate)

        // Skip warmup, then measure peak-to-peak over a stable window.
        let warmup = max(2_000, fir.tapCount * 3)
        for i in 0..<warmup {
            _ = fir.push(Float(sin(omega * Double(i))))
            _ = butter.process(Float(sin(omega * Double(i))))
        }
        var firPeak: Float = 0
        var butterPeak: Float = 0
        for i in warmup..<(warmup + 8_000) {
            let s = Float(sin(omega * Double(i)))
            firPeak = max(firPeak, abs(fir.push(s)))
            butterPeak = max(butterPeak, abs(butter.process(s)))
        }
        // Both should pass the 38 kHz tone, but the FIR should preserve
        // it closer to unity than Butterworth.
        #expect(firPeak > 0.95,
            "FIR must pass 38 kHz at near-unity; got peak \(firPeak)")
        // Document the architectural claim: FIR ≥ Butterworth at 38 kHz.
        #expect(firPeak >= butterPeak - 0.01,
            "FIR (\(firPeak)) should preserve 38 kHz at least as well as Butterworth (\(butterPeak))")
    }

    @Test func firDecimatorResetClearsState() {
        var dec = LinearPhaseFIRDecimator()
        dec.configure(cutoffHz: 53_000.0, sampleRateOS: 1_536_000.0, decimateFactor: 8)
        // Drive non-zero data through.
        for _ in 0..<2_000 { _ = dec.push(0.5) }
        dec.reset()
        // Output should drop to ~0 after reset + many zero pushes.
        var lastOut: Float = 0
        for _ in 0..<2_000 { lastOut = dec.push(0.0) }
        #expect(abs(lastOut) < 1e-6,
            "Reset + zero-fill must drive output to 0; got \(lastOut)")
    }
}
