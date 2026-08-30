#if canImport(Accelerate)
import Accelerate
#else
import MPXPrimeAcceleration
#endif
import Foundation
import MPXPrimeCore

// MARK: - Final-MPX limiter ride isolation (--verify-final-ride)
//
// Chain review 2026-08-30, item A1. The Final-MPX look-ahead limiter rides
// ~1.2 dB on a hot chain even with full composite clipping (the stereo-guard
// sweep refuted the guard as the cause). This table switches one candidate off
// per row -- pilot guard, RDS guard, stereo guard, oversampling factor, knee
// width, the final limiter itself, the safety shaper -- on two configs and two
// dense scenarios, and prints every peak controller's duty so the ride can be
// attributed before anything is redesigned (A2 POCS passes are the expected
// answer if the band-limiting overshoot of LP(clipped) dominates).

private struct RideRow {
    let label: String
    let mutate: (inout AppConfig) -> Void
}

private func rideRows() -> [RideRow] {
    [
        RideRow(label: "baseline") { _ in },
        RideRow(label: "pilot guard OFF") { $0.compositeClipperCancelPilot = false },
        RideRow(label: "RDS guard OFF") { $0.compositeClipperCancelRDS = false },
        RideRow(label: "stereo guard 0") { $0.compositeClipperStereoGuard = 0.0 },
        RideRow(label: "all guards OFF") { c in
            c.compositeClipperCancelPilot = false
            c.compositeClipperCancelRDS = false
            c.compositeClipperStereoGuard = 0.0
        },
        RideRow(label: "8x oversampling") { $0.compositeClipperOversampling = 8 },
        RideRow(label: "32x oversampling") { $0.compositeClipperOversampling = 32 },
        RideRow(label: "narrow knee (thr = ceiling - 0.2 dB)") { c in
            c.compositeClipperThresholdDB = c.compositeClipperCeilingDB - 0.2
        },
        RideRow(label: "clipper look-ahead 2 ms") { $0.compositeClipperLookaheadMS = 2.0 },
        RideRow(label: "final limiter OFF (composite vs budget)") { $0.limitMPX = false },
        RideRow(label: "safety shaper OFF") { $0.audioCompositeSoftClipEnabled = false }
    ]
}

private func printRideTable(label: String, config: AppConfig, durationSeconds: Double) {
    let scenarios = verificationScenarios().filter { ["bright_dense", "transient_push"].contains($0.name) }
    print("\(label): drive \(String(format: "%.1f", config.finalDriveDB)) dB, clipper \(String(format: "%.1f", config.compositeClipperThresholdDB)) / \(String(format: "%.1f", config.compositeClipperCeilingDB)) dB, \(config.compositeClipperOversampling)x, multiband \(config.multibandEnabled ? "on" : "off"), AGC \(config.widebandAGCEnabled ? "on" : "off")")
    print("Row                                       Scenario         ClipGR  FinalGR  SafetyClip  AudioPk dBFS  TruePk dBFS  Peak dBFS")
    print("----------------------------------------  ---------------  ------  -------  ----------  ------------  -----------  ---------")
    for row in rideRows() {
        var cfg = config
        row.mutate(&cfg)
        for scenario in scenarios {
            let m = verifyScenario(config: cfg, durationSeconds: durationSeconds, scenario: scenario)
            print(
                "\(padded(row.label, width: 40))  "
                    + "\(padded(scenario.name, width: 15))  "
                    + "\(String(format: "%6.2f", m.maxLimiterGRDB))"
                    + "  \(String(format: "%7.2f", m.maxSafetyGRDB))"
                    + "  \(String(format: "%10.2f", m.maxSafetyClipDB))"
                    + "  \(String(format: "%12.2f", dbfsValue(m.maxAudioCompositePeak)))"
                    + "  \(String(format: "%11.2f", dbfsValue(m.truePeakAbs)))"
                    + "  \(String(format: "%9.2f", dbfsValue(m.peakAbs)))"
            )
        }
    }
    print("")
}

func runFinalRideIsolation(baseConfig: AppConfig, durationSeconds: Double) -> Int32 {
    let duration = max(3.0, min(durationSeconds, 6.0))
    var hot = baseConfig
    hot.finalDriveDB = 12.0
    hot.compositeClipperEnabled = true
    hot.limitMPX = true
    hot.limitLookaheadEnabled = true
    hot.widebandAGCEnabled = false
    hot.multibandEnabled = false
    hot.preEncodeAudioLimiterEnabled = false
    var loud = baseConfig
    _ = PresetCatalog.applyFormatProfile(id: "music_loud", to: &loud)

    print("Columns: ClipGR = composite clipper kernel GR, FinalGR = Final-MPX look-ahead limiter duty,")
    print("SafetyClip = how far the composite still exceeded the budget into the 1x safety shaper,")
    print("AudioPk = audio-composite peak before pilot/RDS injection, TruePk = 4x true peak of the MPX.")
    print("The 'all guards OFF' row is the pure band-limiting overshoot of LP(clipped); the")
    print("'final limiter OFF' row shows how far the un-ridden composite exceeds the budget.")
    print("")
    printRideTable(label: "Hot chain (12 dB drive, AGC / multiband / pre-encode limiter off)", config: hot, durationSeconds: duration)
    printRideTable(label: "Profile Music - Loud", config: loud, durationSeconds: duration)
    print("Assessment")
    print("Result: OK - isolation table printed; attribution feeds chain-review item A2.")
    return 0
}
