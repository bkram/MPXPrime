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

        mutating func resetWorstWindow() {
            worstWindowDBr = -.infinity
            windowsChecked = 0
        }

        init(sampleRate: Float, ceilingDBr: Float, subcarrierReserve: Float) {
            self.ceilingDBr = ceilingDBr
            rider.configure(sampleRate: sampleRate)
            guardStage.configure(sampleRate: sampleRate,
                                 subcarrierReserveMeanSquare: subcarrierReserve)
            meter.configure(sampleRate: sampleRate)
        }

        var enforcing = true

        /// One sample of pre-control audio plus its fixed subcarriers.
        mutating func push(audio: Float, subcarriers: Float) {
            rider.observe(audio: audio, subcarriers: subcarriers, ceilingDBr: ceilingDBr)
            let ridden = enforcing ? audio * rider.gain : audio
            let emitted = guardStage.process(
                audio: ridden, subcarriers: subcarriers, ceilingDBr: ceilingDBr,
                enforcing: enforcing)
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
                audio: ridden, subcarriers: pilot, ceilingDBr: r.ceilingDBr,
                enforcing: true)
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
            let emitted = guardStage.process(
                audio: 0.0, subcarriers: pilot, ceilingDBr: 0.0, enforcing: true)
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

    // MARK: - Regressions from the 2026-09-11 review

    @Test func enablingActsOnRealHistoryNotAFreshWindow() {
        // The previous version of this test only checked that a STANDALONE
        // meter had history -- it never toggled the controller, so it could
        // not see that the rider and guard only advanced while enabled.
        //
        // Note what this can and cannot claim: audio already transmitted
        // cannot be un-transmitted, so a window straddling the moment of
        // enabling is over the ceiling by arithmetic. What must be true is
        // that control starts INFORMED -- the rider already knows the
        // programme is hot -- and that windows lying wholly after the
        // switch are compliant without a 60-second wait.
        var r = rig()
        r.enforcing = false
        let hot = amplitude(deviationKHz: 38.0)
        var i = 0
        func run(_ seconds: Float) {
            for _ in 0..<Int(sampleRate * seconds) {
                r.push(audio: sine(i, hz: 1_000.0, amp: hot), subcarriers: 0.0)
                i += 1
            }
        }
        run(70.0)
        #expect(r.worstWindowDBr > 5.0,
                "the disabled stage should not have altered anything, got \(r.worstWindowDBr) dBr")

        // The instant of enabling: the rider must ALREADY be asking for
        // reduction, because it has been observing all along. On the old
        // code it sat at unity here and had to learn from scratch.
        let gainAtEnable = r.rider.gain
        #expect(gainAtEnable < 0.9,
                "the rider was at \(gainAtEnable) when enabled -- it had no history")

        r.enforcing = true
        // Let the pre-enable audio age out of the window, then judge only
        // windows that lie wholly after the switch.
        run(70.0)
        r.resetWorstWindow()
        run(70.0)
        #expect(r.windowsChecked > 0)
        #expect(r.worstWindowDBr <= 0.05,
                "a window wholly after enabling reads \(r.worstWindowDBr) dBr")
    }

    @Test func aLivePilotIncreaseUpdatesTheGuardsReserve() {
        // Pilot level and the deviation scale are live-apply and both feed
        // the reserve charged to not-yet-emitted slots. Leaving it stale
        // under-charges them, and a completed window ran over at +0.47 dBr
        // against a 0 dBr ceiling.
        let smallPilot = amplitude(deviationKHz: 3.0)
        let bigPilot = amplitude(deviationKHz: 12.0)
        var r = rig(subcarrierReserve: (smallPilot * smallPilot) * 0.5)
        var i = 0
        // Warm-up at the small pilot, then the operator raises it.
        for _ in 0..<Int(sampleRate * 10.0) {
            r.push(audio: sine(i, hz: 1_000.0, amp: amplitude(deviationKHz: 30.0)),
                   subcarriers: sine(i, hz: 19_000.0, amp: smallPilot))
            i += 1
        }
        r.guardStage.setSubcarrierReserve((bigPilot * bigPilot) * 0.5)
        for _ in 0..<Int(sampleRate * 120.0) {
            r.push(audio: sine(i, hz: 1_000.0, amp: amplitude(deviationKHz: 30.0)),
                   subcarriers: sine(i, hz: 19_000.0, amp: bigPilot))
            i += 1
        }
        #expect(r.windowsChecked > 0)
        #expect(r.worstWindowDBr <= 0.05,
                "a live pilot increase left a completed window at \(r.worstWindowDBr) dBr")
    }

    @Test func aReserveChangeKeepsTheAccumulatedWindow() {
        // The reserve is not stored in the ring, so updating it is O(1) and
        // must not discard measured history -- otherwise a live pilot edit
        // would blank the compliance window it is supposed to protect.
        var guardStage = BS412ComplianceGuard()
        guardStage.configure(sampleRate: sampleRate, subcarrierReserveMeanSquare: 0.0)
        for i in 0..<Int(sampleRate * 10.0) {
            _ = guardStage.process(audio: sine(i, hz: 1_000.0, amp: 0.3),
                                   subcarriers: 0.0, ceilingDBr: 0.0, enforcing: true)
        }
        let before = guardStage.windowEnergy
        #expect(before > 0.0)
        guardStage.setSubcarrierReserve(0.005)
        #expect(guardStage.windowEnergy == before,
                "changing the reserve discarded the accumulated window")
    }

    @Test func anIsolatedGuardEventStaysVisibleToTelemetry() {
        // Telemetry is sampled per render block, and on ALSA only every
        // fourth period. An eight-sample flag is 42 us at 192 kHz -- an
        // isolated intervention was already false by the next publication
        // point, so it may as well not have been reported.
        let sr: Float = 192_000.0
        var guardStage = BS412ComplianceGuard()
        guardStage.configure(sampleRate: sr, subcarrierReserveMeanSquare: 0.0)
        // Spend the window budget, then force one intervention.
        for i in 0..<Int(sr * 61.0) {
            let x = 0.9 * sinf(2.0 * Float.pi * 1_000.0 * Float(i) / sr)
            _ = guardStage.process(audio: x, subcarriers: 0.0,
                                   ceilingDBr: 0.0, enforcing: true)
        }
        #expect(guardStage.active, "the guard should be working on a signal this hot")
        // Now go silent and sample at a realistic publication distance: a
        // 512-sample block, and four of them for the ALSA case.
        for _ in 0..<512 {
            _ = guardStage.process(audio: 0.0, subcarriers: 0.0,
                                   ceilingDBr: 0.0, enforcing: true)
        }
        #expect(guardStage.active,
                "the intervention was invisible one 512-sample block later")
        for _ in 0..<(512 * 3) {
            _ = guardStage.process(audio: 0.0, subcarriers: 0.0,
                                   ceilingDBr: 0.0, enforcing: true)
        }
        #expect(guardStage.active,
                "the intervention was invisible four blocks later, which is the ALSA rate")
    }

    /// Component tests above drive the rider and guard directly, so they
    /// cannot see a WIRING mistake -- and two of the three defects this
    /// section fixes were exactly that. This one goes through the generator.
    @Test func theGeneratorRunsTheMeterWithTheStageDisabled() {
        var cfg = AppConfig()
        cfg.sampleRate = 192_000.0
        cfg.blockSize = 4096
        cfg.operatingMode = .mpx
        cfg.enRDS = false
        cfg.bs412Enabled = false          // DISABLED on purpose
        let generator = MPXGenerator(config: cfg, sampleRate: 192_000.0)
        let frames = Int(192_000.0 * 1.0)
        var left = [Float](repeating: 0.0, count: frames)
        var right = [Float](repeating: 0.0, count: frames)
        for i in 0..<frames {
            let v = Float(0.3 * sin(2.0 * Double.pi * 440.0 * Double(i) / 192_000.0))
            left[i] = v
            right[i] = v
        }
        left.withUnsafeMutableBufferPointer { lb in
            right.withUnsafeMutableBufferPointer { rb in
                // swiftlint:disable force_unwrapping
                generator.renderFromInputInPlace(
                    frameCount: frames, left: lb.baseAddress!, right: rb.baseAddress!)
                // swiftlint:enable force_unwrapping
            }
        }
        let status = generator.bs412Status
        #expect(status.secondsObserved > 0.9,
                """
                one second rendered with BS.412 off advanced the window by \
                \(status.secondsObserved) s -- the reporting meter is not wired \
                unconditionally, so enabling the stage would start a blind minute
                """)
        #expect(!status.powerValid, "a one-second window must not be called valid")
        #expect(status.powerDBr.isFinite)
    }

    @Test func theReportingMeterStillRunsWithTheStageOff() {
        var meter = BS412MultiplexPowerMeter()
        meter.configure(sampleRate: sampleRate)
        for i in 0..<Int(sampleRate * 65.0) {
            meter.process(sine(i, hz: 1_000.0, amp: amplitude(deviationKHz: 38.0)))
        }
        #expect(meter.windowValid, "65 s of measurement did not validate the window")
        #expect(meter.powerDBr > 5.0, "the history is there to act on immediately")
    }
}
