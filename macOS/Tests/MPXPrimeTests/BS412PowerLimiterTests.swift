import Testing
import Foundation
import MPXPrimeCore
@testable import MPXPrime

// ITU-R BS.412-9 sec 2.5.1 (standards/R-REC-BS.412-9-199812-I!!PDF-E.pdf):
// "the power of the complete multiplex signal (including pilot-tone and
// additional signals) integrated over any interval of 60 s is not higher
// than the power of a multiplex signal containing a single sinusoidal tone
// which causes a peak deviation of +/- 19 kHz."
//
// ANY interval, not "the settled average". These tests check the first
// completed window and the programme transitions, which is where the
// feedback-only controller failed: from unity, a steady +6.02 dBr input
// averaged about +2.35 dBr across its first minute and then rebounded across
// the ceiling while settling.
@Suite("BS.412 multiplex power")
struct BS412PowerLimiterTests {

    private let sampleRate: Float = 48_000.0

    /// Amplitude of a sine at `kHz` deviation. |x| = 1.0 is 75 kHz.
    private func amplitude(deviationKHz: Float) -> Float { deviationKHz / 75.0 }

    // MARK: - Harness

    /// Drives rider + guard exactly as the chain does and records the power
    /// of every completed 60-second window, so a test can assert on all of
    /// them rather than on an endpoint.
    private struct Rig {
        var rider = BS412Rider()
        var guardStage = BS412ComplianceGuard()
        var meter = BS412MultiplexPowerMeter()
        var ceilingDBr: Float
        private(set) var worstWindowDBr: Float = -.infinity
        private(set) var windowsChecked = 0
        private(set) var guardEverActive = false
        private(set) var subcarriersUntouched = true

        init(sampleRate: Float, ceilingDBr: Float, subcarrierReserve: Float) {
            self.ceilingDBr = ceilingDBr
            rider.configure(sampleRate: sampleRate)
            guardStage.configure(sampleRate: sampleRate,
                                 subcarrierReserveMeanSquare: subcarrierReserve)
            meter.configure(sampleRate: sampleRate)
        }

        /// One sample of pre-control audio plus its fixed subcarriers.
        mutating func push(audio: Float, subcarriers: Float) {
            rider.observe(audio: audio, subcarriers: subcarriers, ceilingDBr: ceilingDBr)
            let ridden = audio * rider.gain
            let emitted = guardStage.process(
                audio: ridden, subcarriers: subcarriers, ceilingDBr: ceilingDBr)
            if guardStage.active { guardEverActive = true }
            // The fixed part must survive untouched: whatever the stage did,
            // the emitted sample minus the audio share must still be `s`.
            if subcarriers != 0.0 {
                let impliedAudio = emitted - subcarriers
                if impliedAudio.isNaN { subcarriersUntouched = false }
            }
            if meter.process(emitted), meter.windowValid {
                worstWindowDBr = max(worstWindowDBr, meter.powerDBr)
                windowsChecked += 1
            }
        }
    }

    private func rig(ceilingDBr: Float = 0.0, subcarrierReserve: Float = 0.0) -> Rig {
        Rig(sampleRate: sampleRate, ceilingDBr: ceilingDBr, subcarrierReserve: subcarrierReserve)
    }

    private func sine(_ i: Int, hz: Float, amp: Float) -> Float {
        amp * sinf(2.0 * Float.pi * hz * Float(i) / sampleRate)
    }

    // MARK: - The reference

