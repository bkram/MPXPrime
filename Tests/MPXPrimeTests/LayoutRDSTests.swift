// macOS-only: builds SwiftUI page bodies, which the Linux build excludes.
#if os(macOS)

import Foundation
import SwiftUI
import Testing

@testable import MPXPrime

// The RDS pages (UI layout review 2026-10, WP5 and Q18).
@Suite("Layout: RDS pages", .serialized)
@MainActor
struct LayoutRDSTests {

    private func buildAllRDSPages(_ m: MPXPrimeViewModel) {
        _ = RDSStatusTab(model: m).body
        _ = RDSStatusSwitches(model: m).body
        _ = RDSProgramTab(model: m).body
        _ = RDSStationCodes(model: m).body
        _ = RDSStationNames(model: m).body
        _ = RDSLongPSFields(model: m).body
        _ = RDSIdentityAdvanced(model: m).body
        _ = PSBankRow(letter: "A", model: m, path: \.rdsPSA).body
        _ = RDSRadiotextTab(model: m).body
        _ = RDSRadiotextText(model: m).body
        _ = RDSRadiotextMessages(model: m).body
        _ = RDSRadiotextPlus(model: m).body
        _ = RDSNowPlaying(model: m).body
        _ = RDSCarrierTab(model: m).body
        _ = RDSInjectionControls(model: m).body
        _ = RDSScheduleTab(model: m).body
        _ = RDSGroupSchedule(model: m).body
        _ = RDSClockTime(model: m).body
        _ = RDSAFTab(model: m).body
        _ = RDSAFFields(model: m).body
    }

    @Test func everyRDSControlDeclaresTheEnginesDisposition() {
        // RDS exists only in MPX Output. Build once with the optional groups
        // collapsed (PIN off) and once with them open, so the conditional
        // controls are covered too.
        var total = 0
        for pinOn in [false, true] {
            let m = LayoutAudit.model(.mpx)
            m.config.rdsEnablePIN = pinOn
            m.config.rdsNowPlayingEnabled = !pinOn
            m.config.rdsSchedulerStandard = pinOn
            m.config.rdsSchedulerAuto = pinOn
            let result = LayoutAudit.mismatches { buildAllRDSPages(m) }
            total += result.checked
            #expect(result.problems.isEmpty, "\(result.problems)")
            m.shutdown()
        }
        #expect(total > 60, "expected the RDS pages to declare their settings; checked \(total)")
    }

    @Test func theInjectionIsRestartClassAndShownInKilohertz() {
        // Before: percent of 75 kHz (0-10 %) next to kHz on the web and in the
        // guide. Now kHz, same range as the dashboard, percent as a readout.
        #expect(RDSPageFormat.injectionReadout(kHz: 2.0) == "2.0 kHz (2.7%)")
        #expect(RDSPageFormat.injectionReadout(kHz: 7.5) == "7.5 kHz (10.0%)")
        #expect(RDSPageFormat.injectionRangeKHz == 0.0...7.5)
        #expect(RestartClassKeys.guiDisposition(of: "rds_level") == .restart)
        let m = LayoutAudit.model(.mpx)
        SettingAudit.reset()
        SettingAudit.isRecording = true
        _ = RDSInjectionControls(model: m).body
        SettingAudit.isRecording = false
        let entry = SettingAudit.entries.first { $0.iniKeys() == ["rds_level"] }
        #expect(entry?.disposition == .restart, "the injection slider must carry the restart badge")
        SettingAudit.reset()
        m.shutdown()
    }

