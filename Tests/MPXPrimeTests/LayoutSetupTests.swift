// macOS-only: builds SwiftUI page bodies, which the Linux build excludes.
#if os(macOS)

import Foundation
import SwiftUI
import Testing

@testable import MPXPrime

// Setup pages (UI layout review 2026-10, WP3). Every control on Audio I/O,
// Test Tone and the Settings window binds through `setting()`, so its restart
// badge is derived from a disposition the engine agrees with; pre-emphasis
// has one home (Audio I/O) in every mode that has it, and the composite
// deviation sits with the other output levels in MPX Output.
@Suite("Layout: Setup pages", .serialized)
@MainActor
struct LayoutSetupTests {

    /// Builds every Setup page and card body in `mode`.
    private func buildSetupPages(_ m: MPXPrimeViewModel) {
        _ = AudioIOTab(model: m).body
        _ = OperatingModeCardContent(model: m).body
        _ = AMOutputControls(model: m).body
        _ = AudioIOInputCardContent(model: m).body
        _ = AudioIOOutputCardContent(model: m).body
        _ = AudioIOMonitorCardContent(model: m).body
        _ = AudioIOEngineCardContent(model: m).body
        _ = AudioIOEngineAdvancedContent(model: m).body
        _ = TestToneView(model: m).body
        _ = TestToneFrequencyRow(model: m).body
        _ = SettingsSectionView(model: m).body
    }

    @Test func setupPagesDeclareTheEnginesDisposition() {
        var total = 0
        for mode in AppConfig.OperatingMode.allCases {
            let m = LayoutAudit.model(mode)
            m.config.processedAudioCoderHasClipper = false  // show the drive slider in FM
            let result = LayoutAudit.mismatches { buildSetupPages(m) }
            total += result.checked
            #expect(result.problems.isEmpty, "\(mode.title): \(result.problems)")
            m.shutdown()
        }
        #expect(total > 60, "expected the Setup pages to declare their settings; checked \(total)")
    }

    /// The INI keys a page declares in `mode`.
    private func declaredKeys(_ mode: AppConfig.OperatingMode, _ build: (MPXPrimeViewModel) -> Void) -> Set<String> {
        let m = LayoutAudit.model(mode)
        SettingAudit.reset()
        SettingAudit.isRecording = true
        build(m)
        SettingAudit.isRecording = false
        let keys = Set(SettingAudit.entries.flatMap { $0.iniKeys() })
        SettingAudit.reset()
        m.shutdown()
        return keys
    }

    @Test func preemphasisLivesOnAudioIOInEveryModeThatHasIt() {
        for mode in AppConfig.OperatingMode.allCases {
            let keys = declaredKeys(mode) { _ = OperatingModeCardContent(model: $0).body }
            #expect(keys.contains("preemphasis_us") == ChainFeature.preemphasis.applies(in: mode),
                    "\(mode.title)")
        }
        // Before: MPX Output had it on Sound > Basics and Audio I/O did not.
        #expect(declaredKeys(.mpx) { _ = OperatingModeCardContent(model: $0).body }.contains("preemphasis_us"))
    }

    @Test func compositeDeviationIsAnOutputLevelInMPXOutputOnly() {
        for mode in AppConfig.OperatingMode.allCases {
            let keys = declaredKeys(mode) { _ = AudioIOOutputCardContent(model: $0).body }
            #expect(keys.contains("mpx_deviation_khz") == (mode == .mpx), "\(mode.title)")
            #expect(keys.contains("output_gain_db"))
        }
        #expect(AudioIOOutputCardContent.outputLevelTitle(.mpx) == "MPX Output Level")
        #expect(AudioIOOutputCardContent.outputLevelRange(.mpx) == -18...0)
        for mode: AppConfig.OperatingMode in [.fm, .hd, .am] {
            #expect(AudioIOOutputCardContent.outputLevelTitle(mode) == "Output Level")
            #expect(AudioIOOutputCardContent.outputLevelRange(mode) == -18...18)
        }
    }

    @Test func engineChoicesLiveOnAudioIONotInTheSettingsWindow() {
        let engine = declaredKeys(.mpx) {
            _ = AudioIOEngineCardContent(model: $0).body
            _ = AudioIOEngineAdvancedContent(model: $0).body
        }
        for key in ["sample_rate", "blocksize", "encoder_fir_enabled", "multiband_fir_enabled", "fft_window_92khz"] {
            #expect(engine.contains(key), "\(key) belongs on Audio I/O > Engine")
        }
        let settings = declaredKeys(.mpx) { _ = SettingsSectionView(model: $0).body }
        #expect(!settings.contains("fft_window_92khz"))
        #expect(settings == ["control_enabled", "control_bind", "control_port", "control_api_key"])
    }

    @Test func sampleRatesReadInKilohertz() {
        #expect(AudioIOEngineCardContent.sampleRates.map(AudioIOEngineCardContent.rateLabel)
                == ["44.1 kHz", "48 kHz", "88.2 kHz", "96 kHz", "176.4 kHz", "192 kHz"])
    }

    @Test func testToneIsOneCardWithATonedLevelAndUnitsOnEveryPreset() {
        let keys = declaredKeys(.mpx) {
            _ = TestToneView(model: $0).body
            _ = TestToneFrequencyRow(model: $0).body
        }
        #expect(keys == ["test_tone_type", "test_tone_mode", "test_tone_level_db", "test_tone_freq"])
        #expect(TestToneView.presetLabel(for: 50) == "50 Hz")
        #expect(TestToneView.presetLabel(for: 1_000) == "1 kHz")
        #expect(TestToneView.presetLabel(for: 12_000) == "12 kHz")
        // The help box says the tone bypasses the chain; so does the page's
        // own doc (it used to say the chain processed the tone normally).
        #expect(Stage.testTone.helpText.contains("bypasses the processing chain"))
    }

    @Test func theTestTonePageResetsTheGenerator() {
        let m = LayoutAudit.model(.mpx)
        m.config.sourceMode = "tone"
        m.config.testToneLevelDB = -3
        m.config.testToneFreq = 400
        m.resetPage(.testTone)
        let shipped = AppConfig()
        #expect(m.config.sourceMode == shipped.sourceMode)
        #expect(m.config.testToneLevelDB == shipped.testToneLevelDB)
        #expect(m.config.testToneFreq == shipped.testToneFreq)
        m.shutdown()
    }
}

#endif  // os(macOS)
