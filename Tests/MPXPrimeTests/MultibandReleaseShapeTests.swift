import Testing
import Foundation
@testable import MPXPrime

// Program-dependent (dual-slope) release of the multiband compressor bands
// (0.45, chain review B2). Until 0.45 `multiband_release_program_dependent`
// multiplied the release time by a constant 1.1 -- no program dependence.
// The contract now (Orban's platform release): a transient excursion below
// the slow platform level releases at the configured (fast) rate -- a kick
// leaves no hole -- while recovery ABOVE the platform (the average level
// dropped) is 3x slower, so the band does not breathe when a chorus ends.
// Off = single slope.

@Suite("Multiband program-dependent release")
struct MultibandReleaseShapeTests {
    private let sampleRate: Float = 48_000.0

    private func makeCompressor(programDependent: Bool) -> MonoCompressor {
        var c = MonoCompressor()
        c.configure(sampleRate: sampleRate, thresholdDB: -24.0, ratio: 3.0, attackMS: 15.0,
                    releaseMS: 250.0, makeupDB: 0.0, kneeDB: 2.0, programDependentRelease: programDependent)
        return c
    }

    /// Bed 6 dB over threshold with a 30 ms +8 dB kick every 250 ms; returns
    /// the gain-reduction excursion left just before the next kick (how much
    /// of the kick's extra reduction is still audible on the bed) and the
    /// depth of the extra reduction the kick caused.
    private func kickBehaviour(programDependent: Bool) -> (residualBeforeNextKick: Float, kickDepth: Float) {
        var c = makeCompressor(programDependent: programDependent)
        let omega = 2.0 * Double.pi * 200.0 / Double(sampleRate)
        let bed: Double = 0.126        // -18 dBFS, 6 dB over the -24 dB threshold
        let kick: Double = bed * 2.51  // +8 dB
        let period = Int(sampleRate * 0.25)
        let kickLen = Int(sampleRate * 0.030)
        var steadyGR: Float = 0.0
        var deepest: Float = 0.0
        var residual: Float = 0.0
        let cycles = 16
        for n in 0..<(period * cycles) {
            let inKick = (n % period) < kickLen
            let amp = inKick ? kick : bed
            let s = Float(amp * sin(omega * Double(n)))
            _ = c.process(s)
            let cycle = n / period
            if cycle == 3, (n % period) == kickLen - 1 { steadyGR = c.lastGainReductionDB }  // not used further
            if cycle >= 8 {
                deepest = min(deepest, c.lastGainReductionDB)
                if (n % period) == period - 1 { residual = c.lastGainReductionDB }
            }
        }
        _ = steadyGR
        // Reference: the bed alone settles to this GR.
        var ref = makeCompressor(programDependent: programDependent)
        var bedGR: Float = 0.0
        for n in 0..<(period * 8) {
            _ = ref.process(Float(bed * sin(omega * Double(n))))
            bedGR = ref.lastGainReductionDB
        }
        return (bedGR - residual, bedGR - deepest)
    }

    @Test func kickExcursionsRecoverAsFastAsSingleSlope() {
        let single = kickBehaviour(programDependent: false)
        let dual = kickBehaviour(programDependent: true)
        print(String(format: "multiband release: kick depth %.2f / %.2f dB, residual before next kick %.2f dB (single) vs %.2f dB (dual)",
                     single.kickDepth, dual.kickDepth, single.residualBeforeNextKick, dual.residualBeforeNextKick))
        // Both catch the kick the same way (attack is the detector's) and the
        // excursion below the platform comes back at the fast rate: no hole.
        // The dual slope may leave up to ~1 dB more standing reduction (the
        // last fraction of a dB to the platform is on the slow slope -- the
        // "come to a stop" behaviour), never a frozen kick depth.
        #expect(abs(single.kickDepth - dual.kickDepth) < 0.8)
        #expect(dual.residualBeforeNextKick < single.residualBeforeNextKick + 1.0,
                "a kick is a transient excursion and must recover at the fast rate")
        #expect(dual.residualBeforeNextKick < dual.kickDepth * 0.6, "the band must not freeze at kick depth")
    }

    /// GR left `after` seconds into quiet program following a 3 s hot bed.
    private func recoveryGR(programDependent: Bool, after: Double) -> (hot: Float, later: Float, final: Float) {
        var c = makeCompressor(programDependent: programDependent)
        let omega = 2.0 * Double.pi * 200.0 / Double(sampleRate)
        for n in 0..<Int(sampleRate * 3.0) { _ = c.process(Float(0.25 * sin(omega * Double(n)))) }   // 12 dB over
        let hot = c.lastGainReductionDB
        var later: Float = 0.0
        let mark = Int(Double(sampleRate) * after)
        for n in 0..<Int(sampleRate * 4.0) {
            _ = c.process(Float(0.02 * sin(omega * Double(n))))                                        // 10 dB under
            if n == mark { later = c.lastGainReductionDB }
        }
        return (hot, later, c.lastGainReductionDB)
    }

    @Test func aLevelDropReleasesGentlyButFully() {
        let single = recoveryGR(programDependent: false, after: 0.5)
        let dual = recoveryGR(programDependent: true, after: 0.5)
        print(String(format: "multiband release after a level drop: GR at 0.5 s %.2f dB (single) vs %.2f dB (dual); hot %.2f dB",
                     single.later, dual.later, dual.hot))
        #expect(dual.hot < -5.0, "the hot bed must be compressed; GR \(dual.hot)")
        // Above the platform the dual slope is 3x slower: at 0.5 s it still
        // holds clearly more reduction than the single slope (no breathing)...
        #expect(dual.later < single.later - 1.5,
                "recovery above the platform should be slower: \(dual.later) vs \(single.later) dB at 0.5 s")
        // ...and after 4 s of quiet program both are fully released.
        #expect(dual.final > -0.3, "after 4 s of quiet program the reduction must be gone; GR \(dual.final)")
        #expect(single.final > -0.3)
    }

    @Test func singleSlopeFollowsTheDetectorExactly() {
        // Off = the applied GR is the detector's target every sample.
        var c = makeCompressor(programDependent: false)
        let omega = 2.0 * Double.pi * 200.0 / Double(sampleRate)
        var mismatch: Float = 0.0
        for n in 0..<Int(sampleRate * 1.0) {
            let amp: Double = (n / 4_800) % 2 == 0 ? 0.25 : 0.05
            let s = Float(amp * sin(omega * Double(n)))
            let out = c.process(s)
            // out / s == 10^(GR/20) exactly when nothing smooths the GR.
            if fabsf(s) > 1e-3 {
                let impliedGR = 20.0 * log10f(fabsf(out / s))
                mismatch = max(mismatch, fabsf(impliedGR - c.lastGainReductionDB))
            }
        }
        #expect(mismatch < 1e-3)
    }
}
