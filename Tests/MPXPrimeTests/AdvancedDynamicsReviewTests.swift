import Foundation
import Testing

@testable import MPXPrime

// Invariants pinned by the Advanced Dynamics correctness review
// (2026-10-10): the attack law lives in
// the time domain with per-band floors, dense program releases slower than
// sparse program, adjacent band gains stay within the sync bound, a live
// crossover change is continuous, the stereo gain is linked, one NaN sample
// does not poison the stage, a slow fade is not reversed, and the leveler's
// OWN hat distortion is measured (the gate that separates the smoother's
// cost from the chain's).
@Suite("Advanced Dynamics review invariants")
struct AdvancedDynamicsReviewTests {
    private let sampleRate: Float = 48_000.0
    private static let x1: Float = 95.0
    private static let x2: Float = 360.0
    private static let x3: Float = 1_600.0
    private static let x4: Float = 6_200.0
    /// One tone per band, at the band centres of the crossovers above.
    private static let bandCentreHz: [Float] = [60.0, 190.0, 760.0, 3_150.0, 9_000.0]

    private func makeLeveler(
        targetDB: Float = -14.0,
        maxGainDB: Float = 18.0,
        density: Float = 0.5,
        speed: Float = 1.0,
        x3Hz: Float = AdvancedDynamicsReviewTests.x3
    ) -> AdvancedDynamicsLeveler {
        var leveler = AdvancedDynamicsLeveler()
        leveler.configureStructure(
            sampleRate: sampleRate,
            x1Hz: Self.x1, x2Hz: Self.x2, x3Hz: x3Hz, x4Hz: Self.x4
        )
        leveler.setParameters(
            targetDB: targetDB,
            lowOffsetDB: 0.0, midOffsetDB: 0.0, highOffsetDB: 0.0,
            maxGainDB: maxGainDB, density: density, speed: speed
        )
        return leveler
    }

    private func fiveTone(_ i: Int, amplitude: Float) -> Float {
        let t = Float(i) / sampleRate
        var x: Float = 0.0
        for f in Self.bandCentreHz { x += amplitude * sinf(2.0 * Float.pi * f * t) }
        return x
    }

    @Test func attackFloorsAreTwoBandPeriods() {
        let leveler = makeLeveler()
        let floors = leveler.attackFloorSeconds
        let expected: [Float] = [2.0 / 60.0, 2.0 / Self.x1, 2.0 / Self.x2, 2.0 / Self.x3, 2.0 / Self.x4]
        for (f, e) in zip(floors, expected) {
            #expect(abs(f - e) < 1e-6)
        }
    }

