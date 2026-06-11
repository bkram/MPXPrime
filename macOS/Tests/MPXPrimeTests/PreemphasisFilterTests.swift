import Testing
import Foundation
@testable import MPXPrime
import MPXPrimeCore

// Isolated tests for the FM pre-/de-emphasis filter pair — fundamental to the
// chain but previously exercised only inside full-chain tests. The pair are
// exact inverses: pre-emphasis H(z) = (1 - a z^-1)/(1 - a), de-emphasis
// H(z) = (1 - a)/(1 - a z^-1); the zero and pole cancel, so a pre->de cascade
// is identity. Both are unity at DC and the 50/75 us time constant sets the
// HF boost (≈ +10 dB at 10 kHz / 192 kHz for 50 us).

@Suite("Pre/de-emphasis filters")
struct PreemphasisFilterTests {

    private let sampleRate: Float = 192_000.0

    /// Steady-state peak amplitude of a unit sine through pre-emphasis at
    /// `freq`, after the filter transient has decayed.
    private func measurePrePeak(tauUS: Int, freq: Float) -> Float {
        var f = PreemphasisFilter()
        f.configure(tauUS: tauUS, sampleRate: sampleRate)
        let omega = 2.0 * Float.pi * freq / sampleRate
        var peak: Float = 0.0
        for i in 0..<8192 {
            let y = f.process(sinf(omega * Float(i)))
            if i >= 4096 { peak = max(peak, abs(y)) }
        }
        return peak
    }

    private func measureDePeak(tauUS: Int, freq: Float) -> Float {
        var f = DeemphasisFilter()
        f.configure(tauUS: tauUS, sampleRate: sampleRate)
        let omega = 2.0 * Float.pi * freq / sampleRate
        var peak: Float = 0.0
        for i in 0..<8192 {
            let y = f.process(sinf(omega * Float(i)))
            if i >= 4096 { peak = max(peak, abs(y)) }
        }
        return peak
    }

    private func dB(_ ratio: Float) -> Float { 20.0 * log10f(max(1e-9, ratio)) }

    @Test func preEmphasisBoostsHighFrequencies() {
        let low = measurePrePeak(tauUS: 50, freq: 1_000.0)
        let high = measurePrePeak(tauUS: 50, freq: 10_000.0)
        let boost = dB(high) - dB(low)
        // Analytic: ~+0.4 dB at 1 kHz, ~+10.3 dB at 10 kHz -> ~+9.9 dB difference.
        #expect(boost > 6.0, "50 us pre-emphasis 10 kHz vs 1 kHz boost was \(boost) dB, expected > 6")
    }

    @Test func deEmphasisCutsHighFrequencies() {
        let low = measureDePeak(tauUS: 50, freq: 1_000.0)
        let high = measureDePeak(tauUS: 50, freq: 10_000.0)
        let cut = dB(low) - dB(high)
        #expect(cut > 6.0, "50 us de-emphasis 10 kHz vs 1 kHz cut was \(cut) dB, expected > 6")
    }

    @Test func sevenFiveBoostsMoreThanFifty() {
        // 75 us has a lower corner (2123 Hz vs 3183 Hz) -> more boost at 10 kHz.
        let boost50 = dB(measurePrePeak(tauUS: 50, freq: 10_000.0))
        let boost75 = dB(measurePrePeak(tauUS: 75, freq: 10_000.0))
        #expect(boost75 > boost50, "75 us boost (\(boost75) dB) should exceed 50 us (\(boost50) dB) at 10 kHz")
    }

    @Test func preThenDeReconstructsInput() {
        // The cascade is mathematically identity; after the transient decays
        // the output must track the input to float precision.
        var pre = PreemphasisFilter()
        var de = DeemphasisFilter()
        pre.configure(tauUS: 50, sampleRate: sampleRate)
        de.configure(tauUS: 50, sampleRate: sampleRate)
        let omega = 2.0 * Float.pi * 5_000.0 / sampleRate
        var maxErr: Float = 0.0
        for i in 0..<8192 {
            let x = sinf(omega * Float(i))
            let y = de.process(pre.process(x))
            if i >= 4096 { maxErr = max(maxErr, abs(y - x)) }
        }
        #expect(maxErr < 1e-3, "pre->de cascade should reconstruct input; max error \(maxErr)")
    }

    @Test func disabledFiltersPassThrough() {
        var pre = PreemphasisFilter()
        var de = DeemphasisFilter()
        pre.configure(tauUS: 0, sampleRate: sampleRate)
        de.configure(tauUS: 0, sampleRate: sampleRate)
        #expect(!pre.enabled)
        #expect(!de.enabled)
        for x in [Float(-0.7), 0.0, 0.3, 0.95] {
            #expect(pre.process(x) == x)
            #expect(de.process(x) == x)
        }
    }
}
