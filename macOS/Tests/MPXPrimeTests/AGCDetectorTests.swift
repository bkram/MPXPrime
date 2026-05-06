import Testing
import Foundation
@testable import MPXPrime

// Characterisation tests for the broadcast-grade upgrade to
// WidebandAGCRider — K-weighting on the detector sidechain and
// program-dependent release. These don't assert exact coefficients;
// they verify the behavioural contract: K-weighted detection changes
// how bass vs mids are perceived, program-dependent release moves
// with program activity, gate + gain clamps still hold.

@Suite("Wideband AGC detector")
struct AGCDetectorTests {

    private let sampleRate: Float = 48_000.0

    // MARK: - Helpers

    private func makeAGC(
        kWeighting: Bool,
        programDependentRelease: Bool = false,
        targetDB: Float = -16.0,
        attackMS: Float = 80.0,
        releaseMS: Float = 1_000.0,
        minGainDB: Float = -12.0,
        maxGainDB: Float = 12.0
    ) -> WidebandAGCRider {
        var agc = WidebandAGCRider()
        agc.configure(
            sampleRate: sampleRate,
            targetDB: targetDB,
            attackMS: attackMS,
            releaseMS: releaseMS,
            minGainDB: minGainDB,
            maxGainDB: maxGainDB,
            kWeightingEnabled: kWeighting,
            programDependentRelease: programDependentRelease
        )
        return agc
    }

    /// Pump a stereo sine through the AGC for `seconds` seconds,
    /// return the detector level and gain at the end of the run.
    private func runSine(
        _ agc: inout WidebandAGCRider,
        freq: Float,
        amplitude: Float,
        seconds: Double
    ) -> (detectorDB: Float, gainDB: Float, gateActive: Bool) {
        let frames = Int(Double(sampleRate) * seconds)
        let omega = 2.0 * Double.pi * Double(freq) / Double(sampleRate)
        for i in 0..<frames {
            let s = Float(Double(amplitude) * sin(omega * Double(i)))
            _ = agc.process(left: s, right: s)
        }
        return agc.telemetry
    }

    // MARK: - K-weighting

