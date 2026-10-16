import Foundation
import Testing

@testable import MPXPrime

// Advanced Dynamics items of levelling review 2026-10
// (2026-10-15): the tone layer's correction must be zero-mean on programme
// whose long-term share does not change (finding 2), while a short HF burst
// is still caught at once.
@Suite("Levelling: Advanced Dynamics tone layer")
struct LevellingAdvancedDynamicsTests {
    private let sampleRate: Float = 48_000.0

    private func makeLeveler() -> AdvancedDynamicsLeveler {
        var leveler = AdvancedDynamicsLeveler()
        leveler.configureStructure(sampleRate: sampleRate, x1Hz: 90.0, x2Hz: 350.0, x3Hz: 1_800.0, x4Hz: 6_800.0)
        leveler.setParameters(
            targetDB: -18.0, lowOffsetDB: 0.0, midOffsetDB: 0.0, highOffsetDB: 0.0,
            maxGainDB: 12.0, density: 0.5, speed: 1.0)
        return leveler
    }

    private enum Programme { case steady, kickTrain, hatBursts }

    /// One tone per band (55 / 190 / 800 / 3500 / 9000 Hz). `kickTrain`
    /// turns the 55 Hz tone into a 150 ms decaying burst every 500 ms;
    /// `hatBursts` turns the 9 kHz tone into 60 ms bursts every 250 ms.
    private func sample(_ i: Int, _ programme: Programme) -> Float {
        let t = Float(i) / sampleRate
        var bassAmp: Float = 0.15
        var hatAmp: Float = 0.05
        switch programme {
        case .steady:
            break
        case .kickTrain:
            let beat = fmodf(t, 0.5)
            bassAmp = beat < 0.15 ? 0.45 * expf(-beat / 0.05) : 0.0
        case .hatBursts:
            let beat = fmodf(t, 0.25)
            // 2 ms raised-cosine edges so the bursts do not click.
            let edge: Float = 0.002
            let on: Float = 0.060
            var g: Float = 0.0
            if beat < edge {
                g = 0.5 - 0.5 * cosf(Float.pi * beat / edge)
            } else if beat < on - edge {
                g = 1.0
            } else if beat < on {
                g = 0.5 + 0.5 * cosf(Float.pi * (beat - (on - edge)) / edge)
            }
            hatAmp = 0.15 * g
        }
        return bassAmp * sinf(2.0 * Float.pi * 55.0 * t)
            + 0.08 * sinf(2.0 * Float.pi * 190.0 * t)
            + 0.08 * sinf(2.0 * Float.pi * 800.0 * t)
            + 0.06 * sinf(2.0 * Float.pi * 3_500.0 * t)
            + hatAmp * sinf(2.0 * Float.pi * 9_000.0 * t)
    }

    /// Mean of (band gain - wideband gain) per band over the last
    /// `measureSeconds`, plus band 5's min / max of that difference over
    /// the last second.
    private func probe(_ programme: Programme, seconds: Float = 24.0, measureSeconds: Float = 8.0)
        -> (mean: [Double], band5Range: (Float, Float)) {
        var leveler = makeLeveler()
        let frames = Int(sampleRate * seconds)
        let measure = frames - Int(sampleRate * measureSeconds)
        let lastSecond = frames - Int(sampleRate)
        var sums = [Double](repeating: 0.0, count: 5)
        var count = 0
        var lo: Float = .infinity
        var hi: Float = -.infinity
        for i in 0..<frames {
            let x = sample(i, programme)
            _ = leveler.process(left: x, right: x)
            if i >= measure, i % 16 == 0 {
                let g = leveler.bandGainsDBFixed
                let w = leveler.widebandGainDB
                let c = [g.0 - w, g.1 - w, g.2 - w, g.3 - w, g.4 - w]
                for k in 0..<5 { sums[k] += Double(c[k]) }
                count += 1
                if i >= lastSecond {
                    lo = min(lo, c[4])
                    hi = max(hi, c[4])
                }
            }
        }
        return (sums.map { $0 / Double(count) }, (lo, hi))
    }

    @Test func levelerCorrectionsAreZeroMeanOnRhythmicProgramme() {
        // Before the fix (review finding 2): kick train -1.47 / -0.94 /
        // -1.50 / -1.56 / -1.70 dB, hat bursts band 5 -1.40 dB with a
        // 0.27 dB swing across the burst cycle.
        for programme in [Programme.steady, .kickTrain, .hatBursts] {
            let r = probe(programme)
            let line = r.mean.map { String(format: "%+.2f", $0) }.joined(separator: " ")
            print("AD mean correction \(programme): \(line) dB; band 5 range \(r.band5Range.0)...\(r.band5Range.1) dB")
            for (k, m) in r.mean.enumerated() {
                #expect(abs(m) <= 0.3, "\(programme): band \(k + 1) mean correction \(m) dB")
            }
        }
    }

