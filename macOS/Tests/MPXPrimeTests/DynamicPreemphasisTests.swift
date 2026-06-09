import Foundation
import Testing

@testable import MPXPrime

// Unit tests for the dynamic-pre-emphasis ("Smart HF") sidechain core. This is
// step 1 of the feature: the detector / relaxation math is exercised in
// isolation, before any chain wiring, so the algorithm is proven independent of
// the pre-emphasis stage it will later modulate.
@Suite struct DynamicPreemphasisTests {

    private func runSine(
        _ dp: inout DynamicPreemphasis, freq: Float, amp: Float, sr: Float, samples: Int
    ) -> Float {
        var r: Float = 0.0
        for n in 0..<samples {
            let s = amp * sinf(2.0 * Float.pi * freq * Float(n) / sr)
            r = dp.relaxAmount(left: s, right: s)
        }
        return r
    }

    @Test func disabledIsAlwaysZero() {
        var dp = DynamicPreemphasis()
        dp.configure(
            enabled: false, sampleRate: 192_000, hfCutoffHz: 4_000,
            thresholdDB: -20, maxRelax: 0.5, attackMS: 1, releaseMS: 50)
        let r = runSine(&dp, freq: 12_000, amp: 0.9, sr: 192_000, samples: 4_000)
        #expect(r == 0.0)
    }

    @Test func maxRelaxZeroIsNoOp() {
        var dp = DynamicPreemphasis()
        dp.configure(
            enabled: true, sampleRate: 192_000, hfCutoffHz: 4_000,
            thresholdDB: -20, maxRelax: 0.0, attackMS: 1, releaseMS: 50)
        let r = runSine(&dp, freq: 12_000, amp: 0.9, sr: 192_000, samples: 4_000)
        #expect(r == 0.0)
    }

    @Test func hfTransientRelaxesWithinCap() {
        var dp = DynamicPreemphasis()
        let maxRelax: Float = 0.5
        dp.configure(
            enabled: true, sampleRate: 192_000, hfCutoffHz: 4_000,
            thresholdDB: -20, maxRelax: maxRelax, attackMS: 1, releaseMS: 50)
        // A hot 12 kHz tone (well above the 4 kHz sidechain HP) drives the
        // detector above threshold -> non-zero relaxation, capped at maxRelax.
        let r = runSine(&dp, freq: 12_000, amp: 0.9, sr: 192_000, samples: 4_000)
        #expect(r > 0.0)
        #expect(r <= maxRelax + 1e-6)
    }

    @Test func lowFrequencyDoesNotRelax() {
        var dp = DynamicPreemphasis()
        dp.configure(
            enabled: true, sampleRate: 192_000, hfCutoffHz: 4_000,
            thresholdDB: -20, maxRelax: 0.5, attackMS: 1, releaseMS: 50)
        // A 100 Hz tone is rejected by the 4 kHz HP, so the detector stays below
        // threshold and pre-emphasis is left at full strength.
        let r = runSine(&dp, freq: 100, amp: 0.9, sr: 192_000, samples: 8_000)
        #expect(r < 0.01)
    }
}