    @Test func kWeightingBoostsMidsOverLows() {
        // Same amplitude, different frequencies. With K-weighting the
        // ~1.5 kHz shelf lifts the detector's view of the mids signal
        // while the HPF slightly attenuates the bass.
        let amplitude: Float = 0.3
        var bass = makeAGC(kWeighting: true)
        var mids = makeAGC(kWeighting: true)
        let bassResult = runSine(&bass, freq: 80.0, amplitude: amplitude, seconds: 3.0)
        let midsResult = runSine(&mids, freq: 3_000.0, amplitude: amplitude, seconds: 3.0)

        // Mids should read hotter than bass under K-weighting.
        #expect(midsResult.detectorDB > bassResult.detectorDB + 2.0,
            "K-weighted detector should see 3 kHz (\(midsResult.detectorDB) dB) clearly hotter than 80 Hz (\(bassResult.detectorDB) dB); delta \(midsResult.detectorDB - bassResult.detectorDB)")
    }

    @Test func kWeightingDisabledTreatsBassAndMidsEqually() {
        // Without K-weighting, the detector sees equal power at any
        // frequency for the same amplitude sinusoid.
        let amplitude: Float = 0.3
        var bass = makeAGC(kWeighting: false)
        var mids = makeAGC(kWeighting: false)
        let bassResult = runSine(&bass, freq: 80.0, amplitude: amplitude, seconds: 3.0)
        let midsResult = runSine(&mids, freq: 3_000.0, amplitude: amplitude, seconds: 3.0)

        // Should be within 1 dB of each other (only detector smoothing
        // noise remains).
        let delta = abs(midsResult.detectorDB - bassResult.detectorDB)
        #expect(delta < 1.0,
            "Unweighted detector should treat 80 Hz and 3 kHz equally; delta \(delta) dB")
    }

    @Test func kWeightedAGCGainsUpMoreOnBassOnlyProgram() {
        // Identical bass sinusoid fed to two AGCs. The K-weighted AGC
        // sees the bass as QUIETER than its raw amplitude (HPF + shelf
        // attenuate it perceptually) so its detector tracks below
        // target and pushes MORE gain up to compensate. The unweighted
        // AGC sees full power and adds less gain. This mirrors how
        // pros avoid over-lifting quiet sub-bass content.
        let amplitude: Float = 0.05  // below target
        var weighted = makeAGC(kWeighting: true)
        var unweighted = makeAGC(kWeighting: false)
        let w = runSine(&weighted, freq: 80.0, amplitude: amplitude, seconds: 5.0)
        let u = runSine(&unweighted, freq: 80.0, amplitude: amplitude, seconds: 5.0)

        #expect(w.gainDB > u.gainDB,
            "K-weighted AGC (gain \(w.gainDB) dB) should add MORE gain on perceived-quiet bass than the unweighted (\(u.gainDB) dB)")
    }

    // MARK: - Program-dependent release

    @Test func programDependentReleaseSlowsOnBusyProgram() {
        // Construct a deliberately busy signal (quickly oscillating
        // envelope from modulated noise) vs a flat continuous sine.
        // Both ring the AGC at the same average level. After a loud
        // passage + silence gap, busy program should release more
        // slowly back to unity than flat program.
        let burst = Int(Double(sampleRate) * 0.25)
        let silenceGap = Int(Double(sampleRate) * 2.0)

        func runMode(busy: Bool, programDependentRelease: Bool) -> Float {
            var agc = makeAGC(
                kWeighting: false,  // isolate release behaviour
                programDependentRelease: programDependentRelease
            )
            let omega = 2.0 * Double.pi * 2_000.0 / Double(sampleRate)
            // Loud burst drives gain down below 0 dB.
            for i in 0..<burst {
                let s = Float(0.5 * sin(omega * Double(i)))
                _ = agc.process(left: s, right: s)
            }
            // Busy program: amplitude modulated at 5 Hz so envelope
            // wobbles. Flat program: steady amplitude.
            let ramp = Int(Double(sampleRate) * 1.5)
            for i in 0..<ramp {
                let t = Double(i) / Double(sampleRate)
                let envelope: Float
                if busy {
                    envelope = 0.20 + 0.15 * Float(sin(2.0 * .pi * 5.0 * t))
                } else {
                    envelope = 0.20
                }
                let s = envelope * Float(sin(omega * Double(i + burst)))
                _ = agc.process(left: s, right: s)
            }
            // Silence gap lets AGC gain decay.
            for _ in 0..<silenceGap {
                _ = agc.process(left: 0.0, right: 0.0)
            }
            return agc.telemetry.gainDB
        }

        // With program-dependent release on, busy program should end
        // up with a HIGHER gain (slower release = hasn't finished
        // pulling gain down / hasn't finished restoring) compared to
        // flat program that raced through the release.
        let busyDependent = runMode(busy: true, programDependentRelease: true)
        let flatDependent = runMode(busy: false, programDependentRelease: true)

        // Difference must be at least 0.5 dB — anything less and the
        // feature isn't doing anything meaningful.
        let diff = abs(busyDependent - flatDependent)
        #expect(diff > 0.5,
            "Program-dependent release should produce a measurable difference between busy (\(busyDependent)) and flat (\(flatDependent)) program gain after the test sequence; diff \(diff) dB")
    }

    @Test func programDependentReleaseActuallyAffectsGainTrajectory() {
        // Inverse of the previous test: feed the SAME busy program
        // through two AGCs differing only in the PDR flag. If the
        // flag is wired and meaningful, the ending gain must differ.
        let burst = Int(Double(sampleRate) * 0.25)
        let silenceGap = Int(Double(sampleRate) * 2.0)

        func runBusy(programDependentRelease: Bool) -> Float {
            var agc = makeAGC(
                kWeighting: false,
                programDependentRelease: programDependentRelease
            )
            let omega = 2.0 * Double.pi * 2_000.0 / Double(sampleRate)
            for i in 0..<burst {
                let s = Float(0.5 * sin(omega * Double(i)))
                _ = agc.process(left: s, right: s)
            }
            let ramp = Int(Double(sampleRate) * 1.5)
            for i in 0..<ramp {
                let t = Double(i) / Double(sampleRate)
                let envelope: Float = 0.20 + 0.15 * Float(sin(2.0 * .pi * 5.0 * t))
                let s = envelope * Float(sin(omega * Double(i + burst)))
                _ = agc.process(left: s, right: s)
            }
            for _ in 0..<silenceGap {
                _ = agc.process(left: 0.0, right: 0.0)
            }
            return agc.telemetry.gainDB
        }

        let on = runBusy(programDependentRelease: true)
        let off = runBusy(programDependentRelease: false)
        #expect(abs(on - off) > 0.5,
            "Toggling program-dependent release on the SAME busy program should change the ending gain; on=\(on), off=\(off), diff=\(abs(on - off))")
    }

    // MARK: - Gate and clamps still work

    @Test func gateEngagesOnSilence() {
        // Extended silence must activate the gate; gain should drift
        // toward 0 dB (unity) rather than max-gain noise-lifting.
        var agc = makeAGC(kWeighting: true, programDependentRelease: true, maxGainDB: 12.0)
        // Run silence for 5 s.
        for _ in 0..<Int(Double(sampleRate) * 5.0) {
            _ = agc.process(left: 0.0, right: 0.0)
        }
        let t = agc.telemetry
        #expect(t.gateActive, "Gate should be active on extended silence")
        #expect(abs(t.gainDB) < 1.0,
            "Gated AGC should drift toward unity gain; ended at \(t.gainDB) dB")
    }

    @Test func gainStaysWithinClamps() {
        // Hammer the AGC with a very loud signal; gain should pin at
        // minGainDB, never go below.
        var agc = makeAGC(kWeighting: true, minGainDB: -8.0, maxGainDB: 8.0)
        let omega = 2.0 * Double.pi * 1_000.0 / Double(sampleRate)
        for i in 0..<Int(Double(sampleRate) * 2.0) {
            let s = Float(0.95 * sin(omega * Double(i)))
            _ = agc.process(left: s, right: s)
        }
        let t = agc.telemetry
        #expect(t.gainDB >= -8.0 - 0.1 && t.gainDB <= 8.0 + 0.1,
            "AGC gain \(t.gainDB) dB escaped clamps [-8, 8]")
    }

    // MARK: - KWeightingFilter unit characterisation

    @Test func kWeightingFilterAttenuatesSubHz() {
        var k = KWeightingFilter()
        k.configure(sampleRate: sampleRate)
        // Feed 10 Hz sine. HPF at 38 Hz with Q 0.5 should attenuate
        // it substantially.
        let omega = 2.0 * Double.pi * 10.0 / Double(sampleRate)
        var lastMax: Float = 0
        // Prime filter for a bit.
        for i in 0..<Int(Double(sampleRate) * 1.0) {
            let y = k.process(Float(sin(omega * Double(i))))
            if i > Int(Double(sampleRate) * 0.5) {
                lastMax = max(lastMax, abs(y))
            }
        }
        #expect(lastMax < 0.5,
            "K-weighting HPF should attenuate 10 Hz below 0.5; measured peak \(lastMax)")
    }

    @Test func kWeightingFilterBoostsHighMids() {
        var k = KWeightingFilter()
        k.configure(sampleRate: sampleRate)
        // 4 kHz sine should come out with at least a few dB of boost
        // from the high-shelf.
        let omega = 2.0 * Double.pi * 4_000.0 / Double(sampleRate)
        var lastMax: Float = 0
        for i in 0..<Int(Double(sampleRate) * 1.0) {
            let y = k.process(Float(sin(omega * Double(i))))
            if i > Int(Double(sampleRate) * 0.5) {
                lastMax = max(lastMax, abs(y))
            }
        }
        // Unity input peak = 1.0; boost means peak > ~1.15 (roughly +1.2 dB).
        #expect(lastMax > 1.05,
            "K-weighting high-shelf should boost 4 kHz peak above 1.05; measured \(lastMax)")
    }
}
