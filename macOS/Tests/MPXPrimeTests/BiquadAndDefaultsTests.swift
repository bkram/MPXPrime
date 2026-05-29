import Testing
import Foundation
@testable import MPXPrime
import MPXPrimeCore

// Three small but load-bearing test groups:
//
// 1. `Biquad.configureBandpass` — RBJ constant-0-dB-peak BP added in 0.10
//    for the composite clipper's pilot/RDS notch path. Verifies passband
//    gain, octave-rolloff stopband, and deep stopband at low frequency.
//
// 2. `AppConfig` defaults — pins the research-grounded amateur-grade
//    defaults shipped in 0.10 so a future refactor cannot silently flip
//    AGC / multiband / bass clipper / composite clipper back to off, or
//    drift the tuned numerics. The default config is the project's
//    most-impacted external surface for amateur operators; regressions
//    here change first-run UX for every new install.
//
// 3. Sample `MPXPrime.ini` round-trip — verifies the shipped sample INI
//    parses cleanly, declares the new defaults, and survives a load →
//    save → re-load cycle without losing the new keys.

@Suite("Biquad bandpass response")
struct BiquadBandpassTests {
    private let sampleRate: Float = 192_000.0
    private let fftSize: Int = 16_384
    private let warmupFrames: Int = 2_048

    private func bandpassResponse(centerHz: Float, q: Float, toneHz: Float)
        -> SpectralReport
    {
        var bp = Biquad()
        bp.configureBandpass(freqHz: centerHz, sampleRate: sampleRate, q: q)
        let totalFrames = warmupFrames + fftSize
        var out = [Float](repeating: 0, count: totalFrames)
        let omega = 2.0 * Double.pi * Double(toneHz) / Double(sampleRate)
        for i in 0..<totalFrames {
            let x = Float(0.5 * sin(omega * Double(i)))
            out[i] = bp.process(x)
        }
        let tail = Array(out[warmupFrames..<totalFrames])
        return FFTAnalyzer(fftSize: fftSize).analyze(tail, sampleRate: sampleRate)
    }

    @Test func passesContentAtCenterFrequency() {
        // Tone at 19 kHz, BP centered at 19 kHz Q=30. The RBJ constant-0-dB
        // peak BP has unity gain at fc, so a -6 dBFS tone (amplitude 0.5)
        // should appear at ~-6 dBFS at the output.
        let report = bandpassResponse(centerHz: 19_000.0, q: 30.0, toneHz: 19_000.0)
        let level = report.peakDBFS(in: 18_900.0...19_100.0)
        #expect(level > -7.0,
            "BP at center fc should be ~ -6 dBFS for a 0.5 amplitude tone; got \(level)")
        #expect(level < -5.0,
            "BP at center fc should not amplify; got \(level)")
    }

    @Test func attenuatesAtOctaveBelowCenter() {
        // Tone at 9.5 kHz (one octave below 19 kHz center). 2nd-order BP
        // should drop by at least 18 dB by an octave away with Q=30.
        let report = bandpassResponse(centerHz: 19_000.0, q: 30.0, toneHz: 9_500.0)
        let level = report.peakDBFS(in: 9_400.0...9_600.0)
        #expect(level < -24.0,
            "BP at one octave below should be ≥ -24 dBFS; got \(level)")
    }

    @Test func attenuatesAtOctaveAboveCenter() {
        // Tone at 38 kHz (one octave above 19 kHz center). Same expected
        // rolloff as the lower octave.
        let report = bandpassResponse(centerHz: 19_000.0, q: 30.0, toneHz: 38_000.0)
        let level = report.peakDBFS(in: 37_800.0...38_200.0)
        #expect(level < -24.0,
            "BP at one octave above should be ≥ -24 dBFS; got \(level)")
    }

    @Test func deeplyAttenuatesFarFromCenter() {
        // Tone at 1 kHz against BP at 19 kHz Q=30. Far-field stopband
        // should be very deep — verify it kills the audio band entirely
        // (the use-case for the pilot/RDS notch path).
        let report = bandpassResponse(centerHz: 19_000.0, q: 30.0, toneHz: 1_000.0)
        let level = report.peakDBFS(in: 950.0...1_050.0)
        #expect(level < -45.0,
            "BP at fc/19 should be ≥ -45 dBFS; got \(level)")
    }
}

@Suite("AppConfig defaults")
struct AppConfigDefaultsTests {

