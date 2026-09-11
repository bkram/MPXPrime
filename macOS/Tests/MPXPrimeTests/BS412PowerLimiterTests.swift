import Testing
import Foundation
import MPXPrimeCore
@testable import MPXPrime

// ITU-R BS.412-9 sec 2.5.1 defines multiplex power as the power of the
// COMPLETE multiplex signal -- pilot and additional signals included --
// integrated over ANY 60-second interval, referenced to the power of a sine
// causing +/- 19 kHz deviation (0 dBr).
//
// The pre-0.60 stage met none of those three conditions: it observed the
// audio composite BEFORE pilot / RDS injection, treated its threshold as dB
// relative to normalised full-scale power (on which the shipped default of
// -10 was about +4.9 dBr, five dB ABOVE the limit it claimed to enforce),
// and let the operator choose 30 to 90 seconds while the UI still said
// BS.412. Its own tests used the same internally-consistent dBFS arithmetic
// on both sides, so they passed (0.60 audit, P0-6).
//
// These tests measure against the STANDARD's reference, not the
// implementation's.
@Suite("BS.412 multiplex power")
struct BS412PowerLimiterTests {

    private let sampleRate: Float = 48_000.0

    /// Amplitude of a sine at `kHz` of deviation. The composite is
    /// normalised so |x| = 1.0 is 75 kHz.
    private func amplitude(deviationKHz: Float) -> Float { deviationKHz / 75.0 }

    private func feed(
        _ meter: inout BS412MultiplexPowerMeter,
        seconds: Float, freqHz: Float, deviationKHz: Float,
        subcarrierShare: Float = 0.0
    ) {
        let amp = amplitude(deviationKHz: deviationKHz)
        let omega = 2.0 * Float.pi * freqHz / sampleRate
        let frames = Int(seconds * sampleRate)
        for i in 0..<frames {
            let x = amp * sinf(omega * Float(i))
            meter.process(total: x, subcarriers: x * subcarrierShare)
        }
    }

    // MARK: - The reference