    @Test func attackNeverFasterThanBandPeriod() {
        // A +20 dB step on a 60 Hz tone: the bass band's gain may slew at
        // most 1 dB per millisecond. The pre-fix coefficient-domain law
        // reached a 30 us time constant on every band once the step was
        // ~14 dB past the window: a whole cycle of gain slew per sample.
        var leveler = makeLeveler()
        let bed = Int(sampleRate * 4.0)
        for i in 0..<bed {
            let t = Float(i) / sampleRate
            let x = 0.05 * sinf(2.0 * Float.pi * 60.0 * t)
            _ = leveler.process(left: x, right: x)
        }
        let msSamples = Int(sampleRate * 0.001)
        var lastGain = leveler.bandGainsDBFixed.0
        var maxSlewDBPerMs: Float = 0.0
        var minGain = lastGain
        for i in 0..<Int(sampleRate * 0.5) {
            let t = Float(bed + i) / sampleRate
            let x = 0.5 * sinf(2.0 * Float.pi * 60.0 * t)
            _ = leveler.process(left: x, right: x)
            if i % msSamples == msSamples - 1 {
                let g = leveler.bandGainsDBFixed.0
                maxSlewDBPerMs = max(maxSlewDBPerMs, abs(g - lastGain))
                minGain = min(minGain, g)
                lastGain = g
            }
        }
        #expect(maxSlewDBPerMs <= 1.0,
            "bass band slewed \(maxSlewDBPerMs) dB in one millisecond")
        // ...and the step was still caught (the gain did come down).
        #expect(minGain < leveler.bandGainsDBFixed.0 + 0.5)
        #expect(minGain < 0.0, "bass band never reduced on a +20 dB step (min gain \(minGain) dB)")
    }

    @Test func transientReductionStillCatchesFastBands() {
        // The floor must not blunt the top band: a +26 dB hat-band step is
        // reduced by more than 4 dB within 20 ms (two band periods at
        // 6.2 kHz are 0.32 ms; the time-domain blend reaches the floor only
        // at full acceleration, and the transient hold has largely decayed
        // by the time the 5 ms envelope reads the step, so a moderate step
        // runs at roughly half the base attack). Measured 4.5 dB at 20 ms
        // on 2026-10-10.
        var leveler = makeLeveler()
        for i in 0..<Int(sampleRate * 3.0) {
            let t = Float(i) / sampleRate
            let x = 0.04 * sinf(2.0 * Float.pi * 9_000.0 * t)
            _ = leveler.process(left: x, right: x)
        }
        let gainBefore = leveler.bandGainsDBFixed.4
        let delay = leveler.groupDelaySamples
        for i in 0..<(delay + Int(sampleRate * 0.020)) {
            let t = Float(i) / sampleRate
            let x = 0.8 * sinf(2.0 * Float.pi * 9_000.0 * t)
            _ = leveler.process(left: x, right: x)
        }
        let gainAfter = leveler.bandGainsDBFixed.4
        #expect(gainBefore - gainAfter > 4.0,
            "top band only moved \(gainBefore - gainAfter) dB within 20 ms of a +26 dB step")
    }

    /// Hat-multitone SINAD in the HF gate's own terms (decoded-domain mask:
    /// partials +/- 250 Hz wanted, bed fundamentals excluded, 300 Hz-15 kHz).
    private static func hatSINAD(_ spec: [Float], scenario: HFTransientScenario,
                                 sampleRate: Double, fftSize: Int) -> Float {
        let binHz = sampleRate / Double(fftSize)
        func range(_ f: Double, _ hw: Double) -> ClosedRange<Int> {
            let lo = max(1, Int(((f - hw) / binHz).rounded(.up)))
            let hi = min(spec.count - 1, Int(((f + hw) / binHz).rounded(.down)))
            return lo...max(lo, hi)
        }
        let wantedRanges = scenario.wantedHz.map { range($0, scenario.wantedHalfWidthHz) }
        let bedRanges = scenario.bedHz.map { range($0, 40.0) }
        var wanted = 0.0
        var unwanted = 0.0
        let lo = max(1, Int((300.0 / binHz).rounded(.up)))
        let hi = min(spec.count - 1, Int((15_000.0 / binHz).rounded(.down)))
        for i in lo...hi {
            let p = Double(spec[i])
            if wantedRanges.contains(where: { $0.contains(i) }) {
                wanted += p
            } else if !bedRanges.contains(where: { $0.contains(i) }) {
                unwanted += p
            }
        }
        return Float(10.0 * log10(max(1e-30, wanted) / max(1e-30, unwanted)))
    }

    @Test func levelerAloneHatSINAD() throws {
        // The HF gate's hat multitone through the leveler ALONE (no
        // limiter, no clipper, no encode): the smoother's own distortion.
        // Default production crossovers and parameters. The synthetic input
        // reads ~107 dB (three exact sines), so "input minus 1 dB" is not a
        // reachable bound for any stage that moves its gain at all -- the
        // pin is an absolute floor well above the full chain's hat gate
        // (20 dB, 15 dB for music_loud): the leveler must not be the
        // dominant cost. Calibrated 2026-10-10.
        let scenario = try #require(hfTransientScenarios().first { $0.name == "hat_multitone" })
        let sr: Double = 48_000.0
        var leveler = AdvancedDynamicsLeveler()
        leveler.configureStructure(sampleRate: Float(sr), x1Hz: 90.0, x2Hz: 350.0, x3Hz: 1_800.0, x4Hz: 6_800.0)
        leveler.setParameters(
            targetDB: -16.0, lowOffsetDB: 0.0, midOffsetDB: -3.0, highOffsetDB: -9.0,
            maxGainDB: 12.0, density: 0.5, speed: 1.0)
        let frames = Int(sr * 5.0)
        var input = [Float](repeating: 0.0, count: frames)
        var output = [Float](repeating: 0.0, count: frames)
        for i in 0..<frames {
            let (l, r) = scenario.sample(i, sr)
            input[i] = l
            output[i] = leveler.process(left: l, right: r).0
        }
        let fftSize = 65_536
        let start = frames - fftSize
        let inSpec = hannPowerSpectrum(input, start: start, fftSize: fftSize)
        let outSpec = hannPowerSpectrum(output, start: start, fftSize: fftSize)
        let inSINAD = Self.hatSINAD(inSpec, scenario: scenario, sampleRate: sr, fftSize: fftSize)
        let outSINAD = Self.hatSINAD(outSpec, scenario: scenario, sampleRate: sr, fftSize: fftSize)
        print(String(format: "Advanced Dynamics leveler-alone hat SINAD: input %.1f dB, output %.1f dB", inSINAD, outSINAD))
        #expect(inSINAD > 60.0, "the synthetic hat input is not clean (\(inSINAD) dB)")
        #expect(outSINAD >= 30.0,
            "leveler-alone hat SINAD \(outSINAD) dB: the smoother itself is distorting the hats")
    }

    @Test func denseProgramReleasesSlowerThanSparse() {
        // Dense (steady, already-compressed) program must release SLOWER
        // than sparse, dynamic program, as the settings reference promises.
        // Since 2026-10-15 every band rides the shared wideband gain, so a
        // burst big enough to make a programme read "sparse" also moves that
        // gain and confounds any timing taken through the audio path; the
        // law is pinned on `liftCoefficient` itself, which the gain law
        // calls. Failed before the 2026-10-10 fix: the slowdown grew WITH
        // divergence.
        let leveler = makeLeveler()
        let sr = Float(sampleRate)
        func timeConstant(_ coeff: Float) -> Float { -1.0 / (sr * logf(coeff)) }
        for errorDB: Float in [3.0, 8.0, 20.0] {
            let dense = timeConstant(leveler.liftCoefficient(errorDB: errorDB, densityDB: 0.0))
            let sparse = timeConstant(leveler.liftCoefficient(errorDB: errorDB, densityDB: 4.0))
            #expect(dense > sparse * 2.0,
                "error \(errorDB) dB: dense lift tau \(dense) s, sparse \(sparse) s: dense must be much slower")
            let middle = timeConstant(leveler.liftCoefficient(errorDB: errorDB, densityDB: 2.0))
            #expect(middle > sparse && middle < dense, "the slowdown must fall monotonically with divergence")
        }
    }

    @Test func bandDisparityIsBounded() {
        // A tone just above the x3 crossover sits on both bands' skirts.
        // The two active bands may not differ by more than D (the review's
        // crossover-skirt double lift was +10 / +8 with no bound at all),
        // and no adjacent pair that touches an active band may differ by
        // more than D at any instant -- the empty bands beside the tone
        // are pulled along, not left behind. Band 1 is excluded: its only
        // neighbour (band 2) is empty too, and an empty band constrains
        // nobody by design, so the 1/2 pair carries no audible balance.
        var leveler = makeLeveler(maxGainDB: 18.0)
        let d = AdvancedDynamicsLeveler.maxAdjacentBandDisparityDB
        let frames = Int(sampleRate * 6.0)
        var maxDisparity: Float = 0.0
        var maxSkirtDisparity: Float = 0.0
        var worst = ""
        let skirtHz = 1.06 * Self.x3
        for i in 0..<frames {
            let t = Float(i) / sampleRate
            let x = 0.05 * sinf(2.0 * Float.pi * skirtHz * t)
            _ = leveler.process(left: x, right: 0.95 * x)
            if i % 48 == 0 {
                let g = leveler.bandGainsDBFixed
                let gains = [g.0, g.1, g.2, g.3, g.4]
                for k in 2..<gains.count {
                    let disparity = abs(gains[k] - gains[k - 1])
                    if disparity > maxDisparity {
                        maxDisparity = disparity
                        worst = "bands \(k)/\(k + 1) at \(Float(i) / sampleRate) s, gains \(gains)"
                    }
                }
                maxSkirtDisparity = max(maxSkirtDisparity, abs(g.2 - g.3))
            }
        }
        // Margin 1.0 dB: the bounds are smoothed over 50 ms, so while an
        // active band lifts at up to ~20 dB/s the empty neighbour it pulls
        // along trails the bound by rate x 50 ms (measured 0.59 dB at
        // 15 dB/s, 2026-10-10).
        #expect(maxDisparity <= d + 1.0,
            "adjacent band gains diverged by \(maxDisparity) dB (bound \(d)): \(worst)")
        #expect(maxSkirtDisparity <= d + 1.0,
            "the skirt bands diverged by \(maxSkirtDisparity) dB (bound \(d))")
    }

    @Test func emptyBandsDoNotCapAnActiveBandsLift() {
        // An empty (gated) band carries no spectral-balance information, so
        // it must not limit its active neighbour's lift: a lone quiet tone
        // in band 3 is lifted well past D although bands 2 and 4 are empty.
        // (The alternative -- empty bands as references -- read -4 dB on
        // the gate's quiet_ballad scenario, 2026-10-10.)
        var leveler = makeLeveler(maxGainDB: 18.0)
        for i in 0..<Int(sampleRate * 8.0) {
            let t = Float(i) / sampleRate
            let x = 0.03 * sinf(2.0 * Float.pi * 760.0 * t)
            _ = leveler.process(left: x, right: x)
        }
        let d = AdvancedDynamicsLeveler.maxAdjacentBandDisparityDB
        #expect(leveler.bandGainsDBFixed.2 > d + 2.0,
            "a lone tone was lifted only \(leveler.bandGainsDBFixed.2) dB: empty neighbours capped it")
        // ...and the empty neighbours are pulled to within D of it (they
        // are constrained, they just do not constrain).
        #expect(leveler.bandGainsDBFixed.1 >= leveler.bandGainsDBFixed.2 - d - 0.5)
        #expect(leveler.bandGainsDBFixed.3 >= leveler.bandGainsDBFixed.2 - d - 0.5)
    }

    @Test func crossoverLiveChangeIsContinuous() {
        // A live x3 change rebuilds the splitter but must keep every band's
        // gain and detector: the pre-fix reset snapped all bands to unity.
        var leveler = makeLeveler()
        for i in 0..<Int(sampleRate * 4.0) {
            let x = fiveTone(i, amplitude: 0.05)
            _ = leveler.process(left: x, right: x)
        }
        let before = leveler.bandGainsDB
        #expect(before.contains { abs($0) > 2.0 }, "the bed did not move the gains; the test would be vacuous")
        leveler.configureStructure(
            sampleRate: sampleRate, x1Hz: Self.x1, x2Hz: Self.x2, x3Hz: 1_400.0, x4Hz: Self.x4)
        let immediately = leveler.bandGainsDB
        var maxStep: Float = 0.0
        for (a, b) in zip(before, immediately) { maxStep = max(maxStep, abs(a - b)) }
        let start = Int(sampleRate * 4.0)
        for i in 0..<Int(sampleRate * 0.1) {
            let x = fiveTone(start + i, amplitude: 0.05)
            _ = leveler.process(left: x, right: x)
            if i % 48 == 0 {
                for (a, b) in zip(before, leveler.bandGainsDB) { maxStep = max(maxStep, abs(a - b)) }
            }
        }
        #expect(maxStep < 1.0, "band gain stepped \(maxStep) dB across a live crossover change")
    }

    @Test func reconfigureWithSameStructureIsInert() {
        // A re-enable (same rate, same crossovers) must not even flush the
        // splitter: the output sample after the call equals the output a
        // twin that was never reconfigured produces.
        var a = makeLeveler()
        var b = makeLeveler()
        for i in 0..<Int(sampleRate * 1.0) {
            let x = fiveTone(i, amplitude: 0.1)
            _ = a.process(left: x, right: x)
            _ = b.process(left: x, right: x)
        }
        b.configureStructure(sampleRate: sampleRate, x1Hz: Self.x1, x2Hz: Self.x2, x3Hz: Self.x3, x4Hz: Self.x4)
        let start = Int(sampleRate * 1.0)
        for i in 0..<Int(sampleRate * 0.2) {
            let x = fiveTone(start + i, amplitude: 0.1)
            let ya = a.process(left: x, right: x)
            let yb = b.process(left: x, right: x)
            #expect(ya.0 == yb.0 && ya.1 == yb.1)
            if ya.0 != yb.0 { break }
        }
    }

    @Test func nanInputRecovers() {
        var leveler = makeLeveler()
        for i in 0..<Int(sampleRate * 1.0) {
            let x = fiveTone(i, amplitude: 0.1)
            _ = leveler.process(left: x, right: x)
        }
        let poisoned = leveler.process(left: Float.nan, right: 0.1)
        #expect(poisoned.0.isFinite && poisoned.1.isFinite)
        let start = Int(sampleRate * 1.0) + 1
        var finiteAtEnd = true
        var nonZeroAtEnd = false
        for i in 0..<Int(sampleRate * 1.0) {
            let x = fiveTone(start + i, amplitude: 0.1)
            let (l, r) = leveler.process(left: x, right: x)
            if i >= Int(sampleRate * 0.9) {
                finiteAtEnd = finiteAtEnd && l.isFinite && r.isFinite
                nonZeroAtEnd = nonZeroAtEnd || abs(l) > 1e-3
            }
        }
        #expect(finiteAtEnd, "output still non-finite 1 s after a single NaN sample")
        #expect(nonZeroAtEnd, "output stuck at zero after a single NaN sample")
        #expect(leveler.bandGainsDB.allSatisfy { $0.isFinite })
        #expect(leveler.currentDensityDB.isFinite)
    }

    @Test func stereoGainIsLinked() {
        // One gain per band for L and R: a right channel at exactly half the
        // left must come out at exactly half the left, sample for sample.
        var leveler = makeLeveler()
        let delay = leveler.groupDelaySamples
        var maxRelativeError: Float = 0.0
        for i in 0..<Int(sampleRate * 3.0) {
            let x = fiveTone(i, amplitude: 0.12)
            let (l, r) = leveler.process(left: x, right: 0.5 * x)
            if i > delay + 100, abs(l) > 1e-3 {
                maxRelativeError = max(maxRelativeError, abs(r - (0.5 * l)) / abs(l))
            }
        }
        #expect(maxRelativeError < 1e-4, "stereo image moved by a relative \(maxRelativeError)")
    }

    /// Five tones at multiples of 20 Hz, so a 50 ms RMS window holds a
    /// whole number of cycles of each and reads the envelope without ripple.
    private func fadeTone(_ i: Int, amplitude: Float) -> Float {
        let t = Float(i) / sampleRate
        var x: Float = 0.0
        for f in [Float(60.0), 200.0, 760.0, 3_160.0, 9_000.0] {
            x += amplitude * sinf(2.0 * Float.pi * f * t)
        }
        return x
    }

    @Test func slowFadeLiftIsBounded() {
        // A 2 dB/s fade over 8 s: the leveler may slow the fade but must
        // never turn it into a swell -- the output's 50 ms RMS envelope
        // rises at most 1.5 dB above its running minimum.
        var leveler = makeLeveler()
        let settle = Int(sampleRate * 3.0)
        for i in 0..<settle {
            let x = fadeTone(i, amplitude: 0.2)
            _ = leveler.process(left: x, right: x)
        }
        let fadeFrames = Int(sampleRate * 8.0)
        let hop = Int(sampleRate * 0.050)
        var sumSq: Double = 0.0
        var runningMin: Float = 1_000.0
        var maxSwell: Float = 0.0
        var envelopes = 0
        for i in 0..<fadeFrames {
            let t = Float(i) / sampleRate
            let amp = 0.2 * powf(10.0, -2.0 * t / 20.0)
            let x = fadeTone(settle + i, amplitude: amp)
            let (l, _) = leveler.process(left: x, right: x)
            sumSq += Double(l * l)
            if i % hop == hop - 1 {
                let db = Float(10.0 * log10(max(1e-12, sumSq / Double(hop))))
                sumSq = 0.0
                envelopes += 1
                // Skip the first 100 ms (group delay + detector settling).
                if envelopes > 2 {
                    runningMin = min(runningMin, db)
                    maxSwell = max(maxSwell, db - runningMin)
                }
            }
        }
        #expect(maxSwell <= 1.5, "a slow fade swelled by \(maxSwell) dB")
    }
}
