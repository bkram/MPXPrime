import Foundation
import Testing
@testable import MPXPrime

/// The 2026-10-15 gain law: one wideband gain carries the loudness, each
/// band adds a slow correction bounded to +3 / -3 dB around it. Before it,
/// every band was levelled to an ABSOLUTE target, which re-equalised all
/// programme toward one spectrum (+10 dB on a single band) and, on dense
/// bass, cut the correlated bass against lifted upper bands so L/R
/// correlation fell from 0.90 to 0.74.
@Suite("Advanced Dynamics tone and image")
struct AdvancedDynamicsToneTests {
    private let sampleRate: Float = 48_000.0

    private func makeLeveler() -> AdvancedDynamicsLeveler {
        var leveler = AdvancedDynamicsLeveler()
        leveler.configureStructure(sampleRate: sampleRate, x1Hz: 90.0, x2Hz: 350.0, x3Hz: 1_800.0, x4Hz: 6_800.0)
        leveler.setParameters(
            targetDB: -16.0, lowOffsetDB: 0.0, midOffsetDB: 0.0, highOffsetDB: 0.0,
            maxGainDB: 12.0, density: 0.5, speed: 1.0)
        return leveler
    }

    /// Loud, correlated bass under a wide, decorrelated top: the case that
    /// lost its image.
    private func denseBass(_ i: Int) -> (Float, Float) {
        let t = Float(i) / sampleRate
        let bass = 0.45 * sinf(2.0 * Float.pi * 55.0 * t) + 0.3 * sinf(2.0 * Float.pi * 110.0 * t)
        let padL = 0.05 * sinf(2.0 * Float.pi * 2_300.0 * t)
        let padR = 0.05 * sinf(2.0 * Float.pi * 2_310.0 * t + 1.3)
        let airL = 0.03 * sinf(2.0 * Float.pi * 8_100.0 * t)
        let airR = 0.03 * sinf(2.0 * Float.pi * 8_150.0 * t + 0.7)
        return (bass + padL + airL, bass + padR + airR)
    }

    private func correlation(_ l: [Float], _ r: [Float]) -> Double {
        var lr = 0.0, ll = 0.0, rr = 0.0
        for i in 0..<l.count {
            lr += Double(l[i] * r[i]); ll += Double(l[i] * l[i]); rr += Double(r[i] * r[i])
        }
        return lr / max(1e-30, (ll * rr).squareRoot())
    }

    @Test func denseBassKeepsItsImageAndBalance() {
        var leveler = makeLeveler()
        let frames = Int(sampleRate * 6.0)
        let measure = frames - Int(sampleRate * 2.0)
        var inL: [Float] = [], inR: [Float] = [], outL: [Float] = [], outR: [Float] = []
        let delay = leveler.groupDelaySamples
        var history: [(Float, Float)] = []
        for i in 0..<frames {
            let x = denseBass(i)
            history.append(x)
            let y = leveler.process(left: x.0, right: x.1)
            if i >= measure, i - delay >= 0 {
                let d = history[i - delay]
                inL.append(d.0); inR.append(d.1); outL.append(y.0); outR.append(y.1)
            }
        }
        let corrIn = correlation(inL, inR)
        let corrOut = correlation(outL, outR)
        #expect(abs(corrOut - corrIn) < 0.02, "correlation \(corrIn) in, \(corrOut) out: the image moved")
        let gains = leveler.bandGainsDB
        let spread = (gains.max() ?? 0) - (gains.min() ?? 0)
        #expect(spread <= 2.0, "band gains \(gains): a steady programme must keep its spectrum")
        #expect(leveler.widebandGainDB < -3.0, "loud dense bass must be levelled down (\(leveler.widebandGainDB) dB)")
    }

    @Test func crossoverToneIsNotLiftedTwice() {
        // A quiet tone exactly on the x3 crossover lands in two bands at
        // -6 dB each. Levelled per band to an absolute target, each half
        // was lifted on its own (the skirt scenario read +10 / +8 dB); now
        // both halves follow the one wideband gain.
        var leveler = makeLeveler()
        let frames = Int(sampleRate * 6.0)
        for i in 0..<frames {
            let t = Float(i) / sampleRate
            let x = 0.02 * sinf(2.0 * Float.pi * 1_800.0 * t)
            _ = leveler.process(left: x, right: x)
        }
        let gains = leveler.bandGainsDB
        #expect(abs(gains[2] - gains[3]) <= 1.0, "skirt bands \(gains[2]) / \(gains[3]) dB must move together")
        #expect(abs(gains[2] - leveler.widebandGainDB) <= 3.5, "the skirt bands follow the wideband gain")
    }

    @Test func correctionIsBounded() {
        // A programme whose bass suddenly drops 12 dB below its usual share
        // may be helped back by at most the lift bound.
        var leveler = makeLeveler()
        let frames = Int(sampleRate * 8.0)
        var maxCorrection: Float = -.infinity
        for i in 0..<frames {
            let t = Float(i) / sampleRate
            let bassAmp: Float = i < frames / 2 ? 0.3 : 0.075
            let x = bassAmp * sinf(2.0 * Float.pi * 60.0 * t) + 0.1 * sinf(2.0 * Float.pi * 1_000.0 * t)
            _ = leveler.process(left: x, right: x)
            if i > frames / 2 {
                maxCorrection = max(maxCorrection, leveler.bandGainsDB[0] - leveler.widebandGainDB)
            }
        }
        #expect(maxCorrection <= AdvancedDynamicsLeveler.spectralLiftMaxDB + 0.05,
            "bass correction reached \(maxCorrection) dB")
        #expect(maxCorrection > 0.5, "a lost bass share should be helped back a little (\(maxCorrection) dB)")
    }
}