    @Test func aNineteenKilohertzSineIsZeroDBr() {
        // The definition of 0 dBr, straight from the Recommendation.
        var meter = BS412MultiplexPowerMeter()
        meter.configure(sampleRate: sampleRate)
        feed(&meter, seconds: 2.0, freqHz: 1_000.0, deviationKHz: 19.0)
        #expect(abs(meter.powerDBr) < 0.05,
                "a sine at 19 kHz deviation must read 0 dBr, got \(meter.powerDBr)")
    }

    @Test func knownAnswersAcrossTheDeviationRange() {
        // A sine at D kHz deviation has power 20*log10(D/19) dBr.
        for deviation in [Float(9.5), 19.0, 38.0, 75.0] {
            var meter = BS412MultiplexPowerMeter()
            meter.configure(sampleRate: sampleRate)
            feed(&meter, seconds: 2.0, freqHz: 1_000.0, deviationKHz: deviation)
            let expected = 20.0 * log10f(deviation / 19.0)
            #expect(abs(meter.powerDBr - expected) < 0.05,
                    "\(deviation) kHz reads \(meter.powerDBr) dBr, expected \(expected)")
        }
    }

    @Test func aNinePercentPilotAloneIsMinusNineDBr() {
        // 9 % injection is 6.75 kHz of deviation: 20*log10(6.75/19) = -8.99
        // dBr. This is the figure the old stage could not see at all, because
        // it measured before injection -- and it is a tenth of the budget.
        var meter = BS412MultiplexPowerMeter()
        meter.configure(sampleRate: sampleRate)
        feed(&meter, seconds: 2.0, freqHz: 19_000.0, deviationKHz: 6.75)
        #expect(abs(meter.powerDBr - (-8.99)) < 0.05,
                "a 9 % pilot alone reads \(meter.powerDBr) dBr, expected -8.99")
    }

    @Test func theWindowIsSixtySecondsAndNotOperatorSettable() {
        #expect(BS412MultiplexPowerMeter.windowSeconds == 60.0)
        var meter = BS412MultiplexPowerMeter()
        meter.configure(sampleRate: sampleRate)
        feed(&meter, seconds: 5.0, freqHz: 1_000.0, deviationKHz: 19.0)
        #expect(!meter.primed, "five seconds cannot prime a 60 s window")
        #expect(abs(meter.secondsObserved - 5.0) < 0.1,
                "observed \(meter.secondsObserved) s after feeding 5 s")
        // The partial reading is still the true average so far, which is what
        // makes limiting before the window fills legitimate.
        #expect(abs(meter.powerDBr) < 0.05)
    }

    @Test func theWindowSlidesRatherThanResetting() {
        // Loud for a while, then quiet: the reading must fall gradually as
        // the loud part ages out, not jump.
        var meter = BS412MultiplexPowerMeter()
        meter.configure(sampleRate: sampleRate)
        feed(&meter, seconds: 10.0, freqHz: 1_000.0, deviationKHz: 38.0)
        let loud = meter.powerDBr
        feed(&meter, seconds: 10.0, freqHz: 1_000.0, deviationKHz: 9.5)
        let mixed = meter.powerDBr
        #expect(loud > mixed, "the average did not fall when the programme got quieter")
        #expect(mixed > 20.0 * log10f(9.5 / 19.0),
                "the window forgot the loud half instead of averaging it")
    }

    // MARK: - The controller

    @Test func theControllerHoldsTheCompleteMultiplexAtTheCeiling() {
        // Programme 6 dB over the ceiling, with no subcarriers: the audio
        // gain must settle where total power sits at the ceiling.
        //
        // Five minutes of signal, because an average-power limit cannot
        // settle faster than the average it reads: the loop is deliberately
        // slow against the 60 s window (a 1 s loop oscillated between 0.05
        // and 0.96 forever, measured).
        var meter = BS412MultiplexPowerMeter()
        var controller = BS412GainController()
        meter.configure(sampleRate: sampleRate)
        controller.configure(sampleRate: sampleRate)
        let amp = amplitude(deviationKHz: 38.0)   // +6.02 dBr
        let omega = 2.0 * Float.pi * 1_000.0 / sampleRate
        var gain: Float = 1.0
        for i in 0..<Int(480.0 * sampleRate) {
            let audio = amp * sinf(omega * Float(i)) * gain
            if meter.process(total: audio, subcarriers: 0.0) {
                gain = controller.update(meter: meter, ceilingDBr: 0.0)
            }
        }
        // Total power now at the ceiling means the audio was pulled down by
        // the 6 dB it was over.
        #expect(abs(meter.powerDBr) < 0.1,
                "settled at \(meter.powerDBr) dBr instead of the 0 dBr ceiling")
        #expect(abs(controller.gainReductionDB - 6.02) < 0.3,
                "gain reduction \(controller.gainReductionDB) dB, expected about 6")
        #expect(!controller.unachievable)
    }

    @Test func theControllerLeavesACompliantSignalAlone() {
        var meter = BS412MultiplexPowerMeter()
        var controller = BS412GainController()
        meter.configure(sampleRate: sampleRate)
        controller.configure(sampleRate: sampleRate)
        let amp = amplitude(deviationKHz: 9.5)   // -6 dBr
        let omega = 2.0 * Float.pi * 1_000.0 / sampleRate
        var gain: Float = 1.0
        for i in 0..<Int(10.0 * sampleRate) {
            let audio = amp * sinf(omega * Float(i)) * gain
            if meter.process(total: audio, subcarriers: 0.0) {
                gain = controller.update(meter: meter, ceilingDBr: 0.0)
            }
        }
        #expect(gain > 0.999, "a compliant signal was attenuated: gain \(gain)")
        #expect(controller.gainReductionDB < 0.01)
    }

    @Test func theControllerAccountsForSubcarriersItCannotReduce() {
        // Pilot + RDS take part of the budget permanently. The audio gain has
        // to solve for what is LEFT, or the total stays over the ceiling --
        // which is exactly what measuring before injection could not do.
        var meter = BS412MultiplexPowerMeter()
        var controller = BS412GainController()
        meter.configure(sampleRate: sampleRate)
        controller.configure(sampleRate: sampleRate)
        let audioAmp = amplitude(deviationKHz: 38.0)
        let pilotAmp = amplitude(deviationKHz: 6.75)
        let audioW = 2.0 * Float.pi * 1_000.0 / sampleRate
        let pilotW = 2.0 * Float.pi * 19_000.0 / sampleRate
        var gain: Float = 1.0
        for i in 0..<Int(300.0 * sampleRate) {
            let audio = audioAmp * sinf(audioW * Float(i)) * gain
            let pilot = pilotAmp * sinf(pilotW * Float(i))
            if meter.process(total: audio + pilot, subcarriers: pilot) {
                gain = controller.update(meter: meter, ceilingDBr: 0.0)
            }
        }
        #expect(abs(meter.powerDBr) < 0.15,
                "complete multiplex settled at \(meter.powerDBr) dBr, not the ceiling")
        // The pilot eats a tenth of the budget, so the audio must come down
        // MORE than the 6 dB it would need on its own.
        #expect(controller.gainReductionDB > 6.2,
                "audio only came down \(controller.gainReductionDB) dB -- the subcarrier share was ignored")
    }

    @Test func aBudgetSubcarriersAloneExceedIsReportedNotSquashed() {
        // An impossible configuration: pilot alone above the ceiling. The
        // controller must flag it rather than quietly attenuating the
        // subcarriers, which would break stereo and RDS decoding.
        var meter = BS412MultiplexPowerMeter()
        var controller = BS412GainController()
        meter.configure(sampleRate: sampleRate)
        controller.configure(sampleRate: sampleRate)
        let pilotAmp = amplitude(deviationKHz: 30.0)   // far over the ceiling
        let pilotW = 2.0 * Float.pi * 19_000.0 / sampleRate
        for i in 0..<Int(5.0 * sampleRate) {
            let pilot = pilotAmp * sinf(pilotW * Float(i))
            if meter.process(total: pilot, subcarriers: pilot) {
                _ = controller.update(meter: meter, ceilingDBr: 0.0)
            }
        }
        #expect(controller.unachievable,
                "pilot alone is over the ceiling and the controller did not say so")
    }

    @Test func aLowerCeilingIsAMarginBelowTheStandard() {
        var meter = BS412MultiplexPowerMeter()
        var controller = BS412GainController()
        meter.configure(sampleRate: sampleRate)
        controller.configure(sampleRate: sampleRate)
        let amp = amplitude(deviationKHz: 19.0)   // exactly 0 dBr
        let omega = 2.0 * Float.pi * 1_000.0 / sampleRate
        var gain: Float = 1.0
        // Longer than the tests above: the correction is smaller, so the
        // slow loop takes proportionally longer to walk the last fraction
        // of a dB onto the ceiling.
        for i in 0..<Int(600.0 * sampleRate) {
            let audio = amp * sinf(omega * Float(i)) * gain
            if meter.process(total: audio, subcarriers: 0.0) {
                gain = controller.update(meter: meter, ceilingDBr: -3.0)
            }
        }
        #expect(abs(meter.powerDBr - (-3.0)) < 0.15,
                "a -3 dBr ceiling settled at \(meter.powerDBr) dBr")
    }
}
