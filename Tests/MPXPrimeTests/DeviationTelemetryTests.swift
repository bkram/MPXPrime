import Foundation
import Testing

@testable import MPXPrime

/// The deviation readout is a MODULATION-domain figure: the engines meter the
/// composite post-`output_gain_db`, then divide the trim back out
/// (`modulationReferenceScale`), so the displayed kHz no longer under-reads by
/// exactly the operator's exciter trim (docs/project-roadmap.md item -1, field-measured
/// 30.2 kHz displayed vs ~75 on air at -7.89 dB). Both engines take that
/// scale from `OutputWiring.modulationReferenceScale`, and this test runs
/// THAT function on the real generator's composite (review finding 10: it
/// used to compute 10^(+6/20) itself, so a sign flip in the engines stayed
/// green): composite peak scales linearly with output gain, and the
/// readout the engines compute from it is gain-invariant.
@Suite("Deviation telemetry domain")
struct DeviationTelemetryTests {

    private func compositePeak(outputGainDB: Double) -> Float {
        var cfg = AppConfig()
        cfg.sampleRate = 192_000.0
        cfg.sourceMode = "input"
        cfg.outputGainDB = outputGainDB
        let generator = MPXGenerator(config: cfg, sampleRate: cfg.sampleRate)
        var peak: Float = 0.0
        let frames = Int(cfg.sampleRate * 0.5)
        for i in 0..<frames {
            let t = Float(i) / Float(cfg.sampleRate)
            let l = 0.5 * sinf(2.0 * Float.pi * 1_000.0 * t)
            let r = 0.4 * sinf(2.0 * Float.pi * 3_000.0 * t)
            let mpx = generator.renderSingleSample(leftIn: l, rightIn: r)
            // Skip the chain settle before taking peaks.
            if i > frames / 2 { peak = max(peak, fabsf(mpx)) }
        }
        return peak
    }

    @Test func meterFormulaIsInvariantUnderOutputGain() {
        let reference = compositePeak(outputGainDB: 0.0)
        let trimmed = compositePeak(outputGainDB: -6.0)
        #expect(reference > 0.1)
        // The composite itself scales with the trim...
        let measuredRatio = trimmed / reference
        let expectedRatio = powf(10.0, -6.0 / 20.0)
        #expect(abs(measuredRatio - expectedRatio) < 0.02,
            "composite peak ratio \(measuredRatio) vs 10^(-6/20) = \(expectedRatio)")
        // ...so the engines' modulation-domain reading (the production scale
        // applied to the metered peak) is gain-invariant.
        func readout(peak: Float, gainDB: Float) -> Float {
            DeviationReadout.kilohertz(
                compositePeak: peak,
                modulationReferenceScale: OutputWiring.modulationReferenceScale(
                    outputGainDB: gainDB, mode: .mpxComposite))
        }
        let atUnity = readout(peak: reference, gainDB: 0.0)
        let atTrim = readout(peak: trimmed, gainDB: -6.0)
        #expect(abs(atTrim - atUnity) / atUnity < 0.02,
            "deviation readout moved with output_gain_db: \(atTrim) kHz at -6 dB vs \(atUnity) kHz at 0 dB")
    }
}