    @Test func processingChainShipsEnabledByDefault() {
        // Regression guard: every commercial processor ships its
        // processing chain on. A fresh AppConfig should match.
        let cfg = AppConfig()
        #expect(cfg.processingBypass == false,
            "processing_bypass must be false — chain ships on")
        #expect(cfg.widebandAGCEnabled == true,
            "AGC must be on by default")
        #expect(cfg.multibandEnabled == true,
            "Multiband must be on by default")
        #expect(cfg.bassClipperEnabled == true,
            "Bass clipper must be on by default — claws back 2-3 dB modulation")
        #expect(cfg.compositeClipperEnabled == true,
            "Composite clipper must be on by default with cancellation enabled")
        #expect(cfg.preEncodeAudioLimiterEnabled == true,
            "Pre-encode audio limiter must be on")
        #expect(cfg.encoderFIREnabled == true,
            "Encoder FIR brick-wall must be on for TX path")
    }

    @Test func coloringStagesDefaultOff() {
        // Stereo widener and PrimeBass color the signal and degrade
        // fringe-listener SNR on low-power TX. DC clipper is too
        // aggressive for default. BS.412 only EU stations need it.
        let cfg = AppConfig()
        #expect(cfg.primeBassEnabled == false,
            "PrimeBass must be off by default — coloring stage")
        #expect(cfg.stereoWidenEnabled == false,
            "Stereo widener must be off by default — degrades fringe SNR")
        #expect(cfg.dcClipperEnabled == false,
            "DC clipper must be off by default — too aggressive")
        #expect(cfg.bs412Enabled == false,
            "BS.412 must be off by default — EU operators opt in")
    }

    @Test func compositeClipperDefaultsEngageOnRealProgram() {
        // 0.10 tightened the clipper from -3.0 / -0.5 (never engaged) to
        // -1.0 / -0.3 (~1.5 dB perceived loudness lift). The clipper now
        // uses additive distortion cancellation (Orban US 4,460,871 /
        // 5,737,434), so audio-band clipping stays engaged for peak
        // control while subcarrier-region distortion is removed.
        let cfg = AppConfig()
        #expect(abs(cfg.compositeClipperThresholdDB - (-1.0)) < 0.01,
            "Threshold must be -1.0 dB; got \(cfg.compositeClipperThresholdDB)")
        #expect(abs(cfg.compositeClipperCeilingDB - (-0.3)) < 0.01,
            "Ceiling must be -0.3 dB; got \(cfg.compositeClipperCeilingDB)")
        #expect(cfg.compositeClipperCancelAudio == false,
            "Audio cancellation must be OFF by default — audio band is where peak reduction comes from")
        #expect(cfg.compositeClipperCancelStereo == true,
            "Stereo cancellation must be on — preserves (L-R) subcarrier integrity")
        #expect(cfg.compositeClipperCancelPilot == true,
            "Pilot guard cancellation must be on — keeps 19 kHz region clean for post-stage pilot injection")
        #expect(cfg.compositeClipperCancelRDS == true,
            "RDS guard cancellation must be on — keeps 57 kHz region clean for post-stage RDS injection")
    }

    @Test func agcDefaultsMatchPopMediumTuning() {
        // Pop Medium per Orban 8500/8700i: -14 LUFS target, 20 dB range,
        // 6 ms attack, 1.5 s release.
        let cfg = AppConfig()
        #expect(abs(cfg.widebandAGCTargetDB - (-14.0)) < 0.01,
            "AGC target must be -14 dB; got \(cfg.widebandAGCTargetDB)")
        #expect(abs(cfg.widebandAGCAttackMS - 6.0) < 0.01,
            "AGC attack must be 6 ms; got \(cfg.widebandAGCAttackMS)")
        #expect(abs(cfg.widebandAGCReleaseMS - 1500.0) < 0.01,
            "AGC release must be 1500 ms; got \(cfg.widebandAGCReleaseMS)")
        #expect(abs(cfg.widebandAGCMaxGainDB - 10.0) < 0.01,
            "AGC max gain must be 10 dB; got \(cfg.widebandAGCMaxGainDB)")
        #expect(abs(cfg.widebandAGCMinGainDB - (-10.0)) < 0.01,
            "AGC min gain must be -10 dB; got \(cfg.widebandAGCMinGainDB)")
        #expect(cfg.widebandAGCKWeightingEnabled == true,
            "K-weighting must be on")
        #expect(cfg.widebandAGCReleaseProgramDependent == true,
            "Program-dependent release must be on")
    }

    @Test func multibandDefaultsNormalAtFiveBandAC() {
        // 5-band AC/Pop preset at "Normal" intensity (was "Light" pre-0.11).
        // Light intensity scales ratios x0.9 and pushes thresholds +1.5 dB,
        // which made the multiband chain so transparent operators reported
        // it sounded like nothing was happening. Normal is the published
        // 5_ac recipe at face value — audible but not aggressive.
        let cfg = AppConfig()
        #expect(cfg.multibandMode == 5,
            "Multiband mode must be 5; got \(cfg.multibandMode)")
        #expect(cfg.multibandPresetID == "5_ac",
            "Multiband preset must be 5_ac; got \(cfg.multibandPresetID)")
        #expect(cfg.multibandIntensity == "normal",
            "Multiband intensity must be normal; got \(cfg.multibandIntensity)")
        // Spot-check the new at-Normal values so the AppConfig defaults
        // can't quietly drift back to the old Light-multiplied numbers.
        #expect(abs(cfg.multibandLowThresholdDB - (-17.5)) < 0.01,
            "Low threshold must be -17.5 dB at Normal; got \(cfg.multibandLowThresholdDB)")
        #expect(abs(cfg.multibandLowRatio - 1.75) < 0.01,
            "Low ratio must be 1.75 at Normal; got \(cfg.multibandLowRatio)")
    }

    @Test func preEmphasisDefaultsTo50Microseconds() {
        // 50 us = world default (EU + most of the world). 75 us = US/CA/KR.
        // Default favors the safer wrong choice — 50 into a 75 deemph
        // sounds slightly dull but legal; 75 into 50 sounds shrill and
        // overmodulates HF.
        let cfg = AppConfig()
        #expect(cfg.preemphasisUS == 50,
            "Pre-emphasis must default to 50 us; got \(cfg.preemphasisUS)")
    }
}

