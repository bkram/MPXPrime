import Testing
import Foundation
import MPXPrimeCore
@testable import MPXPrime

// The BS.412 rider rides the REMAINING 60-second budget, not every second.
//
// ITU-R BS.412-9 sec 2.5.1 bounds the power "integrated over any interval
// of 60 s". The 0.65 rider held every 1 s prediction window at the ceiling
// with a 50 s release, which is a stronger condition than the Recommendation
// requires: on programme whose 1 s power varies around its mean, the 60 s
// integral landed 1-3 dB under the ceiling (measured here, on the fixture
// below, at -1.74 dB; on air the Meter read +0.4 dBr while the stage cost
// 5.6 dB of audio). The budget rider predicts the next minute from the
// recent power (the far horizon from the quieter of a 5 s mean and the last
// second), plans against the energy already in the window at every horizon
// up to 60 s, books each block at no more than the guard will let through,
// and lets the compliance guard remain the proof.
//
// These tests drive rider + guard + meter exactly as the chain does
// (`BS412PowerLimiterTests.Rig` is the model) on synthetic composites with a
// known per-second power, and check all three properties at once: every
// completed window at or under the ceiling, the integral close to it, and
// the guard idle.
@Suite("BS.412 budget rider")
struct BS412BudgetRiderTests {

    private let sampleRate: Float = 48_000.0

    /// 9 % pilot: 6.75 kHz of 75 kHz. Alone it is -9 dBr.
    private let pilotAmplitude: Float = 6.75 / 75.0

    private var pilotMeanSquare: Float { pilotAmplitude * pilotAmplitude * 0.5 }

    /// Amplitude of a 1 kHz audio sine such that audio + pilot together read
    /// `totalDBr` on the complete multiplex.
    private func audioAmplitude(totalDBr: Float) -> Float {
        let total = BS412.meanSquare(forDBr: totalDBr)
        let audio = max(0.0, total - pilotMeanSquare)
        return sqrtf(2.0 * audio)
    }

    /// Deterministic uniform noise in [-1, 1] (LCG), so the programme is the
    /// same on every run and every platform.
    private struct Noise {
        private var state: UInt32
        init(seed: UInt32) { state = seed }
        mutating func next() -> Float {
            state = 1_103_515_245 &* state &+ 12_345
            let unit = Float(state & 0x7FFF_FFFF) / Float(0x7FFF_FFFF)
            return 2.0 * unit - 1.0
        }
    }

    // MARK: - Harness

    private struct Rig {
        var rider = BS412Rider()
        var guardStage = BS412ComplianceGuard()
        var meter = BS412MultiplexPowerMeter()
        let ceilingDBr: Float
        let sampleRate: Float

        /// Power of every completed 60 s window, in dBr, in order.
        private(set) var windowsDBr: [Float] = []
        /// Power of every completed second of the emitted multiplex, dBr.
        private(set) var secondsDBr: [Float] = []
        private(set) var guardEngagedSamples = 0
        private(set) var samples = 0
        private var secondEnergy: Double = 0.0
        private var secondSamples = 0

        init(sampleRate: Float, ceilingDBr: Float, pilotMeanSquare: Float) {
            self.sampleRate = sampleRate
            self.ceilingDBr = ceilingDBr
            rider.configure(sampleRate: sampleRate)
            guardStage.configure(sampleRate: sampleRate,
                                 subcarrierReserveMeanSquare: pilotMeanSquare)
            meter.configure(sampleRate: sampleRate)
        }

        mutating func push(audio: Float, subcarriers: Float) {
            rider.observe(audio: audio, subcarriers: subcarriers, ceilingDBr: ceilingDBr)
            let ridden = audio * rider.gain
            let emitted = guardStage.process(
                audio: ridden, subcarriers: subcarriers, ceilingDBr: ceilingDBr,
                enforcing: true)
            // The guard returns `ridden + subcarriers` untouched unless it
            // solved a gain for this sample, so an exact comparison is the
            // per-sample engagement count.
            if emitted != ridden + subcarriers { guardEngagedSamples += 1 }
            samples += 1
            secondEnergy += Double(emitted) * Double(emitted)
            secondSamples += 1
            if secondSamples >= Int(sampleRate) {
                let meanSquare = Float(secondEnergy / Double(secondSamples))
                secondsDBr.append(BS412.dBr(forMeanSquare: meanSquare))
                secondEnergy = 0.0
                secondSamples = 0
            }
            if meter.process(emitted), meter.windowValid {
                windowsDBr.append(meter.powerDBr)
            }
        }

