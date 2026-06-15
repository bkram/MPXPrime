import Testing
import Foundation
@testable import MPXPrime

// Multiband idle transparency.
//
// The multiband compressor must pass the program untouched when no band is
// over threshold (the classic "transparent when idle" contract). This is
// established compositionally:
//   * the linear-phase splitter reconstructs the delayed input to within
//     -60 dB (see MultibandFIRSplitterTests sum-to-flat) — recombination
//     adds no coloration;
//   * each per-band MonoCompressor applies exactly unity gain below
//     threshold with 0 dB makeup — verified here.
// Together these mean splitter(in) summed through idle, unity-makeup bands
// reproduces the input.

@Suite("Multiband idle transparency")
struct MultibandIdleTransparencyTests {

    private let sampleRate: Float = 192_000.0

    /// A below-threshold signal with 0 dB makeup must pass at unity gain
    /// (no gain reduction, no level change), across the band parameters
    /// the 5-band AC preset actually uses.
    @Test func perBandCompressorIsUnityBelowThreshold() {
        struct Band { let threshold: Float; let ratio: Float; let attack: Float; let release: Float }
        let bands = [
            Band(threshold: -17.5, ratio: 1.75, attack: 28.0, release: 375.0),
            Band(threshold: -16.0, ratio: 1.55, attack: 19.0, release: 300.0),
            Band(threshold: -14.5, ratio: 1.28, attack: 13.0, release: 225.0)
        ]
        for band in bands {
            var comp = MonoCompressor()
            comp.configure(
                sampleRate: sampleRate,
                thresholdDB: band.threshold,
                ratio: band.ratio,
                attackMS: band.attack,
                releaseMS: band.release,
                makeupDB: 0.0
            )
            // Drive 12 dB below threshold so the detector envelope never
            // crosses the knee.
            let peak = powf(10.0, (band.threshold - 12.0) / 20.0)
            let omega = 2.0 * Float.pi * 1_000.0 / sampleRate
            var maxAbsErr: Float = 0.0
            var maxGRDB: Float = 0.0
            // Settle the detector, then check the steady-state region.
            let total = Int(0.2 * sampleRate)
            let checkFrom = Int(0.1 * sampleRate)
            for i in 0..<total {
                let x = peak * sinf(omega * Float(i))
                let y = comp.process(x)
                if i >= checkFrom {
                    maxAbsErr = max(maxAbsErr, abs(y - x))
                    maxGRDB = max(maxGRDB, abs(comp.lastGainReductionDB))
                }
            }
            #expect(maxGRDB < 0.01,
                    "band @\(band.threshold) dB applied \(maxGRDB) dB GR below threshold; should be idle")
            #expect(maxAbsErr < peak * 1e-4,
                    "band @\(band.threshold) dB altered the signal by \(maxAbsErr) (peak \(peak)) while idle")
        }
    }

    /// Makeup gain is applied flatly when idle (a pure level offset, no
    /// shape change) — guards against makeup being mis-wired into the
    /// detector path.
    @Test func idleMakeupIsAFlatLevelOffset() {
        var comp = MonoCompressor()
        let makeupDB: Float = 3.0
        comp.configure(
            sampleRate: sampleRate,
            thresholdDB: -6.0,
            ratio: 1.5,
            attackMS: 20.0,
            releaseMS: 300.0,
            makeupDB: makeupDB
        )
        let peak = powf(10.0, (-6.0 - 12.0) / 20.0)  // 12 dB below threshold
        let expectedGain = powf(10.0, makeupDB / 20.0)
        let omega = 2.0 * Float.pi * 1_000.0 / sampleRate
        let total = Int(0.2 * sampleRate)
        let checkFrom = Int(0.1 * sampleRate)
        var maxRelErr: Float = 0.0
        for i in 0..<total {
            let x = peak * sinf(omega * Float(i))
            let y = comp.process(x)
            if i >= checkFrom, abs(x) > peak * 0.1 {
                let gain = y / x
                maxRelErr = max(maxRelErr, abs(gain - expectedGain) / expectedGain)
            }
        }
        #expect(maxRelErr < 1e-3,
                "idle makeup gain deviated by \(maxRelErr) from the flat \(makeupDB) dB offset")
    }
}
