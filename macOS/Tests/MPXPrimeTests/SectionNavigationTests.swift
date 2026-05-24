import Testing
import Foundation
@testable import MPXPrime

// Section-navigation shortcuts (⌘1-⌘4) jump between sidebar groups
// and remember the last sub-tab visited within each group so swapping
// to another section and back restores the operator's place.

@Suite("Section navigation")
@MainActor
struct SectionNavigationTests {

    private func makeViewModel() -> MPXPrimeViewModel {
        let tempPath = NSTemporaryDirectory()
            + "MPXPrime-SectionNavTests-\(UUID().uuidString).ini"
        return MPXPrimeViewModel(configPath: tempPath)
    }

    @Test func goToMonitoringFromProcessingLandsOnMonitoringStage() {
        let model = makeViewModel()
        model.selectedStage = .processingMultiband
        model.goToGroup(.monitoring)
        #expect(model.selectedStage == .monitoring)
    }

    @Test func goToProcessingFromMonitoringLandsOnOverview() {
        let model = makeViewModel()
        #expect(model.selectedStage == .monitoring)
        model.goToGroup(.processing)
        #expect(model.selectedStage == .processingOverview)
    }

    @Test func goToRDSFromMonitoringLandsOnRDSControl() {
        let model = makeViewModel()
        model.goToGroup(.rds)
        #expect(model.selectedStage == .rdsControl)
    }

    @Test func goToToolsFromMonitoringLandsOnTestTone() {
        let model = makeViewModel()
        model.goToGroup(.tools)
        #expect(model.selectedStage == .testTone)
    }

    @Test func goToProcessingRemembersLastSubTab() {
        // Visit a Processing sub-tab, leave, come back via the shortcut.
        let model = makeViewModel()
        model.selectedStage = .processingCompositeClipper
        model.goToGroup(.rds)
        #expect(model.selectedStage == .rdsControl)
        model.goToGroup(.processing)
        #expect(model.selectedStage == .processingCompositeClipper,
            "⌘2 should restore the last Processing sub-tab visited, not snap to Overview")
    }

    @Test func goToRDSRemembersLastSubTab() {
        let model = makeViewModel()
        model.selectedStage = .rdsRadiotext
        model.goToGroup(.monitoring)
        model.goToGroup(.rds)
        #expect(model.selectedStage == .rdsRadiotext)
    }

    @Test func goToToolsRemembersSnapshotsIfThatsWhereTheUserWas() {
        let model = makeViewModel()
        model.selectedStage = .snapshots
        model.goToGroup(.monitoring)
        model.goToGroup(.tools)
        #expect(model.selectedStage == .snapshots)
    }

    @Test func goToCurrentGroupIsANoOp() {
        // ⌘2 while already on a Processing sub-tab should not snap to
        // Overview — staying put is the correct behavior (also avoids
        // an unnecessary @Published broadcast).
        let model = makeViewModel()
        model.selectedStage = .processingMultiband
        model.goToGroup(.processing)
        #expect(model.selectedStage == .processingMultiband)
    }
}