        var guardEngagedPercent: Float {
            100.0 * Float(guardEngagedSamples) / Float(max(1, samples))
        }
    }

    private func rig(ceilingDBr: Float = 0.0) -> Rig {
        Rig(sampleRate: sampleRate, ceilingDBr: ceilingDBr, pilotMeanSquare: pilotMeanSquare)
    }

    /// Feed `seconds` of programme whose total power is `levelDBr(second)`.
    private func run(_ r: inout Rig, seconds: Int, from start: Int = 0,
                     levelDBr: (Int) -> Float) {
        let perSecond = Int(sampleRate)
        for second in 0..<seconds {
            let amp = audioAmplitude(totalDBr: levelDBr(second))
            let base = (start + second) * perSecond
            for k in 0..<perSecond {
                let i = Float(base + k)
                let audio = amp * sinf(2.0 * Float.pi * 1_000.0 * i / sampleRate)
                let pilot = pilotAmplitude * sinf(2.0 * Float.pi * 19_000.0 * i / sampleRate)
                r.push(audio: audio, subcarriers: pilot)
            }
        }
    }

    private func mean(_ values: ArraySlice<Float>) -> Float {
        values.isEmpty ? .nan : values.reduce(0.0, +) / Float(values.count)
    }

    // MARK: - The property

