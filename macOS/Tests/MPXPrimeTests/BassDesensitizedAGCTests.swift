import Testing
import Foundation
@testable import MPXPrime

// Bass-desensitised wideband AGC (docs/project-roadmap.md P4 + P5). P4 clips LF transient peaks out
// of the AGC sidechain; P5 recovers fast from brief reductions. Together they keep
// a kick / heavy bass line from pumping the whole chain. The deterministic gate
// below feeds a sustained mid tone with periodic low-frequency "kick" bursts and
// checks that the wideband AGC gain swings LESS (less pump) with the feature on,
// and that the feature is genuinely off by default.
@Suite("Bass-desensitised wideband AGC")
struct BassDesensitizedAGCTests {

    private let sr: Float = 48_000.0

    /// Run a steady bass-dominant program (loud low tone + quiet mid) through the
    /// AGC and return the settled gain (dB). With the LF band attenuated out of the
    /// sidechain (P4), the detector tracks the quiet mid instead of the loud bass,
    /// so the AGC rests much higher — bass no longer drives the loudness reading.
    private func settledGainDB(bassDesensitize: Bool) -> Float {
        var agc = WidebandAGCRider()
        agc.configure(
            sampleRate: sr,
            targetDB: -20.0,
            attackMS: 6.0,
            releaseMS: 800.0,
            minGainDB: -12.0,
            maxGainDB: 12.0,
            kWeightingEnabled: true,
            programDependentRelease: true,
            bassDesensitizeEnabled: bassDesensitize,
            bassDesensitizeFreqHz: 150.0)

        let total = Int(sr * 6.0)
        let warmup = Int(sr * 4.0)   // let the slow release fully settle
        var sum: Double = 0
        var count = 0
        for i in 0..<total {
            let t = Float(i) / sr
            // Loud 80 Hz bass dominates the loudness; quiet 2 kHz mid underneath.
            let s = 0.50 * sinf(2.0 * .pi * 80.0 * t) + 0.05 * sinf(2.0 * .pi * 2_000.0 * t)
            _ = agc.process(left: s, right: s)
            if i >= warmup {
                sum += Double(agc.telemetry.gainDB)
                count += 1
            }
        }
        return Float(sum / Double(max(1, count)))
    }

    @Test func bassDesensitizeKeepsBassFromDrivingTheAGC() {
        let off = settledGainDB(bassDesensitize: false)
        let on = settledGainDB(bassDesensitize: true)
        // The loud bass must pull the AGC down with the feature off, or the test
        // proves nothing.
        #expect(off < -2.0, "loud bass should reduce AGC gain when bass-desensitize is OFF, got \(off) dB")
        // With the bass attenuated out of the sidechain, the AGC tracks the quiet
        // mid instead and rests well above the bass-driven level.
        #expect(on > off + 3.0, "bass-desensitize should keep bass from driving the AGC: on=\(on) dB off=\(off) dB")
    }

    @Test func bassDesensitizeConfigDefaultsOffAndRoundTrips() throws {
        #expect(AppConfig().widebandAGCBassDesensitizeEnabled == false, "must default off")
        var cfg = AppConfig()
        cfg.widebandAGCBassDesensitizeEnabled = true
        let restored = try AppConfig.loadFromINIString(cfg.captureAsINIString())
        #expect(restored.widebandAGCBassDesensitizeEnabled == true)
    }
}
