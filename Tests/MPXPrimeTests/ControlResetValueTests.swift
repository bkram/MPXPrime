#if os(macOS)
import Foundation
import Testing
@testable import MPXPrime

/// Every slider resets to the ACTIVE Format Profile value (the shipped
/// defaults are Music - Clean itself), so a reset never drags a Loud or
/// Speech station back to Clean values.
@Suite("Control reset values")
@MainActor
struct ControlResetValueTests {
    private func model() -> MPXPrimeViewModel {
        MPXPrimeViewModel(
            configPath: NSTemporaryDirectory() + "MPXPrime-Reset-\(UUID().uuidString).ini",
            deviceLister: { [] })
    }

    @Test func shippedDefaultsAreTheDefaultProfile() {
        var profiled = AppConfig()
        _ = PresetCatalog.applyFormatProfile(id: AppConfig().formatProfileID, to: &profiled)
        #expect(String(describing: profiled) == String(describing: AppConfig()))
    }

    @Test func resetFollowsTheActiveProfile() {
        let m = model()
        m.config.formatProfileID = "music_clean"
        #expect(m.resetValue(\.finalDriveDB) == AppConfig().finalDriveDB)
        m.config.formatProfileID = "music_loud"
        var loud = AppConfig()
        _ = PresetCatalog.applyFormatProfile(id: "music_loud", to: &loud)
        #expect(m.resetValue(\.finalDriveDB) == loud.finalDriveDB)
        #expect(m.resetValue(\.multibandLowThresholdDB) == loud.multibandLowThresholdDB)
        #expect(loud.finalDriveDB != AppConfig().finalDriveDB, "the test needs a profile that differs")
        m.shutdown()
    }

    @Test func calibrationAndUntouchedControlsResetToShippedDefaults() {
        let m = model()
        m.config.formatProfileID = "music_dense"
        let shipped = AppConfig()
        #expect(m.resetValue(\.inputGainDB) == shipped.inputGainDB)
        #expect(m.resetValue(\.outputGainDB) == shipped.outputGainDB)
        #expect(m.resetValue(\.processedAudioCeilingDBTP) == shipped.processedAudioCeilingDBTP)
        #expect(m.resetValue(\.processedAudioFinalClipDriveDB) == shipped.processedAudioFinalClipDriveDB)
        m.config.formatProfileID = "custom"
        #expect(m.resetValue(\.finalDriveDB) == shipped.finalDriveDB)
        m.shutdown()
    }

    @Test func fmOutputResetsToTheCoderReferenceLevel() {
        let m = model()
        m.config.operatingMode = .fm
        #expect(m.resetValue(\.outputGainDB) == -9.0)
        m.config.operatingMode = .hd
        #expect(m.resetValue(\.outputGainDB) == AppConfig().outputGainDB, "HD keeps full scale")
        m.shutdown()
    }

    @Test func tabResetUsesTheProfileValuesToo() {
        let m = model()
        m.config.formatProfileID = "music_loud"
        m.config.finalDriveDB = 1.0
        m.selectedProcessingTab = .finalStage
        m.resetCurrentProcessingTabToDefaults()
        #expect(m.config.finalDriveDB == m.resetValue(\.finalDriveDB))
        m.shutdown()
    }
}
#endif
