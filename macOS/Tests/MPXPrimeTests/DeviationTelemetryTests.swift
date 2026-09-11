import Foundation
import Testing

@testable import MPXPrime

/// The deviation readout is a MODULATION-domain figure: the engines meter the
/// composite post-`output_gain_db`, then divide the trim back out
/// (`modulationReferenceScale`), so the displayed kHz no longer under-reads by
/// exactly the operator's exciter trim (docs/project-roadmap.md item -1, field-measured
/// 30.2 kHz displayed vs ~75 on air at -7.89 dB). The engines' wiring is a
/// three-line multiply; the invariant itself is pinned here at the generator
/// level, headlessly: composite peak scales linearly with output gain, and
/// peak x 10^(-gain/20) -- the meter formula -- is gain-invariant.
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
        // ...so the meter's modulation-domain reading (peak divided back by
        // the trim) is gain-invariant: what the deviation readout now shows.
        let restored = trimmed * powf(10.0, 6.0 / 20.0)
        #expect(abs(restored - reference) / reference < 0.02,
            "modulation-domain reading moved with output_gain_db: \(restored) vs \(reference)")
    }
}