    /// Programme whose 1 s power varies by +/-3 dB around +2 dBr for 180 s.
    /// Every completed window must sit at or under the ceiling, the integral
    /// must sit close to it, and the guard must have stayed the proof.
    ///
    /// Before this rework (1 s prediction, 50 s release) the same fixture
    /// completed its windows at -1.74 dBr on average (worst -1.57, lowest
    /// -1.97): the programme's 1 s power spread, given away. The budget
    /// rider completes them at -0.10 dBr (worst -0.02, lowest -0.19).
    @Test func interleavedProgrammeRidesTheSixtySecondBudget() {
        var r = rig()
        var noise = Noise(seed: 1)
        run(&r, seconds: 180) { _ in 2.0 + 3.0 * noise.next() }

        #expect(r.windowsDBr.count > 100, "fixture problem: \(r.windowsDBr.count) windows completed")
        // swiftlint:disable force_unwrapping
        let worst = r.windowsDBr.max()!
        let lowest = r.windowsDBr.min()!
        let last = r.windowsDBr.last!
        // swiftlint:enable force_unwrapping
        let integral = mean(r.windowsDBr[...])
        print(String(format: """
            BS.412 budget rider, +2 dBr +/-3 dB per second for 180 s: \
            worst window %+.3f dBr, mean %+.3f, lowest %+.3f, last %+.3f, \
            guard engaged on %.4f %% of samples
            """, worst, integral, lowest, last, r.guardEngagedPercent))

        // (a) ANY interval of 60 s: every completed window.
        #expect(worst <= 0.01, "a completed 60 s window reads \(worst) dBr")
        // (b) The integral rides the ceiling instead of the loudest second.
        #expect(integral >= -0.3,
                "the completed windows average \(integral) dBr -- the rider is holding seconds, not the minute")
        #expect(lowest >= -0.5,
                "a completed window fell to \(lowest) dBr on programme that is +2 dBr before control")
        // (c) The guard is the proof, not the worker.
        #expect(r.guardEngagedPercent < 0.1,
                "the guard engaged on \(r.guardEngagedPercent) % of samples")
    }

    /// The same programme from a cold start: the FIRST completed window
    /// counts too, and nothing before it may be muted to get there.
    @Test func theFirstWindowIsPacedNotRepaidWithSilence() {
        var r = rig()
        var noise = Noise(seed: 7)
        run(&r, seconds: 75) { _ in 2.0 + 3.0 * noise.next() }
        #expect(!r.windowsDBr.isEmpty)
        // swiftlint:disable force_unwrapping
        #expect(r.windowsDBr.max()! <= 0.01,
                "the first completed window reads \(r.windowsDBr.max()!) dBr")
        // swiftlint:enable force_unwrapping
        // Pre-control the quietest second is -1 dBr and the pilot alone is
        // -9 dBr; a rider that spends the first window's budget early and
        // then starves shows seconds down at the pilot.
        // swiftlint:disable:next force_unwrapping
        let quietest = r.secondsDBr.dropFirst().min()!
        #expect(quietest > -5.0, "a second was ridden down to \(quietest) dBr (budget spent early, repaid with silence)")
    }

    /// A sustained level step is where a controller that spends the window's
    /// deficit greedily pumps: a quiet minute followed by a hot passage
    /// would pass the hot audio at full level until the budget is gone, then
    /// hold it 6 dB under the ceiling for the rest of the minute. The budget
    /// rider must instead repay the few seconds of lag as a shallow, flat
    /// sag, and the window wholly inside the hot passage must still be
    /// compliant. The 1 s / 50 s rider failed this differently: its lag
    /// excess exceeded its margin band, so the guard clamped the last second
    /// of the first hot minute to -6.00 dBr (0.62 % of samples).
    @Test func aSustainedStepRepaysAsAShallowSagNotADeepCut() {
        var r = rig()
        run(&r, seconds: 60) { _ in -6.0 }
        run(&r, seconds: 90, from: 60) { _ in 6.0 }
        // swiftlint:disable force_unwrapping
        #expect(r.windowsDBr.max()! <= 0.01,
                "a window across or after the step reads \(r.windowsDBr.max()!) dBr")
        // swiftlint:enable force_unwrapping
        // Seconds 66..149: the hot passage after the prediction has caught
        // up. The repayment of the lag must be shallow and the level must
        // never be pushed back over the ceiling.
        let settled = r.secondsDBr[66..<150]
        // swiftlint:disable force_unwrapping
        let deepest = settled.min()!
        let highest = settled.max()!
        // swiftlint:enable force_unwrapping
        print(String(format: "BS.412 budget rider, -6 -> +6 dBr step: hot passage settles between %+.2f and %+.2f dBr, guard %.4f %%",
                     deepest, highest, r.guardEngagedPercent))
        #expect(deepest >= -1.0, "the hot passage was cut to \(deepest) dBr (deficit spent, then repaid with a deep cut)")
        #expect(highest <= 0.1, "the hot passage sat at \(highest) dBr")
        #expect(r.guardEngagedPercent < 0.1)
    }

    /// Lowering the ceiling live leaves the rider's own ledger over the new
    /// budget. Like the guard, it must forgive that history and ride at the
    /// new ceiling, not mute until the old minute has aged out.
    @Test func loweringTheCeilingLiveForgivesTheRidersLedger() {
        var r = rig(ceilingDBr: 0.0)
        run(&r, seconds: 65) { _ in 6.0 }
        let forgivenBefore = r.rider.historyForgivenCount
        var lowered = Rig(sampleRate: sampleRate, ceilingDBr: -3.0, pilotMeanSquare: pilotMeanSquare)
        lowered.rider = r.rider
        lowered.guardStage = r.guardStage
        lowered.meter = r.meter
        run(&lowered, seconds: 30, from: 65) { _ in 6.0 }
        #expect(lowered.rider.historyForgivenCount == forgivenBefore + 1,
                "the rider's ledger was not forgiven after the ceiling dropped")
        // swiftlint:disable force_unwrapping
        let afterDrop = lowered.secondsDBr.dropFirst().min()!
        // swiftlint:enable force_unwrapping
        #expect(afterDrop > -3.5, "second after lowering read \(afterDrop) dBr (muted)")
    }

    /// A loud burst on ceiling-riding programme. While it lasts the rider
    /// holds it (after the one second of prediction lag); when it ends the
    /// plan must follow the drop within seconds, not hold the burst's level
    /// for the length of its long mean. With the far horizon predicted from
    /// the 5 s mean alone the return was cut to -4.9 dBr and took 7 s to
    /// recover; predicting it from the quieter of the two means recovers in
    /// 3 s. The 1 s / 50 s rider cut it to -4.8 dBr and was still 1.3 dB
    /// down a minute later.
    @Test func aBurstDoesNotHoldTheProgrammeDownAfterItEnds() {
        var r = rig()
        run(&r, seconds: 70) { _ in 2.0 }
        run(&r, seconds: 5, from: 70) { _ in 8.0 }
        run(&r, seconds: 30, from: 75) { _ in 2.0 }
        // swiftlint:disable force_unwrapping
        #expect(r.windowsDBr.max()! <= 0.01,
                "a window across the burst reads \(r.windowsDBr.max()!) dBr")
        // swiftlint:enable force_unwrapping
        let afterBurst = Array(r.secondsDBr[75..<85])
        print(String(format: "BS.412 budget rider, 5 s +8 dBr burst on +2 dBr: return profile %@, guard %.4f %%",
                     afterBurst.map { String(format: "%+.1f", $0) }.joined(separator: " "), r.guardEngagedPercent))
        // Second 0 after the burst is the prediction lag on the way down;
        // from the fourth second on the programme must be back on the
        // ceiling.
        for (offset, level) in afterBurst.enumerated() where offset >= 3 {
            #expect(level >= -0.5, "second \(offset) after the burst still reads \(level) dBr")
        }
        #expect(r.guardEngagedPercent < 0.3)
    }

    /// A step up from a ceiling-riding state. The one second of prediction
    /// lag passes hot and the guard removes what exceeds its own limit; the
    /// rider must not then repay that same energy a second time. Before the
    /// ledger cap the seconds after the step read -1.1 -0.9 -0.7 -0.5 -0.3;
    /// with it -0.8 -0.7 -0.5 -0.3 (the in-band debt only).
    @Test func theRiderDoesNotRepayWhatTheGuardAlreadyRemoved() {
        var r = rig()
        run(&r, seconds: 70) { _ in 2.0 }
        run(&r, seconds: 30, from: 70) { _ in 8.0 }
        // swiftlint:disable force_unwrapping
        #expect(r.windowsDBr.max()! <= 0.01)
        let repayment = r.secondsDBr[71..<80].min()!
        // swiftlint:enable force_unwrapping
        print(String(format: "BS.412 budget rider, +2 -> +8 dBr step from the ceiling: deepest repayment second %+.2f dBr, guard %.4f %%",
                     repayment, r.guardEngagedPercent))
        #expect(repayment >= -1.0, "the repayment after the lag second reached \(repayment) dBr")
        #expect(r.rider.historyForgivenCount == 0, "prediction-lag debt was forgiven as if the ceiling had moved")
        #expect(r.guardEngagedPercent < 0.3)
    }

    // MARK: - The shared ledger

    /// The guard and the rider plan from the same window arithmetic. Pin
    /// the ledger's three readings against a hand-computed window so a
    /// change in one consumer cannot silently move the other.
    @Test func theWindowLedgerAccountsUnobservedSlotsAndAgedEnergy() {
        var ledger = BS412WindowLedger()
        let sr: Float = 48_000.0
        ledger.configure(sampleRate: sr, horizonSeconds: [1.0, 60.0])
        let charge: Float = 0.5
        ledger.setUnobservedCharge(meanSquare: charge)
        let blocks = ledger.blocksPerWindow
        let perBlockCharge = Double(charge) * Double(BS412.decimation)

        // Cold: everything is charge.
        #expect(abs(ledger.totalEnergy - perBlockCharge * Double(blocks)) < 1e-6)
        #expect(abs(ledger.agedEnergy(horizonIndex: 0) - perBlockCharge * Double(ledger.horizonBlocks[0])) < 1e-6)

        // Commit two seconds of a known block energy.
        let perSecond = ledger.horizonBlocks[0]
        for _ in 0..<(2 * perSecond) { ledger.commit(blockEnergy: 2.0) }
        let observed = 2 * perSecond
        #expect(ledger.observedBlocks == observed)
        let expectedTotal = 2.0 * Double(observed) + perBlockCharge * Double(blocks - observed)
        #expect(abs(ledger.totalEnergy - expectedTotal) < 1e-6)
        // The oldest second is still unobserved while filling.
        #expect(abs(ledger.agedEnergy(horizonIndex: 0) - perBlockCharge * Double(perSecond)) < 1e-6)
        // pastEnergy: the window after the next commit, less the slot it
        // replaces -- an unobserved slot here, so one charge fewer.
        let pastExpected = 2.0 * Double(observed) + perBlockCharge * Double(blocks - observed - 1)
        #expect(abs(ledger.pastEnergy - pastExpected) < 1e-6)

        // Fill the window completely with 1.0 per block, then the oldest
        // second is the 2.0 blocks written first.
        for _ in 0..<(blocks - observed) { ledger.commit(blockEnergy: 1.0) }
        #expect(ledger.observedBlocks == blocks)
        let oldestSecond = 2.0 * Double(perSecond)
        #expect(abs(ledger.agedEnergy(horizonIndex: 0) - oldestSecond) < 1e-6)
        let fullTotal = (2.0 * Double(observed)) + Double(blocks - observed)
        #expect(abs(ledger.totalEnergy - fullTotal) < 1e-6)
        // The full-window horizon reads the whole window.
        #expect(abs(ledger.agedEnergy(horizonIndex: 1) - ledger.totalEnergy) < 1e-6)
        // Reset forgets history but keeps the charge.
        ledger.reset()
        #expect(ledger.observedBlocks == 0)
        #expect(abs(ledger.unobservedChargeMeanSquare - charge) < 1e-9)
        let coldTotal = perBlockCharge * Double(blocks)
        #expect(abs(ledger.totalEnergy - coldTotal) < 1e-6)
    }
}