@Suite("Sample MPXPrime.ini round-trip")
struct SampleINIRoundTripTests {

    /// Locate the sample INI by walking up from the test bundle until we
    /// find the `macOS/MPXPrime.ini` next to the package manifest. SPM
    /// test bundles run from a derived data location; the source tree
    /// is reachable via Bundle resourcePath ancestry.
    private func sampleINIPath() -> String? {
        // Walk the file's source path up to the package root.
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MPXPrimeTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // macOS/
        let candidate = here.appendingPathComponent("MPXPrime.ini").path
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    @Test func sampleINIParsesWithoutErrors() throws {
        guard let path = sampleINIPath() else {
            Issue.record("Sample MPXPrime.ini not found at expected location")
            return
        }
        // Should parse without throwing.
        _ = try AppConfig.load(fromINI: path)
    }

    @Test func sampleINIShipsWithProcessingOn() throws {
        guard let path = sampleINIPath() else {
            Issue.record("Sample MPXPrime.ini not found at expected location")
            return
        }
        let cfg = try AppConfig.load(fromINI: path)
        // The whole point of the 0.10 sample-INI rewrite: the shipped
        // sample must put a fresh operator into a processed-on chain.
        #expect(cfg.processingBypass == false,
            "Sample INI must set processing_bypass = False")
        #expect(cfg.widebandAGCEnabled == true,
            "Sample INI must enable AGC")
        #expect(cfg.multibandEnabled == true,
            "Sample INI must enable multiband")
        #expect(cfg.bassClipperEnabled == true,
            "Sample INI must enable bass clipper")
        #expect(cfg.compositeClipperEnabled == true,
            "Sample INI must enable composite clipper")
        #expect(cfg.compositeClipperCancelAudio == false,
            "Sample INI must keep audio-band clipping engaged (cancelAudio = False) so the clipper actually delivers loudness lift")
        #expect(cfg.compositeClipperCancelStereo == true,
            "Sample INI must enable stereo subcarrier cancellation to preserve (L-R) sideband integrity")
    }

    @Test func sampleINISurvivesRoundTrip() throws {
        guard let path = sampleINIPath() else {
            Issue.record("Sample MPXPrime.ini not found at expected location")
            return
        }
        let original = try AppConfig.load(fromINI: path)

        let tempDir = FileManager.default.temporaryDirectory
        let tempPath = tempDir.appendingPathComponent("MPXPrime-roundtrip-test.ini").path
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        try original.save(toINI: tempPath)
        let reloaded = try AppConfig.load(fromINI: tempPath)

        // Spot-check key fields survive the round-trip. Full equality
        // would be brittle (defaults injection, key normalization etc.);
        // the goal here is to catch keys lost by the serializer.
        #expect(reloaded.processingBypass == original.processingBypass)
        #expect(reloaded.widebandAGCEnabled == original.widebandAGCEnabled)
        #expect(reloaded.multibandEnabled == original.multibandEnabled)
        #expect(reloaded.bassClipperEnabled == original.bassClipperEnabled)
        #expect(reloaded.compositeClipperEnabled == original.compositeClipperEnabled)
        #expect(reloaded.compositeClipperCancelAudio == original.compositeClipperCancelAudio)
        #expect(reloaded.compositeClipperCancelStereo == original.compositeClipperCancelStereo)
        #expect(abs(reloaded.compositeClipperThresholdDB - original.compositeClipperThresholdDB) < 0.01)
        #expect(abs(reloaded.compositeClipperCeilingDB - original.compositeClipperCeilingDB) < 0.01)
        #expect(reloaded.preemphasisUS == original.preemphasisUS)
        #expect(reloaded.multibandPresetID == original.multibandPresetID)
        #expect(reloaded.multibandIntensity == original.multibandIntensity)
    }
}
