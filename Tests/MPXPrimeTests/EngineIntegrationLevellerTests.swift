import Foundation
import Testing
@testable import MPXPrime

// Advanced Dynamics hold window (fix round G1, item 3). Inside its hold
// window the leveller's wideband gain stopped dead, so the same steady
// programme settled anywhere within the window depending on what came
// before it: down from louder programme it stopped half a window over the
// cut, up from quieter programme half a window short of the lift. The gain
// now creeps to the target inside the window at 10x the base release (the
// fix the wideband AGC got in review 2026-10-15, finding 4).
@Suite("Engine integration (Advanced Dynamics hold window)")
struct EngineIntegrationLevellerTests {

    private let sampleRate: Float = 32_000.0

    private func makeLeveller() -> AdvancedDynamicsLeveler {
        var l = AdvancedDynamicsLeveler()
        l.configureStructure(sampleRate: sampleRate, x1Hz: 90, x2Hz: 350, x3Hz: 1_800, x4Hz: 6_800)
        // Density 0: the widest hold window (3 dB). Speed 4: 0.3 s base
        // release, so the in-window creep (10x) is 3 s and the test is short.
        l.setParameters(targetDB: -18.0, lowOffsetDB: 0.0, midOffsetDB: 0.0, highOffsetDB: 0.0,
                        maxGainDB: 12.0, density: 0.0, speed: 4.0)
        return l
    }

    /// Steady multitone at `amplitude`.
    private func programme(_ i: Int, amplitude: Float) -> Float {
        let t = Float(i) / sampleRate
        return amplitude * (0.5 * sinf(2.0 * Float.pi * 220.0 * t)
            + 0.35 * sinf(2.0 * Float.pi * 1_000.0 * t)
            + 0.15 * sinf(2.0 * Float.pi * 3_000.0 * t))
    }

    /// Wideband gain after `historyAmplitude` for 6 s, then the same steady
    /// programme for `steadySeconds`.
    private func settledGainDB(historyAmplitude: Float, steadySeconds: Float) -> Float {
        var l = makeLeveller()
        let history = Int(sampleRate * 6.0)
        for i in 0..<history {
            let x = programme(i, amplitude: historyAmplitude)
            _ = l.process(left: x, right: x)
        }
        let steady = Int(sampleRate * steadySeconds)
        for i in history..<(history + steady) {
            let x = programme(i, amplitude: 0.1)
            _ = l.process(left: x, right: x)
        }
        return l.widebandGainDB
    }

    @Test func steadyStateDoesNotDependOnHistory() {
        let fromLoud = settledGainDB(historyAmplitude: 0.5, steadySeconds: 24.0)
        let fromQuiet = settledGainDB(historyAmplitude: 0.025, steadySeconds: 24.0)
        print(String(format: "AD wideband gain on the same programme: from louder %.2f dB, from quieter %.2f dB",
                     fromLoud, fromQuiet))
        // Before: the two rest points were a hold window apart (about 1.5 dB
        // each side of target at density 0).
        #expect(abs(fromLoud - fromQuiet) < 0.2,
                "steady state depends on history: \(fromLoud) vs \(fromQuiet) dB")
    }
}
