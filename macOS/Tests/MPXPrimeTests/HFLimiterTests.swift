import Foundation
import Testing

@testable import MPXPrime

// Pre-emphasis-aware HF limiter (program-controlled pre-emphasis, Orban
// US 4,103,243 topology): rides only the boost component `pre - flat`.
@Suite struct HFLimiterTests {

    private let sampleRate: Float = 48_000.0

    private func makeLimiter(enabled: Bool = true, thresholdDB: Float = -2.0,
                             maxReductionDB: Float = 12.0) -> HFLimiter {
        var limiter = HFLimiter()
        limiter.configure(
            enabled: enabled, sampleRate: sampleRate, thresholdDB: thresholdDB,
            attackMS: 1.5, releaseMS: 20.0, maxReductionDB: maxReductionDB)
        return limiter
    }

    @Test func disabledIsExactPassthrough() {
        var limiter = makeLimiter(enabled: false)
        for n in 0..<2_000 {
            let flat = 0.5 * sinf(2.0 * Float.pi * 10_000.0 * Float(n) / sampleRate)
            let pre = flat * 1.9
            let out = limiter.process(flatL: flat, flatR: flat, emphasizedL: pre, emphasizedR: pre)
            #expect(out.0 == pre)
            #expect(out.1 == pre)
        }
        #expect(limiter.gainReductionDB == 0.0)
    }

    @Test func hfOvershootIsPulledToTheThreshold() {
        // 10 kHz "hat": flat 0.30, boost 0.60 -> pre-emphasised peak 0.90,
        // threshold -2 dB (0.794). Steady state must sit at the threshold
        // (+ a small smoothing margin), never below the flat level.
        var limiter = makeLimiter()
        var peak: Float = 0.0
        for n in 0..<9_600 {
            let s = sinf(2.0 * Float.pi * 10_000.0 * Float(n) / sampleRate)
            let flat = 0.30 * s
            let pre = 0.90 * s
            let out = limiter.process(flatL: flat, flatR: flat, emphasizedL: pre, emphasizedR: pre)
            if n >= 4_800 { peak = max(peak, fabsf(out.0)) }
        }
        #expect(peak <= 0.794 * 1.03, "steady-state peak \(peak) should sit at the threshold")
        #expect(peak >= 0.30, "the stage must never cut HF below the flat level")
        #expect(limiter.gainReductionDB > 0.5)
    }

    @Test func bassDrivenPeakLeavesHFAlone() {
        // A bass peak over threshold with a negligible boost component must
        // not flutter the HF: the boost is not the cause of the excess, so
        // the gain stays at unity (Dolby modulation-control idea).
        var limiter = makeLimiter()
        var maxDeviation: Float = 0.0
        for n in 0..<4_800 {
            let bass = 0.95 * sinf(2.0 * Float.pi * 80.0 * Float(n) / sampleRate)
            let hf = 0.01 * sinf(2.0 * Float.pi * 10_000.0 * Float(n) / sampleRate)
            let flat = bass + hf
            let pre = bass + (2.0 * hf)
            let out = limiter.process(flatL: flat, flatR: flat, emphasizedL: pre, emphasizedR: pre)
            maxDeviation = max(maxDeviation, fabsf(out.0 - pre))
        }
        #expect(maxDeviation < 1e-6)
        #expect(limiter.gain == 1.0)
    }

    @Test func releaseRestoresFullPreemphasis() {
        var limiter = makeLimiter()
        for n in 0..<4_800 {
            let s = sinf(2.0 * Float.pi * 10_000.0 * Float(n) / sampleRate)
            _ = limiter.process(flatL: 0.30 * s, flatR: 0.30 * s, emphasizedL: 0.90 * s, emphasizedR: 0.90 * s)
        }
        #expect(limiter.gain < 0.95)
        // Quiet program: 200 ms is 10 release time constants.
        for n in 0..<9_600 {
            let s = 0.05 * sinf(2.0 * Float.pi * 10_000.0 * Float(n) / sampleRate)
            _ = limiter.process(flatL: s, flatR: s, emphasizedL: 1.9 * s, emphasizedR: 1.9 * s)
        }
        #expect(limiter.gain > 0.999)
    }

