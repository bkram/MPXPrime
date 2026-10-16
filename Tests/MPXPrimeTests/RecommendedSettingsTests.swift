// macOS-only: exercises the SwiftUI view model, which the Linux CLI build excludes.
#if os(macOS)

import Testing
import Foundation
@testable import MPXPrime

// "Apply recommended" on the Sound overview re-applies the selected Format
// Profile through the SAME view-model path picking the profile uses
// (`applyFormatProfile`, then `normalizeSelection`). These tests pin the
// contract the button advertises: a stage key the profile owns snaps back
// to the profile's value, and installation keys (devices, levels, mode,
// control server) are untouched. The catalogue's per-profile values are
// read from the catalogue, never restated here.

@Suite("Recommended settings")
@MainActor
struct RecommendedSettingsTests {

    private func makeViewModel() -> MPXPrimeViewModel {
        let tempPath = NSTemporaryDirectory()
            + "MPXPrime-RecommendedSettingsTests-\(UUID().uuidString).ini"
        return MPXPrimeViewModel(configPath: tempPath, deviceLister: { [] })
    }

    /// What the Overview button does, in one place.
    private func applyRecommended(_ model: MPXPrimeViewModel) {
        model.applyFormatProfile(model.config.formatProfileID)
        model.normalizeSelection()
    }

    @Test func applyRecommendedRestoresStageKeysAndLeavesInstallationAlone() throws {
        let model = makeViewModel()
        model.applyFormatProfile("music_loud")
        let profile = try #require(MPXPrimeViewModel.formatProfile(forID: "music_loud"))

        // Installation keys, set to values no profile could produce.
        model.config.inputDeviceUID = "in-test-uid"
        model.config.outputDeviceUID = "out-test-uid"
        model.config.monitorDeviceUID = "mon-test-uid"
        model.config.inputGainDB = -3.25
        model.config.outputGainDB = -4.75
        model.config.operatingMode = .fm
        model.config.controlEnabled = true
        model.config.controlBind = "0.0.0.0"
        model.config.controlPort = 9911

        // Stage keys the profile owns, drifted away from the profile.
        model.config.multibandEnabled = false
        model.config.widebandAGCEnabled = !profile.agcEnabled
        model.config.compositeClipperThresholdDB = profile.compositeClipperThresholdDB - 3.0
        model.config.finalDriveDB = profile.finalDriveDB + 2.0

        applyRecommended(model)

        #expect(model.config.formatProfileID == "music_loud")
        #expect(model.config.multibandEnabled, "the profile's multiband preset re-engages the stage")
        #expect(model.config.widebandAGCEnabled == profile.agcEnabled)
        #expect(abs(model.config.compositeClipperThresholdDB - profile.compositeClipperThresholdDB) < 1e-9)
        #expect(abs(model.config.finalDriveDB - profile.finalDriveDB) < 1e-9)

        #expect(model.config.inputDeviceUID == "in-test-uid")
        #expect(model.config.outputDeviceUID == "out-test-uid")
        #expect(model.config.monitorDeviceUID == "mon-test-uid")
        #expect(abs(model.config.inputGainDB - (-3.25)) < 1e-9)
        #expect(abs(model.config.outputGainDB - (-4.75)) < 1e-9)
        #expect(model.config.operatingMode == .fm)
        #expect(model.config.controlEnabled)
        #expect(model.config.controlBind == "0.0.0.0")
        #expect(model.config.controlPort == 9911)
    }

    @Test func applyRecommendedKeepsAVisibleSelection() {
        // normalizeSelection after the apply must not move the operator off
        // a page the configuration still shows.
        let model = makeViewModel()
        model.applyFormatProfile("speech")
        model.selectedStage = .processingAdvancedDynamics
        applyRecommended(model)
        #expect(model.selectedStage == .processingAdvancedDynamics)
    }

    @Test func applyRecommendedWithCustomChangesNothing() {
        // The button is disabled for `custom`; the path it would take is the
        // sentinel apply, which records the label and nothing else.
        let model = makeViewModel()
        model.applyFormatProfile("music_loud")
        model.config.multibandEnabled = false
        model.applyFormatProfile("custom")
        applyRecommended(model)
        #expect(model.config.formatProfileID == "custom")
        #expect(!model.config.multibandEnabled, "custom must not re-apply any stage key")
    }
}

#endif  // os(macOS)
