import Foundation
import Testing

@testable import MPXPrime

// The kHz scale of the deviation readout is FIXED: composite amplitude 1.0 is
// 75 kHz at every `mpx_deviation_khz`, because the generator scales the whole
// composite (subcarriers included) by `mpx_deviation_khz / 75`. Until 0.60
// both engines multiplied the metered peak by the configured deviation
// instead -- exact at the default, 33 kHz for full modulation at a 50 kHz
// setting. Pinned here through the real generator: a pilot-only composite at
// two settings must read 9 % of the chosen deviation, which is what the
// Test Tone card and `scripts/smoke-live.sh` already predict.
@Suite("Deviation readout scale")
struct DeviationReadoutTests {

    private func pilotOnlyCompositePeak(deviationKHz: Double) -> Float {
        var cfg = AppConfig()
        cfg.sampleRate = 192_000.0
        cfg.sourceMode = "input"
        cfg.enRDS = false
        cfg.pilotLevel = 0.09
        cfg.outputGainDB = 0.0
        cfg.mpxDeviationKHz = deviationKHz
        let generator = MPXGenerator(config: cfg, sampleRate: cfg.sampleRate)
        var peak: Float = 0.0
        let frames = Int(cfg.sampleRate * 0.5)
        for i in 0..<frames {
            let mpx = generator.renderSingleSample(leftIn: 0.0, rightIn: 0.0)
            if i > frames / 2 { peak = max(peak, fabsf(mpx)) }
        }
        return peak
    }

    @Test(arguments: [50.0, 75.0])
    func pilotReadsNinePercentOfTheChosenDeviation(deviationKHz: Double) {
        let peak = pilotOnlyCompositePeak(deviationKHz: deviationKHz)
        let kHz = DeviationReadout.kilohertz(compositePeak: peak, modulationReferenceScale: 1.0)
        let expected = Float(0.09 * deviationKHz)
        #expect(abs(kHz - expected) < 0.05, "pilot read \(kHz) kHz at a \(deviationKHz) kHz setting, expected \(expected)")
    }

    @Test func thePreZeroSixtyFormulaUnderReadsAwayFromTheDefault() {
        // The regression: peak x configured deviation. At 50 kHz the pilot
        // (4.5 kHz on air) read 3.0 kHz -- the same 2/3 that hid a
        // 50 kHz station's full modulation as 33 kHz.
        let peak = pilotOnlyCompositePeak(deviationKHz: 50.0)
        let old = peak * 50.0
        #expect(abs(old - 3.0) < 0.05)
        #expect(abs(DeviationReadout.kilohertz(compositePeak: peak, modulationReferenceScale: 1.0) - 4.5) < 0.05)
    }

    @Test func outputTrimIsDividedBackOut() {
        // A composite metered post -6 dB trim reads the modulation-domain
        // figure once the engine's reference scale (10^(+6/20)) is applied.
        let trimmedPeak: Float = 0.5 * powf(10.0, -6.0 / 20.0)
        let kHz = DeviationReadout.kilohertz(
            compositePeak: trimmedPeak, modulationReferenceScale: powf(10.0, 6.0 / 20.0))
        #expect(abs(kHz - 37.5) < 0.01)
    }
}