    @Test func maxReductionCapsTheGainRide() {
        // Boost far above a -6 dB threshold with a 3 dB cap: removing the
        // excess would need ~-6.5 dB of boost gain, so the ride floors at
        // 10^(-3/20) and the rest is left for the broadband limiter.
        var limiter = makeLimiter(thresholdDB: -6.0, maxReductionDB: 3.0)
        for n in 0..<9_600 {
            let s = sinf(2.0 * Float.pi * 10_000.0 * Float(n) / sampleRate)
            _ = limiter.process(flatL: 0.05 * s, flatR: 0.05 * s, emphasizedL: 0.99 * s, emphasizedR: 0.99 * s)
        }
        let floor = powf(10.0, -3.0 / 20.0)
        #expect(abs(limiter.gain - floor) < 0.01)
    }

    @Test func stereoLinkKeepsChannelRatio() {
        // One shared gain: a hard-left hat reduces both channels' boost by
        // the same factor, so the L/R ratio of the boost is preserved.
        var limiter = makeLimiter()
        var ratioError: Float = 0.0
        for n in 0..<9_600 {
            let s = sinf(2.0 * Float.pi * 10_000.0 * Float(n) / sampleRate)
            let out = limiter.process(
                flatL: 0.30 * s, flatR: 0.06 * s, emphasizedL: 0.90 * s, emphasizedR: 0.18 * s)
            if n >= 4_800, fabsf(s) > 0.5 {
                // out = flat + g*boost; boostR/boostL = 0.2 exactly.
                let gL = (out.0 - (0.30 * s)) / (0.60 * s)
                let gR = (out.1 - (0.06 * s)) / (0.12 * s)
                ratioError = max(ratioError, fabsf(gL - gR))
            }
        }
        #expect(ratioError < 1e-4)
    }

    @Test func runtimeConfigCarriesEveryField() {
        var config = AppConfig()
        config.hfLimiterEnabled = true
        config.hfLimiterThresholdDB = -4.5
        config.hfLimiterAttackMS = 2.5
        config.hfLimiterReleaseMS = 35.0
        config.hfLimiterMaxReductionDB = 9.0
        let runtime = MPXGenerator.makeRuntimeConfig(from: config)
        #expect(runtime.hfLimiterEnabled)
        #expect(abs(runtime.hfLimiterThresholdDB - (-4.5)) < 1e-6)
        #expect(abs(runtime.hfLimiterAttackMS - 2.5) < 1e-6)
        #expect(abs(runtime.hfLimiterReleaseMS - 35.0) < 1e-6)
        #expect(abs(runtime.hfLimiterMaxReductionDB - 9.0) < 1e-6)
    }

    @Test func iniRoundTripKeepsHFLimiterKeys() throws {
        var config = AppConfig()
        config.hfLimiterEnabled = true
        config.hfLimiterThresholdDB = -3.0
        config.hfLimiterAttackMS = 1.0
        config.hfLimiterReleaseMS = 40.0
        config.hfLimiterMaxReductionDB = 8.0
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-limiter-\(UUID().uuidString).ini")
        try config.save(toINI: url.path)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try AppConfig.load(fromINI: url.path)
        #expect(loaded.hfLimiterEnabled)
        #expect(abs(loaded.hfLimiterThresholdDB - (-3.0)) < 1e-6)
        #expect(abs(loaded.hfLimiterAttackMS - 1.0) < 1e-6)
        #expect(abs(loaded.hfLimiterReleaseMS - 40.0) < 1e-6)
        #expect(abs(loaded.hfLimiterMaxReductionDB - 8.0) < 1e-6)
    }

    @Test func legacyFormatProfileIDsMigrateToThe045Profiles() {
        #expect(AppConfig.migratedFormatProfileID("chr_top40") == "music_loud")
        #expect(AppConfig.migratedFormatProfileID("edm_dance") == "music_loud")
        #expect(AppConfig.migratedFormatProfileID("community_radio") == "music_clean")
        #expect(AppConfig.migratedFormatProfileID("news_talk") == "speech")
        #expect(AppConfig.migratedFormatProfileID("jazz_classical") == "classical_wide")
        #expect(AppConfig.migratedFormatProfileID("music_clean") == "music_clean")
        #expect(AppConfig.migratedFormatProfileID("custom") == "custom")
    }

    @Test func safetyClipWarningFiresOnlyWithoutAPeakController() {
        var config = AppConfig()
        #expect(!config.safetyClipsAreThePeakController)
        config.preEncodeAudioLimiterEnabled = false
        #expect(!config.safetyClipsAreThePeakController)
        config.compositeClipperEnabled = false
        #expect(config.safetyClipsAreThePeakController)
        config.processingBypass = true
        #expect(!config.safetyClipsAreThePeakController)
    }
}