    @Test func isolatedHFBurstIsCaughtWithinMilliseconds() {
        // A sibilant-like burst on steady programme: band 5 must be cut by
        // at least 2 dB within 10 ms of the burst reaching the detector.
        var leveler = makeLeveler()
        let settle = Int(sampleRate * 12.0)
        for i in 0..<settle {
            let x = sample(i, .steady)
            _ = leveler.process(left: x, right: x)
        }
        let before = leveler.bandGainsDBFixed.4 - leveler.widebandGainDB
        let delay = leveler.groupDelaySamples
        var after = before
        for i in settle..<(settle + delay + Int(sampleRate * 0.010)) {
            let t = Float(i) / sampleRate
            let x = sample(i, .steady) + 0.3 * sinf(2.0 * Float.pi * 7_500.0 * t)
            _ = leveler.process(left: x, right: x)
            after = leveler.bandGainsDBFixed.4 - leveler.widebandGainDB
        }
        print("AD band 5 correction 10 ms into an HF burst: \(before) -> \(after) dB")
        #expect(before - after >= 2.0, "band 5 moved only \(before - after) dB within 10 ms of the burst")
    }

    /// Flat output RMS (dBFS) of the leveler over the last 8 s of 16 s.
    private func outputLevelDB(_ f: (Int) -> Float) -> Double {
        var leveler = makeLeveler()
        let frames = Int(sampleRate * 16.0)
        let measure = frames - Int(sampleRate * 8.0)
        var sum = 0.0
        for i in 0..<frames {
            let x = f(i)
            let y = leveler.process(left: x, right: x)
            if i >= measure { sum += Double(y.0) * Double(y.0) }
        }
        return 10.0 * log10(sum / Double(frames - measure))
    }

    @Test func levelerOutputMeetsTargetOnRhythmicProgramme() {
        // The loudness reading is smoothed symmetrically, so a rhythmic
        // programme is levelled by its power, not by its beat peaks. Before
        // (zero-mean tone layer already in, 5 / 60 ms envelope): kick train
        // -20.27 dBFS, the verifier's bass_kick -23.34 dBFS against -18.
        let window: Float = 1.875   // hold window at density 0.5
        let kickTrain = outputLevelDB { i in self.sample(i, .kickTrain) }
        let bassKick = outputLevelDB { i in
            let t = Double(i) / Double(self.sampleRate)
            let beat = t.truncatingRemainder(dividingBy: 0.5)
            let env = exp(-beat / 0.08)
            return Float(0.9 * env * sin(2.0 * Double.pi * 55.0 * beat) + 0.12 * env * sin(2.0 * Double.pi * 110.0 * beat))
        }
        print(String(format: "AD output on rhythmic programme (target -18): kick train %.2f, bass_kick %.2f dBFS", kickTrain, bassKick))
        #expect(abs(kickTrain + 18.0) <= Double(window), "kick train levelled to \(kickTrain) dBFS")
        #expect(abs(bassKick + 18.0) <= Double(window), "bass_kick levelled to \(bassKick) dBFS")
    }

    @Test func detectorPreemphasisWeightingIsPartial() {
        // The loudness reading carries 0.3 of a 50 us pre-emphasis: a
        // 10 kHz tone reads about 4.5 dB hotter than a 1 kHz tone of the
        // same amplitude (full weighting: 11 dB, none: 0 dB).
        func reading(_ hz: Float) -> Float {
            var leveler = makeLeveler()
            leveler.setDetectorPreemphasis(tauUS: 50)
            for i in 0..<Int(sampleRate * 1.0) {
                let x = 0.05 * sinf(2.0 * Float.pi * hz * Float(i) / sampleRate)
                _ = leveler.process(left: x, right: x)
            }
            return leveler.lastWidebandLevelDB
        }
        let tilt = reading(10_000.0) - reading(1_000.0)
        print("AD loudness reading, 10 kHz re 1 kHz: \(tilt) dB")
        #expect(tilt > 3.5 && tilt < 5.5, "10 kHz reads \(tilt) dB over 1 kHz")
    }
}
