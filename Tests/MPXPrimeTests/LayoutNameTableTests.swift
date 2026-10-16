// macOS-only: `Stage` is the SwiftUI sidebar's enum, excluded from Linux.
#if os(macOS)

import Foundation
import Testing

@testable import MPXPrime

// One name per page (UI layout review 2026-10, WP1.1). `Stage` is the name
// table: the sidebar label is the master, and the page title, the reset
// button, the Overview card, the flow-strip chip and the web dashboard's
// page title, subtitle, help and chain pill all derive from it. Before the
// table a stage had up to five names ("Audio Clipper", "Audio Clip", "DC
// Clipper", "DC-Clip"; "Identity", "Program", "Program Service"), and the
// dashboard spelled them again by hand.
@Suite("Layout: one name table")
struct LayoutNameTableTests {

    private func schemaModel() throws -> [String: Any] {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MPXPrime/Control/WebUI/schema.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any] ?? [:]
        return root["model"] as? [String: Any] ?? [:]
    }

    private func schemaPages() throws -> [String: [String: Any]] {
        let model = try schemaModel()
        var pages: [String: [String: Any]] = [:]
        for list in ["stages", "rds", "tools"] {
            for page in model[list] as? [[String: Any]] ?? [] {
                if let id = page["id"] as? String { pages[id] = page }
            }
        }
        return pages
    }

    @Test func everyDashboardPageUsesTheStageNames() throws {
        let pages = try schemaPages()
        for stage in Stage.allCases {
            let id = stage.schemaPageID
            if stage == .monitoring || stage == .processingOverview { continue }
            let page = try #require(pages[id], "no dashboard page \(id) for \(stage)")
            #expect(page["title"] as? String == stage.label, "\(id) title")
            #expect(page["sub"] as? String == stage.detailSubtitle, "\(id) subtitle")
            #expect(page["help"] as? String == stage.helpText, "\(id) help")
        }
        let model = try schemaModel()
        #expect(model["overviewHelp"] as? String == Stage.processingOverview.helpText)
        #expect(model["overviewTitle"] as? String == Stage.processingOverview.label)
        #expect(model["overviewSub"] as? String == Stage.processingOverview.detailSubtitle)
        #expect(model["monitoringTitle"] as? String == Stage.monitoring.label)
        #expect(model["monitoringSub"] as? String == Stage.monitoring.detailSubtitle)
        #expect(model["monitoringHelp"] as? String == Stage.monitoring.helpText)
    }

    @Test func theChainPillsAreTheFlowStripChips() throws {
        let model = try schemaModel()
        let pills = model["pills"] as? [[Any]] ?? []
        let expected: [(String, String?)] = [("IN", nil)]
            + Stage.signalChain.map { ($0.chipLabel ?? "", $0.schemaPageID) }
            + [("OUT", nil)]
        #expect(pills.count == expected.count)
        for (pill, want) in zip(pills, expected) {
            #expect(pill.first as? String == want.0)
            #expect((pill.count > 1 ? pill[1] as? String : nil) == want.1)
        }
        // A stage page's own `pill` is its chip (nil when the strip omits it).
        let pages = try schemaPages()
        for tab in ProcessingTab.allCases where tab != .overview {
            #expect(pages[tab.rawValue]?["pill"] as? String == tab.stage.chipLabel, "\(tab.rawValue) pill")
        }
    }

    @Test func everyStripStageHasAChipAndOnlyStripStagesDo() {
        for stage in Stage.allCases {
            #expect((stage.chipLabel != nil) == Stage.signalChain.contains(stage), "\(stage)")
        }
        // The output terminal and the clipper names say what the stage is.
        #expect(Stage.processingDCClipper.chipLabel == "Audio Clip")
        #expect(Stage.processingDCClipper.label == "Audio Clipper")
    }

    @Test func pageEnumsHaveNoNamesOfTheirOwn() {
        // The tab enums are keyed by the dashboard page id and read every
        // operator-facing string from `Stage`.
        for tab in ProcessingTab.allCases {
            #expect(tab.rawValue == tab.stage.schemaPageID)
            #expect(tab.resetButtonTitle == "Reset \(tab.stage.label)")
            #expect(tab.helpText == tab.stage.helpText)
            #expect(tab.stage.legacyProcessingTab == tab)
        }
        for tab in RDSTab.allCases {
            #expect(tab.rawValue == tab.stage.schemaPageID)
            #expect(tab.resetButtonTitle == "Reset \(tab.stage.label)")
            #expect(tab.stage.legacyRDSTab == tab)
        }
        // Identity's reset says Identity (it said "Reset Program Tab").
        #expect(RDSTab.program.resetButtonTitle == "Reset Identity")
        #expect(RDSTab.carrier.resetButtonTitle == "Reset Subcarrier")
    }

    @Test func everyPageHasHelpAndASentenceSubtitleInPlainASCII() {
        for stage in Stage.allCases {
            #expect(!stage.helpText.isEmpty, "\(stage) has no help")
            #expect(stage.detailSubtitle.hasSuffix("."), "\(stage) subtitle is not a sentence")
            for text in [stage.label, stage.detailSubtitle, stage.helpText] {
                let ascii = text.unicodeScalars.allSatisfy { $0.isASCII }
                #expect(ascii, "\(stage): non-ASCII in '\(text)'")
            }
        }
    }

    @Test func soundGroupsFollowTheSignalOrder() {
        // The sidebar's Sound groups list the stages in the order the signal
        // meets them (PrimeBass after the multiband, the Bass Clipper after
        // PrimeBass); only the levelling group pairs the two engines.
        let levelling: Set<Stage> = [.processingAGC, .processingAdvancedDynamics]
        let sidebar = Stage.soundGroups.flatMap(\.stages)
            .filter { Stage.signalChain.contains($0) && !levelling.contains($0) }
        let chain = Stage.signalChain.filter { sidebar.contains($0) }
        #expect(sidebar == chain)
        #expect(StageGroup.allCases.map(\.title)
                == ["Input", "Levelling", "EQ", "Dynamics", "Bass", "Peak Control", "Transmission"])
    }
}

#endif  // os(macOS)