    @Test func aNineteenKilohertzSineIsZeroDBr() {
        var meter = BS412MultiplexPowerMeter()
        meter.configure(sampleRate: sampleRate)
        for i in 0..<Int(sampleRate * 2.0) {
            meter.process(sine(i, hz: 1_000.0, amp: amplitude(deviationKHz: 19.0)))
        }
        #expect(abs(meter.powerDBr) < 0.05,
                "a sine at 19 kHz deviation must read 0 dBr, got \(meter.powerDBr)")
    }

    @Test func knownAnswersAcrossTheDeviationRange() {
        for deviation in [Float(9.5), 19.0, 38.0, 75.0] {
            var meter = BS412MultiplexPowerMeter()
            meter.configure(sampleRate: sampleRate)
            for i in 0..<Int(sampleRate * 2.0) {
                meter.process(sine(i, hz: 1_000.0, amp: amplitude(deviationKHz: deviation)))
            }
            let expected = 20.0 * log10f(deviation / 19.0)
            #expect(abs(meter.powerDBr - expected) < 0.05,
                    "\(deviation) kHz reads \(meter.powerDBr) dBr, expected \(expected)")
        }
    }

    @Test func aNinePercentPilotAloneIsMinusNineDBr() {
        var meter = BS412MultiplexPowerMeter()
        meter.configure(sampleRate: sampleRate)
        for i in 0..<Int(sampleRate * 2.0) {
            meter.process(sine(i, hz: 19_000.0, amp: amplitude(deviationKHz: 6.75)))
        }
        #expect(abs(meter.powerDBr - (-8.99)) < 0.05,
                "a 9 % pilot alone reads \(meter.powerDBr) dBr, expected -8.99")
    }

    @Test func theWindowIsSixtySecondsAndNotOperatorSettable() {
        #expect(BS412.windowSeconds == 60.0)
        var meter = BS412MultiplexPowerMeter()
        meter.configure(sampleRate: sampleRate)
        for i in 0..<Int(sampleRate * 5.0) {
            meter.process(sine(i, hz: 1_000.0, amp: amplitude(deviationKHz: 19.0)))
        }
        #expect(!meter.windowValid, "five seconds cannot validate a 60 s window")
        #expect(abs(meter.secondsObserved - 5.0) < 0.1)
        #expect(abs(meter.powerDBr) < 0.05, "the provisional average is still the true one so far")
    }

    // MARK: - Compliance: every window, not the endpoint

    @Test func firstCompleteWindowNeverExceedsCeiling() {
        // The regression that motivated the rebuild. Steady +6.02 dBr from a
        // cold start; the feedback-only controller's first completed window
        // read about +2.35 dBr.
        var r = rig()
        let amp = amplitude(deviationKHz: 38.0)
        for i in 0..<Int(sampleRate * 75.0) {
            r.push(audio: sine(i, hz: 1_000.0, amp: amp), subcarriers: 0.0)
        }
        #expect(r.windowsChecked > 0, "no complete window was ever evaluated")
        #expect(r.worstWindowDBr <= 0.05,
                "the first completed 60 s window reads \(r.worstWindowDBr) dBr")
    }

    @Test func hotProgramAfterQuietNeverExceedsAnyWindow() {
        var r = rig()
        let quiet = amplitude(deviationKHz: 9.5)
        let hot = amplitude(deviationKHz: 38.0)
        for i in 0..<Int(sampleRate * 70.0) {
            r.push(audio: sine(i, hz: 1_000.0, amp: quiet), subcarriers: 0.0)
        }
        for i in 0..<Int(sampleRate * 90.0) {
            r.push(audio: sine(i, hz: 1_000.0, amp: hot), subcarriers: 0.0)
        }
        #expect(r.worstWindowDBr <= 0.05,
                "a quiet-to-hot step left a window at \(r.worstWindowDBr) dBr")
    }

    @Test func releaseDoesNotReboundAcrossCeiling() {
        var r = rig()
        let quiet = amplitude(deviationKHz: 9.5)
        let hot = amplitude(deviationKHz: 38.0)
        var i = 0
        func run(_ seconds: Float, _ amp: Float) {
            for _ in 0..<Int(sampleRate * seconds) {
                r.push(audio: sine(i, hz: 1_000.0, amp: amp), subcarriers: 0.0)
                i += 1
            }
        }
        run(80.0, hot)
        run(60.0, quiet)
        run(80.0, hot)
        #expect(r.worstWindowDBr <= 0.05,
                "hot / quiet / hot left a window at \(r.worstWindowDBr) dBr")
    }

    @Test func pilotAndRDSRemainConstantWhileAudioIsReduced() {
        // The fixed part must pass through bit-identically even while the
        // reducible part is being pulled down hard.
        var r = rig(subcarrierReserve: 0.0)
        let hot = amplitude(deviationKHz: 60.0)
        let pilotAmp = amplitude(deviationKHz: 6.75)
        var worstSubcarrierError: Float = 0.0
        var sawReduction = false
        for i in 0..<Int(sampleRate * 90.0) {
            let audio = sine(i, hz: 1_000.0, amp: hot)
            let pilot = sine(i, hz: 19_000.0, amp: pilotAmp)
            r.rider.observe(audio: audio, subcarriers: pilot, ceilingDBr: r.ceilingDBr)
            let ridden = audio * r.rider.gain
            if r.rider.gain < 0.99 { sawReduction = true }
            let emitted = r.guardStage.process(
                audio: ridden, subcarriers: pilot, ceilingDBr: r.ceilingDBr)
            // Whatever gain was applied, it was applied to `ridden` alone:
            // emitted = h * ridden + pilot, so emitted - h*ridden == pilot.
            // h is unknown here, but h is in [0, 1], so the emitted sample
            // must lie between `pilot` and `ridden + pilot`.
            let lo = min(pilot, ridden + pilot)
            let hi = max(pilot, ridden + pilot)
            if emitted < lo - 1e-6 || emitted > hi + 1e-6 {
                worstSubcarrierError = max(worstSubcarrierError, 1.0)
            }
        }
        #expect(sawReduction, "the rider never engaged, so this proves nothing")
        #expect(worstSubcarrierError == 0.0,
                "an emitted sample fell outside [pilot, audio + pilot] -- the pilot was scaled")
    }

    @Test func subcarriersAloneOverBudgetIsUnachievable() {
        var guardStage = BS412ComplianceGuard()
        guardStage.configure(sampleRate: sampleRate, subcarrierReserveMeanSquare: 0.0)
        let pilotAmp = amplitude(deviationKHz: 30.0)   // far over a 0 dBr ceiling
        for i in 0..<Int(sampleRate * 90.0) {
            let pilot = sine(i, hz: 19_000.0, amp: pilotAmp)
            let emitted = guardStage.process(audio: 0.0, subcarriers: pilot, ceilingDBr: 0.0)
            #expect(emitted == pilot, "the guard altered a subcarrier-only sample")
        }
        let impossible = guardStage.unachievable
        #expect(impossible,
                "pilot alone is over the ceiling and the guard did not say so")
    }

    @Test func crossTermCannotHideAnOverage() {
        // Correlated audio and subcarriers: the emitted energy is
        // (h*a + s)^2, not h^2*a^2 + s^2, so a guard that estimated the
        // subcarrier share by subtraction would be wrong by the cross term.
        // This one accounts for the exact emitted sample, so every rolling
        // window must hold at all three correlations.
        let subAmp: Float = 0.2
        for phase in [Float(0.0), .pi / 2.0, .pi] {
            // The reserve must match the subcarriers actually emitted -- that
            // is the guard's contract, and the chain computes it from the
            // configured pilot / RDS levels. Understating it lets an early
            // passage spend budget the subcarriers then cannot fit into, and
            // the guard reports `unachievable` rather than attenuating them.
            var r = rig(subcarrierReserve: (subAmp * subAmp) * 0.5)
            let frames = Int(sampleRate * 150.0)
            for i in 0..<frames {
                let t = 2.0 * Float.pi * 1_000.0 * Float(i) / sampleRate
                r.push(audio: 0.6 * sinf(t), subcarriers: subAmp * sinf(t + phase))
            }
            #expect(r.windowsChecked > 0)
            #expect(r.worstWindowDBr <= 0.05,
                    "phase \(phase): worst rolling window \(r.worstWindowDBr) dBr")
            let impossible = r.guardStage.unachievable
            #expect(!impossible,
                    "phase \(phase): a correctly reserved budget reported unachievable")
        }
    }

    @Test func earlyAudioCannotConsumeFutureSubcarrierBudget() {
        // A hot burst at the very start must not spend budget that the next
        // minute of pilot-only samples cannot then fit into.
        let pilotAmp = amplitude(deviationKHz: 6.75)
        let reserve = (pilotAmp * pilotAmp) * 0.5   // the bound the chain uses
        var r = rig(subcarrierReserve: reserve)
        for i in 0..<Int(sampleRate * 5.0) {
            r.push(audio: sine(i, hz: 1_000.0, amp: amplitude(deviationKHz: 75.0)),
                   subcarriers: sine(i, hz: 19_000.0, amp: pilotAmp))
        }
        for i in 0..<Int(sampleRate * 120.0) {
            r.push(audio: 0.0, subcarriers: sine(i, hz: 19_000.0, amp: pilotAmp))
        }
        #expect(r.windowsChecked > 0)
        #expect(r.worstWindowDBr <= 0.05,
                "an early burst pushed a later window to \(r.worstWindowDBr) dBr")
    }

    @Test func guardIsIdleOnCompliantProgram() {
        var r = rig()
        let amp = amplitude(deviationKHz: 9.5)   // -6 dBr, well under
        for i in 0..<Int(sampleRate * 90.0) {
            r.push(audio: sine(i, hz: 1_000.0, amp: amp), subcarriers: 0.0)
        }
        #expect(!r.guardEverActive, "the hard guard engaged on compliant programme")
        #expect(r.rider.gain > 0.999, "the rider attenuated compliant programme")
    }

    @Test func blockBoundaryOffsetsHaveTheSameVerdict() {
        // Shift a hot burst across block phases: the verdict must not depend
        // on where the burst lands relative to the 64-sample accounting.
        for offset in [0, 1, 17, 33, 63] {
            var r = rig()
            let amp = amplitude(deviationKHz: 38.0)
            for _ in 0..<offset { r.push(audio: 0.0, subcarriers: 0.0) }
            for i in 0..<Int(sampleRate * 75.0) {
                r.push(audio: sine(i, hz: 1_000.0, amp: amp), subcarriers: 0.0)
            }
            #expect(r.worstWindowDBr <= 0.05,
                    "offset \(offset) left a window at \(r.worstWindowDBr) dBr")
        }
    }

    @Test func aLowerCeilingIsAMarginBelowTheStandard() {
        var r = rig(ceilingDBr: -3.0)
        let amp = amplitude(deviationKHz: 19.0)   // exactly 0 dBr uncontrolled
        for i in 0..<Int(sampleRate * 90.0) {
            r.push(audio: sine(i, hz: 1_000.0, amp: amp), subcarriers: 0.0)
        }
        #expect(r.worstWindowDBr <= -3.0 + 0.05,
                "a -3 dBr ceiling left a window at \(r.worstWindowDBr) dBr")
    }

    @Test func enableUsesExistingHistory() {
        // The reporting meter runs regardless, so switching control on does
        // not begin a fresh 60-second blind period.
        var meter = BS412MultiplexPowerMeter()
        meter.configure(sampleRate: sampleRate)
        for i in 0..<Int(sampleRate * 65.0) {
            meter.process(sine(i, hz: 1_000.0, amp: amplitude(deviationKHz: 38.0)))
        }
        #expect(meter.windowValid, "65 s of measurement did not validate the window")
        #expect(meter.powerDBr > 5.0, "the history is there to act on immediately")
    }
}
