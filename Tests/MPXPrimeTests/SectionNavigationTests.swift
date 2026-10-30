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
        return MPXPrimeViewModel(configPath: tempPath, deviceLister: { [] })
    }

    @Test func goToMonitoringFromProcessingLandsOnMonitoringStage() {
        let model = makeViewModel()
        model.selectedStage = .processingMultiband
        model.goToGroup(.onAir)
        #expect(model.selectedStage == .monitoring)
    }

    @Test func goToProcessingFromMonitoringLandsOnOverview() {
        let model = makeViewModel()
        #expect(model.selectedStage == .monitoring)
        model.goToGroup(.sound)
        #expect(model.selectedStage == .processingOverview)
    }

    @Test func goToRDSFromMonitoringLandsOnRDSControl() {
        let model = makeViewModel()
        model.goToGroup(.rds)
        #expect(model.selectedStage == .rdsControl)
    }

    @Test func goToSetupFromMonitoringLandsOnAudioIO() {
        let model = makeViewModel()
        model.goToGroup(.setup)
        #expect(model.selectedStage == .audioIO)
    }

    @Test func goToSystemFromMonitoringLandsOnPresets() {
        let model = makeViewModel()
        model.goToGroup(.system)
        #expect(model.selectedStage == .snapshots)
    }

    @Test func goToSetupRemembersTestToneIfThatsWhereTheUserWas() {
        let model = makeViewModel()
        model.selectedStage = .testTone
        model.goToGroup(.onAir)
        model.goToGroup(.setup)
        #expect(model.selectedStage == .testTone)
    }

    @Test func goToProcessingRemembersLastSubTab() {
        // Visit a Processing sub-tab, leave, come back via the shortcut.
        let model = makeViewModel()
        model.selectedStage = .processingCompositeClipper
        model.goToGroup(.rds)
        #expect(model.selectedStage == .rdsControl)
        model.goToGroup(.sound)
        #expect(model.selectedStage == .processingCompositeClipper,
            "⌘2 should restore the last Processing sub-tab visited, not snap to Overview")
    }

    @Test func goToRDSRemembersLastSubTab() {
        let model = makeViewModel()
        model.selectedStage = .rdsRadiotext
        model.goToGroup(.onAir)
        model.goToGroup(.rds)
        #expect(model.selectedStage == .rdsRadiotext)
    }

    @Test func everyStageHasASectionAndEverySoundGroupIsReachable() {
        // The sidebar draws Sound from the shared StageGroup table; a stage the
        // table forgets would silently vanish from the GUI.
        let listed = Set(Stage.soundLandingStages + Stage.soundGroups.flatMap(\.stages))
        for stage in Stage.allCases where stage.group == .sound {
            #expect(listed.contains(stage), "\(stage) is in the Sound section but no group lists it")
        }
        #expect(Set(Stage.Group.allCases.map(\.section)) == Set(NavigationSection.allCases))
    }

    @Test func goToCurrentGroupIsANoOp() {
        // ⌘2 while already on a Processing sub-tab should not snap to
        // Overview — staying put is the correct behavior (also avoids
        // an unnecessary @Published broadcast).
        let model = makeViewModel()
        model.selectedStage = .processingMultiband
        model.goToGroup(.sound)
        #expect(model.selectedStage == .processingMultiband)
    }

    // MARK: - Processed-audio output mode hides composite/RDS surfaces

    @Test func compositeOutputShowsAllStages() {
        let model = makeViewModel()
        model.config.processedAudioOutput = false
        // Every mode-gated stage shows; the one exception is the pages of the
        // levelling engine not in use (the default is Advanced Dynamics
        // since 2026-10-15).
        for stage in Stage.allCases where stage.levellingEngine != .regular {
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
        for stage: Stage in [.monitoring, .processingOverview, .processingAdvancedDynamics,
                             .processingLimiter, .testTone] {
            #expect(model.isStageVisible(stage), "\(stage) should remain visible")
        }
    }

    @Test func switchingToProcessedAudioNormalizesAStaleRDSSelection() {
        let model = makeViewModel()
        model.selectedStage = .rdsRadiotext
        model.config.processedAudioOutput = true
        model.normalizeSelection()
        #expect(model.selectedStage == .processingOverview,
            "a hidden RDS selection should snap back to the Processing overview")
    }

    @Test func hdOutputHidesPreemphasisDependentHFControl() {
        let model = makeViewModel()
        model.config.operatingMode = .hd
        #expect(!model.isStageVisible(.processingHFLimiter))

        model.selectedStage = .processingHFLimiter
        model.normalizeSelection()
        #expect(model.selectedStage == .processingOverview)

        for mode: AppConfig.OperatingMode in [.mpx, .fm, .am] {
            model.config.operatingMode = mode
            #expect(model.isStageVisible(.processingHFLimiter),
                    "HF control should remain available in \(mode.title)")
        }
    }

    @Test func compositeStageSelectionSurvivesInCompositeMode() {
        let model = makeViewModel()
        model.selectedStage = .processingCompositeClipper
        model.config.processedAudioOutput = false
        model.normalizeSelection()
        #expect(model.selectedStage == .processingCompositeClipper)
    }

    // MARK: - Levelling engine hides the other engine's pages

    @Test func levellingEngineChoiceHidesTheOtherEnginesPages() {
        let model = makeViewModel()
        let regular: [Stage] = [.processingAGC, .processingMultiband, .processingExpander, .processingMBLimiter]
        // Defaults (since 2026-10-15): Advanced Dynamics, so the regular
        // chain's pages are hidden.
        #expect(LevellingEngine.current(for: model.config) == .advanced)
        for stage in regular {
            #expect(!model.isStageVisible(stage), "\(stage) is replaced by Advanced Dynamics and should hide")
        }
        #expect(model.isStageVisible(.processingAdvancedDynamics))

        model.config.advancedDynamicsEnabled = false
        for stage in regular {
            #expect(model.isStageVisible(stage), "\(stage) belongs to the regular engine and should show")
        }
        #expect(!model.isStageVisible(.processingAdvancedDynamics))

        // A selection the new engine does not own snaps to the overview --
        // the page the picker lives on.
        model.config.advancedDynamicsEnabled = true
        model.selectedStage = .processingAGC
        model.normalizeSelection()
        #expect(model.selectedStage == .processingOverview)

        // Mode gating composes with the engine: HD has no HF control
        // whichever engine levels, and the engine still hides its rival.
        model.config.operatingMode = .hd
        #expect(!model.isStageVisible(.processingHFLimiter))
        #expect(!model.isStageVisible(.processingAGC))
        model.config.advancedDynamicsEnabled = false
        #expect(!model.isStageVisible(.processingHFLimiter))
        #expect(model.isStageVisible(.processingAGC))
        #expect(!model.isStageVisible(.processingAdvancedDynamics))
    }
}

#endif  // os(macOS)
