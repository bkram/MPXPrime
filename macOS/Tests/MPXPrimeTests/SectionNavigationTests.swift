// macOS-only: exercises the SwiftUI view model, which the Linux CLI build excludes.
#if os(macOS)

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

    // MARK: - Processed-audio output mode hides composite/RDS surfaces

    @Test func compositeOutputShowsAllStages() {
        let model = makeViewModel()
        model.config.processedAudioOutput = false
        for stage in Stage.allCases {
            #expect(model.isStageVisible(stage), "\(stage) should be visible in composite mode")
        }
    }

    @Test func processedAudioHidesCompositeAndRDSStages() {
        let model = makeViewModel()
        model.config.processedAudioOutput = true
        // Hidden: composite clipper, BS.412, and every RDS stage.
        for stage in Stage.allCases where stage.group == .rds {
            #expect(!model.isStageVisible(stage), "RDS stage \(stage) should be hidden")
        }
        #expect(!model.isStageVisible(.processingCompositeClipper))
        #expect(!model.isStageVisible(.processingBS412))
        #expect(!model.isStageVisible(.processingFinalStage))
        // Audio-domain stages and the monitor/tools stay visible.
        for stage: Stage in [.monitoring, .processingOverview, .processingAGC,
                             .processingMultiband, .processingLimiter, .testTone] {
            #expect(model.isStageVisible(stage), "\(stage) should remain visible")
        }
    }

    @Test func switchingToProcessedAudioNormalizesAStaleRDSSelection() {
        let model = makeViewModel()
        model.selectedStage = .rdsRadiotext
        model.config.processedAudioOutput = true
        model.normalizeSelectionForOutputMode()
        #expect(model.selectedStage == .processingOverview,
            "a hidden RDS selection should snap back to the Processing overview")
    }

    @Test func compositeStageSelectionSurvivesInCompositeMode() {
        let model = makeViewModel()
        model.selectedStage = .processingCompositeClipper
        model.config.processedAudioOutput = false
        model.normalizeSelectionForOutputMode()
        #expect(model.selectedStage == .processingCompositeClipper)
    }
}

#endif  // os(macOS)
