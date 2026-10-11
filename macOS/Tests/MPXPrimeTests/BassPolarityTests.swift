import Testing
import Foundation
@testable import MPXPrime
import MPXPrimeCore

// Clipper campaign item 2: the bass-protection stages (mono bass, the 4x
// bass clipper, the FM side-channel guard) must never invert or drop the
// bass. Stereo Tool once shipped exactly that inversion. These tests render
// the verifier's bass scenario (50 + 80 Hz L/R pair at -12 dBFS, 2 kHz
// left-only reference at -20 dBFS, dipped for 100 ms at 0.8 s as the latency
// marker) through the real generator as configured and with the bass clipper
// off, decode both with the coherent receiver model and score `BassPol` (the
// decoded mono 40-120 Hz band of the configured chain correlated with the
// clipper-off chain's), `InPol` (the configured chain against the input at
// the chain's measured latency, a loose check for a flip upstream) and
// `BassLoss` (bass-band gain relative to the 2 kHz reference, configured
// minus clipper-off: what the protection stage costs).

@Suite("Bass polarity through the bass-protection stages")
struct BassPolarityTests {

    private let durationSeconds = 3.0

    private func expectUprightBass(_ metrics: BassPolarityMetrics, label: String) {
        #expect(metrics.polarity >= BassPolarityMetrics.minPolarity,
            "\(label): the bass clipper must leave the decoded mono bass upright against the clipper-off chain; BassPol \(metrics.polarity)")
        #expect(metrics.inputPolarity >= BassPolarityMetrics.minInputPolarity,
            "\(label): decoded mono bass against the input at the chain's \(metrics.latencyMS) ms latency must not read as a flip; InPol \(metrics.inputPolarity)")
        #expect(metrics.lossDB >= BassPolarityMetrics.minLossDB,
            "\(label): bass protection must not cost more than 1.5 dB of bass; BassLoss \(metrics.lossDB) dB (raw tilt \(metrics.tiltDB) dB, reference gain \(metrics.referenceGainDB) dB)")
    }

    @Test func shippedDefaultsKeepBassUprightAndIntact() {
        let metrics = bassPolarityMetrics(config: AppConfig(), durationSeconds: durationSeconds)
        expectUprightBass(metrics, label: "shipped defaults")
    }

    @Test func musicLoudKeepsBassUprightAndIntact() {
        var config = AppConfig()
        #expect(PresetCatalog.applyFormatProfile(id: "music_loud", to: &config) != nil)
        let metrics = bassPolarityMetrics(config: config, durationSeconds: durationSeconds)
        expectUprightBass(metrics, label: "Music - Loud")
    }

    /// With mono bass OFF the side channel keeps its bass, so the metric sees
    /// the stereo-image guard and the bass clipper on a genuinely stereo pair.
    /// An in-phase pair still reads about +1: the metric is not fooled by
    /// mono summing into a false pass.
    @Test func monoBassOffReadsUprightOnAnInPhasePair() {
        var config = AppConfig()
        config.monoBassEnabled = false
        let metrics = bassPolarityMetrics(config: config, durationSeconds: durationSeconds)
        expectUprightBass(metrics, label: "mono bass off")
        #expect(metrics.polarity >= 0.95,
            "an in-phase pair with mono bass off must read about +1, got \(metrics.polarity)")
    }

    /// Negative control: an inverted composite (pilot and audio) decodes to
    /// inverted mono. Both readings must call it an inversion rather than
    /// re-aligning at one of the tone pair's half-period aliases.
    @Test func invertedCompositeReadsAsInversion() {
        let config = AppConfig()
        var unprotectedConfig = config
        unprotectedConfig.bassClipperEnabled = false
        let render = renderBassPolarityScenario(config: config, durationSeconds: durationSeconds)
        let inverted = BassPolarityRender(
            inputLeft: render.inputLeft,
            inputRight: render.inputRight,
            mpx: render.mpx.map { -$0 }
        )
        let measured = bassPolarityMeasurement(config: config, render: inverted)
        let unprotected = bassPolarityMeasurement(
            config: unprotectedConfig,
            render: renderBassPolarityScenario(config: unprotectedConfig, durationSeconds: durationSeconds)
        )
        let metrics = BassPolarityMetrics(measured: measured, unprotected: unprotected)
        #expect(metrics.polarity <= -BassPolarityMetrics.minPolarity,
            "an inverted chain must read about -1 against the clipper-off chain, got \(metrics.polarity)")
        #expect(metrics.inputPolarity < BassPolarityMetrics.minInputPolarity,
            "an inverted chain must fail the input-referenced check, got InPol \(metrics.inputPolarity) at \(metrics.latencyMS) ms")
        let upright = bassPolarityMeasurement(config: config, render: render)
        #expect(abs(upright.latencyMS - measured.latencyMS) < 1.5,
            "the inversion must be read at the same latency as the upright chain: \(upright.latencyMS) vs \(measured.latencyMS) ms")
    }
}