    @Test func timeZoneIsAQuarterHourMenu() {
        let choices = RDSPageFormat.timeZoneChoices
        #expect(choices.first == -12.0)
        #expect(choices.last == 14.0)
        #expect(choices.count == 105)
        #expect(zip(choices, choices.dropFirst()).allSatisfy { $1 - $0 == 0.25 })
        #expect(RDSPageFormat.timeZoneLabel(1.0) == "UTC+01:00")
        #expect(RDSPageFormat.timeZoneLabel(0.0) == "UTC+00:00")
        #expect(RDSPageFormat.timeZoneLabel(-3.5) == "UTC-03:30")
        #expect(RDSPageFormat.timeZoneLabel(5.75) == "UTC+05:45")
        // A hand-edited off-grid value still shows as itself.
        #expect(RDSPageFormat.timeZoneMenu(including: 1.1).contains(1.1))
        #expect(RDSPageFormat.timeZoneMenu(including: 1.0) == choices)
    }

    @Test func rangesMatchTheDashboard() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MPXPrime/Control/WebUI/schema.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any] ?? [:]
        let schema = root["schema"] as? [String: [String: Any]] ?? [:]
        func range(_ key: String) -> ClosedRange<Double>? {
            guard let lo = (schema[key]?["min"] as? NSNumber)?.doubleValue,
                  let hi = (schema[key]?["max"] as? NSNumber)?.doubleValue else { return nil }
            return lo...hi
        }
        #expect(range("rds_level") == RDSPageFormat.injectionRangeKHz)
        #expect(range("rt_cycle_time") == RDSPageFormat.cycleTimeRange)
        withKnownIssue("the dashboard's PS Frame Time range is fork W's (schema.json); 0.5-30 s is the shared decision", isIntermittent: true) {
            #expect(range("ps_frame_seconds") == RDSPageFormat.psFrameRange)
        }
    }

    @Test func noRDSLabelCarriesAGroupCode() throws {
        // Group codes ("(1A)", "(4A)", "(15A)") are mechanism: tooltips only.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MPXPrime/UI/RDSTabs.swift"), encoding: .utf8)
        let labelCall = try Regex(#"(?:Toggle|SettingToggle|SettingPicker|Picker|Card\(title:|DoubleSliderRow\(\s*title:|LabeledContent|Text)\(?\s*"([^"]*)""#)
        var labels: [String] = []
        for match in source.matches(of: labelCall) {
            if let s = match.output[1].substring { labels.append(String(s)) }
        }
        #expect(labels.count > 30)
        let groupCode = try Regex(#"\(\d{1,2}[AB]\)"#)
        for label in labels {
            #expect(label.firstMatch(of: groupCode) == nil, "label '\(label)' carries a group code")
        }
        for gone in ["Center", "Msg ", "DI Comp", "Program Service", "Runtime Flags", "Single Radiotext"] {
            #expect(!labels.contains { $0.contains(gone) }, "old label '\(gone)' still present")
        }
    }

    @Test func onAirSwitchesAreOnStatusAndIDIsNotInTheClock() {
        // TA / TP / MS are switched during the day: Status (they sat on
        // Identity under "Runtime Flags"). "Enable ID" is identity, not clock
        // time (it sat in the Clock Time card).
        func keys(_ build: () -> Void) -> Set<String> {
            SettingAudit.reset()
            SettingAudit.isRecording = true
            build()
            SettingAudit.isRecording = false
            let k = Set(SettingAudit.entries.flatMap { $0.iniKeys() })
            SettingAudit.reset()
            return k
        }
        let m = LayoutAudit.model(.mpx)
        let status = keys { _ = RDSStatusSwitches(model: m).body }
        #expect(status.isSuperset(of: ["en_rds", "tp", "ta", "ms"]))
        let identity = keys {
            _ = RDSStationCodes(model: m).body
            _ = RDSStationNames(model: m).body
            _ = RDSLongPSFields(model: m).body
            _ = RDSIdentityAdvanced(model: m).body
        }
        #expect(identity.isDisjoint(with: ["tp", "ta", "ms"]))
        #expect(identity.isSuperset(of: ["pi", "ecc", "pty", "en_id", "en_lps", "ps_long_32", "lic"]))
        let clock = keys { _ = RDSClockTime(model: m).body }
        #expect(!clock.contains("en_id"))
        #expect(clock == ["en_ct", "tz_offset"])
        m.shutdown()
    }
}

#endif  // os(macOS)
