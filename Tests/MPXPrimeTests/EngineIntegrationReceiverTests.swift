import Foundation
import Testing
@testable import MPXPrime

// The receiver gate's guard-band cancellation depth (fix round G1, item 5).
// The composite clipper's look-ahead gain stage (2 ms by default) took the
// metric's whole overdrive as gain reduction, so nothing was clipped, there
// was no residual to protect and the depth read 0.0 dB on both guards while
// the guard FIR worked: with the look-ahead off the same render measures
// about 30 dB. The metric now switches the look-ahead off so it measures the
// guard, not the absence of clipping.
@Suite("Engine integration (receiver guard metric)")
struct EngineIntegrationReceiverTests {

    @Test func guardDepthMeasuresTheGuardWithTheShippedLookahead() {
        var cfg = AppConfig()
        cfg.sampleRate = 192_000.0
        #expect(cfg.compositeClipperLookaheadMS > 0.0, "the shipped default should exercise the look-ahead case")
        let m = guardBandCancellationMetrics(baseConfig: cfg, durationSeconds: 0.5)
        print(String(format: "guard depth: pilot %.1f dB (on %.1f / off %.1f), RDS %.1f dB (on %.1f / off %.1f)",
                     m.pilotGuardDepthDB, m.pilotGuardResidualOnDBFS, m.pilotGuardResidualOffDBFS,
                     m.rdsGuardDepthDB, m.rdsGuardResidualOnDBFS, m.rdsGuardResidualOffDBFS))
        #expect(m.pilotGuardDepthDB > 20.0, "pilot guard depth \(m.pilotGuardDepthDB) dB")
        #expect(m.rdsGuardDepthDB > 20.0, "RDS guard depth \(m.rdsGuardDepthDB) dB")
    }
}
