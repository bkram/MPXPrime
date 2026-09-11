// macOS-only: exercises the SwiftUI view model, which the Linux CLI build excludes.
#if os(macOS)

import Testing
import Foundation
@testable import MPXPrime

// The Processing Overview grid's chevron-card buttons need to set
// `selectedStage` to the right unified-enum case so the sidebar lights
// up and the per-stage content view picks the right detail tab. This
// suite pins the ProcessingTab → Stage mapping (and its inverse via
// Stage.legacyProcessingTab) so a rename or a missing case is caught
// at test time instead of as a silent "click does nothing" UI bug.

@Suite("ProcessingTab ↔ Stage mapping")
@MainActor
struct ProcessingTabStageMappingTests {

    @Test func everyProcessingTabRoundTripsThroughStage() {
        for tab in ProcessingTab.allCases {
            let stage = tab.stage
            let backToTab = stage.legacyProcessingTab
            #expect(backToTab == tab,
                "ProcessingTab.\(tab) → Stage.\(stage) but Stage.legacyProcessingTab = \(String(describing: backToTab))")
        }
    }

    @Test func everyProcessingStageMapsBackToATab() {
        let processingStages: [Stage] = Stage.allCases.filter { $0.group == .processing }
        for stage in processingStages {
            #expect(stage.legacyProcessingTab != nil,
                "Stage.\(stage) in the .processing group must have a legacyProcessingTab")
        }
    }

    @Test func clickingPhaseRotatorCardFromOverviewLandsOnPhaseRotatorStage() {
        // Simulates what the Overview-grid chevron Button does.
        let tempPath = NSTemporaryDirectory()
            + "MPXPrime-ProcessingTabStageMappingTests-\(UUID().uuidString).ini"
        let model = MPXPrimeViewModel(configPath: tempPath, deviceLister: { [] })
        model.selectedStage = .processingOverview
        #expect(model.selectedProcessingTab == .overview)
        // The Button action body:
        model.selectedStage = ProcessingTab.phaseRotator.stage
        // didSet should propagate to the legacy enum the per-tab switch reads.
        #expect(model.selectedStage == .processingPhaseRotator)
        #expect(model.selectedProcessingTab == .phaseRotator)
    }

    @Test func clickingAGCCardFromOverviewLandsOnAGCStage() {
        let tempPath = NSTemporaryDirectory()
            + "MPXPrime-ProcessingTabStageMappingTests-\(UUID().uuidString).ini"
        let model = MPXPrimeViewModel(configPath: tempPath, deviceLister: { [] })
        model.selectedStage = .processingOverview
        model.selectedStage = ProcessingTab.agc.stage
        #expect(model.selectedStage == .processingAGC)
        #expect(model.selectedProcessingTab == .agc)
    }
}

#endif  // os(macOS)
